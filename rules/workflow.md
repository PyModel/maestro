# Workflow

## Planning
- Plan internally for anything with 3+ steps or an architectural decision. In `auto` mode don't stop for plan approval — plan, then dispatch.
- Stop and re-plan the moment something goes sideways instead of pushing the same approach.
- Ask for approval only before irreversible or outward-facing actions — and before dispatching any plan whose blast radius you can't bound by file scope.

## Delegation
Match the primitive to the task. Source-code implementation goes to Codex through the implementation adapters and their shared Write turn module — never to a subagent. Design and architecture debate goes to the discussion loop with Codex (read-only, transcript-carried) — never to a subagent either; an argument needs a peer with read access to the repo, not a summary. Reserve subagents for research and parallel exploration that would otherwise pollute main context — one focused task each, read-only. If one subagent can complete the task, use one rather than several. Never spawn a subagent to verify or double-check Codex's work — review is your job as orchestrator, done on the actual diff.

## Continuation loops
Implementation with a verifiable exit criterion runs on `implementer-loop.sh` by default — bounded (`--max-iters`), evidence-fed, self-verifying, autonomous between rounds. For longer orchestration arcs, use exactly one runtime continuation mechanism: `/goal` or Ralph, never both. Before presenting or starting any `/ralph-loop`, read the `ralph-protocol` skill. A Ralph loop drives the *orchestration* loop (debate → plan → dispatch → review); the implementer inside it still uses the loop adapter and shared Write turn module — never give Ralph its own path to code.

## Verification
Never mark a task complete without proving it works: Codex runs the plan's verification commands and pastes output; you re-read the diff and re-run cheap checks yourself. Report failures with their actual output; report skipped checks as skipped.

## Elegance check
For non-trivial plans, pause once before dispatching: is there a more elegant design? If the plan feels hacky, redo it now — a hacky plan comes back as hacky code, applied to disk. Skip this for obvious fixes.

## Self-improvement
After any correction from the user, save a `type: feedback` memory capturing the pattern, the why, and how to apply it. Recalled feedback memories are the single source of truth — no separate lessons file.

## Task tracking
For multi-step implementation work, keep `tasks/todo.md` with checkable items and mark them off as you go. The `ralph-protocol` skill has the full template.

## Git & PR
- One branch per task: `feat/ fix/ chore/ refactor/` + kebab-case summary. Never commit straight to `main`.
- Conventional commit subjects: `feat: … / fix: … / refactor: … / test: … / chore: … / docs: …`.
- Before `gh pr create`: tests green, lint clean, and `git diff origin/main` reviewed line by line (by you, the orchestrator — that review is the loop's final gate).
- Open as `--draft` while work continues, `gh pr ready` when it is reviewable.
- Keep a PR under ~400 changed lines. Bigger work gets split into stacked PRs.
- Sync with `git rebase origin/main`; push rewritten history only with `--force-with-lease`, never bare `--force`.
- PR body answers three things: what changed, why, how it was verified. Link the issue.
- Delete the branch after merge; never reuse a merged branch.

## Core
No laziness. Find root causes, no temporary patches.
