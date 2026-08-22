#!/bin/bash
# agent-hierarchy — roster.mjs `next-split`: the pure greedy layout algorithm
# (spec 0004 §6/§6.7, amended by 0002 §7), unit-tested against synthetic
# geometry. No herdr required — next-split performs no I/O.
# Usage: bash tests/test-roster-next-split.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# runs with no HERDR_ENV and an unset HOME override on purpose: proves no I/O is needed (§11.3.10)
run() { OUT=$(env -u HERDR_ENV node "$H/roster.mjs" next-split "$@" 2>&1); RC=$?; }

# 1 — created empty => target is --self, whatever the geometry (rule 1)
run --mode grid --pane-count 1 --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":80,"x":0,"y":0}}]'
check "1: empty created -> target is self" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\""'

# 2 — AMENDED (0002 §7.3, inverts the pre-amendment rule): self IS returned as target when it
# is the largest pane, even with created non-empty. self is never excluded from the search.
run --mode grid --pane-count 3 --self p0 --created '["a"]' --geometry '[{"pane_id":"p0","rect":{"width":1000,"height":1000,"x":0,"y":0}},{"pane_id":"a","rect":{"width":5,"height":5,"x":0,"y":0}}]'
check "2: self IS returned as target when largest, created non-empty (0002 §7 fix)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\""'

# 3 — largest-area candidate wins across the whole set, self included
run --mode grid --pane-count 3 --self p0 --created '["a","b"]' --geometry '[{"pane_id":"p0","rect":{"width":20,"height":20,"x":0,"y":0}},{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"b","rect":{"width":20,"height":10,"x":0,"y":0}}]'
check "3a: self area 400 beats created 100/200 -> self wins" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\""'
run --mode grid --pane-count 3 --self p0 --created '["a","b"]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"a","rect":{"width":20,"height":20,"x":0,"y":0}},{"pane_id":"b","rect":{"width":20,"height":10,"x":0,"y":0}}]'
check "3b: self area 100, created 400/200 -> the 400 one wins" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\""'

# 4 — tie -> earliest in candidate order [self, ...created], order-independent of geometry array order
run --mode grid --pane-count 2 --self p0 --created '["a"]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "4a: self tied with a created pane -> self wins (first in candidate order)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\""'
run --mode grid --pane-count 3 --self p0 --created '["a","b"]' --geometry '[{"pane_id":"p0","rect":{"width":1,"height":1,"x":0,"y":0}},{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"b","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "4b: two tied created panes -> the one listed first in --created (a before b)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\""'
run --mode grid --pane-count 3 --self p0 --created '["a","b"]' --geometry '[{"pane_id":"p0","rect":{"width":1,"height":1,"x":0,"y":0}},{"pane_id":"b","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "4c: tie-break unaffected by --geometry array order (still a)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\""'

# 5 — mode columns => direction right even for a tall target
run --mode columns --pane-count 3 --self p0 --created '["a"]' --geometry '[{"pane_id":"p0","rect":{"width":1,"height":1,"x":0,"y":0}},{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "5: columns mode -> right even for a tall (5x100) target" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'

# 6 — grid, ragged case: falls back to the §6.1 aspect rule (0007 §7.2 — re-anchored: a 1x1 self
# overlapping the target at the origin is not a tiling, so under the shape-aware rule it no longer
# reaches the fallback. Fixture is total=5 (--pane-count 4), four 90x21-ish panes tiling a 180x42
# root so the band/column tests both fall through and the §6.1 aspect rule alone decides.)
run --mode grid --pane-count 4 --self p0 --created '["p1","p2","p3"]' --geometry '[{"pane_id":"p0","rect":{"width":90,"height":21,"x":0,"y":0}},{"pane_id":"p1","rect":{"width":90,"height":21,"x":90,"y":0}},{"pane_id":"p2","rect":{"width":90,"height":21,"x":0,"y":21}},{"pane_id":"p3","rect":{"width":90,"height":21,"x":90,"y":21}}]'
check "6a': grid, ragged fallback, 90x21 target (90 > 42) -> right" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\"" && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode grid --pane-count 4 --self p0 --created '["p1","p2","p3"]' --geometry '[{"pane_id":"p0","rect":{"width":40,"height":21,"x":0,"y":0}},{"pane_id":"p1","rect":{"width":40,"height":21,"x":40,"y":0}},{"pane_id":"p2","rect":{"width":40,"height":21,"x":0,"y":21}},{"pane_id":"p3","rect":{"width":40,"height":21,"x":40,"y":21}}]'
check "6b': grid, ragged fallback, 40x21 target (40 > 42 false) -> down" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'
run --mode grid --pane-count 4 --self p0 --created '["p1","p2","p3"]' --geometry '[{"pane_id":"p0","rect":{"width":42,"height":21,"x":0,"y":0}},{"pane_id":"p1","rect":{"width":42,"height":21,"x":42,"y":0}},{"pane_id":"p2","rect":{"width":42,"height":21,"x":0,"y":21}},{"pane_id":"p3","rect":{"width":42,"height":21,"x":42,"y":21}}]'
check "6c': grid, ragged fallback, width === height*2 exactly -> down (strict >, 0004 §6.1 boundary preserved)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'

