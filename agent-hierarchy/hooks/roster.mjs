#!/usr/bin/env node
/**
 * agent-hierarchy — the CLI behind both /agent-roster (roster template) and
 * /agent-team (live team): deterministic roster + team file I/O.
 * Modelled on msg.mjs. Interactive prompting (AskUserQuestion, ListAgents
 * polling, actually spawning sessions) is the SKILL.md's job; this CLI does
 * validation and reads/writes only, so validation lives in one place.
 *
 *   roster.mjs show   [global|repo|repo-user] [--level L] [--roster <r>] [--cwd <path>]
 *   roster.mjs init    [level] [--level L] --route <peer|subagent> [--roster <r>] [--cwd <path>]
 *   roster.mjs add     [level] [--level L] [--roster <r>] --role <R> [--model M] [--effort E]
 *                       [--route peer|subagent|pane] [--kind K] [--args '<json>'] [--auto-mode A]
 *                       [--on-missing auto|prompt|never] [--cwd <path>]
 *                       (spec 0044 §1.10: writes the roster template and spawns NOTHING —
 *                        supersedes spec 0039's auto-spawn. Use spawn-one, or spawn-ad-hoc.)
 *   roster.mjs edit    [level] [--level L] [--roster <r>] --member <NAME> [--role R] [--model M]
 *                       [--effort E] [--route ...] [--auto-mode A] [--on-missing auto|prompt|never] [--cwd <path>]
 *                       (--model "" and --effort "" clear the field)
 *   roster.mjs remove  [level] [--level L] [--roster <r>] --member <NAME> [--cwd <path>]
 *   roster.mjs create  [--plan] [--commit --verified <json> --transport <t>
 *                       (--verified: JSON array of member objects from the spawn/check-in
 *                       cycle, OR a JSON array of member-name strings hydrated from the
 *                       --roster-level roster)
 *                       --roster-level <L> [--partial (accepted, ignored: partial is derived)]
 *                       [--orchestrator-pid <pid>]] [--cwd <path>]
 *   roster.mjs create  --spawn [--roster-level <L>] [--cwd <path>]
 *                       (every create phase takes [--team <T>], the team's name — default the
 *                       repo basename; [--roster <r>], build from `rosters.<r>` — default the
 *                       `roster` block; [--mode <auto|columns|grid>], the team's layout — an
 *                       explicit --mode on --spawn/--commit is stored as the default for future teams;
 *                       and [--member-model <name>=<model>], repeatable, the model a member runs on
 *                       this time, which --spawn requires for every launched member with none stored.
 *                       A legwork member with no model is skipped while task-gopher is installed:
 *                       `skipped_members` lists it, and its work goes to task-gopher subagents.
 *                       [--no-legwork-handoff] counts task-gopher as not installed, for a driver that
 *                       cannot dispatch it; [--names-in-use <name>], repeatable, a live session name
 *                       a member's derived name is renamed away from)
 *   (`--spawn` launches only; `--commit` persists. Both are required, in that order.)
 *   roster.mjs next-split --mode <auto|columns|grid> --pane-count <N> --self <pane-id>
 *                       --created '<json array of pane ids>'
 *                       --geometry '<json array of {pane_id, rect}>'
 *   roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>]
 *                       (or --next --created <json>, or --apply --target <id> --direction <right|down>)
 *   roster.mjs disband [--plan] [--cwd <path>] [--team <T>]
 *   roster.mjs disband --close --confirm --plan-token <tok> [--allow-global] [--cwd <path>] [--team <T>]
 *   roster.mjs dismiss <name> [--plan] [--cwd <path>] [--team <T>]
 *   roster.mjs dismiss <name> --close --confirm --plan-token <tok> [--also-config] [--level L]
 *                       [--allow-global] [--cwd <path>] [--team <T>]
 *   roster.mjs resync  [--dry-run] [--cwd <path>]
 *   roster.mjs move    <name> --tab <tab_id> [--split right|down]
 *                       <name> --new-tab [--workspace <id>]
 *                       <name> --new-workspace
 *                       [--dry-run] [--cwd <path>]
 *   roster.mjs spawn-one <role> [--member <name>] [--model M] [--team <T>] [--cwd <path>] [--dry-run]
 *                       [--allow-global] [--orchestrator-pid <pid>] [--names-in-use <name>]
 *                       (--model: required when the member has no model stored; this launch only)
 *                       (--team names the team to join; an unknown name creates that scope —
 *                        no separate create step, and nothing to ask about.)
 *   roster.mjs spawn-ad-hoc <role> [--model M] [--effort E] [--route peer|pane] [--kind K]
 *                       [--args '<json>'] [--auto-mode A] [--on-missing ...] [--team T]
 *                       [--dry-run] [--allow-global] [--orchestrator-pid <pid>] [--names-in-use <name>]
 *                       [--cwd <path>]
 *                       (spec 0044 §1.4: spawn a member the roster does not define, or one whose
 *                        parameters diverge from it. Writes ONLY the team file — never the roster.)
 *   roster.mjs teams   [--cwd <path>] [--orchestrator-pid <pid>]
 *   roster.mjs reap    [--commit] [--cwd <path>]
 *                       (bare: lists orphaned team records — dead/null orchestrator pid,
 *                       age never a factor — and deletes nothing; --commit removes them.)
 *   roster.mjs history [--cwd <path>]
 *   roster.mjs create  --from <id|alias> [--team <T>] [--plan|--commit|--spawn] [--cwd <path>]
 *   roster.mjs adopt   --orchestrator-pid <pid> [--team <T>] [--cwd <path>]
 *   roster.mjs checkin [--team <T>] [--cwd <path>] [--orchestrator-pid <pid>]
 *   roster.mjs whoami  [--team <T>] [--cwd <path>]
 *                       Read-only: which team member this session's pane is, and its
 *                       orchestrator's pid / liveness / best-effort reply address.
 *   roster.mjs doctor [--cwd <path>] [--check]
 *                       Read-only self-check: one JSON object, one row per thing that can be
 *                       wrong. `--check` exits 1 when any row is red. Writes nothing, ever.
 *                       (spec 0036 §3.3: re-registers the current session with its current cwd;
 *                       exits non-zero when still misplaced relative to the team's expected_root.
 *                       Resolves the session pid the same way as create --commit/teams — process.ppid
 *                       is the transient Bash-tool shell, never the session, at this call site.)
 *
 * Spec 0044: the roster is a read-only TEMPLATE for the whole team lifecycle. `init`/`add`/`edit`/
 * `remove`/`layout`/`alias` write roster level files and spawn nothing; every other command writes
 * only a team file. A session that owns a live team is refused a roster edit (§1.3) unless the USER
 * passes `--allow-roster-edit` — no code path may supply that flag on the user's behalf. A team with
 * no `--team` lives at `teams/<effective-prefix>.json`, not the shared `team.json`; an existing
 * `team.json` keeps being used, unmigrated, until its own team disbands (§1.7).
 *
 * `--team <name>` (spec 0011 §5.1) selects a named team's `teams/<name>.json`
 * in place of the default `team.json`, on every subcommand above that touches
 * a team file; omitted, everything resolves the default team exactly as
 * before. `create --team <T>` (§5.2) writes `teams/<T>.json`.
 *
 * `--level`/the positional bare word are equivalent; `add`/`edit`/`remove`
 * with neither default to the level the roster currently resolves from
 * (repo-user > repo > global) and print which level they chose.
 *
 * `create` is two-phase, both file-I/O-only: `--plan` (default) resolves the
 * roster, refuses a live Team, clears a stale one, and reports the transport
 * plus each member's derived name and spawn shape — it spawns nothing.
 * `--commit` persists a Team the caller (the SKILL.md flow) has already
 * spawned and verified via ListAgents, writing team.json.
 *
 * `resync` re-derives every peer member's herdr location from herdr's own live
 * topology and rewrites team.json; `move` executes a `herdr pane move` then
 * resyncs that one member. Bare `disband`/`--plan` also resyncs first, in
 * memory only (no write) — see docs/specs/0008-roster-relocate.md.
 */

import { accessSync, constants as fsConstants, existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

import { AGENT_REF_RE, agentRefError, hierarchyNameParts as parseNameParts, chainRoles, checkCustomRow, CLASSES, classBuiltin, classProp, customRoleNames, defaultLabel, DISPATCH_MODES, formatFindings, hasContractErrors, isAlternative, isBuiltinRole, isOverride, locateAgentFile, registryRoles, roleAgent, roleClass, ROLE_LABELS, roleLabel, validateAgentContract, validateRole, CONFIG_VERSION, findGitRoot, hierarchyDir, mainHierarchyDir, peerName, pluginVersion, recentHookErrors, resolveConfig, statusReport, HOOK_ERROR_LOG, ROLES, ROSTER_LEVELS, resolveRoster, rosterLevelPaths, rosterMemberNames, namedRosterKeys, normalizeRosterBlock, dropNonObjectMembers, legworkHandedOff, rosterBlocksOf, staleTeamKeys, TASK_GOPHER, STALE_ROUTE_VALUES, suggestTeamAlias, teamLayoutPreference, teamPrefix, teamPrefixInfo, tierOf, validateHerdrName, validateTeamAlias } from "./lib-config.mjs";
import { ageSecOf, appendRosterRecord, attributedRoster, fmtAge, latestRoster, livePeerSlots, peersPath, readJsonl, newId, localIso, NO_TEAM_SCOPE, pidAlive, realCwd, recordLiveness, synthesizedPeerName } from "./lib-hier.mjs";
import { readPeerRecords } from "./lib-peer.mjs";
import { attributeSessionTeam, clearTeam, defaultTeamScope, envTeamFile, fingerprint, herdrOnPath, historyEntryIsActive, KIND_AUTO_MODE_ARGS, KIND_DEFAULT, kindAutoModeArgs, kindFieldErrors, listTeamNames, memberArgs, memberNamePrefix, normalizeMembers, readHistory, readTeam, resolveKind, resolveTeamByPane, ROSTER_LAYOUT_VALUES, ROSTER_ROUTE_VALUES, routeHasPane, teamFileState, teamIsLive, teamIsOrphaned, teamMemberNameSet, teamOwnedBy, teamPath, teamRosterKey, upsertHistory, validateMember, validateRosterBlock, validateTeamMember, writeTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "plan", "commit", "partial", "manual", "next", "apply", "kill", "keep-sessions", "spawn", "dry-run", "new-tab", "new-workspace", "allow-global", "clear", "close", "confirm", "also-config", "no-spawn", "allow-roster-edit", "no-legwork-handoff"]);
const DISBAND_FLAGS = new Set(["kill", "plan", "close", "confirm", "plan-token", "allow-global", "cwd", "team"]);
// Spec 0046 §3: tracking-only removal moved OFF dismiss/disband and onto its own verb, so the
// destructive verbs cannot be reached with a flag that quietly means "do not close anything".
const UNTRACK_FLAGS = new Set(["all", "plan", "commit", "keep-sessions", "also-config", "level", "cwd", "team"]);
const DISMISS_FLAGS = new Set(["plan", "close", "confirm", "plan-token", "also-config", "level", "allow-global", "cwd", "team"]);
const RESYNC_FLAGS = new Set(["dry-run", "cwd", "team", "bind"]);
const MOVE_FLAGS = new Set(["tab", "split", "new-tab", "workspace", "new-workspace", "dry-run", "allow-global", "cwd", "team"]);
const SPAWN_ONE_FLAGS = new Set(["cwd", "dry-run", "allow-global", "team", "orchestrator-pid", "member", "model", "names-in-use"]);
/** Spec 0044 §1.4: the member-spec flags `add` takes, plus the spawn-side ones `spawn-one` takes.
    No `--level` and no `--member`: an ad hoc member has no roster level to land in, and its name
    is derived (point 5), never supplied. */
const AD_HOC_FLAGS = new Set(["role", "model", "effort", "route", "kind", "args", "auto-mode", "on-missing", "cwd", "dry-run", "allow-global", "team", "orchestrator-pid", "names-in-use"]);
/** Spec 0044 §1.2/§1.3: the commands whose PURPOSE is writing a roster level file. The same list
    §1.5 classifies as legitimate roster writers and §8.1 puts on the `/agent-roster` surface —
    one list, so the gate and the surface split cannot drift apart. */
const ROSTER_MUTATING_CMDS = new Set(["init", "add", "edit", "remove"]);
const ADOPT_FLAGS = new Set(["orchestrator-pid", "team", "cwd"]);
const REAP_FLAGS = new Set(["commit", "cwd"]);
const CHECKIN_FLAGS = new Set(["cwd", "team", "orchestrator-pid"]);
const WHOAMI_FLAGS = new Set(["cwd", "team"]);
/** Verbs that can create a team, and so check the name it would get. */
const TEAM_CREATING_VERBS = new Set(["create", "spawn-one", "spawn-ad-hoc"]);
/** Team-side verbs that, given no --team, act on the team the invoking session owns before any default. */
const OWNED_TEAM_VERBS = new Set(["create", "spawn-one", "spawn-ad-hoc", "dismiss", "disband", "untrack", "resync", "move"]);

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (!BOOL_FLAGS.has(key) && next !== undefined && !next.startsWith("--")) {
        opts[key] = next;
        i++;
      } else {
        opts[key] = true;
      }
    } else {
      opts._.push(a);
    }
  }
  return opts;
}

function fail(msg) {
  process.stderr.write(`roster.mjs: ${msg}\n`);
  process.exit(2);
}

/** Every stale key this invocation's config writes migrated: `{path, key, from, to}`, `to` null
    for a deletion. The verb's output carries it. */
const migratedKeys = [];

function out(obj) {
  const payload = migratedKeys.length && obj && typeof obj === "object" && !Array.isArray(obj) ? { ...obj, migrated: migratedKeys } : obj;
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
}

/** A partial layout-splits result: real work happened, but not all of it. Bypasses the outer try/catch. */
function partial(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + "\n");
  process.exit(3);
}


const OWN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

/**
 * One doctor row. `fn` may throw or hit missing/garbage files — the row degrades to `warn` with the
 * message instead, because a self-check that dies on the first surprise is the one thing it must
 * never do.
 */
function row(name, fn) {
  try {
    const r = fn();
    return { name, status: r.status, detail: r.detail };
  } catch (err) {
    return { name, status: "warn", detail: `check failed: ${err && err.message ? err.message : String(err)}` };
  }
}

/** The installPath the plugin manager records for this plugin, or null when nothing readable says. */
function recordedInstallPath() {
  const raw = JSON.parse(readFileSync(join(homedir(), ".claude", "plugins", "installed_plugins.json"), "utf8"));
  const plugins = raw && typeof raw === "object" ? raw.plugins || {} : {};
  const key = Object.keys(plugins).find((k) => /^(ah|agent-hierarchy)@/.test(k));
  if (!key) return null;
  // The value is an ARRAY of install records, one per marketplace that supplies the plugin.
  const first = [].concat(plugins[key])[0];
  return first && typeof first.installPath === "string" ? first.installPath : null;
}

function gitPorcelain(dir) {
  return execFileSync("git", ["status", "--porcelain"], { cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
}

/** Read-only state report: rows a human or an agent can read in one pass. Writes nothing. */
// ---------------------------------------------------------------- role verbs (custom roles)

const ROLE_FLAGS = new Set(["class", "agent", "label", "description", "routes", "model", "dispatch", "level", "scaffold", "dry-run", "json", "cwd"]);

/** resolveConfig's scope names → roster level names. */
function levelOfScope(scope) {
  return { user: "global", project: "repo", "repo-user": "repo-user", default: "shipped" }[scope] || scope || null;
}

/** One `role list` row per registry role, with its contract status (validated for custom rows and overrides). */
function roleRows() {
  const reg = registry();
  return registryRoles(reg).map((role) => {
    const entry = reg.roles[role];
    const builtin = isBuiltinRole(role);
    const cls = roleClass(role, reg);
    let v = null;
    try {
      v = validateRole(role, reg);
    } catch (err) {
      v = { findings: [{ level: "error", code: "agent-not-found", path: null, field: null, message: String(err && err.message), fix: [{ kind: "create-file", detail: "check the agent file" }] }], description: { text: null, source: null }, file: { found: null } };
    }
    const errors = v ? v.findings.filter((f) => f.level === "error").length : 0;
    const warns = v ? v.findings.length - errors : 0;
    const status = !v
      ? "shipped"
      : errors
        ? builtin ? `UNAVAILABLE → reverted to ah:${role}` : `UNAVAILABLE: ${errors} error${errors > 1 ? "s" : ""}`
        : warns ? `${warns} warning${warns > 1 ? "s" : ""}` : "ok";
    const placement = !CLASSES[cls].chain
      ? "legwork"
      : isAlternative(role, entry)
        ? `alt. to ${ROLE_LABELS[classBuiltin(cls)]}: ${entry.routes}`
        : builtin ? `built-in · ${CLASSES[cls].step}` : "side";
    return {
      name: role,
      builtin,
      class: cls,
      label: roleLabel(role, reg),
      agent: roleAgent(role, entry),
      model: entry.model,
      level: levelOfScope(reg.sources[role]),
      placement,
      description: v ? v.description.text : null,
      description_source: v ? v.description.source : null,
      status,
      path: v ? v.file.found : null,
      findings: v ? v.findings : [],
    };
  });
}

function roleList() {
  const reg = registry();
  const roles = roleRows();
  const excluded = reg.excludedRoles.map((e) => ({ name: e.name, level: levelOfScope(e.scope), path: e.path, reason: e.reason }));
  if (opts.json === true) return out({ roles, excluded });
  const lines = roles.map(
    (r) => `${r.name.padEnd(20)} ${r.builtin ? "built-in" : "custom  "} ${r.class.padEnd(9)} ${r.agent.padEnd(26)} ${String(r.model).padEnd(8)} ${String(r.level).padEnd(9)} ${r.placement} — ${r.status}${r.description ? ` — "${r.description}" (${r.description_source})` : ""}`
  );
  for (const e of excluded) lines.push(`EXCLUDED ${e.name} (${e.level}, ${e.path}): ${e.reason}`);
  process.stdout.write(`${lines.join("\n")}\n`);
}

/** The row to seed `role set` from when its level has none: the effective row, minus defaults. */
function seedRow(name, entry) {
  const seed = {};
  for (const [k, v] of Object.entries(entry)) {
    if (k === "effectiveDescription") continue;
    if (k === "dispatch" && v === "peer") continue;
    if (k === "peer" && v === "auto") continue;
    if (!isBuiltinRole(name) && k === "agent" && v === name) continue;
    if (!isBuiltinRole(name) && k === "label" && v === defaultLabel(name)) continue;
    seed[k] = Array.isArray(v) ? [...v] : v;
  }
  return seed;
}

/** A minimal agent file that passes its class contract: no tools allowlist, and the class's forbidden plus discouraged tools disallowed. */
function scaffoldText(agent, cls, label, description, routes) {
  const c = CLASSES[cls];
  const disallowed = c.contract ? [...c.contract.forbidden, ...c.contract.discouraged] : [];
  const standIn = routes ? `, standing in for the ${ROLE_LABELS[classBuiltin(cls)]} for: ${routes}` : "";
  return [
    "---",
    `name: ${agent}`,
    `description: ${JSON.stringify(description)}`,
    ...(disallowed.length ? [`disallowedTools: ${disallowed.join(", ")}`] : []),
    "---",
    "",
    `You are the ${label}, an agent-hierarchy role of class ${cls}${standIn}. The hierarchy contract you receive at session or subagent start governs your protocol; this file adds your specialisation.`,
    "",
    "## Specialisation",
    "",
    "<!-- Replace this line with what this role specialises in. -->",
    "",
  ].join("\n");
}

function roleSet(name) {
  if (typeof name !== "string" || !name) fail("role set needs a role name: role set <name> [flags]");
  const reg = registry();
  const builtin = isBuiltinRole(name);
  const dry = opts["dry-run"] === true;
  const given = { class: opts.class, agent: opts.agent, label: opts.label, description: opts.description, routes: opts.routes, model: opts.model, dispatch: opts.dispatch, scaffold: opts.scaffold, level: opts.level };
  for (const [k, v] of Object.entries(given)) {
    if (v === true) fail(`role set: --${k} needs a value`);
  }
  if (builtin) {
    for (const k of ["class", "label", "description", "routes", "scaffold"]) {
      if (given[k] !== undefined) fail(`role set ${name}: --${k} does not apply to a built-in role — only --agent, --model and --dispatch`);
    }
  }
  // Default: where the row already lives (a write elsewhere would be shadowed
  // or would shadow it), else beside a repo scaffold, else global.
  const defined = levelOfScope(reg.sources[name]);
  const level = typeof opts.level === "string" ? requireLevel(opts.level)
    : defined && defined !== "shipped" ? defined
    : given.scaffold === "repo" ? "repo" : "global";
  const path = rosterLevelPaths(cwd)[level];
  const data = readLevelFile(path);
  const layerRoles = data.roles && typeof data.roles === "object" && !Array.isArray(data.roles) ? data.roles : null;
  const atLevel = layerRoles && layerRoles[name] && typeof layerRoles[name] === "object" && !Array.isArray(layerRoles[name]) ? layerRoles[name] : null;
  const row = atLevel ? { ...atLevel } : reg.roles[name] ? seedRow(name, reg.roles[name]) : {};
  for (const k of ["class", "agent", "label", "model", "dispatch"]) if (typeof given[k] === "string") row[k] = given[k];
  for (const k of ["description", "routes"]) {
    if (typeof given[k] !== "string") continue;
    if (given[k] === "") delete row[k];
    else row[k] = given[k];
  }
  if (row.dispatch !== undefined && !DISPATCH_MODES.includes(row.dispatch)) fail(`role set ${name}: --dispatch must be one of ${DISPATCH_MODES.join(", ")}`);

  const warnings = [];
  let cls;
  let checked;
  if (builtin) {
    cls = roleClass(name, null);
    if (row.agent !== undefined) {
      const why = agentRefError(row.agent);
      if (why) fail(`role set ${name}: ${why}`);
      if (row.agent.startsWith("ah:") && row.agent !== `ah:${name}`) fail(`role set ${name}: ah:* agents belong to the built-ins`);
    }
    if (row.model !== undefined && !CLASSES[cls].models.includes(row.model)) {
      fail(`role set ${name}: model ${JSON.stringify(row.model)} is not allowed for ${name} (allowed: ${CLASSES[cls].models.join(", ")})`);
    }
    checked = row;
  } else {
    if (!row.class) fail(`role set ${name}: --class is required for a new role (one of ${Object.keys(CLASSES).join(", ")})`);
    const c = checkCustomRow(name, row);
    if (c.error) fail(`role set ${name}: ${c.error}`);
    warnings.push(...c.warnings);
    if (row.routes !== undefined && !CLASSES[row.class].chain) delete row.routes;
    cls = row.class;
    checked = c.row;
  }
  if (given.dispatch === "model" && cls !== "legwork") fail(`role set ${name}: --dispatch model is not allowed for a ${cls} role — only legwork roles run as subagents`);
  const agent = builtin ? roleAgent(name, row) : checked.agent;
  const owner = registryRoles(reg).find((r) => r !== name && roleAgent(r, reg.roles[r]) === agent);
  if (owner) fail(`role set ${name}: agent ${JSON.stringify(agent)} is already the ${owner} role's agent — an agent maps to exactly one role`);
  if (!builtin) {
    const prefix = roleSetPrefix();
    const v = validateTeamAlias(prefix, { roles: { ...reg.roles, [name]: checked } });
    if (!v.ok) fail(`role set ${name}: the team prefix "${prefix}" collides with this role name (${v.why}) — rename the role, or create the team with a different \`--team <name>\``);
    if (checked.routes) {
      const rival = customRoleNames(reg).find((r) => r !== name && reg.roles[r].class === cls && reg.roles[r].routes);
      if (rival) warnings.push(`class ${cls} already has an alternative (${rival}); candidates are tried in name order and the first fit wins`);
    }
  }
  const loc = agent.includes(":") ? null : locateAgentFile(agent, cwd);
  if (!builtin) {
    const prefix = roleSetPrefix();
    const peerName = `${prefix}-${name}`;
    if (!validateHerdrName(peerName).ok) warnings.push(`under the team prefix "${prefix}" its peer name, ${peerName}, is ${peerName.length} characters — Herdr allows at most 32 ([a-z][a-z0-9_-]), so spawning it under Herdr is refused; use a shorter role name, or create the team with a shorter \`--team <name>\``);
  }
  if (level === "repo" && loc && loc.level === "user") warnings.push(`this repo-level row points at ${loc.path}, which exists only in your user agents dir — other users of this repo will not have it`);

  let scaffold = null;
  if (opts.scaffold !== undefined) {
    if (!["repo", "user"].includes(opts.scaffold)) fail("role set: --scaffold must be repo or user");
    if (agent.includes(":")) fail(`role set ${name}: --scaffold cannot write a plugin agent's file (${agent})`);
    const root = findGitRoot(cwd);
    if (opts.scaffold === "repo" && !root) fail("role set: --scaffold repo needs a git repo");
    const file = opts.scaffold === "repo" ? join(root, ".claude", "agents", `${agent}.md`) : join(homedir(), ".claude", "agents", `${agent}.md`);
    if (existsSync(file)) fail(`role set ${name}: --scaffold refuses to overwrite ${file}`);
    const description = checked.description || (checked.routes ? `${checked.label} — ${checked.routes}` : null);
    if (!description) fail(`role set ${name}: --scaffold needs a description — give --description or --routes`);
    scaffold = { path: file, text: scaffoldText(agent, cls, checked.label, description, checked.routes || null) };
  }

  const needsContract = !builtin || isOverride(name, row);
  const validate = (inMemory) =>
    needsContract
      ? validateAgentContract({ role: name, cls, agent, description: builtin ? null : checked.description || null, builtin, cwd, inMemory })
      : null;
  const report = (v) => {
    const findings = v ? v.findings : [];
    if (findings.length) process.stderr.write(`${formatFindings(findings)}\n`);
    for (const w of warnings) process.stderr.write(`roster.mjs: warning — ${w}\n`);
    return {
      level,
      path,
      role: name,
      row,
      agent_file: v ? { path: v.file.found, status: scaffold && dry ? "scaffold (not written)" : v.file.found ? "found" : "not found" } : null,
      description: v ? v.description : null,
      findings,
      warnings,
      scaffold: scaffold ? scaffold.path : null,
    };
  };

  if (dry) return { dry_run: true, ...report(validate(scaffold)) };

  if (scaffold) {
    mkdirSync(dirname(scaffold.path), { recursive: true });
    writeFileSync(scaffold.path, scaffold.text, "utf8");
  }
  const dropScaffold = () => {
    if (!scaffold) return;
    try {
      unlinkSync(scaffold.path);
    } catch {}
  };
  let v;
  try {
    v = validate(null);
  } catch (err) {
    dropScaffold();
    throw err;
  }
  const result = report(v);
  if (v && hasContractErrors(v.findings)) {
    dropScaffold();
    fail(`role set ${name}: the agent file fails the ${cls} contract — nothing was written (findings above)`);
  }
  try {
    writeLevelFile(path, { ...data, version: data.version || CONFIG_VERSION, roles: { ...(layerRoles || {}), [name]: row } });
  } catch (err) {
    dropScaffold();
    throw err;
  }
  return { written: true, ...result };
}

function roleRemove(name) {
  if (typeof name !== "string" || !name) fail("role remove needs a role name");
  const reg = registry();
  const builtin = isBuiltinRole(name);
  const excluded = reg.excludedRoles.find((e) => e.name === name);
  const defined = levelOfScope(reg.sources[name] || (excluded && excluded.scope));
  const level = typeof opts.level === "string" ? requireLevel(opts.level) : defined && defined !== "shipped" ? defined : fail(`role remove ${name}: it is not defined at any level`);
  if (!builtin) {
    const users = [];
    for (const [lvl, p] of Object.entries(rosterLevelPaths(cwd))) {
      const d = readLevelFile(p);
      for (const [label, , b] of rosterBlocksOf(d)) {
        if (!b || !Array.isArray(b.members)) continue;
        b.members.forEach((m, i) => {
          if (m && m.role === name) users.push(`${lvl} ${label} member ${i + 1} (${name})`);
        });
      }
    }
    if (users.length) fail(`role remove ${name}: roster members still use it — ${users.join("; ")}. Remove them first (/ah:agent-roster).`);
  }
  const path = rosterLevelPaths(cwd)[level];
  const data = readLevelFile(path);
  const layerRoles = data.roles && typeof data.roles === "object" && !Array.isArray(data.roles) ? data.roles : null;
  if (!layerRoles || !layerRoles[name]) fail(`role remove ${name}: no row for it at level "${level}" (${path})`);
  if (builtin) {
    if (layerRoles[name].agent === undefined) fail(`role remove ${name}: a built-in role cannot be removed, and it has no agent override at level "${level}"`);
    delete layerRoles[name].agent;
    // An empty row would still shadow a wider level's row for this role under whole-row precedence.
    if (!Object.keys(layerRoles[name]).length) delete layerRoles[name];
  } else {
    delete layerRoles[name];
  }
  writeLevelFile(path, data);
  return { removed: name, level, path, override_only: builtin };
}

function doctorReport(cwd) {
  const rows = [];

  rows.push(row("version", () => ({
    status: "ok",
    detail: `ah ${pluginVersion()} at ${OWN_ROOT}, node ${process.version}`,
  })));

  rows.push(row("install", () => {
    let recorded = null;
    try {
      recorded = recordedInstallPath();
    } catch (err) {
      const cached = OWN_ROOT.includes(join(".claude", "plugins", "cache"));
      return cached
        ? { status: "warn", detail: `installed_plugins.json unreadable (${err.message}) while running from the plugin cache` }
        : { status: "ok", detail: `installed_plugins.json unreadable (${err.message}); running from a local checkout at ${OWN_ROOT}` };
    }
    if (!recorded) return { status: "warn", detail: `no ah@…/agent-hierarchy@… install record found; own root ${OWN_ROOT}` };
    if (realCwd(recorded) === realCwd(OWN_ROOT)) return { status: "ok", detail: `installed path matches own root: ${OWN_ROOT}` };
    return { status: "warn", detail: `stale root in use — installed at ${recorded}, running from ${OWN_ROOT}; take the most recent \`ah CLI root\` line` };
  }));

  rows.push(row("identity", () => {
    const raw = process.env.CLAUDE_PID;
    if (!raw) return { status: "red", detail: "CLAUDE_PID unset — every write verb must be given --orchestrator-pid <pid>" };
    const pid = Number(raw);
    if (!Number.isInteger(pid)) return { status: "red", detail: `CLAUDE_PID is not an integer: ${JSON.stringify(raw)}` };
    return pidAlive(pid)
      ? { status: "ok", detail: `CLAUDE_PID ${pid}, alive` }
      : { status: "red", detail: `CLAUDE_PID ${pid} names no live process` };
  }));

  rows.push(row("runtime-dir", () => {
    const dir = hierarchyDir(cwd);
    const gitRoot = findGitRoot(cwd);
    // A worktree's `.git` is a FILE pointing at the real git dir; state resolution differs there.
    let worktree = false;
    try {
      worktree = !!gitRoot && statSync(join(gitRoot, ".git")).isFile();
    } catch {
      worktree = false;
    }
    const note = worktree ? " (cwd is a git worktree: .git is a file)" : "";
    if (!existsSync(dir)) return { status: "ok", detail: `${dir} does not exist yet — created on first write${note}` };
    try {
      accessSync(dir, fsConstants.W_OK);
    } catch {
      return { status: "red", detail: `${dir} exists but is not writable${note}` };
    }
    return { status: "ok", detail: `${dir} exists and is writable${note}` };
  }));

  rows.push(row("config", () => {
    const resolved = resolveConfig(cwd, { pid: ownOrchestratorPid() });
    const detail = statusReport(cwd).split("\n").slice(0, 4).join(" | ");
    if (!resolved.configured) return { status: "warn", detail: `not configured — ${detail}` };
    // Custom roles: an invalid row is excluded, and a row whose agent fails its class contract is
    // unavailable. Either is a warning, named here so it is visible without reading the directive.
    const roleProblems = resolved.excludedRoles.map((e) => `invalid custom role ${e.name} (${e.reason})`);
    for (const role of registryRoles(resolved)) {
      if (isBuiltinRole(role) && !isOverride(role, resolved.roles[role])) continue;
      const v = validateRole(role, resolved);
      if (v && hasContractErrors(v.findings)) roleProblems.push(`role ${role} is unavailable: its agent fails the ${roleClass(role, resolved)} contract (roster.mjs role list)`);
    }
    if (roleProblems.length) return { status: "warn", detail: `${detail} | ${roleProblems.join("; ")}` };
    return { status: resolved.enabled ? "ok" : "warn", detail };
  }));

  rows.push(row("team", () => {
    const dir = hierarchyDir(cwd);
    const team = readTeam(dir, teamFile);
    if (!team) return { status: "ok", detail: `no team file at ${teamPath(dir, teamFile)}` };
    const pid = team.orchestrator && team.orchestrator.pid;
    const alive = Number.isInteger(pid) && pidAlive(pid);
    const age = team.created_at ? `${fmtAge(ageSecOf(team.created_at))} ago` : "unknown age";
    const live = teamIsLive(team);
    const known = new Set(registryRoles(registry()));
    const orphans = (team.members || []).filter((m) => m && m.role && !known.has(m.role));
    const orphanNote = orphans.length
      ? `; ${orphans.map((m) => `member ${m.name || "(unnamed)"} has role "${m.role}", which is not defined here — it can still be dismissed or disbanded`).join("; ")}`
      : "";
    return {
      status: live && !orphans.length ? "ok" : "warn",
      detail: `team_id ${team.team_id || "?"} , orchestrator pid ${pid ?? "none"} ${alive ? "alive" : "dead"}, created ${age}, live=${live}${orphanNote}`,
    };
  }));

  rows.push(row("peers", () => {
    const recs = readJsonl(peersPath(hierarchyDir(cwd)));
    if (!recs.length) return { status: "ok", detail: "no peers.jsonl records" };
    const byStatus = {};
    let live = 0;
    let dead = 0;
    for (const r of latestRoster(hierarchyDir(cwd))) {
      byStatus[r.status || "?"] = (byStatus[r.status || "?"] || 0) + 1;
      if (Number.isInteger(r.pid) && pidAlive(r.pid)) live++;
      else dead++;
    }
    const counts = Object.entries(byStatus).map(([k, v]) => `${k}=${v}`).join(" ");
    return { status: "ok", detail: `${recs.length} records; latest-per-slot: ${counts}; ${live} live pid(s), ${dead} dead` };
  }));

  rows.push(row("hook-errors", () => {
    const recent = recentHookErrors(24);
    if (!recent.length) return { status: "ok", detail: `no hook errors in the last 24 h (${HOOK_ERROR_LOG})` };
    const last = recent.slice(-5).map((e) => `${e.ts} ${e.hook}: ${e.message}`);
    return { status: "warn", detail: `${recent.length} hook error(s) in 24 h — last ${last.length}: ${last.join(" || ")}` };
  }));

  rows.push(row("hooks-syntax", () => {
    const hooksDir = join(OWN_ROOT, "hooks");
    const broken = [];
    for (const f of readdirSync(hooksDir).filter((f) => f.endsWith(".mjs"))) {
      try {
        execFileSync(process.execPath, ["--check", join(hooksDir, f)], { stdio: ["ignore", "ignore", "pipe"] });
      } catch {
        broken.push(f);
      }
    }
    return broken.length
      ? { status: "red", detail: `node --check fails: ${broken.join(", ")} — every hook in this root is dead until fixed` }
      : { status: "ok", detail: "every hooks/*.mjs parses" };
  }));

  rows.push(row("marketplace", () => {
    if (!existsSync(join(OWN_ROOT, "..", ".git"))) {
      return { status: "ok", detail: "own root is not inside a git checkout — nothing to be dirty" };
    }
    const clone = dirname(OWN_ROOT);
    const dirty = gitPorcelain(clone).split("\n").filter(Boolean).length;
    return dirty
      ? { status: "warn", detail: `${clone} has ${dirty} uncommitted change(s) — hooks run from this tree, so an unfinished edit is live` }
      : { status: "ok", detail: `${clone} is clean` };
  }));

  // Keys that name or lay out a team from config do nothing; this is one of the places a person
  // reading output learns so, and only when there is something to say.
  const stale = staleTeamKeys(cwd, registry()).warnings;
  if (stale.length) rows.push({ name: "stale-config-keys", status: "warn", detail: stale.join(" ") });
  return { cwd, rows, red: rows.filter((r) => r.status === "red").map((r) => r.name) };
}

const all = parseArgs(process.argv.slice(2));
const cmd = all._.shift();
const opts = all;
const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();
/**
 * Spec 0048 §2.6: `--help`, or no verb at all, prints this file's own usage block on stdout and
 * exits 0 — the CLIs are the whole interface now, so discovering them must not look like an error.
 */
function printUsage(verb) {
  const src = readFileSync(fileURLToPath(import.meta.url), "utf8");
  const block = /^\/\*\*\n([\s\S]*?)\n \*\//m.exec(src);
  const text = block ? block[1].replace(/^ \* ?/gm, "") : "roster.mjs";
  // A verb's entry is its `roster.mjs <verb>` line plus the indented continuations under it, so
  // asking about one verb costs three lines instead of the whole 60-line block.
  if (verb) {
    const lines = text.split("\n");
    const picked = [];
    let taking = false;
    for (const l of lines) {
      const m = /^ {2}roster\.mjs (\S+)/.exec(l);
      if (m) taking = m[1] === verb;
      else if (taking && !/^ {4,}/.test(l)) taking = false;
      if (taking) picked.push(l);
    }
    if (picked.length) {
      process.stdout.write(picked.join("\n") + "\n");
      process.exit(0);
    }
  }
  process.stdout.write(text + "\n");
  process.exit(0);
}
if (opts.help === true || cmd === undefined) printUsage(cmd);


/** `--team <name>` (spec 0011 §5.1), validated once with the same validator 0010's alias uses. */
function resolveTeamArg() {
  if (typeof opts.team !== "string") return null;
  const v = validateTeamAlias(opts.team);
  if (!v.ok) {
    if (TEAM_CREATING_VERBS.has(cmd)) {
      const transport = detectTransport();
      const block = newTeamBlock(hierarchyDir(cwd));
      refuseTeamName(opts.team, "explicit", teamNameProblem(opts.team, transport, block) || { why: v.why, failing_member: null }, transport, block);
    }
    fail(`--team: ${v.why}`);
  }
  return opts.team;
}
/** Verbs that edit or read the roster TEMPLATE. A roster has no team, so `--team` means nothing
    here — and silently writing the default block instead of the one meant is the worse failure. */
const TEMPLATE_VERBS = new Set(["init", "add", "edit", "remove", "show"]);
if (TEMPLATE_VERBS.has(cmd) && opts.team !== undefined) fail(`${cmd}: \`--team\` names a live team; to edit a named roster use \`--roster <r>\``);

/** `--roster <r>`: the `rosters.<r>` block a template verb or `create` uses; absent means the default `roster` block. */
function resolveRosterArg() {
  if (opts.roster === undefined) return null;
  if (typeof opts.roster !== "string") fail("--roster needs a value: --roster <name>");
  const v = validateTeamAlias(opts.roster);
  if (!v.ok) fail(`--roster: ${v.why}`);
  return opts.roster;
}
const rosterArg = resolveRosterArg();

// `create --from` without an explicit --team defaults the team scope to the entry's own stored
// alias (spec 0015 §7.2) — the `create` case reassigns both before anything else reads them.
// Declared before it is resolved: validating it can read the role registry, which reads teamArg.
let registryCache = null;
let teamArg = null;
/** An ad hoc member about to be spawned, so the name check counts it among the new team's members. */
let adHocForNameCheck = null;
teamArg = resolveTeamArg();
let repoBasename = teamPrefix(cwd, teamArg);

/**
 * Spec 0044 §1.1: which team FILE this invocation reads and writes. Deliberately NOT `teamArg`,
 * which also selects the roster CONFIG container (`rosters.<team>`) — defaulting that would make a
 * bare `add` start writing `rosters.<repo>` instead of `roster`. Two axes, two variables.
 *
 * `repoBasename` is unaffected either way: `teamPrefixInfo(cwd, "<X>")` returns prefix `<X>`, so
 * the derived default scope has the same prefix the unscoped path already computed. That identity
 * is what makes §1.1's migration claim true — only the file location moves, never the names.
 */
let teamFile = teamArg;
/** No `--team` was given, so the scope was derived — which is what decides whether a collision
    suggests a free candidate (§1.1) or tells the user to disband the team they named. */
let teamFileDefaulted = false;
/** Spec 0044 [9.1]: the derived prefix cannot name a file. Recorded rather than refused on sight —
    every bare command in such a repo would fail, reads like `show` and `disband` included. Only
    the paths that would CREATE a team refuse, in `resolveWritableTeamScope`. */
let teamFileUnnamable = null;
let teamFileUnreadable = null;
function resolveTeamFileScope() {
  if (teamArg) {
    teamFile = teamArg;
    teamFileDefaulted = false;
    return;
  }
  // A session that owns a live team means that team when it names none — a directive's bare
  // `spawn-one` carries no --team, and must join the team its orchestrator made, not start another.
  if (OWNED_TEAM_VERBS.has(cmd)) {
    const owned = ownedLiveTeams(hierarchyDir(cwd));
    if (owned.length > 1) {
      fail(`${cmd}: this session owns ${owned.length} live teams (${owned.map((n) => (n === null ? "the default team (team.json)" : `"${n}"`)).join(", ")}) — pass --team <name> to say which`);
    }
    if (owned.length === 1) {
      teamFile = owned[0];
      teamFileDefaulted = false;
      repoBasename = teamPrefix(cwd, teamFile);
      return;
    }
  }
  const scope = defaultTeamScope(hierarchyDir(cwd), teamPrefix(cwd, null));
  teamFile = scope.team;
  teamFileDefaulted = scope.defaulted;
  teamFileUnnamable = scope.unnamable || null;
  teamFileUnreadable = scope.unreadable || null;
}

/** The live teams this invocation's own pid owns — every team file here, the legacy one included.
    Empty when no pid resolves: a plain user shell owns nothing. */
function ownedLiveTeams(dir) {
  const myPid = ownOrchestratorPid();
  if (!Number.isInteger(myPid)) return [];
  return [null, ...listTeamNames(dir)].filter((name) => {
    const t = readTeam(dir, name);
    return teamOwnedBy(t, invokerIdentity());
  });
}

/** Where the name a create would use came from: the user's --team (or a history entry's), a legacy
    team.json's members, or the repo basename. */
function teamNameSource() {
  if (typeof opts.team === "string" || (cmd === "create" && typeof opts.from === "string" && teamArg)) return "explicit";
  return teamPrefixInfo(cwd, null).source === "legacy-team" ? "legacy-team" : "basename";
}

/**
 * The block a new team would be built from. Under herdr every pane-routed member it derives must
 * carry a Herdr-valid name — the whole block, not only the members launched now, because every
 * later `spawn-one` into the team derives its name from the same frozen team name.
 */
function newTeamBlock(dir) {
  if (cmd === "create" && typeof opts.from === "string") {
    const members = validateHistoryMembers(resolveHistoryEntry(dir));
    return { route: (members[0] && members[0].route) || "peer", members };
  }
  const found = resolveRoster(cwd, cmd === "create" ? rosterArg : null, null, registry());
  const resolved = cmd === "spawn-ad-hoc" ? adHocRoster(found) : found;
  const block = resolved ? { route: resolved.route, members: resolved.members } : { route: null, members: [] };
  if (cmd === "spawn-ad-hoc" && adHocForNameCheck) block.members = [...block.members, adHocForNameCheck];
  return block;
}

/** The roster an ad hoc spawn may read: it takes nothing from a roster but its route, so one that
    resolves at global level — possibly another project's — is not read at all on that path. */
function adHocRoster(found) {
  return found && found.level === "global" ? null : found;
}

/** The final names of every pane-routed member `block` gives team `name`, renames included. */
function paneNames(block, name) {
  return renameInUse(rosterMemberNames(block.members.map(({ name: _name, ...m }) => m), name), name)
    .filter((m) => routeHasPane(m.route || block.route))
    .map((m) => m.name);
}

/**
 * Whether `name` can be a team's name: a valid team name on every transport (it is a path segment
 * and a prefix), and under herdr also a prefix every pane-routed member name fits Herdr's rule
 * with. tmux and terminal have no such rule, so they are not held to it. Null, or `{why,
 * failing_member}` — the longest failing member name under herdr, else null.
 */
function teamNameProblem(name, transport, block) {
  const failing = transport === "herdr" ? paneNames(block, name).filter((n) => !validateHerdrName(n).ok).sort((a, b) => b.length - a.length) : [];
  const failingMember = failing.length ? { name: failing[0], length: failing[0].length } : null;
  const v = validateTeamAlias(name, registry());
  if (!v.ok) return { why: v.why, failing_member: failingMember };
  return failingMember ? { why: validateHerdrName(failingMember.name).why, failing_member: failingMember } : null;
}

function argWord(a) {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : shQuote(a);
}

/** This invocation as a command line, without each `--flag [value]` that `drop(flag, value)`
    selects, and with `tail` appended as written. */
function rerunCommand(drop, tail) {
  const argv = process.argv.slice(2);
  const kept = [];
  for (let i = 0; i < argv.length; i++) {
    const value = argv[i + 1] !== undefined && !argv[i + 1].startsWith("--") ? argv[i + 1] : undefined;
    if (argv[i].startsWith("--") && drop(argv[i].slice(2), value)) {
      if (value !== undefined) i++;
      continue;
    }
    kept.push(argv[i]);
  }
  return `node ${argWord(fileURLToPath(import.meta.url))} ${kept.map(argWord).join(" ")} ${tail}`;
}

/** This invocation, with `--team <TEAM>` in place of any --team it had. */
function rerunWithTeamPlaceholder() {
  return rerunCommand((flag) => flag === "team", "--team <TEAM>");
}

/** A refusal whose choice belongs to the user: JSON on stdout for a caller that branches on
    `refused`, the message on stderr for one that reads text, exit 2. */
function refuse(fields) {
  process.stdout.write(JSON.stringify({ ok: false, ...fields }, null, 2) + "\n");
  fail(fields.message);
}

/**
 * The one refusal for a team name that cannot be used, whatever proposed it. Choosing a team's name
 * is the user's call, so the sanitizer's suggestion is only offered: JSON on stdout for a caller
 * that branches on `refused`, the instruction on stderr for one that reads text, exit 2. `rerun`
 * carries a literal <TEAM>, so it cannot be run as-is before someone has chosen. Nothing is
 * launched or written.
 */
function refuseTeamName(name, nameSource, problem, transport, block) {
  const suffixes = transport === "herdr" ? paneNames(block, name).map((n) => n.slice(name.length)) : [];
  const suggestion = transport === "herdr" ? suggestTeamAlias(name, { transport, suffixes, resolved: registry() }) : suggestTeamAlias(name);
  let suggestionWhy = null;
  if (suggestion === null) {
    const bad = suffixes.find((suffix) => !/^-[a-z0-9_-]+$/.test(suffix));
    const longest = [...suffixes].sort((a, b) => b.length - a.length)[0] || "";
    suggestionWhy = bad
      ? `the member name suffix "${bad}" is not valid in a Herdr agent name ([a-z0-9_-] only), whatever the team is called — rename that role or its --member name`
      : `the longest member name suffix, "${longest}" (${longest.length} characters), leaves no room for a team name within Herdr's 32-character limit — shorten that role or its --member name`;
  }
  const needsUserChoice = suggestion !== null;
  const rerun = needsUserChoice ? rerunWithTeamPlaceholder() : null;
  const message = needsUserChoice
    ? `Team name "${name}" (${nameSource}) can't be used: ${problem.why}. Do not pick a name yourself. Ask the user with AskUserQuestion — first option "Use ${suggestion} (Recommended)", and let them type another name. Then re-run ${rerun} with <TEAM> replaced by their answer. This is not a launch failure.`
    : `No team name can make member names valid under ${transport}: ${suggestionWhy}. Tell the user; the fix is a shorter or renamed role or --member name. Do not retry with a name of your own.`;
  refuse({ refused: "team-name-unusable", needs_user_choice: needsUserChoice, verb: cmd, name, name_source: nameSource, transport, why: problem.why, failing_member: problem.failing_member, suggestion, suggestion_why: suggestionWhy, rerun, message });
}

/** Every value of a repeatable `--<flag> <value>` on this invocation, in order. parseArgs keeps
    only a flag's last value, so argv is read directly. */
function repeatedFlag(flag) {
  const argv = process.argv.slice(2);
  const values = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] !== `--${flag}`) continue;
    const value = argv[i + 1] !== undefined && !argv[i + 1].startsWith("--") ? argv[i + 1] : null;
    if (value === null) fail(`${cmd}: --${flag} requires a value`);
    values.push(value);
    i++;
  }
  return values;
}


