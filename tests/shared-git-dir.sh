#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-write-lease.sh"
bash -n "$LIB" || { echo "VERIFY FAIL: syntax"; exit 1; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export MAESTRO_LOCK_WAIT_SEC=0
git init -q "$D/repo" && (
  cd "$D/repo" || exit 1
  git config user.email p@p
  git config user.name p
  git commit -q --allow-empty -m init
  git worktree add -q ../wt -b probe
) 2>/dev/null
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

# superproject/submodule overlap: the outer repository can edit submodule bytes,
# so both entry points must share one ownership domain.
git init -q "$D/dep"
(
  cd "$D/dep" || exit 1
  git config user.email p@p
  git config user.name p
  printf 'dep\n' > dep.txt
  git add dep.txt
  git commit -q -m init
)
git init -q "$D/super"
(
  cd "$D/super" || exit 1
  git config user.email p@p
  git config user.name p
  printf 'super\n' > super.txt
  git add super.txt
  git commit -q -m init
  git -c protocol.file.allow=always submodule add -q "$D/dep" dep
  git commit -q -am submodule
)
SUPER=$(cd "$D/super" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path")
SUB=$(cd "$D/super/dep" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path")
echo "super: $SUPER"; echo "sub:   $SUB"
[ "$SUPER" = "$SUB" ] || { echo "VERIFY FAIL: superproject/submodule lease paths differ"; exit 1; }
(cd "$D/super" && bash -c "set -uo pipefail; . '$LIB'; progress_init; write_lock_acquire held
  cd '$D/super/dep'; unset MAESTRO_LOCK_TOKEN; write_lock_acquire; echo \$? > '$D/sub-rc.txt'") >/dev/null 2>&1
SUB_RC=$(cat "$D/sub-rc.txt" 2>/dev/null)
[ "$SUB_RC" = 11 ] || { echo "VERIFY FAIL: submodule overlap contention rc=$SUB_RC want 11"; exit 1; }

# non-git fallback unchanged
N=$(mktemp -d); F=$(cd "$N" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path"); rm -rf "$N"
case "$F" in */.maestro-write.lock) ;; *) echo "VERIFY FAIL: non-git fallback = $F"; exit 1;; esac

[ -f "$ROOT/tests/lease.sh" ] || { echo "VERIFY FAIL: missing $ROOT/tests/lease.sh"; exit 1; }
bash "$ROOT/tests/lease.sh" 2>&1 | tail -1 | grep -qE '[1-9][0-9]* passed, 0 failed' || { echo "VERIFY FAIL: lease suite regressed"; exit 1; }
echo "VERIFY PASS: shared worktree/submodule lease path, contention=11, fallback intact, lease suite green"
