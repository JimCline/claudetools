#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse route gate: global-scope confirm gate + session
 * routing preference + tier rule.
 *
 * Global-scope confirm gate (spec 0009 §4), two independent predicates, both
 * evaluated before routing preference:
 *   - Scope A (roster identity): fires when `resolved.rosterLevel === "global"`
 *     and the role is peer-eligible, UNLESS the dispatch is an Agent/Task spawn
 *     under route "subagents" (a SendMessage peer brief still fires — the
 *     `subagents` route denies that later anyway, but scope A is the more
 *     specific reason). `rosterLevel === null` never fires it.
 *   - Scope B (role config): fires when `resolved.sources[role] === "user"`
 *     (never `"default"` — that is every unconfigured repo, see spec §8.10),
 *     for ANY resolved role except `ultra-advisor` (its own PreToolUse gate,
 *     `pretooluse-ultra-gate.mjs`, already puts a human in the loop). Runs
 *     regardless of PEER_ELIGIBLE_ROLES/route — a plain subagent dispatch
 *     borrows the same user-scope model/effort.
 * Both are answer-or-stay-denied, strict, per (session_id, scope) — unlike the
 * routing-preference ask below, an unanswered re-issue keeps denying (with a
 * shorter reason once the first full prompt has been shown). `allow`/`deny`
 * are recorded via `msg.mjs global-scope <roster|config> <allow|deny>
 * --session <id>` as `{type:"global-scope", session_id, scope, answer}`; the
 * one-shot `{type:"global-scope-ask", session_id, scope}` only suppresses
 * re-showing the long prompt, it authorises nothing. Scope A denies before
 * scope B when both fire on one dispatch, and its reason mentions scope B is
 * pending. See docs/specs/0009-global-roster-confirm-gate.md.
 *
 * Routing preference (Agent/Task spawning a peer-eligible role, or a
 * SendMessage peer brief): the FIRST such dispatch each session, when no
 * session route answer exists in `gates.jsonl` and no config `route` key is
 * set, is DENIED ONCE PER SESSION (not per role) with a three-option prompt;
 * the orchestrator records the answer with `msg.mjs route <value> --session
 * <id>` and re-issues. The one-shot record is `{type:"route-ask",
 * session_id}` — once made, later dispatches never ask again this session,
 * even unanswered (they fall through to the "peers" default).
 *
 * Once a route is known (session record > config `route` > "peers"
 * default — see `effectiveRoute` in lib-hier.mjs), it is enforced silently:
 *   - `subagents`: every Agent/Task spawn passes; a SendMessage peer brief is
 *     denied (route says never use peers this session).
 *   - `peers`: an Agent/Task spawn is denied while ANY live instance of that
 *     role exists (brief it instead). When none is live, the FIRST such
 *     dispatch for that role this session is ALSO denied once, asking the
 *     user (via AskUserQuestion) whether to fall back to a subagent for that
 *     specific role; the identical re-issue then passes regardless of the
 *     answer — this is a reminder gate, not an enforced no. Record:
 *     `{type:"peer-fallback-ask", session_id, role}`. Per-member `onMissing`
 *     (spec 0021) overrides this default before the ask fires: "never" falls
 *     straight through to the subagent every time, no gate; "auto" denies
 *     once naming the `spawn-one` command instead of asking (record
 *     `{type:"on-missing-auto", session_id, role}`), degrading to the
 *     "prompt" behaviour above when no usable roster entry exists for the
 *     role (spec 0009 §5.2's rule: recommending a command that will fail is
 *     worse than not recommending one). Resolved from the role's FIRST
 *     roster member in roster order — this is a role-level question,
 *     independent of 0019's per-instance spawn-one selection.
 *   - `prefer-peers`: an Agent/Task spawn is denied only while a live
 *     instance is NOT busy; allowed — without asking — when every live
 *     instance is busy or none is live (the user already opted into silent
 *     subagent fallback by choosing this route).
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

