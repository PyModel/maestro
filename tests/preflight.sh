#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../hooks/lib-companion.sh"
D=$(mktemp -d)

pass() {
  printf 'PASS %s: %s\n' "$1" "$2"
}

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  exit 1
}

REAL_NODE=$(node -p 'process.execPath')
[ -n "$REAL_NODE" ] && [ -x "$REAL_NODE" ] ||
  fail 0 "cannot resolve a real node binary"
mkdir -p "$D/shim"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exec "%s" "$@"\n' "$REAL_NODE"
} > "$D/shim/node"
chmod +x "$D/shim/node"
export PATH="$D/shim:$PATH"
mkdir -p "$D/home/.codex"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$D/home/.codex/config.toml"
printf 'high\n' > "$D/home/.codex/maestro-impl-effort"
export HOME="$D/home"
LOG="$D/argv.log"
ERR="$D/stderr.log"
trap 'rm -rf "$D"' EXIT

. "$LIB"

companion_pin >/dev/null 2>&1 ||
  fail 0 "no Codex pin; cannot exercise preflight"

cat > "$D/stub.cjs" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");

const args = process.argv.slice(2);
fs.appendFileSync(process.env.PREFLIGHT_LOG, `${args.join(" ")}\n`);

if (args[0] === "--help") {
  switch (path.basename(__filename, ".cjs")) {
    case "drifted":
      console.log("Usage:\n  node x task [--background] [--model <m>] [--effort <none|minimal|low|medium|high|xhigh>] [prompt]");
      break;
    case "capable":
      console.log("Usage:\n  node x task [--background] [--write] [--model <m>] [--effort <none|minimal|low|medium|high|xhigh>] [prompt]");
      break;
    case "misleading":
      console.log("Usage:\n  node x task [--background] [--model <m>] [prompt]\n  node x review [--write] [prompt]");
      break;
    case "silent":
      break;
    case "erroring":
      console.error("error: unknown option '--help'");
      process.exitCode = 1;
      break;
  }
} else if (args[0] === "task") {
  console.log("started task-fake-abc123");
}
EOF

for stub in drifted capable misleading silent erroring; do
  cp "$D/stub.cjs" "$D/$stub.cjs"
done

export PREFLIGHT_LOG="$LOG"

run_start() {
  local stub=$1
  local mode=${2:-read}
  : > "$LOG"
  : > "$ERR"
  if [ "$mode" = "write" ]; then
    mkdir -p "$D/lease"
    printf 'token=preflight-token\npid=%s\nprocess_start=unavailable\njob_id=unknown\nsession_id=preflight\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' \
      "$$" > "$D/lease/metadata"
    export MAESTRO_LOCK_ACQUIRED=1 MAESTRO_LOCK_TOKEN=preflight-token MAESTRO_LOCK_DIR="$D/lease"
    if OUTPUT=$(companion_start "$D/$stub.cjs" "hello" write 2>"$ERR"); then
      RC=0
    else
      RC=$?
    fi
  else
    if OUTPUT=$(companion_start "$D/$stub.cjs" "hello" 2>"$ERR"); then
      RC=0
    else
      RC=$?
    fi
  fi
}

run_start drifted write
[ "$RC" -eq 3 ] ||
  fail 1 "drifted write returned rc=$RC, want 3; output: $OUTPUT"
grep -qi 'flag drift' "$ERR" ||
  fail 1 "drifted write did not report flag drift; stderr: $(cat "$ERR")"
grep -q '^task\( \|$\)' "$LOG" &&
  fail 1 "drifted write attempted a task dispatch"
pass 1 "conclusive flag drift refuses write dispatch"

run_start misleading write
[ "$RC" -eq 3 ] ||
  fail 1b "unrelated --write returned rc=$RC, want 3; output: $OUTPUT"
grep -qi 'flag drift' "$ERR" ||
  fail 1b "unrelated --write did not report task flag drift; stderr: $(cat "$ERR")"
grep -q '^task\( \|$\)' "$LOG" &&
  fail 1b "--write from another subcommand authorized a task dispatch"
pass 1b "--write on another subcommand does not authorize task"

run_start capable write
[ "$RC" -eq 0 ] ||
  fail 2 "capable write returned rc=$RC, want 0; stderr: $(cat "$ERR")"
[ "$OUTPUT" = "task-fake-abc123" ] ||
  fail 2 "capable write returned unexpected job id: $OUTPUT"
grep -q '^task .*--write' "$LOG" ||
  fail 2 "capable write task invocation omitted --write"
grep -q '^task .*--effort high' "$LOG" ||
  fail 2 "write task invocation omitted the explicit implementation effort"
pass 2 "advertised --write dispatches with explicit implementation effort"

run_start silent write
[ "$RC" -eq 0 ] ||
  fail 3 "silent help blocked write dispatch with rc=$RC; stderr: $(cat "$ERR")"
grep -q '^task\( \|$\)' "$LOG" ||
  fail 3 "silent help did not proceed to task dispatch"
pass 3 "silent help is inconclusive and does not block"

run_start erroring write
[ "$RC" -eq 0 ] ||
  fail 4 "erroring help blocked write dispatch with rc=$RC; stderr: $(cat "$ERR")"
grep -q '^task\( \|$\)' "$LOG" ||
  fail 4 "erroring help did not proceed to task dispatch"
pass 4 "erroring help is inconclusive and does not block"

run_start drifted
[ "$RC" -eq 0 ] ||
  fail 5 "read-only dispatch returned rc=$RC; stderr: $(cat "$ERR")"
grep -q '^--help\( \|$\)' "$LOG" &&
  fail 5 "read-only dispatch paid for a help probe"
grep -q '^task\( \|$\)' "$LOG" ||
  fail 5 "read-only invocation did not dispatch a task"
grep -q -- '--write' "$LOG" &&
  fail 5 "read-only task invocation included --write"
grep -q '^task .*--effort high' "$LOG" ||
  fail 5 "read-only invocation omitted the explicit debate effort"
pass 5 "read-only dispatch skips the compatibility probe and pins debate effort"

CACHE="$HOME/.claude/plugins/cache/openai-codex/codex"
mkdir -p "$CACHE/1.0.2/scripts" "$CACHE/1.0.10/scripts"
: > "$CACHE/1.0.2/scripts/codex-companion.mjs"
: > "$CACHE/1.0.10/scripts/codex-companion.mjs"
sleep 1
touch "$CACHE/1.0.2/scripts/codex-companion.mjs"
RESOLVED=$(companion_resolve)
[ "$RESOLVED" = "$CACHE/1.0.10/scripts/codex-companion.mjs" ] ||
  fail 6 "resolved $RESOLVED, want highest semantic version 1.0.10"
pass 6 "runtime companion resolution ignores cache mtime and selects highest semantic version"

echo "VERIFY PASS: task-scoped write preflight, inconclusive help allowed, read-only probe skipped, highest companion version selected"
exit 0
