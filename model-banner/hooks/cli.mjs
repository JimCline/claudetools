#!/usr/bin/env node
/**
 * model-banner — CLI backing the /model-banner slash command.
 *
 * Actions: install | uninstall | on | off | size <small|large> |
 *          color <tier> <color> | status
 *
 * install/uninstall are the only actions that ever touch
 * ~/.claude/settings.json, and only because the user explicitly ran
 * /model-banner init or /model-banner uninstall — no hook may do this.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveConfig, userConfigPath, SIZES, LAYOUTS, CONFIG_VERSION } from "./lib-config.mjs";
import { TIERS, DEFAULT_TIER } from "./lib-tiers.mjs";
import { COLORS } from "./lib-color.mjs";
import { shimSource } from "./lib-shim.mjs";

const PLUGIN_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const HOME = homedir();
const STATE_DIR = join(HOME, ".claude", "model-banner");
const SHIM_PATH = join(STATE_DIR, "statusline.mjs");
const PLUGIN_ROOT_FILE = join(STATE_DIR, "plugin-root");
const SETTINGS_PATH = join(HOME, ".claude", "settings.json");
const USER_CONFIG_PATH = userConfigPath();
const SHIM_MARKER = "model-banner/statusline.mjs";

/** Returns: parsed object | null (absent) | undefined (exists but unparseable). */
function readJSON(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

function writeJSON(path, obj) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(obj, null, 2) + "\n", "utf8");
}

function readUserConfig() {
  const data = readJSON(USER_CONFIG_PATH);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { version: CONFIG_VERSION };
  }
  return data;
}

function writeUserConfig(cfg) {
  writeJSON(USER_CONFIG_PATH, cfg);
}

/** Backs up settings.json to a numbered .bak file; never overwrites an existing backup. Returns the backup path, or null if there was nothing to back up. */
function backupSettings() {
  if (!existsSync(SETTINGS_PATH)) return null;
  let candidate = `${SETTINGS_PATH}.model-banner.bak`;
  let i = 1;
  while (existsSync(candidate)) {
    i += 1;
    candidate = `${SETTINGS_PATH}.model-banner.bak-${i}`;
  }
  writeFileSync(candidate, readFileSync(SETTINGS_PATH, "utf8"), "utf8");
  return candidate;
}

function writeShim(pluginRoot) {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(SHIM_PATH, shimSource(pluginRoot), "utf8");
  writeFileSync(PLUGIN_ROOT_FILE, pluginRoot + "\n", "utf8");
}

function cmdInstall() {
  writeShim(PLUGIN_ROOT);

  const rawSettings = readJSON(SETTINGS_PATH);
  if (rawSettings === undefined) {
    console.error(
      `model-banner: ${SETTINGS_PATH} exists but is not valid JSON — aborting install. Fix or remove it, then re-run /model-banner init.`
    );
    process.exitCode = 1;
    return;
  }
  const settings = rawSettings || {};

  const existingCommand =
    settings.statusLine && typeof settings.statusLine.command === "string" ? settings.statusLine.command : null;
  const alreadyOurs = Boolean(existingCommand && existingCommand.includes(SHIM_MARKER));

  const cfg = readUserConfig();
  let chainedNote;
  if (!existingCommand) {
    chainedNote = "nothing (no prior statusLine command)";
  } else if (alreadyOurs) {
    chainedNote = `unchanged (${cfg.chain ? `already chaining "${cfg.chain}"` : "no chain recorded"})`;
  } else {
    cfg.chain = existingCommand;
    chainedNote = `"${existingCommand}"`;
  }
  cfg.version = CONFIG_VERSION;
  writeUserConfig(cfg);

  const backupPath = backupSettings();

  const newCommand = `node "${join(HOME, ".claude", "model-banner", "statusline.mjs")}"`;
  const nextSettings = { ...settings, statusLine: { ...(settings.statusLine || {}), command: newCommand } };
  writeJSON(SETTINGS_PATH, nextSettings);

  console.log("model-banner: installed.");
  console.log(`  settings backed up to: ${backupPath || "(no prior settings.json existed)"}`);
  console.log(`  chained status line:   ${chainedNote}`);
  console.log(`  size is "${cfg.size || "large"}" (5 rows) — run /model-banner size small for a one-row version`);
}

function cmdUninstall() {
  const settings = readJSON(SETTINGS_PATH);
  if (!settings) {
    console.log("model-banner: no settings.json to restore.");
    return;
  }
  const cfg = readUserConfig();
  const backupPath = backupSettings();
  const nextSettings = { ...settings };
  if (typeof cfg.chain === "string" && cfg.chain) {
    nextSettings.statusLine = { ...(settings.statusLine || {}), command: cfg.chain };
    console.log(`model-banner: restored statusLine.command to "${cfg.chain}".`);
  } else {
    delete nextSettings.statusLine;
    console.log("model-banner: removed the statusLine key (no prior command was recorded).");
  }
  writeJSON(SETTINGS_PATH, nextSettings);

  cfg.chain = null;
  writeUserConfig(cfg);

  console.log(`  settings backed up to: ${backupPath}`);
}

