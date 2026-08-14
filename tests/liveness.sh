#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/hooks/implementer-loop.sh"
WATCHDOG="$ROOT/hooks/implementer-watchdog.sh"
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

prepare_generation() { # lock [generation]
  local lock="$1" generation="${2-}"
  mkdir -p "$lock" || return 1
  if [ -z "$generation" ]; then
    [ ! -f "$lock/generation" ] || return 0
    generation=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  fi
  printf '%s\n' "$generation" > "$lock/generation"
}

sync_generation_field() { # lock [record-name]
  local lock="$1" record="${2:-metadata}" generation file temp
  generation=$(cat "$lock/generation") || return 1
  file="$lock/$record"
  temp="$file.generation"
  awk -v generation="$generation" '
    BEGIN { written = 0 }
    /^generation=/ {
      if (!written) print "generation=" generation
      written = 1
      next
    }
    { print }
    END { if (!written) print "generation=" generation }
  ' "$file" > "$temp" || return 1
  command mv "$temp" "$file"
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
  printf 'if [ "${1:-}" = "-e" ]; then exec "%s" "$@"; fi\n' "$REAL_NODE"
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
  local stage_repo stage_state stage_lock stage_attempt
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
    printf '      [ "$count" -eq 1 ] && exit 1\n'
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
  stage_lock="$stage_repo/.git/maestro-write.lock"
  mkdir -p "$stage_state"
  : > "$stage_state/job.log"
  : > "$stage_state/calls.log"
  status_empty > "$stage_state/status.json"
  set -m
  (
    cd "$stage_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
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
  stage_attempt=0
  while ! grep -qx 'job_id=task-fake0000-aaaaaa' "$stage_lock/metadata" 2>/dev/null; do
    stage_attempt=$((stage_attempt + 1))
    if [ "$stage_attempt" -ge 50 ]; then
      kill -TERM -"$pid" 2>/dev/null || :
      wait_bounded "$pid" 3
      echo "write job was not published before poison staging setup"
      return 1
    fi
    sleep 0.05
  done
  mkdir "$stage_lock/metadata.new" ||
    { echo "could not block poison staging"; return 1; }
  wait_bounded "$pid" 11
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "pre-cancel poison staging failure hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "pre-cancel staging failure rc=$WAIT_RC want 11"; return 1; }
  if grep -q '^cancel ' "$stage_state/calls.log"; then
    echo "cancel issued after poison staging failed: $(tr '\n' ' ' < "$stage_state/calls.log")"
    return 1
  fi
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
  [ "$WAIT_RC" -eq 11 ] || { echo "staging marker clear rc=$WAIT_RC want 11"; return 1; }
  grep -q 'staged Lease interval metadata is malformed' "$stage_state/clear-output" ||
    { echo "staging marker refusal diagnostic missing"; return 1; }
  [ -d "$stage_lock" ] || { echo "unsafe staging marker was cleared"; return 1; }

  race_state="$TEST_ROOT/late-poison-race-state"
  race_shim="$race_state/shim"
  mkdir -p "$race_shim"
  status_empty > "$race_state/status.json"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "-e" ]; then exec "%s" "$@"; fi\n' "$REAL_NODE"
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
          . "$ROOT/hooks/lib-write-lease.sh"
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
  [ "$WAIT_RC" -eq 11 ] ||
    { echo "late-poison release rc=$WAIT_RC want 11"; race_failed=1; }
  grep -qx 'quiescence=unconfirmed' "$release_lock/metadata" 2>/dev/null ||
    { echo "release erased poison that arrived during liveness check"; race_failed=1; }

  acquire_repo=$(new_repo late-poison-acquire-repo)
  acquire_lock="$acquire_repo/.git/maestro-write.lock"
  acquire_poison="$race_state/acquire.poison"
  prepare_generation "$acquire_lock" || return 1
  printf 'token=late-token\npid=99999999\nprocess_start=dead\njob_id=task-acquire-race\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' \
    > "$acquire_lock/metadata"
  sync_generation_field "$acquire_lock" || return 1
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
          . "$ROOT/hooks/lib-write-lease.sh"
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
  local wedge_repo wedge_lock fresh_wedge_repo fresh_wedge_lock healthy_repo healthy_lock healthy_pid healthy_now
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
  prepare_generation "$(dirname "$metadata")" || return 1
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=task-old00000-aaaaaa\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\nquiescence=unconfirmed\nunconfirmed_job=task-old00000-aaaaaa\nunconfirmed_reason=deadline\n' > "$metadata"
  sync_generation_field "$(dirname "$metadata")" || return 1
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

  wedge_repo=$(new_repo clear-wedge-repo)
  wedge_lock="$wedge_repo/.git/maestro-write.lock"
  prepare_generation "$wedge_lock" || return 1
  touch -t 202001010000 "$wedge_lock"
  set -m
  (
    cd "$wedge_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/empty.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/wedge-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "wedge clear hung"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "wedge clear rc=$WAIT_RC want 0"; return 1; }
  [ ! -d "$wedge_lock" ] || { echo "metadata-less wedge survived clear"; return 1; }
  grep -q 'structurally invalid orphan' "$state/wedge-output" &&
    grep -Fq "$wedge_lock" "$state/wedge-output" ||
    { echo "wedge clear output omitted what was removed"; return 1; }

  fresh_wedge_repo=$(new_repo clear-fresh-wedge-repo)
  fresh_wedge_lock="$fresh_wedge_repo/.git/maestro-write.lock"
  prepare_generation "$fresh_wedge_lock" || return 1
  set -m
  (
    cd "$fresh_wedge_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/empty.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/fresh-wedge-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "fresh wedge clear hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "fresh wedge clear rc=$WAIT_RC want 11"; return 1; }
  [ -d "$fresh_wedge_lock" ] || { echo "fresh initializing lock was cleared"; return 1; }
  grep -q 'may still be initializing' "$state/fresh-wedge-output" ||
    { echo "fresh initializing refusal missing"; return 1; }

  healthy_repo=$(new_repo clear-healthy-repo)
  healthy_lock="$healthy_repo/.git/maestro-write.lock"
  healthy_pid=$$
  healthy_now=$(date +%s)
  prepare_generation "$healthy_lock" || return 1
  printf 'token=healthy-token\npid=%s\nprocess_start=unavailable\njob_id=task-healthy-owner\nsession_id=sess-healthy-owner\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$healthy_pid" "$healthy_now" > "$healthy_lock/metadata"
  sync_generation_field "$healthy_lock" || return 1
  set -m
  (
    cd "$healthy_repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" MAESTRO_TEST_STATUS="$state/empty.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/healthy-output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 4
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "healthy clear hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "healthy clear rc=$WAIT_RC want 11"; return 1; }
  [ -d "$healthy_lock" ] || { echo "healthy lock was removed"; return 1; }
  grep -q 'job=task-healthy-owner' "$state/healthy-output" &&
    grep -q 'session=sess-healthy-owner' "$state/healthy-output" &&
    grep -q "pid=$healthy_pid" "$state/healthy-output" &&
    grep -q 'healthy' "$state/healthy-output" ||
    { echo "healthy refusal omitted owner details"; return 1; }
  if grep -q 'CLEARED' "$state/healthy-output"; then
    echo "healthy refusal claimed CLEARED"
    return 1
  fi
}

t7_read_only_deadline_no_lease() {
  local repo state pid inherited
  repo=$(new_repo discussion-repo)
  state="$TEST_ROOT/discussion-state"
  inherited="$state/inherited-lease"
  mkdir -p "$state" "$inherited"
  : > "$state/job.log"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  printf 'token=faketoken\npid=1\nprocess_start=x\njob_id=fakejob\nsession_id=fakesess\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1767225600\ndigest_before=unavailable\n' > "$inherited/metadata"
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
        MAESTRO_LOCK_ACQUIRED=1 MAESTRO_LOCK_TOKEN=faketoken MAESTRO_LOCK_DIR="$inherited" \
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
  [ "$WAIT_RC" -eq 124 ] ||
    { echo "rc=$WAIT_RC want 124"; cat "$state/output"; return 1; }
  [ ! -d "$repo/.git/maestro-write.lock" ] &&
    [ ! -d "$repo/.maestro-write.lock" ] ||
    { echo "read-only turn created a write lock"; return 1; }
  ! grep -q '^quiescence=unconfirmed$' "$inherited/metadata" ||
    { echo "read-only Discussion turn poisoned inherited Lease interval state"; return 1; }
}

t8_verifier_boundaries() {
  local repo state pid verify child ownership
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
  wait_bounded "$pid" 30
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "verifier exceeded 30s bound"; return 1; }
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

  repo=$(new_repo verifier-lease-repo)
  state="$TEST_ROOT/verifier-lease-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify="if env | grep -Eq '^MAESTRO_LOCK_(TOKEN|DIR|ACQUIRED)='; then printf '0\n' > '$state/ownership'; exit 1; else printf '1\n' > '$state/ownership'; fi"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 25
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "verifier lease check exceeded 25s bound"; return 1; }
  ownership=$(sed -n '1p' "$state/ownership" 2>/dev/null)
  [ "$ownership" = 1 ] ||
    { echo "verifier inherited Lease interval capability state=${ownership:-no result}"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "verifier lease check rc=$WAIT_RC want 0"; return 1; }

  repo=$(new_repo verifier-success-reap-repo)
  state="$TEST_ROOT/verifier-success-reap-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify="sleep 60 & child=\$!; printf '%s\\n' \"\$child\" > '$state/child.pid'; exit 0"
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 2
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 25
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "successful verifier reap exceeded 25s bound"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "successful verifier reap rc=$WAIT_RC want 0"; return 1; }
  child=$(sed -n '1p' "$state/child.pid" 2>/dev/null)
  [ -n "$child" ] || { echo "successful verifier child pid missing"; return 1; }
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "successful verifier child $child survived VERIFIED_DONE"
    return 1
  fi
  repo=$(new_repo verifier-root-repo)
  state="$TEST_ROOT/verifier-root-state"
  mkdir -p "$repo/deep/nested" "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify='test "$PWD" = "$(git rev-parse --show-toplevel)"'
  set -m
  (
    cd "$repo/deep/nested" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 25
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "verifier root cwd exceeded 25s bound"; return 1; }
  [ "$WAIT_RC" -eq 0 ] ||
    { echo "verifier root cwd rc=$WAIT_RC want 0: $(tr '\n' ' ' < "$state/output")"; return 1; }
  grep -q '^MAESTRO_FINAL: LOOP VERIFIED_DONE rc=0$' "$state/output" ||
    { echo "verifier root cwd final missing: $(tr '\n' ' ' < "$state/output")"; return 1; }
  local heartbeat first second
  repo=$(new_repo verifier-heartbeat-repo)
  state="$TEST_ROOT/verifier-heartbeat-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify='sleep 5'
  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=1 \
        MAESTRO_LOCK_HEARTBEAT_STALE_SEC=2 \
        MAESTRO_VERIFY_TIMEOUT_SEC=8 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  heartbeat="$repo/.git/maestro-write.lock/heartbeat"
  for _ in 1 2 3 4 5 6 7 8; do
    if grep -q 'LOOP: RESULT: DONE on iteration 1' "$state/output" 2>/dev/null &&
      [ -f "$heartbeat" ]; then
      break
    fi
    sleep 1
  done
  grep -q 'LOOP: RESULT: DONE on iteration 1' "$state/output" ||
    { echo "verifier did not reach local verification"; return 1; }
  [ -f "$heartbeat" ] || { echo "verification heartbeat missing"; return 1; }
  first=$(sed -n 's/^epoch=//p' "$heartbeat" | head -1)
  sleep 2
  second=$(sed -n 's/^epoch=//p' "$heartbeat" | head -1)
  case "$first:$second" in
    :*|*:|*[!0-9:]*) echo "invalid heartbeat epochs: first=$first second=$second"; return 1 ;;
  esac
  [ "$second" -gt "$first" ] ||
    { echo "verification heartbeat did not advance: first=$first second=$second"; return 1; }
  kill -0 "$pid" 2>/dev/null ||
    { echo "verifier ended before heartbeat observation"; return 1; }
  wait_bounded "$pid" 30
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "heartbeat verifier exceeded 30s"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "heartbeat verifier rc=$WAIT_RC"; return 1; }
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
  wait_bounded "$pid" 25
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "completed dispatch exceeded 25s bound"; return 1; }
  if grep -q '^cancel task-fake0000-aaaaaa$' "$state/calls.log"; then
    echo "completed job was cancelled"
    return 1
  fi
  [ "$WAIT_RC" -eq 0 ] || { echo "rc=$WAIT_RC want 0"; return 1; }
  grep -q '^result task-fake0000-aaaaaa$' "$state/calls.log" ||
    { echo "result missing: $(tr '\n' ' ' < "$state/calls.log")"; return 1; }
}

