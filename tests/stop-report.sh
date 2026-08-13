#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/hooks/implementer-loop.sh"
WATCHDOG="$ROOT/hooks/implementer-watchdog.sh"
WRITE_TURN_LIB="$ROOT/hooks/lib-write-turn.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-stop-report.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
WAIT_RC=0
WAIT_TIMED_OUT=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

wait_for_pid() {
  local pid="$1" limit="$2" elapsed=0
  WAIT_TIMED_OUT=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
      WAIT_TIMED_OUT=1
      kill -TERM -"$pid" 2>/dev/null || :
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || :
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" 2>/dev/null
  WAIT_RC=$?
  [ "$WAIT_TIMED_OUT" -eq 0 ] || WAIT_RC=124
}

REAL_NODE=$(node -p 'process.execPath')
REAL_SLEEP=$(command -v sleep)
REAL_MV=$(command -v mv)
TEST_HOME="$TEST_ROOT/home"
SHIM="$TEST_ROOT/shim"
COMPANION="$TEST_HOME/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
REPO="$TEST_ROOT/repo"
NEEDS_PLAN="$REPO/needs-plan.md"
DONE_PLAN="$REPO/done-plan.md"
STATUS_LOSS_PLAN="$REPO/status-loss-plan.md"
FAILED_PLAN="$REPO/failed-plan.md"
STATUS="$TEST_ROOT/status.json"
mkdir -p "$SHIM" "$(dirname "$COMPANION")" "$TEST_HOME/.codex" "$REPO"
: > "$COMPANION"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "-e" ]; then exec "%s" "$@"; fi\n' "$REAL_NODE"
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
printf 'Objective: fail closed when status is lost.\n' > "$STATUS_LOSS_PLAN"
printf 'Objective: carry failed evidence.\n' > "$FAILED_PLAN"
printf 'Objective: reject a result prefix.\n' > "$REPO/prefix-plan.md"
printf 'Objective: accept the last result record.\n' > "$REPO/last-record-plan.md"
cp "$DONE_PLAN" "$TEST_ROOT/done-plan.before"
git init -q "$REPO"
(
  cd "$REPO" &&
    git config user.email p@p &&
    git config user.name p &&
    git add needs-plan.md done-plan.md status-loss-plan.md failed-plan.md prefix-plan.md last-record-plan.md &&
    git commit -q -m init
)

TEST_PATH="$SHIM:$PATH"
NEEDS_RESULT='RESULT: NEEDS_ANSWERS
QUESTIONS:
1. Which answer should be used?
CONTINUATION:
- Completed: fixture-stop-capsule
- Evidence: the answer is missing
'

run_loop() {
  local name="$1" plan="$2" result="$3" max_iters="${4:-1}"
  : > "$TEST_ROOT/$name.calls"
  (
    cd "$REPO" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_CALL_LOG="$TEST_ROOT/$name.calls" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT="$result" \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters "$max_iters" --max-idle 2 --poll 1
  ) > "$TEST_ROOT/$name.stdout" \
    2> "$TEST_ROOT/$name.stderr" \
    3> "$TEST_ROOT/$name.progress"
}

