#!/bin/bash
# task-gopher relay-gate + strict-checkpoint regression tests.
# Runs the hook with HOME redirected to a throwaway dir so real config is never touched.
# Usage: bash tests/test-relay-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-nudge.mjs"
FAKEHOME="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-relay-test.XXXXXX")"
trap 'rm -rf "$FAKEHOME"' EXIT
PASS=0; FAIL=0

REAL_RELAY="$(printf '%s' ~)/.claude/task-gopher.relay"
REAL_RELAY_PRE=0; [ -f "$REAL_RELAY" ] && REAL_RELAY_PRE=1

mkdir -p "$FAKEHOME/.claude"

# run_hook <payload-json>  -> sets OUT (stdout) and RC (exit code)
run_hook() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$HOOK" 2>/dev/null); RC=$?; }

check() { # check <name> <condition...>
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:120} RC=$RC)"; fi
}

is_allow() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
is_deny()  { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; }

DISPATCH_NOSENT='{"tool_name":"Agent","prompt_id":"PID","tool_input":{"subagent_type":"TYPE","prompt":"do the thing"}}'
DISPATCH_SENT='{"tool_name":"Agent","prompt_id":"PID","tool_input":{"subagent_type":"TYPE","prompt":"[task-gopher: ON] tier gate blah\n\ndo the thing"}}'
payload() { printf '%s' "$1" | sed "s/PID/$2/; s/TYPE/$3/"; }

# ---- 1. plugin OFF: everything passes through
run_hook "$(payload "$DISPATCH_NOSENT" t0 general-purpose)"
check "off: dispatch without sentinel allowed" is_allow

# ---- plugin ON (no strict)
touch "$FAKEHOME/.claude/task-gopher.enabled"

run_hook "$(payload "$DISPATCH_NOSENT" t1 task-gopher:task-gopher)"
check "on: dispatch TO gopher never bounced" is_allow
check "on: gopher dispatch logged" "grep -q '\"event\":\"dispatch\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(payload "$DISPATCH_NOSENT" t1 general-purpose)"
check "on: missing sentinel -> deny" is_deny
check "deny reason carries full directive" "printf '%s' \"\$OUT\" | grep -q 'COPY EVERYTHING BELOW'"
check "deny reason carries sentinel text" "printf '%s' \"\$OUT\" | grep -q 'task-gopher: ON'"

run_hook "$(payload "$DISPATCH_SENT" t1 general-purpose)"
check "on: sentinel present -> allow" is_allow
check "relay-ok logged" "grep -q '\"event\":\"relay-ok\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(payload "$DISPATCH_NOSENT" t1 general-purpose)"
check "on: second missing-sentinel dispatch -> deny (bounce 2)" is_deny

run_hook "$(payload "$DISPATCH_NOSENT" t1 general-purpose)"
check "on: third missing-sentinel dispatch -> fail-open allow" is_allow
check "relay-forgone logged" "grep -q '\"event\":\"relay-forgone\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(payload "$DISPATCH_NOSENT" t2 general-purpose)"
check "on: new turn re-arms relay gate -> deny" is_deny

run_hook "$(payload "$DISPATCH_NOSENT" t2 Explore)"
check "on: Explore exempt" is_allow

run_hook "$(payload "$DISPATCH_NOSENT" t2 Plan)"
check "on: Plan exempt" is_allow

INSIDE_GOPHER='{"tool_name":"Agent","prompt_id":"t2","agent_type":"task-gopher:task-gopher","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$INSIDE_GOPHER"
check "on: inside gopher runner nothing gates" is_allow

TASK_ALIAS='{"tool_name":"Task","prompt_id":"t3","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$TASK_ALIAS"
check "on: Task tool name gated same as Agent" is_deny

PAD=$(printf 'x%.0s' $(seq 1 210))
BURIED="{\"tool_name\":\"Agent\",\"prompt_id\":\"t3b\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"$PAD [task-gopher: ON] quoted mention\"}}"
run_hook "$BURIED"
check "on: sentinel buried past top window -> still deny" is_deny

