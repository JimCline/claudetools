#!/bin/bash
# agent-hierarchy — pretooluse-roster-skill-gate.mjs (spec 0042 §1.3) and the
# §1.5 team-intent nudge in userpromptsubmit-peer-tracking.mjs.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-skill-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-roster-skill-gate.mjs"
ROSTER="$PLUGIN/hooks/roster.mjs"
PROMPT_HOOK="$PLUGIN/hooks/userpromptsubmit-peer-tracking.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-skill-gate-test.XXXXXX")"
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

# hook <bash command string> [session id] [agent id]
# Spec 0048 §2.4.3: the gate keys on the parsed Bash command, not on a tool name.
hook() {
  local cmd=$1 session=${2:-s1} agent_id=${3:-}
  OUT=$(node -e '
    const payload = { session_id: process.argv[1], cwd: process.argv[2], tool_name: "Bash", tool_input: { command: process.argv[3] } };
    if (process.argv[4]) payload.agent_id = process.argv[4];
    process.stdout.write(JSON.stringify(payload));
  ' "$session" "$PROJ" "$cmd" "$agent_id" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) return 0;; *) return 1;; esac; }

VERBS="create spawn-one spawn-ad-hoc adopt move dismiss disband untrack"

# ---- 1/2: each gated verb: clean session denies + names the skill;
# the immediate identical retry proceeds (self-cleared).
n=0
for verb in $VERBS; do
  n=$((n+1))
  sess="clean-$n"
  CMD="node $ROSTER $verb --plan --cwd $PROJ"
  hook "$CMD" "$sess"
  check "deny+skill-name: roster.mjs $verb" '[ "$RC" -eq 0 ] && is_deny && echo "$OUT" | grep -q "ah:agent-team"'
  check "deny text tells the caller to re-run the same command" 'echo "$OUT" | grep -q "Re-running the same command"'
  hook "$CMD" "$sess"
  check "self-clears on retry: roster.mjs $verb" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
done

# ---- 3: explicitly-not-gated verbs produce no output at all
for verb in show teams history reap resync layout-splits init add edit remove layout alias checkin; do
  hook "node $ROSTER $verb --cwd $PROJ" "notgated-$verb"
  check "not gated, no output: roster.mjs $verb" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
done
hook "node $PLUGIN/hooks/msg.mjs new --to architect --from orchestrator --slug s --cwd $PROJ" "notgated-msg"
check "not gated, no output: msg.mjs new" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
hook "ls -la" "notgated-bash"
check "not gated, no output: an unrelated Bash command" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 0048 §6 T4: the old key is gone — an MCP tool name is no longer gated
OUT=$(printf '{"session_id":"mcp-key","cwd":"%s","tool_name":"mcp__plugin_ah_ah__team_create","tool_input":{"cwd":"%s"}}' "$PROJ" "$PROJ" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "an mcp__ tool name is no longer gated (MCP surface removed)" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 5: subagent context never denies
hook "node $ROSTER create --plan --cwd $PROJ" "sub1" "agent123"
check "subagent context: no deny" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 6: malformed/unreadable input fails open, never throws
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "malformed input: RC 0, no output, no throw" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

OUT=$(printf '' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "empty input: RC 0, no output" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 4: verb-set/matcher agreement check (spec 0048 §2.4.5)
NAME_AGREEMENT=$(node "$PLUGIN/tests/check-gate-name-agreement.mjs" 2>&1); NA_RC=$?
echo "$NAME_AGREEMENT"
check "gate verb-set/matcher agreement" '[ "$NA_RC" -eq 0 ]'

# ---------------------------------------------------------------------------
# §1.5: team-intent nudge in userpromptsubmit-peer-tracking.mjs
# ---------------------------------------------------------------------------

prompt_hook() {
  local prompt=$1
  OUT=$(node -e '
    const p = JSON.stringify(process.argv[1]);
    process.stdout.write(`{"session_id":"s1","prompt":${p}}`);
  ' "$prompt" | HOME="$FAKEHOME" node "$PROMPT_HOOK" 2>&1); RC=$?
}

prompt_hook "let's spawn the team for this repo"
check "§1.5: team-intent phrase injects a line naming the skill" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "ah:agent-team" && [ "$(echo "$OUT" | grep -c "ah:agent-team")" -eq 1 ]'

prompt_hook "please fix the bug in the login form"
check "§1.5: unrelated prompt injects nothing" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# phrase list matches SKILL.md's frontmatter description exactly (one source of truth)
PHRASE_CHECK=$(node -e '
  const fs = require("fs");
  const body = fs.readFileSync(process.argv[1], "utf8");
  const fm = body.match(/^---\n([\s\S]*?)\n---/);
  const descLine = fm && fm[1].match(/^description:\s*(.*)$/m);
  const skillPhrases = descLine ? [...descLine[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]) : [];

  // Exercise the actual (side-effect-free) phrase-list module rather than re-deriving
  // the extraction logic here, so a drift in that logic shows up as a functional
  // mismatch, not just a literal-list mismatch.
  import(process.argv[2]).then((mod) => {
    const derived = typeof mod.teamIntentPhrases === "function" ? mod.teamIntentPhrases() : null;
    if (derived === null) { console.log("FAIL: teamIntentPhrases not exported"); process.exit(1); }
    const a = JSON.stringify([...skillPhrases].sort());
    const b = JSON.stringify([...derived].sort());
    console.log(a === b ? "PASS" : `FAIL skill=${a} hook=${b}`);
    process.exit(a === b ? 0 : 1);
  }).catch((e) => { console.log("FAIL: " + e.message); process.exit(1); });
' "$PLUGIN/skills/agent-team/SKILL.md" "$PLUGIN/hooks/lib-team-intent.mjs")
check "§1.5: hook phrase list matches SKILL.md description" '[ "$PHRASE_CHECK" = "PASS" ]'

# spec 0042 review G3: every extracted phrase must be 3+ whitespace-separated words —
# matching is unanchored substring, so a shorter phrase (e.g. "the team") would fire on
# ordinary conversation and turn the nudge into noise. Asserted here so a future edit to
# SKILL.md's description can't silently reintroduce a short phrase.
WORD_FLOOR_CHECK=$(node -e '
  import(process.argv[1]).then((mod) => {
    const short = mod.teamIntentPhrases().filter((p) => p.trim().split(/\s+/).length < 3);
    console.log(short.length ? `FAIL short phrases: ${JSON.stringify(short)}` : "PASS");
    process.exit(short.length ? 1 : 0);
  }).catch((e) => { console.log("FAIL: " + e.message); process.exit(1); });
' "$PLUGIN/hooks/lib-team-intent.mjs")
check "§1.5: every team-intent phrase is 3+ words" '[ "$WORD_FLOOR_CHECK" = "PASS" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
