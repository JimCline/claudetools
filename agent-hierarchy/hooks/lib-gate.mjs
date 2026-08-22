#!/usr/bin/env node
/**
 * agent-hierarchy — Ultra-Advisor escalation gate state.
 *
 * The Ultra-Advisor is the most expensive tier in the hierarchy, so the first
 * attempt to escalate in a session needs the user's explicit go-ahead. That
 * answer is recorded here, keyed by the harness `session_id`.
 *
 * State is SESSION-SCOPED ONLY and deliberately not part of
 * `agent-hierarchy.json`: a standing "yes" that outlived the session it was
 * given in would turn a consent gate into a one-time formality. A new session
 * always asks again. Users who want a durable answer set `enabled:false` or
 * change the role's model instead.
 *
 * Written only by `gate.mjs set`, which the Orchestrator runs once per session
 * after asking the user; read by the PreToolUse hook on every dispatch.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const GATE_VERSION = 1;

/**
 * The three answers the user can give.
 *   session — allow every later escalation this session without asking
 *   each    — allow this one; prompt again on each later escalation
 *   off     — block escalation for the rest of this session
 */
export const GATE_CHOICES = ["session", "each", "off"];

export const GATE_CHOICE_LABELS = {
  session: "allowed for the rest of this session",
  each: "ask before each escalation",
  off: "blocked for the rest of this session",
};

/** Subagent types this gate covers. The bare name does not resolve as a dispatch target, but gating it too costs nothing. */
export const GATED_SUBAGENT_TYPES = ["ah:ultra-advisor", "ultra-advisor"];

/** Cap on retained sessions. Entries are pruned oldest-first on write. */
export const MAX_SESSIONS = 50;

/** Key used when the harness payload carries no session_id, so a missing field cannot silently open the gate. */
export const NO_SESSION_KEY = "__nosession__";

export function gatePath() {
  return join(homedir(), ".claude", "agent-hierarchy.gate.json");
}

export function normalizeSessionId(sessionId) {
  return typeof sessionId === "string" && sessionId.trim() ? sessionId.trim() : NO_SESSION_KEY;
}

export function isGatedSubagentType(type) {
  return typeof type === "string" && GATED_SUBAGENT_TYPES.includes(type.trim());
}

/**
 * True when a SendMessage `to` target names the given expected peer session.
 * Strips an optional trailing " [ref]" disambiguator (SendMessage accepts
 * "name" or "name [ref]") before comparing, so both forms match the same peer.
 */
export function isGatedPeerTarget(to, expectedName) {
  if (typeof to !== "string" || !to.trim()) return false;
  if (typeof expectedName !== "string" || !expectedName) return false;
  return to.trim().replace(/\s*\[[^\]]*\]\s*$/, "") === expectedName;
}

/** Read the state file. Any unreadable or malformed state resets to empty rather than throwing. */
export function readGateState() {
  const path = gatePath();
  if (!existsSync(path)) return { version: GATE_VERSION, sessions: {} };
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { version: GATE_VERSION, sessions: {} };
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { version: GATE_VERSION, sessions: {} };
  // A file written by a newer plugin is not ours to interpret; treat it as no decision
  // so the gate asks again rather than acting on a shape it does not understand.
  if (Number.isInteger(data.version) && data.version > GATE_VERSION) return { version: GATE_VERSION, sessions: {} };
  const sessions = data.sessions && typeof data.sessions === "object" && !Array.isArray(data.sessions) ? data.sessions : {};
  return { version: GATE_VERSION, sessions };
}

/** The recorded choice for a session, or null when the user has not been asked yet. */
export function getDecision(sessionId) {
  const key = normalizeSessionId(sessionId);
  const entry = readGateState().sessions[key];
  if (!entry || typeof entry !== "object") return null;
  return GATE_CHOICES.includes(entry.choice) ? entry.choice : null;
}

function writeGateState(state) {
  const path = gatePath();
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

/** Record the user's answer. Throws on an unrecognized choice so a typo cannot land in state. */
export function setDecision(sessionId, choice, cwd) {
  if (!GATE_CHOICES.includes(choice)) {
    throw new Error(`unknown choice ${JSON.stringify(choice)} (expected: ${GATE_CHOICES.join(", ")})`);
  }
  const key = normalizeSessionId(sessionId);
  const state = readGateState();
  state.sessions[key] = { choice, at: new Date().toISOString(), ...(cwd ? { cwd } : {}) };
  state.sessions = prune(state.sessions);
  writeGateState(state);
  return state.sessions[key];
}

/** Forget a session's answer so the next escalation asks again. Returns true if something was removed. */
export function clearDecision(sessionId) {
  const key = normalizeSessionId(sessionId);
  const state = readGateState();
  if (!state.sessions[key]) return false;
  delete state.sessions[key];
  writeGateState(state);
  return true;
}
