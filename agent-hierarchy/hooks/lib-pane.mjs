#!/usr/bin/env node
/**
 * agent-hierarchy — /pane primitives.
 *
 * A pane is a real, interactive, top-level Claude Code session launched with
 * `claude --agent <name>` inside its own detached tmux session, which the user
 * can watch and type into. The Orchestrator delegates to it and gets one reply
 * back per solicited turn.
 *
 * Everything mechanical lives here: agent resolution, the append-only
 * registry, the per-pane mailbox, tmux, and the optional iTerm2 presentation
 * split. `pane.mjs` is the CLI over it; `stop-pane-relay.mjs` shares only the
 * mailbox conventions and deliberately imports nothing from this file, so its
 * fast path stays a single env lookup.
 *
 * Two rules that are easy to break and expensive to debug:
 *
 *   - Orientation letters name the DIVIDER, and the two backends disagree.
 *     `v` = vertical divider = side by side = iTerm2 `split vertically`
 *     = tmux `-h`. `h` = stacked = iTerm2 `split horizontally` = tmux `-v`.
 *     The registry and every message say "right"/"below" in words; the letters
 *     are translated at exactly one boundary, `itermSplit()` below.
 *
 *   - Values reaching a shell are WHITELISTED, never quoted. tmux runs its
 *     command argument through `sh`, so the agent name, key, model, and
 *     permission mode are each matched against a fixed pattern or a fixed
 *     array before they are interpolated. That is the feature's only injection
 *     surface.
 */

import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

// ---------------------------------------------------------------- paths

export const REGISTRY_PATH = join(homedir(), ".claude", "agent-hierarchy.panes.jsonl");
export const MAILBOX_ROOT = join(homedir(), ".claude", "agent-hierarchy.panes");
export const REGISTRY_MAX_LINES = 2000;

export function mailboxDir(key) {
  return join(MAILBOX_ROOT, key);
}

// ------------------------------------------------------------ whitelists

/** Agent names reaching the tmux command string. Whitelist, not quoting (§12.1). */
export const AGENT_RE = /^[A-Za-z0-9_:-]{1,80}$/;
/** Pane keys, which are also tmux session names. */
export const KEY_RE = /^ah-[a-z0-9-]{1,60}$/;
/** `--model` values: the four aliases or a full model id. */
export const MODEL_RE = /^claude-[a-z0-9.[\]-]+$/;
export const MODEL_ALIASES = ["sonnet", "opus", "haiku", "fable"];
/** iTerm2 session UUIDs, before they are interpolated into AppleScript. */
export const ITERM_UUID_RE = /^[A-Za-z0-9-]{1,64}$/;

/**
 * Permission modes accepted from the command line.
 *
 * `bypassPermissions` is deliberately absent: it disables every check, and a
 * flag a model types mid-conversation is not the deliberate, persistent,
 * reviewable act that warrants it. It is reachable only through
 * `panes.permissionMode` in a config file.
 */
export const ARGV_PERMISSION_MODES = ["manual", "acceptEdits", "auto", "dontAsk"];
export const CONFIG_PERMISSION_MODES = [...ARGV_PERMISSION_MODES, "bypassPermissions"];

/**
 * What each mode actually does, per the official permission-modes reference.
 * Worth stating because two of them are routinely misremembered: `dontAsk`
 * auto-DENIES anything that would have prompted (it never stalls, but it also
 * never grants), and `acceptEdits` covers reads, edits, and safe filesystem
 * commands but NOT general Bash — so a paned Implementor still stalls on a
 * test or build run.
 */
export const PERMISSION_MODE_NOTES = {
  manual: "prompts for anything beyond reads — will stall if nobody is attached",
  acceptEdits: "auto-accepts file edits and safe FS commands; general Bash still prompts",
  auto: "no routine prompts, with a background safety classifier",
  dontAsk: "auto-DENIES anything that would prompt — never stalls, never grants",
  bypassPermissions: "no permission checks at all — containers/VMs only",
};

export const HIERARCHY_ROLES = ["ultra-advisor", "architect", "reviewer", "implementor", "task-runner"];

/**
 * Roles whose permission mode is settled by policy, so `open` does not ask.
 * The Implementor is absent on purpose: it can execute, so its mode is the
 * user's call at creation time.
 */
