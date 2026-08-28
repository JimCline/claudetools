# 0025 — `create --commit` member validation, and resync as the repair path

Status: design. One spec, four changes, one NEEDS-EVIDENCE item.
**Amended 2026-08-27:** E1 came back "names absent"; §8 is resolved and the
cwd-fallback design it gated is now §12–§14. §3/§4/§6/§7 are unchanged and
already implemented — this amendment is purely additive.
Author: Architect. Spec path was NOT dictated by the dispatch; `0025` follows the
established `docs/specs/NNNN-slug.md` convention (0024 was the highest existing).

## 1. Goal

Two asks from a peer session (waves repo) that had four live peer sessions and
no usable `team.json`:

1. `create --commit` must reject malformed `verified` entries instead of writing
   them into `team.json`.
2. There must be a supported path from "the team is alive" to "the tracking file
   says so", without hand-editing `team.json`.

These are one spec because they are the same surface — the integrity of
`team.members` — and because the fixes interlock: validating (or hydrating) at
commit is useless unless something can then fill in each member's live pane, and
that something is `resync`, which today is itself a corruption source.

## 2. Root cause — the peer's diagnosis is wrong, and the correction matters

The peer reported "the MCP layer turned a JSON-string-array into char-indexed
garbage objects". **It did not.** The MCP layer is clean end to end:

- `mcp/server.mjs:193` declares `verified: { type: "string" }`.
- `mcp/server.mjs:531` rejects the call outright unless `typeof args_in.verified
  === "string"`.
- `mcp/server.mjs:542` → `pushArg`, which is `args.push('--verified',
  String(value))` (`mcp/server.mjs:403-406`). A string round-trips unchanged.

The actual chain, entirely inside `hooks/roster.mjs`:

**Step 1 — commit writes whatever it parsed, unvalidated.**

```js
// roster.mjs:1081
const verified = typeof opts.verified === "string" ? JSON.parse(opts.verified) : fail("--commit needs --verified <json array>");
// roster.mjs:1107
members: verified,
```

`--verified` is specified to carry an array of **member objects** (that is what
the spawn/check-in cycle produces). The peer passed an array of **names**. Nothing
checks. `team.members` became `["waves-architect", "waves-implementor", ...]`.

**Step 2 — `move` reports "(none)".** `roster.mjs:1465-1466` does
`teamMembers.find((m) => m.name === name)`, then on failure prints
`teamMembers.map((m) => m.name).filter(Boolean).join(", ") || "(none)"`. Strings
have no `.name`, so every entry filters out. This is the exact reported message,
and it is a *symptom*, not the bug.

**Step 3 — `resync` created the char-indexed garbage and persisted it.**

```js
// roster.mjs:366-369
if (m.route !== "peer" || m.transport_id == null) {
  counts.skipped++;
  return { ...m, status: "skipped" };
}
```

`m` is a string. `m.route` is `undefined`, so every member is skipped — that is
the peer's "skipped all 4, no-op". And `{ ...m }` **spreads a string into an
object literal**, which produces exactly `{"0":"w","1":"a","2":"v", ...}`. The
result is then written back to disk:

```js
// roster.mjs:1445-1446
team.members = result.members.map(stripResyncMeta);
writeTeam(dir, team, teamArg);
```

So `resync` — the tool reached for to repair the file — is what corrupted it.
The strings on disk were at least still readable; the char-indexed objects were
not, which is why hand-editing became the only way out.

Confidence: high. This is a straight read of the code and it reproduces every
observed symptom, including the specific shape of the garbage.

## 3. Change 1 — validate team members at the commit boundary

**File:** `agent-hierarchy/hooks/lib-roster.mjs` (new exported function).

Add `validateTeamMember(m)` returning an array of error strings, mirroring the
existing `validateMember` in style and placement.

**Do NOT reuse `validateMember` for this.** `lib-roster.mjs:122` makes it reject
any member carrying a stored `name` — correct for *roster config* members, where
names are derived at resolve time, and wrong for *team* members, which are
written with a `name` by the spawn path (`roster.mjs:768`, `roster.mjs:1620`).
Reusing it would reject every legitimately committed member.

Checks:

- `m` is a non-null non-array object — else `["member must be an object, got <JSON.stringify(m)>"]` and return immediately.
- `m.role` ∈ `ROLES`.
- `m.name` — **required and a non-empty string only when `m.route === "peer"`.**
  For any other route it may be a non-empty string OR `null`/absent; `""` is
  invalid on every route.

  Rationale (amendment, 2026-08-27): a subagent-routed member has no pane, and
  `name` exists to address one. SKILL.md documents BOTH shapes — the hand-built
  commit array carries `name`/`ref`/`transport_id` null (SKILL.md:373, :388),
  while `auto` mode builds from `--spawn`'s `members[]`, which gives non-peer
  members a real derived name (`roster.mjs:781`, SKILL.md:389-391). Both are
  legitimate; validation accepts both. Three shipped fixtures
  (`tests/test-roster-disband.sh:73`, `tests/test-roster-resync.sh:74`,
  `tests/test-roster-disband-close.sh:68`) commit the null-name shape, so an
  unconditional rule breaks tested behaviour. Downstream already tolerates a
  null name (`roster.mjs:742` guards `m.name && m.role`; `move` refuses non-peer
  members at `:1520`); only `dismiss` (`:1324`) addresses by name, which is the
  documented limitation, not a regression introduced here.
- `m.route` ∈ `ROSTER_ROUTE_VALUES`.
- `m.transport_id`, if present, is a string or `null`.
- `m.tab_id` / `m.workspace_id`, if present, are a string or `null`.
- `m.model` / `m.effort` / `m.auto_mode` are NOT re-validated here — they are
  carried through from the roster config, which validated them already.

**File:** `agent-hierarchy/hooks/roster.mjs`, commit branch, immediately after
`roster.mjs:1081`.

- If the parse result is not an array: `fail('--verified must be a JSON array, got <type>')`.
- Run `validateTeamMember` over every entry. On any error, `fail()` with a
  message that names each offending index and its errors, and states the two
  accepted shapes. The message must be actionable — the peer's session had no
  way to tell what was wrong. Required substance:

  > `create --commit: --verified entry 0 is not a valid member: member must be an object, got "waves-architect". --verified takes either a JSON array of member objects (as produced by the spawn/check-in cycle) or a JSON array of member-name strings (hydrated from the roster at --roster-level).`

## 4. Change 2 — accept an array of names and hydrate

This is what the peer actually wanted, and the dispatch asks for validation
"against real member names present in the resolved roster", so hydration is the
same requirement stated positively.

**File:** `agent-hierarchy/hooks/roster.mjs`, commit branch.

After parsing and confirming an array, branch on entry type:

- **All entries are strings** → hydrate. Resolve the roster at `--roster-level`
  for `cwd` and derive member names using the *same* derivation the `show` and
  `spawn-one` paths use (`namedMembers`, `roster.mjs:168` — Implementor: confirm
  its exact signature and the resolve call it needs, and reuse it rather than
  re-deriving names, so there stays one name-derivation implementation). For each
  string, find the roster member with that derived name. Unknown name →
  `fail("create --commit: --verified names no member <name> in the <level> roster — it defines: <names> ")`, matching the phrasing already used at
  `roster.mjs:1555`. Each hydrated entry gets `role`, `name`, `model`, `effort`,
  `route`, `autoMode` from the roster, and `transport_id: null`, with `tab_id`
  and `workspace_id` omitted.
  (The key is camelCase `autoMode`, matching the launch path at
  `roster.mjs:781`/`:783` — NOT `auto_mode`. Only `normalizeMembers`
  (`lib-roster.mjs:287`) converts to snake_case, and only for the history
  record. An earlier draft of this spec said `auto_mode` here; that was a
  spec-side typo, and the Implementor was right to use `autoMode`.)
- **All entries are objects** → validate per §3, write as today. Unchanged path.
- **Mixed** → `fail()`; do not guess.

A hydrated commit produces members that are correct but have no panes. `move`
will still refuse them (`roster.mjs:1467`, "has no pane to move") until §5 runs.
That is the intended two-step: **commit registers who, resync discovers where.**
Say so in the commit output — add `"needs_resync": true` to the emitted object
when any member was hydrated, so the caller is told the next step rather than
hitting a confusing `move` failure.

## 5. Change 3 — `resync` becomes the repair path for live-but-untracked members

This is ask (2), and it needs almost no new machinery, because
`matchMemberToPane` (`roster.mjs:336-346`) **already matches by name first** and
only falls back to `transport_id`. The single thing preventing repair is the
skip guard.

**File:** `agent-hierarchy/hooks/roster.mjs:366`.