/**
 * This create's `--member-model <name>=<model>` values, checked against `members`, the members it
 * is planned from: each must name one of them, a claude-kind one, with a model its class allows.
 */
function memberModelOverrides(members) {
  const models = new Map();
  for (const value of repeatedFlag("member-model")) {
    const eq = value.indexOf("=");
    if (eq <= 0) fail(`${cmd}: --member-model takes <name>=<model>, got ${JSON.stringify(value)}`);
    const name = value.slice(0, eq);
    const model = value.slice(eq + 1);
    if (models.has(name)) fail(`${cmd}: --member-model names ${name} twice`);
    const m = members.find((x) => x.name === name);
    if (!m) fail(`${cmd}: --member-model names no member ${JSON.stringify(name)} — the members are: ${members.map((x) => x.name).join(", ") || "(none)"}`);
    if (resolveKind(m) !== KIND_DEFAULT) fail(`${cmd}: --member-model ${name}: ${name} is kind ${JSON.stringify(resolveKind(m))}, and a model applies only to kind claude`);
    const errs = validateMember({ role: m.role, model }, registry());
    if (errs.length) fail(`${cmd}: --member-model ${name}: ${errs.join("; ")}`);
    models.set(name, model);
  }
  return models;
}

/** The member with `model` in place of its own when one is supplied at invocation. */
function withModel(m, model) {
  return model === undefined ? m : { ...m, model };
}

/**
 * `members`, named under team `prefix`, with each colliding one renamed to `<prefix>-<role>-<n>`
 * and given `renamed_from`, the name it was derived as. A member collides when its name exactly
 * matches a `--names-in-use` value, or when the name it was derived as is held by a record another
 * member claimed (`claimRecords`). n is the smallest from 2 whose name is not in use, not taken by
 * an earlier member, not a later non-colliding member's derived name, and not a record of the
 * team being joined (`records`). A name in use that one of those records holds is the team's own
 * session when `ownLive(name)` says that record is live or may be, and then causes no rename. The
 * CLI cannot see live session names itself; the flag is all it knows of them.
 */
function renameInUse(members, prefix, records = [], ownLive = () => false) {
  const inUse = new Set(repeatedFlag("names-in-use"));
  const recordNames = new Set(records.map((r) => r && r.name).filter(Boolean));
  const ownCache = new Map();
  const own = (name) => {
    if (!ownCache.has(name)) ownCache.set(name, recordNames.has(name) && ownLive(name));
    return ownCache.get(name);
  };
  const derivedOf = (m) => m.derived || m.name;
  const claimedByOther = (m) => members.some((x) => x !== m && x.record && x.record.name === derivedOf(m));
  const collides = (m) => (inUse.has(m.name) && !own(m.name)) || claimedByOther(m);
  if (!members.some(collides)) return members;
  const taken = new Set(recordNames);
  return members.map((m, i) => {
    if (!collides(m)) {
      taken.add(m.name);
      return m;
    }
    const kept = new Set(members.slice(i + 1).filter((x) => !collides(x)).map(derivedOf));
    const base = peerName(prefix, m.role);
    let n = 2;
    while (inUse.has(`${base}-${n}`) || taken.has(`${base}-${n}`) || kept.has(`${base}-${n}`)) n++;
    taken.add(`${base}-${n}`);
    return { ...m, name: `${base}-${n}`, renamed_from: derivedOf(m) };
  });
}

/**
 * spawn-one's roster members of one role, each holding the team record it stands for (`record`):
 * first a record renamed away from the member's derived name, which the member takes with its name
 * and `renamed_from`, then a record under that derived name. Each record goes to one member at most.
 */
function claimRecords(members, records) {
  const claimed = new Set();
  const claim = (m, match) => {
    const r = records.find((x) => !claimed.has(x) && match(x));
    if (r) claimed.add(r);
    return r;
  };
  return members
    .map((m) => {
      const r = claim(m, (x) => x.renamed_from === m.name);
      return r ? { ...m, name: r.name, renamed_from: r.renamed_from, derived: m.name, record: r } : m;
    })
    .map((m) => {
      if (m.record) return m;
      const r = claim(m, (x) => x.name === m.name);
      return r ? { ...m, record: r } : m;
    });
}

/** `renamed_members` for an output, listing each of `members` that was renamed; absent when none was. */
function renamedField(members) {
  const renamed = members.filter((m) => m.renamed_from).map((m) => ({ name: m.name, role: m.role, renamed_from: m.renamed_from }));
  return renamed.length ? { renamed_members: renamed } : {};
}

let taskGopherInstalledCache;
/** Installed per installed_plugins.json. Whether it is enabled only the driver's agent list can tell,
    so a driver that cannot dispatch it passes --no-legwork-handoff and it counts as not installed. */
function taskGopherInstalled() {
  if (opts["no-legwork-handoff"] === true) return false;
  if (taskGopherInstalledCache === undefined) taskGopherInstalledCache = Boolean(locateAgentFile(TASK_GOPHER, cwd).path);
  return taskGopherInstalledCache;
}

/** A claude-kind legwork member with no model is not launched while task-gopher is installed: its
    legwork goes to task-gopher subagents instead, and nobody is asked for a model. */
function autoSkipped(m) {
  return legworkHandedOff(m, registry(), taskGopherInstalled);
}

/** A skipped member as reported. */
function skippedEntry(m) {
  return { name: m.name, role: m.role, handoff: TASK_GOPHER };
}

/** `obj` with `skipped_members`, and what to do about them, when there are any. */
function withSkipped(obj, skipped) {
  if (!skipped.length) return obj;
  const one = skipped.length === 1;
  const message =
    `${skipped.map((m) => m.name).join(", ")} ${one ? "has" : "have"} no model and task-gopher is installed, so ${one ? "it was" : "they were"} not launched: ` +
    `send that legwork to ${TASK_GOPHER} subagents, and do not ask the user about ${one ? "it" : "them"}. ` +
    `If ${TASK_GOPHER} is not among your available agent types (installed but not enabled), tell the user which member was not launched and why: ` +
    "adding it means `disband`, then `create --no-legwork-handoff`, which lists it for a model like any other member. " +
    `A driver that cannot dispatch ${TASK_GOPHER} passes --no-legwork-handoff on every create phase from the start.`;
  return { ...obj, skipped_members: skipped, message };
}

const CHAIN_WORK_CLASSES = ["design", "review", "implement"];

/**
 * What a member of class `cls` with no model borrows: the highest-tier model among the claude-kind
 * design, review and implement members of `pool` that `cls` allows, the first in roster order on a
 * tie — `{model, from}`, or null. `inherit` has no knowable tier, so it is never borrowed, and a
 * legwork member never borrows a chain model.
 */
function memberFallback(cls, pool) {
  if (cls === "legwork") return null;
  const allowed = CLASSES[cls] ? CLASSES[cls].models : [];
  let best = null;
  for (const m of pool) {
    if (resolveKind(m) !== KIND_DEFAULT || !CHAIN_WORK_CLASSES.includes(roleClass(m.role, registry()))) continue;
    const tier = tierOf(m.model);
    if (tier === null || !allowed.includes(m.model)) continue;
    if (!best || tier > best.tier) best = { tier, model: m.model, from: m.name };
  }
  return best && { model: best.model, from: best.from };
}

/** The claude-kind members of `launching` with no model, each with the models its class allows and
    what it would borrow from `pool`. */
function membersNeedingModel(launching, pool) {
  return launching
    .filter((m) => resolveKind(m) === KIND_DEFAULT && !m.model)
    .map((m) => {
      const cls = roleClass(m.role, registry());
      return { name: m.name, role: m.role, class: cls, allowed: CLASSES[cls] ? [...CLASSES[cls].models] : [], fallback: memberFallback(cls, pool) };
    });
}

/** A create plan's pane- and peer-routed members that have no model. */
function planNeedingModel(plan) {
  return membersNeedingModel(plan.members.filter((m) => routeHasPane(m.route)), plan.members);
}

/**
 * The refusal for members about to launch with no model. A member's model is the user's to choose,
 * and the CLI cannot tell whether its caller can ask, so it never applies the fallback itself: it
 * names the members and hands back two reruns — one with a literal <MODEL> per member for the
 * user's answers, and one with each fallback filled in, for a caller that cannot ask.
 */
function refuseMemberModels(needing) {
  const listed = new Set(needing.map((m) => m.name));
  const drop =
    cmd === "create"
      ? (flag, value) => flag === "member-model" && typeof value === "string" && listed.has(value.slice(0, value.indexOf("=")))
      : cmd === "spawn-one"
        ? (flag) => flag === "member" || flag === "model"
        : (flag) => flag === "model";
  const tail = (modelOf) =>
    cmd === "create"
      ? needing.map((m) => `--member-model ${argWord(m.name)}=${modelOf(m)}`).join(" ")
      : cmd === "spawn-one"
        ? `--member ${argWord(needing[0].name)} --model ${modelOf(needing[0])}`
        : `--model ${modelOf(needing[0])}`;
  const rerun = rerunCommand(drop, tail(() => "<MODEL>"));
  const rerunFallback = needing.every((m) => m.fallback) ? rerunCommand(drop, tail((m) => m.fallback.model)) : null;
  const who = needing.map((m) => `${m.name} (${m.role}; allowed: ${m.allowed.join(", ")}; fallback: ${m.fallback ? `${m.fallback.model}, from ${m.fallback.from}` : "none"})`).join("; ");
  const message =
    `No model is defined for ${needing.length === 1 ? "this member" : "these members"}: ${who}. A member's model is the user's choice: ` +
    "ask the user with AskUserQuestion, one question per member, with its fallback model as the first option when it has one, " +
    `then re-run ${rerun} with each <MODEL> replaced by the answer. ` +
    (rerunFallback
      ? `Only a top-level session that cannot ask the user (a non-interactive run: claude -p, the SDK, headless) runs the fallback rerun instead: ${rerunFallback}. `
      : `rerun_fallback is null — there is no fallback for ${needing.filter((m) => !m.fallback).map((m) => m.name).join(", ")} — so a session that cannot ask the user stops and reports these members. `) +
    "A subagent never runs rerun_fallback: it returns this refusal to its caller. Never choose a model any other way. " +
    "This is not a launch failure.";
  refuse({ refused: "member-model-undefined", verb: cmd, members: needing, rerun, rerun_fallback: rerunFallback, message });
}

/** The name check a verb about to create `teamFile` runs before anything is launched or written. */
function checkNewTeamName(dir) {
  if (teamFile === null) return;
  const transport = detectTransport();
  const block = newTeamBlock(dir);
  const problem = teamNameProblem(teamFile, transport, block);
  if (problem) refuseTeamName(teamFile, teamNameSource(), problem, transport, block);
}

/** A roster has no team, so `show` names members under the default team name — and says so when
    a create could not use that name, rather than refusing a read. */
function showNameNote(block) {
  if (!block) return {};
  const problem = teamNameProblem(repoBasename, detectTransport(), block);
  return problem ? { team_name_note: `members are shown under the default team name "${repoBasename}", which a team cannot use (${problem.why}) — create will ask for a name` } : {};
}

/** `role set`'s assumed prefix: the invoking session's own live team, else the default team's. */
function roleSetPrefix() {
  const owned = ownedLiveTeams(hierarchyDir(cwd));
  return owned.length ? teamPrefix(cwd, owned[0]) : teamPrefix(cwd, null);
}
resolveTeamFileScope();

function levelArg() {
  if (typeof opts.level === "string") return opts.level;
  const bare = opts._[0];
  return typeof bare === "string" && ROSTER_LEVELS.includes(bare) ? bare : null;
}

function requireLevel(explicit) {
  if (!ROSTER_LEVELS.includes(explicit)) fail(`--level must be one of ${ROSTER_LEVELS.join(", ")}, got ${JSON.stringify(explicit)}`);
  return explicit;
}

/** For add/edit/remove: explicit --level, else whichever level currently resolves. Returns
    {level, wasDefaulted, teamKey}. `teamKey` is always the active `--team` scope (never
    resolveRoster's possibly-null match) — a write must target `rosters.<team>` whenever a
    team scope is active, even the first time, before any override exists anywhere (spec 0032
    §3.4: writing to `data.roster` while `--team` is active is the corruption this guards). */
// Spec 0038 §1.1 leaves the bootstrapped container's route unspecified, and the plugin has no
// roster-level default (a session's dispatch route "unset stays null"). "peer" is the superset:
// it tries a live peer first and falls back to a subagent, so nothing is foreclosed.
// Overridden by an explicit `add --route`.
const AUTO_INIT_ROUTE = "peer";

function targetLevel({ allowMissing = false, key = rosterArg } = {}) {
  const explicit = levelArg();
  if (explicit) return { level: requireLevel(explicit), wasDefaulted: false, teamKey: key };
  const resolved = resolveRoster(cwd, key, repoBasename, registry());
  if (resolved) return { level: resolved.level, wasDefaulted: true, teamKey: key };
  // Spec 0038 §1.1: with nothing resolving anywhere, `add` (only) may bootstrap at the same
  // default `targetLevel` would otherwise have picked — repo level when cwd is inside a git
  // repo. Named-roster (§1.2, 0032 §3.4b) and non-repo cwds keep the existing failure.
  if (allowMissing && !key) {
    if (findGitRoot(cwd)) return { level: "repo", wasDefaulted: true, teamKey: key };
    // Spec 0038 §1.1: no git root → no auto-create; a bare `add` outside any repo must not write
    // the user-wide file as a side effect. The escape is explicit.
    fail(`no roster resolves at any level and ${cwd} is not inside a git repo — re-run with --level global to create the user-wide roster (~/.claude/agent-hierarchy.json), or cd into a repo`);
  }
  fail("no roster resolves at any level — run `roster.mjs init` first");
}

/** Spec 0038 §1.1 "one writer": the roster block `init` creates, shared with `add`'s auto-init so
    the shape is serialized in exactly one place (0035 §11's duplicate-representation family). */
function freshRosterBlock(route) {
  if (!ROSTER_ROUTE_VALUES.includes(route)) fail(`--route must be "peer" or "subagent", got ${JSON.stringify(route)}`);
  return { route, members: [] };
}

/** Install a fresh block as the container for `teamKey` (`roster`, or `rosters.<team>`) — replaces wholesale. */
function installRosterBlock(data, teamKey, fresh) {
  data.version = data.version || CONFIG_VERSION;
  if (!teamKey) data.roster = fresh;
  else {
    data.rosters ||= {};
    data.rosters[teamKey] = fresh;
  }
}

/** The roster container to read/write at this level for the active team scope (spec 0032 §3.4).
    Never creates a container — `init` is the only path that may (spec 0032 §3.4b). No site may
    reach `data.roster` directly while a `--team` scope is active. */
function rosterContainer(data, teamKey) {
  if (!teamKey) return data.roster || null;
  return data.rosters && data.rosters[teamKey] ? data.rosters[teamKey] : null;
}

/** "roster" or `rosters.<name>` — for output/warning text naming which container a write hit (spec 0032 §3.4 point 5). */
function containerLabel(teamKey) {
  return teamKey ? `rosters.${teamKey}` : "roster";
}

/** Roster rows each level file lost to `dropNonObjectMembers` when it was read, by path, so the
    write that persists the cleaned file can list them under `migrated`. */
const droppedAtRead = new Map();

