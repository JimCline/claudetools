#!/usr/bin/env node
/**
 * agent-hierarchy — hand-rolled stdio MCP server (spec 0013).
 *
 * Newline-delimited JSON-RPC 2.0 over stdio, zero dependencies — the only
 * client is Claude Code itself, so the full MCP SDK (17 direct deps, an
 * HTTP+OAuth stack this server never uses) was rejected in favor of this.
 *
 * Every tool is a thin exec of the real msg.mjs/roster.mjs CLI scripts —
 * this file never reimplements their logic, only maps CLI exit code/stdout/
 * stderr onto an MCP tool result. `cwd` is required on every tool call and
 * is never defaulted to this process's own cwd, which is frozen at spawn
 * for the server's whole lifetime and does not track the session's cwd.
 *
 * `gate_status` (wrapping gate.mjs status) is deliberately absent: spec 0013
 * §8.3 rules it out on independent merits — chiefly that GATE_CLI is already
 * a resolved absolute path constant (lib-config.mjs:41), so this spec's path-
 * resolution problem was already solved for gate.mjs before 0013 existed.
 */

import { execFileSync, spawn } from "node:child_process";
import { appendFileSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const MSG_CLI = join(HERE, "..", "hooks", "msg.mjs");
const ROSTER_CLI = join(HERE, "..", "hooks", "roster.mjs");

// The session pid, captured at startup (spec 0018 §4.1): this server is a direct child of the
// Claude Code session, and CLAUDE_PID is not exported to MCP server subprocesses. Read once —
// after the parent exits this process is reparented (typically to pid 1), which reads as alive
// forever; capturing later would stamp a lie, so it is captured exactly once, here, and never
// re-read.
const PPID_AT_STARTUP = process.ppid;
const SESSION_PID = PPID_AT_STARTUP === 1 ? null : PPID_AT_STARTUP;

const PROTOCOL_VERSION = "2024-11-05";
let PLUGIN_MANIFEST;
try {
  PLUGIN_MANIFEST = JSON.parse(readFileSync(join(HERE, "..", ".claude-plugin", "plugin.json"), "utf8"));
} catch {
  PLUGIN_MANIFEST = { version: "unknown" };
}

// ---------------------------------------------------------------------------
// Lifecycle log (spec 0047 §3.2).
//
// One append-only JSONL file. Deliberately ONE global path rather than
// lib-config's `hierarchyDir(cwd)`: that resolver is per-cwd (git root first),
// and under §4 a single daemon serves every cwd at once, so a per-cwd log would
// scatter one process's lifetime across directories. AGENT_HIERARCHY_DIR still
// overrides, the way every hook honours it.
//
// Nothing here may throw: a server that dies because it could not write its own
// diagnostic log is the failure this log exists to diagnose.
// ---------------------------------------------------------------------------
const LOG_DIR = process.env.AGENT_HIERARCHY_DIR
  ? resolve(process.env.AGENT_HIERARCHY_DIR.trim())
  : join(homedir(), ".claude", "hierarchy");
const LOG_PATH = join(LOG_DIR, "mcp-server.log");
const LOG_CAP_BYTES = 1024 * 1024;
const SERVER_ROOT = join(HERE, "..");
const STARTED_AT = new Date().toISOString();

let TRANSPORT = "stdio";
let IDENTITY_METHOD = "ppid";

function logEvent(event, extra) {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    appendFileSync(
      LOG_PATH,
      JSON.stringify({
        ts: new Date().toISOString(),
        event,
        pid: process.pid,
        transport: TRANSPORT,
        version: PLUGIN_MANIFEST.version,
        ...(extra || {}),
      }) + "\n",
    );
  } catch {
    // A log write must never affect the server. No stderr either: in stdio mode
    // the harness surfaces stderr, and a noisy disk error would bury the real one.
  }
}

/** §3.2 size cap: one generation, checked once at `start`. No rotation library, no scheduler. */
function capLog() {
  try {
    if (statSync(LOG_PATH).size > LOG_CAP_BYTES) renameSync(LOG_PATH, LOG_PATH + ".1");
  } catch {
    // Missing file is the common case, not an error.
  }
}

function logStart(extra) {
  capLog();
  logEvent("start", {
    // The startup capture, never a fresh read: after the parent exits this process
    // is reparented, so reading again here would stamp a different and meaningless
    // number into the log (spec 0018 §4.1).
    ppid: PPID_AT_STARTUP,
    // Under HTTP the session pid is per-MCP-session, not per-process: claiming one
    // here would be a lie about whichever client connects first.
    session_pid: TRANSPORT === "stdio" ? SESSION_PID : null,
    identity: IDENTITY_METHOD,
    node: process.version,
    exec: process.execPath,
    root: SERVER_ROOT,
    cwd: process.cwd(),
    argv: process.argv.slice(1),
    ...(extra || {}),
  });
}

/**
 * §3.3: log and then do the conventional thing. A signal handler that swallows
 * its signal would make the harness's "exited cleanly" line a lie, and a server
 * left hung after an uncaught throw is worse than one that is simply gone.
 */
function installProcessHandlers() {
  process.on("uncaughtException", (err) => {
    logEvent("uncaught", { message: err && err.message ? err.message : String(err), stack: err && err.stack ? err.stack : null });
    process.exit(1);
  });
  process.on("unhandledRejection", (reason) => {
    const err = reason instanceof Error ? reason : null;
    logEvent("unhandled", { message: err ? err.message : String(reason), stack: err ? err.stack : null });
    process.exit(1);
  });
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => {
      logEvent("signal", { signal: sig });
      onShutdown(sig);
    });
  }
  process.on("exit", (code) => logEvent("exit", { code }));
}

/** Replaced by the HTTP transport so SIGTERM can close the listener first (§4.3). */
let onShutdown = (sig) => process.exit(sig === "SIGINT" ? 130 : 0);

const cwdSchema = {
  type: "string",
  description: "Absolute path to the repo/session working directory. Required on every call — never defaults to the server's own cwd.",
};

const teamSchema = { type: "string", description: "Named team scope, if any." };

const levelSchema = { type: "string", enum: ["global", "repo", "repo-user"] };

