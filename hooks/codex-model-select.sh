#!/usr/bin/env bash
# Maestro Codex model + debate/implementation effort selector.
# Pins top-level model settings in ~/.codex/config.toml and keeps the
# implementation effort in ~/.codex/maestro-impl-effort and the scout pin in
# ~/.codex/maestro-scout.
#
# Usage:
#   codex-model-select.sh --show
#   codex-model-select.sh --pin
#   codex-model-select.sh --scout <model> <effort>
#   codex-model-select.sh --scout-pin
#   codex-model-select.sh <model> <debate-effort> [impl-effort]
#   codex-model-select.sh --ask-on-start on|off|status
#
# Debate effort: none | minimal | low | medium | high | xhigh | max | ultra
# Implementation effort: none | minimal | low | medium | high | xhigh
# Exit codes: 0 = ok | 3 = bad args, invalid values, or failed publication
set -uo pipefail

CODEX_CONF="$HOME/.codex/config.toml"
IMPL_EFFORT_FILE="$HOME/.codex/maestro-impl-effort"
SCOUT_FILE="$HOME/.codex/maestro-scout"
MAESTRO_DIR="$HOME/.maestro"
ASK_FLAG="$MAESTRO_DIR/ask-on-start"
PIN_LOCK="$HOME/.codex/maestro-pin.lock"
PIN_LOCK_TOKEN=""
PIN_LOCK_HELD=0

pin_lock_metadata_value() { # field
  sed -n "s/^$1=//p" "$PIN_LOCK/metadata" 2>/dev/null | head -1
}

pin_lock_process_start() { # pid
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

pin_lock_release() {
  local recorded
  [ "$PIN_LOCK_HELD" -eq 1 ] || return 0
  recorded=$(pin_lock_metadata_value token)
  [ "$recorded" = "$PIN_LOCK_TOKEN" ] || return 0
  rm -f "$PIN_LOCK/metadata" 2>/dev/null || return 0
  rmdir "$PIN_LOCK" 2>/dev/null || :
  PIN_LOCK_HELD=0
}

pin_lock_acquire() {
  local token process_start temp owner_token owner_pid owner_start current_start reclaim tick=0
  mkdir -p "$HOME/.codex" || return 3
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 3
  process_start=$(pin_lock_process_start "$$")
  [ -n "$process_start" ] || process_start=unavailable
  while [ "$tick" -lt 200 ]; do
    if mkdir "$PIN_LOCK" 2>/dev/null; then
      temp="$PIN_LOCK/metadata.tmp.$token"
      if ! printf 'token=%s\npid=%s\nprocess_start=%s\n' "$token" "$$" "$process_start" > "$temp" ||
        ! mv -f "$temp" "$PIN_LOCK/metadata"; then
        rm -f "$temp" 2>/dev/null || :
        rmdir "$PIN_LOCK" 2>/dev/null || :
        return 3
      fi
      PIN_LOCK_TOKEN=$token
      PIN_LOCK_HELD=1
      trap pin_lock_release EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      return 0
    fi
    owner_token=$(pin_lock_metadata_value token)
    owner_pid=$(pin_lock_metadata_value pid)
    owner_start=$(pin_lock_metadata_value process_start)
    case "$owner_pid" in ''|*[!0-9]*)
      sleep 0.05
      tick=$((tick + 1))
      continue ;;
    esac
    if kill -0 "$owner_pid" 2>/dev/null; then
      current_start=$(pin_lock_process_start "$owner_pid")
      if [ -z "$current_start" ] || [ -z "$owner_start" ] ||
        [ "$owner_start" = unavailable ] || [ "$current_start" = "$owner_start" ]; then
        sleep 0.05
        tick=$((tick + 1))
        continue
      fi
    fi
    [ -n "$owner_token" ] || return 3
    [ "$(pin_lock_metadata_value token)" = "$owner_token" ] || continue
    reclaim="$PIN_LOCK/.reclaim"
    if ! mkdir "$reclaim" 2>/dev/null; then
      sleep 0.05
      tick=$((tick + 1))
      continue
    fi
    if [ "$(pin_lock_metadata_value token)" != "$owner_token" ]; then
      rmdir "$reclaim" 2>/dev/null || :
      continue
    fi
    if rm -f "$PIN_LOCK/metadata" 2>/dev/null &&
      rmdir "$reclaim" 2>/dev/null && rmdir "$PIN_LOCK" 2>/dev/null; then
      continue
    fi
    rmdir "$reclaim" 2>/dev/null || :
    return 3
  done
  echo "SELECT_ERROR: another model selection is still active; no pin files were changed" >&2
  return 3
}

