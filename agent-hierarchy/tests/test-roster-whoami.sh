#!/bin/bash
# agent-hierarchy — roster.mjs `whoami`: a session looks up which team member its own pane is, and
# where its orchestrator lives. Read-only: no team write, no peers.jsonl write.
# HOME-redirected; real state untouched. The reply-address socket lives in a directory the Claude
# Code harness owns, so nothing is ever created there: the socket-present case points the session's
# own exported socket path at a sandbox directory instead.
# Usage: bash tests/test-roster-whoami.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
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

# $1: extra env assignments; the caller's own pane, pid, socket and session-id env never leak in.
who() {
  local envs=$1; shift
  OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_SESSION_ID HOME="$FAKEHOME" $envs node "$H/roster.mjs" whoami "$@" --cwd "$PROJ" 2>&1); RC=$?
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

# ---- reply address: the socket directory follows this session's own exported socket path
SOCKS="$SANDBOX/socks"
mkdir -p "$SOCKS"
: > "$SOCKS/$$.sock"
who "HERDR_PANE_ID=P1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCKS/424242.sock"
check "own socket exported, orchestrator's socket beside it -> send_to names the orchestrator pid's file in that directory" \
  'echo "$OUT" | SOCKS="$SOCKS" jsq "o.orchestrator.send_to===\"uds:\"+process.env.SOCKS+\"/\"+process.argv[2]+\".sock\"" "$$"'
rm -f "$SOCKS/$$.sock"
: > "$SOCKS/424242.sock"
who "HERDR_PANE_ID=P1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCKS/424242.sock"
check "orchestrator's socket file absent (only this session's own exists) -> send_to null" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.orchestrator.live===true&&o.orchestrator.send_to===null"'
who "HERDR_PANE_ID=P1"
check "socket variable unset -> exit 0, send_to null" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.orchestrator.send_to===null"'
who "HERDR_PANE_ID=P1 CLAUDE_CODE_MESSAGING_SOCKET="
check "socket variable empty -> exit 0, send_to null" '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.orchestrator.send_to===null"'

# ---- last observed brief: read from the obligation store under the redirected HOME
STORE="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
row() { printf '%s\n' "$1" >> "$STORE"; }
who "HERDR_PANE_ID=P1 CLAUDE_CODE_SESSION_ID=s-me"
check "no store file -> last_observed_brief null, member still resolved, no store created" \
  'echo "$OUT" | jsq "o.last_observed_brief===null&&o.reason===null&&o.member.name===\"alpha-reviewer\"" && [ ! -e "$STORE" ]'
row '{"type":"turn","session_id":"s-me","status":"armed","ts":"2026-01-01T00:00:01Z"}'
row '{"type":"dispatch","session_id":"s-me","request_id":"r1","to":"x","ts":"2026-01-01T00:00:02Z"}'
who "HERDR_PANE_ID=P1 CLAUDE_CODE_SESSION_ID=s-me"
check "only turn and dispatch rows for this session -> null" 'echo "$OUT" | jsq "o.last_observed_brief===null"'
row '{"session_id":"s-other","from":"uds:/x/1.sock","from_name":"someone","reply_to":"someone","task":"t","status":"pending","nudges":0,"ts":"2026-01-01T00:00:03Z"}'
who "HERDR_PANE_ID=P1 CLAUDE_CODE_SESSION_ID=s-me"
check "obligation rows for another session only -> null" 'echo "$OUT" | jsq "o.last_observed_brief===null"'
row '{"session_id":"s-me","from":"uds:/x/2.sock","from_name":"first-orch","reply_to":"first-orch","task":"t1","status":"pending","nudges":0,"ts":"2026-01-01T00:00:04Z"}'
row '{"session_id":"s-me","from":"uds:/x/3.sock","from_name":"second-orch","reply_to":"uds:/x/3.sock","task":"t2","status":"resolved","nudges":0,"ts":"2026-01-01T00:00:05Z"}'
row '{"type":"turn","session_id":"s-me","status":"disarmed","ts":"2026-01-01T00:00:06Z"}'
who "HERDR_PANE_ID=P1 CLAUDE_CODE_SESSION_ID=s-me"
check "several rows -> the last obligation row in file order, whatever its status, under exactly from/from_name/reply_to/ts" \
  'echo "$OUT" | jsq "JSON.stringify(o.last_observed_brief)===JSON.stringify({from:\"uds:/x/3.sock\",from_name:\"second-orch\",reply_to:\"uds:/x/3.sock\",ts:\"2026-01-01T00:00:05Z\"})&&!(\"last_observed_brief\" in o.orchestrator)"'
row '{"session_id":"s-me","from":"uds:/x/4.sock","from_name":"","reply_to":"uds:/x/4.sock","task":"t3","status":"pending","nudges":0,"ts":"2026-01-01T00:00:07Z"}'
who "HERDR_PANE_ID=P1 CLAUDE_CODE_SESSION_ID=s-me"
check "stored from_name empty -> null, not the empty string" 'echo "$OUT" | jsq "o.last_observed_brief.from===\"uds:/x/4.sock\"&&o.last_observed_brief.from_name===null"'
who "CLAUDE_CODE_SESSION_ID=s-me"
check "no pane id -> reason no-pane-id, the block is still filled" 'echo "$OUT" | jsq "o.reason===\"no-pane-id\"&&o.member===null&&o.last_observed_brief.from===\"uds:/x/4.sock\""'
who "HERDR_PANE_ID=P9 CLAUDE_CODE_SESSION_ID=s-me"
check "not a member -> the block is still filled" 'echo "$OUT" | jsq "o.reason===\"not-a-member\"&&o.last_observed_brief.from===\"uds:/x/4.sock\""'
row '{"session_id":"s-whoami","from":"uds:/x/5.sock","from_name":"via-peers-row","reply_to":"via-peers-row","task":"t4","status":"pending","nudges":0,"ts":"2026-01-01T00:00:08Z"}'
who "CLAUDE_PID=$$"
check "no session id in the env -> the one on this pid's peers.jsonl row is used" 'echo "$OUT" | jsq "o.last_observed_brief.from_name===\"via-peers-row\""'
who "CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=s-me"
check "the env session id outranks the peers.jsonl one" 'echo "$OUT" | jsq "o.last_observed_brief.from===\"uds:/x/4.sock\""'
STORE_SUM=$(cksum < "$STORE")
who "HERDR_PANE_ID=P1"
check "session id unresolvable -> block null, reason untouched (null on a resolved member), key present" \
  'echo "$OUT" | jsq "o.last_observed_brief===null&&(\"last_observed_brief\" in o)&&o.reason===null&&o.member.name===\"alpha-reviewer\""'
check "the store is never written" '[ "$(cksum < "$STORE")" = "$STORE_SUM" ]'
check "team files and peers.jsonl still byte-identical" '[ "$(state_sum)" = "$BEFORE" ]'

# ---- usage error
who "HERDR_PANE_ID=P1" --bogus x
check "unknown flag -> exit 2" '[ "$RC" -eq 2 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
