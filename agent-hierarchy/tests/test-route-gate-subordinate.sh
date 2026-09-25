#!/bin/bash
# agent-hierarchy — role sessions and subagents never dispatch ah roles; they route the need back.
# A session whose own peers.jsonl "up" record carries a role other than orchestrator, and any
# subagent (hook input with agent_id), is denied EVERY Agent/Task spawn of a peer-eligible role
# and every sentinel peer brief to one — whatever the route — with route-back text
# (NEEDS-<ROLE>). Legwork and replies pass. A session with no resolvable identity is the
# Orchestrator. The role contracts say the same thing. HOME- and AGENT_HIERARCHY_DIR-redirected.
# Usage: bash tests/test-route-gate-subordinate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-routegate-sub-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
PEERS="$HD/peers.jsonl"
GATES="$HD/gates.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
(cd "$PROJ" && git init -q)
export PROJ
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

payload() { # <session> <subagent_type> [agent_id] [agent_type]
  node -e 'const[s,st,a,at]=process.argv.slice(1);const o={session_id:s,cwd:process.env.PROJ,tool_name:"Agent",tool_input:{subagent_type:st,prompt:"do it"}};if(a){o.agent_id=a;o.agent_type=at;}process.stdout.write(JSON.stringify(o));' "$1" "$2" "${3:-}" "${4:-}"; }
