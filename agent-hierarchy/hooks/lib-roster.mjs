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
 * directly.
 */

import { accessSync, constants, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";

import { ROLES, VALID_MODELS_BY_ROLE } from "./lib-config.mjs";

/** A roster member's route: "peer" (SendMessage to a live session) or "subagent" (spawned in-process). */
export const ROSTER_ROUTE_VALUES = ["peer", "subagent"];

/** Team-wide herdr pane layout: "auto" (default), "columns", or "grid". See spec 0004 §4. */
export const ROSTER_LAYOUT_VALUES = ["auto", "columns", "grid"];

/** `claude --effort <level>` values (verified via `claude --help`, NEEDS-EVIDENCE #1). */
export const EFFORT_VALUES = ["low", "medium", "high", "xhigh", "max"];

/** `claude --permission-mode <mode>` values (verified via `claude --help`, NEEDS-EVIDENCE #2). */
export const AUTO_MODE_VALUES = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"];

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
  if (m.name !== undefined) errors.push('member must not carry a stored "name" — it is derived at resolve time (spec §3.4)');
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

/** Atomic write: `<path>.tmp` then rename. `team` names which file (default when omitted). */
export function writeTeam(dir, teamData, team = null) {
  const path = teamPath(dir, team);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(teamData, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
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
