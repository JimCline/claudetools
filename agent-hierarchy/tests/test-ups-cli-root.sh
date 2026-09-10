#!/bin/bash
# agent-hierarchy — the `ah CLI root:` line on UserPromptSubmit (0.73.1).
#
# SessionStart alone does not cover the case that produced this: `/reload-plugins` fires no
# SessionStart, so a session that updates mid-flight never hears the new root and the CLI paths
# are the whole interface. UserPromptSubmit repeats the line every prompt. Its classification must
# match sessionstart.mjs — nothing for subagents, nothing when the hierarchy is configured-and-
# disabled — and the line itself must come from lib-config.mjs's cliRootLine(), not a restatement.
# HOME-redirected; real config never touched.
# Usage: bash tests/test-ups-cli-root.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/userpromptsubmit-peer-tracking.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-ups-cli-root-test.XXXXXX")"
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

# ups <prompt> [agent_id]
ups() {
  local prompt=$1 agent_id=${2:-}
  OUT=$(node -e '
    const payload = { session_id: "s1", cwd: process.argv[1], prompt: process.argv[2] };
    if (process.argv[3]) payload.agent_id = process.argv[3];
    process.stdout.write(JSON.stringify(payload));
  ' "$PROJ" "$prompt" "$agent_id" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

# The expected text is the function's own output, so the test cannot drift from the hook by
# restating the line: only a real behavioural change can break it.
ROOT_LINE=$(node --input-type=module -e "
  import { cliRootLine } from '$PLUGIN/hooks/lib-config.mjs';
  process.stdout.write(cliRootLine());
")
check "cliRootLine() opens with the root marker and names both CLIs" \
  '[ -n "$ROOT_LINE" ] && echo "$ROOT_LINE" | grep -qE "^ah CLI root \(v[^)]+\): " &&
   echo "$ROOT_LINE" | grep -q "/hooks/roster.mjs" && echo "$ROOT_LINE" | grep -q "/hooks/msg.mjs"'
check "cliRootLine() spells the absolute roster.mjs and msg.mjs paths" \
  'echo "$ROOT_LINE" | grep -q "$PLUGIN/hooks/roster.mjs" && echo "$ROOT_LINE" | grep -q "$PLUGIN/hooks/msg.mjs"'

# Two root lines in one context after a mid-session update name two different plugin directories;
# the version token is what tells a role which of them it is looking at.
PJ_VERSION=$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$PLUGIN/.claude-plugin/plugin.json")
check "cliRootLine() carries the plugin.json version as a (vX.Y.Z) token" \
  '[ -n "$PJ_VERSION" ] && echo "$ROOT_LINE" | grep -qF "ah CLI root (v$PJ_VERSION):"'

# ---- 1: an ordinary prompt in a main session carries the line, verbatim from cliRootLine()
ups "please fix the bug in the login form"
check "main session, unconfigured cwd: emits the root line" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "ah CLI root (v"'
check "main session: additionalContext contains cliRootLine() byte-for-byte" \
  'node -e "
     const out = JSON.parse(process.argv[1]);
     const ctx = out.hookSpecificOutput.additionalContext;
     process.exit(ctx.includes(process.argv[2]) ? 0 : 1);
   " "$OUT" "$ROOT_LINE"'
check "main session: still exactly one stdout JSON object" \
  '[ "$(echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{try{JSON.parse(d);console.log(\"one\")}catch{console.log(\"not-one\")}})")" = "one" ]'
check "main session: hookEventName is UserPromptSubmit" 'echo "$OUT" | grep -q "\"hookEventName\":\"UserPromptSubmit\""'

# ---- 2: a subagent gets nothing (same rule as sessionstart.mjs)
ups "please fix the bug in the login form" "agent123"
check "subagent: no output at all" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 3: configured-and-disabled gets nothing
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
ups "please fix the bug in the login form"
check "hierarchy configured but disabled: no output at all" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 4: configured and enabled gets the line
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF
ups "please fix the bug in the login form"
check "hierarchy configured and enabled: emits the root line" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "ah CLI root (v"'

# ---- 5: the pre-existing team-intent nudge still fires, and now shares the write
ups "let's spawn the team for this repo"
check "team-intent prompt: nudge AND root line in one stdout object" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "ah:agent-team" && echo "$OUT" | grep -q "ah CLI root (v" && [ "$(echo "$OUT" | grep -c "hookSpecificOutput")" -eq 1 ]'

# ---- 6: malformed input still fails open
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "malformed input: RC 0, no throw" '[ "$RC" -eq 0 ]'

# ---- 7: the two injection points share one source of truth. If sessionstart.mjs or this hook ever
# restates the line instead of calling cliRootLine(), that is the drift this catches.
check "both hooks call cliRootLine() rather than restating the line" \
  'grep -q "cliRootLine()" "$PLUGIN/hooks/sessionstart.mjs" && grep -q "cliRootLine()" "$HOOK" &&
   grep -q "ah CLI root" "$PLUGIN/hooks/lib-config.mjs" &&
   ! grep -q "ah CLI root" "$PLUGIN/hooks/sessionstart.mjs" && ! grep -q "ah CLI root" "$HOOK"'

# ---- 8: no `<AH_ROOT>` placeholder survives in text the harness substitutes into (agents/, skills/)
check "agents/ and skills/ use \${CLAUDE_PLUGIN_ROOT}, never the <AH_ROOT> placeholder" \
  '[ "$(grep -rl "<AH_ROOT>" "$PLUGIN/agents" "$PLUGIN/skills" 2>/dev/null | wc -l | tr -d " ")" -eq 0 ]'

# docs/cli-tools.md is read as a FILE, never substituted, so it keeps <AH_ROOT> — but it must carry
# the resolve-it-yourself recipe, or a reader has a placeholder and no way to expand it.
check "docs/cli-tools.md keeps <AH_ROOT> and carries the installed_plugins.json fallback recipe" \
  'grep -q "<AH_ROOT>" "$PLUGIN/docs/cli-tools.md" && grep -q "installed_plugins.json" "$PLUGIN/docs/cli-tools.md"'
# One recipe, in docs/cli-tools.md: a second copy is a second thing to drift.
check "orchestrator.md points at cli-tools.md rather than carrying its own recipe" \
  '! grep -q "installed_plugins.json" "$PLUGIN/agents/orchestrator.md" && grep -q "docs/cli-tools.md" "$PLUGIN/agents/orchestrator.md"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
