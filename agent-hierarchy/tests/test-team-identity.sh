#!/bin/bash
# agent-hierarchy — a team's identity belongs to the team (spec 0057): the team file records the
# roster block it was built from and its layout; the default layout is a stored global preference;
# a session's own team is resolved before the default scope; a launched member knows its team
# from AH_TEAM_FILE; `--roster` selects a template and `--team` names only a live team.
# HOME-redirected; no test reaches the real herdr, tmux, or ~/.claude.
# Usage: bash tests/test-team-identity.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-identity-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/claude"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux" "$SANDBOX/nolaunch/claude"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE CLAUDE_PID
FAKEHOME="$SANDBOX/home"
GLOBAL="$FAKEHOME/.claude/agent-hierarchy.json"
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
if (args[0] === "pane" && args[1] === "rename") finish(0);
process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"
FAKE_STATE_DIR="$SANDBOX/state"

# A fresh repo per case: <name> sets PROJ, HD, TEAMS and resets fake-herdr state.
new_repo() {
  PROJ="$SANDBOX/$1"
  rm -rf "$PROJ" "$FAKE_STATE_DIR"; mkdir -p "$PROJ/.claude" "$FAKE_STATE_DIR"
  (cd "$PROJ" && git init -q)
  HD="$PROJ/.claude/hierarchy"
  TEAMS="$HD/teams"
  printf '{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}' > "$FAKE_STATE_DIR/geometry.json"
}
fresh_home() { rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME/.claude"; }

# roster.mjs under the fake HOME, on the terminal transport (no herdr, tmux fails), owner pid = this shell.
run_roster() {
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
run_roster_split() { # stdout and stderr apart: STDOUT / STDERR
  env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr"; RC=$?
  STDOUT=$(cat "$SANDBOX/stdout"); STDERR=$(cat "$SANDBOX/stderr"); OUT="$STDOUT$STDERR"
}
# roster.mjs on the fake herdr transport.
run_herdr() {
  OUT=$(env HERDR_ENV=1 HERDR_PANE_ID=p0 HOME="$FAKEHOME" CLAUDE_PID=$$ PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
run_herdr_split() { # stdout only in OUT, stderr in STDERR
  OUT=$(env HERDR_ENV=1 HERDR_PANE_ID=p0 HOME="$FAKEHOME" CLAUDE_PID=$$ PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
setup_roster() { # <roles...> — a repo-level default roster
  run_roster init --level repo --route peer
  for r in "$@"; do run_roster add --level repo --role "$r" --model opus; done
}
jq_file() { # <file> <js expr over t>
  node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((new Function("t","return "+process.argv[2]))(t)))' "$1" "$2" 2>/dev/null
}
jq_out() { # <js expr over o> — over $OUT as JSON
  printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{o=JSON.parse(s.slice(s.indexOf("{")))}process.stdout.write(String((new Function("o","return "+process.argv[1]))(o)))})' "$1" 2>/dev/null
}
commit_team() { # <team name or ""> <member json> [extra args...]
  local team=$1 members=$2; shift 2
  if [ -n "$team" ]; then run_roster create --commit --team "$team" --verified "$members" --transport terminal --roster-level repo "$@"
  else run_roster create --commit --verified "$members" --transport terminal --roster-level repo "$@"; fi
}

# ==================================================================== step 1 — the team carries its identity
fresh_home; new_repo proj1; setup_roster architect
BASE1="$(basename "$PROJ")"
commit_team "" "[{\"name\":\"$BASE1-architect\",\"role\":\"architect\",\"route\":\"peer\"}]"
check "A1: create --commit writes a team file carrying roster (null) and layout" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/$BASE1.json" "JSON.stringify([t.roster, t.layout])")" = "[null,\"auto\"]" ]'
rm -rf "$HD"
run_herdr spawn-one architect
check "A1b: a team created implicitly by spawn-one carries roster (null) and layout" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/$BASE1.json" "JSON.stringify([t.roster, t.layout])")" = "[null,\"auto\"]" ]'

fresh_home; new_repo proj2; setup_roster architect reviewer
BASE2="$(basename "$PROJ")"
run_herdr create --plan --mode grid
check "A2: create --plan --mode grid reports layout grid (explicit) and layout_plan grid" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.layout.mode+\"/\"+o.layout.source+\"/\"+o.layout_plan.mode")" = "grid/explicit/grid" ]'
check "A2b: --plan never stores the layout" '[ ! -e "$GLOBAL" ]'
commit_team "" "[{\"name\":\"$BASE2-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --mode grid
check "A2c: create --commit --mode grid records layout grid on the team" '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/$BASE2.json" t.layout)" = "grid" ]'
rm -f "$GLOBAL"
run_herdr spawn-one reviewer --dry-run
check "A2d: the next spawn-one into that team uses the team's grid, not the stored preference" '[ "$RC" -eq 0 ] && [ "$(jq_out o.mode)" = "grid" ]'

fresh_home; new_repo proj4; setup_roster architect
BASE4="$(basename "$PROJ")"
run_roster create --plan
check "A4: no global file, bare create --plan → layout auto, source default" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.layout.mode+\"/\"+o.layout.source")" = "auto/default" ]'
commit_team "" "[{\"name\":\"$BASE4-architect\",\"role\":\"architect\",\"route\":\"peer\"}]"
check "A4b: bare create --commit creates no global file" '[ "$RC" -eq 0 ] && [ ! -e "$GLOBAL" ] && [ "$(jq_file "$TEAMS/$BASE4.json" t.layout)" = "auto" ]'

fresh_home; new_repo proj5; setup_roster architect
BASE5="$(basename "$PROJ")"
printf '{\n  "version": 1,\n  "handoffs": "confirm",\n  "custom": {"keep": [1, 2]}\n}\n' > "$GLOBAL"
commit_team "" "[{\"name\":\"$BASE5-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --mode columns
check "A5: create --commit --mode columns stores teamLayout columns in the global file" '[ "$RC" -eq 0 ] && [ "$(jq_file "$GLOBAL" t.teamLayout)" = "columns" ]'
check "A5b: every other key of the global file is unchanged" \
  '[ "$(jq_file "$GLOBAL" "JSON.stringify([t.version,t.handoffs,t.custom,Object.keys(t).sort()])")" = "[1,\"confirm\",{\"keep\":[1,2]},[\"custom\",\"handoffs\",\"teamLayout\",\"version\"]]" ]'
rm -rf "$HD"
run_roster create --plan
check "A5c: the next bare create --plan reports columns, source stored" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.layout.mode+\"/\"+o.layout.source")" = "columns/stored" ]'
run_roster create --plan --mode grid
check "A5d: create --plan --mode grid writes nothing" '[ "$RC" -eq 0 ] && [ "$(jq_file "$GLOBAL" t.teamLayout)" = "columns" ]'

