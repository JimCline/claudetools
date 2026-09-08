#!/bin/bash
# agent-hierarchy — spec 0044 §1.10: `roster.mjs add <role>` writes the roster config row and
# SPAWNS NOTHING. This suite was spec 0039's — the spec that gave `add` an auto-spawn — and 0044
# §1.10 R2 keeps it rather than deleting it: its coverage of add's validation, level handling and
# route/kind variation is worth having, and only the spawn assertions invert. Every case that used
# to assert "and the peer launched" now asserts the stub was never called and no team file appeared,
# so a reintroduced auto-spawn fails here rather than passing silently.
#
# Fake herdr stub copied verbatim from test-roster-spawn-one.sh (itself from
# test-roster-create-spawn.sh, spec 0005 §11.1) — kept even though nothing here should reach it,
# because "the stub recorded zero calls" is the assertion, and a stub that is absent cannot make it.
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
# Spec 0044 §1.1 moved a bare team to `teams/<prefix>.json`. `add` must write NEITHER, so both
# paths are named and every "no team file" assertion checks both — checking only the old location
# would pass vacuously now.
TEAM_FILE="$PROJ/.claude/hierarchy/teams/$(basename "$PROJ").json"
LEGACY_TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
no_team_file() { [ ! -f "$TEAM_FILE" ] && [ ! -f "$LEGACY_TEAM_FILE" ]; }
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

# ==== T1 — add reviewer (route peer) in a fully spawnable env: the row is written and NOTHING is
#          launched. Falsifying core: 0039's `add` exits 0 here having started an agent, so a
#          revert of §1.10 turns "zero stub calls" red. Route peer is 0039's own spawning case and
#          is the one a regression reaches first. ====
fresh
run_add "" --role reviewer
check "T1: add exits 0" '[ "$RC" -eq 0 ]'
check "T1: roster row present" '[ "$(roles_in_cfg)" = "reviewer" ]'
check "T1: §1.10 — nothing was launched (zero stub calls at all)" '[ "$(starts)" -eq 0 ] && [ ! -d "$FAKE_STATE_DIR/calls" ]'
check "T1: §1.10 — no team file at either location" 'no_team_file'
check "T1: §1.10 — no spawn field in the output" '! echo "$OUT" | grep -q "\"spawn\":"'
check "T1: §1.10 — the write is reported and the spawn step is named, not left to be discovered" \
  'echo "$OUT" | grep -q "added reviewer to $CFG" && echo "$OUT" | grep -q "spawn-one reviewer"'
check "T1: §1.10 — the removal is surgical: the row is exactly what add always wrote" \
  'grep -q "\"role\": \"reviewer\"" "$CFG" && grep -q "\"model\": \"opus\"" "$CFG"'

# ==== T2 — --no-spawn (§1.10 R1): still accepted, now a silent no-op — byte-identical to T1. ====
T1_CFG="$(cat "$CFG")"
fresh
run_add "" --role reviewer --no-spawn
check "T2: R1 — --no-spawn exits 0 with the row written" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T2: R1 — produces the byte-identical roster the flagless form did" '[ "$(cat "$CFG")" = "$T1_CFG" ]'
check "T2: R1 — no spawn attempt, no team file" '[ "$(starts)" -eq 0 ] && no_team_file'
check "T2: R1 — the flag is not echoed back as a reason for anything" '! echo "$OUT" | grep -q -- "--no-spawn"'

# ==== T3 — --route subagent: config only, and the notice names why there is nothing to launch. ====
fresh
run_add "" --role reviewer --route subagent
check "T3: subagent-route add exits 0 with the row written" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T3: notice names the route and says nothing was launched" 'echo "$OUT" | grep -q "route subagent" && echo "$OUT" | grep -q "config only"'
check "T3: no spawn attempt, no team file" '[ "$(starts)" -eq 0 ] && no_team_file'

