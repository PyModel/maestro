#!/usr/bin/env bash
# Maestro companion library — shared Codex companion plumbing for the hook scripts.
# Sourced, not executed. All functions assume `set -uo pipefail` in the caller.

_MAESTRO_COMPANION_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-process.sh
. "$_MAESTRO_COMPANION_HERE/lib-process.sh"
# shellcheck source=lib-job-lock.sh
. "$_MAESTRO_COMPANION_HERE/lib-job-lock.sh"
# Interface:
#   companion_turn MODE PROMPT_FILE MAX_IDLE POLL RESULT_FILE PROFILE_FILE EVIDENCE_FILE LIFECYCLE_FN
#   companion_interrupt SIGNAL JOB_OR_EMPTY EVIDENCE_FILE LIFECYCLE_FN
#   companion_writers RESULT_FILE EVIDENCE_FILE
#
# MODE is explicit `read` or `write`. Lifecycle events are `guard`, `started`,
# `tick`, `cancel-begin`, `cancel-end`, and `current-job`; read callers use `:`.
# Exit codes plus caller-owned files are the only outcome interface.
#
# Error-handling contract: a companion that cannot answer `status` 4 times in a row
# is cancelled instead of being polled forever; an empty `result` is fetched once
# more before being declared a failure. Hangs are cancelled by the poll itself.



# This is the companion wrapper's allowlist, not the Codex binary's. The wrapper
# is narrower: Codex also accepts max and ultra when it reads effort from config.
COMPANION_WRAPPER_REASONING_EFFORTS=(none minimal low medium high xhigh)

companion_wrapper_accepts_effort() {
  local candidate="$1" allowed
  for allowed in "${COMPANION_WRAPPER_REASONING_EFFORTS[@]}"; do
    [ "$candidate" = "$allowed" ] && return 0
  done
  return 1
}


companion_version_is_newer() { # candidate current
  awk -v left="$1" -v right="$2" '
    BEGIN {
      sub(/^v/, "", left)
      sub(/^v/, "", right)
      left_count = split(left, left_dash, "-")
      right_count = split(right, right_dash, "-")
      left_base = left_dash[1]
      right_base = right_dash[1]
      left_n = split(left_base, left_parts, ".")
      right_n = split(right_base, right_parts, ".")
      max = left_n > right_n ? left_n : right_n
      for (i = 1; i <= max; i++) {
        l = i <= left_n ? left_parts[i] : 0
        r = i <= right_n ? right_parts[i] : 0
        if (l !~ /^[0-9]+$/ || r !~ /^[0-9]+$/) {
          exit left > right ? 0 : 1
        }
        if ((l + 0) != (r + 0)) exit (l + 0) > (r + 0) ? 0 : 1
      }
      left_pre = left_count > 1 ? substr(left, length(left_base) + 2) : ""
      right_pre = right_count > 1 ? substr(right, length(right_base) + 2) : ""
      if (left_pre == "" && right_pre != "") exit 0
      if (left_pre != "" && right_pre == "") exit 1
      exit left_pre > right_pre ? 0 : 1
    }
  '
}
companion_call() { # stdout-file stderr-file [--tick fn] companion args...
  local out="${1-}" err="${2-}" tick=:
  local C timeout="${MAESTRO_COMPANION_TIMEOUT_SEC-120}"
  local rc invalid=0
  [ -n "$out" ] && [ -n "$err" ] && [ "$out" != "$err" ] || return 3
  shift 2 2>/dev/null || return 3
  if [ "${1-}" = --tick ]; then
    [ $# -ge 3 ] || return 3
    tick="$2"
    shift 2
  fi
  C="${1-}"
  [ -n "$C" ] || return 3
  shift
  case "$timeout" in
    ''|*[!0-9]*) invalid=1 ;;
    *) [ "$timeout" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_COMPANION: ignoring invalid timeout_seconds=$timeout; using 120s"
    timeout=120
  fi
  process_run_bounded "$timeout" MAESTRO_COMPANION "$tick" "$out" "$err" -- \
    node "$C" "$@"
  rc=$?
  return "$rc"
}

