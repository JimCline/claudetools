#!/bin/bash
# agent-hierarchy — disband/dismiss/teams find live herdr panes that no registry row names
# (spec 0050): `herdr agent list` is a source of the live-peer set, not just a healer of existing
# rows. HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-disband-herdr-only.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-herdr-only-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
OTHER="$SANDBOX/otherrepo"
HIER_DIR="$PROJ/.claude/hierarchy"
TEAM_FILE="$HIER_DIR/team.json"
PEERS_FILE="$HIER_DIR/peers.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$OTHER" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
(cd "$OTHER" && git init -q)
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr, same convention as test-roster-dismiss.sh: `agent list` reads
# $FAKE_HERDR_STATE, `pane close` logs and succeeds, every invocation logged verbatim.
# FAKE_HERDR_FAIL=1 makes `agent list` exit non-zero (T5's degrade case).
echo '[]' > "$SANDBOX/agents.json"
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
if (process.env.FAKE_HERDR_INVOKED_LOG) fs.appendFileSync(process.env.FAKE_HERDR_INVOKED_LOG, JSON.stringify(args) + "\n");
if (args[0] === "agent" && args[1] === "list") {
  if (process.env.FAKE_HERDR_FAIL === "1") {
    process.stderr.write("fake herdr: daemon unreachable\n");
    process.exit(2);
  }
  const agents = JSON.parse(fs.readFileSync(process.env.FAKE_HERDR_STATE, "utf8"));
  console.log(JSON.stringify({ id: "cli:agent:list", result: { agents, type: "agent_list" } }));
  process.exit(0);
}
if (args[0] === "pane" && args[1] === "close") {
  console.log(JSON.stringify({ id: "cli:pane:close", result: { ok: true } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(args) + "\n");
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"
INVOKED_LOG="$SANDBOX/herdr-invoked.log"

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
run_self() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" HERDR_PANE_ID="$1" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" node "$H/roster.mjs" "${@:2}" --cwd "$PROJ" 2>&1); RC=$?; }

write_agents() { echo "$1" > "$SANDBOX/agents.json"; }

# One agent in the shape a live `herdr agent list` actually returns: the registered name is
# OPTIONAL (herdr reports it only for `herdr agent start` agents), the pane title always present,
# the session id nested under agent_session, and the cwd duplicated across both keys.
# agent <pane_id> <title> [name|-] [cwd|-] [session_id|-]
agent() {
  "$NODE_BIN" -e 'const [pane,title,name,cwd,sid]=process.argv.slice(1);
    const a={agent:"claude",agent_status:"idle",focused:false,pane_id:pane,tab_id:"wG:t1",revision:1,
      terminal_title:"\u2733 "+title,terminal_title_stripped:title,terminal_id:"term_"+pane,workspace_id:"wG"};
    if(name&&name!=="-")a.name=name;
    if(cwd&&cwd!=="-"){a.cwd=cwd;a.foreground_cwd=cwd;}
    if(sid&&sid!=="-")a.agent_session={agent:"claude",kind:"id",source:"herdr:claude",value:sid};
    process.stdout.write(JSON.stringify(a));' "$1" "$2" "${3:--}" "${4:--}" "${5:--}"
}
agents() { write_agents "[$(IFS=,; echo "$*")]"; }
jq_() { echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);console.log(String(eval(process.argv[1])))})' "$1"; }
plan_token() { echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))'; }

fresh() { rm -rf "$HIER_DIR"; mkdir -p "$HIER_DIR"; : > "$INVOKED_LOG"; write_agents '[]'; }

seed_peer() { # <name> <role> <status> <pid> [pane_id]
  mkdir -p "$(dirname "$PEERS_FILE")"
  "$NODE_BIN" -e 'const fs=require("fs");const[f,n,r,st,p,pane]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,pane_id:pane||undefined,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4" "$5"
}

seed_peer_sid() { # <name> <role> <status> <pid> <pane_id> <session_id>
  mkdir -p "$(dirname "$PEERS_FILE")"
  "$NODE_BIN" -e 'const fs=require("fs");const[f,n,r,st,p,pane,sid]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,pane_id:pane,session_id:sid,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4" "$5" "$6"
}

write_team() { # <transport> <members-json>
  mkdir -p "$HIER_DIR"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "$1",
  "orchestrator": { "session_id": null, "pid": null },
  "members": $2,
  "partial": false
}
EOF
}

