#!/usr/bin/env bash
# Maestro implementer watchdog — single dispatch.
# Dispatches a written implementation plan to Codex as a background job via the
# codex-plugin-cc companion — WITH write access, so Codex edits the files itself —
# polls its log, cancels it if it stalls (no log growth), and prints the result.
# Appends the implementer contract (execute-the-plan discipline + structured RESULT
# lines) to every dispatch, so callers never retype it.
#
# For "keep going until it is verifiably done" work, prefer implementer-loop.sh,
# which wraps this script in a bounded, evidence-fed, self-verifying loop.
#
# Usage: implementer-watchdog.sh "<plan>" [max_idle_sec] [poll_sec]
#        implementer-watchdog.sh --file <plan_file> [max_idle_sec] [poll_sec]
#   --file:       read the plan from a file — the normal path; a plan with exact
#                 steps and verification commands corrupts in shell quoting
#   max_idle_sec: cancel if the job log does not grow for this long (default 300 = 5 min)
#   poll_sec:     status/log poll interval (default 20)
#
# NO blind retries here by design: a failed write-mode job may have left the tree
# half-edited, so re-dispatching the identical plan risks double-applying. The
# loop script re-dispatches with the failure evidence instead. On success the
# script prints IMPLEMENTER_STATE: DONE|NEEDS_ANSWERS|BLOCKED|FAILED|MISSING to
# stderr so callers never parse prose for the verdict.
#
# Exit codes: 0 = DONE result printed | 10 = NEEDS_ANSWERS result printed
#             11 = BLOCKED result printed or write lock held | 124 = read-only timeout
#             125 = write cancellation poisoned the lease
#             3 = could not start | 4 = job failed or result missing
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-companion.sh
. "$HERE/lib-companion.sh"
progress_init

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
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
  write_lock_release
  progress "MAESTRO_FINAL: WATCHDOG $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap maestro_interrupt HUP INT TERM