import { hierarchyRoleOf, isSubagent, PEER_ELIGIBLE_ROLES, readHookInput, resolveConfig, resolvedPeerTargets, roleFromName, ROLE_LABELS, teamPrefix, tierOf } from "./lib-config.mjs";
import {
  appendGate,
  describeInstance,
  effectiveRoute,
  extractMsgToken,
  hasGate,
  hierarchyDir,
  readGates,
  readMsgFile,
  roleTier,
  roster,
  sessionModel,
} from "./lib-hier.mjs";
import { ON_MISSING_DEFAULT, resolveMemberTeam, teamMemberByName } from "./lib-roster.mjs";
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
    `ah: choose this session's dispatch route before tasking roles. Live peers: ${liveBits.length ? liveBits.join(" | ") : "none"}.`,
    "Ask the user with AskUserQuestion, exactly these options in this order:",
    '  "Peer agents only (Recommended)" — never spawn a roster subagent; when no live peer exists for a role, ask before falling back to a subagent for that role.',
    '  "Prefer peer agents, fall back to subagents" — reuse a live peer when one is free; spawn without asking when none is.',
    '  "Subagents only" — ignore peers entirely this session.',
    `Record it: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" route <peers|prefer-peers|subagents> --session ${sessionId}`,
    "Then re-issue this exact dispatch. Say in one line what you recorded.",
  ].join("\n");
}

function subagentsDenyReason() {
  return "ah: route is subagents this session — spawn the subagent instead, or change route with msg.mjs route.";
}

function peersDenyReason(role, live) {
  return `ah: route is peers this session — live instance(s) for ${ROLE_LABELS[role]}: ${live.map(describeInstance).join("; ")}. SendMessage it (set to_name) instead of spawning, or change route with msg.mjs route.`;
}

function peerFallbackAskReason(role, resolved, dir, sessionId, cwd) {
  // §5.2: offer the spawn-one option only when a roster entry for `role` exists at a
  // level this session may use (repo/repo-user, or global with a recorded scope-A allow).
  const rosterUsable = !!resolved.roster && (resolved.rosterLevel !== "global" || globalScopeAnswer(dir, sessionId, "roster") === "allow");
  const member = rosterUsable ? resolved.roster.members.find((m) => m.role === role) : null;
  if (member) {
    return [
      `ah: route is peers this session, but no live instance of ${ROLE_LABELS[role]} exists to route to.`,
      `A roster entry for ${ROLE_LABELS[role]} exists at ${resolved.rosterLevel} level (name: ${member.name}).`,
      "Ask the user with AskUserQuestion, exactly these options in this order:",
      `  "Stand up the real ${ROLE_LABELS[role]} peer (Recommended)" — node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" spawn-one ${role} --cwd ${cwd}`,
      "     Then SendMessage the peer instead of re-issuing this dispatch.",
      '  "Spawn a one-off subagent instead" — re-issue this exact dispatch.',
      `  "Neither — I'll start it myself" — do not dispatch; say you are blocked on ${ROLE_LABELS[role]}.`,
    ].join("\n");
  }
  const why = resolved.rosterLevel === "global" && !rosterUsable ? "global roster not confirmed" : `no roster entry for ${ROLE_LABELS[role]}`;
  return `ah: route is peers this session, but no live instance of ${ROLE_LABELS[role]} exists to route to (${why}). Ask the user with AskUserQuestion: "No live ${ROLE_LABELS[role]} peer is available — spawn a subagent for this role instead?", options "Yes, spawn a subagent (Recommended)" and "No, wait — I'll start the peer myself". If yes, re-issue this exact dispatch. If no, do not dispatch — wait for the peer to come up or tell the user you're blocked on ${ROLE_LABELS[role]}.`;
}

function onMissingFor(resolved, role) {
  // §4: a role-level question ("is a peer of this kind available"), not a per-instance one —
  // 0019's per-instance selection belongs to spawn-one, not here. First member in roster order.
  const member = resolved.roster && Array.isArray(resolved.roster.members) ? resolved.roster.members.find((m) => m.role === role) : null;
  return (member && member.onMissing) || ON_MISSING_DEFAULT;
}

function onMissingAutoReason(role, cwd) {
  return [
    `ah: no live ${ROLE_LABELS[role]} peer, and its on-missing policy is "auto".`,
    `Run: node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" spawn-one ${role} --cwd ${cwd}`,
    "Then SendMessage the peer instead of re-issuing this dispatch. Do not ask the user — this is configured.",
  ].join("\n");
}

