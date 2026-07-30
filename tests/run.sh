#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

for suite in \
  gate.sh \
  preflight.sh \
  lease.sh \
  liveness.sh \
  shared-git-dir.sh \
  detection.sh \
  orphan-lifecycle.sh \
  commit-invariance.sh \
  manual-check-and-submodules.sh
do
  if bash "$TEST_DIR/$suite"; then
    printf 'PASS  %s\n' "$suite"
    PASS=$((PASS+1))
  else
    rc=$?
    printf 'FAIL  %s (rc=%d)\n' "$suite" "$rc"
    FAIL=$((FAIL+1))
  fi
done

printf 'SUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