function readLevelFile(path) {
  if (!existsSync(path)) return { version: CONFIG_VERSION };
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    if (!data || typeof data !== "object" || Array.isArray(data)) return { version: CONFIG_VERSION };
    const dropped = dropNonObjectMembers(data);
    if (dropped.length) droppedAtRead.set(path, dropped);
    return data;
  } catch {
    return { version: CONFIG_VERSION };
  }
}

/**
 * Rewrites, in place, the keys in a level file's `data` that no longer do anything, so a write the
 * user started leaves the file current. Opt-ins that ran a chain role as a subagent — only legwork
 * does now: a top-level route other than "peers", a chain role's dispatch "model", a chain member's
 * route "subagent", onMissing "never"/"prompt", and a block route "subagent", which becomes "peer"
 * while each legwork member that inherited it keeps "subagent" as its own. And the team keys a
 * roster no longer holds: `teamAlias`, a block's `layout`, and `teamLayout` outside the global file.
 * A member whose role cannot be classified is left as it is; a member that is not an object is
 * dropped. Other keys and key order are kept.
 */
function migrateStaleKeys(path, data) {
  const changes = [];
  const note = (key, from, to) => changes.push({ path, key, from: from === undefined ? null : from, to });
  const reg = registry();
  for (const d of [...(droppedAtRead.get(path) || []), ...dropNonObjectMembers(data)]) note(`${d.label}.members[${d.index}]`, d.value, null);
  droppedAtRead.delete(path);
  if (STALE_ROUTE_VALUES.includes(data.route)) {
    note("route", data.route, null);
    delete data.route;
  }
  if (data.teamAlias !== undefined) {
    note("teamAlias", data.teamAlias, null);
    delete data.teamAlias;
  }
  if (data.teamLayout !== undefined && path !== rosterLevelPaths(cwd).global) {
    note("teamLayout", data.teamLayout, null);
    delete data.teamLayout;
  }
  const roles = data.roles && typeof data.roles === "object" && !Array.isArray(data.roles) ? data.roles : {};
  // A custom role's class is the one this file now holds: the registry was resolved before the
  // write, so a write that reclassifies a role would otherwise be judged by its old class.
  const classOf = (role) => {
    const row = roles[role];
    return !isBuiltinRole(role) && row && typeof row === "object" && CLASSES[row.class] ? row.class : roleClass(role, reg);
  };
  for (const [role, row] of Object.entries(roles)) {
    if (!row || typeof row !== "object" || row.dispatch !== "model") continue;
    const cls = classOf(role);
    if (cls && cls !== "legwork") {
      note(`roles.${role}.dispatch`, "model", null);
      delete row.dispatch;
    }
  }
  for (const [label, , block] of rosterBlocksOf(data)) {
    if (!block || typeof block !== "object" || Array.isArray(block)) continue;
    if (block.layout !== undefined) {
      note(`${label}.layout`, block.layout, null);
      delete block.layout;
    }
    const staleBlock = block.route === "subagent";
    if (staleBlock) {
      note(`${label}.route`, "subagent", "peer");
      block.route = "peer";
    }
    (Array.isArray(block.members) ? block.members : []).forEach((m, i) => {
      const cls = m && typeof m === "object" ? classOf(m.role) : null;
      if (!cls) return;
      const at = `${label}.members[${i}]`;
      if (m.onMissing === "never" || m.onMissing === "prompt") {
        note(`${at}.onMissing`, m.onMissing, null);
        delete m.onMissing;
      }
      if (cls === "legwork") {
        if (staleBlock && m.route === undefined) {
          note(`${at}.route`, null, "subagent");
          m.route = "subagent";
        }
      } else if (m.route === "subagent") {
        note(`${at}.route`, "subagent", null);
        delete m.route;
      }
    });
  }
  return changes;
}

function writeLevelFile(path, data) {
  const changes = migrateStaleKeys(path, data);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
  if (changes.length) {
    migratedKeys.push(...changes);
    process.stderr.write(`roster.mjs: migrated ${changes.length} stale key(s) in ${path}: ${changes.map((c) => c.key).join(", ")} (listed under \`migrated\`)\n`);
  }
}

/** The route `member` of `block` is checked against. A route or role given by this invocation is
    checked as given; anything left from before reads as `normalizeRosterBlock` reads it. */
function checkedRoute(member, block, givenNow) {
  if (givenNow && member.route !== undefined) return member.route;
  const view = normalizeRosterBlock({ route: block.route, members: [member] }, registry());
  return view.members[0].route || view.route;
}

function namedMembers(members) {
  return rosterMemberNames(members, repoBasename);
}

/**
 * Spec 0043 §1.9: `--args` carries a JSON array of native CLI arguments for a non-claude kind.
 * Only the JSON shape is decoded here — whether the decoded value is a legal `args` (array of
 * non-empty strings, absent for kind claude) is `kindFieldErrors`' single answer, so the CLI and
 * a hand-edited config file are judged by exactly the same rule.
 *
 * An empty array clears the field (§1.9 makes absent and `[]` equivalent).
 */
function parseArgsFlag(value, cmd) {
  if (value === true) fail(`${cmd}: --args requires a value — a JSON array of strings, e.g. --args '["--profile","fast"]'`);
  const raw = String(value).trim();
  if (!raw) return null;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail(`${cmd}: --args must be a JSON array of strings, e.g. --args '["--profile","fast"]' (could not parse ${JSON.stringify(raw)})`);
  }
  if (Array.isArray(parsed) && parsed.length === 0) return null;
  return parsed;
}

/**
 * Spec 0043 §1.7: any member launched through Herdr — every non-claude member by §1.4, and a
 * claude member on the herdr transport — must have a name Herdr will accept. Checked against the
 * DERIVED name at add/edit, which is the only place it can be reported usefully; `validateMember`
 * cannot host it because it rejects a member carrying a stored `name` at all.
 *
 * Pre-existing latent defect for long repo basenames; in scope here because a non-claude member
 * has no non-Herdr transport to fall back to, so for it the failure is unconditional.
 */
function requireHerdrName(member, cmd) {
  if (!routeHasPane(member.route)) return;
  const check = validateHerdrName(member.name);
  if (check.ok) return;
  // A non-claude kind has no non-Herdr transport to fall back to (§1.4), so an unusable name is
  // an unconditional failure and must be refused now.
  if (resolveKind(member) !== KIND_DEFAULT) fail(`${cmd}: ${check.why}`);
  // A claude member still launches fine on tmux/terminal with a name Herdr would reject — a repo
  // directory containing a space is the common case, and tests/test-roster-spawn-cwd.sh asserts
  // it works. Spec 0043 §1.7 asks for this to be rejected for both kinds, but §3 forbids changing
  // the claude path "with or without Herdr", so this warns rather than refusing. See the spec-gap
  // note in the implementation report — this is the Architect's call to settle, not mine.
  process.stderr.write(`roster.mjs: warning — ${check.why}. This member spawns fine on the tmux/terminal transport, but \`herdr agent start\` will reject the name.\n`);
}

/**
 * Spec 0044 §1.4 point 1: the member-shaped fields `--role/--model/--effort/--route/--kind/--args/
 * --auto-mode/--on-missing` decode to, shared by `add` (which writes the result to the roster) and
 * `spawn-ad-hoc` (which writes it to the team file). One decoder, so "the same fields `add`
 * accepts" stays true by construction rather than by two lists agreeing today.
 *
 * Validation is NOT done here — the caller validates against its own effective route, which is the
 * roster block's for `add` and the member's own for an ad hoc spawn.
 */
function memberFromFlags(role, cmdLabel) {
  if (opts.kind === true) fail(`${cmdLabel}: --kind requires a value (e.g. claude, codex, pi)`);
  const kind = typeof opts.kind === "string" ? opts.kind : KIND_DEFAULT;
  // A model is the user's to define: none is filled in, and a member without one is asked for it
  // when it is launched.
  const member = { role };
  if (typeof opts.model === "string") member.model = opts.model;
  if (kind !== KIND_DEFAULT) member.kind = kind;
  if (typeof opts.effort === "string") member.effort = opts.effort;
  if (typeof opts.route === "string") member.route = opts.route;
  if (typeof opts["auto-mode"] === "string") member.autoMode = opts["auto-mode"];
  // §1.9 makes absent and `[]` equivalent, so an empty --args omits the key rather than
  // writing `"args": null`.
  if (opts.args !== undefined) {
    const parsed = parseArgsFlag(opts.args, cmdLabel);
    if (parsed !== null) member.args = parsed;
  }
  if (opts["on-missing"] === true) fail(`${cmdLabel}: --on-missing requires a value (auto)`);
  if (typeof opts["on-missing"] === "string") member.onMissing = opts["on-missing"];
  return member;
}

function findMemberIndex(members, name) {
  return namedMembers(members).findIndex((m) => m.name === name);
}

/** Spec 0020 §3.5/§3.6: remove one member by derived name from a roster CONFIG level (the
    template for future teams) — shared by `remove` and `dismiss --also-config` so there is
    exactly one config-edit path. Resolves the level exactly as `remove` always has
    (targetLevel()). Writes nothing when the member isn't found. */
/** Spec 0046 §2.3: forget ONE member's team.json row, touching no session. This is verbatim the
    body `dismiss --commit` had through 0.70.0 — including the ordinal-shift warning — moved here
    because `dismiss` is now destructive-only (§3). The live guard that fronts it is the caller's. */
function untrackMember(dir, team, target, name) {
  const outTeam = { ...team, members: team.members.filter((m) => m.name !== name) };
  // The template key is read from the team file, which the last departure removes.
  const templateKey = opts["also-config"] === true ? teamTemplateKey(dir) : null;
  const teamRemoved = writeTeamRows(dir, team, outTeam.members);
  // §3.4: a commit on a still-live member is allowed, but must never be silent about it.
  // Spec 0043 §1.6: kind-aware, and an indeterminate answer warns too — the whole point of
  // the third value is that "Herdr did not answer" must not be spent as "it is dead".
  const commitState = memberLiveness(dir, target);
  if (commitState.live || commitState.indeterminate) {
    let command = null;
    if (routeHasPane(target.route) && target.transport_id) {
      if (team.transport === "herdr") command = `herdr pane close ${target.transport_id}`;
      else if (team.transport === "tmux") command = `tmux kill-pane -t ${target.transport_id}`;
    }
    process.stderr.write(
      `roster.mjs: ah: ${target.name} ${commitState.indeterminate ? `may still be live — could not determine (${commitState.why})` : `is still live`} (${team.transport} ${target.transport_id}). Its record is gone from team ${team.team_id}.` +
        (command ? ` Close it with \`${command}\` if you did not mean to leave it running.\n` : "\n")
    );
  }
  const teamEmpty = outTeam.members.length === 0;
  if (teamRemoved) process.stderr.write(`roster.mjs: ah: team ${team.team_id} has no members left, so it was removed.\n`);
  // Spec 0046 §2.3: `untracked`, not `dismissed` — dismiss now means "closed the session", and a
  // caller that greps for `dismissed` on this output would read a live session as gone.
  const dismissOut = {
    untracked: true,
    member: { role: target.role, name: target.name },
    team_id: team.team_id,
    removed: target.name,
    remaining: outTeam.members.map((m) => m.name),
    team_empty: teamEmpty,
    ...(teamRemoved ? { team_removed: true } : {}),
    config: null,
    store: `team ${JSON.stringify(team.team_id)}`,
  };
  if (opts["also-config"] === true) {
    const result = removeConfigMember(target.name, templateKey);
    if (!result.removed) {
      process.stderr.write(
        `roster.mjs: ah: untracked ${target.name} from team ${team.team_id}, but no roster member named ${target.name} exists at level "${result.level}" — the config was not changed.\n`
      );
      dismissOut.config = { removed: false, level: result.level, reason: result.reason };
    } else {
      // §3.5.1: ordinal shift. `result.before`/`result.after` are the config's
      // ordinal-derived names before/after this removal, in array order. Everything at or
      // before the removed index is unaffected; every later same-role sibling's ordinal
      // (and therefore derived name) shifts down by one. Warn — never refuse — whenever a
      // shifted name belongs to a member team.json still records as live under the OLD name.
      const reordinaled = [];
      for (let i = result.idx; i < result.before.length - 1; i++) {
        const oldName = result.before[i + 1].name;
        const newName = result.after[i].name;
        if (oldName === newName) continue;
        const teamHasRecord = outTeam.members.some((m) => m.name === oldName);
        // Spec 0043 §1.6: ask the recorded member (kind-aware), not a bare name. An
        // indeterminate answer warns — a Herdr blip must not silently drop the shift notice.
        const oldMember = outTeam.members.find((m) => m.name === oldName);
        const oldState = oldMember ? memberLiveness(dir, oldMember) : null;
        if (teamHasRecord && oldState && (oldState.live || oldState.indeterminate)) reordinaled.push({ from: oldName, to: newName });
      }
      dismissOut.config = { removed: true, level: result.level, path: result.path, reordinaled };
      if (reordinaled.length > 0) {
        const pairs = reordinaled.map((r) => `${r.from} is now derived as ${r.to}`).join(", ");
        process.stderr.write(
          `roster.mjs: ah: removing ${target.name} from the roster re-ordinals later ${target.role} members: ${pairs}. ` +
            `Live team records keep their original names and still dispatch correctly; a future create/spawn-one will use the new names.\n`
        );
      }
    }
  }
  return dismissOut;
}

/** Spec 0043 §1.6 three-valued liveness as an output field: `null` is "could not determine",
    which is NOT `false`. */
function liveField(dir, member) {
  const st = memberLiveness(dir, member);
  return st.indeterminate ? { live: null, live_unknown: st.why } : { live: st.live };
}

/** Spec 0046 §2.3: three-valued liveness for the guard. `indeterminate` counts as live —
    "Herdr did not answer" must never be spent as "it is dead" (spec 0043 §1.6). */
function untrackLiveGuard(dir, members, verb) {
  const stillUp = [];
  for (const m of members) {
    const st = memberLiveness(dir, m);
    if (st.live || st.indeterminate) stillUp.push({ name: m.name, why: st.indeterminate ? st.why : "live" });
  }
  if (stillUp.length === 0) return;
  fail(
    `untrack: ${stillUp.length === 1 ? `${stillUp[0].name} is` : `${stillUp.map((s) => s.name).join(", ")} are`} still live — ` +
      `untrack only forgets the record and CANNOT BE UNDONE; the session would keep running with nothing tracking it. ` +
      `Use \`${verb}\` to close ${stillUp.length === 1 ? "it" : "them"}, or re-run with --keep-sessions to forget the record and leave ${stillUp.length === 1 ? "it" : "them"} running. ` +
      `Detail: ${JSON.stringify(stillUp)}`,
  );
}


/**
 * The roster block the team at this scope reads its members from: its recorded key (or the pre-0057
 * name rule) as that key actually resolves. A key with no block falls through to the default
 * block on read, so an edit made for the team — `--also-config` — must land there too.
 */
function teamTemplateKey(dir) {
  const key = teamRosterKey(dir, teamFile);
  const resolved = resolveRoster(cwd, key, repoBasename, registry());
  return resolved ? resolved.teamKey : key;
}

function removeConfigMember(name, key = rosterArg) {
  const { level, wasDefaulted, teamKey } = targetLevel({ key });
  const path = rosterLevelPaths(cwd)[level];
  const data = readLevelFile(path);
  const container = rosterContainer(data, teamKey);
  if (!container || !Array.isArray(container.members)) {
    return { level, path, wasDefaulted, removed: false, reason: `no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init\` first` };
  }
  const idx = findMemberIndex(container.members, name);
  if (idx === -1) return { level, path, wasDefaulted, removed: false, reason: "no such member" };
  const before = namedMembers(container.members);
  // Spec 0032 §3.4 point 4: splice only — never delete the container itself, even down to
  // members: []. An empty rosters.<team> block and an absent one differ (the former still
  // no-matches per §3.2's guard, but only `remove --team X --all` may erase the block).
  container.members.splice(idx, 1);
  const after = namedMembers(container.members);
  writeLevelFile(path, data);
  return { level, path, wasDefaulted, removed: true, idx, before, after, container: containerLabel(teamKey) };
}

function detectTransport() {
  if (process.env.HERDR_ENV === "1") return "herdr";
  try {
    execFileSync("tmux", ["list-sessions"], { stdio: "ignore" });
    return "tmux";
  } catch {
    return "terminal";
  }
}

/**
 * Single-quote one string for `/bin/sh -c` (spec 0043 §1.9). `args` is the first member field
 * whose value is authored as free text and interpolated into `runShell`'s command string, so an
 * element containing `;`, a backtick, `$(…)` or a redirect would otherwise execute as shell
 * syntax instead of arriving as one argument. Same class of reason as the tmux branch's
 * `JSON.stringify` below.
 */
function shQuote(s) {
  return `'${String(s).split("'").join(`'\\''`)}'`;
}

/**
 * The single launch-shape seam (spec 0009 §6.3) — `spawn-one`, `create --spawn` and history
 * replay all build their command here. Spec 0043 §1.4 branches it on `kind`: a claude member's
 * string is unchanged byte-for-byte (§3/§4.1), and every other kind gets Herdr's own `--kind`
 * with its native arguments after `--`. No `--timeout` on either path — r6 dropped it once
 * Herdr's own default was confirmed to be the same value it was passing.
 */
function spawnShape(member, transport, agent = null) {
  const kind = resolveKind(member);
  const isClaude = kind === KIND_DEFAULT;
  // §1.9: `add`/`edit` already refuse these combinations, but a hand-edited config reaches this
  // function without passing through either — and for `args` on a claude member the consequence
  // is an unvalidated second channel for --model/--permission-mode, so re-check here.
  const configErrors = kindFieldErrors(member);
  if (configErrors.length) {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name} (kind ${kind}) has an invalid configuration: ${configErrors.join("; ")}` };
  }
  // Herdr rejects the name only at `agent start`, after the pane has been split, which strands an
  // empty pane; a refusal here lands before layout, so no pane is ever opened for it.
  const herdrName = transport === "herdr" ? validateHerdrName(member.name) : { ok: true };
  if (!herdrName.ok) {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name}: ${herdrName.why}` };
  }
  // §1.4: forced by F2 — the tmux branch sends the literal string `claude <flags>` into a pane
  // and the terminal branch execs `claude`; neither can start another kind, and teaching them
  // each kind's binary would duplicate knowledge Herdr owns. Refuse rather than launch a claude.
  if (!isClaude && transport !== "herdr") {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name} has kind ${JSON.stringify(kind)}, which requires the herdr transport, but the detected transport is ${JSON.stringify(transport)} — start a Herdr session (HERDR_ENV=1) to spawn non-claude kinds` };
  }
  // The agent is interpolated into a shell string, so its charset is re-checked here at the seam
  // even though every config write and read already checked it.
  const agentRef = agent || `ah:${member.role}`;
  if (isClaude && !AGENT_REF_RE.test(agentRef)) {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name} has an invalid agent reference ${JSON.stringify(agentRef)}` };
  }
  // §1.4: emitted only for kind claude — `--agent ah:<role>` is a Claude Code plugin-agent
  // reference and --model/--effort/--permission-mode are Claude CLI flags (§F3, §1.8).
  // The member learns its team from its launch: settings `env` reaches its hooks and its Bash
  // children, and overrides whatever AH_TEAM_FILE the launching shell happens to carry.
  const teamFilePath = teamPath(hierarchyDir(cwd), teamFile);
  // A member's name and the team file it is launched into must agree, or its session is silently
  // attributed to a team it is not in. The prefix is read from the file name alone, so this check
  // cannot race the name derivation. The legacy team.json keeps its prefix in its content, and is
  // exempt.
  if (isClaude && teamFile !== null) {
    const expected = basename(teamFilePath, ".json");
    if (memberNamePrefix(member.name, member.role) !== expected) {
      fail(`member ${member.name} would be launched with AH_TEAM_FILE=${teamFilePath}, but a member of that team is named ${expected}-${member.role} or ${expected}-${member.role}-<n> (expected prefix "${expected}-") — nothing was launched`);
    }
  }
  const teamFileSetting = `--settings ${shQuote(JSON.stringify({ env: { AH_TEAM_FILE: teamFilePath } }))}`;
  const agentFlags = isClaude
    ? [`--agent ${agentRef}`, `--name ${member.name}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null, teamFileSetting].filter(Boolean)
    : [];
  // A non-claude member's permission flags are its autoMode translated into that CLI's own
  // vocabulary, placed ahead of its own args so an explicit native flag wins.
  const nativeArgs = isClaude ? null : (() => {
    const all = [...(kindAutoModeArgs(member) || []), ...(memberArgs(member) || [])];
    return all.length ? all : null;
  })();
  const claudeCmd = `claude ${agentFlags.join(" ")}`;
  if (transport === "herdr") return {
    transport,
    kind,
    args: nativeArgs ? [...nativeArgs] : null,
    // Layout is team-level and geometry-dependent: `roster.mjs layout-splits` computes and
    // performs the split sequence from live `herdr pane layout` output. See spec 0004 §3.2.
    layout: [],
    launch: [
      isClaude
        ? `herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`
        : `herdr agent start ${member.name} --kind ${kind} --pane <TARGET>${nativeArgs ? ` -- ${nativeArgs.map(shQuote).join(" ")}` : ""}`,
    ],
    // Placement comes from the layout step's own --cwd (runLayoutLoop :641), not from here —
    // carried for output parity (spec 0035 §2.2/§2.4).
    launch_cwd: cwd,
    target_placeholder: "<TARGET>",
    target_from: null,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
  if (transport === "tmux") return {
    transport,
    kind,
    args: null,
    // -P -F prints the new window's pane id: an untargeted `send-keys` writes to
    // whatever pane is active, which cannot survive two launches being in flight.
    layout: [`tmux new-window -P -F '#{pane_id}' -c "${cwd}"`],
    launch: [`tmux send-keys -t <TARGET> ${JSON.stringify(claudeCmd)} Enter`],
    // Placement comes from the layout step's own -c above, not from here — carried for output
    // parity (spec 0035 §2.2/§2.4).
    launch_cwd: cwd,
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "stdout", trim: true },
  };
  // Spec 0035 §2: the only branch with no separate layout step, so launch_cwd here is not just
  // for output parity — launchMember must actually apply it (§2.3), or the child inherits
  // roster.mjs's own process cwd instead of the resolved --cwd.
  return { transport, kind, args: null, layout: [], launch: [`${claudeCmd} --bg`], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null };
}

/** The role registry for this invocation's cwd and team, read once. */
function registry() {
  if (!registryCache) {
    try {
      registryCache = resolveConfig(cwd, { team: teamArg });
    } catch {
      registryCache = { roles: {}, sources: {}, excludedRoles: [], warnings: [], cwd };
    }
  }
  return registryCache;
}

/**
 * Re-run the class-contract validator at the spawn seam for a claude-kind member whose agent is
 * custom or overridden — the agent file may have changed since `role set`. Returns null for a
 * shipped built-in; otherwise `{agent, findings, notice}` or `{refuse, findings}`. A failing
 * custom role is refused; a failing built-in override falls back to the shipped `ah:<role>`.
 */
function spawnValidation(member) {
  if (resolveKind(member) !== KIND_DEFAULT) return null;
  const reg = registry();
  const entry = reg.roles && reg.roles[member.role];
  if (!entry) return { refuse: `role "${member.role}" is not defined here — roster.mjs role list`, findings: [] };
  if (isBuiltinRole(member.role) && !isOverride(member.role, entry)) return null;
  const result = validateRole(member.role, reg);
  const failed = hasContractErrors(result.findings);
  if (isBuiltinRole(member.role)) {
    if (!failed) return { agent: roleAgent(member.role, entry), findings: result.findings, notice: null };
    return { agent: `ah:${member.role}`, findings: result.findings, notice: `spawned ah:${member.role} in place of ${roleAgent(member.role, entry)} — that agent fails the ${roleClass(member.role, reg)} contract` };
  }
  if (failed) return { refuse: `role ${member.role}: agent ${entry.agent} fails the ${entry.class} contract, so ${member.name} was not launched:\n${formatFindings(result.findings)}`, findings: result.findings };
  return { agent: entry.agent, findings: result.findings, notice: null };
}

/** `spawnShape` behind the spawn-seam revalidation; findings and any fallback notice ride on `validation`. */
function shapeFor(member, transport) {
  const v = spawnValidation(member);
  const shape = v && v.refuse
    ? { transport, kind: resolveKind(member), layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: v.refuse }
    : spawnShape(member, transport, v ? v.agent : null);
  if (v && (v.refuse || v.notice || v.findings.length)) {
    shape.validation = { refused: Boolean(v.refuse), notice: v.notice || null, findings: v.findings };
    if (!v.refuse) {
      for (const f of v.findings) process.stderr.write(`roster.mjs: ${member.name}: ${formatFindings([f])}\n`);
      if (v.notice) process.stderr.write(`roster.mjs: ${member.name}: ${v.notice}\n`);
    }
  }
  return shape;
}

/**
 * Warn when a roster at `level` names a custom role defined only at a more specific level: another
 * repo (for a global roster) or another user (for a repo roster) resolving it would not see the role.
 */
function warnRoleVisibility(role, level) {
  if (isBuiltinRole(role)) return;
  const source = registry().sources[role];
  const rank = { user: 0, project: 1, "repo-user": 2 };
  const levelRank = { global: 0, repo: 1, "repo-user": 2 }[level];
  if (source && rank[source] > levelRank) {
    process.stderr.write(`roster.mjs: warning — role "${role}" is defined at ${source === "project" ? "repo" : source} level, below this ${level} roster; where that definition does not resolve, this member's role is unknown.\n`);
  }
}

/**
 * The layout a team being created uses, and where it came from: an explicit `--mode`, else the
 * global stored preference, else `auto`. A roster says nothing about layout.
 */
