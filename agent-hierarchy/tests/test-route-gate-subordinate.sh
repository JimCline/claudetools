#!/bin/bash
# agent-hierarchy — spec 0026 §3: the route gate becomes orchestrator-only.
# A session whose peers.jsonl "up" record resolves to a subordinate role
# (non-null, not "orchestrator") must never trip the interactive route-ask,
# peer-fallback-ask, or on-missing-auto gates — it resolves silently to
# config route > prefer-peers. The global-scope confirm gate (spec 0009 §4)
# is untouched and must still fire for a subordinate. HOME- and
# AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-route-gate-subordinate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
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

payload() { # <session> <tool> <subagent_type> <prompt>
  node -e 'const[s,t,st,p]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.PROJ,tool_name:t,tool_input:{subagent_type:st,prompt:p}}));' "$1" "$2" "$3" "$4"; }
gate() { # <payload>
  local pl=$1
  OUT=$(echo "$pl" | PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
}
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
allowed_with_note() { [ $RC -eq 0 ] && echo "$OUT" | grep -q '"systemMessage"' && ! echo "$OUT" | grep -q '"permissionDecision"'; }

seed_up() { # <session> <role> — an "up" peers.jsonl record, what sessionstart.mjs writes
  node -e 'const fs=require("fs");const[f,s,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:s,role:r,pid:999999,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
seed_live() { # <name> <role>
  node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
seed_busy() { # <name> <role>
  node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,busy:true,ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2"; }
write_repo_config() { # <json roles block>
  cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": $1 }
EOF
}
write_repo_config_route_peers() { # <members-json-array> — config route:"peers" + roster (onMissing tests)
  cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "route": "peers", "roster": { "route": "peer", "members": $1 } }
EOF
}
write_global_roster() { # <members-json-array> — rosterLevel: global (§3.5/item 8)
  rm -f "$PROJ/.claude/agent-hierarchy.json"
  cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": $1 } }
EOF
}

write_repo_config '{}'

# ---- item 2: up record role "orchestrator" -> route-ask fires exactly as an ordinary session
seed_up so2 orchestrator
gate "$(payload so2 Agent ah:reviewer 'review it')"
check "2: explicit orchestrator up-record: route-ask fires" 'denied'
check "2: ask prompt is the three-option route question" \
  'echo "$OUT" | grep -q "Peer agents only (Recommended)" && echo "$OUT" | grep -q "Subagents only"'
check "2: route-ask gate recorded" 'grep -qE "\"type\":\"route-ask\",\"session_id\":\"so2\"" "$GATES"'

# ---- item 3: up record role "ultra-advisor" (subordinate), no live peer for the target role ->
# route-ask does NOT fire, no route-ask gate, effective route is prefer-peers (allows silently)
seed_up so3 ultra-advisor
gate "$(payload so3 Agent ah:reviewer 'review it')"
check "3: subordinate session: route-ask suppressed, no live peer, allows silently (prefer-peers default)" 'allowed'
check "3: no route-ask gate recorded for this session" '! grep "\"session_id\":\"so3\"" "$GATES" | grep -q "\"type\":\"route-ask\""'

# ---- item 4: subordinate, same conditions, a FREE live peer exists -> deny with
# preferPeersDenyReason (prefer-peers enforcement), never an AskUserQuestion
seed_up so4 ultra-advisor
seed_live rev-pp reviewer
gate "$(payload so4 Agent ah:reviewer 'review it')"
check "4: subordinate, free live peer: denied (prefer-peers redirect)" 'denied'
check "4: denial names the live peer, not the route-ask" 'echo "$OUT" | grep -q "prefer-peers" && echo "$OUT" | grep -q "rev-pp" && ! echo "$OUT" | grep -q "AskUserQuestion"'
check "4: no route-ask gate recorded for this session" '! grep "\"session_id\":\"so4\"" "$GATES" | grep -q "\"type\":\"route-ask\""'

# ---- item 5: subordinate, same role but the only live instance is busy -> allow (spawn), no
# peer-fallback-ask or on-missing-auto record (prefer-peers never touches those)
seed_up so5 ultra-advisor
seed_busy rev-pp reviewer
gate "$(payload so5 Agent ah:reviewer 'review it')"
check "5: subordinate, only live instance busy: allows silently" 'allowed'
check "5: no peer-fallback-ask or on-missing-auto gate recorded for this session" \
  '! grep "\"session_id\":\"so5\"" "$GATES" | grep -qE "\"type\":\"(peer-fallback-ask|on-missing-auto)\""'

# ---- item 6: subordinate, config route:"peers" explicitly, no live peer, onMissing default
# (prompt) -> allow silently, no peer-fallback-ask record (§3.4)
write_repo_config_route_peers '[{"role":"implementor","model":"sonnet"}]'
seed_up so6 architect
gate "$(payload so6 Agent ah:implementor 'implement it')"
check "6: subordinate, config route=peers, no live peer, onMissing default: allows (systemMessage explains why, no deny)" 'allowed_with_note'
check "6: no peer-fallback-ask gate recorded for this session" '! grep "\"session_id\":\"so6\"" "$GATES" | grep -q "\"type\":\"peer-fallback-ask\""'

# ---- item 7: same, onMissing:"auto" -> allow silently, no on-missing-auto record (§3.4)
write_repo_config_route_peers '[{"role":"implementor","model":"sonnet","onMissing":"auto"}]'
seed_up so7 architect
gate "$(payload so7 Agent ah:implementor 'implement it')"
check "7: subordinate, config route=peers, no live peer, onMissing auto: allows (systemMessage explains why, no deny)" 'allowed_with_note'
check "7: no on-missing-auto gate recorded for this session" '! grep "\"session_id\":\"so7\"" "$GATES" | grep -q "\"type\":\"on-missing-auto\""'

# ---- item 8: subordinate, rosterLevel global -> the global-scope confirm gate (spec 0009 §4)
# still fires. This is the assertion that stops a future "simplification" from widening the
# route-only suppression into a permission bypass (§3.5).
write_global_roster '[{"role":"architect","model":"opus"}]'
seed_up so8 implementor
gate "$(payload so8 Agent ah:architect 'design it')"
check "8: subordinate session, global roster: global-scope confirm gate still fires" \
  'denied && echo "$OUT" | grep -qi "global" && echo "$OUT" | grep -q "global-scope roster"'
check "8: NOT allowed to slip through as a route-gate suppression" '! allowed'

# ---- item 8a (§3.1.2/§6): hook input with NO session id at all -> gate holds the "__nosession__"
# sentinel; a peers.jsonl "up" record with session_id: null and no name (subordinate role, the
# exact shape sessionstart.mjs writes for a no-session-id role session) -> selfRole stays null ->
# treated as Orchestrator -> route-ask FIRES.
# This is an OUTCOME assertion. §3.1.2 documents that selfRole is unresolvable here via TWO
# independent mechanisms (the sentinel/null mismatch AND latestRoster's key-truthiness drop) that
# mask each other, so this test cannot isolate either one — that's item 8b's job. Do not try to
# make this fail by breaking a single mechanism; it won't, and that's not a defect in this test.
# Item 8 left a global roster in place (rosterLevel: global), which would make the deny come
# from the global-scope gate instead of the route-ask, never reaching the routing block at all —
# clear the global config item 8's write_global_roster wrote (a repo config alone doesn't shadow
# it: with no "roster" key of its own, resolution still falls through to the global one) and
# restore a plain repo config so this actually exercises the routing path.
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"
write_repo_config '{}'
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' "$PEERS"
NOSESSION_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.env.PROJ,tool_name:"Agent",tool_input:{subagent_type:"ah:reviewer",prompt:"review it"}}));')
gate "$NOSESSION_PAYLOAD"
check "8a: no session_id in hook input, null-keyed subordinate record present: route-ask still fires" 'denied'
# One assertion against a single JSON line (appendGate serialises {...rec, ts}), not two
# independent greps that could each match a different, unrelated record in the shared file.
check "8a: route-ask gate recorded keyed on the __nosession__ sentinel" \
  'grep -qE "\"type\":\"route-ask\",\"session_id\":\"__nosession__\"" "$GATES"'

