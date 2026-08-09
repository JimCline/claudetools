#!/usr/bin/env node
/**
 * agent-hierarchy — durable-agent (/pane) primitives.
 *
 * A durable agent is a real, interactive, top-level Claude Code session
 * launched with `claude --agent <name>` inside its own detached tmux session
 * ("pane"), which the user can watch and type into. The Orchestrator delegates
 * to it and gets one reply back per solicited turn, and its context persists
 * across sends — and across Orchestrator sessions.
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
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

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
 *
 * INVARIANT (§14.1a): returns false ONLY when a definition positively
 * demonstrates that both Bash and Edit are unavailable. Every other input —
 * empty frontmatter, no `tools` and no `disallowedTools`, an unparseable file,
 * a built-in with no file at all — returns true, so the permission question is
 * always asked when execution cannot be ruled out. The final expression reads
 * like a redundancy and is not: with an empty deny list,
 * `!denies("Bash") || !denies("Edit")` is true, and "simplifying" it to
 * `deny.includes("Bash") || deny.includes("Edit")` would invert it and
 * silently remove the prompt for every unrestricted agent. Test 25 pins all
 * four branches. Divergent definition pairs (§6.3a) resolve by OR at the call
 * site: canExecute(recorded) || canExecute(live).
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
    const at = id.indexOf("@");
    if ((at === -1 ? id : id.slice(0, at)) !== pluginId) continue;
    const marketplace = at === -1 ? null : id.slice(at + 1);
    for (const rec of Array.isArray(list) ? list : []) records.push({ ...rec, marketplace });
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
  return { installPath: chosen.installPath, version: chosen.version, marketplace: chosen.marketplace };
}

/**
 * The live-checkout root for a plugin whose marketplace is directory-sourced
 * (§6.3a). Under such a marketplace the checkout IS the source tree — exactly
 * one copy per plugin, no version directories, nothing to choose between — so
 * computing this does not weaken the never-glob-the-cache rule: every path is
 * built from named manifest fields, none is discovered by readdir.
 *
 * Returns { root, warnings }: `root` is the plugin's directory inside the
 * checkout, or null when the marketplace is not local-path or the candidate
 * had to be abandoned. Abandonment is always LOUD (a warning), never silent —
 * the `source` field was verified as a relative-path string for only two
 * plugins in one manifest, so an unrecognised shape must degrade visibly, not
 * quietly, to single-source behaviour.
 */
