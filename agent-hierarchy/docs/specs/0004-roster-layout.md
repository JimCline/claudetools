# Spec 0004 — `/agent-roster create`: real pane layout instead of N serial `--current` splits

Status: **ready for implementation.** Herdr CLI evidence gathered live 2026-08-22; all design questions
resolved. The two remaining §9 items are verification-phase evidence and a deferred follow-up, neither
blocking.

> **Amended 2026-08-22 (post-ship).** Three amendments, all driven by
> `docs/specs/0002-roster-spawn-defects.md` and all confirmed by the user:
>
> 1. **§6.2 rule 1 — "P0 is split at most once, ever" — is reversed.** `0002` §7 showed that freezing
>    the orchestrator's pane after its first split produces a visibly unbalanced screen (50% / 25% /
>    12.5% / 12.5% for a 3-member Team instead of four equal panes). The orchestrator's pane is meant to
>    be an equal-footing participant at every step, not a leftover the algorithm works around. §6.2,
>    §6.3, §6.4, §6.6, §6.7, §7.1, §9, §11 and §12 are amended; each amended point says so inline.
>    `0002` §7 is the live evidence for this reversal and defers the rule itself to this section — the
>    rule lives here, not there.
> 2. **§12 item 5 — "`roster.mjs` spawns nothing" — is scoped down, not deleted.** One subcommand,
>    `layout-splits`, may now execute `herdr pane layout` and `herdr pane split` directly. The new
>    boundary, and what is still guaranteed, is written out in full at §12 item 5. Designed in
>    `0002` §5.3.
> 3. **From `0002` §6 (Defect D):** the herdr `launch` command must now carry `--name <derived-name>`
>    for the Claude session. §11.1 item 7 and §12 item 6 previously asserted the opposite and are
>    corrected below.

Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Team, Orchestrator)
Related: `docs/specs/0001-agent-roster.md` §6 step 4 (the never-implemented "split evenly across
available panes/windows"); `docs/specs/0003-roster-create-perf.md` §11.1, which names this work as
`0004` and states the layout phase it introduced is "the structural prerequisite" for it;
`docs/specs/0002-roster-spawn-defects.md` §5–§7 (defects found by running the shipped implementation).

## 1. Goal

Stop `roster.mjs` from prescribing a fixed split topology, and let the orchestrating session compute a
real layout from live pane geometry — so three new agents land in a quadrant-ish arrangement rather
than three slivers carved serially off the orchestrator's own pane.

Three things follow:

- **A team-wide layout preference** (`roster.layout`: `auto` | `columns` | `grid`) persisted in the
  roster next to `roster.route`, asked once at `init`, and **re-confirmed at every `create`**.
- **A new plan-level `layout_plan` object** for the herdr transport, replacing the per-member
  hardcoded split command. Layout stops being a per-member field because it stopped being a per-member
  concern the moment it stopped being "split `--current`, again".
- **An unambiguous split algorithm** (§6), implemented as a **pure, testable function** in
  `roster.mjs` and exposed as `roster.mjs next-split` — not as prose the orchestrator improvises from.
  An untested layout algorithm living only in SKILL.md is exactly how the current hardcoded string
  survived undetected.

## 2. Current state — evidence

### 2.1 The defect

`hooks/roster.mjs:129-154`, herdr branch, as it stands after 0003:

```js
  if (transport === "herdr") return {
    transport,
    layout: [`herdr pane split --current --direction right --cwd "${cwd}" --no-focus`],
    launch: [`herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`],
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
```

Every member gets the identical string. `--current` is the *orchestrator's* pane in every case, and
`--direction right` never varies. N members therefore halve the orchestrator's pane N times: at N=5 it
is 1/32 of its original width. There is no `herdr pane layout` inspection anywhere in the file.

### 2.2 The herdr skill already forbids this

`/Users/jimcline/.claude/skills/herdr/SKILL.md`, verbatim:

> Honor a direction requested by the user. Otherwise inspect the caller pane:
>
>     herdr pane layout --pane "$HERDR_PANE_ID"
>
> Split a wide pane to the right and a narrow or tall pane down. **Avoid repeated same-direction splits
> that create unusably narrow columns or short rows.** Keep the user's focus in the calling pane and
> explicitly preserve the caller's working directory:
>
>     herdr pane split --current --direction right --cwd "$PWD" --no-focus
>
> Replace `right` with `down` when appropriate. Read the new pane ID from `.result.pane.pane_id`.

Three obligations fall out and all three are currently unmet: honour a user-requested direction,
inspect geometry before choosing, and don't repeat one direction.

### 2.3 Live herdr CLI evidence (gathered 2026-08-22 in a real `HERDR_ENV=1` pane)

**`herdr pane split` accepts an explicit target.** Live usage string:

```
herdr pane split [<pane_id>|--pane ID|--current] --direction right|down
                 [--ratio FLOAT] [--cwd PATH] [--env KEY=VALUE]
                 [--right-click herdr|pane] [--focus] [--no-focus]
```

So §6's greedy targeting can address the chosen pane directly. No focus-then-split dance and no
chain-split fallback are needed; both are removed from this spec.

**`herdr pane layout` reports cell geometry, and returns the whole workspace** even when queried
against a single pane. Live response, recorded verbatim:

```json
{"id":"cli:pane:layout","result":{"layout":{
  "area":{"height":42,"width":180,"x":4,"y":1},
  "focused_pane_id":"w2:p1",
  "panes":[
    {"focused":true, "pane_id":"w2:p1","rect":{"height":28,"width":90,"x":4,"y":1}},
    {"focused":false,"pane_id":"w2:p5","rect":{"height":14,"width":90,"x":4,"y":29}},
    {"focused":false,"pane_id":"w2:p3","rect":{"height":42,"width":45,"x":94,"y":1}},
    {"focused":false,"pane_id":"w2:p4","rect":{"height":42,"width":45,"x":139,"y":1}}],
  "splits":[ /* per-split direction/ratio/rect — not used by this spec, see below */ ],
  "tab_id":"w2:t1","workspace_id":"w2","zoomed":false},
  "type":"pane_layout"}}
```

180 columns × 42 rows is unambiguously **cells**, not pixels. This confirms §6.1's aspect rule as
written — `width > height × 2` — rather than inverting it.

Two consequences the Implementor needs:

- **The parse path for geometry is `.result.layout.panes[]`**, each element carrying `pane_id` and
  `rect: {width, height, x, y}`. This is a *different* path from `pane split`'s
  `.result.pane.pane_id`; do not conflate them.
- **Use `panes[]`, not `splits[]`.** `panes[]` is all §6 needs, and the recorded `splits[]` sample
  contained a malformed key (`"x=94"` where `"x":94` was meant) in transcription. Depending only on
  `panes[]` keeps the parse narrow and avoids inheriting that ambiguity.

Because the response is whole-workspace, **the orchestrator's own pane is always present in the
geometry** — which is what makes the amended §6.2 rule 1 implementable without any extra call.

One `herdr pane layout` call per iteration therefore yields everything needed to pick the next target.

### 2.4 What `roster.mjs` can and cannot know without asking

`roster.mjs` has no *ambient* knowledge of the screen. It knows the member count and the configured
mode; it does not know pane ids, pane sizes, or how many panes exist. Any layout it prescribes
*unprompted* is therefore a guess, which is exactly how the current hardcoded string came to exist.

Under the amended §12 item 5 it may now **ask** — `layout-splits` calls `herdr pane layout` itself
rather than emitting a string for someone else to run. What has not changed is that a layout decision
must be made from observed geometry, never from a static assumption.

### 2.5 Where `roster.layout` has to slot in

- `hooks/lib-roster.mjs:21` — `export const ROSTER_ROUTE_VALUES = ["peer", "subagent"];`
- `hooks/lib-roster.mjs` `validateRosterBlock(roster)` — makes `roster.route` **required**:
  `if (!ROSTER_ROUTE_VALUES.includes(roster.route)) errors.push(...)`.
- `hooks/lib-config.mjs` `resolveRoster()` (298-321) returns `{ level, route, members, path }`,
  passing `r.route` straight through with no defaulting.
- `hooks/lib-roster.mjs` contains **no** occurrence of the string `layout` today.
- `hooks/roster.mjs` `create` `--plan` emits `out({ level, path, transport, members: plan })` at `:278`.
- `skills/agent-roster/SKILL.md` headings, in order: `# agent-roster`, `## Levels`,
  `## Command surface`, `## /agent-roster bare, or show`, `## init`, `## add / edit / remove`,
  `## Create`, `## disband`, `## Check-in registry (team.json)`.
- `tests/test-roster-spawn.sh:103-104` asserts the herdr layout string contains
  `pane split --current --direction right` and `--no-focus` — this assertion **must be replaced**, it
  encodes the defect.

## 3. Design decision — layout is team-level and computed from live geometry, for herdr only

### 3.1 Per transport

| transport | layout in scope? | why |
|---|---|---|
| **herdr** | **yes** | Panes are spatial subdivisions of a finite screen. Splitting is zero-sum; direction and target matter. |
| **tmux** | **no** | `tmux new-window` creates a whole new window, not a spatial split. Nothing is subdivided, nothing gets narrower, and there is no quadrant problem to solve. Grid/columns are meaningless here. **tmux keeps 0003's per-member `layout`/`target_from: 0` shape byte-for-byte.** |
| **terminal** | **no** | `layout: []` today; a backgrounded process has no pane at all. **Unchanged, confirmed.** |

This is a deliberate, stated asymmetry, not an oversight. `layout_plan` is `null` for tmux and terminal.

### 3.2 The new contract for herdr

`roster.mjs` stops emitting a per-member herdr layout command. Instead:

- each herdr member gets `layout: []`, `target_from: null`;
- the plan gains one **top-level** `layout_plan` object carrying the mode, the member count, the
  *templates*, and the two JSON parse paths;
- the orchestrating session runs **one** `roster.mjs layout-splits` call, which performs the §6.6
  procedure internally (§12 item 5, amended);
- phase 3b is **unchanged** — the orchestrator substitutes each id for `<TARGET>` in that member's
  `launch`, exactly as 0003 specifies.

`target_placeholder` stays `"<TARGET>"` for herdr. `target_source` stays on the member as the parse
recipe. Only `target_from` becomes `null`, and it acquires one new documented meaning:

> `target_from: null` **with** a non-null `target_placeholder` means: the target id does not come from
> this member's `layout` array — it comes from the plan-level layout phase. `target_from: null`
> **with** a null `target_placeholder` (terminal) means there is no target at all.

`layout_plan`'s command templates remain in the plan even though `layout-splits` now runs the loop:
they document the contract, they are what §11.1 asserts against without a transport, and they are the
fallback recipe if `layout-splits` is unavailable (`0002` §5.2). They are **not** a second supported
execution path for the skill — see §7.1.

## 4. Required change A — `roster.layout` in the roster schema

### 4.1 Schema

```jsonc
"roster": {
  "route": "peer",        // existing, required
  "layout": "auto",       // NEW, OPTIONAL, default "auto"; one of "auto" | "columns" | "grid"
  "members": [ /* … */ ]
}
```

**`roster.layout` is optional, unlike `roster.route`.** An existing roster written before this change
has no `layout` key and must stay valid; it resolves to `"auto"`. Do not copy `route`'s
required-ness — copy only its validation shape.

### 4.2 `hooks/lib-roster.mjs`

Add beside `ROSTER_ROUTE_VALUES` at `:21`:

```js
export const ROSTER_LAYOUT_VALUES = ["auto", "columns", "grid"];
```

In `validateRosterBlock`, after the existing `roster.route` check, add the **optional-field** form —
note it mirrors `validateMember`'s optional-field style (`!== undefined && !== null`), not
`validateRosterBlock`'s required-field style:

```js
if (roster.layout !== undefined && roster.layout !== null && !ROSTER_LAYOUT_VALUES.includes(roster.layout)) {
  errors.push(`roster.layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(roster.layout)}`);
}
```