export const TOOLS = [
  {
    name: "msg_new",
    description: "Create a new hierarchy message file (request or response) via msg.mjs new.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        to: { type: "string", description: "Recipient role." },
        from: { type: "string", description: "Sender role." },
        slug: { type: "string", description: "Short slug for the message." },
        to_name: { type: "string", description: "Recipient instance/session name." },
        from_name: { type: "string", description: "Sender instance/session name." },
        parent: { type: "string", description: "Parent message id, to link a follow-up." },
        reason: { type: "string", description: "context|second-opinion|parallel" },
        eta: { type: "string", enum: ["small", "medium", "large"], description: "Expected turnaround: small=5min, medium=10min, large=20min. Only meaningful on a request." },
        type: { type: "string", description: "request|response (default request)." },
        id: { type: "string", description: "Explicit message id — set when writing a response to match its request." },
        req_path: { type: "string", description: "Response only: the request file's ABSOLUTE path (the brief's [hierarchy-msg] value, verbatim). The response is written beside it, cross-checked against its frontmatter — never into this session's own pool (spec 0037)." },
        team: teamSchema,
      },
      required: ["cwd", "to", "from", "slug"],
    },
  },
  {
    name: "msg_list",
    description: "List hierarchy message exchanges via msg.mjs list.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        filter: { type: "string", enum: ["open", "closed", "all"], description: "Default open." },
        to: { type: "string", description: "Filter by recipient role." },
        team: teamSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "msg_downstream",
    description: "List requests dispatched by a session other than the one that rooted their parent chain, via msg.mjs downstream.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        root_name: { type: "string", description: "Filter to rows whose root requester's from_name equals this." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "msg_index",
    description: "List numbered section anchors in a message file via msg.mjs index.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        path: { type: "string", description: "Absolute path to the message file." },
      },
      required: ["cwd", "path"],
    },
  },
  {
    name: "msg_roster",
    description: "Show live/stale peer roster status via msg.mjs roster.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "roster_show",
    description: "[/agent-roster — roster TEMPLATE] Show the resolved roster, or one level's raw file, via roster.mjs show. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: { ...levelSchema, description: "Show one level's raw file instead of the resolved (winning) roster." },
        team: teamSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_list",
    description: "[/agent-team — live Team] List every team in the hierarchy dir via roster.mjs teams. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        orchestrator_pid: { type: "integer", description: "Override for the `own` field's identity check. Defaults to the calling session's pid, derived automatically." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "roster_init",
    description: "[/agent-roster — roster TEMPLATE] Initialise a roster level via roster.mjs member init. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team — it launches nothing and terminates nothing. Refused while this session owns a live team (spec 0044 §1.3): to add a member to the RUNNING team, use team_spawn_ad_hoc.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        route: { type: "string", enum: ["peer", "subagent", "pane"], description: "\"pane\" means the member is driven through its Herdr pane rather than SendMessage, and is required for any non-claude kind (spec 0043 §1.5)." },
        layout: { type: "string", enum: ["auto", "columns", "grid"] },
      },
      required: ["cwd", "route"],
    },
  },
  {
    name: "roster_add",
    description: "[/agent-roster — roster TEMPLATE] Add a member to the roster via roster.mjs member add. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team — it launches nothing and terminates nothing. Refused while this session owns a live team (spec 0044 §1.3): to add a member to the RUNNING team, use team_spawn_ad_hoc.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        role: { type: "string", description: "Required." },
        model: { type: "string", description: "kind claude only — rejected for any other kind (spec 0043 §1.3)." },
        effort: { type: "string", description: "kind claude only." },
        auto_mode: { type: "string", description: "kind claude only." },
        kind: { type: "string", description: "Which agent CLI Herdr starts for this member (claude, codex, pi, …). Omitted means claude. Any non-claude kind requires route \"pane\", the herdr transport, and no model/effort/auto_mode (spec 0043)." },
        args: { type: "array", items: { type: "string" }, description: "Native CLI arguments passed verbatim after herdr's `--`. Non-claude kinds only (spec 0043 §1.9)." },
        on_missing: { type: "string", enum: ["auto", "prompt", "never"], description: "Peer-routed members only." },
      },
      required: ["cwd", "role"],
    },
  },
  {
    name: "roster_edit",
    description: "[/agent-roster — roster TEMPLATE] Edit an existing roster member via roster.mjs member edit. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team — it launches nothing and terminates nothing. Refused while this session owns a live team (spec 0044 §1.3): to add a member to the RUNNING team, use team_spawn_ad_hoc.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        member: { type: "string", description: "The member's derived name. Required." },
        model: { type: "string", description: "kind claude only." },
        effort: { type: "string", description: "kind claude only." },
        auto_mode: { type: "string", description: "kind claude only." },
        kind: { type: "string" },
        args: { type: "array", items: { type: "string" }, description: "Non-claude kinds only." },
        on_missing: { type: "string", enum: ["auto", "prompt", "never"] },
      },
      required: ["cwd", "member"],
    },
  },
  {
    name: "roster_remove",
    description: "[/agent-roster — roster TEMPLATE] Remove a member from the roster via roster.mjs member remove. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team — it launches nothing and terminates nothing. Refused while this session owns a live team (spec 0044 §1.3): to add a member to the RUNNING team, use team_spawn_ad_hoc. To close a RUNNING member's session, use team_dismiss.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        member: { type: "string", description: "The member's derived name. Required." },
      },
      required: ["cwd", "member"],
    },
  },
  {
    name: "roster_layout",
    description: "[/agent-roster — roster TEMPLATE] Show or set a roster level's pane layout via roster.mjs config layout. Omit `layout` to read. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team. Refused while this session owns a live team (spec 0044 §1.3).",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        layout: { type: "string", enum: ["auto", "columns", "grid"], description: "Omit to read." },
        team: teamSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "roster_alias",
    description: "[/agent-roster — roster TEMPLATE] Show, set, or clear this repo's team-name alias via roster.mjs config alias. Edits the TEMPLATE for FUTURE teams and does NOT affect a running team. Refused while this session owns a live team (spec 0044 §1.3).",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        level: levelSchema,
        set: { type: "string", description: "New alias." },
        clear: { type: "boolean" },
        team: teamSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_create",
    description: "[/agent-team — live Team] Plan, spawn, or commit a Team from the EXISTING roster (roster_show) via roster.mjs create — an instance, not a roster edit. Do not call roster_add/roster_edit first unless the roster's member list itself is wrong or missing.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        mode: { type: "string", enum: ["plan", "spawn", "commit"] },
        team: teamSchema,
        roster_level: { type: "string" },
        layout_mode: { type: "string", description: "Layout mode, with mode: spawn." },
        orchestrator_pid: { type: "integer", description: "Override, with mode: commit. Defaults to the calling session's pid, derived automatically — supply only to override." },
        orchestrator_session_id: { type: "string", description: "Optional, with mode: commit." },
        transport: { type: "string", description: "With mode: commit." },
        verified: { type: "string", description: "JSON array, passed to --verified verbatim. Required with mode: commit. Either a JSON array of member objects (from the spawn/check-in cycle) or a JSON array of member-name strings (hydrated from the roster)." },
        partial: { type: "boolean", description: "With mode: commit." },
      },
      required: ["cwd", "mode"],
    },
  },
  {
    name: "team_adopt",
    description: "[/agent-team — live Team] Re-stamp orchestrator.pid on an existing, orphaned team file via roster.mjs adopt. Recovery only — refuses to hijack a live team.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        orchestrator_pid: { type: "integer", description: "Defaults to the calling session's pid, derived automatically — supply only to override." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_reap",
    description: "[/agent-team — live Team] List orphaned team records (mode: plan, default, read-only), or remove them (mode: commit). A team is orphaned when its orchestrator process is gone. Never touches a team whose orchestrator is alive.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        mode: { type: "string", enum: ["plan", "commit"], description: "Default plan." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_layout_splits",
    description: "[/agent-team — live Team] Run or drive the herdr layout-splits phase via roster.mjs layout-splits.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        mode: { type: "string", enum: ["auto", "columns", "grid"] },
        pane_count: { type: "integer" },
        next: { type: "boolean", description: "Compute the next decision without splitting." },
        created: { type: "string", description: "JSON array of pane ids already created, with next: true." },
        apply: { type: "boolean", description: "Perform one split directly." },
        target: { type: "string", description: "Pane id, with apply: true." },
        direction: { type: "string", enum: ["right", "down"], description: "With apply: true." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_disband",
    description: "[/agent-team — live Team] CLOSE EVERY MEMBER'S SESSION and drop the team record. This is what \"disband the team\" / \"close the team\" / \"tear down the team\" mean. Destructive: mode:plan is read-only and returns the close list plus a close_token; mode:close needs confirm:true and that token, and the harness asks the user once. On success the team file is removed; if some closes fail the file is rewritten minus the ones that closed and partial:true is reported. The close list is team.json's members plus any live peer attributed to this team (spec 0046 §2.2). To forget the record WITHOUT closing anything, use team_untrack.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        mode: { type: "string", enum: ["plan", "close"], description: "Default plan." },
        confirm: { type: "boolean", description: "Required with mode:close, and only after the user has been shown the close list and agreed." },
        plan_token: { type: "string", description: "close_token from the preceding team_disband mode:plan call. Required with mode:close." },
        allow_global: { type: "boolean" },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_untrack",
    description: "[/agent-team — live Team] Forget a tracking record WITHOUT touching any session — the non-destructive counterpart to team_dismiss/team_disband. Use it only when the user says to KEEP the session running (\"leave it up\", \"just stop tracking it\"), or when the member is already dead. On a live target it REFUSES unless keep_sessions:true, because forgetting a live session leaves it running with nothing naming it; the record cannot be recovered. Untracking something already gone succeeds with already_untracked:true.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        name: { type: "string", description: "A team.json member name. A live session that team.json never recorded has no record to forget — team_dismiss closes it." },
        all: { type: "boolean", description: "Forget the whole team file instead of one member." },
        mode: { type: "string", enum: ["plan", "commit"], description: "Default plan." },
        keep_sessions: { type: "boolean", description: "Required to untrack a target that is live or whose liveness cannot be determined. Says: yes, leave it running untracked." },
        also_config: { type: "boolean", description: "Single member only. ALSO remove it from the roster TEMPLATE (spec 0044 §8.1)." },
        level: { type: "string", description: "With also_config." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_resync",
    description: "[/agent-team — live Team] Re-derive every peer member's herdr location from live topology via roster.mjs resync.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        dry_run: { type: "boolean" },
        bind: { type: "string" },
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_move",
    description: "[/agent-team — live Team] Relocate a member's pane via roster.mjs move.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        name: { type: "string", description: "The member's derived name." },
        tab: { type: "string" },
        split: { type: "string", enum: ["right", "down"], description: "Required with tab." },
        new_tab: { type: "boolean" },
        workspace: { type: "string", description: "With new_tab." },
        new_workspace: { type: "boolean" },
        dry_run: { type: "boolean" },
        allow_global: { type: "boolean" },
      },
      required: ["cwd", "name"],
    },
  },
  {
    name: "team_history",
    description: "[/agent-team — live Team] List recent team-history entries (for reuse via 'create --from') via roster.mjs history. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "team_spawn_one",
    description: "[/agent-team — live Team] Spawn or restart one missing/dead peer role (e.g. 'spawn the architect') without touching the rest of the team.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        role: { type: "string" },
        member: { type: "string", description: "Derived member name, to disambiguate two same-role roster members." },
        dry_run: { type: "boolean" },
        allow_global: { type: "boolean" },
        orchestrator_pid: { type: "integer", description: "Owner pid when this call creates a new team. Defaults to the calling session's pid, derived automatically — supply only to override." },
      },
      required: ["cwd", "role"],
    },
  },
  {
    name: "team_spawn_ad_hoc",
    description:
      "[/agent-team — live Team] Spawn a team member the roster does NOT define, or one whose parameters diverge from it (different model, effort, kind, args, or route) — e.g. 'spawn a codex reviewer just for this task'. Writes only the team file; the roster template is never touched, whatever the divergence. Use this instead of editing the roster when a running team needs a member the roster does not describe.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        role: { type: "string", description: "The member's role. Need not appear in the roster." },
        model: { type: "string", description: "kind claude only — rejected for any other kind (spec 0043 §1.3)." },
        effort: { type: "string", description: "kind claude only." },
        route: { type: "string", enum: ["peer", "pane"], description: "Defaults to peer. A subagent-routed member has no session to spawn." },
        auto_mode: { type: "string", description: "kind claude only." },
        kind: { type: "string", description: "Which agent CLI Herdr starts (claude, codex, pi, …). Omitted means claude. Any non-claude kind requires route \"pane\" and no model/effort/auto_mode." },
        args: { type: "array", items: { type: "string" }, description: "Native CLI arguments passed verbatim after herdr's `--`. Non-claude kinds only." },
        on_missing: { type: "string", enum: ["auto", "prompt", "never"], description: "Peer-routed members only." },
        dry_run: { type: "boolean" },
        allow_global: { type: "boolean" },
        orchestrator_pid: { type: "integer", description: "Owner pid when this call creates a new team. Defaults to the calling session's pid, derived automatically — supply only to override." },
      },
      required: ["cwd", "role"],
    },
  },
  {
    name: "team_dismiss",
    description: "[/agent-team — live Team] CLOSE ONE MEMBER'S SESSION and drop its row. This is what \"dismiss the architect\" / \"remove the implementor\" / \"drop that member\" mean on a LIVE member. Destructive: mode:plan is read-only and returns the member, its liveness and a close_token; mode:close needs confirm:true and that token, and the harness asks the user once. On a successful close the team.json row is removed (untracked:true); on failure the row stays. `name` accepts any identifier the user can see for a live session — the derived member name, a pane_id, a session_id or a unique 8+ char prefix of one, the role@sid8 form team_list prints, or the herdr display name (spec 0046 §2.4). A dead member cannot be closed: use team_untrack.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        name: { type: "string", description: "The member's derived name, or any identifier team_list shows for a live untracked session (pane_id, session_id or 8+ char prefix, role@sid8, herdr display name)." },
        mode: { type: "string", enum: ["plan", "close"], description: "Default plan." },
        confirm: { type: "boolean", description: "Required with mode:close, and only after the user has been shown the close list and agreed." },
        plan_token: { type: "string", description: "close_token from the preceding team_dismiss mode:plan call. Required with mode:close." },
        allow_global: { type: "boolean" },
        also_config: { type: "boolean", description: "With mode:close, ALSO remove the member from the roster TEMPLATE. Opt-in; shifts later same-role ordinals (spec 0044 §8.1)." },
        level: { type: "string", description: "With also_config." },
      },
      required: ["cwd", "name"],
    },
  },
];

