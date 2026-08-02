#!/usr/bin/env bash
# Maestro companion library — shared Codex companion plumbing for the hook scripts.
# Sourced, not executed. All functions assume `set -uo pipefail` in the caller.
#
#   progress_init                          → keeps inherited FD 3, or opens it to caller stdout
#   progress <message>                     → writes one progress line to FD 3
#   repo_digest                            → prints a repository-wide state digest, or returns non-zero
#   write_lock_acquire [job]               → returns 0 acquired/inherited | 11 live contention
#   write_lock_is_owner                    → returns 0 for the acquirer or its inherited token
#   write_lock_heartbeat_write              → atomically refreshes the current owner's heartbeat
#   write_lock_heartbeat_epoch <dir> <token> → prints a matching heartbeat epoch
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
#                                             | 125 write timeout
#   companion_result <C> <job>             → prints result (retried), or returns 4
#
# Error-handling contract: a companion that cannot answer `status` 4 times in a row
# is cancelled instead of being polled forever; an empty `result` is fetched once
# more before being declared a failure. Hangs are cancelled by the poll itself.

progress_init() {
  if ! { true >&3; } 2>/dev/null; then exec 3>&1; fi
}

progress() { printf '%s\n' "$*" >&3; }

companion_result_state() { # result text → last valid full-line state
  printf '%s\n' "$1" |
    sed -nE 's/^RESULT:[[:space:]]*(DONE|NEEDS_ANSWERS|BLOCKED|FAILED)[[:space:]]*$/\1/p' |
    tail -1
}

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
  local regular_paths hashes link_output link_rc path type mode contents worktree nested_list candidate nested_top
  inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || return 1
  [ "$inside" = "true" ] || return 1
  worktrees=$(git worktree list --porcelain 2>/dev/null) || return 1
  worktrees=$(printf '%s\n' "$worktrees" | sed -n 's/^worktree //p' | LC_ALL=C sort) || return 1
  [ -n "$worktrees" ] || return 1
  root_list=$(mktemp "${TMPDIR:-/tmp}/maestro-repo-roots.XXXXXX") || return 1
  if ! (
    while IFS= read -r worktree; do
      [ -n "$worktree" ] || continue
      if [ ! -d "$worktree" ] ||
        ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'MAESTRO_DIGEST: skipping invalid/prunable worktree record: %s\n' "$worktree" >&2
        continue
      fi
      printf '%s\n' "$worktree"
      git -C "$worktree" submodule foreach --recursive --quiet \
        'printf "%s\n" "$PWD"' 2>/dev/null || exit 1
      nested_list="${root_list}.nested"
      git -C "$worktree" ls-files --others --exclude-standard -z \
        > "$nested_list" 2>/dev/null || exit 1
      while IFS= read -r -d '' path; do
        candidate="$worktree/${path%/}"
        [ -e "$candidate/.git" ] || continue
        nested_top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
        nested_top=$(cd "$nested_top" 2>/dev/null && pwd -P) || continue
        [ "$nested_top" = "$(cd "$candidate" 2>/dev/null && pwd -P)" ] || continue
        printf '%s\n' "$nested_top"
      done < "$nested_list"
      rm -f "$nested_list"
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
  printf 'tree-v2:%s\n' "$digest"
}

run_bounded() {
  local timeout="$1" label="$2" default="${run_bounded_default-120}"
  local invalid output pid elapsed timed_out grace rc start hb
  shift 2
  invalid=0
  case "$timeout" in
    ''|*[!0-9]*) invalid=1 ;;
    *) [ "$timeout" -ge 1 ] 2>/dev/null || invalid=1 ;;
  esac
  if [ "$invalid" -eq 1 ]; then
    progress "$label: ignoring invalid timeout_seconds=$timeout; using ${default}s"
    timeout=$default
  fi

  output=$(mktemp "${TMPDIR:-/tmp}/maestro-bounded-call.XXXXXX") || return 1
  set -m
  (
    "$@" > "$output"
  ) &
  pid=$!
  set +m

  start=$SECONDS
  hb=0
  elapsed=0
  timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      timed_out=1
      break
    fi
    sleep 0.1
    hb=$((hb + 1))
    if [ "$hb" -ge 10 ]; then
      write_lock_heartbeat_write
      hb=0
    fi
  done
  if [ "$timed_out" -eq 1 ]; then
    kill -TERM -"$pid" 2>/dev/null || :
    grace=0
    while kill -0 -"$pid" 2>/dev/null && [ "$grace" -lt 5 ]; do
      sleep 1
      grace=$((grace + 1))
    done
    kill -KILL -"$pid" 2>/dev/null || :
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  if [ "$timed_out" -eq 1 ]; then
    progress "$label: timed out after ${timeout}s"
    rc=125
  elif [ "$rc" -eq 0 ]; then
    cat "$output"
  fi
  rm -f "$output" 2>/dev/null || :
  return "$rc"
}

