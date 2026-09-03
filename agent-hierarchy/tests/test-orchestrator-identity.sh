#!/bin/bash
# agent-hierarchy — spec 0018 (orchestrator identity on the MCP path): Bash-path
# refusals for the two write sites (create --commit is covered in test-roster-cli.sh;
# spawn-one is covered here), and the `adopt` recovery verb / hijack guard (§5).
# HOME-redirected; real state untouched.
# Usage: bash tests/test-orchestrator-identity.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-orch-identity-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

run() { OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

run init --level repo --route peer
run add --no-spawn --level repo --role architect --model opus

# ---- spawn-one (Bash path): CLAUDE_PID unset, no existing team -> refuses, exit 2,
# no team.json written (spec 0018 §3/§9, the second write site a commit-only fix misses)
rm -f "$TEAM_FILE"
run spawn-one architect
check "spawn-one: CLAUDE_PID unset, new team -> exit 2" '[ "$RC" -eq 2 ]'
check "spawn-one: CLAUDE_PID unset -> no team.json written" '[ ! -e "$TEAM_FILE" ]'

# ---- spawn-one: dead --orchestrator-pid -> refuses, distinct message, no team.json
OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" spawn-one architect --orchestrator-pid 99999999 --cwd "$PROJ" 2>&1); RC=$?
check "spawn-one: dead --orchestrator-pid -> exit 2" '[ "$RC" -eq 2 ]'
check "spawn-one: dead --orchestrator-pid -> no team.json written" '[ ! -e "$TEAM_FILE" ]'

# ---- spec 0018 §5: `adopt` recovery verb
# Orphaned (null-owner) team, hand-written directly — post-0018 no CLI path can ever
# produce this shape again, but it is exactly what a pre-fix commit left behind.
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$PROJ/.claude/hierarchy', { version: 1, team_id: 'orphan-1', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: null, pid: null }, members: [{ role: 'architect', name: 'myrepo-architect' }], partial: false }, null);
"
BEFORE_MEMBERS=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$TEAM_FILE','utf8')).members))")
( sleep 30 ) & ADOPT_PID=$!
run adopt --orchestrator-pid "$ADOPT_PID"
check "adopt: orphan (null owner) -> succeeds" '[ "$RC" -eq 0 ]'
check "adopt: orphan -> orchestrator.pid re-stamped" "grep -q '\"pid\": $ADOPT_PID' '$TEAM_FILE'"
AFTER_MEMBERS=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$TEAM_FILE','utf8')).members))")
check "adopt: members byte-identical before/after" '[ "$BEFORE_MEMBERS" = "$AFTER_MEMBERS" ]'
check "adopt: team_id unchanged" '[ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).team_id)")" = "orphan-1" ]'
kill "$ADOPT_PID" 2>/dev/null

# ---- adopt: recorded owner alive and different -> hijack guard refuses, before any write
( sleep 30 ) & OWNER_PID=$!
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$PROJ/.claude/hierarchy', { version: 1, team_id: 'owned-1', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: null, pid: $OWNER_PID }, members: [], partial: false }, null);
"
( sleep 30 ) & OTHER_PID=$!
run adopt --orchestrator-pid "$OTHER_PID"
check "adopt: recorded owner alive and different -> refused" '[ "$RC" -eq 2 ]'
check "adopt: hijack guard -> orchestrator.pid unchanged" "grep -q '\"pid\": $OWNER_PID' '$TEAM_FILE'"
kill "$OTHER_PID" 2>/dev/null

# ---- adopt: recorded owner dead -> allowed
kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null
( sleep 30 ) & NEWOWNER_PID=$!
run adopt --orchestrator-pid "$NEWOWNER_PID"
check "adopt: recorded owner dead -> allowed" '[ "$RC" -eq 0 ]'
check "adopt: dead-owner adopt -> pid re-stamped" "grep -q '\"pid\": $NEWOWNER_PID' '$TEAM_FILE'"
kill "$NEWOWNER_PID" 2>/dev/null

# ---- adopt: supplied pid itself dead -> refused
run adopt --orchestrator-pid 99999999
check "adopt: supplied pid dead -> refused" '[ "$RC" -eq 2 ]'

# ---- adopt: no team file at this scope -> refused
rm -f "$TEAM_FILE"
( sleep 30 ) & NOTEAM_PID=$!
run adopt --orchestrator-pid "$NOTEAM_PID"
check "adopt: no team file at this scope -> refused" '[ "$RC" -eq 2 ]'
kill "$NOTEAM_PID" 2>/dev/null

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
