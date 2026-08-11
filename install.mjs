#!/usr/bin/env node
// Maestro installer — validates first, then atomically publishes owned files and settings.
import crypto from 'node:crypto';
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
const MAESTRO_DIR = path.join(HOME, '.maestro');
const MANIFEST = path.join(MAESTRO_DIR, 'install-manifest.json');
const ASK_FLAG = path.join(MAESTRO_DIR, 'ask-on-start');
const cliArgs = process.argv.slice(2);
const unknownArgs = cliArgs.filter((arg) => arg !== '--with-workflow');
if (unknownArgs.length > 0) {
  console.error(`[maestro] WARN: unknown option: ${unknownArgs.join(', ')}`);
  console.error('usage: node install.mjs [--with-workflow]');
  process.exit(1);
}
const withWorkflow = cliArgs.includes('--with-workflow');

const HOOK_FILES = [
  'orchestrator-inject.mjs', 'orchestrator-gate.mjs', 'maestro-policy.mjs', 'session-start.mjs',
  'implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh', 'scout.sh',
  'lib-process.sh', 'lib-job-lock.sh', 'lib-companion.sh', 'lib-write-lease.sh', 'lib-write-turn.sh',
  'codex-model-select.sh', 'codex-mcp-check.sh',
];
const EXECUTABLE_HOOKS = new Set([
  'implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh', 'scout.sh',
  'codex-model-select.sh', 'codex-mcp-check.sh',
]);

const log = (...args) => console.log('[maestro]', ...args);
const warn = (...args) => console.warn('[maestro] WARN:', ...args);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const hashBytes = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const hashFile = (file) => hashBytes(fs.readFileSync(file));

function fail(message) {
  warn(message);
  process.exit(1);
}

function rejectSymlink(file, label) {
  if (fs.existsSync(file) && fs.lstatSync(file).isSymbolicLink()) {
    fail(`${label} is a symlink; refusing to replace it: ${file}`);
  }
}

function atomicWrite(file, bytes, mode) {
  const tmp = `${file}.maestro-tmp-${process.pid}`;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  try {
    fs.writeFileSync(tmp, bytes, { mode });
    if (mode !== undefined) fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, file);
  } catch (error) {
    try { fs.rmSync(tmp); } catch {}
    throw error;
  }
}

function atomicCopy(source, destination) {
  rejectSymlink(destination, 'managed destination');
  const mode = fs.statSync(source).mode;
  atomicWrite(destination, fs.readFileSync(source), mode);
}

function refreshBackup(file, suffix = '.maestro.bak') {
  if (!fs.existsSync(file)) return;
  const stat = fs.statSync(file);
  atomicWrite(`${file}${suffix}`, fs.readFileSync(file), stat.mode);
  log(`backed up ${path.basename(file)} → ${path.basename(file)}${suffix}`);
}

function snapshotFile(file) {
  if (!fs.existsSync(file)) return { existed: false };
  const stat = fs.statSync(file);
  return { existed: true, bytes: fs.readFileSync(file), mode: stat.mode };
}

function restoreSnapshot(file, snapshot) {
  if (snapshot.existed) atomicWrite(file, snapshot.bytes, snapshot.mode);
  else fs.rmSync(file, { force: true });
}

