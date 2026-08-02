#!/usr/bin/env node
// Maestro uninstaller — removes only bytes recorded in the ownership manifest and
// exact marked hook commands. Divergent files are preserved.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const CLAUDE = path.join(HOME, '.claude');
const HOOKS = path.join(CLAUDE, 'hooks');
const SETTINGS = path.join(CLAUDE, 'settings.json');
const MAESTRO_DIR = path.join(HOME, '.maestro');
const MANIFEST = path.join(MAESTRO_DIR, 'install-manifest.json');
const AUTHORIZATION_DIR = path.join(MAESTRO_DIR, 'direct-edit');
const AUTHORIZATION_PATTERN = /^maestro-direct-[A-Za-z0-9_-]{1,64}\.flag$/;
const HOOK_FILES = [
  'orchestrator-inject.mjs', 'orchestrator-gate.mjs', 'maestro-policy.mjs', 'session-start.mjs',
  'implementer-watchdog.sh', 'implementer-loop.sh', 'discussion-loop.sh',
  'lib-companion.sh', 'codex-model-select.sh', 'codex-mcp-check.sh',
];

const log = (...args) => console.log('[maestro]', ...args);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

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

function refreshBackup(file, suffix) {
  if (!fs.existsSync(file)) return;
  atomicWrite(`${file}${suffix}`, fs.readFileSync(file), fs.statSync(file).mode);
}

function managedPath(key) {
  if (path.isAbsolute(key) || key.split('/').includes('..') ||
      !/^(hooks|rules|skills)\//.test(key)) return null;
  const destination = path.resolve(CLAUDE, key);
  const prefix = `${path.resolve(CLAUDE)}${path.sep}`;
  return destination.startsWith(prefix) ? destination : null;
}

function readManifest() {
  if (!fs.existsSync(MANIFEST) || fs.lstatSync(MANIFEST).isSymbolicLink()) return null;
  try {
    const value = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
    if (value?.version !== 1 || !isObject(value.files)) return null;
    return value;
  } catch {
    return null;
  }
}

function managedCommand(script) {
  return `node "${path.join(HOOKS, script)}" # maestro-managed:${script}`;
}

function legacyCommand(script) {
  return `node "${path.join(HOOKS, script)}"`;
}

function readSettingsForUninstall() {
  if (!fs.existsSync(SETTINGS)) return null;
  if (fs.lstatSync(SETTINGS).isSymbolicLink()) {
    log('settings.json is a symlink; refusing a partial uninstall.');
    process.exit(1);
  }
  let settings;
  try { settings = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); }
  catch {
    log('settings.json is invalid JSON; refusing a partial uninstall.');
    process.exit(1);
  }
  if (!isObject(settings) || (settings.hooks !== undefined && !isObject(settings.hooks))) {
    log('settings.json schema is invalid; refusing a partial uninstall.');
    process.exit(1);
  }
  for (const blocks of Object.values(settings.hooks ?? {})) {
    if (!Array.isArray(blocks) || blocks.some((block) => !isObject(block) ||
        (block.hooks !== undefined && !Array.isArray(block.hooks)))) {
      log('settings.json hook schema is invalid; refusing a partial uninstall.');
      process.exit(1);
    }
  }
  return settings;
}

const settings = readSettingsForUninstall();
const manifest = readManifest();
if (!manifest) {
  log('ownership manifest missing or invalid — kept all installed files; no filename-only deletion is safe');
} else {
  for (const [key, recordedHash] of Object.entries(manifest.files)) {
    const installed = managedPath(key);
    if (!installed || !/^[a-f0-9]{64}$/.test(recordedHash)) {
      log(`kept untrusted manifest entry ${key}`);
      continue;
    }
    if (!fs.existsSync(installed)) {
      delete manifest.files[key];
      continue;
    }
    const stat = fs.lstatSync(installed);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      log(`kept ${key} — it is not a regular owned file`);
      continue;
    }
    if (hashFile(installed) !== recordedHash) {
      log(`kept ${key} — its bytes changed after installation`);
      continue;
    }
    fs.rmSync(installed);
    delete manifest.files[key];
    log(`removed ${key}`);
    let parent = path.dirname(installed);
    while (parent !== CLAUDE && parent.startsWith(`${CLAUDE}${path.sep}`)) {
      try { fs.rmdirSync(parent); } catch { break; }
      parent = path.dirname(parent);
    }
  }
  if (Object.keys(manifest.files).length === 0) {
    fs.rmSync(MANIFEST);
  } else {
    atomicWrite(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`, 0o600);
  }
}

if (settings) {
  const commands = new Set(HOOK_FILES.flatMap((script) => [managedCommand(script), legacyCommand(script)]));
  let changed = false;
  for (const [event, blocks] of Object.entries(settings.hooks ?? {})) {
    settings.hooks[event] = blocks
      .map((block) => {
        if (!Array.isArray(block.hooks)) return block;
        const hooks = block.hooks.filter((hook) => {
          const remove = isObject(hook) && hook.type === 'command' && commands.has(hook.command);
          changed ||= remove;
          return !remove;
        });
        return { ...block, hooks };
      })
      .filter((block) => !Array.isArray(block.hooks) || block.hooks.length > 0);
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }
  if (changed) {
    refreshBackup(SETTINGS, '.maestro-uninstall.bak');
    atomicWrite(SETTINGS, `${JSON.stringify(settings, null, 2)}\n`, fs.statSync(SETTINGS).mode);
    log('stripped exact Maestro hook entries from settings.json (other hooks kept)');
  }
}

const askFlag = path.join(MAESTRO_DIR, 'ask-on-start');
if (fs.existsSync(askFlag) && !fs.lstatSync(askFlag).isSymbolicLink()) {
  fs.rmSync(askFlag);
  log('removed ~/.maestro/ask-on-start');
}
if (fs.existsSync(AUTHORIZATION_DIR) && !fs.lstatSync(AUTHORIZATION_DIR).isSymbolicLink() &&
    fs.lstatSync(AUTHORIZATION_DIR).isDirectory()) {
  for (const name of fs.readdirSync(AUTHORIZATION_DIR)) {
    if (!AUTHORIZATION_PATTERN.test(name)) continue;
    const candidate = path.join(AUTHORIZATION_DIR, name);
    const stat = fs.lstatSync(candidate);
    if (stat.isFile() || stat.isSymbolicLink()) fs.rmSync(candidate, { force: true });
  }
  try { fs.rmdirSync(AUTHORIZATION_DIR); } catch {}
  log('removed private direct-edit authorization markers');
}
try { fs.rmdirSync(MAESTRO_DIR); } catch {}
log('done. web_search="disabled" and model pins in ~/.codex/config.toml were left as-is.');
