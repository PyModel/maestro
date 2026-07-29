# Autonomous Maestro Fusion Design

**Date:** 2026-07-29
**Status:** Design approved; written-spec review pending

## Summary

Maestro will remain a native Claude Code product and coexist with its current hook-based orchestrator/implementer workflow. A fresh Claude Code session will offer a session-scoped autonomous Maestro mode. When enabled, one coding request runs through an adaptive Claude/Codex workflow without asking the user implementation questions mid-run.

Claude is **Maestro**: it routes work, forms the initial position, resolves Codex questions, fuses plans, reviews actual changes, and produces the final judgment. Codex remains the independent challenger and write-enabled implementer. Complex work receives an independent opinion, bounded debate when the opinions materially differ, a fused plan before implementation, and a fused evidence-backed report afterward. Settled mechanical work skips opinion and debate but still receives implementation verification and final result fusion.

The design borrows Fusion Harness's strongest structural ideas: file-backed prompt templates, independent opinions, exact-path artifact handoffs, explicit consensus and divergence, and correction prompts grounded in actual gate output. It does not port Fusion Harness's Pi extension or custom two-column terminal UI.

## Goals

1. Let a user enable autonomous Maestro mode once for the current Claude Code session.
2. Adaptively route settled work through a short path and complex work through opinion, debate, and plan fusion.
3. Let Claude answer every reversible Codex question without involving the user.
4. Preserve Maestro's existing write lease, watchdog, provenance detection, verification, and final diff review.
5. Produce a final fused result grounded in the request, plan, Codex report, actual diff, and verifier output.
6. Keep all model contracts in strict file-backed prompt templates rather than long shell or JavaScript string literals.
7. Remain bounded and fail closed when autonomy cannot proceed safely.

## Non-goals

- No Pi extension, standalone application, custom TUI, or two-column renderer.
- No replacement or removal of the current Claude Code installer and legacy workflow.
- No parallel write-capable agents in one working tree.
- No unbounded debate, implementation, review, or replanning loops.
- No autonomous authorization of destructive operations, credentials, or unsafe security-boundary changes.
- No claim that hooks form a security boundary; existing documented guardrail limitations remain.

## Terms

- **Maestro:** the main Claude Code model and conversation loop. It owns judgment and orchestration.
- **Codex:** the companion model reached through the installed Codex plugin. It challenges designs read-only and implements plans write-enabled.
- **Opinion:** an independent, read-only Codex response to the original request. Codex does not see Claude's position during this stage.
- **Debate:** a bounded exchange used only when the independent positions materially disagree or the root cause remains unclear.
- **Plan fusion:** Claude's canonical implementation plan synthesized from the request, repository evidence, both opinions, and any debate.
- **Result fusion:** Claude's final synthesis of the planned outcome, Codex's report, actual diff, local verification, and recorded assumptions.
- **Reversible question:** a decision that stays within the user's objective and can be changed through an ordinary later code edit without crossing a security, credential, destructive, or irreversible product boundary.

## Product Surface

### Session setup

On a fresh session, the existing SessionStart flow asks one native `AskUserQuestion` interaction covering:

1. Codex model.
2. Debate/design effort.
3. Implementation effort.
4. Whether to enable autonomous Maestro mode for this session.

A positive choice uses `hooks/maestro-mode.mjs` to write `/tmp/maestro-sessions/<safe-session-id>.mode`. The controller accepts only a sanitized session identifier and the literal values `enabled` or `legacy`; it never treats hook input as a path. A resumed instance of the same session preserves the mode and prints status rather than asking again. A new session has a new ID and asks again. Choosing `legacy` preserves today's Maestro behavior; it does not uninstall or disable the orchestrator/implementer loop.

The setup instruction includes the exact mode-setting command with the current session ID. Claude applies the selected model settings and session mode after the picker returns. Mode state is never used as a cross-session preference.

### Stage output

Claude Code uses its native conversation and background-task output. Stable text markers expose progress:

