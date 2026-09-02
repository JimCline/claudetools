#!/usr/bin/env node
/**
 * agent-hierarchy — message-file CLI.
 *
 *   msg.mjs new --to <role> --from <role> --slug <s> [--to-name <n>] [--from-name <n>]
 *               [--parent <id>] [--reason context|second-opinion|parallel]
 *               [--eta small|medium|large] [--type request|response] [--id <id>] [--team <name>]
 *               [--req <abs request path>]   (response only: write it beside that request — spec 0037)
 *   msg.mjs list [--open|--closed|--all] [--to <role>] [--team <name>] [--json] [--plain]
 *   msg.mjs downstream [--root-name <name>]
 *   msg.mjs index <path>
 *   msg.mjs sweep [--days 7]
 *   msg.mjs roster
 *   msg.mjs route [peers|subagents|prefer-peers] --session <id>
 *   msg.mjs global-scope <roster|config> <allow|deny> --session <id>
 *
 * Every subcommand takes `--cwd <path>` (default process.cwd()) and resolves
 * the runtime dir via lib-hier.mjs; output is JSON unless `--plain`. Writers
 * never hand-roll ids or skeletons — `new` is the only way a file is born.
 * Bad args or a response without its request exit non-zero with one line on
 * stderr.
 *
 * `--team <name>` (spec 0011 §5.1) scopes `new`/`list`/`roster` to a named
 * team instead of the default. Omitted, `new`/`list` fall through to spec
 * 0011 §4.4 rung 3: `CLAUDE_PID` matched against a team's `orchestrator.pid`
 * (`pidAlive`-guarded), so a CLI launched from a named-team orchestrator
 * resolves that team without the flag; no match resolves the default team,
 * same as before this rung existed. `route`/`global-scope` write
 * `gates.jsonl`, which spec 0011 §6.2 leaves shared and unscoped — no
 * `--team` there.
 */

import { PEER_ELIGIBLE_ROLES, resolveConfig, ROUTE_VALUES, teamPrefix, validateTeamAlias } from "./lib-config.mjs";
import {
  appendGate,
  createMessage,
  effectiveRoute,
  ensureHierarchyDir,
  exchangeAgeSec,
  fmtAge,
  hierarchyDir,
  indexAnchors,
  listDownstreamDispatches,
  listExchanges,
  pidAlive,
  readMsgFile,
  recordRoute,
  roster,
  rosterLine,
  sweep,
  SWEEP_DAYS,
} from "./lib-hier.mjs";
import { listTeamNames, readTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "open", "closed", "all"]);

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (!BOOL_FLAGS.has(key) && next !== undefined && !next.startsWith("--")) {
        opts[key] = next;
        i++;
      } else {
        opts[key] = true;
      }
    } else {
      opts._.push(a);
    }
  }
  return opts;
}

function fail(msg) {
  process.stderr.write(`msg.mjs: ${msg}\n`);
  process.exit(2);
}

function out(obj, plain) {
  process.stdout.write((plain ? String(obj) : JSON.stringify(obj)) + "\n");
}

const all = parseArgs(process.argv.slice(2));
const cmd = all._.shift();
const opts = all;
const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();
const plain = opts.plain === true;

/**
 * `--team <name>` if given (validated with 0010's alias validator); else
 * spec 0011 §4.4 rung 3 — `CLAUDE_PID` matched against a team's
 * `orchestrator.pid`, `pidAlive`-guarded so a recycled pid from a dead
 * orchestrator never matches a stale team. No match falls through to the
 * default team (null), same as before this rung existed.
 */
