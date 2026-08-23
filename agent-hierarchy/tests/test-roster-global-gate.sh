#!/bin/bash
# agent-hierarchy — PreToolUse route gate: the global-scope confirm gate
# (spec 0009 §4) — two independent predicates, both answer-or-stay-denied,
# both evaluated before the pre-existing routing-preference block. Also
# covers §5's peer-first fallback rewrite. HOME- and AGENT_HIERARCHY_DIR-
# redirected; real state untouched.
# Usage: bash tests/test-roster-global-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
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
set_global_scope() { # <session> <roster|config> <allow|deny>
  HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" global-scope "$2" "$3" --session "$1" --cwd "$PROJ" >/dev/null; }
gates_for() { grep "\"session_id\":\"$1\"" "$GATES" 2>/dev/null; } # <session>

seed_live "g-impl-live" "implementor"

# ================= Scope A — roster identity =================

cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [
  {"role": "implementor", "name": "g-implementor", "model": "opus"}
] } }
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF

# ---- A1/A2/A3: ask, reask (unanswered stays denied), allow, then downstream enforcement
set_route sA1 peers
gate "$(PROJ="$PROJ" payload sA1 Agent ah:implementor 'implement it')"
check "A1: global roster, no answer, Agent dispatch -> denied naming the global path" \
  'denied && echo "$OUT" | grep -q "GLOBAL one at" && echo "$OUT" | grep -q "myrepo-implementor(implementor)"'
check "A1: ask prompt lists all three options, in order" \
  'case "$OUT" in *"Create a roster for this repo (Recommended)"*"Use the global roster for this session"*"Subagents only this session"*) true;; *) false;; esac'
check "A1: gates.jsonl ordering -- scope-A ask precedes any route-ask for this session" \
  'gates_for sA1 | grep -q "\"type\":\"global-scope-ask\"" && gates_for sA1 | grep -q "\"scope\":\"roster\"" && ! gates_for sA1 | grep -q "\"type\":\"route-ask\""'
gate "$(PROJ="$PROJ" payload sA1 Agent ah:implementor 'implement it')"
check "A2: identical re-issue, still no answer -> still denied (not fall-through, unlike route-ask)" \
  'denied && echo "$OUT" | grep -q "already asked about the global roster this session and did not record an answer"'
set_global_scope sA1 roster allow
gate "$(PROJ="$PROJ" payload sA1 Agent ah:implementor 'implement it')"
check "A3: after global-scope roster allow -> scope A no longer blocks (denied for a different, downstream reason)" \
  'denied && echo "$OUT" | grep -q "route is peers this session" && ! echo "$OUT" | grep -q "GLOBAL one at" && ! echo "$OUT" | grep -q "already asked about the global roster"'

# ---- A-deny: deny recorded -> denied every time, exact §4.8 text
gate "$(PROJ="$PROJ" payload sA2 Agent ah:implementor 'implement it')"
set_global_scope sA2 roster deny
gate "$(PROJ="$PROJ" payload sA2 Agent ah:implementor 'implement it')"
check "A-deny: first post-deny attempt -> denied with §4.8 text" \
  'denied && echo "$OUT" | grep -q "the global roster was declined for this session"'
gate "$(PROJ="$PROJ" payload sA2 Agent ah:implementor 'implement it')"
check "A-deny: second post-deny attempt -> denied every time, not one-shot" \
  'denied && echo "$OUT" | grep -q "the global roster was declined for this session"'

# ---- A-route: route subagents is a scope-A escape for Agent dispatch, NOT for a SendMessage brief
set_route sA3 subagents
gate "$(PROJ="$PROJ" payload sA3 Agent ah:implementor 'implement it')"
check "A-route: route subagents + Agent dispatch -> scope A passes (fully allowed)" 'allowed'
gate "$(PROJ="$PROJ" send_payload sA3 g-impl-live "[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]
plain")"
check "A-route: route subagents + SendMessage peer brief -> scope A still denies" \
  'denied && echo "$OUT" | grep -q "GLOBAL one at"'

