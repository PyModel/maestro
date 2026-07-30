#!/usr/bin/env bash
# Maestro companion library — shared Codex companion plumbing for the hook scripts.
# Sourced, not executed. All functions assume `set -uo pipefail` in the caller.
#
#   progress_init                          → keeps inherited FD 3, or opens it to caller stdout
#   progress <message>                     → writes one progress line to FD 3
#   repo_digest                            → prints a repository-wide state digest, or returns non-zero
#   write_lock_acquire [job]               → returns 0 acquired/inherited | 11 live contention
#   write_lock_is_owner                    → returns 0 for the acquirer or its inherited token
#   write_lock_set_job <job>               → records a known job id for the current owner
#   write_lock_poison <job> <reason>        → stages unconfirmed-quiescence metadata
#   write_lock_release                     → releases an acquired lock only after its lease ends
#   provenance_check                       → manually compares the tree to the last completed snapshot
#   companion_resolve                      → prints companion path, or returns 3
#   companion_pin                          → prints model<TAB>debate-effort<TAB>impl-effort, or returns 3
#   companion_start <C> <prompt> [write]   → prints job id, or returns 3 (fails closed without a pin)
#   companion_verify_pin <C> <job> <model> <effort> → returns 0 match | 4 mismatch
#   companion_workspace_writers <C>        → prints job<TAB>write, or returns 4
#   companion_poll  <C> <job> <idle> <sec> → returns 0 done | 4 failed | 124 read-only timeout
#                                             | 125 write timeout | 6 status-lost
#   companion_result <C> <job>             → prints result (retried), or returns 4
#
# Error-handling contract: a companion that cannot answer `status` 4 times in a row
# is declared lost (6) instead of being polled forever; an empty `result` is fetched
# once more before being declared a failure. Hangs are cancelled by the poll itself.

progress_init() {
  if ! { true >&3; } 2>/dev/null; then exec 3>&1; fi
}

progress() { printf '%s\n' "$*" >&3; }

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

