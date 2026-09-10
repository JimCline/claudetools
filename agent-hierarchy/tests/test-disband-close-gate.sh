#!/bin/bash
# agent-hierarchy — pretooluse-disband-close-gate.mjs (spec 0016 §4.5.1, 0020 §4.1), re-keyed onto
# the parsed Bash command by spec 0048 §2.4.2/§6 T3: it fires on `roster.mjs dismiss|disband --close`
# and on nothing else, always asks, never caches. HOME-redirected; real state untouched.
# Usage: bash tests/test-disband-close-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-disband-close-gate.mjs"
ROSTER="$PLUGIN/hooks/roster.mjs"
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

# hook <bash command string>
hook() {
  OUT=$(node -e '
    process.stdout.write(JSON.stringify({ session_id: "s1", cwd: process.argv[1], tool_name: "Bash", tool_input: { command: process.argv[2] } }));
  ' "$PROJ" "$1" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

is_ask() { case "$OUT" in *'"permissionDecision":"ask"'*) return 0;; *) return 1;; esac; }

# ---- fires on disband --close, always ask
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "fires on roster.mjs disband --close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "generic message when no team.json exists (readTeam enrichment has nothing)" \
  'echo "$OUT" | grep -q "close the live sessions of this Team"'

# ---- enrichment: names the members when team.json is readable
TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{"version":1,"team_id":"t1","created":"2026-01-01T00:00:00Z","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":null},"members":[{"role":"architect","name":"proj-architect","route":"peer","transport_id":"P1"}],"partial":false}
EOF
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "enrichment: names the live member in the ask message" 'echo "$OUT" | grep -q "proj-architect"'

# ---- asking twice asks twice: never cached, nothing recorded (spec 0048 §2.4.2)
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "second identical close command asks again (no caching)" '[ "$RC" -eq 0 ] && is_ask'
check "nothing is recorded in gates.jsonl by this gate" '[ ! -f "$PROJ/.claude/hierarchy/gates.jsonl" ]'

# ---- readTeam enrichment failing (unreadable cwd) still asks, generic message, never skipped
hook "node $ROSTER disband --close --confirm --plan-token t --cwd /nonexistent/definitely-not-a-real-path"
check "enrichment failure: still asks (never skips the prompt)" '[ "$RC" -eq 0 ] && is_ask'

# ---- dismiss: the member name comes from argv, not a tool input
hook "node $ROSTER dismiss proj-architect --close --confirm --plan-token t --cwd $PROJ"
check "fires on roster.mjs dismiss <name> --close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "dismiss: enrichment names the single member from argv, not the whole team" \
  'echo "$OUT" | grep -q "proj-architect"'

# ---- plan forms and the non-destructive verbs are NOT gated (0048 §2.4.2: --close is the mode)
hook "node $ROSTER disband --cwd $PROJ"
check "does NOT fire on bare disband (the plan form)" '[ -z "$OUT" ]'
hook "node $ROSTER dismiss proj-architect --cwd $PROJ"
check "does NOT fire on bare dismiss <name> (the plan form)" '[ -z "$OUT" ]'
hook "node $ROSTER untrack --all --commit --cwd $PROJ"
check "does NOT fire on untrack (never destructive to a session)" '[ -z "$OUT" ]'
hook "node $ROSTER show --cwd $PROJ"
check "does NOT fire on an unrelated verb (show)" '[ -z "$OUT" ]'
hook "ls"
check "does NOT fire on an unrelated Bash command" '[ -z "$OUT" ]'

# ---- the old key is gone: an MCP tool name must no longer reach this gate (0048 §3)
OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"mcp__ah__team_disband","tool_input":{"cwd":"%s","mode":"close","confirm":true,"plan_token":"t"}}' "$PROJ" "$PROJ" \
  | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "an mcp__ah__team_disband tool call is no longer gated (MCP surface removed)" '[ -z "$OUT" ]'

# ---- a close command the parser rejects must NOT be silently allowed past the gate either:
# it is unrecognised, so the gate stays silent and the user's normal permission flow applies.
hook "cd /x && node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "a compound command is not recognised (parser fails closed, gate silent)" '[ -z "$OUT" ]'

# ---- matcher reachability: the cases above pipe JSON straight to the .mjs and bypass hooks.json,
# so a gate whose matcher no longer selects it would ship ungated while they all pass (0020 §4.1).
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
MATCHER_CHECK=$(node -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const rule = (cfg.hooks.PreToolUse || []).find((r) =>
    Array.isArray(r.hooks) && r.hooks.some((h) => typeof h.command === "string" && h.command.includes("pretooluse-disband-close-gate.mjs"))
  );
  console.log(rule && rule.matcher === "Bash" ? "PASS" : "FAIL " + JSON.stringify(rule && rule.matcher));
' "$HOOKS_JSON")
check "hooks.json PreToolUse matcher for pretooluse-disband-close-gate.mjs is Bash" '[ "$MATCHER_CHECK" = "PASS" ]'

# gate/matcher agreement check (spec 0042 §4 item 4, re-keyed by 0048 §2.4.5)
NAME_AGREEMENT=$(node "$PLUGIN/tests/check-gate-name-agreement.mjs" 2>&1); NA_RC=$?
echo "$NAME_AGREEMENT"
check "gate verb-set/matcher agreement" '[ "$NA_RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
