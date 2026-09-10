#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate for `roster.mjs disband --close` (spec 0016 §4.5.1) and
 * `roster.mjs dismiss <name> --close` (spec 0020 §4.1) — whole-team close and single-member close,
 * the only two operations that execute `herdr pane close`/`tmux kill-pane`.
 *
 * Keyed on the PARSED Bash command (spec 0048 §2.4.2), not on a tool name: the ah CLIs are
 * invoked through the Bash tool now. `--close` presence is the mode — a plan call (no `--close`)
 * destroys nothing and is not gated. The matcher in hooks.json is `Bash`, so this hook sees every
 * Bash call and decides for itself; the gated verb set lives here alone, and
 * tests/check-gate-name-agreement.mjs asserts it against hooks.json's matcher.
 * Always asks: no caching, no allowlist, no "don't ask again" — closing live sessions is exactly
 * the operation that should re-prompt every time. pretooluse-ah-cli.mjs deliberately stays silent
 * on close commands so this `ask` is the only decision in play.
 *
 * Enriches the prompt with the live member list via `readTeam` when it can; if that read fails
 * for any reason, it still asks, with a generic message — never skips the prompt because
 * enrichment failed.
 */

import { readHookInput } from "./lib-config.mjs";
import { hierarchyDir } from "./lib-hier.mjs";
import { readTeam } from "./lib-roster.mjs";
import { isCloseCommand, parseAhCommand } from "./lib-ah-cli.mjs";

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

let recognised = false;
try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  if (!isCloseCommand(parsed)) process.exit(0);
  recognised = true;

  const singleMemberName = parsed.verb === "dismiss" && typeof parsed.positional[0] === "string" ? parsed.positional[0] : null;
  let names = singleMemberName;
  if (!names) {
    try {
      const cwd = typeof parsed.flags.cwd === "string" && parsed.flags.cwd ? parsed.flags.cwd : null;
      if (cwd) {
        const team = readTeam(hierarchyDir(cwd), typeof parsed.flags.team === "string" ? parsed.flags.team : null);
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
  // Once the command is known to be a close command, any later throw still fails closed with the
  // generic prompt rather than letting a destructive call through unprompted (0016 §4.5.1,
  // 0020 §4.1). Before that point the hook cannot know the call is ah's at all — the matcher is
  // now every Bash call — so it stays out of the way.
  if (recognised) ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
  process.exit(0);
}
