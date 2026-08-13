#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-bounded-calls.XXXXXXXX)
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

milliseconds_now() {
  local value
  value=$(date +%s%N 2>/dev/null) || value=""
  case "$value" in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *) printf '%s\n' "$((value / 1000000))" ;;
  esac
}

# shellcheck source=../hooks/lib-write-lease.sh
source "$ROOT/hooks/lib-write-lease.sh"
progress_init

t0_process_module_contract() (
  local out="$TEST_ROOT/process-contract.out"
  local err="$TEST_ROOT/process-contract.err"
  local rc
  [ -f "$ROOT/hooks/lib-process.sh" ] ||
    { echo "hooks/lib-process.sh is missing"; return 1; }
  # shellcheck source=../hooks/lib-process.sh
  source "$ROOT/hooks/lib-process.sh"
  process_run_bounded 2 TEST_PROCESS : "$out" "$err" -- \
    bash -c 'printf "process-out\n"; printf "process-err\n" >&2; exit 37'
  rc=$?
  [ "$rc" -eq 37 ] || { echo "rc=$rc want 37"; return 1; }
  [ "$(cat "$out")" = process-out ] || { echo "stdout file mismatch"; return 1; }
  [ "$(cat "$err")" = process-err ] || { echo "stderr file mismatch"; return 1; }
)

t0b_companion_module_contract() (
  local prompt="$TEST_ROOT/companion-contract.prompt"
  local result="$TEST_ROOT/companion-contract.result"
  local profile="$TEST_ROOT/companion-contract.profile"
  local evidence="$TEST_ROOT/companion-contract.evidence" rc
  declare -F companion_turn >/dev/null &&
    declare -F companion_interrupt >/dev/null &&
    declare -F companion_writers >/dev/null ||
    { echo "narrow companion interface missing"; return 1; }
  printf 'objective\n' > "$prompt"
  companion_turn inferred "$prompt" 2 1 "$result" "$profile" "$evidence" :
  rc=$?
  [ "$rc" -eq 3 ] || { echo "invalid explicit mode rc=$rc want 3"; return 1; }
  companion_turn write "$prompt" 2 1 "$result" "$profile" "$evidence" :
  rc=$?
  [ "$rc" -eq 3 ] || { echo "write without lifecycle rc=$rc want 3"; return 1; }
  [ ! -e "$result" ] && [ ! -e "$profile" ] && [ ! -e "$evidence" ] ||
    { echo "invalid mode or lifecycle mutated caller-owned files"; return 1; }
)

t0c_failed_started_publication_cancels_job() (
  local prompt="$TEST_ROOT/publication-failure.prompt"
  local result="$TEST_ROOT/publication-failure.result"
  local profile="$TEST_ROOT/publication-failure.profile"
  local evidence="$TEST_ROOT/publication-failure.evidence"
  local calls="$TEST_ROOT/publication-failure.calls" rc
  companion_resolve() { printf '%s' "$FIXTURE"; }
  companion_pin() { printf 'gpt-5.6-sol\thigh\thigh\tgpt-5.6-luna-max\n'; }
  reject_started() {
    [ "$1" != started ]
  }
  printf 'objective\n' > "$prompt"
  : > "$calls"
  export MAESTRO_TEST_CALL_LOG="$calls"
  companion_turn write "$prompt" 2 1 "$result" "$profile" "$evidence" \
    reject_started
  rc=$?
  [ "$rc" -eq 125 ] || { echo "publication failure rc=$rc want 125"; return 1; }
  [ "$(grep -c '^cancel task-fake0000-aaaaaa$' "$calls")" -eq 1 ] ||
    { echo "unpublished job was not cancelled exactly once"; return 1; }
  grep -q '^job=task-fake0000-aaaaaa$' "$profile" ||
    { echo "profile omitted unpublished job"; return 1; }
  grep -q '^cancel_reason=launch-publication-failed$' "$profile" ||
    { echo "profile omitted publication failure"; return 1; }
)

