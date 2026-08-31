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
 *   - `stop_hook_active: true` disarms the turn marker if it is armed, then
 *     always allows immediately, no re-check.
 *   - Each (session, task, from) obligation is blocked at most MAX_NUDGES
 *     times (tracked via an incrementing `nudges` field re-appended on the
 *     pending record); once exhausted it is marked "waived" and the stop is
 *     allowed even though nothing was ever sent.
 *   - Any read/parse failure anywhere in this hook allows the stop.
 *
 * Amendment 2 (interactive peers): a peer session doubles as an interactive
 * one, so enforcement must fire on the peer's own tasking-related turns, not
 * on every turn a user happens to chat through while a report is owed — that
 * would burn the nudge budget on unrelated turns and pressure a premature
 * reply. The check order is now: subagent -> allow; stop_hook_active ->
 * disarm-if-armed, allow; no pending obligations -> allow; the session's
 * latest turn marker (armed by UserPromptSubmit tracking on a peer-delivered
 * turn — see that hook) is absent or "disarmed" -> allow WITHOUT touching any
 * nudge count (the user-turn exemption: the user drove this turn, not the
 * peer); otherwise (armed) -> the existing nudge/waive logic below, and in
 * EVERY armed outcome (block OR everything-just-waived) the marker is
 * disarmed, so one armed marker licenses at most one enforcement pass.
 *
 * No-ops (allows) for subagents (same `agent_id` discriminator as the rest of
 * the plugin) — a subagent's report is structural, not something this
 * contract governs.
 */

import { isSubagent, MSG_CLI, readHookInput } from "./lib-config.mjs";
import { parseMsgFilename } from "./lib-hier.mjs";
import { appendPeerRecord, appendTurnMarker, latestTurnMarker, MAX_NUDGES, pendingFor } from "./lib-peer.mjs";

function allow() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

/**
 * Spec 0028 §4.3: escalate across the two attempts — the first is a reminder,
 * the second (`isFinal`, `nudges` has reached `MAX_NUDGES`) states plainly
 * that stopping now will be recorded as an unmet obligation. The terminal
 * `status: "waived"` record write (below) already existed pre-0028; this text
 * is the other half of Hole 2 — the give-up was silent before, now it isn't.
 */
function owedLine(rec, isFinal) {
  let line = `you were tasked as a peer (task ${rec.task}) by ${rec.from_name} and have not sent your report: SendMessage it now with to:"${rec.from}"`;
  if (rec.msg) {
    const meta = parseMsgFilename(rec.msg);
    const id = meta ? meta.id : "<id>";
    line += ` — your reply must carry [hierarchy-msg <response path>] — write it with node "${MSG_CLI}" new --type response --id ${id}`;
  }
  if (isFinal) line += " THIS IS THE LAST ATTEMPT — stopping without sending your report now will be recorded as an unmet obligation.";
  return line;
}

function disarmIfArmed(sessionId) {
  const marker = latestTurnMarker(sessionId);
  if (marker && marker.status === "armed") appendTurnMarker(sessionId, "disarmed");
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) allow();

  const sessionId = typeof input.session_id === "string" ? input.session_id : "";

  if (input.stop_hook_active === true) {
    if (sessionId) disarmIfArmed(sessionId);
    allow();
  }

  if (!sessionId) allow();

  const owed = pendingFor(sessionId);
  if (owed.length === 0) allow();

  const marker = latestTurnMarker(sessionId);
  if (!marker || marker.status !== "armed") allow(); // user-turn exemption: no nudge count touched

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

  // Every armed outcome consumes the marker, whether it blocks or everything just got waived.
  appendTurnMarker(sessionId, "disarmed");

  if (toNudge.length === 0) allow();

  const reason =
    toNudge.length === 1
      ? owedLine(toNudge[0], toNudge[0].nudges >= MAX_NUDGES)
      : ["You have more than one unsent peer report:", ...toNudge.map((rec) => `- ${owedLine(rec, rec.nudges >= MAX_NUDGES)}`)].join("\n");
  block(reason);
} catch {
  // fail open: never trap a session over a tracking failure
  allow();
}
