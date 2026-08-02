# Dispatch Budget Resilience Research

**Date:** 2026-08-02
**Status:** Implemented and integration-tested

## Incident

A real write dispatch reached `MAESTRO_MAX_DISPATCH_SEC=1200` while still making useful progress and
roughly 80% complete. Maestro cancelled it, retained and poisoned the lease, and left useful but
unreported edits in the tree. Recovery required waiting for quiescence, clearing the lease, inspecting
the partial tree, writing a new continuation plan, and manually raising the cap to 2400 seconds.

This is not evidence that cancellation should become retryable. It is evidence that the default hard
ceiling is too close to the normal working budget for large but healthy writes.

## Pre-change behavior and constraints

- `companion_poll` cancels at 1200 seconds regardless of activity
  (`hooks/lib-companion.sh:1126-1250`). `tests/liveness.sh` deliberately proves that a growing log
  defeats idle detection but still dies at the absolute deadline.
- Commit `8d82cf9` added that deadline because a chatty tool loop could otherwise hold the repository
  lease forever. Removing the hard ceiling is not acceptable.
- Write cancellation is not proven terminal. Maestro must retain poison and must not dispatch a
  replacement writer (`hooks/lib-companion.sh:1101-1124`, `hooks/implementer-loop.sh:275-280`).
- A cancelled turn has no trustworthy final report. Its edits are **unreported partial state**, not a
  checkpoint and not evidence that any plan step completed.
- Commit `448f38d` already reduced avoidable budget use by forbidding unnamed in-dispatch suites. The
  new incident occurred despite that policy, so planning discipline alone is insufficient.

## Primary-source findings

### Long-running systems separate liveness from total duration

Temporal distinguishes frequent Activity Heartbeats from an overall Schedule-To-Close timeout.
Heartbeats indicate definite progress and may carry a progress payload for a later retry, while the
overall timeout bounds the complete Activity Execution. Temporal explicitly warns that heartbeat
suitability depends on being able to report definite progress, not merely being alive.

AWS Step Functions similarly defines a task timeout and a shorter heartbeat interval for long-running
activities. The worker heartbeat says that the task remains active; the timeout remains the bounded
workflow policy.

systemd exposes `EXTEND_TIMEOUT_USEC` so a supervised operation can request more time before expiry.
That protocol is useful precedent for an explicit extension, but repeated extensions are unbounded;
Maestro must retain a separate finite ceiling.

### Codex can support better cooperation eventually, but the current companion cannot

The official Codex app-server protocol provides `turn/steer`, `turn/interrupt`, and a later
`turn/completed` notification. In principle, a future companion could steer an active turn to produce
a continuation and could observe its exact terminal event.

The installed codex companion 1.0.6 does not expose steering in its CLI. Its cancellation path waits
only for the `turn/interrupt` request response, then terminates the worker and records `cancelled`; it
does not wait for the matching `turn/completed` notification
(`scripts/lib/codex.mjs:960-999`, `scripts/codex-companion.mjs:963-1018`). Therefore:

- no mid-turn checkpoint request is available through Maestro's current seam;
- interrupt acknowledgement is not quiescence proof;
- cancel-then-resume and automatic continuation remain unsafe.

## Designs considered

| Design | Result |
|---|---|
| Keep 20 minutes and improve plans | Rejected. Verification scoping already landed; real productive work still crossed the cap. |
| Raise write dispatches to a fixed 40-minute ceiling | **Selected.** Smallest interface and no false claim that activity equals progress. |
| Grant 20 more minutes only when logs/phases change | Rejected for now. The five-minute idle guard already removes quiet jobs; chatty loops can manufacture every available activity signal, so the branch adds false precision without reducing the 40-minute worst case. |
| Ask the model to yield with `RESULT: CONTINUE` | Deferred. Prompt-only clock compliance is unreliable, and the current companion cannot steer a running turn. |
| Cancel and automatically resume/re-dispatch | Rejected. Cancellation is not terminal confirmation and partial edits are not a checkpoint. |
| Remove the hard ceiling | Rejected. Reintroduces unbounded cost and permanent lease retention. |

Four independent design reviews split two votes for activity-gated extension, one for cooperative
yields, and one for a fixed ceiling. The fixed ceiling wins on depth and locality: the caller learns no
new control, budgeting remains in `companion_poll`, and the implementation does not expose a
heuristic “progress” interface that cannot be made truthful.

## Recommended design

### Budget policy

Keep `MAESTRO_MAX_DISPATCH_SEC` as the real hard ceiling.

- Unset write-mode default: **2400 seconds**.
- Unset read-only default: **1200 seconds**.
- A valid explicit `MAESTRO_MAX_DISPATCH_SEC=N`: exactly `N` for either mode; never silently doubled.
- An invalid explicit value: warn and retain the current conservative 1200-second fallback.
- Emit one informational warning halfway through the hard budget:

