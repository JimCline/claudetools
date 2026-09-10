#!/bin/bash
# agent-hierarchy — spec 0048 §6 T1/T2/T7/T8: the shared ah-command parser (hooks/lib-ah-cli.mjs),
# the allow hook (hooks/pretooluse-ah-cli.mjs), the no-MCP invariant, and the hooks.json wiring.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-ah-cli.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-ah-cli-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

# ---------------------------------------------------------------------------
# T1 — the grammar. Table-driven, run inside one node process against the module.
# ---------------------------------------------------------------------------
R="/opt/ah/0.73.0/hooks/roster.mjs"
M="/opt/ah/0.73.0/hooks/msg.mjs"
T1=$(node -e '
const { parseAhCommand, ROSTER_BOOL_FLAGS, MSG_BOOL_FLAGS } = await import(process.argv[1]);
const R = "/opt/ah/0.73.0/hooks/roster.mjs";
const M = "/opt/ah/0.73.0/hooks/msg.mjs";
const bad = [];
const ok = (cmd, want) => {
  const p = parseAhCommand(cmd);
  if (!p) return bad.push(`rejected but should parse: ${cmd}`);
  for (const [k, v] of Object.entries(want)) {
    const got = k === "flags" || k === "positional" ? JSON.stringify(p[k]) : p[k];
    const exp = k === "flags" || k === "positional" ? JSON.stringify(v) : v;
    if (got !== exp) bad.push(`${cmd} → ${k}=${got}, want ${exp}`);
  }
};
const no = (cmd) => { if (parseAhCommand(cmd)) bad.push(`accepted but must be rejected: ${cmd}`); };

// every documented shape parses
ok(`node ${R} show --cwd /repo`, { script: "roster", verb: "show", flags: {"cwd": "/repo"} });
ok(`node ${R} teams --cwd /repo`, { script: "roster", verb: "teams" });
ok(`node ${R} dismiss bob --close --confirm --plan-token t9 --cwd /repo`,
   { script: "roster", verb: "dismiss", positional: ["bob"], flags: {"close": true, "confirm": true, "plan-token": "t9", "cwd": "/repo"} });
ok(`node ${R} disband --close --confirm --plan-token t9 --allow-global --cwd /repo`, { verb: "disband", flags: {"close": true, "confirm": true, "plan-token": "t9", "allow-global": true, "cwd": "/repo"} });
ok(`node ${R} spawn-one architect --dry-run --cwd /repo`, { verb: "spawn-one", positional: ["architect"], flags: {"dry-run": true, "cwd": "/repo"} });
ok(`node ${R} create --commit --verified \x27[{"name":"a-architect","role":"architect"}]\x27 --transport terminal --roster-level repo --cwd /repo`,
   { verb: "create", flags: {"commit": true, "verified": "[{\"name\":\"a-architect\",\"role\":\"architect\"}]", "transport": "terminal", "roster-level": "repo", "cwd": "/repo"} });
ok(`node ${R} move bob --tab t1 --split right --cwd /repo`, { verb: "move", positional: ["bob"] });
ok(`node ${R} untrack --all --commit --keep-sessions --cwd /repo`, { verb: "untrack", flags: {"all": true, "commit": true, "keep-sessions": true, "cwd": "/repo"} });
ok(`node ${M} new --to architect --from orchestrator --slug s --cwd /repo`, { script: "msg", verb: "new" });
ok(`node ${M} list --open --to implementor --cwd /repo`, { script: "msg", verb: "list", flags: {"open": true, "to": "implementor", "cwd": "/repo"} });
ok(`node ${M} index /repo/.claude/hierarchy/msgs/x--request.md`, { script: "msg", verb: "index", positional: ["/repo/.claude/hierarchy/msgs/x--request.md"] });
ok(`node "${R}" show --cwd /repo`, { script: "roster", verb: "show" });            // wholly double-quoted path
ok(`node \x27${R}\x27 show --cwd "/re po"`, { script: "roster", flags: {"cwd": "/re po"} }); // quoted arg with a space

// rejections — every one must fail closed
no(`cd /x && node ${R} show --cwd /repo`);
no(`node ${R} show --cwd /repo ; rm -rf /`);
no(`node ${R} show --cwd /repo | cat`);
no(`node ${R} show --cwd "$PWD"`);
no(`node ${R} show --cwd $(id)`);
no("node " + R + " show --cwd `id`");
no(`FOO=1 node ${R} show --cwd /repo`);
no(`nodejs ${R} show --cwd /repo`);
no(`node /tmp/x/roster.mjs show --cwd /repo`);          // not a hooks/ dir
no(`node /opt/ah/0.73.0/hooks/other.mjs show`);          // not one of the two scripts
// glob/expansion chars in a BARE script token: the shell expands these before node resolves the
// path, so the literal we parse need not be the file that runs (D1).
no(`node /opt/ah/*/hooks/roster.mjs show --cwd /repo`);   // glob: *
no(`node /opt/ah/0.7?.0/hooks/roster.mjs show --cwd /repo`); // glob: ?
no(`node /opt/ah/[a]/hooks/roster.mjs show --cwd /repo`); // glob: [ ]
no(`node /opt/ah/{a,b}/hooks/roster.mjs show --cwd /repo`); // brace expansion
no(`node ~/ah/hooks/roster.mjs show --cwd /repo`);        // tilde expansion
ok(`node \x27/opt/ah/*/hooks/roster.mjs\x27 show --cwd /repo`, { script: "roster" }); // quoted: nothing expands, literal path stands
no(`node ${R} show --cwd /repo\nrm -rf /`);
no(`node ${R} show > /tmp/out`);
no(`node ${R} show --cwd /repo &`);
no(`node ${R} show --cwd /re\\ po`);                     // backslash outside quotes
no(`node ${R} show --cwd \x27/repo`);                    // unterminated quote
no("");
no("node");

// the bool-flag sets are copies of the CLIs own — assert equality against the source
const fs = await import("node:fs");
const setOf = (file) => {
  const src = fs.readFileSync(file, "utf8");
  const m = /const BOOL_FLAGS = new Set\(\[([^\]]+)\]/.exec(src);
  return m ? [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]).sort() : null;
};
const rosterSrc = setOf(process.argv[2]);
const msgSrc = setOf(process.argv[3]);
if (!rosterSrc || !msgSrc) bad.push("could not extract BOOL_FLAGS from the CLIs");
else {
  if (JSON.stringify(rosterSrc) !== JSON.stringify([...ROSTER_BOOL_FLAGS].sort())) bad.push(`roster bool flags drifted: cli=${rosterSrc} parser=${[...ROSTER_BOOL_FLAGS].sort()}`);
  if (JSON.stringify(msgSrc) !== JSON.stringify([...MSG_BOOL_FLAGS].sort())) bad.push(`msg bool flags drifted: cli=${msgSrc} parser=${[...MSG_BOOL_FLAGS].sort()}`);
}
console.log(bad.length ? "FAIL\n" + bad.join("\n") : "OK");
' "$PLUGIN/hooks/lib-ah-cli.mjs" "$PLUGIN/hooks/roster.mjs" "$PLUGIN/hooks/msg.mjs" 2>&1)
OUT="$T1"; RC=0
check "T1: the grammar accepts every documented form and rejects every unsafe one; bool sets match the CLIs" '[ "$T1" = "OK" ]'

