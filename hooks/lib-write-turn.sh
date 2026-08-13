#!/usr/bin/env bash
# Maestro single Write turn module. Sourced, not executed.

[ "${_MAESTRO_WRITE_TURN_LOADED-0}" = 1 ] && return 0
_MAESTRO_WRITE_TURN_LOADED=1

_MAESTRO_WRITE_TURN_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-write-lease.sh
. "$_MAESTRO_WRITE_TURN_HERE/lib-write-lease.sh"

# Interface:
#   write_turn_run PLAN_FILE MAX_IDLE POLL RESULT_FILE EVIDENCE_FILE
#   write_turn_interrupt SIGNAL RESULT_FILE EVIDENCE_FILE
# The caller owns the surrounding Lease interval; this module owns one companion
# launch, poll, cancellation, result classification, and its temporary files.
_MAESTRO_WRITE_TURN_ACTIVE=inactive

_write_turn_positive_integer() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] 2>/dev/null ;;
  esac
}

_write_turn_result_state() {
  printf '%s\n' "$1" |
    sed -nE 's/^RESULT:[[:space:]]*(DONE|NEEDS_ANSWERS|BLOCKED|FAILED)[[:space:]]*$/\1/p' |
    tail -1
}
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
  codes. Run only the commands the plan'"'"'s Verification section names. Do not run additional
  wrapper, regression, or full suites, even when one seems prudent, and even when a suite you
  already ran turned red; fix the cause and re-run the named command. The caller'"'"'s --verify owns
  comprehensive verification and runs it after this dispatch, so a full suite here spends a
  deadline that is not yours to spend and gets the run cancelled. If a named command is not
  sufficient to prove the work, say so in the report and use the QUESTIONS channel; do not
  substitute a broader suite on your own initiative. A claim without output is not verification.
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


write_turn_lifecycle() { # [tick] | event job reason log
  local event="${1:-tick}" job="${2:-${_MAESTRO_WRITE_TURN_JOB:-unknown}}"
  local reason="${3:-unknown}" log="${4:-unknown}" rc model effort
  case "$event" in
    guard)
      _write_lease_turn_event guard "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      ;;
    started)
      _write_lease_turn_event started "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      _MAESTRO_WRITE_TURN_JOB=$job
      model=$(sed -n 's/^model=//p' "$_MAESTRO_WRITE_TURN_PROFILE" | head -1)
      effort=$(sed -n 's/^effort=//p' "$_MAESTRO_WRITE_TURN_PROFILE" | head -1)
      progress "WATCHDOG: started $job (model=${model:-unknown} effort=${effort:-unknown}, write mode, max_idle=${_MAESTRO_WRITE_TURN_MAX_IDLE}s poll=${_MAESTRO_WRITE_TURN_POLL}s)"
      ;;
    tick)
      _write_lease_turn_event tick "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      ;;
    cancel-begin)
      _write_lease_turn_event cancel-begin "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        progress "MAESTRO_LOCK: could not stage cancellation poison for job=$job reason=$reason; the job was not cancelled and may still be running (log: ${log:-unknown}). Recover only after no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
      fi
      return "$rc"
      ;;
    cancel-end)
      _write_lease_turn_event cancel-end "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        progress "MAESTRO_LOCK: poison metadata rename failed; retaining metadata.new as the fail-closed marker"
      fi
      if [ "$reason" = deadline ]; then
        progress "MAESTRO_RECOVERY: UNREPORTED_PARTIAL job=$job reason=deadline; the tree may contain incomplete edits and local verification did not run. Confirm quiescence, clear the poisoned lease, inspect the diff and targeted tests, then write an evidence-based continuation plan. Do not restart from scratch or auto-resume."
      fi
      return "$rc"
      ;;
    current-job)
      _write_lease_turn_event current-job "$job" "$reason" \
        "$_MAESTRO_WRITE_TURN_RESULT" "$_MAESTRO_WRITE_TURN_EVIDENCE"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      sed -n 's/^job=//p' "$_MAESTRO_WRITE_TURN_RESULT" | head -1
      ;;
    *)
      return 3
      ;;
  esac
}

