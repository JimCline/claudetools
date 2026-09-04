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
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

import { hierarchyDir, PEER_ELIGIBLE_ROLES, ROLES, ROLE_LABELS, ROUTE_VALUES, TIER, resolvedPeerTargets, roleFromName, tierOf } from "./lib-config.mjs";
import { listTeamNames, readTeam, resolveMemberTeam, teamIsOrphaned, teamMemberByName } from "./lib-roster.mjs";

export { hierarchyDir };

export const MSG_ROLES = ["orchestrator", ...ROLES];
export const MSG_TYPES = ["request", "response"];
export const REASONS = ["context", "second-opinion", "parallel"];
/** Complexity scaling for a peer dispatch (spec 0028 §5.6): the liveness check-in threshold. Absent/unrecognised treated as "small". */
export const ETAS = ["small", "medium", "large"];
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
  const order = ["id", "type", "to", "from", "slug", "parent", "reason", "eta", "to_name", "from_name", "team", "created"];
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
    if (opts.eta !== undefined && opts.eta !== null && !ETAS.includes(opts.eta)) {
      throw new Error(`--eta must be one of ${ETAS.join("|")}, got ${JSON.stringify(opts.eta)}`);
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
      eta: opts.eta || null,
      to_name: opts.toName || null,
      from_name: opts.fromName || null,
      team: opts.team || null,
      created: localIso(now),
    };
  } else {
    if (!opts.id) throw new Error("--id is required for a response");
    let req;
    if (opts.reqPath) {
      // Spec 0037 §2.1: the reply lands beside the request — its destination is never re-derived
      // from the responder's cwd. Every check here is a hard error with nothing written: a
      // relative path would resolve against the responder's drifted cwd (the bug, reintroduced
      // through the fix), and a typo'd-but-plausible directory is silent misdelivery again.
      const p = opts.reqPath;
      if (!isAbsolute(p)) throw new Error(`--req must be an absolute path, got ${JSON.stringify(p)} — use the brief's [hierarchy-msg <path>] value verbatim`);
      if (!existsSync(p)) throw new Error(`--req: no such file ${p} — either the path is typo'd, or the request was archived/moved. Nothing written.`);
      const meta = parseMsgFilename(p);
      if (!meta || meta.type !== "request") throw new Error(`--req: ${p} is not a request file`);
      if (meta.id !== opts.id) throw new Error(`--req: request id ${JSON.stringify(meta.id)} does not match --id ${JSON.stringify(opts.id)}`);
      req = { path: p, meta };
    } else {
      req = findByIdAndType(dir, opts.id, "request");
      // Spec 0037 §2.2: no --req and no matching request in the resolved pool is the moment every
      // silent-misdelivery vector becomes visible — say what to do, not just what is missing.
      if (!req) {
        throw new Error(
          `no request \`${opts.id}\` found in ${msgsDir(dir)} — if you are answering a request delivered as [hierarchy-msg <path>], re-run with --req <that path>. A response created here would land in a pool the requester never reads.`
        );
      }
      if (findByIdAndType(dir, opts.id, "response")) throw new Error(`response ${opts.id} already exists`);
    }
    const parsed = readMsgFile(req.path);
    const rf = parsed && parsed.fm ? parsed.fm : {};
    if (opts.reqPath) {
      // §2.1.3: frontmatter cross-check makes --req self-verifying, not just a destination override.
      if (!parsed || !parsed.fm) throw new Error(`--req: ${req.path} has no parseable frontmatter`);
      const mismatch = (label, got, want) => {
        if (got && want && got !== want) throw new Error(`--req: ${label} — response has ${JSON.stringify(got)}, request has ${JSON.stringify(want)}`);
      };
      mismatch("id mismatch", opts.id, rf.id);
      mismatch("--to must equal the request's from", opts.to, rf.from);
      mismatch("--from must equal the request's to", opts.from, rf.to);
      mismatch("--to-name must equal the request's from_name", opts.toName, rf.from_name);
      mismatch("--from-name must equal the request's to_name", opts.fromName, rf.to_name);
    }
    fields = {
      id: opts.id,
      type,
      to: opts.to || rf.from || req.meta.to,
      from: opts.from || rf.to || req.meta.to,
      slug: req.meta.slug,
      parent: rf.parent || null,
      reason: null,
      eta: null,
      to_name: opts.toName || rf.from_name || null,
      from_name: opts.fromName || rf.to_name || null,
      team: opts.team || rf.team || null,
      created: localIso(now),
    };
  }
  const targetMsgs = opts.reqPath ? dirname(opts.reqPath) : msgsDir(dir);
  const path = join(targetMsgs, msgFilename(fields));
  const body = frontmatterText(fields) + "\n" + skeletonBody(type === "request" ? REQUEST_KEYS : RESPONSE_KEYS);
  if (!opts.reqPath) {
    writeFileSync(path, body, "utf8");
    return { id: fields.id, path, fields };
  }
  // §2.1.5: same duplicate rule as the local pool, applied to the pool the file actually lands in.
  if (existsSync(path)) throw new Error(`response ${fields.id} already exists at ${path}`);
  try {
    writeFileSync(path, body, "utf8");
  } catch (err) {
    // §2.4: never fall back to the local pool — a written-but-invisible file IS the bug. Fail with
    // the OS error verbatim and the workaround.
    throw new Error(
      `could not write the response beside the request at ${path}: ${err && err.message ? err.message : String(err)} — deliver the response content via SendMessage to ${fields.to_name || fields.to} instead, naming this path. Nothing was written to the local pool.`
    );
  }
  // §2.1.6: divergence telemetry — the fix working as intended, surfaced so it is never invisible.
  const localPool = resolve(dir);
  const targetPool = resolve(dirname(targetMsgs));
  const divergent = localPool !== targetPool ? { local: localPool, target: targetPool } : null;
  return { id: fields.id, path, fields, divergent };
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
 * The root of `startId`'s parent chain within `byId` (requests only — a
 * `parent` naming a response id never resolves here, so it can't be mistaken
 * for a request), or `null` if the chain never reaches a `parent: null`
 * message within 32 hops. A cycle, a missing parent, and an exhausted hop cap
 * all take this same "no root" path (spec 0026 §4.2 amendment, 2026-08-28):
 * guessing a root would make §4.1 condition 3's answer a guess too, and a
 * downstream row is a positive claim about who dispatched what.
 */
