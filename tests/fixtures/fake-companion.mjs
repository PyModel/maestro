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

if (command === "--help") {
  console.log(`Usage:
  node scripts/codex-companion.mjs task [--background] [--write] [--resume-last|--resume|--fresh] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [prompt]`);
  process.exit(0);
}

if (command === "task") {
  appendCall(`task ${args.join(" ")}`);
  if (process.env.MAESTRO_TEST_ARGV) {
    fs.writeFileSync(
      process.env.MAESTRO_TEST_ARGV,
      JSON.stringify([command, ...args]),
      "utf8"
    );
  }
  console.log("Started task-fake0000-aaaaaa");
  const delay = Number(process.env.MAESTRO_TEST_TASK_DELAY ?? "0");
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay * 1000));
  }
  process.exit(0);
}

if (command === "status" && args[0] === "--all" && args[1] === "--json") {
  appendCall("status --all --json");
  growLog();
  const statusFile = process.env.MAESTRO_TEST_STATUS;
  if (!statusFile) {
    process.exit(1);
  }
  const value = fs.readFileSync(statusFile, "utf8");
  console.log(value.trim() === "BROKEN" ? "{malformed" : value);
  process.exit(0);
}

if (command === "status" && args.at(-1) === "--json") {
  appendCall(`status ${args.join(" ")}`);
  growLog();
  const status = process.env.MAESTRO_TEST_JOB_PHASE ?? "completed";
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
  process.exit(0);
}

if (command === "result") {
  appendCall(`result ${args.join(" ")}`);
  console.log(process.env.MAESTRO_TEST_RESULT ?? "RESULT: DONE");
  process.exit(0);
}

if (command === "cancel") {
  appendCall(`cancel ${args.join(" ")}`);
  process.exit(0);
}

process.exit(1);
