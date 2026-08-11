#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="$ROOT/hooks/codex-model-select.sh"
SCOUT="$ROOT/hooks/scout.sh"
COMPANION_LIB="$ROOT/hooks/lib-companion.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
REAL_NODE=$(node -p 'process.execPath')
TEST_ROOT=$(mktemp -d /tmp/maestro-scout.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

setup_case() { # name
  CASE_ROOT="$TEST_ROOT/$1"
  CASE_HOME="$CASE_ROOT/home"
  CASE_REPO="$CASE_ROOT/repo"
  CASE_SHIM="$CASE_ROOT/shim"
  CASE_COMPANION="$CASE_HOME/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
  CASE_QUERY="$CASE_ROOT/query.md"
  CASE_ARGV="$CASE_ROOT/argv.json"
  CASE_TASK_IDS="$CASE_ROOT/task-ids"
  mkdir -p "$CASE_SHIM" "$(dirname "$CASE_COMPANION")" \
    "$CASE_HOME/.codex" "$CASE_REPO"
  : > "$CASE_COMPANION"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "-e" ]; then exec "%s" "$@"; fi\n' "$REAL_NODE"
    printf 'shift\nexec "%s" "%s" "$@"\n' "$REAL_NODE" "$FIXTURE"
  } > "$CASE_SHIM/node"
  chmod +x "$CASE_SHIM/node"
  printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' \
    > "$CASE_HOME/.codex/config.toml"
  printf 'high\n' > "$CASE_HOME/.codex/maestro-impl-effort"
  printf 'find the selector\n' > "$CASE_QUERY"
  printf 'task-scout0000-aaaaaa\n' > "$CASE_TASK_IDS"
  git init -q "$CASE_REPO"
  CASE_PATH="$CASE_SHIM:$PATH"
}

run_scout() { # stdout stderr [environment...]
  local stdout="$1" stderr="$2"
  shift 2
  (
    cd "$CASE_REPO" || exit 1
    env HOME="$CASE_HOME" PATH="$CASE_PATH" \
      MAESTRO_TEST_ARGV="$CASE_ARGV" \
      MAESTRO_TEST_TASK_ID_FILE="$CASE_TASK_IDS" \
      "$@" bash "$SCOUT" --query "$CASE_QUERY"
  ) > "$stdout" 2> "$stderr" 3>&1
}

t1_selector_round_trip() (
  local output pin show
  setup_case t1
  output=$(HOME="$CASE_HOME" bash "$SELECTOR" --scout fake-small low 2>&1) ||
    { echo "selector failed: $output"; return 1; }
  pin=$(HOME="$CASE_HOME" bash "$SELECTOR" --scout-pin) || return 1
  [ "$pin" = $'fake-small\tlow' ] || { echo "pin=$pin"; return 1; }
  show=$(HOME="$CASE_HOME" bash "$SELECTOR" --show) || return 1
  case "$show" in *$'scout=fake-small/low\n'*|*$'scout=fake-small/low') ;; *)
    echo "show omitted scout: $show"; return 1 ;; esac
)

t2_selector_rejects_invalid_values() (
  local output rc before
  setup_case t2
  for value in max ultra; do
    output=$(HOME="$CASE_HOME" bash "$SELECTOR" --scout m "$value" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || { echo "effort=$value rc=$rc output=$output"; return 1; }
    case "$output" in *SELECT_ERROR:*) ;; *) echo "missing SELECT_ERROR: $output"; return 1 ;; esac
    [ ! -e "$CASE_HOME/.codex/maestro-scout" ] ||
      { echo "rejected effort created pin"; return 1; }
  done
  for model in 'bad/model' 'bad model'; do
    output=$(HOME="$CASE_HOME" bash "$SELECTOR" --scout "$model" low 2>&1); rc=$?
    [ "$rc" -eq 3 ] || { echo "model=$model rc=$rc output=$output"; return 1; }
    case "$output" in *SELECT_ERROR:*) ;; *) echo "missing SELECT_ERROR: $output"; return 1 ;; esac
    [ ! -e "$CASE_HOME/.codex/maestro-scout" ] ||
      { echo "rejected model created pin"; return 1; }
  done
  HOME="$CASE_HOME" bash "$SELECTOR" --scout stable low >/dev/null || return 1
  before=$(cat "$CASE_HOME/.codex/maestro-scout")
  HOME="$CASE_HOME" bash "$SELECTOR" --scout 'still bad' low >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] && [ "$(cat "$CASE_HOME/.codex/maestro-scout")" = "$before" ] ||
    { echo "invalid update changed existing pin"; return 1; }
)

t3_unpinned_scout_is_blocked() (
  local stdout stderr rc before
  setup_case t3
  stdout="$CASE_ROOT/stdout"; stderr="$CASE_ROOT/stderr"
  before=$(cat "$CASE_TASK_IDS")
  run_scout "$stdout" "$stderr"; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -Fq 'codex-model-select.sh --scout <model> <effort>' "$stderr" ||
    { echo "missing pin guidance: $(tr '\n' ' ' < "$stderr")"; return 1; }
  [ ! -e "$CASE_ARGV" ] && [ "$(cat "$CASE_TASK_IDS")" = "$before" ] ||
    { echo "companion job started while unpinned"; return 1; }
)

