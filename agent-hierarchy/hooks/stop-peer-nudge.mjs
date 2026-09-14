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
 *   - On a PEER-DRIVEN (armed) turn, each (session, task, from) obligation is
 *     blocked at most MAX_NUDGES times (tracked via an incrementing `nudges`
 *     field re-appended on the pending record); once exhausted it is marked
 *     "waived" and the stop is allowed even though nothing was ever sent.
 *     `stop_hook_active` deliberately does NOT short-circuit this path — the
 *     ceiling is what guarantees termination, and a blanket allow on the
 *     re-stop made that ceiling unreachable (see below).
 *   - On a USER-DRIVEN (unarmed) turn, `stop_hook_active: true` allows, which
 *     bounds the reminder to one block per turn.
 *   - Any read/parse failure anywhere in this hook allows the stop.
 *
 * Why `stop_hook_active` is not a blanket allow: a block re-prompts the model,
 * and a model that answers the re-prompt by WRITING its response file without
 * SendMessage-ing it then stops again — that second stop carries
 * `stop_hook_active: true`. Allowing it unconditionally spent the whole
 * enforcement budget on one block, left the obligation `pending` on disk, and
 * nothing re-armed it, because re-arming requires another inbound
 * cross-session delivery that a one-shot tasking never gets. That is a live
 * failure mode, not a hypothetical: an Implementor wrote its report, echoed
 * the `[hierarchy-msg ...]` token in its own output, and went idle, stranding
 * the orchestrator until a human asked it directly.
 *
 * Amendment 2 (interactive peers), as amended: the turn marker (armed by
 * UserPromptSubmit tracking on a peer-delivered turn) no longer decides
 * WHETHER to enforce, only whether enforcing costs budget. A report is owed
 * regardless of who drove the turn, so an unarmed turn still blocks; it just
 * does not consume a nudge, which preserves the original point of the
 * exemption — unrelated user chat must not burn the budget or pressure a
 * premature reply. The marker is no longer consumed by the act of blocking
 * either: it is released only when the obligation is waived here (or resolved
 * by posttooluse-peer-resolve.mjs), since spending it on a single nudge was
 * the other half of the strand above.
 *
 * The sanctioned escape, when the user genuinely does not want the report
 * sent, is to send the orchestrator a one-line "cancelled by user" reply —
 * which resolves the obligation through the normal path. Going silent is not
 * an escape: the orchestrator is stranded either way, and only the reply tells
 * it so.
 *
 * No-ops (allows) for subagents (same `agent_id` discriminator as the rest of
 * the plugin) — a subagent's report is structural, not something this
 * contract governs.
 */

import { isSubagent, logHookError, MSG_CLI, readHookInput } from "./lib-config.mjs";
import { parseMsgFilename, responsePlan } from "./lib-hier.mjs";
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
  let line = `you were tasked as a peer (task ${rec.task}) by ${rec.from_name} and have NOT DELIVERED your report. Call SendMessage now with to:"${rec.from}". Writing the response file is not delivery and neither is printing the token in your own output — your text is invisible to another session, so nothing has reached ${rec.from_name} until SendMessage returns.`;
  if (rec.msg) {
    const meta = parseMsgFilename(rec.msg);
    const id = meta ? meta.id : "<id>";
    line += ` The message you send must carry [hierarchy-msg <response path>].`;
    const plan = responsePlan(rec.msg);
    if (plan) line += ` If that response file does not exist yet, its path is ${plan.path}`;
    line += ` (write it with node "${MSG_CLI}" new --type response --id ${id} --req ${rec.msg}`;
    // A role whose contract denies Bash cannot run that command, and the path is derivable here.
    if (plan)
      line += `; no Bash? write the file yourself with frontmatter \`id,type: response,to,from,slug,parent,reason,eta,to_name,from_name,team,created\` and the \`## [0] tldr\` / \`## [1] status\` … sections`;
    line += `) — then SEND it.`;
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
  if (!sessionId) allow();

  const owed = pendingFor(sessionId);
  if (owed.length === 0) allow();

  const marker = latestTurnMarker(sessionId);
  const armed = !!marker && marker.status === "armed";

  // User-driven turn: the report is still owed, so still say so — but charge no
  // budget for a turn the peer did not drive, and let the re-stop through so a
  // single reminder is all one user turn can cost.
  if (!armed) {
    if (input.stop_hook_active === true) allow();
    const lines = owed.map((rec) => owedLine(rec, false));
    block(lines.length === 1 ? lines[0] : ["You have more than one unsent peer report:", ...lines.map((l) => `- ${l}`)].join("\n"));
  }

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

  // The marker is released only once nothing is owed on it any more — blocking
  // does not spend it, or the ceiling above is never reached.
  if (toNudge.length === 0) {
    disarmIfArmed(sessionId);
    allow();
  }

  const reason =
    toNudge.length === 1
      ? owedLine(toNudge[0], toNudge[0].nudges >= MAX_NUDGES)
      : ["You have more than one unsent peer report:", ...toNudge.map((rec) => `- ${owedLine(rec, rec.nudges >= MAX_NUDGES)}`)].join("\n");
  block(reason);
} catch (err) {
  logHookError("stop-peer-nudge.mjs", err);
  // fail open: never trap a session over a tracking failure
  allow();
}