repo_digest() {
  local inside worktrees roots root_list digest material tracked untracked paths entries
  local regular_paths hashes link_output link_rc path type mode contents worktree
  inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || return 1
  [ "$inside" = "true" ] || return 1
  worktrees=$(git worktree list --porcelain 2>/dev/null) || return 1
  worktrees=$(printf '%s\n' "$worktrees" | sed -n 's/^worktree //p' | LC_ALL=C sort) || return 1
  [ -n "$worktrees" ] || return 1
  root_list=$(mktemp "${TMPDIR:-/tmp}/maestro-repo-roots.XXXXXX") || return 1
  if ! (
    while IFS= read -r worktree; do
      [ -n "$worktree" ] || continue
      printf '%s\n' "$worktree"
      git -C "$worktree" submodule foreach --recursive --quiet \
        'printf "%s\n" "$PWD"' 2>/dev/null || exit 1
    done <<< "$worktrees"
  ) > "$root_list"; then
    rm -f "$root_list"
    return 1
  fi
  roots=$(LC_ALL=C sort -u "$root_list") || {
    rm -f "$root_list"
    return 1
  }
  rm -f "$root_list"
  [ -n "$roots" ] || return 1

  material=$(mktemp "${TMPDIR:-/tmp}/maestro-repo-digest.XXXXXX") || return 1
  tracked="${material}.tracked"
  untracked="${material}.untracked"
  paths="${material}.paths"
  entries="${material}.entries"
  regular_paths="${material}.regular"
  hashes="${material}.hashes"
  if ! (
    while IFS= read -r worktree; do
      [ -n "$worktree" ] || continue
      : > "$tracked" || exit 1
      : > "$untracked" || exit 1
      : > "$paths" || exit 1
      : > "$entries" || exit 1
      : > "$regular_paths" || exit 1
      : > "$hashes" || exit 1
      git -C "$worktree" ls-files -z > "$tracked" 2>/dev/null || exit 1
      # Ignored paths are out of observation scope, not "not source": hashing them has
      # unbounded cost (for example node_modules and build outputs).
      git -C "$worktree" ls-files --others --exclude-standard -z \
        > "$untracked" 2>/dev/null || exit 1
      LC_ALL=C sort -zu "$tracked" "$untracked" > "$paths" || exit 1

      while IFS= read -r -d '' path; do
        if [ -L "$worktree/$path" ]; then
          type='link'
          mode=120000
          link_output=$(
            readlink "$worktree/$path" 2>/dev/null
            link_rc=$?
            printf '\001%s' "$link_rc"
          )
          link_rc=${link_output##*$'\001'}
          if [ "$link_rc" -eq 0 ]; then
            contents=${link_output%$'\001'*}
            contents=${contents%$'\n'}
          else
            # The entry may vanish after enumeration; preserve a degraded marker.
            contents=unavailable
          fi
        elif [ -f "$worktree/$path" ]; then
          type='file'
          if [ -x "$worktree/$path" ]; then mode=100755; else mode=100644; fi
          contents=
          printf '%s\0' "$path" >> "$regular_paths"
        elif [ -e "$worktree/$path" ]; then
          type=other
          mode=other
          contents=unavailable
        else
          type=absent
          mode=absent
          contents=absent
        fi
        printf '%s\0%s\0%s\0%s\0' "$path" "$type" "$mode" "$contents" >> "$entries"
      done < "$paths" || exit 1

      if [ -s "$regular_paths" ]; then
        # xargs is serial: it preserves the sorted NUL-delimited path order, and
        # hash-object emits exactly one output line per argument in argument order.
        if ! xargs -0 git -C "$worktree" hash-object -- \
          < "$regular_paths" > "$hashes" 2>/dev/null; then
          # A path can vanish after enumeration. Re-run only this degraded case
          # individually so the unavailable marker stays paired with that path.
          : > "$hashes"
          while IFS= read -r -d '' path; do
            if contents=$(git -C "$worktree" hash-object -- "$path" 2>/dev/null); then
              printf '%s\n' "$contents"
            else
              printf 'unavailable\n'
            fi
          done < "$regular_paths" > "$hashes" || exit 1
        fi
      fi

      printf 'worktree\0%s\0' "$worktree"
      exec 8< "$hashes" || exit 1
      while IFS= read -r -d '' path &&
        IFS= read -r -d '' type &&
        IFS= read -r -d '' mode &&
        IFS= read -r -d '' contents; do
        if [ "$type" = "file" ]; then
          IFS= read -r contents <&8 || contents=unavailable
        fi
        printf 'path\0%s\0type\0%s\0mode\0%s\0contents\0%s\0' \
          "$path" "$type" "$mode" "$contents"
      done < "$entries" || exit 1
      exec 8<&-
    done <<< "$roots"
  ) > "$material"; then
    rm -f "$material" "$tracked" "$untracked" "$paths" "$entries" "$regular_paths" "$hashes"
    return 1
  fi
  if ! digest=$(shasum < "$material" | awk '{print $1}'); then
    rm -f "$material" "$tracked" "$untracked" "$paths" "$entries" "$regular_paths" "$hashes"
    return 1
  fi
  rm -f "$material" "$tracked" "$untracked" "$paths" "$entries" "$regular_paths" "$hashes"
  [ -n "$digest" ] || return 1
  printf 'tree-v2:%s\n' "$digest"
}

repo_digest_is_observed() {
  case "$1" in
    tree-v2:*) return 0 ;;
    *) return 1 ;;
  esac
}

