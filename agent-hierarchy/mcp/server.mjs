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

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
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
      resolve(mapExecResult({ code: -1, stdout: "", stderr: String(err && err.message ? err.message : err), scriptPath, expectedNonZero }));
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      resolve(mapExecResult({ code: -1, stdout, stderr: stderr || String(err && err.message ? err.message : err), scriptPath, expectedNonZero }));
    });
    child.on("close", (code) => {
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

export async function callTool(name, input) {
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
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
      pushArg(args, "orchestrator-pid", SESSION_PID);
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
        pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
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
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
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
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
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
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
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

async function handleRequest(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    sendResult(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: "ah", version: PLUGIN_MANIFEST.version },
      instructions:
        "To show/inspect the agent-hierarchy roster, call roster_show directly " +
        "(pass cwd) rather than shelling out — hand-rolled bash/cat reads only " +
        "the local .claude/agent-hierarchy.json and misses worktree/main-checkout " +
        "and global fallback resolution that roster_show already implements.",
    });
    return;
  }
  if (method === "tools/list") {
    sendResult(id, { tools: TOOLS });
    return;
  }
  if (method === "tools/call") {
    const toolName = params && params.name;
    if (!TOOL_NAMES.has(toolName)) {
      sendError(id, -32602, `unknown tool ${JSON.stringify(toolName)}`);
      return;
    }
    const result = await callTool(toolName, params && params.arguments);
    sendResult(id, result);
    return;
  }
  if (method === "ping") {
    sendResult(id, {});
    return;
  }
  sendError(id, -32601, `method not found: ${JSON.stringify(method)}`);
}

function isNotification(msg) {
  return msg && typeof msg === "object" && !("id" in msg);
}

function isValidRequestShape(msg) {
  return Boolean(msg) && typeof msg === "object" && !Array.isArray(msg) && typeof msg.method === "string";
}

// Only run the stdio loop when launched as the server process, not when this module
// is imported (e.g. by tests exercising TOOLS/mapExecResult/callTool directly).
const isMain = process.argv[1] && resolveIsMain();
function resolveIsMain() {
  try {
    return fileURLToPath(import.meta.url) === process.argv[1];
  } catch {
    return false;
  }
}

if (isMain) {
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
}