```text
MAESTRO_BUDGET: job=<id> crossed the normal budget and remains active; continuing to the <N>s hard ceiling. Activity is not proof of completion.
```

The warning does not mutate the plan, checkpoint the tree, change the lease, start another job, or
retrieve a result. Existing idle and four-status-loss exits remain the fast paths. A noisy bad job may
consume 40 minutes, but never more; a quiet bad job still dies at the idle threshold.

Use Bash `SECONDS` for elapsed time and start the clock before `companion_start`, avoiding wall-clock
rollback and ensuring startup consumes the advertised dispatch budget. Terminal-state evaluation must
remain before the hard-deadline check, preserving the terminal-at-deadline regression fix.

### Hard-ceiling transition

```text
RUNNING
  terminal success              -> HARVEST RESULT
  terminal failure              -> FAILED
  observed external cancellation-> POISON / BLOCKED
  idle or status lost           -> POISON / CANCEL / BLOCKED
  midpoint                      -> WARN ONCE; SAME TURN CONTINUES
  hard ceiling                  -> POISON / CANCEL / BLOCKED
```

For write mode, every cancellation path retains the lease and is terminal for the loop. There is no
hard-ceiling-to-redispatch edge.

### Recovery output

A hard-ceiling stop should emit a stable fact, not an inferred continuation:

```text
MAESTRO_RECOVERY: UNREPORTED_PARTIAL job=<id> reason=deadline; the tree may contain incomplete edits and local verification did not run. Confirm quiescence, clear the poisoned lease, inspect the diff and targeted tests, then write an evidence-based continuation plan. Do not restart from scratch or auto-resume.
```

The original plan remains the authority. After quiescence, the orchestrator independently records:
pre-existing user-owned paths, changed files, completed evidence, failing tests, and the exact next
action. Maestro must not manufacture those claims while the cancelled writer may still be running.

### Required adjacent cancellation fix

The implementation maps companion-reported `cancelled|canceled` write state to poison reason
`cancelled-observed`, returns 125, retains the lease, and terminates as `BLOCKED` without issuing a
redundant cancel request or starting another job.

## Acceptance tests

Add focused cases to `tests/liveness.sh` and deterministic sequencing to the fake companion:

1. Unset budget resolution yields write=2400 and read-only=1200 without waiting real minutes.
2. Explicit `MAESTRO_MAX_DISPATCH_SEC=N` remains the exact hard ceiling; invalid input falls back to
   1200 with a warning.
3. A write job crosses a scaled midpoint, emits exactly one warning, completes before the ceiling,
   fetches its result, and is never cancelled.
4. A permanently growing/chatty job still cancels at the scaled hard ceiling, poisons the lease, starts
   exactly one task, and exits loop rc 11.
5. A quiet job still takes the existing idle path before the ceiling.
6. Status loss after the midpoint still follows the four-failure fail-closed path and receives no extra
   dispatch.
7. A terminal state observed on the ceiling poll is harvested before deadline handling.
8. A companion-reported external cancellation poisons and blocks with one task and no result fetch.
9. Startup delay consumes the hard budget, and a wall-clock `date` shim cannot defeat it.
10. Deadline output contains `UNREPORTED_PARTIAL` and never claims checkpoint, completion, or a
    percentage.
11. `bash tests/liveness.sh` and `bash tests/run.sh` pass.

## Implementation outcome

Landed after lease-generation/global-liveness and supervisor-signal repairs, without cooperative
continuation or automatic recovery. `tests/bounded-calls.sh` verifies mode-specific defaults and
explicit/invalid values. `tests/liveness.sh` verifies midpoint continuation, startup accounting,
hard-ceiling poison/recovery output, terminal-at-ceiling precedence, malformed status loss, and
externally observed cancellation. The original integration run finished with 15 suites and zero failures. Residual-audit closure later
added runner process-tree coverage, bringing the default integration run to 16 suites.

## Sources

- Maestro source: `hooks/lib-companion.sh`, `hooks/implementer-loop.sh`,
  `hooks/implementer-watchdog.sh`, `tests/liveness.sh`.
- Maestro history: commits `8d82cf9`, `448f38d`, `776034b`; `tasks/todo.md` cancellation account.
- Temporal, *Detecting Activity failures*: https://docs.temporal.io/encyclopedia/detecting-activity-failures
- AWS Step Functions, *Task workflow state*: https://docs.aws.amazon.com/step-functions/latest/dg/state-task.html
- systemd, `sd_notify(3)` (`EXTEND_TIMEOUT_USEC`):
  https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
- OpenAI Codex, *codex app-server protocol*: https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
