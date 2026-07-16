#!/usr/bin/env node
/**
 * task-gopher — SessionStart context injection.
 *
 * Injects the full delegation directive when the plugin is ON, so a fresh,
 * resumed, or post-compaction session starts already knowing to dispatch
 * tool-heavy work to the task-gopher subagent. Silent when OFF, and silent
 * inside a subagent (only the top-level orchestrator may delegate).
 */

import { FULL_DIRECTIVE, isEnabled, isSubagent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isSubagent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: FULL_DIRECTIVE,
      },
    })
  );
}
