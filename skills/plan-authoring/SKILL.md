---
name: plan-authoring
description: How to write an implementation plan the Codex implementer can execute without guessing — the six sections, evidence discipline, scope fencing, and verification design. Read before dispatching any plan.
---

# Plan Authoring

The implementer shares none of your conversation context. It sees the plan file and nothing else. Every ambiguity you leave becomes a decision it makes alone, confidently, and applies to disk.

A plan you cannot finish writing means the decision is not formed yet. Form it, or ask the user the open question — *before* dispatching.

## The six sections

Five always, plus Decisions when a debate produced the design.

### 1. Objective
The outcome in one paragraph, and **the evidence that the problem is real**. Not "the model pin seems broken" — paste the proof:

```
`--show` reports model=gpt-5.6-sol effort=xhigh, while `status --json` for job
task-ms4vc08s-vbccvp records "request": { "model": null, "effort": null }.
```

Evidence in the Objective is what stops the implementer from re-litigating whether to do the work.

State what is **out** of scope here too, especially the adjacent thing a reasonable engineer would bundle. "A separate plan handles the streaming channel; do not implement it here."

### 2. Files
Exact absolute paths, and an explicit **do-not-touch list**. The negative list does more work than the positive one — it names the files a helpful implementer would otherwise improve.

### 3. Steps
Ordered, concrete, with the design decisions already made. Reference real line numbers and quote the current code you are changing. If a step says "refactor appropriately," it is not a step.

Where a step has a failure mode that a plausible implementation walks into, say so inline: *"a nested child that inherited FD 3 must NOT re-dup it — that redirects progress back into the parent's capture pipe and re-creates the bug."*

### 4. Constraints
Project conventions, things not to touch, and **facts you researched** so the implementer never needs to look them up (it has no web access):

- Style to match — *"this file parses JSON with sed/grep on purpose; do not add jq."*
- Interfaces that must not change — output prefixes, exit codes, function signatures other code parses.
- Prohibitions on speculative work: no config flags, no log-level systems, no abstraction for a single call site.

Pre-state these grants in every plan:

- **Scope grants** — name the adjacent files the implementer may touch without asking, and the condition that permits each one. Half of this channel's questions have been "may I also edit X"; answering it here avoids the round-trip.
- **Bounded defaults** — for every foreseeable judgment call, state the default to apply and require a `DEFAULT_APPLIED:` disclosure naming the grant.

Ask for the laziest implementation that satisfies the objective: no speculative abstraction, and no new dependency when the repository or standard library already suffices.

### 5. Verification
The exact commands, and **what passing looks like** for each. A verification step whose output nobody defined is decoration.

- Give pass criteria, not just commands: *"`/tmp/fake-argv.txt` must contain `--model` followed by the pinned model — read it from `--pin`, do not hardcode it."*
- Mark the steps that must pass or be fixed rather than reported: *"if 2, 5, 6, or 7 fails, fix and re-run rather than reporting DONE — those four are what make this change safe."*
- **Forbid destructive or expensive verifiers.** Name commands that mutate user state and say not to run them. Name anything that costs a real API call.
- Prefer a hermetic test over an observation. A fake companion that records its argv proves the flags are passed; reading the code proves nothing.
- End with a scope check (`git status --short`) and instruct: report an out-of-scope path, do not silently revert it.

### 6. Decisions *(only after a discussion)*
The converged design, **the losing alternatives, and why they lost**. This is the implementer's only window into a debate it was not part of — without it, it will reinvent a rejected option and think it is helping.

## Evidence discipline

- **Quote, never paraphrase.** Paste actual output, actual diffs, actual JSON. A paraphrased error is a hypothesis wearing a fact's clothes.
- **Embed researched facts.** You have web and MCP access; the implementer does not. A plan that requires no lookups cannot stall on one.
- **Distinguish verified from assumed.** If a claim is inference, label it. The implementer cannot tell your certainty from your prose.

## Notes for the implementer

A short closing section for hazards learned the hard way — the things that are not steps but will waste a run:

> `node <companion> task --help` does **not** print help. The companion has no arg validation on `task`; it dispatches `--help` to the model as a prompt and burns a real job.

## Anti-patterns

| Smell | Why it fails |
|---|---|
| "Refactor X appropriately" | No verifiable end state; the implementer invents one. |
| Verification that only builds/compiles | Compiling is not behaving. |
| No do-not-touch list | Scope creep is the default, not the exception. |
| Hardcoded expected values in tests | Passes today, lies after any config change. |
| Bundling independent changes | Two features in one diff means neither can be reverted alone. |
| A plan written after starting the work | The plan then documents what happened instead of directing it. |

## Sizing

One plan, one coherent change, reviewable in a single diff. If two parts could ship and be reverted independently, they are two plans — and if they touch the same files, the second **queues** behind the first. Concurrent write-mode dispatches against shared files interleave edits and are not recoverable.

Exception: a guard and the hazard it guards must ship together. Shipping a concurrency-enabling change without its lock ships the hazard.
