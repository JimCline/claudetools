#!/bin/bash
# agent-hierarchy — follow-up hygiene: a roster row that is not an object is skipped at read and
# cleaned by the next write; an orphaned team that live sessions depend on is reported by teams and
# reap, and kept by reap --commit; a member launched into a team file must carry that team's
# prefix; and whether a team is partial is derived from its roster when it is shown.
# HOME- and AGENT_HIERARCHY_DIR-redirected; herdr is a fake that records its calls; no test
# reaches the real herdr, tmux, or ~/.claude.
# Usage: bash tests/test-follow-up-hygiene.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports its own; a test must not inherit it — each call below passes the pid it needs

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
SKILL="$PLUGIN/skills/agent-team/SKILL.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-follow-up-hygiene-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/claude"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux" "$SANDBOX/nolaunch/claude"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AGENT_HIERARCHY_DIR
FAKEHOME="$SANDBOX/home"
NODE_DIR="$(dirname "$(command -v node)")"
FAKE_STATE_DIR="$SANDBOX/state"
PASS=0; FAIL=0
# A pid that is certainly dead: the owner of every orphaned team below.
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"

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
if (args[0] === "agent" && args[1] === "list") {
  const f = path.join(dir, "agents.json");
  console.log(JSON.stringify({ id: "cli:agent:list", result: { agents: fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : [] } }));
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
seed_sid() { # <name|""> <role> <session id> [team] [pane]: a live peers.jsonl up row
  node -e 'const fs=require("fs");const[f,n,r,s,t,p,pid]=process.argv.slice(1);const o={type:"peer",status:"up",role:r,session_id:s,pid:Number(pid),ts:new Date().toISOString()};if(n)o.name=n;if(t)o.team=t;if(p)o.pane_id=p;fs.appendFileSync(f,JSON.stringify(o)+"\n");' "$HD/peers.jsonl" "$1" "$2" "$3" "${4:-}" "${5:-}" "$$"; }
seed_down() { # <session id> <role> [team]: that session's row goes down
  node -e 'const fs=require("fs");const[f,s,r,t,pid]=process.argv.slice(1);const o={type:"peer",status:"down",role:r,session_id:s,pid:Number(pid),ts:new Date().toISOString()};if(t)o.team=t;fs.appendFileSync(f,JSON.stringify(o)+"\n");' "$HD/peers.jsonl" "$1" "$2" "${3:-}" "$$"; }
pending() { # <session id> <from_name>: a brief a hook filed for that session
  mkdir -p "$FAKEHOME/.claude"
  node -e 'const fs=require("fs");const[f,s,n]=process.argv.slice(1);fs.appendFileSync(f,JSON.stringify({session_id:s,from:"orchestrator",from_name:n,reply_to:n,ts:new Date().toISOString()})+"\n");' "$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl" "$1" "$2"; }
run_nopid() { # a roster call with no orchestrator pid at all
  OUT=$(env -u HERDR_ENV -u CLAUDE_PID HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
agent_payload() { # <session> <subagent_type>
  node -e 'const[s,t,cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd,tool_name:"Agent",tool_input:{subagent_type:t,prompt:"x"}}));' "$1" "$2" "$PROJ"; }
gate() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }

# ============================================================ R: roster rows that are not objects
new_repo r1
printf '{"version":1,"enabled":true,"roster":{"route":"peer","members":[null,{"role":"architect","model":"opus"},7]}}\n' > "$CFG"
run_r create --plan
check "R1: create --plan exits 0 with r1-architect as the only member" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = "r1-architect" ]'
check "R1: create --plan's warnings name members[0] (null) and members[2] (number)" \
  '[ "$(jq_out "o.warnings.filter(w=>w.includes(\"is not an object\")).join(\"|\")")" = "roster \`$CFG\`: \`members[0]\` is not an object (\`null\`); ignored|roster \`$CFG\`: \`members[2]\` is not an object (\`number\`); ignored" ]'
run_h spawn-one architect --dry-run
check "R1: spawn-one --dry-run exits 0 and plans r1-architect" '[ "$RC" -eq 0 ] && [ "$(jq_out o.name)" = "r1-architect" ]'
run_r show
check "R1: show exits 0" '[ "$RC" -eq 0 ] && ! echo "$STDERR" | grep -q TypeError'
run_r teams
check "R1: teams exits 0" '[ "$RC" -eq 0 ]'
run_r doctor
DOCTOR_RC=$RC
check "R1: doctor names both elements and does not crash" 'echo "$OUT" | grep -qF "\`members[0]\` is not an object (\`null\`); ignored" && echo "$OUT" | grep -qF "\`members[2]\` is not an object (\`number\`); ignored" && ! echo "$STDERR" | grep -q TypeError'
OUT=$(cd "$PROJ" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/lib-config.mjs" 2>&1); RC=$?
check "R1: the status report exits 0 and names both elements" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -qF "\`members[0]\` is not an object (\`null\`)" && echo "$OUT" | grep -qF "\`members[2]\` is not an object (\`number\`)"'
gate "$(agent_payload r1s ah:architect)"
GATE_BAD=$OUT
printf '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}\n' > "$CFG"
gate "$(agent_payload r1s ah:architect)"
check "R1: the route gate's decision is the same with and without the bad elements, and nothing is logged" \
  'denied && [ "$GATE_BAD" = "$OUT" ] && [ ! -s "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl" ]'
run_r doctor
check "R1: doctor's exit code is the one it has without the bad elements" '[ "$RC" -eq "$DOCTOR_RC" ]'

printf '{"version":1,"roster":{"route":"peer","members":[null,{"role":"architect","model":"opus"},7]}}\n' > "$CFG"
run_r add --no-spawn --level repo --role reviewer --model opus
check "R2: add rewrites the file without the bad elements" '[ "$RC" -eq 0 ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members.map(m=>m.role))")" = "[\"architect\",\"reviewer\"]" ]'
check "R2: ...and lists them under migrated" '[ "$(jq_out "o.migrated.map(c=>c.key).join()")" = "roster.members[0],roster.members[2]" ]'
printf '{"version":1,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"},"x",[1],true]}}\n' > "$CFG"
run_r edit --member r1-architect --model sonnet --level repo
check "R2: edit rewrites the file without the bad elements (string, array, boolean)" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members)")" = "[{\"role\":\"architect\",\"model\":\"sonnet\"}]" ]'

