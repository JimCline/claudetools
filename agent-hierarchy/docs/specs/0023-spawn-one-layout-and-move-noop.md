# Spec 0023 — `spawn-one` tiles against the team it is joining; `move` stops reporting no-ops as success

Fixes the two defects in GitHub issue #1 (claudetools, jimcline146).

- **Bug A** — `roster_spawn_one` ignores the configured team layout. A roster with `layout: "grid"`
  produces a row of right-splits when members are spawned one at a time, and a real grid when the
  same members are spawned in one `create --spawn`.
- **Bug B** — `roster.mjs move` reports `moved: true` when herdr no-ops a same-tab move.

Both fixes live in `hooks/roster.mjs`. `herdr` itself is out of tree and is not touched.

> **Numbering note.** `0022` §11 speculated about a future `0023` (an acknowledged repo-level roster).
> That idea was never scheduled and `0022` is withdrawn. This spec claims the number; the `0022` §11
> idea is unaffected and unscheduled, and would need a number of its own if ever revived.

> **Amended (a) — user decision, 2026-08-27: live-count sizing.** The original §3.2 chose the
> roster's *configured* peer count as the tiling total, so that incremental `spawn-one` would
> reproduce `create --spawn`'s exact arrangement. **The user was offered that tradeoff (original §10)
> and chose the alternative: panes are always sized for the currently-live count, filling the
> screen.** §3.2, §3.3, §3.5, §3.6, §5.3, §8.1 and §10 are amended below. The original reasoning is
> **recorded as user-overridden, not as wrong** — it was correct about what it optimised for, and the
> user preferred a different thing to optimise for.
>
> The amendment turned out to *remove* machinery rather than swap it: the `totalPaneCount`
> parameter, the `configuredPeerPaneCount` helper, one hazard, one NEEDS-EVIDENCE item and one test
> case all disappear. See §3.3.

> **Amended (b) — NEEDS-EVIDENCE §5.1 RESOLVED, 2026-08-27.** Live experiment (Implementor, msg
> 20260827-143609-1opb): `herdr pane layout --current` is **current-tab scoped**. A pane created in a
> second tab of the same workspace never appeared in `.result.layout.panes` (5 panes before, 5 after a
> 9-pane tab was added). There is no per-pane `tab_id`; `tab_id` appears once at the layout root.
> This is §5.1's first branch: **ship §3.3 as written, no further change.** Bug A is unblocked.

> **Amended (d) — NEEDS-EVIDENCE §5.2 RESOLVED, 2026-08-27.** Live experiment (Implementor, msg
> 20260827-143609-1opb item 2): `herdr pane move <pane> --tab <its own tab> --split down` returns
> `"move_result":{"changed":false,"reason":"same_tab"}`, and `source_layout`/`target_layout` are
> **byte-identical** with no visible reposition. herdr genuinely no-ops a same-tab move; it does not
> reposition. This is §5.2's first branch: **ship §4.3 as written, no narrowing.** The byte-identical
> layout comparison is the load-bearing half — it observes rects directly, so it sees the intra-tab
> reposition that `resyncMembers`' three-id tracking could not. **No open NEEDS-EVIDENCE items remain.**

---

## 1. Goal