valid_effort() {
  case "$1" in
    none|minimal|low|medium|high|xhigh|max|ultra) return 0 ;;
    *) return 1 ;;
  esac
}

valid_impl_effort() {
  case "$1" in
    none|minimal|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

valid_model() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

read_scout_pin() { # model-variable effort-variable
  local model_value="" effort_value=""
  if [ -f "$SCOUT_FILE" ]; then
    model_value=$(sed -n 's/^model=//p' "$SCOUT_FILE" | head -1)
    effort_value=$(sed -n 's/^effort=//p' "$SCOUT_FILE" | head -1)
  fi
  printf -v "$1" '%s' "$model_value"
  printf -v "$2" '%s' "$effort_value"
}

scout_pin_valid() { # model effort
  local first second lines
  [ -f "$SCOUT_FILE" ] || return 1
  first=$(sed -n '1p' "$SCOUT_FILE")
  second=$(sed -n '2p' "$SCOUT_FILE")
  lines=$(wc -l < "$SCOUT_FILE" | tr -d '[:space:]')
  [ "$lines" = 2 ] && [ "$first" = "model=$1" ] &&
    [ "$second" = "effort=$2" ] && valid_model "$1" &&
    valid_impl_effort "$2"
}

scout_pin() {
  local model effort howto='codex-model-select.sh --scout <model> <effort>'
  if [ ! -f "$SCOUT_FILE" ]; then
    echo "SELECT_ERROR: scout pin is missing; pin with: $howto" >&2
    return 3
  fi
  read_scout_pin model effort
  if ! scout_pin_valid "$model" "$effort"; then
    if [ -n "$model" ] && ! valid_model "$model"; then
      echo "SELECT_ERROR: invalid scout model '$model'; pin with: $howto" >&2
    elif [ -n "$effort" ] && ! valid_impl_effort "$effort"; then
      echo "SELECT_ERROR: invalid scout effort '$effort' (expected: none | minimal | low | medium | high | xhigh); pin with: $howto" >&2
    else
      echo "SELECT_ERROR: malformed scout pin; pin with: $howto" >&2
    fi
    return 3
  fi
  printf '%s\t%s\n' "$model" "$effort"
}

# TOML tables may be indented. Multiline strings are copied/scanned without
# treating their contents as keys or table headers.
read_pin() {
  local MODEL_VALUE="" EFFORT_VALUE="" VALUES
  if [ -f "$CODEX_CONF" ]; then
    VALUES=$(awk '
      function occurrences(line, token, count) {
        count = 0
        while ((at = index(line, token)) > 0) {
          count++
          line = substr(line, at + length(token))
        }
        return count
      }
      BEGIN { triple_single = sprintf("%c%c%c", 39, 39, 39); quote = "" }
      {
        line = $0
        if (quote != "") {
          if (occurrences(line, quote) % 2 == 1) quote = ""
          next
        }
        double_count = occurrences(line, "\"\"\"")
        single_count = occurrences(line, triple_single)
        if (double_count % 2 == 1) quote = "\"\"\""
        else if (single_count % 2 == 1) quote = triple_single
        if (line ~ /^[[:space:]]*\[/) exit
        if (line ~ /^[[:space:]]*model[[:space:]]*=/) {
          split(line, fields, "\"")
          model = fields[2]
        } else if (line ~ /^[[:space:]]*model_reasoning_effort[[:space:]]*=/) {
          split(line, fields, "\"")
          effort = fields[2]
        }
      }
      END { printf "%s\t%s", model, effort }
    ' "$CODEX_CONF") || return 3
    MODEL_VALUE=${VALUES%%$'\t'*}
    EFFORT_VALUE=${VALUES#*$'\t'}
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
  local M E I SM SE
  read_pin M E || return 3
  read_impl_effort I
  echo "model=${M:-(not pinned — Codex default)}"
  if [ -n "$E" ] && ! valid_effort "$E"; then
    echo "effort=$E (invalid)"
  else
    echo "effort=${E:-(not pinned — Codex default)}"
  fi
  echo "impl-effort=$I"
  if [ ! -f "$SCOUT_FILE" ]; then
    echo "scout=(not pinned — scout dispatch disabled)"
  else
    read_scout_pin SM SE
    if scout_pin_valid "$SM" "$SE"; then
      echo "scout=$SM/$SE"
    else
      echo "scout=${SM:-?}/${SE:-?} (invalid)"
    fi
  fi
  if [ -f "$ASK_FLAG" ]; then echo "ask-on-start=on"; else echo "ask-on-start=off"; fi
}

pin() {
  local M E I
  read_pin M E || return 3
  read_impl_effort I
  if [ -z "$M" ] || [ -z "$E" ]; then
    echo "SELECT_ERROR: Codex model and effort must both be pinned in the config.toml preamble" >&2
    return 3
  fi
  if ! valid_effort "$E"; then
    echo "SELECT_ERROR: invalid debate effort '$E' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
    return 3
  fi
  if ! valid_impl_effort "$I"; then
    echo "SELECT_ERROR: invalid implementation effort '$I' (expected: none | minimal | low | medium | high | xhigh; max/ultra are debate-only because the companion wrapper cannot express them for write jobs)" >&2
    return 3
  fi
  printf '%s\t%s\t%s\n' "$M" "$E" "$I"
}

stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

render_config() { # source destination model effort
  local source="$1" destination="$2" model="$3" effort="$4"
  awk -v model_value="$model" -v effort_value="$effort" '
    function occurrences(line, token, count) {
      count = 0
      while ((at = index(line, token)) > 0) {
        count++
        line = substr(line, at + length(token))
      }
      return count
    }
    function insert_missing() {
      if (!model_written) print "model = \"" model_value "\""
      if (!effort_written) print "model_reasoning_effort = \"" effort_value "\""
      model_written = effort_written = 1
    }
    BEGIN {
      triple_single = sprintf("%c%c%c", 39, 39, 39)
      quote = ""
      in_table = 0
      model_written = 0
      effort_written = 0
    }
    {
      line = $0
      if (quote != "") {
        print line
        if (occurrences(line, quote) % 2 == 1) quote = ""
        next
      }
      double_count = occurrences(line, "\"\"\"")
      single_count = occurrences(line, triple_single)
      if (!in_table && line ~ /^[[:space:]]*\[/) {
        insert_missing()
        in_table = 1
      }
      if (!in_table && line ~ /^[[:space:]]*model[[:space:]]*=/) {
        if (!model_written) print "model = \"" model_value "\""
        model_written = 1
        next
      }
      if (!in_table && line ~ /^[[:space:]]*model_reasoning_effort[[:space:]]*=/) {
        if (!effort_written) print "model_reasoning_effort = \"" effort_value "\""
        effort_written = 1
        next
      }
      print line
      if (double_count % 2 == 1) quote = "\"\"\""
      else if (single_count % 2 == 1) quote = triple_single
    }
    END { if (!in_table) insert_missing() }
  ' "$source" > "$destination"
}

publish_pin() { # model debate-effort impl-effort
  local model="$1" effort="$2" impl="$3"
  local config_source config_tmp impl_tmp config_original impl_original
  local config_existed=0 impl_existed=0 config_mode=600 impl_mode=600
  mkdir -p "$HOME/.codex" || return 3
  config_tmp="$CODEX_CONF.mtmp.$$"
  impl_tmp="$IMPL_EFFORT_FILE.mtmp.$$"
  config_original="$CODEX_CONF.moriginal.$$"
  impl_original="$IMPL_EFFORT_FILE.moriginal.$$"

  if [ -f "$CODEX_CONF" ]; then
    config_existed=1
    config_mode=$(stat_mode "$CODEX_CONF") || return 3
    cp -p "$CODEX_CONF" "$config_original" || return 3
    config_source=$CODEX_CONF
  else
    config_source=/dev/null
  fi
  if [ -f "$IMPL_EFFORT_FILE" ]; then
    impl_existed=1
    impl_mode=$(stat_mode "$IMPL_EFFORT_FILE") || {
      rm -f "$config_original"
      return 3
    }
    cp -p "$IMPL_EFFORT_FILE" "$impl_original" || {
      rm -f "$config_original"
      return 3
    }
  fi

  if ! render_config "$config_source" "$config_tmp" "$model" "$effort" ||
    ! chmod "$config_mode" "$config_tmp" ||
    ! printf '%s\n' "$impl" > "$impl_tmp" ||
    ! chmod "$impl_mode" "$impl_tmp"; then
    rm -f "$config_tmp" "$impl_tmp" "$config_original" "$impl_original"
    echo "SELECT_ERROR: could not stage Codex pin files" >&2
    return 3
  fi

  if [ "$config_existed" -eq 1 ] && [ ! -f "$CODEX_CONF.maestro.bak" ]; then
    cp -p "$CODEX_CONF" "$CODEX_CONF.maestro.bak" || {
      rm -f "$config_tmp" "$impl_tmp" "$config_original" "$impl_original"
      echo "SELECT_ERROR: could not back up config.toml" >&2
      return 3
    }
    echo "SELECT: backed up config.toml → config.toml.maestro.bak"
  fi

  if ! mv -f "$config_tmp" "$CODEX_CONF"; then
    rm -f "$config_tmp" "$impl_tmp" "$config_original" "$impl_original"
    echo "SELECT_ERROR: could not publish config.toml" >&2
    return 3
  fi
  if ! mv -f "$impl_tmp" "$IMPL_EFFORT_FILE"; then
    if [ "$config_existed" -eq 1 ]; then
      mv -f "$config_original" "$CODEX_CONF" 2>/dev/null ||
        cp -p "$config_original" "$CODEX_CONF" 2>/dev/null || :
    else
      rm -f "$CODEX_CONF"
    fi
    if [ "$impl_existed" -eq 1 ] && [ ! -f "$IMPL_EFFORT_FILE" ]; then
      cp -p "$impl_original" "$IMPL_EFFORT_FILE" 2>/dev/null || :
    fi
    rm -f "$config_tmp" "$impl_tmp" "$config_original" "$impl_original"
    echo "SELECT_ERROR: could not publish implementation effort; previous pin restored" >&2
    return 3
  fi
  rm -f "$config_original" "$impl_original"
  return 0
}

publish_scout_pin() { # model effort
  local tmp="$SCOUT_FILE.mtmp.$$"
  mkdir -p "$HOME/.codex" || return 3
  if ! printf 'model=%s\neffort=%s\n' "$1" "$2" > "$tmp" ||
    ! chmod 600 "$tmp" || ! mv -f "$tmp" "$SCOUT_FILE"; then
    rm -f "$tmp" 2>/dev/null || :
    echo "SELECT_ERROR: could not publish scout pin" >&2
    return 3
  fi
}

case "${1:-}" in
  --show)
    pin_lock_acquire || exit 3
    show
    exit $? ;;
  --pin)
    pin_lock_acquire || exit 3
    pin
    exit $? ;;
  --scout-pin)
    [ "$#" -eq 1 ] || { echo "usage: codex-model-select.sh --scout-pin" >&2; exit 3; }
    pin_lock_acquire || exit 3
    scout_pin
    exit $? ;;
  --scout)
    [ "$#" -eq 3 ] || { echo "usage: codex-model-select.sh --scout <model> <effort>" >&2; exit 3; }
    pin_lock_acquire || exit 3
    if ! valid_model "$2"; then
      echo "SELECT_ERROR: invalid scout model '$2' (expected letters, digits, . _ -)" >&2
      exit 3
    fi
    if ! valid_impl_effort "$3"; then
      echo "SELECT_ERROR: invalid scout effort '$3' (expected: none | minimal | low | medium | high | xhigh)" >&2
      exit 3
    fi
    publish_scout_pin "$2" "$3" || exit 3
    echo "SELECT: scout pin updated → model=$2 effort=$3 (applies from the next scout dispatch)"
    exit 0 ;;
  --ask-on-start)
    case "${2:-}" in
      on)  mkdir -p "$MAESTRO_DIR" && : > "$ASK_FLAG" && echo "ask-on-start=on — the setup prompt fires at each new session" ;;
      off) rm -f "$ASK_FLAG" && echo "ask-on-start=off — session start shows a status line only" ;;
      status) [ -f "$ASK_FLAG" ] && echo "ask-on-start=on" || echo "ask-on-start=off" ;;
      *) echo "usage: codex-model-select.sh --ask-on-start on|off|status" >&2; exit 3 ;;
    esac
    exit $? ;;
  ""|--help|-h)
    echo "usage: codex-model-select.sh --show | --pin | --scout <model> <effort> | --scout-pin | <model> <debate-effort> [impl-effort] | --ask-on-start on|off|status" >&2
    exit 3 ;;