function createLayout() {
  if (opts.mode !== undefined) {
    if (!ROSTER_LAYOUT_VALUES.includes(opts.mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(opts.mode)}`);
    return { mode: opts.mode, source: "explicit" };
  }
  const pref = teamLayoutPreference();
  for (const w of pref.warnings) process.stderr.write(`roster.mjs: ${w}\n`);
  if (pref.layout) return { mode: pref.layout, source: "stored" };
  return { mode: "auto", source: "default" };
}

/**
 * An explicit `--mode` on a create that creates something becomes the default layout for future
 * teams. Losing the preference must not fail a create whose team already exists, so every failure
 * here is a warning — and a global file that does not parse is left untouched rather than replaced.
 */
function storeTeamLayout(layout) {
  if (layout.source !== "explicit") return;
  const path = rosterLevelPaths(cwd).global;
  try {
    let data = { version: CONFIG_VERSION };
    if (existsSync(path)) {
      const parsed = JSON.parse(readFileSync(path, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error(`${path} is not a JSON object`);
      data = parsed;
    }
    if (data.teamLayout === layout.mode) return;
    data.teamLayout = layout.mode;
    writeLevelFile(path, data);
  } catch (err) {
    process.stderr.write(`roster.mjs: warning — layout "${layout.mode}" was not stored as the default for future teams (${err && err.message ? err.message : String(err)}); the team itself is unaffected\n`);
  }
}

/** Plan-level herdr layout instructions for the orchestrator to drive (spec 0004 §5.2). Null for non-herdr or an all-subagent roster. */
function layoutPlan(mode, transport, plan) {
  if (transport !== "herdr") return null;
  const paneCount = plan.filter((m) => routeHasPane(m.route)).length;
  if (paneCount === 0) return null;
  return {
    mode,
    computed_by: "roster.mjs layout-splits",
    pane_count: paneCount,
    inspect_command: `herdr pane layout --current`,
    inspect_source: { kind: "json", path: ".result.layout.panes" },
    split_command: `herdr pane split --pane <SPLIT_TARGET> --direction <DIRECTION> --cwd "${cwd}" --no-focus`,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
}

/** `auto` resolves once from the final target pane count, never from splits done so far (spec 0004 §6.3). */
function effectiveMode(mode, paneCount) {
  if (mode !== "auto") return mode;
  return paneCount <= 2 ? "columns" : "grid";
}

/**
 * Pure greedy split-target algorithm (spec 0004 §6.7, amended). No I/O —
 * arithmetic over `self`, `created` (pane ids created so far, in creation
 * order) and `geometry` (`[{pane_id, rect: {width, height, x, y}}]`). `self`
 * is an ordinary candidate at every call, first in candidate order for
 * tie-breaking. Exists so the rule is unit-tested and the orchestrator never
 * improvises it.
 */
function nextSplit({ mode, paneCount, self, created, geometry }) {
  const byId = new Map(geometry.map((g) => [g.pane_id, g.rect]));
  let target = null;
  let bestArea = -1;
  for (const id of [self, ...created]) {
    const rect = byId.get(id);
    if (!rect) fail(`next-split: pane ${JSON.stringify(id)} is not present in the reported geometry`);
    const area = rect.width * rect.height;
    if (area > bestArea) {
      bestArea = area;
      target = id;
    }
  }
  const rect = byId.get(target);

  // Plan constants, spec 0007 §5.2 — derived from paneCount alone, no persisted state.
  const total = paneCount + 1;
  const bands = Math.max(total >= 3 ? 2 : 1, 2 ** Math.floor(Math.log2(total) / 2));
  const cols = Math.ceil(total / bands);

  // Root rect, spec 0007 §5.3 — bounding box of the candidate panes only.
  const cands = [self, ...created].map((id) => byId.get(id));
  const rootX = Math.min(...cands.map((r) => r.x));
  const rootY = Math.min(...cands.map((r) => r.y));
  const rootWidth = Math.max(...cands.map((r) => r.x + r.width)) - rootX;
  const rootHeight = Math.max(...cands.map((r) => r.y + r.height)) - rootY;

  // Direction rule, spec 0007 §5.4.
  let direction;
  if (effectiveMode(mode, paneCount) === "columns") {
    direction = "right";
  } else if (rootWidth > 0 && rootHeight > 0 && rect.height * 2 * bands > rootHeight * 3) {
    direction = "down"; // spans >1.5 bands
  } else if (rootWidth > 0 && rootHeight > 0 && rect.width * 2 * cols > rootWidth * 3) {
    direction = "right"; // spans >1.5 columns
  } else {
    direction = rect.width > rect.height * 2 ? "right" : "down"; // 0004 §6.1, verbatim
  }

  return { target, direction };
}

// Sole exec site for herdr (spec 0002 §11.3's grep assertion; spec 0005 extends the permitted
// callers to `create --spawn` alongside `layout-splits` — see tests/test-roster-layout-splits.sh).
function herdrCall(args, opts = {}) {
  const timeout = Number(process.env.AH_HERDR_TIMEOUT_MS || 10000);
  let stdout;
  try {
    stdout = execFileSync("herdr", args, { encoding: "utf8", timeout, maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    // Spec 0043 §1.6: `herdr agent get` on a missing name exits 1 and writes its error as JSON
    // on STDOUT, not stderr — so the failure path has to be inspectable, not just thrown. Kept
    // inside this function rather than adding a second exec site: spec 0002 §11.3's grep
    // assertion requires `herdr` to be spawned from exactly one place.
    if (opts.allowFailure && !err.signal) {
      return { ok: false, stdout: err.stdout ? String(err.stdout) : "", stderr: err.stderr ? String(err.stderr) : "", status: typeof err.status === "number" ? err.status : null };
    }
    if (err.signal) throw new Error(`herdr ${args.join(" ")} timed out after ${timeout}ms`);
    throw new Error(`herdr ${args.join(" ")} failed: ${(err.stderr && String(err.stderr).trim()) || err.message}`);
  }
  if (opts.allowFailure) return { ok: true, stdout, stderr: "", status: 0 };
  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(`herdr ${args.join(" ")} produced unparseable output`);
  }
}

/**
 * Spec 0043 §1.6: liveness AND readiness for a non-claude member, from `herdr agent get <name>`.
 * These are two different predicates for a Herdr-driven agent (they collapse into one only for a
 * Claude peer): a `blocked` agent sitting on a startup prompt is unambiguously LIVE — spawning a
 * second under the same name would be wrong — and unambiguously NOT READY.
 *
 * Three-way by design. "Herdr could not answer" is NOT "the agent is dead": the first thing a
 * caller does with "dead" is spawn a replacement, so a transient daemon outage would become
 * duplicate agents under names Herdr requires to be unique. Indeterminate must refuse the
 * operation instead.
 *
 * Returns `{live, indeterminate, why, agent_status, ready}`.
 */
const HERDR_LIVE_STATES = ["idle", "working", "blocked", "done", "unknown"];

function herdrAgentState(name) {
  if (!herdrOnPath()) {
    return { live: false, indeterminate: true, why: "no `herdr` binary on PATH — cannot ask whether this agent is live", agent_status: null, ready: false };
  }
  let res;
  try {
    res = herdrCall(["agent", "get", name], { allowFailure: true });
  } catch (err) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} failed: ${err.message}`, agent_status: null, ready: false };
  }
  let parsed = null;
  for (const stream of [res.stdout, res.stderr]) {
    if (typeof stream !== "string" || !stream.trim()) continue;
    try {
      parsed = JSON.parse(stream);
      break;
    } catch {
      // try the other stream
    }
  }
  if (!parsed) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} produced unparseable output`, agent_status: null, ready: false };
  }
  const code = parsed.error && parsed.error.code;
  // The ONLY signal that means "no such agent". Any other error code is Herdr failing to answer.
  if (code === "agent_not_found") {
    return { live: false, indeterminate: false, why: "agent_not_found", agent_status: null, ready: false };
  }
  if (code) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned error code ${JSON.stringify(code)}`, agent_status: null, ready: false };
  }
  const agent = parsed.result && parsed.result.agent;
  if (!agent || typeof agent !== "object") {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned no .result.agent`, agent_status: null, ready: false };
  }
  const status = typeof agent.agent_status === "string" ? agent.agent_status : null;
  // A non-claude record carries no `agent_session` key and a claude one does — deliberately NOT
  // branched on, so both kinds take one code path through `agent_status`.
  //
  // §1.6's "anything else" row: only a status Herdr has told us is terminal can mean not-live.
  // A missing status, or one this build does not recognize (a newer Herdr, a state added later),
  // is Herdr declining to answer — indeterminate. Reading it as a definite not-live is the
  // duplicate-spawn bug: the caller starts a second agent under a name Herdr requires unique.
  if (status === null) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned no agent_status`, agent_status: null, ready: false };
  }
  // §1.6's table has exactly ONE not-live row — exit 1 with `agent_not_found`, handled above.
  // A status outside the live set is therefore not a fifth terminal state this build happens not
  // to know; it is Herdr saying something this build cannot interpret, which is the "anything
  // else" row.
  if (!HERDR_LIVE_STATES.includes(status)) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned unrecognized agent_status ${JSON.stringify(status)}`, agent_status: status, ready: false };
  }
  const live = true;
  // Readiness: Herdr's own cross-kind normalized answer. ABSENT IS NOT FALSE — the field was not
  // present on the claude payload, and reading absent-as-false would mark every ready Claude
  // member unpromptable. Absent falls back to the lifecycle set.
  const ready =
    agent.interactive_ready === undefined || agent.interactive_ready === null
      ? status !== null && ["idle", "done"].includes(status)
      : agent.interactive_ready === true;
  return { live, indeterminate: false, why: `agent_status ${status}`, agent_status: status, ready };
}

/**
 * Live herdr topology: agent name (if any) plus pane/tab/workspace ids for every live pane
 * (spec 0008 §5.2). `herdr agent list` is the preferred single-call source — field names
 * (`.result.agents[].{name?,pane_id,tab_id,workspace_id}`) verified against a live herdr this
 * session; `name` is absent for a pane hosting no `herdr agent start`-named agent. `cwd` (spec
 * 0025 §12.3) is read from either `cwd` or `foreground_cwd` — the true key is unconfirmed and
 * this repo consumed neither before now, so both are read as cheap insurance.
 */
let herdrTopologyCache = null;

function queryHerdrTopology() {
  if (herdrTopologyCache) return herdrTopologyCache;
  const result = herdrCall(["agent", "list"]);
  const agents = result && result.result && Array.isArray(result.result.agents) ? result.result.agents : null;
  if (!agents) throw new Error("herdr agent list produced unexpected shape (missing .result.agents)");
  // Cached for the life of the process: several readers (resync, the dismiss name forms, the
  // live-registry herdr arm) want the same snapshot, and one command must cost one exec.
  herdrTopologyCache = agents.map((a) => ({
    name: a.name || null,
    // The pane title roster itself sets with `herdr pane rename`. An agent registered through
    // `herdr agent start` reports `name`; one herdr detected in a pane on its own reports only
    // the title, so both are carried and the reader decides which it trusts.
    title: (a.terminal_title_stripped && String(a.terminal_title_stripped)) || null,
    session_id: (a.agent_session && typeof a.agent_session.value === "string" && a.agent_session.value) || null,
    pane_id: a.pane_id,
    tab_id: a.tab_id,
    workspace_id: a.workspace_id,
    cwd: a.cwd || a.foreground_cwd || null,
  }));
  return herdrTopologyCache;
}

/** Spec 0008 §5.3: name first (durable across workspace moves), pane id second, else no match. */
function matchMemberToPane(member, topology) {
  if (member.name) {
    const byName = topology.find((p) => p.name === member.name);
    if (byName) return byName;
  }
  if (member.transport_id) {
    const byId = topology.find((p) => p.pane_id === member.transport_id);
    if (byId) return byId;
  }
  return null;
}

/**
 * Pure heal pass over `team.members` against live herdr topology (spec 0008 §5.1, multi-pass
 * matching added spec 0025 §12.3-§12.6). No I/O beyond the topology query and, when `dir`/`teamCwd`
 * are supplied, reading peers.jsonl — never writes team.json. Shared by `resync` (persists the
 * result, and the only caller that can supply `dir`/`teamCwd`/`selfPaneId`/`bind`) and `disband`'s
 * bare/`--plan` path plus `move` (both call with no options object, so passes 2/3 and `--bind` are
 * inert and behavior is byte-identical to before this amendment).
 *
 * Returns `{ members, counts, query_ok, query_error, warning?, bind_error? }`; on topology-query
 * failure `members`/`counts` are null and the caller decides whether to fail() (resync/move) or
 * degrade (disband). On a `--bind` validation failure `members`/`counts` are also null (no partial
 * application) and `bind_error` names the problem — the caller must fail() before any write.
 *
 * Pass 1 (identity, via `matchMemberToPane`) is unchanged in behavior. Passes 2 (peers.jsonl exact
 * match) and 3 (cwd narrowing) consider only members pass 1 left `not_found` with `transport_id ===
 * null` — a member that HAD a transport_id and failed pass 1 stays `not_found` forever, since it
 * moved or died and a weaker signal must not re-home it onto another session's pane.
 */
function resyncMembers(team, { dir = null, teamCwd = null, selfPaneId = null, bind = null } = {}) {
  let topology;
  try {
    topology = queryHerdrTopology();
  } catch (err) {
    return { members: null, counts: null, query_ok: false, query_error: err.message };
  }
  const claimed = new Set();
  let duplicate = false;
  const counts = { updated: 0, unchanged: 0, not_found: 0, skipped: 0, malformed: 0, ambiguous: 0 };

  // Pass 1 — identity. Behavior for every member matching here is unchanged from before §12.3.
  const members = team.members.map((m) => {
    // Spec 0025 §6: a malformed (non-object) entry must round-trip byte-identical, never `{ ...m }` —
    // spreading a string produces exactly the char-indexed garbage that corrupted team.json in the wild.
    if (!m || typeof m !== "object" || Array.isArray(m)) {
      counts.malformed++;
      return m;
    }
    if (!routeHasPane(m.route)) {
      counts.skipped++;
      return { ...m, status: "skipped" };
    }
    let match = matchMemberToPane(m, topology);
    if (match && claimed.has(match.pane_id)) {
      duplicate = true; // spec 0008 §7.6: first match wins, later claimants fall through to not_found
      match = null;
    }
    if (!match) {
      counts.not_found++;
      return { ...m, status: "not_found", transport_stale: true };
    }
    claimed.add(match.pane_id);
    const from = { transport_id: m.transport_id, tab_id: m.tab_id, workspace_id: m.workspace_id };
    const to = { transport_id: match.pane_id, tab_id: match.tab_id, workspace_id: match.workspace_id };
    const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
    delete healed.transport_stale;
    if (from.transport_id !== to.transport_id || from.tab_id !== to.tab_id || from.workspace_id !== to.workspace_id) {
      counts.updated++;
      return { ...healed, status: "updated", from, to };
    }
    counts.unchanged++;
    return { ...healed, status: "unchanged" };
  });

  // --bind (spec 0025 §12.5): validate every entry as a WHOLE before applying any of them, so a
  // validation failure never partially writes. Claims its panes before pass 2, so an explicit
  // instruction always outranks an inferred one.
  if (bind) {
    const topologyIds = new Set(topology.map((p) => p.pane_id));
    const knownNames = members.filter((m) => m && typeof m === "object" && !Array.isArray(m)).map((m) => m.name).filter(Boolean);
    // Seeded from `claimed` and grown as each entry validates, so a later entry in the SAME
    // --bind object sees an earlier entry's claim — `claimed` alone only reflects pass 1.
    const willClaim = new Set(claimed);
    for (const [name, paneId] of Object.entries(bind)) {
      const idx = members.findIndex((m) => m && typeof m === "object" && !Array.isArray(m) && m.name === name);
      if (idx === -1) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: unknown member "${name}" (known: ${knownNames.join(", ") || "none"})` };
      }
      if (!routeHasPane(members[idx].route)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: member "${name}" has route "${members[idx].route}", not "peer"` };
      }
      if (!topologyIds.has(paneId)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is not in live herdr topology` };
      }
      if (willClaim.has(paneId)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is already claimed` };
      }
      if (selfPaneId && paneId === selfPaneId) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is the caller's own pane` };
      }
      willClaim.add(paneId);
    }
    for (const [name, paneId] of Object.entries(bind)) {
      const idx = members.findIndex((m) => m.name === name);
      const m = members[idx];
      const topo = topology.find((p) => p.pane_id === paneId);
      const from = { transport_id: m.transport_id, tab_id: m.tab_id, workspace_id: m.workspace_id };
      const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
      const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
      delete healed.transport_stale;
      claimed.add(paneId);
      // Decrement whichever bucket the member actually held before the bind — a --bind target
      // is not required to be `not_found` (spec 0025 §12.5 lists no such restriction), so it may
      // already be `updated`/`unchanged` from pass 1.
      if (m.status === "not_found") counts.not_found--;
      else if (m.status === "unchanged") counts.unchanged--;
      else if (m.status === "updated") counts.updated--;
      counts.updated++;
      members[idx] = { ...healed, status: "updated", from, to, match_by: "bind" };
    }
  }

  // Recomputed fresh each time rather than snapshotted once — pass 2's binds must be visible to
  // pass 3's gating (exactly one member still awaiting repair).
  const awaitingRepair = () =>
    members.map((m, i) => ({ m, i })).filter(({ m }) => m && typeof m === "object" && !Array.isArray(m) && m.status === "not_found" && m.transport_id == null);

  // Pass 2 — peers.jsonl exact match (spec 0025 §12.4). Only runs when the caller can locate both
  // the peer roster and the team's directory.
  if (dir && teamCwd) {
    const teamCwdReal = realCwd(teamCwd);
    const liveRoster = latestRoster(dir);
    const topologyIds = new Set(topology.map((p) => p.pane_id));
    for (const { m, i } of awaitingRepair()) {
      const candidates = liveRoster.filter(
        (rec) =>
          rec.status === "up" &&
          pidAlive(rec.pid) &&
          rec.pane_id != null &&
          rec.cwd != null &&
          realCwd(rec.cwd) === teamCwdReal &&
          rec.role === m.role &&
          topologyIds.has(rec.pane_id) &&
          !claimed.has(rec.pane_id) &&
          rec.pane_id !== selfPaneId
      );
      // Two members sharing a role and both awaiting repair each see both records here (>1), so
      // both correctly fall through to pass 3 rather than being zipped — no separate role-grouping
      // pass needed (spec 0025 §12.4, §14 item 12).
      if (candidates.length !== 1) continue;
      const rec = candidates[0];
      const topo = topology.find((p) => p.pane_id === rec.pane_id);
      claimed.add(rec.pane_id);
      counts.not_found--;
      counts.updated++;
      const from = { transport_id: null, tab_id: m.tab_id, workspace_id: m.workspace_id };
      const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
      const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
      delete healed.transport_stale;
      members[i] = { ...healed, status: "updated", from, to, match_by: "peers_jsonl" };
    }
  }

  // Pass 3 — cwd narrowing (spec 0025 §12.5-§12.6). Auto-bind only when the caller's own pane is
  // known AND excluded, exactly one candidate pane remains, and exactly one member awaits repair —
  // never zip N members onto N candidates by order (spec 0025 §14 item 9). Every other shape reports
  // `ambiguous` with the candidate list rather than guessing.
  if (teamCwd) {
    const teamCwdReal = realCwd(teamCwd);
    // Raw candidates (before self-pane exclusion) decide zero vs. many; `candidatePanes` (after
    // exclusion) decides auto-bind eligibility and what gets reported. A single raw candidate that
    // turns out to be the caller's own pane is NOT "zero" — a pane genuinely exists there, it is
    // just unsafe to guess, which is the "ambiguous" case, not "not_found" (spec 0025 §12.5,
    // Architect ruling 2026-08-27).
    const rawCandidates = topology.filter((p) => p.cwd != null && realCwd(p.cwd) === teamCwdReal && !claimed.has(p.pane_id));
    const candidatePanes = rawCandidates.filter((p) => p.pane_id !== selfPaneId);
    const awaiting = awaitingRepair();
    const autoBindEligible = selfPaneId != null && candidatePanes.length === 1 && awaiting.length === 1;
    for (const { m, i } of awaiting) {
      if (autoBindEligible) {
        const topo = candidatePanes[0];
        claimed.add(topo.pane_id);
        counts.not_found--;
        counts.updated++;
        const from = { transport_id: null, tab_id: m.tab_id, workspace_id: m.workspace_id };
        const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
        const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
        delete healed.transport_stale;
        members[i] = { ...healed, status: "updated", from, to, match_by: "cwd" };
      } else if (rawCandidates.length === 0) {
        // Nothing ambiguous about a member with no candidate pane — it is simply not running,
        // which is what `not_found` already means on the pass-1 path. `transport_stale` means
        // "the id we had is now wrong"; a repair-case member never had one, so strip it.
        const { transport_stale, ...clean } = m;
        members[i] = { ...clean, status: "not_found" };
      } else {
        counts.not_found--;
        counts.ambiguous++;
        members[i] = {
          ...m,
          status: "ambiguous",
          candidates: candidatePanes.map((p) => ({ pane_id: p.pane_id, tab_id: p.tab_id, workspace_id: p.workspace_id, cwd: p.cwd })),
        };
      }
    }
  }

  return { members, counts, query_ok: true, query_error: null, warning: duplicate ? "duplicate pane match" : undefined };
}

/** Strip resyncMembers()'s per-pass bookkeeping fields before a healed member array is persisted. */
function stripResyncMeta(m) {
  // A malformed (non-object) passthrough must stay byte-identical — object-destructuring a
  // string here would recreate the same char-indexed corruption this guards against (spec 0025 §6).
  if (!m || typeof m !== "object" || Array.isArray(m)) return m;
  const { status, from, to, match_by, candidates, ...member } = m;
  return member;
}

/** Spec 0008 §4: the no-op reason for a non-herdr transport, shared by `resync` and `move`. */
function transportNoop(transport) {
  return transport === "tmux" ? "transport tmux not supported (spec 0008 §4)" : "transport terminal has no panes";
}

/** Spec 0004 §6.6 sequential split loop, shared by `layout-splits` (bare form) and `create --spawn`'s layout phase (spec 0005 §4 step 3). Stops at the first failure. */
function runLayoutLoop({ mode, paneCount, self, splitCwd, seedPanes = [] }) {
  const panes = [];
  const splits = [];
  for (let i = 1; i <= paneCount; i++) {
    let geomResult;
    try {
      geomResult = herdrCall(["pane", "layout", "--current"]);
    } catch (err) {
      if (panes.length === 0) fail(err.message);
      partial({ panes, splits, mode, pane_count: paneCount, complete: false, failed_at: i, attempted: null, error: err.message });
    }
    const geometry = geomResult.result.layout.panes;

    // Seed the candidate set with sibling panes that are actually on screen right now.
    // Filtered against live geometry every iteration: a stale transport_id in team.json is
    // routine (it is why `resync` exists), and an absent candidate is a hard fail in nextSplit.
    const present = new Set(geometry.map((g) => g.pane_id));
    const liveSeed = [...new Set(seedPanes)].filter((id) => id !== self && present.has(id));

    const decision = nextSplit({
      mode,
      paneCount: liveSeed.length + paneCount, // live total: what is on screen + what we are adding
      self,
      created: [...liveSeed, ...panes],
      geometry,
    });
    let splitResult;
    try {
      splitResult = herdrCall(["pane", "split", "--pane", decision.target, "--direction", decision.direction, "--cwd", splitCwd, "--no-focus"]);
    } catch (err) {
      if (panes.length === 0) fail(err.message);
      partial({ panes, splits, mode, pane_count: paneCount, complete: false, failed_at: i, attempted: decision, error: err.message });
    }
    const newPaneId = splitResult.result.pane.pane_id;
    panes.push(newPaneId);
    splits.push({ i, target: decision.target, direction: decision.direction, pane_id: newPaneId });
  }
  return { panes, splits };
}

/** Spec 0011 §7.2: `--team <T>` cannot equal the effective unscoped prefix while a default team with
    a RUNNING ORCHESTRATOR exists — two teams would derive the same peer names, and tagging cannot fix
    ListAgents' namespace. Owner-alive is the whole test here: neither `teamIsLive` (which also expires
    on age) nor `teamIsOrphaned` — a name stays taken for as long as someone is dispatching under it,
    however old the team file is. */
function guardTeamPrefixCollision(dir, team) {
  if (!team) return;
  const unscoped = teamPrefix(cwd, null);
  if (team !== unscoped) return;
  const existing = readTeam(dir, null);
  if (existing && pidAlive(existing.orchestrator && existing.orchestrator.pid)) {
    fail(`--team ${JSON.stringify(team)} equals the effective default prefix "${unscoped}", and a default team whose orchestrator is still running (${existing.team_id}) already exists — pick a different --team name`);
  }
}

/** Spec 0011 §5.3: effective prefix, then -2, -3, ... until a name has no `teams/<name>.json` yet
    and is itself `validateTeamAlias`-clean. The bare prefix is never offered here — the caller only
    reaches this path because a live default team already holds it (§7.2 would refuse it anyway). */
function deriveTeamCandidate(dir, basePrefix) {
  // Every candidate is `<basePrefix>-<n>`, so a basePrefix that cannot clear the validator makes
  // all 1000 of them fail — and the caller then reports an exhausted search instead of the one
  // thing the user can act on. Spec 0044 [9.1]'s refusal is the correct answer here.
  if (!validateTeamAlias(basePrefix).ok) {
    const transport = detectTransport();
    const block = newTeamBlock(dir);
    refuseTeamName(basePrefix, teamNameSource(), teamNameProblem(basePrefix, transport, block) || { why: validateTeamAlias(basePrefix).why, failing_member: null }, transport, block);
  }
  for (let n = 2; n <= 1000; n++) {
    const candidate = `${basePrefix}-${n}`;
    if (validateTeamAlias(candidate).ok && !readTeam(dir, candidate)) return candidate;
  }
  fail(`could not derive a free --team candidate from "${basePrefix}" after 1000 attempts`);
}

/** Spec 0011 §5.3: the hybrid prompt. `create` cannot read stdin (it runs inside an agent session,
    not a TTY), so a bare `create` colliding with someone else's live default team refuses with a
    candidate name instead of guessing — SKILL.md surfaces this via AskUserQuestion. */
function refuseLiveDefaultTeam(dir, existing) {
  const basePrefix = teamPrefix(cwd, null);
  const candidate = deriveTeamCandidate(dir, basePrefix);
  const members = Array.isArray(existing.members) && existing.members.length > 0;
  fail(
    `a live team "${existing.team_id}" (orchestrator pid ${existing.orchestrator && existing.orchestrator.pid}) already holds the name "${basePrefix}" here, ` +
      (members ? `and its members are dispatched under that prefix. ` : `but it has no members: \`disband\` ends it. `) +
      `Re-run with --team ${candidate} to accept the auto-derived name, or --team <your-name> to choose your own.`
  );
}

/** Who runs this command, for deciding which team it owns: its pid, and its session id when
    `--session` supplies one. */
function invokerIdentity() {
  return { pid: ownOrchestratorPid(), sessionId: typeof opts.session === "string" ? opts.session : null };
}

/** The pid this session claims as its own, resolved exactly as the commit path resolves it
    (spec 0018 §3): `--orchestrator-pid` wins, else `CLAUDE_PID`. NaN when neither is usable. */
function ownOrchestratorPid() {
  return typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
}

/** The pane this session sits in: the transport's own env first, then what SessionStart
    recorded for it (`record` is the session's peers.jsonl row, or null). */
function sessionPaneId(record) {
  return process.env.HERDR_PANE_ID || (record && record.pane_id) || process.env.TMUX_PANE || null;
}

/**
 * Spec 0044 §1.11: the team already at the RESOLVED scope is consulted before `create` writes.
 * Ownership, not liveness, is the line — refusing every live team would break 0015's supported
 * commit-twice, and allowing every re-commit destroys a team another session is running.
 *
 * Only the commit path is answered here. `--plan` and `--spawn` reach `refuseOrClearExistingTeam`
 * through `getMembersPlan`, which already refuses ANY live team at the scope — both live rows of
 * §1.11's table — and `createSpawn` writes no team file of its own. Re-refusing them here would
 * only replace their message with a worse one.
 */
function guardLiveTeamAtScope(dir, { committing }) {
  const existing = readTeam(dir, teamFile);
  if (!existing || !teamIsLive(existing, invokerIdentity())) return;
  if (!committing) return;
  const ownerPid = existing.orchestrator && existing.orchestrator.pid;
  const myPid = ownOrchestratorPid();
  if (teamOwnedBy(existing, invokerIdentity())) return;
  if (Number.isInteger(myPid) && ownerPid === myPid) {
    fail(
      `create --commit: team ${existing.team_id} at this scope records session ${existing.orchestrator.session_id}, not this one (${invokerIdentity().sessionId}), ` +
        `so its pid ${ownerPid} is not evidence this session owns it — disband it first, or commit under a different --team`
    );
  }
  // Constraint 2: no `--team <candidate>` in either refusal. The members in `--verified` already
  // carry names derived from the original prefix, so committing them under a different team name
  // is the two-identity-axes disagreement §1.1 exists to end. Point at disband instead.
  if (!Number.isInteger(myPid)) {
    // Without an own pid, ownership cannot be established either way — so this refuses like the
    // foreign case, but must not ASSERT the team is foreign: it may well be this session's own.
    fail(
      `create --commit: a live team ${existing.team_id} (orchestrator pid ${ownerPid}) holds this scope, and this ` +
        `session has no pid of its own to compare against — pass --orchestrator-pid <pid> (or set CLAUDE_PID) to ` +
        `commit it as yours, or disband it first`
    );
  }
  fail(
    `create --commit: team ${existing.team_id} at this scope is owned by another live orchestrator (pid ${ownerPid}) — ` +
      `disband it first, or have that session commit its own team`
  );
}

/** Shared by `resolveMembersPlan` and `planMembersFromHistory` (spec 0015 §7.2): refuse a live Team, clear a stale one. */
function refuseOrClearExistingTeam(dir) {
  resolveWritableTeamScope(dir, { replacing: true });
  const existing = readTeam(dir, teamFile);
  if (!existing) return;
  if (teamIsLive(existing, invokerIdentity())) {
    // Spec 0044 §1.1 (fork F3): a scope the caller did not name is one this command derived, so a
    // collision there is answered with a free candidate to accept — never silently applied. An
    // explicit `--team` the user chose gets the plain "disband it first" instead.
    if (teamFileDefaulted) refuseLiveDefaultTeam(dir, existing);
    fail(`a live Team ${existing.team_id} already exists${existing.members.length === 0 ? " but has no members" : ""} — disband it first`);
  }
  clearTeam(dir, teamFile);
}

/** Settles which team file a create/spawn verb writes to, then refuses (exit 2) when that file exists but cannot be read. */
function resolveWritableTeamScope(dir, { replacing = false, committing = false } = {}) {
  settleWritableTeamScope(dir, { replacing, committing });
  // A writing verb never writes over a team file it cannot read — it may still describe a running
  // team. Checked on whichever file the scope settled on, and before anything launches, so a
  // refusal strands no session.
  const target = teamFileState(dir, teamFile);
  if (target.state === "unusable") {
    const escape = teamFileDefaulted ? "pass an explicit --team <name>" : "name a different --team";
    fail(`the team file ${target.path} exists but cannot be read, so it will not be written over or beside — nothing was written. Repair or remove that file, or ${escape}`);
  }
}

/**
 * The two things §1.1's invariant demands at the moment a team would be CREATED, both of which
 * §1.7's read-side leniency has to be kept away from. Only the create/spawn family calls this —
 * `disband`, `dismiss`, `resync`, `reap` and `adopt` must keep resolving to whatever is there,
 * because operating on it in place is exactly what §1.7 promises.
 *
 * [9.1] A prefix that cannot name a file refuses here rather than at scope resolution, so `show`,
 * `init` and `add` still work in such a repo.
 *
 * (Reviewer B1) A legacy `team.json` resolves for reading whenever one exists, but a team whose
 * owner is gone must not be written into: it would be cleared and a brand-new team put straight
 * back into the shared default, which is self-perpetuating in exactly the pre-0044 repos §1.7
 * exists for. Re-point at the named path and leave the stale file for `reap`. A LIVE legacy team
 * is still written into — that team is the one §1.7 is carrying across the upgrade.
 */
function settleWritableTeamScope(dir, { replacing, committing }) {
  // An unreadable legacy file keeps the scope: retargeting would start a second team beside it.
  if (teamFile !== null || !teamFileDefaulted || teamFileUnreadable) return;
  const legacy = readTeam(dir, null);
  // Which legacy team may still be written into depends on what the caller is about to do, and
  // the two predicates are deliberately different:
  // - JOINING one (`spawn-one`, `spawn-ad-hoc`): `teamIsOrphaned`, never `!teamIsLive`. The
  //   latter also flags a team past the staleness window whose orchestrator is still running,
  //   and moving new members of that team to a second file splits it — what §1.7 forbids.
  // - REPLACING it (`create`): `teamIsLive`, matching `refuseOrClearExistingTeam`'s own rule one
  //   step later, so the file it is about to clear is never also the file it writes the
  //   replacement into. A live one is refused outright just below.
  if (legacy && (replacing ? teamIsLive(legacy, invokerIdentity()) : !teamIsOrphaned(legacy))) {
    // Declining to retarget cannot be the whole answer on the replacing path: the caller would
    // then write straight over the running team's members in the shared default, which is the one
    // thing §1.1 forbids outright. Refuse here so `--commit` and `--spawn` get the answer `--plan`
    // already gave.
    // §1.11 constraint 1: this refusal runs BEFORE the ownership gate, so leaving it
    // unconditional would make the new rule unreachable for every pre-0044 team — an
    // orchestrator re-committing its OWN live legacy team would still be refused here. The
    // commit path falls through to `guardLiveTeamAtScope`, which knows about ownership;
    // `--plan`/`--spawn` keep this message, where offering a candidate name is still right.
    if (replacing && !committing) refuseLiveDefaultTeam(dir, legacy);
    return;
  }
  if (teamFileUnnamable) {
    const transport = detectTransport();
    const block = newTeamBlock(dir);
    refuseTeamName(teamFileUnnamable, teamNameSource(), teamNameProblem(teamFileUnnamable, transport, block) || { why: validateTeamAlias(teamFileUnnamable).why, failing_member: null }, transport, block);
  }
  teamFile = teamPrefix(cwd, null);
}

/** Shared by `create --plan` and `create --spawn` (spec 0005 §9 item 1): resolve the roster, refuse/clear a stale Team, compute members[] + spawn shapes. */
function resolveMembersPlan(dir) {
  refuseOrClearExistingTeam(dir);
  const resolved = resolveRoster(cwd, rosterArg, repoBasename, registry());
  if (!resolved) fail("no roster resolves at any level — hand off to `roster.mjs init`");
  const transport = detectTransport();
  const members = renameInUse(resolved.members, repoBasename);
  const models = memberModelOverrides(members);
  const rows = members.map((row) => withModel(row, models.get(row.name)));
  const skipped = rows.filter((m) => routeHasPane(m.route || resolved.route) && autoSkipped(m));
  const planned = rows.filter((m) => !skipped.includes(m));
  const plan = planned.map((m) => {
    const route = m.route || resolved.route;
    return { role: m.role, name: m.name, kind: resolveKind(m), model: m.model, effort: m.effort, route, autoMode: m.autoMode, args: memberArgs(m), spawn: routeHasPane(route) ? shapeFor({ ...m, route }, transport) : null };
  });
  const layout = createLayout();
  const named = namedRosterKeys(cwd);
  const result = { level: resolved.level, path: resolved.path, transport, layout, layout_plan: layoutPlan(layout.mode, transport, plan), members: plan, ...(named.length ? { named_rosters: named } : {}), ...renamedField(planned) };
  return withSkipped(result, skipped.map(skippedEntry));
}

/** `create --from <id|alias>` (spec 0015 §7.2): resolve which history entry `--from` names. */
function resolveHistoryEntry(dir) {
  const key = opts.from;
  const h = readHistory(dir);
  const byId = h.teams.find((t) => t.id === key);
  if (byId) return byId;
  const byAlias = h.teams.filter((t) => t.alias === key).sort((a, b) => (a.last_used < b.last_used ? 1 : -1));
  if (byAlias.length) return byAlias[0];
  fail(`create --from: no history entry matches ${JSON.stringify(key)} — available ids: ${h.teams.map((t) => t.id).join(", ") || "(none)"}`);
}

/**
 * Rename stored history members (role/model/effort/route/auto_mode, snake_case, no name — spec
 * 0015 §3.1) to the plan-shape's camelCase `autoMode` and validate. Renaming before validating
 * matters: `validateMember` checks the camelCase key and rejects any member carrying a "name"
 * (spec §7.2: the rename is history->plan only, one direction). Returns the renamed members, or
 * `fail()`s naming the invalid field — never silently repairs a stale entry.
 */
function validateHistoryMembers(entry) {
  const stored = Array.isArray(entry.members) ? entry.members : [];
  const renamed = stored.map((m) => {
    const out = { role: m.role, model: m.model, effort: m.effort, route: m.route };
    if (m.auto_mode !== undefined) out.autoMode = m.auto_mode;
    return out;
  });
  const rosterBlock = normalizeRosterBlock({ route: (renamed[0] && renamed[0].route) || "peer", members: renamed }, registry());
  const errors = validateRosterBlock(rosterBlock, registry());
  if (errors.length) fail(errors.join("; "));
  return renamed;
}

/**
 * `create --from <id|alias>` (spec 0015 §7.2): the member source is a stored history entry
 * instead of a live roster level. Everything downstream — refuse/clear a stale Team, validation,
 * derived names, spawn shapes — is the existing `resolveMembersPlan` path, unchanged.
 */
function planMembersFromHistory(entry, dir) {
  refuseOrClearExistingTeam(dir);
  const renamed = validateHistoryMembers(entry);
  const rosterBlock = normalizeRosterBlock({ route: (renamed[0] && renamed[0].route) || "peer", members: renamed }, registry());
  const transport = detectTransport();
  const named = renameInUse(namedMembers(rosterBlock.members), repoBasename);
  const models = memberModelOverrides(named);
  const rows = named.map((row) => withModel(row, models.get(row.name)));
  const skipped = rows.filter((m) => routeHasPane(m.route || rosterBlock.route) && autoSkipped(m));
  const planned = rows.filter((m) => !skipped.includes(m));
  const plan = planned.map((m) => {
    const route = m.route || rosterBlock.route;
    return { role: m.role, name: m.name, kind: resolveKind(m), model: m.model, effort: m.effort, route, autoMode: m.autoMode, args: memberArgs(m), spawn: routeHasPane(route) ? shapeFor({ ...m, route }, transport) : null };
  });
  const layout = createLayout();
  const result = { level: entry.roster_level || null, path: null, transport, layout, layout_plan: layoutPlan(layout.mode, transport, plan), members: plan, ...renamedField(planned) };
  return withSkipped(result, skipped.map(skippedEntry));
}

