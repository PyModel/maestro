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
#   implementer-loop.sh --clear-lease
#
#   --plan       the five-part plan file (same contract as the watchdog --file)
#   --verify     command run LOCALLY after every RESULT: DONE claim. Exit 0 = pass.
#                Required: the loop's whole point is that Codex's word is not proof.
#   --max-iters  cap on dispatch rounds (default 4). 0 is prohibited — an
#                unbounded write loop is a runaway, not autonomy.
#   --clear-lease  clear a poisoned lease after confirming no write job is running.
#
# MAESTRO_MAX_DISPATCH_SEC caps each Codex dispatch (default 1200).
# Cancellation occurs within one --poll interval after that deadline.
# MAESTRO_VERIFY_TIMEOUT_SEC caps each local verifier process group (default 900).
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
ATTEMPTS=""; DISPATCH=""; ERRF=""; VOUTF=""
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
  [ -n "$ATTEMPTS" ] && rm -f "$ATTEMPTS"
  [ -n "$DISPATCH" ] && rm -f "$DISPATCH"
  [ -n "$ERRF" ] && rm -f "$ERRF"
  [ -n "$VOUTF" ] && rm -f "$VOUTF"
  write_lock_release
  progress "MAESTRO_FINAL: LOOP $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap maestro_interrupt HUP INT TERM

PLAN=""; VERIFY=""; MAX_ITERS=4; MAX_IDLE=300; POLL=20; CLEAR_LEASE=0
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
    --clear-lease)
      CLEAR_LEASE=1; shift ;;
    *) echo "LOOP_ERROR: unknown argument: $1" >&2; maestro_finish "FAILED" 3 ;;
  esac
done

if [ "$CLEAR_LEASE" -eq 1 ]; then
  lock_path=$(write_lock_path) || {
    echo "LOOP_ERROR: could not resolve the write lock path" >&2
    maestro_finish "FAILED" 3
  }
  if [ ! -d "$lock_path" ]; then
    progress "MAESTRO_LOCK: there is no write lease to clear at $lock_path"
    maestro_finish "CLEARED" 0
  fi

  metadata="$lock_path/metadata"
  staged_metadata="$lock_path/metadata.new"
  heartbeat="$lock_path/heartbeat"
  orphan=0
  stale_heartbeat=0
  if [ ! -e "$metadata" ] && [ ! -e "$staged_metadata" ]; then
    orphan=1
    poisoned_job=unknown
    poisoned_reason=missing-metadata
    poisoned_session=unknown
  else
    poison_metadata="$metadata"
    quiescence=$(write_lock_metadata_value "$poison_metadata" quiescence)
    if [ "$quiescence" != "unconfirmed" ] &&
      [ -e "$staged_metadata" ]; then
      poison_metadata="$staged_metadata"
      quiescence=unconfirmed
    fi
    if [ "$quiescence" != "unconfirmed" ]; then
      owner_token=$(write_lock_metadata_value "$metadata" token)
      owner_job=$(write_lock_metadata_value "$metadata" job_id)
      owner_job=${owner_job:-unknown}
      owner_session=$(write_lock_metadata_value "$metadata" session_id)
      owner_session=$(MAESTRO_SESSION_ID="${owner_session:-}" write_lock_session_id)
      owner_pid=$(write_lock_metadata_value "$metadata" pid)
      started_epoch=$(write_lock_metadata_value "$metadata" started_epoch)
      malformed=0
      case "$owner_pid" in
        ''|*[!0-9]*) malformed=1 ;;
      esac
      if [ -z "$owner_token" ] || [ "$malformed" -eq 1 ]; then
        progress "MAESTRO_LOCK: refusing to clear — write lease metadata is malformed; owner cannot be identified; failing closed (lock: $lock_path)"
        maestro_finish "BLOCKED" 11
      fi
      heartbeat_stale=$(write_lock_heartbeat_stale_sec)
      heartbeat_note=""
      case "$started_epoch" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$heartbeat_stale" -ne 0 ]; then
            now=$(date +%s)
            heartbeat_effective=$started_epoch
            heartbeat_epoch=$(write_lock_heartbeat_epoch "$lock_path" "$owner_token")
            case "$heartbeat_epoch" in
              ''|*[!0-9]*) ;;
              *)
                [ "$heartbeat_epoch" -gt "$heartbeat_effective" ] &&
                  heartbeat_effective=$heartbeat_epoch
                ;;
            esac
            heartbeat_age=$((now - heartbeat_effective))
            [ "$heartbeat_age" -lt 0 ] && heartbeat_age=0
            if [ "$heartbeat_age" -gt "$heartbeat_stale" ]; then
              stale_heartbeat=1
            else
              heartbeat_note="; heartbeat ${heartbeat_age}s old"
            fi
          fi
          ;;
      esac
      if [ "$stale_heartbeat" -eq 0 ]; then
        progress "MAESTRO_LOCK: refusing to clear — write lease is healthy and not this command's to clear (job=$owner_job session=${owner_session:-unknown} pid=$owner_pid, lock: $lock_path)${heartbeat_note}"
        maestro_finish "BLOCKED" 11
      fi
      poisoned_job=$owner_job
      poisoned_session=$owner_session
    fi
    if [ "$stale_heartbeat" -eq 0 ]; then
      poisoned_job=$(write_lock_metadata_value "$poison_metadata" unconfirmed_job)
      poisoned_reason=$(write_lock_metadata_value "$poison_metadata" unconfirmed_reason)
      poisoned_session=$(write_lock_metadata_value "$poison_metadata" session_id)
      poisoned_session=$(MAESTRO_SESSION_ID="${poisoned_session:-}" write_lock_session_id)
    fi
  fi

  writers=$(write_lock_workspace_writers)
  writers_rc=$?
  running_job=""
  if [ "$writers_rc" -eq 0 ]; then
    running_job=$(printf '%s\n' "$writers" |
      awk '$2 == "true" { print $1; exit }')
  fi
  if [ "$writers_rc" -eq 4 ] || [ -n "$running_job" ]; then
    progress "MAESTRO_LOCK: refusing to clear — a write-capable job is still running (${running_job:-unknown}) session=${poisoned_session:-unknown}"
    maestro_finish "BLOCKED" 11
  fi

  if [ "$orphan" -eq 1 ]; then
    progress "MAESTRO_LOCK: clearing structurally invalid orphan write lease (lock: $lock_path, removing: every entry under $lock_path, then $lock_path)"
    if ! find "$lock_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null ||
      ! rmdir "$lock_path" 2>/dev/null; then
      progress "MAESTRO_LOCK: failed to clear structurally invalid orphan write lease at $lock_path"
      maestro_finish "BLOCKED" 11
    fi
  elif [ "$stale_heartbeat" -eq 1 ]; then
    progress "MAESTRO_LOCK: clearing a write lease whose heartbeat went stale (job=$owner_job session=${owner_session:-unknown} last_heartbeat=${heartbeat_age}s ago, lock: $lock_path)"
  elif [ -e "$staged_metadata" ]; then
    progress "MAESTRO_LOCK: clearing poisoned write lease (job=${poisoned_job:-unknown} session=${poisoned_session:-unknown} reason=${poisoned_reason:-unknown}, lock: $lock_path, removing: $staged_metadata)"
  else
    progress "MAESTRO_LOCK: clearing poisoned write lease (job=${poisoned_job:-unknown} session=${poisoned_session:-unknown} reason=${poisoned_reason:-unknown}, lock: $lock_path)"
  fi
  if [ "$orphan" -eq 0 ]; then
    if ! rm -f "$metadata" "$heartbeat" 2>/dev/null ||
      ! rm -rf "$staged_metadata" 2>/dev/null ||
      ! rmdir "$lock_path" 2>/dev/null; then
      if [ "$stale_heartbeat" -eq 1 ]; then
        progress "MAESTRO_LOCK: failed to clear stale-heartbeat write lease at $lock_path session=${owner_session:-unknown}"
      else
        progress "MAESTRO_LOCK: failed to clear poisoned write lease at $lock_path session=${poisoned_session:-unknown}"
      fi
      maestro_finish "BLOCKED" 11
    fi
  fi
  maestro_finish "CLEARED" 0