esac

pin_lock_acquire || exit 3
MODEL="${1:-}"
EFFORT="${2:-}"
if [ $# -ge 3 ]; then
  IMPL_EFFORT="$3"
else
  read_impl_effort IMPL_EFFORT
fi

if ! valid_model "$MODEL"; then
  echo "SELECT_ERROR: invalid model name '$MODEL' (expected e.g. gpt-5.6-sol — letters, digits, . _ -)" >&2
  exit 3
fi
if ! valid_effort "$EFFORT"; then
  echo "SELECT_ERROR: invalid effort '$EFFORT' (expected: none | minimal | low | medium | high | xhigh | max | ultra)" >&2
  exit 3
fi
if ! valid_impl_effort "$IMPL_EFFORT"; then
  echo "SELECT_ERROR: invalid implementation effort '$IMPL_EFFORT' (expected: none | minimal | low | medium | high | xhigh; max/ultra are debate-only because the companion wrapper cannot express them for write jobs)" >&2
  exit 3
fi

if ! publish_pin "$MODEL" "$EFFORT" "$IMPL_EFFORT"; then
  exit 3
fi
echo "SELECT: Codex pin updated → model=$MODEL debate-effort=$EFFORT impl-effort=$IMPL_EFFORT (applies from the next dispatch)"
