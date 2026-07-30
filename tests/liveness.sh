#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/hooks/implementer-loop.sh"
DISCUSSION="$ROOT/hooks/discussion-loop.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-liveness.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
WAIT_RC=0
WAIT_TIMED_OUT=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

status_empty() {
  printf '{\n  "running": [],\n  "latestFinished": null\n}\n'
}

status_running_job() {
  printf '{\n  "running": [\n    {\n      "id": "%s",\n      "write": %s\n    }\n  ],\n  "latestFinished": null\n}\n' "$1" "$2"
}

new_repo() {
  local dir="$TEST_ROOT/$1"
  git init -q "$dir"
  (
    cd "$dir" &&
      git config user.email p@p &&
      git config user.name p &&
      printf 'seed\n' > seed.txt &&
      git add seed.txt &&
      git commit -q -m init
  )
  printf '%s' "$dir"
}

wait_bounded() {
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
REAL_MV=$(command -v mv)
TEST_HOME="$TEST_ROOT/home"
SHIM="$TEST_ROOT/shim"
COMPANION="$TEST_HOME/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
mkdir -p "$SHIM" "$(dirname "$COMPANION")" "$TEST_HOME/.codex"
: > "$COMPANION"
{
  printf '#!/usr/bin/env bash\n'
  printf 'shift\n'
  printf 'exec "%s" "%s" "$@"\n' "$REAL_NODE" "$FIXTURE"
} > "$SHIM/node"
chmod +x "$SHIM/node"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$TEST_HOME/.codex/config.toml"
printf 'high\n' > "$TEST_HOME/.codex/maestro-impl-effort"
printf 'Objective: exercise liveness.\n' > "$TEST_ROOT/plan.md"
TEST_PATH="$SHIM:$PATH"
export MAESTRO_LOCK_WAIT_SEC=0

t1_deadline_growing_log() {
  local repo state pid started elapsed
  repo=$(new_repo deadline-repo)
  state="$TEST_ROOT/deadline-state"
  mkdir -p "$state"
  : > "$state/job.log"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  started=$(date +%s)
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=6 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 4 --max-idle 30 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 11
  elapsed=$(( $(date +%s) - started ))
  printf '%s\n' "$WAIT_RC" > "$state/loop.rc"
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "dispatch exceeded 11s bound"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
  [ "$elapsed" -ge 4 ] && [ "$elapsed" -le 10 ] ||
    { echo "elapsed=${elapsed}s want roughly 6s"; return 1; }
  grep -q '^cancel task-fake0000-aaaaaa$' "$state/calls.log" ||
    { echo "cancel missing: $(tr '\n' ' ' < "$state/calls.log")"; return 1; }
}

t2_growth_defeats_idle() {
  local repo state pid alive
  repo=$(new_repo growth-repo)
  state="$TEST_ROOT/growth-state"
  mkdir -p "$state"
  : > "$state/job.log"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=6 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 4 --max-idle 2 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  sleep 4
  alive=0
  kill -0 "$pid" 2>/dev/null && alive=1
  wait_bounded "$pid" 7
  [ "$alive" -eq 1 ] || { echo "dispatch died at or before idle cap"; return 1; }
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "absolute deadline did not stop dispatch"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
}

t3_write_cancel_poisons() {
  local metadata="$TEST_ROOT/deadline-repo/.git/maestro-write.lock/metadata"
  local repo state shim pid lock poison_metadata
  local stage_repo stage_state stage_shim stage_lock
  local race_state race_shim release_repo release_lock release_poison
  local acquire_repo acquire_lock acquire_poison race_failed=0
  [ -f "$metadata" ] || { echo "poisoned metadata missing"; return 1; }
  grep -qx 'quiescence=unconfirmed' "$metadata" ||
    { echo "quiescence poison missing"; return 1; }
  grep -qx 'unconfirmed_job=task-fake0000-aaaaaa' "$metadata" ||
    { echo "unconfirmed job missing"; return 1; }
  grep -qx 'unconfirmed_reason=deadline' "$metadata" ||
    { echo "unconfirmed reason missing"; return 1; }

  repo=$(new_repo poison-move-failure-repo)
  state="$TEST_ROOT/poison-move-failure-state"
  shim="$state/shim"
  mkdir -p "$shim"
  : > "$state/job.log"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'state="%s"\n' "$state/mv-count"
    printf 'real_mv="%s"\n' "$REAL_MV"
    printf 'count=0\n'
    printf '[ -f "$state" ] && IFS= read -r count < "$state"\n'
    printf 'if [ "${1:-}" = "-f" ]; then\n'
    printf '  case "${2:-}" in\n'
    printf '    */metadata.new)\n'
    printf '      count=$((count + 1))\n'
    printf '      printf "%%s\\\\n" "$count" > "$state"\n'
    printf '      [ "$count" -eq 2 ] && exit 1\n'
    printf '      ;;\n'
    printf '  esac\n'
    printf 'fi\n'
    printf 'exec "$real_mv" "$@"\n'
  } > "$shim/mv"
  chmod +x "$shim/mv"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$shim:$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=6 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 4 --max-idle 30 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 11
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "poison-move failure case hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "poison-move failure rc=$WAIT_RC want 11"; return 1; }
  lock="$repo/.git/maestro-write.lock"
  [ -d "$lock" ] || { echo "lease released after poison mv failed"; return 1; }
  poison_metadata="$lock/metadata"
  grep -qx 'quiescence=unconfirmed' "$poison_metadata" 2>/dev/null ||
    poison_metadata="$lock/metadata.new"
  grep -qx 'quiescence=unconfirmed' "$poison_metadata" 2>/dev/null ||
    { echo "no fail-closed poison metadata survived"; return 1; }

  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true --max-iters 1
  ) > "$state/reacquire-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "fallback poison acquire hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "fallback poison acquire rc=$WAIT_RC want 11"; return 1; }
  grep -q -- '--clear-lease' "$state/reacquire-output" ||
    { echo "fallback poison omitted recovery"; return 1; }

  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/clear-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "fallback poison clear hung"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "fallback poison clear rc=$WAIT_RC want 0"; return 1; }
  [ ! -d "$lock" ] || { echo "fallback poison survived clear"; return 1; }

  stage_repo=$(new_repo poison-stage-failure-repo)
  stage_state="$TEST_ROOT/poison-stage-failure-state"
  stage_shim="$stage_state/shim"
  mkdir -p "$stage_shim"
  : > "$stage_state/job.log"
  : > "$stage_state/calls.log"
  status_empty > "$stage_state/status.json"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real_mv="%s"\n' "$REAL_MV"
    printf 'if [ "${1:-}" = "-f" ]; then\n'
    printf '  case "${2:-}" in\n'
    printf '    */metadata.new)\n'
    printf '      "$real_mv" "$@"\n'
    printf '      rc=$?\n'
    printf '      [ "$rc" -eq 0 ] && mkdir "$2"\n'
    printf '      exit "$rc"\n'
    printf '      ;;\n'
    printf '  esac\n'
    printf 'fi\n'
    printf 'exec "$real_mv" "$@"\n'
  } > "$stage_shim/mv"
  chmod +x "$stage_shim/mv"
  set -m
  (
    cd "$stage_repo" &&
      env HOME="$TEST_HOME" PATH="$stage_shim:$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$stage_state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$stage_state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$stage_state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=6 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 4 --max-idle 30 --poll 2
  ) > "$stage_state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 11
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "pre-cancel poison staging failure hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "pre-cancel staging failure rc=$WAIT_RC want 11"; return 1; }
  if grep -q '^cancel ' "$stage_state/calls.log"; then
    echo "cancel issued after poison staging failed: $(tr '\n' ' ' < "$stage_state/calls.log")"
    return 1
  fi
  stage_lock="$stage_repo/.git/maestro-write.lock"
  [ -d "$stage_lock" ] || { echo "lease released after poison staging failed"; return 1; }
  grep -q 'was not cancelled and may still be running' "$stage_state/output" &&
    grep -q 'task-fake0000-aaaaaa' "$stage_state/output" &&
    grep -q "$stage_state/job.log" "$stage_state/output" &&
    grep -q -- '--clear-lease' "$stage_state/output" ||
    { echo "pre-cancel staging failure diagnostic incomplete"; return 1; }

  set -m
  (
    cd "$stage_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$stage_state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true --max-iters 1
  ) > "$stage_state/reacquire-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "staging marker acquire hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "staging marker acquire rc=$WAIT_RC want 11"; return 1; }
  grep -q -- '--clear-lease' "$stage_state/reacquire-output" ||
    { echo "staging marker acquire omitted recovery"; return 1; }
  [ -d "$stage_lock" ] || { echo "staging marker acquire removed the lock"; return 1; }

  set -m
  (
    cd "$stage_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$stage_state/status.json" \
        bash "$LOOP" --clear-lease
  ) > "$stage_state/clear-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "staging marker clear hung"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "staging marker clear rc=$WAIT_RC want 0"; return 1; }
  grep -Fq "$stage_lock/metadata.new" "$stage_state/clear-output" ||
    { echo "staging marker clear omitted removed entry"; return 1; }
  [ ! -d "$stage_lock" ] || { echo "staging marker survived clear"; return 1; }

  race_state="$TEST_ROOT/late-poison-race-state"
  race_shim="$race_state/shim"
  mkdir -p "$race_shim"
  status_empty > "$race_state/status.json"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'shift\n'
    printf 'if [ "${1:-}" = "status" ] && [ "${2:-}" = "--all" ] && [ "${3:-}" = "--json" ]; then\n'
    printf '  mv -f "$MAESTRO_TEST_LATE_POISON" "$MAESTRO_TEST_LATE_LOCK/metadata"\n'
    printf 'fi\n'
    printf 'exec "%s" "%s" "$@"\n' "$REAL_NODE" "$FIXTURE"
  } > "$race_shim/node"
  chmod +x "$race_shim/node"

  release_repo=$(new_repo late-poison-release-repo)
  release_lock="$release_repo/.git/maestro-write.lock"
  release_poison="$race_state/release.poison"
  set -m
  (
    cd "$release_repo" &&
      env HOME="$TEST_HOME" PATH="$race_shim:$TEST_PATH" \
        MAESTRO_TEST_STATUS="$race_state/status.json" \
        MAESTRO_TEST_LATE_LOCK="$release_lock" \
        MAESTRO_TEST_LATE_POISON="$release_poison" ROOT="$ROOT" \
        bash -c '
          unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
          . "$ROOT/hooks/lib-companion.sh"
          progress_init
          write_lock_acquire || exit $?
          write_lock_set_job task-release-race
          sed -n "p" "$MAESTRO_LOCK_DIR/metadata" > "$MAESTRO_TEST_LATE_POISON"
          printf "quiescence=unconfirmed\nunconfirmed_job=task-release-race\nunconfirmed_reason=deadline\n" \
            >> "$MAESTRO_TEST_LATE_POISON"
          write_lock_release
        '
  ) > "$race_state/release-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "late-poison release race hung"; race_failed=1; }
  [ "$WAIT_RC" -eq 0 ] ||
    { echo "late-poison release rc=$WAIT_RC want 0"; race_failed=1; }
  grep -qx 'quiescence=unconfirmed' "$release_lock/metadata" 2>/dev/null ||
    { echo "release erased poison that arrived during liveness check"; race_failed=1; }

  acquire_repo=$(new_repo late-poison-acquire-repo)
  acquire_lock="$acquire_repo/.git/maestro-write.lock"
  acquire_poison="$race_state/acquire.poison"
  mkdir -p "$acquire_lock"
  printf 'token=late-token\npid=99999999\nprocess_start=dead\njob_id=task-acquire-race\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' \
    > "$acquire_lock/metadata"
  sed -n 'p' "$acquire_lock/metadata" > "$acquire_poison"
  printf 'quiescence=unconfirmed\nunconfirmed_job=task-acquire-race\nunconfirmed_reason=deadline\n' \
    >> "$acquire_poison"
  set -m
  (
    cd "$acquire_repo" &&
      env HOME="$TEST_HOME" PATH="$race_shim:$TEST_PATH" \
        MAESTRO_TEST_STATUS="$race_state/status.json" \
        MAESTRO_TEST_LATE_LOCK="$acquire_lock" \
        MAESTRO_TEST_LATE_POISON="$acquire_poison" ROOT="$ROOT" \
        bash -c '
          unset MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR MAESTRO_LOCK_ACQUIRED
          . "$ROOT/hooks/lib-companion.sh"
          progress_init
          write_lock_acquire
          [ "$?" -eq 11 ]
        '
  ) > "$race_state/acquire-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "late-poison acquire race hung"; race_failed=1; }
  [ "$WAIT_RC" -eq 0 ] ||
    { echo "late-poison acquire did not block"; race_failed=1; }
  grep -qx 'quiescence=unconfirmed' "$acquire_lock/metadata" 2>/dev/null ||
    { echo "acquire erased poison that arrived during liveness check"; race_failed=1; }
  [ "$race_failed" -eq 0 ]
}

