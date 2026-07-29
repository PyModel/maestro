#!/usr/bin/env bash
# Green-phase verification of Plan F, run by the orchestrator as review.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-companion.sh"
FAKE="$ROOT/tests/fixtures/fake-companion.mjs"
[ -f "$FAKE" ] || { echo "VERIFY FAIL: missing fixture $FAKE"; exit 1; }
TEST_ROOT=$(mktemp -d /tmp/maestro-planf-green.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

ws() { local d="$TEST_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

status_running_job() { printf '{\n  "running": [\n    {\n      "id": "%s",\n      "write": %s\n    }\n  ],\n  "latestFinished": null\n}\n' "$1" "$2"; }
status_empty()       { printf '{\n  "running": [],\n  "latestFinished": null\n}\n'; }

dead_lock() {  # dir job_id
  mkdir -p "$1/.maestro-write.lock"
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=%s\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\n' \
    "$2" > "$1/.maestro-write.lock/metadata"
}

# ---------------------------------------------------------------- step 2
# Live dispatcher must block WITHOUT querying the companion.
t2() (
  local dir log rc; dir=$(ws live); log="$dir/calls.log"; : > "$log"
  cd "$dir"
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
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
  cd "$dir"; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  unset MAESTRO_LOCK_TOKEN
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11 after dispatcher kill"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "successor broke a lease with a live writer"; return 1; }
  return 0
)
t10a() { kill_dispatcher_case "$(ws kill_before)" unknown task-other0000-bbbbbb; }
t10b() { kill_dispatcher_case "$(ws kill_after)" task-fake0000-aaaaaa task-fake0000-aaaaaa; }

printf '=== Plan F green-phase verification ===\n'
for t in t2 t3 t4 t5 t5b t6 t7 t7b t8 t9 t9b t10a t10b; do
  msg=$($t 2>&1) && ok "$t" || bad "$t" "${msg:-no detail}"
done
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
