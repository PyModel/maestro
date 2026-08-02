#!/usr/bin/env node
// UserPromptSubmit hook: (1) resets the direct-edit flag on a NEW task prompt,
// (2) sets it when the user explicitly asks Claude to edit code itself instead of
// delegating to Codex, (3) emits the orchestrator/implementer loop directive ONLY
// when the prompt carries a code/design signal. Firing on every turn — including
// "how much does X cost" — trains the loop to tune it out, so silence on unrelated
// prompts is what gives the directive its weight.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  NONCODE_EXTENSIONS,
  directiveOpensGate,
  isValidSessionId,
} from './maestro-policy.mjs';

const MAESTRO_DIR = path.join(os.homedir(), '.maestro');
const FLAG_DIR = path.join(MAESTRO_DIR, 'direct-edit');
const FLAG_PATTERN = /^maestro-direct-[A-Za-z0-9_-]{1,64}\.flag$/;

function ensurePrivateDirectory(directory) {
  try {
    const stat = fs.lstatSync(directory);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('unsafe authorization directory');
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    fs.mkdirSync(directory, { mode: 0o700 });
  }
  fs.chmodSync(directory, 0o700);
}

function ensureFlagDirectory() {
  ensurePrivateDirectory(MAESTRO_DIR);
  ensurePrivateDirectory(FLAG_DIR);
}

function clearAllFlags() {
  let ok = true;
  try {
    for (const name of fs.readdirSync(FLAG_DIR)) {
      if (!FLAG_PATTERN.test(name)) continue;
      try { fs.rmSync(`${FLAG_DIR}/${name}`, { force: true }); } catch { ok = false; }
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') ok = false;
  }
  return ok;
}

function failClosed(message) {
  clearAllFlags();
  process.stderr.write(`ORCHESTRATOR INJECT: ${message}; direct-edit authorization revoked.\n`);
  process.exit(2);
}

let payload;
try { payload = JSON.parse(fs.readFileSync(0, 'utf8')); }
catch { failClosed('invalid hook JSON'); }
if (!payload || typeof payload !== 'object' || Array.isArray(payload) ||
    !isValidSessionId(payload.session_id) || typeof payload.prompt !== 'string') {
  failClosed('invalid hook payload');
}
const sid = payload.session_id;
const prompt = payload.prompt.trim();
const flag = path.join(FLAG_DIR, `maestro-direct-${sid}.flag`);

// Explicit user override: "edit it yourself" / "don't delegate" → Claude may write
// source directly for this task. This is the only thing that opens the gate.
if (directiveOpensGate(prompt)) {
  try {
    ensureFlagDirectory();
    const descriptor = fs.openSync(
      flag,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC |
        (fs.constants.O_NOFOLLOW ?? 0),
      0o600
    );
    try {
      fs.fchmodSync(descriptor, 0o600);
      fs.writeFileSync(descriptor, '1\n');
    } finally { fs.closeSync(descriptor); }
  } catch {
    failClosed('could not create a safe authorization marker');
  }
} else {
  // Only a SHORT standalone ack counts as continuation. "Okay, now fix this other
  // bug" starts with an approval word but carries a new task — it must reset.
  const isApproval =
    /^(?:onayl|onay|evet|devam|tamam|olur|approve|ok|okay|go|yes|proceed)[.!]?$/i.test(prompt);
  if (!isApproval) {
    try { fs.rmSync(flag, { force: true }); }
    catch { failClosed('could not revoke direct-edit authorization'); }
  }
}

// Meta trigger: picking the Codex model/effort is setup, not a code task — handle
// it before the code-signal logic so "codex model" never triggers the work loop.
if (/(codex (model|settings|effort|config)|pick (the )?codex|change codex|set codex)/i.test(prompt)) {
  process.stdout.write(
    'CODEX MODEL SETUP — ask the user for the Codex model and separate role-specific efforts.\n' +
    'Show current settings first:  bash ~/.claude/hooks/codex-model-select.sh --show\n' +
    'Debate effort governs read-only discussions; implementation effort governs write jobs.\n' +
    'minimal/low = quick mechanics, medium = default, high = delicate work; max/ultra are\n' +
    'debate-only because the companion cannot express them for write jobs.\n' +
    'Apply their picks:  bash ~/.claude/hooks/codex-model-select.sh <model> <debate-effort> <impl-effort>\n' +
    'and confirm all three values in one line.'
  );
  process.exit(0);
}

// An explicit request always wins, regardless of what else the prompt says.
const onDemand = /delegate to codex|codex implement|have codex|ask codex|codex'?e yapt[ıi]r|grill|debate|sanity.?check|discuss with codex|talk to codex|second opinion|tart[ıi][şs]/i.test(prompt);

// Otherwise: does this prompt plausibly end in a source-code change? Config,
// markdown and questions deliberately miss — those Claude handles directly.
const fileTokens = prompt.match(/[\w./-]*\.[A-Za-z][A-Za-z0-9_]{0,11}\b/g) || [];
const hasCodeFile = fileTokens.some((token) => {
  const extension = token.slice(token.lastIndexOf('.') + 1).toLowerCase();
  return !NONCODE_EXTENSIONS.has(extension);
});
const CODE_SIGNAL = new RegExp([
  '/(code-review|apple-design|improve|quality-code|software-architecture-design|systematic-debugging)\\b',
  '\\b(implement|refactor|debug|crash|failing|regression|endpoint|schema|migration|architecture)\\b',
  '\\b(fix|bug|api|component|function|query|deploy|optimi[sz]e|design|build|add feature)\\b',
  '\\btest',
  '(hata|düzelt|mimari|tasarla|tasarım|özellik|fonksiyon|bileşen|sorgu|entegre|kodla|geliştir|çalışmıyor|patlıyor|bozuldu)',
].join('|'), 'i');

if (!onDemand && !hasCodeFile && !CODE_SIGNAL.test(prompt)) process.exit(0);

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
  '   NEEDS_ANSWERS → answer without interrupting only to grant a mechanically necessary adjacent file\n' +
  '     with unchanged design/behavior, or to substitute an equally strong verifier/venue. Otherwise\n' +
  '     relay QUESTIONS verbatim. Append authorized answers to the plan and re-run the loop.\n' +
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