export const NO_PROMPT_ROLES = ["architect", "reviewer", "ultra-advisor", "task-runner"];

export const BUILTIN_AGENTS = ["Explore", "Plan", "general-purpose", "claude", "statusline-setup", "claude-code-guide"];

// --------------------------------------------------------- orientation

/**
 * Orientation words. The LETTER NAMES THE DIVIDER: `v` is a vertical divider,
 * which puts the panes side by side. Returns "right" | "below" | null.
 */
export function parseOrientation(word) {
  if (word === undefined || word === null || word === "") return null;
  const w = String(word).trim().toLowerCase();
  if (w === "v" || w === "r" || w === "right") return "right";
  if (w === "h" || w === "b" || w === "below") return "below";
  return null;
}

/** How an orientation reads in a confirmation. Never echo a flag or a letter. */
export function orientationPhrase(orientation) {
  return orientation === "below" ? "opened below" : "opened to the right";
}

// -------------------------------------------------- frontmatter parsing

/**
 * The frontmatter block of an agent definition, as a flat object.
 *
 * Deliberately minimal: only `name`, `tools`, `disallowedTools`, `model`, and
 * `initialPrompt` are consulted anywhere, and agent definitions write them as
 * scalars or one-line lists. List-valued keys come back as arrays; everything
 * else comes back as a string.
 */
