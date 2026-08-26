#!/bin/bash
# agent-hierarchy — herdr pane auto-labeling (spec 0014): a best-effort
# `herdr pane rename <pane-id> claude - <member.name>` call inside
# `launchMember()`, strictly after that member's own successful herdr launch.
# Workaround for a missing herdr feature (show_agent_labels_on_pane_borders is
# a boolean, not a template) — retire this, don't extend it, if herdr ever
# grows a real label template.
# Reuses the per-invocation-append fake herdr/tmux stub (spec 0005 §11.1),
# extended with a `pane rename` handler that can fail by exit code
# (FAKE_HERDR_RENAME_FAIL_PANE) or by throwing via unparseable stdout
# (FAKE_HERDR_RENAME_GARBLE_PANE) — two distinct failure origins because a
# try/catch that only checks an exit code would pass the first and miss the
# second (§8 item 5).
# Usage: bash tests/test-herdr-pane-label.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-herdr-pane-label-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr: per-invocation-append call records under $FAKE_STATE_DIR/calls/,
# same technique as test-roster-create-spawn.sh, plus a `pane rename` handler.
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

if (args[0] === "pane" && args[1] === "rename") {
  const paneId = args[2];
  const failPane = process.env.FAKE_HERDR_RENAME_FAIL_PANE;
  if (failPane && paneId === failPane) {
    process.stderr.write("fake herdr: pane rename failed (exit)\n");
    finish(1);
  }
  const garblePane = process.env.FAKE_HERDR_RENAME_GARBLE_PANE;
  if (garblePane && paneId === garblePane) {
    console.log("not valid json {{{");
    finish(0);
  }
  console.log(JSON.stringify({ result: { pane: { pane_id: paneId, label: args.slice(3).join(" ") } } }));
  finish(0);
}

process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

