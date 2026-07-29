#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-companion.sh"
bash -n "$LIB" || { echo "VERIFY FAIL: syntax"; exit 1; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
git init -q "$D/repo" && (cd "$D/repo" && git commit -q --allow-empty -m init && git worktree add -q ../wt -b probe) 2>/dev/null
A=$(cd "$D/repo" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path")
B=$(cd "$D/wt"   && bash -c "set -uo pipefail; . '$LIB'; write_lock_path")
echo "main: $A"; echo "wt:   $B"
[ "$A" = "$B" ] || { echo "VERIFY FAIL: divergent lease paths across worktrees"; exit 1; }

# cross-worktree contention: holder alive in main checkout, acquirer in worktree must get 11
# Write the rc to a file and discard every other stream: progress_init re-points
# FD 3 at stdout inside this shell, so capturing stdout would swallow the operator
# line into $RC along with the exit code.
(cd "$D/repo" && bash -c "set -uo pipefail; . '$LIB'; progress_init; write_lock_acquire held
  cd '$D/wt'; unset MAESTRO_LOCK_TOKEN; write_lock_acquire; echo \$? > '$D/rc.txt'") >/dev/null 2>&1
RC=$(cat "$D/rc.txt" 2>/dev/null)
echo "cross-worktree acquire rc=$RC"
[ "$RC" = "11" ] || { echo "VERIFY FAIL: cross-worktree contention rc=$RC want 11"; exit 1; }

# non-git fallback unchanged
N=$(mktemp -d); F=$(cd "$N" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path"); rm -rf "$N"
case "$F" in */.maestro-write.lock) ;; *) echo "VERIFY FAIL: non-git fallback = $F"; exit 1;; esac

[ -f "$ROOT/tests/lease.sh" ] || { echo "VERIFY FAIL: missing $ROOT/tests/lease.sh"; exit 1; }
bash "$ROOT/tests/lease.sh" 2>&1 | tail -1 | grep -q '13 passed, 0 failed' || { echo "VERIFY FAIL: lease suite regressed"; exit 1; }
echo "VERIFY PASS: shared lease path, cross-worktree contention=11, fallback intact, 13/13 lease suite"
