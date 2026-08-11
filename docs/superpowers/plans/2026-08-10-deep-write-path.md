# Deep Write Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Maestro's shallow shared lifecycle plumbing with four deep modules while preserving every observable command contract and safety invariant.

**Architecture:** `lib-process.sh` owns bounded process groups; narrowed `lib-companion.sh` owns companion transport/polling; `lib-write-lease.sh` owns one run-scoped Lease interval and durable Cancellation facts; `lib-write-turn.sh` owns one complete Write turn. Loop and watchdog become peer adapters. Verification and Discussion turns remain internal to their single callers.

**Tech Stack:** Portable Bash 3.2, Node.js standard library, Git, existing shell integration harness, existing fake companion adapter.

## Global Constraints

- Preserve CLIs, exits, progress/final markers, retry caps, timeout defaults, one-writer rules, poison/quiescence behavior, provenance order, and installer byte identity.
- One Implementation run acquires one Lease interval; no Write turn acquires or releases.
- Exit code plus caller-owned result/evidence files are the only supported outcome interface.
- Portable Bash 3.2; no new dependencies or GNU-only commands.
- Clean cutover: migrate every caller and delete old implementations in the same task; no aliases, shims, dual record formats, or inherited-token fallback.
- Tests use real processes, repositories, durable files, and the existing fake companion. Do not replace race tests with mocks.
- No commits are created unless the user separately requests repository history changes.

---

### Task 1: Freeze the peer-adapter contract

**Files:**
- Modify: `tests/stop-report.sh`
- Modify: `tests/liveness.sh`
- Modify: `tests/install.sh`

**Interfaces:**
- Consumes: current public loop/watchdog/install behavior.
- Produces: behavior tests that survive the internal cutover.

- [x] **Step 1: Add a characterization proving one loop run owns one lease across two Write turns**

Use the existing fake companion call log and a two-iteration DONE-then-verification-fail scenario. Assert one acquisition generation/token is observed throughout, two `task --write` starts occur, and no second acquisition/reclaim marker appears. The production mutation caught is reacquiring per Write turn.

- [x] **Step 2: Add exact public mapping cases**

Exercise watchdog `0/10/11/4/125` and loop `0/10/11/12/3` paths through existing entry points. Assert observable final marker and exit, not implementation text. The production mutations caught are swapped adapter mappings and redispatch after cancellation.

- [x] **Step 3: Extend installer identity expectations for the planned libraries before creating them**

Add expected managed paths for `lib-process.sh`, `lib-write-lease.sh`, and `lib-write-turn.sh`; assert install owns them, byte-identical reinstall preserves inode/mtime, divergent bytes refuse overwrite, and modified installed bytes survive uninstall. This must fail because the source/manifest entries do not exist yet.

- [x] **Step 4: Run RED checks**

```bash
bash tests/stop-report.sh
bash tests/liveness.sh
bash tests/install.sh
```

Expected: new lease-interval characterization may expose current watchdog nesting details; installer suite fails specifically because the three new managed libraries are absent.

---

### Task 2: Deepen bounded process supervision

**Files:**
- Create: `hooks/lib-process.sh`
- Modify: `hooks/lib-companion.sh`
- Modify: `hooks/implementer-loop.sh`
- Modify: `hooks/discussion-loop.sh`
- Modify: `tests/bounded-calls.sh`
- Modify: `tests/runner-timeout.sh`

**Interfaces:**
- Produces:

```bash
process_run_bounded TIMEOUT LABEL TICK_FN STDOUT_FILE STDERR_FILE -- COMMAND [ARG...]
process_interrupt SIGNAL EVIDENCE_FILE
progress_init
progress MESSAGE...
```

- [x] **Step 1: Add process-interface tests**

Exercise exact wrapped rc, separate stdout/stderr files, sub-second completion without a one-second floor, timeout rc, TERM-to-KILL escalation, descendant-group absence after timeout, tick callback invocation, and idempotent interrupt. The production mutations caught are leader-only kill, output mixing, lost rc, and heartbeat starvation.

- [x] **Step 2: Run the focused suite RED**

```bash
bash tests/bounded-calls.sh
```

Expected: fail because `hooks/lib-process.sh` or `process_run_bounded` is missing.

- [x] **Step 3: Move process implementation**

Move progress FD setup and `run_bounded` mechanics out of `lib-companion.sh`. Use caller-owned output files. Keep job-control process groups, deadline accounting, five-second TERM grace, KILL fallback, wait/reap, and function callback validation without `eval`. Store active process state only inside the sourced process module.

- [x] **Step 4: Migrate current bounded calls and Verification transaction supervision**

