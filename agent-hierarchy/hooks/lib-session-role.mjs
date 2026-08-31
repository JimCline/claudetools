#!/usr/bin/env node
/**
 * agent-hierarchy — session-id -> hierarchy-role persisted map (spec 0028 §3.3).
 *
 * Written by sessionstart.mjs when a top-level `claude --agent <role>` session
 * starts (the same role it already computes at that point); read by
 * `resolveHierarchyRole` (lib-config.mjs) as the FALLBACK half of role
 * attribution.
 *
 * NON-ENFORCING (spec 0028 §3.7): a subagent shares its parent's session_id,
 * so this map answers "what role is this session", not "what role is this
 * caller" — a gate must never act on the value this file returns, only on
 * `resolveHierarchyRole`'s `direct` flag. Logging and the §5 liveness check
 * (which legitimately keys on a session) are the only sanctioned uses.
 *
 * Same append-and-cap discipline as lib-gate.mjs: one JSON file keyed by
 * `session_id`, oldest entries pruned past MAX_SESSIONS.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import { normalizeSessionId } from "./lib-gate.mjs";

export { normalizeSessionId };

export const SESSION_ROLE_VERSION = 1;

/** Cap on retained sessions. Entries are pruned oldest-first on write. */
export const MAX_SESSIONS = 50;

export function sessionRolePath() {
  return join(homedir(), ".claude", "agent-hierarchy.session-roles.json");
}

function readState() {
  const path = sessionRolePath();
  if (!existsSync(path)) return { version: SESSION_ROLE_VERSION, sessions: {} };
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { version: SESSION_ROLE_VERSION, sessions: {} };
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { version: SESSION_ROLE_VERSION, sessions: {} };
  if (Number.isInteger(data.version) && data.version > SESSION_ROLE_VERSION) return { version: SESSION_ROLE_VERSION, sessions: {} };
  const sessions = data.sessions && typeof data.sessions === "object" && !Array.isArray(data.sessions) ? data.sessions : {};
  return { version: SESSION_ROLE_VERSION, sessions };
}

function writeState(state) {
  const path = sessionRolePath();
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

/** Drop the oldest entries once the file exceeds MAX_SESSIONS. */
function prune(sessions) {
  const keys = Object.keys(sessions);
  if (keys.length <= MAX_SESSIONS) return sessions;
  const ordered = keys.sort((a, b) => String(sessions[a].at || "").localeCompare(String(sessions[b].at || "")));
  const kept = {};
  for (const key of ordered.slice(keys.length - MAX_SESSIONS)) kept[key] = sessions[key];
  return kept;
}

/** Record what SessionStart computed for a top-level `--agent <role>` session. */
export function writeSessionRole(sessionId, role) {
  const key = normalizeSessionId(sessionId);
  const state = readState();
  state.sessions[key] = { role, at: new Date().toISOString() };
  state.sessions = prune(state.sessions);
  writeState(state);
}

/** The persisted role for a session_id, or null. Non-enforcing — see the header comment. */
export function readSessionRole(sessionId) {
  const key = normalizeSessionId(sessionId);
  const entry = readState().sessions[key];
  return entry && typeof entry.role === "string" ? entry.role : null;
}
