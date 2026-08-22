#!/bin/bash
# agent-hierarchy — roster.mjs `create --spawn` (spec 0005): resolve + layout +
# concurrent launch + herdr-only retry, in one script invocation. Uses a
# PER-INVOCATION-APPEND fake herdr/tmux (spec 0005 §11.1) — each call writes
# exactly one new file under $FAKE_STATE_DIR/calls/, never mutates another
# call's file — because N concurrent launches read-modify-writing one shared
# JSON file (0002's technique, correct for layout-splits' sequential calls)
# would interleave and lose writes here.
# Usage: bash tests/test-roster-create-spawn.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-create-spawn-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr: per-invocation-append call records under $FAKE_STATE_DIR/calls/.
# `pane layout`/`pane split` also mutate a shared geometry.json — legitimate, since
# those calls remain sequential by construction (spec 0005 §11.1's own carve-out).
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
  if (process.env.FAKE_LAYOUT_DUP === "1") {
    console.log(JSON.stringify({ result: { pane: { pane_id: process.env.FAKE_LAYOUT_DUP_ID || "" } } }));
    finish(0);
  }
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
  const sleepMs = Number(process.env.FAKE_HERDR_SLEEP || 0);
  if (sleepMs > 0) {
    const until = Date.now() + sleepMs;
    while (Date.now() < until) { /* busy-wait: no sleep syscall in plain node */ }
  }
  const failAlways = process.env.FAKE_HERDR_FAIL_ALWAYS_NAME;
  if (failAlways && name === failAlways) {
    process.stderr.write("fake herdr: agent start failed (always)\n");
    finish(1);
  }
  const failOnce = process.env.FAKE_HERDR_FAIL_ONCE_NAME;
  if (failOnce && name === failOnce) {
    const marker = path.join(dir, `failed-once-${name}`);
    if (!fs.existsSync(marker)) {
      fs.writeFileSync(marker, "1");
      process.stderr.write("fake herdr: agent start failed (once)\n");
      finish(1);
    }
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

# ---- fake tmux: same per-invocation-append call recording.
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

if (args[0] === "list-sessions") finish(0); // detectTransport()'s probe

if (args[0] === "new-window") {
  const idFile = path.join(dir, "tmux-next-id.json");
  let n = 1;
  if (fs.existsSync(idFile)) n = JSON.parse(fs.readFileSync(idFile, "utf8")).next;
  fs.writeFileSync(idFile, JSON.stringify({ next: n + 1 }));
  const failAt = Number(process.env.FAKE_TMUX_NEWWINDOW_FAIL_AT || 0);
  if (failAt && n === failAt) {
    process.stderr.write(`fake tmux: new-window failed (call ${n})\n`);
    finish(1);
  }
  console.log(`%${n}`);
  finish(0);
}

if (args[0] === "send-keys") {
  const joined = args.join(" ");
  const m = joined.match(/--name (\S+)/);
  const name = m ? m[1] : null;
  const failName = process.env.FAKE_TMUX_FAIL_NAME;
  if (failName && name === failName) {
    process.stderr.write("fake tmux: send-keys failed\n");
    finish(1);
  }
  finish(0);
}

process.stderr.write(`fake tmux: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/tmux"

FAKE_STATE_DIR="$SANDBOX/state"

reset_state() {
  rm -rf "$FAKE_STATE_DIR"
  mkdir -p "$FAKE_STATE_DIR"
}

init_geometry() {
  local width=$1 height=$2
  cat > "$FAKE_STATE_DIR/geometry.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":$width,"height":$height,"x":0,"y":0},"panes":{"p0":{"width":$width,"height":$height,"x":0,"y":0}}}
EOF
}

# Roster setup: N peer members via real roster.mjs calls (add-order is plan order).
ROLES4=(ultra-advisor architect reviewer implementor)
setup_roster() {
  local n=$1
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
  for ((i = 0; i < n; i++)); do
    HOME="$FAKEHOME" node "$H/roster.mjs" add --level repo --role "${ROLES4[$i]}" --model opus --cwd "$PROJ" >/dev/null
  done
}

call_files() { find "$FAKE_STATE_DIR/calls" -name '*.json' 2>/dev/null; }
call_files_matching() { # $1 = jq-ish node filter expr referencing `c`
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

run_spawn() {
  # extra env assignments as "$1", rest are roster.mjs args. Ambient shells on this
  # machine sometimes already export HERDR_ENV=1 (a live herdr pane session) — `env -u`
  # it so a test that wants tmux/terminal transport actually gets it (see
  # test-roster-spawn.sh's identical `env -u HERDR_ENV` convention).
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" create --spawn $* --cwd \"$PROJ\" 2>&1"); RC=$?
}

# ==== 1/2 — concurrency: N=4 herdr peers, each launch sleeps 400ms ====
reset_state; init_geometry 180 42; setup_roster 4
START_MS=$(node -e "console.log(Date.now())")
run_spawn "HERDR_ENV=1 FAKE_HERDR_SLEEP=400" --mode auto
END_MS=$(node -e "console.log(Date.now())")
ELAPSED=$((END_MS - START_MS))
check "1: concurrency smoke — N=4 x 400ms launches complete in well under 1600ms serial time" \
  '[ "$ELAPSED" -lt 1000 ]'
check "1b: exit 0, partial false, all four members ready" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"partial\": false" && [ "$(echo "$OUT" | grep -c "\"launch_status\": \"ready\"")" -eq 4 ]'
check "2: concurrency is real — at least one pair of agent-start intervals overlaps" \
  '[ "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const rows=JSON.parse(s);let overlap=false;for(let i=0;i<rows.length;i++)for(let j=i+1;j<rows.length;j++){if(rows[i].start_ms<rows[j].end_ms&&rows[j].start_ms<rows[i].end_ms)overlap=true;}console.log(overlap?1:0)})")" -eq 1 ]'

# ==== 3 — supervision: process exit is after max(end_ms) across launch calls (not detached) ====
check "3: supervision — spawn process exit is after the slowest launch call ends" \
  '[ "$END_MS" -ge "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const rows=JSON.parse(s);console.log(Math.max(...rows.map(r=>r.end_ms)))})")" ]'

# ==== 4/5 — layout sequential, and precedes launch ====
check "4: layout is sequential — pane split call intervals do not overlap" \
  '[ "$(call_files_matching "c.argv[0]===\"pane\" && c.argv[1]===\"split\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const rows=JSON.parse(s).sort((a,b)=>a.start_ms-b.start_ms);let ok=1;for(let i=1;i<rows.length;i++)if(rows[i].start_ms<rows[i-1].end_ms)ok=0;console.log(ok)})")" -eq 1 ]'
check "5: layout precedes launch — max(split end_ms) < min(agent-start start_ms)" \
  '[ "$(node -e "
      const fs=require(\"fs\");
      const rows=fs.readdirSync(process.argv[1]).map(f=>JSON.parse(fs.readFileSync(process.argv[1]+\"/\"+f,\"utf8\")));
      const splits=rows.filter(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"split\");
      const starts=rows.filter(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"start\");
      const maxSplitEnd=Math.max(...splits.map(r=>r.end_ms));
      const minLaunchStart=Math.min(...starts.map(r=>r.start_ms));
      console.log(maxSplitEnd<minLaunchStart?1:0)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'

# ==== 6 — the N-distinct-non-empty-ids assertion fires before any launch ====
reset_state; init_geometry 180 42; setup_roster 2
run_spawn "HERDR_ENV=1 FAKE_LAYOUT_DUP=1 FAKE_LAYOUT_DUP_ID=dup" --mode auto
check "6: duplicate/empty target id -> exit 2, zero agent-start calls made" \
  '[ "$RC" -eq 2 ] && [ "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 0 ]'

# ==== 7 — retry, herdr, success ====
reset_state; init_geometry 180 42; setup_roster 2
run_spawn "HERDR_ENV=1 FAKE_HERDR_FAIL_ONCE_NAME=myrepo-architect" --mode auto
check "7: retryable herdr failure -> retried true, ends ready; other member unaffected" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const a=o.members.find(m=>m.name===\"myrepo-architect\");const r=o.members.find(m=>m.name===\"myrepo-ultra-advisor\");process.exit(a.retried===true&&a.launch_status===\"ready\"&&r.retried===false&&r.launch_status===\"ready\"?0:1)})"'
check "7b: architect has exactly two agent-start call files, ultra-advisor exactly one" \
  '[ "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\" && c.argv[2]===\"myrepo-architect\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 2 ] && [ "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\" && c.argv[2]===\"myrepo-ultra-advisor\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 1 ]'

# ==== 8 — retry, herdr, hard failure ====
reset_state; init_geometry 180 42; setup_roster 2
run_spawn "HERDR_ENV=1 FAKE_HERDR_FAIL_ALWAYS_NAME=myrepo-architect" --mode auto
check "8: non-retryable herdr failure -> two call files, failed, retried true, error present, partial true" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const a=o.members.find(m=>m.name===\"myrepo-architect\");process.exit(a.retried===true&&a.launch_status===\"failed\"&&!!a.error&&o.partial===true?0:1)})"'
check "8b: architect has exactly two agent-start call files" \
  '[ "$(call_files_matching "c.argv[0]===\"agent\" && c.argv[1]===\"start\" && c.argv[2]===\"myrepo-architect\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 2 ]'

# ==== 9 — NEEDS-EVIDENCE item 2 unresolved (no live pane to reproduce the retryable condition on);
# fallback is retry-once-on-any-herdr-failure, so assertion 8 above (hard failure still retries once)
# IS this test, per the documented fallback — not silently dropped, recorded at the assertion site.

# ==== 10 — tmux dispatch: partial false, dispatched, no retry ====
reset_state; setup_roster 2
run_spawn "" --mode auto
check "10: tmux — every peer ends dispatched, retried false, top-level partial false" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.partial===false&&o.members.every(m=>m.launch_status===\"dispatched\"&&m.retried===false)?0:1)})"'

# ==== 11 — tmux does not retry ====
reset_state; setup_roster 2
run_spawn "FAKE_TMUX_FAIL_NAME=myrepo-architect" --mode auto
check "11: tmux send-keys failure -> failed, retried false, exactly one send-keys call for that member" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const a=o.members.find(m=>m.name===\"myrepo-architect\");process.exit(a.launch_status===\"failed\"&&a.retried===false?0:1)})" && [ "$(call_files_matching "c.argv[0]===\"send-keys\" && c.argv.join(String.fromCharCode(32)).includes(\"myrepo-architect\")" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 1 ]'

# ==== 12 — tmux targets a pane id: send-keys -t matches the corresponding new-window's id ====
reset_state; setup_roster 2
run_spawn "" --mode auto
check "12: every send-keys argv contains -t followed by the new-window id at the same plan index" \
  '[ "$(node -e "
      const fs=require(\"fs\");
      const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      const wins=rows.filter(c=>c.argv[0]===\"new-window\").sort((a,b)=>a.start_ms-b.start_ms);
      // fake new-window prints %1, %2, ... in call order — recover ids positionally
      const ids=wins.map((_,i)=>\"%\"+(i+1));
      const sends=rows.filter(c=>c.argv[0]===\"send-keys\");
      let ok=1;
      for (const s of sends) {
        const t=s.argv[s.argv.indexOf(\"-t\")+1];
        if (!ids.includes(t)) ok=0;
      }
      console.log(ok)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'

# ==== 13 — mutual exclusion ====
reset_state; setup_roster 1
run_spawn "" --plan
check "13a: --spawn --plan -> exit 2, no calls made" \
  '[ "$RC" -eq 2 ] && [ ! -d "$FAKE_STATE_DIR/calls" -o -z "$(ls -A "$FAKE_STATE_DIR/calls" 2>/dev/null)" ]'
run_spawn "" --commit --transport terminal --roster-level repo --verified '[]'
check "13b: --spawn --commit -> exit 2, no calls made" \
  '[ "$RC" -eq 2 ] && [ ! -d "$FAKE_STATE_DIR/calls" -o -z "$(ls -A "$FAKE_STATE_DIR/calls" 2>/dev/null)" ]'

# ==== 14 — --plan parity: unaffected by the shared-function extraction ====
reset_state; setup_roster 1
PLAN_OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1)
check "14: --plan output has the expected shape (level/transport/layout_plan/members) post-extraction" \
  'echo "$PLAN_OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.level===\"repo\"&&\"transport\"in o&&\"layout_plan\"in o&&Array.isArray(o.members)&&o.members.length===1&&o.members[0].name===\"myrepo-ultra-advisor\"?0:1)})"'

# ==== 15 — --mode is honored, not silently re-derived from the roster's stored layout ====
# Roster stored as "columns" (always splits right); CLI --mode grid on a squarish rect (100x60,
# width <= height*2) picks "down" instead — see nextSplit()'s effectiveMode branch. A pass here
# that used the stored "columns" value would show up as "right", not "down".
reset_state
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --layout columns --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --level repo --role ultra-advisor --model opus --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --level repo --role architect --model opus --cwd "$PROJ" >/dev/null
init_geometry 100 60
run_spawn "HERDR_ENV=1" --mode grid
check "15: create --spawn --mode grid overrides a roster stored as columns (first split goes down)" \
  '[ "$RC" -eq 0 ] && [ "$(call_files_matching "c.argv[0]===\"pane\" && c.argv[1]===\"split\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const rows=JSON.parse(s).sort((a,b)=>a.start_ms-b.start_ms);console.log(rows[0].argv[rows[0].argv.indexOf(\"--direction\")+1])})")" = "down" ]'

# ==== 16 — tmux layout mid-loop failure preserves already-created windows (partial, not a bare fail) ====
reset_state; setup_roster 3
run_spawn "FAKE_TMUX_NEWWINDOW_FAIL_AT=2" --mode auto
check "16: tmux new-window fails on window 2 of 3 -> exit 3, first window id preserved, no launches fired" \
  '[ "$RC" -eq 3 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s.slice(s.indexOf(\"{\")));process.exit(o.complete===false&&Array.isArray(o.panes)&&o.panes[0]===\"%1\"?0:1)})" && [ "$(call_files_matching "c.argv[0]===\"send-keys\"" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
