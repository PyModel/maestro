#!/usr/bin/env bash
# Maestro companion-job lifetime mutex. Sourced, not executed.

[ "${_MAESTRO_JOB_LOCK_LOADED-0}" = 1 ] && return 0
_MAESTRO_JOB_LOCK_LOADED=1

MAESTRO_JOB_LOCK_TOKEN=""
MAESTRO_JOB_LOCK_DIR=""
MAESTRO_JOB_LOCK_IDENTITY=""
MAESTRO_JOB_LOCK_ACQUIRED=0
export -n MAESTRO_JOB_LOCK_TOKEN MAESTRO_JOB_LOCK_DIR \
  MAESTRO_JOB_LOCK_IDENTITY MAESTRO_JOB_LOCK_ACQUIRED 2>/dev/null || :

maestro_workspace_scope_root() {
  local dir top parent selected=""
  dir=$(pwd -P) || return 1
  while :; do
    if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
      top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
      selected=$top
      dir=$(dirname "$top")
    else
      parent=$(dirname "$dir")
      [ "$parent" != "$dir" ] || break
      dir=$parent
    fi
  done
  [ -n "$selected" ] || return 1
  printf '%s\n' "$selected"
}

job_lock_path() {
  local workspace git_dir
  workspace=$(maestro_workspace_scope_root) || return 1
  git_dir=$(git -C "$workspace" rev-parse --git-dir 2>/dev/null) || return 1
  case "$git_dir" in
    /*) ;;
    *) git_dir="$workspace/$git_dir" ;;
  esac
  printf '%s/maestro-job-lock' "$(cd "$git_dir" 2>/dev/null && pwd -P)"
}

job_lock_metadata_value() { # metadata field
  sed -n "s/^${2}=//p" "$1" 19>&- 2>/dev/null | head -1 19>&-
}

lock_claim_random_id() {
  local value
  value=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  lock_claim_generation_valid "$value" || return 1
  printf '%s' "$value"
}
lock_claim_generation_valid() {
  [ "${#1}" -eq 32 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}
lock_claim_inode_identity() {
  stat -c '%d:%i' "$1" 19>&- 2>/dev/null ||
    stat -f '%d:%i' "$1" 19>&- 2>/dev/null
}
lock_claim_path_identity() { # lock-dir
  local lock_dir="$1" before after generation marker
  marker="$lock_dir/generation"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  before=$(lock_claim_inode_identity "$lock_dir") || return 1
  generation=$(cat "$marker" 19>&-) || return 1
  lock_claim_generation_valid "$generation" || return 1
  after=$(lock_claim_inode_identity "$lock_dir") || return 1
  [ "$before" = "$after" ] || return 1
  printf '%s:%s' "$before" "$generation"
}
lock_claim_identity_generation() {
  local generation="${1##*:}"
  lock_claim_generation_valid "$generation" || return 1
  printf '%s' "$generation"
}
lock_claim_metadata_value_once() { # metadata field
  local metadata="$1" field="$2" count
  count=$(sed -n "s/^${field}=//p" "$metadata" 19>&- 2>/dev/null |
    wc -l 19>&- | tr -d '[:space:]' 19>&-) || return 1
  [ "$count" = 1 ] || return 1
  job_lock_metadata_value "$metadata" "$field"
}
lock_claim_record_matches_identity() { # metadata identity
  local expected actual
  expected=$(lock_claim_identity_generation "$2") || return 1
  actual=$(lock_claim_metadata_value_once "$1" generation) || return 1
  [ "$actual" = "$expected" ]
}
job_lock_path_identity() {
  lock_claim_path_identity "$1"
}

job_lock_path_mtime_epoch() {
  stat -c '%Y' "$1" 19>&- 2>/dev/null ||
    stat -f '%m' "$1" 19>&- 2>/dev/null
}
# Shared generation fence for companion and write locks. `lockf`/`flock`
# ownership is released by the kernel when a claimant dies, including SIGKILL;
# the stable gate inode is never unlinked or replaced.
_MAESTRO_LOCK_CLAIM_DIR=""
_MAESTRO_LOCK_CLAIM_IDENTITY=""
_MAESTRO_LOCK_CLAIM_TOKEN=""
_MAESTRO_LOCK_CLAIM_NONCE=""
_MAESTRO_LOCK_CLAIM_GATE=""
_MAESTRO_LOCK_CLAIM_SAVED_FD=""
_MAESTRO_LOCK_CLAIM_MODE=""
case "$(uname -s 2>/dev/null)" in
  Darwin|FreeBSD|NetBSD|OpenBSD) _MAESTRO_LOCK_CLAIM_BACKEND=lockf ;;
  Linux) _MAESTRO_LOCK_CLAIM_BACKEND=flock ;;
  *) _MAESTRO_LOCK_CLAIM_BACKEND=unavailable ;;
esac
export -n _MAESTRO_LOCK_CLAIM_DIR _MAESTRO_LOCK_CLAIM_IDENTITY \
  _MAESTRO_LOCK_CLAIM_TOKEN _MAESTRO_LOCK_CLAIM_NONCE \
  _MAESTRO_LOCK_CLAIM_GATE _MAESTRO_LOCK_CLAIM_SAVED_FD \
  _MAESTRO_LOCK_CLAIM_MODE _MAESTRO_LOCK_CLAIM_BACKEND 2>/dev/null || :

lock_claim_current_matches() { # lock-dir identity token [present|initializing|absent|opaque]
  local lock_dir="$1" identity="$2" token="$3" mode="${4:-present}"
  local current_identity current_token metadata
  case "$mode" in present|initializing|absent|opaque) ;; *) return 1 ;; esac
  current_identity=$(lock_claim_path_identity "$lock_dir") || return 1
  [ "$current_identity" = "$identity" ] || return 1
  [ "$mode" != opaque ] || return 0
  metadata="$lock_dir/metadata"
  if [ ! -e "$metadata" ] && [ ! -L "$metadata" ]; then
    [ "$mode" = initializing ] || [ "$mode" = absent ]
    return
  fi
  [ "$mode" != absent ] && [ -f "$metadata" ] && [ ! -L "$metadata" ] ||
    return 1
  current_token=$(lock_claim_metadata_value_once "$metadata" token) || return 1
  [ "$current_token" = "$token" ] || return 1
  lock_claim_record_matches_identity "$metadata" "$identity"
}

lock_claim_gate_path() { # lock-dir
  local lock_dir="$1"
  case "$lock_dir" in
    /*/*) printf '%s/maestro-generation-claim.lock' "${lock_dir%/*}" ;;
    *) return 1 ;;
  esac
}

