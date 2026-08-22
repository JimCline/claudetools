# Spec 0003 — `/agent-roster create`: phase the spawn so members come up concurrently

Status: draft (slowness reported 2026-08-22; design only, nothing implemented)
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Auto-mode, Team, Check-in registry)
Related: `docs/specs/0001-agent-roster.md` §6 (`create` — instantiating a Team), §13 (partial check-in);
`docs/specs/0002-roster-spawn-defects.md` (the previous `spawnShape()` fix)

## 1. Goal

Make `/agent-roster create` stand up an N-member Team in roughly the time of the
*slowest single member* rather than the *sum of all members*, by splitting each
member's spawn commands into a **layout** phase and a **launch** phase so the
orchestrating session can batch each phase into one turn of concurrent tool calls.

Two things fall out of the same change and are in scope because the restructure
requires them:

- **A latent tmux defect** (`§4.3`): the emitted `tmux send-keys` has no target, so
  it types into whatever pane happens to be active. Batching would break it
  immediately; it is already fragile serially.
- **A pane-readiness race** (`§6.4`): the current split-then-immediately-start
  ordering gives the freshly-spawned shell no time to reach its prompt. Phasing
  removes the race rather than adding one.

`hooks/roster.mjs` remains pure file I/O and spawns nothing. This spec changes the
*strings it emits and their grouping*, never what it executes.

## 2. Current state — evidence

### 2.1 Where the time goes

`roster.mjs create --plan` does zero spawning. All spawning happens in the
orchestrating session, driven by `skills/agent-roster/SKILL.md` § Create step 3:

