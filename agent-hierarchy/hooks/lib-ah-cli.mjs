/**
 * agent-hierarchy — shared parser for ah CLI invocations under the Bash tool (spec 0048 §2.4.1).
 *
 * One grammar, three consumers: the allow hook (pretooluse-ah-cli.mjs), the disband/dismiss close
 * gate, and the roster skill gate. The grammar IS the security boundary of the allow hook, so
 * `parseAhCommand` is fail-closed by construction: anything it is not certain about returns null,
 * which makes every consumer silent and leaves the user's normal permission flow in place. It
 * never throws and never inspects the filesystem — `scriptUnderRoot` is the only filesystem check
 * and is a separate function so a parse can be reasoned about on its own.
 *
 * Accepted shape (spec 0048 §2.1/§2.2):
 *   node <abs>/hooks/roster.mjs <verb> [args…]
 *   node <abs>/hooks/msg.mjs    <verb> [args…]
 * exactly one simple command — no `;  & | < > ( ) ` $ \ newline` outside single quotes, and no
 * `{ } * ? [ ] ~` in any UNQUOTED token, so no compound command, no redirection, no substitution
 * and no brace/glob/tilde expansion can ride along: what is parsed is what runs. JSON
 * arguments travel single-quoted. A double-quoted argument may not contain `$`, a backtick or a
 * backslash; the metacharacter ban applies to it too, which is stricter than §2.2's token rule
 * and deliberately so — a quoted `;` has no use in the documented forms and the stricter reading
 * only ever costs a permission prompt.
 *
 * Flag parsing mirrors both CLIs' own `parseArgs` (roster.mjs:121-139, msg.mjs:57-75) exactly:
 * `--k v` unless `k` is one of that CLI's bool flags or the next token looks like a flag. The
 * bool sets below are copies of the CLIs' own; tests/test-ah-cli.sh asserts they are equal.
 */

import { dirname, basename, join } from "node:path";
import { realpathSync } from "node:fs";

export const ROSTER_BOOL_FLAGS = new Set([
  "plain",
  "json",
  "plan",
  "commit",
  "partial",
  "manual",
  "next",
  "apply",
  "kill",
  "keep-sessions",
  "spawn",
  "dry-run",
  "new-tab",
  "new-workspace",
  "allow-global",
  "clear",
  "close",
  "confirm",
  "also-config",
  "no-spawn",
  "allow-roster-edit",
]);

export const MSG_BOOL_FLAGS = new Set(["plain", "json", "open", "closed", "all"]);

const SCRIPTS = { "roster.mjs": "roster", "msg.mjs": "msg" };
const META = new Set([";", "&", "|", "<", ">", "(", ")", "`", "$", "\\", "\n", "\r"]);
// The shell expands `{ } * ? [ ] ~` before node ever sees the command, so any of them outside quotes
// makes the text parsed here and the command executed two different things. Checked one CHARACTER at
// a time in the unquoted branch: a token-level check misses a token that mixes quoting, where an
// adjacent empty quote (`--cl{o..o}s''e`) hides the unquoted part from the whole-token test.
const EXPAND = new Set(["{", "}", "*", "?", "[", "]", "~"]);

/**
 * Split a command string into tokens under the grammar above.
 * @returns {null | {text: string, quoted: "none"|"whole"|"mixed"}[]} null if the string is
 * outside the grammar.
 */
function tokenize(command) {
  const tokens = [];
  let cur = null;
  const push = () => {
    if (cur) tokens.push({ text: cur.text, quoted: cur.quotedParts === 0 ? "none" : cur.parts === 1 ? "whole" : "mixed" });
    cur = null;
  };
  const add = (text, quoted) => {
    if (!cur) cur = { text: "", parts: 0, quotedParts: 0 };
    cur.text += text;
    cur.parts += 1;
    if (quoted) cur.quotedParts += 1;
  };
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === " " || c === "\t") {
      push();
      continue;
    }
    if (c === "'") {
      const end = command.indexOf("'", i + 1);
      if (end === -1) return null;
      const body = command.slice(i + 1, end);
      if (body.includes("\n") || body.includes("\r")) return null;
      add(body, true);
      i = end;
      continue;
    }
    if (c === '"') {
      const end = command.indexOf('"', i + 1);
      if (end === -1) return null;
      const body = command.slice(i + 1, end);
      for (const ch of body) if (META.has(ch)) return null;
      add(body, true);
      i = end;
      continue;
    }
    if (META.has(c) || EXPAND.has(c)) return null;
    add(c, false);
  }
  push();
  return tokens;
}

/**
 * @param {string} command the Bash tool's `command` input.
 * @returns {null | {script: "roster"|"msg", scriptPath: string, verb: string|null, positional: string[], flags: Record<string, string|true>}}
 */
export function parseAhCommand(command) {
  if (typeof command !== "string" || !command.trim()) return null;
  const tokens = tokenize(command);
  if (!tokens || tokens.length < 2) return null;
  if (tokens[0].quoted !== "none" || tokens[0].text !== "node") return null;

  const scriptTok = tokens[1];
  if (scriptTok.quoted === "mixed") return null;
  const scriptPath = scriptTok.text;
  if (!scriptPath.startsWith("/")) return null;
  const script = SCRIPTS[basename(scriptPath)];
  if (!script) return null;
  if (basename(dirname(scriptPath)) !== "hooks") return null;

  const bools = script === "roster" ? ROSTER_BOOL_FLAGS : MSG_BOOL_FLAGS;
  const argv = tokens.slice(2).map((t) => t.text);
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (!bools.has(key) && next !== undefined && !next.startsWith("--")) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    } else {
      positional.push(a);
    }
  }
  const verb = positional.length ? positional[0] : null;
  return { script, scriptPath, verb, positional: positional.slice(1), flags };
}

/**
 * The path rule (spec 0048 §2.2): the script must really be this plugin's own, under the hook's
 * own installed root OR a sibling directory of it. The sibling arm is 0047's self-replace rule
 * reused: after an in-session version bump the hook runs from the new version dir while the
 * role's context still names the previous one, and both live under the same plugin-cache parent.
 * With a local-checkout marketplace the siblings are other plugin dirs, so only a sibling that
 * itself ships `hooks/roster.mjs` could match — accepted.
 */
export function scriptUnderRoot(scriptPath, ownRoot) {
  if (typeof scriptPath !== "string" || typeof ownRoot !== "string") return false;
  let real, root;
  try {
    real = realpathSync(scriptPath);
    root = realpathSync(ownRoot);
  } catch {
    return false;
  }
  const name = basename(real);
  if (!SCRIPTS[name]) return false;
  const realRoot = dirname(dirname(real));
  if (join(realRoot, "hooks", name) !== real) return false;
  return realRoot === root || dirname(realRoot) === dirname(root);
}

/**
 * Spec 0048 §2.4.2: the two destructive forms. `--close` presence is the mode, so a plan call is
 * not one of these. Single definition for both consumers — the allow hook must stay silent on
 * exactly the set the close gate asks about; tests/check-gate-name-agreement.mjs asserts the list.
 */
export const CLOSE_VERBS = ["dismiss", "disband"];

export function isCloseCommand(parsed) {
  return !!parsed && parsed.script === "roster" && CLOSE_VERBS.includes(parsed.verb) && parsed.flags.close === true;
}