lock_claim_fd19_save() {
  local fd
  [ -z "$_MAESTRO_LOCK_CLAIM_SAVED_FD" ] || return 1
  if ! eval ': <&19' 2>/dev/null; then
    _MAESTRO_LOCK_CLAIM_SAVED_FD=closed
    return 0
  fi
  fd=20
  while [ "$fd" -le 255 ]; do
    if ! eval ": <&$fd" 2>/dev/null; then
      eval "exec $fd<&19" || return 1
      _MAESTRO_LOCK_CLAIM_SAVED_FD=$fd
      return 0
    fi
    fd=$((fd + 1))
  done
  return 1
}

lock_claim_fd19_restore() {
  local saved="$_MAESTRO_LOCK_CLAIM_SAVED_FD"
  [ -n "$saved" ] || return 1
  exec 19>&- || :
  if [ "$saved" != closed ]; then
    eval "exec 19<&$saved" || return 1
    eval "exec $saved>&-" || return 1
  fi
  _MAESTRO_LOCK_CLAIM_SAVED_FD=""
}

lock_claim_gate_acquire() { # gate-path
  local gate="$1" rc=1
  (umask 077; : >> "$gate") || return 1
  lock_claim_fd19_save || return 1
  if ! exec 19>>"$gate"; then
    lock_claim_fd19_restore || :
    return 1
  fi
  case "$_MAESTRO_LOCK_CLAIM_BACKEND" in
    lockf)
      command -v lockf >/dev/null 2>&1 &&
        lockf -s -t 0 19 >/dev/null 2>&1
      rc=$?
      ;;
    flock)
      command -v flock >/dev/null 2>&1 &&
        flock -n 19 >/dev/null 2>&1
      rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    lock_claim_fd19_restore || :
    return 1
  fi
}

lock_claim_publish_generation() { # lock-dir generation
  local marker="$1/generation"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  (umask 077; printf '%s\n' "$2" > "$marker") 19>&-
}

