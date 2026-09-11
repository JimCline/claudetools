#!/usr/bin/env node
/**
 * agent-hierarchy — config resolution + injected directive text.
 *
 * Two config scopes, both plain JSON at `.claude/agent-hierarchy.json`:
 *   - user:    ~/.claude/agent-hierarchy.json          (all repos)
 *   - project: <cwd>/.claude/agent-hierarchy.json      (committable)
 *
 * Resolution rules (from the design spec):
 *   - Merge is SHALLOW per role: a role object present in the project config
 *     replaces the user-scope role object entirely — no key-level deep merge.
 *   - `enabled`: most-specific scope wins (project overrides user).
 *   - `inherit` is a legal CONFIG value meaning "omit the `model` parameter on
 *     the Agent call". It is never emitted as a literal model value.
 *   - Invalid model → fall back to the role default + a one-line warning.
 *   - Missing `version` → treat as 1. A version newer than this plugin
 *     understands → that scope is ignored (with a note); if nothing valid is
 *     left, the session is treated as unconfigured.
 *   - Peer-eligible roles: missing `dispatch` → "peer" (preserves pre-dispatch-field
 *     behavior for every config written before it existed). Missing `peer` when
 *     dispatch is "peer" → "auto" (the "<repo>-<role>" convention). Invalid
 *     values for either → fall back the same way, with a warning.
 *
 * Run directly (`node lib-config.mjs`) to print the resolved status table for
 * the current working directory — that is what `/hierarchy status` uses.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Cycle with lib-roster.mjs (which imports ROLES/VALID_MODELS_BY_ROLE from here): safe only
// because neither module touches the other's export at module top-level, only inside function
// bodies called later (statusReport here; validateMember/validateRosterBlock there). Keep it that
// way — a top-level use on either side would risk the top-level-await deadlock class documented
// in lib-roster.mjs's header.
import { listTeamNames, readTeam } from "./lib-roster.mjs";
import { normalizeSessionId } from "./lib-gate.mjs";
import { readSessionRole } from "./lib-session-role.mjs";

/** Absolute path to the escalation-gate CLI, resolved from this file so it survives wherever the plugin is installed. */
const GATE_CLI = join(dirname(fileURLToPath(import.meta.url)), "gate.mjs");
/** Absolute path to the message-file CLI, same resolution as GATE_CLI. */
export const MSG_CLI = join(dirname(fileURLToPath(import.meta.url)), "msg.mjs");
/** Absolute path to the roster CLI, same resolution as GATE_CLI/MSG_CLI. */
export const ROSTER_CLI = join(dirname(fileURLToPath(import.meta.url)), "roster.mjs");

let lastHookInput = null;

/** Where hook failures are recorded. Global, not per-repo: resolving a repo can itself be what threw. */
export const HOOK_ERROR_LOG = join(homedir(), ".claude", "hierarchy", "hook-errors.jsonl");
const HOOK_ERROR_CAP = 1024 * 1024;

/**
 * Append one line about a hook failure. Hooks decide nothing on this path and keep whatever
 * fail-open behaviour they had; without it a crashed hook and a hook that chose to stay silent look
 * identical, and Claude Code surfaces neither outside `--debug`.
 *
 * @param {string} hook basename of the entrypoint.
 * @param {unknown} err the thrown value.
 * @param {{session_id?: string, hook_event_name?: string}} [input] the parsed payload, when there is one.
 */
export function logHookError(hook, err, input = lastHookInput) {
  try {
    const line = {
      ts: new Date().toISOString(),
      hook,
      event: input && typeof input.hook_event_name === "string" ? input.hook_event_name : null,
      session_id: input && typeof input.session_id === "string" ? input.session_id : null,
      message: err instanceof Error ? err.message : String(err),
      stack: err instanceof Error && err.stack ? err.stack.split("\n").slice(1, 4).map((f) => f.trim()) : [],
    };
    mkdirSync(dirname(HOOK_ERROR_LOG), { recursive: true });
    try {
      if (statSync(HOOK_ERROR_LOG).size > HOOK_ERROR_CAP) renameSync(HOOK_ERROR_LOG, `${HOOK_ERROR_LOG}.1`);
    } catch {}
    appendFileSync(HOOK_ERROR_LOG, `${JSON.stringify(line)}\n`, "utf8");
  } catch {
    // The logger is the last link in the chain: if it throws, there is nowhere left to report to.
  }
}

/** Entries from the last `hours`, newest last. Unreadable or absent log reads as empty. */
export function recentHookErrors(hours = 24) {
  try {
    const cutoff = Date.now() - hours * 3600 * 1000;
    return readFileSync(HOOK_ERROR_LOG, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch { return null; } })
      .filter((e) => e && Date.parse(e.ts) >= cutoff);
  } catch {
    return [];
  }
}

let cachedVersion;

/** This plugin's version, or "?" when plugin.json cannot be read. Two roots in one context are told apart by it. */
export function pluginVersion() {
  if (cachedVersion === undefined) {
    try {
      cachedVersion = JSON.parse(
        readFileSync(join(dirname(dirname(ROSTER_CLI)), ".claude-plugin", "plugin.json"), "utf8")
      ).version || "?";
    } catch {
      cachedVersion = "?";
    }
  }
  return cachedVersion;
}

/** The `ah CLI root:` line appended to every SessionStart injection (spec 0048 §2.1): the absolute CLI paths, which only a hook can resolve. */
export function cliRootLine() {
  return (
    `ah CLI root (v${pluginVersion()}): ${dirname(dirname(ROSTER_CLI))} — roster: \`node ${ROSTER_CLI} <verb> --cwd <abs cwd>\`, ` +
    `messages: \`node ${MSG_CLI} <verb> --cwd <abs cwd>\` (verbs: agent-hierarchy/docs/cli-tools.md)`
  );
}

/** Message-file enforcement: "required" gates role dispatches and responses on message files; "off" disables both gates (CLI and listing stay). */
export const MSGS_MODES = ["required", "off"];

/**
 * Session dispatch-routing preference for peer-eligible roles: "peers" (never
 * spawn a roster subagent — the default when nothing has decided; when no
 * live peer exists for a role, the gate asks once per role before allowing a
 * subagent fallback), "subagents" (never route to a peer), or "prefer-peers"
 * (peer when one is live and free, else subagent, without asking). Unlike
 * `msgs`/`handoffs`, an unset config value is NOT normalized to a default
 * here — `resolveConfig` returns `route: null` when no layer sets it, because
 * "unset" and "explicitly peers" are different states to
 * `pretooluse-route-gate.mjs`: only the former asks the user once per session
 * which route to use at all.
 */
export const ROUTE_VALUES = ["peers", "subagents", "prefer-peers"];

/** Config schema version this plugin understands. */
export const CONFIG_VERSION = 1;

/** Selectable roles, in display order. Orchestrator is the session agent and is not configurable. */
export const ROLES = ["ultra-advisor", "architect", "reviewer", "implementor", "task-runner"];

export const ROLE_LABELS = {
  "ultra-advisor": "Ultra-Advisor",
  architect: "Architect",
  reviewer: "Reviewer",
  implementor: "Implementor",
  "task-runner": "Task-Runner",
};

/** Shipped defaults — these mirror the agent-file frontmatter (implementor has no `model:` key). */
export const ROLE_DEFAULTS = {
  "ultra-advisor": { model: "fable" },
  architect: { model: "opus" },
  reviewer: { model: "opus" },
  implementor: { model: "inherit" },
  "task-runner": { model: "haiku", delegate: "task-gopher" },
};

/**
 * Accepted model values, per role. `inherit` is accepted here and converted at
 * render time into "omit the model parameter" — it is NOT a legal Agent-tool
 * value and must never be passed through literally.
 *
 * Architect, Reviewer, and Implementor are REASONING roles: haiku is never
 * valid for them — a Haiku-tier model cannot carry design, review, or
 * implementation judgment. Only Task-Runner (legwork, no reasoning) may run
 * on haiku.
 *
 * Ultra-Advisor is the escalation apex: it exists only to bring MORE reasoning
 * than the Architect already applied, so it takes top-tier models only and
 * never `inherit` — inheriting a Sonnet session would make the tier
 * decorative, which is the same argument that keeps haiku out of the
 * reasoning roles. Its model is always explicit.
 */