t0e_role_dispatch_uses_pinned_models() (
  local read_prompt="$TEST_ROOT/model-routing-read.prompt"
  local read_result="$TEST_ROOT/model-routing-read.result"
  local read_profile="$TEST_ROOT/model-routing-read.profile"
  local read_evidence="$TEST_ROOT/model-routing-read.evidence"
  local read_argv="$TEST_ROOT/model-routing-read.argv"
  local write_prompt="$TEST_ROOT/model-routing-write.prompt"
  local write_result="$TEST_ROOT/model-routing-write.result"
  local write_profile="$TEST_ROOT/model-routing-write.profile"
  local write_evidence="$TEST_ROOT/model-routing-write.evidence"
  local write_argv="$TEST_ROOT/model-routing-write.argv" rc
  companion_resolve() { printf '%s' "$FIXTURE"; }
  companion_pin() { printf 'gpt-5.6-sol\thigh\thigh\tgpt-5.6-luna-max\n'; }
  write_lifecycle() { return 0; }
  printf 'read objective\n' > "$read_prompt"
  export MAESTRO_TEST_ARGV="$read_argv"
  companion_turn read "$read_prompt" 2 1 "$read_result" "$read_profile" \
    "$read_evidence" :
  rc=$?
  [ "$rc" -eq 0 ] || { echo "read dispatch rc=$rc"; return 1; }
  grep -Fq '"--model","gpt-5.6-sol"' "$read_argv" ||
    { echo "read dispatch used the implementation model: $(cat "$read_argv")"; return 1; }
  printf 'write objective\n' > "$write_prompt"
  export MAESTRO_TEST_ARGV="$write_argv"
  companion_turn write "$write_prompt" 2 1 "$write_result" "$write_profile" \
    "$write_evidence" write_lifecycle
  rc=$?
  [ "$rc" -eq 0 ] || { echo "write dispatch rc=$rc"; return 1; }
  grep -Fq '"--model","gpt-5.6-luna-max"' "$write_argv" ||
    { echo "write dispatch used the debate model: $(cat "$write_argv")"; return 1; }
  grep -Fq '"--effort","high"' "$write_argv" ||
    { echo "write dispatch omitted explicit high effort: $(cat "$write_argv")"; return 1; }
)

t0f_matching_top_level_effort_omits_write_flag() (
  local argv="$TEST_ROOT/max-write.argv" calls="$TEST_ROOT/max-write.calls"
  local job_file="$TEST_ROOT/max-write.job" out="$TEST_ROOT/max-write.stdout"
  local err="$TEST_ROOT/max-write.stderr" warning="$TEST_ROOT/max-write.warning"
  local output job rc
  : > "$calls"
  export MAESTRO_TEST_ARGV="$argv" MAESTRO_TEST_CALL_LOG="$calls"
  export COMPANION_CONFIG_EFFORT=max
  output=$(companion_start "$FIXTURE" objective write \
    gpt-5.6-luna max : "$job_file" "$out" "$err" 3>&1 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "matching max write rc=$rc output=$output"; return 1; }
  [ -s "$argv" ] || { echo "matching max write did not launch a task"; return 1; }
  ! grep -Fq '"--effort"' "$argv" ||
    { echo "matching max write passed an effort flag: $(cat "$argv")"; return 1; }
  grep -q '^task ' "$calls" || { echo "matching max write did not launch a task"; return 1; }
  case "$output" in
    *'CODEX: companion cannot express implementation effort=max as a flag; the pinned top-level config value is the same tier and governs this write dispatch'*) ;;
    *) echo "matching max progress missing: $output"; return 1 ;;
  esac
  job=$(cat "$job_file")
  companion_verify_pin "$FIXTURE" "$job" gpt-5.6-luna max : "$out" "$err"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "matching max pin verification rc=$rc"; return 1; }
  export COMPANION_CONFIG_EFFORT=high
  companion_verify_pin "$FIXTURE" "$job" gpt-5.6-luna max : "$out" "$err" \
    2> "$warning"
  rc=$?
  [ "$rc" -eq 4 ] || { echo "mismatched max pin verification rc=$rc"; return 1; }
  grep -Fq "Codex pin verification warning for $job" "$warning" ||
    { echo "mismatched max pin verification warning missing: $(cat "$warning")"; return 1; }
)

