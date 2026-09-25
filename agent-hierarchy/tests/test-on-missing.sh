#!/bin/bash
# agent-hierarchy — spec 0021: per-roster-member `onMissing` policy, read by
# pretooluse-route-gate.mjs when no live instance exists. Only "auto" remains: a chain role never
# runs as a subagent, so a "prompt" or "never" left in a roster is ignored and gets the same wall.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-on-missing.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
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

# ---- 1: no member carries onMissing -> the default "auto": the spawn-one wall, every time, no ask
write_repo_roster '[{"role":"implementor","model":"sonnet"}]'
set_route om1 peers
gate "$(payload om1 Agent ah:implementor 'implement it')"
check "1: no onMissing set: denied naming the spawn-one command with --cwd, no AskUserQuestion" \
  'denied && echo "$OUT" | grep -q "spawn-one implementor --cwd" && ! echo "$OUT" | grep -q "AskUserQuestion"'
gate "$(payload om1 Agent ah:implementor 'implement it')"
check "1: re-issue denied again" 'denied && echo "$OUT" | grep -q "spawn-one implementor"'
check "1: no one-shot record written" '! grep "\"session_id\":\"om1\"" "$GATES" 2>/dev/null | grep -qE "peer-fallback-ask|on-missing-auto"'

# ---- 2: a stale onMissing:"prompt" is ignored — the spawn-one wall, no ask, and the re-issue is denied too
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"prompt"}]'
set_route om2 peers
gate "$(payload om2 Agent ah:implementor 'implement it')"
check "2: stale onMissing prompt: denied with the spawn-one command, no AskUserQuestion" \
  'denied && echo "$OUT" | grep -q "spawn-one implementor --cwd" && ! echo "$OUT" | grep -q "AskUserQuestion"'
check "2: no one-shot peer-fallback-ask recorded" '! grep "\"session_id\":\"om2\"" "$GATES" 2>/dev/null | grep -q "peer-fallback-ask"'
gate "$(payload om2 Agent ah:implementor 'implement it')"
check "2: re-issue denied again" 'denied && echo "$OUT" | grep -q "spawn-one implementor"'

# ---- 3: a stale onMissing:"never" is ignored — denied every time, no gate record
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"}]'
set_route om3 peers
gate "$(payload om3 Agent ah:implementor 'implement it')"
check "3: stale onMissing never: denied with the spawn-one command" 'denied && echo "$OUT" | grep -q "spawn-one implementor --cwd"'
check "3: no gate recorded for this session" '! grep "\"session_id\":\"om3\"" "$GATES" | grep -qE "on-missing-auto|peer-fallback-ask|route-deny"'
gate "$(payload om3 Agent ah:implementor 'implement it')"
check "3: still denied on a second dispatch" 'denied'

# ---- 4: onMissing:"auto" explicit — same wall as the default
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"auto"}]'
set_route om4 peers
gate "$(payload om4 Agent ah:implementor 'implement it')"
check "4: onMissing auto: denied naming the spawn-one command with --cwd" \
  'denied && echo "$OUT" | grep -q "spawn-one implementor" && echo "$OUT" | grep -q -- "--cwd"'
check "4: reason contains no AskUserQuestion instruction" '! echo "$OUT" | grep -q "AskUserQuestion"'
gate "$(payload om4 Agent ah:implementor 'implement it')"
check "4: re-issue denied again" 'denied'

# ---- 5: no roster member for the dispatched role -> the spawn-ad-hoc command, never an ask
write_repo_roster '[{"role":"reviewer","model":"opus","onMissing":"auto"}]'
set_route om5 peers
gate "$(payload om5 Agent ah:implementor 'implement it')"
check "5: no roster member for the dispatched role: spawn-ad-hoc command" 'denied && echo "$OUT" | grep -q "spawn-ad-hoc implementor --cwd"'
check "5: no spawn-one line and no ask" '! echo "$OUT" | grep -q "spawn-one" && ! echo "$OUT" | grep -q "AskUserQuestion"'

# ---- 6: onMissing does not leak into the live-peer branch — a live instance exists, the deny
# names it regardless of onMissing
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"auto"}]'
node -e 'const fs=require("fs");const[f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:"myrepo-implementor",role:"implementor",ts:new Date().toISOString()})+"\n");' "$PEERS"
set_route om6 peers
gate "$(payload om6 Agent ah:implementor 'implement it')"
check "6: live instance exists: denied naming it (SendMessage instead), not the spawn-one text" \
  'denied && echo "$OUT" | grep -q "myrepo-implementor" && echo "$OUT" | grep -q "SendMessage" && ! echo "$OUT" | grep -q "spawn-one"'

# ---- 7: a stale prefer-peers session record with no live peer is ignored too — the spawn-one wall
: > "$PEERS"   # case 6 left a live "myrepo-implementor" registry entry; clear it for the no-live cases below
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"}]'
echo '{"type":"route","session_id":"om7","value":"prefer-peers"}' >> "$GATES"
gate "$(payload om7 Agent ah:implementor 'implement it')"
check "7: stale prefer-peers record, no live peer: denied with the spawn-one command" 'denied && echo "$OUT" | grep -q "spawn-one implementor --cwd"'

# ---- 8: a global-level roster confirms nothing: its member's onMissing:"auto" gives the spawn-one wall
write_global_roster '[{"role":"architect","model":"opus","onMissing":"auto"}]'
gate "$(payload om8 Agent ah:architect 'design it')"
check "8: global roster: denied with the spawn-one command, no global-scope confirm" \
  'denied && echo "$OUT" | grep -q "spawn-one architect" && ! echo "$OUT" | grep -q "global-scope"'

# ---- 9: multi-member role — a stale "never" on the first member lets nothing through either
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"
write_repo_roster '[{"role":"implementor","model":"sonnet","onMissing":"never"},{"role":"implementor","model":"opus","onMissing":"auto"}]'
set_route om9 peers
gate "$(payload om9 Agent ah:implementor 'implement it')"
check "9: multi-member role: the first member's stale never is ignored — denied with the spawn-one command" 'denied && echo "$OUT" | grep -q "spawn-one implementor"'

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