/** The members a create run is planned from, named and with their effective routes, without planning
    it: the history entry's with --from, else the roster's. */
function createSourceMembers(dir) {
  if (typeof opts.from === "string") {
    const renamed = validateHistoryMembers(resolveHistoryEntry(dir));
    const block = normalizeRosterBlock({ route: (renamed[0] && renamed[0].route) || "peer", members: renamed }, registry());
    return renameInUse(namedMembers(block.members), repoBasename).map((m) => ({ ...m, route: m.route || block.route }));
  }
  const resolved = resolveRoster(cwd, rosterArg, repoBasename, registry());
  return resolved ? renameInUse(resolved.members, repoBasename).map((m) => ({ ...m, route: m.route || resolved.route })) : [];
}

/** `create`'s member source: history (`--from`) or the live roster (default). */
function getMembersPlan(dir) {
  return typeof opts.from === "string" ? planMembersFromHistory(resolveHistoryEntry(dir), dir) : resolveMembersPlan(dir);
}

function runShell(commandString, opts = {}) {
  return new Promise((resolvePromise) => {
    execFile("/bin/sh", ["-c", commandString], { encoding: "utf8", maxBuffer: 1024 * 1024, cwd: opts.cwd }, (err, stdout, stderr) => {
      resolvePromise({ err, stdout, stderr });
    });
  });
}

/**
 * Best-effort peer-pane border label (spec 0014) — herdr's
 * `show_agent_labels_on_pane_borders` is a boolean, not a template, so no
 * config key composes "claude" + the member's name. If herdr ever gains a
 * label template, this workaround should be retired, not extended. Must
 * never throw: `launchMember()`'s caller (`:538`) maps a rejected promise to
 * `launch_status: "failed"`, and a cosmetic label error is not a launch
 * outcome.
 */
function labelPane(member) {
  try {
    // Spec 0043 §1.4: the kind, not the literal "claude" — a codex member's pane must read as
    // codex. `member.kind` is always explicit here (defaulted at the read seam, §1.1).
    herdrCall(["pane", "rename", member.transport_id, resolveKind(member), "-", member.name]);
    return null;
  } catch {
    return "failed";
  }
}

/**
 * Spec 0043 §1.4: Herdr reports launch problems as JSON with an `error.code`, and — verified
 * live (r4) — writes that JSON to STDOUT on the error path, not stderr. A reader that inspects
 * only stderr finds an empty string and silently misreads the outcome, so both are parsed.
 * Returns the error code, or null when nothing parseable carries one.
 */
function herdrErrorCode(attempt) {
  for (const stream of [attempt.stdout, attempt.stderr]) {
    if (typeof stream !== "string" || !stream.trim()) continue;
    try {
      const parsed = JSON.parse(stream);
      const code = parsed && parsed.error && parsed.error.code;
      if (typeof code === "string" && code) return code;
    } catch {
      // not JSON — try the other stream
    }
  }
  return null;
}

/**
 * A failed herdr launch leaves the pane split for it behind, and the user would have to close it
 * by hand. When no agent registered under the member's name, the pane's recent output — usually
 * the only explanation of the failure — is captured into the report, then the pane is closed.
 * A pane is left open, with its close command as the remedy, only when an agent may be live in it
 * or the close itself fails.
 */
function closeOrphanPane(member) {
  const id = member.transport_id;
  if (!id) return { remedy: "the agent name never registered" };
  const keep = { orphaned_transport_id: id, remedy: `the pane is orphaned (the agent name never registered) — close it with \`herdr pane close ${id}\`` };
  if (herdrAgentState(member.name).live) return keep;
  const call = (args) => {
    try {
      return herdrCall(args, { allowFailure: true });
    } catch {
      return { ok: false, stdout: "" };
    }
  };
  const read = call(["pane", "read", id, "--source", "recent-unwrapped", "--lines", "40"]);
  const closed = call(["pane", "close", id]);
  const paneOutput = read.ok && read.stdout.trim() ? read.stdout.trim() : null;
  if (!closed.ok) return { ...keep, pane_output: paneOutput };
  return { closed_pane: id, pane_output: paneOutput };
}

/**
 * One member's launch, with the herdr-only retry (spec 0005 §4 step 6). NEEDS-EVIDENCE item 2 (§9)
 * is unresolved — no live pane was available to reproduce the retryable "pane busy" condition, only
 * the non-retryable ones (bad --kind, nonexistent pane) — so this uses the spec's documented safe
 * fallback: retry once on any herdr failure, herdr-only.
 */
async function launchMember(member, transport) {
  // Spec 0043 §1.4: a member whose kind cannot be started on this transport (or whose config is
  // invalid) is REFUSED — nothing is shelled for it at all, and it fails alone so the rest of a
  // mixed `create --spawn` still launches.
  if (member.spawn.refuse) {
    return { ...member, launch_status: "failed", launch_result: { reason: "refused", detail: member.spawn.refuse }, retried: false, error: member.spawn.refuse };
  }
  const template = member.spawn.launch[0];
  const cmd = member.spawn.target_placeholder && member.transport_id != null ? template.split(member.spawn.target_placeholder).join(member.transport_id) : template;
  let attempt = await runShell(cmd, { cwd: member.spawn.launch_cwd });
  let retried = false;
  // §1.4: `agent_not_ready` means an agent IS running and is sitting on its own startup prompt.
  // Re-running `agent start` against that pane is wrong, so this one code suppresses the retry.
  const firstCode = attempt.err && transport === "herdr" ? herdrErrorCode(attempt) : null;
  if (attempt.err && transport === "herdr" && firstCode !== "agent_not_ready") {
    retried = true;
    attempt = await runShell(cmd, { cwd: member.spawn.launch_cwd });
  }
  const errorText = () => (attempt.stderr && String(attempt.stderr).trim()) || (attempt.stdout && String(attempt.stdout).trim()) || (attempt.err && attempt.err.message) || "launch failed";
  if (transport === "herdr") {
    if (attempt.err) {
      const code = herdrErrorCode(attempt);
      // §1.4: blocked-at-startup is a first-class outcome, NOT a failure. The agent is live and
      // queryable by name, nothing is orphaned, and spawn must never answer the prompt itself
      // (§6) — it reports the remedy and leaves the decision with a human.
      if (code === "agent_not_ready") {
        return {
          ...member,
          launch_status: "blocked-at-startup",
          launch_result: {
            code,
            detail: errorText(),
            remedy: `${member.name} is live but awaiting a startup prompt — \`herdr agent read ${member.name} --source recent-unwrapped --lines 40\` shows it, \`herdr agent send-keys ${member.name} <key>\` answers it`,
          },
          retried,
        };
      }
      const result = { code, detail: errorText(), ...closeOrphanPane(member) };
      if (code === "timeout" && member.spawn.args && member.spawn.args.length) {
        result.likely_cause = `args ${JSON.stringify(member.spawn.args)} most likely made ${resolveKind(member)} run and exit instead of staying interactive — these are passed through unvalidated, so this is a diagnostic, not a verdict`;
      }
      return { ...member, launch_status: "failed", launch_result: result, retried, error: errorText() };
    }
    if (!attempt.err) {
      let parsed = null;
      try {
        parsed = JSON.parse(attempt.stdout);
      } catch {
        /* non-JSON success output — reported as ready with a null launch_result */
      }
      const result = { ...member, launch_status: "ready", launch_result: parsed, retried };
      if (member.transport_id && herdrOnPath()) {
        const labelResult = labelPane(member);
        if (labelResult) result.label = labelResult;
      }
      return result;
    }
  }
  // tmux and terminal: no readiness handshake, and no retry (spec 0005 §4 step 6 [correction]).
  if (!attempt.err) return { ...member, launch_status: "dispatched", launch_result: null, retried: false };
  return { ...member, launch_status: "failed", launch_result: null, retried: false, error: errorText() };
}

/**
 * Per-member layout+launch+retry (spec 0009 §6.3 step 5): place `peerMembers.length` panes via the
 * transport, assign each member's `transport_id`, then launch+retry each with `launchMember`.
 * Mutates `peerMembers` in place (`transport_id`); returns launch results aligned to `peerMembers`.
 * Shared by `createSpawn` (spec 0005) and `spawn-one` (spec 0009 §6) — one implementation.
 */
async function layoutAndLaunch(allMembers, transport, mode, splitCwd, callerLabel, layoutOpts = {}) {
  // Spec 0043 §1.4/§4.3: a refused member has nothing shelled for it — and a pane IS something
  // shelled for it, so the refusal must land BEFORE the layout step, not inside launchMember.
  // Partitioned here rather than at each call site because this is the one seam `create --spawn`,
  // `spawn-one`, and history replay all pass through.
  const refused = allMembers.filter((m) => m.spawn && m.spawn.refuse);
  const peerMembers = allMembers.filter((m) => !(m.spawn && m.spawn.refuse));
  for (const m of refused) m.transport_id = null;

  let panes = [];
  if (transport === "herdr" && peerMembers.length > 0) {
    if (!herdrOnPath()) {
      fail("transport is herdr (HERDR_ENV=1) but no `herdr` binary is on PATH — cannot place panes. Install herdr, or unset HERDR_ENV to use tmux/terminal.");
    }
    const self = process.env.HERDR_PANE_ID;
    if (!self) fail(`${callerLabel} needs HERDR_PANE_ID in the environment`);
    ({ panes } = runLayoutLoop({ mode, paneCount: peerMembers.length, self, splitCwd, seedPanes: layoutOpts.seedPanes || [] }));
  } else if (transport === "tmux") {
    for (let i = 0; i < peerMembers.length; i++) {
      try {
        panes.push(execFileSync("tmux", ["new-window", "-P", "-F", "#{pane_id}", "-c", splitCwd], { encoding: "utf8" }).trim());
      } catch (err) {
        // Mirrors runLayoutLoop's herdr-path partial(): preserve the windows already created
        // rather than losing them to the generic top-level catch (spec 0005 review, tmux gap).
        partial({ panes, mode, pane_count: peerMembers.length, complete: false, failed_at: i, error: err.message });
      }
    }
  }

  // [correction] spec 0003 §6.2: N layout commands must yield N distinct, non-empty target ids —
  // asserted before any launch fires, so a bad layout cannot become N claude processes in the wrong places.
  if (transport !== "terminal" && peerMembers.length > 0) {
    if (panes.length !== peerMembers.length || panes.some((p) => !p) || new Set(panes).size !== panes.length) {
      fail(`${callerLabel}: layout produced ${JSON.stringify(panes)} for ${peerMembers.length} peer member(s) — expected that many distinct, non-empty target ids`);
    }
  }
  peerMembers.forEach((m, i) => {
    m.transport_id = transport === "terminal" ? null : panes[i];
  });

  const settled = await Promise.allSettled(peerMembers.map((m) => launchMember(m, transport)));
  const launched = settled.map((r, i) => (r.status === "fulfilled" ? r.value : { ...peerMembers[i], launch_status: "failed", launch_result: null, retried: false, error: String(r.reason) }));
  // Results stay aligned to the caller's original array so an index-keyed caller still lines up.
  return allMembers.map((m) => (m.spawn && m.spawn.refuse ? { ...m, transport_id: null, launch_status: "failed", launch_result: { reason: "refused", detail: m.spawn.refuse }, retried: false, error: m.spawn.refuse } : launched[peerMembers.indexOf(m)]));
}

/** Spec 0016 §4.5: short hash over `team_id` + the sorted non-null `transport_id`s of the close
    set — binds `disband --close --plan-token` to the exact plan that `disband` (bare/plan mode)
    reported, so a stale plan or a topology change between plan and close is caught rather than
    silently closing the wrong panes. */
function closeToken(teamId, closable) {
  const ids = closable.map((m) => m.transport_id).filter((id) => id != null).sort();
  return createHash("sha256").update(JSON.stringify({ team_id: teamId, ids })).digest("hex").slice(0, 16);
}

/** Members with something addressable to close — spec 0016 §4.5's "close set". */
function closableMembers(members) {
  return members.filter((m) => routeHasPane(m.route) && m.transport_id != null);
}

/** Build argv directly and close one member's pane — never `/bin/sh` (spec 0016 §4.5): a
    `transport_id` reaches here from herdr/tmux's own output, but running it through a shell
    string (as the display-only `command` field does) would make it an injection vector. */
function closeMemberPane(transport, transportId) {
  if (transport === "herdr") {
    herdrCall(["pane", "close", transportId]);
    return;
  }
  if (transport === "tmux") {
    execFileSync("tmux", ["kill-pane", "-t", transportId]);
    return;
  }
  throw new Error(`disband --close: transport ${JSON.stringify(transport)} has no addressable pane to close`);
}

/** Strip a member's role (and any -<ordinal> suffix) off its derived name to recover its naming prefix. */
function prefixOfMemberName(name, role) {
  return memberNamePrefix(name, role) ?? name;
}

/** Spec 0010 §7.2/§7.4: `spawn-one` after an alias change can add a member under a different
    prefix than the Team's existing members — no auto-rename, no auto-disband, just a warning. */
function warnMixedPrefixSpawnOne(dir, member) {
  const team = readTeam(dir, teamFile);
  if (!team || !Array.isArray(team.members) || team.members.length === 0) return;
  const newPrefix = prefixOfMemberName(member.name, member.role);
  const mismatched = team.members.find((m) => m.name && m.role && prefixOfMemberName(m.name, m.role) !== newPrefix);
  if (!mismatched) return;
  const oldPrefix = prefixOfMemberName(mismatched.name, mismatched.role);
  process.stderr.write(
    `roster.mjs: ah: this member will be named "${member.name}", but team ${team.team_id}'s existing members are named "${oldPrefix}-*". ` +
      `The team will hold both prefixes. Every name still resolves from team.json, so dispatch is unaffected.\n`
  );
}

/** Spec 0009 §6.3 step 4: the same up/pid, seen|briefed/freshness liveness rule `roster()`
    (lib-hier.mjs) applies per-record, applied here to one named team member. */
function memberIsLive(dir, name) {
  const rec = attributedRoster(dir).find((r) => r.name === name);
  return Boolean(rec) && rec.status !== "down" && recordLiveness(rec).live;
}

/**
 * Spec 0043 §1.6: liveness for one member, kind-aware, three-valued.
 *
 * `kind: claude` is unchanged — `peers.jsonl`, written by the spawned session's own SessionStart
 * hook. A non-claude process runs no Claude hooks and can never satisfy that, so left alone it
 * would read as permanently not-live and `spawn-one`'s already-live refusal would never fire —
 * a second `spawn-one` would then start a second agent under a name Herdr requires to be unique.
 * That is the concrete failure this exists to prevent.
 *
 * Returns `{live, indeterminate, why, agent_status, ready}`; callers must treat `indeterminate`
 * as "refuse", never as "dead".
 */
function memberLiveness(dir, member) {
  if (resolveKind(member) === KIND_DEFAULT) {
    const live = memberIsLive(dir, member.name);
    return { live, indeterminate: false, why: live ? "peers.jsonl up" : "no live peers.jsonl record", agent_status: null, ready: live };
  }
  return herdrAgentState(member.name);
}

/** Spec 0046 §2.4: every identifier a user can actually see for a live peer, in one place —
    reused by dismiss plan, dismiss close, and the unresolved-target error. Forms, first match
    wins: pane_id; session_id exact then unique >=8-char prefix; the name the status surface
    prints (synthesized `role@sid8` for a nameless row, or a briefed row's own name); and last
    the herdr display name, which costs a `herdr agent list` and is SKIPPED, never failed, when
    herdr is absent. Two matches never pick — GitHub #4 was a dead end precisely because tooling
    would not say what it could see, so ambiguity reports every candidate. */
function peerIdentifiers(m) {
  return { name: m.name, pane_id: m.transport_id || null, session_id: m.session_id || null, role: m.role || null };
}

function resolvePeerTarget(fallback, name, teamTransport) {
  const uniq = (matches) => {
    if (matches.length > 1) {
      fail(
        `dismiss: ${JSON.stringify(name)} is ambiguous — ${matches.length} live peers match: ` +
          JSON.stringify(matches.map(peerIdentifiers)) +
          " — re-run with a pane_id or a full session_id; nothing was closed",
      );
    }
    return matches[0] || null;
  };

  let hit = uniq(fallback.filter((m) => m.transport_id && m.transport_id === name));
  if (hit) return hit;

  hit = uniq(fallback.filter((m) => m.session_id && m.session_id === name));
  if (hit) return hit;

  if (name.length >= 8) {
    hit = uniq(fallback.filter((m) => m.session_id && m.session_id.startsWith(name)));
    if (hit) return hit;
  }

  hit = uniq(fallback.filter((m) => m.name === name));
  if (hit) return hit;

  // Herdr display name last: only when this team actually rides herdr, and a failed/absent herdr
  // is not an error here — it just means this form is unavailable (spec 0046 §2.4).
  if (teamTransport === null || teamTransport === "herdr") {
    let topology = null;
    try {
      topology = queryHerdrTopology();
    } catch {
      topology = null;
    }
    if (topology) {
      const panes = topology.filter((p) => p.name === name).map((p) => p.pane_id);
      if (panes.length > 0) {
        hit = uniq(fallback.filter((m) => m.transport_id && panes.includes(m.transport_id)));
        if (hit) return hit;
      }
    }
  }
  return null;
}

/** Spec 0046 §2.2: one session can appear as a nameless `up` row AND a named `briefed` row —
    `rosterKey` partitions them — so the close set is deduplicated on `transport_id`, falling
    back to `session_id`. A row with neither is kept as its own entry (nothing can merge it). */
function dedupPeers(members) {
  const seen = new Set();
  const out = [];
  for (const m of members) {
    const key = m.transport_id || m.session_id || null;
    if (key !== null) {
      if (seen.has(key)) continue;
      seen.add(key);
    }
    out.push(m);
  }
  return out;
}

/** `<prefix>-<role>[-<n>]` → `{prefix, role}` against this invocation's registry (see lib-config's `hierarchyNameParts`). */
function hierarchyNameParts(name) {
  return parseNameParts(name, registry());
}

/** The naming prefix a scope's sessions were dispatched under: a named team's own name, else the
    prefix this command would spawn with (`--team` > alias > repo basename). */
function scopePrefix(scope) {
  return typeof scope === "string" && scope ? scope : teamPrefix(cwd, teamArg);
}

/** `herdr agent list` as a reportable outcome instead of a throw: an absent or unanswering herdr
    contributes no agents and fails nothing, and the caller reports why. */
function herdrArmQuery() {
  if (!herdrOnPath()) return { ok: false, reason: "herdr not on PATH", agents: [] };
  try {
    return { ok: true, reason: null, agents: queryHerdrTopology() };
  } catch (err) {
    return { ok: false, reason: err.message, agents: [] };
  }
}

/** A team riding tmux or terminal has no herdr topology that could describe it, and asking herdr
    about one would be an exec for an answer that cannot apply. With no team file at all there is
    no transport to contradict: herdr is the only registry a loose peer can be in. */
function herdrArmApplies(dir, scope) {
  if (scope === NO_TEAM_SCOPE) return true;
  const team = readTeam(dir, typeof scope === "string" && scope ? scope : null);
  return !team || team.transport === "herdr";
}

/**
 * The live herdr panes whose names say they belong to this scope's hierarchy, in `livePeerSlots`
 * shape. The name is the agent's registered `name` when it has one and its pane title otherwise,
 * and a registered name that does not match is never overridden by a title that would.
 * Being listed by herdr IS the liveness signal — closing a pane needs nothing but its id,
 * so a per-agent status query would buy nothing the close path uses. The pane running this command
 * is never included. A pane reporting a cwd in another checkout is excluded; one reporting no cwd
 * is kept, since a name match under this scope's own prefix is already repo-specific.
 */
function herdrArmMatches(dir, scope) {
  const q = herdrArmApplies(dir, scope) ? herdrArmQuery() : { ok: false, reason: "team transport is not herdr", agents: [] };
  const prefix = scopePrefix(scope);
  const selfPane = process.env.HERDR_PANE_ID || null;
  const myRoot = findGitRoot(realCwd(cwd)) || null;
  const matched = [];
  for (const a of q.agents) {
    const key = a.name || a.title;
    const parts = hierarchyNameParts(key);
    if (!parts || parts.prefix !== prefix) continue;
    if (selfPane && a.pane_id === selfPane) continue;
    // Fail closed when this command has no git root to compare against: an agent that reports a
    // cwd is then unverifiable, not assumed local. One that reports none is unchanged.
    if (a.cwd && (!myRoot || (findGitRoot(realCwd(a.cwd)) || null) !== myRoot)) continue;
    matched.push({ name: key, role: parts.role, pid: null, pane_id: a.pane_id, session_id: a.session_id || null, cwd: a.cwd || null, live: true, how: `herdr agent list (${a.name ? "name" : "title"})`, source: "herdr" });
  }
  return { ...q, prefix, matched };
}

/** Registry wins: an agent a team.json row or a peers.jsonl row already names — by pane id, by
    name, or by session id — is that row, and the richer row is the one the close set carries.
    Only rows that are not known-dead count: a stale `up` record whose pid is gone describes a
    session that ended, and letting it suppress a live pane would hide the pane from the close set
    entirely. A team.json row carries no liveness of its own and always counts. */
function herdrArmSlots(dir, scope, known) {
  const ids = new Set();
  const names = new Set();
  const sessions = new Set();
  for (const k of known.filter((k) => k.live !== false)) {
    if (k.pane_id) ids.add(k.pane_id);
    if (k.transport_id) ids.add(k.transport_id);
    if (k.name) names.add(k.name);
    if (k.session_id) sessions.add(k.session_id);
  }
  return herdrArmMatches(dir, scope).matched.filter((s) => !ids.has(s.pane_id) && !names.has(s.name) && !(s.session_id && sessions.has(s.session_id)));
}

/** The live registry for a scope: peers.jsonl rows plus the herdr-topology arm. Every reader of
    the fallback/extras/untracked lists goes through here, so the arm reaches all of them at once
    and none of them carries per-site herdr logic. */
function liveRegistrySlots(dir, scope, known = []) {
  const peers = livePeerSlots(dir, scope);
  return [...peers, ...herdrArmSlots(dir, scope, [...peers, ...known])];
}

/** Which sources a disband/dismiss/teams answer consulted and what each yielded — so an empty
    answer can name the prefix it searched under, the one thing a user can check at a glance. */
function sourcesField(dir, scope, team) {
  const arm = herdrArmMatches(dir, scope);
  return {
    team: { file: team ? teamPath(dir, teamFile) : null, members: team && Array.isArray(team.members) ? team.members.length : 0 },
    peers: { live: livePeerSlots(dir, scope).filter((s) => s.live).length },
    herdr: arm.ok
      ? { ok: true, agents: arm.agents.length, matched: arm.matched.length, prefix: arm.prefix }
      : { ok: false, reason: arm.reason, prefix: arm.prefix },
  };
}

/** Spec 0040 §1.2: the live peer records for the current team, shaped like team.json members so
    closableMembers/closeToken/closeMemberPane apply verbatim. Records store the herdr pane id
    from checkin (HERDR_PANE_ID); a record without one has no transport_id and is listed but
    never closable. `source: "peers"` marks the row as coming from the registry, not team.json. */
function peerFallbackMembers(dir, scope, known = []) {
  // Spec 0046 §2.2 (replaces the 0044 `teamArg` rule, which WAS GitHub #4): the scope is the
  // identity of the team being operated on — `teamFile` (null for the default team), or
  // NO_TEAM_SCOPE in the no-team.json branch — never the `--team` FLAG. Passing `teamArg || null`
  // meant a bare command scoped to null and so excluded every peer carrying a real team tag,
  // leaving the close set empty while the sessions were plainly live. The old comment's fear (a
  // derived scope filters untagged peers out) holds only when the derived team is NAMED, and
  // there excluding default-team peers is the correct isolation.
  return liveRegistrySlots(dir, scope, known)
    .filter((s) => s.live)
    .map((s) => ({ role: s.role, name: s.name, route: "peer", transport_id: s.pane_id, session_id: s.session_id || null, live: s.live, how: s.how, source: s.source || "peers" }));
}

/** Live registry peers that are not already one of `members`. A pane hosts exactly one session, so
    a peer on a member's pane IS that member whatever name the registry shows it under (a nameless
    checkin row appears as `role@sid8`); name equality is the fallback, and the only key a paneless
    row has. Nulls never match. `members` must be the resynced rows: the stored pane ids are the
    ones that may have moved. The team row is the one kept — it carries no `source`, and the
    post-close reconcile finds results by member name. */
function peerExtras(dir, members, scope) {
  const panes = new Set();
  const names = new Set();
  for (const m of members) {
    if (!m || typeof m !== "object") continue;
    if (m.transport_id) panes.add(m.transport_id);
    if (m.name) names.add(m.name);
  }
  const isMember = (p) => {
    const pane = p.transport_id || p.pane_id || null;
    return (pane !== null && panes.has(pane)) || (!!p.name && names.has(p.name));
  };
  return dedupPeers(peerFallbackMembers(dir, scope, members).filter((p) => !isMember(p)));
}

/** Spec 0046 §2.5: live peers attributed to `scope` that no team.json row names — the orphans
    `teams`/`reap` must surface so a user can see what `team_dismiss`/`team_disband` would close. */
/** Every member name any team file in this dir records — what "untracked" is measured against. */
function trackedNames(dir, rows) {
  const names = new Set();
  for (const row of rows) {
    const t = readTeam(dir, row.name);
    for (const m of (t && Array.isArray(t.members) ? t.members : [])) if (m.name) names.add(m.name);
  }
  return names;
}

function untrackedLive(dir, scope, tracked) {
  return liveRegistrySlots(dir, scope)
    .filter((s) => s.live && !tracked.has(s.name))
    .map((s) => ({ name: s.name, role: s.role, pane_id: s.pane_id, session_id: s.session_id, pid: s.pid, cwd: s.cwd, ...(s.source === "herdr" ? { source: "herdr" } : {}) }));
}

/** The latest obligation row any hook filed for a session, or null. Observed, not verified: a
    plain cross-session message files none. */
function lastBriefRow(sessionId) {
  return sessionId ? readPeerRecords().filter((r) => r.session_id === sessionId && r.type !== "turn" && r.type !== "dispatch").at(-1) || null : null;
}

/** Who last briefed a session, best-effort: that row's `from_name`, else `from`, else null. */
function lastBriefFrom(sessionId) {
  const row = lastBriefRow(sessionId);
  return row ? row.from_name || row.from || null : null;
}

/**
 * What still depends on an orphaned team: `live_members`, its records that `memberLiveness` finds
 * live or cannot rule out (an indeterminate one is listed as such, never dropped, since dropping it
 * would read as not live); and `attributed_live`, the live sessions that claim the team through
 * their launch environment or a `<t>-` Herdr name but match no record — its `untracked_live` rows,
 * never for the legacy team.json. Each field is present
 * only when non-empty. `untracked` is that team's `untracked_live` when the caller has it.
 */
function orphanDependents(dir, teamName, untracked = null) {
  const t = readTeam(dir, teamName);
  const members = t && Array.isArray(t.members) ? t.members.filter((m) => m && typeof m.name === "string") : [];
  const records = attributedRoster(dir);
  const live_members = members.flatMap((m) => {
    const l = memberLiveness(dir, m);
    if (!l.live && !l.indeterminate) return [];
    const rec = records.find((r) => r.name === m.name);
    return [{ name: m.name, role: m.role ?? null, last_brief_from: lastBriefFrom(rec && rec.session_id), ...(l.indeterminate ? { indeterminate: true } : {}) }];
  });
  // The legacy team.json claims nothing: an untagged row cannot be told apart from a session never
  // launched with AH_TEAM_FILE, and its name prefix is the repo basename plain role sessions share.
  // A named team's tag and its `<t>-` names are claims on it, and a non-Claude member writes no
  // peers row, so its name is its only link.
  const rows = teamName === null ? [] : untracked || untrackedLive(dir, teamName, new Set(members.map((m) => m.name)));
  const attributed_live = rows.map((r) => ({ name: r.name, role: r.role, pane_id: r.pane_id, last_brief_from: lastBriefFrom(r.session_id) }));
  return { ...(live_members.length ? { live_members } : {}), ...(attributed_live.length ? { attributed_live } : {}) };
}

/** The adopt command that makes the invoking session the owner of `teamName`, or null when no
    invoking pid resolves. */
function adoptCommand(teamName) {
  const pid = ownOrchestratorPid();
  if (!Number.isInteger(pid) || pid <= 0) return null;
  const words = ["node", fileURLToPath(import.meta.url), "adopt", "--orchestrator-pid", String(pid)];
  if (teamName != null) words.push("--team", teamName);
  words.push("--cwd", cwd);
  return words.map(shellWord).join(" ");
}

function peerFallbackPlanEntry(m) {
  return { role: m.role, name: m.name, route: m.route, transport: "herdr", transport_id: m.transport_id, command: m.transport_id ? `herdr pane close ${m.transport_id}` : null, live: m.live, how: m.how, source: m.source || "peers" };
}

/** Close one member of a (possibly mixed, spec 0040 §1.4a) close set: team rows use the team's
    transport; registry rows are herdr by construction and carry `source` through to the result. */
function closeOne(m, teamTransport) {
  const row = { name: m.name, transport_id: m.transport_id };
  try {
    closeMemberPane(m.source ? "herdr" : teamTransport, m.transport_id);
    Object.assign(row, { closed: true, error: null });
  } catch (err) {
    Object.assign(row, { closed: false, error: err.message });
  }
  if (m.source) row.source = m.source;
  return row;
}

/** Shared token/confirm gate for every --close variant. */
function gateClose(verb, scope, closable) {
  const closeList = closable.map((m) => ({ name: m.name, transport_id: m.transport_id, ...(m.source ? { source: m.source } : {}) }));
  if (opts.confirm !== true) {
    fail(`${verb} --close: --confirm is required to close ${verb === "dismiss" ? "a live session" : "live sessions"}. Close list: ${JSON.stringify(closeList)}`);
  }
  if (typeof opts["plan-token"] !== "string" || !opts["plan-token"]) {
    fail(`${verb} --close needs --plan-token <tok>, from a preceding \`${verb}${verb === "dismiss" ? " <name>" : ""}\` (plan) call`);
  }
  if (opts["plan-token"] !== closeToken(scope, closable)) {
    fail(`${verb} --close: --plan-token does not match the current close plan (the topology may have changed) — re-run \`${verb}\` and retry with the fresh token`);
  }
}

const shellWord = (s) => (/^[A-Za-z0-9_\/.:@%+=-]+$/.test(s) ? s : `'${s.replace(/'/g, "'\\''")}'`);

/** The exact `--close` command a plan's caller runs after the user says yes, so the agent copies
    one string instead of assembling flags. */
function closeCommand(verb, name, token) {
  const words = ["node", fileURLToPath(import.meta.url), verb];
  if (name != null) words.push(name);
  words.push("--close", "--confirm", "--plan-token", token);
  if (typeof opts.team === "string") words.push("--team", opts.team);
  if (typeof opts.cwd === "string") words.push("--cwd", opts.cwd);
  return words.map(shellWord).join(" ");
}

/** The team file's path when it exists but `readTeam` could not parse it, else null. A missing
    file and a corrupt one both read as "no team"; only the corrupt one must never be treated as
    absent by a path that could go on to delete or rewrite it. */
function unreadableTeamFile(dir) {
  const path = teamPath(dir, teamFile);
  return existsSync(path) ? path : null;
}

/** After a whole-team close: decide, row by row over a FRESH read of the team file, what stays.
    A closed session's row goes; a row whose session may still exist stays, with the reason.
    `snapshot` is the record the close plan was validated against — a named row absent from it
    was added while the closes ran and is never touched. */
