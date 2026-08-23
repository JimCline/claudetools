#!/bin/bash
# agent-hierarchy — roster.mjs `layout-splits`: the herdr-execution loop, the
# one subcommand that shells out (spec 0002 §5.3). Uses a STATEFUL fake
# `herdr` on PATH (same technique test-roster-spawn.sh:27-32 uses for tmux)
# that actually halves the target pane's rect on each split — a fixed-geometry
# stub would let a non-mutating loop pass.
# Usage: bash tests/test-roster-layout-splits.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-layout-splits-test.XXXXXX")"
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

# ---- the stateful fake herdr: a small node script backed by a JSON state file
cat > "$SANDBOX/bin/herdr" <<EOF
#!/usr/bin/env node
$(cat <<'FAKEEOF'
const fs = require("fs");
const stateFile = process.env.FAKE_HERDR_STATE;
const args = process.argv.slice(2);

function loadState() {
  return JSON.parse(fs.readFileSync(stateFile, "utf8"));
}
function saveState(s) {
  fs.writeFileSync(stateFile, JSON.stringify(s));
}

const sleepMs = Number(process.env.FAKE_HERDR_SLEEP || 0);
if (sleepMs > 0) {
  const until = Date.now() + sleepMs;
  while (Date.now() < until) { /* busy-wait: no sleep syscall available in plain node */ }
}

if (args[0] === "pane" && args[1] === "layout") {
  const s = loadState();
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  console.log(JSON.stringify({ id: "cli:pane:layout", result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false }, type: "pane_layout" } }));
  process.exit(0);
}

if (args[0] === "pane" && args[1] === "split") {
  const s = loadState();
  s.splitCount = (s.splitCount || 0) + 1;
  const failOn = Number(process.env.FAKE_HERDR_FAIL_ON || 0);
  if (failOn > 0 && s.splitCount === failOn) {
    saveState(s); // the failed attempt still counted; no new pane created
    process.stderr.write("fake herdr: pane split failed\n");
    process.exit(1);
  }
  const paneIdx = args.indexOf("--pane");
  const dirIdx = args.indexOf("--direction");
  const target = args[paneIdx + 1];
  const direction = args[dirIdx + 1];
  const rect = s.panes[target];
  const newId = `p${s.nextId++}`;
  if (direction === "right") {
    const w1 = Math.floor(rect.width / 2);
    const w2 = rect.width - w1;
    s.panes[target] = { ...rect, width: w1 };
    s.panes[newId] = { ...rect, width: w2, x: rect.x + w1 };
  } else {
    const h1 = Math.floor(rect.height / 2);
    const h2 = rect.height - h1;
    s.panes[target] = { ...rect, height: h1 };
    s.panes[newId] = { ...rect, height: h2, y: rect.y + h1 };
  }
  saveState(s);
  console.log(JSON.stringify({ result: { pane: { pane_id: newId } } }));
  process.exit(0);
}

process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
process.exit(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

init_state() {
  local width=$1 height=$2
  cat > "$SANDBOX/state.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":$width,"height":$height,"x":0,"y":0},"panes":{"p0":{"width":$width,"height":$height,"x":0,"y":0}}}
EOF
}

run() {
  OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/state.json" HERDR_PANE_ID=p0 node "$H/roster.mjs" layout-splits "$@" --cwd "$PROJ" 2>&1)
  RC=$?
}

# 1 — happy path
init_state 180 42
run --pane-count 3 --mode grid
check "1: happy path exit 0, complete true, 3 distinct panes, 3 splits i=1..3" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const ok=o.complete===true&&o.panes.length===3&&new Set(o.panes).size===3&&o.panes.every(Boolean)&&o.splits.length===3&&o.splits.every((sp,i)=>sp.i===i+1);process.exit(ok?0:1)})"'

# 2 — it actually split: final state has 4 panes, areas within 5%, from two start rects
for dims in "180 42" "200 50"; do
  set -- $dims
  init_state "$1" "$2"
  run --pane-count 3 --mode grid
  check "2: end-to-end equal-area (4 panes within 5%) at ${1}x${2}" \
    'node -e "const s=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\"));const ids=Object.keys(s.panes);const areas=ids.map(id=>s.panes[id].width*s.panes[id].height);const max=Math.max(...areas),min=Math.min(...areas);process.exit(ids.length===4&&ids.includes(\"p0\")&&(max-min)/max<=0.05?0:1)"'
done

