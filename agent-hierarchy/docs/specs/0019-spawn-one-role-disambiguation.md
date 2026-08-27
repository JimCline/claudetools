# Spec 0019 — `spawn-one` must disambiguate same-role roster members

Status: draft
Supersedes nothing. Amends the `spawn-one` behaviour defined in `docs/specs/0009-global-roster-confirm-gate.md` §6.
Terms and naming rules: `docs/specs/0001-agent-roster.md` §3.4 (member naming), §5.1 (`team.json` shape).

**Amended (a) — spec-defect found in review, §3.3's already-live gate.** The original §3.3 derived the
already-live short-circuit from the **team-record** lookup, but liveness is decided by `memberIsLive`,
which reads a **different store**. On exactly the population this spec targets, the two disagree and the
command launches into a live agent name. §3.3 now gates on the selected target's liveness directly.

**Amended (b) — second spec-defect, same gate: (a) was necessary but not sufficient.** (a) replaced the
record-derived gate with a name-derived one, and §5 claimed that for a single-candidate role the two are
equivalent "in every reachable state". **That claim is false under alias drift (`0010` §7.2)**, and the
consequence is worse than the defect (a) fixed: a live peer loses its `team.json` row. The gate is now a
**disjunction over two names** — the selected name and the existing record's name — both registry reads.
§3.3(i), §3.3.1, §5, and §6 case 12 carry the fix; §7's "one predicate, one store" rule is unchanged and
is in fact what the fix follows.

## 1. Goal

`roster.mjs spawn-one <role>` resolves its target by **role alone**. When a roster defines two or more
members of the same role (`0001` §3.4 explicitly allows this: `bps-implementor`, `bps-implementor-2`, …),
`spawn-one implementor` always targets the *first* one. If that one is already live, the command either
short-circuits with `already live` or attempts a launch that collides with the running session
(`agent_name_taken`) — and the member that is actually missing is never spawned.

After this change, `spawn-one <role>` spawns the first member **of that role that is not already live**,
and an explicit `--member <name>` targets one specific same-role instance.

## 2. Root cause — three role-keyed lookups

All three are in the `case "spawn-one":` block of `agent-hierarchy/hooks/roster.mjs` (currently lines
~1309–1388). They are the whole bug; nothing in `lib-roster.mjs` needs to change.

| # | Current code | Problem |
|---|---|---|
| A | `const member = resolved.members.find((m) => m.role === role)` | Picks roster member #1 of the role, always. |
| B | `const existing = team && Array.isArray(team.members) ? team.members.find((m) => m.role === role) : null` — then `if (existing && memberIsLive(dir, existing.name)) → out({spawned:false, reason:"already live"})` | Reports "already live" based on a *different* member than the one that would be spawned — **and on a different store than the one that decides liveness (§3.3.1).** |
| C | `const idx = outTeam.members.findIndex((m) => m.role === role); if (idx === -1) push(newRecord) else outTeam.members[idx] = newRecord` | Overwrites the first same-role team record instead of appending a second one — so even if A and B were fixed, `team.json` would silently lose `bps-implementor` when `-2` spawned. |

`newRecord` already carries `name`, and `team.json` members are already name-bearing
(`teamMemberByName` matches on `m.name`), so keying by name needs no schema change.

## 3. Design

### 3.1 Target selection (replaces A)

```
candidates = resolved.members.filter(m => m.role === role)     // roster order preserved (0001 §3.4)
if candidates.length === 0            → today's error, unchanged
if opts["member"] given               → §3.2
if candidates.length === 1            → target = candidates[0]        // TODAY'S BEHAVIOUR, byte-identical
else                                  → target = first candidate whose name is not live,
                                        else the LAST candidate (all live → §3.4)
```

"not live" is `!memberIsLive(dir, candidate.name)`. `memberIsLive` is the **only** liveness predicate in
this block — §3.3 uses the same function on the same store, so selection and short-circuit can never
disagree about what "live" means.

Rationale for the single-candidate carve-out: it keeps the *selection* for a one-per-role roster
bit-for-bit unchanged. Note that this carve-out applies to selection and to the record-slot predicate —
**not** to the liveness gate, which is unconditional (§3.3(i), amendment (b)).

