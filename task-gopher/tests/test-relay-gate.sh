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

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