t0g_mismatched_top_level_effort_refuses_write() (
  local argv="$TEST_ROOT/mismatch-write.argv" calls="$TEST_ROOT/mismatch-write.calls"
  local job_file="$TEST_ROOT/mismatch-write.job" out="$TEST_ROOT/mismatch-write.stdout"
  local err="$TEST_ROOT/mismatch-write.stderr" output rc
  : > "$calls"
  export MAESTRO_TEST_ARGV="$argv" MAESTRO_TEST_CALL_LOG="$calls"
  output=$(COMPANION_CONFIG_EFFORT=high companion_start "$FIXTURE" objective write \
    gpt-5.6-luna max : "$job_file" "$out" "$err" 3>&1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "mismatched max write was accepted: $output"; return 1; }
  ! grep -q '^task ' "$calls" || { echo "mismatched max write launched a task"; return 1; }
  [ ! -e "$argv" ] || { echo "mismatched max write produced task argv"; return 1; }
)

t0d_read_interrupt_never_cancels_unknown_writer() (
  local evidence="$TEST_ROOT/read-interrupt.evidence"
  local calls="$TEST_ROOT/read-interrupt.calls"
  local status="$TEST_ROOT/read-interrupt.status" rc
  companion_resolve() { printf '%s' "$FIXTURE"; }
  printf '%s\n' '{"running":[{"id":"task-writer00-aaaaaa","write":true}],"latestFinished":null}' > "$status"
  : > "$calls"
  export MAESTRO_TEST_CALL_LOG="$calls"
  export MAESTRO_TEST_STATUS="$status"
  companion_interrupt TERM "" "$evidence" :
  rc=$?
  [ "$rc" -eq 124 ] || { echo "read interrupt rc=$rc want 124"; return 1; }
  ! grep -q '^cancel ' "$calls" ||
    { echo "read interrupt cancelled an unknown repository writer"; return 1; }
)

t1_hanging_status_is_bounded() {
  local timeout="${MAESTRO_COMPANION_TIMEOUT_SEC-2}"
  local output="$TEST_ROOT/hanging-status.out" pid started elapsed limit
  local call_out="$TEST_ROOT/hanging-status.stdout"
  local call_err="$TEST_ROOT/hanging-status.stderr"
  limit=$((timeout + 3))
  started=$(date +%s)
  set -m
  (
    export MAESTRO_COMPANION_TIMEOUT_SEC="$timeout"
    export MAESTRO_TEST_STATUS_HANG=6
    companion_verify_pin "$FIXTURE" task-bounded0-aaaaaa \
      gpt-5.6-sol high : "$call_out" "$call_err"
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  wait_for_pid "$pid" 12
  elapsed=$(( $(date +%s) - started ))
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "status exceeded 12s outer bound"; return 1; }
  [ "$elapsed" -le "$limit" ] ||
    { echo "status took ${elapsed}s with ${timeout}s companion timeout"; return 1; }
  [ "$WAIT_RC" -eq 4 ] ||
    { echo "rc=$WAIT_RC want 4 from the existing pin-verification failure"; return 1; }
  grep -q "MAESTRO_COMPANION: timed out after ${timeout}s" "$output" ||
    { echo "timeout progress missing: $(tr '\n' ' ' < "$output")"; return 1; }
}

