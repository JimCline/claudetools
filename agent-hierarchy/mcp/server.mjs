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

const PROTOCOL_VERSION = "2024-11-05";
const PLUGIN_MANIFEST = JSON.parse(readFileSync(join(HERE, "..", ".claude-plugin", "plugin.json"), "utf8"));

const cwdSchema = {
  type: "string",
  description: "Absolute path to the repo/session working directory. Required on every call — never defaults to the server's own cwd.",
};

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
        team: { type: "string", description: "Named team scope, if any." },
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
        team: { type: "string", description: "Named team scope, if any." },
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
        team: { type: "string", description: "Named team scope, if any." },
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
        level: { type: "string", enum: ["global", "repo", "repo-user"], description: "Show one level's raw file instead of the resolved (winning) roster." },
        team: { type: "string", description: "Named team scope, if any." },
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
      },
      required: ["cwd"],
    },
  },
];

const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));

/**
 * Pure exit-code/stdout/stderr → MCP tool-result mapper (spec 0013 §6.2).
 * Exported so tests can exercise the mapping directly with synthetic inputs,
 * independent of which real CLI invocation (if any) produces a given case.
 */
export function mapExecResult({ code, stdout, stderr, scriptPath }) {
  if (code === 0) {
    const text = stderr && stderr.trim() ? `${stdout}\nstderr:\n${stderr}` : stdout;
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

function execCli(scriptPath, args) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(process.execPath, [scriptPath, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      resolve(mapExecResult({ code: -1, stdout: "", stderr: String(err && err.message ? err.message : err), scriptPath }));
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      resolve(mapExecResult({ code: -1, stdout, stderr: stderr || String(err && err.message ? err.message : err), scriptPath }));
    });
    child.on("close", (code) => {
      resolve(mapExecResult({ code, stdout, stderr, scriptPath }));
    });
  });
}

function pushArg(args, flag, value) {
  if (value === undefined || value === null || value === "") return;
  args.push(`--${flag}`, String(value));
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