# ===========================================================================
# T1. No team.json, no peers.jsonl: a herdr pane named by convention is the plan,
#     and --close closes exactly its pane.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run disband
check "T1: the plan holds exactly one close entry" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "1" ]'
check "T1: the single entry is the herdr-only agent, labeled source:herdr" \
  '[ "$(jq_ "o.close[0].name")" = "myrepo-architect" ] && [ "$(jq_ "o.close[0].source")" = "herdr" ] && [ "$(jq_ "o.close[0].transport_id")" = "P7" ]'
check "T1: sources.herdr reports ok/matched/prefix" \
  '[ "$(jq_ "o.sources.herdr.ok")" = "true" ] && [ "$(jq_ "o.sources.herdr.matched")" = "1" ] && [ "$(jq_ "o.sources.herdr.prefix")" = "myrepo" ]'
TOKEN1=$(plan_token)
: > "$INVOKED_LOG"
run disband --close --confirm --plan-token "$TOKEN1"
check "T1: --close exits 0 and reports closed" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.closed")" = "true" ]'
check "T1: exactly one pane close, argv verbatim [\"pane\",\"close\",\"P7\"]" \
  '[ "$(grep -c "pane" "$INVOKED_LOG")" = "1" ] && grep -q "\[\"pane\",\"close\",\"P7\"\]" "$INVOKED_LOG"'

# ===========================================================================
# T2. Another repo's prefix never matches.
# ===========================================================================
fresh
agents "$(agent P8 otherrepo-architect otherrepo-architect "$PROJ" sid-other-0001)"
run disband
check "T2: a foreign prefix yields the unchanged no-op reason" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.reason")" = "no active team and no live peers" ]'
check "T2: sources.herdr ok with matched 0 (it listed 1 agent)" \
  '[ "$(jq_ "o.sources.herdr.ok")" = "true" ] && [ "$(jq_ "o.sources.herdr.agents")" = "1" ] && [ "$(jq_ "o.sources.herdr.matched")" = "0" ]'

# ===========================================================================
# T3. A matching name whose reported cwd is in another git checkout is excluded.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$OTHER" sid-architect-0001)"
run disband
check "T3: a pane in another checkout is excluded" \
  '[ "$(jq_ "o.sources.herdr.matched")" = "0" ] && [ "$(jq_ "o.reason")" = "no active team and no live peers" ]'
agents "$(agent P7 myrepo-architect myrepo-architect - sid-architect-0001)"
run disband
check "T3: a pane reporting no cwd at all is kept (U1)" '[ "$(jq_ "o.sources.herdr.matched")" = "1" ]'

# ===========================================================================
# T4. Dedup: the registry row wins, and the token is the one-id token.
# ===========================================================================
fresh
seed_peer myrepo-architect architect up $$ P7
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run disband
check "T4: one close entry, from the registry row" \
  '[ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].source")" = "peers" ]'
TOKEN4=$(plan_token)
run teams
check "T4: teams lists it once, from the registry row" \
  '[ "$(jq_ "o.untracked_live.length")" = "1" ] && [ "$(jq_ "o.untracked_live[0].source===undefined")" = "true" ]'
run disband --close --confirm --plan-token "$TOKEN4"
check "T4: the plan token still authorises the close (no duplicate id)" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.closed")" = "true" ]'

# T4c: same session, two different panes and no shared name — only the session id can tie them.
fresh
seed_peer_sid myrepo-reviewer reviewer up $$ P2 sid-reviewer-0001
agents "$(agent P3 myrepo-reviewer-2 - "$PROJ" sid-reviewer-0001)" "$(agent P6 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run teams
check "T4c: an agent sharing a peers row's session id under another name/pane is not added again" \
  '[ "$(jq_ "o.untracked_live.length")" = "2" ] && [ "$(jq_ "o.untracked_live.filter(r=>r.session_id===\"sid-reviewer-0001\").length")" = "1" ] && [ "$(jq_ "o.untracked_live.some(r=>r.name===\"myrepo-reviewer-2\")")" = "false" ]'

# T4d: a stale registry row (status up, pid long gone) must not suppress the live pane it names.
fresh
seed_peer myrepo-architect architect up 999999 P7
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run disband
check "T4d: a dead peers row does not hide the live herdr agent on its pane" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].source")" = "herdr" ] && [ "$(jq_ "o.close[0].transport_id")" = "P7" ]'

