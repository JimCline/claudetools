#!/bin/bash
# agent-hierarchy — roster.mjs `disband`: plain disband unchanged (team.json
# only, never kills). `--kill` is a two-call contract (spec 0002 §8, amended):
# `--plan` emits per-member close commands and never touches team.json;
# `--commit` removes team.json and nothing else. Emits only; never executes.
# HOME-redirected; real state untouched.
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

# ---- plain disband: unchanged, removes team.json only, no close commands
write_team herdr
run disband
check "disband (plain): reports disbanded, no 'close' key emitted" \
  'echo "$OUT" | grep -q "\"disbanded\": true" && ! echo "$OUT" | grep -q "\"close\""'
check "disband (plain): team.json removed" \
  '[ ! -e "$TEAM_FILE" ]'

# ---- disband with no active team
run disband
check "disband: no active team -> disbanded false, reason given" \
  'echo "$OUT" | grep -q "\"disbanded\": false"'

# ---- bare --kill (no --plan/--commit): rejected, must pick one
write_team herdr
run disband --kill
check "--kill (bare): exit 2, names --plan/--commit" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q -- "--plan" && echo "$OUT" | grep -q -- "--commit"'

# ---- --kill --plan, herdr transport: read-only, team.json untouched
write_team herdr
run disband --kill --plan
check "--kill --plan (herdr): emits herdr pane close for the peer member with a transport_id" \
  'echo "$OUT" | grep -q "\"command\": \"herdr pane close PANE1\""'
check "--kill --plan (herdr): peer member with null transport_id gets null command" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.close.find(c=>c.name===\"myrepo-implementor\");process.exit(m&&m.command===null?0:1)})"'
check "--kill --plan (herdr): subagent-routed member gets null command" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.close.find(c=>c.role===\"reviewer\");process.exit(m&&m.command===null?0:1)})"'
check "--kill --plan (herdr): does NOT emit 'removed', and team.json is untouched" \
  '! echo "$OUT" | grep -q "\"removed\"" && [ -e "$TEAM_FILE" ]'

# ---- --kill --commit: removes team.json only, after --plan already ran
run disband --kill --commit
check "--kill --commit: reports removed, team.json now gone" \
  'echo "$OUT" | grep -q "\"removed\"" && ! echo "$OUT" | grep -q "\"close\"" && [ ! -e "$TEAM_FILE" ]'

# ---- --kill --commit on an already-gone team: reports no active team, same shape as plain disband
run disband --kill --commit
check "--kill --commit (retry, no active team): removed false, reason given" \
  'echo "$OUT" | grep -q "\"removed\": false"'

# ---- --kill --plan, tmux transport
write_team tmux
run disband --kill --plan
check "--kill --plan (tmux): emits tmux kill-pane -t for the peer member with a transport_id" \
  'echo "$OUT" | grep -q "\"command\": \"tmux kill-pane -t PANE1\""'
run disband --kill --commit

# ---- --kill --plan, terminal transport: no transport_id is ever non-null for terminal, so no commands
write_team terminal
run disband --kill --plan
check "--kill --plan (terminal): every command is null (nothing addressable to close)" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.close.every(c=>c.command===null)?0:1)})"'
run disband --kill --commit

# ---- --kill --plan emits only; never executes (no herdr/tmux binary needs to exist on PATH for this to work)
write_team herdr
OUT=$(HOME="$FAKEHOME" PATH="$(dirname "$(command -v node)")" node "$H/roster.mjs" disband --kill --plan --cwd "$PROJ" 2>&1); RC=$?
check "--kill --plan: succeeds with no herdr binary on PATH (emit-only, does not execute)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"command\": \"herdr pane close PANE1\""'
run disband --kill --commit

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
