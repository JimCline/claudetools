#!/bin/bash
# agent-hierarchy — spec 0039: `roster.mjs add <role>` that succeeds ends in a live peer when the
# member's route is peer — validate → write → spawn through the same extracted core `spawn-one`
# uses. Fake herdr stub copied verbatim from test-roster-spawn-one.sh (itself from
# test-roster-create-spawn.sh, spec 0005 §11.1) — the spawn path is shared, so is its fake.
# Usage: bash tests/test-roster-add-spawn.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-add-spawn-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
CFG="$PROJ/.claude/agent-hierarchy.json"
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
fresh() { # empty peer-route roster, no team, clean stub state
  rm -rf "$PROJ/.claude/hierarchy" "$CFG"; reset_state; init_geometry 200 60
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
}
call_count() { # <predicate over c>
  node -e '
    const fs = require("fs"); const dir = process.argv[1]; let files = [];
    try { files = fs.readdirSync(dir); } catch { files = []; }
    const rows = files.map((f) => JSON.parse(fs.readFileSync(dir + "/" + f, "utf8")));
    console.log(rows.filter(new Function("c", "return " + process.argv[2] + ";")).length);
  ' "$FAKE_STATE_DIR/calls" "$1"
}
starts() { call_count 'c.argv[0]==="agent" && c.argv[1]==="start"'; }
roles_in_cfg() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((d.roster&&d.roster.members||[]).map(m=>m.role).join(","))' "$CFG" 2>/dev/null; }
team_names() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((d.members||[]).map(m=>m.name+":"+(m.transport_id||"")).join(","))' "$TEAM_FILE" 2>/dev/null; }
run_add() { # <extra_env> <args...>
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" CLAUDE_PID=$$ $extra_env node \"$H/roster.mjs\" add $* --cwd \"$PROJ\" 2>&1"); RC=$?
}
seed_peer() { # <name> <role> <status> <pid>
  mkdir -p "$(dirname "$PEERS_FILE")"
  node -e 'const fs=require("fs");const[f,n,r,st,p]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4"
}

# ==== T1 — add reviewer (route peer) in a spawnable env: row written AND peer launched, read back
#          from the roster file, team.json and the stub's call log. Falsifying core: pre-fix `add`
#          exits 0 with the row and never spawns. ====
fresh
run_add "" --role reviewer
check "T1: add exits 0" '[ "$RC" -eq 0 ]'
check "T1: roster row present" '[ "$(roles_in_cfg)" = "reviewer" ]'
check "T1: team.json records the spawned reviewer with a pane id" 'echo "$(team_names)" | grep -q "^myrepo-reviewer:p[0-9]"'
check "T1: exactly one agent start went to the stub" '[ "$(starts)" -eq 1 ]'
check "T1: output states written AND spawned, separately" 'echo "$OUT" | grep -q "added reviewer to $CFG" && echo "$OUT" | grep -q "spawned myrepo-reviewer" && echo "$OUT" | grep -q "\"spawned\": true"'

# ==== T2 — --no-spawn: config only, zero stub calls, no team.json ====
fresh
run_add "" --role reviewer --no-spawn
check "T2: --no-spawn exits 0 with the row written" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T2: no spawn attempt (zero stub calls)" '[ "$(starts)" -eq 0 ] && [ ! -d "$FAKE_STATE_DIR/calls" ]'
check "T2: no team.json" '[ ! -f "$TEAM_FILE" ]'
check "T2: output says no session spawned" 'echo "$OUT" | grep -q "no session spawned"'

# ==== T3 — --route subagent: config only, notice, zero spawn attempts ====
fresh
run_add "" --role reviewer --route subagent
check "T3: subagent-route add exits 0 with the row written" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T3: notice names the route and says no session spawned" 'echo "$OUT" | grep -q "route subagent — dispatched on demand, no session spawned"'
check "T3: no spawn attempt" '[ "$(starts)" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'

# ==== T4 — spawn failure after a successful write: entry kept, exit 3, both facts + remedy ====
fresh
run_add "FAKE_HERDR_FAIL_ALWAYS_NAME=myrepo-reviewer" --role reviewer
check "T4: exit code 3" '[ "$RC" -eq 3 ]'
check "T4: roster entry persists" '[ "$(roles_in_cfg)" = "reviewer" ]'
check "T4: output names the write" 'echo "$OUT" | grep -q "added reviewer to $CFG"'
check "T4: output names the failure and the spawn-one retry" 'echo "$OUT" | grep -q "spawn FAILED:" && echo "$OUT" | grep -q "retry with roster.mjs spawn-one reviewer (or roster_spawn_one)"'
check "T4: the stub was actually asked to start (failure is post-write, not pre-spawn)" '[ "$(starts)" -ge 1 ]'

