# Spec 0007 — `grid` mode degenerates to a single row of columns

Status: **final.** Defect observed 2026-08-22 during a live `/agent-roster create
grid` run in `~/git/repos/wrangl` against `ah` 0.34.0 (source `agent-hierarchy` at
the commit holding `0004`/`0002`'s fixes). Algorithm designed 2026-08-22.
Terms: see `agent-hierarchy/CONTEXT.md`.
Related: `docs/specs/0004-roster-layout.md` §6 (the `next-split` algorithm this
defect is about, amended by §8 below); `docs/specs/0002-roster-spawn-defects.md`
§7 (Defect E — a different, already-fixed bug in the same function) and §7.2
(carries a now-stale expectation — see §8.4).

---

## Note on this revision

§1–§4 are the original defect report and are unchanged: they are the evidence
record and should not be edited. §5 was a sketch and is now a concrete
algorithm. §6–§10 are new.

Three findings changed the design away from what §5's sketch proposed. Each is a
**[correction]**, not a confirmation:

1. **§5's `rows = floor(sqrt(paneCount + 1))` is wrong, and an existing shipped
   test proves it.** For 3 total panes it yields 1 row — i.e. `grid` becomes
   indistinguishable from `columns`. `tests/test-roster-create-spawn.sh:308-317`
   asserts precisely the opposite (`--mode grid` on a 100×60 rect with
   `pane_count 2` must split **down** where `columns` would split right), and
   exists to prove `--mode` is honored at all. Implementing §5's formula verbatim
   would not merely fail that assertion — it would destroy what the assertion
   tests. §5.2 replaces it. **This is the single item most likely to be
   "simplified" back to the sketch during implementation. It must not be.**
2. **Only the *direction* rule needs to change; target selection must not be
   touched.** §5 spoke of replacing "`nextSplit()`'s decision logic". Target
   selection (`0004` §6.2 rule 2, greedy largest-area) is not merely innocent
   here — it is what *preserves* the equal-area invariant under any direction
   rule at all (§5.6). Changing it would put `0002` §7's fix at risk for no gain.
3. **§6's "equal-area property must still hold" overstates what `0004`
   guarantees, and the correct statement is what makes the ragged cases legal.**
   `0004`:424-425 scopes it exactly: *"for `pane_count + 1` equal to a power of
   two, every resulting pane has equal area."* With 50/50 splits, equal area for
   5 or 6 panes is arithmetically impossible — every pane area is `root / 2^k`.
   §6 item 2 is restated accordingly in §7.

---

## 1. Summary

`roster.mjs create --spawn --mode grid` on a 3-member roster (4 panes total: self
+ 3 members) produced four panes of equal area, arranged as **one row of four
columns**, not a 2×2 grid. The user's reaction, live: "this isn't a grid, these
are columns, why not a grid?"

This is **not an implementation bug** — the shipped `nextSplit()` matches
`0004` §6.1's aspect rule and §6.4's worked example exactly, split for split. The
defect is in what `0004` §6 actually guarantees: **equal area**, not a 2D
row-and-column tiling. For any terminal wide enough (which is most of them —
180×42, 200×50, the two examples `0004` itself uses), those two properties
diverge, and `grid` mode visibly fails to look like a grid.

## 2. Live trace

Roster: 3 members (architect, implementor, reviewer), route `peer`, transport
`herdr`. Starting pane `w3:p1`, single pane, 180×42 cells. `layout_plan.mode`
was `grid`, `pane_count: 3`.

`roster.mjs create --spawn --mode grid` ran the layout internally and reported
success (`launch_status: "ready"` for all three members, `partial: false`).
Post-hoc `herdr pane layout --current`:

```json
{
  "panes": [
    {"pane_id": "w3:p1", "rect": {"width": 45, "height": 42, "x": 4,  "y": 1}},
    {"pane_id": "w3:pY", "rect": {"width": 45, "height": 42, "x": 49, "y": 1}},
    {"pane_id": "w3:pX", "rect": {"width": 45, "height": 42, "x": 94, "y": 1}},
    {"pane_id": "w3:pZ", "rect": {"width": 45, "height": 42, "x": 139,"y": 1}}
  ],
  "splits": [
    {"direction": "right", "id": "split_0_root"},
    {"direction": "right", "id": "split_1_0"},
    {"direction": "right", "id": "split_2_1"}
  ]
}
```

Four equal 45×42 panes — matches `0004` §6.4's own N=3 row ("four equal 45×42
panes") verbatim. All three splits chose `"right"`, so the result is
geometrically one row of four columns, not two rows of two.

## 3. Root cause

`nextSplit()` (`hooks/roster.mjs:200-216`, unchanged since `0002` §7.3 landed)
picks a direction from a single, stateless test on the *current target pane
only*:

```js
const direction = effectiveMode(mode, paneCount) === "columns"
  || rect.width > rect.height * 2 ? "right" : "down";
```

Walking the live trace against this rule, with `effectiveMode` already `"grid"`
for all three splits (`paneCount=3 > 2`):

| split | target | rect | `width > height*2`? | direction |
|---|---|---|---|---|
| 1 | self | 180×42 | 180 > 84 → yes | right |
| 2 | self (tie, picked first) | 90×42 | 90 > 84 → yes | right |
| 3 | largest remaining (the other 90×42 half) | 90×42 | 90 > 84 → yes | right |

Every intermediate pane stays over the 2:1 cell-aspect threshold until *after*
the third split, so the rule never once returns `"down"` for this pane count.
The heuristic has no memory of which axis has already been split how many
times — it only ever asks "is *this* pane still wide," and for pane counts
that don't happen to cross the threshold partway through, the answer is always
yes.

`0004` §6.4's own table shows this precisely (N=1 through N=3 all `right`; only
N=4's fourth split goes `down`, and only because the *individual* candidate
pane by then measures 45×21, which finally trips the threshold) — the spec's
own worked example documents this exact result without flagging that four
equal-width columns is not what "grid" reads as to a user. Equal area was
verified; visual grid-ness was not.

