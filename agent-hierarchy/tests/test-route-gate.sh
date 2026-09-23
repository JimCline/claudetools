#!/bin/bash
# agent-hierarchy — PreToolUse route gate: session routing preference (the
# peers wall; subagents/prefer-peers opt-ins) and tier deny
# (dispatching an advisor role at or below the session's own tier without a
# reason). HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-route-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-routegate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
PEERS="$HD/peers.jsonl"
GATES="$HD/gates.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] },
  "architect": { "model": "opus", "dispatch": "model" },
  "ultra-advisor": { "model": "fable", "dispatch": "model" } } }
EOF

payload() { # <session> <tool> <subagent_type> <prompt> [model-field] [agent_id]
  node -e 'const[s,t,st,p,m,a]=process.argv.slice(1);const o={session_id:s,cwd:process.env.PROJ,tool_name:t,tool_input:{subagent_type:st,prompt:p}};if(m)o.model=m;if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3" "$4" "$5" "$6"; }
send_payload() { node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "$1" "$2" "$3"; }
gate() { # <payload> [env kv...]
  local pl=$1; shift
  OUT=$(echo "$pl" | PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" env "$@" node "$GATE" 2>&1); RC=$?
}
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
# F1: an informational note must not auto-approve the tool call — no permissionDecision key at all.
allowed_with_note() { [ $RC -eq 0 ] && echo "$OUT" | grep -q '"systemMessage"' && ! echo "$OUT" | grep -q '"permissionDecision"'; }

seed_live() { # <name> <role> — fresh `seen` record, so the instance is live
  node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
seed_busy() { # <name> <role> — fresh `seen` record, busy:true
  node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,busy:true,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
set_route() { # <session> <value>
  HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route "$2" --session "$1" --cwd "$PROJ" >/dev/null; }

# ---- 1: route unset, no roster, none live -> the wall: spawn-ad-hoc every time, never a route-ask
gate "$(PROJ="$PROJ" payload s1 Agent ah:reviewer 'review it')"
check "route unset: reviewer spawn denied with the spawn-ad-hoc command" 'denied && echo "$OUT" | grep -q "spawn-ad-hoc reviewer --cwd"'
check "no route question" '! echo "$OUT" | grep -q "dispatch route" && ! grep -q "\"type\":\"route-ask\"" "$GATES" 2>/dev/null'
gate "$(PROJ="$PROJ" payload s1 Agent ah:reviewer 'review it')"
check "identical re-issue denied again" 'denied'
gate "$(PROJ="$PROJ" payload s1 Agent ah:architect 'design it')"
check "architect with a user-written dispatch:model is an opt-in: passes" 'allowed'
gate "$(PROJ="$PROJ" payload s8 Agent task-gopher:task-gopher 'run tests')"
check "task-gopher dispatch: not a roster dispatch, never gated" 'allowed'

# ---- 2: msg.mjs route CLI
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route --session s2 --cwd "$PROJ" --plain 2>&1); RC=$?
check "route --session, no value: prints the default (peers, source default)" 'echo "$OUT" | grep -q "^peers" && echo "$OUT" | grep -q "default"'
set_route s2 peers
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route --session s2 --cwd "$PROJ" --plain 2>&1); RC=$?
check "route --session, no value after recording: prints recorded value + session source" 'echo "$OUT" | grep -q "^peers" && echo "$OUT" | grep -q "session"'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route bogus --session s2 --cwd "$PROJ" 2>&1); RC=$?
check "route with an invalid value: rejected, non-zero exit" '[ $RC -ne 0 ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route peers --cwd "$PROJ" 2>&1); RC=$?
check "route with a value but no --session: rejected, non-zero exit" '[ $RC -ne 0 ]'

# ---- 3: precedence — session > config > default
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "route": "subagents", "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] },
  "architect": { "model": "opus", "dispatch": "model" },
  "ultra-advisor": { "model": "fable", "dispatch": "model" } } }
EOF
gate "$(PROJ="$PROJ" payload s3 Agent ah:reviewer 'review it')"
check "config route=subagents, no session answer: never asks, Agent spawn allowed (subagents route doesn't gate spawns)" 'allowed'
gate "$(PROJ="$PROJ" send_payload s3 rev-a "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "config route=subagents: peer brief denied (SendMessage under subagents)" 'denied'
set_route s3 peers
gate "$(PROJ="$PROJ" send_payload s3 rev-a "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "session route overrides config: peers now allows the peer brief" 'allowed'