send_payload() { # <session> <to> <message> [agent_id]
  node -e 'const[s,t,m,a]=process.argv.slice(1);const o={session_id:s,cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3" "${4:-}"; }
gate() { OUT=$(echo "$1" | PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
seed_up() { # <session> <role> — an "up" peers.jsonl record, what sessionstart.mjs writes
  node -e 'const fs=require("fs");const[f,s,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:s,role:r,pid:999999,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
spawn_cmd() { echo "$OUT" | grep -q "spawn-ad-hoc $1 --cwd"; }
BRIEF='[hierarchy-peer-brief reply-to="sender" task="x"]
[hierarchy-msg /tmp/req.md]'

echo '{ "version": 1, "enabled": true }' > "$PROJ/.claude/agent-hierarchy.json"

# ---- control: an explicit orchestrator up-record gets the Orchestrator wall, not route-back
seed_up so1 orchestrator
gate "$(payload so1 ah:reviewer)"
check "1: orchestrator session: the wall carries the spawn command" 'denied && spawn_cmd reviewer && ! echo "$OUT" | grep -q "NEEDS-"'

# ---- 18: a role session (own up row: architect) is denied, every time, and routes back
seed_up so18 architect
gate "$(payload so18 ah:implementor)"
check "18: Agent(ah:implementor) denied with NEEDS-IMPLEMENTOR route-back" \
  'denied && echo "$OUT" | grep -q "NEEDS-IMPLEMENTOR" && echo "$OUT" | grep -q "NEEDS-EVIDENCE" && echo "$OUT" | grep -q "response file" && ! spawn_cmd implementor'
check "18b: route-back text keeps legwork available" 'echo "$OUT" | grep -q "task-gopher:\*" && echo "$OUT" | grep -q "ah:task-runner"'
gate "$(payload so18 ah:implementor)"
check "18c: the identical re-issue is denied again" 'denied && echo "$OUT" | grep -q "NEEDS-IMPLEMENTOR"'
HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route subagents --session so18 --cwd "$PROJ" >/dev/null
gate "$(payload so18 ah:implementor)"
check "18d: still denied with route subagents recorded for the session" 'denied && echo "$OUT" | grep -q "NEEDS-IMPLEMENTOR"'
gate "$(payload so18 ah:ultra-advisor)"
check "18e: the label is uppercased and hyphenated" 'denied && echo "$OUT" | grep -q "NEEDS-ULTRA-ADVISOR"'
for t in ah:task-runner task-gopher:task-gopher task-gopher:smart-gopher general-purpose; do
  gate "$(payload so18 "$t")"
  check "18f: legwork/non-ah $t allowed" 'allowed'
done
gate "$(send_payload so18 myrepo-reviewer "$BRIEF")"
check "18g: a sentinel brief to a reviewer peer is denied with route-back" 'denied && echo "$OUT" | grep -q "NEEDS-REVIEWER"'
gate "$(send_payload so18 ct-orchestrator '[hierarchy-msg /tmp/resp.md]
- status: done')"
check "18h: a [hierarchy-msg <response>] reply to the Orchestrator is allowed" 'allowed'

# ---- 18i: no session_id -> treated as the Orchestrator -> the wall with a spawn command
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' "$PEERS"
NOSESSION_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.env.PROJ,tool_name:"Agent",tool_input:{subagent_type:"ah:reviewer",prompt:"review it"}}));')
gate "$NOSESSION_PAYLOAD"
check "18i: no session_id in hook input: Orchestrator wall with a spawn command" 'denied && spawn_cmd reviewer && ! echo "$OUT" | grep -q "NEEDS-"'

# ---- 18j: latestRoster drops a record with no name and session_id: null (unit, lib-hier.mjs)
LATEST_ROSTER_DIR="$SANDBOX/hier8b"
mkdir -p "$LATEST_ROSTER_DIR"
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' \
  "$LATEST_ROSTER_DIR/peers.jsonl"
LATEST_ROSTER_OUT=$(AGENT_HIERARCHY_DIR="$LATEST_ROSTER_DIR" node -e '
  import("'"$H"'/lib-hier.mjs").then((L) => {
    process.stdout.write(JSON.stringify(L.latestRoster(process.env.AGENT_HIERARCHY_DIR)));
  });')
check "18j: latestRoster drops the nameless, session_id:null record" '[ "$LATEST_ROSTER_OUT" = "[]" ]'

# ---- 18k: upRecordFor(dir, "__nosession__") never matches a session_id:null record
SENTINEL_DIR="$SANDBOX/hier8c"
mkdir -p "$SENTINEL_DIR"
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",name:"anything",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' \
  "$SENTINEL_DIR/peers.jsonl"
SENTINEL_OUT=$(AGENT_HIERARCHY_DIR="$SENTINEL_DIR" node -e '
  import("'"$H"'/lib-hier.mjs").then((L) => {
    process.stdout.write(JSON.stringify(L.upRecordFor(process.env.AGENT_HIERARCHY_DIR, "__nosession__")));
  });')
check "18k: upRecordFor(dir, \"__nosession__\") is null for a named, session_id:null record" '[ "$SENTINEL_OUT" = "null" ]'

# ---- 19: a subagent (agent_id set) of any type is denied and routes back to its parent
for at in ah:architect general-purpose; do
  gate "$(payload s19 ah:reviewer agent-19 "$at")"
  check "19 ($at): Agent(ah:reviewer) denied, NEEDS-REVIEWER, into the final report to the parent" \
    'denied && echo "$OUT" | grep -q "NEEDS-REVIEWER" && echo "$OUT" | grep -q "final report to the session that spawned you"'
  gate "$(payload s19 ah:task-runner agent-19 "$at")"
  check "19b ($at): Agent(ah:task-runner) allowed" 'allowed'
  gate "$(payload s19 task-gopher:smart-gopher agent-19 "$at")"
  check "19c ($at): Agent(task-gopher:smart-gopher) allowed" 'allowed'
done
gate "$(send_payload s19 myrepo-architect "$BRIEF" agent-19)"
check "19d: a subagent's sentinel brief to an architect peer is denied" 'denied && echo "$OUT" | grep -q "NEEDS-ARCHITECT"'
OUT=$(echo '{"session_id":"s19","agent_id":"agent-19","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"ls"}}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "19e: a subagent's non-dispatch tool call passes" 'allowed'

# ---- 20: the role contracts agree with the deny text
check "20: architect.md and ultra-advisor.md never tell the role to dispatch ah:implementor" \
  '! grep -q "ah:implementor" "$PLUGIN/agents/architect.md" "$PLUGIN/agents/ultra-advisor.md"'
for r in architect implementor reviewer ultra-advisor; do
  check "20b: agents/$r.md carries the NEEDS-<ROLE> route-back rule" 'grep -q "NEEDS-<ROLE>" "$PLUGIN/agents/$r.md"'
done
NOTICE=$(node --input-type=module -e 'const c = await import(process.argv[1] + "/lib-config.mjs"); process.stdout.write(c.buildRoleSessionNotice("architect", "ah:architect"));' "$H")
check "20c: buildRoleSessionNotice carries the route-back and legwork sentence" \
  'echo "$NOTICE" | grep -q "NEEDS-<ROLE>" && echo "$NOTICE" | grep -q "NEEDS-EVIDENCE" && echo "$NOTICE" | grep -q "task-gopher:\*" && echo "$NOTICE" | grep -q "ah:task-runner"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
