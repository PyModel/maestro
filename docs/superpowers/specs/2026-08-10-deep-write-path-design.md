# Deep Write Path Design

**Date:** 2026-08-10
**Status:** Approved by blanket acceptance of recommended decisions

## Goal

Deepen Maestro's safety-critical write path without changing observable behavior. The loop and watchdog become peer adapters over one Write turn module; one Implementation run owns one Lease interval across every Write turn and Verification transaction.

## Constraints

- Preserve every CLI, exit code, progress/final marker, retry cap, timeout default, one-writer rule, Cancellation fact rule, provenance ordering, installer ownership rule, and existing durable recovery behavior.
- Portable macOS Bash 3.2. No associative arrays, namerefs, `mapfile`, `wait -n`, GNU `timeout`, or new dependencies.
- Exit code plus caller-owned result/evidence files are the only supported outcome interface. Environment remains configuration only.
- Keep both entry adapters. Delete loop-to-watchdog nesting.
- Clean cutover: no aliases, dual record formats, inherited-token fallback, or deprecated paths.
- Tests retain real Git repositories, processes, races, durable files, and the fake companion transport adapter.

## Architecture

### `hooks/lib-process.sh`

Own bounded local process groups, timeout clipping, TERM/grace/KILL, descendant reaping, progress FD setup, and interrupting the currently active local group.

Supported interface:

```bash
process_run_bounded TIMEOUT LABEL TICK_FN STDOUT_FILE STDERR_FILE -- COMMAND [ARG...]
process_interrupt SIGNAL EVIDENCE_FILE
progress_init
progress MESSAGE...
```

The tick function is `:` or a validated Bash function name. It lets a caller refresh the Lease interval without teaching the process module about lease metadata. No known child group may survive a timeout or an `always-reap` Verification transaction.

### Narrowed `hooks/lib-companion.sh`

Own companion discovery, model pinning, `--write` compatibility preflight, task start, pin verification, normalized status polling, hard/idle budgets, four-strike status loss, result retrieval, cancellation transport, and repository-global writer observation. JSON and plugin command details remain behind this seam.

Supported interface:

```bash
companion_turn MODE PROMPT_FILE MAX_IDLE POLL RESULT_FILE PROFILE_FILE EVIDENCE_FILE LIFECYCLE_FN
companion_interrupt SIGNAL JOB_OR_EMPTY EVIDENCE_FILE LIFECYCLE_FN
companion_writers RESULT_FILE EVIDENCE_FILE
```

`MODE` is explicit `read` or `write`; inherited lease state never selects behavior. `LIFECYCLE_FN` is `:` for read-only work or the private Write turn adapter. Lifecycle events are `guard`, `started`, `tick`, `cancel-begin`, `cancel-end`, and `current-job`. The write lifecycle must establish the Cancellation fact before external cancellation. Read status loss retains its configured Discussion turn retry behavior; read idle/deadline remains terminal `124`.

### `hooks/lib-write-lease.sh`

Own the complete Lease interval implementation: repository scope, materialized-byte digest, process identity, acquisition/wait/reclaim, metadata/heartbeat, generation fencing, Cancellation fact, release, operator clear, provenance, orphan adoption, and global writer checks.

Supported interface:

```bash
write_lease_begin EVIDENCE_FILE
write_lease_end EVIDENCE_FILE
write_lease_clear RESULT_FILE EVIDENCE_FILE
provenance_check
repo_digest
```

Private collaboration interface:

```bash
_write_lease_turn_event EVENT JOB REASON RESULT_FILE EVIDENCE_FILE
```

One adapter call to `write_lease_begin` starts one Lease interval. A Write turn never acquires or releases it. Private module state may identify the current generation inside the shell, but no adapter consumes outcome globals. Every durable mutation rechecks the current token. Cancellation ordering stays: stage complete `metadata.new`, attempt cancel only after successful staging, promote afterward; a surviving marker remains fail-closed. Release and reclaim recheck poison before and after liveness/digest work and under the generation claim. Provenance publishes before handoff.

### `hooks/lib-write-turn.sh`

