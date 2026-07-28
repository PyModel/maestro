#!/usr/bin/env node
// UserPromptSubmit hook: (1) resets the direct-edit flag on a NEW task prompt,
// (2) sets it when the user explicitly asks Claude to edit code itself instead of
// delegating to Codex, (3) emits the orchestrator/implementer loop directive ONLY
// when the prompt carries a code/design signal. Firing on every turn — including
// "how much does X cost" — trains the loop to tune it out, so silence on unrelated
// prompts is what gives the directive its weight.
import fs from 'node:fs';
let payload = {};
try { payload = JSON.parse(fs.readFileSync(0, 'utf8')); } catch {}
const sid = payload.session_id || 'default';
const prompt = (payload.prompt || '').trim();
const flag = `/tmp/maestro-direct-${sid}.flag`;

// Explicit user override: "edit it yourself" / "don't delegate" → Claude may write
// source directly for this task. This is the only thing that opens the gate.
const DIRECT = /(edit it yourself|do it yourself|write it yourself|don'?t delegate|no codex|skip codex|yourself this time|kendin yap|sen yap|sen d[üu]zenle)/i;
if (DIRECT.test(prompt)) {
  try { fs.writeFileSync(flag, '1'); } catch {}
} else {
  // Only a SHORT standalone ack counts as continuation. "Okay, now fix this other
  // bug" starts with an approval word but carries a new task — it must reset.
  const isApproval =
    prompt.length <= 24 &&
    /^(onayl|onay|evet|devam|tamam|olur|approve|ok\b|okay\b|go\b|yes\b|proceed)/i.test(prompt);
  if (!isApproval) {
    try { fs.rmSync(flag, { force: true }); } catch {}
  }
}

// Meta trigger: picking the Codex model/effort is setup, not a code task — handle
// it before the code-signal logic so "codex model" never triggers the work loop.
if (/(codex (model|settings|effort|config)|pick (the )?codex|change codex|set codex)/i.test(prompt)) {
  process.stdout.write(
    'CODEX MODEL SETUP — ask the user which Codex model and reasoning effort the implementer\n' +
    'should use. Show current settings first:  bash ~/.claude/hooks/codex-model-select.sh --show\n' +
    'Effort guide: minimal/low = quick mechanical fixes, medium = default implementation,\n' +
    'high = debates, delicate refactors, final-review judgment.\n' +
    'Apply their pick:  bash ~/.claude/hooks/codex-model-select.sh <model> <effort>\n' +
    'and confirm in one line. One setting feeds both loops (discussions + implementation).'
  );
  process.exit(0);
}

// An explicit request always wins, regardless of what else the prompt says.
const onDemand = /delegate to codex|codex implement|have codex|ask codex|codex'?e yapt[ıi]r|grill|debate|sanity.?check|discuss with codex|talk to codex|second opinion|tart[ıi][şs]/i.test(prompt);

// Otherwise: does this prompt plausibly end in a source-code change? Config,
// markdown and questions deliberately miss — those Claude handles directly.
const CODE_SIGNAL = new RegExp([
  '\\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|rb|php|java|kt|swift|c|h|cpp|hpp|cc|vue|svelte|sql|sh)\\b',
  '/(code-review|apple-design|improve|quality-code|software-architecture-design|systematic-debugging)\\b',
  '\\b(implement|refactor|debug|crash|failing|regression|endpoint|schema|migration|architecture)\\b',
  '\\b(fix|bug|api|component|function|query|deploy|optimi[sz]e|design|build|add feature)\\b',
  '\\btest',
  '(hata|düzelt|mimari|tasarla|tasarım|özellik|fonksiyon|bileşen|sorgu|entegre|kodla|geliştir|çalışmıyor|patlıyor|bozuldu)',
].join('|'), 'i');

if (!onDemand && !CODE_SIGNAL.test(prompt)) process.exit(0);

process.stdout.write(
  'ORCHESTRATOR/IMPLEMENTER LOOP — this prompt carries a code/design signal.\n' +
  'You are the master: you debate, plan, dispatch, answer, and review. Codex argues and writes.\n' +
  '1) DEBATE FIRST when there is a design fork, an architecture choice, an unclear root cause,\n' +
  '   or the user asked to grill/debate: run the bidirectional discussion loop (read-only):\n' +
  '   bash ~/.claude/hooks/discussion-loop.sh --new "<topic>" <slug>\n' +
  '   bash ~/.claude/hooks/discussion-loop.sh --turn <your-turn-file> <slug>\n' +
  '   Grill Codex and let it grill you. Ends in CONVERGED / ESCALATE / 6-turn cap — never drift.\n' +
  '   The CONVERGED design becomes the Decisions section of your plan. Skip this for settled,\n' +
  '   obvious work — debating the trivial trains both sides to skim.\n' +
  '2) PLAN it yourself: objective, exact files in scope, concrete steps, constraints, and the\n' +
  '   verification commands Codex must run. Research any external facts with your own web\n' +
  '   tools FIRST (Codex runs with no web) and embed them in the plan.\n' +
  '3) DISPATCH the plan — default is the AUTONOMOUS LOOP (no babysitting between rounds):\n' +
  '   bash ~/.claude/hooks/implementer-loop.sh --plan <plan-file> --verify "<verify command>" [--max-iters 4]\n' +
  '   It re-dispatches with the actual failing output each round and re-runs your verify command\n' +
  '   locally after every DONE claim. Exits: 0 verified-done · 10 NEEDS_ANSWERS · 11 BLOCKED ·\n' +
  '   12 stuck-at-cap. Single-shot fallback: implementer-watchdog.sh --file <plan>.\n' +
  '   Both append the implementer contract themselves — do not retype it; never spawn a subagent.\n' +
  '4) HANDLE the loop state:\n' +
  '   VERIFIED_DONE → still review the diff yourself before believing it (next step).\n' +
  '   NEEDS_ANSWERS → relay the QUESTIONS verbatim to the user (answer yourself only\n' +
  '     when the answer is certain from context), append answers to the plan, re-run the loop.\n' +
  '   BLOCKED → surface the blocker; never improvise around credentials/destructive steps.\n' +
  '   STUCK → do not raise --max-iters. Root cause unclear → take the attempts log to a\n' +
  '     debugging discussion (step 1); otherwise re-plan and run the loop again.\n' +
  '5) REVIEW, mandatory before reporting done: read the actual git diff against your stated\n' +
  '   goal, run the verification commands again yourself when cheap, and open your report with\n' +
  '   a SHIP / FIX-FIRST / RETHINK verdict. FIX-FIRST → dispatch a fix plan back to Codex.\n' +
  '   You are reviewing your own plan executed — state that the review is same-vendor.\n' +
  '6) NEVER edit source files directly (the gate blocks it) unless the user says "edit it\n' +
  '   yourself". Details: ~/.claude/rules/orchestrator-implementer.md'
);