# ===========================================================================
# T5. Herdr cannot answer: degrade, never fail.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_FAIL=1 FAKE_HERDR_STATE="$SANDBOX/agents.json" node "$H/roster.mjs" disband --cwd "$PROJ" 2>&1); RC=$?
check "T5: a failing herdr query still exits 0 with the no-op reason" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.reason")" = "no active team and no live peers" ]'
check "T5: sources.herdr.ok false carries a reason and the prefix" \
  '[ "$(jq_ "o.sources.herdr.ok")" = "false" ] && [ -n "$(jq_ "o.sources.herdr.reason")" ] && [ "$(jq_ "o.sources.herdr.prefix")" = "myrepo" ]'
OUT=$(HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" disband --cwd "$PROJ" 2>&1); RC=$?
check "T5: herdr absent from PATH reports 'herdr not on PATH', exit 0" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.sources.herdr.ok")" = "false" ] && [ "$(jq_ "o.sources.herdr.reason")" = "herdr not on PATH" ]'

# ===========================================================================
# T6. dismiss resolves a herdr-only agent by name and by pane id; a bare role still fails.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run dismiss myrepo-architect
check "T6: dismiss <name> plans the herdr-only agent" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.member.transport_id")" = "P7" ] && [ "$(jq_ "o.member.source")" = "herdr" ]'
TOKEN6=$(plan_token)
: > "$INVOKED_LOG"
run dismiss myrepo-architect --close --confirm --plan-token "$TOKEN6"
check "T6: dismiss --close closes exactly P7" \
  '[ "$RC" -eq 0 ] && grep -q "\[\"pane\",\"close\",\"P7\"\]" "$INVOKED_LOG"'
run dismiss P7
check "T6: dismiss <pane_id> resolves the same agent" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.member.name")" = "myrepo-architect" ]'
run dismiss architect
check "T6: a bare role name still fails" '[ "$RC" -ne 0 ]'
run dismiss sid-architect-0001
check "T6: dismiss <session_id> resolves the herdr-only agent" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.member.transport_id")" = "P7" ]'
run dismiss sid-arch
check "T6: dismiss <8-char session-id prefix> resolves it too" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.member.transport_id")" = "P7" ]'
run dismiss sid-arc
check "T6: a 7-character prefix is not a session-id form" '[ "$RC" -ne 0 ]'

# ===========================================================================
# T12. An agent herdr reports with NO registered name is matched on its pane title;
#      a registered name that does not match is never overridden by a title that would.
# ===========================================================================
fresh
agents "$(agent PT myrepo-architect - "$PROJ" sid-titleonly-0001)"
run disband
check "T12: a title-only agent is matched, and how says which key matched" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].name")" = "myrepo-architect" ] && [ "$(jq_ "o.close[0].how")" = "herdr agent list (title)" ]'
fresh
agents "$(agent PU myrepo-architect foo-x "$PROJ" sid-namewins-00001)"
run disband
check "T12: a registered name wins over a matching title" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.sources.herdr.matched")" = "0" ] && [ "$(jq_ "o.reason")" = "no active team and no live peers" ]'
fresh
agents "$(agent PV some-other-title myrepo-architect "$PROJ" sid-nameonly-0001)"
run disband
check "T12: a registered name matching on its own says (name)" \
  '[ "$(jq_ "o.close[0].how")" = "herdr agent list (name)" ]'

# T12b. A title-only match is still subject to the cwd gate.
fresh
agents "$(agent PT myrepo-architect - "$OTHER" sid-titleonly-0001)"
run disband
check "T12b: a title-only agent in another checkout is excluded" \
  '[ "$(jq_ "o.sources.herdr.matched")" = "0" ]'

# ===========================================================================
# T7. teams: the herdr-only agent shows up as untracked_live.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run teams
check "T7: untracked_live lists it with source herdr and herdr's own session id" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.untracked_live.length")" = "1" ] && [ "$(jq_ "o.untracked_live[0].source")" = "herdr" ] && [ "$(jq_ "o.untracked_live[0].session_id")" = "sid-architect-0001" ] && [ "$(jq_ "o.untracked_live[0].pid===null")" = "true" ]'
check "T7: teams carries the sources block too" '[ "$(jq_ "o.sources.herdr.prefix")" = "myrepo" ]'

