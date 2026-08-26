#!/usr/bin/env node
/**
 * agent-hierarchy — PostToolUse roster writer (orchestrator side).
 *
 * ListAgents: every line of the tool response under `Peer sessions` matching
 *   `^\s*(.+?) \[([0-9a-f]+)\]\s+·\s+(\w+)\s+·\s+(idle|busy)\s+·`
 * whose name is a configured peer target for some role, or contains a role
 * token (architect|reviewer|implementor|ultra-advisor|advisor), is recorded as
 * `{status:"seen", name, ref, role, busy}`. Other names are ignored.
 *
 * SendMessage carrying the `[hierarchy-peer-brief` sentinel: records
 * `{status:"briefed", name: stripRef(to), role, task}`.
 *
 * The peer report-back resolver (posttooluse-peer-resolve.mjs) is a separate
 * hook and is unchanged. Subagents write nothing. Fail-open.
 */

import { isSubagent, readHookInput, resolveConfig, teamPrefix } from "./lib-config.mjs";
import { appendRosterRecord, hierarchyDir, roleForAnyPeerName } from "./lib-hier.mjs";
import { parseSentinel, stripRef } from "./lib-peer.mjs";
import { resolveMemberTeam } from "./lib-roster.mjs";

/**
 * The team tag for a roster record (spec 0011 §4.3): a fresh name-membership
 * lookup, since this hook has no session_id to resolve `resolved.team` from
 * (§4.4 rung 2 is unavailable here) — it only ever tags names it just read.
 */
function teamTagFor(dir, name) {
  const membership = resolveMemberTeam(dir, name);
  return membership.found ? membership.team : null;
}

const LINE_RE = /^\s*(.+?) \[([0-9a-f]+)\]\s+·\s+(\w+)\s+·\s+(idle|busy)\s+·/;

function responseText(resp) {
  if (typeof resp === "string") return resp;
  if (!resp || typeof resp !== "object") return "";
  if (typeof resp.output === "string") return resp.output;
  if (typeof resp.text === "string") return resp.text;
  if (Array.isArray(resp.content)) return resp.content.map((p) => (p && typeof p.text === "string" ? p.text : "")).join("\n");
  if (Array.isArray(resp)) return resp.map((p) => (typeof p === "string" ? p : p && typeof p.text === "string" ? p.text : "")).join("\n");
  try {
    return JSON.stringify(resp);
  } catch {
    return "";
  }
}

try {
  const input = await readHookInput();
  if (!isSubagent(input)) {
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const resolved = resolveConfig(cwd);
    const repoBasename = teamPrefix(cwd, resolved.team);
    const dir = hierarchyDir(cwd);
    const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};

    if (input.tool_name === "ListAgents") {
      const lines = responseText(input.tool_response).split("\n");
      const headerAt = lines.findIndex((l) => /peer sessions/i.test(l));
      const scan = headerAt >= 0 ? lines.slice(headerAt + 1) : lines;
      for (const line of scan) {
        const m = line.match(LINE_RE);
        if (!m) continue;
        const name = m[1].trim();
        const role = roleForAnyPeerName(dir, name, resolved, repoBasename);
        if (!role) continue;
        appendRosterRecord(dir, { status: "seen", name, ref: m[2], role, busy: m[4] === "busy", team: teamTagFor(dir, name) });
      }
    } else if (input.tool_name === "SendMessage") {
      const message = typeof toolInput.message === "string" ? toolInput.message : "";
      const sentinel = parseSentinel(message);
      const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
      if (sentinel && to) {
        const role = roleForAnyPeerName(dir, to, resolved, repoBasename);
        appendRosterRecord(dir, { status: "briefed", name: to, role, task: sentinel.task || null, team: teamTagFor(dir, to) });
      }
    }
  }
} catch {
  // fail open
}
process.exit(0);