NOSTRING='{"tool_name":"Agent","prompt_id":"t3c","tool_input":{"subagent_type":"general-purpose","prompt":42}}'
run_hook "$NOSTRING"
check "on: non-string prompt (schema drift) -> fail open" is_allow

run_hook "$(payload "$DISPATCH_NOSENT" t3d statusline-setup)"
check "on: statusline-setup exempt" is_allow

# ---- per-context bounce budgets (single shared slot would fail all of these)
SESA='{"tool_name":"Agent","prompt_id":"t5","session_id":"sA","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
SESB='{"tool_name":"Agent","prompt_id":"t5","session_id":"sB","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$SESA"; run_hook "$SESA"   # sA: bounces 1 and 2
run_hook "$SESB"
check "cross-session: sB has its own budget -> deny" is_deny
run_hook "$SESA"
check "cross-session: sA fail-open not reset by sB -> allow" is_allow

AG1='{"tool_name":"Agent","prompt_id":"t6","session_id":"sA","agent_id":"ag1","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
AG2='{"tool_name":"Agent","prompt_id":"t6","session_id":"sA","agent_id":"ag2","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$AG1"; run_hook "$AG1"; run_hook "$AG1"  # ag1: bounce, bounce, forgone
run_hook "$AG2"
check "sibling agent: budget not exhausted by ag1 -> deny" is_deny

X1='{"tool_name":"Agent","prompt_id":"p1","session_id":"sX","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
Y1='{"tool_name":"Agent","prompt_id":"p2","session_id":"sY","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$X1"; run_hook "$Y1"; run_hook "$X1"   # interleaved: X:1, Y:1, X:2
run_hook "$X1"
check "interleaved sessions: X still reaches fail-open -> allow" is_allow

READ_P='{"tool_name":"Read","prompt_id":"t4","tool_input":{"file_path":"/x"}}'
run_hook "$READ_P"
check "on (non-strict): Read not checkpointed" is_allow

# ---- strict mode regressions
touch "$FAKEHOME/.claude/task-gopher.strict"

run_hook "$READ_P"
check "strict: first Read of turn -> checkpoint deny" is_deny
run_hook "$READ_P"
check "strict: re-run passes (bypass 1)" is_allow
run_hook "$READ_P"
check "strict: bypass 2 silent" is_allow
run_hook "$READ_P"
check "strict: 3rd consecutive bypass -> escalated deny" is_deny

run_hook "$READ_P"; run_hook "$READ_P"   # bypasses 1 and 2 of the new streak
run_hook "$(payload "$DISPATCH_NOSENT" t4 task-gopher:task-gopher)"
check "strict: gopher dispatch allowed" is_allow
run_hook "$READ_P"
check "strict: dispatch reset streak (Read allowed, no escalate)" is_allow

# ---- robustness
run_hook 'not json at all'
check "malformed stdin -> allow" is_allow
run_hook ''
check "empty stdin -> allow" is_allow

# ---- syntax + json validity
for f in "$PLUGIN"/hooks/*.mjs; do
  node --check "$f" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: node --check $(basename "$f")"; } || { FAIL=$((FAIL+1)); echo "FAIL: node --check $(basename "$f")"; }
done
for j in "$PLUGIN/hooks/hooks.json" "$PLUGIN/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json"; do
  node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: valid JSON $(basename "$j")"; } || { FAIL=$((FAIL+1)); echo "FAIL: invalid JSON $j"; }
done

# ---- plugin.json and marketplace.json agree on the version
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='task-gopher').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

# ---- real config untouched (fail only if the file APPEARED during this run;
# a live session running the plugin may have created it beforehand)
if [ -f "$REAL_RELAY" ] && [ "$REAL_RELAY_PRE" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "FAIL: real relay file was created by the tests!"
else
  PASS=$((PASS+1)); echo "PASS: real ~/.claude/task-gopher.relay untouched by tests"
fi

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
