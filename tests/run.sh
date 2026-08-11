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

suite_descendants() { # root pid
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { pid[NR] = $1; parent[$1] = $2 }
    END {
      selected[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) {
          current = pid[i]
          if (!selected[current] && selected[parent[current]]) {
            selected[current] = 1
            changed = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) if (pid[i] != root && selected[pid[i]]) print pid[i]
    }
  '
}

terminate_suite_tree() { # process-group leader
  local root="$1" descendants descendant ticks=0 alive
  descendants=$(suite_descendants "$root")
  kill -TERM -"$root" 2>/dev/null || :
  for descendant in $descendants; do kill -TERM "$descendant" 2>/dev/null || :; done
  while [ "$ticks" -lt 50 ]; do
    alive=0
    kill -0 -"$root" 2>/dev/null && alive=1
    for descendant in $descendants; do
      kill -0 "$descendant" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
    ticks=$((ticks + 1))
  done
  kill -KILL -"$root" 2>/dev/null || :
  for descendant in $descendants; do kill -KILL "$descendant" 2>/dev/null || :; done
}

if [ "$#" -gt 0 ]; then
  suites="$*"
else
  suites="gate.sh
install.sh
model-selector.sh
preflight.sh
lease.sh
job-lock.sh
scout.sh
liveness.sh
stop-report.sh
bounded-calls.sh
runner-timeout.sh
shared-git-dir.sh
provenance-edge.sh
discussion.sh
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
    terminate_suite_tree "$pid"
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
