#!/usr/bin/env bash
# The detector must be silent on the workflow it exists to support, still catch
# unattributed writes, and migrate without manufacturing a gap.
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/lib-companion.sh"
D=$(mktemp -d /tmp/commitinv.XXXXXX); trap 'rm -rf "$D"' EXIT

mk() { git init -q "$1"; ( cd "$1" && git config user.email p@p && git config user.name p \
  && printf 'a\n' > s.sh && git add -A && git commit -q -m init ); }
run() { local r=$1; shift; ( cd "$r" && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; progress_init; $*" ) 2>&1; }
gaps() { echo "$1" | grep -c 'BASELINE GAP'; }

echo "== 1. the prescribed loop (dispatch -> review -> commit -> dispatch) is silent =="
mk "$D/w"
run "$D/w" "write_lock_acquire job-one >/dev/null
  printf 'CODEX EDIT\n' > '$D/w/s.sh'
  write_lock_release" >/dev/null
( cd "$D/w" && git add -A && git commit -q -m 'fix: what codex wrote' )
O1=$(run "$D/w" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire job-two')
[ "$(gaps "$O1")" -eq 0 ] || { echo "FAIL(1): committing codex's own bytes reported as an unattributed gap"
  echo "   $(echo "$O1" | grep 'BASELINE GAP' | cut -c1-150)"; exit 1; }
echo "   ok"

echo "== 2. an unattributed shell write between leases is still caught =="
mk "$D/x"
run "$D/x" 'write_lock_acquire job-one >/dev/null; write_lock_release' >/dev/null
printf 'WROTE VIA REDIRECT, NO LEASE HELD\n' > "$D/x/s.sh"     # the gate does not match Bash
O2=$(run "$D/x" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire job-two')
[ "$(gaps "$O2")" -eq 1 ] || { echo "FAIL(2): unattributed redirect not reported (gaps=$(gaps "$O2"))"; exit 1; }
echo "   ok"

echo "== 3. migration: an unrecognised baseline is no observation, never unequal =="
mk "$D/m"
LOG="$D/m/.git/maestro-provenance.log"
printf '2026-01-01T00:00:00Z type=dispatch job=old-job before=%s after=%s\n' \
  "$(printf 0%.0s $(seq 40))" "$(printf b%.0s $(seq 40))" > "$LOG"
O3=$(run "$D/m" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire job-one >/dev/null; write_lock_release')
[ "$(gaps "$O3")" -eq 0 ] || { echo "FAIL(3a): old bare record compared as unequal instead of no-observation"; exit 1; }
grep -q 'after=tree-v2:' "$LOG" || { echo "FAIL(3b): no self-describing v2 baseline written"
  echo "   log: $(tail -1 "$LOG")"; exit 1; }
O4=$(run "$D/m" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire job-two >/dev/null; write_lock_release')
[ "$(gaps "$O4")" -eq 0 ] || { echo "FAIL(3c): gap on an unchanged tree once a v2 baseline exists"; exit 1; }
printf 'a\nb\n' > "$D/m/s.sh"
O5=$(run "$D/m" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire job-three')
[ "$(gaps "$O5")" -eq 1 ] || { echo "FAIL(3d): expected exactly one gap after a one-byte mutation, got $(gaps "$O5")"; exit 1; }
echo "   ok"

echo "== 4. the digest tracks materialized content, not refs =="
mk "$D/d"
d() { ( cd "$D/d" && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; repo_digest" ) 2>/dev/null; }
B=$(d); [ "$(d)" = "$B" ] || { echo "FAIL(4a): digest unstable on an unchanged tree"; exit 1; }
case "$B" in tree-v2:*) ;; *) echo "FAIL(4b): digest is not self-describing: $B"; exit 1 ;; esac
( cd "$D/d" && git add -A && git commit -q --allow-empty -m empty )
[ "$(d)" = "$B" ] || { echo "FAIL(4c): a commit changed the digest"; exit 1; }
chmod +x "$D/d/s.sh"
[ "$(d)" != "$B" ] || { echo "FAIL(4d): an executable-bit change was invisible"; exit 1; }
chmod -x "$D/d/s.sh"
rm "$D/d/s.sh"
[ "$(d)" != "$B" ] || { echo "FAIL(4e): deleting a tracked file was invisible"; exit 1; }
echo "   ok"

echo "VERIFY PASS: commit-invariant, redirect still caught, migration is no-observation, content surface correct"