const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));

/**
 * Pure exit-code/stdout/stderr → MCP tool-result mapper (spec 0013 §6.2).
 * Exported so tests can exercise the mapping directly with synthetic inputs,
 * independent of which real CLI invocation (if any) produces a given case.
 */
export function mapExecResult({ code, stdout, stderr, scriptPath, expectedNonZero }) {
  if (code === 0) {
    const text = stderr && stderr.trim() ? `${stdout}\nstderr:\n${stderr}` : stdout;
    return { content: [{ type: "text", text }] };
  }
  if (expectedNonZero && expectedNonZero.has(code)) {
    // Spec 0016 §5: an expected non-zero exit (e.g. layout-splits' partial exit 3) is data, not
    // an error — the full stdout payload (`complete: false`, `panes`, `failed_at`, ...) must
    // survive, prefixed with the exit code the way exit 2 already prefixes `exit=2`.
    const text = stderr && stderr.trim() ? `exit=${code}\n${stdout}\nstderr:\n${stderr}` : `exit=${code}\n${stdout}`;
    return { content: [{ type: "text", text }] };
  }
  if (code === 2) {
    return { content: [{ type: "text", text: `exit=2\n${stderr}` }], isError: true };
  }
  return {
    content: [{ type: "text", text: `spawn/exit failure (exit=${code}) invoking ${scriptPath}\n${stderr}` }],
    isError: true,
  };
}

function execCli(scriptPath, args, expectedNonZero) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(process.execPath, [scriptPath, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      logEvent("exec-error", { script: scriptPath, code: (err && err.code) || null, message: err && err.message ? err.message : String(err) });
      resolve(mapExecResult({ code: -1, stdout: "", stderr: String(err && err.message ? err.message : err), scriptPath, expectedNonZero }));
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      logEvent("exec-error", { script: scriptPath, code: (err && err.code) || null, message: err && err.message ? err.message : String(err) });
      resolve(mapExecResult({ code: -1, stdout, stderr: stderr || String(err && err.message ? err.message : err), scriptPath, expectedNonZero }));
    });
    child.on("close", (code) => {
      // Trigger (ii), spec 0047 §3.2 r2: spawning process.execPath always succeeds — the
      // executable exists by definition — so a deleted install dir surfaces as node's own
      // module resolution failing, not as a spawn error. This is the only way shape C′
      // reaches the lifecycle log.
      if (code !== 0) {
        const missing = /(?:ERR_MODULE_NOT_FOUND|Cannot find module)[^'"\n]*['"]([^'"]+)['"]/.exec(stderr);
        if (missing || /ERR_MODULE_NOT_FOUND|Cannot find module/.test(stderr)) {
          logEvent("exec-error", { script: scriptPath, code: "MODULE_NOT_FOUND", missing: missing ? missing[1] : null });
        }
      }
      resolve(mapExecResult({ code, stdout, stderr, scriptPath, expectedNonZero }));
    });
  });
}