companion_workspace_writers() { # companion stdout-file stderr-file
  local C="$1" out="$2" err="$3" status parsed rc
  parsed="${out}.parsed"
  CODEX_COMPANION_SESSION_ID='' companion_call "$out" "$err" \
    "$C" status --all --json
  rc=$?
  [ "$rc" -eq 0 ] || return 4
  status=$(cat "$out")
  [ -n "${status//[[:space:]]/}" ] || return 4

  printf '%s\n' "$status" | node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => {
      try {
        const value = JSON.parse(input);
        if (!value || typeof value !== "object" || Array.isArray(value) ||
            !Array.isArray(value.running)) process.exit(4);
        for (const job of value.running) {
          if (!job || typeof job !== "object" || Array.isArray(job) ||
              typeof job.id !== "string" || !/^task-[a-z0-9][a-z0-9-]*[a-z0-9]$/.test(job.id) ||
              typeof job.write !== "boolean") process.exit(4);
          process.stdout.write(`${job.id}\t${job.write}\n`);
        }
      } catch {
        process.exit(4);
      }
    });
  ' > "$parsed" 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$parsed"
    return 4
  fi
  mv -f "$parsed" "$out" || return 4
  return 0
}

companion_resolve() {
  local base candidate version best="" best_version=""
  base="$HOME/.claude/plugins/cache/openai-codex/codex"
  for candidate in "$base"/*/scripts/codex-companion.mjs; do
    [ -f "$candidate" ] || continue
    version=${candidate#"$base"/}
    version=${version%%/*}
    if [ -z "$best" ] || companion_version_is_newer "$version" "$best_version"; then
      best=$candidate
      best_version=$version
    fi
  done
  [ -n "$best" ] || return 3
  printf '%s' "$best"
}

companion_pin() {
  local here selector pin model efforts debate_effort impl_effort
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  selector="$here/codex-model-select.sh"
  if ! pin=$(bash "$selector" --pin 2>/dev/null); then
    echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <debate-effort> <impl-effort>" >&2
    return 3
  fi
  case "$pin" in
    *$'\t'*$'\t'*) ;;
    *)
      echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <debate-effort> <impl-effort>" >&2
      return 3 ;;
  esac
  model=${pin%%$'\t'*}
  efforts=${pin#*$'\t'}
  debate_effort=${efforts%%$'\t'*}
  impl_effort=${efforts#*$'\t'}
  if [ -z "$model" ] || [ -z "$debate_effort" ] || [ -z "$impl_effort" ]; then
    echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <debate-effort> <impl-effort>" >&2
    return 3
  fi
  if ! companion_wrapper_accepts_effort "$impl_effort"; then
    echo "unsupported implementation effort '$impl_effort' — choose none|minimal|low|medium|high|xhigh; max/ultra are debate-only" >&2
    return 3
  fi
  printf '%s\t%s\t%s\n' "$model" "$debate_effort" "$impl_effort"
}

companion_start() { # companion prompt mode model effort lifecycle job-file stdout stderr
  local C="$1" PROMPT="$2" mode="$3" MODEL="$4" EFFORT="$5"
  local lifecycle="$6" job_file="$7" out="$8" err="$9"
  local HELP TASK_HELP guard_rc START JOB START_RC
  case "$mode" in read|write) ;; *) return 3 ;; esac
  if [ "$mode" = "write" ]; then
    # Compatibility probe, not an authorization check: only a help text that
    # describes `task` WITHOUT --write proves drift. Anything inconclusive
    # (empty, error, no synopsis) must not block a dispatch.
    companion_call "$out" "$err" --tick "$lifecycle" "$C" --help
    if [ "$?" -eq 0 ]; then
      HELP=$( { cat "$out"; cat "$err"; } )
    else
      HELP=""
    fi
    TASK_HELP=$(printf '%s\n' "$HELP" |
      grep -E '(^|[[:space:]])task([[:space:]]|$)' | head -1)
    if [ -n "$TASK_HELP" ]; then
      case "$TASK_HELP" in
        *--write*) ;;
        *)
          echo "companion at $C describes its task subcommand without --write — the plugin may have renamed the flag (README: Plugin flag drift). Refusing to dispatch a write job blind; update Maestro or pin the previous plugin version." >&2
          return 3 ;;
      esac
    fi
  fi
  local -a args=(task --background)
  [ "$mode" = "write" ] && args+=(--write)
  args+=(--model "$MODEL")
  if [ "$mode" = "write" ]; then
    if ! companion_wrapper_accepts_effort "$EFFORT"; then
      echo "companion cannot express implementation effort=$EFFORT; refusing to silently substitute the debate tier" >&2
      return 3
    fi
    args+=(--effort "$EFFORT")
  elif companion_wrapper_accepts_effort "$EFFORT"; then
    args+=(--effort "$EFFORT")
  else
    progress "CODEX: companion wrapper cannot express debate effort=$EFFORT explicitly; the pinned top-level config value governs this read-only dispatch"
  fi
  "$lifecycle" guard unknown dispatch ""
  guard_rc=$?
  [ "$guard_rc" -eq 0 ] || return "$guard_rc"
  companion_call "$out" "$err" --tick "$lifecycle" "$C" \
    "${args[@]}" "$PROMPT"
  START_RC=$?
  START=$( { cat "$out"; cat "$err"; } )
  if [ "$START_RC" -ne 0 ]; then
    printf 'could not start Codex job (exit %s). Output: %s' "$START_RC" "$START" >&2
    return 3
  fi
  JOB=$(printf '%s' "$START" | grep -oE 'task-[a-z0-9][a-z0-9-]*[a-z0-9]' | head -1)
  if [ -z "$JOB" ]; then
    printf 'could not start Codex job. Output: %s' "$START" >&2
    return 3
  fi
  printf '%s\n' "$JOB" > "$job_file" || return 3
}

companion_verify_pin() { # companion job model effort lifecycle stdout stderr
  local C="$1" JOB="$2" EXPECTED_MODEL="$3" EXPECTED_EFFORT="$4"
  local lifecycle="$5" out="$6" err="$7" ST REQUEST
  local MODEL_FIELD EFFORT_FIELD WRITE_FIELD
  local RECORDED_MODEL="null" RECORDED_EFFORT="null" RECORDED_WRITE=""
  companion_call "$out" "$err" --tick "$lifecycle" \
    "$C" status "$JOB" --json
  ST=$(cat "$out")
  REQUEST=$(printf '%s' "$ST" | tr '\n' ' ' | sed -n 's/.*"request"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' | head -1)
  MODEL_FIELD=$(printf '%s' "$REQUEST" | grep -oE '"model"[[:space:]]*:[[:space:]]*(null|"[^"]*")' | head -1)
  EFFORT_FIELD=$(printf '%s' "$REQUEST" | grep -oE '"effort"[[:space:]]*:[[:space:]]*(null|"[^"]*")' | head -1)
  WRITE_FIELD=$(printf '%s' "$REQUEST" | grep -oE '"write"[[:space:]]*:[[:space:]]*(true|false)' | head -1)
  if [ -n "$MODEL_FIELD" ]; then
    RECORDED_MODEL=$(printf '%s' "$MODEL_FIELD" | sed -E 's/^"model"[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//')
  fi
  if [ -n "$EFFORT_FIELD" ]; then
    RECORDED_EFFORT=$(printf '%s' "$EFFORT_FIELD" | sed -E 's/^"effort"[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//')
  fi
  if [ -n "$WRITE_FIELD" ]; then
    RECORDED_WRITE=$(printf '%s' "$WRITE_FIELD" | sed -E 's/^"write"[[:space:]]*:[[:space:]]*//')
  fi
  if [ "$RECORDED_MODEL" = "$EXPECTED_MODEL" ] &&
    [ "$RECORDED_EFFORT" = "$EXPECTED_EFFORT" ]; then
    return 0
  fi
  if [ "$RECORDED_MODEL" = "$EXPECTED_MODEL" ] &&
    [ -n "$EFFORT_FIELD" ] && [ "$RECORDED_EFFORT" = "null" ] &&
    [ "$RECORDED_WRITE" = false ]; then
    return 0
  fi
  echo "Codex pin verification warning for $JOB: requested model=$EXPECTED_MODEL effort=$EXPECTED_EFFORT; recorded model=$RECORDED_MODEL effort=$RECORDED_EFFORT" >&2
  return 4
}

