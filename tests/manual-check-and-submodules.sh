#!/usr/bin/env bash
# Two regressions introduced alongside the materialized-tree digest.
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/lib-companion.sh"
D=$(mktemp -d /tmp/planr.XXXXXX); trap 'rm -rf "$D"' EXIT

echo "== 1. the manual operator check always says something =="
git init -q "$D/r"; ( cd "$D/r" && git config user.email p@p && git config user.name p \
  && printf 'a\n' > s.sh && git add -A && git commit -q -m init )
printf '2026-01-01T00:00:00Z type=dispatch job=old before=aaa after=bbb\n' \
  > "$D/r/.git/maestro-provenance.log"
OUT=$( cd "$D/r" && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; provenance_check" 2>&1 )
[ -n "$OUT" ] || { echo "FAIL(1a): manual check printed nothing for an unrecognised baseline"; exit 1; }
echo "$OUT" | grep -q '^PROVENANCE: ' || { echo "FAIL(1b): output is not a PROVENANCE line: [$OUT]"; exit 1; }
echo "$OUT" | grep -qi 'not observed\|unavailable' \
  || { echo "FAIL(1c): does not say the comparison could not be made: [$OUT]"; exit 1; }
echo "$OUT" | grep -q 'BASELINE GAP' && { echo "FAIL(1d): reported a gap it cannot know about"; exit 1; }
echo "   ok — [$OUT]"

echo "== 2. submodule working-tree content is observed, and stays commit-invariant =="
git init -q "$D/dep"; ( cd "$D/dep" && git config user.email p@p && git config user.name p \
  && printf 'v1\n' > f.txt && git add -A && git commit -q -m v1 \
  && printf 'v2\n' > f.txt && git add -A && git commit -q -m v2 )
git init -q "$D/s"; cd "$D/s"; git config user.email p@p; git config user.name p
printf 'a\n' > s.sh; git add -A; git commit -q -m init
git -c protocol.file.allow=always submodule add -q "$D/dep" dep 2>/dev/null || {
  echo "SKIP(2): this git refuses local submodules"; echo "VERIFY PASS (case 2 skipped)"; exit 0; }
git add -A; git commit -q -m addsub
d() { ( cd "$D/s" && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; repo_digest" ) 2>/dev/null; }

B=$(d)
[ "$(d)" = "$B" ] || { echo "FAIL(2a): digest unstable with a submodule present"; exit 1; }
( cd "$D/s/dep" && git checkout -q HEAD~1 )                 # pointer bump = content change
[ "$(d)" != "$B" ] || { echo "FAIL(2b): a submodule pointer bump was invisible"; exit 1; }
( cd "$D/s/dep" && git checkout -q - 2>/dev/null )
[ "$(d)" = "$B" ] || { echo "FAIL(2c): restoring the submodule did not restore the digest"; exit 1; }
printf 'DIRTY IN SUBMODULE\n' > "$D/s/dep/f.txt"
[ "$(d)" != "$B" ] || { echo "FAIL(2d): a dirty submodule working tree was invisible"; exit 1; }
( cd "$D/s/dep" && git add -A && git commit -q -m 'commit inside the submodule' )
C=$(d)
( cd "$D/s/dep" && git commit -q --allow-empty -m 'another commit, same content' )
[ "$(d)" = "$C" ] || { echo "FAIL(2e): committing inside a submodule changed the digest"; exit 1; }
echo "   ok"

echo "== 3. a failed enumeration degrades even without caller pipefail =="
REALGIT=$(PATH=/usr/bin:/bin:/usr/local/bin command -v git)
SHIM=$D/shim; mkdir -p "$SHIM"
cat > "$SHIM/git" <<SH
#!/bin/sh
for a in "\$@"; do [ "\$a" = submodule ] && exit 1; done
exec "$REALGIT" "\$@"
SH
chmod +x "$SHIM/git"
# deliberately NO pipefail: provenance_check is documented as an operator-facing
# manual command, and an interactive shell does not set it.
OUT=$( cd "$D/s" && PATH="$SHIM:$PATH" bash -c "exec 3>&-; . '$LIB'; repo_digest" 2>/dev/null ); RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL(3a): partial digest reported as authoritative (rc=0, out=[$OUT])"; exit 1; }
[ -z "$OUT" ] || { echo "FAIL(3b): printed a digest despite failing enumeration: [$OUT]"; exit 1; }
echo "   ok"

echo "VERIFY PASS: manual check always speaks, submodule content observed and commit-invariant, enumeration failure degrades without pipefail"
