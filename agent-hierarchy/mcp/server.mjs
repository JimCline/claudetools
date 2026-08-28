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
        type: { type: "string", description: "request|response (default request)." },
        id: { type: "string", description: "Explicit message id — set when writing a response to match its request." },
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
    description: "Show the resolved roster, or one level's raw file, via roster.mjs show.",
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
    name: "roster_teams",
    description: "List every team in the hierarchy dir via roster.mjs teams.",
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
    name: "roster_member",
    description: "Init a roster level, or add, edit, or remove a roster member, via roster.mjs.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        action: { type: "string", enum: ["init", "add", "edit", "remove"] },
        level: levelSchema,
        member: { type: "string", description: "The member's derived name. Required with action: edit, remove." },
        role: { type: "string", description: "Required with action: add." },
        model: { type: "string", description: "With action: add, edit." },
        effort: { type: "string", description: "With action: add, edit." },
        route: { type: "string", enum: ["peer", "subagent"], description: "Required with action: init." },
        auto_mode: { type: "string", description: "With action: add, edit." },
        on_missing: { type: "string", enum: ["auto", "prompt", "never"], description: "With action: add, edit. Peer-routed members only." },
        layout: { type: "string", enum: ["auto", "columns", "grid"], description: "With action: init." },
      },
      required: ["cwd", "action"],
    },
  },
  {
    name: "roster_config",
    description: "Show or set a roster level's pane layout, or the repo's team-name alias, via roster.mjs.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        target: { type: "string", enum: ["layout", "alias"] },
        level: levelSchema,
        layout: { type: "string", enum: ["auto", "columns", "grid"], description: "With target: layout. Omit to read." },
        set: { type: "string", description: "New alias. With target: alias." },
        clear: { type: "boolean", description: "With target: alias." },
        team: teamSchema,
      },
      required: ["cwd", "target"],
    },
  },
  {
    name: "roster_create",
    description: "Plan, spawn, or commit a Team via roster.mjs create.",
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
    name: "roster_adopt",
    description: "Re-stamp orchestrator.pid on an existing, orphaned team.json via roster.mjs adopt. Recovery only — refuses to hijack a live team.",
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
    name: "roster_layout_splits",
    description: "Run or drive the herdr layout-splits phase via roster.mjs layout-splits.",
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
    name: "roster_disband",
    description: "Plan, commit, or keep-sessions a Team teardown via roster.mjs disband. Non-destructive modes only — never closes anything.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        mode: { type: "string", enum: ["plan", "commit", "keep-sessions"], description: "Default plan." },
      },
      required: ["cwd"],
    },
  },
  {
    name: "roster_disband_close",
    description: "Close the live sessions of a Team. Destructive; requires prior user confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        confirm: { type: "boolean", description: "Must be true, and only after the user has been shown the close list and agreed." },
        plan_token: { type: "string", description: "close_token from the preceding roster_disband mode:plan call." },
        allow_global: { type: "boolean" },
      },
      required: ["cwd", "confirm", "plan_token"],
    },
  },
  {
    name: "roster_resync",
    description: "Re-derive every peer member's herdr location from live topology via roster.mjs resync.",
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
    name: "roster_move",
    description: "Relocate a member's pane via roster.mjs move.",
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
    name: "roster_history",
    description: "List recent team-history entries (for reuse via 'create --from') via roster.mjs history.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
      },
      required: ["cwd"],
    },
  },
  {
    name: "roster_spawn_one",
    description: "Spawn or restart one missing/dead peer role (e.g. 'spawn the architect') without touching the rest of the team.",
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
    name: "roster_dismiss",
    description: "Dismiss ONE member from a live team's check-in registry by derived name (e.g. 'dismiss bps-implementor-2'). Does not close sessions.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        name: { type: "string", description: "Derived member name from team.json, not a role." },
        mode: { type: "string", enum: ["plan", "commit"], description: "plan (default) is read-only; commit rewrites team.json minus this member." },
        also_config: { type: "boolean", description: "With mode:commit, also remove the matching roster config entry so a future create does not rebuild it." },
        level: { type: "string", enum: ["global", "repo", "repo-user"], description: "Config level for also_config; defaults to the resolving level." },
      },
      required: ["cwd", "name"],
    },
  },
  {
    name: "roster_dismiss_close",
    description: "Close ONE live team member's session. Destructive; requires prior user confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: cwdSchema,
        team: teamSchema,
        name: { type: "string" },
        confirm: { type: "boolean", description: "Must be true, and only after the user has been shown the close list and agreed." },
        plan_token: { type: "string", description: "close_token from the preceding roster_dismiss mode:plan call." },
        allow_global: { type: "boolean" },
      },
      required: ["cwd", "name", "confirm", "plan_token"],
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
      pushArg(args, "type", args_in.type);
      pushArg(args, "id", args_in.id);
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
    case "roster_teams": {
      const args = ["teams"];
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_member": {
      const action = args_in.action;
      if (!["init", "add", "edit", "remove"].includes(action)) {
        return err(`roster_member: "action" must be one of init, add, edit, remove, got ${JSON.stringify(action)}`);
      }
      if (action === "init") {
        if (!args_in.level) return err('roster_member: action "init" requires "level".');
        if (!args_in.route) return err('roster_member: action "init" requires "route".');
      }
      if (action === "add" && !args_in.role) return err('roster_member: action "add" requires "role".');
      if ((action === "edit" || action === "remove") && !args_in.member) {
        return err(`roster_member: action "${action}" requires "member".`);
      }

      const args = [action];
      pushArg(args, "level", args_in.level);
      if (action === "init") {
        pushArg(args, "route", args_in.route);
        pushArg(args, "layout", args_in.layout);
      }
      if (action === "add") pushArg(args, "role", args_in.role);
      if (action === "edit" || action === "remove") pushArg(args, "member", args_in.member);
      if (action === "edit") pushArg(args, "role", args_in.role);
      if (action === "add" || action === "edit") {
        pushArg(args, "model", args_in.model);
        pushArg(args, "effort", args_in.effort);
        pushArg(args, "route", args_in.route);
        pushArg(args, "auto-mode", args_in.auto_mode);
        pushArg(args, "on-missing", args_in.on_missing);
      }
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_config": {
      const target = args_in.target;
      if (target !== "layout" && target !== "alias") {
        return err(`roster_config: "target" must be one of layout, alias, got ${JSON.stringify(target)}`);
      }
      const args = [target];
      pushArg(args, "level", args_in.level);
      if (target === "layout") {
        pushArg(args, "layout", args_in.layout);
      } else {
        pushArg(args, "set", args_in.set);
        pushFlag(args, "clear", args_in.clear);
        pushArg(args, "team", args_in.team);
      }
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_create": {
      const mode = args_in.mode;
      if (mode !== "plan" && mode !== "spawn" && mode !== "commit") {
        return { content: [{ type: "text", text: `roster_create: "mode" must be one of plan, spawn, commit, got ${JSON.stringify(mode)}` }], isError: true };
      }
      if (mode === "commit" && typeof args_in.verified !== "string") {
        return { content: [{ type: "text", text: 'roster_create: mode "commit" requires "verified" (a JSON array string).' }], isError: true };
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
    case "roster_layout_splits": {
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
    case "roster_disband": {
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "commit" && mode !== "keep-sessions") {
        return { content: [{ type: "text", text: `roster_disband: "mode" must be one of plan, commit, keep-sessions, got ${JSON.stringify(mode)}` }], isError: true };
      }
      const args = ["disband"];
      if (mode === "commit") args.push("--commit");
      else if (mode === "keep-sessions") args.push("--keep-sessions");
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_disband_close": {
      if (args_in.confirm !== true) {
        return {
          content: [{ type: "text", text: 'roster_disband_close: "confirm" must be true, and only after the user has been shown the close list and agreed.' }],
          isError: true,
        };
      }
      if (typeof args_in.plan_token !== "string" || !args_in.plan_token.trim()) {
        return {
          content: [{ type: "text", text: 'roster_disband_close: "plan_token" is required — pass the close_token from a preceding roster_disband mode:plan call.' }],
          isError: true,
        };
      }
      const args = ["disband", "--close", "--confirm", "--plan-token", args_in.plan_token];
      pushArg(args, "team", args_in.team);
      pushFlag(args, "allow-global", args_in.allow_global);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_resync": {
      const args = ["resync"];
      pushFlag(args, "dry-run", args_in.dry_run);
      pushArg(args, "team", args_in.team);
      pushArg(args, "bind", args_in.bind);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_move": {
      if (typeof args_in.name !== "string" || !args_in.name.trim()) {
        return { content: [{ type: "text", text: 'roster_move: "name" is required.' }], isError: true };
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
    case "roster_history": {
      const args = ["history"];
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_spawn_one": {
      if (typeof args_in.role !== "string" || !args_in.role.trim()) {
        return { content: [{ type: "text", text: 'roster_spawn_one: "role" is required.' }], isError: true };
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
    case "roster_dismiss": {
      if (typeof args_in.name !== "string" || !args_in.name.trim()) {
        return { content: [{ type: "text", text: 'roster_dismiss: "name" is required.' }], isError: true };
      }
      const mode = args_in.mode || "plan";
      if (mode !== "plan" && mode !== "commit") {
        return { content: [{ type: "text", text: `roster_dismiss: "mode" must be one of plan, commit, got ${JSON.stringify(mode)}` }], isError: true };
      }
      const args = ["dismiss", args_in.name];
      if (mode === "commit") args.push("--commit");
      pushFlag(args, "also-config", args_in.also_config);
      pushArg(args, "level", args_in.level);
      pushArg(args, "team", args_in.team);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_dismiss_close": {
      if (typeof args_in.name !== "string" || !args_in.name.trim()) {
        return { content: [{ type: "text", text: 'roster_dismiss_close: "name" is required.' }], isError: true };
      }
      if (args_in.confirm !== true) {
        return {
          content: [{ type: "text", text: 'roster_dismiss_close: "confirm" must be true, and only after the user has been shown the close list and agreed.' }],
          isError: true,
        };
      }
      if (typeof args_in.plan_token !== "string" || !args_in.plan_token.trim()) {
        return {
          content: [{ type: "text", text: 'roster_dismiss_close: "plan_token" is required — pass the close_token from a preceding roster_dismiss mode:plan call.' }],
          isError: true,
        };
      }
      const args = ["dismiss", args_in.name, "--close", "--confirm", "--plan-token", args_in.plan_token];
      pushArg(args, "team", args_in.team);
      pushFlag(args, "allow-global", args_in.allow_global);
      pushArg(args, "cwd", cwd);
      return execCli(ROSTER_CLI, args);
    }
    case "roster_adopt": {
      const args = ["adopt"];
      pushArg(args, "orchestrator-pid", args_in.orchestrator_pid ?? SESSION_PID);
      pushArg(args, "team", args_in.team);
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