t4_poison_stops_redispatch() {
  local state="$TEST_ROOT/deadline-state" tasks rc
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  rc=$(sed -n '1p' "$state/loop.rc")
  [ "$tasks" -eq 1 ] || { echo "task dispatches=$tasks want 1"; return 1; }
  [ "$rc" -eq 11 ] || { echo "loop rc=$rc want 11"; return 1; }
}

t5_poison_blocks_acquire() {
  local repo="$TEST_ROOT/deadline-repo" state="$TEST_ROOT/reacquire-state" pid
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true --max-iters 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "poisoned acquire hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
  grep -q -- '--clear-lease' "$state/output" ||
    { echo "recovery command missing"; return 1; }
  [ ! -s "$state/calls.log" ] ||
    { echo "poisoned acquire reached companion"; return 1; }
}

t6_clear_lease_works_and_refuses() {
  local repo="$TEST_ROOT/deadline-repo" state="$TEST_ROOT/clear-state"
  local refuse_repo metadata pid
  mkdir -p "$state"
  status_empty > "$state/empty.json"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/empty.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/clear-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "clear hung"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "clear rc=$WAIT_RC want 0"; return 1; }
  [ ! -d "$repo/.git/maestro-write.lock" ] || { echo "poisoned lock survived clear"; return 1; }
  grep -q 'task-fake0000-aaaaaa' "$state/clear-output" &&
    grep -q 'deadline' "$state/clear-output" ||
    { echo "clear output omitted poison details"; return 1; }

  refuse_repo=$(new_repo clear-refuse-repo)
  metadata="$refuse_repo/.git/maestro-write.lock/metadata"
  mkdir -p "$(dirname "$metadata")"
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=task-old00000-aaaaaa\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\nquiescence=unconfirmed\nunconfirmed_job=task-old00000-aaaaaa\nunconfirmed_reason=deadline\n' > "$metadata"
  status_running_job task-running0-bbbbbb true > "$state/running.json"
  set -m
  (
    cd "$refuse_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/running.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/refuse-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "refusing clear hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "refuse rc=$WAIT_RC want 11"; return 1; }
  grep -q 'refusing to clear' "$state/refuse-output" &&
    grep -q 'task-running0-bbbbbb' "$state/refuse-output" ||
    { echo "refusal omitted running writer"; return 1; }
  [ -d "$refuse_repo/.git/maestro-write.lock" ] ||
    { echo "refused lock was removed"; return 1; }
}

