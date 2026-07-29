#!/usr/bin/env node
/**
 * task-gopher — audit report.
 *
 * Reads the append-only JSONL log written by pretooluse-nudge.mjs and prints a
 * human-readable summary: how often the strict checkpoint fired, how many
 * direct retrievals were bypassed (and what they were), how many times the
 * agent dispatched to task-gopher, and how the subagent relay behaved. Because
 * dispatch/relay lines are written whenever the plugin is ON while
 * checkpoint/bypass lines require strict mode, the bypass-to-dispatch ratio is
 * computed only over dispatches from strict-gated turns — otherwise
 * non-strict-era dispatches would dilute the exact rubber-stamping signal the
 * ratio exists to expose.
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
    console.log("It fills up once the plugin is ON (dispatch/relay events) — and in strict mode, checkpoint events too.");
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
  const relayOk = events.filter((e) => e.event === "relay-ok");
  const relayBounces = events.filter((e) => e.event === "relay-bounce");
  const relayForgone = events.filter((e) => e.event === "relay-forgone");
  const turns = new Set(events.map((e) => e.pid).filter(Boolean)).size;

  // Only dispatches from turns the strict gate actually saw count toward the
  // ratio; dispatch lines also accrue in non-strict mode.
  const strictPids = new Set([...checkpoints, ...bypasses].map((e) => e.pid).filter(Boolean));
  const strictDispatches = dispatches.filter((d) => strictPids.has(d.pid));

  const ratio = strictDispatches.length
    ? (bypasses.length / strictDispatches.length).toFixed(2)
    : `∞ (${bypasses.length} bypasses, 0 strict-turn dispatches)`;

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

  console.log("task-gopher — audit report");
  console.log("=".repeat(42));
  console.log(`log:            ${LOG_FILE}`);
  console.log(`span:           ${span}`);
  console.log(`turns logged:   ${turns}  (${strictPids.size} saw the strict gate)`);
  console.log(`checkpoints:    ${checkpoints.length}  (times the strict gate blocked)`);
  console.log(`bypasses:       ${bypasses.length}  (direct retrievals done anyway)`);
  console.log(`dispatches:     ${dispatches.length}  (delegations to task-gopher; ${strictDispatches.length} in strict-gated turns)`);
  console.log(`bypass/dispatch ratio: ${ratio}  (strict-gated turns only; lower is better)`);
  if (toolBreakdown) console.log(`bypassed tools: ${toolBreakdown}`);
  if (relayOk.length || relayBounces.length || relayForgone.length) {
    console.log(
      `subagent relay:  ${relayOk.length} ok, ${relayBounces.length} bounced, ${relayForgone.length} forgone (fail-open)`
    );
  }

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
