#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit): block DIRECT source-code writes by the
// orchestrator — in Maestro, Claude plans and reviews while Codex holds the pen.
// The gate opens only when the user explicitly asked Claude to edit it itself
// (orchestrator-inject.mjs sets the flag on phrases like "edit it yourself").
// Exempt so meta-work and notes never get locked:
//   - harness/config dirs (~/.claude, ~/.codex)
//   - scratch dirs (/tmp, ~/Desktop) — plan files for dispatch live here
//   - any non-code file (md/txt/json/toml/yaml/notes/etc.)
// Exit 2 = block, stderr is fed back to the model.
import fs from 'node:fs';
let payload = {};
try { payload = JSON.parse(fs.readFileSync(0, 'utf8')); } catch {}
const path = payload.tool_input?.file_path || '';
const sid = payload.session_id || 'default';

// Exempt paths: harness/config + scratch → direct edit always allowed here.
if (/\/\.claude\/|\/\.codex\/|(^|\/)tmp\/|\/Desktop\//.test(path)) process.exit(0);
// Only real source code triggers the gate; md/txt/json/toml/yaml and everything else is free.
const isCode = /\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|rb|php|java|kt|swift|c|h|cpp|hpp|cc|vue|svelte|sql|sh)$/i.test(path);
if (!isCode) process.exit(0);

if (fs.existsSync(`/tmp/maestro-direct-${sid}.flag`)) process.exit(0);
process.stderr.write(
  "ORCHESTRATOR GATE (source code): you are the planner/reviewer, not the implementer.\n" +
  "Write a plan file and dispatch it to Codex instead:\n" +
  "  bash ~/.claude/hooks/implementer-watchdog.sh --file <plan-file>\n" +
  "The watchdog appends the implementer contract itself — do not retype it. This is the\n" +
  "only implementation entry point — do not spawn a subagent to write code either.\n" +
  "Details: ~/.claude/rules/orchestrator-implementer.md\n" +
  "If Codex is unreachable or the change is genuinely trivial, STOP and ask the user\n" +
  'whether you may edit it directly ("edit it yourself" opens this gate for the task).'
);
process.exit(2);
