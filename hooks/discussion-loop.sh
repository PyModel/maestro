#!/usr/bin/env bash
# Maestro read-only, bounded discussion loop.
# Transcript state is kept in a sidecar file so quoted Markdown headings cannot
# alter turn counting or orphan recovery.
set -uo pipefail
umask 077

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-companion.sh
. "$HERE/lib-companion.sh"
progress_init

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
DISCUSSION_LOCK=""
DISCUSSION_LOCK_TOKEN=""
maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}

discussion_lock_release() {
  local metadata token
  [ -n "$DISCUSSION_LOCK" ] && [ -n "$DISCUSSION_LOCK_TOKEN" ] || return 0
  metadata="$DISCUSSION_LOCK/metadata"
  token=$(write_lock_metadata_value "$metadata" token)
  [ "$token" = "$DISCUSSION_LOCK_TOKEN" ] || return 0
  rm -f "$metadata" 2>/dev/null || return 0
  rmdir "$DISCUSSION_LOCK" 2>/dev/null || :
}

maestro_interrupt() { maestro_finish "INTERRUPTED" 4; }
cleanup() {
  trap - EXIT HUP INT TERM
  discussion_lock_release
  progress "MAESTRO_FINAL: DISCUSSION $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap maestro_interrupt HUP INT TERM

SLUG="main"
MODE="${1:-}"
valid_slug() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }

transcript_path() {
  local root readable hash
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
  root=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  readable=$(basename "$root" | tr -c 'A-Za-z0-9' '-')
  hash=$(printf '%s' "$root" | git hash-object --stdin 2>/dev/null)
  hash=${hash:0:12}
  [ -n "$hash" ] || return 1
  DISCUSS_DIR="$HOME/.maestro/discussions"
  [ ! -L "$DISCUSS_DIR" ] || return 1
  mkdir -p "$DISCUSS_DIR" || return 1
  chmod 700 "$DISCUSS_DIR" || return 1
  T="$DISCUSS_DIR/${readable}-${hash}-${SLUG}.md"
  STATE="$T.state"
}

discussion_write_state() { # turns awaiting_reply rollback_bytes
  local tmp="$STATE.tmp.$$"
  if printf 'turns=%s\nawaiting_reply=%s\nrollback_bytes=%s\n' "$1" "$2" "$3" > "$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$STATE"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || :
  return 1
}

discussion_read_state() {
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || return 1
  STATE_TURNS=$(write_lock_metadata_value "$STATE" turns)
  STATE_AWAITING=$(write_lock_metadata_value "$STATE" awaiting_reply)
  STATE_ROLLBACK=$(write_lock_metadata_value "$STATE" rollback_bytes)
  case "$STATE_TURNS" in ''|*[!0-9]*) return 1 ;; esac
  case "$STATE_ROLLBACK" in ''|*[!0-9]*) return 1 ;; esac
  case "$STATE_AWAITING" in 0|1) ;; *) return 1 ;; esac
  return 0
}

discussion_lock_acquire() {
  local metadata recorded_token owner_pid owner_start current_start attempt token process_start reclaim_dir
  LOCK="$T.lock"
  metadata="$LOCK/metadata"
  attempt=0
  while [ "$attempt" -lt 2 ]; do
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    if mkdir -m 700 "$LOCK" 2>/dev/null; then
      process_start=$(write_lock_process_start "$$")
      [ -n "$process_start" ] || process_start=unavailable
      if ! printf 'token=%s\npid=%s\nprocess_start=%s\n' "$token" "$$" "$process_start" > "$metadata"; then
        rmdir "$LOCK" 2>/dev/null || :
        return 1
      fi
      DISCUSSION_LOCK="$LOCK"
      DISCUSSION_LOCK_TOKEN="$token"
      return 0
    fi
    [ -f "$metadata" ] || return 1
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    owner_pid=$(write_lock_metadata_value "$metadata" pid)
    owner_start=$(write_lock_metadata_value "$metadata" process_start)
    case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
    if kill -0 "$owner_pid" 2>/dev/null; then
      current_start=$(write_lock_process_start "$owner_pid")
      if [ -z "$current_start" ] || [ -z "$owner_start" ] ||
        [ "$owner_start" = unavailable ] || [ "$current_start" = "$owner_start" ]; then
        return 1
      fi
    fi
    [ -n "$recorded_token" ] || return 1
    [ "$(write_lock_metadata_value "$metadata" token)" = "$recorded_token" ] || return 1
    reclaim_dir="$LOCK/.reclaim"
    mkdir "$reclaim_dir" 2>/dev/null || return 1
    if [ "$(write_lock_metadata_value "$metadata" token)" != "$recorded_token" ]; then
      rmdir "$reclaim_dir" 2>/dev/null || :
      return 1
    fi
    if ! rm -f "$metadata" 2>/dev/null ||
      ! rmdir "$reclaim_dir" 2>/dev/null || ! rmdir "$LOCK" 2>/dev/null; then
      rmdir "$reclaim_dir" 2>/dev/null || :
      return 1
    fi
    progress "DISCUSSION: reclaimed stale transcript lock $LOCK"
    attempt=$((attempt + 1))
  done
  return 1
}

