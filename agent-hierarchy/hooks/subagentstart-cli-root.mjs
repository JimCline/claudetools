#!/usr/bin/env node
/**
 * agent-hierarchy — SubagentStart: give a subagent the absolute CLI root.
 *
 * SessionStart and UserPromptSubmit do not fire inside an Agent-tool subagent, so without this a
 * subagent's only route to the CLIs is a `${CLAUDE_PLUGIN_ROOT}` placeholder in its own agent file,
 * and a subagent that finds that placeholder unexpanded has nothing left but to guess a path.
 *
 * One line for every subagent: the SubagentStart channel is shared with every other plugin. The
 * exception is a subagent whose `agent_type` resolves to a custom or overridden chain role — it
 * also gets the hierarchy contract (its agent file need not carry the protocol) — and a design
 * role, which gets the routing block when Implement/Review alternatives exist. This hook reads the
 * plugin's contract files and the config, never an agent file.
 * SubagentStart accepts additionalContext ONLY inside the hookSpecificOutput envelope — bare stdout
 * is discarded (Engram: subagent context-injection channels).
 */

import { cliRootLine, contractBlock, designRoutingBlock, hierarchyRoleOf, isBuiltinRole, isOverride, logHookError, readHookInput, resolveConfig, roleAgent, roleClass } from "./lib-config.mjs";

try {
  const input = await readHookInput();
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd);
  if (!resolved.configured || resolved.enabled) {
    const blocks = [cliRootLine()];
    const role = hierarchyRoleOf(input.agent_type, { resolved });
    if (role) {
      const entry = resolved.roles[role];
      // Only a session running the custom or override agent itself; an ah:* subagent is the
      // shipped agent and is never injected.
      if (!input.agent_type.startsWith("ah:") && input.agent_type === roleAgent(role, entry) && (!isBuiltinRole(role) || isOverride(role, entry))) {
        const contract = contractBlock(role, resolved);
        if (contract) blocks.push(contract);
      }
      if (roleClass(role, resolved) === "design") {
        const routing = designRoutingBlock(resolved);
        if (routing) blocks.push(routing);
      }
    }
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "SubagentStart",
          additionalContext: blocks.join("\n\n"),
        },
      })
    );
  }
} catch (err) {
  logHookError("subagentstart-cli-root.mjs", err);
}
process.exit(0);