repo_digest_bounded() {
  local timeout scratch rc result="" run_bounded_default=120
  timeout=${MAESTRO_DIGEST_TIMEOUT_SEC-120}
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/maestro-repo-digest-call.XXXXXX") || return 1
  result=$(TMPDIR="$scratch" run_bounded "$timeout" \
    "MAESTRO_DIGEST: repository digest" repo_digest)
  rc=$?
  rm -rf "$scratch" || rc=1
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$result"
}

repo_digest_is_observed() {
  case "$1" in
    tree-v2:*) return 0 ;;
    *) return 1 ;;
  esac
}

write_lock_scope_root() {
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

write_lock_path() {
  local workspace git_dir
  if workspace=$(write_lock_scope_root); then
    if { git_dir=$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null) && [ -n "$git_dir" ]; } ||
      git_dir=$(git -C "$workspace" rev-parse --git-dir 2>/dev/null); then
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
  sed -n "s/^${field}=//p" "$metadata" 2>/dev/null | head -1
}

write_lock_publish_metadata() {   # lock_dir token record
  local lock_dir="$1" token="$2" record="$3" metadata temp recorded_token
  metadata="$lock_dir/metadata"
  temp="$lock_dir/metadata.tmp.$token"
  [ ! -d "$lock_dir/.reclaim" ] || return 1
  if [ -f "$metadata" ]; then
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    [ "$recorded_token" = "$token" ] || return 1
  fi
  printf '%s\n' "$record" > "$temp" || return 1
  if [ -d "$lock_dir/.reclaim" ]; then
    rm -f "$temp" 2>/dev/null || :
    return 1
  fi
  if [ -f "$metadata" ]; then
    recorded_token=$(write_lock_metadata_value "$metadata" token)
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

write_lock_heartbeat_write() {
  local interval invalid now last lock_dir heartbeat temp
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
  heartbeat="$lock_dir/heartbeat"
  temp="$lock_dir/heartbeat.tmp.$MAESTRO_LOCK_TOKEN"
  if ! printf 'token=%s\nepoch=%s\n' "$MAESTRO_LOCK_TOKEN" "$now" > "$temp"; then
    rm -f "$temp" 2>/dev/null || :
    return 1
  fi
  if ! write_lock_is_owner; then
    rm -f "$temp" 2>/dev/null || :
    return 0
  fi
  if mv -f "$temp" "$heartbeat"; then
    MAESTRO_LOCK_HEARTBEAT_LAST_WRITE_EPOCH=$now
    MAESTRO_LOCK_HEARTBEAT_LAST_TOKEN=$MAESTRO_LOCK_TOKEN
    return 0
  fi
  rm -f "$temp" 2>/dev/null || :
  return 1
}

write_lock_heartbeat_epoch() {   # lock_dir token
  local lock_dir="$1" token="$2" heartbeat recorded_token
  heartbeat="$lock_dir/heartbeat"
  [ -f "$heartbeat" ] || return 0
  recorded_token=$(write_lock_metadata_value "$heartbeat" token)
  [ "$recorded_token" = "$token" ] || return 0
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
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
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
  local deadline="$1" job="$2" session="$3" lock_dir="$4" now remaining sleep_for
  [ "$deadline" -gt 0 ] 2>/dev/null || return 1
  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || return 1
  remaining=$((deadline - now))
  sleep_for=$MAESTRO_LOCK_WAIT_POLL_SEC
  [ "$sleep_for" -le "$remaining" ] || sleep_for=$remaining
  progress "MAESTRO_LOCK: waiting for the write lease held by job=$job session=$session — ${remaining}s left before blocking (lock: $lock_dir); arrival order is not guaranteed"
  sleep "$sleep_for"
  return 0
}

write_lock_poison_gate() {   # lock_dir metadata → 11 when poisoned (after printing), else 0
  local lock_dir="$1" metadata="$2"
  local poison_metadata quiescence unconfirmed_job unconfirmed_reason owner_session
  poison_metadata="$metadata"
  quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
  if [ "$quiescence" != "unconfirmed" ] && [ -e "$lock_dir/metadata.new" ]; then
    poison_metadata="$lock_dir/metadata.new"
    quiescence=unconfirmed
  fi
  [ "$quiescence" = "unconfirmed" ] || return 0
  unconfirmed_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
  unconfirmed_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
  owner_session=$(write_lock_metadata_value "$poison_metadata" session_id)
  owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
  progress "MAESTRO_LOCK: write dispatch blocked; quiescence is unconfirmed for job=${unconfirmed_job:-unknown} session=${owner_session:-unknown} reason=${unconfirmed_reason:-unknown} (lock: $lock_dir). Clear it once no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
  return 11
}

write_lock_is_owner() {
  local lock_dir metadata recorded_token
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || {
    [ -n "${MAESTRO_LOCK_TOKEN:-}" ] || return 1
  }
  lock_dir="${MAESTRO_LOCK_DIR:-$(write_lock_path)}"
  [ ! -d "$lock_dir/.reclaim" ] || return 1
  metadata="$lock_dir/metadata"
  [ -f "$metadata" ] || return 1
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ -n "${MAESTRO_LOCK_TOKEN:-}" ] &&
    [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ]
}

