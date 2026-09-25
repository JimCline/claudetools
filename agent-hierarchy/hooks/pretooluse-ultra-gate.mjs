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
 * to a config read before being cleared. Another instance of the role, a
 * second one or one renamed because another session held the plain name,
 * is gated too: by the `<prefix>-<role>-<n>` pattern on every gated
 * prefix, which needs no team file, and by its recorded name in a team
 * whose prefix is gated. A SendMessage to any other peer —
 * including a peer for a different hierarchy role — passes through
 * untouched.
 *
 * A Bash call is a third route, into an Ultra-Advisor running in a Herdr pane:
 * `roster.mjs deliver` to one gets the same decision as a SendMessage (its
 * `--wait-only`, and a ping for a request already delivered, send no new
 * task). A `deliver` command the parser cannot read gets that decision, with
 * no exemption, when any of its words names an Ultra-Advisor. A raw Herdr
 * input verb aimed at one, by name or pane id, is always denied, except a
 * `send-keys` of exactly one key token. Every other Bash call is passed on
 * one string test, before any config is read. `roster.mjs` refuses a
 * `deliver` to an advise-class member itself when no approval is recorded,
 * for the shell shapes this hook cannot see.
 */

import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  declaredTier,
  hierarchyRoleOf,
  KIND_DEFAULT,
  logHookError,
  registryRoles,
  roleClass,
  readHookInput,
  resolveConfig,
  resolveHierarchyRole,
  resolveKind,
  ROSTER_CLI,
} from "./lib-config.mjs";
import { parseAhCommand } from "./lib-ah-cli.mjs";
import { getDecision, NO_SESSION_KEY, normalizeSessionId } from "./lib-gate.mjs";
import { gateTarget, herdrInputCalls } from "./lib-gate-target.mjs";
import { responsePlan } from "./lib-hier.mjs";

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

