#!/usr/bin/env bash
# Maestro single-shot Write-turn adapter.
set -uo pipefail
umask 077

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-write-turn.sh
. "$HERE/lib-write-turn.sh"
progress_init

FINAL_STATE=INTERRUPTED
FINAL_RC=4
WORK=""
PLAN_FILE=""
RESULT_FILE=""
EVIDENCE_FILE=""

maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}

maestro_interrupt() {
  local signal="$1" rc
  trap : HUP INT TERM
  write_turn_interrupt "$signal" "${RESULT_FILE:-/dev/null}" \
    "${EVIDENCE_FILE:-/dev/null}"
  rc=$?
  [ ! -s "${RESULT_FILE:-/dev/null}" ] ||
    cat "$RESULT_FILE"
  [ ! -s "${EVIDENCE_FILE:-/dev/null}" ] ||
    cat "$EVIDENCE_FILE" >&2
  [ "$rc" -eq 125 ] && maestro_finish POISONED 125
  maestro_finish INTERRUPTED 4
}

cleanup() {
  trap - EXIT HUP INT TERM
  write_lease_end "${EVIDENCE_FILE:-/dev/null}" || :
  [ -z "$WORK" ] || rm -rf "$WORK" 2>/dev/null || :
  progress "MAESTRO_FINAL: WATCHDOG $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap 'maestro_interrupt HUP' HUP
trap 'maestro_interrupt INT' INT
trap 'maestro_interrupt TERM' TERM

WORK=$(mktemp -d "${TMPDIR:-/tmp}/maestro-write-turn.XXXXXX") ||
  maestro_finish FAILED 3
RESULT_FILE="$WORK/result"
EVIDENCE_FILE="$WORK/evidence"
: > "$RESULT_FILE"
: > "$EVIDENCE_FILE"

if [ "${1:-}" = "--file" ]; then
  [ $# -ge 2 ] ||
    { echo "WATCHDOG_ERROR: plan file required after --file" >&2; maestro_finish FAILED 3; }
  PLAN_FILE="$2"
  [ -f "$PLAN_FILE" ] ||
    { echo "WATCHDOG_ERROR: plan file not found: $PLAN_FILE" >&2; maestro_finish FAILED 3; }
  shift 2
else
  [ $# -ge 1 ] ||
    { echo "WATCHDOG_ERROR: plan required" >&2; maestro_finish FAILED 3; }
  PLAN_FILE="$WORK/plan"
  printf '%s\n' "$1" > "$PLAN_FILE" || maestro_finish FAILED 3
  shift
fi
MAX_IDLE="${1:-300}"
POLL="${2:-20}"
if ! _write_turn_positive_integer "$MAX_IDLE" ||
  ! _write_turn_positive_integer "$POLL"; then
  echo "WATCHDOG_ERROR: max_idle_sec and poll_sec must be positive integers" >&2
  maestro_finish FAILED 3
fi
MAX_IDLE=$((10#$MAX_IDLE))
POLL=$((10#$POLL))

write_lease_begin "$EVIDENCE_FILE"
rc=$?
if [ "$rc" -ne 0 ]; then
  [ ! -s "$EVIDENCE_FILE" ] || cat "$EVIDENCE_FILE" >&2
  [ "$rc" -eq 11 ] && maestro_finish BLOCKED 11
  maestro_finish FAILED "$rc"
fi

write_turn_run "$PLAN_FILE" "$MAX_IDLE" "$POLL" "$RESULT_FILE" "$EVIDENCE_FILE"
rc=$?
[ ! -s "$RESULT_FILE" ] || cat "$RESULT_FILE"
[ ! -s "$EVIDENCE_FILE" ] || cat "$EVIDENCE_FILE" >&2

if [ "$rc" -ne 125 ] && [ -s "$RESULT_FILE" ]; then
  case "$rc" in
    0) STATE=DONE ;;
    10) STATE=NEEDS_ANSWERS ;;
    11) STATE=BLOCKED ;;
    4)
      if grep -q '^IMPLEMENTER_STATE: MISSING ' "$EVIDENCE_FILE"; then
        echo "IMPLEMENTER_STATE: MISSING (no RESULT line — treat as FAILED and re-dispatch with the output)" >&2
        maestro_finish MISSING 4
      fi
      STATE=FAILED
      ;;
    *) STATE="" ;;
  esac
  [ -z "$STATE" ] || echo "IMPLEMENTER_STATE: $STATE" >&2
fi

case "$rc" in
  0) maestro_finish DONE 0 ;;
  10) maestro_finish NEEDS_ANSWERS 10 ;;
  11) maestro_finish BLOCKED 11 ;;
  125) maestro_finish POISONED 125 ;;
  3) maestro_finish FAILED 3 ;;
  *) maestro_finish FAILED 4 ;;
esac
