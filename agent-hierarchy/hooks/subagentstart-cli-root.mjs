#!/usr/bin/env node
/**
 * agent-hierarchy — SubagentStart: give a subagent the absolute CLI root.
 *
 * SessionStart and UserPromptSubmit do not fire inside an Agent-tool subagent, so without this a
 * subagent's only route to the CLIs is a `${CLAUDE_PLUGIN_ROOT}` placeholder in its own agent file,
 * and a subagent that finds that placeholder unexpanded has nothing left but to guess a path.
 *
 * One line, and only that line: the SubagentStart channel is shared with every other plugin.
 * SubagentStart accepts additionalContext ONLY inside the hookSpecificOutput envelope — bare stdout
 * is discarded (Engram: subagent context-injection channels).
 */

import { cliRootLine, logHookError, readHookInput, resolveConfig } from "./lib-config.mjs";

try {
  const input = await readHookInput();
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd);
  if (!resolved.configured || resolved.enabled) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "SubagentStart",
          additionalContext: cliRootLine(),
        },
      })
    );
  }
} catch (err) {
  logHookError("subagentstart-cli-root.mjs", err);
}
process.exit(0);
