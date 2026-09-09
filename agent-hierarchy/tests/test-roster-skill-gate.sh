#!/bin/bash
# agent-hierarchy — pretooluse-roster-skill-gate.mjs (spec 0042 §1.3) and the
# §1.5 team-intent nudge in userpromptsubmit-peer-tracking.mjs.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-skill-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-roster-skill-gate.mjs"
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

# hook <tool_name> [extra json fields for tool_input/top-level]
hook() {
  local tool=$1 session=${2:-s1} agent_id=${3:-}
  local agent_field=""
  [ -n "$agent_id" ] && agent_field=",\"agent_id\":\"$agent_id\""
  OUT=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":{"cwd":"%s"}%s}' "$session" "$PROJ" "$tool" "$PROJ" "$agent_field" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) return 0;; *) return 1;; esac; }

VERBS="team_create team_spawn_one team_spawn_ad_hoc team_adopt team_move team_dismiss team_disband team_untrack"
PREFIXES="mcp__plugin_ah_ah__ mcp__ah__"

# ---- 1/2: each gated tool, both prefixes: clean session denies + names the skill;
# the immediate identical retry proceeds (self-cleared).
n=0
for verb in $VERBS; do
  for prefix in $PREFIXES; do
    n=$((n+1))
    sess="clean-$n"
    hook "${prefix}${verb}" "$sess"
    check "deny+skill-name: ${prefix}${verb}" '[ "$RC" -eq 0 ] && is_deny && echo "$OUT" | grep -q "ah:agent-team"'
    hook "${prefix}${verb}" "$sess"
    check "self-clears on retry: ${prefix}${verb}" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
  done
done

# ---- 3: explicitly-not-gated tools produce no output at all
for tool in mcp__ah__roster_show mcp__ah__team_list mcp__ah__team_history mcp__ah__roster_add \
            mcp__ah__roster_init mcp__ah__roster_edit mcp__ah__roster_remove \
            mcp__ah__team_reap mcp__ah__team_resync mcp__ah__team_layout_splits \
            mcp__ah__roster_layout mcp__ah__roster_alias \
            mcp__plugin_ah_ah__roster_show mcp__plugin_ah_ah__roster_layout \
            mcp__ah__msg_new mcp__plugin_ah_ah__msg_new; do
  hook "$tool" "notgated-$tool"
  check "not gated, no output: $tool" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
done

# ---- 5: subagent context never denies
hook "mcp__plugin_ah_ah__team_create" "sub1" "agent123"
check "subagent context: no deny" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 6: malformed/unreadable input fails open, never throws
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "malformed input: RC 0, no output, no throw" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

OUT=$(printf '' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "empty input: RC 0, no output" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- 4: generic name-agreement check (also covers §1.6's gate — see the checker's own header)
NAME_AGREEMENT=$(node "$PLUGIN/tests/check-gate-name-agreement.mjs" 2>&1); NA_RC=$?
echo "$NAME_AGREEMENT"
check "gate name-agreement (body vs hooks.json matcher, both prefixes)" '[ "$NA_RC" -eq 0 ]'

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