export const REASONING_MODELS = ["opus", "sonnet", "fable", "inherit"];
export const TOP_TIER_MODELS = ["fable", "opus"];
export const VALID_MODELS_BY_ROLE = {
  "ultra-advisor": TOP_TIER_MODELS,
  architect: REASONING_MODELS,
  reviewer: REASONING_MODELS,
  implementor: REASONING_MODELS,
  "task-runner": [...REASONING_MODELS, "haiku"],
};

/**
 * A roster member's agent kind (spec 0043 §1.1/§1.2) — which CLI Herdr starts
 * for it. Absent or null means `claude`; the default is total, so no consumer
 * may treat absent-kind as its own case.
 *
 * Shape-only validation, deliberately: Herdr owns the installed-kind list, it
 * is install- and version-specific, and an allowlist compiled in here would be
 * wrong the day a new kind ships. An unrecognized kind fails at spawn time,
 * where Herdr produces the authoritative error (§1.2).
 *
 * Lives here rather than in lib-roster.mjs (where the rest of the member
 * schema lives) because lib-config.mjs is the leaf: lib-roster.mjs imports
 * from it, so the reverse import would close the cycle documented at
 * lib-roster.mjs:22-26. lib-roster.mjs re-exports these for callers that read
 * the member schema from there.
 */
export const KIND_DEFAULT = "claude";
export const KIND_RE = /^[a-z][a-z0-9-]*$/;

/** A member's effective kind: absent/null resolves to `claude` (§1.1). Applied once, at the read seam. */
export function resolveKind(m) {
  const k = m && m.kind;
  if (k === undefined || k === null) return KIND_DEFAULT;
  return k;
}

/**
 * True when a member's route means "this member occupies a pane": `peer` (a
 * Claude session in a pane) and `pane` (spec 0043 §1.5 — driven through Herdr
 * agent-control rather than SendMessage). `subagent` members have no pane.
 *
 * Every pane-bearing decision — layout counts, launch, close, move, resync —
 * asks this, so adding a third pane-bearing route did not have to be spelled
 * out at each of those sites.
 */
export function routeHasPane(route) {
  return route === "peer" || route === "pane";
}

/**
 * Herdr's agent-name rule (spec 0043 §1.7, F6): `[a-z][a-z0-9_-]{0,31}`,
 * i.e. at most 32 characters. Returns `{ok: true}` or `{ok: false, why}`.
 *
 * Checked against the DERIVED name, at add/edit — not inside
 * `rosterMemberNames`, which runs on every roster read (SessionStart, the
 * route gate, `show`) where throwing would break reads that have nothing to
 * do with spawning.
 */
export function validateHerdrName(name) {
  if (typeof name !== "string" || !name) return { ok: false, why: "name must be a non-empty string" };
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(name)) {
    return {
      ok: false,
      why: `derived name ${JSON.stringify(name)} (${name.length} chars) does not match Herdr's agent-name rule [a-z][a-z0-9_-]{0,31} (max 32 characters) — shorten the team alias or repo basename with \`roster.mjs alias --set <short>\``,
    };
  }
  return { ok: true };
}

export const CONFIG_BASENAME = "agent-hierarchy.json";

/** Roles a roster member may carry — the same ROLES list, orchestrator is never a member (§3.2). */
export const ROSTER_ROLES = ROLES;

/** Roster levels, in resolution precedence order (highest first). */
export const ROSTER_LEVELS = ["repo-user", "repo", "global"];

/** Model families ranked for the tier rule: a role at or below the session's own tier buys no extra reasoning. */
export const TIER = { haiku: 1, sonnet: 2, opus: 3, fable: 4 };

/** Family tier from `claude-<family>-…` or a bare family name; unknown → null. */
export function tierOf(model) {
  if (typeof model !== "string" || !model) return null;
  const m = model.toLowerCase().match(/(?:^|[^a-z])(haiku|sonnet|opus|fable)(?:[^a-z]|$)/);
  return m ? TIER[m[1]] : null;
}

/**
 * Flow control: who advances the chain. `auto` (default) — the Orchestrator
 * performs handoffs itself and reports. `confirm` — the Orchestrator asks the
 * user before each reasoning-role dispatch, so every handoff is a decision the
 * user makes. Legwork dispatches (Task-Runner / task-gopher) are exempt in
 * both modes: errands are not handoffs.
 */
export const HANDOFF_MODES = ["auto", "confirm"];

/**
 * Roles the Orchestrator should try as a named peer session (SendMessage)
 * before falling back to spawning a subagent. Ultra-Advisor is included
 * because pretooluse-ultra-gate.mjs also watches SendMessage calls addressed
 * to its named peer, so the peer route is gated exactly like the subagent
 * route — see that file. Task-Runner is excluded: task-gopher is already its
 * dedicated fast path.
 */
export const PEER_ELIGIBLE_ROLES = ["ultra-advisor", "architect", "reviewer", "implementor"];

/** Per-role dispatch route: "peer" tries the named peer session first, falling back to a subagent; "model" always spawns a subagent. */
export const DISPATCH_MODES = ["peer", "model"];

/** The named-peer-session convention shared by the injected directive and the Ultra-Advisor gate: "<repo-basename>-<role>". */
export function peerName(repoBasename, role) {
  return `${repoBasename}-${role}`;
}

/**
 * Role tokens a peer session name may carry; `advisor` alone reads as
 * ultra-advisor. Lives here (not lib-hier.mjs) so `validateTeamAlias` below
 * can consult it without a circular import — lib-hier.mjs imports
 * `roleFromName` from here instead (spec 0010 §4.4 amendment (e)).
 */
const ROLE_TOKENS = [
  ["ultra-advisor", "ultra-advisor"],
  ["architect", "architect"],
  ["reviewer", "reviewer"],
  ["implementor", "implementor"],
  ["advisor", "ultra-advisor"],
];

/** The role a session name implies, via a role token, or null. */
export function roleFromName(name) {
  if (typeof name !== "string") return null;
  for (const [token, role] of ROLE_TOKENS) if (name.includes(token)) return role;
  return null;
}

/**
 * Every peer session name this role's config resolves to — `peer` may be a
 * single name or an array of names (several peers for one role). Empty when
 * the resolved `dispatch` is "model" (never route to a peer) or the role isn't
 * peer-eligible at all.
 */
export function resolvedPeerTargets(role, entry, repoBasename) {
  if (!PEER_ELIGIBLE_ROLES.includes(role)) return [];
  if (!entry || entry.dispatch === "model") return [];
  if (Array.isArray(entry.peer)) return entry.peer.filter((p) => typeof p === "string" && p.trim());
  if (entry.peer && entry.peer !== "auto") return [entry.peer];
  return [peerName(repoBasename, role)];
}

/** One-name convenience wrapper over `resolvedPeerTargets`: the first target, or null when there is none. */
export function resolvedPeerTarget(role, entry, repoBasename) {
  const targets = resolvedPeerTargets(role, entry, repoBasename);
  return targets.length ? targets[0] : null;
}

/** Read the hook's stdin JSON payload; returns {} if absent or unparseable. */
export async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    lastHookInput = JSON.parse(raw);
    return lastHookInput;
  } catch (err) {
    // Empty stdin is ordinary; stdin that arrived and would not parse is not, and the {} it
    // degrades to is indistinguishable from a plain main session.
    // 40 bytes is enough to recognise the shape; a longer prefix starts capturing the session id
    // and the transcript path a real payload carries.
    err.message = `${err.message} — unparseable payload, ${raw.length} bytes: ${raw.slice(0, 40)}`;
    logHookError("readHookInput", err, {});
    return {};
  }
}

/**
 * True for any subagent session.
 *
 * The discriminator is `agent_id`, which only a subagent carries. `agent_type`
 * is NOT usable for this: a top-level `claude --agent <plugin:name>` session
 * sets it too (verified on v2.1.223 — its SessionStart payload was
 * `session_id, transcript_path, cwd, agent_type, hook_event_name, source`,
 * with no `agent_id`), so testing `agent_type` classifies a genuine main
 * session as a subagent and suppresses the injection it should receive.
 *
 * Both subagent cases suppress every injection: an `ah:*` role
 * (hard recursion suppression, since subagents can nest up to three layers)
 * and any foreign subagent such as `task-gopher:task-gopher`.
 */
