#!/bin/bash
# comment-discipline at-spawn injection tests (SubagentStart, flavor 5c).
# Runs the hooks with HOME redirected and a throwaway cwd so real config is never touched.
# Usage: bash tests/test-subagentstart.sh   (exits 0 iff all cases pass)
#
# What this CANNOT prove: that the harness actually delivers SubagentStart
# additionalContext to the spawned subagent. That needs a live probe in a fresh
# session — see docs/subagent-directive-relay.md, "Test plan".

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
SPAWN="$PLUGIN/hooks/subagentstart.mjs"
INJECT="$PLUGIN/hooks/posttooluse-inject.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/comment-discipline-spawn-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0

REAL_SEEN="$(printf '%s' ~)/.claude/comment-discipline.seen"
REAL_SEEN_PRE=0; [ -f "$REAL_SEEN" ] && REAL_SEEN_PRE=1

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

enable_user()  { printf '{"version":1,"enabled":true}\n'  > "$FAKEHOME/.claude/comment-discipline.json"; }
disable_user() { printf '{"version":1,"enabled":false}\n' > "$FAKEHOME/.claude/comment-discipline.json"; }
disable_proj() { printf '{"version":1,"enabled":false}\n' > "$PROJ/.claude/comment-discipline.json"; }
unconfigure()  { rm -f "$FAKEHOME/.claude/comment-discipline.json" "$PROJ/.claude/comment-discipline.json"; }
forget()       { rm -f "$FAKEHOME/.claude/comment-discipline.seen"; }

# run <script> <payload-json> -> OUT / RC
run() { OUT=$(printf '%s' "$2" | HOME="$FAKEHOME" node "$1" 2>/dev/null); RC=$?; }

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:120})"; fi
}

is_silent()  { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
has_rule()   { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'Comment discipline ACTIVE'; }
is_spawn()   { printf '%s' "$OUT" | grep -q '"hookEventName":"SubagentStart"'; }

# The whole channel depends on emitting a JSON envelope: plain stdout is
# discarded silently by this event. Assert the shape, not just the text.
is_json_envelope() {
  printf '%s' "$OUT" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const o=JSON.parse(s);
      const h=o.hookSpecificOutput;
      if(!h||h.hookEventName!=="SubagentStart") process.exit(1);
      if(typeof h.additionalContext!=="string"||!h.additionalContext.length) process.exit(1);
    })' 2>/dev/null
}

spawn_payload() { # <agent_type> [agent_id] [session_id]
  printf '{"hook_event_name":"SubagentStart","agent_type":"%s","agent_id":"%s","session_id":"%s","prompt_id":"p1","cwd":"%s","transcript_path":"/tmp/t.jsonl"}' \
    "$1" "${2:-ag1}" "${3:-s1}" "$PROJ"
}

GENERAL="$(spawn_payload general-purpose)"

# ---- unconfigured / disabled: the hook stays out of the way
unconfigure; forget
run "$SPAWN" "$GENERAL"
check "unconfigured: silent (no nudge into a subagent)" is_silent

disable_user; forget
run "$SPAWN" "$GENERAL"
check "disabled at user scope: silent" is_silent

enable_user; disable_proj; forget
run "$SPAWN" "$GENERAL"
check "project scope overrides user enable: silent" is_silent
rm -f "$PROJ/.claude/comment-discipline.json"

# ---- enabled: a code-capable subagent gets the rule at spawn
enable_user; forget
run "$SPAWN" "$GENERAL"
check "general-purpose spawn: injects the rule" has_rule
check "general-purpose spawn: tagged SubagentStart" is_spawn
check "general-purpose spawn: valid JSON envelope" is_json_envelope

# A plain-stdout regression would still 'have_rule' via grep, so assert the
# payload is parseable JSON and NOT bare text.
forget
run "$SPAWN" "$GENERAL"
check "output is not bare text" 'printf "%s" "$OUT" | head -c 1 | grep -q "{"'

