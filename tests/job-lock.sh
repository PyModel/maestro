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

prepare_generation() { # lock [generation]
  local lock="$1" generation="${2-}"
  mkdir -p "$lock" || return 1
  if [ -z "$generation" ]; then
    [ ! -f "$lock/generation" ] || return 0
    generation=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  fi
  printf '%s\n' "$generation" > "$lock/generation"
}

sync_metadata_generation() { # lock
  local lock="$1" generation temp
  generation=$(cat "$lock/generation") || return 1
  temp="$lock/metadata.generation"
  awk -v generation="$generation" '
    BEGIN { written = 0 }
    /^generation=/ {
      if (!written) print "generation=" generation
      written = 1
      next
    }
    { print }
    END { if (!written) print "generation=" generation }
  ' "$lock/metadata" > "$temp" || return 1
  command mv "$temp" "$lock/metadata"
}
status_running() {
  printf '{"running":[{"id":"%s","write":%s}],"latestFinished":null}\n' \
    "$2" "$3" > "$1"
}
no_job_lock_generation_siblings() { # lock
  local lock="$1" candidate
  for candidate in "$lock".reclaim.* "$lock".release.*; do
    [ ! -e "$candidate" ] ||
      { echo "companion job lock left a generation sibling: $candidate"; return 1; }
  done
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
  local generation
  lock=$(lock_path "$repo")
  prepare_generation "$lock" || return 1
  generation=$(cat "$lock/generation") || return 1
  {
    printf 'token=%s\n' "$token"
    printf 'generation=%s\n' "$generation"
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
  prepare_generation "$lock" || return 1
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
  prepare_generation "$lock" || return 1
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
  kill -0 "$waiter" 2>/dev/null ||
    { echo "young-lock contender did not wait: $(tr '\n' ' ' < "$repo/waiter.out")"; return 1; }
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
  lock=$(lock_path "$repo"); prepare_generation "$lock" || return 1; : > "$lock/metadata"
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

t7_dead_holder_uses_global_quiescence() (
  local repo="$TEST_ROOT/t7" lock output pid
  new_repo "$repo"
  lock=$(lock_path "$repo")
  "$REAL_NODE" -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      running: [],
      latestFinished: null,
      padding: " ".repeat(256 * 1024)
    }));
  ' "$repo/status.json" || return 1
  write_metadata "$repo" dead-holder 999999 session-dead-holder write task-dead-holder
  output="$repo/clear.out"
  set -m
  (
    cd "$repo" || exit 1
    exec env HOME="$HOME_DIR" PATH="$TEST_PATH" \
      MAESTRO_TEST_JOB_PHASE=running \
      MAESTRO_TEST_JOB_STATUS_EXIT=1 \
      MAESTRO_TEST_STATUS="$repo/status.json" \
      bash "$LOOP" --clear-job-lock
  ) > "$output" 2>&1 3>&1 &
  pid=$!
  PIDS="$PIDS $pid"
  set +m
  wait_turn "$pid" 4
  [ "$TURN_RC" -eq 0 ] ||
    { echo "dead-holder clear rc=$TURN_RC want 0: $(tr '\n' ' ' < "$output")"; return 1; }
  [ ! -d "$lock" ] ||
    { echo "dead-holder lock survived global quiescence"; return 1; }
  grep -q '^MAESTRO_FINAL: LOOP CLEARED rc=0$' "$output" ||
    { echo "dead-holder clear final missing: $(tr '\n' ' ' < "$output")"; return 1; }
)

t8_generation_claim_serializes_reclaimers() (
  local repo="$TEST_ROOT/t8" lock state shim real_mv a_out b_out a_pid a_rc b_rc token
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  state="$repo/state"
  shim="$repo/shim"
  mkdir -p "$state" "$shim"
  status_empty "$repo/status.json"
  write_metadata "$repo" old-generation 999999 session-old write task-old0000-aaaaaa
  real_mv=$(command -v mv)
  cat > "$shim/mv" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "$lock" ]; then
  : > "$state/before-move"
  while [ ! -e "$state/allow-move" ]; do sleep 0.05; done
  "$real_mv" "\$@"
  rc=\$?
  : > "$state/after-move"
  while [ ! -e "$state/allow-cleanup" ]; do sleep 0.05; done
  exit "\$rc"