function firstUseReason(sessionId, model, retry = "dispatch (Agent call or SendMessage)") {
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
    `3. On "Yes, rest of session" or "Ask me each time", re-issue the identical ${retry} — it will proceed. On "No, not this session", do NOT retry: tell the user plainly how you will handle the question instead (Architect, or inline) and what that leaves unadjudicated.`,
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

function rawHerdrReason(name, group, verb, cwd) {
  return [
    `ah: raw \`herdr ${group} ${verb}\` to ${name} is denied: ${name} is an Ultra-Advisor, and a brief reaches it only with the user's approval, which a raw Herdr call bypasses.`,
    `Brief a non-claude Ultra-Advisor with \`node "${ROSTER_CLI}" deliver ${name} --req <request path> --cwd ${cwd}\`, run in the background; a Claude one with SendMessage.`,
  ].join("\n");
}

/** The model a gate reason names: a recorded non-claude member's own, with its declared tier, else the role's. */
function modelText(target, resolved) {
  const m = target.member;
  if (m && resolveKind(m) !== KIND_DEFAULT) return `${resolveKind(m)} ${m.model || "?"} (declared ${declaredTier(resolveKind(m), m.model) || "none"})`;
  return resolved.roles[target.role].model;
}

/**
 * The Bash shapes that can carry a brief to a Herdr pane. Every other Bash call costs this one
 * string test, and reads no config.
 */
function bashShapes(command) {
  const deliverish = command.includes("deliver") && command.includes("roster.mjs");
  const herdr = herdrInputCalls(command);
  return deliverish || herdr.length ? { deliverish, herdr } : null;
}

try {
  const input = await readHookInput();

  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  const command = toolName === "Bash" && input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : null;
  const bash = command !== null ? bashShapes(command) : null;
  if (!isDispatch && !isSend && !bash) decide(null);

  // Spec 0028 §3.2 primary fix: this gate is Orchestrator-only. A caller
  // positively attributed (§3.7) as a subordinate hierarchy role is not the
  // Orchestrator, so the gate must not fire for it — an unidentified caller
  // still falls through to the checks below, same as today.
  {
    const { role: callerRole, direct: callerDirect } = resolveHierarchyRole(input);
    if (callerDirect && callerRole) decide(null);
  }

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = normalizeSessionId(input.session_id);

  // Team scope must be resolved before repoBasename/teamPrefix — spec 0011
  // §9.1 requires every team-scoped prefix call to pass the resolved team, not
  // just the cwd — which costs the config read the fast path below used to
  // skip for non-gated tool calls.
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== NO_SESSION_KEY ? sessionId : undefined });
  if (!resolved.enabled) decide(null);

  // Every advise-class role is gated, custom ones included; one approval covers them all for the
  // session. A dispatch is gated when the lookup says advise, so `x:ultra-advisor` is gated too.
  const adviseRoles = registryRoles(resolved).filter((r) => roleClass(r, resolved) === "advise");
  const targetOf = (name) => gateTarget(name, { resolved, cwd, roles: adviseRoles });

  if (bash) {
    // A raw Herdr prompt to an Ultra-Advisor is never how it is briefed, whatever the user decided:
    // the sanctioned paths carry the approval. A single key token is the startup-dialog answer 0043
    // documents for a Claude one in a Herdr pane; anything more is a brief.
    for (const call of bash.herdr) {
      const target = targetOf(call.name);
      if (!target) continue;
      const oneKey = call.verb === "send-keys" && call.args.length === 1 && call.args[0].length <= 16 && !/\s/.test(call.args[0]);
      if (!oneKey) decide("deny", rawHerdrReason(target.member ? target.member.name : call.name, call.group, call.verb, cwd));
    }
    if (!bash.deliverish) decide(null);
    const parsed = parseAhCommand(command);
    let target = null;
    if (parsed) {
      if (parsed.script !== "roster" || parsed.verb !== "deliver") decide(null);
      target = targetOf(parsed.positional[0]);
      if (!target) decide(null);
    } else {
      // A shell shape the parser cannot read (a `cd … &&` or env prefix, a relative script path, a
      // `;` chain): its flags cannot be trusted, so no exemption applies, but any word naming an
      // Ultra-Advisor puts it through the decision.
      const words = command.split(/[\s;&|()<>`]+/).map((w) => w.replace(/^(['"])(.*)\1$/, "$2")).filter(Boolean);
      target = words.map(targetOf).find(Boolean) || null;
      if (!target) decide(null);
    }
    const decision = getDecision(sessionId);
    if (parsed) {
      // --wait-only sends nothing. A ping for a request that already has its response file carries
      // no new task: the delivery that created the file passed this gate. Neither asks again under
      // `each`; a ping is still denied under `off` and with no decision.
      if (parsed.flags["wait-only"] === true) decide(null);
      const plan = typeof parsed.flags.req === "string" ? responsePlan(parsed.flags.req) : null;
      if (parsed.flags.ping !== undefined && plan && existsSync(plan.path) && (decision === "session" || decision === "each")) decide(null);
    }
    const model = modelText(target, resolved);
    switch (decision) {
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
        decide("deny", firstUseReason(sessionId, model, "command"));
    }
  }

  let gatedRole = null;
  let target = null;
  if (isDispatch) {
    const type = typeof toolInput.subagent_type === "string" ? toolInput.subagent_type.trim() : "";
    const hit = hierarchyRoleOf(type, { resolved });
    gatedRole = hit && roleClass(hit, resolved) === "advise" ? hit : null;
  } else {
    target = targetOf(toolInput.to);
    gatedRole = target ? target.role : null;
  }
  if (!gatedRole) decide(null);

  const model = target ? modelText(target, resolved) : resolved.roles[gatedRole].model;

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
} catch (err) {
  // A gate that cannot decide must not block; exit 1 is non-blocking and leaves a trace.
  logHookError("pretooluse-ultra-gate.mjs", err);
  process.exit(1);
}
