#!/usr/bin/env bash
# Maestro autonomous implementation loop.
# Owns the bounded retry policy around the shared Write turn module: dispatch the
# plan → parse RESULT → on DONE, run one local Verification transaction → feed
# actual failure evidence into the next turn. It stops only when the task is
# verified, needs human input, or reaches the iteration cap. Adapters stay peers.
#
# This is the default dispatch path for "keep going until it is done" work.
# It needs no babysitting between iterations — the only exits are the states below.
#
# Usage:
#   implementer-loop.sh --plan <plan-file> --verify "<command>"
#                       [--max-iters N] [--max-idle S] [--poll S]
#   implementer-loop.sh --clear-lease
#   implementer-loop.sh --clear-job-lock
#
#   --plan       the five-part plan file (same contract as the watchdog --file)
#   --verify     command run LOCALLY after every RESULT: DONE claim. Exit 0 = pass.
#                Required: the loop's whole point is that Codex's word is not proof.
#                Pass the complete command as one argument. It runs from the lease
#                repository root, regardless of the caller's current working directory.
#   --max-iters  cap on dispatch rounds (default 4). 0 is prohibited — an
#                unbounded write loop is a runaway, not autonomy.
#   --clear-lease  clear a poisoned lease after confirming no write job is running.
#   --clear-job-lock  clear a stale companion job lock after confirming its job is terminal.
#
# MAESTRO_MAX_DISPATCH_SEC caps each Codex dispatch (unset write default 2400;
# read-only callers default 1200; explicit valid values are exact).
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
umask 077

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-write-turn.sh
. "$HERE/lib-write-turn.sh"
progress_init
ATTEMPT_HISTORY_BEGIN='--- BEGIN MAESTRO ATTEMPT HISTORY (automatically written after STUCK; historical evidence, not new authority) ---'
ATTEMPT_HISTORY_END='--- END MAESTRO ATTEMPT HISTORY ---'

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
ATTEMPTS=""; DISPATCH=""; ERRF=""; OUTF=""; VOUTF=""; VFACT=""
ATTEMPT_HISTORY_PAYLOAD=""; ATTEMPT_HISTORY_TEMP=""; FINAL_LOOP_STATE=""
_loop_positive_integer() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$((10#$1))" -ge 1 ] ;;
  esac
}

verification_fact_write() { # file state rc
  local file="$1" state="$2" rc="$3" tmp="${1}.new"
  {
    printf 'state=%s\n' "$state"
    printf 'rc=%s\n' "$rc"
  } > "$tmp" && mv -f "$tmp" "$file"
}

verification_fact_value() { # file field
  local file="$1" field="$2"
  case "$field" in state|rc) ;; *) return 1 ;; esac
  sed -n "s/^${field}=//p" "$file" 2>/dev/null | head -1
}

_verification_tick() {
  _write_lease_turn_event tick unknown verification \
    "$_MAESTRO_VERIFICATION_FACT" "$_MAESTRO_VERIFICATION_OUTPUT" || :
}