export function isSubagent(input) {
  const id = input && input.agent_id;
  return typeof id === "string" && id.length > 0;
}

/**
 * True for a session that carries an agent identity but is NOT a subagent —
 * i.e. the main session of a `claude --agent <name>` invocation.
 */
export function isTopLevelAgentSession(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.length > 0 && !isSubagent(input);
}

/**
 * The hierarchy role an `agent_type` names, or null when it names none.
 *
 * Matched anchored on `(^|:)role$`, the same matcher the rest of the plugin
 * uses to identify roles. A foreign `someplugin:architect` therefore reads as
 * `architect`; that imprecision is accepted, because the text this selects is
 * generic enough for the false positive to be harmless.
 */
export function hierarchyRoleOf(agentType) {
  if (typeof agentType !== "string" || !agentType) return null;
  return ROLES.find((role) => agentType === role || agentType.endsWith(`:${role}`)) || null;
}

/**
 * Resolve the calling session's hierarchy role — spec 0028 §3.3/§3.7.
 * Returns `{ role, direct }`: `direct: true` only when the payload itself
 * identifies the caller (`agent_type`); otherwise falls back to the
 * session-id-keyed persisted map, with `direct: false`.
 *
 * A subagent shares its parent's session_id, so the persisted half answers
 * "what role is this session", not "what role is this caller" — a caller
 * that enforces policy MUST check `direct` and act only when it is true. Do
 * not collapse this to a bare role string; hiding `direct` invites the exact
 * defect §3.7 describes.
 */
export function resolveHierarchyRole(input) {
  const direct = input && input.agent_type ? hierarchyRoleOf(input.agent_type) : null;
  if (direct) return { role: direct, direct: true };
  const persisted = readSessionRole(normalizeSessionId(input && input.session_id));
  return { role: persisted, direct: false };
}

export function userConfigPath() {
  return join(homedir(), ".claude", CONFIG_BASENAME);
}

export function projectConfigPath(cwd) {
  if (typeof cwd !== "string" || !cwd) return null;
  return join(resolve(cwd), ".claude", CONFIG_BASENAME);
}

/** Walk up from `start` to the nearest enclosing `.git`; null if none. Shared by hierarchyDir and the roster levels below so all three agree on "this repo". */
export function findGitRoot(start) {
  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/**
 * The hierarchy runtime dir for a cwd. `AGENT_HIERARCHY_DIR` env wins; else
 * the enclosing git checkout's `.claude/hierarchy/`; else
 * `~/.claude/hierarchy/<basename(cwd)>/`. Lives here (not lib-hier.mjs, which
 * re-exports it) so lib-config.mjs can resolve a team.json path for
 * `statusReport` without a runtime import cycle.
 */
export function hierarchyDir(cwd) {
  const env = process.env.AGENT_HIERARCHY_DIR;
  if (typeof env === "string" && env.trim()) return resolve(env.trim());
  const base = typeof cwd === "string" && cwd ? cwd : process.cwd();
  const root = findGitRoot(base);
  if (root) return join(root, ".claude", "hierarchy");
  return join(homedir(), ".claude", "hierarchy", basename(resolve(base)));
}

/** `"-Users-jimcline-git-repos-claudetools"` style slug of an absolute path — every `/` becomes `-`, leading `-` preserved. */
export function pathSlug(absPath) {
  return resolve(absPath).replace(/\//g, "-");
}

/** Absolute path of each roster level's config file for a cwd. */
export function rosterLevelPaths(cwd) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  return {
    global: userConfigPath(),
    repo: join(repoRoot, ".claude", CONFIG_BASENAME),
    "repo-user": join(homedir(), ".claude", "agent-hierarchy", "projects", pathSlug(repoRoot), CONFIG_BASENAME),
  };
}

/**
 * Main checkout root when `worktreeRoot` is a linked worktree, else null.
 * A worktree's `.git` is a FILE holding `gitdir: <main>/.git/worktrees/<name>`;
 * that dir's `commondir` file points back at the main `.git`. A submodule uses
 * the same `.git`-file mechanism but resolves under `.git/modules/`, so the
 * `worktrees` check below is what keeps submodules out.
 */
function mainCheckoutRoot(worktreeRoot) {
  const dotgit = join(worktreeRoot, ".git");
  let raw;
  try {
    if (!statSync(dotgit).isFile()) return null; // normal checkout: .git is a dir
    raw = readFileSync(dotgit, "utf8");
  } catch {
    return null;
  }
  const m = /^gitdir:\s*(.+)$/m.exec(raw);
  if (!m) return null;
  const gitdir = resolve(worktreeRoot, m[1].trim()); // pointer may be relative
  if (basename(dirname(gitdir)) !== "worktrees") return null; // submodule, or unknown layout
  let commonDir;
  try {
    commonDir = resolve(gitdir, readFileSync(join(gitdir, "commondir"), "utf8").trim());
  } catch {
    commonDir = dirname(dirname(gitdir)); // .../.git/worktrees/<n> -> .../.git
  }
  // Only a `<root>/.git` common dir implies a working tree at `<root>`. A bare
  // repo's is `<name>.git` and `--separate-git-dir`'s is an arbitrary path;
  // deriving a root from either names a directory that is not a checkout.
  if (basename(commonDir) !== ".git") return null;
  const root = dirname(commonDir);
  return root && root !== worktreeRoot ? root : null;
}

/** Candidate config paths per roster level, most specific first. */
export function rosterLevelCandidates(cwd) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  const roots = [repoRoot];
  const main = mainCheckoutRoot(repoRoot);
  if (main) roots.push(main); // empty for a normal checkout
  return {
    "repo-user": roots.map((r) => join(homedir(), ".claude", "agent-hierarchy", "projects", pathSlug(r), CONFIG_BASENAME)),
    repo: roots.map((r) => join(r, ".claude", CONFIG_BASENAME)),
    global: [userConfigPath()],
  };
}

/**
 * Derive each member's dispatch name (§3.4): first member of a role gets
 * `peerName(repoBasename, role)`, later same-role members get `-2`, `-3`, ...
 * in array order. `peerName` stays the ordinal-1 case of this function.
 *
 * Also the single read seam where a member's `kind` default is applied (spec
 * 0043 §1.1): every consumer downstream of a roster read — `spawnShape`,
 * `memberIsLive`, `show`, `history`, the `team.json` writers — sees an
 * explicit `kind` and none of them re-applies the default. The value is
 * resolved, never written back to the config file.
 */
export function rosterMemberNames(members, repoBasename) {
  const seen = {};
  return members.map((m) => {
    const role = m.role;
    const ordinal = (seen[role] = (seen[role] || 0) + 1);
    const base = peerName(repoBasename, role);
    return { ...m, kind: resolveKind(m), name: ordinal === 1 ? base : `${base}-${ordinal}` };
  });
}

/**
 * Character-set + role-collision rule for a `teamAlias` (spec 0010 §4.4,
 * amendment (d)): starts alphanumeric, 1-32 chars of letters/digits/`-`
 * thereafter, and must not derive a peer name that `roleFromName`'s
 * unanchored substring match resolves to the wrong role, for any role in
 * `PEER_ELIGIBLE_ROLES` (e.g. alias `architect` yields peer name
 * `architect-reviewer`, which resolves to role `architect`, not `reviewer`).
 * Stated behaviorally against the real functions, not a hardcoded token
 * list, so it stays correct if `ROLE_TOKENS` ever changes — a blacklist
 * would wrongly reject `advisor`, which is genuinely safe. Returns
 * `{ok: true}` or `{ok: false, why}`.
 */
export function validateTeamAlias(alias) {
  if (typeof alias !== "string" || !alias) return { ok: false, why: "alias must be a non-empty string" };
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,31}$/.test(alias)) {
    return {
      ok: false,
      why: "alias must start with a letter or digit, be 1-32 characters, and contain only letters, digits, and -",
    };
  }
  const collidesWith = PEER_ELIGIBLE_ROLES.find((role) => roleFromName(peerName(alias, role)) !== role);
  if (collidesWith) {
    return {
      ok: false,
      why: `alias collides with role-token matching: a "${collidesWith}" peer name derived from it would not resolve back to role "${collidesWith}"`,
    };
  }
  return { ok: true };
}

