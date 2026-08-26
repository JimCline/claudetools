#!/bin/bash
# agent-hierarchy — roster.mjs `spawn-one` (spec 0009 §6): the one operation
# `create` cannot reach — a live Team with one role dead or never launched.
# Reuses test-roster-create-spawn.sh's PER-INVOCATION-APPEND fake herdr/tmux
# stub verbatim (spec 0005 §11.1's technique) since `spawn-one` shares
# `layoutAndLaunch` with `create --spawn` (extracted, not forked — spec 0009 §6.3).
# Usage: bash tests/test-roster-spawn-one.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-spawn-one-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
PEERS_FILE="$PROJ/.claude/hierarchy/peers.jsonl"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr/tmux: identical to test-roster-create-spawn.sh's per-invocation-append stub.
cat > "$SANDBOX/bin/herdr" <<EOF
#!$(command -v node)
$(cat <<'FAKEEOF'
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const dir = process.env.FAKE_STATE_DIR;
const callsDir = path.join(dir, "calls");
fs.mkdirSync(callsDir, { recursive: true });
const startMs = Date.now();
function finish(exitCode) {
  const file = path.join(callsDir, `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify({ argv: args, start_ms: startMs, end_ms: Date.now(), exit: exitCode, pid: process.pid, bin: "herdr" }));
  process.exit(exitCode);
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
  const direction = args[args.indexOf("--direction") + 1];
  const rect = s.panes[target];
  const newId = `p${s.nextId++}`;
  if (direction === "right") {
    const w1 = Math.floor(rect.width / 2), w2 = rect.width - w1;
    s.panes[target] = { ...rect, width: w1 };
    s.panes[newId] = { ...rect, width: w2, x: rect.x + w1 };
  } else {
    const h1 = Math.floor(rect.height / 2), h2 = rect.height - h1;
    s.panes[target] = { ...rect, height: h1 };
    s.panes[newId] = { ...rect, height: h2, y: rect.y + h1 };
  }
  fs.writeFileSync(geomFile, JSON.stringify(s));
  console.log(JSON.stringify({ result: { pane: { pane_id: newId } } }));
  finish(0);
}

if (args[0] === "agent" && args[1] === "start") {
  const name = args[2];
  const failAlways = process.env.FAKE_HERDR_FAIL_ALWAYS_NAME;
  if (failAlways && name === failAlways) {
    process.stderr.write("fake herdr: agent start failed (always)\n");
    finish(1);
  }
  console.log(JSON.stringify({ result: { pane: { pane_id: "target" }, agent: { name, ready: true } } }));
  finish(0);
}

process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

FAKE_STATE_DIR="$SANDBOX/state"
reset_state() { rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"; }
init_geometry() {
  local width=$1 height=$2
  cat > "$FAKE_STATE_DIR/geometry.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":$width,"height":$height,"x":0,"y":0},"panes":{"p0":{"width":$width,"height":$height,"x":0,"y":0}}}
EOF
}
clear_hierarchy() { rm -rf "$PROJ/.claude/hierarchy"; }

# Roster setup: N peer members via real roster.mjs calls, add-order is plan order.
ROLES4=(ultra-advisor architect reviewer implementor)
setup_roster() { # <n> [level]
  local n=$1 level=${2:-repo}
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level "$level" --route peer --cwd "$PROJ" >/dev/null
  for ((i = 0; i < n; i++)); do
    HOME="$FAKEHOME" node "$H/roster.mjs" add --level "$level" --role "${ROLES4[$i]}" --model opus --cwd "$PROJ" >/dev/null
  done
}

call_files_matching() {
  node -e '
    const fs = require("fs");
    const dir = process.argv[1];
    const pred = process.argv[2];
    let files = [];
    try { files = fs.readdirSync(dir); } catch { files = []; }
    const rows = files.map((f) => JSON.parse(fs.readFileSync(dir + "/" + f, "utf8")));
    const fn = new Function("c", "return " + pred + ";");
    console.log(JSON.stringify(rows.filter(fn)));
  ' "$FAKE_STATE_DIR/calls" "$1"
}
call_count() { call_files_matching "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))'; }

run_one() { # <extra_env> <args...>
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" CLAUDE_PID=$$ $extra_env node \"$H/roster.mjs\" spawn-one $* --cwd \"$PROJ\" 2>&1"); RC=$?
}
run_spawn() { # <extra_env> <args...> -- create --spawn, for the §9-parity global-roster check
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" create --spawn $* --cwd \"$PROJ\" 2>&1"); RC=$?
}
write_team() { # <json>
  mkdir -p "$(dirname "$TEAM_FILE")"
  printf '%s' "$1" > "$TEAM_FILE"
}
seed_peer() { # <name> <role> <status> <pid>
  mkdir -p "$(dirname "$PEERS_FILE")"
  node -e 'const fs=require("fs");const[f,n,r,st,p]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4"
}

# ==== 1 — repo roster, no team -> launches once, team.json written with roster_level "repo" ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "HERDR_ENV=1" ultra-advisor
check "1: exit 0, spawned true, roster_level repo" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true" && echo "$OUT" | grep -q "\"roster_level\": \"repo\""'
check "1b: team.json written with roster_level repo, one member" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(t.roster_level===\"repo\"&&t.members.length===1&&t.members[0].role===\"ultra-advisor\"?0:1)" "$TEAM_FILE"'
check "1c: exactly one agent-start call" '[ "$(call_count "c.argv[0]===\"agent\" && c.argv[1]===\"start\"")" -eq 1 ]'

# ==== 2 — live Team, one dead member -> spawn-one for it succeeds, preserves team_id + the live member ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 2
write_team "$(node -e '
  console.log(JSON.stringify({
    version: 1, team_id: "T-fixture-1", created: new Date().toISOString(), roster_level: "repo",
    transport: "herdr", orchestrator: { session_id: null, pid: process.ppid },
    members: [
      { role: "ultra-advisor", name: "myrepo-ultra-advisor", route: "peer", model: "opus", effort: null, autoMode: null, transport_id: "p1" },
      { role: "architect", name: "myrepo-architect", route: "peer", model: "opus", effort: null, autoMode: null, transport_id: "p2" }
    ],
    partial: false,
  }))
')"
seed_peer "myrepo-ultra-advisor" "ultra-advisor" "up" "$$"
BEFORE_ULTRA=$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).members.find(m=>m.role==="ultra-advisor")))' "$TEAM_FILE")
run_one "HERDR_ENV=1" architect
check "2: spawn-one on the dead member of a live Team succeeds" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'
check "2b: team_id preserved (not a fresh Team)" 'echo "$OUT" | grep -q "\"team_id\": \"T-fixture-1\""'
check "2c: the live (untouched) member is unchanged in team.json" \
  '[ "$(node -e "console.log(JSON.stringify(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).members.find(m=>m.role===\"ultra-advisor\")))" "$TEAM_FILE")" = "$BEFORE_ULTRA" ]'
check "2d: architect member updated with a new transport_id, role/team_id count unchanged" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));const a=t.members.find(m=>m.role===\"architect\");process.exit(t.team_id===\"T-fixture-1\"&&t.members.length===2&&a&&a.transport_id&&a.transport_id!==\"p2\"?0:1)" "$TEAM_FILE"'

# ==== 3 — live member -> {spawned:false, reason:"already live"}, exit 0, team.json byte-identical ====
BEFORE_TEAM=$(cat "$TEAM_FILE")
run_one "HERDR_ENV=1" ultra-advisor
check "3: already-live member -> spawned false, reason already live, exit 0" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": false" && echo "$OUT" | grep -q "\"reason\": \"already live\""'
check "3b: team.json byte-identical (no write)" '[ "$(cat "$TEAM_FILE")" = "$BEFORE_TEAM" ]'
check "3c: no new agent-start call for the already-live member" '[ "$(call_count "c.argv[0]===\"agent\" && c.argv[1]===\"start\" && c.argv[2]===\"myrepo-ultra-advisor\"")" -eq 0 ]'

# ==== 4 — roster has no entry for the requested role -> non-zero, message lists defined roles ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "" architect
check "4: no roster entry for role -> non-zero, message lists what the roster defines" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "ultra-advisor"'

# ==== 5 — unknown role -> non-zero ====
run_one "" bogus-role
check "5: unknown role -> non-zero" '[ "$RC" -ne 0 ]'

# ==== 6 — launch fails -> non-zero, team.json unchanged (absent, here) ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "HERDR_ENV=1 FAKE_HERDR_FAIL_ALWAYS_NAME=myrepo-ultra-advisor" ultra-advisor
check "6: launch failure -> non-zero" '[ "$RC" -ne 0 ]'
check "6b: team.json never written" '[ ! -f "$TEAM_FILE" ]'

# ==== 7 — --dry-run: emits the plan, herdr stub never invoked, no write ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "HERDR_ENV=1" ultra-advisor --dry-run
check "7: --dry-run exit 0, emits the plan" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"dry_run\": true" && echo "$OUT" | grep -q "\"role\": \"ultra-advisor\""'
check "7b: --dry-run never invokes the herdr stub" '[ ! -d "$FAKE_STATE_DIR/calls" -o -z "$(ls -A "$FAKE_STATE_DIR/calls" 2>/dev/null)" ]'
check "7c: --dry-run never writes team.json" '[ ! -f "$TEAM_FILE" ]'

# ==== 8 — unknown flag -> non-zero ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "" ultra-advisor --bogus-flag
check "8: unknown flag -> non-zero" '[ "$RC" -ne 0 ]'

# ==== 9 — global-level roster needs --allow-global; create --spawn shares the same guard ====
# rm the repo-level roster left by earlier cases first -- resolveRoster prefers repo over global.
reset_state; clear_hierarchy; init_geometry 180 42; rm -f "$PROJ/.claude/agent-hierarchy.json"
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --level global --role ultra-advisor --model opus --cwd "$PROJ" >/dev/null
run_one "HERDR_ENV=1" ultra-advisor
check "9a: global roster, no --allow-global -> non-zero, names GLOBAL level, no 'declined'" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "GLOBAL level" && echo "$OUT" | grep -q -- "--allow-global" && ! echo "$OUT" | grep -qi "declined"'
check "9b: global roster refusal makes no launch attempt" '[ "$(call_count "c.argv[0]===\"agent\" && c.argv[1]===\"start\"")" -eq 0 ]'
run_one "HERDR_ENV=1" ultra-advisor --allow-global
check "9c: --allow-global proceeds against a global-level roster" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'

reset_state; clear_hierarchy; init_geometry 180 42; rm -f "$PROJ/.claude/agent-hierarchy.json"
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --level global --role ultra-advisor --model opus --cwd "$PROJ" >/dev/null
run_spawn "HERDR_ENV=1" --mode auto
check "9d: create --spawn against a global roster, no --allow-global -> non-zero, names GLOBAL level, no 'declined'" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "GLOBAL level" && echo "$OUT" | grep -q -- "--allow-global" && ! echo "$OUT" | grep -qi "declined"'
run_spawn "HERDR_ENV=1" --mode auto --allow-global
check "9e: create --spawn --allow-global proceeds against a global-level roster" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"partial\": false"'

# ==== 10 — regression: the two extraction-adjacent suites must pass UNMODIFIED ====
CS_OUT=$(bash "$PLUGIN/tests/test-roster-create-spawn.sh" 2>&1); CS_RC=$?
check "10a: test-roster-create-spawn.sh passes unmodified" '[ "$CS_RC" -eq 0 ]'
DB_OUT=$(bash "$PLUGIN/tests/test-roster-disband.sh" 2>&1); DB_RC=$?
check "10b: test-roster-disband.sh passes unmodified" '[ "$DB_RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
