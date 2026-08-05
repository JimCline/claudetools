#!/usr/bin/env node
/**
 * agent-hierarchy — CLI for the Ultra-Advisor escalation gate.
 *
 *   node gate.mjs set --session <id> --choice session|each|off
 *   node gate.mjs status [--session <id>]
 *   node gate.mjs reset --session <id>
 *
 * The PreToolUse hook composes the exact `set` line (session id already
 * substituted) into its denial, so the Orchestrator records the user's answer
 * by copying one command rather than by hand-writing state.
 */

import {
  GATE_CHOICES,
  GATE_CHOICE_LABELS,
  clearDecision,
  gatePath,
  getDecision,
  readGateState,
  setDecision,
} from "./lib-gate.mjs";

const USAGE = [
  "usage:",
  "  node gate.mjs set --session <id> --choice session|each|off",
  "  node gate.mjs status [--session <id>]",
  "  node gate.mjs reset --session <id>",
  "",
  "choices:",
  "  session  allow every Ultra-Advisor dispatch for the rest of this session",
  "  each     allow, but ask again before each later escalation",
  "  off      block Ultra-Advisor escalation for the rest of this session",
].join("\n");

function fail(message) {
  process.stderr.write(`agent-hierarchy gate: ${message}\n\n${USAGE}\n`);
  process.exit(1);
}

function parseFlags(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) fail(`unexpected argument ${JSON.stringify(arg)}`);
    const name = arg.slice(2);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) fail(`--${name} needs a value`);
    flags[name] = value;
    i += 1;
  }
  return flags;
}

const [command, ...rest] = process.argv.slice(2);
const flags = parseFlags(rest);

switch (command) {
  case "set": {
    if (!flags.session) fail("--session is required");
    if (!flags.choice) fail("--choice is required");
    if (!GATE_CHOICES.includes(flags.choice)) {
      fail(`unknown choice ${JSON.stringify(flags.choice)} (expected: ${GATE_CHOICES.join(", ")})`);
    }
    setDecision(flags.session, flags.choice, flags.cwd || process.cwd());
    process.stdout.write(`Ultra-Advisor: ${GATE_CHOICE_LABELS[flags.choice]}.\n`);
    break;
  }

  case "status": {
    if (flags.session) {
      const decision = getDecision(flags.session);
      process.stdout.write(
        decision
          ? `Ultra-Advisor: ${GATE_CHOICE_LABELS[decision]} (choice "${decision}").\n`
          : "Ultra-Advisor: not yet decided this session — the next escalation will ask.\n"
      );
      break;
    }
    const { sessions } = readGateState();
    const keys = Object.keys(sessions).sort((a, b) => String(sessions[b].at || "").localeCompare(String(sessions[a].at || "")));
    if (!keys.length) {
      process.stdout.write(`No Ultra-Advisor gate decisions recorded (${gatePath()}).\n`);
      break;
    }
    process.stdout.write(`Ultra-Advisor gate decisions, newest first (${gatePath()}):\n`);
    for (const key of keys) {
      const entry = sessions[key];
      process.stdout.write(`  ${String(entry.at || "?").padEnd(26)} ${String(entry.choice).padEnd(8)} ${key}${entry.cwd ? `  ${entry.cwd}` : ""}\n`);
    }
    break;
  }

  case "reset": {
    if (!flags.session) fail("--session is required");
    const removed = clearDecision(flags.session);
    process.stdout.write(
      removed
        ? "Ultra-Advisor: gate decision cleared — the next escalation will ask again.\n"
        : "Ultra-Advisor: nothing recorded for that session; the next escalation will ask.\n"
    );
    break;
  }

  default:
    fail(command ? `unknown command ${JSON.stringify(command)}` : "no command given");
}