/** Convenience boolean wrapper over `validateTeamAlias`. */
export function isValidTeamAlias(alias) {
  return validateTeamAlias(alias).ok;
}

/**
 * Spec 0044 §1.1/[9.1]: a `validateTeamAlias`-clean name to offer a user whose repo basename is
 * not one. The refusal it feeds has to be actionable — "this name is illegal" with nothing to
 * type next is how a user ends up back on the shared `team.json` the invariant forbids. Sanitize
 * first so the suggestion still resembles the repo; `team` is the last resort, which is also the
 * answer when the basename is legal characters but role-token-colliding (e.g. `architect`).
 */
export function suggestTeamAlias(raw) {
  const sanitized = String(raw == null ? "" : raw)
    .replace(/[^A-Za-z0-9-]/g, "-")
    .replace(/^[^A-Za-z0-9]+/, "")
    .slice(0, 32)
    .replace(/-+$/, "");
  return [sanitized, `team-${sanitized}`.slice(0, 32).replace(/-+$/, "")].find((c) => validateTeamAlias(c).ok) || "team";
}

/**
 * Resolve the naming prefix for a repo (spec 0010 §4.1): the first of
 * repo-user, repo carrying a valid top-level `teamAlias` string wins; `global`
 * is never read (§4.3 — an alias is a property of one repo, not a
 * machine-wide default). An unreadable file, non-object root, absent key, or
 * a value failing `validateTeamAlias` falls through to the next level —
 * never throws. Nothing found → the git-root basename (or cwd basename when
 * not inside a git checkout), byte-identical to the pre-alias behavior.
 * `teamPrefix` is a thin wrapper over this — keep it that way, one
 * implementation.
 *
 * `team`, when a non-empty string, short-circuits everything below it: an
 * active named-team scope (spec 0011 §3.3) outranks repo-user/repo/default,
 * since the team name itself is the prefix members are dispatched-named
 * under.
 */
export function teamPrefixInfo(cwd, team) {
  if (typeof team === "string" && team) return { prefix: team, alias: team, source: "team" };
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  const paths = rosterLevelPaths(cwd);
  for (const level of ROSTER_LEVELS) {
    if (level === "global") continue;
    const path = paths[level];
    if (!existsSync(path)) continue;
    let data;
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      continue;
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) continue;
    const alias = data.teamAlias;
    if (alias === undefined) continue;
    if (isValidTeamAlias(alias)) return { prefix: alias, alias, source: level };
    // Invalid hand-edited value — fall through; resolveConfig's warnings array
    // is where the user learns why (it reads the same raw layers).
  }
  return { prefix: basename(repoRoot), alias: null, source: "default" };
}

/** The winning naming prefix for a repo — see `teamPrefixInfo`. */
export function teamPrefix(cwd, team) {
  return teamPrefixInfo(cwd, team).prefix;
}

/** The `rosters[team]` block at one level, or null. Invalid alias keys are skipped. */
function pickTeamRoster(data, team) {
  const map = data.rosters;
  if (!map || typeof map !== "object" || Array.isArray(map)) return null;
  return Object.prototype.hasOwnProperty.call(map, team) ? map[team] : null;
}

/**
 * Resolve the roster: repo-user → repo → global, first level whose `roster`
 * key is present with at least one member wins IN ITS ENTIRETY (no merging
 * across levels). Returns `{level, route, layout, members: [...withNames],
 * path, teamAlias, teamAliasSource, teamKey}` (`layout` defaults to "auto"
 * when absent — the sole default site, spec 0004 §4.3) or null when no level
 * has one.
 *
 * Two-pass (spec 0032 §3.2): when `team` is given, pass 1 walks every level
 * looking for a `rosters[team]` block (team-specificity outranks location);
 * pass 2, always run, is today's behaviour reading the default `roster` key.
 * `teamKey` on the result is the team the WINNING pass matched on — the
 * team name for a pass-1 hit, else null (including whenever `team` had no
 * matching override anywhere and pass 2 won).
 */
export function resolveRoster(cwd, team) {
  const candidates = rosterLevelCandidates(cwd);
  const { prefix, alias, source } = teamPrefixInfo(cwd, team);
  const passes = team ? [team, null] : [null];
  for (const teamKey of passes) {
    for (const level of ROSTER_LEVELS) {
      for (const path of candidates[level]) {
        if (!existsSync(path)) continue;
        let data;
        try {
          data = JSON.parse(readFileSync(path, "utf8"));
        } catch {
          continue;
        }
        if (!data || typeof data !== "object" || Array.isArray(data)) continue;
        const r = teamKey ? pickTeamRoster(data, teamKey) : data.roster;
        if (!r || typeof r !== "object" || Array.isArray(r) || !Array.isArray(r.members) || r.members.length === 0) continue;
        return {
          level,
          route: r.route,
          layout: r.layout || "auto",
          members: rosterMemberNames(r.members, prefix),
          path,
          teamAlias: alias,
          teamAliasSource: source,
          teamKey,
        };
      }
    }
  }
  return null;
}

/** Load one scope. Returns null when absent/unreadable/not an object. */
function loadScope(path, scope, warnings) {
  if (!path || !existsSync(path)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    warnings.push(`ah: ${scope}-scope config at ${path} is not valid JSON — ignoring it.`);
    return null;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    warnings.push(`ah: ${scope}-scope config at ${path} is not a JSON object — ignoring it.`);
    return null;
  }
  const version = data.version === undefined ? CONFIG_VERSION : data.version;
  if (!Number.isInteger(version) || version > CONFIG_VERSION) {
    warnings.push(
      `ah: ${scope}-scope config at ${path} declares version ${JSON.stringify(data.version)}, which this plugin (v${CONFIG_VERSION}) does not understand — ignoring it.`
    );
    return null;
  }
  return { scope, path, data };
}

/**
 * The active team scope (spec 0011 §4.4): (1) `opts.team` if given —
 * trusted as-is, the CLI layer validates it with `validateTeamAlias` before
 * we ever see it; (2) the team (default or named) whose `team.json` binds
 * `orchestrator.session_id === opts.sessionId`, letting an orchestrator omit
 * `--team` after `create`; (3) `null`, the default team. Any read failure
 * (missing team file, unreadable member list) degrades to `null` rather than
 * throwing — 0009 §8.12's fail-open catch, extended to team resolution.
 */
function resolveTeamScope(cwd, opts) {
  if (opts && typeof opts.team === "string" && opts.team) return opts.team;
  if (opts && opts.sessionId) {
    try {
      const dir = hierarchyDir(cwd);
      const base = readTeam(dir);
      if (base && base.orchestrator && base.orchestrator.session_id === opts.sessionId) return null;
      for (const name of listTeamNames(dir)) {
        const team = readTeam(dir, name);
        if (team && team.orchestrator && team.orchestrator.session_id === opts.sessionId) return name;
      }
    } catch {
      // fail-open to default — see doc comment above.
    }
  }
  return null;
}

/**
 * Resolve the effective hierarchy for a session.
 *
 * @returns {{configured: boolean, enabled: boolean, roles: object, sources: object,
 *            shadowed: string[], layers: object[], warnings: string[], team: string|null}}
 */
