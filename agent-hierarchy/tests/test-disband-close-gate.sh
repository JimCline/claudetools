#!/bin/bash
# agent-hierarchy — pretooluse-disband-close-gate.mjs (spec 0016 §4.5.1): PreToolUse ask-rule for
# `mcp__ah__roster_disband_close`, matched by name only (never a wildcard), always ask, no caching.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-disband-close-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-disband-close-gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-disband-close-gate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

# hook <tool_name> <tool_input json>
hook() {
  local tool=$1 input=$2
  OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"%s","tool_input":%s}' "$PROJ" "$tool" "$input" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

is_ask() { case "$OUT" in *'"permissionDecision":"ask"'*) return 0;; *) return 1;; esac; }

# ---- fires on the exact tool name, always ask
hook "mcp__ah__roster_disband_close" '{"cwd":"'"$PROJ"'","confirm":true,"plan_token":"t"}'
check "fires on mcp__ah__roster_disband_close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "generic message when no team.json exists (readTeam enrichment has nothing)" \
  'echo "$OUT" | grep -q "close the live sessions of this Team"'

# ---- enrichment: names the members when team.json is readable
TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{"version":1,"team_id":"t1","created":"2026-01-01T00:00:00Z","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":null},"members":[{"role":"architect","name":"proj-architect","route":"peer","transport_id":"P1"}],"partial":false}
EOF
hook "mcp__ah__roster_disband_close" '{"cwd":"'"$PROJ"'","confirm":true,"plan_token":"t"}'
check "enrichment: names the live member in the ask message" \
  'echo "$OUT" | grep -q "proj-architect"'

# ---- readTeam enrichment failing (unreadable cwd) still asks, generic message, never skipped
hook "mcp__ah__roster_disband_close" '{"cwd":"/nonexistent/definitely-not-a-real-path","confirm":true,"plan_token":"t"}'
check "enrichment failure: still asks (never skips the prompt)" '[ "$RC" -eq 0 ] && is_ask'

# ---- does NOT fire on other mcp__ah__* tools, including the near-miss roster_disband
hook "mcp__ah__roster_disband" '{"cwd":"'"$PROJ"'","mode":"plan"}'
check "does NOT fire on roster_disband (the near-miss)" '[ -z "$OUT" ]'

hook "mcp__ah__roster_show" '{"cwd":"'"$PROJ"'"}'
check "does NOT fire on an unrelated tool (roster_show)" '[ -z "$OUT" ]'

hook "Bash" '{"command":"ls"}'
check "does NOT fire on a non-MCP tool" '[ -z "$OUT" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
