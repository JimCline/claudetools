#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse route gate: session routing preference + tier rule.
 *
 * Routing preference (Agent/Task spawning a peer-eligible role, or a
 * SendMessage peer brief): the FIRST such dispatch each session, when no
 * session route answer exists in `gates.jsonl` and no config `route` key is
 * set, is DENIED ONCE PER SESSION (not per role) with a three-option prompt;
 * the orchestrator records the answer with `msg.mjs route <value> --session
 * <id>` and re-issues. The one-shot record is `{type:"route-ask",
 * session_id}` — once made, later dispatches never ask again this session,
 * even unanswered (they fall through to the "prefer-peers" default).
 *
 * Once a route is known (session record > config `route` > "prefer-peers"
 * default — see `effectiveRoute` in lib-hier.mjs), it is enforced silently:
 *   - `subagents`: every Agent/Task spawn passes; a SendMessage peer brief is
 *     denied (route says never use peers this session).
 *   - `peers`: an Agent/Task spawn is denied while ANY live instance of that
 *     role exists (brief it instead); allowed — with an informational
 *     `systemMessage` and no `permissionDecision` — when none is live
 *     (nothing to route to).
 *   - `prefer-peers`: an Agent/Task spawn is denied only while a live
 *     instance is NOT busy; allowed when every live instance is busy or none
 *     is live.
 * Every enforcement deny is ONE-SHOT per (session, role, route): the
 * identical re-issue passes, but a mid-session route change re-arms the
 * deny for the new route. Record: `{type:"route-deny", session_id, role,
 * route}`.
 *
 * A SendMessage peer brief resolves its role from config first
 * (`resolvedPeerTargets`), then falls back to the roster: a recorded
 * instance whose name matches `to` supplies its role, so an unconfigured
 * but roster-known peer still routes and gates like any other.
 *
 * Tier gate (Agent/Task, and SendMessage peer briefs carrying the sentinel +
 * `[hierarchy-msg`): when the session model is known, the target is architect
 * or ultra-advisor, that role's tier ≤ the session tier, and the request file
 * carries no `reason:` — DENIED ONCE per (session, role) with
 * `{type:"tier-deny", session_id, role}`. Second attempt passes. With
 * `msgs:"off"` there is no request file to carry `reason:`, so the denial
 * text drops the `reason:` instruction.
 *
 * Both mechanisms are reminders, not walls; both fail open on any internal
 * error. Runs after the ultra approval gate and the msg gate, which are
 * independent.
 */

import { basename, resolve } from "node:path";

import { hierarchyRoleOf, isSubagent, PEER_ELIGIBLE_ROLES, readHookInput, resolveConfig, resolvedPeerTargets, ROLE_LABELS, tierOf } from "./lib-config.mjs";
import {
  appendGate,
  describeInstance,
  effectiveRoute,
  extractMsgToken,
  hasGate,
  hierarchyDir,
  readMsgFile,
  roleTier,
  roster,
  sessionModel,
} from "./lib-hier.mjs";
import { parseSentinel, stripRef } from "./lib-peer.mjs";

const TIER_ROLES = ["architect", "ultra-advisor"];

function decide(decision, reason, systemMessage) {
  if (decision || systemMessage) {
    const payload = {};
    if (decision) {
      payload.hookSpecificOutput = { hookEventName: "PreToolUse", permissionDecision: decision };
      if (reason) payload.hookSpecificOutput.permissionDecisionReason = reason;
    }
    if (systemMessage) payload.systemMessage = systemMessage;
    process.stdout.write(JSON.stringify(payload));
  }
  process.exit(0);
}

function askReason(ros, sessionId) {
  const liveBits = [];
  for (const role of PEER_ELIGIBLE_ROLES) {
    const live = (ros[role] || []).filter((i) => i.live);
    if (live.length) liveBits.push(`${ROLE_LABELS[role]}=${live.map(describeInstance).join("; ")}`);
  }
  return [
    `agent-hierarchy: choose this session's dispatch route before tasking roles. Live peers: ${liveBits.length ? liveBits.join(" | ") : "none"}.`,
    "Ask the user with AskUserQuestion, exactly these options in this order:",
    '  "Prefer peer agents, fall back to subagents (Recommended)" — reuse a live peer when one is free; spawn only when none is.',
    '  "Peer agents only" — never spawn a roster subagent; wait or tell the user when no peer is free.',
    '  "Subagents only" — ignore peers entirely this session.',
    `Record it: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" route <prefer-peers|peers|subagents> --session ${sessionId}`,
    "Then re-issue this exact dispatch. Say in one line what you recorded.",
  ].join("\n");
}

