#!/usr/bin/env node
/**
 * task-gopher — audit report.
 *
 * Reads the append-only JSONL log written by pretooluse-nudge.mjs and prints a
 * human-readable summary: how often the strict checkpoint fired, how many
 * direct retrievals were bypassed (and what they were), how many times the
 * agent dispatched to task-gopher vs. smart-gopher, how often the
 * smart-gopher gate checkpointed a distinct escalation request, and how the
 * subagent relay behaved. Because
 * dispatch/relay lines are written whenever the plugin is ON while
 * checkpoint/bypass lines require strict mode, the bypass-to-dispatch ratio is
 * computed only over dispatches from strict-gated turns — otherwise
 * non-strict-era dispatches would dilute the exact rubber-stamping signal the
 * ratio exists to expose.
 *
 * Read-only. Prints to stdout. Never throws.
 */

import { readFileSync } from "node:fs";
import { LOG_FILE, gopherKind } from "./directive.mjs";

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
  const relayInjected = events.filter((e) => e.event === "relay-injected");
  const relaySkipped = events.filter((e) => e.event === "relay-skip");
  const blocked = events.filter((e) => e.event === "destructive-blocked");
  const authorized = events.filter((e) => e.event === "destructive-allowed");
  const asked = events.filter((e) => e.event === "destructive-ask");
  const smartGateCheckpoints = events.filter((e) => e.event === "smart-gate-checkpoint");
  const turns = new Set(events.map((e) => e.pid).filter(Boolean)).size;

  // Only dispatches from turns the strict gate actually saw count toward the
  // ratio; dispatch lines also accrue in non-strict mode.
  const strictPids = new Set([...checkpoints, ...bypasses].map((e) => e.pid).filter(Boolean));
  const strictDispatches = dispatches.filter((d) => strictPids.has(d.pid));

  // `e.agent` fallback matters: logs written by earlier versions have no `agent`
  // field, and the report must not misreport historical lines. Falling back to
  // the `detail` substring (which holds the subagent_type) reads them correctly;
  // `gopherKind` already tests smart-gopher before task-gopher (see directive.mjs).
  const agentOf = (e) => e.agent || gopherKind(e.detail) || "task-gopher";
  const smartDispatches = dispatches.filter((d) => agentOf(d) === "smart-gopher");
  const cheapDispatches = dispatches.filter((d) => agentOf(d) === "task-gopher");

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
  console.log(
    `dispatches:     ${dispatches.length}  (${cheapDispatches.length} task-gopher, ${smartDispatches.length} smart-gopher; ` +
      `${strictDispatches.length} in strict-gated turns)`
  );
  console.log(`bypass/dispatch ratio: ${ratio}  (strict-gated turns only; lower is better)`);
  if (smartDispatches.length || smartGateCheckpoints.length) {
    console.log(
      `smart-gopher gate: ${smartGateCheckpoints.length} checkpoint(s) fired ` +
        `(once per distinct request, independent of strict mode)`
    );
  }
  if (toolBreakdown) console.log(`bypassed tools: ${toolBreakdown}`);
  if (relayOk.length || relayInjected.length || relaySkipped.length) {
    console.log(
      `subagent relay:  ${relayInjected.length} dispatches stamped, ${relayOk.length} already carried it`
    );
  }
  if (relaySkipped.length) {
    // Broken down by reason so a mistaken skip is legible: "no-dispatch-tool" on
    // an agent that clearly can dispatch is the failure this feature can cause.
    const byReason = {};
    for (const s of relaySkipped) byReason[s.reason || "?"] = (byReason[s.reason || "?"] || 0) + 1;
    const reasons = Object.entries(byReason)
      .sort((a, b) => b[1] - a[1])
      .map(([r, n]) => `${r} ${n}`)
      .join(", ");
    console.log(`relay skipped:   ${relaySkipped.length} dispatches to agents that can't delegate (${reasons})`);
  }

  // The guard's own trail. Interceptions are shown in full rather than counted:
  // each one is a command the runner was about to run and could not judge,
  // which is the single most useful thing this log holds. The ask count is what
  // the guard cost a human in interruptions — if it climbs, the leads are
  // dispatching destructive work instead of running it themselves.
  if (blocked.length || authorized.length || asked.length) {
    console.log(
      `destructive guard: ${asked.length} put to you for approval, ${blocked.length} denied outright, ` +
        `${authorized.length} run under an explicit ALLOW-DESTRUCTIVE`
    );
    const preauth = asked.filter((a) => a.preauthorized).length;
    if (preauth) {
      console.log(`  (${preauth} of those prompts carried a lead's ALLOW-DESTRUCTIVE recommendation)`);
    }
    for (const b of [...asked, ...blocked].slice(-RECENT)) {
      const labels = Array.isArray(b.labels) ? ` [${b.labels.join(", ")}]` : "";
      const what = b.event === "destructive-ask" ? "asked" : "blocked";
      const why = b.why ? ` (${b.why})` : "";
      console.log(`  - ${what} [${agentOf(b)}]: ${b.detail || "?"}${labels}${why}`);
    }
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
