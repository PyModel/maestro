# Liveness prerequisites for autonomous Maestro mode

Source: `docs/superpowers/specs/2026-07-29-autonomous-maestro-fusion-review.md` items 1-4.
Landed as `a86f61d` on branch `fix/dispatch-liveness-and-lease-poisoning`.

## Items

- [x] Absolute per-dispatch deadline in `companion_poll` (`MAESTRO_MAX_DISPATCH_SEC`, default 1200s)
- [x] Write-mode cancellation poisons the write lease and terminates; no re-dispatch
- [x] Poison honored by `write_lock_acquire` and `write_lock_release`, including a surviving
      `metadata.new`, and re-checked after the job-liveness probe
- [x] `--clear-lease` recovery, refusing while a write-capable job still runs
- [x] Verifier deadline with its own process group (`MAESTRO_VERIFY_TIMEOUT_SEC`, default 900s)
- [x] Read-only dispatches unaffected (no lease, no poison)
- [x] Docs corrected: hang no longer auto-retries; poison, manual clear, unreported edits, and the
      upstream companion limitation stated honestly
- [x] Reinstalled with `node install.mjs` so the fix is live for this machine's dispatches

## Acceptance — met

```
bash tests/liveness.sh   → 9 passed, 0 failed (exit 0)
bash tests/run.sh        → SUMMARY: 9 passed, 0 failed (exit 0)
```
Both re-run by the orchestrator independently, not taken from the implementer's report.

## Review

**Verdict: SHIP**, after one FIX-FIRST round. Same-vendor review — Codex executed the orchestrator's
own plan — so every claim was checked against source and the verification re-run locally.

Three rounds of `NEEDS_ANSWERS`, each a real defect in the plan rather than a stall:

1. The mode discriminator (`MAESTRO_LOCK_ACQUIRED`) is never exported, so it read false in the
   watchdog — the one process that calls `companion_poll` in write mode. Every write cancel would
   have been misclassified read-only and the poison would never have fired. Answered with the
   inherited-token discriminator, following `write_lock_set_job`'s existing precedent.
2. Cancel-then-poison left a window where the job was cancelled but the lease still clearable.
   Reordered to stage first; staging failure refuses to cancel at all.
3. `--clear-lease` returned 0 reporting "no poisoned lease" while the lock survived. A surviving
   `metadata.new` is now unconfirmed state everywhere.

One defect found in orchestrator review, not by any test: the deadline was evaluated before the
terminal-state check, so a job completing in the final poll interval was cancelled and poisoned —
successful work reported `BLOCKED` and needing a manual clear. Reproduced RED
(`completed job was cancelled`), fixed, regression-locked.

Codex deviated from one instruction and was right to: told a comment would suffice for the
poison/delete race, it added a real re-check after the liveness probe. That probe spawns a node
process, which is long enough for poison to land inside the window.

Behavior change to know about: a hung write dispatch no longer auto-retries. It ends `BLOCKED` and
needs `--clear-lease`. That retry was the mechanism that started a second writer.

## Multi-session coordination — complete

The converged multi-session design (transcript:
`~/.maestro/discussions/-Users-panda-Projects-active-maestro-multi-session.md`), decided by the user
as one shared working tree with coordinated delegation:

- [x] Session attribution in lease metadata, poison state, provenance and contention messages, via
      `session-start.mjs` appending a validated `MAESTRO_SESSION_ID` to `$CLAUDE_ENV_FILE`
      (documented at `plugin-dev/skills/hook-development/SKILL.md:259-262,328`). Attribution, not
      ownership — token, process identity and job liveness stay authoritative; missing is `unknown`
      → `f154e72`
- [x] Implementer contract: preflight `git status --short`, report pre-existing dirty paths and
      confirm they were left alone. An obligation and a report, never a dirty-tree gate → `f154e72`
- [x] Bounded unordered wait inside `write_lock_acquire` instead of immediate `BLOCKED`, with
      classification before every wait — only a structurally valid, non-poisoned lease with a
      confirmed release path is queueable; poison preempts a wait already in progress → `8feca5c`

