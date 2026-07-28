#!/usr/bin/env node
/**
 * comment-discipline — config CLI backing the /comment-discipline command.
 *
 * The slash command shells out to this rather than having the model hand-edit
 * JSON, so init/on/off/status are deterministic and cannot corrupt the config
 * they are meant to manage.
 *
 * Usage:
 *   cli.mjs init user|project   create that scope's config, enabled
 *   cli.mjs on | off            flip the NARROWEST existing scope
 *   cli.mjs status              report both scopes and the effective verdict
 */

import { existsSync } from "node:fs";
import { projectConfigPath, resolveConfig, userConfigPath, writeConfig } from "./lib-config.mjs";

const [command, argument] = process.argv.slice(2);
const cwd = process.cwd();

function describeScopes() {
  const u = userConfigPath();
  const p = projectConfigPath(cwd);
  const lines = [];
  lines.push(existsSync(u) ? `  user    ${u}` : "  user    (none)");
  lines.push(existsSync(p) ? `  project ${p}` : "  project (none)");
  return lines.join("\n");
}

/**
 * on/off target the narrowest scope that ALREADY has a config, so a repo-level
 * opt-out never silently rewrites the user's global setting. With no config at
 * all there is nothing to flip — that is an init, and we say so.
 */
function narrowestExistingScope() {
  const p = projectConfigPath(cwd);
  if (p && existsSync(p)) return { scope: "project", path: p };
  const u = userConfigPath();
  if (existsSync(u)) return { scope: "user", path: u };
  return null;
}

switch (command) {
  case "init": {
    if (argument !== "user" && argument !== "project") {
      console.error('comment-discipline: init needs a scope — "user" or "project".');
      process.exit(2);
    }
    const path = argument === "user" ? userConfigPath() : projectConfigPath(cwd);
    writeConfig(path, true);
    console.log(`comment-discipline: ON (${argument} scope) — ${path}`);
    break;
  }

  case "on":
  case "off": {
    const enabled = command === "on";
    const target = narrowestExistingScope();
    if (!target) {
      console.error("comment-discipline: not configured yet — run `/comment-discipline init` first.");
      process.exit(2);
    }
    writeConfig(target.path, enabled);
    console.log(`comment-discipline: ${enabled ? "ON" : "OFF"} (${target.scope} scope) — ${target.path}`);
    break;
  }

  case "status": {
    const resolved = resolveConfig(cwd);
    if (!resolved.configured) {
      console.log("comment-discipline: NOT CONFIGURED — run `/comment-discipline init`.");
    } else {
      console.log(`comment-discipline: ${resolved.enabled ? "ON" : "OFF"}`);
    }
    console.log(describeScopes());
    if (resolved.sources.length > 1) {
      console.log("  (both scopes present — project wins)");
    }
    for (const warning of resolved.warnings) console.log(`  ${warning}`);
    break;
  }

  default:
    console.error("comment-discipline: usage — cli.mjs init user|project | on | off | status");
    process.exit(2);
}