Adapt companion command calls to consume output files. Replace loop-local PID/group termination with `process_interrupt`. Keep verifier descendant cleanup stricter than ordinary companion calls: the Verification transaction must prove the group absent even when the leader exits `0`.

- [x] **Step 5: Delete old process paths**

Remove old `run_bounded`, duplicate progress helpers, `terminate_process_group`, and adapter PID outcome state. Do not leave forwarding names.

- [x] **Step 6: Run GREEN checks**

```bash
bash tests/bounded-calls.sh
bash tests/runner-timeout.sh
bash tests/liveness.sh
```

Expected: all pass; process-leak checks report no descendants.

---

### Task 3: Deepen the Lease interval module

**Files:**
- Create: `hooks/lib-write-lease.sh`
- Modify: `hooks/lib-companion.sh`
- Modify: `hooks/implementer-loop.sh`
- Modify: `hooks/implementer-watchdog.sh`
- Modify: `tests/lease.sh`
- Modify: `tests/provenance-edge.sh`
- Modify: `tests/orphan-lifecycle.sh`
- Modify: `tests/shared-git-dir.sh`
- Modify: `tests/commit-invariance.sh`
- Modify: `tests/manual-check-and-submodules.sh`

**Interfaces:**
- Consumes: `process_run_bounded`, repository-global companion writer observation.
- Produces:

```bash
write_lease_begin EVIDENCE_FILE
write_lease_end EVIDENCE_FILE
write_lease_clear RESULT_FILE EVIDENCE_FILE
provenance_check
repo_digest
_write_lease_turn_event EVENT JOB REASON RESULT_FILE EVIDENCE_FILE
```

- [x] **Step 1: Convert one acquisition/release test to the new interface**

Source `lib-write-lease.sh`, begin one Lease interval, assert durable metadata exists and token remains stable, end it, and assert provenance published before the lock becomes available. The production mutations caught are per-turn acquisition, missing token fence, and release-before-provenance.

- [x] **Step 2: Run that lease test RED**

```bash
bash tests/lease.sh
```

Expected: fail because the new library/interface is missing.

- [x] **Step 3: Move digest, identity, lease, poison, provenance, and clear implementation**

Preserve metadata-first acquisition, atomic metadata publication, initialization grace, bounded unordered wait, live/unknown fail-closed classification, global writer checks, exact-generation `.reclaim`, two-attempt cap, heartbeat throttling, no-follow provenance append, orphan adoption, and materialized-byte digest behavior.

- [x] **Step 4: Implement the private lifecycle event seam**

`guard` rechecks exact ownership; `started` publishes validated `task-*`; `tick` refreshes heartbeat; `cancel-begin` writes a complete generation-bound `metadata.new` before cancellation; `cancel-end` promotes after the attempt; `current-job` writes the durable job to a caller-owned result file. Any staging/promotion uncertainty retains poison. No event communicates outcome through `MAESTRO_CANCEL_*`.

- [x] **Step 5: Move operator clear from the loop**

`write_lease_clear` must preserve `0/11/3`, refuse live/unconfirmed owners and every visible/unknown writer state, distinguish absent from cleared in the result file, and remove only a proven-safe exact generation.

- [x] **Step 6: Migrate all lease/provenance tests without weakening races**

Retain concurrent contenders, malformed metadata, metadata-less initialization, PID reuse/timezone, stale heartbeat, late poison, poisoned wait, ABA generation changes, global writer uncertainty, symlink log refusal, shared common-git-dir scope, submodules, materialized bytes, orphan handoff, and commit invariance. Replace only calls to old public symbols/outcome globals.

- [x] **Step 7: Delete lease code from `lib-companion.sh` and adapters**

Remove every old `write_lock_*`, `repo_digest*`, provenance implementation, inline clear path, and adapter reads of lease metadata/outcome globals. No aliases.

- [x] **Step 8: Run GREEN checks**

```bash
bash tests/lease.sh
bash tests/provenance-edge.sh
bash tests/orphan-lifecycle.sh
bash tests/shared-git-dir.sh
bash tests/commit-invariance.sh
bash tests/manual-check-and-submodules.sh
```

Expected: all pass with existing race and durable-file coverage intact.

---

### Task 4: Narrow companion transport and deepen Write turns

**Files:**
- Create: `hooks/lib-write-turn.sh`
- Modify: `hooks/lib-companion.sh`
- Modify: `hooks/implementer-watchdog.sh`
- Modify: `hooks/implementer-loop.sh`
- Modify: `tests/preflight.sh`
- Modify: `tests/bounded-calls.sh`
- Modify: `tests/liveness.sh`
- Modify: `tests/stop-report.sh`

