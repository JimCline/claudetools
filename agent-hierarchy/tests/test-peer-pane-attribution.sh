#!/bin/bash
# agent-hierarchy — liveness readers attribute a nameless peers.jsonl row to the team member whose
# transport_id is that row's pane (and whose role matches), so a spawned peer that never got a
# name on its SessionStart row still reads live: spawn-one refuses a duplicate, teams/dismiss see
# it, the route gate names it. SessionEnd's down row carries the pane so a closed peer reads dead.
# Usage: bash tests/test-peer-pane-attribution.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-pane-attr-test.XXXXXX")"
sleep 600 & LIVE_PID=$!
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}
has() { echo "$OUT" | tr -d " \n" | grep -q "$1"; }
jq_ok() { echo "$OUT" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const o=JSON.parse(s);process.exit(($1)?0:1)})"; }

# Fake herdr: logs every invocation, answers nothing useful — a launch attempt is the failure.
INVOKED_LOG="$SANDBOX/herdr-invoked.log"
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env node
require("fs").appendFileSync(process.env.FAKE_HERDR_INVOKED_LOG, JSON.stringify(process.argv.slice(2)) + "\n");
if (process.argv[2] === "agent" && process.argv[3] === "list") { console.log(JSON.stringify({ result: { agents: [] } })); process.exit(0); }
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"
launches() { grep -c '"agent","start"' "$INVOKED_LOG" 2>/dev/null || true; }

run() { OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$SANDBOX/bin:$NODE_DIR:/usr/bin:/bin" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

HIER="$PROJ/.claude/hierarchy"
PEERS_FILE="$HIER/peers.jsonl"
TEAM="$HIER/team.json"
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF

write_team() { # <path> <team_id> <members-json>
  mkdir -p "$(dirname "$1")"
  node -e 'const fs=require("fs");const[p,id,m]=process.argv.slice(1);
    fs.writeFileSync(p, JSON.stringify({version:1,team_id:id,created:"2026-01-01T00:00:00Z",roster_level:"repo",transport:"herdr",
      orchestrator:{session_id:null,pid:null},members:JSON.parse(m),partial:false}, null, 2));' "$1" "$2" "$3"
}
ARCH_MEMBER='[{"role":"architect","name":"myrepo-architect","ref":"r1","route":"peer","model":"opus","transport_id":"PANE1","checked_in":"2026-01-01T00:00:00Z"}]'
seed() { # <json fields> — one peers.jsonl row; ts defaults to now
  node -e 'const fs=require("fs");const[f,j]=process.argv.slice(1);const r={type:"peer",ts:new Date().toISOString(),...JSON.parse(j)};fs.appendFileSync(f,JSON.stringify(r)+"\n");' "$PEERS_FILE" "$1"
}
SID="abcdef0123456789-arch"
fresh() { rm -rf "$HIER"; mkdir -p "$HIER"; : > "$INVOKED_LOG"; write_team "$TEAM" t-default "$ARCH_MEMBER"; }
up_row() { # <pid> [role] [session]
  seed "{\"status\":\"up\",\"role\":\"${2:-architect}\",\"pid\":$1,\"pane_id\":\"PANE1\",\"session_id\":\"${3:-$SID}\",\"cwd\":\"$PROJ\"}"
}

# ---- 1: a nameless up row on the member's pane, live pid -> spawn-one refuses, no launch
fresh; up_row "$LIVE_PID"
run spawn-one architect --orchestrator-pid $$
check "1: spawn-one sees the pane-attributed member as already live" 'has "\"reason\":\"alreadylive\""'
check "1b: spawn-one launched nothing" '[ "$(launches)" -eq 0 ]'

# ---- 2: teams/dismiss/untrack read the member live and do not list it as untracked
run teams
check "2: teams does not list the member as untracked role@sid8" '[ "$RC" -eq 0 ] && ! has "architect@abcdef01"'
run dismiss myrepo-architect --plan
check "2b: dismiss plan shows the member live" '[ "$RC" -eq 0 ] && jq_ok "o.live===true"'
check "2c: dismiss plan counts one live peer" 'jq_ok "o.sources.peers.live===1"'
run untrack myrepo-architect
check "2d: untrack plan shows the member live" '[ "$RC" -eq 0 ] && jq_ok "o.member.live===true"'

# ---- 3: dead pid -> not live
fresh; up_row "$DEAD_PID"
run dismiss myrepo-architect --plan
check "3: a dead pid on the member's pane is not live" '[ "$RC" -eq 0 ] && jq_ok "o.live===false"'

# ---- 4: role mismatch, or a pane two team files claim -> not attributed
fresh; up_row "$LIVE_PID" reviewer
run dismiss myrepo-architect --plan
check "4: a row whose role differs from the member's is not attributed" '[ "$RC" -eq 0 ] && jq_ok "o.live===false"'
fresh; up_row "$LIVE_PID"
write_team "$HIER/teams/alpha.json" t-alpha '[{"role":"architect","name":"alpha-architect","ref":"r1","route":"peer","model":"opus","transport_id":"PANE1","checked_in":"2026-01-01T00:00:00Z"}]'
run dismiss myrepo-architect --plan
check "4b: a pane claimed by two team files is not attributed" '[ "$RC" -eq 0 ] && jq_ok "o.live===false"'

# ---- 5: pane up row + fresh briefed row -> one slot, not ambiguous, busy/task borrowed
fresh; up_row "$LIVE_PID"
seed '{"status":"briefed","name":"myrepo-architect","role":"architect","busy":true,"task":"spec-x"}'
OUT=$(HOME="$FAKEHOME" node "$H/msg.mjs" roster --plain --cwd "$PROJ" 2>&1); RC=$?
check "5: one architect entry for the member" '[ "$(echo "$OUT" | grep -c "^architect:")" -eq 1 ]'
check "5b: liveness comes from the pane row, busy/task from the briefed row" 'echo "$OUT" | grep "^architect: myrepo-architect" | grep "up-pid" | grep "busy" | grep -q "task=spec-x"'
run dismiss myrepo-architect --plan
check "5c: dismiss-by-name is not ambiguous" '[ "$RC" -eq 0 ] && ! has "ambiguous" && jq_ok "o.live===true"'

# ---- 6: pane-attributed down row + fresh briefed row -> not live; SessionEnd writes pane_id
fresh
seed "{\"status\":\"up\",\"role\":\"architect\",\"pid\":$LIVE_PID,\"pane_id\":\"PANE1\",\"session_id\":\"$SID\",\"cwd\":\"$PROJ\",\"ts\":\"2026-09-01T00:00:00.000Z\"}"
echo "{\"session_id\":\"$SID\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionEnd\"}" | env -u HERDR_PANE_ID HOME="$FAKEHOME" node "$H/sessionend-roster.mjs"
check "6: SessionEnd's down row carries the up row's pane_id" \
  'tail -1 "$PEERS_FILE" | grep -q "\"status\":\"down\"" && tail -1 "$PEERS_FILE" | grep -q "\"pane_id\":\"PANE1\""'
seed '{"status":"briefed","name":"myrepo-architect","role":"architect"}'
run dismiss myrepo-architect --plan
check "6b: a pane-attributed down row outweighs a fresh briefed row" '[ "$RC" -eq 0 ] && jq_ok "o.live===false"'

# ---- 7: the route gate names the attributed member
fresh; up_row "$LIVE_PID"
PL=$(node -e 'process.stdout.write(JSON.stringify({session_id:"orch-1",cwd:process.argv[1],tool_name:"Agent",tool_input:{subagent_type:"ah:architect",prompt:"design it"}}))' "$PROJ")
OUT=$(echo "$PL" | HOME="$FAKEHOME" node "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
check "7: Agent(ah:architect) is denied naming the attributed member" \
  'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\"" && echo "$OUT" | grep -q "SendMessage \\\\\"myrepo-architect\\\\\""'

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
