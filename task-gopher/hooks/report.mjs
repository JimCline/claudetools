#!/usr/bin/env node
/**
 * task-gopher — strict-mode audit report.
 *
 * Reads the append-only JSONL log written by pretooluse-nudge.mjs and prints a
 * human-readable summary: how often the checkpoint fired, how many direct
 * retrievals were bypassed (and what they were), and how many times the agent
 * actually dispatched to task-gopher. The bypass-to-dispatch ratio and the list
 * of recent bypasses are what let you judge whether the orchestrator is being
 * deliberate or just rubber-stamping past the gate.
 *
 * Read-only. Prints to stdout. Never throws.
 */

import { readFileSync } from "node:fs";
import { LOG_FILE } from "./directive.mjs";

const RECENT = Number(process.argv[2]) || 12;

function main() {
  let raw;
  try {
    raw = readFileSync(LOG_FILE, "utf8");
  } catch {
    console.log(`No task-gopher audit log yet (${LOG_FILE}).`);
    console.log("It fills up once strict mode is on and the checkpoint starts firing.");
    return;
  }

  const events = raw
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);

  if (!events.length) {
    console.log(`task-gopher audit log is empty (${LOG_FILE}).`);
    return;
  }

  const checkpoints = events.filter((e) => e.event === "checkpoint");
  const bypasses = events.filter((e) => e.event === "bypass");
  const dispatches = events.filter((e) => e.event === "dispatch");
  const turns = new Set(events.map((e) => e.pid).filter(Boolean)).size;

  const ratio = dispatches.length
    ? (bypasses.length / dispatches.length).toFixed(2)
    : `∞ (${bypasses.length} bypasses, 0 dispatches)`;

  // Which tools/commands get bypassed most.
  const byTool = {};
  for (const b of bypasses) byTool[b.tool || "?"] = (byTool[b.tool || "?"] || 0) + 1;
  const toolBreakdown = Object.entries(byTool)
    .sort((a, b) => b[1] - a[1])
    .map(([t, n]) => `${t} ${n}`)
    .join(", ");

  const span =
    events[0].ts && events[events.length - 1].ts
      ? `${events[0].ts} → ${events[events.length - 1].ts}`
      : "(no timestamps)";

  console.log("task-gopher — strict-mode audit report");
  console.log("=".repeat(42));
  console.log(`log:            ${LOG_FILE}`);
  console.log(`span:           ${span}`);
  console.log(`turns w/ gate:  ${turns}`);
  console.log(`checkpoints:    ${checkpoints.length}  (times the gate blocked)`);
  console.log(`bypasses:       ${bypasses.length}  (direct retrievals done anyway)`);
  console.log(`dispatches:     ${dispatches.length}  (delegations to task-gopher)`);
  console.log(`bypass/dispatch ratio: ${ratio}  (lower is better)`);
  if (toolBreakdown) console.log(`bypassed tools: ${toolBreakdown}`);

  const recent = bypasses.slice(-RECENT);
  if (recent.length) {
    console.log("");
    console.log(`recent bypasses (last ${recent.length}) — what was run directly:`);
    for (const r of recent) {
      const when = r.ts ? r.ts.replace("T", " ").replace(/\..*/, "") : "";
      const detail = r.detail ? `: ${r.detail}` : "";
      console.log(`  - ${when}  ${r.tool || "?"}${detail}`);
    }
  }

  console.log("");
  console.log("A high bypass/dispatch ratio or lots of clearly-delegatable reads above");
  console.log("means the gate is being rubber-stamped. Clear the log with:");
  console.log("  /task-gopher log clear");
}

try {
  main();
} catch (e) {
  console.log(`task-gopher report: could not generate (${e && e.message}).`);
}
