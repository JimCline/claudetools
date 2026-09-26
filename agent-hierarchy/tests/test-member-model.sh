#!/bin/bash
# agent-hierarchy — a member's model is the user's to define: `add` stores one only when given,
# `edit ""` clears it, and a spawn verb about to launch a claude member with none refuses with
# `member-model-undefined`, offering the highest defined chain model as a fallback it never applies
# itself; a model-less legwork member is skipped instead while task-gopher is installed.
# HOME-redirected; no test reaches the real herdr, tmux, or ~/.claude.
# Usage: bash tests/test-member-model.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-member-model-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/claude"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux" "$SANDBOX/nolaunch/claude"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE CLAUDE_PID
FAKEHOME="$SANDBOX/home"
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:600})"; fi
}

# ---- fake herdr: records every call; splits geometry; `agent start` succeeds.
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
if (args[0] === "pane" && args[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(path.join(dir, "geometry.json"), "utf8"));
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  console.log(JSON.stringify({ result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } }));
  finish(0);
}
if (args[0] === "pane" && args[1] === "split") {
  const geomFile = path.join(dir, "geometry.json");
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
if (args[0] === "agent" && args[1] === "list") { console.log(JSON.stringify({ result: { agents: [] } })); finish(0); }
if (args[0] === "pane" && args[1] === "rename") finish(0);
process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"
FAKE_STATE_DIR="$SANDBOX/state"

# A fresh repo per case: <name> sets PROJ, HD, CFG and resets fake-herdr state. The repo basename
# is the team name, so members are named <name>-<role>.
new_repo() {
  PROJ="$SANDBOX/$1"
  rm -rf "$PROJ" "$FAKE_STATE_DIR"; mkdir -p "$PROJ/.claude" "$FAKE_STATE_DIR"
  (cd "$PROJ" && git init -q)
  HD="$PROJ/.claude/hierarchy"
  CFG="$PROJ/.claude/agent-hierarchy.json"
  printf '{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}' > "$FAKE_STATE_DIR/geometry.json"
}
fresh_home() { rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME/.claude"; }
# task-gopher installed per installed_plugins.json ("TG").
tg_home() {
  fresh_home
  mkdir -p "$SANDBOX/tg/agents" "$FAKEHOME/.claude/plugins"
  printf -- '---\nname: task-gopher\nmodel: haiku\n---\nbody\n' > "$SANDBOX/tg/agents/task-gopher.md"
  echo "{\"version\":2,\"plugins\":{\"task-gopher@claudetools\":[{\"installPath\":\"$SANDBOX/tg\"}]}}" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
}
roster_json() { # <members json array> [route] — the repo-level default roster, written directly
  printf '{"version":1,"roster":{"route":"%s","members":%s}}\n' "${2:-peer}" "$1" > "$CFG"
}

# roster.mjs under the fake HOME on the terminal transport, owner pid = this shell.
run_roster() {
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
run_split() { # stdout in OUT, stderr in STDERR
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
# roster.mjs on the fake herdr transport; stdout in OUT, stderr in STDERR.
run_herdr() {
  OUT=$(env HERDR_ENV=1 HERDR_PANE_ID=p0 HOME="$FAKEHOME" CLAUDE_PID=$$ PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
# a rerun command string from a refusal, run on the fake herdr transport.
run_herdr_cmd() {
  OUT=$(env HERDR_ENV=1 HERDR_PANE_ID=p0 HOME="$FAKEHOME" CLAUDE_PID=$$ PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" /bin/sh -c "$1" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
jq_out() { # <js expr over o> — over $OUT as JSON
  printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{o=JSON.parse(s.slice(s.indexOf("{")))}process.stdout.write(String((new Function("o","return "+process.argv[1]))(o)))})' "$1" 2>/dev/null
}
jq_file() { # <file> <js expr over t>
  node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((new Function("t","return "+process.argv[2]))(t)))' "$1" "$2" 2>/dev/null
}
# every fake-herdr `agent start` call, one argv per line
agent_starts() {
  node -e 'const fs=require("fs"),p=require("path"),d=p.join(process.argv[1],"calls");if(!fs.existsSync(d))process.exit(0);for(const f of fs.readdirSync(d)){const c=JSON.parse(fs.readFileSync(p.join(d,f),"utf8"));if(c.argv[0]==="agent"&&c.argv[1]==="start")console.log(c.argv.join(" "))}' "$FAKE_STATE_DIR"
}
herdr_calls() { ls "$FAKE_STATE_DIR/calls" 2>/dev/null | wc -l | tr -d ' '; }
team_files() { find "$HD" -name '*.json' \( -name team.json -o -path '*/teams/*' \) 2>/dev/null; }
sum() { cksum < "$1"; }

# ============================================================ A: storage
fresh_home
new_repo a1
run_roster init --level repo --route peer
for r in ultra-advisor architect reviewer implementor task-runner; do run_roster add --level repo --role "$r"; done
check "A1: add without --model stores no model for any built-in role" '[ "$(jq_file "$CFG" "t.roster.members.filter(m=>\"model\" in m).length")" = 0 ] && [ "$(jq_file "$CFG" "t.roster.members.length")" = 5 ]'
run_roster role set docs-writer --class implement --model sonnet --description "Writes docs." --scaffold user
run_roster add --level repo --role docs-writer
check "A1: ...nor for a custom role whose roles.<name>.model is set" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members.at(-1))")" = "{\"role\":\"docs-writer\"}" ]'
run_roster add --level repo --role architect --model opus
check "A1: with --model opus the model is stored" '[ "$(jq_file "$CFG" "t.roster.members.at(-1).model")" = opus ]'
run_roster add --level repo --role architect --model ""
check "A2: add --model \"\" still exits 2" '[ "$RC" = 2 ]'

new_repo a2
roster_json '[{"role":"architect","model":"opus","effort":"high"},{"role":"ultra-advisor","model":"fable","effort":"max"}]'
run_roster edit --level repo --member a2-architect --model ""
EXPECT=$(jq_file "$CFG" 'JSON.stringify(t)'); ORIG='{"version":1,"roster":{"route":"peer","members":[{"role":"architect","effort":"high"},{"role":"ultra-advisor","model":"fable","effort":"max"}]}}'
check "A2: edit --model \"\" removes model and leaves the rest of the file as it was" '[ "$RC" = 0 ] && [ "$EXPECT" = "$ORIG" ]'
run_roster edit --level repo --member a2-architect --effort ""
check "A2: edit --effort \"\" removes effort" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members[0])")" = "{\"role\":\"architect\"}" ]'
run_roster edit --level repo --member a2-ultra-advisor --model ""
check "A2: an ultra-advisor row's model can be cleared too" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members[1])")" = "{\"role\":\"ultra-advisor\",\"effort\":\"max\"}" ]'

