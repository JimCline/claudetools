#!/bin/bash
# agent-hierarchy — spec 0044 §8 (the entry point splits): `/agent-roster` edits the
# roster TEMPLATE, `/agent-team` operates the live INSTANCE, and `roster.mjs` stays the
# single implementation underneath. Covers spec 0044 §4 items 7, 8 and 9; the mechanism
# half's items 1-5 live in tests/test-roster-team-scope.sh.
# Usage: bash tests/test-roster-surface-split.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-surface-split-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
HIER="$PROJ/.claude/hierarchy"
ROSTER_SKILL="$PLUGIN/skills/agent-roster/SKILL.md"
TEAM_SKILL="$PLUGIN/skills/agent-team/SKILL.md"
PASS=0; FAIL=0
RC=0; OUT=""

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

r() { local env=$1; shift; OUT=$(eval "HOME=\"$FAKEHOME\" PATH=\"$NODE_DIR:\$PATH\" $env node \"$H/roster.mjs\" $(printf '%q ' "$@") --cwd \"$PROJ\"" 2>&1); RC=$?; }

# The `## Command surface` section of one skill file, bullets only.
surface_verbs() { # <skill file>
  awk '/^## Command surface/{f=1;next} /^## /{f=0} f' "$1" | grep -oE '^- `[a-z-]+' | sed 's/^- `//'
}

########################################################################
# 7 — §4 item 7: the alias holds. `/agent-roster <lifecycle>` and
# `/agent-team <lifecycle>` reach the SAME implementation, because there is
# only one: both skills drive `roster.mjs`, which has no notion of which
# surface invoked it. A second implementation, or a surface-conditional
# branch, is what this asserts against.
########################################################################
for verb in create spawn-one dismiss disband; do
  n=$(grep -cE "^ *case \"$verb\":" "$H/roster.mjs")
  check "7: exactly one \`$verb\` implementation in roster.mjs (no per-surface fork)" '[ "$n" -eq 1 ]'
done
check "7: roster.mjs accepts no surface/skill selector at all" \
  '! grep -qE -- "--surface|--skill|--via-team|SURFACE_FLAGS" "$H/roster.mjs"'

# Both slash commands exist and each delegates to its own skill, verbatim.
check "7: /agent-roster command file delegates to ah:agent-roster" \
  '[ -f "$PLUGIN/commands/agent-roster.md" ] && grep -q "ah:agent-roster" "$PLUGIN/commands/agent-roster.md"'
check "7: /agent-team command file delegates to ah:agent-team" \
  '[ -f "$PLUGIN/commands/agent-team.md" ] && grep -q "ah:agent-team" "$PLUGIN/commands/agent-team.md"'
check "7: the agent-team skill file exists with a frontmatter name" \
  '[ -f "$TEAM_SKILL" ] && head -5 "$TEAM_SKILL" | grep -q "^name: agent-team$"'

# §8.3 is explicit that the alias is PERMANENT, not a deprecation: the four
# lifecycle verbs must still run from the CLI both skills share, unchanged.
r "" init --level repo --route peer
check "7: init still runs (shared implementation reachable)" '[ "$RC" -eq 0 ]'
r "" add --level repo --role architect --model opus
check "7: add still runs" '[ "$RC" -eq 0 ]'
r "" create --plan
check "7: create --plan still runs through the same CLI both surfaces call" '[ "$RC" -eq 0 ]'
r "" disband
check "7: disband still runs" '[ "$RC" -eq 0 ]'
r "" dismiss myrepo-architect
check "7: dismiss still runs" '[ "$RC" -eq 0 ]'
r "" spawn-one architect --dry-run
check "7: spawn-one still runs" '[ "$RC" -eq 0 ]'
# §1.4's new command is on the team surface and reachable from the same CLI.
check "7: spawn-ad-hoc is dispatched by the same roster.mjs" \
  '[ "$(grep -cE "^ *case \"spawn-ad-hoc\":" "$H/roster.mjs")" -eq 1 ]'

