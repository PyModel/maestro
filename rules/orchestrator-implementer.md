# Orchestrator / Implementer Loop

**Orchestrator (master)** = the main Claude loop (Opus 5, or Fable 5 on the hardest tasks). Plans, dispatches, answers, reviews. Writes no source code by default.
**Implementer (hands)** = Codex behind a shared Write turn module, **write-enabled**. Executes written plans, runs verifiers, returns evidence and questions.

## Codex model & effort

At session start a hook asks which Codex models and role-specific reasoning efforts to use (or shows the current pin). Discussion and implementation each carry their own model and their own effort tier. Mid-session, the user can say "codex model" to change them; apply with:

```
bash ~/.claude/hooks/codex-model-select.sh --show
bash ~/.claude/hooks/codex-model-select.sh <model> <debate-effort> <impl-effort> <impl-model>
```

Name `<impl-model>` explicitly. Omitting it keeps an existing implementation pin, but on a fresh unpinned install it silently inherits `<model>`, which is not the intended implementation default.

Effort guide: minimal/low for quick mechanical work, medium for default implementation, and **high for architecture debates, delicate refactors, and final-review judgment**. Debate effort may also use max/ultra through top-level Codex config; implementation effort uses none/minimal/low/medium/high/xhigh per write job, while max/ultra are allowed only when the implementation effort exactly matches the pinned top-level debate effort and the companion omits the per-job flag. Never accept a silent fallback from an unsupported implementation tier. Model availability depends on the user's ChatGPT plan; the script validates the name's shape only, and Codex itself rejects a model it cannot reach. “Keep current” is usable only when `--pin` succeeds; a fresh unpinned install cannot dispatch until the user selects values.

## Dispatch

```
# Claude Bash tool: run_in_background: true
bash ~/.claude/hooks/implementer-loop.sh --plan <plan-file> --verify "<verify command>" [--max-iters 4]   # default
# Claude Bash tool: run_in_background: true
bash ~/.claude/hooks/implementer-watchdog.sh --file <plan-file>                                            # single-shot fallback
```

These are the only ways to invoke the implementer. Always run the outer Bash call in the background: foreground Bash stdout/stderr is invisible to the user, while background-task output streams live. This is observed Claude Code behavior, not a preference. Both append the implementer contract (execute-the-plan discipline, structured RESULT lines, no web-search) to every dispatch — never retype it. Always use files: a plan carries exact steps and verification commands, and inlining that into shell quotes corrupts it. Write the plan to `/tmp` (the gate exempts `/tmp`).
`--verify` consumes exactly one argument. Quote the complete shell command (or pass it as one array element); after Bash splits the invocation, the hook cannot distinguish a lost quote from a legitimate option such as `--max-iters 4` inside the verifier.

**Prefer the loop.** It is autonomous between iterations: dispatch → parse RESULT → on a DONE claim, re-run your verify command *locally* (a claim is not proof) → on any failure, append the actual failing output to the next dispatch so Codex never repeats an approach blind. It only stops for the four states below — do not babysit it between rounds.

Write access is real — Codex edits your working tree directly. Scope the plan tightly; Codex is instructed to touch only the files the plan names. Never dispatch a plan you would not want applied verbatim.

**Orchestrator patience is mandatory.** After dispatching a write-mode job, yield immediately. Perform no workspace reads, verification commands, or diff review until that job reports completion. Reading a tree while Codex is still writing reviews a moving target and silently defeats the loop's final gate.

One Implementation run holds one Lease interval across every Write turn and local Verification transaction. Its ownership domain spans linked worktrees and superproject/submodule overlaps. Contention waits up to `MAESTRO_LOCK_WAIT_SEC` (default 300 seconds, `0` disables waiting) only while the Lease interval has a confirmed release path; each sleep is clipped to the remaining cap. Stale reclaim is token-conditioned, and repository safety queries deliberately ignore companion session filtering and accept compact or pretty valid JSON only. A stale heartbeat is only a recovery candidate: `--clear-lease` still refuses while the recorded owner process is alive or unidentifiable, or any repository-global companion writer is visible. A metadata-less lock younger than five seconds may still be in its atomic-publication window and is not clearable. Never break the lock manually; if cancellation left quiescence unconfirmed, first prove no Codex job is writing, then run `bash ~/.claude/hooks/implementer-loop.sh --clear-lease`.

