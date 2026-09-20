# 0054 — `disband` lists a tracked member's pane twice

Target: agent-hierarchy 0.81.1 (bug fix). Base: main @ 11edcd9, v0.81.0.

## The defect

On the first real `roster.mjs disband` of team "claudetools" (3 herdr peers, `teams/claudetools.json`),
the plan's `close` array held six rows for three panes — each member once as a team row
(`{name:"claudetools-architect", transport_id:"w16:p2", resync_status:"updated"}`) and again as a
live-peer row (`{name:"architect@47ce3168", transport_id:"w16:p2", live:true, how:"up-pid",
source:"peers"}`). `--close` closed each pane via the team row, then attempted the duplicate and got
`herdr pane close w16:p2 failed: pane_not_found`, so the top-level `closed` was `false` although every
session had in fact been closed. Reconcile was correct (`pruned` = the 3 names, `kept` = [],
`team_removed` = true).

### Root cause

`peerExtras` (hooks/roster.mjs:2002-2005) decides which live registry peers are "outside the team file"
by **name equality alone**:

```js
const named = new Set(team.members.map((m) => m.name));
return dedupPeers(peerFallbackMembers(dir, scope, team.members).filter((m) => !named.has(m.name)));
```

A peers.jsonl record with no `name` is given a synthesized one, `` `${role}@${sid.slice(0,8)}` ``
(hooks/lib-hier.mjs:771-775). `architect@47ce3168` never equals `claudetools-architect`, so the record
survives the filter and the same pane enters the union twice.

This is the only id-blind dedupe in the file. `herdrArmSlots` (roster.mjs:1944-1960) already suppresses
by pane id, name **and** session id; `dedupPeers` (roster.mjs:1854-1869) keys on `transport_id` falling
back to `session_id`. Neither runs across the team ∪ extras union.

Two contributing facts, both confirmed in the source:

1. `dedupPeers` is applied only *within* the extras list (roster.mjs:2004), never across the union at
   roster.mjs:2960 / :3015.
2. Both disband call sites resync first (roster.mjs:2955 and :2991) but then pass the **raw** `team`
   to `peerExtras` (roster.mjs:2960 and :3013), so anything `peerExtras` compares against transport ids
   sees the *stale* stored ids, while the close set and token are built from the healed ones. In the
   incident every team row was `resync_status:"updated"`, i.e. the stored ids were exactly the ones that
   had moved — so an id comparison made against `team.members` would still have missed.

The name-only filter is not an accident of implementation: spec 0040 §1.4a mandates it
("dedupe by name — a record matching a team member's name is that member, not an extra").
**0054 amends 0040 §1.4a on this point.**

## Requirements

### R1 — the extras filter is identity-based, and runs against post-resync members

**R1.1.** `peerExtras` must exclude a live registry peer that is the *same session* as a member row,
where sameness is decided by this predicate (first match wins; any match excludes):

| # | key | compare | authority |
|---|-----|---------|-----------|
| 1 | pane | the peer row's pane id (`pane_id` as the slot carries it, `transport_id` after `peerFallbackMembers` renames it) vs. the member row's **post-resync** `transport_id` | **authoritative** — a pane hosts exactly one session |
| 2 | name | the peer row's `name` (synthesized or real) vs. the member row's `name` | fallback, and the pre-0054 behaviour; it is the only key available for a paneless row |

Nulls never match: a null pane id matches no member, and a null member `name` matches no peer.
Guard both spellings of the pane field, as `herdrArmSlots` already does at roster.mjs:1954-1955 — the
team row says `transport_id`, the peer slot says `pane_id`.

**R1.2 — no pid key, no session-id key.** Team member rows carry `role`, `name`, `ref`, `route`,
`model`, `transport_id`, `checked_in`, and (herdr) `tab_id` / `workspace_id`. They carry **no `pid` and
no `session_id`**, so neither is available as a cross-source key here and neither may be invented.
(`herdrArmSlots` can use `session_id` only because both of its inputs are registry slots.)
If the team member schema later gains `session_id`, adding it as key #2 is the natural extension — do
not add it now.

**R1.3 — a peers row with no pane id.** It cannot collide by pane, so it is excluded only if its name
matches. If it survives, it appears in the plan's `close` array with `source:"peers"` and
`transport_id: null` exactly as today — and, per `closableMembers` (roster.mjs:1716), it is not closable,
so it contributes nothing to the token and is never passed to `closeOne`. This is unchanged behaviour
and must stay unchanged.

