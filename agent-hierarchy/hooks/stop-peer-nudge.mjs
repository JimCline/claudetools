#!/usr/bin/env node
/**
 * agent-hierarchy — Stop hook for the peer report-back contract.
 *
 * If this session has unresolved peer obligations (a sentinel arrived via
 * UserPromptSubmit tracking and no matching SendMessage reply was seen),
 * block the stop and name what is owed. E3 (live-verified): a Stop hook's
 * {"decision":"block","reason":...} re-prompts the model with the reason, and
 * the immediately following Stop payload carries `stop_hook_active: true` —
 * the UI renders the reason under a "Stop hook error:" label, so the wording
 * below is written to read sensibly there.
 *
 * Loop guards, all mandatory — this must never trap a session:
 *   - `stop_hook_active: true` always allows immediately, no re-check.
 *   - Each (session, task, from) obligation is blocked at most MAX_NUDGES
 *     times (tracked via an incrementing `nudges` field re-appended on the
 *     pending record); once exhausted it is marked "waived" and the stop is
 *     allowed even though nothing was ever sent.
 *   - Any read/parse failure anywhere in this hook allows the stop.
 *
 * No-ops (allows) for subagents (same `agent_id` discriminator as the rest of
 * the plugin) — a subagent's report is structural, not something this
 * contract governs.
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { appendPeerRecord, MAX_NUDGES, pendingFor } from "./lib-peer.mjs";

function allow() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

function owedLine(rec) {
  return `you were tasked as a peer (task ${rec.task}) by ${rec.from_name} and have not sent your report: SendMessage it now with to:"${rec.from}"`;
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) allow();
  if (input.stop_hook_active === true) allow();

  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  if (!sessionId) allow();

  const owed = pendingFor(sessionId);
  if (owed.length === 0) allow();

  const toNudge = [];
  const now = new Date().toISOString();
  for (const rec of owed) {
    const nudges = typeof rec.nudges === "number" ? rec.nudges : 0;
    if (nudges >= MAX_NUDGES) {
      appendPeerRecord({ ...rec, ts: now, status: "waived" });
    } else {
      const updated = { ...rec, ts: now, status: "pending", nudges: nudges + 1 };
      appendPeerRecord(updated);
      toNudge.push(updated);
    }
  }

  if (toNudge.length === 0) allow();

  const reason =
    toNudge.length === 1
      ? owedLine(toNudge[0])
      : ["You have more than one unsent peer report:", ...toNudge.map((rec) => `- ${owedLine(rec)}`)].join("\n");
  block(reason);
} catch {
  // fail open: never trap a session over a tracking failure
  allow();
}