function resolveLiveCandidate(pluginId, marketplace) {
  const none = { root: null, warnings: [] };
  if (!marketplace) return none;
  let known;
  try {
    known = JSON.parse(readFileSync(join(homedir(), ".claude", "plugins", "known_marketplaces.json"), "utf8"));
  } catch {
    return none;
  }
  const entry = known && typeof known === "object" ? known[marketplace] : null;
  const src = entry && entry.source;
  if (!src || src.source !== "directory" || typeof src.path !== "string" || !src.path) return none;

  const warnings = [];
  const root = (typeof entry.installLocation === "string" && entry.installLocation) || src.path;
  let rootIsDir = false;
  try {
    rootIsDir = statSync(root).isDirectory();
  } catch {
    /* not on disk — handled below */
  }
  if (!rootIsDir) {
    warnings.push(`marketplace \`${marketplace}\` is directory-sourced but its checkout ${root} is not on disk; policy comes from the installed copy only.`);
    return { root: null, warnings };
  }
  const manifestPath = join(root, ".claude-plugin", "marketplace.json");
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch {
    warnings.push(`marketplace \`${marketplace}\` is directory-sourced but ${manifestPath} could not be read; policy comes from the installed copy only.`);
    return { root: null, warnings };
  }
  const pluginEntry = (Array.isArray(manifest && manifest.plugins) ? manifest.plugins : []).find((p) => p && p.name === pluginId) || null;
  const rel = pluginEntry ? pluginEntry.source : undefined;
  if (typeof rel !== "string" || !rel) {
    warnings.push(
      `marketplace \`${marketplace}\` lists \`${pluginId}\` with a plugin source /pane does not recognise (expected a relative path string); policy comes from the installed copy only.`
    );
    return { root: null, warnings };
  }
  const pluginRoot = resolve(root, rel);
  const normRoot = resolve(root);
  if (pluginRoot !== normRoot && !pluginRoot.startsWith(normRoot + sep)) {
    warnings.push(`marketplace \`${marketplace}\` resolves \`${pluginId}\` to ${pluginRoot}, outside its own checkout; policy comes from the installed copy only.`);
    return { root: null, warnings };
  }
  return { root: pluginRoot, warnings };
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
    // Scopes 1 and 2 have exactly one copy of a file by construction; §6.3a
    // never applies to them.
    return {
      ok: true,
      source: scope.source,
      definitionPath: hits[0].path,
      definitionPathLive: null,
      definitionSource: "recorded",
      installPath: null,
      marketplace: null,
      frontmatter: hits[0].frontmatter,
      frontmatters: [hits[0].frontmatter],
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
  const agentRelPath = `${rest.split(":").join("/")}.md`;
  const definitionPath = join(agentsDir, agentRelPath);

  // §6.3a: under a directory-sourced marketplace, Claude Code may launch the
  // pane from the live checkout while installed_plugins.json points at the
  // cache. Read BOTH copies, prefer neither, and let the caller take the safe
  // union of every definition-derived policy. Which copy the harness actually
  // reads (E12) is deliberately not an input here.
  const live = resolveLiveCandidate(pluginId, found.marketplace);
  warnings.push(...live.warnings);
  const definitionPathLive = live.root ? join(live.root, "agents", agentRelPath) : null;

  const recordedExists = existsSync(definitionPath);
  const liveExists = Boolean(definitionPathLive && existsSync(definitionPathLive));

  if (!recordedExists && !liveExists) {
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

  const readCopy = (path) => {
    // An unreadable copy is frontmatter {}, never an error: §14.1a's fail-safe
    // turns that into canExecute === true, so a parse quirk over-prompts
    // instead of silently granting.
    try {
      const buf = readFileSync(path);
      return { buf, frontmatter: parseFrontmatter(buf.toString("utf8")) };
    } catch {
      warnings.push(`could not read frontmatter from ${path}`);
      return { buf: null, frontmatter: {} };
    }
  };
  const recorded = recordedExists ? readCopy(definitionPath) : null;
  const liveCopy = liveExists ? readCopy(definitionPathLive) : null;

  let definitionSource;
  if (!definitionPathLive) {
    definitionSource = "recorded";
  } else if (recordedExists && liveExists) {
    // Byte comparison, and only bytes: mtime must never pick a winner —
    // installation copies files, so the STALE cache copy carries the LATER
    // mtime on this machine.
    const identical = recorded.buf && liveCopy.buf && recorded.buf.equals(liveCopy.buf);
    definitionSource = identical ? "identical" : "divergent";
  } else if (recordedExists) {
    definitionSource = "recorded-only";
    warnings.push(`the live checkout has no copy of this agent (${definitionPathLive} does not exist); using the installed copy.`);
  } else {
    definitionSource = "live-only";
    warnings.push(`the installed copy ${definitionPath} does not exist; using the live checkout copy at ${definitionPathLive}.`);
  }

  const frontmatters = [];
  if (recorded) frontmatters.push(recorded.frontmatter);
  if (liveCopy && definitionSource !== "identical") frontmatters.push(liveCopy.frontmatter);

  return {
    ok: true,
    source: "plugin",
    definitionPath,
    definitionPathLive,
    definitionSource,
    installPath: found.installPath,
    marketplace: found.marketplace || null,
    frontmatter: recorded ? recorded.frontmatter : liveCopy.frontmatter,
    frontmatters,
    warnings,
  };
}

function listMdFiles(root) {
  const out = [];
  const walk = (dir, prefix) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(join(dir, entry.name), rel);
      else if (entry.isFile() && entry.name.endsWith(".md")) out.push(rel);
    }
  };
  walk(root, "");
  return out.sort();
}