# ---- non-authoring agent types are skipped (optimization, matched exactly)
for t in Explore Plan output-style-setup task-gopher task-gopher:task-gopher; do
  forget
  run "$SPAWN" "$(spawn_payload "$t")"
  check "skips non-authoring agent: $t" is_silent
done

# Exact match, not substring: a custom agent whose name merely CONTAINS a
# skipped name must still be covered.
forget
run "$SPAWN" "$(spawn_payload Explorer)"
check "does not skip 'Explorer' (substring of Explore)" has_rule

forget
run "$SPAWN" "$(spawn_payload my-task-gopher-helper)"
check "does not skip 'my-task-gopher-helper'" has_rule

# ---- missing / malformed input must never break a spawn
enable_user; forget
run "$SPAWN" ''
check "empty stdin: exits 0" '[ $RC -eq 0 ]'

run "$SPAWN" 'not json at all'
check "malformed stdin: exits 0" '[ $RC -eq 0 ]'

forget
run "$SPAWN" "{\"hook_event_name\":\"SubagentStart\",\"cwd\":\"$PROJ\",\"session_id\":\"s1\"}"
check "missing agent_id: still injects" has_rule

# ---- the seen-mark hands off to the PostToolUse backstop
enable_user; forget
run "$SPAWN" "$(spawn_payload general-purpose ag9 s9)"
check "spawn marked the agent as seen" '[ -f "$FAKEHOME/.claude/comment-discipline.seen" ] && grep -q "^s9|ag9$" "$FAKEHOME/.claude/comment-discipline.seen"'

run "$INJECT" "{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"s9\",\"agent_id\":\"ag9\"}"
check "backstop stays quiet for an agent SubagentStart reached" is_silent

# ...but still covers an agent it never saw (e.g. a spawn with no SubagentStart)
run "$INJECT" "{\"tool_name\":\"Edit\",\"cwd\":\"$PROJ\",\"session_id\":\"s9\",\"agent_id\":\"unseen\"}"
check "backstop still covers an unmarked agent" has_rule

# ---- state dir is created when absent
enable_user; forget
rm -rf "$FAKEHOME/.claude"
mkdir -p "$FAKEHOME/.claude"; enable_user
rm -f "$FAKEHOME/.claude/comment-discipline.seen"
run "$SPAWN" "$(spawn_payload general-purpose agX sX)"
check "creates the seen file when absent" '[ -f "$FAKEHOME/.claude/comment-discipline.seen" ]'

# An unwritable seen path must not suppress delivery — failing toward delivery
# is the whole point of the backstop contract.
enable_user; forget
rm -f "$FAKEHOME/.claude/comment-discipline.seen"
mkdir -p "$FAKEHOME/.claude/comment-discipline.seen"
run "$SPAWN" "$(spawn_payload general-purpose agY sY)"
check "seen path unwritable: injects anyway" has_rule
rmdir "$FAKEHOME/.claude/comment-discipline.seen" 2>/dev/null

# ---- the hand-relay clause is gone (0.3.0 delivers automatically)
enable_user; forget
run "$SPAWN" "$GENERAL"
check "directive no longer asks agents to copy it by hand" '! printf "%s" "$OUT" | grep -q "copy this entire block verbatim"'
check "directive tells agents NOT to copy it" 'printf "%s" "$OUT" | grep -q "do NOT copy this block"'

# ---- wiring
check "hooks.json registers SubagentStart" 'grep -q "\"SubagentStart\"" "$PLUGIN/hooks/hooks.json"'
check "hooks.json points at subagentstart.mjs" 'grep -q "subagentstart.mjs" "$PLUGIN/hooks/hooks.json"'
check "hooks.json still registers PostToolUse backstop" 'grep -q "\"PostToolUse\"" "$PLUGIN/hooks/hooks.json"'

# ---- JSON files parse
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
