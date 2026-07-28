#!/usr/bin/env node
// Maestro uninstaller — removes the hooks + rules and strips ONLY the maestro
// hook entries from settings.json, leaving your other hooks untouched. Backs up
// settings.json before editing. Your .maestro.bak files are left in place.
// A rule is only deleted when it is still byte-identical to this repo's copy, so a
// file you wrote or edited yourself is never silently removed.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const REPO = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = path.join(HOME, '.claude');
const HOOKS = path.join(CLAUDE, 'hooks');
const RULES = path.join(CLAUDE, 'rules');
const SETTINGS = path.join(CLAUDE, 'settings.json');

const log = (...a) => console.log('[maestro]', ...a);
const MAESTRO_HOOKS = [
  'orchestrator-inject.mjs', 'orchestrator-gate.mjs', 'session-start.mjs',
  'implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh',
  'lib-companion.sh', 'codex-model-select.sh', 'codex-mcp-check.sh',
];
const RULE_FILES = ['orchestrator-implementer.md', 'coding-discipline.md', 'workflow.md'];
const SKILL_NAMES = ['ralph-protocol', 'plan-authoring'];

// --- 1. Remove hook files ---
for (const f of MAESTRO_HOOKS) {
  const p = path.join(HOOKS, f);
  if (fs.existsSync(p)) { fs.rmSync(p); log(`removed ${f}`); }
}

// --- 1b. Remove rules, but only the untouched ones this installer placed ---
for (const f of RULE_FILES) {
  const installed = path.join(RULES, f);
  const source = path.join(REPO, 'rules', f);
  if (!fs.existsSync(installed)) continue;
  if (!fs.existsSync(source)) { log(`kept ${f} — no repo copy to compare it against`); continue; }
  if (fs.readFileSync(installed).equals(fs.readFileSync(source))) { fs.rmSync(installed); log(`removed ${f}`); }
  else log(`kept ${f} — it differs from this repo's copy, so it is yours to delete`);
}

// --- 1c. Remove skills, same untouched-only rule ---
for (const name of SKILL_NAMES) {
  const installed = path.join(CLAUDE, 'skills', name, 'SKILL.md');
  const source = path.join(REPO, 'skills', name, 'SKILL.md');
  if (fs.existsSync(installed) && fs.existsSync(source)) {
    if (fs.readFileSync(installed).equals(fs.readFileSync(source))) {
      fs.rmSync(installed);
      try { fs.rmdirSync(path.dirname(installed)); } catch {} // only when it is now empty
      log(`removed skills/${name}`);
    } else log(`kept skills/${name} — it differs from this repo's copy, so it is yours to delete`);
  }
}

// --- 2. Strip maestro hook entries from settings.json (keep the rest) ---
if (fs.existsSync(SETTINGS)) {
  const bak = `${SETTINGS}.maestro-uninstall.bak`;
  if (!fs.existsSync(bak)) fs.copyFileSync(SETTINGS, bak);
  let s;
  try { s = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); }
  catch { log('settings.json is not valid JSON; left it alone.'); process.exit(0); }
  const isMaestro = (cmd) => MAESTRO_HOOKS.some((a) => (cmd || '').includes(a));
  for (const event of Object.keys(s.hooks || {})) {
    s.hooks[event] = (s.hooks[event] || [])
      .map((block) => ({ ...block, hooks: (block.hooks || []).filter((h) => !isMaestro(h.command)) }))
      .filter((block) => (block.hooks || []).length > 0);
    if (s.hooks[event].length === 0) delete s.hooks[event];
  }
  fs.writeFileSync(SETTINGS, JSON.stringify(s, null, 2) + '\n');
  log('stripped maestro hook entries from settings.json (your other hooks kept)');
}

// --- 3. Remove the session-start picker flag; leave config.toml pins to the user ---
{
  const askFlag = path.join(HOME, '.maestro', 'ask-on-start');
  if (fs.existsSync(askFlag)) {
    fs.rmSync(askFlag);
    try { fs.rmdirSync(path.join(HOME, '.maestro')); } catch {} // only when empty
    log('removed ~/.maestro/ask-on-start');
  }
}

log('done. web_search="disabled" and any model/model_reasoning_effort pins in ~/.codex/config.toml were left as-is — remove them by hand if you want Codex defaults back (a .maestro.bak is next to it).');
