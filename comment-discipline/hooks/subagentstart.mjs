#!/usr/bin/env node
/**
 * comment-discipline — at-spawn injection into subagents.
 *
 * SessionStart never fires for a subagent, so without this a subagent starts
 * blind to the authoring rule. SubagentStart fires at spawn and its
 * `additionalContext` lands in the SUBAGENT's own context, which makes it the
 * earliest possible delivery — before the subagent's first turn, not after its
 * first edit.
 *
 * THE JSON ENVELOPE IS MANDATORY. Writing the same text to stdout as plain text
 * delivers NOTHING here, with no error and no log line. That is the opposite of
 * SessionStart, where bare stdout IS injected, so the habit transfers and fails
 * silently. The docs imply the rule by exclusion: stdout is added to context for
 * UserPromptSubmit, UserPromptExpansion, and SessionStart — a closed list that
 * does not include this event. See docs/subagent-directive-relay.md.
 *
 * Why this instead of rewriting the dispatch prompt (a PreToolUse hook on
 * `Agent`): that tool's input is already owned by task-gopher's relay, and two
 * plugins rewriting one tool's input is undefined behavior. SubagentStart has no
 * such contention — additionalContext from multiple hooks on one event is
 * documented to aggregate. It also costs the dispatching agent nothing, and it
 * fires for EVERY spawn rather than only those a parent requested by tool call.
 *
 * The tradeoff: the payload carries no dispatch prompt (keys are agent_id,
 * agent_type, cwd, prompt_id, session_id, transcript_path), so this hook cannot
 * see what the subagent was asked to do and cannot vary its text by task. Fine
 * here — the authoring rule is the same every time.
 *
 * Marks the agent in SEEN_FILE so posttooluse-inject.mjs stays quiet for
 * subagents this hook already reached. That backstop now covers only the spawns
 * this event misses.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DIRECTIVE, NON_AUTHORING_AGENTS, SEEN_FILE, readHookInput, resolveConfig } from "./lib-config.mjs";

const quit = () => process.exit(0);

try {
  const input = await readHookInput();

  // The matcher runs against agent type as an unanchored regex, so gate here
  // too rather than trusting hooks.json to have selected correctly.
  const agentType = typeof input.agent_type === "string" ? input.agent_type : "";
  if (NON_AUTHORING_AGENTS.has(agentType)) quit();

  const resolved = resolveConfig(input.cwd || process.cwd());
  if (!resolved.configured || !resolved.enabled) quit();

  const agentId = typeof input.agent_id === "string" ? input.agent_id : "";
  const sessionId = typeof input.session_id === "string" ? input.session_id : "";

  // Mark BEFORE injecting so the backstop skips this agent. Failure to persist
  // is not fatal: the worst case is the backstop injecting again on the first
  // edit, which is the pre-0.3.0 behavior and merely wasteful.
  if (agentId) {
    try {
      mkdirSync(dirname(SEEN_FILE), { recursive: true });
      appendFileSync(SEEN_FILE, sessionId + "|" + agentId + "\n");
    } catch {
      // best-effort
    }
  }

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: DIRECTIVE,
      },
    })
  );
} catch {
  quit(); // never break a spawn
}