function readManifest() {
  if (!fs.existsSync(MANIFEST)) return { version: 1, files: {} };
  rejectSymlink(MANIFEST, 'ownership manifest');
  let value;
  try { value = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')); }
  catch { fail(`ownership manifest is invalid JSON; refusing to overwrite managed files: ${MANIFEST}`); }
  if (value?.version !== 1 || !isObject(value.files) ||
      Object.values(value.files).some((hash) => !/^[a-f0-9]{64}$/.test(hash))) {
    fail(`ownership manifest has an unsupported schema; refusing to overwrite managed files: ${MANIFEST}`);
  }
  return value;
}

function validateSettings(value) {
  if (!isObject(value)) fail('settings.json root must be an object; no files were changed.');
  if (value.hooks !== undefined && !isObject(value.hooks)) {
    fail('settings.json hooks must be an object; no files were changed.');
  }
  for (const [event, blocks] of Object.entries(value.hooks ?? {})) {
    if (!Array.isArray(blocks)) fail(`settings.json hooks.${event} must be an array; no files were changed.`);
    for (const block of blocks) {
      if (!isObject(block)) fail(`settings.json hooks.${event} contains a non-object block; no files were changed.`);
      if (block.hooks !== undefined && !Array.isArray(block.hooks)) {
        fail(`settings.json hooks.${event} block hooks must be an array; no files were changed.`);
      }
      if ((block.hooks ?? []).some((hook) => !isObject(hook))) {
        fail(`settings.json hooks.${event} contains a non-object hook; no files were changed.`);
      }
    }
  }
}

function readSettings() {
  if (!fs.existsSync(SETTINGS)) return {};
  rejectSymlink(SETTINGS, 'settings.json');
  let value;
  try { value = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); }
  catch { fail('settings.json is not valid JSON; no files were changed. Fix it and re-run.'); }
  validateSettings(value);
  return value;
}

function managedCommand(script) {
  return `node "${path.join(HOOKS, script)}" # maestro-managed:${script}`;
}

function legacyCommand(script) {
  return `node "${path.join(HOOKS, script)}"`;
}

function ensureHook(settings, event, matcher, script) {
  settings.hooks ??= {};
  settings.hooks[event] ??= [];
  const blocks = settings.hooks[event];
  const desired = managedCommand(script);
  const legacy = legacyCommand(script);
  for (const block of blocks) {
    if ((matcher ? block.matcher === matcher : !block.matcher) && Array.isArray(block.hooks)) {
      const existing = block.hooks.find((hook) => hook.type === 'command' && hook.command === desired);
      if (existing) return false;
      const old = block.hooks.find((hook) => hook.type === 'command' && hook.command === legacy);
      if (old) {
        old.command = desired;
        return true;
      }
    }
  }
  let block = blocks.find((candidate) => matcher ? candidate.matcher === matcher : !candidate.matcher);
  if (!block) {
    block = matcher ? { matcher, hooks: [] } : { hooks: [] };
    blocks.push(block);
  }
  block.hooks ??= [];
  block.hooks.push({ type: 'command', command: desired });
  return true;
}

function targetFiles() {
  const targets = HOOK_FILES.map((name) => ({
    key: `hooks/${name}`,
    source: path.join(REPO, 'hooks', name),
    destination: path.join(HOOKS, name),
  }));
  const rules = ['orchestrator-implementer.md', 'coding-discipline.md'];
  if (withWorkflow) rules.push('workflow.md');
  for (const name of rules) {
    targets.push({ key: `rules/${name}`, source: path.join(REPO, 'rules', name), destination: path.join(RULES, name) });
  }
  const skills = ['plan-authoring'];
  if (withWorkflow) skills.push('ralph-protocol');
  for (const name of skills) {
    targets.push({
      key: `skills/${name}/SKILL.md`,
      source: path.join(REPO, 'skills', name, 'SKILL.md'),
      destination: path.join(SKILLS, name, 'SKILL.md'),
    });
  }
  return targets;
}

function compareVersionsDesc(a, b) {
  const left = a.split('.');
  const right = b.split('.');
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const aPart = Number(left[index] ?? 0);
    const bPart = Number(right[index] ?? 0);
    if (Number.isNaN(aPart) || Number.isNaN(bPart)) return String(right[index]).localeCompare(String(left[index]));
    if (aPart !== bPart) return bPart - aPart;
  }
  return 0;
}

