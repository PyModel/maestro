#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANION_LIB="$ROOT/hooks/lib-companion.sh"
LOOP="$ROOT/hooks/implementer-loop.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
REAL_NODE=$(node -p 'process.execPath')
TEST_ROOT=$(mktemp -d /tmp/maestro-job-lock.XXXXXXXX)
PIDS=""
cleanup() {
  local pid
  for pid in $PIDS; do
    kill -KILL "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
TURN_PID=""
TURN_RC=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

HOME_DIR="$TEST_ROOT/home"
SHIM="$TEST_ROOT/shim"
COMPANION="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
mkdir -p "$SHIM" "$(dirname "$COMPANION")" "$HOME_DIR/.codex"
: > "$COMPANION"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "-e" ]; then exec "%s" "$@"; fi\n' "$REAL_NODE"
  printf 'shift\n'
  printf 'exec "%s" "%s" "$@"\n' "$REAL_NODE" "$FIXTURE"
} > "$SHIM/node"
chmod +x "$SHIM/node"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$HOME_DIR/.codex/config.toml"
printf 'high\n' > "$HOME_DIR/.codex/maestro-impl-effort"
TEST_PATH="$SHIM:$PATH"

new_repo() {
  mkdir -p "$1"
  git init -q "$1"
}

lock_path() { printf '%s/.git/maestro-job-lock' "$1"; }
status_empty() { printf '{"running":[],"latestFinished":null}\n' > "$1"; }
status_running() {
  printf '{"running":[{"id":"%s","write":%s}],"latestFinished":null}\n' \
    "$2" "$3" > "$1"
}

wait_for() { # seconds command...
  local limit="$1" i=0
  shift
  while ! "$@"; do
    [ "$i" -lt $((limit * 10)) ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
}

wait_for_job_metadata() { grep -q '^job=' "$1" 2>/dev/null; }

start_turn() { # repo mode output task-ids flag start-log wait-sec
  local repo="$1" mode="$2" output="$3" ids="$4" flag="$5" starts="$6" wait_sec="$7"
  (
    cd "$repo" || exit 1
    exec env HOME="$HOME_DIR" PATH="$TEST_PATH" \
      MAESTRO_LOCK_WAIT_SEC="$wait_sec" MAESTRO_LOCK_WAIT_POLL_SEC=1 \
      MAESTRO_TEST_TASK_ID_FILE="$ids" \
      MAESTRO_TEST_JOB_TERMINAL_FLAG="$flag" \
      MAESTRO_TEST_JOB_START_LOG="$starts" \
      MAESTRO_TEST_STATUS="$repo/status.json" \
      COMPANION_LIB="$COMPANION_LIB" bash -c '
        set -uo pipefail
        . "$COMPANION_LIB"
        progress_init
        lifecycle() { return 0; }
        prompt="$PWD/prompt.$$.md"
        result="$PWD/result.$$"
        profile="$PWD/profile.$$"
        evidence="$PWD/evidence.$$"
        printf "objective\n" > "$prompt"
        callback=:
        [ "$1" = read ] || callback=lifecycle
        companion_turn "$1" "$prompt" 20 1 "$result" "$profile" "$evidence" "$callback"
      ' _ "$mode"
  ) > "$output" 2>&1 3>&1 &
  TURN_PID=$!
  PIDS="$PIDS $TURN_PID"
}

wait_turn() { # pid limit
  local pid="$1" limit="$2" i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((limit * 10)) ]; then
      kill -KILL "$pid" 2>/dev/null || :
      wait "$pid" 2>/dev/null || :
      TURN_RC=124
      return
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  TURN_RC=$?
}

