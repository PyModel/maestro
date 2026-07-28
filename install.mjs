#!/usr/bin/env node
// Maestro installer — OS-agnostic (macOS / Linux / Windows-with-bash).
// Copies the hooks + rules into ~/.claude, idempotently merges the hook entries into
// settings.json (never clobbers your existing hooks), and offers to disable Codex web
// search. Safe to re-run: a second run changes nothing. Backs up any file it edits.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const REPO = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = path.join(HOME, '.claude');
const HOOKS = path.join(CLAUDE, 'hooks');
const RULES = path.join(CLAUDE, 'rules');
const SKILLS = path.join(CLAUDE, 'skills');
const SETTINGS = path.join(CLAUDE, 'settings.json');
const CODEX_CONF = path.join(HOME, '.codex', 'config.toml');
const withWorkflow = process.argv.slice(2).includes('--with-workflow');

const log = (...a) => console.log('[maestro]', ...a);
const warn = (...a) => console.warn('[maestro] WARN:', ...a);

function backup(file) {
  const bak = `${file}.maestro.bak`;
  if (fs.existsSync(file) && !fs.existsSync(bak)) {
    fs.copyFileSync(file, bak);
    log(`backed up ${path.basename(file)} → ${path.basename(bak)}`);
  }
}

function atomicCopy(src, dest) {
  const tmp = `${dest}.maestro-tmp-${process.pid}`;
  fs.copyFileSync(src, tmp);
  try { fs.chmodSync(tmp, fs.statSync(src).mode); } catch {}
  try {
    fs.renameSync(tmp, dest);
  } catch (error) {
    try { fs.unlinkSync(tmp); } catch {}
    throw error;
  }
}

// --- 1. Prerequisite: the codex-plugin-cc companion must exist ---
function findCompanion() {
  const base = path.join(CLAUDE, 'plugins', 'cache', 'openai-codex', 'codex');
  if (!fs.existsSync(base)) return null;
  const versions = fs.readdirSync(base).sort().reverse();
  for (const v of versions) {
    const p = path.join(base, v, 'scripts', 'codex-companion.mjs');
    if (fs.existsSync(p)) return p;
  }
  return null;
}
if (!findCompanion()) {
  warn('openai/codex-plugin-cc not found. Maestro needs it to run Codex as the implementer.');
  warn('Install it in Claude Code:  /plugin install codex@openai-codex   (and sign in with `codex login` / ChatGPT Plus).');
  warn('Continuing install anyway — hooks will be in place once the plugin is added.');
}

// --with-workflow ships rules/workflow.md plus the ralph-protocol skill it defers to,
// whose bounded execution loop runs on the ralph-loop plugin.
function hasRalphLoop() {
  return [
    path.join(CLAUDE, 'plugins', 'cache', 'claude-plugins-official', 'ralph-loop'),
    path.join(CLAUDE, 'plugins', 'marketplaces', 'claude-plugins-official', 'plugins', 'ralph-loop'),
  ].some((p) => fs.existsSync(p));
}
if (withWorkflow && !hasRalphLoop()) {
  warn('ralph-loop plugin not found. rules/workflow.md drives its bounded execution loop through it.');
  warn('Install it in Claude Code:  /plugin install ralph-loop@claude-plugins-official');
  warn('Continuing install anyway — the rest of the rule works, but /ralph-loop and /cancel-ralph will not exist.');
}

// --- 2. Copy hooks + rules ---
fs.mkdirSync(HOOKS, { recursive: true });
fs.mkdirSync(RULES, { recursive: true });
const HOOK_FILES = [
  'orchestrator-inject.mjs', 'orchestrator-gate.mjs', 'session-start.mjs',
  'implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh',
  'lib-companion.sh', 'codex-model-select.sh', 'codex-mcp-check.sh',
];
for (const f of HOOK_FILES) {
  atomicCopy(path.join(REPO, 'hooks', f), path.join(HOOKS, f));
}
for (const f of ['implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh', 'codex-model-select.sh', 'codex-mcp-check.sh']) {
  try { fs.chmodSync(path.join(HOOKS, f), 0o755); } catch {}
}
const RULE_FILES = ['orchestrator-implementer.md', 'coding-discipline.md'];
if (withWorkflow) RULE_FILES.push('workflow.md');
for (const f of RULE_FILES) {
  const src = path.join(REPO, 'rules', f);
  const dest = path.join(RULES, f);
  // you may already have a rule by this name — keep a copy before overwriting it
  if (fs.existsSync(dest) && !fs.readFileSync(dest).equals(fs.readFileSync(src))) backup(dest);
  atomicCopy(src, dest);
}
log(`copied ${HOOK_FILES.length} hooks → ~/.claude/hooks and ${RULE_FILES.length} rules → ~/.claude/rules`);

