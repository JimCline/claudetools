# Spec 0002 — `roster.mjs` / `agent-roster` skill: create-path defects

Status: **ready for implementation.** Defects observed 2026-08-22 across live `/agent-roster create`
runs in `~/git/repos/wrangl` against `ah` 0.32.3. One NEEDS-EVIDENCE item (§12.1) is scoped to a single
`claude --help` invocation the Implementor runs first; it does not block the rest.
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Auto-mode, Team, Check-in registry)
Related: `docs/specs/0001-agent-roster.md` §6 (`create` — instantiating a Team);
`docs/specs/0003-roster-create-perf.md` (the batched-launch / sequential-layout tradeoff revisited by §5);
`docs/specs/0004-roster-layout.md` — **amended by this spec's §5, §6 and §7**, see below.

> **Amended 2026-08-22 by `0006-disband-kill-by-default.md`.** §8.2's decision — keep plain `disband`
> safe, put the destructive form behind `--kill` — is **reversed** by user direction. Bare `disband` is
> now the close-plan call and `--keep-sessions` is the safe form. §8.1's two-call contract, §8.1's
> close-before-remove ordering, and §8.3's emit-don't-execute rule are all **unchanged** — only which
> flag selects which path changed. Read §8.2 as history.

## 1. Goal

Fix the defects that surfaced across two consecutive `create` runs against `wrangl`
(one 4-member, one 3-member after removing ultra-advisor) and the `disband` that
followed them:

| § | Defect | Where |
|---|---|---|
| 3 | A — `--model inherit` emitted literally | `hooks/roster.mjs:132` (`agentFlags`) |
| 4 | B — `ah:` rename shipped to source but not to installs | release, not source |
| 5 | C — herdr layout loop runs at model-turn granularity | `skills/agent-roster/SKILL.md` §Create 3a |
| 6 | D — `launch` never sets the Claude session's display name | `hooks/roster.mjs:132` (`agentFlags`) |
| 7 | E — `nextSplit()` freezes the orchestrator's pane out of the layout | `hooks/roster.mjs` `nextSplit()`/`direction()` |
| 8 | F — no one-shot teardown; `disband` orphans live sessions | missing command |

§3 and §6 both land on a single line — `hooks/roster.mjs:132`, the `agentFlags`
array inside `spawnShape()` — and are one edit between them.
§7's *rule* is owned by `0004` §6.2, which this spec amends rather than restates.
§5's fix (`layout-splits`) reverses `0004` §12 item 5, which is amended there.

## 2. How this surfaced

A `/agent-roster create` run against `wrangl` produced a plan whose `spawn.steps`
could not be executed as given. The orchestrating session copied the emitted steps
verbatim, which is exactly what `0001` §6 step 3 instructs it to do — the steps are
presented as concrete commands, so treating them as authoritative is the intended
behaviour, not operator error.

The first run was aborted before any agent started. Two panes were split and closed.
A later run, with `--name` patched in by hand, completed and produced the §7 trace.

## 3. Defect A — `--model inherit` is emitted literally

**Severity: live defect, present in source at 0.32.0 and in every installed cache.**

Line 132 builds the model flag as:

```js
member.model ? `--model ${member.model}` : null
```

`inherit` is a legal *config* value meaning "omit the `model` parameter". It is
never a model id. `commands/hierarchy.md` states this in two places, and
`lib-config.mjs` resolves it correctly for the Agent-tool path — the resolver's own
output annotates it (`inherit* … * inherit = omit the model parameter, never pass
"inherit"`). `spawnShape()` is the one place that does not honour it.

`ROLE_DEFAULTS.implementor` is `{ model: "inherit" }`, so **the default roster hits
this on every create.** A roster built entirely from defaults emits:

```
herdr agent start <repo>-implementor --kind claude --pane <id> -- \
  --agent ah:implementor --model inherit --permission-mode <mode>
```

`--model inherit` is not a valid model id, so the implementor pane fails to start.
Under `0001` §6 step 5 that is a partial check-in, and the Team commits degraded —
missing the one member that does the building.

### 3.1 Required change

Treat `inherit` as absent when building the flag, not as a value:

```js
member.model && member.model !== "inherit" ? `--model ${member.model}` : null
```

The check belongs in `spawnShape()` rather than at the call site: the same array
feeds all three transport branches (`herdr` L135, `tmux` L136, `terminal` L137), so
one guard covers every transport.

### 3.2 Why not fix it in the roster instead

Storing the implementor with no `model` key would also avoid the flag, but it
discards information: `inherit` is a deliberate, distinct choice from "unset", and
`lib-config.mjs` and `roster.mjs show` both surface it as such. The roster schema is
correct; the flag builder is what is wrong.

## 4. Defect B — the `ah:` rename shipped to source but not to the cache

**Severity: not a source defect. A release/install gap that presented as one. Closed
as of `0.32.3`; the durable part is §4.2.**

The agents were renamed from `agent-hierarchy:<role>` to `ah:<role>`. Source at
version `0.32.0` reflects this — line 132 reads `` `--agent ah:${member.role}` `` —
and the only remaining `agent-hierarchy:` strings anywhere in the tree are 39
occurrences confined to `docs/retired/` (historical design docs; correctly left
alone).

The newest installed cache at the time was `0.31.0`, where line 132 still read
`` `--agent agent-hierarchy:${member.role}` ``. That single line was the **only**
difference in `roster.mjs` between the two versions:

```
132c132
<   const agentFlags = [`--agent ah:${member.role}`, …
---
>   const agentFlags = [`--agent agent-hierarchy:${member.role}`, …
```

So every peer-routed member planned from the installed plugin named an agent type
that no longer resolves, and all peer spawns failed — while a reader of the source
tree saw correct code and could not reproduce it.

### 4.1 Required change

