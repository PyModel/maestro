#!/usr/bin/env bash
# Maestro Codex model + effort selector.
# Pins which Codex model the implementer/discussion loops use, and its reasoning
# effort, by writing `model` and `model_reasoning_effort` into the TOP LEVEL of
# ~/.codex/config.toml (keys under [tables] are never touched). Codex reads this
# config by default, so both loops pick it up on their next dispatch.
#
# Usage:
#   codex-model-select.sh --show                     current model + effort
#   codex-model-select.sh --pin                      machine-readable model + effort
#   codex-model-select.sh <model> <effort>           pin both (backs up config first)
#   codex-model-select.sh --ask-on-start on|off|status
#                                                    toggle the session-start setup
#                                                    prompt (~/.maestro/ask-on-start)
#
# Effort: none | minimal | low | medium | high | xhigh
#   none = disable reasoning effort · low = quick mechanical fixes
#   medium = default implementation · high = architecture debates, delicate
#   refactors, final-review judgment · xhigh = maximum tier for those tasks
# Model availability depends on the ChatGPT plan (e.g. gpt-5.6-sol). Model names
# are validated for shape only — Codex itself will reject a model it cannot reach.
#
# Exit codes: 0 = ok | 3 = bad args / invalid values
set -uo pipefail

CODEX_CONF="$HOME/.codex/config.toml"
MAESTRO_DIR="$HOME/.maestro"
ASK_FLAG="$MAESTRO_DIR/ask-on-start"

read_pin() {
  local MODEL_VALUE="" EFFORT_VALUE=""
  if [ -f "$CODEX_CONF" ]; then
    MODEL_VALUE=$(awk -F'"' '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{print $2}' "$CODEX_CONF" | tail -1)
    EFFORT_VALUE=$(awk -F'"' '/^\[/{exit} /^[[:space:]]*model_reasoning_effort[[:space:]]*=/{print $2}' "$CODEX_CONF" | tail -1)
  fi
  printf -v "$1" '%s' "$MODEL_VALUE"
  printf -v "$2" '%s' "$EFFORT_VALUE"
}

show() {
  local M E
  read_pin M E
  echo "model=${M:-(not pinned — Codex default)}"
  echo "effort=${E:-(not pinned — Codex default)}"
  if [ -f "$ASK_FLAG" ]; then echo "ask-on-start=on"; else echo "ask-on-start=off"; fi
}

pin() {
  local M E
  read_pin M E
  if [ -z "$M" ] || [ -z "$E" ]; then
    echo "SELECT_ERROR: Codex model and effort must both be pinned in the config.toml preamble" >&2
    return 3
  fi
  printf '%s\t%s\n' "$M" "$E"
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
    echo "usage: codex-model-select.sh --show | --pin | <model> <effort> | --ask-on-start on|off|status" >&2
    exit 3 ;;
esac

MODEL="${1:-}"
EFFORT="${2:-}"

if ! [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "SELECT_ERROR: invalid model name '$MODEL' (expected e.g. gpt-5.6-sol — letters, digits, . _ -)" >&2
  exit 3
fi
case "$EFFORT" in
  none|minimal|low|medium|high|xhigh) ;;
  *) echo "SELECT_ERROR: invalid effort '$EFFORT' (expected: none | minimal | low | medium | high | xhigh)" >&2; exit 3 ;;
esac

mkdir -p "$HOME/.codex"
if [ -f "$CODEX_CONF" ] && [ ! -f "$CODEX_CONF.maestro.bak" ]; then
  cp "$CODEX_CONF" "$CODEX_CONF.maestro.bak"
  echo "SELECT: backed up config.toml → config.toml.maestro.bak"
fi
[ -f "$CODEX_CONF" ] || : > "$CODEX_CONF"

set_kv model "$MODEL"
set_kv model_reasoning_effort "$EFFORT"
echo "SELECT: Codex implementer pinned → model=$MODEL effort=$EFFORT (applies from the next dispatch)"