# 3 — self participates: at least one split targets self; for pane-count 3, more than one does
init_state 180 42
run --pane-count 3 --mode grid
check "3: self participates in more than one split (Defect E end-to-end guard)" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const selfSplits=o.splits.filter(sp=>sp.target===\"p0\").length;process.exit(selfSplits>1?0:1)})"'
check "3b: final layout is a grid, not a row — exactly two distinct y-values across the four panes (0007 §7.3)" \
  '[ "$(node -e "const s=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\"));console.log(new Set(Object.values(s.panes).map(r=>r.y)).size)")" -eq 2 ]'

# 4 — partial: FAIL_ON=2 -> exit 3, 1 pane, complete false, failed_at 2, attempted present, error non-empty
init_state 180 42
FAKE_HERDR_FAIL_ON=2 run --pane-count 3 --mode grid
check "4: partial (FAIL_ON=2) -> exit 3, panes has 1 id, complete false, failed_at 2, attempted+error present" \
  '[ "$RC" -eq 3 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.complete===false&&o.panes.length===1&&o.failed_at===2&&o.attempted&&o.error?0:1)})"'
check "4b: the already-created pane still exists in the fake's state (not cleaned up)" \
  '[ "$(node -e "console.log(Object.keys(JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\")).panes).length)")" -eq 2 ]'

# 5 — nothing-happened is exit 2, not 3: FAIL_ON=1 (the very first split fails)
init_state 180 42
FAKE_HERDR_FAIL_ON=1 run --pane-count 3 --mode grid
check "5: FAIL_ON=1 -> exit 2 (first split failed, nothing to hand back), distinguishable from exit 3" \
  '[ "$RC" -eq 2 ]'

# 6 — herdr absent from PATH -> exit 2, named message, no JSON
init_state 180 42
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 PATH="$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/state.json" HERDR_PANE_ID=p0 node "$H/roster.mjs" layout-splits --pane-count 3 --mode grid --cwd "$PROJ" 2>&1); RC=$?
check "6: herdr absent from PATH -> exit 2, no JSON" \
  '[ "$RC" -eq 2 ] && ! echo "$OUT" | grep -q "^{"'

# 7 — timeout: SLEEP=2000 with a 300ms timeout -> non-zero exit, message names the timeout, well under 2s
init_state 180 42
START=$(date +%s)
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/state.json" HERDR_PANE_ID=p0 FAKE_HERDR_SLEEP=2000 AH_HERDR_TIMEOUT_MS=300 node "$H/roster.mjs" layout-splits --pane-count 1 --mode grid --cwd "$PROJ" 2>&1); RC=$?
END=$(date +%s)
check "7: timeout -> non-zero exit, message names the timeout, under 2s" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "timed out" && [ $((END-START)) -lt 2 ]'

# 8 — wrong transport: HERDR_ENV unset, a fake tmux present -> exit 2, named message, fake herdr never invoked
init_state 180 42
cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"
rm -f "$SANDBOX/marker"
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/state.json" HERDR_PANE_ID=p0 node "$H/roster.mjs" layout-splits --pane-count 1 --mode grid --cwd "$PROJ" 2>&1); RC=$?
check "8: wrong transport (tmux) -> exit 2, named message" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "herdr"'
check "8b: fake herdr never invoked (state untouched — still 1 pane)" \
  '[ "$(node -e "console.log(Object.keys(JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\")).panes).length)")" -eq 1 ]'

# 9 — --next mutates nothing: exit 0, decision + geometry returned, state byte-identical afterwards
init_state 180 42
BEFORE=$(cat "$SANDBOX/state.json")
run --next --mode grid --pane-count 3 --created '[]'
AFTER=$(cat "$SANDBOX/state.json")
check "9: --next exit 0, returns target/direction/geometry" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\"" && echo "$OUT" | grep -q "\"geometry\""'
check "9b: --next mutates nothing (state byte-identical)" \
  '[ "$BEFORE" = "$AFTER" ]'

# 10 — --apply computes nothing: given a target/direction next-split would not have chosen, it splits anyway
init_state 180 42
run --apply --target p0 --direction down
check "10: --apply splits exactly the given target/direction, not a computed one" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'
check "10b: state reflects a down split (p0 height halved from 42)" \
  '[ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\")).panes.p0.height)")" -eq 21 ]'

# 11 — --next --apply together -> exit 2
init_state 180 42
run --next --apply --mode grid --pane-count 3 --target p0 --direction down --created '[]'
check "11: --next and --apply together -> exit 2" \
  '[ "$RC" -eq 2 ]'

