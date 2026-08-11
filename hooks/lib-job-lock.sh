#!/usr/bin/env bash
# Maestro companion-job lifetime mutex. Sourced, not executed.

[ "${_MAESTRO_JOB_LOCK_LOADED-0}" = 1 ] && return 0
_MAESTRO_JOB_LOCK_LOADED=1

MAESTRO_JOB_LOCK_TOKEN=""
MAESTRO_JOB_LOCK_DIR=""
MAESTRO_JOB_LOCK_ACQUIRED=0
export -n MAESTRO_JOB_LOCK_TOKEN MAESTRO_JOB_LOCK_DIR \
  MAESTRO_JOB_LOCK_ACQUIRED 2>/dev/null || :

job_lock_path() {
  local workspace git_dir
  workspace=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  git_dir=$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$git_dir" in
    /*) ;;
    *) git_dir="$workspace/$git_dir" ;;
  esac
  printf '%s/maestro-job-lock' "$(cd "$git_dir" 2>/dev/null && pwd -P)"
}

job_lock_metadata_value() { # metadata field
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1
}

job_lock_path_mtime_epoch() { # path
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

job_lock_session_id() {
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

job_lock_job_valid() {
  case "${1-}" in
    task-*) ;;
    *) return 1 ;;
  esac
  case "$1" in *[!A-Za-z0-9-]*) return 1 ;; esac
}

job_lock_metadata_valid() { # metadata require-job
  local metadata="$1" require_job="${2:-0}" token pid session class start job
  [ -f "$metadata" ] || return 1
  token=$(job_lock_metadata_value "$metadata" token)
  pid=$(job_lock_metadata_value "$metadata" pid)
  session=$(job_lock_metadata_value "$metadata" session)
  class=$(job_lock_metadata_value "$metadata" class)
  start=$(job_lock_metadata_value "$metadata" start)
  job=$(job_lock_metadata_value "$metadata" job)
  [ -n "$token" ] || return 1
  case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$session" in
    unknown) ;;
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) [ "${#session}" -le 64 ] || return 1 ;;
  esac
  case "$class" in read|write) ;; *) return 1 ;; esac
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$job" ]; then
    job_lock_job_valid "$job" || return 1
  elif [ "$require_job" -eq 1 ]; then
    return 1
  fi
}

job_lock_publish_metadata() { # lock-dir token record
  local lock_dir="$1" token="$2" record="$3" metadata temp recorded_token
  metadata="$lock_dir/metadata"
  temp="$lock_dir/metadata.tmp.$token"
  if [ -f "$metadata" ]; then
    recorded_token=$(job_lock_metadata_value "$metadata" token)
    [ "$recorded_token" = "$token" ] || return 1
  fi
  (umask 077; printf '%s\n' "$record" > "$temp") || return 1
  if [ -f "$metadata" ]; then
    recorded_token=$(job_lock_metadata_value "$metadata" token)
    if [ "$recorded_token" != "$token" ]; then
      rm -f "$temp" 2>/dev/null || :
      return 1
    fi
  fi
  if mv -f "$temp" "$metadata"; then
    return 0
  fi
  rm -f "$temp" 2>/dev/null || :
  return 1
}

job_lock_job_state() { # job output-variable
  local job="$1" output_var="$2" C scratch out err parsed rc observed=""
  case "$output_var" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 4 ;; esac
  printf -v "$output_var" '%s' ""
  C=$(companion_resolve) || return 4
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-job-state.XXXXXX") || return 4
  out="$scratch/stdout"
  err="$scratch/stderr"
  parsed="$scratch/parsed"
  CODEX_COMPANION_SESSION_ID='' companion_call "$out" "$err" \
    "$C" status "$job" --json
  rc=$?
  if [ "$rc" -eq 0 ]; then
    node -e '
      const fs = require("node:fs");
      const [file, expected] = process.argv.slice(1);
      try {
        const value = JSON.parse(fs.readFileSync(file, "utf8"));
        if (!value || typeof value !== "object" || Array.isArray(value) ||
            value.id !== expected || typeof value.status !== "string" ||
            !/^[A-Za-z][A-Za-z_-]*$/.test(value.status)) process.exit(4);
        process.stdout.write(`${value.status.toLowerCase()}\n`);
      } catch { process.exit(4); }
    ' "$out" "$job" > "$parsed" 2>/dev/null
    rc=$?
  fi
  [ ! -s "$err" ] || cat "$err" >&2
  if [ "$rc" -eq 0 ]; then
    observed=$(sed -n '1p' "$parsed")
    printf -v "$output_var" '%s' "$observed"
  fi
  rm -rf "$scratch"
  [ "$rc" -eq 0 ] || return 4
}

job_lock_state_terminal() {
  case "${1-}" in
    completed|done|finished|succeeded|success|cancelled|canceled|failed|error|errored) return 0 ;;
    *) return 1 ;;
  esac
}

job_lock_workspace_jobs() { # output-variable
  local output_var="$1" scratch result evidence rc observed_jobs=""
  case "$output_var" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 4 ;; esac
  printf -v "$output_var" '%s' ""
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-job-list.XXXXXX") || return 4
  result="$scratch/result"
  evidence="$scratch/evidence"
  companion_writers "$result" "$evidence"
  rc=$?
  [ ! -s "$evidence" ] || cat "$evidence" >&2
  if [ "$rc" -eq 0 ]; then
    observed_jobs=$(cat "$result")
    printf -v "$output_var" '%s' "$observed_jobs"
  fi
  rm -rf "$scratch"
  return "$rc"
}

job_lock_wait_tick() { # deadline class job session lock-dir
  local deadline="$1" class="$2" job="$3" session="$4" lock_dir="$5"
  local now remaining sleep_for
  [ "$deadline" -gt 0 ] 2>/dev/null || return 1
  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || return 1
  remaining=$((deadline - now))
  sleep_for=$MAESTRO_LOCK_WAIT_POLL_SEC
  [ "$sleep_for" -le "$remaining" ] || sleep_for=$remaining
  progress "MAESTRO_JOB_LOCK: waiting for class=$class job=$job session=$session — ${remaining}s left before blocking (lock: $lock_dir)"
  sleep "$sleep_for"
}

job_lock_recovery_message() { # detail lock-dir
  progress "MAESTRO_JOB_LOCK: $1 (lock: $2). Recover with: bash ~/.claude/hooks/implementer-loop.sh --clear-job-lock"
}

job_lock_acquire() { # read|write
  local class="${1-}" metadata token session now record wait_cap wait_poll deadline
  local recorded_token owner_pid owner_session owner_class owner_job state reclaim
  local age mtime
  case "$class" in read|write) ;; *) return 3 ;; esac
  MAESTRO_JOB_LOCK_TOKEN=""
  MAESTRO_JOB_LOCK_ACQUIRED=0
  MAESTRO_JOB_LOCK_DIR=$(job_lock_path) || return 3
  metadata="$MAESTRO_JOB_LOCK_DIR/metadata"

  wait_cap=${MAESTRO_LOCK_WAIT_SEC:-300}
  wait_poll=${MAESTRO_LOCK_WAIT_POLL_SEC:-5}
  case "$wait_cap" in
    *[!0-9]*)
      progress "MAESTRO_JOB_LOCK: invalid MAESTRO_LOCK_WAIT_SEC=$wait_cap; waiting disabled"
      wait_cap=0
      ;;
    *) wait_cap=$((10#$wait_cap)) ;;
  esac
  case "$wait_poll" in
    ''|*[!0-9]*) wait_poll=1 ;;
    *)
      if [ "$wait_poll" -lt 1 ]; then wait_poll=1; else wait_poll=$((10#$wait_poll)); fi
      ;;
  esac
  MAESTRO_LOCK_WAIT_POLL_SEC=$wait_poll
  if [ "$wait_cap" -gt 0 ]; then
    deadline=$(( $(date +%s) + wait_cap ))
  else
    deadline=0
  fi

  while :; do
    if (umask 077; mkdir "$MAESTRO_JOB_LOCK_DIR") 2>/dev/null; then
      token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      session=$(job_lock_session_id)
      now=$(date +%s)
      record=$(printf 'token=%s\npid=%s\nsession=%s\nclass=%s\nstart=%s' \
        "$token" "$$" "${session:-unknown}" "$class" "$now")
      if ! job_lock_publish_metadata "$MAESTRO_JOB_LOCK_DIR" "$token" "$record"; then
        rm -f "$metadata" "$MAESTRO_JOB_LOCK_DIR"/metadata.tmp.* 2>/dev/null || :
        rmdir "$MAESTRO_JOB_LOCK_DIR" 2>/dev/null || :
        return 3
      fi
      MAESTRO_JOB_LOCK_TOKEN=$token
      MAESTRO_JOB_LOCK_ACQUIRED=1
      return 0
    fi
    [ -d "$MAESTRO_JOB_LOCK_DIR" ] || return 3

    if [ ! -f "$metadata" ]; then
      mtime=$(job_lock_path_mtime_epoch "$MAESTRO_JOB_LOCK_DIR") || mtime=""
      case "$mtime" in
        ''|*[!0-9]*)
          job_lock_recovery_message "metadata is absent and lock age is unconfirmed; failing closed" "$MAESTRO_JOB_LOCK_DIR"
          return 11
          ;;
      esac
      now=$(date +%s)
      age=$((now - mtime)); [ "$age" -ge 0 ] || age=0
      if [ "$age" -lt 5 ] &&
        job_lock_wait_tick "$deadline" unknown unknown unknown "$MAESTRO_JOB_LOCK_DIR"; then
        continue
      fi
      job_lock_recovery_message "metadata is absent; owner cannot be identified; failing closed" "$MAESTRO_JOB_LOCK_DIR"
      return 11
    fi

    if ! job_lock_metadata_valid "$metadata" 0; then
      job_lock_recovery_message "metadata is malformed; owner cannot be identified; failing closed" "$MAESTRO_JOB_LOCK_DIR"
      return 11
    fi
    recorded_token=$(job_lock_metadata_value "$metadata" token)
    owner_pid=$(job_lock_metadata_value "$metadata" pid)
    owner_session=$(job_lock_metadata_value "$metadata" session)
    owner_class=$(job_lock_metadata_value "$metadata" class)
    owner_job=$(job_lock_metadata_value "$metadata" job)
    owner_job=${owner_job:-unknown}

    if kill -0 "$owner_pid" 2>/dev/null; then
      if job_lock_wait_tick "$deadline" "$owner_class" "$owner_job" "$owner_session" "$MAESTRO_JOB_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_JOB_LOCK: companion dispatch blocked; held by class=$owner_class job=$owner_job session=$owner_session pid=$owner_pid (lock: $MAESTRO_JOB_LOCK_DIR)"
      return 11
    fi
    if [ "$owner_job" = unknown ]; then
      job_lock_recovery_message "metadata has no published job and owner pid=$owner_pid is dead; failing closed" "$MAESTRO_JOB_LOCK_DIR"
      return 11
    fi
    if ! job_lock_job_state "$owner_job" state; then
      job_lock_recovery_message "companion status for class=$owner_class job=$owner_job session=$owner_session is unavailable or malformed; failing closed" "$MAESTRO_JOB_LOCK_DIR"
      return 11
    fi
    if ! job_lock_state_terminal "$state"; then
      if job_lock_wait_tick "$deadline" "$owner_class" "$owner_job" "$owner_session" "$MAESTRO_JOB_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_JOB_LOCK: companion dispatch blocked; class=$owner_class job=$owner_job session=$owner_session remains $state (lock: $MAESTRO_JOB_LOCK_DIR)"
      return 11
    fi

    [ "$(job_lock_metadata_value "$metadata" token)" = "$recorded_token" ] || continue
    reclaim="${MAESTRO_JOB_LOCK_DIR}.reclaim.${recorded_token}.$$"
    [ ! -e "$reclaim" ] || return 11
    if ! mv "$MAESTRO_JOB_LOCK_DIR" "$reclaim" 2>/dev/null; then
      continue
    fi
    rm -rf "$reclaim" 2>/dev/null || return 11
  done
}

job_lock_publish_job() { # job-id
  local job="${1-}" metadata recorded_token pid session class start record
  job_lock_job_valid "$job" || return 3
  [ "${MAESTRO_JOB_LOCK_ACQUIRED:-0}" -eq 1 ] || return 3
  metadata="${MAESTRO_JOB_LOCK_DIR:-}/metadata"
  [ -f "$metadata" ] || return 3
  recorded_token=$(job_lock_metadata_value "$metadata" token)
  if [ "$recorded_token" != "${MAESTRO_JOB_LOCK_TOKEN:-}" ]; then
    progress "MAESTRO_JOB_LOCK: lock generation changed while publishing job=$job"
    return 3
  fi
  pid=$(job_lock_metadata_value "$metadata" pid)
  session=$(job_lock_metadata_value "$metadata" session)
  class=$(job_lock_metadata_value "$metadata" class)
  start=$(job_lock_metadata_value "$metadata" start)
  record=$(printf 'token=%s\npid=%s\nsession=%s\nclass=%s\nstart=%s\njob=%s' \
    "$recorded_token" "$pid" "$session" "$class" "$start" "$job")
  job_lock_publish_metadata "$MAESTRO_JOB_LOCK_DIR" "$recorded_token" "$record"
}

job_lock_release() {
  local metadata recorded_token release_dir
  [ "${MAESTRO_JOB_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_JOB_LOCK_DIR:-}/metadata"
  [ -f "$metadata" ] || return 0
  recorded_token=$(job_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_JOB_LOCK_TOKEN:-}" ] || return 0
  release_dir="${MAESTRO_JOB_LOCK_DIR}.release.${recorded_token}.$$"
  [ ! -e "$release_dir" ] || return 0
  [ "$(job_lock_metadata_value "$metadata" token)" = "$recorded_token" ] || return 0
  if mv "$MAESTRO_JOB_LOCK_DIR" "$release_dir" 2>/dev/null; then
    rm -rf "$release_dir" 2>/dev/null || :
    MAESTRO_JOB_LOCK_ACQUIRED=0
    MAESTRO_JOB_LOCK_TOKEN=""
  fi
  return 0
}

job_lock_clear() { # result-file evidence-file
  local result="${1-}" evidence="${2-}" lock_dir metadata age_path mtime now age
  local valid=0 token pid session class job state jobs reclaim current_token
  [ -n "$result" ] && [ -n "$evidence" ] && [ "$result" != "$evidence" ] || return 3
  : > "$evidence" || return 3
  printf 'state=blocked\n' > "$result" || return 3
  lock_dir=$(job_lock_path) || return 3
  if [ ! -d "$lock_dir" ]; then
    progress "MAESTRO_JOB_LOCK: there is no companion job lock to clear at $lock_dir"
    printf 'state=absent\n' > "$result"
    return 0
  fi
  metadata="$lock_dir/metadata"
  token=$(job_lock_metadata_value "$metadata" token)
  pid=$(job_lock_metadata_value "$metadata" pid)
  session=$(job_lock_metadata_value "$metadata" session); session=${session:-unknown}
  class=$(job_lock_metadata_value "$metadata" class); class=${class:-unknown}
  job=$(job_lock_metadata_value "$metadata" job); job=${job:-unknown}

  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        progress "MAESTRO_JOB_LOCK: refusing to clear — holder class=$class job=$job session=$session pid=$pid is alive (lock: $lock_dir)"
        return 11
      fi
      ;;
  esac

  if job_lock_metadata_valid "$metadata" 1; then valid=1; fi
  if [ "$valid" -eq 1 ]; then
    if ! job_lock_job_state "$job" state; then
      jobs=""
      if job_lock_workspace_jobs jobs && [ -n "$jobs" ]; then
        progress "MAESTRO_JOB_LOCK: refusing to clear — companion status for holder class=$class job=$job session=$session is unavailable while repository-global job $(printf '%s\n' "$jobs" | awk 'NF { print $1; exit }') is running"
      else
        progress "MAESTRO_JOB_LOCK: refusing to clear — companion status for holder class=$class job=$job session=$session is unavailable or malformed"
      fi
      return 11
    fi
    if ! job_lock_state_terminal "$state"; then
      progress "MAESTRO_JOB_LOCK: refusing to clear — holder class=$class job=$job session=$session remains $state"
      return 11
    fi
  else
    age_path="$lock_dir"
    [ ! -e "$metadata" ] || age_path="$metadata"
    mtime=$(job_lock_path_mtime_epoch "$age_path") || {
      progress "MAESTRO_JOB_LOCK: refusing to clear — malformed or absent metadata age is unconfirmed (lock: $lock_dir)"
      return 11
    }
    now=$(date +%s)
    age=$((now - mtime)); [ "$age" -ge 0 ] || age=0
    if [ "$age" -lt 5 ]; then
      progress "MAESTRO_JOB_LOCK: refusing to clear — malformed or absent metadata is ${age}s old and may still be publishing (lock: $lock_dir); retry after 5s"
      return 11
    fi
    jobs=""
    if ! job_lock_workspace_jobs jobs; then
      progress "MAESTRO_JOB_LOCK: refusing to clear — repository-global companion status is unavailable"
      return 11
    fi
    if [ -n "$jobs" ]; then
      progress "MAESTRO_JOB_LOCK: refusing to clear — repository-global job $(printf '%s\n' "$jobs" | awk 'NF { print $1; exit }') is running"
      return 11
    fi
  fi

  if [ "$valid" -eq 1 ]; then
    current_token=$(job_lock_metadata_value "$metadata" token)
    [ "$current_token" = "$token" ] || {
      progress "MAESTRO_JOB_LOCK: refusing to clear — lock generation changed during recovery"
      return 11
    }
    reclaim="${lock_dir}.reclaim.${token}.$$"
  else
    if job_lock_metadata_valid "$metadata" 0; then
      progress "MAESTRO_JOB_LOCK: refusing to clear — metadata became valid during recovery"
      return 11
    fi
    token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    reclaim="${lock_dir}.reclaim.clear-${token}.$$"
  fi
  [ ! -e "$reclaim" ] || return 11
  if ! mv "$lock_dir" "$reclaim" 2>/dev/null; then
    progress "MAESTRO_JOB_LOCK: refusing to clear — lock generation changed during recovery"
    return 11
  fi
  rm -rf "$reclaim" 2>/dev/null || return 11
  if [ -d "$lock_dir" ]; then
    progress "MAESTRO_JOB_LOCK: cleared the requested generation, but a successor already holds the lock"
    return 11
  fi
  progress "MAESTRO_JOB_LOCK: cleared companion job lock (class=$class job=$job session=$session)"
  printf 'state=cleared\n' > "$result"
  return 0
}