# ---------------------------------------------------------------------------
# T2 — the allow hook. Run from a COPY of the plugin so the sibling rule is real.
# ---------------------------------------------------------------------------
INST="$SANDBOX/inst"
mkdir -p "$INST/A" "$INST/B" "$SANDBOX/outside"
cp -R "$PLUGIN/hooks" "$INST/A/hooks"
cp -R "$PLUGIN/hooks" "$INST/B/hooks"
cp -R "$PLUGIN/hooks" "$SANDBOX/outside/hooks"
AHOOK="$INST/A/hooks/pretooluse-ah-cli.mjs"

allow_hook() {
  OUT=$(node -e 'process.stdout.write(JSON.stringify({ session_id: "s1", cwd: "/repo", tool_name: process.argv[2] || "Bash", tool_input: { command: process.argv[1] } }))' "$1" "$2" \
    | HOME="$FAKEHOME" node "$AHOOK" 2>&1); RC=$?
}
is_allow() { case "$OUT" in *'"permissionDecision":"allow"'*) return 0;; *) return 1;; esac; }

allow_hook "node $INST/A/hooks/roster.mjs show --cwd /repo"
check "T2: recognised command under the hook's own root → allow" '[ "$RC" -eq 0 ] && is_allow'
allow_hook "node $INST/B/hooks/roster.mjs show --cwd /repo"
check "T2: same command under a SIBLING install dir → allow (post-bump root)" '[ "$RC" -eq 0 ] && is_allow'
allow_hook "node $INST/A/hooks/msg.mjs list --open --cwd /repo"
check "T2: msg.mjs is allowed too" '[ "$RC" -eq 0 ] && is_allow'
allow_hook "node $SANDBOX/outside/hooks/roster.mjs show --cwd /repo"
check "T2: a copy outside the root and its siblings → no output (normal prompt)" '[ -z "$OUT" ]'
allow_hook "node $INST/A/hooks/roster.mjs dismiss bob --close --confirm --plan-token t --cwd /repo"
check "T2: a close command → no output (the close gate's ask must stand alone)" '[ -z "$OUT" ]'
allow_hook "node $INST/A/hooks/roster.mjs disband --close --confirm --plan-token t --cwd /repo"
check "T2: disband --close → no output" '[ -z "$OUT" ]'
allow_hook "node $INST/A/hooks/roster.mjs disband --cwd /repo"
check "T2: the disband PLAN form is allowed (only --close is withheld)" '[ "$RC" -eq 0 ] && is_allow'
allow_hook "ls -la"
check "T2: an unrelated Bash command → no output" '[ -z "$OUT" ]'
allow_hook "node $INST/A/hooks/roster.mjs show --cwd /repo" "Read"
check "T2: a non-Bash tool → no output" '[ -z "$OUT" ]'
OUT=$(printf 'not json' | HOME="$FAKEHOME" node "$AHOOK" 2>&1); RC=$?
check "T2: malformed payload → RC 0, no output" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# every T1 rejection must also be silent at the hook (the grammar IS the boundary)
REJ_FAIL=""
while IFS= read -r cmd; do
  allow_hook "$cmd"
  [ -n "$OUT" ] && REJ_FAIL="$REJ_FAIL|$cmd"