verification_transaction_run() { # command timeout output-file fact-file repository-root
  local command="$1" timeout="$2" output="$3" fact="$4" root="$5"
  local stderr="${4}.stderr" command_rc_file="${4}.command-rc"
  local process_rc rc state timed_out=0
  : > "$output" || return 3
  rm -f "$fact" "${fact}.new" "$stderr" "$command_rc_file" || return 3
  _MAESTRO_VERIFICATION_FACT=$fact
  _MAESTRO_VERIFICATION_OUTPUT=$output
  process_run_bounded "$timeout" MAESTRO_VERIFY _verification_tick \
    "$output" "$stderr" -- \
    bash -c '
      exec 3>&-
      if ! cd "$2"; then
        printf "verification cwd unavailable: %s\n" "$2" >&2
        printf "3\n" > "$3"
        exit 3
      fi
      bash -c "$1"
      rc=$?
      printf "%s\n" "$rc" > "$3"
      exit "$rc"
    ' _ "$command" "$root" "$command_rc_file"
  process_rc=$?
  if [ "$process_rc" -eq 125 ] && [ ! -f "$command_rc_file" ]; then
    timed_out=1
  fi
  [ ! -s "$stderr" ] || cat "$stderr" >> "$output"
  if [ -f "$command_rc_file" ]; then
    rc=$(sed -n '1p' "$command_rc_file")
  else
    rc=$process_rc
  fi
  rm -f "$stderr" "$command_rc_file"
  if ! _write_lease_turn_event guard unknown verification "$fact" "$output"; then
    verification_fact_write "$fact" lease-lost 11 ||
      progress "LOOP_WARNING: could not write verification fact $fact; using in-process state=lease-lost rc=11."
    return 11
  fi
  if [ "$timed_out" -eq 1 ]; then
    verification_fact_write "$fact" timed-out 124 ||
      progress "LOOP_WARNING: could not write verification fact $fact; using in-process state=timed-out rc=124."
    return 124
  fi
  state=failed
  [ "$rc" -ne 0 ] || state=passed
  verification_fact_write "$fact" "$state" "$rc" ||
    progress "LOOP_WARNING: could not write verification fact $fact; using in-process state=$state rc=$rc."
  return "$rc"
}
attempt_history_bound() { # file
  local file="$1" max_lines=120 max_bytes=65536
  local line_tail="${1}.lines" byte_tail="${1}.bytes" bounded="${1}.bounded"
  local bytes marker marker_bytes keep wrapper_bytes payload_max
  marker='MAESTRO_ATTEMPT_HISTORY_TRUNCATED: earlier bytes omitted; retained the most recent evidence within the 65536-byte limit'
  wrapper_bytes=$(printf '\n\n%s\n\n%s\n' \
    "$ATTEMPT_HISTORY_BEGIN" "$ATTEMPT_HISTORY_END" | wc -c | tr -d ' ')
  payload_max=$((max_bytes - wrapper_bytes - (2 * (max_lines + 1))))
  if ! tail -n "$max_lines" "$file" > "$line_tail"; then
    rm -f "$line_tail" "$byte_tail" "$bounded"
    return 1
  fi
  bytes=$(wc -c < "$line_tail" | tr -d ' ')
  if [ "$bytes" -le "$payload_max" ]; then
    mv -f "$line_tail" "$file"
    return $?
  fi
  marker_bytes=$(printf '%s\n' "$marker" | wc -c | tr -d ' ')
  keep=$((payload_max - marker_bytes))
  if ! tail -c "$keep" "$line_tail" > "$byte_tail" ||
    ! { printf '%s\n' "$marker"; cat "$byte_tail"; } > "$bounded" ||
    ! mv -f "$bounded" "$file"; then
    rm -f "$line_tail" "$byte_tail" "$bounded"
    return 1
  fi
  rm -f "$line_tail" "$byte_tail"
}

attempt_history_resolve_plan() { # plan
  local path="$1" link hops=0 dir
  case "$path" in
    /*) ;;
    *) path="$(pwd -P)/$path" ;;
  esac
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    link=$(readlink "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="${path%/*}/$link" ;;
    esac
  done
  dir=$(cd "${path%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "${path##*/}"
}

