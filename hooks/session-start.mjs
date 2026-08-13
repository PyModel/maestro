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
const IMPL_MODEL = path.join(HOME, '.codex', 'maestro-impl-model');
const SCOUT_PIN = path.join(HOME, '.codex', 'maestro-scout');
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
let implModel = model;
let hasImplModelPin = false;
try {
  const candidate = fs.readFileSync(IMPL_MODEL, 'utf8').trim();
  if (/^[a-zA-Z0-9._-]+$/.test(candidate)) {
    implModel = candidate;
    hasImplModelPin = true;
  }
} catch {}
let scout = 'unpinned';
try {
  const pin = fs.readFileSync(SCOUT_PIN, 'utf8');
  const scoutModel = pin.match(/^model=([^\n]+)$/m)?.[1];
  const scoutEffort = pin.match(/^effort=([^\n]+)$/m)?.[1];
  if (/^[a-zA-Z0-9._-]+$/.test(scoutModel ?? '') &&
      /^(none|minimal|low|medium|high|xhigh)$/.test(scoutEffort ?? '')) {
    scout = `${scoutModel}/${scoutEffort}`;
  }
} catch {}

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
    `  1) Debate model for this session — current: ${model}.\n` +
    `  2) Debate/design effort — current: ${debateEffort}.\n` +
    `  3) Implementation effort — current: ${implEffort}.\n` +
    `  4) Implementation model — current: ${implModel}.\n` +
    'Implementation model — default: gpt-5.6-luna-max (with impl effort xhigh).\n' +
    'Alternatives: gpt-5.6-sol at low | medium | high; gpt-5.6-luna at xhigh;\n' +
    'gpt-5.6-terra at xhigh; gpt-5.6-terra-max. Availability depends on the\n' +
    "user's ChatGPT plan.\n" +
    'Debate default stays: model gpt-5.6-sol, effort max.\n' +
    'Effort tiers max/ultra are debate-only — the companion wrapper accepts only\n' +
    'none|minimal|low|medium|high|xhigh per write job, so a "max" tier on the\n' +
    'implementation side is expressed as a *-max model name, not as an effort.\n' +
    'Then apply their picks:  bash ~/.claude/hooks/codex-model-select.sh <model> <debate-effort> <impl-effort> <impl-model>\n' +
    'and confirm all four settings in one line. “Keep current” is valid only when the current pin is\n' +
    (hasDispatchPin
      ? 'complete; if the user declines or skips, preserve it and proceed.\n'
      : 'NOT complete: explain that Maestro cannot dispatch Codex until values are selected; do not claim setup succeeded.\n')
  );
} else {
  process.stdout.write(
    `Maestro: Codex pin is model=${model}, debate-effort=${debateEffort}, impl-effort=${implEffort}, impl-model=${implModel}${hasImplModelPin ? '' : ' (inherited)'}, scout=${scout}. ` +
    'Say "codex model" to change it before starting work' +
    (armed
      ? '.'
      : ' — or enable the session-start setup question: bash ~/.claude/hooks/codex-model-select.sh --ask-on-start on.')
  );
}