# ============================================================ B: the ask
fresh_home
new_repo b1
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor"}]'
BEFORE=$(sum "$CFG")
run_split spawn-one implementor --dry-run
check "B1: spawn-one on a model-less member exits 2 with member-model-undefined" '[ "$RC" = 2 ] && [ "$(jq_out o.refused)" = member-model-undefined ] && [ "$(jq_out o.verb)" = spawn-one ] && [ "$(jq_out o.ok)" = false ]'
check "B1: members[0] carries name, role, class, allowed and fallback" '[ "$(jq_out "JSON.stringify(o.members)")" = "[{\"name\":\"b1-implementor\",\"role\":\"implementor\",\"class\":\"implement\",\"allowed\":[\"opus\",\"sonnet\",\"fable\",\"inherit\"],\"fallback\":{\"model\":\"opus\",\"from\":\"b1-architect\"}}]" ]'
check "B1: rerun pins the member and carries a literal <MODEL>" '[[ "$(jq_out o.rerun)" == *"--member b1-implementor --model <MODEL>" ]]'
check "B1: the message is on stderr, prefixed roster.mjs:" '[[ "$STDERR" == "roster.mjs: No model is defined"* ]]'
check "B1: no team file is created" '[ -z "$(team_files)" ]'

run_herdr spawn-one implementor --model sonnet
TF=$(team_files)
check "B2: --model sonnet launches the member on sonnet" '[ "$RC" = 0 ] && [[ "$(agent_starts)" == *"--model sonnet"* ]]'
check "B2: the team record holds model sonnet" '[ -n "$TF" ] && [ "$(jq_file "$TF" "t.members.find(m=>m.name===\"b1-implementor\").model")" = sonnet ]'
check "B2/A3: the roster file is byte-identical" '[ "$(sum "$CFG")" = "$BEFORE" ]'

