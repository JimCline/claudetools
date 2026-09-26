#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate on raw `herdr agent` Bash calls.
 *
 * `herdr agent start <name>`: Herdr refuses a name outside [a-z][a-z0-9_-]{0,31} only when
 * `agent start` runs, and by then the caller has already split the pane it names — so a bad name
 * strands an empty pane, and the usual next move is to split another one. Denying the command
 * before it runs keeps the split pane usable: the deny says to reuse it with a valid name rather
 * than split a new one.
 *
 * Every Herdr CLI verb that writes input into a pane (`agent prompt|send-keys|attach`,
 * `pane send-text|send-keys|run`, `terminal attach|session control`), aimed at a non-Claude
 * hierarchy member by name or by its pane's id: denied. Such a member is briefed only through
 * `roster.mjs deliver`, which checks its screen first, and its prompts are answered only through
 * `roster.mjs answer`, with the user's choice. So every key that reaches it is a relay, never a
 * stray one. Reads (`get`, `read`, `wait`) stay allowed, and Claude members are untouched. No
 * config is read unless the command makes one of those calls.
 *
 * Fail-open: any error lets the call through, since Herdr still refuses a bad name itself.
 */

import { logHookError, readHookInput, registryRoles, resolveConfig, validateHerdrName, KIND_DEFAULT } from "./lib-config.mjs";
import { gateTarget, herdrCalls, herdrInputCalls } from "./lib-gate-target.mjs";
import { NO_SESSION_KEY, normalizeSessionId } from "./lib-gate.mjs";

function deny(reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } }));
  process.exit(0);
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const command = input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : "";
  for (const { name, pane } of herdrCalls(command, "agent", ["start"])) {
    const check = validateHerdrName(name);
    if (check.ok) continue;
    const reuse = pane
      ? ` Pane ${pane} is still empty: re-run \`herdr agent start <valid name> --pane ${pane} …\` in it rather than splitting another, or close it with \`herdr pane close ${pane}\`.`
      : "";
    deny(`ah: herdr agent names must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters); ${JSON.stringify(name)} is ${name.length} characters.${reuse}`);
  }
  const raw = herdrInputCalls(command);
  if (raw.length) {
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const sessionId = normalizeSessionId(input.session_id);
    const resolved = resolveConfig(cwd, { sessionId: sessionId !== NO_SESSION_KEY ? sessionId : undefined });
    if (resolved.enabled) {
      const roles = registryRoles(resolved);
      for (const call of raw) {
        const target = gateTarget(call.name, { resolved, cwd, roles });
        if (!target || target.kind === KIND_DEFAULT) continue;
        const who = target.member && target.member.name !== call.name ? `${call.name} (${target.member.name})` : call.name;
        deny(`ah: \`herdr ${call.group} ${call.verb} ${call.name}\` is denied — ${who} is a ${target.kind} member of the hierarchy: brief it with \`roster.mjs deliver\`; answer its prompt with \`roster.mjs answer\` after asking the user.`);
      }
    }
  }
} catch (err) {
  logHookError("pretooluse-herdr-name-gate.mjs", err);
}
process.exit(0);