function reconcileAfterClose(dir, snapshot, results) {
  const path = teamPath(dir, teamFile);
  const fresh = readTeam(dir, teamFile);
  if (!fresh || !Array.isArray(fresh.members)) return { pruned: [], kept: [], team_removed: false, team_file: existsSync(path) ? path : null };
  const snapshotNames = new Set(snapshot.members.map((m) => m.name).filter((n) => n != null));
  const resultFor = (m) => results.find((r) => (m.name != null ? r.name === m.name : r.name == null && r.transport_id != null && r.transport_id === m.transport_id));
  const pruned = [];
  const kept = [];
  const keptRows = [];
  for (const m of fresh.members) {
    const label = m.name != null ? m.name : m.role;
    const r = resultFor(m);
    let why = null;
    if (m.name != null && !snapshotNames.has(m.name)) why = "added";
    else if (r && !r.closed) why = "close-failed";
    else if (!r && m.name != null) {
      const st = memberLiveness(dir, m);
      if (st.live) why = "live";
      else if (st.indeterminate) why = "indeterminate";
    }
    if (why) {
      kept.push({ name: label, why });
      keptRows.push(m);
    } else pruned.push(label);
  }
  return { pruned, kept, team_removed: writeTeamRows(dir, fresh, keptRows), team_file: path };
}

/** Writes `team` with only `rows`, or clears its file when no row is left: a team's last departure
    ends it. True when the file was cleared. */
function writeTeamRows(dir, team, rows) {
  if (rows.length === 0) clearTeam(dir, teamFile);
  else writeTeam(dir, { ...team, members: rows }, teamFile);
  return rows.length === 0;
}

/** `create --spawn` (spec 0005): resolve + layout + launch + retry in one script invocation. */
async function createSpawn(dir, withWarnings) {
  if (typeof opts.from === "string") resolveHistoryEntry(dir);
  const plan = getMembersPlan(dir);
  const { level, transport, layout, members } = plan;
  const peerMembers = members.filter((m) => routeHasPane(m.route));
  const needing = planNeedingModel(plan);
  if (needing.length) refuseMemberModels(needing);

  const launched = await layoutAndLaunch(peerMembers, transport, layout.mode, cwd, "create --spawn");
  storeTeamLayout(layout);
  const launchByName = new Map(peerMembers.map((m, i) => [m.name, launched[i]]));

  // Spec 0043 §1.1: `kind` is written only when it is not the default, so claude rows stay
  // byte-identical to pre-0043. `create --spawn` does not write team.json itself — the
  // Orchestrator builds it from these rows (SKILL.md), so a row that omits `kind` becomes a
  // team.json entry that resolves to claude and asks `peers.jsonl` about a process that never
  // writes it: the member reads dead forever, and `dismiss` drops a live agent's record without
  // the warning that is supposed to stop exactly that. (`spawn-one` is unaffected — it sources
  // its member from the roster config and takes only the name from the team record.)
  const kindFields = (m) => {
    const f = {};
    if (resolveKind(m) !== KIND_DEFAULT) f.kind = resolveKind(m);
    if (memberArgs(m)) f.args = [...memberArgs(m)];
    return f;
  };
  const outputMembers = members.map((m) => {
    if (!routeHasPane(m.route)) return { role: m.role, name: m.name, ...kindFields(m), model: m.model, route: m.route, autoMode: m.autoMode, transport_id: null, launch_status: null, launch_cwd: null };
    const lm = launchByName.get(m.name);
    // Spec 0035 §2.4: placement is consequential and must not be silent — report where each
    // peer actually launched, not just that it launched.
    const entry = { role: m.role, name: m.name, ...kindFields(m), model: m.model, route: m.route, autoMode: m.autoMode, transport_id: m.transport_id, launch_status: lm.launch_status, launch_result: lm.launch_result, retried: lm.retried, launch_cwd: m.spawn ? m.spawn.launch_cwd : null };
    if (lm.error) entry.error = lm.error;
    if (lm.label) entry.label = lm.label;
    if (m.spawn && m.spawn.validation) entry.validation = m.spawn.validation;
    // Spec 0008 §6: populate tab_id/workspace_id from the launch result when it carries them.
    // No new herdr query on this path — if absent, the first `resync` fills them in.
    const launchedPane = transport === "herdr" && lm.launch_result && lm.launch_result.result && lm.launch_result.result.pane;
    if (launchedPane && launchedPane.tab_id != null) entry.tab_id = launchedPane.tab_id;
    if (launchedPane && launchedPane.workspace_id != null) entry.workspace_id = launchedPane.workspace_id;
    return entry;
  });
  const isPartial = outputMembers.some((m) => routeHasPane(m.route) && m.launch_status === "failed");
  const renamed = plan.renamed_members ? { renamed_members: plan.renamed_members } : {};
  out(withWarnings(withSkipped({ level, transport, members: outputMembers, partial: isPartial, ...renamed }, plan.skipped_members || [])));
}

/** One team's inventory row (spec 0011 §5.4 / 0033 §3.1): `null` for the default team, or
    `name` == readdirSync's entry basename == the value listTeamNames(dir) returns. Never
    writes. Shared by `teams` and `reap` (spec 0033 §3.2) so the two commands cannot drift
    apart about what a team is. */
function describeTeamRow(dir, name, myPid) {
  const t = readTeam(dir, name);
  if (!t) return null;
  const pid = t.orchestrator && t.orchestrator.pid;
  return {
    name,
    team_id: t.team_id,
    members: Array.isArray(t.members) ? t.members.length : 0,
    orchestrator_pid: pid ?? null,
    pid_alive: pidAlive(pid),
    orphaned: teamIsOrphaned(t), // pid null/unresolvable/dead — spec 0033 §3.1
    own: Number.isInteger(myPid) && pid === myPid,
    created: t.created,
  };
}

/** Every team in this hierarchy dir — default team first, then every named team (spec 0033 §3.2). */
function allTeamRows(dir, myPid) {
  return [describeTeamRow(dir, null, myPid), ...listTeamNames(dir).map((name) => describeTeamRow(dir, name, myPid))].filter(Boolean);
}

/** Spec 0009 §6 / 0039 §1.2: stand up ONE missing or dead peer — the single spawn path shared by
    `spawn-one` and `add`. Extracted, not forked, from `createSpawn`'s launch path. Resolves the
    roster, picks the member (`--member`, else the sole/first-dead candidate), refuses when the
    peer is already live, places the pane, launches, and persists team.json. Returns the JSON the
    caller prints; every refusal goes through `fail()`. `callerLabel` prefixes the error text and
    the layout call. */
async function spawnOneCore(role, callerLabel, adHocMember = null) {
  resolveWritableTeamScope(hierarchyDir(cwd));
  if (!readTeam(hierarchyDir(cwd), teamFile)) checkNewTeamName(hierarchyDir(cwd));
  if (!chainRoles(registry()).includes(role)) fail(`${callerLabel}: role must be one of ${chainRoles(registry()).join(", ")}, got ${JSON.stringify(role)}`);
  const found = resolveRoster(cwd, teamRosterKey(hierarchyDir(cwd), teamFile), repoBasename, registry());
  const resolved = adHocMember ? adHocRoster(found) : found;
  // An ad hoc member need not exist in the roster, and need not have a
  // roster to exist in. A repo-level roster is still read when there IS one — for the layout
  // mode — but its absence is only fatal on the roster-sourced paths.
  if (!resolved && !adHocMember) fail(`no roster configured for ${cwd}; run \`spawn-ad-hoc ${role}\` instead (it needs no roster), or run the /agent-roster skill's Init flow to define one`);
  const candidates = adHocMember ? [adHocMember] : resolved.members.filter((m) => m.role === role);
  if (candidates.length === 0) {
    const roles = [...new Set(resolved.members.map((m) => m.role))];
    fail(`${callerLabel}: no ${role} member in the roster — roles it defines: ${roles.join(", ") || "(none)"}`);
  }
  const dir = hierarchyDir(cwd);
  const team = readTeam(dir, teamFile);
  // The role's members are named as create names them, but against the team being joined: each
  // takes the record it stands for, then any whose name another session holds is renamed. The
  // choice below is made on those final names.
  const records = team ? team.members : [];
  const claimed = adHocMember ? candidates : claimRecords(candidates, records.filter((r) => r && r.role === role));
  const named = adHocMember
    ? candidates
    : renameInUse(claimed, repoBasename, records, (name) => {
        const st = memberLiveness(dir, records.find((r) => r && r.name === name));
        return st.live || st.indeterminate;
      });
  // §3.2: --member is value-taking; parseArgs sets it to `true` (not a string) when given
  // with no value or immediately followed by another flag — that must fail loudly, never
  // silently fall through to implicit selection.
  if (opts["member"] === true) fail(`${callerLabel}: --member requires a value (the derived member name)`);
  let member;
  if (adHocMember) {
    member = adHocMember;
  } else if (typeof opts["member"] === "string") {
    member = named.find((m) => m.name === opts["member"]);
    if (!member) fail(`${callerLabel}: no member named ${opts["member"]} for role ${role} in the roster — it defines: ${named.map((m) => m.name).join(", ") || "(none)"}`);
  } else if (named.length === 1) {
    member = named[0];
  } else {
    member = named.find((m) => !memberLiveness(dir, m).live) || named[named.length - 1];
  }
  // The members this call renamed away from --names-in-use, which its output reports; a member
  // that only took its record's existing name was not renamed.
  const renamedNow = (adHocMember ? member.renamed_from : !claimed.includes(member)) ? [member] : [];
  // A model given at invocation launches this member on it, this time only; the roster is untouched.
  if (!adHocMember && opts.model !== undefined) {
    if (typeof opts.model !== "string") fail(`${callerLabel}: --model requires a value`);
    if (resolveKind(member) !== KIND_DEFAULT) fail(`${callerLabel}: --model: ${member.name} is kind ${JSON.stringify(resolveKind(member))}, and a model applies only to kind claude`);
    const modelErrors = validateMember({ role: member.role, model: opts.model }, registry());
    if (modelErrors.length) fail(`${callerLabel}: --model: ${modelErrors.join("; ")}`);
    member = withModel(member, opts.model);
  }

  // Spec 0018 §3/§4.3: creating a new team here needs a resolvable, live owner pid — refuse
  // before anything spawns, so a half-launched team (panes up, no persisted owner) never
  // happens. Only relevant when no team file exists yet; an existing team already has one.
  let newTeamOrchestratorPid = null;
  if (!team) {
    newTeamOrchestratorPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
    if (!Number.isInteger(newTeamOrchestratorPid)) {
      fail(`${callerLabel}: no orchestrator pid resolvable (CLAUDE_PID unset and no --orchestrator-pid given) — refusing to create a team with an unowned pid`);
    }
    if (!pidAlive(newTeamOrchestratorPid)) {
      fail(`${callerLabel}: --orchestrator-pid ${newTeamOrchestratorPid} is not a live process — refusing to create a team owned by a dead pid`);
    }
  }
  // Spec 0044 §1.4 point 5: an ad hoc member is ALWAYS matched by name. Matching by role would
  // make `matches` find a different, same-role member already in the team and overwrite its
  // record — which is the one outcome that point forbids, and which the name-collision refusal
  // above does not catch because the two names differ.
  const byName = Boolean(adHocMember) || candidates.length > 1;
  // A member renamed in place is matched under the name its record still has.
  const recordName = member.record ? member.record.name : member.name;
  const matches = (m) => (byName ? m.name === recordName : m.role === role);
  const existing = team && Array.isArray(team.members) ? team.members.find(matches) : null;
  // §3.3(i)/§3.3.1, amendment (b): the already-live decision is a disjunction over TWO names,
  // both asked of the registry (`memberIsLive`) — never the team-record lookup by itself.
  // - memberIsLive(dir, member.name): the name we're about to launch is already running
  //   (population 1 — a live member whose team.json slot got overwritten by a sibling spawn).
  // - liveRecord: this slot's EXISTING record is live under a different (stale-drifted) name
  //   (population 2 — alias drift, spec 0010 §7.2). A dead existing record must NOT block a
  //   legitimate spawn, which is why liveness is asked about its name too, not just its presence.
  // Collapsing to either disjunct alone reopens the other population — see §3.3.1.
  // Spec 0043 §1.6: liveness is kind-aware and THREE-valued. An indeterminate answer (Herdr
  // unreachable) must refuse rather than proceed — proceeding means launching a replacement for
  // an agent that may well be alive, under a name Herdr requires to be unique.
  const selfState = memberLiveness(dir, member);
  if (selfState.indeterminate) {
    fail(`${callerLabel}: cannot determine whether ${member.name} (kind ${resolveKind(member)}) is already live — ${selfState.why}. Refusing to spawn: a duplicate agent under a name Herdr requires to be unique is worse than not spawning. Fix Herdr and retry.`);
  }
  const existingState = existing ? memberLiveness(dir, { ...member, name: existing.name }) : null;
  if (existingState && existingState.indeterminate) {
    fail(`${callerLabel}: cannot determine whether the existing record ${existing.name} (kind ${resolveKind(member)}) is still live — ${existingState.why}. Refusing to spawn; fix Herdr and retry.`);
  }
  const liveRecord = existingState && existingState.live ? existing : null;
  // An ad hoc name is derived, never chosen, so a live session already holding it belongs to
  // someone else. Reporting it as "already live" would hand the caller that session as if it
  // were the member just asked for.
  if (adHocMember && (selfState.live || liveRecord)) {
    fail(`${callerLabel}: the derived name ${member.name} is already held by a live session outside this team's record — nothing was launched or written. Free the name with \`dismiss ${member.name}\` or \`untrack ${member.name}\`, or spawn under a different prefix with --team <other>`);
  }
  if (selfState.live || liveRecord) {
    const out_member = liveRecord || existing || { role: member.role, name: member.name };
    const state = selfState.live ? selfState : existingState;
    // §1.6: live and ready are different questions for a Herdr-driven agent — a member blocked
    // on its own startup prompt is live (do not spawn a second) but not promptable.
    const liveInfo = { agent_status: state.agent_status, ready: state.ready };
    if (byName && typeof opts["member"] !== "string") {
      // Reporting only (the load-bearing refusal already fired above). An indeterminate candidate
      // is listed with a marker rather than dropped — vanishing from the list would read as
      // "confirmed not live", which is exactly what indeterminate does not mean.
      const candidatesLive = named
        .map((c) => ({ name: c.name, st: memberLiveness(dir, c) }))
        .filter(({ st }) => st.live || st.indeterminate)
        .map(({ name, st }) => (st.indeterminate ? `${name} (liveness unknown)` : name));
      return { spawned: false, reason: "already live", member: out_member, role, candidates_live: candidatesLive, ...liveInfo };
    }
    return { spawned: false, reason: "already live", member: out_member, ...liveInfo };
  }
  const needing = membersNeedingModel([member], resolved ? resolved.members : []);
  if (needing.length) refuseMemberModels(needing);
  warnMixedPrefixSpawnOne(dir, member);

  const transport = detectTransport();
  // Spec 0043 §1.5: the member's own route, not a hardcoded "peer" — a `pane` member must be
  // recorded as `pane` or disband/dismiss/move would never find it, and `spawnShape` needs the
  // effective route to apply §1.3's non-claude rule.
  const blockRoute = resolved ? resolved.route : null;
  const memberRoute = routeHasPane(member.route || blockRoute) ? member.route || blockRoute : "peer";
  const planEntry = { role: member.role, name: member.name, kind: resolveKind(member), model: member.model, effort: member.effort, route: memberRoute, autoMode: member.autoMode, args: memberArgs(member), spawn: shapeFor({ ...member, route: memberRoute }, transport) };
  // The layout is the team's: recorded when the team was created, chosen now when this spawn creates it.
  const layout = team
    ? { mode: ROSTER_LAYOUT_VALUES.includes(team.layout) ? team.layout : "auto" }
    : createLayout();
  const mode = layout.mode;

  if (planEntry.spawn.validation && planEntry.spawn.validation.refused) fail(`${callerLabel}: ${planEntry.spawn.refuse}`);
  const validation = planEntry.spawn.validation ? { validation: planEntry.spawn.validation } : {};
  if (opts["dry-run"] === true) {
    return { dry_run: true, role: member.role, name: member.name, mode, launch: planEntry.spawn.launch, ...validation, ...renamedField(renamedNow) };
  }

  const seedPanes = team && Array.isArray(team.members)
    ? team.members
        .filter((m) => routeHasPane(m.route) && m.transport_id != null && m.name !== member.name)
        .map((m) => m.transport_id)
    : [];

  const [launched] = await layoutAndLaunch([planEntry], transport, mode, cwd, callerLabel, { seedPanes });
  if (launched.launch_status === "failed") {
    // Spec 0043 §1.4/§1.9: the orphaned-pane id, its close command and the args-blame diagnostic
    // live in `launch_result`. `fail()` prints one line, so they have to be folded into it —
    // dropping them leaves the user with a bare timeout and no way to find either the evidence
    // or the pane it is sitting in.
    const lr = launched.launch_result;
    const extra = lr ? [lr.likely_cause, lr.remedy, lr.closed_pane ? `its pane ${lr.closed_pane} was closed` : null, lr.pane_output ? `the pane's last output:\n${lr.pane_output}` : null].filter(Boolean) : [];
    // The transport's own error rarely says which name was attempted, and a name taken where the
    // liveness check cannot see it surfaces only here.
    fail([`${callerLabel}: launching ${member.name} failed`, launched.error, ...extra].filter(Boolean).join(" — "));
  }

  const newRecord = { role: member.role, name: member.name, ...(member.renamed_from ? { renamed_from: member.renamed_from } : {}), route: memberRoute, model: member.model, effort: member.effort, autoMode: member.autoMode, transport_id: launched.transport_id };
  // §1.1: written only when it is not the default, so claude-kind team.json rows are unchanged.
  if (resolveKind(member) !== KIND_DEFAULT) newRecord.kind = resolveKind(member);
  if (memberArgs(member)) newRecord.args = [...memberArgs(member)];
  const launchedPane = transport === "herdr" && launched.launch_result && launched.launch_result.result && launched.launch_result.result.pane;
  if (launchedPane && launchedPane.tab_id != null) newRecord.tab_id = launchedPane.tab_id;
  if (launchedPane && launchedPane.workspace_id != null) newRecord.workspace_id = launchedPane.workspace_id;

  // The launch above takes long enough for another spawn to have written this file, so the write
  // builds on the record as it stands now. The launched session is left running on a refusal:
  // reporting its pane keeps it recoverable, closing it would destroy work on a late-seen race.
  const fresh = teamFileState(dir, teamFile);
  const orphaned = `the session just launched is still running with transport_id ${launched.transport_id} and is in no team record`;
  if (fresh.state === "unusable" || (team && fresh.state === "absent")) {
    fail(`${callerLabel}: ${fresh.state === "absent" ? `the team file ${fresh.path} is gone` : `the team file ${fresh.path} is no longer readable`} — it changed while ${member.name} was launching, so nothing was written; ${orphaned}`);
  }
  const rival = fresh.team && Array.isArray(fresh.team.members) ? fresh.team.members.find(matches) : null;
  if (rival && (!existing || rival.transport_id !== existing.transport_id)) {
    fail(`${callerLabel}: another spawn recorded ${rival.name != null ? rival.name : rival.role} (pane ${rival.transport_id}) in ${fresh.path} while ${member.name} was launching — its row was not overwritten; ${orphaned}`);
  }
  let outTeam = fresh.team;
  if (!outTeam) {
    outTeam = {
      version: 1,
      team_id: newId(),
      created: localIso(),
      roster_level: resolved ? resolved.level : null,
      transport,
      orchestrator: { session_id: null, pid: newTeamOrchestratorPid },
      members: [],
      expected_root: realCwd(cwd),
      roster: resolved ? resolved.teamKey : null,
      layout: mode,
    };
  }
  const idx = outTeam.members.findIndex(matches);
  if (idx === -1) outTeam.members.push(newRecord);
  else outTeam.members[idx] = newRecord;
  writeTeam(dir, outTeam, teamFile);
  const outMember = launched.label ? { ...newRecord, label: launched.label } : newRecord;
  // Spec 0035 §2.4: report where this peer actually launched, not just that it launched.
  const spawnOut = { spawned: true, member: outMember, team_id: outTeam.team_id, roster_level: outTeam.roster_level, launch_cwd: planEntry.spawn.launch_cwd, ...validation, ...renamedField(renamedNow) };
  // Spec 0043 §1.4: blocked-at-startup is success WITH AN ACTION OUTSTANDING, not a failure —
  // the agent is live and queryable, so the team row stands and the caller is told what to do.
  if (launched.launch_status === "blocked-at-startup") {
    spawnOut.launch_status = launched.launch_status;
    spawnOut.launch_result = launched.launch_result;
    spawnOut.ready = false;
  }
  return spawnOut;
}

/**
 * Spec 0044 §1.3: mechanical enforcement of §1.2's boundary. Prose in CONTEXT.md is what already
 * existed and is what failed, so this refuses instead — the roster is a template for FUTURE teams,
 * and a session that currently owns a live one has no business editing it mid-flight.
 *
 * The message leads with §1.4's command and mentions the override second, deliberately. An agent
 * that reads a prohibition looks for a way around it; an agent that reads an instruction follows
 * it. The override is the USER's — no code path may supply it, and an agent adding it to get past
 * this refusal is precisely the failure this exists to prevent.
 *
 * Every team file in this hierarchy dir is checked, not just the one at the resolving scope: an
 * orchestrator holding `--team foo` is just as much an owner while it runs a bare `add`, and
 * scoping the check to the resolving file would let it edit the roster simply by omitting `--team`
 * (r3 [9.2]). Ownership is decided by pid EQUALITY, never by `resolveSessionTeam`'s role scan — a
 * pid either matches or it does not, so the gate never has to guess.
 */
function refuseRosterEditWhileOwningTeam(command) {
  if (!ROSTER_MUTATING_CMDS.has(command)) return;
  if (opts["allow-roster-edit"] === true) return;
  const dir = hierarchyDir(cwd);
  const myPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
  // §1.3: an unresolvable pid must NOT refuse. That hole is the plain user shell §1.2 preserves —
  // every agent-invoked path this defends against does have a pid.
  if (!Number.isInteger(myPid)) return;
  for (const name of [null, ...listTeamNames(dir)]) {
    const existing = readTeam(dir, name);
    if (!teamOwnedBy(existing, invokerIdentity())) continue;
    fail(
      `${command} edits the roster TEMPLATE, and this session owns live team ${existing.team_id} (${name ? `team "${name}"` : "the default team"}). ` +
        `To add or change a member of the RUNNING team — including one that diverges from the roster, or a role the roster does not define — run \`roster.mjs spawn-ad-hoc <role> [--model M] [--kind K] [--args '[...]']\`, which writes only the team file. ` +
        `If you genuinely mean to edit the template for future teams while this one runs, the user can re-run with --allow-roster-edit.`
    );
  }
}

