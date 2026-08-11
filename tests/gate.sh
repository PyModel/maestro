#!/usr/bin/env bash
set -uo pipefail
umask 077

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$TEST_DIR/../hooks/orchestrator-gate.mjs"
INJECT="$TEST_DIR/../hooks/orchestrator-inject.mjs"
NODE=$(node -p 'process.execPath')
SID="gatetest-$$"
FAKEHOME=$(mktemp -d)
FLAG_DIR="$FAKEHOME/.maestro/direct-edit"
FLAG="$FLAG_DIR/maestro-direct-${SID}.flag"
LEGACY_FLAG="/tmp/maestro-direct-${SID}.flag"
GATE_TMP="/tmp/maestro-gate-${SID}"
trap 'rm -f "$LEGACY_FLAG" /tmp/maestro-direct-default.flag; rm -rf "$FAKEHOME" "$GATE_TMP"' EXIT
mkdir -p "$FLAG_DIR"
chmod 700 "$FAKEHOME/.maestro" "$FLAG_DIR"

pass() {
  printf 'PASS %s: %s\n' "$1" "$2"
}

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  exit 1
}

gate_payload() {
  local file_path=$1
  local cwd=${2:-/work/repo}
  printf '{"session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' \
    "$SID" "$cwd" "$file_path"
}

check_gate() {
  local number=$1
  local label=$2
  local expected=$3
  local payload=$4
  local home=${5:-$FAKEHOME}
  local output rc

  if output=$(printf '%s' "$payload" | HOME="$home" "$NODE" "$GATE" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq "$expected" ] ||
    fail "$number" "$label returned rc=$rc, want $expected; output: $output"
}