companion_poll_bounds_valid() { # max_idle poll
  local max_idle="$1" poll="$2"
  case "$max_idle" in ''|*[!0-9]*) return 1 ;; esac
  case "$poll" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$max_idle))" -ge 1 ] && [ "$((10#$poll))" -ge 1 ]
}

companion_dispatch_budget() { # write|read
  local mode="$1" value invalid=0
  if [ "${MAESTRO_MAX_DISPATCH_SEC+x}" = x ]; then
    value=$MAESTRO_MAX_DISPATCH_SEC
  elif [ "$mode" = write ]; then
    value=2400
  else
    value=1200
  fi
  case "$value" in
    ''|*[!0-9]*) invalid=1 ;;
    *) [ "$value" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_POLL: ignoring invalid MAESTRO_MAX_DISPATCH_SEC=$value; using 1200s"
    value=1200
  else
    value=$((10#$value))
  fi
  printf '%s\n' "$value"
}

companion_cancel_fact_write() { # file job reason request source
  local file="$1" job="$2" reason="$3" request="$4" source="$5" tmp
  [ -n "$file" ] || return 0
  tmp="${file}.new"
  {
    printf 'job=%s\n' "$job"
    printf 'reason=%s\n' "$reason"
    printf 'request=%s\n' "$request"
    printf 'source=%s\n' "$source"
  } > "$tmp" && mv -f "$tmp" "$file"
}

companion_cancel_fact_value() { # file field
  local file="$1" field="$2"
  case "$field" in job|reason|request|source) ;; *) return 1 ;; esac
  sed -n "s/^${field}=//p" "$file" 2>/dev/null | head -1
}

