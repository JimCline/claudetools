#!/usr/bin/env node
/**
 * task-gopher — SessionStart context injection.
 *
 * Injects the full delegation directive when the plugin is ON, so a fresh,
 * resumed, or post-compaction session starts already knowing to dispatch
 * tool-heavy work to task-gopher. MAIN SESSION ONLY: SessionStart never fires
 * for subagents — they receive the directive via the relay gate in
 * pretooluse-nudge.mjs instead. The directive's own tier gate means only
 * Sonnet-tier-or-higher agents act on it. Silent when OFF, and silent inside
 * either gopher.
 */

import { FULL_DIRECTIVE, isEnabled, isGopherAgent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isGopherAgent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: FULL_DIRECTIVE,
      },
    })
  );
}
