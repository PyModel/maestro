#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-bounded-calls.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
WAIT_RC=0
WAIT_TIMED_OUT=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

wait_for_pid() {
  local pid="$1" limit="$2" elapsed=0
  WAIT_TIMED_OUT=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
      WAIT_TIMED_OUT=1
      kill -TERM -"$pid" 2>/dev/null || :
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || :
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" 2>/dev/null
  WAIT_RC=$?
  [ "$WAIT_TIMED_OUT" -eq 0 ] || WAIT_RC=124
}

milliseconds_now() {
  local value
  value=$(date +%s%N 2>/dev/null) || value=""
  case "$value" in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *) printf '%s\n' "$((value / 1000000))" ;;
  esac
}

# shellcheck source=../hooks/lib-companion.sh
source "$ROOT/hooks/lib-companion.sh"
progress_init

t1_hanging_status_is_bounded() {
  local timeout="${MAESTRO_COMPANION_TIMEOUT_SEC-2}"
  local output="$TEST_ROOT/hanging-status.out" pid started elapsed limit
  limit=$((timeout + 3))
  started=$(date +%s)
  set -m
  (
    export MAESTRO_COMPANION_TIMEOUT_SEC="$timeout"
    export MAESTRO_TEST_STATUS_HANG=6
    companion_verify_pin "$FIXTURE" task-bounded0-aaaaaa gpt-5.6-sol high
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  wait_for_pid "$pid" 12
  elapsed=$(( $(date +%s) - started ))
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "status exceeded 12s outer bound"; return 1; }
  [ "$elapsed" -le "$limit" ] ||
    { echo "status took ${elapsed}s with ${timeout}s companion timeout"; return 1; }
  [ "$WAIT_RC" -eq 4 ] ||
    { echo "rc=$WAIT_RC want 4 from the existing pin-verification failure"; return 1; }
  grep -q "MAESTRO_COMPANION: timed out after ${timeout}s" "$output" ||
    { echo "timeout progress missing: $(tr '\n' ' ' < "$output")"; return 1; }
}

t2_timeout_reaps_process_group() {
  local output="$TEST_ROOT/reap.out" child_file="$TEST_ROOT/child.pid"
  local child rc elapsed=0
  run_bounded 1 TEST_REAP bash -c \
    'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait "$child"' \
    _ "$child_file" > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 125 ] || { echo "rc=$rc want 125"; return 1; }
  [ -s "$child_file" ] || { echo "wrapped child pid missing"; return 1; }
  child=$(sed -n '1p' "$child_file")
  while kill -0 "$child" 2>/dev/null && [ "$elapsed" -lt 3 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "wrapped child $child survived timeout"
    return 1
  fi
}

t3_run_bounded_returns_wrapped_rc() {
  local output rc
  output=$(run_bounded 2 TEST_RC bash -c 'printf "discarded\n"; exit 37')
  rc=$?
  [ "$rc" -eq 37 ] || { echo "rc=$rc want 37"; return 1; }
  [ -z "$output" ] || { echo "failed command stdout leaked: $output"; return 1; }
  output=$(run_bounded 2 TEST_STDOUT printf 'bounded-ok\n')
  rc=$?
  [ "$rc" -eq 0 ] || { echo "success rc=$rc want 0"; return 1; }
  [ "$output" = "bounded-ok" ] || { echo "stdout=$output"; return 1; }
}

t4_invalid_companion_timeout_falls_back() {
  local output rc
  output=$(MAESTRO_COMPANION_TIMEOUT_SEC=bogus \
    companion_call "$FIXTURE" result task-bounded0-aaaaaa 3>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  case "$output" in
    *MAESTRO_COMPANION*bogus*120s*) ;;
    *) echo "fallback progress missing: $output"; return 1 ;;
  esac
  case "$output" in
    *"RESULT: DONE"*) ;;
    *) echo "companion output missing: $output"; return 1 ;;
  esac
}