lock_claim_create() { # lock-dir output-identity; 0=created, 1=exists/clean-failure, 2=gate unavailable, 3=unsafe residue
  local lock_dir="$1" output_var="${2-}" gate generation created_identity rc=1
  case "$output_var" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
  printf -v "$output_var" '%s' ""
  [ -z "$_MAESTRO_LOCK_CLAIM_DIR" ] || return 2
  generation=$(lock_claim_random_id) || return 1
  gate=$(lock_claim_gate_path "$lock_dir") || return 2
  lock_claim_gate_acquire "$gate" || return 2
  if (umask 077; mkdir "$lock_dir") 19>&- 2>/dev/null; then
    if ! lock_claim_publish_generation "$lock_dir" "$generation"; then
      rm -f "$lock_dir/generation" 19>&- 2>/dev/null || :
      if rmdir "$lock_dir" 19>&- 2>/dev/null ||
        { [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; }; then
        rc=1
      else
        rc=3
      fi
    elif created_identity=$(lock_claim_path_identity "$lock_dir"); then
      printf -v "$output_var" '%s' "$created_identity"
      rc=0
    else
      rc=3
    fi
  fi
  lock_claim_fd19_restore || return 2
  return "$rc"
}

lock_claim_forget() {
  _MAESTRO_LOCK_CLAIM_DIR=""
  _MAESTRO_LOCK_CLAIM_IDENTITY=""
  _MAESTRO_LOCK_CLAIM_TOKEN=""
  _MAESTRO_LOCK_CLAIM_NONCE=""
  _MAESTRO_LOCK_CLAIM_GATE=""
  _MAESTRO_LOCK_CLAIM_MODE=""
}

lock_claim_unlock() {
  local rc=0
  lock_claim_fd19_restore || rc=$?
  lock_claim_forget
  _MAESTRO_LOCK_CLAIM_SAVED_FD=""
  return "$rc"
}
lock_claim_acquire() { # lock-dir identity token [present|initializing|absent|opaque]
  local lock_dir="$1" identity="$2" token="$3" mode="${4:-present}" gate nonce
  [ -n "$identity" ] && [ -n "$token" ] || return 1
  case "$mode" in present|initializing|absent|opaque) ;; *) return 1 ;; esac
  [ -z "$_MAESTRO_LOCK_CLAIM_DIR" ] || return 1
  lock_claim_current_matches "$lock_dir" "$identity" "$token" "$mode" ||
    return 1
  gate=$(lock_claim_gate_path "$lock_dir") || return 1
  nonce=$(lock_claim_random_id) || return 1
  lock_claim_gate_acquire "$gate" || return 1
  _MAESTRO_LOCK_CLAIM_DIR=$lock_dir
  _MAESTRO_LOCK_CLAIM_IDENTITY=$identity
  _MAESTRO_LOCK_CLAIM_TOKEN=$token
  _MAESTRO_LOCK_CLAIM_NONCE=$nonce
  _MAESTRO_LOCK_CLAIM_GATE=$gate
  _MAESTRO_LOCK_CLAIM_MODE=$mode
  if ! lock_claim_current_matches "$lock_dir" "$identity" "$token" "$mode"; then
    lock_claim_unlock
    return 1
  fi
}

lock_claim_path() {
  [ "$_MAESTRO_LOCK_CLAIM_DIR" = "$1" ] || return 1
  printf '%s' "$1"
}

lock_claim_current_path_matches() { # identity token
  [ -n "$_MAESTRO_LOCK_CLAIM_DIR" ] &&
    lock_claim_current_matches "$_MAESTRO_LOCK_CLAIM_DIR" "$1" "$2" \
      "$_MAESTRO_LOCK_CLAIM_MODE"
}

lock_claim_release() { # lock-dir identity token
  local lock_dir="$1" identity="$2" token="$3" rc=1
  [ "$_MAESTRO_LOCK_CLAIM_DIR" = "$lock_dir" ] || return 1
  [ "$_MAESTRO_LOCK_CLAIM_IDENTITY" = "$identity" ] || return 1
  [ "$_MAESTRO_LOCK_CLAIM_TOKEN" = "$token" ] || return 1
  lock_claim_current_matches "$lock_dir" "$identity" "$token" \
    "$_MAESTRO_LOCK_CLAIM_MODE" && rc=0
  lock_claim_unlock || return 1
  return "$rc"
}

