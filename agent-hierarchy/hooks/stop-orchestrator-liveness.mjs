#!/usr/bin/env node
/**
 * agent-hierarchy — Stop hook: Orchestrator-side liveness check-in (spec 0028
 * §5). A Stop hook that refuses to let the Orchestrator go quiet while it is
 * still owed a report from a peer it dispatched.
 *
 * "Is this the Orchestrator" is resolved the same way `pretooluse-route-gate.mjs`
 * already does (and the same direction `pretooluse-*-gate.mjs` now do via
 * `resolveHierarchyRole`, §3.2): a caller positively attributed as a
 * SUBORDINATE hierarchy role is definitely not the Orchestrator and is
 * skipped; everything else (no attribution at all — the common case for a
 * plain top-level session) proceeds, on the same fail-open-toward-enforcement
 * direction used throughout this plugin.
 *
 * §5.3 (r4, finding 3): outstanding dispatches are this session's own
 * `type:"dispatch"` records (lib-peer.mjs, written by
 * posttooluse-peer-resolve.mjs the moment this session sends a request
 * token) cross-referenced against the messages directory — NOT the
 * peer-pending obligation store, which is keyed on the RECIPIENT's
 * session_id and so cannot answer "did THIS session dispatch this", and
 * would miss a peer that died before ever receiving the brief.
 *
 * §5.5: mutually exclusive with `stop-peer-nudge.mjs` by role — a session
 * that itself OWES a report takes precedence over one that is OWED one;
 * this hook cedes whenever the session has ANY pending peer obligation,
 * regardless of turn-marker state. (An armed-marker precondition check was
 * tried first but is racy: stop-peer-nudge.mjs disarms the marker as a side
 * effect of its own block, so whichever of the two Stop hooks runs second
 * would see a disarmed marker even on a turn peer-nudge legitimately just
 * blocked — order-dependent on hooks.json's array order, which nothing here
 * can rely on holding. Ceding on `pendingFor().length > 0` alone has no such
 * dependency: it is a superset of the cases where peer-nudge would actually
 * block, and this hook staying silent on the rest costs nothing.)
 */

import { hierarchyDir, isSubagent, readHookInput, resolveConfig, resolveHierarchyRole } from "./lib-config.mjs";
import { appendGate, exchangeAgeSec, openExchanges, readGates, readMsgFile } from "./lib-hier.mjs";
import { dispatchRecordsFor, MAX_NUDGES, pendingFor } from "./lib-peer.mjs";

function allow() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

/** small=5min, medium=10min, large=20min; absent/unrecognised treated as small — spec §5.6. */
const ETA_THRESHOLD_SEC = { small: 5 * 60, medium: 10 * 60, large: 20 * 60 };

function thresholdFor(eta) {
  return ETA_THRESHOLD_SEC[eta] || ETA_THRESHOLD_SEC.small;
}

/**
 * §5.3 (r4): open exchanges THIS session dispatched on the peer route — a
 * dispatch record for the exchange's id exists among this session's own
 * (§5.3's header comment) — past their `eta` threshold (§5.6, T13). A
 * subagent dispatch never goes through SendMessage, so it never gets a
 * dispatch record either — that alone is what excludes it here (T14), no
 * separate check needed.
 */
function outstandingDispatches(dir, resolved, sessionId, now) {
  const myDispatches = new Map(dispatchRecordsFor(sessionId).map((r) => [r.request_id, r]));
  const out = [];
  for (const e of openExchanges(dir, resolved.team)) {
    if (!myDispatches.has(e.id)) continue; // no dispatch record from THIS session for this id (T14, T28)
    const parsed = readMsgFile(e.request.path);
    const fm = parsed && parsed.fm;
    if (!fm || fm.from !== "orchestrator") continue;
    const ageSec = exchangeAgeSec(e, now);
    const eta = fm.eta || "small";
    if (ageSec < thresholdFor(eta)) continue; // too young to flag (T13)
    out.push({ id: e.id, role: e.to, to_name: fm.to_name || "(unnamed)", path: e.request.path, ageSec, created: fm.created, eta });
  }
  return out;
}

function fmtAge(sec) {
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

function checkInReason(items) {
  const lines = [
    "ah: you have outstanding peer dispatch(es) past their eta threshold — this Stop is BLOCKED until you check in:",
    ...items.map((it) => `- ${it.role} "${it.to_name}", request ${it.id}, sent ${fmtAge(it.ageSec)} ago (${it.path})`),
    "For each: call ListAgents to confirm the peer session is still alive, then SendMessage it a short status query.",
    "If it answers, work continues — nothing more to do here. If it is gone or silent after checking, that is a fact you (the conduit) should surface to the user.",
    "If you deliberately parked this dispatch, you may stop — this is the last check before it is no longer blocked.",
  ];
  return lines.join("\n");
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) allow();

  const { role: callerRole, direct: callerDirect } = resolveHierarchyRole(input);
  if (callerDirect && callerRole) allow(); // positively a subordinate role — not the Orchestrator

  if (input.stop_hook_active === true) allow();

  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  // §5.5: the obligation this session OWES takes precedence — but spec 0031
  // §4.1a: a record armed by the widened msg-token path must NOT cede this
  // check, or a session receiving any msg-file request (including one
  // addressed to "orchestrator") would silently stop being held to its own
  // outstanding dispatches. A record with no `armed_by` predates the field
  // and is treated as sentinel-armed (existing behaviour), not msg-token.
  if (sessionId && pendingFor(sessionId).some((r) => r.armed_by !== "msg-token")) allow();

  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd, { sessionId: sessionId || undefined });
  if (!resolved.enabled) allow();

  const dir = hierarchyDir(cwd);
  const now = Date.now();
  const outstanding = outstandingDispatches(dir, resolved, sessionId, now);
  if (outstanding.length === 0) allow();

  const toBlockOn = [];
  for (const item of outstanding) {
    const count = readGates(dir).filter((r) => r.type === "liveness-nudge" && r.session_id === sessionId && r.request_id === item.id).length;
    if (count >= MAX_NUDGES) continue;
    appendGate(dir, { type: "liveness-nudge", session_id: sessionId, request_id: item.id });
    toBlockOn.push(item);
  }
  if (toBlockOn.length === 0) allow(); // every outstanding id already spent its nudges — escape hatch, §4.4's rationale extended here

  block(checkInReason(toBlockOn));
} catch {
  allow();
}