**Interfaces:**
- Companion produces:

```bash
companion_turn MODE PROMPT_FILE MAX_IDLE POLL RESULT_FILE PROFILE_FILE EVIDENCE_FILE LIFECYCLE_FN
companion_interrupt SIGNAL JOB_OR_EMPTY EVIDENCE_FILE LIFECYCLE_FN
companion_writers RESULT_FILE EVIDENCE_FILE
```

- Write turn produces:

```bash
write_turn_run PLAN_FILE MAX_IDLE POLL RESULT_FILE EVIDENCE_FILE
write_turn_interrupt SIGNAL RESULT_FILE EVIDENCE_FILE
```

- [x] **Step 1: Add Write-turn interface tests**

Through the fake companion, assert DONE/NEEDS_ANSWERS/BLOCKED/FAILED/missing result mappings, last anchored full-line `RESULT:` precedence, no blind retry, launch-publication generation fence, Cancellation fact before cancel, observed cancellation without redundant cancel, deadline terminal harvest, four-strike status loss, idle elapsed-time behavior, midpoint warning, startup in hard budget, and raw evidence preservation. The production mutations caught are incorrect ordering, prefix parsing, redispatch, and read/write cancellation confusion.

- [x] **Step 2: Run focused tests RED**

```bash
bash tests/preflight.sh
bash tests/liveness.sh
bash tests/stop-report.sh
```

Expected: fail because `lib-write-turn.sh`/new interface is absent or the loop still nests the watchdog.

- [x] **Step 3: Narrow companion implementation**

Keep discovery, semantic-version selection, pin loading/effort validation, write-flag synopsis preflight, task launch, pin verification, normalized status, hard/idle budgeting, clipped sleeps/calls, four consecutive malformed statuses, result second fetch, cancel transport, and global writer parsing. Require explicit `read|write`; remove inherited-token mode inference and all lease metadata access.

- [x] **Step 4: Implement the Write turn module**

Move the Implementer Contract verbatim. Build a private prompt file, supply the lease lifecycle adapter, guard immediately before launch, publish the job before polling, classify the last valid full-line result, and write exact raw reply/evidence files. Return `0/10/11/3/4/125` as designed. On any write cancellation path, stage Cancellation fact, issue at most one cancel, promote/retain poison, emit existing recovery text, and never retry.

- [x] **Step 5: Implement unified signal handling**

`write_turn_interrupt` first calls `process_interrupt`, recovers the durable/current job or performs one bounded global writer query, stages signal reason, cancels only a known target, retains the Lease interval, and returns `125`. Preserve pre-job unknown recovery and do not cancel after failed poison staging.

- [x] **Step 6: Convert watchdog to a thin peer adapter**

Retain its inline/`--file` CLI and positional bounds. Begin one Lease interval, call one Write turn, relay files, end/retain, emit exact `IMPLEMENTER_STATE`/`MAESTRO_FINAL`, and preserve public `125`.

- [x] **Step 7: Convert loop to direct Write turns**

Remove `WATCHDOG`, `WATCHDOG_PID`, subprocess launch/capture, and duplicate result parsing/cancellation. Begin once before iteration, call `write_turn_run` directly, keep evidence-fed retries and stop history, run the internal Verification transaction after DONE, map Write-turn `125` to BLOCKED/`11`, and end/retain once.

- [x] **Step 8: Delete old transport and lifecycle paths**

Remove old public start/status/poll/result/cancel wrappers not used by the three supported companion entries, adapter cancellation globals, and duplicate implementer contract. No forwarding functions.

- [x] **Step 9: Run GREEN checks**

```bash
bash tests/preflight.sh
bash tests/bounded-calls.sh
bash tests/liveness.sh
bash tests/stop-report.sh
```

Expected: all pass; loop call log shows direct peer-adapter behavior and no redispatch after poison.

---

### Task 5: Make Discussion and Verification transactions explicit

**Files:**
- Modify: `hooks/discussion-loop.sh`
- Modify: `hooks/implementer-loop.sh`
- Modify: `tests/discussion.sh`
- Modify: `tests/liveness.sh`

**Interfaces:**
- Consumes: `companion_turn read`, `process_run_bounded`, Write turn/Lease interval internals only in the Implementation-run adapter.
- Produces: private `discussion_turn_run` and `verification_transaction_run` functions; no new sourced seam.

- [x] **Step 1: Add/retain Discussion transaction behavior tests**