# ==== T4 — the stub rigged to FAIL on this exact name. Under 0039 that produced exit 3 and a
#          "spawn FAILED" remedy; under §1.10 add never asks the stub anything, so the rigging is
#          unreachable and the add is a plain success. ====
fresh
run_add "FAKE_HERDR_FAIL_ALWAYS_NAME=myrepo-reviewer" --role reviewer
check "T4: §1.10 — exit 0, not 3: there is no spawn left to fail" '[ "$RC" -eq 0 ]'
check "T4: roster entry written" '[ "$(roles_in_cfg)" = "reviewer" ]'
check "T4: §1.10 — no spawn-failure remedy text survives" '! echo "$OUT" | grep -q "spawn FAILED"'
check "T4: §1.10 — the stub was never asked to start anything" '[ "$(starts)" -eq 0 ]'

# ==== T5 — add --team X with no rosters.X: 0032 §3.4b error, unchanged by §1.10. ====
fresh
run_add "" --role reviewer --team X
check "T5: exits non-zero (validation, code 2)" '[ "$RC" -eq 2 ]'
check "T5: names init as the remedy (0032 §3.4b)" 'echo "$OUT" | grep -q "init"'
check "T5: nothing written, nothing spawned" '[ "$(roles_in_cfg)" = "" ] && [ "$(starts)" -eq 0 ] && no_team_file'

# ==== T6 (structural) — §1.10 asks for REMOVAL, not for an unreachable call. `add` must not
#          mention the spawn core at all; the two commands that legitimately spawn still route
#          through it, so the one-launch-path property (§1.4 point 3) is asserted at the same time. ====
ADD_CASE=$(sed -n '/case "add": {/,/case "edit": {/p' "$H/roster.mjs")
SPAWN_ONE_CASE=$(sed -n '/case "spawn-one": {/,/case "spawn-ad-hoc": {/p' "$H/roster.mjs")
AD_HOC_CASE=$(sed -n '/case "spawn-ad-hoc": {/,/case "adopt": {/p' "$H/roster.mjs")
check "T6: §1.10 — add does not call spawnOneCore (removed, not merely unreachable)" '! echo "$ADD_CASE" | grep -q "spawnOneCore("'
check "T6: §1.10 — add does not call layoutAndLaunch either" '! echo "$ADD_CASE" | grep -q "layoutAndLaunch("'
check "T6: spawn-one handler calls spawnOneCore" 'echo "$SPAWN_ONE_CASE" | grep -q "spawnOneCore("'
check "T6: §1.4 point 3 — spawn-ad-hoc goes through the SAME core, not a second builder" \
  'echo "$AD_HOC_CASE" | grep -q "spawnOneCore(" && ! echo "$AD_HOC_CASE" | grep -q "layoutAndLaunch(" && ! echo "$AD_HOC_CASE" | grep -q "spawnShape("'
check "T6: layoutAndLaunch is called from spawnOneCore, not from either command case" \
  '! echo "$SPAWN_ONE_CASE" | grep -q "layoutAndLaunch(" && sed -n "/^async function spawnOneCore/,/^}/p" "$H/roster.mjs" | grep -q "layoutAndLaunch("'
check "T6: §1.10 — the add-spawn error-context plumbing is gone with it" '! grep -q "addSpawnCtx" "$H/roster.mjs"'

# ==== T7 — 0038's empty-roster scenario: no roster file anywhere; add auto-creates it and writes
#          the row, and still launches nothing. 0038's auto-init is untouched by §1.10. ====
fresh; rm -f "$CFG"
run_add "" --role reviewer
check "T7: exits 0" '[ "$RC" -eq 0 ]'
check "T7: roster file auto-created with the reviewer row" '[ -f "$CFG" ] && [ "$(roles_in_cfg)" = "reviewer" ] && echo "$OUT" | grep -q "created a minimal one"'
check "T7: §1.10 — nothing spawned, no team file" '[ "$(starts)" -eq 0 ] && no_team_file'

# ==== T8 — a live peer of that role already exists. Under 0039 this reported "already live";
#          now add has no opinion about liveness at all — it appends the row and stops, and the
#          existing team record is left exactly as it was. ====
fresh
mkdir -p "$(dirname "$TEAM_FILE")"
printf '%s' "{\"version\":1,\"team_id\":\"t-live\",\"created\":\"x\",\"roster_level\":\"repo\",\"transport\":\"herdr\",\"orchestrator\":{\"session_id\":null,\"pid\":1},\"members\":[{\"role\":\"reviewer\",\"name\":\"myrepo-reviewer\",\"route\":\"peer\",\"transport_id\":\"p9\"}],\"partial\":false}" > "$TEAM_FILE"
seed_peer myrepo-reviewer reviewer up $$
run_add "" --role reviewer
check "T8: exits 0 with the row appended" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T8: §1.10 — no second spawn, and the team record is byte-untouched" '[ "$(starts)" -eq 0 ] && [ "$(team_names)" = "myrepo-reviewer:p9" ]'