write_lock_path() {
  local workspace git_dir
  workspace=$(pwd -P)
  if { git_dir=$(git rev-parse --git-common-dir 2>/dev/null) && [ -n "$git_dir" ]; } ||
    git_dir=$(git rev-parse --git-dir 2>/dev/null); then
    case "$git_dir" in
      /*) ;;
      *) git_dir="$workspace/$git_dir" ;;
    esac
    printf '%s/maestro-write.lock' "$(cd "$git_dir" && pwd -P)"
  else
    printf '%s/.maestro-write.lock' "$workspace"
  fi
}

provenance_log_path() {
  local lock_path
  lock_path=$(write_lock_path) || return 1
  case "$lock_path" in
    */maestro-write.lock)
      printf '%s/maestro-provenance.log' "${lock_path%/maestro-write.lock}"
      ;;
    *)
      return 1
      ;;
  esac
}

write_lock_metadata_value() {
  local metadata="$1" field="$2"
  sed -n "s/^${field}=//p" "$metadata" 2>/dev/null | head -1
}

write_lock_session_id() {   # prints a validated session id, or unknown
  local session_id="${MAESTRO_SESSION_ID:-}"
  case "$session_id" in
    ''|*[!A-Za-z0-9_-]*) printf 'unknown' ;;
    *)
      if [ "${#session_id}" -le 64 ]; then
        printf '%s' "$session_id"
      else
        printf 'unknown'
      fi
      ;;
  esac
}

