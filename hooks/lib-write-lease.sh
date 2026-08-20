#!/usr/bin/env bash
# Maestro run-scoped write Lease interval module. Sourced, not executed.

[ "${_MAESTRO_WRITE_LEASE_LOADED-0}" = 1 ] && return 0
_MAESTRO_WRITE_LEASE_LOADED=1

_MAESTRO_WRITE_LEASE_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-companion.sh
. "$_MAESTRO_WRITE_LEASE_HERE/lib-companion.sh"

# Interface:
#   write_lease_begin EVIDENCE_FILE
#   _write_lease_turn_event EVENT JOB REASON RESULT_FILE EVIDENCE_FILE
#   write_lease_end EVIDENCE_FILE
#   write_lease_clear RESULT_FILE EVIDENCE_FILE
# One process owns one Lease interval. Begin rejects inherited capability state;
# end releases only the acquired generation; clear is generation-fenced recovery.

# Lease authority is process-local. Never accept inherited environment state as
# proof that this shell owns the repository write interval.
MAESTRO_LOCK_TOKEN=""
MAESTRO_LOCK_DIR=""
MAESTRO_LOCK_IDENTITY=""
MAESTRO_LOCK_ACQUIRED=0
_MAESTRO_WRITE_LEASE_RETAIN=0
export -n MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_IDENTITY \
  MAESTRO_LOCK_ACQUIRED 2>/dev/null || :
repo_digest() {
  local inside worktree roots root_list digest material tracked untracked paths entries
  local regular_paths hashes link_output link_rc path type mode contents nested_list candidate nested_top
  local root_queue discovered root
  inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || return 1
  [ "$inside" = "true" ] || return 1
  worktree=$(write_lock_scope_root) || return 1
  [ -d "$worktree" ] || return 1
  root_list=$(mktemp "${TMPDIR:-/tmp}/maestro-repo-roots.XXXXXX") || return 1
  root_queue="${root_list}.queue"
  discovered="${root_list}.discovered"
  nested_list="${root_list}.nested"
  if ! (
    : > "$root_list" || exit 1
    : > "$root_queue" || exit 1
    printf '%s\n' "$worktree" >> "$root_queue" || exit 1

    exec 9< "$root_queue" || exit 1
    while IFS= read -r root <&9; do
      [ -n "$root" ] || continue
      grep -Fqx -- "$root" "$root_list" 2>/dev/null && continue
      printf '%s\n' "$root" >> "$root_list" || exit 1
      : > "$discovered" || exit 1
      git -C "$root" submodule foreach --recursive --quiet \
        'printf "%s\n" "$PWD"' >> "$discovered" 2>/dev/null || exit 1
      git -C "$root" ls-files --others --exclude-standard -z \
        > "$nested_list" 2>/dev/null || exit 1
      while IFS= read -r -d '' path; do
        candidate="$root/${path%/}"
        [ -e "$candidate/.git" ] || continue
        nested_top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
        nested_top=$(cd "$nested_top" 2>/dev/null && pwd -P) || continue
        [ "$nested_top" = "$(cd "$candidate" 2>/dev/null && pwd -P)" ] || continue
        printf '%s\n' "$nested_top" >> "$discovered" || exit 1
      done < "$nested_list"
      while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        nested_top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
        nested_top=$(cd "$nested_top" 2>/dev/null && pwd -P) || continue
        [ "$nested_top" = "$(cd "$candidate" 2>/dev/null && pwd -P)" ] || continue
        grep -Fqx -- "$nested_top" "$root_list" 2>/dev/null ||
          printf '%s\n' "$nested_top" >> "$root_queue" || exit 1
      done < "$discovered"
    done
    exec 9<&-
  ); then
    rm -f "$root_list" "$root_queue" "$discovered" "$nested_list"
    return 1
  fi
  roots=$(LC_ALL=C sort -u "$root_list") || {
    rm -f "$root_list" "$root_queue" "$discovered" "$nested_list"
    return 1
  }
  rm -f "$root_list" "$root_queue" "$discovered" "$nested_list"
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
        if ! xargs -0 git -C "$worktree" hash-object --no-filters -- \
          < "$regular_paths" > "$hashes" 2>/dev/null; then
          # A path can vanish after enumeration. Re-run only this degraded case
          # individually so the unavailable marker stays paired with that path.
          : > "$hashes"
          while IFS= read -r -d '' path; do
            if contents=$(git -C "$worktree" hash-object --no-filters -- "$path" 2>/dev/null); then
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
  if ! digest=$(git hash-object --no-filters --stdin < "$material" 2>/dev/null); then
    rm -f "$material" "$tracked" "$untracked" "$paths" "$entries" "$regular_paths" "$hashes"
    return 1
  fi
  rm -f "$material" "$tracked" "$untracked" "$paths" "$entries" "$regular_paths" "$hashes"
  [ -n "$digest" ] || return 1
  printf 'tree-v3:%s\n' "$digest"
}

repo_digest_bounded() {
  local timeout="${MAESTRO_DIGEST_TIMEOUT_SEC-120}"
  local scratch out err rc invalid=0
  case "$timeout" in
    ''|*[!0-9]*) invalid=1 ;;
    *) [ "$timeout" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_DIGEST: repository digest: ignoring invalid timeout_seconds=$timeout; using 120s"
    timeout=120
  fi
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-repo-digest-call.XXXXXX") || return 1
  out="$scratch/stdout"
  err="$scratch/stderr"
  TMPDIR="$scratch" process_run_bounded "$timeout" \
    "MAESTRO_DIGEST: repository digest" write_lock_heartbeat_write \
    "$out" "$err" -- repo_digest
  rc=$?
  [ ! -s "$err" ] || cat "$err" >&2
  if [ "$rc" -eq 0 ]; then
    cat "$out"
  fi
  rm -rf "$scratch" || rc=1
  [ "$rc" -eq 0 ] || return 1
}

repo_digest_is_observed() {
  case "$1" in
    tree-v3:*) return 0 ;;
    *) return 1 ;;
  esac
}

write_lock_scope_root() {
  maestro_workspace_scope_root
}