run_completed_turn() { # repo mode id name
  local repo="$1" mode="$2" id="$3" name="$4" ids flag starts output pid
  ids="$repo/$name.ids"
  flag="$repo/$name.terminal"
  starts="$repo/$name.starts"
  output="$repo/$name.out"
  printf '%s\n' "$id" > "$ids"
  : > "$flag"
  : > "$starts"
  start_turn "$repo" "$mode" "$output" "$ids" "$flag" "$starts" 3
  pid=$TURN_PID
  wait_turn "$pid" 8
  [ "$TURN_RC" -eq 0 ] || { echo "$name rc=$TURN_RC: $(tr '\n' ' ' < "$output")"; return 1; }
}

run_clear() { # repo output phase status-exit
  local repo="$1" output="$2" phase="$3" status_exit="$4"
  (
    cd "$repo" || exit 1
    env HOME="$HOME_DIR" PATH="$TEST_PATH" \
      MAESTRO_TEST_JOB_PHASE="$phase" \
      MAESTRO_TEST_JOB_STATUS_EXIT="$status_exit" \
      MAESTRO_TEST_STATUS="$repo/status.json" \
      bash "$LOOP" --clear-job-lock
  ) > "$output" 2>&1 3>&1
}

write_metadata() { # repo token pid session class [job]
  local lock repo="$1" token="$2" pid="$3" session="$4" class="$5" job="${6-}"
  lock=$(lock_path "$repo")
  mkdir -p "$lock"
  {
    printf 'token=%s\n' "$token"
    printf 'pid=%s\n' "$pid"
    printf 'session=%s\n' "$session"
    printf 'class=%s\n' "$class"
    printf 'start=1\n'
    [ -z "$job" ] || printf 'job=%s\n' "$job"
  } > "$lock/metadata"
}

t1_sequential_reads_release() (
  local repo="$TEST_ROOT/t1"
  new_repo "$repo"
  status_empty "$repo/status.json"
  run_completed_turn "$repo" read task-read0000-aaaaaa first || return 1
  [ ! -d "$(lock_path "$repo")" ] || { echo "lock survived first read"; return 1; }
  run_completed_turn "$repo" read task-read0001-bbbbbb second || return 1
  [ ! -d "$(lock_path "$repo")" ] || { echo "lock survived second read"; return 1; }
)

t2_killed_adapter_waits_for_terminal_job() (
  local repo="$TEST_ROOT/t2" ids flag starts first second first_pid second_pid
  local flip_ms second_start count
  repo="$TEST_ROOT/t2"
  new_repo "$repo"
  status_empty "$repo/status.json"
  ids="$repo/ids"; flag="$repo/terminal"; starts="$repo/starts"
  first="$repo/first.out"; second="$repo/second.out"
  printf 'task-settle00-aaaaaa\ntask-settle01-bbbbbb\n' > "$ids"
  : > "$starts"
  start_turn "$repo" read "$first" "$ids" "$flag" "$starts" 8
  first_pid=$TURN_PID
  wait_for 5 test -s "$starts" ||
    { echo "first job did not start: $(tr '\n' ' ' < "$first")"; return 1; }
  wait_for 2 wait_for_job_metadata "$(lock_path "$repo")/metadata" || :
  kill -KILL "$first_pid" 2>/dev/null || return 1
  wait "$first_pid" 2>/dev/null || :

  start_turn "$repo" read "$second" "$ids" "$flag" "$starts" 8
  second_pid=$TURN_PID
  sleep 1
  kill -0 "$second_pid" 2>/dev/null ||
    { echo "second dispatch exited before terminal flip: $(tr '\n' ' ' < "$second")"; return 1; }
  count=$(wc -l < "$starts")
  [ "$count" -eq 1 ] || { echo "second job started before terminal flip (starts=$count)"; return 1; }
  flip_ms=$("$REAL_NODE" -e 'console.log(Date.now())')
  : > "$flag"
  wait_turn "$second_pid" 10
  [ "$TURN_RC" -eq 0 ] || { echo "second rc=$TURN_RC: $(tr '\n' ' ' < "$second")"; return 1; }
  second_start=$(awk 'NR == 2 { print $1 }' "$starts")
  [ -n "$second_start" ] && [ "$second_start" -ge "$flip_ms" ] ||
    { echo "second start=$second_start preceded flip=$flip_ms"; return 1; }
  [ ! -d "$(lock_path "$repo")" ] || { echo "lock survived second completion"; return 1; }
)

