# Review: Autonomous Maestro Fusion Design

**Date:** 2026-07-29
**Reviews:** `2026-07-29-autonomous-maestro-fusion-design.md` (commit 69f1d1c)
**Method:** 4-turn Claude/Codex debate (`gpt-5.6-sol`, effort `max`), read-only, transcript at
`~/.maestro/discussions/-Users-panda-Projects-active-maestro-fusion-spec.md`
**Outcome:** `ESCALATE` — one product decision belongs to the user (item 12). Everything else converged.

**Verdict: RETHINK before implementing** — not because the design is wrong (its direction survived the
debate intact) but because it is specified on top of a liveness defect that already exists in shipping
code and that the mode itself would hide. The prerequisites below are not part of the feature; they
gate it.

## The finding that reorders the whole spec

Autonomous mode's defining property is that no human is watching. Three existing behaviors are
tolerable only *because* a human is watching, and the spec inherits all three:

**1. `companion_poll` has no absolute deadline.** It is `while :;` with exactly three exits: a terminal
job state (`hooks/lib-companion.sh:788-794`), status unreachable 4× (`706-711`), and
`idle >= MAX_IDLE` (`802-806`). `idle` resets to zero on any growth of the companion's log file
(`796-800`). A Codex job looping on tool calls grows that file every poll, so the only timer that
exists is defeated by the most common stuck mode. No `timeout`, `SECONDS`, or deadline exists anywhere
in `hooks/`.

**2. A stuck job holds the repository-wide lease with no expiry.** `hooks/implementer-loop.sh:87`
acquires the lease before the loop; line 114 then blocks inside `companion_poll`.
`lib-companion.sh:425` deliberately retains the lease while the owning job is still running. So the
run never reaches `SHIP`, `BLOCKED`, or `STUCK` — and every other session in that repository is
blocked behind it indefinitely. `PRODUCT.md:13` promises "either a verified result or a precise
terminal blocker"; this path delivers neither.

**3. Cancellation does not stop the writer.** This is the sharpest finding, and it means a naive
deadline would make things *worse*:

- `codex-companion.mjs:986` calls `terminateProcessTree(job.pid)`, then unconditionally writes
  `status: "cancelled"` and nulls the PID (`989-1011`) — the status flip does not depend on the
  outcome.
- `lib/process.mjs:99-115` (POSIX) sends `kill(-pid, "SIGTERM")` — one signal to the process group,
  **no SIGKILL escalation, no `waitpid`, no confirmation**. Its own `delivered: true` means the signal
  was sent, not that anything died.
- The recorded PID is the detached *task-worker* (`codex-companion.mjs:671-693`), but the turn that
  actually writes runs through a shared broker process (`lib/codex.mjs:1101` →
  `lib/app-server.mjs:338-350`, `BrokerCodexAppServerClient`). **Worker death does not prove the
  brokered turn stopped**, and a `turn/interrupt` acknowledgment is not a terminal event.
- `lib-companion.sh:803-805` ignores cancel's output and returns 124 immediately.
  `implementer-loop.sh:126-133` re-dispatches, and `lib-companion.sh:319-325` makes that re-entrant by
  design via `MAESTRO_LOCK_TOKEN`.

The lease serializes dispatches *between processes* and is structurally blind to a zombie job holding
its own token. So a timed-out-but-alive Codex process can write the same tree as its replacement. This
is live today on the idle path; adding a deadline makes it routine.

## Prerequisites (land before the mode ships)

1. **Absolute per-dispatch deadline** in `companion_poll`, shared by opinion, debate, and
   implementation. Default 20 minutes with a validated positive override; keep the idle timer as the
   fast path. Returning 124 lets `implementer-loop.sh:126-133` count it as a failed attempt, so the
   run bound becomes `MAX_ITERS × DEADLINE` with no second run-level timer and no new state.
2. **Confirmed turn quiescence before any re-dispatch or lease release** — terminal turn observation
   *plus* worker/process-group death. Worker death alone is insufficient proof (see above). Failed
   confirmation retains the lease and terminates the run; it never releases or reuses it.
3. **A deadline on the local verifier** (`implementer-loop.sh:148` runs `bash -c "$VERIFY"` with no
   bound), inheriting the same process-tree rule.
4. **State plainly that cancellation can leave unreported edits.** The next round is told the tree
   already contains prior attempts' edits (`implementer-loop.sh:104-108`) with no report from the
   killed job. The provenance digest proves the tree changed, never that intent completed.

Settling test for 1–3 (both sides agreed on this): extend `tests/fixtures/fake-companion.mjs` with a
permanently `running` job whose `logFile` grows every poll. Current code must outlive `MAX_IDLE`;
revised code must cancel at the absolute cap, prove no second task starts while the first is alive,
and terminate `STUCK`. `MAESTRO_TEST_JOB_PHASE` alone is not enough — the fixture needs log-growth
behavior.

## Spec corrections

5. **Enforce the outer caps or relabel them.** Spec lines 257-258 publish "maximum one replan" and
   "maximum two repair rounds" as bounds, but nothing counts them — no state file, no script. Today's
   working caps are enforced in code (`discussion-loop.sh:121-127` refuses turn 7;
   `implementer-loop.sh:98,167` bounds rounds). Fix: **one controller** atomically owning
   `ROUTE / REPLANS / REPAIRS`, read and refused on by the dispatch path. A file alone is a record, not
   an authority. Debate turns stay **derived from the transcript** — duplicating that count would
   create two sources of truth for a cap that already works. Any cap that ends up unenforced must be
   relabelled as discipline, in the language `rules/orchestrator-implementer.md` already uses for the
   gate. Publishing an unenforced number as a bound is what that rule exists to forbid.
