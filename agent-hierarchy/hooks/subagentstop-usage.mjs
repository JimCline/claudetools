#!/usr/bin/env node
/**
 * agent-hierarchy — usage collector, fired on SubagentStop.
 *
 * When a subagent finishes, this reads its transcript from disk, sums the
 * per-turn `message.usage` token counts, and appends ONE line to USAGE_FILE.
 * That is the entire mechanism: a node process reading local files. It costs
 * zero tokens — no model is involved, and no agent is ever asked to report its
 * own usage.
 *
 * The join that makes attribution work: the transcript itself does not say
 * which agent type it belongs to (only a display slug), while the hook payload
 * carries `agent_type` but no token counts. This event is where both are in
 * hand at once. The record stores the RAW agent_type; mapping to a hierarchy
 * role happens at report time, so the mapping can change without touching data.
 *
 * Path derivation, verified against the real layout:
 *   payload.transcript_path = <project_dir>/<session_id>.jsonl   (the parent's)
 *   subagent transcript     = <project_dir>/<session_id>/subagents/agent-<agent_id>.jsonl
 *
 * `found:false` records are deliberate telemetry, not noise: the SubagentStop
 * payload shape is assumed to mirror SubagentStart's (proven), and if a harness
 * change ever breaks the derivation, a run of found:false lines is the only
 * way anyone notices — this channel has no user-visible failure mode.
 *
 * Collects whenever the plugin's hooks are loaded, independent of the
 * /hierarchy on-off flag: that flag governs the orchestration directive, and
 * usage data is exactly what you want while evaluating whether the hierarchy
 * is earning its keep. Never blocks, never throws — a broken collector must
 * not interfere with a finishing subagent.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { USAGE_FILE, pruneUsageFile, sumTranscript, zeroUsage } from "./lib-usage.mjs";

try {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  const p = JSON.parse(raw || "{}");

  const agentId = typeof p.agent_id === "string" ? p.agent_id : "";
  if (!agentId) process.exit(0); // not a subagent lifecycle event we can attribute

  const sessionId = typeof p.session_id === "string" ? p.session_id : "";
  const tPath = typeof p.transcript_path === "string" ? p.transcript_path : "";
  const projectDir = tPath ? dirname(tPath) : "";

  let ts = "";
  try {
    ts = new Date().toISOString();
  } catch {
    ts = "";
  }

  let rec = {
    ts,
    session_id: sessionId,
    agent_id: agentId,
    agent_type: typeof p.agent_type === "string" ? p.agent_type : "",
    project_dir: projectDir,
    found: false,
    model: "",
    ...zeroUsage(),
  };

  if (projectDir && sessionId) {
    const sums = sumTranscript(join(projectDir, sessionId, "subagents", `agent-${agentId}.jsonl`));
    if (sums) rec = { ...rec, found: true, ...sums };
  }

  mkdirSync(dirname(USAGE_FILE), { recursive: true });
  appendFileSync(USAGE_FILE, JSON.stringify(rec) + "\n"); // O_APPEND: concurrent stops just queue
  pruneUsageFile();
} catch {
  // fall through to a clean exit — never break a finishing subagent
}
process.exit(0);
