#!/bin/bash
# agent-hierarchy — a team ends with its last member, and a member whose planned name a live
# session already holds (`--names-in-use`) is renamed, on create, spawn-one and spawn-ad-hoc; the
# route gate steers a plain SendMessage off the name a member was renamed away from, and the
# ultra-gate gates an advise-class member by its recorded name.
# HOME- and AGENT_HIERARCHY_DIR-redirected; herdr is a fake that records its calls; no test
# reaches the real herdr, tmux, or ~/.claude.
# Usage: bash tests/test-team-lifecycle-names.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
UGATE="$H/pretooluse-ultra-gate.mjs"
SKILL="$PLUGIN/skills/agent-team/SKILL.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-lifecycle-names-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/claude"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux" "$SANDBOX/nolaunch/claude"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
FAKEHOME="$SANDBOX/home"
NODE_DIR="$(dirname "$(command -v node)")"
FAKE_STATE_DIR="$SANDBOX/state"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500} STDERR=${STDERR:0:300})"; fi
}

# ---- fake herdr: splits panes, starts agents, closes panes; every call is recorded.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/herdr" <<EOF
#!$(command -v node)
$(cat <<'FAKEEOF'
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const dir = process.env.FAKE_STATE_DIR;
fs.mkdirSync(path.join(dir, "calls"), { recursive: true });
function finish(code) {
  fs.writeFileSync(path.join(dir, "calls", `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`), JSON.stringify({ argv: args, exit: code }));
  process.exit(code);
}
const geomFile = path.join(dir, "geometry.json");
if (args[0] === "pane" && args[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  console.log(JSON.stringify({ result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } }));
  finish(0);
}
if (args[0] === "pane" && args[1] === "split") {
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const target = args[args.indexOf("--pane") + 1];
  const rect = s.panes[target];
  const newId = `p${s.nextId++}`;
  const w1 = Math.floor(rect.width / 2);
  s.panes[target] = { ...rect, width: w1 };
  s.panes[newId] = { ...rect, width: rect.width - w1, x: rect.x + w1 };
  fs.writeFileSync(geomFile, JSON.stringify(s));
  console.log(JSON.stringify({ result: { pane: { pane_id: newId } } }));
  finish(0);
}
if (args[0] === "agent" && args[1] === "start") {
  console.log(JSON.stringify({ result: { pane: { pane_id: "target" }, agent: { name: args[2], ready: true } } }));
  finish(0);
}
if (args[0] === "pane" && (args[1] === "close" || args[1] === "rename")) {
  console.log(JSON.stringify({ result: {} }));
  finish(0);
}
process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

reset_state() {
  rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"
  echo '{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}' > "$FAKE_STATE_DIR/geometry.json"
}
calls() { # <argv[0]> <argv[1]> — how many herdr calls of that shape were made
  node -e 'const fs=require("fs"),d=process.argv[1]+"/calls";let n=0;try{for(const f of fs.readdirSync(d)){const c=JSON.parse(fs.readFileSync(d+"/"+f,"utf8"));if(c.argv[0]===process.argv[2]&&c.argv[1]===process.argv[3])n++}}catch{}console.log(n)' "$FAKE_STATE_DIR" "$1" "$2"; }
started() { # the names herdr was asked to start, comma-joined
  node -e 'const fs=require("fs"),d=process.argv[1]+"/calls";const n=[];try{for(const f of fs.readdirSync(d)){const c=JSON.parse(fs.readFileSync(d+"/"+f,"utf8"));if(c.argv[0]==="agent"&&c.argv[1]==="start")n.push(c.argv[2])}}catch{}console.log(n.sort().join(","))' "$FAKE_STATE_DIR"; }

new_repo() { # <name>: PROJ, CFG, HD (the hierarchy dir every command and gate here reads), fresh
  PROJ="$SANDBOX/$1"; rm -rf "$PROJ"; mkdir -p "$PROJ/.claude"; (cd "$PROJ" && git init -q)
  CFG="$PROJ/.claude/agent-hierarchy.json"; HD="$SANDBOX/hier-$1"; rm -rf "$HD"; mkdir -p "$HD"
  rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME/.claude"; reset_state
}
roster_q() { env -u HERDR_ENV -u CLAUDE_PID HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" "$@" --cwd "$PROJ" >/dev/null 2>&1; }
setup_roster() { # <roles...>: a repo-level default roster, every member on opus
  roster_q init --level repo --route peer
  for r in "$@"; do roster_q add --no-spawn --level repo --role "$r" --model opus; done
}
run_r() { # a plain (non-herdr) roster call: stdout in OUT, stderr in STDERR
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
run_h() { # a roster call under the fake herdr
  OUT=$(env HERDR_ENV=1 HERDR_PANE_ID=p0 HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" CLAUDE_PID=$$ PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
jq_out() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{o=JSON.parse(s.slice(s.indexOf("{")))}process.stdout.write(String((new Function("o","return "+process.argv[1]))(o)))})' "$1" 2>/dev/null; }
jq_file() { node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((new Function("t","return "+process.argv[2]))(t)))' "$1" "$2" 2>/dev/null; }

rec() { # <name> <role> [extra json fields]: one claude-kind peer member record
  printf '{"role":"%s","name":"%s","route":"peer","model":"opus","transport_id":"pane-%s"%s}' "$2" "$1" "$1" "${3:+,$3}"; }
write_team() { # <team> <session id|""> <member json>...: a live herdr team this test's shell owns
  local team=$1 sid=$2; shift 2
  local members; members=$(IFS=,; echo "$*")
  local sidj="null"; [ -n "$sid" ] && sidj="\"$sid\""
  mkdir -p "$HD/teams"
  printf '{"version":1,"team_id":"t-%s","created":"%s","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":%s,"pid":%s},"members":[%s],"partial":false,"expected_root":"%s","roster":null,"layout":"auto"}' \
    "$team" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sidj" "${OWNER_PID:-$$}" "$members" "$PROJ" > "$HD/teams/$team.json"
}
seed_up() { # <name> <role>: a live peers.jsonl record for that session name
  node -e 'const fs=require("fs");const[f,n,r,p]=process.argv.slice(1);fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",name:n,role:r,pid:Number(p),ts:new Date().toISOString()})+"\n");' "$HD/peers.jsonl" "$1" "$2" "$$"; }
arch_records() { jq_file "$HD/teams/x.json" 't.members.filter(m=>m.role==="architect").map(m=>m.name+"<"+(m.renamed_from||"")).join(",")'; }

send_payload() { # <session> <to> <message>
  node -e 'const[s,t,m,cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "$1" "$2" "$3" "$PROJ"; }
agent_payload() { # <session> <subagent_type>
  node -e 'const[s,t,cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd,tool_name:"Agent",tool_input:{subagent_type:t,prompt:"x"}}));' "$1" "$2" "$PROJ"; }
gate() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
ugate() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$UGATE" 2>&1); RC=$?; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
BRIEF='[hierarchy-peer-brief reply-to="me" task="x"]
plain'

# ============================================================ any: an empty team's refusal
# A bare create against this session's own team gets the generic refusal; against a default-scope
# team another live orchestrator (this test's parent shell) holds, it gets refuseLiveDefaultTeam.
new_repo any1; setup_roster architect
write_team any1 ""
run_r create --plan
check "any (owned): create --plan's generic refusal says the team has no members and names disband" \
  '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "a live Team t-any1 already exists but has no members — disband it first"'
write_team any1 "" "$(rec any1-architect architect)"
run_r create --plan
check "any (owned control): with members the generic refusal is unchanged" \
  '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "a live Team t-any1 already exists — disband it first"'
OWNER_PID=$PPID write_team any1 ""
run_r create --plan
check "any: create --plan refuses a live empty team at the default scope, saying it has no members and naming disband" \
  '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "but it has no members: \`disband\` ends it" && ! echo "$STDERR" | grep -q "members are dispatched"'
OWNER_PID=$PPID write_team any1 "" "$(rec any1-architect architect)"
run_r create --plan
check "any (control): a team with members still says its members are dispatched" \
  '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "members are dispatched under that prefix"'

# ============================================================ L: the last departure ends the team
new_repo l1; setup_roster architect
run_h spawn-ad-hoc reviewer --model opus --team walk
check "L1: spawn-ad-hoc --team walk stands up a one-member team" '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/walk.json" "t.members.map(m=>m.name).join()")" = "walk-reviewer" ]'
run_h dismiss walk-reviewer --team walk
TOKEN=$(jq_out o.close_token)
check "L1: the dismiss plan for the last member shows team_will_be_removed:true" '[ "$RC" -eq 0 ] && [ "$(jq_out o.team_will_be_removed)" = "true" ]'
run_h dismiss walk-reviewer --close --confirm --plan-token "$TOKEN" --team walk
check "L1: dismiss --close of the last member removes teams/walk.json and reports team_removed:true" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.team_removed)" = "true" ] && [ "$(jq_out o.closed)" = "true" ] && [ ! -e "$HD/teams/walk.json" ]'
check "L1: no history row is written" '[ ! -e "$HD/team-history.json" ]'
run_r create --team walk --plan
check "L1: a following create --team walk --plan succeeds" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "walk-architect" ]'

new_repo l2
run_h spawn-ad-hoc reviewer --model opus --team walk
run_h spawn-ad-hoc implementor --model opus --team walk
run_h dismiss walk-reviewer --team walk
TOKEN=$(jq_out o.close_token)
check "L2: the plan for a member that is not the last has no team_will_be_removed" '[ "$RC" -eq 0 ] && [ "$(jq_out "\"team_will_be_removed\" in o")" = "false" ]'
run_h dismiss walk-reviewer --close --confirm --plan-token "$TOKEN" --team walk
check "L2: dismissing a member that is not the last keeps the rest and reports no team_removed" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "\"team_removed\" in o")" = "false" ] && [ "$(jq_file "$HD/teams/walk.json" "t.members.map(m=>m.name).join()")" = "walk-implementor" ]'

new_repo l3
write_team x "" "$(rec x-architect architect)"
seed_up x-architect architect
run_h untrack x-architect --commit --keep-sessions --team x
check "L3: untrack of the last member clears the file and reports team_removed:true, team_empty still reported" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.team_removed)" = "true" ] && [ "$(jq_out o.team_empty)" = "true" ] && [ ! -e "$HD/teams/x.json" ]'
check "L3: the session is untouched (no pane close) and the old warning is replaced by the removal notice" \
  '[ "$(calls pane close)" = "0" ] && echo "$STDERR" | grep -q "team t-x has no members left, so it was removed" && ! echo "$STDERR" | grep -q "If you meant to end the team entirely"'

