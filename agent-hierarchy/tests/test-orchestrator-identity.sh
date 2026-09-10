#!/bin/bash
# agent-hierarchy — spec 0018 (orchestrator identity, now resolved entirely on the Bash path
# per spec 0048 §2.3): Bash-path
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

# ---- every CLI write site resolves its own pid the same way: CLAUDE_PID, or an explicit
# --orchestrator-pid. With neither, refusing is the only safe answer — the shell that runs these
# verbs is a transient Bash-tool subprocess whose pid is dead before the next sweep.
rm -f "$TEAM_FILE"
run create --commit --transport tmux --roster-level repo --verified '["myrepo-architect"]'
check "create --commit: CLAUDE_PID unset, no flag -> exit non-zero" '[ "$RC" -ne 0 ]'
check "create --commit: CLAUDE_PID unset -> message names CLAUDE_PID" 'echo "$OUT" | grep -q "CLAUDE_PID"'
check "create --commit: CLAUDE_PID unset -> no team.json written" '[ ! -e "$TEAM_FILE" ]'

run checkin
check "checkin: CLAUDE_PID unset, no flag -> exit non-zero" '[ "$RC" -ne 0 ]'
check "checkin: CLAUDE_PID unset -> message names CLAUDE_PID" 'echo "$OUT" | grep -q "CLAUDE_PID"'
check "checkin: CLAUDE_PID unset -> no team.json written" '[ ! -e "$TEAM_FILE" ]'

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

# ---------------------------------------------------------------------------
# spec 0048 §2.3 / §6 T5: msg.mjs resolves the owning team from --orchestrator-pid
# FIRST, falling back to CLAUDE_PID. Roster-side cases are above; this is the msg side.
# ---------------------------------------------------------------------------
( sleep 30 ) & PID_A=$!
( sleep 30 ) & PID_B=$!
TEAMS_DIR="$PROJ/.claude/hierarchy/teams"
mkdir -p "$TEAMS_DIR"
cat > "$TEAMS_DIR/alpha.json" <<EOF
{"version":1,"team_id":"alpha","created":"2026-01-01T00:00:00Z","roster_level":"repo","transport":"terminal","orchestrator":{"session_id":null,"pid":$PID_B},"members":[],"partial":false}
EOF
rm -f "$TEAM_FILE"

msg_team() {
  # $1 = CLAUDE_PID value, $2… = extra args; prints the `team:` frontmatter value of the new file
  local pid=$1; shift
  local path
  path=$(CLAUDE_PID="$pid" HOME="$FAKEHOME" node "$H/msg.mjs" new --to architect --from orchestrator --slug t5-probe --cwd "$PROJ" "$@" 2>&1 | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{process.stdout.write(JSON.parse(s).path||'')}catch{process.stdout.write('')}})")
  [ -n "$path" ] && grep -m1 '^team:' "$path" || echo "team: <no file>"
}

OUT=$(msg_team "$PID_B"); RC=0
check "T5: msg.mjs resolves the team from CLAUDE_PID when no flag is given" 'echo "$OUT" | grep -q "team: alpha"'
OUT=$(msg_team "$PID_A" --orchestrator-pid "$PID_B"); RC=0
check "T5: --orchestrator-pid wins over a CLAUDE_PID that owns nothing" 'echo "$OUT" | grep -q "team: alpha"'
OUT=$(msg_team "$PID_B" --orchestrator-pid "$PID_A"); RC=0
check "T5: --orchestrator-pid wins over a CLAUDE_PID that owns the team (override, not merge)" '! echo "$OUT" | grep -q "team: alpha"'
kill "$PID_A" "$PID_B" 2>/dev/null
rm -f "$TEAMS_DIR/alpha.json"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