# A6: a global file holding only the stored layout changes no resolution.
fresh_home; new_repo proj6; setup_roster architect
BASE6="$(basename "$PROJ")"
snapshot() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    const r = C.resolveConfig('$PROJ');
    process.stdout.write(JSON.stringify({configured: r.configured, enabled: r.enabled, route: r.route, msgs: r.msgs, handoffs: r.handoffs, roles: r.roles, roster: r.roster, warnings: r.warnings}));
  " 2>&1)
  local show; show=$(env -u HERDR_ENV HOME="$FAKEHOME" node "$H/roster.mjs" show --cwd "$PROJ" 2>&1; env -u HERDR_ENV HOME="$FAKEHOME" node "$H/roster.mjs" show --level global --cwd "$PROJ" 2>&1)
  printf '%s\n%s' "$OUT" "$show"
}
BEFORE6=$(snapshot)
commit_team "" "[{\"name\":\"$BASE6-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --mode grid
check "A6: with no global file before, the write creates one holding only version + teamLayout" \
  '[ "$(jq_file "$GLOBAL" "JSON.stringify(t)")" = "{\"version\":1,\"teamLayout\":\"grid\"}" ]'
AFTER6=$(snapshot)
check "A6b: resolved roster, enabled, route, msgs, handoffs, roles, configured and show are identical" '[ "$BEFORE6" = "$AFTER6" ]'
# An unconfigured machine stays unconfigured.
fresh_home; new_repo proj6b
printf '{"version":1,"teamLayout":"grid"}\n' > "$GLOBAL"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(String(C.resolveConfig('$PROJ').configured));" 2>&1)
check "A6c: a preference-only global file leaves an unconfigured machine unconfigured" '[ "$OUT" = "false" ]'

fresh_home; new_repo proj7; setup_roster architect
node -e 'const f=process.argv[1];const d=JSON.parse(require("fs").readFileSync(f,"utf8"));d.teamLayout="grid";require("fs").writeFileSync(f,JSON.stringify(d))' "$PROJ/.claude/agent-hierarchy.json"
run_roster create --plan
check "A7: teamLayout in a repo-level file is ignored with a warning" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.layout.mode)" = "auto" ] && echo "$OUT" | grep -q "teamLayout in .* is ignored"'
printf '{"version":1,"teamLayout":"diagonal"}\n' > "$GLOBAL"
node -e 'const f=process.argv[1];const d=JSON.parse(require("fs").readFileSync(f,"utf8"));delete d.teamLayout;require("fs").writeFileSync(f,JSON.stringify(d))' "$PROJ/.claude/agent-hierarchy.json"
run_roster create --plan
check "A7b: an invalid stored value is ignored with a warning" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.layout.mode+\"/\"+o.layout.source")" = "auto/default" ] && echo "$OUT" | grep -q "\"diagonal\" .* is not a layout"'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(C.resolveConfig('$PROJ').warnings.join('\n'));" 2>&1)
check "A7c: resolveConfig carries the same warning" 'echo "$OUT" | grep -q "\"diagonal\" .* is not a layout"'

fresh_home; new_repo proj8; setup_roster architect
BASE8="$(basename "$PROJ")"
printf '{"version":1, not json' > "$GLOBAL"
commit_team "" "[{\"name\":\"$BASE8-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --mode grid
check "A8: an unparseable global file → create still succeeds, warns, and the file is left untouched" \
  '[ "$RC" -eq 0 ] && [ -e "$TEAMS/$BASE8.json" ] && echo "$OUT" | grep -q "was not stored as the default" && [ "$(cat "$GLOBAL")" = "{\"version\":1, not json" ]'
rm -rf "$HD"; rm -f "$GLOBAL"; chmod 500 "$FAKEHOME/.claude"
commit_team "" "[{\"name\":\"$BASE8-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --mode grid
chmod 700 "$FAKEHOME/.claude"
check "A8b: an unwritable global location → create still succeeds and warns" \
  '[ "$RC" -eq 0 ] && [ -e "$TEAMS/$BASE8.json" ] && echo "$OUT" | grep -q "was not stored as the default"'

# A3: a legacy team.json is named by its members, whatever config says.
fresh_home; new_repo proj3
mkdir -p "$HD"
printf '{"version":1,"team_id":"T-legacy","created":"2026-01-01T00:00:00Z","transport":"terminal","orchestrator":{"session_id":null,"pid":%s},"members":[{"role":"architect","name":"ct-architect","route":"peer"},{"role":"reviewer","name":"ct-reviewer-2","route":"peer"}]}' $$ > "$HD/team.json"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); const i = C.teamPrefixInfo('$PROJ', null); process.stdout.write(i.prefix + '/' + i.source);" 2>&1)
check "A3: a legacy team.json whose members are ct-* yields prefix ct, source legacy-team" '[ "$OUT" = "ct/legacy-team" ]'

# ==================================================================== step 2 — a session's own team first
write_team() { # <name or ""> <owner pid> <members json> [extra top-level json fields]
  local f="$TEAMS/$1.json"; [ -z "$1" ] && f="$HD/team.json"
  mkdir -p "$(dirname "$f")"
  printf '{"version":1,"team_id":"T-%s","created":"%s","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":%s},"members":%s,"partial":false%s}' \
    "${1:-legacy}" "$(node -e 'console.log(new Date().toISOString())')" "$2" "$3" "${4:+,$4}" > "$f"
}
listing() { (cd "$HD" 2>/dev/null && find . -type f | sort | xargs cat 2>/dev/null); }
DEAD_PID=$(node -e 'const {execFileSync}=require("child_process");const p=Number(execFileSync("sh",["-c","echo $$"]).toString());console.log(p)')

fresh_home; new_repo proj-b1; setup_roster architect reviewer
BASEB="$(basename "$PROJ")"
write_team ct $$ '[{"role":"reviewer","name":"ct-reviewer","route":"peer","transport_id":"p9"}]'
run_herdr spawn-one architect
check "B1: bare spawn-one by the owner of live teams/ct.json joins ct as ct-architect" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/ct.json" "t.members.map(m=>m.name).join(\",\")")" = "ct-reviewer,ct-architect" ]'
check "B1b: and no teams/<basename>.json was written" '[ ! -e "$TEAMS/$BASEB.json" ] && [ ! -e "$HD/team.json" ]'

write_team zz $$ '[]'
BEFORE_B2=$(listing)
run_herdr spawn-one implementor
check "B2: an owner of two live teams gets a refusal naming both, and nothing is written" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "\"ct\"" && echo "$OUT" | grep -q "\"zz\"" && echo "$OUT" | grep -q -- "--team" && [ "$(listing)" = "$BEFORE_B2" ]'
rm -f "$TEAMS/zz.json"

OUT=$(env -u HERDR_ENV -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1); RC=$?
check "B3: with no pid resolvable, the default scope is used as before (basename names)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"$BASEB-architect\"" && ! echo "$OUT" | grep -q "\"ct-architect\""'