companion_cancel_job() { # C JOB REASON LOG MODE FACT LIFECYCLE STDOUT STDERR
  local C="$1" JOB="$2" REASON="$3" log="$4" mode="${5:-read}"
  local fact="${6:-}" lifecycle="${7:-:}" out="${8-}" err="${9-}"
  local crc request=unconfirmed lifecycle_rc=0
  case "$mode" in read|write) ;; *) return 3 ;; esac
  if ! "$lifecycle" cancel-begin "$JOB" "$REASON" "$log"; then
    companion_cancel_fact_write "$fact" "$JOB" "$REASON" not-attempted request || :
    [ "$mode" = write ] && return 125
    return 4
  fi
  companion_call "$out" "$err" --tick "$lifecycle" "$C" cancel "$JOB"
  crc=$?
  [ "$crc" -ne 0 ] || request=acknowledged
  progress "MAESTRO_POLL: cancel attempted reason=$REASON job=$JOB log=${log:-unknown}"
  "$lifecycle" cancel-end "$JOB" "$REASON" "$log" || lifecycle_rc=$?
  if ! companion_cancel_fact_write "$fact" "$JOB" "$REASON" "$request" request; then
    progress "MAESTRO_POLL: could not persist cancellation fact for job=$JOB"
    [ "$mode" = write ] && return 125
    return 4
  fi
  [ "$lifecycle_rc" -eq 0 ] || {
    [ "$mode" = write ] && return 125
    return 4
  }
  [ "$mode" = write ] && return 125
  return 124
}