/**
 * `doctor`'s §6.3a check: for every installed plugin whose marketplace is
 * directory-sourced, compare the installed `agents/` tree against the live
 * checkout's, byte for byte. A stale cache should be noticed here, at doctor
 * time — not at `open` time with a user waiting. `agents/` only: hook or
 * command drift is the platform's business, not /pane's.
 */
export function agentsTreeDivergence() {
  const manifest = join(homedir(), ".claude", "plugins", "installed_plugins.json");
  let data;
  try {
    data = JSON.parse(readFileSync(manifest, "utf8"));
  } catch {
    return [];
  }
  const reports = [];
  for (const [id, list] of Object.entries((data && data.plugins) || {})) {
    const at = id.indexOf("@");
    if (at === -1) continue;
    const pluginId = id.slice(0, at);
    const marketplace = id.slice(at + 1);
    const rec = (Array.isArray(list) ? list : []).find((r) => r && r.installPath && existsSync(r.installPath));
    if (!rec) continue;
    const live = resolveLiveCandidate(pluginId, marketplace);
    if (!live.root) continue;
    const installedAgents = join(rec.installPath, "agents");
    const liveAgents = join(live.root, "agents");
    if (!existsSync(installedAgents) && !existsSync(liveAgents)) continue;
    const installed = listMdFiles(installedAgents);
    const inCheckout = listMdFiles(liveAgents);
    const differ = [];
    const onlyInstalled = [];
    const onlyLive = [];
    for (const rel of new Set([...installed, ...inCheckout])) {
      const here = installed.includes(rel);
      const there = inCheckout.includes(rel);
      if (here && there) {
        try {
          if (!readFileSync(join(installedAgents, rel)).equals(readFileSync(join(liveAgents, rel)))) differ.push(rel);
        } catch {
          differ.push(rel);
        }
      } else if (here) onlyInstalled.push(rel);
      else onlyLive.push(rel);
    }
    reports.push({
      pluginId,
      marketplace,
      installPath: rec.installPath,
      liveRoot: live.root,
      checked: installed.length + onlyLive.length,
      differ,
      onlyInstalled,
      onlyLive,
      identical: !differ.length && !onlyInstalled.length && !onlyLive.length,
    });
  }
  return reports;
}

/** The hierarchy role an agent name denotes, anchored `(^|:)role$`, or null. */
export function roleOfAgent(name) {
  if (typeof name !== "string" || !name) return null;
  return HIERARCHY_ROLES.find((role) => name === role || name.endsWith(`:${role}`)) || null;
}

// ------------------------------------------------------------- panes config

export const PANE_DEFAULTS = {
  // The Bash tool kills commands at 120s by default, and a killed send prints
  // none of its guidance. Worst case is bootWait (30s) + this poll window, so
  // the pair must stay under 120 — a longer --timeout needs a longer Bash
  // timeout passed alongside it.
  timeoutSeconds: 80,
  pollSeconds: 2,
  inlinePromptMaxChars: 2000,
  replyInlineMaxChars: 4000,
  iterm2: true,
  allowBuiltins: false,
  permissionMode: null,
  onDefinitionDivergence: "warn",
  size: { x: 200, y: 50 },
};

/**
 * §6.3a deliberately offers no "ignore": silently preferring one copy is the
 * rejected option, and a config value must not reintroduce it.
 */
