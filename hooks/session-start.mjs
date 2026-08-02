#!/usr/bin/env node
// SessionStart hook: before any work begins, surface which Codex model + role-specific
// reasoning efforts the implementer/discussion loops will use — and, when the user has armed
// it (~/.maestro/ask-on-start, on by default after install), turn that into an
// actual setup question at the top of the session. On `resume` we only show the
// status line: re-asking on every resume would train the user to skip it.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

let payload = {};
try { payload = JSON.parse(fs.readFileSync(0, 'utf8')); } catch {}

const HOME = os.homedir();
const CONF = path.join(HOME, '.codex', 'config.toml');
const IMPL_EFFORT = path.join(HOME, '.codex', 'maestro-impl-effort');
const ASK = path.join(HOME, '.maestro', 'ask-on-start');

let preamble = '';
try { preamble = fs.readFileSync(CONF, 'utf8').split(/^\s*\[/m)[0]; } catch {}
const get = (k) => {
  const m = preamble.match(new RegExp(`^\\s*${k}\\s*=\\s*"([^"]+)"`, 'm'));
  return m ? m[1] : null;
};
const pinnedModel = get('model');
const pinnedDebateEffort = get('model_reasoning_effort');
const model = pinnedModel || '(Codex default — not pinned)';
const debateEffort = pinnedDebateEffort || '(Codex default — not pinned)';
const hasDispatchPin = Boolean(pinnedModel && pinnedDebateEffort);
let implEffort = 'medium';
try { implEffort = fs.readFileSync(IMPL_EFFORT, 'utf8').trim() || 'medium'; } catch {}

const armed = fs.existsSync(ASK);
const source = payload.source || 'startup';

if (typeof process.env.CLAUDE_ENV_FILE === 'string' && process.env.CLAUDE_ENV_FILE &&
    typeof payload.session_id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(payload.session_id)) {
  try {
    // The allowlist rejects every character that would require shell escaping.
    fs.appendFileSync(process.env.CLAUDE_ENV_FILE, `export MAESTRO_SESSION_ID=${payload.session_id}\n`);
  } catch {}
}

if (armed && source !== 'resume') {
  process.stdout.write(
    'MAESTRO SESSION SETUP — the user wants to pick the Codex model and role-specific reasoning tiers before work starts.\n' +
    'Show the current pin first:\n' +
    '  bash ~/.claude/hooks/codex-model-select.sh --show\n' +
    'Then use the AskUserQuestion tool as an interactive picker, not a prose question, to ask:\n' +
    `  1) Codex model for this session — current: ${model}. Availability depends on the user's\n` +
    '     ChatGPT plan (e.g. gpt-5.6-sol if the plan reaches it).\n' +
    `  2) Debate/design effort — current: ${debateEffort}.\n` +
    `  3) Implementation effort — current: ${implEffort}.\n` +
    'The real tiers are: none | minimal | low | medium | high | xhigh | max | ultra.\n' +
    'max and ultra are available for debate/design only because the companion wrapper cannot\n' +
    'express them as an explicit per-job implementation effort.\n' +
    'Then apply their picks:  bash ~/.claude/hooks/codex-model-select.sh <model> <debate-effort> <impl-effort>\n' +
    'and confirm the new settings in one line. “Keep current” is valid only when the current pin is\n' +
    (hasDispatchPin
      ? 'complete; if the user declines or skips, preserve it and proceed.\n'
      : 'NOT complete: explain that Maestro cannot dispatch Codex until values are selected; do not claim setup succeeded.\n')
  );
} else {
  process.stdout.write(
    `Maestro: Codex pin is model=${model}, debate-effort=${debateEffort}, impl-effort=${implEffort}. ` +
    'Say "codex model" to change it before starting work' +
    (armed
      ? '.'
      : ' — or enable the session-start setup question: bash ~/.claude/hooks/codex-model-select.sh --ask-on-start on.')
  );
}