`validateMember` is **not** touched by *this* spec. (`0002` §12.1 adds an `auto_mode` check to it; that
is a separate change, and it does not add a per-member layout.) Layout is team-wide only; there is no
per-member layout override, and adding one would be meaningless — a member does not own a split.

### 4.3 `hooks/lib-config.mjs`

`resolveRoster()` (298-321) currently returns `{ level, route, members, path }`. Add `layout`,
defaulted at resolve time:

```js
return { level, route: r.route, layout: r.layout || "auto", members: /* … */, path };
```

This is the only place the default is applied. Do not also default it in `roster.mjs` — one default
site, per 0001's "do not invent a second default table".

### 4.4 `hooks/roster.mjs` — CLI surface

- `init` accepts `--layout <mode>`, validated against `ROSTER_LAYOUT_VALUES`, written into the
  roster block. Omitted ⇒ key omitted ⇒ resolves to `auto`.
- **New subcommand** `layout`:
  ```
  roster.mjs layout [--level <L>] [--layout <mode>]
  ```
  With `--layout`, writes that value into the given level's roster block and re-validates. Without it,
  reports the resolved value and which level it came from. `--level` defaults via the existing
  `targetLevel()` helper, exactly as `add`/`edit`/`remove` do.

  This subcommand exists because `roster.layout` must be changeable without `init` (which replaces the
  whole level). `roster.route` has no such editor today; that is a pre-existing gap and **not** in
  scope — do not add `roster.mjs route` as a drive-by.