function pushArg(args, flag, value) {
  if (value === undefined || value === null || value === "") return;
  args.push(`--${flag}`, String(value));
}

/** Bare-boolean CLI flags (`--dry-run`, `--next`, ...) — `pushArg` only emits `--flag value`. */
function pushFlag(args, flag, value) {
  if (value === true) args.push(`--${flag}`);
}

function err(text) {
  return { content: [{ type: "text", text }], isError: true };
}

/**
 * @param sessionPid The calling session's pid for the seven team_* tools that record an
 *   owner (spec 0018). Under stdio it is this process's parent; under the §4 HTTP daemon
 *   it is per-MCP-session and must be passed in, because the daemon has no session parent.
 */
export async function callTool(name, input, sessionPid = SESSION_PID) {
  const args_in = input && typeof input === "object" ? input : {};
  const cwd = args_in.cwd;
  if (typeof cwd !== "string" || !cwd.trim()) {
    return { content: [{ type: "text", text: `${name}: "cwd" is required and must be a non-empty string.` }], isError: true };
  }

  switch (name) {
    case "msg_new": {
      const args = ["new"];
      pushArg(args, "to", args_in.to);
      pushArg(args, "from", args_in.from);
      pushArg(args, "slug", args_in.slug);
      pushArg(args, "to-name", args_in.to_name);
      pushArg(args, "from-name", args_in.from_name);
      pushArg(args, "parent", args_in.parent);
      pushArg(args, "reason", args_in.reason);
      pushArg(args, "eta", args_in.eta);
      pushArg(args, "type", args_in.type);
      pushArg(args, "id", args_in.id);
      pushArg(args, "req", args_in.req_path);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(MSG_CLI, args);
    }
    case "msg_list": {
      const args = ["list"];
      if (args_in.filter === "closed") args.push("--closed");
      else if (args_in.filter === "all") args.push("--all");
      pushArg(args, "to", args_in.to);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(MSG_CLI, args);
    }
    case "msg_downstream": {
      const args = ["downstream"];
      pushArg(args, "root-name", args_in.root_name);
      pushArg(args, "cwd", cwd);
      return execCli(MSG_CLI, args);
    }
    case "msg_index": {
      if (typeof args_in.path !== "string" || !args_in.path.trim()) {
        return { content: [{ type: "text", text: 'msg_index: "path" is required and must be a non-empty string.' }], isError: true };
      }
      const args = ["index", args_in.path];
      pushArg(args, "cwd", cwd);
      return execCli(MSG_CLI, args);
    }
    case "msg_roster": {
      const args = ["roster"];
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(MSG_CLI, args);
    }
    case "roster_show": {
      const args = ["show"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_list": {
      const args = ["teams"];
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_init": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.action !== undefined) return err('roster_init: "action" is not a parameter — the roster_member tool was split in 0046; this tool IS the action.');
      if (!args_in.level) return err('roster_init: "level" is required.');
      if (!args_in.route) return err('roster_init: "route" is required.');
      const args = ["init"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "route", args_in.route);
      pushArg(args, "layout", args_in.layout);
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_add": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.action !== undefined) return err('roster_add: "action" is not a parameter — the roster_member tool was split in 0046; this tool IS the action.');
      if (!args_in.role) return err('roster_add: "role" is required.');
      // Spec 0044 §1.10 R1/R3: `no_spawn`, `allow_global` and `orchestrator_pid` are still
      // ACCEPTED and ignored — `add` no longer spawns — but stay out of the schema, because a
      // documented `no_spawn` asserts that spawning is what happens without it.
      const args = ["add"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "role", args_in.role);
      pushArg(args, "model", args_in.model);
      pushArg(args, "effort", args_in.effort);
      pushArg(args, "route", args_in.route);
      pushArg(args, "auto-mode", args_in.auto_mode);
      pushArg(args, "on-missing", args_in.on_missing);
      pushArg(args, "kind", args_in.kind);
      if (args_in.args !== undefined && args_in.args !== null) pushArg(args, "args", JSON.stringify(args_in.args));
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_edit": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.action !== undefined) return err('roster_edit: "action" is not a parameter — the roster_member tool was split in 0046; this tool IS the action.');
      if (!args_in.member) return err('roster_edit: "member" is required.');
      const args = ["edit"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "member", args_in.member);
      pushArg(args, "role", args_in.role);
      pushArg(args, "model", args_in.model);
      pushArg(args, "effort", args_in.effort);
      pushArg(args, "route", args_in.route);
      pushArg(args, "auto-mode", args_in.auto_mode);
      pushArg(args, "on-missing", args_in.on_missing);
      pushArg(args, "kind", args_in.kind);
      if (args_in.args !== undefined && args_in.args !== null) pushArg(args, "args", JSON.stringify(args_in.args));
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_remove": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.action !== undefined) return err('roster_remove: "action" is not a parameter — the roster_member tool was split in 0046; this tool IS the action.');
      if (!args_in.member) return err('roster_remove: "member" is required.');
      const args = ["remove"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "member", args_in.member);
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_layout": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.target !== undefined) return err('roster_layout: "target" is not a parameter — the roster_config tool was split in 0046; this tool IS the target.');
      const args = ["layout"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "layout", args_in.layout);
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_alias": {
      // Spec 0046 §6.2: the discriminator is gone with the split. A stray one means the caller is
      // still working from the old single-tool schema, so say so rather than silently ignoring it.
      if (args_in.target !== undefined) return err('roster_alias: "target" is not a parameter — the roster_config tool was split in 0046; this tool IS the target.');
      const args = ["alias"];
      pushArg(args, "level", args_in.level);
      pushArg(args, "set", args_in.set);
      pushFlag(args, "clear", args_in.clear);
      pushArg(args, "team", args_in.team);
      pushArg(args, "orchestrator-pid", sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_create": {
      const mode = args_in.mode;
      if (mode !== "plan" && mode !== "spawn" && mode !== "commit") {
        return { content: [{ type: "text", text: `team_create: "mode" must be one of plan, spawn, commit, got ${JSON.stringify(mode)}` }], isError: true };
      }
      if (mode === "commit" && typeof args_in.verified !== "string") {
        return { content: [{ type: "text", text: 'team_create: mode "commit" requires "verified" (a JSON array string).' }], isError: true };
      }
      const args = ["create", `--${mode}`];
      pushArg(args, "team", args_in.team);
      pushArg(args, "roster-level", args_in.roster_level);
      if (mode === "spawn") {
        pushArg(args, "mode", args_in.layout_mode);
      }
      if (mode === "commit") {
        pushArg(args, "transport", args_in.transport);
        pushArg(args, "verified", args_in.verified);
        // Spec 0018 §4.2: explicit param wins, else the pid captured at server startup.
        pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? sessionPid);
        pushArg(args, "session", args_in.orchestrator_session_id);
        pushFlag(args, "partial", args_in.partial);
      }
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_layout_splits": {
      const args = ["layout-splits"];
      pushArg(args, "mode", args_in.mode);
      pushArg(args, "pane-count", args_in.pane_count);
      pushFlag(args, "next", args_in.next);
      pushArg(args, "created", args_in.created);
      pushFlag(args, "apply", args_in.apply);
      pushArg(args, "target", args_in.target);
      pushArg(args, "direction", args_in.direction);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args, new Set([3]));
    }
    case "team_disband": {
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "close") return err(`team_disband: "mode" must be one of plan, close, got ${JSON.stringify(mode)}`);
      const args = ["disband"];
      if (mode === "close") {
        if (args_in.confirm !== true) return err('team_disband: "confirm" must be true, and only after the user has been shown the close list and agreed.');
        if (typeof args_in.plan_token !== "string" || !args_in.plan_token.trim()) return err('team_disband: "plan_token" is required — pass the close_token from a preceding team_disband mode:plan call.');
        args.push("--close", "--confirm", "--plan-token", args_in.plan_token);
        pushFlag(args, "allow-global", args_in.allow_global);
      }
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_resync": {
      const args = ["resync"];
      pushFlag(args, "dry-run", args_in.dry_run);
      pushArg(args, "team", args_in.team);
      pushArg(args, "bind", args_in.bind);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_move": {
      if (typeof args_in.name !== "string" || !args_in.name.trim()) {
        return { content: [{ type: "text", text: 'team_move: "name" is required.' }], isError: true };
      }
      const args = ["move", args_in.name];
      pushArg(args, "tab", args_in.tab);
      pushArg(args, "split", args_in.split);
      pushFlag(args, "new-tab", args_in.new_tab);
      pushArg(args, "workspace", args_in.workspace);
      pushFlag(args, "new-workspace", args_in.new_workspace);
      pushFlag(args, "dry-run", args_in.dry_run);
      pushFlag(args, "allow-global", args_in.allow_global);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_history": {
      const args = ["history"];
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_spawn_one": {
      if (typeof args_in.role !== "string" || !args_in.role.trim()) {
        return { content: [{ type: "text", text: 'team_spawn_one: "role" is required.' }], isError: true };
      }
      const args = ["spawn-one", args_in.role];
      pushArg(args, "member", args_in.member);
      pushFlag(args, "dry-run", args_in.dry_run);
      pushFlag(args, "allow-global", args_in.allow_global);
      pushArg(args, "team", args_in.team);
      // Spec 0018 §4.2: explicit param wins, else the pid captured at server startup.
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_spawn_ad_hoc": {
      if (!args_in.role) {
        return { content: [{ type: "text", text: 'team_spawn_ad_hoc: "role" is required.' }], isError: true };
      }
      const args = ["spawn-ad-hoc"];
      pushArg(args, "role", args_in.role);
      pushArg(args, "model", args_in.model);
      pushArg(args, "effort", args_in.effort);
      pushArg(args, "route", args_in.route);
      pushArg(args, "auto-mode", args_in.auto_mode);
      pushArg(args, "on-missing", args_in.on_missing);
      pushArg(args, "kind", args_in.kind);
      // Same encoding roster_add uses: a real array on the wire, a JSON string on the CLI.
      if (args_in.args !== undefined && args_in.args !== null) pushArg(args, "args", JSON.stringify(args_in.args));
      pushArg(args, "team", args_in.team);
      pushFlag(args, "dry-run", args_in.dry_run);
      pushFlag(args, "allow-global", args_in.allow_global);
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? sessionPid);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_dismiss": {
      if (typeof args_in.name !== "string" || !args_in.name.trim()) return err('team_dismiss: "name" is required.');
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "close") return err(`team_dismiss: "mode" must be one of plan, close, got ${JSON.stringify(mode)}`);
      const args = ["dismiss", args_in.name];
      if (mode === "close") {
        if (args_in.confirm !== true) return err('team_dismiss: "confirm" must be true, and only after the user has been shown the close list and agreed.');
        if (typeof args_in.plan_token !== "string" || !args_in.plan_token.trim()) return err('team_dismiss: "plan_token" is required — pass the close_token from a preceding team_dismiss mode:plan call.');
        args.push("--close", "--confirm", "--plan-token", args_in.plan_token);
        pushFlag(args, "allow-global", args_in.allow_global);
      }
      pushFlag(args, "also-config", args_in.also_config);
      pushArg(args, "level", args_in.level);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_untrack": {
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "commit") return err(`team_untrack: "mode" must be one of plan, commit, got ${JSON.stringify(mode)}`);
      const named = typeof args_in.name === "string" && args_in.name.trim();
      if (!named && args_in.all !== true) return err('team_untrack: pass "name" for one member, or all:true for the whole team record.');
      if (named && args_in.all === true) return err('team_untrack: pass "name" or all:true, not both.');
      const args = ["untrack"];
      if (named) args.push(args_in.name);
      else args.push("--all");
      args.push(mode === "commit" ? "--commit" : "--plan");
      pushFlag(args, "keep-sessions", args_in.keep_sessions);
      pushFlag(args, "also-config", args_in.also_config);
      pushArg(args, "level", args_in.level);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_adopt": {
      const args = ["adopt"];
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? sessionPid);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "team_reap": {
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "commit") {
        return { content: [{ type: "text", text: `team_reap: "mode" must be one of plan, commit, got ${JSON.stringify(mode)}` }], isError: true };
      }
      const args = ["reap"];
      if (mode === "commit") args.push("--commit");
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    default:
      return { content: [{ type: "text", text: `unknown tool ${JSON.stringify(name)}` }], isError: true };
  }
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