# ============================================================ O: an orphaned team that live sessions depend on
new_repo o1; setup_roster architect reviewer
OWNER_PID=$DEAD write_team o1 "" "$(rec o1-architect architect)" "$(rec o1-reviewer reviewer)"
seed_sid o1-architect architect sid-a1 o1
pending sid-a1 orch-a
run_r teams
check "O1: teams lists only the live record under live_members, with who last briefed it" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "JSON.stringify(o.teams.find(t=>t.name===\"o1\").live_members)")" = "[{\"name\":\"o1-architect\",\"role\":\"architect\",\"last_brief_from\":\"orch-a\"}]" ]'
check "O1: ...and no attributed_live" '[ "$(jq_out "String(o.teams.find(t=>t.name===\"o1\").attributed_live)")" = undefined ]'
run_r reap
check "O1: the reap plan lists the same live_members on the orphan" \
  '[ "$(jq_out "JSON.stringify(o.orphans.find(t=>t.name===\"o1\").live_members)")" = "[{\"name\":\"o1-architect\",\"role\":\"architect\",\"last_brief_from\":\"orch-a\"}]" ]'
run_r reap --commit
check "O1: reap --commit keeps the file and reaps nothing" '[ "$RC" -eq 0 ] && [ -f "$HD/teams/o1.json" ] && [ "$(jq_out o.reaped.length)" = 0 ]'
check "O1: ...listing it in kept with the adopt command for the invoking pid" \
  '[ "$(jq_out o.kept[0].team)" = o1 ] && [ "$(jq_out o.kept[0].next)" = "node $H/roster.mjs adopt --orchestrator-pid $$ --team o1 --cwd $PROJ" ] && [ "$(jq_out o.kept[0].why)" = "its records are live sessions" ]'
run_nopid reap --commit
check "O1: with no invoking pid, next is null" '[ "$RC" -eq 0 ] && [ "$(jq_out o.kept[0].next)" = null ] && [ -f "$HD/teams/o1.json" ]'

new_repo o2; setup_roster architect
OWNER_PID=$DEAD write_team o2 "" "$(rec o2-architect architect)"
run_r reap --commit
check "O2: an orphan with no live member is cleared by reap --commit, as before" \
  '[ "$RC" -eq 0 ] && [ ! -e "$HD/teams/o2.json" ] && [ "$(jq_out "o.reaped.map(t=>t.name).join()")" = o2 ] && [ "$(jq_out "String(o.kept)")" = undefined ]'

new_repo o3; setup_roster architect
OWNER_PID=$DEAD write_team o3 "" '{"role":"implementor","name":"o3-implementor","route":"peer","kind":"codex","transport_id":"pane-c"}'
run_r teams
check "O3: a non-claude member whose Herdr state is indeterminate is listed with indeterminate:true" \
  '[ "$(jq_out "JSON.stringify(o.teams.find(t=>t.name===\"o3\").live_members)")" = "[{\"name\":\"o3-implementor\",\"role\":\"implementor\",\"last_brief_from\":null,\"indeterminate\":true}]" ]'
run_r reap --commit
check "O3: ...and it keeps the team" '[ "$RC" -eq 0 ] && [ -f "$HD/teams/o3.json" ] && [ "$(jq_out o.kept[0].team)" = o3 ]'

new_repo o4; setup_roster architect
OWNER_PID=$DEAD write_team o4 "" "$(rec o4-architect architect)"
seed_sid o4-architect architect sid-a4 o4
BEFORE=$(jq_file "$HD/teams/o4.json" 'JSON.stringify(t.members)')
run_r adopt --orchestrator-pid $$ --team o4
run_r teams
check "O4: after adopt with the invoker's live pid, the team is no longer orphaned" '[ "$(jq_out "o.teams.find(t=>t.name===\"o4\").orphaned")" = false ]'
check "O4: ...and its members are unchanged byte for byte" '[ "$(jq_file "$HD/teams/o4.json" "JSON.stringify(t.members)")" = "$BEFORE" ]'

SECTION=$(awk '/^\*\*An orphan that live sessions depend on\.\*\*/{f=1} f{print} f&&/Adopting never closes or launches anything\./{exit}' "$SKILL")
check "O5: the skill says a team with live members is adopted, never reaped" 'grep -q "with \`live_members\` is adopted, never reaped" <<<"$SECTION"'
check "O5: ...adopt it yourself when every live member was last briefed by you" 'grep -q "Adopt it yourself" <<<"$SECTION" && grep -q "every live member.s \`last_brief_from\` is you" <<<"$SECTION"'
check "O5: ...otherwise ask the user, with the two options and no reap" \
  'grep -q "Otherwise ask the user" <<<"$SECTION" && grep -q "AskUserQuestion" <<<"$SECTION" && grep -qF "\"Adopt it\"" <<<"$SECTION" && grep -qF "\"Leave it\"" <<<"$SECTION" && grep -q "Do not offer reaping" <<<"$SECTION"'

new_repo o6; setup_roster architect reviewer
OWNER_PID=$DEAD write_team o6 "" "$(rec o6-architect architect)"
seed_sid "" reviewer sid-t1 o6 pZ
pending sid-t1 orch-b
run_r teams
check "O6: teams lists a session tagged with the team but matching no record under attributed_live" \
  '[ "$(jq_out "JSON.stringify(o.teams.find(t=>t.name===\"o6\").attributed_live.map(r=>[r.role,r.pane_id,r.last_brief_from]))")" = "[[\"reviewer\",\"pZ\",\"orch-b\"]]" ] && [ "$(jq_out "String(o.teams.find(t=>t.name===\"o6\").live_members)")" = undefined ]'
run_r reap
check "O6: the reap plan lists it too" '[ "$(jq_out "o.orphans.find(t=>t.name===\"o6\").attributed_live.length")" = 1 ]'
run_r reap --commit
check "O6: reap --commit keeps the file, with next null and the environment-only why" \
  '[ -f "$HD/teams/o6.json" ] && [ "$(jq_out o.kept[0].next)" = null ] && [ "$(jq_out o.kept[0].why)" = "live sessions claim this team (through AH_TEAM_FILE or a \`o6-\` Herdr name) but match no record. Adopting would relaunch its dead records beside them. Run reap again after those sessions exit." ]'
seed_down sid-t1 reviewer o6
run_r reap --commit
check "O6: once that session is down, reap clears it" '[ "$RC" -eq 0 ] && [ ! -e "$HD/teams/o6.json" ] && [ "$(jq_out "o.reaped.map(t=>t.name).join()")" = o6 ]'

# O6b: only a row tagged with the team claims it. The legacy team.json has no name to tag, so an
# untagged live session never keeps a legacy orphan alive.
new_repo o6b; setup_roster architect reviewer
printf '{"version":1,"team_id":"t-o6b","created":"%s","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":%s},"members":[%s],"expected_root":"%s","roster":null,"layout":"auto"}' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEAD" "$(rec o6b-architect architect)" "$PROJ" > "$HD/team.json"
seed_sid "" reviewer sid-x
node -e 'const fs=require("fs");fs.appendFileSync(process.argv[1],JSON.stringify({type:"peer",status:"up",role:"implementor",session_id:"sid-y",team:null,pid:Number(process.argv[2]),ts:new Date().toISOString()})+"\n")' "$HD/peers.jsonl" "$$"
run_r teams
check "O6b: a legacy orphan with an untagged and a null-tagged live session has no attributed_live, and teams' untracked_live still lists both" \
  '[ "$(jq_out "String(o.teams.find(t=>t.name===null).attributed_live)")" = undefined ] && [ "$(jq_out "o.teams.find(t=>t.name===null).untracked_live.map(r=>r.role).sort().join()")" = implementor,reviewer ]'
run_r reap
check "O6b: the reap plan gives that orphan no attributed_live" '[ "$(jq_out "String(o.orphans.find(t=>t.name===null).attributed_live)")" = undefined ]'
run_r reap --commit
check "O6b: reap --commit clears it" '[ "$RC" -eq 0 ] && [ ! -e "$HD/team.json" ] && [ "$(jq_out "o.reaped.map(t=>String(t.name)).join()")" = null ] && [ "$(jq_out "String(o.kept)")" = undefined ]'

# O6c: a named team's `<t>-` Herdr name is a claim on it: a non-Claude member writes no peers row,
# so a live Herdr-only agent under that prefix keeps the orphan.
new_repo o6c; setup_roster architect reviewer
OWNER_PID=$DEAD write_team o6c "" "$(rec o6c-architect architect)"
echo '[{"agent":"codex","agent_status":"idle","name":"o6c-reviewer","pane_id":"w1:p7","interactive_ready":true}]' > "$FAKE_STATE_DIR/agents.json"
run_h teams
check "O6c: teams lists the Herdr-only agent under untracked_live and attributed_live" \
  '[ "$(jq_out "o.teams.find(t=>t.name===\"o6c\").untracked_live.map(r=>r.name+\"/\"+r.source).join()")" = "o6c-reviewer/herdr" ] && [ "$(jq_out "JSON.stringify(o.teams.find(t=>t.name===\"o6c\").attributed_live)")" = "[{\"name\":\"o6c-reviewer\",\"role\":\"reviewer\",\"pane_id\":\"w1:p7\",\"last_brief_from\":null}]" ]'
run_h reap --commit
check "O6c: ...and reap --commit KEEPS the orphan, with next null and the environment-only why" \
  '[ "$RC" -eq 0 ] && [ -f "$HD/teams/o6c.json" ] && [ "$(jq_out o.reaped.length)" = 0 ] && [ "$(jq_out o.kept[0].team)" = o6c ] && [ "$(jq_out o.kept[0].next)" = null ] && [ "$(jq_out o.kept[0].attributed_live[0].name)" = o6c-reviewer ] && [ "$(jq_out o.kept[0].why)" = "live sessions claim this team (through AH_TEAM_FILE or a \`o6c-\` Herdr name) but match no record. Adopting would relaunch its dead records beside them. Run reap again after those sessions exit." ]'

check "O8: the skill leaves an orphan with only attributed_live sessions alone: never adopted, never closed" \
  'grep -q "only \`attributed_live\` sessions: leave it" <<<"$SECTION" && grep -q "Never adopt it" <<<"$SECTION" && grep -q "Never \`disband --close\` it" <<<"$SECTION"'

# ============================================================ O7: a team file that does not exist never decides identity
# Identity comes from the launch path alone; only readers of the record see that it is missing.
new_repo o7; setup_roster architect reviewer
TF="$HD/teams/o7.json"
env_run() { env HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" AH_TEAM_FILE="$TF" "$@"; }
gate_env() { OUT=$(echo "$1" | env_run node "$GATE" 2>&1); RC=$?; }
o7_gates() { # every gate decision o7's role session can reach, one per line
  local p
  for p in "$(agent_payload s7-g ah:reviewer)" \
    "$(node -e 'const[cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s7-g",agent_type:"ah:architect",cwd,tool_name:"Agent",tool_input:{subagent_type:"ah:reviewer",prompt:"x"}}))' "$PROJ")" \
    "$(node -e 'const[cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s7-g",cwd,tool_name:"SendMessage",tool_input:{to:"o7-reviewer",message:"[hierarchy-peer-brief reply-to=\"me\" task=\"t\"]\nx"}}))' "$PROJ")"; do
    gate_env "$p"; echo "$RC:$OUT"
  done; }