# ============================================================ N1-N5: create
new_repo n1; setup_roster architect reviewer implementor
run_r create --team x --plan
check "N1 (control): with no --names-in-use the plan has the derived names and no renamed_members" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "x-architect,x-reviewer,x-implementor" ] && [ "$(jq_out "\"renamed_members\" in o")" = "false" ]'
run_r create --team x --plan --names-in-use x-architect
check "N1: the architect becomes x-architect-2, the others keep their names, renamed_members says so" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "x-architect-2,x-reviewer,x-implementor" ] && [ "$(jq_out "JSON.stringify(o.renamed_members)")" = "[{\"name\":\"x-architect-2\",\"role\":\"architect\",\"renamed_from\":\"x-architect\"}]" ]'
run_r create --team x --plan --names-in-use x-architect --names-in-use x-architect-2
check "N1: with x-architect-2 also in use, the architect is x-architect-3" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members[0].name")" = "x-architect-3" ]'

new_repo n2; setup_roster architect architect
run_r create --team x --plan --names-in-use x-architect
check "N2: two architects, plain name in use: the first becomes x-architect-3 and the second stays x-architect-2" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "x-architect-3,x-architect-2" ]'

new_repo n3; setup_roster architect
run_r create --team x --plan --names-in-use x-architect-2
check "N3: only an exact match collides: x-architect-2 in use leaves x-architect alone" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "x-architect" ] && [ "$(jq_out "\"renamed_members\" in o")" = "false" ]'