No source edit. Shipping `0.32.x` closed it (done at `0.32.3`).

### 4.2 The part worth fixing — in scope

The failure mode is the real finding: a `spawnShape()` regression is invisible until
a human runs `create` and watches panes die. Nothing compares the emitted `--agent`
value against the agent types that actually exist.

`tests/test-*.sh` is standalone bash with no harness (per `0001` §2). Add to the
**existing** `tests/test-roster-spawn.sh` (it already exists — `0004` §2.5 cites
`:103-104`) assertions that, for a roster exercising every role, each emitted step's
`--agent` argument names an agent definition present in `agents/`, and that no step
contains `--model inherit`. Both are string assertions over `create --plan` output —
no spawning, no transport, no live session.

Those assertions fail today on the `inherit` bug alone, which is the point: they
would have caught Defect A at author time and Defect B at install time.

## 5. Defect C — the herdr layout loop runs at model-turn granularity

**Severity: process defect in the skill, not in `roster.mjs`. Confirmed live: ~99% of
observed wall-clock in the layout phase was avoidable.**

The skill's §Create step 3a (layout, herdr transport) is genuinely sequential —
each split's target depends on the pane id the previous split returned, so the four
splits for a 4-member roster cannot be issued concurrently. That part is correct
and `0003` already reasoned about it.

What actually happened in the `wrangl` run: the orchestrating session executed that
sequential loop **one tool call per step** — `inspect` → `next-split` → `split`,
three tool calls per member, issued as three separate model turns each. For four
members that is 12 model-turn round trips before a single agent launches. The user
observed this as visibly slow pane creation.

Measured comparison, same repo, same 4-member roster, same `next-split` calls, same
`herdr` commands — only the harness changed:

| Execution shape | Wall clock |
|---|---|
| One tool call per step (12 model turns) | user-observed: slow, multi-second per split |
| Entire 4-split loop in one shell invocation | **0.58s** |

The dependency chain between splits is real; the *tool-call* chain is not. Nothing
requires the orchestrator to round-trip through the model between an `inspect`/`split`
pair — there is no reasoning to do between iterations, because `nextSplit()` already
picks the target and direction from the geometry.

### 5.1 Root cause

The skill hands the orchestrator four raw ingredients (`inspect_command`,
`next-split`, `split_command`, extraction paths) and describes them as a loop for
the *orchestrating session* to drive, one iteration at a time, in prose. Nothing in
`roster.mjs` performs the loop itself. The 0003 tradeoff analysis — batching saves
only `(N-1) × split_latency`, so the serial fallback is acceptable — measured the
wrong denominator: `split_latency` there is ~145ms per split, but the cost actually
paid was `3N` model-turn round trips, which dominates by roughly two orders of
magnitude.

### 5.2 The shell-loop technique — evidence only, NOT a SKILL.md instruction

The measurement above came from expressing the whole loop as one shell invocation
using only the pieces the plan already emits:

```sh
J='const o=JSON.parse(require("fs").readFileSync(0,"utf8"));'
created='[]'
for i in $(seq 1 "$PANE_COUNT"); do
  geom=$(herdr pane layout --current | node -e "$J console.log(JSON.stringify(o.result.layout.panes))")
  ns=$($ROSTER next-split --mode "$MODE" --pane-count "$PANE_COUNT" \
        --self "$HERDR_PANE_ID" --created "$created" --geometry "$geom")
  tgt=$(printf '%s' "$ns" | node -e "$J console.log(o.target)")
  dir=$(printf '%s' "$ns" | node -e "$J console.log(o.direction)")
  new=$(herdr pane split --pane "$tgt" --direction "$dir" --cwd "$PWD" --no-focus \
        | node -e "$J console.log(o.result.pane.pane_id)")
  echo "$new"
  created=$(printf '%s' "$created" | node -e "$J console.log(JSON.stringify(o.concat([process.argv[1]])))" "$new")
done
```

**This recipe is recorded here as the evidence for §5.3 and as a manual fallback if
`layout-splits` is ever unavailable. It does NOT go into `SKILL.md`.** Documenting
two ways to run the layout phase would reintroduce exactly the improvisation that
produced §2.1's hardcoded string: an orchestrator offered a choice will sometimes
take the hand-rolled one, and the hand-rolled one is untested.

One live pitfall it exposed, which §5.3 designs out entirely: this was first run
under `zsh`, where arrays are 1-indexed, while the follow-up script assumed bash's
0-indexing (`${ids[0]}`). That mismatch sent one launch to an empty pane target and
silently shifted every other member onto the wrong pane.

### 5.3 Required change — the `layout-splits` subcommand

