#!/usr/bin/env bash
# Maestro autonomous implementation loop.
# Wraps implementer-watchdog.sh in a bounded, evidence-fed, self-verifying loop:
# dispatch the plan → parse the RESULT → on DONE, re-run the verification command
# LOCALLY (a claim is not proof) → on failure, append the actual failing output
# to the next dispatch so Codex never repeats an approach blind. Loops until the
# task is verifiably implemented, needs human input, or hits the iteration cap.
#
# This is the default dispatch path for "keep going until it is done" work.
# It needs no babysitting between iterations — the only exits are the states below.
#
# Usage:
#   implementer-loop.sh --plan <plan-file> --verify "<command>"
#                       [--max-iters N] [--max-idle S] [--poll S]
#
#   --plan       the five-part plan file (same contract as the watchdog --file)
#   --verify     command run LOCALLY after every RESULT: DONE claim. Exit 0 = pass.
#                Required: the loop's whole point is that Codex's word is not proof.
#   --max-iters  cap on dispatch rounds (default 4). 0 is prohibited — an
#                unbounded write loop is a runaway, not autonomy.
#
# Exit codes: 0  = verified done
#             10 = NEEDS_ANSWERS (questions on stdout — relay to user, append
#                  answers to the plan, re-run)
#             11 = BLOCKED (credentials/destructive step — surface, never improvise)
#             12 = STUCK at iteration cap (attempts log on stderr — re-plan or
#                  escalate; do not just raise --max-iters)
#             3  = bad args / could not start
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCHDOG="$HERE/implementer-watchdog.sh"
# shellcheck source=lib-companion.sh
. "$HERE/lib-companion.sh"
progress_init

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
ATTEMPTS=""; DISPATCH=""; ERRF=""
maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}
maestro_interrupt() {
  maestro_finish "INTERRUPTED" 4
}
cleanup() {
  local provenance_line=""
  trap - EXIT HUP INT TERM
  [ -n "$ATTEMPTS" ] && rm -f "$ATTEMPTS"
  [ -n "$DISPATCH" ] && rm -f "$DISPATCH"
  [ -n "$ERRF" ] && rm -f "$ERRF"
  write_lock_release
  provenance_line=$(provenance_check 2>/dev/null) || :
  [ -n "$provenance_line" ] && progress "$provenance_line"
  progress "MAESTRO_FINAL: LOOP $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap maestro_interrupt HUP INT TERM

PLAN=""; VERIFY=""; MAX_ITERS=4; MAX_IDLE=300; POLL=20
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --plan needs a file" >&2; maestro_finish "FAILED" 3; }
      PLAN="$2"; shift 2 ;;
    --verify)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --verify needs a command" >&2; maestro_finish "FAILED" 3; }
      VERIFY="$2"; shift 2 ;;
    --max-iters)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --max-iters needs a number" >&2; maestro_finish "FAILED" 3; }
      MAX_ITERS="$2"; shift 2 ;;
    --max-idle)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --max-idle needs seconds" >&2; maestro_finish "FAILED" 3; }
      MAX_IDLE="$2"; shift 2 ;;
    --poll)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --poll needs seconds" >&2; maestro_finish "FAILED" 3; }
      POLL="$2"; shift 2 ;;
    *) echo "LOOP_ERROR: unknown argument: $1" >&2; maestro_finish "FAILED" 3 ;;
  esac
done

[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "LOOP_ERROR: --plan <file> required and must exist" >&2; maestro_finish "FAILED" 3; }
[ -n "$VERIFY" ] || { echo "LOOP_ERROR: --verify \"<command>\" required — RESULT: DONE is a claim, not proof" >&2; maestro_finish "FAILED" 3; }
[ "$MAX_ITERS" -ge 1 ] 2>/dev/null || { echo "LOOP_ERROR: --max-iters must be >= 1 (0 is prohibited)" >&2; maestro_finish "FAILED" 3; }
[ -f "$WATCHDOG" ] || { echo "LOOP_ERROR: implementer-watchdog.sh not found next to this script" >&2; maestro_finish "FAILED" 3; }

write_lock_acquire
lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  [ "$lock_rc" -eq 11 ] && maestro_finish "BLOCKED" 11
  maestro_finish "FAILED" "$lock_rc"
fi

ATTEMPTS=$(mktemp /tmp/maestro-attempts.XXXXXXXX)
ERRF=$(mktemp /tmp/maestro-looperr.XXXXXXXX)