inject_payload() {
  local prompt=$1
  local escaped=${prompt//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '{"session_id":"%s","prompt":"%s"}' "$SID" "$escaped"
}

run_inject() {
  local prompt=$1
  local payload output
  payload=$(inject_payload "$prompt")
  output=$(printf '%s' "$payload" | HOME="$FAKEHOME" "$NODE" "$INJECT")
  printf '%s' "$output"
}

rm -f "$FLAG"
payload=$(gate_payload "/work/repo/src/app.ts")
check_gate 1 "source without override is blocked" 2 "$payload"
pass 1 "source without override is blocked"

payload=$(gate_payload "/work/repo/notes.md")
check_gate 2 "markdown is allowed" 0 "$payload"
pass 2 "markdown is allowed"

payload=$(gate_payload "/tmp/plan.sh")
check_gate 3 "/tmp is allowed" 0 "$payload"
payload=$(gate_payload "/private/tmp/plan.sh")
check_gate 3 "/private/tmp is allowed" 0 "$payload"
pass 3 "real temporary roots are allowed"

payload=$(gate_payload "$FAKEHOME/Desktop/scratch.py")
check_gate 4 "home Desktop is allowed" 0 "$payload" "$FAKEHOME"
pass 4 "home Desktop is allowed"

payload=$(gate_payload "/work/repo/tmp/app.ts")
check_gate 5 "repository tmp directory is blocked" 2 "$payload"
pass 5 "repository tmp directory is blocked"

payload=$(gate_payload "/work/repo/Desktop/app.py")
check_gate 6 "nested Desktop directory is blocked" 2 "$payload"
pass 6 "nested Desktop directory is blocked"

payload=$(gate_payload "/work/repo/.claude/hooks/x.sh")
check_gate 7 "harness directory is allowed" 0 "$payload"
pass 7 "harness directory is allowed at any segment"

for file_path in "/work/repo/build.scala" "/work/repo/Makefile" "/work/repo/run"; do
  payload=$(gate_payload "$file_path")
  check_gate 8 "unknown code path $file_path is blocked" 2 "$payload"
done
pass 8 "unknown extensions, code basenames, and extensionless paths are blocked"

for file_path in "/work/repo/LICENSE" "/work/repo/.gitignore" \
  "/work/repo/package.json" "/work/repo/.env"; do
  payload=$(gate_payload "$file_path")
  check_gate 9 "non-code path $file_path is allowed" 0 "$payload"
done
pass 9 "non-code allowlist is allowed"

check_gate 10 "garbage payload fails closed" 2 "not-json"
check_gate 10 "missing file path fails closed" 2 "{\"session_id\":\"$SID\"}"
pass 10 "malformed and missing-path payloads fail closed"

printf '1\n' > "$FLAG"
payload=$(gate_payload "/work/repo/src/app.ts")
check_gate 11 "main-loop flag is honored" 0 "$payload"
pass 11 "main-loop flag is honored"

payload=$(printf \
  '{"session_id":"%s","cwd":"/work/repo","agent_id":"agent-123","tool_input":{"file_path":"/work/repo/src/app.ts"}}' \
  "$SID")
check_gate 12 "subagent cannot inherit flag" 2 "$payload"
pass 12 "subagent cannot inherit flag"

rm -f "$FLAG"
payload=$(gate_payload "src/app.ts" "/work/repo")
check_gate 13 "relative source path is resolved and blocked" 2 "$payload"
pass 13 "relative source path is resolved against payload cwd"

payload=$(gate_payload "x.ts" "/tmp/scratch")
check_gate 14 "relative temporary path is allowed" 0 "$payload"
pass 14 "relative temporary path is allowed"

rm -f "$FLAG"
run_inject "edit it yourself" >/dev/null
[ -f "$FLAG" ] || fail 15 "direct imperative did not set flag"
pass 15 "direct imperative sets flag"

rm -f "$FLAG"
run_inject "please edit it yourself this time" >/dev/null
[ -f "$FLAG" ] || fail 16 "polite direct imperative did not set flag"
pass 16 "polite direct imperative sets flag"

rm -f "$FLAG"
run_inject "do not edit it yourself" >/dev/null
[ ! -f "$FLAG" ] || fail 17 "negated imperative set flag"
pass 17 "do-not negation does not set flag"

rm -f "$FLAG"
run_inject "don't edit it yourself" >/dev/null
[ ! -f "$FLAG" ] || fail 18 "contraction negation set flag"
pass 18 "contraction negation does not set flag"

rm -f "$FLAG"
run_inject "never edit it yourself" >/dev/null
[ ! -f "$FLAG" ] || fail 19 "never-negated imperative set flag"
pass 19 "never negation does not set flag"

rm -f "$FLAG"
run_inject 'what does "edit it yourself" do?' >/dev/null
[ ! -f "$FLAG" ] || fail 20 "quoted mention set flag"
pass 20 "quoted mention does not set flag"

rm -f "$FLAG"
run_inject "does saying edit it yourself open the gate?" >/dev/null
[ ! -f "$FLAG" ] || fail 21 "mention context set flag"
pass 21 "mention context does not set flag"

rm -f "$FLAG"
run_inject "sen yap" >/dev/null
[ -f "$FLAG" ] || fail 22 "Turkish imperative did not set flag"
rm -f "$FLAG"
run_inject "sen yapma" >/dev/null
[ ! -f "$FLAG" ] || fail 22 "Turkish negation set flag"
pass 22 "Turkish imperative and negation are distinguished"

rm -f "$FLAG"
run_inject "don't delegate" >/dev/null
[ -f "$FLAG" ] || fail 23 "negative-form directive did not set flag"
pass 23 "negative-form directive sets flag"

printf '1\n' > "$FLAG"
output=$(run_inject "now fix the other bug in auth.scala")
[ ! -f "$FLAG" ] || fail 24 "new Scala task did not reset flag"
case "$output" in
  *ORCHESTRATOR/IMPLEMENTER\ LOOP*) ;;
  *) fail 24 "new Scala task did not emit orchestrator directive" ;;
esac
pass 24 "new Scala task resets flag and emits directive"

printf '1\n' > "$FLAG"
run_inject "ok" >/dev/null
[ -f "$FLAG" ] || fail 25 "short continuation reset flag"
pass 25 "short continuation preserves flag"