function resolveTeamArg() {
  if (typeof opts.team === "string") {
    const v = validateTeamAlias(opts.team);
    if (!v.ok) fail(`--team: ${v.why}`);
    return opts.team;
  }
  const pid = Number(process.env.CLAUDE_PID);
  if (Number.isInteger(pid) && pid > 0 && pidAlive(pid)) {
    try {
      const dir = hierarchyDir(cwd);
      const base = readTeam(dir);
      if (base && base.orchestrator && base.orchestrator.pid === pid) return null;
      for (const name of listTeamNames(dir)) {
        const team = readTeam(dir, name);
        if (team && team.orchestrator && team.orchestrator.pid === pid) return name;
      }
    } catch {
      // fail-open to default — 0009 §8.12 pattern extended to team resolution.
    }
  }
  return null;
}
const teamArg = resolveTeamArg();

/** The `team:` tag an exchange's request was written with (null = default team or untagged, §7.6). */
function itemTeamTag(item) {
  const parsed = readMsgFile(item.request.path);
  return (parsed && parsed.fm && parsed.fm.team) || null;
}

/** `<root_from_name> → <from_name> → <to>: <slug>  (id <id>, parent <parent>[, role-only])` — spec 0026 §4.3. */
function downstreamLine(d) {
  const tag = d.identity === "role-only" ? ", role-only" : "";
  return `${d.root_from_name} → ${d.from_name} → ${d.to}: ${d.slug}  (id ${d.id}, parent ${d.parent}${tag})`;
}