companion_poll() {
  local C="$1" JOB="$2" MAX_IDLE="$3" POLL="$4"
  local poll_started="${5:-$SECONDS}" mode="${6:-read}"
  local cancel_fact="${7:-}" lifecycle="${8:-:}"
  local out="${9-}" err="${10-}"
  case "$mode" in read|write) ;; *) return 3 ;; esac
  [ -z "$cancel_fact" ] || rm -f "$cancel_fact" "${cancel_fact}.new"
  if ! companion_poll_bounds_valid "$MAX_IDLE" "$POLL"; then
    progress "MAESTRO_POLL: max_idle and poll must be positive integers (max_idle=$MAX_IDLE poll=$POLL)"
    return 3
  fi
  MAX_IDLE=$((10#$MAX_IDLE))
  POLL=$((10#$POLL))
  local LOG="" last_size=-1 sfails=0 MAX_TOTAL total midpoint warned=0
  local last_phase="__MAESTRO_UNSET__" last_preview="" quiet=0 keepalive_size=0
  local last_activity="$poll_started" idle_elapsed=0 sleep_for remaining_total remaining_idle
  local configured_call_timeout call_timeout invalid_call_timeout=0
  local ST state status_compact size phase elapsed preview preview_emit preview_json emitted line growth status_rc
  MAX_TOTAL=$(companion_dispatch_budget "$mode")
  configured_call_timeout=${MAESTRO_COMPANION_TIMEOUT_SEC-120}
  case "$configured_call_timeout" in
    ''|*[!0-9]*) invalid_call_timeout=1 ;;
    *) [ "$configured_call_timeout" -ge 1 ] 2>/dev/null || invalid_call_timeout=1 ;;
  esac
  if [ "$invalid_call_timeout" -eq 1 ]; then
    progress "MAESTRO_COMPANION: ignoring invalid timeout_seconds=$configured_call_timeout; using 120s"
    configured_call_timeout=120
  else
    configured_call_timeout=$((10#$configured_call_timeout))
  fi
  midpoint=$((MAX_TOTAL / 2))
  [ "$midpoint" -ge 1 ] || midpoint=1
  while :; do
    total=$((SECONDS - poll_started))
    [ "$total" -ge 0 ] || total=0
    idle_elapsed=$((SECONDS - last_activity))
    [ "$idle_elapsed" -ge 0 ] || idle_elapsed=0
    remaining_total=$((MAX_TOTAL - total))
    remaining_idle=$((MAX_IDLE - idle_elapsed))
    sleep_for=$POLL
    if [ "$remaining_total" -le 0 ]; then
      sleep_for=0
    elif [ "$sleep_for" -gt "$remaining_total" ]; then
      sleep_for=$remaining_total
    fi
    if [ "$last_size" -ge 0 ]; then
      if [ "$remaining_idle" -le 0 ]; then
        sleep_for=0
      elif [ "$sleep_for" -gt "$remaining_idle" ]; then
        sleep_for=$remaining_idle
      fi
    fi
    [ "$sleep_for" -eq 0 ] || sleep "$sleep_for"
    "$lifecycle" tick "$JOB" "" || :
    total=$((SECONDS - poll_started))
    [ "$total" -ge 0 ] || total=0
    remaining_total=$((MAX_TOTAL - total))
    if [ "$remaining_total" -le 0 ]; then call_timeout=1; else call_timeout=$remaining_total; fi
    [ "$call_timeout" -le "$configured_call_timeout" ] || call_timeout=$configured_call_timeout
    MAESTRO_COMPANION_TIMEOUT_SEC="$call_timeout" \
      companion_call "$out" "$err" --tick "$lifecycle" \
      "$C" status "$JOB" --json
    status_rc=$?
    ST=$(cat "$out")
    total=$((SECONDS - poll_started))
    [ "$total" -ge 0 ] || total=0
    if [ "$status_rc" -ne 0 ] || [ -z "$ST" ]; then
      sfails=$((sfails + 1))
      if [ "$total" -ge "$MAX_TOTAL" ]; then
        progress "MAESTRO_POLL: hard deadline reached while companion status was unreachable for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" deadline "$LOG" "$mode" \
          "$cancel_fact" "$lifecycle" "$out" "$err"
        return $?
      fi
      if [ "$sfails" -ge 4 ]; then
        progress "MAESTRO_POLL: companion status unreachable ${sfails}x in a row for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" status-lost "$LOG" "$mode" \
          "$cancel_fact" "$lifecycle" "$out" "$err"
        return $?
      fi
      continue
    fi
    state=$(printf '%s' "$ST" | grep -oiE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' | head -1 | grep -oiE '[a-z]+"$' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    status_compact=$(printf '%s' "$ST" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$status_compact" in \{*\}) ;; *) state="" ;; esac
    if [ -z "$state" ]; then
      sfails=$((sfails + 1))
      if [ "$total" -ge "$MAX_TOTAL" ]; then
        progress "MAESTRO_POLL: hard deadline reached while companion status was malformed for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" deadline "$LOG" "$mode" \
          "$cancel_fact" "$lifecycle" "$out" "$err"
        return $?
      fi
      if [ "$sfails" -ge 4 ]; then
        progress "MAESTRO_POLL: companion status malformed or unreachable ${sfails}x in a row for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" status-lost "$LOG" "$mode" \
          "$cancel_fact" "$lifecycle" "$out" "$err"
        return $?
      fi
      continue
    fi
    sfails=0
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
      cancelled|canceled)
        if [ "$mode" = write ]; then
          "$lifecycle" cancel-begin "$JOB" cancelled-observed "$LOG" || :
          "$lifecycle" cancel-end "$JOB" cancelled-observed "$LOG" || :
          progress "MAESTRO_POLL: companion reported job=$JOB state=cancelled; write lease poisoned and no replacement will start"
          companion_cancel_fact_write "$cancel_fact" "$JOB" cancelled-observed \
            not-needed observed || :
          return 125
        fi
        companion_cancel_fact_write "$cancel_fact" "$JOB" cancelled-observed \
          not-needed observed || :
        printf 'job %s ended in state %s' "$JOB" "$state" >&2
        return 4 ;;
      failed|error|errored)
        printf 'job %s ended in state %s' "$JOB" "${state:-unknown}" >&2
        return 4 ;;
    esac

    if [ "$warned" -eq 0 ] && [ "$total" -ge "$midpoint" ]; then
      progress "MAESTRO_BUDGET: job=$JOB crossed the normal budget and remains active; continuing to the ${MAX_TOTAL}s hard ceiling. Activity is not proof of completion."
      warned=1
    fi

    if [ "$size" -gt "$last_size" ]; then
      last_size=$size
      last_activity=$SECONDS
    fi
    idle_elapsed=$((SECONDS - last_activity))
    [ "$idle_elapsed" -ge 0 ] || idle_elapsed=0

    if [ "$total" -ge "$MAX_TOTAL" ]; then
      companion_cancel_job "$C" "$JOB" deadline "$LOG" "$mode" \
        "$cancel_fact" "$lifecycle" "$out" "$err"
      return $?
    fi
    if [ "$idle_elapsed" -ge "$MAX_IDLE" ]; then
      companion_cancel_job "$C" "$JOB" idle "$LOG" "$mode" \
        "$cancel_fact" "$lifecycle" "$out" "$err"
      return $?
    fi
  done
}