o7_readers() { # <label>: SessionStart, resolveConfig, whoami and msg.mjs with the file in its current state
  local label=$1 src req id
  for src in startup compact; do
    printf '{"session_id":"s7-%s","cwd":"%s","agent_type":"ah:architect","source":"%s","hook_event_name":"SessionStart"}' "$src" "$PROJ" "$src" | env_run node "$H/sessionstart.mjs" >/dev/null 2>&1
    OUT=$(tail -1 "$HD/peers.jsonl")
    check "O7 ($label): SessionStart with source $src tags the up row with team o7" '[ "$(jq_out "o.status+\"/\"+o.team")" = "up/o7" ]'
  done
  OUT=$(env_run node --input-type=module -e "const C=await import('$H/lib-config.mjs');process.stdout.write(JSON.stringify({team:C.resolveConfig('$PROJ',{sessionId:'s7-x'}).team}))" 2>&1)
  check "O7 ($label): resolveConfig gives the role session team o7" '[ "$(jq_out o.team)" = o7 ]'
  OUT=$(env_run HERDR_PANE_ID=pane-o7-architect node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1); RC=$?
  check "O7 ($label): whoami exits 0 with member null, team o7, reason no-team and no env_team_invalid" \
    '[ "$RC" -eq 0 ] && [ "$(jq_out "JSON.stringify([o.member,o.team,o.reason,o.answered_by,\"env_team_invalid\" in o])")" = "[null,\"o7\",\"no-team\",\"env\",false]" ]'
  req=$(env_run node "$H/msg.mjs" new --to architect --from orchestrator --slug o7 --cwd "$PROJ" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).path)}catch{}})')
  id=$(basename "$req" | cut -c1-20)
  OUT=$(env_run node "$H/msg.mjs" new --type response --id "$id" --to orchestrator --from architect --req "$req" --cwd "$PROJ" 2>&1); RC=$?
  check "O7 ($label): msg.mjs new --type response --req succeeds" '[ "$RC" -eq 0 ] && [ -f "$(jq_out o.path)" ]'
}
rm -f "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"
o7_readers "before a commit"
GATES_NEVER=$(o7_gates)
write_team o7 "" "$(rec o7-architect architect)"
GATES_PRESENT=$(o7_gates)
OUT=$(env_run HERDR_PANE_ID=pane-o7-architect node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1)
check "O7 (control): with the file present, whoami finds the member by its pane" '[ "$(jq_out o.member.name)" = o7-architect ] && [ "$(jq_out o.reason)" = null ]'
rm -f "$TF"
o7_readers "after a removal"
GATES_REMOVED=$(o7_gates)
check "O7: the route gate decides the same before a commit, with the file present, and after a removal" \
  '[ "$GATES_NEVER" = "$GATES_PRESENT" ] && [ "$GATES_REMOVED" = "$GATES_PRESENT" ] && [ "$(printf "%s\n" "$GATES_PRESENT" | grep -c "permissionDecision")" -ge 1 ]'