# ---- fake tmux: same call-logging convention (for test 8's tmux sub-case).
cat > "$SANDBOX/bin/tmux" <<EOF
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
  fs.writeFileSync(file, JSON.stringify({ argv: args, start_ms: startMs, end_ms: Date.now(), exit: exitCode, pid: process.pid, bin: "tmux" }));
  process.exit(exitCode);
}
if (args[0] === "list-sessions") finish(0);
if (args[0] === "new-window") {
  const idFile = path.join(dir, "tmux-next-id.json");
  let n = 1;
  if (fs.existsSync(idFile)) n = JSON.parse(fs.readFileSync(idFile, "utf8")).next;
  fs.writeFileSync(idFile, JSON.stringify({ next: n + 1 }));
  console.log(`%${n}`);
  finish(0);
}
if (args[0] === "send-keys") finish(0);
process.stderr.write(`fake tmux: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/tmux"

# ---- fake claude: terminal-transport tests (7, 8b) shell out to a real
# `claude ... --bg` command string (spawnShape()'s terminal branch); this stub
# just exits 0. Kept in its own directory so PATH can include it WITHOUT
# herdr/tmux also being resolvable (an ambient no-herdr, no-tmux machine).
mkdir -p "$SANDBOX/bin-claude-only"
cat > "$SANDBOX/bin-claude-only/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin-claude-only/claude"

FAKE_STATE_DIR="$SANDBOX/state"
reset_state() { rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"; }
init_geometry() { # <width> <height>
  local width=$1 height=$2
  cat > "$FAKE_STATE_DIR/geometry.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":$width,"height":$height,"x":0,"y":0},"panes":{"p0":{"width":$width,"height":$height,"x":0,"y":0}}}
EOF
}
clear_hierarchy() { rm -rf "$PROJ/.claude/hierarchy"; rm -f "$PROJ/.claude/agent-hierarchy.json"; }

ROLES4=(ultra-advisor architect reviewer implementor)
setup_roster() { # <n> [level]
  local n=$1 level=${2:-repo}
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level "$level" --route peer --cwd "$PROJ" >/dev/null
  for ((i = 0; i < n; i++)); do
    HOME="$FAKEHOME" node "$H/roster.mjs" add --level "$level" --role "${ROLES4[$i]}" --model opus --cwd "$PROJ" >/dev/null
  done
}

call_files_matching() { # <js predicate over c>
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

run_spawn() { # <extra_env> <args...> -- create --spawn
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" create --spawn $* --cwd \"$PROJ\" 2>&1"); RC=$?
}
run_one() { # <extra_env> <args...> -- spawn-one
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" spawn-one $* --cwd \"$PROJ\" 2>&1"); RC=$?
}

# ==== 1 — right label, right pane: two members, one `pane rename` per member,
# each pairing that member's own name with that member's own transport_id
# (p1=ultra-advisor, p2=architect — deterministic split order). ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 2
run_spawn "HERDR_ENV=1" --mode auto
check "1: exit 0, two ready members" \
  '[ "$RC" -eq 0 ] && [ "$(echo "$OUT" | grep -c "\"launch_status\": \"ready\"")" -eq 2 ]'
check "1a: exactly one pane-rename call, targeting p1, with myrepo-ultra-advisor in the label args" \
  '[ "$(call_files_matching "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p1\" && c.argv.includes(\"myrepo-ultra-advisor\")")" != "[]" ]'
check "1b: exactly one pane-rename call, targeting p2, with myrepo-architect in the label args" \
  '[ "$(call_files_matching "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p2\" && c.argv.includes(\"myrepo-architect\")")" != "[]" ]'
check "1c: exactly two pane-rename calls total (one per member, none extra)" \
  '[ "$(call_count "c.argv[0]===\"pane\" && c.argv[1]===\"rename\"")" -eq 2 ]'
check "1d: the rename argv shape matches spec §4.4 exactly: [pane, rename, <id>, claude, -, <name>]" \
  '[ "$(call_files_matching "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p1\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const r=JSON.parse(s)[0];console.log(r&&r.argv.length===6&&r.argv[3]===\"claude\"&&r.argv[4]===\"-\"&&r.argv[5]===\"myrepo-ultra-advisor\"?1:0)})")" -eq 1 ]'

# ==== 2 — never the orchestrator's own pane (§4.2 trap: HERDR_PANE_ID=p0 is
# guaranteed present and wrong). Reuses run 1's call log. ====
check "2: no pane-rename call ever targets p0 (HERDR_PANE_ID)" \
  '[ "$(call_count "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p0\"")" -eq 0 ]'

# ==== 3 — ordering: each member's pane-rename starts after that same member's
# own agent-start call ends (per-member, not a global ordering assertion —
# launches are concurrent). Reuses run 1's call log. ====
check "3: p1's rename starts after p1's own agent-start ends" \
  '[ "$(node -e "
      const fs=require(\"fs\");
      const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      const start=rows.find(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"start\"&&c.argv[2]===\"myrepo-ultra-advisor\");
      const rename=rows.find(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"rename\"&&c.argv[2]===\"p1\");
      console.log(start&&rename&&rename.start_ms>=start.end_ms?1:0)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'
check "3b: p2's rename starts after p2's own agent-start ends" \
  '[ "$(node -e "
      const fs=require(\"fs\");
      const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      const start=rows.find(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"start\"&&c.argv[2]===\"myrepo-architect\");
      const rename=rows.find(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"rename\"&&c.argv[2]===\"p2\");
      console.log(start&&rename&&rename.start_ms>=start.end_ms?1:0)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'

# ==== 4 — rename failure (non-zero exit) does not fail the launch. This is §5.1
# and the highest-value test: the new insertion point is inside the promise
# whose rejection means "launch failed". spawn-one so team.json is written
# directly (single-role command), unlike create --spawn which only launches. ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "HERDR_ENV=1 FAKE_HERDR_RENAME_FAIL_PANE=p1" ultra-advisor
check "4: rename exit-failure -> spawn still succeeds, launch_status not failed" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true" && ! echo "$OUT" | grep -q "\"launch_status\": \"failed\""'
check "4b: team.json written with the correct transport_id (p1) despite the rename failure" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(t.members[0].transport_id===\"p1\"?0:1)" "$TEAM_FILE"'
check "4c: partial unaffected — a single successful spawn-one carries no partial flag issue" \
  '! echo "$OUT" | grep -q "\"partial\": true"'
check "4d: rename exit-failure IS observable — output carries \"label\": \"failed\" for this member" \
  'echo "$OUT" | grep -q "\"label\": \"failed\""'
check "4e: label is NOT persisted into team.json — output-only, matching createSpawn" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(\"label\" in t.members[0]?1:0)" "$TEAM_FILE"'

# ==== 5 — rename *throw* (unparseable stdout, not an exit code) does not fail
# the launch either — a separate test because a try/catch that only checks an
# exit code would pass 4 and fail this one. ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
run_one "HERDR_ENV=1 FAKE_HERDR_RENAME_GARBLE_PANE=p1" ultra-advisor
check "5: rename throw (malformed JSON) -> spawn still succeeds, launch_status not failed" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true" && ! echo "$OUT" | grep -q "\"launch_status\": \"failed\""'
check "5b: team.json written with the correct transport_id (p1) despite the rename throw" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(t.members[0].transport_id===\"p1\"?0:1)" "$TEAM_FILE"'
check "5c: rename throw IS observable — output carries \"label\": \"failed\" for this member" \
  'echo "$OUT" | grep -q "\"label\": \"failed\""'

# ==== 6 — no rename after a failed launch (§5.2 item 4): the pane may hold no
# agent, so labeling it would assert something false. ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 2
run_spawn "HERDR_ENV=1 FAKE_HERDR_FAIL_ALWAYS_NAME=myrepo-architect" --mode auto
check "6: architect's launch failed" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const a=o.members.find(m=>m.name===\"myrepo-architect\");process.exit(a.launch_status===\"failed\"?0:1)})"'
check "6b: no pane-rename call targets architect's pane (p2) — the failed launch got no rename" \
  '[ "$(call_count "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p2\"")" -eq 0 ]'
check "6c: the other (successful) member still got its rename" \
  '[ "$(call_count "c.argv[0]===\"pane\" && c.argv[1]===\"rename\" && c.argv[2]===\"p1\"")" -eq 1 ]'

# ==== 7 — herdr absent from the ambient environment (no HERDR_ENV, no herdr/
# tmux binary on PATH — what a machine without herdr looks like). Spawn
# succeeds via the terminal transport; no rename is attempted because there is
# no herdr call of any kind. ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 1
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin-claude-only:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" spawn-one ultra-advisor --cwd "$PROJ" 2>&1); RC=$?
check "7: herdr absent from PATH -> spawn still succeeds (terminal transport) — this is the real assertion" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'
check "7b: consistency check only — no calls dir populated (PATH excludes the stub entirely here, so this can't fail either way regardless of whether the herdrOnPath() guard exists; test 8a is what actually discriminates the guard, with the stub present but transport=tmux)" \
  '[ ! -d "$FAKE_STATE_DIR/calls" ] || [ -z "$(ls -A "$FAKE_STATE_DIR/calls" 2>/dev/null)" ]'

# ==== 8 — non-herdr transports (tmux, then terminal): zero herdr invocations
# of any kind, forced explicitly rather than by ambient absence (distinct
# from 7: here the stub IS available but the transport never selects it). ====
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 2
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" create --spawn --mode auto --cwd "$PROJ" 2>&1); RC=$?
check "8a: tmux transport -> exit 0, zero herdr-tagged calls" \
  '[ "$RC" -eq 0 ] && [ "$(call_count "c.bin===\"herdr\"")" -eq 0 ]'
reset_state; clear_hierarchy; init_geometry 180 42; setup_roster 2
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$SANDBOX/bin-claude-only:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" node "$H/roster.mjs" create --spawn --mode auto --cwd "$PROJ" 2>&1); RC=$?
check "8b: terminal transport (no tmux either) -> exit 0, zero herdr-tagged calls" \
  '[ "$RC" -eq 0 ] && { [ ! -d "$FAKE_STATE_DIR/calls" ] || [ "$(call_count "c.bin===\"herdr\"")" -eq 0 ]; }'

# ==== 9 — regression: the suites sharing launchMember()/layoutAndLaunch()
# (create --spawn, spawn-one) and the herdr-presence hard-fail path this
# reuses (herdrOnPath()) still pass unmodified. Full 30-file suite run is
# reported separately by the caller, per the existing test-roster-spawn-one.sh
# convention of regression-checking only its closest extraction-adjacent
# suites here rather than the whole tree. ====
CS_OUT=$(bash "$PLUGIN/tests/test-roster-create-spawn.sh" 2>&1); CS_RC=$?
check "9a: test-roster-create-spawn.sh passes unmodified" '[ "$CS_RC" -eq 0 ]'
SO_OUT=$(bash "$PLUGIN/tests/test-roster-spawn-one.sh" 2>&1); SO_RC=$?
check "9b: test-roster-spawn-one.sh passes unmodified" '[ "$SO_RC" -eq 0 ]'
HP_OUT=$(bash "$PLUGIN/tests/test-herdr-presence.sh" 2>&1); HP_RC=$?
check "9c: test-herdr-presence.sh passes unmodified" '[ "$HP_RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
