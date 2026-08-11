#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.mjs"
UNINSTALL="$ROOT/uninstall.mjs"
SELECTOR="$ROOT/hooks/codex-model-select.sh"
SESSION_START="$ROOT/hooks/session-start.mjs"
REAL_NODE=$(node -p 'process.execPath')
TEST_ROOT=$(mktemp -d /tmp/maestro-install.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

new_home() {
  local home="$TEST_ROOT/$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/rules"
  printf '%s' "$home"
}

run_install() { # home output [args...]
  local home="$1" output="$2"
  shift 2
  env HOME="$home" "$REAL_NODE" "$INSTALL" "$@" > "$output" 2>&1
}

run_uninstall() { # home output
  env HOME="$1" "$REAL_NODE" "$UNINSTALL" > "$2" 2>&1
}

file_identity() {
  stat -f '%i:%m' "$1" 2>/dev/null || stat -c '%i:%Y' "$1"
}

managed_commands() { # settings
  "$REAL_NODE" - "$1" <<'NODE'
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const blocks of Object.values(value.hooks ?? {})) {
  for (const block of blocks) {
    for (const hook of block.hooks ?? []) {
      if (hook.command?.includes('# maestro-managed:')) console.log(hook.command);
    }
  }
}
NODE
}

t1_schema_failure_mutates_nothing() {
  local home out rc target
  home=$(new_home schema)
  out="$home/install.out"
  target="$home/.claude/hooks/orchestrator-gate.mjs"
  printf 'USER BYTES\n' > "$target"
  printf '{"hooks":[]}\n' > "$home/.claude/settings.json"
  run_install "$home" "$out"; rc=$?
  [ "$rc" -ne 0 ] || { echo "install accepted hooks array"; return 1; }
  [ "$(cat "$target")" = 'USER BYTES' ] || { echo "foreign hook was overwritten before schema failure"; return 1; }
  [ ! -e "$home/.claude/hooks/lib-companion.sh" ] || { echo "other managed files were copied before schema failure"; return 1; }
}

t2_foreign_managed_path_is_refused() {
  local home out rc target
  home=$(new_home divergence)
  out="$home/install.out"
  target="$home/.claude/hooks/orchestrator-gate.mjs"
  printf '{}\n' > "$home/.claude/settings.json"
  printf 'FOREIGN GATE\n' > "$target"
  run_install "$home" "$out"; rc=$?
  [ "$rc" -ne 0 ] || { echo "install overwrote an unowned same-named hook"; return 1; }
  [ "$(cat "$target")" = 'FOREIGN GATE' ] || { echo "foreign bytes changed"; return 1; }
  [ ! -e "$home/.claude/hooks/lib-companion.sh" ] || { echo "partial install occurred after divergence"; return 1; }
  grep -q 'refus' "$out" || { echo "divergence refusal was not explained"; return 1; }
}

t3_exact_settings_identity_survives_round_trip() {
  local home install_out uninstall_out settings foreign commands
  home=$(new_home settings-identity)
  install_out="$home/install.out"
  uninstall_out="$home/uninstall.out"
  settings="$home/.claude/settings.json"
  foreign='node /tmp/orchestrator-gate.mjs.backup'
  cat > "$settings" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": "$foreign" }
        ]
      }
    ]
  }
}
EOF
  run_install "$home" "$install_out" || { cat "$install_out"; return 1; }
  commands=$(managed_commands "$settings")
  [ "$(printf '%s\n' "$commands" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 3 ] ||
    { echo "expected three explicitly marked commands: $commands"; return 1; }
  grep -Fq "$foreign" "$settings" || { echo "foreign similarly named command was removed"; return 1; }
  run_uninstall "$home" "$uninstall_out" || { cat "$uninstall_out"; return 1; }
  grep -Fq "$foreign" "$settings" || { echo "uninstall removed foreign similarly named command"; return 1; }
  [ -z "$(managed_commands "$settings")" ] || { echo "managed commands survived uninstall"; return 1; }
}