6. **Drop the nine-template renderer** (spec 120-156). Its four Claude-facing templates move hook
   string literals into files for a customization nobody asked for, and the Codex-facing ones need no
   placeholder engine: both working handoffs today are plain concatenation
   (`discussion-loop.sh:202`, `implementer-loop.sh:101-109`). Variables become *appended labelled
   sections*, not substitutions. Deleting the renderer deletes an attack surface, a failure mode
   ("unresolved placeholder"), and a test suite. **Keep three static Codex-facing files** — opinion,
   debate doctrine, implementer contract. `USER_PROMPT_CORRECTION.md` is cut too:
   `implementer-loop.sh:102-109` already appends labelled failure evidence. The implementer contract
   is worth extracting on its own merits — `implementer-watchdog.sh:83-127` is 45 lines of
   shell-quoted prose, which is spec goal 6's real case.
7. **Run artifacts move to workspace-keyed `~/.maestro/runs/`.** `/tmp/maestro-runs/` (spec 160)
   re-introduces exactly what commit 2005656 fixed: "Transcripts lived in /tmp, which macOS clears on
   reboot and prunes on its own schedule." Result fusion reads `fused-plan.md`, `codex-result.md`, and
   `verification.txt` written potentially an hour and several max-effort rounds earlier — same failure
   mode, longer window. The session **mode flag stays in `/tmp`**, per that commit's own distinction:
   authorization and session scope should not survive a reboot; run memory should.
8. **Keep the independent opinion, full route only.** Codex's pushback held: `discussion-loop.sh:202`
   sends it Claude's entire framing, and "attack the weakest assumption" cannot restore causal
   independence after anchoring. The deciding risk is false consensus on a load-bearing design error.
   Record the falsification test as the criterion for deleting the stage: run representative
   full-route tasks through both paths, blind-review unique material defects found, compare downstream
   replans and latency. No lift → delete it.
9. **"Reversible" needs an operational test, not a definition.** Spec 41 defines it; spec 189 then
   hands reversible product taste to the party that benefits from applying the definition loosely. The
   agreed test: the inverse touches only hunks and artifacts *this run introduced*, preserves
   pre-existing work and data, and creates no compatibility or migration obligation; **and** no
   external mutation was authorized or executed. ("Nothing observed" was rejected as unprovable; "in
   the plan's scope" was rejected as circular, since Claude writes the plan.) Failing the test →
   terminal `BLOCKED`. `DECISION_REQUIRED` gets counted like every other cap.
10. **Verify `session_id` empirically before writing tests against it.** Spec 54 asserts resume
    preserves the ID and a new session gets a new one; neither model verified this across `--resume`,
    `--continue`, `/clear`, and auto-compact. Capture real payloads first. An absent or changed ID must
    fail closed to legacy — which is safe, but the spec should say so rather than assert the harness's
    behavior as if it were Maestro's.
11. **Drop the test the spec cannot deliver.** Spec 313 promises to verify that "material-divergence
    and aligned-opinion paths produce the expected debate state," but no shell test can observe a
    model's semantic judgment. Once the controller in (5) records the route, test **recorded
    controller transitions** instead.

## Escalated product decision — resolved by the user

The fork, relayed verbatim from the debate:

> **ESCALATE:** Allow local product taste passing the run-diff/no-compatibility/no-external-mutation
> test, preserving unattended autonomy; or keep product taste human-gated, preserving explicit
> authority but ending such runs `BLOCKED`. Recommendation: allow it and disclose
> `ASSUMPTION_APPLIED`.

**Decision (user, 2026-07-29): allow it, with disclosure.** Local product taste that passes the item 9
test may be decided inside an autonomous run and must be reported as `ASSUMPTION_APPLIED` in the final
result. Anything failing that test — external mutation, a compatibility or migration obligation, or an
inverse touching work this run did not introduce — remains terminal `BLOCKED`. Legacy mode keeps its
existing escalation behavior unchanged.

## What survived unchallenged

Session-scoped opt-in autonomy; Codex as the only writer holding the repo-wide lease; adaptive
short/full routing as a concept; evidence over claims in result fusion; read-only opinion and debate;
the six-section plan contract; `ASSUMPTION_APPLIED` disclosure; fail-closed terminal states; the
honest documentation of guardrail limits. Item E from the debate — two autonomous sessions in one
repository, where the second dies `BLOCKED` on lease contention rather than queuing — was examined and
judged correct as specified (fail-fast is safe).

## Sequencing

Spec line 349's constraint holds, with the prerequisites prepended: liveness and cancellation
semantics (1-4) → prompt extraction and install safety (6) → session mode with verified payloads (10)
→ controller and caps (5) → opinion/fusion (7, 8) → autonomous question handling (9). Existing lease
and provenance suites stay green after every step; `bash tests/run.sh` remains the acceptance command.

## Review honesty

This review is same-vendor by construction on the Claude side: Claude wrote the spec being reviewed
and drove the debate. The compensating discipline was to verify every Codex claim against source
rather than accept it — the broker-vs-worker distinction, the missing `waitpid`, the token
re-entrancy, and the absent deadline were each read in the actual files and are cited above with
line numbers. Two of Codex's four turns overturned a position Claude held.