**R1.4 — the team row wins; the peer row is the one dropped.** The surviving row must be the team row,
with no `source` field. 0040 §1.5 makes the absence of `source` on a team row the discriminator for
existing callers, and `reconcileAfterClose` (roster.mjs:2083-2115) matches results back to
`fresh.members` by name — a peers-shaped row surviving in its place would break both.

**R1.5 — both disband call sites must compare against the healed members.** The plan path
(roster.mjs:2988-3015) and the `--close` path (roster.mjs:2953-2963) each compute `healedMembers` before
calling `peerExtras`; the exclusion set and the `known` argument passed down to `liveRegistrySlots` must
both be derived from `healedMembers`, not `team.members`. Without this the fix does not fire on the very
case that produced the bug. How `peerExtras` receives them is the Implementor's call.

**R1.6 — scope.** `peerExtras` has exactly two callers, both `disband` (roster.mjs:2960 and :3013).
`dismiss` resolves a single target through `resolvePeerTarget` and never forms a union, so it is out of
scope; do not change it. The no-team fallback branches (roster.mjs:2934-2952, :2973-2987) have no team
rows to collide with and already call `dedupPeers`; do not change them.

**R1.7 — `sources` is untouched.** The `sources` provenance block reports what each source *yielded*
(`team.members 3, peers.live 3, herdr matched 3`). Those are raw per-source counts, not the union, and
must not be adjusted by the dedupe — reducing them would destroy the signal that told us the duplicate
existed.

### R2 — `close_token`

`closeToken` (roster.mjs:1706-1713) hashes `{team_id, ids}` where `ids` is the sorted non-null
`transport_id`s of the closable union. It sorts but deliberately does **not** dedupe.

**R2.1.** The token for a topology that previously produced a duplicate **does change** versus 0.81.0:
`["w16:p2","w16:p2","w16:p3","w16:p3","w16:p4","w16:p4"]` becomes
`["w16:p2","w16:p3","w16:p4"]`. This is correct and is accepted. No compatibility guarantee is broken:
the old token described a close set that could not succeed.

**R2.2.** The token is never compared across versions — plan and `--close` both build the union through
the same `peerExtras`, so they continue to agree within a single build. `gateClose` (roster.mjs:2043-2057)
is unchanged.

**R2.3 — 0040's byte-compatibility promises survive.** With **zero** extras the union is the team rows
alone and the token is unchanged (pinned by tests/test-roster-disband-peers.sh:153-162, T7c). With an
extra whose name equals a team member's, the old name filter already excluded it and the new predicate
still does (pinned by T7 at :171). Only the previously-double-counted case moves.

**R2.4 — stale-token refusal still fires.** A genuinely untracked peer appearing after the plan
contributes a pane id that is in no member row and in no earlier peers row, so it survives the predicate,
enters `ids`, changes the hash, and `gateClose` fails with exit 2 as today. Nothing in R1 can mask a new
id, because R1 only ever *removes* a row that duplicates one already in the set.

**R2.5 — do NOT add a dedupe inside `closeToken`.** Its "sorts, does not dedupe" contract is documented
at roster.mjs:1706-1709 and relied on by the hand-computed token assertions in
tests/test-roster-disband-peers.sh:160 and tests/test-roster-disband-close.sh:178. Fixing the union is the
root-cause fix; deduping in the hash would paper over any future duplicate instead of surfacing it.

### R3 — top-level `closed`

**Definition (recording existing behaviour, roster.mjs:2964): `closed` is true iff every close that was
attempted succeeded** — `results.every((r) => r.closed)` over the closable union, one entry per attempt.
It is vacuously true when nothing was closable. It does **not** assert that every member is gone; that is
what `pruned` / `kept` / `team_removed` report.

**No code change.** After R1 the incident scenario attempts each pane exactly once, all three succeed, no
`pane_not_found` is produced, and `closed` is `true`.

If the existing definition is not stated in cli-tools.md or skills/agent-team/SKILL.md, a one-sentence
statement of it may be added there. **No gate text and no directive text changes; directive size
ceilings are not raised.**

### R4 — what must not change

- 0052 B1: the reconcile keep/prune rule, every close attempt for every closable member, the snapshot
  semantics. `reconcileAfterClose` is untouched. (It only ever walks `fresh.members`, so dropping a
  duplicate *peers* row cannot change what is pruned or kept — but it removes the case where a duplicate
  row's failed result shadowed a team row's lookup in `resultFor`, roster.mjs:2089.)
- 0052 U2: the plan stays read-only. Nothing in R1 writes.
- 0052 B6 / F7: both confirmation layers — the plan→`close_token`→`--close --confirm` contract and
  `hooks/pretooluse-disband-close-gate.mjs` — unchanged, as is the conversational confirm in
  skills/agent-team/SKILL.md:479-482.