## 4. What an actual grid looks like, live-confirmed

Splitting the same starting pane by axis instead of by area — `down` first,
then `right` on each resulting half — produces a real 2×2:

```
1. herdr pane split --pane w3:p1 --direction down    → w3:p1 (top, 180×21), w3:p0 (bottom, 180×21)
2. herdr pane split --pane w3:p1 --direction right    → w3:p1 (top-left, 90×21), w3:p11 (top-right, 90×21)
3. herdr pane split --pane w3:p0 --direction right    → w3:p0 (bottom-left, 90×21), w3:p12 (bottom-right, 90×21)
```

Confirmed via `herdr pane layout --current`: four 90×21 panes at
`(4,1) (94,1) (4,22) (94,22)` — two rows, two columns, self among them. This
was applied manually as the workaround for the live Team in `~/git/repos/wrangl`
and the user confirmed it as the expected result ("this is correct!").

**The algorithm in §5 reproduces this sequence exactly** — `↓ → →`, four 90×21
panes — for this pane count and this start rect. That is the design target, not
a coincidence, and §7 asserts it.

---

## 5. The algorithm

### 5.1 Shape of the change

One function changes: `nextSplit()` at `hooks/roster.mjs:200-216`. Within it,
**only the direction expression at `:214`** is replaced. Specifically:

| part of `nextSplit()` | change |
|---|---|
| signature `{ mode, paneCount, self, created, geometry }` | **none** |
| candidate loop `:204-212` (largest area, strict `>`, earliest wins ties) | **none** |
| the absent-from-geometry error `:206` | **none** |
| `effectiveMode()` `:187-190` | **none** |
| direction expression `:214` | replaced by §5.4 |
| purity (no I/O) | **none** — the new rule is still arithmetic over the arguments |

Everything the sketch's §5.1 listed as "must not change" is therefore untouched
by construction, not by care:

- `0004` §6.1's aspect rule survives verbatim, as the §5.4 fallback.
- `columns` mode short-circuits before any new code runs.
- `effectiveMode`'s `paneCount <= 2` branch is not read or written.
- `0002` §7's self-in-the-candidate-pool fix lives entirely in `:204`.
- The `--next`/`--apply` pause contract (`0004` §8.1) is preserved because the
  new rule adds **no state**: the plan constants are re-derived from `paneCount`
  on every call, and `paneCount` is already a required argument. A `--next`
  invocation in a fresh process computes the identical answer. See §5.7.

### 5.2 Plan constants — derived from `paneCount` alone