export function rootOf(byId, startId) {
  const seen = new Set([startId]);
  let id = startId;
  let fm = byId.get(id);
  for (let hops = 0; ; hops++) {
    if (!fm.parent) return { id, fm };
    if (hops >= 32 || !byId.has(fm.parent) || seen.has(fm.parent)) return null;
    seen.add(fm.parent);
    id = fm.parent;
    fm = byId.get(id);
  }
}

/**
 * Downstream dispatches: requests created by a session other than the one that
 * rooted their parent chain. Derived entirely from existing frontmatter — no
 * new persisted field.
 * Returns newest-first: { id, parent, root_id, root_from, root_from_name,
 *                         from, from_name, to, to_name, slug, created }
 */
// `from_name` is optional (msg.mjs:147-148), so absence must never read as a
// value. Confirm sameness on names when both are present; otherwise fall back
// to the always-present role. Unconfirmed sameness is not sameness.
function bothNamed(a, b) { return Boolean(a.from_name && b.from_name); }
function sameSender(a, b) {
  return bothNamed(a, b) ? a.from_name === b.from_name : a.from === b.from;
}

export function listDownstreamDispatches(dir) {
  const byId = new Map();
  for (const f of requestFiles(dir)) {
    if (f.meta.type !== "request") continue;
    const parsed = readMsgFile(f.path);
    if (parsed && parsed.fm) byId.set(f.meta.id, parsed.fm);
  }
  const out = [];
  for (const [id, fm] of byId) {
    if (!fm.parent) continue; // §4.1 condition 2, explicit
    const root = rootOf(byId, id);
    if (!root || root.id === id) continue; // unresolvable, or self-rooted (cycle)
    if (sameSender(root.fm, fm)) continue; // §4.1 condition 3
    out.push({
      id,
      parent: fm.parent,
      root_id: root.id,
      root_from: root.fm.from,
      root_from_name: root.fm.from_name,
      from: fm.from,
      from_name: fm.from_name,
      to: fm.to,
      to_name: fm.to_name,
      slug: fm.slug,
      created: fm.created,
      identity: bothNamed(root.fm, fm) ? "name" : "role-only",
    });
  }
  return out.sort((a, b) => (a.id < b.id ? 1 : -1));
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

/**
 * Validate the response pointer a SendMessage reply must carry (spec 0031
 * Fix F). Mirrors `validateRequestToken` above, plus the id check that
 * function has no equivalent of: without it, a pointer at any older or
 * unrelated response file would pass, letting a session close an obligation
 * with a document about something else — worse than a missing token, because
 * it looks answered. Returns `{ok:true, path, fm}` or `{ok:false, why}`.
 */
export function validateResponseToken(text, dir, expectedFrom, expectedId) {
  const path = extractMsgToken(text);
  if (!path) return { ok: false, why: "missing token" };
  if (!isAbsolute(path) || !existsSync(path)) return { ok: false, why: `path not found (${path})` };
  if (!isUnder(path, msgsDir(dir)) || !path.endsWith("--response.md")) return { ok: false, why: "not a response file" };
  const parsed = readMsgFile(path);
  if (!parsed || !parsed.fm || parsed.fm.type !== "response") return { ok: false, why: "not a response file" };
  if (expectedFrom && parsed.fm.from !== expectedFrom) {
    return { ok: false, why: `wrong from: (file says ${parsed.fm.from}, expected ${expectedFrom})` };
  }
  if (expectedId && parsed.fm.id !== expectedId) {
    return { ok: false, why: `wrong id: (file says ${parsed.fm.id}, expected ${expectedId})` };
  }
  return { ok: true, path, fm: parsed.fm };
}

/** The text after the closing frontmatter fence, trimmed; the whole text, trimmed, if there is no fence. */
function bodyAfterFrontmatter(text) {
  const fm = parseFrontmatter(text);
  if (!fm) return text.trim();
  return text.split("\n").slice(fm.end).join("\n").trim();
}

/** A `## [n] <key>` section heading — structurally generated, never authored. */
const SKELETON_HEADING_RE = /^##\s*\[\d+\]\s*\S+/;

/** A bare placeholder bullet — `- none`, or `- [n] <key>:` with nothing typed after the colon. */
const SKELETON_BULLET_RE = /^-\s*(none|\[\d+\]\s*[^:]+:\s*)$/;

/**
 * True when at least one line of `body` is not one of the structurally
 * generated shapes msg.mjs writes into a fresh skeleton (blank, a section
 * heading, or a bare placeholder bullet) — i.e. the author actually typed
 * something. Spec 0028 §4.2 (r4): rejected as the fix a byte-identity check
 * against the skeleton body, since that breaks silently on any wording change
 * to the skeleton; this asks "did the author write anything" instead, which
 * survives that kind of edit. One authored line anywhere is enough — a
 * response filled in one section and left the rest skeleton still counts.
 */
function hasAuthoredContent(body) {
  for (const raw of body.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (SKELETON_HEADING_RE.test(line)) continue;
    if (SKELETON_BULLET_RE.test(line)) continue;
    return true;
  }
  return false;
}

/**
 * True when text carries `[hierarchy-msg <path>]` naming an existing
 * `--response.md` (optionally for one id) whose body — beyond its
 * frontmatter — the author actually wrote something into. Spec 0028 §4.2:
 * the token check alone let a role satisfy its report-back obligation by
 * emitting the pointer to a file that was never actually filled in (a bare
 * frontmatter stub, e.g. from a tool that can create the file but cannot
 * write its body) — existence is not completion, and (r4) neither is an
 * untouched skeleton body.
 */
export function hasResponseToken(text, id) {
  const path = extractMsgToken(text);
  if (!path || !path.endsWith("--response.md") || !existsSync(path)) return false;
  if (id) {
    const meta = parseMsgFilename(path);
    if (!meta || meta.id !== id) return false;
  }
  let body;
  try {
    body = readFileSync(path, "utf8");
  } catch {
    return false;
  }
  return hasAuthoredContent(bodyAfterFrontmatter(body));
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

/**
 * Realpath-normalise a cwd for comparison (spec 0025 §12.3, spec 0036 §3.1). Falls back to the
 * raw path if it does not resolve (e.g. the directory is gone).
 */
export function realCwd(p) {
  if (!p) return p;
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
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
 * The one liveness rule for a peers.jsonl record: `up` is live iff its pid is alive;
 * `seen`/`briefed` are live while fresher than ROSTER_FRESH_SEC; anything else (incl.
 * `down`) is not. Every liveness read — roster(), memberIsLive, the disband/dismiss
 * no-team fallback (spec 0040 §1.2) — goes through here; do not re-derive it elsewhere.
 */
export function recordLiveness(rec, now = Date.now()) {
  const ageSec = ageSecOf(rec.ts, now);
  let live = false;
  let how = rec.status;
  if (rec.status === "up") {
    live = pidAlive(rec.pid);
    how = "up-pid";
  } else if (rec.status === "seen" || rec.status === "briefed") {
    live = ageSec < ROSTER_FRESH_SEC;
  }
  return { live, how, ageSec };
}

/**
 * Spec 0040 §1.2: the named, not-down peers.jsonl records attributed to `team` (null =
 * default team), each with recordLiveness() applied — the enumeration disband/dismiss fall
 * back to when no team.json exists, and disband's source of extra non-team peers when one
 * does. A record's team is its team.json membership when it has one (as roster() resolves
 * it); with no membership — the very case this exists for — its own checkin `team` tag
 * decides, untagged meaning the default team.
 */
export function livePeerSlots(dir, team = null, now = Date.now()) {
  const slots = [];
  for (const rec of latestRoster(dir)) {
    if (rec.status === "down" || !rec.name) continue;
    const membership = resolveMemberTeam(dir, rec.name);
    const tag = rec.team !== undefined ? rec.team : null;
    if ((membership.found ? membership.team : tag) !== team) continue;
    slots.push({ name: rec.name, role: rec.role || null, pid: rec.pid ?? null, pane_id: rec.pane_id || null, ...recordLiveness(rec, now) });
  }
  return slots;
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
    const { live, how, ageSec } = recordLiveness(rec, now);
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
  const lines = [`HIERARCHY STATE (${dir}):`, openLine, peersLine, routeLine(eff), tierLine(resolved, model)];
  // Spec 0033 §3.4: surface orphaned team records (dead orchestrator pid), never auto-delete —
  // best-effort, must never cost the rest of the state block.
  try {
    const orphanNames = [null, ...listTeamNames(dir)].filter((name) => teamIsOrphaned(readTeam(dir, name)));
    if (orphanNames.length) {
      const named = orphanNames.map((n) => n || "default");
      lines.push(`ah: ${orphanNames.length} orphaned team record(s) (${named.join(", ")}) — their orchestrator process is gone. \`roster.mjs reap\` to list, \`reap --commit\` to remove.`);
    }
  } catch {
    // advisory only — never let a probe failure cost the state block
  }
  // Spec 0036 §3.6: a misplaced-peer count, so the orchestrator sees it without asking — never
  // silent (same argument as 0035 §2.4). Best-effort, like the orphan-team line above.
  try {
    // Filtered to live rows — an unclean exit otherwise leaves misplaced:true as the latest row
    // forever, nagging about a peer that no longer exists (same fix as roster.mjs's teams case).
    const misplacedCount = latestRoster(dir).filter((r) => r.misplaced && r.status === "up" && pidAlive(r.pid)).length;
    if (misplacedCount) lines.push(`ah: ${misplacedCount} misplaced peer(s) — see \`roster.mjs teams\` for detail.`);
  } catch {
    // advisory only — never let a probe failure cost the state block
  }
  return lines.join("\n");
}

export { ROLES, ROLE_LABELS };
