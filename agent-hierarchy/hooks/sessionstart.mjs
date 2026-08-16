#!/usr/bin/env node
/**
 * agent-hierarchy — SessionStart context injection.
 *
 * Injects the resolved role→model table plus the orchestration protocol, so a
 * fresh, resumed, forked, or post-compaction session starts already knowing
 * which model each role runs on and how to route work through the chain.
 *
 * Gating, in this order:
 *   - Subagent (`agent_id` set) → inject NOTHING. `agent-hierarchy:*` role
 *     agents must never receive the protocol, since subagents can nest and an
 *     Implementor that starts orchestrating defeats the hierarchy; foreign
 *     subagents such as `task-gopher:task-gopher` should not pay for it
 *     either. Each role agent gets its own instructions from its `agents/*.md`
 *     body, which IS loaded at spawn. Unlike sibling plugins that must relay
 *     their directives into subagents to work at all (see
 *     docs/subagent-directive-relay.md), suppression is the INTENT here. A
 *     soft role-gate sentence stays in the directive as a backstop for paths
 *     where the hook does not run.
 *   - Top-level `--agent <hierarchy role>` (`agent_type` set, `agent_id` not)
 *     → the role-session notice. It is a main session, so the directive would
 *     otherwise reach it, but it is NOT the Orchestrator. A top-level
 *     `--agent` session running a non-hierarchy agent deliberately falls
 *     through: it is a legitimate main session that may orchestrate.
 *   - Top-level, configured, enabled  → the directive.
 *   - Top-level, no usable config     → a one-line setup nudge.
 *   - Top-level, config with enabled:false → silence (the user opted out;
 *     nudging them to configure would be wrong).
 *
 * There is exactly ONE write to stdout in this file, at the very end. Two JSON
 * objects on stdout is malformed output, and the harness drops the injection
 * without saying so — so build the string first, then write it once.
 */

import {
  buildDirective,
  buildNudge,
  buildRoleSessionNotice,
  hierarchyRoleOf,
  isSubagent,
  isTopLevelAgentSession,
  readHookInput,
  resolveConfig,
} from "./lib-config.mjs";

const input = await readHookInput();

let context = null;

if (!isSubagent(input)) {
  const role = isTopLevelAgentSession(input) ? hierarchyRoleOf(input.agent_type) : null;

  if (role) {
    context = buildRoleSessionNotice(role, input.agent_type);
  } else {
    const resolved = resolveConfig(input.cwd || process.cwd());
    if (!resolved.configured) context = buildNudge(resolved);
    else if (resolved.enabled) context = buildDirective(resolved, input.session_id);
  }
}

if (context) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: context,
      },
    })
  );
}
