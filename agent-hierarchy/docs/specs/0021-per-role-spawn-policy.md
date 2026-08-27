# Spec 0021 — per-member `onMissing` policy for the peer-fallback prompt

Status: draft — **complete and self-contained. All three policy values ship together.**
Amends the peer-fallback branch defined in `docs/specs/0009-global-roster-confirm-gate.md` §5.
Terms: `docs/specs/0001-agent-roster.md` §3.2 (member schema), §3.4 (member naming).

**Amendment history — read once, then treat the body as authoritative.**
This spec briefly deferred `auto` to a background-spawn design (`0022`) on the understanding that the user
wanted a **zero-turn** spawn. That is not the ask. **Confirmed: `auto` means "one orchestrator turn, no
user prompt"** — the gate denies once with the `spawn-one` command, the orchestrator runs it and
re-issues, and the re-issue passes. `0022` is **withdrawn**; nothing in this spec depends on it, and the
§4.2 below is the original design, restored.

What `auto` buys is the removal of the **`AskUserQuestion` round-trip**, not the removal of the
orchestrator's turn. The orchestrator is told what to do instead of being told what to ask. That is the
feature, and §4.2 requires it to be described that way.

**Amended (c), during review — the `route: subagent` trap.** The original §3.2 made an `onMissing`-bearing
member impossible to switch to `route: subagent` through the CLI: `edit`'s `updated = {...existing}`
carries the old `onMissing` forward, the reject fires on the carried-forward value, and no clearing
spelling exists. The escape was hand-editing the level JSON or `remove` + `add` — a trap with no in-CLI
exit. §3.2 is rewritten: a route switch **clears** an inherited `onMissing` and warns, while a *supplied*
`--on-missing` alongside a subagent route still hard-fails. The distinction is the point — see §3.2.1.

## 1. Goal

When route is `peers` and no live instance of a role exists, `pretooluse-route-gate.mjs` denies the
dispatch once and prompts the user with three options (`peerFallbackAskReason`). That behaviour is
hard-coded and identical for every role. The user wants it configurable **per roster member**:

| policy | behaviour when no live peer exists |
|---|---|
| `auto` | deny once with the `spawn-one` command; do not ask the user; the re-issue passes (§4.2) |
| `prompt` | today's three-option prompt (**default**) |
| `never` | never spawn a peer for this role; fall straight through to a subagent |

## 2. Name: `onMissing`, not `spawnPolicy`

The Orchestrator flagged the collision risk with the existing `autoMode`. `autoMode` is Claude's own
`--permission-mode` (`acceptEdits`, `bypassPermissions`, …) — a *launch* setting for a session that is
being started. This field decides *whether a launch happens at all*, in response to a specific condition.

`onMissing` names the condition, which is what makes it unmistakable at a call site and in `show` output:
`onMissing: auto` reads as "when this member is missing, spawn it". `spawnPolicy` reads adjacent to
`autoMode` and invites exactly the conflation the Orchestrator wants avoided. On-disk key: `onMissing`
(camelCase, matching `autoMode`/`route`); CLI flag `--on-missing`; MCP param `on_missing`.

## 3. Schema and defaults

### 3.1 Member field

```jsonc
{ "role": "implementor", "model": "inherit", "route": "peer", "onMissing": "auto" }
```

Add to `lib-roster.mjs`:

```js
/** What the peer-fallback gate does when this member has no live instance (spec 0021). */
export const ON_MISSING_VALUES = ["auto", "prompt", "never"];
export const ON_MISSING_DEFAULT = "prompt";
```

and one clause in `validateMember`, in the same shape as the existing `effort`/`route`/`autoMode` clauses:

```js
if (m.onMissing !== undefined && m.onMissing !== null && !ON_MISSING_VALUES.includes(m.onMissing)) {
  errors.push(`on-missing must be one of ${ON_MISSING_VALUES.join(", ")}, got ${JSON.stringify(m.onMissing)}`);
}
```

**Absent ⇒ `prompt`.** Every existing roster keeps today's behaviour with no migration and no rewrite.
Resolve the default at the **read site** (§4), not by stamping `onMissing: "prompt"` into member objects —
`normalizeMembers` (`lib-roster.mjs`) feeds the team-history fingerprint, and materialising a default that
was previously absent would change the fingerprint of every existing roster and orphan its history entry.