Assert append-before-start, exact rollback after orphaned awaiting state, configured status-loss retry count, no retry for idle/deadline, reply publication before clearing `awaiting_reply`, last full-line terminal marker, round cap, signal recovery, and absence of any write Lease interval. The production mutations caught are partial transcript commits and read-mode poison.

- [x] **Step 2: Add/retain Verification transaction behavior tests**

Assert verifier runs only after DONE, receives no lease capability, full process group is absent after success/failure/timeout, timeout evidence reaches the next Write turn, failed proof redispatches within the same Lease interval, ownership loss blocks, and signal retains the lease conservatively.

- [x] **Step 3: Run RED checks if new assertions expose missing locality**

```bash
bash tests/discussion.sh
bash tests/liveness.sh
```

Expected: any new direct-module assumptions fail before the private transaction functions replace top-level interleaving.

- [x] **Step 4: Co-locate each transaction without extracting a shallow library**

Move transcript append/state/start/retry/result/persist into private `discussion_turn_run`. Move verifier launch/reap/evidence/ownership check into private `verification_transaction_run`. Keep public CLI parsing/final marker mapping outside each function.

- [x] **Step 5: Run GREEN checks**

```bash
bash tests/discussion.sh
bash tests/liveness.sh
bash tests/stop-report.sh
```

Expected: all pass; read-only paths create no lease/poison and Verification transactions stay inside one run-owned interval.

---

### Task 6: Publish managed modules and remove obsolete paths

**Files:**
- Modify: `install.mjs`
- Modify: `uninstall.mjs`
- Modify: `tests/install.sh`
- Modify: `tests/run.sh`
- Modify: `README.md`
- Modify: `rules/orchestrator-implementer.md` only where internal topology text is stale
- Modify: `CONTEXT.md`
- Modify: `tasks/todo.md`

**Interfaces:**
- Consumes: final four-library topology.
- Produces: symmetric install/uninstall ownership and accurate operator documentation.

- [x] **Step 1: Add the three libraries to managed hook lists**

Add `lib-process.sh`, `lib-write-lease.sh`, and `lib-write-turn.sh` to both installer and uninstaller known-file lists. Do not add them to executable hooks or settings registration. Keep manifest schema and validate-before-mutate transaction unchanged.

- [x] **Step 2: Complete installer tests**

Make the Task 1 RED cases green: all libraries install with source bytes, identical reinstall preserves identity, late failure rolls all files back, divergent installed bytes refuse overwrite, and uninstall removes only manifest-matching bytes.

- [x] **Step 3: Update runtime documentation**

Replace the single shared-library row with four deep modules and describe loop/watchdog as peer adapters. Preserve public invocation/exit tables. Use the approved domain terms exactly: Implementation run, Write turn, Lease interval, Cancellation fact, Verification transaction, Discussion turn.

- [x] **Step 4: Remove obsolete symbols and test-only coupling**

Search changed runtime/tests for old `write_lock_*`, `MAESTRO_CANCEL_*`, adapter-visible `MAESTRO_LOCK_*`, loop watchdog spawn, and deleted companion polling entries. Every remaining match must be an intentional environment-isolation assertion or historical documentation; otherwise migrate/delete it.

- [x] **Step 5: Run focused installer checks**

```bash
node --check install.mjs
node --check uninstall.mjs
bash tests/install.sh
```

Expected: syntax passes and installer suite is green.

---

### Task 7: Verify the complete clean cutover

**Files:**
- Review all changed artifacts.
- Update: `tasks/todo.md` review section.

**Interfaces:**
- Consumes: all prior task deliverables.
- Produces: end-to-end evidence for completion.

- [x] **Step 1: Run shell and Node syntax checks**

```bash
for file in hooks/*.sh tests/*.sh; do bash -n "$file" || exit; done
node --check install.mjs
node --check uninstall.mjs
```

Expected: zero failures.

- [x] **Step 2: Run the complete integration suite**

```bash
bash tests/run.sh
```

Expected: every suite passes with zero failures.

- [x] **Step 3: Smoke test installed entry points in an isolated HOME**

Install into a temporary HOME, run standalone watchdog and bounded loop against the fake companion, run one Discussion turn, reinstall and confirm byte identity through the installer suite, then uninstall. Assert exact final markers/exits and no surviving process group or lock on safe completion.

- [x] **Step 4: Review architecture invariants**

Confirm one acquire/end per Implementation run, no Write-turn acquisition, poison-before-cancel, no redispatch after cancellation, explicit read mode, generation rechecks, provenance-before-handoff, no watchdog nesting, and no compatibility shims.

- [x] **Step 5: Record review evidence**

Append exact commands/results, changed topology, deviations, and any external blocker to `tasks/todo.md`. Do not claim unrun checks.