t4_modified_hook_survives_uninstall() {
  local home install_out uninstall_out modified untouched
  home=$(new_home modified-hook)
  install_out="$home/install.out"
  uninstall_out="$home/uninstall.out"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$install_out" || { cat "$install_out"; return 1; }
  modified="$home/.claude/hooks/orchestrator-gate.mjs"
  untouched="$home/.claude/hooks/lib-companion.sh"
  printf 'USER MODIFIED AFTER INSTALL\n' > "$modified"
  run_uninstall "$home" "$uninstall_out" || { cat "$uninstall_out"; return 1; }
  [ -f "$modified" ] && [ "$(cat "$modified")" = 'USER MODIFIED AFTER INSTALL' ] ||
    { echo "uninstall deleted or changed a modified hook"; return 1; }
  [ ! -e "$untouched" ] || { echo "uninstall kept untouched managed hook"; return 1; }
}

t5_settings_backup_refreshes_before_each_merge() {
  local home first second settings bak
  home=$(new_home backup-refresh)
  first="$home/first.out"
  second="$home/second.out"
  settings="$home/.claude/settings.json"
  bak="$settings.maestro.bak"
  printf '{"theme":"one"}\n' > "$settings"
  run_install "$home" "$first" || { cat "$first"; return 1; }
  "$REAL_NODE" - "$settings" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.theme = 'two';
value.hooks.SessionStart = [];
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
  run_install "$home" "$second" || { cat "$second"; return 1; }
  grep -q '"theme": "two"' "$bak" || { echo "backup did not capture latest user settings"; return 1; }
  "$REAL_NODE" -e 'const fs=require("node:fs"); const s=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (!Array.isArray(s.hooks.SessionStart) || s.hooks.SessionStart.length !== 0) process.exit(1)' "$bak" ||
    { echo "backup was not the exact pre-merge settings"; return 1; }
}

