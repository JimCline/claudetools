#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse dispatch gate: role briefs travel as files.
 *
 * A role dispatch — an Agent/Task spawn of architect / implementor / reviewer
 * / ultra-advisor, or a SendMessage carrying the `[hierarchy-peer-brief`
 * sentinel (a peer tasking) — must carry `[hierarchy-msg <abs request path>]`
 * naming an existing `--request.md` under `<dir>/msgs/` whose frontmatter is
 * `type: request` and whose `to:` matches the dispatched role. Otherwise the
 * call is DENIED with the exact steps to write the file and re-issue.
 *
 * Exempt: task-runner / task-gopher (errands stay inline), any subagent
 * context (`agent_id` set — nested dispatches are 0.30.0 territory), pings /
 * chat / replies (SendMessage without the sentinel), a disabled hierarchy,
 * and `msgs:"off"` in agent-hierarchy.json. Any internal error allows.
 */

import { basename, resolve } from "node:path";

import { hierarchyRoleOf, isSubagent, MSG_CLI, PEER_ELIGIBLE_ROLES, readHookInput, resolveConfig, resolvedPeerTargets } from "./lib-config.mjs";
import { hierarchyDir, validateRequestToken } from "./lib-hier.mjs";
import { parseSentinel, stripRef } from "./lib-peer.mjs";

const GATED_ROLES = ["architect", "implementor", "reviewer", "ultra-advisor"];

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

function denyReason(role, why) {
  return [
    "ah: role dispatches carry their brief as a message file, not inline prose.",
    `1. node "${MSG_CLI}" new --to ${role || "<role>"} --from orchestrator --slug <slug> [--to-name <peer-or-agent name>] [--parent <id>] [--reason context|second-opinion|parallel]`,
    "2. Fill every section (bullets, no prose; keep every constraint verbatim; [0] tldr indexes the rest).",
    "3. Re-issue this exact dispatch with first line: [hierarchy-msg <path>] then ≤3 TL;DR lines. Peer briefs keep the [hierarchy-peer-brief ...] sentinel too.",
    `Reason this call was denied: ${why}.`,
  ].join("\n");
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

  let role = null;
  let text = "";
  if (isDispatch) {
    role = hierarchyRoleOf(toolInput.subagent_type);
    if (!role || !GATED_ROLES.includes(role)) decide(null);
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    if (!parseSentinel(text)) decide(null);
  }

  const resolved = resolveConfig(cwd);
  if (!resolved.enabled || resolved.msgs === "off") decide(null);

  if (isSend) {
    const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
    const repoBasename = basename(resolve(cwd));
    role = PEER_ELIGIBLE_ROLES.find((r) => resolvedPeerTargets(r, resolved.roles[r], repoBasename).includes(to)) || null;
  }

  const dir = hierarchyDir(cwd);
  const check = validateRequestToken(text, dir, role);
  if (check.ok) decide(null);
  decide("deny", denyReason(role, check.why));
} catch {
  decide(null);
}