rm -f "$FLAG"
output=$(run_inject "update README.md please")
case "$output" in
  *ORCHESTRATOR/IMPLEMENTER\ LOOP*) fail 26 "markdown-only prompt emitted directive" ;;
esac
pass 26 "markdown-only prompt stays silent"

rm -f "$FLAG"
output=$(run_inject "bump the price to 3.5 dollars")
case "$output" in
  *ORCHESTRATOR/IMPLEMENTER\ LOOP*) fail 27 "numeric token emitted directive" ;;
esac
pass 27 "numeric tokens stay silent"

payload=$(printf \
  '{"session_id":"%s","cwd":{"a":1},"tool_input":{"file_path":"src/app.ts"}}' \
  "$SID")
if output=$(printf '%s' "$payload" | "$NODE" "$GATE" 2>&1); then
  rc=0
else
  rc=$?
fi
[ "$rc" -eq 2 ] ||
  fail 28 "invalid cwd returned rc=$rc, want 2; output: $output"
case "$output" in
  *failing\ closed*) ;;
  *) fail 28 "invalid cwd did not report failing closed; output: $output" ;;
esac
pass 28 "unexpected gate errors fail closed"

rm -f "$FLAG"
run_inject "don't ever edit it yourself" >/dev/null
[ ! -f "$FLAG" ] || fail 29 "adverb-separated negation set flag"
pass 29 "bounded adverb after negator does not set flag"

rm -f "$FLAG"
run_inject "please just edit it yourself" >/dev/null
[ -f "$FLAG" ] || fail 30 "unguarded adverb imperative did not set flag"
pass 30 "adverb without negator still sets flag"

printf '1\n' > "$FLAG"
run_inject "ok fix auth bug" >/dev/null
[ ! -f "$FLAG" ] || fail 31 "approval-prefixed new task preserved authorization"
payload=$(gate_payload "/work/repo/src/auth.ts")
check_gate 31 "approval-prefixed new task is blocked" 2 "$payload"
pass 31 "only a standalone acknowledgement preserves authorization"

rm -f "$FLAG"
run_inject "edit it yourself" >/dev/null
[ -f "$FLAG" ] || fail 32 "setup authorization missing"
if printf 'not-json' | HOME="$FAKEHOME" "$NODE" "$INJECT" >/dev/null 2>&1; then
  fail 32 "malformed injector payload returned success"
fi
[ ! -f "$FLAG" ] || fail 32 "malformed injector payload preserved stale authorization"
payload=$(gate_payload "/work/repo/src/app.ts")
check_gate 32 "malformed next prompt revokes prior authorization" 2 "$payload"
pass 32 "malformed injector input fails closed and revokes stale flags"

mkdir -p "$FLAG_DIR"
touch "$FLAG_DIR/maestro-direct-default.flag"
payload='{"cwd":"/work/repo","tool_input":{"file_path":"src/app.ts"}}'
check_gate 33 "missing session id cannot use a default flag" 2 "$payload"
payload='{"session_id":"../bad","cwd":"/work/repo","tool_input":{"file_path":"src/app.ts"}}'
check_gate 33 "invalid session id fails closed" 2 "$payload"
pass 33 "authorization requires a validated session id"

rm -f "$FLAG"
run_inject "do not under any circumstances edit it yourself" >/dev/null
[ ! -f "$FLAG" ] || fail 34 "nonlocal negation opened the gate"
pass 34 "negation applies across the current clause"

rm -f "$FLAG"
run_inject 'what does "please edit it yourself" mean?' >/dev/null
[ ! -f "$FLAG" ] || fail 35 "quoted polite mention opened the gate"
rm -f "$FLAG"
run_inject "I said please edit it yourself yesterday" >/dev/null
[ ! -f "$FLAG" ] || fail 35 "reported-speech mention opened the gate"
pass 35 "quoted and reported mentions cannot authorize edits"

