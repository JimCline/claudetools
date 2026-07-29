#!/bin/bash
# comment-discipline subagent-backstop tests.
# Runs the hooks with HOME redirected and a throwaway cwd so real config is never touched.
# Usage: bash tests/test-subagent-backstop.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
INJECT="$PLUGIN/hooks/posttooluse-inject.mjs"
SESSION="$PLUGIN/hooks/sessionstart.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/comment-discipline-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0

REAL_SEEN="$(printf '%s' ~)/.claude/comment-discipline.seen"
REAL_SEEN_PRE=0; [ -f "$REAL_SEEN" ] && REAL_SEEN_PRE=1

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

enable_user()  { printf '{"version":1,"enabled":true}\n'  > "$FAKEHOME/.claude/comment-discipline.json"; }
disable_user() { printf '{"version":1,"enabled":false}\n' > "$FAKEHOME/.claude/comment-discipline.json"; }
unconfigure()  { rm -f "$FAKEHOME/.claude/comment-discipline.json" "$PROJ/.claude/comment-discipline.json"; }
forget()       { rm -f "$FAKEHOME/.claude/comment-discipline.seen"; }

# run <script> <payload-json> -> OUT / RC
run() { OUT=$(printf '%s' "$2" | HOME="$FAKEHOME" node "$1" 2>/dev/null); RC=$?; }

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:120})"; fi
}