fi
exec "$real_mv" "\$@"
EOF
  chmod +x "$shim/mv"
  a_out="$repo/a.out"
  (
    cd "$repo" || exit 1
    exec env HOME="$HOME_DIR" PATH="$shim:$TEST_PATH" \
      MAESTRO_TEST_JOB_PHASE=completed \
      MAESTRO_TEST_JOB_STATUS_EXIT=0 \
      MAESTRO_TEST_STATUS="$repo/status.json" \
      bash "$LOOP" --clear-job-lock
  ) > "$a_out" 2>&1 3>&1 &
  a_pid=$!
  PIDS="$PIDS $a_pid"
  wait_for 5 test -e "$state/before-move" ||
    { echo "first reclaimer did not reach atomic move: $(tr '\n' ' ' < "$a_out")"; return 1; }

  b_out="$repo/b.out"
  run_clear "$repo" "$b_out" completed 0; b_rc=$?
  [ "$b_rc" -eq 11 ] ||
    { echo "second reclaimer rc=$b_rc want 11: $(tr '\n' ' ' < "$b_out")"; return 1; }
  [ -f "$lock/metadata" ] ||
    { echo "second reclaimer removed the claimed generation"; return 1; }

  : > "$state/allow-move"
  wait_for 5 test -e "$state/after-move" ||
    { echo "first reclaimer did not atomically move the lock"; return 1; }
  write_metadata "$repo" successor 999998 session-successor write task-successor-aaaaaa
  : > "$state/allow-cleanup"
  wait_turn "$a_pid" 10
  a_rc=$TURN_RC
  [ "$a_rc" -eq 11 ] ||
    { echo "first reclaimer rc=$a_rc want 11 after successor: $(tr '\n' ' ' < "$a_out")"; return 1; }
  token=$(sed -n 's/^token=//p' "$lock/metadata")
  [ "$token" = successor ] ||
    { echo "successor generation was removed or changed (token=${token:-missing})"; return 1; }
  no_job_lock_generation_siblings "$lock" || return 1
)

