#!/usr/bin/env node
/**
 * task-gopher — UserPromptSubmit reminder.
 *
 * Keeps the delegation behavior alive turn-to-turn with a ONE-LINE reminder
 * (the full spec was injected at SessionStart — repeating it every turn would
 * itself waste the tokens this plugin exists to save). Also means a mid-session
 * `/task-gopher on` takes effect on the very next prompt. Silent when OFF, and
 * silent inside a subagent (only the top-level orchestrator may delegate).
 */

import { SHORT_REMINDER, isEnabled, isSubagent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isSubagent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: SHORT_REMINDER,
      },
    })
  );
}
