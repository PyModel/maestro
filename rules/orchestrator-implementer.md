# Orchestrator / Implementer Loop

**Orchestrator (master)** = the main Claude loop (Opus 5, or Fable 5 on the hardest tasks). Plans, dispatches, answers, reviews. Writes no source code by default.
**Implementer (hands)** = Codex, watchdog-wrapped, **write-enabled**. Executes written plans, runs verifiers, returns evidence and questions.

## Codex model & effort

At session start a hook asks which Codex model and reasoning effort to use (or shows the current pin). Both loops — discussion and implementation — share the setting. Mid-session, the user can say "codex model" to change it; apply with:

```
bash ~/.claude/hooks/codex-model-select.sh --show
bash ~/.claude/hooks/codex-model-select.sh <model> <effort>
```

Effort guide: minimal/low for quick mechanical fixes, medium for default implementation, **high for architecture debates, delicate refactors, and final-review judgment** — effort is where the quality of the *argument* comes from. Model availability depends on the user's ChatGPT plan; the script validates the name's shape only, and Codex itself rejects a model it cannot reach.

## Dispatch

```
# Claude Bash tool: run_in_background: true
bash ~/.claude/hooks/implementer-loop.sh --plan <plan-file> --verify "<verify command>" [--max-iters 4]   # default
# Claude Bash tool: run_in_background: true
bash ~/.claude/hooks/implementer-watchdog.sh --file <plan-file>                                            # single-shot fallback
```

These are the only ways to invoke the implementer. Always run the outer Bash call in the background: foreground Bash stdout/stderr is invisible to the user, while background-task output streams live. This is observed Claude Code behavior, not a preference. Both append the implementer contract (execute-the-plan discipline, structured RESULT lines, no web-search) to every dispatch — never retype it. Always use files: a plan carries exact steps and verification commands, and inlining that into shell quotes corrupts it. Write the plan to `/tmp` (the gate exempts `/tmp`).

**Prefer the loop.** It is autonomous between iterations: dispatch → parse RESULT → on a DONE claim, re-run your verify command *locally* (a claim is not proof) → on any failure, append the actual failing output to the next dispatch so Codex never repeats an approach blind. It only stops for the four states below — do not babysit it between rounds.

Write access is real — Codex edits your working tree directly. Scope the plan tightly; Codex is instructed to touch only the files the plan names. Never dispatch a plan you would not want applied verbatim.

**Orchestrator patience is mandatory.** After dispatching a write-mode job, yield immediately. Perform no workspace reads, verification commands, or diff review until that job reports completion. Reading a tree while Codex is still writing reviews a moving target and silently defeats the loop's final gate.

Write-mode dispatches also hold a workspace lock. A lock-contention `BLOCKED` names the holding job and PID; wait for that job to finish. Never break the lock by hand. Read-only discussion turns do not take this lock.

The watchdog layer auto-cancels after 5 minutes of no progress — the loop counts a hang as a failed attempt and re-dispatches with the evidence.

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

You drive, like a user would. Write your turn to a temp file — your position, your strongest evidence, actual diffs and failing output when relevant — the script appends it to the transcript at `/tmp/maestro-discussion-<slug>.md`, and Codex replies with a `STANCE: AGREE / PUSHBACK / ALTERNATIVE / REFRAME` line. Debate mode is **read-only**: nobody edits code while the design is still being argued. Codex shares no memory between calls — the transcript *is* the memory, so quote, never paraphrase.

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

## The result protocol

Every background run ends with `MAESTRO_FINAL: <SCOPE> <STATE> rc=<n>`. Parse the **last matching** line anchored at `^MAESTRO_FINAL:` from the background task's output file — not the last physical line — and treat that state as authoritative alongside the exit code.

