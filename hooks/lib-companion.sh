#!/usr/bin/env bash
# Maestro companion library — shared Codex companion plumbing for the hook scripts.
# Sourced, not executed. All functions assume `set -uo pipefail` in the caller.
#
#   progress_init                          → keeps inherited FD 3, or opens it to caller stdout
#   progress <message>                     → writes one progress line to FD 3
#   write_lock_acquire [job]               → returns 0 acquired/inherited | 11 live contention
#   write_lock_set_job <job>               → records a known job id for the current owner
#   write_lock_release                     → releases an acquired lock only after its lease ends
#   companion_resolve                      → prints companion path, or returns 3
#   companion_pin                          → prints model<TAB>effort, or returns 3
#   companion_start <C> <prompt> [write]   → prints job id, or returns 3 (fails closed without a pin)
#   companion_verify_pin <C> <job> <model> <effort> → returns 0 match | 4 mismatch
#   companion_workspace_writers <C>        → prints job<TAB>write, or returns 4
#   companion_poll  <C> <job> <idle> <sec> → returns 0 done | 4 failed | 124 hung | 6 status-lost
#   companion_result <C> <job>             → prints result (retried), or returns 4
#
# Error-handling contract: a companion that cannot answer `status` 4 times in a row
# is declared lost (6) instead of being polled forever; an empty `result` is fetched
# once more before being declared a failure. Hangs are cancelled by the poll itself.

progress_init() {
  if ! { true >&3; } 2>/dev/null; then exec 3>&1; fi
}

progress() { printf '%s\n' "$*" >&3; }

