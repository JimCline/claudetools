#!/usr/bin/env node
/**
 * agent-hierarchy — usage reporter. Pure local computation, zero tokens.
 *
 *   node usage-report.mjs [session|day|week|month|all] [--json]
 *
 * Run it straight from a shell (or via `!` in Claude Code) and no model ever
 * sees a byte of it. Running it through /hierarchy usage costs only the tokens
 * of the printed report entering that session's context.
 *
 * Data sources:
 *   - USAGE_FILE — one record per finished subagent, written by the
 *     SubagentStop collector (agent_type + summed transcript usage).
 *   - Main-session transcripts — the orchestrator's own usage, summed directly
 *     from <project_dir>/<session_id>.jsonl for every session the records
 *     mention. Scanned INCREMENTALLY: CACHE_FILE stores a byte offset and
 *     per-day buckets per transcript, so a closed session is never re-parsed
 *     and a live one is parsed only from where the last run stopped. Offsets
 *     only ever advance to the end of the last COMPLETE line, because a live
 *     transcript's tail may be mid-write.
 *
 * Honest accounting notes, also printed where they matter:
 *   - Subagent records are bucketed by their Stop time; orchestrator usage by
 *     each turn's own timestamp. Windowed numbers are as exact as the data.
 *   - `in` is fresh (uncached) input; cache reads are reported separately
 *     rather than folded in, since a cache-read token is ~10x cheaper.
 *   - Subagents whose transcript could not be found appear as found:false
 *     records — counted as agents, zero tokens. A run of those means the
 *     collector's path derivation broke; say so rather than hiding them.
 */

import { readFileSync, renameSync, statSync, writeFileSync, openSync, readSync, closeSync } from "node:fs";
import { join } from "node:path";
import { CACHE_FILE, USAGE_FILE, addUsage, roleFor, zeroUsage } from "./lib-usage.mjs";

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const window = args.find((a) => ["session", "day", "week", "month", "all"].includes(a)) || "";

const DAY_MS = 24 * 60 * 60 * 1000;
const now = new Date();
const localMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
const since = {
  day: localMidnight,
  week: now.getTime() - 7 * DAY_MS,
  month: now.getTime() - 30 * DAY_MS,
  all: 0,
  session: 0,
};

// ---- load subagent records ------------------------------------------------

