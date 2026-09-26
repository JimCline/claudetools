#!/usr/bin/env node
/**
 * agent-hierarchy — roster-member schema/validation and the per-team
 * check-in registry (`team.json`). See spec `docs/specs/0001-agent-roster.md`
 * §3.2 (roster schema) and §5 / ADR 0002 (check-in registry).
 *
 * Deliberately has NO static dependency on lib-hier.mjs — lib-hier.mjs
 * imports FROM here (roleForPeerName/buildStateBlock consult the team
 * registry), so a back-import would form a cycle. Callers that also need
 * lib-hier.mjs helpers (hierarchyDir, newId, localIso, ...) are leaf scripts
 * (roster.mjs, sessionstart.mjs, pretooluse-route-gate.mjs) that import both
 * directly. (pidAlive/ageSecOf/newId/localIso are duplicated below for
 * teamIsLive/team-history — see the ponytail note at their definitions.)
 */

import { accessSync, constants, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { basename, delimiter, dirname, isAbsolute, join, resolve } from "node:path";

import { homedir } from "node:os";

import { checkoutRoot, CLASSES, declaredTier, isValidTeamAlias, KIND_DEFAULT, KIND_RE, registryRoles, resolveKind, roleClass, routeHasPane, suggestTeamAlias } from "./lib-config.mjs";

// Spec 0043 §1.1/§1.5: `kind`/`route`-shape helpers are DEFINED in lib-config.mjs (the leaf) and
// re-exported here so the member schema still reads as one module. Defining them here instead
// would need lib-config.mjs to import from this file, closing the cycle described at :22-26.
export { KIND_DEFAULT, KIND_RE, resolveKind, routeHasPane };

// ponytail: pidAlive/ageSecOf/newId/localIso duplicated from lib-hier.mjs rather than imported —
// lib-hier.mjs imports readTeam/resolveMemberTeam/teamMemberByName from here, and a back-import
// closes a real cycle (lib-config → lib-roster → lib-hier → lib-config) that broke lib-hier.mjs's
// top-level `MSG_ROLES = [...ROLES]` with a TDZ ReferenceError. Upgrade path: hoist these four to
// a leaf module both files import, if lib-hier.mjs ever needs its own copy to drift from this one.
const pad = (n, w = 2) => String(n).padStart(w, "0");

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === "EPERM";
  }
}

function ageSecOf(ts, now = Date.now()) {
  const t = Date.parse(ts);
  return Number.isFinite(t) ? Math.max(0, (now - t) / 1000) : Infinity;
}

function newId(now = new Date()) {
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  let rand = "";
  while (rand.length < 4) rand += randomBytes(4).readUInt32BE(0).toString(36);
  return `${stamp}-${rand.slice(0, 4)}`;
}

function localIso(now = new Date()) {
  const off = -now.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  const abs = Math.abs(off);
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

/**
 * A roster member's route — how the Orchestrator REACHES this member:
 * "peer" (SendMessage to a live Claude session), "subagent" (spawned
 * in-process by the Agent tool), or "pane" (spec 0043 §1.5 — driven through
 * Herdr's agent-control surface, not SendMessage-addressable at all).
 *
 * `transport` remains a separate axis — how the process was PLACED.
 */
export const ROSTER_ROUTE_VALUES = ["peer", "subagent", "pane"];

/** Team-wide herdr pane layout: "auto" (default), "columns", or "grid". See spec 0004 §4. */
export const ROSTER_LAYOUT_VALUES = ["auto", "columns", "grid"];

/** `claude --effort <level>` values (verified via `claude --help`, NEEDS-EVIDENCE #1). */
export const EFFORT_VALUES = ["low", "medium", "high", "xhigh", "max"];

/**
 * `claude --permission-mode <mode>` values (verified via `claude --help`, NEEDS-EVIDENCE #2).
 * Listed most-recommended first: `auto` is the hands-off mode to reach for. `bypassPermissions`
 * is accepted only so legacy configs keep working — it is never recommended or offered.
 */
export const AUTO_MODE_VALUES = ["auto", "acceptEdits", "plan", "dontAsk", "manual", "bypassPermissions"];

/** What the route gate does when this member has no live instance. Only "auto" — the spawn command —
    exists, since a chain role never runs as a subagent. */
export const ON_MISSING_VALUES = ["auto"];
export const ON_MISSING_DEFAULT = "auto";

/** `team.json` for the default team, or `teams/<team>.json` for a named one (spec 0011 §3). */
export const teamPath = (dir, team = null) => (team ? join(dir, "teams", `${team}.json`) : join(dir, "team.json"));

/** The hierarchy dir a team file path sits in — the inverse of `teamPath` — or null when the path is not shaped like one. */
export const teamFileHome = (p) => (basename(p) === "team.json" ? dirname(p) : basename(dirname(p)) === "teams" ? dirname(dirname(p)) : null);

// ---------------------------------------------------------------- herdr transport presence (spec 0010 §2.4)

/**
 * True when an executable named `herdr` is on PATH. Pure `fs` — never spawns
 * a process, because this runs on every SessionStart including `compact`.
 * No caching: a stale cached "missing" answer is worse than re-checking.
 */
export function herdrOnPath() {
  const pathEnv = process.env.PATH;
  if (typeof pathEnv !== "string" || !pathEnv) return false;
  for (const entry of pathEnv.split(delimiter)) {
    if (!entry) continue;
    try {
      accessSync(join(entry, "herdr"), constants.X_OK);
      return true;
    } catch {
      // not here, or not executable — try the next PATH entry
    }
  }
  return false;
}

// ---------------------------------------------------------------- roster member/block validation

/**
 * A Claude `--permission-mode` value expressed in the target kind's own CLI
 * vocabulary. Codex has no permission-mode flag: it splits the same decision
 * into a sandbox policy (what the agent may touch) and an approval policy
 * (when it stops to ask), so each Claude mode maps to a pair. `plan` is
 * read-only with no prompts because a plan run must not edit and must not
 * block; `bypassPermissions` is the one mode with a single-flag equivalent.
 */
export const KIND_AUTO_MODE_ARGS = {
  codex: {
    manual: ["--sandbox", "read-only", "--ask-for-approval", "on-request"],
    plan: ["--sandbox", "read-only", "--ask-for-approval", "never"],
    acceptEdits: ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"],
    auto: ["--sandbox", "workspace-write", "--ask-for-approval", "never"],
    dontAsk: ["--sandbox", "workspace-write", "--ask-for-approval", "never"],
    bypassPermissions: ["--dangerously-bypass-approvals-and-sandbox"],
  },
};

/**
 * The native flags a non-claude member's `autoMode` becomes, or null when the
 * member has no autoMode or its kind has no mapping. Emitted before the
 * member's own `args` so an explicit native flag overrides the mapping.
 */
export function kindAutoModeArgs(m) {
  if (!m || !m.autoMode) return null;
  const table = KIND_AUTO_MODE_ARGS[resolveKind(m)];
  const args = table && table[m.autoMode];
  return args ? [...args] : null;
}

/** A TOML basic string holding `s`, quotes included. */
function tomlString(s) {
  const escape = (c) => (c === "\\" ? "\\\\" : c === '"' ? '\\"' : `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
  return `"${String(s).replace(/[\\"\u0000-\u001f\u007f]/g, escape)}"`;
}

/** A TOML basic string's body with its escapes decoded, or null for an escape this reader does not know. */
function tomlUnescape(body) {
  const simple = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", '"': '"', "\\": "\\" };
  let out = "";
  for (let i = 0; i < body.length; i++) {
    if (body[i] !== "\\") {
      out += body[i];
      continue;
    }
    const c = body[++i];
    if (c !== undefined && Object.hasOwn(simple, c)) {
      out += simple[c];
      continue;
    }
    const len = c === "u" ? 4 : c === "U" ? 8 : 0;
    const hex = body.slice(i + 1, i + 1 + len);
    if (!len || hex.length !== len || !/^[0-9a-fA-F]+$/.test(hex)) return null;
    const code = parseInt(hex, 16);
    if (code > 0x10ffff) return null;
    out += String.fromCodePoint(code);
    i += len;
  }
  return out;
}

