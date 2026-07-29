#!/usr/bin/env bash
# Maestro discussion loop.
# Bidirectional, multi-turn debate between the orchestrator (Claude) and Codex —
# design, architecture, solution duels, root-cause debugging. READ-ONLY: nobody
# edits code while the design is still being argued.
#
# Claude drives the loop like a user would: it writes its turn to a file, this
# script appends it to the running transcript, dispatches the WHOLE transcript to
# Codex, and prints the reply. Codex shares no context between calls, so the
# transcript is the entire memory — quote evidence in it, never paraphrase.
#
# Usage:
#   discussion-loop.sh --new "<topic>" [slug]              start a fresh transcript
#   discussion-loop.sh --turn <turn-file> [slug] [max_idle_sec] [poll_sec]
# Transcript: ~/.maestro/discussions/<workspace-key>-<slug>.md
#             (default slug: main)
#
# Termination (enforced): after MAESTRO_MAX_ROUNDS Claude turns (default 6) the
# script refuses another turn — converge with a stated assumption or ESCALATE.
# After each reply the script prints DISCUSSION_STATE: CONVERGED | ESCALATE |
# CONTINUE to stderr, so the orchestrator never has to guess whether to stop.
#
# Error handling: transient job failures are retried (MAESTRO_DISCUSSION_RETRIES,
# default 2, backoff MAESTRO_RETRY_SLEEP seconds, default 5) — read-only retries
# are free. Hangs are NOT auto-retried (a hang is usually prompt-induced). A
# per-transcript lock stops two turns racing; an orphaned Claude turn (dispatch
# died before the reply) is replaced, not duplicated, on the next --turn.
#
# Exit codes: 0 = reply printed | 5 = round cap | 124 = hung, cancelled
#             3 = could not start / bad args | 4 = job failed after retries
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-companion.sh
. "$HERE/lib-companion.sh"
progress_init

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
DISCUSSION_LOCK=""
maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}
maestro_interrupt() {
  maestro_finish "INTERRUPTED" 4
}
cleanup() {
  trap - EXIT HUP INT TERM
  [ -n "$DISCUSSION_LOCK" ] && rmdir "$DISCUSSION_LOCK" 2>/dev/null
  progress "MAESTRO_FINAL: DISCUSSION $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap maestro_interrupt HUP INT TERM

SLUG="main"
MODE="${1:-}"

valid_slug() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }

transcript_path() {
  local root key
  # Anchor to the repo root so subdirectories share one workspace transcript.
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
  key=$(printf '%s' "$root" | tr -c 'A-Za-z0-9' '-')
  DISCUSS_DIR="$HOME/.maestro/discussions"
  mkdir -p "$DISCUSS_DIR"
  T="$DISCUSS_DIR/${key}-${SLUG}.md"

  # Best-effort migration keeps an in-flight discussion intact.
  OLD_T="/tmp/maestro-discussion-${SLUG}.md"
  if [ -f "$OLD_T" ] && [ ! -f "$T" ]; then
    mv "$OLD_T" "$T" 2>/dev/null || :
  fi
}

if [ "$MODE" = "--new" ]; then
  [ $# -ge 2 ] || { echo "DISCUSSION_ERROR: topic required after --new" >&2; maestro_finish "FAILED" 3; }
  TOPIC="$2"
  SLUG="${3:-main}"
  valid_slug "$SLUG" || { echo "DISCUSSION_ERROR: slug may only contain [a-zA-Z0-9_-]" >&2; maestro_finish "FAILED" 3; }
  transcript_path
  if [ -f "$T" ]; then
    echo "DISCUSSION_ERROR: transcript already exists: $T (pick another slug or remove it)" >&2
    maestro_finish "FAILED" 3
  fi
  printf '# Discussion: %s\n\n' "$TOPIC" > "$T"
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
transcript_path
if [ ! -f "$T" ]; then
  echo "DISCUSSION_ERROR: no transcript at $T — start one with --new \"<topic>\" ${SLUG}" >&2
  maestro_finish "FAILED" 3
fi
if [ ! -f "$FILE" ]; then
  echo "DISCUSSION_ERROR: turn file not found: $FILE" >&2
  maestro_finish "FAILED" 3
fi

# Round cap — checked BEFORE dispatching, so a capped discussion costs nothing.
TURNS=$(grep -c '^### Claude' "$T" || true)
if [ "$TURNS" -ge "$MAX_ROUNDS" ]; then
  echo "DISCUSSION_CAP: ${MAX_ROUNDS} turns exhausted. Do not re-run: either state the design" >&2
  echo "with its deciding assumption and proceed to planning, or ESCALATE the exact fork" >&2
  echo "(both options + each side's case) to the user." >&2
  maestro_finish "ESCALATE" 5
fi

# One turn at a time per transcript.
LOCK="$T.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "DISCUSSION_ERROR: another turn is in progress for $T (lock: $LOCK)" >&2
  maestro_finish "FAILED" 3
fi
DISCUSSION_LOCK="$LOCK"

# Discussion doctrine — appended to every turn so Codex debates with discipline by
# default. Adversarial in both directions: no manufactured objections, AND no
# manufactured agreement. Grilling is the job; politeness is not.
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
  context7) ARE available — use them to verify version-sensitive facts (library
  versions, API changes, current docs) instead of trusting training data. Max 2
  lookups per turn; if a lookup fails or stalls, do NOT retry — mark it
  "RESEARCH NEEDED: <question>" and argue from what you have.