companion_result() { # companion job lifecycle result-file stdout stderr
  local C="$1" JOB="$2" lifecycle="$3" result="$4" out="$5" err="$6"
  local OUT rc
  companion_call "$out" "$err" --tick "$lifecycle" "$C" result "$JOB"
  rc=$?
  OUT=$(cat "$out")
  if [ "$rc" -ne 0 ] || [ -z "${OUT//[[:space:]]/}" ]; then
    sleep 3
    companion_call "$out" "$err" --tick "$lifecycle" "$C" result "$JOB"
    rc=$?
    OUT=$(cat "$out")
  fi
  if [ "$rc" -ne 0 ] || [ -z "${OUT//[[:space:]]/}" ]; then
    printf 'job %s returned an empty result twice' "$JOB" >&2
    return 4
  fi
  printf '%s\n' "$OUT" > "$result" || return 4
}

_companion_lifecycle_valid() {
  local lifecycle="${1-}"
  [ "$lifecycle" = : ] && return 0
  [[ "$lifecycle" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] &&
    declare -F "$lifecycle" >/dev/null
}

_companion_profile_write() { # file mode model effort job cancel-reason cancel-request
  local file="$1" mode="$2" model="$3" effort="$4" job="$5"
  local cancel_reason="$6" cancel_request="$7" tmp="${1}.new"
  {
    printf 'mode=%s\n' "$mode"
    printf 'model=%s\n' "$model"
    printf 'effort=%s\n' "$effort"
    printf 'job=%s\n' "$job"
    printf 'cancel_reason=%s\n' "$cancel_reason"
    printf 'cancel_request=%s\n' "$cancel_request"
  } > "$tmp" && mv -f "$tmp" "$file"
}

_companion_turn_cleanup() { # profile-file
  local profile="$1"
  rm -f "${profile}.job" "${profile}.transport.out" \
    "${profile}.transport.err" "${profile}.cancel" \
    "${profile}.cancel.new" 2>/dev/null || :
  job_lock_release
}

companion_turn() { # mode prompt-file max-idle poll result-file profile-file evidence-file lifecycle
  local mode="${1-}" prompt_file="${2-}" max_idle="${3-}" poll="${4-}"
  local result="${5-}" profile="${6-}" evidence="${7-}" lifecycle="${8-}"
  local prompt C pin efforts model effort job rc derived
  local override_model="${MAESTRO_COMPANION_MODEL-}"
  local override_effort="${MAESTRO_COMPANION_EFFORT-}"
  local override_model_set=0 override_effort_set=0
  local cancel_fact job_file call_out call_err reason=none request=none started
  [ "$#" -eq 8 ] || return 3
  case "$mode" in read|write) ;; *) return 3 ;; esac
  [ -f "$prompt_file" ] || return 3
  companion_poll_bounds_valid "$max_idle" "$poll" || return 3
  _companion_lifecycle_valid "$lifecycle" || return 3
  if { [ "$mode" = write ] && [ "$lifecycle" = : ]; } ||
    { [ "$mode" = read ] && [ "$lifecycle" != : ]; }; then
    return 3
  fi
  [ -n "$result" ] && [ -n "$profile" ] && [ -n "$evidence" ] ||
    return 3
  [ "$result" != "$profile" ] && [ "$result" != "$evidence" ] &&
    [ "$profile" != "$evidence" ] && [ "$prompt_file" != "$result" ] &&
    [ "$prompt_file" != "$profile" ] && [ "$prompt_file" != "$evidence" ] ||
    return 3
  cancel_fact="${profile}.cancel"
  job_file="${profile}.job"
  call_out="${profile}.transport.out"
  call_err="${profile}.transport.err"
  for derived in "$cancel_fact" "${cancel_fact}.new" "$job_file" \
    "$call_out" "$call_err"; do
    [ "$derived" != "$prompt_file" ] && [ "$derived" != "$result" ] &&
      [ "$derived" != "$evidence" ] || return 3
  done
  prompt=$(cat "$prompt_file") || return 3
  : > "$result" || return 3
  : > "$evidence" || return 3
  _companion_turn_cleanup "$profile"
  rm -f "$profile" "${profile}.new" || return 3

  C=$(companion_resolve) || return 3
  pin=$(companion_pin) || return 3
  model=${pin%%$'\t'*}
  efforts=${pin#*$'\t'}
  if [ "$mode" = write ]; then
    effort=${efforts#*$'\t'}
  else
    effort=${efforts%%$'\t'*}
  fi
  [ "${MAESTRO_COMPANION_MODEL+x}" = x ] && override_model_set=1
  [ "${MAESTRO_COMPANION_EFFORT+x}" = x ] && override_effort_set=1
  if [ "$override_model_set" -ne "$override_effort_set" ]; then
    return 3
  fi
  if [ "$override_model_set" -eq 1 ]; then
    [ "$mode" = read ] || return 3
    case "$override_model" in ''|*[!a-zA-Z0-9._-]*) return 3 ;; esac
    companion_wrapper_accepts_effort "$override_effort" || return 3
    model=$override_model
    effort=$override_effort
  fi
  _companion_profile_write "$profile" "$mode" "$model" "$effort" \
    unknown none none || return 3

  job_lock_acquire "$mode"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _companion_turn_cleanup "$profile"
    return "$rc"
  fi
  started=$SECONDS
  companion_start "$C" "$prompt" "$mode" "$model" "$effort" \
    "$lifecycle" "$job_file" "$call_out" "$call_err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _companion_turn_cleanup "$profile"
    return "$rc"
  fi
  job=$(cat "$job_file")
  job_lock_publish_job "$job"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    "$lifecycle" started "$job" dispatch ""
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    _companion_profile_write "$profile" "$mode" "$model" "$effort" \
      "$job" none none || rc=3
  fi
  if [ "$rc" -ne 0 ]; then
    companion_cancel_job "$C" "$job" launch-publication-failed startup \
      "$mode" "$cancel_fact" "$lifecycle" "$call_out" "$call_err" || :
    if [ -f "$cancel_fact" ]; then
      reason=$(companion_cancel_fact_value "$cancel_fact" reason)
      request=$(companion_cancel_fact_value "$cancel_fact" request)
    fi
    _companion_profile_write "$profile" "$mode" "$model" "$effort" \
      "$job" "${reason:-unknown}" "${request:-unknown}" || :
    _companion_turn_cleanup "$profile"
    [ "$mode" = write ] && return 125
    return 4
  fi
  if [ "$mode" = read ]; then
    progress "CODEX: started $job (model=$model effort=$effort, read mode, max_idle=${max_idle}s poll=${poll}s)"
  fi
  companion_verify_pin "$C" "$job" "$model" "$effort" "$lifecycle" \
    "$call_out" "$call_err" || :

  companion_poll "$C" "$job" "$max_idle" "$poll" "$started" \
    "$mode" "$cancel_fact" "$lifecycle" "$call_out" "$call_err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if ! companion_result "$C" "$job" "$lifecycle" "$result" \
      "$call_out" "$call_err"; then
      _companion_turn_cleanup "$profile"
      return 4
    fi
    _companion_turn_cleanup "$profile"
    return 0
  fi
  if [ -f "$cancel_fact" ]; then
    reason=$(companion_cancel_fact_value "$cancel_fact" reason)
    request=$(companion_cancel_fact_value "$cancel_fact" request)
  fi
  _companion_profile_write "$profile" "$mode" "$model" "$effort" \
    "$job" "${reason:-unknown}" "${request:-unknown}" || :
  _companion_turn_cleanup "$profile"
  return "$rc"
}