/**
 * The single JSON-RPC method implementation both transports drive (spec 0047 §4.2).
 * Returns `{result}` or `{error}` — it never writes anywhere, so the stdio loop and
 * the HTTP handler cannot drift apart on what a method means.
 *
 * @param sessionPid the calling session's pid, per transport (§4.4).
 */
export async function dispatch(method, params, sessionPid = SESSION_PID) {
  if (method === "initialize") {
    return {
      result: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "ah", version: PLUGIN_MANIFEST.version },
        instructions:
          "To show/inspect the agent-hierarchy roster, call roster_show directly " +
          "(pass cwd) rather than shelling out — hand-rolled bash/cat reads only " +
          "the local .claude/agent-hierarchy.json and misses worktree/main-checkout " +
          "and global fallback resolution that roster_show already implements.",
      },
    };
  }
  if (method === "tools/list") return { result: { tools: TOOLS } };
  if (method === "tools/call") {
    const toolName = params && params.name;
    if (toolName === "__test_crash" && process.env.AH_MCP_TEST_CRASH === "1") {
      // Spec 0047 §7.1 test 2's only hook into the crash path. Thrown from a
      // macrotask on purpose: a throw returned through this function would be
      // caught and answered as -32603, which is the opposite of what the test
      // must observe. Without the env var the name is just an unknown tool.
      setImmediate(() => {
        throw new Error("AH_MCP_TEST_CRASH: deliberate handler throw");
      });
      return { result: { content: [{ type: "text", text: "crashing" }] } };
    }
    if (!TOOL_NAMES.has(toolName)) {
      return { error: { code: -32602, message: `unknown tool ${JSON.stringify(toolName)}` } };
    }
    return { result: await callTool(toolName, params && params.arguments, sessionPid) };
  }
  if (method === "ping") return { result: {} };
  if (method === "server/discover") {
    // Undocumented, but the harness POSTs it before `initialize` on an HTTP transport
    // (observed while running spec 0047 §6 E1/E2 against a probe daemon). An empty
    // result is what the probe answered on the run that connected successfully.
    return { result: {} };
  }
  return { error: { code: -32601, message: `method not found: ${JSON.stringify(method)}` } };
}

async function handleRequest(msg) {
  const { id, method, params } = msg;
  const res = await dispatch(method, params);
  if (res.error) sendError(id, res.error.code, res.error.message);
  else sendResult(id, res.result);
}

function isNotification(msg) {
  return msg && typeof msg === "object" && !("id" in msg);
}

function isValidRequestShape(msg) {
  return Boolean(msg) && typeof msg === "object" && !Array.isArray(msg) && typeof msg.method === "string";
}

