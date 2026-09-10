#!/usr/bin/env node
/**
 * SessionStart: make sure the `ah` MCP HTTP daemon is listening (spec 0047 §4.3).
 *
 * Deliberately a separate script from sessionstart.mjs: that hook's subagent /
 * `--agent` guards and its roster write must stay untouched, and this one has to
 * run for every session shape regardless of them.
 *
 * Contract, in order of importance:
 *   - stdout is injected into the model's context, so success is SILENT. The only
 *     thing ever printed is a single line when the daemon could not be started,
 *     because that is the one case the model must tell the user about.
 *   - exit 0 always. A diagnostic hook that fails a session start is worse than
 *     no daemon: every tool has a documented CLI fallback.
 *   - the bind is the lock. Two sessions starting at once both spawn; the loser
 *     gets EADDRINUSE, logs it and exits 0. No pidfile to go stale.
 */

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = process.env.CLAUDE_PLUGIN_ROOT || join(HERE, "..");
const SERVER = join(ROOT, "mcp", "server.mjs");
const PORT = Number(process.env.AH_MCP_PORT || 7434);
const HEALTH_TIMEOUT_MS = 300;

function hierDir() {
  return process.env.AGENT_HIERARCHY_DIR || join(homedir(), ".claude", "hierarchy");
}

async function health() {
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/health`, {
      signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

function cannotStart(why) {
  process.stdout.write(
    `agent-hierarchy: could not start the ah MCP daemon (${why}). MCP tools will be unavailable ` +
      `this session — use the roster.mjs / msg.mjs CLI fallback documented in docs/mcp-tools.md.\n`,
  );
}

function startDaemon() {
  const dir = hierDir();
  let fd = "ignore";
  try {
    mkdirSync(dir, { recursive: true });
    fd = openSync(join(dir, "mcp-server.log"), "a");
  } catch {
    fd = "ignore";
  }
  const child = spawn(process.execPath, [SERVER, "--http"], {
    detached: true,
    stdio: ["ignore", fd, fd],
    env: process.env,
  });
  // A detached spawn reports most failures asynchronously, and this process is about
  // to exit — so the pre-flight existsSync below is what actually catches the common
  // case. This listener only keeps an async error from surfacing as an unhandled
  // event in the window before exit.
  child.on("error", (err) => cannotStart(err && err.message ? err.message : String(err)));
  child.unref();
}

const live = await health();
if (live) {
  // A daemon on another version is still the right daemon to talk to: it notices the
  // version change on its next request and re-execs itself from the new install
  // (§4.3). Starting a second one here would only lose the port race.
  process.exit(0);
}

if (!existsSync(SERVER)) {
  cannotStart(`no server at ${SERVER}`);
  process.exit(0);
}

try {
  startDaemon();
} catch (err) {
  cannotStart(err && err.message ? err.message : String(err));
}
process.exit(0);