/**
 * The directories Codex's own config records as trusted, read line by line and never written. Only
 * `[projects."<abs path>"]` tables and their `trust_level` are read. Any other way of writing
 * `projects` (a `[projects]` or literal-string header, a dotted key, an inline table), a header or
 * value it cannot decode, or a missing or unreadable file gives null: the answer is unknown.
 */
function codexTrustedProjects(configPath) {
  let text;
  try {
    text = readFileSync(configPath, "utf8");
  } catch {
    return null;
  }
  const trusted = new Set();
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      const header = /^\[projects\."((?:[^"\\]|\\.)*)"\]\s*(?:#.*)?$/.exec(line);
      if (header) {
        current = tomlUnescape(header[1]);
        if (current === null) return null;
        continue;
      }
      if (/^\[\[?\s*["']?projects\b/.test(line)) return null;
      current = null;
      continue;
    }
    if (current === null) {
      if (/^["']?projects["']?\s*[.=]/.test(line)) return null;
      continue;
    }
    const kv = /^trust_level\s*=\s*(.*)$/.exec(line);
    if (!kv) continue;
    const value = /^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/.exec(kv[1]);
    const decoded = value ? tomlUnescape(value[1]) : null;
    if (decoded === null) return null;
    if (decoded === "trusted") trusted.add(current);
  }
  return trusted;
}

/** `p` and every directory above it, nearest first. */
function selfAndAncestors(p) {
  const out = [];
  for (let d = resolve(p); ; d = dirname(d)) {
    out.push(d);
    if (dirname(d) === d) return out;
  }
}

const realOr = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
};

/** Where Codex saves a trust answer given in `cwd`: the checkout's root (a worktree's main checkout), else `cwd`. */
export function codexTrustRoot(cwd) {
  return checkoutRoot(cwd) || resolve(cwd);
}

/**
 * Whether Codex has been told to trust `cwd`, read before a launch: `{verdict, configPath,
 * codexHome, trustRoot}`, verdict "trusted", "untrusted" or "unknown". It reads
 * `$CODEX_HOME/config.toml` when that is set, else `~/.codex/config.toml`. A trusted entry for the
 * cwd, the trust root, or any directory above either counts, each compared as given and resolved.
 * A wrong "trusted" is caught by the screen check after launch, so every doubt resolves that way.
 */
export function codexTrust(cwd, env = process.env) {
  const codexHome = typeof env.CODEX_HOME === "string" && env.CODEX_HOME ? env.CODEX_HOME : join(homedir(), ".codex");
  const configPath = join(codexHome, "config.toml");
  const trustRoot = codexTrustRoot(cwd);
  const info = { configPath, codexHome, trustRoot };
  const trusted = codexTrustedProjects(configPath);
  if (!trusted) return { verdict: "unknown", ...info };
  const entries = new Set([...trusted].flatMap((p) => [p, realOr(p)]));
  const candidates = [cwd, trustRoot].flatMap((p) => [...selfAndAncestors(p), ...selfAndAncestors(realOr(p))]);
  return { verdict: candidates.some((c) => entries.has(c)) ? "trusted" : "untrusted", ...info };
}

/**
 * The model spellings Codex accepts on its command line: `--model`, `-m`, and a `model` config
 * override (`-c model=…`). A member whose `model` is set may not also carry one of these in `args`.
 */
function codexArgsSetModel(args) {
  const configModel = (v) => typeof v === "string" && /^\s*model\s*=/.test(v);
  return args.some((a, i) => {
    if (typeof a !== "string") return false;
    if (a === "--model" || a.startsWith("--model=") || a === "-m" || /^-m[^-]/.test(a)) return true;
    if ((a === "-c" || a === "--config") && configModel(args[i + 1])) return true;
    return (a.startsWith("-c") && a.length > 2 && configModel(a.slice(2))) || (a.startsWith("--config=") && configModel(a.slice("--config=".length)));
  });
}

const TRUST_ROOT_TEXT =
  "Codex saves `trust_level = \"trusted\"` for `<trust root>` in `<config path>`. That is the whole repository, not only `<cwd>`. From then on, every Codex session anywhere under `<trust root>`, yours included, skips this question and loads that repository's own Codex config, hooks and exec policies.";
const TRUST_CWD_TEXT =
  "Codex saves `trust_level = \"trusted\"` for `<cwd>` in `<config path>`. From then on, every Codex session anywhere under `<cwd>`, yours included, skips this question and loads that directory's own Codex config, hooks and exec policies.";

/**
 * What the hierarchy knows about launching and driving a non-Claude harness, per kind: how a
 * member's model, standing-instructions file, extra writable directory and approvals reviewer reach
 * its command line; its idle composer, the one screen a brief may be typed into; the prompts it can
 * stop on, each by the layout Codex draws it in; and, per prompt, the answers that may be relayed.
 *
 * An answer row is offered only while an option of the recognised block reads its `onScreen` label
 * (under its digit key's number, when it has one), and its `keys` pick it explicitly whatever the
 * highlight is. Every row was checked against codex-cli
 * 0.154.0-alpha.6.2 (tag rust-v0.154.0-alpha.6.2): digits cannot be remapped, while Codex's letter
 * hotkeys come from the user's keymap, so no row uses one. `grants` marks an answer that gives
 * something away. Deliberately absent: approval's "Yes, and don't ask again" (it pre-approves the
 * rest of the member's session with no human) and every login method but ChatGPT sign-in; the user
 * can pick those in the pane. Codex's other approval screens (edits, permissions, network access,
 * terminal input, MCP) are not patterns: their option order is decided at run time.
 */
export const KIND_HARNESS = {
  codex: {
    label: "Codex",
    modelArgs: (model) => ["--model", model],
    argsSetModel: codexArgsSetModel,
    modelsCommand: "codex debug models",
    instructionsArgs: (path) => ["-c", `model_instructions_file=${tomlString(path)}`],
    writableDirArgs: (dir) => ["--add-dir", dir],
    approvalsArgs: ["-c", 'approvals_reviewer="user"'],
    approvalsKey: "approvals_reviewer",
    trust: codexTrust,
    // How a member spawns, instructs and waits on a native legwork child, `model` being the child's
    // model or null. Its presence is what gives this kind native delegation. Which tools a Codex
    // session exposes varies by model at run time, not by launch argv, so only the form verified live
    // is named, as an example.
    nativeLegwork: (model) => {
      const m = model ? `, \`model: ${JSON.stringify(model)}\`` : "";
      const modelRule = model ? "If the spawn is refused for that model, spawn once more without `model` and say so in your response." : "Do not set `model`: the child runs on your model.";
      return `The tested form: \`spawn_agent\` with \`task_name\`, \`message\` and \`fork_turns: "none"\`${m}; then \`wait_agent\`; \`followup_task\` with \`target\` sends that child a further order. If your spawn tool's names or fields differ, use their equivalents. Never fork your conversation history into a child: it starts from this file and your order alone. ${modelRule}`;
    },
    // Idle and empty, the bottom band is padding, the prompt row, padding and a one-line footer; the
    // placeholder is drawn only while the input is empty.
    composer: { glyphs: ["›", "»"], placeholders: ["Ask Codex to do anything", "Ask a follow-up question"] },
    // Each prompt as Codex draws it: its footer is the last line on screen, and its option block sits
    // directly above it. `herdr` is the status Herdr reports while it is up. Approval's second label
    // has a free slot for the member's command prefix; its hotkeys come from the user's keymap.
    prompts: {
      approval: {
        heading: "Would you like to run the following command?",
        marker: "›",
        footer: /^\s*Press .+ to confirm or .+ to cancel(?: or .+ to open thread)?$/,
        herdr: "blocked",
        onboarding: false,
        joinLabels: true,
        labels: [/^Yes, proceed \([^()]+\)$/, /^Yes, and don't ask again for commands that start with `.+` \([^()]+\)$/, /^No, and tell Codex what to do differently \([^()]+\)$/],
      },
      "trust-dialog": {
        heading: "Do you trust the contents of this directory",
        marker: "›",
        footer: /^\s*Press enter to continue$/,
        herdr: "idle",
        onboarding: true,
        joinLabels: true,
        labels: ["Yes, continue", "No, quit"],
      },
      login: {
        heading: "Sign in with ChatGPT",
        marker: ">",
        footer: /^\s*Press enter to continue$/,
        herdr: "idle",
        onboarding: true,
        joinLabels: false,
        optionsSpaced: true,
        labels: ["Sign in with ChatGPT", "Sign in with Device Code", "Provide your own API key", "Use Amazon Bedrock"],
      },
    },
    // The headings of Codex's approval screens that are not relayed: on screen, no prompt is named.
    otherHeadings: ["Would you like to make the following edits?", "Would you like to grant these permissions?", "Do you want to approve network access to", "Would you like to send input to", "needs your approval."],
    options: {
      approval: [
        {
          id: "approve",
          label: "Yes, once",
          grants: true,
          keys: ["1"],
          onScreen: /^Yes, proceed \([^()]+\)$/,
          description: "Codex runs the command shown above outside the member's sandbox, this one time. Its next command that needs approval asks again.",
        },
        {
          id: "deny",
          label: "No",
          grants: false,
          keys: ["esc"],
          onScreen: "No, and tell Codex what to do differently (esc)",
          description: "Codex does not run the command, and the member's turn ends. It then waits for its next brief.",
        },
      ],
      "trust-dialog": [
        { id: "trust", label: "Yes, trust", grants: true, keys: ["1", "Enter"], onScreen: "Yes, continue", description: (ctx) => (ctx.trustRoot !== ctx.cwd ? TRUST_ROOT_TEXT : TRUST_CWD_TEXT) },
        {
          id: "distrust",
          label: "No, quit",
          grants: false,
          keys: ["2"],
          onScreen: "No, quit",
          description: "Codex quits and saves nothing. The member doesn't start, and its pane is left at a shell. Nothing is written to `<config path>`, so the next Codex launch in `<cwd>` asks again.",
        },
      ],
      login: [
        {
          id: "sign-in",
          label: "Start ChatGPT sign-in",
          grants: false,
          keys: ["1"],
          onScreen: "Sign in with ChatGPT",
          description: "Codex opens a ChatGPT sign-in in your browser. You finish it there, and the member waits until you do. The sign-in is saved for every Codex session that uses `<CODEX_HOME>`.",
        },
      ],
    },
  },
};

/** A screen read as lines, trailing whitespace cut from each and trailing blank lines dropped. */
function screenLines(screen) {
  const lines = String(screen ?? "").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/**
 * Whether `screen` is the kind's idle, empty composer: its last four lines, once braille cells are
 * blanked, are a blank padding row, the prompt row (a composer glyph at column 0, a space, then a
 * placeholder and only spaces), a blank padding row and a one-line footer of any content. Codex's
 * sparkle animation draws braille only into blank cells of those rows.
 */
export function isComposer(kind, screen) {
  const c = KIND_HARNESS[kind] && KIND_HARNESS[kind].composer;
  if (!c) return false;
  const lines = String(screen ?? "").split("\n");
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  if (lines.length < 4) return false;
  const [padTop, row, padBottom, footer] = lines.slice(-4).map((l) => l.replace(/[\u2800-\u28FF]/g, " "));
  const blank = (l) => l.trim() === "";
  return blank(padTop) && blank(padBottom) && !blank(footer) && c.glyphs.includes(row[0]) && row[1] === " " && c.placeholders.includes(row.slice(2).replace(/ +$/, ""));
}

/** `{n, marked, text}` when `line` starts an option: the marker or a space, a space, then `<n>. `. */
function optionStart(line, marker) {
  const m = /^(.) (\d+)\. (.*)$/u.exec(line);
  return m && (m[1] === marker || m[1] === " ") ? { n: Number(m[2]), marked: m[1] === marker, text: m[3] } : null;
}

/**
 * The option block of prompt `spec` when it is what `lines` end with, as `[{n, marked, label}]`, or
 * null. The footer is the last line; above it, past blank lines, is a block whose first line is
 * option 1 with a blank line directly above it, and a blank line inside it (login only) must be
 * followed by the next option's start. In the block, a line indented 5 or more spaces continues the
 * option above; on an onboarding screen a line starting at column 0 is a terminal soft wrap, which
 * the blank-line rule leaves only straight after another block line. Options are numbered from 1 with no gaps,
 * exactly one carries the marker, and each label is one the prompt draws.
 */
function promptBlock(spec, lines, agentStatus) {
  const herdrAgrees = spec.herdr === "blocked" ? agentStatus === "blocked" : agentStatus !== "blocked" && agentStatus !== "working";
  if (!herdrAgrees || !lines.length || !spec.footer.test(lines[lines.length - 1])) return null;
  let end = lines.length - 2;
  while (end >= 0 && lines[end] === "") end--;
  let top = -1;
  for (let j = end; j >= 0; j--) {
    if (lines[j] !== "") continue;
    const below = optionStart(lines[j + 1], spec.marker);
    if (below && below.n === 1) {
      top = j + 1;
      break;
    }
    // Login leaves a blank line between one method's lines and the next.
    if (!(spec.optionsSpaced && below)) return null;
  }
  if (top < 0) return null;
  const options = [];
  for (let k = top; k <= end; k++) {
    const line = lines[k];
    const start = optionStart(line, spec.marker);
    if (start) options.push({ n: start.n, marked: start.marked, parts: [start.text] });
    else if (line === "") continue;
    else if (/^ {5,}\S/.test(line)) options[options.length - 1].parts.push(line.trim());
    else if (spec.onboarding && /^\S/.test(line)) options[options.length - 1].parts.push(line.trim());
    else return null;
  }
  if (options.some((o, i) => o.n !== i + 1) || options.filter((o) => o.marked).length !== 1) return null;
  const block = options.map((o) => ({ n: o.n, marked: o.marked, label: (spec.joinLabels ? o.parts.join(" ") : o.parts[0]).trim() }));
  const known = (label) => spec.labels.some((l) => (typeof l === "string" ? l === label : l.test(label)));
  if (!block.every((o) => known(o.label))) return null;
  if (!lines.slice(0, top).some((l) => l.includes(spec.heading))) return null;
  return block;
}

/**
 * What a kind's screen shows, given Herdr's status for it: `composer`, true when it is the idle,
 * empty composer (and Herdr says neither working nor blocked); `prompt`, the one prompt whose layout
 * it ends with, when no other known prompt's heading is anywhere on it; and `block`, that prompt's
 * options. Anything else names no prompt. Spawn, `deliver` and `answer` all read screens here.
 */
export function recognizeScreen(kind, screen, agentStatus) {
  const h = KIND_HARNESS[kind];
  const composer = isComposer(kind, screen) && agentStatus !== "working" && agentStatus !== "blocked";
  const none = { composer, prompt: null, block: [] };
  if (!h || !h.prompts) return none;
  const lines = screenLines(screen);
  const matched = Object.entries(h.prompts)
    .map(([name, spec]) => ({ name, block: promptBlock(spec, lines, agentStatus) }))
    .filter((m) => m.block);
  if (matched.length !== 1) return none;
  const [{ name, block }] = matched;
  const text = String(screen ?? "");
  const others = [...Object.entries(h.prompts).filter(([n]) => n !== name).map(([, spec]) => spec.heading), ...(h.otherHeadings || [])];
  if (others.some((heading) => text.includes(heading))) return none;
  return { composer, prompt: name, block };
}

/** Whether a recognised option block offers answer `row`: an option reads its label, under its digit key's number if it has one. */
export function rowOffered(row, block) {
  const digit = row.keys.find((k) => /^\d$/.test(k));
  const reads = (label) => (typeof row.onScreen === "string" ? label === row.onScreen : row.onScreen.test(label));
  return (block || []).some((o) => (digit === undefined || o.n === Number(digit)) && reads(o.label));
}

/** SHA-256 hex of a screen read, with trailing whitespace cut from each line and trailing blank lines dropped. */
export function screenHash(screen) {
  const lines = String(screen ?? "").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return createHash("sha256").update(lines.join("\n")).digest("hex");
}

/** The answer rows a kind's table holds for prompt `blockedBy`, or null when it has none by that name. */
export function promptRows(kind, blockedBy) {
  const h = KIND_HARNESS[kind];
  const rows = h && h.options && Object.hasOwn(h.options, blockedBy) ? h.options[blockedBy] : null;
  return Array.isArray(rows) ? rows : null;
}

/**
 * The answers to offer for `blockedBy` while its option block is `block`: each row the block offers,
 * as `{id, label, description, grants}` with `<cwd>`, `<config path>`, `<CODEX_HOME>` and
 * `<trust root>` filled from `ctx`.
 */
export function promptOptions(kind, blockedBy, block, ctx) {
  return (promptRows(kind, blockedBy) || [])
    .filter((row) => rowOffered(row, block))
    .map((row) => {
      const template = typeof row.description === "function" ? row.description(ctx) : row.description;
      const description = template
        .split("<cwd>").join(ctx.cwd)
        .split("<config path>").join(ctx.configPath)
        .split("<CODEX_HOME>").join(ctx.codexHome)
        .split("<trust root>").join(ctx.trustRoot);
      return { id: row.id, label: row.label, description, grants: row.grants };
    });
}

/**
 * Spec 0043 §1.9: a member's `args` as an actual list, with absent and `[]`
 * treated as the same thing (the spec makes them equivalent, so nothing
 * downstream has to distinguish them).
 */
export function memberArgs(m) {
  const a = m && m.args;
  return Array.isArray(a) && a.length ? a : null;
}

/**
 * Spec 0043 §1.2/§1.3/§1.5/§1.9: everything the `kind` field changes about a
 * member. Shared by `validateMember`, `validateTeamMember` and `spawnShape`'s
 * defensive re-check, so a hand-edited config cannot reach the launch line
 * with a combination `add` would have refused.
 *
 * `model`/`effort`/`auto-mode` are rejected rather than ignored for a
 * non-claude kind: they render as literal `--model`/`--effort`/
 * `--permission-mode` Claude CLI flags (§F3), so silently dropping them would
 * make `show` display a model that affects nothing.
 */
export function kindFieldErrors(m, resolved = null) {
  const errors = [];
  if (!m || typeof m !== "object") return errors;

  if (m.kind !== undefined && m.kind !== null && (typeof m.kind !== "string" || !KIND_RE.test(m.kind))) {
    errors.push(`kind must be a non-empty lowercase string matching ${KIND_RE.source}, got ${JSON.stringify(m.kind)}`);
    return errors; // an unusable kind makes every rule below meaningless
  }
  const kind = resolveKind(m);
  const nonClaude = kind !== KIND_DEFAULT;
  const harness = nonClaude ? KIND_HARNESS[kind] || null : null;

  if (nonClaude) {
    const mapped = KIND_AUTO_MODE_ARGS[kind];
    for (const [key, label] of [["model", "model"], ["effort", "effort"], ["autoMode", "auto-mode"]]) {
      if (m[key] === undefined || m[key] === null) continue;
      // auto-mode survives for a kind with a permission mapping: it is the one Claude flag whose
      // meaning exists in the other CLI's vocabulary, so it is translated rather than refused.
      if (key === "autoMode" && mapped) {
        // A value outside AUTO_MODE_VALUES is already reported by validateMember; saying it twice
        // helps nobody. This fires only for a real gap in a kind's table.
        if (!mapped[m.autoMode] && AUTO_MODE_VALUES.includes(m.autoMode)) errors.push(`auto-mode ${JSON.stringify(m.autoMode)} has no ${kind} equivalent — use one of ${Object.keys(mapped).join(", ")}`);
        continue;
      }
      // A kind with a model mapping takes any model its harness might accept: the harness checks
      // the name at the first turn, and its list can depend on the account, so only the shape is
      // checked here.
      if (key === "model" && harness) {
        if (typeof m.model !== "string" || !/^[^\s\p{Cc}]+$/u.test(m.model)) errors.push(`model must be a non-empty string with no whitespace or control characters, got ${JSON.stringify(m.model)}`);
        continue;
      }
      if (key === "model") {
        errors.push(`model has no mapping for kind ${JSON.stringify(kind)} — pass that harness's own model flag in args instead (got ${JSON.stringify(m.model)})`);
        continue;
      }
      errors.push(`${label} is a Claude Code CLI flag and has no meaning for kind ${JSON.stringify(kind)} — remove it (got ${JSON.stringify(m[key])})`);
    }
    if (m.route !== "pane") {
      errors.push(`route must be "pane" for kind ${JSON.stringify(kind)} (a non-claude agent is reached through its Herdr pane, not SendMessage or the Agent tool), got ${JSON.stringify(m.route)}`);
    }
  }

  if (m.args !== undefined && m.args !== null) {
    if (!Array.isArray(m.args)) {
      errors.push(`args must be an array of strings, got ${JSON.stringify(m.args)}`);
    } else {
      m.args.forEach((a, i) => {
        if (typeof a !== "string" || !a) errors.push(`args[${i}] must be a non-empty string, got ${JSON.stringify(a)}`);
      });
    }
  }
  // §1.9: not merely unnecessary for a claude member — the `--` slot already carries the
  // VALIDATED agentFlags, so args would be a second, unvalidated channel for Claude CLI flags
  // (`args: ["--model","haiku"]` on an ultra-advisor defeats TOP_TIER_MODELS). Every model /
  // effort / permission rule is only as strong as this rejection.
  if (!nonClaude && memberArgs(m)) {
    errors.push(`args is not allowed for kind "claude" — Claude CLI flags are set with --model/--effort/--auto-mode, which are validated; args would bypass that (got ${JSON.stringify(m.args)})`);
  }
  // One channel per setting: the CLI adds the model and approvals flags itself, so the same
  // setting in args would either conflict or silently undo what the CLI set.
  if (harness && memberArgs(m)) {
    if (m.model !== undefined && m.model !== null && harness.argsSetModel(memberArgs(m))) {
      errors.push(`model is set, and args sets the model too — one channel per setting: drop the model flag from args, or drop model (got ${JSON.stringify(m.args)})`);
    }
    if (memberArgs(m).some((a) => typeof a === "string" && a.includes(harness.approvalsKey))) {
      errors.push(`args must not set ${harness.approvalsKey}: every ${kind} member is launched with ${harness.approvalsArgs.join(" ")}, so an escalation waits for a human, and a later setting in args would undo that (got ${JSON.stringify(m.args)})`);
    }
  }
  // An advise-class member's model is locked to the top tier. args could carry a second model flag
  // in a spelling no check here knows, or a prompt that would brief it at launch with no approval.
  if (nonClaude && memberArgs(m) && roleClass(m.role, resolved) === "advise") {
    errors.push(`args is not allowed on a non-claude advise-class member (${m.role}) — it could set a second model past the tier lock, or brief the member at launch without the user's approval (got ${JSON.stringify(m.args)})`);
  }
  // A kind with no model mapping runs its harness's default model, which can never be declared a
  // tier, so it could never meet the advise class's lock.
  if (nonClaude && !harness && roleClass(m.role, resolved) === "advise") errors.push(unmappedAdviseMessage(kind));
  return errors;
}

/** Why an advise-class member cannot be of `kind`, a kind with no model mapping. */
export function unmappedAdviseMessage(kind) {
  return `The Ultra-Advisor's model must have a declared opus or fable tier, and \`${kind}\` has no model mapping, so its model cannot be set or declared. Use claude, or a kind with a model mapping (${Object.keys(KIND_HARNESS).join(", ")}).`;
}

/** The tiers an advise-class member's model must be declared at. */
export const ADVISE_TIERS = ["opus", "fable"];

/**
 * Warnings, not errors, for a non-claude member: a chain member whose auto-mode leaves it a
 * read-only sandbox cannot write its report without an approval answered in its own pane, and
 * (with `tier`) an advise-class member whose model is not declared opus or fable will be refused
 * when it is spawned. Spawn itself passes `tier: false`, because there the tier is a refusal.
 */
export function kindFieldWarnings(m, resolved = null, { tier = true } = {}) {
  const warnings = [];
  if (!m || typeof m !== "object" || resolveKind(m) === KIND_DEFAULT) return warnings;
  const kind = resolveKind(m);
  const cls = roleClass(m.role, resolved);
  const autoArgs = kindAutoModeArgs(m);
  if (cls && CLASSES[cls] && CLASSES[cls].chain && autoArgs && autoArgs.includes("read-only")) {
    warnings.push(`auto-mode ${JSON.stringify(m.autoMode)} runs ${kind} in a read-only sandbox, so this ${m.role} cannot write its report file without an approval answered in its own pane`);
  }
  if (tier && cls === "advise" && KIND_HARNESS[kind] && typeof m.model === "string" && m.model) {
    const declared = declaredTier(kind, m.model);
    if (!ADVISE_TIERS.includes(declared)) {
      warnings.push(
        `${kind} model ${m.model} ${declared ? `is declared ${declared}` : "has no declared tier"}; an advise-class member needs a model declared opus or fable, so spawning it will refuse. Declare it with \`roster.mjs tier set ${kind} ${m.model} <opus|fable>\` if that is how it compares`
      );
    }
  }
  return warnings;
}

/**
 * Validation errors for one roster member object; empty array = valid. `resolved` supplies the
 * registry, so a custom role is accepted and its model is checked against its class allowlist;
 * without it only the built-ins are known.
 */
export function validateMember(m, resolved = null) {
  const errors = [];
  if (!m || typeof m !== "object") return ["member must be an object"];
  const roles = registryRoles(resolved);
  if (!roles.includes(m.role)) errors.push(`role must be one of ${roles.join(", ")}, got ${JSON.stringify(m.role)}`);
  const cls = roleClass(m.role, resolved);
  const validModels = cls ? CLASSES[cls].models : [];
  // The class allowlist names Claude aliases, so it applies to claude members only; a non-claude
  // member's model is checked by kindFieldErrors.
  if (m.model !== undefined && m.model !== null && resolveKind(m) === KIND_DEFAULT && !validModels.includes(m.model)) {
    errors.push(`model ${JSON.stringify(m.model)} is not valid for role ${JSON.stringify(m.role)} (allowed: ${validModels.join(", ")})`);
  }
  if (m.effort !== undefined && m.effort !== null && !EFFORT_VALUES.includes(m.effort)) {
    errors.push(`effort must be one of ${EFFORT_VALUES.join(", ")}, got ${JSON.stringify(m.effort)}`);
  }
  if (m.route !== undefined && m.route !== null && !ROSTER_ROUTE_VALUES.includes(m.route)) {
    errors.push(`route must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(m.route)}`);
  } else if (m.route === "subagent" && cls && cls !== "legwork") {
    errors.push(`route "subagent" is not allowed for role ${JSON.stringify(m.role)} — only legwork roles run as subagents`);
  }
  if (m.autoMode !== undefined && m.autoMode !== null && !AUTO_MODE_VALUES.includes(m.autoMode)) {
    errors.push(`auto-mode must be one of ${AUTO_MODE_VALUES.join(", ")}, got ${JSON.stringify(m.autoMode)}`);
  }
  if (m.onMissing !== undefined && m.onMissing !== null && !ON_MISSING_VALUES.includes(m.onMissing)) {
    const why = m.onMissing === "never" || m.onMissing === "prompt" ? " — only legwork roles run as subagents" : "";
    errors.push(`on-missing must be one of ${ON_MISSING_VALUES.join(", ")}, got ${JSON.stringify(m.onMissing)}${why}`);
  }
  if (m.name !== undefined) errors.push('member must not carry a stored "name" — it is derived at resolve time (spec §3.4)');
  for (const e of kindFieldErrors(m, resolved)) errors.push(e);
  return errors;
}

/**
 * Validation errors for one TEAM member object (`team.json`'s `members[]`, spec 0025 §3); empty
 * array = valid. Deliberately NOT `validateMember` — that one rejects any stored `name`, which is
 * correct for roster-config members (derived at resolve time) but wrong here: the spawn path
 * writes team members WITH a `name` (roster.mjs:768, roster.mjs:1620).
 */
export function validateTeamMember(m, resolved = null) {
  if (!m || typeof m !== "object" || Array.isArray(m)) return [`member must be an object, got ${JSON.stringify(m)}`];
  const errors = [];
  const roles = registryRoles(resolved);
  if (!roles.includes(m.role)) errors.push(`role must be one of ${roles.join(", ")}, got ${JSON.stringify(m.role)}`);
  // Spec 0025 §3 amendment: name addresses a pane, so it's load-bearing only for route "peer" —
  // a subagent-routed member legitimately has no pane and no name (SKILL.md's hand-built recipe).
  // Spec 0043 §1.5: a `pane`-routed member addresses a pane exactly as a `peer` one does — its
  // name is the Herdr agent name — so the name requirement follows the pane, not the literal
  // route "peer".
  if (m.name === "") {
    errors.push(`name must not be an empty string`);
  } else if (routeHasPane(m.route) && (typeof m.name !== "string" || !m.name)) {
    errors.push(`name is required and must be a non-empty string when route is ${JSON.stringify(m.route)}, got ${JSON.stringify(m.name)}`);
  } else if (!routeHasPane(m.route) && m.name !== undefined && m.name !== null && typeof m.name !== "string") {
    errors.push(`name must be a non-empty string or null, got ${JSON.stringify(m.name)}`);
  }
  if (!ROSTER_ROUTE_VALUES.includes(m.route)) errors.push(`route must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(m.route)}`);
  for (const e of kindFieldErrors(m, resolved)) errors.push(e);
  if (m.transport_id !== undefined && m.transport_id !== null && typeof m.transport_id !== "string") {
    errors.push(`transport_id must be a string or null, got ${JSON.stringify(m.transport_id)}`);
  }
  if (m.tab_id !== undefined && m.tab_id !== null && typeof m.tab_id !== "string") {
    errors.push(`tab_id must be a string or null, got ${JSON.stringify(m.tab_id)}`);
  }
  if (m.workspace_id !== undefined && m.workspace_id !== null && typeof m.workspace_id !== "string") {
    errors.push(`workspace_id must be a string or null, got ${JSON.stringify(m.workspace_id)}`);
  }
  return errors;
}

/** Validation errors for a whole `roster` block (`{route, members}`); empty array = valid. */
export function validateRosterBlock(roster, resolved = null) {
  if (!roster || typeof roster !== "object" || Array.isArray(roster)) return ["roster must be an object"];
  const errors = [];
  if (!ROSTER_ROUTE_VALUES.includes(roster.route)) {
    errors.push(`roster.route is required and must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(roster.route)}`);
  }
  if (!Array.isArray(roster.members)) {
    errors.push("roster.members must be an array");
  } else {
    roster.members.forEach((m, i) => {
      if (m && m.role === "orchestrator") {
        errors.push(`member ${i}: role "orchestrator" is not a roster member — the Orchestrator is whatever session runs /agent-team create`);
        return;
      }
      // A member with no route of its own inherits the block's, so every per-member rule that
      // reads `route` — spec 0043 §1.3's "kind requires route pane" above all — must see the
      // EFFECTIVE route. Validating the bare member instead rejects a legal `kind: codex` member
      // in a `route: pane` block, and does so for every reader: add, edit, create, show.
      for (const e of validateMember({ ...m, route: (m && m.route) || roster.route }, resolved)) errors.push(`member ${i}: ${e}`);
    });
  }
  return errors;
}

// ---------------------------------------------------------------- check-in registry (team.json)

/** The active Team for this hierarchy dir (default, or `team` if named), or null if none/unreadable. */
export function readTeam(dir, team = null) {
  const path = teamPath(dir, team);
  if (!existsSync(path)) return null;
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    // Every reader goes straight to `.members`, so an object without the array is no record:
    // a truncated or hand-edited file must read as unusable rather than crash a verb mid-write.
    return data && typeof data === "object" && !Array.isArray(data) && Array.isArray(data.members) ? data : null;
  } catch {
    return null;
  }
}

/**
 * `readTeam` collapses "no file" and "a file that yields no record" into one null. This keeps them
 * apart: `state` is "absent", "unusable" (the file exists but does not parse to a record) or
 * "usable", with `path` always set and `team` the record only when usable.
 */
export function teamFileState(dir, team = null) {
  const path = teamPath(dir, team);
  if (!existsSync(path)) return { state: "absent", path, team: null };
  const record = readTeam(dir, team);
  return record ? { state: "usable", path, team: record } : { state: "unusable", path, team: null };
}

/** Atomic write: `<path>.tmp` then rename, for any JSON file under `dir` (team.json, team-history.json). */
function atomicWriteJson(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

/** Atomic write: `<path>.tmp` then rename. `team` names which file (default when omitted). */
export function writeTeam(dir, teamData, team = null) {
  atomicWriteJson(teamPath(dir, team), teamData);
}

/** Unlink team.json (or a named team's file); no-op if absent. */
export function clearTeam(dir, team = null) {
  const path = teamPath(dir, team);
  if (!existsSync(path)) return;
  try {
    unlinkSync(path);
  } catch {
    // already gone / racing another sweep — fine
  }
}

/** The Team member whose derived name matches, or null. */
export function teamMemberByName(dir, name, team = null) {
  const t = readTeam(dir, team);
  if (!t || !Array.isArray(t.members) || !name) return null;
  return t.members.find((m) => m.name === name) || null;
}

/** The member of one team (default when `team` is omitted) that was renamed away from `name`, the
    name it would have had, because a session outside the team already held it. */
export function teamMemberRenamedFrom(dir, name, team = null) {
  const t = readTeam(dir, team);
  if (!t || !name) return null;
  return t.members.find((m) => m && m.renamed_from === name) || null;
}

/** Named-slot Team members for a role — peer and pane both occupy one (subagent-routed members
    are recorded but are never dispatch targets by name). Its consumer `resolveSessionTeam` counts
    slots to decide which team a session belongs to, and a pane member fills a slot exactly as a
    peer one does: excluding it would make a team of one codex member count zero. */
export function teamMembersForRole(dir, role, team = null) {
  const t = readTeam(dir, team);
  if (!t || !Array.isArray(t.members)) return [];
  return t.members.filter((m) => m.role === role && routeHasPane(m.route));
}

/** Basenames (sans `.json`) of every named team under `dir/teams/` — does NOT include the default team. */
export function listTeamNames(dir) {
  const teamsDir = join(dir, "teams");
  if (!existsSync(teamsDir)) return [];
  try {
    return readdirSync(teamsDir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => f.slice(0, -5));
  } catch {
    return [];
  }
}

/** The naming prefix of a derived member name `<prefix>-<role>[-N]`, or null when the name does not end in its role. */
export function memberNamePrefix(name, role) {
  if (typeof name !== "string" || typeof role !== "string" || !role) return null;
  const m = new RegExp(`^(.+)-${role}(?:-\\d+)?$`).exec(name);
  return m ? m[1] : null;
}

/**
 * The prefix a legacy `team.json`'s members were named under, inferred from the first member whose
 * name ends in its own role. The file has no stored name, and recomputing the prefix from current
 * config would drift if that config changed while the team ran. Null when no file or no inferable member.
 */
export function legacyTeamPrefix(dir) {
  const t = readTeam(dir, null);
  if (!t) return null;
  for (const m of t.members) {
    const prefix = m && memberNamePrefix(m.name, m.role);
    if (prefix) return prefix;
  }
  return null;
}

/**
 * The roster block a live team was built from: the key its file records (null: the default block).
 * A team file written before teams recorded it keeps the old rule, which keyed the block by the
 * team's own name. No team file → null.
 */
export function teamRosterKey(dir, teamName) {
  const t = readTeam(dir, teamName);
  if (!t) return null;
  if (!Object.prototype.hasOwnProperty.call(t, "roster")) return teamName || null;
  return typeof t.roster === "string" && t.roster ? t.roster : null;
}

/** The member-name set of one team (default when `team` is omitted). */
export function teamMemberNameSet(dir, team = null) {
  const t = readTeam(dir, team);
  if (!t || !Array.isArray(t.members)) return new Set();
  return new Set(t.members.map((m) => m.name).filter(Boolean));
}

/**
 * Which team currently lists `name` as a member (spec 0011 §4.1) — checked
 * against the default team first, then every named team. `{found:false}`
 * when no team's member set contains it; `{found:true, team:null}` for the
 * default team; `{found:true, team:"<name>"}` for a named one. `team:null`
 * on its own is ambiguous between "default team" and "not found" — always
 * branch on `found`, never on `team` alone.
 */
export function resolveMemberTeam(dir, name) {
  if (!name) return { found: false, team: null };
  if (teamMemberNameSet(dir, null).has(name)) return { found: true, team: null };
  for (const team of listTeamNames(dir)) {
    if (teamMemberNameSet(dir, team).has(name)) return { found: true, team };
  }
  return { found: false, team: null };
}

/**
 * Spec 0044 §1.1/§1.7: which team FILE a command with no `--team` operates on. Every team an
 * orchestrator creates from now on lives at `teams/<name>.json`, named for the effective unscoped
 * prefix, because `teamPrefixInfo(cwd, "<X>")` returns prefix `<X>` — so `teams/<prefix>.json`
 * derives byte-identical member names to what bare `create` wrote into `team.json` before.
 *
 * The one exception is §1.7's: a `team.json` that ALREADY exists keeps being the scope, so a team
 * live across the upgrade stays readable, disbandable, resyncable and reapable in place. It is
 * never moved or migrated; it ages out when its own team disbands, after which the next bare
 * command resolves to the named path. Nothing here ever CREATES `team.json`.
 *
 * Existence, not liveness, is the gate on that exception: §1.7 promises a legacy team stays
 * readable, disbandable, resyncable and reapable in place, and a team whose owner has died is
 * exactly the one still needing `disband`/`reap`. What §1.1's invariant forbids is CREATING the
 * shared default, so the guard against a new team landing back in a stale `team.json` lives at
 * the creation site (`roster.mjs resolveWritableTeamScope`), not here.
 *
 * `prefix` is passed in rather than derived: prefix resolution lives in lib-config.mjs and this
 * module is below it in the import order. Returns `{team, defaulted}` — `team: null` means the
 * legacy default file, and `defaulted` says the caller supplied no `--team` (which is what decides
 * whether a name collision should suggest a free candidate or tell the user to disband).
 */
export function defaultTeamScope(dir, prefix) {
  // The flag rides along with the legacy branch too. Returning early without it let a legacy
  // `team.json` mask an unnamable prefix, so the caller skipped [9.1]'s refusal and then derived
  // a team name from a prefix `validateTeamAlias` rejects.
  const bad = isValidTeamAlias(prefix) ? null : { unnamable: prefix, suggested: suggestTeamAlias(prefix) };
  // A legacy file that exists but yields no record still claims the scope: resolving past it
  // would start a second team beside a record nobody can read. `unreadable` names it.
  const legacy = teamFileState(dir, null);
  if (legacy.state === "usable") return { team: null, defaulted: true, ...bad };
  if (legacy.state === "unusable") return { team: null, defaulted: true, ...bad, unreadable: legacy.path };
  // The prefix becomes a path segment, so it has to clear the same validator an explicit `--team`
  // clears — a repo basename is arbitrary text and `teams/<it>.json` must not be able to escape
  // the directory. Spec 0044 [9.1]: a prefix that cannot name a file must not fall back to the
  // unscoped path, which would silently reinstate the shared default across a whole class of
  // repos. `unnamable` says so; the CLI refuses on it at the point a team would be CREATED, not
  // here — refusing during scope resolution would also take out every read of such a repo.
  if (bad) return { team: null, defaulted: true, ...bad };
  return { team: prefix, defaulted: true };
}

/**
 * Spec 0044 §1.6: AUTHORITATIVE team attribution for a session that can see its own pane.
 * The orchestrator wrote this session's pane id into a team member row at spawn time, and a
 * member name is already team-prefixed and unique across concurrent teams — so matching on the
 * pane id identifies the team without inferring anything from role. This is what demotes
 * `resolveSessionTeam`'s role scan to a fallback: under §1.1 two concurrent orchestrators each
 * holding an architect make that scan ambiguous, and ambiguous means it resolves to nothing.
 *
 * Safe-refuse, deliberately (§1.6, §3): two teams claiming one pane id is corrupt state, not a
 * tie to break, and it resolves to null. A wrong match here would let `teams` dismiss and respawn
 * a healthy session, so under-attribution is the only acceptable error direction.
 */
export function resolveTeamByPane(dir, paneId, { liveOnly = false } = {}) {
  return paneId ? paneResolver(dir, { liveOnly })(paneId) : null;
}

/** `resolveTeamByPane` with every team file read once up front, for callers resolving many panes.
    `liveOnly` ignores teams whose orchestrator is gone. */
export function paneResolver(dir, { liveOnly = false } = {}) {
  const teams = [null, ...listTeamNames(dir)].map((teamName) => ({ teamName, team: readTeam(dir, teamName) })).filter(({ team }) => !liveOnly || (team && !teamIsOrphaned(team)));
  return (paneId) => {
    if (!paneId) return null;
    let match = null;
    for (const { teamName, team: t } of teams) {
      const rows = t && Array.isArray(t.members) ? t.members.filter((m) => m && m.transport_id === paneId) : [];
      if (!rows.length) continue;
      if (match || rows.length > 1) return null;
      match = { teamName, team: t, member: rows[0] };
    }
    return match;
  };
}

/**
 * Spec 0036 §3.2/§3.3 (F4/F6): the ONE shared team-resolution used by both SessionStart (no
 * `--team`, no known peer name — role only) and `roster.mjs checkin` (an explicit `--team`, or
 * none). `explicitTeam` given -> a direct lookup, same as every other `--team` subcommand's
 * convention. Omitted -> scan the default team plus every named team for CANDIDATE teams — any
 * team with at least one peer member of this role (G1: candidacy, not uniqueness, decides
 * ambiguity, so a team with TWO members of the role is correctly "ambiguous," never mistaken for
 * "not a candidate" and silently skipped in favor of an unrelated team that happens to have
 * exactly one). Resolve only when there is exactly one candidate team AND it has exactly one such
 * member; more than one candidate, or a lone candidate with more than one member, resolves to
 * nothing (never guess — an unresolved team must skip detection entirely, per §3.2 point 3).
 * Returns `{ teamName, team }` (teamName is `null` for the default team) or `null`.
 *
 * Spec 0044 §1.6 demotes this to a FALLBACK. Inferring a team from role alone was only workable
 * while one default team was the common case; under §1.1 concurrent teams each holding one member
 * of a role make it ambiguous, and ambiguous resolves to nothing. Reach it through
 * `attributeSessionTeam`, which asks `resolveTeamByPane` first, rather than calling it directly.
 */
export function attributeSessionTeam(dir, role, { explicitTeam = null, paneId = null, homes = [dir] } = {}) {
  if (explicitTeam) return resolveSessionTeam(dir, role, explicitTeam);
  const env = envTeamFile(homes);
  if (env && !env.invalid) return { teamName: env.teamName, team: readTeam(env.home, env.teamName), home: env.home, via: "env" };
  const byPane = resolveTeamByPane(dir, paneId);
  if (byPane) return { ...byPane, via: "pane" };
  const byRole = resolveSessionTeam(dir, role);
  return byRole ? { ...byRole, via: "role-scan" } : null;
}

/** `realpath` of the longest existing ancestor of `p`, with the rest appended as written — a team
    file named at launch may not exist yet, and neither may its `teams/` dir. */
function realPrefixPath(p) {
  try {
    return realpathSync(p);
  } catch {
    const parent = dirname(p);
    return parent === p ? p : join(realPrefixPath(parent), basename(p));
  }
}

/**
 * The team file this session was launched into: `AH_TEAM_FILE`, set by the launcher on every
 * member it starts. A path from the environment becomes a file path, so it is accepted only as
 * `<H>/teams/<name>.json` with a valid team name, or `<H>/team.json`, where `<H>` is one of `homes`
 * (compared by realpath). The file need not exist: SessionStart fires before the launcher writes it.
 * Returns null when unset; `{invalid: why, kind, value}` when rejected, `kind` being `other-repo` for
 * a well-formed team file of some other repo's hierarchy dir (a correctly launched peer running a
 * command against another repo) and `malformed` for anything else; else `{home, teamName}` (null
 * name: the legacy `team.json`).
 */
export function envTeamFile(homes, value = process.env.AH_TEAM_FILE) {
  if (typeof value !== "string" || value === "") return null;
  const malformed = (why) => ({ invalid: why, kind: "malformed", value });
  if (!isAbsolute(value)) return malformed("it is not an absolute path");
  if (value.split("/").includes("..")) return malformed("it climbs directories with `..`");
  const path = resolve(value);
  const home = teamFileHome(path);
  if (!home) return malformed("it is not a team file path (<hierarchy dir>/teams/<name>.json or <hierarchy dir>/team.json)");
  const legacy = basename(path) === "team.json";
  const teamName = legacy ? null : basename(path).replace(/\.json$/, "");
  if (!legacy && (!path.endsWith(".json") || !isValidTeamAlias(teamName))) return malformed("it does not name a team file with a valid team name");
  const realHome = realPrefixPath(home);
  const match = homes.filter(Boolean).find((h) => realPrefixPath(resolve(h)) === realHome);
  if (match) return { home: match, teamName };
  // A hierarchy dir is `<repo>/.claude/hierarchy`, or `~/.claude/hierarchy/<name>` outside a repo.
  const isHierarchyDir = (h) => (basename(h) === "hierarchy" && basename(dirname(h)) === ".claude") || (basename(dirname(h)) === "hierarchy" && basename(dirname(dirname(h))) === ".claude");
  if (!isHierarchyDir(home)) return malformed("it is not inside a hierarchy dir");
  return { invalid: `it is a team file of another repo's hierarchy dir (${home}), not this one's`, kind: "other-repo", value };
}

/**
 * The team a session that owns none belongs to: the team file it was launched into, else the one
 * LIVE team whose member row holds its pane. Never inferred from role — a peer whose team file is
 * not written yet would otherwise be attributed to some other team that has a member of its role.
 */
export function memberTeam(dir, homes, paneId) {
  const env = envTeamFile(homes);
  if (env && !env.invalid) return { teamName: env.teamName, home: env.home, via: "env" };
  const byPane = resolveTeamByPane(dir, paneId, { liveOnly: true });
  return byPane ? { teamName: byPane.teamName, home: dir, via: "pane" } : null;
}

export function resolveSessionTeam(dir, role, explicitTeam = null) {
  if (explicitTeam) {
    const team = readTeam(dir, explicitTeam);
    return team ? { teamName: explicitTeam, team } : null;
  }
  let match = null;
  for (const teamName of [null, ...listTeamNames(dir)]) {
    const n = teamMembersForRole(dir, role, teamName).length;
    if (n === 0) continue;
    if (match || n > 1) return null;
    match = { teamName, team: readTeam(dir, teamName) };
  }
  return match;
}

// ---------------------------------------------------------------- team history (spec 0015)

// ponytail: 24h is a blunt fixed ceiling, not a config knob — see spec 0001 §5.3.
/** A team is "live" when its orchestrator pid is alive and it isn't past the stale-age cutoff. */
export const TEAM_STALE_AGE_SEC = 24 * 3600;

/**
 * Whether `invoker` (`{pid, sessionId}`) owns team `t`: the recorded owner pid is the invoker's and
 * is alive, and — when both the invocation and the team know a session id — the two agree. That
 * session check is the only guard against a reused pid; without one, the pid alone decides.
 */
export function teamOwnedBy(t, invoker) {
  if (!t || !invoker || !Number.isInteger(invoker.pid)) return false;
  const orch = t.orchestrator || {};
  if (Number(orch.pid) !== invoker.pid || !pidAlive(invoker.pid)) return false;
  return !(invoker.sessionId && orch.session_id && orch.session_id !== invoker.sessionId);
}

/**
 * Same predicate sessionstart.mjs's stale-team sweep uses. The age cap is an orphan heuristic for a
 * team whose owner the reader cannot vouch for; given the `invoker`, a team it owns is live at any
 * age, because an owner vouches for its team simply by being alive.
 */
export function teamIsLive(t, invoker = null) {
  if (!t) return false;
  if (invoker && teamOwnedBy(t, invoker)) return true;
  const pid = t.orchestrator && t.orchestrator.pid;
  return pidAlive(pid) && ageSecOf(t.created) <= TEAM_STALE_AGE_SEC;
}

/** Reapable: the owning process is provably gone. Age is NOT a factor — see 0033 §3.3.
    NOT `!teamIsLive` — that also flags a >24h-old but still-running team, which a bulk
    deleter (`roster reap`) must never touch. `pidAlive`'s EPERM-means-alive branch makes
    every error mode here a false negative (a recycled pid reads as alive, so it is not
    reaped) — never a wrong deletion of a live team. */
export function teamIsOrphaned(t) {
  if (!t) return false;
  const pid = t.orchestrator && t.orchestrator.pid;
  return !pidAlive(pid);
}

/** `team-history.json` for this hierarchy dir. */
export const historyPath = (dir) => join(dir, "team-history.json");

/** `{version, teams:[]}`, always — a missing or corrupt file reads back as empty, never throws. */
export function readHistory(dir) {
  const path = historyPath(dir);
  if (!existsSync(path)) return { version: 1, teams: [] };
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    return data && typeof data === "object" && Array.isArray(data.teams) ? data : { version: 1, teams: [] };
  } catch {
    return { version: 1, teams: [] };
  }
}

/** Atomic write of the whole history document. */
export function writeHistory(dir, h) {
  atomicWriteJson(historyPath(dir), h);
}

/**
 * Config-only fingerprint of a roster (spec 0015 §3.1): stable across re-runs of the same
 * roster, so re-committing the same config updates one entry instead of piling up duplicates.
 * `members` must already be normalized (normalizeMembers) — config fields only, role-sorted.
 */
export function fingerprint({ roster_level, transport, members }) {
  const canonical = JSON.stringify({ roster_level: roster_level || null, transport: transport || null, members });
  return createHash("sha256").update(canonical).digest("hex").slice(0, 8);
}

/**
 * Strips a committed team's members down to the config that reproduces them (spec 0015 §3.1):
 * role, model, effort, route, auto_mode. No name, ref, transport_id, or any other runtime/launch
 * field. Sorted by role so fingerprint/output ordering is stable.
 */
export function normalizeMembers(members) {
  const list = Array.isArray(members) ? members : [];
  return list
    .slice()
    .sort((a, b) => ((a && a.role) || "").localeCompare((b && b.role) || ""))
    .map((m) => {
      const out = {};
      for (const key of ["role", "model", "effort", "route"]) {
        const value = m ? m[key] : undefined;
        if (value !== undefined && value !== null) out[key] = value;
      }
      // Spec 0043 §1.1: persist `kind` only when it is not the default, so replaying a
      // pre-0043 team through `create --from` reproduces byte-identical member rows.
      if (m && resolveKind(m) !== KIND_DEFAULT) out.kind = resolveKind(m);
      const args = memberArgs(m);
      if (args) out.args = [...args];
      // Committed members carry camelCase `autoMode` (spec 0015 §3.1's evidence amendment — the
      // spec's own on-disk example uses snake_case `auto_mode`, so store under that key regardless
      // of which case the source member used).
      const autoMode = m ? (m.auto_mode !== undefined ? m.auto_mode : m.autoMode) : undefined;
      if (autoMode !== undefined && autoMode !== null) out.auto_mode = autoMode;
      return out;
    });
}

/** True iff `e` is the history entry behind the currently-live team for its alias. */
export function historyEntryIsActive(dir, e) {
  const t = readTeam(dir, e.alias || null);
  return teamIsLive(t) && t.team_id === e.last_team_id;
}

/**
 * Evict least-recently-used, never-active entries until at most 5 remain (spec 0015 §6, amended).
 * `justUpsertedId` is excluded from candidates unconditionally, regardless of liveness — without
 * this, the entry just inserted/refreshed by this same write is the only non-active candidate
 * whenever the other 5 are all live, and gets evicted on the write that created it.
 */
function evictHistory(dir, h, justUpsertedId) {
  while (h.teams.length > 5) {
    const candidates = h.teams.filter((e) => e.id !== justUpsertedId && !historyEntryIsActive(dir, e));
    if (!candidates.length) break;
    candidates.sort((a, b) =>
      a.last_used !== b.last_used
        ? a.last_used < b.last_used
          ? -1
          : 1
        : a.created_at !== b.created_at
          ? a.created_at < b.created_at
            ? -1
            : 1
          : a.id < b.id
            ? -1
            : 1,
    );
    const victim = candidates[0];
    h.teams = h.teams.filter((t) => t !== victim);
  }
}

/**
 * Insert-or-refresh one history entry by fingerprint (spec 0015 §4). `members` must already be
 * normalized. Returns `{capExceeded}` — true when a live team kept the cap from being enforced.
 */
export function upsertHistory(dir, { fingerprint: fp, alias, roster_level, transport, members, team_id }) {
  const h = readHistory(dir);
  const now = localIso();
  const label = `${alias || "default"} (${members.length} role${members.length === 1 ? "" : "s"})`;
  const idx = h.teams.findIndex((t) => t.fingerprint === fp);
  let upsertedId;
  if (idx === -1) {
    upsertedId = newId();
    h.teams.push({
      id: upsertedId,
      fingerprint: fp,
      alias: alias || null,
      label,
      created_at: now,
      last_used: now,
      last_team_id: team_id || null,
      roster_level: roster_level || null,
      transport: transport || null,
      members,
    });
  } else {
    upsertedId = h.teams[idx].id;
    h.teams[idx] = { ...h.teams[idx], alias: alias || null, label, last_used: now, last_team_id: team_id || null, roster_level: roster_level || null, transport: transport || null, members };
  }
  evictHistory(dir, h, upsertedId);
  h.teams.sort((a, b) => (a.last_used < b.last_used ? 1 : -1));
  writeHistory(dir, h);
  return { capExceeded: h.teams.length > 5 };
}
