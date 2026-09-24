#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate on raw `herdr agent start <name>` Bash calls.
 *
 * Herdr refuses a name outside [a-z][a-z0-9_-]{0,31} only when `agent start` runs, and by then
 * the caller has already split the pane it names — so a bad name strands an empty pane, and the
 * usual next move is to split another one. Denying the command before it runs keeps the split
 * pane usable: the deny says to reuse it with a valid name rather than split a new one.
 *
 * Fail-open: any error lets the call through, since Herdr still refuses the name itself.
 */

import { logHookError, readHookInput, validateHerdrName } from "./lib-config.mjs";

/** The NAME and `--pane` of every `herdr agent start` in a shell command string. */
function herdrStarts(command) {
  const starts = [];
  for (const m of String(command).matchAll(/\bherdr\s+agent\s+start\b([^;&|\n]*)/g)) {
    const tokens = m[1].trim().split(/\s+/).filter(Boolean).map((t) => t.replace(/^(['"])(.*)\1$/, "$2"));
    let name = null;
    let pane = null;
    for (let i = 0; i < tokens.length; i++) {
      const t = tokens[i];
      if (t === "--") break;
      if (t.startsWith("--")) {
        const [flag, inline] = t.split("=", 2);
        const value = inline !== undefined ? inline : tokens[++i];
        if (flag === "--pane") pane = value || null;
        continue;
      }
      if (name === null) name = t;
    }
    if (name !== null) starts.push({ name, pane });
  }
  return starts;
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const command = input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : "";
  for (const { name, pane } of herdrStarts(command)) {
    const check = validateHerdrName(name);
    if (check.ok) continue;
    const reuse = pane
      ? ` Pane ${pane} is still empty: re-run \`herdr agent start <valid name> --pane ${pane} …\` in it rather than splitting another, or close it with \`herdr pane close ${pane}\`.`
      : "";
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: `ah: herdr agent names must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters); ${JSON.stringify(name)} is ${name.length} characters.${reuse}`,
        },
      })
    );
    process.exit(0);
  }
} catch (err) {
  logHookError("pretooluse-herdr-name-gate.mjs", err);
}
process.exit(0);
