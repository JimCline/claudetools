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

import { logHookError, readHookInput } from "./lib-config.mjs";
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

/**
 * The parser reads only a command that begins `node <abs>/roster.mjs`. A `cd … &&` or env prefix,
 * a relative script path, a `;` chain, `sh -c "…"`, a backslash continuation, a runtime option
 * (`node --no-warnings`) or another runtime (`bun`, `tsx`, `deno run -A`) is a shape it cannot read,
 * and the close would then run unasked. Such a command is a close when a runtime word is followed
 * by a `roster.mjs` word — past any number of `-` options and at most two other words (`run`, an
 * option's value) — and, after it, a `dismiss`/`disband` word and a `--close` word. Requiring a runtime word keeps a mention that has none (`git commit -m
 * "roster.mjs dismiss --close"`) silent; one that spells out `node roster.mjs …` asks, which
 * fails safe — so test shapes belong in the test file and reach the hook through stdin, never in a
 * Bash command, where a grep pattern or heredoc mentioning one asks by design. Every command that does not mention both strings costs two substring tests and
 * reads no config.
 */
function unparsedClose(command) {
  if (typeof command !== "string" || !command.includes("roster.mjs") || !command.includes("--close")) return false;
  const words = command.replace(/\\\n/g, " ").split(/[\s;&|()<>`]+/).filter(Boolean);
  let at = -1;
  for (let i = 0; i < words.length && at < 0; i++) {
    if (!/^["']?(.*\/)?(node|nodejs|bun|deno|tsx)$/.test(words[i])) continue;
    for (let j = i + 1, other = 0; j < words.length; j++) {
      if (/(^|\/)roster\.mjs["']?$/.test(words[j])) { at = j; break; }
      if (!words[j].startsWith("-") && ++other > 2) break;
    }
  }
  if (at < 0) return false;
  const rest = words.slice(at + 1).map((w) => w.replace(/^["']+|["']+$/g, ""));
  return rest.some((w) => w === "dismiss" || w === "disband") && rest.includes("--close");
}

let recognised = false;
try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  if (!parsed && unparsedClose(toolInput.command)) {
    recognised = true;
    ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
  }
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
} catch (err) {
  logHookError("pretooluse-disband-close-gate.mjs", err);
  // Once the command is known to be a close command, any later throw still fails closed with the
  // generic prompt rather than letting a destructive call through unprompted (0016 §4.5.1,
  // 0020 §4.1). Before that point the hook cannot know the call is ah's at all — the matcher is
  // now every Bash call — so it stays out of the way.
  if (recognised) ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
  process.exit(0);
}
