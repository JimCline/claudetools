/**
 * task-gopher — can a dispatch target act on the directive at all?
 *
 * The relay prepends ~1,500 tokens of "delegate your legwork" to every dispatch
 * prompt. An agent whose `tools:` allow-list has no Agent/Task entry cannot
 * dispatch, so those tokens buy nothing: it reads the directive's own escape
 * clause and correctly does nothing with it. The gate is handed the target's
 * NAME, not its capabilities, so answering this means finding the agent's
 * definition on disk and reading its frontmatter.
 *
 * Three rules keep that safe, and every branch below exists to honor one:
 *
 * 1. Only an ALLOW-list is decisive. No `tools:` key means the agent inherits
 *    every tool and CAN dispatch. `disallowedTools` is a deny-list and is never
 *    evidence of absence — agent-hierarchy's architect, reviewer and
 *    ultra-advisor all use it while keeping Agent.
 * 2. Fail toward stamping. Unresolvable name, missing file, absent frontmatter,
 *    or two installed copies that disagree -> stamp. A broken lookup must never
 *    silently disable the relay for an agent that needs it.
 * 3. Stay off the hot path. This runs only in the gate's Agent/Task branch,
 *    never for a Read/Grep/Glob, and memoizes what it resolves.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const DISPATCH_TOOLS = new Set(["Agent", "Task"]);

// A dispatch name is model-supplied and becomes a path segment here, so hold it
// to the shape real agent names actually take.
const SAFE_NAME = /^[A-Za-z0-9._-]+$/;

const memo = new Map();

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** The YAML frontmatter block of an agent definition, or null if it has none. */
function frontmatter(text) {
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/.exec(body);
  return m ? m[1] : null;
}

/**
 * One frontmatter key's value, following YAML block scalars (`tools: >-`) and
 * block sequences (`- Read`) onto the indented lines beneath. Both styles are in
 * live use: agent-hierarchy writes the inline form, github-pr-toolkit the folded
 * one. Returns null when the key is absent or carries nothing.
 */
export function frontmatterValue(fm, key) {
  const lines = fm.split(/\r?\n/);
  const head = new RegExp(`^${key}[ \\t]*:(.*)$`);
  for (let i = 0; i < lines.length; i++) {
    const m = head.exec(lines[i]);
    if (!m) continue;
    const inline = m[1].trim();
    if (inline && !/^[>|][-+]?$/.test(inline)) return inline;
    const parts = [];
    for (let j = i + 1; j < lines.length; j++) {
      if (!lines[j].trim()) continue;
      if (!/^[ \t]/.test(lines[j])) break; // dedent -> this is the next key
      parts.push(lines[j].trim().replace(/^-[ \t]*/, ""));
    }
    return parts.join(", ") || null;
  }
  return null;
}

/** Does this `tools:` value leave the agent a way to dispatch? An absent list grants everything. */
export function grantsDispatch(raw) {
  if (raw == null) return true;
  const tools = raw
    .trim()
    .replace(/^\[/, "")
    .replace(/\]$/, "")
    .split(",")
    .map((t) => t.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean);
  if (!tools.length) return true; // `tools:` with nothing after it is not decisive
  if (tools.includes("*")) return true;
  return tools.some((t) => DISPATCH_TOOLS.has(t));
}

/**
 * Where a plugin's files live. `installed_plugins.json` is the authority: it
 * pins the exact installed version, which a glob over the cache cannot do —
 * several versions of one plugin sit there side by side. Marketplaces served
 * from a local checkout are probed too, since those are edited in place and the
 * versioned cache copy can lag behind them.
 */
function pluginRoots(plugin) {
  const dir = join(homedir(), ".claude", "plugins");
  const roots = [];

  const installed = (readJson(join(dir, "installed_plugins.json")) || {}).plugins || {};
  for (const key of Object.keys(installed)) {
    // keys are `<plugin>@<marketplace>`; a dispatch carries only the plugin half
    if (key.split("@")[0] !== plugin) continue;
    for (const entry of installed[key] || []) {
      if (entry && typeof entry.installPath === "string") roots.push(entry.installPath);
    }
  }

  const marketplaces = readJson(join(dir, "known_marketplaces.json")) || {};
  for (const key of Object.keys(marketplaces)) {
    const loc = marketplaces[key] && marketplaces[key].installLocation;
    if (typeof loc === "string") roots.push(join(loc, plugin));
  }

  return roots;
}

/** Every path this `subagent_type`'s definition could occupy. */
function candidatePaths(subagentType, cwd) {
  const parts = subagentType.split(":");
  if (parts.length > 2) return []; // not a shape we resolve -> caller stamps
  const plugin = parts.length === 2 ? parts[0] : null;
  const name = parts[parts.length - 1];
  if (!SAFE_NAME.test(name)) return [];

  if (plugin === null) {
    const paths = [];
    if (typeof cwd === "string" && cwd) paths.push(join(cwd, ".claude", "agents", `${name}.md`));
    paths.push(join(homedir(), ".claude", "agents", `${name}.md`));
    return paths;
  }
  if (!SAFE_NAME.test(plugin)) return [];
  return pluginRoots(plugin).map((root) => join(root, "agents", `${name}.md`));
}

/**
 * True only when every definition found for this target agrees it has no way to
 * dispatch. Finding nothing, or finding copies that disagree, means we do not
 * know — and not knowing means stamping (rule 2).
 */
export function cannotDispatch(subagentType, cwd) {
  if (typeof subagentType !== "string" || !subagentType) return false;

  const key = `${subagentType} ${typeof cwd === "string" ? cwd : ""}`;
  if (memo.has(key)) return memo.get(key);

  let verdict = false;
  try {
    const found = candidatePaths(subagentType, cwd).filter((p) => existsSync(p));
    verdict =
      found.length > 0 &&
      found.every((p) => {
        const fm = frontmatter(readFileSync(p, "utf8"));
        return fm !== null && !grantsDispatch(frontmatterValue(fm, "tools"));
      });
  } catch {
    verdict = false;
  }

  memo.set(key, verdict);
  return verdict;
}