companion_interrupt() { # signal job-or-empty evidence-file lifecycle
  local signal="${1-}" target="${2-}" evidence="${3-}" lifecycle="${4-}"
  local reason mode="write" C writers rc scratch out err writer write_capable cancelled=0
  [ "$#" -eq 4 ] && [ -n "$evidence" ] ||
    return 3
  _companion_lifecycle_valid "$lifecycle" || return 3
  [ "$lifecycle" = : ] && mode="read"
  case "$signal" in
    HUP) reason="signal-hup" ;;
    INT) reason="signal-int" ;;
    TERM) reason="signal-term" ;;
    *) return 3 ;;
  esac
  if [ -z "$target" ] && [ "$lifecycle" != : ]; then
    target=$("$lifecycle" current-job unknown "$reason" "") ||
      target=""
    [ "$target" = unknown ] && target=""
  fi
  C=$(companion_resolve) || C=""
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-interrupt.XXXXXX") ||
    return 4
  out="$scratch/stdout"
  err="$scratch/stderr"
  if [ "$mode" = read ]; then
    if [ -n "$target" ] && [ -n "$C" ]; then
      companion_cancel_job "$C" "$target" "$reason" signal-handler \
        "$mode" "" "$lifecycle" "$out" "$err"
      rc=$?
      [ ! -s "$err" ] || cat "$err" >> "$evidence"
      rm -rf "$scratch"
      return "$rc"
    fi
    rm -rf "$scratch"
    return 124
  fi

  if [ -n "$target" ] && [ -n "$C" ]; then
    companion_cancel_job "$C" "$target" "$reason" signal-handler \
      "$mode" "" "$lifecycle" "$out" "$err" || :
    [ ! -s "$err" ] || cat "$err" >> "$evidence"
    cancelled=1
  fi

  writers=""
  if [ -n "$C" ] && companion_workspace_writers "$C" "$out" "$err"; then
    writers=$(cat "$out" 2>/dev/null)
    [ ! -s "$err" ] || cat "$err" >> "$evidence"
    while IFS=$'\t' read -r writer write_capable; do
      [ "$write_capable" = true ] || continue
      [ "$writer" != "$target" ] || continue
      companion_cancel_job "$C" "$writer" "$reason" signal-handler \
        "$mode" "" "$lifecycle" "$out" "$err" || :
      [ ! -s "$err" ] || cat "$err" >> "$evidence"
      cancelled=1
    done <<< "$writers"
  else
    [ ! -s "$err" ] || cat "$err" >> "$evidence"
  fi
  rm -rf "$scratch"
  if [ "$cancelled" -eq 0 ]; then
    "$lifecycle" cancel-begin unknown "$reason" "" || :
  fi
  return 125
}

companion_writers() { # result-file evidence-file
  local result="${1-}" evidence="${2-}" C rc
  local out="${1-}.transport" err="${1-}.transport.stderr"
  [ "$#" -eq 2 ] && [ -n "$result" ] && [ -n "$evidence" ] &&
    [ "$result" != "$evidence" ] || return 3
  rm -f "$out" "$err" || return 3
  : > "$result" || return 3
  : > "$evidence" || return 3
  C=$(companion_resolve) || return 4
  companion_workspace_writers "$C" "$out" "$err"
  rc=$?
  [ ! -s "$err" ] || cat "$err" >> "$evidence"
  if [ "$rc" -eq 0 ]; then
    cat "$out" > "$result" || rc=4
  fi
  rm -f "$out" "$err"
  return "$rc"
}