t5_repo_digest_survives_refactor() {
  local output rc
  output=$(cd "$ROOT" && MAESTRO_DIGEST_TIMEOUT_SEC=120 repo_digest_bounded)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  case "$output" in
    tree-v2:*) ;;
    *) echo "digest=$output"; return 1 ;;
  esac
}

t6_poll_hanging_status_is_bounded() {
  local timeout=1 output="$TEST_ROOT/poll-hanging-status.out" pid
  # This check expects read-only rc=124; an inherited write lease would be poisoned by the fixture job id.
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
  set -m
  (
    export MAESTRO_COMPANION_TIMEOUT_SEC="$timeout"
    export MAESTRO_TEST_STATUS_HANG=4
    companion_poll "$FIXTURE" task-bounded0-aaaaaa 60 1
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  wait_for_pid "$pid" 18
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "poll exceeded 18s outer bound"; return 1; }
  [ "$WAIT_RC" -eq 124 ] ||
    { echo "rc=$WAIT_RC want 124 from read-only status-loss cancellation"; return 1; }
  grep -q "MAESTRO_COMPANION: timed out after ${timeout}s" "$output" ||
    { echo "timeout progress missing: $(tr '\n' ' ' < "$output")"; return 1; }
}

t7_fast_status_has_no_one_second_floor() {
  local started finished elapsed i
  unset MAESTRO_TEST_STATUS_HANG
  started=$(milliseconds_now) || return 1
  for i in 1 2 3 4 5; do
    companion_call "$FIXTURE" status task-bounded0-aaaaaa --json >/dev/null ||
      { echo "status call $i failed"; return 1; }
  done
  finished=$(milliseconds_now) || return 1
  elapsed=$((finished - started))
  printf 'MEASURE 5 fast status calls: %sms\n' "$elapsed" >&3
  [ "$elapsed" -lt 2000 ] ||
    { echo "5 status calls took ${elapsed}ms want under 2000ms"; return 1; }
}

t8_t6_scrubs_an_inherited_lease() {
  local lease="$TEST_ROOT/injected-lease" output="$TEST_ROOT/t6-inherited.out" rc
  mkdir "$lease" || return 1
  cat > "$lease/metadata" <<'EOF' || return 1
token=faketoken
pid=1
process_start=x
job_id=fakejob
session_id=fakesess
started_at=2026-01-01T00:00:00Z
started_epoch=1767225600
digest_before=unavailable
EOF
  export MAESTRO_LOCK_ACQUIRED=1
  export MAESTRO_LOCK_TOKEN=faketoken
  export MAESTRO_LOCK_DIR="$lease"
  t6_poll_hanging_status_is_bounded > "$output" 2>&1
  rc=$?
  unset MAESTRO_LOCK_ACQUIRED MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR
  [ "$rc" -eq 0 ] || { cat "$output"; return 1; }
  ! grep -q '^quiescence=unconfirmed$' "$lease/metadata" ||
    { echo "injected lease was poisoned"; return 1; }
}

t9_failed_start_cannot_publish_a_task_id() (
  local output rc
  companion_pin() { printf 'gpt-5.6-sol\thigh\thigh\n'; }
  companion_call() {
    printf 'transport failed after allocating task-phantom0-aaaaaa\n'
    return 9
  }
  output=$(companion_start "$FIXTURE" objective)
  rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc want 3, output=${output:-empty}"; return 1; }
  [ -z "$output" ] || { echo "failed launch published task id: $output"; return 1; }
)