# 12 — --pane-count 0 -> exit 0, {"panes":[],"complete":true}, fake never invoked
init_state 180 42
run --pane-count 0 --mode grid
check "12: --pane-count 0 -> exit 0, empty complete result" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"panes\": \[\]" && echo "$OUT" | grep -q "\"complete\": true"'
check "12b: fake herdr never invoked (state untouched)" \
  '[ "$(node -e "console.log(Object.keys(JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/state.json\",\"utf8\")).panes).length)")" -eq 1 ]'

# ---- connection-free invariant: put a fake herdr that touches a marker file and exits 1 on PATH,
# run every OTHER subcommand, assert the marker is never created.
cat > "$SANDBOX/bin/herdr-marker" <<'EOF'
#!/bin/sh
touch "$FAKE_HERDR_MARKER"
exit 1
EOF
mkdir -p "$SANDBOX/markerbin"
cat > "$SANDBOX/markerbin/herdr" <<EOF
#!$(command -v node)
require("fs").writeFileSync(process.env.FAKE_HERDR_MARKER, "");
process.exit(1);
EOF
chmod +x "$SANDBOX/markerbin/herdr"
rm -f "$SANDBOX/marker"
INVOK() { HOME="$FAKEHOME" HERDR_ENV=1 PATH="$SANDBOX/markerbin:$NODE_DIR" FAKE_HERDR_MARKER="$SANDBOX/marker" node "$H/roster.mjs" "$@" --cwd "$PROJ" >/dev/null 2>&1; }
INVOK show
INVOK init --level repo --route peer
INVOK add --level repo --role architect --model opus
INVOK edit --member myrepo-architect --model sonnet
INVOK remove --member myrepo-architect
INVOK init --level repo --route peer
INVOK layout --level repo --layout grid
INVOK next-split --mode grid --pane-count 1 --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}}]'
INVOK create --plan
INVOK create --commit --transport terminal --roster-level repo --verified '[]'
INVOK disband --kill --plan
INVOK disband --kill --commit
check "invariant: no subcommand but layout-splits reaches herdrCall (marker never created)" \
  '[ ! -e "$SANDBOX/marker" ]'

# ---- create --spawn joins the permitted list (spec 0005 §11.3): unlike every subcommand above, it
# DOES reach herdrCall on a herdr roster with a peer member.
rm -f "$SANDBOX/marker"
INVOK init --level repo --route peer
INVOK add --level repo --role architect --model opus
HOME="$FAKEHOME" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$SANDBOX/markerbin:$NODE_DIR" FAKE_HERDR_MARKER="$SANDBOX/marker" node "$H/roster.mjs" create --spawn --mode auto --cwd "$PROJ" >/dev/null 2>&1
check "invariant: create --spawn DOES reach herdrCall on a herdr roster (marker created)" \
  '[ -e "$SANDBOX/marker" ]'
INVOK disband --commit

# herdrCall's definition plus its permitted callers (layout-splits, create --spawn, and now move)
# are the only places `herdrCall(` may appear (spec 0002 §11.3, extended by spec 0005 §11.3 to add
# create --spawn, and by spec 0008 §5.5 to add move — "roster.mjs may start a process and may not
# stop one" also covers relocating one). move's case sits after disband's and resync's in the
# switch, so one contiguous range can't bracket {definition, layout-splits, create,
# queryHerdrTopology, move} without also swallowing disband's/resync's case bodies — summing two
# disjoint windows (definition..disband boundary, and move's own case body) keeps both excluded, so
# a herdrCall( added to either would break the count match below.
PERMITTED=$(( $(awk "/^function herdrCall/,/case \"disband\":/" "$H/roster.mjs" | grep -c "herdrCall(") + $(awk "/case \"move\":/,/default:/" "$H/roster.mjs" | grep -c "herdrCall(") ))
check "invariant (grep): herdrCall( appears only in its definition, layout-splits, create --spawn, and move" \
  '[ "$(grep -c "herdrCall(" "$H/roster.mjs")" -eq "'"$PERMITTED"'" ]'

# disband's case body specifically never calls herdrCall( directly (spec 0002 §11.3, spec 0006 §4:
# disband executes nothing) — an explicit, narrowly-scoped assertion independent of the sum above.
check "invariant (grep): disband's own case body never calls herdrCall( directly" \
  '[ "$(awk "/case \"disband\":/,/case \"resync\":/" "$H/roster.mjs" | grep -c "herdrCall(")" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