- When an MCP check changes your position, name it: "verified via context7: <fact>"
  beats an unsupported claim. When it does not change your position, say nothing.
- You have read-only repo access: ground claims in the actual code (git log, blame,
  ripgrep) whenever the debate touches reality.
- If the decision genuinely belongs to the human (product taste, irreversible
  tradeoff, budget), end with:
    ESCALATE: <the exact fork — both options, the case for each, your recommendation>
- If the design is settled, end with:
    CONVERGED: <the agreed design in 2-3 lines — including what the losing
    alternatives were and why they lost>
- Stay under ~300 words.'

C=$(companion_resolve) || {
  echo "DISCUSSION_ERROR: codex-companion.mjs not found. Is the openai/codex-plugin-cc plugin installed? (run: /plugin install codex@openai-codex)" >&2
  maestro_finish "FAILED" 3
}

PIN=$(companion_pin 2>/dev/null) || {
  echo "DISCUSSION_ERROR: no Codex model/effort pinned — run codex-model-select.sh <model> <effort> first." >&2
  maestro_finish "FAILED" 3
}
PIN_MODEL=${PIN%%$'\t'*}
PIN_EFFORT=${PIN#*$'\t'}
PIN_EFFORT=${PIN_EFFORT%%$'\t'*}

# If the previous Claude turn never got a Codex reply (dispatch died, hang, job
# failed), replace that orphaned turn instead of appending a duplicate.
LAST_CLAUDE=$(grep -n '^### Claude' "$T" | tail -1 | cut -d: -f1 || true)
LAST_CODEX=$(grep -n '^### Codex' "$T" | tail -1 | cut -d: -f1 || true)
LAST_CODEX=${LAST_CODEX:-0}
if [ -n "$LAST_CLAUDE" ] && [ "$LAST_CLAUDE" -gt "$LAST_CODEX" ]; then
  head -n $((LAST_CLAUDE - 1)) "$T" > "$T.tmp.$$" && mv "$T.tmp.$$" "$T"
  TURNS=$((TURNS - 1))
fi

# Append Claude's turn to the transcript, then dispatch the whole thing.
N=$((TURNS + 1))
printf '\n### Claude (turn %s)\n\n' "$N" >> "$T"
cat "$FILE" >> "$T"
printf '\n' >> "$T"

PROMPT="$(cat "$T")${DOCTRINE}"

# READ-ONLY on purpose: no write flag here. Debate mode argues; the implementer
# path is the only one that edits code, and only after convergence.
REPLY=""
attempt=0
while :; do
  attempt=$((attempt + 1))
  JOB=$(companion_start "$C" "$PROMPT") || {
    echo "DISCUSSION_ERROR: could not start Codex job (see above)." >&2
    maestro_finish "FAILED" 3
  }
  progress "DISCUSSION: turn $N dispatched as $JOB (model=$PIN_MODEL effort=$PIN_EFFORT, read-only, attempt $attempt, max_idle=${MAX_IDLE}s poll=${POLL}s)"
  companion_verify_pin "$C" "$JOB" "$PIN_MODEL" "$PIN_EFFORT" || :

  companion_poll "$C" "$JOB" "$MAX_IDLE" "$POLL"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "DISCUSSION_HUNG: job $JOB stalled; cancelled. Your turn is saved in $T — re-run --turn to retry, or proceed alone." >&2
    maestro_finish "HUNG" 124
  fi

  if [ "$rc" -eq 0 ]; then
    if REPLY=$(companion_result "$C" "$JOB"); then
      break
    fi
    rc=4
  fi

  # rc is 4 (failed) or 6 (status-lost) — transient; retry if attempts remain.
  if [ "$attempt" -le "$RETRIES" ]; then
    left=$((RETRIES - attempt + 1))
    word="retries"; [ "$left" -eq 1 ] && word="retry"
    echo "DISCUSSION_RETRY: attempt $attempt failed; retrying in ${RETRY_SLEEP}s ($left $word left)" >&2
    sleep "$RETRY_SLEEP"
  else
    echo "DISCUSSION_FAILED: job failed after $attempt attempt(s). Your turn is saved in $T — re-run --turn to retry, or proceed alone." >&2
    maestro_finish "FAILED" 4
  fi
done

printf '\n### Codex (turn %s · model=%s effort=%s)\n\n%s\n' "$N" "$PIN_MODEL" "$PIN_EFFORT" "$REPLY" >> "$T"
printf '%s\n' "$REPLY"

# Machine-readable state so the orchestrator knows whether the debate is over
# without parsing prose.
if printf '%s' "$REPLY" | grep -q '^CONVERGED:'; then
  FINAL_STATE="CONVERGED"
  progress "DISCUSSION_STATE: CONVERGED — extract the agreed design into the plan's Decisions section"
elif printf '%s' "$REPLY" | grep -q '^ESCALATE:'; then
  FINAL_STATE="ESCALATE"
  progress "DISCUSSION_STATE: ESCALATE — relay the fork verbatim to the user before continuing"
else
  FINAL_STATE="CONTINUE"
  progress "DISCUSSION_STATE: CONTINUE — write your next turn and re-run --turn (or converge yourself and say why)"
fi
printf '%s' "$REPLY" | grep -q '^STANCE:' || \
  echo "DISCUSSION_WARN: reply opened without a STANCE line — weigh it accordingly" >&2
maestro_finish "$FINAL_STATE" 0