lock_claim_move() { # lock-dir identity token destination
  local lock_dir="$1" identity="$2" token="$3" destination="$4"
  [ "$_MAESTRO_LOCK_CLAIM_DIR" = "$lock_dir" ] || return 1
  [ "$_MAESTRO_LOCK_CLAIM_IDENTITY" = "$identity" ] || return 1
  [ "$_MAESTRO_LOCK_CLAIM_TOKEN" = "$token" ] || return 1
  if ! lock_claim_current_path_matches "$identity" "$token" ||
    [ -e "$destination" ] ||
    ! mv "$lock_dir" "$destination" 19>&- 2>/dev/null; then
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  if ! lock_claim_unlock; then
    progress "MAESTRO_LOCK_CLEANUP: canonical lock retired; generation gate cleanup failed"
  fi
  return 0
}

lock_claim_discard() { # lock-dir identity token
  local lock_dir="$1" identity="$2" token="$3" destination
  destination="${lock_dir}.reclaim.${_MAESTRO_LOCK_CLAIM_NONCE:-$$}"
  lock_claim_move "$lock_dir" "$identity" "$token" "$destination" || return 1
  if ! rm -rf "$destination" 2>/dev/null; then
    progress "MAESTRO_LOCK_CLEANUP: canonical lock released; cleanup of retired generation failed: $destination"
  fi
  return 0
}