write_turn_run() { # plan-file max-idle poll result-file evidence-file
  local plan="${1-}" max_idle="${2-}" poll="${3-}"
  local result="${4-}" evidence="${5-}" profile="${5-}.profile"
  local prompt_file="${5-}.prompt" rc state reason request profile_job
  [ -f "$plan" ] || return 3
  _write_turn_positive_integer "$max_idle" || return 3
  _write_turn_positive_integer "$poll" || return 3
  [ -n "$result" ] && [ -n "$evidence" ] && [ "$result" != "$evidence" ] ||
    return 3
  rm -f "$profile" "${profile}.new" "$prompt_file" || return 3
  {
    cat "$plan"
    printf '%s\n' "$CONTRACT"
  } > "$prompt_file" || return 3

  _MAESTRO_WRITE_TURN_RESULT=$result
  _MAESTRO_WRITE_TURN_EVIDENCE=$evidence
  _MAESTRO_WRITE_TURN_PROFILE=$profile
  _MAESTRO_WRITE_TURN_PROMPT=$prompt_file
  _MAESTRO_WRITE_TURN_MAX_IDLE=$max_idle
  _MAESTRO_WRITE_TURN_POLL=$poll
  _MAESTRO_WRITE_TURN_JOB=""
  _MAESTRO_WRITE_TURN_ACTIVE=live
  companion_turn write "$prompt_file" "$max_idle" "$poll" \
    "$result" "$profile" "$evidence" write_turn_lifecycle
  rc=$?
  case "$rc" in
    0|3|4) _MAESTRO_WRITE_TURN_ACTIVE=inactive ;;
    *) _MAESTRO_WRITE_TURN_ACTIVE=uncertain ;;
  esac
  if [ -z "$_MAESTRO_WRITE_TURN_JOB" ] && [ -f "$profile" ]; then
    profile_job=$(sed -n 's/^job=//p' "$profile" | head -1)
    [ "$profile_job" = unknown ] || _MAESTRO_WRITE_TURN_JOB=$profile_job
  fi
  rm -f "$prompt_file"

  case "$rc" in
    0)
      state=$(_write_turn_result_state "$(cat "$result")")
      rm -f "$profile" "${profile}.new"
      case "$state" in
        DONE) return 0 ;;
        NEEDS_ANSWERS) return 10 ;;
        BLOCKED) return 11 ;;
        FAILED) return 4 ;;
        *)
          printf 'IMPLEMENTER_STATE: COMPANION_FAILURE\n' >> "$evidence"
          printf '%s\n' "WATCHDOG_BLOCKED: job ${_MAESTRO_WRITE_TURN_JOB:-unknown} returned no valid full-line RESULT record; inspect the result and current diff before a fresh dispatch." >> "$evidence"
          return 11
          ;;
      esac
      ;;
    125)
      reason=$(sed -n 's/^cancel_reason=//p' "$profile" 2>/dev/null | head -1)
      request=$(sed -n 's/^cancel_request=//p' "$profile" 2>/dev/null | head -1)
      if [ "$reason" = launch-response-unparseable ]; then
        printf 'IMPLEMENTER_STATE: COMPANION_FAILURE\n' >> "$evidence"
        printf 'WATCHDOG_BLOCKED: task launch succeeded without a parseable job id; an untracked writer may still be running. Retained the write lease and companion job lock until repository-global status confirms quiescence.\n' >> "$evidence"
        progress "WATCHDOG_POISONED: task launch returned no job id; after confirming no Codex job is running, clear both retained locks with --clear-job-lock and --clear-lease."
      fi
      if [ -z "$request" ] || [ "$request" = unconfirmed ] ||
        [ "$request" = not-attempted ]; then
        progress "WATCHDOG_POISONED: job ${_MAESTRO_WRITE_TURN_JOB:-unknown} was not confirmed cancelled and may still be running; the write lease is retained and this run is over."
      else
        progress "WATCHDOG_POISONED: job ${_MAESTRO_WRITE_TURN_JOB:-unknown} was cancelled (${reason:-unknown}) and turn quiescence could not be confirmed; the write lease is retained and this run is over."
      fi
      progress "WATCHDOG_POISONED: recover only after no Codex job is writing: bash hooks/implementer-loop.sh --clear-lease (installed path: bash ~/.claude/hooks/implementer-loop.sh --clear-lease)"
      printf 'RESULT: BLOCKED\n' > "$result" || :
      rm -f "$profile" "${profile}.new"
      return 125
      ;;
    11)
      rm -f "$profile" "${profile}.new"
      return 11
      ;;
    3)
      printf '%s\n' "WATCHDOG_ERROR: could not start Codex job (see above)." >> "$evidence"
      rm -f "$profile" "${profile}.new"
      return 3
      ;;
    *)
      printf 'IMPLEMENTER_STATE: COMPANION_FAILURE\n' >> "$evidence"
      printf 'WATCHDOG_BLOCKED: job %s ended without a structured implementer result; inspect the companion/process/result evidence before a fresh dispatch.\n' \
        "${_MAESTRO_WRITE_TURN_JOB:-unknown}" >> "$evidence"
      rm -f "$profile" "${profile}.new"
      return 11
      ;;
  esac
}

