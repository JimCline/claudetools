#!/usr/bin/env node
/**
 * agent-hierarchy — peer report-back tracking (Phase 2 of the peer report-back
 * contract).
 *
 * A peer brief opens with the sentinel line
 * `[hierarchy-peer-brief reply-to="..." task="..."]`. When a receiving session
 * gets one (via SendMessage, which arrives wrapped as
 * `<cross-session-message from="..." from-name="...">`), a pending obligation
 * is recorded; it resolves when that session SendMessages a reply to the
 * recorded address, and a Stop hook nudges (at most twice) while it is still
 * owed.
 *
 * State is `~/.claude/agent-hierarchy.peer-pending.jsonl`, append-only, one
 * JSON object per line. Later lines supersede earlier ones for the same
 * (session_id, task, from) key; readers take the last record for each key.
 * HOME-relative so tests can redirect it.
 *
 * The same file also carries arm/disarm TURN MARKERS (Amendment 2,
 * `{"type":"turn","session_id","status":"armed"|"disarmed","ts"}`), which
 * distinguish a peer-delivered turn (enforcement-eligible) from a plain
 * interactive turn (never nudged). Marker records carry `type:"turn"` and are
 * ignored by every obligation reader (`latestByKey`/`pendingFor`); a marker's
 * own "latest" is read separately, per session, via `latestTurnMarker`.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import { isGatedPeerTarget } from "./lib-gate.mjs";
import { parseMsgFilename } from "./lib-hier.mjs";

/** One JSONL record per tracked peer obligation. */
export function peerPendingPath() {
  return join(homedir(), ".claude", "agent-hierarchy.peer-pending.jsonl");
}

/** Loop guard: block a stop at most this many times per (session, task, from) before waiving it. */
export const MAX_NUDGES = 2;

const SENTINEL_RE = /\[hierarchy-peer-brief\s+reply-to="([^"]+)"(?:\s+task="([^"]*)")?[^\]]*\]/;
const WRAPPER_TAG_RE = /<cross-session-message\b[^>]*>/;

/** Strip a trailing " [ref]" disambiguator, the same shape `isGatedPeerTarget` strips off a SendMessage `to`. */
export function stripRef(s) {
  return s.replace(/\s*\[[^\]]*\]\s*$/, "");
}

/**
 * Parse the `[hierarchy-peer-brief reply-to="..." task="..."]` sentinel out of
 * arbitrary text, or null. `reply-to` is normalized by stripping a trailing
 * " [ref]" — a caller may write `reply-to="<name> [ref]"` to redirect to a
 * disambiguated third session (Change 1), but the record must store the bare
 * name so it compares equal to a `to` that a later SendMessage may or may not
 * qualify with a ref (`isGatedPeerTarget` only strips the `to` side).
 */
export function parseSentinel(text) {
  if (typeof text !== "string" || !text) return null;
  const m = text.match(SENTINEL_RE);
  if (!m) return null;
  return { replyTo: stripRef(m[1].trim()), task: m[2] || "" };
}

/** Parse `from`/`from-name` off the enclosing `<cross-session-message ...>` tag, or null. */
export function parseWrapper(text) {
  if (typeof text !== "string" || !text) return null;
  const tagMatch = text.match(WRAPPER_TAG_RE);
  if (!tagMatch) return null;
  const tag = tagMatch[0];
  const from = tag.match(/\bfrom="([^"]+)"/);
  const fromName = tag.match(/\bfrom-name="([^"]+)"/);
  if (!from) return null;
  return { from: from[1], fromName: fromName ? fromName[1] : "" };
}

/** `[hierarchy-msg <path>]` — matched against the first non-blank line, same anchoring discipline as `SENTINEL_RE` below. */
const MSG_TOKEN_LINE_RE = /^\[hierarchy-msg\s+([^\]\s]+)\s*\]/;

/**
 * Extract a pending-record payload from a delivered prompt, or null when the
 * text is not a parseable, ANCHORED peer brief.
 *
 * The sentinel counts only as the first non-blank line immediately following
 * the opening `<cross-session-message ...>` tag — the contract already
 * mandates a brief OPEN with it, so a sentinel found anywhere else in the
 * text (e.g. a report or reply QUOTING a brief) is not a tasking and must
 * record nothing. Matching the sentinel anywhere in the text, rather than
 * anchoring it, was a review-caught spec-defect: a quoted sentinel made the
 * receiving session record a phantom obligation to its own peer. This check
 * is done here rather than in `parseSentinel` — that helper stays a simple,
 * unanchored "does this text contain a sentinel" utility; anchoring is a
 * property of a TASKING, which is what this function decides.
 *
 * Also requires a parseable wrapper `from` — a sentinel with no enclosing
 * envelope is not something a SendMessage delivery produces (E2), so it is
 * treated as unparseable rather than guessed at (fail open: no record,
 * nothing to nudge).
 *
 * Spec 0031 Fix D: a second, equally anchored form also arms — an
 * Orchestrator dispatch carries `[hierarchy-msg <path>]` (not the peer-brief
 * sentinel) as its first non-blank line, where `<path>` ends `--request.md`,
 * `parseMsgFilename` accepts it, and the file exists. r2's gate depended on
 * `pendingFor` being populated on this path and it never was — see spec
 * 0031 §4.1. `armed_by` records which form armed the record so a consumer
 * that must not cede on this path (§4.1a) can tell the two apart; the
 * sentinel path is unchanged in every other respect.
 */
