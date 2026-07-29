#!/usr/bin/env node
/**
 * agent-hierarchy — SessionStart context injection.
 *
 * Injects the resolved role→model table plus the orchestration protocol, so a
 * fresh, resumed, forked, or post-compaction session starts already knowing
 * which model each role runs on and how to route work through the chain.
 *
 * Gating:
 *   - Any subagent (`agent_type` set) → inject NOTHING. Belt-and-braces only:
 *     SessionStart fires for the main session alone, so this branch is not what
 *     keeps the protocol out of subagents — the platform does. Suppression is
 *     nonetheless the INTENT here, unlike sibling plugins that must relay their
 *     directives into subagents to work at all (see
 *     docs/subagent-directive-relay.md): `agent-hierarchy:*` role agents must
 *     never receive the protocol, since subagents can nest and an Implementor
 *     that starts orchestrating defeats the hierarchy. Foreign subagents such
 *     as `task-gopher:task-gopher` should not pay for it either. Each role
 *     agent gets its own instructions from its `agents/*.md` body, which IS
 *     loaded at spawn. A soft role-gate sentence stays in the directive as a
 *     backstop for paths where the hook does not run.
 *   - Top-level, configured, enabled  → the directive.
 *   - Top-level, no usable config     → a one-line setup nudge.
 *   - Top-level, config with enabled:false → silence (the user opted out;
 *     nudging them to configure would be wrong).
 */

import { buildDirective, buildNudge, isSubagent, readHookInput, resolveConfig } from "./lib-config.mjs";

const input = await readHookInput();

if (!isSubagent(input)) {
  const resolved = resolveConfig(input.cwd || process.cwd());
  let context = null;

  if (!resolved.configured) {
    context = buildNudge(resolved);
  } else if (resolved.enabled) {
    context = buildDirective(resolved);
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
}
