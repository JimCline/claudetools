#!/bin/bash
# agent-hierarchy — spec 0021: per-roster-member `onMissing` policy (auto|prompt|never),
# read by pretooluse-route-gate.mjs's peer-fallback branch (route=peers, no live instance).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-on-missing.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-on-missing-test.XXXXXX")"
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
set_route() { HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" route "$2" --session "$1" --cwd "$PROJ" >/dev/null; }

# repo-level roster config (route=peers is a session concept, unrelated to roster.route=peer here)
write_repo_roster() { # <members-json-array>
  cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": $1 } }
EOF
}
write_global_roster() { # <members-json-array>
  rm -f "$PROJ/.claude/agent-hierarchy.json"
  cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": $1 } }
EOF
}

# ---- 1: back-compat — no member carries onMissing: byte-identical to today's 3-option ask
write_repo_roster '[{"role":"implementor","model":"sonnet"}]'
set_route om1 peers
gate "$(payload om1 Agent ah:implementor 'implement it')"
check "1: no onMissing set: denied with the roster-aware 3-option ask (Stand up the real .../Spawn a one-off .../Neither)" \
  'denied && echo "$OUT" | grep -q "Stand up the real Implementor peer" && echo "$OUT" | grep -q "Spawn a one-off subagent instead"'
check "1: one-shot peer-fallback-ask recorded" 'grep -q "\"type\":\"peer-fallback-ask\"" "$GATES" && grep -q "\"session_id\":\"om1\"" "$GATES"'
gate "$(payload om1 Agent ah:implementor 'implement it')"
check "1: re-issue passes (one-shot spent)" 'allowed_with_note'

# ---- 2: onMissing:"prompt" explicit — identical to case 1
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"prompt"}]'
set_route om2 peers
gate "$(payload om2 Agent ah:implementor 'implement it')"
check "2: onMissing prompt: same 3-option ask as the default" \
  'denied && echo "$OUT" | grep -q "Stand up the real Implementor peer"'
gate "$(payload om2 Agent ah:implementor 'implement it')"
check "2: re-issue passes" 'allowed_with_note'

# ---- 3: onMissing:"never" — no deny, ever; systemMessage names the policy; no gate record
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"}]'
set_route om3 peers
gate "$(payload om3 Agent ah:implementor 'implement it')"
check "3: onMissing never: passes immediately with a systemMessage naming the policy" \
  'allowed_with_note && echo "$OUT" | grep -q "on-missing policy is" && echo "$OUT" | grep -q "never"'
check "3: no on-missing-auto or peer-fallback-ask gate recorded for this session (never is not one-shot)" \
  '! grep "\"session_id\":\"om3\"" "$GATES" | grep -qE "on-missing-auto|peer-fallback-ask"'
gate "$(payload om3 Agent ah:implementor 'implement it')"
check "3: still passes on a second dispatch (the policy is the answer every time, not one-shot)" 'allowed_with_note'

# ---- 4: onMissing:"auto" — deny once with the spawn-one instruction, no AskUserQuestion, then pass
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"auto"}]'
set_route om4 peers
gate "$(payload om4 Agent ah:implementor 'implement it')"
check "4: onMissing auto: denied naming the spawn-one command with --cwd" \
  'denied && echo "$OUT" | grep -q "spawn-one implementor" && echo "$OUT" | grep -q -- "--cwd"'
check "4: reason contains no AskUserQuestion instruction" '! echo "$OUT" | grep -q "AskUserQuestion"'
check "4: on-missing-auto recorded" 'grep -q "\"type\":\"on-missing-auto\"" "$GATES" && grep -q "\"session_id\":\"om4\"" "$GATES"'
gate "$(payload om4 Agent ah:implementor 'implement it')"
check "4: re-issue passes" 'allowed_with_note'

# ---- 5: onMissing:"auto" with no usable roster (no member for the role) degrades to prompt's
# two-option form, and the reason contains no spawn-one line (§4.3)
write_repo_roster '[{"role":"reviewer","model":"opus","onMissing":"auto"}]'
set_route om5 peers
gate "$(payload om5 Agent ah:implementor 'implement it')"
check "5: no roster member for the dispatched role: degrades to the 2-option generic fallback ask" \
  'denied && echo "$OUT" | grep -q "spawn a subagent for this role instead"'
