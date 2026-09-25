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
 * `ah:orchestrator` as a subagent: denied for every caller. The Orchestrator is the top-level
 * session. A bare `orchestrator` agent ref is not ours and passes.
 *
 * Orchestrator, Agent/Task spawning a chain role: a chain role runs only as a peer, so this is a
 * wall, denied every time, and the reason is the whole instruction:
 *   - a live instance exists → SendMessage it (free ones first) with this brief;
 *   - none live, the role has a roster member → the exact `spawn-one` command;
 *   - none live, no roster member for the role → the exact `spawn-ad-hoc` command.
 * Legwork roles pass: they are the only roles that run as subagents. The hook never spawns:
 * launching panes from here would sidestep the session's own Bash permission prompts and race
 * the hook timeout.
 *
 * Orchestrator, SendMessage peer brief: passes the route gate. The brief's role resolves from
 * team records first (all teams, then the team file its request names), then config peer
 * targets, then the roster, then the name's role token.
 *
 * Orchestrator, any SendMessage, brief or not: a `to` with no `[ref]` that equals the name a
 * member of the session's own team was renamed away from (`renamed_from`) is DENIED, naming the
 * member's real name: another session holds that name. A name one of the team's records holds
 * is never denied.
 *
 * Any SendMessage whose `to` is a recorded non-claude pane member is DENIED with that member's
 * `roster.mjs deliver` command: SendMessage cannot reach it, and a Claude session that happens to
 * hold the same name must not receive its brief.
 *
 * Tier gate (Agent/Task, and SendMessage peer briefs carrying the sentinel +
 * `[hierarchy-msg`): when the session model is known, the target is architect
 * or ultra-advisor, that role's tier ≤ the session tier, and the request file
 * carries no `reason:` — DENIED ONCE per (session, role) with
 * `{type:"tier-deny", session_id, role}`. Second attempt passes. With
 * `msgs:"off"` there is no request file to carry `reason:`, so the denial
 * text drops the `reason:` instruction.
 *
 * Fails open on an internal error, except that a dispatch of a built-in chain ref is denied: the
 * gate could not check it. Runs after the ultra approval gate and the msg gate, which are
 * independent.
 */