write_lock_is_owner() {
  local metadata recorded_token
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || {
    [ -n "${MAESTRO_LOCK_TOKEN:-}" ] || return 1
  }
  metadata="${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"
  [ -f "$metadata" ] || return 1
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ -n "${MAESTRO_LOCK_TOKEN:-}" ] &&
    [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ]
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
  local owner_job started_epoch current_start held now attempt token process_start owner_alive
  local identity_note quiescence unconfirmed_job unconfirmed_reason poison_metadata owner_session
  local writers writers_rc digest_before log_path last prior_job prior_after observed_at
  local stale_digest_before stale_digest_after stale_released_at session_id
  MAESTRO_LOCK_ACQUIRED=0
  MAESTRO_LOCK_DIR=$(write_lock_path) || return 3
  metadata="$MAESTRO_LOCK_DIR/metadata"

  poison_metadata="$metadata"
  quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
  if [ "$quiescence" != "unconfirmed" ] &&
    [ -e "$MAESTRO_LOCK_DIR/metadata.new" ]; then
    poison_metadata="$MAESTRO_LOCK_DIR/metadata.new"
    quiescence=unconfirmed
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
    unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
    owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
    owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
    progress "MAESTRO_LOCK: write dispatch blocked; quiescence is unconfirmed for job=${unconfirmed_job:-unknown} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown} (lock: $MAESTRO_LOCK_DIR). Clear it once no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
    return 11
  fi

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
      # ponytail: mkdir gives mutual exclusion; ps only sharpens stale-owner recovery.
      # Without it, record the gap and let the contention path fail closed instead.
      if [ -z "$process_start" ]; then
        process_start=unavailable
        progress "MAESTRO_LOCK: process start identity unavailable for pid=$$; lease recorded without it (stale-owner recovery will fail closed)"
      fi
      now=$(date +%s)
      digest_before=$(repo_digest 2>/dev/null) || digest_before=unavailable
      session_id=$(write_lock_session_id)
      if log_path=$(provenance_log_path 2>/dev/null) && [ -f "$log_path" ]; then
        last=$(grep -E '^[^ ]+ type=(dispatch|orphan-adopted) job=[^ ]+( session=[^ ]+)? before=[^ ]+ after=[^ ]+$' \
          "$log_path" 2>/dev/null | tail -1)
        if [ -n "$last" ]; then
          prior_job=${last#* job=}
          prior_job=${prior_job%% *}
          prior_after=${last##* after=}
          if repo_digest_is_observed "$prior_after" &&
            repo_digest_is_observed "$digest_before" &&
            [ "$prior_after" != "$digest_before" ]; then
            observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            progress "PROVENANCE: BASELINE GAP — tree at acquisition differs from the prior completed snapshot (prior_job=$prior_job, expected=$prior_after, observed=$digest_before); author unknown"
            printf '%s type=gap prior_job=%s session=%s expected=%s observed=%s\n' \
              "$observed_at" "$prior_job" "${session_id:-unknown}" "$prior_after" "$digest_before" \
              >> "$log_path" 2>/dev/null || :
          fi
        fi
      fi
      if ! printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s\n' \
        "$token" "$$" "$process_start" "$requested_job" "${session_id:-unknown}" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$now" "$digest_before" > "$metadata"; then
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
      progress "MAESTRO_LOCK: write dispatch blocked by an initializing owner (job=unknown session=unknown pid=unknown held=unknown, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    owner_pid=$(write_lock_metadata_value "$metadata" pid)
    owner_start=$(write_lock_metadata_value "$metadata" process_start)
    owner_job=$(write_lock_metadata_value "$metadata" job_id)
    owner_session=$(write_lock_metadata_value "$metadata" session_id)
    owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
    started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
    stale_digest_before=$(write_lock_metadata_value "$metadata" digest_before)
    owner_job=${owner_job:-unknown}
    stale_digest_before=${stale_digest_before:-unavailable}
    owner_alive=0
    current_start=""
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      owner_alive=1
      current_start=$(ps -o lstart= -p "$owner_pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    fi

    if [ "$owner_alive" -eq 1 ] &&
      { [ -z "$current_start" ] || [ -z "$owner_start" ] ||
        [ "$owner_start" = unavailable ] || [ "$current_start" = "$owner_start" ]; }; then
      identity_note=""
      if [ -z "$current_start" ] || [ -z "$owner_start" ] || [ "$owner_start" = unavailable ]; then
        identity_note=" (identity unconfirmed; failing closed)"
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
      progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown} for $held (lock: $MAESTRO_LOCK_DIR)${identity_note}"
      return 11
    fi

    writers=$(write_lock_workspace_writers)
    writers_rc=$?
    if [ "$writers_rc" -eq 4 ]; then
      progress "MAESTRO_LOCK: dispatcher is gone but job liveness could not be determined; write lock retained (job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown}, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    if [ "$owner_job" != "unknown" ]; then
      if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
        progress "MAESTRO_LOCK: write dispatch blocked; lease retained because orphaned job=$owner_job session=${owner_session:-unknown} is still running (lock: $MAESTRO_LOCK_DIR)"
        return 11
      fi
    elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
      progress "MAESTRO_LOCK: write dispatch blocked; lease retained because an unidentified write-capable job is still running (session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    # Cancellation stages poison before the job disappears from the writers list.
    # Recheck after liveness so that transition cannot be erased as stale.
    poison_metadata="$metadata"
    quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
    if [ "$quiescence" != "unconfirmed" ] &&
      [ -e "$MAESTRO_LOCK_DIR/metadata.new" ]; then
      poison_metadata="$MAESTRO_LOCK_DIR/metadata.new"
      quiescence=unconfirmed
    fi
    if [ "$quiescence" = "unconfirmed" ]; then
      unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
      unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
      owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
      owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
      progress "MAESTRO_LOCK: write dispatch blocked; quiescence is unconfirmed for job=${unconfirmed_job:-unknown} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown} (lock: $MAESTRO_LOCK_DIR). Clear it once no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
      return 11
    fi

    if rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" 2>/dev/null &&
      rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
      progress "MAESTRO_LOCK: broke stale write lock held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown}"
      stale_digest_after=$(repo_digest 2>/dev/null) || stale_digest_after=unavailable
      if repo_digest_is_observed "$stale_digest_before" &&
        repo_digest_is_observed "$stale_digest_after" &&
        [ "$stale_digest_before" != "$stale_digest_after" ]; then
        progress "PROVENANCE: ADOPTED UNOBSERVED INTERVAL — the tree changed while an orphaned lease was held (job=$owner_job, expected=$stale_digest_before, observed=$stale_digest_after); the interval was not observed and the author is unknown"
      fi
      stale_released_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      if log_path=$(provenance_log_path 2>/dev/null); then
        # The interval between the orphan's last write and this steal was never observed,
        # so the after value is adopted, not witnessed.
        printf '%s type=orphan-adopted job=%s session=%s before=%s after=%s\n' \
          "$stale_released_at" "$owner_job" "${owner_session:-unknown}" \
          "$stale_digest_before" "$stale_digest_after" \
          >> "$log_path" 2>/dev/null || :
      fi
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
    progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown} for $held (lock: $MAESTRO_LOCK_DIR)"
    return 11
  done

  progress "MAESTRO_LOCK: write dispatch blocked by a competing acquirer (job=unknown session=unknown pid=unknown held=unknown, lock: $MAESTRO_LOCK_DIR)"
  return 11
}