All Maestro companion dispatches—Write turns, debates, and future Read adapters—serialize on a per-workspace job lock for the companion job's full lifetime. Recover a stale lock with `bash ~/.claude/hooks/implementer-loop.sh --clear-job-lock`; direct non-Maestro companion launches bypass this mutex because it is a Maestro convention, not a companion capability.

**Scout** is read-only repository reconnaissance on a separately pinned small model. Pin it with `bash ~/.claude/hooks/codex-model-select.sh --scout <model> <effort>` and dispatch it with `bash ~/.claude/hooks/scout.sh --query <file>`; it serializes on the companion job lock and fails closed when unpinned.

Five minutes without log growth remains the fast idle guard, measured from monotonic elapsed time rather than by adding poll intervals. `--max-idle` and `--poll` must be positive integers and fail before lease acquisition or task launch. `MAESTRO_MAX_DISPATCH_SEC` is the hard ceiling: unset write jobs get 2400 seconds, read-only debates get 1200, and an explicit valid value is used exactly. Startup consumes the budget; poll sleeps clip to the nearest idle/deadline boundary; one halfway warning continues the same turn without claiming a checkpoint. `MAESTRO_COMPANION_TIMEOUT_SEC` bounds every companion call (default 120 seconds). Four consecutive empty or malformed statuses fail closed; read-only `status-lost` uses the configured discussion retries, while idle/deadline cancellation is terminal. Any write cancellation—including companion-observed cancellation—poisons and retains the lease, ends `BLOCKED`, and cannot redispatch; a hard-ceiling stop emits `MAESTRO_RECOVERY: UNREPORTED_PARTIAL`. Clear only after confirming quiescence with the documented standalone `--clear-lease` command; it is mutually exclusive with execution options.

Terminal-confirmed cancellation requires the companion to expose the turn's terminal event. That is an upstream capability Maestro cannot observe from the shell.

**Research flows both ways, with two sources of truth.** Codex's built-in web search is disabled (that was the hang source), but its configured **MCP tools (tavily, context7, …) are available to both loops** for version-sensitive facts: library versions, API changes, current docs. The discipline:

- You still pre-research with your own MCPs/web and embed facts in the plan — a plan that needs no lookups is faster and cannot stall.
- Codex may verify what turns out version-sensitive (max 2 lookups per turn/run, no retries on stall). When it verifies something, its report says `verified via <mcp>: <fact>` — trust that over either model's training data.
- A stalled or failed lookup degrades gracefully: debates mark it `RESEARCH NEEDED:` (you fetch it), implementations use the QUESTIONS channel if the fact is load-bearing.
- Check what the jobs inherit any time: `bash ~/.claude/hooks/codex-mcp-check.sh`. MCP configs live per-side — yours in Claude Code, Codex's in `~/.codex/config.toml`; neither sees the other's.

## When

Source-code changes and real design work, including `/code-review`, `/apple-design`, `/improve`. Pure questions, chat, notes, config edits, and writing plan files you do yourself, direct.

## The discussion loop — bidirectional debate

Design forks, architecture choices, and elusive root causes earn a debate *before* a plan. You talk to Codex as a peer — grill it, and let it grill you back:

```
bash ~/.claude/hooks/discussion-loop.sh --new "<topic>" <slug>
bash ~/.claude/hooks/discussion-loop.sh --turn <your-turn-file> <slug>
```

You drive, like a user would. Write your turn to a temp file — your position, your strongest evidence, actual diffs and failing output when relevant — the script appends it to a private transcript at `~/.maestro/discussions/<workspace>-<path-hash>-<slug>.md`, and Codex replies with a `STANCE: AGREE / PUSHBACK / ALTERNATIVE / REFRAME` line. Debate mode is **read-only**: nobody edits code while the design is still being argued. Codex shares no memory between calls — the transcript *is* the memory, so quote, never paraphrase.

**Protocol:**