fi

[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "LOOP_ERROR: --plan <file> required and must exist" >&2; maestro_finish "FAILED" 3; }
[ -n "$VERIFY" ] || { echo "LOOP_ERROR: --verify \"<command>\" required — RESULT: DONE is a claim, not proof" >&2; maestro_finish "FAILED" 3; }
[ "$MAX_ITERS" -ge 1 ] 2>/dev/null || { echo "LOOP_ERROR: --max-iters must be >= 1 (0 is prohibited)" >&2; maestro_finish "FAILED" 3; }
[ -f "$WATCHDOG" ] || { echo "LOOP_ERROR: implementer-watchdog.sh not found next to this script" >&2; maestro_finish "FAILED" 3; }

VERIFY_TIMEOUT="${MAESTRO_VERIFY_TIMEOUT_SEC-900}"
verify_timeout_invalid=0
case "$VERIFY_TIMEOUT" in
  ''|*[!0-9]*) verify_timeout_invalid=1 ;;
  *) [ "$VERIFY_TIMEOUT" -ge 1 ] 2>/dev/null || verify_timeout_invalid=1 ;;
esac
if [ "$verify_timeout_invalid" -eq 1 ]; then
  progress "MAESTRO_VERIFY: ignoring invalid MAESTRO_VERIFY_TIMEOUT_SEC=$VERIFY_TIMEOUT; using 900s"
  VERIFY_TIMEOUT=900
fi

write_lock_acquire
lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  [ "$lock_rc" -eq 11 ] && maestro_finish "BLOCKED" 11
  maestro_finish "FAILED" "$lock_rc"
fi