Let `total = paneCount + 1` (panes on screen when the run finishes, self
included — `0004` §6.1's "total pane count", known before the first split).

```js
const total = paneCount + 1;
const bands = Math.max(total >= 3 ? 2 : 1, 2 ** Math.floor(Math.log2(total) / 2));
const cols  = Math.ceil(total / bands);
```

`bands` is **the largest power of two not exceeding √total, floored at 2 once
there are three or more panes.**

Two deliberate choices, both load-bearing:

- **Power of two, not `floor(sqrt())`.** Splits are 50/50 (`0004` §11.3 item 11
  and every fake in the suite halve with `floor`/remainder). A band count that
  is not a power of two cannot be produced by equal binary subdivision — asking
  for 3 rows yields 4 unequal ones. Restricting `bands` to a power of two makes
  the row structure exactly achievable, which is what lets §5.5 state the row
  count as an invariant rather than an aspiration.
- **The `max(2, …)` floor at `total >= 3`.** This is the §5's-sketch correction
  from the revision note. `2 ** floor(log2(3)/2) = 1`, so without the floor a
  3-pane `grid` is one row — identical to `columns`, and
  `tests/test-roster-create-spawn.sh:308-317` fails. The floor states the thing
  `grid` actually means: **grid mode is at least two rows.** It is a no-op for
  every `total >= 4`.

Resulting shapes:

| `total` | `bands` | `cols` | shape |
|---|---|---|---|
| 1 | 1 | 1 | (never called — `layoutPlan` returns null at `pane_count 0`) |
| 2 | 1 | 2 | one row of two |
| 3 | 2 | 2 | two rows: 2 on top, 1 below |
| 4 | 2 | 2 | 2×2 |
| 5 | 2 | 3 | two rows: 3 and 2 |
| 6 | 2 | 3 | 2×3 |
| 7 | 2 | 4 | two rows: 4 and 3 |
| 8 | 2 | 4 | 2×4 |
| 9–15 | 2 | 5–8 | two rows |
| 16 | 4 | 4 | 4×4 |

### 5.3 The root rect

The region this algorithm owns is the bounding box of **the candidate panes
only** — never the whole workspace. `0004` §6.1 already excludes foreign panes
from the candidate set; this extends the same exclusion to the geometry the
rule measures against, so a stranger's pane in the same tab cannot distort the
target shape.

```js
const cands = [self, ...created].map((id) => byId.get(id));
const rootX = Math.min(...cands.map((r) => r.x));
const rootY = Math.min(...cands.map((r) => r.y));
const rootWidth  = Math.max(...cands.map((r) => r.x + r.width))  - rootX;
const rootHeight = Math.max(...cands.map((r) => r.y + r.height)) - rootY;
```

Before the first split `created` is empty and the box is exactly `self`'s rect,
which is the correct root.

**Stated assumption, not verified by reading:** the candidate panes tile their
bounding box without gaps. This holds for every layout this algorithm itself
produces (it only ever subdivides its own region) and is the same assumption
`0004` §6.2 rule 2's greedy argument already rests on. It could be violated only
by a foreign pane opened *inside* the region between two calls, which would
already break `0004` §6.1. No new exposure.

### 5.4 The direction rule

Replaces `hooks/roster.mjs:214` in full.

```js
if (effectiveMode(mode, paneCount) === "columns") return "right";
if (rootWidth > 0 && rootHeight > 0) {
  if (rect.height * 2 * bands > rootHeight * 3) return "down";   // spans >1.5 bands
  if (rect.width  * 2 * cols  > rootWidth  * 3) return "right";  // spans >1.5 columns
}
return rect.width > rect.height * 2 ? "right" : "down";          // 0004 §6.1, verbatim
```

Read in order:

1. **`columns` short-circuits.** Unchanged behaviour, unchanged code path.
2. **Bands first.** If the target is taller than one-and-a-half band heights, it
   still spans more than one target row; split it `down`. Bands-first is a
   convention, not an aspect decision — see §5.8.
3. **Then columns.** If the target is wider than one-and-a-half column widths,
   it still spans more than one target column; split it `right`.
4. **Otherwise `0004` §6.1's aspect rule, unchanged**, for a target that already
   fits one grid cell but must still be subdivided. This is the ragged case: it
   is reached whenever `cols` is not a power of two (§5.6 traces `total = 5`
   hitting it at split 4 and returning the right answer).

**Why `1.5`, and why the integer form.** The meaningful values of
`height / bandHeight` are 1, 2, 4 — halving only ever produces powers of two.
`1.5` is the midpoint between "one band" and "two bands", the furthest possible
point from both, so ±1 cell of `floor`/remainder drift cannot flip the decision
for any band height of 3 cells or more. The comparison is written as integer
arithmetic (`h * 2 * bands > rootHeight * 3`) rather than
`h > 1.5 * rootHeight / bands` so there is no float rounding at the boundary at
all. **Do not "simplify" it back to a division.**

The `rootWidth > 0 && rootHeight > 0` guard is a divide-by-zero equivalent: a
degenerate geometry falls through to the aspect rule rather than producing
`NaN`-driven directions.

### 5.5 What this guarantees

For `total >= 3`, all provable from §5.2/§5.4 rather than observed:

1. **The first split is always `down`.** `bands >= 2`, so the threshold is at
   most `0.75 × rootHeight`, and the first target's height *is* `rootHeight`.
2. **At least one split is `right`.** `cols >= 2` for every `total >= 3`, and
   after the down splits every pane is one band tall, so the band test can no
   longer fire while splits remain.
3. **The final row count is exactly `bands`.** A pane can only be split `down`
   while it is taller than 1.5 band heights; once every pane is one band tall
   nothing re-triggers it, and greedy largest-area does the down splits first
   because full-width panes are the largest ones.
4. **`grid` is never identical to `columns` for `total >= 3`** — a direct
   consequence of (1). This is the property
   `tests/test-roster-create-spawn.sh:308-317` exists to protect.

(1)+(2) together are exactly `0007` §6 item 1's live check, promoted from an
empirical assertion to a theorem. The test still runs; it just can no longer
pass by luck.

### 5.6 Equal area is preserved — and why that is free

`0004`:424-425 states the invariant precisely: *"for `pane_count + 1` equal to a
power of two, every resulting pane has equal area regardless of the starting
rect."*

That invariant depends only on **target selection**, never on direction. Each
split halves the chosen pane's area, so a greedy always-split-the-largest rule
keeps every pane's area in `{A/2^m, A/2^(m+1)}` at all times, and after `2^k - 1`
splits every pane is at `A/2^k`. **Direction changes shape, not area.** Since
§5.1 leaves target selection untouched, the invariant is preserved by
construction — and `tests/test-roster-next-split.sh:95-146` and
`tests/test-roster-layout-splits.sh:110-117` both continue to pass without
modification. §7.1 records that as a verified expectation, not a hope.

For `total` a power of two the shape is also exact: `bands` is a power of two,
so `cols = total / bands` is too, and the grid divides evenly with no ragged
row.

**Worked trace, `total = 5` (the ragged case), 180×42:** `bands = 2`, `cols = 3`,
band height 21, column width 60.

| split | candidates | target | test that fires | dir | result |
|---|---|---|---|---|---|
| 1 | p0 180×42 | p0 | `42·2·2=168 > 42·3=126` | ↓ | p0 180×21 @(0,0), p1 180×21 @(0,21) |
| 2 | tie 3780/3780 | p0 | band: `21·4=84 > 126` false; col: `180·2·3=1080 > 180·3=540` | → | p0 90×21, p2 90×21 @(90,0) |
| 3 | p1 largest | p1 | col: `1080 > 540` | → | p1 90×21, p3 90×21 @(90,21) |
| 4 | four-way tie | p0 | band false; col: `90·2·3=540 > 540` **false** → **fallback**: `90 > 42` | → | p0 45×21, p4 45×21 |

Final: top row 45, 45, 90; bottom row 90, 90. Two rows, ragged — a grid with an
uneven row, which is what `total = 5` permits. Areas are *not* equal, and the
invariant correctly does not claim they are.

### 5.7 Manual mode stays stateless

`layout-splits --next` (`hooks/roster.mjs:538-553`) and the `next-split`
subcommand (`:497-506`) each run in a fresh process and pass `--created` and
`--geometry` on the command line. The new rule reads **no state that is not
already an argument**: `bands`/`cols` come from `paneCount` (already required,
already validated at `:501`), and the root rect comes from `geometry` restricted
to `[self, ...created]`. A `--next` call therefore returns the same decision the
in-process loop would have made at the same point, which is the whole of the
`0004` §8.1 pause contract. **No plan object is persisted, and none may be
added** — persisting one would reintroduce exactly the divergence between manual
and automatic mode that `0004` §6.7's single-implementation rule exists to
prevent.

### 5.8 Why the axis order is a convention, not a computation

§5's sketch asked for the axis order (bands-first vs columns-first) to be chosen
by applying `0004` §6.1's aspect rule once at planning time. **That computation
is unnecessary, and this spec drops it.**

When `bands` and `cols` are both powers of two, the two orders produce
*identical final rects* — `rootWidth/cols × rootHeight/bands` either way. The
order is unobservable in the result. It is observable only in the ragged case,
where it decides whether the short row is a row or the short column is a column.
Bands-first is chosen there because a grid with a short **bottom row** is the
familiar degradation (it is what every photo grid and every tiling WM does), and
because it makes the §5.5 guarantees stateable in one direction.

Applying the aspect rule at planning time would also actively reintroduce the
defect: on 180×42 with `total = 4`, `180 > 84` is true, so it would choose
columns-first, and the first split would be `right` — the exact behaviour §3
diagnoses. The aspect rule is a good test of *a rect*; it is not a good test of
*a plan*, and §5's sketch put it in the one place where it fails.

---

## 6. Files to change

| file | change |
|---|---|
| `hooks/roster.mjs` | `nextSplit()` `:200-216` — insert §5.2/§5.3 constants, replace the `:214` direction expression with §5.4. Nothing else in the file. |
| `docs/specs/0004-roster-layout.md` | §8 below — applied as part of this spec. |
| `docs/specs/0002-roster-spawn-defects.md` | §8.4 — **flagged, not applied.** Orchestrator's call. |
| `tests/test-roster-next-split.sh` | §7.2 |
| `tests/test-roster-layout-splits.sh` | §7.3 |
| `tests/test-roster-create-spawn.sh` | §7.4 — no change expected; listed because it is the assertion that constrains §5.2. |

`hooks/roster.mjs:237-260` (`runLayoutLoop`), `:167-184` (`layoutPlan`),
`:187-190` (`effectiveMode`), and the `next-split`/`layout-splits` argument
handling are **not** touched. If a diff shows them changed, that is a defect.

---

## 7. Verification

Restating `0007` §6's four items against what was actually found, plus the
per-assertion reconciliation the Implementor needs so nothing fails as a
surprise.

### 7.1 The four required checks

1. **Multi-axis tiling.** For `paneCount >= 2` (`total >= 3`) in `grid` mode, the
   split sequence contains at least one `down` and at least one `right`. Now
   provable (§5.5 items 1–2), so assert it as a unit property across a range of
   pane counts rather than only live. **Live confirmation still required** on a
   180×42 and a 200×50 tab that a 3-member `grid` create produces two rows of
   two — see §9.
2. **Equal area.** Restated to `0004`:424-425's actual scope: *for
   `pane_count + 1` a power of two, all panes equal area.* Preserved by
   construction (§5.6); both existing fixtures must pass **unmodified**. If
   either needs editing to pass, the change went further than §5.1 permits —
   stop and report it rather than adjusting the fixture.
3. **`0004` §6.4's table matches the code.** Applied in §8.2.
4. **1- and 2-member creates still resolve to `columns`.** `effectiveMode` is
   untouched; `tests/test-roster-next-split.sh:65-74` (cases 7a/7b/7c) covers it
   and must pass unmodified.

### 7.2 `tests/test-roster-next-split.sh` — assertion by assertion

Traced against the new rule. **Only one assertion inverts.**

| case | line | verdict |
|---|---|---|
| 1 (empty created → self) | 20-22 | passes unchanged — target-only |
| 2 (self is target when largest) | 26-28 | passes unchanged — target-only, `0002` §7 guard intact |
| 3a, 3b (largest wins) | 31-36 | passes unchanged |
| 4a, 4b, 4c (tie → earliest) | 39-47 | passes unchanged |
| 5 (columns → right for a tall target) | 50-52 | passes unchanged — short-circuit |
| **6a (grid, 90×42 → right)** | **55-57** | **INVERTS.** Root box over `p0` 1×1 and `a` 90×42 is 90×42; `bands=2`; `42·4=168 > 42·3=126` ⇒ **down**. Must be rewritten — see below. |
| 6b (grid, 45×42 → down) | 58-60 | still passes, **but for a different reason** — the band rule, not the aspect rule it names |
| 6c (grid, 84×42 boundary → down) | 61-63 | same: still passes, no longer testing the aspect boundary |
| 7a, 7b, 7c (auto/`pane-count 2` → columns) | 66-74 | passes unchanged |
| 7d (auto/`pane-count 3` first call → down) | 75-77 | passes unchanged — `bands=2`, `100·4 > 100·3` ⇒ down |
| 8a, 8b (absent from geometry → exit 2) | 80-85 | passes unchanged |
| 9 (`--pane-count` omitted → exit 2) | 88-90 | passes unchanged |
| 10 (no I/O) | 93 | passes unchanged |
| **11 (equal-area, two start rects)** | **95-146** | **passes unchanged** — §5.6. Do not edit this fixture. |

**6a/6b/6c must be re-anchored, not deleted.** They are the only coverage of
`0004` §6.1's aspect rule, and that rule still exists — as the §5.4 fallback. But
their current geometry (a 1×1 `self` overlapping the target at the origin) is not
a tiling, so under a shape-aware rule it no longer means what it says. Replace
them with a fixture that actually reaches the fallback: `total = 5`
(`--pane-count 4`), root 180×42, four 90×21 panes at `(0,0) (90,0) (0,21)
(90,21)`, `--self p0 --created '["p1","p2","p3"]'`. There `cols = 3`, the column
test is `90·2·3 = 540 > 540` — false — and the aspect rule decides. Assert:

- **6a′** — that fixture ⇒ `target p0`, `direction right` (fallback fired,
  `90 > 42`).
- **6b′** — the same fixture with the four panes at 40×21 ⇒ `down`
  (`40 > 42` false), proving the fallback still returns both values.
- **6c′** — panes at 42×21, the exact `width === height*2` boundary ⇒ `down`,
  preserving `0004` §6.1's strict `>`.

Rename them so the file does not claim to test a per-split aspect rule that no
longer exists: *"grid, ragged case: falls back to the §6.1 aspect rule"*.

New cases to add:

- **12 — first split is `down` for every `total >= 3`.** Loop `--pane-count` 2
  through 8 with a single-pane 180×42 geometry; assert `down` each time. This is
  §5.5 item 1 and the direct regression test for this defect.
- **13 — `grid` differs from `columns`.** Same fixture, `--mode columns` ⇒
  `right` for every one of those pane counts. The pair is what proves the modes
  are distinct.
- **14 — the sketch formula is rejected.** `--pane-count 2 --mode grid` (i.e.
  `total = 3`) on 100×60 ⇒ `down`. `floor(sqrt(3)) = 1` would give `right`. Cite
  §5.2 at the assertion site so the next reader knows why the floor exists.
- **15 — the live case, end to end.** Drive the loop the way case 11 does, from
  180×42 with `--pane-count 3`, and assert the direction sequence is exactly
  `["down","right","right"]` and the final rects are four 90×21 at
  `(0,0) (90,0) (0,21) (90,21)` — §4's live-confirmed workaround, reproduced by
  the algorithm.

### 7.3 `tests/test-roster-layout-splits.sh`

| assertion | line | verdict |
|---|---|---|
| 1 (happy path, 3 panes, 3 splits) | 104-108 | passes unchanged |
| 2 (end-to-end equal area, 180×42 and 200×50) | 110-117 | **passes unchanged** — traced: 180×42 ⇒ four 90×21; 200×50 ⇒ four 100×25. Do not edit. |
| 3 (self participates in >1 split) | 119-123 | **passes unchanged** — the new sequence targets `p0` at splits 1 and 2, so `selfSplits = 2 > 1`. The `0002` Defect E end-to-end guard survives. |
| 4-12 (partial, exits, timeout, `--next`, `--apply`, …) | 125+ | untouched — no direction dependence |

Add one assertion: after `--pane-count 3 --mode grid` at 180×42, the fake's final
state has **exactly two distinct `y` values** across its four panes. That is the
end-to-end form of "it is a grid", and it is the assertion whose absence let this
defect ship — every existing check measured area, none measured arrangement.

### 7.4 `tests/test-roster-create-spawn.sh`

**No change expected.** Assertion 15 (`:308-317`) — roster stored as `columns`,
CLI `--mode grid` on 100×60, first split must be `down` — passes **only because
of §5.2's `max(2, …)` floor**. Re-run it deliberately and read the result: it is
the tripwire for the sketch formula, and if it fails, §5.2 was implemented as
`floor(sqrt())`.

Assertions 6, 7, 8, 10, 11, 12, 13, 14, 16 are launch/retry/transport behaviour
from `0005` and have no direction dependence.

---

## 8. Amendments to `0004`

### 8.1 §6.3 — the `grid` selector

`0004` §6.3's bullet currently reads: *"`grid` — direction is chosen per the §6.1
visual-aspect rule on the *target* pane."* That sentence is the defect, stated as
the specification. Amend it to name the shape rule as primary and §6.1 as the
fallback, and cross-reference `0007` §5.4. `columns` and `auto`'s bullets are
untouched, as is §6.3's closing "There are only two algorithms."

### 8.2 §6.4 — the worked tables

The `grid` tables are recomputed. Both are worked examples, not invariants —
§6.4's existing paragraph saying so still stands and still governs.

**`grid` at 180×42 cells.** `total = N+1`; `bands`/`cols` per `0007` §5.2.

| N | total | bands×cols | splits, in order | resulting panes |
|---|---|---|---|---|
| 1 | 2 | 1×2 | P0→A | P0 90×42, A 90×42 |
| 2 | 3 | 2×2 | P0↓A, then P0→B | P0 90×21, B 90×21 (top); A 180×21 (bottom) |
| 3 | 4 | 2×2 | P0↓A, P0→B, A→C | **four equal 90×21 panes — two rows of two**, P0 among them |
| 4 | 5 | 2×3 | …then P0→D (four-way tie ⇒ P0; ragged, §6.1 fallback fires) | top 45, 45, 90; bottom 90, 90 — all ×21 |
| 5 | 6 | 2×3 | …then A→E | top 45, 45, 90; bottom 45, 45, 90 — all ×21 |

**`grid` at 200×50 cells**, the same rules on a differently-shaped tab:

| N | total | bands×cols | splits, in order | resulting panes |
|---|---|---|---|---|
| 1 | 2 | 1×2 | P0→A | P0 100×50, A 100×50 |
| 2 | 3 | 2×2 | P0↓A, then P0→B | P0 100×25, B 100×25 (top); A 200×25 (bottom) |
| 3 | 4 | 2×2 | P0↓A, P0→B, A→C | **four equal 100×25 quadrants** |

Two notes belong with the tables:

- **The N=3 rows are now identical in shape across both tabs** — two rows of two,
  differing only in cell dimensions. Under the old rule they diverged (180×42
  gave one row of four, 200×50 gave quadrants) purely because of the terminal's
  aspect. §6.4's warning that "the same rules split *right* at step 2 on a 180×42
  tab and *down* on a 200×50 one" described the old rule and no longer applies to
  `grid`; the shape is now a function of `pane_count`, not of the tab.
- **§6.4's existing prose at `:415-416`** — *"The N=3 row is exactly the
  arrangement `0002` §7.2 describes as the expected one — P0 split down first,
  then each half split again"* — was **not true of the table it sat under** (that
  table's 200×50 N=3 sequence was `→ ↓ ↓`, P0 split *right* first). It is now
  literally true of both tables. Keep the sentence; it finally matches.

The `columns` table is unchanged — `columns` mode is untouched.

### 8.3 §6.4's invariant paragraph, and §11.3

`0004`:424-425's invariant (*"for `pane_count + 1` equal to a power of two, every
resulting pane has equal area regardless of the starting rect"*) is **unchanged
and still holds** — `0007` §5.6 proves it survives, because it never depended on
direction. Extend the paragraph with the new invariant rather than replacing it:

> Also invariant, and asserted alongside it: for `pane_count + 1 >= 3` in `grid`
> mode the sequence contains at least one `down` split and at least one `right`
> split, and the final layout has exactly `bands` rows (`0007` §5.5).

§11.3 gains the corresponding items; §11.3's existing item 11 (the equal-area
fixture) is unchanged. §6.7's code block is updated to match `0007` §5.4, and
§6.7's four "points the Implementor must not smooth over" all still stand — none
of them concerns direction.