check "O7: no reader threw and no hook-error entry was written" '[ ! -s "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl" ]'

mkdir -p "$SANDBOX/other/.claude/hierarchy/teams"
for bad in "relative/teams/o7.json:malformed" "$SANDBOX/other/.claude/hierarchy/teams/o7.json:other-repo"; do
  OUT=$(env HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" AH_TEAM_FILE="${bad%:*}" node --input-type=module -e "const C=await import('$H/lib-config.mjs');process.stdout.write(JSON.stringify({team:C.resolveConfig('$PROJ',{sessionId:'s7-x'}).team}))" 2>&1)
  check "O7b: AH_TEAM_FILE=${bad%:*} is treated as unset" '[ "$(jq_out o.team)" = null ]'
  OUT=$(env HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" AH_TEAM_FILE="${bad%:*}" node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1); RC=$?
  check "O7b: ...and whoami reports it as env_team_invalid (${bad##*:})" '[ "$RC" -eq 0 ] && [ "$(jq_out o.env_team_invalid.kind)" = "${bad##*:}" ] && [ "$(jq_out o.team)" = null ]'
done

launched_team_files() { # the AH_TEAM_FILE of every member launch the fake recorded, comma-joined
  node -e 'const fs=require("fs"),d=process.argv[1]+"/calls";const out=[];for(const f of fs.readdirSync(d)){const c=JSON.parse(fs.readFileSync(d+"/"+f,"utf8"));if(c.argv[0]!=="agent"||c.argv[1]!=="start")continue;const i=c.argv.indexOf("--settings");out.push(i<0?"none":JSON.parse(c.argv[i+1]).env.AH_TEAM_FILE)}console.log(out.join())' "$FAKE_STATE_DIR"; }
new_repo o7c; setup_roster architect reviewer
run_h create --spawn --team o7c
TF="$HD/teams/o7c.json"
check "O7c: create --spawn launches its members with AH_TEAM_FILE set to the team file it has not written yet" \
  '[ "$RC" -eq 0 ] && [ ! -e "$TF" ] && [ "$(launched_team_files)" = "$TF,$TF" ]'
printf '{"session_id":"s7c","cwd":"%s","agent_type":"ah:architect","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" | env_run node "$H/sessionstart.mjs" >/dev/null 2>&1
OUT=$(tail -1 "$HD/peers.jsonl")
check "O7c: a member checking in at startup before --commit carries team o7c on its up row" '[ ! -e "$TF" ] && [ "$(jq_out "o.status+\"/\"+o.team")" = "up/o7c" ]'
ROW_PID=$(jq_out o.pid)
env_run node "$H/roster.mjs" checkin --orchestrator-pid "$ROW_PID" --cwd "$PROJ" >/dev/null 2>&1
OUT=$(tail -1 "$HD/peers.jsonl")
check "O7c: ...and so does a checkin re-registration before --commit" '[ ! -e "$TF" ] && [ "$(jq_out "o.status+\"/\"+o.team+\"/\"+o.pid")" = "up/o7c/$ROW_PID" ]'

# ============================================================ S1: a member's name must match its team file
new_repo s1; setup_roster architect
write_team s1 "" "$(rec other-architect architect '"renamed_from":"s1-architect"')"
run_h spawn-one architect --team s1
check "S1: a record hand-edited to claim a foreign-prefixed name makes spawn-one exit 2" \
  '[ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "member other-architect" && echo "$STDERR" | grep -qF "$HD/teams/s1.json" && echo "$STDERR" | grep -qF "expected prefix \"s1-\""'
check "S1: ...with no pane opened and nothing started" '[ "$(calls pane split)" = 0 ] && [ "$(calls agent start)" = 0 ]'
new_repo s1b; setup_roster architect
write_team s1b "" "$(rec s1b-architect-2 architect '"renamed_from":"s1b-architect"')"
run_h spawn-one architect --team s1b
check "S1 (control): the same claim under the team's own prefix relaunches it" '[ "$RC" -eq 0 ] && [ "$(started)" = s1b-architect-2 ]'

# ============================================================ P: partial is derived when shown
write_legacy() { # <partial> <roster key json> <member json>...: a live default-scope team.json this shell owns
  local partial=$1 key=$2; shift 2
  local members; members=$(IFS=,; echo "$*")
  printf '{"version":1,"team_id":"t-legacy","created":"%s","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":%s},"members":[%s],"partial":%s,"expected_root":"%s","roster":%s,"layout":"auto"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$members" "$partial" "$PROJ" "$key" > "$HD/team.json"
}
status_team() { (cd "$PROJ" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/lib-config.mjs" 2>&1) | grep '^Team: '; }
state_team() {
  HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e '
    const [H, cwd, dir] = process.argv.slice(1);
    const { resolveConfig } = await import(H + "/lib-config.mjs");
    const { buildStateBlock } = await import(H + "/lib-hier.mjs");
    process.stdout.write(buildStateBlock(dir, resolveConfig(cwd), "x", "opus"));' "$H" "$PROJ" "$HD" 2>&1 | grep '^Team '; }
shown_partial() { status_team | grep -q ', partial)' && state_team | grep -q ' \[partial\]'; }
shown_whole() { status_team | grep -q '^Team: t-legacy' && ! status_team | grep -q 'partial' && state_team | grep -q '^Team t-legacy' && ! state_team | grep -q 'partial'; }

new_repo p1; setup_roster architect reviewer implementor
write_legacy false null "$(rec p1-architect architect)" "$(rec p1-reviewer reviewer)"
check "P1: a record missing for a roster member shows partial, in the status line and HIERARCHY STATE" 'shown_partial'
run_h spawn-one implementor
check "P1: spawning the missing member clears it, with no other write" '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/team.json" "t.members.length")" = 3 ] && shown_whole'
check "P1: ...the stored key is untouched and ignored" '[ "$(jq_file "$HD/team.json" "t.partial")" = false ]'
run_h dismiss p1-reviewer
TOKEN=$(jq_out o.close_token)
run_h dismiss p1-reviewer --close --confirm --plan-token "$TOKEN"
check "P2: dismissing a member of a full team shows partial" '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/team.json" "t.members.length")" = 2 ] && shown_partial'

new_repo p3; setup_roster architect reviewer implementor
write_legacy false null "$(rec p3-architect-2 architect '"renamed_from":"p3-architect"')" "$(rec p3-reviewer reviewer)" "$(rec p3-implementor implementor)"
check "P3: a renamed member (renamed_from the derived name) counts as present" 'shown_whole'
write_legacy false null "$(rec p3-architect-2 architect)" "$(rec p3-reviewer reviewer)" "$(rec p3-implementor implementor)"
check "P3 (control): the same record without renamed_from leaves the architect missing" 'shown_partial'

new_repo p4; setup_roster architect reviewer implementor
write_legacy false null "$(rec p4-architect architect)" "$(rec p4-reviewer reviewer)" "$(rec p4-ultra-advisor ultra-advisor)"
check "P4: an ad hoc extra member does not make a partial team complete" 'shown_partial'
write_legacy false null "$(rec p4-architect architect)" "$(rec p4-reviewer reviewer)" "$(rec p4-implementor implementor)" "$(rec p4-ultra-advisor ultra-advisor)"
check "P4: ...nor a complete team partial" 'shown_whole'

new_repo p5; setup_roster architect reviewer
write_legacy true null "$(rec p5-architect architect)" "$(rec p5-reviewer reviewer)"
check "P5: an old file carrying partial:true on a complete team shows whole" 'shown_whole'
write_legacy false null "$(rec p5-architect architect)"
check "P5: ...and partial:false on an incomplete team shows partial" 'shown_partial'
write_legacy false '"gone"' "$(rec p5-architect architect)"
check "P5: with its roster block unresolvable, nothing is shown" 'shown_whole'

new_repo p6; setup_roster architect
roster_q add --no-spawn --level repo --role task-runner
write_legacy false null "$(rec p6-architect architect)"
check "P6: without task-gopher, a legwork member with no model and no record shows partial" 'shown_partial'
mkdir -p "$SANDBOX/tg/agents" "$FAKEHOME/.claude/plugins"
printf -- '---\nname: task-gopher\nmodel: haiku\n---\nbody\n' > "$SANDBOX/tg/agents/task-gopher.md"
echo "{\"version\":2,\"plugins\":{\"task-gopher@claudetools\":[{\"installPath\":\"$SANDBOX/tg\"}]}}" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
check "P6: with task-gopher installed that member is handed off, never launched, so the team shows whole" 'shown_whole'

# ============================================================ W: writers no longer store partial
new_repo w1; setup_roster architect
run_r create --commit --transport herdr --roster-level repo --verified '["w1-architect"]' --partial
check "W: create --commit accepts --partial and writes no partial key" '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/w1.json" "String(t.partial)")" = undefined ]'
new_repo w2; setup_roster architect reviewer
run_h spawn-one architect --team w2
check "W: spawn-one's new team writes no partial key" '[ "$RC" -eq 0 ] && [ "$(jq_file "$HD/teams/w2.json" "String(t.partial)")" = undefined ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