t2_timeout_reaps_process_group() {
  local output="$TEST_ROOT/reap.out" error="$TEST_ROOT/reap.err"
  local child_file="$TEST_ROOT/child.pid"
  local child rc elapsed=0
  process_run_bounded 1 TEST_REAP : "$output" "$error" -- bash -c \
    'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait "$child"' \
    _ "$child_file"
  rc=$?
  [ "$rc" -eq 125 ] || { echo "rc=$rc want 125"; return 1; }
  [ -s "$child_file" ] || { echo "wrapped child pid missing"; return 1; }
  child=$(sed -n '1p' "$child_file")
  while kill -0 "$child" 2>/dev/null && [ "$elapsed" -lt 3 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "wrapped child $child survived timeout"
    return 1
  fi
}

t3_run_bounded_returns_wrapped_rc() {
  local output="$TEST_ROOT/process-rc.out" error="$TEST_ROOT/process-rc.err" rc
  process_run_bounded 2 TEST_RC : "$output" "$error" -- \
    bash -c 'printf "preserved\n"; exit 37'
  rc=$?
  [ "$rc" -eq 37 ] || { echo "rc=$rc want 37"; return 1; }
  [ "$(cat "$output")" = preserved ] ||
    { echo "failed command stdout was not preserved"; return 1; }
  process_run_bounded 2 TEST_STDOUT : "$output" "$error" -- printf 'bounded-ok\n'
  rc=$?
  [ "$rc" -eq 0 ] || { echo "success rc=$rc want 0"; return 1; }
  [ "$(cat "$output")" = bounded-ok ] || { echo "stdout=$(cat "$output")"; return 1; }
}

t4_invalid_companion_timeout_falls_back() {
  local progress rc
  local call_out="$TEST_ROOT/invalid-timeout.stdout"
  local call_err="$TEST_ROOT/invalid-timeout.stderr"
  progress=$(MAESTRO_COMPANION_TIMEOUT_SEC=bogus \
    companion_call "$call_out" "$call_err" \
      "$FIXTURE" result task-bounded0-aaaaaa 3>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  case "$progress" in
    *MAESTRO_COMPANION*bogus*120s*) ;;
    *) echo "fallback progress missing: $progress"; return 1 ;;
  esac
  case "$(cat "$call_out")" in
    *"RESULT: DONE"*) ;;
    *) echo "companion output missing: $(cat "$call_out")"; return 1 ;;
  esac
}

t5_repo_digest_survives_refactor() {
  local output rc
  output=$(cd "$ROOT" && MAESTRO_DIGEST_TIMEOUT_SEC=120 repo_digest_bounded)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  case "$output" in
    tree-v2:*) ;;
    *) echo "digest=$output"; return 1 ;;
  esac
}

t6_poll_hanging_status_is_bounded() {
  local timeout=1 output="$TEST_ROOT/poll-hanging-status.out" pid
  local call_out="$TEST_ROOT/poll-hanging-status.stdout"
  local call_err="$TEST_ROOT/poll-hanging-status.stderr"
  # Mode is explicit. Inherited Lease interval state must never turn a read poll
  # into write cancellation.
  set -m
  (
    export MAESTRO_COMPANION_TIMEOUT_SEC="$timeout"
    export MAESTRO_TEST_STATUS_HANG=4
    companion_poll "$FIXTURE" task-bounded0-aaaaaa 60 1 \
      "$SECONDS" read "" : "$call_out" "$call_err"
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  set +m
  wait_for_pid "$pid" 18
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "poll exceeded 18s outer bound"; return 1; }
  [ "$WAIT_RC" -eq 124 ] ||
    { echo "rc=$WAIT_RC want 124 from read-only status-loss cancellation"; return 1; }
  grep -q "MAESTRO_COMPANION: timed out after ${timeout}s" "$output" ||
    { echo "timeout progress missing: $(tr '\n' ' ' < "$output")"; return 1; }
}