### 3.2 `--member <name>` (new flag)

```
roster.mjs spawn-one <role> --member <derived-name> [...existing flags]
```

- `<name>` is the **derived** name from `0001` §3.4 (`bps-implementor`, `bps-implementor-2`). Never a
  role, never an ordinal on its own.
- Resolution: `candidates.find(m => m.name === opts.member)`.
- Not found → `fail("spawn-one: no member named <name> for role <role> in the roster — it defines: <names…>")`,
  listing every derived name for that role.
- Name found but its role ≠ the positional `<role>` → the same failure (do not silently accept a
  cross-role name; the positional role stays authoritative and the flag only narrows within it).
- Add `"member"` to `SPAWN_ONE_FLAGS` so the existing unrecognized-flag guard accepts it, and add it to
  the usage banner at roster.mjs line ~32 and to the `unrecognized flag` error string (line ~1314).
- **`--member` takes a value.** It must NOT be in `BOOL_FLAGS`. A value-taking flag given with no value
  (`--member --dry-run`) must `fail` naming `--member`, never silently absorb the next token or degrade
  to `true` — the degraded case selects by §3.1's implicit rule while the caller believes they targeted
  a specific member, which is the worst available outcome. Assert it (§6 case 10).

### 3.3 Team-record keying and the already-live gate (replaces B and C)

Two separate concerns that the original text wrongly fused. Keep them separate:

**(i) Already-live gate — a disjunction over two names, both asked of the registry.**
*Rewritten by amendment (b).*

```js
const existingRecord = team && Array.isArray(team.members) ? team.members.find(matches) : null;   // (ii)
const liveRecord = existingRecord && memberIsLive(dir, existingRecord.name) ? existingRecord : null;

if (memberIsLive(dir, target.name) || liveRecord) {
  out({ spawned: false, reason: "already live",
        member: liveRecord || existingRecord || { role: target.role, name: target.name } });
  break;
}
```

Two distinct live-states must both short-circuit, and neither implies the other:

- **`memberIsLive(dir, target.name)`** — the name we are about to launch is already running. Catches
  amendment (a)'s defect: a registry-live member with no `team.json` record (the defect-C population).
- **`liveRecord`** — the *existing record for this slot* is running under a **different** name. Catches
  amendment (b)'s defect: alias drift (§3.3.1). `existingRecord` alone is not enough — a stale record for
  a dead session must not block a legitimate spawn, which is why liveness is asked about its name too.

`member:` prefers `liveRecord` (the thing that is actually running, and the name a user must act on),
falls back to `existingRecord`, then to a synthesised `{role, name}` when no record exists at all.

**This is still one predicate over one store.** `memberIsLive` is asked about two names; both are registry
reads. The rule §7 states — *"is this name in use" comes from the registry, "which record do I rewrite"
comes from `team.json`* — is what produces this shape, not an exception to it.

**(ii) Team-record slot — keyed by name only when the role has more than one roster candidate:**

```js
const byName = candidates.length > 1;
const matches = (m) => (byName ? m.name === target.name : m.role === role);
const idx = outTeam.members.findIndex(matches);
```

Keep this as ONE predicate used by both the read (`existingRecord` above) and the write — a divergence
between "which record describes this member" and "which slot do I overwrite" is how defect C loses records.

#### 3.3.1 Why the stores disagree — two distinct populations, do not re-fuse them

`memberIsLive(dir, name)` reads `latestRoster(dir)` — the pid/check-in **registry** (`peers.jsonl`), keyed
by name. The record lookup reads **`team.json`**. Different files, different lifetimes. Two populations
where they disagree, each producing a different bug:

**Population 1 — registry-live, no record (amendment (a)).**

> A same-role member is live in the registry but has **no `team.json` record**, because defect C
> overwrote its slot when a sibling of the same role was spawned.

Under the pre-(a) text, `existingRecord` is `null`, the short-circuit is skipped, and `spawn-one` launches
into a name that is already running → `agent_name_taken`. The `memberIsLive(dir, target.name)` disjunct
closes it.

**Population 2 — record-live under a stale name (amendment (b)), single-candidate role.**

