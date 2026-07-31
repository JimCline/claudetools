#!/bin/bash
# agent-hierarchy role-agent frontmatter guards.
# The harness offers a generic `advisor` escalation tool to subagents and
# nudges them to use it. Inside the hierarchy that is a sideways escalation —
# often to the very model the role already runs on — so every role denies it
# and carries a body rule for harnesses that ignore the deny.
# Usage: bash tests/test-agent-frontmatter.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
A="$PLUGIN/agents"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

fm() { # frontmatter only (between the --- markers) of agents/<file>
  awk '/^---$/{n++;next} n==1{print}' "$A/$1"
}

# ---- advisor is unavailable to every role
for f in reviewer architect ultra-advisor implementor; do
  check "$f: frontmatter denies advisor" 'fm "'$f'.md" | grep -E "^disallowedTools:" | grep -qw advisor'
  check "$f: body carries the no-advisor rule" 'grep -q "generic \`advisor\` tool" "$A/'$f'.md"'
done
# task-runner is an allowlist agent: advisor must simply not be granted
check "task-runner: tools allowlist does not grant advisor" '! fm task-runner.md | grep -E "^tools:" | grep -qw advisor'

# ---- the denies this plugin already relies on must not have been dropped
check "reviewer: still denies Edit, Write, NotebookEdit" 'fm reviewer.md | grep -E "^disallowedTools:" | grep -qw Edit && fm reviewer.md | grep -E "^disallowedTools:" | grep -qw Write && fm reviewer.md | grep -E "^disallowedTools:" | grep -qw NotebookEdit'
check "architect: still denies Edit, NotebookEdit" 'fm architect.md | grep -E "^disallowedTools:" | grep -qw Edit && fm architect.md | grep -E "^disallowedTools:" | grep -qw NotebookEdit'
check "ultra-advisor: still denies Edit, NotebookEdit" 'fm ultra-advisor.md | grep -E "^disallowedTools:" | grep -qw Edit && fm ultra-advisor.md | grep -E "^disallowedTools:" | grep -qw NotebookEdit'
# implementor must stay otherwise-unrestricted: advisor is its ONLY deny
check "implementor: denies advisor and nothing else" '[ "$(fm implementor.md | grep -E "^disallowedTools:" )" = "disallowedTools: advisor" ]'

# ---- model pins unchanged
check "reviewer pinned sonnet" 'fm reviewer.md | grep -q "^model: sonnet$"'
check "architect pinned opus" 'fm architect.md | grep -q "^model: opus$"'
check "ultra-advisor pinned fable" 'fm ultra-advisor.md | grep -q "^model: fable$"'
check "task-runner pinned haiku" 'fm task-runner.md | grep -q "^model: haiku$"'
check "implementor has no model pin (inherits)" '! fm implementor.md | grep -q "^model:"'

# ---- versions agree across plugin.json and marketplace.json
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='agent-hierarchy').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
