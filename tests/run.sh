#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

SUITE_TIMEOUT="${MAESTRO_SUITE_TIMEOUT_SEC-600}"
suite_timeout_invalid=0
case "$SUITE_TIMEOUT" in
  ''|*[!0-9]*) suite_timeout_invalid=1 ;;
  *) [ "$SUITE_TIMEOUT" -ge 1 ] 2>/dev/null || suite_timeout_invalid=1 ;;
esac
if [ "$suite_timeout_invalid" -eq 1 ]; then
  printf 'MAESTRO_TEST: ignoring invalid MAESTRO_SUITE_TIMEOUT_SEC=%s; using 600s\n' "$SUITE_TIMEOUT"
  SUITE_TIMEOUT=600
fi

if [ "$#" -gt 0 ]; then
  suites="$*"
else
  suites="gate.sh
preflight.sh
lease.sh
liveness.sh
shared-git-dir.sh
detection.sh
orphan-lifecycle.sh
commit-invariance.sh
manual-check-and-submodules.sh"
fi

for suite in $suites; do
  set -m
  bash "$TEST_DIR/$suite" &
  pid=$!
  set +m
  elapsed=0
  timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$SUITE_TIMEOUT" ]; then
      timed_out=1
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
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
  [ "$timed_out" -eq 0 ] || rc=124

  if [ "$timed_out" -eq 1 ]; then
    printf 'TIMEOUT  %s (rc=124)\n' "$suite"
    FAIL=$((FAIL+1))
  elif [ "$rc" -eq 0 ]; then
    printf 'PASS  %s\n' "$suite"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %s (rc=%d)\n' "$suite" "$rc"
    FAIL=$((FAIL+1))
  fi
done

printf 'SUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