// ---------------------------------------------------------------------------
// Identity under a shared daemon (spec 0047 §4.4).
//
// E1 result: `${CLAUDE_PID}` does NOT expand in a plugin manifest's `headers` —
// with CLAUDE_PID absent from the launching env the daemon receives the literal
// string, and when it IS present the value is the *parent* session's pid, not the
// connecting one. So method 1 is out and this, method 2, is the mechanism: resolve
// the client's ephemeral port back to the process that owns it.
// ---------------------------------------------------------------------------
function peerSessionPid(port) {
  if (!port) return null;
  try {
    const linux = process.platform === "linux";
    const out = linux
      ? execFileSync("ss", ["-tnpH", `sport = :${port}`], { encoding: "utf8", timeout: 2000 })
      : execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:ESTABLISHED", "-Fp"], { encoding: "utf8", timeout: 2000 });
    const pids = linux
      ? [...out.matchAll(/pid=(\d+)/g)].map((m) => Number(m[1]))
      : out.split("\n").filter((l) => l.startsWith("p")).map((l) => Number(l.slice(1)));
    // Both ends of a loopback connection own a socket on that port: the client's and
    // our own accepted one. Ours is the one we can name, so drop it and the remainder
    // is the client.
    const peers = [...new Set(pids.filter((p) => Number.isInteger(p) && p > 0 && p !== process.pid))];
    if (peers.length > 1) {
      // A forked client leaves several pids holding the same socket. The smallest is the
      // oldest, i.e. the session itself rather than anything it spawned (spec 0047 §12 F4).
      peers.sort((a, b) => a - b);
      logEvent("identity-ambiguous", { pids: peers, chosen: peers[0] });
    }
    return peers.length ? peers[0] : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Self-replacement on update (spec 0047 §4.3).
// ---------------------------------------------------------------------------
function installedAhRoot() {
  try {
    const j = JSON.parse(readFileSync(join(homedir(), ".claude", "plugins", "installed_plugins.json"), "utf8"));
    for (const [key, val] of Object.entries(j)) {
      if (!key.startsWith("ah@")) continue;
      for (const entry of Array.isArray(val) ? val : [val]) {
        if (entry && typeof entry.installPath === "string" && entry.installPath) return entry.installPath;
      }
    }
  } catch {
    // No manifest, or unreadable: treat as "not an installed lineage" and never replace.
  }
  return null;
}

function realOrNull(p) {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
}

/**
 * The root to re-exec from, or null to stay put (spec 0047 §4.3).
 *
 * Replace iff `installPath !== root` AND `dirname(installPath) === dirname(root)` —
 * both are version dirs under the same marketplace cache dir. The sibling-dir rule
 * admits a genuine version bump and excludes every `--plugin-dir` checkout; a
 * marketplace rename or a cache relocation does not self-replace either, and needs a
 * session restart.
 */
function replacementRoot() {
  const target = installedAhRoot();
  if (!target) return null;
  const a = realOrNull(target);
  const b = realOrNull(SERVER_ROOT);
  if (!a || !b || a === b) return null;
  if (dirname(a) !== dirname(b)) return null;
  return a;
}

function logFd() {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    return openSync(LOG_PATH, "a");
  } catch {
    return "ignore";
  }
}

function spawnDaemon(root) {
  const fd = logFd();
  const child = spawn(process.execPath, [join(root, "mcp", "server.mjs"), "--http"], {
    detached: true,
    stdio: ["ignore", fd, fd],
    env: process.env,
  });
  child.unref();
}

// ---------------------------------------------------------------------------
// HTTP transport (spec 0047 §4.2). Streamable HTTP, plain JSON responses only —
// no SSE is ever emitted. 127.0.0.1 only.
// ---------------------------------------------------------------------------
const DEFAULT_PORT = 7434;
const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const REPLACE_HEALTH_TIMEOUT_MS = 3000;
/**
 * Backoff after a failed self-replace (§12 F5′, Orchestrator r2.1). Without it a
 * permanently broken `next` root spawns one doomed child per request for as long as the
 * daemon lives. In-memory on purpose: a restarted daemon gets a fresh attempt.
 */
const REPLACE_RETRY_MS = 5 * 60 * 1000;

/**
 * Methods a request may carry with no `Mcp-Session-Id`. `initialize` obviously, and
 * `server/discover`, which the harness POSTs *before* `initialize` — no session can
 * exist yet (observed while running §6 E2).
 */
const SESSIONLESS_METHODS = new Set(["initialize", "server/discover"]);

function mcpPort() {
  const n = Number(process.env.AH_MCP_PORT);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_PORT;
}

function readBody(req) {
  return new Promise((done) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => done(body));
  });
}