Own one complete Write turn: implementer contract, prompt assembly, prelaunch lease guard, companion launch, job publication, polling, Cancellation fact integration, raw result classification, and interruption.

Supported interface:

```bash
write_turn_run PLAN_FILE MAX_IDLE POLL RESULT_FILE EVIDENCE_FILE
write_turn_interrupt SIGNAL RESULT_FILE EVIDENCE_FILE
```

Return codes preserve watchdog outcomes: `0` DONE, `10` NEEDS_ANSWERS, `11` BLOCKED/lost ownership, `3` invalid input or start failure, `4` failed/missing result, `125` Cancellation fact with quiescence unconfirmed. The loop maps `125` to its existing terminal BLOCKED/`11`; standalone watchdog preserves `125`. Last anchored full-line `RESULT:` wins. No Write turn retries.

### Peer adapters

`implementer-watchdog.sh` retains CLI parsing and public final markers. It begins one Lease interval, calls one Write turn, ends or retains the Lease interval, then maps the result.

`implementer-loop.sh` retains Implementation-run iteration/stop policy. It begins one Lease interval, calls `write_turn_run` directly per iteration, runs its internal Verification transaction after DONE, and ends or retains once. It no longer launches the watchdog.

### Internal modules

The Verification transaction stays private in `implementer-loop.sh`. It has one caller, runs only after DONE, uses the process module, scrubs lease capability variables, kills/reaps the full verifier group, appends bounded failure evidence, and rechecks ownership before redispatch or success.

The Discussion turn stays private in `discussion-loop.sh`. It has one caller and owns transcript append/rollback, transcript lock, round cap, retries, reply persistence, and terminal marker parsing. It calls `companion_turn read` explicitly and never imports the Lease interval module.

## Safety invariants

1. One Implementation run owns one Lease interval.
2. The launch guard runs after write-flag preflight and immediately before start.
3. A confirmed task ID is published into the same lease generation before polling.
4. Publication failure after launch establishes a Cancellation fact and cancels; no replacement Write turn starts.
5. Heartbeat covers companion calls, poll sleeps, and Verification transactions.
6. Cancellation never proves quiescence. Every write cancellation retains the Lease interval until explicit recovery.
7. Live or identity-unknown owners are never stolen. Stale heartbeat is diagnostic, not death proof.
8. Reclaim requires proven owner death, known repository-global writer state, no writer, and exact-generation claim.
9. Normal and orphan provenance publish before the generation becomes available to a successor.
10. HUP/INT/TERM first reap the active local process group, then establish the Cancellation fact, then attempt external cancellation.
11. SIGKILL/host loss cannot run a trap; durable identity, heartbeat, global writer observation, poison, and operator clear remain the recovery path.
12. Every public CLI, marker, and exit remains compatible.

## Files

Create:

- `hooks/lib-process.sh`
- `hooks/lib-write-lease.sh`
- `hooks/lib-write-turn.sh`

Modify:

- `hooks/lib-companion.sh`
- `hooks/implementer-loop.sh`
- `hooks/implementer-watchdog.sh`
- `hooks/discussion-loop.sh`
- `install.mjs`
- `uninstall.mjs`
- `README.md`
- focused integration suites and `tests/run.sh`

## Deletion test

Delete from the old companion module: process supervision, digest/provenance, every `write_lock_*` implementation, lease-aware mode inference, polling/cancellation outcome globals, and result classification. Delete from the loop: watchdog child launch/wait, duplicate signal cancellation, inline clear, and duplicate process-group termination. Delete from the watchdog: embedded contract/transport sequence and duplicate poison/signal logic. Deleting these paths concentrates complexity behind the new interfaces instead of moving it to callers, so each new module passes the deletion test.

## Verification

- Focused process, companion, Lease interval, Write turn, liveness, stop-report, discussion, provenance, orphan, and installer suites.
- `bash tests/run.sh` with all suites green.
- `bash -n` on every changed shell file; `node --check` on changed `.mjs` files.
- Smoke install in an isolated HOME, exercise both write adapters and Discussion turn through the fake companion, reinstall byte-identically, then uninstall.
- Review changed files for old symbols/outcome globals and obsolete watchdog nesting; no compatibility paths remain.
