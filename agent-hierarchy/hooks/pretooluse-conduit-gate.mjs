#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse conduit gate (spec 0028 §3): the Orchestrator
 * is the only hierarchy role that talks to the user. Denies AskUserQuestion,
 * ExitPlanMode, SendUserFile, and PushNotification for any hierarchy role
 * (architect / implementor / reviewer / ultra-advisor / task-runner) — but
 * only on POSITIVE DIRECT ATTRIBUTION (§3.7): an unidentified caller, or one
 * known only through the persisted session-role fallback, is always allowed.
 * A false deny wedges a session with no way to proceed or explain itself; a
 * false allow just reproduces today's behaviour — the same fail-open
 * direction every other gate here takes.
 *
 * No one-shot state: this gate is not offering a choice to remember, it is
 * closing a channel — it fires every time and is never wired into
 * readGateState/setDecision.
 */

import { readHookInput, resolveHierarchyRole, ROLE_LABELS } from "./lib-config.mjs";

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

const GATED_TOOLS = ["AskUserQuestion", "ExitPlanMode", "SendUserFile", "PushNotification"];

const REPORT_ALTERNATIVE =
  'put the question in your response message file\'s `open_questions` (or `want_back` when you are handing a decision back), naming each option and what it decides, then return — do not block waiting for an answer.';
const ARTIFACT_ALTERNATIVE =
  "reference it by absolute path in your response message and let the Orchestrator decide whether to surface it to the user.";

const ALTERNATIVE_BY_TOOL = {
  AskUserQuestion: REPORT_ALTERNATIVE,
  ExitPlanMode: REPORT_ALTERNATIVE,
  SendUserFile: `The file it would have sent is not sent — ${ARTIFACT_ALTERNATIVE}`,
  PushNotification: `The notification it would have sent is not sent — ${ARTIFACT_ALTERNATIVE}`,
};

function denyReason(role, toolName) {
  return [
    `ah: ${ROLE_LABELS[role] || role} does not talk to the user — the Orchestrator is the sole conduit. This call was BLOCKED and did not run.`,
    ALTERNATIVE_BY_TOOL[toolName],
    "Returning with an unresolved question is a correct outcome here, not a failure.",
    "If you reached here because another gate told you to ask the user, that gate should not have fired for your role — report it as a defect in your response message rather than retrying.",
  ].join(" ");
}

try {
  const input = await readHookInput();
  const toolName = input.tool_name;
  if (!GATED_TOOLS.includes(toolName)) decide(null);

  // §3.7: enforce only on positive direct attribution. `role` is never
  // "orchestrator" here — the Orchestrator has no entry in ROLES — so a
  // direct, non-null role is always one of the gated non-orchestrator roles.
  const { role, direct } = resolveHierarchyRole(input);
  if (!direct || !role) decide(null);

  decide("deny", denyReason(role, toolName));
} catch {
  decide(null);
}