try {
  refuseRosterEditWhileOwningTeam(cmd);
  switch (cmd) {
    case "show": {
      const explicit = levelArg();
      if (explicit) {
        const level = requireLevel(explicit);
        const path = rosterLevelPaths(cwd)[level];
        const data = readLevelFile(path);
        const container = rosterContainer(data, rosterArg);
        const resolved = resolveRoster(cwd, rosterArg, repoBasename, registry());
        const shown = container && Array.isArray(container.members) ? { route: container.route, members: namedMembers(container.members) } : null;
        out({
          level,
          path,
          container: containerLabel(rosterArg),
          roster: shown,
          shadowed: resolved && resolved.level !== level ? `shadowed by ${resolved.level}` : null,
          ...showNameNote(shown),
        });
      } else {
        const resolved = resolveRoster(cwd, rosterArg, repoBasename, registry());
        out(
          resolved
            ? { ...resolved, ...showNameNote(resolved) }
            : {
                roster: null,
                hint: "no roster configured — spawn ad hoc with: roster.mjs spawn-ad-hoc <role> [--kind K] [--route pane|peer] --cwd <abs cwd>",
              }
        );
      }
      break;
    }

    case "init": {
      const level = requireLevel(levelArg() || fail("init needs --level global|repo|repo-user (or the level as the first word)"));
      const route = opts.route;
      if (!ROSTER_ROUTE_VALUES.includes(route)) fail(`--route must be "peer" or "subagent", got ${JSON.stringify(route)}`);
      if (route === "subagent") fail("init: --route subagent is not allowed — only legwork roles run as subagents. Init with --route peer, then route individual legwork members with `add --role <legwork role> --route subagent`.");
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      // Spec 0032 §3.4 point 3: `init --team X` creates `rosters.X`, never `roster`; `init`
      // with no `--team` keeps writing `roster`, unchanged. A fresh object, not a mutation of
      // whatever was there — `init` REPLACES the block wholesale (pre-existing behavior for the
      // default `roster`), so a stale `layout` (or any other key) from a prior init must not
      // survive a re-init.
      if (opts.layout !== undefined) fail("init: --layout was removed — a team's layout is chosen when it is created: `roster.mjs create --mode <auto|columns|grid>` (an explicit --mode also becomes the default for future teams)");
      const fresh = freshRosterBlock(route);
      installRosterBlock(data, rosterArg, fresh);
      writeLevelFile(path, data);
      out({ level, path, container: containerLabel(rosterArg), roster: fresh });
      break;
    }

    case "add": {
      const { level, wasDefaulted, teamKey } = targetLevel({ allowMissing: true });
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      let container = rosterContainer(data, teamKey);
      // 0032 §3.4b: a team-scoped container is created only by `init --team` — no
      // auto-vivification, since a typo'd --team writes a block that can never be selected
      // (resolveRoster only matches an active team name), which is silent-wrong forever.
      // Spec 0038 §1.1/§1.2: the DEFAULT container is the one exception — bare `add <role>`
      // with no roster bootstraps a minimal one here, through init's own writer.
      if (!container && teamKey) {
        fail(`no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init --roster ${teamKey}\` first`);
      }
      const created = !container;
      if (created) {
        container = freshRosterBlock(typeof opts.route === "string" && opts.route !== "subagent" ? opts.route : AUTO_INIT_ROUTE);
        installRosterBlock(data, teamKey, container);
      }
      if (!Array.isArray(container.members)) container.members = [];
      const role = opts.role;
      if (role === "orchestrator") fail('role "orchestrator" is not a roster member — the Orchestrator is whatever session runs /agent-team create');
      if (!registryRoles(registry()).includes(role)) fail(`--role must be one of ${registryRoles(registry()).join(", ")}, got ${JSON.stringify(role)}`);
      const member = memberFromFlags(role, "add");
      const addRoute = checkedRoute(member, container, true);
      if (member.onMissing !== undefined && addRoute === "subagent") {
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      // Spec 0043 §1.3's route rule is about the member's EFFECTIVE route, and a member with no
      // route of its own inherits the block's — the same `member.route || container.route` the
      // on-missing check above already uses. Validating the bare member instead would reject
      // `add --kind codex` under a `route: pane` roster block, which is the one place it belongs.
      const memberErrors = validateMember({ ...member, route: addRoute }, registry());
      if (memberErrors.length) fail(memberErrors.join("; "));
      if (member.autoMode === "bypassPermissions" && addRoute === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen; use --auto-mode auto for hands-off runs\n');
      }
      container.members.push(member);
      const blockErrors = validateRosterBlock(normalizeRosterBlock(container, registry()), registry());
      if (blockErrors.length) fail(blockErrors.join("; "));
      warnRoleVisibility(role, level);
      const addedNamed = namedMembers(container.members).at(-1);
      requireHerdrName({ ...addedNamed, route: addedNamed.route || container.route }, "add");
      writeLevelFile(path, data);
      if (created) process.stderr.write(`roster.mjs: no roster existed — created a minimal one at level "${level}": ${path}\n`);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — added at the currently-resolving level "${level}" (${path})\n`);
      const added = namedMembers(container.members).at(-1);
      const result = { level, path, wasDefaulted, container: containerLabel(teamKey), member: added };
      process.stderr.write(`roster.mjs: added ${role} to ${path}\n`);
      // Spec 0044 §1.10 supersedes spec 0039: `add` writes the template and stops. Editing the
      // roster and standing up a live member are two acts, and while one command did both, that
      // command was the only way an agent had to get a divergent member running — so it reached
      // for it and wrote the roster on the way, which is the whole defect this spec closes.
      // Saying nothing here would silently strand anyone who relied on the old behaviour, so the
      // next step is named rather than left to be discovered.
      const effectiveRoute = addRoute;
      result.spawned = false;
      result.next_step = routeHasPane(effectiveRoute) && classProp(role, registry(), "chain") === true
        ? `config only — nothing was launched. To start this member: roster.mjs spawn-one ${role} --member ${added.name}`
        : `config only — nothing was launched. ${!routeHasPane(effectiveRoute) ? `route ${effectiveRoute}` : `role ${role} is never a peer session`}: dispatched on demand.`;
      process.stderr.write(`roster.mjs: ${result.next_step}\n`);
      out(result);
      break;
    }

    case "edit": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("edit needs --member <derived-name>");
      const { level, wasDefaulted, teamKey } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      const container = rosterContainer(data, teamKey);
      if (!container || !Array.isArray(container.members)) fail(`no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init\` first`);
      const idx = findMemberIndex(container.members, memberName);
      if (idx === -1) fail(`no member named ${JSON.stringify(memberName)} at level "${level}"`);
      const updated = { ...container.members[idx] };
      if (typeof opts.role === "string") updated.role = opts.role;
      // An empty value clears the field, as `--args ""` does.
      if (opts.model === "") delete updated.model;
      else if (typeof opts.model === "string") updated.model = opts.model;
      if (opts.effort === "") delete updated.effort;
      else if (typeof opts.effort === "string") updated.effort = opts.effort;
      if (typeof opts.route === "string") updated.route = opts.route;
      if (typeof opts["auto-mode"] === "string") updated.autoMode = opts["auto-mode"];
      if (opts.kind === true) fail("edit: --kind requires a value (e.g. claude, codex, pi)");
      if (typeof opts.kind === "string") {
        // §1.1: the default is total, so an explicit `claude` is stored as "no key" — a roster
        // file never gains `kind: "claude"` through an edit.
        if (opts.kind === KIND_DEFAULT) delete updated.kind;
        else updated.kind = opts.kind;
        if (opts.kind !== KIND_DEFAULT) {
          // §1.3: model/effort/auto-mode are Claude CLI flags and are rejected for another kind.
          // A claude member usually carries a `model`, so without this every `edit --kind codex`
          // on one would be unreachable. Cleared with a notice rather than a new flag, following
          // the on-missing route-switch precedent below: clear what the switch stranded, and say so.
          const mapsAutoMode = Boolean(KIND_AUTO_MODE_ARGS[opts.kind]);
          const strandable = mapsAutoMode ? ["model", "effort"] : ["model", "effort", "autoMode"];
          const stranded = strandable.filter((k) => updated[k] !== undefined && updated[k] !== null);
          // Supplied together in one invocation is a contradiction, not a stranding — never guess
          // which the user meant (§3.2(i)'s precedent).
          const suppliedNow = [
            typeof opts.model === "string" ? "--model" : null,
            typeof opts.effort === "string" ? "--effort" : null,
            typeof opts["auto-mode"] === "string" && !mapsAutoMode ? "--auto-mode" : null,
          ].filter(Boolean);
          if (suppliedNow.length) {
            fail(`edit: ${suppliedNow.join(", ")} cannot be combined with --kind ${opts.kind} — model and effort are Claude CLI flags and apply only to kind claude. Pass native arguments with --args instead.`);
          }
          for (const k of stranded) delete updated[k];
          if (stranded.length) {
            process.stderr.write(
              `roster.mjs: ah: cleared ${stranded.join(", ")} — ${stranded.length > 1 ? "they are" : "it is"} a Claude CLI setting and this member is now kind "${opts.kind}". Pass native arguments with --args.
`
            );
          }
        }
      }
      if (opts.args !== undefined) {
        const parsedArgs = parseArgsFlag(opts.args, "edit");
        if (parsedArgs === null) delete updated.args;
        else updated.args = parsedArgs;
      }
      if (opts["on-missing"] === true) fail("edit: --on-missing requires a value (auto)");
      // §3.2.1: supplied-ness must be read from `opts`, never from `updated` — `updated` already
      // carries a value merged in via {...existing}, so once merged, "supplied now" and "was already
      // there" are indistinguishable on `updated` alone. That conflation is the trap amendment (c) fixes.
      const onMissingSupplied = typeof opts["on-missing"] === "string";
      if (onMissingSupplied) updated.onMissing = opts["on-missing"];
      const routeOrRoleGiven = typeof opts.route === "string" || typeof opts.role === "string";
      const editRoute = checkedRoute(updated, container, routeOrRoleGiven);
      if (onMissingSupplied && editRoute === "subagent") {
        // §3.2(i): both supplied in one invocation — a contradiction, never guess which one wins.
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      if (!onMissingSupplied && updated.route === "subagent" && updated.onMissing !== undefined) {
        // §3.2(ii): a route switch stranded an inherited onMissing — clear it and say so, rather than
        // silently discarding something the user configured earlier or making the switch unreachable.
        const dropped = updated.onMissing;
        delete updated.onMissing;
        process.stderr.write(`roster.mjs: ah: dropped on-missing "${dropped}" — it applies only to peer-routed members, and this member is now route "subagent"\n`);
      }
      if (updated.role === "orchestrator") fail('role "orchestrator" is not a roster member');
      // A stale onMissing left from before is not this edit's to reject: the write migrates it.
      const checked = { ...updated, route: editRoute };
      if (!onMissingSupplied && (checked.onMissing === "never" || checked.onMissing === "prompt")) delete checked.onMissing;
      const errors = validateMember(checked, registry());
      if (errors.length) fail(errors.join("; "));
      warnRoleVisibility(updated.role, level);
      if (updated.autoMode === "bypassPermissions" && editRoute === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen; use --auto-mode auto for hands-off runs\n');
      }
      container.members[idx] = updated;
      const editedNamed = namedMembers(container.members)[idx];
      requireHerdrName({ ...editedNamed, route: editedNamed.route || container.route }, "edit");
      writeLevelFile(path, data);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — edited at the currently-resolving level "${level}" (${path})\n`);
      out({ level, path, wasDefaulted, container: containerLabel(teamKey), member: namedMembers(container.members)[idx] });
      break;
    }

    case "remove": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("remove needs --member <derived-name>");
      const result = removeConfigMember(memberName);
      if (!result.removed) fail(result.reason === "no such member" ? `no member named ${JSON.stringify(memberName)} at level "${result.level}"` : result.reason);
      if (result.wasDefaulted) process.stderr.write(`roster.mjs: no --level given — removed from the currently-resolving level "${result.level}" (${result.path})\n`);
      out({ level: result.level, path: result.path, wasDefaulted: result.wasDefaulted, removed: memberName, container: result.container, store: `${result.container} config at "${result.level}" (${result.path})` });
      break;
    }

    case "layout":
      fail("layout was removed: a team's layout is chosen when it is created — `roster.mjs create --mode <auto|columns|grid>`. An explicit --mode also becomes the default for future teams.");
      break;

    case "alias":
      fail("alias was removed: a team's name is chosen when it is created — `roster.mjs create --team <name>`. The name belongs to that team and is not stored anywhere else.");
      break;

    case "next-split": {
      const mode = opts.mode;
      if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
      const paneCountRaw = opts["pane-count"];
      const paneCount = typeof paneCountRaw === "string" ? Number(paneCountRaw) : fail("next-split needs --pane-count <N>");
      if (!Number.isInteger(paneCount) || paneCount < 0) fail(`--pane-count must be a non-negative integer, got ${JSON.stringify(paneCountRaw)}`);
      const self = typeof opts.self === "string" ? opts.self : fail("next-split needs --self <pane-id>");
      const created = typeof opts.created === "string" ? JSON.parse(opts.created) : fail("next-split needs --created <json array>");
      const geometry = typeof opts.geometry === "string" ? JSON.parse(opts.geometry) : fail("next-split needs --geometry <json array>");
      out(nextSplit({ mode, paneCount, self, created, geometry }));
      break;
    }

    case "layout-splits": {
      if (opts.next === true && opts.apply === true) fail("--next and --apply are mutually exclusive");
      if (detectTransport() !== "herdr") fail("layout-splits requires the herdr transport");
      if (!herdrOnPath()) {
        fail("transport is herdr (HERDR_ENV=1) but no `herdr` binary is on PATH — cannot place panes. Install herdr, or unset HERDR_ENV to use tmux/terminal.");
      }

      const splitCwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();

      if (opts.apply === true) {
        const target = typeof opts.target === "string" ? opts.target : fail("layout-splits --apply needs --target <pane-id>");
        const dir = opts.direction;
        if (dir !== "right" && dir !== "down") fail(`--direction must be "right" or "down", got ${JSON.stringify(dir)}`);
        let result;
        try {
          result = herdrCall(["pane", "split", "--pane", target, "--direction", dir, "--cwd", splitCwd, "--no-focus"]);
        } catch (err) {
          fail(err.message);
        }
        out({ pane_id: result.result.pane.pane_id, target, direction: dir });
        break;
      }

      const mode = opts.mode;
      if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
      const paneCountRaw = opts["pane-count"];
      const paneCount = typeof paneCountRaw === "string" ? Number(paneCountRaw) : fail("layout-splits needs --pane-count <N>");
      if (!Number.isInteger(paneCount) || paneCount < 0) fail(`--pane-count must be a non-negative integer, got ${JSON.stringify(paneCountRaw)}`);
      const self = typeof opts.self === "string" ? opts.self : process.env.HERDR_PANE_ID;
      if (!self) fail("layout-splits needs --self <pane-id> (or HERDR_PANE_ID in the environment)");

      if (opts.next === true) {
        const created = typeof opts.created === "string" ? JSON.parse(opts.created) : fail("layout-splits --next needs --created <json array>");
        let geomResult;
        try {
          geomResult = herdrCall(["pane", "layout", "--current"]);
        } catch (err) {
          fail(err.message);
        }
        const geometry = geomResult.result.layout.panes;
        const decision = nextSplit({ mode, paneCount, self, created, geometry });
        const targetRect = geometry.find((g) => g.pane_id === decision.target).rect;
        out({
          index: created.length + 1,
          pane_count: paneCount,
          mode,
          target: decision.target,
          direction: decision.direction,
          target_rect: targetRect,
          target_is_self: decision.target === self,
          geometry,
        });
        break;
      }

      // Bare form: perform the whole spec 0004 §6.6 loop, stop at the first failure.
      if (paneCount === 0) {
        out({ panes: [], complete: true });
        break;
      }
      const { panes, splits } = runLayoutLoop({ mode, paneCount, self, splitCwd });
      out({ panes, splits, mode, pane_count: paneCount, complete: true });
      break;
    }

    case "create": {
      if ([opts.plan === true, opts.commit === true, opts.spawn === true].filter(Boolean).length > 1) {
        fail("create: --plan, --commit, and --spawn are mutually exclusive");
      }
      const dir = hierarchyDir(cwd);
      // Spec 0015 §7.2: --from without an explicit --team targets the entry's own alias (or the
      // default team when the alias is null) — an explicit --team still wins. Must happen before
      // anything below reads teamArg/repoBasename (naming, file target, history upsert alias).
      if (typeof opts.from === "string" && !teamArg) {
        const entry = resolveHistoryEntry(dir);
        teamArg = entry.alias || null;
        repoBasename = teamPrefix(cwd, teamArg);
        // The stored alias names the team FILE the entry was committed under, so re-derive the
        // scope from it — a null alias (a pre-0044 default team) still resolves through §1.1.
        resolveTeamFileScope();
      }
      if (rosterArg && typeof opts.from === "string") fail("create --from takes no --roster — a history entry carries its own members");
      // An explicit selector that silently fell back to the default block would look applied and
      // never be, so a missing block refuses before anything is cleared, launched, or written.
      if (rosterArg) {
        const named = resolveRoster(cwd, rosterArg, repoBasename, registry());
        if (!named || named.teamKey !== rosterArg) {
          fail(`create --roster ${rosterArg}: no rosters.${rosterArg} block with members at any level — nothing was launched or written. Define it with \`roster.mjs init --roster ${rosterArg}\` and \`roster.mjs add --roster ${rosterArg} --role <R>\``);
        }
      }
      // --team once also picked `rosters.<team>`; it now names only the team, so a block that would
      // have been picked by that name is pointed out rather than silently passed over.
      const createWarnings = [];
      if (teamArg && !rosterArg && typeof opts.from !== "string") {
        const named = resolveRoster(cwd, teamArg, repoBasename, registry());
        if (named && named.teamKey === teamArg) {
          createWarnings.push(`a rosters.${teamArg} block exists, but --team names only the team: this team is built from the default roster. To build it from rosters.${teamArg}, pass --roster ${teamArg}.`);
        }
      }
      if (!teamArg) {
        const teamName = teamFile ?? teamPrefix(cwd, null);
        for (const alias of staleTeamKeys(cwd, registry()).aliases) {
          if (alias === teamName) continue;
          createWarnings.push(`this repo's config still sets a team alias, "${alias}", which no longer names teams: this team is named "${teamName}". To keep the old member names (${alias}-<role>), pass --team ${alias}.`);
        }
      }
      createWarnings.push(...staleTeamKeys(cwd, registry()).warnings);
      for (const w of createWarnings) process.stderr.write(`roster.mjs: warning — ${w}\n`);
      const withWarnings = (obj) => (createWarnings.length ? { ...obj, warnings: createWarnings } : obj);
      // Spec 0044 §1.1: all three modes settle the scope here, together. `--commit` creates a team
      // exactly as `--plan`/`--spawn` do, and reaching `writeTeam` without this let it recreate the
      // shared default — and, when that default held a live team, overwrite that running team in
      // place. Scope first, then the `--team` collision rule, then §1.11's ownership gate against
      // whatever team is already at the settled scope.
      resolveWritableTeamScope(dir, { replacing: true, committing: opts.commit === true });
      checkNewTeamName(dir);
      guardTeamPrefixCollision(dir, teamFile);
      guardLiveTeamAtScope(dir, { committing: opts.commit === true });
      if (opts.spawn === true) {
        await createSpawn(dir, withWarnings);
        break;
      }
      if (opts.commit) {
        // `--from --commit` (spec 0015 §7.2): --commit still reads members from --verified, not
        // history (only a real spawn/check-in cycle has ref/transport_id/checked_in) — but a
        // stored entry that no longer validates must fail() before anything else runs, so this
        // eager check is the only place --from's validation happens on the commit path.
        if (typeof opts.from === "string") validateHistoryMembers(resolveHistoryEntry(dir));
        const verified = typeof opts.verified === "string" ? JSON.parse(opts.verified) : fail("--commit needs --verified <json array>");
        if (!Array.isArray(verified)) fail(`create --commit: --verified must be a JSON array, got ${typeof verified}`);
        const transport = typeof opts.transport === "string" ? opts.transport : fail("--commit needs --transport");
        const rosterLevel = typeof opts["roster-level"] === "string" ? opts["roster-level"] : fail("--commit needs --roster-level");
        // Spec 0025 §3/§4: --verified is either a JSON array of member objects (validated per
        // validateTeamMember, §3) or member-name strings (hydrated from the --roster-level
        // roster, §4). Mixed shapes, unknown names, or invalid entries fail before any write.
        const allStrings = verified.length > 0 && verified.every((m) => typeof m === "string");
        const allObjects = verified.every((m) => m && typeof m === "object" && !Array.isArray(m));
        let members;
        let needsResync = false;
        const sourceMembers = createSourceMembers(dir);
        const memberModels = memberModelOverrides(sourceMembers);
        // A member create --spawn skipped never ran, so it is not recorded even when named here.
        const skips = sourceMembers.map((m) => withModel(m, memberModels.get(m.name))).filter((m) => routeHasPane(m.route) && autoSkipped(m));
        const skipNames = new Set(skips.map((m) => m.name));
        if (allStrings) {
          // Spec 0032 §3.4a/§3.4c: reuse resolveRoster's own resolution and no-match predicate
          // directly, rather than re-deriving the container from --roster-level by hand — a
          // hand-rolled predicate drifted from resolveRoster's (`!members.length` vs null-only),
          // so an override with `members: []` was picked here while --plan correctly fell
          // through to the default. resolveRoster is exactly what --plan itself calls.
          const resolved = resolveRoster(cwd, rosterArg, repoBasename, registry());
          const rosterMembers = resolved ? renameInUse(resolved.members, repoBasename) : [];
          const rosterRoute = resolved ? resolved.route : undefined;
          members = verified.filter((name) => !skipNames.has(name)).map((name) => {
            const found = rosterMembers.find((m) => m.name === name);
            if (!found) {
              fail(`create --commit: --verified names no member ${JSON.stringify(name)} in the ${rosterLevel} roster — it defines: ${rosterMembers.map((m) => m.name).join(", ") || "(none)"}`);
            }
            return { role: found.role, name: found.name, model: memberModels.get(found.name) ?? found.model, effort: found.effort, route: found.route || rosterRoute, autoMode: found.autoMode, transport_id: null };
          });
          needsResync = true;
        } else if (allObjects) {
          const offenses = verified.map((m, i) => ({ i, errs: validateTeamMember(m, registry()) })).filter((o) => o.errs.length > 0);
          if (offenses.length > 0) {
            const detail = offenses.map((o) => `--verified entry ${o.i} is not a valid member: ${o.errs.join("; ")}`).join(". ");
            fail(`create --commit: ${detail}. --verified takes either a JSON array of member objects (as produced by the spawn/check-in cycle) or a JSON array of member-name strings (hydrated from the roster at --roster-level).`);
          }
          // Each member was launched pointing at a team file; committing it under another would
          // leave its hooks attributing it to a team this record is not.
          const foreign = verified.filter((m) => Object.prototype.hasOwnProperty.call(m, "team") && (m.team ?? null) !== (teamFile ?? null));
          if (foreign.length) {
            const label = (t) => (t == null ? "the default team (team.json)" : JSON.stringify(t));
            fail(
              `create --commit: ${foreign.map((m) => `${m.name} checked in to team ${label(m.team)}`).join(", ")}, but this commit writes team ${label(teamFile)} — ` +
                `nothing was written. Pass the same --team to every create phase (--plan, --spawn, --commit).`
            );
          }
          // The check-in's `team` has done its job; the file the row lands in already says which team it is.
          members = verified.filter((m) => !(skipNames.has(m.name) && !m.model)).map(({ team: _checkedInTeam, ...member }) => member);
        } else {
          fail("create --commit: --verified must be either all member objects or all member-name strings, not a mix");
        }
        // renamed_from comes only from this commit's own renames: a member its --names-in-use renamed
        // is recorded with the name it was derived as, and any value the caller supplied is dropped.
        members = members.map((m) => {
          const source = sourceMembers.find((s) => s.renamed_from && s.name === m.name && s.role === m.role);
          const { renamed_from: _supplied, ...rest } = m;
          return source ? { ...rest, renamed_from: source.renamed_from } : rest;
        });
        // roster.mjs runs as a transient Bash-tool subprocess, so process.ppid here is
        // that shell, not the orchestrator's own long-lived process — using it would make
        // the staleness sweep (sessionstart.mjs) tear the Team down almost immediately.
        // CLAUDE_PID is the env var every claude session exports as its own pid (see
        // sessionstart.mjs/README's peers.jsonl liveness records, which rely on the same
        // invariant); an explicit --orchestrator-pid overrides it for tests or an
        // unusual environment where the env var isn't propagated.
        const orchestratorPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
        // Spec 0018 §3: an unresolvable or dead owner pid must refuse, not write null — a null
        // pid reads as dead and gets the team swept (deleted) on the next SessionStart.
        if (!Number.isInteger(orchestratorPid)) {
          fail("create --commit: no orchestrator pid resolvable (CLAUDE_PID unset and no --orchestrator-pid given) — refusing to write a team with an unowned pid");
        }
        if (!pidAlive(orchestratorPid)) {
          fail(`create --commit: --orchestrator-pid ${orchestratorPid} is not a live process — refusing to write a team owned by a dead pid`);
        }
        // Every team-creating write records the roster block it was built from (null: the default
        // block, or a history entry, which carries its own members) and its layout.
        const templateRoster = typeof opts.from === "string" ? null : resolveRoster(cwd, rosterArg, repoBasename, registry());
        const layout = createLayout();
        const team = {
          version: 1,
          team_id: newId(),
          created: localIso(),
          roster_level: rosterLevel,
          transport,
          orchestrator: { session_id: typeof opts.session === "string" ? opts.session : null, pid: orchestratorPid },
          members,
          expected_root: realCwd(cwd),
          roster: templateRoster ? templateRoster.teamKey : null,
          layout: layout.mode,
        };
        writeTeam(dir, team, teamFile);
        storeTeamLayout(layout);
        // A history-write failure must not fail `create` — the Team is already committed and
        // running; a missing history row is cosmetic (spec 0015 §4).
        const skipped = skips.filter((m) => !members.some((x) => x.name === m.name)).map(skippedEntry);
        const outObj = withSkipped(withWarnings({ committed: true, team, ...renamedField(members) }), skipped);
        // Spec 0025 §4: a hydrated commit has names but no panes yet — tell the caller the next
        // step (`resync`) instead of letting `move` fail confusingly on "no pane to move".
        if (needsResync) outObj.needs_resync = true;
        try {
          const normalized = normalizeMembers(team.members);
          const historyResult = upsertHistory(dir, {
            fingerprint: fingerprint({ roster_level: team.roster_level, transport: team.transport, members: normalized }),
            // The team FILE scope, so `create --from` and historyEntryIsActive resolve back to the
            // file this commit actually wrote (§1.1 moved that off the shared default).
            alias: teamFile || null,
            roster_level: team.roster_level,
            transport: team.transport,
            members: normalized,
            team_id: team.team_id,
          });
          // Spec 0015 §6: exceeding the 5-entry cap because every eviction candidate is a live
          // team is temporary but must not be silent.
          if (historyResult.capExceeded) outObj.history = { ok: true, cap_exceeded: true };
        } catch (err) {
          outObj.history = { ok: false, why: err && err.message ? err.message : String(err) };
        }
        out(outObj);
        break;
      }
      // --plan (default): resolve, refuse a live Team, clear a stale one, report the spawn plan.
      const plan = withWarnings(getMembersPlan(dir));
      const needing = planNeedingModel(plan);
      out(needing.length ? { ...plan, members_needing_model: needing } : plan);
      break;
    }

    case "disband": {
      // Spec 0006 §6: an unrecognized flag must fail loudly, not degrade to the (now destructive-
      // by-default) bare path. --kill is accepted-and-ignored (§5.4) for 0002-era callers.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!DISBAND_FLAGS.has(key) && key !== "commit" && key !== "keep-sessions") fail(`disband: unrecognized flag --${key} (use --plan, or --close --confirm --plan-token <tok>; tracking-only removal is \`untrack --all\`)`);
      }
      // Spec 0046 §3: these modes moved to `untrack`. A named error, not the generic unknown-flag
      // one — the caller asked for tracking-only removal and needs the verb that still does it.
      if (opts.commit === true || opts["keep-sessions"] === true) {
        fail(
          `${cmd}: --commit and --keep-sessions were removed in 0046 — \`${cmd}\` now only plans or CLOSES sessions. ` +
            `To forget the record and leave the session running, use \`untrack ${cmd === "disband" ? "--all" : "<name>"} --commit --keep-sessions\`.`,
        );
      }
      if (opts.close === true && opts.kill === true) {
        fail("disband --close cannot be combined with --kill");
      }
      const dir = hierarchyDir(cwd);

      // --close (spec 0016 §4.5): closes the live sessions the preceding plan call named, via
      // argv built directly (never runShell's /bin/sh), then reconciles the team file against
      // what actually closed — no bookkeeping call follows.
      if (opts.close === true) {
        const team = readTeam(dir, teamFile);
        if (!team) {
          // Spec 0040 §1.1/§1.3: no team.json — close the live registry peers instead, under the
          // same three gates, with the literal "no-team" standing in for team_id in the token.
          // Dedup like :2521's plan does. closeToken() sorts the ids WITHOUT deduping, so one
          // session appearing as both a nameless `up` row and a `briefed` row yields a plan token
          // over one id and a close set over two — the token never matches its own plan.
          const closable = closableMembers(dedupPeers(peerFallbackMembers(dir, NO_TEAM_SCOPE)));
          const unreadable = unreadableTeamFile(dir);
          const unreadableField = unreadable ? { team_file_unreadable: unreadable } : {};
          if (closable.length === 0) {
            out({ closed: false, reason: "no active team and no live peers", sources: sourcesField(dir, NO_TEAM_SCOPE, null), ...unreadableField });
            break;
          }
          gateClose("disband", "no-team", closable);
          const results = closable.map((m) => closeOne(m, null));
          out({ closed: results.every((r) => r.closed), source: "peers", results, sources: sourcesField(dir, NO_TEAM_SCOPE, null), pruned: [], kept: [], team_removed: false, team_file: null, ...unreadableField });
          break;
        }
        let healedMembers = team.members;
        if (team.transport === "herdr") {
          const result = resyncMembers(team);
          if (result.query_ok) healedMembers = result.members;
        }
        // Spec 0040 §1.4a: the close set is the union of team.json members and live registry
        // peers outside it; the token pins exactly that union.
        const closable = closableMembers([...healedMembers, ...peerExtras(dir, healedMembers, teamFile)]);
        gateClose("disband", team.team_id, closable);
        const results = closable.map((m) => closeOne(m, team.transport));
        out({ closed: results.every((r) => r.closed), results, sources: sourcesField(dir, teamFile, team), ...reconcileAfterClose(dir, team, results) });
        break;
      }



      // Bare disband / --plan / --kill (ignored): the new default (spec 0006 §5.1). Read-only,
      // emits the close plan, writes nothing. Spec 0008 §5.6 (AMENDMENT): for herdr, resync the
      // member list in memory first — the plan then targets each member's *current* pane — but
      // never persist the heal and never fail() on a query error (degrade to the stored ids).
      const team = readTeam(dir, teamFile);
      if (!team) {
        // Spec 0040 §1.1/§1.5: plan over the live registry peers; `source: "peers"` says so.
        const fallback = dedupPeers(peerFallbackMembers(dir, NO_TEAM_SCOPE));
        const closable = closableMembers(fallback);
        const unreadable = unreadableTeamFile(dir);
        const unreadableField = unreadable ? { team_file_unreadable: unreadable } : {};
        if (closable.length === 0) {
          out({ disbanded: false, reason: "no active team and no live peers", sources: sourcesField(dir, NO_TEAM_SCOPE, null), ...unreadableField });
          break;
        }
        const peersToken = closeToken("no-team", closable);
        out({ close: fallback.map(peerFallbackPlanEntry), close_token: peersToken, next: closeCommand("disband", null, peersToken), source: "peers", sources: sourcesField(dir, NO_TEAM_SCOPE, null), ...unreadableField });
        break;
      }
      let healedMembers = team.members;
      let resyncSummary = null;
      if (team.transport === "herdr") {
        const result = resyncMembers(team);
        if (result.query_ok) {
          healedMembers = result.members;
          resyncSummary = { ok: true, counts: result.counts };
          if (result.warning) resyncSummary.warning = result.warning;
        } else {
          healedMembers = team.members.map((m) => ({ ...m, status: "unqueried" }));
          resyncSummary = { ok: false, reason: result.query_error };
        }
      }
      const close = healedMembers.map((m) => {
        let command = null;
        if (routeHasPane(m.route) && m.transport_id) {
          if (team.transport === "herdr") command = `herdr pane close ${m.transport_id}`;
          else if (team.transport === "tmux") command = `tmux kill-pane -t ${m.transport_id}`;
        }
        const entry = { role: m.role, name: m.name, route: m.route, transport: team.transport, transport_id: m.transport_id, command };
        if (team.transport === "herdr") entry.resync_status = m.status;
        return entry;
      });
      // Spec 0040 §1.4a: live registry peers outside team.json join the plan, labeled, and the
      // token hashes the union — with none present, output and token are exactly the team-only ones.
      const extras = peerExtras(dir, healedMembers, teamFile);
      for (const m of extras) close.push(peerFallbackPlanEntry(m));
      const planToken = closeToken(team.team_id, closableMembers([...healedMembers, ...extras]));
      const disbandOut = { close, close_token: planToken, next: closeCommand("disband", null, planToken), sources: sourcesField(dir, teamFile, team) };
      if (resyncSummary) disbandOut.resync = resyncSummary;
      out(disbandOut);
      break;
    }

    case "dismiss": {
      // Spec 0020: the missing inverse of `spawn-one` — drop ONE member from a live team.
      // Mirrors disband's plan/close/commit split exactly, scoped to one member; reuses every
      // close-path helper verbatim (§2/§3.3). Do not fork a second close implementation.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!DISMISS_FLAGS.has(key) && key !== "commit" && key !== "keep-sessions") fail(`dismiss: unrecognized flag --${key} (use --plan, or --close --confirm --plan-token <tok> [--also-config] [--level L]; tracking-only removal is \`untrack <name>\`)`);
      }
      // Spec 0046 §3: these modes moved to `untrack`. A named error, not the generic unknown-flag
      // one — the caller asked for tracking-only removal and needs the verb that still does it.
      if (opts.commit === true || opts["keep-sessions"] === true) {
        fail(
          `${cmd}: --commit and --keep-sessions were removed in 0046 — \`${cmd}\` now only plans or CLOSES sessions. ` +
            `To forget the record and leave the session running, use \`untrack ${cmd === "disband" ? "--all" : "<name>"} --commit --keep-sessions\`.`,
        );
      }
      if (opts.plan === true && opts.close === true) fail("dismiss --plan cannot be combined with --close");
      if ((opts["also-config"] === true || typeof opts.level === "string") && opts.close !== true) {
        fail("dismiss: --also-config and --level are only valid with --close (0046 U2) — a plan removes nothing");
      }
      const name = typeof opts._[0] === "string" ? opts._[0] : fail("dismiss needs a member name: roster.mjs dismiss <name> [--plan|--close --confirm --plan-token <tok>]");
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      const target = team ? team.members.find((m) => m.name === name) : null;
      // Spec 0040 §1.4b + 0046 §2.4: a name absent from team.json (or no team.json at all) is
      // resolved against the live registry by every identifier the user can see.
      const dismissScope = team ? teamFile : NO_TEAM_SCOPE;
      const fallback = target ? [] : dedupPeers(peerFallbackMembers(dir, dismissScope, team && Array.isArray(team.members) ? team.members : []));
      const fbTarget = target ? null : resolvePeerTarget(fallback, name, team ? team.transport : null);
      if (!team && !fbTarget) {
        if (closableMembers(fallback).length === 0) {
          out({ dismissed: false, reason: "no active team and no live peers", sources: sourcesField(dir, NO_TEAM_SCOPE, null) });
          break;
        }
        fail(
          `dismiss: no member named ${JSON.stringify(name)} — no team.json; live untracked sessions: ` +
            JSON.stringify(fallback.map(peerIdentifiers)) +
            " — dismiss accepts any of those name / pane_id / session_id values",
        );
      }
      if (!target && !fbTarget) {
        if (team.members.some((m) => m.role === name)) {
          fail(`dismiss: no member named ${JSON.stringify(name)} in team ${team.team_id} — that is a role, not a member name; dismiss takes a derived name (0019 §3.2)`);
        }
        fail(
          `dismiss: no member named ${JSON.stringify(name)} in team ${team.team_id} — it has: ${team.members.map((m) => m.name).join(", ") || "(none)"}` +
            (fallback.length > 0
              ? "; live untracked sessions in this team: " +
                JSON.stringify(fallback.map(peerIdentifiers)) +
                " — dismiss accepts any of those name / pane_id / session_id values"
              : "; no live untracked sessions in this team either"),
        );
      }
      if (fbTarget) {
        // Spec 0040 §1.4b/§1.5: single-record plan/close, same shapes as the team path plus
        // `source: "peers"`; the token scope is the team's id when one exists, else "no-team".
        const scope = team ? team.team_id : "no-team";
        const closable = closableMembers([fbTarget]);
        if (opts.close === true) {
          if (closable.length === 0) fail(`dismiss --close: ${name} has no addressable pane (live peer record without a pane_id)`);
          gateClose("dismiss", scope, closable);
          const results = closable.map((m) => closeOne(m, null));
          out({ closed: results.every((r) => r.closed), source: "peers", results, sources: sourcesField(dir, dismissScope, team) });
          break;
        }
        const peerToken = closeToken(scope, closable);
        out({ member: peerFallbackPlanEntry(fbTarget), live: fbTarget.live, close_token: peerToken, ...(closable.length > 0 ? { next: closeCommand("dismiss", name, peerToken) } : {}), source: "peers", sources: sourcesField(dir, dismissScope, team) });
        break;
      }

      // --close --confirm --plan-token <tok>: reuse disband --close's machinery verbatim.
      if (opts.close === true) {
        let healedMembers = team.members;
        if (team.transport === "herdr") {
          const result = resyncMembers(team);
          if (result.query_ok) healedMembers = result.members;
        }
        const healedTarget = healedMembers.find((m) => m.name === name) || target;
        const closable = closableMembers([healedTarget]);
        if (closable.length === 0) {
          fail(`dismiss --close: ${name} has no addressable pane (route=${target.route}, transport_id=${target.transport_id ?? null}) — use --commit to prune the record`);
        }
        const closeList = closable.map((m) => ({ name: m.name, transport_id: m.transport_id }));
        if (opts.confirm !== true) {
          fail(`dismiss --close: --confirm is required to close a live session. Close list: ${JSON.stringify(closeList)}`);
        }
        if (typeof opts["plan-token"] !== "string" || !opts["plan-token"]) {
          fail("dismiss --close needs --plan-token <tok>, from a preceding `dismiss <name>` (plan) call");
        }
        // §3.3: token scoping is load-bearing and falls out for free — closeToken hashes
        // {team_id, ids:[...]} over exactly THIS member's closable set (one id here, vs a
        // whole-team disband plan's every-id set), so a whole-team token can never authorise
        // this close and this token can never authorise a whole-team close. Do not widen the
        // hash input to "simplify" this later.
        const expectedToken = closeToken(team.team_id, closable);
        if (opts["plan-token"] !== expectedToken) {
          fail("dismiss --close: --plan-token does not match the current close plan (the topology may have changed) — re-run `dismiss` and retry with the fresh token");
        }
        const results = closable.map((m) => {
          try {
            closeMemberPane(team.transport, m.transport_id);
            return { name: m.name, transport_id: m.transport_id, closed: true, error: null };
          } catch (err) {
            return { name: m.name, transport_id: m.transport_id, closed: false, error: err.message };
          }
        });
        const allClosed = results.every((r) => r.closed);
        // §2.1 bookkeeping: the row goes only when the close actually succeeded. A failed close
        // that still dropped the record is exactly the orphan GitHub #4 was about.
        const dismissClose = { closed: allClosed, results, untracked: false, sources: sourcesField(dir, teamFile, team) };
        if (allClosed) {
          // The template key is read from the team file, which the last departure removes.
          const templateKey = opts["also-config"] === true ? teamTemplateKey(dir) : null;
          if (writeTeamRows(dir, team, team.members.filter((m) => m.name !== name))) dismissClose.team_removed = true;
          dismissClose.untracked = true;
          if (opts["also-config"] === true) dismissClose.config = removeConfigMember(target.name, templateKey);
        }
        out(dismissClose);
        break;
      }


      // Bare dismiss / --plan: read-only. For herdr, resync in memory first (0008 §5.6) so the
      // plan names the member's current pane; never persist the heal.
      let healedMembers = team.members;
      if (team.transport === "herdr") {
        const result = resyncMembers(team);
        healedMembers = result.query_ok ? result.members : team.members.map((m) => ({ ...m, status: "unqueried" }));
      }
      const healedTarget = healedMembers.find((m) => m.name === name) || target;
      let command = null;
      if (routeHasPane(healedTarget.route) && healedTarget.transport_id) {
        if (team.transport === "herdr") command = `herdr pane close ${healedTarget.transport_id}`;
        else if (team.transport === "tmux") command = `tmux kill-pane -t ${healedTarget.transport_id}`;
      }
      // §3.2 store split (0019 §3.3.1): `live` reads the registry; `command` reads team.json's
      // transport_id regardless of `live` — a stale-registry member still yields a close command.
      const memberOut = { role: healedTarget.role, name: healedTarget.name, route: healedTarget.route, transport: team.transport, transport_id: healedTarget.transport_id, command };
      if (team.transport === "herdr") memberOut.resync_status = healedTarget.status || "unqueried";
      const dismissClosable = closableMembers([healedTarget]);
      const dismissToken = closeToken(team.team_id, dismissClosable);
      out({
        member: memberOut,
        // Spec 0043 §1.6 three-valued: `null` is "could not determine", distinct from `false`.
        ...(() => {
          const st = memberLiveness(dir, healedTarget);
          return st.indeterminate ? { live: null, live_unknown: st.why } : { live: st.live };
        })(),
        close_token: dismissToken,
        // Nothing to close means `--close` would only refuse, so no command is offered.
        ...(dismissClosable.length > 0 ? { next: closeCommand("dismiss", name, dismissToken) } : {}),
        sources: sourcesField(dir, teamFile, team),
        team_id: team.team_id,
        remaining: team.members.filter((m) => m.name !== name).map((m) => m.name),
        ...(team.members.every((m) => m.name === name) ? { team_will_be_removed: true } : {}),
      });
      break;
    }

    case "untrack": {
      // Spec 0046 §2.3: the ONLY way to drop a tracking record without closing a session. GitHub
      // #4 happened because that capability was a --commit FLAG on the destructive verbs, so an
      // agent reaching for "remove the member" got tracking-only removal and left live sessions
      // orphaned with nothing naming them. As its own verb it can carry a live guard that every
      // caller passes through, and the guard says untrack is not undo.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!UNTRACK_FLAGS.has(key)) fail(`untrack: unrecognized flag --${key} (use <name>|--all [--plan|--commit] [--keep-sessions] [--also-config] [--level L])`);
      }
      if (opts.plan === true && opts.commit === true) fail("untrack --plan cannot be combined with --commit");
      const untrackAll = opts.all === true;
      const untrackName = typeof opts._[0] === "string" ? opts._[0] : null;
      if (untrackAll && untrackName) fail("untrack: pass a member name or --all, not both");
      if (!untrackAll && !untrackName) fail("untrack needs a member name or --all: roster.mjs untrack <name>|--all [--plan|--commit] [--keep-sessions]");
      if ((opts["also-config"] === true || typeof opts.level === "string") && untrackAll) {
        fail("untrack: --also-config and --level apply to a single member, not --all");
      }
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      const commit = opts.commit === true;
      const keep = opts["keep-sessions"] === true;

      // §2.3 idempotency: a skill-driven agent that untracks after a close which already dropped
      // the row must not see an error.
      if (!team) {
        out({ untracked: false, already_untracked: true, reason: "no team file to forget" });
        break;
      }
      if (untrackAll) {
        if (!commit) {
          out({
            plan: "untrack-all",
            team_id: team.team_id,
            members: team.members.map((m) => ({ role: m.role, name: m.name, ...liveField(dir, m) })),
            removes: teamPath(dir, teamFile),
          });
          break;
        }
        if (!keep) untrackLiveGuard(dir, team.members, "disband --close");
        clearTeam(dir, teamFile);
        out({
          untracked: true,
          team_id: team.team_id,
          removed: teamPath(dir, teamFile),
          members: team.members.map((m) => ({ role: m.role, name: m.name, transport_id: m.transport_id })),
        });
        break;
      }

      const utTarget = team.members.find((m) => m.name === untrackName) || null;
      if (!utTarget) {
        // §2.3: a live peer that team.json never recorded has no record to forget — say so, and
        // name the verb that CAN act on it, rather than repeating #4's dead end.
        const livePeers = dedupPeers(peerFallbackMembers(dir, teamFile));
        const asPeer = resolvePeerTarget(livePeers, untrackName, team.transport);
        if (asPeer) {
          fail(
            `untrack: ${JSON.stringify(untrackName)} is not tracked in team ${team.team_id} — it is a LIVE untracked session ` +
              `(${JSON.stringify(peerIdentifiers(asPeer))}). There is no record to forget; \`dismiss ${asPeer.name} --close\` closes it.`,
          );
        }
        out({ untracked: false, already_untracked: true, team_id: team.team_id, member: untrackName });
        break;
      }
      if (!commit) {
        out({
          plan: "untrack",
          team_id: team.team_id,
          member: { role: utTarget.role, name: utTarget.name, ...liveField(dir, utTarget) },
          remaining: team.members.filter((m) => m.name !== untrackName).map((m) => m.name),
        });
        break;
      }
      if (!keep) untrackLiveGuard(dir, [utTarget], `dismiss ${utTarget.name} --close`);
      out(untrackMember(dir, team, utTarget, untrackName));
      break;
    }

    case "resync": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!RESYNC_FLAGS.has(key)) fail(`resync: unrecognized flag --${key} (use --dry-run, --team, --bind, or --cwd)`);
      }
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      if (!team) {
        out({ resynced: false, reason: "no active team" });
        break;
      }
      if (team.transport !== "herdr") {
        out({ resynced: false, reason: transportNoop(team.transport) });
        break;
      }
      let bind = null;
      if (opts.bind !== undefined) {
        try {
          bind = JSON.parse(opts.bind);
        } catch {
          fail("resync: --bind is not valid JSON");
        }
        if (!bind || typeof bind !== "object" || Array.isArray(bind)) fail("resync: --bind must be a JSON object mapping member name to pane id");
      }
      const result = resyncMembers(team, { dir, teamCwd: findGitRoot(cwd) || cwd, selfPaneId: process.env.HERDR_PANE_ID || null, bind });
      if (!result.query_ok) fail(result.query_error);
      if (result.bind_error) fail(result.bind_error);
      const dryRun = opts["dry-run"] === true;
      const membersOut = result.members.map((m) => {
        if (!m || typeof m !== "object" || Array.isArray(m)) return { status: "malformed", raw: m };
        const entry = { role: m.role, name: m.name, status: m.status };
        if (m.status === "updated") {
          entry.from = m.from;
          entry.to = m.to;
          if (m.match_by) entry.match_by = m.match_by;
        }
        if (m.status === "ambiguous") entry.candidates = m.candidates;
        return entry;
      });
      if (!dryRun) {
        team.members = result.members.map(stripResyncMeta);
        writeTeam(dir, team, teamFile);
      }
      const resyncOut = { resynced: true, dry_run: dryRun, transport: "herdr", members: membersOut, counts: result.counts };
      if (result.warning) resyncOut.warning = result.warning;
      // Spec 0025 §6: a duplicate-pane warning must not silently drop this one, or vice versa —
      // distinct key, since `warning` is an established string field callers already match on.
      if (result.counts.malformed > 0) {
        resyncOut.warning_malformed = `${result.counts.malformed} member(s) in team.json are malformed (not objects) and were left untouched — re-run \`create --commit\` with --verified as an array of member names to repair (spec 0025 §4)`;
      }
      out(resyncOut);
      break;
    }

    case "move": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!MOVE_FLAGS.has(key)) fail(`move: unrecognized flag --${key} (use --tab/--split, --new-tab[/--workspace], --new-workspace, or --allow-global)`);
      }
      const name = typeof opts._[0] === "string" ? opts._[0] : fail("move needs a member name: roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace");
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      const teamMembers = team && Array.isArray(team.members) ? team.members : [];
      const member = teamMembers.find((m) => m.name === name);
      if (!member) fail(`move: no member named ${JSON.stringify(name)} — known members: ${teamMembers.map((m) => m.name).filter(Boolean).join(", ") || "(none)"}`);
      if (!routeHasPane(member.route) || member.transport_id == null) fail(`move: member ${name} has no pane to move`);
      if (team.transport !== "herdr") {
        out({ moved: false, reason: transportNoop(team.transport) });
        break;
      }
      const modeCount = [opts.tab !== undefined, opts["new-tab"] === true, opts["new-workspace"] === true].filter(Boolean).length;
      if (modeCount !== 1) fail("move: exactly one of --tab, --new-tab, --new-workspace is required");
      const moveUsage = "roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace";
      if (opts.tab !== undefined && typeof opts.tab !== "string") fail(`move: --tab requires a value: ${moveUsage}`);
      if (opts.tab !== undefined && opts.split === undefined) fail(`move: --tab requires --split right|down: ${moveUsage}`);
      if (opts.workspace !== undefined && typeof opts.workspace !== "string") fail(`move: --workspace requires a value: ${moveUsage}`);
      if (opts.split !== undefined && opts.tab === undefined) fail("move: --split is only valid with --tab");
      const herdrArgs = ["pane", "move", member.transport_id];
      if (opts.tab !== undefined) {
        herdrArgs.push("--tab", opts.tab);
        if (opts.split !== undefined) {
          if (opts.split !== "right" && opts.split !== "down") fail(`move: --split must be "right" or "down", got ${JSON.stringify(opts.split)}`);
          herdrArgs.push("--split", opts.split);
        }
      } else if (opts["new-tab"] === true) {
        herdrArgs.push("--new-tab");
        if (typeof opts.workspace === "string") herdrArgs.push("--workspace", opts.workspace);
      } else {
        herdrArgs.push("--new-workspace");
      }
      const commandString = `herdr ${herdrArgs.join(" ")}`;
      if (opts["dry-run"] === true) {
        out({ moved: false, dry_run: true, command: commandString });
        break;
      }
      try {
        herdrCall(herdrArgs);
      } catch (err) {
        fail(err.message);
      }
      // Ignore the move response body entirely (spec 0008 §2/§5.4 step 7) — re-query instead.
      const result = resyncMembers(team);
      if (!result.query_ok) {
        // spec 0008 §7.5: the pane already moved, so a query failure is reported at exit 0, never fail() —
        // a non-zero exit here would misrepresent the move (which succeeded) as having failed.
        out({ moved: true, command: commandString, resync: { ok: false, reason: result.query_error } });
        break;
      }
      team.members = result.members.map(stripResyncMeta);
      writeTeam(dir, team, teamFile);
      const healed = result.members.find((m) => m.name === name);
      const resyncOut = { ok: true, status: healed.status };
      if (healed.status === "updated") {
        resyncOut.from = healed.from;
        resyncOut.to = healed.to;
      }
      if (result.warning) resyncOut.warning = result.warning;
      const noop = healed.status === "unchanged";
      const payload = { moved: !noop, member: { role: member.role, name: member.name }, command: commandString, resync: resyncOut };
      if (noop) {
        payload.reason =
          `no-op: herdr accepted the command but pane ${member.transport_id} is in the same tab and ` +
          `workspace as before (re-query reports no change)`;
      }
      out(payload);
      break;
    }

    case "spawn-one": {
      // Spec 0009 §6: the one operation `create` cannot reach — a live Team with one role
      // dead or never launched. Extracted, not forked, from `createSpawn`'s launch path.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!SPAWN_ONE_FLAGS.has(key)) fail(`spawn-one: unrecognized flag --${key} (use --cwd, --dry-run, --allow-global, --team, --orchestrator-pid, --member, --model, or --names-in-use)`);
      }
      out(await spawnOneCore(opts._[0], "spawn-one"));
      break;
    }

    case "spawn-ad-hoc": {
      // Spec 0044 §1.4: the command that was missing. `spawn-one` can only stand up a member the
      // roster already defines, and `add` used to be the only other way to get a member running —
      // which is why an agent asked for a DIVERGENT member reached for the one command that writes
      // the roster. This spawns any member spec, roster-defined or not, matching or diverging, and
      // touches no roster level file under any input (§1.2's anti-requirement).
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!AD_HOC_FLAGS.has(key)) fail(`spawn-ad-hoc: unrecognized flag --${key} (use --role, --model, --effort, --route, --kind, --args, --auto-mode, --on-missing, --team, --cwd, --dry-run, --allow-global, --orchestrator-pid, --names-in-use)`);
      }
      const role = typeof opts.role === "string" ? opts.role : opts._[0];
      // The ad hoc path takes exactly one peer-eligible role and defaults everything else; a
      // request that cannot name one is under-specified and belongs on the skill-driven path.
      const formalPath = "Ask the user which role they want, or for a whole team use Skill ah:agent-team (Create).";
      const adHocRoles = chainRoles(registry());
      if (!role) fail(`spawn-ad-hoc: under-specified — no role named (spawn-ad-hoc <role>, one of ${adHocRoles.join(", ")}). ${formalPath}`);
      if (!adHocRoles.includes(role)) {
        fail(`spawn-ad-hoc: under-specified — ${JSON.stringify(role)} is not a role spawn-ad-hoc can stand up; it spawns exactly one of ${adHocRoles.join(", ")}. ${formalPath}`);
      }
      const adHoc = memberFromFlags(role, "spawn-ad-hoc");
      // §1.4 point 1: the same validation rules, unrelaxed. An ad hoc member has no roster block
      // to inherit from, so its own route IS the effective route — defaulted to "peer", the same
      // superset `add`'s auto-init uses, when the caller does not say.
      adHoc.route = adHoc.route || AUTO_INIT_ROUTE;
      if (adHoc.onMissing !== undefined && adHoc.route === "subagent") {
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      const adHocErrors = validateMember(adHoc, registry());
      if (adHocErrors.length) fail(adHocErrors.join("; "));
      if (!routeHasPane(adHoc.route)) {
        fail(`spawn-ad-hoc: route ${JSON.stringify(adHoc.route)} has no session to spawn — a subagent-routed member is dispatched on demand by the Agent tool, so there is nothing to launch`);
      }
      const dir = hierarchyDir(cwd);
      adHocForNameCheck = adHoc;
      resolveWritableTeamScope(dir); // the name below is derived against the team this will write to
      if (!readTeam(dir, teamFile)) checkNewTeamName(dir);
      // §1.4 point 5: the name is derived with the TEAM's prefix, against the members that team
      // already holds, so a second member of the same role gets the next ordinal instead of the
      // first one's name. Derived, then checked — a collision refuses rather than overwriting a
      // row that may name a live agent.
      const existingTeam = readTeam(dir, teamFile);
      const sameRole = existingTeam && Array.isArray(existingTeam.members) ? existingTeam.members.filter((m) => m && m.role === role) : [];
      adHoc.name = namedMembers([...sameRole.map((m) => ({ role: m.role })), adHoc]).at(-1).name;
      if (teamMemberNameSet(dir, teamFile).has(adHoc.name)) {
        fail(`spawn-ad-hoc: team ${teamPath(dir, teamFile)} already has a member named ${adHoc.name} — refusing to overwrite its record. Dismiss it first, or spawn into a different --team`);
      }
      Object.assign(adHoc, renameInUse([adHoc], repoBasename, existingTeam ? existingTeam.members : [])[0]);
      requireHerdrName(adHoc, "spawn-ad-hoc");
      out(await spawnOneCore(role, "spawn-ad-hoc", adHoc));
      break;
    }

    case "adopt": {
      // Spec 0018 §5: recovery for a team whose owner pid is null or dead (e.g. hit by the
      // pre-fix null-pid bug) — re-stamps orchestrator.pid without touching members/team_id.
      // Not a hijack primitive: refuses whenever the recorded owner is alive and different.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!ADOPT_FLAGS.has(key)) fail(`adopt: unrecognized flag --${key} (use --orchestrator-pid, --team, or --cwd)`);
      }
      const suppliedPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : NaN;
      if (!Number.isInteger(suppliedPid)) fail("adopt needs --orchestrator-pid <pid>");
      if (!pidAlive(suppliedPid)) fail(`adopt: --orchestrator-pid ${suppliedPid} is not a live process`);
      const dir = hierarchyDir(cwd);
      const adoptTarget = teamFileState(dir, teamFile);
      if (adoptTarget.state === "unusable") {
        fail(`adopt: the team file ${adoptTarget.path} exists but does not read as a team record, so there is nothing to adopt and it was not rewritten. Repair or remove that file`);
      }
      const team = adoptTarget.team;
      if (!team) fail("adopt: no team file at this scope to adopt");
      const currentPid = team.orchestrator && team.orchestrator.pid;
      if (currentPid != null && pidAlive(currentPid) && currentPid !== suppliedPid) {
        fail(`adopt: team is owned by live pid ${currentPid} — refusing to hijack a live team (no --force)`);
      }
      team.orchestrator = { ...(team.orchestrator || {}), pid: suppliedPid };
      writeTeam(dir, team, teamFile);
      out({ adopted: true, team_id: team.team_id, orchestrator: team.orchestrator });
      break;
    }

    case "teams": {
      // Spec 0011 §5.4: read-only inventory of every team file in this hierarchy dir — otherwise a
      // stale or a sibling orchestrator's team is invisible. Never writes.
      const dir = hierarchyDir(cwd);
      const myPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
      const rows = allTeamRows(dir, myPid);
      // Spec 0036 §3.6 (F4 fix): a misplaced row is attributed to a specific member ONLY when its
      // own `team` matches this team's identity AND its role names exactly one peer member of
      // THIS team — role alone is not unique across DIFFERENT teams, and §3.5's action on a wrong
      // match is destructive (dismiss+respawn of a healthy peer). A row with no `team` (pre-0036),
      // or a role shared by >1 member of the same team, is never attributed — counted in
      // `misplaced_unattributed` instead: under-reporting is recoverable, mis-reporting is not.
      // Filtered to live rows (status "up" and a live pid — same convention upRecordFor uses) —
      // an unclean exit (crash, killed pane, no SessionEnd) otherwise leaves misplaced:true as the
      // latest row forever, nagging about a peer that no longer exists.
      const liveUp = latestRoster(dir).filter((r) => r.status === "up" && pidAlive(r.pid));
      const liveMisplaced = liveUp.filter((r) => r.misplaced);
      for (const row of rows) {
        const t = readTeam(dir, row.name);
        const members = t && Array.isArray(t.members) ? t.members : [];
        const flagged = [];
        let unattributed = 0;
        // Spec 0044 §1.6, channel (b): attribute at READ time. The orchestrator wrote this peer's
        // pane into a member row, and by now that write has landed — which it had NOT when the
        // peer's own SessionStart wrote its row, so a peer launched into a fresh team carries no
        // `team` and no `expected_root` of its own and the recorded-flag pass below can never see
        // it. Matching pane against `transport_id` names the member exactly, and the comparison
        // against this team's own `expected_root` is redone here rather than trusted from the row.
        // Safe-refuse is unchanged: `resolveTeamByPane` returns nothing rather than breaking a
        // tie, so an ambiguous pane falls through to the fallback and is never guessed at.
        const byPaneSeen = new Set();
        for (const r of liveUp) {
          const byPane = r.pane_id ? resolveTeamByPane(dir, r.pane_id) : null;
          if (!byPane || byPane.teamName !== row.name) continue;
          byPaneSeen.add(r);
          const root = t && t.expected_root;
          if (root && realCwd(r.cwd) !== root) flagged.push({ role: r.role, name: byPane.member.name, observed_cwd: r.cwd });
        }
        for (const r of liveMisplaced) {
          if (byPaneSeen.has(r)) continue;
          // A pre-0036 row (no `team` at all) falls into the default team's bucket — the only
          // shape that existed before named teams — but is NEVER flagged, only counted: T16.
          const hasExplicitTeam = Object.prototype.hasOwnProperty.call(r, "team");
          const rowTeam = hasExplicitTeam ? r.team : null;
          if (rowTeam !== row.name) continue;
          const roleMembers = members.filter((m) => m.role === r.role && routeHasPane(m.route));
          if (hasExplicitTeam && roleMembers.length === 1) flagged.push({ role: r.role, name: roleMembers[0].name, observed_cwd: r.cwd });
          else unattributed++;
        }
        row.misplaced_members = flagged;
        row.misplaced_unattributed = unattributed;
        row.untracked_live = untrackedLive(dir, row.name, new Set(members.map((m) => m.name).filter(Boolean)));
        if (row.orphaned) Object.assign(row, orphanDependents(dir, row.name, row.untracked_live));
      }
      // Spec 0046 §2.5: a briefed peer's row carries its team.json member NAME, so the top-level
      // list must exclude every tracked name in the whole hierarchy dir, not just one team's.
      out({ teams: rows, untracked_live: untrackedLive(dir, NO_TEAM_SCOPE, trackedNames(dir, rows)), sources: sourcesField(dir, NO_TEAM_SCOPE, null) });
      break;
    }

    case "checkin": {
      // Spec 0036 §3.3: the missing re-registration primitive — SessionStart fires once, at
      // launch, so nothing else re-appends to peers.jsonl mid-session. Re-runs §3.2's comparison
      // and appends a fresh row via the same writer sessionstart.mjs:98 uses.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!CHECKIN_FLAGS.has(key)) fail(`checkin: unrecognized flag --${key} (use --team, --cwd, or --orchestrator-pid)`);
      }
      const dir = hierarchyDir(cwd);
      // roster.mjs runs as a transient Bash-tool subprocess, so process.ppid here is that shell,
      // not the session pid the hooks recorded. A record written under the shell's pid is dead the
      // moment the command returns, and the next SessionStart sweeps the team as stale.
      const myPid = ownOrchestratorPid();
      if (!Number.isInteger(myPid)) {
        fail("checkin: cannot resolve this session's pid — CLAUDE_PID is unset; pass --orchestrator-pid <pid>");
      }
      const existing = latestRoster(dir).find((r) => r.pid === myPid);
      if (!existing) fail(`checkin: no existing roster record for pid ${myPid} — SessionStart must run before checkin`);
      // Spec 0036 §3.2/§3.3 (F4/F6): the same shared resolver sessionstart.mjs uses — an explicit
      // --team is a direct lookup (unchanged from before); omitted, it now scans for the one team
      // whose members contain exactly one of this role, instead of silently defaulting.
      // Spec 0044 §1.6: the pane this session sits in is authoritative — the orchestrator wrote it
      // into the member row — so ask that before falling back to the role scan, which under §1.1's
      // concurrent teams is ambiguous far more often than it used to be.
      const resolved = attributeSessionTeam(dir, existing.role, {
        explicitTeam: teamArg,
        paneId: sessionPaneId(existing),
        homes: [dir, mainHierarchyDir(cwd)],
      });
      // G8: an EXPLICIT --team that resolves to nothing is a typo, not a legitimate absence —
      // 0032 §3.4b's same precedent (add --team X refuses a nonexistent container) rather than
      // silently reporting misplaced:false forever. An omitted --team still skips silently
      // (§3.2 point 3), unaffected.
      if (teamArg && !resolved) fail(`checkin: no such team "${teamArg}"`);
      const team = resolved && resolved.team;
      const expectedRoot = (team && team.expected_root) || null;
      const observed = realCwd(cwd);
      const misplaced = Boolean(expectedRoot) && observed !== expectedRoot;
      const rec = {
        status: "up",
        role: existing.role,
        session_id: existing.session_id || null,
        pid: myPid,
        ppid: process.ppid,
        cwd: observed,
        pane_id: process.env.HERDR_PANE_ID || existing.pane_id || null,
        tab_id: process.env.HERDR_TAB_ID || existing.tab_id || null,
        workspace_id: process.env.HERDR_WORKSPACE_ID || existing.workspace_id || null,
      };
      // §3.2/§3.3: gains `team` when a team resolved — never `name` (see sessionstart.mjs's
      // identical comment; rosterKey/posttooluse-roster.mjs partitioning risk).
      if (resolved) rec.team = resolved.teamName;
      // Spec 0036 §3.1: absent expected_root means no expectation recorded — never write
      // misplaced/expected_root fields in that case, so an old team is never read as a mismatch.
      if (expectedRoot) {
        rec.expected_root = expectedRoot;
        rec.misplaced = misplaced;
      }
      appendRosterRecord(dir, rec);
      // `team` only when one resolved: `create --commit` refuses a member whose check-in names a
      // team other than the one being committed, and an absent key is what "not attributed" means.
      out({ checked_in: true, cwd: observed, expected_root: expectedRoot, misplaced, ...(resolved ? { team: resolved.teamName } : {}) });
      if (misplaced) process.exitCode = 1;
      break;
    }

    case "whoami": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!WHOAMI_FLAGS.has(key)) fail(`whoami: unrecognized flag --${key} (use --team or --cwd)`);
      }
      const dir = hierarchyDir(cwd);
      const myPid = ownOrchestratorPid();
      const myRow = Number.isInteger(myPid) ? latestRoster(dir).find((r) => r.pid === myPid) : null;
      const paneId = sessionPaneId(myRow);
      // Observed, not verified: the last obligation row any hook filed for this session. A plain
      // cross-session message files none, so null here is the ordinary case, not a fault.
      const mySessionId = process.env.CLAUDE_CODE_SESSION_ID || (myRow && myRow.session_id) || null;
      const briefRow = lastBriefRow(mySessionId);
      const last_observed_brief = briefRow ? { from: briefRow.from ?? null, from_name: briefRow.from_name || null, reply_to: briefRow.reply_to ?? null, ts: briefRow.ts ?? null } : null;
      // `answered_by` names the step that placed this session: the team file it was launched into
      // (`env`), or the member row holding its pane (`pane`). A rejected AH_TEAM_FILE is never
      // followed; it is reported beside the real outcome, so a bad launch is diagnosable without
      // hiding what the pane lookup found.
      const env = teamArg ? null : envTeamFile([dir, mainHierarchyDir(cwd)]);
      const envInvalid = env && env.invalid ? { env_team_invalid: { value: env.value, kind: env.kind, why: env.invalid } } : {};
      const empty = (reason) => ({ member: null, team: null, team_file: null, orchestrator: null, last_observed_brief, reason, answered_by: null, ...envInvalid });
      const describe = (home, teamName, team, member, answeredBy) => {
        const orch = team && team.orchestrator && typeof team.orchestrator === "object" ? team.orchestrator : null;
        const pid = orch && Number.isInteger(orch.pid) ? orch.pid : null;
        const live = pid == null ? null : pidAlive(pid);
        // Harness-owned path: Claude Code, not this plugin, creates one socket per session pid here
        // and may move it. Best-effort only, so the address is offered only while the file exists.
        // This session's own socket sits in the same directory, so its location is followed when
        // the harness exports it.
        const ownSocket = process.env.CLAUDE_CODE_MESSAGING_SOCKET;
        const socket = pid == null ? null : join(ownSocket ? dirname(ownSocket) : "/tmp/cc-socks", `${pid}.sock`);
        return {
          member: member ? { name: member.name ?? null, role: member.role ?? null, route: member.route ?? null } : null,
          team: teamName,
          team_file: teamPath(home, teamName),
          orchestrator: orch ? { pid, session_id: orch.session_id ?? null, live, send_to: live && existsSync(socket) ? `uds:${socket}` : null } : null,
          last_observed_brief,
          reason: null,
          answered_by: answeredBy,
          ...envInvalid,
        };
      };
      if (env && !env.invalid) {
        const team = readTeam(env.home, env.teamName);
        const member = paneId && team && Array.isArray(team.members) ? team.members.find((m) => m && m.transport_id === paneId) || null : null;
        // The launch path alone names the team, whether or not its file exists: a member starts
        // before `create --commit` writes it, and keeps running after reap, disband or untrack
        // removes it. With no file there is no record, which is all that changes.
        out({ ...describe(env.home, env.teamName, team, member, "env"), ...(team ? {} : { reason: "no-team" }) });
        break;
      }
      if (!paneId) {
        out(empty("no-pane-id"));
        break;
      }
      // A peer running in a linked worktree has its own hierarchy dir, but its Team was written
      // by an orchestrator in the main checkout — so that dir is searched too.
      const records = [dir, mainHierarchyDir(cwd)]
        .filter(Boolean)
        .flatMap((home) => (teamArg ? [teamArg] : [null, ...listTeamNames(home)]).map((teamName) => ({ home, teamName, team: readTeam(home, teamName) })))
        .filter((r) => r.team);
      if (records.length === 0) {
        out(empty("no-team"));
        break;
      }
      const matches = records.flatMap((r) => (Array.isArray(r.team.members) ? r.team.members : []).filter((m) => m && m.transport_id === paneId).map((member) => ({ ...r, member })));
      if (matches.length === 0) {
        out(empty("not-a-member"));
        break;
      }
      if (matches.length > 1) {
        out({ ...empty("ambiguous"), candidates: matches.map((m) => ({ team: m.teamName, name: m.member.name ?? null })) });
        break;
      }
      const { home, teamName, team, member } = matches[0];
      out(describe(home, teamName, team, member, "pane"));
      break;
    }

    case "reap": {
      // Spec 0033 §3.2: explicit verb, plan-by-default like `create`/`disband`. Bare form lists
      // orphans and deletes nothing; --commit removes them. Any other flag fails loudly rather
      // than degrading to the destructive path (mirrors disband's guard, §3.2).
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!REAP_FLAGS.has(key)) fail(`reap: unrecognized flag --${key} (use --commit)`);
      }
      const dir = hierarchyDir(cwd);
      const orphans = allTeamRows(dir, null).filter((t) => t.orphaned);
      // Spec 0046 §2.5: reported, never acted on — reap's contract stays orchestrator-dead teams only.
      const untracked_live = untrackedLive(dir, NO_TEAM_SCOPE, trackedNames(dir, allTeamRows(dir, null)));
      for (const t of orphans) Object.assign(t, orphanDependents(dir, t.name));
      if (opts.commit === true) {
        // An orphan that live sessions still depend on is kept: clearing it would forget the
        // records of live sessions, and a later spawn-one could launch their duplicates.
        const kept = orphans.filter((t) => t.live_members || t.attributed_live);
        const reaped = orphans.filter((t) => !kept.includes(t));
        for (const t of reaped) clearTeam(dir, t.name);
        const keptRows = kept.map((t) => ({
          team: t.name,
          ...(t.live_members ? { live_members: t.live_members } : {}),
          ...(t.attributed_live ? { attributed_live: t.attributed_live } : {}),
          next: t.live_members ? adoptCommand(t.name) : null,
          why: t.live_members
            ? "its records are live sessions"
            : `live sessions claim this team (through AH_TEAM_FILE or a \`${t.name}-\` Herdr name) but match no record. Adopting would relaunch its dead records beside them. Run reap again after those sessions exit.`,
        }));
        out({ committed: true, reaped, ...(keptRows.length ? { kept: keptRows } : {}), untracked_live });
      } else {
        out({ committed: false, orphans, untracked_live });
      }
      break;
    }

    case "history": {
      // Spec 0015 §7.1: read-only inventory of stored roster configs, for `create --from`.
      const dir = hierarchyDir(cwd);
      const h = readHistory(dir);
      const teams = h.teams.map((e) => ({
        id: e.id,
        label: e.label,
        alias: e.alias,
        active: historyEntryIsActive(dir, e),
        last_used: e.last_used,
        created_at: e.created_at,
        roles: [...new Set((e.members || []).map((m) => m.role))],
        member_count: Array.isArray(e.members) ? e.members.length : 0,
        roster_level: e.roster_level,
        transport: e.transport,
      }));
      out({ teams });
      break;
    }

    case "role": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!ROLE_FLAGS.has(key)) fail(`role: unrecognized flag --${key} (use --class, --agent, --label, --description, --routes, --model, --dispatch, --level, --scaffold, --dry-run, --json, --team, --cwd)`);
      }
      const sub = opts._[0];
      if (sub === "list") roleList();
      else if (sub === "set") out(roleSet(opts._[1]));
      else if (sub === "remove") out(roleRemove(opts._[1]));
      else fail("usage: roster.mjs role list [--json] | role set <name> [--class C] [--agent A] [--label L] [--description D] [--routes R] [--model M] [--dispatch peer|model] [--level L] [--scaffold repo|user] [--dry-run] | role remove <name> [--level L]  (all with --cwd <abs cwd>)");
      break;
    }

    case "doctor": {
      const report = doctorReport(cwd);
      out(report);
      if (opts.check === true && report.red.length) process.exit(1);
      break;
    }

    default:
      fail(`usage: roster.mjs show|init|add|edit|remove|create|next-split|layout-splits|disband|resync|move|spawn-one|spawn-ad-hoc|adopt|untrack|teams|reap|history|checkin|whoami|doctor [--commit] [--level global|repo|repo-user] [--team <name>] [--cwd <path>]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