```text
MAESTRO: OPINION
MAESTRO: DEBATE
MAESTRO: PLAN_FUSION
MAESTRO: BUILD
MAESTRO: VERIFY
MAESTRO: RESULT_FUSION
```

A stage that is not needed is omitted. Meaning does not depend on color, icons, animation, or terminal width.

## Adaptive Routing

The existing machine-level code signal remains the gate that decides whether a prompt concerns code or design. When autonomous mode is enabled and a code signal is present, Claude applies the following semantic route.

### Short route

Use the short route only when all of these are true:

- The requested outcome is concrete and has one settled implementation path.
- The change is local and does not alter a public interface, schema, security boundary, concurrency contract, migration, or multi-module architecture.
- The failure, if any, has an evident root cause.
- A direct verifier can prove completion.

Flow:

```text
Claude plan -> Codex implementation loop -> local verification -> Claude result fusion
```

There is no independent opinion, debate, or pre-build two-source fusion on this route. The final result is still fused from Claude's plan/review and Codex's implementation evidence.

### Full fusion route

Use the full route when any of these apply:

- Competing valid designs or an architecture choice exist.
- The work changes a public interface, schema, migration, security boundary, concurrency contract, or multiple modules.
- The root cause is unclear or previous implementation attempts are stuck.
- The request has consequential product ambiguity.
- Claude cannot state a complete implementation plan without making a load-bearing assumption.

Flow:

```text
Claude independent position + Codex independent opinion
-> comparison
-> bounded debate when material divergence remains
-> Claude plan fusion
-> Codex implementation and verification loop
-> Claude diff review
-> Claude result fusion
```

Claude writes its position before launching the Codex opinion request. The opinion runner receives only the original request and relevant repository path, never Claude's position. This ordering prevents one model from anchoring the other.

If the opinions already agree on the load-bearing design, Claude records consensus and skips multi-turn debate. Cosmetic wording differences do not trigger debate.

## Prompt System

### Source and installed layout

Source templates live in `prompts/`. The installer copies Maestro-owned prompt files into `~/.claude/maestro/prompts/`. The uninstaller removes a prompt only while the installed copy remains byte-identical to the repository copy, matching existing rule and hook safety behavior.

The initial template set is:

```text
prompts/
├── USER_PROMPT_SESSION_SETUP.md
├── USER_PROMPT_MAESTRO.md
├── USER_PROMPT_OPINION.md
├── SYSTEM_PROMPT_DEBATE.md
├── USER_PROMPT_DEBATE.md
├── USER_PROMPT_PLAN_FUSION.md
├── USER_PROMPT_IMPLEMENTER.md
├── USER_PROMPT_CORRECTION.md
└── USER_PROMPT_RESULT_FUSION.md
```

`USER_PROMPT_MAESTRO.md` is the autonomous directive emitted by the UserPromptSubmit hook. `USER_PROMPT_IMPLEMENTER.md` contains the current implementer contract and wraps the fused plan. `USER_PROMPT_CORRECTION.md` carries prior failure evidence. The debate doctrine moves out of `discussion-loop.sh` into its system template.

### Rendering contract

One Node.js standard-library renderer, sourced as `hooks/prompt-render.mjs` and installed beside the other Maestro hooks, is shared by JavaScript hooks and Bash entry points. It accepts a known template filename and a JSON variable map on standard input, replaces exact `{{VARIABLE}}` placeholders, and writes the rendered prompt to standard output.

The renderer must:

- Reject paths outside the installed prompt directory.
- Exit nonzero when a template is missing.
- Exit nonzero when any placeholder remains unresolved.
- Treat values as inert text and never evaluate shell or JavaScript expressions.
- Preserve multiline content byte-for-byte except for placeholder substitution.
- Report the template name and missing variable without printing sensitive variable values.

Operational status lines and machine-readable state markers remain in code. Model instructions and role contracts live in templates.

## Run Artifacts and Data Flow

Each autonomous task receives `/tmp/maestro-runs/<safe-session-id>/<run-id>/`, where the run ID is generated rather than accepted from prompt text. It contains only the artifacts produced for that run:

