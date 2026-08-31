#!/bin/bash
# agent-hierarchy — response gate: SubagentStop nudge for a role subagent that
# was briefed by message file, and the peer-side resolver/nudge when the
# obligation carries `msg`. Payload shape from tests/fixtures/subagentstop-payload.json
# (a real v2.1.233 SubagentStop, which carries `last_assistant_message`).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-msg-response.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
NUDGE="$H/subagentstop-msg-nudge.mjs"
MSG="$H/msg.mjs"
UPS="$H/userpromptsubmit-peer-tracking.mjs"
PTU="$H/posttooluse-peer-resolve.mjs"
STOP="$H/stop-peer-nudge.mjs"
FIXTURE="$PLUGIN/tests/fixtures/subagentstop-payload.json"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-msgresp-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/proj"
PROJDIR="$SANDBOX/projects/-proj"
STATE_FILE="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$PROJDIR"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

echo '{ "version": 1, "enabled": true, "roles": {} }' > "$PROJ/.claude/agent-hierarchy.json"

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }

# Fixture-shaped SubagentStop payload with overrides: <agent_id> <agent_type> <last_assistant_message|-> <agent_transcript_path>
stop_payload() {
  node -e '
    const fs=require("fs");
    const [fixture,agentId,agentType,last,tp,cwd,sid]=process.argv.slice(1);
    const o=JSON.parse(fs.readFileSync(fixture,"utf8"));
    o.agent_id=agentId; o.agent_type=agentType; o.cwd=cwd; o.session_id=sid;
    o.transcript_path=tp.replace(/\/[^/]+\/subagents\/.*$/,"")+"/"+sid+".jsonl";
    o.agent_transcript_path=tp;
    if (last==="-") delete o.last_assistant_message; else o.last_assistant_message=last;
    process.stdout.write(JSON.stringify(o));
  ' "$FIXTURE" "$1" "$2" "$3" "$4" "$PROJ" "sess1"
}
nudge() { OUT=$(stop_payload "$1" "$2" "$3" "$4" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$NUDGE" 2>&1); RC=$?; }

# Subagent transcript: first user turn carries the brief text; last assistant turn carries the final text.
write_transcript() { # <path> <first user text> <last assistant text>
  mkdir -p "$(dirname "$1")"
  node -e '
    const [p,u,a]=process.argv.slice(1);
    const lines=[
      JSON.stringify({type:"user",message:{role:"user",content:u}}),
      JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"text",text:"working..."}]}}),
      JSON.stringify({type:"user",message:{role:"user",content:[{type:"tool_result",content:"ok"}]}}),
      JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"text",text:a}]}}),
    ];
    require("fs").writeFileSync(p,lines.join("\n")+"\n");
  ' "$1" "$2" "$3"
}

