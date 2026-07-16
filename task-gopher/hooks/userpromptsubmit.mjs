#!/usr/bin/env node
/**
 * task-gopher — UserPromptSubmit reminder.
 *
 * Keeps the delegation behavior alive turn-to-turn with a ONE-LINE reminder
 * (the full spec was injected at SessionStart — repeating it every turn would
 * itself waste the tokens this plugin exists to save). Also means a mid-session
 * `/task-gopher on` takes effect on the very next prompt. Delivered to any agent;
 * the reminder's own tier gate means only Sonnet-tier-or-higher agents act on it.
 * Silent when OFF, and silent inside task-gopher itself.
 */

import { SHORT_REMINDER, isEnabled, isTaskGopherAgent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isTaskGopherAgent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: SHORT_REMINDER,
      },
    })
  );
}
