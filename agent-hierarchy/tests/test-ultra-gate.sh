#!/bin/bash
# agent-hierarchy Ultra-Advisor escalation-gate tests: PreToolUse decisions + gate CLI + directive text.
# HOME-redirected; real config and real gate state are never touched.
# Usage: bash tests/test-ultra-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
HOOK="$PLUGIN/hooks/pretooluse-ultra-gate.mjs"
CLI="$PLUGIN/hooks/gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-gate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
GATE_FILE="$FAKEHOME/.claude/agent-hierarchy.gate.json"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:200})"; fi
}

# hook <session_id> <subagent_type> [tool_name] [cwd]
hook() {
  local sid=$1 stype=$2 tool=${3:-Agent} cwd=${4:-$PROJ}
  OUT=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' \
        "$sid" "$cwd" "$tool" "$stype" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

cli()      { OUT=$(HOME="$FAKEHOME" node "$CLI" "$@" 2>&1); RC=$?; }
proj_cfg() { printf '%s\n' "$1" > "$PROJ/.claude/agent-hierarchy.json"; }
clear_all() { rm -f "$GATE_FILE" "$PROJ/.claude/agent-hierarchy.json"; }

# hook_send <session_id> <to> [cwd]
hook_send() {
  local sid=$1 to=$2 cwd=${3:-$PROJ}
  OUT=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"SendMessage","tool_input":{"to":"%s","message":"x"}}' \
        "$sid" "$cwd" "$to" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}
PEER_UA="$(basename "$PROJ")-ultra-advisor"

# The gate must hold for a plain install with no config file at all.
clear_all

# ---- passthrough: the gate is inert for everything that is not an Ultra-Advisor dispatch
hook s1 "agent-hierarchy:implementor"
check "implementor dispatch passes through" '[ -z "$OUT" ]'

hook s1 "task-gopher:task-gopher"
check "task-gopher dispatch passes through" '[ -z "$OUT" ]'

OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$PROJ" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "non-Agent tool passes through" '[ -z "$OUT" ]'

OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"Agent","tool_input":{}}' "$PROJ" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "Agent call with no subagent_type passes through" '[ -z "$OUT" ]'

# ---- SendMessage: only gated when the target is this repo's Ultra-Advisor peer
hook_send sm1 "unrelated-peer"
check "SendMessage to an unrelated peer passes through" '[ -z "$OUT" ]'

hook_send sm1 "$(basename "$PROJ")-architect"
check "SendMessage to a different role's peer passes through" '[ -z "$OUT" ]'

hook_send sm1 "$PEER_UA"
check "SendMessage to the Ultra-Advisor peer is gated (first use denied)" 'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'
check "SendMessage denial records no decision" '[ ! -f "$GATE_FILE" ]'

hook_send sm1 "$PEER_UA [abc123]"
check "SendMessage target with a trailing [ref] bracket still matches" 'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'

# ---- first use in a session: denied, with the recording command spelled out
hook s1 "agent-hierarchy:ultra-advisor"
check "first escalation is denied"          'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'
check "denial names AskUserQuestion"        'case "$OUT" in *AskUserQuestion*) true;; *) false;; esac'
check "denial carries the set command"      'case "$OUT" in *"gate.mjs\\\" set --session \\\"s1\\\" --choice CHOICE"*) true;; *) false;; esac'
check "denial offers all three answers"     'case "$OUT" in *"Yes, rest of session"*"Ask me each time"*"No, not this session"*) true;; *) false;; esac'
check "denial states nothing ran"           'case "$OUT" in *BLOCKED*) true;; *) false;; esac'

# A denial must not itself record anything — the user has not answered yet.
check "denial records no decision" '[ ! -f "$GATE_FILE" ]'

# ---- a session's approval covers both dispatch routes to the same role
cli set --session sm1 --choice session
hook_send sm1 "$PEER_UA"
check "session approval covers the SendMessage route" '[ -z "$OUT" ]'
hook sm1 "agent-hierarchy:ultra-advisor"
check "the same session's approval also covers the Agent-tool route" '[ -z "$OUT" ]'

hook s1 "ultra-advisor"
check "bare ultra-advisor name is gated too" 'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'

hook s1 "agent-hierarchy:ultra-advisor" Task
check "legacy Task tool name is gated"       'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'

# ---- choice: allow for the rest of the session
cli set --session s1 --choice session
check "set session exits 0"        '[ $RC -eq 0 ]'
check "set session confirms"       'case "$OUT" in *"rest of this session"*) true;; *) false;; esac'
hook s1 "agent-hierarchy:ultra-advisor"
check "allowed session passes through"    '[ -z "$OUT" ]'
hook s1 "agent-hierarchy:ultra-advisor"
check "allowance is not one-shot"         '[ -z "$OUT" ]'

