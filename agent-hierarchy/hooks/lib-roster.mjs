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

import { accessSync, constants, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { delimiter, dirname, join } from "node:path";

import { isValidTeamAlias, KIND_DEFAULT, KIND_RE, resolveKind, ROLES, routeHasPane, suggestTeamAlias, VALID_MODELS_BY_ROLE } from "./lib-config.mjs";

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

/** `claude --permission-mode <mode>` values (verified via `claude --help`, NEEDS-EVIDENCE #2). */
export const AUTO_MODE_VALUES = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"];

/** What the peer-fallback gate does when this member has no live instance (spec 0021). */
export const ON_MISSING_VALUES = ["auto", "prompt", "never"];
export const ON_MISSING_DEFAULT = "prompt";

/** `team.json` for the default team, or `teams/<team>.json` for a named one (spec 0011 §3). */
export const teamPath = (dir, team = null) => (team ? join(dir, "teams", `${team}.json`) : join(dir, "team.json"));

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
export function kindFieldErrors(m) {
  const errors = [];
  if (!m || typeof m !== "object") return errors;

  if (m.kind !== undefined && m.kind !== null && (typeof m.kind !== "string" || !KIND_RE.test(m.kind))) {
    errors.push(`kind must be a non-empty lowercase string matching ${KIND_RE.source}, got ${JSON.stringify(m.kind)}`);
    return errors; // an unusable kind makes every rule below meaningless
  }
  const kind = resolveKind(m);
  const nonClaude = kind !== KIND_DEFAULT;

  if (nonClaude) {
    for (const [key, label] of [["model", "model"], ["effort", "effort"], ["autoMode", "auto-mode"]]) {
      if (m[key] !== undefined && m[key] !== null) {
        errors.push(`${label} is a Claude Code CLI flag and has no meaning for kind ${JSON.stringify(kind)} — remove it (got ${JSON.stringify(m[key])})`);
      }
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
  return errors;
}

/** Validation errors for one roster member object; empty array = valid. */
export function validateMember(m) {
  const errors = [];
  if (!m || typeof m !== "object") return ["member must be an object"];
  if (!ROLES.includes(m.role)) errors.push(`role must be one of ${ROLES.join(", ")}, got ${JSON.stringify(m.role)}`);
  const validModels = VALID_MODELS_BY_ROLE[m.role] || [];
  if (m.model !== undefined && m.model !== null && !validModels.includes(m.model)) {
    errors.push(`model ${JSON.stringify(m.model)} is not valid for role ${JSON.stringify(m.role)} (allowed: ${validModels.join(", ")})`);
  }
  if (m.effort !== undefined && m.effort !== null && !EFFORT_VALUES.includes(m.effort)) {
    errors.push(`effort must be one of ${EFFORT_VALUES.join(", ")}, got ${JSON.stringify(m.effort)}`);
  }
  if (m.route !== undefined && m.route !== null && !ROSTER_ROUTE_VALUES.includes(m.route)) {
    errors.push(`route must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(m.route)}`);
  }
  if (m.autoMode !== undefined && m.autoMode !== null && !AUTO_MODE_VALUES.includes(m.autoMode)) {
    errors.push(`auto-mode must be one of ${AUTO_MODE_VALUES.join(", ")}, got ${JSON.stringify(m.autoMode)}`);
  }
  if (m.onMissing !== undefined && m.onMissing !== null && !ON_MISSING_VALUES.includes(m.onMissing)) {
    errors.push(`on-missing must be one of ${ON_MISSING_VALUES.join(", ")}, got ${JSON.stringify(m.onMissing)}`);
  }
  if (m.name !== undefined) errors.push('member must not carry a stored "name" — it is derived at resolve time (spec §3.4)');
  for (const e of kindFieldErrors(m)) errors.push(e);
  return errors;
}

/**
 * Validation errors for one TEAM member object (`team.json`'s `members[]`, spec 0025 §3); empty
 * array = valid. Deliberately NOT `validateMember` — that one rejects any stored `name`, which is
 * correct for roster-config members (derived at resolve time) but wrong here: the spawn path
 * writes team members WITH a `name` (roster.mjs:768, roster.mjs:1620).
 */
export function validateTeamMember(m) {
  if (!m || typeof m !== "object" || Array.isArray(m)) return [`member must be an object, got ${JSON.stringify(m)}`];
  const errors = [];
  if (!ROLES.includes(m.role)) errors.push(`role must be one of ${ROLES.join(", ")}, got ${JSON.stringify(m.role)}`);
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
  for (const e of kindFieldErrors(m)) errors.push(e);
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
export function validateRosterBlock(roster) {
  if (!roster || typeof roster !== "object" || Array.isArray(roster)) return ["roster must be an object"];
  const errors = [];
  if (!ROSTER_ROUTE_VALUES.includes(roster.route)) {
    errors.push(`roster.route is required and must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(roster.route)}`);
  }
  if (roster.layout !== undefined && roster.layout !== null && !ROSTER_LAYOUT_VALUES.includes(roster.layout)) {
    errors.push(`roster.layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(roster.layout)}`);
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
      for (const e of validateMember({ ...m, route: (m && m.route) || roster.route })) errors.push(`member ${i}: ${e}`);
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
    return data && typeof data === "object" && !Array.isArray(data) ? data : null;
  } catch {
    return null;
  }
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
  if (readTeam(dir, null)) return { team: null, defaulted: true };
  // The prefix becomes a path segment, so it has to clear the same validator an explicit `--team`
  // clears — a repo basename is arbitrary text and `teams/<it>.json` must not be able to escape
  // the directory. Spec 0044 [9.1]: a prefix that cannot name a file must not fall back to the
  // unscoped path, which would silently reinstate the shared default across a whole class of
  // repos. `unnamable` says so; the CLI refuses on it at the point a team would be CREATED, not
  // here — refusing during scope resolution would also take out `alias --set`, the remedy.
  if (!isValidTeamAlias(prefix)) return { team: null, defaulted: true, unnamable: prefix, suggested: suggestTeamAlias(prefix) };
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
export function resolveTeamByPane(dir, paneId) {
  if (!paneId) return null;
  let match = null;
  for (const teamName of [null, ...listTeamNames(dir)]) {
    const t = readTeam(dir, teamName);
    const rows = t && Array.isArray(t.members) ? t.members.filter((m) => m && m.transport_id === paneId) : [];
    if (!rows.length) continue;
    if (match || rows.length > 1) return null;
    match = { teamName, team: t, member: rows[0] };
  }
  return match;
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
export function attributeSessionTeam(dir, role, { explicitTeam = null, paneId = null } = {}) {
  if (explicitTeam) return resolveSessionTeam(dir, role, explicitTeam);
  return resolveTeamByPane(dir, paneId) || resolveSessionTeam(dir, role);
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

/** Same predicate sessionstart.mjs's stale-team sweep uses. */
export function teamIsLive(t) {
  if (!t) return false;
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
