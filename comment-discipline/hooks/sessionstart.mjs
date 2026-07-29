#!/usr/bin/env node
/**
 * comment-discipline — SessionStart context injection.
 *
 * Injects the authoring directive on startup, resume, clear, fork, and
 * post-compaction, so the rule survives the compaction that would otherwise
 * quietly drop it mid-session.
 *
 * MAIN SESSION ONLY — not a choice, a platform fact: SessionStart never fires
 * for subagents (a subagent is not a session). This hook therefore needs no
 * subagent gate: it simply never runs in one. That matters here more than for
 * the sibling plugins, because subagents write plenty of code — an Implementor
 * or a general-purpose agent is exactly who leaves `// NEW: added validation`
 * behind — so the directive reaches them two other ways: it asks the
 * dispatching agent to relay it into code-writing dispatch prompts, and
 * posttooluse-inject.mjs injects it on a subagent's first edit (always — it
 * cannot tell whether the relay happened). See docs/subagent-directive-relay.md.
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