export function parseFrontmatter(text) {
  const lines = String(text).split(/\r?\n/);
  if (lines[0] !== "---") return {};
  const out = {};
  let key = null;
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (line === "---") break;
    const listItem = /^\s*-\s+(.*)$/.exec(line);
    if (listItem && key) {
      if (!Array.isArray(out[key])) out[key] = out[key] ? [String(out[key])] : [];
      out[key].push(listItem[1].trim().replace(/^["']|["']$/g, ""));
      continue;
    }
    const kv = /^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/.exec(line);
    if (!kv) continue;
    key = kv[1];
    const raw = kv[2].trim();
    out[key] = raw === "" ? [] : raw.replace(/^["']|["']$/g, "");
  }
  return out;
}

function toolList(value) {
  if (value === undefined || value === null) return null;
  if (Array.isArray(value)) return value.map((v) => String(v).trim()).filter(Boolean);
  const s = String(value).trim();
  if (!s) return null;
  return s
    .replace(/^\[|\]$/g, "")
    .split(/[,\s]+/)
    .map((v) => v.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean);
}

/**
 * Whether a definition's resolved toolset lets the agent change things or run
 * commands. `open` asks the user to choose a permission mode for exactly these
 * agents, and says nothing for the rest — an agent that can only read has no
 * decision to make.
 */
export function canExecute(frontmatter) {
  const allow = toolList(frontmatter.tools);
  if (allow && allow.length) {
    if (allow.includes("*")) return true;
    return allow.some((t) => t === "Bash" || t === "Edit");
  }
  const deny = toolList(frontmatter.disallowedTools) || [];
  const denies = (t) => deny.includes(t);
  return !denies("Bash") || !denies("Edit");
}

// ------------------------------------------------------ agent resolution

function scanAgentDir(root, wanted) {
  const hits = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(".md")) {
        let fm;
        try {
          fm = parseFrontmatter(readFileSync(full, "utf8"));
        } catch {
          continue;
        }
        // The docs are explicit that the filename need not match `name:`.
        if (typeof fm.name === "string" && fm.name === wanted) hits.push({ path: full, frontmatter: fm });
      }
    }
  };
  walk(root);
  hits.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return hits;
}

/**
 * Locate a plugin's install directory through installed_plugins.json.
 *
 * NEVER glob the plugin cache: multiple versions of a plugin coexist under
 * cache/<marketplace>/<plugin>/<version>/ and a glob picks an arbitrary one.
 */
function resolveInstalledPlugin(pluginId) {
  const manifest = join(homedir(), ".claude", "plugins", "installed_plugins.json");
  let data;
  try {
    data = JSON.parse(readFileSync(manifest, "utf8"));
  } catch {
    return { error: `could not read ${manifest}` };
  }
  const plugins = (data && data.plugins) || {};
  const records = [];
  for (const [id, list] of Object.entries(plugins)) {
    if (id.split("@")[0] !== pluginId) continue;
    for (const rec of Array.isArray(list) ? list : []) records.push(rec);
  }
  if (!records.length) return { error: `no installed plugin named \`${pluginId}\`` };

  const scopeRank = (r) => (r.scope === "project" ? 0 : r.scope === "user" ? 1 : 2);
  const existsRank = (r) => (r.installPath && existsSync(r.installPath) ? 0 : 1);
  const semver = (v) =>
    String(v || "0")
      .split(".")
      .map((n) => parseInt(n, 10) || 0);
  const cmpSemver = (a, b) => {
    const x = semver(a);
    const y = semver(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
      if ((y[i] || 0) !== (x[i] || 0)) return (y[i] || 0) - (x[i] || 0);
    }
    return 0;
  };
  records.sort(
    (a, b) =>
      scopeRank(a) - scopeRank(b) ||
      existsRank(a) - existsRank(b) ||
      cmpSemver(a.version, b.version) ||
      String(b.lastUpdated || "").localeCompare(String(a.lastUpdated || ""))
  );
  const chosen = records[0];
  if (!chosen.installPath || !existsSync(chosen.installPath)) {
    return { error: `installed plugin \`${pluginId}\` has no install path on disk` };
  }
  return { installPath: chosen.installPath, version: chosen.version };
}

/**
 * Resolve an agent name to its definition file.
 *
 * Resolution exists for validation, model and permission policy, refusals, and
 * for naming the resolved path in the confirmation — never to build the CLI
 * invocation. `claude --agent <name>` applies the definition's own
 * restrictions itself.
 *
 * Returns { ok: true, source, definitionPath, installPath, frontmatter,
 * warnings } or { ok: false, error }.
 */
export function resolveAgent(name, cwd) {
  const warnings = [];
  if (BUILTIN_AGENTS.includes(name)) {
    return { ok: false, builtin: true, error: `${name} is a Claude Code built-in with no definition file on disk.` };
  }

  const scopes = [
    { source: "project", root: cwd ? join(resolve(cwd), ".claude", "agents") : null },
    { source: "user", root: join(homedir(), ".claude", "agents") },
  ];
  for (const scope of scopes) {
    if (!scope.root || !existsSync(scope.root)) continue;
    const hits = scanAgentDir(scope.root, name);
    if (!hits.length) continue;
    if (hits.length > 1) {
      warnings.push(`two ${scope.source}-scope agents are named \`${name}\`: ${hits[0].path} and ${hits[1].path}. Using the first.`);
    }
    return {
      ok: true,
      source: scope.source,
      definitionPath: hits[0].path,
      installPath: null,
      frontmatter: hits[0].frontmatter,
      warnings,
    };
  }

  if (!name.includes(":")) {
    return { ok: false, error: `no agent named \`${name}\` in <cwd>/.claude/agents or ~/.claude/agents, and it is not a namespaced plugin agent (plugin:agent).` };
  }

  const idx = name.indexOf(":");
  const pluginId = name.slice(0, idx);
  const rest = name.slice(idx + 1);
  const found = resolveInstalledPlugin(pluginId);
  if (found.error) return { ok: false, error: found.error };

  const agentsDir = join(found.installPath, "agents");
  const definitionPath = join(agentsDir, `${rest.split(":").join("/")}.md`);
  if (!existsSync(definitionPath)) {
    let available = [];
    try {
      available = readdirSync(agentsDir)
        .filter((f) => f.endsWith(".md"))
        .map((f) => f.replace(/\.md$/, ""));
    } catch {
      /* the plugin may simply have no agents dir */
    }
    return {
      ok: false,
      error: `plugin \`${pluginId}\` has no agent \`${rest}\`${available.length ? ` — it defines: ${available.join(", ")}` : " (it defines no agents)"}`,
    };
  }

  let frontmatter = {};
  try {
    frontmatter = parseFrontmatter(readFileSync(definitionPath, "utf8"));
  } catch {
    warnings.push(`could not read frontmatter from ${definitionPath}`);
  }
  return { ok: true, source: "plugin", definitionPath, installPath: found.installPath, frontmatter, warnings };
}

/** The hierarchy role an agent name denotes, anchored `(^|:)role$`, or null. */
export function roleOfAgent(name) {
  if (typeof name !== "string" || !name) return null;
  return HIERARCHY_ROLES.find((role) => name === role || name.endsWith(`:${role}`)) || null;
}

// ------------------------------------------------------------- panes config

export const PANE_DEFAULTS = {
  timeoutSeconds: 300,
  pollSeconds: 2,
  inlinePromptMaxChars: 2000,
  iterm2: true,
  allowBuiltins: false,
  permissionMode: null,
  size: { x: 200, y: 50 },
};

/**
 * The `panes` block of a resolved agent-hierarchy config, with defaults filled
 * in. Additive by design: a config with no `panes` block is valid and stays at
 * schema version 1.
 */
export function panesConfig(rawPanes) {
  const out = { ...PANE_DEFAULTS, size: { ...PANE_DEFAULTS.size }, warnings: [] };
  if (!rawPanes || typeof rawPanes !== "object") return out;
  for (const [k, v] of Object.entries(rawPanes)) {
    if (!(k in PANE_DEFAULTS)) {
      out.warnings.push(`unknown key \`panes.${k}\` ignored.`);
      continue;
    }
    if (k === "size") {
      if (v && typeof v === "object") {
        if (Number.isFinite(v.x)) out.size.x = v.x;
        if (Number.isFinite(v.y)) out.size.y = v.y;
      }
      continue;
    }
    if (k === "permissionMode") {
      if (v === null) continue;
      if (!CONFIG_PERMISSION_MODES.includes(v)) {
        out.warnings.push(`ignoring panes.permissionMode "${v}" — not one of ${CONFIG_PERMISSION_MODES.join(", ")}.`);
        continue;
      }
    }
    out[k] = v;
  }
  return out;
}

// ---------------------------------------------------------------- registry

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
}