t7_fast_status_has_no_one_second_floor() {
  local started finished elapsed i
  local call_out="$TEST_ROOT/fast-status.stdout"
  local call_err="$TEST_ROOT/fast-status.stderr"
  started=$(milliseconds_now) || return 1
  for i in 1 2 3 4 5; do
    companion_call "$call_out" "$call_err" \
      "$FIXTURE" status task-bounded0-aaaaaa --json ||
      { echo "status call $i failed"; return 1; }
  done
  finished=$(milliseconds_now) || return 1
  elapsed=$((finished - started))
  printf 'MEASURE 5 fast status calls: %sms\n' "$elapsed" >&3
  [ "$elapsed" -lt 2000 ] ||
    { echo "5 status calls took ${elapsed}ms want under 2000ms"; return 1; }
}

t8_explicit_read_ignores_inherited_lease() {
  local lease="$TEST_ROOT/injected-lease" output="$TEST_ROOT/t6-inherited.out" rc
  mkdir "$lease" || return 1
  cat > "$lease/metadata" <<'EOF' || return 1
token=faketoken
pid=1
process_start=x
job_id=fakejob
session_id=fakesess
started_at=2026-01-01T00:00:00Z
started_epoch=1767225600
digest_before=unavailable
EOF
  export MAESTRO_LOCK_ACQUIRED=1
  export MAESTRO_LOCK_TOKEN=faketoken
  export MAESTRO_LOCK_DIR="$lease"
  t6_poll_hanging_status_is_bounded > "$output" 2>&1
  rc=$?
  unset MAESTRO_LOCK_ACQUIRED MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR
  [ "$rc" -eq 0 ] || { cat "$output"; return 1; }
  ! grep -q '^quiescence=unconfirmed$' "$lease/metadata" ||
    { echo "injected lease was poisoned"; return 1; }
}

t9_failed_start_cannot_publish_a_task_id() (
  local job_file="$TEST_ROOT/phantom.job"
  local call_out="$TEST_ROOT/phantom.stdout"
  local call_err="$TEST_ROOT/phantom.stderr" output rc
  companion_call() {
    printf 'transport failed after allocating task-phantom0-aaaaaa\n' > "$1"
    : > "$2"
    return 9
  }
  companion_start "$FIXTURE" objective read gpt-5.6-sol high : \
    "$job_file" "$call_out" "$call_err"
  rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc want 3"; return 1; }
  [ ! -s "$job_file" ] || {
    output=$(cat "$job_file")
    echo "failed launch published task id: $output"
    return 1
  }
)

t10_dispatch_budget_resolution() (
  local output rc
  unset MAESTRO_MAX_DISPATCH_SEC
  [ "$(companion_dispatch_budget write)" = 2400 ] ||
    { echo "unset write budget is not 2400"; return 1; }
  [ "$(companion_dispatch_budget read)" = 1200 ] ||
    { echo "unset read budget is not 1200"; return 1; }
  [ "$(MAESTRO_MAX_DISPATCH_SEC=7 companion_dispatch_budget write)" = 7 ] ||
    { echo "explicit write budget was changed"; return 1; }
  output=$(MAESTRO_MAX_DISPATCH_SEC=bogus companion_dispatch_budget write 3>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "invalid budget rc=$rc"; return 1; }
  case "$output" in
    *MAESTRO_POLL*bogus*1200s*1200) ;;
    *) echo "invalid budget fallback/warning missing: $output"; return 1 ;;
  esac
)

t11_idle_uses_elapsed_time_not_poll_count() (
  local log="$TEST_ROOT/slow-status.log" reason="$TEST_ROOT/slow-status.reason"
  local call_out="$TEST_ROOT/slow-status.stdout"
  local call_err="$TEST_ROOT/slow-status.stderr"
  local started elapsed rc
  : > "$log"
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
  companion_call() {
    sleep 2
    printf '{"status":"running","logFile":"%s"}\n' "$log" > "$1"
    : > "$2"
  }
  companion_cancel_job() {
    printf '%s\n' "$3" > "$reason"
    return 124
  }
  started=$SECONDS
  companion_poll "$FIXTURE" task-slowstatus-aaaaaa 2 1 \
    "$SECONDS" read "" : "$call_out" "$call_err" >/dev/null 2>&1
  rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || { echo "rc=$rc want 124"; return 1; }
  [ "$(cat "$reason")" = idle ] || { echo "cancel reason=$(cat "$reason") want idle"; return 1; }
  [ "$elapsed" -le 7 ] || { echo "idle cancellation took ${elapsed}s; configured idle wall time was 2s"; return 1; }
)

