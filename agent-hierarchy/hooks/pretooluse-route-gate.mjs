#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse route gate: who may dispatch an ah role, and how + tier rule.
 *
 * Role sessions and subagents (Agent/Task, and SendMessage peer briefs): a subordinate role
 * session (its own `up` row carries a role other than orchestrator) or any subagent (hook input
 * with `agent_id`) never dispatches a peer-eligible ah role — an Agent/Task spawn of one, or a
 * sentinel-bearing SendMessage brief to one, is DENIED EVERY TIME with route-back text: the need
 * goes back to the Orchestrator as NEEDS-<ROLE> / NEEDS-EVIDENCE. Legwork (`ah:task-runner`,
 * `task-gopher:*`), non-ah agent types, replies, and every other subagent tool call pass
 * untouched. A session whose own identity cannot be resolved (no session_id) is treated as the
 * Orchestrator: `__nosession__` never matches sessionstart.mjs's `session_id: null` row, so
 * `upRecordFor` finds nothing and `selfRole` is null — the safe direction.
 *
 * Orchestrator, Agent/Task spawning a peer-eligible role: ah dispatch is a peer unless the user
 * opted in (`subagentOptIn` in lib-config.mjs — the same predicate the directive renders from).
 * With an opt-in the spawn passes. `prefer-peers` with a free live peer denies once per
 * (session, role, route) — record `{type:"route-deny", ...}` — and the re-issue passes.
 * Otherwise it is a wall, denied every time, and the reason is the whole instruction:
 *   - a live instance exists → SendMessage it (free ones first) with this brief;
 *   - none live, the role's first roster member has `onMissing` "auto" or unset → the exact
 *     `spawn-one` command;
 *   - none live, that member has an explicit `onMissing:"prompt"` → a one-shot AskUserQuestion,
 *     spawn-the-peer first; the re-issue passes (record `{type:"peer-fallback-ask", ...}`);
 *   - none live, no roster member for the role → the exact `spawn-ad-hoc` command.
 * The hook never spawns: launching panes from here would sidestep the session's own Bash
 * permission prompts and race the hook timeout.
 *
 * Orchestrator, SendMessage peer brief: under route `subagents` it is denied once per
 * (session, role, route); otherwise it passes. The brief's role resolves from team records
 * first (all teams, then the team file its request names), then config peer targets, then the
 * roster, then the name's role token.
 *
 * Tier gate (Agent/Task, and SendMessage peer briefs carrying the sentinel +
 * `[hierarchy-msg`): when the session model is known, the target is architect
 * or ultra-advisor, that role's tier ≤ the session tier, and the request file
 * carries no `reason:` — DENIED ONCE per (session, role) with
 * `{type:"tier-deny", session_id, role}`. Second attempt passes. With
 * `msgs:"off"` there is no request file to carry `reason:`, so the denial
 * text drops the `reason:` instruction.
 *
 * Fails open on any internal error. Runs after the ultra approval gate and the msg gate, which
 * are independent.
 */

import { chainRoles, classProp, hierarchyRoleOf, isSubagent, logHookError, MSG_CLI, readHookInput, resolveConfig, resolvedPeerTargets, roleLabel, ROSTER_CLI, roleFromName, rosterMemberFor, subagentOptIn, teamPrefix, tierOf } from "./lib-config.mjs";
import {
  appendGate,
  describeInstance,
  effectiveRoute,
  extractMsgToken,
  hasGate,
  hierarchyDir,
  messageHome,
  readMsgFile,
  roleTier,
  roster,
  sessionModel,
  upRecordFor,
} from "./lib-hier.mjs";
import { ON_MISSING_DEFAULT, resolveMemberTeam, teamMemberByName } from "./lib-roster.mjs";
import { parseSentinel, stripRef } from "./lib-peer.mjs";

/** The registry this call resolved; labels for custom roles come from it. */
let registry = null;
const label = (role) => roleLabel(role, registry);

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

const needsLabel = (role) => `NEEDS-${role.toUpperCase()}`;