write_lock_set_job() {
  local job="$1" metadata next_metadata recorded_token owner_pid owner_start started_at started_epoch
  local digest_before session_id
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
  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  session_id=$(write_lock_metadata_value "$metadata" session_id)
  session_id=$(MAESTRO_SESSION_ID="${session_id:-}" write_lock_session_id)
  next_metadata="${MAESTRO_LOCK_DIR}/metadata.new"
  if printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s\n' \
    "$recorded_token" "$owner_pid" "$owner_start" "$job" "${session_id:-unknown}" \
    "$started_at" "$started_epoch" "$digest_before" > "$next_metadata"; then
    mv -f "$next_metadata" "$metadata"
  else
    rm -f "$next_metadata" 2>/dev/null || :
    return 3
  fi
}

write_lock_poison() {
  local job="$1" reason="$2" metadata next_metadata recorded_token owner_pid owner_start
  local owner_job started_at started_epoch digest_before session_id
  write_lock_is_owner || return 3
  metadata="${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"
  [ -f "$metadata" ] || return 3
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || return 3
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  owner_start=$(write_lock_metadata_value "$metadata" process_start)
  owner_job=$(write_lock_metadata_value "$metadata" job_id)
  started_at=$(write_lock_metadata_value "$metadata" started_at)
  started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  session_id=$(write_lock_metadata_value "$metadata" session_id)
  session_id=$(MAESTRO_SESSION_ID="${session_id:-}" write_lock_session_id)
  next_metadata="${MAESTRO_LOCK_DIR}/metadata.new"
  if printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s\nquiescence=unconfirmed\nunconfirmed_job=%s\nunconfirmed_reason=%s\n' \
    "$recorded_token" "$owner_pid" "$owner_start" "$owner_job" "${session_id:-unknown}" \
    "$started_at" "$started_epoch" "$digest_before" "$job" "$reason" > "$next_metadata"; then
    return 0
  else
    rm -f "$next_metadata" 2>/dev/null || :
    return 3
  fi
}