- **New subcommand** `next-split` — §6.7. Pure; internal.
- **New subcommand** `layout-splits` — `0002` §5.3. The only subcommand that executes anything.
- `show` includes `layout` in its output alongside `route`.

## 5. Required change B — `spawnShape()` and the plan

### 5.1 `spawnShape()`

Only the **herdr** branch changes here. The tmux branch, the terminal branch, and everything above the
transport branches — `agentFlags`, `claudeFlags`, `claudeCmd`, the `member.model !== "inherit"` guard
(`0002` §3.1), the `--name` element (`0002` §6.1), and the comment at `:130-131` — are untouched *by
this section*.

```js
  if (transport === "herdr") return {
    transport,
    // Layout is team-level and geometry-dependent: `roster.mjs layout-splits` computes and
    // performs the split sequence from live `herdr pane layout` output. See spec 0004 §3.2.
    layout: [],
    launch: [`herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`],
    target_placeholder: "<TARGET>",
    target_from: null,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
```

`agentFlags` itself gains `--name ${member.name}` per `0002` §6.1 — see §12 item 6, amended.

### 5.2 `layout_plan` — new top-level plan key

`roster.mjs:278` becomes:

```js
out({ level: resolved.level, path: resolved.path, transport, layout_plan: layoutPlan(resolved, transport, plan), members: plan });
```

with a new pure function:

```js
function layoutPlan(resolved, transport, plan) {
  if (transport !== "herdr") return null;
  const paneCount = plan.filter((m) => m.route === "peer").length;
  if (paneCount === 0) return null;
  return {
    mode: resolved.layout,
    computed_by: "roster.mjs layout-splits",
    pane_count: paneCount,
    inspect_command: `herdr pane layout --current`,
    inspect_source: { kind: "json", path: ".result.layout.panes" },
    split_command: `herdr pane split --pane <SPLIT_TARGET> --direction <DIRECTION> --cwd "${cwd}" --no-focus`,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
}
```

`--pane <SPLIT_TARGET>` is the live-verified form (§2.3). `inspect_command` uses `--current` because
the response is whole-workspace regardless of the pane queried (§2.3), so there is nothing to thread
into it. `<SPLIT_TARGET>` and `<DIRECTION>` are holes, deliberately spelled in the same `<UPPER>` style
as 0003's `<TARGET>` so §11.1's "no angle brackets survive substitution" check generalizes.

**`computed_by` changes value** from the pre-amendment `"orchestrator"` to `"roster.mjs layout-splits"`.
It is a documentation field; nothing branches on it. Change it so the plan does not describe a
mechanism that no longer exists.

`pane_count` is load-bearing beyond reporting: the amended §6.3 keys the `auto` mode decision off it.

`layout_plan` is `null` for tmux, for terminal, and for an all-subagent roster.

## 6. The layout algorithm

### 6.1 Shared definitions

- **P0** — the orchestrator's own pane (`$HERDR_PANE_ID`). **Amended: P0 is a layout participant, not
  a special case.** It is a candidate target at every step (§6.2 rule 1).