run_roster create --plan
check "B4: bare create --plan by the owner of a live team refuses (same-owner --plan row)" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "already exists"'
commit_team "" '[{"name":"ct-architect","role":"architect","route":"peer"}]'
check "B4b: bare create --commit by the owner is allowed and rewrites its own team" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/ct.json" "t.members.map(m=>m.name).join(\",\")")" = "ct-architect" ] && [ ! -e "$TEAMS/$BASEB.json" ]'

write_team "$BASEB" "$DEAD_PID" '[]'
run_roster adopt --orchestrator-pid $$
check "B5: adopt with no --team still acts on the default scope, not the owned team" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/$BASEB.json" t.orchestrator.pid)" = "$$" ] && [ "$(jq_file "$TEAMS/ct.json" t.team_id)" != "" ]'

# B6: a team is live for its own owner at any age; the 24h cap only covers teams the invoker
# cannot vouch for.
fresh_home; new_repo proj-b6; setup_roster architect reviewer
BASEB6="$(basename "$PROJ")"
OLD=$(node -e 'console.log(new Date(Date.now() - 25 * 3600 * 1000).toISOString())')
write_team ct $$ '[{"role":"reviewer","name":"ct-reviewer","route":"peer","transport_id":"p9"}]' "\"created\":\"$OLD\""
run_herdr spawn-one architect
check "B6: a bare spawn-one by the owner joins its 25h-old team" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/ct.json" "t.members.map(m=>m.name).join(\",\")")" = "ct-reviewer,ct-architect" ] && [ ! -e "$TEAMS/$BASEB6.json" ]'
BEFORE_B6=$(cat "$TEAMS/ct.json")
run_roster create --plan
check "B6b: a bare create --plan by the owner refuses and leaves it byte-identical" '[ "$RC" -ne 0 ] && [ "$(cat "$TEAMS/ct.json")" = "$BEFORE_B6" ]'
# The hook's invoker is its parent process: re-own the team by the shell that runs the hook.
printf '{"session_id":"sess-b6","cwd":"%s","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" > "$SANDBOX/b6-input.json"
bash -c 'node -e "const f=process.argv[1],fs=require(\"fs\");const t=JSON.parse(fs.readFileSync(f,\"utf8\"));t.orchestrator.pid=Number(process.argv[2]);fs.writeFileSync(f,JSON.stringify(t))" "$1" $$
  env -u HERDR_PANE_ID -u TMUX_PANE HOME="$2" node "$3/sessionstart.mjs" < "$4" > /dev/null 2>&1
  true' _ "$TEAMS/ct.json" "$FAKEHOME" "$H" "$SANDBOX/b6-input.json"
check "B6c: SessionStart's stale-team sweep, run for the owning session, leaves the 25h-old team in place" '[ -e "$TEAMS/ct.json" ]'
write_team "$BASEB6" "$PPID" '[]' "\"created\":\"$OLD\""
run_roster create --plan
check "B6d: a 25h-old team owned by a different live pid is still stale — a bare create --plan clears it" '[ "$RC" -eq 0 ] && [ ! -e "$TEAMS/$BASEB6.json" ]'

# B7: a session id on both sides must agree — the only guard against a reused pid.
write_team ct $$ '[]' "\"orchestrator\":{\"session_id\":\"s1\",\"pid\":$$}"
BEFORE_B7=$(cat "$TEAMS/ct.json")
commit_team ct '[{"name":"ct-architect","role":"architect","route":"peer"}]' --session s2
check "B7: create --commit --session s2 into a team recording session s1 under the same pid is refused, untouched" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "records session s1" && [ "$(cat "$TEAMS/ct.json")" = "$BEFORE_B7" ]'
commit_team ct '[{"name":"ct-architect","role":"architect","route":"peer"}]' --session s1
check "B7b: with the recorded session it is the invoker's own team and the commit goes through" '[ "$RC" -eq 0 ]'

# ==================================================================== step 3 — a launched member knows its team
sleep 600 & OWNER_PID=$!
sleep 600 & OTHER_PID=$!
trap 'kill $OWNER_PID $OTHER_PID 2>/dev/null; rm -rf "$SANDBOX"' EXIT
resolve_team() { # <env assignments...> — resolveConfig(PROJ,{sessionId}).team and its prefix, as a hook computes them
  OUT=$(env -u AH_TEAM_FILE -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" "$@" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    const r = C.resolveConfig('$PROJ', { sessionId: 'sess-hook', pid: Number(process.env.P_PID || 0) || undefined });
    process.stdout.write(JSON.stringify({ team: r.team, prefix: C.teamPrefix('$PROJ', r.team), names: r.roster ? r.roster.members.map((m) => m.name) : null }));
  " 2>&1)
}

fresh_home; new_repo proj-p1; setup_roster architect reviewer
write_team ct "$OWNER_PID" '[]'
resolve_team AH_TEAM_FILE="$TEAMS/ct.json"
check "P1: a hook with AH_TEAM_FILE=<repo>/.../teams/ct.json in a session owning nothing resolves team ct" '[ "$(jq_out o.team)" = "ct" ]'
check "P1b: and derives ct-* names (prefix and roster names the route gate reads)" \
  '[ "$(jq_out o.prefix)" = "ct" ] && [ "$(jq_out "o.names.join(\",\")")" = "ct-architect,ct-reviewer" ]'
write_team zz "$OTHER_PID" '[]'
resolve_team AH_TEAM_FILE="$TEAMS/ct.json" P_PID="$OTHER_PID"
check "P2: the same env in a session whose pid owns live teams/zz.json resolves zz — owner steps first" '[ "$(jq_out o.team)" = "zz" ]'
rm -f "$TEAMS/zz.json"

new_repo proj-p3-other; OTHER_TEAMS="$TEAMS"
new_repo proj-p3; setup_roster architect
write_team ct "$OWNER_PID" '[]'
mkdir -p "$SANDBOX/elsewhere/teams"
for bad in "relative/teams/ct.json" "$TEAMS/../../../../proj-p3-other/.claude/hierarchy/teams/ct.json" "$SANDBOX/elsewhere/teams/ct.json" "$TEAMS/_bad.json" "$TEAMS/ct.txt"; do
  resolve_team AH_TEAM_FILE="$bad"
  check "P3: AH_TEAM_FILE=$bad is rejected — no throw, resolution continues to the default" '[ "$(jq_out o.team)" = "null" ]'
  OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" AH_TEAM_FILE="$bad" node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1); RC=$?
  check "P3b: whoami keeps the real reason and reports $bad as malformed" \
    '[ "$RC" -eq 0 ] && [ "$(jq_out o.reason)" = "no-pane-id" ] && [ "$(jq_out o.env_team_invalid.kind)" = "malformed" ] && [ "$(jq_out o.env_team_invalid.value)" = "$bad" ]'
done
OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" AH_TEAM_FILE="$OTHER_TEAMS/ct.json" node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1); RC=$?
check "P3a: another repo's well-formed team file is reported as other-repo, not malformed" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.reason)" = "no-pane-id" ] && [ "$(jq_out o.env_team_invalid.kind)" = "other-repo" ]'
OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" AH_TEAM_FILE="$TEAMS/ct.json" node "$H/roster.mjs" whoami --cwd "$PROJ" 2>&1); RC=$?
check "P3c: a valid AH_TEAM_FILE is what whoami answers with (answered_by env)" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.team+\"/\"+o.answered_by+\"/\"+o.reason")" = "ct/env/null" ] && [ "$(jq_out "String(\"env_team_invalid\" in o)")" = "false" ]'