```text
request.md
claude-opinion.md
codex-opinion.md
debate.md
fused-plan.md
codex-result.md
verification.txt
final-fusion.md
```

Stages receive exact absolute artifact paths through template variables. A downstream stage reads those paths directly and never scans `/tmp` or the repository to discover handoff material. Files are created only when their stage runs, so short-route runs omit opinion and debate files.

Artifacts are diagnostic and ephemeral. Prompts require agents to redact credentials, tokens, personal data, and secret environment values. Repository source needed for a decision is cited by path and line rather than copied wholesale into artifacts where practical.

### Opinion

A read-only `hooks/opinion-loop.sh` runner dispatches the original request to Codex using `USER_PROMPT_OPINION.md`. It has no write lease and no write-enabled companion mode. The complete response is saved to `codex-opinion.md`. Claude's pre-written position is saved separately.

### Debate

When needed, the debate starts from both complete opinions and the original request. The existing six-turn cap remains. Codex must open with a stance and attack the weakest load-bearing assumption. The debate ends in one of these states:

- `CONVERGED`: sufficient agreement exists for plan fusion.
- `DECISION_REQUIRED`: a reversible decision remains; Claude chooses and records the assumption.
- `BLOCKED`: proceeding requires credentials, destructive authorization, or an unsafe security decision.

The previous behavior of escalating reversible product taste to the user is replaced in autonomous mode by Claude's recorded decision. Legacy mode retains its existing escalation behavior.

### Plan fusion

Claude reads only the exact request, opinion, and debate artifacts. The fused plan follows Maestro's six-section plan contract:

1. Objective.
2. Files.
3. Steps.
4. Constraints.
5. Verification.
6. Decisions, including consensus, material divergence, selected alternative, and rejected alternatives.

Every autonomous judgment not directly specified by the user is recorded as:

```text
ASSUMPTION_APPLIED: <decision> | evidence: <repository or request basis> | reversible: <why>
```

The plan is canonical. Codex implements it rather than re-fusing or redesigning it.

### Implementation and correction

The existing `implementer-loop.sh`, watchdog, repository-wide write lease, and provenance digest remain the only write path. Autonomous mode passes the run artifact directory so Codex reports, attempt evidence, and local verification output survive for result fusion. Legacy invocations remain compatible.

On local verification failure, the correction prompt includes the exact command, exit status, and bounded output. Codex continues from the current working tree and may not restart or repeat a failed approach unchanged.

### Autonomous question handling

Codex may still return `NEEDS_ANSWERS`; suppressing questions would encourage guessing. The shell loop returns control to the main Claude turn. Claude then:

1. Reads the numbered questions and continuation capsule.
2. Answers from the original request, fused plan, repository evidence, and established project conventions.
3. Records each reversible choice as `ASSUMPTION_APPLIED`.
4. Appends the answers and continuation capsule to the canonical plan.
5. Re-runs the implementation loop without asking the user.

Claude may grant a mechanically necessary adjacent file only when the public behavior, objective, and safety boundaries remain unchanged. It may choose an equally strong non-destructive verifier when the environment blocks the planned verifier. It may not weaken or waive verification.

### Result fusion

After `VERIFIED_DONE`, Claude independently reads:

- The original request.
- The fused or short-route plan.
- Codex's report.
- The actual `git diff` and scope status.
- Local verification output.
- Recorded assumptions and debate decisions.

Codex's report is evidence to check, not a source of truth. Claude re-runs cheap verification where appropriate and compares the actual diff against the user-visible objective.

If the diff has an implementation defect, Claude emits a scoped fix plan and re-enters the implementation loop. If the plan itself was wrong, Claude performs one fresh full-fusion replan using the observed evidence. Result fusion cannot report success until review and verification pass.

The user-facing result has five stable sections:

1. Terminal verdict: `SHIP`, `BLOCKED`, or `STUCK`.
2. Fused result.
3. Verification evidence.
4. Assumptions applied.
5. Short consensus and divergence summary.