t10_watchdog_signal_is_terminal() {
  local repo state pid child tasks cancels poisons metadata
  repo=$(new_repo watchdog-signal-repo)
  state="$TEST_ROOT/watchdog-signal-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  : > "$state/job.log"
  status_running_job task-fake0000-aaaaaa true > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_TEST_STATUS_HANG=60 \
        MAESTRO_TEST_STATUS_PID_FILE="$state/status.pid" \
        MAESTRO_COMPANION_TIMEOUT_SEC=120 \
        bash "$WATCHDOG" --file "$TEST_ROOT/plan.md" 30 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 600); do
    [ -s "$state/status.pid" ] &&
      grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" && break
    sleep 0.05
  done
  [ -s "$state/status.pid" ] &&
    grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "watchdog never entered hanging status call"; return 1; }
  child=$(sed -n '1p' "$state/status.pid")
  kill -TERM "$pid" || return 1
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] ||
    { echo "signalled watchdog did not exit"; return 1; }
  [ "$WAIT_RC" -eq 125 ] || { echo "rc=$WAIT_RC want 125: $(tr '\n' ' ' < "$state/output")"; return 1; }
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "hanging Companion child $child survived watchdog TERM"
    return 1
  fi
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  cancels=$(grep -c '^cancel task-fake0000-aaaaaa$' "$state/calls.log" || true)
  poisons=$(grep -c '^quiescence=unconfirmed$' \
    "$repo/.git/maestro-write.lock/metadata" 2>/dev/null || true)
  [ "$tasks" -eq 1 ] || { echo "task starts=$tasks want 1"; return 1; }
  [ "$cancels" -eq 1 ] || { echo "cancel attempts=$cancels want 1"; return 1; }
  [ "$poisons" -eq 1 ] || { echo "poison records=$poisons want 1"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  [ -f "$metadata" ] || { echo "signalled watchdog released its lease"; return 1; }
  grep -qx 'quiescence=unconfirmed' "$metadata" &&
    grep -qx 'unconfirmed_reason=signal-term' "$metadata" ||
    { echo "signalled watchdog did not record one TERM poison"; return 1; }
}