is_silent()   { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
has_rule()    { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'Comment discipline ACTIVE'; }
is_posttool() { printf '%s' "$OUT" | grep -q '"hookEventName":"PostToolUse"'; }

SUB="{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\",\"agent_id\":\"ag1\"}"
SUB2="{\"tool_name\":\"Write\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\",\"agent_id\":\"ag2\"}"
SUB_S2="{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"s2\",\"agent_id\":\"ag1\"}"
MAIN="{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\"}"

# ---- unconfigured / disabled: the backstop stays out of the way
unconfigure; forget
run "$INJECT" "$SUB"
check "unconfigured: silent (no nudge on an edit)" is_silent

disable_user; forget
run "$INJECT" "$SUB"
check "disabled: silent" is_silent

# ---- enabled: first edit in a subagent gets the rule, once
enable_user; forget
run "$INJECT" "$SUB"
check "subagent first edit: injects the rule" has_rule
check "subagent injection uses PostToolUse event name" is_posttool
run "$INJECT" "$SUB"
check "subagent second edit: silent (once per agent)" is_silent

run "$INJECT" "$SUB2"
check "sibling agent in same session: gets its own injection" has_rule

run "$INJECT" "$SUB_S2"
check "same agent_id in a different session: injected again" has_rule

# ---- main session is SessionStart's job, not the backstop's
run "$INJECT" "$MAIN"
check "main session (no agent_id): silent" is_silent

# ---- the unanchored matcher also routes TodoWrite here; only real edits count
forget
run "$INJECT" "{\"tool_name\":\"TodoWrite\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\",\"agent_id\":\"ag7\"}"
check "TodoWrite (matcher false-positive): silent" is_silent
run "$INJECT" "{\"tool_name\":\"NotebookEdit\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\",\"agent_id\":\"ag8\"}"
check "NotebookEdit: injects" has_rule

# ---- project scope opts out even when user scope is on
printf '{"version":1,"enabled":false}\n' > "$PROJ/.claude/comment-discipline.json"
forget
run "$INJECT" "$SUB"
check "project scope disabled beats user enabled: silent" is_silent
rm -f "$PROJ/.claude/comment-discipline.json"

# ---- robustness: a backstop must never break an edit
enable_user; forget
run "$INJECT" 'not json'
check "malformed stdin -> silent, exit 0" is_silent
run "$INJECT" ''
check "empty stdin -> silent, exit 0" is_silent
run "$INJECT" '{"tool_name":"Edit","agent_id":"ag9"}'
check "missing cwd/session_id -> no crash" "[ $RC -eq 0 ]"

# ---- the relay clause reaches the main session via SessionStart
enable_user
run "$SESSION" "{\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionStart\"}"
check "SessionStart still injects the directive" has_rule
check "directive carries the relay clause" "printf '%s' \"\$OUT\" | grep -q 'Relay to code-writing subagents'"

# ---- persistence must fail toward DELIVERY, never silently die
# (regression: markSeen had no mkdirSync, so a missing ~/.claude silenced the
#  hook permanently — and it fails closed, so nobody would ever notice)
NOHOME="$SANDBOX/nohome"
mkdir -p "$NOHOME"
printf '{"version":1,"enabled":true}\n' > "$PROJ/.claude/comment-discipline.json"
OUT=$(printf '%s' "$SUB" | HOME="$NOHOME" node "$INJECT" 2>/dev/null); RC=$?
check "missing ~/.claude: still injects" has_rule
[ -f "$NOHOME/.claude/comment-discipline.seen" ] && { PASS=$((PASS+1)); echo "PASS: missing ~/.claude: state dir created"; } || { FAIL=$((FAIL+1)); echo "FAIL: state dir not created"; }
OUT=$(printf '%s' "$SUB" | HOME="$NOHOME" node "$INJECT" 2>/dev/null); RC=$?
check "missing ~/.claude: second edit still silent (mark persisted)" is_silent

# unwritable state path: a dead safety net is worse than a repeated directive
UNWRIT="$SANDBOX/unwrit"
mkdir -p "$UNWRIT/.claude/comment-discipline.seen"   # a directory occupies the path
OUT=$(printf '%s' "$SUB" | HOME="$UNWRIT" node "$INJECT" 2>/dev/null); RC=$?
check "unwritable state path: injects anyway (fails toward delivery)" has_rule
rm -f "$PROJ/.claude/comment-discipline.json"

# ---- concurrent subagents must not wipe each other's marks
# (regression: non-atomic writeFileSync let a torn read reset ALL entries)
enable_user; forget
for i in $(seq 1 12); do
  printf '%s' "{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"cs\",\"agent_id\":\"c$i\"}" \
    | HOME="$FAKEHOME" node "$INJECT" >/dev/null 2>&1 &
done
wait
KEPT=$(node -e "try{const s=require('fs').readFileSync('$FAKEHOME/.claude/comment-discipline.seen','utf8').split('\n').filter(Boolean);process.stdout.write(String(new Set(s).size))}catch(e){process.stdout.write('0')}")
[ "$KEPT" -eq 12 ] && { PASS=$((PASS+1)); echo "PASS: 12 concurrent agents, all 12 marks survived"; } || { FAIL=$((FAIL+1)); echo "FAIL: concurrent marks lost, only $KEPT/12 survived"; }
STRAY=$(ls "$FAKEHOME/.claude/" | grep -c '\.tmp$')
[ "$STRAY" -eq 0 ] && { PASS=$((PASS+1)); echo "PASS: no stray .tmp files left behind"; } || { FAIL=$((FAIL+1)); echo "FAIL: $STRAY stray .tmp files"; }

# ---- relay clause must not claim the top slot (task-gopher gates the first 200 chars)
node -e "
const {DIRECTIVE} = await import('$PLUGIN/hooks/lib-config.mjs');
const p = DIRECTIVE.split('\n').find(l => l.startsWith('Relay to code-writing'));
process.exit(p && /BELOW any directive block already leading/.test(p) ? 0 : 1);
" --input-type=module >/dev/null 2>&1 \
  && { PASS=$((PASS+1)); echo "PASS: relay clause defers the top slot"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: relay clause does not defer the top slot"; }

# ---- syntax + JSON validity
for f in "$PLUGIN"/hooks/*.mjs; do
  node --check "$f" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: node --check $(basename "$f")"; } || { FAIL=$((FAIL+1)); echo "FAIL: node --check $(basename "$f")"; }
done
for j in "$PLUGIN/hooks/hooks.json" "$PLUGIN/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json"; do
  node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: valid JSON $(basename "$j")"; } || { FAIL=$((FAIL+1)); echo "FAIL: invalid JSON $j"; }
done

# ---- versions agree across plugin.json and marketplace.json
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='comment-discipline').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

# ---- real config untouched
if [ -f "$REAL_SEEN" ] && [ "$REAL_SEEN_PRE" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "FAIL: real ~/.claude/comment-discipline.seen was created by the tests!"
else
  PASS=$((PASS+1)); echo "PASS: real ~/.claude untouched by tests"
fi

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
