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

import { accessSync, constants, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { delimiter, join } from "node:path";

import { ROLES, VALID_MODELS_BY_ROLE } from "./lib-config.mjs";

/** A roster member's route: "peer" (SendMessage to a live session) or "subagent" (spawned in-process). */
export const ROSTER_ROUTE_VALUES = ["peer", "subagent"];

/** Team-wide herdr pane layout: "auto" (default), "columns", or "grid". See spec 0004 §4. */
export const ROSTER_LAYOUT_VALUES = ["auto", "columns", "grid"];

/** `claude --effort <level>` values (verified via `claude --help`, NEEDS-EVIDENCE #1). */
export const EFFORT_VALUES = ["low", "medium", "high", "xhigh", "max"];

/** `claude --permission-mode <mode>` values (verified via `claude --help`, NEEDS-EVIDENCE #2). */
export const AUTO_MODE_VALUES = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"];

export const teamPath = (dir) => join(dir, "team.json");

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

/** The active Team for this hierarchy dir, or null if none/unreadable. */
export function readTeam(dir) {
  const path = teamPath(dir);
  if (!existsSync(path)) return null;
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    return data && typeof data === "object" && !Array.isArray(data) ? data : null;
  } catch {
    return null;
  }
}

/** Atomic write: `team.json.tmp` then rename. */
export function writeTeam(dir, team) {
  mkdirSync(dir, { recursive: true });
  const path = teamPath(dir);
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(team, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

/** Unlink team.json; no-op if absent. */
export function clearTeam(dir) {
  const path = teamPath(dir);
  if (!existsSync(path)) return;
  try {
    unlinkSync(path);
  } catch {
    // already gone / racing another sweep — fine
  }
}

/** The Team member whose derived name matches, or null. */
export function teamMemberByName(dir, name) {
  const team = readTeam(dir);
  if (!team || !Array.isArray(team.members) || !name) return null;
  return team.members.find((m) => m.name === name) || null;
}

/** Peer-routed Team members for a role (subagent-routed members are recorded but are never dispatch targets by name). */
export function teamMembersForRole(dir, role) {
  const team = readTeam(dir);
  if (!team || !Array.isArray(team.members)) return [];
  return team.members.filter((m) => m.role === role && m.route === "peer");
}
