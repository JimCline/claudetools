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

# ---- hierarchy roles: each role's md already carries the delegation rule, so
# relaying it again pays for the same text twice.
for ROLE in ah:architect ah:implementor ah:orchestrator ah:reviewer ah:ultra-advisor ah:task-runner; do
  run_hook "$(payload "$DISPATCH_NOSENT" t2 "$ROLE")"
  check "on: $ROLE exempt from the relay" is_allow
  check "on: $ROLE not rewritten" "! printf '%s' \"\$OUT\" | grep -q 'updatedInput'"
done
check "hierarchy exemption logged as builtin" \
  "grep -q '\"event\":\"relay-skip\".*\"detail\":\"ah:reviewer\".*\"reason\":\"builtin\"' \"$FAKEHOME/.claude/task-gopher.log\""

# Sibling positive: the exemption must not have widened to everything.
run_hook "$(payload "$DISPATCH_NOSENT" t2 general-purpose)"
check "on: general-purpose still stamped (exemption is not over-broad)" is_inject

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

# ---- user-maintained exempt list (~/.claude/task-gopher.relay-exempt).
# Covers what the automatic check cannot see: an SDK-defined agent has no file
# on disk, so its tool list can never be read.
EXEMPT="$FAKEHOME/.claude/task-gopher.relay-exempt"
run_hook "$(payload "$DISPATCH_NOSENT" x0 sdk-only-agent)"
check "exempt: no exempt file -> stamped as before" is_inject

printf '# a comment\n\nsdk-only-agent\n' > "$EXEMPT"
run_hook "$(payload "$DISPATCH_NOSENT" x1 sdk-only-agent)"
check "exempt: listed subagent_type not stamped" is_allow
check "exempt: skip is logged with a reason" \
  "grep -q '\"event\":\"relay-skip\".*\"reason\":\"user-exempt\"' \"$FAKEHOME/.claude/task-gopher.log\""
run_hook "$(payload "$DISPATCH_NOSENT" x2 general-purpose)"
check "exempt: unlisted subagent_type still stamped" is_inject
run_hook "$(payload "$DISPATCH_NOSENT" x3 "# a comment")"
check "exempt: comment lines are not treated as entries" is_inject
printf 'trailing-space-agent   \n' > "$EXEMPT"
run_hook "$(payload "$DISPATCH_NOSENT" x4 trailing-space-agent)"
check "exempt: entries are trimmed" is_allow
rm -f "$EXEMPT"
run_hook "$(payload "$DISPATCH_NOSENT" x5 sdk-only-agent)"
check "exempt: removing the file restores stamping" is_inject

# ---- automatic skip: read the target agent's own `tools:` allow-list.
# Only an allow-list is decisive — `disallowedTools` is a deny-list and is never
# evidence that Agent is absent — and anything unresolvable must still be stamped.
AGENTS="$FAKEHOME/.claude/agents"
mkdir -p "$AGENTS"

printf -- '---\nname: toolless\ntools: Read, Grep, Glob\n---\n\nbody\n' > "$AGENTS/toolless.md"
run_hook "$(payload "$DISPATCH_NOSENT" y1 toolless)"
check "tools: allow-list without Agent/Task -> not stamped" is_allow
check "tools: skip logged as no-dispatch-tool" \
  "grep -q '\"event\":\"relay-skip\".*\"reason\":\"no-dispatch-tool\"' \"$FAKEHOME/.claude/task-gopher.log\""

printf -- '---\nname: folded\ntools: >-\n  Read,\n  Grep,\n  advisor\n---\n\nbody\n' > "$AGENTS/folded.md"
run_hook "$(payload "$DISPATCH_NOSENT" y2 folded)"
check "tools: folded block scalar (>-) parsed -> not stamped" is_allow

printf -- '---\nname: seq\ntools:\n  - Read\n  - Glob\n---\n\nbody\n' > "$AGENTS/seq.md"
run_hook "$(payload "$DISPATCH_NOSENT" y3 seq)"
check "tools: YAML block sequence parsed -> not stamped" is_allow

printf -- '---\nname: hasagent\ntools: Read, Agent, Glob\n---\n\nbody\n' > "$AGENTS/hasagent.md"
run_hook "$(payload "$DISPATCH_NOSENT" y4 hasagent)"
check "tools: allow-list WITH Agent -> stamped" is_inject

printf -- '---\nname: hastask\ntools: >-\n  Read,\n  Task\n---\n\nbody\n' > "$AGENTS/hastask.md"
run_hook "$(payload "$DISPATCH_NOSENT" y5 hastask)"
check "tools: allow-list with Task counts as dispatch-capable -> stamped" is_inject

printf -- '---\nname: notools\ndescription: inherits everything\n---\n\nbody\n' > "$AGENTS/notools.md"
run_hook "$(payload "$DISPATCH_NOSENT" y6 notools)"
check "tools: NO tools key -> inherits Agent -> stamped" is_inject

printf -- '---\nname: denylist\ndisallowedTools: Edit, Write, advisor\n---\n\nbody\n' > "$AGENTS/denylist.md"
run_hook "$(payload "$DISPATCH_NOSENT" y7 denylist)"
check "tools: disallowedTools is NOT evidence of absence -> stamped" is_inject

printf -- '---\nname: star\ntools: "*"\n---\n\nbody\n' > "$AGENTS/star.md"
run_hook "$(payload "$DISPATCH_NOSENT" y8 star)"
check "tools: wildcard allow-list -> stamped" is_inject

printf -- '---\nname: flow\ntools: [Read, Grep]\n---\n\nbody\n' > "$AGENTS/flow.md"
run_hook "$(payload "$DISPATCH_NOSENT" y9 flow)"
check "tools: YAML flow sequence parsed -> not stamped" is_allow

printf -- 'no frontmatter here, just prose\n' > "$AGENTS/nofm.md"
run_hook "$(payload "$DISPATCH_NOSENT" y10 nofm)"
check "tools: unparseable definition (no frontmatter) -> stamped" is_inject

run_hook "$(payload "$DISPATCH_NOSENT" y11 does-not-exist-anywhere)"
check "tools: unresolvable subagent_type -> stamped" is_inject

run_hook '{"tool_name":"Agent","prompt_id":"y12","tool_input":{"subagent_type":"../../../etc/passwd","prompt":"x"}}'
check "tools: path-traversal subagent_type resolves nothing -> stamped" is_inject

# a project-level agent is found via the payload's cwd
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ/.claude/agents"
printf -- '---\nname: projonly\ntools: Read, Grep\n---\n\nbody\n' > "$PROJ/.claude/agents/projonly.md"
run_hook "{\"tool_name\":\"Agent\",\"prompt_id\":\"y13\",\"cwd\":\"$PROJ\",\"tool_input\":{\"subagent_type\":\"projonly\",\"prompt\":\"x\"}}"
check "tools: project .claude/agents resolved from cwd -> not stamped" is_allow
run_hook "$(payload "$DISPATCH_NOSENT" y14 projonly)"
check "tools: same agent without cwd is unresolvable -> stamped" is_inject