> **NEEDS-EVIDENCE #1 — confirm that claim before implementing.** Read `normalizeMembers` and
> `fingerprint` in `lib-roster.mjs` and report whether adding a new member key changes the hash for a
> roster that does not set it. Expected: it does not, because `normalizeMembers` copies an explicit key
> list (`role`, `model`, `effort`, `route`, `auto_mode`). **If it does** — or if `onMissing` should be part
> of the fingerprint — say so; the answer decides whether `normalizeMembers` gains `onMissing` in its key
> list. My reading says it should NOT be added (it is a dispatch-time policy, not part of what reproduces
> a team's shape), but I could not run it.

### 3.2 Interaction with `route: "subagent"`

*Rewritten by amendment (c).*

`onMissing` is meaningless for a subagent-routed member — there is no peer to be missing. Two different
situations, two different answers:

**(i) The user supplies both in one invocation → hard `fail`.** `add` or `edit` where `--on-missing` is
given AND the member's effective route resolves to `subagent`:

```
on-missing applies only to peer-routed members (this member's route is "subagent")
```

They have asserted two contradictory things in a single command. Storing either one silently would be
guessing at which they meant.

**(ii) A route switch leaves an inherited `onMissing` behind → delete it and warn.** `edit --route
subagent` on a member that already carries `onMissing`, where `--on-missing` is **not** supplied on this
invocation:

```js
if (updated.route === "subagent" && updated.onMissing !== undefined && !userSuppliedOnMissing) {
  const dropped = updated.onMissing;
  delete updated.onMissing;
  process.stderr.write(`roster.mjs: ah: dropped on-missing "${dropped}" — it applies only to peer-routed members, and this member is now route "subagent"\n`);
}
```

The warning must name the dropped value. A silent delete of something the user configured earlier is the
other half of the same trap.

#### 3.2.1 Why the two cases differ — do not collapse them

Both are "subagent route meets `onMissing`", and it is tempting to give them one answer. Don't:

- Collapsing to **always fail** is the defect this amendment fixes. The carried-forward value in
  `updated = {...existing}` is not something the user typed *now*; failing on it makes a legal state
  transition unreachable through the CLI, with no clearing spelling to escape it.
- Collapsing to **always delete** would silently discard a value the user typed in the same breath as the
  contradicting route. That is the case where they most need to be told they are confused.

The discriminator is **"did this invocation supply `--on-missing`?"**, not "is the value present on the
member object?" — by the time the reject runs, the spread has made those two indistinguishable unless the
implementation keeps them apart. Read the supplied-ness from `opts`, before merging. State this in a
comment; it is the whole subtlety.

#### 3.2.2 Why not a clearing value

The Reviewer's alternative was `--on-missing default` (or similar) to delete the key. Rejected:

- It adds a fourth spelling to a three-value vocabulary, and a value whose meaning is "unset this" rather
  than a policy — `show` would then have to render `default` as `prompt (default)`, two names for one state.
- It leaves the trap in place for anyone who does not know the new word exists.
- The route switch is the only way to reach the invalid state, so the fix belongs at the transition, not
  in the value set.

This matches how the field is already described for non-peer-eligible roles: **inert, not invalid** (below).

### 3.3 Non-peer-eligible roles: inert, not rejected

The gate only consults `onMissing` for roles in `PEER_ELIGIBLE_ROLES`, so a `task-runner` member carrying
one is inert. Do **not** reject it at write time — `PEER_ELIGIBLE_ROLES` is a dispatch-side concept and a
roster may legitimately outlive a change to it. `show` marks it, **with the reason**:

```
(inert: role is not peer-eligible)
```

Not a bare `(inert)`. The reason is the informative half — a reader seeing `(inert)` alone has to go
find out why, and the two candidate causes (non-peer-eligible role vs. subagent route) have different
fixes. *(Reviewer nit, folded in: `lib-config.mjs`'s `statusReport` currently renders the bare form.)*

## 4. Where it is read — `pretooluse-route-gate.mjs`

**One branch changes.** In the `route === "peers"` / `!live.length` arm:

```js
} else {                                    // no live instance of `role`
  const policy = onMissingFor(resolved, role);
  if (policy === "never") {
    decide(null, null, `ah: no live ${ROLE_LABELS[role]} peer, and its on-missing policy is "never" — spawning the subagent.`);
  }
  if (policy === "auto") { /* §4.2 */ }
  /* policy === "prompt" → today's peerFallbackAskReason path, byte-identical */
}
```

`onMissingFor(resolved, role)` resolves as: the roster member's `onMissing`, else `ON_MISSING_DEFAULT`.
For a multi-member role (`0019`), use the **first** member of that role in roster order — the gate is
asking a role-level question ("is a peer of this kind available"), and `0019`'s per-instance selection
belongs to `spawn-one`, not here. State this in a comment; it is the kind of thing a later reader will
assume is a bug.

### 4.1 `never`

Falls through to a subagent immediately, with a `systemMessage` (not a deny) explaining why — the same
shape the existing already-asked fall-through uses at the end of that branch. No gate record: there is
nothing one-shot about it, the policy is the answer every time.

### 4.2 `auto` — deny once with the instruction, do not ask the user

**What `auto` is.** It removes the `AskUserQuestion` round-trip. The orchestrator is told what to run
instead of being told what to ask:

```
deny, reason:
ah: no live <Role> peer, and its on-missing policy is "auto".
Run: node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" spawn-one <role> --cwd <cwd>
Then SendMessage the peer instead of re-issuing this dispatch. Do not ask the user — this is configured.
```

**What `auto` is not.** A PreToolUse hook returns a permission decision on the synchronous dispatch path;
it cannot stand up a peer and report success within that call. So `auto` costs **one orchestrator turn**,
and `SKILL.md` and `show` must describe it as **"spawn without asking"**, never "spawns automatically" —
a human reading the latter will expect a peer to appear with no turn at all.

*(A zero-turn variant was designed and withdrawn — see `docs/specs/0022-background-peer-spawn.md`, kept as
a record of the investigation and its Ultra-Advisor ruling. Do not resurrect it without a new decision;
the user considered and rejected it.)*

**Gate record:** `{type:"on-missing-auto", session_id, role}`, one-shot per (session, role), exactly like
`peer-fallback-ask`. Without it, an orchestrator that ignores the instruction and re-issues gets denied
forever. With it, the re-issue falls through to the subagent — the same graceful degradation `0009` §5.3
already relies on ("`spawn-one` fails → nothing becomes live → the re-issue passes"). Reuse that
reasoning; do not invent a stricter one.

The choice sticks with no further state, for the reason `0009` §5.3 already gives: if the orchestrator
runs the command, the peer's SessionStart appends its `up` record and the *next* dispatch takes the
live-peer branch (`peersDenyReason`), which says to SendMessage it. The existing live-peer branch enforces
the outcome; this branch only has to start it.

### 4.3 Availability guard — reuse `0009` §5.2 verbatim

`peerFallbackAskReason` already computes `rosterUsable` and only offers the spawn option when a roster
entry exists at a level this session may use:

```js
rosterUsable = !!resolved.roster && (resolved.rosterLevel !== "global" || globalScopeAnswer(dir, sessionId, "roster") === "allow")
```

**`auto` must apply the identical guard**, and when it fails, degrade to `prompt`'s two-option form rather
than emitting a `spawn-one` line that will fail. If `!rosterUsable` or no member exists for the role →
behave as `prompt`, with the existing "no roster entry / global roster not confirmed" degradation.
`0009` §5.2's rule stands: *recommending a command that will fail is worse than not recommending one.*

### 4.4 `auto` does NOT bypass the global-scope confirm gate

**The Orchestrator's recommendation is correct and is adopted.** `onMissing` skips only the "should I
spawn this role" question. It has no effect on `0009` §4's scope-A/scope-B gates, for three reasons worth
recording so this is not re-litigated:

1. **Different risk.** Scope A asks whether a roster belonging to *some other project* should be used
   here. That is a blast radius across repos; `onMissing` is a per-role convenience within one.
2. **Different owner.** `onMissing` lives *in* the roster. A roster cannot be the thing that authorises
   its own use — that is the config equivalent of a self-signed permission, and a global roster carrying
   `onMissing: auto` would silently spawn peers in every repo that falls back to it.
3. **Ordering already enforces it.** The scope gates run *before* the routing-preference block in
   `pretooluse-route-gate.mjs`, and scope A denies outright. `onMissing` is read inside the routing block,
   so it is unreachable until the scope question is answered. **No new code is needed to get this right —
   but a test must pin it** (§6 case 8), because a future refactor that hoists policy reading above the
   scope gates would silently invert it.

This holds for free precisely because everything in this spec happens **inside** the gate. It was the one
property `0022` would have had to re-establish by hand, and it is one of the reasons its withdrawal costs
nothing structural.

### 4.5 Not in scope

- **`route === "prefer-peers"`.** That route already means "spawn silently when no peer is live"; it has no
  prompt for `onMissing` to change. Leave it untouched.
- **`route === "subagents"`.** No peer path at all.
- **The `live.length > 0` branch** (`peersDenyReason`). `onMissing` is about *missing*; a live-but-busy
  peer is a different question, and conflating them would make `auto` mean two things.

## 5. Files to change

| File | Change |
|---|---|
| `agent-hierarchy/hooks/lib-roster.mjs` | `ON_MISSING_VALUES`, `ON_MISSING_DEFAULT`, one clause in `validateMember`. **Do not touch `normalizeMembers`** (§3.1, pending NEEDS-EVIDENCE #1). |
| `agent-hierarchy/hooks/pretooluse-route-gate.mjs` | `onMissingFor(resolved, role)` helper; the three-way branch in the `peers`/no-live arm (§4); `auto`'s deny reason + `on-missing-auto` gate record. Header comment updated — it is the file's own spec and currently describes the branch as unconditional. |
| `agent-hierarchy/hooks/roster.mjs` | `add`/`edit`: accept `--on-missing`, validate, §3.2's two-case handling (supplied → fail; inherited + route switch → delete + warn), reading supplied-ness from `opts` **before** the `{...existing}` merge (§3.2.1). Add `on-missing` to the value-taking flag handling — **not** `BOOL_FLAGS` (`0019` §3.2's lesson: a value-taking flag in `BOOL_FLAGS` silently becomes `true`). Usage banner. |
| `agent-hierarchy/hooks/lib-config.mjs` | `statusReport` / roster display: show each member's effective `onMissing`, marking defaulted values `(default)` and non-peer-eligible roles **`(inert: role is not peer-eligible)`** — the reason, not a bare `(inert)` (§3.3). |
| `agent-hierarchy/mcp/server.mjs` | `roster_member` add/edit: optional `on_missing` enum param → `--on-missing`. |
| `agent-hierarchy/skills/agent-roster/SKILL.md` | Document the three values, with `auto` worded as **"spawn without asking"** (§4.2), and the §4.4 non-bypass stated in one line. |
| `agent-hierarchy/tests/test-on-missing.sh` | **NEW**, §6. |
| `agent-hierarchy/tests/test-roster-cli.sh` | `--on-missing` round-trips through `add`/`edit`/`show`; invalid value rejected; §3.2's two cases (§6 cases 12–13). |
| `agent-hierarchy/tests/test-route-gate.sh` | The gate cases in §6 may fit here instead of a new file — Implementor's call; put them wherever the existing peer-fallback assertions live. |
| `.claude-plugin/plugin.json` + root `marketplace.json` | Version bump in **both**. |

## 6. Verification

Follow whatever harness `tests/test-route-gate.sh` already uses to feed the hook JSON on stdin and assert
on `permissionDecision` / `permissionDecisionReason` / `systemMessage`.

1. **Back-compat** — roster with no `onMissing` on any member: the peer-fallback branch is byte-identical
   to today (deny once with the three-option prompt, `peer-fallback-ask` recorded, re-issue passes).
2. **`prompt` explicit** — `onMissing: "prompt"` produces output identical to case 1.
3. **`never`** — no deny; the dispatch passes with a `systemMessage` naming the policy. No gate record
   written.
4. **`auto`** — first dispatch denied; assert **all four**: the reason contains the literal
   `spawn-one <role>` command **and** `--cwd`; the reason contains **no** `AskUserQuestion` instruction
   (that is what distinguishes `auto` from `prompt`); `on-missing-auto` is recorded; and the identical
   re-issue **passes** (§4.2's degradation).
5. **`auto` with no usable roster** — global-level roster with no scope-A allow, or no member for the role:
   falls back to `prompt`'s degraded two-option form, and the reason contains **no** `spawn-one` line
   (§4.3).
6. **`auto` does not leak into the live-peer branch** — a live instance exists: `peersDenyReason` fires
   unchanged regardless of `onMissing` (§4.5).
7. **`prefer-peers` unaffected** — `onMissing: "never"` with route `prefer-peers` and no live peer: passes
   silently as today, with no `onMissing` mention.
8. **Scope gate wins (§4.4)** — global-level roster, member has `onMissing: "auto"`, no scope-A answer
   recorded: the dispatch is denied by **scope A** (reason names the global roster and `msg.mjs
   global-scope roster`), **not** by the `auto` spawn instruction. This is the case that pins the ordering
   against a future refactor.
9. **Multi-member role** — role has two members with different `onMissing` values: the gate uses the
   **first** in roster order (§4).
10. **Validation** — `add --on-missing bogus` exits non-zero listing the three values;
    `add --on-missing` with no value exits non-zero naming `--on-missing` (never parsed as `true`).
11. **`(inert)` names its reason** — a `task-runner` member with `onMissing: "auto"`: `show` output
    contains `inert: role is not peer-eligible`, not a bare `(inert)` (§3.3).
12. **Supplied + subagent → fail** (§3.2(i)) — `add --role implementor --route subagent --on-missing auto`
    exits non-zero; and `edit --member <name> --route subagent --on-missing auto` on an existing peer
    member also exits non-zero. Both must name the route in the message.
13. **Inherited + route switch → cleared, warned** (§3.2(ii)) — **this is the trap case and must be shown
    to fail against pre-amendment-(c) code.** Seed a peer member with `onMissing: "auto"`, then
    `edit --member <name> --route subagent` with **no** `--on-missing`. Assert **all four**: exit 0; the
    member's `route` is now `subagent`; the `onMissing` key is **absent** from the written level file (not
    `null`, not retained); and stderr names the dropped value `"auto"`.
14. **Round-trip after clearing** — following case 13, `edit --member <name> --route peer --on-missing prompt`
    succeeds and the key is back. The transition is not one-way.
15. **Fingerprint stability** — a roster's team-history fingerprint is unchanged by this release for a
    roster that sets no `onMissing`, and (pending NEEDS-EVIDENCE #1) by setting one.

Regression bar: `test-route-gate.sh`, `test-roster-cli.sh`, `test-roster-levels.sh`, `test-team-history.sh`,
and `test-hierarchy-scope.sh` pass unchanged except for the cases this spec adds.

## 7. Decisions made here

- **`onMissing`, not `spawnPolicy`** (§2) — names the condition, not the mechanism, and cannot be misread
  as a sibling of `autoMode`.
- **Default resolved at the read site, not stamped into members** (§3.1) — protects the team-history
  fingerprint and keeps every existing roster file byte-identical.
- **Route switch clears an inherited `onMissing`; a supplied one still fails** (§3.2, amendment (c)).
  Reviewer's option (a) over option (b), for the reason in §3.2.2 — but split into two cases, because the
  undifferentiated version of (a) would silently swallow a genuine user contradiction. The discriminator
  is supplied-ness, read from `opts` before the merge.
- **`auto` = "spawn without asking", one orchestrator turn** (§4.2). The honest description of what a
  PreToolUse hook can do. The zero-turn alternative was designed, escalated, ruled on, and then dropped by
  the user in favour of this; `0022` retains that record.
- **`auto` reuses `0009` §5.2's availability guard and §5.3's degradation** rather than inventing new
  fallback semantics (§4.3, §4.2).
- **`auto` does not bypass the global-scope gate** (§4.4) — adopting the Orchestrator's recommendation,
  with the reasoning recorded and pinned by a test.

## 8. Open — not decided here

- **NEEDS-EVIDENCE #1** (§3.1) — does adding a member key change `fingerprint`? Decides whether
  `normalizeMembers` gains `onMissing`. Blocking for the schema half.
- **NEEDS-EVIDENCE #2** — read `hooks.json`'s PreToolUse ordering and confirm `pretooluse-route-gate.mjs`
  is the only hook that would consult `onMissing`. If `pretooluse-ultra-gate.mjs` has its own
  no-live-peer path for `ultra-advisor`, this spec must say whether `onMissing` applies there — I did not
  read that file and will not guess about the role with its own dedicated human-in-the-loop gate.

## 9. Confidence

High. Everything here is local to one branch of one hook plus a schema field: the read-site default, all
three policy values, the CLI/MCP surface, and §4.4's non-bypass are evidence-backed by the gate source and
fully reversible.

One pattern worth the Reviewer's attention, since amendment (c) is the second time it has bitten a spec of
mine (`0019` was the first): **a validation rule written against a merged object cannot distinguish what
the user just asked for from what was already there.** §3.2.1 is that lesson stated once; if another
field in this CLI ever grows a cross-field constraint, it will need the same split.