write_lock_path() {
  local workspace git_dir
  if workspace=$(write_lock_scope_root); then
    if git_dir=$(git -C "$workspace" rev-parse --git-dir 2>/dev/null); then
      case "$git_dir" in
        /*) ;;
        *) git_dir="$workspace/$git_dir" ;;
      esac
      printf '%s/maestro-write.lock' "$(cd "$git_dir" && pwd -P)"
      return 0
    fi
  fi
  workspace=$(pwd -P) || return 1
  printf '%s/.maestro-write.lock' "$workspace"
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

provenance_log_append() { # path record
  local log_path="$1" record="$2"
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [file, record] = process.argv.slice(1);
    const noFollow = fs.constants.O_NOFOLLOW;
    if (noFollow === undefined) process.exit(2);
    const flags = fs.constants.O_WRONLY | fs.constants.O_APPEND |
      fs.constants.O_CREAT | noFollow;
    try {
      const fd = fs.openSync(file, flags, 0o600);
      try {
        fs.fchmodSync(fd, 0o600);
        fs.writeFileSync(fd, `${record}\n`);
      } finally {
        fs.closeSync(fd);
      }
    } catch (error) {
      if (error?.code !== "ELOOP") throw error;
      const temp = path.join(path.dirname(file),
        `.maestro-provenance.${process.pid}.${Date.now()}`);
      try {
        fs.writeFileSync(temp, `${record}\n`, { flag: "wx", mode: 0o600 });
        fs.renameSync(temp, file);
      } catch (replaceError) {
        try { fs.rmSync(temp); } catch {}
        throw replaceError;
      }
    }
  ' "$log_path" "$record" 2>/dev/null
}

write_lock_metadata_value() {
  local metadata="$1" field="$2"
  sed -n "s/^${field}=//p" "$metadata" 19>&- 2>/dev/null | head -1 19>&-
}

write_lock_remove_publication_temps() { # lock-dir
  local lock_dir="$1"
  rm -f "$lock_dir"/metadata.tmp.* "$lock_dir"/heartbeat.tmp.* 2>/dev/null
}

write_lock_unknown_entry() { # lock-dir output-variable
  local lock_dir="$1" output_var="$2" entry base
  printf -v "$output_var" '%s' ""
  for entry in "$lock_dir"/* "$lock_dir"/.[!.]* "$lock_dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    case "$base" in
      generation|metadata|metadata.new|heartbeat|metadata.tmp.*|heartbeat.tmp.*) continue ;;
    esac
    printf -v "$output_var" '%s' "$entry"
    return 0
  done
  return 1
}

write_lock_publish_metadata() {   # lock_dir identity token record
  local lock_dir="$1" identity="$2" token="$3" record="$4"
  local metadata temp recorded_token
  metadata="$lock_dir/metadata"
  temp="$lock_dir/metadata.tmp.$token"
  lock_claim_acquire "$lock_dir" "$identity" "$token" initializing || return 1
  if [ -f "$metadata" ]; then
    recorded_token=$(write_lock_metadata_value "$metadata" token)
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
write_lock_cleanup_failed_publication() { # lock-dir identity token
  local lock_dir="$1" identity="$2" token="$3" current_identity current_token
  [ -d "$lock_dir" ] || return 0
  lock_claim_acquire "$lock_dir" "$identity" "$token" initializing || return 1
  current_identity=$(write_lock_path_identity "$lock_dir") || current_identity=""
  current_token=$(write_lock_metadata_value "$lock_dir/metadata" token)
  if [ "$current_identity" != "$identity" ] ||
    { [ -n "$current_token" ] && [ "$current_token" != "$token" ]; }; then
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  lock_claim_discard "$lock_dir" "$identity" "$token"
}


write_lock_heartbeat_write() {
  local interval invalid now last lock_dir heartbeat temp identity token generation
  write_lock_is_owner || return 0
  interval=${MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC:-20}
  invalid=0
  case "$interval" in
    *[!0-9]*) invalid=1 ;;
    *) [ "$interval" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_LOCK: invalid MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=$interval; using 20s"
    interval=20
    MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=$interval
  else
    interval=$((10#$interval))
  fi
  now=$(date +%s) || return 1
  last=${MAESTRO_LOCK_HEARTBEAT_LAST_WRITE_EPOCH:-0}
  if [ "${MAESTRO_LOCK_HEARTBEAT_LAST_TOKEN:-}" = "${MAESTRO_LOCK_TOKEN:-}" ] &&
    [ "$last" -ge 0 ] 2>/dev/null &&
    [ "$((now - last))" -lt "$interval" ]; then
    return 0
  fi
  lock_dir="${MAESTRO_LOCK_DIR:-$(write_lock_path)}"
  identity=${MAESTRO_LOCK_IDENTITY:-}
  token=${MAESTRO_LOCK_TOKEN:-}
  lock_claim_acquire "$lock_dir" "$identity" "$token" || return 0
  generation=$(lock_claim_identity_generation "$identity") || {
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  }
  heartbeat="$lock_dir/heartbeat"
  temp="$lock_dir/heartbeat.tmp.$token"
  if ! printf 'token=%s\ngeneration=%s\nepoch=%s\n' \
    "$token" "$generation" "$now" > "$temp" 19>&- ||
    ! mv -f "$temp" "$heartbeat" 19>&-; then
    rm -f "$temp" 19>&- 2>/dev/null || :
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  if ! lock_claim_release "$lock_dir" "$identity" "$token"; then
    return 1
  fi
  MAESTRO_LOCK_HEARTBEAT_LAST_WRITE_EPOCH=$now
  MAESTRO_LOCK_HEARTBEAT_LAST_TOKEN=$token
}

write_lock_heartbeat_epoch() {   # lock_dir token identity
  local lock_dir="$1" token="$2" identity="${3-}" heartbeat recorded_token
  heartbeat="$lock_dir/heartbeat"
  [ -f "$heartbeat" ] && [ ! -L "$heartbeat" ] || return 0
  recorded_token=$(lock_claim_metadata_value_once "$heartbeat" token) || return 0
  [ "$recorded_token" = "$token" ] || return 0
  [ -z "$identity" ] ||
    lock_claim_record_matches_identity "$heartbeat" "$identity" || return 0
  write_lock_metadata_value "$heartbeat" epoch
}

write_lock_heartbeat_stale_sec() {
  local stale invalid
  stale=${MAESTRO_LOCK_HEARTBEAT_STALE_SEC:-90}
  invalid=0
  case "$stale" in
    *[!0-9]*) invalid=1 ;;
    *) [ "$stale" -ge 0 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "MAESTRO_LOCK: invalid MAESTRO_LOCK_HEARTBEAT_STALE_SEC=$stale; using 90s"
    stale=90
  else
    stale=$((10#$stale))
  fi
  printf '%s\n' "$stale"
}

write_lock_process_start() {   # pid
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

write_lock_path_mtime_epoch() { # path
  stat -c '%Y' "$1" 19>&- 2>/dev/null ||
    stat -f '%m' "$1" 19>&- 2>/dev/null
}
write_lock_path_identity() { # path
  lock_claim_path_identity "$1"
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

# Bounded, unordered wait for a queueable lease. Returns 0 when the caller should
# re-classify and retry, 1 when it should stop waiting and block.
# ponytail: no ticket files, so no arrival order and nothing to reap — the cap
# bounds starvation. Add FIFO only if starvation is actually reproduced.
write_lock_wait_tick() {   # deadline job session lock_dir
  local deadline="$1" job="$2" session="$3" lock_dir="$4"
  local now remaining sleep_for last_log log_interval=30
  [ "$deadline" -gt 0 ] 2>/dev/null || return 1
  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || return 1
  remaining=$((deadline - now))
  sleep_for=$MAESTRO_LOCK_WAIT_POLL_SEC
  [ "$sleep_for" -le "$remaining" ] || sleep_for=$remaining
  last_log=${MAESTRO_LOCK_WAIT_LAST_LOG_EPOCH:-0}
  if [ "$last_log" -eq 0 ] || [ "$((now - last_log))" -ge "$log_interval" ]; then
    progress "MAESTRO_LOCK: waiting for the write lease held by job=$job session=$session — ${remaining}s left before blocking (lock: $lock_dir); arrival order is not guaranteed"
    MAESTRO_LOCK_WAIT_LAST_LOG_EPOCH=$now
  fi
  sleep "$sleep_for"
  return 0
}

write_lock_wait_summary() {   # wait-start wait-budget
  local started="$1" budget="$2" now elapsed
  case "$started" in
    ''|*[!0-9]*)
      printf 'wait_budget=%ss wait_elapsed=unknown' "$budget"
      return 0
      ;;
  esac
  now=$(date +%s) || {
    printf 'wait_budget=%ss wait_elapsed=unknown' "$budget"
    return 0
  }
  elapsed=$((now - started))
  [ "$elapsed" -ge 0 ] || elapsed=0
  printf 'wait_budget=%ss wait_elapsed=%ss' "$budget" "$elapsed"
}

write_lock_poison_gate() {   # lock_dir metadata → 11 when poisoned (after printing), else 0
  local lock_dir="$1" metadata="$2"
  local poison_metadata quiescence unconfirmed_job unconfirmed_reason owner_session
  write_lock_effective_poison "$lock_dir" "$metadata" poison_metadata quiescence
  [ "$quiescence" = "unconfirmed" ] || return 0
  unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
  unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
  owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
  owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
  progress "MAESTRO_LOCK: write dispatch blocked; quiescence is unconfirmed for job=${unconfirmed_job:-unknown} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown} (lock: $lock_dir). Clear it once no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
  return 11
}

write_lock_effective_poison() { # lock-dir metadata output-path output-quiescence
  local lock_dir="$1" metadata="$2" path_var="$3" quiescence_var="$4"
  local effective_path="$metadata" effective_quiescence
  effective_quiescence=$(write_lock_metadata_value "$effective_path" quiescence)
  if [ "$effective_quiescence" != unconfirmed ] && [ -e "$lock_dir/metadata.new" ]; then
    effective_path="$lock_dir/metadata.new"
    effective_quiescence=unconfirmed
  fi
  printf -v "$path_var" '%s' "$effective_path"
  printf -v "$quiescence_var" '%s' "$effective_quiescence"
}

write_lock_is_owner() {
  local lock_dir metadata recorded_token current_identity
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || {
    [ -n "${MAESTRO_LOCK_TOKEN:-}" ] || return 1
  }
  [ -n "${MAESTRO_LOCK_IDENTITY:-}" ] || return 1
  lock_dir="${MAESTRO_LOCK_DIR:-$(write_lock_path)}"
  current_identity=$(write_lock_path_identity "$lock_dir") || return 1
  [ "$current_identity" = "$MAESTRO_LOCK_IDENTITY" ] || return 1
  metadata="$lock_dir/metadata"
  [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
  recorded_token=$(lock_claim_metadata_value_once "$metadata" token) || return 1
  [ -n "${MAESTRO_LOCK_TOKEN:-}" ] &&
    [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ] &&
    lock_claim_record_matches_identity "$metadata" "$MAESTRO_LOCK_IDENTITY"
}


write_lock_workspace_writers() { # output-variable
  local output_var="${1-}" scratch result evidence rc observed=""
  case "$output_var" in
    ''|[0-9]*|*[!a-zA-Z0-9_]*) return 4 ;;
  esac
  printf -v "$output_var" '%s' ""
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-writers.XXXXXX") ||
    return 4
  result="$scratch/result"
  evidence="$scratch/evidence"
  companion_writers "$result" "$evidence"
  rc=$?
  [ ! -s "$evidence" ] || cat "$evidence" >&2
  if [ "$rc" -eq 0 ]; then
    observed=$(cat "$result")
    printf -v "$output_var" '%s' "$observed"
  fi
  rm -rf "$scratch"
  return "$rc"
}

write_lock_acquire() {
  local requested_job="${1:-unknown}" metadata recorded_token owner_pid owner_start
  local owner_job started_epoch current_start held now attempt token process_start owner_alive
  local identity_note owner_session malformed_metadata
  local writers writers_rc digest_before log_path last prior_job prior_after observed_at
  local stale_digest_before stale_digest_after stale_released_at session_id started_at
  local metadata_record reclaim_dir current_token generation_identity current_identity generation
  local wait_cap wait_poll wait_deadline wait_started_epoch initializing_grace remaining sleep_for
  local heartbeat_stale heartbeat_epoch heartbeat_effective heartbeat_age heartbeat_note create_rc
  MAESTRO_LOCK_ACQUIRED=0
  MAESTRO_LOCK_IDENTITY=""
  MAESTRO_LOCK_WAIT_LAST_LOG_EPOCH=0
  MAESTRO_LOCK_DIR=$(write_lock_path) || return 3
  metadata="$MAESTRO_LOCK_DIR/metadata"

  wait_cap=${MAESTRO_LOCK_WAIT_SEC:-14400}
  wait_poll=${MAESTRO_LOCK_WAIT_POLL_SEC:-5}
  # A typo must fail fast: silently substituting a long default would hide bad input.
  case "$wait_cap" in
    *[!0-9]*)
      progress "MAESTRO_LOCK: invalid MAESTRO_LOCK_WAIT_SEC=$wait_cap; waiting disabled"
      wait_cap=0
      ;;
    *) wait_cap=$((10#$wait_cap)) ;;
  esac
  case "$wait_poll" in
    *[!0-9]*)
      progress "MAESTRO_LOCK: invalid MAESTRO_LOCK_WAIT_POLL_SEC=$wait_poll; waiting disabled"
      wait_cap=0
      wait_poll=1
      ;;
    *)
      if [ "$wait_poll" -lt 1 ]; then
        progress "MAESTRO_LOCK: invalid MAESTRO_LOCK_WAIT_POLL_SEC=$wait_poll; waiting disabled"
        wait_cap=0
        wait_poll=1
      else
        wait_poll=$((10#$wait_poll))
      fi
      ;;
  esac
  MAESTRO_LOCK_WAIT_POLL_SEC=$wait_poll
  heartbeat_stale=$(write_lock_heartbeat_stale_sec)

  write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata" || return 11


  initializing_grace=0
  wait_started_epoch=$(date +%s 2>/dev/null) || wait_started_epoch=""
  case "$wait_started_epoch" in
    ''|*[!0-9]*)
      progress "MAESTRO_LOCK: wait clock unavailable; waiting disabled"
      wait_cap=0
      wait_deadline=0
      ;;
    *)
      if [ "$wait_cap" -gt 0 ]; then
        wait_deadline=$((wait_started_epoch + wait_cap))
      else
        wait_deadline=0
      fi
      ;;
  esac
  token=$(lock_claim_random_id) || {
    progress "MAESTRO_LOCK: lock token generation failed; no lease was created"
    return 3
  }

  attempt=0
  while [ "$attempt" -lt 2 ]; do
    write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata" || return 11
    create_rc=0
    generation_identity=""
    lock_claim_create "$MAESTRO_LOCK_DIR" generation_identity || create_rc=$?
    if [ "$create_rc" -eq 2 ]; then
      if write_lock_wait_tick "$wait_deadline" unknown unknown \
        "$MAESTRO_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_LOCK: write dispatch blocked by a competing generation claimant ($(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    if [ "$create_rc" -eq 3 ]; then
      progress "MAESTRO_LOCK: lease generation initialization failed and the canonical generation could not be retired; retaining fail-closed lock (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    if [ "$create_rc" -eq 0 ]; then
      process_start=$(write_lock_process_start "$$")
      # ponytail: mkdir gives mutual exclusion; ps only sharpens stale-owner recovery.
      # Without it, record the gap and let the contention path fail closed instead.
      if [ -z "$process_start" ]; then
        process_start=unavailable
        progress "MAESTRO_LOCK: process start identity unavailable for pid=$$; lease recorded without it (stale-owner recovery will fail closed)"
      fi
      session_id=$(write_lock_session_id)
      now=$(date +%s)
      started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      generation=$(lock_claim_identity_generation "$generation_identity") || return 11
      metadata_record=$(printf 'token=%s\ngeneration=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=unavailable' \
        "$token" "$generation" "$$" "$process_start" "$requested_job" "${session_id:-unknown}" \
        "$started_at" "$now")
      if ! write_lock_publish_metadata "$MAESTRO_LOCK_DIR" "$generation_identity" "$token" "$metadata_record"; then
        if ! write_lock_cleanup_failed_publication "$MAESTRO_LOCK_DIR" \
          "$generation_identity" "$token"; then
          progress "MAESTRO_LOCK: metadata publication failed and the canonical generation could not be retired; retaining fail-closed lock (lock: $MAESTRO_LOCK_DIR)"
          return 11
        fi
        return 3
      fi
      MAESTRO_LOCK_TOKEN="$token"
      MAESTRO_LOCK_IDENTITY="$generation_identity"
      MAESTRO_LOCK_ACQUIRED=1

      digest_before=$(repo_digest_bounded 2>/dev/null) || digest_before=unavailable
      metadata_record=$(printf 'token=%s\ngeneration=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s' \
        "$token" "$generation" "$$" "$process_start" "$requested_job" "${session_id:-unknown}" \
        "$started_at" "$now" "$digest_before")
      if ! write_lock_publish_metadata "$MAESTRO_LOCK_DIR" "$generation_identity" "$token" "$metadata_record"; then
        progress "MAESTRO_LOCK: repository digest could not be recorded; lease retains digest_before=unavailable (lock: $MAESTRO_LOCK_DIR)"
      fi

      if log_path=$(provenance_log_path 2>/dev/null) &&
        [ -f "$log_path" ] && [ ! -L "$log_path" ]; then
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
            provenance_log_append "$log_path" "$(printf '%s type=gap prior_job=%s session=%s expected=%s observed=%s' \
              "$observed_at" "$prior_job" "${session_id:-unknown}" "$prior_after" "$digest_before")" || :
          fi
        fi
      fi
      return 0
    fi

    if [ ! -d "$MAESTRO_LOCK_DIR" ]; then
      progress "MAESTRO_LOCK: could not create write lock at $MAESTRO_LOCK_DIR"
      return 3
    fi
    generation_identity=$(write_lock_path_identity "$MAESTRO_LOCK_DIR") || {
      progress "MAESTRO_LOCK: write lease generation identity is unavailable; failing closed (lock: $MAESTRO_LOCK_DIR)"
      return 11
    }

    if [ ! -f "$metadata" ]; then
      if [ "$wait_cap" -gt 0 ] && [ "$initializing_grace" -lt 3 ]; then
        now=$(date +%s 2>/dev/null) || now=""
        case "$now" in
          ''|*[!0-9]*) wait_cap=0 ;;
          *)
            remaining=$((wait_deadline - now))
            if [ "$remaining" -gt 0 ]; then
              sleep_for=1
              [ "$sleep_for" -le "$remaining" ] || sleep_for=$remaining
              initializing_grace=$((initializing_grace + 1))
              sleep "$sleep_for"
              continue
            fi
            ;;
        esac
      fi
      progress "MAESTRO_LOCK: write dispatch blocked by an initializing owner (job=unknown session=unknown pid=unknown held=unknown; $(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    if ! lock_claim_record_matches_identity "$metadata" "$generation_identity"; then
      progress "MAESTRO_LOCK: write lease metadata is malformed or belongs to another generation; owner cannot be identified; failing closed (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    recorded_token=$(write_lock_metadata_value "$metadata" token)
    owner_pid=$(write_lock_metadata_value "$metadata" pid)
    owner_start=$(write_lock_metadata_value "$metadata" process_start)
    owner_job=$(write_lock_metadata_value "$metadata" job_id)
    owner_session=$(write_lock_metadata_value "$metadata" session_id)
    owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
    started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
    stale_digest_before=$(write_lock_metadata_value "$metadata" digest_before)
    malformed_metadata=0
    case "$owner_pid" in
      ''|*[!0-9]*) malformed_metadata=1 ;;
    esac
    if [ -z "$recorded_token" ] || [ "$malformed_metadata" -eq 1 ]; then
      progress "MAESTRO_LOCK: write lease metadata is malformed; owner cannot be identified; failing closed (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    owner_job=${owner_job:-unknown}
    stale_digest_before=${stale_digest_before:-unavailable}
    owner_alive=0
    current_start=""
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      owner_alive=1
      current_start=$(write_lock_process_start "$owner_pid")
    fi

    if [ "$owner_alive" -eq 1 ] &&
      { [ -z "$current_start" ] || [ -z "$owner_start" ] ||
        [ "$owner_start" = unavailable ] || [ "$current_start" = "$owner_start" ]; }; then
      identity_note=""
      heartbeat_note=""
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
          if [ "$heartbeat_stale" -ne 0 ]; then
            heartbeat_effective=$started_epoch
            heartbeat_epoch=$(write_lock_heartbeat_epoch "$MAESTRO_LOCK_DIR" \
              "$recorded_token" "$generation_identity")
            case "$heartbeat_epoch" in
              ''|*[!0-9]*) ;;
              *)
                [ "$heartbeat_epoch" -gt "$heartbeat_effective" ] &&
                  heartbeat_effective=$heartbeat_epoch
                ;;
            esac
            heartbeat_age=$((now - heartbeat_effective))
            [ "$heartbeat_age" -lt 0 ] && heartbeat_age=0
            if [ "$heartbeat_age" -gt "$heartbeat_stale" ]; then
              heartbeat_note="; heartbeat is stale (last tick ${heartbeat_age}s ago, threshold ${heartbeat_stale}s) — the owner may be wedged. Recover only after confirming that process is done: kill it yourself, then bash hooks/implementer-loop.sh --clear-lease"
            else
              heartbeat_note="; heartbeat is fresh (last tick ${heartbeat_age}s ago)"
            fi
          fi
          ;;
      esac
      if [ -z "$identity_note" ]; then
        if write_lock_wait_tick "$wait_deadline" "$owner_job" "${owner_session:-unknown}" "$MAESTRO_LOCK_DIR"; then
          continue
        fi
      fi
      progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown} for $held (lease_age=$held; $(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)${identity_note}${heartbeat_note}"
      return 11
    fi

    writers=""
    write_lock_workspace_writers writers
    writers_rc=$?
    if [ "$writers_rc" -eq 4 ]; then
      progress "MAESTRO_LOCK: dispatcher is gone but job liveness could not be determined; write lock retained (job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown}, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    if [ "$owner_job" != "unknown" ]; then
      if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
        if write_lock_wait_tick "$wait_deadline" "$owner_job" "${owner_session:-unknown}" "$MAESTRO_LOCK_DIR"; then
          continue
        fi
        progress "MAESTRO_LOCK: write dispatch blocked; lease retained because orphaned job=$owner_job session=${owner_session:-unknown} is still running ($(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
        return 11
      fi
    elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
      if write_lock_wait_tick "$wait_deadline" "$owner_job" "${owner_session:-unknown}" "$MAESTRO_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_LOCK: write dispatch blocked; lease retained because an unidentified write-capable job is still running (session=${owner_session:-unknown}; $(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    # Cancellation stages poison before the job disappears from the writers list.
    # Recheck after liveness so that transition cannot be erased as stale.
    write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata" || return 11

    # Serialize classification and atomically retire only this generation.
    # The kernel-backed claim is released automatically if this shell dies.
    current_token=$(write_lock_metadata_value "$metadata" token)
    if [ "$current_token" != "$recorded_token" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    if ! lock_claim_acquire "$MAESTRO_LOCK_DIR" \
      "$generation_identity" "$recorded_token"; then
      progress "MAESTRO_LOCK: write dispatch blocked by a competing generation claimant ($(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    reclaim_dir=$(lock_claim_path "$MAESTRO_LOCK_DIR") || {
      lock_claim_release "$MAESTRO_LOCK_DIR" \
        "$generation_identity" "$recorded_token" || :
      return 11
    }
    metadata="$reclaim_dir/metadata"
    if ! lock_claim_current_path_matches "$generation_identity" "$recorded_token"; then
      lock_claim_release "$MAESTRO_LOCK_DIR" \
        "$generation_identity" "$recorded_token" || :
      attempt=$((attempt + 1))
      continue
    fi
    if ! write_lock_poison_gate "$reclaim_dir" "$metadata"; then
      lock_claim_release "$MAESTRO_LOCK_DIR" \
        "$generation_identity" "$recorded_token" || :
      return 11
    fi

    stale_digest_after=$(repo_digest_bounded 19>&- 2>/dev/null) ||
      stale_digest_after=unavailable
    stale_released_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 19>&-)
    if repo_digest_is_observed "$stale_digest_before" &&
      repo_digest_is_observed "$stale_digest_after" &&
      [ "$stale_digest_before" != "$stale_digest_after" ]; then
      progress "PROVENANCE: ADOPTED UNOBSERVED INTERVAL — the tree changed while an orphaned lease was held (job=$owner_job, expected=$stale_digest_before, observed=$stale_digest_after); the interval was not observed and the author is unknown"
    fi
    if log_path=$(provenance_log_path 19>&- 2>/dev/null); then
      provenance_log_append "$log_path" "$(printf '%s type=orphan-adopted job=%s session=%s before=%s after=%s' \
        "$stale_released_at" "$owner_job" "${owner_session:-unknown}" \
        "$stale_digest_before" "$stale_digest_after")" 19>&- || :
    fi
    if lock_claim_discard "$MAESTRO_LOCK_DIR" \
      "$generation_identity" "$recorded_token"; then
      progress "MAESTRO_LOCK: broke stale write lock held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown}"
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
    progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown} for $held (lease_age=$held; $(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
    return 11
  done

  progress "MAESTRO_LOCK: write dispatch blocked by a competing acquirer (job=unknown session=unknown pid=unknown held=unknown; $(write_lock_wait_summary "$wait_started_epoch" "$wait_cap"); lock: $MAESTRO_LOCK_DIR)"
  return 11
}

write_lock_set_job() {
  local job="$1" metadata recorded_token owner_pid owner_start started_at started_epoch
  local digest_before session_id identity token generation metadata_record
  write_lock_is_owner || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; job update skipped"
    return 0
  }
  identity=${MAESTRO_LOCK_IDENTITY:-}
  token=${MAESTRO_LOCK_TOKEN:-}
  metadata="${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "$token" ] || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; job update skipped"
    return 0
  }
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  owner_start=$(write_lock_metadata_value "$metadata" process_start)
  started_at=$(write_lock_metadata_value "$metadata" started_at)
  started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  session_id=$(write_lock_metadata_value "$metadata" session_id)
  session_id=$(MAESTRO_SESSION_ID="${session_id:-}" write_lock_session_id)
  generation=$(lock_claim_identity_generation "$identity") || return 3
  metadata_record=$(printf 'token=%s\ngeneration=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s' \
    "$token" "$generation" "$owner_pid" "$owner_start" "$job" "${session_id:-unknown}" \
    "$started_at" "$started_epoch" "$digest_before")
  if ! write_lock_publish_metadata "$MAESTRO_LOCK_DIR" "$identity" "$token" \
    "$metadata_record"; then
    progress "MAESTRO_LOCK: this lease changed while publishing job=$job; job update rejected"
    return 3
  fi
}

write_lock_poison() {
  local job="$1" reason="$2" metadata next_metadata recorded_token owner_pid owner_start
  local owner_job started_at started_epoch digest_before session_id identity token generation
  write_lock_is_owner || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; poison not staged"
    return 3
  }
  identity=${MAESTRO_LOCK_IDENTITY:-}
  token=${MAESTRO_LOCK_TOKEN:-}
  lock_claim_acquire "$MAESTRO_LOCK_DIR" "$identity" "$token" || {
    progress "MAESTRO_LOCK: this lease changed before poison could be staged"
    return 3
  }
  metadata="$MAESTRO_LOCK_DIR/metadata"
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  if [ "$recorded_token" != "$token" ]; then
    lock_claim_release "$MAESTRO_LOCK_DIR" "$identity" "$token" || :
    progress "MAESTRO_LOCK: this lease is no longer held by this process; poison not staged"
    return 3
  fi
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  owner_start=$(write_lock_metadata_value "$metadata" process_start)
  owner_job=$(write_lock_metadata_value "$metadata" job_id)
  started_at=$(write_lock_metadata_value "$metadata" started_at)
  started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  session_id=$(write_lock_metadata_value "$metadata" session_id)
  session_id=$(MAESTRO_SESSION_ID="${session_id:-}" write_lock_session_id)
  generation=$(lock_claim_identity_generation "$identity") || {
    lock_claim_release "$MAESTRO_LOCK_DIR" "$identity" "$token" || :
    return 3
  }
  next_metadata="$MAESTRO_LOCK_DIR/metadata.new"
  if ! printf 'token=%s\ngeneration=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s\nquiescence=unconfirmed\nunconfirmed_job=%s\nunconfirmed_reason=%s\n' \
    "$token" "$generation" "$owner_pid" "$owner_start" "$owner_job" "${session_id:-unknown}" \
    "$started_at" "$started_epoch" "$digest_before" "$job" "$reason" \
    > "$next_metadata" 19>&-; then
    rm -f "$next_metadata" 19>&- 2>/dev/null || :
    lock_claim_release "$MAESTRO_LOCK_DIR" "$identity" "$token" || :
    return 3
  fi
  if ! lock_claim_release "$MAESTRO_LOCK_DIR" "$identity" "$token"; then
    progress "MAESTRO_LOCK: lease changed after poison staging; retaining fail-closed state"
    return 3
  fi
}

write_lock_finalize_poison() {
  local lock_dir identity token metadata next_metadata staged_token quiescence
  write_lock_is_owner || return 1
  lock_dir=${MAESTRO_LOCK_DIR:-}
  identity=${MAESTRO_LOCK_IDENTITY:-}
  token=${MAESTRO_LOCK_TOKEN:-}
  lock_claim_acquire "$lock_dir" "$identity" "$token" || return 1
  metadata="$lock_dir/metadata"
  next_metadata="$lock_dir/metadata.new"
  staged_token=$(write_lock_metadata_value "$next_metadata" token)
  quiescence=$(write_lock_metadata_value "$next_metadata" quiescence)
  if [ "$staged_token" != "$token" ] || [ "$quiescence" != unconfirmed ] ||
    ! lock_claim_record_matches_identity "$next_metadata" "$identity" ||
    ! mv -f "$next_metadata" "$metadata" 19>&-; then
    lock_claim_release "$lock_dir" "$identity" "$token" || :
    return 1
  fi
  lock_claim_release "$lock_dir" "$identity" "$token"
}

write_lock_release() {
  local metadata recorded_token owner_job owner_session writers writers_rc quiescence
  local unconfirmed_job unconfirmed_reason poison_metadata claimed current_token
  local digest_before digest_after log_path released_at observed_identity current_identity unknown_entry
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_LOCK_DIR:-}/metadata"
  if [ -z "${MAESTRO_LOCK_DIR:-}" ] || [ ! -f "$metadata" ]; then
    progress "MAESTRO_LOCK: acquired lease metadata is unavailable during release; retaining fail-closed state"
    return 11
  fi
  observed_identity=${MAESTRO_LOCK_IDENTITY:-}
  [ -n "$observed_identity" ] || {
    progress "MAESTRO_LOCK: acquired lease identity is unavailable during release; retaining the lock"
    return 11
  }
  current_identity=$(write_lock_path_identity "$MAESTRO_LOCK_DIR") || {
    progress "MAESTRO_LOCK: lease generation identity is unavailable during release; retaining the lock"
    return 11
  }
  [ "$current_identity" = "$observed_identity" ] || {
    progress "MAESTRO_LOCK: lease generation changed before release; releasing nothing"
    return 11
  }
  lock_claim_record_matches_identity "$metadata" "$observed_identity" || {
    progress "MAESTRO_LOCK: lease metadata belongs to another generation during release; retaining the lock"
    return 11
  }
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; releasing nothing"
    return 11
  }
  owner_job=$(write_lock_metadata_value "$metadata" job_id)
  owner_job=${owner_job:-unknown}
  owner_session=$(write_lock_metadata_value "$metadata" session_id)
  owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
  write_lock_effective_poison "$MAESTRO_LOCK_DIR" "$metadata" \
    poison_metadata quiescence
  if [ "$poison_metadata" != "$metadata" ] &&
    ! lock_claim_record_matches_identity "$poison_metadata" "$observed_identity"; then
    progress "MAESTRO_LOCK: staged poison belongs to another generation; retaining the lock"
    return 11
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
    unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
    progress "MAESTRO_LOCK: write lease retained because quiescence was never confirmed (job=${unconfirmed_job:-$owner_job} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi
  if [ "$_MAESTRO_WRITE_LEASE_RETAIN" -eq 1 ]; then
    progress "MAESTRO_LOCK: write lease retained because cancellation poison could not be persisted (job=$owner_job session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi

  writers=""
  write_lock_workspace_writers writers
  writers_rc=$?
  if [ "$writers_rc" -eq 4 ]; then
    progress "MAESTRO_LOCK: job liveness could not be determined; write lease retained (job=$owner_job session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi
  if [ "$owner_job" != "unknown" ]; then
    if printf '%s\n' "$writers" | awk -v job="$owner_job" '$1 == job { found = 1 } END { exit !found }'; then
      progress "MAESTRO_LOCK: write lease retained because job $owner_job session=${owner_session:-unknown} is still running; a later dispatch will resolve it (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
  elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
    progress "MAESTRO_LOCK: write lease retained because an unidentified write-capable job is still running; a later dispatch will resolve it (session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi

  digest_before=$(write_lock_metadata_value "$metadata" digest_before)
  digest_before=${digest_before:-unavailable}
  digest_after=$(repo_digest_bounded 2>/dev/null) || digest_after=unavailable
  released_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  write_lock_effective_poison "$MAESTRO_LOCK_DIR" "$metadata" \
    poison_metadata quiescence
  if [ "$poison_metadata" != "$metadata" ] &&
    ! lock_claim_record_matches_identity "$poison_metadata" "$observed_identity"; then
    progress "MAESTRO_LOCK: staged poison generation changed during release; retaining the lock"
    return 11
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    progress "MAESTRO_LOCK: write lease retained because cancellation poison arrived during release (lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi
  current_token=$(write_lock_metadata_value "$metadata" token)
  if [ "$current_token" != "${MAESTRO_LOCK_TOKEN:-}" ]; then
    progress "MAESTRO_LOCK: lease token changed during release; retaining the lock"
    return 11
  fi
  if ! lock_claim_acquire "$MAESTRO_LOCK_DIR" \
    "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}"; then
    progress "MAESTRO_LOCK: lease release lost the generation claim; retaining the lock"
    return 11
  fi
  claimed=$(lock_claim_path "$MAESTRO_LOCK_DIR") || {
    lock_claim_release "$MAESTRO_LOCK_DIR" \
      "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}" || :
    progress "MAESTRO_LOCK: lease release lost its claimed path; retaining the lock"
    return 11
  }
  metadata="$claimed/metadata"
  if ! lock_claim_current_path_matches "$observed_identity" \
    "${MAESTRO_LOCK_TOKEN:-}"; then
    lock_claim_release "$MAESTRO_LOCK_DIR" \
      "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}" || :
    progress "MAESTRO_LOCK: lease generation changed during release; releasing nothing"
    return 11
  fi
  write_lock_effective_poison "$claimed" "$metadata" poison_metadata quiescence 19>&-
  if [ "$poison_metadata" != "$metadata" ] &&
    ! lock_claim_record_matches_identity "$poison_metadata" "$observed_identity"; then
    lock_claim_release "$MAESTRO_LOCK_DIR" \
      "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}" || :
    progress "MAESTRO_LOCK: staged poison generation changed during release; retaining the lock"
    return 11
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    lock_claim_release "$MAESTRO_LOCK_DIR" \
      "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}" || :
    progress "MAESTRO_LOCK: write lease retained because cancellation poison arrived during release (lock: $MAESTRO_LOCK_DIR)"
    return 11
  fi
  if write_lock_unknown_entry "$claimed" unknown_entry; then
    lock_claim_release "$MAESTRO_LOCK_DIR" \
      "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}" || :
    progress "MAESTRO_LOCK: write lease retained because its directory contains an unrecognized entry ($unknown_entry)"
    return 11
  fi
  if log_path=$(provenance_log_path 19>&- 2>/dev/null); then
    provenance_log_append "$log_path" "$(printf '%s type=dispatch job=%s session=%s before=%s after=%s' \
      "$released_at" "$owner_job" "${owner_session:-unknown}" "$digest_before" "$digest_after")" 19>&- || :
  fi
  if ! lock_claim_discard "$MAESTRO_LOCK_DIR" \
    "$observed_identity" "${MAESTRO_LOCK_TOKEN:-}"; then
    progress "MAESTRO_LOCK: lease generation could not be removed after release; retaining fail-closed state"
    return 11
  fi
  MAESTRO_LOCK_ACQUIRED=0
  MAESTRO_LOCK_IDENTITY=""
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
  if ! log_path=$(provenance_log_path 2>/dev/null) ||
    [ ! -f "$log_path" ] || [ -L "$log_path" ]; then
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

write_lease_clear() { # result-file evidence-file
  local result="${1-}" evidence="${2-}"
  local lock_path metadata staged_metadata heartbeat orphan stale_heartbeat heartbeat_missing
  local lock_mtime now lock_age poisoned_job poisoned_reason poisoned_session
  local poison_metadata quiescence owner_token owner_job owner_session owner_pid
  local owner_start started_epoch malformed heartbeat_stale heartbeat_note
  local heartbeat_effective heartbeat_epoch heartbeat_age current_start
  local writers writers_rc running_job clear_token reclaim_dir claim_mode
  local current_poison current_quiescence current_token generation_claim_token
  local recovery_record recovery_pid recovery_start observed_identity current_identity
  [ -n "$result" ] && [ -n "$evidence" ] && [ "$result" != "$evidence" ] ||
    return 3
  : > "$evidence" || return 3
  printf 'state=blocked\n' > "$result" || return 3
  lock_path=$(write_lock_path) || {
    printf 'state=failed\n' > "$result"
    printf 'MAESTRO_LOCK: could not resolve the write lock path\n' >> "$evidence"
    return 3
  }
  if [ ! -d "$lock_path" ]; then
    progress "MAESTRO_LOCK: there is no write lease to clear at $lock_path"
    printf 'state=absent\n' > "$result"
    return 0
  fi
  observed_identity=$(write_lock_path_identity "$lock_path") || {
    progress "MAESTRO_LOCK: refusing to clear — Lease interval identity is unconfirmed (lock: $lock_path)"
    return 11
  }

  metadata="$lock_path/metadata"
  staged_metadata="$lock_path/metadata.new"
  heartbeat="$lock_path/heartbeat"
  orphan=0
  stale_heartbeat=0
  heartbeat_missing=0
  if [ ! -e "$metadata" ] && [ ! -e "$staged_metadata" ]; then
    lock_mtime=$(write_lock_path_mtime_epoch "$lock_path") || {
      progress "MAESTRO_LOCK: refusing to clear — metadata is absent and lock age is unconfirmed (lock: $lock_path)"
      return 11
    }
    now=$(date +%s)
    lock_age=$((now - lock_mtime))
    [ "$lock_age" -ge 0 ] || lock_age=0
    if [ "$lock_age" -lt 5 ]; then
      progress "MAESTRO_LOCK: refusing to clear — metadata is absent but the ${lock_age}s-old lease may still be initializing (lock: $lock_path); retry after 5s"
      return 11
    fi
    orphan=1
    poisoned_job=unknown
    poisoned_reason=missing-metadata
    poisoned_session=unknown
  else
    write_lock_effective_poison "$lock_path" "$metadata" \
      poison_metadata quiescence
    if [ ! -f "$metadata" ] || [ -L "$metadata" ] ||
      ! lock_claim_record_matches_identity "$metadata" "$observed_identity"; then
      progress "MAESTRO_LOCK: refusing to clear — Lease interval metadata belongs to another generation (lock: $lock_path)"
      return 11
    fi
    if [ "$poison_metadata" != "$metadata" ] &&
      { [ ! -f "$poison_metadata" ] || [ -L "$poison_metadata" ] ||
        ! lock_claim_record_matches_identity "$poison_metadata" "$observed_identity"; }; then
      progress "MAESTRO_LOCK: refusing to clear — staged Lease interval metadata is malformed or belongs to another generation (lock: $lock_path)"
      return 11
    fi
    if [ "$quiescence" != "unconfirmed" ]; then
      owner_token=$(write_lock_metadata_value "$metadata" token)
      owner_job=$(write_lock_metadata_value "$metadata" job_id)
      owner_job=${owner_job:-unknown}
      owner_session=$(write_lock_metadata_value "$metadata" session_id)
      owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
      owner_pid=$(write_lock_metadata_value "$metadata" pid)
      owner_start=$(write_lock_metadata_value "$metadata" process_start)
      started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
      malformed=0
      case "$owner_pid" in
        ''|*[!0-9]*) malformed=1 ;;
      esac
      if [ -z "$owner_token" ] || [ "$malformed" -eq 1 ]; then
        progress "MAESTRO_LOCK: refusing to clear — write lease metadata is malformed; owner cannot be identified; failing closed (lock: $lock_path)"
        return 11
      fi
      heartbeat_stale=$(write_lock_heartbeat_stale_sec)
      heartbeat_note=""
      case "$started_epoch" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$heartbeat_stale" -ne 0 ]; then
            now=$(date +%s)
            heartbeat_effective=$started_epoch
            heartbeat_epoch=$(write_lock_heartbeat_epoch "$lock_path" \
              "$owner_token" "$observed_identity")
            case "$heartbeat_epoch" in
              ''|*[!0-9]*)
                heartbeat_missing=1
                ;;
              *)
                [ "$heartbeat_epoch" -gt "$heartbeat_effective" ] &&
                  heartbeat_effective=$heartbeat_epoch
                ;;
            esac
            heartbeat_age=$((now - heartbeat_effective))
            [ "$heartbeat_age" -lt 0 ] && heartbeat_age=0
            if [ "$heartbeat_age" -gt "$heartbeat_stale" ]; then
              stale_heartbeat=1
            elif [ "$heartbeat_missing" -eq 1 ]; then
              heartbeat_note="; metadata-only lease (heartbeat file missing; lease start ${heartbeat_age}s old)"
            else
              heartbeat_note="; heartbeat ${heartbeat_age}s old"
            fi
          fi
          ;;
      esac
      if [ "$stale_heartbeat" -eq 0 ]; then
        progress "MAESTRO_LOCK: refusing to clear — write lease is healthy and not this command's to clear (job=$owner_job session=${owner_session:-unknown} pid=$owner_pid, lock: $lock_path)${heartbeat_note}"
        return 11
      fi
      if kill -0 "$owner_pid" 2>/dev/null; then
        current_start=$(write_lock_process_start "$owner_pid")
        if [ -z "$current_start" ] || [ -z "$owner_start" ] ||
          [ "$owner_start" = unavailable ] || [ "$current_start" = "$owner_start" ]; then
          progress "MAESTRO_LOCK: refusing to clear — heartbeat is stale but the recorded owner process is still alive or its identity is unconfirmed (job=$owner_job session=${owner_session:-unknown} pid=$owner_pid, lock: $lock_path)"
          return 11
        fi
      fi
      poisoned_job=$owner_job
      poisoned_session=$owner_session
    fi
    if [ "$stale_heartbeat" -eq 0 ]; then
      poisoned_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
      poisoned_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
      poisoned_session=$(write_lock_metadata_value "$poison_metadata" session_id)
      poisoned_session=$(MAESTRO_SESSION_ID="${poisoned_session:-}" write_lock_session_id)
    fi
  fi
  if [ "$orphan" -eq 0 ]; then
    clear_token=$(write_lock_metadata_value "$poison_metadata" token)
    if [ -z "$clear_token" ] && [ "$poison_metadata" != "$metadata" ]; then
      clear_token=$(write_lock_metadata_value "$metadata" token)
    fi
    if [ -z "$clear_token" ]; then
      progress "MAESTRO_LOCK: refusing to clear — Lease interval generation is missing (lock: $lock_path)"
      return 11
    fi
    recovery_record="$metadata"
    [ -f "$recovery_record" ] || recovery_record="$poison_metadata"
    recovery_pid=$(write_lock_metadata_value "$recovery_record" pid)
    recovery_start=$(write_lock_metadata_value "$recovery_record" process_start)
    case "$recovery_pid" in
      ''|*[!0-9]*)
        progress "MAESTRO_LOCK: refusing to clear — Lease interval owner identity is malformed (lock: $lock_path)"
        return 11
        ;;
    esac
    if kill -0 "$recovery_pid" 2>/dev/null; then
      current_start=$(write_lock_process_start "$recovery_pid")
      if [ -z "$current_start" ] || [ -z "$recovery_start" ] ||
        [ "$recovery_start" = unavailable ] ||
        [ "$current_start" = "$recovery_start" ]; then
        progress "MAESTRO_LOCK: refusing to clear — Lease interval owner process is still alive or its identity is unconfirmed (pid=$recovery_pid, lock: $lock_path)"
        return 11
      fi
    fi
  fi

  writers=""
  write_lock_workspace_writers writers
  writers_rc=$?
  running_job=""
  if [ "$writers_rc" -eq 0 ]; then
    running_job=$(printf '%s\n' "$writers" |
      awk '$2 == "true" { print $1; exit }')
  fi
  if [ "$writers_rc" -eq 4 ] || [ -n "$running_job" ]; then
    progress "MAESTRO_LOCK: refusing to clear — a write-capable job is still running (${running_job:-unknown}) session=${poisoned_session:-unknown}"
    return 11
  fi
  generation_claim_token=${clear_token:-}
  claim_mode=present
  if [ -z "$generation_claim_token" ]; then
    generation_claim_token="orphan-$observed_identity"
    claim_mode=absent
  fi
  if ! lock_claim_acquire "$lock_path" "$observed_identity" \
    "$generation_claim_token" "$claim_mode"; then
    progress "MAESTRO_LOCK: refusing to clear — generation claim is unavailable (lock: $lock_path)"
    return 11
  fi
  reclaim_dir=$(lock_claim_path "$lock_path") || {
    lock_claim_release "$lock_path" "$observed_identity" \
      "$generation_claim_token" || :
    return 11
  }
  metadata="$reclaim_dir/metadata"
  staged_metadata="$reclaim_dir/metadata.new"
  if [ "$orphan" -eq 1 ]; then
    if [ -e "$metadata" ] || [ -e "$staged_metadata" ]; then
      lock_claim_release "$lock_path" "$observed_identity" \
        "$generation_claim_token" || :
      progress "MAESTRO_LOCK: refusing to clear — metadata appeared while claiming the orphan Lease interval"
      return 11
    fi
    current_identity=$(write_lock_path_identity "$reclaim_dir") || current_identity=""
    if [ "$current_identity" != "$observed_identity" ]; then
      lock_claim_release "$lock_path" "$observed_identity" \
        "$generation_claim_token" || :
      progress "MAESTRO_LOCK: refusing to clear — Lease interval generation changed during recovery"
      return 11
    fi
  else
    write_lock_effective_poison "$reclaim_dir" "$metadata" \
      current_poison current_quiescence 19>&-
    if [ "$current_poison" != "$metadata" ] &&
      { [ ! -f "$current_poison" ] || [ -L "$current_poison" ] ||
        ! lock_claim_record_matches_identity "$current_poison" "$observed_identity"; }; then
      lock_claim_release "$lock_path" "$observed_identity" \
        "$generation_claim_token" || :
      progress "MAESTRO_LOCK: refusing to clear — Lease interval poison belongs to another generation"
      return 11
    fi
    current_identity=$(write_lock_path_identity "$reclaim_dir") || current_identity=""
    current_token=$(write_lock_metadata_value "$current_poison" token)
    if [ -z "$current_token" ] && [ "$current_poison" != "$metadata" ]; then
      current_token=$(write_lock_metadata_value "$metadata" token)
    fi
    if [ "$current_identity" != "$observed_identity" ] ||
      [ "$current_token" != "$clear_token" ] ||
      { [ "$stale_heartbeat" -eq 0 ] &&
        [ "$current_quiescence" != unconfirmed ]; }; then
      lock_claim_release "$lock_path" "$observed_identity" \
        "$generation_claim_token" || :
      progress "MAESTRO_LOCK: refusing to clear — Lease interval generation changed during recovery"
      return 11
    fi
  fi

  if [ "$orphan" -eq 1 ]; then
    progress "MAESTRO_LOCK: clearing structurally invalid orphan write lease (lock: $lock_path, removing atomically: every entry in the claimed generation)"
  elif [ "$stale_heartbeat" -eq 1 ] && [ "$heartbeat_missing" -eq 1 ]; then
    progress "MAESTRO_LOCK: clearing metadata-only write lease after its missing heartbeat exceeded the stale threshold (job=$owner_job session=${owner_session:-unknown} lease_start_age=${heartbeat_age}s, lock: $lock_path)"
  elif [ "$stale_heartbeat" -eq 1 ]; then
    progress "MAESTRO_LOCK: clearing a write lease whose heartbeat went stale (job=$owner_job session=${owner_session:-unknown} last_heartbeat=${heartbeat_age}s ago, lock: $lock_path)"
  elif [ -e "$reclaim_dir/metadata.new" ]; then
    progress "MAESTRO_LOCK: clearing poisoned write lease (job=${poisoned_job:-unknown} session=${poisoned_session:-unknown} reason=${poisoned_reason:-unknown}, lock: $lock_path, removing staged entry atomically: $lock_path/metadata.new)"
  else
    progress "MAESTRO_LOCK: clearing poisoned write lease (job=${poisoned_job:-unknown} session=${poisoned_session:-unknown} reason=${poisoned_reason:-unknown}, lock: $lock_path)"
  fi
  if ! lock_claim_discard "$lock_path" "$observed_identity" \
    "$generation_claim_token"; then
    progress "MAESTRO_LOCK: failed to atomically remove the claimed write lease generation at $lock_path"
    return 11
  fi
  if [ -d "$lock_path" ]; then
    progress "MAESTRO_LOCK: cleared the requested generation, but a successor already holds the write lease (lock: $lock_path)"
    return 11
  fi
  printf 'state=cleared\n' > "$result"
  return 0
}

_write_lease_turn_event() { # event job reason result-file evidence-file
  local event="${1-}" job="${2-}" reason="${3:-unknown}"
  local result="${4-}" evidence="${5-}" metadata current_job
  [ -n "$result" ] && [ -n "$evidence" ] && [ "$result" != "$evidence" ] ||
    return 3

  case "$event" in
    guard)
      if ! write_lock_is_owner; then
        printf 'MAESTRO_LOCK: write launch rejected because Lease interval ownership changed\n' >> "$evidence" 2>/dev/null || :
        return 11
      fi
      write_lock_poison_gate "${MAESTRO_LOCK_DIR:-$(write_lock_path)}" \
        "${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata" || return 11
      ;;
    started)
      [[ "$job" =~ ^task-[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] || return 3
      write_lock_is_owner || return 11
      write_lock_set_job "$job" || return 3
      write_lock_is_owner || return 11
      ;;
    tick)
      write_lock_heartbeat_write
      ;;
    cancel-begin)
      _MAESTRO_WRITE_LEASE_RETAIN=1
      if ! write_lock_is_owner || ! write_lock_poison "$job" "$reason"; then
        printf 'MAESTRO_LOCK: cancellation poison could not be persisted (job=%s reason=%s)\n' \
          "$job" "$reason" >> "$evidence" 2>/dev/null || :
        return 11
      fi
      ;;
    cancel-end)
      _MAESTRO_WRITE_LEASE_RETAIN=1
      if ! write_lock_finalize_poison; then
        printf 'MAESTRO_LOCK: cancellation poison could not be finalized (job=%s reason=%s)\n' \
          "$job" "$reason" >> "$evidence" 2>/dev/null || :
        return 11
      fi
      ;;
    current-job)
      write_lock_is_owner || return 11
      metadata="${MAESTRO_LOCK_DIR}/metadata"
      current_job=$(write_lock_metadata_value "$metadata" job_id)
      printf 'job=%s\n' "${current_job:-unknown}" > "$result" || return 3
      ;;
    *)
      return 3
      ;;
  esac
}

write_lease_begin() { # evidence-file
  local evidence="${1-}"
  [ -n "$evidence" ] || return 3
  MAESTRO_LOCK_TOKEN=""
  MAESTRO_LOCK_DIR=""
  MAESTRO_LOCK_IDENTITY=""
  MAESTRO_LOCK_ACQUIRED=0
  _MAESTRO_WRITE_LEASE_RETAIN=0
  write_lock_acquire unknown
}

write_lease_end() { # evidence-file
  local evidence="${1-}" lock_path="${MAESTRO_LOCK_DIR:-}"
  [ -n "$evidence" ] || return 3
  write_lock_release || return $?
  if [ -z "$lock_path" ] || [ ! -d "$lock_path" ]; then
    MAESTRO_LOCK_TOKEN=""
    MAESTRO_LOCK_DIR=""
    MAESTRO_LOCK_IDENTITY=""
    MAESTRO_LOCK_ACQUIRED=0
    _MAESTRO_WRITE_LEASE_RETAIN=0
  fi
}
