#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-write-lease.sh"
JOB_LIB="$ROOT/hooks/lib-job-lock.sh"
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
[ "$A" != "$B" ] || { echo "VERIFY FAIL: linked worktrees share a write lease path"; exit 1; }

# Linked worktrees have separate materialized trees, indexes, and branches. Their
# write leases must therefore be independent so separate terminals can run in parallel.
# Write the rc to a file and discard every other stream: progress_init re-points
# FD 3 at stdout inside this shell, so capturing stdout would swallow the operator
# line into $RC along with the exit code.
(cd "$D/repo" && bash -c "set -uo pipefail; . '$LIB'; progress_init; write_lock_acquire held
  cd '$D/wt'; unset MAESTRO_LOCK_TOKEN; write_lock_acquire; echo \$? > '$D/rc.txt'") >/dev/null 2>&1
RC=$(cat "$D/rc.txt" 2>/dev/null)
echo "cross-worktree acquire rc=$RC"
[ "$RC" = "0" ] || { echo "VERIFY FAIL: isolated worktree acquire rc=$RC want 0"; exit 1; }

# Companion job supervision is isolated at the same boundary. A read/debate or
# Write turn in one task worktree must not block a different task worktree.
JA=$(cd "$D/repo" && bash -c "set -uo pipefail; . '$JOB_LIB'; job_lock_path")
JB=$(cd "$D/wt"   && bash -c "set -uo pipefail; . '$JOB_LIB'; job_lock_path")
echo "main job lock: $JA"; echo "wt job lock:   $JB"
[ "$JA" != "$JB" ] || { echo "VERIFY FAIL: linked worktrees share a companion job lock"; exit 1; }
(cd "$D/repo" && bash -c "set -uo pipefail; . '$JOB_LIB'; progress_init() { :; }; job_lock_acquire write
  cd '$D/wt'; unset MAESTRO_JOB_LOCK_TOKEN; job_lock_acquire write; echo \$? > '$D/job-rc.txt'") >/dev/null 2>&1
JOB_RC=$(cat "$D/job-rc.txt" 2>/dev/null)
[ "$JOB_RC" = "0" ] || { echo "VERIFY FAIL: isolated worktree job-lock acquire rc=$JOB_RC want 0"; exit 1; }

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

SUPER_JOB=$(cd "$D/super" && bash -c 'set -uo pipefail; . "$1"; job_lock_path' _ "$JOB_LIB")
SUB_JOB=$(cd "$D/super/dep" && bash -c 'set -uo pipefail; . "$1"; job_lock_path' _ "$JOB_LIB")
echo "super job lock: $SUPER_JOB"; echo "sub job lock:   $SUB_JOB"
[ "$SUPER_JOB" = "$SUB_JOB" ] ||
  { echo "VERIFY FAIL: superproject/submodule job-lock paths differ"; exit 1; }
(cd "$D/super" && bash -c 'set -uo pipefail; . "$1"; progress_init() { :; }; job_lock_acquire write
  cd "$2"; unset MAESTRO_JOB_LOCK_TOKEN; export MAESTRO_LOCK_WAIT_SEC=0
  job_lock_acquire write; echo $? > "$3"' _ \
  "$JOB_LIB" "$D/super/dep" "$D/sub-job-rc.txt") >/dev/null 2>&1
SUB_JOB_RC=$(cat "$D/sub-job-rc.txt" 2>/dev/null)
[ "$SUB_JOB_RC" = 11 ] ||
  { echo "VERIFY FAIL: submodule job-lock contention rc=$SUB_JOB_RC want 11"; exit 1; }

# non-git fallback unchanged
N=$(mktemp -d); F=$(cd "$N" && bash -c "set -uo pipefail; . '$LIB'; write_lock_path"); rm -rf "$N"
case "$F" in */.maestro-write.lock) ;; *) echo "VERIFY FAIL: non-git fallback = $F"; exit 1;; esac

echo "VERIFY PASS: worktree-isolated write/job locks, shared submodule scope, fallback intact"
