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

import { ROLES, VALID_MODELS_BY_ROLE } from "./lib-config.mjs";

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

/** A roster member's route: "peer" (SendMessage to a live session) or "subagent" (spawned in-process). */
export const ROSTER_ROUTE_VALUES = ["peer", "subagent"];

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
  if (m.name === "") {
    errors.push(`name must not be an empty string`);
  } else if (m.route === "peer" && (typeof m.name !== "string" || !m.name)) {
    errors.push(`name is required and must be a non-empty string when route is "peer", got ${JSON.stringify(m.name)}`);
  } else if (m.route !== "peer" && m.name !== undefined && m.name !== null && typeof m.name !== "string") {
    errors.push(`name must be a non-empty string or null, got ${JSON.stringify(m.name)}`);
  }
  if (!ROSTER_ROUTE_VALUES.includes(m.route)) errors.push(`route must be one of ${ROSTER_ROUTE_VALUES.join(", ")}, got ${JSON.stringify(m.route)}`);
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
    errors.push(`roster.route is required and must be "peer" or "subagent", got ${JSON.stringify(roster.route)}`);
  }
  if (roster.layout !== undefined && roster.layout !== null && !ROSTER_LAYOUT_VALUES.includes(roster.layout)) {
    errors.push(`roster.layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(roster.layout)}`);
  }
  if (!Array.isArray(roster.members)) {
    errors.push("roster.members must be an array");
  } else {
    roster.members.forEach((m, i) => {
      if (m && m.role === "orchestrator") {
        errors.push(`member ${i}: role "orchestrator" is not a roster member — the Orchestrator is whatever session runs /agent-roster create`);
        return;
      }
      for (const e of validateMember(m)) errors.push(`member ${i}: ${e}`);
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

/** Peer-routed Team members for a role (subagent-routed members are recorded but are never dispatch targets by name). */
export function teamMembersForRole(dir, role, team = null) {
  const t = readTeam(dir, team);
  if (!t || !Array.isArray(t.members)) return [];
  return t.members.filter((m) => m.role === role && m.route === "peer");
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
 */
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