t11_loop_signal_is_terminal() {
  local repo state pid tasks cancels metadata
  repo=$(new_repo loop-signal-repo)
  state="$TEST_ROOT/loop-signal-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  : > "$state/job.log"
  status_running_job task-fake0000-aaaaaa true > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 2 --max-idle 30 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 600); do
    grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" && break
    sleep 0.05
  done
  grep -q '^status task-fake0000-aaaaaa --json$' "$state/calls.log" ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "loop watchdog never reached polling"; return 1; }
  kill -TERM "$pid" || return 1
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "signalled loop did not exit"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11: $(tr '\n' ' ' < "$state/output")"; return 1; }
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  cancels=$(grep -c '^cancel task-fake0000-aaaaaa$' "$state/calls.log" || true)
  [ "$tasks" -eq 1 ] || { echo "task starts=$tasks want 1"; return 1; }
  [ "$cancels" -eq 1 ] || { echo "cancel attempts=$cancels want 1"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  [ -f "$metadata" ] && grep -qx 'quiescence=unconfirmed' "$metadata" ||
    { echo "signalled loop did not retain poisoned lease"; return 1; }
}

t12_loop_signal_reaps_verifier() {
  local repo state pid child cancels metadata
  repo=$(new_repo verifier-signal-repo)
  state="$TEST_ROOT/verifier-signal-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  verify="sleep 60 & child=\$!; printf '%s\\n' \"\$child\" > '$state/child.pid'; wait \"\$child\""
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT='RESULT: DONE' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify "$verify" \
          --max-iters 1 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 600); do
    [ -s "$state/child.pid" ] && break
    sleep 0.05
  done
  [ -s "$state/child.pid" ] ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "verifier never started"; return 1; }
  child=$(sed -n '1p' "$state/child.pid")
  kill -TERM "$pid" || return 1
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "loop signal during verifier did not exit"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || :
    echo "verifier child $child survived loop TERM"
    return 1
  fi
  cancels=$(grep -c '^cancel ' "$state/calls.log" || true)
  [ "$cancels" -eq 0 ] ||
    { echo "verifier signal cancelled the completed writer $cancels time(s)"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  [ -f "$metadata" ] &&
    grep -qx 'quiescence=unconfirmed' "$metadata" &&
    grep -qx 'unconfirmed_reason=signal-term' "$metadata" ||
    { echo "verifier signal did not retain one exact-generation poison"; return 1; }
  grep -q 'request=not-attempted source=signal-handler' "$state/output" ||
    { echo "verifier signal did not record a not-attempted cancellation fact"; return 1; }
}