t9_orphan_identity_fences_successor_publication() (
  local repo="$TEST_ROOT/t9" lock rc result evidence probe_a probe_b
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  prepare_generation "$lock" || return 1
  (
    cd "$repo" || exit 1
    . "$COMPANION_LIB"
    progress_init
    result="$repo/result"
    evidence="$repo/evidence"
    job_lock_workspace_jobs() {
      rm -rf "$lock"
      prepare_generation "$lock" || return 1
      touch -t 202001010000 "$lock"
      printf -v "$1" '%s' ""
      return 0
    }
    job_lock_clear "$result" "$evidence" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" -eq 11 ] || { echo "orphan clear rc=$rc want 11"; return 1; }
  [ -d "$lock" ] || { echo "successor publication directory was removed"; return 1; }
  probe_a=$(mktemp -d "$repo/identity-a.XXXXXX") || return 1
  probe_b=$(mktemp -d "$repo/identity-b.XXXXXX") || return 1
  prepare_generation "$probe_a" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || return 1
  prepare_generation "$probe_b" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || return 1
  . "$COMPANION_LIB"
  [ "$(job_lock_path_identity "$probe_a")" != "$(job_lock_path_identity "$probe_b")" ] ||
    { echo "directory identity helper does not distinguish generations"; return 1; }
  [ ! -e "$lock/metadata" ] ||
    { echo "successor unexpectedly published metadata"; return 1; }
)
t10_publication_claim_blocks_concurrent_clear() (
  local repo="$TEST_ROOT/t10" lock identity generation record state publisher rc result evidence
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  state="$repo/interleave"
  result="$repo/clear.result"
  evidence="$repo/clear.evidence"
  mkdir -p "$state"
  prepare_generation "$lock" || return 1
  . "$COMPANION_LIB"
  cd "$repo" || exit 1
  progress_init
  identity=$(job_lock_path_identity "$lock") || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=publisher\ngeneration=%s\npid=999999\nsession=test\nclass=write\nstart=1\njob=task-publisher-aaaaaa' "$generation")
  (
    mv() {
      command mv "$@" || return
      case "$*" in
        *"$lock/metadata")
          : > "$state/metadata-moved"
          while [ ! -e "$state/finish-publication" ]; do sleep 0.05; done
          ;;
      esac
    }
    job_lock_publish_metadata "$lock" "$identity" publisher "$record"
  ) > "$state/publisher.out" 2>&1 &
  publisher=$!
  if ! wait_for 5 test -e "$state/metadata-moved"; then
    : > "$state/finish-publication"
    wait "$publisher" 2>/dev/null || :
    echo "publisher did not reach its final metadata check"
    return 1
  fi
  job_lock_job_state() { printf -v "$2" '%s' completed; }
  job_lock_clear "$result" "$evidence" > "$state/clear.out" 2>&1 3>&1
  rc=$?
  : > "$state/finish-publication"
  wait "$publisher" || { echo "publisher failed after the clearer was refused"; return 1; }
  [ "$rc" -eq 11 ] || { echo "concurrent clear rc=$rc want 11"; return 1; }
  grep -q 'generation claim is unavailable' "$state/clear.out" ||
    { echo "clear did not contend on the publisher claim"; return 1; }
  [ "$(job_lock_metadata_value "$lock/metadata" token)" = publisher ] ||
    { echo "publisher lost ownership after concurrent clear"; return 1; }
)
t11_valid_clear_identity_fences_same_token_successor() (
  local repo="$TEST_ROOT/t11" lock old replacement result evidence rc
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  old="$lock.observed"
  replacement="$lock.successor"
  result="$repo/result"
  evidence="$repo/evidence"
  write_metadata "$repo" replayed 999999 session-replayed write task-replayed-aaaaaa
  (
    cd "$repo" || exit 1
    . "$COMPANION_LIB"
    progress_init
    stat() { printf '7:42\n'; }
    job_lock_job_state() {
      command mkdir "$replacement" || return 1
      command cp "$lock/metadata" "$replacement/metadata" || return 1
      prepare_generation "$replacement" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || return 1
      sync_metadata_generation "$replacement" || return 1
      command mv "$lock" "$old" || return 1
      command mv "$replacement" "$lock" || return 1
      printf -v "$2" '%s' completed
      return 0
    }
    job_lock_clear "$result" "$evidence" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" -eq 11 ] || { echo "same-token job clear rc=$rc want 11"; return 1; }
  [ -f "$lock/generation" ] ||
    { echo "same-token job-lock successor was removed by clear"; return 1; }
  [ "$(sed -n 's/^token=//p' "$lock/metadata")" = replayed ] ||
    { echo "same-token job-lock successor metadata changed"; return 1; }
  no_job_lock_generation_siblings "$lock" || return 1
)

t12_release_identity_fences_same_token_successor() (
  local repo="$TEST_ROOT/t12" lock old replacement state token
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  old="$lock.observed"
  replacement="$lock.successor"
  state="$repo/replaced"
  (
    cd "$repo" || exit 1
    . "$COMPANION_LIB"
    progress_init
    stat() { printf '7:42\n'; }
    job_lock_acquire write >/dev/null 2>&1 || return 1
    token=$MAESTRO_JOB_LOCK_TOKEN
    claim_checks=0
    lock_claim_current_matches() {
      local lock_dir="$1" identity="$2" requested_token="$3"
      local current_identity current_token
      claim_checks=$((claim_checks + 1))
      if [ "$claim_checks" -eq 2 ] && [ ! -e "$state" ]; then
        : > "$state" || return 1
        command mkdir "$replacement" || return 1
        command cp "$lock/metadata" "$replacement/metadata" || return 1
        prepare_generation "$replacement" cccccccccccccccccccccccccccccccc || return 1
        sync_metadata_generation "$replacement" || return 1
        command mv "$lock" "$old" || return 1
        command mv "$replacement" "$lock" || return 1
      fi
      current_identity=$(job_lock_path_identity "$lock_dir") || return 1
      [ "$current_identity" = "$identity" ] || return 1
      current_token=$(job_lock_metadata_value "$lock_dir/metadata" token)
      [ -z "$current_token" ] || [ "$current_token" = "$requested_token" ]
    }
    job_lock_release
    [ -f "$lock/generation" ] ||
      { echo "same-token job-lock successor was removed by release"; return 1; }
    [ "$(job_lock_metadata_value "$lock/metadata" token)" = "$token" ] ||
      { echo "same-token job-lock successor metadata changed during release"; return 1; }
    [ "$MAESTRO_JOB_LOCK_ACQUIRED" -eq 1 ] ||
      { echo "release dropped local ownership after rejecting a changed generation"; return 1; }
    no_job_lock_generation_siblings "$lock"
  )
)
t13_job_publication_fences_acquisition_identity() (
  local repo="$TEST_ROOT/t13" lock old replacement rc
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  old="$lock.acquired"
  replacement="$lock.successor"
  (
    cd "$repo" || exit 1
    . "$COMPANION_LIB"
    progress_init
    stat() { printf '7:42\n'; }
    job_lock_acquire write >/dev/null 2>&1 || return 1
    command mkdir "$replacement" || return 1
    command cp "$lock/metadata" "$replacement/metadata" || return 1
    prepare_generation "$replacement" dddddddddddddddddddddddddddddddd || return 1
    sync_metadata_generation "$replacement" || return 1
    command mv "$lock" "$old" || return 1
    command mv "$replacement" "$lock" || return 1
    job_lock_publish_job task-replayed-aaaaaa >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || { echo "same-token job publication rc=$rc want 3"; return 1; }
    [ -f "$lock/generation" ] ||
      { echo "same-token publication successor disappeared"; return 1; }
    ! grep -q '^job=' "$lock/metadata" ||
      { echo "job id was published into a replacement generation"; return 1; }
  )
)

t14_killed_publisher_claim_is_recoverable() (
  local repo="$TEST_ROOT/t14" lock identity generation record state publisher child result evidence rc
  local shim real_mv
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  state="$repo/interleave"
  result="$repo/clear.result"
  evidence="$repo/clear.evidence"
  mkdir -p "$state"
  shim="$state/shim"
  real_mv=$(command -v mv) || return 1
  mkdir -p "$shim"
  cat > "$shim/mv" <<EOF
#!/bin/sh
"$real_mv" "\$@" || exit
case "\$*" in
  *"$lock/metadata")
    sleep 10 &
    printf '%s\n' "\$!" > "$state/child.pid"
    wait "\$!"
    ;;
esac
EOF
  chmod +x "$shim/mv"
  prepare_generation "$lock" || return 1
  . "$COMPANION_LIB"
  cd "$repo" || exit 1
  progress_init
  identity=$(job_lock_path_identity "$lock") || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=publisher\ngeneration=%s\npid=999999\nsession=test\nclass=write\nstart=1\njob=task-publisher-aaaaaa' "$generation")
  (
    export PATH="$shim:$PATH"
    job_lock_publish_metadata "$lock" "$identity" publisher "$record"
  ) > "$state/publisher.out" 2>&1 &
  publisher=$!
  wait_for 5 test -s "$state/child.pid" ||
    { echo "publisher did not enter its fenced metadata update"; return 1; }
  child=$(cat "$state/child.pid")
  kill -KILL "$publisher" 2>/dev/null || return 1
  wait "$publisher" 2>/dev/null || :
  kill -0 "$child" 2>/dev/null ||
    { echo "blocked publication child exited before claim recovery"; return 1; }
  job_lock_job_state() { printf -v "$2" '%s' completed; }
  job_lock_clear "$result" "$evidence" > "$state/clear.out" 2>&1 3>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    kill "$child" 2>/dev/null || :
    echo "clear could not recover killed publisher claim: $(tr '\n' ' ' < "$state/clear.out")"
    return 1
  fi
  [ ! -d "$lock" ] ||
    { echo "killed publisher generation survived operator clear"; return 1; }
  kill "$child" 2>/dev/null || :
  no_job_lock_generation_siblings "$lock"
)