function routeBackReason(role, subagent) {
  const where = subagent
    ? "Put it in your final report to the session that spawned you."
    : "Put it in your report: your response file, or your reply to the brief's reply-to.";
  return [
    `ah: role sessions and subagents do not dispatch ah roles (${label(role)} here) — only the Orchestrator does.`,
    `Route it back to your Orchestrator as ${needsLabel(role)} — or NEEDS-EVIDENCE when what you need is a run or a measurement — saying what is needed and why. ${where}`,
    "Legwork stays available: task-gopher:* and ah:task-runner.",
  ].join("\n");
}

const optInCmd = (sessionId) => `node "${MSG_CLI}" route subagents --session ${sessionId}`;

function subagentsDenyReason() {
  return "ah: route is subagents this session — spawn the subagent instead, or change route with msg.mjs route.";
}

function peersDenyReason(role, live, sessionId, resolved) {
  const ordered = [...live.filter((i) => !i.busy), ...live.filter((i) => i.busy)];
  return [
    `ah: live ${label(role)} peer(s): ${ordered.map(describeInstance).join("; ")}.`,
    `ah roles are dispatched as peers: SendMessage "${ordered[0].name}" (set to_name) with the brief this Agent call carried, instead of spawning.`,
    `A subagent only if the user opts in: ${optInCmd(sessionId)}.`,
    ...paneLine(resolved, rosterMemberFor(resolved, role)),
  ].join("\n");
}

function preferPeersDenyReason(role, live) {
  return `ah: route is prefer-peers this session — free live instance(s) for ${label(role)}: ${live.map(describeInstance).join("; ")}. SendMessage it (set to_name) instead of spawning, or change route with msg.mjs route.`;
}

function spawnCommand(role, member, cwd, model) {
  if (member) return `node "${ROSTER_CLI}" spawn-one ${role} --cwd ${cwd}`;
  return `node "${ROSTER_CLI}" spawn-ad-hoc ${role} --cwd ${cwd}${model ? ` --model ${model}` : ""}`;
}

function paneLine(resolved, member) {
  return member && (member.route || resolved.roster.route) === "pane" ? ["This member's route is pane: drive it with `herdr agent prompt`, not SendMessage."] : [];
}

function spawnReason(role, resolved, member, cwd, model, sessionId) {
  return [
    `ah: no live ${label(role)} peer. ah roles are dispatched as peers, never subagents, unless the user opts in.`,
    `Run: ${spawnCommand(role, member, cwd, model)}`,
    "Then SendMessage the `name` the command prints, with the brief you gave this Agent call. The session takes a few seconds to boot: if the name is not in ListAgents yet, wait until it is (`roster.mjs teams` reports it live).",
    "If the command reports the member already exists or is already live, SendMessage the name it reports.",
    `If the command fails (no herdr or tmux, launch error), tell the user and ask whether to opt into subagents: ${optInCmd(sessionId)}. Re-issue this Agent call only after that is recorded; it is denied every time until then.`,
    ...paneLine(resolved, member),
  ].join("\n");
}

function promptAskReason(role, resolved, member, cwd) {
  return [
    `ah: no live ${label(role)} peer, and its roster member ${member.name ? `"${member.name}" ` : ""}has on-missing policy "prompt".`,
    "Ask the user with AskUserQuestion, exactly these options in this order:",
    `  "Spawn the ${label(role)} peer (Recommended)" — ${spawnCommand(role, member, cwd, null)}, then SendMessage the name it prints with this brief instead of re-issuing this dispatch.`,
    '  "Use a subagent for this dispatch" — re-issue this exact dispatch.',
    `  "Neither — I'll start it myself" — do not dispatch; say you are blocked on ${label(role)}.`,
    ...paneLine(resolved, member),
  ].join("\n");
}

function tierReason(model, tier, role, roleModel, roleTierN, msgsOff) {
  const escape = msgsOff
    ? "Do it inline, or re-issue this exact dispatch to proceed."
    : "Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.";
  return `tier rule: you are ${model}(${tier}) ≥ ${label(role)} ${roleModel}(${roleTierN}). ${escape}`;
}