# ---- item 8b (§3.1.2): latestRoster drops a record with no name and session_id: null. Falsifiable
# unit test on lib-hier.mjs directly, independent of the route gate — pins the mechanism 8a cannot.
LATEST_ROSTER_DIR="$SANDBOX/hier8b"
mkdir -p "$LATEST_ROSTER_DIR"
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' \
  "$LATEST_ROSTER_DIR/peers.jsonl"
LATEST_ROSTER_OUT=$(AGENT_HIERARCHY_DIR="$LATEST_ROSTER_DIR" node -e '
  import("'"$H"'/lib-hier.mjs").then((L) => {
    process.stdout.write(JSON.stringify(L.latestRoster(process.env.AGENT_HIERARCHY_DIR)));
  });')
check "8b: latestRoster drops the nameless, session_id:null record" '[ "$LATEST_ROSTER_OUT" = "[]" ]'

# ---- item 8c (§3.1.1): the sentinel/null mismatch, isolated (unit-level, falsifiable). The record
# is NAMED, so §3.1.2's key-truthiness drop is out of the picture — only the "__nosession__" vs
# null mismatch can prevent a match. Pins §3.1.1 directly; 8b pins §3.1.2 directly; 8a is the
# combined outcome that survives either one being changed.
SENTINEL_DIR="$SANDBOX/hier8c"
mkdir -p "$SENTINEL_DIR"
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",name:"anything",session_id:null,role:"implementor",pid:999999,ts:new Date().toISOString()})+"\n");' \
  "$SENTINEL_DIR/peers.jsonl"
SENTINEL_OUT=$(AGENT_HIERARCHY_DIR="$SENTINEL_DIR" node -e '
  import("'"$H"'/lib-hier.mjs").then((L) => {
    process.stdout.write(JSON.stringify(L.upRecordFor(process.env.AGENT_HIERARCHY_DIR, "__nosession__")));
  });')
check "8c: upRecordFor(dir, \"__nosession__\") is null for a named, session_id:null record" '[ "$SENTINEL_OUT" = "null" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