t12_status_call_is_clipped_to_hard_dispatch_budget() (
  local output="$TEST_ROOT/hard-status-bound.out" calls="$TEST_ROOT/hard-status-calls.log"
  local call_out="$TEST_ROOT/hard-status.stdout"
  local call_err="$TEST_ROOT/hard-status.stderr"
  local started elapsed rc
  : > "$calls"
  unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
  started=$SECONDS
  MAESTRO_TEST_CALL_LOG="$calls" \
    MAESTRO_TEST_STATUS_HANG=4 \
    MAESTRO_COMPANION_TIMEOUT_SEC=5 \
    MAESTRO_MAX_DISPATCH_SEC=2 \
    companion_poll "$FIXTURE" task-hardbound-aaaaaa 60 1 \
      "$SECONDS" read "" : "$call_out" "$call_err" > "$output" 2>&1 3>&1
  rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || { echo "rc=$rc want read-only deadline 124"; return 1; }
  [ "$elapsed" -le 4 ] || { echo "elapsed=${elapsed}s exceeded the 2s hard budget by an unbounded status call"; return 1; }
  grep -q '^cancel task-hardbound-aaaaaa$' "$calls" || { echo "deadline did not cancel the job"; return 1; }
  grep -q 'reason=deadline' "$output" || { echo "hard bound was not classified as deadline"; return 1; }
)

t13_cancellation_writes_one_terminal_fact() (
  local fact="$TEST_ROOT/cancel.fact" events="$TEST_ROOT/cancel.events" rc
  local call_out="$TEST_ROOT/cancel.stdout"
  local call_err="$TEST_ROOT/cancel.stderr"
  unset MAESTRO_CANCEL_REASON MAESTRO_CANCEL_REQUESTED
  companion_call() { : > "$1"; : > "$2"; return 4; }
  lifecycle() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$events"; }
  companion_cancel_job "$FIXTURE" task-cancelfact-aaaaaa deadline /tmp/job.log \
    read "$fact" lifecycle "$call_out" "$call_err"
  rc=$?
  [ "$rc" -eq 124 ] || { echo "rc=$rc want 124"; return 1; }
  [ -f "$fact" ] || { echo "cancellation fact missing"; return 1; }
  grep -q '^job=task-cancelfact-aaaaaa$' "$fact" || { cat "$fact"; return 1; }
  grep -q '^reason=deadline$' "$fact" || { cat "$fact"; return 1; }
  grep -q '^request=unconfirmed$' "$fact" || { cat "$fact"; return 1; }
  grep -q '^source=request$' "$fact" || { cat "$fact"; return 1; }
  [ "$(cat "$events")" = "cancel-begin task-cancelfact-aaaaaa deadline
cancel-end task-cancelfact-aaaaaa deadline" ] ||
    { echo "events=$(tr '\n' '|' < "$events")"; return 1; }
  ! declare -p MAESTRO_CANCEL_REASON MAESTRO_CANCEL_REQUESTED >/dev/null 2>&1 ||
    { echo "cancellation leaked outcome globals"; return 1; }
)

t14_nonzero_status_and_result_are_lost() (
  local output="$TEST_ROOT/nonzero-status.out" calls="$TEST_ROOT/nonzero-status.calls"
  local call_out="$TEST_ROOT/nonzero-status.stdout"
  local call_err="$TEST_ROOT/nonzero-status.stderr"
  local result="$TEST_ROOT/nonzero-result" evidence="$TEST_ROOT/nonzero-result.evidence" rc statuses
  sleep() { command sleep 0.05; }
  : > "$calls"
  MAESTRO_TEST_CALL_LOG="$calls" \
    MAESTRO_TEST_JOB_STATUS_RAW='{"status":"running"}' \
    MAESTRO_TEST_JOB_STATUS_EXIT=1 \
    companion_poll "$FIXTURE" task-status-exit-aaaaaa 2 1 \
      "$SECONDS" read "" : "$call_out" "$call_err" > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 124 ] || { echo "nonzero status rc=$rc want 124"; return 1; }
  statuses=$(grep -c '^status task-status-exit-aaaaaa --json$' "$calls" || true)
  [ "$statuses" -eq 4 ] || { echo "status-loss strikes=$statuses want 4"; return 1; }
  grep -q 'status-lost' "$output" ||
    { echo "nonzero status was not classified status-lost"; return 1; }

  MAESTRO_TEST_RESULT='RESULT: DONE' MAESTRO_TEST_RESULT_EXIT=1 \
    companion_result "$FIXTURE" task-result-exit-aaaaaa : "$result" \
      "$call_out" "$call_err" "$evidence" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 4 ] || { echo "nonzero result rc=$rc want 4"; return 1; }
)

