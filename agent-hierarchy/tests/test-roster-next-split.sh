#!/bin/bash
# agent-hierarchy — roster.mjs `next-split`: the pure greedy layout algorithm
# (spec 0004 §6/§6.7), unit-tested against synthetic geometry. No herdr
# required — next-split performs no I/O.
# Usage: bash tests/test-roster-next-split.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# runs with no HERDR_ENV and an unset HOME override on purpose: proves no I/O is needed (§11.3.9)
run() { OUT=$(env -u HERDR_ENV node "$H/roster.mjs" next-split "$@" 2>&1); RC=$?; }

# 1 — created empty => target is --self, whatever the geometry (rule 1)
run --mode grid --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":80,"x":0,"y":0}}]'
check "1: empty created -> target is self" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"p0\""'

# 2 — self never returned as target once created is non-empty, even when self has the largest area
run --mode grid --self p0 --created '["a"]' --geometry '[{"pane_id":"p0","rect":{"width":1000,"height":1000,"x":0,"y":0}},{"pane_id":"a","rect":{"width":5,"height":5,"x":0,"y":0}}]'
check "2: self is never re-targeted once split once (the reported defect)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\"" && ! echo "$OUT" | grep -q "\"target\": \"p0\""'

# 3 — largest-area member pane wins: areas 100/400/200
run --mode grid --self p0 --created '["a","b","c"]' --geometry '[{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"b","rect":{"width":20,"height":20,"x":0,"y":0}},{"pane_id":"c","rect":{"width":20,"height":10,"x":0,"y":0}}]'
check "3: largest-area pane (400) wins" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"b\""'

# 4 — tie -> earliest in created, order-independent of geometry array order
run --mode grid --self p0 --created '["a","b"]' --geometry '[{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"b","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "4a: tied areas -> earliest-created wins (a before b)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\""'
run --mode grid --self p0 --created '["a","b"]' --geometry '[{"pane_id":"b","rect":{"width":10,"height":10,"x":0,"y":0}},{"pane_id":"a","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "4b: tie-break unaffected by geometry array order (still a)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\""'

# 5 — mode columns => direction right even for a tall target
run --mode columns --self p0 --created '["a"]' --geometry '[{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "5: columns mode -> right even for a tall (5x100) target" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'

# 6 — mode grid: aspect rule, strict > at the boundary
run --mode grid --self p0 --created '["a"]' --geometry '[{"pane_id":"a","rect":{"width":90,"height":42,"x":0,"y":0}}]'
check "6a: grid, 90x42 (90 > 84) -> right" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode grid --self p0 --created '["a"]' --geometry '[{"pane_id":"a","rect":{"width":45,"height":42,"x":0,"y":0}}]'
check "6b: grid, 45x42 (45 > 84 false) -> down" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"down\""'
run --mode grid --self p0 --created '["a"]' --geometry '[{"pane_id":"a","rect":{"width":84,"height":42,"x":0,"y":0}}]'
check "6c: grid, width === height*2 exactly -> down (strict >, boundary is not right)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"down\""'

# 7 — mode auto: columns at created.length 0 or 1, grid at 2+
run --mode auto --self p0 --created '[]' --geometry '[{"pane_id":"p0","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "7a: auto, created.length 0 -> columns (tall self still splits right)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode auto --self p0 --created '["a"]' --geometry '[{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}}]'
check "7b: auto, created.length 1 -> columns (tall target still splits right)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"direction\": \"right\""'
run --mode auto --self p0 --created '["a","b"]' --geometry '[{"pane_id":"a","rect":{"width":5,"height":100,"x":0,"y":0}},{"pane_id":"b","rect":{"width":5,"height":50,"x":0,"y":0}}]'
check "7c: auto, created.length 2 -> grid (tall target now splits down)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"target\": \"a\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'

# 8 — a created id absent from geometry is an error (exit 2, named message), not a silent skip
run --mode grid --self p0 --created '["missing"]' --geometry '[{"pane_id":"p0","rect":{"width":10,"height":10,"x":0,"y":0}}]'
check "8: created id absent from geometry -> exit 2 with a named error" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "missing"'

# 9 — next-split performs no I/O: succeeds with no herdr running and no HERDR_ENV set (already the case for every `run` above)
check "9: next-split needs no HERDR_ENV / herdr connection (all runs above ran with -u HERDR_ENV)" 'true'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
