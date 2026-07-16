#!/usr/bin/env node
/**
 * task-gopher — SessionStart context injection.
 *
 * Injects the full delegation directive when the plugin is ON, so a fresh,
 * resumed, or post-compaction session starts already knowing to dispatch
 * tool-heavy work to task-gopher. Delivered to any agent (top-level or
 * subagent); the directive's own tier gate means only Sonnet-tier-or-higher
 * agents act on it. Silent when OFF, and silent inside task-gopher itself (it
 * must never dispatch to task-gopher).
 */

import { FULL_DIRECTIVE, isEnabled, isTaskGopherAgent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isTaskGopherAgent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: FULL_DIRECTIVE,
      },
    })
  );
}
