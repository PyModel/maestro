#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit): block DIRECT writes by the
// orchestrator — in Maestro, Claude plans and reviews while Codex holds the pen.
// The gate opens only when the user explicitly asked Claude to edit it itself
// (orchestrator-inject.mjs sets the flag on phrases like "edit it yourself"),
// and subagents never inherit that main-loop authorization. Unknown file types
// are gated by default; only the shared non-code allowlist and anchored
// harness/scratch paths stay free. Unreadable payloads fail closed because an
// allow decision without a trustworthy target path would bypass the policy.
// Exit 2 = block, stderr is fed back to the model.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { isNonCode, isValidSessionId } from './maestro-policy.mjs';

const MAESTRO_DIR = path.join(os.homedir(), '.maestro');
const AUTHORIZATION_DIR = path.join(MAESTRO_DIR, 'direct-edit');

const failClosed = () => {
  process.stderr.write(
    'ORCHESTRATOR GATE: could not read the hook payload; failing closed for edits — ' +
    'likely a harness change, report it to the user.\n'
  );
  process.exit(2);
};

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  failClosed();
}

if (!payload || typeof payload !== 'object' || Array.isArray(payload)) failClosed();
if (!isValidSessionId(payload.session_id)) failClosed();
const filePath = payload.tool_input?.file_path;
if (typeof filePath !== 'string' || filePath.trim() === '') failClosed();
if (payload.cwd !== undefined && typeof payload.cwd !== 'string') failClosed();

function canonicalPolicyPath(absolutePath) {
  let cursor = absolutePath;
  const missing = [];
  while (true) {
    let stat;
    try {
      stat = fs.lstatSync(cursor);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      const parent = path.dirname(cursor);
      if (parent === cursor) throw error;
      missing.unshift(path.basename(cursor));
      cursor = parent;
      continue;
    }
    if (stat.isSymbolicLink() || stat.isFile() || stat.isDirectory()) {
      return path.join(fs.realpathSync(cursor), ...missing);
    }
    return path.join(cursor, ...missing);
  }
}

try {
  const cwd =
    typeof payload.cwd === 'string' && payload.cwd ? payload.cwd : process.cwd();
  const resolvedPath = path.isAbsolute(filePath)
    ? path.resolve(filePath)
    : path.resolve(cwd, filePath);
  const policyPath = canonicalPolicyPath(resolvedPath);
  const sid = payload.session_id;

  // Scratch roots are anchored: ordinary repository dirs named tmp or Desktop
  // must not become write bypasses. Harness dirs remain exempt at any segment.
  const scratchRoots = new Set(['/tmp', '/private/tmp', os.tmpdir()]);
  const inScratchRoot = [...scratchRoots].some(
    (root) => policyPath.startsWith(`${root}${path.sep}`)
  );
  const desktopRoot = canonicalPolicyPath(path.join(os.homedir(), 'Desktop'));
  const inDesktop = policyPath.startsWith(`${desktopRoot}${path.sep}`);
  const inHarnessDir = policyPath
    .split(path.sep)
    .some((segment) => segment === '.claude' || segment === '.codex');
  if (inScratchRoot || inDesktop || inHarnessDir) process.exit(0);

  let executable = false;
  try {
    const stat = fs.statSync(policyPath);
    executable = stat.isFile() && (stat.mode & 0o111) !== 0;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  if (!executable && isNonCode(policyPath)) process.exit(0);

  const isSubagent = [payload.agent_id, payload.agent_type].some(
    (value) => typeof value === 'string' && value.trim() !== ''
  );

  const blockMessage =
    "ORCHESTRATOR GATE (source code): you are the planner/reviewer, not the implementer.\n" +
    "Write a plan file and dispatch it to Codex instead:\n" +
    "  bash ~/.claude/hooks/implementer-watchdog.sh --file <plan-file>\n" +
    "The watchdog appends the implementer contract itself — do not retype it. This is the\n" +
    "only implementation entry point — do not spawn a subagent to write code either.\n" +
    "Details: ~/.claude/rules/orchestrator-implementer.md\n" +
    "If Codex is unreachable or the change is genuinely trivial, STOP and ask the user\n" +
    'whether you may edit it directly ("edit it yourself" opens this gate for the task).';

  if (isSubagent) {
    process.stderr.write(
      blockMessage +
      '\nSubagents never inherit "edit it yourself"; only the main loop can hold the override.'
    );
    process.exit(2);
  }

  const flag = path.join(AUTHORIZATION_DIR, `maestro-direct-${sid}.flag`);
  try {
    const expectedUid = typeof process.getuid === 'function' ? process.getuid() : null;
    for (const directory of [MAESTRO_DIR, AUTHORIZATION_DIR]) {
      const stat = fs.lstatSync(directory);
      if (stat.isSymbolicLink() || !stat.isDirectory() || (stat.mode & 0o077) !== 0 ||
          (expectedUid !== null && stat.uid !== expectedUid)) throw new Error('unsafe authorization directory');
    }
    const stat = fs.lstatSync(flag);
    if (stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0 &&
        (expectedUid === null || stat.uid === expectedUid) && fs.readFileSync(flag, 'utf8') === '1\n') {
      process.exit(0);
    }
  } catch {}
  process.stderr.write(blockMessage);
  process.exit(2);
} catch {
  failClosed();
}