export function resolveConfig(cwd, opts = {}) {
  const warnings = [];
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const team = resolveTeamScope(resolvedCwd, opts);
  const userPath = userConfigPath();
  // Fix 2 (spec 0032 §4): worktree-aware candidate lists, matching resolveRoster — first
  // existing path per scope, never merged across candidates within a level (§4 rationale:
  // `shadowed` counts scopes, and a merge would change what it means).
  const candidates = rosterLevelCandidates(resolvedCwd);
  // `global`/`repo`/`repo-user` here map to resolveConfig's `user`/`project`/`repo-user`
  // scope names. Names differ for historical reasons (spec 0001); the files are the same.
  const firstExisting = (paths) => paths.find((p) => existsSync(p)) || null;
  const projectPath = firstExisting(candidates.repo);
  const repoUserPath = firstExisting(candidates["repo-user"]);
  const user = loadScope(userPath, "user", warnings);
  // When the session's cwd IS the home directory the two scopes are the same
  // file; loading it twice would report every role as shadowed by itself.
  const project = !projectPath || projectPath === userPath ? null : loadScope(projectPath, "project", warnings);
  const repoUser = !repoUserPath || repoUserPath === userPath || repoUserPath === projectPath ? null : loadScope(repoUserPath, "repo-user", warnings);

  // Least specific first: repo-user is the new highest-precedence layer.
  const layers = [user, project, repoUser].filter(Boolean);

  // teamAlias is read at repo/repo-user only (§4.3) — a hand-edited invalid
  // value at global is simply never consulted, so it gets no warning either.
  for (const layer of layers) {
    if (layer.scope === "user") continue;
    const rawAlias = layer.data.teamAlias;
    if (rawAlias === undefined) continue;
    const v = validateTeamAlias(rawAlias);
    if (!v.ok) {
      warnings.push(`ah: teamAlias ${JSON.stringify(rawAlias)} at ${layer.scope}-scope config (${layer.path}) is invalid (${v.why}) — ignoring it.`);
    }
  }

  const roles = {};
  const sources = {};
  for (const role of ROLES) {
    roles[role] = { ...ROLE_DEFAULTS[role] };
    sources[role] = "default";
  }

  if (layers.length === 0) {
    return {
      configured: false,
      enabled: true,
      handoffs: "auto",
      handoffsSource: "default",
      msgs: "required",
      route: null,
      routeSource: null,
      roles,
      sources,
      shadowed: [],
      layers,
      warnings,
      cwd: resolvedCwd,
      roster: null,
      rosterLevel: null,
      team,
    };
  }

  let enabled = true;
  for (const layer of layers) {
    if (typeof layer.data.enabled === "boolean") enabled = layer.data.enabled;
  }

  // Most-specific scope wins, same rule as `enabled`.
  let handoffs = "auto";
  let handoffsSource = "default";
  for (const layer of layers) {
    if (typeof layer.data.handoffs === "string") {
      handoffs = layer.data.handoffs;
      handoffsSource = layer.scope;
    }
  }
  if (!HANDOFF_MODES.includes(handoffs)) {
    warnings.push(
      `ah: handoffs ${JSON.stringify(handoffs)} is not a mode (allowed: ${HANDOFF_MODES.join(", ")}) — using "auto".`
    );
    handoffs = "auto";
    handoffsSource = "default";
  }

  // Most-specific scope wins, same rule as `enabled`.
  let msgs = "required";
  for (const layer of layers) {
    if (typeof layer.data.msgs === "string") msgs = layer.data.msgs;
  }
  if (!MSGS_MODES.includes(msgs)) {
    warnings.push(`ah: msgs ${JSON.stringify(msgs)} is not a mode (allowed: ${MSGS_MODES.join(", ")}) — using "required".`);
    msgs = "required";
  }

  // Most-specific scope wins, same rule as `enabled`. Unset stays null — see ROUTE_VALUES doc comment.
  let route = null;
  let routeSource = null;
  for (const layer of layers) {
    if (typeof layer.data.route === "string") {
      route = layer.data.route;
      routeSource = layer.scope;
    }
  }
  if (route !== null && !ROUTE_VALUES.includes(route)) {
    warnings.push(`ah: route ${JSON.stringify(route)} is not a mode (allowed: ${ROUTE_VALUES.join(", ")}) — ignoring it.`);
    route = null;
    routeSource = null;
  }

  const definedBy = {};
  for (const layer of layers) {
    const layerRoles = layer.data.roles;
    if (!layerRoles || typeof layerRoles !== "object" || Array.isArray(layerRoles)) continue;
    for (const role of ROLES) {
      const entry = layerRoles[role];
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
      // Shallow replacement: the whole role object is swapped, not merged key-by-key.
      roles[role] = { ...entry };
      sources[role] = layer.scope;
      (definedBy[role] ||= []).push(layer.scope);
    }
  }

  // A user-scope role value that a project config also defines is shadowed.
  const shadowed = ROLES.filter((role) => (definedBy[role] || []).length > 1);

  for (const role of ROLES) {
    const model = roles[role].model;
    const valid = VALID_MODELS_BY_ROLE[role];
    if (typeof model !== "string" || !valid.includes(model)) {
      warnings.push(
        `ah: model ${JSON.stringify(model)} is not allowed for role "${role}" (allowed: ${valid.join(", ")}) — using the default "${ROLE_DEFAULTS[role].model}".`
      );
      roles[role] = { ...roles[role], model: ROLE_DEFAULTS[role].model };
    }
    if (!PEER_ELIGIBLE_ROLES.includes(role)) continue;
    const rawDispatch = roles[role].dispatch;
    let dispatch = rawDispatch === undefined ? "peer" : rawDispatch;
    if (!DISPATCH_MODES.includes(dispatch)) {
      warnings.push(
        `ah: dispatch ${JSON.stringify(rawDispatch)} is not valid for role "${role}" (allowed: ${DISPATCH_MODES.join(", ")}) — using "peer".`
      );
      dispatch = "peer";
    }
    roles[role] = { ...roles[role], dispatch };
    if (dispatch === "peer") {
      const rawPeer = roles[role].peer;
      let peer = rawPeer === undefined ? "auto" : rawPeer;
      const validArray = Array.isArray(peer) && peer.length > 0 && peer.every((p) => typeof p === "string" && p.trim());
      if (!validArray && (typeof peer !== "string" || !peer.trim())) {
        warnings.push(`ah: peer value for role "${role}" must be a non-empty string or array of names — using "auto".`);
        peer = "auto";
      }
      roles[role] = { ...roles[role], peer };
    }
  }

  const rosterResult = resolveRoster(cwd, team);
  return {
    configured: true,
    enabled,
    handoffs,
    handoffsSource,
    msgs,
    route,
    routeSource,
    roles,
    sources,
    shadowed,
    layers,
    warnings,
    cwd: resolvedCwd,
    roster: rosterResult,
    rosterLevel: rosterResult ? rosterResult.level : null,
    team,
  };
}

/** The subagent_type to dispatch for a role, honouring task-runner's `delegate`. */
export function subagentType(role, entry) {
  if (role === "task-runner" && entry && entry.delegate === "task-gopher") {
    return "task-gopher:task-gopher";
  }
  return `ah:${role}`;
}

/**
 * One dispatch line per role. `inherit` renders as "omit the parameter", never
 * as a value. A peer-eligible role still sitting on the unconfirmed
 * `peer:"auto"` default gets a pointer to PEER NAME CONFIRMATION instead of a
 * resolved name — the repo-basename convention is a guess, not a settled
 * answer, until a user has confirmed it once. A role whose peer name IS
 * already settled (see `resolvedPeerTarget`) leads with the named-peer
 * SendMessage route and gives the subagent call as the fallback; a role
 * resolved to "model" — including every non-peer-eligible role — gets the
 * subagent call alone.
 */
function roleLines(roles, repoBasename) {
  return ROLES.map((role) => {
    const entry = roles[role];
    const type = subagentType(role, entry);
    const agentCall =
      entry.model === "inherit"
        ? `Agent(subagent_type:"${type}") — OMIT \`model\` entirely (inherits this session's model). Never pass "inherit" as a value.`
        : `Agent(subagent_type:"${type}", model:"${entry.model}")`;
    if (PEER_ELIGIBLE_ROLES.includes(role) && entry.dispatch === "peer" && entry.peer === "auto") {
      return `- ${ROLE_LABELS[role]} — peer name not yet confirmed for this repo (see PEER NAME CONFIRMATION below); resolve it before your first dispatch of this role, then use ${agentCall} as the fallback once resolved.`;
    }
    const peers = resolvedPeerTargets(role, entry, repoBasename);
    if (!peers.length) {
      return `- ${ROLE_LABELS[role]} — ${agentCall}`;
    }
    const named = peers.map((p) => `"${p}"`).join(" / ");
    return `- ${ROLE_LABELS[role]} — peer ${named} via SendMessage if it appears in ListAgents (default), else ${agentCall}`;
  });
}

/**
 * The Ultra-Advisor user gate, appended to protocol item 7.
 *
 * The gate itself is enforced by the PreToolUse hook; this text exists so the
 * Orchestrator recognizes the denial as policy rather than a malfunction, and
 * so a spoken "stop asking about the advisor" can be honored on the spot the
 * way the flow switch already is.
 */