# ---- A-repo: a repo-level roster shadows the global one -> scope A never fires
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [
  {"role": "implementor", "name": "myrepo-implementor", "model": "opus"}
] } }
EOF
set_route sA4 peers
gate "$(PROJ="$PROJ" payload sA4 Agent ah:implementor 'implement it')"
check "A-repo: repo-level roster resolves -> scope A never fires" \
  '! echo "$OUT" | grep -q "GLOBAL one at" && ! gates_for sA4 | grep -q "\"scope\":\"roster\""'

# ---- A-none: no roster at any level -> scope A never fires
cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF
set_route sA5 subagents
gate "$(PROJ="$PROJ" payload sA5 Agent ah:implementor 'implement it')"
check "A-none: no roster anywhere -> scope A never fires (fully allowed)" 'allowed'

# ================= Scope B — role configuration =================

cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roles": {
  "implementor": { "model": "opus", "effort": "high", "dispatch": "peer", "peer": "g-impl" },
  "architect": { "model": "opus", "dispatch": "peer", "peer": "g-arch" },
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": "g-rev" },
  "ultra-advisor": { "model": "fable", "dispatch": "peer", "peer": "g-ultra" }
} }
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF

gate "$(PROJ="$PROJ" payload sB1 Agent ah:implementor 'implement it')"
check "B1: role defined only in user-scope config -> denied, names model/effort (also the §8.11 vocabulary-trap regression: a '===\"global\"' predicate would never fire here)" \
  'denied && echo "$OUT" | grep -q "USER-scope config" && echo "$OUT" | grep -q "model=opus" && echo "$OUT" | grep -q "effort=high"'

set_route sB2 subagents
gate "$(PROJ="$PROJ" payload sB2 Agent ah:implementor 'implement it')"
check "B2: route subagents + plain Agent dispatch -> STILL denied (scope B has no route escape)" \
  'denied && echo "$OUT" | grep -q "USER-scope config"'

cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roles": {
  "implementor": { "model": "opus", "dispatch": "peer", "peer": "repo-impl" }
} }
EOF
set_route sB3 subagents
gate "$(PROJ="$PROJ" payload sB3 Agent ah:implementor 'implement it')"
check "B3: role also defined at project level -> sources[role]===project -> scope B never fires" 'allowed'

rm -f "$GLOBAL_CFG" "$REPO_CFG"
set_route sB4 subagents
gate "$(PROJ="$PROJ" payload sB4 Agent ah:implementor 'implement it')"
check "B4: no config file anywhere -> sources[role]===default -> scope B never fires (wall-vs-policy, §8.10)" 'allowed'

cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roles": {
  "implementor": { "model": "opus", "effort": "high", "dispatch": "peer", "peer": "g-impl" },
  "architect": { "model": "opus", "dispatch": "peer", "peer": "g-arch" },
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": "g-rev" },
  "ultra-advisor": { "model": "fable", "dispatch": "peer", "peer": "g-ultra" }
} }
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF

set_route sB6 subagents
gate "$(PROJ="$PROJ" payload sB6 Agent ah:implementor 'implement it')"
check "B6a: fresh session, implementor user-scoped -> denied" 'denied'
set_global_scope sB6 config allow
gate "$(PROJ="$PROJ" payload sB6 Agent ah:implementor 'implement it')"
check "B6b: after config allow -> implementor passes" 'allowed'
gate "$(PROJ="$PROJ" payload sB6 Agent ah:reviewer 'review it')"
check "B6c: config allow is per-session, not per-role -> reviewer (also user-scoped) passes too, no re-ask" 'allowed'

gate "$(PROJ="$PROJ" payload sB8 Agent ah:ultra-advisor 'advise')"
check "B8: ultra-advisor with user-scope config -> scope B does not fire (its own ultra gate covers it)" \
  '! gates_for sB8 | grep -q "\"scope\":\"config\""'