t7_read_only_deadline_no_lease() {
  local repo state pid
  repo=$(new_repo discussion-repo)
  state="$TEST_ROOT/discussion-state"
  mkdir -p "$state"
  : > "$state/job.log"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  printf 'Opening turn.\n' > "$state/turn.md"
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        bash "$DISCUSSION" --new "liveness" deadline
  ) > "$state/new-output" 2>&1 || return 1
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_LOCK_TOKEN= \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=6 \
        bash "$DISCUSSION" --turn "$state/turn.md" deadline 30 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 11
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "read-only deadline did not fire"; return 1; }
  [ "$WAIT_RC" -eq 124 ] || { echo "rc=$WAIT_RC want 124"; return 1; }
  [ ! -d "$repo/.git/maestro-write.lock" ] &&
    [ ! -d "$repo/.maestro-write.lock" ] ||
    { echo "read-only turn created a write lock"; return 1; }
}

t8_verifier_deadline() {
  local repo state pid verify child
  repo=$(new_repo verifier-repo)
  state="$TEST_ROOT/verifier-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify="sleep 60 & child=\$!; printf '%s\n' \"\$child\" > '$state/child.pid'; wait \"\$child\""
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_VERIFY_TIMEOUT_SEC=3 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 10
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "verifier exceeded 10s bound"; return 1; }
  [ "$WAIT_RC" -eq 12 ] || { echo "rc=$WAIT_RC want 12"; return 1; }
  grep -q 'verification timed out after 3s' "$state/output" ||
    { echo "attempt evidence omitted verifier timeout"; return 1; }
  child=$(sed -n '1p' "$state/child.pid")
  [ -n "$child" ] || { echo "verifier child pid missing"; return 1; }
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "verifier child $child survived process-group timeout"
    return 1
  fi
}