The loop exits with a machine-readable `LOOP_STATE` (and the underlying Codex run's RESULT line). Handle each:

- **VERIFIED_DONE** (exit 0) — the plan is executed *and* your verify command passed locally. Do not believe it yet — review the diff (below).
- **NEEDS_ANSWERS** (exit 10) — relay the QUESTIONS block verbatim to the user. Answer yourself only when the answer is certain from context; guessing defeats the point of the channel. Append the answers to the plan file and re-run the loop.
- **BLOCKED** (exit 11) — missing access, credentials, a destructive step, or write-lock contention. Surface it; never improvise around it. Lock contention names the holding job; wait for that job instead of breaking its lock.
- **STUCK** (exit 12) — the iteration cap hit without verified completion. Never just raise `--max-iters`: read the attempts log, and if the root cause is not obvious, take the evidence to a **debugging discussion** first (hypothesis + actual output; let Codex try to break it) — a duel beats a blind re-plan. Then re-plan around the actual failing output and run the loop again.

Single-shot watchdog runs (the fallback) end with one RESULT line. Handle each:

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

A PreToolUse hook blocks your Edit/Write/MultiEdit on real source files (`.ts .tsx .js .py .go .rs …`) for the whole task. Never gated: `~/.claude`, `~/.codex`, `/tmp`, `~/Desktop`, and any non-code file — plan files, notes, and config are always yours to write. The gate opens only when the user explicitly says "edit it yourself" / "sen yap", and resets on the next task. Codex unreachable and the change is trivial → ask the user for direct-edit approval; don't route around the gate.

**What the gate is, exactly — do not overstate it.**

> The orchestrator must not author source or delegate source writing to subagents. The gate blocks direct Edit, Write, and MultiEdit calls as a guardrail, not a complete filesystem boundary; Maestro does not currently prevent or reliably attribute repository mutations made through other execution paths.

The hook is registered for `Edit|Write|MultiEdit` only. `Bash`, MCP tools, and `Workflow`/`Agent` are *not* matched, so a redirect, `sed -i`, or a write-capable MCP call reaches the tree untouched. The rule above is a discipline you keep, not a control that keeps you. Never tell the user "the gate blocks this" as evidence a change is safe — say what actually ran and what you verified.

One known hole, still real today:

- The direct-edit override keys off `session_id`, which subagents share (`agent_id` is what distinguishes them). One "edit it yourself" therefore opens the gate for every agent in a fan-out.

Fixed: the lease used to resolve via `git rev-parse --git-dir`, which is per-worktree, so N linked worktrees held N independent leases. It now anchors to `--git-common-dir` and serializes repository-wide.

**Detection, since prevention is unavailable.** A probe measured it: `Edit` and `Write` are blocked, while a `Bash` redirect, `sed -i`, and `git commit` all reached the tree and moved `HEAD`. Prevention would mean enumerating an unbounded set of write paths, so Maestro compares state instead — path-agnostic, and indifferent to whether bytes arrived via `Edit`, `Bash`, an MCP tool, or a workflow agent.

Each write-mode acquisition digests the **materialized tree** — path, type, mode and content for tracked and non-ignored untracked files, across every linked worktree and every initialized submodule — and compares it against the snapshot the previous dispatch left. `HEAD` and the index are deliberately *not* covered. A mismatch prints one line before the job starts:

```
PROVENANCE: BASELINE GAP — tree at acquisition differs from the prior completed snapshot (prior_job=…, expected=…, observed=…); author unknown
```

Content, not refs, is what the next job reads — and anchoring to refs made the loop's own prescribed step fire the alarm. Reviewing a dispatch and committing it moved the digest without changing a byte on disk, so every round reported a gap: a 100% false-positive rate on the normal path, which is the alarm fatigue this design rejected when it ruled out sticky warnings. So committing does not move the digest; a `checkout`, `reset`, or stray `sed -i` that changes content still does. A history rewrite that preserves file content is invisible, which is intended.

The digest value is self-describing (`tree-v2:…`). A reader takes the **newest** record and *then* inspects the prefix: an unrecognised or `unavailable` value means **no observation** — never equal, never unequal. Selecting records by prefix instead would skip past newer records to a stale comparable one and manufacture the gap this exists to avoid. One consequence, and it is correct: the first dispatch after a digest-version change finds no comparable baseline, says nothing, and establishes a new one.

Read a gap as *state diverged*, never as *the orchestrator cheated*. Lease metadata delimits an interval; it never identifies which process performed the write. The gap is recorded to `<common-git-dir>/maestro-provenance.log` and the observed state adopted, so it reports once rather than alarming forever — it does not block, and it never changes `LOOP_STATE` or an exit code.

A second line covers the one interval Maestro genuinely cannot observe. When a later dispatch steals an orphaned lease, everything between the orphan's last write and the steal is unattributable — Maestro cannot see when the orphan stopped. Rather than resolve that in the orphan's favour, the synthesized record is typed `orphan-adopted` and, when the tree moved, says so:

```
PROVENANCE: ADOPTED UNOBSERVED INTERVAL — the tree changed while an orphaned lease was held (job=…, expected=…, observed=…); the interval was not observed and the author is unknown
```

Two limits worth stating plainly. Ignored paths are **out of observation scope** — not "not source": `.env` and generated inputs do affect behavior, but hashing `node_modules` on every dispatch has unbounded cost, and a diagnostic that slows every run gets turned off. And the log lives inside the repository it watches, so anything able to write anywhere can rewrite it. This catches accidental convention failures and unnoticed agent writes, which is what actually happens. It is not an adversarial control, and must never be described as one.

## Model choice

The orchestrator model is a `/model` choice, not a config here: Opus 5 as the everyday master, Fable 5 when the planning or review judgment is the expensive part. The implementer model is whatever your Codex login reaches.