new_repo b3
roster_json '[{"role":"ultra-advisor","model":"fable"},{"role":"architect","model":"opus"},{"role":"reviewer","model":"sonnet"},{"role":"implementor"}]'
run_split spawn-one implementor --dry-run
check "B3: the fallback is the architect's opus, not the Ultra-Advisor's fable" '[ "$(jq_out "JSON.stringify(o.members[0].fallback)")" = "{\"model\":\"opus\",\"from\":\"b3-architect\"}" ]'
RERUN=$(jq_out o.rerun)
check "B3: rerun_fallback is rerun with <MODEL> replaced by opus" '[ "$(jq_out o.rerun_fallback)" = "${RERUN/<MODEL>/opus}" ]'

new_repo b3a
roster_json '[{"role":"ultra-advisor","model":"fable"},{"role":"implementor"}]'
run_split spawn-one implementor --dry-run
check "B3a: an advise-class model is no candidate: fallback null" '[ "$RC" = 2 ] && [ "$(jq_out o.members[0].fallback)" = null ] && [ "$(jq_out o.rerun_fallback)" = null ]'

new_repo b3b
run_roster role set docs-writer --class implement --description "Writes docs." --scaffold user
roster_json '[{"role":"docs-writer","model":"fable"},{"role":"architect"}]'
run_split spawn-one architect --dry-run
check "B3b: a custom implement-class member's fable is the architect's fallback" '[ "$(jq_out "JSON.stringify(o.members[0].fallback)")" = "{\"model\":\"fable\",\"from\":\"b3b-docs-writer\"}" ]'

new_repo b4
roster_json '[{"role":"ultra-advisor"},{"role":"architect","model":"opus"}]'
run_split spawn-one ultra-advisor --dry-run
check "B4: a model-less ultra-advisor borrows the architect's opus" '[ "$(jq_out "JSON.stringify(o.members[0].fallback)")" = "{\"model\":\"opus\",\"from\":\"b4-architect\"}" ] && [ "$(jq_out "JSON.stringify(o.members[0].allowed)")" = "[\"fable\",\"opus\"]" ]'
roster_json '[{"role":"ultra-advisor"},{"role":"architect","model":"sonnet"},{"role":"reviewer","model":"sonnet"}]'
run_split spawn-one ultra-advisor --dry-run
check "B4: ...but never sonnet: fallback and rerun_fallback null" '[ "$RC" = 2 ] && [ "$(jq_out o.members[0].fallback)" = null ] && [ "$(jq_out o.rerun_fallback)" = null ]'

new_repo b5
roster_json '[{"role":"architect"},{"role":"implementor","model":"inherit"}]'
run_split spawn-one architect --dry-run
check "B5: inherit is never borrowed: fallback null" '[ "$RC" = 2 ] && [ "$(jq_out o.members[0].fallback)" = null ] && [ "$(jq_out o.rerun_fallback)" = null ]'
roster_json '[{"role":"architect"},{"role":"reviewer"}]'
run_split spawn-one architect --dry-run
check "B5: ...and with no chain model at all, null too" '[ "$(jq_out o.members[0].fallback)" = null ]'
check "B5: the message says to stop and report when there is no fallback" '[[ "$(jq_out o.message)" == *"stops and reports"* ]]'