# ==== T5 — add --team X with no rosters.X: 0032 §3.4b error, zero spawn side effects ====
fresh
run_add "" --role reviewer --team X
check "T5: exits non-zero (validation, code 2 not 3)" '[ "$RC" -eq 2 ]'
check "T5: names init as the remedy (0032 §3.4b)" 'echo "$OUT" | grep -q "init"'
check "T5: nothing written, nothing spawned" '[ "$(roles_in_cfg)" = "" ] && [ "$(starts)" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'

# ==== T6 (structural) — one spawn implementation: add and spawn-one both call spawnOneCore;
#          add never calls layoutAndLaunch directly. ====
ADD_CASE=$(sed -n '/case "add": {/,/case "edit": {/p' "$H/roster.mjs")
SPAWN_ONE_CASE=$(sed -n '/case "spawn-one": {/,/case "adopt": {/p' "$H/roster.mjs")
check "T6: add's spawn path calls spawnOneCore" 'echo "$ADD_CASE" | grep -q "spawnOneCore("'
check "T6: spawn-one handler calls spawnOneCore" 'echo "$SPAWN_ONE_CASE" | grep -q "spawnOneCore("'
check "T6: add never calls layoutAndLaunch directly" '! echo "$ADD_CASE" | grep -q "layoutAndLaunch("'
check "T6: layoutAndLaunch is called from spawnOneCore, not the spawn-one case" '! echo "$SPAWN_ONE_CASE" | grep -q "layoutAndLaunch(" && sed -n "/^async function spawnOneCore/,/^}/p" "$H/roster.mjs" | grep -q "layoutAndLaunch("'

# ==== T7 — 0038 empty-roster scenario: no roster file anywhere; add reviewer auto-creates the
#          file (route peer default) AND spawns through the shared path with no team.json yet. ====
fresh; rm -f "$CFG"
run_add "" --role reviewer
check "T7: exits 0" '[ "$RC" -eq 0 ]'
check "T7: roster file auto-created with the reviewer row" '[ -f "$CFG" ] && [ "$(roles_in_cfg)" = "reviewer" ] && echo "$OUT" | grep -q "created a minimal one"'
check "T7: peer spawned and recorded in a fresh team.json" '[ "$(starts)" -eq 1 ] && echo "$(team_names)" | grep -q "^myrepo-reviewer:p[0-9]"'

# ==== T8 — a live peer of that role already exists (team.json slot record live in the registry):
#          config append + "already live", no second spawn. ====
fresh
mkdir -p "$(dirname "$TEAM_FILE")"
printf '%s' "{\"version\":1,\"team_id\":\"t-live\",\"created\":\"x\",\"roster_level\":\"repo\",\"transport\":\"herdr\",\"orchestrator\":{\"session_id\":null,\"pid\":$$},\"members\":[{\"role\":\"reviewer\",\"name\":\"myrepo-reviewer\",\"route\":\"peer\",\"transport_id\":\"p9\"}],\"partial\":false}" > "$TEAM_FILE"
seed_peer myrepo-reviewer reviewer up $$
run_add "" --role reviewer
check "T8: exits 0 with the row appended" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T8: reports already live, no session spawned" 'echo "$OUT" | grep -q "already live" && echo "$OUT" | grep -q "no session spawned"'
check "T8: no second spawn; team.json untouched" '[ "$(starts)" -eq 0 ] && [ "$(team_names)" = "myrepo-reviewer:p9" ]'