done <<EOF
cd /x && node $INST/A/hooks/roster.mjs show --cwd /repo
node $INST/A/hooks/roster.mjs show --cwd /repo ; rm -rf /tmp/nothing
node $INST/A/hooks/roster.mjs show --cwd /repo | cat
node $INST/A/hooks/roster.mjs show --cwd "\$PWD"
FOO=1 node $INST/A/hooks/roster.mjs show --cwd /repo
nodejs $INST/A/hooks/roster.mjs show --cwd /repo
node $INST/A/hooks/roster.mjs show > /tmp/ah-test-out
EOF
check "T2: every rejected form is silent at the hook (never allowed on a partial parse)" '[ -z "$REJ_FAIL" ]'

# ---------------------------------------------------------------------------
# T7 — the no-MCP invariant
# ---------------------------------------------------------------------------
HITS=$(cd "$PLUGIN" && grep -rl 'mcp__\|mcpServers\|server\.mjs\|AH_MCP' agents/ skills/ commands/ hooks/ README.md docs/*.md .claude-plugin/ 2>/dev/null)
OUT="$HITS"
check "T7: no mcp__/mcpServers/server.mjs/AH_MCP reference outside docs/specs and tests" '[ -z "$HITS" ]'
check "T7: the mcp/ directory is gone" '[ ! -d "$PLUGIN/mcp" ]'
check "T7: no MCP matcher survives in hooks.json" '! grep -q "mcp__" "$PLUGIN/hooks/hooks.json"'
check "T7: docs/cli-tools.md replaced docs/mcp-tools.md" '[ -f "$PLUGIN/docs/cli-tools.md" ] && [ ! -f "$PLUGIN/docs/mcp-tools.md" ]'

# ---------------------------------------------------------------------------
# T8 — hooks.json wiring
# ---------------------------------------------------------------------------
WIRING=$(node -e '
const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const bad = [];
const bash = (cfg.hooks.PreToolUse || []).filter((r) => r.matcher === "Bash");
const cmds = bash.flatMap((r) => r.hooks.map((h) => h.command));
for (const f of ["pretooluse-ah-cli.mjs", "pretooluse-disband-close-gate.mjs", "pretooluse-roster-skill-gate.mjs"]) {
  if (!cmds.some((c) => c.includes(f))) bad.push(`${f} is not on a Bash matcher`);
}
const ss = JSON.stringify(cfg.hooks.SessionStart || []);
if (ss.includes("sessionstart-mcp-ensure")) bad.push("sessionstart-mcp-ensure entry survives");
console.log(bad.length ? "FAIL " + bad.join("; ") : "PASS");
' "$PLUGIN/hooks/hooks.json")
check "T8: allow hook + both gates on matcher Bash, no sessionstart-mcp-ensure entry" '[ "$WIRING" = "PASS" ]'
NA=$(node "$PLUGIN/tests/check-gate-name-agreement.mjs" >/dev/null 2>&1; echo $?)
check "T8: check-gate-name-agreement.mjs passes" '[ "$NA" -eq 0 ]'
check "T8: sessionstart-mcp-ensure.mjs is deleted" '[ ! -f "$PLUGIN/hooks/sessionstart-mcp-ensure.mjs" ]'

# ---------------------------------------------------------------------------
# §2.1: SessionStart publishes the absolute CLI root — the only channel roles have
# ---------------------------------------------------------------------------
ROOT_LINE=$(printf '{"source":"startup","cwd":"%s","session_id":"root-line","agent_type":"ah:implementor"}' "$PLUGIN" \
  | HOME="$FAKEHOME" node "$PLUGIN/hooks/sessionstart.mjs" 2>&1)
OUT="$ROOT_LINE"
check "§2.1: SessionStart injects an 'ah CLI root:' line naming the absolute root and both scripts" \
  'echo "$ROOT_LINE" | grep -q "ah CLI root: $PLUGIN" && echo "$ROOT_LINE" | grep -q "$PLUGIN/hooks/roster.mjs" && echo "$ROOT_LINE" | grep -q "$PLUGIN/hooks/msg.mjs"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
