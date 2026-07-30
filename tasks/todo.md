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

## Session 2026-07-30 — verification of the shipped fixes, then two lease defects

### Verification — the recent fixes hold

Re-run by the orchestrator, not taken from any implementer report:

```
bash tests/run.sh              → SUMMARY: 9 passed, 0 failed
bash tests/lease.sh  ×10       → 10/10 green, 28 passed each
```

The ×10 loop is the check that discriminates: the `-lt 1` → `-le 1` flake failed about one run in
eight, so a single green run is the same evidence the *broken* assertion produced seven times out of
eight. The flake class does not extend to `liveness.sh` — its timing assertion is `-ge 4 && -le 10`,
a window wide enough that a tick boundary cannot cross it.

Production-path proofs, beyond the suites:

- `write_lock_session_id` returns this session's id, and `.git/maestro-provenance.log` shows the
  transition — `session=unknown` at 02:46, real UUIDs from 03:07 — so `e268c25` works where it counts
- installed `orchestrator-gate.mjs` probed directly: source Edit `rc=2`, `tasks/todo.md` `rc=0`,
  a payload carrying `agent_id`/`agent_type` refused the override
- `SessionStart` is registered with no matcher in `~/.claude/settings.json`, so it does fire on resume
- all 10 hooks, 3 rules and the skill are byte-identical to `HEAD`; the only extra files installed are
  the `.maestro.bak` backups `073ee36` promises
- the `metadata.new` surviving-lock regression from `8d82cf9` is locked at `tests/liveness.sh:317`,
  not merely fixed by hand

### Defect 1 — a metadata-less lock wedges the repository, unrecoverably

`hooks/lib-companion.sh:425-465` creates the lock directory at 425, runs the **unbounded**
`repo_digest` at 435, and does not write `metadata` until 455 or set `MAESTRO_LOCK_ACQUIRED=1` until
463. Any death inside that window — dispatch deadline, `Ctrl-C`, crash, session kill — leaves a lock
directory with no metadata.

Reproduced in a throwaway repo:

- a contender gets `rc=11 — blocked by an initializing owner (job=unknown session=unknown pid=unknown
  held=unknown)`, permanently: the stale-break path needs metadata to prove the owner is dead
- `--clear-lease` prints `MAESTRO_FINAL: LOOP CLEARED rc=0` — success — and the lock survives
- the only exit is `rmdir` by hand, which `rules/orchestrator-implementer.md:34` forbids

This is also a violation of the single-cleanup invariant rather than a missing feature. Both entry
points already route every terminal path through one `cleanup()` → `write_lock_release`
(`implementer-loop.sh:54-65`, `implementer-watchdog.sh:46-53`), but `write_lock_release` returns 0
immediately when `MAESTRO_LOCK_ACQUIRED` is 0 or `metadata` is absent (`lib-companion.sh:651-655`) —
so the shared cleanup is a no-op for exactly the half-acquired lease that needs it.

Found by Codex in debate (`STANCE: REFRAME`), verified against source and reproduced before being
relayed. Codex recommended deleting automatic provenance hashing from the lease path; the user chose
to keep the feature and publish metadata before scanning.

### Defect 2 — an unparseable metadata file lets a contender steal a live lease

Found while stress-testing defect 1's fix design, and worse than defect 1: it produces two writers in
one tree, the outcome the whole poison design exists to prevent.

`printf … > "$metadata"` truncates before it writes, so the file legitimately exists-and-is-empty for
a moment. Simulating a reader in that window:

```
MAESTRO_LOCK: broke stale write lock held by job=unknown session=unknown pid=unknown
contender acquire rc=0
STOLE IT — contender now owns a lease the live owner thinks it holds
```

