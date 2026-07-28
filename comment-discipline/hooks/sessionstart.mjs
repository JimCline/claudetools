#!/usr/bin/env node
/**
 * comment-discipline — SessionStart context injection.
 *
 * Injects the authoring directive on startup, resume, clear, fork, and
 * post-compaction, so the rule survives the compaction that would otherwise
 * quietly drop it mid-session.
 *
 * Unlike task-gopher and agent-hierarchy, this hook does NOT gate on subagents.
 * Those two suppress inside subagents to stop dispatch recursion; there is no
 * recursion here, and subagents write plenty of code — an Implementor or a
 * general-purpose agent is exactly who leaves `// NEW: added validation`
 * behind. Suppressing there would gut the plugin.
 *
 * Three states:
 *   - unconfigured           → one-line setup nudge
 *   - configured + enabled   → the directive
 *   - configured + disabled  → silence (the user opted out; nudging them to
 *     configure something they deliberately turned off would be wrong)
 */

import { DIRECTIVE, NUDGE, readHookInput, resolveConfig } from "./lib-config.mjs";

const input = await readHookInput();
const resolved = resolveConfig(input.cwd || process.cwd());

let context = null;
if (!resolved.configured) {
  context = NUDGE;
} else if (resolved.enabled) {
  context = DIRECTIVE;
}

if (context) {
  const lines = [context, ...resolved.warnings];
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: lines.join("\n"),
      },
    })
  );
}