function gateSentences(sessionId) {
  const lines = [
    "USER GATE: a PreToolUse hook DENIES the first Ultra-Advisor dispatch of every session — Agent-tool spawn or SendMessage to its named peer — until the user approves. The denial states the exact question to put to them and the exact command that records their answer — follow it verbatim; no improvised wording, no skipped record step. Their answer (allow for this session / ask each time / blocked this session) is session-scoped, covers both routes, resets next session. In \"confirm\" flow that prompt REPLACES item 0's confirmation for that dispatch: ask once, not twice.",
  ];
  if (sessionId) {
    lines.push(
      `This session's gate id is "${sessionId}". Plain-words request ("don't use the ultra advisor", "stop asking me about it", "go ahead without asking") → run \`node "${GATE_CLI}" set --session "${sessionId}" --choice session|each|off\` without waiting for a dispatch; \`node "${GATE_CLI}" status --session "${sessionId}"\` reports the current answer.`
    );
  }
  return lines.join(" ");
}

/**
 * Guidance appended once, only when at least one peer-eligible role's config
 * still has `peer:"auto"` — its peer session name has never been confirmed
 * for this repo. Mirrors the ranking `/hierarchy init` steps 6-8 already use,
 * applied lazily at first dispatch instead of only during the wizard, so a
 * role never run through `init` (or hand-added to the config) still gets its
 * peer name settled once rather than guessed at on every dispatch forever.
 */
function peerConfirmationParagraph(repoBasename) {
  return [
    "PEER NAME CONFIRMATION — a role above marked \"peer name not yet confirmed\" has `peer:\"auto\"` never settled for this repo. Resolve ONCE, the first time you need to dispatch that role, before dispatching:",
    `1. ListAgents. Exact match on "${repoBasename}-<role>" first (repo-basename convention).`,
    "2. No match + you know this session's display name (UI, or user told you) → also try \"<that name's prefix>-<role>\" — some setups name peers off a shared custom prefix, not the repo dir.",
    "3. Rank ListAgents output: (a) exact match on expected name, (b) contains expected prefix AND a role-match token (\"architect\", \"reviewer\", \"implementor\", \"ultra-advisor\"/\"advisor\"), (c) role token only, (d) prefix only, (e) everything else — same tiers as `/hierarchy init`.",
    "4. AskUserQuestion — even an exact match gets this one-time confirmation, never assume silently. Offer: confirm the top candidate (if any); \"pick from a list\" of up to the top 4 ranked candidates when 2 or more exist; \"type in the exact name\"; \"no peer — always use a subagent for this role\".",
    "5. Record immediately with the Write tool in the most specific `.claude/agent-hierarchy.json` that already exists (project if present, else user), replacing only that role's object: `peer:\"<confirmed-name>\"` (keep `dispatch:\"peer\"`) for a confirmed name; `dispatch:\"model\"` with `peer` omitted for \"no peer\". Preserve every other key and role. One line: what you recorded, where.",
    "6. Proceed with THIS dispatch on the resolved route. Every later dispatch of this role in this repo uses the recorded value — never ask again unless the user changes it via `/hierarchy` or the config file.",
  ].join("\n");
}

/**
 * The three 0.29.0 protocol items: message files (12), roster + route (13),
 * tier rule (14). `hierDir`, `model`, and `route` may be null (unit callers);
 * the text degrades to the generic form. `route`, when given, is
 * `{value, source}` from `effectiveRoute()`.
 */
function protocolItems1214(resolved, hierDir, model, route, sessionId) {
  const dirText = hierDir || "<hierarchy dir>";
  const routeText = route ? `${route.value} (from ${route.source})` : "not yet chosen — your first roster dispatch will ask";
  const routeCmd = `node "${MSG_CLI}" route <peers|prefer-peers|subagents>${sessionId ? ` --session ${sessionId}` : ""}`;
  const t = tierOf(model);
  const roleTierText = `Architect ${resolved.roles.architect.model}(${tierOf(resolved.roles.architect.model) ?? "?"}), Ultra-Advisor ${resolved.roles["ultra-advisor"].model}(${tierOf(resolved.roles["ultra-advisor"].model) ?? "?"})`;
  const tierOpen =
    model && t !== null
      ? `TIER RULE — you are ${model} (tier ${t}). ${roleTierText}. haiku<sonnet<opus<fable.`
      : `TIER RULE — read your own model from your environment line and rank haiku<sonnet<opus<fable; ${roleTierText}.`;
  return [
    `12. MESSAGE FILES — every role dispatch (Agent spawn of architect/implementor/reviewer/ultra-advisor, or a peer brief via SendMessage) carries its brief as a file, not inline prose; a PreToolUse gate denies the dispatch otherwise. Writer: \`node "${MSG_CLI}" new --to <role> --from orchestrator --slug <slug> [--to-name <peer-or-agent name>] [--parent <id>] [--reason context|second-opinion|parallel]\` (never hand-roll ids or skeletons), then fill EVERY section of the skeleton it prints — request keys [0] tldr [1] goal [2] context [3] constraints [4] files [5] acceptance [6] want_back; \`[0] tldr\` = one bullet per section, \`- [N] key: <≤10-word gist>\`. Style: bullets, imperative, no prose, no restating what the reader can see; every constraint / negative / acceptance criterion survives verbatim — brevity is the tie-breaker, never the goal. In-band pointer: the Agent prompt / SendMessage body opens with \`[hierarchy-msg <abs request path>]\` then ≤3 TL;DR lines (peer briefs keep the [hierarchy-peer-brief ...] sentinel line first). Reader: \`grep -n '^## \\\\[' <path>\` = the index; Read(offset,limit) only the sections the tldr says matter (whole-file Read fine when small). The role replies \`[hierarchy-msg <abs response path>]\` + its [1] status bullet; a response file closes the exchange — new work is a new id (\`--parent <id>\` links it), never an append. Files under ${dirText}/msgs/; \`node "${MSG_CLI}" list|index|sweep|roster\` (or /hierarchy msgs|peers|sweep). Multiple instances per role are normal — roles are categories; \`to_name:\`/\`from_name:\` name the instance.`,
    `13. PEER ROSTER + ROUTE — ${dirText}/peers.jsonl is ground truth for which role peers are up, seen, or briefed; after compaction trust the HIERARCHY STATE block over memory. This session's dispatch route is ${routeText} — honor it without re-asking (a PreToolUse gate enforces it, one-shot per role per session, on the roster roles). User changes it in chat ("peers only", "subagents only", "prefer peers"/"peers when free") → record immediately with \`${routeCmd}\` and confirm in one line. Standing up, reshaping, or tearing down a live Team — create/spawn a Team, spawn or dismiss one member, disband, resync/move — goes through the \`ah:agent-team\` skill (\`Skill(skill:"ah:agent-team")\`, or \`/agent-team\`); editing the roster TEMPLATE — add/edit/remove a role — through \`ah:agent-roster\`; neither is a raw roster MCP call. A one-off subagent dispatch of a role is ordinary protocol, no skill. Spawning one session is a direct call, not a skill: a roster member is \`node "${ROSTER_CLI}" spawn-one <role> [--member <n>] --cwd <abs cwd>\`; with no roster, or for a role the roster does not carry, \`… spawn-ad-hoc <role> [--kind pi|codex|claude] [--route peer|pane] --cwd <abs cwd>\`. A non-\`claude\` \`--kind\` is route \`pane\`: drive it with \`herdr agent prompt\`, never SendMessage.`,
    `14. ${tierOpen} Do not dispatch Architect or Ultra-Advisor for REASONING when its tier ≤ yours — take that role's contract inline (write the spec at the spec path yourself; adjudicate yourself). Same-or-lower-tier dispatch only for: context — the design is large and belongs out of your window; second-opinion — the user asked, or you want a fresh-context check; parallel — other work runs meanwhile. Put the reason in the request file's reason: field and one tldr line. Ultra-Advisor: escalate only when strictly higher than you; same tier → decide it yourself and say so. Reviewer is exempt — review buys independence, not tier. A PreToolUse gate denies ONCE per role per session when your model is known, the role's tier ≤ yours, and the request file carries no reason:.`,
  ];
}

/**
 * The full SessionStart injection for a configured, enabled session.
 * `extra.hierDir` (runtime dir) and `extra.model` (session model, if known)
 * shape items 4/12/14; both optional.
 */
