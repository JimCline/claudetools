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
check "architect: still denies NotebookEdit, does not deny Edit (spec: allowed to Edit spec files in place)" 'fm architect.md | grep -E "^disallowedTools:" | grep -qw NotebookEdit && ! fm architect.md | grep -E "^disallowedTools:" | grep -qw Edit'
# The Architect is design-only: no execution by any means. Bash is denied
# mechanically, and the body must carry both halves of the rule — the
# NEEDS-EVIDENCE hand-back and the no-execution-via-runner clause (a live
# Architect was observed running test cycles through task-runner, licensed by
# the old "execution legwork" wording).
check "architect: denies Bash (never executes)" 'fm architect.md | grep -E "^disallowedTools:" | grep -qw Bash'
check "architect: body carries NEEDS-EVIDENCE hand-back rule" 'grep -q "NEEDS-EVIDENCE" "$A/architect.md"'
check "architect: delegation is read-only retrieval, not execution" 'grep -q "READ-ONLY retrieval" "$A/architect.md" && ! grep -q "execution legwork" "$A/architect.md"'
# Only the architect loses Bash. The reviewer KEEPS it — but scoped by contract
# to read-only git inspection (the diff must live in its own context to be
# judged); every execution is a mandatory task-gopher dispatch. The implementor
# builds, so its Bash is unrestricted.
check "reviewer: Bash NOT denied (read-only diff inspection needs it)" '! fm reviewer.md | grep -E "^disallowedTools:" | grep -qw Bash'
check "reviewer: body scopes Bash to read-only inspection" 'grep -q "read-only inspection" "$A/reviewer.md"'
check "reviewer: body mandates delegated execution" 'grep -q "never execute yourself" "$A/reviewer.md" && grep -q "MANDATORY for execution" "$A/reviewer.md"'
check "reviewer: old run-it-yourself wording is gone" '! grep -q "a test should pass, run it" "$A/reviewer.md"'
check "implementor: Bash NOT denied" '! fm implementor.md | grep -E "^disallowedTools:" | grep -qw Bash'
check "ultra-advisor: still denies Edit, NotebookEdit" 'fm ultra-advisor.md | grep -E "^disallowedTools:" | grep -qw Edit && fm ultra-advisor.md | grep -E "^disallowedTools:" | grep -qw NotebookEdit'
# implementor must stay otherwise-unrestricted: advisor is its ONLY deny
check "implementor: denies advisor and nothing else" '[ "$(fm implementor.md | grep -E "^disallowedTools:" )" = "disallowedTools: advisor" ]'

# ---- model pins unchanged
check "reviewer pinned opus" 'fm reviewer.md | grep -q "^model: opus$"'
check "architect pinned opus" 'fm architect.md | grep -q "^model: opus$"'
check "ultra-advisor pinned fable" 'fm ultra-advisor.md | grep -q "^model: fable$"'
check "task-runner pinned haiku" 'fm task-runner.md | grep -q "^model: haiku$"'
check "implementor has no model pin (inherits)" '! fm implementor.md | grep -q "^model:"'

# ---- versions agree across plugin.json and marketplace.json
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='ah').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
