#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate for `mcp__ah__roster_disband_close` (spec 0016 §4.5.1).
 *
 * Matches ONLY this one MCP tool name, never a wildcard — prompting on every roster tool
 * would train users to blanket-allow the whole server, destroying the one gate that matters
 * here. Always asks: no caching, no allowlist, no "don't ask again" — closing live sessions is
 * exactly the operation that should re-prompt every time.
 *
 * Enriches the prompt with the live member list via `readTeam` when it can; if that read fails
 * for any reason, it still asks, with a generic message — never skips the prompt because
 * enrichment failed. Deliberately trivial: no herdr calls, no network, no topology queries,
 * nothing beyond `readTeam` and a formatted string, so there is nothing here that can throw
 * past the enrichment's own try/catch.
 */

import { readHookInput } from "./lib-config.mjs";
import { hierarchyDir } from "./lib-hier.mjs";
import { readTeam } from "./lib-roster.mjs";

function ask(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "mcp__ah__roster_disband_close") process.exit(0);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  let names = null;
  try {
    const cwd = typeof toolInput.cwd === "string" && toolInput.cwd ? toolInput.cwd : null;
    if (cwd) {
      const team = readTeam(hierarchyDir(cwd), typeof toolInput.team === "string" ? toolInput.team : null);
      if (team && Array.isArray(team.members)) names = team.members.map((m) => m.name).filter(Boolean).join(", ") || null;
    }
  } catch {
    names = null;
  }
  ask(
    names
      ? `ah: close the live session(s) of team member(s) ${names}? This is destructive and cannot be undone from here.`
      : "ah: close the live sessions of this Team? This is destructive and cannot be undone from here."
  );
} catch {
  // This hook's matcher (hooks.json) fires it only for mcp__ah__roster_disband_close, so a
  // parse failure here still means that tool is being called — fail closed with the generic
  // prompt rather than letting the destructive call through unprompted (spec §4.5.1).
  ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
}
