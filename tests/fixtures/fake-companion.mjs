#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";

const [command, ...args] = process.argv.slice(2);

function appendCall(line) {
  if (process.env.MAESTRO_TEST_CALL_LOG) {
    fs.appendFileSync(process.env.MAESTRO_TEST_CALL_LOG, `${line}\n`);
  }
}

function growLog() {
  const file = process.env.MAESTRO_TEST_LOGFILE;
  const bytes = Number(process.env.MAESTRO_TEST_LOG_GROWTH ?? "0");
  if (file && Number.isInteger(bytes) && bytes > 0) {
    fs.appendFileSync(file, "x".repeat(bytes));
  }
}

function nextSequenceValue(file, fallback) {
  if (!file) return fallback;
  const values = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
  if (values.length === 0) return fallback;
  fs.writeFileSync(file, values.slice(1).join("\n"), "utf8");
  return values[0];
}

if (command === "--help") {
  appendCall("--help");
  const delay = Number(process.env.MAESTRO_TEST_HELP_DELAY ?? "0");
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay * 1000));
  }
  console.log(`Usage:
  node scripts/codex-companion.mjs task [--background] [--write] [--resume-last|--resume|--fresh] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [prompt]`);
  process.exit(0);
}

if (command === "task") {
  appendCall(`task ${args.join(" ")}`);
  if (process.env.MAESTRO_TEST_LEASE_TOKEN_LOG &&
      process.env.MAESTRO_TEST_LEASE_METADATA) {
    const metadata = fs.readFileSync(
      process.env.MAESTRO_TEST_LEASE_METADATA,
      "utf8"
    );
    const token = metadata.match(/^token=(.*)$/m)?.[1] ?? "missing";
    const reclaim = fs.existsSync(
      process.env.MAESTRO_TEST_LEASE_METADATA.replace(/\/metadata$/, "/.reclaim")
    ) ? 1 : 0;
    fs.appendFileSync(
      process.env.MAESTRO_TEST_LEASE_TOKEN_LOG,
      `token=${token} reclaim=${reclaim}\n`
    );
  }
  if (process.env.MAESTRO_TEST_ARGV) {
    fs.writeFileSync(
      process.env.MAESTRO_TEST_ARGV,
      JSON.stringify([command, ...args]),
      "utf8"
    );
  }
  const taskId = process.env.MAESTRO_TEST_TASK_ID ?? nextSequenceValue(
    process.env.MAESTRO_TEST_TASK_ID_FILE,
    "task-fake0000-aaaaaa"
  );
  if (process.env.MAESTRO_TEST_JOB_START_LOG) {
    fs.appendFileSync(
      process.env.MAESTRO_TEST_JOB_START_LOG,
      `${Date.now()}\t${taskId}\n`
    );
  }
  console.log(`Started ${taskId}`);
  const delay = Number(process.env.MAESTRO_TEST_TASK_DELAY ?? "0");
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay * 1000));
  }
  const taskExit = Number(process.env.MAESTRO_TEST_TASK_EXIT ?? "0");
  process.exit(Number.isInteger(taskExit) ? taskExit : 1);
}

if (command === "status" && args[0] === "--all" && args[1] === "--json") {
  appendCall("status --all --json");
  growLog();
  if (process.env.MAESTRO_TEST_UNPUBLISHED_SECOND_WRITER) {
    console.log(JSON.stringify({
      running: [{
        id: process.env.MAESTRO_TEST_UNPUBLISHED_SECOND_WRITER,
        write: true
      }],
      latestFinished: null
    }));
    process.exit(0);
  }
  const statusFile = process.env.MAESTRO_TEST_STATUS;
  if (!statusFile) {
    process.exit(1);
  }
  const ownerSession = process.env.MAESTRO_TEST_STATUS_SESSION_ID;
  const requestedSession = process.env.CODEX_COMPANION_SESSION_ID;
  if (ownerSession && requestedSession && requestedSession !== ownerSession) {
    console.log(JSON.stringify({ running: [], latestFinished: null }));
    process.exit(0);
  }
  const value = fs.readFileSync(statusFile, "utf8");
  console.log(value.trim() === "BROKEN" ? "{malformed" : value);
  process.exit(0);
}

if (command === "status" && args.at(-1) === "--json") {
  appendCall(`status ${args.join(" ")}`);
  growLog();
  const hang = Number(process.env.MAESTRO_TEST_STATUS_HANG ?? "0");
  if (hang > 0 && process.env.MAESTRO_TEST_STATUS_PID_FILE) {
    fs.writeFileSync(process.env.MAESTRO_TEST_STATUS_PID_FILE, `${process.pid}\n`);
  }
  if (hang > 0) {
    await new Promise((resolve) => setTimeout(resolve, hang * 1000));
  }
  if (process.env.MAESTRO_TEST_JOB_STATUS_RAW !== undefined) {
    console.log(process.env.MAESTRO_TEST_JOB_STATUS_RAW);
    process.exit(Number(process.env.MAESTRO_TEST_JOB_STATUS_EXIT ?? "0"));
  }
  const terminalFlag = process.env.MAESTRO_TEST_JOB_TERMINAL_FLAG;
  const status = terminalFlag
    ? (fs.existsSync(terminalFlag) ? "completed" : "running")
    : nextSequenceValue(
        process.env.MAESTRO_TEST_JOB_PHASE_FILE,
        process.env.MAESTRO_TEST_JOB_PHASE ?? "completed"
      );
  const value = {
    id: args[0],
    status,
    phase: status === "running" ? "running" : "done",
    elapsed: "1s",
    progressPreview: [],
    request: { model: "gpt-5.6-sol", effort: "high" }
  };
  if (process.env.MAESTRO_TEST_LOGFILE) {
    value.logFile = process.env.MAESTRO_TEST_LOGFILE;
  }
  console.log(JSON.stringify(value));
  process.exit(Number(process.env.MAESTRO_TEST_JOB_STATUS_EXIT ?? "0"));
}

if (command === "result") {
  appendCall(`result ${args.join(" ")}`);
  console.log(process.env.MAESTRO_TEST_RESULT ?? "RESULT: DONE");
  process.exit(Number(process.env.MAESTRO_TEST_RESULT_EXIT ?? "0"));
}

if (command === "cancel") {
  appendCall(`cancel ${args.join(" ")}`);
  process.exit(0);
}

process.exit(1);
