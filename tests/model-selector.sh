#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="$ROOT/hooks/codex-model-select.sh"
TEST_ROOT=$(mktemp -d /tmp/maestro-model-selector.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

new_home() {
  local home="$TEST_ROOT/$1"
  mkdir -p "$home/.codex"
  printf '%s' "$home"
}

t1_preserves_mode_and_nested_tables() {
  local home config impl output mode nested
  home=$(new_home preserve)
  config="$home/.codex/config.toml"
  impl="$home/.codex/maestro-impl-effort"
  cat > "$config" <<'EOF'
model = "old-model"
model_reasoning_effort = "medium"

  [profiles.indented]
  model = "nested-model"
  model_reasoning_effort = "low"
EOF
  printf 'medium\n' > "$impl"
  chmod 600 "$config" "$impl"
  output=$(HOME="$home" bash "$SELECTOR" gpt-5.6-sol high low 2>&1) ||
    { echo "selector failed: $output"; return 1; }
  mode=$(mode_of "$config")
  [ "$mode" = 600 ] || { echo "config mode=$mode want 600"; return 1; }
  [ "$(mode_of "$impl")" = 600 ] || { echo "impl mode changed"; return 1; }
  grep -qx 'model = "gpt-5.6-sol"' "$config" || { echo "top-level model not updated"; return 1; }
  grep -qx 'model_reasoning_effort = "high"' "$config" || { echo "top-level effort not updated"; return 1; }
  nested=$(awk '/^[[:space:]]*\[profiles.indented\]/{inside=1; next} inside{print}' "$config")
  printf '%s\n' "$nested" | grep -qx '  model = "nested-model"' || { echo "nested model changed: $nested"; return 1; }
  printf '%s\n' "$nested" | grep -qx '  model_reasoning_effort = "low"' || { echo "nested effort changed: $nested"; return 1; }
  [ "$(cat "$impl")" = low ] || { echo "implementation effort not updated"; return 1; }
  [ "$(HOME="$home" bash "$SELECTOR" --pin)" = $'gpt-5.6-sol\thigh\tlow' ] ||
    { echo "--pin disagrees with written values"; return 1; }
}

t2_indented_table_is_not_top_level_pin() {
  local home output rc
  home=$(new_home indented-only)
  cat > "$home/.codex/config.toml" <<'EOF'
  [profiles.only]
  model = "nested-model"
  model_reasoning_effort = "high"
EOF
  printf 'medium\n' > "$home/.codex/maestro-impl-effort"
  output=$(HOME="$home" bash "$SELECTOR" --pin 2>&1); rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc want 3, output=$output"; return 1; }
}

t3_failed_publish_rolls_back_both_files() {
  local home config impl shim real_mv output rc
  home=$(new_home rollback)
  config="$home/.codex/config.toml"
  impl="$home/.codex/maestro-impl-effort"
  shim="$home/shim"
  real_mv=$(command -v mv)
  mkdir -p "$shim"
  printf 'model = "old-model"\nmodel_reasoning_effort = "medium"\n' > "$config"
  printf 'medium\n' > "$impl"
  cp "$config" "$home/config.before"
  cp "$impl" "$home/impl.before"
  cat > "$shim/mv" <<EOF
#!/usr/bin/env bash
last="\${!#}"
if [ "\$last" = "$impl" ] && [ ! -e "$home/failed-once" ]; then
  : > "$home/failed-once"
  exit 1
fi
exec "$real_mv" "\$@"
EOF
  chmod +x "$shim/mv"
  output=$(HOME="$home" PATH="$shim:$PATH" bash "$SELECTOR" new-model high low 2>&1); rc=$?
  [ "$rc" -ne 0 ] || { echo "failed publish returned success: $output"; return 1; }
  case "$output" in *'Codex pin updated'*) echo "failed publish claimed success"; return 1 ;; esac
  cmp -s "$config" "$home/config.before" || { echo "config was not rolled back"; return 1; }
  cmp -s "$impl" "$home/impl.before" || { echo "impl effort changed despite failure"; return 1; }
}

t4_rejects_unexpressible_implementation_effort() {
  local home config impl output rc
  home=$(new_home reject-impl-ultra)
  config="$home/.codex/config.toml"
  impl="$home/.codex/maestro-impl-effort"
  printf 'model = "old-model"\nmodel_reasoning_effort = "medium"\n' > "$config"
  printf 'medium\n' > "$impl"
  cp "$config" "$home/config.before"
  cp "$impl" "$home/impl.before"
  output=$(HOME="$home" bash "$SELECTOR" new-model high ultra 2>&1); rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc want 3: $output"; return 1; }
  case "$output" in *'implementation effort'*'none | minimal | low | medium | high | xhigh'*) ;; *)
    echo "rejection did not explain wrapper-supported implementation tiers: $output"; return 1 ;; esac
  cmp -s "$config" "$home/config.before" || { echo "config changed after rejected implementation effort"; return 1; }
  cmp -s "$impl" "$home/impl.before" || { echo "implementation file changed after rejection"; return 1; }
}

t5_concurrent_selection_cannot_publish_torn_pin() {
  local home config impl shim real_mv a_pid a_rc b_rc final
  home=$(new_home concurrent)
  config="$home/.codex/config.toml"
  impl="$home/.codex/maestro-impl-effort"
  shim="$home/shim"
  real_mv=$(command -v mv)
  mkdir -p "$shim"
  printf 'model = "old-model"\nmodel_reasoning_effort = "medium"\n' > "$config"
  printf 'medium\n' > "$impl"
  cat > "$shim/mv" <<EOF
#!/usr/bin/env bash
last="\${!#}"
"$real_mv" "\$@"
rc=\$?
if [ "\$rc" -eq 0 ] && [ "\$last" = "$config" ] && grep -q 'model = "model-a"' "$config"; then
  : > "$home/a-config-published"
  while [ ! -e "$home/allow-a" ]; do sleep 0.01; done
fi
exit "\$rc"
EOF
  chmod +x "$shim/mv"
  HOME="$home" PATH="$shim:$PATH" bash "$SELECTOR" model-a high high > "$home/a.out" 2>&1 &
  a_pid=$!
  for _ in $(seq 1 200); do
    [ -e "$home/a-config-published" ] && break
    sleep 0.01
  done
  [ -e "$home/a-config-published" ] || { kill "$a_pid" 2>/dev/null || :; echo "first selector never reached staged publish"; return 1; }
  HOME="$home" bash "$SELECTOR" model-b low low > "$home/b.out" 2>&1 &
  b_pid=$!
  sleep 0.1
  : > "$home/allow-a"
  wait "$a_pid"; a_rc=$?
  wait "$b_pid"; b_rc=$?
  [ "$a_rc" -eq 0 ] && [ "$b_rc" -eq 0 ] ||
    { echo "selector rc values A=$a_rc B=$b_rc; A=$(cat "$home/a.out") B=$(cat "$home/b.out")"; return 1; }
  final=$(HOME="$home" bash "$SELECTOR" --pin) || return 1
  [ "$final" = $'model-b\tlow\tlow' ] || { echo "concurrent final pin is torn or reordered: $final"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Model selector verification ===\n'
check t1_preserves_mode_and_nested_tables "selector preserves modes and nested TOML tables"
check t2_indented_table_is_not_top_level_pin "indented table keys cannot fake a top-level pin"
check t3_failed_publish_rolls_back_both_files "failed second publish rolls back both files"
check t4_rejects_unexpressible_implementation_effort "selector rejects implementation effort the wrapper cannot express"
check t5_concurrent_selection_cannot_publish_torn_pin "concurrent selectors cannot publish a torn model/effort tuple"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