# ---- scoping: one session's answer never speaks for another
hook s2 "agent-hierarchy:ultra-advisor"
check "a different session still asks"    'case "$OUT" in *\"permissionDecision\":\"deny\"*"has no decision on record"*) true;; *) false;; esac'

# ---- choice: ask before each escalation
cli set --session s2 --choice each
hook s2 "agent-hierarchy:ultra-advisor"
check "each-time yields ask"              'case "$OUT" in *\"permissionDecision\":\"ask\"*) true;; *) false;; esac'
hook s2 "agent-hierarchy:ultra-advisor"
check "each-time asks again next time"    'case "$OUT" in *\"permissionDecision\":\"ask\"*) true;; *) false;; esac'
check "ask reason names the model"        'case "$OUT" in *fable*) true;; *) false;; esac'

# ---- choice: blocked for this session
cli set --session s3 --choice off
hook s3 "agent-hierarchy:ultra-advisor"
check "off yields deny"                   'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'
check "off says do not retry"             'case "$OUT" in *"Do not retry"*) true;; *) false;; esac'
check "off does not re-prompt"            'case "$OUT" in *AskUserQuestion*) false;; *) true;; esac'

# ---- reset returns a session to unasked
cli reset --session s1
check "reset exits 0" '[ $RC -eq 0 ]'
hook s1 "agent-hierarchy:ultra-advisor"
check "reset session asks again"          'case "$OUT" in *"has no decision on record"*) true;; *) false;; esac'

# ---- CLI status
cli status --session s3
check "status reports the recorded choice" 'case "$OUT" in *"blocked for the rest of this session"*) true;; *) false;; esac'
cli status --session never-seen
check "status reports an undecided session" 'case "$OUT" in *"not yet decided"*) true;; *) false;; esac'
cli status
check "bare status lists every session (s2)" 'case "$OUT" in *s2*) true;; *) false;; esac'
check "bare status lists every session (s3)" 'case "$OUT" in *s3*) true;; *) false;; esac'
check "bare status is newest-first"          'case "$OUT" in *s3*s2*) true;; *) false;; esac'

# ---- CLI rejects garbage rather than storing it
cli set --session s9 --choice yes-please
check "unknown choice exits non-zero" '[ $RC -ne 0 ]'
hook s9 "agent-hierarchy:ultra-advisor"
check "rejected choice stored nothing" 'case "$OUT" in *"has no decision on record"*) true;; *) false;; esac'
cli set --session s9
check "missing --choice exits non-zero" '[ $RC -ne 0 ]'
cli set --choice session
check "missing --session exits non-zero" '[ $RC -ne 0 ]'

# ---- corrupt state fails closed (asks) rather than silently allowing
cli set --session s10 --choice session
printf 'not json at all' > "$GATE_FILE"
hook s10 "agent-hierarchy:ultra-advisor"
check "corrupt gate file falls back to asking" 'case "$OUT" in *"has no decision on record"*) true;; *) false;; esac'
rm -f "$GATE_FILE"

# ---- a disabled hierarchy has no role to gate
proj_cfg '{"version":1,"enabled":false}'
hook s11 "agent-hierarchy:ultra-advisor"
check "enabled:false passes through" '[ -z "$OUT" ]'
proj_cfg '{"version":1,"enabled":true,"roles":{"ultra-advisor":{"model":"opus"}}}'
hook s11 "agent-hierarchy:ultra-advisor"
check "re-enabled hierarchy gates again" 'case "$OUT" in *\"permissionDecision\":\"deny\"*) true;; *) false;; esac'
check "denial names the configured model" 'case "$OUT" in *opus*) true;; *) false;; esac'

# ---- the injected directive teaches the Orchestrator about the gate
eval_js() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('${LIB}');
    const r = L.resolveConfig('${PROJ}');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

eval_js "L.buildDirective(r, 'sid-abc')"
check "directive explains the gate"        'case "$OUT" in *"USER GATE"*) true;; *) false;; esac'
check "directive carries the session id"   'case "$OUT" in *"gate id is \"sid-abc\""*) true;; *) false;; esac'
check "directive gives the set command"    'case "$OUT" in *"set --session \"sid-abc\" --choice session|each|off"*) true;; *) false;; esac'
check "directive resolves the CLI path"    'case "$OUT" in *"$PLUGIN/hooks/gate.mjs"*) true;; *) false;; esac'
check "gate prompt supersedes item 0"      'case "$OUT" in *"ask once, not twice"*) true;; *) false;; esac'

eval_js "L.statusReport('${PROJ}')"
check "status report points at /hierarchy gate" 'case "$OUT" in *"/hierarchy gate"*) true;; *) false;; esac'

eval_js "L.buildDirective(r)"
check "directive without a session id still explains the gate" 'case "$OUT" in *"USER GATE"*) true;; *) false;; esac'
check "directive without a session id omits the command"       'case "$OUT" in *"gate id is"*) false;; *) true;; esac'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
