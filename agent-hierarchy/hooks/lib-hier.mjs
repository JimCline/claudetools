#!/usr/bin/env node
/**
 * agent-hierarchy — the hierarchy runtime directory: message files, peer
 * roster, one-shot gate records, tier rule.
 *
 * Runtime dir resolution (`hierarchyDir`): `AGENT_HIERARCHY_DIR` env wins;
 * else the enclosing git checkout's `.claude/hierarchy/`; else
 * `~/.claude/hierarchy/<basename(cwd)>/`. The dir is self-gitignored.
 *
 * Message files live at `<dir>/msgs/<id>--<to>--<slug>--<type>.md` with a
 * flat YAML frontmatter and `## [N] key` section anchors; a request and its
 * response share the id, and the response's existence closes the exchange.
 * `peers.jsonl` and `gates.jsonl` are append-only JSONL, latest-per-key on
 * read, exactly like `lib-peer.mjs`.
 *
 * Every reader here fails open: unreadable or malformed state reads as empty.
 */

import { randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

import { hierarchyDir, PEER_ELIGIBLE_ROLES, ROLES, ROLE_LABELS, ROUTE_VALUES, TIER, resolvedPeerTargets, roleFromName, tierOf } from "./lib-config.mjs";
import { readTeam, resolveMemberTeam, teamMemberByName } from "./lib-roster.mjs";

export { hierarchyDir };

export const MSG_ROLES = ["orchestrator", ...ROLES];
export const MSG_TYPES = ["request", "response"];
export const REASONS = ["context", "second-opinion", "parallel"];
export const REQUEST_KEYS = ["tldr", "goal", "context", "constraints", "files", "acceptance", "want_back"];
export const RESPONSE_KEYS = ["tldr", "status", "changes", "evidence", "gaps", "open_questions"];
export const SLUG_RE = /^[a-z0-9-]{1,32}$/;
export const ID_RE = /^\d{8}-\d{6}-[0-9a-z]{4}$/;
export const ROSTER_FRESH_SEC = 1800;
export const SWEEP_DAYS = 7;

/** `[hierarchy-msg <abs path>]` — the in-band pointer to a message file. */
export const MSG_TOKEN_RE = /\[hierarchy-msg\s+([^\]\s]+)\s*\]/;


// ---------------------------------------------------------------- runtime dir

/** mkdir -p the layout and self-gitignore it. Idempotent; returns the dir. */
export function ensureHierarchyDir(cwd) {
  const dir = hierarchyDir(cwd);
  for (const sub of ["msgs", join("msgs", "archive"), "specs"]) mkdirSync(join(dir, sub), { recursive: true });
  const ignore = join(dir, ".gitignore");
  if (!existsSync(ignore)) writeFileSync(ignore, "*\n", "utf8");
  return dir;
}

export const msgsDir = (dir) => join(dir, "msgs");
export const archiveDir = (dir) => join(dir, "msgs", "archive");
export const specsDir = (dir) => join(dir, "specs");
export const peersPath = (dir) => join(dir, "peers.jsonl");
export const gatesPath = (dir) => join(dir, "gates.jsonl");

// ---------------------------------------------------------------- jsonl

export function readJsonl(path) {
  if (!existsSync(path)) return [];
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const rec = JSON.parse(line);
      if (rec && typeof rec === "object") out.push(rec);
    } catch {
      // corrupt line: skip
    }
  }
  return out;
}

export function appendJsonl(path, rec) {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(rec) + "\n");
}

// ---------------------------------------------------------------- ids, time

const pad = (n, w = 2) => String(n).padStart(w, "0");

/** `YYYYMMDD-HHMMSS-<4 base36>` in the writer's local time. */
export function newId(now = new Date()) {
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  let rand = "";
  while (rand.length < 4) rand += randomBytes(4).readUInt32BE(0).toString(36);
  return `${stamp}-${rand.slice(0, 4)}`;
}