t15_platform_backend_is_deterministic() (
  local repo="$TEST_ROOT/t15" lock identity generation record marker platform expected
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  marker="$repo/wrong-backend"
  prepare_generation "$lock" || return 1
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  platform=$(uname -s)
  case "$platform" in
    Darwin|FreeBSD|NetBSD|OpenBSD)
      expected=lockf
      flock() { : > "$marker"; return 1; }
      ;;
    Linux)
      expected=flock
      lockf() { : > "$marker"; return 1; }
      ;;
    *) echo "unsupported claim backend platform: $platform"; return 1 ;;
  esac
  [ "$_MAESTRO_LOCK_CLAIM_BACKEND" = "$expected" ] ||
    { echo "claim backend=$_MAESTRO_LOCK_CLAIM_BACKEND want $expected"; return 1; }
  identity=$(job_lock_path_identity "$lock") || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=backend\ngeneration=%s\npid=999999\nsession=test\nclass=write\nstart=1' "$generation")
  job_lock_publish_metadata "$lock" "$identity" backend "$record" ||
    { echo "selected claim backend could not publish metadata"; return 1; }
  [ ! -e "$marker" ] ||
    { echo "PATH-only alternate backend was selected"; return 1; }
)

t16_claim_gate_uses_the_requested_lock_path() (
  local repo_a="$TEST_ROOT/t16-a" repo_b="$TEST_ROOT/t16-b" lock gate expected
  new_repo "$repo_a"
  new_repo "$repo_b"
  repo_a=$(cd "$repo_a" && pwd -P)
  repo_b=$(cd "$repo_b" && pwd -P)
  lock=$(lock_path "$repo_a")
  expected="${lock%/*}/maestro-generation-claim.lock"
  cd "$repo_b" || exit 1
  . "$COMPANION_LIB"
  gate=$(lock_claim_gate_path "$lock") || return 1
  [ "$gate" = "$expected" ] ||
    { echo "claim gate followed cwd: got=$gate want=$expected"; return 1; }
)