# ===========================================================================
# T8. With a team.json, a herdr pane outside members joins the close set as an extra.
# ===========================================================================
fresh
write_team herdr '[{"role":"reviewer","name":"myrepo-reviewer","ref":"r1","route":"peer","model":"opus","transport_id":"P3","checked_in":"2026-01-01T00:00:00Z"}]'
agents "$(agent P3 myrepo-reviewer myrepo-reviewer "$PROJ" sid-reviewer-0001)" "$(agent P9 myrepo-implementor myrepo-implementor "$PROJ" sid-implementor-01)"
run disband
check "T8: the plan holds the team member and the herdr-only extra" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "2" ] && [ "$(jq_ "o.close.map(e=>e.name).sort().join(\",\")")" = "myrepo-implementor,myrepo-reviewer" ]'
check "T8: the extra is labeled source herdr; the member is still matched to its pane" \
  '[ "$(jq_ "o.close.find(e=>e.name===\"myrepo-implementor\").source")" = "herdr" ] && [ "$(jq_ "[\"unchanged\",\"updated\"].includes(o.close.find(e=>e.name===\"myrepo-reviewer\").resync_status)")" = "true" ]'
check "T8: the team member is not duplicated by the arm" \
  '[ "$(jq_ "o.close.filter(e=>e.name===\"myrepo-reviewer\").length")" = "1" ]'

# T8b. A tmux team has no herdr topology — the arm is not even asked.
fresh
write_team tmux '[{"role":"reviewer","name":"myrepo-reviewer","ref":"r1","route":"peer","model":"opus","transport_id":"PANE1","checked_in":"2026-01-01T00:00:00Z"}]'
agents "$(agent P9 myrepo-implementor myrepo-implementor "$PROJ" sid-implementor-01)"
: > "$INVOKED_LOG"
run disband
check "T8b: a tmux team reports herdr ok:false and never execs herdr" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.sources.herdr.ok")" = "false" ] && [ "$(jq_ "o.sources.herdr.reason")" = "team transport is not herdr" ] && [ ! -s "$INVOKED_LOG" ]'
check "T8b: the herdr-only agent is not added to a tmux team's close set" \
  '[ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].name")" = "myrepo-reviewer" ]'

# ===========================================================================
# T9. The name rule: ordinals match, junk does not, --team changes the prefix.
# ===========================================================================
fresh
agents "$(agent PA myrepo-implementor-2 myrepo-implementor-2 "$PROJ" sid-impl2-000001)" "$(agent PB myrepo-implementor-x myrepo-implementor-x "$PROJ" sid-implx-000001)" "$(agent PC myrepoarchitect myrepoarchitect "$PROJ" sid-junk-0000001)"
run disband
check "T9: only the ordinal name matches" \
  '[ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].name")" = "myrepo-implementor-2" ]'
fresh
agents "$(agent PD foo-architect foo-architect "$PROJ" sid-fooarch-00001)" "$(agent PE myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)"
run disband --team foo
check "T9: --team foo matches foo-architect only" \
  '[ "$(jq_ "o.sources.herdr.prefix")" = "foo" ] && [ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].name")" = "foo-architect" ]'

# ===========================================================================
# T11. The pane running the command is never in its own close set.
# ===========================================================================
fresh
agents "$(agent P7 myrepo-architect myrepo-architect "$PROJ" sid-architect-0001)" "$(agent P6 myrepo-reviewer myrepo-reviewer "$PROJ" sid-reviewer-0001)"
run_self P7 disband
check "T11: HERDR_PANE_ID is excluded from the close set" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "1" ] && [ "$(jq_ "o.close[0].transport_id")" = "P6" ]'

# ===========================================================================
# T13. No git root for this command: an agent that reports a cwd cannot be verified, so it is
#      excluded; one that reports none is unaffected.
# ===========================================================================
NOGIT="$SANDBOX/nogit"
mkdir -p "$NOGIT/.claude/hierarchy"
run_nogit() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" node "$H/roster.mjs" "$@" --cwd "$NOGIT" 2>&1); RC=$?; }
agents "$(agent PW nogit-architect nogit-architect "$NOGIT" sid-nogit-00000001)"
run_nogit disband
check "T13: with no git root, an agent reporting a cwd is excluded" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.sources.herdr.prefix")" = "nogit" ] && [ "$(jq_ "o.sources.herdr.matched")" = "0" ]'
agents "$(agent PW nogit-architect nogit-architect - sid-nogit-00000001)"
run_nogit disband
check "T13: an agent reporting no cwd still matches" '[ "$(jq_ "o.sources.herdr.matched")" = "1" ]'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