### 8.4 `0002` §7.2 — flagged, not applied

**This is outside the amendment scope I was given, and I have not edited
`0002`.** Recording it because it is a live inconsistency and the Orchestrator
should decide.

`0002` §7.2 (`:490`) reads: *"On a 180×42 tab the same rules give four equal
45×42 columns."* That is the exact arrangement this spec was filed against,
sitting in a shipped spec as the **expected** result. After this change the
sequence gives four 90×21 panes in two rows.

Its next sentence — *"Equal *area* is the invariant; a specific split sequence is
not"* — remains true and is in fact the clause that licenses this change. Suggested
replacement for the stale sentence only, leaving the rest of §7.2 intact:

> On a 180×42 tab the same rules give four equal panes at 90×21, two rows of two
> (`0007` §5 recomputed the sequence; `0002`'s original text here predicted four
> 45×42 columns, which is the arrangement `0007` was filed against).

---

## 9. NEEDS-EVIDENCE

One item. Everything else in this spec is settled by reading or by arithmetic.

**Item 1 — live confirmation on a real `herdr` tab.** `0007` §6 item 1 asks for
it and it has not been run; the traces above are computed against the halving
model the fakes implement, not against `herdr`.

Run, after implementation:

1. `roster.mjs create --spawn --mode grid` with a 3-member roster on a 180×42 tab.
2. The same on a 200×50 tab.
3. `herdr pane layout --current` after each.