t17_acquisition_waits_for_the_generation_gate() (
  local repo="$TEST_ROOT/t17" lock gate state holder acquirer rc
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  state="$repo/gate-state"
  mkdir -p "$state"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  gate=$(lock_claim_gate_path "$lock") || return 1
  (
    lock_claim_gate_acquire "$gate" || exit 1
    : > "$state/ready"
    while [ ! -e "$state/release" ]; do sleep 0.05; done
    lock_claim_unlock
  ) &
  holder=$!
  wait_for 5 test -e "$state/ready" ||
    { echo "generation gate holder did not start"; return 1; }
  (
    export MAESTRO_LOCK_WAIT_SEC=3 MAESTRO_LOCK_WAIT_POLL_SEC=1
    job_lock_acquire write
    rc=$?
    printf '%s\n' "$rc" > "$state/acquire.rc"
    if [ "$rc" -eq 0 ]; then job_lock_release; fi
    exit "$rc"
  ) > "$state/acquire.out" 2>&1 3>&1 &
  acquirer=$!
  sleep 0.3
  if [ -d "$lock" ]; then
    : > "$state/bypassed"
  fi
  : > "$state/release"
  wait "$holder" || return 1
  wait "$acquirer"
  rc=$?
  [ "$rc" -eq 0 ] ||
    { echo "acquisition after gate release rc=$rc: $(tr '\n' ' ' < "$state/acquire.out")"; return 1; }
  [ ! -e "$state/bypassed" ] ||
    { echo "acquisition created the lock while the generation gate was held"; return 1; }
  [ ! -d "$lock" ] ||
    { echo "acquisition left a lock generation behind"; return 1; }
)

t18_generation_gate_preserves_caller_fd19() (
  local repo="$TEST_ROOT/t18" lock output identity generation record
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  output="$repo/caller-fd19"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  exec 19>> "$output" || return 1
  printf 'before\n' >&19 || return 1
  lock_claim_create "$lock" identity ||
    { echo "could not create generation under caller fd19"; return 1; }
  [ -n "$identity" ] || return 1
  generation=$(cat "$lock/generation") || return 1
  record=$(printf 'token=fd19\ngeneration=%s\npid=999999\nsession=test\nclass=write\nstart=1' "$generation")
  job_lock_publish_metadata "$lock" "$identity" fd19 "$record" ||
    { echo "could not publish metadata under caller fd19"; return 1; }
  printf 'after-publish\n' >&19 ||
    { echo "metadata publication closed caller fd19"; return 1; }
  lock_claim_acquire "$lock" "$identity" fd19 ||
    { echo "could not reacquire generation under caller fd19"; return 1; }
  lock_claim_release "$lock" "$identity" fd19 ||
    { echo "could not release generation claim under caller fd19"; return 1; }
  printf 'after-release\n' >&19 ||
    { echo "claim release closed caller fd19"; return 1; }
  exec 19>&-
  [ "$(cat "$output")" = "$(printf 'before\nafter-publish\nafter-release')" ] ||
    { echo "caller fd19 content was not preserved"; return 1; }
)