function preferPeersDenyReason(role, live) {
  return `ah: route is prefer-peers this session — free live instance(s) for ${ROLE_LABELS[role]}: ${live.map(describeInstance).join("; ")}. SendMessage it (set to_name) instead of spawning, or change route with msg.mjs route.`;
}

function tierReason(model, tier, role, roleModel, roleTierN, msgsOff) {
  const escape = msgsOff
    ? "Do it inline, or re-issue this exact dispatch to proceed."
    : "Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.";
  return `tier rule: you are ${model}(${tier}) ≥ ${ROLE_LABELS[role]} ${roleModel}(${roleTierN}). ${escape}`;
}

function globalScopeAnswer(dir, sessionId, scope) {
  const recs = readGates(dir).filter((r) => r.type === "global-scope" && r.session_id === sessionId && r.scope === scope);
  return recs.length ? recs[recs.length - 1].answer : null;
}

function globalScopeReaskReason(scope, sessionId, scopeBPending) {
  const what = scope === "roster" ? "the global roster" : "user-scope role configuration";
  const note = scopeBPending ? " Note: a second question about user-scope role configuration (scope B) is also pending for this dispatch." : "";
  return `ah: you were already asked about ${what} this session and did not record an answer. Run node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" global-scope ${scope} <allow|deny> --session ${sessionId}, then re-issue.${note}`;
}

function globalRosterAskReason(resolved, sessionId, scopeBPending) {
  const members = resolved.roster.members.map((m) => `${m.name}(${m.role})`).join(", ") || "(none)";
  const lines = [
    `ah: no roster is configured for this repo (checked repo and repo-user). The roster resolving here is the GLOBAL one at ${resolved.roster.path}, members: ${members}. It may belong to an unrelated project.`,
    "Ask the user with AskUserQuestion, exactly these options in this order:",
    '  "Create a roster for this repo (Recommended)" — run the /agent-roster skill\'s Init then Add flow for this repo, then re-issue.',
    '  "Use the global roster for this session" — records allow; no further prompting for this scope.',
    `  "Subagents only this session" — node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" route subagents --session ${sessionId}`,
    `Record the answer: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" global-scope roster <allow|deny> --session ${sessionId}`,
    "Then re-issue this exact dispatch. Say in one line what you recorded.",
  ];
  if (scopeBPending) lines.push("Note: a second question about user-scope role configuration (scope B) is also pending for this dispatch.");
  return lines.join("\n");
}

function globalRosterDenyReason(sessionId) {
  return `ah: the global roster was declined for this session. Create a repo roster with the /agent-roster skill, or switch to subagents (msg.mjs route subagents --session ${sessionId}).`;
}

function globalConfigAskReason(role, resolved, sessionId) {
  const entry = resolved.roles[role];
  const lines = [
    `ah: ${ROLE_LABELS[role]}'s configuration here comes from your USER-scope config (~/.claude/agent-hierarchy.json): model=${entry.model} effort=${entry.effort || "-"} dispatch=${entry.dispatch || "-"}. This repo has no project or repo-user config for ${ROLE_LABELS[role]}, so those settings may have been set for a different project.`,
    "Ask the user with AskUserQuestion, exactly these options in this order:",
    '  "Use the user-scope settings for this session (Recommended)" — records allow.',
    '  "Set this role for this repo instead" — run the /agent-roster skill\'s Add/Edit flow at repo level, then re-issue.',
    `  "Stop — I'll decide later" — do not dispatch; say you are blocked on ${ROLE_LABELS[role]}.`,
    `Record the answer: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" global-scope config <allow|deny> --session ${sessionId}`,
    "Then re-issue this exact dispatch. Say in one line what you recorded.",
  ];
  return lines.join("\n");
}

function globalConfigDenyReason(role) {
  return `ah: user-scope role configuration was declined for this session. Set ${ROLE_LABELS[role]} at repo level with the /agent-roster skill, then re-issue.`;
}

