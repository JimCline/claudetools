#!/usr/bin/env node
/**
 * agent-hierarchy — message-file CLI.
 *
 *   msg.mjs new --to <role> --from <role> --slug <s> [--to-name <n>] [--from-name <n>]
 *               [--parent <id>] [--reason context|second-opinion|parallel]
 *               [--type request|response] [--id <id>]
 *   msg.mjs list [--open|--closed|--all] [--to <role>] [--json] [--plain]
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
 */

import { PEER_ELIGIBLE_ROLES, resolveConfig, ROUTE_VALUES, teamPrefix } from "./lib-config.mjs";
import {
  appendGate,
  createMessage,
  effectiveRoute,
  ensureHierarchyDir,
  exchangeAgeSec,
  fmtAge,
  hierarchyDir,
  indexAnchors,
  listExchanges,
  readMsgFile,
  recordRoute,
  roster,
  rosterLine,
  sweep,
  SWEEP_DAYS,
} from "./lib-hier.mjs";

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

try {
  switch (cmd) {
    case "new": {
      const dir = ensureHierarchyDir(cwd);
      const type = typeof opts.type === "string" ? opts.type : "request";
      const res = createMessage(dir, {
        cwd,
        type,
        to: opts.to,
        from: opts.from,
        slug: opts.slug,
        id: typeof opts.id === "string" ? opts.id : undefined,
        parent: typeof opts.parent === "string" ? opts.parent : null,
        reason: typeof opts.reason === "string" ? opts.reason : null,
        toName: typeof opts["to-name"] === "string" ? opts["to-name"] : null,
        fromName: typeof opts["from-name"] === "string" ? opts["from-name"] : null,
      });
      out(plain ? `${res.id}  ${res.path}` : { id: res.id, path: res.path }, plain);
      break;
    }
    case "list": {
      const dir = hierarchyDir(cwd);
      const which = opts.all ? "all" : opts.closed ? "closed" : "open";
      let items = listExchanges(dir);
      if (which === "open") items = items.filter((e) => e.open);
      if (which === "closed") items = items.filter((e) => !e.open);
      if (typeof opts.to === "string") items = items.filter((e) => e.to === opts.to);
      const rows = items.map((e) => ({
        id: e.id,
        to: e.to,
        slug: e.slug,
        age: fmtAge(exchangeAgeSec(e)),
        state: e.open ? "open" : "closed",
        request: e.request.path,
        response: e.response ? e.response.path : null,
      }));
      if (plain) out(rows.map((r) => `${r.id}  ${r.to}  ${r.slug}  ${r.age}  ${r.state}`).join("\n"), true);
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
      const resolved = resolveConfig(cwd);
      const ros = roster(dir, resolved, teamPrefix(resolved.cwd));
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
      fail(`usage: msg.mjs new|list|index|sweep|roster|route|global-scope [--cwd <path>] [--plain]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
