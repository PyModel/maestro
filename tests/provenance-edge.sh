#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-write-lease.sh"
TEST_ROOT=$(mktemp -d /tmp/maestro-provenance-edge.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

digest() {
  (cd "$1" && bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; repo_digest") 2>/dev/null
}

new_repo() {
  local repo="$TEST_ROOT/$1"
  git init -q "$repo"
  (
    cd "$repo" || exit 1
    git config user.email p@p
    git config user.name p
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m init
  )
  printf '%s' "$repo"
}

t1_clean_filter_cannot_hide_materialized_changes() {
  local repo before after
  repo=$(new_repo no-filters)
  (
    cd "$repo" || exit 1
    printf '*.filtered filter=maestro-hide\n' > .gitattributes
    git config filter.maestro-hide.clean "sh -c 'printf normalized'"
    git config filter.maestro-hide.smudge cat
    printf 'materialized-one\n' > value.filtered
    git add .gitattributes value.filtered
    git commit -q -m filtered
  )
  before=$(digest "$repo") || { echo "initial digest failed"; return 1; }
  printf 'materialized-two\n' > "$repo/value.filtered"
  after=$(digest "$repo") || { echo "changed digest failed"; return 1; }
  [ "$before" != "$after" ] || { echo "clean filter hid a working-tree byte change"; return 1; }
}

t2_linked_worktree_changes_are_isolated() {
  local repo worktree main_before main_after worktree_before worktree_after
  repo=$(new_repo isolated-main)
  worktree="$TEST_ROOT/isolated-wt"
  git -C "$repo" worktree add -q "$worktree" -b isolated-branch >/dev/null 2>&1 || return 1
  main_before=$(digest "$repo") || { echo "main digest failed"; return 1; }
  worktree_before=$(digest "$worktree") || { echo "worktree digest failed"; return 1; }
  printf 'worktree-only change\n' > "$worktree/seed.txt"
  main_after=$(digest "$repo") || { echo "main digest after worktree edit failed"; return 1; }
  worktree_after=$(digest "$worktree") || { echo "worktree digest after edit failed"; return 1; }
  [ "$main_before" = "$main_after" ] ||
    { echo "another worktree changed the main worktree digest"; return 1; }
  [ "$worktree_before" != "$worktree_after" ] ||
    { echo "worktree-local change was invisible"; return 1; }
}

t3_untracked_nested_repository_is_observed() {
  local repo nested before after
  repo=$(new_repo nested-parent)
  nested="$repo/vendor-source"
  new_repo nested-child >/dev/null
  mv "$TEST_ROOT/nested-child" "$nested"
  before=$(digest "$repo") || { echo "initial nested digest failed"; return 1; }
  printf 'changed inside nested repository\n' > "$nested/seed.txt"
  after=$(digest "$repo") || { echo "changed nested digest failed"; return 1; }
  [ "$before" != "$after" ] || { echo "nested repository content change was invisible"; return 1; }
}

t4_release_publishes_baseline_before_handoff() {
  local repo state shim real_mv lock holder contender_out contender_rc
  local handoff_out handoff_rc
  repo=$(new_repo release-handoff)
  repo=$(cd "$repo" && pwd -P)
  state="$TEST_ROOT/release-handoff-state"
  shim="$state/shim"
  lock="$repo/.git/maestro-write.lock"
  real_mv=$(command -v mv)
  mkdir -p "$shim"
  # Establish a prior completed baseline.
  (
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-baseline >/dev/null 2>&1 || exit 1
    write_lock_release >/dev/null 2>&1
  ) || return 1
  cat > "$shim/mv" <<EOF
#!/usr/bin/env bash
"$real_mv" "\$@"
rc=\$?
if [ "\$rc" -eq 0 ] && [ "\${1:-}" = "$lock" ]; then
  case "\${2:-}" in
    "$lock".reclaim.*)
      : > "$state/lock-moved"
      while [ ! -e "$state/allow-release" ]; do sleep 0.05; done
      ;;
  esac
fi
exit "\$rc"
EOF
  chmod +x "$shim/mv"
  (
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-releasing >/dev/null 2>&1 || exit 1
    printf 'authorized change\n' > seed.txt
    PATH="$shim:$PATH" write_lock_release
  ) > "$state/holder.out" 2>&1 &
  holder=$!
  for _ in $(seq 1 600); do
    [ -e "$state/lock-moved" ] && break
    sleep 0.05
  done
  [ -e "$state/lock-moved" ] ||
    { kill "$holder" 2>/dev/null || :; echo "holder never moved the released generation"; return 1; }
  contender_out=$(
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    export MAESTRO_LOCK_WAIT_SEC=0
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-gated-contender 3>&1 >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || write_lock_release >/dev/null 2>&1
    exit "$rc"
  )
  contender_rc=$?
  : > "$state/allow-release"
  wait "$holder" || return 1
  [ "$contender_rc" -eq 11 ] ||
    { echo "contender rc=$contender_rc bypassed the release generation gate: $contender_out"; return 1; }
  handoff_out=$(
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    export MAESTRO_LOCK_WAIT_SEC=0
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-handoff-contender 3>&1 >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || write_lock_release >/dev/null 2>&1
    exit "$rc"
  )
  handoff_rc=$?
  [ "$handoff_rc" -eq 0 ] ||
    { echo "handoff contender rc=$handoff_rc: $handoff_out"; return 1; }
  if printf '%s\n' "$handoff_out" | grep -q 'BASELINE GAP'; then
    echo "contender observed a false gap after release handoff: $handoff_out"
    return 1
  fi
}

t5_digest_does_not_depend_on_shasum() {
  local repo shim output
  repo=$(new_repo no-shasum)
  shim="$TEST_ROOT/no-shasum-bin"
  mkdir -p "$shim"
  cat > "$shim/shasum" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$shim/shasum"
  output=$(cd "$repo" && PATH="$shim:$PATH" bash -c "exec 3>&-; set -uo pipefail; . '$LIB'; repo_digest") 2>/dev/null ||
    { echo "digest failed when shasum was unavailable"; return 1; }
  case "$output" in tree-v3:*) ;; *) echo "digest=$output"; return 1 ;; esac
}

