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

# ---------------------------------------------------------------------------
# spec 0020 §4.1 / §6 item 17/21: parallel coverage for mcp__ah__roster_dismiss_close.
# TWO distinct checks, deliberately not one: the ask-decision case exercises the hook
# BODY directly (same as every case above — it pipes JSON straight to the .mjs file, never
# touching hooks.json), and the matcher-reachability case inspects hooks.json itself. A
# body-only fix (tool name added to GATED_TOOLS but not to the hooks.json matcher) would pass
# the first case while shipping completely ungated in production — exactly what §4.1 warns
# against — so the second case is the one that actually proves the tool is reachable at all.
# ---------------------------------------------------------------------------

# ---- ask-decision: fires on the exact new tool name, always ask (same as disband_close)
hook "mcp__ah__roster_dismiss_close" '{"cwd":"'"$PROJ"'","name":"proj-architect","confirm":true,"plan_token":"t"}'
check "fires on mcp__ah__roster_dismiss_close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "dismiss_close: enrichment names the single member from tool_input.name, not the whole team" \
  'echo "$OUT" | grep -q "proj-architect"'

# ---- matcher-reachability: hooks.json's PreToolUse matcher must name the new tool IN THE SAME
# rule that points at pretooluse-disband-close-gate.mjs — a hook the matcher never selects for
# never runs, and the ask-decision case above cannot detect that (it bypasses hooks.json).
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
MATCHER_CHECK=$(node -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const rule = (cfg.hooks.PreToolUse || []).find((r) =>
    Array.isArray(r.hooks) && r.hooks.some((h) => typeof h.command === "string" && h.command.includes("pretooluse-disband-close-gate.mjs"))
  );
  const names = rule ? String(rule.matcher).split("|") : [];
  console.log(names.includes("mcp__ah__roster_dismiss_close") ? "PASS" : "FAIL " + JSON.stringify(names));
' "$HOOKS_JSON")
check "hooks.json PreToolUse matcher for pretooluse-disband-close-gate.mjs names mcp__ah__roster_dismiss_close" \
  '[ "$MATCHER_CHECK" = "PASS" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