# reset to no-config-route for the remaining per-value cases
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] },
  "architect": { "model": "opus", "dispatch": "model" },
  "ultra-advisor": { "model": "fable", "dispatch": "model" } } }
EOF

# ---- 4: subagents route — denies peer brief, allows spawns
seed_live rev-a reviewer
seed_live rev-b reviewer
set_route s4 subagents
gate "$(PROJ="$PROJ" send_payload s4 rev-a "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "subagents: SendMessage peer brief denied" 'denied'
check "one-shot: route-deny recorded for role reviewer" 'grep -q "\"type\":\"route-deny\"" "$GATES" && grep -q "\"session_id\":\"s4\"" "$GATES" && grep -q "\"role\":\"reviewer\"" "$GATES"'
gate "$(PROJ="$PROJ" send_payload s4 rev-a "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "subagents: identical re-issue passes (one-shot spent)" 'allowed'
gate "$(PROJ="$PROJ" payload s4 Agent ah:reviewer 'review it')"
check "subagents: Agent spawn always allowed, even with a live peer" 'allowed'

# ---- 5: peers route — a wall: denies spawn while live, and when none is live, every time
set_route s5 peers
gate "$(PROJ="$PROJ" payload s5 Agent ah:reviewer 'review it')"
check "peers, live instances exist: spawn denied, names candidates" 'denied && echo "$OUT" | grep -q "rev-a" && echo "$OUT" | grep -q "rev-b"'
gate "$(PROJ="$PROJ" payload s5 Agent ah:reviewer 'review it')"
check "peers: identical re-issue denied again" 'denied && echo "$OUT" | grep -q "rev-a"'
set_route s5b peers
gate "$(PROJ="$PROJ" payload s5b Agent ah:implementor 'implement it')"
check "peers, no live instance for the role: denied with the spawn command" \
  'denied && echo "$OUT" | grep -q "spawn-ad-hoc implementor --cwd"'
gate "$(PROJ="$PROJ" payload s5b Agent ah:implementor 'implement it')"
check "peers, no live instance: re-issue denied again" 'denied && ! grep -q "\"type\":\"peer-fallback-ask\"" "$GATES"'

# ---- 6: prefer-peers route — denies only while a live instance is free
set_route s6 prefer-peers
gate "$(PROJ="$PROJ" payload s6 Agent ah:reviewer 'review it')"
check "prefer-peers, a live free instance exists: spawn denied" 'denied'
gate "$(PROJ="$PROJ" payload s6 Agent ah:reviewer 'review it')"
check "prefer-peers: identical re-issue passes (one-shot spent)" 'allowed'
# mark both reviewer instances busy
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:"rev-a",role:"reviewer",busy:true,ts:new Date().toISOString()})+"\n");
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:"rev-b",role:"reviewer",busy:true,ts:new Date().toISOString()})+"\n");' "$PEERS"
set_route s6b prefer-peers
gate "$(PROJ="$PROJ" payload s6b Agent ah:reviewer 'review it')"
check "prefer-peers, all live instances busy: spawn allowed" 'allowed'

# ---- F2: with two roles live at once, the deny names the dispatched role's live peer
seed_live impl-f2 implementor
gate "$(PROJ="$PROJ" payload sf2 Agent ah:implementor 'implement it')"
check "F2: the deny names the live implementor, not the reviewers" \
  'denied && echo "$OUT" | grep -q "impl-f2" && ! echo "$OUT" | grep -q "rev-a"'

# ---- F3: an unconfigured but roster-known peer still resolves a role and gates
seed_live impl-f3 implementor
set_route sf3 subagents
gate "$(PROJ="$PROJ" send_payload sf3 impl-f3 "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "F3: subagents route denies a brief to a roster-known, config-unlisted peer" 'denied'
gate "$(PROJ="$PROJ" send_payload sf3 ghost-nobody "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "F3: brief to a name with no roster record at all still passes through" 'allowed'

# ---- F4: the one-shot key includes the route value — a mid-session route
# change re-arms the deny instead of silently reusing the old route's gate
set_route sf4 prefer-peers
gate "$(PROJ="$PROJ" payload sf4 Agent ah:implementor 'implement it')"
check "F4: prefer-peers, free live implementor: denied" 'denied'
gate "$(PROJ="$PROJ" payload sf4 Agent ah:implementor 'implement it')"
check "F4: identical re-issue under the same route passes (one-shot spent)" 'allowed'
set_route sf4 peers
gate "$(PROJ="$PROJ" payload sf4 Agent ah:implementor 'implement it')"
check "F4: same session+role, route changed to peers: denied again under the new route" 'denied'
set_route sf4b prefer-peers
seed_live arch-f4 architect
gate "$(PROJ="$PROJ" payload sf4b Agent ah:architect 'design it')"
check "F4b: a user-written dispatch:model opts in even under prefer-peers with a free peer" 'allowed'