t10_dispatch_budget_resolution() (
  local output rc
  unset MAESTRO_MAX_DISPATCH_SEC
  [ "$(companion_dispatch_budget write)" = 2400 ] ||
    { echo "unset write budget is not 2400"; return 1; }
  [ "$(companion_dispatch_budget read)" = 1200 ] ||
    { echo "unset read budget is not 1200"; return 1; }
  [ "$(MAESTRO_MAX_DISPATCH_SEC=7 companion_dispatch_budget write)" = 7 ] ||
    { echo "explicit write budget was changed"; return 1; }
  output=$(MAESTRO_MAX_DISPATCH_SEC=bogus companion_dispatch_budget write 3>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "invalid budget rc=$rc"; return 1; }
  case "$output" in
    *MAESTRO_POLL*bogus*1200s*1200) ;;
    *) echo "invalid budget fallback/warning missing: $output"; return 1 ;;
  esac
)

t11_idle_uses_elapsed_time_not_poll_count() (
  local log="$TEST_ROOT/slow-status.log" reason="$TEST_ROOT/slow-status.reason"
  local started elapsed rc
  : > "$log"
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
  companion_call() {
    sleep 2
    printf '{"status":"running","logFile":"%s"}\n' "$log"
  }
  companion_cancel_job() {
    printf '%s\n' "$3" > "$reason"
    return 124
  }
  started=$SECONDS
  companion_poll "$FIXTURE" task-slowstatus-aaaaaa 2 1 >/dev/null 2>&1
  rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || { echo "rc=$rc want 124"; return 1; }
  [ "$(cat "$reason")" = idle ] || { echo "cancel reason=$(cat "$reason") want idle"; return 1; }
  [ "$elapsed" -le 7 ] || { echo "idle cancellation took ${elapsed}s; configured idle wall time was 2s"; return 1; }
)

t12_status_call_is_clipped_to_hard_dispatch_budget() (
  local output="$TEST_ROOT/hard-status-bound.out" calls="$TEST_ROOT/hard-status-calls.log"
  local started elapsed rc
  : > "$calls"
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
  started=$SECONDS
  MAESTRO_TEST_CALL_LOG="$calls" \
    MAESTRO_TEST_STATUS_HANG=4 \
    MAESTRO_COMPANION_TIMEOUT_SEC=5 \
    MAESTRO_MAX_DISPATCH_SEC=2 \
    companion_poll "$FIXTURE" task-hardbound-aaaaaa 60 1 > "$output" 2>&1 3>&1
  rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || { echo "rc=$rc want read-only deadline 124"; return 1; }
  [ "$elapsed" -le 4 ] || { echo "elapsed=${elapsed}s exceeded the 2s hard budget by an unbounded status call"; return 1; }
  grep -q '^cancel task-hardbound-aaaaaa$' "$calls" || { echo "deadline did not cancel the job"; return 1; }
  grep -q 'reason=deadline' "$output" || { echo "hard bound was not classified as deadline"; return 1; }
)

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then
    ok "$label"
  else
    bad "$label" "${detail:-no detail}"
  fi
}

printf '=== Bounded companion calls verification ===\n'
check t1_hanging_status_is_bounded "hanging status honors the companion timeout"
check t2_timeout_reaps_process_group "timeout returns 125 and reaps the process group"
check t3_run_bounded_returns_wrapped_rc "bounded runner preserves stdout and command rc"
check t4_invalid_companion_timeout_falls_back "invalid companion timeout falls back to 120s"
check t5_repo_digest_survives_refactor "bounded repository digest still returns tree-v2"
check t6_poll_hanging_status_is_bounded "poll loop bounds repeated hanging statuses"
check t7_fast_status_has_no_one_second_floor "five fast status calls finish under two seconds"
check t8_t6_scrubs_an_inherited_lease "t6 scrubs an inherited write lease"
check t9_failed_start_cannot_publish_a_task_id "failed start cannot publish a phantom task id"
check t10_dispatch_budget_resolution "dispatch budgets resolve by mode and preserve explicit values"
check t11_idle_uses_elapsed_time_not_poll_count "idle timeout uses elapsed wall time, not configured poll counts"
check t12_status_call_is_clipped_to_hard_dispatch_budget "status calls cannot extend the hard dispatch budget by their full timeout"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
