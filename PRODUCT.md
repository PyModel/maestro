# Product

## Register

product

## Users

Developers working in Claude Code who want Claude's planning and review judgment combined with Codex's implementation throughput, without manually coordinating the two models between stages.

## Product Purpose

Maestro turns one coding request into a bounded autonomous workflow: Claude determines the approach, obtains an independent Codex opinion when the task warrants it, fuses the plan, delegates implementation, verifies the result, and returns an evidence-backed final judgment. Success means the user can start the loop once and receive either a verified result or a precise terminal blocker without answering implementation questions mid-run.

## Brand Personality

Decisive, rigorous, transparent. Maestro should feel like an experienced technical lead conducting an engineering process, not a collection of role-playing chatbots.

## Anti-references

- Opaque “AI magic” that hides decisions, disagreement, or verification evidence.
- Chatty multi-agent theater where personas generate more output than engineering value.
- Decorative dashboards or custom terminal spectacle that compete with the work.
- Unbounded retry loops or success claims based only on an agent's report.
- Workflows that interrupt the user for reversible implementation decisions.

## Design Principles

1. **Claude conducts; Codex performs.** Claude owns routing, judgment, assumptions, fusion, and review. Codex owns scoped implementation and independent technical challenge.
2. **Autonomy stays bounded.** The loop resolves reversible questions itself but stops on unsafe, destructive, or impossible work instead of guessing.
3. **Evidence outranks claims.** Actual diffs, command output, and local verification determine completion.
4. **Disagreement is useful data.** Material differences are preserved, debated when necessary, and resolved explicitly in the fused plan.
5. **Native behavior over spectacle.** Use Claude Code's existing hooks, questions, background tasks, and text output rather than introducing a separate application shell.

## Accessibility & Inclusion

The workflow is keyboard-native and uses stable plain-text stage and terminal-state labels. Meaning never depends on color, animation, symbols, or terminal width. Output stays concise enough to scan with assistive terminal tooling, and every failure includes actionable text.