- 0052 B3 / :107-108 / :120: name-null team rows are distinct rows, pruned and reported by `role`. The
  predicate's null rules (R1.1) preserve this — a null member name matches no peer, so a name-null row
  can never absorb a peers row.
- 0053 R1.6 (`readTeam` predicate), R8/G7 (spawn-one collision predicate), G6 (fresh-record write):
  all untouched.
- 0040 §1.5 output shapes: `source:"peers"` on extra rows, absent on team rows; `sources` block on every
  plan and close result.

## Tests

**File: `tests/test-roster-disband-peers.sh`**, alongside the existing T7 / T7c block at :153-183. That
file already owns the team ∪ peers union; test-roster-disband-close.sh owns reconcile and file removal,
and 0053 R2.4 requires its T7 be left alone.

Required cases:

1. **The real shape.** Team file with member `{name:"myrepo-architect", transport_id:"PANE1", route:"peer"}`,
   plus a peers.jsonl row for the **same pane** under a **different** name — seeded nameless so the
   synthesized `role@sid8` name is what appears, which is the incident's exact shape. Assert:
   - the plan's `close` array has **one** row for `PANE1`, it is the team row (`source === undefined`,
     `name === "myrepo-architect"`);
   - `--close` produces **one** `results` entry for `PANE1`;
   - top-level `closed === true`;
   - no result carries a `pane_not_found` error.
2. **Named-differently-but-same-pane, pane healed by resync.** Same as (1) but with the team row's stored
   `transport_id` stale and resync healing it to the peers row's pane — this is the case R1.5 exists for,
   and it fails if the comparison is made against `team.members`.
3. **A genuinely untracked live peer still surfaces.** A peers row on a pane no member holds still appears
   with `source:"peers"` and is still closed. T7 at :171 covers the name-collision half; this covers the
   no-collision half explicitly.
4. **Paneless peers row** (R1.3): survives as an extra with `transport_id: null`, contributes nothing to
   the token, is never closed.
5. **Stale token** (R2.4): take a plan token, then seed a new live peer on a fresh pane, then `--close`
   with the old token → exit 2 with the re-run-the-plan message.

**Existing assertions that pin the duplicate shape: none found.** T7c (:153-162, zero extras, hand-computed
token) and T7 (:163-171, equal-name extra) both still hold under R1 — verified by reading the file, not by
running it. Counts pinned elsewhere (test-roster-disband-peers.sh:96-100, :183, :225;
test-roster-disband-herdr-only.sh:116, :158-159; test-roster-disband-close.sh:108, :178-180, :184) are all
either no-team-fallback or single-source fixtures with no team/peer pane overlap.

**NEEDS-EVIDENCE N1.** That last paragraph is a read-based claim. Run the full suite and confirm the only
tests that move are the new ones. If any existing assertion changes, stop and report it rather than
editing the assertion — an existing test that breaks here means a fixture *does* overlap and the
predicate needs re-examining.

**NEEDS-EVIDENCE N2.** The incident's peers rows reported `how:"up-pid"`. Confirm from the seeded fixture
that a nameless peers row for a pane held by a team member actually reaches `peerExtras` (i.e. that
`livePeerSlots`' `inScope` / `resolveMemberTeam` filtering at hooks/lib-hier.mjs:785-797 does not already
drop it in the test fixture's shape). If the fixture cannot reproduce the six-row plan **before** the fix,
the test is not testing the bug — report that before writing the fix.

## Confidence and escalation

Medium-high on the root cause: the code path is unambiguous and the incident's observed row names
(`claudetools-architect` vs `architect@47ce3168`) are exactly the synthesized-name shape that defeats a
name-only filter. Medium on completeness: I could not run anything, so N1 and N2 are unverified.

No Ultra-Advisor escalation recommended. Blast radius is one helper with two callers, both read-through;
the confirmation layers and the reconcile rule are untouched; the only contract that moves is a token
value that was wrong by construction.

## Decisions I made, and the one that is the user's

Made: pane id as the authoritative key with name retained as the fallback (R1.1); team row wins (R1.4);
no dedupe inside `closeToken` (R2.5); `closed` keeps its existing every-attempt-succeeded meaning (R3).

**For the user:** 0040 §1.4a says in normative text "dedupe by name". R1 contradicts it. The spec-hygiene
question is whether 0040 gets an amendment note pointing at 0054, or whether 0054 standing as the later
spec is enough. I have not edited 0040.