if [ "$MODE" = "--new" ]; then
  [ $# -ge 2 ] || { echo "DISCUSSION_ERROR: topic required after --new" >&2; maestro_finish "FAILED" 3; }
  TOPIC="$2"
  SLUG="${3:-main}"
  valid_slug "$SLUG" || { echo "DISCUSSION_ERROR: slug may only contain [a-zA-Z0-9_-]" >&2; maestro_finish "FAILED" 3; }
  transcript_path || { echo "DISCUSSION_ERROR: could not resolve a private transcript path" >&2; maestro_finish "FAILED" 3; }
  if [ -e "$T" ] || [ -e "$STATE" ]; then
    echo "DISCUSSION_ERROR: transcript already exists: $T (pick another slug or remove it)" >&2
    maestro_finish "FAILED" 3
  fi
  tmp="$T.tmp.$$"
  if ! printf '# Discussion: %s\n\n' "$TOPIC" > "$tmp" ||
    ! chmod 600 "$tmp" || ! mv -f "$tmp" "$T" ||
    ! discussion_write_state 0 0 0; then
    rm -f "$tmp" "$T" "$STATE" 2>/dev/null || :
    echo "DISCUSSION_ERROR: could not create transcript state at $T" >&2
    maestro_finish "FAILED" 3
  fi
  echo "DISCUSSION: started '$TOPIC' → $T"
  echo "Write your opening position to a file, then: discussion-loop.sh --turn <file> ${SLUG}"
  maestro_finish "CONTINUE" 0
fi

if [ "$MODE" != "--turn" ]; then
  echo "DISCUSSION_ERROR: usage: discussion-loop.sh --new \"<topic>\" [slug] | --turn <file> [slug] [max_idle] [poll]" >&2
  maestro_finish "FAILED" 3
fi

[ $# -ge 2 ] || { echo "DISCUSSION_ERROR: turn file required after --turn" >&2; maestro_finish "FAILED" 3; }
FILE="$2"
SLUG="${3:-main}"
MAX_IDLE="${4:-300}"
POLL="${5:-20}"
MAX_ROUNDS="${MAESTRO_MAX_ROUNDS:-6}"
RETRIES="${MAESTRO_DISCUSSION_RETRIES:-2}"
RETRY_SLEEP="${MAESTRO_RETRY_SLEEP:-5}"

valid_slug "$SLUG" || { echo "DISCUSSION_ERROR: slug may only contain [a-zA-Z0-9_-]" >&2; maestro_finish "FAILED" 3; }
for value in "$MAX_IDLE" "$POLL" "$MAX_ROUNDS" "$RETRIES" "$RETRY_SLEEP"; do
  case "$value" in ''|*[!0-9]*) echo "DISCUSSION_ERROR: bounds must be non-negative integers" >&2; maestro_finish "FAILED" 3 ;; esac
done
[ "$MAX_IDLE" -ge 1 ] && [ "$POLL" -ge 1 ] && [ "$MAX_ROUNDS" -ge 1 ] ||
  { echo "DISCUSSION_ERROR: max_idle, poll, and max rounds must be at least 1" >&2; maestro_finish "FAILED" 3; }
[ "$RETRIES" -le 10 ] || { echo "DISCUSSION_ERROR: retries must be at most 10" >&2; maestro_finish "FAILED" 3; }
transcript_path || { echo "DISCUSSION_ERROR: could not resolve transcript path" >&2; maestro_finish "FAILED" 3; }
[ -f "$T" ] || { echo "DISCUSSION_ERROR: no transcript at $T — start one with --new \"<topic>\" ${SLUG}" >&2; maestro_finish "FAILED" 3; }
[ -f "$FILE" ] || { echo "DISCUSSION_ERROR: turn file not found: $FILE" >&2; maestro_finish "FAILED" 3; }
if ! discussion_lock_acquire; then
  echo "DISCUSSION_ERROR: another turn is in progress or its owner cannot be disproved for $T (lock: $T.lock)" >&2
  maestro_finish "FAILED" 3
fi
if ! discussion_read_state; then
  echo "DISCUSSION_ERROR: transcript state is missing or malformed: $STATE" >&2
  maestro_finish "FAILED" 3
fi

if [ "$STATE_AWAITING" -eq 1 ]; then
  rollback_tmp="$T.rollback.$$"
  if ! dd if="$T" of="$rollback_tmp" bs=1 count="$STATE_ROLLBACK" 2>/dev/null ||
    ! chmod 600 "$rollback_tmp" || ! mv -f "$rollback_tmp" "$T"; then
    rm -f "$rollback_tmp" 2>/dev/null || :
    echo "DISCUSSION_ERROR: could not roll back orphaned turn" >&2
    maestro_finish "FAILED" 3
  fi
  STATE_TURNS=$((STATE_TURNS - 1))
  discussion_write_state "$STATE_TURNS" 0 0 || {
    echo "DISCUSSION_ERROR: could not persist orphan recovery" >&2
    maestro_finish "FAILED" 3
  }
fi
TURNS=$STATE_TURNS
if [ "$TURNS" -ge "$MAX_ROUNDS" ]; then
  echo "DISCUSSION_CAP: ${MAX_ROUNDS} turns exhausted. Do not re-run: either state the design" >&2
  echo "with its deciding assumption and proceed to planning, or ESCALATE the exact fork" >&2
  echo "(both options + each side's case) to the user." >&2
  maestro_finish "ESCALATE" 5
fi

DOCTRINE='

--- DISCUSSION DOCTRINE (always applies) ---
You are debating the orchestrator (another model) as a peer, not serving a user.
The text above is the full transcript so far; it is your only memory.
- Open with exactly one stance line: STANCE: AGREE / PUSHBACK / ALTERNATIVE / REFRAME
- Steelman the opposing position in one line before attacking it. Then attack the
  weakest load-bearing assumption, not the easiest target.
- If the question itself is wrong, use STANCE: REFRAME and state the right question.
- Name the single risk that should decide this, and what evidence would change your mind.
- No manufactured objections: a sound design gets STANCE: AGREE plus one line naming
  the assumption most likely to be wrong. No manufactured agreement either: if it is
  wrong, say so plainly and show why.
- In debugging duels: the winner is whichever hypothesis survives contact with the
  evidence, not the better argument. Demand the actual output, log, or code line that
  distinguishes the rival hypotheses — and say which experiment would settle it.
- Built-in web search is disabled (it hangs). Your configured MCP tools (e.g. tavily,
  context7) ARE available — max 2 lookups per turn.
- You have read-only repo access: ground claims in the actual code.
- If the decision belongs to the human, end with:
    ESCALATE: <the exact fork, both options, and recommendation>
- If the design is settled, end with:
    CONVERGED: <the agreed design and rejected alternatives>
- Stay under ~300 words.'

C=$(companion_resolve) || { echo "DISCUSSION_ERROR: codex-companion.mjs not found" >&2; maestro_finish "FAILED" 3; }
PIN=$(companion_pin 2>/dev/null) || { echo "DISCUSSION_ERROR: no Codex model/effort pinned" >&2; maestro_finish "FAILED" 3; }
PIN_MODEL=${PIN%%$'\t'*}
PIN_EFFORT=${PIN#*$'\t'}
PIN_EFFORT=${PIN_EFFORT%%$'\t'*}

N=$((TURNS + 1))
ROLLBACK_BYTES=$(wc -c < "$T" | tr -d ' ')
backup="$T.before.$$"
tmp="$T.tmp.$$"
if ! cp -p "$T" "$backup" || ! cp -p "$T" "$tmp" ||
  ! printf '\n### Claude (turn %s)\n\n' "$N" >> "$tmp" ||
  ! cat "$FILE" >> "$tmp" || ! printf '\n' >> "$tmp" ||
  ! chmod 600 "$tmp" || ! mv -f "$tmp" "$T" ||
  ! discussion_write_state "$N" 1 "$ROLLBACK_BYTES"; then
  [ -f "$backup" ] && mv -f "$backup" "$T" 2>/dev/null || :
  rm -f "$tmp" 2>/dev/null || :
  echo "DISCUSSION_ERROR: could not persist Claude turn" >&2
  maestro_finish "FAILED" 3
fi
rm -f "$backup"
PROMPT="$(cat "$T")${DOCTRINE}"

REPLY=""
attempt=0
while :; do
  attempt=$((attempt + 1))
  dispatch_started=$SECONDS
  JOB=$(companion_start "$C" "$PROMPT") || { echo "DISCUSSION_ERROR: could not start Codex job" >&2; maestro_finish "FAILED" 3; }
  progress "DISCUSSION: turn $N dispatched as $JOB (model=$PIN_MODEL effort=$PIN_EFFORT, read-only, attempt $attempt, max_idle=${MAX_IDLE}s poll=${POLL}s)"
  companion_verify_pin "$C" "$JOB" "$PIN_MODEL" "$PIN_EFFORT" || :
  companion_poll "$C" "$JOB" "$MAX_IDLE" "$POLL" "$dispatch_started"
  rc=$?
  if [ "$rc" -eq 124 ] && [ "${MAESTRO_CANCEL_REASON:-unknown}" != status-lost ]; then
    echo "DISCUSSION_HUNG: job $JOB stalled; cancelled. Your turn is saved in $T." >&2
    maestro_finish "HUNG" 124
  fi
  if [ "$rc" -eq 0 ] && REPLY=$(companion_result "$C" "$JOB"); then break; fi
  if [ "$attempt" -le "$RETRIES" ]; then
    left=$((RETRIES - attempt + 1)); word=retries; [ "$left" -eq 1 ] && word=retry
    echo "DISCUSSION_RETRY: attempt $attempt failed; retrying in ${RETRY_SLEEP}s ($left $word left)" >&2
    sleep "$RETRY_SLEEP"
  else
    echo "DISCUSSION_FAILED: job failed after $attempt attempt(s). Your turn is saved in $T." >&2
    maestro_finish "FAILED" 4
  fi
done

backup="$T.before.$$"
tmp="$T.tmp.$$"
if ! cp -p "$T" "$backup" || ! cp -p "$T" "$tmp" ||
  ! printf '\n### Codex (turn %s · model=%s effort=%s)\n\n%s\n' "$N" "$PIN_MODEL" "$PIN_EFFORT" "$REPLY" >> "$tmp" ||
  ! chmod 600 "$tmp" || ! mv -f "$tmp" "$T" ||
  ! discussion_write_state "$N" 0 "$ROLLBACK_BYTES"; then
  [ -f "$backup" ] && mv -f "$backup" "$T" 2>/dev/null || :
  rm -f "$tmp" 2>/dev/null || :
  echo "DISCUSSION_ERROR: reply was received but could not be persisted" >&2
  maestro_finish "FAILED" 3
fi
rm -f "$backup"
printf '%s\n' "$REPLY"

marker=$(printf '%s\n' "$REPLY" |
  sed -nE 's/^(CONVERGED|ESCALATE):[[:space:]].*$/\1/p' | tail -1)
case "$marker" in
  CONVERGED)
    FINAL_STATE="CONVERGED"
    progress "DISCUSSION_STATE: CONVERGED — extract the agreed design into the plan's Decisions section" ;;
  ESCALATE)
    FINAL_STATE="ESCALATE"
    progress "DISCUSSION_STATE: ESCALATE — relay the fork verbatim to the user before continuing" ;;
  *)
    FINAL_STATE="CONTINUE"
    progress "DISCUSSION_STATE: CONTINUE — write your next turn and re-run --turn" ;;
esac
printf '%s\n' "$REPLY" | sed -n '1p' | grep -q '^STANCE:' ||
  echo "DISCUSSION_WARN: reply opened without a STANCE line — weigh it accordingly" >&2
maestro_finish "$FINAL_STATE" 0