export const DIVERGENCE_MODES = ["warn", "refuse"];

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
    if (k === "onDefinitionDivergence" && !DIVERGENCE_MODES.includes(v)) {
      out.warnings.push(`ignoring panes.onDefinitionDivergence "${v}" — it is "warn" or "refuse" (there is deliberately no "ignore").`);
      continue;
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

function foldLast(path) {
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
  return last;
}

/**
 * Current state is a FOLD over the append-only log: a key is live iff its most
 * recent event is `open`. Never read-modify-write this file — measured on this
 * plugin's sibling state, that dropped roughly 4 of 12 concurrent writes.
 */
export function foldRegistry(path = REGISTRY_PATH) {
  const live = new Map();
  for (const [key, rec] of foldLast(path)) {
    if (rec.ev !== "open") continue;
    // Records predating the §6.3a fields stay valid: absent means the single
    // recorded copy, never a rewrite of the log.
    if (rec.definition_source === undefined) rec.definition_source = "recorded";
    if (rec.definition_path_live === undefined) rec.definition_path_live = null;
    live.set(key, rec);
  }
  return live;
}

/**
 * Keys whose most recent event is `launching`: a create crashed (or is
 * mid-flight) between the tmux launch and its `open` event. Never live; doctor
 * reports them and reaps the ones with no tmux session behind them.
 */
export function launchingKeys(path = REGISTRY_PATH) {
  return [...foldLast(path).values()].filter((rec) => rec.ev === "launching");
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
 * does no I/O, so a broken mailbox cannot cost the session its protocol — the
 * caller reads the `pending` token and passes it in.
 *
 * `pending` carries the OUTSTANDING request, and re-stating its id here is what
 * makes the reply contract survive compaction: the id is an opaque token with
 * no semantic content, so a summary drops it, and gate E then rejects a
 * perfectly good final message. Every session start re-supplies it from disk
 * rather than trusting context to have carried it.
 *
 * This text owns the top slot of the pane's injected context.
 */
export function buildPaneProtocol({ role, declaredRole, key, pending }) {
  const identity = role || declaredRole || "an agent-hierarchy role";
  const lines = [
    `agent-hierarchy DURABLE AGENT. You are running as \`${identity}\`, a durable agent in a terminal pane${key ? ` (\`${key}\`)` : ""}. You are NOT the Orchestrator: do not decompose-and-dispatch, do the role's own work.`,
    "",
    "1. One channel, inbound only. You answer the turn you were given. You cannot initiate contact with the Orchestrator — there is no tool and no address for it. Your final assistant message IS your reply, and it is captured automatically.",
    "2. The reply is the whole payload — and it must be LEAN. Only your final assistant message is relayed; thinking, tool output, and intermediate turns are discarded. Final results only, never progress narration: the Orchestrator is budgeting tokens, and every character of your reply lands in its context.",
    "3. Echo the request id. A delivered task opens with `[ah-request <id>]`. Your final message for that task MUST begin with the exact line `[ah-reply <id>]` — the relay refuses to deliver a final message without it, and your work would sit unread in the pane. You are never required to REMEMBER the id: if you are not certain of it — your context was compacted, or the request scrolled out of view — read it from `$AGENT_HIERARCHY_PANE_DIR/pending` (JSON, field `reqid`). Never invent or approximate it.",
    "4. Artifacts and bulk go to disk. If you produce a spec file, a diff, a report, or anything long, write it to disk (when you have a write tool) and put the ABSOLUTE PATH in your final message. Do not paste the artifact into the reply.",
    "5. Structure any long reply for grepping. When a reply must run long, open it (after the `[ah-reply]` line) with a `## TL;DR` section — one bullet per section, naming the `## ` headings that follow — so the Orchestrator can pull single sections off disk instead of loading everything.",
    "6. A human may type into this pane directly. That input is the user's own instruction and you should treat it as such. A turn the Orchestrator did not solicit is not relayed anywhere — that conversation is between you and the human only.",
    "7. No nesting. Do not create durable agents, and do not run `/agent-hierarchy:durable`. You DO have the Agent tool and ordinary subagent dispatch remains correct for your role; durable agents specifically are what you may not create.",
    "8. Your role contract still applies. Your `agents/*.md` body governs, and nothing here relaxes it.",
  ];
  if (role && declaredRole && role !== declaredRole) {
    lines.push(
      "",
      `(Note: this pane was opened for \`${declaredRole}\`, but the session reports \`${role}\`. An environment variable reached a session it was not meant for — tell the user.)`
    );
  }
  const reqid = pending && typeof pending.reqid === "string" && pending.reqid ? pending.reqid : null;
  if (reqid) {
    const when = pending.sent_at && typeof pending.sent_at === "string" ? ` (delivered ${pending.sent_at})` : "";
    lines.push(
      "",
      `CURRENT REQUEST: \`${reqid}\`${when}. Your final message for this task MUST begin with this exact line, as the very first line, with nothing before it:`,
      "",
      `[ah-reply ${reqid}]`,
      "",
      "This block is re-supplied from disk at every session start, so a compaction cannot cost you the id. Do not paraphrase, abbreviate, or invent it."
    );
  }
  return lines.join("\n");
}

/**
 * The delivery envelope. Stamped by `send` in tested code — never hand-written
 * by the Orchestrator — so every delivery carries the same reply contract the
 * relay's gate E enforces: echo the reqid, final results only, TL;DR + `## `
 * sections when long. Kept to a few lines because the pane pays input tokens
 * for it on every request.
 */
export function wrapPrompt(reqid, text) {
  return (
    `[ah-request ${reqid}] Reply contract: begin your FINAL message with the exact line "[ah-reply ${reqid}]" — it is not relayed without it. ` +
    `Final results only, lean: bulk goes to disk with absolute paths in the reply, and a long reply opens with a "## TL;DR" section followed by "## " sections.\n\n` +
    text
  );
}

/** The `## TL;DR` section of a reply body, heading included, or null. */
export function extractTldr(text) {
  const lines = String(text).split("\n");
  const start = lines.findIndex((l) => /^##\s*TL;DR/i.test(l));
  if (start === -1) return null;
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((l) => /^##\s/.test(l));
  return lines
    .slice(start, start + 1 + (end === -1 ? rest.length : end))
    .join("\n")
    .trimEnd();
}

/**
 * Reply files that have landed but never been presented, newest first. The
 * `.presented` marker (written by pane.mjs on every pickup path) is what
 * "unread" means everywhere: list, the roster, and the nudge hook all call
 * this instead of counting reply files.
 */
export function unreadReplies(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^reply\..*\.json$/.test(f))
    .filter((f) => !existsSync(join(dir, f.replace(/\.json$/, ".presented"))))
    .map((f) => ({
      file: f,
      reqid: f.replace(/^reply\./, "").replace(/\.json$/, ""),
      mtime: statSync(join(dir, f)).mtimeMs,
    }))
    .sort((a, b) => b.mtime - a.mtime);
}

/**
 * Finished work that never reached the Orchestrator, newest first.
 *
 * Two kinds, deliberately surfaced identically because the Orchestrator's move
 * is the same for both — read it and decide whether it answers the question:
 *   `unmatched.<ts>.json`  the echo gate rejected the turn and gave up
 *   `nag.<reqid>.json`     the echo gate asked for a retry that never came
 *
 * The nag kind is what keeps the retry mechanism honest: if a Stop `block` is
 * not honoured in an interactive session, the nag file is still here and still
 * reported, so the work surfaces either way.
 */
export function strandedTurns(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^unmatched\..*\.json$/.test(f) || /^nag\..*\.json$/.test(f))
    .map((f) => {
      const nag = f.startsWith("nag.");
      let reqid = nag ? f.replace(/^nag\./, "").replace(/\.json$/, "") : null;
      if (!nag) {
        try {
          reqid = JSON.parse(readFileSync(join(dir, f), "utf8")).reqid_expected ?? null;
        } catch {
          reqid = null;
        }
      }
      return { file: f, kind: nag ? "nag" : "unmatched", reqid, mtime: statSync(join(dir, f)).mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime);
}

/** Every `## ` heading line of a reply body, in order — the grep targets. */
export function sectionHeadings(text) {
  return String(text)
    .split("\n")
    .filter((l) => /^##\s/.test(l))
    .map((l) => l.trim());
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

/** Whether a tmux session with this key exists at all, the pane check aside. */
export function tmuxSessionExists(key) {
  if (!KEY_RE.test(key || "")) return false;
  return run("tmux", ["has-session", "-t", key]).status === 0;
}

/**
 * Fold, then verify each live key against tmux; append a `dead` close for any
 * that fails. Every read path that answers "what is running?" — list, send,
 * close, the SessionStart roster, the PreToolUse offer — goes through this, so
 * cleanup converges at exactly the moments the answer matters and no polling
 * daemon is needed.
 */
export function verifyAndReapLive() {
  const live = new Map();
  for (const [key, rec] of foldRegistry()) {
    if (isPaneLive(rec)) live.set(key, rec);
    else appendRegistry({ ev: "close", key, at: new Date().toISOString(), reason: "dead" });
  }
  return live;
}

/**
 * The durable-agent roster appended to an Orchestrator's SessionStart
 * directive. Null when the registry is absent or holds no live keys, so the
 * common case costs one existsSync and injects nothing.
 */
export function durableRoster() {
  if (!existsSync(REGISTRY_PATH)) return null;
  const live = verifyAndReapLive();
  if (!live.size) return null;
  const cli = join(dirname(fileURLToPath(import.meta.url)), "pane.mjs");
  const lines = [`Durable agents live right now (query anytime: node "${cli}" list):`];
  for (const rec of live.values()) {
    const dir = rec.dir || mailboxDir(rec.key);
    const pending = readJsonFile(join(dir, "pending"));
    const unread = unreadReplies(dir).length;
    lines.push(
      `- ${rec.key} — ${rec.agent} (${rec.model || "inherited model"}) — ${pending ? `WORKING on ${pending.reqid} since ${pending.sent_at}` : "idle"}${unread ? ` — ${unread} UNREAD reply waiting (pick it up: node "${cli}" wait --key ${rec.key})` : ""} — created ${rec.created_at || "unknown"} by session ${rec.orchestrator_session_id || "unknown"}`
    );
  }
  lines.push(
    "A durable agent is a live interactive session that keeps its context between sends, so related follow-up work is cheaper there than in a fresh subagent of the same role. Prefer it for follow-ups it has context for; prefer a subagent for independent work or a clean context.",
    `Send work through the /agent-hierarchy:durable ask flow — every send needs the user's approval first: node "${cli}" send --key <key> --summary "<one line>"  (prompt on stdin via heredoc).`
  );
  return lines.join("\n");
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
 * The process-group id of a RECORDED pid. This is a lookup on a pid the
 * registry captured at creation, never a scan for a target — the distinction
 * §13.4 rule 1 turns on.
 */
export function readPgid(pid) {
  const res = run("ps", ["-o", "pgid=", "-p", String(pid)]);
  if (res.status !== 0) return null;
  const n = parseInt(res.stdout.trim(), 10);
  return Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * Kill a pane's tmux session and then reap its process — as a process GROUP
 * when that is provably safe, as a single pid otherwise.
 *
 * `tmux kill-session` has been observed NOT to take the Claude Code process
 * with it, leaving a billed session running, so the recorded pid is signalled
 * afterwards. E5 measured that the pane's `claude` leads its own process
 * group, whose only other members are its ~6 MCP-server children — so the
 * group kill is exactly as wide as the pane, and it is what stops an MCP
 * server from outliving its parent while holding a port or GPU memory.
 *
 * The `pgid === pane_pid` guard is mandatory, not padding: `kill(-N)` names
 * "the group whose LEADER is N", so if the pane process were not the leader,
 * `-pane_pid` would address some other group entirely — under pid reuse, an
 * unrelated tree. The pgid is confirmed by `ps` on every close, never cached,
 * and the group kill is refused when the group is pane.mjs's own (that group
 * contains this very process). Every guard failure falls back to the
 * previously-shipped single-pid kill.
 *
 * Kill safety rails, all mandatory: only a pid the registry recorded at
 * creation is ever signalled (never one derived from a live scan), never our
 * own pid or parent, never a negative target without the same-invocation pgid
 * confirmation, and never a session whose name does not look like ours.
 *
 * `deps` exists so the tests can pin the guard logic without signalling real
 * processes; production callers pass nothing.
 */
export function killPane(record, deps = {}) {
  const getPgid = deps.readPgid || readPgid;
  const signal = deps.kill || ((target, sig) => process.kill(target, sig));
  const alive = deps.pidAlive || pidAlive;
  const wait = deps.sleep || sleepSync;
  const selfPid = deps.selfPid ?? process.pid;
  const selfPpid = deps.selfPpid ?? process.ppid;

  const notes = [];
  if (!record || !KEY_RE.test(record.key || "")) return { ok: false, error: "refusing to kill: key does not match ^ah-" };
  if (!/^ah-/.test(record.tmux_session || "")) return { ok: false, error: "refusing to kill: tmux_session does not match ^ah-" };

  run("tmux", ["kill-session", "-t", record.key]);

  const pid = record.pane_pid;
  if (!Number.isInteger(pid) || pid <= 0) {
    notes.push(`no pane_pid was recorded for ${record.key}; not guessing. If a \`claude\` process survives, find it with: ps -ax | grep 'claude --agent'`);
    return { ok: true, notes };
  }
  if (pid === selfPid || pid === selfPpid) {
    return { ok: false, error: `refusing to kill pid ${pid}: it is this process or its parent` };
  }
  if (!alive(pid)) return { ok: true, notes };

  const pgid = getPgid(pid);
  const ownPgid = deps.ownPgid !== undefined ? deps.ownPgid : getPgid(selfPid);
  let target = pid;
  if (!Number.isInteger(pgid) || pgid !== pid) {
    notes.push(`could not confirm ${pid} leads its own process group (pgid ${pgid ?? "unreadable"}); killed the single pid — MCP-server children may survive.`);
  } else if (!Number.isInteger(ownPgid)) {
    notes.push(`could not read this process's own group; killed the single pid — MCP-server children may survive.`);
  } else if (pgid === ownPgid) {
    notes.push(`refusing the group kill: ${pid}'s process group is this process's own. Killed the single pid — MCP-server children may survive.`);
  } else {
    target = -pid;
  }

  try {
    signal(target, "SIGTERM");
  } catch {
    return { ok: true, notes };
  }
  for (let waited = 0; waited < 3000 && alive(pid); waited += 250) wait(250);
  if (alive(pid)) {
    try {
      signal(target, "SIGKILL");
      notes.push(`pane process ${pid} ignored SIGTERM and was killed.`);
    } catch {
      notes.push(`pane process ${pid} could not be killed; kill it by hand.`);
    }
  }
  return { ok: true, notes };
}

/**
 * The recorded pane_pids of panes whose most recent registry event is a close.
 * Doctor uses these to name any group member that outlived its pane (§13.3).
 */
export function closedPaneGroupPids(path = REGISTRY_PATH) {
  const lastEv = new Map();
  const lastOpen = new Map();
  for (const line of readRegistryLines(path)) {
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (!rec || typeof rec.key !== "string") continue;
    lastEv.set(rec.key, rec.ev);
    if (rec.ev === "open") lastOpen.set(rec.key, rec);
  }
  const out = [];
  for (const [key, ev] of lastEv) {
    if (ev === "open") continue;
    const open = lastOpen.get(key);
    if (open && Number.isInteger(open.pane_pid) && open.pane_pid > 0) out.push({ key, pane_pid: open.pane_pid });
  }
  return out;
}

/**
 * Processes whose parent is gone (reparented to pid 1) and whose pgid matches
 * one of the given recorded pane pids. REPORT ONLY — doctor names these, it
 * never signals them; the one `ps` table read exists to describe survivors,
 * never to pick a kill target.
 */
export function survivingGroupProcesses(pgids) {
  const wanted = new Set((pgids || []).map(Number).filter((n) => Number.isInteger(n) && n > 0));
  if (!wanted.size) return [];
  const res = run("ps", ["-axo", "pid=,ppid=,pgid=,comm="]);
  if (res.status !== 0) return [];
  const out = [];
  for (const line of res.stdout.split("\n")) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const pid = parseInt(m[1], 10);
    const ppid = parseInt(m[2], 10);
    const pgid = parseInt(m[3], 10);
    if (wanted.has(pgid) && ppid === 1) out.push({ pid, pgid, comm: m[4].trim() });
  }
  return out;
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
  // E6: a successful split RETURNS the child session id. An empty result means
  // the UUID walk matched nothing and no split happened, which is a failure to
  // report, not a success with an unknown child.
  if (!res.stdout) return { ok: false, error: "no iTerm2 session matched this session's UUID" };
  return { ok: true, childUuid: res.stdout };
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