# ==== T8b — kind coverage (spec 0043): a non-claude, pane-routed add is a config row too. ====
fresh
run_add "" --role reviewer --kind codex --route pane
check "T8b: add --kind codex --route pane exits 0 with the row written" '[ "$RC" -eq 0 ] && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T8b: §1.10 — a pane-routed non-claude add launches nothing either" '[ "$(starts)" -eq 0 ] && no_team_file'
check "T8b: the kind is recorded in the roster" 'grep -q "\"kind\": \"codex\"" "$CFG"'

# ==== T9 — MCP roster_member add: same contract through the tool surface. §1.10 R3 keeps
#          no_spawn accepted and ignored, and it is gone from the tool schema. ====
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
check "T9: §1.10 — row written via MCP, nothing spawned, no team file" '[ "$(roles_in_cfg)" = "reviewer" ] && [ "$(starts)" -eq 0 ] && no_team_file'
MCP_CFG="$(cat "$CFG")"
fresh
mcp_add '{"no_spawn":true}'
check "T9b: R3 — no_spawn is still accepted (no error) and ignored" '[ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "\"isError\":true"'
check "T9b: R3 — it produces the byte-identical roster the flagless call did" '[ "$(cat "$CFG")" = "$MCP_CFG" ]'
fresh
mcp_add '{"allow_global":true,"orchestrator_pid":1}'
check "T9c: R3 — allow_global and orchestrator_pid are still accepted and inert on add" \
  '[ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "\"isError\":true" && [ "$(roles_in_cfg)" = "reviewer" ] && [ "$(starts)" -eq 0 ]'
check "T9d: R3 — no_spawn is gone from the roster_member tool schema" \
  '! grep -q "no_spawn:" "$PLUGIN/mcp/server.mjs"'

# ==== T10 — global-level roster. 0039's §1.6 --allow-global guard was reached only through the
#           spawn, so with no spawn there is nothing to guard: the row lands, exit 0, either way. ====
GCFG="$FAKEHOME/.claude/agent-hierarchy.json"
rm -rf "$PROJ/.claude/hierarchy" "$CFG" "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global
check "T10a: §1.10 — a flagless global add exits 0 with the row written" '[ "$RC" -eq 0 ] && grep -q "\"role\": \"reviewer\"" "$GCFG"'
check "T10a: §1.10 — no spawn-failure remedy, nothing launched" '! echo "$OUT" | grep -q "spawn FAILED" && [ "$(starts)" -eq 0 ] && no_team_file'
rm -f "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global --allow-global
check "T10b: --allow-global is accepted and inert on add" '[ "$RC" -eq 0 ] && [ "$(starts)" -eq 0 ]'
rm -f "$GCFG"

# ==== T11 — a --level naming a level SHADOWED by the resolving one. 0039 had to refuse this,
#           because spawning would have launched the OTHER level's member. With no spawn the
#           hazard is gone: the row lands where it was told to, and both rosters stand. ====
rm -rf "$PROJ/.claude/hierarchy" "$CFG" "$GCFG"; reset_state; init_geometry 200 60
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" init --level global --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --level repo --role reviewer --cwd "$PROJ" >/dev/null
run_add "" --role reviewer --level global --allow-global
check "T11: §1.10 — the shadowed-level row lands, exit 0, with the repo roster intact" \
  '[ "$RC" -eq 0 ] && grep -q "\"role\": \"reviewer\"" "$GCFG" && [ "$(roles_in_cfg)" = "reviewer" ]'
check "T11: §1.10 — nothing launched, no team file, no level-mismatch refusal" \
  '[ "$(starts)" -eq 0 ] && no_team_file && ! echo "$OUT" | grep -q "level mismatch"'
rm -f "$GCFG"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