## Bounded Autonomy and Terminal States

Defaults remain fixed rather than user-configurable in the first implementation:

- Debate: maximum six Claude/Codex turns.
- Implementation: maximum four Codex dispatch rounds per plan.
- Plan recovery: maximum one evidence-based full replan.
- Final review repair: maximum two scoped fix-plan rounds across the run.

Terminal states:

- `SHIP`: requested behavior is present, scope review passes, and required verification succeeds.
- `BLOCKED`: missing credentials, destructive authorization, unsafe security decision, write-lease contention that cannot clear, or an external prerequisite prevents safe progress.
- `STUCK`: bounded debate, implementation, replan, or review-repair capacity is exhausted without proof of completion.

There is no user question in the middle of an autonomous run. A hard boundary ends the run with `BLOCKED`; exhausted recovery ends it with `STUCK`. Both include the exact evidence and next action.

## Safety and Compatibility

- Existing direct-edit authorization semantics remain unchanged. Autonomous mode does not let Claude write source.
- Codex remains the only source writer and must hold the repository-wide lease.
- Opinion and debate are read-only and never acquire the write lease.
- Ignored-path and provenance limitations remain documented honestly.
- No destructive Git command is authorized by autonomous mode.
- No prompt or artifact may log secrets, tokens, credentials, or personal data.
- Existing command lines continue to work without a run artifact directory.
- Disabling autonomous mode preserves legacy Maestro behavior.
- The new prompt directory follows installer backup, idempotence, and byte-identity removal rules.

## Testing Strategy

Tests remain end-to-end shell suites using fake companions and temporary repositories.

### Session lifecycle

Verify:

- A fresh session emits the combined setup request and starts with no enabled flag.
- Enabling mode creates only the current session's flag.
- Resume preserves and reports the current session mode without asking again.
- A different session ID does not inherit the flag.
- Declining mode retains legacy routing.

### Prompt rendering and installation

Verify:

- Every template renders with its required variables.
- Missing templates and unresolved placeholders fail nonzero and name the template.
- Multiline values survive exactly and are never shell-evaluated.
- Install is idempotent.
- Uninstall removes unchanged prompts but preserves user-modified prompt copies.

### Routing and opinions

Verify:

- Non-code prompts remain silent.
- Enabled autonomous mode emits the adaptive directive for code signals.
- Disabled mode emits the legacy directive.
- Opinion dispatch is read-only, receives the original request without Claude's opinion, and writes only its designated artifact.
- Material-divergence and aligned-opinion paths produce the expected debate state.

### Implementation state machine

Using the fake companion, verify:

- `NEEDS_ANSWERS` preserves questions and continuation data for Claude to answer and resume.
- Correction rounds receive exact local verifier output.
- Artifact paths are exact and isolated between runs.
- `BLOCKED` and `STUCK` remain terminal and machine-readable.
- Fix and replan caps prevent runaway execution.

### Regression coverage

Run the existing suites unchanged for write leases, shared Git directories, orphan handling, provenance detection, gate enforcement, preflight behavior, and commit invariance. The complete acceptance command remains:

```bash
bash tests/run.sh
```

The final implementation plan must also include syntax checks for each changed `.mjs` file and focused execution of every new or modified integration suite before the full run.

## Documentation Impact

README documentation will explain:

- Claude is Maestro and Codex is the implementer/challenger.
- How the startup picker enables autonomous mode for one session.
- The short and full-fusion routes.
- The no-user-in-the-middle autonomy policy and its `BLOCKED` boundary.
- Stable stages and terminal states.
- Prompt customization through file-backed templates.

The documented limits will continue to distinguish behavioral discipline from enforcement.

## Implementation Sequencing Constraint

Implementation must be split into small, reviewable commits. Prompt rendering and installation safety land before any hook depends on templates. Session mode lands before adaptive routing. Opinion and fusion behavior land before autonomous question handling. Existing lease and provenance behavior must remain green after every step.