export function extractPendingRecord(text) {
  if (typeof text !== "string" || !text) return null;

  const tagMatch = text.match(WRAPPER_TAG_RE);
  if (!tagMatch) return null;

  const afterTag = text.slice(tagMatch.index + tagMatch[0].length);
  const firstLine = afterTag.split("\n").find((line) => line.trim() !== "");
  if (firstLine === undefined) return null;

  const line = firstLine.trim();
  const wrapper = parseWrapper(text);
  if (!wrapper) return null;

  const sentinelMatch = line.match(SENTINEL_RE);
  if (sentinelMatch && sentinelMatch.index === 0) {
    return {
      from: wrapper.from,
      from_name: wrapper.fromName,
      reply_to: stripRef(sentinelMatch[1].trim()),
      task: sentinelMatch[2] || "",
      armed_by: "sentinel",
    };
  }

  const msgMatch = line.match(MSG_TOKEN_LINE_RE);
  if (msgMatch && msgMatch.index === 0) {
    const path = msgMatch[1];
    if (path.endsWith("--request.md") && existsSync(path)) {
      const meta = parseMsgFilename(path);
      if (meta && meta.type === "request") {
        return {
          from: wrapper.from,
          from_name: wrapper.fromName,
          reply_to: wrapper.from,
          task: meta.slug,
          armed_by: "msg-token",
        };
      }
    }
  }

  return null;
}

/** Read every record. Malformed lines are skipped; an unreadable file reads as empty (fail open). */
export function readPeerRecords() {
  const path = peerPendingPath();
  if (!existsSync(path)) return [];
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  const records = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const rec = JSON.parse(line);
      if (rec && typeof rec === "object") records.push(rec);
    } catch {
      // corrupt line: skip it, do not fail the whole read
    }
  }
  return records;
}

function keyOf(rec) {
  return `${rec.session_id} ${rec.task} ${rec.from}`;
}

/**
 * Collapse to the LAST record per (session_id, task, from) key, in file
 * order. Turn markers (`type:"turn"`) are not obligations and are ignored
 * here — an obligation reader must never see one.
 */
export function latestByKey(records) {
  const byKey = new Map();
  for (const rec of records) {
    if (rec && (rec.type === "turn" || rec.type === "dispatch")) continue;
    byKey.set(keyOf(rec), rec);
  }
  return [...byKey.values()];
}

export function appendPeerRecord(rec) {
  const path = peerPendingPath();
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(rec) + "\n");
}

/** The latest, still-"pending" records for one session. */
export function pendingFor(sessionId) {
  return latestByKey(readPeerRecords()).filter((r) => r.session_id === sessionId && r.status === "pending");
}

/** Append a `type:"turn"` arm/disarm marker for a session (Amendment 2). */
export function appendTurnMarker(sessionId, status) {
  appendPeerRecord({ type: "turn", session_id: sessionId, status, ts: new Date().toISOString() });
}

/**
 * The latest turn marker for a session, or null when none was ever recorded.
 * Unlike obligations, markers are keyed by session_id alone (one arm/disarm
 * state per session, not per obligation) — the last matching record in file
 * order is authoritative.
 */
export function latestTurnMarker(sessionId) {
  const markers = readPeerRecords().filter((r) => r && r.type === "turn" && r.session_id === sessionId);
  return markers.length ? markers[markers.length - 1] : null;
}

/**
 * Spec 0028 §5.3 (r4, finding 3): §5.3 as originally shipped filtered
 * outstanding dispatches by the PEER-PENDING record's `session_id`, which is
 * the RECIPIENT's — that record only exists once the peer's own hook ran, so
 * a peer that died before receiving the brief (the stall most worth
 * catching) was invisible, and two orchestrators in one repo cross-blocked
 * on each other's dispatches. This is a separate, dispatcher-authored record:
 * written by the SENDER's own hook (`posttooluse-peer-resolve.mjs`) the
 * moment it sends a request token, keyed on the SENDER's own `session_id` —
 * independent of whether the recipient ever saw it.
 */
export function appendDispatchRecord(sessionId, requestId, to) {
  appendPeerRecord({ type: "dispatch", session_id: sessionId, request_id: requestId, to, created: new Date().toISOString() });
}

/** This session's own recorded dispatches — never another session's, per the header comment above. */
export function dispatchRecordsFor(sessionId) {
  return readPeerRecords().filter((r) => r && r.type === "dispatch" && r.session_id === sessionId);
}

/**
 * True when a SendMessage `to` target satisfies a pending record: it matches
 * the recorded `from` (the delivery envelope's socket address), the recorded
 * `from_name`, or — for an explicit third-party reply-to — the `reply_to`
 * name itself. All three comparisons strip a trailing " [ref]" exactly like
 * `isGatedPeerTarget` does; that is a no-op for a bare socket address.
 */
export function targetSatisfiesRecord(to, rec) {
  if (isGatedPeerTarget(to, rec.from)) return true;
  if (isGatedPeerTarget(to, rec.from_name)) return true;
  if (rec.reply_to !== "sender" && isGatedPeerTarget(to, rec.reply_to)) return true;
  return false;
}
