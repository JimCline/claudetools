#!/bin/bash
# agent-hierarchy handoff-flow tests: config resolution + directive rendering.
# HOME-redirected; real config never touched.
# Usage: bash tests/test-flow-mode.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-flow-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:140})"; fi
}

# eval_js <js-expression over {resolveConfig,buildDirective,statusReport} bound as L, cwd $PROJ>
eval_js() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('${LIB}');
    const r = L.resolveConfig('${PROJ}');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

user_cfg()    { printf '%s\n' "$1" > "$FAKEHOME/.claude/agent-hierarchy.json"; }
proj_cfg()    { printf '%s\n' "$1" > "$PROJ/.claude/agent-hierarchy.json"; }
clear_cfgs()  { rm -f "$FAKEHOME/.claude/agent-hierarchy.json" "$PROJ/.claude/agent-hierarchy.json"; }

BASE='"version":1,"enabled":true,"roles":{}'

# ---- default: auto, from nothing and from a config without the key
clear_cfgs
eval_js "r.handoffs + '|' + r.handoffsSource"
check "unconfigured -> auto/default" '[ "$OUT" = "auto|default" ]'

user_cfg "{$BASE}"
eval_js "r.handoffs + '|' + r.handoffsSource"
check "config without handoffs key -> auto/default" '[ "$OUT" = "auto|default" ]'

# ---- explicit values, both scopes, most-specific wins
user_cfg "{$BASE,\"handoffs\":\"confirm\"}"
eval_js "r.handoffs + '|' + r.handoffsSource"
check "user confirm -> confirm/user" '[ "$OUT" = "confirm|user" ]'

proj_cfg "{$BASE,\"handoffs\":\"auto\"}"
eval_js "r.handoffs + '|' + r.handoffsSource"
check "project auto overrides user confirm" '[ "$OUT" = "auto|project" ]'

# ---- invalid value: warning + fall back to auto
clear_cfgs
user_cfg "{$BASE,\"handoffs\":\"sometimes\"}"
eval_js "r.handoffs + '|' + (r.warnings.some(w=>w.includes('handoffs')) ? 'warned' : 'silent')"
check "invalid handoffs -> auto with a warning" '[ "$OUT" = "auto|warned" ]'

# ---- directive rendering: the gate appears ONLY in confirm mode
clear_cfgs
user_cfg "{$BASE,\"handoffs\":\"confirm\"}"
eval_js "L.buildDirective(r)"
check "confirm: directive carries the handoff gate (item 0)" 'printf "%s" "$OUT" | grep -q "0. Handoff gate"'
check "confirm: gate names AskUserQuestion" 'printf "%s" "$OUT" | grep -q "AskUserQuestion"'
check "confirm: legwork exempt" 'printf "%s" "$OUT" | grep -q "errands are not handoffs"'
check "confirm: flow-control item states current mode" 'printf "%s" "$OUT" | grep -q "handoffs are currently \"confirm\""'

user_cfg "{$BASE,\"handoffs\":\"auto\"}"
eval_js "L.buildDirective(r)"
check "auto: no handoff gate item" '! printf "%s" "$OUT" | grep -q "0. Handoff gate"'
check "auto: flow-control item states current mode" 'printf "%s" "$OUT" | grep -q "handoffs are currently \"auto\""'

# ---- the switch instruction is present in BOTH modes (user can flip anytime)
for mode in auto confirm; do
  user_cfg "{$BASE,\"handoffs\":\"$mode\"}"
  eval_js "L.buildDirective(r)"
  check "$mode: directive tells Orchestrator the user can flip at any time" 'printf "%s" "$OUT" | grep -q "AT ANY TIME"'
  check "$mode: switch updates config AND takes effect now" 'printf "%s" "$OUT" | grep -q "honor the new mode immediately"'
done

# ---- evidence loop: the Orchestrator polices role lanes, in BOTH modes
for mode in auto confirm; do
  user_cfg "{$BASE,\"handoffs\":\"$mode\"}"
  eval_js "L.buildDirective(r)"
  check "$mode: evidence-loop item present" 'printf "%s" "$OUT" | grep -q "11. Evidence loop"'
  check "$mode: NEEDS-EVIDENCE routing named" 'printf "%s" "$OUT" | grep -q "NEEDS-EVIDENCE"'
  check "$mode: overstep policing is the Orchestrator's job" 'printf "%s" "$OUT" | grep -q "route the work to the role that owns it"'
  check "$mode: Reviewer execution-delegation clause present" 'printf "%s" "$OUT" | grep -q "The Reviewer likewise reasons only"'
done

# ---- status report shows the flow line
user_cfg "{$BASE,\"handoffs\":\"confirm\"}"
OUT=$(cd "$PROJ" && HOME="$FAKEHOME" node "$LIB" 2>&1); RC=$?
check "status: handoff flow line present" 'printf "%s" "$OUT" | grep -q "handoff flow:   confirm"'

# ---- versions agree across plugin.json and marketplace.json
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='ah').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