1. Sequential `spawn-one` calls tile the tab under the roster's configured `layout`, sizing every
   pane for the number of panes actually on screen. *(Amended (a) — was "converge on the same pane
   arrangement a single `create --spawn` would have produced".)*
2. `move`'s `moved` field tells the truth: a move that changed nothing reports `moved: false` with a
   reason, at exit 0.

Non-goals, stated so their absence is not read as oversight:

- No change to `nextSplit()`. The rule is correct; only its **inputs** are wrong at the `spawn-one`
  call site. §3.1 explains why this matters more than it sounds.
- No new `herdr` exec site anywhere in `roster.mjs` (§7 item 4).
- **Amended (a):** byte-parity between an incremental sequence and a batch `create --spawn` is
  explicitly **not** a goal and must not be asserted by any test. See §3.2.
- No herdr-side change. The issue's "Suggestion" bullet — clearer herdr messaging for a same-tab
  retile attempt — is a separate upstream ask against the herdr repo and is **out of scope here**
  (§9).

---

## 2. Bug A — root cause, confirmed against source

### 2.1 The call chain

`spawn-one` (`roster.mjs:1580-1591`) builds a single plan entry and calls:

```js
const layoutInfo = layoutPlan(resolved, transport, [planEntry]);   // :1582
const mode = layoutInfo ? layoutInfo.mode : resolved.layout;       // :1583
const [launched] = await layoutAndLaunch([planEntry], transport, mode, cwd, "spawn-one"); // :1591
```

`mode` is **correct** — `layoutPlan` sets `mode: resolved.layout` (`:238`), so a `grid` roster yields
`"grid"`. The mode is not the bug, and an implementor who "fixes" the mode has fixed nothing.

`layoutAndLaunch` then calls (`:624`):

```js
({ panes } = runLayoutLoop({ mode, paneCount: peerMembers.length, self, splitCwd }));
```

`peerMembers.length` is **1** for `spawn-one`, always. `runLayoutLoop` (`:406-430`) loops once and
calls `nextSplit({ mode, paneCount: 1, self, created: [], geometry })`.

### 2.2 What that does inside `nextSplit`

Two independent things go wrong, and **both** must be fixed. Fixing either alone leaves the bug.

**(a) The candidate set collapses to `{self}`.** `nextSplit` iterates `[self, ...created]`
(`:266`). With `created` empty, the orchestrator's own pane is the only candidate, so the split
target is *always* P0 — a sibling peer pane can never be chosen even when it is by far the largest.
The greedy rule of `0004` §6.2 is being applied to a candidate set of one, where it is vacuous.

**(b) `total` is always 2.** `total = paneCount + 1` (`:278`) with `paneCount === 1` gives 2 on every
call, no matter how many panes the team already has. The plan constants follow:

```
total = 2  →  bands = max(1, 2**floor(log2(2)/2)) = max(1, 1) = 1
              cols  = ceil(2/1) = 2
```

The root rect is the bbox of the candidates (`:283-287`), and with one candidate that is exactly
`self`'s rect, so `rect === root`. The direction rule (`:293-298`) then evaluates:

- band test: `rect.height * 2 * bands > rootHeight * 3` → `2 > 3` → **false**
- column test: `rect.width * 2 * cols > rootWidth * 3` → `4 > 3` → **true** → `direction = "right"`

**`"right"` falls out unconditionally, for every mode except when `effectiveMode` resolves to
`columns` — which also yields `"right"`.** Every incremental spawn right-splits the orchestrator's
pane. That is precisely the reported symptom: a row, never a grid.

### 2.3 Why `create --spawn` is correct

`createSpawn` (`:750-752`) passes the **full** `peerMembers` array, so `paneCount === N` and `created`
accumulates real pane ids across iterations. `total = N+1` is the true final count and the candidate
set grows. `0004` §6.4's worked tables are the batch path.

### 2.4 This supersedes `0009` §6.3 step 5

`0009` §6.3 step 5 specifies, verbatim:

> place one pane via `runLayoutLoop({mode, paneCount: 1, self: HERDR_PANE_ID, splitCwd: cwd})` …
> *(`paneCount: 1` confirmed workable — NEEDS-EVIDENCE item 6, resolved.)*

**`paneCount: 1` is the bug, and that evidence item was answered too narrowly.** "Confirmed workable"
established that the call completes and yields one pane. It did not establish that the resulting
*arrangement* honours `roster.layout`, which is the property this spec is about. A call that returns a
pane id and a call that tiles correctly are different claims.

**This spec supersedes `0009` §6.3 step 5's `paneCount: 1`.** Everything else in `0009` §6.3 — the
liveness short-circuit, the merge-write, the persistence requirement, the shared-implementation rule
— stands unchanged. When implementing, append a correction note to `0009` §6.3 step 5 pointing here;
do not silently rewrite the original sentence (this is the convention `0009` §6.6 item 2 itself
established for exactly this situation).

---

## 3. Bug A — the fix

### 3.1 `nextSplit` does not change. Its callers do.

This is load-bearing. `nextSplit` is pure by contract (`0004` §6.7, restated in `0004` §12 item 5),
has a dedicated CLI surface (`next-split`) and fifteen unit assertions (`0004` §11.3). Changing it
would put all of that at risk to fix a caller's arithmetic.

The fix supplies `nextSplit` with the two inputs it was being denied:

| input | today at `spawn-one` | after — amended (a) |
|---|---|---|
| `created` | `[]` | the team's live sibling pane ids, in team-record order |
| `paneCount` | `1` | live siblings present in geometry, plus the panes being created now |

### 3.2 Where the seed comes from — decision, amended (a)

The Orchestrator's brief offered two sources for the tiling total. They answer different questions.

**The `created` seed MUST be live pane ids. This half is unchanged by the amendment.** `nextSplit`
needs pane *identifiers* that are present in the reported geometry (it hard-fails otherwise, `:268`).
Roster config holds no pane ids and can never supply them. There is no choice here.

**`paneCount` is the live count — panes actually on screen, plus the ones this call adds.**
*Amended (a). The user chose this.* The consequence, stated plainly because it is the thing that was
traded:

> Every pane is sized for the panes that exist right now, so the screen is always full. An
> incremental sequence therefore may **not** reproduce `create --spawn`'s arrangement for the same
> members, because a split made when three panes were live cannot be un-made when the fourth arrives.

**Recorded, user-overridden, not wrong — the original argument for the configured count.** It is kept
because it is the reason the alternative existed, and because anyone proposing to flip this back
needs to know it was considered:

- `0004` §6.3, as amended, says *"`auto` resolves **once, from the final target pane count**"*, and
  `0004` §6.1 defines the total as *"known before the first split runs"*. The configured count is
  the only source that satisfies that reading literally.
- It would have made convergence exact. Batch step *k* runs with `paneCount = N`,
  `created = [p₁..p_{k-1}]`; an incremental spawn *k* using the configured total would run the same
  arguments over the same geometry, therefore reach the same decision.

**Why the user's choice is nonetheless the better product behaviour**, and why I do not consider this
a regression against `0004`: sizing for the configured count means a user who configures five members
and deliberately runs three gets three panes proportioned for five — two slots' worth of the screen
given to panes that do not exist. `0004` §6.3's "final target pane count" was written for `create`,
where the final count is genuinely known before the first split because every member is being spawned
in that one call. On the `spawn-one` path there is no such thing as a known final count: the user may
stop at three, or never spawn the fifth. **The live count is the only quantity that is actually known
at the moment of the split**, and treating the roster's configured size as a commitment to spawn all
of it was an assumption, not a fact.

**What is given up, accepted:** intermediate arrangements diverge from batch, and non-power-of-two
totals can end in a different (equally valid) tiling than batch would have produced. What is
*retained* is the property that actually matters and that `0004` §11.3 item 11 asserts for batch —
at power-of-two totals the panes still come out equal. Worked, on a 180×42 tab with `grid`:

| call | liveSeed | total | candidates | decision | result |
|---|---|---|---|---|---|
| spawn-one #1 | — | 2 | self 180×42 | `right` | self 90×42, p1 90×42 |
| spawn-one #2 | p1 | 3 | self 90×42, p1 90×42 | `down` on self (tie → earliest) | self 90×21, p2 90×21, p1 90×42 |
| spawn-one #3 | p1, p2 | 4 | self 90×21, p1 90×42, p2 90×21 | `down` on p1 (largest) | **four equal 90×21 panes** |

Three sequential `spawn-one` calls reach `0004` §6.4's N=3 outcome — four equal panes including the
orchestrator's — by a different route than batch takes. That is the design working as chosen.

**Confidence: high on the `created` seed (forced). The tiling total is a recorded user decision, so
it is not mine to be confident about** — my analysis of both options is above, and the user picked
with it in hand.

### 3.3 `runLayoutLoop` — additive change *(amended (a) — simplified)*

`hooks/roster.mjs:406-430`. **One** new optional parameter. **Existing callers pass nothing and must
be byte-identical in behaviour.**

The amendment removed the `totalPaneCount` parameter the original draft carried. It is unnecessary:
the live total is `liveSeed.length + paneCount`, and both terms are already in scope inside the loop.
Deriving it there is strictly better than passing it in, because `liveSeed` is filtered against the
geometry and a caller-supplied count could not be.

```js
function runLayoutLoop({ mode, paneCount, self, splitCwd, seedPanes = [] }) {
  const panes = [];   // NEWLY created only — this is what the function returns, unchanged
  const splits = [];
  for (let i = 1; i <= paneCount; i++) {
    // ... existing geometry fetch, unchanged ...
    const geometry = geomResult.result.layout.panes;

    // Seed the candidate set with sibling panes that are actually on screen right now.
    // Filtered against live geometry every iteration: a stale transport_id in team.json is
    // routine (it is why `resync` exists), and an absent candidate is a hard fail in nextSplit.
    const present = new Set(geometry.map((g) => g.pane_id));
    const liveSeed = [...new Set(seedPanes)].filter((id) => id !== self && present.has(id));

    const decision = nextSplit({
      mode,
      paneCount: liveSeed.length + paneCount,   // live total: what is on screen + what we are adding
      self,
      created: [...liveSeed, ...panes],
      geometry,
    });
    // ... existing split call, unchanged; push newPaneId onto `panes` and `splits` ...
  }
  return { panes, splits };
}
```

Points the Implementor must not smooth over:

- **`panes` still holds only newly created ids.** `layoutAndLaunch`'s `:640` assertion
  (`panes.length !== peerMembers.length`) depends on this and must keep passing unmodified. The seed
  goes into `created` for the *decision*; it never goes into the *return value*.
- **The seed is filtered inside the loop, not once outside it.** A sibling pane can close mid-loop.
  Re-deriving `liveSeed` per iteration from the geometry already being fetched costs one Set
  construction and no extra I/O.
- **The filter now feeds the total as well as the candidate set**, which makes it more load-bearing
  than in the original draft: omitting it produces both a hard fail in `nextSplit` *and* an inflated
  total. §8.1 test A4 pins this.
- **`id !== self`** guards against a team record whose `transport_id` happens to equal the
  orchestrator's pane. Harmless if it never fires; a duplicated candidate and an off-by-one total if
  it does.
- With `seedPanes = []`: `liveSeed` is `[]`, `paneCount` passed to `nextSplit` is
  `0 + paneCount = paneCount`, and `created` is `[...[], ...panes]`. **Identical to today, term for
  term.** The `layout-splits` CLI path (`:1039`) and `createSpawn` are untouched.

### 3.4 `layoutAndLaunch` — pass-through *(amended (a) — one field, not two)*

`hooks/roster.mjs:616-650`. Append one optional options object; do not reorder existing parameters.

```js
async function layoutAndLaunch(peerMembers, transport, mode, splitCwd, callerLabel, layoutOpts = {}) {
  // ...
    ({ panes } = runLayoutLoop({
      mode,
      paneCount: peerMembers.length,
      self,
      splitCwd,
      seedPanes: layoutOpts.seedPanes || [],
    }));
  // ... everything else unchanged ...
}
```

`createSpawn` (`:752`) passes no sixth argument and is unchanged. This preserves `0009` §6.3 step 5's
standing requirement that the two callers share one implementation rather than forking it.

### 3.5 `spawn-one` — compute and pass *(amended (a))*

`hooks/roster.mjs`, in the `spawn-one` case, between the existing `:1583` mode resolution and the
`:1591` call. `team` and `dir` are already in scope (`:1527`, `:1542`).

```js
const seedPanes = team && Array.isArray(team.members)
  ? team.members
      .filter((m) => m.route === "peer" && m.transport_id != null && m.name !== member.name)
      .map((m) => m.transport_id)
  : [];

const [launched] = await layoutAndLaunch(
  [planEntry], transport, mode, cwd, "spawn-one", { seedPanes }
);
```

**That is the whole of the amended change at this call site.** No total is computed here — §3.3
derives it from the geometry-filtered seed, which is the live count the user chose. `resolved` is not
consulted for the tiling at all.

**Do NOT filter the seed on `memberIsLive`.** `memberIsLive` (`:728`) answers "has this *agent*
checked in", which is a different question from "is there a *pane* occupying screen space". A pane
whose agent died is still on screen and must still be a tiling candidate; a live member with a stale
`transport_id` must still be dropped. **Pane presence in the live geometry is the only correct
filter, and §3.3 already applies it.** Adding a liveness filter here would be a second, wrong gate.

**Seed order is `team.members` order.** `0004` §6.2 rule 2 breaks ties toward the earliest candidate,
so order is observable — but only when two candidate areas are exactly equal. `team.members` order is
creation order for the batch path and append order for `spawn-one` (`:1613`), except that a respawn
replaces in place (`:1614`) and so keeps its original slot. **Accepted limitation:** after a member is
respawned, seed order can differ from true creation order, and an exact-area tie would then break
differently. Recorded, not fixed — tracking true creation order would need persisted layout state,
which `0004` §6.7 exists to avoid.

### 3.6 REMOVED by amendment (a) — `configuredPeerPaneCount` and its hazard

*Heading retained so §-numbering and inbound references stay stable.*

The original §3.6 specified a `configuredPeerPaneCount(resolved)` helper and warned at length about a
trap in it: `resolveRoster` (`lib-config.mjs:408-434`) returns `route: r.route` at the roster level
*and* `members: rosterMemberNames(r.members, prefix)`, so a member may inherit the roster-level route
and `resolved.members.filter((m) => m.route === "peer")` can undercount to zero.

**All of it is deleted.** Under live-count sizing the roster's configured membership is never
consulted for tiling, so the helper has no caller and the route-inheritance trap is unreachable from
this spec. The original NEEDS-EVIDENCE item about `rosterMemberNames` (§5.3) and the test that pinned
the hazard (§8.1 A5) are struck for the same reason.

**The observation itself remains true and is worth keeping in mind elsewhere** — anything that filters
`resolveRoster().members` on `m.route` outside a plan-builder path has the same bug latent in it.
`layoutPlan` (`:235`) is safe only because it is handed plan entries whose route is already resolved.

### 3.7 Amendment to `0004` §6.1 — the candidate set

*Unchanged by amendment (a).*

`0004` §6.1 currently defines:

> **Candidate set** — `[P0, ...member panes]`, in that order. Panes that exist in the reported
> geometry but were neither P0 nor created by this loop (someone else's pane in the same tab) are
> **not** candidates: this procedure only subdivides its own screen real estate.

**This spec amends the parenthetical clause, and only it.** The candidate set becomes:

> `[P0, ...live panes of this team's peer members, ...panes created by this loop]`.

**The stated rationale is not weakened, it is honoured.** The exclusion exists so the procedure only
subdivides *its own* screen real estate. A pane belonging to this team's own peer member, created by
a previous run of this same procedure, **is** its own real estate — it was excluded only because the
original text used "created by this loop" as a proxy for ownership, and that proxy is exactly what
breaks under incremental spawning. Foreign panes — anything not P0 and not a recorded member of this
team — remain excluded, unconditionally.

Apply this as an amendment note in `0004` §6.1 referencing this spec. Do not rewrite the original
sentence in place.

### 3.8 `layoutPlan`'s `pane_count` is NOT changed

`layoutPlan` (`:233-246`) reports `pane_count: plan.filter(route === "peer").length` — for
`spawn-one`, `1`. That is honest: it is the number of panes **this call places**, and `0004` §11.1
item 2 asserts it equals the number of peer-routed members *in the plan*. Leave it. The tiling total
is a separate quantity and is derived separately, by design.

---

## 4. Bug B — root cause and fix

*Unchanged by amendment (a).*

### 4.1 Root cause

`roster.mjs` `move` case, `:1484-1506`:

```js
try { herdrCall(herdrArgs); } catch (err) { fail(err.message); }
// Ignore the move response body entirely (spec 0008 §2/§5.4 step 7) — re-query instead.
const result = resyncMembers(team);
// ...
const healed = result.members.find((m) => m.name === name);
const resyncOut = { ok: true, status: healed.status };
// ...
out({ moved: true, member: {...}, command: commandString, resync: resyncOut });   // :1506
```

herdr exits 0 on a same-tab no-op, so `herdrCall` does not throw. `resyncMembers` (`:384-389`)
correctly computes `status: "unchanged"` — none of `transport_id`/`tab_id`/`workspace_id` moved. The
output then prints **`"moved": true` directly alongside `"status": "unchanged"`**.

**The defect is best characterised as an internal contradiction, not a missing check.** The command
already computes and already emits the correct answer; the `moved` field simply refuses to agree with
its own sibling. That framing matters for §4.2.

### 4.2 This does not violate `0008` §2 — it completes it

`0008` §2's closing paragraph is the invariant at stake:

> **Consequence for `move`:** `move` does *not* need to parse `.result.move_result.pane.*` out of the
> move response. It runs the move, then re-queries. One code path, self-correcting, and correct even
> if herdr's move response shape changes.

The invariant governs **the source of truth**: the re-query is authoritative, the response body is
not. It says nothing about always concluding success — that was never a design decision, it was an
oversight in the emit step.

Therefore:

- **Deriving `moved` from `healed.status` honours `0008` §2.** It reads the authoritative re-query,
  which is exactly what the invariant mandates.
- **Inspecting herdr's `reason: "same_tab"` from the response body would violate it**, and is
  rejected on that basis. It would also re-couple `roster.mjs` to a response shape `0008` §2
  deliberately decoupled from. Do not do this, even though the GH issue names the field.

`0008` §5.4 step 8's example output already carries `resync.status`. This change makes `moved`
consistent with a field the command has emitted since day one.

### 4.3 The change

`roster.mjs:1500-1506`. One condition, plus a reason string.

```js
const healed = result.members.find((m) => m.name === name);
const resyncOut = { ok: true, status: healed.status };
if (healed.status === "updated") { resyncOut.from = healed.from; resyncOut.to = healed.to; }
if (result.warning) resyncOut.warning = result.warning;

const noop = healed.status === "unchanged";
const payload = {
  moved: !noop,
  member: { role: member.role, name: member.name },
  command: commandString,
  resync: resyncOut,
};
if (noop) {
  payload.reason =
    `no-op: herdr accepted the command but pane ${member.transport_id} is in the same tab and ` +
    `workspace as before (re-query reports no change)`;
}
out(payload);
```

**Scope discipline — change `unchanged` and nothing else:**

- **`status: "not_found"` keeps `moved: true`.** `0008` §5.4 step 8 specifies this explicitly and
  gives its reasoning (*"The move really happened; hiding that behind a non-zero exit is worse than
  reporting it"*). Not this spec's business.
- **The `!query_ok` path (`:1494`) keeps `moved: true`.** `0008` §5.4 amendment (b) specifies that
  shape verbatim. Its residual weakness — an unverifiable move is reported as success — is real but
  is `0008`'s recorded decision, and re-litigating it is out of scope. Recorded here so the next
  reader knows it was considered.
- **Exit code stays 0.** `moved: false` is a truthful report, not an error. Precedent is already in
  this same case body: `:1456` (wrong transport) and `:1481` (`--dry-run`) both emit `moved: false`
  at exit 0.

### 4.4 MCP needs no change

`mcp/server.mjs` `roster_move` (`:596-611`) and `roster_spawn_one` (`:617-630`) both end in
`execCli(ROSTER_CLI, args)`, and `mapExecResult` (`:355-374`) wraps roster.mjs's stdout as text
without parsing or whitelisting fields. **The new `moved: false` and `reason` reach MCP callers
verbatim.** No server-side edit, no tool-schema edit.

---

## 5. NEEDS-EVIDENCE

I cannot run anything. Each item below states exactly what to run and what each outcome decides.
Item 1 is **blocking for bug A**; the rest are confirmations.

### 5.1 RESOLVED (amendment (b)) — geometry is current-tab scoped; ship as written

**Answered: first branch. No change to §3.3.** The experiment and its result are recorded in the
amendment block above. The analysis below is retained because it explains *why* the tab-scoping
question was load-bearing, and because any future change that widens the candidate set inherits it.

**Why it blocks, and amendment (a) raised the stakes.** §3.3 filters the seed by presence in the
reported geometry. If that geometry is scoped to the current tab, an off-tab sibling is dropped
automatically and the design is correct as written. If it spans the whole workspace including other
tabs, a sibling that was `move`d to another tab would enter the candidate set, its rect would join the
root-rect bbox (`:283-287`), **and — under live-count sizing — it would also inflate the tiling
total**, so the remaining panes would be sized for a pane that shares no screen space with them.
Under the original configured-count design only the bbox was at risk; now the count is too.

`0004` §2.3 describes the response as *"whole-workspace"*, and `0004` §6.5 repeats it — but a
workspace may contain multiple tabs, and neither passage says whether `--current` narrows it. The
existing code never hits this because its candidates are all panes it just created in the current
tab. **The seed is the first thing that could introduce an off-tab candidate.**

**Run:** in a live `HERDR_ENV=1` session, create a second tab in the same workspace with at least one
pane in it, then from a pane in the first tab run `herdr pane layout --current` and report
`.result.layout.panes` in full — specifically (a) whether any pane from the second tab appears, and
(b) whether each entry carries any tab identifier field.

**Decides:**
- *Current-tab only* → ship §3.3 exactly as written. No further change.
- *Multi-tab, and entries carry a tab id* → §3.3 gains one more filter term on that field, comparing
  against the tab of `self`. Mechanical; amend §3.3 and proceed. The total corrects itself, because
  it is derived from the same filtered list.
- *Multi-tab with no tab id per entry* → the geometry cannot distinguish, and the seed must instead be
  filtered on the members' recorded `tab_id` against the orchestrator's own tab. That needs a source
  for the orchestrator's tab that is not `HERDR_TAB_ID` — `0008` §2 item 1 proves that env var goes
  stale after a move — which means a new herdr query, which collides with §7 item 4's no-new-exec-site
  constraint. **Come back to me: that branch is a design change, not an implementation detail.**

### 5.2 RESOLVED (amendment (d)) — herdr no-ops a same-tab move; ship as written

**Answered: first branch. No change to §4.3.** The experiment and result are in the amendment block
above. The analysis below is retained because it explains why the question was load-bearing, and
because it names the tripwire: this pins herdr's behaviour as observed in 2026-08. Should a future
herdr honour same-tab retiles, `moved: false` becomes a false negative and **test B1 is what should
be revisited first.** `--split right` was not separately observed; `reason: "same_tab"` is a
property of the unchanged tab rather than of the direction, so it is covered by inference.

**Why it matters.** §4.3 concludes "no-op" from three unchanged ids. `resyncMembers` tracks only
`transport_id`/`tab_id`/`workspace_id` — an *intra*-tab repositioning would be invisible to it and
would be reported as a no-op even though something really moved.

**Run:** with a pane in a tab holding at least two panes, run
`herdr pane move <pane_id> --tab <that same tab_id> --split down` and report whether the pane's
position within the tab visibly changes, plus the full response body.

**Decides:**
- *No-op, as GH issue #1 reports* → ship §4.3 as written.
- *It really repositions* → narrow the condition: keep `moved: false` for the `--new-tab` /
  `--new-workspace` forms, and for the `--tab` form report `moved: false` only when
  `opts.tab === member.tab_id` as recorded **before** the move. Mechanical; amend §4.3.

### 5.3 STRUCK by amendment (a) — `resolveRoster().members` route inheritance

*Heading retained so §-numbering stays stable.*

The original item asked whether `rosterMemberNames` (`lib-config.mjs:310-318`) resolves the
roster-level `route` default onto each member. It existed only to settle the body of the
`configuredPeerPaneCount` helper, which §3.6 deletes. **No longer needed for this spec.** The
underlying caution is preserved as a note in §3.6.

### 5.4 Live confirmation

`0004` §13 is explicit that the unit tests do not prove the result *looks* right, and that the live
check must not be skipped. After implementation: in a real herdr session with a `grid` roster, run
`spawn-one` three times in sequence and confirm four visibly equal panes including the orchestrator's
own — the §3.2 worked table, observed rather than derived.

---

## 6. Files to change

*Amended (a): the `configuredPeerPaneCount` row is removed; the `runLayoutLoop`, `layoutAndLaunch`
and `spawn-one` rows lose `totalPaneCount`.*

| file | change |
|---|---|
| `hooks/roster.mjs` `runLayoutLoop` (`:406-430`) | Add `seedPanes = []` param; per-iteration `liveSeed` filter; pass `liveSeed.length + paneCount` as `paneCount` and `[...liveSeed, ...panes]` as `created` to `nextSplit`. Return value unchanged (§3.3). |
| `hooks/roster.mjs` `layoutAndLaunch` (`:616-650`) | Add trailing `layoutOpts = {}`; forward `seedPanes` to `runLayoutLoop` (§3.4). |
| `hooks/roster.mjs` `spawn-one` case (`~:1583-1591`) | Compute `seedPanes` from `team.members`; pass as the sixth argument (§3.5). |
| `hooks/roster.mjs` `move` case (`:1499-1506`) | `moved: healed.status !== "unchanged"`, plus `reason` when false (§4.3). Nothing else in the case body changes. |
| `docs/specs/0004-roster-layout.md` §6.1 | Amendment note per §3.7 — candidate set includes the team's live member panes. Do not rewrite in place. |
| `docs/specs/0009-global-roster-confirm-gate.md` §6.3 step 5 | Correction note per §2.4 — `paneCount: 1` superseded by this spec. Do not rewrite in place. |
| `tests/` | §8. |

**Not changed, deliberately:** `nextSplit` (`:262-302`), `effectiveMode` (`:249-252`), `layoutPlan`
(`:233-246`), `resyncMembers` (`:355-392`), `createSpawn` (`:737-770`), `resolveRoster` and everything
downstream of it on this path, `mcp/server.mjs`, the `next-split` and `layout-splits` CLI surfaces,
and every `herdr` invocation.

---

## 7. What must NOT change

Checked against `0004` §12 and `0008`, item by item. Nothing here conflicts, and each of these is an
assertion the Reviewer should verify rather than assume. *Unchanged by amendment (a).*

1. **`nextSplit()` stays pure** (`0004` §12 item 5, `0004` §6.7). All new I/O-adjacent logic sits in
   `runLayoutLoop`, which already performs I/O. The `next-split` subcommand stays connection-free
   (`0004` §11.3 item 10).
2. **All fifteen `0004` §11.3 `next-split` unit assertions keep passing unmodified.** `nextSplit`'s
   signature, semantics, and CLI are untouched. If any of these need editing, the implementation has
   drifted from this spec — stop and report.
3. **`createSpawn`'s observable behaviour is byte-identical.** `seedPanes` defaults to `[]`, which
   reproduces today's arithmetic exactly (§3.3). `0009` §6.3 step 5's "do not fork it" requirement is
   preserved by making the change additive on the shared function.
4. **No new `herdr` exec site.** `tests/test-roster-layout-splits.sh:242-255` asserts the count of
   `herdrCall(` occurrences over two disjoint line windows, and `0004` §12 item 5 states the permitted
   exec list exhaustively. The seed is read from `team.json` and filtered against geometry that
   `runLayoutLoop` **already fetches**; no `queryHerdrTopology()` call is added to the `spawn-one`
   path. An implementation that adds one has violated this spec even if its tiling is correct.
5. **No compensating special case for P0** (`0004` §12 item 9). P0 remains an ordinary candidate,
   first in order. The seed is appended after it, before loop-created panes.
6. **`roster.mjs` still never starts or kills a process** (`0004` §12 item 5). Unchanged in both fixes.
7. **`0008` §5.4's `not_found` and query-failure paths are untouched** (§4.3).
8. **`move`'s exit code and every other output field** keep their names, positions, and meanings. The
   change is one boolean's value plus one optional `reason` key — additive, in the same shape family
   as `0008` §5.6's recorded additive relaxation.

---

## 8. Verification

The existing stateful fake herdr in `tests/test-roster-layout-splits.sh:26-98` is the right harness —
it actually halves the target rect on each split, so a non-tiling loop cannot pass.

> **Amended (c), 2026-08-27 — do NOT extract a shared fake.** The original text assumed a second fake
> would be created by copying the first, and told the Implementor not to do that. In fact two
> independently-written fakes already exist, covering different surfaces of herdr: the
> `layout-splits` fake models geometry mutation but has no `seedPanes` flag and no
> team.json/roster/agent-start harness, so it cannot exercise the `spawn-one` machinery at all;
> `test-roster-spawn-one.sh`'s fake can. Consolidating two already-passing, divergent doubles is a
> larger and riskier diff than any acceptance criterion requires. `0008` §5.1's rule governs the
> *behaviour under test*, not test doubles. **Each fake carries a comment naming the other and the
> requirement that their split-geometry models agree** — that, not extraction, is what prevents the
> silent drift.

### 8.1 Bug A *(amended (a) — A2 replaced, A5 struck)*

- **A1 — the reported bug.** 3-member `grid` roster. Run `spawn-one` twice in sequence from a
  single-pane start. Assert the final 3-pane layout has **two distinct y-values** (the shape assertion
  `test-roster-layout-splits.sh:124` already uses).
  **Must be shown to fail against unmodified code**, which produces a single row of right-splits.
- **A2 — the acceptance property.** *Replaces the original A2, which asserted batch parity and now
  asserts something the design deliberately does not guarantee.* From a single-pane start, run
  `spawn-one` three times under `grid`. Assert the four resulting panes have areas within 5% of each
  other, and that the decision sequence contains at least one `down` and at least one `right`
  (`0004` §11.3 items 11–12, applied to the incremental path). Run from two start rects — `180×42`
  and `200×50` — so the assertion is about the rule, not one tab.
- **A2-neg — parity is NOT asserted.** No test may compare an incremental sequence's arrangement
  against `create --spawn`'s for the same members. If such an assertion exists, delete it; under
  live-count sizing it is a false requirement and will fail for legitimate reasons.
- **A3 — batch unregressed.** `create --spawn` output for a fixed roster and start rect is unchanged
  from pre-change. Capture before and after; assert equality.
- **A4 — stale seed.** Seed `team.json` with a peer member whose `transport_id` is absent from the
  fake's state. `spawn-one` must exit 0, place its pane, and size it for the *surviving* panes only —
  **not** fail with `"is not present in the reported geometry"`. **Must be shown to fail if the §3.3
  geometry filter is omitted**, which is the single likeliest way to implement this wrong, and which
  under amendment (a) now corrupts the total as well as the candidate set.
- **A5 — STRUCK by amendment (a).** Pinned the `configuredPeerPaneCount` route-inheritance hazard,
  which §3.6 deletes. Do not write it.
- **A6 — no new exec site.** `tests/test-roster-layout-splits.sh:242-255`'s `herdrCall(` count
  assertion still passes with no edit to its window boundaries.

### 8.2 Bug B

*Unchanged by amendment (a).*

- **B1 — the reported bug.** Fake herdr accepts `pane move` and changes nothing. Assert
  `moved: false`, `resync.status === "unchanged"`, a `reason` naming the no-op, and **exit 0**.
  **Must be shown to fail against unmodified code**, which emits `moved: true`.
- **B2 — real move unregressed.** Fake changes `tab_id`. Assert `moved: true`,
  `resync.status === "updated"`, `from`/`to` both present.
- **B3 — `not_found` unregressed.** Fake drops the pane from topology after the move. Assert
  `moved: true`, `resync.status === "not_found"`, exit 0 (`0008` §5.4).
- **B4 — query failure unregressed.** Topology query fails after a successful move. Assert
  `moved: true`, `resync.ok === false`, exit 0 (`0008` §5.4 amendment (b)).

B3 and B4 exist specifically so a fix that over-reaches — flipping every non-`updated` status to
`moved: false` — fails the suite.

---

## 9. Out of scope, recorded for the user

**herdr's own messaging.** The GH issue's "Suggestion" bullet asks for a clearer herdr-side
error/reason when a same-tab retile is attempted. `herdr` is an external binary in a separate repo and
is not touchable from here; `0004` §12 item 5 and the constraint in the dispatch both hold it out of
scope. **This is a genuine upstream ask and should be filed against the herdr repo separately.** Note
that this spec's fix does not depend on it: §4.2 rejects reading herdr's `reason` field on principle,
so even a perfectly-worded herdr message would not change the implementation here.

---

## 10. Decisions

**Made by the user, 2026-08-27 (amendment (a)):**

- Tiling total is the **live** count, not the roster's configured count. Panes always fill the screen;
  incremental and batch arrangements may differ. §3.2 records both sides of the tradeoff, with the
  configured-count argument marked user-overridden rather than wrong.

**Made by me, with rationale in-line:**

- The `created` seed comes from live pane ids (§3.2). Forced — roster config has no pane ids.
- `nextSplit` is not touched (§3.1).
- The live total is derived inside `runLayoutLoop` from the geometry-filtered seed rather than passed
  in by the caller (§3.3). Strictly better: a caller-supplied count cannot be filtered against
  geometry, so it would go stale exactly when a sibling pane closes.
- Bug B keys on `resyncMembers`'s status, never on herdr's response body (§4.2).
- Bug B changes `unchanged` only; `not_found` and query-failure keep `0008`'s specified shapes (§4.3).
- `0004` §6.1's candidate-set definition is amended, with its stated rationale preserved (§3.7).
- `0009` §6.3 step 5 is superseded (§2.4).

**Nothing is awaiting a user decision, and no NEEDS-EVIDENCE item is open.** §5.1 closed via
amendment (b) and §5.2 via amendment (d), both in favour of shipping the design as written; §5.3 was
struck by amendment (a). §5.4's live confirmation is a post-implementation check, not a gate.

---

## 11. Confidence

- **High** — bug A's root cause. The `total = 2` arithmetic in §2.2 resolves to `"right"`
  unconditionally, which matches the reported symptom exactly, and it is derivable from the source
  without running anything.
- **High** — that both defects in §2.2 must be fixed together. Correcting the total while leaving
  `created` empty would still target P0 every time.
- **High** — bug B's fix and its compatibility with `0008` §2. The command already computes the right
  answer and emits it in an adjacent field.
- **High** — that amendment (a) is a simplification rather than a substitution. It removes a
  parameter, a helper, an evidence item and a test case, and the resulting expression
  (`liveSeed.length + paneCount`) is derived from data the loop already holds.
- **User decision, not my confidence to give** — the live-vs-configured total (§3.2). Both options
  were analysed and the user chose with that analysis in hand.
- **Resolved** — §5.1. The geometry is current-tab scoped, so an off-tab sibling cannot enter the
  candidate set or the tiling total. The design ships unchanged and bug A has no open blocker.

**No Ultra-Advisor escalation recommended.** Both changes are additive, confined to one file, behind
existing seams, and revertible in one commit; neither touches security, auth, persistence format, or
a public interface. §5.1's third branch is the one thing that would change this answer — if the
geometry turns out to be multi-tab with no per-pane tab id, re-dispatch me before implementing.
