#!/bin/bash
# agent-hierarchy — in an Orchestrator session, ah dispatch of a peer-eligible role is a peer
# unless the user opted in: every Agent call is denied (a wall, not a one-shot) naming the live
# peer or carrying the exact spawn command; each opt-in passes; explicit onMissing:"prompt" still
# asks once; no route question, no global-scope confirm, no peer-name ceremony in the directive.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-route-wall.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-route-wall-test.XXXXXX")"
sleep 600 & LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
HIER="$PROJ/.claude/hierarchy"
PEERS="$HIER/peers.jsonl"
GATES="$HIER/gates.jsonl"
CFG="$PROJ/.claude/agent-hierarchy.json"
UCFG="$FAKEHOME/.claude/agent-hierarchy.json"
NODE_DIR="$(dirname "$(command -v node)")"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}
reset() { rm -rf "$HIER" "$UCFG"; mkdir -p "$HIER"; }
payload() { # <session> <subagent_type> [tool_input.model]
  node -e 'const[s,st,m,cwd]=process.argv.slice(1);const ti={subagent_type:st,prompt:"do it"};if(m)ti.model=m;process.stdout.write(JSON.stringify({session_id:s,cwd,tool_name:"Agent",tool_input:ti}));' "$1" "$2" "${3:-}" "$PROJ"; }
send_payload() { # <session> <to>
  node -e 'const[s,t,cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd,tool_name:"SendMessage",tool_input:{to:t,message:"[hierarchy-peer-brief reply-to=\"me\" task=\"x\"]\nplain"}}));' "$1" "$2" "$PROJ"; }
