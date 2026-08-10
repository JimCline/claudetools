#!/usr/bin/env node
/**
 * model-banner — config resolution.
 *
 * Two config scopes, both plain JSON at `.claude/model-banner.json`:
 *   - user:    ~/.claude/model-banner.json          (all repos)
 *   - project: <cwd>/.claude/model-banner.json      (committable)
 *
 * Resolution rules:
 *   - enabled, size, chain: most-specific scope wins (project overrides user).
 *   - colors: merged per tier key — a project config that sets only one tier
 *     overrides just that tier; other tiers keep their user-scope-or-default
 *     value.
 *   - Missing version -> treat as 1. A version newer than this plugin
 *     understands -> that scope is ignored (with a warning).
 *   - An unknown colour name is dropped from the resolved map (with a
 *     warning) so the caller's tier-default fallback applies; this never
 *     throws.
 *
 * Run directly (`node lib-config.mjs`) to print the resolved status table for
 * the current working directory — that is what `/model-banner status` uses.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { COLORS } from "./lib-color.mjs";

export const CONFIG_VERSION = 1;
export const CONFIG_BASENAME = "model-banner.json";
export const SIZES = ["large", "compact", "small"];
export const LAYOUTS = ["stack", "side"];

export function userConfigPath() {
  return join(homedir(), ".claude", CONFIG_BASENAME);
}

export function projectConfigPath(cwd) {
  if (typeof cwd !== "string" || !cwd) return null;
  return join(resolve(cwd), ".claude", CONFIG_BASENAME);
}

/** Load one scope. Returns null when absent/unreadable/not an object. */
function loadScope(path, scope, warnings) {
  if (!path || !existsSync(path)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    warnings.push(`model-banner: ${scope}-scope config at ${path} is not valid JSON — ignoring it.`);
    return null;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    warnings.push(`model-banner: ${scope}-scope config at ${path} is not a JSON object — ignoring it.`);
    return null;
  }
  const version = data.version === undefined ? CONFIG_VERSION : data.version;
  if (!Number.isInteger(version) || version > CONFIG_VERSION) {
    warnings.push(
      `model-banner: ${scope}-scope config at ${path} declares version ${JSON.stringify(data.version)}, which this plugin (v${CONFIG_VERSION}) does not understand — ignoring it.`
    );
    return null;
  }
  return { scope, path, data };
}

/**
 * Resolve the effective config for a session.
 *
 * @returns {{configured: boolean, enabled: boolean, enabledSource: string,
 *            size: string, sizeSource: string, chain: (string|null),
 *            chainSource: string, colors: object, colorSources: object,
 *            layers: object[], warnings: string[], userPath: string,
 *            projectPath: (string|null)}}
 */
export function resolveConfig(cwd) {
  const warnings = [];
  const userPath = userConfigPath();
  const projectPath = projectConfigPath(cwd);
  const user = loadScope(userPath, "user", warnings);
  // When the session's cwd IS the home directory the two scopes are the same
  // file; loading it twice would report every key as shadowed by itself.
  const project = projectPath === userPath ? null : loadScope(projectPath, "project", warnings);

  // Least specific first: later layers win.
  const layers = [user, project].filter(Boolean);

  let enabled = true;
  let enabledSource = "default";
  let size = "large";
  let sizeSource = "default";
  let layout = "stack";
  let layoutSource = "default";
  let chain = null;
  let chainSource = "default";
  const colors = {};
  const colorSources = {};

  for (const layer of layers) {
    const data = layer.data;
    if (typeof data.enabled === "boolean") {
      enabled = data.enabled;
      enabledSource = layer.scope;
    }
    if (typeof data.size === "string") {
      size = data.size;
      sizeSource = layer.scope;
    }
    if (typeof data.layout === "string") {
      layout = data.layout;
      layoutSource = layer.scope;
    }
    if (typeof data.chain === "string" || data.chain === null) {
      chain = data.chain;
      chainSource = layer.scope;
    }
    if (data.colors && typeof data.colors === "object" && !Array.isArray(data.colors)) {
      for (const [tier, value] of Object.entries(data.colors)) {
        if (typeof value !== "string") continue;
        colors[tier] = value;
        colorSources[tier] = layer.scope;
      }
    }
  }

  if (!SIZES.includes(size)) {
    warnings.push(`model-banner: size ${JSON.stringify(size)} is not one of ${SIZES.join(", ")} — using "large".`);
    size = "large";
    sizeSource = "default";
  }

  if (!LAYOUTS.includes(layout)) {
    warnings.push(`model-banner: layout ${JSON.stringify(layout)} is not one of ${LAYOUTS.join(", ")} — using "stack".`);
    layout = "stack";
    layoutSource = "default";
  }

  for (const tier of Object.keys(colors)) {
    if (COLORS[colors[tier]] === undefined) {
      warnings.push(
        `model-banner: colour ${JSON.stringify(colors[tier])} for "${tier}" is not a known colour (allowed: ${Object.keys(COLORS).join(", ")}) — using the tier default.`
      );
      delete colors[tier];
      delete colorSources[tier];
    }
  }

  return {
    configured: layers.length > 0,
    enabled,
    enabledSource,
    size,
    sizeSource,
    layout,
    layoutSource,
    chain,
    chainSource,
    colors,
    colorSources,
    layers,
    warnings,
    userPath,
    projectPath,
  };
}

/** Human-readable resolved table for `/model-banner status`. */
export function statusReport(cwd, extra) {
  const resolved = resolveConfig(cwd);
  const seen = Object.fromEntries(resolved.layers.map((l) => [l.scope, l.path]));
  const out = [];
  out.push(`model-banner: ${resolved.enabled ? "ON" : "OFF"} (from ${resolved.enabledSource})`);
  if (extra) out.push(...extra);
  out.push(`size:           ${resolved.size} (from ${resolved.sizeSource})`);
  out.push(`layout:         ${resolved.layout} (from ${resolved.layoutSource})`);
  out.push(`user config:    ${seen.user || `${resolved.userPath} (none)`}`);
  out.push(`project config: ${seen.project || `${resolved.projectPath || "(unknown cwd)"} (none)`}`);
  out.push(`chain:          ${resolved.chain ? `"${resolved.chain}"` : "(none)"}`);
  for (const warning of resolved.warnings) out.push(warning);
  return out.join("\n");
}

// Run directly: print the status table for the current working directory.
if (process.argv[1] && resolve(process.argv[1]).endsWith("lib-config.mjs")) {
  process.stdout.write(statusReport(process.cwd()) + "\n");
}
