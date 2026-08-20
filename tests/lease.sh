#!/usr/bin/env bash
# Green-phase verification of Plan F, run by the orchestrator as review.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-write-lease.sh"
LEASE_LIB="$LIB"
LOOP="$ROOT/hooks/implementer-loop.sh"
FAKE="$ROOT/tests/fixtures/fake-companion.mjs"
REAL_NODE=$(node -p 'process.execPath')
[ -f "$FAKE" ] || { echo "VERIFY FAIL: missing fixture $FAKE"; exit 1; }
TEST_ROOT=$(mktemp -d /tmp/maestro-planf-green.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export MAESTRO_LOCK_WAIT_SEC=0

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

ws() { local d="$TEST_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

prepare_generation() { # lock [generation]
  local lock="$1" generation="${2-}"
  mkdir -p "$lock" || return 1
  if [ -z "$generation" ]; then
    [ ! -f "$lock/generation" ] || return 0
    generation=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  fi
  printf '%s\n' "$generation" > "$lock/generation"
}

sync_generation_field() { # lock [record-name]
  local lock="$1" record="${2:-metadata}" generation file temp
  generation=$(cat "$lock/generation") || return 1
  file="$lock/$record"
  temp="$file.generation"
  awk -v generation="$generation" '
    BEGIN { written = 0 }
    /^generation=/ {
      if (!written) print "generation=" generation
      written = 1
      next
    }
    { print }
    END { if (!written) print "generation=" generation }
  ' "$file" > "$temp" || return 1
  command mv "$temp" "$file"
}

without_ps_path() {  # dir
  local bin="$1/no-ps"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' > "$bin/ps"
  chmod +x "$bin/ps"
  printf '%s:%s' "$bin" "$PATH"
}

confirmed_ps_path() {  # dir
  local bin="$1/confirmed-ps"
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "Mon Jan  1 00:00:00 2026\\n"\n' > "$bin/ps"
  chmod +x "$bin/ps"
  printf '%s:%s' "$bin" "$PATH"
}

tz_sensitive_ps_path() {  # dir
  local bin="$1/tz-sensitive-ps"
  mkdir -p "$bin"
  cat > "$bin/ps" <<'EOF'
#!/bin/sh
if [ "${TZ:-}" = "UTC0" ] && [ "${LC_ALL:-}" = "C" ]; then
  printf 'Mon Jan  1 00:00:00 2026\n'
elif [ "${TZ:-}" = "owner-zone" ]; then
  printf 'Tue Jan  2 01:00:00 2026\n'
else
  printf 'Wed Jan  3 02:00:00 2026\n'
fi
EOF
  chmod +x "$bin/ps"
  printf '%s:%s' "$bin" "$PATH"
}

status_running_job() { printf '{\n  "running": [\n    {\n      "id": "%s",\n      "write": %s\n    }\n  ],\n  "latestFinished": null\n}\n' "$1" "$2"; }
status_empty()       { printf '{\n  "running": [],\n  "latestFinished": null\n}\n'; }

run_clear_lease() {  # dir status stale_sec
  local dir="$1" status="$2" stale_sec="$3" clear_home clear_shim companion
  clear_home="$TEST_ROOT/clear-home"
  clear_shim="$TEST_ROOT/clear-shim"
  companion="$clear_home/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
  mkdir -p "$clear_shim" "$(dirname "$companion")" || return 1
  ln -sf "$FAKE" "$companion" || return 1
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-e" ]; then exec %q "$@"; fi\nshift\nexec %q %q "$@"\n' \
    "$REAL_NODE" "$REAL_NODE" "$FAKE" > "$clear_shim/node" || return 1
  chmod +x "$clear_shim/node" || return 1
  (
    cd "$dir" || exit 1
    env HOME="$clear_home" PATH="$clear_shim:$PATH" \
      MAESTRO_TEST_STATUS="$status" \
      MAESTRO_LOCK_HEARTBEAT_STALE_SEC="$stale_sec" \
      bash "$LOOP" --clear-lease
  )
}

dead_lock() {  # dir job_id
  local lock="$1/.maestro-write.lock" generation
  prepare_generation "$lock" || return 1
  generation=$(cat "$lock/generation") || return 1
  printf 'token=old\ngeneration=%s\npid=999999\nprocess_start=dead\njob_id=%s\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\n' \
    "$generation" "$2" > "$lock/metadata"
}

# ---------------------------------------------------------------- deep Lease interval interface
t1() (
  local dir evidence token inherited_rc
  dir=$(ws deep_lease_interface)
  evidence="$dir/evidence"
  [ -f "$LEASE_LIB" ] || { echo "hooks/lib-write-lease.sh is missing"; return 1; }
  cd "$dir" || exit 1
  # shellcheck source=../hooks/lib-write-lease.sh
  . "$LEASE_LIB"
  companion_resolve() { printf '%s' "$FAKE"; }
  progress_init
  declare -F _write_lease_turn_event >/dev/null ||
    { echo "private Lease interval lifecycle seam missing"; return 1; }
  declare -F write_lease_clear >/dev/null ||
    { echo "operator recovery interface missing"; return 1; }
  status_empty > "$dir/status.json"
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lease_begin "$evidence" >/dev/null 2>&1 || return 1
  [ -f "$dir/.maestro-write.lock/metadata" ] ||
    { echo "Lease interval metadata missing"; return 1; }
  token=$(sed -n 's/^token=//p' "$dir/.maestro-write.lock/metadata")
  [ -n "$token" ] || { echo "Lease interval token missing"; return 1; }
  env MAESTRO_LOCK_WAIT_SEC=0 MAESTRO_LOCK_ACQUIRED=1 \
    MAESTRO_LOCK_TOKEN="$token" MAESTRO_LOCK_DIR="$dir/.maestro-write.lock" \
    LEASE_LIB="$LEASE_LIB" bash -c '
      set -uo pipefail
      . "$LEASE_LIB"
      progress_init
      write_lease_begin /dev/null
    ' >/dev/null 2>&1
  inherited_rc=$?
  [ "$inherited_rc" -eq 11 ] ||
    { echo "inherited token fallback rc=$inherited_rc want 11"; return 1; }
  write_lease_end "$evidence" >/dev/null 2>&1 || return 1
  [ ! -e "$dir/.maestro-write.lock" ] ||
    { echo "Lease interval survived safe end"; return 1; }
)

# ---------------------------------------------------------------- step 2
# Live dispatcher must block WITHOUT querying the companion.
t2() (
  local dir log rc; dir=$(ws live); log="$dir/calls.log"; : > "$log"
  cd "$dir" || exit 1
  . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_CALL_LOG="$log" MAESTRO_TEST_STATUS="$dir/none.json"
  write_lock_acquire task-live0000-aaaaaa >/dev/null   # this shell owns it, pid alive
  # contend from a context that does not inherit the owner token
  unset MAESTRO_LOCK_TOKEN
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ ! -s "$log" ] || { echo "companion WAS queried: $(cat "$log")"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 3
t3() (
  local dir rc; dir=$(ws known_running)
  status_running_job task-fake0000-aaaaaa true > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  local out; out=$(write_lock_acquire 2>&1 >/dev/null); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock was broken"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 4
t4() (
  local dir rc; dir=$(ws known_absent)
  status_empty > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  grep -q 'job_id=task-new00000-cccccc' "$dir/.maestro-write.lock/metadata" || { echo "new owner not recorded"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 5  (MUST PASS)
t5() (
  local dir rc; dir=$(ws unknown_writer)
  status_running_job task-other0000-bbbbbb true > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock was broken — the unknown-id gap is OPEN"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 5b
# unknown id, a running job that is NOT write-capable → safe to break
t5b() (
  local dir rc; dir=$(ws unknown_reader)
  status_running_job task-other0000-bbbbbb false > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0 (read-only job must not hold a write lease)"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 6
t6() (
  local dir rc; dir=$(ws unknown_empty)
  status_empty > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 7  (MUST PASS)
t7() (
  local dir rc; dir=$(ws broken)
  printf 'BROKEN\n' > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "broke the lock on UNCERTAIN liveness"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 7b
# companion entirely unreachable (node exits non-zero) → fail closed
t7b() (
  local dir rc; dir=$(ws unreachable)
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  unset MAESTRO_TEST_STATUS   # stub exits 1 with no status file
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "broke the lock when companion unreachable"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 8  (MUST PASS)
t8() (
  local dir; dir=$(ws release_live)
  status_running_job task-fake0000-aaaaaa true > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "released a lease whose job is still running"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 9
t9() (
  local dir; dir=$(ws release_terminal)
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ ! -d "$dir/.maestro-write.lock" ] || { echo "failed to release a terminal lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 9b
t9b() (
  local dir; dir=$(ws release_broken)
  printf 'BROKEN\n' > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "released on UNCERTAIN liveness"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 10 (MUST PASS)
# Kill a REAL dispatcher process while a job is listed running.
# 10a: killed BEFORE the job id was published (job_id=unknown)
# 10b: killed AFTER  the job id was published
kill_dispatcher_case() (  # $1=dir  $2=job_id_recorded  $3=running_job_id
  local dir="$1" rc
  status_running_job "$3" true > "$dir/status.json"
  # real child acquires the lock, then is killed without running its trap
  env MAESTRO_TEST_STATUS="$dir/status.json" bash -c '
    cd "$1"; set -uo pipefail; . "$2"; companion_resolve() { printf "%s" "$3"; }; progress_init
    write_lock_acquire "$4" >/dev/null 2>&1
    kill -9 $$
  ' _ "$dir" "$LIB" "$FAKE" "$2" >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock vanished when dispatcher was hard-killed"; return 1; }
  # a new dispatcher now contends
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  unset MAESTRO_LOCK_TOKEN
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11 after dispatcher kill"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "successor broke a lease with a live writer"; return 1; }
  return 0
)
t10a() { kill_dispatcher_case "$(ws kill_before)" unknown task-other0000-bbbbbb; }
t10b() { kill_dispatcher_case "$(ws kill_after)" task-fake0000-aaaaaa task-fake0000-aaaaaa; }

# ---------------------------------------------------------------- step 11
# Missing ps must not prevent acquisition; metadata records the recovery gap.
t11() (
  local dir rc; dir=$(ws no_ps_acquire)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(without_ps_path "$dir"); export PATH
  write_lock_acquire task-no-ps000-aaaaaa >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  grep -qx 'process_start=unavailable' "$dir/.maestro-write.lock/metadata" ||
    { echo "process_start=unavailable not recorded"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 12
# A live owner with unconfirmable identity must block rather than be stolen.
t12() (
  local dir lock owner_pid rc; dir=$(ws no_ps_contention)
  lock="$dir/.maestro-write.lock"
  status_empty > "$dir/status.json"
  sleep 30 & owner_pid=$!
  trap 'kill "$owner_pid" 2>/dev/null || :; wait "$owner_pid" 2>/dev/null || :' EXIT
  prepare_generation "$lock" || return 1
  printf 'token=old\npid=%s\nprocess_start=unavailable\njob_id=task-live0000-aaaaaa\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\n' \
    "$owner_pid" > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  PATH=$(without_ps_path "$dir"); export PATH
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "live owner's lock was broken"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 13
# A valid session id is recorded and identifies the live owner on contention.
t13() (
  local dir out rc; dir=$(ws session_valid)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-valid_13
  write_lock_acquire task-live0000-aaaaaa >/dev/null 2>&1
  grep -qx 'session_id=session-valid_13' "$dir/.maestro-write.lock/metadata" ||
    { echo "valid session id not recorded"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'session=session-valid_13' ||
    { echo "contention did not identify owner session: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 14
# Invalid environment input is replaced, never copied into metadata.
t14() (
  local dir metadata; dir=$(ws session_invalid)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID='bad id; rm -rf /'
  write_lock_acquire task-invalid0-aaaaaa >/dev/null 2>&1
  metadata="$dir/.maestro-write.lock/metadata"
  grep -qx 'session_id=unknown' "$metadata" ||
    { echo "invalid session id did not record unknown"; return 1; }
  if grep -Fq 'bad' "$metadata" || grep -Fq 'rm -rf' "$metadata"; then
    echo "invalid session id leaked into metadata"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 15
# Publishing a job rewrites metadata without losing the recorded session.
t15() (
  local dir; dir=$(ws session_set_job)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-set_job
  write_lock_acquire >/dev/null 2>&1
  write_lock_set_job task-published-aaaaaa
  grep -qx 'session_id=session-set_job' "$dir/.maestro-write.lock/metadata" ||
    { echo "session id lost while publishing job"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 16
# Completed dispatch provenance carries the originating session.
t16() (
  local dir log; dir=$(ws session_dispatch)
  git -C "$dir" init -q
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_SESSION_ID=session-dispatch
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-session0-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  log="$dir/.git/maestro-provenance.log"
  grep -Eq ' type=dispatch job=task-session0-aaaaaa session=session-dispatch before=[^ ]+ after=[^ ]+$' "$log" ||
    { echo "dispatch provenance missing session"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 17
# Legacy provenance without a session field remains a valid acquisition baseline.
t17() (
  local dir log; dir=$(ws legacy_baseline)
  git -C "$dir" init -q
  log="$dir/.git/maestro-provenance.log"
  printf '2026-01-01T00:00:00Z type=dispatch job=legacy-job before=tree-v3:old after=tree-v3:old\n' > "$log"
  cd "$dir" || exit 1; . "$LIB"; progress_init
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1
  grep -q ' type=gap prior_job=legacy-job ' "$log" ||
    { echo "legacy provenance was not recognized as a baseline"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 18
# A live owner with confirmed process identity waits until the bounded cap.
t18() (
  local dir out rc started elapsed; dir=$(ws wait_live_confirmed)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-wait_live
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-live-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -ge 2 ] || { echo "elapsed=${elapsed}s want at least 2s"; return 1; }
  printf '%s\n' "$out" |
    grep -q 'waiting for the write lease held by job=task-wait-live-aaaaaa session=session-wait_live' ||
    { echo "wait attribution missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 19
# A zero cap preserves immediate contention and emits no waiting progress.
t19() (
  local dir out rc started elapsed; dir=$(ws wait_disabled)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-off-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=0 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  # date +%s is whole seconds, so a boundary crossing inflates any measurement by 1.
  # -le 1 absorbs that artifact; the "no waiting" invariant is proven exactly by the
  # absence of a wait message below, since every tick prints before it sleeps.
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "zero cap waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 20
# A live owner with unconfirmed process identity is never queueable.
t20() (
  local dir lock owner_pid out rc started elapsed; dir=$(ws wait_identity_unconfirmed)
  lock="$dir/.maestro-write.lock"
  sleep 30 & owner_pid=$!
  trap 'kill "$owner_pid" 2>/dev/null || :; wait "$owner_pid" 2>/dev/null || :' EXIT
  prepare_generation "$lock" || return 1
  printf 'token=old\npid=%s\nprocess_start=unavailable\njob_id=task-unconfirmed-aaaaaa\nsession_id=session-unconfirmed\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$owner_pid" "$(date +%s)" > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "identity-unconfirmed owner waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 21
# Poison is human-clearable state, so it must remain an immediate block.
t21() (
  local dir out rc started elapsed; dir=$(ws wait_poisoned)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  write_lock_acquire task-poisoned-aaaaaa >/dev/null 2>&1 || return 1
  write_lock_poison task-poisoned-aaaaaa timeout >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "poisoned lease waited: $out"
    return 1
  fi
  printf '%s\n' "$out" | grep -q -- '--clear-lease' ||
    { echo "clear-lease recovery missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 22
# Undeterminable companion liveness is fail-closed, never queueable.
t22() (
  local dir out rc started elapsed; dir=$(ws wait_liveness_unknown)
  dead_lock "$dir" task-status-fails-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  unset MAESTRO_TEST_STATUS
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "unknown liveness waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 23
# Reclassification sees poison staged while a caller is already waiting.
t23() (
  local dir out rc owner_token poison_pid poison_rc started elapsed; dir=$(ws wait_poison_preempts)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-poison_preempts
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-poison-preempts-aaaaaa >/dev/null 2>&1 || return 1
  owner_token=$MAESTRO_LOCK_TOKEN
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=10 MAESTRO_LOCK_WAIT_POLL_SEC=1
  (
    MAESTRO_LOCK_TOKEN="$owner_token"
    MAESTRO_LOCK_ACQUIRED=1
    sleep 2
    write_lock_poison task-poison-preempts-aaaaaa timeout
  ) &
  poison_pid=$!
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  wait "$poison_pid"; poison_rc=$?
  [ "$poison_rc" -eq 0 ] || { echo "poison staging rc=$poison_rc"; return 1; }
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -lt 5 ] || { echo "elapsed=${elapsed}s poison did not preempt wait"; return 1; }
  printf '%s\n' "$out" | grep -q 'waiting for the write lease' ||
    { echo "no wait occurred before poison: $out"; return 1; }
  printf '%s\n' "$out" | tail -1 | grep -q 'quiescence is unconfirmed.*--clear-lease' ||
    { echo "final poison recovery message missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 24
# An invalid cap warns and fails fast instead of falling back to five minutes.
t24() (
  local dir out rc started elapsed; dir=$(ws wait_invalid_cap)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-invalid-cap-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=abc MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  printf '%s\n' "$out" | grep -q 'invalid MAESTRO_LOCK_WAIT_SEC=abc' ||
    { echo "invalid cap warning missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 25
# Waiting does not reset the two-attempt stale-break budget.
t25() (
  local dir out rc breaks; dir=$(ws wait_stale_budget)
  status_empty > "$dir/status.json"
  dead_lock "$dir" task-stale-budget-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  out=$(write_lock_acquire task-new-after-stale-aaaaaa 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  breaks=$(printf '%s\n' "$out" | grep -c 'broke stale write lock')
  [ "$breaks" -ge 1 ] || { echo "stale lock was not broken: $out"; return 1; }
  [ "$breaks" -le 2 ] || { echo "stale lock broke $breaks times: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 26
# Malformed metadata is unconfirmed identity, never proof that the owner is dead.
t26() (
  local dir lock out rc; dir=$(ws malformed_metadata)
  lock="$dir/.maestro-write.lock"
  prepare_generation "$lock" || return 1
  : > "$lock/metadata"
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  out=$(write_lock_acquire task-malformed-aaaaaa 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$lock" ] && [ ! -s "$lock/metadata" ] ||
    { echo "malformed owner lock was replaced"; return 1; }
  printf '%s\n' "$out" | grep -q 'metadata is malformed.*owner cannot be identified.*failing closed' ||
    { echo "malformed metadata diagnostic missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 27
# Identity is published before the digest runs and remains releasable afterward.
t27() (
  local dir metadata identity_before initial_identity current_identity token owner_pid rc
  dir=$(ws identity_before_digest)
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  metadata="$dir/.maestro-write.lock/metadata"
  identity_before="$dir/identity-before-digest"
  repo_digest() {
    local recorded_token recorded_pid
    [ -f "$metadata" ] || return 1
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    recorded_pid=$(write_lock_metadata_value "$metadata" pid)
    [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] &&
      [ -n "${MAESTRO_LOCK_TOKEN:-}" ] &&
      [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ] &&
      [ "$recorded_pid" = "$$" ] || return 1
    sed -n '1,7p' "$metadata" > "$identity_before" || return 1
    printf 'tree-v3:identity-published\n'
  }
  write_lock_acquire task-published-first-aaaaaa >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  [ -f "$metadata" ] || { echo "metadata was not published"; return 1; }
  token=$(write_lock_metadata_value "$metadata" token)
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  [ -n "$token" ] && [ "$token" = "$MAESTRO_LOCK_TOKEN" ] ||
    { echo "published token does not identify the owner"; return 1; }
  initial_identity=$(sed -n '1,7p' "$identity_before")
  current_identity=$(sed -n '1,7p' "$metadata")
  [ "$initial_identity" = "$current_identity" ] ||
    { echo "owner identity changed during digest publication"; return 1; }
  case "$owner_pid" in
    ''|*[!0-9]*) echo "published pid is not numeric: $owner_pid"; return 1 ;;
  esac
  [ "$owner_pid" = "$$" ] || { echo "pid=$owner_pid want $$"; return 1; }
  grep -qx 'digest_before=tree-v3:identity-published' "$metadata" ||
    { echo "digest ran before identity publication"; return 1; }
  write_lock_release >/dev/null 2>&1
  [ ! -d "$dir/.maestro-write.lock" ] ||
    { echo "published owner could not release its lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 28
# Absent metadata remains the distinct initializing-owner state.
t28() (
  local dir lock out rc; dir=$(ws absent_metadata)
  lock="$dir/.maestro-write.lock"
  prepare_generation "$lock" || return 1
  cd "$dir" || exit 1; . "$LIB"; progress_init
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$lock" ] || { echo "initializing owner lock was removed"; return 1; }
  printf '%s\n' "$out" | grep -q 'blocked by an initializing owner' ||
    { echo "initializing-owner diagnostic missing: $out"; return 1; }
  if printf '%s\n' "$out" | grep -q 'metadata is malformed'; then
    echo "absent metadata was reported as malformed: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 29
# A current owner's heartbeat is visible as fresh and never changes its token.
t29() (
  local dir lock heartbeat owner_token recorded_token generation out rc; dir=$(ws heartbeat_fresh)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  export MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=1
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=3
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-heartbeat-fresh-aaaaaa >/dev/null 2>&1 || return 1
  lock="$dir/.maestro-write.lock"
  heartbeat="$lock/heartbeat"
  owner_token=$MAESTRO_LOCK_TOKEN
  write_lock_heartbeat_write || { echo "heartbeat write failed"; return 1; }
  [ "$(wc -l < "$heartbeat")" -eq 3 ] ||
    { echo "heartbeat did not contain exactly three lines"; return 1; }
  grep -qx "token=$owner_token" "$heartbeat" ||
    { echo "heartbeat token missing"; return 1; }
  generation=$(cat "$lock/generation") || return 1
  grep -qx "generation=$generation" "$heartbeat" ||
    { echo "heartbeat generation missing"; return 1; }
  write_lock_heartbeat_epoch "$lock" "$owner_token" "$MAESTRO_LOCK_IDENTITY" |
    grep -Eq '^[0-9]+$' ||
    { echo "heartbeat epoch missing"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is fresh (last tick [0-9][0-9]*s ago)' ||
    { echo "fresh heartbeat diagnostic missing: $out"; return 1; }
  recorded_token=$(write_lock_metadata_value "$lock/metadata" token)
  [ "$recorded_token" = "$owner_token" ] ||
    { echo "owner token changed from $owner_token to $recorded_token"; return 1; }
  MAESTRO_LOCK_TOKEN=$owner_token
  MAESTRO_LOCK_ACQUIRED=1
  write_lock_release >/dev/null 2>&1
  [ ! -d "$lock" ] || { echo "heartbeat prevented normal release"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 30
# A stopped owner becomes diagnostically stale, but the contender never reclaims it.
t30() (
  local dir lock stop owner_out owner_pid owner_token before out rc owner_rc
  dir=$(ws heartbeat_stale_no_reclaim)
  lock="$dir/.maestro-write.lock"
  stop="$dir/stop-owner"
  owner_out="$dir/owner.out"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  bash -c '
    cd "$1" || exit 1
    . "$2"; progress_init
    export MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=1
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-heartbeat-stale-aaaaaa >/dev/null 2>&1 || exit 1
    write_lock_heartbeat_write || exit 1
    printf "%s\n" "$MAESTRO_LOCK_TOKEN" > "$1/owner.token"
    while [ ! -e "$3" ]; do
      sleep 1
      write_lock_heartbeat_write || exit 1
    done
    write_lock_is_owner || exit 2
    printf "owner-still-owns\n"
    write_lock_release || exit 3
    [ ! -d "$4" ] || exit 4
    printf "owner-released\n"
  ' _ "$dir" "$LIB" "$stop" "$lock" > "$owner_out" 2>&1 &
  owner_pid=$!
  stale_owner_cleanup() {
    [ -n "$owner_pid" ] || return 0
    : > "$stop"
    kill -CONT "$owner_pid" 2>/dev/null || :
    wait "$owner_pid" 2>/dev/null || :
  }
  trap stale_owner_cleanup EXIT
  for _ in 1 2 3 4 5; do
    [ -s "$dir/owner.token" ] && [ -f "$lock/heartbeat" ] && break
    sleep 1
  done
  [ -s "$dir/owner.token" ] && [ -f "$lock/heartbeat" ] ||
    { echo "owner did not publish heartbeat"; return 1; }
  owner_token=$(sed -n '1p' "$dir/owner.token")
  before="$dir/metadata.before"
  cp "$lock/metadata" "$before" || return 1
  kill -STOP "$owner_pid" || return 1
  sleep 3
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_WAIT_SEC=1 MAESTRO_LOCK_WAIT_POLL_SEC=1
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is stale .*owner may be wedged' ||
    { echo "stale heartbeat diagnostic missing: $out"; return 1; }
  [ -d "$lock" ] || { echo "stale heartbeat was reclaimed"; return 1; }
  cmp -s "$before" "$lock/metadata" ||
    { echo "contender changed lease metadata"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = "$owner_token" ] ||
    { echo "contender changed lease token"; return 1; }
  : > "$stop"
  kill -CONT "$owner_pid" || return 1
  wait "$owner_pid"; owner_rc=$?
  owner_pid=""
  [ "$owner_rc" -eq 0 ] || { echo "resumed owner rc=$owner_rc: $(cat "$owner_out")"; return 1; }
  grep -qx 'owner-still-owns' "$owner_out" &&
    grep -qx 'owner-released' "$owner_out" ||
    { echo "resumed owner did not retain and release lease: $(cat "$owner_out")"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 31
# Before the first tick, a young lease uses started_epoch as its freshness floor.
t31() (
  local dir lock owner_token out rc; dir=$(ws heartbeat_absent_young)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=3
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-heartbeat-young-aaaaaa >/dev/null 2>&1 || return 1
  lock="$dir/.maestro-write.lock"
  owner_token=$MAESTRO_LOCK_TOKEN
  rm -f "$lock/heartbeat"
  [ ! -e "$lock/heartbeat" ] || { echo "young lease unexpectedly ticked"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is fresh (last tick [0-9][0-9]*s ago)' ||
    { echo "started_epoch freshness floor missing: $out"; return 1; }
  MAESTRO_LOCK_TOKEN=$owner_token
  MAESTRO_LOCK_ACQUIRED=1
  write_lock_release >/dev/null 2>&1
  return 0
)

# ---------------------------------------------------------------- step 32
# A stale heartbeat never bypasses the write-capable-job gate.
t32() (
  local dir lock status out rc now; dir=$(ws clear_stale_writer)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  prepare_generation "$lock" || return 1
  printf 'token=stale-writer\npid=%s\nprocess_start=old\njob_id=task-stale-writer\nsession_id=session-stale-writer\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    99999999 "$((now - 5))" > "$lock/metadata"
  printf 'token=stale-writer\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  status_running_job task-running-writer true > "$status"
  out=$(run_clear_lease "$dir" "$status" 1 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -q 'refusing to clear.*write-capable job is still running.*task-running-writer' <<< "$out" ||
    { echo "writer gate diagnostic missing: $out"; return 1; }
  [ -d "$lock" ] && [ -f "$lock/metadata" ] && [ -f "$lock/heartbeat" ] ||
    { echo "writer gate did not preserve stale lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 33
# With no write-capable job, an operator may clear a stale-heartbeat lease.
t33() (
  local dir lock status out rc now; dir=$(ws clear_stale_empty)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  prepare_generation "$lock" || return 1
  printf 'token=stale-empty\npid=%s\nprocess_start=old\njob_id=task-stale-empty\nsession_id=session-stale-empty\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    99999999 "$((now - 5))" > "$lock/metadata"
  printf 'token=stale-empty\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  status_empty > "$status"
  out=$(run_clear_lease "$dir" "$status" 1 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0: $out"; return 1; }
  grep -q 'clearing a write lease whose heartbeat went stale.*job=task-stale-empty.*session=session-stale-empty.*last_heartbeat=[0-9][0-9]*s ago' <<< "$out" ||
    { echo "stale clear diagnostic missing: $out"; return 1; }
  grep -q 'MAESTRO_FINAL: LOOP CLEARED rc=0' <<< "$out" ||
    { echo "clear result missing: $out"; return 1; }
  [ ! -d "$lock" ] && [ ! -e "$lock/metadata" ] && [ ! -e "$lock/heartbeat" ] ||
    { echo "stale lease entries survived clear"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 34
# A fresh heartbeat remains outside --clear-lease eligibility.
t34() (
  local dir lock status out rc now; dir=$(ws clear_fresh)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  prepare_generation "$lock" || return 1
  printf 'token=fresh-clear\npid=%s\nprocess_start=current\njob_id=task-fresh-clear\nsession_id=session-fresh-clear\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$$" "$now" > "$lock/metadata"
  printf 'token=fresh-clear\nepoch=%s\n' "$now" > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  status_empty > "$status"
  out=$(run_clear_lease "$dir" "$status" 10 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -q 'refusing to clear.*write lease is healthy.*heartbeat [0-9][0-9]*s old' <<< "$out" ||
    { echo "fresh clear refusal omitted heartbeat age: $out"; return 1; }
  [ -d "$lock" ] && [ -f "$lock/metadata" ] && [ -f "$lock/heartbeat" ] ||
    { echo "fresh heartbeat lease was removed"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 35
# A zero stale threshold restores the pre-heartbeat contention message.
t35() (
  local dir lock stop owner_pid out rc now; dir=$(ws heartbeat_reporting_disabled)
  lock="$dir/.maestro-write.lock"
  stop="$dir/stop-owner"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  (
    while [ ! -e "$stop" ]; do sleep 1; done
  ) &
  owner_pid=$!
  disabled_owner_cleanup() {
    [ -n "$owner_pid" ] || return 0
    : > "$stop"
    kill -CONT "$owner_pid" 2>/dev/null || :
    wait "$owner_pid" 2>/dev/null || :
  }
  trap disabled_owner_cleanup EXIT
  now=$(date +%s)
  prepare_generation "$lock" || return 1
  printf 'token=disabled\npid=%s\nprocess_start=Mon Jan  1 00:00:00 2026\njob_id=task-disabled\nsession_id=session-disabled\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$owner_pid" "$((now - 5))" > "$lock/metadata"
  printf 'token=disabled\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  kill -STOP "$owner_pid" || return 1
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=0
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  if grep -Eq 'heartbeat is (fresh|stale)' <<< "$out"; then
    echo "disabled heartbeat reporting changed message: $out"
    return 1
  fi
  grep -q 'write dispatch blocked; held by job=task-disabled.*for [0-9][0-9]*s' <<< "$out" ||
    { echo "pre-heartbeat contention message missing: $out"; return 1; }
  : > "$stop"
  kill -CONT "$owner_pid" || return 1
  wait "$owner_pid" || return 1
  owner_pid=""
  return 0
)

# ---------------------------------------------------------------- step 36
# Unknown lease age never becomes a heartbeat-staleness claim.
t36() (
  local dir lock out rc; dir=$(ws heartbeat_unknown_age)
  lock="$dir/.maestro-write.lock"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  prepare_generation "$lock" || return 1
  printf 'token=unknown-age\npid=%s\nprocess_start=Mon Jan  1 00:00:00 2026\njob_id=task-unknown-age\nsession_id=session-unknown-age\nstarted_at=unknown\nstarted_epoch=not-a-number\ndigest_before=unavailable\n' \
    "$$" > "$lock/metadata"
  printf 'token=unknown-age\nepoch=1\n' > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  if grep -Eq 'heartbeat is (fresh|stale)' <<< "$out"; then
    echo "unknown age was reported as heartbeat staleness: $out"
    return 1
  fi
  grep -q 'for unknown' <<< "$out" ||
    { echo "unknown held age missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 37
# Repository safety must see writers from every companion session.
t37() (
  local dir writers="" rc; dir=$(ws cross_session_writer)
  status_running_job task-session-a-writer true > "$dir/status.json"
  cd "$dir" || exit 1
  . "$LIB"
  companion_resolve() { printf '%s' "$FAKE"; }
  progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  export MAESTRO_TEST_STATUS_SESSION_ID=session-a
  export CODEX_COMPANION_SESSION_ID=session-b
  write_lock_workspace_writers writers; rc=$?
  [ "$rc" -eq 0 ] || { echo "global status rc=$rc want 0"; return 1; }
  printf '%s\n' "$writers" | awk '$1 == "task-session-a-writer" && $2 == "true" { found = 1 } END { exit !found }' ||
    { echo "session B could not see session A writer: ${writers:-empty}"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 38
# Process identity is stable across caller locale and timezone changes.
t38() (
  local dir lock owner_token out rc; dir=$(ws process_identity_tz)
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1
  . "$LIB"
  companion_resolve() { printf '%s' "$FAKE"; }
  progress_init
  PATH=$(tz_sensitive_ps_path "$dir"); export PATH
  export TZ=owner-zone LC_ALL=POSIX
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-tz-owner-aaaaaa >/dev/null 2>&1 || return 1
  lock="$dir/.maestro-write.lock"
  owner_token=$MAESTRO_LOCK_TOKEN
  unset MAESTRO_LOCK_TOKEN
  export TZ=contender-zone LC_ALL=C
  out=$(write_lock_acquire task-tz-contender-aaaaaa 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11 after TZ/locale change: $out"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = "$owner_token" ] ||
    { echo "live owner's token changed after TZ/locale change"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 39
# A stale heartbeat is not permission to clear a still-live recorded owner.
t39() (
  local dir lock status out rc now owner_start ps_shim; dir=$(ws clear_stale_live_owner)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  owner_start='Mon Jan  1 00:00:00 2026'
  ps_shim="$TEST_ROOT/clear-shim"
  mkdir -p "$ps_shim"
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$owner_start" > "$ps_shim/ps"
  chmod +x "$ps_shim/ps"
  prepare_generation "$lock" || return 1
  printf 'token=stale-live\npid=%s\nprocess_start=%s\njob_id=task-stale-live\nsession_id=session-stale-live\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$$" "$owner_start" "$((now - 5))" > "$lock/metadata"
  printf 'token=stale-live\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" heartbeat || return 1
  status_empty > "$status"
  out=$(run_clear_lease "$dir" "$status" 1 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11: $out"; return 1; }
  grep -q 'refusing to clear.*owner process is still alive' <<< "$out" ||
    { echo "live-owner refusal missing: $out"; return 1; }
  [ -d "$lock" ] || { echo "stale heartbeat cleared a live owner"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 40
# A stale classification cannot delete a generation acquired while the reclaimer was paused.
t40() (
  local dir lock state shim real_rm bpid apid brc arc successes
  dir=$(ws concurrent_reclaim)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  state="$dir/reclaim-state"
  shim="$state/shim"
  real_rm=$(command -v rm)
  mkdir -p "$shim"
  prepare_generation "$lock" || return 1
  status_empty > "$dir/status.json"
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=task-old\nsession_id=session-old\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  cat > "$shim/rm" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$lock/metadata" ] && [ "\${MAESTRO_TEST_RECLAIMER:-}" = B ] &&
    [ ! -d "$lock/.reclaim" ] && [ ! -e "$state/b-paused-once" ]; then
    : > "$state/b-paused-once"
    while [ ! -e "$state/a-ready" ]; do sleep 0.05; done
    break
  fi
done
exec "$real_rm" "\$@"
EOF
  chmod +x "$shim/rm"

  run_reclaimer() {
    local role="$1" path="$2"
    (
      cd "$dir" || exit 1
      . "$LIB"
      companion_resolve() { printf '%s' "$FAKE"; }
      progress_init
      export MAESTRO_TEST_STATUS="$dir/status.json"
      export MAESTRO_TEST_RECLAIMER="$role"
      export PATH="$path"
      write_lock_acquire "task-${role}-owner" >/dev/null 2>&1
      rc=$?
      printf '%s\n' "$rc" > "$state/${role}.rc"
      [ "$rc" -ne 0 ] || printf '%s\n' "$MAESTRO_LOCK_TOKEN" > "$state/${role}.token"
      : > "$state/${role}-ready"
      while [ ! -e "$state/release-${role}" ]; do sleep 0.05; done
    )
  }

  run_reclaimer B "$shim:$PATH" & bpid=$!
  for _ in $(seq 1 600); do
    [ -e "$state/b-paused-once" ] || [ -e "$state/B-ready" ] || { sleep 0.05; continue; }
    break
  done
  [ -e "$state/b-paused-once" ] || [ -e "$state/B-ready" ] ||
    { kill "$bpid" 2>/dev/null || :; echo "reclaimer B did not reach acquisition"; return 1; }

  run_reclaimer A "$PATH" & apid=$!
  for _ in $(seq 1 600); do
    [ -e "$state/A-ready" ] && [ -e "$state/B-ready" ] || { sleep 0.05; continue; }
    break
  done
  if [ ! -e "$state/A-ready" ] || [ ! -e "$state/B-ready" ]; then
    : > "$state/release-A"; : > "$state/release-B"
    kill "$apid" "$bpid" 2>/dev/null || :
    echo "concurrent reclaimers did not finish"
    return 1
  fi
  brc=$(sed -n '1p' "$state/B.rc")
  arc=$(sed -n '1p' "$state/A.rc")
  successes=0
  [ "$brc" -eq 0 ] && successes=$((successes + 1))
  [ "$arc" -eq 0 ] && successes=$((successes + 1))
  : > "$state/release-A"; : > "$state/release-B"
  wait "$apid" 2>/dev/null || :
  wait "$bpid" 2>/dev/null || :
  [ "$successes" -eq 1 ] ||
    { echo "successful reclaimers=$successes want 1 (A=$arc B=$brc)"; return 1; }
  winner=A; [ "$brc" -eq 0 ] && winner=B
  winner_token=$(sed -n '1p' "$state/${winner}.token")
  recorded_token=$(sed -n 's/^token=//p' "$lock/metadata" 2>/dev/null | head -1)
  [ -n "$winner_token" ] && [ "$recorded_token" = "$winner_token" ] ||
    { echo "successful reclaimer $winner lost ownership (winner=$winner_token recorded=${recorded_token:-missing})"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 41
# A large wait poll cannot overshoot the documented wait cap.
t41() (
  local dir out rc started elapsed; dir=$(ws wait_poll_clipped)
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-clipped-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=1 MAESTRO_LOCK_WAIT_POLL_SEC=4
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 2 ] || { echo "elapsed=${elapsed}s exceeded 1s cap by more than clock granularity: $out"; return 1; }
)

# ---------------------------------------------------------------- step 42
# Repository-global writer parsing accepts valid compact JSON and rejects bad entries.
t42() (
  local dir output result evidence rc; dir=$(ws compact_writer_status)
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  companion_resolve() { printf '%s' "$FAKE"; }
  result="$dir/writers.result"
  evidence="$dir/writers.evidence"
  printf '%s\n' '{"running":[],"latestFinished":null}' > "$dir/status.json"
  export MAESTRO_TEST_STATUS="$dir/status.json"
  companion_writers "$result" "$evidence"; rc=$?
  output=$(cat "$result")
  [ "$rc" -eq 0 ] && [ -z "$output" ] ||
    { echo "compact empty status rc=$rc output=${output:-empty}"; return 1; }

  printf '%s\n' '{"running":[{"id":"task-compact0-aaaaaa","write":true}],"latestFinished":null}' > "$dir/status.json"
  companion_writers "$result" "$evidence"; rc=$?
  output=$(cat "$result")
  [ "$rc" -eq 0 ] || { echo "compact writer status rc=$rc"; return 1; }
  [ "$output" = $'task-compact0-aaaaaa\ttrue' ] ||
    { echo "compact writer output=$output"; return 1; }

  printf '%s\n' '{"running":[{"id":"task-bad0000-aaaaaa"}]}' > "$dir/status.json"
  companion_writers "$result" "$evidence" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] || { echo "malformed writer entry rc=$rc want 4"; return 1; }
)

# ---------------------------------------------------------------- step 43
# Operator recovery removes only the generation it inspected.
t43() (
  local dir lock result evidence rc token; dir=$(ws clear_generation_fence)
  lock="$dir/.maestro-write.lock"
  result="$dir/clear.result"
  evidence="$dir/clear.evidence"
  cd "$dir" || exit 1
  . "$LEASE_LIB"
  progress_init
  prepare_generation "$lock" || return 1
  printf 'token=first\npid=999999\nprocess_start=dead\njob_id=task-first00-aaaaaa\nsession_id=test\nstarted_epoch=1\nquiescence=unconfirmed\nunconfirmed_job=task-first00-aaaaaa\nunconfirmed_reason=deadline\n' > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  write_lock_workspace_writers() {
    printf 'token=second\npid=999999\nprocess_start=dead\njob_id=task-second0-aaaaaa\nsession_id=test\nstarted_epoch=1\nquiescence=unconfirmed\nunconfirmed_job=task-second0-aaaaaa\nunconfirmed_reason=deadline\n' > "$lock/metadata"
    sync_generation_field "$lock" || return 1
    return 0
  }
  write_lease_clear "$result" "$evidence"; rc=$?
  [ "$rc" -eq 11 ] || { echo "generation change clear rc=$rc want 11"; return 1; }
  token=$(sed -n 's/^token=//p' "$lock/metadata")
  [ "$token" = second ] || { echo "new generation was modified"; return 1; }
  [ ! -d "$lock/.reclaim" ] || { echo "failed clear left generation claim"; return 1; }
)

# ---------------------------------------------------------------- step 44
# Poison alone does not authorize clearing a live supervisor generation.
t44() (
  local dir lock result evidence start rc; dir=$(ws clear_live_owner)
  lock="$dir/.maestro-write.lock"
  result="$dir/clear.result"
  evidence="$dir/clear.evidence"
  cd "$dir" || exit 1
  . "$LEASE_LIB"
  progress_init
  prepare_generation "$lock" || return 1
  start=$(write_lock_process_start "$$")
  printf 'token=live\npid=%s\nprocess_start=%s\njob_id=task-live0000-aaaaaa\nsession_id=test\nstarted_epoch=1\nquiescence=unconfirmed\nunconfirmed_job=task-live0000-aaaaaa\nunconfirmed_reason=deadline\n' \
    "$$" "${start:-unavailable}" > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  write_lock_workspace_writers() { return 0; }
  write_lease_clear "$result" "$evidence"; rc=$?
  [ "$rc" -eq 11 ] || { echo "live owner clear rc=$rc want 11"; return 1; }
  [ -f "$lock/metadata" ] || { echo "live owner generation was removed"; return 1; }
)

# ---------------------------------------------------------------- review finding 1
t45_publication_temp_does_not_wedge_steal() (
  local dir lock rc
  dir=$(ws publication_temps)
  lock="$dir/.maestro-write.lock"
  status_empty > "$dir/status.json"
  prepare_generation "$lock" || return 1
  printf 'token=old\npid=99999999\nprocess_start=dead\njob_id=task-stale-temp-aaaaaa\nsession_id=test\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' \
    > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  : > "$lock/heartbeat.tmp.deadtoken"
  cd "$dir" || exit 1
  . "$LIB"
  companion_resolve() { printf '%s' "$FAKE"; }
  progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-after-temp-aaaaaa >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "stale temp steal rc=$rc want 0"; return 1; }
  [ -f "$lock/metadata" ] || { echo "steal left a metadata-less lock"; return 1; }
  write_lock_release >/dev/null 2>&1
)

t46_publication_temp_does_not_wedge_release() (
  local dir lock
  dir=$(ws release_publication_temp)
  lock="$dir/.maestro-write.lock"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-release-temp-aaaaaa >/dev/null 2>&1 || return 1
  : > "$lock/metadata.tmp.deadtoken"
  write_lock_release >/dev/null 2>&1
  [ ! -d "$lock" ] || { echo "publication temp wedged normal release"; return 1; }
)

# Unknown entries remain a loud release failure.
t47_unknown_lock_entry_is_not_deleted() (
  local dir lock
  dir=$(ws unknown_lock_entry)
  lock="$dir/.maestro-write.lock"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-unknown-entry-aaaaaa >/dev/null 2>&1 || return 1
  : > "$lock/not-a-publication-temp"
  write_lock_release >/dev/null 2>&1
  [ -f "$lock/not-a-publication-temp" ] ||
    { echo "release deleted an unknown lock entry"; return 1; }
  [ -d "$lock" ] || { echo "release hid the unknown-entry failure"; return 1; }
)

# ---------------------------------------------------------------- review finding 4
t48_prelaunch_interrupt_releases_without_poison() (
  local repo shim marker output plan pid rc count real_git t48_home node_shim companion status
  repo="$TEST_ROOT/prelaunch-interrupt-repo"
  shim="$TEST_ROOT/prelaunch-interrupt-shim"
  marker="$TEST_ROOT/prelaunch-interrupt.marker"
  output="$TEST_ROOT/prelaunch-interrupt.output"
  plan="$repo/plan.md"
  t48_home="$TEST_ROOT/prelaunch-interrupt-home"
  node_shim="$TEST_ROOT/prelaunch-interrupt-node-shim"
  companion="$t48_home/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
  status="$TEST_ROOT/prelaunch-interrupt-status.json"
  real_git=$(command -v git)
  mkdir -p "$repo" "$shim" "$node_shim" "$(dirname "$companion")" || return 1
  ln -sf "$FAKE" "$companion" || return 1
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-e" ]; then exec %q "$@"; fi\nshift\nexec %q %q "$@"\n' \
    "$REAL_NODE" "$REAL_NODE" "$FAKE" > "$node_shim/node" || return 1
  chmod +x "$node_shim/node" || return 1
  status_empty > "$status"
  git init -q "$repo" || return 1
  (
    cd "$repo" || exit 1
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    printf 'Objective: interrupt before launch.\n' > plan.md
    git add seed plan.md
    git commit -q -m init
  ) || return 1
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = hash-object ] && [ "${2:-}" = --no-filters ] && [ "${3:-}" = --stdin ]; then' \
    '  : > "$MAESTRO_TEST_DIGEST_MARKER"' \
    '  sleep 5' \
    'fi' \
    'exec "$MAESTRO_TEST_REAL_GIT" "$@"' > "$shim/git" || return 1
  chmod +x "$shim/git" || return 1
  set -m
  (
    cd "$repo" &&
      exec env HOME="$t48_home" PATH="$shim:$node_shim:$PATH" MAESTRO_TEST_REAL_GIT="$real_git" \
        MAESTRO_TEST_DIGEST_MARKER="$marker" MAESTRO_TEST_STATUS="$status" MAESTRO_LOCK_WAIT_SEC=0 \
        bash "$LOOP" --plan "$plan" --verify true --max-iters 1
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  count=0
  while [ ! -e "$marker" ] && [ "$count" -lt 600 ]; do
    sleep 0.05
    count=$((count + 1))
  done
  [ -e "$marker" ] ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "digest window was not reached"; return 1; }
  kill -TERM "$pid" || return 1
  wait "$pid"; rc=$?
  [ "$rc" -eq 4 ] || { echo "prelaunch signal rc=$rc want 4: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -qx 'MAESTRO_FINAL: LOOP INTERRUPTED rc=4' "$output" ||
    { echo "INTERRUPTED final missing: $(tr '\n' ' ' < "$output")"; return 1; }
  ! grep -q 'lease retained' "$output" ||
    { echo "prelaunch signal falsely claimed retained poison"; return 1; }
  [ ! -d "$repo/.git/maestro-write.lock" ] ||
    { echo "prelaunch signal left the lease directory"; return 1; }
)

# ---------------------------------------------------------------- review finding 7
t49_digest_recurses_through_nested_repositories() (
  local repo nested deeper before after
  repo="$TEST_ROOT/recursive-digest-repo"
  nested="$repo/nested-a"
  deeper="$nested/nested-b"
  git init -q "$repo" || return 1
  git init -q "$nested" || return 1
  git init -q "$deeper" || return 1
  for root in "$repo" "$nested" "$deeper"; do
    (
      cd "$root" || exit 1
      git config user.email p@p
      git config user.name p
      printf 'seed\n' > seed
      git add seed
      git commit -q -m init
    ) || return 1
  done
  cd "$repo" || exit 1
  . "$LIB"
  before=$(repo_digest) || return 1
  printf 'changed\n' > "$deeper/seed"
  after=$(repo_digest) || return 1
  [ "$before" != "$after" ] ||
    { echo "digest ignored a change in a doubly nested repository"; return 1; }
)

# ---------------------------------------------------------------- review finding 10
t50_effective_poison_state_is_shared() (
  local dir lock metadata selected quiescence
  dir=$(ws effective_poison)
  lock="$dir/.maestro-write.lock"
  metadata="$lock/metadata"
  mkdir -p "$lock"
  printf 'token=base\nquiescence=confirmed\n' > "$metadata"
  cd "$dir" || exit 1
  . "$LIB"
  write_lock_effective_poison "$lock" "$metadata" selected quiescence || return 1
  [ "$selected" = "$metadata" ] && [ "$quiescence" = confirmed ] ||
    { echo "base poison state path=$selected quiescence=$quiescence"; return 1; }
  printf 'token=base\nquiescence=unconfirmed\n' > "$lock/metadata.new"
  write_lock_effective_poison "$lock" "$metadata" selected quiescence || return 1
  [ "$selected" = "$lock/metadata.new" ] && [ "$quiescence" = unconfirmed ] ||
    { echo "staged poison state path=$selected quiescence=$quiescence"; return 1; }
)

# ---------------------------------------------------------------- wait diagnostics
t51_wait_diagnostics_identify_waiter_budget() (
  local dir out rc started_epoch metadata rewritten
  dir=$(ws wait_diagnostics)
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-diagnostic-aaaaaa >/dev/null 2>&1 || return 1
  metadata="$dir/.maestro-write.lock/metadata"
  started_epoch=$(date +%s)
  rewritten="$metadata.rewritten"
  sed "s/^started_epoch=.*/started_epoch=$((started_epoch - 60))/" \
    "$metadata" > "$rewritten" || return 1
  mv -f "$rewritten" "$metadata" || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -Eq 'lease_age=6[2-5]s' ||
    { echo "lease age missing or inaccurate: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'wait_budget=2s' ||
    { echo "wait budget missing: $out"; return 1; }
  printf '%s\n' "$out" | grep -Eq 'wait_elapsed=[2-3]s' ||
    { echo "wait elapsed missing or inaccurate: $out"; return 1; }
)

t52_contention_progress_is_throttled() (
  local dir out rc wait_lines
  dir=$(ws wait_progress)
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-progress-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=3 MAESTRO_LOCK_WAIT_POLL_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  wait_lines=$(printf '%s\n' "$out" | grep -c 'waiting for the write lease' || true)
  [ "$wait_lines" -eq 1 ] ||
    { echo "wait_lines=$wait_lines want 1: $out"; return 1; }
)

t53_initializing_wait_respects_budget() (
  local dir lock out rc started elapsed
  dir=$(ws initializing_wait_budget)
  lock="$dir/.maestro-write.lock"
  prepare_generation "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  export MAESTRO_LOCK_WAIT_SEC=1 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 2 ] ||
    { echo "initializing-owner elapsed=${elapsed}s exceeded 1s cap: $out"; return 1; }
  printf '%s\n' "$out" | grep -Eq 'wait_budget=1s wait_elapsed=[1-2]s' ||
    { echo "initializing-owner budget missing: $out"; return 1; }
)

t54_atomic_clear_preserves_successor() (
  local dir lock first_result first_evidence second_result second_evidence
  local second_rc_file rc move_rc token candidate
  dir=$(ws atomic_clear_successor)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  first_result="$dir/first.result"
  first_evidence="$dir/first.evidence"
  second_result="$dir/second.result"
  second_evidence="$dir/second.evidence"
  second_rc_file="$dir/second.rc"
  prepare_generation "$lock" || return 1
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=task-old00000-aaaaaa\nsession_id=test\nstarted_epoch=1\nquiescence=unconfirmed\nunconfirmed_job=task-old00000-aaaaaa\nunconfirmed_reason=deadline\n' > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_workspace_writers() {
    printf -v "$1" '%s' ""
    return 0
  }
  mv() {
    if [ "${1-}" = "$lock" ]; then
      write_lease_clear "$second_result" "$second_evidence" >/dev/null 2>&1
      printf '%s\n' "$?" > "$second_rc_file"
      command mv "$@"
      move_rc=$?
      prepare_generation "$lock" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee || return 1
      printf 'token=successor\npid=999998\nprocess_start=dead\njob_id=task-successor-aaaaaa\nsession_id=test\nstarted_epoch=1\n' > "$lock/metadata"
      sync_generation_field "$lock" || return 1
      return "$move_rc"
    fi
    command mv "$@"
  }
  write_lease_clear "$first_result" "$first_evidence" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "first clear rc=$rc want 11 after successor acquisition"; return 1; }
  [ "$(cat "$second_rc_file")" -eq 11 ] ||
    { echo "second clear bypassed the active generation claim"; return 1; }
  token=$(sed -n 's/^token=//p' "$lock/metadata")
  [ "$token" = successor ] ||
    { echo "successor generation was removed or changed (token=${token:-missing})"; return 1; }
  for candidate in "$lock".reclaim.clear-*; do
    [ ! -e "$candidate" ] ||
      { echo "atomic clear left a reclaim generation: $candidate"; return 1; }
  done
)

t55_metadata_only_clear_is_reported() (
  local dir lock result evidence out rc
  dir=$(ws metadata_only_clear)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  result="$dir/result"
  evidence="$dir/evidence"
  prepare_generation "$lock" || return 1
  printf 'token=metadata-only\npid=999999\nprocess_start=dead\njob_id=task-metadata-only\nsession_id=test\nstarted_epoch=1\n' > "$lock/metadata"
  sync_generation_field "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_workspace_writers() {
    printf -v "$1" '%s' ""
    return 0
  }
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  out=$(write_lease_clear "$result" "$evidence" 3>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "metadata-only clear rc=$rc want 0: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'clearing metadata-only write lease' ||
    { echo "metadata-only structure missing from diagnostics: $out"; return 1; }
  [ ! -d "$lock" ] || { echo "metadata-only generation survived clear"; return 1; }
)

t56_orphan_identity_fences_successor_publication() (
  local dir lock result evidence rc probe_a probe_b
  dir=$(ws orphan_identity_successor)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  result="$dir/result"
  evidence="$dir/evidence"
  prepare_generation "$lock" || return 1
  touch -t 202001010000 "$lock"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_workspace_writers() {
    rm -rf "$lock"
    prepare_generation "$lock" || return 1
    touch -t 202001010000 "$lock"
    printf -v "$1" '%s' ""
    return 0
  }
  write_lease_clear "$result" "$evidence"
  rc=$?
  [ "$rc" -eq 11 ] || { echo "orphan clear rc=$rc want 11"; return 1; }
  [ -d "$lock" ] || { echo "successor publication directory was removed"; return 1; }
  probe_a=$(mktemp -d "$dir/identity-a.XXXXXX") || return 1
  probe_b=$(mktemp -d "$dir/identity-b.XXXXXX") || return 1
  prepare_generation "$probe_a" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || return 1
  prepare_generation "$probe_b" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || return 1
  [ "$(write_lock_path_identity "$probe_a")" != "$(write_lock_path_identity "$probe_b")" ] ||
    { echo "directory identity helper does not distinguish generations"; return 1; }
  [ ! -e "$lock/metadata" ] ||
    { echo "successor unexpectedly published metadata"; return 1; }
)
t57_publication_claim_blocks_concurrent_clear() (
  local dir lock identity generation record state publisher rc result evidence i
  dir=$(ws publication_claim_clear)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  state="$dir/interleave"
  result="$dir/clear.result"
  evidence="$dir/clear.evidence"
  mkdir -p "$state"
  prepare_generation "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  identity=$(write_lock_path_identity "$lock") || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=publisher\ngeneration=%s\npid=999999\nprocess_start=dead\njob_id=task-publisher-aaaaaa\nsession_id=test\nstarted_at=2020-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable' "$generation")
  (
    mv() {
      command mv "$@" || return
      case "$*" in
        *"$lock/metadata")
          : > "$state/metadata-moved"
          while [ ! -e "$state/finish-publication" ]; do sleep 0.05; done
          ;;
      esac
    }
    write_lock_publish_metadata "$lock" "$identity" publisher "$record"
  ) > "$state/publisher.out" 2>&1 &
  publisher=$!
  i=0
  while [ ! -e "$state/metadata-moved" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$state/metadata-moved" ]; then
    : > "$state/finish-publication"
    wait "$publisher" 2>/dev/null || :
    echo "publisher did not reach its final metadata check"
    return 1
  fi
  write_lock_workspace_writers() { printf -v "$1" '%s' ""; }
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  write_lease_clear "$result" "$evidence" > "$state/clear.out" 2>&1 3>&1
  rc=$?
  : > "$state/finish-publication"
  wait "$publisher" || { echo "publisher failed after the clearer was refused"; return 1; }
  [ "$rc" -eq 11 ] || { echo "concurrent clear rc=$rc want 11"; return 1; }
  grep -q 'generation claim is unavailable' "$state/clear.out" ||
    { echo "clear did not contend on the publisher claim"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = publisher ] ||
    { echo "publisher lost ownership after concurrent clear"; return 1; }
)
t58_reclaimer_diagnostics_include_wait_budget() (
  local dir lock state identity token holder out rc i
  dir=$(ws reclaimer_wait_summary)
  lock="$dir/.maestro-write.lock"
  state="$dir/claim-holder"
  dead_lock "$dir" task-reclaimer-aaaaaa
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  identity=$(write_lock_path_identity "$lock") || return 1
  token=$(write_lock_metadata_value "$lock/metadata" token)
  (
    lock_claim_acquire "$lock" "$identity" "$token" || exit 1
    : > "$state.ready"
    while [ ! -e "$state.release" ]; do sleep 0.05; done
    lock_claim_release "$lock" "$identity" "$token"
  ) &
  holder=$!
  i=0
  while [ ! -e "$state.ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state.ready" ] || { echo "claim holder did not start"; return 1; }
  write_lock_workspace_writers() {
    printf -v "$1" '%s' ""
    return 0
  }
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  : > "$state.release"
  wait "$holder" || return 1
  [ "$rc" -eq 11 ] || { echo "reclaimer contention rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -Eq 'wait_budget=0s wait_elapsed=[0-9]+s' ||
    { echo "reclaimer contention omitted wait accounting: $out"; return 1; }
)

t59_valid_clear_identity_fences_same_token_successor() (
  local dir lock metadata old replacement result evidence rc
  dir=$(ws valid_clear_same_token)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  metadata="$lock/metadata"
  old="$lock.observed"
  replacement="$lock.successor"
  result="$dir/result"
  evidence="$dir/evidence"
  prepare_generation "$lock" || return 1
  printf 'token=replayed\npid=999999\nprocess_start=dead\njob_id=task-replayed-aaaaaa\nsession_id=test\nstarted_epoch=1\nquiescence=unconfirmed\nunconfirmed_job=task-replayed-aaaaaa\nunconfirmed_reason=deadline\n' > "$metadata"
  sync_generation_field "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  stat() { printf '7:42\n'; }
  write_lock_workspace_writers() {
    command mkdir "$replacement" || return 1
    command cp "$metadata" "$replacement/metadata" || return 1
    prepare_generation "$replacement" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || return 1
    sync_generation_field "$replacement" || return 1
    command mv "$lock" "$old" || return 1
    command mv "$replacement" "$lock" || return 1
    printf -v "$1" '%s' ""
    return 0
  }
  write_lease_clear "$result" "$evidence" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 11 ] || { echo "same-token clear rc=$rc want 11"; return 1; }
  [ -f "$lock/generation" ] ||
    { echo "same-token successor generation was removed"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = replayed ] ||
    { echo "same-token successor metadata changed"; return 1; }
)

t60_release_identity_fences_same_token_successor() (
  local dir lock metadata old replacement evidence token
  dir=$(ws release_same_token)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  metadata="$lock/metadata"
  old="$lock.observed"
  replacement="$lock.successor"
  evidence="$dir/evidence"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  stat() { printf '7:42\n'; }
  write_lock_acquire task-release-aaaaaa >/dev/null 2>&1 || return 1
  token=$MAESTRO_LOCK_TOKEN
  write_lock_workspace_writers() {
    command mkdir "$replacement" || return 1
    command cp "$metadata" "$replacement/metadata" || return 1
    prepare_generation "$replacement" cccccccccccccccccccccccccccccccc || return 1
    sync_generation_field "$replacement" || return 1
    command mv "$lock" "$old" || return 1
    command mv "$replacement" "$lock" || return 1
    printf -v "$1" '%s' ""
    return 0
  }
  write_lease_end "$evidence" >/dev/null 2>&1
  [ -f "$lock/generation" ] ||
    { echo "same-token successor was removed during release"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = "$token" ] ||
    { echo "same-token successor metadata changed during release"; return 1; }
  [ "$MAESTRO_LOCK_ACQUIRED" -eq 1 ] ||
    { echo "release dropped local ownership after rejecting a changed generation"; return 1; }
)

t61_killed_publisher_claim_is_recoverable() (
  local dir lock identity generation record state publisher child result evidence rc candidate i
  local shim real_mv
  dir=$(ws killed_publisher_claim)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  state="$dir/interleave"
  result="$dir/clear.result"
  evidence="$dir/clear.evidence"
  mkdir -p "$state"
  shim="$state/shim"
  real_mv=$(command -v mv) || return 1
  mkdir -p "$shim"
  cat > "$shim/mv" <<EOF
#!/bin/sh
"$real_mv" "\$@" || exit
case "\$*" in
  *"$lock/metadata")
    sleep 10 &
    printf '%s\n' "\$!" > "$state/child.pid"
    wait "\$!"
    ;;
esac
EOF
  chmod +x "$shim/mv"
  prepare_generation "$lock" || return 1
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  identity=$(write_lock_path_identity "$lock") || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=publisher\ngeneration=%s\npid=999999\nprocess_start=dead\njob_id=task-publisher-aaaaaa\nsession_id=test\nstarted_at=2020-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable' "$generation")
  (
    export PATH="$shim:$PATH"
    write_lock_publish_metadata "$lock" "$identity" publisher "$record"
  ) > "$state/publisher.out" 2>&1 &
  publisher=$!
  i=0
  while [ ! -s "$state/child.pid" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$state/child.pid" ] ||
    { echo "publisher did not enter its fenced metadata update"; return 1; }
  child=$(cat "$state/child.pid")
  kill -KILL "$publisher" 2>/dev/null || return 1
  wait "$publisher" 2>/dev/null || :
  kill -0 "$child" 2>/dev/null ||
    { echo "blocked publication child exited before claim recovery"; return 1; }
  write_lock_workspace_writers() { printf -v "$1" '%s' ""; }
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  write_lease_clear "$result" "$evidence" > "$state/clear.out" 2>&1 3>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    kill "$child" 2>/dev/null || :
    echo "clear could not recover killed publisher claim: $(tr '\n' ' ' < "$state/clear.out")"
    return 1
  fi
  [ ! -d "$lock" ] ||
    { echo "killed publisher generation survived operator clear"; return 1; }
  kill "$child" 2>/dev/null || :
  for candidate in "$lock".reclaim.*; do
    [ ! -e "$candidate" ] ||
      { echo "killed publisher recovery leaked $candidate"; return 1; }
  done
)

t62_acquisition_waits_for_the_generation_gate() (
  local dir lock gate state holder acquirer rc i
  dir=$(ws acquisition_generation_gate)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  state="$dir/gate-state"
  mkdir -p "$state"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  gate=$(lock_claim_gate_path "$lock") || return 1
  (
    lock_claim_gate_acquire "$gate" || exit 1
    : > "$state/ready"
    while [ ! -e "$state/release" ]; do sleep 0.05; done
    lock_claim_unlock
  ) &
  holder=$!
  i=0
  while [ ! -e "$state/ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/ready" ] ||
    { echo "generation gate holder did not start"; return 1; }
  (
    write_lock_workspace_writers() { printf -v "$1" '%s' ""; }
    export MAESTRO_LOCK_WAIT_SEC=3 MAESTRO_LOCK_WAIT_POLL_SEC=1
    write_lock_acquire task-gate-acquirer-aaaaaa
    rc=$?
    printf '%s\n' "$rc" > "$state/acquire.rc"
    if [ "$rc" -eq 0 ]; then write_lock_release; fi
    exit "$rc"
  ) > "$state/acquire.out" 2>&1 3>&1 &
  acquirer=$!
  sleep 0.3
  if [ -d "$lock" ]; then
    : > "$state/bypassed"
  fi
  : > "$state/release"
  wait "$holder" || return 1
  wait "$acquirer"
  rc=$?
  [ "$rc" -eq 0 ] ||
    { echo "acquisition after gate release rc=$rc: $(tr '\n' ' ' < "$state/acquire.out")"; return 1; }
  [ ! -e "$state/bypassed" ] ||
    { echo "acquisition created the write lock while the generation gate was held"; return 1; }
  [ ! -d "$lock" ] ||
    { echo "acquisition left a write lock generation behind"; return 1; }
)

t63_release_rejects_a_preexisting_same_token_successor() (
  local dir lock retired token successor_identity
  dir=$(ws release_preexisting_successor)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  retired="$dir/retired"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_acquire task-release-owner-aaaaaa >/dev/null 2>&1 || return 1
  token=$MAESTRO_LOCK_TOKEN
  command mv "$lock" "$retired" || return 1
  prepare_generation "$lock" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee || return 1
  cp "$retired/metadata" "$lock/metadata" || return 1
  sync_generation_field "$lock" || return 1
  successor_identity=$(write_lock_path_identity "$lock") || return 1
  write_lock_workspace_writers() { printf -v "$1" '%s' ""; }
  write_lock_release
  [ -d "$lock" ] ||
    { echo "release removed a same-token successor present before release"; return 1; }
  [ "$(write_lock_path_identity "$lock")" = "$successor_identity" ] ||
    { echo "release replaced the same-token successor"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = "$token" ] ||
    { echo "release changed successor metadata"; return 1; }
  [ "$MAESTRO_LOCK_ACQUIRED" -eq 1 ] ||
    { echo "release dropped local ownership after rejecting a successor"; return 1; }
)

t64_owner_mutations_reject_a_preexisting_same_token_successor() (
  local dir lock retired expected
  dir=$(ws owner_mutation_preexisting_successor)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  retired="$dir/retired"
  expected="$dir/successor.metadata"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_acquire task-mutation-owner-aaaaaa >/dev/null 2>&1 || return 1
  command mv "$lock" "$retired" || return 1
  prepare_generation "$lock" ffffffffffffffffffffffffffffffff || return 1
  cp "$retired/metadata" "$lock/metadata" || return 1
  sync_generation_field "$lock" || return 1
  cp "$lock/metadata" "$expected" || return 1
  write_lock_set_job task-wrong-successor-aaaaaa >/dev/null 2>&1 || :
  write_lock_poison task-wrong-successor-aaaaaa deadline >/dev/null 2>&1 || :
  export MAESTRO_LOCK_HEARTBEAT_LAST_WRITE_EPOCH=0
  export MAESTRO_LOCK_HEARTBEAT_LAST_TOKEN=""
  write_lock_heartbeat_write >/dev/null 2>&1 || :
  cmp "$expected" "$lock/metadata" ||
    { echo "owner metadata mutation rewrote a same-token successor"; return 1; }
  [ ! -e "$lock/metadata.new" ] ||
    { echo "owner poison mutation staged data in a same-token successor"; return 1; }
  [ ! -e "$lock/heartbeat" ] ||
    { echo "owner heartbeat mutation wrote into a same-token successor"; return 1; }
)

t65_poison_finalize_rejects_a_preexisting_same_token_successor() (
  local dir lock retired expected staged result evidence rc
  dir=$(ws poison_finalize_preexisting_successor)
  dir=$(cd "$dir" && pwd -P)
  lock="$dir/.maestro-write.lock"
  retired="$dir/retired"
  expected="$dir/successor.metadata"
  staged="$dir/successor.metadata.new"
  result="$dir/result"
  evidence="$dir/evidence"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  write_lock_acquire task-poison-owner-aaaaaa >/dev/null 2>&1 || return 1
  write_lock_poison task-poison-owner-aaaaaa deadline >/dev/null 2>&1 || return 1
  command mv "$lock" "$retired" || return 1
  prepare_generation "$lock" 11111111111111111111111111111111 || return 1
  cp "$retired/metadata" "$lock/metadata" || return 1
  cp "$retired/metadata.new" "$lock/metadata.new" || return 1
  sync_generation_field "$lock" || return 1
  sync_generation_field "$lock" metadata.new || return 1
  cp "$lock/metadata" "$expected" || return 1
  cp "$lock/metadata.new" "$staged" || return 1
  _write_lease_turn_event cancel-end task-poison-owner-aaaaaa deadline \
    "$result" "$evidence"
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "poison finalize rc=$rc want 11 after generation replacement"; return 1; }
  cmp "$expected" "$lock/metadata" ||
    { echo "poison finalize rewrote a same-token successor"; return 1; }
  cmp "$staged" "$lock/metadata.new" ||
    { echo "poison finalize consumed successor staging metadata"; return 1; }
)

t66_failed_publication_retirement_blocks() (
  local dir lock output rc
  dir=$(ws failed_publication_retirement)
  dir=$(cd "$dir" && pwd -P)
  output="$dir/acquire.out"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  lock=$(write_lock_path) || return 1
  mv() {
    case "$*" in
      *"$lock/metadata.tmp."*"$lock/metadata"|*"$lock $lock.reclaim."*) return 1 ;;
    esac
    command mv "$@"
  }
  write_lock_acquire task-publication-failure-aaaaaa > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "failed publication retirement rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$lock" ] ||
    { echo "failed retirement unexpectedly removed the canonical generation"; return 1; }
  [ "$MAESTRO_LOCK_ACQUIRED" -eq 0 ] ||
    { echo "failed publication granted local ownership"; return 1; }
  grep -q 'could not be retired' "$output" ||
    { echo "failed retirement diagnostic missing"; return 1; }
)

t67_identity_failure_retirement_blocks() (
  local dir lock output rmdir_called rc
  dir=$(ws identity_failure_retirement)
  dir=$(cd "$dir" && pwd -P)
  output="$dir/acquire.out"
  rmdir_called="$dir/rmdir.called"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  lock=$(write_lock_path) || return 1
  lock_claim_path_identity() { return 1; }
  rmdir() { : > "$rmdir_called"; return 1; }
  write_lock_acquire task-identity-failure-aaaaaa > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "identity failure retirement rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$lock" ] ||
    { echo "identity failure unexpectedly removed the canonical generation"; return 1; }
  [ ! -e "$rmdir_called" ] ||
    { echo "identity failure attempted an unfenced rmdir"; return 1; }
  grep -q 'generation initialization failed.*retaining fail-closed lock' "$output" ||
    { echo "identity failure diagnostic missing"; return 1; }
)

t68_token_failure_precedes_creation() (
  local dir lock output rc
  dir=$(ws token_failure_precedes_creation)
  dir=$(cd "$dir" && pwd -P)
  output="$dir/acquire.out"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  lock=$(write_lock_path) || return 1
  od() { return 1; }
  write_lock_acquire task-token-failure-aaaaaa > "$output" 2>&1
  rc=$?
  [ "$rc" -eq 3 ] ||
    { echo "token generation failure rc=$rc want 3: $(tr '\n' ' ' < "$output")"; return 1; }
  [ ! -e "$lock" ] ||
    { echo "token generation failure created a canonical lock"; return 1; }
)

t69_default_wait_covers_a_default_implementation_run() (
  local dir deadline_file before deadline budget out rc
  dir=$(ws default_implementation_wait)
  deadline_file="$dir/deadline"
  cd "$dir" || exit 1
  . "$LIB"
  progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-default-wait-holder-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_WAIT_SEC
  export MAESTRO_LOCK_WAIT_POLL_SEC=1
  write_lock_wait_tick() {
    printf '%s\n' "$1" > "$deadline_file"
    return 1
  }
  before=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  deadline=$(cat "$deadline_file") || return 1
  budget=$((deadline - before))
  [ "$budget" -ge 14399 ] && [ "$budget" -le 14401 ] ||
    { echo "default wait budget=${budget}s want 14400s"; return 1; }
  printf '%s\n' "$out" | grep -q 'wait_budget=14400s' ||
    { echo "default wait diagnostic missing 14400s budget: $out"; return 1; }
)



printf '=== Plan F green-phase verification ===\n'
for t in t1 t2 t3 t4 t5 t5b t6 t7 t7b t8 t9 t9b t10a t10b t11 t12 t13 t14 t15 t16 t17 \
  t18 t19 t20 t21 t22 t23 t24 t25 t26 t27 t28 t29 t30 t31 t32 t33 t34 t35 t36 t37 t38 t39 t40 t41 t42 t43 t44 \
  t45_publication_temp_does_not_wedge_steal \
  t46_publication_temp_does_not_wedge_release \
  t47_unknown_lock_entry_is_not_deleted \
  t48_prelaunch_interrupt_releases_without_poison \
  t49_digest_recurses_through_nested_repositories \
  t50_effective_poison_state_is_shared t51_wait_diagnostics_identify_waiter_budget \
  t52_contention_progress_is_throttled t53_initializing_wait_respects_budget \
  t54_atomic_clear_preserves_successor t55_metadata_only_clear_is_reported \
  t56_orphan_identity_fences_successor_publication \
  t57_publication_claim_blocks_concurrent_clear \
  t58_reclaimer_diagnostics_include_wait_budget \
  t59_valid_clear_identity_fences_same_token_successor \
  t60_release_identity_fences_same_token_successor \
  t61_killed_publisher_claim_is_recoverable \
  t62_acquisition_waits_for_the_generation_gate \
  t63_release_rejects_a_preexisting_same_token_successor \
  t64_owner_mutations_reject_a_preexisting_same_token_successor \
  t65_poison_finalize_rejects_a_preexisting_same_token_successor \
  t66_failed_publication_retirement_blocks \
  t67_identity_failure_retirement_blocks \
  t68_token_failure_precedes_creation \
  t69_default_wait_covers_a_default_implementation_run; do
  msg=$($t 2>&1) && ok "$t" || bad "$t" "${msg:-no detail}"
done
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