Root cause: line 494 sets `owner_alive=0` when `pid` is unparseable, and the
`identity unconfirmed; failing closed` branch at 503-505 is gated on `owner_alive -eq 1` — so it is
unreachable precisely when the pid is missing. Absent identity is treated as *proof of death* instead
of *unconfirmed*, contradicting the invariant the file states for itself at 428-432 ("let the
contention path fail closed instead").

Consequence for the fix: atomic temp-plus-rename for every metadata write is mandatory, not a nicety.
A digest update written in place would widen this window rather than close it.

### Findings that are only reporting accuracy

- `rules/orchestrator-implementer.md:34,95` — doc drift. Still describes lock contention as an
  immediate `BLOCKED` you wait out by hand; since `39340b9` it auto-waits up to 300s. `README.md:80`
  is correct, `AGENTS.md`/`PRODUCT.md` do not mention it. This is the file loaded into every session's
  system prompt, so the orchestrator operates on stale rules.
- `hooks/implementer-loop.sh:106` — prints the same "nothing to clear" message, with a hardcoded
  `session=unknown`, for both "no lock at all" and "an unclearable orphan is wedging the repo".
- `tests/lease.sh:360,383,404,426,479` — messages read `want under 1s` while asserting `-le 1`.

### Test hardening — agreed in debate, not yet dispatched

- `cd … || exit` at all 28 SC2164 sites (27 in `lease.sh`, 1 in `manual-check-and-submodules.sh`).
  Ranked first by both sides: a failed `cd` does not abort the case, so it continues in the real
  checkout and can create a lease there.
- per-suite bounding in `tests/run.sh`, which has no deadline at all today — while
  `implementer-loop.sh --verify "bash tests/run.sh"` is the prescribed verify command, so a hung
  suite hangs *while holding the write lease*. Use the existing `set -m` + process-group TERM + grace
  idiom (`tests/liveness.sh:41-58`, `implementer-loop.sh:229-244`), not `timeout(1)` — that is
  Homebrew-only here, absent from stock macOS. Both sides probed independently that a group TERM runs
  the suite's `EXIT` trap and yields 143, so temp dirs still get cleaned.
- shellcheck inventory, measured at 0.11.0: 0 errors, 60 warnings, 172 info, 173 style. The 60 are
  28× SC2164, 28× SC1090, 4× SC2034 — all four verified cross-boundary false positives
  (`MAESTRO_LOCK_RETAIN`, `MAESTRO_CANCEL_REASON`, `MAESTRO_CANCEL_REQUESTED`,
  `tests/lease.sh:447`). Gating at `info`/`style` is rejected: 32× SC2030 + 32× SC2031 are inherent to
  a harness whose every case is a subshell, and this repo already argued against high-false-positive
  diagnostics in `9f21754`/`299b6da`. Open question Codex raised: a real gate needs CI (there is no
  `.github`) or a documented Homebrew dependency, since stock macOS ships no shellcheck.

### Plan A — shipped

`cd … || exit 1` at all 28 SC2164 sites, per-suite bounding in `tests/run.sh`
(`MAESTRO_SUITE_TIMEOUT_SEC`, default 600, invalid falls back to 600 with a message), optional suite
selection so the bound is testable in seconds, and the five `want at most 1s` messages.

**Verdict: SHIP**, no fix round. Same-vendor review — Codex executed the orchestrator's own plan — so
every claim was checked against the diff and re-run locally.

```
SC2164 in scope            28 → 0
want under / at most 1s    0 / 5
cd-guard additions in diff 28, exactly the named sites
hooks/ touched             0 files
bash tests/run.sh          SUMMARY: 9 passed, 0 failed
bash tests/lease.sh ×10    10/10 green, 28 each
MAESTRO_SUITE_TIMEOUT_SEC=3 + hanging suite → TIMEOUT hang.sh (rc=124) in 3s, not 300
MAESTRO_SUITE_TIMEOUT_SEC=abc → ignored with a message, bounding still active
```

The plan's own load-bearing claim was proven rather than asserted: a hanging suite carrying
`trap 'rm -rf "$TEST_ROOT"' EXIT` is **cleaned** when the runner TERMs its process group, which is what
justifies TERM-then-grace over a bare KILL.

One `NEEDS_ANSWERS` round, caused by the orchestrator's plan rather than by the implementer: the plan
quoted illustrative excerpts and expected byte-exact patching against them, but the real declarations
carry trailing inline comments (`kill_dispatcher_case() (  # $1=dir ...`) and several statements share a
line. Two patch attempts failed and nothing was written. Answered inside the orchestrator's authority —
invariant-preserving, no gate weakened — by requiring line-by-line patching against on-disk text.

### Plan B1 — applied, verified, one BLOCKED round on the way

Atomic publish before scanning, bounded digest, fail-closed on malformed metadata, honest
`--clear-lease`. Both reproduced defects are fixed:

```
bash tests/lease.sh      === 31 passed, 0 failed ===   (28 + t26 steal, t27 publish-order, t28 absent)
bash tests/liveness.sh   === 9 passed, 0 failed ===    (t6 extended, count unchanged)
shellcheck SC2164|SC2115 on both changed hooks → 0
```

Re-running the original reproductions against the fixed code:

- the wedge: still blocks a contender, but `--clear-lease` now prints
  `clearing structurally invalid orphan write lease` and the lock is **cleared** — recovery exists
- the steal: a contender now prints `write lease metadata is malformed; owner cannot be identified;
  failing closed`, returns 11, and leaves the owner's lock intact. Before: `broke stale write lock` and
  `acquire rc=0`
- a healthy unpoisoned lease: `--clear-lease` refuses with `BLOCKED rc=11`, naming
  `session=sess-healthy-owner`. Before: `CLEARED rc=0` while the lease sat there

Design details worth keeping: the re-publish carries a **byte-identical token** — `write_lock_is_owner`
and `write_lock_release` both authorize by comparing it, so a regenerated token would silently disable
release and reintroduce the wedge with every suite still green. The atomic writer uses
`metadata.tmp.<token>` → `mv`, which avoids both the `metadata.new` poison-name collision and
`tests/liveness.sh`'s `mv` shim (which intercepts only `*/metadata.new`). `repo_digest_bounded` prints
its timeout line **only** when the bound fires, never on `repo_digest`'s ordinary return-1 paths — every
`lease.sh` case runs in a plain `mktemp` directory, so ordinary failure is the common path there. Each
call gets a dedicated `TMPDIR` that is removed afterward, which also fixes a pre-existing leak: a killed
`repo_digest` left `maestro-repo-digest.*` files behind because it cleans up with inline `rm -f`, not a
trap.

#### The BLOCKED round, and what it demonstrated

The first B1 dispatch hit `MAESTRO_MAX_DISPATCH_SEC` (1200s) at ~20 minutes *while running
`bash tests/run.sh`* as the last of five in-plan verification commands. Cancellation retained and
poisoned the lease and ended the run, as designed.

Cause: an orchestrator planning error. The plan demanded five verification commands including the
~5-minute full suite, while `--verify` re-ran two of them locally — so the dispatch budget paid twice
for the same suites. `lease.sh` and `liveness.sh` had already exited 0 inside the turn and the edits
were applied before the cancel. Fix for future plans: keep in-dispatch verification to the fast checks
and let the loop's local `--verify` own the slow suite.

**The poison design validated itself on itself.** After the cancel, `bash tests/run.sh` was still
executing with two `liveness.sh` children — the brokered turn kept running, exactly the state the docs
say cannot be observed from the shell. A re-dispatch would have put a second writer in the tree. The
documented recovery order was followed: wait for that process to exit, confirm no Codex job is writing,
then `--clear-lease`, which cleared the lease naming `job=task-ms7d34jp-pgz9v0`,
`session=66ffdc6d-…` and `reason=deadline`. No lock was broken by hand.

### Still open

- **Plan B2** — the heartbeat the user requires plus the fencing Codex proved it needs (rename the lock
  directory before reacquisition, retain while the owner's PGID or a companion writer is
  alive-or-unknown, token-check every write boundary). Settling experiment, named in the debate: long
  verifier → SIGSTOP owner → heartbeat expiry → contender → SIGCONT; the contender must block while the
  verifier PGID lives, and after reclaim the old token must fail every update, dispatch and verification
  boundary.
- **`rules/orchestrator-implementer.md:34,95`** — the contention doc drift, still unfixed.
- **A ShellCheck gate** — needs CI (there is no `.github`) or a documented Homebrew dependency. A
  product decision, not a dispatch decision.
- **A liveness trap the tool could catch:** nothing warns that a plan's own verification list competes
  with `MAESTRO_MAX_DISPATCH_SEC`. A plan asking for a 5-minute suite inside a 20-minute cap is a
  predictable cancellation, and it cost a round on the most delicate change of the session.

### Not a defect — checked and dismissed

A suspected stale progress monitor. There are **zero** `Monitor` tool calls in any session transcript
for this project, so there was no monitor to go stale; what was observed was background-dispatch
notification timing. The monitor stays unchanged. Staleness today is already decided by process
identity plus companion job liveness, never by log growth — `MAX_IDLE` cancels the *dispatch*
(`lib-companion.sh:1028-1041`) and never marks a lease stale.