t15_capitalized_terminal_status_completes() (
  local calls="$TEST_ROOT/capitalized.calls"
  local call_out="$TEST_ROOT/capitalized.stdout"
  local call_err="$TEST_ROOT/capitalized.stderr" rc statuses
  sleep() { command sleep 0.05; }
  : > "$calls"
  MAESTRO_TEST_CALL_LOG="$calls" MAESTRO_TEST_JOB_PHASE=Completed \
    companion_poll "$FIXTURE" task-capitalized-aaaaaa 1 1 \
      "$SECONDS" read "" : "$call_out" "$call_err" >/dev/null 2>&1
  rc=$?
  statuses=$(grep -c '^status task-capitalized-aaaaaa --json$' "$calls" || true)
  [ "$rc" -eq 0 ] || { echo "capitalized status rc=$rc want 0"; return 1; }
  [ "$statuses" -eq 1 ] || { echo "capitalized status polls=$statuses want 1"; return 1; }
)

t16_three_segment_job_id_round_trips() (
  local repo="$TEST_ROOT/three-segment-repo" job_file="$TEST_ROOT/three-segment.job"
  local call_out="$TEST_ROOT/three-segment.stdout"
  local call_err="$TEST_ROOT/three-segment.stderr"
  local result="$TEST_ROOT/three-segment.result" evidence="$TEST_ROOT/three-segment.evidence"
  local writers="$TEST_ROOT/three-segment.writers" expected=task-2026-08-abcdef job invalid rc
  git init -q "$repo" || return 1
  (
    cd "$repo" || exit 1
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed
    git add seed
    git commit -q -m init
  ) || return 1
  cd "$repo" || exit 1
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire unknown >/dev/null 2>&1 || return 1
  MAESTRO_TEST_TASK_ID="$expected" companion_start "$FIXTURE" objective write \
    gpt-5.6-sol high : "$job_file" "$call_out" "$call_err" || return 1
  job=$(cat "$job_file")
  [ "$job" = "$expected" ] || { echo "extracted job=$job want $expected"; return 1; }
  MAESTRO_TEST_JOB_PHASE=completed companion_verify_pin "$FIXTURE" "$job" \
    gpt-5.6-sol high : "$call_out" "$call_err" || return 1
  _write_lease_turn_event started "$job" dispatch "$result" "$evidence"; rc=$?
  [ "$rc" -eq 0 ] || { echo "started-event job id rc=$rc want 0"; return 1; }
  grep -qx "job_id=$expected" "$repo/.git/maestro-write.lock/metadata" ||
    { echo "started-event did not publish the full id"; return 1; }
  printf '%s\n' "{\"running\":[{\"id\":\"$expected\",\"write\":true}],\"latestFinished\":null}" \
    > "$TEST_ROOT/three-segment.status"
  MAESTRO_TEST_STATUS="$TEST_ROOT/three-segment.status" \
    companion_workspace_writers "$FIXTURE" "$writers" "$call_err" || return 1
  [ "$(cat "$writers")" = "$expected"$'\ttrue' ] ||
    { echo "writer validator rejected or changed the full id"; return 1; }
  for invalid in task-ABC-def task-bad_id; do
    _write_lease_turn_event started "$invalid" dispatch "$result" "$evidence"; rc=$?
    [ "$rc" -eq 3 ] || { echo "started-event accepted invalid id=$invalid"; return 1; }
    printf '%s\n' "{\"running\":[{\"id\":\"$invalid\",\"write\":true}]}" \
      > "$TEST_ROOT/three-segment.status"
    MAESTRO_TEST_STATUS="$TEST_ROOT/three-segment.status" \
      companion_workspace_writers "$FIXTURE" "$writers" "$call_err" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 4 ] || { echo "writer validator accepted invalid id=$invalid"; return 1; }
  done
)

