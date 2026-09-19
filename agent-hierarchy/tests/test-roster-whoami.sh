#!/bin/bash
# agent-hierarchy — roster.mjs `whoami`: a session looks up which team member its own pane is, and
# where its orchestrator lives. Read-only: no team write, no peers.jsonl write.
# HOME-redirected; real state untouched. The reply-address socket lives in a directory the Claude
# Code harness owns, so only its absence is exercised here — nothing is ever created there.
# Usage: bash tests/test-roster-whoami.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-whoami-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
HIER="$PROJ/.claude/hierarchy"
mkdir -p "$FAKEHOME/.claude" "$HIER/teams"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}
jsq() { HIER="$HIER" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{process.exit(1)}process.exit(eval(process.argv[1])?0:1)})' "$@"; }

# $1: extra env assignments (pane / pid); the caller's own pane and pid env never leak in.
who() {
  local envs=$1; shift
  OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE -u CLAUDE_PID HOME="$FAKEHOME" $envs node "$H/roster.mjs" whoami "$@" --cwd "$PROJ" 2>&1); RC=$?
}

(exit 0) & DEAD_PID=$!; wait "$DEAD_PID"

# $1 file, $2 team_id, $3 orchestrator pid (or null), $4 member name, $5 pane
write_team() {
  cat > "$1" <<EOF
{
  "version": 1, "team_id": "$2", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": $3 },
  "members": [
    {"role": "reviewer", "name": "$4", "route": "peer", "transport_id": "$5"},
    {"role": "architect", "name": null, "route": "subagent", "transport_id": null}
  ],
  "partial": false
}
EOF
}
state_sum() { find "$HIER" -type f -exec cksum {} + | sort; }

# ---- no team record at all
who "HERDR_PANE_ID=P1"
check "no team record anywhere -> no-team, exit 0" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===\"no-team\"&&o.member===null&&o.team===null&&o.orchestrator===null"'

write_team "$HIER/teams/alpha.json" ta "$$" alpha-reviewer P1
: > "$HIER/peers.jsonl"
BEFORE=$(state_sum)

# ---- no pane id from any source
who ""
check "no pane env, no pid -> no-pane-id, exit 0" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===\"no-pane-id\"&&o.member===null"'

# ---- exactly one match; live orchestrator whose socket is absent
who "HERDR_PANE_ID=P1"
check "pane matches one member -> member, team, team_file, orchestrator filled; reason null" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===null&&o.member.name===\"alpha-reviewer\"&&o.member.role===\"reviewer\"&&o.member.route===\"peer\"&&o.team===\"alpha\"&&o.team_file===process.env.HIER+\"/teams/alpha.json\"&&!(\"candidates\" in o)"'
check "live orchestrator pid with no socket file -> live true, send_to null, session_id passed through" \
  'echo "$OUT" | jsq "o.orchestrator.pid===Number(process.argv[2])&&o.orchestrator.live===true&&o.orchestrator.send_to===null&&o.orchestrator.session_id===null" "$$"'

who "TMUX_PANE=P1"
check "TMUX_PANE is the last pane source" 'echo "$OUT" | jsq "o.reason===null&&o.member.name===\"alpha-reviewer\""'

# ---- the pane recorded for this session's pid stands in when the env has none, and loses to it
node -e 'const fs=require("fs");const[f,p]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:"reviewer",session_id:"s-whoami",pid:Number(p),pane_id:"P1",ts:new Date().toISOString()})+"\n");' "$HIER/peers.jsonl" "$$"
BEFORE=$(state_sum)
who "CLAUDE_PID=$$"
check "pane id from this pid's peers.jsonl row" 'echo "$OUT" | jsq "o.reason===null&&o.member.name===\"alpha-reviewer\""'
who "CLAUDE_PID=$$ HERDR_PANE_ID=NOPE"
check "HERDR_PANE_ID outranks the recorded pane" 'echo "$OUT" | jsq "o.reason===\"not-a-member\""'

# ---- records exist, none holds the pane
who "HERDR_PANE_ID=P9"
check "pane in no team -> not-a-member" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===\"not-a-member\"&&o.member===null&&o.team===null"'

# ---- --team scans only that record
who "HERDR_PANE_ID=P1" --team alpha
check "--team alpha: found" 'echo "$OUT" | jsq "o.reason===null&&o.team===\"alpha\""'
who "HERDR_PANE_ID=P1" --team ghost
check "--team naming a missing record -> no-team" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===\"no-team\""'

# ---- dead orchestrator
write_team "$HIER/teams/beta.json" tb "$DEAD_PID" beta-reviewer P2
who "HERDR_PANE_ID=P2"
check "dead orchestrator pid -> live false, send_to null" 'echo "$OUT" | jsq "o.team===\"beta\"&&o.orchestrator.live===false&&o.orchestrator.send_to===null"'
write_team "$HIER/teams/beta.json" tb null beta-reviewer P2
who "HERDR_PANE_ID=P2"
check "no recorded orchestrator pid -> pid null, live null, send_to null" 'echo "$OUT" | jsq "o.orchestrator.pid===null&&o.orchestrator.live===null&&o.orchestrator.send_to===null"'

# ---- legacy team.json: team null, team_file set
write_team "$HIER/team.json" tl "$$" myrepo-reviewer P3
who "HERDR_PANE_ID=P3"
check "legacy team.json member -> team null, team_file set" 'echo "$OUT" | jsq "o.reason===null&&o.team===null&&o.team_file===process.env.HIER+\"/team.json\"&&o.member.name===\"myrepo-reviewer\""'

# ---- one pane in two records
write_team "$HIER/teams/gamma.json" tg "$$" gamma-reviewer P1
who "HERDR_PANE_ID=P1"
check "pane in two team records -> ambiguous with both candidates, nothing resolved" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.reason===\"ambiguous\"&&o.member===null&&o.orchestrator===null&&JSON.stringify(o.candidates.map(c=>c.team+\":\"+c.name).sort())===JSON.stringify([\"alpha:alpha-reviewer\",\"gamma:gamma-reviewer\"])"'
who "HERDR_PANE_ID=P1" --team gamma
check "--team disambiguates" 'echo "$OUT" | jsq "o.reason===null&&o.member.name===\"gamma-reviewer\""'

# ---- nothing above wrote anything
rm -f "$HIER/teams/beta.json" "$HIER/teams/gamma.json" "$HIER/team.json"
check "team files and peers.jsonl byte-identical after every lookup" '[ "$(state_sum)" = "$BEFORE" ]'

# ---- usage error
who "HERDR_PANE_ID=P1" --bogus x
check "unknown flag -> exit 2" '[ "$RC" -eq 2 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