i=0
while [ "$i" -lt "$MAX_ITERS" ]; do
  i=$((i + 1))
  DISPATCH=$(mktemp /tmp/maestro-dispatch.XXXXXXXX)
  cat "$PLAN" > "$DISPATCH"
  if [ -s "$ATTEMPTS" ]; then
    {
      printf '\n\n--- PRIOR ATTEMPTS IN THIS LOOP (always applies when present) ---\n'
      printf -- '- The working tree already contains these attempts'"'"' edits. Continue from the\n'
      printf '  current state; do NOT restart from scratch, and never repeat a failed approach\n'
      printf '  unchanged. Fix the specific failure shown, then re-run the verification.\n'
      cat "$ATTEMPTS"
    } >> "$DISPATCH"
  fi

  progress "LOOP: iteration $i/$MAX_ITERS — dispatching to Codex"
  : > "$ERRF"
  OUT=$(bash "$WATCHDOG" --file "$DISPATCH" "$MAX_IDLE" "$POLL" 2>"$ERRF")
  rc=$?
  cat "$ERRF" >&2
  rm -f "$DISPATCH"; DISPATCH=""

  if [ "$rc" -eq 3 ]; then
    echo "LOOP_ERROR: dispatch could not start (see above)." >&2
    maestro_finish "FAILED" 3
  fi

  STATE=$(printf '%s' "$OUT" | grep -oE '^RESULT:[[:space:]]*(DONE|NEEDS_ANSWERS|BLOCKED|FAILED)' | head -1 | sed 's/^RESULT:[[:space:]]*//')

  if { [ "$rc" -eq 124 ] || [ "$rc" -ne 0 ]; } &&
    ! { [ "$rc" -eq 10 ] && [ "$STATE" = "NEEDS_ANSWERS" ]; } &&
    ! { [ "$rc" -eq 11 ] && [ "$STATE" = "BLOCKED" ]; }; then
    kind="failed"; [ "$rc" -eq 124 ] && kind="hung"
    printf '\n## Attempt %s — job %s before producing a result\n%s\n' "$i" "$kind" \
      "$(tail -n 40 "$ERRF")" >> "$ATTEMPTS"
    progress "LOOP: iteration $i $kind — re-dispatching with the evidence"
    continue
  fi

  case "$STATE" in
    NEEDS_ANSWERS)
      printf '%s\n' "$OUT"
      progress "LOOP_STATE: NEEDS_ANSWERS after $i iteration(s) — relay the QUESTIONS verbatim to the user, append the answers to the plan file, and re-run this loop."
      maestro_finish "NEEDS_ANSWERS" 10 ;;
    BLOCKED)
      printf '%s\n' "$OUT"
      progress "LOOP_STATE: BLOCKED after $i iteration(s) — surface the blocker; never improvise around credentials or destructive steps."
      maestro_finish "BLOCKED" 11 ;;
    DONE)
      progress "LOOP: RESULT: DONE on iteration $i — verifying locally: $VERIFY"
      # Close FD 3 so verifier progress re-points to stdout and lands in VOUT instead of the operator channel.
      VOUT=$(bash -c "$VERIFY" 2>&1 3>&-)
      vrc=$?
      if [ "$vrc" -eq 0 ]; then
        printf '%s\n' "$OUT"
        progress "LOOP_STATE: VERIFIED_DONE after $i iteration(s) — local verification passed."
        maestro_finish "VERIFIED_DONE" 0
      fi
      printf '\n## Attempt %s — claimed DONE but LOCAL verification failed (exit %s): %s\n%s\n' \
        "$i" "$vrc" "$VERIFY" "$(printf '%s' "$VOUT" | tail -n 60)" >> "$ATTEMPTS"
      progress "LOOP: iteration $i claimed DONE but verification failed (exit $vrc) — re-dispatching with the output"
      ;;
    FAILED|"")
      label="RESULT: FAILED"
      [ -z "$STATE" ] && label="no RESULT line (treated as FAILED)"
      printf '\n## Attempt %s — %s\n%s\n' "$i" "$label" \
        "$(printf '%s' "$OUT" | tail -n 80)" >> "$ATTEMPTS"
      progress "LOOP: iteration $i $label — re-dispatching with the evidence"
      ;;
  esac
done

progress "LOOP_STUCK: $MAX_ITERS iteration(s) without verified completion. Attempts log:"
tail -n 120 "$ATTEMPTS" >&2
progress "LOOP_STATE: STUCK — re-plan around the evidence above (a debugging discussion helps), or escalate to the user. Do not simply raise --max-iters."
maestro_finish "STUCK" 12