t6_provenance_append_never_follows_symlink() {
  local repo log victim before
  repo=$(new_repo provenance-log-symlink)
  log="$repo/.git/maestro-provenance.log"
  victim="$TEST_ROOT/provenance-victim"
  printf 'DO NOT APPEND HERE\n' > "$victim"
  before=$(cat "$victim")
  ln -s "$victim" "$log"
  (
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-safe-log-aaaaaa >/dev/null 2>&1 || exit 1
    write_lock_release >/dev/null 2>&1
  ) || return 1
  [ "$(cat "$victim")" = "$before" ] || { echo "provenance append followed symlink into victim"; return 1; }
  [ -f "$log" ] && [ ! -L "$log" ] || { echo "unsafe provenance symlink was not replaced by a regular log"; return 1; }
  grep -q ' type=dispatch job=task-safe-log-aaaaaa ' "$log" ||
    { echo "safe replacement log omitted dispatch record"; return 1; }
}

t7_orphan_baseline_is_published_before_reclaim_handoff() {
  local repo lock state reclaimer contender_rc
  local generation=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  repo=$(new_repo orphan-handoff)
  lock="$repo/.git/maestro-write.lock"
  state="$TEST_ROOT/orphan-handoff-state"
  mkdir -p "$lock" "$state"
  printf '%s\n' "$generation" > "$lock/generation"
  printf 'token=orphan-token\ngeneration=%s\npid=999999\nprocess_start=dead\njob_id=task-orphan-old\nsession_id=orphan-session\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\ndigest_before=unavailable\n' \
    "$generation" > "$lock/metadata"
  (
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    export MAESTRO_LOCK_WAIT_SEC=0
    write_lock_workspace_writers() { return 0; }
    provenance_log_append() {
      : > "$state/publishing"
      while [ ! -e "$state/allow-publish" ]; do sleep 0.05; done
      return 0
    }
    write_lock_acquire task-orphan-reclaimer >/dev/null 2>&1
    printf '%s\n' "$?" > "$state/reclaimer.rc"
  ) &
  reclaimer=$!
  for _ in $(seq 1 600); do
    [ -e "$state/publishing" ] && break
    sleep 0.05
  done
  [ -e "$state/publishing" ] || { kill "$reclaimer" 2>/dev/null || :; echo "reclaimer never reached baseline publication"; return 1; }
  (
    cd "$repo" || exit 1
    . "$LIB"
    progress_init
    exec 3>/dev/null
    export MAESTRO_LOCK_WAIT_SEC=0
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-handoff-contender >/dev/null 2>&1
    printf '%s\n' "$?"
  ) > "$state/contender.rc"
  contender_rc=$(sed -n '1p' "$state/contender.rc")
  : > "$state/allow-publish"
  wait "$reclaimer" || return 1
  [ "$contender_rc" -eq 11 ] ||
    { echo "contender rc=$contender_rc acquired before orphan baseline publication finished"; return 1; }
  [ "$(cat "$state/reclaimer.rc")" -eq 0 ] || { echo "reclaimer did not acquire after publication"; return 1; }
}

check() {
  local fn="$1" label="$2" detail
  if detail=$("$fn" 2>&1); then ok "$label"; else bad "$label" "${detail:-no detail}"; fi
}

printf '=== Provenance edge verification ===\n'
check t1_clean_filter_cannot_hide_materialized_changes "digest hashes materialized bytes without clean filters"
check t2_linked_worktree_changes_are_isolated "linked worktree changes remain outside this task's provenance"
check t3_untracked_nested_repository_is_observed "untracked nested repositories are observed as materialized roots"
check t4_release_publishes_baseline_before_handoff "baseline publication is serialized with lease handoff"
check t5_digest_does_not_depend_on_shasum "digest remains available without the non-portable shasum utility"
check t6_provenance_append_never_follows_symlink "provenance append cannot write through a symlink"
check t7_orphan_baseline_is_published_before_reclaim_handoff "orphan baseline publication is serialized before lease handoff"
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