t3_malformed_metadata_fails_closed() (
  local repo="$TEST_ROOT/t3" lock ids flag starts output pid rc
  new_repo "$repo"
  status_empty "$repo/status.json"
  lock=$(lock_path "$repo")
  mkdir -p "$lock"
  : > "$lock/metadata"
  ids="$repo/ids"; flag="$repo/terminal"; starts="$repo/starts"; output="$repo/out"
  printf 'task-malform-aaaaaa\n' > "$ids"; : > "$flag"; : > "$starts"
  start_turn "$repo" read "$output" "$ids" "$flag" "$starts" 0
  pid=$TURN_PID
  wait_turn "$pid" 5; rc=$TURN_RC
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  grep -Fq 'bash ~/.claude/hooks/implementer-loop.sh --clear-job-lock' "$output" ||
    { echo "clear command missing: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$lock" ] || { echo "malformed lock was removed"; return 1; }
)

t4_publication_window_is_not_clearable() (
  local repo="$TEST_ROOT/t4" lock waiter clear_out clear_rc
  new_repo "$repo"
  status_empty "$repo/status.json"
  lock=$(lock_path "$repo")
  mkdir -p "$lock"
  (
    cd "$repo" || exit 1
    exec env HOME="$HOME_DIR" PATH="$TEST_PATH" \
      MAESTRO_LOCK_WAIT_SEC=3 MAESTRO_LOCK_WAIT_POLL_SEC=1 \
      COMPANION_LIB="$COMPANION_LIB" bash -c '
        set -uo pipefail
        . "$COMPANION_LIB"
        progress_init
        job_lock_acquire read
      '
  ) > "$repo/waiter.out" 2>&1 3>&1 &
  waiter=$!; PIDS="$PIDS $waiter"
  sleep 0.5
  kill -0 "$waiter" 2>/dev/null || { echo "young-lock contender did not wait"; return 1; }
  clear_out="$repo/clear.out"
  run_clear "$repo" "$clear_out" completed 0; clear_rc=$?
  [ "$clear_rc" -eq 11 ] || { echo "clear rc=$clear_rc want 11: $(tr '\n' ' ' < "$clear_out")"; return 1; }
  [ -d "$lock" ] || { echo "young metadata-less lock was cleared"; return 1; }
  kill -KILL "$waiter" 2>/dev/null || :
  wait "$waiter" 2>/dev/null || :
)

t5_operator_recovery_is_fail_closed() (
  local repo lock output rc holder

  repo="$TEST_ROOT/t5-running"; new_repo "$repo"
  status_running "$repo/status.json" task-running0-aaaaaa true
  write_metadata "$repo" running 999999 session-running write task-running0-aaaaaa
  output="$repo/clear.out"
  run_clear "$repo" "$output" running 0; rc=$?
  [ "$rc" -eq 11 ] || { echo "running clear rc=$rc want 11"; return 1; }
  grep -Fq 'class=write job=task-running0-aaaaaa session=session-running' "$output" ||
    { echo "running holder attribution missing: $(tr '\n' ' ' < "$output")"; return 1; }

  repo="$TEST_ROOT/t5-terminal"; new_repo "$repo"; status_empty "$repo/status.json"
  write_metadata "$repo" terminal 999999 session-terminal read task-terminal-aaaaaa
  output="$repo/clear.out"
  run_clear "$repo" "$output" completed 0; rc=$?
  [ "$rc" -eq 0 ] && [ ! -d "$(lock_path "$repo")" ] ||
    { echo "terminal clear rc=$rc lock=$(test -d "$(lock_path "$repo")" && echo present || echo absent): $(tr '\n' ' ' < "$output")"; return 1; }

  repo="$TEST_ROOT/t5-malformed"; new_repo "$repo"; status_empty "$repo/status.json"
  lock=$(lock_path "$repo"); mkdir -p "$lock"; : > "$lock/metadata"
  touch -t 202001010000 "$lock/metadata"
  output="$repo/clear.out"
  run_clear "$repo" "$output" completed 0; rc=$?
  [ "$rc" -eq 0 ] && [ ! -d "$lock" ] ||
    { echo "malformed clear rc=$rc: $(tr '\n' ' ' < "$output")"; return 1; }

  repo="$TEST_ROOT/t5-unavailable"; new_repo "$repo"
  holder=task-visible0-bbbbbb
  status_running "$repo/status.json" "$holder" true
  write_metadata "$repo" unavailable 999999 session-unavailable write task-unavail0-aaaaaa
  output="$repo/clear.out"
  run_clear "$repo" "$output" running 1; rc=$?
  [ "$rc" -eq 11 ] || { echo "unavailable clear rc=$rc want 11"; return 1; }
  grep -Fq "repository-global job $holder is running" "$output" ||
    { echo "visible global writer missing: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$(lock_path "$repo")" ] || { echo "unavailable-status lock was cleared"; return 1; }
)

