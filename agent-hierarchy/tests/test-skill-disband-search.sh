#!/bin/bash
# agent-hierarchy — the agent-team skill must tell the LLM to SEARCH when a disband/dismiss plan
# comes back empty, never to hand the question back to the user (spec 0050 §3).
# Usage: bash tests/test-skill-disband-search.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$PLUGIN/skills/agent-team/SKILL.md"
DOC="$PLUGIN/docs/cli-tools.md"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# The text of one `## <heading>` section, up to the next `## ` heading.
section() { awk -v h="$1" 'index($0, "## " h) == 1 {inside=1; next} /^## / {inside=0} inside' "$SKILL"; }

DISBAND="$(section '`disband`')"
DISMISS="$(section '`dismiss`')"

check "setup: both sections are non-empty" '[ -n "$DISBAND" ] && [ -n "$DISMISS" ]'
check "T10: the disband section reaches ListAgents" 'echo "$DISBAND" | grep -q "ListAgents"'
check "T10: the dismiss section reaches ListAgents" 'echo "$DISMISS" | grep -q "ListAgents"'
check "T10: the empty-plan search subsection exists" 'grep -q "^### Plan came back empty" "$SKILL"'
check "T10: it names all three sources" \
  'grep -q "roster.mjs teams --cwd" "$SKILL" && grep -q "sources.herdr" "$SKILL" && grep -q "ListAgents-only" "$SKILL"'
check "T10: ListAgents-only sessions are notified, not dropped" \
  'grep -q "hierarchy-disband" "$SKILL" && grep -q "notified, not closed" "$SKILL"'
check "T10: the disband notice tells a peer it may end its own session" \
  'grep -q "end your session if you can" "$SKILL"'
check "T10: the empty report names the prefix it searched under" 'grep -q "Searched with prefix" "$SKILL"'
check "T10: the skill never hands the search back to the user" \
  '! grep -qi "ask the user where" "$SKILL" && ! grep -qi "ask the user to locate" "$SKILL"'
check "T10: cli-tools.md documents the sources field" '[ "$(grep -c "carries.*\`sources\`\|\`sources\` block" "$DOC")" -ge 3 ]'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