let records = [];
try {
  records = readFileSync(USAGE_FILE, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter((r) => r && typeof r.agent_id === "string");
} catch {
  // no data yet — still report (orchestrator sums need session ids from
  // records, so with no records the report is honestly empty)
}

// A resumed agent (SendMessage continuation) fires SubagentStop again and the
// collector re-sums its transcript — which is CUMULATIVE, so summing both
// records double-counts. Keep only the last record per (session, agent):
// later record ⊇ earlier one.
{
  const latest = new Map();
  for (const r of records) latest.set(`${r.session_id}|${r.agent_id}`, r);
  records = [...latest.values()];
}

const latestSession = records.reduce(
  (best, r) => (r.ts > (best?.ts || "") ? r : best),
  null
)?.session_id;

// ---- orchestrator: incremental main-transcript scan -----------------------

function loadCache() {
  try {
    const c = JSON.parse(readFileSync(CACHE_FILE, "utf8"));
    if (c && c.v === 1 && c.files && typeof c.files === "object") return c;
  } catch {
    // absent or corrupt — rebuild from scratch
  }
  return { v: 1, files: {} };
}

function saveCache(cache) {
  try {
    const tmp = `${CACHE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(cache));
    renameSync(tmp, CACHE_FILE);
  } catch {
    // cache is an optimization; losing it only costs a re-parse
  }
}

/** Read [offset, end-of-last-complete-line) and parse the new lines. */
function scanFrom(file, entry) {
  let size;
  try {
    size = statSync(file).size;
  } catch {
    return false; // transcript gone (session cleaned up) — keep cached sums
  }
  if (size < entry.offset) entry.offset = 0; // truncated/rotated: restart
  if (size === entry.offset) return true;

  let text;
  try {
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(size - entry.offset);
    readSync(fd, buf, 0, buf.length, entry.offset);
    closeSync(fd);
    text = buf.toString("utf8");
  } catch {
    return false;
  }

  const lastNl = text.lastIndexOf("\n");
  if (lastNl < 0) return true; // no complete new line yet
  const complete = text.slice(0, lastNl + 1);
  entry.offset += Buffer.byteLength(complete, "utf8");

  const today = new Date().toISOString().slice(0, 10);
  for (const line of complete.split("\n")) {
    if (!line) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const u = o?.message?.usage;
    if (o?.type !== "assistant" || !u) continue;
    const day = typeof o.timestamp === "string" ? o.timestamp.slice(0, 10) : today;
    const b = (entry.days[day] ||= zeroUsage());
    b.calls += 1;
    b.in += u.input_tokens || 0;
    b.out += u.output_tokens || 0;
    b.cache_read += u.cache_read_input_tokens || 0;
    b.cache_create += u.cache_creation_input_tokens || 0;
    const m = o?.message?.model;
    if (typeof m === "string" && m) entry.models[m] = (entry.models[m] || 0) + 1;
  }
  return true;
}

const cache = loadCache();
const mainFiles = new Map(); // session_id -> transcript path
for (const r of records) {
  if (r.project_dir && r.session_id && !mainFiles.has(r.session_id)) {
    mainFiles.set(r.session_id, join(r.project_dir, `${r.session_id}.jsonl`));
  }
}
for (const [sid, file] of mainFiles) {
  const entry = (cache.files[file] ||= { offset: 0, days: {}, models: {}, session_id: sid });
  scanFrom(file, entry);
}
saveCache(cache);

// ---- aggregate ------------------------------------------------------------

function inWindow(ts, winStart) {
  if (!winStart) return true;
  const t = Date.parse(ts);
  return Number.isFinite(t) && t >= winStart;
}

/** roles: { role: { agents:Set, ...usage, missing } } for one window. */
function aggregate(winStart, sessionOnly) {
  const roles = {};
  const otherTypes = {};
  for (const r of records) {
    if (sessionOnly && r.session_id !== latestSession) continue;
    if (!sessionOnly && !inWindow(r.ts, winStart)) continue;
    const role = roleFor(r.agent_type);
    const b = (roles[role] ||= { agents: new Set(), missing: 0, ...zeroUsage() });
    b.agents.add(r.agent_id);
    if (r.found === false) b.missing += 1;
    addUsage(b, r);
    if (role === "other") {
      const t = r.agent_type || "(unknown)";
      otherTypes[t] = (otherTypes[t] || 0) + 1;
    }
  }

  // orchestrator rows from the per-day buckets
  const orch = { agents: new Set(), missing: 0, ...zeroUsage() };
  for (const [file, entry] of Object.entries(cache.files)) {
    if (sessionOnly && entry.session_id !== latestSession) continue;
    if (!sessionOnly && winStart) {
      // only sessions that have records in this window contribute
      const active = records.some((r) => r.session_id === entry.session_id && inWindow(r.ts, winStart));
      if (!active) continue;
    }
    let contributed = false;
    for (const [day, b] of Object.entries(entry.days)) {
      if (!sessionOnly && winStart && Date.parse(`${day}T23:59:59Z`) < winStart) continue;
      addUsage(orch, b);
      contributed = true;
    }
    if (contributed) orch.agents.add(file);
  }
  if (orch.calls > 0) roles.orchestrator = orch;

  return { roles, otherTypes };
}

function dailyTotals(days) {
  const out = {};
  const start = now.getTime() - days * DAY_MS;
  for (const r of records) {
    if (!inWindow(r.ts, start)) continue;
    const d = r.ts.slice(0, 10);
    (out[d] ||= zeroUsage());
    addUsage(out[d], r);
  }
  for (const entry of Object.values(cache.files)) {
    for (const [day, b] of Object.entries(entry.days)) {
      if (Date.parse(`${day}T23:59:59Z`) < start) continue;
      (out[day] ||= zeroUsage());
      addUsage(out[day], b);
    }
  }
  return out;
}

// ---- render ---------------------------------------------------------------

const fmt = (n) =>
  n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : String(n);
const pad = (s, w) => String(s).padEnd(w);
const rpad = (s, w) => String(s).padStart(w);

const ROLE_ORDER = ["orchestrator", "ultra-advisor", "architect", "reviewer", "implementor", "task-runner", "other"];
const orderedRoles = (roles) =>
  Object.keys(roles).sort((a, b) => {
    const ia = ROLE_ORDER.indexOf(a), ib = ROLE_ORDER.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });

function renderTable(roles) {
  const lines = [
    `  ${pad("role", 14)}${rpad("agents", 7)}${rpad("calls", 7)}${rpad("out", 10)}${rpad("in", 10)}${rpad("cache-read", 12)}`,
  ];
  const total = { agents: 0, ...zeroUsage() };
  for (const role of orderedRoles(roles)) {
    const b = roles[role];
    const agents = role === "orchestrator" ? b.agents.size : b.agents.size;
    lines.push(
      `  ${pad(role, 14)}${rpad(agents, 7)}${rpad(b.calls, 7)}${rpad(fmt(b.out), 10)}${rpad(fmt(b.in), 10)}${rpad(fmt(b.cache_read), 12)}` +
        (b.missing ? `   (${b.missing} transcript${b.missing > 1 ? "s" : ""} not found)` : "")
    );
    total.agents += agents;
    addUsage(total, b);
  }
  lines.push(
    `  ${pad("total", 14)}${rpad(total.agents, 7)}${rpad(total.calls, 7)}${rpad(fmt(total.out), 10)}${rpad(fmt(total.in), 10)}${rpad(fmt(total.cache_read), 12)}`
  );
  return lines;
}

function renderBars(roles) {
  const rows = orderedRoles(roles).map((role) => [role, roles[role].out]);
  const max = Math.max(1, ...rows.map(([, v]) => v));
  return rows.map(
    ([role, v]) =>
      `  ${pad(role, 14)}${pad("█".repeat(Math.max(v > 0 ? 1 : 0, Math.round((v / max) * 24))), 25)}${fmt(v)}`
  );
}

function renderDaily(totals) {
  const days = Object.keys(totals).sort();
  const max = Math.max(1, ...days.map((d) => totals[d].out));
  return days.map(
    (d) =>
      `  ${d}  ${pad("█".repeat(Math.max(totals[d].out > 0 ? 1 : 0, Math.round((totals[d].out / max) * 24))), 25)}${fmt(totals[d].out)}`
  );
}

const session = aggregate(0, true);
const week = aggregate(since.week, false);
const chosen = window && window !== "session" ? aggregate(since[window], false) : null;

if (asJson) {
  const strip = ({ roles, otherTypes }) => ({
    roles: Object.fromEntries(
      Object.entries(roles).map(([k, v]) => [k, { ...v, agents: v.agents.size }])
    ),
    otherTypes,
  });
  process.stdout.write(
    JSON.stringify(
      {
        generated: now.toISOString(),
        records: records.length,
        latest_session: latestSession || null,
        session: strip(session),
        window: window || "default",
        windowed: strip(chosen || week),
        daily: dailyTotals(window === "month" ? 30 : 14),
      },
      null,
      2
    ) + "\n"
  );
  process.exit(0);
}

const out = [];
out.push(`agent-hierarchy usage — ${now.toISOString().slice(0, 16).replace("T", " ")}`);
out.push(`data: ${USAGE_FILE} (${records.length} subagent records)`);
if (!records.length) {
  out.push("");
  out.push("No usage recorded yet. The collector runs on SubagentStop, so data appears");
  out.push("once the plugin is enabled and a session dispatches subagents.");
}
if (latestSession) {
  out.push("");
  out.push(`SESSION ${latestSession.slice(0, 8)} (latest with subagent activity)`);
  out.push(...renderTable(session.roles));
}
if (chosen) {
  out.push("");
  out.push(`${window.toUpperCase()} — output tokens by role`);
  out.push(...renderTable(chosen.roles));
  out.push("");
  out.push(...renderBars(chosen.roles));
} else if (records.length) {
  out.push("");
  out.push("LAST 7 DAYS — output tokens by role");
  out.push(...renderBars(week.roles));
}
const daily = dailyTotals(window === "month" ? 30 : 14);
if (Object.keys(daily).length) {
  out.push("");
  out.push(`DAILY output tokens (last ${window === "month" ? 30 : 14} days)`);
  out.push(...renderDaily(daily));
}
const others = (chosen || week).otherTypes;
if (Object.keys(others).length) {
  out.push("");
  out.push(
    `"other" agent types: ${Object.entries(others)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([t, n]) => `${t} ×${n}`)
      .join(", ")}`
  );
}
out.push("");
out.push("in = fresh input tokens; cache reads shown separately (≈10x cheaper).");
process.stdout.write(out.join("\n") + "\n");
