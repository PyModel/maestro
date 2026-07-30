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

## Next

The converged multi-session design (transcript:
`~/.maestro/discussions/-Users-panda-Projects-active-maestro-multi-session.md`), decided by the user
as one shared working tree with coordinated delegation:

- [ ] Bounded unordered wait inside `write_lock_acquire` instead of immediate `BLOCKED`, with
      classification before every wait — only a structurally valid, non-poisoned lease with a
      confirmed release path is queueable; poison preempts a wait already in progress
- [ ] Session attribution in lease metadata, poison state, provenance and contention messages, via
      `session-start.mjs` appending a validated `MAESTRO_SESSION_ID` to `$CLAUDE_ENV_FILE`
      (documented at `plugin-dev/skills/hook-development/SKILL.md:259-262,328`). Attribution, not
      ownership — token, process identity and job liveness stay authoritative; missing is `unknown`
- [ ] Implementer contract: preflight `git status --short`, report pre-existing dirty paths and
      confirm they were left alone. An obligation and a report, never a dirty-tree gate