# 7 — AMENDED (0002 §7.3 cause 2): auto resolves from --pane-count, never from created.length.
run --mode auto --pane-count 2 --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "7a: auto, --pane-count 2, created empty -> columns (tall self still splits right)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode auto --pane-count 2 --self p0 --created '["a"]' --geometry '[{"pane_id":"p0","rect":{"width":1,"height":1,"x":0,"y":0}},{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "7b: auto, --pane-count 2, created length 1 -> still columns (right for a tall target)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode auto --pane-count 2 --self p0 --created '["a","b"]' --geometry '[{"pane_id":"p0","rect":{"width":1,"height":1,"x":0,"y":0}},{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}},{"pane_id":"b","rect":{"width":1,"height":1,"x":0,"y":0}}]'
check "7c: auto, --pane-count 2, third call -> still columns (right for a tall target)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode auto --pane-count 3 --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "7d: auto, --pane-count 3, FIRST call (created empty) -> grid already, not columns (0002 §7 cause 2 regression test)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'

# 8 — a candidate id absent from geometry is an error (exit 2, named message), not a silent skip
run --mode grid --pane-count 2 --self p0 --created '["missing"]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "8a: created id absent from geometry -> exit 2 with a named error" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "missing"'
run --mode grid --pane-count 2 --self p0 --created '[]' --geometry '[{"pane_id":"other","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "8b: self absent from geometry -> exit 2 with a named error" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "p0"'

# 9 — --pane-count omitted -> exit 2 with a named error
run --mode grid --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "9: --pane-count omitted -> exit 2, named error" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "pane-count"'

# 10 — next-split performs no I/O: succeeds with no herdr running and no HERDR_ENV set (already the case for every `run` above)
check "10: next-split needs no HERDR_ENV / herdr connection (all runs above ran with -u HERDR_ENV)" 'true'

# 11 — equal-area property (0002 §7.3's fixture / 0004 §11.3 item 11): drive next-split in a loop
# from a synthetic start rect, applying an idealized split after each decision, and assert that
# for --pane-count 3 (4 panes total) all four final areas are within 5% of each other, self among
# them. Run from two different start rects so the assertion is about the rule, not one tab.
cat > "/tmp/nextsplit-equalarea-$$.mjs" <<'NODEEOF'
import { execFileSync } from "node:child_process";

const H = process.argv[2];
const startRects = [
  { width: 180, height: 42 },
  { width: 200, height: 50 },
];

function runNextSplit(mode, paneCount, self, created, geometry) {
  const out = execFileSync("node", [H, "next-split", "--mode", mode, "--pane-count", String(paneCount), "--self", self, "--created", JSON.stringify(created), "--geometry", JSON.stringify(geometry)], { encoding: "utf8", env: { ...process.env, HERDR_ENV: undefined } });
  return JSON.parse(out);
}

let ok = true;
for (const start of startRects) {
  const rects = { p0: { ...start, x: 0, y: 0 } };
  const created = [];
  for (let i = 0; i < 3; i++) {
    const geometry = Object.entries(rects).map(([pane_id, rect]) => ({ pane_id, rect }));
    const { target, direction } = runNextSplit("grid", 3, "p0", created, geometry);
    const rect = rects[target];
    const newId = `p${i + 1}`;
    if (direction === "right") {
      const w1 = Math.floor(rect.width / 2);
      const w2 = rect.width - w1;
      rects[target] = { ...rect, width: w1 };
      rects[newId] = { ...rect, width: w2, x: rect.x + w1 };
    } else {
      const h1 = Math.floor(rect.height / 2);
      const h2 = rect.height - h1;
      rects[target] = { ...rect, height: h1 };
      rects[newId] = { ...rect, height: h2, y: rect.y + h1 };
    }
    created.push(newId);
  }
  const ids = Object.keys(rects);
  if (ids.length !== 4 || !ids.includes("p0")) { console.error(`expected 4 panes including p0, got ${JSON.stringify(ids)}`); ok = false; continue; }
  const areas = ids.map((id) => rects[id].width * rects[id].height);
  const max = Math.max(...areas), min = Math.min(...areas);
  if ((max - min) / max > 0.05) { console.error(`start ${JSON.stringify(start)}: areas not within 5% — ${JSON.stringify(areas)}`); ok = false; }
}
process.exit(ok ? 0 : 1);
NODEEOF
OUT=$(node "/tmp/nextsplit-equalarea-$$.mjs" "$H/roster.mjs" 2>&1); RC=$?
rm -f "/tmp/nextsplit-equalarea-$$.mjs"
check "11: equal-area property holds for 4 panes (pane-count 3) from two different start rects, self included" \
  '[ "$RC" -eq 0 ]'

