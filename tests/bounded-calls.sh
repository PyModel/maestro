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
  [ "$WAIT_RC" -eq 6 ] ||
    { echo "rc=$WAIT_RC want 6 from four consecutive empty statuses"; return 1; }
  grep -q "MAESTRO_COMPANION: timed out after ${timeout}s" "$output" ||
    { echo "timeout progress missing: $(tr '\n' ' ' < "$output")"; return 1; }
}

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
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