write_lock_release() {
  local metadata recorded_token owner_job owner_session writers writers_rc quiescence
  local unconfirmed_job unconfirmed_reason poison_metadata
  local digest_before digest_after log_path released_at
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_LOCK_DIR:-}/metadata"
  [ -n "${MAESTRO_LOCK_DIR:-}" ] && [ -f "$metadata" ] || return 0
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || return 0
  owner_job=$(write_lock_metadata_value "$metadata" job_id)
  owner_job=${owner_job:-unknown}
  owner_session=$(write_lock_metadata_value "$metadata" session_id)
  owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
  poison_metadata="$metadata"
  quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
  if [ "$quiescence" != "unconfirmed" ] &&
    [ -e "$MAESTRO_LOCK_DIR/metadata.new" ]; then
    poison_metadata="$MAESTRO_LOCK_DIR/metadata.new"
    quiescence=unconfirmed
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
    unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
    owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
    owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
    progress "MAESTRO_LOCK: write lease retained because quiescence was never confirmed (job=${unconfirmed_job:-$owner_job} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi
  if [ "${MAESTRO_LOCK_RETAIN:-0}" -eq 1 ]; then
    progress "MAESTRO_LOCK: write lease retained because cancellation poison could not be persisted (job=$owner_job session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi

  writers=$(write_lock_workspace_writers)
  writers_rc=$?
  if [ "$writers_rc" -eq 4 ]; then
    progress "MAESTRO_LOCK: job liveness could not be determined; write lease retained (job=$owner_job session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi
  if [ "$owner_job" != "unknown" ]; then
    if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
      progress "MAESTRO_LOCK: write lease retained because job $owner_job session=${owner_session:-unknown} is still running; a later dispatch will resolve it (lock: $MAESTRO_LOCK_DIR)"
      return 0
    fi
  elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
    progress "MAESTRO_LOCK: write lease retained because an unidentified write-capable job is still running; a later dispatch will resolve it (session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi

  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  digest_after=$(repo_digest 2>/dev/null) || digest_after=unavailable
  released_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  # The inherited watchdog can poison while this process checks job liveness.
  poison_metadata="$metadata"
  quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
  if [ "$quiescence" != "unconfirmed" ] &&
    [ -e "$MAESTRO_LOCK_DIR/metadata.new" ]; then
    poison_metadata="$MAESTRO_LOCK_DIR/metadata.new"
    quiescence=unconfirmed
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
    unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
    owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
    owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
    progress "MAESTRO_LOCK: write lease retained because quiescence was never confirmed (job=${unconfirmed_job:-$owner_job} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi
  rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" 2>/dev/null || return 0
  rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null || :
  if log_path=$(provenance_log_path 2>/dev/null); then
    # Best-effort diagnostic only, not an enforcement boundary: repository writers can rewrite this log.
    # A differing before/after pair is a dispatch-window change with an unknown author:
    # lease metadata delimits an interval; it never identifies which process wrote.
    printf '%s type=dispatch job=%s session=%s before=%s after=%s\n' \
      "$released_at" "$owner_job" "${owner_session:-unknown}" "$digest_before" "$digest_after" \
      >> "$log_path" 2>/dev/null || :
  fi
  MAESTRO_LOCK_ACQUIRED=0
}