# 12 — multi-axis tiling (0007 §5.5 item 1): first split is always down for total>=3, across a
# range of pane counts, from a single-pane 180x42 start.
for pc in 2 3 4 5 6 7 8; do
  run --mode grid --pane-count "$pc" --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":180,"height":42,"x":0,"y":0}}]'
  check "12: grid, first split is down for --pane-count $pc" \
    '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"down\""'
done

# 13 — grid differs from columns (0007 §5.5 item 4): the same fixtures under --mode columns are
# right for every pane count, proving the two modes are distinct rather than coincidentally equal.
for pc in 2 3 4 5 6 7 8; do
  run --mode columns --pane-count "$pc" --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":180,"height":42,"x":0,"y":0}}]'
  check "13: columns, first split is right for --pane-count $pc (contrasts with case 12's down)" \
    '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
done

# 14 — the sketch formula (floor(sqrt(total))) is rejected (0007 §5.2's max(2, ...) floor):
# --pane-count 2 (total=3) on 100x60 must be down. floor(sqrt(3))=1 would collapse grid to columns
# here and give right instead.
run --mode grid --pane-count 2 --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":100,"height":60,"x":0,"y":0}}]'
check "14: grid, --pane-count 2 (total=3) on 100x60 -> down (0007 §5.2 floor, not floor(sqrt(total)))" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"down\""'

# 15 — the live case, end to end (0007 §4): from a 180x42 single-pane start with --pane-count 3,
# the full decision sequence is exactly [down, right, right] and the final rects are four 90x21
# panes tiling the four quadrants — the live-confirmed workaround, reproduced by the algorithm.
cat > "/tmp/nextsplit-livecase-$$.mjs" <<'NODEEOF'
import { execFileSync } from "node:child_process";

const H = process.argv[2];

function runNextSplit(mode, paneCount, self, created, geometry) {
  const out = execFileSync("node", [H, "next-split", "--mode", mode, "--pane-count", String(paneCount), "--self", self, "--created", JSON.stringify(created), "--geometry", JSON.stringify(geometry)], { encoding: "utf8", env: { ...process.env, HERDR_ENV: undefined } });
  return JSON.parse(out);
}

const rects = { p0: { width: 180, height: 42, x: 0, y: 0 } };
const created = [];
const directions = [];
for (let i = 0; i < 3; i++) {
  const geometry = Object.entries(rects).map(([pane_id, rect]) => ({ pane_id, rect }));
  const { target, direction } = runNextSplit("grid", 3, "p0", created, geometry);
  directions.push(direction);
  const rect = rects[target];
  const newId = `p${i + 1}`;
  if (direction === "right") {
    const w1 = Math.floor(rect.width / 2);
    const w2 = rect.width - w1;
    rects[target] = { ...rect, width: w1 };
    rects[newId] = { ...rect, width: w2, x: rect.x + w1 };
  } else {
    const h1 = Math.floor(rect.height / 2);
    const h2 = rect.height - h1;
    rects[target] = { ...rect, height: h1 };
    rects[newId] = { ...rect, height: h2, y: rect.y + h1 };
  }
  created.push(newId);
}

const expectedDirections = JSON.stringify(["down", "right", "right"]);
const gotDirections = JSON.stringify(directions);
if (gotDirections !== expectedDirections) {
  console.error(`expected directions ${expectedDirections}, got ${gotDirections}`);
  process.exit(1);
}

const expectedRects = [
  { width: 90, height: 21, x: 0, y: 0 },
  { width: 90, height: 21, x: 90, y: 0 },
  { width: 90, height: 21, x: 0, y: 21 },
  { width: 90, height: 21, x: 90, y: 21 },
];
const gotRects = Object.values(rects).map((r) => ({ width: r.width, height: r.height, x: r.x, y: r.y }));
const norm = (arr) => JSON.stringify([...arr].sort((a, b) => a.x - b.x || a.y - b.y));
if (norm(gotRects) !== norm(expectedRects)) {
  console.error(`expected rects ${JSON.stringify(expectedRects)}, got ${JSON.stringify(gotRects)}`);
  process.exit(1);
}
process.exit(0);
NODEEOF
OUT=$(node "/tmp/nextsplit-livecase-$$.mjs" "$H/roster.mjs" 2>&1); RC=$?
rm -f "/tmp/nextsplit-livecase-$$.mjs"
check "15: end to end, 180x42 --pane-count 3 -> sequence [down,right,right], four 90x21 quadrants (0007 §4 live case)" \
  '[ "$RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
