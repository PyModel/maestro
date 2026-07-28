# Maestro

**Claude Opus 5 (or Fable 5) is the master — Codex is the hands.**

The orchestrator thinks through *what* and *how* — architecture, plans, reviews, talking to you — but never touches source files. Codex, dispatched through a watchdog, writes the code, runs the verification, and returns a structured result: evidence, or the questions it needs answered. A gate stops Claude from writing source at all, so the split is a mechanism, not a resolution.

It runs on your existing **ChatGPT Plus / Codex login**. No OpenAI API key, no proxy, no second subscription.

Maestro makes Claude the orchestrating brain and Codex the write-enabled implementer: Claude plans, debates, and reviews; Codex executes and verifies.

## Why

Some teams trust Claude's judgment more than its patience, and Codex's typing more than its plans. Maestro is for that split: the model you want making decisions (Opus 5 / Fable 5) holds the plan and the final review; the model you want grinding through edits holds the pen. The loop also fixes what breaks in practice — Codex hanging mid-task, an implementer that guesses when the plan is ambiguous, a review that rubber-stamps its own plan.

## How it works

```
session start → pick Codex model + effort (or keep current)                       ← the setup
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

Ten pieces, all installed under `~/.claude` (plus one shared library they source):

- **`session-start.mjs`** — a `SessionStart` hook that opens each new session with the Codex setup question: which model and which reasoning effort the implementer should run this session. Resumed sessions get a one-line status instead of a re-ask. Toggle with `codex-model-select.sh --ask-on-start off`.
- **`codex-model-select.sh`** — pins `model` + `model_reasoning_effort` in the top level of `~/.codex/config.toml` (TOML-safe, backed up, idempotent; keys inside `[tables]` never touched). One setting feeds both loops. Effort guide: minimal/low for mechanical fixes, medium default, high for debates and delicate judgment. Mid-session, saying *"codex model"* re-opens the picker.
- **`codex-mcp-check.sh`** — shows exactly which `[mcp_servers.*]` your background Codex jobs inherit from `~/.codex/config.toml`, with env keys masked, plus the built-in `web_search` status (disabled on purpose; MCPs unaffected). Run it once after setup to confirm tavily/context7 are visible to the loops.
- **`implementer-loop.sh`** — the autonomous heart. Wraps the watchdog in a bounded, evidence-fed, self-verifying loop: dispatch the plan → parse the `RESULT` → on a DONE claim, re-run your verify command *locally* (a claim is not proof) → on any failure, append the actual failing output to the next dispatch so Codex never repeats an approach blind. No babysitting between rounds: it exits only as `VERIFIED_DONE` (0), `NEEDS_ANSWERS` (10), `BLOCKED` (11), or `STUCK` at the iteration cap (12) with the full attempts log. `--max-iters 0` is prohibited — an unbounded write loop is a runaway, not autonomy.

- **`discussion-loop.sh`** — the bidirectional debate channel. Claude drives it like a user would: it writes its turn (position + strongest evidence) to a file, the script appends it to a persistent transcript and dispatches the *whole* transcript to Codex **read-only** — nobody edits code mid-argument. Codex shares no memory between calls, so the transcript *is* the memory. Every reply opens with a stance (`STANCE: AGREE / PUSHBACK / ALTERNATIVE / REFRAME`), every discussion must terminate in `CONVERGED` (agreed design + why the losers lost), `ESCALATE` (a genuine human fork, relayed verbatim), or the enforced 6-turn cap. After each reply the script prints a machine-readable `DISCUSSION_STATE: CONVERGED / ESCALATE / CONTINUE` so the orchestrator never guesses whether to stop. Transient job failures retry automatically (read-only retries are free); hangs don't (a hang is usually prompt-induced). A per-transcript lock stops racing turns, and an orphaned turn is replaced, not duplicated. Appends the discussion doctrine — steelman-then-attack, name the deciding risk, no manufactured objections *and* no manufactured agreement — to every turn so neither side drifts into politeness.

- **`implementer-watchdog.sh`** — the single-dispatch layer under the loop (and the fallback for one-shot work). Runs Codex **with `--write`**, polls its log, cancels it if it stalls for 5 minutes, and prints `IMPLEMENTER_STATE:` to stderr so callers never parse prose for the verdict. Appends the implementer contract — execute-this-plan-only, no scope creep, paste actual verification output, end with exactly one `RESULT:` line — to every dispatch. No blind retries here by design: a failed write-mode job may have left the tree half-edited, so re-dispatch belongs to the loop, which feeds the failure evidence back in.
- **`orchestrator-inject.mjs`** — a `UserPromptSubmit` hook that resets the direct-edit flag on each new task, opens the gate when you say *"edit it yourself"*, and states the loop — but only when the prompt actually carries a code/design signal. Everything else gets silence. A directive that fires on "how much does this cost" is one the model learns to skip, so the selectivity is what keeps it worth reading.
- **`orchestrator-gate.mjs`** — a `PreToolUse` hook that blocks Claude's Edit/Write/MultiEdit on real source-code files, period. Notes, configs, `~/.claude`, `~/.codex`, `/tmp`, and `~/Desktop` are exempt — plan files for dispatch are always Claude's to write. The gate opens only on an explicit user override and closes again on the next task.
- **`orchestrator-implementer.md`** — the behavioral spec Claude reads every session.
- **`coding-discipline.md`** — a short rule covering both plan-writing and any direct edits: minimum scope, surgical changes, verifiable goals. Independent of the loop; useful on its own.

Four design choices that matter:

- **Grilling is structured, not vibes.** Multi-turn debate between models fails in two known ways: endless courteous loops, and one side caving to sound cooperative. The discussion doctrine kills both — a mandatory stance line forces Codex to commit each turn, an AGREE still has to name the assumption most likely to be wrong, REFRAME gives it explicit license to reject the question itself, and the 6-turn cap forces every debate to land on `CONVERGED` with stated assumptions or `ESCALATE` to you with both sides' cases intact. Debugging duels run on evidence, not eloquence: the settling experiment gets named before convergence. The output isn't lost either — the CONVERGED design, losing alternatives, and rejection reasons become the **Decisions** section of the implementation plan, so the implementer sees the debate it wasn't part of.

- **Write access is scoped by contract, reviewed by diff.** Codex really edits your tree — that's the point. The discipline is that it may touch only the files the plan names, must report every file it changed, and *nothing it does is believed* until Opus re-reads the actual `git diff` against the stated goal. Fixes never get silently patched by the orchestrator; they go back to Codex so the diff stays single-author.
- **Questions are a first-class channel, not a failure.** A background Codex job can't ask interactively, so the contract gives it a structured way to stop instead of guess: `RESULT: NEEDS_ANSWERS` plus a numbered `QUESTIONS:` block — what it found, what it needs decided, what each answer implies. Opus relays them verbatim to you (or answers from context when certain) and re-dispatches with answers appended. An implementer that guesses is worse than one that asks.
- **The final review is mandatory, honest about being same-vendor.** Opus reviews Codex's execution of Opus's own plan — the spec says so out loud, and compensates: re-read the diff fresh against the goal, re-run cheap verification commands yourself, check for scope creep beyond the named files, and open with **SHIP / FIX-FIRST / RETHINK**. FIX-FIRST dispatches a fix plan back to Codex; RETHINK goes back to you.

Codex's *built-in* web search is disabled (that was the thing that kept hanging) — but its **configured MCP servers (tavily, context7, …) stay available to both loops** for version-sensitive facts: library versions, API changes, current docs. Research still flows plan-first — Opus pre-researches with its own MCPs/web and embeds facts before dispatching — and Codex verifies what turns out version-sensitive, capped at 2 lookups per turn/run with no retries on stall (the watchdog's idle cancel is the backstop). Verified facts come back labeled `verified via <mcp>: <fact>` so the reviewer can trust them over either model's training data. MCP config is per-side: Opus uses Claude Code's MCPs, Codex uses `~/.codex/config.toml` — `codex-mcp-check.sh` shows exactly what the background jobs inherit.

## Requirements

- **Claude Code** (ships Node), with **Opus 5** (the Max default; `claude-opus-5`) or **Fable 5** (`claude-fable-5`) as the session model — a `/model` choice, not a config here.
- The **Codex plugin** — `/plugin install codex@openai-codex` inside Claude Code.
- A **ChatGPT Plus / Codex login** — `codex login`. Not an API key.
- *Optional, only for `--with-workflow`:* the **ralph-loop plugin** — `/plugin install ralph-loop@claude-plugins-official`.

## Install

```bash
git clone <this repo>
cd maestro
node install.mjs
```

Or hand the repo to Claude Code and say: *"run `node install.mjs` in this repo."*

The installer is idempotent — re-running it changes nothing. It backs up `settings.json`, `config.toml`, and any rule file it would overwrite (`.maestro.bak`), merges its hooks without touching your existing ones, and offers to disable Codex web search. Restart Claude Code (plain `claude`) afterward so the rules and hooks load.

### Optional: the workflow rule

```bash
node install.mjs --with-workflow
```

Adds `workflow.md` plus the `ralph-protocol` skill it defers to: a bounded execution loop on top of the orchestration loop. Plans live in `tasks/todo.md`, a verifier hierarchy decides what counts as proof, and long jobs run through `/ralph-loop` capped at 8 iterations with an explicit `RESULT: VERIFIED_COMPLETE` / `RESULT: BLOCKED` stop line. The Ralph loop drives the *orchestration* (plan → dispatch → review); the implementer inside it is still Codex.

## Uninstall

```bash
node uninstall.mjs
```

Removes the hooks, strips only its own entries from `settings.json`, and leaves your backups in place. A rule is deleted only while it's still byte-identical to this repo's copy — edit one and the uninstaller keeps it and tells you.

## Limits

- **Model pin depends on config being honored:** the picker writes `model` / `model_reasoning_effort` into `~/.codex/config.toml`, which Codex reads by default. If your companion version overrides the model with its own flags, the pin won't take — check with `codex-model-select.sh --show` plus one dispatch's behavior, and say "codex model" to adjust.
- **Plugin flag drift:** the watchdog passes `--write` to the companion's `task` subcommand (the companion can also run read-only *without* it). If your plugin version renamed the flag, `node <companion> task --help` will tell you — it's one variable at the top of the script.
- **Same-vendor review:** the orchestrator reviews its own plan's execution. The spec forces a fresh-eyes diff read and a verdict to compensate, but if you want a cross-vendor final review, pair Maestro with a separate read-only advisor model for the review step only.
- **Windows:** the watchdog is a bash script. Run Claude Code from Git Bash or WSL; pure PowerShell can't execute it.
- **Codex on Plus:** the implementer model is whatever your ChatGPT plan's Codex can reach.

## License

MIT. See [LICENSE](LICENSE). © elkaix / Pythoughts Labs.