```js
if (m.route !== "peer") {
```

Drop the `|| m.transport_id == null` clause. A peer member with a null
`transport_id` then flows into the normal match path: matched → `status:
"updated"` with `from.transport_id: null`, and the healed entry is written;
unmatched → the existing `status: "not_found"` handling, which is already
correct for "declared but not running".

Why this is safe: name is already the primary match key for members that *do*
have a `transport_id`, so a null one does not widen the collision surface, and
the existing `claimed` set (`roster.mjs:371-374`) still prevents two members
claiming one pane.

**No new tool, no new MCP surface.** Do not add `roster_member repair` or a new
`roster_resync` mode. `resync` is already "re-derive every peer member's herdr
location from live topology" — a member with no recorded location is squarely
inside that contract, and it was only ever excluded by the guard.

> **Amendment note (E1 resolved):** §5 is correct and stays, but it repairs only
> members whose name herdr already knows. E1 came back "names absent" for panes
> roster.mjs did not label — which is the peer's actual scenario — so §5 alone
> repairs nothing there. §12 adds the fallback.

## 6. Change 4 — `resync` must never rewrite an entry it did not understand

Defence in depth, and the fix for `team.json` files already corrupted in the
wild (the peer's repo, and any other that ran `resync` over a bad commit).

**File:** `agent-hierarchy/hooks/roster.mjs`, top of the `team.members.map`
callback in `resyncMembers` (`roster.mjs:365`).

```js
if (!m || typeof m !== "object" || Array.isArray(m)) {
  counts.malformed = (counts.malformed || 0) + 1;
  return m;   // byte-identical passthrough — never spread a non-object
}
```

Requirements:

- Return the **original value**, not a copy. `{ ...m }` on a string is the
  corruption; that must not survive anywhere in this function.
- Add `malformed` to the `counts` object initialised at `roster.mjs:363` so the
  key is always present.
- These entries have no `role`/`name`/`status`, so the per-member output
  projection at `roster.mjs:1437-1444` must tolerate that: emit
  `{ status: "malformed", raw: m }` for them rather than
  `{ role: undefined, name: undefined }`.
- When `counts.malformed > 0`, set a warning on the resync output naming the
  recovery: re-run `create --commit` with `--verified` as an array of member
  names (§4). Reuse the existing `resyncOut.warning` channel
  (`roster.mjs:1449`); if a duplicate-pane warning is also present, both must be
  reported — make `warning` an array, or emit the malformed one under a distinct
  key. Implementor's call, but neither may silently drop the other.
- `resync` must still exit 0 in this case. Do **not** `fail()` on a corrupt
  member — that would block the very recovery being reported.
- `stripResyncMeta` (`roster.mjs:395-398`) must carry the same passthrough
  guard: it destructures `{ status, from, to, ...member }`, which on a
  non-object produces the identical char-indexed corruption this section
  exists to prevent. Return the original value unchanged when it is not a
  non-null non-array object. Without this, the guard in `resyncMembers` is
  defeated on the write path at `roster.mjs:1445`.

The same passthrough guard makes `move`'s inline `resyncMembers` call
(`roster.mjs:1509`) non-destructive too, for free.

## 7. Change 5 — the MCP description that misled the caller

**File:** `agent-hierarchy/mcp/server.mjs:193`.

The description reads "JSON array, passed to --verified verbatim", which does not
say an array *of what*. That ambiguity is the proximate cause of the peer's call.
Replace with wording naming both accepted shapes: a JSON array of member objects
(from the spawn/check-in cycle) or a JSON array of member-name strings (hydrated
from the roster). Mirror the same clarification in `roster.mjs`'s usage text at
`roster.mjs:16`.

Keep `type: "string"` and keep the `typeof` guard at `mcp/server.mjs:531`. Do
**not** make the schema accept a real array: `pushArg` would `String()` it into
`a,b,c` and silently produce a single mangled argument. String-only is correct.

## 8. NEEDS-EVIDENCE — E1 — **RESOLVED 2026-08-27**

The question was whether `herdr agent list` reports a usable `name` for a session
roster.mjs did not spawn.

**Answer: names are ABSENT.** Panes hosting an orchestrator or a manually-started
session carry no `name` key; only roster-spawned peers (labelled via `labelPane`,
`roster.mjs:576`) do. `cwd` is present on every entry.

Per the branch this spec already committed to, §5 therefore does not repair the
peer's scenario on its own, and the cwd-based fallback is required. It is
designed in **§12**, with its own new evidence gate in **§13**.

## 9. What must NOT change

- `validateMember` (`lib-roster.mjs:102`) keeps rejecting a stored `name`. It
  governs roster-config members; do not relax it to serve team members.
- `pushArg` (`mcp/server.mjs:403`) stays type-agnostic. Do not add array
  handling.
- `verified` stays `type: "string"` in the MCP schema, and the `typeof` guard at
  `mcp/server.mjs:531` stays.
- `resync` keeps exiting 0 on a corrupt team file.
- No new MCP tool and no new roster subcommand. Ask (2) is served by relaxing an
  existing guard (§5) plus one new flag on `resync` (§12).
- `normalizeMembers` (`lib-roster.mjs:287`) and the history path are untouched.
- **(amendment)** Name matching stays the highest-priority tier. cwd is never
  allowed to re-home a member that a name or `transport_id` match already
  resolved (§12.2).
- **(amendment)** `resync` never binds a member to a pane by positional order.
  See §12.4.

## 10. Verification

Add tests beside the existing roster commit/resync tests:

1. `create --commit --verified '["a","b"]'` with names present in the roster →
   `team.json` holds two well-formed member objects with `transport_id: null`,
   and the output carries `needs_resync: true`.
2. Same, with one name absent from the roster → non-zero exit, message names the
   unknown name and lists the roster's names.
3. `create --commit --verified '[{...}, "oops"]'` (mixed) → non-zero exit.
4. `create --commit --verified '["a"]'` where the roster has no such member →
   `team.json` is **not written** (failure precedes the write).
5. **Regression, the load-bearing one:** given a `team.json` whose `members` is
   `["waves-architect"]`, `resync` exits 0, leaves that entry byte-identical on
   disk (assert the file's raw text, not a parsed comparison — a parsed one
   passes against `{"0":"w",...}`), reports `counts.malformed === 1`, and emits
   the recovery warning.
6. A peer member with `transport_id: null` whose name matches a live pane is
   healed by `resync` to `status: "updated"` with `from.transport_id === null`.
6a. `create --commit` with a subagent-routed member carrying `"name": null`
    (the SKILL.md:388 recipe shape) → succeeds, and `team.json` records the
    member with `name` still null. This is the regression the unconditional
    rule broke; no test covered it, which is why the suite was green.
6b. `create --commit` with a subagent-routed member carrying a real derived
    name (the `--spawn` auto-mode shape, `roster.mjs:781`) → also succeeds.
    Both shapes are valid input.
6c. `create --commit` with any member carrying `"name": ""` → non-zero exit,
    on every route.
6d. `create --commit` with a PEER-routed member carrying `"name": null` →
    non-zero exit. The carve-out is route-scoped and must not widen.

§14 adds the tests for §12.

## 11. Confidence and limits

- §2's root cause: **high confidence**, read directly from the code, and it
  accounts for all three reported symptoms including the exact garbage shape.
  The peer's MCP-mangling theory is refuted, not merely doubted.
- §3, §4, §6, §7: high confidence, small and local.
- §5: the guard is confirmed to be what blocks repair. E1 is now resolved and
  shows §5 is necessary but **not sufficient** for unlabelled panes — see §12.
- The one thing I could not verify by reading: `namedMembers`' exact signature
  and the resolve call §4 needs to reach it (I have its line, not its body). It
  is an existing helper on the `show`/`spawn-one` path, so this is an
  implementation detail, not a design fork.
- No Ultra-Advisor escalation needed.

---

# Amendment — pane identity (closes §8, revised after E2/E3)

## 12. Change 6 — matching a live pane to a member

### 12.1 What E2 and E3 settled

**E2: herdr exposes no pid.** Confirmed live against `herdr agent list` and
`herdr pane list`; the field set is `{name?, pane_id, tab_id, workspace_id}` plus
cwd. peers.jsonl cannot be joined to herdr topology by process id.

**E3: every herdr-launched pane knows its own identity.** `HERDR_PANE_ID`,
`HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` are set in each pane's environment.
`HERDR_PANE_ID` is already consumed by this repo (`roster.mjs:647-648`,
`roster.mjs:1032-1033`), so this is an established idiom, not a new dependency.

E3 is the more important result, but NOT for the reason it first appears. A
session can identify its own pane — yet the session being repaired is never the
session running `resync`. The Orchestrator repairs its peers, and it cannot read
another process's environment. A `--self` fast path would serve only "a peer
fixes its own row", which is not the reported problem. **Rejected: no `--self`
flag.**

What E3 unlocks instead: a peer can WRITE its pane identity where the Orchestrator
can read it later. That is §12.2.

### 12.2 Peers self-report their pane at SessionStart

**File:** `agent-hierarchy/hooks/sessionstart.mjs:90-97`.

Extend the existing `appendRosterRecord` "up" record with three fields:

    appendRosterRecord(dir, {
      status: "up",
      role,
      session_id: input.session_id || null,
      pid: process.ppid,
      ppid: process.ppid,
      cwd,
      pane_id: process.env.HERDR_PANE_ID || null,
      tab_id: process.env.HERDR_TAB_ID || null,
      workspace_id: process.env.HERDR_WORKSPACE_ID || null,
    });

That is the whole write side. peers.jsonl now carries an exact role+cwd →
pane identity mapping, self-reported by each peer in its own process, which is
what E2 could not supply from herdr's side.

Keep the surrounding `try/catch` and its "roster is best-effort" comment: a
missing env var must never cost the session its role notice.

Three scope limits, to be stated in the spec rather than discovered later:

- Only `claude --agent ah:<role>` sessions write an up record at all
  (`sessionstart.mjs:82` guards `!isSubagent(input)`, `:86` guards `if (role)`).
  A plain session in a pane writes nothing.
- Only sessions started AFTER this ships have the new fields. Existing live
  sessions do not, and are repairable only by §12.5.
- Only under herdr. Elsewhere the fields are null and the tier is skipped.

### 12.3 Carry cwd through topology, and make matching multi-pass

**File:** `agent-hierarchy/hooks/roster.mjs`, `queryHerdrTopology` (`:328-335`).

Add cwd to the projection, accepting either key — E1 reported cwd present as
`cwd`/`foreground_cwd`, and the repo consumes neither today:

    cwd: a.cwd || a.foreground_cwd || null,

Update the doc comment at `:325-330` to record the added field and its
provenance, matching how that comment already records the rest.

**`resyncMembers` becomes multi-pass.** Today it is a single `map` in member
order sharing one `claimed` set (`:371-388`). A weaker tier added inline would
let an early member steal a pane a later member would have matched exactly.
Passes run in strict order, each claiming into the shared `claimed` set:

- **Pass 1 — identity.** Existing `matchMemberToPane` (name, then
  `transport_id`). Behaviour for every member matching here is UNCHANGED.
- **Pass 2 — peers.jsonl self-report (§12.4).** Exact.
- **Pass 3 — cwd narrowing (§12.5).** Inferential, tightly gated.

Passes 2 and 3 consider only members left unmatched AND whose `transport_id` is
`null` — the repair case. A member that HAD a `transport_id` and failed pass 1
stays `not_found`: it moved or died, and must not be re-homed onto another
session's pane by a weaker signal.

All cwd comparisons are realpath-normalised on both sides, via a small local
helper — `realCwd` — added for this purpose.

Correction (amendment, 2026-08-27): an earlier draft of this section said to
reuse "this plugin's existing realpath-based cwd-mismatch helper". **No such
helper exists.** A repo-wide search for `realpath`/`realpathSync`/`cwdMismatch`/
`sameCwd`/`normalizeCwd`/`cwdMatches` returns only this change's own additions.
The claim came from misreading a commit-message line about a realpath-based
SessionStart *guard*, which is not a reusable path utility. Build the local
helper; do not spend time hunting for one to reuse.

`realCwd` must: resolve symlinks, strip trailing slashes, and on ANY failure
return its input unchanged. That degradation direction is load-bearing — a
failed normalisation must produce a non-match (a refusal to bind), never a
false match. Every failure mode of this helper is a missed repair, which is
recoverable; the opposite would bind a member to the wrong pane, which is not.

Members carry no cwd of their own and need none — every member of a team shares
the team's directory by construction (`roster.mjs:653`).

### 12.4 Pass 2 — the exact tier

Read peers.jsonl with the existing `readRoster` (`lib-hier.mjs:457-459`) and
latest-per-key + liveness logic already used at `roster.mjs:754-757`
(`latestRoster`, `pidAlive`). A candidate record must satisfy all of:

- `status === "up"` and not superseded by a later `down` for that session;
- `pidAlive(rec.pid)`;
- `rec.pane_id != null`;
- `rec.cwd` realpath-equals the team's directory;
- `rec.role === member.role`;
- `rec.pane_id` exists in the live herdr topology (a dead session's pane may have
  been recycled — trust the record for identity, never for liveness);
- that pane is unclaimed, and is not the caller's own pane (§12.6).

If exactly ONE record satisfies all of the above for exactly ONE member awaiting
repair, bind it: `status: "updated"`, `from.transport_id: null`,
`match_by: "peers_jsonl"`. Take `tab_id`/`workspace_id` from the LIVE topology
entry, not from the record — the pane may have been moved since startup.

If two members share a role and both await repair, the role key cannot separate
them: both fall through to pass 3, and in practice to §12.5's ambiguity report.
Do not guess by recency; a newer `up` record does not mean "this member".

`match_by` is a new field and must be emitted on every pass-2 and pass-3 bind, so
a reader can always tell an exact location from an inferred one.

### 12.5 Pass 3 — cwd narrowing, and the refusal to guess

Candidates are unclaimed panes whose cwd realpath-equals the team directory.
Auto-bind ONLY when all three hold:

1. the caller's own pane is identified and excluded (§12.6);
2. exactly ONE candidate pane remains;
3. exactly ONE member is awaiting repair.

Result: `status: "updated"`, `from.transport_id: null`, `match_by: "cwd"`.

Otherwise the outcome depends on how many candidates survived, and the two cases
are NOT the same:

- **Zero candidates** → `status: "not_found"`. Nothing is ambiguous about a
  member with no candidate pane; it is simply not running, which is what
  `not_found` already means on the pass-1 path. Emit no `candidates` key and no
  `--bind` suggestion — there is nothing to bind to, and suggesting otherwise
  sends the reader looking for a pane that does not exist.

  Do NOT set `transport_stale` on these. That flag (`roster.mjs:377`) means "the
  id we had is now wrong"; a repair-case member never had one.

- **Two or more candidates, or exactly one that fails a §12.6 gate** →
  `status: "ambiguous"`, with `candidates: [{pane_id, tab_id, workspace_id, cwd}]`
  and a ready-to-paste `--bind` invocation. This is the genuine "I found panes
  and will not guess between them" case.

`resync` exits 0 in both — these are reports, not failures.

**Explicitly rejected: zipping N unmatched members onto N candidate panes by
order.** It is the obvious shortcut in exactly the peer's 4-and-4 case and it is
wrong. herdr's ordering bears no relation to roster order, so a zip is a coin
flip per member, and a wrong bind is not cosmetic: messages route to the wrong
agent, and `dismiss --close` (`roster.mjs:1295`) closes the wrong pane. **A
failed repair is recoverable; a confidently wrong one is not.** If a later
reviewer is tempted by count-matching, this paragraph is the answer, and §14
test 9 is the regression.

**The explicit bind.** One new flag on `resync`:

    roster.mjs resync --bind '{"waves-architect":"wG:p4","waves-reviewer":"wG:p7"}'

A single JSON-object argument, not a repeatable flag — `--verified` already
establishes JSON-in-one-flag as this CLI's convention, and it sidesteps whether
`parseArgs` (`:81`) accumulates repeats. Add `"bind"` to `RESYNC_FLAGS` so the
unknown-flag guard keeps working, and mirror it into the `roster_resync` MCP
schema (`mcp/server.mjs:259-270`) as `bind: { type: "string" }` through the
existing `pushArg`.

Validate every binding before writing anything, failing on the first problem
rather than partially applying: the member exists in `team.members` (else the
`:1282` phrasing — name plus known names); that member's `route === "peer"`; the
pane exists in live topology; the pane is unclaimed; the pane is not the caller's
own (§12.6). A validated binding claims its pane BEFORE pass 2 runs, so an
explicit instruction always outranks an inferred one. Emit `match_by: "bind"`.

### 12.6 Excluding the caller's own pane

The Orchestrator's own session sits at the team cwd and, absent a signal, is
indistinguishable from a peer. Binding a member to it would route that member's
messages into the Orchestrator's own session and let `dismiss --close` close it.
That must be structurally impossible.

E3 resolves this: read `process.env.HERDR_PANE_ID`, which `roster.mjs:647-648`
and `:1032-1033` already do for the spawn and layout paths. Exclude that pane id
from every candidate set in passes 2 and 3, and reject it in `--bind` validation.

Do NOT use `focused_pane_id` from `herdr pane layout` as a substitute. Focus is
not identity — they diverge the moment the user clicks another pane — and the
failure it enables is closing the Orchestrator's pane.

If `HERDR_PANE_ID` is unset (non-herdr transport, or a session started outside
herdr), §12.5's auto-bind is DISABLED and every pass-3 member reports
`ambiguous`. Pass 2 still runs: its role+cwd+liveness conjunction is strong
enough to stand without the exclusion, and it can only ever match a pane a peer
itself reported. `--bind` also still works, because a human choosing a pane
deliberately is a different risk from the tool inferring one.

## 13. NEEDS-EVIDENCE

None outstanding. E1, E2, and E3 are resolved and their answers are recorded in
§8, §12.1, and §12.2.

## 14. Verification for §12

7.  Pass ordering: members A (name-matchable) and B (`transport_id: null`, not
    name-matchable) with two panes at the team cwd, one carrying A's name. B must
    not claim A's pane regardless of member order in `team.json` — assert with A
    listed second.
8.  Pass 2 exact bind: a peers.jsonl `up` record with a live pid, matching role
    and cwd, and a `pane_id` present in topology → `status: "updated"`,
    `match_by: "peers_jsonl"`, `from.transport_id === null`.
9.  **Anti-zip regression.** Two members awaiting repair, two candidate panes, no
    usable peers.jsonl records → both `status: "ambiguous"`, both
    `transport_id` still `null` on disk, exit 0. This is the test that fails if
    someone later "optimises" §12.5 away.
10. Pass 2 rejects a stale record: `up` record whose `pid` is dead → not used,
    even though role and cwd match.
11. Pass 2 rejects a recycled pane: `up` record whose `pane_id` is absent from
    live topology → not used; member falls through to pass 3.
12. Two members sharing one role, both awaiting repair, two `up` records → NOT
    bound by pass 2; falls through to `ambiguous`.
13. `--bind` naming an unknown member → non-zero exit listing known names.
14. `--bind` naming a pane already claimed by pass 1 → non-zero exit, and
    `team.json` unchanged (assert no partial application).
15. `--bind` where cwd does not match → still binds. Explicit outranks heuristic.
16. Self-pane exclusion: the sole candidate pane IS `HERDR_PANE_ID` → no
    auto-bind, `status: "ambiguous"`.
17. `HERDR_PANE_ID` unset → pass 3 auto-bind never fires; pass 2 still binds.
18. A member with a non-null `transport_id` that fails pass 1 → stays
    `not_found`; no weaker tier re-homes it.
19. `sessionstart.mjs` writes `pane_id`/`tab_id`/`workspace_id` when the env vars
    are set, and `null` for each when unset, without throwing.
20. Status classification, zero vs many — assert the EXACT status string, never
    merely `!= "updated"`:
    - a repair-case member with no candidate pane at the team cwd →
      `status === "not_found"`, no `candidates` key, no `transport_stale`;
    - a repair-case member with two candidate panes → `status === "ambiguous"`
      with `candidates.length === 2`.
    Items 10, 11, and 12 must be tightened the same way: each asserts the exact
    expected status, and its fixture makes the candidate count explicit rather
    than incidental. An assertion of `!= "updated"` is what let a member with
    zero candidates report `ambiguous` unnoticed.

## 15. Confidence and limits

- §12.2 is the load-bearing change and I am confident in it: the write site,
  the reader (`readRoster`), and the liveness idiom (`latestRoster` + `pidAlive`)
  all already exist; this adds three fields to one object literal.
- §12.4's role key is the known weak spot. peers.jsonl records carry `role`, not
  `name` (`sessionstart.mjs:90-97`), so two members sharing a role are
  indistinguishable to pass 2 and correctly fall through. Adding the derived name
  to the up record would close that, but the session does not reliably know its
  own roster-derived name at SessionStart, so I am NOT specifying it here.
- §12.5 and §12.6 are unchanged in substance from the pre-E3 draft; E3 only
  supplied the self-pane signal §12.6 was missing.
- The cwd key name (`cwd` vs `foreground_cwd`) remains unconfirmed; §12.3 reads
  both, which is cheap insurance rather than a dodged decision.
- No Ultra-Advisor escalation needed.