run_status_loss() {
  local output="$TEST_ROOT/status-loss.out" pid
  set -m
  (
    cd "$REPO" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_COMPANION_TIMEOUT_SEC=2 \
        MAESTRO_TEST_STATUS_HANG=3 \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$STATUS_LOSS_PLAN" --verify true \
          --max-iters 2 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  wait_for_pid "$pid" 22
  STATUS_LOSS_RC=$WAIT_RC
  STATUS_LOSS_TIMED_OUT=$WAIT_TIMED_OUT
}

run_failed_loop() {
  local output="$TEST_ROOT/failed-loop.out" pid
  : > "$TEST_ROOT/failed-calls.log"
  : > "$TEST_ROOT/failed-lease-tokens.log"
  set -m
  (
    cd "$REPO" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_LEASE_METADATA="$REPO/.git/maestro-write.lock/metadata" \
        MAESTRO_TEST_LEASE_TOKEN_LOG="$TEST_ROOT/failed-lease-tokens.log" \
        MAESTRO_TEST_CALL_LOG="$TEST_ROOT/failed-calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT=$'RESULT: FAILED\nUNIQUE-FAILED-EVIDENCE-7319' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$FAILED_PLAN" --verify true \
          --max-iters 2 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  # Two dispatches settle in ~4s; a measured tail reaches 13s on a busy host.
  wait_for_pid "$pid" 30
  FAILED_LOOP_RC=$WAIT_RC
  FAILED_LOOP_TIMED_OUT=$WAIT_TIMED_OUT
  # wait_for_pid TERMs the loop it gives up on, and the loop poisons the write
  # lease on TERM. $REPO is shared with the cases below, so drop the poison here
  # and let the timeout surface as this case alone instead of three cascades.
  [ "$FAILED_LOOP_TIMED_OUT" -eq 0 ] || rm -rf "$REPO/.git/maestro-write.lock"
}

run_loop needs-first "$NEEDS_PLAN" "$NEEDS_RESULT"
FIRST_RC=$?
cp "$NEEDS_PLAN" "$TEST_ROOT/needs-plan.after-first"
run_loop needs-second "$NEEDS_PLAN" "$NEEDS_RESULT"
SECOND_RC=$?
run_loop "done" "$DONE_PLAN" 'RESULT: DONE'
DONE_RC=$?
run_loop prefix "$REPO/prefix-plan.md" 'RESULT: DONEISH' 2
PREFIX_RC=$?
run_loop last-record "$REPO/last-record-plan.md" $'RESULT: FAILED\nearlier failure\nRESULT: DONE'
LAST_RECORD_RC=$?
run_failed_loop
run_status_loss


t0_write_turn_interface_rejects_invalid_bounds_before_lease() (
  local repo="$TEST_ROOT/write-turn-invalid-repo"
  local plan="$repo/plan.md"
  local result="$TEST_ROOT/write-turn-invalid.result"
  local evidence="$TEST_ROOT/write-turn-invalid.evidence"
  local rc
  [ -f "$WRITE_TURN_LIB" ] || { echo "hooks/lib-write-turn.sh is missing"; return 1; }
  mkdir -p "$repo" || return 1
  printf 'Objective: invalid bounds must fail before ownership.\n' > "$plan" || return 1
  git init -q "$repo" || return 1
  cd "$repo" || return 1
  # shellcheck source=../hooks/lib-write-turn.sh
  source "$WRITE_TURN_LIB"
  write_turn_run "$plan" invalid 1 "$result" "$evidence"
  rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc want 3"; return 1; }
  [ ! -e "$repo/.git/maestro-write.lock" ] ||
    { echo "invalid Write turn acquired a Lease interval"; return 1; }
)
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

t6_status_loss_fails_closed() {
  local output="$TEST_ROOT/status-loss.out" starts
  local lock="$REPO/.git/maestro-write.lock" metadata="$REPO/.git/maestro-write.lock/metadata"
  [ "$STATUS_LOSS_TIMED_OUT" -eq 0 ] ||
    { echo "status-loss loop exceeded 22s outer bound"; return 1; }
  starts=$(grep -c 'WATCHDOG: started' "$output" || true)
  [ "$starts" -eq 1 ] ||
    {
      echo "starts=$starts want 1 (loop rc=$STATUS_LOSS_RC): $(tr '\n' ' ' < "$output")"
      return 1
    }
  [ "$STATUS_LOSS_RC" -eq 11 ] ||
    { echo "rc=$STATUS_LOSS_RC want 11"; return 1; }
  grep -q '^MAESTRO_FINAL: LOOP BLOCKED rc=11$' "$output" ||
    { echo "anchored BLOCKED final missing"; return 1; }
  [ -d "$lock" ] && [ -f "$metadata" ] ||
    { echo "write lease was not retained"; return 1; }
  grep -qx 'quiescence=unconfirmed' "$metadata" &&
    grep -qx 'unconfirmed_reason=status-lost' "$metadata" ||
    { echo "retained metadata is not poisoned for status loss"; return 1; }
}

t7_result_records_are_full_line_and_last_wins() {
  local starts
  [ "$PREFIX_RC" -eq 11 ] || { echo "DONEISH rc=$PREFIX_RC want 11"; return 1; }
  starts=$(grep -c '^task ' "$TEST_ROOT/prefix.calls" || true)
  [ "$starts" -eq 1 ] || { echo "DONEISH starts=$starts want 1"; return 1; }
  grep -qx 'IMPLEMENTER_STATE: COMPANION_FAILURE' "$TEST_ROOT/prefix.stderr" ||
    { echo "DONEISH companion-failure marker missing"; return 1; }
  [ "$LAST_RECORD_RC" -eq 0 ] || { echo "last-record rc=$LAST_RECORD_RC want 0"; return 1; }
  grep -q 'LOOP_STATE: VERIFIED_DONE' "$TEST_ROOT/last-record.progress" ||
    { echo "last anchored DONE record did not win"; return 1; }
}

t8_failed_result_evidence_reaches_next_dispatch() {
  local starts evidence samples first second
  [ "$FAILED_LOOP_TIMED_OUT" -eq 0 ] || { echo "failed-evidence loop timed out"; return 1; }
  [ "$FAILED_LOOP_RC" -eq 12 ] || { echo "rc=$FAILED_LOOP_RC want 12"; return 1; }
  starts=$(grep -c '^task ' "$TEST_ROOT/failed-calls.log" || true)
  evidence=$(grep -c 'UNIQUE-FAILED-EVIDENCE-7319' "$TEST_ROOT/failed-calls.log" || true)
  [ "$starts" -eq 2 ] || { echo "task starts=$starts want 2"; return 1; }
  [ "$evidence" -ge 1 ] || { echo "iteration two prompt omitted failed result evidence"; return 1; }
  samples=$(wc -l < "$TEST_ROOT/failed-lease-tokens.log" | tr -d ' ')
  first=$(sed -n '1p' "$TEST_ROOT/failed-lease-tokens.log")
  second=$(sed -n '2p' "$TEST_ROOT/failed-lease-tokens.log")
  [ "$samples" -eq 2 ] || { echo "lease samples=$samples want 2"; return 1; }
  [ "$first" = "$second" ] && [ "${first##* }" = "reclaim=0" ] ||
    { echo "Write turns crossed Lease generations: first=$first second=$second"; return 1; }
}
t8b_stuck_attempt_history_persists() {
  local blocks evidence
  blocks=$(grep -c '^--- BEGIN MAESTRO ATTEMPT HISTORY ' "$FAILED_PLAN" || true)
  evidence=$(grep -c 'UNIQUE-FAILED-EVIDENCE-7319' "$FAILED_PLAN" || true)
  [ "$blocks" -eq 1 ] || { echo "attempt history blocks=$blocks want 1"; return 1; }
  [ "$evidence" -ge 1 ] || { echo "persisted attempt history omitted failed evidence"; return 1; }
}

t8c_result_transport_failure_blocks_without_retry() (
  local repo="$TEST_ROOT/transport-failure-repo"
  local plan output="$TEST_ROOT/transport-failure.out"
  local calls="$TEST_ROOT/transport-failure.calls" rc starts
  mkdir -p "$repo"
  plan="$repo/plan.md"
  printf 'Objective: classify result transport failure.\n' > "$plan"
  (
    cd "$repo" &&
      git init -q &&
      git config user.email p@p &&
      git config user.name p &&
      git add plan.md &&
      git commit -q -m init
  ) || return 1
  : > "$calls"
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_CALL_LOG="$calls" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT-TRANSPORT-STDOUT-7319' \
        MAESTRO_TEST_RESULT_STDERR='RESULT-TRANSPORT-STDERR-8426' \
        MAESTRO_TEST_RESULT_EXIT=1 \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 2 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  starts=$(grep -c '^task ' "$calls" || true)
  [ "$rc" -eq 11 ] || { echo "transport failure rc=$rc want 11"; return 1; }
  [ "$starts" -eq 1 ] || { echo "transport failure starts=$starts want 1"; return 1; }
  grep -qx 'IMPLEMENTER_STATE: COMPANION_FAILURE' "$output" ||
    { echo "companion failure marker missing"; return 1; }
  grep -q 'post-launch companion/process/result failure' "$output" ||
    { echo "companion failure guidance missing"; return 1; }
  grep -q 'RESULT-TRANSPORT-STDOUT-7319' "$output" ||
    { echo "result transport stdout evidence missing"; return 1; }
  grep -q 'RESULT-TRANSPORT-STDERR-8426' "$output" ||
    { echo "result transport stderr evidence missing"; return 1; }
)
t8d_unparseable_launch_retains_both_locks() (
  local repo="$TEST_ROOT/unparseable-launch-repo" plan output calls rc starts
  local write_lock job_lock
  mkdir -p "$repo"
  plan="$repo/plan.md"
  output="$repo/output"
  calls="$repo/calls"
  write_lock="$repo/.git/maestro-write.lock"
  job_lock="$repo/.git/maestro-job-lock"
  printf 'Objective: retain ownership after an unparseable launch response.\n' > "$plan"
  (
    cd "$repo" &&
      git init -q &&
      git config user.email p@p &&
      git config user.name p &&
      git add plan.md &&
      git commit -q -m init
  ) || return 1
  : > "$calls"
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_CALL_LOG="$calls" \
        MAESTRO_TEST_TASK_RESPONSE_RAW='accepted-without-job-id' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 2 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  starts=$(grep -c '^task ' "$calls" || true)
  [ "$rc" -eq 11 ] || { echo "unparseable launch rc=$rc want 11"; return 1; }
  [ "$starts" -eq 1 ] || { echo "unparseable launch starts=$starts want 1"; return 1; }
  grep -qx 'IMPLEMENTER_STATE: COMPANION_FAILURE' "$output" ||
    { echo "unparseable launch companion-failure marker missing"; return 1; }
  [ -f "$write_lock/metadata.new" ] &&
    grep -qx 'quiescence=unconfirmed' "$write_lock/metadata.new" ||
    { echo "unparseable launch did not poison and retain the write lease"; return 1; }
  [ -f "$job_lock/metadata" ] &&
    ! grep -q '^job=' "$job_lock/metadata" ||
    { echo "unparseable launch did not retain an unpublished companion job lock"; return 1; }
)
t8e_attempt_history_is_byte_bounded() (
  local repo="$TEST_ROOT/bounded-history-repo" plan output result_file rc history_bytes
  mkdir -p "$repo"
  plan="$repo/plan.md"
  output="$repo/output"
  result_file="$repo/result.txt"
  printf 'Objective: bound persisted attempt evidence.\n' > "$plan"
  "$REAL_NODE" -e '
    process.stdout.write(
      "RESULT: FAILED\nBOUNDARY-START-" + "x".repeat(100000) + "-BOUNDARY-END\n"
    );
  ' > "$result_file" || return 1
  (
    cd "$repo" &&
      git init -q &&
      git config user.email p@p &&
      git config user.name p &&
      git add plan.md &&
      git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT_FILE="$result_file" \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  history_bytes=$(sed -n \
    '/^--- BEGIN MAESTRO ATTEMPT HISTORY /,/^--- END MAESTRO ATTEMPT HISTORY ---$/p' \
    "$plan" | wc -c | tr -d ' ')
  [ "$rc" -eq 12 ] || { echo "oversized history rc=$rc want 12"; return 1; }
  [ "$history_bytes" -le 65536 ] ||
    { echo "persisted history bytes=$history_bytes exceed the 65536-byte ceiling"; return 1; }
  grep -q 'MAESTRO_ATTEMPT_HISTORY_TRUNCATED' "$plan" ||
    { echo "persisted history lacks an explicit truncation marker"; return 1; }
  grep -q -- '-BOUNDARY-END' "$plan" ||
    { echo "persisted history did not retain the useful evidence tail"; return 1; }
  ! grep -q 'BOUNDARY-START' "$plan" ||
    { echo "persisted history retained the oversized evidence prefix"; return 1; }
)




t8f_attempt_history_quotes_embedded_delimiters() (
  local repo="$TEST_ROOT/history-delimiter-repo" plan output result_file rc ends
  mkdir -p "$repo"
  plan="$repo/plan.md"
  output="$repo/output"
  result_file="$repo/result.txt"
  printf 'Objective: preserve attempt-history framing.\n' > "$plan"
  printf 'RESULT: FAILED\n%s\nAFTER-INJECTED-END-9184\n' \
    '--- END MAESTRO ATTEMPT HISTORY ---' > "$result_file"
  (
    cd "$repo" &&
      git init -q &&
      git config user.email p@p &&
      git config user.name p &&
      git add plan.md &&
      git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT_FILE="$result_file" \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  ends=$(grep -c '^--- END MAESTRO ATTEMPT HISTORY ---$' "$plan" || true)
  [ "$rc" -eq 12 ] || { echo "embedded delimiter rc=$rc want 12"; return 1; }
  [ "$ends" -eq 1 ] ||
    { echo "embedded payload created $ends closing delimiters want 1"; return 1; }
  grep -qx '> --- END MAESTRO ATTEMPT HISTORY ---' "$plan" ||
    { echo "embedded closing delimiter was not quoted"; return 1; }
  grep -qx '> AFTER-INJECTED-END-9184' "$plan" ||
    { echo "payload after embedded delimiter escaped the quoted history"; return 1; }
)

t8g_attempt_history_commit_failure_preserves_plan() (
  local repo="$TEST_ROOT/history-commit-repo" plan before output result_file shim rc
  repo="$TEST_ROOT/history-commit-repo"
  mkdir -p "$repo"
  plan="$repo/plan.md"
  before="$repo/plan.before"
  output="$repo/output"
  result_file="$repo/result.txt"
  shim="$repo/shim"
  mkdir -p "$shim"
  printf 'Objective: preserve the plan on history commit failure.\n' > "$plan"
  cp "$plan" "$before"
  printf 'RESULT: FAILED\nATOMIC-HISTORY-EVIDENCE-5731\n' > "$result_file"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "-f" ]; then\n'
    printf '  case "${2:-}" in */.maestro-history.*) exit 73 ;; esac\n'
    printf 'fi\n'
    printf 'exec "%s" "$@"\n' "$REAL_MV"
  } > "$shim/mv"
  chmod +x "$shim/mv"
  (
    cd "$repo" &&
      git init -q &&
      git config user.email p@p &&
      git config user.name p &&
      git add plan.md &&
      git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$shim:$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT_FILE="$result_file" \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 12 ] || { echo "history commit failure rc=$rc want 12"; return 1; }
  cmp -s "$plan" "$before" ||
    { echo "history commit failure partially changed the plan"; return 1; }
  grep -q 'could not append attempt history' "$output" ||
    { echo "history commit failure warning missing"; return 1; }
)

t9_loop_is_independent_of_single_shot_adapter() {
  local bundle="$TEST_ROOT/peer-hooks" repo="$TEST_ROOT/peer-repo"
  local plan="$TEST_ROOT/peer-plan.md" output="$TEST_ROOT/peer-loop.out" name rc
  mkdir -p "$bundle" "$repo" || return 1
  for name in implementer-loop.sh lib-process.sh lib-companion.sh lib-job-lock.sh \
    lib-write-lease.sh lib-write-turn.sh codex-model-select.sh; do
    cp "$ROOT/hooks/$name" "$bundle/$name" || return 1
  done
  [ ! -e "$bundle/implementer-watchdog.sh" ] ||
    { echo "test bundle unexpectedly contains the single-shot adapter"; return 1; }
  printf 'Objective: prove peer adapter independence.\n' > "$plan" || return 1
  git init -q "$repo" || return 1
  (
    cd "$repo" &&
      git config user.email p@p &&
      git config user.name p &&
      printf 'peer\n' > tracked &&
      git add tracked &&
      git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$bundle/implementer-loop.sh" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -q '^MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0$' "$output" ||
    { echo "peer loop did not verify independently"; return 1; }
}


t10_public_adapter_exit_mappings() {
  local spec name result expected_rc expected_state output rc
  local mapping_repo="$TEST_ROOT/adapter-mapping-repo"
  mkdir -p "$mapping_repo" || return 1
  git init -q "$mapping_repo" || return 1
  (
    cd "$mapping_repo" &&
      git config user.email p@p &&
      git config user.name p &&
      printf 'adapter mapping\n' > seed &&
      git add seed &&
      git commit -q -m init
  ) || return 1
  for spec in \
    'done|RESULT: DONE|0|DONE' \
    'answers|RESULT: NEEDS_ANSWERS|10|NEEDS_ANSWERS' \
    'blocked|RESULT: BLOCKED|11|BLOCKED' \
    'failed|RESULT: FAILED|4|FAILED'; do
    IFS='|' read -r name result expected_rc expected_state <<< "$spec"
    output="$TEST_ROOT/watchdog-$name.out"
    (
      cd "$mapping_repo" &&
        env HOME="$TEST_HOME" PATH="$TEST_PATH" \
          MAESTRO_LOCK_WAIT_SEC=0 \
          MAESTRO_TEST_JOB_PHASE=completed \
          MAESTRO_TEST_RESULT="$result" \
          MAESTRO_TEST_STATUS="$STATUS" \
          bash "$WATCHDOG" --file "$DONE_PLAN" 2 1
    ) > "$output" 2>&1 3>&1
    rc=$?
    [ "$rc" -eq "$expected_rc" ] ||
      { echo "watchdog $name rc=$rc want $expected_rc"; return 1; }
    grep -q "^MAESTRO_FINAL: WATCHDOG $expected_state rc=$expected_rc$" \
      "$output" ||
      { echo "watchdog $name final marker missing"; return 1; }
  done

  output="$TEST_ROOT/watchdog-invalid.out"
  (
    cd "$mapping_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        bash "$WATCHDOG" --file "$DONE_PLAN" invalid 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 3 ] &&
    grep -q '^MAESTRO_FINAL: WATCHDOG FAILED rc=3$' "$output" ||
    { echo "watchdog invalid mapping rc=$rc"; return 1; }

  output="$TEST_ROOT/loop-invalid.out"
  (
    cd "$mapping_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        bash "$LOOP" --plan "$DONE_PLAN" --verify true --max-iters 0
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 3 ] &&
    grep -q '^MAESTRO_FINAL: LOOP FAILED rc=3$' "$output" ||
    { echo "loop invalid mapping rc=$rc"; return 1; }
  output="$TEST_ROOT/loop-unquoted-verify.out"
  (
    cd "$mapping_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        bash "$LOOP" --plan "$DONE_PLAN" --verify true extra --max-iters 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 3 ] &&
    grep -q '^LOOP_ERROR: unknown argument: extra$' "$output" ||
    { echo "unquoted verifier residue rc=$rc: $(tr '\n' ' ' < "$output")"; return 1; }

  output="$TEST_ROOT/loop-verifier-flag-string.out"
  (
    cd "$mapping_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$DONE_PLAN" --verify 'true --max-iters 4' --max-iters 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 0 ] &&
    grep -q '^MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0$' "$output" ||
    { echo "flag-like verifier command rc=$rc: $(tr '\n' ' ' < "$output")"; return 1; }
}

t11_signal_cancels_unpublished_writer_and_prints_result() (
  local repo="$TEST_ROOT/signal-race-repo" state="$TEST_ROOT/signal-race-state"
  local plan="$TEST_ROOT/signal-race-plan.md" pid rc count result_line final_line failed=0
  mkdir -p "$repo" "$state" || return 1
  : > "$state/calls.log"
  printf 'Objective: exercise signal cancellation.\n' > "$plan"
  git init -q "$repo" || return 1
  (
    cd "$repo" || exit 1
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_UNPUBLISHED_SECOND_WRITER=task-second-writer-bbbbbb \
        bash "$WATCHDOG" --file "$plan" 30 1
  ) > "$state/output" 2>&1 3>&1 &
  pid=$!
  set +m
  count=0
  while ! grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" 2>/dev/null &&
    [ "$count" -lt 200 ]; do
    sleep 0.05
    count=$((count + 1))
  done
  grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "watchdog never entered polling"; return 1; }
  kill -TERM "$pid" || return 1
  # Signalled shutdown cancels two writers before exiting; keep the hang guard
  # well clear of that work so a busy host reads as slow, not as rc=124.
  wait_for_pid "$pid" 30
  rc=$WAIT_RC
  [ "$rc" -eq 125 ] || { echo "signal rc=$rc want 125: $(tr '\n' ' ' < "$state/output")"; return 1; }
  grep -qx 'cancel task-fake0000-aaaaaa' "$state/calls.log" ||
    { echo "metadata job was not cancelled"; return 1; }
  grep -qx 'cancel task-second-writer-bbbbbb' "$state/calls.log" ||
    { echo "unpublished second writer was not cancelled"; failed=1; }
  result_line=$(grep -n '^RESULT: BLOCKED$' "$state/output" | head -1 | cut -d: -f1)
  final_line=$(grep -n '^MAESTRO_FINAL: WATCHDOG POISONED rc=125$' "$state/output" | head -1 | cut -d: -f1)
  [ -n "$result_line" ] && [ -n "$final_line" ] && [ "$result_line" -lt "$final_line" ] ||
    { echo "RESULT: BLOCKED was not printed before the poisoned final"; failed=1; }
  [ "$failed" -eq 0 ]
)

t12_passing_verification_survives_unwritable_fact() (
  local repo="$TEST_ROOT/unwritable-fact-repo" state="$TEST_ROOT/unwritable-fact-state"
  local plan="$TEST_ROOT/unwritable-fact-plan.md" shim="$TEST_ROOT/unwritable-fact-shim"
  local rc starts
  mkdir -p "$repo" "$state" "$shim" || return 1
  : > "$state/calls.log"
  printf 'Objective: pass local verification.\n' > "$plan"
  git init -q "$repo" || return 1
  (
    cd "$repo" || exit 1
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  printf '%s\n' '#!/usr/bin/env bash' \
    'target=""' \
    'for arg in "$@"; do target=$arg; done' \
    'case "$target" in /tmp/maestro-verify-fact.*) exit 1 ;; esac' \
    'exec "$MAESTRO_TEST_REAL_MV" "$@"' > "$shim/mv" || return 1
  chmod +x "$shim/mv" || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$shim:$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_REAL_MV="$REAL_MV" MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true --max-iters 1 --max-idle 2 --poll 1
  ) > "$state/output" 2>&1 3>&1
  rc=$?
  starts=$(grep -c '^task ' "$state/calls.log" || true)
  [ "$rc" -eq 0 ] || { echo "passing verify rc=$rc want 0: $(tr '\n' ' ' < "$state/output")"; return 1; }
  [ "$starts" -eq 1 ] || { echo "passing verify dispatched $starts jobs want 1"; return 1; }
  grep -q 'LOOP_WARNING:.*maestro-verify-fact' "$state/output" ||
    { echo "unwritable fact warning missing"; return 1; }
  ! grep -q 'LOCAL verification failed' "$state/output" ||
    { echo "passing verification was reported failed"; return 1; }
  grep -qx 'MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0' "$state/output" ||
    { echo "VERIFIED_DONE final missing"; return 1; }
)
t13_release_failure_overrides_verified_done() (
  local repo="$TEST_ROOT/release-failure-repo"
  local plan="$TEST_ROOT/release-failure-plan.md"
  local output="$TEST_ROOT/release-failure.out" rc
  mkdir -p "$repo" || return 1
  printf 'Objective: fail closed when lease release is unsafe.\n' > "$plan"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" \
          --verify 'touch .git/maestro-write.lock/foreign-entry' \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "unsafe release rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -q 'unrecognized entry' "$output" ||
    { echo "unsafe release diagnostic missing"; return 1; }
  grep -qx 'MAESTRO_FINAL: LOOP BLOCKED rc=11' "$output" ||
    { echo "unsafe release did not override the success final"; return 1; }
  ! grep -q '^MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0$' "$output" ||
    { echo "unsafe release emitted a verified success final"; return 1; }
  ! grep -q '^LOOP_STATE: VERIFIED_DONE' "$output" ||
    { echo "unsafe release emitted a verified success state"; return 1; }
  grep -q '^LOOP_STATE: BLOCKED' "$output" ||
    { echo "unsafe release omitted the terminal blocked state"; return 1; }
)

t13b_failed_verifier_release_failure_has_one_terminal_state() (
  local repo="$TEST_ROOT/release-failure-stuck-repo"
  local plan="$TEST_ROOT/release-failure-stuck-plan.md"
  local output="$TEST_ROOT/release-failure-stuck.out" rc states
  mkdir -p "$repo" || return 1
  printf 'Objective: fail verification and retain an unsafe lease.\n' > "$plan"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" \
          --verify 'touch .git/maestro-write.lock/foreign-entry; false' \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  states=$(grep -c '^LOOP_STATE:' "$output" || true)
  [ "$rc" -eq 11 ] ||
    { echo "failed verifier unsafe release rc=$rc want 11"; return 1; }
  [ "$states" -eq 1 ] ||
    { echo "failed verifier emitted $states terminal states: $(grep '^LOOP_STATE:' "$output")"; return 1; }
  grep -q '^LOOP_STATE: BLOCKED' "$output" ||
    { echo "failed verifier unsafe release omitted blocked state"; return 1; }
  ! grep -q '^LOOP_STATE: STUCK' "$output" ||
    { echo "failed verifier emitted stale STUCK state"; return 1; }
)

t14_release_cleanup_residue_does_not_reclassify_success() (
  local repo="$TEST_ROOT/release-cleanup-repo"
  local plan="$TEST_ROOT/release-cleanup-plan.md"
  local state="$TEST_ROOT/release-cleanup-state"
  local shim="$state/shim" output="$state/output" real_rm candidate
  local rc residue=0
  mkdir -p "$repo" "$shim" || return 1
  printf 'Objective: release the canonical lease despite cleanup residue.\n' > "$plan"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  real_rm=$(command -v rm) || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in */maestro-write.lock.reclaim.*) exit 1 ;; esac\n'
    printf 'done\n'
    printf 'exec "$MAESTRO_TEST_REAL_RM" "$@"\n'
  } > "$shim/rm" || return 1
  chmod +x "$shim/rm" || return 1
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$shim:$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_REAL_RM="$real_rm" \
        MAESTRO_TEST_JOB_PHASE=completed MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 0 ] ||
    { echo "cleanup residue rc=$rc want 0: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -q '^MAESTRO_LOCK_CLEANUP: canonical lock released;' "$output" ||
    { echo "cleanup residue diagnostic missing"; return 1; }
  grep -qx 'MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0' "$output" ||
    { echo "cleanup residue reclassified verified success"; return 1; }
  [ ! -d "$repo/.git/maestro-write.lock" ] ||
    { echo "canonical lease survived atomic retirement"; return 1; }
  for candidate in "$repo/.git/maestro-write.lock.reclaim."*; do
    [ ! -e "$candidate" ] || residue=$((residue + 1))
  done
  [ "$residue" -eq 1 ] ||
    { echo "cleanup residue count=$residue want 1"; return 1; }
)

t15_job_lock_release_failure_blocks_completed_turn() (
  local repo="$TEST_ROOT/job-release-failure-repo"
  local plan="$TEST_ROOT/job-release-failure-plan.md"
  local output="$TEST_ROOT/job-release-failure.out" rc
  local job_lock write_lock
  mkdir -p "$repo" || return 1
  printf 'Objective: block if the companion job lock cannot be released.\n' > "$plan"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  job_lock="$repo/.git/maestro-job-lock"
  write_lock="$repo/.git/maestro-write.lock"
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_LOCK_WAIT_SEC=0 \
        MAESTRO_TEST_JOB_PHASE=completed MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$STATUS" \
        MAESTRO_TEST_MUTATE_JOB_LOCK_METADATA="$job_lock/metadata" \
        bash "$LOOP" --plan "$plan" --verify true \
          --max-iters 1 --max-idle 2 --poll 1
  ) > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "job-lock release failure rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -q 'MAESTRO_JOB_LOCK:.*release' "$output" ||
    { echo "job-lock release failure diagnostic missing"; return 1; }
  grep -qx 'MAESTRO_FINAL: LOOP BLOCKED rc=11' "$output" ||
    { echo "job-lock release failure did not block public adapter"; return 1; }
  [ -d "$job_lock" ] ||
    { echo "foreign job-lock generation was removed"; return 1; }
  [ ! -d "$write_lock" ] ||
    { echo "write lease remained after job-lock-only failure"; return 1; }
)

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then
    ok "$label"
  else
    bad "$label" "${detail:-no detail}"
  fi
}