write_lock_path() {
  local workspace git_dir
  workspace=$(pwd -P)
  if git_dir=$(git rev-parse --git-dir 2>/dev/null); then
    case "$git_dir" in
      /*) ;;
      *) git_dir="$workspace/$git_dir" ;;
    esac
    printf '%s/maestro-write.lock' "$(cd "$git_dir" && pwd -P)"
  else
    printf '%s/.maestro-write.lock' "$workspace"
  fi
}

write_lock_metadata_value() {
  local metadata="$1" field="$2"
  sed -n "s/^${field}=//p" "$metadata" 2>/dev/null | head -1
}

companion_workspace_writers() {
  local C="$1" status parsed rc
  if ! status=$(node "$C" status --all --json 2>/dev/null); then
    return 4
  fi
  [ -n "${status//[[:space:]]/}" ] || return 4

  parsed=$(printf '%s\n' "$status" | awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN {
      first = ""
      last = ""
      seen_running = 0
      closed_running = 0
      in_running = 0
      depth = 0
      bad = 0
    }
    {
      line = $0
      stripped = trim(line)
      if (stripped != "") {
        if (first == "") first = stripped
        last = stripped
      }

      if (!in_running) {
        if (line ~ /^[[:space:]]*"running"[[:space:]]*:[[:space:]]*\[[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
          seen_running = 1
          closed_running = 1
        } else if (line ~ /^[[:space:]]*"running"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
          seen_running = 1
          in_running = 1
        }
        next
      }

      if (depth == 0 && line ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
        in_running = 0
        closed_running = 1
        next
      }

      if (line ~ /\{[[:space:]]*$/) {
        depth++
        if (depth == 1) {
          job_id = ""
          write_flag = ""
        }
        next
      }

      if (line ~ /^[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/) {
        if (depth == 1) {
          if (job_id == "" || write_flag == "") {
            bad = 1
          } else {
            print job_id, write_flag
          }
        }
        depth--
        if (depth < 0) bad = 1
        next
      }

      if (depth == 1 && line ~ /^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
        value = line
        sub(/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/"[[:space:]]*,?[[:space:]]*$/, "", value)
        job_id = value
      } else if (depth == 1 && line ~ /^[[:space:]]*"write"[[:space:]]*:[[:space:]]*(true|false)[[:space:]]*,?[[:space:]]*$/) {
        value = line
        sub(/^[[:space:]]*"write"[[:space:]]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]*,?[[:space:]]*$/, "", value)
        write_flag = value
      }
    }
    END {
      if (first != "{" || last != "}" || !seen_running || !closed_running || in_running || depth != 0 || bad) {
        exit 4
      }
    }
  ')
  rc=$?
  [ "$rc" -eq 0 ] || return 4
  [ -n "$parsed" ] && printf '%s\n' "$parsed"
  return 0
}

write_lock_workspace_writers() {
  local companion
  companion=$(companion_resolve) || return 4
  companion_workspace_writers "$companion"
}

write_lock_acquire() {
  local requested_job="${1:-unknown}" metadata recorded_token owner_pid owner_start
  local owner_job started_epoch current_start held now attempt token process_start
  local writers writers_rc
  MAESTRO_LOCK_ACQUIRED=0
  MAESTRO_LOCK_DIR=$(write_lock_path) || return 3
  metadata="$MAESTRO_LOCK_DIR/metadata"

  if [ -n "${MAESTRO_LOCK_TOKEN:-}" ] && [ -f "$metadata" ]; then
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    if [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ]; then
      export MAESTRO_LOCK_DIR
      return 0
    fi
  fi

  attempt=0
  while [ "$attempt" -lt 2 ]; do
    if mkdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
      token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      process_start=$(ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      if [ -z "$process_start" ]; then
        rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null || :
        progress "MAESTRO_LOCK: could not determine process start identity for pid=$$"
        return 3
      fi
      now=$(date +%s)
      if ! printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nstarted_at=%s\nstarted_epoch=%s\n' \
        "$token" "$$" "$process_start" "$requested_job" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$now" > "$metadata"; then
        rm -f "$metadata" 2>/dev/null || :
        rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null || :
        return 3
      fi
      MAESTRO_LOCK_TOKEN="$token"
      MAESTRO_LOCK_ACQUIRED=1
      export MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR
      return 0
    fi

    if [ ! -d "$MAESTRO_LOCK_DIR" ]; then
      progress "MAESTRO_LOCK: could not create write lock at $MAESTRO_LOCK_DIR"
      return 3
    fi

    if [ ! -f "$metadata" ]; then
      progress "MAESTRO_LOCK: write dispatch blocked by an initializing owner (job=unknown pid=unknown held=unknown, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    owner_pid=$(write_lock_metadata_value "$metadata" pid)
    owner_start=$(write_lock_metadata_value "$metadata" process_start)
    owner_job=$(write_lock_metadata_value "$metadata" job_id)
    started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
    owner_job=${owner_job:-unknown}
    current_start=""
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      current_start=$(ps -o lstart= -p "$owner_pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    fi

    if [ -n "$current_start" ] && [ "$current_start" = "$owner_start" ]; then
      case "$started_epoch" in
        ''|*[!0-9]*) held="unknown" ;;
        *)
          now=$(date +%s)
          held=$((now - started_epoch))
          [ "$held" -lt 0 ] && held=0
          held="${held}s"
          ;;
      esac
      progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job pid=${owner_pid:-unknown} for $held (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    writers=$(write_lock_workspace_writers)
    writers_rc=$?
    if [ "$writers_rc" -eq 4 ]; then
      progress "MAESTRO_LOCK: dispatcher is gone but job liveness could not be determined; write lock retained (job=$owner_job pid=${owner_pid:-unknown}, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    if [ "$owner_job" != "unknown" ]; then
      if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
        progress "MAESTRO_LOCK: write dispatch blocked; lease retained because orphaned job=$owner_job is still running (lock: $MAESTRO_LOCK_DIR)"
        return 11
      fi
    elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
      progress "MAESTRO_LOCK: write dispatch blocked; lease retained because an unidentified write-capable job is still running (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    if rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" 2>/dev/null &&
      rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
      progress "MAESTRO_LOCK: broke stale write lock held by job=$owner_job pid=${owner_pid:-unknown}"
      attempt=$((attempt + 1))
      continue
    fi

    case "$started_epoch" in
      ''|*[!0-9]*) held="unknown" ;;
      *)
        now=$(date +%s)
        held=$((now - started_epoch))
        [ "$held" -lt 0 ] && held=0
        held="${held}s"
        ;;
    esac
    progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job pid=${owner_pid:-unknown} for $held (lock: $MAESTRO_LOCK_DIR)"
    return 11
  done

  progress "MAESTRO_LOCK: write dispatch blocked by a competing acquirer (job=unknown pid=unknown held=unknown, lock: $MAESTRO_LOCK_DIR)"
  return 11
}

write_lock_set_job() {
  local job="$1" metadata next_metadata recorded_token owner_pid owner_start started_at started_epoch
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || {
    [ -n "${MAESTRO_LOCK_TOKEN:-}" ] || return 0
  }
  metadata="${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"
  [ -f "$metadata" ] || return 0
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || return 0
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  owner_start=$(write_lock_metadata_value "$metadata" process_start)
  started_at=$(write_lock_metadata_value "$metadata" started_at)
  started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
  next_metadata="${MAESTRO_LOCK_DIR}/metadata.new"
  if printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nstarted_at=%s\nstarted_epoch=%s\n' \
    "$recorded_token" "$owner_pid" "$owner_start" "$job" "$started_at" "$started_epoch" > "$next_metadata"; then
    mv -f "$next_metadata" "$metadata"
  else
    rm -f "$next_metadata" 2>/dev/null || :
    return 3
  fi
}

write_lock_release() {
  local metadata recorded_token owner_job writers writers_rc
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_LOCK_DIR:-}/metadata"
  [ -n "${MAESTRO_LOCK_DIR:-}" ] && [ -f "$metadata" ] || return 0
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || return 0
  owner_job=$(write_lock_metadata_value "$metadata" job_id)
  owner_job=${owner_job:-unknown}

  writers=$(write_lock_workspace_writers)
  writers_rc=$?
  if [ "$writers_rc" -eq 4 ]; then
    progress "MAESTRO_LOCK: job liveness could not be determined; write lease retained (job=$owner_job, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi
  if [ "$owner_job" != "unknown" ]; then
    if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
      progress "MAESTRO_LOCK: write lease retained because job $owner_job is still running; a later dispatch will resolve it (lock: $MAESTRO_LOCK_DIR)"
      return 0
    fi
  elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
    progress "MAESTRO_LOCK: write lease retained because an unidentified write-capable job is still running; a later dispatch will resolve it (lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi

  rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" 2>/dev/null || return 0
  rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null || :
  MAESTRO_LOCK_ACQUIRED=0
}

companion_resolve() {
  local c
  c=$(ls -dt "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | head -1)
  if [ -z "$c" ] || [ ! -f "$c" ]; then
    return 3
  fi
  printf '%s' "$c"
}

companion_pin() {
  local here selector pin
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  selector="$here/codex-model-select.sh"
  if ! pin=$(bash "$selector" --pin 2>/dev/null); then
    echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <effort>" >&2
    return 3
  fi
  printf '%s\n' "$pin"
}

companion_start() {
  local C="$1" PROMPT="$2" WRITE="${3:-}"
  local PIN MODEL EFFORT
  PIN=$(companion_pin) || return 3
  MODEL=${PIN%%$'\t'*}
  EFFORT=${PIN#*$'\t'}
  local -a args=(task --background)
  [ "$WRITE" = "write" ] && args+=(--write)
  args+=(--model "$MODEL" --effort "$EFFORT")
  local START JOB
  START=$(node "$C" "${args[@]}" "$PROMPT" 2>&1)
  JOB=$(printf '%s' "$START" | grep -oE 'task-[a-z0-9]+-[a-z0-9]+' | head -1)
  if [ -z "$JOB" ]; then
    printf 'could not start Codex job. Output: %s' "$START" >&2
    return 3
  fi
  printf '%s' "$JOB"
}

companion_verify_pin() {
  local C="$1" JOB="$2" EXPECTED_MODEL="$3" EXPECTED_EFFORT="$4"
  local ST REQUEST MODEL_FIELD EFFORT_FIELD RECORDED_MODEL="null" RECORDED_EFFORT="null"
  ST=$(node "$C" status "$JOB" --json 2>/dev/null)
  REQUEST=$(printf '%s' "$ST" | tr '\n' ' ' | sed -n 's/.*"request"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' | head -1)
  MODEL_FIELD=$(printf '%s' "$REQUEST" | grep -oE '"model"[[:space:]]*:[[:space:]]*(null|"[^"]*")' | head -1)
  EFFORT_FIELD=$(printf '%s' "$REQUEST" | grep -oE '"effort"[[:space:]]*:[[:space:]]*(null|"[^"]*")' | head -1)
  if [ -n "$MODEL_FIELD" ]; then
    RECORDED_MODEL=$(printf '%s' "$MODEL_FIELD" | sed -E 's/^"model"[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//')
  fi
  if [ -n "$EFFORT_FIELD" ]; then
    RECORDED_EFFORT=$(printf '%s' "$EFFORT_FIELD" | sed -E 's/^"effort"[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//')
  fi
  if [ "$RECORDED_MODEL" = "$EXPECTED_MODEL" ] && [ "$RECORDED_EFFORT" = "$EXPECTED_EFFORT" ]; then
    return 0
  fi
  echo "Codex pin verification warning for $JOB: requested model=$EXPECTED_MODEL effort=$EXPECTED_EFFORT; recorded model=$RECORDED_MODEL effort=$RECORDED_EFFORT" >&2
  return 4
}

companion_poll() {
  local C="$1" JOB="$2" MAX_IDLE="$3" POLL="$4"
  local LOG="" last_size=-1 idle=0 sfails=0
  local last_phase="__MAESTRO_UNSET__" last_preview="" quiet=0 keepalive_size=0
  local ST state size phase elapsed preview preview_emit preview_json emitted line growth
  while :; do
    sleep "$POLL"
    ST=$(node "$C" status "$JOB" --json 2>/dev/null)
    if [ -z "$ST" ]; then
      sfails=$((sfails + 1))
      if [ "$sfails" -ge 4 ]; then
        printf 'companion status unreachable 4x in a row; giving up on %s' "$JOB" >&2
        return 6
      fi
      continue
    fi
    sfails=0
    state=$(printf '%s' "$ST" | grep -oiE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' | head -1 | grep -oiE '[a-z]+"$' | tr -d '"')
    [ -z "$LOG" ] && LOG=$(printf '%s' "$ST" | sed -n 's/.*"logFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    phase=$(printf '%s' "$ST" | grep -oE '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"phase"[[:space:]]*:[[:space:]]*"//; s/"$//')
    elapsed=$(printf '%s' "$ST" | grep -oE '"elapsed"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"elapsed"[[:space:]]*:[[:space:]]*"//; s/"$//')
    preview_json=$(printf '%s' "$ST" | tr '\n' ' ' | sed -n 's/.*"progressPreview"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -1)
    preview=$(printf '%s' "$preview_json" |
      grep -oE '"([^"\\]|\\.)*"' |
      sed -E 's/^"//; s/"$//; s/\\"/"/g; s/\\\\/\\/g; s/^[[:space:]]*//; s/[[:space:]]*$//' |
      sed '/^$/d')

    size=0
    [ -n "$LOG" ] && [ -f "$LOG" ] && size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    quiet=$((quiet + POLL))
    emitted=0
    if [ "$phase" != "$last_phase" ]; then
      if [ -n "$phase" ]; then
        progress "CODEX: job=$JOB phase=$phase elapsed=${elapsed:-unknown}"
        emitted=1
      fi
      last_phase="$phase"
    fi
    if [ "$preview" != "$last_preview" ]; then
      preview_emit=$(
        awk '
          FNR == NR {
            prev[++prev_len] = $0
            next
          }
          {
            cur[++cur_len] = $0
          }
          END {
            max_overlap = prev_len < cur_len ? prev_len : cur_len
            overlap = 0
            for (k = max_overlap; k > 0; k--) {
              matches = 1
              for (i = 1; i <= k; i++) {
                if (prev[prev_len - k + i] != cur[i]) {
                  matches = 0
                  break
                }
              }
              if (matches) {
                overlap = k
                break
              }
            }
            for (i = overlap + 1; i <= cur_len; i++) {
              print cur[i]
            }
          }
        ' <(printf '%s\n' "$last_preview" | head -4) \
          <(printf '%s\n' "$preview" | head -4)
      )
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${#line}" -gt 160 ]; then
          line="${line:0:159}…"
        fi
        progress "CODEX: job=$JOB $line"
        emitted=1
      done <<< "$preview_emit"
      last_preview="$preview"
    fi
    if [ "$emitted" -eq 1 ]; then
      quiet=0
    elif [ "$quiet" -ge 60 ]; then
      growth=$((size - keepalive_size))
      [ "$growth" -lt 0 ] && growth=0
      progress "CODEX-ALIVE: job=$JOB elapsed=${elapsed:-unknown} log_growth=${growth}B"
      keepalive_size=$size
      quiet=0
    fi

    case "$state" in
      completed|done|finished|succeeded|success)
        return 0 ;;
      failed|error|errored|cancelled|canceled)
        printf 'job %s ended in state %s' "$JOB" "${state:-unknown}" >&2
        return 4 ;;
    esac

    if [ "$size" -gt "$last_size" ]; then
      last_size=$size; idle=0
    else
      idle=$((idle + POLL))
    fi

    if [ "$idle" -ge "$MAX_IDLE" ]; then
      node "$C" cancel "$JOB" >/dev/null 2>&1
      printf 'job %s stalled for %ss (no log growth); cancelled' "$JOB" "$MAX_IDLE" >&2
      return 124
    fi
  done
}

companion_result() {
  local C="$1" JOB="$2"
  local OUT
  OUT=$(node "$C" result "$JOB" 2>/dev/null)
  if [ -z "${OUT//[[:space:]]/}" ]; then
    sleep 3
    OUT=$(node "$C" result "$JOB" 2>/dev/null)
  fi
  if [ -z "${OUT//[[:space:]]/}" ]; then
    printf 'job %s returned an empty result twice' "$JOB" >&2
    return 4
  fi
  printf '%s\n' "$OUT"
}
