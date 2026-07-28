# Coding Discipline

Applies to plans you write for Codex, and to any code you write when the user has opened the direct-edit gate.

## Simplicity
Minimum code that solves the problem. No speculative abstraction, no unrequested configurability, no error handling for impossible cases. Plan 50 lines, not 200.

## Surgical scope
- Plans name the exact files to touch. Don't dispatch refactors, reformats, or "improvements" to adjacent code.
- Clean up orphans **your** changes created (unused imports, dead vars). Leave pre-existing dead code alone — mention it instead.

## Verifiable goals
Turn the task into something checkable, then loop until it passes:
"fix the bug" → the plan includes a failing test to write first, then make pass. No deliverable is done until the verification commands have run and their output was read.

## When to ask
One rule, everywhere: ask only when two readings would produce materially different work and you cannot pick with a stated assumption. Otherwise assume, say so in one line, and proceed. Bug reports never need hand-holding — reproduce, fix, verify. Codex asks through the QUESTIONS channel; you ask the user directly.