t6_manifest_supports_version_independent_uninstall() {
  local home install_out uninstall_out rule manifest hash
  home=$(new_home version-manifest)
  install_out="$home/install.out"
  uninstall_out="$home/uninstall.out"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$install_out" || { cat "$install_out"; return 1; }
  rule="$home/.claude/rules/coding-discipline.md"
  manifest="$home/.maestro/install-manifest.json"
  [ -f "$manifest" ] || { echo "ownership manifest missing"; return 1; }
  printf 'BYTES FROM INSTALLED VERSION A\n' > "$rule"
  hash=$("$REAL_NODE" -e 'const fs=require("node:fs"),c=require("node:crypto"); process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$rule")
  "$REAL_NODE" - "$manifest" "$hash" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const hash = process.argv[3];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.files['rules/coding-discipline.md'] = hash;
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
  run_uninstall "$home" "$uninstall_out" || { cat "$uninstall_out"; return 1; }
  [ ! -e "$rule" ] || { echo "version-A managed bytes were compared to version-B source instead of manifest"; return 1; }
}

t7_invalid_settings_prevents_partial_uninstall() {
  local home install_out uninstall_out hook before rc
  home=$(new_home uninstall-schema)
  install_out="$home/install.out"
  uninstall_out="$home/uninstall.out"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$install_out" || { cat "$install_out"; return 1; }
  hook="$home/.claude/hooks/lib-companion.sh"
  before="$home/hook.before"
  cp "$hook" "$before"
  printf '{not-json\n' > "$home/.claude/settings.json"
  run_uninstall "$home" "$uninstall_out"; rc=$?
  [ "$rc" -ne 0 ] || { echo "invalid settings uninstall returned success"; return 1; }
  cmp -s "$hook" "$before" || { echo "managed hook changed before settings validation"; return 1; }
  [ "$(cat "$home/.claude/settings.json")" = '{not-json' ] || { echo "invalid settings changed"; return 1; }
}

t8_nested_or_multiline_web_search_does_not_fake_top_level() {
  local home out config before_table
  home=$(new_home top-level-web-search)
  out="$home/install.out"
  config="$home/.codex/config.toml"
  mkdir -p "$home/.codex"
  printf '{}\n' > "$home/.claude/settings.json"
  cat > "$config" <<'EOF'
notes = """
web_search = "live"
"""

  [mcp_servers.example.env]
  web_search = "live"
EOF
  run_install "$home" "$out" || { cat "$out"; return 1; }
  before_table=$(awk '/^[[:space:]]*\[/{exit} {print}' "$config")
  printf '%s\n' "$before_table" | grep -qx 'web_search = "disabled"' ||
    { echo "installer did not add a true top-level web_search key: $(cat "$config")"; return 1; }
  [ "$(grep -c '^[[:space:]]*web_search[[:space:]]*=' "$config")" -eq 3 ] ||
    { echo "nested or multiline keys were rewritten instead of preserved"; return 1; }
}

t9_unknown_option_fails_before_mutation() {
  local home out rc settings
  home=$(new_home unknown-option)
  out="$home/install.out"
  settings="$home/.claude/settings.json"
  printf '{"theme":"unchanged"}\n' > "$settings"
  run_install "$home" "$out" --with-workfow; rc=$?
  [ "$rc" -ne 0 ] || { echo "unknown option performed an install"; return 1; }
  [ "$(cat "$settings")" = '{"theme":"unchanged"}' ] || { echo "settings changed after unknown option"; return 1; }
  [ ! -e "$home/.claude/hooks/lib-companion.sh" ] || { echo "managed files copied after unknown option"; return 1; }
  [ ! -e "$home/.maestro/install-manifest.json" ] || { echo "manifest created after unknown option"; return 1; }
  grep -q 'unknown option' "$out" || { echo "usage error did not name the unknown option"; return 1; }
}

t10_reinstall_preserves_disabled_session_prompt() {
  local home first second flag
  home=$(new_home ask-preference)
  first="$home/first.out"
  second="$home/second.out"
  flag="$home/.maestro/ask-on-start"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$first" || { cat "$first"; return 1; }
  [ -f "$flag" ] || { echo "fresh install did not arm the setup prompt"; return 1; }
  HOME="$home" bash "$SELECTOR" --ask-on-start off >/dev/null || return 1
  [ ! -e "$flag" ] || { echo "selector did not disable setup prompt"; return 1; }
  run_install "$home" "$second" || { cat "$second"; return 1; }
  [ ! -e "$flag" ] || { echo "reinstall silently re-enabled setup prompt"; return 1; }
}

t11_identical_reinstall_keeps_managed_file_identity() {
  local home first second before after name identity path
  home=$(new_home reinstall-idempotent)
  first="$home/first.out"
  second="$home/second.out"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$first" || { cat "$first"; return 1; }
  before=$(
    for name in lib-process.sh lib-companion.sh lib-write-lease.sh lib-write-turn.sh; do
      path="$home/.claude/hooks/$name"
      [ -f "$path" ] || { echo "$name was not installed" >&2; exit 1; }
      identity=$(file_identity "$path") || exit 1
      printf '%s=%s\n' "$name" "$identity"
    done
  ) || return 1
  sleep 1
  run_install "$home" "$second" || { cat "$second"; return 1; }
  after=$(
    for name in lib-process.sh lib-companion.sh lib-write-lease.sh lib-write-turn.sh; do
      path="$home/.claude/hooks/$name"
      [ -f "$path" ] || { echo "$name was not installed" >&2; exit 1; }
      identity=$(file_identity "$path") || exit 1
      printf '%s=%s\n' "$name" "$identity"
    done
  ) || return 1
  [ "$after" = "$before" ] ||
    { echo "identical reinstall replaced a managed library"; return 1; }
}

t12_late_install_failure_rolls_back_managed_files() {
  local home out rc
  home=$(new_home transaction-rollback)
  out="$home/install.out"
  printf '{}\n' > "$home/.claude/settings.json"
  chmod 700 "$home/.claude/hooks" "$home/.claude/rules"
  chmod 500 "$home/.claude"
  run_install "$home" "$out"; rc=$?
  chmod 700 "$home/.claude"
  [ "$rc" -ne 0 ] || { echo "fault-injected install unexpectedly succeeded"; return 1; }
  [ ! -e "$home/.claude/hooks/lib-companion.sh" ] || { echo "hook survived failed transaction"; return 1; }
  [ ! -e "$home/.claude/rules/coding-discipline.md" ] || { echo "rule survived failed transaction"; return 1; }
  [ "$(cat "$home/.claude/settings.json")" = '{}' ] || { echo "settings changed despite failed transaction"; return 1; }
  [ ! -e "$home/.maestro/install-manifest.json" ] || { echo "manifest published for failed transaction"; return 1; }
}

t13_fresh_session_does_not_call_unpinned_defaults_usable() {
  local home output
  home=$(new_home session-unpinned)
  mkdir -p "$home/.maestro" "$home/.codex"
  : > "$home/.maestro/ask-on-start"
  output=$(printf '%s' '{"source":"startup","session_id":"session-test"}' |
    env HOME="$home" "$REAL_NODE" "$SESSION_START") || return 1
  case "$output" in
    *'NOT complete'*'cannot dispatch Codex until values are selected'*) ;;
    *) echo "fresh session presented unpinned defaults as usable: $output"; return 1 ;;
  esac
  printf 'model = "gpt-test"\nmodel_reasoning_effort = "high"\n' > "$home/.codex/config.toml"
  output=$(printf '%s' '{"source":"startup","session_id":"session-test"}' |
    env HOME="$home" "$REAL_NODE" "$SESSION_START") || return 1
  case "$output" in
    *'complete; if the user declines or skips, preserve it'*) ;;
    *) echo "complete pin was not offered as preservable: $output"; return 1 ;;
  esac
}

