<div align="center">

# 🎼 Maestro

### **Claude is the master. Codex is the hands.**

*An orchestrator/implementer loop for Claude Code — Opus plans, debates, and reviews; Codex writes the code and proves it works.*

[![License](https://img.shields.io/badge/license-MIT-3DA639?style=for-the-badge)](LICENSE)
[![Claude](https://img.shields.io/badge/Claude-Opus%205%20·%20Fable%205-D97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://claude.com/claude-code)
[![Codex](https://img.shields.io/badge/Codex-write--enabled-412991?style=for-the-badge&logo=openai&logoColor=white)](https://openai.com/codex)
[![Bash](https://img.shields.io/badge/shell-bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)](hooks/)
[![Node](https://img.shields.io/badge/runtime-Node-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](install.mjs)
[![Platform](https://img.shields.io/badge/platform-macOS%20·%20Linux-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](#requirements)
[![Tests](https://img.shields.io/badge/tests-16%20suites-00B34A?style=for-the-badge)](tests/)
[![No API key](https://img.shields.io/badge/no%20API%20key-ChatGPT%20login-FF6B35?style=for-the-badge)](#requirements)

</div>

---

The orchestrator thinks through *what* and *how* — architecture, plans, reviews, talking to you — but never touches source files. Codex, dispatched through a watchdog, writes the code, runs the verification, and returns a structured result: evidence, or the questions it needs answered.

It runs on your existing **ChatGPT Plus / Codex login**. No OpenAI API key, no proxy, no second subscription.

```bash
git clone https://github.com/Pythoughts-labs/maestro.git
cd maestro && node install.mjs
```

> Restart Claude Code (plain `claude`) afterward so the rules and hooks load.

---

## Maestro in action

Run `node install.mjs`, restart Claude Code in your project terminal, then ask Claude directly to use Codex for the task. That's it — no Maestro skill or slash command is needed.

<div align="center">
  <img src="public/running.png" alt="Maestro dispatching a plan to Codex and monitoring the implementer loop" width="100%">
  <img src="public/session.png" alt="Maestro relaying Codex questions and tracking verified implementation progress" width="100%">
</div>

---

## Why

Some teams trust Claude's judgment more than its patience, and Codex's typing more than its plans. Maestro is for that split: the model you want making decisions (Opus 5 / Fable 5) holds the plan and the final review; the model you want grinding through edits holds the pen.

The loop also fixes what breaks in practice — Codex hanging mid-task, an implementer that guesses when the plan is ambiguous, a review that rubber-stamps its own plan.

## How it works

```
session start → pick model + debate/write efforts (or keep a complete pin)        ← the setup
your prompt
   → design fork or murky bug? Opus DEBATES Codex (read-only, transcript-carried)  ← the argument
       grill and be grilled, until CONVERGED / ESCALATE / 6-turn cap
   → Opus plans it: objective, files, steps, constraints, verification commands   ← the brain
   → the AUTONOMOUS LOOP runs Codex (write-enabled) until verified:               ← the hands
       dispatch → RESULT → local re-verification → failure evidence re-dispatched
       exits only: VERIFIED_DONE / NEEDS_ANSWERS / BLOCKED / STUCK-at-cap
   → questions relayed back to you, answers re-dispatched                          ← the loop
   → stuck with unclear root cause? the attempts log goes to the debate table
   → Opus reviews the actual diff (SHIP / FIX-FIRST / RETHINK)
   → done
```

### Exit codes

The loop never ends in prose. Every run finishes on a machine-readable state:

| Code | State | What it means | What you do |
|:---:|---|---|---|
| `0` | **VERIFIED_DONE** | Plan executed *and* the verify command passed locally | Review the diff — a claim is not proof |
| `10` | **NEEDS_ANSWERS** | Codex hit real ambiguity and stopped instead of guessing | Answer the `QUESTIONS:` block, re-run |
| `11` | **BLOCKED** | Missing access, a destructive step, lease contention, or an unconfirmed cancelled writer | Surface it; never improvise around it |
| `12` | **STUCK** | Hit the iteration cap without verification | Read the attempts log, re-plan — don't just raise the cap |

These codes describe `implementer-loop.sh`. The peer single-shot adapter uses rc `125` plus `MAESTRO_FINAL: WATCHDOG POISONED` for the same unconfirmed Write turn cancellation; `implementer-loop.sh` maps that outcome to `BLOCKED`/11.

One Implementation run acquires one Lease interval across every Write turn and local Verification transaction, then releases or retains it once at the terminal state. The peer watchdog adapter acquires the same interval for its single Write turn.

Write contention waits without arrival ordering only while the current lease has a confirmed release path. `MAESTRO_LOCK_WAIT_SEC` caps the wait (default 300 seconds; `0` disables it), and `MAESTRO_LOCK_WAIT_POLL_SEC` controls polling (default 5 seconds, minimum 1); invalid values disable waiting.

Foreground write supervisors update a separate lease heartbeat every `MAESTRO_LOCK_HEARTBEAT_INTERVAL_SEC` (default 20 seconds, minimum 1; invalid values use 20). `MAESTRO_LOCK_HEARTBEAT_STALE_SEC` controls when a missed heartbeat is reported (default 90 seconds; `0` disables staleness reporting; invalid values use 90). A stale heartbeat is only a recovery candidate: `--clear-lease` still refuses while the recorded owner process is alive or unidentifiable, or any repository-global companion writer is visible.

`MAESTRO_MAX_DISPATCH_SEC` is a hard ceiling: unset write jobs get 2400 seconds and read-only discussions get 1200; an explicit valid value is used exactly, while invalid input warns and falls back to 1200. Startup consumes this budget, poll sleeps are clipped to the nearest deadline, and one halfway warning continues the same job without claiming progress or creating a checkpoint. Idle time uses elapsed monotonic time rather than configured poll counts. `--max-idle` and `--poll` must be positive integers and are rejected before any lease or task starts. The local verifier has its own process-group deadline (`MAESTRO_VERIFY_TIMEOUT_SEC`, default 900 seconds), and `MAESTRO_COMPANION_TIMEOUT_SEC` bounds each companion call (default 120 seconds). Four consecutive empty **or malformed** statuses, or the hard ceiling during status loss, cancel and fail closed. Read-only status loss consumes its configured retry allowance; idle/deadline cancellation does not. A write cancellation—including one reported externally by the companion—poisons and retains the lease, ends the loop as `BLOCKED`, emits `UNREPORTED_PARTIAL` at the hard ceiling, and never starts a replacement writer. Once no Codex job is writing, recover with `bash hooks/implementer-loop.sh --clear-lease` (installed: `bash ~/.claude/hooks/implementer-loop.sh --clear-lease`). A metadata-less lease younger than five seconds is treated as an owner still initializing, not an orphan to clear.

All Maestro companion dispatches serialize for their full job lifetime on a per-workspace job lock; after confirming a stale lock's recorded job is terminal, recover with `bash hooks/implementer-loop.sh --clear-job-lock` (installed: `bash ~/.claude/hooks/implementer-loop.sh --clear-job-lock`).

A separately pinned scout runs cheap read-only repository reconnaissance through that same serialized companion job lock and fails closed when its scout pin is absent or invalid.

On every SessionStart source, the hook appends a validated `MAESTRO_SESSION_ID` export to `$CLAUDE_ENV_FILE`. The value is attribution only: the token, PID/process-start identity, and companion job liveness remain the ownership checks. A missing or invalid value is recorded as `unknown`; the session appears in lease metadata, contention/poison messages, and provenance records.

## Components

Installed under `~/.claude`; the entry adapters share focused lifecycle libraries.

| File | Role |
|---|---|
| **`session-start.mjs`** | Opens each session with model plus separate debate/write effort picks. Resumed sessions get a status line instead of a re-ask. |
| **`codex-model-select.sh`** | Serializes concurrent selectors and transactionally pins model plus debate/implementation effort, preserving config modes and top-level TOML scope. |
| **`codex-mcp-check.sh`** | Shows exactly which MCP servers your background Codex jobs inherit, env keys masked. |
| **`implementer-loop.sh`** | Implementation run adapter: one Lease interval across repeated Write turns and local Verification transactions, with failure evidence fed back. Bounded by `--max-iters` and a verifier deadline. |
| **`discussion-loop.sh`** | Explicitly read-only Discussion turns with collision-resistant workspace identity, private transcripts, sidecar turn state, and stale-lock recovery. |
| **`implementer-watchdog.sh`** | Peer single-shot adapter for one Write turn; it does not sit inside the loop adapter. |
| **`orchestrator-inject.mjs`** | Resets the direct-edit flag per task; states the loop only when the prompt carries a code/design signal. |
| **`orchestrator-gate.mjs`** | Blocks the orchestrator's `Edit`/`Write`/`MultiEdit` on source files. |
| **`lib-process.sh`** | Bounded process-group execution, output capture, lifecycle tick callbacks, and interruption. |
| **`lib-companion.sh`** | Companion transport and polling with explicit read/write mode and caller-owned result, profile, and evidence files. |
| **`lib-write-lease.sh`** | Lease interval ownership, repository digest, provenance, poison, release, and operator recovery. |
| **`lib-write-turn.sh`** | One deep Write turn interface shared by both implementation adapters. |

Plus the behavioral specs: **`orchestrator-implementer.md`** (read every session) and **`coding-discipline.md`** (useful standalone).

## Four design choices that matter

<details>
<summary><b>Grilling is structured, not vibes</b></summary>

Multi-turn debate between models fails in two known ways: endless courteous loops, and one side caving to sound cooperative. A mandatory stance line (`AGREE` / `PUSHBACK` / `ALTERNATIVE` / `REFRAME`) forces Codex to commit each turn; an `AGREE` still has to name the assumption most likely to be wrong; `REFRAME` gives it explicit license to reject the question itself. A 6-turn cap forces every debate to land on `CONVERGED` with stated assumptions, or `ESCALATE` to you with both cases intact.

The output isn't lost either — the converged design, the losing alternatives, and their rejection reasons become the **Decisions** section of the plan, so the implementer sees the debate it wasn't part of.
</details>

<details>
<summary><b>Write access is scoped by contract, reviewed by diff</b></summary>

Codex really edits your tree — that's the point. It may touch only the files the plan names, must report every file it changed, and *nothing it does is believed* until the orchestrator re-reads the actual `git diff` against the stated goal. Before its first edit, it must run `git status --short`, report the pre-existing dirty paths, preserve them, and confirm out-of-scope paths stayed untouched; this is an obligation and report, never a dirty-tree gate. Fixes never get silently patched by the orchestrator; they go back to Codex so the diff stays single-author.
</details>

<details>
<summary><b>Questions are a first-class channel, not a failure</b></summary>

A background job can't ask interactively, so the contract gives it a structured way to stop instead of guess: `RESULT: NEEDS_ANSWERS` plus a numbered `QUESTIONS:` block. An implementer that guesses is worse than one that asks.
</details>

<details>
<summary><b>The final review is mandatory, and honest about being same-vendor</b></summary>

The orchestrator reviews its own plan's execution. The spec says so out loud and compensates: fresh-eyes diff read, re-run the cheap verification yourself, check for scope creep, open with **SHIP / FIX-FIRST / RETHINK**. If you want a cross-vendor review, pair Maestro with a separate read-only advisor for the review step only.
</details>

## Research

Codex's *built-in* web search is disabled — that was the thing that kept hanging. Its **configured MCP servers (tavily, context7, …) stay available to both loops** for version-sensitive facts.

Research flows plan-first: the orchestrator pre-researches and embeds facts before dispatching, and Codex verifies only what turns out version-sensitive — capped at 2 lookups per run, no retries on stall. Verified facts come back labeled `verified via <mcp>: <fact>`, so the reviewer can trust them over either model's training data.

## Tests

```bash
bash tests/run.sh
```

Sixteen suites cover leases, liveness, installation ownership, model selection, gate authorization, discussions, provenance, and nested process cleanup. They drive real entry points end to end—acquiring leases, mutating repositories, signalling supervisors, and installing into isolated homes—rather than replacing lifecycle behavior with mocks.

They are slow on purpose: several suites wait on real lease timeouts.

## Requirements

- **Claude Code** (ships Node), with **Opus 5** (`claude-opus-5`) or **Fable 5** (`claude-fable-5`) as the session model — a `/model` choice, not a config here.
- The **Codex plugin** — `/plugin install codex@openai-codex` inside Claude Code.
- A **ChatGPT Plus / Codex login** — `codex login`. Not an API key.
- *Optional, for `--with-workflow`:* `/plugin install ralph-loop@claude-plugins-official`.

## Install

```bash
git clone https://github.com/Pythoughts-labs/maestro.git
cd maestro
node install.mjs
```

Or hand the repo to Claude Code and say: *"run `node install.mjs` in this repo."*

The installer validates options, settings, and every managed destination before changing anything. An ownership manifest records installed bytes; known-owned files update atomically, byte-identical reinstalls preserve file identity, and divergent or same-named user files cause a refusal instead of an overwrite. Ordinary late failures roll back every path published by that run; abrupt termination still leaves byte-atomic files that a rerun can reconcile. Settings/config backups refresh immediately before each merge, only a true top-level TOML `web_search` key satisfies the hang guard, disabled session prompts stay disabled on reinstall, and hook registrations carry exact Maestro markers rather than filename substring guesses.

<details>
<summary><b>Optional: the workflow rule</b></summary>

```bash
node install.mjs --with-workflow
```

Adds `workflow.md` plus the `ralph-protocol` skill it defers to: a bounded execution loop on top of the orchestration loop. Plans live in `tasks/todo.md`, a verifier hierarchy decides what counts as proof, and long jobs run through `/ralph-loop` capped at 8 iterations with an explicit stop line. The Ralph loop drives the *orchestration*; the implementer inside it is still Codex.
</details>

## Uninstall

```bash
node uninstall.mjs
```

Removes only files whose bytes still match the ownership manifest, strips only exact Maestro-marked commands from `settings.json`, and clears private direct-edit authorization markers. Modified hooks, rules, skills, foreign similarly named commands, and backups remain untouched; uninstall ownership does not depend on the current checkout version.

## Limits

Stated plainly, because a tool that overstates its guarantees is worse than one that has fewer.

- **The gate is a guardrail, not a boundary.** It is registered for `Edit|Write|MultiEdit` only. `Bash`, MCP tools, and `Workflow`/`Agent` are *not* matched, so a redirect or `sed -i` reaches the tree untouched. Authorization requires a validated session, lives under a private `~/.maestro/direct-edit` directory with owner/mode/content checks, ignores the legacy forgeable `/tmp` marker path, and is revoked by malformed prompt payloads. Scratch/non-code exemptions use canonical existing targets or parents so symlinks cannot change classification; executable files remain gated regardless of extension. The orchestrator not writing source remains a discipline, not a sandbox.
- **Provenance detection reports, it never attributes.** Each write-lease acquisition hashes actual materialized bytes with Git filters disabled, using Git itself rather than a platform-specific digest utility, across healthy worktrees, initialized submodules, and non-ignored nested repositories. One prunable worktree degrades independently. Baseline records publish before lease handoff, and log publication atomically replaces rather than follows a symlink. A mismatch names an interval—never a writer—and ignored paths remain out of scope on cost grounds. `MAESTRO_DIGEST_TIMEOUT_SEC` bounds each snapshot (default 120); timeout degrades that interval to `unavailable` and disables comparison rather than blocking dispatch. It is not an adversarial control.
- **Cancellation terminality is upstream.** The companion does not expose the brokered turn's terminal event to Maestro's shell. A cancelled write may therefore leave unreported edits, so Maestro stops and retains the lease instead of guessing that the turn is quiescent.
- **Same-vendor review.** The orchestrator reviews its own plan's execution.
- **Model pin depends on config being honored for debate max/ultra.** Model and wrapper-supported efforts are explicit per task. Debate max/ultra rely on the top-level Codex config because the companion cannot express them; implementation therefore rejects max/ultra instead of silently substituting another tier. A fresh unpinned install cannot dispatch until model and effort values are selected.
- **Plugin flag drift.** Write dispatches preflight the companion's global `--help` and refuse only when it describes `task` without `--write`; inconclusive help (empty, error, or no synopsis) proceeds rather than blocking work.
- **Windows.** The watchdog is a bash script — run Claude Code from Git Bash or WSL.
- **Codex on Plus.** The implementer model is whatever your ChatGPT plan's Codex can reach.

## License

MIT. See [LICENSE](LICENSE). © elkaix / Pythoughts Labs.