# ---- 7: tier gate — advisor dispatch at/below the session's own tier
mk_req() { # <role> [reason] -> REQ path
  local args=(new --cwd "$PROJ" --to "$1" --from orchestrator --slug tg-case)
  [ -n "$2" ] && args+=(--reason "$2")
  local o; o=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" "${args[@]}")
  node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$o"
}
REQ_NOREASON=$(mk_req architect)
REQ_REASON=$(mk_req architect second-opinion)
set_route t0 prefer-peers   # an opt-in with no free architect, so these isolate the tier gate

gate "$(PROJ="$PROJ" payload t0 Agent ah:architect "[hierarchy-msg $REQ_NOREASON]")"
check "model unknown: architect dispatch passes (tier gate inert)" 'allowed'
set_route t2 prefer-peers
gate "$(PROJ="$PROJ" payload t2 Agent ah:architect "[hierarchy-msg $REQ_NOREASON]")" CLAUDE_MODEL=claude-opus-4-1
check "session opus >= architect opus, reason null: denied" 'denied'
check "tier deny reason: names both tiers and the reason escape" 'echo "$OUT" | grep -qi "tier rule" && echo "$OUT" | grep -q "reason:"'
check "one-shot: tier-deny recorded" 'grep -q "\"type\":\"tier-deny\"" "$GATES"'
gate "$(PROJ="$PROJ" payload t2 Agent ah:architect "[hierarchy-msg $REQ_NOREASON]")" CLAUDE_MODEL=claude-opus-4-1
check "tier deny is one-shot per session+role" 'allowed'
set_route t3 prefer-peers
gate "$(PROJ="$PROJ" payload t3 Agent ah:architect "[hierarchy-msg $REQ_REASON]")" CLAUDE_MODEL=claude-opus-4-1
check "request file carries reason: passes" 'allowed'
set_route t4 prefer-peers
gate "$(PROJ="$PROJ" payload t4 Agent ah:architect "[hierarchy-msg $REQ_NOREASON]")" CLAUDE_MODEL=claude-sonnet-4-5
check "session sonnet < architect opus: passes" 'allowed'
set_route t5 prefer-peers
gate "$(PROJ="$PROJ" payload t5 Agent ah:ultra-advisor "[hierarchy-msg $(mk_req ultra-advisor)]")" CLAUDE_MODEL=claude-fable-5
check "fable session dispatching ultra-advisor (fable), no reason: denied" 'denied'
set_route t6 prefer-peers
gate "$(PROJ="$PROJ" payload t6 Agent ah:ultra-advisor "[hierarchy-msg $(mk_req ultra-advisor)]")" CLAUDE_MODEL=claude-opus-4-1
check "opus session dispatching ultra-advisor (fable): passes" 'allowed'
set_route t7 prefer-peers
gate "$(PROJ="$PROJ" payload t7 Agent ah:reviewer 'plain')" CLAUDE_MODEL=claude-fable-5
check "reviewer is not a tier-gated role" 'allowed'
set_route t8 prefer-peers
gate "$(PROJ="$PROJ" payload t8 Agent ah:architect 'no token at all')" CLAUDE_MODEL=claude-opus-4-1
check "no request file: treated as reason-absent -> denied once" 'denied'

# ---- 8: msgs:"off" — tier denial text drops the reason: instruction
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "off", "roles": {
  "architect": { "model": "opus", "dispatch": "model" } } }
EOF
set_route toff prefer-peers
gate "$(PROJ="$PROJ" payload toff Agent ah:architect 'no request file, msgs off')" CLAUDE_MODEL=claude-opus-4-1
check "msgs:off, tier deny fires" 'denied'
check "msgs:off: denial text drops the reason: instruction" '! echo "$OUT" | grep -q "reason:"'
check "msgs:off: denial text tells the caller to just re-issue" 'echo "$OUT" | grep -q "re-issue this exact dispatch to proceed"'

# ---- 9: model from payload beats env; cached model from gates.jsonl
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] },
  "architect": { "model": "opus", "dispatch": "model" },
  "ultra-advisor": { "model": "fable", "dispatch": "model" } } }
