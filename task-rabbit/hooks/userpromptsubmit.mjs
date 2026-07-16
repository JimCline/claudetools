#!/usr/bin/env node
/**
 * task-rabbit — UserPromptSubmit reminder.
 *
 * Keeps the delegation behavior alive turn-to-turn with a ONE-LINE reminder
 * (the full spec was injected at SessionStart — repeating it every turn would
 * itself waste the tokens this plugin exists to save). Also means a mid-session
 * `/task-rabbit on` takes effect on the very next prompt. Silent when OFF.
 */

import { SHORT_REMINDER, isEnabled } from "./directive.mjs";

if (isEnabled()) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: SHORT_REMINDER,
      },
    })
  );
}