companion_call() {
  local C="$1" run_bounded_default=120
  shift
  run_bounded "${MAESTRO_COMPANION_TIMEOUT_SEC-120}" \
    "MAESTRO_COMPANION" node "$C" "$@"
}

companion_workspace_writers() {
  local C="$1" status parsed rc
  if ! status=$(unset CODEX_COMPANION_SESSION_ID; companion_call "$C" status --all --json 2>/dev/null); then
    return 4
  fi
  [ -n "${status//[[:space:]]/}" ] || return 4

  parsed=$(printf '%s\n' "$status" | node -e '
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
              typeof job.id !== "string" || !/^task-[a-z0-9][a-z0-9-]*$/.test(job.id) ||
              typeof job.write !== "boolean") process.exit(4);
          process.stdout.write(`${job.id}\t${job.write}\n`);
        }
      } catch {
        process.exit(4);
      }
    });
  ' 2>/dev/null)
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
  local identity_note owner_session malformed_metadata
  local writers writers_rc digest_before log_path last prior_job prior_after observed_at
  local stale_digest_before stale_digest_after stale_released_at session_id started_at
  local metadata_record reclaim_dir current_token
  local wait_cap wait_poll wait_deadline initializing_grace
  local heartbeat_stale heartbeat_epoch heartbeat_effective heartbeat_age heartbeat_note
  MAESTRO_LOCK_ACQUIRED=0
  MAESTRO_LOCK_DIR=$(write_lock_path) || return 3
  metadata="$MAESTRO_LOCK_DIR/metadata"

  wait_cap=${MAESTRO_LOCK_WAIT_SEC:-300}
  wait_poll=${MAESTRO_LOCK_WAIT_POLL_SEC:-5}
  # A typo must fail fast: a 300-second fallback would turn bad input into a five-minute stall.
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

  if [ -n "${MAESTRO_LOCK_TOKEN:-}" ] && [ -f "$metadata" ]; then
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    if [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ]; then
      export MAESTRO_LOCK_DIR
      return 0
    fi
  fi

  initializing_grace=0
  if [ "$wait_cap" -gt 0 ]; then wait_deadline=$(( $(date +%s) + wait_cap )); else wait_deadline=0; fi
  attempt=0
  while [ "$attempt" -lt 2 ]; do
    write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata" || return 11
    if mkdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
      token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
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
      metadata_record=$(printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=unavailable' \
        "$token" "$$" "$process_start" "$requested_job" "${session_id:-unknown}" \
        "$started_at" "$now")
      if ! write_lock_publish_metadata "$MAESTRO_LOCK_DIR" "$token" "$metadata_record"; then
        rm -f "$metadata" "$MAESTRO_LOCK_DIR/heartbeat" 2>/dev/null || :
        rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null || :
        return 3
      fi
      MAESTRO_LOCK_TOKEN="$token"
      MAESTRO_LOCK_ACQUIRED=1
      export MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR

      digest_before=$(repo_digest_bounded 2>/dev/null) || digest_before=unavailable
      metadata_record=$(printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s' \
        "$token" "$$" "$process_start" "$requested_job" "${session_id:-unknown}" \
        "$started_at" "$now" "$digest_before")
      if ! write_lock_publish_metadata "$MAESTRO_LOCK_DIR" "$token" "$metadata_record"; then
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

    if [ ! -f "$metadata" ]; then
      if [ "$wait_cap" -gt 0 ] && [ "$initializing_grace" -lt 3 ]; then
        initializing_grace=$((initializing_grace + 1))
        sleep 1
        continue
      fi
      progress "MAESTRO_LOCK: write dispatch blocked by an initializing owner (job=unknown session=unknown pid=unknown held=unknown, lock: $MAESTRO_LOCK_DIR)"
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
            heartbeat_epoch=$(write_lock_heartbeat_epoch "$MAESTRO_LOCK_DIR" "$recorded_token")
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
      progress "MAESTRO_LOCK: write dispatch blocked; held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown} for $held (lock: $MAESTRO_LOCK_DIR)${identity_note}${heartbeat_note}"
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
        if write_lock_wait_tick "$wait_deadline" "$owner_job" "${owner_session:-unknown}" "$MAESTRO_LOCK_DIR"; then
          continue
        fi
        progress "MAESTRO_LOCK: write dispatch blocked; lease retained because orphaned job=$owner_job session=${owner_session:-unknown} is still running (lock: $MAESTRO_LOCK_DIR)"
        return 11
      fi
    elif printf '%s\n' "$writers" | awk '$2 == "true" { found = 1 } END { exit !found }'; then
      if write_lock_wait_tick "$wait_deadline" "$owner_job" "${owner_session:-unknown}" "$MAESTRO_LOCK_DIR"; then
        continue
      fi
      progress "MAESTRO_LOCK: write dispatch blocked; lease retained because an unidentified write-capable job is still running (session=${owner_session:-unknown}, lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi

    # Cancellation stages poison before the job disappears from the writers list.
    # Recheck after liveness so that transition cannot be erased as stale.
    write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata" || return 11

    # Claim this exact generation before deletion. The second token check closes
    # the path-reuse ABA: a delayed reclaimer may observe a successor at the same
    # pathname, but it cannot delete that successor using the stale classification.
    current_token=$(write_lock_metadata_value "$metadata" token)
    if [ "$current_token" != "$recorded_token" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    reclaim_dir="$MAESTRO_LOCK_DIR/.reclaim"
    if ! mkdir "$reclaim_dir" 2>/dev/null; then
      progress "MAESTRO_LOCK: write dispatch blocked by a competing stale-lease reclaimer (lock: $MAESTRO_LOCK_DIR)"
      return 11
    fi
    current_token=$(write_lock_metadata_value "$metadata" token)
    if [ "$current_token" != "$recorded_token" ]; then
      rmdir "$reclaim_dir" 2>/dev/null || :
      attempt=$((attempt + 1))
      continue
    fi
    if ! write_lock_poison_gate "$MAESTRO_LOCK_DIR" "$metadata"; then
      rmdir "$reclaim_dir" 2>/dev/null || :
      return 11
    fi

    # Observe and publish the adopted baseline while this generation claim still
    # blocks a successor. Removing the lock first lets a successor publish and
    # release before this older record, reversing baseline order.
    stale_digest_after=$(repo_digest_bounded 2>/dev/null) || stale_digest_after=unavailable
    stale_released_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" \
      "$MAESTRO_LOCK_DIR/heartbeat" 2>/dev/null; then
      rmdir "$reclaim_dir" 2>/dev/null || :
      return 11
    fi
    if repo_digest_is_observed "$stale_digest_before" &&
      repo_digest_is_observed "$stale_digest_after" &&
      [ "$stale_digest_before" != "$stale_digest_after" ]; then
      progress "PROVENANCE: ADOPTED UNOBSERVED INTERVAL — the tree changed while an orphaned lease was held (job=$owner_job, expected=$stale_digest_before, observed=$stale_digest_after); the interval was not observed and the author is unknown"
    fi
    if log_path=$(provenance_log_path 2>/dev/null); then
      # The interval between the orphan's last write and this steal was never observed,
      # so the after value is adopted, not witnessed.
      provenance_log_append "$log_path" "$(printf '%s type=orphan-adopted job=%s session=%s before=%s after=%s' \
        "$stale_released_at" "$owner_job" "${owner_session:-unknown}" \
        "$stale_digest_before" "$stale_digest_after")" || :
    fi
    if rmdir "$reclaim_dir" 2>/dev/null &&
      rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
      progress "MAESTRO_LOCK: broke stale write lock held by job=$owner_job session=${owner_session:-unknown} pid=${owner_pid:-unknown}"
      attempt=$((attempt + 1))
      continue
    fi
    rmdir "$reclaim_dir" 2>/dev/null || :

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
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || {
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
  next_metadata="${MAESTRO_LOCK_DIR}/metadata.new"
  if ! printf 'token=%s\npid=%s\nprocess_start=%s\njob_id=%s\nsession_id=%s\nstarted_at=%s\nstarted_epoch=%s\ndigest_before=%s\n' \
    "$recorded_token" "$owner_pid" "$owner_start" "$job" "${session_id:-unknown}" \
    "$started_at" "$started_epoch" "$digest_before" > "$next_metadata"; then
    rm -f "$next_metadata" 2>/dev/null || :
    return 3
  fi
  if ! write_lock_is_owner || ! mv -f "$next_metadata" "$metadata"; then
    rm -f "$next_metadata" 2>/dev/null || :
    progress "MAESTRO_LOCK: this lease changed while publishing job=$job; job update rejected"
    return 3
  fi
}

write_lock_poison() {
  local job="$1" reason="$2" metadata next_metadata recorded_token owner_pid owner_start
  local owner_job started_at started_epoch digest_before session_id
  write_lock_is_owner || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; poison not staged"
    return 3
  }
  metadata="${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"
  [ -f "$metadata" ] || return 3
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; poison not staged"
    return 3
  }
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
  local digest_before digest_after log_path released_at reclaim_dir current_token
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
  metadata="${MAESTRO_LOCK_DIR:-}/metadata"
  [ -n "${MAESTRO_LOCK_DIR:-}" ] && [ -f "$metadata" ] || return 0
  recorded_token=$(write_lock_metadata_value "$metadata" token)
  [ "$recorded_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || {
    progress "MAESTRO_LOCK: this lease is no longer held by this process; releasing nothing"
    return 0
  }
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
  digest_after=$(repo_digest_bounded 2>/dev/null) || digest_after=unavailable
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
  current_token=$(write_lock_metadata_value "$metadata" token)
  [ "$current_token" = "${MAESTRO_LOCK_TOKEN:-}" ] || return 0
  reclaim_dir="$MAESTRO_LOCK_DIR/.reclaim"
  if ! mkdir "$reclaim_dir" 2>/dev/null; then
    progress "MAESTRO_LOCK: lease release lost the generation claim; retaining the lock"
    return 0
  fi
  current_token=$(write_lock_metadata_value "$metadata" token)
  if [ "$current_token" != "${MAESTRO_LOCK_TOKEN:-}" ]; then
    rmdir "$reclaim_dir" 2>/dev/null || :
    progress "MAESTRO_LOCK: lease generation changed during release; releasing nothing"
    return 0
  fi
  poison_metadata="$metadata"
  quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
  if [ "$quiescence" != "unconfirmed" ] && [ -e "$MAESTRO_LOCK_DIR/metadata.new" ]; then
    poison_metadata="$MAESTRO_LOCK_DIR/metadata.new"
    quiescence=unconfirmed
  fi
  if [ "$quiescence" = "unconfirmed" ]; then
    rmdir "$reclaim_dir" 2>/dev/null || :
    progress "MAESTRO_LOCK: write lease retained because cancellation poison arrived during release (lock: $MAESTRO_LOCK_DIR)"
    return 0
  fi
  # Publish the completed baseline while the generation claim still excludes a
  # successor. Otherwise the next acquirer can compare against the older record
  # and report this authorized dispatch as a false baseline gap.
  if log_path=$(provenance_log_path 2>/dev/null); then
    # Best-effort diagnostic only, not an enforcement boundary: repository writers can rewrite this log.
    # A differing before/after pair is a dispatch-window change with an unknown author:
    # lease metadata delimits an interval; it never identifies which process wrote.
    provenance_log_append "$log_path" "$(printf '%s type=dispatch job=%s session=%s before=%s after=%s' \
      "$released_at" "$owner_job" "${owner_session:-unknown}" "$digest_before" "$digest_after")" || :
  fi
  if ! rm -f "$metadata" "$MAESTRO_LOCK_DIR/metadata.new" \
    "$MAESTRO_LOCK_DIR/heartbeat" 2>/dev/null ||
    ! rmdir "$reclaim_dir" 2>/dev/null ||
    ! rmdir "$MAESTRO_LOCK_DIR" 2>/dev/null; then
    rmdir "$reclaim_dir" 2>/dev/null || :
    return 0
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

companion_start() {
  local C="$1" PROMPT="$2" WRITE="${3:-}"
  local PIN MODEL EFFORTS DEBATE_EFFORT IMPL_EFFORT HELP TASK_HELP
  PIN=$(companion_pin) || return 3
  MODEL=${PIN%%$'\t'*}
  EFFORTS=${PIN#*$'\t'}
  DEBATE_EFFORT=${EFFORTS%%$'\t'*}
  IMPL_EFFORT=${EFFORTS#*$'\t'}
  if [ "$WRITE" = "write" ]; then
    # Compatibility probe, not an authorization check: only a help text that
    # describes `task` WITHOUT --write proves drift. Anything inconclusive
    # (empty, error, no synopsis) must not block a dispatch.
    HELP=$(companion_call "$C" --help 2>&1) || HELP=""
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
  if [ "$WRITE" = "write" ]; then
    if ! write_lock_is_owner; then
      progress "MAESTRO_LOCK: write launch blocked because this process no longer owns the lease"
      return 11
    fi
    if ! write_lock_poison_gate "${MAESTRO_LOCK_DIR:-$(write_lock_path)}" \
      "${MAESTRO_LOCK_DIR:-$(write_lock_path)}/metadata"; then
      return 11
    fi
  fi
  local -a args=(task --background)
  [ "$WRITE" = "write" ] && args+=(--write)
  args+=(--model "$MODEL")
  if [ "$WRITE" = "write" ]; then
    if ! companion_wrapper_accepts_effort "$IMPL_EFFORT"; then
      echo "companion cannot express implementation effort=$IMPL_EFFORT; refusing to silently substitute the debate tier" >&2
      return 3
    fi
    args+=(--effort "$IMPL_EFFORT")
  elif companion_wrapper_accepts_effort "$DEBATE_EFFORT"; then
    args+=(--effort "$DEBATE_EFFORT")
  else
    progress "CODEX: companion wrapper cannot express debate effort=$DEBATE_EFFORT explicitly; the pinned top-level config value governs this read-only dispatch"
  fi
  local START JOB START_RC
  START=$(companion_call "$C" "${args[@]}" "$PROMPT" 2>&1)
  START_RC=$?
  if [ "$START_RC" -ne 0 ]; then
    printf 'could not start Codex job (exit %s). Output: %s' "$START_RC" "$START" >&2
    return 3
  fi
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
  local PIN EFFORTS CONFIG_EFFORT
  ST=$(companion_call "$C" status "$JOB" --json 2>/dev/null)
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
    if [ "$CONFIG_EFFORT" = "$EXPECTED_EFFORT" ] && [ "$RECORDED_WRITE" = false ]; then
      return 0
    fi
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

companion_cancel_job() { # C JOB REASON LOG → 124 read-only, 125 write-mode
  local C="$1" JOB="$2" REASON="$3" log="$4" crc write_mode=0
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
  companion_call "$C" cancel "$JOB" >/dev/null 2>&1
  crc=$?
  if [ "$crc" -eq 125 ]; then MAESTRO_CANCEL_REQUESTED=0; else MAESTRO_CANCEL_REQUESTED=1; fi
  progress "MAESTRO_POLL: cancel attempted reason=$REASON job=$JOB log=${log:-unknown}"
  if [ "$write_mode" -eq 1 ] && [ "$REASON" = deadline ]; then
    progress "MAESTRO_RECOVERY: UNREPORTED_PARTIAL job=$JOB reason=deadline; the tree may contain incomplete edits and local verification did not run. Confirm quiescence, clear the poisoned lease, inspect the diff and targeted tests, then write an evidence-based continuation plan. Do not restart from scratch or auto-resume."
  fi
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
  local poll_started="${5:-$SECONDS}" mode=read
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
  local ST state status_compact size phase elapsed preview preview_emit preview_json emitted line growth
  write_lock_is_owner && mode="write"
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
    write_lock_heartbeat_write
    total=$((SECONDS - poll_started))
    [ "$total" -ge 0 ] || total=0
    remaining_total=$((MAX_TOTAL - total))
    if [ "$remaining_total" -le 0 ]; then call_timeout=1; else call_timeout=$remaining_total; fi
    [ "$call_timeout" -le "$configured_call_timeout" ] || call_timeout=$configured_call_timeout
    ST=$(MAESTRO_COMPANION_TIMEOUT_SEC="$call_timeout" \
      companion_call "$C" status "$JOB" --json 2>/dev/null)
    total=$((SECONDS - poll_started))
    [ "$total" -ge 0 ] || total=0
    if [ -z "$ST" ]; then
      sfails=$((sfails + 1))
      if [ "$total" -ge "$MAX_TOTAL" ]; then
        progress "MAESTRO_POLL: hard deadline reached while companion status was unreachable for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" deadline "$LOG"
        return $?
      fi
      if [ "$sfails" -ge 4 ]; then
        progress "MAESTRO_POLL: companion status unreachable ${sfails}x in a row for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" status-lost "$LOG"
        return $?
      fi
      continue
    fi
    state=$(printf '%s' "$ST" | grep -oiE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' | head -1 | grep -oiE '[a-z]+"$' | tr -d '"')
    status_compact=$(printf '%s' "$ST" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$status_compact" in \{*\}) ;; *) state="" ;; esac
    if [ -z "$state" ]; then
      sfails=$((sfails + 1))
      if [ "$total" -ge "$MAX_TOTAL" ]; then
        progress "MAESTRO_POLL: hard deadline reached while companion status was malformed for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" deadline "$LOG"
        return $?
      fi
      if [ "$sfails" -ge 4 ]; then
        progress "MAESTRO_POLL: companion status malformed or unreachable ${sfails}x in a row for $JOB; cancelling and failing closed"
        companion_cancel_job "$C" "$JOB" status-lost "$LOG"
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
        if write_lock_is_owner; then
          MAESTRO_CANCEL_REASON=cancelled-observed
          MAESTRO_CANCEL_REQUESTED=0
          MAESTRO_LOCK_RETAIN=1
          if ! write_lock_poison "$JOB" cancelled-observed; then
            progress "MAESTRO_LOCK: companion reported cancellation, but poison could not be staged; retaining the lease"
            return 125
          fi
          if ! mv -f "$MAESTRO_LOCK_DIR/metadata.new" "$MAESTRO_LOCK_DIR/metadata"; then
            progress "MAESTRO_LOCK: observed-cancellation poison rename failed; retaining metadata.new as the fail-closed marker"
          fi
          progress "MAESTRO_POLL: companion reported job=$JOB state=$state; write lease poisoned and no replacement will start"
          return 125
        fi
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
      companion_cancel_job "$C" "$JOB" deadline "$LOG"
      return $?
    fi
    if [ "$idle_elapsed" -ge "$MAX_IDLE" ]; then
      companion_cancel_job "$C" "$JOB" idle "$LOG"
      return $?
    fi
  done
}

companion_result() {
  local C="$1" JOB="$2"
  local OUT
  OUT=$(companion_call "$C" result "$JOB" 2>/dev/null)
  if [ -z "${OUT//[[:space:]]/}" ]; then
    sleep 3
    OUT=$(companion_call "$C" result "$JOB" 2>/dev/null)
  fi
  if [ -z "${OUT//[[:space:]]/}" ]; then
    printf 'job %s returned an empty result twice' "$JOB" >&2
    return 4
  fi
  printf '%s\n' "$OUT"
}
