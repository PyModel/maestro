#!/usr/bin/env node
// SessionStart hook: before any work begins, surface which Codex model + reasoning
// effort the implementer/discussion loops will use — and, when the user has armed
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
const ASK = path.join(HOME, '.maestro', 'ask-on-start');

let preamble = '';
try { preamble = fs.readFileSync(CONF, 'utf8').split(/^\[/m)[0]; } catch {}
const get = (k) => {
  const m = preamble.match(new RegExp(`^\\s*${k}\\s*=\\s*"([^"]+)"`, 'm'));
  return m ? m[1] : null;
};
const model = get('model') || '(Codex default — not pinned)';
const effort = get('model_reasoning_effort') || '(Codex default)';

const armed = fs.existsSync(ASK);
const source = payload.source || 'startup';

if (armed && source !== 'resume') {
  process.stdout.write(
    'MAESTRO SESSION SETUP — the user wants to pick the Codex implementer model before work starts.\n' +
    `Ask now, before the first task (one compact question, two picks):\n` +
    `  1) Codex model for this session — current: ${model}. Availability depends on the user's\n` +
    '     ChatGPT plan (e.g. gpt-5.6-sol if the plan reaches it).\n' +
    `  2) Reasoning effort — current: ${effort}. Guide: minimal/low = quick mechanical fixes,\n` +
    '     medium = default implementation, high = architecture debates, delicate refactors,\n' +
    '     final-review judgment.\n' +
    'Then apply their pick:  bash ~/.claude/hooks/codex-model-select.sh <model> <effort>\n' +
    'and confirm the new setting in one line. If the user says "keep current" or skips, proceed\n' +
    'without running anything. This one setting feeds BOTH loops — discussions and implementation\n' +
    'share the same Codex login.'
  );
} else {
  process.stdout.write(
    `Maestro: Codex implementer is model=${model}, effort=${effort}. ` +
    'Say "codex model" to change it before starting work' +
    (armed
      ? '.'
      : ' — or enable the session-start setup question: bash ~/.claude/hooks/codex-model-select.sh --ask-on-start on.')
  );
}
