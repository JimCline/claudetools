#!/bin/bash
# agent-hierarchy — peer roster: writers (peer SessionStart/SessionEnd,
# orchestrator PostToolUse on ListAgents/SendMessage), roster() liveness and
# per-instance openBriefs, array `peer` config, msg.mjs roster.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-roster.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
PEERS="$HD/peers.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

unset AGENT_HIERARCHY_PANE_DIR AGENT_HIERARCHY_PANE_ROLE AGENT_HIERARCHY_PANE_KEY

# reviewer has TWO configured peers; implementor uses the <repo>-implementor convention; architect is subagent-only.
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] },
  "architect": { "model": "opus", "dispatch": "model" } } }
EOF

run() { # <hook file> <payload json>
  OUT=$(echo "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/$1" 2>&1); RC=$?
}
eval_hier() { # <js over lib-hier as L, lib-config as C>
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
    const L = await import('$H/lib-hier.mjs'); const C = await import('$H/lib-config.mjs');
    const resolved = C.resolveConfig('$PROJ');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}
last_for() { # <jq-ish: name-or-session key> -> last record json
  node -e '
    const fs=require("fs");const [f,key]=process.argv.slice(1);
    const recs=fs.readFileSync(f,"utf8").trim().split("\n").map(l=>JSON.parse(l)).filter(r=>(r.name||r.session_id)===key);
    process.stdout.write(recs.length?JSON.stringify(recs[recs.length-1]):"none");' "$PEERS" "$1"; }

# ---- 1: peer session SessionStart -> up (pid = hook's ppid); SessionEnd -> down
run sessionstart.mjs "{\"session_id\":\"peer-s1\",\"cwd\":\"$PROJ\",\"agent_type\":\"agent-hierarchy:implementor\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}"
check "peer SessionStart: still emits the role notice" 'echo "$OUT" | grep -q "MAIN session"'
check "peer SessionStart: notice says You are a peer Implementor + msg protocol" 'echo "$OUT" | grep -q "You are a peer Implementor" && echo "$OUT" | grep -q "hierarchy-msg"'
check "peer SessionStart: up record written" '[ "$(last_for peer-s1 | node -e "process.stdin.on(\"data\",d=>process.stdout.write(JSON.parse(d).status))")" = up ]'
check "peer SessionStart: role + pid recorded" 'last_for peer-s1 | grep -q "\"role\":\"implementor\"" && last_for peer-s1 | grep -q "\"pid\":[0-9]"'
run sessionstart.mjs "{\"session_id\":\"sub-s\",\"cwd\":\"$PROJ\",\"agent_id\":\"a1\",\"agent_type\":\"agent-hierarchy:implementor\",\"hook_event_name\":\"SessionStart\"}"
check "subagent SessionStart: no roster record" '[ "$(last_for sub-s)" = none ] && [ -z "$OUT" ]'
run sessionend-roster.mjs "{\"session_id\":\"peer-s1\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}"
check "SessionEnd (no agent_type in payload): matched by session_id -> down" '[ "$(last_for peer-s1 | grep -c "\"status\":\"down\"")" = 1 ]'
run sessionend-roster.mjs "{\"session_id\":\"plain-s\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}"
check "SessionEnd for an ordinary session: nothing written" '[ "$(last_for plain-s)" = none ]'
run sessionend-roster.mjs "{\"session_id\":\"peer-s2\",\"cwd\":\"$PROJ\",\"agent_type\":\"agent-hierarchy:reviewer\",\"hook_event_name\":\"SessionEnd\"}"
check "SessionEnd with agent_type role: down written even without a prior up" 'last_for peer-s2 | grep -q "\"status\":\"down\""'

# ---- 2: ListAgents PostToolUse parses the listing; role-matching names only
LISTING='Peer sessions (SendMessage to reach them):
  rev-a [a1b2c3] · opus · idle · cwd /x
  rev-b [d4e5f6] · opus · busy · cwd /x
  myrepo-implementor [0a0b0c] · sonnet · idle · cwd /x
  someone-architect [ffffff] · opus · idle · cwd /y
  random-notes [123abc] · haiku · idle · cwd /z
Background subagents:
  gopher-x [999999] · haiku · busy · running'
PAYLOAD=$(node -e 'const [cwd,l]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"orch",cwd,tool_name:"ListAgents",tool_input:{},tool_response:l}));' "$PROJ" "$LISTING")
run posttooluse-roster.mjs "$PAYLOAD"
check "ListAgents: rev-a seen (configured array peer)" 'last_for rev-a | grep -q "\"status\":\"seen\"" && last_for rev-a | grep -q "\"role\":\"reviewer\""'
check "ListAgents: rev-b seen + busy:true + ref" 'last_for rev-b | grep -q "\"busy\":true" && last_for rev-b | grep -q "\"ref\":\"d4e5f6\""'
check "ListAgents: convention name myrepo-implementor seen as implementor" 'last_for myrepo-implementor | grep -q "\"role\":\"implementor\""'
check "ListAgents: role-token-only name (someone-architect) recorded as architect candidate" 'last_for someone-architect | grep -q "\"role\":\"architect\""'
check "ListAgents: non-matching name ignored" '[ "$(last_for random-notes)" = none ]'
check "ListAgents: subagent lines below Peer sessions with no role token ignored" '[ "$(last_for gopher-x)" = none ]'
PAYLOAD=$(node -e 'const [cwd,l]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"orch",cwd,agent_id:"sub1",tool_name:"ListAgents",tool_input:{},tool_response:l}));' "$PROJ" "  new-reviewer [111111] · opus · idle · cwd /q")
run posttooluse-roster.mjs "$PAYLOAD"
check "ListAgents in a subagent context: nothing written" '[ "$(last_for new-reviewer)" = none ]'

# ---- 3: SendMessage brief -> briefed (with task); plain SendMessage -> nothing
PAYLOAD=$(node -e 'const [cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"orch",cwd,tool_name:"SendMessage",tool_input:{to:"rev-a [a1b2c3]",message:"[hierarchy-peer-brief reply-to=\"sender\" task=\"spec-x\"]\n[hierarchy-msg /nowhere]\n- review"}}));' "$PROJ")
run posttooluse-roster.mjs "$PAYLOAD"
check "SendMessage brief: briefed, name stripped of [ref], task recorded" 'last_for rev-a | grep -q "\"status\":\"briefed\"" && last_for rev-a | grep -q "\"task\":\"spec-x\""'
PAYLOAD=$(node -e 'const [cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"orch",cwd,tool_name:"SendMessage",tool_input:{to:"rev-b",message:"just checking in"}}));' "$PROJ")
run posttooluse-roster.mjs "$PAYLOAD"
check "SendMessage without sentinel: rev-b unchanged (still seen)" 'last_for rev-b | grep -q "\"status\":\"seen\""'

# ---- 4: roster(): two reviewer instances, live by freshness, openBriefs split by to_name
HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --cwd "$PROJ" --to reviewer --from orchestrator --slug for-a --to-name rev-a >/dev/null
HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --cwd "$PROJ" --to reviewer --from orchestrator --slug for-any >/dev/null
HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --cwd "$PROJ" --to implementor --from orchestrator --slug for-impl >/dev/null
eval_hier "JSON.stringify(L.roster('$HD', resolved, 'myrepo').reviewer.map(i => [i.name, i.live, i.how, i.busy, i.openBriefs, i.unassigned]))"
check "roster: two reviewer instances, both live (fresh), rev-a briefed / rev-b seen+busy" \
  'echo "$OUT" | grep -q "\[\"rev-a\",true,\"briefed\",false,2,1\]" && echo "$OUT" | grep -q "\[\"rev-b\",true,\"seen\",true,1,1\]"'
eval_hier "L.roster('$HD', resolved, 'myrepo').implementor.map(i => i.name+':'+i.live+':'+i.openBriefs).join(',')"
check "roster: implementor convention peer live, 1 open (unassigned)" '[ "$OUT" = "myrepo-implementor:true:1" ]'
eval_hier "L.roster('$HD', resolved, 'myrepo').architect.map(i => i.name+':'+i.live).join(',')"
check "roster: role-token-only architect candidate listed" '[ "$OUT" = "someone-architect:true" ]'
# age past ROSTER_FRESH_SEC -> stale
eval_hier "L.roster('$HD', resolved, 'myrepo', Date.now() + (L.ROSTER_FRESH_SEC + 5) * 1000).reviewer.map(i => i.live).join(',')"
check "roster: seen/briefed older than ROSTER_FRESH_SEC -> stale" '[ "$OUT" = "false,false" ]'
# up + pid: alive pid (this shell) vs dead pid
node -e 'const fs=require("fs");const [f,pid]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:"implementor",session_id:"live-s",pid:Number(pid),ts:new Date(Date.now()-86400000).toISOString()})+"\n");
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:"implementor",session_id:"dead-s",pid:2147483000,ts:new Date().toISOString()})+"\n");' "$PEERS" "$$"
eval_hier "JSON.stringify(L.roster('$HD', resolved, 'myrepo').implementor.map(i => [i.name, i.live, i.how]))"
check "roster: up with alive pid -> live (age ignored); up with dead pid -> stale; unnamed shows role@session" \
  'echo "$OUT" | grep -q "\[\"implementor@live-s\",true,\"up-pid\"\]" && echo "$OUT" | grep -q "\[\"implementor@dead-s\",false,\"up-pid\"\]"'