import { chainRoles, classProp, hierarchyRoleOf, HOOK_ERROR_LOG, isSubagent, KIND_DEFAULT, logHookError, readHookInput, resolveConfig, resolvedPeerTargets, resolveKind, ROLE_LABELS, roleLabel, ROSTER_CLI, roleFromName, rosterMemberFor, teamPrefix, tierOf } from "./lib-config.mjs";
import {
  appendGate,
  describeInstance,
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
import { resolveMemberTeam, teamMemberByName, teamMemberRenamedFrom } from "./lib-roster.mjs";
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

const ORCHESTRATOR_REASON = "ah: The Orchestrator is the top-level session and never runs as a subagent. Do this orchestration here.";

/** The built-in chain refs, known without reading config — the only ones the gate can still
    recognise after it has failed. */
const BUILTIN_CHAIN_REFS = ["ah:orchestrator", "ah:ultra-advisor", "ah:architect", "ah:reviewer", "ah:implementor"];

/** A gate that failed has not checked the dispatch, and passing it would run a chain role as a
    subagent, so a built-in chain ref is denied. Built from the input alone: nothing here reads
    config or can throw again. Null for anything else, which stays fail-open. */
function failClosedReason(input) {
  const tool = input && input.tool_name;
  const ref = input && input.tool_input && typeof input.tool_input.subagent_type === "string" ? input.tool_input.subagent_type.trim() : "";
  if ((tool !== "Agent" && tool !== "Task") || !BUILTIN_CHAIN_REFS.includes(ref)) return null;
  const head = `ah: the route gate hit an internal error and could not check this dispatch (logged to ${HOOK_ERROR_LOG}).`;
  if (ref === "ah:orchestrator") return `${head} The Orchestrator never runs as a subagent.`;
  const role = ref.slice("ah:".length);
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : "<abs cwd>";
  return `${head} ${ROLE_LABELS[role]} never runs as a subagent: SendMessage its live peer, or start one with \`node "${ROSTER_CLI}" spawn-one ${role} --cwd ${cwd}\`.`;
}

function peersDenyReason(role, live, resolved, cwd) {
  const ordered = [...live.filter((i) => !i.busy), ...live.filter((i) => i.busy)];
  return [
    `ah: live ${label(role)} peer(s): ${ordered.map(describeInstance).join("; ")}.`,
    `ah roles are dispatched as peers: SendMessage "${ordered[0].name}" (set to_name) with the brief this Agent call carried, instead of spawning.`,
    ...paneLine(resolved, rosterMemberFor(resolved, role), cwd),
  ].join("\n");
}

function spawnCommand(role, member, cwd) {
  if (member) return `node "${ROSTER_CLI}" spawn-one ${role} --cwd ${cwd}`;
  return `node "${ROSTER_CLI}" spawn-ad-hoc ${role} --cwd ${cwd}`;
}

function deliverCommand(name, reqPath, cwd) {
  return `node "${ROSTER_CLI}" deliver ${name} --req ${reqPath || "<request path>"} --cwd ${cwd}`;
}

function paneLine(resolved, member, cwd) {
  // A non-Claude member never appears in peers.jsonl, so it is never among the live instances this
  // gate lists; spawn-one is what reports it live.
  return member && (member.route || resolved.roster.route) === "pane"
    ? [`This member's route is pane: brief it with \`${deliverCommand("<name>", null, cwd)}\`, run in the background, not SendMessage — <name> is the name the spawn command prints, including when spawn-one reports it already live.`]
    : [];
}

/** A `to` that names a non-claude pane member: SendMessage cannot reach it, and a Claude session holding the same name must not get its brief. */
function paneSendReason(member, text, cwd) {
  return `ah: \`${member.name}\` runs in \`${resolveKind(member)}\` and cannot receive SendMessage. Brief it with \`${deliverCommand(member.name, extractMsgToken(text), cwd)}\`, run in the background.`;
}

const isPaneMember = (m) => Boolean(m) && resolveKind(m) !== KIND_DEFAULT && m.route === "pane";

function renamedReason(to, member) {
  return `${to} is not in your team; its ${label(member.role)} is ${member.name}. SendMessage "${member.name}". To reach the other session on purpose, address it with its [ref].`;
}

function spawnReason(role, resolved, member, cwd, prefix) {
  return [
    `ah: no live ${label(role)} peer. ah chain roles run as peers, never subagents.`,
    `Run: ${spawnCommand(role, member, cwd)}`,
    `Before running it, run ListAgents and add \`--names-in-use <name>\` for every live name that starts with \`${prefix}-\`.`,
    "Then SendMessage the `name` the command prints, with the brief you gave this Agent call. The session takes a few seconds to boot: if the name is not in ListAgents yet, wait until it is (`roster.mjs teams` reports it live).",
    "If the command reports the member already exists or is already live, SendMessage the name it reports.",
    'If the command refuses with `refused: "team-name-unusable"`, follow its `message`: ask the user for the team name, then re-run with `--team`. That is not a launch failure.',
    "If the command fails to launch, follow agent-team's 'When a role can't take the work'.",
    ...paneLine(resolved, member, cwd),
  ].join("\n");
}

function tierReason(model, tier, role, roleModel, roleTierN, msgsOff) {
  const escape = msgsOff
    ? "Do it inline, or re-issue this exact dispatch to proceed."
    : "Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.";
  return `tier rule: you are ${model}(${tier}) ≥ ${label(role)} ${roleModel}(${roleTierN}). ${escape}`;
}

let input = null;
try {
  input = await readHookInput();
  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  if (!isDispatch && !isSend) decide(null);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const subagentType = typeof toolInput.subagent_type === "string" ? toolInput.subagent_type.trim() : "";
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  if (!resolved.enabled) decide(null);
  if (isDispatch && subagentType === "ah:orchestrator") decide("deny", ORCHESTRATOR_REASON);
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
    role = hierarchyRoleOf(subagentType, { resolved });
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    const rawTo = typeof toolInput.to === "string" ? toolInput.to.trim() : "";
    const to = stripRef(rawTo);
    // The name a member was renamed away from belongs to another session, unless one of the team's
    // own records holds it too; only a `[ref]` says the sender means that other session.
    if (!subagent && !isSubordinateSession && to && to === rawTo && !teamMemberByName(dir, to, resolved.team)) {
      const renamed = teamMemberRenamedFrom(dir, to, resolved.team);
      if (renamed) decide("deny", renamedReason(to, renamed));
    }
    if (to) {
      const anyTeam = resolveMemberTeam(dir, to);
      const named = anyTeam.found ? teamMemberByName(dir, to, anyTeam.team) : null;
      if (isPaneMember(named)) decide("deny", paneSendReason(named, text, cwd));
    }
    if (!parseSentinel(text)) decide(null);
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
    if (isPaneMember(teamMember)) decide("deny", paneSendReason(teamMember, text, cwd));
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

  // ---- Orchestrator: a chain role runs only as a peer — the live one gets the brief, or one is spawned
  if (peerEligible && isDispatch) {
    const live = (getRoster()[role] || []).filter((i) => i.live);
    if (live.length) decide("deny", peersDenyReason(role, live, resolved, cwd));
    decide("deny", spawnReason(role, resolved, rosterMemberFor(resolved, role), cwd, repoBasename));
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
  const reason = failClosedReason(input);
  decide(reason ? "deny" : null, reason);
}