########################################################################
# 8 — §4 item 8: the gate covers BOTH surfaces. A split that disarmed
# pretooluse-roster-skill-gate.mjs on one path is the named failure mode.
########################################################################
GATE="$H/pretooluse-roster-skill-gate.mjs"
# Spec 0048 §2.4.3: the gate keys on the parsed Bash command, not on an MCP tool name.
gate() { # <bash command string> <session_id>
  OUT=$(node -e 'process.stdout.write(JSON.stringify({ session_id: process.argv[1], cwd: process.argv[2], hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: process.argv[3] } }))' \
    "$2" "$PROJ" "$1" | HOME="$FAKEHOME" node "$GATE" 2>&1); RC=$?
}
i=0
for verb in create spawn-one spawn-ad-hoc adopt move dismiss disband untrack; do
  i=$((i+1)); rm -rf "$HIER/gates.jsonl"
  gate "node $H/roster.mjs $verb --cwd $PROJ" "sess-$i"
  check "8: roster.mjs $verb is gated" \
    'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\""'
  check "8: ...and the denial routes to the agent-team skill, not the roster one" \
    'echo "$OUT" | grep -q "ah:agent-team"'
done
# hooks.json's matcher is load-bearing in parallel with the JS verb set — a gate the matcher
# never selects for is silently ungated, whatever its body says (0042 §1.6, 0048 §2.4.5).
check "8: hooks.json runs the gate on the Bash matcher" \
  'node -e "const c=require(\"fs\").readFileSync(process.argv[1],\"utf8\");const j=JSON.parse(c);process.exit((j.hooks.PreToolUse||[]).some((r)=>r.matcher===\"Bash\"&&r.hooks.some((h)=>h.command.includes(\"pretooluse-roster-skill-gate.mjs\")))?0:1)" "$H/hooks.json"'
# The roster-side (template) verbs stay OUT of the lifecycle gate, exactly as before.
rm -rf "$HIER/gates.jsonl"; gate "node $H/roster.mjs add --role reviewer --cwd $PROJ" "sess-member"
check "8: add (template edit) is NOT captured by the lifecycle gate" \
  '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
rm -rf "$HIER/gates.jsonl"; gate "node $H/roster.mjs show --cwd $PROJ" "sess-show"
check "8: show (read-only) is NOT gated" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# §1.3's refusal is the OTHER thing that must not become surface-conditional:
# it lives in roster.mjs, so both skill surfaces inherit it.
r "" create --commit --verified '["myrepo-architect"]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "8: a live team exists for the refusal check" '[ "$RC" -eq 0 ]'
r "CLAUDE_PID=$$" add --level repo --role reviewer --model opus
check "8: §1.3 refuses the roster edit whichever surface issued it" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "spawn-ad-hoc"'
########################################################################
# 9 — §4 item 9: the surfaces list the right commands. This is the part of
# §8 that does the actual work (an agent picks from the menu it is shown),
# so it is asserted rather than eyeballed.
########################################################################
LIFECYCLE="create spawn-one spawn-ad-hoc dismiss disband adopt move resync reap teams history checkin"
TEMPLATE="init add edit remove layout alias"
for v in $LIFECYCLE; do
  check "9: /agent-roster's command surface does not list \`$v\`" \
    '! surface_verbs "$ROSTER_SKILL" | grep -qx "$v"'
done
for v in $TEMPLATE; do
  check "9: /agent-team's command surface does not list \`$v\`" \
    '! surface_verbs "$TEAM_SKILL" | grep -qx "$v"'
done
# ...and each surface positively lists its own half, so "lists nothing" cannot pass.
for v in create spawn-one spawn-ad-hoc dismiss disband; do
  check "9: /agent-team's command surface DOES list \`$v\`" \
    'surface_verbs "$TEAM_SKILL" | grep -qx "$v"'
done
for v in init add edit remove layout alias show; do
  check "9: /agent-roster's command surface DOES list \`$v\`" \
    'surface_verbs "$ROSTER_SKILL" | grep -qx "$v"'
done
check "9: /agent-roster's description no longer advertises spawning or disbanding a team" \
  '! head -5 "$ROSTER_SKILL" | grep -qiE "spawn the team|spawn my team|disband the team|start the team"'
check "9: /agent-team's description does advertise them" \
  'head -5 "$TEAM_SKILL" | grep -qi "disband the team"'
check "9: /agent-roster points at agent-team for lifecycle work" \
  'grep -q "ah:agent-team" "$ROSTER_SKILL"'
check "9: /agent-team points back at agent-roster for template edits" \
  'grep -q "ah:agent-roster" "$TEAM_SKILL"'

echo "----"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