check "5: no spawn-one line in the degraded reason" '! echo "$OUT" | grep -q "spawn-one"'
check "5: no on-missing-auto gate recorded (never entered the auto path)" '! grep -q "\"type\":\"on-missing-auto\".*\"session_id\":\"om5\"" "$GATES"'

# ---- 6: onMissing:"auto" does not leak into the live-peer branch — a live instance exists,
# peersDenyReason fires unchanged regardless of onMissing
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"auto"}]'
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:"myrepo-implementor",role:"implementor",ts:new Date().toISOString()})+"\n");' "$PEERS"
set_route om6 peers
gate "$(payload om6 Agent ah:implementor 'implement it')"
check "6: live instance exists: denied with peersDenyReason (SendMessage instead), not the auto spawn-one text" \
  'denied && echo "$OUT" | grep -q "SendMessage it" && ! echo "$OUT" | grep -q "spawn-one"'

# ---- 7: prefer-peers route is unaffected by onMissing — no live peer, onMissing:"never":
# passes silently as today, no onMissing mention
: > "$PEERS"   # case 6 left a live "myrepo-implementor" registry entry; clear it for the no-live cases below
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"}]'
set_route om7 prefer-peers
gate "$(payload om7 Agent ah:implementor 'implement it')"
check "7: prefer-peers, no live peer: passes silently (RC 0, no output)" 'allowed'
check "7: no onMissing mention anywhere in output" '[ -z "$OUT" ]'

# ---- 8: scope gate wins — global-level roster, member has onMissing:"auto", no scope-A answer
# recorded: denied by scope A (names the global roster + msg.mjs global-scope roster), not by
# the auto spawn-one instruction. Pins the ordering against a future refactor (§4.4).
write_global_roster '[{"role":"architect","model":"opus","onMissing":"auto"}]'
gate "$(payload om8 Agent ah:architect 'design it')"
check "8: global roster, no scope-A answer: denied by scope A, names the global roster and msg.mjs global-scope roster" \
  'denied && echo "$OUT" | grep -qi "global" && echo "$OUT" | grep -q "global-scope roster"'
check "8: NOT denied by the auto spawn-one instruction" '! echo "$OUT" | grep -q "on-missing policy is \"auto\""'
check "8: no on-missing-auto gate recorded — scope A ran first and the routing block was never reached" \
  '! grep -q "\"type\":\"on-missing-auto\".*\"session_id\":\"om8\"" "$GATES"'

# ---- 9: multi-member role — two members of the same role with different onMissing values;
# the gate uses the FIRST in roster order
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"},{"role":"implementor","model":"opus","onMissing":"auto"}]'
set_route om9 peers
gate "$(payload om9 Agent ah:implementor 'implement it')"
check "9: multi-member role: first member's onMissing (never) wins, not the second's (auto)" \
  'allowed_with_note && echo "$OUT" | grep -q "on-missing policy is" && echo "$OUT" | grep -q "never"'

# ---- 11: fingerprint stability — normalizeMembers does not copy onMissing (spec 0021 §3.1,
# NEEDS-EVIDENCE #1, resolved: the field is display/dispatch-time only, never in the fingerprint)
FP_CHECK=$(node --input-type=module -e '
  import { normalizeMembers, fingerprint } from "'"$H"'/lib-roster.mjs";
  const withOnMissing = normalizeMembers([{ role: "implementor", model: "sonnet", onMissing: "auto" }]);
  const withoutOnMissing = normalizeMembers([{ role: "implementor", model: "sonnet" }]);
  const a = fingerprint({ roster_level: "repo", transport: "herdr", members: withOnMissing });
  const b = fingerprint({ roster_level: "repo", transport: "herdr", members: withoutOnMissing });
  console.log(a === b && !("onMissing" in withOnMissing[0]) && !("on_missing" in withOnMissing[0]) ? "PASS" : "FAIL " + JSON.stringify({ a, b, withOnMissing }));
' 2>&1)
check "11: fingerprint unchanged whether or not a member sets onMissing; normalizeMembers never copies the key" \
  '[ "$FP_CHECK" = "PASS" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