What each outcome decides:

- **Four panes at two distinct `y` values, two per row** ⇒ confirmed; close the
  item.
- **Four panes in one row** ⇒ the shape rule is not reaching the live path.
  Check that `--mode` survives to `nextSplit` (assertion 15's concern) before
  suspecting §5.4.
- **Panes at unexpected sizes but the right arrangement** ⇒ `herdr pane split`
  does not halve exactly. That would not invalidate §5.4 (the 1.5 threshold has
  ±0.5-band tolerance) but it *would* invalidate the equal-area invariant, which
  is `0004`'s, not this spec's — report it as a separate finding against `0004`.

This is verification of a designed result, not an input to the design.
Implementation may proceed on everything in this spec before it is answered.

---

## 10. Confidence and escalation

**High** on the mechanism, on §5.5's guarantees, and on §5.6's equal-area
argument — all three are arithmetic over code I read, not judgement.

**High** on the test reconciliation in §7: I traced every existing assertion in
`test-roster-next-split.sh` and `test-roster-layout-splits.sh` individually
against the new rule rather than sampling. Exactly one inverts (6a), two pass for
a changed reason (6b/6c), and the two equal-area fixtures pass untouched.

**Medium-high** on §5.2's shape table beyond `total = 8`. The formula is
principled and the guarantees hold for any `total`, but nobody has looked at a
9-pane or 16-pane layout on a real terminal, and "two rows of five" may read
worse than "three rows" to a user even though three equal rows are not
constructible from 50/50 splits. This is a taste question, not a correctness one,
and it is not worth resolving until someone runs a Team that large.

**No Ultra-Advisor escalation.** Recording the reasons rather than asserting the
conclusion: the blast radius is one pure function with no I/O, no persisted
format, and no security surface; the change is a strict subset of what `0007` §5
already scoped; the equal-area invariant is preserved by construction rather than
by testing; and a live-confirmed manual workaround exists (§4) if it regresses.
`0007` §7's own read was Medium only because the algorithm was undesigned — that
is now resolved.

**Two things for the Orchestrator to decide, not me:**

1. **§8.4** — whether to amend `0002` §7.2's stale sentence. I did not, because
   the amendment scope I was given named `0004` only.
2. **`total = 3` is now two rows** (`grid` with 2 members: two panes on top, one
   full-width below). This only occurs on an *explicit* `--mode grid`, since
   `auto` routes `pane_count <= 2` to `columns`. It is a deliberate consequence
   of §5.2's floor and of what `grid` means, but it is a visible behaviour change
   for anyone who asked for `grid` with two members and got columns. Worth one
   line in the skill's mode description if it surprises anyone.

**One tripwire.** If `grid` ever needs to honour a user-specified row count, an
aspect preference, or a non-halving split ratio, §5.2's power-of-two restriction
stops being an implementation detail and becomes a constraint on the feature.
That is a different design and should come back as a new spec, not as a
relaxation of §5.2.
