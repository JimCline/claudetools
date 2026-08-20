#!/usr/bin/env node
/**
 * task-gopher — UserPromptSubmit reminder.
 *
 * Keeps the delegation behavior alive turn-to-turn with a ONE-LINE reminder
 * (the full spec was injected at SessionStart — repeating it every turn would
 * itself waste the tokens this plugin exists to save). Also means a mid-session
 * `/task-gopher on` takes effect on the very next prompt. MAIN SESSION ONLY:
 * UserPromptSubmit never fires for subagents — they receive the directive via
 * the relay gate in pretooluse-nudge.mjs instead. The reminder's own tier gate
 * means only Sonnet-tier-or-higher agents act on it. Silent when OFF, and
 * silent inside either gopher.
 */

import { SHORT_REMINDER, isEnabled, isGopherAgent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isGopherAgent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: SHORT_REMINDER,
      },
    })
  );
}