lock_claim_release_active() {
  local lock_dir="$_MAESTRO_LOCK_CLAIM_DIR"
  [ -n "$lock_dir" ] || return 0
  lock_claim_release "$lock_dir" "$_MAESTRO_LOCK_CLAIM_IDENTITY" \
    "$_MAESTRO_LOCK_CLAIM_TOKEN" || :
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
  local metadata="$1" require_job="${2:-0}" token generation pid session class start job
  [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
  token=$(lock_claim_metadata_value_once "$metadata" token) || return 1
  generation=$(lock_claim_metadata_value_once "$metadata" generation) || return 1
  pid=$(job_lock_metadata_value "$metadata" pid)
  session=$(job_lock_metadata_value "$metadata" session)
  class=$(job_lock_metadata_value "$metadata" class)
  start=$(job_lock_metadata_value "$metadata" start)
  job=$(job_lock_metadata_value "$metadata" job)
  [ -n "$token" ] || return 1
  lock_claim_generation_valid "$generation" || return 1
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

job_lock_publish_metadata() { # lock-dir identity token record
  local lock_dir="$1" identity="$2" token="$3" record="$4"
  local metadata temp recorded_token
  metadata="$lock_dir/metadata"
  temp="$lock_dir/metadata.tmp.$token"
  lock_claim_acquire "$lock_dir" "$identity" "$token" initializing || return 1
  if [ -f "$metadata" ]; then
    recorded_token=$(job_lock_metadata_value "$metadata" token)
    if [ "$recorded_token" != "$token" ]; then
      lock_claim_release "$lock_dir" "$identity" "$token" || :
      return 1
    fi
  fi
  if ! (umask 077; printf '%s\n' "$record" > "$temp") 19>&- ||
    ! mv -f "$temp" "$metadata" 19>&-; then
    rm -f "$temp" 19>&- 2>/dev/null || :
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  if ! recorded_token=$(lock_claim_metadata_value_once "$metadata" token); then
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  lock_claim_release "$lock_dir" "$identity" "$token" || return 1
  [ "$recorded_token" = "$token" ]
}

job_lock_cleanup_failed_publication() { # lock-dir identity token
  local lock_dir="$1" identity="$2" token="$3" current_identity current_token
  [ -d "$lock_dir" ] || return 0
  lock_claim_acquire "$lock_dir" "$identity" "$token" initializing || return 1
  current_identity=$(job_lock_path_identity "$lock_dir") || current_identity=""
  current_token=$(job_lock_metadata_value "$lock_dir/metadata" token)
  if [ "$current_identity" != "$identity" ] ||
    { [ -n "$current_token" ] && [ "$current_token" != "$token" ]; }; then
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  lock_claim_discard "$lock_dir" "$identity" "$token"
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
        const job = value?.job;
        if (!value || typeof value !== "object" || Array.isArray(value) ||
            !job || typeof job !== "object" || Array.isArray(job) ||
            job.id !== expected || typeof job.status !== "string" ||
            !/^[A-Za-z][A-Za-z_-]*$/.test(job.status)) process.exit(4);
        process.stdout.write(`${job.status.toLowerCase()}\n`);
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
  local age mtime generation_identity current_identity create_rc
  case "$class" in read|write) ;; *) return 3 ;; esac
  MAESTRO_JOB_LOCK_TOKEN=""
  MAESTRO_JOB_LOCK_IDENTITY=""
  MAESTRO_JOB_LOCK_ACQUIRED=0
  MAESTRO_JOB_LOCK_DIR=$(job_lock_path) || return 3
  metadata="$MAESTRO_JOB_LOCK_DIR/metadata"

  wait_cap=${MAESTRO_LOCK_WAIT_SEC:-14400}
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
  token=$(lock_claim_random_id) || {
    progress "MAESTRO_JOB_LOCK: lock token generation failed; no lock was created"
    return 3
  }


  while :; do
    create_rc=0
    generation_identity=""
    lock_claim_create "$MAESTRO_JOB_LOCK_DIR" generation_identity || create_rc=$?
    if [ "$create_rc" -eq 2 ]; then
      if job_lock_wait_tick "$deadline" unknown unknown unknown \
        "$MAESTRO_JOB_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_JOB_LOCK: companion dispatch blocked by a competing generation claimant (lock: $MAESTRO_JOB_LOCK_DIR)"
      return 11
    fi
    if [ "$create_rc" -eq 3 ]; then
      progress "MAESTRO_JOB_LOCK: lock generation initialization failed and the canonical generation could not be retired; retaining fail-closed lock (lock: $MAESTRO_JOB_LOCK_DIR)"
      return 11
    fi
    if [ "$create_rc" -eq 0 ]; then
      session=$(job_lock_session_id)
      now=$(date +%s)
      generation=$(lock_claim_identity_generation "$generation_identity") || return 11
      record=$(printf 'token=%s\ngeneration=%s\npid=%s\nsession=%s\nclass=%s\nstart=%s' \
        "$token" "$generation" "$$" "${session:-unknown}" "$class" "$now")
      if ! job_lock_publish_metadata "$MAESTRO_JOB_LOCK_DIR" "$generation_identity" "$token" "$record"; then
        if ! job_lock_cleanup_failed_publication "$MAESTRO_JOB_LOCK_DIR" \
          "$generation_identity" "$token"; then
          progress "MAESTRO_JOB_LOCK: metadata publication failed and the canonical generation could not be retired; retaining fail-closed lock (lock: $MAESTRO_JOB_LOCK_DIR)"
          return 11
        fi
        return 3
      fi
      MAESTRO_JOB_LOCK_TOKEN=$token
      MAESTRO_JOB_LOCK_IDENTITY=$generation_identity
      MAESTRO_JOB_LOCK_ACQUIRED=1
      return 0
    fi
    [ -d "$MAESTRO_JOB_LOCK_DIR" ] || return 3
    generation_identity=$(job_lock_path_identity "$MAESTRO_JOB_LOCK_DIR") || {
      job_lock_recovery_message "lock generation identity is unavailable; failing closed" "$MAESTRO_JOB_LOCK_DIR"
      return 11
    }

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

    if ! job_lock_metadata_valid "$metadata" 0 ||
      ! lock_claim_record_matches_identity "$metadata" "$generation_identity"; then
      job_lock_recovery_message "metadata is malformed or belongs to another generation; owner cannot be identified; failing closed" "$MAESTRO_JOB_LOCK_DIR"
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
    if ! lock_claim_acquire "$MAESTRO_JOB_LOCK_DIR" \
      "$generation_identity" "$recorded_token"; then
      progress "MAESTRO_JOB_LOCK: companion dispatch blocked by a competing generation claimant (lock: $MAESTRO_JOB_LOCK_DIR)"
      return 11
    fi
    reclaim=$(lock_claim_path "$MAESTRO_JOB_LOCK_DIR") || {
      lock_claim_release "$MAESTRO_JOB_LOCK_DIR" \
        "$generation_identity" "$recorded_token" || :
      return 11
    }
    if ! lock_claim_current_path_matches "$generation_identity" "$recorded_token"; then
      lock_claim_release "$MAESTRO_JOB_LOCK_DIR" \
        "$generation_identity" "$recorded_token" || :
      continue
    fi
    lock_claim_discard "$MAESTRO_JOB_LOCK_DIR" \
      "$generation_identity" "$recorded_token" || return 11
  done
}