> A single-implementor roster. `team.json` holds `old-implementor`, still live and pid-alive in the
> registry. The team alias changes (`0010` §7.2), so the roster now derives `new-implementor`.

Under the post-(a) / pre-(b) text: `memberIsLive("new-implementor")` is **false** — that name was never
live — so `spawn-one` proceeds and launches a **second** live pane for the same role. Then the role-keyed
`idx` (`byName` is false for a single candidate) **overwrites `old-implementor`'s `team.json` row** with
the new one. The still-running old session loses its record, and dispatch to it breaks. In the same run,
`warnMixedPrefixSpawnOne` prints *"every name still resolves from team.json, so dispatch is unaffected"* —
which its own overwrite has just made false. It also violates `0009` §6.3 step 4: a live member must yield
a no-op, never a duplicate peer.

The `liveRecord` disjunct closes it, and restores `0010` §7.2's live-drift no-op exactly.

**Consequences to preserve, both of them:**
- A `null` `existingRecord` is a normal state (population 1), not an anomaly.
- A live `existingRecord` under a name that differs from `target.name` is also a normal state
  (population 2), and must short-circuit.

Any later refactor that collapses the gate to `existingRecord && memberIsLive(...)` reopens population 1;
any refactor that collapses it to `memberIsLive(target.name)` alone reopens population 2. **Both disjuncts
are load-bearing.** Say so at the call site.

### 3.4 All candidates live

When every member of the role is already live, §3.1 selects the last candidate and §3.3(i) fires on it.
Report, do not spawn:

```json
{"spawned": false, "reason": "already live", "member": {…},
 "role": "implementor", "candidates_live": ["bps-implementor", "bps-implementor-2"]}
```

`candidates_live` is `candidates.filter(c => memberIsLive(dir, c.name)).map(c => c.name)` — computed from
the same predicate, not inferred from `team.json`. It is new and additive; existing consumers keying on
`spawned`/`reason` are unaffected — verify that claim against `mcp/server.mjs` and
`tests/test-roster-spawn-one.sh` before shipping.

This also preserves `0009` §6.3 step 4's idempotence contract: a live member yields a zero-exit no-op,
never a duplicate peer.

### 3.5 Interaction with alias/prefix drift (spec 0010 §7.2)

`warnMixedPrefixSpawnOne(dir, member)` exists because a team alias change makes the derived name shift,
so a role's live team record can carry a *stale* name.