Dispatched as two plans, not one: attribution first so the waiting messages could name the session
holding the lease, then the wait itself. One plan touching `write_lock_acquire` twice invites a logic
bug.

### Acceptance — met

```
bash tests/run.sh      → SUMMARY: 9 passed, 0 failed (exit 0)
bash tests/lease.sh    → 28 passed, 0 failed (exit 0)
```

Re-run by the orchestrator, plus two proofs written independently of the implementer because its own
proof artifacts were ephemeral:

- default cap (`MAESTRO_LOCK_WAIT_SEC` unset) genuinely waits — 4 ticks in 4s, message reports
  `300s left before blocking`; a poisoned lease still blocks in 1s with no wait and prints recovery
- 64-char session id passes, 65-char becomes `unknown`, and the validation idiom does not leak into
  the caller's environment

### Review

**Verdict: SHIP**, after one FIX-FIRST round on `8feca5c`. Same-vendor review — Codex executed the
orchestrator's own plan — so every claim was checked against source and verification re-run locally.

`f154e72` (attribution + contract). One `NEEDS_ANSWERS`, caused by the orchestrator's own verifier:
it pointed `grep -c` at the env file in the invalid-id case, the one case where the hook is correctly
required to create nothing, so a correct hook produced an empty count and `|| true` hid the reason.
Codex refused to weaken the hook to satisfy a broken gate. Verifier rewritten to pre-create the file
as Claude Code does, with hook stderr now a failure and a fourth case for a payload carrying no
`session_id`. What review checked hardest: `session=` sits between `job=` and `before=` in provenance
records, because both readers extract the digest with `${last##* after=}` and a trailing field would
have silently corrupted the value they compare — the feature would have kept running while no longer
detecting anything.

`8feca5c` (bounded wait). One `NEEDS_ANSWERS`, and the plan was wrong twice over: it named the
pre-`mkdir` poison check as the per-poll mechanism (that check sits outside the loop, so `continue`
never re-runs it) and elsewhere named the after-liveness re-check (every wait `continue`s before the
liveness probe). Its "do not add a second poison check" constraint was also void on arrival — the
file already carried two verbatim copies of that block. Resolved by extracting
`write_lock_poison_gate` and calling it three times, which left less duplicated logic than before.

One defect found in orchestrator review, not by the implementer or any passing suite: five of the new
assertions proved "returned immediately" with whole-second `date +%s` arithmetic and `-lt 1`. Whole
seconds cannot express that — a boundary crossing inflates any measurement by 1, so a 20ms operation
failed about one run in eight. It surfaced as `SUMMARY: 8 passed, 1 failed` on the first independent
full-suite run, reproduced as `FAIL t20 — elapsed=1s want under 1s` in 1 of 8 `lease.sh` runs, and was
then confirmed deterministically: with measurement forced to start ~30ms before a tick, the old
assertion failed 10/10 and `-le 1` held 10/10 while `rc=11` and zero wait lines stayed correct. This
mattered beyond cosmetics — `tests/run.sh` gates every write dispatch, so the flake would randomly
turn a correct implementation into a failing round.

The timing bound was kept rather than deleted: the initialization-grace path sleeps up to 3s
**without** printing, so the grep assertions cannot see that stall. The grep proves zero wait ticks
exactly and independently of timing; `-le 1` guards the silent case. Neither alone is sufficient.

Known cosmetic nit, not worth a dispatch round: those five failure messages still read
`want under 1s` while the assertion now admits 1.

### Behavior to know about

Write contention now waits up to 300s by default instead of failing immediately. Set
`MAESTRO_LOCK_WAIT_SEC=0` for the old behavior. Waiting is unordered — FIFO was rejected because
arrival order would have to be reconciled against stale state on every poll, and the cap already
bounds starvation. An invalid knob value disables waiting rather than falling back to the default, so
a typo stays fast instead of becoming a five-minute stall.
