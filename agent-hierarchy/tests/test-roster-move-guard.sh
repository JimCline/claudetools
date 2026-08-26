#!/bin/bash
# agent-hierarchy — roster.mjs `move`'s requireAllowGlobal guard (spec 0016 §4.4): `move` relocates
# a live agent pane and was unguarded on every path before this change. The guard must match sites
# 624 (create --spawn) / 1135 (spawn-one) exactly — same helper, same argument shape, same message.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-move-guard.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-move-guard-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

echo '[]' > "$SANDBOX/agents.json"
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
if (args[0] === "agent" && args[1] === "list") {
  const agents = JSON.parse(fs.readFileSync(process.env.FAKE_HERDR_STATE, "utf8"));
  console.log(JSON.stringify({ id: "cli:agent:list", result: { agents, type: "agent_list" } }));
  process.exit(0);
}
if (args[0] === "pane" && args[1] === "move") {
  console.log(JSON.stringify({ id: "cli:pane:move", result: { ok: true } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(args) + "\n");
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "PANE1", "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF

# ---- no roster configured at all: move is not gated (requireAllowGlobal no-ops when resolveRoster returns null)
run move myrepo-architect --new-workspace
check "move (no roster resolves anywhere): not global-gated, succeeds" '[ "$RC" -eq 0 ]'

# ---- a repo-level roster: not global, no guard fires
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
run move myrepo-architect --new-workspace
check "move (repo-level roster): not global, succeeds without --allow-global" '[ "$RC" -eq 0 ]'
rm -f "$PROJ/.claude/agent-hierarchy.json"

# ---- a global-level roster: guarded, same message style as spawn-one/create --spawn
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
run move myrepo-architect --new-workspace
check "move (global roster, no --allow-global): exit 2" '[ "$RC" -eq 2 ]'
check "move (global roster, no --allow-global): message names GLOBAL level and --allow-global (matches 624/1135 style)" \
  'echo "$OUT" | grep -q "GLOBAL level" && echo "$OUT" | grep -q "\-\-allow-global"'

run move myrepo-architect --new-workspace --allow-global
check "move --allow-global: proceeds against the global roster" '[ "$RC" -eq 0 ]'
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