function runHttp() {
  TRANSPORT = "http";
  IDENTITY_METHOD = "socket-peer";
  const port = mcpPort();
  const sessions = new Map();
  let replacing = false;
  let replaceFailedAt = 0;

  const newSession = (req) => {
    const id = `ah-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    const now = Date.now();
    sessions.set(id, { session_pid: peerSessionPid(req.socket.remotePort), created: now, lastSeen: now });
    return id;
  };

  const expire = () => {
    const cutoff = Date.now() - SESSION_TTL_MS;
    for (const [id, s] of sessions) if (s.lastSeen < cutoff) sessions.delete(id);
  };

  const server = createServer(async (req, res) => {
    const json = (code, obj, headers) => {
      res.writeHead(code, { "Content-Type": "application/json", ...(headers || {}) });
      res.end(JSON.stringify(obj));
    };

    if (req.method === "GET" && req.url.startsWith("/health")) {
      expire();
      json(200, {
        name: "ah",
        version: PLUGIN_MANIFEST.version,
        pid: process.pid,
        root: SERVER_ROOT,
        port,
        started: STARTED_AT,
        sessions: sessions.size,
        node: process.version,
        transport: "http",
        identity: IDENTITY_METHOD,
      });
      return;
    }
    if (req.method === "GET") {
      // No server-initiated stream: the harness asks for one, accepts the refusal and
      // carries on over POST (verified against a probe daemon, §6 E2).
      res.writeHead(405).end();
      return;
    }
    if (req.method === "DELETE") {
      const sid = req.headers["mcp-session-id"];
      if (sid) sessions.delete(String(sid));
      res.writeHead(200).end();
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405).end();
      return;
    }

    const raw = await readBody(req);
    let parsed;
    try {
      parsed = JSON.parse(raw || "null");
    } catch {
      json(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
      return;
    }
    const batch = Array.isArray(parsed) ? parsed : [parsed];
    if (!batch.length || !batch.every(isValidRequestShape)) {
      json(400, { jsonrpc: "2.0", id: null, error: { code: -32600, message: "invalid request" } });
      return;
    }

    expire();
    const sidHeader = req.headers["mcp-session-id"] ? String(req.headers["mcp-session-id"]) : null;
    const initializing = batch.some((m) => m.method === "initialize");
    // Gated per message, not per batch (spec 0047 §12 F6). A batch is only as exempt as
    // its least exempt member: `[initialize, tools/list]` with no session id must be
    // refused whole, or the initialize would smuggle the tools/list past the gate.
    const needsSession = batch.filter((m) => !SESSIONLESS_METHODS.has(m.method));
    let session = null;
    let issuedSid = null;

    if (needsSession.length) {
      if (!sidHeader) {
        json(400, { jsonrpc: "2.0", id: batch[0].id ?? null, error: { code: -32600, message: `Mcp-Session-Id header is required for ${needsSession.map((m) => m.method).join(", ")}` } });
        return;
      }
      session = sessions.get(sidHeader);
      if (!session) {
        json(404, { jsonrpc: "2.0", id: batch[0].id ?? null, error: { code: -32001, message: "unknown or expired Mcp-Session-Id" } });
        return;
      }
      session.lastSeen = Date.now();
    }
    if (initializing) {
      issuedSid = newSession(req);
      if (!session) session = sessions.get(issuedSid);
    }

    const sessionPid = session ? session.session_pid : null;
    const responses = [];
    for (const msg of batch) {
      if (isNotification(msg)) continue;
      const out = await dispatch(msg.method, msg.params, sessionPid);
      responses.push(out.error ? { jsonrpc: "2.0", id: msg.id, error: out.error } : { jsonrpc: "2.0", id: msg.id, result: out.result });
    }
    if (!responses.length) {
      res.writeHead(202).end();
    } else {
      json(200, Array.isArray(parsed) ? responses : responses[0], issuedSid ? { "Mcp-Session-Id": issuedSid } : undefined);
    }

    if (replacing) return;
    if (replaceFailedAt && Date.now() - replaceFailedAt < REPLACE_RETRY_MS) return;
    const next = replacementRoot();
    if (!next) return;
    replacing = true;
    // Order per spec 0047 §4.3 as amended by the Orchestrator r2.1 ruling (F5′): CLOSE
    // before spawning. §4.3's original "spawn first, then close" is a bind race — the
    // child inherits a port its own parent still holds, takes EADDRINUSE, and exits 0
    // per the bind-is-lock rule; the parent then closes and the port is dead with no
    // daemon on it. Closing first costs a sub-second window the harness's retry covers.
    res.on("finish", () => {
      server.close(async () => {
        const relisten = () => {
          replaceFailedAt = Date.now();
          replacing = false;
          server.listen(port, "127.0.0.1", () => logEvent("relisten", { port }));
        };
        try {
          spawnDaemon(next);
        } catch (err) {
          logEvent("replace-failed", { to: next, err: err && err.message ? err.message : String(err) });
          relisten();
          return;
        }
        // Hand over only once the replacement actually answers AS the new root: a child
        // that died on startup must not take the port down with it.
        const deadline = Date.now() + REPLACE_HEALTH_TIMEOUT_MS;
        while (Date.now() < deadline) {
          try {
            const res2 = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(250) });
            const health = await res2.json();
            if (health && realOrNull(health.root) === next) {
              logEvent("replace", { from: SERVER_ROOT, to: next });
              process.exit(0);
            }
          } catch {
            // Not up yet, or up but not answering /health — keep polling until the deadline.
          }
          await new Promise((r) => setTimeout(r, 100));
        }
        logEvent("replace-failed", { to: next, err: "no health in 3s" });
        relisten();
      });
    });
  });

  onShutdown = () => {
    server.close(() => process.exit(0));
    // A hung connection must not keep the process alive past the signal.
    setTimeout(() => process.exit(0), 1000).unref();
  };

  server.on("error", (err) => {
    // The bind IS the lock (§4.3): a second starter loses the race, says so in the
    // log and leaves quietly. Nothing on stdout — a SessionStart hook's stdout is
    // model context.
    logEvent("bind-error", { port, code: err && err.code ? err.code : null, message: err && err.message ? err.message : String(err) });
    process.exit(0);
  });

  server.listen(port, "127.0.0.1", () => logStart({ port }));
}

// ---------------------------------------------------------------------------
// --stop (spec 0047 §4.3)
// ---------------------------------------------------------------------------
async function runStop() {
  const port = mcpPort();
  let health;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(2000) });
    health = await res.json();
  } catch {
    process.stdout.write(`ah MCP daemon: nothing answering on 127.0.0.1:${port}\n`);
    return 0;
  }
  // Logged BEFORE the signal, by the stopping process, so --diag can tell an operator
  // stop (stop -> signal SIGTERM -> exit) from an external kill (bare signal -> exit).
  logEvent("stop", { target_pid: health.pid, port });
  try {
    process.kill(health.pid, "SIGTERM");
  } catch (err) {
    process.stdout.write(`ah MCP daemon: pid ${health.pid} could not be signalled (${err && err.code ? err.code : err})\n`);
    return 1;
  }
  process.stdout.write(`ah MCP daemon: SIGTERM sent to pid ${health.pid} (v${health.version}, port ${port})\n`);
  return 0;
}

// ---------------------------------------------------------------------------
// --diag (spec 0047 §3.4). Reads what already exists; starts no server.
//
// The classification rules ARE spec 0047 §1's table, as data, so the fixtures in
// tests/fixtures/mcp-logs/ pin one row each.
// ---------------------------------------------------------------------------
/**
 * One row of spec 0047 §1's transport-aware table each, in order; first match wins.
 * The transport matters because the harness owns a stdio child and does not own the
 * daemon: under http it never writes `Sending SIGINT`, and any close line is just the
 * harness closing its own client.
 */
export const DIAG_RULES = [
  {
    shape: "C\u2032",
    // `connected` is load-bearing: a start failure also says ENOENT ("spawn node
    // ENOENT"), and §1 distinguishes the two purely by whether the handshake ever
    // completed. The signal is node's own "Cannot find module", not a spawn error —
    // spawning `process.execPath` succeeds even when the script is gone.
    when: (f) => f.connected && f.moduleMissing,
    remedy: "plugin files moved under a running server — restart the session",
  },
  {
    shape: "A",
    when: (f) => !f.connected,
    remedy: "never completed the handshake — check `exec`/`node` in the lifecycle log, then `claude --debug=mcp`",
  },
  {
    shape: "C",
    // stdio only: the http registration is a constant URL, so the harness has no
    // config change to drop the server over.
    when: (f) => f.transport !== "http" && f.sigint,
    remedy: "the harness dropped this server (config changed / version bump) — `/reload-plugins`",
  },
  {
    shape: "B",
    // Two different observations of the same thing. stdio: the child closed with no
    // SIGINT, so nobody asked it to. http: the daemon stopped answering after the
    // handshake — a post-connect connection error, or the harness starting over.
    // Under-sensitive by construction (§1: no real http death captured yet, E8).
    when: (f) => f.connected && (f.transport === "http" ? f.postConnectError : f.closed && !f.sigint),
    remedy: "died mid-session — check the lifecycle log for `uncaught`/`signal` on that pid",
  },
  {
    shape: "C",
    // §1's "also C" arm (the 0.67.0-under-0.71.0 case, §0): a session STILL OPEN while
    // answering as an older release than the one installed — the harness never picked
    // the new registration up. Ordered after B and C′ on purpose: a log that has already
    // closed, or whose calls are failing, is telling you something more specific, and
    // every historical log names an older version simply by being old.
    when: (f) => f.transport !== "http" && f.staleVersion && !f.closed,
    remedy: "serving an older version than the one installed — `/reload-plugins`",
  },
  { shape: "ok", when: () => true, remedy: "" },
];

/** Is `a` an older release than `b`? Used only for §1's stale-`serverVersion` arm. */
function olderVersion(a, b) {
  const pa = String(a).split(".").map(Number);
  const pb = String(b).split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x !== y) return x < y;
  }
  return false;
}

export function classifyHarnessLog(lines) {
  const facts = { connected: false, sigint: false, closed: false, cleanClose: false, enoent: false, moduleMissing: false, postConnectError: false, staleVersion: false, version: null, calls: 0, lastError: null, start: null, sessionId: null, transport: null };
  for (const entry of lines) {
    if (!entry || typeof entry !== "object") continue;
    const text = String(entry.debug ?? entry.error ?? "");
    if (!facts.start && entry.timestamp) facts.start = entry.timestamp;
    if (entry.sessionId) facts.sessionId = entry.sessionId;
    // A file that never connected is classified by the registration in force (§1), which
    // the harness names before it tries: "Initializing HTTP transport to ...".
    if (!facts.transport && text.includes("Initializing HTTP transport")) facts.transport = "http";
    if (text.includes("Successfully connected")) {
      facts.connected = true;
      const t = text.match(/transport:\s*([a-z]+)/);
      if (t) facts.transport = t[1];
    }
    // Order matters, not mere presence: the harness's own cold-start retry writes a
    // ConnectionRefused and a second "Starting connection" BEFORE the handshake on
    // every hook-started daemon (§6 E3, the `http-ok` fixture). Only a failure after
    // the handshake says the daemon went away.
    if (facts.connected && (/ConnectionRefused|ECONNRESET|fetch failed|Connection failed/.test(text) || text.includes("Starting connection"))) {
      facts.postConnectError = true;
    }
    if (text.includes("Sending SIGINT")) facts.sigint = true;
    if (text.includes("connection closed") || text.includes("process exited")) {
      facts.closed = true;
      if (text.includes("(cleanly)") || text.includes("exited cleanly")) facts.cleanClose = true;
    }
    if (text.includes("ENOENT")) facts.enoent = true;
    if (text.includes("Cannot find module") || text.includes("ERR_MODULE_NOT_FOUND")) facts.moduleMissing = true;
    if (text.startsWith("Calling MCP tool:")) facts.calls += 1;
    if (entry.error || text.includes("failed after")) facts.lastError = text.split("\n")[0].slice(0, 120);
    const v = text.match(/"version":"([^"]+)"/);
    if (v) facts.version = v[1];
  }
  facts.staleVersion = !!facts.version && olderVersion(facts.version, PLUGIN_MANIFEST.version);
  const rule = DIAG_RULES.find((r) => r.when(facts));
  return { ...facts, shape: rule.shape, remedy: rule.remedy };
}

function harnessLogDir(cwd) {
  const slug = resolve(cwd).replace(/\//g, "-");
  const base =
    process.platform === "darwin"
      ? join(homedir(), "Library", "Caches", "claude-cli-nodejs")
      : join(homedir(), ".cache", "claude-cli-nodejs"); // Linux: assumed, spec 0047 §6 E7
  return join(base, slug, "mcp-logs-plugin-ah-ah");
}

function readJsonl(path) {
  const out = [];
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return out;
  }
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      // A torn last line in a log being written is expected; skip it.
    }
  }
  return out;
}

async function runDiag(argv) {
  const cwdArg = argv.includes("--cwd") ? argv[argv.indexOf("--cwd") + 1] : process.cwd();
  const asJson = argv.includes("--json");
  const dir = harnessLogDir(cwdArg);
  const report = { cwd: resolve(cwdArg), harness_log_dir: dir, servers: [], lifecycle: { path: LOG_PATH, starts: [], exits: [], problems: [], stops: [] }, health: null };

  let files = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".jsonl")).sort().reverse();
  } catch {
    report.harness_logs = `no harness logs for ${report.cwd}`;
  }
  for (const f of files) {
    report.servers.push({ file: f, ...classifyHarnessLog(readJsonl(join(dir, f))) });
  }

  // `--stop` records its intent (with the pid it is about to signal) before sending the
  // signal, so a SIGTERM the operator asked for is distinguishable from one it did not
  // (§1's B row: a `signal` NOT preceded by a `stop` is evidence, §4.3).
  const stopRequests = new Set();
  for (const entry of readJsonl(LOG_PATH)) {
    if (entry.event === "start") report.lifecycle.starts.push(entry);
    else if (entry.event === "exit") report.lifecycle.exits.push(entry);
    else if (entry.event === "stop") stopRequests.add(entry.target_pid);
    else if (entry.event === "signal") {
      report.lifecycle.stops.push({ ts: entry.ts, pid: entry.pid, signal: entry.signal, origin: stopRequests.has(entry.pid) ? "operator" : "external" });
    }
    if (["uncaught", "unhandled", "exec-error", "bind-error", "replace-failed"].includes(entry.event)) report.lifecycle.problems.push(entry);
  }
  for (const st of report.lifecycle.stops) {
    if (st.origin === "external") report.lifecycle.problems.push({ ts: st.ts, event: "signal", message: `${st.signal} pid ${st.pid} — external (no \`--stop\` requested it)` });
  }
  if (!report.lifecycle.starts.length && !report.lifecycle.problems.length) {
    report.lifecycle.note = `no lifecycle log at ${LOG_PATH} (nothing has run since 0.72.0, or AGENT_HIERARCHY_DIR points elsewhere)`;
  }

  try {
    const res = await fetch(`http://127.0.0.1:${mcpPort()}/health`, { signal: AbortSignal.timeout(1000) });
    report.health = await res.json();
  } catch {
    report.health = { answering: false, port: mcpPort() };
  }

  if (asJson) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
    return 0;
  }

  const L = (t) => process.stdout.write(t + "\n");
  L(`ah MCP diagnosis — cwd ${report.cwd}`);
  L(`harness logs: ${report.harness_log_dir}`);
  if (report.harness_logs) L(`  ${report.harness_logs}`);
  for (const s of report.servers) {
    const lc = report.lifecycle.starts.find((st) => s.start && Math.abs(Date.parse(st.ts) - Date.parse(s.start)) < 60000);
    L(
      `  ${s.shape.padEnd(3)} ${s.start || "?"}  v${s.version || "?"}  ${s.transport || "?"}  calls=${s.calls}` +
        `  session=${(s.sessionId || "?").slice(0, 8)}${lc ? `  lifecycle-pid=${lc.pid}` : ""}`,
    );
    if (s.lastError) L(`        last error: ${s.lastError}`);
    if (s.remedy) L(`        remedy: ${s.remedy}`);
  }
  L(`lifecycle log: ${report.lifecycle.path}`);
  if (report.lifecycle.note) L(`  ${report.lifecycle.note}`);
  else L(`  ${report.lifecycle.starts.length} start(s), ${report.lifecycle.exits.length} exit(s), ${report.lifecycle.problems.length} problem event(s)`);
  for (const p of report.lifecycle.problems.slice(-5)) L(`  ${p.ts} ${p.event} ${p.message || p.code || ""}`);
  for (const st of report.lifecycle.stops.slice(-5)) L(`  ${st.ts} ${st.signal} pid ${st.pid} — ${st.origin === "operator" ? "operator stop (--stop)" : "external stop"}`);
  L(
    report.health && report.health.answering === false
      ? `daemon: nothing answering on 127.0.0.1:${report.health.port}`
      : `daemon: v${report.health.version} pid ${report.health.pid} sessions ${report.health.sessions} identity ${report.health.identity} root ${report.health.root}`,
  );
  return 0;
}

