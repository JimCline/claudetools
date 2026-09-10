#!/usr/bin/env node
// agent-hierarchy — gate/matcher agreement check (spec 0042 §4 item 4, re-keyed by 0048 §2.4.5).
// The ah CLIs are invoked through the Bash tool, so "agreement" now means: every PreToolUse gate
// that keys on a parsed ah command is wired on the `Bash` matcher, no matcher mentions an MCP tool
// name any more, and each gate's VERB SET is exactly the set its spec section names. The verb sets
// are the thing that drifts — a verb added to a gate's body but not to the spec list, or a gate
// quietly narrowed — and that drift is what shipped the disband-close gate inert once already
// (0042 §1.6). Assert it structurally, don't trust it.
//
// Parses hook source as text rather than importing the .mjs modules: the gate hooks run their whole
// PreToolUse body via top-level await at import time (reading stdin, then process.exit), so
// `import()`ing them here would hang/exit this test process.

import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const HOOKS_DIR = join(ROOT, "hooks");
const HOOKS_JSON = JSON.parse(readFileSync(join(HOOKS_DIR, "hooks.json"), "utf8"));

// hook file → [the const whose array literal holds its verbs, the file that const lives in,
// the verb set spec 0048 names for it]. The close gate's verbs live in the shared parser, which is
// the single definition the allow hook's silence and the gate's `ask` both read (0048 §2.4.2).
const GATES = [
  {
    hook: "pretooluse-disband-close-gate.mjs",
    source: "lib-ah-cli.mjs",
    constName: "CLOSE_VERBS",
    expect: ["dismiss", "disband"],
    spec: "0048 §2.4.2",
  },
  {
    hook: "pretooluse-roster-skill-gate.mjs",
    source: "pretooluse-roster-skill-gate.mjs",
    constName: "VERBS",
    expect: ["create", "spawn-one", "spawn-ad-hoc", "adopt", "move", "dismiss", "disband", "untrack"],
    spec: "0048 §2.4.3",
  },
];

function verbsFrom(file, constName) {
  const src = readFileSync(join(HOOKS_DIR, file), "utf8");
  const m = src.match(new RegExp(`(?:const|let)\\s+${constName}\\s*=\\s*(?:new Set\\()?\\[([^\\]]+)\\]`));
  if (!m) return null;
  const verbs = [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
  return verbs.length ? verbs : null;
}

function rulesFor(hookFile) {
  return (HOOKS_JSON.hooks.PreToolUse || []).filter((r) =>
    (r.hooks || []).some((h) => typeof h.command === "string" && h.command.includes(`hooks/${hookFile}`))
  );
}

let fail = false;

for (const rule of HOOKS_JSON.hooks.PreToolUse || []) {
  if (typeof rule.matcher === "string" && rule.matcher.includes("mcp__")) {
    console.log(`FAIL: PreToolUse matcher still names MCP tools: ${rule.matcher}`);
    fail = true;
  }
}

for (const gate of GATES) {
  const rules = rulesFor(gate.hook);
  if (rules.length !== 1) {
    console.log(`FAIL ${gate.hook}: expected exactly one hooks.json PreToolUse rule to run it, found ${rules.length}`);
    fail = true;
    continue;
  }
  if (rules[0].matcher !== "Bash") {
    console.log(`FAIL ${gate.hook}: matcher is ${JSON.stringify(rules[0].matcher)}, must be "Bash" (${gate.spec})`);
    fail = true;
  }
  const verbs = verbsFrom(gate.source, gate.constName);
  if (!verbs) {
    console.log(`FAIL ${gate.hook}: could not statically extract ${gate.constName} from hooks/${gate.source}`);
    fail = true;
    continue;
  }
  const onlyBody = verbs.filter((v) => !gate.expect.includes(v));
  const onlySpec = gate.expect.filter((v) => !verbs.includes(v));
  if (onlyBody.length || onlySpec.length) {
    console.log(`FAIL ${gate.hook}: verb set drifted from ${gate.spec} — extra=${JSON.stringify(onlyBody)} missing=${JSON.stringify(onlySpec)}`);
    fail = true;
  } else {
    console.log(`PASS ${gate.hook}: matcher Bash, ${verbs.length} verbs agree with ${gate.spec}`);
  }
}

// The allow hook must be wired on the same matcher, or nothing grants the prompt-free path.
const allowRules = rulesFor("pretooluse-ah-cli.mjs");
if (allowRules.length !== 1 || allowRules[0].matcher !== "Bash") {
  console.log(`FAIL pretooluse-ah-cli.mjs: expected exactly one PreToolUse rule on matcher "Bash", found ${JSON.stringify(allowRules.map((r) => r.matcher))}`);
  fail = true;
} else {
  console.log("PASS pretooluse-ah-cli.mjs: wired on matcher Bash");
}

// SubagentStart is the only channel that reaches an Agent-tool subagent, so an unwired or
// narrowly-matched entry leaves every subagent without the absolute CLI paths.
const subStart = (HOOKS_JSON.hooks.SubagentStart || []).filter((r) =>
  (r.hooks || []).some((h) => typeof h.command === "string" && h.command.includes("hooks/subagentstart-cli-root.mjs"))
);
if (subStart.length !== 1 || subStart[0].matcher !== "*") {
  console.log(`FAIL subagentstart-cli-root.mjs: expected exactly one SubagentStart rule on matcher "*", found ${JSON.stringify(subStart.map((r) => r.matcher))}`);
  fail = true;
} else {
  console.log('PASS subagentstart-cli-root.mjs: wired on SubagentStart matcher "*"');
}

process.exit(fail ? 1 : 0);