t19_failed_publication_retirement_blocks() (
  local repo lock output rc
  repo="$TEST_ROOT/t19"
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  output="$repo/acquire.out"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  mv() {
    case "$*" in
      *"$lock/metadata.tmp."*"$lock/metadata"|*"$lock $lock.reclaim."*) return 1 ;;
    esac
    command mv "$@"
  }
  job_lock_acquire read > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "failed publication retirement rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$lock" ] ||
    { echo "failed retirement unexpectedly removed the canonical generation"; return 1; }
  [ "$MAESTRO_JOB_LOCK_ACQUIRED" -eq 0 ] ||
    { echo "failed publication granted local ownership"; return 1; }
  grep -q 'could not be retired' "$output" ||
    { echo "failed retirement diagnostic missing"; return 1; }
)

t20_identity_failure_retirement_blocks() (
  local repo lock output rmdir_called rc
  repo="$TEST_ROOT/t20"
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  output="$repo/acquire.out"
  rmdir_called="$repo/rmdir.called"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  lock_claim_path_identity() { return 1; }
  rmdir() { : > "$rmdir_called"; return 1; }
  job_lock_acquire read > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 11 ] ||
    { echo "identity failure retirement rc=$rc want 11: $(tr '\n' ' ' < "$output")"; return 1; }
  [ -d "$lock" ] ||
    { echo "identity failure unexpectedly removed the canonical generation"; return 1; }
  [ ! -e "$rmdir_called" ] ||
    { echo "identity failure attempted an unfenced rmdir"; return 1; }
  grep -q 'generation initialization failed.*retaining fail-closed lock' "$output" ||
    { echo "identity failure diagnostic missing"; return 1; }
)

t21_token_failure_precedes_creation() (
  local repo lock output rc
  repo="$TEST_ROOT/t21"
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  output="$repo/acquire.out"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  od() { return 1; }
  job_lock_acquire read > "$output" 2>&1
  rc=$?
  [ "$rc" -eq 3 ] ||
    { echo "token generation failure rc=$rc want 3: $(tr '\n' ' ' < "$output")"; return 1; }
  [ ! -e "$lock" ] ||
    { echo "token generation failure created a canonical lock"; return 1; }
)

t22_post_move_unlock_failure_does_not_reclassify_release() (
  local repo lock output rc
  repo="$TEST_ROOT/t22"
  new_repo "$repo"
  repo=$(cd "$repo" && pwd -P)
  lock=$(lock_path "$repo")
  output="$repo/release.out"
  cd "$repo" || exit 1
  . "$COMPANION_LIB"
  progress_init
  job_lock_acquire read >/dev/null 2>&1 || return 1
  lock_claim_unlock() {
    exec 19>&-
    return 1
  }
  job_lock_release > "$output" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 0 ] ||
    { echo "post-move unlock failure rc=$rc want 0: $(tr '\n' ' ' < "$output")"; return 1; }
  [ ! -d "$lock" ] ||
    { echo "post-move unlock failure left the canonical generation"; return 1; }
  grep -q 'canonical lock retired; generation gate cleanup failed' "$output" ||
    { echo "post-move unlock failure diagnostic missing"; return 1; }
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
check t7_dead_holder_uses_global_quiescence "dead holders clear after bounded global quiescence"
check t9_orphan_identity_fences_successor_publication "orphan identity fence preserves initializing successors"
check t10_publication_claim_blocks_concurrent_clear "metadata publisher excludes a clearer through its final check"
check t15_platform_backend_is_deterministic "claim backend selection is platform-stable"
check t16_claim_gate_uses_the_requested_lock_path "generation gate is derived from the requested lock path"
check t17_acquisition_waits_for_the_generation_gate "lock creation waits for the generation gate"
check t18_generation_gate_preserves_caller_fd19 "generation claims preserve caller fd 19"
check t11_valid_clear_identity_fences_same_token_successor "valid clear fences same-token replacement generations"
check t12_release_identity_fences_same_token_successor "release fences same-token replacement generations"
check t13_job_publication_fences_acquisition_identity "job publication is fenced to the acquired directory identity"
check t14_killed_publisher_claim_is_recoverable "killed publisher claims are recoverable"
check t19_failed_publication_retirement_blocks "failed publication blocks when its generation cannot retire"
check t20_identity_failure_retirement_blocks "identity failure blocks when its generation cannot retire"
check t21_token_failure_precedes_creation "token generation fails before canonical creation"
check t22_post_move_unlock_failure_does_not_reclassify_release "post-move gate cleanup failure does not reclassify release"
check t8_generation_claim_serializes_reclaimers "generation claims serialize reclaimers and preserve successors"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