**For a single-candidate role, the live-drift case is now a no-op** (§3.3(i)'s `liveRecord` disjunct) —
which is what `0010` §7.2 always intended and what the pre-(a) code accidentally delivered. The warning
still fires for the *dead*-drift case, where the stale record's session is gone and the spawn legitimately
proceeds and overwrites the slot.

For a multi-candidate role, name-keying means a stale-named record is not overwritten — it would be left
behind alongside a new one. Accepted, because:

- the existing `warnMixedPrefixSpawnOne` warning already fires and tells the user, and
- silently deleting a *live* differently-named session's registry row is worse than leaving a warned-about
  duplicate the user can `disband`/`dismiss`/`move`.

Call `warnMixedPrefixSpawnOne(dir, target)` with the **selected** target, not `candidates[0]`.

### 3.6 Surfaces that must carry the new flag

- `agent-hierarchy/mcp/server.mjs` — the `roster_spawn_one` tool. Add an optional `member` string
  parameter, documented as "derived member name, to disambiguate two same-role roster members", passed
  through as `--member`. Its `role` parameter stays required.
- `agent-hierarchy/skills/agent-roster/SKILL.md` — wherever `spawn-one` is documented, add one line:
  bare `spawn-one <role>` picks the first member of that role that is not live; `--member <name>` targets
  a specific one.
- `agent-hierarchy/hooks/roster.mjs` usage banner (line ~32).

## 4. Files to change

| File | Change |
|---|---|
| `agent-hierarchy/hooks/roster.mjs` | `SPAWN_ONE_FLAGS` += `member` (value-taking, NOT in `BOOL_FLAGS` — §3.2); usage banner; §3.1 selection; §3.2 flag resolution incl. the missing-value failure; §3.3 two-disjunct gate + name-keyed slot; §3.4 output; §3.5 pass `target` to `warnMixedPrefixSpawnOne`. **Only the `case "spawn-one"` block and the two constants.** |
| `agent-hierarchy/mcp/server.mjs` | `roster_spawn_one`: optional `member` param → `--member`. |
| `agent-hierarchy/skills/agent-roster/SKILL.md` | One-line doc of the new selection rule + `--member`. |
| `agent-hierarchy/tests/test-roster-spawn-one.sh` | New cases, §6. |
| `agent-hierarchy/tests/test-team-alias.sh` | New case 12 (§6) — the same-role live-stale drift case. Existing case 25 does **not** cover it (§6). |
| `agent-hierarchy/tests/test-mcp-server.sh` | One case for `member` passthrough. |
| `agent-hierarchy/.claude-plugin/plugin.json` **and** root `marketplace.json` | Version bump in **both** — this repo requires it. |

## 5. What must NOT change

- `lib-roster.mjs` — no change at all. `teamMemberByName`, `teamMembersForRole`, `resolveMemberTeam`
  are already name-correct.
- `memberIsLive` itself — its registry-backed definition is correct and is what makes §3.3(i) work.
  Do not "fix" it to read `team.json`; that would recreate population 1 from the other side.
- `create --spawn`'s launch path and `layoutAndLaunch` — `spawn-one` was extracted from it, not forked;
  keep it that way. No new copy of the launch logic.
- **Observable behaviour for a roster with one member per role**, in every state reachable today: the
  `already live` no-op (including the alias-drift live case, §3.3.1 population 2), the dead-record
  overwrite, the orchestrator-pid refusals (spec 0018), the `--allow-global` gate (0009 §6.4), and the
  `already live` output shape.
  *(Amendment (b) removed the original claim that the record-derived and name-derived gates are equivalent
  here. They are not — §3.3.1 population 2 is the counterexample — which is precisely why the gate is a
  disjunction rather than a substitution. What is preserved is the observable behaviour, not the
  predicate.)*
- Roster member naming (`0001` §3.4) and the rule that a roster member never stores a `name`.
- `team.json` schema. Records already carry `name`; nothing is added to a member record.
- The `--dry-run` output shape, except that it now names the selected member.

## 6. Verification

Extend `agent-hierarchy/tests/test-roster-spawn-one.sh` (existing standalone-bash convention,
HOME-redirect + `--cwd` injection, fake `claude`/`herdr` on PATH as the file already does):

1. **Regression** — roster with one implementor, none live: spawns `<repo>-implementor`. Output identical
   to before the change.
2. **The reported bug** — roster with implementor + implementor-2, `team.json` lists `<repo>-implementor`
   as live: `spawn-one implementor` spawns `<repo>-implementor-2`, and `team.json` afterwards contains
   **both** records.
3. **Ordering** — same roster, `-2` live and `-1` absent: `spawn-one implementor` spawns
   `<repo>-implementor` (roster order, first-not-live — not "next after the live one").
4. **All live** — both live: `spawned:false`, `reason:"already live"`, and **assert `candidates_live`
   contains both names** (asserting only `spawned:false` passes even if the key is missing).
5. **`--member` hit** — `--member <repo>-implementor-2` with neither live spawns `-2`, not `-1`.
6. **`--member` miss** — `--member <repo>-implementor-9` fails non-zero with a message listing the real names.
7. **`--member` cross-role** — must exercise a **multi-candidate** role, not a single-candidate one:
   roster has implementor + implementor-2 + reviewer; `spawn-one implementor --member <repo>-reviewer`
   fails non-zero. (A single-candidate variant passes for the wrong reason.)
8. **`--dry-run`** with two candidates and #1 live names `-2` in its output and launches nothing.
9. **No slot loss** — after #2, `readTeam(...).members` has two entries with distinct `name`s and both
   `role: "implementor"`.
10. **`--member` with no value** — `spawn-one implementor --member --dry-run` exits non-zero naming
    `--member`. Must NOT be silently parsed as `member: true` plus `dry-run: true` (§3.2).
11. **Registry-live, team-record-absent (population 1, amendment (a))** — roster has implementor +
    implementor-2; the registry lists `<repo>-implementor-2` as live; `team.json` has **no record** for
    it. `spawn-one implementor` must NOT launch `-2`. **Must be shown to fail against a build using the
    pre-(a) §3.3 text.**
12. **Record-live under a stale name (population 2, amendment (b))** — **single** implementor in the
    roster; `team.json` holds `old-implementor` **and** the registry has a live entry for that same name;
    the team alias has changed so the roster now derives `new-implementor`. Assert **all four**:
    `spawned:false` / `reason:"already live"`; the fake `claude` was **never invoked**; `team.json` is
    **byte-identical** afterwards; and the emitted `member.name` is `old-implementor` (the thing actually
    running), not `new-implementor`. **Must be shown to fail against a build using the pre-(b) §3.3 text**,
    where it launches a second pane and overwrites the row.
    **Note:** `tests/test-team-alias.sh` case 25 does **not** cover this. It seeds a *cross-role* stale
    record with **no** registry entry, so `existingRecord` is null under both old and new code and the
    case passes either way. This needs a **same-role, registry-live** stale record.

Regression bar: every existing `agent-hierarchy/tests/test-*.sh` passes unchanged — in particular
`test-roster-spawn-one.sh`'s pre-existing cases, `test-team-alias.sh` (0010 §7.2 drift),
`test-roster-global-gate.sh`, `test-orchestrator-identity.sh`, and `test-mcp-server.sh`.

## 7. Decisions made here (and why)

- **First-not-live, in roster order** rather than "lowest free ordinal computed from `team.json`". Roster
  order is already the authority for naming (`0001` §3.4); deriving a second ordering from the registry
  would be a second source of truth.
- **One liveness predicate, one store.** `spawn-one` decides "is this name in use" from the registry, and
  "which record do I rewrite" from `team.json`, and never lets one stand in for the other. Amendment (b)'s
  disjunction is this rule applied twice — two names, one registry — not an exception to it. Both
  amendments came from the same root error: treating a `team.json` lookup as evidence about liveness.
- **`--member` added.** The Orchestrator's brief asked whether it is needed; it is. Without it there is no
  way to respawn a *specific* dead instance when two of a role exist and one is live — the implicit rule
  would always pick the one that is down, which is right, but it gives no way to express intent when the
  user wants a named one, and it makes the MCP surface undiagnosable. It is additive and optional.
- **Single-candidate carve-out applies to selection and the record slot, not to liveness** (§3.1, §3.3).
  Amendment (b) is what forced that distinction; the original text applied it too broadly.

## 8. Open / not decided here

- **User's call, not mine:** should `spawn-one <role>` with all candidates live be an *error* (non-zero)
  rather than a `spawned:false` success? Today's single-member behaviour is a zero-exit report; §3.4 keeps
  that for consistency. If the Orchestrator scripts around exit codes, this may be the wrong default.
- **NEEDS-EVIDENCE #2** — confirm no other caller of `roster.mjs spawn-one` (hooks, `sessionstart.mjs`,
  `pretooluse-route-gate.mjs`, `mcp/server.mjs`) parses the `already live` JSON in a way that the new
  `candidates_live` key, a changed `member` value, or a `member` derived from no team record would break.
  Grep for `already live` and `spawned` across `agent-hierarchy/` and report each consumer.

*(NEEDS-EVIDENCE #1 — `memberIsLive`'s keying — is resolved: it reads `latestRoster` by name, a different
store from `team.json`. That answer produced both amendments; see §3.3.1.)*

## 9. Confidence

High on the fix as it now stands. But the honest read of this spec's history is worth recording: **two
review rounds found the same class of error in the same three lines.** Both came from reasoning about
liveness in terms of the team record rather than the registry, and the second was hidden behind a
correctness claim I made in §5 without being able to run the alias-drift path.

What follows for the reviewer: check that the gate's **two disjuncts are both present and both reachable**
(§6 cases 11 and 12 are the ones that distinguish them), and treat any §5-style "these are equivalent in
every reachable state" claim in this spec as unverified unless a test pins it. No escalation recommended —
the fix is two lines and the failure mode is now covered by tests that must fail first.
