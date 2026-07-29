#!/usr/bin/env bash
# BLACK-BOX gate: exercises the WIRING, not the function.
# Calling provenance functions directly is expressly insufficient — that is the
# hole that let the tautological-clean defect ship.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/hooks/implementer-loop.sh"
LIB="$ROOT/hooks/lib-companion.sh"
bash -n "$LIB" || { echo "VERIFY FAIL: syntax lib"; exit 1; }
bash -n "$LOOP" || { echo "VERIFY FAIL: syntax loop"; exit 1; }

D=$(mktemp -d /tmp/planN.XXXXXX); trap 'rm -rf "$D"' EXIT
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
[ -f "$FIXTURE" ] || { echo "VERIFY FAIL: missing fixture $FIXTURE"; exit 1; }
# Resolve the real node BEFORE PATH is shimmed, and embed the absolute path:
# the shim is itself named `node`, so calling `node` from inside it would recurse.
REAL_NODE=$(node -p 'process.execPath')
mkdir -p "$D/shim"
cat > "$D/shim/node" <<EOF
#!/usr/bin/env bash
# lib-companion invokes: node <resolved-companion-path> <subcommand> …
# Drop the resolved path and run the fixture in its place.
shift
exec "$REAL_NODE" "$FIXTURE" "\$@"
EOF
chmod +x "$D/shim/node"
export PATH="$D/shim:$PATH"
export MAESTRO_TEST_RESULT="RESULT: DONE"
printf '{\n  "running": [],\n  "latestFinished": null\n}\n' > "$D/status.json"
export MAESTRO_TEST_STATUS="$D/status.json"
printf 'Objective: noop\n' > "$D/plan.md"

mkrepo() {
  rm -rf "$1"; git init -q "$1"
  ( cd "$1" && git config user.email p@p && git config user.name p \
    && printf '#!/usr/bin/env bash\necho ok\n' > s.sh \
    && printf 'ORIGINAL untracked\n' > u.sh \
    && git add s.sh && git commit -q -m init )
}
dispatch() { ( cd "$1" && bash "$LOOP" --plan "$D/plan.md" --verify true --max-iters 1 ) 2>&1; }

# ---- 1. tracked mutation between two dispatches is reported at the SECOND acquisition
mkrepo "$D/r1"
O1=$(dispatch "$D/r1")
printf 'MUTATED BY ORCHESTRATOR\n' > "$D/r1/s.sh"
O2=$(dispatch "$D/r1")
echo "$O2" | grep -q 'BASELINE GAP' || { echo "VERIFY FAIL(1): no BASELINE GAP after tracked mutation"; echo "$O2" | grep -E '^PROVENANCE:|^MAESTRO_FINAL'; exit 1; }

# the gap must be reported BEFORE the companion starts its second job
GAPLINE=$(echo "$O2" | grep -n 'BASELINE GAP' | head -1 | cut -d: -f1)
STARTLINE=$(echo "$O2" | grep -n 'WATCHDOG: started' | head -1 | cut -d: -f1)
[ -n "$GAPLINE" ] && [ -n "$STARTLINE" ] && [ "$GAPLINE" -lt "$STARTLINE" ] \
  || { echo "VERIFY FAIL(1b): gap not reported before dispatch (gap=$GAPLINE start=$STARTLINE)"; exit 1; }

# ---- 2. no tautological clean line anywhere
if echo "$O1$O2" | grep -q 'clean — tree matches the last dispatch'; then
  echo "VERIFY FAIL(2): tautological clean line still emitted"; exit 1
fi

# ---- 3. untracked-file CONTENT mutation is detected (was invisible)
mkrepo "$D/r3"
dispatch "$D/r3" >/dev/null
printf 'COMPLETELY DIFFERENT untracked payload\n' > "$D/r3/u.sh"
O3=$(dispatch "$D/r3")
echo "$O3" | grep -q 'BASELINE GAP' || { echo "VERIFY FAIL(3): untracked content mutation not detected"; exit 1; }

# ---- 4. NO false gap when nothing changed between dispatches
mkrepo "$D/r4"
dispatch "$D/r4" >/dev/null
O4=$(dispatch "$D/r4")
echo "$O4" | grep -q 'BASELINE GAP' && { echo "VERIFY FAIL(4): false gap on an untouched tree"; exit 1; }

# ---- 5. ignored files stay out of observation scope (documented limit, must NOT gap)
mkrepo "$D/r5"
( cd "$D/r5" && printf 'out.log\n' > .gitignore && git add .gitignore && git commit -q -m ign && printf 'a\n' > out.log )
dispatch "$D/r5" >/dev/null
printf 'completely different ignored content\n' > "$D/r5/out.log"
O5=$(dispatch "$D/r5")
echo "$O5" | grep -q 'BASELINE GAP' && { echo "VERIFY FAIL(5): ignored file caused a gap"; exit 1; }

# ---- 6. sentinel still last, state/rc unchanged by the diagnostic
for O in "$O2" "$O3" "$O4"; do
  LAST=$(echo "$O" | grep -E '^MAESTRO_FINAL:' | tail -1)
  echo "$LAST" | grep -q 'LOOP VERIFIED_DONE rc=0' || { echo "VERIFY FAIL(6): state changed: $LAST"; exit 1; }
  TRAIL=$(echo "$O" | awk '/^MAESTRO_FINAL:/{n=NR} END{print NR-n}')
  [ "$TRAIL" = "0" ] || { echo "VERIFY FAIL(6): $TRAIL lines after sentinel"; exit 1; }
done

# ---- 7. regressions
bash "$ROOT/tests/lease.sh" 2>&1 | tail -1 | grep -q '13 passed, 0 failed' || { echo "VERIFY FAIL(7): lease suite"; exit 1; }
bash "$ROOT/tests/shared-git-dir.sh" 2>&1 | tail -1 | grep -q 'VERIFY PASS' || { echo "VERIFY FAIL(7): planJ"; exit 1; }

echo "VERIFY PASS: gap detected at acquisition (tracked + untracked content), reported before dispatch, no tautological clean, no false gap, ignored out of scope, sentinel intact"