try {
  const input = await readHookInput();
  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  if (!isDispatch && !isSend) decide(null);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  if (!resolved.enabled) decide(null);
  registry = resolved;
  const repoBasename = teamPrefix(cwd, resolved.team);
  const dir = hierarchyDir(cwd);

  const subagent = isSubagent(input);
  const selfRole = subagent ? null : (upRecordFor(dir, sessionId) || {}).role || null;
  const isSubordinateSession = selfRole !== null && selfRole !== "orchestrator";

  let rosterCache = null;
  const getRoster = () => rosterCache || (rosterCache = roster(dir, resolved, repoBasename));

  let role = null;
  let text = "";
  if (isDispatch) {
    role = hierarchyRoleOf(toolInput.subagent_type, { resolved });
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    if (!parseSentinel(text)) decide(null);
    const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
    // Mechanism (A) — spec 0011 §4.4.1/§9.1: "what role is this name" is
    // answered by an all-teams name search, independent of `resolved.team` —
    // the team-scoped form has a silent-null failure mode when rung 2 misses.
    let teamDir = dir;
    let membership = to ? resolveMemberTeam(dir, to) : { found: false, team: null };
    if (to && !membership.found) {
      // The brief's request file names its team file by absolute path, so a session whose cwd
      // moved away from the checkout it spawned the teammate from still finds the record.
      const reqPath = extractMsgToken(text);
      const req = reqPath ? readMsgFile(reqPath) : null;
      const home = req ? messageHome(reqPath, req.fm) : null;
      if (home) {
        teamDir = home;
        membership = resolveMemberTeam(home, to);
      }
    }
    const teamMember = membership.found ? teamMemberByName(teamDir, to, membership.team) : null;
    role = teamMember ? teamMember.role : null;
    if (!role) role = chainRoles(resolved).find((r) => resolvedPeerTargets(r, resolved.roles[r], repoBasename).includes(to)) || null;
    if (!role && to) {
      const ros = getRoster();
      role = chainRoles(resolved).find((r) => (ros[r] || []).some((i) => i.name === to)) || null;
    }
    if (!role && to) role = roleFromName(to, resolved);
  }
  const peerEligible = !!role && classProp(role, resolved, "chain") === true;

  // ---- role sessions and subagents: never dispatch an ah role, whatever the route or config
  if (subagent || isSubordinateSession) {
    if (peerEligible) decide("deny", routeBackReason(role, subagent));
    decide(null);
  }

  // ---- Orchestrator: ah dispatch is a peer unless the user opted in
  if (peerEligible) {
    const routeInfo = effectiveRoute(dir, resolved, sessionId);
    const route = routeInfo.value;
    const alreadyDenied = hasGate(dir, (r) => r.type === "route-deny" && r.session_id === sessionId && r.role === role && r.route === route);

    if (isSend) {
      if (route === "subagents" && !alreadyDenied) {
        appendGate(dir, { type: "route-deny", session_id: sessionId, role, route });
        decide("deny", subagentsDenyReason());
      }
    } else {
      const live = (getRoster()[role] || []).filter((i) => i.live);
      const free = live.filter((i) => !i.busy);
      const optedIn = subagentOptIn(role, resolved, routeInfo, live);
      if (!optedIn && route === "prefer-peers" && free.length) {
        if (!alreadyDenied) {
          appendGate(dir, { type: "route-deny", session_id: sessionId, role, route });
          decide("deny", preferPeersDenyReason(role, free));
        }
      } else if (!optedIn) {
        if (live.length) decide("deny", peersDenyReason(role, live, sessionId, resolved));
        const member = rosterMemberFor(resolved, role);
        if (member && (member.onMissing || ON_MISSING_DEFAULT) === "prompt") {
          if (!hasGate(dir, (r) => r.type === "peer-fallback-ask" && r.session_id === sessionId && r.role === role)) {
            appendGate(dir, { type: "peer-fallback-ask", session_id: sessionId, role });
            decide("deny", promptAskReason(role, resolved, member, cwd));
          }
          decide(null, null, `ah: no live ${label(role)} peer, its on-missing policy is "prompt", and the user was already asked this session — spawning the subagent.`);
        }
        const model = typeof toolInput.model === "string" && toolInput.model ? toolInput.model : null;
        decide("deny", spawnReason(role, resolved, member, cwd, model, sessionId));
      }
    }
  }

  // ---- tier gate: same-or-lower-tier Architect / Ultra-Advisor without a reason
  if (role && classProp(role, resolved, "tier") === true) {
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
} catch (err) {
  logHookError("pretooluse-route-gate.mjs", err);
  decide(null);
}
