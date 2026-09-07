#!/usr/bin/env node
// agent-hierarchy — generic name-agreement check (spec 0042 §4 item 4): for every
// PreToolUse gate that enumerates this plugin's own MCP tool names, the set the hook
// BODY gates and the set the hooks.json MATCHER selects for it must be identical, and
// every enumerated verb must appear under both the `mcp__plugin_ah_ah__` and
// `mcp__ah__` prefixes. This is the exact hole that shipped the disband-close gate
// inert while its own tests passed (0042 §1.6) — assert it structurally, don't trust it.
//
// Parses hook source as text rather than importing the .mjs modules: both gate hooks
// run their whole PreToolUse body via top-level await at import time (reading stdin,
// then process.exit), so `import()`ing them here would hang/exit this test process.
//
// Gate discovery is generic (0042 review G2): every hooks.json PreToolUse rule whose
// matcher contains "mcp__" is treated as a gate under test, not a hardcoded file list —
// a third such gate added later is covered automatically. A rule whose hook file's name
// set cannot be statically extracted FAILS the check rather than being silently skipped.

import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const HOOKS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "hooks");
const HOOKS_JSON = JSON.parse(readFileSync(join(HOOKS_DIR, "hooks.json"), "utf8"));
const PREFIXES = ["mcp__plugin_ah_ah__", "mcp__ah__"];

function verbOf(name) {
  return PREFIXES.reduce((n, p) => (n.startsWith(p) ? n.slice(p.length) : n), name);
}

// Strategy A: an explicit, fully-qualified set — `<NAME> = new Set([...literal strings...])`.
// Scoped to the initializer's own bracket contents, never the whole file (0042 review G1:
// a whole-file literal scrape double-counted `DISMISS_CLOSE_TOOLS`, which duplicates two of
// `GATED_TOOLS`'s four names, reporting 6 for a gate that gates 4).
function namesFromLiteralSet(src) {
  const m = src.match(/(?:const|let)\s+GATED_TOOLS\s*=\s*new Set\(\[([\s\S]*?)\]\)/);
  if (!m) return null;
  const names = [...m[1].matchAll(/"(mcp__[A-Za-z0-9_]+)"/g)].map((x) => x[1]);
  return names.length ? names : null;
}

// Strategy B: verbs crossed with prefixes, e.g. `VERBS.flatMap((v) => [\`mcp__plugin_ah_ah__${v}\`, \`mcp__ah__${v}\`])`.
// Prefixes are read out of the flatMap's own template literals so a differently-prefixed
// gate is still discovered; falls back to this file's PREFIXES only if that read fails.
function namesFromVerbs(src) {
  const vm = src.match(/(?:const|let)\s+VERBS\s*=\s*\[([^\]]+)\]/);
  if (!vm) return null;
  const verbs = [...vm[1].matchAll(/"([^"]+)"/g)].map((v) => v[1]);
  if (!verbs.length) return null;
  const fm = src.match(/flatMap\(\(v\)\s*=>\s*\[([^\]]+)\]\)/);
  const templatePrefixes = fm ? [...fm[1].matchAll(/`([^`]*)\$\{v\}`/g)].map((m) => m[1]) : [];
  const prefixes = templatePrefixes.length ? templatePrefixes : PREFIXES;
  return verbs.flatMap((v) => prefixes.map((p) => `${p}${v}`));
}

function extractGatedNames(hookFile) {
  let src;
  try {
    src = readFileSync(join(HOOKS_DIR, hookFile), "utf8");
  } catch {
    return null;
  }
  return namesFromLiteralSet(src) || namesFromVerbs(src) || null;
}

function hookFilesForRule(rule) {
  return rule.hooks
    .map((h) => (typeof h.command === "string" ? h.command.match(/hooks\/([\w.-]+\.mjs)/) : null))
    .filter(Boolean)
    .map((m) => m[1]);
}

let fail = false;
const rules = (HOOKS_JSON.hooks.PreToolUse || []).filter((r) => typeof r.matcher === "string" && r.matcher.includes("mcp__"));

if (!rules.length) {
  console.log("FAIL: no hooks.json PreToolUse rule matches any mcp__ tool name — discovery found nothing to check");
  fail = true;
}

for (const rule of rules) {
  const matcher = rule.matcher.split("|");
  const matcherSet = new Set(matcher);
  for (const hookFile of hookFilesForRule(rule)) {
    const body = extractGatedNames(hookFile);
    if (!body) {
      console.log(`FAIL ${hookFile}: matcher "${rule.matcher}" contains mcp__ names but no gated-name set could be statically extracted from the hook body`);
      fail = true;
      continue;
    }
    const bodySet = new Set(body);
    const onlyBody = body.filter((n) => !matcherSet.has(n));
    const onlyMatcher = matcher.filter((n) => !bodySet.has(n));
    if (onlyBody.length || onlyMatcher.length) {
      console.log(`FAIL ${hookFile}: body/matcher disagree — onlyBody=${JSON.stringify(onlyBody)} onlyMatcher=${JSON.stringify(onlyMatcher)}`);
      fail = true;
    } else {
      console.log(`PASS ${hookFile}: body and matcher agree (${bodySet.size} names)`);
    }

    const verbs = [...new Set(body.map(verbOf))];
    for (const verb of verbs) {
      const missing = PREFIXES.filter((p) => !bodySet.has(`${p}${verb}`));
      if (missing.length) {
        console.log(`FAIL ${hookFile}: verb "${verb}" missing prefix(es) ${JSON.stringify(missing)}`);
        fail = true;
      }
    }
  }
}

process.exit(fail ? 1 : 0);
