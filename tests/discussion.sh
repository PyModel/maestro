#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCUSSION="$ROOT/hooks/discussion-loop.sh"
FIXTURE="$ROOT/tests/fixtures/fake-companion.mjs"
TEST_ROOT=$(mktemp -d /tmp/maestro-discussion.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

REAL_NODE=$(node -p 'process.execPath')
HOME_DIR="$TEST_ROOT/home"
SHIM="$TEST_ROOT/shim"
COMPANION="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
mkdir -p "$SHIM" "$(dirname "$COMPANION")" "$HOME_DIR/.codex"
: > "$COMPANION"
cat > "$SHIM/node" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-e" ]; then exec "$REAL_NODE" "\$@"; fi
shift
exec "$REAL_NODE" "$FIXTURE" "\$@"
EOF
chmod +x "$SHIM/node"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$HOME_DIR/.codex/config.toml"
printf 'high\n' > "$HOME_DIR/.codex/maestro-impl-effort"
printf '{\n  "running": [],\n  "latestFinished": null\n}\n' > "$TEST_ROOT/status.json"
TEST_PATH="$SHIM:$PATH"

new_repo() {
  mkdir -p "$1"
  git init -q "$1"
}

run_new() { # repo slug output
  (cd "$1" && env HOME="$HOME_DIR" PATH="$TEST_PATH" bash "$DISCUSSION" --new topic "$2") > "$3" 2>&1
}

transcript_from() {
  sed -n 's/^DISCUSSION: started .* → //p' "$1" | head -1
}

run_turn() { # repo turn slug result output [max-rounds]
  local repo="$1" turn="$2" slug="$3" result="$4" output="$5" rounds="${6:-6}"
  (
    cd "$repo" &&
      env HOME="$HOME_DIR" PATH="$TEST_PATH" \
        MAESTRO_MAX_ROUNDS="$rounds" \
        MAESTRO_TEST_JOB_PHASE=completed \
        MAESTRO_TEST_RESULT="$result" \
        MAESTRO_TEST_STATUS="$TEST_ROOT/status.json" \
        bash "$DISCUSSION" --turn "$turn" "$slug" 30 1
  ) > "$output" 2>&1
}

t1_workspace_keys_do_not_collide() {
  local left right left_out right_out left_t right_t
  left="$TEST_ROOT/collision/a-b"
  right="$TEST_ROOT/collision/a/b"
  new_repo "$left"
  new_repo "$right"
  left_out="$TEST_ROOT/left-new.out"
  right_out="$TEST_ROOT/right-new.out"
  run_new "$left" same "$left_out" || { cat "$left_out"; return 1; }
  run_new "$right" same "$right_out" || { cat "$right_out"; return 1; }
  left_t=$(transcript_from "$left_out")
  right_t=$(transcript_from "$right_out")
  [ -n "$left_t" ] && [ -n "$right_t" ] || { echo "transcript paths missing"; return 1; }
  [ "$left_t" != "$right_t" ] || { echo "colliding roots share $left_t"; return 1; }
  [ "$(mode_of "$(dirname "$left_t")")" = 700 ] || { echo "discussion directory is not 0700"; return 1; }
  [ "$(mode_of "$left_t")" = 600 ] || { echo "transcript is not 0600"; return 1; }
}

t2_content_headings_do_not_control_rounds_and_last_marker_wins() {
  local repo first second first_out second_out transcript
  repo="$TEST_ROOT/control-repo"
  new_repo "$repo"
  run_new "$repo" control "$TEST_ROOT/control-new.out" || return 1
  transcript=$(transcript_from "$TEST_ROOT/control-new.out")
  first="$TEST_ROOT/first-turn.md"
  second="$TEST_ROOT/second-turn.md"
  cat > "$first" <<'EOF'
Quote examples only:
### Claude
### Claude
### Codex
### Claude
EOF
  printf 'second real turn\n' > "$second"
  first_out="$TEST_ROOT/first-turn.out"
  second_out="$TEST_ROOT/second-turn.out"
  run_turn "$repo" "$first" control $'STANCE: REFRAME\nCONVERGED: rejected draft\nESCALATE: actual final fork' "$first_out" 2 ||
    { cat "$first_out"; return 1; }
  grep -q 'DISCUSSION_STATE: ESCALATE' "$first_out" ||
    { echo "last ESCALATE marker did not win: $(tr '\n' ' ' < "$first_out")"; return 1; }
  run_turn "$repo" "$second" control $'STANCE: AGREE\nCONTINUE' "$second_out" 2 ||
    { echo "second real turn was rejected: $(tr '\n' ' ' < "$second_out")"; return 1; }
  [ "$(grep -c '^### Claude (turn ' "$transcript")" -eq 2 ] ||
    { echo "transcript does not contain exactly two generated Claude turns"; return 1; }
}

t3_dead_discussion_lock_is_reclaimed() {
  local repo transcript lock turn output
  repo="$TEST_ROOT/stale-lock-repo"
  new_repo "$repo"
  run_new "$repo" stale "$TEST_ROOT/stale-new.out" || return 1
  transcript=$(transcript_from "$TEST_ROOT/stale-new.out")
  lock="$transcript.lock"
  mkdir "$lock"
  printf 'token=dead\npid=999999\nprocess_start=dead\n' > "$lock/metadata"
  turn="$TEST_ROOT/stale-turn.md"
  output="$TEST_ROOT/stale-turn.out"
  printf 'recover stale lock\n' > "$turn"
  run_turn "$repo" "$turn" stale $'STANCE: AGREE\ncontinue' "$output" ||
    { echo "stale lock was not recovered: $(tr '\n' ' ' < "$output")"; return 1; }
  [ ! -d "$lock" ] || { echo "discussion lock survived completed turn"; return 1; }
}

t4_status_loss_uses_configured_read_only_retries() {
  local repo turn output calls retry_shim real_sleep rc starts cancels retries
  repo="$TEST_ROOT/status-loss-repo"
  new_repo "$repo"
  run_new "$repo" status-loss "$TEST_ROOT/status-loss-new.out" || return 1
  turn="$TEST_ROOT/status-loss-turn.md"
  output="$TEST_ROOT/status-loss-turn.out"
  calls="$TEST_ROOT/status-loss-calls.log"
  retry_shim="$TEST_ROOT/status-loss-shim"
  real_sleep=$(command -v sleep)
  mkdir -p "$retry_shim"
  cat > "$retry_shim/sleep" <<EOF
#!/usr/bin/env bash
exec "$real_sleep" 0.01
EOF
  chmod +x "$retry_shim/sleep"
  printf 'exercise status-loss retry\n' > "$turn"
  : > "$calls"
  (
    cd "$repo" || exit 1
    env HOME="$HOME_DIR" PATH="$retry_shim:$TEST_PATH" \
      MAESTRO_DISCUSSION_RETRIES=2 \
      MAESTRO_RETRY_SLEEP=0 \
      MAESTRO_TEST_CALL_LOG="$calls" \
      MAESTRO_TEST_JOB_STATUS_RAW='{malformed' \
      MAESTRO_TEST_STATUS="$TEST_ROOT/status.json" \
      bash "$DISCUSSION" --turn "$turn" status-loss 30 1
  ) > "$output" 2>&1
  rc=$?
  [ "$rc" -eq 4 ] || { echo "rc=$rc want exhausted-retry failure 4"; return 1; }
  starts=$(grep -c '^task ' "$calls" || true)
  cancels=$(grep -c '^cancel ' "$calls" || true)
  retries=$(grep -c '^DISCUSSION_RETRY:' "$output" || true)
  [ "$starts" -eq 3 ] || { echo "task starts=$starts want 3: $(tr '\n' ' ' < "$output")"; return 1; }
  [ "$cancels" -eq 3 ] || { echo "cancel attempts=$cancels want 3"; return 1; }
  [ "$retries" -eq 2 ] || { echo "retry messages=$retries want 2"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Discussion state verification ===\n'
check t1_workspace_keys_do_not_collide "workspace transcript keys are collision-resistant and private"
check t2_content_headings_do_not_control_rounds_and_last_marker_wins "content headings are inert and last terminal marker wins"
check t3_dead_discussion_lock_is_reclaimed "dead discussion locks are safely reclaimed"
check t4_status_loss_uses_configured_read_only_retries "read-only status loss consumes configured retries"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
