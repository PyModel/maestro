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
import { isNonCode } from './maestro-policy.mjs';

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

if (!payload || typeof payload !== 'object') failClosed();
const filePath = payload.tool_input?.file_path;
if (typeof filePath !== 'string' || filePath.trim() === '') failClosed();
if (payload.cwd !== undefined && typeof payload.cwd !== 'string') failClosed();

try {
  const cwd =
    typeof payload.cwd === 'string' && payload.cwd ? payload.cwd : process.cwd();
  const resolvedPath = path.isAbsolute(filePath)
    ? path.resolve(filePath)
    : path.resolve(cwd, filePath);
  const sid = payload.session_id || 'default';

  // Scratch roots are anchored: ordinary repository dirs named tmp or Desktop
  // must not become write bypasses. Harness dirs remain exempt at any segment.
  const scratchRoots = new Set(['/tmp', '/private/tmp', os.tmpdir()]);
  const inScratchRoot = [...scratchRoots].some(
    (root) => resolvedPath.startsWith(`${root}${path.sep}`)
  );
  const desktopRoot = path.join(os.homedir(), 'Desktop');
  const inDesktop = resolvedPath.startsWith(`${desktopRoot}${path.sep}`);
  const inHarnessDir = resolvedPath
    .split(path.sep)
    .some((segment) => segment === '.claude' || segment === '.codex');
  if (inScratchRoot || inDesktop || inHarnessDir) process.exit(0);

  if (isNonCode(resolvedPath)) process.exit(0);

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

  if (fs.existsSync(`/tmp/maestro-direct-${sid}.flag`)) process.exit(0);
  process.stderr.write(blockMessage);
  process.exit(2);
} catch {
  failClosed();
}