if [ "${1:-}" = "--file" ]; then
  [ $# -ge 2 ] || { echo "WATCHDOG_ERROR: plan file required after --file" >&2; maestro_finish "FAILED" 3; }
  FILE="$2"
  if [ ! -f "$FILE" ]; then
    echo "WATCHDOG_ERROR: plan file not found: $FILE" >&2
    maestro_finish "FAILED" 3
  fi
  PROMPT=$(cat "$FILE")
  shift 2
else
  [ $# -ge 1 ] || { echo "WATCHDOG_ERROR: plan required" >&2; maestro_finish "FAILED" 3; }
  PROMPT="$1"
  shift 1
fi
MAX_IDLE="${1:-300}"
POLL="${2:-20}"

write_lock_acquire
lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  [ "$lock_rc" -eq 11 ] && maestro_finish "BLOCKED" 11
  maestro_finish "FAILED" "$lock_rc"
fi

# Implementer contract — appended to every dispatch so each run is disciplined by
# default. Codex is the hands, not the brain: it executes THIS plan, it does not
# redesign it. Ambiguity is returned as QUESTIONS, never resolved by guessing —
# the background job cannot ask interactively, so structured stops are the only
# channel back to the orchestrator.
CONTRACT='

--- IMPLEMENTER CONTRACT (always applies) ---
- You are the implementer, not the planner. Execute the plan above exactly as written.
  Do not redesign, expand scope, or "improve" adjacent code. Touch only the files the plan names.
- Write access is real: every edit you make lands on disk. Stay inside the plan'"'"'s file scope.
- Built-in web search is disabled (it hangs). The orchestrator has embedded the external
  facts you need; for anything version-sensitive it missed, you MAY verify via your
  configured MCP tools (e.g. tavily, context7) — max 2 lookups per run, never as a
  substitute for the plan. If a lookup fails or stalls, do NOT retry: if the fact is
  load-bearing, use the QUESTIONS channel; otherwise proceed with the plan'"'"'s fact.
- When you implement against an MCP-verified version or API, note
  "verified via <mcp>: <fact>" in your report so the reviewer knows the ground truth used.
- If the plan is ambiguous, contradicts what you find in the code, or a step fails twice,
  STOP immediately. Do not guess, do not improvise a different approach. End with:
    RESULT: NEEDS_ANSWERS
    QUESTIONS:
    1. <question — what you found, what you need decided, and what each answer implies>
- Exception, and the ONLY one: if the plan states a default or a scope grant that covers
  the ambiguity, apply it and keep going. Record the line
    DEFAULT_APPLIED: <what you applied> — <the plan text that granted it>
  in your report. This is not a result state and never replaces the RESULT line; it is a
  disclosure for the reviewer. If the plan does not cover it, STOP as above — a default you
  invented is a guess, not a grant.
- Whenever you stop with NEEDS_ANSWERS or BLOCKED, the job ends and your thread is gone.
  Everything the next run needs must be written down. End with a capsule:
    CONTINUATION:
    - Completed: <steps finished, and the files they touched>
    - Evidence: <the exact failing output or constraint that stopped you>
    - Next: <the immediate next step for each possible answer>
  Write it for a fresh implementer with no memory of this run, because that is who reads it.
- Run the plan'"'"'s verification commands yourself and paste their ACTUAL output and exit
  codes. A claim without output is not verification.
- End every run with exactly ONE result line, then the evidence:
    RESULT: DONE            — plan fully executed, verification output pasted below
    RESULT: NEEDS_ANSWERS   — followed by a QUESTIONS: block (numbered)
    RESULT: BLOCKED         — missing access/credentials or a destructive step; name the blocker
    RESULT: FAILED          — verification failed; paste the failing output
- Report the list of files you created or modified. Never silently leave stray files.
- Before your first edit, run `git status --short` and note what was already dirty. In this workflow
  the tree is normally dirty (plan files, notes, untracked docs) — that is never a reason to stop and
  never a gate. Preserve every pre-existing change: do not revert, stash, checkout, or commit work
  you did not make, and keep prior edits to files you also touch. In your report, list the
  pre-existing dirty paths you observed and confirm you left the out-of-scope ones untouched.
- Keep the final report under ~400 words, plus the verification output and any `CONTINUATION:`
  capsule. Your reader is another model reviewing your diff, not a human reading a report.
- Write the laziest thing that works: reuse what the repo already has, prefer the standard
  library and native features over new code, and never add an abstraction, dependency, or
  config knob the plan did not ask for. Shortest working diff wins. Mark a deliberate
  shortcut with a `ponytail:` comment naming its ceiling.'
PROMPT="${PROMPT}${CONTRACT}"

C=$(companion_resolve) || {
  echo "WATCHDOG_ERROR: codex-companion.mjs not found. Is the openai/codex-plugin-cc plugin installed? (run: /plugin install codex@openai-codex)" >&2
  maestro_finish "FAILED" 3
}

PIN=$(companion_pin 2>/dev/null) || {
  echo "WATCHDOG_ERROR: no Codex model/effort pinned — run codex-model-select.sh <model> <effort> first." >&2
  maestro_finish "FAILED" 3
}
PIN_MODEL=${PIN%%$'\t'*}
PIN_EFFORT=${PIN#*$'\t'}
PIN_DEBATE_EFFORT=${PIN_EFFORT%%$'\t'*}
PIN_EFFORT=${PIN_EFFORT#*$'\t'}
case "$PIN_EFFORT" in max|ultra) PIN_EFFORT="$PIN_DEBATE_EFFORT" ;; esac

JOB=$(companion_start "$C" "$PROMPT" write) || {
  echo "WATCHDOG_ERROR: could not start Codex job (see above)." >&2
  maestro_finish "FAILED" 3
}
write_lock_set_job "$JOB"
progress "WATCHDOG: started $JOB (model=$PIN_MODEL effort=$PIN_EFFORT, write mode, max_idle=${MAX_IDLE}s poll=${POLL}s)"
companion_verify_pin "$C" "$JOB" "$PIN_MODEL" "$PIN_EFFORT" || :

companion_poll "$C" "$JOB" "$MAX_IDLE" "$POLL"
rc=$?
case "$rc" in
  0)
    if ! OUT=$(companion_result "$C" "$JOB"); then
      echo "WATCHDOG_FAILED: job $JOB completed but returned no result. Continue on Opus alone." >&2
      maestro_finish "FAILED" 4
    fi
    printf '%s\n' "$OUT"
    STATE=$(printf '%s' "$OUT" | grep -oE '^RESULT:[[:space:]]*(DONE|NEEDS_ANSWERS|BLOCKED|FAILED)' | head -1 | sed 's/^RESULT:[[:space:]]*//')
    if [ -n "$STATE" ]; then
      FINAL_STATE="$STATE"
      echo "IMPLEMENTER_STATE: $STATE" >&2
    else
      echo "IMPLEMENTER_STATE: MISSING (no RESULT line — treat as FAILED and re-dispatch with the output)" >&2
      maestro_finish "MISSING" 4
    fi
    case "$STATE" in
      DONE) maestro_finish "DONE" 0 ;;
      NEEDS_ANSWERS) maestro_finish "NEEDS_ANSWERS" 10 ;;
      BLOCKED) maestro_finish "BLOCKED" 11 ;;
      FAILED) maestro_finish "FAILED" 4 ;;
    esac ;;
  124)
    progress "WATCHDOG_HUNG: job $JOB was cancelled; no retry was started."
    maestro_finish "HUNG" 124 ;;
  125)
    reason=${MAESTRO_CANCEL_REASON:-unknown}
    if [ "${MAESTRO_CANCEL_REQUESTED:-1}" -eq 0 ]; then
      progress "WATCHDOG_POISONED: job $JOB was not cancelled because poison metadata could not be staged and may still be running; the write lease is retained and this run is over."
    else
      progress "WATCHDOG_POISONED: job $JOB was cancelled ($reason) and turn quiescence could not be confirmed; the write lease is retained and this run is over."
    fi
    progress "WATCHDOG_POISONED: recover only after no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
    printf 'RESULT: BLOCKED\n'
    maestro_finish "POISONED" 125 ;;
  6)
    echo "WATCHDOG_FAILED: companion status unreachable; job $JOB state unknown. Check the tree before re-dispatching." >&2
    maestro_finish "FAILED" 4 ;;
  *)
    echo "WATCHDOG_FAILED: job $JOB ended failed. Re-dispatch with the failure evidence, or ask the user." >&2
    maestro_finish "FAILED" 4 ;;
esac