export function buildDirective(resolved, sessionId, extra = {}) {
  const hierDir = extra && typeof extra.hierDir === "string" ? extra.hierDir : null;
  const model = extra && typeof extra.model === "string" ? extra.model : null;
  const route = extra && extra.route && typeof extra.route.value === "string" ? extra.route : null;
  const confirm = resolved.handoffs === "confirm";
  const repoBasename = teamPrefix(resolved.cwd, resolved.team);
  const needsPeerConfirmation = ROLES.some(
    (role) =>
      PEER_ELIGIBLE_ROLES.includes(role) && resolved.roles[role].dispatch === "peer" && resolved.roles[role].peer === "auto"
  );
  const lines = [
    "Agent hierarchy ACTIVE. You are the Orchestrator: decompose, dispatch, synthesize — do not design or implement non-trivial changes yourself.",
    "",
    "Roles — dispatch route per role below: peer session via SendMessage, or always a spawned subagent. Legwork (Task-Runner) always spawns or delegates to task-gopher; pass `model` on the Agent call — agent frontmatter is fallback only. Role with a peer target: SendMessage it first when ListAgents shows it running (Ultra-Advisor's peer route gated exactly like its subagent route — item 7), else the subagent. No peer target → always the subagent:",
    ...roleLines(resolved.roles, repoBasename),
    "",
    ...(needsPeerConfirmation ? [peerConfirmationParagraph(repoBasename), ""] : []),
    "PEER BRIEF CONTRACT — a peer session is an independent Claude session: unlike a subagent, NOTHING returns its result to you automatically; a peer that finishes goes idle without telling you unless the brief itself obliges it to report. Every SendMessage that tasks a role peer must:",
    "- Open with the sentinel line `[hierarchy-peer-brief reply-to=\"sender\" task=\"<short-slug>\"]`. reply-to=\"sender\" = the peer replies to the delivery-envelope address: your message arrives wrapped as `<cross-session-message from=\"...\">`; copying that `from` into the reply's `to` is the reliable route (the sender is often NOT in the peer's ListAgents — never rely on that). Explicit `reply-to=\"<name> [ref]\"` only to redirect the report to a third session.",
    "- Next line: `[hierarchy-msg <request path>]` — the brief lives in the message file (item 12); set its `to_name:` to the peer's session name.",
    "- Same self-contained brief a subagent would get (spec path, task, constraints) — the peer shares none of your context.",
    "- End with an explicit report-back order: the exact report expected (same as the role's subagent form); the reply rule restated in prose (copy this message's wrapper `from` into the SendMessage `to`); and plainly: task NOT COMPLETE until that report is sent back via SendMessage — finishing silently strands the caller.",
    "- No reply and ListAgents shows the peer idle → ping ONCE (\"you owe a report on task <slug> — SendMessage it back to the sender\"); still silent → dispatch the role's subagent and tell the user the peer stalled.",
    "",
    "Protocol (hard default, not a preference):",
    ...(confirm
      ? [
          "0. Handoff gate — user chose per-handoff approval (config handoffs:\"confirm\"). Before dispatching Ultra-Advisor, Architect, Implementor, or Reviewer — review-loop re-dispatches included — read that role's dispatch line in Roles above. No peer target (subagent-only) → skip ListAgents for it; offer \"Dispatch <role> (Recommended)\", \"Do it inline yourself\", \"Skip this step\". Peer target named → ListAgents first: is that session present? Then AskUserQuestion naming the role, its model, one line on what you hand it. Peer listed → offer \"Task peer \\\"<name>\\\" via SendMessage (Recommended)\", \"Dispatch <role> subagent instead\", \"Do it inline yourself\", \"Skip this step\", in that order. Peer target but not listed → drop the peer option for this dispatch; offer the subagent-only three. Filter peer-vs-subagent options by this session's route (item 13): \"peers\" → peer option only, no subagent option; \"subagents\" → subagent option only, no peer option even if listed; \"prefer-peers\" → both, peer first. This item decides only WHETHER to hand off — the route decides HOW, asked once, not per dispatch. Ultra-Advisor: both routes equally gated by item 7's PreToolUse approval gate (it watches SendMessage to the Ultra-Advisor peer as it watches Agent/Task) — the peer option never skips user approval. Ask per dispatch, not per plan; never re-ask a dispatch already approved. Legwork (Task-Runner / task-gopher) exempt — errands are not handoffs. \"Task peer\" = SendMessage that peer the same self-contained brief a subagent gets, then await its reply as you would a subagent's completion; the brief must follow the PEER BRIEF CONTRACT above — a peer not ordered to report back does the work and goes idle silently. \"Do it inline\" = you take that role's contract for that step. \"Skip\" = the step does not happen; say plainly what that leaves undesigned or unverified.",
        ]
      : []),
    "1. Gate: binds the top-level Orchestrator only. Role agents never spawn ultra-advisor/architect/reviewer/implementor. They MAY dispatch task-gopher for legwork — that is not recursion.",
    "2. Scope: the chain governs changes. Analysis, debugging, research → Architect (design reasoning) or Task-Runner (retrieval) alone — no Reviewer without a diff. Never dispatch Architect or Ultra-Advisor when the deliverable is only writing, recording, or persisting something you already know — a memory entry, a status note, a file update with no open design question: no reasoning content → do it yourself, or hand the mechanical write to Task-Runner or Implementor. Architect/Ultra-Advisor = reasoning that produces new judgment, never the write step alone.",
    "3. Tiers: trivial (one blind Edit, no verification — typo, config value) → yourself. Determined (request fixes the spec; no design choices left) → Implementor, then Reviewer. Everything else → Architect → spec → Implementor → Reviewer; Ultra-Advisor ahead of the Architect when an item 7 trigger fires.",
    `4. Spec handoff: one unique absolute spec path — default \`${hierDir ? join(hierDir, "specs") : "<hierarchy dir>/specs"}/<slug>.md\` — dictated in the Architect's prompt; same path to Implementor and Reviewer. Dispatches are self-contained — subagents share no context.`,
    "5. Living spec: Implementor reports a spec gap, or a deviation is agreed → amend the spec file (yourself, or re-dispatch the Architect for design questions) BEFORE the Reviewer runs. The Reviewer always validates against the current spec.",
    "6. Review loop: Reviewer classifies each finding impl-defect or spec-defect. Impl-defect → Implementor; spec-defect → Architect. Max 2 round-trips; findings still open after that → escalate to Ultra-Advisor, not another loop, then surface its verdict to the user.",
    `7. Ultra-Advisor — escalation apex, never a routine step. Reasons and adjudicates; never implements. Dispatch ONLY when: the user says the problem is hard, important, or high-stakes, or asks for a second opinion; the Architect reports low confidence or a fork it could not resolve; the review loop hits item 6's cap; or the change carries outsized blast radius (security, auth, data migration, concurrency, a public interface, anything hard to reverse). Give it the same absolute spec path plus the specific question. Its answer is authoritative: fold it into the spec before the Implementor runs again. Never escalate because a task feels large — size is the Architect's job. ${gateSentences(sessionId)}`,
    "8. Task-Runner: prefer `task-gopher:task-gopher`; that agent type unavailable → `ah:task-runner`. task-gopher's on/off toggle controls only its directive, not the agent — delegation works either way.",
    "9. Skills and commands override: a skill mandating a different flow (tdd, diagnose, review) wins over this protocol for its scope.",
    `10. Flow control — handoffs are currently "${resolved.handoffs}"${confirm ? " (ask before each reasoning-role dispatch, per item 0)" : " (you advance the chain yourself and report)"}. The user owns this switch and may flip it AT ANY TIME, either direction, just by telling you — "ask me before handoffs", "stop asking", or /hierarchy flow auto|confirm. Then: update the "handoffs" key in the most specific agent-hierarchy.json that exists (project if present, else user) with the Write tool, preserving every other key; confirm in one line; honor the new mode immediately for the rest of this session — no restart.`,
    "11. Evidence loop — YOU keep the roles in their lanes. The Architect reasons and designs; it never executes — no tests, builds, or experiments, direct or via a runner (Bash is denied to it). (a) Dispatch it with design questions only: never fold \"and verify it works\" into an Architect prompt. (b) Its report or spec carries NEEDS-EVIDENCE items → route that gruntwork to the Implementor (write/run/measure, at implementation rates; Task-Runner for a pure run-and-report), then re-dispatch the Architect with the results and the same spec path. (c) The Reviewer likewise reasons only: it reads diffs itself (read-only git is its instrument) but MUST delegate every execution — suites, builds, repro scripts — to task-gopher and judge the compact report; its Bash is for inspection, never for running. (d) A role's report shows it did another role's work — an Architect that ran tests, a Reviewer that ran a suite itself, an Implementor that redesigned → do not accept that part: note the overstep, route the work to the role that owns it. Reasoning-tier tokens buy judgment, not gruntwork; enforcing that split is YOUR job, not the roles' goodwill.",
    ...protocolItems1214(resolved, hierDir, model, route, sessionId),
  ];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/** One-line setup nudge for an unconfigured top-level session. */
export function buildNudge(resolved) {
  const lines = ["agent-hierarchy is installed but not configured — run `/hierarchy init` to assign a model to each role."];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/**
 * The SessionStart injection for a top-level `claude --agent <role>` session.
 *
 * Such a session IS the main session, so the Orchestrator directive would
 * otherwise reach it — and a role told it is the Orchestrator starts
 * dispatching instead of doing its own work. This says the opposite, in three
 * sentences. It deliberately carries no role→model table and no protocol: the
 * role's own `agents/*.md` body is the whole contract here.
 */
export function buildRoleSessionNotice(role, agentType) {
  return [
    `You are running as \`${agentType}\` as the MAIN session of this Claude Code instance, launched with \`--agent\`.`,
    "The agent-hierarchy Orchestrator protocol does NOT apply to you: do not decompose-and-dispatch, and do not treat yourself as the top of the chain.",
    `Your ${ROLE_LABELS[role] || role} contract in \`agents/*.md\` governs.`,
    "If a message tasks you as a peer (it opens with `[hierarchy-peer-brief reply-to=...]`), the work is not finished until you have sent your report back via SendMessage to that reply-to address — completing the task and going idle without replying strands the session that tasked you.",
    `You are a peer ${ROLE_LABELS[role] || role}. Briefs arrive as [hierarchy-msg <path>]; read via grep '^## \\[' then Read; reply with a response file (node "${MSG_CLI}" new --type response --id <id> --req <that request path>) and [hierarchy-msg <path>] first line.`,
  ].join(" ");
}

/** Human-readable resolved table for `/hierarchy status` and the wizard's echo. */
export function statusReport(cwd) {
  const resolved = resolveConfig(cwd);
  const out = [];
  const userPath = userConfigPath();
  const projectPath = projectConfigPath(cwd);
  const seen = Object.fromEntries(resolved.layers.map((l) => [l.scope, l.path]));

  out.push(`ah: ${!resolved.configured ? "NOT CONFIGURED" : resolved.enabled ? "ON" : "OFF (enabled:false)"}`);
  out.push(`user config:    ${seen.user || `${userPath} (none)`}`);
  out.push(`project config: ${seen.project || `${projectPath || "(unknown cwd)"} (none)`}`);
  out.push(
    `handoff flow:   ${resolved.handoffs} ${resolved.handoffs === "confirm" ? "(ask before each reasoning-role dispatch)" : "(automatic handoffs)"} — from ${resolved.handoffsSource}; switch anytime with /hierarchy flow or by asking the Orchestrator`
  );
  out.push(
    "ultra gate:     the first Ultra-Advisor escalation each session needs your approval — /hierarchy gate to view or change it (session-scoped; resets next session)"
  );
  out.push("");
  out.push("Resolved effective table:");
  out.push(`  Orchestrator  ${"session model".padEnd(14)} fixed (this session's agent)`);
  const aliasInfo = teamPrefixInfo(resolved.cwd, resolved.team);
  const repoBasename = aliasInfo.prefix;
  for (const role of ROLES) {
    const entry = resolved.roles[role];
    const model = entry.model === "inherit" ? "inherit*" : entry.model;
    const peers = resolvedPeerTargets(role, entry, repoBasename);
    const dispatch = PEER_ELIGIBLE_ROLES.includes(role) ? (peers.length ? `dispatch: peer ${peers.map((p) => `"${p}"`).join(" / ")}` : "dispatch: subagent-only") : "";
    out.push(
      `  ${ROLE_LABELS[role].padEnd(13)} ${model.padEnd(14)} from ${resolved.sources[role].padEnd(8)} -> ${subagentType(role, entry)}${dispatch ? `  [${dispatch}]` : ""}`
    );
  }
  out.push("");
  out.push("* inherit = omit the `model` parameter on the Agent call (never pass \"inherit\").");
  out.push("");
  if (resolved.roster) {
    const r = resolved.roster;
    out.push(`Roster: level=${r.level} route=${r.route} path=${r.path}`);
    for (const m of r.members) {
      // spec 0021: default ("prompt") is resolved here at the display site, not stamped onto the
      // member — literal, not imported, to avoid a lib-roster.mjs -> lib-config.mjs import cycle
      // (lib-roster.mjs already imports ROLES/VALID_MODELS_BY_ROLE from this file).
      const onMissingDefaulted = m.onMissing === undefined || m.onMissing === null;
      const onMissingEffective = onMissingDefaulted ? "prompt" : m.onMissing;
      // §3.3: name the reason, not a bare "(inert)" — non-peer-eligible role and subagent route are
      // two different causes with two different fixes.
      // Spec 0043 §1.3: `pane` keeps on-missing's spawn-selection meaning but has no
      // peer-fallback meaning (nothing to fall back TO), so it gets its own wording rather
      // than reusing the subagent one, which would read as "this setting does nothing".
      const effRoute = m.route || r.route;
      const onMissingTag = !PEER_ELIGIBLE_ROLES.includes(m.role)
        ? " (inert: role is not peer-eligible)"
        : effRoute === "subagent"
          ? " (inert: route is subagent)"
          : effRoute === "pane"
            ? " (selects which member to spawn; no peer fallback on route pane)"
            : onMissingDefaulted
              ? " (default)"
              : "";
      out.push(
        `  ${m.name.padEnd(24)} ${ROLE_LABELS[m.role] || m.role} kind=${resolveKind(m)} model=${m.model || "?"} effort=${m.effort || "-"} route=${effRoute} auto-mode=${m.autoMode || "-"} on-missing=${onMissingEffective}${onMissingTag}`
      );
    }
  } else {
    out.push("Roster: none configured — /agent-roster init to define one (roles/route above stay in effect).");
  }
  out.push(
    aliasInfo.alias
      ? `Team alias: ${aliasInfo.alias} (from ${aliasInfo.source}) — agents named ${aliasInfo.alias}-<role>`
      : `Team alias: none — agents named ${aliasInfo.prefix}-<role>`
  );
  if (resolved.rosterLevel === "global") {
    out.push("  — GLOBAL roster; confirmation required before dispatching to its members (spec 0009 §4).");
  }
  const userScopeRoles = ROLES.filter((role) => resolved.sources[role] === "user");
  if (userScopeRoles.length) {
    out.push(`  — role config for ${userScopeRoles.map((role) => ROLE_LABELS[role]).join(", ")} comes from user scope; confirmation required (spec 0009 §4).`);
  }
  out.push(`Stand up one missing peer: node "${ROSTER_CLI}" spawn-one <role> --cwd ${resolved.cwd}. Full-team Create is the /agent-team skill's job — do not hand-assemble create calls.`);
  let team = null;
  try {
    team = readTeam(hierarchyDir(resolved.cwd));
  } catch {
    team = null;
  }
  out.push(team ? `Team: ${team.team_id} (${team.transport}, ${team.members.length} member(s)${team.partial ? ", partial" : ""})` : "Team: none active — /agent-team create to instantiate the roster");
  if (resolved.shadowed.length) {
    out.push(`WARNING: project config shadows user-scope values for: ${resolved.shadowed.join(", ")}.`);
  }
  for (const warning of resolved.warnings) out.push(warning);
  out.push("Changes apply to this session now; other live sessions pick them up at their next start, clear, or compaction.");
  return out.join("\n");
}

// Run directly: print the status table for the current working directory.
if (process.argv[1] && resolve(process.argv[1]).endsWith("lib-config.mjs")) {
  process.stdout.write(statusReport(process.cwd()) + "\n");
}