try {
  switch (cmd) {
    case "new": {
      const dir = ensureHierarchyDir(cwd);
      const type = typeof opts.type === "string" ? opts.type : "request";
      if (opts.req === true) fail("--req needs the request file's absolute path");
      const reqPath = typeof opts.req === "string" ? opts.req : null;
      if (reqPath && type !== "response") fail("--req applies only to --type response");
      const res = createMessage(dir, {
        reqPath,
        cwd,
        type,
        to: opts.to,
        from: opts.from,
        slug: opts.slug,
        id: typeof opts.id === "string" ? opts.id : undefined,
        parent: typeof opts.parent === "string" ? opts.parent : null,
        reason: typeof opts.reason === "string" ? opts.reason : null,
        eta: typeof opts.eta === "string" ? opts.eta : null,
        toName: typeof opts["to-name"] === "string" ? opts["to-name"] : null,
        fromName: typeof opts["from-name"] === "string" ? opts["from-name"] : null,
        team: teamArg,
      });
      out(plain ? `${res.id}  ${res.path}` : { id: res.id, path: res.path }, plain);
      if (res.divergent) {
        process.stderr.write(`msg.mjs: note — this session's own pool is ${res.divergent.local}; the response was written beside its request under ${res.divergent.target} (spec 0037)\n`);
      }
      break;
    }
    case "list": {
      const dir = hierarchyDir(cwd);
      const which = opts.all ? "all" : opts.closed ? "closed" : "open";
      let items = listExchanges(dir);
      if (which === "open") items = items.filter((e) => e.open);
      if (which === "closed") items = items.filter((e) => !e.open);
      if (typeof opts.to === "string") items = items.filter((e) => e.to === opts.to);
      items = items.filter((e) => itemTeamTag(e) === teamArg);
      const rows = items.map((e) => ({
        id: e.id,
        to: e.to,
        slug: e.slug,
        age: fmtAge(exchangeAgeSec(e)),
        state: e.open ? "open" : "closed",
        request: e.request.path,
        response: e.response ? e.response.path : null,
      }));
      // Spec 0026 §4.3: append a downstream section only when non-empty — no
      // header when there is nothing to show, so output stays byte-identical
      // to before this existed until a downstream dispatch actually exists.
      const downstream = listDownstreamDispatches(dir);
      if (plain) {
        const rowsText = rows.map((r) => `${r.id}  ${r.to}  ${r.slug}  ${r.age}  ${r.state}`).join("\n");
        const text = downstream.length
          ? (rowsText ? `${rowsText}\n\ndownstream:\n` : "downstream:\n") + downstream.map(downstreamLine).join("\n")
          : rowsText;
        out(text, true);
      } else {
        out(downstream.length ? { exchanges: rows, downstream } : rows, false);
      }
      break;
    }
    case "downstream": {
      const dir = hierarchyDir(cwd);
      let rows = listDownstreamDispatches(dir);
      if (typeof opts["root-name"] === "string") rows = rows.filter((r) => r.root_from_name === opts["root-name"]);
      if (plain) out(rows.map(downstreamLine).join("\n"), true);
      else out(rows, false);
      break;
    }
    case "index": {
      const path = opts._[0];
      if (!path) fail("index needs a <path>");
      const parsed = readMsgFile(path);
      if (!parsed) fail(`cannot read ${path}`);
      const anchors = indexAnchors(parsed.text);
      if (plain) out(anchors.map((a) => `${a.line}:${a.text}`).join("\n"), true);
      else out(anchors.map((a) => ({ line: a.line, n: a.n, key: a.key })), false);
      break;
    }
    case "sweep": {
      const dir = hierarchyDir(cwd);
      const days = opts.days !== undefined ? Number(opts.days) : SWEEP_DAYS;
      if (!Number.isFinite(days) || days < 0) fail(`--days must be a non-negative number, got ${JSON.stringify(opts.days)}`);
      const moved = sweep(dir, days);
      out(plain ? String(moved) : { archived: moved }, plain);
      break;
    }
    case "roster": {
      const dir = hierarchyDir(cwd);
      const resolved = resolveConfig(cwd, { team: teamArg });
      const ros = roster(dir, resolved, teamPrefix(resolved.cwd, resolved.team));
      if (plain) {
        const lines = [];
        for (const role of PEER_ELIGIBLE_ROLES) {
          const list = ros[role];
          if (!list.length) lines.push(`${role}: none`);
          for (const i of list) {
            lines.push(
              `${role}: ${i.name}  ${i.live ? "live" : "stale"}  ${i.how}  ${fmtAge(i.ageSec)} ago${i.busy ? "  busy" : ""}${i.task ? `  task=${i.task}` : ""}  open=${i.openBriefs}${i.unassigned ? ` (unassigned ${i.unassigned})` : ""}`
            );
          }
        }
        out(lines.join("\n"), true);
      } else {
        out({ dir, summary: rosterLine(ros), roles: ros }, false);
      }
      break;
    }
    case "route": {
      const dir = hierarchyDir(cwd);
      const resolved = resolveConfig(cwd);
      const sessionId = typeof opts.session === "string" ? opts.session : null;
      if (!sessionId) fail("route needs --session <id>");
      const value = opts._[0];
      if (value === undefined) {
        const eff = effectiveRoute(dir, resolved, sessionId);
        out(plain ? `${eff.value} (${eff.source})` : eff, plain);
      } else {
        if (!ROUTE_VALUES.includes(value)) fail(`route must be one of ${ROUTE_VALUES.join("|")}, got ${JSON.stringify(value)}`);
        recordRoute(dir, sessionId, value);
        out(plain ? value : { recorded: value, session_id: sessionId }, plain);
      }
      break;
    }
    case "global-scope": {
      const dir = hierarchyDir(cwd);
      const scope = opts._[0];
      const answer = opts._[1];
      if (!["roster", "config"].includes(scope)) fail(`global-scope needs roster|config, got ${JSON.stringify(scope)}`);
      if (!["allow", "deny"].includes(answer)) fail(`global-scope needs allow|deny, got ${JSON.stringify(answer)}`);
      const sessionId = typeof opts.session === "string" ? opts.session : null;
      if (!sessionId) fail("global-scope needs --session <id>");
      appendGate(dir, { type: "global-scope", session_id: sessionId, scope, answer });
      out(plain ? `${scope} ${answer}` : { recorded: answer, scope, session_id: sessionId }, plain);
      break;
    }
    default:
      fail(`usage: msg.mjs new|list|downstream|index|sweep|roster|route|global-scope [--cwd <path>] [--plain]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