function installSkill(name) {
  const src = path.join(REPO, 'skills', name, 'SKILL.md');
  const destDir = path.join(SKILLS, name);
  const dest = path.join(destDir, 'SKILL.md');
  fs.mkdirSync(destDir, { recursive: true });
  if (fs.existsSync(dest) && !fs.readFileSync(dest).equals(fs.readFileSync(src))) backup(dest);
  atomicCopy(src, dest);
  log(`copied skills/${name} → ~/.claude/skills (loaded on demand, not every session)`);
}

installSkill('plan-authoring');

// workflow.md keeps the Ralph details out of the always-loaded context by pointing at
// this skill, so the two must ship together or that reference dangles.
if (withWorkflow) {
  installSkill('ralph-protocol');
} else {
  log('skipped rules/workflow.md + the ralph-protocol skill — add them with:  node install.mjs --with-workflow');
}

// --- 3. Idempotent settings.json merge (never clobbers existing hooks) ---
let settings = {};
if (fs.existsSync(SETTINGS)) {
  backup(SETTINGS);
  try { settings = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); }
  catch { warn('settings.json is not valid JSON; aborting merge. Fix it and re-run.'); process.exit(1); }
}
settings.hooks ??= {};

function hookCmd(script) { return `node "${path.join(HOOKS, script)}"`; }
function ensureHook(event, matcher, script) {
  settings.hooks[event] ??= [];
  const present = settings.hooks[event].some(b =>
    (matcher ? b.matcher === matcher : !b.matcher) &&
    (b.hooks || []).some(h => (h.command || '').includes(script)));
  if (present) return false;
  let block = settings.hooks[event].find(b => (matcher ? b.matcher === matcher : !b.matcher));
  if (!block) { block = matcher ? { matcher, hooks: [] } : { hooks: [] }; settings.hooks[event].push(block); }
  block.hooks ??= [];
  block.hooks.push({ type: 'command', command: hookCmd(script) });
  return true;
}
let added = 0;
added += ensureHook('PreToolUse', 'Edit|Write|MultiEdit', 'orchestrator-gate.mjs') ? 1 : 0;
added += ensureHook('UserPromptSubmit', null, 'orchestrator-inject.mjs') ? 1 : 0;
added += ensureHook('SessionStart', null, 'session-start.mjs') ? 1 : 0;
fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + '\n');
log(added ? `merged ${added} hook entr${added === 1 ? 'y' : 'ies'} into settings.json` : 'settings.json already had all hook entries (no change)');

// --- 4. Offer web_search="disabled" in Codex config ---
// The implementer must not hang on "Searching:" — the orchestrator does the research
// with its own web tools and embeds facts in the plan before dispatch.
if (fs.existsSync(CODEX_CONF)) {
  const conf = fs.readFileSync(CODEX_CONF, 'utf8');
  if (/^\s*web_search\s*=/m.test(conf)) {
    log('~/.codex/config.toml already sets web_search (no change)');
  } else {
    backup(CODEX_CONF);
    const note = '# maestro: disables Codex built-in web search so jobs cannot hang on "Searching:" — MCP servers ([mcp_servers.*]) are unaffected and stay available to both loops\nweb_search = "disabled"\n\n';
    fs.writeFileSync(CODEX_CONF, note + conf);
    log('added web_search="disabled" to ~/.codex/config.toml (prevents Codex hang; your MCP servers are unaffected)');
  }
} else {
  warn('~/.codex/config.toml not found — skipping web_search tweak. After `codex login`, add:  web_search = "disabled"');
}

// --- 4b. Arm the session-start model/effort picker (on by default; easy off) ---
const MAESTRO_DIR = path.join(HOME, '.maestro');
const ASK_FLAG = path.join(MAESTRO_DIR, 'ask-on-start');
if (!fs.existsSync(ASK_FLAG)) {
  fs.mkdirSync(MAESTRO_DIR, { recursive: true });
  fs.closeSync(fs.openSync(ASK_FLAG, 'a'));
  log('armed the session-start Codex model/effort picker (~/.maestro/ask-on-start)');
  log('  → disable it any time:  bash ~/.claude/hooks/codex-model-select.sh --ask-on-start off');
}

// --- 5. Windows note ---
if (process.platform === 'win32') {
  warn('Windows: the implementer watchdog is a bash script. Run Claude Code from Git Bash / WSL so it can execute; pure PowerShell cannot run it.');
}

log('done. Restart Claude Code (plain `claude`) so the rules and hooks load. See README for how the loop works.');