# Operator-facing manual check; do not wire this into cleanup.
provenance_check() {
  local lock_path metadata log_path last current after job at
  if lock_path=$(write_lock_path 2>/dev/null) &&
    [ -d "$lock_path" ] && [ -r "$lock_path/metadata" ]; then
    metadata="$lock_path/metadata"
    job=$(write_lock_metadata_value "$metadata" job_id)
    job=${job:-unknown}
    printf '%s\n' "PROVENANCE: in flight — a write lease is held (job=$job), so the tree is mid-dispatch"
    return 0
  fi
  if ! log_path=$(provenance_log_path 2>/dev/null) || [ ! -f "$log_path" ]; then
    printf '%s\n' "PROVENANCE: no baseline yet (first dispatch will establish one)"
    return 0
  fi
  last=$(grep -E '^[^ ]+ type=(dispatch|orphan-adopted) job=[^ ]+( session=[^ ]+)? before=[^ ]+ after=[^ ]+$' \
    "$log_path" 2>/dev/null | tail -1)
  if [ -z "$last" ]; then
    printf '%s\n' "PROVENANCE: no baseline yet (first dispatch will establish one)"
    return 0
  fi

  at=${last%% *}
  job=${last#* job=}
  job=${job%% *}
  after=${last##* after=}
  current=$(repo_digest 2>/dev/null) || current=unavailable
  if ! repo_digest_is_observed "$after" || ! repo_digest_is_observed "$current"; then
    printf '%s\n' "PROVENANCE: comparison unavailable — prior or current snapshot was not observed (job=$job, at $at)"
    return 0
  fi
  if [ "$current" = "$after" ]; then
    printf '%s\n' "PROVENANCE: tree matches the prior completed snapshot (job=$job, at $at)"
    return 0
  fi

  # Best-effort diagnostic only, not an enforcement boundary or a dispatch verdict.
  printf '%s\n' "PROVENANCE: BASELINE GAP — tree differs from the prior completed snapshot (prior_job=$job, expected=$after, observed=$current); author unknown"
  return 1
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
  local here selector pin model efforts debate_effort impl_effort
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  selector="$here/codex-model-select.sh"
  if ! pin=$(bash "$selector" --pin 2>/dev/null); then
    echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <effort>" >&2
    return 3
  fi
  case "$pin" in
    *$'\t'*$'\t'*) ;;
    *)
      echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <effort>" >&2
      return 3 ;;
  esac
  model=${pin%%$'\t'*}
  efforts=${pin#*$'\t'}
  debate_effort=${efforts%%$'\t'*}
  impl_effort=${efforts#*$'\t'}
  if [ -z "$model" ] || [ -z "$debate_effort" ] || [ -z "$impl_effort" ]; then
    echo "no Codex model/effort pinned — run: codex-model-select.sh <model> <effort>" >&2
    return 3
  fi
  printf '%s\t%s\t%s\n' "$model" "$debate_effort" "$impl_effort"
}

companion_start() {
  local C="$1" PROMPT="$2" WRITE="${3:-}"
  local PIN MODEL EFFORTS DEBATE_EFFORT IMPL_EFFORT HELP
  PIN=$(companion_pin) || return 3
  MODEL=${PIN%%$'\t'*}
  EFFORTS=${PIN#*$'\t'}
  DEBATE_EFFORT=${EFFORTS%%$'\t'*}
  IMPL_EFFORT=${EFFORTS#*$'\t'}
  if [ "$WRITE" = "write" ]; then
    # Compatibility probe, not an authorization check: only a help text that
    # describes `task` WITHOUT --write proves drift. Anything inconclusive
    # (empty, error, no synopsis) must not block a dispatch.
    HELP=$(node "$C" --help 2>&1) || HELP=""
    case "$HELP" in
      *--write*) ;;
      *task*)
        echo "companion at $C describes its task subcommand without --write — the plugin may have renamed the flag (README: Plugin flag drift). Refusing to dispatch a write job blind; update Maestro or pin the previous plugin version." >&2
        return 3 ;;
      *) ;;
    esac
  fi
  local -a args=(task --background)
  [ "$WRITE" = "write" ] && args+=(--write)
  args+=(--model "$MODEL")
  if [ "$WRITE" = "write" ]; then
    if companion_wrapper_accepts_effort "$IMPL_EFFORT"; then
      args+=(--effort "$IMPL_EFFORT")
    else
      progress "CODEX: companion wrapper cannot express implementation effort=$IMPL_EFFORT; --effort omitted and config debate tier=$DEBATE_EFFORT governs this write dispatch"
    fi
  fi
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
  local ST REQUEST MODEL_FIELD EFFORT_FIELD WRITE_FIELD
  local RECORDED_MODEL="null" RECORDED_EFFORT="null" RECORDED_WRITE=""
  local PIN EFFORTS CONFIG_EFFORT IMPL_EFFORT
  ST=$(node "$C" status "$JOB" --json 2>/dev/null)
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
  if [ "$RECORDED_MODEL" = "$EXPECTED_MODEL" ] && [ "$RECORDED_EFFORT" = "$EXPECTED_EFFORT" ]; then
    return 0
  fi
  if [ "$RECORDED_MODEL" = "$EXPECTED_MODEL" ] &&
    [ -n "$EFFORT_FIELD" ] && [ "$RECORDED_EFFORT" = "null" ] &&
    PIN=$(companion_pin 2>/dev/null); then
    EFFORTS=${PIN#*$'\t'}
    CONFIG_EFFORT=${EFFORTS%%$'\t'*}
    IMPL_EFFORT=${EFFORTS#*$'\t'}
    if [ "$CONFIG_EFFORT" = "$EXPECTED_EFFORT" ]; then
      case "$RECORDED_WRITE" in
        false) return 0 ;;
        true)
          case "$IMPL_EFFORT" in max|ultra) return 0 ;; esac ;;
      esac
    fi
  fi
  echo "Codex pin verification warning for $JOB: requested model=$EXPECTED_MODEL effort=$EXPECTED_EFFORT; recorded model=$RECORDED_MODEL effort=$RECORDED_EFFORT" >&2
  return 4
}

