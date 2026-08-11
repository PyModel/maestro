#!/usr/bin/env bash
# Maestro bounded process module. Sourced, not executed.

[ "${_MAESTRO_PROCESS_LOADED-0}" = 1 ] && return 0
_MAESTRO_PROCESS_LOADED=1

# Interface:
#   process_run_bounded TIMEOUT LABEL TICK_FN STDOUT_FILE STDERR_FILE -- COMMAND [ARGS...]
#   process_interrupt SIGNAL EVIDENCE_FILE
# The module owns the spawned process group; callers own output and evidence files.

_MAESTRO_PROCESS_PID=""

progress_init() {
  if ! { true >&3; } 2>/dev/null; then exec 3>&1; fi
}

progress() { printf '%s\n' "$*" >&3; }

_process_group_stop() { # pid
  local pid="$1" grace=0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -"$pid" 2>/dev/null || :
  while kill -0 -"$pid" 2>/dev/null && [ "$grace" -lt 5 ]; do
    sleep 1
    grace=$((grace + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || :
  return 0
}

process_run_bounded() { # timeout label tick stdout stderr -- command [args...]
  local timeout="${1-}" label="${2-}" tick="${3-}"
  local stdout_file="${4-}" stderr_file="${5-}"
  local pid start elapsed timed_out=0 ticks=0 rc
  shift 5 2>/dev/null || return 3
  [ "${1-}" = "--" ] || return 3
  shift

  case "$timeout" in
    ''|*[!0-9]*) return 3 ;;
    *) [ "$timeout" -ge 1 ] 2>/dev/null || return 3 ;;
  esac
  if [ "$tick" != : ] && ! declare -F "$tick" >/dev/null 2>&1; then
    return 3
  fi
  [ -n "$stdout_file" ] && [ -n "$stderr_file" ] && [ "$stdout_file" != "$stderr_file" ] || return 3
  [ "$#" -gt 0 ] || return 3
  : > "$stdout_file" || return 3
  : > "$stderr_file" || return 3

  set -m
  (
    "$@" > "$stdout_file" 2> "$stderr_file"
  ) &
  pid=$!
  _MAESTRO_PROCESS_PID=$pid
  set +m

  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      timed_out=1
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
    if [ "$ticks" -ge 10 ]; then
      "$tick" || :
      ticks=0
    fi
  done

  if [ "$timed_out" -eq 1 ]; then
    _process_group_stop "$pid"
  fi
  wait "$pid" 2>/dev/null
  rc=$?

  # A successful leader may leave descendants in its process group. Do not
  # return while any process from this bounded call is still alive.
  if kill -0 -"$pid" 2>/dev/null; then
    _process_group_stop "$pid"
  fi
  _MAESTRO_PROCESS_PID=""

  if [ "$timed_out" -eq 1 ]; then
    progress "$label: timed out after ${timeout}s"
    return 125
  fi
  return "$rc"
}

process_interrupt() { # HUP|INT|TERM evidence-file
  local signal="${1-}" evidence="${2-}" pid="${_MAESTRO_PROCESS_PID-}"
  case "$signal" in HUP|INT|TERM) ;; *) return 3 ;; esac
  [ -n "$pid" ] || return 0
  _process_group_stop "$pid"
  wait "$pid" 2>/dev/null || :
  _MAESTRO_PROCESS_PID=""
  if [ -n "$evidence" ]; then
    printf 'MAESTRO_PROCESS: interrupted active process group with %s\n' "$signal" >> "$evidence" 2>/dev/null || :
  fi
  return 0
}