# ---- plugin agents resolve through installed_plugins.json, which pins the
# installed version; a bare glob over the cache cannot, since several versions
# of one plugin sit there side by side.
mkdir -p "$FAKEHOME/.claude/plugins" "$SANDBOX/plugroot-a/agents" "$SANDBOX/plugroot-b/agents"
cat > "$FAKEHOME/.claude/plugins/installed_plugins.json" <<EOF
{"version":1,"plugins":{"fakeplug@mkt":[{"scope":"user","installPath":"$SANDBOX/plugroot-a"}]}}
EOF
printf -- '---\nname: assessor\ntools: >-\n  Read,\n  Grep,\n  Glob,\n  advisor\n---\n\nbody\n' \
  > "$SANDBOX/plugroot-a/agents/assessor.md"
printf -- '---\nname: worker\ntools: Read, Agent\n---\n\nbody\n' > "$SANDBOX/plugroot-a/agents/worker.md"

run_hook "$(payload "$DISPATCH_NOSENT" y15 fakeplug:assessor)"
check "plugin: namespaced tool-less agent -> not stamped" is_allow
run_hook "$(payload "$DISPATCH_NOSENT" y16 fakeplug:worker)"
check "plugin: namespaced dispatch-capable agent -> stamped" is_inject
run_hook "$(payload "$DISPATCH_NOSENT" y17 otherplug:assessor)"
check "plugin: unknown plugin name -> stamped" is_inject

# two installed copies that disagree means we don't actually know -> stamp
cat > "$FAKEHOME/.claude/plugins/installed_plugins.json" <<EOF
{"version":1,"plugins":{"fakeplug@mkt":[{"scope":"user","installPath":"$SANDBOX/plugroot-a"},{"scope":"project","installPath":"$SANDBOX/plugroot-b"}]}}
EOF
printf -- '---\nname: assessor\ntools: Read, Agent\n---\n\nbody\n' > "$SANDBOX/plugroot-b/agents/assessor.md"
run_hook "$(payload "$DISPATCH_NOSENT" y18 fakeplug:assessor)"
check "plugin: copies that disagree -> stamped (fail toward the relay)" is_inject

# a marketplace served from a local checkout is edited in place, so its agents
# live under the checkout rather than the versioned cache copy
rm -f "$FAKEHOME/.claude/plugins/installed_plugins.json"
mkdir -p "$SANDBOX/checkout/localplug/agents"
cat > "$FAKEHOME/.claude/plugins/known_marketplaces.json" <<EOF
{"mkt":{"source":{"source":"directory"},"installLocation":"$SANDBOX/checkout"}}
EOF
printf -- '---\nname: scout\ntools: Read, Grep\n---\n\nbody\n' > "$SANDBOX/checkout/localplug/agents/scout.md"
run_hook "$(payload "$DISPATCH_NOSENT" y19 localplug:scout)"
check "plugin: local-checkout marketplace resolved -> not stamped" is_allow
rm -f "$FAKEHOME/.claude/plugins/known_marketplaces.json"

# a malformed registry must not break the gate
printf 'not json' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
run_hook "$(payload "$DISPATCH_NOSENT" y20 fakeplug:assessor)"
check "plugin: unparseable installed_plugins.json -> stamped, gate survives" is_inject
rm -f "$FAKEHOME/.claude/plugins/installed_plugins.json"

# dispatches to the gopher itself outrank every skip path
printf 'task-gopher:task-gopher\n' > "$EXEMPT"
run_hook "$(payload "$DISPATCH_NOSENT" y21 task-gopher:task-gopher)"
check "exempt: gopher dispatch still resets the streak, not skipped as exempt" \
  "is_allow && grep -q '\"event\":\"dispatch\"' \"$FAKEHOME/.claude/task-gopher.log\""
rm -f "$EXEMPT"

rm -rf "$AGENTS"

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

