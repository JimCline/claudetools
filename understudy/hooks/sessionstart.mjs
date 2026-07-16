#!/usr/bin/env node
/**
 * understudy — SessionStart context injection.
 *
 * Injects the full delegation directive when the plugin is ON, so a fresh,
 * resumed, or post-compaction session starts already knowing to defer
 * tool-heavy work to the understudy subagent. Silent when OFF.
 */

import { FULL_DIRECTIVE, isEnabled } from "./directive.mjs";

if (isEnabled()) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: FULL_DIRECTIVE,
      },
    })
  );
}
