# Spec 0004 — `/agent-roster create`: real pane layout instead of N serial `--current` splits

Status: **ready for implementation.** Herdr CLI evidence gathered live 2026-08-22; all design questions
resolved. The two remaining §9 items are verification-phase evidence and a deferred follow-up, neither
blocking.
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Team, Orchestrator)
Related: `docs/specs/0001-agent-roster.md` §6 step 4 (the never-implemented "split evenly across
available panes/windows"); `docs/specs/0003-roster-create-perf.md` §11.1, which names this work as
`0004` and states the layout phase it introduced is "the structural prerequisite" for it.

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

`hooks/roster.mjs` remains pure file I/O and spawns nothing. As in 0003, this spec changes the strings
it emits and their grouping, never what it executes. `next-split` is arithmetic over JSON handed to it
on the command line — it opens no connection and reads no pane.

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

One `herdr pane layout` call per iteration therefore yields everything needed to pick the next target —
the cheap end of §6.5's question.

### 2.4 What `roster.mjs` can and cannot know

`roster.mjs` is a transient subprocess with no herdr connection. It knows the member count and the
configured mode. It cannot know pane ids, pane sizes, or how many panes already exist. Any layout it
prescribes *unprompted* is therefore a guess, which is exactly how the current hardcoded string came to
exist. Geometry-dependent decisions belong to the orchestrating session, which can call
`herdr pane layout` — and which then hands that geometry back to `roster.mjs next-split` (§6.7) for the
arithmetic.

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

## 3. Design decision — layout is team-level and orchestrator-computed, for herdr only

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
  *templates*, and the two JSON parse paths — the transport knowledge `roster.mjs` legitimately has;
- the orchestrating session runs the §6.6 loop, calling `roster.mjs next-split` for each decision;
- phase 3b is **unchanged** — the orchestrator substitutes each id for `<TARGET>` in that member's
  `launch`, exactly as 0003 specifies.

`target_placeholder` stays `"<TARGET>"` for herdr. `target_source` stays on the member as the parse
recipe. Only `target_from` becomes `null`, and it acquires one new documented meaning:

> `target_from: null` **with** a non-null `target_placeholder` means: the target id does not come from
> this member's `layout` array — it comes from the plan-level `layout_plan` sequence the orchestrator
> computes and runs. `target_from: null` **with** a null `target_placeholder` (terminal) means there is
> no target at all.

That tri-state is the one piece of added contract complexity, and it is justified: the alternative is N
copies of the same template on N members, which is what made the current bug easy to write.

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

`validateMember` is **not** touched. Layout is team-wide only; there is no per-member layout override,
and adding one would be meaningless (a member does not own a split).

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
- **New subcommand** `next-split` — §6.7.
- `show` includes `layout` in its output alongside `route`.

## 5. Required change B — `spawnShape()` and the plan

### 5.1 `spawnShape()`

Only the **herdr** branch changes. The tmux branch, the terminal branch, and everything above the
transport branches — `agentFlags`, `claudeFlags`, `claudeCmd`, 0002's `member.model !== "inherit"`
guard, and the comment at `:130-131` — are **untouched**.

```js
  if (transport === "herdr") return {
    transport,
    // Layout is team-level and geometry-dependent: the orchestrator computes the split
    // sequence from `layout_plan` and live `herdr pane layout` output. See spec 0004 §3.2.
    layout: [],
    launch: [`herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`],
    target_placeholder: "<TARGET>",
    target_from: null,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
```

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
    computed_by: "orchestrator",
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
into it. `<SPLIT_TARGET>` and `<DIRECTION>` are holes the orchestrator fills, deliberately spelled in
the same `<UPPER>` style as 0003's `<TARGET>` so §11.1's "no angle brackets survive substitution"
check generalizes.

`layout_plan` is `null` for tmux, for terminal, and for an all-subagent roster.

## 6. The layout algorithm

### 6.1 Shared definitions

- **P0** — the orchestrator's own pane (`$HERDR_PANE_ID`).
- **Member panes** — panes created by this procedure, tracked in creation order.
- **Visual aspect.** Terminal cells are roughly twice as tall as they are wide, so a pane that is
  square *in cells* is not square *on screen*. Geometry is reported in cells (§2.3, confirmed live),
  so compare `width` against `height × 2`:
  - `width > height × 2` ⇒ the pane looks wide ⇒ split **right**
  - otherwise ⇒ split **down**

  Getting this backwards is the difference between a grid and five slivers. Note the recorded live
  sample: `w2:p3` is 45×42 — nearly square in cells, but `45 > 84` is false, so it correctly splits
  **down**, not right.
- **Area** — `rect.width × rect.height`, in cells. Used only for comparison.

### 6.2 The two hard rules

1. **P0 is split at most once, ever — on the first split only.** After that P0 is never a split target
   again. This is the rule that fixes the reported problem: the orchestrator's pane ends at half the
   screen regardless of N, instead of `1/2^N`.
2. **Target selection: the largest-area pane among the member panes** (P0 excluded after the first
   split). Ties break toward the **earliest-created** pane, so the sequence is deterministic and
   reproducible across runs. Creation order is known to the orchestrator from its own tracked list;
   it is not derivable from `pane_id` and must not be inferred from one.

### 6.3 The three modes

- **`columns`** — direction is always `right`. Target per rule 2.
- **`grid`** — direction is chosen per the §6.1 visual-aspect rule on the *target* pane. Target per rule 2.
- **`auto`** — `columns` when `pane_count ≤ 2`, otherwise `grid`. Two or three total columns stay
  readable; beyond that they hit the herdr skill's "unusably narrow columns" warning, which is the
  whole reason `auto` is the default.

There are only two algorithms. `auto` is a selector, not a third implementation.

### 6.4 Worked sequences

Starting from P0 alone at 180×42 cells (the live sample's full tab area; `180 > 42×2` ⇒ wide).
`→` = split right, `↓` = split down.

**`grid`** (and therefore `auto` for N ≥ 3):

| N | splits, in order | resulting arrangement |
|---|---|---|
| 2 | P0→A (P0 90×42, A 90×42); A→B (A 45×42, B 45×42) | orchestrator = left half; A and B as two columns in the right half |
| 3 | …as N=2; then A↓C (A 45×21, C 45×21) | left half orchestrator; right half: A over C, B full height beside them |
| 4 | …as N=3; then B↓D (B 45×21, D 45×21) | left half orchestrator; right half a clean **2×2 quadrant** |
| 5 | …as N=4; then A→E (A 22×21, E 23×21) | 2×2 on the right with its top-left cell halved horizontally |

**These tables are worked examples for a 180×42 tab, not invariants.** The algorithm is geometry-driven,
so the exact sequence depends on the terminal's dimensions: at 180×42 pane A is 90×42 and `90 > 84`
holds, so step 2 splits *right*; on a 200×50 tab the same pane is 100×50, `100 > 100` fails, and it
splits *down* instead. That is the rule working correctly, not drifting. **The specification is the
rules in §6.1-6.3**, and §11.3 tests those rules rather than these tables — asserting a table would
bake one terminal's dimensions into the suite.

**`columns`** (all `right`), 180×42 tab:

| N | splits, in order | resulting widths (P0 first) |
|---|---|---|
| 2 | P0→A; A→B | 90, 45, 45 |
| 3 | …then A→C | 90, 22, 23, 45 |
| 4 | …then B→D | 90, 22, 23, 22, 23 |
| 5 | …then A→E | 90, 11, 11, 23, 22, 23 |

Columns degrades past N=3 by construction; that is the mode the user asked for, and `auto` exists to
avoid it. `show` and the §7.1 confirmation should surface this: when the user picks `columns` with
`pane_count ≥ 4`, say once that panes will be narrow. Say it; do not override the choice.

**`auto`** = the `columns` row for N ≤ 2, the `grid` row for N ≥ 3.

### 6.5 Geometry refresh

Sizes change on every split, so each greedy choice needs current numbers. Call `inspect_command`
**once before the loop** and **once after each split**. One call suffices per iteration — the response
is whole-workspace (§2.3).

These calls are cheap local IPC and are **not** batched: the loop is inherently sequential because each
split's target depends on the previous split's result. This is a deliberate, narrow regression against
0003's batched phase 3a, and §7.1 explains why it is acceptable.

### 6.6 The procedure

```
panes := []                      # member pane ids, in creation order
for i in 1 .. layout_plan.pane_count:
    geometry := run layout_plan.inspect_command, parse layout_plan.inspect_source.path
    decision := roster.mjs next-split --mode <layout_plan.mode> \
                  --self <P0> --created '<panes as JSON>' --geometry '<geometry as JSON>'
    [manual mode only: present `decision` and let the user amend or drop it — §8]
    run layout_plan.split_command with <SPLIT_TARGET>=decision.target,
                                       <DIRECTION>=decision.direction
    new_id := parse layout_plan.target_source.path out of the split response
    append new_id to `panes`
assign panes[k] to the k-th peer-routed member, in plan order
```

### 6.7 `roster.mjs next-split` — the algorithm as testable code

```
roster.mjs next-split --mode <auto|columns|grid> --self <pane-id>
                      --created '<json array of pane ids, creation order>'
                      --geometry '<json array of {pane_id, rect:{width,height,x,y}}>'
```

Prints `{"target": "<pane-id>", "direction": "right"|"down"}`.

Behaviour, and it is the whole of §6.1-6.3 in one pure function:

- `created` empty ⇒ `target = self` (rule 1: P0's only split).
- otherwise ⇒ `target` = the id in `created` with the largest `rect.width × rect.height` from
  `geometry`; ties resolved by earliest position in `created` (rule 2).
- `direction` = `"right"` when the effective mode is `columns`; otherwise `"right"` if the target's
  `rect.width > rect.height * 2`, else `"down"`.
- effective mode: `auto` resolves to `columns` when `created.length + 1 ≤ 2`, else `grid`.
- A `created` id absent from `geometry` is an error (exit 2, named message) — it means a pane died or
  the ids were mismatched, and silently skipping it would produce a wrong layout.

This function performs **no I/O** — it is arithmetic over two JSON arguments. It exists in `roster.mjs`
solely so the algorithm is unit-testable and so the orchestrator cannot improvise the greedy rule;
`roster.mjs` itself never calls it. That asymmetry is deliberate and was confirmed as wanted.

## 7. Required change C — `SKILL.md`

### 7.1 § Create — new step 0, and a rewritten 3a

Steps 1, 2, 3b, 4 and 5 are unchanged. **0003's `launch`/`target_placeholder`/`target_from`/
`target_source` substitution mechanism in 3b is explicitly out of scope and must not be edited.**

Insert **step 0, before Plan**:

> 0. **Confirm the layout.** Read the roster's `layout` (via `roster.mjs show`; it is `auto` unless
>    set). Ask the user to confirm it for this Team with AskUserQuestion, marking the stored value
>    "(current default)": `auto` — columns for 1-2 members, grid beyond; `columns` — one vertical
>    column per member; `grid` — balanced quadrants. **Always ask, every `create`** — a persisted
>    default is not a licence to apply it silently. If the user picks something other than the stored
>    value, ask once whether to make it the new default, and only if yes run
>    `roster.mjs layout --layout <mode>`. Never persist a divergent choice without asking.
>    This step applies to `auto` and `manual` alike. Skip it entirely when the transport is not `herdr`.

Replace phase **3a** with:

> **3a — Layout.** For the `herdr` transport, `spawn.layout` is empty and the plan carries a top-level
> `layout_plan`; you drive the splits. Loop `layout_plan.pane_count` times: run
> `layout_plan.inspect_command` and parse `layout_plan.inspect_source.path`; pass that geometry, your
> own `$HERDR_PANE_ID`, and the pane ids you have created so far (in creation order) to
> `roster.mjs next-split --mode <layout_plan.mode>`; run `layout_plan.split_command` with the target
> and direction it returns; read the new pane id from `layout_plan.target_source.path` and append it to
> your created list. **Do not compute the target or direction yourself — `next-split` owns that rule.**
> This loop is **sequential**; each target depends on the previous result, so do not try to batch it.
>
> In `manual` mode, pause inside this loop before each split — see § Create manual-mode layout below.
>
> For `tmux`, phase 3a is unchanged: issue every member's `spawn.layout` in a single batched message
> and read each target from its `target_source`.
>
> For `terminal`, there is no layout phase.
>
> **Assert before continuing:** you must hold exactly `layout_plan.pane_count` non-empty, distinct pane
> ids — minus any the user deliberately dropped in `manual` mode. If any is missing, empty, or
> duplicated, retry that one split; if it still yields no pane, treat that member as one that did not
> come up and carry it into step 5's partial handling.
>
> Assign the pane ids to peer-routed members in plan order, then continue to 3b unchanged.

On the sequential loop: 0003 measured the layout batch as saving only `(N-1) × split_latency`, which it
called "small", and rated batched layout **Medium** confidence with a named serial fallback. This spec
takes that fallback deliberately in exchange for a layout that is actually usable. **All of 0003's
real saving — the batched `launch` phase, `N × ready_wait` collapsing to `max(ready_wait)` — is
untouched.** Note the trade in the PR.

### 7.2 § init — new step

Insert after the existing step 2 (Route), renumbering the rest:

> 2b. **Layout.** If not given, ask the team-wide pane layout: `auto` (Recommended) — columns for 1-2
>     members, grid beyond; `columns` — one vertical column per member, narrow past three;
>     `grid` — balanced quadrants. Pass it as `--layout <mode>` to `roster.mjs init`. Only meaningful
>     for the `herdr` transport; harmless otherwise.

### 7.3 § Command surface and § add / edit / remove

Add to the command surface list:
- `layout [--level <L>] [--layout <mode>]` — show or set the team-wide pane layout.
- `next-split --mode <m> --self <id> --created <json> --geometry <json>` — internal; used by § Create
  phase 3a. Not a user-facing command.

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
on pane sizes before any split has run — and `next-split` reads geometry rather than modelling it. A
predicted sequence would be approximate (it cannot know herdr's exact ratio behaviour) and would
diverge from what actually happens the moment a real split lands differently. Showing the real
decision, one at a time, is exact by construction.

Add to `skills/agent-roster/SKILL.md` § Create, as a subsection referenced from 3a:

> **§ Create manual-mode layout.** In `manual` mode, inside the 3a loop, after `next-split` returns and
> **before** running the split, show the user:
> - the iteration (`split 2 of 4`),
> - the target pane id and its current size in cells (from the geometry you just read),
> - the direction, and the mode that chose it.
>
> Offer: **accept** (run it as computed), **change direction** (`right`/`down`), **change target**
> (any existing pane id from the geometry — including panes this loop did not create), or **skip this
> split**. Run whatever the user settles on, then continue the loop; the next iteration re-reads
> geometry and re-computes from the real result, so an amendment is absorbed rather than compounding.
>
> **Skip** means that member gets no pane: it is carried into step 5's partial handling as a member
> that did not come up, exactly as a failed split would be. Say so when offering the option — a skip
> is not free, it degrades the Team.

### 8.2 What this pause is not

This is a pause **inside** 3a, before each split. It is **not** a pause between 3a and 3b: 0003 §5
forbids that explicitly, because a per-member pause there would re-serialize the batched launch phase
that 0003 exists to parallelize. Nothing here touches 3b, and nothing here re-serializes anything —
3a is already sequential by §6.5.

0003 §11.3 flagged "should manual offer a deliberate checkpoint between layout and launch" as an
undecided UX question. **This spec does not decide it** — every pause specified here is inside or
before 3a. §11.3 remains open and untouched.

## 9. Remaining evidence items — neither blocking

1. **Live check at N=4, `grid`.** Confirm the sequence produces a 2×2 on the right and that the
   orchestrator's pane is still half the screen. This is the acceptance evidence for the whole spec and
   must be run during the Implementor's verification phase (§11.4). It cannot be shortcut, and §13
   explains why it is the only real proof the result *looks* right.
2. **`herdr pane split --ratio FLOAT` semantics — deferred follow-up, do not implement here.** The live
   usage string exposes a `--ratio` flag this spec does not use. If `--ratio` sets the fraction retained
   by the *existing* pane, then `columns` could produce **exactly even** columns by chain-splitting the
   remainder at `1/(N-k)` on step `k`, removing §6.4's acknowledged "columns degrades past N=3" wart.
   Confirmed out of scope for this change: the greedy algorithm works with or without `--ratio` and
   already delivers the requested quadrant behaviour, and building on an unverified flag semantic is how
   §2.1 happened. If someone later verifies which pane the ratio applies to, it becomes a small,
   self-contained addition to `next-split`'s output (an optional `ratio` field).

## 10. Change list

| File | Change |
|---|---|
| `hooks/lib-roster.mjs` | Add `ROSTER_LAYOUT_VALUES` beside `ROSTER_ROUTE_VALUES` (`:21`). Add the **optional**-field `roster.layout` check to `validateRosterBlock`. `validateMember` untouched. |
| `hooks/lib-config.mjs` | `resolveRoster()` (298-321) returns `layout: r.layout \|\| "auto"` alongside `route`. Sole default site. |
| `hooks/roster.mjs` | herdr branch of `spawnShape()` → §5.1 (`layout: []`, `target_from: null`). Add `layoutPlan()` per §5.2 and `layout_plan` to the `--plan` output at `:278`. Add the pure `nextSplit()` function per §6.7 and its `next-split` subcommand. `init` accepts `--layout`. New `layout` subcommand. `show` reports `layout`. tmux and terminal branches untouched. |
| `skills/agent-roster/SKILL.md` | § Create: new step 0 (§7.1), rewritten 3a (§7.1), new § Create manual-mode layout subsection (§8.1). § init: new step 2b (§7.2). § Command surface: add `layout` and `next-split` (§7.3). **Step 3b untouched.** |
| `tests/test-roster-spawn.sh` | Replace the `:103-104` assertion (it asserts the defect). New assertions per §11.1. |
| `tests/test-roster-next-split.sh` | **NEW.** Unit tests for `next-split` per §11.3. |
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
7. 0002/0003 regression guards still pass: no `--model inherit` anywhere in `layout` or `launch`; the
   herdr `launch` contains no `--name`.

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

1. `--created '[]'` ⇒ `target` is `--self`, whatever the geometry (rule 1).
2. With `created` non-empty, `self` is **never** returned as the target, even when `self` has the
   largest area in `geometry` (rule 1's "at most once" — the highest-value assertion in this file, since
   it is the reported defect).
3. Largest-area member pane wins: give three created panes of areas 100/400/200 and assert the 400 one.
4. Tie → earliest in `created`: two equal-area panes, assert the one listed first, and assert the
   result is unchanged when `geometry`'s array order is reversed (order-independence).
5. `--mode columns` ⇒ `direction` is `right` for a tall target as well as a wide one.
6. `--mode grid`: target 90×42 ⇒ `right` (`90 > 84`); target 45×42 ⇒ `down` (`45 > 84` false); target
   exactly `width === height * 2` ⇒ `down` (the boundary is strict `>`).
7. `--mode auto` with `created.length === 0` or `1` behaves as `columns`; with `2` or more, as `grid`.
8. A `created` id absent from `geometry` ⇒ exit 2 with a named error, **not** a silent skip.
9. `next-split` performs no I/O: it succeeds with no herdr running and no `HERDR_ENV` set.

### 11.4 Live checks (herdr)

- N=4, `grid`: §9 item 1 — a 2×2 on the right, orchestrator still at half screen.
- N=5, `columns`: panes are narrow (expected) and the user was warned once (§6.4).
- Re-run `create` after `roster.mjs layout --layout columns`: step 0 shows `columns` as the current
  default and still asks.
- `manual`, N ≥ 3: a pause appears before **every** split, each showing the target's real current size;
  amending one split's direction is honoured and the following iteration re-computes from the actual
  result rather than from the original plan; skipping a split yields a `--partial` Team naming that
  member.

## 12. What must NOT change

1. **0003's launch mechanism.** `launch[]`, `target_placeholder`, `target_source`, and the phase-3b
   substitution are out of scope. Only the layout side moves. `target_from` changes value for herdr
   (`0` → `null`); its *meaning* for tmux is untouched.
2. **The batched launch phase.** 3b stays one message, one tool call per member. The sequential loop
   and the manual per-split pause are confined to 3a and only for herdr.
3. **The plan→commit two-step.** `--plan` resolves and reports; `--commit --verified … --transport …
   --roster-level …` writes the Team. The `--commit` branch, the `team` object literal, and the
   `CLAUDE_PID` / `--orchestrator-pid` behaviour with its comment are untouched.
4. **Check-in and partial success.** Poll every 2s, give up at 60s, fixed interval, not configurable.
   On partial, commit with `--partial`, name the missing members, do not tear down (0001 §13). Every
   new failure path here — a split that yields no pane id, a user-skipped split — funnels into that
   same outcome.
5. **`roster.mjs` spawns nothing, and `next-split` opens nothing.** It emits strings and templates, and
   does arithmetic over JSON arguments. No `execFileSync` beyond `detectTransport()`'s pre-existing
   tmux probe at `:119-127`.
6. **0002's fixes.** `--model inherit` stays omitted; the herdr path keeps passing `agentFlags`
   (no `--name`) after `--`; the `:130-131` comment survives.
7. **tmux and terminal transports.** Byte-identical to 0003. No layout_plan, no mode, no change.
8. **The derived-name scheme** (0001 §3.4) and `roster.route` semantics, including its required-ness.

## 13. Confidence and escalation

**High** — that layout must be orchestrator-driven rather than emitted by `roster.mjs`: the file has no
herdr connection and cannot see geometry. `next-split` is the seam that keeps the *rule* in tested code
while leaving the *geometry* to the only party that can observe it.

**High** — the herdr CLI mechanics. `--pane <id>` targeting, cell units, and whole-workspace inspection
are all confirmed from live output (§2.3), not from documentation. The aspect rule survived that check
unchanged.

**High** — that grid/columns are herdr-only concepts. `tmux new-window` subdivides nothing; there is no
zero-sum screen to allocate.

**High** — that `roster.layout` should be optional-with-default rather than required like
`roster.route`. Every roster written before this change lacks the key.

**Medium-high** — the algorithm's aesthetic outcome. The rules are deterministic and now unit-tested,
but the resulting arrangement is tab-size-dependent, as §6.4 shows: the same rule yields a different
split at 180×42 than at 200×50. That is correct behaviour rather than a defect, but it means §9 item 1's
live N=4 check is the only real proof the result *looks* like a quadrant. Do not skip it.

**No Ultra-Advisor escalation recommended.** The blast radius is one function's herdr branch, one new
optional config field, one pure helper, and prose. No persisted-format migration (`team.json` untouched,
old rosters valid by construction), no security surface, revertible in one commit.

**No open design questions.** Every NEEDS-CONFIRMATION raised during this spec's drafting has been
resolved by the user and folded into the body. §9's two items are verification evidence and a deferred
follow-up respectively, neither of which blocks implementation.