t4_pinned_scout_uses_its_model_and_effort() (
  local stdout stderr rc pin model effort final reply
  setup_case t4
  stdout="$CASE_ROOT/stdout"; stderr="$CASE_ROOT/stderr"
  HOME="$CASE_HOME" bash "$SELECTOR" --scout fake-small low >/dev/null || return 1
  pin=$(HOME="$CASE_HOME" bash "$SELECTOR" --scout-pin) || return 1
  model=${pin%%$'\t'*}
  effort=${pin#*$'\t'}
  reply=$'fixture scout reply\nSCOUT_SUMMARY: fixture completed'
  run_scout "$stdout" "$stderr" MAESTRO_TEST_RESULT="$reply"; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc stderr=$(tr '\n' ' ' < "$stderr")"; return 1; }
  grep -Fq 'fixture scout reply' "$stdout" || { echo "fixture reply missing"; return 1; }
  final=$(grep '^MAESTRO_FINAL:' "$stdout" | tail -1)
  [ "$final" = 'MAESTRO_FINAL: SCOUT DONE rc=0' ] ||
    { echo "final=$final"; return 1; }
  grep -Fq "\"--model\",\"$model\"" "$CASE_ARGV" ||
    { echo "argv omitted model=$model: $(cat "$CASE_ARGV")"; return 1; }
  grep -Fq "\"--effort\",\"$effort\"" "$CASE_ARGV" ||
    { echo "argv omitted effort=$effort: $(cat "$CASE_ARGV")"; return 1; }
)

t5_scout_honors_job_lock() (
  local stdout stderr lock rc before
  setup_case t5
  stdout="$CASE_ROOT/stdout"; stderr="$CASE_ROOT/stderr"
  HOME="$CASE_HOME" bash "$SELECTOR" --scout fake-small low >/dev/null || return 1
  lock="$CASE_REPO/.git/maestro-job-lock"
  mkdir "$lock"
  printf 'token=live\npid=%s\nsession=unknown\nclass=read\nstart=1\njob=task-live0000-aaaaaa\n' \
    "$$" > "$lock/metadata"
  before=$(cat "$CASE_TASK_IDS")
  run_scout "$stdout" "$stderr" MAESTRO_LOCK_WAIT_SEC=0; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ ! -e "$CASE_ARGV" ] && [ "$(cat "$CASE_TASK_IDS")" = "$before" ] ||
    { echo "companion job started despite live job lock"; return 1; }
)

t6_corrupt_pin_is_blocked() (
  local stdout stderr rc
  setup_case t6
  stdout="$CASE_ROOT/stdout"; stderr="$CASE_ROOT/stderr"
  printf 'model=fake-small\neffort=ultra\n' > "$CASE_HOME/.codex/maestro-scout"
  run_scout "$stdout" "$stderr"; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -Fq "invalid scout effort 'ultra'" "$stderr" ||
    { echo "corrupt pin error missing: $(tr '\n' ' ' < "$stderr")"; return 1; }
  [ ! -e "$CASE_ARGV" ] || { echo "corrupt pin started companion"; return 1; }
)

t7_override_guard_precedes_job_lock() (
  local read_out write_out read_argv write_argv rc
  setup_case t7
  read_out="$CASE_ROOT/read.out"; write_out="$CASE_ROOT/write.out"
  read_argv="$CASE_ROOT/read.argv"; write_argv="$CASE_ROOT/write.argv"
  (
    cd "$CASE_REPO" || exit 1
    env HOME="$CASE_HOME" PATH="$CASE_PATH" \
      COMPANION_LIB="$COMPANION_LIB" MAESTRO_COMPANION_MODEL=fake-small \
      MAESTRO_TEST_ARGV="$read_argv" bash -c '
        . "$COMPANION_LIB"
        progress_init
        printf "query\n" > prompt
        companion_turn read prompt 20 1 result profile evidence :
      '
  ) > "$read_out" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 3 ] || { echo "partial override rc=$rc want 3"; return 1; }
  [ ! -e "$read_argv" ] && [ ! -d "$CASE_REPO/.git/maestro-job-lock" ] ||
    { echo "partial override reached job start or lock"; return 1; }
  (
    cd "$CASE_REPO" || exit 1
    env HOME="$CASE_HOME" PATH="$CASE_PATH" \
      COMPANION_LIB="$COMPANION_LIB" MAESTRO_COMPANION_MODEL=fake-small \
      MAESTRO_COMPANION_EFFORT=low MAESTRO_TEST_ARGV="$write_argv" bash -c '
        . "$COMPANION_LIB"
        progress_init
        lifecycle() { return 0; }
        printf "write\n" > prompt
        companion_turn write prompt 20 1 result profile evidence lifecycle
      '
  ) > "$write_out" 2>&1 3>&1
  rc=$?
  [ "$rc" -eq 3 ] || { echo "write override rc=$rc want 3"; return 1; }
  [ ! -e "$write_argv" ] && [ ! -d "$CASE_REPO/.git/maestro-job-lock" ] ||
    { echo "write override reached job start or lock"; return 1; }
)

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Scout verification ===\n'
check t1_selector_round_trip "selector round-trips the scout pin"
check t2_selector_rejects_invalid_values "selector rejects invalid scout pins atomically"
check t3_unpinned_scout_is_blocked "unpinned scout fails closed before dispatch"
check t4_pinned_scout_uses_its_model_and_effort "pinned scout dispatches with its own argv"
check t5_scout_honors_job_lock "scout serializes on the companion job lock"
check t6_corrupt_pin_is_blocked "corrupt scout pin fails closed"
check t7_override_guard_precedes_job_lock "override guard rejects partial and write steering"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