# ---- legwork: skipped while task-gopher is installed, never given a chain model
new_repo b6
roster_json '[{"role":"architect","model":"opus"},{"role":"reviewer","model":"opus"},{"role":"task-runner"}]'
fresh_home
run_roster create --plan
check "B6/B6d: no task-gopher record: the task-runner is listed with fallback null, never the chain's opus" '[ "$RC" = 0 ] && [ "$(jq_out "JSON.stringify(o.members_needing_model.map(m=>[m.name,m.fallback]))")" = "[[\"b6-task-runner\",null]]" ] && [ "$(jq_out "\"skipped_members\" in o")" = false ]'
mkdir -p "$FAKEHOME/.claude/plugins/cache/x/task-gopher/agents"; printf -- '---\nmodel: haiku\n---\n' > "$FAKEHOME/.claude/plugins/cache/x/task-gopher/agents/task-gopher.md"
run_roster create --plan
check "B6d: a cache directory with no install record is not task-gopher: still listed" '[ "$(jq_out "o.members_needing_model[0].name")" = b6-task-runner ] && [ "$(jq_out o.members_needing_model[0].fallback)" = null ]'
run_herdr create --spawn
check "B6d: create --spawn refuses, listing the task-runner with rerun_fallback null" '[ "$RC" = 2 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = b6-task-runner ] && [ "$(jq_out o.rerun_fallback)" = null ]'
tg_home; rm "$SANDBOX/tg/agents/task-gopher.md"
run_roster create --plan
check "B6e: a record whose agents/task-gopher.md is missing: listed, fallback null" '[ "$RC" = 0 ] && [ "$(jq_out "o.members_needing_model[0].name")" = b6-task-runner ] && [ "$(jq_out o.members_needing_model[0].fallback)" = null ]'
fresh_home; mkdir -p "$FAKEHOME/.claude/plugins"; echo 'not json{' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
run_roster create --plan
check "B6e: an unreadable installed_plugins.json: listed, fallback null, no crash" '[ "$RC" = 0 ] && [ "$(jq_out "o.members_needing_model[0].name")" = b6-task-runner ] && [ "$(jq_out o.members_needing_model[0].fallback)" = null ]'
tg_home
run_roster create --plan
check "B6/B6f: with task-gopher installed the task-runner is skipped — never listed, never given the chain's opus" '[ "$RC" = 0 ] && [ "$(jq_out "\"members_needing_model\" in o")" = false ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = b6-architect,b6-reviewer ] && [ "$(jq_out "o.skipped_members[0].name")" = b6-task-runner ]'