write_turn_interrupt() { # HUP|INT|TERM result-file evidence-file
  local signal="${1-}" result="${2-}" evidence="${3-}" rc reason job
  case "$signal" in
    HUP) reason="signal-hup" ;;
    INT) reason="signal-int" ;;
    TERM) reason="signal-term" ;;
    *) return 4 ;;
  esac
  process_interrupt "$signal" "$evidence" || :
  _MAESTRO_WRITE_TURN_RESULT=$result
  _MAESTRO_WRITE_TURN_EVIDENCE=$evidence
  [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] || return 4
  case "$_MAESTRO_WRITE_TURN_ACTIVE" in
    live)
      companion_interrupt "$signal" "${_MAESTRO_WRITE_TURN_JOB-}" \
        "$evidence" write_turn_lifecycle
      rc=$?
      ;;
    inactive)
      job=${_MAESTRO_WRITE_TURN_JOB:-}
      if [ -z "$job" ]; then
        rc=4
      else
        if write_turn_lifecycle cancel-begin "$job" "$reason" "$evidence"; then
          write_turn_lifecycle cancel-end "$job" "$reason" "$evidence" || :
        fi
        printf 'CANCELLATION_FACT: job=%s reason=%s request=not-attempted source=signal-handler\n' \
          "$job" "$reason" >> "$evidence" 2>/dev/null || :
        progress "MAESTRO_CANCEL: job=$job reason=$reason request=not-attempted source=signal-handler"
        rc=125
      fi
      ;;
    *)
      rc=125
      ;;
  esac
  [ -z "${_MAESTRO_WRITE_TURN_PROMPT-}" ] ||
    rm -f "$_MAESTRO_WRITE_TURN_PROMPT" 2>/dev/null || :
  if [ -n "${_MAESTRO_WRITE_TURN_PROFILE-}" ]; then
    rm -f "$_MAESTRO_WRITE_TURN_PROFILE" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.new" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.job" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.transport.out" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.transport.err" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.cancel" \
      "${_MAESTRO_WRITE_TURN_PROFILE}.cancel.new" 2>/dev/null || :
  fi
  if [ "$rc" -eq 125 ]; then
    printf 'RESULT: BLOCKED\n' > "$result" 2>/dev/null || :
    return 125
  fi
  return 4
}