new_repo proj-p4; setup_roster architect
printf '{"session_id":"sess-p4","cwd":"%s","agent_type":"ah:architect","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" \
  | env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" AH_TEAM_FILE="$TEAMS/ct.json" node "$H/sessionstart.mjs" > /dev/null 2>&1
OUT=$(tail -1 "$HD/peers.jsonl" 2>/dev/null)
check "P4: sessionstart with AH_TEAM_FILE set and no team file yet tags the up row with that team" \
  '[ ! -e "$TEAMS/ct.json" ] && [ "$(jq_out "o.status+\"/\"+o.team")" = "up/ct" ]'

# P5: every transport's launch carries the channel, through every quoting layer, for a path with a space.
mkdir -p "$SANDBOX/fakes"
cat > "$SANDBOX/fakes/claude" <<'EOF'
#!/bin/sh
i=0; for a in "$@"; do printf '%s\n' "$a" > "$ARGV_DIR/$i"; i=$((i+1)); done
EOF
cat > "$SANDBOX/fakes/tmux" <<'EOF'
#!/bin/sh
[ "$1" = "list-sessions" ] && exit 0
[ "$1" = "send-keys" ] && { /bin/sh -c "$4"; exit $?; }
exit 1
EOF
cat > "$SANDBOX/fakes/herdr" <<'EOF'
#!/bin/sh
while [ "$1" != "--" ]; do shift; done; shift
exec claude "$@"
EOF
chmod +x "$SANDBOX/fakes/claude" "$SANDBOX/fakes/tmux" "$SANDBOX/fakes/herdr"
settings_value() { # the AH_TEAM_FILE the fake claude received via --settings
  node -e 'const fs=require("fs"),d=process.argv[1];const a=fs.readdirSync(d).sort((x,y)=>x-y).map(f=>fs.readFileSync(d+"/"+f,"utf8").replace(/\n$/,""));const i=a.indexOf("--settings");process.stdout.write(i<0?"<none>":JSON.parse(a[i+1]).env.AH_TEAM_FILE)' "$ARGV_DIR" 2>/dev/null
}
new_repo "with space/proj-p5"; setup_roster architect
BASEP5="$(basename "$PROJ")"
EXPECT_P5="$PROJ/.claude/hierarchy/teams/$BASEP5.json"
for transport in terminal tmux herdr; do
  case $transport in
    terminal) tenv="env -u HERDR_ENV PATH=$SANDBOX/nolaunch:$NODE_DIR" ;;
    tmux) tenv="env -u HERDR_ENV PATH=$SANDBOX/fakes:$NODE_DIR" ;;
    herdr) tenv="env HERDR_ENV=1 PATH=$SANDBOX/fakes:$NODE_DIR" ;;
  esac
  PLAN=$($tenv HOME="$FAKEHOME" CLAUDE_PID=$$ AH_TEAM_FILE=/elsewhere/.claude/hierarchy/teams/zz.json node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1)
  LAUNCH=$(printf '%s' "$PLAN" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).members[0].spawn.launch[0]))' 2>/dev/null)
  export ARGV_DIR="$SANDBOX/argv-$transport"; rm -rf "$ARGV_DIR"; mkdir -p "$ARGV_DIR"
  (cd "$PROJ" && env PATH="$SANDBOX/fakes:$NODE_DIR" /bin/sh -c "${LAUNCH//<TARGET>/p1}")
  OUT="$LAUNCH"
  check "P5 ($transport): the launch hands the member its target team file through every quoting layer, not the inherited AH_TEAM_FILE" \
    '[ "$(settings_value)" = "$EXPECT_P5" ]'
done
unset ARGV_DIR

new_repo proj-p6; setup_roster architect
write_team ct "$OWNER_PID" '[{"role":"architect","name":"ct-architect","route":"peer","transport_id":"pLive"}]'
write_team old "$DEAD_PID" '[{"role":"architect","name":"old-architect","route":"peer","transport_id":"pDead"}]'
resolve_team HERDR_PANE_ID=pLive
check "P6: no env, a pane matching a live team's member row resolves that team" '[ "$(jq_out o.team)" = "ct" ]'
resolve_team HERDR_PANE_ID=pDead
check "P6b: a pane matching only a dead team resolves nothing" '[ "$(jq_out o.team)" = "null" ]'