function findCompanion() {
  const base = path.join(CLAUDE, 'plugins', 'cache', 'openai-codex', 'codex');
  if (!fs.existsSync(base)) return null;
  for (const version of fs.readdirSync(base).sort(compareVersionsDesc)) {
    const candidate = path.join(base, version, 'scripts', 'codex-companion.mjs');
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function hasRalphLoop() {
  return [
    path.join(CLAUDE, 'plugins', 'cache', 'claude-plugins-official', 'ralph-loop'),
    path.join(CLAUDE, 'plugins', 'marketplaces', 'claude-plugins-official', 'plugins', 'ralph-loop'),
  ].some((candidate) => fs.existsSync(candidate));
}

function hasTopLevelTomlKey(config, key) {
  let multiline = null;
  const occurrences = (line, token) => line.split(token).length - 1;
  const keyPattern = new RegExp(`^\\s*${key}\\s*=`);
  for (const line of config.split(/\r?\n/)) {
    if (multiline !== null) {
      if (occurrences(line, multiline) % 2 === 1) multiline = null;
      continue;
    }
    const trimmed = line.trimStart();
    if (trimmed.startsWith('#') || trimmed === '') continue;
    if (trimmed.startsWith('[')) return false;
    if (keyPattern.test(line)) return true;
    if (occurrences(line, '"""') % 2 === 1) multiline = '"""';
    else if (occurrences(line, "'''") % 2 === 1) multiline = "'''";
  }
  return false;
}

// Validate every trust boundary before creating or replacing anything.
const settings = readSettings();
const hadManifest = fs.existsSync(MANIFEST);
const manifest = readManifest();
const targets = targetFiles();
for (const target of targets) {
  rejectSymlink(target.destination, 'managed destination');
  if (!fs.existsSync(target.destination)) continue;
  if (!fs.statSync(target.destination).isFile()) fail(`managed destination is not a regular file: ${target.destination}`);
  const current = hashFile(target.destination);
  const source = hashFile(target.source);
  const recorded = manifest.files[target.key];
  if (recorded ? current !== recorded && current !== source : current !== source) {
    fail(`refusing to overwrite modified or unowned file: ${target.destination}`);
  }
}
rejectSymlink(CODEX_CONF, 'Codex config');
rejectSymlink(`${SETTINGS}.maestro.bak`, 'settings backup');
rejectSymlink(`${CODEX_CONF}.maestro.bak`, 'Codex config backup');
rejectSymlink(ASK_FLAG, 'ask-on-start preference');

if (!findCompanion()) {
  warn('openai/codex-plugin-cc not found. Maestro needs it to run Codex as the implementer.');
  warn('Install it in Claude Code:  /plugin install codex@openai-codex   (and sign in with `codex login` / ChatGPT Plus).');
  warn('Continuing install anyway — hooks will be in place once the plugin is added.');
}
if (withWorkflow && !hasRalphLoop()) {
  warn('ralph-loop plugin not found. rules/workflow.md drives its bounded execution loop through it.');
  warn('Install it in Claude Code:  /plugin install ralph-loop@claude-plugins-official');
  warn('Continuing install anyway — the rest of the rule works, but /ralph-loop and /cancel-ralph will not exist.');
}

let settingsChanged = 0;
settingsChanged += ensureHook(settings, 'PreToolUse', 'Edit|Write|MultiEdit', 'orchestrator-gate.mjs') ? 1 : 0;
settingsChanged += ensureHook(settings, 'UserPromptSubmit', null, 'orchestrator-inject.mjs') ? 1 : 0;
settingsChanged += ensureHook(settings, 'SessionStart', null, 'session-start.mjs') ? 1 : 0;
const settingsBytes = `${JSON.stringify(settings, null, 2)}\n`;
const currentSettings = fs.existsSync(SETTINGS) ? fs.readFileSync(SETTINGS, 'utf8') : null;

let configBytes = null;
if (fs.existsSync(CODEX_CONF)) {
  const config = fs.readFileSync(CODEX_CONF, 'utf8');
  if (hasTopLevelTomlKey(config, 'web_search')) {
    log('~/.codex/config.toml already sets web_search (no change)');
  } else {
    const note = '# maestro: disables Codex built-in web search so jobs cannot hang on "Searching:" — MCP servers ([mcp_servers.*]) are unaffected and stay available to both loops\nweb_search = "disabled"\n\n';
    configBytes = note + config;
  }
} else {
  warn('~/.codex/config.toml not found — skipping web_search tweak. After `codex login`, add:  web_search = "disabled"');
}

const nextFiles = { ...manifest.files };
const mutablePaths = [...new Set([
  ...targets.map((target) => target.destination),
  SETTINGS,
  `${SETTINGS}.maestro.bak`,
  CODEX_CONF,
  `${CODEX_CONF}.maestro.bak`,
  MANIFEST,
  ASK_FLAG,
])];
const snapshots = new Map(mutablePaths.map((file) => [file, snapshotFile(file)]));
const publishedPaths = [];
const markPublished = (file) => {
  if (!publishedPaths.includes(file)) publishedPaths.push(file);
};

try {
  let filesChanged = 0;
  for (const target of targets) {
    const sourceHash = hashFile(target.source);
    const identical = fs.existsSync(target.destination) && hashFile(target.destination) === sourceHash;
    if (!identical) {
      atomicCopy(target.source, target.destination);
      markPublished(target.destination);
      filesChanged++;
    }
    if (target.key.startsWith('hooks/') && EXECUTABLE_HOOKS.has(path.basename(target.destination)) &&
        (fs.statSync(target.destination).mode & 0o777) !== 0o755) {
      fs.chmodSync(target.destination, 0o755);
      markPublished(target.destination);
    }
    nextFiles[target.key] = sourceHash;
  }
  log(filesChanged === 0
    ? 'managed hooks/rules/skills already matched installed bytes'
    : `published ${filesChanged} changed managed file${filesChanged === 1 ? '' : 's'} into ~/.claude`);

  if (currentSettings !== settingsBytes) {
    if (fs.existsSync(SETTINGS)) {
      refreshBackup(SETTINGS);
      markPublished(`${SETTINGS}.maestro.bak`);
    }
    const mode = fs.existsSync(SETTINGS) ? fs.statSync(SETTINGS).mode : 0o600;
    atomicWrite(SETTINGS, settingsBytes, mode);
    markPublished(SETTINGS);
  }
  log(settingsChanged ? `merged ${settingsChanged} managed hook entr${settingsChanged === 1 ? 'y' : 'ies'} into settings.json` : 'settings.json already had all managed hook entries');

  if (configBytes !== null) {
    refreshBackup(CODEX_CONF);
    markPublished(`${CODEX_CONF}.maestro.bak`);
    atomicWrite(CODEX_CONF, configBytes, fs.statSync(CODEX_CONF).mode);
    markPublished(CODEX_CONF);
    log('added web_search="disabled" to ~/.codex/config.toml (prevents Codex hang; your MCP servers are unaffected)');
  }

  atomicWrite(MANIFEST, `${JSON.stringify({ version: 1, files: nextFiles }, null, 2)}\n`, 0o600);
  markPublished(MANIFEST);
  if (!fs.existsSync(ASK_FLAG) && !hadManifest) {
    atomicWrite(ASK_FLAG, '', 0o600);
    markPublished(ASK_FLAG);
    log('armed the session-start Codex model/effort picker (~/.maestro/ask-on-start)');
    log('  → disable it any time:  bash ~/.claude/hooks/codex-model-select.sh --ask-on-start off');
  } else if (!fs.existsSync(ASK_FLAG)) {
    log('preserved ask-on-start=off from the previous installation');
  }
  if (!withWorkflow) {
    log('skipped rules/workflow.md + the ralph-protocol skill — add them with:  node install.mjs --with-workflow');
  }
  if (process.platform === 'win32') {
    warn('Windows: the implementer watchdog is a bash script. Run Claude Code from Git Bash / WSL.');
  }
  log('done. Restart Claude Code (plain `claude`) so the rules and hooks load.');
} catch (error) {
  const rollbackFailures = [];
  for (const file of [...publishedPaths].reverse()) {
    try { restoreSnapshot(file, snapshots.get(file)); }
    catch (rollbackError) { rollbackFailures.push(`${file}: ${rollbackError.message}`); }
  }
  warn(`installation failed; rolled back ${publishedPaths.length - rollbackFailures.length} published path(s): ${error.message}`);
  if (rollbackFailures.length > 0) {
    warn(`rollback incomplete — ${rollbackFailures.join('; ')}`);
  }
  process.exit(1);
}