mkdir -p "$FAKEHOME/repo/src" "$GATE_TMP"
printf 'source\n' > "$FAKEHOME/repo/src/app.ts"
ln -s "$FAKEHOME/repo/src/app.ts" "$GATE_TMP/allowed.md"
payload=$(gate_payload "$GATE_TMP/allowed.md")
check_gate 36 "scratch symlink to source is blocked" 2 "$payload"
ln -s "$FAKEHOME/repo/src" "$GATE_TMP/source-link"
payload=$(gate_payload "$GATE_TMP/source-link/not-created.ts")
check_gate 36 "nonexistent path below symlinked source parent is blocked" 2 "$payload"
payload=$(gate_payload "$GATE_TMP/ordinary-new.ts")
check_gate 36 "ordinary nonexistent scratch file remains allowed" 0 "$payload"
pass 36 "path exemptions use canonical existing targets and parents"

rm -f "$FLAG"
printf 'DO NOT OVERWRITE\n' > "$FAKEHOME/victim"
mkdir -p "$FLAG_DIR"
ln -s "$FAKEHOME/victim" "$FLAG"
payload=$(inject_payload "edit it yourself")
if printf '%s' "$payload" | HOME="$FAKEHOME" "$NODE" "$INJECT" >/dev/null 2>&1; then
  fail 37 "injector accepted a symlink authorization marker"
fi
[ "$(cat "$FAKEHOME/victim")" = 'DO NOT OVERWRITE' ] || fail 37 "authorization marker followed and overwrote a symlink"
[ ! -L "$FLAG" ] || fail 37 "unsafe marker symlink was retained"
pass 37 "authorization creation never follows symlinks"

output=$(run_inject "codex model")
case "$output" in
  *'separate role-specific efforts'*'<model> <debate-effort> <impl-effort>'*) ;;
  *) fail 38 "mid-session model setup did not request separate debate/implementation efforts: $output" ;;
esac
case "$output" in
  *'One setting feeds both loops'*) fail 38 "mid-session model setup still claims one shared effort" ;;
esac
pass 38 "mid-session model setup preserves role-specific effort selection"

output=$(run_inject "fix the auth bug")
case "$output" in
  *'mechanically necessary adjacent file'*'equally strong verifier'*) ;;
  *) fail 39 "injected NEEDS_ANSWERS guidance omitted the bounded autonomous-answer cases" ;;
esac
pass 39 "injected stop handling matches bounded autonomy policy"

rm -f "$FLAG" "$LEGACY_FLAG"
touch "$LEGACY_FLAG"
payload=$(gate_payload "/work/repo/src/app.ts")
check_gate 40 "legacy world-writable tmp marker is not authorization" 2 "$payload" "$FAKEHOME"
pass 40 "direct-edit authorization is not forgeable through the legacy /tmp marker path"

mkdir -p "$FAKEHOME/repo"
printf '#!/usr/bin/env node\n' > "$FAKEHOME/repo/tool.json"
chmod 755 "$FAKEHOME/repo/tool.json"
payload=$(gate_payload "$FAKEHOME/repo/tool.json")
check_gate 41 "executable file cannot use a non-code extension exemption" 2 "$payload" "$FAKEHOME"
pass 41 "executable files remain source-gated regardless of extension"

rm -f "$FLAG"
payload=$(gate_payload "/work/repo/src/app.ts")
if output=$(printf '%s' "$payload" |
  HOME="$FAKEHOME" "$NODE" "$GATE" 2>&1); then
  rc=0
else
  rc=$?
fi
[ "$rc" -eq 2 ] ||
  fail 42 "source gate guidance returned rc=$rc, want 2"
case "$output" in
  *implementer-loop.sh*implementer-watchdog.sh*) ;;
  *) fail 42 "source gate guidance omitted the default loop or peer fallback: $output" ;;
esac
pass 42 "source gate directs blocked edits to the default loop and peer fallback"

echo "VERIFY PASS: gate payloads, canonical paths, private subagent/session scoping, override semantics, model setup, and bounded autonomy framing"
exit 0