blocked() { echo "$OUT" | grep -q '"decision":"block"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }

check "fixture: real SubagentStop payload committed" '[ -f "$FIXTURE" ]'
check "fixture: carries last_assistant_message" 'grep -q "\"last_assistant_message\"" "$FIXTURE"'
check "fixture: carries agent_transcript_path" 'grep -q "\"agent_transcript_path\"" "$FIXTURE"'

# ---- 1: role subagent briefed by file, no pointer in last message -> block once, then allow
msg new --to implementor --from orchestrator --slug impl-x
REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
ID=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$OUT")
T1="$PROJDIR/sess1/subagents/agent-a1.jsonl"
write_transcript "$T1" "[hierarchy-msg $REQ]
- implement impl-x" "Done, I changed three files."
nudge a1 ah:implementor "Done, I changed three files." "$T1"
check "no pointer -> block" 'blocked'
check "block reason: names msg.mjs new --type response --id <id>" 'echo "$OUT" | grep -q "msg.mjs.* new --type response --id $ID"'
check "block reason: says --to orchestrator --from implementor" 'echo "$OUT" | grep -q -- "--to orchestrator --from implementor"'
check "block reason: return exactly [hierarchy-msg <response path>] + status" 'echo "$OUT" | grep -q "\[hierarchy-msg <response path>\]"'
check "nudge recorded in gates.jsonl" 'grep -q "\"type\":\"nudge\".*\"agent_id\":\"a1\"" "$HD/gates.jsonl"'
nudge a1 ah:implementor "Done, I changed three files." "$T1"
check "second stop of the same agent_id -> allow" 'allowed'

# ---- 2: pointer to an existing response file -> allow silently
msg new --to reviewer --from orchestrator --slug rev-y
REQ2=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
ID2=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$OUT")
msg new --type response --id "$ID2"
RESP2=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
# r4's hasResponseToken requires the file itself to carry authored content,
# not just an existing skeleton pointed to by the pointer text — write some.
printf '\n- done: PASS\n' >> "$RESP2"
T2="$PROJDIR/sess1/subagents/agent-a2.jsonl"
write_transcript "$T2" "[hierarchy-msg $REQ2]" "[hierarchy-msg $RESP2]
- done: PASS"
nudge a2 ah:reviewer "[hierarchy-msg $RESP2]
- done: PASS" "$T2"
check "pointer to existing response -> allow" 'allowed'
nudge a2b ah:reviewer "[hierarchy-msg $HD/msgs/${ID2}--orchestrator--rev-y--response.md.missing]" "$T2"
check "pointer to a non-existent response -> block" 'blocked'
msg new --to reviewer --from orchestrator --slug rev-z
REQ3=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
T3="$PROJDIR/sess1/subagents/agent-a3.jsonl"
write_transcript "$T3" "[hierarchy-msg $REQ3]" "[hierarchy-msg $RESP2]"
nudge a3 ah:reviewer "[hierarchy-msg $RESP2]" "$T3"
check "pointer to a response for a DIFFERENT id -> block" 'blocked'

# ---- 3: last_assistant_message absent -> read the transcript's last assistant line
nudge a4 ah:reviewer - "$T2"
check "no last_assistant_message: transcript last assistant line has pointer -> allow" 'allowed'
T5="$PROJDIR/sess1/subagents/agent-a5.jsonl"
write_transcript "$T5" "[hierarchy-msg $REQ3]" "all done, no pointer"
nudge a5 ah:reviewer - "$T5"
check "no last_assistant_message: transcript lacks pointer -> block" 'blocked'

# ---- 4: no request token in the brief (inline brief / gate off) -> allow silently
T6="$PROJDIR/sess1/subagents/agent-a6.jsonl"
write_transcript "$T6" "Please review /tmp/spec.md" "done"
nudge a6 ah:reviewer "done" "$T6"
check "no request token in first user turn -> allow" 'allowed'
nudge a7 ah:reviewer "done" "$PROJDIR/sess1/subagents/agent-missing.jsonl"
check "missing transcript -> allow (fail open)" 'allowed'

# ---- 5: non-role subagents and msgs:off
nudge a8 task-gopher:task-gopher "done" "$T1"
check "task-gopher -> allow" 'allowed'
nudge a9 general-purpose "done" "$T1"
check "foreign agent type -> allow" 'allowed'
echo '{ "version": 1, "enabled": true, "msgs": "off", "roles": {} }' > "$PROJ/.claude/agent-hierarchy.json"
nudge a10 ah:implementor "no pointer" "$T1"
check "msgs:off -> allow" 'allowed'
echo '{ "version": 1, "enabled": true, "roles": {} }' > "$PROJ/.claude/agent-hierarchy.json"
OUT=$(echo "garbage" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$NUDGE" 2>&1); RC=$?
check "malformed stdin -> allow" 'allowed'
check "subagentstop-msg-nudge.mjs writes to stdout exactly once" '[ "$(grep -c "process.stdout.write" "$NUDGE")" -eq 1 ]'

# ---- 6: peer side — obligation with msg resolves only against a response pointer
rm -f "$STATE_FILE"
ups_payload() { node -e 'const[s,p]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,prompt:p,hook_event_name:"UserPromptSubmit"}));' "$1" "$2"; }
ptu_payload() { node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "$1" "$2" "$3"; }
stopp_payload() { node -e 'const[s]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,stop_hook_active:false}));' "$1"; }
ups()  { OUT=$(ups_payload "$1" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$UPS" 2>&1); RC=$?; }
ptu()  { OUT=$(ptu_payload "$1" "$2" "$3" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$PTU" 2>&1); RC=$?; }
pstop() { OUT=$(stopp_payload "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$STOP" 2>&1); RC=$?; }
last_status() { node -e '
  const fs=require("fs");const [f,sid]=process.argv.slice(1);
  const recs=fs.readFileSync(f,"utf8").trim().split("\n").map(l=>JSON.parse(l)).filter(r=>r.type!=="turn"&&r.session_id===sid);
  process.stdout.write(recs.length?recs[recs.length-1].status:"none");' "$STATE_FILE" "$1"; }

BRIEF="<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"orch\" from-mode=\"prompting\">
[hierarchy-peer-brief reply-to=\"sender\" task=\"impl-x\"]
[hierarchy-msg $REQ]
- implement impl-x
</cross-session-message>"
ups peer1 "$BRIEF"
check "peer tracking: obligation records msg path" 'grep -q "\"msg\":\"$REQ\"" "$STATE_FILE"'
ptu peer1 "uds:/tmp/cc-socks/1.sock" "done, all good"
check "peer resolve: reply to the right address WITHOUT pointer stays pending" '[ "$(last_status peer1)" = pending ]'
ptu peer1 "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $RESP2]
- done"
check "peer resolve: pointer for a DIFFERENT id stays pending" '[ "$(last_status peer1)" = pending ]'
pstop peer1
check "peer stop nudge: names msg.mjs new --type response --id <id>" 'echo "$OUT" | grep -q "\"decision\":\"block\"" && echo "$OUT" | grep -q "msg.mjs.* new --type response --id $ID"'
check "peer stop nudge: says reply must carry [hierarchy-msg <response path>]" 'echo "$OUT" | grep -q "must carry \[hierarchy-msg <response path>\]"'
msg new --type response --id "$ID"
RESP=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
# Same as RESP2 above — the file itself must carry authored content under r4.
printf '\n- done: 3 files\n' >> "$RESP"
ptu peer1 "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $RESP]
- done: 3 files"
check "peer resolve: matching response pointer + file present -> resolved" '[ "$(last_status peer1)" = resolved ]'

# An obligation without msg (inline brief) resolves as before, no pointer needed.
INLINE="<cross-session-message from=\"uds:/tmp/cc-socks/2.sock\" from-name=\"orch\" from-mode=\"prompting\">
[hierarchy-peer-brief reply-to=\"sender\" task=\"inline-task\"]
please do the thing
</cross-session-message>"
ups peer2 "$INLINE"
check "peer tracking: inline brief records no msg" '! grep -q "\"session_id\":\"peer2\".*\"msg\"" "$STATE_FILE"'
ptu peer2 "uds:/tmp/cc-socks/2.sock" "done"
check "peer resolve: obligation without msg resolves on address alone" '[ "$(last_status peer2)" = resolved ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
