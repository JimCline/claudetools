#!/bin/bash
# task-gopher relay-gate + strict-checkpoint regression tests.
# Runs the hook with HOME redirected to a throwaway dir so real config is never touched.
# Usage: bash tests/test-relay-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-nudge.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-relay-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
SANDBOX_COUNT="$SANDBOX/stamped.count"
PASS=0; FAIL=0

REAL_NUDGE="$(printf '%s' ~)/.claude/task-gopher.nudge"
REAL_NUDGE_PRE=0; [ -f "$REAL_NUDGE" ] && REAL_NUDGE_PRE=1

mkdir -p "$FAKEHOME/.claude"
: > "$SANDBOX_COUNT"

# run_hook <payload-json>  -> sets OUT (stdout) and RC (exit code)
run_hook() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$HOOK" 2>/dev/null); RC=$?; }

check() { # check <name> <condition...>
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:120} RC=$RC)"; fi
}

is_allow()  { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
is_deny()   { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; }
is_inject() { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"updatedInput"'; }

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
check "on: missing sentinel -> rewrites the dispatch (updatedInput)" is_inject
check "rewritten prompt is stamped with the directive" "printf '%s' \"\$OUT\" | grep -q 'task-gopher: ON'"
check "rewritten prompt keeps the original task text" "printf '%s' \"\$OUT\" | grep -q 'do the thing'"
check "rewrite does NOT deny" "! printf '%s' \"\$OUT\" | grep -q 'permissionDecision'"
check "relay-injected logged" "grep -q '\"event\":\"relay-injected\"' \"$FAKEHOME/.claude/task-gopher.log\""
# every other tool_input field must survive the rewrite
OUT=$(printf '%s' '{"tool_name":"Agent","prompt_id":"t1b","tool_input":{"subagent_type":"general-purpose","prompt":"x","description":"keep me","model":"opus"}}' | HOME="$FAKEHOME" node "$HOOK"); RC=$?
check "rewrite preserves other tool_input fields" "printf '%s' \"\$OUT\" | grep -q 'keep me' && printf '%s' \"\$OUT\" | grep -q 'opus'"
check "rewrite preserves subagent_type" "printf '%s' \"\$OUT\" | grep -q 'general-purpose'"

run_hook "$(payload "$DISPATCH_SENT" t1 general-purpose)"
check "on: sentinel present -> allow, no double-stamp" is_allow
check "relay-ok logged" "grep -q '\"event\":\"relay-ok\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(payload "$DISPATCH_NOSENT" t2 general-purpose)"
check "on: every dispatch is stamped (no once-per-turn limit)" is_inject

run_hook "$(payload "$DISPATCH_NOSENT" t2 Explore)"
check "on: Explore exempt" is_allow

run_hook "$(payload "$DISPATCH_NOSENT" t2 Plan)"
check "on: Plan exempt" is_allow

INSIDE_GOPHER='{"tool_name":"Agent","prompt_id":"t2","agent_type":"task-gopher:task-gopher","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$INSIDE_GOPHER"
check "on: inside gopher runner nothing gates" is_allow

TASK_ALIAS='{"tool_name":"Task","prompt_id":"t3","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$TASK_ALIAS"
check "on: Task tool name gated same as Agent" is_inject

PAD=$(printf 'x%.0s' $(seq 1 210))
BURIED="{\"tool_name\":\"Agent\",\"prompt_id\":\"t3b\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"$PAD [task-gopher: ON] quoted mention\"}}"
run_hook "$BURIED"
check "on: sentinel buried past top window -> still stamped" is_inject

NOSTRING='{"tool_name":"Agent","prompt_id":"t3c","tool_input":{"subagent_type":"general-purpose","prompt":42}}'
run_hook "$NOSTRING"
check "on: non-string prompt (schema drift) -> fail open" is_allow

run_hook "$(payload "$DISPATCH_NOSENT" t3d statusline-setup)"
check "on: statusline-setup exempt" is_allow

# ---- the rewrite is stateless: every context is stamped, always
SESA='{"tool_name":"Agent","prompt_id":"t5","session_id":"sA","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
SESB='{"tool_name":"Agent","prompt_id":"t5","session_id":"sB","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$SESA"; run_hook "$SESA"; run_hook "$SESA"
check "repeat dispatches in one turn: still stamped (no budget to exhaust)" is_inject
run_hook "$SESB"
check "second session: stamped, unaffected by the first" is_inject

AG1='{"tool_name":"Agent","prompt_id":"t6","session_id":"sA","agent_id":"ag1","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
run_hook "$AG1"
check "nested dispatch from inside a subagent: stamped (chain is automatic)" is_inject

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

run_hook "$READ_P"
check "strict: re-run passes after escalation (escape hatch survives the reset)" is_allow
run_hook "$READ_P"                       # bypass 2 of the new streak
run_hook "$(payload "$DISPATCH_NOSENT" t4 task-gopher:task-gopher)"
check "strict: gopher dispatch allowed" is_allow
run_hook "$READ_P"
check "strict: dispatch reset streak (Read allowed, no escalate)" is_allow

# ---- THE INTERLEAVE BUG: state was one shared {pid,n} slot, so any other
# context writing its own id made the next reader see a foreign turn and
# re-fire the turn-start checkpoint. Measured in the wild: 76% of turn-start
# checkpoints hit a turn already in progress, median 2.7s after its last event.
# A checkpointed context must survive another context checkpointing between
# its calls.
READ_OTHER='{"tool_name":"Read","prompt_id":"tOTHER","session_id":"sOTHER","tool_input":{"file_path":"/x"}}'
run_hook "$READ_OTHER"
check "strict: a different context gets its own turn-start" is_deny
run_hook "$READ_P"
check "strict: original context NOT re-checkpointed after a foreign turn" is_allow

# Concurrent sessions must not share a streak at all.
READ_S2='{"tool_name":"Read","prompt_id":"tS","session_id":"sTWO","tool_input":{"file_path":"/x"}}'
READ_S3='{"tool_name":"Read","prompt_id":"tS","session_id":"sTHREE","tool_input":{"file_path":"/x"}}'
run_hook "$READ_S2"; run_hook "$READ_S2"   # sTWO: checkpointed, then bypassing
run_hook "$READ_S3"
check "strict: same prompt_id in another SESSION is its own streak" is_deny

# ---- a subagent gets its own budget, not the parent's spent one.
# Uses a fresh turn so the parent's own streak position is unambiguous:
# before the fix, the subagent shared the parent's counter, so a parent that
# had already spent its turn-start meant the subagent was never checkpointed
# at all — measured live, a subagent's first Read sailed straight through.
READ_PAR='{"tool_name":"Read","prompt_id":"tPAR","session_id":"sPAR","tool_input":{"file_path":"/x"}}'
READ_SUB='{"tool_name":"Read","prompt_id":"tPAR","session_id":"sPAR","agent_id":"agSUB","tool_input":{"file_path":"/x"}}'
run_hook "$READ_PAR"
check "strict: parent turn-start" is_deny
run_hook "$READ_PAR"
check "strict: parent bypass 1" is_allow
run_hook "$READ_SUB"
check "strict: subagent in an already-checkpointed turn is still checkpointed" is_deny
run_hook "$READ_SUB"
check "strict: subagent re-run passes" is_allow
run_hook "$READ_PAR"
check "strict: subagent's streak did not consume the parent's budget" is_allow

# ---- retrieval detection is POSITIONAL, not a substring scan.
# Each of these previously matched somewhere in the raw string and got blocked,
# though none of them is a retrieval. Uses a fresh turn per case so a checkpoint
# would be unambiguous: a gated command denies on its turn's first call, an
# ungated one is allowed outright.
bash_payload() { # <command> <prompt_id>
  printf '{"tool_name":"Bash","prompt_id":"%s","session_id":"sB","tool_input":{"command":%s}}' \
    "$2" "$(printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
}

run_hook "$(bash_payload 'git push origin main | tail -10' b1)"
check "strict: 'push | tail' is trimming output, not retrieval" is_allow
run_hook "$(bash_payload 'npm run deploy | head -5' b2)"
check "strict: '| head' is trimming output, not retrieval" is_allow
run_hook "$(bash_payload 'git commit -m "add tail support and cat helpers"' b3)"
check "strict: retrieval words inside a commit message are text" is_allow
run_hook "$(bash_payload 'git add -A && git commit -m "fix"' b4)"
check "strict: plain state changes still ungated" is_allow

# ...and the real retrievals must still be caught.
run_hook "$(bash_payload 'tail -200 /var/log/app.log' b5)"
check "strict: leading 'tail FILE' IS retrieval" is_deny
run_hook "$(bash_payload 'cat src/index.ts' b6)"
check "strict: leading 'cat FILE' IS retrieval" is_deny
run_hook "$(bash_payload 'ls -la && grep -rn TODO src/' b7)"
check "strict: grep in a later stage IS retrieval" is_deny
run_hook "$(bash_payload 'npm test 2>&1 | tail -40' b8)"
check "strict: a test run stays gated despite the trailing tail" is_deny

# ---- state is an append-only line log, not a rewritten JSON slot
check "strict: nudge state is a line log, not JSON" \
  '! head -c 1 "$FAKEHOME/.claude/task-gopher.nudge" | grep -q "{"'
check "strict: parent and subagent are separate keys" \
  'grep -q "^sPAR||tPAR" "$FAKEHOME/.claude/task-gopher.nudge" && grep -q "^sPAR|agSUB|tPAR" "$FAKEHOME/.claude/task-gopher.nudge"'

# ---- concurrent dispatches all get stamped (rewrite keeps no shared state)
for i in $(seq 1 12); do
  printf '%s' "{\"tool_name\":\"Agent\",\"prompt_id\":\"cc\",\"session_id\":\"s$i\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"x\"}}" \
    | HOME="$FAKEHOME" node "$HOOK" 2>/dev/null | grep -c '"updatedInput"' >> "$SANDBOX_COUNT" &
done
wait
STAMPED=$(awk '{s+=$1} END {print s+0}' "$SANDBOX_COUNT")
[ "$STAMPED" -eq 12 ] && { PASS=$((PASS+1)); echo "PASS: 12 concurrent dispatches, all 12 stamped"; } || { FAIL=$((FAIL+1)); echo "FAIL: only $STAMPED/12 concurrent dispatches stamped"; }
STRAY=$(ls "$FAKEHOME/.claude/" | grep -c '\.tmp$')
[ "$STRAY" -eq 0 ] && { PASS=$((PASS+1)); echo "PASS: no stray .tmp files left behind"; } || { FAIL=$((FAIL+1)); echo "FAIL: $STRAY stray .tmp files"; }

# ---- works on a fresh HOME with no state dir
NOHOME="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-nohome.XXXXXX")"
mkdir -p "$NOHOME/.claude" && touch "$NOHOME/.claude/task-gopher.enabled"
OUT=$(printf '%s' "$(payload "$DISPATCH_NOSENT" nh general-purpose)" | HOME="$NOHOME" node "$HOOK" 2>/dev/null); RC=$?
check "fresh HOME: dispatch still stamped" is_inject
rm -rf "$NOHOME"

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
if [ -f "$REAL_NUDGE" ] && [ "$REAL_NUDGE_PRE" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "FAIL: real state file was created by the tests!"
else
  PASS=$((PASS+1)); echo "PASS: real ~/.claude state untouched by tests"
fi

# ---- the retired bounce machinery is fully gone
grep -q 'RELAY_FILE\|relay-bounce\|relay-forgone\|RELAY_FORGO_AFTER' "$PLUGIN"/hooks/*.mjs \
  && { FAIL=$((FAIL+1)); echo "FAIL: dead relay-bounce machinery still referenced"; } \
  || { PASS=$((PASS+1)); echo "PASS: relay-bounce machinery fully removed"; }

# ---- so is the single-slot counter it replaced
grep -q 'readCounter\|writeCounter' "$PLUGIN"/hooks/*.mjs \
  && { FAIL=$((FAIL+1)); echo "FAIL: single-slot counter still referenced"; } \
  || { PASS=$((PASS+1)); echo "PASS: single-slot counter fully removed"; }

# ---- the directive must name the agent the way the harness resolves it:
# plugin agents are namespaced, and the bare name errors with "not found".
# A subagent has no agent roster until after its first tool call, so the
# directive text is its only source for the correct spelling.
grep -q 'task-gopher:task-gopher' "$PLUGIN/hooks/directive.mjs" \
  && { PASS=$((PASS+1)); echo "PASS: directive names the namespaced subagent_type"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: directive lacks the namespaced subagent_type"; }
grep -q 'subagent_type: "task-gopher")' "$PLUGIN/hooks/directive.mjs" \
  && { FAIL=$((FAIL+1)); echo "FAIL: directive still tells agents to use the bare name"; } \
  || { PASS=$((PASS+1)); echo "PASS: directive no longer uses the bare agent name"; }

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