# ---- the directive's claim about what the relay skips must be backed by code.
# It promised a tool-less skip to every agent that read it, for several versions
# before one existed; that sentence is the most-read text the plugin ships.
grep -q 'no Agent/Task tool' "$PLUGIN/hooks/directive.mjs" \
  && grep -q 'cannotDispatch' "$PLUGIN/hooks/pretooluse-nudge.mjs" \
  && { PASS=$((PASS+1)); echo "PASS: directive's skip claim is backed by the gate"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: directive claims a skip the gate does not implement"; }

# ---- the retired manual-copy instruction must not survive in the command doc
grep -q 'copy the full \[task-gopher: ON\] directive block verbatim' "$PLUGIN/commands/task-gopher.md" \
  && { FAIL=$((FAIL+1)); echo "FAIL: command doc still tells agents to hand-copy the directive"; } \
  || { PASS=$((PASS+1)); echo "PASS: command doc describes the automatic relay"; }

# ---- smart-gopher: dispatches to it are never stamped, and the guard's naming
# trap (task-gopher:smart-gopher contains BOTH "smart-gopher" and "task-gopher")
# must resolve to smart-gopher, most-specific-first.
run_hook "$(payload "$DISPATCH_NOSENT" s1 task-gopher:smart-gopher)"
check "R1: dispatch to smart-gopher never stamped" is_allow
check "R2: dispatch logged as event dispatch" "grep -q '\"event\":\"dispatch\"' \"$FAKEHOME/.claude/task-gopher.log\""
check "R2: dispatch logged with agent smart-gopher" "grep -q '\"agent\":\"smart-gopher\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(payload "$DISPATCH_NOSENT" s2 smart-gopher)"
check "R3: bare unnamespaced smart-gopher not stamped" is_allow

# ---- R4: dispatch to smart-gopher resets the strict streak (mirrors the t4 sequence)
READ_P4='{"tool_name":"Read","prompt_id":"t4b","tool_input":{"file_path":"/x"}}'
run_hook "$READ_P4"
check "R4: strict turn-start checkpoint" is_deny
run_hook "$READ_P4"
run_hook "$(payload "$DISPATCH_NOSENT" t4b task-gopher:smart-gopher)"
check "R4: dispatch to smart-gopher allowed" is_allow
run_hook "$READ_P4"
check "R4: dispatch to smart-gopher reset the streak (Read allowed, no escalate)" is_allow

# ---- R5: smart-gopher's own tool use is never checkpointed
INSIDE_SMART='{"tool_name":"Read","prompt_id":"t4b","agent_type":"task-gopher:smart-gopher","tool_input":{"file_path":"/x"}}'
run_hook "$INSIDE_SMART"
check "R5: inside smart-gopher, Read never checkpointed" is_allow

# ---- R6/R7: unrelated names still get stamped; the match is not *gopher*-loose
run_hook "$(payload "$DISPATCH_NOSENT" s3 general-purpose)"
check "R6: general-purpose still stamped" is_inject
run_hook "$(payload "$DISPATCH_NOSENT" s4 smartish-helper)"
check "R7: smartish-helper (unrelated name) still stamped" is_inject

# ---- R8: dispatch TO task-gopher itself still logs the right agent kind
run_hook "$(payload "$DISPATCH_NOSENT" s5 task-gopher:task-gopher)"
check "R8: dispatch to task-gopher never stamped" is_allow
check "R8: dispatch logged with agent task-gopher" "grep -q '\"agent\":\"task-gopher\"' \"$FAKEHOME/.claude/task-gopher.log\""

# ---- SMART-GOPHER GATE: least-privilege-first, enforced not just advised.
# DISPATCH_NOSENT carries no session_id, so R1-R8 above never had one to scope
# against — the gate must stay invisible to them (fails open, no session_id).
smart_dispatch() { # <prompt_id> <session_id> <prompt-text>
  printf '{"tool_name":"Agent","prompt_id":"%s","session_id":"%s","tool_input":{"subagent_type":"task-gopher:smart-gopher","prompt":"%s"}}' "$1" "$2" "$3"
}
task_dispatch() { # <prompt_id> <session_id>
  printf '{"tool_name":"Agent","prompt_id":"%s","session_id":"%s","tool_input":{"subagent_type":"task-gopher:task-gopher","prompt":"x"}}' "$1" "$2"
}

run_hook "$(smart_dispatch g1 sGATE "investigate which of three parsers is live")"
check "G1: first smart-gopher dispatch this session -> checkpoint deny" is_deny
check "G1: nudge names task-gopher" "printf '%s' \"\$OUT\" | grep -q 'task-gopher'"
check "G1: nudge previews the prompt" "printf '%s' \"\$OUT\" | grep -q 'investigate which of three parsers'"
check "G1: checkpoint logged" "grep -q '\"event\":\"smart-gate-checkpoint\"' \"$FAKEHOME/.claude/task-gopher.log\""
check "G1: no dispatch-event logged for the denied attempt" \
  "! tail -1 \"$FAKEHOME/.claude/task-gopher.log\" | grep -q '\"event\":\"dispatch\"'"

run_hook "$(smart_dispatch g1 sGATE "investigate which of three parsers is live")"
check "G2: identical retry -> allowed" is_allow
check "G2: retry logged as a normal dispatch" "grep -q '\"event\":\"dispatch\".*\"agent\":\"smart-gopher\"' \"$FAKEHOME/.claude/task-gopher.log\""

run_hook "$(smart_dispatch g2 sGATE "a completely different smart-gopher task")"
check "G3: a DIFFERENT smart-gopher prompt, same session -> its own fresh checkpoint" is_deny
run_hook "$(smart_dispatch g2 sGATE "a completely different smart-gopher task")"
check "G3b: that exact prompt's retry -> allowed" is_allow
run_hook "$(smart_dispatch g1 sGATE "investigate which of three parsers is live")"
check "G3c: the FIRST prompt (already passed) still goes straight through after a different one fired" is_allow

run_hook "$(smart_dispatch g3 sGATE-OTHER "first smart-gopher dispatch of a fresh session")"
check "G4: a different session's first smart-gopher dispatch -> its own checkpoint" is_deny
run_hook "$(smart_dispatch g3 sGATE-OTHER "first smart-gopher dispatch of a fresh session")"
check "G4b: that session's retry -> allowed" is_allow
run_hook "$(smart_dispatch g6 sGATE "investigate which of three parsers is live")"
check "G4c: the exact prompt from G1, but a DIFFERENT prompt_id, same session -> no re-fire (keyed on prompt text, not prompt_id)" is_allow

run_hook "$(task_dispatch g4 sGATE-TG)"
check "G5: task-gopher dispatch, brand-new session, never gated" is_allow

run_hook "$(payload "$DISPATCH_NOSENT" g5 task-gopher:smart-gopher)"
check "G6: smart-gopher dispatch with no session_id fails open (can't scope -> allow)" is_allow

# ---- V: verbatim-read gate (spec 0001). Hard deny, every time — a hit cannot
# be re-issued past, so these must never depend on session or prompt state.
vdispatch() { # <prompt-id> <subagent_type> <prompt>
  node -e 'const[p,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({tool_name:"Agent",prompt_id:p,session_id:"sV",tool_input:{subagent_type:t,prompt:m}}));' "$1" "$2" "$3"
}
vrun() { OUT=$(vdispatch "$1" "$2" "$3" | HOME="$FAKEHOME" node "$HOOK" 2>/dev/null); RC=$?; }
vcount() { grep -c '"event":"verbatim-deny"' "$FAKEHOME/.claude/task-gopher.log"; }

WHOLE="Return the full contents of hooks/x.mjs"

# 1 — whole-file order to task-gopher
vrun v1 task-gopher:task-gopher "$WHOLE"
check "V1: whole-file order -> deny" is_deny
check "V1: reason names the direct Read remedy" "printf '%s' \"\$OUT\" | grep -q 'Read('"
check "V1: reason says it will not be allowed as written" "printf '%s' \"\$OUT\" | grep -q 'will not be allowed as written'"
check "V1: reason does NOT say re-issue" "! printf '%s' \"\$OUT\" | grep -q 're-issue'"
check "V1: reason quotes the matched text" "printf '%s' \"\$OUT\" | grep -q 'full contents'"
check "V1: one verbatim-deny logged" '[ "$(vcount)" -eq 1 ]'

# 2 — same prompt, same session: still denied (no one-shot key)
vrun v1 task-gopher:task-gopher "$WHOLE"
check "V2: identical prompt again, same session -> still deny" is_deny
check "V2: a second verbatim-deny logged" '[ "$(vcount)" -eq 2 ]'

# 3 — negation
vrun v3 task-gopher:task-gopher "Do NOT return the whole file; grep -n TODO hooks/x.mjs and report file:line"
check "V3: negated whole-file phrase -> allow" is_allow

# 4 — "verbatim" alone is never the trigger
vrun v4 task-gopher:task-gopher "report every FAIL line verbatim from /tmp/suite.log"
check "V4: 'verbatim' alone -> allow" is_allow

# 5 — small range allowed, large range denied
vrun v5 task-gopher:task-gopher "sed -n '10,40p' hooks/x.mjs, verbatim"
check "V5: sed 10,40p -> allow" is_allow
vrun v5b task-gopher:task-gopher "sed -n '1,400p' hooks/x.mjs"
check "V5: sed 1,400p -> deny" is_deny

# 6 — line-range prose and head
vrun v6 task-gopher:task-gopher "quote lines 95-190 of tests/t.sh"
check "V6: lines 95-190 (96 lines) -> deny" is_deny
vrun v6b task-gopher:task-gopher "quote lines 130-150 of tests/t.sh"
check "V6: lines 130-150 (21 lines) -> allow" is_allow
vrun v6c task-gopher:task-gopher "head -150 hooks/x.mjs"
check "V6: head -150 on a path -> deny" is_deny
vrun v6d task-gopher:task-gopher "head -150"
check "V6: head -150 with no path token -> allow" is_allow

# 7 — smart-gopher: verbatim runs FIRST, so the smart gate never fires
SMART_BEFORE=$(grep -c '"event":"smart-gate-checkpoint"' "$FAKEHOME/.claude/task-gopher.log")
vrun v7 task-gopher:smart-gopher "$WHOLE"
check "V7: smart-gopher whole-file order -> deny" is_deny
check "V7: denial is the verbatim gate, not the smart gate" "printf '%s' \"\$OUT\" | grep -q 'will not be allowed as written'"
check "V7: no smart-gate-checkpoint logged" '[ "$(grep -c "\"event\":\"smart-gate-checkpoint\"" "$FAKEHOME/.claude/task-gopher.log")" -eq "$SMART_BEFORE" ]'

# 8 — non-gopher targets are untouched: the relay path still stamps them
vrun v8 general-purpose "$WHOLE"
check "V8: general-purpose whole-file order -> not denied, still stamped" is_inject

# 9 — plugin OFF: no gate at all
mv "$FAKEHOME/.claude/task-gopher.enabled" "$FAKEHOME/.claude/task-gopher.enabled.off"
vrun v9 task-gopher:task-gopher "$WHOLE"
check "V9: plugin OFF -> allow" is_allow
mv "$FAKEHOME/.claude/task-gopher.enabled.off" "$FAKEHOME/.claude/task-gopher.enabled"

# 10 — the predicate itself, so a later tuner cannot quietly break a rule.
# Written to a file rather than `node -e`: the example strings contain both
# quote characters.
cat > "$SANDBOX/pred.mjs" <<'PREDEOF'
import { verbatimReadHit } from "PLUGIN_DIR/hooks/directive.mjs";
const cases = [
  ["Return the full contents of hooks/x.mjs", "H1"],
  ["Full content of hooks/sessionend-roster.mjs", "H1"],
  ["full contents of `hooks/x.mjs`", "H1"],
  ["the complete, exact contents of hooks/x.mjs", "H1"],
  ["Return the FULL, VERBATIM content of these files:\n- hooks/a.mjs\n- hooks/b.mjs", "H1"],
  ["hooks/x.mjs in full", "H1"],
  ["tests/t.sh — full contents", "H1"],
  ["Now return the whole file hooks/x.mjs", "H1"],
  ["Read the whole file hooks/x.mjs and report it verbatim", "H1"],
  ["read the whole file and report back", "H2"],
  ["dump it in its entirety", "H2"],
  ["sed -n '1,400p' hooks/x.mjs", "H3"],
  ["head -80 hooks/x.mjs", "H3"],
  ["head -n 80 hooks/x.mjs", "H3"],
  ["tail -n 300 /tmp/x.log", "H3"],
  ["quote lines 95-190 of tests/t.sh", "H3"],
  ["Read(hooks/x.mjs, offset 1, limit 200)", "H3"],
  ["full contents of the tests/ directory (just filenames)", null],
  ["full text of the section beginning ## Scope in docs/a.md", null],
  ["full source of `roleForPeerName` in hooks/x.mjs", null],
  ["full text of every FAIL line in /tmp/suite.log", null],
  ["return the full file if under 500 lines", null],
  ["give the full file listing of docs/", null],
  ["Run the full suite, one file at a time on tests/t.sh", null],
  ["full contents of v0.16.0", null],
  ["head -150", null],
  ["lines 95-190", null],
  ["head -79 hooks/x.mjs", null],
  ["head -80 hooks/x.mjs | grep x", null],
  ["sed -n '1,79p' hooks/x.mjs", null],
  ["sed -n '1,80p' hooks/x.mjs > /tmp/o", null],
  ["grep -n TODO src/ | head -100", null],
  ["tail -n 300 /tmp/x.log > /tmp/t; wc -l /tmp/t", null],
  ["Read(hooks/x.mjs, offset 1, limit 60)", null],
  ["Read hooks/x.mjs.\n\nThen return the full file.", null],
  ["full contents, cleaned up, of hooks/x.mjs", null],
  ["Read hooks/x.mjs and return the full file contents", null],
  ["grep -n TODO hooks/x.mjs and report file:line", null],
  ["summarise hooks/x.mjs in 10 lines", null],
  ["list the exported names in hooks/directive.mjs", null],
  ["don't dump the whole file hooks/x.mjs unless it is under 40 lines", null],
  ["Do NOT print full log contents of /tmp/x.log", null],
  ["report every FAIL line verbatim from /tmp/suite.log", null],
  ["cat /tmp/summary.txt", null],
];
let bad = 0;
for (const [text, want] of cases) {
  const hit = verbatimReadHit(text);
  const got = hit ? hit.rule : null;
  if (got !== want) { bad++; console.error("want " + want + " got " + got + " <- " + text); }
}

// 15 — r8 recall fixtures: the 13 labelled TPs from the E1 round-2 sheet,
// verbatim. The five nulls are ACCEPTED MISSES (known-FN-direction) and their
// count is the complement of E1 #2's recall numerator. Do not "fix" them.
const tp13 = [
  [2, "Repo: /Users/jimcline/git/repos/claudetools (read-only, do not modify anything).\n\nReport these 3 items verbatim, each under its own heading. No summarizing/paraphrasing.\n\n1. In agent-hierarchy/hooks/subagentstop-usage.mjs: find how it derives the subagent's own transcript path (look for `agent_transcript_path`, `subagents`, a `join(...)` building a per-agent transcript path, or similar). Quote the exact code (file:line + the function/expression body).\n\n2. In agent-hierarchy/README.md: run `grep -n \"Verified payloads\" agent-hierarchy/README.md`, then report the full bullet list under that heading verbatim (with line numbers).\n\n3. Full content of agent-hierarchy/hooks/sessionend-roster.mjs, verbatim, with line numbers (it's a new small file, ~40-60 lines).\n\nIf any item isn't found, say \"not found\" for it.", "H1"],
  [10, "Four retrievals, report each verbatim and labeled 1-4 with line numbers. Exact literal text needed — no paraphrasing, this is for a precise code edit.\n\n1. Read /Users/jimcline/git/repos/claudetools/agent-hierarchy/docs/specs/0009-global-roster-confirm-gate.md lines 380-420 (the amendment (f) / §6.4 CLI-text discussion) and lines 890-910 (the §6.4 CLI-side requireAllowGlobal text requirement) and lines 985-1010 (the new §13 section, if it exists in that range — if §13 starts elsewhere in the file, grep for \"^## §13\" or \"^### §13\" or \"§13\" as a section heading first and read the whole section). Quote the EXACT literal CLI error-message text §6.4 specifies for requireAllowGlobal (word for word, including any placeholder like <verb> or ${verb}), and the exact text of §13's task list.\n\n2. Read /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/roster.mjs lines 480-495 (the `requireAllowGlobal` function). Report its exact current literal source with line numbers.\n\n3. Grep /Users/jimcline/git/repos/claudetools/agent-hierarchy/tests/test-roster-spawn-one.sh for \"declined\" and \"allow-global\" and \"requireAllowGlobal\" (case-insensitive) and report each matching line with line number and its surrounding 2 lines of context (the check() blocks that assert on requireAllowGlobal's message), so I can see the current assertion text to update.\n\n4. Read /Users/jimcline/git/repos/claudetools/agent-hierarchy/.claude/hierarchy/msgs/20260823-140500-2af7--orchestrator--spec-defect-cleanup--response.md if it exists (try that exact path; if not found, also try /Users/jimcline/git/repos/claudetools/.claude/hierarchy/msgs/ with the same filename). Report its full content, especially any section discussing §6.4's exact wording or the requireAllowGlobal string.\n\nReturn everything verbatim.", null],
  [18, "Repo: /Users/jimcline/git/repos/claudetools/agent-hierarchy\n\nI'm about to WRITE a brand-new bash test file at tests/test-roster-multi-team.sh, modeled on the existing test files' conventions. I need exact, verbatim detail — quote real lines, don't paraphrase — on:\n\n1. How tests are run overall: find any run-all-tests entrypoint (e.g. a `run-tests.sh`, a Makefile target, or a package.json script, or a README section) at or near /Users/jimcline/git/repos/claudetools/agent-hierarchy/ — the exact command used to run the whole suite, and whether individual test files are just `bash tests/test-foo.sh` runnable standalone.\n\n2. The FULL verbatim content of tests/test-team-alias.sh — every line, no summarizing. I need its shell helper functions (things like `evalc`, `check`, `OUT`, `run_roster`, temp-dir setup/teardown, `PASS`/`FAIL` counting, how it invokes `node .../hooks/roster.mjs ...`) so I can write a new file using the exact same helpers and conventions.\n\n3. The FULL verbatim content of tests/test-roster.sh, specifically lines 1-110 (I need its setup boilerplate and its existing peer-role-resolution test block).\n\n4. Just the shell helper-function definitions (not full body) from tests/test-team-registry.sh and tests/test-team-stale.sh — how they create/read team.json fixtures for tests (e.g. a helper that writes a team.json file with orchestrator pid, members, etc).\n\nReport back: (a) the exact run-all-tests command, (b) test-team-alias.sh's full content verbatim, (c) test-roster.sh lines 1-110 verbatim, (d) team.json fixture-writing helper snippets from the other two files. Do not summarize or paraphrase code — quote it exactly, since I'm going to copy conventions from it byte-for-byte.", "H1"],
  [30, "File: /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/roster.mjs\n\nIn the \"spawn-one\" CLI subcommand's implementation (the function/block that builds a variable named `newRecord`, currently containing a line like `if (launched.label) newRecord.label = launched.label;`), find and report:\n\n1. The exact line number and full text of the `newRecord` object literal declaration.\n2. The exact line number and full text of the line `if (launched.label) newRecord.label = launched.label;` (or whatever it currently reads).\n3. The exact line number and text of every subsequent line in this same spawn-one block, up to and including wherever `newRecord` (or a team object containing it) is written to disk (e.g. a call to `writeTeam(...)` or similar) — I need to see how `newRecord` flows from creation to persistence.\n4. The exact line number and text of wherever this same spawn-one block constructs/prints its CLI output/result (e.g. a `result = {...}` or `console.log(JSON.stringify(...))` or `process.stdout.write` call) — I need to see whether it reuses `newRecord` directly for output or builds a separate output object.\n\nReport back with line numbers and verbatim code for items 1-4, roughly lines 1140-1220 of the file should cover it but confirm actual range. Do not summarize or interpret — just quote the exact lines with numbers.", null],
  [38, "WHERE: repo at /Users/jimcline/git/repos/claudetools/agent-hierarchy (current checkout on branch main, no need to change branch).\n\nHOW: Run exactly these steps:\n1. `cat -n /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/pretooluse-route-gate.mjs`\n2. `grep -n \"peerConfirmationParagraph\\|PEER_ELIGIBLE_ROLES\\|prefer-peers\\|route\" -r /Users/jimcline/git/repos/claudetools/agent-hierarchy/lib-config.mjs`\n3. `cat -n /Users/jimcline/git/repos/claudetools/agent-hierarchy/lib-config.mjs`\n4. `sed -n '1,200p' /Users/jimcline/git/repos/claudetools/agent-hierarchy/docs/comms-protocol.md`\n\nWHAT BACK: Return the FULL verbatim output of all four commands, with line numbers preserved (do not summarize, truncate, or omit any lines) — I need the complete file contents of pretooluse-route-gate.mjs and lib-config.mjs, plus the first 200 lines of docs/comms-protocol.md, to edit them directly. If any file is very large (over ~500 lines), still return it in full — do not truncate.\n\nWHAT IF: If any file/path doesn't exist, report the exact error and stop — do not guess an alternate path.", "H3"],
  [42, "Repo: /Users/jimcline/git/repos/claudetools/agent-hierarchy\n\nRun this exact command from that directory:\nfor f in tests/test-*.sh; do echo \"=== $f ===\"; bash \"$f\" > /tmp/th-$(basename \"$f\").log 2>&1; echo \"exit=$?\"; tail -3 /tmp/th-$(basename \"$f\").log; done\n\nReport back, for EVERY test file found: its filename, its exit code, and its last-line summary (the \"passed: N failed: N\" or similar line). If any file has a non-zero exit code, additionally show the full contents of its log file. Report every file — do not sample or summarize away any of them; there should be around 19-20 files.", null],
  [46, "Repo: /Users/jimcline/git/repos/claudetools, branch main. Read-only. Do not modify anything.\n\nThree narrow retrievals. Report compactly, file:line + short quote. Every match, not first-N.\n\nTASK A — find every place that tells an agent (in prose/instructions) to invoke a script via node. Run from the repo root:\n  grep -rn \"msg\\.mjs\\|roster\\.mjs\\|gate\\.mjs\" --include=*.md --include=*.json --include=*.mjs --include=*.js --include=*.sh . | grep -v node_modules\nReport each hit as: path:line, and a <=100 char quote. Group hits into two buckets: (1) instructional text intended for an LLM to read (agent .md files, SKILL.md, hook-injected strings, README), (2) actual code invoking or importing the script. Say which bucket each is in.\n\nTASK B — report the structure of the agent-hierarchy plugin:\n  ls -la /Users/jimcline/git/repos/claudetools/agent-hierarchy\n  cat /Users/jimcline/git/repos/claudetools/agent-hierarchy/.claude-plugin/plugin.json\nReport the top-level file/dir listing and the full contents of plugin.json.\n\nTASK C — does any plugin in this repo already ship an MCP server? Run:\n  grep -rln \"mcpServers\\|\\.mcp\\.json\" --include=*.json --include=*.md /Users/jimcline/git/repos/claudetools | grep -v node_modules\n  find /Users/jimcline/git/repos/claudetools -name \".mcp.json\" -not -path \"*/node_modules/*\"\nFor any .mcp.json found, cat it. Also report whether any plugin.json in this repo has an \"mcpServers\" key, and if so quote it.\n\nOn any failure: report the error and stop.", "H1"],
  [66, "Working directory: /Users/jimcline/git/repos/claudetools/agent-hierarchy\n\nRun this exact command:\nfor f in tests/*.sh; do bash \"$f\" > /tmp/rh-$(basename \"$f\").log 2>&1; echo \"$f exit=$?\"; done > /tmp/rh-summary.log 2>&1; cat /tmp/rh-summary.log\n\nThen run: grep -c \"^PASS:\" /tmp/rh-test-roster-team-override.sh.log; grep -c \"^FAIL:\" /tmp/rh-test-roster-team-override.sh.log; grep \"^FAIL:\" /tmp/rh-test-roster-team-override.sh.log\n\nReport back:\n1. The full contents of /tmp/rh-summary.log (one line per test file with its exit code) — verbatim.\n2. For any file whose exit code was non-zero: grep \"FAIL:\" from that file's log (e.g. /tmp/rh-<basename>.log) and report those FAIL lines verbatim, plus the last 30 lines of that log.\n3. The T18a/T18b/T18c and T19a/T19b/T19c PASS/FAIL lines specifically from /tmp/rh-test-roster-team-override.sh.log (grep -n \"T18\\|T19\" on that log).\n4. Total pass/fail counts if the test files print a summary line like \"passed: X failed: Y\" — sum them if reported per-file, or just report each file's own summary line.\n\nDo not fix anything, do not interpret — just run and report the raw results as specified.", "H1"],
  [74, "WHERE: /Users/jimcline/git/repos/claudetools/agent-hierarchy (branch main, current worktree).\n\nHOW + WHAT BACK — run exactly these and report each result under its own heading. Do not summarize or interpret; report raw output (trimmed as specified).\n\n1. `grep -n 'case \"' hooks/roster.mjs` — the full list, every match, with line numbers. This is the command dispatch table.\n\n2. `grep -n 'function \\|const .* = async\\|^async function' hooks/roster.mjs | head -80` — first 80 matches.\n\n3. `sed -n '1,40p' hooks/roster.mjs` — the usage header verbatim.\n\n4. `grep -rn 'no-spawn\\|no_spawn\\|noSpawn' hooks/ mcp/ skills/ commands/ CONTEXT.md` — every match with line numbers (exclude tests/ dir).\n\n5. `grep -rln 'no-spawn\\|no_spawn' tests/` then `grep -rc 'no-spawn\\|no_spawn' tests/ | grep -v ':0'` — list of test files and per-file counts.\n\n6. `grep -n 'roster_' mcp/server.mjs | head -60` — first 60 matches with line numbers.\n\n7. `ls tests/` — full listing.\n\n8. `grep -rn 'team\\.json' tests/ | head -40` — first 40 matches with line numbers.\n\n9. `sed -n '1,60p' CONTEXT.md` — verbatim.\n\n10. `cat commands/agent-roster.md` — verbatim.\n\n11. `sed -n '1,80p' hooks/pretooluse-roster-skill-gate.mjs` — verbatim.\n\nWHAT IF: if any command errors or returns nothing, say so under that heading and continue to the next. Do not substitute a different command. Report and stop only if the directory does not exist.", "H3"],
  [78, "Work in /Users/jimcline/git/repos/claudetools/agent-hierarchy. Read-only — do NOT edit any file.\n\n1. Run every test suite: `for f in tests/test-*.sh; do echo \"=== $f\"; bash \"$f\" >/tmp/one.log 2>&1; echo \"exit=$? $(tail -1 /tmp/one.log)\"; done > /tmp/tg-all2.log 2>&1; echo done`\n2. Report the full contents of /tmp/tg-all2.log (it is short — one `===` line and one `exit=` line per suite).\n3. Report every line from `grep -nE 'exit=[1-9]|failed: [1-9]' /tmp/tg-all2.log` (or \"none\").\n4. Run `node --check hooks/roster.mjs; echo \"r=$?\"` and `node --check hooks/lib-roster.mjs; echo \"l=$?\"` and `node --check mcp/server.mjs; echo \"m=$?\"` — report the three exit codes.\n5. Report the output of `grep -n '\"version\"' .claude-plugin/plugin.json ../.claude-plugin/marketplace.json`.\n\nIf a step fails, report that and continue. Report and stop; change nothing.", "H1"],
  [82, "Repo: /Users/jimcline/git/repos/claudetools. Read-only, do NOT edit. Run each step, report verbatim under numbered headings. Report every match, not a sample.\n\n1. Run: grep -n 'openExchanges\\|open\\b\\|msgs\\|exchange' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/sessionstart.mjs\n   Report every match verbatim with line numbers. Then run: cat /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/sessionstart.mjs and report the FULL file verbatim.\n\n2. Run: grep -rn 'compact' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/hooks.json\n   Report verbatim. Then run: cat /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/hooks.json and report the FULL file verbatim.\n\n3. Run: grep -n -B3 -A20 'export function openExchanges' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/lib-hier.mjs\n   Report verbatim.\n\n4. Run: grep -rn 'openExchanges' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/ /Users/jimcline/git/repos/claudetools/agent-hierarchy/mcp/\n   Report every match verbatim with line numbers.\n\n5. Run: git -C /Users/jimcline/git/repos/claudetools status --porcelain\n   Report verbatim.\n\n6. Run: wc -l /Users/jimcline/git/repos/claudetools/agent-hierarchy/skills/autonomous-pipeline/SKILL.md /Users/jimcline/git/repos/claudetools/agent-hierarchy/commands/pipeline.md\n   Report verbatim.\n\n7. Run: grep -n 'slug' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/lib-hier.mjs | head -20\n   Report verbatim.\n\n8. Run: grep -n -B2 -A15 'REQUEST_KEYS\\|RESPONSE_KEYS' /Users/jimcline/git/repos/claudetools/agent-hierarchy/hooks/lib-hier.mjs | head -40\n   Report verbatim.\n\nOn any command failure: report the exact error text and continue. Do not guess or fill gaps.", null],
  [86, "Repo: /Users/jimcline/git/repos/claudetools (branch main). Read-only retrieval, three items. Report compactly, no commentary.\n\n1. From /Users/jimcline/git/repos/claudetools/agent-hierarchy/.claude-plugin/plugin.json — print the ENTIRE file verbatim (it is small).\n\n2. From /Users/jimcline/git/repos/claudetools/.claude-plugin/marketplace.json — print verbatim ONLY the plugin entry whose name/source is \"agent-hierarchy\" or \"ah\" (whichever matches), including its full `mcpServers` block if present. If there are multiple matching entries, print all of them. Also print the top-level keys of the file (just the key names).\n\n3. From /Users/jimcline/git/repos/claudetools/agent-hierarchy/mcp/server.mjs — print verbatim the first 60 lines, AND print every line matching (with line numbers) any of: `process.exit`, `readFileSync`, `existsSync`, `mkdir`, `version`, `require(`, `await import`, `process.env`. Use grep -nE for that. Do NOT print the whole file.\n\nAlso report: total line count of server.mjs, and whether the file /Users/jimcline/git/repos/claudetools/agent-hierarchy/mcp/ contains any other files (ls -la of that directory).\n\nOn any failure (file missing, unreadable): say exactly which file and stop.", null],
  [98, "Repo: /Users/jimcline/git/repos/claudetools. Read-only retrieval; run no tests, change nothing. Report each item under a numbered heading, with file:line refs. If a line range looks wrong (function not there), grep for the symbol and report the true location instead of guessing.\n\n1. Print verbatim with line numbers: agent-hierarchy/hooks/roster.mjs lines 1600-1760 (disband variants) and 1744-1910 (dismiss variants). If those overlap, print 1600-1910 once.\n2. In agent-hierarchy/hooks/roster.mjs, find the function(s) that actually close a peer's pane/session (grep for: herdrCall, kill-pane, closePane, close, transportId). Print each such function definition verbatim with line numbers (cap: 120 lines total for this item; if longer, print signatures + the close-relevant bodies).\n3. Print verbatim with line numbers: agent-hierarchy/hooks/lib-hier.mjs lines 715-800 (the roster() enumerator). Also grep lib-hier.mjs and roster.mjs for `peers.jsonl` and `latestRoster` — report every write site and the exact fields written to a peers.jsonl record (quote the object literal(s)).\n4. Report how a peer slot record is marked dead/closed: grep roster.mjs + lib-hier.mjs for status values written to peers.jsonl or slot records (e.g. 'closed', 'ended', 'dead', appendSlot, appendPeer). Quote the relevant lines.\n5. Print verbatim: agent-hierarchy/mcp/server.mjs tool definitions and handlers for roster_disband, roster_disband_close, roster_dismiss, roster_dismiss_close (grep to locate; print each block with line numbers).\n6. In agent-hierarchy/hooks/msg.mjs, report the list of valid message `type` values (grep for type validation/enum). Quote the line(s).\n7. Grep agent-hierarchy/hooks/roster.mjs for `readTeam` — print the function definition and every call site line.\n8. List which test files cover disband/dismiss: ls agent-hierarchy/tests/ | grep -iE 'disband|dismiss' and report names only.\n\nOn any failure (file missing, grep empty): report which item failed and stop that item, continue the rest.", "H3"],
];
let tpbad = 0;
let denied = 0;
for (const [n, text, want] of tp13) {
  const hit = verbatimReadHit(text);
  const got = hit ? hit.rule : null;
  if (got !== want) { tpbad++; console.error("TP#" + n + " want " + want + " got " + got); }
  if (got) denied++;
}
if (denied !== 8) { tpbad++; console.error("recall numerator " + denied + ", expected 8"); }

process.stdout.write(String(bad + tpbad));
PREDEOF
sed -i.bak "s|PLUGIN_DIR|$PLUGIN|" "$SANDBOX/pred.mjs"
PRED=$(node "$SANDBOX/pred.mjs" 2>/dev/null)
# 17 — r9: each string is a measured shape from the r8 FP sheet.
vrun v17a task-gopher:task-gopher "report the first 30 lines of /tmp/ah-wt-roster.log verbatim"
check "V17a: bounded excerpt said verbatim -> allow" is_allow
vrun v17b task-gopher:task-gopher "run this exact script and report its full stdout/stderr verbatim"
check "V17b: script output, not a file -> allow" is_allow
vrun v17c task-gopher:task-gopher "hooks/x.mjs in full"
check "V17c: terminal qualifier after a path -> deny" is_deny
vrun v17d task-gopher:task-gopher "hooks/x.mjs (full file)"
check "V17d: parenthesised terminal qualifier -> deny" is_deny
vrun v17e task-gopher:task-gopher 'From hooks/lib-hier.mjs: the full source of the `roster(dir)` function'
check "V17e: mirror rejects a trailing 'of' -> allow" is_allow
vrun v17f task-gopher:task-gopher 'Search the whole file for `process.env.CLAUDE_PID` and report every match'
check "V17f: search verb before the qualifier -> allow" is_allow
vrun v17g task-gopher:task-gopher "Fetch and grep the full text of pkg/constants.py for BUFFER"
check "V17g: grep before the qualifier -> allow" is_allow
vrun v17h task-gopher:task-gopher '`ls -R ~/.claude/skills/herdr` — full file listing'
check "V17h: listing noun after the file-noun -> allow" is_allow
vrun v17i task-gopher:task-gopher "Read tests/t.sh in full and report back a COMPACT numbered list of every test case"
check "V17i: read-but-distil -> allow" is_allow
vrun v17j task-gopher:task-gopher "Read hooks/report.mjs in full. Report back compactly:"
check "V17j: read-but-distil, adverb form -> allow" is_allow
vrun v17k task-gopher:task-gopher "Read tests/t.sh in full (158 lines) and report back VERBATIM with line numbers: the entire file"
check "V17k: 'report' alone is not a distil signal -> deny" is_deny
vrun v17l task-gopher:task-gopher "grep for §13 as a heading first and read the whole section"
check "V17l: H2 no longer lists 'section' -> allow" is_allow
vrun v17m task-gopher:task-gopher "Read the whole file hooks/x.mjs and quote it"
check "V17m: H2 control -> deny" is_deny
vrun v17n task-gopher:task-gopher "the complete text of section §7.5 of docs/specs/0008.md"
check "V17n: qualifier-first 'of section' breaks adjacency -> allow" is_allow

check "V10/V15: predicate agrees with every example and with the 13 recall fixtures (8 deny, 5 known-FN-direction)" '[ "$PRED" = "0" ]'

# 11 — r8 H1 adjacency: an explicit path token, glue only in between.
vrun v11a task-gopher:task-gopher "Full content of hooks/sessionend-roster.mjs"
check "V11a: qualifier then path -> deny" is_deny
vrun v11b task-gopher:task-gopher 'full contents of `hooks/x.mjs`'
check "V11b: backticked path (qualifier unquoted) -> deny" is_deny
vrun v11c task-gopher:task-gopher "the complete, exact contents of hooks/x.mjs"
check "V11c: H1c shape -> deny" is_deny
vrun v11d task-gopher:task-gopher "$(printf 'Return the FULL, VERBATIM content of these files:\n- hooks/a.mjs\n- hooks/b.mjs')"
check "V11d: colon + one newline + list marker is glue -> deny" is_deny
vrun v11e task-gopher:task-gopher "hooks/x.mjs in full"
check "V11e: H1b mirror -> deny" is_deny
vrun v11f task-gopher:task-gopher "tests/t.sh — full contents"
check "V11f: path first, dash glue -> deny" is_deny
vrun v11g task-gopher:task-gopher "full contents of the tests/ directory (just filenames)"
check "V11g: trailing slash is a directory, not a path token -> allow" is_allow
vrun v11h task-gopher:task-gopher "full text of the section beginning ## Scope in docs/a.md"
check "V11h: non-glue words break adjacency -> allow" is_allow
vrun v11i task-gopher:task-gopher 'full source of `roleForPeerName` in hooks/x.mjs'
check "V11i: an identifier is not glue -> allow" is_allow
vrun v11j task-gopher:task-gopher "full text of every FAIL line in /tmp/suite.log"
check "V11j: line filter breaks adjacency -> allow" is_allow
vrun v11k task-gopher:task-gopher "return the full file if under 500 lines"
check "V11k: no path token -> allow" is_allow
vrun v11l task-gopher:task-gopher "give the full file listing of docs/"
check "V11l: directory listing -> allow" is_allow
vrun v11m task-gopher:task-gopher "Run the full suite, one file at a time on tests/t.sh"
check "V11m: comma binding, and 'suite' is not glue -> allow" is_allow
vrun v11n task-gopher:task-gopher "full contents of v0.16.0"
check "V11n: version string is not a path token -> allow" is_allow

# 12 — r8 mention guard. Both live FPs named paths; the quote rule tests the
# QUALIFIER, never the path.
vrun v12a task-gopher:task-gopher "the gate should DENY a dispatch that orders the runner to read a WHOLE FILE such as hooks/x.mjs"
check "V12a: describing the gate -> allow" is_allow
vrun v12b task-gopher:task-gopher "a hit counts as a true positive when the order asks for the complete file hooks/x.mjs"
check "V12b: definitional -> allow" is_allow
vrun v12c task-gopher:task-gopher 'the phrase `whole file` must trip it for hooks/x.mjs'
check "V12c: qualifier in backticks -> allow" is_allow
vrun v12d task-gopher:task-gopher 'label as TP any prompt saying "full contents of hooks/x.mjs"'
check "V12d: qualifier inside double quotes -> allow" is_allow
vrun v12e task-gopher:task-gopher "Now return the whole file hooks/x.mjs"
check "V12e: imperative, no meta word -> deny" is_deny

# 13 — r8 H3: the range tool must sit directly on a path, and = 80 denies
# whether or not a pipe is anywhere nearby.
vrun v13a task-gopher:task-gopher "head -80 hooks/x.mjs"
check "V13a: span exactly 80 -> deny" is_deny
vrun v13b task-gopher:task-gopher "head -79 hooks/x.mjs"
check "V13b: span 79 -> allow" is_allow
vrun v13c task-gopher:task-gopher "head -80 hooks/x.mjs | grep x"
check "V13c: piped -> allow" is_allow
vrun v13d task-gopher:task-gopher "head -n 80 hooks/x.mjs"
check "V13d: -n spelling -> deny" is_deny
vrun v13e task-gopher:task-gopher "sed -n '1,80p' hooks/x.mjs"
check "V13e: sed span 80 -> deny" is_deny
vrun v13f task-gopher:task-gopher "sed -n '1,79p' hooks/x.mjs"
check "V13f: sed span 79 -> allow" is_allow
vrun v13g task-gopher:task-gopher "sed -n '1,80p' hooks/x.mjs > /tmp/o"
check "V13g: redirect -> allow" is_allow
vrun v13h task-gopher:task-gopher "grep -n TODO src/ | head -100"
check "V13h: pipe before, and src/ is not a path token -> allow" is_allow
vrun v13i task-gopher:task-gopher "tail -n 300 /tmp/x.log > /tmp/t; wc -l /tmp/t"
check "V13i: redirect then read back -> allow" is_allow
vrun v13j task-gopher:task-gopher "tail -n 300 /tmp/x.log"
check "V13j: tail straight off a file -> deny" is_deny
vrun v13k task-gopher:task-gopher "Read(hooks/x.mjs, offset 1, limit 200)"
check "V13k: Read limit 200 -> deny" is_deny
vrun v13l task-gopher:task-gopher "Read(hooks/x.mjs, offset 1, limit 60)"
check "V13l: Read limit 60 -> allow" is_allow

# 14 — r8 known-FN-direction. These are ACCEPTED MISSES, measured in E1's
# recall number. Do not "fix" them into denies: the narrow rule is the ruling.
vrun v14a task-gopher:task-gopher "$(printf 'Read hooks/x.mjs.\n\nThen return the full file.')"
check "V14a: known-FN-direction — path two lines up -> allow" is_allow
vrun v14b task-gopher:task-gopher "full contents, cleaned up, of hooks/x.mjs"
check "V14b: known-FN-direction — non-glue words between -> allow" is_allow
vrun v14c task-gopher:task-gopher "Read hooks/x.mjs and return the full file contents"
check "V14c: known-FN-direction — 'and return the' breaks adjacency -> allow" is_allow
vrun v14d task-gopher:task-gopher "Read the whole file hooks/x.mjs and report it verbatim"
check "V14d: contrast — H2 needs no path -> deny" is_deny

# 16 — r8 negative control: a named path with no whole-file qualifier at all.
vrun v16a task-gopher:task-gopher "grep -n TODO hooks/x.mjs and report file:line"
check "V16a: grep with file:line -> allow" is_allow
vrun v16b task-gopher:task-gopher "summarise hooks/x.mjs in 10 lines"
check "V16b: summary -> allow" is_allow
vrun v16c task-gopher:task-gopher "list the exported names in hooks/directive.mjs"
check "V16c: listing exports -> allow" is_allow
check "V10: LARGE_RANGE_LINES is a named constant" "grep -q 'export const LARGE_RANGE_LINES' \"$PLUGIN/hooks/directive.mjs\""

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