**Decision (the user's, 2026-08-22): move the loop inside `roster.mjs`.** This
reverses `0004` §12 item 5's "`roster.mjs` spawns nothing" invariant, deliberately
and with a narrow, exhaustively-listed boundary. **`0004` §12 item 5 is amended to
state that boundary and is the authority on it** — read it before implementing.

Beyond the wall-clock win, this structurally enforces the "do not compute the target
yourself" rule: the orchestrator never sees the intermediate geometry, so it cannot
compute anything from it, and the shell-indexing pitfall disappears because no
orchestrator-authored shell script exists.

#### 5.3.1 Signature

```
roster.mjs layout-splits --mode <auto|columns|grid> --pane-count <N>
                         [--self <pane-id>] [--cwd <path>]

roster.mjs layout-splits --next  --mode <m> --pane-count <N>
                         [--self <pane-id>] --created '<json array of pane ids>'

roster.mjs layout-splits --apply --target <pane-id> --direction <right|down>
                         [--cwd <path>]
```

- **Bare form** — runs the whole `0004` §6.6 loop and returns every pane id.
- **`--next`** — reads geometry, computes one decision, **mutates nothing**. Manual
  mode's pause, and the only read-only form.
- **`--apply`** — performs exactly one split with the target and direction given,
  computing nothing. Manual mode's commit step, and the retry path for a failed
  split in the bare form.
- `--next` and `--apply` are mutually exclusive; both together ⇒ exit 2.
- `--self` defaults to `process.env.HERDR_PANE_ID`; absent and not passed ⇒ exit 2.
- `--cwd` defaults to `process.cwd()`; passed through to `herdr pane split --cwd`.
- `--pane-count 0` ⇒ `{"panes":[],"complete":true}`, exit 0. Not an error; the skill
  should not have called it (`layout_plan` is null), but a no-op is the kind answer.
- **Guard:** if `detectTransport() !== "herdr"`, exit 2 with a named message. One
  transport-detection implementation, the existing one.

#### 5.3.2 Implementation notes the Implementor will otherwise trip on

These come from the current shape of `hooks/roster.mjs`; all three are load-bearing.

1. **`parseArgs` (`:45-63`) swallows the following argv unless the key is in
   `BOOL_FLAGS`.** Add `manual`, `next`, and `apply` to `BOOL_FLAGS`, or
   `--next --mode grid` parses as `next: "--mode"`… actually as `next: true` only
   because the next token starts with `--`; `--apply --target x` would misparse the
   moment a bare value follows. Add them; do not rely on the `startsWith("--")`
   accident.
2. **`fail()` (`:65-68`) is the only exit path and always exits 2**, and the whole
   dispatch `switch` (`:210-397`) is wrapped in `try { … } catch (err) { fail(...) }`.
   A partial result therefore **cannot be thrown** — a thrown error becomes exit 2 and
   the caller loses the pane ids. Write the partial result to stdout and
   `process.exit(3)` directly inside the `layout-splits` case, before any throw can
   escape. Add a sibling helper next to `fail()` rather than inlining it:
   ```js
   function partial(obj) {
     process.stdout.write(JSON.stringify(obj, null, 2) + "\n");
     process.exit(3);
   }
   ```
3. **Add `layout-splits` to the usage string at `:396`**, alongside the other
   subcommands. It is the `default:` branch's only documentation.

#### 5.3.3 How it shells out

`execFileSync` is already imported and used by `detectTransport()` (`:126`).

```js
function herdrCall(args) {
  const timeout = Number(process.env.AH_HERDR_TIMEOUT_MS || 10000);
  const stdout = execFileSync("herdr", args, {
    encoding: "utf8",
    timeout,
    maxBuffer: 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return JSON.parse(stdout);
}
```

Requirements on this helper, all deliberate:

- **Argv array, never a shell string.** Pane ids and `--cwd` go through as argv
  elements, so nothing is shell-interpreted. This is strictly safer than the emitted-
  string path it replaces, where the skill interpolated a path into a shell command.
- **Bare `"herdr"`, resolved via PATH** — not an absolute path. This is what makes
  the §11.3 fake-binary tests possible.
- **A timeout is mandatory.** Without one a hung herdr hangs `create` indefinitely
  with no output. `AH_HERDR_TIMEOUT_MS` exists so §11.3 can test the timeout path in
  under a second instead of ten; it is a test seam, not a user-facing knob, and is
  not documented in `SKILL.md`.
- **This is the single exec site.** Every herdr call goes through `herdrCall`. §11.3
  asserts structurally that it is reachable only from `layout-splits`.
- A non-zero exit, a timeout, or unparseable stdout are all one failure kind: the
  thrown error's message is what lands in the `error` field below.

#### 5.3.4 Return shapes

**Bare form, complete** (exit **0**):

```json
{
  "panes": ["w2:p3", "w2:p4", "w2:p5"],
  "splits": [
    {"i": 1, "target": "w2:p1", "direction": "right", "pane_id": "w2:p3"},
    {"i": 2, "target": "w2:p1", "direction": "down",  "pane_id": "w2:p4"},
    {"i": 3, "target": "w2:p3", "direction": "down",  "pane_id": "w2:p5"}
  ],
  "mode": "grid", "pane_count": 3, "complete": true
}
```

**Bare form, partial** (exit **3**, JSON still on stdout):

```json
{
  "panes": ["w2:p3"],
  "splits": [{"i": 1, "target": "w2:p1", "direction": "right", "pane_id": "w2:p3"}],
  "mode": "grid", "pane_count": 3, "complete": false,
  "failed_at": 2,
  "attempted": {"target": "w2:p1", "direction": "down"},
  "error": "herdr pane split failed: <message>"
}
```

**`--next`** (exit 0, nothing mutated):

```json
{"index": 2, "pane_count": 3, "mode": "grid",
 "target": "w2:p1", "direction": "down",
 "target_rect": {"width": 90, "height": 42, "x": 4, "y": 1},
 "target_is_self": true,
 "geometry": [ /* the panes[] just read, so the caller can offer alternatives */ ]}
```

**`--apply`** (exit 0): `{"pane_id": "w2:p4", "target": "w2:p1", "direction": "down"}`

**Anything that prevented work from starting** — bad args, wrong transport, no
`--self`, `herdr` missing from PATH, the *first* inspect failing — is `fail()`,
exit **2**, no JSON. The distinction that matters: exit 2 means nothing happened;
exit 3 means something did and you must not throw it away.

#### 5.3.5 Failure policy: stop at the first failure, return what exists

The loop **stops** at the first failed `herdr` call. It does not continue to the
remaining iterations, because a failing call most often means the connection is gone
and N−k more failures are noise.

It **returns the panes it already created**, with `complete: false` and exit 3. Those
panes are real, they cost real work, and their members can still be launched into
them — discarding them would strand live panes with nothing in them and degrade the
Team further than the failure itself did. This is the same principle as `0001` §13's
partial check-in: report exactly what happened, never silently pretend.

`attempted` carries the decision the failed iteration had computed, so the caller can
retry that exact split via `--apply` without recomputing — and without needing the
geometry, which by then has changed.

**No internal retry.** One failure, one report. Retry is the caller's decision
(`0004` §7.1's 3a), because only the caller knows whether to retry, degrade, or stop.

## 6. Defect D — the launch command never sets the Claude session's display name

**Severity: live defect. Every peer member from the current plan fails check-in.**

`spawnShape()`'s `launch` array builds:

```
herdr agent start <derived-name> --kind claude --pane <target> -- \
  --agent ah:<role> [--model ...] --permission-mode <mode>
```

`<derived-name>` here only names the **herdr-side** agent record (the argument to
`herdr agent start`). It is never passed to the `claude` process itself. Claude Code
has a flag for exactly this — `-n, --name <name>: Set a display name for this
session` — and the emitted command omits it.

The consequence: `ListAgents` (step 4 of §Create) reports each session under Claude's
auto-generated display name (`wrangl-8f`, `wrangl-95`, … — a short random suffix on
the repo basename), never the roster's derived name (`wrangl-architect`, etc.). §4's
matching step — "match each spawned member's derived name" — cannot succeed for any
peer member as currently emitted; every `create` run degrades to a full check-in
timeout (60s) followed by a `--partial` commit, even though every session actually
came up and is idle.

This was previously correct: an earlier draft of the skill's §Create documented the
spawn as `claude --agent ah:<role> --model <model> --name <derived-name>`, i.e.
`--name` was in the contract. It was dropped when the command moved from
skill-authored prose into `spawnShape()`.

### 6.1 Required change

Add `--name ${member.name}` to the **`agentFlags` array** at `hooks/roster.mjs:132`,
immediately after the `--agent` element. `agentFlags` is interpolated after `--` by
all three transport branches, so one element covers every transport — the same
argument as §3.1. No schema change: `name` is already computed and present on
`member` when `spawnShape()` runs.

Do **not** add it per-branch to the three `launch` arrays; that would be three
places to regress instead of one.

### 6.2 Why this one is a "live defect" and not a release-lag issue

Unlike Defect B, this is present in `0.32.3`, the latest released version, and was
exercised directly: after adding `--name` by hand to all four launch commands in a
manual re-run, `ListAgents` matched all four sessions by derived name immediately,
and `create --commit` succeeded with `partial: false`. No other change was needed.

### 6.3 It contradicts a shipped assertion — fix the assertion

`0004` §11.1 item 7 asserted "the herdr `launch` contains no `--name`", and `0004`
§12 item 6 listed that as something that must not change. **Both were wrong and both
are amended in `0004` itself.** The Implementor will meet the old assertion in
`tests/test-roster-spawn.sh` if it was written; invert it, do not work around it.

## 7. Defect E — `next-split` freezes the orchestrator's own pane out of the layout

**Severity: layout-quality defect, confirmed live. Not a crash — every pane still
comes up and every agent still launches — but the resulting geometry is visibly
unbalanced, and gets worse as the panel of created panes grows relative to `self`.**

Design principle, stated by the user directly and now recorded in `0004` §6.2 rule 1:
**the orchestrator's own pane is one of the panes being laid out, on equal footing
with the member panes, from the first decision onward** — not a leftover shape that
the layout works around. A 3-member create is a 4-pane layout problem (self + 3
members), and `auto` should be choosing a shape for all 4.

### 7.1 Observed trace (3-member create, 4 panes total)

`nextSplit()` and `direction()` as shipped in `0.32.3`:

```js
function nextSplit({ mode, self, created, geometry }) {
  if (created.length === 0) return { target: self, direction: direction(self, mode, created, geometry) };
  const byId = new Map(geometry.map((g) => [g.pane_id, g.rect]));
  let target = null;
  let bestArea = -1;
  for (const id of created) {                         // <-- self is never in this loop
    const rect = byId.get(id);
    const area = rect.width * rect.height;
    if (area > bestArea) { bestArea = area; target = id; }
  }
  return { target, direction: direction(target, mode, created, geometry) };
}

function direction(target, mode, created, geometry) {
  const effectiveMode = mode === "auto" ? (created.length + 1 <= 2 ? "columns" : "grid") : mode;
  ...
}
```

| Split | Rule applied | Target | Result |
|---|---|---|---|
| 1 | `columns` (created.length+1=1≤2) | `self` | `self`→90×42, new→90×42 |
| 2 | `columns` (created.length+1=2≤2) | new pane (self excluded) | that pane→45×42, another new→45×42 |
| 3 | `grid` (created.length+1=3>2), target from `created` only | one 45×42 pane (self still excluded) | →two 45×21 panes |

Final: `self`=90×42 (**50% of total screen area**), one member pane=45×42 (25%),
two member panes=45×21 each (12.5%). `self` never re-entered the candidate pool, so
it kept the size it happened to get after split 1 while the "grid" logic only ever
subdivided the *other* three panes among themselves.

Two compounding causes:

1. **`self` is excluded from the "largest pane" search after the very first split.**
   The candidate loop only ranges over `created`. Whatever size `self` ends up at
   after split 1, it keeps forever.
2. **`effectiveMode` is decided from `created.length`** (splits done so far), never
   from the final target pane count (`layout_plan.pane_count`, already known before
   the first split runs). So `auto` commits to two unconditional `right` splits
   before it ever considers a grid.

### 7.2 What the expected layout looks like

For 4 total panes, the rules should produce four equal panes with `self` among them.
On a 200×50 tab that is literally `0004` §6.4's quadrant sequence — split `self`
down, then split each half — and it falls out without a special case once both
causes are fixed. On a 180×42 tab the same rules give four equal 45×42 columns.
Equal *area* is the invariant; a specific split sequence is not.

### 7.3 Required change — the rule lives in `0004`, amended

**`0004` §6.2 rule 1 has been reversed to match this defect's finding**, together
with §6.3's selector input, §6.4's worked tables, §6.6/§6.7's `--pane-count`
argument, and §11.3's unit tests. **Implement against `0004` §6.7's code shape**;
this section does not restate the algorithm and must not be treated as a competing
description of it.

What that amounts to in `hooks/roster.mjs`:

- `nextSplit()` iterates `[self, ...created]`, not `created`; the
  `created.length === 0` early return disappears (it becomes the same code path).
- `direction()` takes the resolved mode, and `effectiveMode` is computed from
  `paneCount` — a new **required** `--pane-count` argument on the `next-split`
  subcommand — never from `created.length`.
- A candidate id absent from `geometry` errors (exit 2), now including `self`.
- `layout-splits` (§5.3) calls this same `nextSplit()`. **One implementation of the
  rule**, one place it can be wrong, one place it is tested.
- Tests per `0004` §11.3, notably its amended item 2 (the shipped test asserting
  `self` is *never* the target encodes this defect and must be inverted) and its new
  item 11 (the 4-pane equal-area fixture this defect asks for).

The equal-area fixture belongs in `tests/test-roster-next-split.sh` alongside the
other `next-split` rules — **not** in a new `tests/test-roster-layout.sh`. One file
owns `next-split`'s behaviour; `layout-splits` gets its own file (§11.3).

## 8. Defect F — no one-shot teardown; `disband` leaves live sessions orphaned

**Severity: usability gap, confirmed live. Not a bug in what `disband` does — it
does exactly what it documents — but there is no command for what a user actually
wants at the end of a session: "tear the whole Team down."**

`disband`'s current contract (skill `## disband`) is deliberately narrow: it removes
`team.json` only, and **never** kills panes or sessions, "since they may hold work
that already cost tokens." That default is correct and must stay the default — it
matches the standing rule that in-flight work which already spent tokens is never
killed without asking first.

But there is currently no *second* command or flag that goes further once a human
has actually decided they want the sessions gone too. In the live session, closing
the three member panes after `disband` required the orchestrator to hand-run
`herdr pane close <id>` once per member, using transport ids the user had to ask
for — there is nothing a user can invoke directly that does "remove the Team and
close its sessions" as a single confirmed action.

### 8.1 Required change

Add an explicit, separate destructive form — `disband --kill`, a flag on the
existing command, not a silent change to plain `disband`'s behaviour. It is a
**two-call contract**, mirroring `create`'s existing `--plan`/`--commit` split in
this same file, precisely so removal cannot happen before the real closes do:

**`disband --kill --plan`** (read-only, no removal):

1. Read `team.json` and capture the member list (`role`, `name`, `transport_id`,
   `route`, and the team's recorded `transport`).
2. Emit a close command for each peer-routed member with a non-null `transport_id`,
   by the team's recorded transport:
   - `herdr` — `herdr pane close <transport_id>` (verified live in this session).
   - `tmux` — `tmux kill-pane -t <transport_id>`. `transport_id` is a tmux
     `#{pane_id}`, captured by 0003's `-P -F '#{pane_id}'`; killing the sole pane of
     a `new-window`-created window closes the window with it.
   - `terminal` — `null`; a backgrounded process has nothing addressable to close.
   - subagent-routed members — `null`; `transport_id` is already null.
   `team.json` is untouched by this call — it can be run, inspected, and even
   abandoned with zero effect on the registry.

**`disband --kill --commit`**: removes `team.json`. Nothing else. The skill calls
this **only after** it has actually run the emitted close commands — never before,
never as part of the same call that emitted them.

**Ordering note:** this deliberately inverts the earlier draft's remove-then-close
order, and the two-call split exists because a single combined call cannot honor
that order — the skill needs the close commands back before it can run them or
prompt the user, so any removal folded into that same call necessarily happens
before the real closes, not after. Closing first means an interrupted teardown
(the skill crashes, the user declines at the prompt, a close fails) still leaves
`team.json` with the ids needed to retry; removing first means the ids are gone and
the user is back to hand-hunting pane ids, which is the exact problem this defect
is about.

The skill runs the emitted commands and reports, per member, whether its session
was actually closed or the close call failed (e.g. the pane was already gone) —
the same "say exactly what happened, never silently pretend" standard `0001` §13
sets for partial check-in. A failed close is reported, not fatal, and `--commit`
still runs afterward — a failed *close* is not a reason to leave `team.json` around
for a session that may in fact already be gone.

`--kill` must still go through the standing confirmation rule for hard-to-reverse
actions: the skill prompts once ("this will close N live sessions — proceed?"),
using `--plan`'s output, before running any close command or calling `--commit`.

### 8.2 Why not just make plain `disband` always kill

Rejected: it would silently invert a documented, deliberate safety default, and
would make `disband` unsafe to run reflexively (e.g. from a script, or as a
"just in case" cleanup step) the way it currently is. A separate opt-in form keeps
the safe default and adds the convenience, rather than trading one for the other.

### 8.3 `disband --kill` emits; it does not execute

**`roster.mjs disband --kill --plan` prints the close commands; `--commit` removes
`team.json`. Neither call runs a close command — the skill runs them, between the
two.** This holds even though §5.3 gives `roster.mjs` the ability to execute herdr
commands — see `0004` §12 item 5's boundary: the carve-out is for the *layout
loop*, whose arguments depend on the previous call's result. Teardown is a flat
list of independent commands, so emitting costs nothing, and killing a live session
is precisely the verb that should stay outside this file. "May split a pane" did
not become "may close one".

The two-call split (rather than one call doing both) is itself load-bearing, not
just tidiness: a single call that both emits the close commands and removes
`team.json` has no way to keep the removal *after* the skill has actually run those
commands, since the skill cannot run them before it has received them. Folding
removal into the emitting call is what produced the exact bug §8.1's ordering note
warns against.

`--plan` output shape:

```json
{"close": [{"role": "architect", "name": "wrangl-architect", "route": "peer",
            "transport": "herdr", "transport_id": "w2:p3",
            "command": "herdr pane close w2:p3"}, …]}
```

`command` is `null` for terminal- and subagent-routed members. The skill runs every
non-null `command` in **one** Bash invocation (same reasoning as §5), reports
per-member outcome, and only then calls:

`--commit` output shape:

```json
{"removed": "<path to team.json>"}
```

`--commit` takes no other arguments and does not re-read the member list — it
removes whatever `team.json` currently exists at the resolved path, exactly like
plain `disband`. If no active team exists when `--commit` runs (e.g. it was already
removed, or the skill retries after a partial run), report `{"removed": false,
"reason": "no active team"}` rather than erroring — same posture as plain `disband`
on a missing team.

## 9. Change list

| File | Change |
|---|---|
| `hooks/roster.mjs` L132 (`agentFlags`) | Guard `inherit` in the `--model` flag (§3.1); add `--name ${member.name}` after `--agent` (§6.1). One array, one edit, all three transports. |
| `hooks/roster.mjs` `nextSplit()` / `direction()` | Rewrite per `0004` §6.7: candidates `[self, ...created]`, `effectiveMode` from a new required `--pane-count`, error on any candidate missing from geometry (§7.3). |
| `hooks/roster.mjs` `next-split` subcommand | Add required `--pane-count <N>`; exit 2 when absent. |
| `hooks/roster.mjs` — **new** `layout-splits` subcommand | Bare / `--next` / `--apply` forms, `herdrCall()` single exec site, exit 0/2/3 contract (§5.3). |
| `hooks/roster.mjs` `BOOL_FLAGS` (`:45-63`) | Add `manual`, `next`, `apply` (§5.3.2 item 1). |
| `hooks/roster.mjs` — **new** `partial()` helper beside `fail()` (`:65-68`) | stdout + `process.exit(3)`, not throwable (§5.3.2 item 2). |
| `hooks/roster.mjs` usage string (`:396`) | Add `layout-splits` (§5.3.2 item 3). |
| `hooks/roster.mjs` `disband` | Add `--kill --plan` (emit per-member close commands, no removal) and `--kill --commit` (remove `team.json` only) as two separate calls, not one (§8.1, §8.3). |
| `hooks/lib-roster.mjs` | Add `AUTO_MODE_VALUES` and an optional-field `auto_mode` check to `validateMember` (§12.1). |
| `skills/agent-roster/SKILL.md` §Create 3a | Call `layout-splits` (one command), per `0004` §7.1. **Do not** document §5.2's shell recipe. |
| `skills/agent-roster/SKILL.md` § Create manual-mode layout | `--next` / `--apply` per iteration (`0004` §8.1). |
| `skills/agent-roster/SKILL.md` §disband | Document `--kill`: the `--plan`/`--commit` split, the one-time confirmation between them, the emitted-commands contract, the per-member report (§8.1, §8.3). |
| `tests/test-roster-spawn.sh` (existing) | Assert every emitted `--agent` names an agent in `agents/`; assert no `--model inherit`; assert every peer `launch` contains `--name <derived-name>` — **inverting** the shipped no-`--name` assertion (§4.2, §6.1, §6.3). |
| `tests/test-roster-next-split.sh` (existing) | Invert `0004` §11.3 item 2; add its items 7, 9 and 11 (§7.3). |
| `tests/test-roster-layout-splits.sh` (new) | Fake `herdr` on PATH; the whole §11.3 list. |
| `tests/test-roster-disband.sh` (new) | `disband` unchanged; `--kill --plan` emits the right commands per transport, `null` for terminal/subagent, and does not touch `team.json`; `--kill --commit` removes `team.json` and nothing else (§11 items 11-13). |
| `docs/specs/0004-roster-layout.md` | **Already amended** — §6.2 rule 1 reversed, §12 item 5 boundary rewritten, §5.2/§6.5/§7.1/§7.3/§11 updated. No further edit. |
| — | Release the `ah:` rename (§4.1) — done at `0.32.3`. |

## 10. What must NOT change

- The roster schema. `inherit` stays a storable, displayable member model.
- `docs/retired/**`. Its `agent-hierarchy:` strings are historical record.
- `0001` §6's instruction that the orchestrator spawns from the plan's emitted
  steps. The steps must become correct; the contract that they are runnable as
  given is the right one and should hold.
- The genuine sequential *dependency* between splits (§5) — only the granularity at
  which that dependency is executed changes, not the ordering.
- **`0004` §12 item 5's amended boundary.** `roster.mjs` may now run
  `herdr pane layout` / `herdr pane split`, from `layout-splits` only. It still never
  starts a process (`claude`, `herdr agent start`, `tmux new-window`) and never
  destroys one (§8.3). Every other subcommand stays connection-free, and §11.3
  asserts that at runtime.
- The design principle behind §7: the orchestrator's own pane is a full member of
  the layout, not a special case. Do **not** add a compensating special case — no
  minimum size for `self`, no reserved half.
- Plain `disband`'s current safe default (§8) — it must keep never killing sessions
  on its own. The one-shot teardown is strictly additive, behind its own explicit
  flag and its own confirmation.
- 0003's batched **launch** phase (3b). Nothing here touches it.

## 11. Verification

### 11.1 Plan and flag checks (no transport)

1. `roster.mjs create --plan` on a default roster (implementor model `inherit`)
   emits no `--model` flag for the implementor, and `--agent ah:implementor`.
2. A roster with an explicit `--model opus` still emits `--model opus`.
3. All three transport branches (`herdr`, `tmux`, `terminal`) are covered by 1–2.
4. Every peer member's `launch` includes `--name` matching its derived name, after
   the `--`, on all three transports.
5. The updated `test-roster-spawn.sh` fails against `0.32.3` (missing `--name`) and
   passes once §3.1 and §6.1 land.

### 11.2 `next-split` unit checks

Per `0004` §11.3 in full, including: `self` returned as target when largest with
`created` non-empty; `--pane-count 3` yielding `grid` on the very first call; the
4-pane equal-area fixture passing from both a 180×42 and a 200×50 start rect.

### 11.3 `layout-splits` checks (`tests/test-roster-layout-splits.sh`, new)

`layout-splits` is the one subcommand that cannot be tested connection-free. Test it
with **a fake `herdr` on PATH**, the technique `test-roster-spawn.sh:27-32` already
uses for `tmux` (`$SANDBOX/bin/<name>` + `PATH="$SANDBOX/bin:$NODE_DIR"`).

The fake must be **stateful** — a stub that returns fixed geometry would let a loop
that never actually splits anything pass. Write it as a small node script keeping a
JSON state file of panes:

- `pane layout --current` → prints the `0004` §2.3 envelope from current state.
- `pane split --pane X --direction D` → halves X's rect along D (`floor` / remainder,
  per `0004` §11.3 item 11), appends a new pane, saves state, prints
  `{"result":{"pane":{"pane_id":"…"}}}`.
- `FAKE_HERDR_FAIL_ON=<n>` → the nth `pane split` exits non-zero.
- `FAKE_HERDR_SLEEP=<ms>` → sleeps before responding, for the timeout path.

Assertions:

1. **Happy path.** `--pane-count 3 --mode grid` ⇒ exit 0, `complete: true`, `panes`
   has 3 distinct non-empty ids, `splits` has 3 entries with `i` 1..3.
2. **It actually split.** The fake's final state has 4 panes, and their areas are
   within 5% of each other — the end-to-end form of `0004` §11.3 item 11. Run from
   both a 180×42 and a 200×50 initial state.
3. **`self` participates.** At least one `splits[].target` equals `--self`, and for
   `--pane-count 3` more than one does. This is the end-to-end guard for Defect E.
4. **Partial.** `FAKE_HERDR_FAIL_ON=2 --pane-count 3` ⇒ **exit 3**, JSON on stdout,
   `panes` has exactly 1 id, `complete: false`, `failed_at: 2`, `attempted` carries a
   target and direction, `error` is non-empty. The already-created pane still exists
   in the fake's state — it was not cleaned up.
5. **Nothing-happened is exit 2, not 3.** `FAKE_HERDR_FAIL_ON=1` ⇒ exit 2 (the first
   split failed, no panes created, nothing to hand back) — assert the caller can
   distinguish the two cases by exit code alone.
6. **`herdr` absent from PATH** ⇒ exit 2, named message, no JSON.
7. **Timeout.** `FAKE_HERDR_SLEEP=2000 AH_HERDR_TIMEOUT_MS=300` ⇒ non-zero exit with
   a message naming the timeout, in well under 2s. Proves the timeout is wired.
8. **Wrong transport.** With `HERDR_ENV` unset and a fake `tmux` present, exit 2 with
   a named message; the fake `herdr` is never invoked.
9. **`--next` mutates nothing.** Exit 0, returns a decision and `geometry`, and the
   fake's state is byte-identical afterwards.
10. **`--apply` computes nothing.** Given a target and direction that `next-split`
    would *not* have chosen, it splits that target in that direction anyway.
11. **`--next --apply` together** ⇒ exit 2.
12. **`--pane-count 0`** ⇒ exit 0, `{"panes":[],"complete":true}`, fake never invoked.

**The connection-free invariant, asserted at runtime.** Put a fake `herdr` on PATH
that `touch`es a marker file and exits 1. Run `show`, `init`, `add`, `edit`,
`remove`, `layout`, `next-split`, `create --plan`, `create --commit`,
`disband --kill --plan` and `disband --kill --commit`. Assert the marker file was
**never created** — no subcommand but
`layout-splits` reaches `herdrCall`. (`detectTransport()`'s `tmux` probe is the one
pre-existing exception and is unaffected: it never calls `herdr`.) Back this with a
grep assertion that `herdrCall(` appears only inside the `layout-splits`
implementation, so a future caller has to defeat both.

### 11.4 Live checks

6. A live `create` on a 4-member herdr roster: `ListAgents` matches all four members
   by derived name on the first check-in poll (no 60s timeout, no `--partial`).
7. The whole auto-mode layout phase is **one** tool call, not `3N`.
8. A live 3-member create (self + 3 = 4 panes) produces four visibly equal panes,
   `self` among them. 1- and 2-member creates still resolve to `columns`
   (`pane_count ≤ 2`) — unchanged by §7.3.
9. `manual`, N ≥ 3: `--next` pauses before every split; an amended direction is
   honoured and the next `--next` recomputes from the actual result; a skipped split
   yields a `--partial` Team naming that member.
10. `disband` (no flag) still only removes `team.json` and leaves every session
    running, unchanged from today.
11. `disband --kill --plan` on a live Team emits one close command per peer member
    with a non-null `transport_id`, `null` for terminal- and subagent-routed
    members, and leaves `team.json` untouched; the skill prompts once before
    running any of them, then calls `disband --kill --commit` to remove
    `team.json`; per-member outcome is reported.
12. `disband --kill` when a pane is already gone: the close reports failure for that
    member and the run still completes and `--commit` still removes `team.json`.
13. `roster.mjs add --auto-mode nonsense` is rejected; `--auto-mode auto` and
    `--auto-mode bypassPermissions` are both accepted, the latter with the §12.1
    warning.

## 12. Open items

### 12.1 `auto_mode` validation — IN SCOPE, with one NEEDS-EVIDENCE

Confirmed a real gap by the live run: `roster.mjs add`/`edit` accepts
`--auto-mode bypassPermissions` (or any string) with no check against Claude Code's
actual `--permission-mode` choices. `bypassPermissions` is a *valid* Claude Code
value but shows a startup confirmation screen, which left all four peer sessions in
that run `agent_not_ready` — up, but never reaching a prompt — until the auto-mode
was corrected to `auto`.

Decided:

- Add `export const AUTO_MODE_VALUES = [...]` to `hooks/lib-roster.mjs` and check
  `member.auto_mode` in `validateMember` using the **optional-field** style
  (`!== undefined && !== null && !VALUES.includes(...)`), matching the sibling
  member fields. `add`/`edit`/`init` reject an out-of-set value with a message
  naming the allowed set.
- **Warn, do not reject, on `bypassPermissions` for a peer-routed member.** It is a
  legitimate choice and rejecting a valid Claude Code value would be the tool
  overruling the user; but it reliably strands a headless peer at a confirmation
  screen, so the CLI says so once at `add`/`edit` time and the skill repeats it at
  `create` time. *(Architect decision, confirmed by the user 2026-08-22.)*

**NEEDS-EVIDENCE (Implementor, before writing the list):** run `claude --help` on
the installed version and take the `--permission-mode` choices from it verbatim.
The set observed during the live run was `acceptEdits`, `auto`, `bypassPermissions`,
`manual`, `dontAsk`, `plan` — treat that as the expectation, not the source. If the
installed help disagrees, use the help and note the discrepancy in the PR rather
than shipping a list that rejects a value Claude Code accepts. If `--help` does not
enumerate them, stop and report rather than guessing: a wrong enum here turns a
working roster into an unwritable one.

### 12.2 Deferred — not in this pass

- **Per-role model-set validation.** Whether `spawnShape()` should validate
  `member.model` against the per-role valid sets (`commands/hierarchy.md`: reasoning
  roles reject `haiku`; `ultra-advisor` is `fable`/`opus` only). Out of scope:
  `inherit` is a type error, whereas an out-of-set model is a policy question, and
  it wants the same "warn vs reject" decision §12.1 just made — worth doing together
  with that precedent settled, in its own change.
- **Plan staleness stamp.** Whether the plan should carry a checksum or version
  stamp so an orchestrator can notice it is planning from a stale install (§4's
  failure mode). Genuinely useful, genuinely separate — a contract addition to the
  plan, not a defect fix.
- **`herdr pane split --ratio`** — `0004` §9 item 2.

## 13. Confidence and escalation

**High** — Defects A and D (§3, §6). Both are one array, both were exercised live,
both have a directly observed before/after. The `--name` fix took check-in from a 60s
timeout to an immediate four-way match in a manual re-run.

**High** — Defect E's fix (§7.3). The rule is specified in `0004` §6.7 as code, the
failure it repairs is traced in §7.1, and the equal-area property is now an assertion
rather than an aesthetic judgement — at both the unit level and end-to-end (§11.3
item 2).

**Medium-high** — `layout-splits` (§5.3), and this is the least-proven part of the
pass. In its favour: the loop body is already specified and tested (`nextSplit()` is
unchanged and shared), the two herdr verbs are live-verified, argv-array exec removes
a shell-injection surface the emitted-string path had, and the fake-binary harness
covers every failure branch including timeout and partial. Against it: this is the
first code in the plugin that mutates the user's screen, the failure modes (hung
herdr, mid-loop partial) are new rather than inherited, and none of it has run
against real herdr yet. §11.4 item 7 is the acceptance check.

**Medium-high** — §8's `disband --kill`. The herdr close is verified live; the tmux
close is inferred from 0003's `#{pane_id}` capture and is the standard tmux verb, but
was not exercised. Low blast radius: it is behind a new flag, prompts first, and
§8.3's emit-don't-execute shape means a wrong command is visible before it runs.

**Medium** — §12.1's enum, until the `claude --help` evidence lands. That is why it
is written as NEEDS-EVIDENCE with an explicit stop-and-report rather than a list to
copy.

### 13.1 On the invariant reversal — a note, not an objection

The user has decided to reverse `0004` §12 item 5, and this spec implements that
decision. Recording what it costs, since the decision is now permanent and the next
reader will not have been in the conversation:

- **What was bought:** the layout phase drops from `3N` model turns to one tool call,
  and the "do not compute the target yourself" rule becomes structural rather than
  advisory — an orchestrator that never sees intermediate geometry cannot misuse it.
  Given that §2.1's original defect *was* an orchestration detail encoded in the wrong
  place, this is a real architectural improvement, not only a speed one.
- **What was spent:** one subcommand can no longer be tested without a fake binary on
  PATH (contained — §11.3 pins the rest at runtime), and "this file executes nothing"
  is no longer available as a flat answer to the next proposal that wants to execute
  something. That second cost is the one worth watching. `0004` §12 item 5 is
  therefore written as an **exhaustive list** with an explicit "decision, not a slope"
  clause, and §8.3 exercises it immediately by keeping `disband --kill` on the
  emit side of the line even though the mechanism to execute now exists.

**No Ultra-Advisor escalation recommended**, including for the reversal. Everything
here is small and reversible: no persisted-format migration (`team.json`'s shape is
unchanged; `auto_mode` validation only tightens what *new* writes accept), no security
surface reduced (the argv-array exec slightly improves it), no public interface beyond
new CLI flags. The one destructive addition (`--kill`) is opt-in, prompts first, and
emits rather than executes.

What *would* change that answer: any proposal to let `roster.mjs` start or kill a
process. That is a different risk class from splitting a pane, and §12 item 5 is
written so such a proposal has to arrive as a spec rather than as a refactor.