# A worktree peer's team lives in the main checkout's hierarchy dir; its recorded block must be read
# from that team file, not from the worktree's own (empty) hierarchy dir.
new_repo proj-p6c; setup_roster architect
run_roster init --level repo --route peer --roster hotfix
run_roster add --level repo --role implementor --model opus --roster hotfix
(cd "$PROJ" && git add -A >/dev/null && git -c user.email=t@t -c user.name=t commit -qm init && git worktree add -q "$SANDBOX/proj-p6c-wt" >/dev/null 2>&1)
write_team rel "$OWNER_PID" '[]' '"roster":"hotfix"'
OUT=$(env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" AH_TEAM_FILE="$TEAMS/rel.json" node --input-type=module -e "
  const C = await import('$H/lib-config.mjs');
  const r = C.resolveConfig('$SANDBOX/proj-p6c-wt', { sessionId: 'sess-wt' });
  process.stdout.write(r.team + '/' + (r.roster ? r.roster.members.map((m) => m.name).join(',') : 'none'));
" 2>&1)
check "P6c: a worktree peer launched into the main checkout's team reads that team's recorded block" '[ "$OUT" = "rel/rel-implementor" ]'

# B8–B10: SessionStart's stale-team sweep acts only on a team the session owns, or — when nothing
# answered — the legacy team.json. A team it was only attributed to (env or pane) is never cleared.
new_repo proj-b8; setup_roster architect
OLD25=$(node -e 'console.log(new Date(Date.now() - 25 * 3600 * 1000).toISOString())')
write_team tt "$OWNER_PID" '[{"role":"architect","name":"tt-architect","route":"peer","transport_id":"%77"}]' "\"created\":\"$OLD25\""
TT_BEFORE=$(cat "$TEAMS/tt.json")
plain_session_start() { # <env assignments...> — a plain (non-role) SessionStart under the fake HOME
  printf '{"session_id":"sess-sweep","cwd":"%s","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" \
    | env -u HERDR_PANE_ID -u TMUX_PANE -u AH_TEAM_FILE HOME="$FAKEHOME" "$@" node "$H/sessionstart.mjs" > /dev/null 2>&1
}
plain_session_start TMUX_PANE=%77
check "B8: a pane matching a 25h-old team the session does not own leaves that team byte-identical" '[ "$(cat "$TEAMS/tt.json" 2>/dev/null)" = "$TT_BEFORE" ]'
plain_session_start AH_TEAM_FILE="$TEAMS/tt.json"
check "B9: a session launched into that team leaves it byte-identical too" '[ "$(cat "$TEAMS/tt.json" 2>/dev/null)" = "$TT_BEFORE" ]'
write_team "" "$DEAD_PID" '[]'
LEGACY_BEFORE=$(cat "$HD/team.json")
plain_session_start AH_TEAM_FILE="$HD/team.json"
check "B10: a dead-owner legacy team.json is left alone when the session was launched into it" '[ "$(cat "$HD/team.json" 2>/dev/null)" = "$LEGACY_BEFORE" ]'
plain_session_start TMUX_PANE=%77
check "B10b: ...and when the session's pane matched another team" '[ "$(cat "$HD/team.json" 2>/dev/null)" = "$LEGACY_BEFORE" ]'
plain_session_start
check "B10c: with no env and no pane it is still cleared, as before, and the attributed team is untouched" \
  '[ ! -e "$HD/team.json" ] && [ "$(cat "$TEAMS/tt.json")" = "$TT_BEFORE" ]'

new_repo proj-p7; setup_roster architect
BEFORE_P7=$(listing)
commit_team b '[{"name":"b-architect","role":"architect","route":"peer","team":"a"}]'
check "P7: create --commit --team b with a verified member checked in to team a is refused, nothing written" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "checked in to team \"a\"" && [ "$(listing)" = "$BEFORE_P7" ]'
commit_team b '[{"name":"b-architect","role":"architect","route":"peer","team":"b"}]'
check "P7b: a member checked in to the team being committed is accepted" '[ "$RC" -eq 0 ] && [ -e "$TEAMS/b.json" ]'
check "P7c: and its row is written without the check-in's team field" '[ "$(jq_file "$TEAMS/b.json" "JSON.stringify(Object.keys(t.members[0]).includes(\"team\"))")" = "false" ]'

# ==================================================================== step 4 — --roster selects a template
setup_named() { # default roster: architect; rosters.hotfix: implementor
  setup_roster architect
  run_roster init --level repo --route peer --roster hotfix
  run_roster add --level repo --role implementor --model opus --roster hotfix
}
fresh_home; new_repo proj-c; setup_named
run_roster create --plan --team hotfix --roster hotfix
check "C1: create --team hotfix --roster hotfix plans from rosters.hotfix" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join(\",\")")" = "hotfix-implementor" ]'
run_roster create --commit --team hotfix --roster hotfix --verified '["hotfix-implementor"]' --transport terminal --roster-level repo
check "C1b: and the committed team records roster \"hotfix\"" '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/hotfix.json" t.roster)" = "hotfix" ]'
rm -rf "$HD"

run_roster_split create --plan --team hotfix
OUT="$STDOUT"
check "C2: create --team hotfix without --roster builds from the default block" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join(\",\")")" = "hotfix-architect" ]'
check "C2b: and warns, in its output and on stderr, naming --roster hotfix" \
  'jq_out "o.warnings.join(\" \")" | grep -q -- "--roster hotfix" && echo "$STDERR" | grep -q -- "--roster hotfix"'

BEFORE_C3=$(listing; cat "$PROJ/.claude/agent-hierarchy.json")
for phase in --plan --commit; do
  run_roster create $phase --roster nope --verified '["x"]' --transport terminal --roster-level repo
  check "C3 ($phase): create --roster nope → error, nothing written" \
    '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "no rosters.nope block" && [ "$(listing; cat "$PROJ/.claude/agent-hierarchy.json")" = "$BEFORE_C3" ]'
done

LEVELS_BEFORE=$(cat "$PROJ/.claude/agent-hierarchy.json" "$GLOBAL" 2>/dev/null)
for verb in "init --level repo --route peer" "add --level repo --role reviewer" "edit --member x-architect --model sonnet" "remove --member x-architect" "show"; do
  run_roster $verb --team X
  check "C4: $verb --team X → error naming --roster" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "--roster <r>"'
done
check "C4b: every level file is byte-identical" '[ "$(cat "$PROJ/.claude/agent-hierarchy.json" "$GLOBAL" 2>/dev/null)" = "$LEVELS_BEFORE" ]'

write_team hotfix "$OWNER_PID" '[]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); const r = C.resolveConfig('$PROJ', { team: 'hotfix' }); process.stdout.write(r.roster.members.map((m) => m.name).join(','));" 2>&1)
check "C5: a team file named hotfix lacking \`roster\` resolves rosters.hotfix (the pre-0057 rule)" '[ "$OUT" = "hotfix-implementor" ]'

write_team hotfix "$OWNER_PID" '[]' '"roster":"hotfix"'
run_herdr spawn-one implementor --team hotfix
check "C6: spawn-one into a team recording roster \"hotfix\" uses that block without --roster" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/hotfix.json" "t.members.map(m=>m.name).join(\",\")")" = "hotfix-implementor" ]'

# msg roster resolves its team through resolveConfig(cwd, {team, pid}) (msg.mjs's roster verb); a team
# whose name differs from its recorded block shows the block comes from the record, not the name.
write_team rel "$OWNER_PID" '[]' '"roster":"hotfix"'
OUT=$(HOME="$FAKEHOME" node "$H/msg.mjs" roster --team rel --cwd "$PROJ" 2>&1); RC=$?
check "C7: msg roster --team rel runs" '[ "$RC" -eq 0 ]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); const r = C.resolveConfig('$PROJ', { team: 'rel', pid: $$ }); process.stdout.write(r.roster.members.map((m) => m.name).join(','));" 2>&1)
check "C7b: the roster msg roster --team rel resolves is the team's recorded block, named under the team" '[ "$OUT" = "rel-implementor" ]'
rm -f "$TEAMS/rel.json"

mkdir -p "$SANDBOX/closebin"; printf '#!/bin/sh\n[ "$1" = "kill-pane" ] && exit 0\nexit 1\n' > "$SANDBOX/closebin/tmux"; chmod +x "$SANDBOX/closebin/tmux"
write_team hotfix $$ '[{"role":"implementor","name":"hotfix-implementor","route":"peer","transport_id":"%9"},{"role":"reviewer","name":"hotfix-reviewer","route":"peer","transport_id":"%8"}]' '"roster":"hotfix"'
node -e 'const f=process.argv[1],fs=require("fs");const t=JSON.parse(fs.readFileSync(f,"utf8"));t.transport="tmux";fs.writeFileSync(f,JSON.stringify(t))' "$TEAMS/hotfix.json"
dismiss_close() { # <member>
  local tok
  tok=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss "$1" --team hotfix --cwd "$PROJ" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).close_token))')
  OUT=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss "$1" --close --confirm --plan-token "$tok" --also-config --team hotfix --cwd "$PROJ" 2>&1); RC=$?
}
DEFAULT_BEFORE=$(jq_file "$PROJ/.claude/agent-hierarchy.json" "JSON.stringify(t.roster)")
dismiss_close hotfix-implementor
check "C8: dismiss --also-config on hotfix-implementor removes it from rosters.hotfix" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$PROJ/.claude/agent-hierarchy.json" "t.rosters.hotfix.members.length")" = "0" ] && [ "$(jq_file "$PROJ/.claude/agent-hierarchy.json" "JSON.stringify(t.roster)")" = "$DEFAULT_BEFORE" ]'
CONFIG_BEFORE=$(cat "$PROJ/.claude/agent-hierarchy.json")
dismiss_close hotfix-reviewer
check "C8b: on an ad hoc member it edits nothing and says so" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.config.removed)" = "false" ] && [ "$(cat "$PROJ/.claude/agent-hierarchy.json")" = "$CONFIG_BEFORE" ]'
# A team file from before teams recorded their block reads the default block (no rosters.<its name>),
# so --also-config edits the default block too.
fresh_home; new_repo proj-c8c; setup_roster architect implementor
BASEC8="$(basename "$PROJ")"
write_team "$BASEC8" $$ "[{\"role\":\"implementor\",\"name\":\"$BASEC8-implementor\",\"route\":\"peer\",\"transport_id\":\"%7\"}]"
node -e 'const f=process.argv[1],fs=require("fs");const t=JSON.parse(fs.readFileSync(f,"utf8"));t.transport="tmux";fs.writeFileSync(f,JSON.stringify(t))' "$TEAMS/$BASEC8.json"
tok=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss "$BASEC8-implementor" --cwd "$PROJ" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).close_token))')
OUT=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss "$BASEC8-implementor" --close --confirm --plan-token "$tok" --also-config --cwd "$PROJ" 2>&1); RC=$?
check "C8c: dismiss --also-config on a pre-0057 default team removes the row from the default roster block" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$PROJ/.claude/agent-hierarchy.json" "t.roster.members.map(m=>m.role).join(\",\")")" = "architect" ]'

