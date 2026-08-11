#!/usr/bin/env bash
# Maestro single-shot read-only reconnaissance adapter.
set -uo pipefail
umask 077

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-companion.sh
. "$HERE/lib-companion.sh"
progress_init

FINAL_STATE="INTERRUPTED"
FINAL_RC=4
SCOUT_WORKDIR=""
SCOUT_PROFILE=""
SCOUT_EVIDENCE=""

maestro_finish() {
  FINAL_STATE="$1"
  FINAL_RC="$2"
  exit "$FINAL_RC"
}

scout_profile_value() { # field
  sed -n "s/^$1=//p" "$SCOUT_PROFILE" 2>/dev/null | head -1
}

scout_job_valid() {
  case "${1-}" in task-*) ;; *) return 1 ;; esac
  case "$1" in *[!a-zA-Z0-9-]*) return 1 ;; esac
}

maestro_interrupt() {
  local signal="$1" job=""
  trap : HUP INT TERM
  process_interrupt "$signal" "$SCOUT_EVIDENCE" || :
  [ ! -f "$SCOUT_PROFILE" ] || job=$(scout_profile_value job)
  scout_job_valid "$job" || job=""
  companion_interrupt "$signal" "$job" "$SCOUT_EVIDENCE" : || :
  maestro_finish "INTERRUPTED" 4
}

cleanup() {
  trap - EXIT HUP INT TERM
  [ -z "$SCOUT_WORKDIR" ] || rm -rf "$SCOUT_WORKDIR" 2>/dev/null || :
  progress "MAESTRO_FINAL: SCOUT $FINAL_STATE rc=$FINAL_RC"
  exit "$FINAL_RC"
}
trap cleanup EXIT
trap 'maestro_interrupt HUP' HUP
trap 'maestro_interrupt INT' INT
trap 'maestro_interrupt TERM' TERM

if [ "$#" -ne 2 ] || [ "$1" != --query ]; then
  echo "SCOUT_ERROR: usage: scout.sh --query <query-file>" >&2
  maestro_finish "FAILED" 3
fi
QUERY="$2"
if [ ! -f "$QUERY" ] || [ ! -r "$QUERY" ]; then
  echo "SCOUT_ERROR: query file is not readable: $QUERY" >&2
  maestro_finish "FAILED" 3
fi

SCOUT_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/maestro-scout.XXXXXX") || {
  echo "SCOUT_ERROR: could not create temporary workdir" >&2
  maestro_finish "FAILED" 3
}
PROMPT="$SCOUT_WORKDIR/prompt"
RESULT="$SCOUT_WORKDIR/result"
SCOUT_PROFILE="$SCOUT_WORKDIR/profile"
SCOUT_EVIDENCE="$SCOUT_WORKDIR/evidence"

PIN=$(bash "$HERE/codex-model-select.sh" --scout-pin) ||
  maestro_finish "BLOCKED" 11
SCOUT_MODEL=${PIN%%$'\t'*}
SCOUT_EFFORT=${PIN#*$'\t'}

if ! {
  cat "$QUERY"
  cat <<'EOF'


--- SCOUT CONTRACT ---
Perform read-only reconnaissance; never modify files.
Answer with concrete file:line evidence.
Use at most 2 MCP lookups, with no retry on stall. Do not use web search.
End with exactly one line: SCOUT_SUMMARY: <answer in one sentence>
EOF
} > "$PROMPT"; then
  echo "SCOUT_ERROR: could not prepare prompt" >&2
  maestro_finish "FAILED" 3
fi

export MAESTRO_COMPANION_MODEL="$SCOUT_MODEL"
export MAESTRO_COMPANION_EFFORT="$SCOUT_EFFORT"
companion_turn read "$PROMPT" 300 20 "$RESULT" "$SCOUT_PROFILE" \
  "$SCOUT_EVIDENCE" :
rc=$?
if [ "$rc" -eq 0 ]; then
  if ! cat "$RESULT"; then
    [ ! -s "$SCOUT_EVIDENCE" ] || cat "$SCOUT_EVIDENCE" >&2
    maestro_finish "FAILED" 4
  fi
  maestro_finish "DONE" 0
fi
if [ "$rc" -eq 11 ]; then
  maestro_finish "BLOCKED" 11
fi
[ ! -s "$SCOUT_EVIDENCE" ] || cat "$SCOUT_EVIDENCE" >&2
maestro_finish "FAILED" 4
