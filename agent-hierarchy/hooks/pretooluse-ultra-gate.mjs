#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate on Ultra-Advisor escalation.
 *
 * The Ultra-Advisor is the escalation apex and the most expensive tier in the
 * hierarchy, so it does not run on the Orchestrator's say-so alone. The first
 * dispatch attempt in a session is DENIED with instructions telling the
 * Orchestrator to put the decision to the user and record the answer; later
 * dispatches follow whatever the user chose.
 *
 * Denying and having the model ask (rather than returning "ask" outright) is
 * what buys the three-way choice: the native permission dialog offers only
 * allow/deny, and "ask me each time" has to be one of the answers.
 *
 * Inert unless the dispatch is an Ultra-Advisor dispatch and the hierarchy is
 * enabled — every other tool call passes through untouched.
 *
 * Covers TWO routes to the same role, so neither can bypass the gate: an
 * Agent/Task dispatch matched by subagent_type, and a SendMessage matched by
 * its `to` target naming the Ultra-Advisor's peer session — normally the
 * "<repo>-ultra-advisor" convention, but a role's `peer` config value can
 * name any session explicitly — or several (see `resolvedPeerTargets` in
 * lib-config.mjs; any of them is gated),
 * so a SendMessage that misses the convention-name fast path falls through
 * to a config read before being cleared. A SendMessage to any other peer —
 * including a peer for a different hierarchy role — passes through
 * untouched.
 */

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { peerName, readHookInput, resolveConfig, resolvedPeerTargets, teamPrefix } from "./lib-config.mjs";
import { getDecision, isGatedPeerTarget, isGatedSubagentType, normalizeSessionId } from "./lib-gate.mjs";

const GATE_CLI = join(dirname(fileURLToPath(import.meta.url)), "gate.mjs");

/** Emit a PreToolUse decision and exit. Passing no decision lets the call proceed under normal permissions. */
function decide(decision, reason) {
  if (decision) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: decision,
          permissionDecisionReason: reason,
        },
      })
    );
  }
  process.exit(0);
}

function setCommand(sessionId, choice) {
  return `node "${GATE_CLI}" set --session "${sessionId}" --choice ${choice}`;
}

function firstUseReason(sessionId, model) {
  return [
    `Ultra-Advisor escalation is user-gated and this session has no decision on record. The dispatch was BLOCKED — it did not run.`,
    ``,
    `Ultra-Advisor runs on "${model}", the most expensive tier in the hierarchy, and exists only for the genuinely hard or high-stakes call. The user decides whether it runs. Do all three steps before retrying:`,
    ``,
    `1. Call AskUserQuestion. Header "Ultra-Advisor". Ask whether to escalate, naming in one line the specific question you would hand it and why the Architect could not settle it. Offer EXACTLY these three options, in this order:`,
    `   - "Yes, rest of session" — Escalate now, and allow every later Ultra-Advisor dispatch this session without asking again.`,
    `   - "Ask me each time" — Escalate now, but prompt again at every later escalation.`,
    `   - "No, not this session" — Do not escalate; block Ultra-Advisor for the rest of this session.`,
    ``,
    `2. Record the answer by running this command verbatim, with CHOICE replaced by session, each, or off to match what the user picked:`,
    `   ${setCommand(sessionId, "CHOICE")}`,
    ``,
    `3. On "Yes, rest of session" or "Ask me each time", re-issue the identical dispatch (Agent call or SendMessage) — it will proceed. On "No, not this session", do NOT retry: tell the user plainly how you will handle the question instead (Architect, or inline) and what that leaves unadjudicated.`,
    ``,
    `Do not reword the options, do not record a choice the user did not pick, and do not skip step 2 — without it this gate denies again. If handoff flow is "confirm", this prompt REPLACES item 0's handoff confirmation for this dispatch: ask once, not twice.`,
  ].join("\n");
}

function blockedReason(sessionId) {
  return [
    `Ultra-Advisor escalation is blocked for this session — the user answered "No, not this session" at the escalation gate. The dispatch was BLOCKED and did not run.`,
    ``,
    `Do not retry it and do not ask again this session. Handle the question with the Architect or inline, and state plainly what that leaves unadjudicated.`,
    ``,
    `Only if the user asks to re-enable escalation, run:`,
    `   ${setCommand(sessionId, "session")}    (or --choice each to be asked each time)`,
  ].join("\n");
}

function eachTimeReason(model) {
  return `Ultra-Advisor escalation (model "${model}") — the escalation apex and the most expensive tier in the hierarchy. The user chose to be asked before each escalation.`;
}

const input = await readHookInput();

const toolName = input.tool_name;
const isDispatch = toolName === "Agent" || toolName === "Task";
const isSend = toolName === "SendMessage";
if (!isDispatch && !isSend) decide(null);

const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
const repoBasename = teamPrefix(cwd);

// Cheap string check first, against the shipped "<repo>-ultra-advisor"
// convention — this alone gates every install that hasn't set a custom peer
// name, so the common case still never pays for a config-file read. Only a
// SendMessage that misses this fast path falls through to one, because a
// custom `peer` value for the ultra-advisor role can only be known by
// reading the config that holds it. Agent/Task dispatches are matched by
// subagent_type and never need the fallback.
let gated = isDispatch
  ? isGatedSubagentType(toolInput.subagent_type)
  : isGatedPeerTarget(toolInput.to, peerName(repoBasename, "ultra-advisor"));

let resolved = null;
if (!gated && isSend) {
  resolved = resolveConfig(cwd);
  gated = resolvedPeerTargets("ultra-advisor", resolved.roles["ultra-advisor"], repoBasename).some((name) => isGatedPeerTarget(toolInput.to, name));
}
if (!gated) decide(null);

// A disabled hierarchy has no Ultra-Advisor role to gate.
resolved ||= resolveConfig(cwd);
if (!resolved.enabled) decide(null);

const sessionId = normalizeSessionId(input.session_id);
const model = resolved.roles["ultra-advisor"].model;

switch (getDecision(sessionId)) {
  case "session":
    decide(null);
    break;
  case "each":
    decide("ask", eachTimeReason(model));
    break;
  case "off":
    decide("deny", blockedReason(sessionId));
    break;
  default:
    decide("deny", firstUseReason(sessionId, model));
}
