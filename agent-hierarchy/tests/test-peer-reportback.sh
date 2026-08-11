#!/bin/bash
# agent-hierarchy peer report-back contract tests: sentinel/wrapper parsing,
# UserPromptSubmit tracking, PostToolUse resolution, Stop nudge/waive, and the
# injected directive/role-notice text. HOME-redirected; real state untouched.
# Usage: bash tests/test-peer-reportback.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
PEERLIB="$PLUGIN/hooks/lib-peer.mjs"
UPS="$PLUGIN/hooks/userpromptsubmit-peer-tracking.mjs"
PTU="$PLUGIN/hooks/posttooluse-peer-resolve.mjs"
STOP="$PLUGIN/hooks/stop-peer-nudge.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-peer-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
STATE_FILE="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

reset_state() { rm -f "$STATE_FILE"; }

# JSON payload builders (node-built, so fixture text with quotes/brackets/newlines never breaks the envelope).
ups_payload()  { node -e 'const[s,p,a]=process.argv.slice(1);const o={session_id:s,prompt:p,hook_event_name:"UserPromptSubmit"};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3"; }
ptu_payload()  { node -e 'const[s,t,a]=process.argv.slice(1);const o={session_id:s,tool_name:"SendMessage",tool_input:{to:t,message:"x"}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3"; }
stop_payload() { node -e 'const[s,active,a]=process.argv.slice(1);const o={session_id:s,stop_hook_active:active==="true"};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3"; }

ups()  { OUT=$(ups_payload "$1" "$2" "$3" | HOME="$FAKEHOME" node "$UPS" 2>&1); RC=$?; }
ptu()  { OUT=$(ptu_payload "$1" "$2" "$3" | HOME="$FAKEHOME" node "$PTU" 2>&1); RC=$?; }
stop() { OUT=$(stop_payload "$1" "${2:-false}" "$3" | HOME="$FAKEHOME" node "$STOP" 2>&1); RC=$?; }

eval_peer() { # <js expression over lib-peer.mjs bound as P>
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const P = await import('${PEERLIB}');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

eval_js() { # <js expression over lib-config.mjs bound as L>
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('${LIB}');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

# ---- fixture texts ----
WELLFORMED='<cross-session-message from="uds:/tmp/cc-socks/12345.sock" from-name="orchestrator-x" from-mode="prompting">
[hierarchy-peer-brief reply-to="sender" task="spec-review"]

Please implement the spec at /tmp/spec.md and report back.
</cross-session-message>'

THIRDPARTY='<cross-session-message from="uds:/tmp/cc-socks/999.sock" from-name="relay-session" from-mode="prompting">
[hierarchy-peer-brief reply-to="orig-caller [ab12cd]" task="third-party-task"]

Reply to orig-caller instead of me.
</cross-session-message>'

NO_SENTINEL='<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="x" from-mode="prompting">
just an ordinary relayed message, no sentinel here
</cross-session-message>'

SENTINEL_NO_WRAPPER='[hierarchy-peer-brief reply-to="sender" task="typed-directly"]
a human typed this sentinel with no cross-session-message wrapper around it'

# A report/reply that QUOTES a brief's sentinel line rather than opening with
# one — the sentinel is present in the text but not anchored, so this must
# NOT be treated as a tasking (regression: unanchored matching was a review-
# caught spec-defect that recorded a phantom obligation from a quoted brief).
QUOTED_SENTINEL='<cross-session-message from="uds:/tmp/cc-socks/555.sock" from-name="reporter-x" from-mode="prompting">
Here is my report on the earlier task. For reference, the original brief said:
[hierarchy-peer-brief reply-to="sender" task="spec-review"]
Everything is done.
</cross-session-message>'

# =====================================================================
# 1. Directive / role-notice text
# =====================================================================
user_cfg()   { printf '%s\n' "$1" > "$FAKEHOME/.claude/agent-hierarchy.json"; }
clear_cfgs() { rm -f "$FAKEHOME/.claude/agent-hierarchy.json" "$PROJ/.claude/agent-hierarchy.json"; }
BASE='"version":1,"enabled":true,"roles":{}'

clear_cfgs
user_cfg "{$BASE,\"handoffs\":\"auto\"}"
eval_js "L.buildDirective(L.resolveConfig('${PROJ}'))"
check "auto-mode directive contains PEER BRIEF CONTRACT" 'printf "%s" "$OUT" | grep -q "PEER BRIEF CONTRACT"'
check "auto-mode directive gives the sentinel line" 'printf "%s" "$OUT" | grep -q "hierarchy-peer-brief reply-to"'

clear_cfgs
user_cfg "{$BASE,\"handoffs\":\"confirm\"}"
eval_js "L.buildDirective(L.resolveConfig('${PROJ}'))"
check "confirm-mode directive contains PEER BRIEF CONTRACT" 'printf "%s" "$OUT" | grep -q "PEER BRIEF CONTRACT"'
check "confirm-mode item 0 references the PEER BRIEF CONTRACT" 'printf "%s" "$OUT" | grep -q "must follow the PEER BRIEF CONTRACT above"'
clear_cfgs

eval_js "L.buildRoleSessionNotice('architect', 'agent-hierarchy:architect')"
check "role-session notice carries the reply-to obligation" 'printf "%s" "$OUT" | grep -q "hierarchy-peer-brief reply-to=..."'
check "role-session notice says the task is not finished until delivered" 'printf "%s" "$OUT" | grep -q "not finished until you have sent your report back"'

# =====================================================================
# 2. Sentinel / wrapper parsing (lib-peer.mjs directly)
# =====================================================================
eval_peer "JSON.stringify(P.extractPendingRecord(\`$WELLFORMED\`))"
check "well-formed: parses" '[ "$OUT" != null ]'
check "well-formed: from extracted"      'printf "%s" "$OUT" | grep -q "uds:/tmp/cc-socks/12345.sock"'
check "well-formed: from_name extracted" 'printf "%s" "$OUT" | grep -q "orchestrator-x"'
check "well-formed: reply_to extracted"  'printf "%s" "$OUT" | grep -q "\"reply_to\":\"sender\""'
check "well-formed: task extracted"      'printf "%s" "$OUT" | grep -q "\"task\":\"spec-review\""'

eval_peer "JSON.stringify(P.extractPendingRecord(\`$NO_SENTINEL\`))"
check "no sentinel -> null (ignored)" '[ "$OUT" = null ]'

eval_peer "JSON.stringify(P.extractPendingRecord(\`$SENTINEL_NO_WRAPPER\`))"
check "sentinel without wrapper -> null (ignored, fail open)" '[ "$OUT" = null ]'

eval_peer "JSON.stringify(P.extractPendingRecord(''))"
check "empty text -> null" '[ "$OUT" = null ]'

eval_peer "JSON.stringify(P.extractPendingRecord(\`$QUOTED_SENTINEL\`))"
check "quoted (unanchored) sentinel -> null (not a tasking)" '[ "$OUT" = null ]'

# =====================================================================
# 3. UserPromptSubmit tracking hook
# =====================================================================
reset_state
ups s1 "$WELLFORMED"
check "well-formed prompt: hook exits clean" '[ -z "$OUT" ]'
check "well-formed prompt: pending record appended" '[ -f "$STATE_FILE" ] && grep -q "\"status\":\"pending\"" "$STATE_FILE"'
check "well-formed prompt: record carries this session id" 'grep -q "\"session_id\":\"s1\"" "$STATE_FILE"'

reset_state
ups s2 "$NO_SENTINEL"
check "ordinary relayed prompt: no state file created" '[ ! -f "$STATE_FILE" ]'

reset_state
ups sQ "$QUOTED_SENTINEL"
check "report quoting a brief's sentinel: no state file created (regression)" '[ ! -f "$STATE_FILE" ]'

reset_state
ups s3 "$WELLFORMED" "sub-agent-1"
check "subagent payload: no-ops (no state file)" '[ ! -f "$STATE_FILE" ]'

# =====================================================================
# 4. PostToolUse resolution
# =====================================================================
reset_state
ups s4 "$WELLFORMED"
ptu s4 "uds:/tmp/cc-socks/12345.sock"
eval_peer "P.pendingFor('s4').length"
check "resolve via raw from (exact socket address)" '[ "$OUT" = 0 ]'

reset_state
ups s5 "$WELLFORMED"
ptu s5 "orchestrator-x"
eval_peer "P.pendingFor('s5').length"
check "resolve via from_name (bare)" '[ "$OUT" = 0 ]'

reset_state
ups s6 "$WELLFORMED"
ptu s6 "orchestrator-x [deadbe]"
eval_peer "P.pendingFor('s6').length"
check "resolve via from_name with trailing [ref] stripped" '[ "$OUT" = 0 ]'

reset_state
ups s7 "$THIRDPARTY"
ptu s7 "orig-caller"
eval_peer "P.pendingFor('s7').length"
check "resolve via explicit third-party reply_to (ref stripped in the sentinel itself)" '[ "$OUT" = 0 ]'

reset_state
ups s8 "$WELLFORMED"
ptu s8 "some-unrelated-peer"
eval_peer "P.pendingFor('s8').length"
check "non-matching SendMessage target leaves the obligation pending" '[ "$OUT" = 1 ]'

reset_state
ups s9 "$WELLFORMED"
ptu s9 "uds:/tmp/cc-socks/12345.sock" "sub-agent-1"
eval_peer "P.pendingFor('s9').length"
check "subagent SendMessage: no-ops, obligation stays pending" '[ "$OUT" = 1 ]'

# =====================================================================
# 5. Stop hook: block / nudge-count / waive / stop_hook_active / subagent
# =====================================================================
reset_state
stop s-nopending
check "no pending obligations: allow (no output)" '[ -z "$OUT" ]'

reset_state
ups s10 "$WELLFORMED"
stop s10
check "1st stop with pending obligation: blocks" 'printf "%s" "$OUT" | grep -q "\"decision\":\"block\""'
check "block reason names the task"      'printf "%s" "$OUT" | grep -q "spec-review"'
check "block reason names the from_name" 'printf "%s" "$OUT" | grep -q "orchestrator-x"'
check "block reason gives the reply instruction" 'printf "%s" "$OUT" | grep -q "SendMessage it now with to:"'
check "block reason names the from address" 'printf "%s" "$OUT" | grep -q "uds:/tmp/cc-socks/12345.sock"'

stop s10
check "2nd stop, still unresolved: blocks again" 'printf "%s" "$OUT" | grep -q "\"decision\":\"block\""'

stop s10
check "3rd stop, still unresolved: waived, allowed (no output)" '[ -z "$OUT" ]'
eval_peer "P.pendingFor('s10').length"
check "waived obligation no longer counts as pending" '[ "$OUT" = 0 ]'

stop s10
check "4th stop: nothing pending, allow" '[ -z "$OUT" ]'

reset_state
ups s11 "$WELLFORMED"
stop s11 true
check "stop_hook_active:true always allows, even with pending obligations" '[ -z "$OUT" ]'

reset_state
ups s12 "$WELLFORMED"
stop s12 false "sub-agent-1"
check "subagent Stop payload: no-ops, allows" '[ -z "$OUT" ]'

# ---- multiple owed reports in one reason
reset_state
ups s13 "$WELLFORMED"
ups s13 "$THIRDPARTY"
stop s13
check "two owed reports: reason mentions both tasks" 'printf "%s" "$OUT" | grep -q "spec-review" && printf "%s" "$OUT" | grep -q "third-party-task"'

# =====================================================================
# 6. Corrupt state file fails open
# =====================================================================
reset_state
ups s14 "$WELLFORMED"
printf 'not json at all\n' >> "$STATE_FILE"
stop s14
check "corrupt line in state file: hook does not crash" '[ $RC -eq 0 ]'
check "corrupt line in state file: still blocks on the real pending record" 'printf "%s" "$OUT" | grep -q "\"decision\":\"block\""'

reset_state
printf 'not json at all\nalso not json\n' > "$STATE_FILE"
stop s15
check "state file is ENTIRELY corrupt: fails open, allows" '[ $RC -eq 0 ] && [ -z "$OUT" ]'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
