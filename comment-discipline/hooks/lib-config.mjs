/**
 * comment-discipline — shared config resolution and directive text.
 *
 * Config lives at `.claude/comment-discipline.json` in one of two scopes:
 *   - user    — ~/.claude/comment-discipline.json          (every project)
 *   - project — <cwd>/.claude/comment-discipline.json      (this repo only)
 *
 * Both may exist. The project layer wins, key by key, so a repo can opt out of
 * a user-level install (or opt in on its own) without editing the other scope.
 * `enabled` is a field in that JSON, not a separate marker file — one source of
 * truth per scope, so `status` can never disagree with what the hook does.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const CONFIG_VERSION = 1;
export const CONFIG_BASENAME = "comment-discipline.json";

/**
 * Records which subagents have already been handed the directive, so the
 * PostToolUse backstop injects it once per agent instead of after every edit.
 * Keyed by `session_id|agent_id`; lives outside the plugin cache so it survives
 * plugin upgrades.
 */
export const SEEN_FILE = join(homedir(), ".claude", "comment-discipline.seen");

/** Agents tracked in SEEN_FILE before the oldest entries are pruned. */
export const SEEN_MAX_KEYS = 64;

/**
 * Agent types that cannot author code, so spending the directive on them is
 * pure waste. Built-in `Explore`/`Plan` have no `Edit`/`Write`, and a
 * task-gopher runner is a retrieval worker. Plugin agents arrive namespaced
 * (`plugin:agent`), so both forms are listed — `agent_type` is matched exactly,
 * not by substring, to avoid catching a custom agent whose name merely contains
 * one of these.
 *
 * This is an optimization, not a safety gate: over-delivery is harmless because
 * the directive's own guards tell an agent that authors nothing to do nothing.
 * Custom read-only agents can't be enumerated and will receive it.
 */
export const NON_AUTHORING_AGENTS = new Set([
  "Explore",
  "Plan",
  "output-style-setup",
  "task-gopher",
  "task-gopher:task-gopher",
]);

export function userConfigPath() {
  return join(homedir(), ".claude", CONFIG_BASENAME);
}

export function projectConfigPath(cwd) {
  if (typeof cwd !== "string" || !cwd) return null;
  return join(resolve(cwd), ".claude", CONFIG_BASENAME);
}

/** Read the hook's stdin JSON payload; returns {} if absent or unparseable. */
export async function readHookInput() {
  try {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString("utf8").trim();
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

/** Load one scope. Returns null when absent; a warning entry when unreadable. */
function readLayer(path, scope, warnings) {
  if (!path || !existsSync(path)) return null;
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    if (data === null || typeof data !== "object" || Array.isArray(data)) {
      warnings.push(`comment-discipline: ${scope}-scope config at ${path} is not a JSON object — ignoring it.`);
      return null;
    }
    return { scope, path, data };
  } catch {
    warnings.push(`comment-discipline: ${scope}-scope config at ${path} is not valid JSON — ignoring it.`);
    return null;
  }
}

/**
 * Resolve both scopes into a single verdict.
 * `configured` is false when neither scope has a usable config — that is the
 * only state that earns a setup nudge. `enabled:false` is a deliberate opt-out
 * and stays silent.
 */
export function resolveConfig(cwd) {
  const warnings = [];
  const user = readLayer(userConfigPath(), "user", warnings);
  const project = readLayer(projectConfigPath(cwd), "project", warnings);
  const layers = [user, project].filter(Boolean);

  if (layers.length === 0) {
    return { configured: false, enabled: false, sources: [], warnings };
  }

  // Later layers win; project is applied last so it overrides user.
  let enabled = true;
  for (const layer of layers) {
    if (typeof layer.data.enabled === "boolean") enabled = layer.data.enabled;
  }

  return {
    configured: true,
    enabled,
    sources: layers.map((l) => ({ scope: l.scope, path: l.path })),
    warnings,
  };
}

/** Write `{version, enabled}` to one scope, creating `.claude/` if needed. */
export function writeConfig(path, enabled) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify({ version: CONFIG_VERSION, enabled }, null, 2)}\n`, "utf8");
  return path;
}

/**
 * The authoring directive — the inverse of the code-critic review lens.
 *
 * The hard part is that a REVIEW lens can be purely subtractive ("never flag the
 * absence of a comment"), while an AUTHORING directive cannot: the model is
 * deciding whether to write a comment at all. Without the two guards at the
 * bottom this backfires into defensive doc-comments written to demonstrate
 * compliance, which is a worse outcome than the ephemeral comments it replaces.
 */
export const DIRECTIVE = [
  "Comment discipline ACTIVE. When you write or edit code, do not leave comments that only make sense while your diff is on screen.",
  "",
  "A comment's audience is the NEXT PERSON TO READ THE CODE, not whoever reviews this change. Git history already records what changed — the code does not need to narrate its own edit. A comment that only parses next to the diff is dead weight the moment it merges, and worse than dead later, because it describes a transition nobody can see.",
  "",
  "Do NOT write:",
  "- Change narration — `// changed from foo to bar`, `// now uses the new API`, `// removed the old implementation`, `// NEW: added validation`, `// updated to handle null`",
  "- Reviewer-directed asides — `// as suggested, kept this for backwards compat`, `// per review feedback`",
  "- Restatements of the line — `// increment counter` above `counter++`",
  "- Task narration — `// Step 1: validate input` over code that obviously validates input",
  "- Bare time markers — `// temporary`, `// for now`, `// will remove later`. The qualifier is the whole rule: `// TODO(#4127): remove once the v2 endpoint lands` is GOOD and must stay. Mark time only with an issue reference or a stated removal condition.",
  "",
  "DO write, freely:",
  "- The behavior or contract of a public API",
  "- WHY non-obvious code is the way it is — a workaround, an external constraint, a deliberate tradeoff, a spec or bug reference",
  "",
  "Two guards, both load-bearing:",
  "1. This NEVER asks you to document. It removes noise; it does not request prose. When in doubt, write NOTHING — a missing comment is not a defect under this directive, and adding defensive doc-comments to demonstrate compliance is itself the failure mode.",
  "2. This governs the comments YOU write or edit. Do not go clean up pre-existing comments you were not asked to touch — drive-by comment deletion produces noisy diffs and is out of scope. A stale comment on a line you are not otherwise changing stays.",
  "",
  "Subagents get this automatically — do NOT copy this block into their prompts by hand. A SubagentStart hook injects it as each subagent spawns, so writing it out yourself would spend your own output tokens duplicating what already happened.",
].join("\n");

export const NUDGE =
  "comment-discipline is installed but not configured — run `/comment-discipline init` to turn it on for every project or just this repo.";