attempt_history_persist() { # plan attempts
  local target dir
  target=$(attempt_history_resolve_plan "$1") || return 1
  dir=${target%/*}
  ATTEMPT_HISTORY_PAYLOAD=$(mktemp /tmp/maestro-attempt-history.XXXXXXXX) ||
    return 1
  ATTEMPT_HISTORY_TEMP=$(mktemp "$dir/.maestro-history.XXXXXXXX") || {
    rm -f "$ATTEMPT_HISTORY_PAYLOAD"
    ATTEMPT_HISTORY_PAYLOAD=""
    return 1
  }
  if ! sed 's/^/> /' "$2" > "$ATTEMPT_HISTORY_PAYLOAD" ||
    ! cp -p "$target" "$ATTEMPT_HISTORY_TEMP" ||
    ! {
      printf '\n\n%s\n' "$ATTEMPT_HISTORY_BEGIN" &&
        cat "$ATTEMPT_HISTORY_PAYLOAD" &&
        printf '%s\n' "$ATTEMPT_HISTORY_END"
    } >> "$ATTEMPT_HISTORY_TEMP" ||
    ! mv -f "$ATTEMPT_HISTORY_TEMP" "$target"; then
    rm -f "$ATTEMPT_HISTORY_PAYLOAD" "$ATTEMPT_HISTORY_TEMP"
    ATTEMPT_HISTORY_PAYLOAD=""
    ATTEMPT_HISTORY_TEMP=""
    return 1
  fi
  rm -f "$ATTEMPT_HISTORY_PAYLOAD"
  ATTEMPT_HISTORY_PAYLOAD=""
  ATTEMPT_HISTORY_TEMP=""
}


maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}
maestro_interrupt() {
  local signal="$1" rc result evidence temp
  trap : HUP INT TERM
  if [ -z "$OUTF" ]; then
    temp=$(mktemp /tmp/maestro-loopout.XXXXXXXX) && OUTF=$temp
  fi
  if [ -z "$ERRF" ]; then
    temp=$(mktemp /tmp/maestro-looperr.XXXXXXXX) && ERRF=$temp
  fi
  result=${OUTF:-/dev/null}
  evidence=${ERRF:-/dev/stderr}
  write_turn_interrupt "$signal" "$result" "$evidence"
  rc=$?
  if [ "$rc" -eq 125 ]; then
    FINAL_LOOP_STATE="LOOP_STATE: BLOCKED — interrupted before writer quiescence could be confirmed; lease retained"
    maestro_finish BLOCKED 11
  fi
  maestro_finish INTERRUPTED 4
}
cleanup() {
  local release_rc=0
  trap - EXIT HUP INT TERM
  write_lease_end "${ERRF:-/dev/null}"
  release_rc=$?
  if [ "$release_rc" -ne 0 ]; then
    case "$FINAL_RC" in
      11|125) ;;
      *)
        FINAL_STATE=BLOCKED
        FINAL_RC=11
        progress "LOOP_RELEASE: completion downgraded to BLOCKED because the write lease could not be released safely"
        FINAL_LOOP_STATE="LOOP_STATE: BLOCKED — the write lease could not be released safely"
        ;;
    esac
  fi
  [ -n "$ATTEMPTS" ] && rm -f "$ATTEMPTS" "${ATTEMPTS}.lines" \
    "${ATTEMPTS}.bytes" "${ATTEMPTS}.bounded"
  [ -n "$ATTEMPT_HISTORY_PAYLOAD" ] &&
    rm -f "$ATTEMPT_HISTORY_PAYLOAD" "${ATTEMPT_HISTORY_PAYLOAD}.lines" \
      "${ATTEMPT_HISTORY_PAYLOAD}.bytes" "${ATTEMPT_HISTORY_PAYLOAD}.bounded"
  [ -n "$ATTEMPT_HISTORY_TEMP" ] && rm -f "$ATTEMPT_HISTORY_TEMP"
  [ -n "$DISPATCH" ] && rm -f "$DISPATCH"
  [ -n "$ERRF" ] && rm -f "$ERRF"
  [ -n "$OUTF" ] && rm -f "$OUTF"
  [ -n "$VOUTF" ] && rm -f "$VOUTF"
  [ -n "$VFACT" ] && rm -f "$VFACT" "${VFACT}.new" \
    "${VFACT}.stderr" "${VFACT}.command-rc"
  [ -z "$FINAL_LOOP_STATE" ] || progress "$FINAL_LOOP_STATE"
  progress "MAESTRO_FINAL: LOOP $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap 'maestro_interrupt HUP' HUP
trap 'maestro_interrupt INT' INT
trap 'maestro_interrupt TERM' TERM

PLAN=""; VERIFY=""; MAX_ITERS=4; MAX_IDLE=300; POLL=20
CLEAR_LEASE=0; CLEAR_JOB_LOCK=0; EXECUTION_OPTIONS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --plan needs a file" >&2; maestro_finish "FAILED" 3; }
      PLAN="$2"; EXECUTION_OPTIONS=1; shift 2 ;;
    --verify)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --verify needs a command" >&2; maestro_finish "FAILED" 3; }
      VERIFY="$2"; EXECUTION_OPTIONS=1; shift 2 ;;
    --max-iters)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --max-iters needs a number" >&2; maestro_finish "FAILED" 3; }
      MAX_ITERS="$2"; EXECUTION_OPTIONS=1; shift 2 ;;
    --max-idle)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --max-idle needs seconds" >&2; maestro_finish "FAILED" 3; }
      MAX_IDLE="$2"; EXECUTION_OPTIONS=1; shift 2 ;;
    --poll)
      [ $# -ge 2 ] || { echo "LOOP_ERROR: --poll needs seconds" >&2; maestro_finish "FAILED" 3; }
      POLL="$2"; EXECUTION_OPTIONS=1; shift 2 ;;
    --clear-lease)
      CLEAR_LEASE=1; shift ;;
    --clear-job-lock)
      CLEAR_JOB_LOCK=1; shift ;;
    *) echo "LOOP_ERROR: unknown argument: $1" >&2; maestro_finish "FAILED" 3 ;;
  esac
done

if [ "$CLEAR_LEASE" -eq 1 ] && [ "$CLEAR_JOB_LOCK" -eq 1 ]; then
  echo "LOOP_ERROR: --clear-lease and --clear-job-lock are mutually exclusive" >&2
  maestro_finish "FAILED" 3
fi
if { [ "$CLEAR_LEASE" -eq 1 ] || [ "$CLEAR_JOB_LOCK" -eq 1 ]; } &&
  [ "$EXECUTION_OPTIONS" -eq 1 ]; then
  echo "LOOP_ERROR: recovery options are mutually exclusive with execution options" >&2
  maestro_finish "FAILED" 3
fi
if [ "$CLEAR_LEASE" -eq 0 ] && [ "$CLEAR_JOB_LOCK" -eq 0 ]; then
  case "$MAX_ITERS" in ''|*[!0-9]*)
    echo "LOOP_ERROR: --max-iters must be a positive integer" >&2
    maestro_finish "FAILED" 3 ;;
  esac
  if [ "$((10#$MAX_ITERS))" -lt 1 ]; then
    echo "LOOP_ERROR: --max-iters must be >= 1 (0 is prohibited)" >&2
    maestro_finish "FAILED" 3
  fi
  if ! _loop_positive_integer "$MAX_IDLE" ||
    ! _loop_positive_integer "$POLL"; then
    echo "LOOP_ERROR: --max-idle and --poll must be positive integers" >&2
    maestro_finish "FAILED" 3
  fi
  MAX_ITERS=$((10#$MAX_ITERS))
  MAX_IDLE=$((10#$MAX_IDLE))
  POLL=$((10#$POLL))
fi

if [ "$CLEAR_JOB_LOCK" -eq 1 ]; then
  CLEAR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/maestro-clear-job-lock.XXXXXX") ||
    maestro_finish "FAILED" 3
  CLEAR_RESULT="$CLEAR_WORK/result"
  CLEAR_EVIDENCE="$CLEAR_WORK/evidence"
  job_lock_clear "$CLEAR_RESULT" "$CLEAR_EVIDENCE"
  clear_rc=$?
  [ ! -s "$CLEAR_EVIDENCE" ] || cat "$CLEAR_EVIDENCE" >&2
  rm -rf "$CLEAR_WORK"
  case "$clear_rc" in
    0) maestro_finish "CLEARED" 0 ;;
    11) maestro_finish "BLOCKED" 11 ;;
    *) maestro_finish "FAILED" "$clear_rc" ;;
  esac
fi

if [ "$CLEAR_LEASE" -eq 1 ]; then
  CLEAR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/maestro-clear-lease.XXXXXX") ||
    maestro_finish "FAILED" 3
  CLEAR_RESULT="$CLEAR_WORK/result"
  CLEAR_EVIDENCE="$CLEAR_WORK/evidence"
  write_lease_clear "$CLEAR_RESULT" "$CLEAR_EVIDENCE"
  clear_rc=$?
  [ ! -s "$CLEAR_EVIDENCE" ] || cat "$CLEAR_EVIDENCE" >&2
  rm -rf "$CLEAR_WORK"
  case "$clear_rc" in
    0) maestro_finish "CLEARED" 0 ;;
    11) maestro_finish "BLOCKED" 11 ;;
    *) maestro_finish "FAILED" "$clear_rc" ;;
  esac
fi

[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "LOOP_ERROR: --plan <file> required and must exist" >&2; maestro_finish "FAILED" 3; }
[ -n "$VERIFY" ] || { echo "LOOP_ERROR: --verify \"<command>\" required — RESULT: DONE is a claim, not proof" >&2; maestro_finish "FAILED" 3; }

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

write_lease_begin "${ERRF:-/dev/null}"
lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  [ "$lock_rc" -eq 11 ] && maestro_finish "BLOCKED" 11
  maestro_finish "FAILED" "$lock_rc"
fi
VERIFY_ROOT=$(write_lock_scope_root 2>/dev/null) ||
  VERIFY_ROOT=$(pwd -P) ||
  maestro_finish "FAILED" 3

ATTEMPTS=$(mktemp /tmp/maestro-attempts.XXXXXXXX)
ERRF=$(mktemp /tmp/maestro-looperr.XXXXXXXX)
OUTF=$(mktemp /tmp/maestro-loopout.XXXXXXXX)
VOUTF=$(mktemp /tmp/maestro-verify.XXXXXXXX)
VFACT=$(mktemp /tmp/maestro-verify-fact.XXXXXXXX)

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
  : > "$OUTF"
  write_turn_run "$DISPATCH" "$MAX_IDLE" "$POLL" "$OUTF" "$ERRF"
  rc=$?
  OUT=$(cat "$OUTF")
  cat "$ERRF" >&2
  rm -f "$DISPATCH"; DISPATCH=""

  if [ "$rc" -eq 3 ]; then
    echo "LOOP_ERROR: dispatch could not start (see above)." >&2
    maestro_finish "FAILED" 3
  fi

  if [ "$rc" -eq 125 ]; then
    printf '%s\n' "$OUT"
    FINAL_LOOP_STATE="LOOP_STATE: BLOCKED after $i iteration(s) — write lease retained because turn quiescence was never confirmed; clear it with --clear-lease once no Codex job is writing."
    maestro_finish "BLOCKED" 11
  fi

  case "$rc" in
    0) STATE=DONE ;;
    10) STATE=NEEDS_ANSWERS ;;
    11) STATE=BLOCKED ;;
    4) STATE=FAILED ;;
    *) STATE="" ;;
  esac

  if [ -z "$STATE" ]; then
    kind="failed"; [ "$rc" -eq 124 ] && kind="hung"
    printf '\n## Attempt %s — job %s before producing a result\n%s\n' "$i" "$kind" \
      "$(tail -n 40 "$ERRF")" >> "$ATTEMPTS"
    attempt_history_bound "$ATTEMPTS" || maestro_finish "FAILED" 3
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
      FINAL_LOOP_STATE="LOOP_STATE: NEEDS_ANSWERS after $i iteration(s) — $persistence_note; relay the QUESTIONS verbatim to the user, answer the questions, and re-run this loop."
      maestro_finish "NEEDS_ANSWERS" 10 ;;
    BLOCKED)
      printf '%s\n' "$OUT"
      if grep -q '^IMPLEMENTER_STATE: COMPANION_FAILURE$' "$ERRF" 2>/dev/null; then
        FINAL_LOOP_STATE="LOOP_STATE: BLOCKED after $i iteration(s) — post-launch companion/process/result failure; inspect the evidence and current diff before a fresh dispatch. This did not consume another implementation attempt."
      else
        FINAL_LOOP_STATE="LOOP_STATE: BLOCKED after $i iteration(s) — surface the blocker; never improvise around credentials or destructive steps."
      fi
      maestro_finish "BLOCKED" 11 ;;
    DONE)
      progress "LOOP: RESULT: DONE on iteration $i — verifying locally: $VERIFY"
      verification_transaction_run "$VERIFY" "$VERIFY_TIMEOUT" "$VOUTF" "$VFACT" "$VERIFY_ROOT"
      vrc=$?
      vstate=$(verification_fact_value "$VFACT" state)
      if [ -z "$vstate" ]; then
        case "$vrc" in
          0) vstate=passed ;;
          11) vstate=lease-lost ;;
          124) vstate=timed-out ;;
          *) vstate=failed ;;
        esac
      fi
      if [ "$vstate" = lease-lost ]; then
        FINAL_LOOP_STATE="LOOP_STATE: BLOCKED — this loop no longer holds the write lease; stopping before re-dispatching"
        maestro_finish "BLOCKED" 11
      fi
      VOUT=$(cat "$VOUTF")
      if [ "$vstate" = passed ]; then
        printf '%s\n' "$OUT"
        FINAL_LOOP_STATE="LOOP_STATE: VERIFIED_DONE after $i iteration(s) — local verification passed."
        maestro_finish "VERIFIED_DONE" 0
      fi
      if [ "$vstate" = timed-out ]; then
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
    FAILED)
      {
        printf '\n## Attempt %s — RESULT: FAILED\n' "$i"
        [ -z "$OUT" ] || printf '%s\n' "$OUT" | tail -n 80
        [ ! -s "$ERRF" ] || tail -n 40 "$ERRF"
      } >> "$ATTEMPTS"
      progress "LOOP: iteration $i RESULT: FAILED — re-dispatching with the evidence"
      ;;
  esac
  attempt_history_bound "$ATTEMPTS" || maestro_finish "FAILED" 3
done

attempt_history_note="attempt history could not be appended to $PLAN"
if [ -w "$PLAN" ] && attempt_history_persist "$PLAN" "$ATTEMPTS"; then
  attempt_history_note="bounded attempt history has been appended to $PLAN"
else
  progress "LOOP_WARNING: could not append attempt history to plan file $PLAN; continuing with exit 12."
fi
progress "LOOP_STUCK: $MAX_ITERS iteration(s) without verified completion. Attempts log:"
cat "$ATTEMPTS" >&2
FINAL_LOOP_STATE="LOOP_STATE: STUCK — $attempt_history_note; re-plan around the evidence above (a debugging discussion helps), or escalate to the user. Do not simply raise --max-iters."
maestro_finish "STUCK" 12