function enforceGlobalScope(dir, sessionId, scope, askReasonFn, denyReasonFn, scopeBPending) {
  const answer = globalScopeAnswer(dir, sessionId, scope);
  if (answer === "deny") decide("deny", denyReasonFn());
  if (answer === "allow") return;
  const asked = hasGate(dir, (r) => r.type === "global-scope-ask" && r.session_id === sessionId && r.scope === scope);
  if (!asked) {
    appendGate(dir, { type: "global-scope-ask", session_id: sessionId, scope });
    decide("deny", askReasonFn());
  }
  decide("deny", globalScopeReaskReason(scope, sessionId, scopeBPending));
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
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  if (!resolved.enabled) decide(null);
  const repoBasename = teamPrefix(cwd, resolved.team);
  const dir = hierarchyDir(cwd);

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
    // Mechanism (A) — spec 0011 §4.4.1/§9.1: "what role is this name" is
    // answered by an all-teams name search, independent of `resolved.team` —
    // the team-scoped form has a silent-null failure mode when rung 2 misses.
    const membership = to ? resolveMemberTeam(dir, to) : { found: false, team: null };
    const teamMember = membership.found ? teamMemberByName(dir, to, membership.team) : null;
    role = teamMember ? teamMember.role : null;
    if (!role) role = PEER_ELIGIBLE_ROLES.find((r) => resolvedPeerTargets(r, resolved.roles[r], repoBasename).includes(to)) || null;
    if (!role && to) {
      const ros = getRoster();
      role = PEER_ELIGIBLE_ROLES.find((r) => (ros[r] || []).some((i) => i.name === to)) || null;
    }
    if (!role && to) role = roleFromName(to);
  }

  // ---- scope A/B: global-scope confirm gate (spec 0009 §4), evaluated before
  // routing preference — see the header comment for the two predicates.
  const scopeBWillFire = !!role && role !== "ultra-advisor" && resolved.sources[role] === "user";
  if (role && PEER_ELIGIBLE_ROLES.includes(role)) {
    const preRoute = effectiveRoute(dir, resolved, sessionId).value;
    const scopeAApplies = resolved.rosterLevel === "global" && !(isDispatch && preRoute === "subagents");
    if (scopeAApplies) {
      enforceGlobalScope(dir, sessionId, "roster", () => globalRosterAskReason(resolved, sessionId, scopeBWillFire), () => globalRosterDenyReason(sessionId), scopeBWillFire);
    }
  }
  if (scopeBWillFire) {
    enforceGlobalScope(dir, sessionId, "config", () => globalConfigAskReason(role, resolved, sessionId), () => globalConfigDenyReason(role));
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
      // already asked this session and still unanswered: fall through, enforce the "peers" default
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
          // spec 0021 §4: per-member on-missing policy overrides the default "ask" behaviour.
          const policy = onMissingFor(resolved, role);
          if (policy === "never") {
            decide(null, null, `ah: no live ${ROLE_LABELS[role]} peer, and its on-missing policy is "never" — spawning the subagent.`);
          }
          if (policy === "auto") {
            // §4.3: identical availability guard to peerFallbackAskReason's roster-usable check —
            // recommending a spawn-one command that will fail is worse than not recommending one.
            const rosterUsable = !!resolved.roster && (resolved.rosterLevel !== "global" || globalScopeAnswer(dir, sessionId, "roster") === "allow");
            const member = rosterUsable ? resolved.roster.members.find((m) => m.role === role) : null;
            if (member) {
              const askedAuto = hasGate(dir, (r) => r.type === "on-missing-auto" && r.session_id === sessionId && r.role === role);
              if (!askedAuto) {
                appendGate(dir, { type: "on-missing-auto", session_id: sessionId, role });
                decide("deny", onMissingAutoReason(role, cwd));
              }
              decide(null, null, `ah: no live ${ROLE_LABELS[role]} peer; its on-missing policy is "auto" and spawn-one was already recommended this session — spawning the subagent.`);
            }
            // !rosterUsable or no roster member for the role: degrade to "prompt" below (§4.3).
          }
          const askedFallback = hasGate(dir, (r) => r.type === "peer-fallback-ask" && r.session_id === sessionId && r.role === role);
          if (!askedFallback) {
            appendGate(dir, { type: "peer-fallback-ask", session_id: sessionId, role });
            decide("deny", peerFallbackAskReason(role, resolved, dir, sessionId, cwd));
          }
          decide(null, null, `ah: route is peers this session, no live instance of ${ROLE_LABELS[role]} exists, and the user was already asked this session — spawning the subagent.`);
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