EOF
REQ2=$(mk_req architect)
set_route t9 prefer-peers
gate "$(PROJ="$PROJ" payload t9 Agent ah:architect "[hierarchy-msg $REQ2]" claude-sonnet-4-5)" CLAUDE_MODEL=claude-opus-4-1
check "payload model wins over env: sonnet session passes" 'allowed'
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"model",session_id:"t10",model:"claude-opus-4-1",ts:new Date().toISOString()})+"\n");' "$GATES"
set_route t10 prefer-peers
gate "$(PROJ="$PROJ" payload t10 Agent ah:architect "[hierarchy-msg $REQ2]")"
check "cached model record used when payload+env silent: denied" 'denied'

# ---- 10: SendMessage path — sentinel briefs to a tier-gated peer
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "architect": { "model": "opus", "dispatch": "peer", "peer": "arch-peer" } } }
EOF
REQ3_NOREASON=$(mk_req architect)
REQ3_REASON=$(mk_req architect second-opinion)
BRIEF_NOREASON="[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
[hierarchy-msg $REQ3_NOREASON]"
set_route u1 prefer-peers
gate "$(PROJ="$PROJ" send_payload u1 arch-peer "$BRIEF_NOREASON")" CLAUDE_MODEL=claude-opus-4-1
check "SendMessage brief to architect peer, no reason: tier-denied" 'denied'
set_route u2 prefer-peers
gate "$(PROJ="$PROJ" send_payload u2 arch-peer "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
[hierarchy-msg $REQ3_REASON]")" CLAUDE_MODEL=claude-opus-4-1
check "SendMessage brief with reason: passes" 'allowed'
set_route u3 prefer-peers
gate "$(PROJ="$PROJ" send_payload u3 arch-peer 'no sentinel here')" CLAUDE_MODEL=claude-opus-4-1
check "SendMessage without sentinel: not gated" 'allowed'
# A peer brief under the default route asks no route question: only the tier rule applies.
gate "$(PROJ="$PROJ" send_payload u4 arch-peer "$BRIEF_NOREASON")" CLAUDE_MODEL=claude-opus-4-1
check "peer brief with no route recorded: tier-denied, no route question" \
  'denied && echo "$OUT" | grep -q "tier rule" && ! echo "$OUT" | grep -q "dispatch route"'
# The request names its team file, so the teammate's role resolves even when the hierarchy dir
# resolves somewhere else.
cat > "$HD/team.json" <<EOF
{ "team_id": "t1", "roster_level": null, "members": [ { "role": "architect", "name": "arch-peer" } ] }
EOF
REQ_DRIFT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" new --cwd "$PROJ" --to architect --from orchestrator --slug drift --reason second-opinion --to-name arch-peer | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).path)')
gate "$(PROJ="$PROJ" send_payload u5 arch-peer "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
[hierarchy-msg $REQ_DRIFT]")" CLAUDE_MODEL=claude-opus-4-1 AGENT_HIERARCHY_DIR="$SANDBOX/elsewhere"
check "teammate found through the request's team_file when the hierarchy dir resolves elsewhere: passes" 'allowed'
gate "$(PROJ="$PROJ" send_payload u6 arch-peer "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
[hierarchy-msg $REQ3_REASON]")" CLAUDE_MODEL=claude-opus-4-1 AGENT_HIERARCHY_DIR="$SANDBOX/elsewhere"
check "same send with a request naming no team file: no ask either" 'allowed'
rm -f "$HD/team.json"

# ---- 11: disabled / malformed / other tools fail open
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
gate "$(PROJ="$PROJ" payload z1 Agent ah:reviewer 'x')" CLAUDE_MODEL=claude-fable-5
check "enabled:false -> passes" 'allowed'
OUT=$(echo "not json" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "malformed stdin fails open" 'allowed'
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "other tools pass" 'allowed'
check "pretooluse-route-gate.mjs writes to stdout exactly once" '[ "$(grep -c "process.stdout.write" "$GATE")" -eq 1 ]'

# ---- 12: every hook file parses — a syntax error in this working tree breaks
# every live Claude session's hooks immediately (they load from this checkout,
# not an installed copy), so the suite must catch it, not the user.
SYNTAX_BAD=$(cd "$H" && for f in *.mjs; do node --check "$f" >/dev/null 2>&1 || echo "$f"; done)
check "every hooks/*.mjs passes node --check" '[ -z "$SYNTAX_BAD" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