# ==== T9 — MCP roster_member add (spec 0039 §1.7): server.mjs runs with the herdr/pane env a live
#          session's MCP server carries but WITHOUT CLAUDE_PID (measured: the server env has
#          HERDR_ENV/HERDR_PANE_ID/PATH, no CLAUDE_PID) — the server must plumb --orchestrator-pid
#          itself (SESSION_PID = its parent, this script, live). Pre-plumbing, the CLI fails
#          "no orchestrator pid resolvable" and the MCP result is exit 3 — seen live before the fix. ====
mcp_add() { # <extra args JSON fragment>
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" node --input-type=module -e '
    import { spawn } from \"node:child_process\";
    const [server, cwd, extra] = process.argv.slice(1);
    const child = spawn(process.execPath, [server], { stdio: [\"pipe\", \"pipe\", \"ignore\"], env: { ...process.env, CLAUDE_PID: \"\" } });
    let buf = \"\";
    child.stdout.on(\"data\", (d) => { buf += d; for (const line of buf.split(\"\\n\")) { let m; try { m = JSON.parse(line); } catch { continue; } if (m.id === 2) { process.stdout.write(JSON.stringify(m)); child.kill(); process.exit(0); } } });
    child.stdin.write(JSON.stringify({ jsonrpc: \"2.0\", id: 1, method: \"initialize\", params: {} }) + \"\\n\");
    child.stdin.write(JSON.stringify({ jsonrpc: \"2.0\", id: 2, method: \"tools/call\", params: { name: \"roster_member\", arguments: { cwd, action: \"add\", role: \"reviewer\", ...JSON.parse(extra) } } }) + \"\\n\");
    setTimeout(() => { process.stdout.write(\"TIMEOUT\"); process.exit(1); }, 15000);
  ' \"$PLUGIN/mcp/server.mjs\" \"$PROJ\" '$1' 2>&1"); RC=$?
}
fresh
mcp_add '{}'
check "T9: MCP add returns a result, not an error" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"result\"" && ! echo "$OUT" | grep -q "\"isError\":true"'
check "T9: row written and peer spawned via MCP (server-plumbed orchestrator pid)" '[ "$(roles_in_cfg)" = "reviewer" ] && [ "$(starts)" -eq 1 ] && echo "$(team_names)" | grep -q "^myrepo-reviewer:p[0-9]"'
fresh
mcp_add '{"no_spawn":true}'
check "T9b: MCP no_spawn writes config only" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ] && [ "$(starts)" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'

# ==== T10 — global-level roster, route peer (spec 0039 §1.6 ruling): flagless add lands the row but
#           the spawn is guard-blocked → exit 3 naming BOTH escapes; with --allow-global it spawns.
#           Same requireAllowGlobal as spawn-one, reached through the shared core. ====
GCFG="$FAKEHOME/.claude/agent-hierarchy.json"
rm -rf "$PROJ/.claude/hierarchy" "$CFG" "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global
check "T10a: flagless add at global level exits 3 with the row written" '[ "$RC" -eq 3 ] && grep -q "\"role\": \"reviewer\"" "$GCFG"'
check "T10a: remedy names both escapes (add --allow-global, spawn-one --allow-global)" 'echo "$OUT" | grep -q "spawn FAILED:" && echo "$OUT" | grep -q -- "add --role reviewer --allow-global" && echo "$OUT" | grep -q -- "spawn-one reviewer --allow-global"'
check "T10a: nothing launched" '[ "$(starts)" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'
rm -f "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global --allow-global
check "T10b: add --allow-global at global level spawns" '[ "$RC" -eq 0 ] && [ "$(starts)" -eq 1 ] && echo "$(team_names)" | grep -q "^myrepo-reviewer:p[0-9]"'
rm -f "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
mcp_add '{"level":"global","allow_global":true}'
check "T10c: MCP allow_global passes through to the spawn" '[ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "\"isError\":true" && [ "$(starts)" -eq 1 ]'
rm -f "$GCFG"

# ==== T11 — review F1: --level naming a level SHADOWED by the resolving one (repo roster present,
#           add --level global --allow-global). The row lands at global, but the shared core resolves
#           the repo roster — spawning would launch the repo's member. Must refuse: exit 3, global
#           row written, nothing launched, no team.json, output names both levels. ====
rm -rf "$PROJ/.claude/hierarchy" "$CFG" "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role reviewer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global --allow-global
check "T11: exits 3 with the global row written and the repo roster untouched" '[ "$RC" -eq 3 ] && grep -q "\"role\": \"reviewer\"" "$GCFG" && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T11: nothing launched, no team.json" '[ "$(starts)" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'
check "T11: output names the level mismatch and both levels" 'echo "$OUT" | grep -q "spawn FAILED: level mismatch" && echo "$OUT" | grep -q "level \"global\"" && echo "$OUT" | grep -q "level \"repo\""'
rm -f "$GCFG"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
