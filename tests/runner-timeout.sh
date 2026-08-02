#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/tests/run.sh"
TEST_ROOT=$(mktemp -d /tmp/maestro-runner-timeout.XXXXXXXX)
child=""
cleanup() {
  if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pid_file="$TEST_ROOT/nested.pid"
output="$TEST_ROOT/runner.out"
env MAESTRO_SUITE_TIMEOUT_SEC=1 \
  MAESTRO_TEST_NESTED_PID_FILE="$pid_file" \
  bash "$RUNNER" fixtures/nested-hang.sh > "$output" 2>&1
rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: timed-out fixture returned success"; exit 1; }
[ -s "$pid_file" ] || { echo "FAIL: nested child pid was not recorded"; exit 1; }
child=$(sed -n '1p' "$pid_file")
for _ in 1 2 3 4 5; do
  kill -0 "$child" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$child" 2>/dev/null; then
  echo "FAIL: nested process-group child $child survived suite timeout"
  exit 1
fi
grep -q 'TIMEOUT  fixtures/nested-hang.sh (rc=124)' "$output" || {
  echo "FAIL: runner did not report the timeout"
  exit 1
}
echo "VERIFY PASS: suite timeout reaps nested process groups"