gate "$(PROJ="$PROJ" payload_cwd "$FAKEHOME" sB9 Agent ah:implementor 'implement it')"
check "B9: cwd is \$HOME -> user scope is the only layer -> scope B fires on the first dispatch" \
  'denied && echo "$OUT" | grep -q "USER-scope config"'

# ================= Shared =================

cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true,
  "roster": { "route": "peer", "members": [
    {"role": "implementor", "name": "g-implementor", "model": "opus"}
  ] },
  "roles": { "implementor": { "model": "opus", "effort": "high", "dispatch": "peer", "peer": "g-impl" } }
}
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF

gate "$(PROJ="$PROJ" payload sS1 Agent ah:implementor 'implement it')"
check "S1: both scopes firing -> scope A denies first, and mentions scope B is pending" \
  'denied && echo "$OUT" | grep -q "GLOBAL one at" && echo "$OUT" | grep -q "a second question about user-scope role configuration (scope B) is also pending"'
set_global_scope sS1 roster allow
gate "$(PROJ="$PROJ" payload sS1 Agent ah:implementor 'implement it')"
check "S1b: scope-A allow does not satisfy scope B -- it still asks separately" \
  'denied && echo "$OUT" | grep -q "USER-scope config"'

set_global_scope sS2 config allow
gate "$(PROJ="$PROJ" payload sS2 Agent ah:implementor 'implement it')"
check "S2: scope-B allow (recorded first) does not satisfy scope A -- scope A still asks" \
  'denied && echo "$OUT" | grep -q "GLOBAL one at" && ! echo "$OUT" | grep -q "USER-scope config"'

cat > "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "enabled": true }
EOF
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [
  {"role": "reviewer", "name": "myrepo-reviewer", "model": "opus"}
] } }
EOF

set_route sS3 peers
gate "$(PROJ="$PROJ" payload sS3 Agent ah:reviewer 'review it')"
check "S3: peers route, no live peer, repo roster has the role -> fallback lists the peer option first, with the spawn-one command" \
  'denied && echo "$OUT" | grep -q "Stand up the real Reviewer peer (Recommended)" && echo "$OUT" | grep -q "spawn-one reviewer --cwd $PROJ"'
case "$OUT" in
  *"Stand up the real Reviewer peer (Recommended)"*"Spawn a one-off subagent instead"*"Neither"*) ORDER_OK=0 ;;
  *) ORDER_OK=1 ;;
esac
check "S3b: peer option is listed FIRST, ahead of the subagent option" '[ "$ORDER_OK" -eq 0 ]'

set_route sS4 peers
gate "$(PROJ="$PROJ" payload sS4 Agent ah:architect 'design it')"
check "S4: peers route, no live peer, no roster entry for the role -> peer option omitted, names why" \
  'denied && echo "$OUT" | grep -q "no roster entry for Architect" && ! echo "$OUT" | grep -q "Stand up the real"'

# ---- malformed gates.jsonl -> never crashes the hook (§8.12). Last: corrupts $GATES for the rest of the run.
# lib-hier.mjs's readJsonl() already skips unparseable lines per-line (pre-existing, not part of
# this spec's change) -- so a single bad line degrades to "that record is silently absent", not to
# the outer catch. It still must not wedge the session: exit 0, well-formed output or none.
printf 'not valid json\n' > "$GATES"
gate "$(PROJ="$PROJ" payload sZ Agent ah:reviewer 'review it')"
check "malformed gates.jsonl: never crashes -- exit 0, no stack trace, well-formed output or none" \
  '[ $RC -eq 0 ] && { [ -z "$OUT" ] || echo "$OUT" | grep -q "hookSpecificOutput"; }'

# ---- every hooks/*.mjs still parses
SYNTAX_BAD=$(cd "$H" && for f in *.mjs; do node --check "$f" >/dev/null 2>&1 || echo "$f"; done)
check "every hooks/*.mjs passes node --check" '[ -z "$SYNTAX_BAD" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