> 3. **Spawn every peer-routed member** using its `spawn.steps`, via Bash (or
>    the `herdr` skill's tools when transport is `herdr`) — one running
>    `claude --agent ah:<role> --model <model> --name <derived-name>` (plus
>    `--effort <e>` / `--permission-mode <a>` when set) per member, in the repo root.

`spawn.steps` is a single flat array per member holding *both* the layout command
and the launch command, so the only reading of step 3 available to the orchestrator
is: for each member, run its steps in order, then move to the next member. That is
one full split→start→wait cycle per member, serialized.

The blocking element is the second step. Per the `herdr` skill's documented
semantics:

> A successful `agent start` returns only after Herdr detects the expected agent in
> the same pane and considers it ready for interactive input. … Startup defaults to
> a 30-second timeout.

So for N peer-routed members, wall clock is approximately
`N × (split_latency + agent_ready_wait)`, with `agent_ready_wait` bounded at 30s.
A default roster has up to 5 peer-routed members. The split is local IPC and
cheap; the ready-wait dominates and is multiplied by N.

### 2.2 What is *not* the bottleneck

Step 4 (check-in) is already a single shared poll across all members —
"**Poll every 2 seconds, give up at 60 seconds** — fixed interval, not backoff;
this is not configurable" — and is not multiplied by N. It is untouched by this
spec. Note also that under the current serial design `agent start` has *already*
blocked until ready, so check-in usually resolves on its first poll; that stays
true after this change, because the launch batch is likewise awaited before
step 4 begins.

### 2.3 The current emitted shape

`hooks/roster.mjs:129-138`:

```js
function spawnShape(member, transport) {
  // herdr's own `--name` positional already names the pane/agent — duplicating
  // it after `--` would pass claude a second, redundant --name.
  const agentFlags = [`--agent ah:${member.role}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null].filter(Boolean);
  const claudeFlags = [...agentFlags, `--name ${member.name}`];
  const claudeCmd = `claude ${claudeFlags.join(" ")}`;
  if (transport === "herdr") return { transport, steps: [`herdr pane split --current --direction right --cwd "${cwd}" --no-focus`, `herdr agent start ${member.name} --kind claude --pane <pane-id-from-split> -- ${agentFlags.join(" ")}`] };
  if (transport === "tmux") return { transport, steps: [`tmux new-window -c "${cwd}"`, `tmux send-keys ${JSON.stringify(claudeCmd)} Enter`] };
  return { transport, steps: [`${claudeCmd} --bg`] };
}
```

Called once per member at `:276`, inside the `create --plan` handler, and emitted
at `:278` as `out({ level, path, transport, members: plan })`.

### 2.4 Consumers of `spawn.steps` — complete

A repo-wide grep for `spawn.steps` / `"steps"` / `'steps'` across `.mjs`, `.js`,
`.md`, `.json`, `.ts` returns exactly two hits:

- `skills/agent-roster/SKILL.md:120` — the step-3 prose above.
- `docs/specs/0002-roster-spawn-defects.md:17` — narrative prose describing a past run.

There is **no** programmatic consumer, no JSON-schema file, and no `.test.*`/`*test*.mjs`
harness selecting on it. `steps` can therefore be **replaced**, not aliased. See §7
for the one shell test that asserts over `create --plan` output.

### 2.5 The `terminal` transport already has no layout phase

`return { transport, steps: [`${claudeCmd} --bg`] };` — a single background process
launch, no pane, no window, no target. Under a batched step 3 this transport gets
the full speedup for free with no structural change beyond `steps` → `launch`.

## 3. Design decision — phase, and batch both phases

Adopt the phase split. The orchestrating session can issue multiple independent
tool calls in a single response and they execute concurrently; that is the primitive
this whole change exists to unlock, and a per-member `steps` array is precisely what
prevents step 3 from using it.

Batch **both** phases, not just the launch phase, but with asymmetric confidence and
an explicit guard (§6.2). Rationale:

- Batching the **launch** phase is where essentially all the saving lives:
  `N × ready_wait` collapses to `max(ready_wait)`. High confidence.
- Batching the **layout** phase saves only `(N-1) × split_latency`, which is small.
  It is nonetheless worth doing, because *not* batching it costs N sequential
  assistant turns — model round-trip latency, which is not obviously cheaper than
  the splits themselves. Medium confidence, guarded by the §6.2 assertion and a
  serial fallback.

## 4. Required change A — `spawnShape()` emits two phases plus a target contract

### 4.1 The new shape

Replace `steps` with five fields:

| field | type | meaning |
|---|---|---|
| `transport` | string | unchanged |
| `layout` | `string[]` | commands that create the destination. May be empty. Safe to run for all members in one batch, subject to §6.2. |
| `launch` | `string[]` | commands that start the agent in that destination. Run only after this member's `layout` succeeded. |
| `target_placeholder` | `string \| null` | the literal substring inside `launch` to substitute with the id produced by `layout`. `null` when `launch` has no hole. |
| `target_from` | `number \| null` | index into `layout` whose output yields the target id. `null` when `target_placeholder` is `null`. |
| `target_source` | object \| null | how to extract the id from that command's result. See §4.2. |

`target_placeholder` is deliberately a *declared* string rather than a convention the
skill has to know per transport — 0002's root cause was a plan whose emitted commands
were treated as authoritative and were not runnable as given. A named, machine-checkable
hole is harder to get silently wrong than the current bare `<pane-id-from-split>` prose.

### 4.2 `target_source`

- herdr — `{ "kind": "json", "path": ".result.pane.pane_id" }`. `herdr pane split`
  returns JSON; the new pane is `.result.pane`. The `herdr` skill is explicit that
  IDs must be parsed from JSON responses and not derived from sidebar order or examples.
- tmux — `{ "kind": "stdout", "trim": true }`. `tmux new-window -P -F '#{pane_id}'`
  prints the new pane id on stdout and nothing else.
- terminal — `null`.

### 4.3 The tmux target defect — must be fixed here

The current tmux launch step is:

```js
`tmux send-keys ${JSON.stringify(claudeCmd)} Enter`
```

There is **no `-t` target**. `send-keys` writes to the session's currently-active
pane. Serially this happens to work only because `tmux new-window` makes the new
window active immediately before it. That is incidental, not designed: any focus
change between the two steps — including a second member's `new-window` — retargets
it. With a batched launch phase, N untargeted `send-keys` would all race for one
active pane and the result would be N `claude` invocations typed into a single
window.

This is a correctness fix the perf work requires, not an optional cleanup. Capture
the pane id at creation and target it explicitly.

### 4.4 The exact replacement function

```js
function spawnShape(member, transport) {
  // herdr's own `--name` positional already names the pane/agent — duplicating
  // it after `--` would pass claude a second, redundant --name.
  const agentFlags = [`--agent ah:${member.role}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null].filter(Boolean);
  const claudeFlags = [...agentFlags, `--name ${member.name}`];
  const claudeCmd = `claude ${claudeFlags.join(" ")}`;
  if (transport === "herdr") return {
    transport,
    layout: [`herdr pane split --current --direction right --cwd "${cwd}" --no-focus`],
    launch: [`herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`],
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
  if (transport === "tmux") return {
    transport,
    // -P -F prints the new window's pane id: an untargeted `send-keys` writes to
    // whatever pane is active, which cannot survive two launches being in flight.
    layout: [`tmux new-window -P -F '#{pane_id}' -c "${cwd}"`],
    launch: [`tmux send-keys -t <TARGET> ${JSON.stringify(claudeCmd)} Enter`],
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "stdout", trim: true },
  };
  return { transport, layout: [], launch: [`${claudeCmd} --bg`], target_placeholder: null, target_from: null, target_source: null };
}
```

Everything above the transport branches is **unchanged**, including 0002's
`member.model !== "inherit"` guard and the `agentFlags`/`claudeFlags` split that
keeps a second `--name` off the herdr path. Do not restructure it.

### 4.5 What does not change in `roster.mjs`

`:276` (`spawn: route === "peer" ? spawnShape(m, transport) : null`) and `:278`
(`out({ level, path, transport, members: plan })`) are untouched. The plan stays
per-member; there is no new plan-level array. `spawnShape` keeps its per-member
contract and builds both phases itself.

## 5. Required change B — `SKILL.md` § Create step 3

Replace step 3 in `skills/agent-roster/SKILL.md` (currently lines 118-124) with a
two-phase, explicitly-batched instruction. Steps 1, 2, 4, and 5 are unchanged.

New step 3 text:

> 3. **Spawn every peer-routed member in two batched phases.** Do not run one
>    member's full sequence before starting the next — that serializes an
>    `agent start` wait per member.
>
>    **3a — Layout.** Issue every peer-routed member's `spawn.layout` commands
>    **in a single message**, one tool call per member, so they run concurrently.
>    Skip members whose `layout` is empty (the `terminal` transport has none).
>    From each result, extract that member's target id using its `target_source`:
>    `kind: "json"` means read the given path out of the JSON response;
>    `kind: "stdout"` means take stdout and trim it.
>
>    **Assert before continuing:** you must hold one non-empty target id per member
>    that had a `layout`, and they must all be distinct. If any is missing, empty,
>    or duplicated, re-run the affected members' `layout` commands **one at a time**
>    and use those results; if a member still yields no target, treat it as a member
>    that did not come up and carry it into step 5's partial handling.
>
>    **3b — Launch.** Substitute each member's target id for its
>    `target_placeholder` inside its `launch` commands, then issue every member's
>    `launch` **in a single message**, one tool call per member. Members with
>    `target_placeholder: null` need no substitution.
>
>    If a launch reports that the pane is not available or not at a prompt, retry
>    that one member's launch once before treating it as failed — the shell may not
>    have reached its prompt yet.
>
>    Subagent-routed members are never spawned here — they stay ordinary Agent-tool
>    dispatches, recorded in the Team with `name`/`ref`/`transport_id` null.

The `manual`-mode rule in step 2 is unchanged and still applies: in `manual`, show
the intended placement and allow an override **before** phase 3a, per member. Manual
mode may present all members' placements at once; it must not be silently converted
into a per-member pause between 3a and 3b.

## 6. Concurrency safety — the four questions, answered

### 6.1 Batched `agent start` across distinct existing panes — SAFE

- **Name collisions: none.** Names are derived per 0001 §3.4 and are unique across
  the roster; herdr requires uniqueness only among live agents. Distinct names,
  distinct panes.
- **Detection racing: bounded.** Each `agent start` is given an explicit `--pane
  <id>`, and herdr "detects the expected agent in the same pane" — detection is
  pane-scoped, so two starts in different panes are not looking at the same buffer.
- **Machine load: real, and it is the one new failure mode.** N `claude` processes
  starting at once each become ready more slowly. A member that comfortably beat the
  30s readiness timeout serially could exceed it at N=5. See §10 NEEDS-EVIDENCE #1
  for raising the timeout; if it cannot be raised, this degrades into an existing,
  already-specified outcome — a member that did not check in, handled by 0001 §13
  partial commit — and not into corruption.

### 6.2 Batched `pane split` / `new-window` — SAFE ENOUGH, WITH AN ASSERTION

Every herdr split targets `--current` with `--no-focus`, so the new panes are
siblings and none is the parent of another; there is no dependency between them.
The residual risk is not corruption but **nondeterministic geometry**: the resulting
pane sizes depend on the order the server happens to process the requests. That is
acceptable here because the geometry is already order-dependent and already poor
(§11.1), so nondeterminism regresses nothing that currently holds.

I could not read herdr's server implementation, so this is a judgment rather than a
verified claim. It is made safe by making it *detected* rather than *assumed*: the
§5 3a assertion — N layout commands must yield N distinct, non-empty target ids —
catches any interleaving that drops or aliases a pane, and the serial re-run is the
fallback. Implement the assertion; do not skip it because the batch "looked fine".

For tmux, `new-window` appends to the session's window list and each invocation
returns its own pane id via `-P -F`; there is no shared target being read-modified.

### 6.3 The `terminal` transport gets this for free

`layout: []`, one `launch` command, no placeholder. Batching step 3b alone gives it
the full N→1 speedup with no other change. Confirmed.

### 6.4 Phasing removes a race rather than adding one

The `herdr` skill requires that an `agent start` target be "an available shell pane
… at its interactive prompt, with the shell itself in the foreground and no
foreground command, editor, or agent running." The current serial ordering runs
`agent start` immediately after the split that created the shell, giving it no time
to reach its prompt. The phased ordering inserts a whole batch plus a message
round-trip between a pane's creation and its use. The `pane_not_available` retry in
step 3b is a belt-and-braces guard, not the primary mechanism.

## 7. Change list

| File | Change |
|---|---|
| `hooks/roster.mjs` | Replace the three transport `return` statements inside `spawnShape()` (`:135-137`) with the §4.4 bodies. Everything above them is unchanged. No other function is touched. No new dependency, no new I/O, no spawning. |
| `skills/agent-roster/SKILL.md` | Replace § Create step 3 (`:118-124`) with the §5 text. Update the step-1 sentence that describes the plan's return value: `a `spawn` shape (the concrete command(s) for the detected transport)` → `a `spawn` shape (`layout` and `launch` command lists for the detected transport, plus how to thread the target id from one to the other)`. Steps 2, 4, 5 and the closing escalation paragraph are unchanged. |
| `tests/test-roster-spawn.sh` | This is the only harness asserting over `create --plan` output (it checks every emitted `--agent` string and the absence of `--model inherit`). If it selects on `.spawn.steps`, retarget those selectors to `.spawn.layout` and `.spawn.launch`. If it greps the raw plan text without a JSON path, no change is needed. Add the §9.2 assertions. |
| `docs/specs/0001-agent-roster.md` | No edit. §6 step 5 describes *what* is spawned, not how it is grouped, and remains accurate. |
| `docs/specs/0002-roster-spawn-defects.md` | No edit. Its `spawn.steps` mention at `:17` is a historical narrative of a past run and stays correct as history. |

## 8. What must NOT change

1. **`roster.mjs` performs zero spawning.** It emits strings. This spec changes the
   strings and their grouping; it does not add `execFileSync`, a spawn, or any
   process launch to the `create --plan` path. `detectTransport()`'s existing
   `execFileSync("tmux", ["list-sessions"])` probe at `:122` is pre-existing and
   untouched.
2. **The plan→commit two-step.** `--plan` resolves and reports; `--commit
   --verified <json> --transport <t> --roster-level <L>` writes the Team. Neither
   the `--commit` branch nor the `team` object literal is touched. The
   `CLAUDE_PID` / `--orchestrator-pid` behaviour and its comment stay exactly as-is.
3. **0001 §13 partial-success behaviour.** On partial check-in, commit anyway with
   `--partial`, name the members that never came up, report the Team as degraded;
   do not block, do not tear down. Every new failure path in this spec (a missing
   target id in 3a, a launch that never becomes ready) must funnel into this
   existing outcome, not into a new abort.
4. **The check-in poll.** Every 2 seconds, give up at 60 seconds, fixed interval,
   not configurable. Do not "optimize" it because starts are now concurrent.
5. **The derived-name scheme** (0001 §3.4). `--name` is what makes check-in
   verifiable.
6. **0002's two fixes.** `--model inherit` must stay omitted rather than emitted
   literally, and the herdr path must keep passing `agentFlags` (no `--name`) after
   `--` while tmux/terminal keep `claudeFlags` (with `--name`). The comment at
   `:130-131` explaining why must survive the edit.
7. **Route handling.** Subagent-routed members get `spawn: null` and are never part
   of either phase.

## 9. Verification

### 9.1 Plan-shape checks (no spawning; safe to run anywhere)

Run `roster.mjs create --plan` on a default roster and assert on the JSON:

1. Every peer-routed member has `spawn.layout` and `spawn.launch` as arrays, and
   **no** `spawn.steps` key.
2. Every subagent-routed member still has `spawn: null`.
3. Under herdr (`HERDR_ENV=1`): `layout[0]` contains `pane split --current` and
   `--no-focus`; `launch[0]` contains `<TARGET>` and does **not** contain `--name`;
   `target_placeholder === "<TARGET>"`, `target_from === 0`,
   `target_source.path === ".result.pane.pane_id"`.
4. Under tmux: `layout[0]` contains `-P -F '#{pane_id}'`; `launch[0]` contains
   `send-keys -t <TARGET>` — assert the `-t` explicitly, it is the §4.3 fix;
   `launch[0]` **does** contain `--name`.
5. Under terminal: `layout` is `[]`, `launch` has exactly one element ending
   `--bg`, and all three `target_*` fields are `null`.
6. For a member configured `model: inherit`, no emitted string anywhere in `layout`
   or `launch` contains `--model inherit` (0002 regression guard, now over both arrays).
7. For every member, `target_placeholder === null` **iff** every `launch` string is
   free of `<TARGET>`. A placeholder declared but absent, or present but undeclared,
   is a defect.

### 9.2 Substitution check

For each peer member, substituting a dummy id for `target_placeholder` in `launch`
must leave no `<` or `>` characters in the resulting command string. This catches a
reintroduced second placeholder.

### 9.3 Live check — herdr, N ≥ 3

Run `/agent-roster create auto` in a herdr session on a roster with at least three
peer-routed members.

- All members' panes appear before any agent starts — the observable signature of
  the phase split. If panes appear one at a time interleaved with agents starting,
  step 3 was not batched and the change did not land.
- Every member checks in; the Team commits non-partial.
- Wall clock from the start of step 3 to the end of step 4 is materially below
  `N ×` the single-member time. Record the before/after numbers in the PR; this is
  the whole point of the change and an unmeasured "feels faster" does not close it.
- Each agent is in its own pane, and `herdr agent list` shows N distinct names.

### 9.4 Live check — tmux, N ≥ 2

The `-t` fix is the thing under test. After create, each new window must contain
exactly one running `claude`, and no window may contain two command lines typed
into it. A single window holding N invocations is the §4.3 defect reproducing.

### 9.5 Degradation check

Verify the partial path still works: create with a roster whose member count
exceeds what the environment can start (or otherwise force one member to fail),
and confirm the Team commits with `--partial`, names the missing member, and does
not tear down — 0001 §13, unchanged.

## 10. NEEDS-EVIDENCE

These are empirical and were not run for this spec. None blocks implementation;
each refines a value or confirms an assumption.

1. **Does `herdr agent start` accept a startup-timeout flag, and what is it called?**
   Run `herdr agent start --help` (or `herdr agent`) and report the exact flag and
   units. *If it exists* → raise it above the 30s default in the herdr `launch`
   string, since §6.1 makes concurrent starts individually slower; pick a value from
   the §9.3 measurement, and prefer generous, because overshooting costs nothing when
   starts are concurrent. *If it does not exist* → change nothing; a timeout becomes
   a member that did not check in, which 0001 §13 already handles.
2. **Does `herdr pane split` accept a count, or is there a batch-split command?**
   Check `herdr pane`. If one exists, it is strictly better than N concurrent
   single splits and removes §6.2's residual risk entirely. Report the exact
   syntax; do not adopt it without re-checking the returned JSON shape, since
   `target_source.path` would change.
3. **Measured `agent start` wall clock, serial vs. batched, at N=3 and N=5.**
   This is the number that justifies the change and sets the item-1 timeout.
4. **Does `tests/test-roster-spawn.sh` select on `.spawn.steps` or grep raw text?**
   Determines whether §7's test change is a retarget or a no-op.

## 11. Open items and adjacent defects — deliberately out of scope

### 11.1 Every split targets `--current`, so the orchestrator's own pane shrinks by half per member

`spawnShape` emits the identical `herdr pane split --current --direction right`
for every member. Repeated same-direction splits from the same source pane halve
the source each time; at N=5 the orchestrator's pane is a sliver. The `herdr` skill
warns against exactly this: "Avoid repeated same-direction splits that create
unusably narrow columns or short rows."

This is also a **non-conformance with 0001 §6 step 4**, which requires "Compute the
layout: peer-routed members split evenly across available panes/windows." That even
split has never been implemented.

It is a layout-quality defect, not a performance defect, and fixing it means
choosing a real layout policy (alternate right/down? split the previously created
sibling rather than `--current`? honour `herdr pane layout`?) — a design question
worth its own spec. Introducing a distinct `layout` phase here is the structural
prerequisite for that work, which is why it is worth naming now. **Do not fix it in
this change.** Recommend `0004`.

### 11.2 `target_source` is a two-case enum with one consumer

`kind: "json" | "stdout"` is interpreted only by SKILL.md prose. If a fourth
transport ever lands, this wants to become a documented contract rather than two
strings. Not worth formalizing at N=3 transports.

### 11.3 Whether `manual` mode should pause between 3a and 3b

§5 forbids the silent per-member pause because it would re-serialize the thing this
spec exists to parallelize. Whether `manual` should offer a *deliberate* single
checkpoint between layout and launch — "here are the five panes, proceed?" — is a
UX question for the user, not a call I should make. Flagged, not decided.

## 12. Confidence and escalation

**High** — that the serialization is in SKILL.md step 3 and not in `roster.mjs`,
that `agent start`'s ready-wait is the multiplied cost, that check-in is not
multiplied, and that `spawn.steps` has no programmatic consumer. All read directly
from source, and the consumer claim is an exhaustive repo-wide grep, not a sample.

**High** — that the tmux `send-keys` lacks `-t` and that batching would break it.
The emitted string is visible at `roster.mjs:136` and has no target.

**High** — that batching the *launch* phase is safe and is where the saving is.
Distinct names, distinct explicit `--pane` targets, pane-scoped detection.

**Medium** — that batching the *layout* phase is safe. I did not read herdr's
server, so I am reasoning from its documented CLI contract about how it handles
near-simultaneous split requests. This is why §5 3a carries an assertion and a
serial fallback rather than a promise: the design is safe *because the failure is
detected*, not because interleaving was ruled out. If the §9.3 live check shows
duplicated or missing pane ids, drop to serial layout and keep batched launch — that
retains most of the benefit and needs no further design.

**Medium** — the raised-timeout mitigation in §10 item 1, which assumes a flag I
could not verify exists.

**No Ultra-Advisor escalation recommended.** The blast radius is one function's
return values plus one prose step; there is no data migration, no persisted format
change (`team.json` is untouched), no security surface, and the whole change is
revertible in a single commit. The one genuinely uncertain call — batched layout —
is isolated behind an assertion with a named fallback, and the fallback is itself a
complete, shippable design.
