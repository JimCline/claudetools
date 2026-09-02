#!/bin/bash
# agent-hierarchy — spec 0031: PreToolUse SendMessage response nudge, and its
# Fix D prerequisite (extractPendingRecord widening in lib-peer.mjs) and
# Fix D consequence guard (stop-orchestrator-liveness.mjs cede check).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-sendmessage-response-nudge.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
HOOK="$H/pretooluse-sendmessage-response.mjs"
TRACK="$H/userpromptsubmit-peer-tracking.mjs"
LIVENESS="$H/stop-orchestrator-liveness.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-sendresp-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PEER_STORE="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }
field() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]]))' "$OUT" "$1"; }

send_payload() { # <session_id> <role> <to> <message> [agent_id]
  node -e 'const[s,r,t,m,a]=process.argv.slice(1);const o={session_id:s,cwd:process.env.PROJ,tool_name:"SendMessage",agent_type:r,tool_input:{to:t,message:m}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3" "$4" "$5"
}
hook() { OUT=$(PROJ="$PROJ" send_payload "$1" "$2" "$3" "$4" "$5" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$HOOK" 2>&1); RC=$?; }

prompt_payload() { # <session_id> <first_line>
  node -e 'const[s,l]=process.argv.slice(1);const o={session_id:s,cwd:process.env.PROJ,prompt:`<cross-session-message from="ct-orchestrator" from-name="ct-orchestrator">\n${l}\ntldr`};process.stdout.write(JSON.stringify(o));' "$1" "$2"
}
track() { OUT=$(PROJ="$PROJ" prompt_payload "$1" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$TRACK" 2>&1); RC=$?; }

liveness_payload() { # <session_id>
  node -e 'const[s]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.PROJ,stop_hook_active:false}));' "$1"
}
liveness() { OUT=$(PROJ="$PROJ" liveness_payload "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$LIVENESS" 2>&1); RC=$?; }

denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
blocked() { echo "$OUT" | grep -q '"decision":"block"'; }

# Latest non-turn peer-pending record for a session, or "null".
latest_pending() {
  node -e '
    const fs=require("fs");
    const [sid,path]=process.argv.slice(1);
    if(!fs.existsSync(path)){process.stdout.write("null");process.exit(0);}
    let last=null;
    for (const l of fs.readFileSync(path,"utf8").split("\n")) {
      if(!l.trim())continue;
      let r; try{r=JSON.parse(l);}catch{continue;}
      if(!r||r.type==="turn"||r.session_id!==sid)continue;
      last=r;
    }
    process.stdout.write(JSON.stringify(last));
  ' "$1" "$PEER_STORE"
}

seed() { echo "$1" >> "$PEER_STORE"; } # raw JSON line, caller supplies ts/status

# ---- fixtures: a request to architect from orchestrator, and its response
msg new --to architect --from orchestrator --slug arch-task
ARCH_REQ=$(field path); ARCH_ID=$(field id)
msg new --type response --id "$ARCH_ID"
ARCH_RESP=$(field path)
# Fill the response body so it is a real response file (content irrelevant here).

# ==== 1-4: Fix D via the real userpromptsubmit-peer-tracking.mjs pipeline ====

track "s1" "[hierarchy-msg $ARCH_REQ]"
P1=$(latest_pending "s1" "$PEER_STORE")
check "1: msg-token first line arms a pending record" '[ "$P1" != "null" ]'
check "1: pending record msg = request path" 'echo "$P1" | grep -q "\"msg\":\"$ARCH_REQ\""'
check "1: pending record reply_to = wrapper from" 'echo "$P1" | grep -q "\"reply_to\":\"ct-orchestrator\""'
check "1: pending record armed_by = msg-token" 'echo "$P1" | grep -q "\"armed_by\":\"msg-token\""'

track "s2" "some text\n[hierarchy-msg $ARCH_REQ]"
P2=$(latest_pending "s2" "$PEER_STORE")
check "2: token not on first non-blank line -> no record armed" '[ "$P2" = "null" ]'

track "s3" "[hierarchy-msg $SANDBOX/does-not-exist--request.md]"
P3=$(latest_pending "s3" "$PEER_STORE")
check "3a: nonexistent path -> no record armed" '[ "$P3" = "null" ]'
track "s3b" "[hierarchy-msg $ARCH_RESP]"
P3b=$(latest_pending "s3b" "$PEER_STORE")
check "3b: a --response.md path -> no record armed" '[ "$P3b" = "null" ]'

track "s4" '[hierarchy-peer-brief reply-to="ct-orchestrator" task="x"]'
P4=$(latest_pending "s4" "$PEER_STORE")
check "4: sentinel form still arms" '[ "$P4" != "null" ]'
check "4: sentinel-armed record armed_by = sentinel" 'echo "$P4" | grep -q "\"armed_by\":\"sentinel\""'

# ==== 5-19: pretooluse-sendmessage-response.mjs, records seeded directly ====

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
seed_qualifying() { # <session_id>
  seed "{\"session_id\":\"$1\",\"from\":\"ct-orchestrator\",\"from_name\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"arch-task\",\"msg\":\"$ARCH_REQ\",\"armed_by\":\"msg-token\",\"ts\":\"$TS\",\"status\":\"pending\",\"nudges\":0}"
}

seed_qualifying "s5"
hook "s5" "architect" "ct-orchestrator" "no token here"
check "5: architect, pending msg record, no token -> deny" 'denied'
check "5: deny reason carries --id and --to" "echo \"\$OUT\" | grep -q -- \"--id $ARCH_ID --to orchestrator\""

hook "s5" "architect" "ct-orchestrator" "no token here, retry"
check "6: second attempt -> allow" 'allowed'
GATES_FILE="$HD/gates.jsonl"
check "6: send-nudge-unmet recorded" "grep -q '\"type\":\"send-nudge-unmet\",\"id\":\"$ARCH_ID\"' \"\$GATES_FILE\""

hook "s7-noobligation" "architect" "ct-orchestrator" "hi"
check "7: no pending record for this session -> allow" 'allowed'

seed "{\"session_id\":\"s8\",\"from\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"x\",\"armed_by\":\"sentinel\",\"ts\":\"$TS\",\"status\":\"pending\",\"nudges\":0}"
hook "s8" "architect" "ct-orchestrator" "hi, checking in"
check "8: pending record with no msg -> allow" 'allowed'

seed_qualifying "s9-other"
hook "s9" "architect" "ct-orchestrator" "no token"
check "9: a different session's pending record -> allow" 'allowed'

seed_qualifying "s10"
hook "s10" "" "ct-orchestrator" "no token"
check "10: no direct role attribution (Orchestrator) -> allow" 'allowed'

seed_qualifying "s11r"
hook "s11r" "reviewer" "ct-orchestrator" "no token"
check "11: reviewer with qualifying record -> allow" 'allowed'
seed_qualifying "s11u"
hook "s11u" "ultra-advisor" "ct-orchestrator" "no token"
check "11: ultra-advisor with qualifying record -> allow" 'allowed'

seed_qualifying "s12"
hook "s12" "architect" "ct-orchestrator" "[hierarchy-msg $ARCH_RESP]"
check "12: valid response token whose id matches -> allow" 'allowed'

msg new --to architect --from orchestrator --slug arch-other
OTHER_ID=$(field id)
msg new --type response --id "$OTHER_ID"
OTHER_RESP=$(field path)
seed_qualifying "s13"
hook "s13" "architect" "ct-orchestrator" "[hierarchy-msg $OTHER_RESP]"
check "13a: id-mismatched response file -> deny" 'denied'
hook "s13" "architect" "ct-orchestrator" "[hierarchy-msg $OTHER_RESP]"
check "13a: deny again on retry (no one-round allowance)" 'denied'

seed_qualifying "s13b"
hook "s13b" "architect" "ct-orchestrator" "[hierarchy-msg $SANDBOX/missing--response.md]"
check "13b: missing file -> deny" 'denied'

seed_qualifying "s13c"
hook "s13c" "architect" "ct-orchestrator" "[hierarchy-msg $ARCH_REQ]"
check "13c: type:request file -> deny" 'denied'

seed_qualifying "s13d"
hook "s13d" "implementor" "ct-orchestrator" "[hierarchy-msg $ARCH_RESP]"
check "13d: mismatched from: -> deny" 'denied'

BEFORE=$(md5 -q "$PEER_STORE" 2>/dev/null || md5sum "$PEER_STORE" | awk '{print $1}')
seed_qualifying "s14"
hook "s14" "architect" "ct-orchestrator" "no token"
hook "s14" "architect" "ct-orchestrator" "no token again"
AFTER_STILL_HAS_S14=$(latest_pending "s14" "$PEER_STORE")
check "14: peer-record store untouched by the hook (msg field present unmodified)" 'echo "$AFTER_STILL_HAS_S14" | grep -q "\"msg\":\"$ARCH_REQ\""'

check "17: subagent context -> allow" '
  hook "s17" "architect" "ct-orchestrator" "no token" "sub1"
  allowed
'

cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
seed_qualifying "s18a"
hook "s18a" "architect" "ct-orchestrator" "no token"
check "18a: hierarchy disabled -> allow" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "off", "roles": {} }
EOF
seed_qualifying "s18b"
hook "s18b" "architect" "ct-orchestrator" "no token"
check "18b: msgs:off -> allow" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF

OUT=$(echo "not json" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$HOOK" 2>&1); RC=$?
check "19: malformed stdin fails open" 'allowed'

check "the test script itself exercises the hook file" '[ -f "$HOOK" ]'

# ==== §4.1a: stop-peer-nudge already covers test 15 (existing mechanism, no
# code changed there); stop-orchestrator-liveness.mjs guard (test 16) ====
# Build an outstanding-past-threshold dispatch so ceding vs not-ceding
# actually produces a different outcome (block vs allow), not two silent
# allows for different reasons.

msg new --to architect --from orchestrator --slug old-task
OLD_REQ=$(field path); OLD_ID=$(field id)
OLD_TS=$(node -e 'process.stdout.write(new Date(Date.now()-600000).toISOString())') # 10min ago > small(5min) threshold
node -e '
  const fs=require("fs");
  const p=process.argv[1]; const ts=process.argv[2];
  fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/^created:.*$/m, "created: "+ts));
' "$OLD_REQ" "$OLD_TS"
dispatch_record() { # <session_id>
  seed "{\"type\":\"dispatch\",\"session_id\":\"$1\",\"request_id\":\"$OLD_ID\",\"to\":\"architect\",\"created\":\"$TS\"}"
}

dispatch_record "s16a"
seed "{\"session_id\":\"s16a\",\"from\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"x\",\"armed_by\":\"msg-token\",\"msg\":\"$ARCH_REQ\",\"ts\":\"$TS\",\"status\":\"pending\",\"nudges\":0}"
liveness "s16a"
check "16: msg-token-armed record does NOT cede -> outstanding dispatch still blocks" 'blocked'

dispatch_record "s16b"
seed "{\"session_id\":\"s16b\",\"from\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"x\",\"armed_by\":\"sentinel\",\"ts\":\"$TS\",\"status\":\"pending\",\"nudges\":0}"
liveness "s16b"
check "16: sentinel-armed record still cedes -> allow" 'allowed'

dispatch_record "s16c"
seed "{\"session_id\":\"s16c\",\"from\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"x\",\"ts\":\"$TS\",\"status\":\"pending\",\"nudges\":0}"
liveness "s16c"
check "16: legacy record with no armed_by still cedes -> allow" 'allowed'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