function cmdOnOff(enabled) {
  const cfg = readUserConfig();
  cfg.enabled = enabled;
  cfg.version = CONFIG_VERSION;
  writeUserConfig(cfg);
  console.log(`model-banner: ${enabled ? "ON" : "OFF"}${enabled ? "" : " (your chained status line, if any, keeps running)"}`);
}

function cmdSize(value) {
  if (!SIZES.includes(value)) {
    console.error(`model-banner: size must be one of ${SIZES.join(", ")} (got ${JSON.stringify(value)}).`);
    process.exitCode = 1;
    return;
  }
  const cfg = readUserConfig();
  cfg.size = value;
  cfg.version = CONFIG_VERSION;
  writeUserConfig(cfg);
  console.log(`model-banner: size set to "${value}".`);
}

function cmdLayout(value) {
  if (!LAYOUTS.includes(value)) {
    console.error(`model-banner: layout must be one of ${LAYOUTS.join(", ")} (got ${JSON.stringify(value)}).`);
    process.exitCode = 1;
    return;
  }
  const cfg = readUserConfig();
  cfg.layout = value;
  cfg.version = CONFIG_VERSION;
  writeUserConfig(cfg);
  console.log(`model-banner: layout set to "${value}".`);
}

function cmdColor(tier, color) {
  const validTiers = [...TIERS.map((t) => t.key), DEFAULT_TIER.key];
  if (!validTiers.includes(tier)) {
    console.error(`model-banner: tier must be one of ${validTiers.join(", ")} (got ${JSON.stringify(tier)}).`);
    process.exitCode = 1;
    return;
  }
  if (COLORS[color] === undefined) {
    console.error(`model-banner: color must be one of ${Object.keys(COLORS).join(", ")} (got ${JSON.stringify(color)}).`);
    process.exitCode = 1;
    return;
  }
  const cfg = readUserConfig();
  cfg.colors = { ...(cfg.colors || {}), [tier]: color };
  cfg.version = CONFIG_VERSION;
  writeUserConfig(cfg);
  console.log(`model-banner: ${tier} set to ${color}.`);
}

function cmdStatus() {
  const resolved = resolveConfig(process.cwd());
  const settings = readJSON(SETTINGS_PATH);
  const currentCommand =
    settings && settings.statusLine && typeof settings.statusLine.command === "string" ? settings.statusLine.command : null;
  const installed = existsSync(SHIM_PATH);
  const wired = Boolean(currentCommand && currentCommand.includes(SHIM_MARKER));

  const lines = [];
  lines.push(`model-banner: ${resolved.enabled ? "ON" : "OFF"} (from ${resolved.enabledSource})`);
  lines.push(`installed:    ${installed ? `yes (${SHIM_PATH})` : "no — run /model-banner init"}`);
  lines.push(`wired:        ${wired ? "yes — settings.json statusLine points at the shim" : "no — settings.json does not currently point at the shim"}`);
  lines.push(`size:         ${resolved.size} (from ${resolved.sizeSource})`);
  lines.push(`layout:       ${resolved.layout} (from ${resolved.layoutSource})`);
  lines.push(`user config:    ${resolved.layers.find((l) => l.scope === "user")?.path || `${resolved.userPath} (none)`}`);
  lines.push(`project config: ${resolved.layers.find((l) => l.scope === "project")?.path || `${resolved.projectPath || "(unknown cwd)"} (none)`}`);
  lines.push("colors:");
  for (const tier of [...TIERS, DEFAULT_TIER]) {
    const configured = resolved.colors[tier.key];
    const value = configured || tier.color;
    lines.push(`  ${tier.key.padEnd(8)} ${value.padEnd(12)}${configured ? ` (from ${resolved.colorSources[tier.key]})` : " (default)"}`);
  }
  lines.push(`chain:        ${resolved.chain ? `"${resolved.chain}"` : "(none)"}`);
  for (const warning of resolved.warnings) lines.push(warning);
  console.log(lines.join("\n"));
}

const [action, ...args] = process.argv.slice(2);

switch (action) {
  case "install":
    cmdInstall();
    break;
  case "uninstall":
    cmdUninstall();
    break;
  case "on":
    cmdOnOff(true);
    break;
  case "off":
    cmdOnOff(false);
    break;
  case "size":
    cmdSize(args[0]);
    break;
  case "layout":
    cmdLayout(args[0]);
    break;
  case "color":
    cmdColor(args[0], args[1]);
    break;
  case "status":
    cmdStatus();
    break;
  default:
    console.error(
      `model-banner: unknown action ${JSON.stringify(action)}. Usage: install|uninstall|on|off|size <large|compact|small>|layout <stack|side>|color <tier> <color>|status`
    );
    process.exitCode = 1;
}