function subagentsDenyReason() {
  return "agent-hierarchy: route is subagents this session — spawn the subagent instead, or change route with msg.mjs route.";
}

function peersDenyReason(role, live) {
  return `agent-hierarchy: route is peers this session — live instance(s) for ${ROLE_LABELS[role]}: ${live.map(describeInstance).join("; ")}. SendMessage it (set to_name) instead of spawning, or change route with msg.mjs route.`;
}

function preferPeersDenyReason(role, live) {
  return `agent-hierarchy: route is prefer-peers this session — free live instance(s) for ${ROLE_LABELS[role]}: ${live.map(describeInstance).join("; ")}. SendMessage it (set to_name) instead of spawning, or change route with msg.mjs route.`;
}

function tierReason(model, tier, role, roleModel, roleTierN, msgsOff) {
  const escape = msgsOff
    ? "Do it inline, or re-issue this exact dispatch to proceed."
    : "Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.";
  return `tier rule: you are ${model}(${tier}) ≥ ${ROLE_LABELS[role]} ${roleModel}(${roleTierN}). ${escape}`;
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) decide(null);

  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  if (!isDispatch && !isSend) decide(null);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd);
  if (!resolved.enabled) decide(null);
  const repoBasename = basename(resolve(cwd));
  const dir = hierarchyDir(cwd);
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";

  let rosterCache = null;
  const getRoster = () => rosterCache || (rosterCache = roster(dir, resolved, repoBasename));

  let role = null;
  let text = "";
  if (isDispatch) {
    role = hierarchyRoleOf(toolInput.subagent_type);
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    if (!parseSentinel(text)) decide(null);
    const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
    role = PEER_ELIGIBLE_ROLES.find((r) => resolvedPeerTargets(r, resolved.roles[r], repoBasename).includes(to)) || null;
    if (!role && to) {
      const ros = getRoster();
      role = PEER_ELIGIBLE_ROLES.find((r) => (ros[r] || []).some((i) => i.name === to)) || null;
    }
  }

  // ---- routing preference: ask once per session, then enforce silently
  if (role && PEER_ELIGIBLE_ROLES.includes(role)) {
    const configRoute = resolved.route;
    const routeInfo = effectiveRoute(dir, resolved, sessionId);
    if (routeInfo.source !== "session" && !configRoute) {
      if (!hasGate(dir, (r) => r.type === "route-ask" && r.session_id === sessionId)) {
        appendGate(dir, { type: "route-ask", session_id: sessionId });
        decide("deny", askReason(getRoster(), sessionId));
      }
      // already asked this session and still unanswered: fall through, enforce the "prefer-peers" default
    }
    const route = routeInfo.value;
    const alreadyDenied = hasGate(dir, (r) => r.type === "route-deny" && r.session_id === sessionId && r.role === role && r.route === route);

    if (route === "subagents") {
      if (isSend && !alreadyDenied) {
        appendGate(dir, { type: "route-deny", session_id: sessionId, role, route });
        decide("deny", subagentsDenyReason());
      }
    } else if (isDispatch) {
      const live = (getRoster()[role] || []).filter((i) => i.live);
      if (route === "peers") {
        if (live.length) {
          if (!alreadyDenied) {
            appendGate(dir, { type: "route-deny", session_id: sessionId, role, route });
            decide("deny", peersDenyReason(role, live));
          }
        } else {
          decide(null, null, `agent-hierarchy: route is peers this session, but no live instance of ${ROLE_LABELS[role]} exists — spawning the subagent (nothing to route to).`);
        }
      } else if (route === "prefer-peers") {
        const free = live.filter((i) => !i.busy);
        if (free.length && !alreadyDenied) {
          appendGate(dir, { type: "route-deny", session_id: sessionId, role, route });
          decide("deny", preferPeersDenyReason(role, free));
        }
      }
    }
  }

  // ---- tier gate: same-or-lower-tier Architect / Ultra-Advisor without a reason
  if (TIER_ROLES.includes(role)) {
    const model = sessionModel(input, dir);
    const tier = tierOf(model);
    if (tier !== null) {
      const rt = roleTier(role, resolved, tier);
      if (rt !== null && rt <= tier) {
        const path = extractMsgToken(text);
        const parsed = path ? readMsgFile(path) : null;
        const reason = parsed && parsed.fm ? parsed.fm.reason : null;
        if (!reason && !hasGate(dir, (r) => r.type === "tier-deny" && r.session_id === sessionId && r.role === role)) {
          appendGate(dir, { type: "tier-deny", session_id: sessionId, role });
          decide("deny", tierReason(model, tier, role, resolved.roles[role].model, rt, resolved.msgs === "off"));
        }
      }
    }
  }

  decide(null);
} catch {
  decide(null);
}