check "roster: live-first ordering" 'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const a=JSON.parse(s);process.exit(a[0][1]===true&&a[a.length-1][1]===false?0:1)})"'
# down supersedes up
node -e 'const fs=require("fs");const [f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"down",role:"implementor",session_id:"live-s",ts:new Date().toISOString()})+"\n");' "$PEERS"
eval_hier "L.roster('$HD', resolved, 'myrepo').implementor.some(i => i.name === 'implementor@live-s')"
check "roster: down supersedes up (instance dropped)" '[ "$OUT" = false ]'

# ---- 5: array peer config resolves all; single string still one; ultra gate matches any
eval_hier "C.resolvedPeerTargets('reviewer', resolved.roles.reviewer, 'myrepo').join(',')+'|'+C.resolvedPeerTarget('reviewer', resolved.roles.reviewer, 'myrepo')+'|'+C.resolvedPeerTargets('implementor', resolved.roles.implementor, 'myrepo').join(',')+'|'+C.resolvedPeerTargets('architect', resolved.roles.architect, 'myrepo').length"
check "resolvedPeerTargets: array -> all; wrapper -> first; auto -> convention; model -> none" '[ "$OUT" = "rev-a,rev-b|rev-a|myrepo-implementor|0" ]'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": [] } } }
EOF
eval_hier "C.resolvedPeerTargets('reviewer', resolved.roles.reviewer, 'myrepo').join(',')+'|'+resolved.warnings.length"
check "resolvedPeerTargets: empty array invalid -> auto + warning" '[ "$OUT" = "myrepo-reviewer|1" ]'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "ultra-advisor": { "model": "fable", "dispatch": "peer", "peer": ["ua-one", "ua-two"] } } }
EOF
OUT=$(echo "{\"session_id\":\"ug\",\"cwd\":\"$PROJ\",\"tool_name\":\"SendMessage\",\"tool_input\":{\"to\":\"ua-two\",\"message\":\"q\"}}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "ultra gate: SendMessage to the SECOND array peer is gated" 'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\""'
OUT=$(echo "{\"session_id\":\"ug\",\"cwd\":\"$PROJ\",\"tool_name\":\"SendMessage\",\"tool_input\":{\"to\":\"ua-three\",\"message\":\"q\"}}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "ultra gate: SendMessage to a non-listed name passes" '[ -z "$OUT" ]'
# directive lists both names
eval_hier "C.buildDirective(resolved, 's').includes('peer \"ua-one\" / \"ua-two\" via SendMessage')"
check "directive role line lists every array peer" '[ "$OUT" = true ]'

# ---- 6: msg.mjs roster output
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a", "rev-b"] } } }
EOF
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" roster --cwd "$PROJ" --plain 2>&1); RC=$?
check "msg.mjs roster --plain: lists rev-a and rev-b under reviewer with open counts" 'echo "$OUT" | grep -q "^reviewer: rev-a .*open=2 (unassigned 1)" && echo "$OUT" | grep -q "^reviewer: rev-b .*busy.*open=1"'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" roster --cwd "$PROJ" 2>&1); RC=$?
check "msg.mjs roster (json): roles.reviewer has 2 instances" 'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).roles.reviewer.length===2?0:1))"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
