#!/usr/bin/env bash
# Orphan lifecycle gate — the sequence every provenance defect has lived in.
# dispatcher dies -> lease retained -> job writes -> job dies -> [window] -> later dispatch steals
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-write-lease.sh"
D=$(mktemp -d /tmp/orphan.XXXXXX); trap 'rm -rf "$D"' EXIT

REAL_NODE=$(node -p 'process.execPath')
mkdir -p "$D/shim"
{ printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_NODE"; } > "$D/shim/node"
chmod +x "$D/shim/node"
export PATH="$D/shim:$PATH"
COMPANION="$D/home/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
mkdir -p "$(dirname "$COMPANION")" "$D/home/.codex"
cp "$ROOT/tests/fixtures/fake-companion.mjs" "$COMPANION"
printf '{\n  "running": [],\n  "latestFinished": null\n}\n' > "$D/status.json"
export MAESTRO_TEST_STATUS="$D/status.json"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$D/home/.codex/config.toml"
printf 'high\n' > "$D/home/.codex/maestro-impl-effort"
export HOME="$D/home"

mk() { rm -rf "$1"; git init -q "$1"; ( cd "$1" && git config user.email p@p && git config user.name p \
  && printf 'a\n' > s.sh && git add -A && git commit -q -m init ); }
run() { ( cd "$1" && shift && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; progress_init; $*" ) 2>&1; }

# Shared prelude: baseline, then an orphaned job that writes inside its own lease
orphan_prelude() {
  run "$1" 'write_lock_acquire seed >/dev/null; write_lock_release >/dev/null'
  run "$1" "write_lock_workspace_writers() { return 4; }
    write_lock_acquire orphan-job >/dev/null
    printf 'ORPHAN IN-LEASE WRITE\n' > '$1/s.sh'
    write_lock_release" >/dev/null
}

echo "== A. orphan's own in-lease writes are NOT reported as a gap =="
mk "$D/a"; orphan_prelude "$D/a"
OA=$(run "$D/a" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire later-job')
echo "$OA" | grep -q 'BASELINE GAP' && { echo "FAIL(A): orphan's own writes blamed"; exit 1; }
echo "   ok"

echo "== B. an orchestrator mutation AFTER the orphan died must not be laundered =="
mk "$D/b"; orphan_prelude "$D/b"
# the orphan is now gone; this write belongs to nobody's lease
printf 'ORCHESTRATOR WROTE THIS AFTER THE ORPHAN DIED\n' > "$D/b/s.sh"
OB=$(run "$D/b" 'unset MAESTRO_LOCK_TOKEN; write_lock_acquire later-job')
if ! echo "$OB" | grep -qiE 'BASELINE GAP|unobserved'; then
  echo "FAIL(B): post-orphan orchestrator mutation silently absorbed into the orphan's record"
  echo "   output: $(echo "$OB" | tr '\n' ' ' | cut -c1-160)"
  exit 1
fi
echo "   ok"

echo "== C. the adopted interval is marked as unobserved in the audit trail =="
grep -q 'type=orphan-adopted\|unobserved' "$D/b/.git/maestro-provenance.log" 2>/dev/null \
  || { echo "FAIL(C): synthesized record claims a completed dispatch it never observed"
       echo "   log: $(tail -1 "$D/b/.git/maestro-provenance.log")"; exit 1; }
echo "   ok"

echo "VERIFY PASS: orphan lifecycle — own writes not blamed, post-orphan window not laundered, adoption marked unobserved"
