#!/usr/bin/env bash
# Green-phase verification of Plan F, run by the orchestrator as review.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/lib-companion.sh"
LOOP="$ROOT/hooks/implementer-loop.sh"
FAKE="$ROOT/tests/fixtures/fake-companion.mjs"
[ -f "$FAKE" ] || { echo "VERIFY FAIL: missing fixture $FAKE"; exit 1; }
TEST_ROOT=$(mktemp -d /tmp/maestro-planf-green.XXXXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export MAESTRO_LOCK_WAIT_SEC=0

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

ws() { local d="$TEST_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

without_ps_path() {  # dir
  local bin="$1/no-ps"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' > "$bin/ps"
  chmod +x "$bin/ps"
  printf '%s:%s' "$bin" "$PATH"
}

confirmed_ps_path() {  # dir
  local bin="$1/confirmed-ps"
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "Mon Jan  1 00:00:00 2026\\n"\n' > "$bin/ps"
  chmod +x "$bin/ps"
  printf '%s:%s' "$bin" "$PATH"
}

status_running_job() { printf '{\n  "running": [\n    {\n      "id": "%s",\n      "write": %s\n    }\n  ],\n  "latestFinished": null\n}\n' "$1" "$2"; }
status_empty()       { printf '{\n  "running": [],\n  "latestFinished": null\n}\n'; }

run_clear_lease() {  # dir status stale_sec
  local dir="$1" status="$2" stale_sec="$3" clear_home clear_shim companion
  clear_home="$TEST_ROOT/clear-home"
  clear_shim="$TEST_ROOT/clear-shim"
  companion="$clear_home/.claude/plugins/cache/openai-codex/codex/test/scripts/codex-companion.mjs"
  mkdir -p "$clear_shim" "$(dirname "$companion")" || return 1
  ln -sf "$FAKE" "$companion" || return 1
  printf '#!/usr/bin/env bash\nshift\nexport HOME=%q\nexport PATH=%q\nexec node %q "$@"\n' \
    "$HOME" "$PATH" "$FAKE" > "$clear_shim/node" || return 1
  chmod +x "$clear_shim/node" || return 1
  (
    cd "$dir" || exit 1
    env HOME="$clear_home" PATH="$clear_shim:$PATH" \
      MAESTRO_TEST_STATUS="$status" \
      MAESTRO_LOCK_HEARTBEAT_STALE_SEC="$stale_sec" \
      bash "$LOOP" --clear-lease
  )
}

dead_lock() {  # dir job_id
  mkdir -p "$1/.maestro-write.lock"
  printf 'token=old\npid=999999\nprocess_start=dead\njob_id=%s\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\n' \
    "$2" > "$1/.maestro-write.lock/metadata"
}

# ---------------------------------------------------------------- step 2
# Live dispatcher must block WITHOUT querying the companion.
t2() (
  local dir log rc; dir=$(ws live); log="$dir/calls.log"; : > "$log"
  cd "$dir" || exit 1
  . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_CALL_LOG="$log" MAESTRO_TEST_STATUS="$dir/none.json"
  write_lock_acquire task-live0000-aaaaaa >/dev/null   # this shell owns it, pid alive
  # contend from a context that does not inherit the owner token
  unset MAESTRO_LOCK_TOKEN
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ ! -s "$log" ] || { echo "companion WAS queried: $(cat "$log")"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 3
t3() (
  local dir rc; dir=$(ws known_running)
  status_running_job task-fake0000-aaaaaa true > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  local out; out=$(write_lock_acquire 2>&1 >/dev/null); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock was broken"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 4
t4() (
  local dir rc; dir=$(ws known_absent)
  status_empty > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  grep -q 'job_id=task-new00000-cccccc' "$dir/.maestro-write.lock/metadata" || { echo "new owner not recorded"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 5  (MUST PASS)
t5() (
  local dir rc; dir=$(ws unknown_writer)
  status_running_job task-other0000-bbbbbb true > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock was broken — the unknown-id gap is OPEN"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 5b
# unknown id, a running job that is NOT write-capable → safe to break
t5b() (
  local dir rc; dir=$(ws unknown_reader)
  status_running_job task-other0000-bbbbbb false > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0 (read-only job must not hold a write lease)"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 6
t6() (
  local dir rc; dir=$(ws unknown_empty)
  status_empty > "$dir/status.json"
  dead_lock "$dir" unknown
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 7  (MUST PASS)
t7() (
  local dir rc; dir=$(ws broken)
  printf 'BROKEN\n' > "$dir/status.json"
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "broke the lock on UNCERTAIN liveness"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 7b
# companion entirely unreachable (node exits non-zero) → fail closed
t7b() (
  local dir rc; dir=$(ws unreachable)
  dead_lock "$dir" task-fake0000-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  unset MAESTRO_TEST_STATUS   # stub exits 1 with no status file
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "broke the lock when companion unreachable"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 8  (MUST PASS)
t8() (
  local dir; dir=$(ws release_live)
  status_running_job task-fake0000-aaaaaa true > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "released a lease whose job is still running"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 9
t9() (
  local dir; dir=$(ws release_terminal)
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ ! -d "$dir/.maestro-write.lock" ] || { echo "failed to release a terminal lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 9b
t9b() (
  local dir; dir=$(ws release_broken)
  printf 'BROKEN\n' > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-fake0000-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "released on UNCERTAIN liveness"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 10 (MUST PASS)
# Kill a REAL dispatcher process while a job is listed running.
# 10a: killed BEFORE the job id was published (job_id=unknown)
# 10b: killed AFTER  the job id was published
kill_dispatcher_case() (  # $1=dir  $2=job_id_recorded  $3=running_job_id
  local dir="$1" rc
  status_running_job "$3" true > "$dir/status.json"
  # real child acquires the lock, then is killed without running its trap
  env MAESTRO_TEST_STATUS="$dir/status.json" bash -c '
    cd "$1"; set -uo pipefail; . "$2"; companion_resolve() { printf "%s" "$3"; }; progress_init
    write_lock_acquire "$4" >/dev/null 2>&1
    kill -9 $$
  ' _ "$dir" "$LIB" "$FAKE" "$2" >/dev/null 2>&1
  [ -d "$dir/.maestro-write.lock" ] || { echo "lock vanished when dispatcher was hard-killed"; return 1; }
  # a new dispatcher now contends
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  unset MAESTRO_LOCK_TOKEN
  write_lock_acquire >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11 after dispatcher kill"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "successor broke a lease with a live writer"; return 1; }
  return 0
)
t10a() { kill_dispatcher_case "$(ws kill_before)" unknown task-other0000-bbbbbb; }
t10b() { kill_dispatcher_case "$(ws kill_after)" task-fake0000-aaaaaa task-fake0000-aaaaaa; }

# ---------------------------------------------------------------- step 11
# Missing ps must not prevent acquisition; metadata records the recovery gap.
t11() (
  local dir rc; dir=$(ws no_ps_acquire)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(without_ps_path "$dir"); export PATH
  write_lock_acquire task-no-ps000-aaaaaa >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  grep -qx 'process_start=unavailable' "$dir/.maestro-write.lock/metadata" ||
    { echo "process_start=unavailable not recorded"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 12
# A live owner with unconfirmable identity must block rather than be stolen.
t12() (
  local dir owner_pid rc; dir=$(ws no_ps_contention)
  status_empty > "$dir/status.json"
  sleep 30 & owner_pid=$!
  trap 'kill "$owner_pid" 2>/dev/null || :; wait "$owner_pid" 2>/dev/null || :' EXIT
  mkdir -p "$dir/.maestro-write.lock"
  printf 'token=old\npid=%s\nprocess_start=unavailable\njob_id=task-live0000-aaaaaa\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=1\n' \
    "$owner_pid" > "$dir/.maestro-write.lock/metadata"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  PATH=$(without_ps_path "$dir"); export PATH
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$dir/.maestro-write.lock" ] || { echo "live owner's lock was broken"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 13
# A valid session id is recorded and identifies the live owner on contention.
t13() (
  local dir out rc; dir=$(ws session_valid)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-valid_13
  write_lock_acquire task-live0000-aaaaaa >/dev/null 2>&1
  grep -qx 'session_id=session-valid_13' "$dir/.maestro-write.lock/metadata" ||
    { echo "valid session id not recorded"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'session=session-valid_13' ||
    { echo "contention did not identify owner session: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 14
# Invalid environment input is replaced, never copied into metadata.
t14() (
  local dir metadata; dir=$(ws session_invalid)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID='bad id; rm -rf /'
  write_lock_acquire task-invalid0-aaaaaa >/dev/null 2>&1
  metadata="$dir/.maestro-write.lock/metadata"
  grep -qx 'session_id=unknown' "$metadata" ||
    { echo "invalid session id did not record unknown"; return 1; }
  if grep -Fq 'bad' "$metadata" || grep -Fq 'rm -rf' "$metadata"; then
    echo "invalid session id leaked into metadata"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 15
# Publishing a job rewrites metadata without losing the recorded session.
t15() (
  local dir; dir=$(ws session_set_job)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-set_job
  write_lock_acquire >/dev/null 2>&1
  write_lock_set_job task-published-aaaaaa
  grep -qx 'session_id=session-set_job' "$dir/.maestro-write.lock/metadata" ||
    { echo "session id lost while publishing job"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 16
# Completed dispatch provenance carries the originating session.
t16() (
  local dir log; dir=$(ws session_dispatch)
  git -C "$dir" init -q
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_SESSION_ID=session-dispatch
  export MAESTRO_TEST_STATUS="$dir/status.json"
  write_lock_acquire task-session0-aaaaaa >/dev/null 2>&1
  write_lock_release >/dev/null 2>&1
  log="$dir/.git/maestro-provenance.log"
  grep -Eq ' type=dispatch job=task-session0-aaaaaa session=session-dispatch before=[^ ]+ after=[^ ]+$' "$log" ||
    { echo "dispatch provenance missing session"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 17
# Legacy provenance without a session field remains a valid acquisition baseline.
t17() (
  local dir log; dir=$(ws legacy_baseline)
  git -C "$dir" init -q
  log="$dir/.git/maestro-provenance.log"
  printf '2026-01-01T00:00:00Z type=dispatch job=legacy-job before=tree-v2:old after=tree-v2:old\n' > "$log"
  cd "$dir" || exit 1; . "$LIB"; progress_init
  write_lock_acquire task-new00000-cccccc >/dev/null 2>&1
  grep -q ' type=gap prior_job=legacy-job ' "$log" ||
    { echo "legacy provenance was not recognized as a baseline"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 18
# A live owner with confirmed process identity waits until the bounded cap.
t18() (
  local dir out rc started elapsed; dir=$(ws wait_live_confirmed)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-wait_live
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-live-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -ge 2 ] || { echo "elapsed=${elapsed}s want at least 2s"; return 1; }
  printf '%s\n' "$out" |
    grep -q 'waiting for the write lease held by job=task-wait-live-aaaaaa session=session-wait_live' ||
    { echo "wait attribution missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 19
# A zero cap preserves immediate contention and emits no waiting progress.
t19() (
  local dir out rc started elapsed; dir=$(ws wait_disabled)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-wait-off-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=0 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  # date +%s is whole seconds, so a boundary crossing inflates any measurement by 1.
  # -le 1 absorbs that artifact; the "no waiting" invariant is proven exactly by the
  # absence of a wait message below, since every tick prints before it sleeps.
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "zero cap waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 20
# A live owner with unconfirmed process identity is never queueable.
t20() (
  local dir owner_pid out rc started elapsed; dir=$(ws wait_identity_unconfirmed)
  sleep 30 & owner_pid=$!
  trap 'kill "$owner_pid" 2>/dev/null || :; wait "$owner_pid" 2>/dev/null || :' EXIT
  mkdir -p "$dir/.maestro-write.lock"
  printf 'token=old\npid=%s\nprocess_start=unavailable\njob_id=task-unconfirmed-aaaaaa\nsession_id=session-unconfirmed\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$owner_pid" "$(date +%s)" > "$dir/.maestro-write.lock/metadata"
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "identity-unconfirmed owner waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 21
# Poison is human-clearable state, so it must remain an immediate block.
t21() (
  local dir out rc started elapsed; dir=$(ws wait_poisoned)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  write_lock_acquire task-poisoned-aaaaaa >/dev/null 2>&1 || return 1
  write_lock_poison task-poisoned-aaaaaa timeout >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "poisoned lease waited: $out"
    return 1
  fi
  printf '%s\n' "$out" | grep -q -- '--clear-lease' ||
    { echo "clear-lease recovery missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 22
# Undeterminable companion liveness is fail-closed, never queueable.
t22() (
  local dir out rc started elapsed; dir=$(ws wait_liveness_unknown)
  dead_lock "$dir" task-status-fails-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  unset MAESTRO_TEST_STATUS
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  if printf '%s\n' "$out" | grep -q 'waiting for the write lease'; then
    echo "unknown liveness waited: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 23
# Reclassification sees poison staged while a caller is already waiting.
t23() (
  local dir out rc owner_token poison_pid poison_rc started elapsed; dir=$(ws wait_poison_preempts)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_SESSION_ID=session-poison_preempts
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-poison-preempts-aaaaaa >/dev/null 2>&1 || return 1
  owner_token=$MAESTRO_LOCK_TOKEN
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=10 MAESTRO_LOCK_WAIT_POLL_SEC=1
  (
    MAESTRO_LOCK_TOKEN="$owner_token"
    MAESTRO_LOCK_ACQUIRED=1
    sleep 2
    write_lock_poison task-poison-preempts-aaaaaa timeout
  ) &
  poison_pid=$!
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  wait "$poison_pid"; poison_rc=$?
  [ "$poison_rc" -eq 0 ] || { echo "poison staging rc=$poison_rc"; return 1; }
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -lt 5 ] || { echo "elapsed=${elapsed}s poison did not preempt wait"; return 1; }
  printf '%s\n' "$out" | grep -q 'waiting for the write lease' ||
    { echo "no wait occurred before poison: $out"; return 1; }
  printf '%s\n' "$out" | tail -1 | grep -q 'quiescence is unconfirmed.*--clear-lease' ||
    { echo "final poison recovery message missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 24
# An invalid cap warns and fails fast instead of falling back to five minutes.
t24() (
  local dir out rc started elapsed; dir=$(ws wait_invalid_cap)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  write_lock_acquire task-invalid-cap-aaaaaa >/dev/null 2>&1 || return 1
  unset MAESTRO_LOCK_TOKEN
  export MAESTRO_LOCK_WAIT_SEC=abc MAESTRO_LOCK_WAIT_POLL_SEC=1
  started=$(date +%s)
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ "$elapsed" -le 1 ] || { echo "elapsed=${elapsed}s want at most 1s"; return 1; }
  printf '%s\n' "$out" | grep -q 'invalid MAESTRO_LOCK_WAIT_SEC=abc' ||
    { echo "invalid cap warning missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 25
# Waiting does not reset the two-attempt stale-break budget.
t25() (
  local dir out rc breaks; dir=$(ws wait_stale_budget)
  status_empty > "$dir/status.json"
  dead_lock "$dir" task-stale-budget-aaaaaa
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  export MAESTRO_LOCK_WAIT_SEC=2 MAESTRO_LOCK_WAIT_POLL_SEC=1
  out=$(write_lock_acquire task-new-after-stale-aaaaaa 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  breaks=$(printf '%s\n' "$out" | grep -c 'broke stale write lock')
  [ "$breaks" -ge 1 ] || { echo "stale lock was not broken: $out"; return 1; }
  [ "$breaks" -le 2 ] || { echo "stale lock broke $breaks times: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 26
# Malformed metadata is unconfirmed identity, never proof that the owner is dead.
t26() (
  local dir lock out rc; dir=$(ws malformed_metadata)
  lock="$dir/.maestro-write.lock"
  mkdir -p "$lock"
  : > "$lock/metadata"
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  out=$(write_lock_acquire task-malformed-aaaaaa 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$lock" ] && [ ! -s "$lock/metadata" ] ||
    { echo "malformed owner lock was replaced"; return 1; }
  printf '%s\n' "$out" | grep -q 'metadata is malformed.*owner cannot be identified.*failing closed' ||
    { echo "malformed metadata diagnostic missing: $out"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 27
# Identity is published before the digest runs and remains releasable afterward.
t27() (
  local dir metadata identity_before initial_identity current_identity token owner_pid rc
  dir=$(ws identity_before_digest)
  status_empty > "$dir/status.json"
  cd "$dir" || exit 1; . "$LIB"; companion_resolve() { printf '%s' "$FAKE"; }; progress_init
  export MAESTRO_TEST_STATUS="$dir/status.json"
  metadata="$dir/.maestro-write.lock/metadata"
  identity_before="$dir/identity-before-digest"
  repo_digest() {
    local recorded_token recorded_pid
    [ -f "$metadata" ] || return 1
    recorded_token=$(write_lock_metadata_value "$metadata" token)
    recorded_pid=$(write_lock_metadata_value "$metadata" pid)
    [ "${MAESTRO_LOCK_ACQUIRED:-0}" -eq 1 ] &&
      [ -n "${MAESTRO_LOCK_TOKEN:-}" ] &&
      [ "$recorded_token" = "$MAESTRO_LOCK_TOKEN" ] &&
      [ "$recorded_pid" = "$$" ] || return 1
    sed -n '1,7p' "$metadata" > "$identity_before" || return 1
    printf 'tree-v2:identity-published\n'
  }
  write_lock_acquire task-published-first-aaaaaa >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0"; return 1; }
  [ -f "$metadata" ] || { echo "metadata was not published"; return 1; }
  token=$(write_lock_metadata_value "$metadata" token)
  owner_pid=$(write_lock_metadata_value "$metadata" pid)
  [ -n "$token" ] && [ "$token" = "$MAESTRO_LOCK_TOKEN" ] ||
    { echo "published token does not identify the owner"; return 1; }
  initial_identity=$(sed -n '1,7p' "$identity_before")
  current_identity=$(sed -n '1,7p' "$metadata")
  [ "$initial_identity" = "$current_identity" ] ||
    { echo "owner identity changed during digest publication"; return 1; }
  case "$owner_pid" in
    ''|*[!0-9]*) echo "published pid is not numeric: $owner_pid"; return 1 ;;
  esac
  [ "$owner_pid" = "$$" ] || { echo "pid=$owner_pid want $$"; return 1; }
  grep -qx 'digest_before=tree-v2:identity-published' "$metadata" ||
    { echo "digest ran before identity publication"; return 1; }
  write_lock_release >/dev/null 2>&1
  [ ! -d "$dir/.maestro-write.lock" ] ||
    { echo "published owner could not release its lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 28
# Absent metadata remains the distinct initializing-owner state.
t28() (
  local dir lock out rc; dir=$(ws absent_metadata)
  lock="$dir/.maestro-write.lock"
  mkdir -p "$lock"
  cd "$dir" || exit 1; . "$LIB"; progress_init
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  [ -d "$lock" ] || { echo "initializing owner lock was removed"; return 1; }
  printf '%s\n' "$out" | grep -q 'blocked by an initializing owner' ||
    { echo "initializing-owner diagnostic missing: $out"; return 1; }
  if printf '%s\n' "$out" | grep -q 'metadata is malformed'; then
    echo "absent metadata was reported as malformed: $out"
    return 1
  fi
  return 0
)

# ---------------------------------------------------------------- step 29
# A current owner's heartbeat is visible as fresh and never changes its token.
t29() (
  local dir lock heartbeat owner_token recorded_token out rc; dir=$(ws heartbeat_fresh)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  export MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=1
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=3
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-heartbeat-fresh-aaaaaa >/dev/null 2>&1 || return 1
  lock="$dir/.maestro-write.lock"
  heartbeat="$lock/heartbeat"
  owner_token=$MAESTRO_LOCK_TOKEN
  write_lock_heartbeat_write || { echo "heartbeat write failed"; return 1; }
  [ "$(wc -l < "$heartbeat")" -eq 2 ] ||
    { echo "heartbeat did not contain exactly two lines"; return 1; }
  grep -qx "token=$owner_token" "$heartbeat" ||
    { echo "heartbeat token missing"; return 1; }
  write_lock_heartbeat_epoch "$lock" "$owner_token" | grep -Eq '^[0-9]+$' ||
    { echo "heartbeat epoch missing"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is fresh (last tick [0-9][0-9]*s ago)' ||
    { echo "fresh heartbeat diagnostic missing: $out"; return 1; }
  recorded_token=$(write_lock_metadata_value "$lock/metadata" token)
  [ "$recorded_token" = "$owner_token" ] ||
    { echo "owner token changed from $owner_token to $recorded_token"; return 1; }
  MAESTRO_LOCK_TOKEN=$owner_token
  MAESTRO_LOCK_ACQUIRED=1
  write_lock_release >/dev/null 2>&1
  [ ! -d "$lock" ] || { echo "heartbeat prevented normal release"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 30
# A stopped owner becomes diagnostically stale, but the contender never reclaims it.
t30() (
  local dir lock stop owner_out owner_pid owner_token before out rc owner_rc
  dir=$(ws heartbeat_stale_no_reclaim)
  lock="$dir/.maestro-write.lock"
  stop="$dir/stop-owner"
  owner_out="$dir/owner.out"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  bash -c '
    cd "$1" || exit 1
    . "$2"; progress_init
    export MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC=1
    write_lock_workspace_writers() { return 0; }
    write_lock_acquire task-heartbeat-stale-aaaaaa >/dev/null 2>&1 || exit 1
    write_lock_heartbeat_write || exit 1
    printf "%s\n" "$MAESTRO_LOCK_TOKEN" > "$1/owner.token"
    while [ ! -e "$3" ]; do
      sleep 1
      write_lock_heartbeat_write || exit 1
    done
    write_lock_is_owner || exit 2
    printf "owner-still-owns\n"
    write_lock_release || exit 3
    [ ! -d "$4" ] || exit 4
    printf "owner-released\n"
  ' _ "$dir" "$LIB" "$stop" "$lock" > "$owner_out" 2>&1 &
  owner_pid=$!
  stale_owner_cleanup() {
    [ -n "$owner_pid" ] || return 0
    : > "$stop"
    kill -CONT "$owner_pid" 2>/dev/null || :
    wait "$owner_pid" 2>/dev/null || :
  }
  trap stale_owner_cleanup EXIT
  for _ in 1 2 3 4 5; do
    [ -s "$dir/owner.token" ] && [ -f "$lock/heartbeat" ] && break
    sleep 1
  done
  [ -s "$dir/owner.token" ] && [ -f "$lock/heartbeat" ] ||
    { echo "owner did not publish heartbeat"; return 1; }
  owner_token=$(sed -n '1p' "$dir/owner.token")
  before="$dir/metadata.before"
  cp "$lock/metadata" "$before" || return 1
  kill -STOP "$owner_pid" || return 1
  sleep 3
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_WAIT_SEC=1 MAESTRO_LOCK_WAIT_POLL_SEC=1
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is stale .*owner may be wedged' ||
    { echo "stale heartbeat diagnostic missing: $out"; return 1; }
  [ -d "$lock" ] || { echo "stale heartbeat was reclaimed"; return 1; }
  cmp -s "$before" "$lock/metadata" ||
    { echo "contender changed lease metadata"; return 1; }
  [ "$(write_lock_metadata_value "$lock/metadata" token)" = "$owner_token" ] ||
    { echo "contender changed lease token"; return 1; }
  : > "$stop"
  kill -CONT "$owner_pid" || return 1
  wait "$owner_pid"; owner_rc=$?
  owner_pid=""
  [ "$owner_rc" -eq 0 ] || { echo "resumed owner rc=$owner_rc: $(cat "$owner_out")"; return 1; }
  grep -qx 'owner-still-owns' "$owner_out" &&
    grep -qx 'owner-released' "$owner_out" ||
    { echo "resumed owner did not retain and release lease: $(cat "$owner_out")"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 31
# Before the first tick, a young lease uses started_epoch as its freshness floor.
t31() (
  local dir lock owner_token out rc; dir=$(ws heartbeat_absent_young)
  cd "$dir" || exit 1; . "$LIB"; progress_init
  PATH=$(confirmed_ps_path "$dir"); export PATH
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=3
  write_lock_workspace_writers() { return 0; }
  write_lock_acquire task-heartbeat-young-aaaaaa >/dev/null 2>&1 || return 1
  lock="$dir/.maestro-write.lock"
  owner_token=$MAESTRO_LOCK_TOKEN
  rm -f "$lock/heartbeat"
  [ ! -e "$lock/heartbeat" ] || { echo "young lease unexpectedly ticked"; return 1; }
  unset MAESTRO_LOCK_TOKEN
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  printf '%s\n' "$out" | grep -q 'heartbeat is fresh (last tick [0-9][0-9]*s ago)' ||
    { echo "started_epoch freshness floor missing: $out"; return 1; }
  MAESTRO_LOCK_TOKEN=$owner_token
  MAESTRO_LOCK_ACQUIRED=1
  write_lock_release >/dev/null 2>&1
  return 0
)

# ---------------------------------------------------------------- step 32
# A stale heartbeat never bypasses the write-capable-job gate.
t32() (
  local dir lock status out rc now; dir=$(ws clear_stale_writer)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  mkdir -p "$lock"
  printf 'token=stale-writer\npid=%s\nprocess_start=old\njob_id=task-stale-writer\nsession_id=session-stale-writer\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$$" "$((now - 5))" > "$lock/metadata"
  printf 'token=stale-writer\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  status_running_job task-running-writer true > "$status"
  out=$(run_clear_lease "$dir" "$status" 1 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -q 'refusing to clear.*write-capable job is still running.*task-running-writer' <<< "$out" ||
    { echo "writer gate diagnostic missing: $out"; return 1; }
  [ -d "$lock" ] && [ -f "$lock/metadata" ] && [ -f "$lock/heartbeat" ] ||
    { echo "writer gate did not preserve stale lease"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 33
# With no write-capable job, an operator may clear a stale-heartbeat lease.
t33() (
  local dir lock status out rc now; dir=$(ws clear_stale_empty)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  mkdir -p "$lock"
  printf 'token=stale-empty\npid=%s\nprocess_start=old\njob_id=task-stale-empty\nsession_id=session-stale-empty\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$$" "$((now - 5))" > "$lock/metadata"
  printf 'token=stale-empty\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  status_empty > "$status"
  out=$(run_clear_lease "$dir" "$status" 1 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "rc=$rc want 0: $out"; return 1; }
  grep -q 'clearing a write lease whose heartbeat went stale.*job=task-stale-empty.*session=session-stale-empty.*last_heartbeat=[0-9][0-9]*s ago' <<< "$out" ||
    { echo "stale clear diagnostic missing: $out"; return 1; }
  grep -q 'MAESTRO_FINAL: LOOP CLEARED rc=0' <<< "$out" ||
    { echo "clear result missing: $out"; return 1; }
  [ ! -d "$lock" ] && [ ! -e "$lock/metadata" ] && [ ! -e "$lock/heartbeat" ] ||
    { echo "stale lease entries survived clear"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 34
# A fresh heartbeat remains outside --clear-lease eligibility.
t34() (
  local dir lock status out rc now; dir=$(ws clear_fresh)
  lock="$dir/.maestro-write.lock"
  status="$dir/status.json"
  now=$(date +%s)
  mkdir -p "$lock"
  printf 'token=fresh-clear\npid=%s\nprocess_start=current\njob_id=task-fresh-clear\nsession_id=session-fresh-clear\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$$" "$now" > "$lock/metadata"
  printf 'token=fresh-clear\nepoch=%s\n' "$now" > "$lock/heartbeat"
  status_empty > "$status"
  out=$(run_clear_lease "$dir" "$status" 10 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  grep -q 'refusing to clear.*write lease is healthy.*heartbeat [0-9][0-9]*s old' <<< "$out" ||
    { echo "fresh clear refusal omitted heartbeat age: $out"; return 1; }
  [ -d "$lock" ] && [ -f "$lock/metadata" ] && [ -f "$lock/heartbeat" ] ||
    { echo "fresh heartbeat lease was removed"; return 1; }
  return 0
)

# ---------------------------------------------------------------- step 35
# A zero stale threshold restores the pre-heartbeat contention message.
t35() (
  local dir lock stop owner_pid out rc now; dir=$(ws heartbeat_reporting_disabled)
  lock="$dir/.maestro-write.lock"
  stop="$dir/stop-owner"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  (
    while [ ! -e "$stop" ]; do sleep 1; done
  ) &
  owner_pid=$!
  disabled_owner_cleanup() {
    [ -n "$owner_pid" ] || return 0
    : > "$stop"
    kill -CONT "$owner_pid" 2>/dev/null || :
    wait "$owner_pid" 2>/dev/null || :
  }
  trap disabled_owner_cleanup EXIT
  now=$(date +%s)
  mkdir -p "$lock"
  printf 'token=disabled\npid=%s\nprocess_start=Mon Jan  1 00:00:00 2026\njob_id=task-disabled\nsession_id=session-disabled\nstarted_at=2026-01-01T00:00:00Z\nstarted_epoch=%s\ndigest_before=unavailable\n' \
    "$owner_pid" "$((now - 5))" > "$lock/metadata"
  printf 'token=disabled\nepoch=%s\n' "$((now - 5))" > "$lock/heartbeat"
  kill -STOP "$owner_pid" || return 1
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=0
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  if grep -Eq 'heartbeat is (fresh|stale)' <<< "$out"; then
    echo "disabled heartbeat reporting changed message: $out"
    return 1
  fi
  grep -q 'write dispatch blocked; held by job=task-disabled.*for [0-9][0-9]*s' <<< "$out" ||
    { echo "pre-heartbeat contention message missing: $out"; return 1; }
  : > "$stop"
  kill -CONT "$owner_pid" || return 1
  wait "$owner_pid" || return 1
  owner_pid=""
  return 0
)

# ---------------------------------------------------------------- step 36
# Unknown lease age never becomes a heartbeat-staleness claim.
t36() (
  local dir lock out rc; dir=$(ws heartbeat_unknown_age)
  lock="$dir/.maestro-write.lock"
  PATH=$(confirmed_ps_path "$dir"); export PATH
  mkdir -p "$lock"
  printf 'token=unknown-age\npid=%s\nprocess_start=Mon Jan  1 00:00:00 2026\njob_id=task-unknown-age\nsession_id=session-unknown-age\nstarted_at=unknown\nstarted_epoch=not-a-number\ndigest_before=unavailable\n' \
    "$$" > "$lock/metadata"
  printf 'token=unknown-age\nepoch=1\n' > "$lock/heartbeat"
  cd "$dir" || exit 1; . "$LIB"; progress_init
  export MAESTRO_LOCK_HEARTBEAT_STALE_SEC=1
  out=$(write_lock_acquire 3>&1 >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 11 ] || { echo "rc=$rc want 11"; return 1; }
  if grep -Eq 'heartbeat is (fresh|stale)' <<< "$out"; then
    echo "unknown age was reported as heartbeat staleness: $out"
    return 1
  fi
  grep -q 'for unknown' <<< "$out" ||
    { echo "unknown held age missing: $out"; return 1; }
  return 0
)

printf '=== Plan F green-phase verification ===\n'
for t in t2 t3 t4 t5 t5b t6 t7 t7b t8 t9 t9b t10a t10b t11 t12 t13 t14 t15 t16 t17 \
  t18 t19 t20 t21 t22 t23 t24 t25 t26 t27 t28 t29 t30 t31 t32 t33 t34 t35 t36; do
  msg=$($t 2>&1) && ok "$t" || bad "$t" "${msg:-no detail}"
done
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
