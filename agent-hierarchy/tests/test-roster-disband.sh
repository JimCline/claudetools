#!/bin/bash
# agent-hierarchy — roster.mjs `disband`: bare disband is the close-plan call by
# default (spec 0006, reversing spec 0002 §8.2). `--commit` removes team.json and
# nothing else; `--keep-sessions` is the old safe default (remove team.json, close
# nothing). `--kill` is accepted-and-ignored for 0002-era callers. Emits only;
# never executes. HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-disband.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-disband-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

run() { OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

write_team() {
  local transport=$1
  mkdir -p "$(dirname "$TEAM_FILE")"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "$transport",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "PANE1", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": null, "ref": "r3", "route": "subagent", "model": "opus", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

# ---- bare disband: the new default. Read-only, emits close, team.json survives.
write_team herdr
run disband
check "disband (bare): emits herdr pane close for the peer member with a transport_id" \
  'echo "$OUT" | grep -q "\"command\": \"herdr pane close PANE1\""'
check "disband (bare): peer member with null transport_id gets null command" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.close.find(c=>c.name===\"myrepo-implementor\");process.exit(m&&m.command===null?0:1)})"'
check "disband (bare): subagent-routed member gets null command" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.close.find(c=>c.role===\"reviewer\");process.exit(m&&m.command===null?0:1)})"'
check "disband (bare): does NOT remove team.json" \
  '! echo "$OUT" | grep -q "\"removed\"" && [ -e "$TEAM_FILE" ]'
check "disband (bare): emits a close key" \
  'echo "$OUT" | grep -q "\"close\""'

# ---- --commit: removes team.json only, no longer requires --kill
run disband --commit
check "--commit: reports removed, team.json now gone" \
  'echo "$OUT" | grep -q "\"removed\"" && ! echo "$OUT" | grep -q "\"close\"" && [ ! -e "$TEAM_FILE" ]'

# ---- --commit on an already-gone team: no active team, same shape as before
run disband --commit
check "--commit (retry, no active team): removed false, reason given" \
  'echo "$OUT" | grep -q "\"removed\": false"'

# ---- bare disband, tmux transport
write_team tmux
run disband
check "disband (bare, tmux): emits tmux kill-pane -t for the peer member with a transport_id" \
  'echo "$OUT" | grep -q "\"command\": \"tmux kill-pane -t PANE1\""'
run disband --commit

# ---- bare disband, terminal transport: no transport_id is ever non-null for terminal, so no commands
write_team terminal
run disband
check "disband (bare, terminal): every command is null (nothing addressable to close)" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.close.every(c=>c.command===null)?0:1)})"'
run disband --commit

# ---- bare disband emits only; never executes (no herdr/tmux binary needs to exist on PATH for this to work)
write_team herdr
OUT=$(HOME="$FAKEHOME" PATH="$(dirname "$(command -v node)")" node "$H/roster.mjs" disband --cwd "$PROJ" 2>&1); RC=$?
check "disband (bare): succeeds with no herdr binary on PATH (emit-only, does not execute)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"command\": \"herdr pane close PANE1\""'
run disband --commit

# ---- --keep-sessions: the old safe default, single call, no close key
write_team herdr
run disband --keep-sessions
check "--keep-sessions: reports disbanded, no 'close' key emitted" \
  'echo "$OUT" | grep -q "\"disbanded\": true" && ! echo "$OUT" | grep -q "\"close\""'
check "--keep-sessions: team.json removed" \
  '[ ! -e "$TEAM_FILE" ]'
check "--keep-sessions: output byte-identical to pre-0006 plain-disband fixture" \
  '[ "$OUT" = "$(cat <<FIX
{
  "disbanded": true,
  "team_id": "t1",
  "members": [
    {
      "role": "architect",
      "name": "myrepo-architect",
      "transport_id": "PANE1"
    },
    {
      "role": "implementor",
      "name": "myrepo-implementor",
      "transport_id": null
    },
    {
      "role": "reviewer",
      "name": null,
      "transport_id": null
    }
  ]
}
FIX
)" ]'

# ---- --keep-sessions with no active team
run disband --keep-sessions
check "--keep-sessions: no active team -> disbanded false, reason given" \
  'echo "$OUT" | grep -q "\"disbanded\": false"'

# ---- unknown flag rejection (spec 0006 §6): fails, team.json intact, no close emitted
write_team herdr
run disband --no-kill
check "disband --no-kill: exit 2, team.json intact, no close key" \
  '[ "$RC" -eq 2 ] && [ -e "$TEAM_FILE" ] && ! echo "$OUT" | grep -q "\"close\""'
run disband --keep-session
check "disband --keep-session (typo): exit 2, team.json intact, no close key" \
  '[ "$RC" -eq 2 ] && [ -e "$TEAM_FILE" ] && ! echo "$OUT" | grep -q "\"close\""'
run disband --nonsense
check "disband --nonsense: exit 2, team.json intact, no close key" \
  '[ "$RC" -eq 2 ] && [ -e "$TEAM_FILE" ] && ! echo "$OUT" | grep -q "\"close\""'

# ---- --keep-sessions combination rules: contradictory pairs rejected
run disband --keep-sessions --commit
check "--keep-sessions --commit: exit 2, team.json intact" \
  '[ "$RC" -eq 2 ] && [ -e "$TEAM_FILE" ]'
run disband --keep-sessions --kill
check "--keep-sessions --kill: exit 2, team.json intact" \
  '[ "$RC" -eq 2 ] && [ -e "$TEAM_FILE" ]'

# ---- --kill is a no-op: identical stdout to the paths it used to select
run disband --kill --plan
KILL_PLAN_OUT=$OUT
run disband --kill
KILL_BARE_OUT=$OUT
run disband
BARE_OUT=$OUT
check "--kill is a no-op: --kill --plan, --kill, and bare disband produce identical stdout" \
  '[ "$KILL_PLAN_OUT" = "$KILL_BARE_OUT" ] && [ "$KILL_BARE_OUT" = "$BARE_OUT" ]'
run disband --kill --commit
KILL_COMMIT_OUT=$OUT
write_team herdr
run disband --commit
COMMIT_OUT=$OUT
check "--kill is a no-op: --kill --commit and --commit produce identical stdout" \
  '[ "$KILL_COMMIT_OUT" = "$COMMIT_OUT" ]'

# ---- --plan is read-only (regression test for the pre-0006 defect: bare --plan used to delete team.json)
write_team herdr
run disband --plan
check "disband --plan: team.json left on disk" \
  '[ -e "$TEAM_FILE" ]'
run disband --commit

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
