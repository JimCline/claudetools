#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate for `mcp__ah__roster_disband_close` (spec 0016 §4.5.1) and
 * `mcp__ah__roster_dismiss_close` (spec 0020 §4.1) — whole-team close and single-member close,
 * the only two MCP tools that execute `herdr pane close`/`tmux kill-pane`.
 *
 * Matches ONLY these two exact MCP tool names, never a wildcard/prefix/suffix rule — prompting
 * on every roster tool would train users to blanket-allow the whole server, destroying the one
 * gate that matters here. The exact-name match lives in TWO places, both load-bearing: this set
 * below, AND the hooks.json PreToolUse matcher that decides whether this hook runs at all. A
 * tool absent from the matcher never reaches this body; a tool absent from this body exits(0)
 * with no gate. Registering a new close tool in only one of the two ships it ungated (0020 §4.1).
 * Always asks: no caching, no allowlist, no "don't ask again" — closing live sessions is exactly
 * the operation that should re-prompt every time.
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

const GATED_TOOLS = new Set(["mcp__ah__roster_disband_close", "mcp__ah__roster_dismiss_close"]);

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
  if (!GATED_TOOLS.has(input.tool_name)) process.exit(0);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const singleMemberName = input.tool_name === "mcp__ah__roster_dismiss_close" && typeof toolInput.name === "string" ? toolInput.name : null;
  let names = singleMemberName;
  if (!names) {
    try {
      const cwd = typeof toolInput.cwd === "string" && toolInput.cwd ? toolInput.cwd : null;
      if (cwd) {
        const team = readTeam(hierarchyDir(cwd), typeof toolInput.team === "string" ? toolInput.team : null);
        if (team && Array.isArray(team.members)) names = team.members.map((m) => m.name).filter(Boolean).join(", ") || null;
      }
    } catch {
      names = null;
    }
  }
  ask(
    names
      ? `ah: close the live session(s) of team member(s) ${names}? This is destructive and cannot be undone from here.`
      : "ah: close the live sessions of this Team? This is destructive and cannot be undone from here."
  );
} catch {
  // This hook's matcher (hooks.json) fires it only for the tools in GATED_TOOLS, so a parse
  // failure here still means one of them is being called — fail closed with the generic prompt
  // rather than letting the destructive call through unprompted (spec 0016 §4.5.1, 0020 §4.1).
  ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
}