printf '=== Stop report persistence verification ===\n'
check t0_write_turn_interface_rejects_invalid_bounds_before_lease "Write turn validates before touching the Lease interval"
check t1_needs_answers_exit "NEEDS_ANSWERS still exits 10"
check t2_first_stop_persisted "first stop appends a delimited history block with its continuation"
check t3_questions_relayed "questions remain on stdout"
check t4_second_stop_appended "second stop appends a second history block"
check t5_verified_done_unchanged "VERIFIED_DONE appends nothing"
check t6_status_loss_fails_closed "status loss blocks after one dispatch and retains poison"
check t7_result_records_are_full_line_and_last_wins "RESULT records are anchored and the last record wins"
check t8_failed_result_evidence_reaches_next_dispatch "FAILED result evidence reaches the next dispatch"
check t8b_stuck_attempt_history_persists "STUCK persists bounded attempt history in the plan"
check t8c_result_transport_failure_blocks_without_retry "result transport failure blocks without billing a retry"
check t8d_unparseable_launch_retains_both_locks "unparseable successful launch retains both ownership locks"
check t8e_attempt_history_is_byte_bounded "STUCK attempt history has a hard byte ceiling"
check t8f_attempt_history_quotes_embedded_delimiters "attempt history quotes embedded closing delimiters"
check t8g_attempt_history_commit_failure_preserves_plan "failed history commit leaves the plan byte-identical"
check t9_loop_is_independent_of_single_shot_adapter "loop and single-shot adapters are peers"
check t10_public_adapter_exit_mappings "public adapter exits and final markers stay exact"
check t11_signal_cancels_unpublished_writer_and_prints_result "signal cancellation scans all writers and prints the blocked result"
check t12_passing_verification_survives_unwritable_fact "passing verification survives an unwritable fact file"
check t13_release_failure_overrides_verified_done "unsafe lease release overrides public adapter success"
check t13b_failed_verifier_release_failure_has_one_terminal_state "failed verification plus unsafe release emits one blocked state"
check t14_release_cleanup_residue_does_not_reclassify_success "post-retirement cleanup residue does not reclassify success"
check t15_job_lock_release_failure_blocks_completed_turn "completed turn blocks when its job lock cannot be released"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