// Only run a transport when launched as the server process, not when this module
// is imported (e.g. by tests exercising TOOLS/mapExecResult/callTool directly).
const isMain = process.argv[1] && resolveIsMain();
function resolveIsMain() {
  let self;
  try {
    self = fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
  const argv = process.argv[1];
  if (self === argv) return true;
  // Compare real paths too. `import.meta.url` is already resolved, but argv[1] is
  // whatever the caller typed — and the SessionStart hook spawns us by
  // $CLAUDE_PLUGIN_ROOT, which nothing realpaths. Any symlink anywhere in that path
  // (a /var -> /private/var sandbox, a symlinked plugin cache) made the two differ,
  // and because success here is silent the result was a daemon that ran nothing and
  // said nothing at all.
  try {
    return realpathSync(self) === realpathSync(argv);
  } catch {
    return false;
  }
}

if (isMain) {
  const argv = process.argv.slice(2);
  if (argv.includes("--diag")) {
    process.exit(await runDiag(argv));
  } else if (argv.includes("--stop")) {
    process.exit(await runStop());
  } else if (argv.includes("--http")) {
    installProcessHandlers();
    runHttp();
  } else {
    installProcessHandlers();
    logStart();
    const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
    rl.on("line", (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let msg;
      try {
        msg = JSON.parse(trimmed);
      } catch {
        send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
        return;
      }
      if (!isValidRequestShape(msg)) {
        const id = msg && typeof msg === "object" && "id" in msg ? msg.id : null;
        send({ jsonrpc: "2.0", id, error: { code: -32600, message: "invalid request" } });
        return;
      }
      if (isNotification(msg)) {
        // Unknown/unhandled notifications (e.g. notifications/initialized) are
        // silently ignored — no response — per spec 0013 §6.1 item 3.
        return;
      }
      // Fire-and-forget per line: do not await here, so a slow tools/call never
      // blocks the read loop from starting the next concurrent call (§6.1 item 5).
      handleRequest(msg).catch((err) => {
        sendError(msg.id, -32603, err && err.message ? err.message : String(err));
      });
    });
    rl.on("close", () => {
      logEvent("stdin-end", {});
      process.exit(0);
    });
  }
}
