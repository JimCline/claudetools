#!/usr/bin/env node
/**
 * model-banner — SessionStart maintenance hook.
 *
 * Keeps the generated status-line shim (~/.claude/model-banner/statusline.mjs)
 * pointed at the current plugin installation, since marketplace-installed
 * plugins live under a version-stamped cache directory that changes on every
 * update. Does nothing if the user has not run /model-banner init. Never
 * touches ~/.claude/settings.json — that mutation belongs to the CLI alone,
 * run explicitly by the user.
 *
 * Emits nothing: no stdout, no additionalContext, no systemMessage.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { shimSource } from "./lib-shim.mjs";

async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/** True for any subagent session — see agent-hierarchy/hooks/lib-config.mjs for why `agent_id`, not `agent_type`, is the discriminator. */
function isSubagent(input) {
  const id = input && input.agent_id;
  return typeof id === "string" && id.length > 0;
}

async function main() {
  const input = await readHookInput();
  if (isSubagent(input)) return;

  const stateDir = join(homedir(), ".claude", "model-banner");
  const shimPath = join(stateDir, "statusline.mjs");
  if (!existsSync(shimPath)) return; // not installed — do nothing

  const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const rootFile = join(stateDir, "plugin-root");

  try {
    const currentRoot = existsSync(rootFile) ? readFileSync(rootFile, "utf8").trim() : null;
    if (currentRoot !== pluginRoot) {
      writeFileSync(rootFile, pluginRoot + "\n", "utf8");
    }
  } catch {
    // best effort — the shim's own fallback chain protects the user either way
  }

  try {
    const shim = readFileSync(shimPath, "utf8");
    if (!shim.includes(JSON.stringify(pluginRoot))) {
      writeFileSync(shimPath, shimSource(pluginRoot), "utf8");
    }
  } catch {
    // best effort
  }
}

main();