export function appendRegistry(record) {
  ensureDir(join(homedir(), ".claude"));
  appendFileSync(REGISTRY_PATH, JSON.stringify(record) + "\n");
}

function readRegistryLines(path = REGISTRY_PATH) {
  try {
    return readFileSync(path, "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Current state is a FOLD over the append-only log: a key is live iff its most
 * recent event is `open`. Never read-modify-write this file — measured on this
 * plugin's sibling state, that dropped roughly 4 of 12 concurrent writes.
 */
export function foldRegistry(path = REGISTRY_PATH) {
  const last = new Map();
  for (const line of readRegistryLines(path)) {
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (!rec || typeof rec.key !== "string") continue;
    last.set(rec.key, rec);
  }
  const live = new Map();
  for (const [key, rec] of last) if (rec.ev === "open") live.set(key, rec);
  return live;
}

/** Rewrite the log to a temp file holding only live keys' events, then rename. */
export function compactRegistry(path = REGISTRY_PATH) {
  const lines = readRegistryLines(path);
  if (lines.length <= REGISTRY_MAX_LINES) return false;
  const live = new Set(foldRegistry(path).keys());
  const kept = lines.filter((line) => {
    try {
      return live.has(JSON.parse(line).key);
    } catch {
      return false;
    }
  });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, kept.length ? kept.join("\n") + "\n" : "");
  renameSync(tmp, path);
  return true;
}

// ----------------------------------------------------------------- mailbox

export function paneLog(dir, event) {
  try {
    ensureDir(dir);
    appendFileSync(join(dir, "log.jsonl"), JSON.stringify({ ...event, at: event.at || new Date().toISOString() }) + "\n");
  } catch {
    /* the audit trail must never take a command down */
  }
}

export function readJsonFile(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** Write JSON through a `.tmp` + rename, so a reader never sees a partial file. */
export function writeJsonAtomic(path, value) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(value));
  renameSync(tmp, path);
}

/**
 * The pane's session-identity file, written by its own SessionStart.
 *
 * First-writer-wins via the exclusive `wx` flag: the pane's boot is the first
 * SessionStart that can run against this directory, so the first write is the
 * real one and a later grandchild cannot overwrite the identity §9.4 gate D
 * checks against.
 */
export function recordPaneSession(paneDir, input) {
  ensureDir(paneDir);
  const record = {
    session_id: (input && input.session_id) || null,
    agent_type: (input && input.agent_type) || null,
    at: new Date().toISOString(),
  };
  try {
    writeFileSync(join(paneDir, "session"), JSON.stringify(record), { flag: "wx" });
  } catch {
    /* already claimed — leave the first writer's record alone */
  }
}

// -------------------------------------------------------- injected text

/**
 * The context injected into a pane session at SessionStart. Builds a string and
 * does no I/O, so a broken mailbox cannot cost the session its protocol.
 *
 * This text owns the top slot of the pane's injected context.
 */
export function buildPaneProtocol({ role, declaredRole, key }) {
  const identity = role || declaredRole || "an agent-hierarchy role";
  const lines = [
    `agent-hierarchy PANE. You are running as \`${identity}\` in an agent-hierarchy pane${key ? ` (\`${key}\`)` : ""}. You are NOT the Orchestrator: do not decompose-and-dispatch, do the role's own work.`,
    "",
    "1. One channel, inbound only. You answer the turn you were given. You cannot initiate contact with the Orchestrator — there is no tool and no address for it. Your final assistant message IS your reply, and it is captured automatically.",
    "2. The reply is the whole payload. Only your final assistant message is relayed; thinking, tool output, and intermediate turns are discarded. Make that last message a complete, standalone answer.",
    "3. Artifacts go to disk. If you produce a spec file, a diff, or a report, write it to disk and put the ABSOLUTE PATH in your final message. Do not paste the artifact into the reply.",
    "4. A human may type into this pane directly. That input is the user's own instruction and you should treat it as such. A turn the Orchestrator did not solicit is not relayed anywhere — that conversation is between you and the human only.",
    "5. No nesting. Do not open panes, and do not run `/agent-hierarchy:pane`. You DO have the Agent tool and ordinary subagent dispatch remains correct for your role; panes specifically are what you may not open.",
    "6. Your role contract still applies. Your `agents/*.md` body governs, and nothing here relaxes it.",
  ];
  if (role && declaredRole && role !== declaredRole) {
    lines.push(
      "",
      `(Note: this pane was opened for \`${declaredRole}\`, but the session reports \`${role}\`. An environment variable reached a session it was not meant for — tell the user.)`
    );
  }
  return lines.join("\n");
}

// -------------------------------------------------------------------- tmux

function run(cmd, args, opts = {}) {
  const res = spawnSync(cmd, args, { encoding: "utf8", ...opts });
  return {
    status: res.status === null ? 1 : res.status,
    stdout: (res.stdout || "").trim(),
    stderr: (res.stderr || "").trim(),
    error: res.error || null,
  };
}

export function tmuxAvailable() {
  return run("command", ["-v", "tmux"], { shell: "/bin/sh" }).status === 0;
}

export function tmuxPath() {
  return run("command", ["-v", "tmux"], { shell: "/bin/sh" }).stdout;
}

/**
 * The `claude` command string tmux will run. Every interpolated value has
 * already been whitelisted by the caller; this function re-checks rather than
 * trusting that, because it is the last point before a shell sees the string.
 */
export function buildLaunchCommand({ agent, model, permissionMode }) {
  if (!AGENT_RE.test(agent)) throw new Error(`agent name failed the whitelist: ${agent}`);
  const parts = ["claude", "--agent", agent];
  if (model) {
    if (!MODEL_ALIASES.includes(model) && !MODEL_RE.test(model)) throw new Error(`model failed the whitelist: ${model}`);
    parts.push("--model", model);
  }
  if (permissionMode) {
    if (!CONFIG_PERMISSION_MODES.includes(permissionMode)) throw new Error(`permission mode failed the whitelist: ${permissionMode}`);
    parts.push("--permission-mode", permissionMode);
  }
  return parts.join(" ");
}

/** The full argv for the launch, exposed so `--dry-run` can print exactly what would run. */
export function buildTmuxArgv({ key, cwd, size, env, command }) {
  if (!KEY_RE.test(key)) throw new Error(`pane key failed the whitelist: ${key}`);
  const argv = ["new-session", "-d", "-s", key, "-x", String(size.x), "-y", String(size.y), "-c", cwd];
  for (const [name, value] of Object.entries(env)) argv.push("-e", `${name}=${value}`);
  argv.push("-P", "-F", "#{pane_id} #{pane_pid}", command);
  return argv;
}

/**
 * Create the detached tmux session and capture its pane id and pane pid AT
 * CREATION. They are never rediscovered later: scanning for a pane is both the
 * shape §13.4 designs away from and a way to grab the wrong one.
 *
 * Verified on tmux 3.7b: `new-session -P -F '#{pane_id} #{pane_pid}'` prints
 * both fields ("%0 58354"), so the display-message fallback is only for hosts
 * where it does not.
 */
export function openTmuxSession(argv, key) {
  const res = run("tmux", argv);
  if (res.status !== 0) return { ok: false, error: res.stderr || "tmux new-session failed" };
  let [paneId, panePid] = res.stdout.split(/\s+/);
  if (!paneId || !panePid) {
    const fallback = run("tmux", ["display-message", "-p", "-t", key, "#{pane_id} #{pane_pid}"]);
    [paneId, panePid] = fallback.stdout.split(/\s+/);
  }
  if (!paneId) return { ok: false, error: `tmux did not report a pane id for ${key}` };
  return { ok: true, paneId, panePid: panePid ? parseInt(panePid, 10) : null };
}

/** Both checks must hold, against a key and pane id we recorded ourselves. */
export function isPaneLive(record) {
  if (!record || !KEY_RE.test(record.key)) return false;
  if (run("tmux", ["has-session", "-t", record.key]).status !== 0) return false;
  const panes = run("tmux", ["list-panes", "-t", record.key, "-F", "#{pane_id}"]);
  if (panes.status !== 0) return false;
  return panes.stdout.split("\n").includes(record.pane_id);
}

/**
 * Deliver a prompt to a pane.
 *
 * `paste-buffer -p` is BRACKETED paste: multi-line text arrives intact, lands
 * as a "[Pasted text]" chip, and does not auto-submit. Plain `send-keys` with
 * embedded newlines submits on the first newline and mangles `$`, backticks,
 * and quotes — it is wrong for prompts.
 *
 * The only literal keystroke this feature ever sends is `Enter`. Everything
 * else goes through the buffer. That is the correctness argument and the
 * security one at once: a tool that types arbitrary keys into a terminal it
 * located by scanning is the shape this design stays out of.
 */
export function sendPrompt(paneId, reqid, text) {
  const buf = `ahp-${reqid}`;
  const load = run("tmux", ["load-buffer", "-b", buf, "-"], { input: text });
  if (load.status !== 0) return { ok: false, error: load.stderr || "tmux load-buffer failed" };
  const paste = run("tmux", ["paste-buffer", "-b", buf, "-p", "-t", paneId]);
  if (paste.status !== 0) {
    run("tmux", ["delete-buffer", "-b", buf]);
    return { ok: false, error: paste.stderr || "tmux paste-buffer failed" };
  }
  const enter = run("tmux", ["send-keys", "-t", paneId, "Enter"]);
  run("tmux", ["delete-buffer", "-b", buf]);
  if (enter.status !== 0) return { ok: false, error: enter.stderr || "tmux send-keys Enter failed" };
  return { ok: true };
}

/** Read-only, and only ever against a pane id the registry recorded. */
export function capturePane(paneId, lines) {
  const res = run("tmux", ["capture-pane", "-p", "-t", paneId, "-S", `-${lines}`]);
  return res.status === 0 ? res.stdout : null;
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Kill a pane's tmux session and then reap its process.
 *
 * `tmux kill-session` has been observed NOT to take the Claude Code process
 * with it, leaving a billed session running, so the recorded pid is checked
 * and signalled afterwards.
 *
 * Kill safety rails, all mandatory: only a pid the registry recorded at
 * creation is ever signalled (never one derived from `ps`, `pgrep`, or any
 * live scan), never our own pid or parent, and never a session whose name does
 * not look like ours.
 */
export function killPane(record) {
  const notes = [];
  if (!record || !KEY_RE.test(record.key || "")) return { ok: false, error: "refusing to kill: key does not match ^ah-" };
  if (!/^ah-/.test(record.tmux_session || "")) return { ok: false, error: "refusing to kill: tmux_session does not match ^ah-" };

  run("tmux", ["kill-session", "-t", record.key]);

  const pid = record.pane_pid;
  if (!Number.isInteger(pid) || pid <= 0) {
    notes.push(`no pane_pid was recorded for ${record.key}; not guessing. If a \`claude\` process survives, find it with: ps -ax | grep 'claude --agent'`);
    return { ok: true, notes };
  }
  if (pid === process.pid || pid === process.ppid) {
    return { ok: false, error: `refusing to kill pid ${pid}: it is this process or its parent` };
  }
  if (!pidAlive(pid)) return { ok: true, notes };

  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return { ok: true, notes };
  }
  for (let waited = 0; waited < 3000 && pidAlive(pid); waited += 250) sleepSync(250);
  if (pidAlive(pid)) {
    try {
      process.kill(pid, "SIGKILL");
      notes.push(`pane process ${pid} ignored SIGTERM and was killed.`);
    } catch {
      notes.push(`pane process ${pid} could not be killed; kill it by hand.`);
    }
  }
  return { ok: true, notes };
}

// ------------------------------------------------------------------ iTerm2

/** All three must hold, or the presentation layer is skipped in silence. */
export function itermAvailable() {
  return process.platform === "darwin" && process.env.TERM_PROGRAM === "iTerm.app" && Boolean(process.env.ITERM_SESSION_ID);
}

/**
 * The Orchestrator's own iTerm2 session UUID.
 *
 * ONLY the UUID after the colon is stable. The `w0t2p0` prefix records where
 * the session was BORN and goes stale — a session observed as `w0t2p0` was
 * actually at w1 t4 p1 — so it must never be parsed for targeting.
 */
export function itermSelfUuid() {
  const raw = process.env.ITERM_SESSION_ID || "";
  const uuid = raw.includes(":") ? raw.slice(raw.indexOf(":") + 1) : "";
  return ITERM_UUID_RE.test(uuid) ? uuid : null;
}

/**
 * Build the AppleScript that splits the Orchestrator's own iTerm2 session and
 * attaches the new pane to the tmux session.
 *
 * Targeting walks windows → tabs → sessions matching `id of s` against the
 * UUID. It must NEVER use `current session of current window`: that follows
 * the user's focus, so the pane can land in a different tab — possibly inside
 * a different running Claude Code session.
 *
 * This is the one and only place an orientation word becomes a split
 * direction. iTerm2's naming matches the divider convention; tmux's inverts
 * it, which is why the translation lives at a single boundary.
 */
export function itermSplitScript(uuid, key, orientation) {
  if (!ITERM_UUID_RE.test(uuid)) throw new Error(`iTerm2 session uuid failed the whitelist: ${uuid}`);
  if (!KEY_RE.test(key)) throw new Error(`pane key failed the whitelist: ${key}`);
  const direction = orientation === "below" ? "split horizontally with default profile" : "split vertically with default profile";
  return [
    'tell application "iTerm2"',
    `  set targetUUID to "${uuid}"`,
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      repeat with s in sessions of t",
    "        if (id of s) is targetUUID then",
    "          tell s",
    `            set newSession to (${direction})`,
    "          end tell",
    "          tell newSession",
    `            write text "tmux attach -t ${key}"`,
    "          end tell",
    "          return id of newSession",
    "        end if",
    "      end repeat",
    "    end repeat",
    "  end repeat",
    '  return ""',
    "end tell",
  ].join("\n");
}

/**
 * Run the split. Failure is never fatal — the pane already exists and works,
 * so the caller falls back to telling the user to `tmux attach`. The hard
 * timeout is there because a hung AppleScript must not hang the command.
 */
export function itermSplit(uuid, key, orientation) {
  let script;
  try {
    script = itermSplitScript(uuid, key, orientation);
  } catch (err) {
    return { ok: false, error: err.message };
  }
  const res = run("osascript", ["-e", script], { timeout: 5000 });
  if (res.status !== 0) return { ok: false, error: res.stderr || "osascript failed" };
  return { ok: true, childUuid: res.stdout || null };
}

// --------------------------------------------------------------- pane keys

/** `ah-<first 8 of the orchestrator session id>-<agent slug>-<n>`, and the tmux session name. */
export function makeKey(orchestratorSessionId, agent, existingKeys) {
  const orch = String(orchestratorSessionId || "nosess")
    .replace(/[^a-z0-9]/gi, "")
    .toLowerCase()
    .slice(0, 8)
    .padEnd(8, "0");
  const slug = String(agent)
    .replace(/[:/]/g, "-")
    .replace(/[^a-z0-9-]/gi, "")
    .toLowerCase()
    .slice(0, 30);
  for (let n = 1; n < 1000; n++) {
    const key = `ah-${orch}-${slug}-${n}`;
    if (KEY_RE.test(key) && !existingKeys.has(key)) return key;
  }
  return null;
}