t13_prelaunch_generation_fence() {
  local repo state pid metadata temp tasks token
  repo=$(new_repo prelaunch-fence-repo)
  state="$TEST_ROOT/prelaunch-fence-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_HELP_DELAY=3 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$WATCHDOG" --file "$TEST_ROOT/plan.md" 30 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 600); do
    grep -q '^--help$' "$state/calls.log" && break
    sleep 0.05
  done
  grep -q '^--help$' "$state/calls.log" ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "watchdog never entered compatibility probe"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  [ -f "$metadata" ] || { kill -KILL "$pid" 2>/dev/null || :; echo "lease metadata missing"; return 1; }
  temp="$metadata.successor"
  sed 's/^token=.*/token=successor-token/' "$metadata" > "$temp" || return 1
  mv -f "$temp" "$metadata" || return 1
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "prelaunch fence watchdog hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11: $(tr '\n' ' ' < "$state/output")"; return 1; }
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  [ "$tasks" -eq 0 ] || { echo "lost owner launched $tasks task(s)"; return 1; }
  token=$(sed -n 's/^token=//p' "$metadata" | head -1)
  [ "$token" = successor-token ] || { echo "successor token changed to $token"; return 1; }
}

t14_midpoint_warning_continues_same_job() {
  local repo state pid warnings tasks ceiling=12 warning
  repo=$(new_repo budget-midpoint-repo)
  state="$TEST_ROOT/budget-midpoint-state"
  warning="^MAESTRO_BUDGET: .*continuing to the ${ceiling}s hard ceiling"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_TERMINAL_FLAG="$state/complete" \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC="$ceiling" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 1 --max-idle 30 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 240); do
    grep -q "$warning" "$state/output" && break
    sleep 0.05
  done
  grep -q "$warning" "$state/output" && : > "$state/complete"
  wait_bounded "$pid" 17
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "midpoint completion exceeded bound"; return 1; }
  [ "$WAIT_RC" -eq 0 ] || { echo "rc=$WAIT_RC want 0: $(tr '\n' ' ' < "$state/output")"; return 1; }
  warnings=$(grep -c "$warning" "$state/output" || true)
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  [ "$warnings" -eq 1 ] || { echo "midpoint warnings=$warnings want 1"; return 1; }
  [ "$tasks" -eq 1 ] || { echo "task starts=$tasks want 1"; return 1; }
  ! grep -q '^cancel ' "$state/calls.log" || { echo "healthy midpoint job was cancelled"; return 1; }
}

