#!/bin/bash
# agent-hierarchy — spec 0048 §6 T6 (replaces test-mcp-cli-fallback.sh): docs/cli-tools.md is the
# verb reference roles are told to read, so it must stay in step with what the CLIs actually parse.
#
# Two properties, both derived from source rather than restated here:
#   1. every verb either CLI dispatches appears in the doc, spelled the same way;
#   2. every flag the doc shows for a verb is one that verb accepts — checked against the verb's own
#      strict flag set where roster.mjs has one (spec 0048 §10: several verbs REJECT unknown flags,
#      so a doc that invents one is worse than silent), and otherwise against the flags the CLI
#      source actually reads.
# Usage: bash tests/test-cli-tools-doc.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

REPORT=$(node -e '
const fs = require("fs");
const [roster, msg, doc] = process.argv.slice(1).map((p) => fs.readFileSync(p, "utf8"));

const rosterVerbs = [...roster.matchAll(/^    case "([a-z-]+)": \{/gm)].map((m) => m[1]);
const msgVerbs = [...msg.matchAll(/^    case "([a-z-]+)":/gm)].map((m) => m[1]);
if (rosterVerbs.length < 15 || msgVerbs.length < 5) {
  console.log(`FAIL: verb extraction looks broken (roster=${rosterVerbs.length} msg=${msgVerbs.length})`);
  process.exit(0);
}

const problems = [];
const missing = [];
for (const v of rosterVerbs) if (!doc.includes(`roster.mjs ${v} `) && !doc.includes(`roster.mjs ${v}\``)) missing.push(`roster.mjs ${v}`);
for (const v of msgVerbs) if (!doc.includes(`msg.mjs ${v} `) && !doc.includes(`msg.mjs ${v}\``)) missing.push(`msg.mjs ${v}`);
if (missing.length) problems.push(`verbs absent from docs/cli-tools.md: ${missing.join(", ")}`);

// strict per-verb flag sets, read out of roster.mjs itself
const setOf = (name) => {
  const m = new RegExp(`const ${name} = new Set\\(\\[([^\\]]+)\\]`).exec(roster);
  return m ? new Set([...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1])) : null;
};
const STRICT = {
  disband: "DISBAND_FLAGS", untrack: "UNTRACK_FLAGS", dismiss: "DISMISS_FLAGS", resync: "RESYNC_FLAGS",
  move: "MOVE_FLAGS", "spawn-one": "SPAWN_ONE_FLAGS", "spawn-ad-hoc": "AD_HOC_FLAGS", alias: "ALIAS_FLAGS",
  adopt: "ADOPT_FLAGS", reap: "REAP_FLAGS", checkin: "CHECKIN_FLAGS",
};
// every flag name the CLI source reads, for the verbs with no strict set
const readFlags = (src) =>
  new Set([
    ...[...src.matchAll(/opts\.([A-Za-z][A-Za-z0-9]*)/g)].map((m) => m[1]),
    ...[...src.matchAll(/opts\["([^"]+)"\]/g)].map((m) => m[1]),
  ]);
// a bool flag counts as accepted by being in BOOL_FLAGS even when the code never names it:
// --open is the default for msg.mjs list, selected by the absence of --closed/--all
const boolFlags = (src) => {
  const m = /const BOOL_FLAGS = new Set\(\[([^\]]+)\]/.exec(src);
  return m ? [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]) : [];
};
const rosterRead = new Set([...readFlags(roster), ...boolFlags(roster)]);
const msgRead = new Set([...readFlags(msg), ...boolFlags(msg)]);

// doc rows: "| label | <commands> |" — collect the flags shown per verb
for (const line of doc.split("\n")) {
  if (!line.startsWith("| ") || !line.includes("hooks/")) continue;
  const flags = [...line.matchAll(/--([a-z][a-z-]*)/g)].map((m) => m[1]);
  if (!flags.length) continue;
  const verbs = [...line.matchAll(/(roster|msg)\.mjs ([a-z-]+)/g)].map((m) => [m[1], m[2]]);
  if (!verbs.length) continue;
  const [script, verb] = verbs[0];
  const strict = script === "roster" && STRICT[verb] ? setOf(STRICT[verb]) : null;
  for (const f of flags) {
    if (f === "cwd") continue;
    if (strict) {
      if (!strict.has(f)) problems.push(`${script}.mjs ${verb}: doc shows --${f}, which ${STRICT[verb]} REJECTS`);
    } else {
      const read = script === "roster" ? rosterRead : msgRead;
      if (!read.has(f)) problems.push(`${script}.mjs ${verb}: doc shows --${f}, which the CLI source never reads`);
    }
  }
}
console.log(problems.length ? "FAIL\n" + problems.join("\n") : "OK");
' "$PLUGIN/hooks/roster.mjs" "$PLUGIN/hooks/msg.mjs" "$PLUGIN/docs/cli-tools.md" 2>&1)
[ "$REPORT" = "OK" ] || echo "$REPORT"
check "T6: every CLI verb is in docs/cli-tools.md and every documented flag is accepted by its verb" '[ "$REPORT" = "OK" ]'

# Control: a flag the verb rejects must be caught, so the check above cannot pass vacuously.
CONTROL=$(TMPDOC="$(mktemp)"; trap 'rm -f "$TMPDOC"' EXIT
  sed 's|roster.mjs reap \[--commit\]|roster.mjs reap [--commit] [--not-a-real-flag]|' "$PLUGIN/docs/cli-tools.md" > "$TMPDOC"
  node -e '
const fs = require("fs");
const roster = fs.readFileSync(process.argv[1], "utf8");
const doc = fs.readFileSync(process.argv[2], "utf8");
const m = /const REAP_FLAGS = new Set\(\[([^\]]+)\]/.exec(roster);
const set = new Set([...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]));
const row = doc.split("\n").find((l) => l.includes("roster.mjs reap"));
const flags = [...row.matchAll(/--([a-z][a-z-]*)/g)].map((x) => x[1]).filter((f) => f !== "cwd");
console.log(flags.some((f) => !set.has(f)) ? "caught" : "NOT-CAUGHT");
' "$PLUGIN/hooks/roster.mjs" "$TMPDOC")
check "T6 control: an invented flag on a strict verb is caught" '[ "$CONTROL" = "caught" ]'

# --help / no-verb contract (spec 0048 §2.6)
for script in roster msg; do
  OUT=$(node "$PLUGIN/hooks/$script.mjs" --help 2>&1); RC=$?
  check "$script.mjs --help prints usage and exits 0" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "'"$script"'.mjs"'
  OUT=$(node "$PLUGIN/hooks/$script.mjs" 2>&1); RC=$?
  check "$script.mjs with no verb prints usage and exits 0" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "'"$script"'.mjs"'
done

# One root-locating recipe, in this file. A cache glob can never be it: several versions coexist
# under the cache dir, so the newest directory there is not necessarily the one in use.
GLOBS=$(grep -rn 'ls -t ~/.claude/plugins/cache' "$PLUGIN/docs" "$PLUGIN/commands" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/hooks" "$PLUGIN/README.md" 2>/dev/null | grep -v '/docs/specs/' | grep -v '/docs/retired/' || true)
check "no cache-glob root recipe survives outside specs" '[ -z "$GLOBS" ]'

# $CLAUDE_PLUGIN_ROOT unbraced is the shell-expanded form, and the Bash tool's env leaves it EMPTY:
# anything printing it as part of a runnable command hands the reader a broken command.
UNBRACED=$(grep -rn '[$]CLAUDE_PLUGIN_ROOT' "$PLUGIN/docs" "$PLUGIN/commands" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/README.md" 2>/dev/null | grep -v '/docs/specs/' | grep -v '/docs/retired/' | grep -v '{CLAUDE_PLUGIN_ROOT' || true)
check "no unbraced \$CLAUDE_PLUGIN_ROOT in docs, commands, agents or skills" '[ -z "$UNBRACED" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