t14_uninstall_removes_private_authorization_markers() {
  local home install_out uninstall_out auth_dir marker
  home=$(new_home uninstall-authorization)
  install_out="$home/install.out"
  uninstall_out="$home/uninstall.out"
  printf '{}\n' > "$home/.claude/settings.json"
  run_install "$home" "$install_out" || { cat "$install_out"; return 1; }
  auth_dir="$home/.maestro/direct-edit"
  marker="$auth_dir/maestro-direct-session-test.flag"
  mkdir -p "$auth_dir"
  chmod 700 "$home/.maestro" "$auth_dir"
  printf '1\n' > "$marker"
  chmod 600 "$marker"
  run_uninstall "$home" "$uninstall_out" || { cat "$uninstall_out"; return 1; }
  [ ! -e "$marker" ] || { echo "private authorization marker survived uninstall"; return 1; }
  [ ! -d "$auth_dir" ] || { echo "empty authorization directory survived uninstall"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Installer ownership verification ===\n'
check t1_schema_failure_mutates_nothing "settings schema is validated before any mutation"
check t2_foreign_managed_path_is_refused "unowned same-named files are never overwritten"
check t3_exact_settings_identity_survives_round_trip "only explicit Maestro hook commands are managed"
check t4_modified_hook_survives_uninstall "uninstall byte-compares every managed hook"
check t5_settings_backup_refreshes_before_each_merge "settings backup refreshes before each merge"
check t6_manifest_supports_version_independent_uninstall "manifest decouples uninstall ownership from repo version"
check t7_invalid_settings_prevents_partial_uninstall "invalid settings prevents a partial uninstall"
check t8_nested_or_multiline_web_search_does_not_fake_top_level "only a true top-level TOML key satisfies web_search configuration"
check t9_unknown_option_fails_before_mutation "unknown installer options fail before mutation"
check t10_reinstall_preserves_disabled_session_prompt "reinstall preserves an explicit ask-on-start=off preference"
check t11_identical_reinstall_keeps_managed_file_identity "identical reinstall leaves managed file identity unchanged"
check t12_late_install_failure_rolls_back_managed_files "late installer failure rolls back all managed file publications"
check t13_fresh_session_does_not_call_unpinned_defaults_usable "session setup distinguishes an unusable fresh pin from keep-current"
check t14_uninstall_removes_private_authorization_markers "uninstall removes private direct-edit authorization state"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