# C9: 0032's level precedence holds for an explicit --roster — a per-key block at any level beats the
# default block at a higher level (T5); within the per-key kind, level precedence decides (T6).
fresh_home; new_repo proj-c9; setup_roster architect
run_roster init --level global --route peer --roster hotfix
run_roster add --level global --role implementor --model opus --roster hotfix
run_roster create --plan --roster hotfix
check "C9 (T5): rosters.hotfix only at global beats the repo default block" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.level+\"/\"+o.members.map(m=>m.role).join(\",\")")" = "global/implementor" ]'
run_roster init --level repo --route peer --roster hotfix
run_roster add --level repo --role reviewer --model opus --roster hotfix
run_roster create --plan --roster hotfix
check "C9b (T6): rosters.hotfix at repo and global → repo wins" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.level+\"/\"+o.members.map(m=>m.role).join(\",\")")" = "repo/reviewer" ]'

# C10: a bare plan lists the rosters a create could be pointed at, and says nothing when there are none.
fresh_home; new_repo proj-c10; setup_roster architect
run_roster create --plan
check "C10b: with no rosters.* anywhere the plan carries no named_rosters key" '[ "$RC" -eq 0 ] && [ "$(jq_out "String(\"named_rosters\" in o)")" = "false" ]'
run_roster init --level repo --route peer --roster hotfix
run_roster add --level repo --role implementor --roster hotfix
run_roster init --level global --route peer --roster alt
run_roster create --plan
check "C10: rosters.hotfix at repo and rosters.alt at global → named_rosters [alt, hotfix]" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "JSON.stringify(o.named_rosters)")" = "[\"alt\",\"hotfix\"]" ]'

