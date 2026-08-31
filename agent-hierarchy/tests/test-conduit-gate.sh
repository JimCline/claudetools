#!/bin/bash
# agent-hierarchy — spec 0028 §3 conduit gate: T1-T6, T24-T26.
# HOME-redirected; real config and real gate state are never touched.
# Usage: bash tests/test-conduit-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-conduit-gate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

# conduit_hook <tool_name> <session_id> [agent_type]
conduit_hook() {
  local tool=$1 sid=$2 atype=${3:-}
  OUT=$(printf '{"tool_name":"%s","session_id":"%s","cwd":"%s","agent_type":"%s","tool_input":{}}' \
        "$tool" "$sid" "$PROJ" "$atype" | HOME="$FAKEHOME" node "$H/pretooluse-conduit-gate.mjs" 2>&1); RC=$?
}

is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) true;; *) false;; esac; }
is_empty() { [ -z "$OUT" ]; }

# ---- T1: falsifiable — direct architect attribution denies AskUserQuestion
conduit_hook AskUserQuestion s1 "ah:architect"
check "T1: architect AskUserQuestion is denied" 'is_deny'
check "T1: denial names the role" 'case "$OUT" in *Architect*) true;; *) false;; esac'
check "T1: denial states returning unresolved is correct" 'case "$OUT" in *"correct outcome"*) true;; *) false;; esac'

# ---- T2: an ah:orchestrator-tagged session — hierarchyRoleOf excludes
# "orchestrator" from ROLES, so this never resolves direct:true; allowed.
conduit_hook AskUserQuestion s2 "ah:orchestrator"
check "T2: orchestrator-tagged session passes through" 'is_empty'

# ---- T3: no agent_type, no persisted role — degradation guard
conduit_hook AskUserQuestion s3
check "T3: unidentified caller passes through" 'is_empty'

# ---- T5/T5a/T5b: the other three gated tools, each falsifiable
conduit_hook ExitPlanMode s5 "ah:implementor"
check "T5: implementor ExitPlanMode is denied" 'is_deny'

conduit_hook SendUserFile s5a "ah:reviewer"
check "T5a: reviewer SendUserFile is denied" 'is_deny'
check "T5a: denial gives the artifact-path alternative" 'case "$OUT" in *"absolute path"*) true;; *) false;; esac'

conduit_hook PushNotification s5b "ah:architect"
check "T5b: architect PushNotification is denied" 'is_deny'

# ---- a non-gated tool is never touched
conduit_hook Bash s5c "ah:architect"
check "non-gated tool passes through regardless of role" 'is_empty'

# ---- T6: the three existing gates do not fire for a positively-attributed non-orchestrator role
ultra_hook() {
  local sid=$1 atype=$2
  OUT=$(printf '{"session_id":"%s","cwd":"%s","agent_type":"%s","tool_name":"Agent","tool_input":{"subagent_type":"ah:ultra-advisor","prompt":"x"}}' \
        "$sid" "$PROJ" "$atype" | HOME="$FAKEHOME" node "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
}
ultra_hook t6u "ah:architect"
check "T6: ultra-gate does not fire for a direct architect caller" 'is_empty'
# regression: ultra-gate still fires for an unidentified (orchestrator) caller
ultra_hook t6u2 ""
check "T6: ultra-gate still fires for an unidentified caller" 'is_deny'

msg_hook() {
  local sid=$1 atype=$2
  OUT=$(printf '{"session_id":"%s","cwd":"%s","agent_type":"%s","tool_name":"Agent","tool_input":{"subagent_type":"ah:reviewer","prompt":"x"}}' \
        "$sid" "$PROJ" "$atype" | HOME="$FAKEHOME" node "$H/pretooluse-msg-gate.mjs" 2>&1); RC=$?
}
msg_hook t6m "ah:architect"
check "T6: msg-gate does not fire for a direct architect caller" 'is_empty'
msg_hook t6m2 ""
check "T6: msg-gate still fires for an unidentified caller (missing token)" 'is_deny'

# route-gate already scopes itself to the Orchestrator via peers.jsonl's own
# "up" record (pre-existing, spec 0026) — assert it with a test rather than
# assuming it (§3.2 primary). A session recorded "up" as a subordinate role
# must not see the routing-preference ask that would otherwise fire on a
# peer-eligible Agent dispatch with no route recorded yet.
HIER_DIR="$SANDBOX/hier"
route_hook() {
  local sid=$1
  OUT=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"Agent","tool_input":{"subagent_type":"ah:architect","prompt":"x"}}' \
        "$sid" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
}
PEERS_JSONL="$HIER_DIR/peers.jsonl"
mkdir -p "$(dirname "$PEERS_JSONL")"
printf '{"type":"peer","status":"up","role":"implementor","session_id":"t6r","pid":%d,"ts":"%s"}\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PEERS_JSONL"
route_hook t6r
check "T6: route-gate does not ask a session already recorded as a subordinate role" 'is_empty'
route_hook t6r2
check "T6: route-gate still asks an unrecorded (orchestrator) session" 'is_deny'

# ---- T24: no agent_type, persisted role = architect -> allow (§3.7 face 1)
SESSROLE="$FAKEHOME/.claude/agent-hierarchy.session-roles.json"
mkdir -p "$(dirname "$SESSROLE")"
cat > "$SESSROLE" <<EOF
{"version":1,"sessions":{"t24":{"role":"architect","at":"2026-01-01T00:00:00Z"}}}
EOF
conduit_hook AskUserQuestion t24
check "T24: persisted-only architect role does not gate AskUserQuestion" 'is_empty'

# ---- T25: no agent_type, persisted role = orchestrator -> allow, and for the
# same reason as T24 (direct:false), not because "orchestrator" was trusted.
cat > "$SESSROLE" <<EOF
{"version":1,"sessions":{"t25":{"role":"orchestrator","at":"2026-01-01T00:00:00Z"}}}
EOF
conduit_hook AskUserQuestion t25
check "T25: persisted orchestrator role does not gate AskUserQuestion (not trusted either way)" 'is_empty'

# ---- T26: resolveHierarchyRole contract — direct:false whenever agent_type is absent
eval_js() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}
cat > "$SESSROLE" <<EOF
{"version":1,"sessions":{"t26":{"role":"architect","at":"2026-01-01T00:00:00Z"}}}
EOF
eval_js "JSON.stringify(C.resolveHierarchyRole({session_id:'t26'}))"
check "T26: no agent_type, persisted architect -> direct:false" 'case "$OUT" in *"\"direct\":false"*) true;; *) false;; esac'
check "T26: no agent_type, persisted architect -> role still surfaces (non-enforcing use)" 'case "$OUT" in *architect*) true;; *) false;; esac'
eval_js "JSON.stringify(C.resolveHierarchyRole({session_id:'never-seen'}))"
check "T26: no agent_type, no persisted role -> {role:null,direct:false}" '[ "$OUT" = "{\"role\":null,\"direct\":false}" ]'
eval_js "JSON.stringify(C.resolveHierarchyRole({agent_type:'ah:implementor',session_id:'t24'}))"
check "T26: agent_type present -> direct:true regardless of a conflicting persisted role" \
  'echo "$OUT" | grep -q "\"role\":\"implementor\",\"direct\":true"'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
