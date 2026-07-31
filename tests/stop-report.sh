#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/hooks/implementer-loop.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-stop-report.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

REAL_NODE=$(node -p 'process.execPath')
REAL_SLEEP=$(command -v sleep)
TEST_HOME="$TEST_ROOT/home"
SHIM="$TEST_ROOT/shim"
COMPANION="$TEST_HOME/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
REPO="$TEST_ROOT/repo"
NEEDS_PLAN="$REPO/needs-plan.md"
DONE_PLAN="$REPO/done-plan.md"
STATUS="$TEST_ROOT/status.json"
mkdir -p "$SHIM" "$(dirname "$COMPANION")" "$TEST_HOME/.codex" "$REPO"
: > "$COMPANION"
{
  printf '#!/usr/bin/env bash\n'
  printf 'shift\n'
  printf 'exec "%s" "%s" "$@"\n' "$REAL_NODE" "$FIXTURE"
} > "$SHIM/node"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exec "%s" 0.01\n' "$REAL_SLEEP"
} > "$SHIM/sleep"
chmod +x "$SHIM/node" "$SHIM/sleep"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$TEST_HOME/.codex/config.toml"
printf 'high\n' > "$TEST_HOME/.codex/maestro-impl-effort"
printf '{\n  "running": [],\n  "latestFinished": null\n}\n' > "$STATUS"
printf 'Objective: stop for answers.\n' > "$NEEDS_PLAN"
printf 'Objective: finish successfully.\n' > "$DONE_PLAN"
cp "$DONE_PLAN" "$TEST_ROOT/done-plan.before"
git init -q "$REPO"
(
  cd "$REPO" &&
    git config user.email p@p &&
    git config user.name p &&
    git add needs-plan.md done-plan.md &&
    git commit -q -m init
)

TEST_PATH="$SHIM:$PATH"
NEEDS_RESULT='RESULT: NEEDS_ANSWERS
QUESTIONS:
1. Which answer should be used?
CONTINUATION:
- Completed: fixture-stop-capsule
- Evidence: the answer is missing
- Next: apply the supplied answer'

run_loop() {
  local name="$1" plan="$2" result="$3"
  (
    cd "$REPO" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT="$result" \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 0
  ) > "$TEST_ROOT/$name.stdout" \
    2> "$TEST_ROOT/$name.stderr" \
    3> "$TEST_ROOT/$name.progress"
}

run_loop needs-first "$NEEDS_PLAN" "$NEEDS_RESULT"
FIRST_RC=$?
cp "$NEEDS_PLAN" "$TEST_ROOT/needs-plan.after-first"
run_loop needs-second "$NEEDS_PLAN" "$NEEDS_RESULT"
SECOND_RC=$?
run_loop done "$DONE_PLAN" 'RESULT: DONE'
DONE_RC=$?

t1_needs_answers_exit() {
  [ "$FIRST_RC" -eq 10 ] && [ "$SECOND_RC" -eq 10 ] ||
    { echo "first=$FIRST_RC second=$SECOND_RC want 10"; return 1; }
}

t2_first_stop_persisted() {
  local plan="$TEST_ROOT/needs-plan.after-first" begins ends continuations capsules
  begins=$(grep -Fc -- '--- BEGIN MAESTRO STOP HISTORY (automatically written after iteration 1) ---' "$plan" || true)
  ends=$(grep -Fc -- '--- END MAESTRO STOP HISTORY (iteration 1) ---' "$plan" || true)
  continuations=$(grep -Fc 'CONTINUATION:' "$plan" || true)
  capsules=$(grep -Fc -- '- Completed: fixture-stop-capsule' "$plan" || true)
  [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] &&
    [ "$continuations" -eq 1 ] && [ "$capsules" -eq 1 ] ||
    {
      echo "begins=$begins ends=$ends continuations=$continuations capsules=$capsules want 1 each"
      return 1
    }
}

t3_questions_relayed() {
  grep -Fqx 'QUESTIONS:' "$TEST_ROOT/needs-first.stdout" &&
    grep -Fqx '1. Which answer should be used?' "$TEST_ROOT/needs-first.stdout" ||
    { echo "questions missing from stdout"; return 1; }
}

t4_second_stop_appended() {
  local begins ends continuations capsules
  begins=$(grep -Fc -- '--- BEGIN MAESTRO STOP HISTORY (automatically written after iteration 1) ---' "$NEEDS_PLAN" || true)
  ends=$(grep -Fc -- '--- END MAESTRO STOP HISTORY (iteration 1) ---' "$NEEDS_PLAN" || true)
  continuations=$(grep -Fc 'CONTINUATION:' "$NEEDS_PLAN" || true)
  capsules=$(grep -Fc -- '- Completed: fixture-stop-capsule' "$NEEDS_PLAN" || true)
  [ "$begins" -eq 2 ] && [ "$ends" -eq 2 ] &&
    [ "$continuations" -eq 2 ] && [ "$capsules" -eq 2 ] ||
    {
      echo "begins=$begins ends=$ends continuations=$continuations capsules=$capsules want 2 each"
      return 1
    }
}

t5_verified_done_unchanged() {
  [ "$DONE_RC" -eq 0 ] ||
    { echo "rc=$DONE_RC want 0"; return 1; }
  grep -q 'LOOP_STATE: VERIFIED_DONE' "$TEST_ROOT/done.progress" ||
    { echo "VERIFIED_DONE progress missing"; return 1; }
  cmp -s "$TEST_ROOT/done-plan.before" "$DONE_PLAN" ||
    { echo "done plan changed"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then
    ok "$label"
  else
    bad "$label" "${detail:-no detail}"
  fi
}

printf '=== Stop report persistence verification ===\n'
check t1_needs_answers_exit "NEEDS_ANSWERS still exits 10"
check t2_first_stop_persisted "first stop appends a delimited history block with its continuation"
check t3_questions_relayed "questions remain on stdout"
check t4_second_stop_appended "second stop appends a second history block"
check t5_verified_done_unchanged "VERIFIED_DONE appends nothing"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