- **Member panes** — panes created by this procedure, tracked in creation order.
- **Candidate set** — `[P0, ...member panes]`, in that order. Panes that exist in the reported
  geometry but were neither P0 nor created by this loop (someone else's pane in the same tab) are
  **not** candidates: this procedure only subdivides its own screen real estate.
- **Total pane count** — `layout_plan.pane_count` member panes, i.e. `pane_count + 1` panes including
  P0. Known before the first split runs.
- **Visual aspect.** Terminal cells are roughly twice as tall as they are wide, so a pane that is
  square *in cells* is not square *on screen*. Geometry is reported in cells (§2.3, confirmed live),
  so compare `width` against `height × 2`:
  - `width > height × 2` ⇒ the pane looks wide ⇒ split **right**
  - otherwise ⇒ split **down**

  Getting this backwards is the difference between a grid and five slivers. Note the recorded live
  sample: `w2:p3` is 45×42 — nearly square in cells, but `45 > 84` is false, so it correctly splits
  **down**, not right.
- **Area** — `rect.width × rect.height`, in cells. Used only for comparison.

### 6.2 The two hard rules — rule 1 amended

1. **P0 is an ordinary candidate at every step.** It is never excluded, never frozen, and gets no
   special treatment beyond being first in the candidate order for tie-breaking (it is the
   earliest-existing pane).

   *This reverses the original rule 1* ("P0 is split at most once, ever"). That rule was written as a
   guard against the `1/2^N` sliver cascade of §2.1, but the cascade came from always splitting
   `--current`, not from P0 being eligible. Under rule 2 a pane can only be split while it is the
   **largest** pane, so P0 can never be driven below the size of every other pane — the greedy rule
   is itself the anti-sliver guard, and the exclusion was redundant. It was also actively harmful:
   `0002` §7.1 records a live 3-member run ending at 50% / 25% / 12.5% / 12.5%, because P0 kept
   whatever size it happened to get from split 1 while the algorithm subdivided only the other three
   panes among themselves.

   **A consequence to state plainly: the orchestrator's pane is no longer guaranteed half the screen.**
   The original §6.2 promised exactly that. It is deliberately traded away for equal footing, on the
   user's explicit instruction: a 3-member create is a 4-pane layout problem, and the orchestrator is
   one of the four.

2. **Target selection: the largest-area pane in the candidate set.** Ties break toward the
   **earliest** entry in candidate order — P0 first, then member panes in creation order — so the
   sequence is deterministic and reproducible across runs. Creation order is tracked by the loop; it
   is not derivable from `pane_id` and must not be inferred from one.

### 6.3 The three modes — amended selector input

- **`columns`** — direction is always `right`. Target per rule 2.
- **`grid`** — direction is chosen per the §6.1 visual-aspect rule on the *target* pane. Target per rule 2.
- **`auto`** — `columns` when `layout_plan.pane_count ≤ 2`, otherwise `grid`.

**Amended:** `auto` resolves **once, from the final target pane count**, and the resolved mode is the
same for every split in the run. The shipped implementation instead recomputed it per split from
`created.length + 1`, so a 4-pane layout ran two `columns` splits before ever reaching `grid`
(`0002` §7 cause 2). The prose above was always the intended rule; only the input was wrong. Concretely:
`effectiveMode(mode, paneCount)` — never `effectiveMode(mode, created.length)`.

There are only two algorithms. `auto` is a selector, not a third implementation.

### 6.4 Worked sequences — recomputed under the amended rules

Starting from P0 alone. `→` = split right, `↓` = split down. N = `pane_count` = member panes = splits;
total panes on screen = N+1.

**`grid` at 180×42 cells** (the live sample's full tab area):

| N | splits, in order | resulting panes |
|---|---|---|
| 1 | P0→A | P0 90×42, A 90×42 |
| 2 | …then P0→B (tie P0/A ⇒ P0 first) | P0 45×42, B 45×42, A 90×42 |
| 3 | …then A→C | **four equal 45×42 panes**, P0 among them |
| 4 | …then P0↓D (four-way tie ⇒ P0; 45 > 84 false ⇒ down) | P0 45×21, D 45×21, A/B/C 45×42 |
| 5 | …then A↓E | P0, D, A, E at 45×21; B, C at 45×42 |

**`grid` at 200×50 cells**, the same rules on a differently-shaped tab:

| N | splits, in order | resulting panes |
|---|---|---|
| 1 | P0→A (200 > 100) | P0 100×50, A 100×50 |
| 2 | …then P0↓B (tie ⇒ P0; 100 > 100 false ⇒ down) | P0 100×25, B 100×25, A 100×50 |
| 3 | …then A↓C | **four equal 100×25 quadrants** |

The N=3 row is exactly the arrangement `0002` §7.2 describes as the expected one — P0 split down first,
then each half split again — and it falls out of the amended rules without being special-cased.

**These tables are worked examples, not invariants.** The algorithm is geometry-driven, so the exact
sequence depends on the terminal's dimensions — visible above: the same rules split *right* at step 2
on a 180×42 tab and *down* on a 200×50 one. That is the rule working correctly, not drifting.
**The specification is the rules in §6.1-6.3**, and §11.3 tests those rules rather than these tables —
asserting a table would bake one terminal's dimensions into the suite.

What *is* invariant, and what §11.3 asserts: for `pane_count + 1` equal to a power of two, every
resulting pane has equal area regardless of the starting rect. Both tables above show it at N=3.

**`columns`** (all `right`), 180×42 tab, widths listed P0-first then in creation order:

| N | splits, in order | resulting widths |
|---|---|---|
| 1 | P0→A | 90, 90 |
| 2 | …then P0→B | 45, 45, 90 |
| 3 | …then A→C | 45, 45, 45, 45 |
| 4 | …then P0→D | 22, 23, 45, 45, 45 |
| 5 | …then A→E | 22, 23, 45, 22, 23, 45 |

Columns degrades past N=3 by construction; that is the mode the user asked for, and `auto` exists to
avoid it. `show` and the §7.1 confirmation should surface this: when the user picks `columns` with
`pane_count ≥ 4`, say once that panes will be narrow. Say it; do not override the choice.

**`auto`** = the `columns` table for `pane_count ≤ 2`, the `grid` table for `pane_count ≥ 3`.

### 6.5 Geometry refresh

Sizes change on every split, so each greedy choice needs current numbers. Inspect **once before the
loop** and **once after each split**. One call suffices per iteration — the response is
whole-workspace (§2.3).

The loop is inherently sequential: each split's target depends on the previous split's result. This is
a deliberate, narrow regression against 0003's batched phase 3a, and §7.1 explains why it is
acceptable. **Sequential does not mean slow** — the whole loop now runs inside a single
`layout-splits` process (`0002` §5), where the per-iteration cost is one local IPC round trip, not a
model turn.

### 6.6 The procedure

This is what `roster.mjs layout-splits` performs internally (`0002` §5.3). It is stated here because
it is the algorithm's contract; the orchestrator no longer executes it step by step.

```
panes := []                      # member pane ids, in creation order
for i in 1 .. pane_count:
    geometry := herdr pane layout --current  → .result.layout.panes
    decision := nextSplit({ mode, paneCount, self: P0, created: panes, geometry })
    [--manual only: return `decision` to the caller and stop — §8]
    herdr pane split --pane <decision.target> --direction <decision.direction> --cwd <cwd> --no-focus
    new_id := response → .result.pane.pane_id
    append new_id to `panes`
return panes
```

The caller assigns `panes[k]` to the k-th peer-routed member, in plan order.

### 6.7 `roster.mjs next-split` — the algorithm as testable code

```
roster.mjs next-split --mode <auto|columns|grid> --pane-count <N> --self <pane-id>
                      --created '<json array of pane ids, creation order>'
                      --geometry '<json array of {pane_id, rect:{width,height,x,y}}>'
```

Prints `{"target": "<pane-id>", "direction": "right"|"down"}`.

`--pane-count` is **required**. Omitting it is an error (exit 2, named message) rather than a silent
fallback to the old `created.length` behaviour — a silent fallback would reintroduce `0002` §7 cause 2
exactly where it is hardest to see.

Behaviour, and it is the whole of §6.1-6.3 in one pure function:

```js
function effectiveMode(mode, paneCount) {
  if (mode !== "auto") return mode;
  return paneCount <= 2 ? "columns" : "grid";
}

function nextSplit({ mode, paneCount, self, created, geometry }) {
  const byId = new Map(geometry.map((g) => [g.pane_id, g.rect]));
  let target = null;
  let bestArea = -1;
  for (const id of [self, ...created]) {
    const rect = byId.get(id);
    if (!rect) throw new Error(`pane ${id} is not present in the reported geometry`);
    const area = rect.width * rect.height;
    if (area > bestArea) { bestArea = area; target = id; }   // strict > ⇒ earliest wins ties
  }
  const rect = byId.get(target);
  const direction =
    effectiveMode(mode, paneCount) === "columns" || rect.width > rect.height * 2 ? "right" : "down";
  return { target, direction };
}
```

Points the Implementor must not smooth over:

- **`self` is in the candidate loop, first.** There is no `created.length === 0` special case any more —
  it disappears, because with an empty `created` the loop's only candidate *is* `self`. Deleting that
  branch is part of the fix, not a refactor.
- **Strict `>` on area** is what makes ties resolve to the earliest candidate. Do not relax it to `>=`.
- **A candidate absent from `geometry` is an error** (exit 2, named message) — including `self`, which
  is newly reachable now that `self` is looked up on every call. It means a pane died or the ids were
  mismatched, and silently skipping it would produce a wrong layout. In practice `self` is always
  present, because `herdr pane layout` returns the whole workspace (§2.3).
- **`direction()` takes the target's rect and the resolved mode.** It no longer needs `created` or
  `geometry`; if the existing helper's signature carries them, drop them rather than leaving a
  parameter that invites the old `created.length` computation back in.

`nextSplit()` performs **no I/O** — it is arithmetic over its arguments — and that does not change
under the §12 item 5 amendment. `layout-splits` calls this exact function; there is **one**
implementation of the rule, and the `next-split` subcommand exists so that implementation is
unit-testable without a transport.

## 7. Required change C — `SKILL.md`

### 7.1 § Create — new step 0, and a rewritten 3a

Steps 1, 2, 3b, 4 and 5 are unchanged. **0003's `launch`/`target_placeholder`/`target_from`/
`target_source` substitution mechanism in 3b is explicitly out of scope and must not be edited.**

Insert **step 0, before Plan**:

> 0. **Confirm the layout.** Read the roster's `layout` (via `roster.mjs show`; it is `auto` unless
>    set). Ask the user to confirm it for this Team with AskUserQuestion, marking the stored value
>    "(current default)": `auto` — columns for 1-2 members, grid beyond; `columns` — one vertical
>    column per member; `grid` — balanced quadrants, **including this session's own pane**. **Always
>    ask, every `create`** — a persisted default is not a licence to apply it silently. If the user
>    picks something other than the stored value, ask once whether to make it the new default, and only
>    if yes run `roster.mjs layout --layout <mode>`. Never persist a divergent choice without asking.
>    This step applies to `auto` and `manual` alike. Skip it entirely when the transport is not `herdr`.

Replace phase **3a** with:

> **3a — Layout.** For the `herdr` transport, `spawn.layout` is empty and the plan carries a top-level
> `layout_plan`. Run **one** command:
>
>     roster.mjs layout-splits --mode <layout_plan.mode> --pane-count <layout_plan.pane_count> --cwd <repo root>
>
> It inspects the live geometry, computes every decision, and performs every split itself. Read
> `panes` from its JSON — the new pane ids, in creation order.
>
> - **exit 0** — `complete: true`, you have all `pane_count` ids.
> - **exit 3** — partial. `panes` holds the ids that *did* get created and they are real: use them.
>   `failed_at` and `error` say which split failed and why, and `attempted` carries the decision it was
>   about to run. Retry that one split with `layout-splits --apply --target … --direction …`; if it
>   fails again, carry the members that have no pane into step 5's partial handling. **Do not discard
>   the panes you already have** — they cost real work and their members can still be launched.
> - **exit 2** — nothing was done; the message says why. No panes were created; treat the layout phase
>   as failed and stop before 3b.
>
> **Do not drive the split loop yourself, and do not compute targets or directions yourself.**
> `layout-splits` owns both. The `layout_plan` command templates in the plan document the contract and
> are the fallback if `layout-splits` is unavailable; they are not a second way to do this.
>
> **Your own pane is one of the panes being laid out**, and may be split more than once. That is
> correct; do not "protect" it.
>
> In `manual` mode, drive it one iteration at a time with `--next` / `--apply` — see
> § Create manual-mode layout below.
>
> For `tmux`, phase 3a is unchanged: issue every member's `spawn.layout` in a single batched message
> and read each target from its `target_source`.
>
> For `terminal`, there is no layout phase.
>
> **Assert before continuing:** you must hold exactly `layout_plan.pane_count` non-empty, distinct pane
> ids — minus any that failed after a retry, and minus any the user deliberately skipped in `manual`
> mode. Assign them to peer-routed members in plan order, then continue to 3b unchanged.

On the sequential loop: 0003 measured the layout batch as saving only `(N-1) × split_latency`, which it
called "small", and rated batched layout **Medium** confidence with a named serial fallback. This spec
takes that fallback deliberately in exchange for a layout that is actually usable. **All of 0003's
real saving — the batched `launch` phase, `N × ready_wait` collapsing to `max(ready_wait)` — is
untouched**, and `layout-splits` removes the model-turn cost that made the serial loop expensive in
practice (`0002` §5).

### 7.2 § init — new step

Insert after the existing step 2 (Route), renumbering the rest:

> 2b. **Layout.** If not given, ask the team-wide pane layout: `auto` (Recommended) — columns for 1-2
>     members, grid beyond; `columns` — one vertical column per member, narrow past three;
>     `grid` — balanced quadrants. In every mode this session's own pane is laid out alongside the
>     members. Pass it as `--layout <mode>` to `roster.mjs init`. Only meaningful for the `herdr`
>     transport; harmless otherwise.

### 7.3 § Command surface and § add / edit / remove

Add to the command surface list:
- `layout [--level <L>] [--layout <mode>]` — show or set the team-wide pane layout.
- `layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>] [--next|--apply …]` — performs
  the herdr layout phase. Used by § Create 3a. Not a user-facing command.
- `next-split --mode <m> --pane-count <n> --self <id> --created <json> --geometry <json>` — the pure
  decision function, exposed for testing. **The skill does not call it**; `layout-splits` does.

Note in § add / edit / remove that layout is team-wide and is **not** a per-member field.

## 8. Manual mode — resolved

**Layout is a separate, earlier decision from per-member placement.** The two are not merged:

- **Step 0** (both modes) settles the *shape* — how the screen gets carved. Team-level, asked once.
- **The per-split pause below** (manual only) settles *each individual cut*, live.
- **Step 2's manual pause** (manual only) settles *which member goes where* — per-member, and it
  already exists in 0003.

### 8.1 The per-split pause

**Decided: `manual` pauses before each split, showing the real computed decision each time.** No
up-front preview of the whole sequence is attempted.

The reason is that a full preview would require *predicting* geometry — simulating each split's effect
on pane sizes before any split has run — and the algorithm reads geometry rather than modelling it. A
predicted sequence would be approximate (it cannot know herdr's exact ratio behaviour) and would
diverge from what actually happens the moment a real split lands differently. Showing the real
decision, one at a time, is exact by construction.

Add to `skills/agent-roster/SKILL.md` § Create, as a subsection referenced from 3a:

> **§ Create manual-mode layout.** In `manual` mode, run the layout phase one iteration at a time.
> For each of the `layout_plan.pane_count` iterations:
>
> 1. `roster.mjs layout-splits --next --mode <m> --pane-count <n> --created '<ids so far, JSON>'` —
>    this reads the live geometry and returns the decision **without splitting anything**.
> 2. Show the user: the iteration (`split 2 of 4`), the target pane id and its current size in cells,
>    whether it is this session's own pane, the direction, and the mode that chose it.
> 3. Offer: **accept**, **change direction** (`right`/`down`), **change target** (any pane id in the
>    returned geometry — including panes this loop did not create), or **skip this split**.
> 4. Unless skipped, run
>    `roster.mjs layout-splits --apply --target <id> --direction <dir> --cwd <repo root>` and append
>    the returned `pane_id` to your list.
>
> The next iteration re-reads geometry, so an amendment is absorbed rather than compounding.
>
> **Skip** means that member gets no pane: it is carried into step 5's partial handling as a member
> that did not come up, exactly as a failed split would be. Say so when offering the option — a skip
> is not free, it degrades the Team.

### 8.2 What this pause is not

This is a pause **inside** the layout phase, before each split. It is **not** a pause between 3a and
3b: 0003 §5 forbids that explicitly, because a per-member pause there would re-serialize the batched
launch phase that 0003 exists to parallelize. Nothing here touches 3b.

0003 §11.3 flagged "should manual offer a deliberate checkpoint between layout and launch" as an
undecided UX question. **This spec does not decide it** — every pause specified here is inside or
before 3a. §11.3 remains open and untouched.

## 9. Remaining evidence items — neither blocking

1. **Live check at N=3, `grid`** (amended from N=4). Confirm four panes of visibly equal size, **the
   orchestrator's own pane among them**. This is the acceptance evidence for the amended §6.2 rule 1
   and must be run during the Implementor's verification phase (§11.4). The pre-amendment version of
   this item asked for "orchestrator still at half screen" — that expectation is retired; half-screen
   is now the symptom, not the goal.
2. **`herdr pane split --ratio FLOAT` semantics — deferred follow-up, do not implement here.** The live
   usage string exposes a `--ratio` flag this spec does not use. If `--ratio` sets the fraction retained
   by the *existing* pane, then `columns` could produce **exactly even** columns by chain-splitting the
   remainder at `1/(N-k)` on step `k`, removing §6.4's acknowledged "columns degrades past N=3" wart.
   Confirmed out of scope: the greedy algorithm works with or without `--ratio` and already delivers the
   requested quadrant behaviour, and building on an unverified flag semantic is how §2.1 happened. If
   someone later verifies which pane the ratio applies to, it becomes a small, self-contained addition
   to `nextSplit()`'s output (an optional `ratio` field).

## 10. Change list

| File | Change |
|---|---|
| `hooks/lib-roster.mjs` | Add `ROSTER_LAYOUT_VALUES` beside `ROSTER_ROUTE_VALUES` (`:21`). Add the **optional**-field `roster.layout` check to `validateRosterBlock`. |
| `hooks/lib-config.mjs` | `resolveRoster()` (298-321) returns `layout: r.layout \|\| "auto"` alongside `route`. Sole default site. |
| `hooks/roster.mjs` | herdr branch of `spawnShape()` → §5.1. Add `layoutPlan()` per §5.2 and `layout_plan` to the `--plan` output at `:278`. Add `nextSplit()`/`effectiveMode()` per §6.7 and the `next-split` subcommand. Add the `layout-splits` subcommand per `0002` §5.3. `init` accepts `--layout`. New `layout` subcommand. `show` reports `layout`. tmux and terminal branches untouched. |
| `skills/agent-roster/SKILL.md` | § Create: new step 0 (§7.1), rewritten 3a calling `layout-splits` (§7.1), new § Create manual-mode layout subsection (§8.1). § init: new step 2b (§7.2). § Command surface: add `layout`, `layout-splits`, `next-split` (§7.3). **Step 3b untouched.** |
| `tests/test-roster-spawn.sh` | Replace the `:103-104` assertion (it asserts the defect). New assertions per §11.1. |
| `tests/test-roster-next-split.sh` | Unit tests for `next-split` per §11.3, including the equal-area property check. |
| `tests/test-roster-layout-splits.sh` | **NEW** — `0002` §11.3. Drives `layout-splits` against a fake `herdr` on PATH. |
| `docs/specs/0003-roster-create-perf.md` | No edit. Its §11.1 already names this spec as the follow-up and stays accurate as written. |
| `docs/specs/0001-agent-roster.md` | No edit. §6 step 4's "split evenly across available panes" is what §6 here finally implements; the sentence stays correct. |

## 11. Verification

### 11.1 Plan-shape checks (no spawning; safe anywhere)

Run `roster.mjs create --plan` and assert:

1. Under herdr: every peer member has `spawn.layout` deep-equal to `[]`, `spawn.target_from === null`,
   `spawn.target_placeholder === "<TARGET>"`, and `spawn.target_source.path === ".result.pane.pane_id"`.
2. Under herdr: top-level `layout_plan` is non-null; `layout_plan.pane_count` equals the number of
   peer-routed members; `layout_plan.mode` is one of `ROSTER_LAYOUT_VALUES`; `split_command` contains
   `--pane <SPLIT_TARGET>` and `<DIRECTION>` and does **not** contain `--current`;
   `inspect_source.path === ".result.layout.panes"`.
3. Under tmux: `layout_plan === null`, and `spawn.layout[0]` still contains `-P -F '#{pane_id}'` with
   `spawn.target_from === 0` — **0003's tmux shape is unregressed** (guard the `-t` in `launch[0]` too).
4. Under terminal: `layout_plan === null`, `spawn.layout` is `[]`, all three `target_*` null.
5. A roster whose JSON has **no** `layout` key resolves to `layout_plan.mode === "auto"` and validates
   clean — the back-compat guard.
6. An all-subagent roster yields `layout_plan === null`.
7. `0002` regression guards: no `--model inherit` anywhere in `layout` or `launch`; **every peer
   member's `launch` contains `--name <derived-name>` after the `--`** (`0002` §6.1).
   *Amended:* the pre-amendment version of this item asserted the herdr `launch` contains **no**
   `--name`. That assertion is wrong and is the Defect D bug; it must be inverted, not preserved.
8. `create --plan` runs to completion with **no** `herdr` binary on PATH — planning stays
   connection-free (`0002` §11.3 covers this for every non-`layout-splits` subcommand).

### 11.2 Validation checks

- `roster.layout: "quadrant"` (not in the enum) is rejected by `validateRosterBlock` with a message
  naming the allowed values.
- `roster.layout` absent ⇒ **no** validation error (contrast with `roster.route` absent, which must
  still error).
- `roster.mjs layout --layout grid` writes the level file and a subsequent `show` reports `grid`.
- A per-member `layout` field is ignored, not honoured — there is no per-member layout.

### 11.3 `next-split` unit checks — the algorithm, tested (`tests/test-roster-next-split.sh`)

Feed synthetic geometry; no herdr required. Test the **rules**, not §6.4's worked tables — those are
tab-size-specific examples, and asserting them would bake one terminal's dimensions into the suite.

1. `--created '[]'` ⇒ `target` is `--self`, whatever the geometry.
2. **`self` IS returned as the target when it is the largest pane, with `created` non-empty.**
   *Amended, and this inverts the pre-amendment item 2* (which asserted `self` is never returned).
   The old assertion encodes `0002` §7's defect and must be replaced, not kept — an implementation
   passing both is impossible, and keeping the old one would silently re-forbid the fix.
3. Largest-area candidate wins across the whole set: give `self` area 400 and created panes 100/200 ⇒
   `self`; give `self` 100 and created 400/200 ⇒ the 400 one.
4. Tie → earliest in candidate order: `self` tied with a created pane ⇒ `self` (it is first); two
   created panes tied ⇒ the one listed first in `--created`. Assert the result is unchanged when
   `--geometry`'s array order is reversed (order-independence — order comes from `--created`, not from
   the geometry response).
5. `--mode columns` ⇒ `direction` is `right` for a tall target as well as a wide one.
6. `--mode grid`: target 90×42 ⇒ `right` (`90 > 84`); target 45×42 ⇒ `down` (`45 > 84` false); target
   exactly `width === height * 2` ⇒ `down` (the boundary is strict `>`).
7. **`--mode auto` resolves from `--pane-count`, not from `created`.** `--pane-count 2` behaves as
   `columns` on *every* call including the third; `--pane-count 3` behaves as `grid` on the **first**
   call, when `created` is still empty. That second case is the direct regression test for
   `0002` §7 cause 2 and is the highest-value assertion in this file.
8. A candidate id absent from `geometry` ⇒ exit 2 with a named error, **not** a silent skip. Cover both
   a missing `created` id and a missing `self`.
9. `--pane-count` omitted ⇒ exit 2 with a named error (§6.7).
10. `next-split` performs no I/O: it succeeds with no herdr binary on PATH and no `HERDR_ENV` set.
11. **Equal-area property (`0002` §7.3's fixture).** Drive `next-split` in a loop from a synthetic
    start rect, applying an idealized split to the model after each decision — `right` splits width
    into `floor(w/2)` and `w - floor(w/2)`, `down` splits height the same way — and assert that for
    `--pane-count 3` (4 panes total) all four final areas are within 5% of each other, **with `self`
    among the four**. Run it from at least two start rects, `180×42` and `200×50`, so the assertion is
    about the rule rather than one tab: both must pass. The simulator is an idealization of herdr's
    splitting and its only job is to exercise the decision *sequence*; do not assert exact cell counts
    against it.

`layout-splits`' own checks — including the invariant that no other subcommand executes `herdr` — are
specified in `0002` §11.3, since that is where the subcommand is designed.

### 11.4 Live checks (herdr)

- N=3, `grid`: §9 item 1 — four visibly equal panes including the orchestrator's own.
- N=5, `columns`: panes are narrow (expected) and the user was warned once (§6.4).
- Re-run `create` after `roster.mjs layout --layout columns`: step 0 shows `columns` as the current
  default and still asks.
- `manual`, N ≥ 3: `--next` pauses before **every** split, each showing the target's real current size;
  amending one split's direction is honoured and the following `--next` recomputes from the actual
  result rather than from the original plan; skipping a split yields a `--partial` Team naming that
  member.
- The whole auto-mode layout phase is **one** tool call (`0002` §5).

## 12. What must NOT change

1. **0003's launch mechanism.** `launch[]`, `target_placeholder`, `target_source`, and the phase-3b
   substitution are out of scope. Only the layout side moves. `target_from` changes value for herdr
   (`0` → `null`); its *meaning* for tmux is untouched.
2. **The batched launch phase.** 3b stays one message, one tool call per member. The sequential loop
   and the manual per-split pause are confined to the layout phase and only for herdr.
3. **The plan→commit two-step.** `--plan` resolves and reports; `--commit --verified … --transport …
   --roster-level …` writes the Team. The `--commit` branch, the `team` object literal, and the
   `CLAUDE_PID` / `--orchestrator-pid` behaviour with its comment are untouched.
4. **Check-in and partial success.** Poll every 2s, give up at 60s, fixed interval, not configurable.
   On partial, commit with `--partial`, name the missing members, do not tear down (0001 §13). Every
   new failure path here — a split that yields no pane id, a `layout-splits` exit 3, a user-skipped
   split — funnels into that same outcome.
5. **`roster.mjs` executes nothing except the two calls named here — AMENDED, scoped down, not
   deleted.** The pre-amendment rule was "`roster.mjs` spawns nothing … no `execFileSync` beyond
   `detectTransport()`'s tmux probe". The user has decided to reverse it for the layout loop
   specifically (`0002` §5.3). The boundary now:

   **Permitted, and this is the exhaustive list:**
   - `detectTransport()`'s pre-existing `tmux list-sessions` probe (`:123-131`) — read-only, unchanged.
   - The `layout-splits` subcommand, and only it: `herdr pane layout` (read) and `herdr pane split`
     (mutating), via `execFileSync` with an argv array. Nothing else, on no other transport.

   **Still guaranteed, and these are not weakened by the amendment:**
   - `roster.mjs` **never starts an agent process.** No `claude`, no `herdr agent start`, no
     `tmux new-window`, no backgrounded terminal. The entire launch phase (3b) stays with the skill.
   - `roster.mjs` **never destroys anything.** `disband --kill` still only *emits* its close commands
     for the skill to run after confirmation (`0002` §8.3). "May split a pane" did not become
     "may close one".
   - **Every other subcommand stays connection-free** — `show`, `init`, `add`, `edit`, `remove`,
     `layout`, `next-split`, `create --plan`, `create --commit`, `disband` — and `0002` §11.3 asserts
     this at runtime rather than by inspection.
   - `nextSplit()` itself remains pure (§6.7). The execution lives in the subcommand wrapper, not in
     the rule.

   **Why the line is here.** The layout loop is the one place where each command's arguments depend on
   the *result* of the previous command, so it cannot be expressed as emitted strings without N
   round trips through the caller — which is precisely the cost `0002` §5 measured. Launch and
   teardown are flat lists of independent commands; emitting them costs nothing and keeps the
   dangerous verbs (start a process, kill a process) outside this file. That is the principle, not
   "whatever was convenient".

   **This boundary is a decision, not a slope.** Moving it again — letting `layout-splits` launch
   agents, or letting `disband --kill` close panes itself — requires its own spec and its own
   decision. Do not extend it by analogy.
6. **`0002`'s fixes.** `--model inherit` stays omitted (`0002` §3.1). **Amended:** `agentFlags` now
   *includes* `--name ${member.name}` (`0002` §6.1) — the pre-amendment wording of this item said the
   herdr path "keeps passing `agentFlags` (no `--name`) after `--`", which is exactly Defect D and is
   retracted. The `:130-131` comment survives.
7. **tmux and terminal transports.** Byte-identical to 0003 apart from `agentFlags` gaining `--name`,
   which is shared by all three branches by construction. No `layout_plan`, no mode, no layout change,
   and `layout-splits` refuses to run on them.
8. **The derived-name scheme** (0001 §3.4) and `roster.route` semantics, including its required-ness.
9. **The amended §6.2 rule 1 itself.** Do not add a compensating special case for the orchestrator's
   pane — no minimum size, no "skip P0 if it would get small", no reserved half. The user's stated
   principle is equal footing, and a second special case to soften the first is precisely what the
   amendment removes.

## 13. Confidence and escalation

**High** — that layout must be computed from live geometry rather than emitted as a static string: the
`--current`/`--direction right` constant is the whole of §2.1. `nextSplit()` is the seam that keeps the
*rule* in pure, tested code regardless of who observes the geometry.

**High** — the herdr CLI mechanics. `--pane <id>` targeting, cell units, and whole-workspace inspection
are all confirmed from live output (§2.3), not from documentation. The aspect rule survived that check
unchanged.

**High** — the amended §6.2 rule 1. Including `self` in the greedy search is a two-line change with a
directly observed failure it repairs (`0002` §7.1) and a directly stated user intent behind it. The
anti-sliver property the old rule was protecting is preserved by the greedy rule itself: a pane is only
ever split while it is the largest, so no pane — `self` included — can be driven below the others.

**High** — that grid/columns are herdr-only concepts, and that `roster.layout` should be
optional-with-default rather than required like `roster.route` (every roster written before this change
lacks the key).

**Medium-high** — the §12 item 5 amendment. The decision is the user's and is recorded; my read is that
the *layout* carve-out is well-chosen — it is the only iteration-dependent loop, the verbs are
non-destructive and visibly reversible (close the pane), and the process-starting verbs stay out. What
it costs is stated honestly in `0002` §13: one subcommand can no longer be tested without a fake binary
on PATH, and the "this file executes nothing" argument is no longer available as a flat answer to the
next proposal. That is why the boundary above is written as an exhaustive list with an explicit
"decision, not a slope" clause rather than a general permission.

**Medium-high** — the algorithm's aesthetic outcome. The rules are deterministic and unit-tested, and
the equal-area property (§11.3 item 11) holds for power-of-two pane counts at any start rect, but
non-power-of-two counts (3, 5, 6 panes total) necessarily produce unequal panes — binary splitting
cannot do otherwise. §9 item 1's live check is still the only real proof the result *looks* right.
Do not skip it.

**No Ultra-Advisor escalation recommended**, including for the invariant reversal. The blast radius
stays small and reversible: the new execution is two non-destructive herdr verbs behind one
subcommand, on one transport, revertible in one commit. What *would* change this answer is any
proposal to let `roster.mjs` start or kill a process — that is a different risk class, and §12 item 5
is written so such a proposal has to come back through a spec rather than arriving as a refactor.

**No open design questions.** §9's two items are verification evidence and a deferred follow-up
respectively, neither of which blocks implementation.