companion_cancel_job() { # C JOB REASON → 124 read-only, 125 write-mode
  local C="$1" JOB="$2" REASON="$3" ST pid log write_mode=0
  ST=$(node "$C" status "$JOB" --json 2>/dev/null) || ST=""
  pid=$(printf '%s\n' "$ST" |
    grep -oE '"pid"[[:space:]]*:[[:space:]]*(null|[0-9]+)' |
    head -1 |
    sed -E 's/^"pid"[[:space:]]*:[[:space:]]*//')
  log=$(printf '%s' "$ST" |
    sed -n 's/.*"logFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -1)
  [ "$pid" = "null" ] && pid=""
  MAESTRO_CANCEL_REASON="$REASON"
  MAESTRO_CANCEL_REQUESTED=0
  if write_lock_is_owner; then
    write_mode=1
    MAESTRO_LOCK_RETAIN=1
    if ! write_lock_poison "$JOB" "$REASON"; then
      progress "MAESTRO_LOCK: could not stage cancellation poison for job=$JOB reason=$REASON; the job was not cancelled and may still be running (log: ${log:-unknown}, lock: ${MAESTRO_LOCK_DIR:-unknown}). Recover only after no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
      return 125
    fi
  fi
  node "$C" cancel "$JOB" >/dev/null 2>&1
  MAESTRO_CANCEL_REQUESTED=1
  progress "MAESTRO_POLL: cancelled reason=$REASON job=$JOB pid=${pid:-unknown} log=${log:-unknown}"
  if [ "$write_mode" -eq 1 ]; then
    if ! mv -f "$MAESTRO_LOCK_DIR/metadata.new" "$MAESTRO_LOCK_DIR/metadata"; then
      progress "MAESTRO_LOCK: poison metadata rename failed; retaining $MAESTRO_LOCK_DIR/metadata.new as the fail-closed marker"
    fi
    return 125
  fi
  return 124
}

companion_poll() {
  local C="$1" JOB="$2" MAX_IDLE="$3" POLL="$4"
  local LOG="" last_size=-1 idle=0 sfails=0 MAX_TOTAL invalid=0 poll_started total
  local last_phase="__MAESTRO_UNSET__" last_preview="" quiet=0 keepalive_size=0
  local ST state size phase elapsed preview preview_emit preview_json emitted line growth
  MAX_TOTAL="${MAESTRO_MAX_DISPATCH_SEC-1200}"
  case "$MAX_TOTAL" in
    ''|*[!0-9]*) invalid=1 ;;
    *) [ "$MAX_TOTAL" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_POLL: ignoring invalid MAESTRO_MAX_DISPATCH_SEC=$MAX_TOTAL; using 1200s"
    MAX_TOTAL=1200
  fi
  poll_started=$(date +%s)
  while :; do
    sleep "$POLL"
    total=$(( $(date +%s) - poll_started ))
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

    if [ "$total" -ge "$MAX_TOTAL" ]; then
      companion_cancel_job "$C" "$JOB" deadline
      return $?
    fi
    if [ "$idle" -ge "$MAX_IDLE" ]; then
      companion_cancel_job "$C" "$JOB" idle
      return $?
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