# ==================================================================== step 5 — teamAlias and roster layout leave
set_repo_key() { # <js assignment over d> — edit the repo-level config in place
  node -e 'const f=process.argv[1],fs=require("fs");const d=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("d",process.argv[2]))(d);fs.writeFileSync(f,JSON.stringify(d))' "$PROJ/.claude/agent-hierarchy.json" "$1"
}
resolve_warnings() { HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(C.resolveConfig('$PROJ').warnings.join('\n'));" 2>&1; }
fake_calls() { ls "$FAKE_STATE_DIR/calls" 2>/dev/null | wc -l | tr -d ' '; }

fresh_home; new_repo proj-d1; setup_roster architect
set_repo_key 'd.teamAlias="ct"'
run_roster create --plan
check "D1: with teamAlias \"ct\" configured and no team, bare create --plan names members under the basename" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out "o.members.map(m=>m.name).join(\",\")")" = "proj-d1-architect" ]'
check "D1b: and warns, naming --team ct as the way to keep the old names" 'jq_out "o.warnings.join(\" \")" | grep -q -- "--team ct"'
status_text() { HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(C.statusReport('$PROJ'));" 2>&1; }
check "D1c: status reports the stale key as ignored; resolveConfig, which feeds hook context, does not carry it" \
  'status_text | grep -q "teamAlias in .* is ignored" && ! resolve_warnings | grep -q "teamAlias in"'
write_team ownd $$ '[]'
commit_team "" '[{"name":"ownd-architect","role":"architect","route":"peer"}]'
check "D1d: a bare create that resolves to the session's own team names that team in the warning" \
  '[ "$RC" -eq 0 ] && jq_out "o.warnings.join(\" \")" | grep -q "this team is named \"ownd\""'
rm -rf "$HD"

run_roster alias --set x
check "D2: the alias verb exits non-zero naming create --team" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "create --team"'
run_roster alias
check "D2b: bare alias too" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "create --team"'
run_roster layout --layout grid
check "D2c: the layout verb exits non-zero naming create --mode" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "create --mode"'
run_roster init --level repo --route peer --layout grid
check "D3: init --layout grid errors, naming create --mode" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "create --mode"'

fresh_home; new_repo proj-d4; setup_roster architect reviewer
set_repo_key 'd.roster.layout="grid"'
run_herdr create --plan
check "D4: a roster layout of grid no longer affects the plan" '[ "$RC" -eq 0 ] && [ "$(jq_out "o.layout.mode+\"/\"+o.layout_plan.mode")" = "auto/auto" ]'
check "D4b: the plan warns that roster.layout is ignored; resolveConfig does not carry it" \
  'jq_out "o.warnings.join(\" \")" | grep -q "roster.layout in .* is ignored" && ! resolve_warnings | grep -q "roster.layout in"'

# D13: a stale key is reported where a person reads CLI output, never in hook-injected context.
fresh_home; new_repo proj-d13; setup_roster architect
set_repo_key 'd.teamAlias="old"; d.roster.layout="grid"'
has_both() { echo "$1" | grep -q "teamAlias in .* is ignored.*delete it from .* to drop this warning" && echo "$1" | grep -q "roster.layout in .* is ignored.*delete it from .* to drop this warning"; }
SS=$(printf '{"session_id":"sess-d13","cwd":"%s","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" | env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>&1)
SSR=$(printf '{"session_id":"sess-d13r","cwd":"%s","agent_type":"ah:architect","source":"startup","hook_event_name":"SessionStart"}' "$PROJ" | env -u HERDR_PANE_ID -u TMUX_PANE HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>&1)
check "D13: SessionStart context, for a plain and a role session, carries neither stale-key warning" '[ -n "$SS" ] && [ -n "$SSR" ] && ! echo "$SS$SSR" | grep -qE "teamAlias in|roster.layout in"'
check "D13b: status carries both, each saying deleting the key drops it" 'has_both "$(status_text)"'
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" node "$H/roster.mjs" doctor --cwd "$PROJ" 2>&1)
check "D13c: doctor carries both" 'has_both "$OUT"'
run_roster create --plan
check "D13d: a bare create --plan carries both" '[ "$RC" -eq 0 ] && has_both "$OUT"'

FN_START=$(grep -n '^export function staleTeamKeys' "$H/lib-config.mjs" | cut -d: -f1)
FN_END=$(awk -v s="$FN_START" 'NR > s && /^}/ { print NR; exit }' "$H/lib-config.mjs")
DOC_START=$(awk -v s="$FN_START" 'NR < s && /^\/\*\*/ { d = NR } END { print d }' "$H/lib-config.mjs")
OUT=$(grep -n 'teamAlias' "$H"/*.mjs)
check "D5: teamAlias appears in hooks/ only in lib-config's stale-key reporter" \
  '[ -n "$OUT" ] && ! echo "$OUT" | grep -qv "/lib-config.mjs:" && echo "$OUT" | awk -F: -v a="$DOC_START" -v b="$FN_END" "{ if (\$2 < a || \$2 > b) bad = 1 } END { exit bad }"'
OUT=$(grep -nE '\b(r|roster|container|resolved|rosterBlock|layoutSource|found|block|data\.roster)\.layout\b' "$H"/*.mjs | grep -v 'block\.layout !== undefined')
check "D5b: no hooks/ file reads a roster block's layout (the stale-key report aside)" '[ -z "$OUT" ]'

# D6: an unusable basename on tmux refuses with the structured refusal and writes nothing.
fresh_home; new_repo my_repo; setup_roster architect
env -u HERDR_ENV PATH="$SANDBOX/fakes:$NODE_DIR" HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr"; RC=$?
OUT=$(cat "$SANDBOX/stdout"); STDERR=$(cat "$SANDBOX/stderr")
check "D6: basename my_repo on tmux → exit 2 with refused team-name-unusable, needs_user_choice, name, source, suggestion" \
  '[ "$RC" -eq 2 ] && [ "$(jq_out "[o.ok,o.refused,o.needs_user_choice,o.verb,o.name,o.name_source,o.transport,o.suggestion].join(\"|\")")" = "false|team-name-unusable|true|create|my_repo|basename|tmux|my-repo" ]'
check "D6b: rerun carries --team <TEAM> literally" 'jq_out o.rerun | grep -q -- "--team <TEAM>$"'
check "D6c: stderr carries the message" 'echo "$STDERR" | grep -q "^roster.mjs: Team name \"my_repo\" (basename) can.t be used"'
check "D6d: no team file, history row, or global file written" '[ ! -e "$HD/teams" ] && [ ! -e "$HD/team.json" ] && [ ! -e "$HD/team-history.json" ] && [ ! -e "$GLOBAL" ]'
D6_MSG=$(jq_out o.message)

# D7: herdr, a basename whose member names break Herdr's rule (uppercase and length).
fresh_home; new_repo Claude-TUI-Line-Experimental; setup_roster ultra-advisor architect
for verb in "create --plan" "spawn-one ultra-advisor" "spawn-ad-hoc architect"; do
  run_herdr_split $verb
  check "D7 ($verb): refuses with the herdr-mode suggestion and the longest failing member" \
    '[ "$RC" -eq 2 ] && [ "$(jq_out "[o.refused,o.verb,o.name_source,o.suggestion,o.failing_member.name,o.failing_member.length].join(\"|\")")" = "team-name-unusable|${verb%% *}|basename|claude-tui-line-ex|Claude-TUI-Line-Experimental-ultra-advisor|42" ]'
done
check "D7b: nothing was launched and no team file written" '[ "$(fake_calls)" = "0" ] && [ ! -e "$TEAMS" ]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(String(['-ultra-advisor','-architect'].every((s) => C.validateHerdrName('claude-tui-line-ex' + s).ok)));")
check "D7c: every member name derived from the suggestion passes Herdr's rule" '[ "$OUT" = "true" ]'
run_herdr spawn-one ultra-advisor --team claude-tui-line-ex
check "D7d: re-running with --team <suggestion> succeeds" '[ "$RC" -eq 0 ] && [ -e "$TEAMS/claude-tui-line-ex.json" ]'
run_herdr spawn-one architect
check "D7e: and a following bare spawn-one joins that team" \
  '[ "$RC" -eq 0 ] && [ "$(jq_file "$TEAMS/claude-tui-line-ex.json" "t.members.map(m=>m.name).join(\",\")")" = "claude-tui-line-ex-ultra-advisor,claude-tui-line-ex-architect" ]'

# D8: an explicit --team too long for Herdr's member names refuses on herdr, proceeds on tmux.
fresh_home; new_repo proj-d8; setup_roster ultra-advisor architect
run_herdr_split create --plan --team averyveryverylongteamname-xy
check "D8: herdr, explicit --team whose longest member name exceeds 32 → the same refusal, name_source explicit" \
  '[ "$RC" -eq 2 ] && [ "$(jq_out "[o.refused,o.name_source,o.failing_member.length].join(\"|\")")" = "team-name-unusable|explicit|42" ] && [ "$(fake_calls)" = "0" ]'
D8_MSG=$(jq_out o.message)
OUT=$(env -u HERDR_ENV PATH="$SANDBOX/fakes:$NODE_DIR" HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --plan --team averyveryverylongteamname-xy --cwd "$PROJ" 2>&1); RC=$?
check "D8b: the same --team on tmux proceeds" '[ "$RC" -eq 0 ] && [ "$(jq_out o.transport)" = "tmux" ]'

# An ad hoc spawn reads no global-level roster, so that roster's members do not count against the
# Herdr name budget either: "-ultra-advisor" would not fit this basename, "-architect" does.
fresh_home; new_repo proj-d8-abcdefghijk
run_roster init --level global --route peer
run_roster add --level global --role ultra-advisor --model opus
run_herdr_split spawn-ad-hoc architect
check "D8c: spawn-ad-hoc under herdr ignores a global roster's members in the name check" \
  '[ "$RC" -eq 0 ] && [ "$(jq_out o.member.name)" = "proj-d8-abcdefghijk-architect" ]'

# D9: a role whose own suffix leaves no room for any team name → no suggestion, nothing to ask.
fresh_home; new_repo proj-d9; setup_roster architect
LONGROLE=reviewer-with-a-very-long-name1
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" node "$H/roster.mjs" role set "$LONGROLE" --class review --description "D9." --level repo --scaffold repo --cwd "$PROJ" 2>&1); RC=$?
check "D11: role set warns under the assumed prefix, naming --team, not alias --set" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "under the team prefix \"proj-d9\"" && echo "$OUT" | grep -q -- "--team" && ! echo "$OUT" | grep -q "alias --set"'
run_roster add --level repo --role "$LONGROLE"
run_herdr_split create --plan
check "D9: a Herdr-impossible role suffix → needs_user_choice false, no suggestion or rerun, suggestion_why names the role" \
  '[ "$RC" -eq 2 ] && [ "$(jq_out "[o.needs_user_choice,o.suggestion,o.rerun].join(\"|\")")" = "false||" ] && jq_out o.suggestion_why | grep -q "$LONGROLE"'
check "D9c: and its message tells the user rather than asking for a name" 'jq_out o.message | grep -q "Do not retry with a name of your own"'

for msg in "$D6_MSG" "$D8_MSG"; do
  OUT="$msg"
  check "D9a: the refusal message carries the whole procedure and no subagent opt-in" \
    'echo "$OUT" | grep -q AskUserQuestion && echo "$OUT" | grep -q "(Recommended)" && echo "$OUT" | grep -q "Do not pick a name yourself" && echo "$OUT" | grep -q -- "--team <TEAM>" && ! echo "$OUT" | grep -q "route subagents"'
done
OUT="$D6_MSG"; check "D9a (D6): names the suggestion" 'echo "$OUT" | grep -q "Use my-repo (Recommended)"'
UNUSABLE_LINE=$(grep -n 'team-name-unusable' "$H/pretooluse-route-gate.mjs" | head -1 | cut -d: -f1)
FAILS_LINE=$(grep -n 'If the command fails' "$H/pretooluse-route-gate.mjs" | head -1 | cut -d: -f1)
check "D9b: spawnReason names team-name-unusable ahead of its launch-failure line" '[ -n "$UNUSABLE_LINE" ] && [ -n "$FAILS_LINE" ] && [ "$UNUSABLE_LINE" -lt "$FAILS_LINE" ]'

OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const C = await import('$H/lib-config.mjs');
  const inputs = ['My_Repo', '.hidden', 'a'.repeat(40), 'my_repo', 'architect', '2024-Experiments', 'My_Repo.Tools', '---', '', 'ui', 'claude-tui-line-experimental-branch'];
  process.stdout.write(JSON.stringify(inputs.map((i) => [C.suggestTeamAlias(i), C.suggestTeamAlias(i, { transport: 'tmux', suffixes: ['-ultra-advisor'] })])));
" 2>&1)
check "D10: suggestTeamAlias without context, or for tmux, returns the pre-0057 outputs" \
  '[ "$OUT" = "[[\"My-Repo\",\"My-Repo\"],[\"hidden\",\"hidden\"],[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"],[\"my-repo\",\"my-repo\"],[\"team\",\"team\"],[\"2024-Experiments\",\"2024-Experiments\"],[\"My-Repo-Tools\",\"My-Repo-Tools\"],[\"team\",\"team\"],[\"team\",\"team\"],[\"ui\",\"ui\"],[\"claude-tui-line-experimental-bra\",\"claude-tui-line-experimental-bra\"]]" ]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const C = await import('$H/lib-config.mjs');
  const h = (raw) => C.suggestTeamAlias(raw, { transport: 'herdr', suffixes: ['-ultra-advisor', '-architect'] });
  process.stdout.write(JSON.stringify(['My_Repo.Tools', '2024-Experiments', 'claude-tui-line-experimental-branch'].map(h)));
" 2>&1)
check "D10b: the herdr mode gives the spec's illustrative names" '[ "$OUT" = "[\"my-repo-tools\",\"experiments\",\"claude-tui-line-ex\"]" ]'

# ==================================================================== step 6 — the surface says the same
SKILLS="$PLUGIN/skills"
OUT=$(grep -niE 'alias|layout|--team' "$SKILLS/agent-roster/SKILL.md")
check "E1: the agent-roster skill names no alias, teamAlias, layout, --layout or --team" '[ -z "$OUT" ]'
TEAM_SKILL="$SKILLS/agent-team/SKILL.md"
check "E2: the agent-team create phase runs a bare create --plan and asks the team name once, suggestion first" \
  'grep -q "Run a bare \`roster.mjs create --plan\`" "$TEAM_SKILL" && grep -q "Team name — one question, every create" "$TEAM_SKILL" && grep -q "Use \`<suggestion>\`" "$TEAM_SKILL" && grep -q "roster.mjs history" "$TEAM_SKILL"'
check "E2b: it re-runs with --team on a non-default choice, stops on needs_user_choice false, asks the roster only when named rosters exist" \
  'grep -q "re-run the plan with" "$TEAM_SKILL" && grep -q "needs_user_choice: false" "$TEAM_SKILL" && grep -q "Roster — only when the plan lists \`named_rosters\`" "$TEAM_SKILL" && grep -q "same\*\* AskUserQuestion call as the team name" "$TEAM_SKILL"'
check "E2c: no layout question unless the user asks, and no alias --set anywhere" \
  'grep -q "Layout — ask nothing by default" "$TEAM_SKILL" && ! grep -q "alias --set" "$TEAM_SKILL"'
DOC="$PLUGIN/docs/cli-tools.md"
check "E3: cli-tools.md has no alias/layout verb row and documents --roster, teamLayout and team-name-unusable" \
  '! grep -qE "roster\.mjs (alias|layout) " "$DOC" && grep -q -- "--roster <r>" "$DOC" && grep -q "teamLayout" "$DOC" && grep -q "team-name-unusable" "$DOC"'
V_PLUGIN=$(node -e 'console.log(require(process.argv[1]).version)' "$PLUGIN/.claude-plugin/plugin.json")
V_MARKET=$(node -e 'console.log(require(process.argv[1]).plugins.find((p) => p.source === "./agent-hierarchy").version)' "$PLUGIN/../.claude-plugin/marketplace.json")
check "E4: plugin.json and the root marketplace.json carry the same version" '[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ]'
OUT=$(grep -n 'Superseded' "$PLUGIN/docs/specs/0044-roster-team-scope-split.md")
check "E5: 0044 carries exactly the §1.1-constraint-4 and §8.1 notes, and none on §9.1's refuse-never-auto-sanitize" \
  '[ "$(echo "$OUT" | grep -c .)" -eq 2 ] && ! echo "$OUT" | grep -qiE "9\.1|sanitiz"'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
