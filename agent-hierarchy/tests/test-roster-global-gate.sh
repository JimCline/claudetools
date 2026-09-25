#!/bin/bash
# agent-hierarchy — PreToolUse route gate: a global-level roster and user-scope role config
# confirm nothing. Neither asks, denies, or records anything on their account; the route gate
# answers exactly as it would for a repo roster. HOME- and AGENT_HIERARCHY_DIR-redirected; real
# state untouched.
# Usage: bash tests/test-roster-global-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-globalgate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
GATES="$HD/gates.jsonl"
PEERS="$HD/peers.jsonl"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"
REPO_CFG="$PROJ/.claude/agent-hierarchy.json"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

payload() { # <session> <tool> <subagent_type> <prompt>
  node -e 'const[s,t,st,p]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.PROJ,tool_name:t,tool_input:{subagent_type:st,prompt:p}}));' "$1" "$2" "$3" "$4"; }
payload_cwd() { # <cwd> <session> <tool> <subagent_type> <prompt>
  node -e 'const[c,s,t,st,p]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:c,tool_name:t,tool_input:{subagent_type:st,prompt:p}}));' "$1" "$2" "$3" "$4" "$5"; }
send_payload() { node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "$1" "$2" "$3"; }
gate() { # <payload> [env kv...]
  local pl=$1; shift
  OUT=$(echo "$pl" | PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" env "$@" node "$GATE" 2>&1); RC=$?
}
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }

seed_live() { # <name> <role>
  node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
set_route() { # <session> <value>
  HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route "$2" --session "$1" --cwd "$PROJ" >/dev/null; }
gates_for() { grep "\"session_id\":\"$1\"" "$GATES" 2>/dev/null; } # <session>

seed_live "g-impl-live" "implementor"
no_global_records() { ! grep -qE "\"type\":\"global-scope(-ask)?\"" "$GATES" 2>/dev/null; }
no_confirm_text() { ! echo "$OUT" | grep -qE "GLOBAL|USER-scope|global-scope"; }

# ================= A global roster =================
cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [
  {"role": "implementor", "name": "g-implementor", "model": "opus"}
] } }
EOF
echo '{ "version": 1, "enabled": true }' > "$REPO_CFG"

gate "$(PROJ="$PROJ" payload sA1 Agent ah:implementor 'implement it')"
check "A1: global roster, live implementor: denied naming it, no confirm" \
  'denied && echo "$OUT" | grep -q "g-impl-live" && no_confirm_text'
: > "$PEERS"
gate "$(PROJ="$PROJ" payload sA2 Agent ah:implementor 'implement it')"
check "A2: global roster, none live: the spawn-one wall, no confirm" 'denied && echo "$OUT" | grep -q "spawn-one implementor" && no_confirm_text'
echo '{"type":"route","session_id":"sA3","value":"subagents"}' >> "$GATES"   # written before only "peers" existed
gate "$(PROJ="$PROJ" payload sA3 Agent ah:implementor 'implement it')"
check "A3: a stale route subagents record: the Agent dispatch gets the spawn-one wall, no confirm" 'denied && echo "$OUT" | grep -q "spawn-one implementor" && no_confirm_text'
gate "$(PROJ="$PROJ" send_payload sA3 g-implementor "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
do it")"
check "A4: a stale route subagents record: a SendMessage brief passes — no route deny, no confirm" 'allowed'
gate "$(PROJ="$PROJ" send_payload sA5 g-implementor "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
do it")"
check "A5: default route: a SendMessage brief to a global-roster member passes" 'allowed'

# ================= User-scope role configuration =================
cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "effort": "high" } } }
EOF
gate "$(PROJ="$PROJ" payload sB1 Agent ah:reviewer 'review it')"
check "B1: role defined only in user-scope config: the wall, no USER-scope ask" 'denied && echo "$OUT" | grep -q "spawn-ad-hoc reviewer" && no_confirm_text'
gate "$(PROJ="$PROJ" payload sB2 Agent ah:task-runner 'run it')"
check "B2: a non-peer-eligible role with user-scope config passes" 'allowed'
gate "$(payload_cwd "$FAKEHOME" sB3 Agent ah:reviewer 'review it')"
check "B3: cwd is the home dir (user scope is the only layer): no USER-scope ask" '! echo "$OUT" | grep -q "USER-scope"'

# ================= A brief to a member of a global-level team =================
mkdir -p "$HD/teams"
cat > "$HD/teams/myrepo.json" <<EOF
{"version":1,"team_id":"t-member-send","created":"2020-01-01T00:00:00+00:00","roster_level":"global","transport":"herdr","orchestrator":{"session_id":null,"pid":$$},"members":[{"role":"reviewer","name":"myrepo-reviewer","route":"peer","transport_id":"p1"}],"partial":true}
EOF
gate "$(PROJ="$PROJ" send_payload sT1 myrepo-reviewer "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
do it")"
check "T1: a brief to a member of a roster_level global team passes" 'allowed'

check "no global-scope or global-scope-ask record was ever written" 'no_global_records'

# ---- malformed gates.jsonl -> never crashes the hook. Last: corrupts $GATES for the rest of the run.
printf 'not valid json\n' > "$GATES"
gate "$(PROJ="$PROJ" payload sZ Agent ah:reviewer 'review it')"
check "malformed gates.jsonl: never crashes -- exit 0, no stack trace, well-formed output or none" \
  '[ $RC -eq 0 ] && { [ -z "$OUT" ] || echo "$OUT" | grep -q "hookSpecificOutput"; }'

SYNTAX_BAD=$(cd "$H" && for f in *.mjs; do node --check "$f" >/dev/null 2>&1 || echo "$f"; done)
check "every hooks/*.mjs passes node --check" '[ -z "$SYNTAX_BAD" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