t6_read_and_write_turns_serialize() (
  local repo="$TEST_ROOT/t6" ids flag starts read_out write_out read_pid write_pid count
  local flip_ms write_start
  new_repo "$repo"
  status_empty "$repo/status.json"
  ids="$repo/ids"; flag="$repo/terminal"; starts="$repo/starts"
  read_out="$repo/read.out"; write_out="$repo/write.out"
  printf 'task-slowread-aaaaaa\ntask-write000-bbbbbb\n' > "$ids"
  : > "$starts"
  start_turn "$repo" read "$read_out" "$ids" "$flag" "$starts" 8
  read_pid=$TURN_PID
  wait_for 5 wait_for_job_metadata "$(lock_path "$repo")/metadata" ||
    { echo "read job was not published"; return 1; }
  start_turn "$repo" write "$write_out" "$ids" "$flag" "$starts" 8
  write_pid=$TURN_PID
  sleep 1
  count=$(wc -l < "$starts")
  [ "$count" -eq 1 ] || { echo "write started while read was running (starts=$count)"; return 1; }
  kill -0 "$write_pid" 2>/dev/null || { echo "write did not wait"; return 1; }
  flip_ms=$("$REAL_NODE" -e 'console.log(Date.now())')
  : > "$flag"
  wait_turn "$read_pid" 10
  [ "$TURN_RC" -eq 0 ] || { echo "read rc=$TURN_RC: $(tr '\n' ' ' < "$read_out")"; return 1; }
  wait_turn "$write_pid" 10
  [ "$TURN_RC" -eq 0 ] || { echo "write rc=$TURN_RC: $(tr '\n' ' ' < "$write_out")"; return 1; }
  count=$(wc -l < "$starts")
  [ "$count" -eq 2 ] || { echo "starts=$count want 2"; return 1; }
  write_start=$(awk 'NR == 2 { print $1 }' "$starts")
  [ "$write_start" -ge "$flip_ms" ] ||
    { echo "write start=$write_start preceded terminal flip=$flip_ms"; return 1; }
  [ ! -d "$(lock_path "$repo")" ] || { echo "lock survived serialized turns"; return 1; }
)

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Companion job lock verification ===\n'
check t1_sequential_reads_release "sequential read turns release the job lock"
check t2_killed_adapter_waits_for_terminal_job "dead adapters cannot outlive running-job ownership"
check t3_malformed_metadata_fails_closed "malformed metadata blocks with recovery guidance"
check t4_publication_window_is_not_clearable "young metadata-less locks remain protected"
check t5_operator_recovery_is_fail_closed "operator recovery clears only proven-safe locks"
check t6_read_and_write_turns_serialize "read and write companion turns serialize"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