new_repo b6c
roster_json '[{"role":"architect","model":"opus"},{"role":"reviewer","model":"opus"},{"role":"task-runner"}]'
BEFORE=$(sum "$CFG")
run_herdr create --spawn
STARTS=$(agent_starts)
check "B6c: create --spawn exits 0 with no refusal and launches the architect and reviewer only" '[ "$RC" = 0 ] && [ "$(jq_out o.refused)" = undefined ] && [ "$(printf "%s\n" "$STARTS" | grep -c .)" = 2 ] && [[ "$STARTS" == *b6c-architect* ]] && [[ "$STARTS" == *b6c-reviewer* ]] && [[ "$STARTS" != *task-runner* ]]'
check "B6c: skipped_members is exactly [{name, role, handoff}], and the team is not partial" '[ "$(jq_out "JSON.stringify(o.skipped_members)")" = "[{\"name\":\"b6c-task-runner\",\"role\":\"task-runner\",\"handoff\":\"task-gopher:task-gopher\"}]" ] && [ "$(jq_out o.partial)" = false ] && [ "$(jq_out "o.members.some(m=>m.role===\"task-runner\")")" = false ]'
check "B6c: the message sends the legwork to task-gopher and covers the not-dispatchable case" '[[ "$(jq_out o.message)" == *"task-gopher:task-gopher subagents"* ]] && [[ "$(jq_out o.message)" == *"not among your available agent types"* ]] && [[ "$(jq_out o.message)" == *"--no-legwork-handoff"* ]]'
run_herdr create --commit --verified '["b6c-architect","b6c-reviewer","b6c-task-runner"]' --transport herdr --roster-level repo
TF=$(team_files)
# Whether the team in <team file> is partial, derived from its roster exactly as it is displayed.
derived_partial() { HOME="$FAKEHOME" node --input-type=module -e '
  const [H, cwd, f] = process.argv.slice(1);
  const { teamIsPartial } = await import(H + "/lib-config.mjs");
  const { readFileSync } = await import("node:fs");
  const { basename, dirname } = await import("node:path");
  const legacy = basename(f) === "team.json";
  process.stdout.write(String(teamIsPartial(legacy ? dirname(f) : dirname(dirname(f)), cwd, legacy ? null : basename(f, ".json"), JSON.parse(readFileSync(f, "utf8")))));' "$H" "$PROJ" "$1"; }
check "B6c: the committed team has no task-runner, even when --verified names it, and is not partial" '[ "$RC" = 0 ] && [ "$(jq_file "$TF" "t.members.map(m=>m.role).join()")" = architect,reviewer ] && [ "$(derived_partial "$TF")" = false ]'
check "B6c: --commit lists skipped_members" '[ "$(jq_out "o.skipped_members[0].name")" = b6c-task-runner ]'
check "B6c: the roster file is byte-identical" '[ "$(sum "$CFG")" = "$BEFORE" ]'
new_repo b6c-plan
roster_json '[{"role":"architect","model":"opus"},{"role":"reviewer","model":"opus"},{"role":"task-runner"}]'
run_roster create --plan
check "B6c: create --plan: the task-runner is in neither members[] nor members_needing_model, and is in skipped_members" '[ "$(jq_out "o.members.some(m=>m.role===\"task-runner\")")" = false ] && [ "$(jq_out "\"members_needing_model\" in o")" = false ] && [ "$(jq_out "o.skipped_members[0].name")" = b6c-plan-task-runner ]'
run_roster create --plan
check "B6c: nothing persists — the next plan decides again" '[ "$(jq_out "o.skipped_members[0].name")" = b6c-plan-task-runner ] && [ "$(jq_file "$CFG" "JSON.stringify(t.roster.members[2])")" = "{\"role\":\"task-runner\"}" ]'

new_repo b6c2
roster_json '[{"role":"architect","model":"opus"},{"role":"task-runner"}]'
run_split spawn-one task-runner --dry-run
check "B6c2: spawn-one task-runner still exits 2 on the role check, with no skip output" '[ "$RC" = 2 ] && [ -z "$OUT" ] && [[ "$STDERR" == "roster.mjs: spawn-one: role must be one of ultra-advisor, architect, reviewer, implementor, got \"task-runner\"" ]]'
run_split spawn-ad-hoc task-runner --dry-run
check "B6c2: spawn-ad-hoc task-runner still exits 2 on the role check, with no skip output" '[ "$RC" = 2 ] && [ -z "$OUT" ] && [[ "$STDERR" == "roster.mjs: spawn-ad-hoc: under-specified — \"task-runner\" is not a role"* ]]'

new_repo b6c3
roster_json '[{"role":"architect"},{"role":"task-runner"}]'
run_herdr create --spawn
check "B6c3: create --spawn refuses listing only the architect" '[ "$RC" = 2 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = b6c3-architect ] && [ "$(herdr_calls)" = 0 ]'
check "B6c3: neither rerun nor rerun_fallback mentions the task-runner" '[[ "$(jq_out o.rerun)" != *task-runner* ]] && [[ "$(jq_out o.rerun_fallback)" != *task-runner* ]]'
RERUN=$(jq_out o.rerun)
run_herdr_cmd "${RERUN/<MODEL>/opus}"
check "B6c3: running rerun with the architect's model launches it and skips the task-runner" '[ "$RC" = 0 ] && [[ "$(agent_starts)" == *"b6c3-architect"*"--model opus"* ]] && [[ "$(agent_starts)" != *task-runner* ]] && [ "$(jq_out "o.skipped_members[0].name")" = b6c3-task-runner ]'

new_repo b6g
roster_json '[{"role":"architect","model":"opus"},{"role":"reviewer","model":"opus"},{"role":"task-runner"}]'
BEFORE=$(sum "$CFG")
run_herdr create --spawn --no-legwork-handoff
check "B6g: --no-legwork-handoff: create --spawn refuses, listing the task-runner with fallback null" '[ "$RC" = 2 ] && [ "$(jq_out "JSON.stringify(o.members.map(m=>[m.name,m.fallback]))")" = "[[\"b6g-task-runner\",null]]" ] && [ "$(jq_out o.rerun_fallback)" = null ] && [ "$(herdr_calls)" = 0 ]'
run_herdr create --spawn --member-model b6g-task-runner=haiku --no-legwork-handoff
check "B6g: rerunning with --member-model <tr>=haiku launches all three, the task-runner on haiku" '[ "$RC" = 0 ] && [ "$(printf "%s\n" "$(agent_starts)" | grep -c .)" = 3 ] && [[ "$(agent_starts)" == *"b6g-task-runner"*"--model haiku"* ]] && [ "$(jq_out "\"skipped_members\" in o")" = false ]'
run_roster create --plan --no-legwork-handoff
check "B6g: create --plan --no-legwork-handoff lists it in members_needing_model, with no skipped_members" '[ "$RC" = 0 ] && [ "$(jq_out "o.members_needing_model[0].name")" = b6g-task-runner ] && [ "$(jq_out "\"skipped_members\" in o")" = false ]'
check "B6g: the roster is byte-identical throughout" '[ "$(sum "$CFG")" = "$BEFORE" ]'

new_repo b6h
roster_json '[{"role":"architect","model":"opus"},{"role":"task-runner","model":"haiku"}]'
run_roster create --plan
check "B6h: a task-runner storing haiku is never listed or skipped" '[ "$(jq_out "\"members_needing_model\" in o")" = false ] && [ "$(jq_out "\"skipped_members\" in o")" = false ]'
run_herdr create --spawn
check "B6h: ...and launches normally" '[ "$RC" = 0 ] && [[ "$(agent_starts)" == *"b6h-task-runner"*"--model haiku"* ]]'

new_repo b6a
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor"}]'
run_split spawn-one architect --dry-run
check "B6a: a stored model with no effort launches with no refusal and no --effort" '[ "$RC" = 0 ] && [[ "$(jq_out "o.launch.join()")" != *--effort* ]]'
run_roster create --plan
check "B6a: a listed member carries no effort field" '[ "$(jq_out "Object.keys(o.members_needing_model[0]).join()")" = name,role,class,allowed,fallback ]'

# ---- B6b: the route gate prints spawn-ad-hoc without the Agent call's model
new_repo b6b
echo '{"version":1,"enabled":true,"roles":{}}' > "$CFG"
gate() { # <tool_input json>
  printf '{"session_id":"g-b6b","cwd":"%s","tool_name":"Agent","tool_input":%s,"hook_event_name":"PreToolUse"}' "$PROJ" "$1" \
    | env -u HERDR_ENV -u HERDR_PANE_ID HOME="$FAKEHOME" node "$H/pretooluse-route-gate.mjs" 2>&1
}
WITH=$(gate '{"subagent_type":"ah:architect","prompt":"x","model":"opus"}')
WITHOUT=$(gate '{"subagent_type":"ah:architect","prompt":"x"}')
OUT=$WITH
check "B6b: the denial prints spawn-ad-hoc with no --model" '[[ "$WITH" == *"spawn-ad-hoc architect --cwd"* ]] && [[ "$WITH" != *"--model"* ]]'
check "B6b: nothing else in the denial differs from a call without a model" '[ "$WITH" = "$WITHOUT" ]'

# ---- create
new_repo b7
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor"},{"role":"reviewer"}]'
run_herdr create --spawn
check "B7: create --spawn refuses, listing both model-less members, launching nothing" '[ "$RC" = 2 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = b7-implementor,b7-reviewer ] && [ "$(herdr_calls)" = 0 ]'
check "B7: the refusal writes no team file" '[ -z "$(team_files)" ]'
check "B7: rerun has one --member-model <MODEL> per listed member" '[[ "$(jq_out o.rerun)" == *"--member-model b7-implementor=<MODEL> --member-model b7-reviewer=<MODEL>" ]]'
run_herdr create --spawn --member-model b7-implementor=sonnet --member-model b7-reviewer=opus
check "B7: rerunning with --member-model for both proceeds" '[ "$RC" = 0 ] && [ "$(jq_out "o.members.map(m=>m.model).join()")" = opus,sonnet,opus ] && [[ "$(agent_starts)" == *"b7-implementor"*"--model sonnet"* ]]'

new_repo b7b
roster_json '[{"role":"architect"},{"role":"implementor"},{"role":"reviewer","model":"opus"}]'
run_herdr create --spawn --member-model b7b-architect=opus --member-model b7b-reviewer=sonnet
RERUN=$(jq_out o.rerun)
check "B7b: the rerun keeps a non-listed member's --member-model, adding <MODEL> only for the listed one" '[ "$RC" = 2 ] && [ "$(jq_out "o.members.map(m=>m.name).join()")" = b7b-implementor ] && [[ "$RERUN" == *"--member-model b7b-architect=opus"* ]] && [[ "$RERUN" == *"--member-model b7b-reviewer=sonnet"* ]] && [[ "$RERUN" == *" --member-model b7b-implementor=<MODEL>" ]]'

new_repo b8
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor"},{"role":"reviewer"}]'
run_roster create --plan
check "B8: --plan never exits 2 on models and lists members_needing_model last" '[ "$RC" = 0 ] && [ "$(jq_out "Object.keys(o).at(-1)")" = members_needing_model ] && [ "$(jq_out "o.members_needing_model.length")" = 2 ]'
run_roster create --plan --member-model b8-implementor=sonnet --member-model b8-reviewer=fable
check "B8: --member-model for all of them removes the key, and each launch carries its --model" '[ "$RC" = 0 ] && [ "$(jq_out "\"members_needing_model\" in o")" = false ] && [[ "$(jq_out "o.members[1].spawn.launch.join()")" == *"--model sonnet"* ]] && [[ "$(jq_out "o.members[2].spawn.launch.join()")" == *"--model fable"* ]]'
new_repo b8b
roster_json '[{"role":"architect","model":"opus"}]'
run_roster create --plan
check "B8: a plan where every member has a model has no members_needing_model" '[ "$RC" = 0 ] && [ "$(jq_out "\"members_needing_model\" in o")" = false ]'

new_repo b9
roster_json '[{"role":"architect","model":"opus"},{"role":"ultra-advisor"},{"role":"implementor","kind":"pi","route":"pane"}]'
run_roster create --plan --member-model nobody=opus;                                        check "B9: an unknown --member-model name exits 2" '[ "$RC" = 2 ]'
run_roster create --plan --member-model b9-architect=opus --member-model b9-architect=sonnet; check "B9: a duplicate --member-model name exits 2" '[ "$RC" = 2 ]'
run_roster create --plan --member-model b9-implementor=opus;                                check "B9: --member-model on a member of a kind with no model mapping (pi) exits 2" '[ "$RC" = 2 ]'
run_roster create --plan --member-model b9-ultra-advisor=sonnet;                            check "B9: ultra-advisor=sonnet exits 2" '[ "$RC" = 2 ] && [[ "$OUT" == *"is not valid for role"* ]]'
run_roster create --plan --member-model b9-architect=haiku;                                 check "B9: architect=haiku exits 2" '[ "$RC" = 2 ]'

new_repo b10
run_split spawn-ad-hoc architect --dry-run
check "B10: spawn-ad-hoc without --model refuses with verb spawn-ad-hoc" '[ "$RC" = 2 ] && [ "$(jq_out o.verb)" = spawn-ad-hoc ] && [[ "$(jq_out o.rerun)" == *"--model <MODEL>" ]]'
run_split spawn-ad-hoc architect --model opus --dry-run
check "B10: with --model opus it behaves as before" '[ "$RC" = 0 ] && [ "$(jq_out o.dry_run)" = true ] && [[ "$(jq_out "o.launch.join()")" == *"--model opus"* ]]'

new_repo b11
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor"}]'
run_herdr create --spawn --team averyveryveryverylongteamnamexyz
check "B11: the team-name refusal wins over the model refusal" '[ "$RC" = 2 ] && [ "$(jq_out o.refused)" = team-name-unusable ]'

new_repo b12
roster_json '[{"role":"architect","model":"sonnet"},{"role":"implementor"}]'
run_roster create --commit --verified '["b12-architect","b12-implementor"]' --member-model b12-implementor=opus --transport terminal --roster-level repo
TF=$(team_files)
check "B12: --commit records the --member-model value" '[ "$RC" = 0 ] && [ "$(jq_file "$TF" "t.members.find(m=>m.name===\"b12-implementor\").model")" = opus ]'
new_repo b12b
roster_json '[{"role":"architect","model":"sonnet"},{"role":"implementor"}]'
run_roster create --commit --verified '["b12b-architect","b12b-implementor"]' --transport terminal --roster-level repo
TF=$(team_files)
check "B12: without it, --commit records the row's model or none, and exits 0" '[ "$RC" = 0 ] && [ "$(jq_file "$TF" "t.members[0].model")" = sonnet ] && [ "$(jq_file "$TF" "\"model\" in t.members[1]")" = false ]'

# --verified objects: a model-less auto-skipped member never ran, so its object is dropped; one that
# carries a model ran on it, so it is kept.
tg_home
ARCH_OBJ='{"role":"architect","name":"%s-architect","route":"peer","model":"opus","transport_id":"p1"}'
new_repo b12c
roster_json '[{"role":"architect","model":"opus"},{"role":"task-runner"}]'
run_roster create --commit --verified "[$(printf "$ARCH_OBJ" b12c),{\"role\":\"task-runner\",\"name\":\"b12c-task-runner\",\"route\":\"peer\",\"transport_id\":\"p2\"}]" --transport herdr --roster-level repo
TF=$(team_files)
check "B12c: --commit drops a model-less auto-skipped --verified object" '[ "$RC" = 0 ] && [ "$(jq_file "$TF" "t.members.map(m=>m.name).join()")" = b12c-architect ] && [ "$(jq_out "o.skipped_members[0].name")" = b12c-task-runner ]'
new_repo b12d
roster_json '[{"role":"architect","model":"opus"},{"role":"task-runner"}]'
run_roster create --commit --verified "[$(printf "$ARCH_OBJ" b12d),{\"role\":\"task-runner\",\"name\":\"b12d-task-runner\",\"route\":\"peer\",\"model\":\"haiku\",\"transport_id\":\"p2\"}]" --transport herdr --roster-level repo
TF=$(team_files)
check "B12c: ...and keeps one that carries a model" '[ "$RC" = 0 ] && [ "$(jq_file "$TF" "t.members.map(m=>m.name+\":\"+m.model).join()")" = b12d-architect:opus,b12d-task-runner:haiku ] && [ "$(jq_out "\"skipped_members\" in o")" = false ]'

new_repo b13
roster_json '[{"role":"architect","model":"opus"},{"role":"implementor","kind":"pi","route":"pane"},{"role":"task-runner","route":"subagent"}]'
run_herdr create --plan
check "B13: a member of a kind with no model mapping (pi) and a subagent-routed member are never listed" '[ "$RC" = 0 ] && [ "$(jq_out "\"members_needing_model\" in o")" = false ]'
run_herdr create --spawn
check "B13: ...and never refused" '[ "$RC" = 0 ] && [ "$(jq_out "o.refused")" = undefined ]'

# ============================================================ D: skills
ROSTER_SKILL="$PLUGIN/skills/agent-roster/SKILL.md"
TEAM_SKILL="$PLUGIN/skills/agent-team/SKILL.md"
check "D1: agent-roster no longer prefills defaults from ROLE_DEFAULTS" '! grep -q "Prefill/offer defaults" "$ROSTER_SKILL" && grep -q "first option is \`Undefined — *$" "$ROSTER_SKILL"'
check "D2: agent-team handles member-model-undefined on the one-peer, spawn-one and spawn-ad-hoc paths and in create" '[ "$(grep -c member-model-undefined "$TEAM_SKILL")" -ge 4 ] && grep -q members_needing_model "$TEAM_SKILL"'
check "D2: agent-team sends skipped members' legwork to task-gopher and asks nothing about them" 'grep -q "skipped_members" "$TEAM_SKILL" && grep -q "Never ask about it" "$TEAM_SKILL" && ! grep -q -- "--skip-member" "$TEAM_SKILL"'
check "D2: agent-team checks the available agent types before the bare plan and carries --no-legwork-handoff" 'grep -q "Before the bare \`--plan\`" "$TEAM_SKILL" && grep -q "not among" "$TEAM_SKILL" && grep -q -- "--no-legwork-handoff\` to every create phase" "$TEAM_SKILL" && ! grep -q relaunch "$TEAM_SKILL"'

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