job_lock_publish_job() { # job-id
  local job="${1-}" metadata recorded_token generation pid session class start record
  local expected_identity current_identity
  job_lock_job_valid "$job" || return 3
  [ "${MAESTRO_JOB_LOCK_ACQUIRED:-0}" -eq 1 ] || return 3
  metadata="${MAESTRO_JOB_LOCK_DIR:-}/metadata"
  [ -f "$metadata" ] || return 3
  recorded_token=$(job_lock_metadata_value "$metadata" token)
  if [ "$recorded_token" != "${MAESTRO_JOB_LOCK_TOKEN:-}" ]; then
    progress "MAESTRO_JOB_LOCK: lock generation changed while publishing job=$job"
    return 3
  fi
  expected_identity=${MAESTRO_JOB_LOCK_IDENTITY:-}
  current_identity=$(job_lock_path_identity "$MAESTRO_JOB_LOCK_DIR") || current_identity=""
  if [ -z "$expected_identity" ] || [ "$current_identity" != "$expected_identity" ]; then
    progress "MAESTRO_JOB_LOCK: lock directory identity changed while publishing job=$job"
    return 3
  fi
  lock_claim_record_matches_identity "$metadata" "$expected_identity" || {
    progress "MAESTRO_JOB_LOCK: lock metadata belongs to another generation while publishing job=$job"
    return 3
  }
  pid=$(job_lock_metadata_value "$metadata" pid)
  session=$(job_lock_metadata_value "$metadata" session)
  class=$(job_lock_metadata_value "$metadata" class)
  start=$(job_lock_metadata_value "$metadata" start)
  generation=$(lock_claim_identity_generation "$expected_identity") || return 3
  record=$(printf 'token=%s\ngeneration=%s\npid=%s\nsession=%s\nclass=%s\nstart=%s\njob=%s' \
    "$recorded_token" "$generation" "$pid" "$session" "$class" "$start" "$job")
  job_lock_publish_metadata "$MAESTRO_JOB_LOCK_DIR" "$expected_identity" "$recorded_token" "$record"
}