t17_repeated_instant_exit_is_reaped() (
  local out="$TEST_ROOT/instant-exit.out" err="$TEST_ROOT/instant-exit.err"
  local i rc
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
    21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    process_run_bounded 1 TEST_INSTANT : "$out" "$err" -- bash -c 'exit 0'
    rc=$?
    [ "$rc" -eq 0 ] ||
      { echo "instant exit $i rc=$rc want 0"; return 1; }
  done
)

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then
    ok "$label"
  else
    bad "$label" "${detail:-no detail}"
  fi
}

printf '=== Bounded companion calls verification ===\n'
check t0_process_module_contract "deep process module owns bounded output and rc"
check t0b_companion_module_contract "companion interface requires an explicit mode"
check t0c_failed_started_publication_cancels_job "failed launch publication cancels the unpublished job"
check t0e_role_dispatch_uses_pinned_models "read and write dispatches use their pinned models"
check t0f_matching_top_level_effort_omits_write_flag "matching top-level effort omits the write effort flag"
check t0g_mismatched_top_level_effort_refuses_write "mismatched top-level effort refuses the write dispatch"
check t0d_read_interrupt_never_cancels_unknown_writer "read interrupt never cancels an unknown writer"
check t1_hanging_status_is_bounded "hanging status honors the companion timeout"
check t2_timeout_reaps_process_group "timeout returns 125 and reaps the process group"
check t3_run_bounded_returns_wrapped_rc "bounded runner preserves stdout and command rc"
check t4_invalid_companion_timeout_falls_back "invalid companion timeout falls back to 120s"
check t5_repo_digest_survives_refactor "bounded repository digest still returns tree-v2"
check t6_poll_hanging_status_is_bounded "poll loop bounds repeated hanging statuses"
check t7_fast_status_has_no_one_second_floor "five fast status calls finish under two seconds"
check t8_explicit_read_ignores_inherited_lease "explicit read mode ignores inherited Lease interval state"
check t9_failed_start_cannot_publish_a_task_id "failed start cannot publish a phantom task id"
check t10_dispatch_budget_resolution "dispatch budgets resolve by mode and preserve explicit values"
check t11_idle_uses_elapsed_time_not_poll_count "idle timeout uses elapsed wall time, not configured poll counts"
check t12_status_call_is_clipped_to_hard_dispatch_budget "status calls cannot extend the hard dispatch budget by their full timeout"
check t13_cancellation_writes_one_terminal_fact "cancellation produces one caller-owned terminal fact"
check t14_nonzero_status_and_result_are_lost "nonzero status and result calls fail closed despite parseable output"
check t15_capitalized_terminal_status_completes "capitalized terminal status is normalized once"
check t16_three_segment_job_id_round_trips "three-segment job ids round-trip without truncation"
check t17_repeated_instant_exit_is_reaped "repeated instant exits cannot wedge bounded polling"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
