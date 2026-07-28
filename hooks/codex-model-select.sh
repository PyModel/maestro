#!/usr/bin/env bash
# Maestro Codex model + debate/implementation effort selector.
# Pins the Codex model and debate effort by writing `model` and
# `model_reasoning_effort` into the TOP LEVEL of ~/.codex/config.toml (keys under
# [tables] are never touched). The implementation effort is stored separately in
# ~/.codex/maestro-impl-effort.
#
# Usage:
#   codex-model-select.sh --show                     current model + both efforts
#   codex-model-select.sh --pin                      machine-readable model + both efforts
#   codex-model-select.sh <model> <debate-effort> [impl-effort]
#                                                    pin settings (backs up config first)
#   codex-model-select.sh --ask-on-start on|off|status
#                                                    toggle the session-start setup
#                                                    prompt (~/.maestro/ask-on-start)
#
# Effort: none | minimal | low | medium | high | xhigh | max | ultra
#   none = disable reasoning effort · low = quick mechanical fixes
#   medium = default implementation · high/xhigh/max/ultra = progressively deeper
#   architecture debates, delicate refactors, and final-review judgment
# Model availability depends on the ChatGPT plan (e.g. gpt-5.6-sol). Model names
# are validated for shape only — Codex itself will reject a model it cannot reach.
#
# Exit codes: 0 = ok | 3 = bad args / invalid values
set -uo pipefail

CODEX_CONF="$HOME/.codex/config.toml"
IMPL_EFFORT_FILE="$HOME/.codex/maestro-impl-effort"
MAESTRO_DIR="$HOME/.maestro"
ASK_FLAG="$MAESTRO_DIR/ask-on-start"

valid_effort() {
  case "$1" in
    none|minimal|low|medium|high|xhigh|max|ultra) return 0 ;;
    *) return 1 ;;
  esac
}

read_pin() {
  local MODEL_VALUE="" EFFORT_VALUE=""
  if [ -f "$CODEX_CONF" ]; then
    MODEL_VALUE=$(awk -F'"' '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{print $2}' "$CODEX_CONF" | tail -1)
    EFFORT_VALUE=$(awk -F'"' '/^\[/{exit} /^[[:space:]]*model_reasoning_effort[[:space:]]*=/{print $2}' "$CODEX_CONF" | tail -1)
  fi
  printf -v "$1" '%s' "$MODEL_VALUE"
  printf -v "$2" '%s' "$EFFORT_VALUE"
}

read_impl_effort() {
  local VALUE=""
  if [ -f "$IMPL_EFFORT_FILE" ]; then
    IFS= read -r VALUE < "$IMPL_EFFORT_FILE" || :
  fi
  printf -v "$1" '%s' "${VALUE:-medium}"
}

show() {
  local M E I
  read_pin M E
  read_impl_effort I
  echo "model=${M:-(not pinned — Codex default)}"
  if [ -n "$E" ] && ! valid_effort "$E"; then
    echo "effort=$E (invalid)"
  else
    echo "effort=${E:-(not pinned — Codex default)}"
  fi
  echo "impl-effort=$I"
  if [ -f "$ASK_FLAG" ]; then echo "ask-on-start=on"; else echo "ask-on-start=off"; fi
}

pin() {
  local M E I
  read_pin M E
  read_impl_effort I
  if [ -z "$M" ] || [ -z "$E" ]; then
    echo "SELECT_ERROR: Codex model and effort must both be pinned in the config.toml preamble" >&2
    return 3
  fi
  if ! valid_effort "$E"; then
    echo "SELECT_ERROR: invalid debate effort '$E' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
    return 3
  fi
  if ! valid_effort "$I"; then
    echo "SELECT_ERROR: invalid implementation effort '$I' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
    return 3
  fi
  printf '%s\t%s\t%s\n' "$M" "$E" "$I"
}

# set_kv <key> <value> — replace or insert top-level `key = "value"` in the TOML
# preamble (everything before the first [table]); keys inside tables are untouched.
set_kv() {
  local KEY="$1" VAL="$2" TMP="$CODEX_CONF.mtmp.$$"
  awk -v k="$KEY" -v v="$VAL" '
    BEGIN { inserted=0; intable=0 }
    /^\[/ && !intable {
      if (!inserted) { print k " = \"" v "\""; inserted=1 }
      intable=1
    }
    !intable && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      if (!inserted) { print k " = \"" v "\""; inserted=1 }
      next
    }
    { print }
    END { if (!inserted) print k " = \"" v "\"" }
  ' "$CODEX_CONF" > "$TMP" && mv "$TMP" "$CODEX_CONF"
}

case "${1:-}" in
  --show)
    show
    exit 0 ;;
  --pin)
    pin
    exit $? ;;
  --ask-on-start)
    case "${2:-}" in
      on)  mkdir -p "$MAESTRO_DIR"; : > "$ASK_FLAG"; echo "ask-on-start=on — the setup prompt fires at each new session" ;;
      off) rm -f "$ASK_FLAG"; echo "ask-on-start=off — session start shows a status line only" ;;
      status) [ -f "$ASK_FLAG" ] && echo "ask-on-start=on" || echo "ask-on-start=off" ;;
      *) echo "usage: codex-model-select.sh --ask-on-start on|off|status" >&2; exit 3 ;;
    esac
    exit 0 ;;
  ""|--help|-h)
    echo "usage: codex-model-select.sh --show | --pin | <model> <debate-effort> [impl-effort] | --ask-on-start on|off|status" >&2
    exit 3 ;;
esac

MODEL="${1:-}"
EFFORT="${2:-}"
if [ $# -ge 3 ]; then
  IMPL_EFFORT="$3"
else
  read_impl_effort IMPL_EFFORT
fi

if ! [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "SELECT_ERROR: invalid model name '$MODEL' (expected e.g. gpt-5.6-sol — letters, digits, . _ -)" >&2
  exit 3
fi
if ! valid_effort "$EFFORT"; then
  echo "SELECT_ERROR: invalid effort '$EFFORT' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
  exit 3
fi
if ! valid_effort "$IMPL_EFFORT"; then
  echo "SELECT_ERROR: invalid implementation effort '$IMPL_EFFORT' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
  exit 3
fi

mkdir -p "$HOME/.codex"
if [ -f "$CODEX_CONF" ] && [ ! -f "$CODEX_CONF.maestro.bak" ]; then
  cp "$CODEX_CONF" "$CODEX_CONF.maestro.bak"
  echo "SELECT: backed up config.toml → config.toml.maestro.bak"
fi
[ -f "$CODEX_CONF" ] || : > "$CODEX_CONF"

set_kv model "$MODEL"
set_kv model_reasoning_effort "$EFFORT"
if [ $# -ge 3 ] || [ ! -s "$IMPL_EFFORT_FILE" ]; then
  printf '%s\n' "$IMPL_EFFORT" > "$IMPL_EFFORT_FILE"
fi
echo "SELECT: Codex pin updated → model=$MODEL debate-effort=$EFFORT impl-effort=$IMPL_EFFORT (applies from the next dispatch)"