job_lock_release() {
  local metadata recorded_token observed_identity
  [ "${MAESTRO_JOB_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_JOB_LOCK_DIR:-}/metadata"
  if [ -z "${MAESTRO_JOB_LOCK_DIR:-}" ] || [ ! -f "$metadata" ]; then
    progress "MAESTRO_JOB_LOCK: acquired lock metadata is unavailable during release; retaining local ownership"
    return 11
  fi
  observed_identity=${MAESTRO_JOB_LOCK_IDENTITY:-}
  if [ -z "$observed_identity" ]; then
    progress "MAESTRO_JOB_LOCK: acquired lock identity is unavailable during release; retaining the lock"
    return 11
  fi
  recorded_token=$(lock_claim_metadata_value_once "$metadata" token) || recorded_token=""
  if [ "$recorded_token" != "${MAESTRO_JOB_LOCK_TOKEN:-}" ]; then
    progress "MAESTRO_JOB_LOCK: lock token changed before release; retaining the lock"
    return 11
  fi
  if ! lock_claim_record_matches_identity "$metadata" "$observed_identity"; then
    progress "MAESTRO_JOB_LOCK: lock metadata belongs to another generation before release; retaining the lock"
    return 11
  fi
  if ! lock_claim_acquire "$MAESTRO_JOB_LOCK_DIR" \
    "$observed_identity" "$recorded_token"; then
    progress "MAESTRO_JOB_LOCK: generation claim is unavailable during release; retaining the lock"
    return 11
  fi
  if ! lock_claim_current_path_matches "$observed_identity" "$recorded_token"; then
    lock_claim_release "$MAESTRO_JOB_LOCK_DIR" \
      "$observed_identity" "$recorded_token" || :
    progress "MAESTRO_JOB_LOCK: generation changed during release; releasing nothing"
    return 11
  fi
  if ! lock_claim_discard "$MAESTRO_JOB_LOCK_DIR" \
    "$observed_identity" "$recorded_token"; then
    progress "MAESTRO_JOB_LOCK: generation could not be retired during release; retaining the lock"
    return 11
  fi
  MAESTRO_JOB_LOCK_ACQUIRED=0
  MAESTRO_JOB_LOCK_TOKEN=""
  MAESTRO_JOB_LOCK_IDENTITY=""
  return 0
}
job_lock_clear() { # result-file evidence-file
  local result="${1-}" evidence="${2-}" lock_dir metadata age_path mtime now age
  local valid=0 token pid session class job state jobs reclaim current_token
  local observed_identity current_identity claim_token claim_mode=present
  [ -n "$result" ] && [ -n "$evidence" ] && [ "$result" != "$evidence" ] || return 3
  : > "$evidence" || return 3
  printf 'state=blocked\n' > "$result" || return 3
  lock_dir=$(job_lock_path) || return 3
  if [ ! -d "$lock_dir" ]; then
    progress "MAESTRO_JOB_LOCK: there is no companion job lock to clear at $lock_dir"
    printf 'state=absent\n' > "$result"
    return 0
  fi
  observed_identity=$(job_lock_path_identity "$lock_dir") || {
    progress "MAESTRO_JOB_LOCK: refusing to clear — lock generation identity is unconfirmed (lock: $lock_dir)"
    return 11
  }
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

  if job_lock_metadata_valid "$metadata" 1 &&
    lock_claim_record_matches_identity "$metadata" "$observed_identity"; then
    valid=1
  fi
  if [ "$valid" -eq 1 ]; then
    if ! job_lock_job_state "$job" state; then
      jobs=""
      if ! job_lock_workspace_jobs jobs; then
        progress "MAESTRO_JOB_LOCK: refusing to clear — companion status for holder class=$class job=$job session=$session and repository-global status are unavailable or malformed"
        return 11
      fi
      if [ -n "$jobs" ]; then
        progress "MAESTRO_JOB_LOCK: refusing to clear — companion status for holder class=$class job=$job session=$session is unavailable while repository-global job $(printf '%s\n' "$jobs" | awk 'NF { print $1; exit }') is running"
        return 11
      fi
      progress "MAESTRO_JOB_LOCK: holder pid=$pid is dead and repository-global status confirms no running jobs; clearing class=$class job=$job session=$session"
    elif ! job_lock_state_terminal "$state"; then
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
    claim_token=$token
    claim_mode=present
  else
    claim_token="untrusted-$observed_identity"
    claim_mode=opaque
  fi
  if ! lock_claim_acquire "$lock_dir" "$observed_identity" "$claim_token" \
    "$claim_mode"; then
    progress "MAESTRO_JOB_LOCK: refusing to clear — generation claim is unavailable"
    return 11
  fi
  reclaim=$(lock_claim_path "$lock_dir") || {
    lock_claim_release "$lock_dir" "$observed_identity" "$claim_token" || :
    return 11
  }
  current_identity=$(job_lock_path_identity "$reclaim") || current_identity=""
  if [ "$current_identity" != "$observed_identity" ]; then
    lock_claim_release "$lock_dir" "$observed_identity" "$claim_token" || :
    progress "MAESTRO_JOB_LOCK: refusing to clear — lock generation changed during recovery"
    return 11
  fi
  metadata="$reclaim/metadata"
  if [ "$valid" -eq 0 ]; then
    if job_lock_metadata_valid "$metadata" 0; then
      lock_claim_release "$lock_dir" "$observed_identity" "$claim_token" || :
      progress "MAESTRO_JOB_LOCK: refusing to clear — metadata became valid during recovery"
      return 11
    fi
  else
    current_token=$(job_lock_metadata_value "$metadata" token)
    if [ "$current_token" != "$token" ]; then
      lock_claim_release "$lock_dir" "$observed_identity" "$claim_token" || :
      progress "MAESTRO_JOB_LOCK: refusing to clear — lock generation changed during recovery"
      return 11
    fi
  fi
  lock_claim_discard "$lock_dir" "$observed_identity" "$claim_token" ||
    return 11
  if [ -d "$lock_dir" ]; then
    progress "MAESTRO_JOB_LOCK: cleared the requested generation, but a successor already holds the lock"
    return 11
  fi
  progress "MAESTRO_JOB_LOCK: cleared companion job lock (class=$class job=$job session=$session)"
  printf 'state=cleared\n' > "$result"
  return 0
}
