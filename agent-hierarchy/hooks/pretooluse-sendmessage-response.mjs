#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse SendMessage response nudge (spec 0031).
 *
 * `pretooluse-msg-gate.mjs` covers the Orchestrator DISPATCHING a role; this
 * hook covers the opposite direction — a directly-attributed `architect` or
 * `implementor` session that owes a response to a message-file request must
 * deliver its answer as a response FILE, named with `[hierarchy-msg <path>]`
 * as the first line of the SendMessage reporting it. Two separate hooks
 * because one deny text cannot express both polarities, and because the
 * dispatch gate's `!parseSentinel(text) -> allow` exemption for pings/chat
 * would make a response gate un-fireable if folded into it (spec 0031 §2).
 *
 * The trigger is `pendingFor(session_id)` carrying a `msg`-bearing record —
 * only populated once `extractPendingRecord` (lib-peer.mjs) arms on the
 * `[hierarchy-msg <request path>]` form, not just the older peer-brief
 * sentinel (Fix D, spec 0031 §4.1). `reviewer` and `ultra-advisor` are
 * excluded (spec 0028 §3.6): those roles cannot Write a response file, so
 * this gate must never fire for them.
 *
 * One-round nudge, keyed on the oldest open request id, mirroring
 * `subagentstop-msg-nudge.mjs:106-116`: a first miss denies once and records
 * `send-nudge`; the retry — token or not — allows and records
 * `send-nudge-unmet` rather than silently passing. A token that IS present
 * but fails `validateResponseToken` (wrong file, wrong `from`, or an id that
 * answers a different request — Fix F) is a different failure: a typo to
 * fix, not a judgment call to defer, so it denies on every attempt with no
 * one-round allowance.
 *
 * Nudge state goes to `gates.jsonl` (`hasGate`/`appendGate`) — a different
 * store from the peer-pending obligation records this hook only reads.
 *
 * Fails open on every error path, exactly like the rest of this plugin.
 */

import { isSubagent, MSG_CLI, readHookInput, resolveConfig, resolveHierarchyRole } from "./lib-config.mjs";
import { appendGate, extractMsgToken, hasGate, hierarchyDir, parseMsgFilename, readMsgFile, validateResponseToken } from "./lib-hier.mjs";
import { pendingFor } from "./lib-peer.mjs";

const GATED_ROLES = ["architect", "implementor"];

function decide(decision, reason) {
  if (decision) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: reason },
      })
    );
  }
  process.exit(0);
}

function requesterOf(rec) {
  const req = readMsgFile(rec.msg);
  return req && req.fm && req.fm.from ? req.fm.from : "orchestrator";
}

function denyReason(qualifying, role) {
  const lines = [
    "ah: this SendMessage did not send — you hold an unanswered message-file request and must reply with a response FILE, not inline prose.",
    "Open request(s) you have not answered:",
  ];
  for (const rec of qualifying) {
    const meta = parseMsgFilename(rec.msg);
    const id = meta ? meta.id : "<id>";
    const from = requesterOf(rec);
    lines.push(`- ${id} (from ${from}): node "${MSG_CLI}" new --type response --id ${id} --to ${from} --from ${role} --req ${rec.msg}`);
  }
  lines.push(
    "Then send: [hierarchy-msg <response path>] as the first line, followed by the [1] status bullet.",
    "If this message is a status update or check-in rather than your answer, send it again unchanged and it will go through."
  );
  return lines.join("\n");
}

function invalidTokenReason(why) {
  return [
    "ah: this SendMessage did not send — the [hierarchy-msg <path>] pointer it carries does not satisfy an open request.",
    `Reason: ${why}.`,
    "Point it at your own response file for the correct request id, or omit the token entirely if this is a status update or check-in.",
  ].join("\n");
}

function byTs(a, b) {
  return String(a.ts).localeCompare(String(b.ts));
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "SendMessage") decide(null);
  if (isSubagent(input)) decide(null);

  const { role: callerRole, direct: callerDirect } = resolveHierarchyRole(input);
  if (!callerDirect || !GATED_ROLES.includes(callerRole)) decide(null);

  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  if (!resolved.enabled || resolved.msgs === "off") decide(null);

  const qualifying = pendingFor(sessionId)
    .filter((r) => typeof r.msg === "string" && r.msg)
    .sort(byTs);
  if (qualifying.length === 0) decide(null);

  const dir = hierarchyDir(cwd);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const text = typeof toolInput.message === "string" ? toolInput.message : "";
  const token = extractMsgToken(text);

  if (token) {
    for (const rec of qualifying) {
      const meta = parseMsgFilename(rec.msg);
      const check = validateResponseToken(text, dir, callerRole, meta ? meta.id : null);
      if (check.ok) decide(null);
    }
    // Present but satisfies no open request: re-check the oldest for the reported reason.
    const meta = parseMsgFilename(qualifying[0].msg);
    const check = validateResponseToken(text, dir, callerRole, meta ? meta.id : null);
    decide("deny", invalidTokenReason(check.why));
  }

  const oldest = qualifying[0];
  const oldestMeta = parseMsgFilename(oldest.msg);
  const requestId = oldestMeta ? oldestMeta.id : oldest.msg;

  if (hasGate(dir, (r) => r.type === "send-nudge" && r.id === requestId)) {
    appendGate(dir, { type: "send-nudge-unmet", id: requestId });
    decide(null);
  }

  appendGate(dir, { type: "send-nudge", id: requestId, session_id: sessionId });
  decide("deny", denyReason(qualifying, callerRole));
} catch {
  decide(null);
}