new_repo n4; setup_roster architect
LONG=abcdefghijklmnopqrstu
run_h create --team "$LONG" --plan
check "N4 (control): a 21-character team name fits Herdr's limit unrenamed" '[ "$RC" -eq 0 ]'
run_h create --team "$LONG" --plan --names-in-use "$LONG-architect"
check "N4: the suffix breaks Herdr's limit: team-name-unusable, failing_member is the suffixed member" \
  '[ "$RC" -eq 2 ] && [ "$(jq_out "[o.refused,o.failing_member.name].join()")" = "team-name-unusable,$LONG-architect-2" ]'
SUGGESTION=$(jq_out o.suggestion)
run_h create --team "$SUGGESTION" --plan --names-in-use "$LONG-architect"
check "N4: the refusal suggests a different name, fitted to the renamed member, and a re-plan with it succeeds" \
  '[ -n "$SUGGESTION" ] && [ "$SUGGESTION" != "$LONG" ] && [ "$RC" -eq 0 ]'

new_repo n5; setup_roster architect reviewer
ROSTER_SUM=$(cksum < "$CFG")
run_h create --team x --spawn --names-in-use x-architect
check "N5: --spawn launches x-architect-2 and reports renamed_members; its member objects carry no renamed_from" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-2,x-reviewer" ] && [ "$(jq_out "o.renamed_members.map(m=>m.name+\"<\"+m.renamed_from).join()")" = "x-architect-2<x-architect" ] && [ "$(jq_out "o.members.some(m=>\"renamed_from\" in m)")" = "false" ]'
run_h create --team x --commit --verified '["x-architect-2","x-reviewer"]' --transport herdr --roster-level repo
check "N5 (control): without --names-in-use, hydration by name does not know x-architect-2" '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "names no member \"x-architect-2\""'
run_h create --team x --commit --verified '["x-architect-2","x-reviewer"]' --transport herdr --roster-level repo --names-in-use x-architect
check "N5: --commit hydrates x-architect-2 by name and records renamed_from:x-architect" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/x.json" "t.members.map(m=>m.name+\"<\"+(m.renamed_from||\"\")).join()")" = "x-architect-2<x-architect,x-reviewer<" ] && [ "$(jq_out "o.renamed_members.length")" = "1" ]'
check "N5: the roster file is byte-identical" '[ "$(cksum < "$CFG")" = "$ROSTER_SUM" ]'
check "N5: the history entry carries no names" '[ -e "$HD/team-history.json" ] && ! grep -q "x-architect" "$HD/team-history.json" && [ "$(jq_file "$HD/team-history.json" "t.teams.every(e=>e.members.every(m=>!(\"name\" in m)))")" = "true" ]'
run_h create --team x --commit --verified '[{"role":"architect","name":"x-architect-2","route":"peer","model":"opus","transport_id":"p1"},{"role":"reviewer","name":"x-reviewer","route":"peer","model":"opus","transport_id":"p2"}]' --transport herdr --roster-level repo --names-in-use x-architect
check "N5 (objects): --commit stamps renamed_from on the verified member object whose name and role match a rename" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/x.json" "t.members.map(m=>m.name+\"<\"+(m.renamed_from||\"\")).join()")" = "x-architect-2<x-architect,x-reviewer<" ]'
run_h create --team x --commit --verified '[{"role":"architect","name":"x-architect-2","route":"peer","model":"opus","transport_id":"p1","renamed_from":"x-bogus"},{"role":"reviewer","name":"x-reviewer","route":"peer","model":"opus","transport_id":"p2","renamed_from":"x-ultra-advisor"}]' --transport herdr --roster-level repo --names-in-use x-architect
check "N5 (objects): a caller-supplied renamed_from is replaced by the commit's own rename, or dropped when it made none" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/x.json" "t.members.map(m=>m.name+\"<\"+(m.renamed_from||\"\")).join()")" = "x-architect-2<x-architect,x-reviewer<" ] && [ "$(jq_out "JSON.stringify(o.renamed_members)")" = "[{\"name\":\"x-architect-2\",\"role\":\"architect\",\"renamed_from\":\"x-architect\"}]" ]'

# ============================================================ N6, N18, N7, N14: the gates
new_repo n6
write_team x s6 "$(rec x-architect-2 architect '"renamed_from":"x-architect"')" "$(rec x-reviewer reviewer)"
RENAMED_TEXT='x-architect is not in your team; its Architect is x-architect-2. SendMessage \"x-architect-2\". To reach the other session on purpose, address it with its [ref].'
gate "$(send_payload s6 x-architect hello)"
check "N6: an Orchestrator SendMessage to x-architect is denied, naming x-architect-2" 'denied && echo "$OUT" | grep -qF "$RENAMED_TEXT"'
gate "$(send_payload s6 "x-architect [abc123]" hello)"
check "N6: to:\"x-architect [abc123]\" passes" 'allowed'
gate "$(send_payload s6 x-architect-2 hello)"
check "N6: to:\"x-architect-2\" passes the rename check" 'allowed'
gate "$(send_payload s-other x-architect hello)"
check "N6 (scope): a session whose resolved team is not x is not denied" 'allowed'
gate "$(send_payload s6 x-architect "$BRIEF")"
check "N18: the deny also fires for a SendMessage carrying the brief sentinel" 'denied && echo "$OUT" | grep -qF "$RENAMED_TEXT"'

new_repo n7
write_team x su "$(rec x-ultra-advisor-2 ultra-advisor '"renamed_from":"x-ultra-advisor"')" "$(rec x-reviewer-2 reviewer)"
ugate "$(send_payload su x-ultra-advisor-2 hello)"
check "N7: a SendMessage to a renamed Ultra-Advisor x-ultra-advisor-2 is gated (first-use deny)" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'
ugate "$(send_payload su x-reviewer-2 hello)"
check "N7 (control): a SendMessage to a recorded reviewer is not gated" 'allowed'
write_team x su "$(rec x-ultra-advisor ultra-advisor)" "$(rec x-ultra-advisor-2 ultra-advisor)"
ugate "$(send_payload su x-ultra-advisor-2 hello)"
check "N7: an unrenamed second instance x-ultra-advisor-2 is gated too" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'
# A record under a prefix no gated prefix derives (one left from an older team name) is caught
# only by the record lookup, not by the <prefix>-<role>-<n> pattern.
write_team x su "$(rec old-ultra-advisor ultra-advisor)"
ugate "$(send_payload su old-ultra-advisor hello)"
check "N7: a recorded Ultra-Advisor whose name no gated prefix derives is gated by the record lookup" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'
rm -f "$HD/teams/x.json"
write_team T sT "$(rec T-reviewer reviewer)"
write_team U sU "$(rec U-ultra-advisor-2 ultra-advisor '"renamed_from":"U-ultra-advisor"')" "$(rec old-ultra-advisor ultra-advisor)"
ugate "$(send_payload sT U-ultra-advisor-2 hello)"
check "N7: team T's resolved Orchestrator is not gated to sibling team U's renamed U-ultra-advisor-2" 'allowed'
ugate "$(send_payload sT old-ultra-advisor hello)"
check "N7: nor to U's recorded old-ultra-advisor" 'allowed'
ugate "$(send_payload s-unresolved U-ultra-advisor-2 hello)"
check "N7: a session that resolves no team, with T and U present, is gated to U-ultra-advisor-2" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'
ugate "$(send_payload s-unresolved old-ultra-advisor hello)"
check "N7: and to U's recorded old-ultra-advisor, through the record lookup over every team" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'

new_repo q; setup_roster ultra-advisor
run_h create --spawn --names-in-use q-ultra-advisor
check "N7b setup: create --spawn launches q-ultra-advisor-2 and writes no team file" '[ "$RC" -eq 0 ] && [ "$(started)" = "q-ultra-advisor-2" ] && [ ! -e "$HD/teams" ] && [ ! -e "$HD/team.json" ]'
for to in q-ultra-advisor-2 "q-ultra-advisor-2 [abc123]" q-ultra-advisor-3; do
  ugate "$(send_payload s-q "$to" hello)"
  check "N7b: with no team file, a SendMessage to \"$to\" is gated by the suffixed-name pattern" 'denied && echo "$OUT" | grep -q "Ultra-Advisor escalation is user-gated"'
done
for to in q-ultra-advisor-2x q-ultra-advisor-2-architect q-architect-2; do
  ugate "$(send_payload s-q "$to" hello)"
  check "N7b: \"$to\" is not gated by the pattern" 'allowed'
done
write_team T sT "$(rec T-reviewer reviewer)"
write_team U sU "$(rec U-reviewer reviewer)"
ugate "$(send_payload sT U-ultra-advisor-2 hello)"
check "N7b (scope): T's resolved Orchestrator is not gated to an unrecorded U-ultra-advisor-2" 'allowed'

new_repo n14
write_team x s14 "$(rec x-reviewer reviewer)"
gate "$(agent_payload s14 ah:architect)"
check "N14: the spawnReason carries the ListAgents / --names-in-use line with the team prefix, right after Run:" \
  'denied && [ "$(printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const l=JSON.parse(s).hookSpecificOutput.permissionDecisionReason.split(\"\\n\");const i=l.findIndex(x=>x.startsWith(\"Run: \"));console.log(l[i+1])})")" = "Before running it, run ListAgents and add \`--names-in-use <name>\` for every live name that starts with \`x-\`." ]'

# ============================================================ N9-N13, N15-N17: spawn verbs
new_repo n9; setup_roster architect
run_h spawn-one architect --team x --names-in-use x-architect
check "N9: spawn-one with no record launches x-architect-2, recorded with renamed_from:x-architect, and reports it" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-2" ] && [ "$(arch_records)" = "x-architect-2<x-architect" ] && [ "$(jq_out "JSON.stringify(o.renamed_members)")" = "[{\"name\":\"x-architect-2\",\"role\":\"architect\",\"renamed_from\":\"x-architect\"}]" ]'

new_repo n10; setup_roster architect
for flags in "" "--names-in-use x-architect"; do
  write_team x "" "$(rec x-architect-2 architect '"renamed_from":"x-architect"')"; reset_state
  run_h spawn-one architect --team x $flags
  check "N10 (${flags:-no flag}): a dead renamed record respawns as x-architect-2, in place, renamed_from kept, nothing reported as renamed" \
    '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-2" ] && [ "$(arch_records)" = "x-architect-2<x-architect" ] && [ "$(jq_out "\"renamed_members\" in o")" = "false" ]'
done
write_team x "" "$(rec x-architect-2 architect '"renamed_from":"x-architect"')"; reset_state
seed_up x-architect-2 architect
run_h spawn-one architect --team x --names-in-use x-architect
check "N10: a live renamed record gets today's already-live refusal" '[ "$RC" -eq 0 ] && [ "$(jq_out o.reason)" = "already live" ] && [ "$(started)" = "" ]'

new_repo n11; setup_roster architect
write_team x "" "$(rec x-architect-2 architect '"renamed_from":"x-architect"')"
run_h dismiss x-architect-2 --team x
run_h dismiss x-architect-2 --close --confirm --plan-token "$(jq_out o.close_token)" --team x
check "N11: dismissing x-architect-2 ends its record" '[ "$RC" -eq 0 ] && [ ! -e "$HD/teams/x.json" ]'
run_h spawn-one architect --team x --names-in-use x-architect
check "N11: spawn-one with the outside name in use gives x-architect-2 with a fresh renamed_from" '[ "$RC" -eq 0 ] && [ "$(arch_records)" = "x-architect-2<x-architect" ]'
rm -f "$HD/teams/x.json"; reset_state
run_h spawn-one architect --team x
check "N11: with the outside name absent it gives the plain x-architect, with no renamed_from" '[ "$RC" -eq 0 ] && [ "$(arch_records)" = "x-architect<" ]'

new_repo n12; setup_roster reviewer
write_team x "" "$(rec x-reviewer reviewer)"
seed_up x-reviewer reviewer
run_h spawn-one reviewer --team x --names-in-use x-reviewer
check "N12: a live own member named in --names-in-use gets today's already-live refusal, no rename, no launch" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.reason)" = "already live" ] && [ "$(jq_out o.member.name)" = "x-reviewer" ] && [ "$(started)" = "" ] && [ "$(jq_file "$HD/teams/x.json" "t.members.map(m=>m.name+\"<\"+(m.renamed_from||\"\")).join()")" = "x-reviewer<" ]'

new_repo n13
write_team x "" "$(rec x-implementor implementor)" "$(rec x-implementor-2 implementor)"
run_h spawn-ad-hoc implementor --model opus --team x --names-in-use x-implementor-3
check "N13: spawn-ad-hoc renames the derived x-implementor-3 to x-implementor-4, recorded and reported" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-implementor-4" ] && [ "$(jq_file "$HD/teams/x.json" "t.members.map(m=>m.name+\"<\"+(m.renamed_from||\"\")).join()")" = "x-implementor<,x-implementor-2<,x-implementor-4<x-implementor-3" ] && [ "$(jq_out "o.renamed_members.map(m=>m.name+\"<\"+m.renamed_from).join()")" = "x-implementor-4<x-implementor-3" ]'
check "N13: no -n-n name is ever produced" '! grep -qE "implementor-[0-9]+-[0-9]+" "$HD/teams/x.json" && ! echo "$OUT" | grep -qE "implementor-[0-9]+-[0-9]+"'

new_repo n15; setup_roster architect
write_team x "" "$(rec x-architect-2 architect '"renamed_from":"x-architect"')"
run_h spawn-one architect --team x --names-in-use x-architect --names-in-use x-architect-2
check "N15: a dead renamed record whose name another session took is renamed in place to x-architect-3, renamed_from still x-architect" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-3" ] && [ "$(arch_records)" = "x-architect-3<x-architect" ] && [ "$(jq_out "JSON.stringify(o.renamed_members)")" = "[{\"name\":\"x-architect-3\",\"role\":\"architect\",\"renamed_from\":\"x-architect\"}]" ]'
write_team x "" "$(rec x-architect architect)"; reset_state
run_h spawn-one architect --team x --names-in-use x-architect
check "N15 (plain): a dead plain record whose name is in use becomes x-architect-2 with renamed_from:x-architect, in place" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-2" ] && [ "$(arch_records)" = "x-architect-2<x-architect" ]'
write_team x "" "$(rec x-architect architect)"; reset_state
seed_up x-architect architect
run_h spawn-one architect --team x --names-in-use x-architect
check "N15 (live): the same record live gets today's already-live refusal, with no rename" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.reason)" = "already live" ] && [ "$(started)" = "" ] && [ "$(arch_records)" = "x-architect<" ]'

new_repo n16; setup_roster architect architect
run_h spawn-one architect --team x --names-in-use x-architect
check "N16: two architects, no records: the first launches as x-architect-3 with renamed_from:x-architect" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-3" ] && [ "$(arch_records)" = "x-architect-3<x-architect" ]'
rm -f "$HD/teams/x.json"; reset_state
run_h spawn-one architect --team x --names-in-use x-architect --member x-architect-2
check "N16: --member x-architect-2 launches the second architect unrenamed, on its own record" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-2" ] && [ "$(arch_records)" = "x-architect-2<" ]'
rm -f "$HD/teams/x.json"; reset_state
run_h spawn-one architect --team x --names-in-use x-architect --member x-architect
check "N16: --member x-architect fails, listing the final names" '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "it defines: x-architect-3, x-architect-2" && [ "$(started)" = "" ]'

new_repo n17; setup_roster architect architect
write_team x s17 "$(rec x-architect-2 architect '"renamed_from":"x-architect"')"
seed_up x-architect-2 architect
BEFORE=$(jq_file "$HD/teams/x.json" 'JSON.stringify(t.members[0])')
run_h spawn-one architect --team x
check "N17: the second architect's derived x-architect-2 is claimed by the first: it launches as x-architect-3, renamed_from:x-architect-2" \
  '[ "$RC" -eq 0 ] && [ "$(started)" = "x-architect-3" ] && [ "$(arch_records)" = "x-architect-2<x-architect,x-architect-3<x-architect-2" ]'
check "N17: the x-architect-2 record is untouched" '[ "$(jq_file "$HD/teams/x.json" "JSON.stringify(t.members[0])")" = "$BEFORE" ]'
gate "$(send_payload s17 x-architect-2 hello)"
check "N17: SendMessage to x-architect-2 passes the rename check: the name is a current record of the team" 'allowed'

# ============================================================ K1: the agent-team skill
SK=$(cat "$SKILL")
LA=$(grep -n "Names already in use — before the team-name question" "$SKILL" | cut -d: -f1)
TQ=$(grep -n "Team name — one question, every create" "$SKILL" | cut -d: -f1)
check "K1: the skill runs ListAgents before the team-name question" '[ -n "$LA" ] && [ -n "$TQ" ] && [ "$LA" -lt "$TQ" ] && echo "$SK" | grep -q "Call\$" && echo "$SK" | grep -q "^   \`ListAgents\` once, before asking the team-name question"'
check "K1: it compares exact names with [ref] stripped" 'echo "$SK" | grep -q "with$" && echo "$SK" | grep -q "any trailing \`\[ref\]\` stripped. Only exact names count"'
check "K1: it labels the renames in the question" 'echo "$SK" | grep -qF "the option for a name with renames carries" && echo "$SK" | grep -qF "claudetools-architect-2)\"."'
check "K1: it captures the set once, passes it unchanged to every later phase, and never re-reads after --spawn" \
  'echo "$SK" | grep -qF "capture that name'"'"'s set **once** and" && echo "$SK" | grep -qF "pass it **unchanged** to every later phase" && echo "$SK" | grep -qF "Never re-read \`ListAgents\` for the set after \`--spawn\`"'
check "K1: it gives the one-line rename notice, for create and for spawn-one/spawn-ad-hoc" \
  'echo "$SK" | grep -qF "\"Renamed <renamed_from> → <name> (and …): another session" && echo "$SK" | grep -qF "already holds that name.\" The same line follows a \`spawn-one\` or"'

check "K1: the create check-in matches each member's name as --spawn printed it, renamed or not" \
  'echo "$SK" | grep -qF "match each member'"'"'s \`name\` as" && echo "$SK" | grep -qF "\`--spawn\` printed it (renamed or not). **Poll every 2 seconds"'
check "K1: --member is described as taking the final name" \
  'echo "$SK" | grep -qF "\`--member <name>\` targets one specific same-role instance by its" && echo "$SK" | grep -qF "final name, as spawn output or the team record shows it (renamed or not)."'
DERIVED_STEPS=$(node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8").replace(/\s+/g," ");console.log(t.split(/(?<=[.;:])\s/).filter(s=>/\b(match|check|verif|select|target|address)\w*\b/i.test(s)&&/derived (member )?names?\b/i.test(s)).join("\n"))' "$SKILL")
check "K1: no step matches, checks, verifies or selects a member by its derived name" '[ -z "$DERIVED_STEPS" ] || { echo "$DERIVED_STEPS"; false; }'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