gate() { OUT=$(echo "$1" | HOME="$FAKEHOME" node "$GATE" 2>&1); RC=$?; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
allowed_with_note() { [ $RC -eq 0 ] && echo "$OUT" | grep -q '"systemMessage"' && ! echo "$OUT" | grep -q '"permissionDecision"'; }
set_route() { HOME="$FAKEHOME" node "$MSG" route "$2" --session "$1" --cwd "$PROJ" >/dev/null; }
seed_live() { # <name> <role> [busy]
  node -e 'const fs=require("fs");const[f,n,r,b]=process.argv.slice(1);fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,busy:b==="1",ts:new Date().toISOString()})+"\n");' "$PEERS" "$1" "$2" "${3:-}"; }
no_ask() { ! echo "$OUT" | grep -q "AskUserQuestion"; }
has_cmd() { echo "$OUT" | grep -qF "node \\\"$H/roster.mjs\\\" $1 architect --cwd $PROJ"; }

PLAIN='{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus" } } }'
ROSTER_ARCH='{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus" } }, "roster": { "route": "peer", "members": [ { "role": "architect", "model": "opus"%s } ] } }'
roster_cfg() { printf "$ROSTER_ARCH" "$1" > "$CFG"; }

# ---- 8: no roster, no route, none live -> spawn-ad-hoc command, denied every time, no route-ask
reset; echo "$PLAIN" > "$CFG"
gate "$(payload s8 ah:architect sonnet)"
check "8: denied with the spawn-ad-hoc command (absolute path, --cwd), never the Agent call's --model" \
  'denied && has_cmd spawn-ad-hoc && ! echo "$OUT" | grep -q -- "--model"'
check "8b: names the send-after-spawn and the opt-in command" \
  'echo "$OUT" | grep -q "SendMessage the \`name\` the command prints" && echo "$OUT" | grep -q "route subagents --session s8"'
gate "$(payload s8 ah:architect sonnet)"
check "8c: the identical re-issue is denied again" 'denied && has_cmd spawn-ad-hoc'
check "8d: no route-ask record" '! grep -q "\"type\":\"route-ask\"" "$GATES" 2>/dev/null'
gate "$(payload s8 task-gopher:task-gopher)"
check "8e: legwork is not gated" 'allowed'

# ---- 9: roster architect member, no onMissing
reset; roster_cfg ""
gate "$(payload s9 ah:architect)"
check "9: none live -> denied with the spawn-one command, no AskUserQuestion" 'denied && has_cmd spawn-one && no_ask'
gate "$(payload s9 ah:architect)"
check "9b: re-issue denied again" 'denied && has_cmd spawn-one'
seed_live busy-arch architect 1
seed_live myrepo-architect architect
gate "$(payload s9 ah:architect)"
check "9c: live one -> denied naming it, free one first" 'denied && echo "$OUT" | grep -q "SendMessage \\\\\"myrepo-architect\\\\\"" && no_ask'
gate "$(payload s9 ah:architect)"
check "9d: re-issue with a live one denied again" 'denied && echo "$OUT" | grep -q "myrepo-architect"'

# ---- 10: roster without an architect member -> spawn-ad-hoc
reset
echo '{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }' > "$CFG"
gate "$(payload s10 ah:architect)"
check "10: roster lacking the role -> spawn-ad-hoc command" 'denied && has_cmd spawn-ad-hoc'

# ---- 11: each opt-in passes; the built-in default does not
reset; echo "$PLAIN" > "$CFG"
set_route s11a subagents
gate "$(payload s11a ah:architect)"; check "11a: session route subagents passes" 'allowed'
set_route s11b prefer-peers
gate "$(payload s11b ah:architect)"; check "11b: session route prefer-peers, none free, passes" 'allowed'
seed_live busy-only architect 1
gate "$(payload s11b ah:architect)"; check "11b2: prefer-peers, the only live one busy, passes" 'allowed'
reset; echo '{ "version": 1, "enabled": true, "route": "subagents", "roles": { "architect": { "model": "opus" } } }' > "$CFG"
gate "$(payload s11c ah:architect)"; check "11c: config route subagents passes" 'allowed'
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
echo '{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus", "dispatch": "model" } } }' > "$UCFG"
gate "$(payload s11d ah:architect)"; check "11d: user-level roles.architect.dispatch model passes" 'allowed'
reset; roster_cfg ', "route": "subagent"'
gate "$(payload s11e ah:architect)"; check "11e: roster member route subagent passes" 'allowed'
reset; roster_cfg ', "onMissing": "never"'
gate "$(payload s11f ah:architect)"; check "11f: onMissing never with none live passes" 'allowed'
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
gate "$(payload s11g ah:architect)"; check "11g: the built-in default config does not pass" 'denied && has_cmd spawn-ad-hoc'
reset; roster_cfg ', "route": "subagent"'; set_route s11h peers
gate "$(payload s11h ah:architect)"; check "11h: a roster route subagent member passes even under an explicit session route peers" 'allowed'
reset; echo '{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus", "dispatch": "model" } } }' > "$CFG"; set_route s11i peers
gate "$(payload s11i ah:architect)"; check "11i: a user-written dispatch model passes even under an explicit session route peers" 'allowed'

# ---- 12/13: the SessionStart directive
directive() { # <session> -> OUT
  OUT=$(cd "$PROJ" && HOME="$FAKEHOME" node --input-type=module -e '
    const c = await import(process.argv[1] + "/lib-config.mjs");
    const r = c.resolveConfig(process.argv[2], { sessionId: "d1" });
    process.stdout.write(c.buildDirective(r, "d1", { hierDir: process.argv[2] + "/.claude/hierarchy" }));' "$H" "$PROJ" 2>&1); RC=$?
}
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
directive
check "12: no route-question / fallback wording" \
  '! echo "$OUT" | grep -qE "will ask|choose this session.s dispatch route|one-shot per role|else the subagent|one-off subagent dispatch"'
check "12b: carries the spawn command form for a peer-eligible role" 'echo "$OUT" | grep -qF "spawn-ad-hoc architect --cwd $PROJ"'
check "13: no peer-name ceremony" '! echo "$OUT" | grep -qE "PEER NAME CONFIRMATION|not yet confirmed"'
check "13b: no \"else Agent\"; the role line is SendMessage / spawn / opt-in" \
  '! echo "$OUT" | grep -q "else Agent" && echo "$OUT" | grep "^- Architect" | grep -q "SendMessage its live teammate" && echo "$OUT" | grep "^- Architect" | grep -q "Subagent only if the user opts in"'
echo '{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus", "dispatch": "model" } } }' > "$CFG"
directive
check "13c: an opted-in role still renders its Agent call" 'echo "$OUT" | grep "^- Architect" | grep -q "Agent(subagent_type:\"ah:architect\""'

# ---- 14: explicit onMissing prompt, none live -> one ask, spawn first + Recommended; re-issue passes
reset; roster_cfg ', "onMissing": "prompt"'
gate "$(payload s14 ah:architect)"
check "14: asks once, spawning the peer first and Recommended" \
  'denied && case "$OUT" in *AskUserQuestion*"Spawn the Architect peer (Recommended)"*"Use a subagent"*) true;; *) false;; esac && has_cmd spawn-one'
gate "$(payload s14 ah:architect)"
check "14b: the re-issue passes" 'allowed_with_note'

# ---- 15: D4 — a global roster confirms nothing, and the CLI needs no --allow-global
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
echo '{ "version": 1, "enabled": true, "roster": { "route": "peer", "members": [ { "role": "architect", "model": "opus" } ] } }' > "$UCFG"
gate "$(payload s15 ah:architect)"
check "15: no global-roster ask on Agent; the wall carries spawn-one" 'denied && ! echo "$OUT" | grep -q "GLOBAL" && has_cmd spawn-one'
gate "$(send_payload s15 myrepo-architect)"
check "15b: no global-roster ask on a SendMessage brief" 'allowed'
OUT=$(HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one architect --dry-run --cwd "$PROJ" 2>&1); RC=$?
check "15c: spawn-one --dry-run against the global roster succeeds without --allow-global" '[ $RC -eq 0 ]'
OUT=$(HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one architect --dry-run --allow-global --cwd "$PROJ" 2>&1); RC=$?
check "15d: --allow-global is still accepted" '[ $RC -eq 0 ]'
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({version:1,team_id:"t15",created:"2026-01-01T00:00:00Z",roster_level:"global",transport:"herdr",orchestrator:{session_id:null,pid:null},members:[{role:"architect",name:"myrepo-architect",ref:"r1",route:"peer",model:"opus",transport_id:"PANE9",checked_in:"2026-01-01T00:00:00Z"}],partial:false}))' "$HIER/team.json"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" disband --cwd "$PROJ" 2>&1); RC=$?
check "15e: the disband plan's close command carries no --allow-global" '[ $RC -eq 0 ] && echo "$OUT" | grep -q "\"next\"" && ! echo "$OUT" | grep -q "allow-global"'

# ---- 16: D4 — user-scope role config confirms nothing; the global-scope verb is gone
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
echo '{ "version": 1, "enabled": true, "roles": { "architect": { "model": "opus" } } }' > "$UCFG"
gate "$(payload s16 ah:architect)"
check "16: no USER-scope config ask" 'denied && ! echo "$OUT" | grep -q "USER-scope" && has_cmd spawn-ad-hoc'
OUT=$(HOME="$FAKEHOME" node "$MSG" global-scope roster allow --session s16 --cwd "$PROJ" 2>&1); RC=$?
check "16b: msg.mjs global-scope exits with the usage error" '[ $RC -ne 0 ] && echo "$OUT" | grep -q "usage:"'

# ---- 17: NE1 — spawn-ad-hoc from the Orchestrator, then the gate must see the spawned peer
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env node
const fs = require("fs"), path = require("path");
const args = process.argv.slice(2), dir = process.env.FAKE_STATE_DIR;
const geomFile = path.join(dir, "geometry.json");
if (args[0] === "pane" && args[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  console.log(JSON.stringify({ result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } }));
  process.exit(0);
}
if (args[0] === "pane" && args[1] === "split") {
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const target = args[args.indexOf("--pane") + 1], rect = s.panes[target], id = `p${s.nextId++}`;
  const w1 = Math.floor(rect.width / 2);
  s.panes[target] = { ...rect, width: w1 };
  s.panes[id] = { ...rect, width: rect.width - w1, x: rect.x + w1 };
  fs.writeFileSync(geomFile, JSON.stringify(s));
  console.log(JSON.stringify({ result: { pane: { pane_id: id } } }));
  process.exit(0);
}
if (args[0] === "agent" && args[1] === "start") { console.log(JSON.stringify({ result: { pane: { pane_id: "target" }, agent: { name: args[2], ready: true } } })); process.exit(0); }
if (args[0] === "agent" && args[1] === "list") { console.log(JSON.stringify({ result: { agents: [] } })); process.exit(0); }
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"
mkdir -p "$SANDBOX/state"
echo '{"self":"p0","nextId":1,"area":{"width":200,"height":50,"x":0,"y":0},"panes":{"p0":{"width":200,"height":50,"x":0,"y":0}}}' > "$SANDBOX/state/geometry.json"
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
payload orch17 ah:architect > "$SANDBOX/pl17.json"
# One subshell plays the Orchestrator's Claude process: it owns the spawned team (its pid is the
# team's orchestrator.pid) and is the parent of the gate hook, as the Claude process is in a session.
(
  ORCH=$BASHPID
  env -u HERDR_ENV -u CLAUDE_PID HOME="$FAKEHOME" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$SANDBOX/bin:$NODE_DIR:/usr/bin:/bin" FAKE_STATE_DIR="$SANDBOX/state" \
    node "$H/roster.mjs" spawn-ad-hoc architect --model opus --orchestrator-pid "$ORCH" --cwd "$PROJ" > "$SANDBOX/spawn17.out" 2>&1
  echo $? > "$SANDBOX/spawn17.rc"
  node -e 'const fs=require("fs"),p=require("path");const d=p.join(process.argv[1],"teams");for(const f of [p.join(process.argv[1],"team.json"),...(fs.existsSync(d)?fs.readdirSync(d).map(x=>p.join(d,x)):[])]){if(!fs.existsSync(f))continue;const t=JSON.parse(fs.readFileSync(f,"utf8"));const m=(t.members||[]).find(m=>m.role==="architect");if(m){process.stdout.write(m.name+" "+m.transport_id);break}}' "$HIER" > "$SANDBOX/spawned17"
  read -r SP_NAME SP_PANE < "$SANDBOX/spawned17"
  node -e 'const fs=require("fs");const[f,pid,pane,cwd]=process.argv.slice(1);fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:"architect",pid:Number(pid),pane_id:pane,session_id:"spawned-arch-0001",cwd,ts:new Date().toISOString()})+"\n");' "$PEERS" "$LIVE_PID" "$SP_PANE" "$PROJ"
  HOME="$FAKEHOME" node "$GATE" < "$SANDBOX/pl17.json" > "$SANDBOX/gate17.out" 2>&1
  true
)
RC=$(cat "$SANDBOX/spawn17.rc"); OUT=$(cat "$SANDBOX/spawn17.out")
check "17a: spawn-ad-hoc architect launched" '[ "$RC" -eq 0 ]'
read -r SP_NAME SP_PANE < "$SANDBOX/spawned17"
OUT=$(cat "$SANDBOX/gate17.out"); RC=0
check "17: Agent(ah:architect) is denied naming the spawned member ($SP_NAME), not with a spawn command" \
  'denied && [ -n "$SP_NAME" ] && echo "$OUT" | grep -q "SendMessage \\\\\"$SP_NAME\\\\\"" && ! echo "$OUT" | grep -q "spawn-ad-hoc"'

# ---- 21: resolveTeamScope adopts a session-less team by the calling session's pid
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
scope() { # <session> [pid|-]: resolveConfig(cwd,{sessionId, pid}).team; "-" = let the hook default (process.ppid) apply
  HOME="$FAKEHOME" node --input-type=module -e '
    const c = await import(process.argv[1] + "/lib-config.mjs");
    const opts = { sessionId: process.argv[3] };
    if (process.argv[4] !== "-") opts.pid = Number(process.argv[4]);
    process.stdout.write(String(c.resolveConfig(process.argv[2], opts).team));' "$H" "$PROJ" "$1" "${2:--}"
}
team_file() { # <name> <session_id|null> <pid>
  mkdir -p "$HIER/teams"
  node -e 'const[f,n,s,p]=process.argv.slice(1);require("fs").writeFileSync(f,JSON.stringify({version:1,team_id:n,created:"2026-01-01T00:00:00Z",roster_level:null,transport:"herdr",orchestrator:{session_id:s==="null"?null:s,pid:Number(p)},members:[],partial:true}))' "$HIER/teams/$1.json" "$1" "$2" "$3"
}
team_file adhoc null 4242
check "21a: a session-less team whose orchestrator pid is the caller's is adopted" '[ "$(scope S21 4242)" = "adhoc" ]'
check "21b: another pid is not" '[ "$(scope S21 4343)" = "null" ]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e '
  const fs = await import("node:fs");
  fs.writeFileSync(process.argv[2] + "/.claude/hierarchy/teams/adhoc.json", JSON.stringify({version:1,team_id:"adhoc",created:"2026-01-01T00:00:00Z",roster_level:null,transport:"herdr",orchestrator:{session_id:null,pid:process.ppid},members:[],partial:true}));
  const c = await import(process.argv[1] + "/lib-config.mjs");
  process.stdout.write(String(c.resolveConfig(process.argv[2], { sessionId: "S21" }).team));' "$H" "$PROJ")
check "21c: in a hook the caller pid defaults to process.ppid" '[ "$OUT" = "adhoc" ]'
reset; team_file owned other-session 4242
check "21d: a team with a non-null, non-matching session_id is never adopted by pid" '[ "$(scope S21 4242)" = "null" ]'
reset; team_file bypid null 4242; team_file byid S21 1
check "21e: an exact session_id match outranks a pid match" '[ "$(scope S21 4242)" = "byid" ]'

# ---- 21f/21g: a CLI's parent is a shell, never the Claude process — it names its pid via
# CLAUDE_PID (or --orchestrator-pid), and without one the pid rung is skipped
reset; echo '{ "version": 1, "enabled": true }' > "$CFG"
seed_live adhoc-architect architect
(
  P=$BASHPID
  team_file adhoc null "$P"
  node -e 'const fs=require("fs");const f=process.argv[1];const t=JSON.parse(fs.readFileSync(f,"utf8"));t.members=[{role:"architect",name:"adhoc-architect",route:"peer",transport_id:"pA"}];fs.writeFileSync(f,JSON.stringify(t));' "$HIER/teams/adhoc.json"
  env -u CLAUDE_PID HOME="$FAKEHOME" node "$MSG" roster --plain --cwd "$PROJ" > "$SANDBOX/cli21f.out" 2>&1
  env CLAUDE_PID="$P" HOME="$FAKEHOME" node "$MSG" roster --plain --cwd "$PROJ" > "$SANDBOX/cli21g.out" 2>&1
  true
)
OUT=$(cat "$SANDBOX/cli21f.out")
check "21f: a CLI with no CLAUDE_PID does not adopt its parent shell's team" 'echo "$OUT" | grep -q "^architect: none"'
OUT=$(cat "$SANDBOX/cli21g.out")
check "21g: a CLI with CLAUDE_PID sees that session's team" 'echo "$OUT" | grep -q "^architect: adhoc-architect"'

# ---- F2: a live pane-route member's deny says herdr, not SendMessage
reset; roster_cfg ', "kind": "codex", "route": "pane"'
seed_live myrepo-architect architect
gate "$(payload sF2 ah:architect)"
check "F2: a live pane-route member's deny says to drive it with herdr agent prompt" 'denied && echo "$OUT" | grep -q "herdr agent prompt"'

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