t9_terminal_at_deadline_harvests() {
  local repo state pid
  repo=$(new_repo terminal-deadline-repo)
  state="$TEST_ROOT/terminal-deadline-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=2 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 1 --max-idle 30 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 7
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "completed dispatch exceeded 7s bound"; return 1; }
  if grep -q '^cancel task-fake0000-aaaaaa$' "$state/calls.log"; then
    echo "completed job was cancelled"
    return 1
  fi
  [ "$WAIT_RC" -eq 0 ] || { echo "rc=$WAIT_RC want 0"; return 1; }
  grep -q '^result task-fake0000-aaaaaa$' "$state/calls.log" ||
    { echo "result missing: $(tr '\n' ' ' < "$state/calls.log")"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then
    ok "$label"
  else
    bad "$label" "${detail:-no detail}"
  fi
}

printf '=== Liveness verification ===\n'
check t1_deadline_growing_log "deadline fires against a growing log"
check t2_growth_defeats_idle "log growth defeats the idle timer"
check t3_write_cancel_poisons "write cancellation poisons; failed mv retains; failed staging blocks and clears; late poison wins"
check t4_poison_stops_redispatch "poison prevents a second dispatch"
check t5_poison_blocks_acquire "poison blocks later acquisition"
check t6_clear_lease_works_and_refuses "clear-lease clears safely and refuses a live writer"
check t7_read_only_deadline_no_lease "read-only deadline creates no write lease"
check t8_verifier_deadline "verifier deadline bounds the process group"
check t9_terminal_at_deadline_harvests "terminal job is harvested at the dispatch deadline"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