t15_startup_consumes_dispatch_budget() {
  local repo state pid statuses
  repo=$(new_repo budget-startup-repo)
  state="$TEST_ROOT/budget-startup-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  : > "$state/job.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_TASK_DELAY=3 \
        MAESTRO_TEST_JOB_PHASE=running \
        MAESTRO_TEST_LOGFILE="$state/job.log" \
        MAESTRO_TEST_LOG_GROWTH=1 \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=2 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 1 --max-idle 30 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "startup-budget case exceeded bound"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
  statuses=$(grep -c '^status task-fake0000-aaaaaa --json$' "$state/calls.log" || true)
  # One status call verifies the pin; the first poll must then hit the already-spent budget.
  [ "$statuses" -eq 2 ] || { echo "status calls=$statuses want 2 (pin check + one poll)"; return 1; }
  grep -q 'MAESTRO_RECOVERY: UNREPORTED_PARTIAL.*reason=deadline' "$state/output" ||
    { echo "deadline recovery marker missing"; return 1; }
}

t16_observed_cancellation_is_terminal() {
  local repo state pid tasks cancels metadata
  repo=$(new_repo observed-cancel-repo)
  state="$TEST_ROOT/observed-cancel-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=cancelled \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 2 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 8
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "observed cancellation loop hung"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11: $(tr '\n' ' ' < "$state/output")"; return 1; }
  tasks=$(grep -c '^task ' "$state/calls.log" || true)
  cancels=$(grep -c '^cancel ' "$state/calls.log" || true)
  [ "$tasks" -eq 1 ] || { echo "task starts=$tasks want 1"; return 1; }
  [ "$cancels" -eq 0 ] || { echo "observed cancellation issued $cancels redundant cancel(s)"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  grep -qx 'quiescence=unconfirmed' "$metadata" 2>/dev/null &&
    grep -qx 'unconfirmed_reason=cancelled-observed' "$metadata" 2>/dev/null ||
    { echo "observed cancellation poison missing"; return 1; }
}

t17_malformed_status_counts_as_status_loss() {
  local repo state pid statuses metadata
  repo=$(new_repo malformed-status-repo)
  state="$TEST_ROOT/malformed-status-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_empty > "$state/status.json"
  set -m
  (
    cd "$repo" &&
      exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_STATUS_RAW='{malformed' \
        MAESTRO_TEST_STATUS="$state/status.json" \
        MAESTRO_MAX_DISPATCH_SEC=8 \
        bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
          --max-iters 2 --poll 1
  ) > "$state/output" 2>&1 &
  pid=$!
  set +m
  wait_bounded "$pid" 11
  [ "$WAIT_TIMED_OUT" -eq 0 ] || { echo "malformed status did not take bounded status-loss path"; return 1; }
  [ "$WAIT_RC" -eq 11 ] || { echo "rc=$WAIT_RC want 11"; return 1; }
  statuses=$(grep -c '^status task-fake0000-aaaaaa --json$' "$state/calls.log" || true)
  [ "$statuses" -eq 5 ] || { echo "status calls=$statuses want 5 (pin + four failed polls)"; return 1; }
  metadata="$repo/.git/maestro-write.lock/metadata"
  grep -qx 'unconfirmed_reason=status-lost' "$metadata" 2>/dev/null ||
    { echo "malformed status was not classified as status-lost"; return 1; }
}

t18_invalid_polling_args_fail_before_launch() {
  local repo state rc tasks
  repo=$(new_repo invalid-polling-args-repo)
  state="$TEST_ROOT/invalid-polling-args-state"
  mkdir -p "$state"
  status_empty > "$state/status.json"

  for invocation in \
    "watchdog-max-idle|bash '$WATCHDOG' --file '$TEST_ROOT/plan.md' bogus 1" \
    "watchdog-poll|bash '$WATCHDOG' --file '$TEST_ROOT/plan.md' 30 0" \
    "loop-max-idle|bash '$LOOP' --plan '$TEST_ROOT/plan.md' --verify true --max-idle bogus" \
    "loop-poll|bash '$LOOP' --plan '$TEST_ROOT/plan.md' --verify true --poll 0"; do
    name=${invocation%%|*}
    command=${invocation#*|}
    : > "$state/calls.log"
    (
      cd "$repo" || exit 1
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_CALL_LOG="$state/calls.log" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash -c "$command"
    ) > "$state/$name.out" 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || { echo "$name rc=$rc want 3"; return 1; }
    tasks=$(grep -c '^task ' "$state/calls.log" || true)
    [ "$tasks" -eq 0 ] || { echo "$name launched $tasks task(s)"; return 1; }
    [ ! -d "$repo/.git/maestro-write.lock" ] || { echo "$name acquired a write lease"; return 1; }
  done

  (
    cd "$repo" || exit 1
    env HOME="$TEST_HOME" PATH="$TEST_PATH" \
      bash "$LOOP" --clear-lease --plan "$TEST_ROOT/plan.md" --verify true
  ) > "$state/clear-mixed.out" 2>&1
  rc=$?
  [ "$rc" -eq 3 ] || { echo "mixed clear/execution rc=$rc want 3"; return 1; }
  grep -q 'mutually exclusive' "$state/clear-mixed.out" ||
    { echo "mixed clear/execution error is unclear"; return 1; }
}

t19_waiting_contender_signal_does_not_cancel_owner() (
  local repo state pid rc
  repo=$(new_repo waiting-signal-repo)
  state="$TEST_ROOT/waiting-signal-state"
  mkdir -p "$state"
  : > "$state/calls.log"
  status_running_job task-holder00-aaaaaa true > "$state/status.json"
  cd "$repo" || exit 1
  . "$ROOT/hooks/lib-write-lease.sh"
  companion_resolve() { printf '%s' "$FIXTURE"; }
  progress_init
  export MAESTRO_TEST_CALL_LOG="$state/calls.log"
  export MAESTRO_TEST_STATUS="$state/status.json"
  write_lock_acquire task-holder00-aaaaaa >/dev/null 2>&1 || return 1

  set -m
  (
    unset MAESTRO_LOCK_ACQUIRED MAESTRO_LOCK_TOKEN MAESTRO_LOCK_DIR
    exec env HOME="$TEST_HOME" PATH="$TEST_PATH" \
      MAESTRO_LOCK_WAIT_SEC=30 MAESTRO_LOCK_WAIT_POLL_SEC=1 \
      MAESTRO_TEST_CALL_LOG="$state/calls.log" \
      MAESTRO_TEST_STATUS="$state/status.json" \
      bash "$LOOP" --plan "$TEST_ROOT/plan.md" --verify true \
        --max-iters 1 --max-idle 2 --poll 1
  ) > "$state/output" 2>&1 3>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 600); do
    grep -q 'waiting for the write lease' "$state/output" && break
    sleep 0.05
  done
  grep -q 'waiting for the write lease' "$state/output" ||
    { kill -KILL "$pid" 2>/dev/null || :; echo "contender never waited"; return 1; }
  kill -TERM "$pid" || return 1
  wait_bounded "$pid" 8
  rc=$WAIT_RC
  status_empty > "$state/status.json"
  write_lock_release >/dev/null 2>&1 || :
  [ "$rc" -eq 4 ] || { echo "waiting contender signal rc=$rc want 4"; return 1; }
  ! grep -q '^cancel ' "$state/calls.log" ||
    { echo "waiting contender cancelled the active lease owner"; return 1; }
)

t20_concurrent_clear_large_status_is_bounded() (
  local repo state lock pid1 pid2 rc1 rc2 timed1 timed2
  repo=$(new_repo concurrent-clear-repo)
  state="$TEST_ROOT/concurrent-clear-state"
  lock="$repo/.git/maestro-write.lock"
  mkdir -p "$state"
  prepare_generation "$lock" || return 1
  "$REAL_NODE" -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      running: [],
      latestFinished: null,
      padding: " ".repeat(256 * 1024)
    }));
  ' "$state/status.json" || return 1
  printf 'token=concurrent-clear\npid=999999\nprocess_start=dead\njob_id=task-concurrent-clear\nsession_id=session-concurrent-clear\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\nquiescence=unconfirmed\nunconfirmed_job=task-concurrent-clear\nunconfirmed_reason=signal-term\n' \
    > "$lock/metadata"
  sync_generation_field "$lock" || return 1

  set -m
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/first.out" 2>&1 &
  pid1=$!
  (
    cd "$repo" &&
      env HOME="$TEST_HOME" PATH="$TEST_PATH" \
        MAESTRO_TEST_STATUS="$state/status.json" \
        bash "$LOOP" --clear-lease
  ) > "$state/second.out" 2>&1 &
  pid2=$!
  set +m

  wait_bounded "$pid1" 4
  rc1=$WAIT_RC
  timed1=$WAIT_TIMED_OUT
  wait_bounded "$pid2" 4
  rc2=$WAIT_RC
  timed2=$WAIT_TIMED_OUT
  [ "$timed1" -eq 0 ] && [ "$timed2" -eq 0 ] ||
    { echo "concurrent clear timed out first=$timed1 second=$timed2"; return 1; }
  case "$rc1:$rc2" in
    0:0|0:11|11:0) ;;
    *) echo "concurrent clear rc=$rc1:$rc2 want one success and no failure"; return 1 ;;
  esac
  [ ! -d "$lock" ] ||
    { echo "concurrent clear left lock entries: $(find "$lock" -mindepth 1 -maxdepth 1 -print)"; return 1; }
)

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
check t3_write_cancel_poisons "write cancellation poisons; failed writes retain fail-closed state; late poison wins"
check t4_poison_stops_redispatch "poison prevents a second dispatch"
check t5_poison_blocks_acquire "poison blocks later acquisition"
check t6_clear_lease_works_and_refuses "clear-lease clears safely and refuses a live writer"
check t7_read_only_deadline_no_lease "read-only deadline creates no write lease"
check t8_verifier_boundaries "verifier deadline bounds the process group and verifier does not own the lease"
check t9_terminal_at_deadline_harvests "terminal job is harvested at the dispatch deadline"
check t10_watchdog_signal_is_terminal "watchdog TERM poisons, cancels once, and cannot redispatch"
check t11_loop_signal_is_terminal "loop TERM poisons, cancels once, and exits blocked"
check t12_loop_signal_reaps_verifier "loop TERM reaps the active verifier process group"
check t13_prelaunch_generation_fence "ownership is rechecked immediately before write launch"
check t14_midpoint_warning_continues_same_job "midpoint warning continues the same productive job"
check t15_startup_consumes_dispatch_budget "startup time consumes the hard dispatch budget"
check t16_observed_cancellation_is_terminal "observed write cancellation poisons and cannot redispatch"
check t17_malformed_status_counts_as_status_loss "malformed nonempty status follows bounded status loss"
check t18_invalid_polling_args_fail_before_launch "invalid polling args and mixed clear mode fail before launch"
check t19_waiting_contender_signal_does_not_cancel_owner "waiting contender TERM never cancels the active owner"
check t20_concurrent_clear_large_status_is_bounded "concurrent clear stays bounded with a large status payload"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