ATTEMPTS=$(mktemp /tmp/maestro-attempts.XXXXXXXX)
ERRF=$(mktemp /tmp/maestro-looperr.XXXXXXXX)
VOUTF=$(mktemp /tmp/maestro-verify.XXXXXXXX)

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
  if ! write_lock_is_owner; then
    progress "LOOP_STATE: BLOCKED — this loop no longer holds the write lease; stopping before re-dispatching"
    maestro_finish "BLOCKED" 11
  fi
  OUT=$(bash "$WATCHDOG" --file "$DISPATCH" "$MAX_IDLE" "$POLL" 2>"$ERRF")
  rc=$?
  cat "$ERRF" >&2
  rm -f "$DISPATCH"; DISPATCH=""

  if [ "$rc" -eq 3 ]; then
    echo "LOOP_ERROR: dispatch could not start (see above)." >&2
    maestro_finish "FAILED" 3
  fi

  if [ "$rc" -eq 125 ]; then
    MAESTRO_LOCK_RETAIN=1
    printf '%s\n' "$OUT"
    progress "LOOP_STATE: BLOCKED after $i iteration(s) — write lease retained because turn quiescence was never confirmed; clear it with --clear-lease once no Codex job is writing."
    maestro_finish "BLOCKED" 11
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
      persistence_note="the stop report could not be appended to $PLAN"
      if [ -w "$PLAN" ] &&
        printf '\n\n--- BEGIN MAESTRO STOP HISTORY (automatically written after iteration %s) ---\n%s\n--- END MAESTRO STOP HISTORY (iteration %s) ---\n' \
          "$i" "$OUT" "$i" >> "$PLAN"; then
        persistence_note="the stop report has been appended to $PLAN"
      else
        progress "LOOP_WARNING: could not append the stop report to plan file $PLAN; continuing with exit 10."
      fi
      printf '%s\n' "$OUT"
      progress "LOOP_STATE: NEEDS_ANSWERS after $i iteration(s) — $persistence_note; relay the QUESTIONS verbatim to the user, answer the questions, and re-run this loop."
      maestro_finish "NEEDS_ANSWERS" 10 ;;
    BLOCKED)
      printf '%s\n' "$OUT"
      progress "LOOP_STATE: BLOCKED after $i iteration(s) — surface the blocker; never improvise around credentials or destructive steps."
      maestro_finish "BLOCKED" 11 ;;
    DONE)
      progress "LOOP: RESULT: DONE on iteration $i — verifying locally: $VERIFY"
      # Close FD 3 so verifier progress re-points to stdout and lands in VOUT instead of the operator channel.
      : > "$VOUTF"
      set -m
      env -u MAESTRO_LOCK_ACQUIRED -u MAESTRO_LOCK_TOKEN -u MAESTRO_LOCK_DIR \
        bash -c "$VERIFY" > "$VOUTF" 2>&1 3>&- &
      vpid=$!
      vstarted=$(date +%s)
      vtimed_out=0
      while kill -0 "$vpid" 2>/dev/null; do
        vtotal=$(( $(date +%s) - vstarted ))
        if [ "$vtotal" -ge "$VERIFY_TIMEOUT" ]; then
          vtimed_out=1
          break
        fi
        sleep 1
        write_lock_heartbeat_write
      done
      if [ "$vtimed_out" -eq 1 ]; then
        kill -TERM -"$vpid" 2>/dev/null || :
        vwait=0
        while kill -0 -"$vpid" 2>/dev/null && [ "$vwait" -lt 5 ]; do
          sleep 1
          vwait=$((vwait + 1))
        done
        kill -KILL -"$vpid" 2>/dev/null || :
      fi
      wait "$vpid" 2>/dev/null
      vrc=$?
      set +m
      if ! write_lock_is_owner; then
        progress "LOOP_STATE: BLOCKED — this loop no longer holds the write lease; stopping before re-dispatching"
        maestro_finish "BLOCKED" 11
      fi
      VOUT=$(cat "$VOUTF")
      if [ "$vtimed_out" -eq 1 ]; then
        vrc=124
      fi
      if [ "$vrc" -eq 0 ]; then
        printf '%s\n' "$OUT"
        progress "LOOP_STATE: VERIFIED_DONE after $i iteration(s) — local verification passed."
        maestro_finish "VERIFIED_DONE" 0
      fi
      if [ "$vtimed_out" -eq 1 ]; then
        printf '\n## Attempt %s — claimed DONE but LOCAL verification timed out after %ss (exit %s): %s\n%s\n' \
          "$i" "$VERIFY_TIMEOUT" "$vrc" "$VERIFY" \
          "$(printf '%s' "$VOUT" | tail -n 60)" >> "$ATTEMPTS"
        progress "LOOP: iteration $i claimed DONE but verification timed out after ${VERIFY_TIMEOUT}s — re-dispatching with the output"
      else
        printf '\n## Attempt %s — claimed DONE but LOCAL verification failed (exit %s): %s\n%s\n' \
          "$i" "$vrc" "$VERIFY" "$(printf '%s' "$VOUT" | tail -n 60)" >> "$ATTEMPTS"
        progress "LOOP: iteration $i claimed DONE but verification failed (exit $vrc) — re-dispatching with the output"
      fi
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