- **When to debate:** two materially different designs, an architecture decision, a root cause you cannot pin from the evidence, or the user asks ("grill this with Codex" / "debate it" / "tartış"). Never for settled trivia — a discussion about the obvious trains both sides to skim.
- **How to grill:** press on the weakest load-bearing assumption, demand the evidence behind claims, ask "what would change your mind". Expect the same back — Codex has explicit license to reframe your question when the question is wrong.
- **Debugging duels:** state your hypothesis plus the *actual* evidence (failing output, logs, the relevant code lines). Codex's job is to break it. The winner is whichever hypothesis survives contact with the evidence, not the better argument — and the settling experiment gets named before you converge.
- **Termination:** `CONVERGED` (the agreed design + why the losers lost), `ESCALATE` (a genuine human call — product taste, irreversible tradeoff — relay the fork verbatim with both options and Codex's recommendation), or the 6-turn cap, whichever comes first. At the cap, converge with a stated assumption or escalate. Never abandon a discussion silently mid-thread.
- **Output:** the CONVERGED design becomes the **Decisions** section of the implementation plan, carrying the losing alternatives and their rejection reasons. A plan born from a debate beats one born from a monologue — but only if the debate actually happened in the transcript.
- **Honesty:** relay outcome-changing counterarguments to the user verbatim. Never claim Codex endorsed a design it pushed back on, and never present your own preference as the consensus.

## The plan contract

Codex shares none of your conversation context. Every dispatch carries five parts, plus one when a debate happened:

1. **Objective** — the outcome, one paragraph
2. **Files** — exact paths in scope (and implicitly, everything else out of scope)
3. **Steps** — concrete, ordered implementation steps with the design decisions already made
4. **Constraints** — project conventions, things not to touch, facts you researched
5. **Verification** — the exact commands Codex must run, and what passing looks like
6. **Decisions** *(after a discussion)* — the CONVERGED design, the losing alternatives, and why they lost. This is the implementer's window into the debate it was not part of.

A plan you can't finish writing means the decision isn't formed yet — form it, or ask the user the open question *before* dispatching. A vague plan gets you a confident wrong implementation, applied to disk.

### Designing the Verification section

Every write dispatch is killed at the `MAESTRO_MAX_DISPATCH_SEC` hard ceiling (2400s when unset; read-only defaults to 1200s), and a write-mode kill retains and poisons the lease. An over-budget verification list therefore still costs a recovery round; the larger healthy-write budget is resilience, not permission to duplicate comprehensive verification inside the dispatch.

**Name only fast leaf checks. The loop's `--verify` owns the comprehensive suite.** It runs *after* the dispatch, locally, from the lease repository root — the caller's shell directory does not affect root-relative paths — on your side of the deadline. A full suite listed in-dispatch is paid for twice, and the second payment is the one that cancels.

**Banning a slow suite by name does not ban it.** Suites call suites, and a ban on the wrapper leaves every caller reachable. Measured in this repo: `run.sh:27` runs `detection.sh`, and `detection.sh:90` runs `lease.sh`. A plan that forbade `run.sh` was satisfied, to the letter, by a dispatch that spent nineteen minutes in `detection.sh` — which is the same work by another name. Before writing the Verification section, expand the call graph of every gate you name or forbid, and budget its **cold transitive** cost, not the leaf's.

Do not attempt to fix this with a token budget or a timing table in the plan. Timings drift, and awareness was never the missing ingredient — the implementer knew the suite was slow and ran it anyway, for defensible reasons, because nothing said *only*. The categorical scope cap belongs in the implementer contract, not in each plan.

Three more recurring costs, from the implementer's side of the boundary:

- **Label each gate's venue.** Say whether a check runs in a sandbox-safe repository copy or needs something orchestrator-owned — `/bin/ps`, Docker, a listener, a live install, or a proof against the *installed* copy rather than the repo file. An unlabelled gate gets attempted in the wrong venue and returns `NEEDS_ANSWERS`.
- **State the expected RED explicitly.** Give the exit code and the output that means "correctly failing" for any test-first step, or a passing-by-accident run reads as success.
- **Grant every test and fixture path the verification touches.** A file-scope contract that omits the fixture the named test loads is correctly refused, and that refusal costs a round. (See also `[[plan-scope-grants-prevent-stuck]]`.)

### Every check you name must be able to fail, and you must have watched it fail

A check that passes both before and after the change is a defect in the check, whatever the
underlying property is doing. Seven shipped in a single day, all authored here, none caught by
anything but habit: a `restore-keys` claim that asserted a belief rather than a behaviour; a
"each pinned version appears once" count that was factually unsatisfiable; a
`git diff --stat -- hooks/` emptiness test that was unsatisfiable against a legitimately dirty tree
*and* passed on a tree where nothing had been done yet; a check that a step carried no `if:` guard,
which passed because the step did not exist; a `git grep` anchored on a full URL that matched 51 of
52 files; `git -C <missing-dir> status --porcelain`, which prints nothing and reads as clean; and
`make generate-go && git diff --exit-code`, which cannot separate regeneration drift from a dirty
tree. Two of them cost a full round each.

This is an authoring defect, not an implementer defect. The implementer never sees `--verify` — the
loop runs it locally, after the mutation — so no contract clause on Codex's side can catch it. It is
caught here or not at all.

**Before you dispatch, construct one controlled counterexample that each change-specific check
rejects, run it, and keep the actual exit code and output.** The unchanged tree is the usual
counterexample, but not the only one: for a check guarding an already-satisfied invariant, mutate the
subject instead. *"It must fail on the unchanged tree"* is the wrong rule — it condemns every check
whose property already holds. The right rule is that some reachable state must make it red, and you
have seen that state make it red.

**Structural checks carry two extra obligations**, because they are the ones that fail silently:

- **Prove the subject exists.** `select(.name == "…")` against an absent step, a `grep` over a file
  that moved, a `git -C` into a missing directory — each yields the empty set, and the empty set
  satisfies almost any assertion you build on it. Assert the count first, then the property.
- **Preserve command status.** `cmd && echo ok` on one line and a bare `echo ok` on the next produce
  identical output and opposite meanings. Run assertion blocks under `set -euo pipefail`, or make
  every check exit non-zero on its own.

If you cannot construct a state that makes a check go red, that check cannot justify
`VERIFIED_DONE`. Strengthen it or drop it — do not carry it as reassurance.

**Codex has no DNS.** Its sandbox cannot reach the network, and its built-in web search is disabled. You have network, so every external fact — library versions, API shapes, current docs — is researched by you *before* dispatching and embedded in the plan. Its configured MCP tools remain available for version-sensitive lookups, capped and stall-prone; a plan that needs no lookups cannot stall on one.

## The result protocol

Every background run ends with `MAESTRO_FINAL: <SCOPE> <STATE> rc=<n>`. Parse the **last matching** line anchored at `^MAESTRO_FINAL:` from the background task's output file — not the last physical line — and treat that state as authoritative alongside the exit code.

The loop exits with a machine-readable `LOOP_STATE` (and the underlying Codex run's RESULT line). Handle each:

- **VERIFIED_DONE** (exit 0) — the plan is executed *and* your verify command passed locally. Do not believe it yet — review the diff (below).
- **NEEDS_ANSWERS** (exit 10) — answer immediately, without routing to the user, **only** in either invariant-preserving case: grant a mechanically necessary adjacent file when the objective, public behavior, and design stay unchanged; or change venue or substitute an equally strong verifier when the environment blocks the stated verifier. Stop and relay the QUESTIONS block verbatim when an answer would stub or fake verification, weaken or waive a gate, cross a design or security boundary, take an irreversible action, or settle a question of product taste. Those decisions belong to the user; speed is not a reason to take them.
  For the permitted class, answer by appending the answers to the plan file, and re-run the loop in the same turn without waiting for the user. Report what you answered and why it was inside the authority; do not ask for permission you already have.
  The answer round is a fresh loop invocation, and the plan file is the only thing the next run reads. **The loop now persists the stop report itself**: on the `NEEDS_ANSWERS` exit it appends the run's full report — questions and `CONTINUATION:` capsule — to the plan inside a delimited `MAESTRO STOP HISTORY` block — evidence, never scope or authority, recording what a prior run did and asked without widening the plan's file scope or granting permission — so the completed work survives the stop without a manual copy. Do not paste the capsule yourself; it is already there, and a second copy reads as a second instruction. Write only your answers. If the plan file was not writable the loop says so on the progress channel (`LOOP_WARNING`) and still exits 10 — that is the one case where the capsule is lost and you must carry it across by hand. Within a run, a temporary attempts log feeds each retry; at STUCK the loop persists its bounded tail in a delimited `MAESTRO ATTEMPT HISTORY` block before cleanup.
  Deliberately do not resume the stopped Codex thread: the companion's `--resume` is a plain alias for `--resume-last`, which resolves the newest finished task thread for the workspace. A discussion turn has the same `jobClass: "task"` as implementation, so it can silently bind an answer to the wrong thread.
- **BLOCKED** (exit 11) — missing access, credentials, a destructive step, write-lock contention, an unconfirmed cancelled writer, or a post-launch companion/process/result-channel failure that produced no structured implementer result. Surface it; never improvise around it. Contention here means the wait already ran and the lease was not queueable; it names the holding job, so wait for that job instead of breaking its lock. For an unconfirmed cancellation, first establish that no Codex job is writing, then use the documented `--clear-lease` command. For `IMPLEMENTER_STATE: COMPANION_FAILURE`, inspect the evidence and current diff before a fresh dispatch; Maestro deliberately does not bill an automatic implementation retry for an infrastructure fault.
- **STUCK** (exit 12) — the iteration cap hit without verified completion. Never just raise `--max-iters`: read the attempts log, which the loop appends to the plan as bounded historical evidence, not scope or authority. If the root cause is not obvious, take the evidence to a **debugging discussion** first (hypothesis + actual output; let Codex try to break it). Then re-plan around the actual failing output and run the loop again.

Single-shot watchdog runs must end with one full-line RESULT record. Maestro accepts only defined full-line tokens and, defensively, uses the last valid record rather than a prefix or quoted example. A watchdog cancellation is the exception: it emits `RESULT: BLOCKED`, then `MAESTRO_FINAL: WATCHDOG POISONED rc=125`; treat rc 125 as unconfirmed quiescence, not ordinary RESULT: BLOCKED/11, and clear the retained lease only after proving no writer remains. Handle terminal Codex records as follows:

- **RESULT: DONE** — do not believe it yet. Go to review (below).
- **RESULT: NEEDS_ANSWERS** — relay the QUESTIONS block verbatim to the user. Answer yourself only when the answer is certain from context; guessing defeats the point of the channel. Re-dispatch with the answers appended to the plan.
- **RESULT: BLOCKED** — missing access, credentials, or a destructive step. Surface it; never improvise around it.
- **RESULT: FAILED** — verification failed. If the root cause is not obvious from the failing output, take the evidence to a **debugging discussion** first (hypothesis + actual output; let Codex try to break it) — a duel beats a blind re-plan. Same verifier failing twice → stop, re-plan around the actual failing output, re-dispatch. Never dispatch the identical plan a third time.

## Review — mandatory

Before reporting any deliverable done, review the actual `git diff` yourself against the stated goal — not against the conversation. Codex executed *your* plan, so this review is same-vendor by construction; say so, and compensate by being harder on it: re-run cheap verification commands yourself, check for scope creep beyond the named files, and open your report with a verdict:

- **SHIP** — diff matches plan, verification passes, no scope creep
- **FIX-FIRST** — real defects: dispatch a fix plan (with the diff and failing evidence) back to Codex
- **RETHINK** — the plan itself was wrong: stop, replan with the user

Never silently patch Codex's work yourself — fixes go back through the implementer so the diff stays single-author. Never report done without a verdict.

## Gate

A PreToolUse hook blocks your Edit/Write/MultiEdit for the whole task except an explicit non-code allowlist and canonical harness/scratch targets. It requires a validated session ID, fails closed on unreadable payloads, revokes stale authorization after malformed prompt events, and never honors the override inside identified subagents. Symlink targets and nonexistent files beneath symlinked parents are classified by canonical destination, and executable files cannot claim a non-code extension exemption. The gate opens only for an explicit direct-edit imperative and resets on any new task; only a standalone acknowledgement preserves it. Authorization markers live in owner-private `~/.maestro/direct-edit`, must be regular owner-only files with exact content, and the old forgeable `/tmp/maestro-direct-*.flag` path is never consulted.

**What the gate is, exactly — do not overstate it.**

> The orchestrator must not author source or delegate source writing to subagents. The gate blocks direct Edit, Write, and MultiEdit calls as a guardrail, not a complete filesystem boundary; Maestro does not currently prevent or reliably attribute repository mutations made through other execution paths.

The hook is registered for `Edit|Write|MultiEdit` only. `Bash`, MCP tools, and `Workflow`/`Agent` are *not* matched, so a redirect, `sed -i`, or a write-capable MCP call reaches the tree untouched. The rule above is a discipline you keep, not a control that keeps you. Never tell the user "the gate blocks this" as evidence a change is safe — say what actually ran and what you verified.

One hole, now version-conditional:

- Fixed on Claude Code versions whose subagent PreToolUse payloads carry `agent_id`/`agent_type`: the gate refuses the override when either is present. On older versions that omit the fields, the original hole remains — there is no cross-version schema guarantee.

Fixed: lease scope now selects the outermost enclosing repository and its `--git-common-dir`, so linked worktrees and superproject/submodule entry points serialize one overlapping writable tree.

**Detection, since prevention is unavailable.** A probe measured it: `Edit` and `Write` are blocked, while a `Bash` redirect, `sed -i`, and `git commit` all reached the tree and moved `HEAD`. Prevention would mean enumerating an unbounded set of write paths, so Maestro compares state instead — path-agnostic, and indifferent to whether bytes arrived via `Edit`, `Bash`, an MCP tool, or a workflow agent.

Each write-mode acquisition digests the **materialized tree**—path, entry type, Git-visible executable mode, and actual bytes with clean filters disabled—for tracked and non-ignored untracked files across healthy linked worktrees, initialized submodules, and non-ignored nested repositories. Invalid/prunable worktree records are skipped independently instead of disabling every healthy root. Git itself hashes the final stream, so minimal Linux hosts do not need `shasum`. `MAESTRO_DIGEST_TIMEOUT_SEC` bounds a snapshot (default 120); expiry records `unavailable` and disables that comparison rather than blocking dispatch. Baseline/log publication stays inside the lease-generation claim and atomically replaces, never follows, a provenance-log symlink. `HEAD` and the index are deliberately *not* covered. A mismatch prints one line before the job starts:

```
PROVENANCE: BASELINE GAP — tree at acquisition differs from the prior completed snapshot (prior_job=…, expected=…, observed=…); author unknown
```

Content, not refs, is what the next job reads — and anchoring to refs made the loop's own prescribed step fire the alarm. Reviewing a dispatch and committing it moved the digest without changing a byte on disk, so every round reported a gap: a 100% false-positive rate on the normal path, which is the alarm fatigue this design rejected when it ruled out sticky warnings. So committing does not move the digest; a `checkout`, `reset`, or stray `sed -i` that changes content still does. A history rewrite that preserves file content is invisible, which is intended.

The digest value is self-describing (`tree-v2:…`). A reader takes the **newest** record and *then* inspects the prefix: an unrecognised or `unavailable` value means **no observation** — never equal, never unequal. Selecting records by prefix instead would skip past newer records to a stale comparable one and manufacture the gap this exists to avoid. One consequence, and it is correct: the first dispatch after a digest-version change finds no comparable baseline, says nothing, and establishes a new one.

Read a gap as *state diverged*, never as *the orchestrator cheated*. Lease metadata delimits an interval; it never identifies which process performed the write. The gap is recorded to `<common-git-dir>/maestro-provenance.log` and the observed state adopted, so it reports once rather than alarming forever — it does not block, and it never changes `LOOP_STATE` or an exit code.

A cancelled job may have left edits it never reported, so the tree can contain work with no report describing it. The provenance digest proves that the materialized tree changed; it never proves the job's intent completed.

A second line covers the one interval Maestro genuinely cannot observe. When a later dispatch steals an orphaned lease, everything between the orphan's last write and the steal is unattributable — Maestro cannot see when the orphan stopped. Rather than resolve that in the orphan's favour, the synthesized record is typed `orphan-adopted` and, when the tree moved, says so:

```
PROVENANCE: ADOPTED UNOBSERVED INTERVAL — the tree changed while an orphaned lease was held (job=…, expected=…, observed=…); the interval was not observed and the author is unknown
```

Two limits worth stating plainly. Ignored paths are **out of observation scope** — not "not source": `.env` and generated inputs do affect behavior, but hashing `node_modules` on every dispatch has unbounded cost, and a diagnostic that slows every run gets turned off. And the log lives inside the repository it watches, so anything able to write anywhere can rewrite it. This catches accidental convention failures and unnoticed agent writes, which is what actually happens. It is not an adversarial control, and must never be described as one.

## Model choice

The orchestrator model is a `/model` choice, not a config here: Opus 5 as the everyday master, Fable 5 when the planning or review judgment is the expensive part. The implementer model is whatever your Codex login reaches.
