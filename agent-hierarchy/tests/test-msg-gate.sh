#!/bin/bash
# agent-hierarchy — PreToolUse msg gate: role dispatches must carry a
# `[hierarchy-msg <request path>]` pointer to a valid request file.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-msg-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-msg-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-msggate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# A configured project so the hierarchy is enabled and reviewer has an explicit peer name.
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": "rev-peer" }, "architect": { "model": "opus", "dispatch": "model" } } }
EOF

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }

agent_payload() { # <subagent_type> <prompt> [agent_id]
  node -e 'const[t,p,a]=process.argv.slice(1);const o={session_id:"s1",cwd:process.env.PROJ,tool_name:"Agent",tool_input:{subagent_type:t,prompt:p}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3"; }
send_payload() { # <to> <message>
  node -e 'const[t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "$1" "$2"; }

gate() { OUT=$(PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
agent() { OUT=$(PROJ="$PROJ" agent_payload "$1" "$2" "$3" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
send()  { OUT=$(PROJ="$PROJ" send_payload "$1" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }

denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }

# ---- fixtures: one implementor request, one closed exchange for reviewer
msg new --to implementor --from orchestrator --slug impl-task
IMPL_REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
msg new --to reviewer --from orchestrator --slug rev-task
REV_REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
REV_ID=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$OUT")
msg new --type response --id "$REV_ID"
REV_RESP=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")

# ---- 1: Agent dispatches
agent ah:implementor "Please implement the thing at /tmp/spec.md"
check "Agent implementor, no token -> deny" 'denied'
check "deny reason: names msg.mjs new --to implementor" 'echo "$OUT" | grep -q "msg.mjs.* new --to implementor --from orchestrator"'
check "deny reason: says missing token" 'echo "$OUT" | grep -q "missing token"'
check "deny reason: 3 numbered steps" 'echo "$OUT" | grep -q "3\. Re-issue this exact dispatch"'
agent ah:implementor "[hierarchy-msg $HD/msgs/20990101-000000-zzzz--implementor--nope--request.md]
tldr"
check "Agent: token to a missing file -> deny (path not found)" 'denied && echo "$OUT" | grep -q "path not found"'
agent ah:implementor "[hierarchy-msg $REV_REQ]
tldr"
check "Agent implementor with reviewer's request -> deny wrong to:" 'denied && echo "$OUT" | grep -q "wrong to: (file says reviewer, dispatch is implementor)"'
agent ah:reviewer "[hierarchy-msg $REV_RESP]
tldr"
check "Agent: response file used as request -> deny (not a request file)" 'denied && echo "$OUT" | grep -q "not a request file"'
cp "$IMPL_REQ" "$SANDBOX/outside--request.md"
agent ah:implementor "[hierarchy-msg $SANDBOX/outside--request.md]"
check "Agent: request file outside <dir>/msgs -> deny" 'denied'
agent ah:implementor "[hierarchy-msg $IMPL_REQ]
- implement impl-task; see file"
check "Agent implementor with valid file -> allow (silent)" 'allowed'
agent implementor "[hierarchy-msg $IMPL_REQ]"
check "bare subagent_type also checked and passes with valid file" 'allowed'
agent implementor "no token here"
check "bare subagent_type without token -> deny" 'denied'
agent task-gopher:task-gopher "run the tests and report"
check "task-gopher exempt" 'allowed'
agent ah:task-runner "run the tests"
check "task-runner exempt" 'allowed'
agent general-purpose "anything"
check "foreign subagent type passes" 'allowed'
agent ah:implementor "no token" "sub1"
check "subagent context (agent_id set) passes" 'allowed'

# ---- 2: SendMessage
send rev-peer "hello, are you there?"
check "SendMessage without sentinel passes" 'allowed'
send rev-peer '[hierarchy-peer-brief reply-to="sender" task="rev-task"]
please review /tmp/spec.md and report back'
check "SendMessage with sentinel + no token -> deny" 'denied && echo "$OUT" | grep -q "missing token"'
check "deny reason: names the resolved role for that peer" 'echo "$OUT" | grep -q "new --to reviewer"'
send "rev-peer [ab12]" "[hierarchy-peer-brief reply-to=\"sender\" task=\"rev-task\"]
[hierarchy-msg $REV_REQ]
- review it"
check "SendMessage brief with valid file (to has [ref]) -> allow" 'allowed'
send "rev-peer" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]
[hierarchy-msg $IMPL_REQ]"
check "SendMessage brief to reviewer peer with implementor's file -> deny wrong to:" 'denied && echo "$OUT" | grep -q "wrong to:"'
send "some-unrelated-session" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]
[hierarchy-msg $IMPL_REQ]"
check "SendMessage brief to a non-configured peer: role check skipped, file valid -> allow" 'allowed'
send "some-unrelated-session" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"] no file"
check "SendMessage brief to a non-configured peer without token -> still denied" 'denied'

# ---- 3: msgs:"off" disables; malformed input fails open; disabled hierarchy passes
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "off", "roles": {} }
EOF
agent ah:implementor "no token"
check "msgs:off -> gate disabled" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "sometimes", "roles": {} }
EOF
agent ah:implementor "no token"
check "msgs invalid value -> falls back to required (denies)" 'denied'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
agent ah:implementor "no token"
check "enabled:false -> passes" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF
OUT=$(echo "not json" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "malformed stdin fails open" 'allowed'
OUT=$(echo '{"tool_name":"Agent","tool_input":"nope"}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "non-object tool_input fails open" 'allowed'
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "other tools pass" 'allowed'

# ---- 4: exactly one stdout write site
check "pretooluse-msg-gate.mjs writes to stdout exactly once" '[ "$(grep -c "process.stdout.write" "$GATE")" -eq 1 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