/** ISO-8601 with the local UTC offset, e.g. `2026-08-16T14:32:01-04:00`. */
export function localIso(now = new Date()) {
  const off = -now.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  const abs = Math.abs(off);
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

export function fmtAge(sec) {
  if (!Number.isFinite(sec) || sec < 0) return "?";
  if (sec < 60) return `${Math.floor(sec)}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

export function ageSecOf(ts, now = Date.now()) {
  const t = Date.parse(ts);
  return Number.isFinite(t) ? Math.max(0, (now - t) / 1000) : Infinity;
}

// ---------------------------------------------------------------- message files

export function msgFilename({ id, to, slug, type }) {
  return `${id}--${to}--${slug}--${type}.md`;
}

export function parseMsgFilename(name) {
  const m = basename(name).match(/^(\d{8}-\d{6}-[0-9a-z]{4})--([a-z-]+)--([a-z0-9-]{1,32})--(request|response)\.md$/);
  if (!m) return null;
  return { id: m[1], to: m[2], slug: m[3], type: m[4] };
}

/**
 * Flat `key: value` frontmatter between `---` fences. `null` reads as null;
 * everything else is a trimmed string. Returns null when there is no fence.
 */
export function parseFrontmatter(text) {
  if (typeof text !== "string") return null;
  const lines = text.split("\n");
  if (lines[0].trim() !== "---") return null;
  const fields = {};
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "---") return { fields, end: i + 1 };
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!m) continue;
    let value = m[2].replace(/\s+#.*$/, "").trim();
    if (value === "null" || value === "") value = null;
    fields[m[1]] = value;
  }
  return null;
}

/** `[{line, key, text}]` for every `## [N] key` anchor at column 0, 1-based line numbers. */
export function indexAnchors(text) {
  const out = [];
  text.split("\n").forEach((line, i) => {
    const m = line.match(/^## \[(\d+)\] (\S+)/);
    if (m) out.push({ line: i + 1, n: Number(m[1]), key: m[2], text: line });
  });
  return out;
}

export function readMsgFile(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  const fm = parseFrontmatter(text);
  return { path, text, fm: fm ? fm.fields : null, anchors: indexAnchors(text) };
}

function skeletonBody(keys) {
  const lines = ["## [0] tldr"];
  keys.slice(1).forEach((key, i) => lines.push(`- [${i + 1}] ${key}: `));
  keys.slice(1).forEach((key, i) => {
    lines.push("", `## [${i + 1}] ${key}`, "- none");
  });
  return lines.join("\n") + "\n";
}

function frontmatterText(fields) {
  const order = ["id", "type", "to", "from", "slug", "parent", "reason", "to_name", "from_name", "team", "created"];
  const lines = ["---"];
  for (const key of order) lines.push(`${key}: ${fields[key] === null || fields[key] === undefined ? "null" : fields[key]}`);
  lines.push("---", "");
  return lines.join("\n");
}

/** Every `<id>--*--request.md` in msgs/ (not archive), as `{path, meta}`. */
function requestFiles(dir) {
  const d = msgsDir(dir);
  if (!existsSync(d)) return [];
  const out = [];
  for (const name of readdirSync(d)) {
    const meta = parseMsgFilename(name);
    if (meta) out.push({ path: join(d, name), meta });
  }
  return out;
}

export function findByIdAndType(dir, id, type) {
  return requestFiles(dir).find((f) => f.meta.id === id && f.meta.type === type) || null;
}

/**
 * Create a message file. Request: id generated (or `--id` honoured), all
 * anchors + `- none` placeholders. Response: `id` required and must match an
 * existing request; to/from swapped from it; parent copied. Throws with a
 * one-line message on bad args.
 */
export function createMessage(dir, opts) {
  const type = opts.type || "request";
  if (!MSG_TYPES.includes(type)) throw new Error(`type must be request|response, got ${JSON.stringify(type)}`);
  ensureHierarchyDir(opts.cwd);
  const now = new Date();
  let fields;
  if (type === "request") {
    const to = opts.to;
    const from = opts.from;
    const slug = opts.slug;
    if (!MSG_ROLES.includes(to)) throw new Error(`--to must be one of ${MSG_ROLES.join("|")}, got ${JSON.stringify(to)}`);
    if (!MSG_ROLES.includes(from)) throw new Error(`--from must be one of ${MSG_ROLES.join("|")}, got ${JSON.stringify(from)}`);
    if (typeof slug !== "string" || !SLUG_RE.test(slug)) throw new Error(`--slug must match [a-z0-9-]{1,32}, got ${JSON.stringify(slug)}`);
    if (opts.reason !== undefined && opts.reason !== null && !REASONS.includes(opts.reason)) {
      throw new Error(`--reason must be one of ${REASONS.join("|")}, got ${JSON.stringify(opts.reason)}`);
    }
    const id = opts.id || newId(now);
    if (!ID_RE.test(id)) throw new Error(`--id must look like YYYYMMDD-HHMMSS-xxxx, got ${JSON.stringify(id)}`);
    if (findByIdAndType(dir, id, "request")) throw new Error(`request ${id} already exists`);
    fields = {
      id,
      type,
      to,
      from,
      slug,
      parent: opts.parent || null,
      reason: opts.reason || null,
      to_name: opts.toName || null,
      from_name: opts.fromName || null,
      team: opts.team || null,
      created: localIso(now),
    };
  } else {
    if (!opts.id) throw new Error("--id is required for a response");
    const req = findByIdAndType(dir, opts.id, "request");
    if (!req) throw new Error(`no request with id ${opts.id} under ${msgsDir(dir)}`);
    if (findByIdAndType(dir, opts.id, "response")) throw new Error(`response ${opts.id} already exists`);
    const parsed = readMsgFile(req.path);
    const rf = parsed && parsed.fm ? parsed.fm : {};
    fields = {
      id: opts.id,
      type,
      to: opts.to || rf.from || req.meta.to,
      from: opts.from || rf.to || req.meta.to,
      slug: req.meta.slug,
      parent: rf.parent || null,
      reason: null,
      to_name: opts.toName || rf.from_name || null,
      from_name: opts.fromName || rf.to_name || null,
      team: opts.team || rf.team || null,
      created: localIso(now),
    };
  }
  const path = join(msgsDir(dir), msgFilename(fields));
  writeFileSync(path, frontmatterText(fields) + "\n" + skeletonBody(type === "request" ? REQUEST_KEYS : RESPONSE_KEYS), "utf8");
  return { id: fields.id, path, fields };
}

/** Pair requests with responses by id: `[{id, request, response, meta}]`, newest id first. */
export function listExchanges(dir) {
  const byId = new Map();
  for (const f of requestFiles(dir)) {
    const e = byId.get(f.meta.id) || { id: f.meta.id, request: null, response: null };
    e[f.meta.type] = f;
    byId.set(f.meta.id, e);
  }
  return [...byId.values()]
    .filter((e) => e.request)
    .sort((a, b) => (a.id < b.id ? 1 : -1))
    .map((e) => ({ ...e, open: !e.response, to: e.request.meta.to, slug: e.request.meta.slug }));
}

/**
 * Open exchanges, optionally filtered to one team. `team` omitted (not even
 * `null`) returns every open exchange, untagged and tagged alike; passing
 * `team` (a name, or `null` for the default team) keeps only exchanges whose
 * frontmatter `team:` tag matches — an untagged exchange's tag reads as
 * `null` (§7.6 degradation), so it matches the default team. This is what
 * closes the `to_name: null` cross-team fan-out (spec 0011 §7.7): callers
 * that bucket peers by team must filter here BEFORE reading `to_name`.
 */
export function openExchanges(dir, team) {
  const list = listExchanges(dir).filter((e) => e.open);
  if (team === undefined) return list;
  return list.filter((e) => {
    const parsed = readMsgFile(e.request.path);
    const tag = (parsed && parsed.fm && parsed.fm.team) || null;
    return tag === (team || null);
  });
}

/** Frontmatter `created` if parseable, else file mtime, as epoch ms. */
function createdMs(path) {
  const parsed = readMsgFile(path);
  const t = parsed && parsed.fm && parsed.fm.created ? Date.parse(parsed.fm.created) : NaN;
  if (Number.isFinite(t)) return t;
  try {
    return statSync(path).mtimeMs;
  } catch {
    return Date.now();
  }
}

/** Move closed pairs whose response is older than `days` into msgs/archive/. Returns the count of pairs moved. */
export function sweep(dir, days = SWEEP_DAYS, now = Date.now()) {
  const cutoff = now - days * 86400 * 1000;
  let moved = 0;
  for (const e of listExchanges(dir)) {
    if (!e.response) continue;
    if (createdMs(e.response.path) > cutoff) continue;
    mkdirSync(archiveDir(dir), { recursive: true });
    for (const f of [e.request, e.response]) renameSync(f.path, join(archiveDir(dir), basename(f.path)));
    moved++;
  }
  return moved;
}

/** Age of an exchange in seconds, from the request's `created` (or mtime). */
export function exchangeAgeSec(e, now = Date.now()) {
  return Math.max(0, (now - createdMs(e.request.path)) / 1000);
}

/** The first `[hierarchy-msg <path>]` token in text, or null. */
export function extractMsgToken(text) {
  if (typeof text !== "string" || !text) return null;
  const m = text.match(MSG_TOKEN_RE);
  return m ? m[1] : null;
}

function isUnder(path, dir) {
  const rel = resolve(path).slice(resolve(dir).length);
  return resolve(path).startsWith(resolve(dir)) && (rel === "" || rel.startsWith("/"));
}

/**
 * Validate the request pointer a dispatch carries. Returns `{ok:true, path,
 * fm}` or `{ok:false, why}` where `why` is one of the deny reasons in the spec.
 */
export function validateRequestToken(text, dir, expectedTo) {
  const path = extractMsgToken(text);
  if (!path) return { ok: false, why: "missing token" };
  if (!isAbsolute(path) || !existsSync(path)) return { ok: false, why: `path not found (${path})` };
  if (!isUnder(path, msgsDir(dir)) || !path.endsWith("--request.md")) return { ok: false, why: "not a request file" };
  const parsed = readMsgFile(path);
  if (!parsed || !parsed.fm || parsed.fm.type !== "request") return { ok: false, why: "not a request file" };
  if (expectedTo && parsed.fm.to !== expectedTo) {
    return { ok: false, why: `wrong to: (file says ${parsed.fm.to}, dispatch is ${expectedTo})` };
  }
  return { ok: true, path, fm: parsed.fm };
}

/** True when text carries `[hierarchy-msg <path>]` naming an existing `--response.md`, optionally for one id. */
export function hasResponseToken(text, id) {
  const path = extractMsgToken(text);
  if (!path || !path.endsWith("--response.md") || !existsSync(path)) return false;
  if (id) {
    const meta = parseMsgFilename(path);
    return !!meta && meta.id === id;
  }
  return true;
}

// ---------------------------------------------------------------- gates.jsonl

export function readGates(dir) {
  return readJsonl(gatesPath(dir));
}

export function appendGate(dir, rec) {
  appendJsonl(gatesPath(dir), { ...rec, ts: new Date().toISOString() });
}

export function hasGate(dir, pred) {
  return readGates(dir).some(pred);
}

// ---------------------------------------------------------------- routing preference

/** This session's recorded `{type:"route", session_id, value, ts}`, latest if more than one, else null. */
export function sessionRouteRecord(dir, sessionId) {
  if (!sessionId) return null;
  const recs = readGates(dir).filter((r) => r.type === "route" && r.session_id === sessionId && ROUTE_VALUES.includes(r.value));
  return recs.length ? recs[recs.length - 1] : null;
}

export function recordRoute(dir, sessionId, value) {
  appendGate(dir, { type: "route", session_id: sessionId, value });
}

/**
 * The dispatch route in effect: session answer > config `route` key >
 * "peers" default. `{value, source}` where source is
 * "session"|"config"|"default".
 */
export function effectiveRoute(dir, resolved, sessionId) {
  const sess = sessionRouteRecord(dir, sessionId);
  if (sess) return { value: sess.value, source: "session" };
  if (resolved && resolved.route) return { value: resolved.route, source: "config" };
  return { value: "peers", source: "default" };
}

// ---------------------------------------------------------------- roster

/**
 * The role for a peer session name: the active Team's check-in registry
 * first (ADR 0002 — authoritative once a Team exists), then the role whose
 * configured peer targets include `name`, then the role its token implies.
 */
export function roleForPeerName(name, resolved, repoBasename) {
  try {
    const member = teamMemberByName(hierarchyDir(resolved.cwd), name, resolved && resolved.team);
    if (member) return member.role;
  } catch {
    // team lookup is best-effort; fall through to the existing paths
  }
  for (const role of PEER_ELIGIBLE_ROLES) {
    if (resolvedPeerTargets(role, resolved.roles[role], repoBasename).includes(name)) return role;
  }
  return roleFromName(name);
}

/**
 * Mechanism (A) — spec 0011 §4.4.1: "what role is this name", searched across
 * every team by name (`resolveMemberTeam`), not scoped to `resolved.team`.
 * For callers that need the role of an arbitrary name regardless of whether
 * team scope itself resolved correctly — unlike `roleForPeerName`, which
 * answers (B) "who is on my team" and is the wrong mechanism for these.
 */
export function roleForAnyPeerName(dir, name, resolved, repoBasename) {
  try {
    const membership = resolveMemberTeam(dir, name);
    if (membership.found) {
      const member = teamMemberByName(dir, name, membership.team);
      if (member) return member.role;
    }
  } catch {
    // team lookup is best-effort; fall through to the existing paths
  }
  for (const role of PEER_ELIGIBLE_ROLES) {
    if (resolvedPeerTargets(role, resolved.roles[role], repoBasename).includes(name)) return role;
  }
  return roleFromName(name);
}

export function readRoster(dir) {
  return readJsonl(peersPath(dir)).filter((r) => r.type === "peer");
}

export function appendRosterRecord(dir, rec) {
  appendJsonl(peersPath(dir), { type: "peer", ...rec, ts: new Date().toISOString() });
}

function rosterKey(rec) {
  return rec.name || rec.session_id || "";
}

/** Latest record per key (name, else session_id). */
export function latestRoster(dir) {
  const byKey = new Map();
  for (const rec of readRoster(dir)) {
    const key = rosterKey(rec);
    if (key) byKey.set(key, rec);
  }
  return [...byKey.values()];
}

/** The `up` record for a session_id, if its latest state is `up`. */
export function upRecordFor(dir, sessionId) {
  return latestRoster(dir).find((r) => r.session_id === sessionId && r.status === "up") || null;
}

export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === "EPERM";
  }
}

/**
 * Per role, a list of peer instances, live-first then freshest:
 * `{name, live, how, ageSec, busy, openBriefs, unassigned}`. `down` records
 * are not candidates and are dropped. Records are attributed to
 * `resolved.team` (spec 0011 §4.1-§4.3): a nameless record always lands in
 * the returned `unattributed` array (never guessed, never dropped, §4.2),
 * and additionally in its role bucket under a synthesized `role@session`
 * name when the caller is the default team (baseline invariance — a
 * specifically-named team's roster stays isolated from it); a
 * named record's effective team is a fresh name-membership lookup — if the
 * record's stored `team` tag disagrees with that lookup (a stale claim,
 * §7.5) it also lands in `unattributed`; otherwise it's included here only
 * if its effective team matches `resolved.team` (a sibling team's member is
 * silently absent, not flagged).
 */
export function roster(dir, resolved, repoBasename, now = Date.now()) {
  const out = {};
  for (const role of PEER_ELIGIBLE_ROLES) out[role] = [];
  const unattributed = [];
  const team = (resolved && resolved.team) || null;
  const open = openExchanges(dir, team).map((e) => {
    const parsed = readMsgFile(e.request.path);
    return { to: e.to, toName: parsed && parsed.fm ? parsed.fm.to_name : null };
  });
  for (const rec of latestRoster(dir)) {
    if (rec.status === "down") continue;
    const role = rec.role || roleForPeerName(rec.name, resolved, repoBasename);
    if (!role || !out[role]) continue;
    const ageSec = ageSecOf(rec.ts, now);
    let live = false;
    let how = rec.status;
    if (rec.status === "up") {
      live = pidAlive(rec.pid);
      how = "up-pid";
    } else if (rec.status === "seen" || rec.status === "briefed") {
      live = ageSec < ROSTER_FRESH_SEC;
    }
    const base = { role, live, how, ageSec, busy: rec.busy === true, task: rec.task || null };

    if (!rec.name) {
      unattributed.push({ name: null, ...base });
      // Baseline (pre-0011) behaviour: a nameless record still surfaces in
      // its role bucket under a synthesized `role@session` name, but only
      // for the default team — an explicitly-named team's roster stays
      // isolated (spec 0011 §4.2/§11 test 4), while the default team keeps
      // exactly the display every existing no-`--team` caller depends on.
      if (team === null) {
        const name = `${role}@${String(rec.session_id || "").slice(0, 8)}`;
        const mine = open.filter((o) => o.to === role && (o.toName === name || o.toName === null));
        out[role].push({ ...base, name, openBriefs: mine.length, unassigned: mine.filter((o) => o.toName === null).length });
      }
      continue;
    }

    const membership = resolveMemberTeam(hierarchyDir(resolved.cwd), rec.name);
    const tag = rec.team !== undefined ? rec.team : null;
    if (tag !== null && (!membership.found || membership.team !== tag)) {
      unattributed.push({ name: rec.name, ...base });
      continue;
    }
    const recTeam = membership.found ? membership.team : null;
    if (recTeam !== team) {
      // §4.5 row 4 (named-team scope only): a name owned by no team at all is
      // `unattributed`, not silently dropped — distinct from row 3, where the
      // name belongs to another team (`membership.found` true) and is excluded
      // entirely.
      if (team !== null && !membership.found) unattributed.push({ name: rec.name, ...base });
      continue;
    }

    const mine = open.filter((o) => o.to === role && (o.toName === rec.name || o.toName === null));
    out[role].push({
      ...base,
      name: rec.name,
      openBriefs: mine.length,
      unassigned: mine.filter((o) => o.toName === null).length,
    });
  }
  for (const role of Object.keys(out)) {
    out[role].sort((a, b) => Number(b.live) - Number(a.live) || a.ageSec - b.ageSec);
  }
  out.unattributed = unattributed;
  return out;
}

export function describeInstance(inst) {
  const bits = [`${inst.live ? "live" : "stale"} ${inst.how} ${fmtAge(inst.ageSec)} ago`];
  if (inst.busy) bits.push("busy");
  if (inst.openBriefs) bits.push(`${inst.openBriefs} open brief${inst.openBriefs === 1 ? "" : "s"}${inst.unassigned ? ` (${inst.unassigned} unassigned)` : ""}`);
  return `"${inst.name}" ${bits.join(", ")}`;
}

/** `peers:` line for HIERARCHY STATE / msg.mjs roster. */
export function rosterLine(ros) {
  const parts = [];
  for (const role of PEER_ELIGIBLE_ROLES) {
    const list = ros[role] || [];
    if (!list.length) {
      parts.push(`${role}: none`);
      continue;
    }
    parts.push(
      list
        .map((i) => `${role}=${i.name} ${i.live ? "live" : "stale"} ${fmtAge(i.ageSec)} ${i.how}${i.busy ? " busy" : ""}${i.task ? `(${i.task})` : ""}${i.openBriefs ? ` ${i.openBriefs} open` : ""}`)
        .join("; ")
    );
  }
  return parts.join("; ");
}

// ---------------------------------------------------------------- tier rule

export { TIER, tierOf };

/** Session model: hook input `model` → env CLAUDE_MODEL → cached `{type:"model"}` gate record → null. */
export function sessionModel(input, dir) {
  if (input && typeof input.model === "string" && input.model) return input.model;
  if (typeof process.env.CLAUDE_MODEL === "string" && process.env.CLAUDE_MODEL) return process.env.CLAUDE_MODEL;
  const sid = input && input.session_id;
  if (dir && sid) {
    const recs = readGates(dir).filter((r) => r.type === "model" && r.session_id === sid && typeof r.model === "string");
    if (recs.length) return recs[recs.length - 1].model;
  }
  return null;
}

export function cacheSessionModel(dir, sessionId, model) {
  if (sessionId && model) appendGate(dir, { type: "model", session_id: sessionId, model });
}

/** The tier a role runs at given its resolved model; `inherit` takes the session tier. */
export function roleTier(role, resolved, sessionTier) {
  const model = resolved.roles[role] && resolved.roles[role].model;
  if (model === "inherit") return sessionTier;
  return tierOf(model);
}

export function roleModelLabel(role, resolved) {
  const model = resolved.roles[role] && resolved.roles[role].model;
  const t = tierOf(model);
  return `${model}(${t === null ? "?" : t})`;
}

/** The `tier:` line for HIERARCHY STATE. */
export function tierLine(resolved, model) {
  const t = tierOf(model);
  const roles = `architect ${roleModelLabel("architect", resolved)}; ultra-advisor ${roleModelLabel("ultra-advisor", resolved)}`;
  if (model && t !== null) return `tier: you are ${model}(${t}); ${roles}`;
  return `tier: model unknown — see TIER RULE; ${roles}`;
}

// ---------------------------------------------------------------- SessionStart state block

/** The `route:` line for HIERARCHY STATE. */
export function routeLine(route) {
  if (!route) return "route: unknown — see /hierarchy route";
  return `route: ${route.value} (from ${route.source}) — change with /hierarchy route or just say so`;
}

/**
 * The HIERARCHY STATE block appended after the directive on every SessionStart
 * matcher. `sessionId`/`route` may be null (unit callers); the route line
 * degrades to the generic form.
 */
export function buildStateBlock(dir, resolved, repoBasename, model, sessionId = null, route = null, now = Date.now()) {
  const open = openExchanges(dir, (resolved && resolved.team) || null);
  const shown = open.slice(0, 10).map((e) => `${e.id} ${e.to} ${e.slug} ${fmtAge(exchangeAgeSec(e, now))}`);
  const openLine = open.length
    ? `open exchanges: ${open.length} — ${shown.join(", ")}${open.length > 10 ? ` +${open.length - 10} more: msg.mjs list` : ""}`
    : "open exchanges: none";
  const team = readTeam(dir, (resolved && resolved.team) || null);
  let peersLine;
  if (team && Array.isArray(team.members) && team.members.length) {
    const ros = roster(dir, resolved, repoBasename, now);
    const rows = team.members.map((m) => {
      if (m.route !== "peer" || !m.name) return `${m.role}=(subagent)`;
      const live = (ros[m.role] || []).find((i) => i.name === m.name);
      return `${m.role}=${m.name} ${live ? (live.busy ? "busy" : "idle") : "not-seen"}`;
    });
    peersLine = `Team ${team.team_id} (authoritative)${team.partial ? " [partial]" : ""}: ${rows.join("; ")}`;
  } else {
    const ros = roster(dir, resolved, repoBasename, now);
    const anyPeer = PEER_ELIGIBLE_ROLES.some((r) => ros[r].length);
    peersLine = `peers: ${anyPeer ? rosterLine(ros) : "none"}`;
  }
  const eff = route || (sessionId ? effectiveRoute(dir, resolved, sessionId) : null);
  return [`HIERARCHY STATE (${dir}):`, openLine, peersLine, routeLine(eff), tierLine(resolved, model)].join("\n");
}

export { ROLES, ROLE_LABELS };
