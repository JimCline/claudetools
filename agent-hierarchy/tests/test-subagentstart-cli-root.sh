#!/bin/bash
# agent-hierarchy — the `ah CLI root` line on SubagentStart.
#
# SessionStart and UserPromptSubmit never fire inside an Agent-tool subagent, so this hook is a
# subagent's only provider of the absolute CLI paths. It is also the one event whose additionalContext
# must sit inside the hookSpecificOutput envelope — bare stdout is discarded — so the shape is
# asserted, not just the text.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-subagentstart-cli-root.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/subagentstart-cli-root.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-subagentstart-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

fire() {
  OUT=$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1","agent_id":"a1","agent_type":"ah:implementor"}' "$PROJ" \
    | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

ROOT_LINE=$(node --input-type=module -e "
  import { cliRootLine } from '$PLUGIN/hooks/lib-config.mjs';
  process.stdout.write(cliRootLine());
")

# ---- 1: unconfigured cwd — a subagent still gets the line
fire
check "unconfigured cwd: exits 0" '[ "$RC" -eq 0 ]'
check "exactly one JSON object on stdout" \
  '[ "$(echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{try{JSON.parse(d);console.log(\"one\")}catch{console.log(\"not-one\")}})")" = "one" ]'
check "hookEventName is SubagentStart" 'echo "$OUT" | grep -q "\"hookEventName\":\"SubagentStart\""'
check "additionalContext sits inside hookSpecificOutput, not at top level" \
  'node -e "
     const o = JSON.parse(process.argv[1]);
     process.exit(o.hookSpecificOutput && typeof o.hookSpecificOutput.additionalContext === \"string\" && o.additionalContext === undefined ? 0 : 1);
   " "$OUT"'
check "additionalContext equals cliRootLine() byte-for-byte" \
  'node -e "
     const o = JSON.parse(process.argv[1]);
     process.exit(o.hookSpecificOutput.additionalContext === process.argv[2] ? 0 : 1);
   " "$OUT" "$ROOT_LINE"'

# ---- 2: configured and enabled still gets the line
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF
fire
check "hierarchy configured and enabled: emits the root line" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "ah CLI root"'

# ---- 3: a disabled hierarchy injects nothing anywhere, this hook included
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
fire
check "hierarchy configured but disabled: no output at all" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
rm -f "$PROJ/.claude/agent-hierarchy.json"

# ---- 4: malformed input fails open
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "malformed input: RC 0, no throw" '[ "$RC" -eq 0 ]'

# ---- 5: hooks.json wiring
check "hooks.json runs this hook on SubagentStart" \
  'node -e "
     const j = JSON.parse(require(\"node:fs\").readFileSync(process.argv[1], \"utf8\"));
     const rules = (j.hooks.SubagentStart || []).filter((r) => (r.hooks || []).some((h) => (h.command || \"\").includes(\"hooks/subagentstart-cli-root.mjs\")));
     process.exit(rules.length === 1 && rules[0].matcher === \"*\" ? 0 : 1);
   " "$PLUGIN/hooks/hooks.json"'

# ---- 6: $CLAUDE_PLUGIN_ROOT is empty in a Bash-tool environment, so a hook that prints it as part
# of a runnable command hands the reader a broken command. Only hooks.json may name it.
LEAKS=$(grep -n 'CLAUDE_PLUGIN_ROOT' "$PLUGIN"/hooks/*.mjs 2>/dev/null \
  | grep -vE ':[0-9]+: *(//|\*|/\*)' || true)
check "no hook .mjs emits \$CLAUDE_PLUGIN_ROOT outside a comment" '[ -z "$LEAKS" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
