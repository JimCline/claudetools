# Spec 0008 — `resync` heals team.json's location record; `move` is a thin wrapper over it

Status: implemented; reviewed PASS WITH NITS. Three NEEDS-EVIDENCE items remain in §9.

Precedent: 0001 (roster), 0004 (layout), 0005 (create --spawn), 0006 (disband).

**Amended 2026-08-23 (a)** — user decision on the old §11 open item: `disband` now
resyncs automatically rather than resync staying manual-only. See §5.6, §7.4, §11.

**Amended 2026-08-23 (b)** — post-review follow-up. Three spec-text corrections where
the spec was narrower or older than good practice, and one adjacent docs defect
recorded. See §5.1 (drop `--level`), §5.4 steps 7–8, §7.5 (the irreversibility rule),
§8.1 (what still needs implementing), and §12. **§5.4 step 8 and §5.1's flag list
require small implementation changes; §5.4 step 7 does not — it ratifies what the code
already does.**

---

## 1. Goal

A team member's recorded terminal location in `team.json` stays correct after that
member's pane is relocated — by an orchestrator-issued move, by the user dragging the
pane in the Herdr UI, or by the agent itself.

Two new `roster.mjs` verbs:

- **`resync`** — the load-bearing one. Re-derives every peer member's location from
  herdr's own live topology and rewrites `team.json`. Works regardless of who moved
  what, or whether roster.mjs ever knew a move happened.
- **`move <name> …`** — executes a `herdr pane move`, then calls the same resync path.
  A convenience verb; it adds no new bookkeeping mechanism.

And one behaviour change to an existing verb:

- **`disband` (bare / `--plan`) resyncs first**, in memory, so the emitted close plan
  targets the pane each member actually occupies at disband time rather than the one it
  was spawned into (§5.6).

Otherwise additive. No change to `create --spawn`, and no change to `disband --commit`
or `disband --keep-sessions`.

---

## 2. The design decision, and why the alternative was rejected

The brief asked whether the agent should **self-report** its new pane/tab/workspace ids
after a move, or whether a general **resync** primitive is the better shape. Resync wins,
and self-report is rejected outright — not deferred.

**Self-report is rejected because:**

1. **The agent's own environment lies.** Verified empirically: after
   `herdr pane move w2:pD --new-tab`, the pane's injected `HERDR_TAB_ID` still read
   `w2:t1` while the true tab was `w2:t3`. Env vars are stamped at launch and never
   refreshed. An agent asked "where are you?" would have to run
   `herdr pane current --current` anyway — i.e. ask herdr, which the orchestrator can
   do directly and more cheaply.
2. **Reading the reply means scraping a TUI.** `herdr agent read --source
   recent-unwrapped` returns the pane's rendered chrome — verb-pack banner, box-drawing
   status bar — around the agent's text. Any fenced-JSON extraction convention is
   fragile in exactly the situation it is needed (a confused or busy agent).
3. **It multiplies writers to `team.json`.** `writeTeam()`
   (`hooks/lib-roster.mjs:97-103`) is atomic per write (tmp + `renameSync`) but is a
   whole-file read-modify-write. Two members self-reporting concurrently do not corrupt
   the file — they **silently lose one update**, because the second rename clobbers the
   first member's field with a snapshot read before it landed. Fixing that requires a
   lock file, retry, or per-member sharding: real machinery, bought for nothing.
4. **It cannot catch the out-of-band case any better than resync can.** A user dragging
   a pane in the Herdr UI does not notify the agent either. Both designs have to poll.
   Only one of them has to poll *through a language model*.

**Resync wins because herdr already answers the question from outside the pane.**
`herdr agent list`, `herdr pane list --workspace <id>`, and `herdr workspace list` are
documented in `~/.claude/skills/herdr/SKILL.md:81-85` and are runnable by the
orchestrator. The authoritative topology is one shell command away. No agent needs to
be woken, prompted, parsed, or trusted.

**Consequence for `move`:** `move` does *not* need to parse
`.result.move_result.pane.*` out of the move response. It runs the move, then
re-queries. One code path, self-correcting, and correct even if herdr's move response
shape changes.

---

## 3. Who writes `team.json`: the orchestrator, only

**Decision: `team.json` has exactly one writer — whoever runs `roster.mjs`, i.e. the
orchestrator.** Peer agents never write it, and no `update-transport` verb is exposed
for a peer to call.

Tradeoff, stated: peer-writes would let a member heal its own record the moment it
noticed a move, without the orchestrator doing anything. That is genuinely more
autonomous. It is rejected because the lost-update failure in §2.3 is real, silent, and
would need a locking protocol to fix — and because §2.1 means the peer has no better
information than the orchestrator does. Single-writer discipline is preserved for free.

---

## 4. Scope: herdr for v1; tmux explicitly deferred

`detectTransport()` (`hooks/roster.mjs:134-142`) returns `herdr` | `tmux` | `terminal`.

- **herdr** — full implementation, both verbs, plus the §5.6 disband integration.
- **tmux** — NOT implemented in v1. `resync` and `move` exit 0 and emit
  `{"resynced": false, "reason": "transport tmux not supported (spec 0008 §4)"}`
  (and the `move` analogue). It is a clean no-op, not an error, so a mixed-transport
  script does not break. **`disband` under tmux is completely unchanged** — it builds
  its plan from stored ids exactly as today. See NEEDS-EVIDENCE item 3 (§9).
- **terminal** — same no-op shape, `"reason": "transport terminal has no panes"`;
  `disband` unchanged.

---

## 5. Command surface

Both verbs join the existing `roster.mjs <verb>` dispatch and follow the established
flag style.

### 5.1 `resync`

```
roster.mjs resync [--dry-run] [--cwd <path>]
```

- `--dry-run` — compute and emit the plan; write nothing.
- `--cwd` — as every other verb.

**Amended (b) — `--level` is NOT accepted.** The original text said "as every other
verb", which was sloppy generalisation. `resync` and `move` locate `team.json` by
`--cwd` alone; `--level` would be silently ignored, and a flag that parses cleanly while
doing nothing is a trap for the caller who reasonably assumes it took effect.
`DISBAND_FLAGS` — the closest sibling verb, likewise operating on an existing team
rather than resolving roster config — does not accept it either. **Remove `--level`
from `RESYNC_FLAGS` and `MOVE_FLAGS`**; the spec-0006-§6 unknown-flag rejection then
gives the caller a loud error instead of silence. Accepted-and-ignored was the other
option and is rejected: 0006 §5.4 uses that pattern only for `--kill`, a flag that had
to stay parseable for existing 0002-era callers. No such caller exists here.

**Algorithm:**

1. `readTeam(dir)`. If null → `out({ resynced: false, reason: "no active team" })`,
   exit 0.
2. If `team.transport !== "herdr"` → the no-op of §4.
3. Query herdr's live topology **once** (see §5.2 for the exact query and the
   NEEDS-EVIDENCE gate on its field names).
4. For each member:
   - `route !== "peer"` or `transport_id == null` → status `skipped`.
   - Match to a live pane (§5.3). No match → status `not_found`; set
     `transport_stale: true` and **leave `transport_id`, `tab_id`, `workspace_id`
     unchanged** (§7.1).
   - Match found → status `updated` if any of the three ids differ, else `unchanged`.
     Write the three ids from the live values and delete any `transport_stale` flag.
5. Unless `--dry-run`, `writeTeam(dir, team)` — **one** write for the whole pass, never
   one per member.
6. Emit:

```json
{
  "resynced": true, "dry_run": false, "transport": "herdr",
  "members": [
    { "role": "implementor", "name": "impl-a", "status": "updated",
      "from": { "transport_id": "w2:pD", "tab_id": "w2:t1", "workspace_id": "w2" },
      "to":   { "transport_id": "w2:pD", "tab_id": "w2:t3", "workspace_id": "w2" } }
  ],
  "counts": { "updated": 1, "unchanged": 2, "not_found": 0, "skipped": 1 }
}
```

`from`/`to` are present only for `updated`; omit them otherwise.

**Structure the implementation so steps 3–4 are a pure function** —
`resyncMembers(team) → { members, counts, query_ok, query_error }` — returning healed
members **without writing**. `resync` persists its result; `disband` (§5.6) does not.
One implementation of the heal, three callers. Do not fork this logic.

### 5.2 The herdr query — GATED ON NEEDS-EVIDENCE ITEM 1

The needed mapping is **agent name (and/or pane id) → `{pane_id, tab_id, workspace_id}`**
for every live pane.

`~/.claude/skills/herdr/SKILL.md` documents that these commands exist
(`SKILL.md:81-85`) and that "most control commands return JSON" (`SKILL.md:44`), but
**does not document their response field names**. Run, once, and record the actual
shapes before writing any parsing:

```
herdr agent list
herdr workspace list
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

Preferred source, in order:

1. **`herdr agent list`**, if it returns agent name plus pane/tab/workspace ids. One
   command, no fan-out over workspaces. Use it.
2. Otherwise `herdr workspace list` → for each workspace `herdr pane list --workspace
   <id>`, concatenated. Correct but N+1 calls.

Either way it is a single helper (`queryHerdrTopology()`) — one function body, not a
design fork.

**Failure handling differs by caller; see §7.5 for the rule that governs all three.**

### 5.3 Matching a member to a live pane

Match by **agent name first, pane id second**:

1. If the member has a herdr agent name and it appears in the topology → that pane.
   Agent name is the durable handle: `SKILL.md:68` notes a pane moved into another
   workspace "receives a new workspace-qualified pane ID", so `pane_id` is *not* a safe
   key across workspace moves, while `SKILL.md:56` states agent commands accept "either
   a unique live agent name or the pane ID currently hosting that agent."
2. Else, if `member.transport_id` matches a live `pane_id` → that pane. Covers the
   verified same-workspace tab-move case (pane id stable, tab id changed) and any
   member with no resolvable agent name.
3. Else → `not_found`.

Name-first matching is what makes the design immune to NEEDS-EVIDENCE item 2.

**NEEDS-EVIDENCE item 4 (§9):** whether the name stored on a team member is the string
herdr knows the live agent by. `disband` reads `m.name` (`hooks/roster.mjs:670,686`),
yet `hooks/lib-roster.mjs:54` appears to forbid `name` on a stored member. Gates step 1
only; step 2 alone still ships a working v1.

### 5.4 `move`

```
roster.mjs move <name> --tab <tab_id> --split right|down
roster.mjs move <name> --new-tab [--workspace <id>]
roster.mjs move <name> --new-workspace
                       [--dry-run] [--cwd ...]
```

1. Resolve the member. Not in `team.json` → `fail()` naming the member and listing the
   known names.
2. `route !== "peer"` or `transport_id == null` → `fail("member <name> has no pane to
   move")`.
3. Transport not herdr → the §4 no-op.
4. Exactly one of `--tab` / `--new-tab` / `--new-workspace`; zero or more than one →
   `fail()` with the usage line. `--split` is only valid with `--tab`.

   **Correction (spec 0009 §6.6):** `--split` is not merely "only valid with `--tab`" —
   herdr **requires** it whenever `--tab` is given. Verified at runtime; herdr's `--help`
   does not annotate the dependency.
5. `--dry-run` → emit the `herdr pane move …` command string and stop. Write nothing,
   execute nothing.
6. Otherwise execute `herdr pane move <transport_id> …`. Non-zero exit → `fail()` with
   herdr's stderr, **and write nothing** (§7.2 — the pane never went anywhere).
7. **On success, run the full `resyncMembers(team)` over the WHOLE team and persist it.**

   *Amended (b).* The original text said "for this one member", which the
   implementation correctly ignored. Whole-team is ratified as the specified behaviour:
   - It costs nothing extra. §5.2's query returns the entire topology in one call
     regardless; scoping the *application* of that result to one member would mean
     discarding accurate, freshly-observed data about the others.
   - The observable side effect — an unrelated member gaining or losing
     `transport_stale`, or having its ids corrected — is **not a defect to be fenced
     off**. It is the correct current truth, written by the single legitimate writer
     (§3), from a query already performed. Suppressing it would leave `team.json`
     knowingly wrong.
   - It keeps one heal path (§5.1's closing note) instead of adding a
     scope-to-one-member branch that exists only to honour a sentence.

   Ignore the move response body entirely.
8. Emit:

```json
{ "moved": true, "member": { "role": "implementor", "name": "impl-a" },
  "command": "herdr pane move w2:pD --new-tab",
  "resync": { "ok": true, "status": "updated",
              "from": {"transport_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"},
              "to":   {"transport_id":"w2:pD","tab_id":"w2:t3","workspace_id":"w2"} } }
```

   - Resync returns `not_found` for the moved member → `"status": "not_found"`,
     `transport_stale: true`, **exit 0**. The move really happened; hiding that behind a
     non-zero exit is worse than reporting it.
   - **Amended (b) — the topology query itself fails after a successful move → also
     exit 0**, emitting `{"moved": true, "command": "…", "resync": {"ok": false,
     "reason": "<herdr stderr>"}}`. Do **not** `fail()`.

     The original spec routed this to §7.5's `fail()` rule, but that rule was authored
     for the *pre*-move failure of step 6. Once step 6 succeeds the pane has moved: a
     bare non-zero exit with herdr's stderr tells the caller "the move failed" when the
     opposite is true, and leaves them with an unhealed `team.json` and no indication
     that a corrective `resync` is what they need. This is the same asymmetry the
     `not_found` case above already recognised; §7.5 now states the governing rule
     rather than leaving it implicit in two places.

     **Requires an implementation change** — the shipped code `fail()`s here.

### 5.5 `move` executes; that does not contradict spec 0006

Spec 0006 §4 establishes that `roster.mjs` "executes nothing destructive" — `disband`
*emits* close commands and never runs them. `move` runs a herdr command directly. This
is consistent, not a reversal: the 0006 invariant is about **closing** panes and ending
sessions. Spec 0005 §2.1 already names the asymmetry deliberately — **`roster.mjs` may
start a process and may not stop one**. `create --spawn` executes herdr split and launch
commands. `move` relocates a pane; it destroys nothing and loses no work. It sits with
`create`, not with `disband`.

Do not "fix" this by making `move` emit-only. It would defeat the verb.

The §5.6 disband integration does not touch this boundary either: the resync it performs
is a **read-only query**. `disband` still executes no close.

### 5.6 `disband` (bare / `--plan`) resyncs first

**User decision, 2026-08-23.** Disband resyncs automatically, accepting the added herdr
round-trip.

**Applies to exactly one path: bare `disband` and `disband --plan`** — the only path
that emits close commands, i.e. the only one whose correctness depends on the recorded
ids. Explicitly NOT `--commit` (removes `team.json`, never re-reads the member list,
emits no close commands — `hooks/roster.mjs:650-659`) and NOT `--keep-sessions` (closes
nothing, emits nothing actionable — `:663-672`).

**The heal is IN MEMORY. `disband` still writes nothing.** This is what makes the
amendment compatible rather than a second reversal of 0006:

- 0006 §5.1 specifies bare disband as read-only — "write nothing". Preserved
  byte-for-byte.
- 0006 §5.2's guarantees — `team.json` survives a declined confirmation, survives a
  failed close, interrupted teardown is resumable — untouched.
- Persisting would buy nothing: an interrupted teardown that is re-run simply resyncs
  again. The write has no reader. Do not add it.

**Algorithm** — replaces the bare-disband branch:

1. `readTeam(dir)`. If null → `{"disbanded": false, "reason": "no active team"}`,
   exit 0. Unchanged.
2. `team.transport !== "herdr"` → skip to step 5, plan from stored ids, exactly as
   today. tmux and terminal disband unchanged (§4).
3. Call the pure `resyncMembers(team)` — query only, no write.
4. **If the query failed, degrade; never `fail()`.** Plan from the stored ids and report
   the failure. Losing the ability to emit a teardown plan because herdr is unreachable
   would be a strict regression.
5. Build `close` from the healed (or stored, per steps 2/4) records — same per-transport
   construction as today.
6. Emit `{"close": [...]}` **plus a sibling `resync` key**:

```json
{ "close": [ { "role": "implementor", "name": "impl-a", "route": "peer",
               "transport": "herdr", "transport_id": "w2:pD",
               "command": "herdr pane close w2:pD", "resync_status": "updated" } ],
  "resync": { "ok": true, "counts": {"updated":1,"unchanged":2,"not_found":0,"skipped":1} } }
```

On a failed query: `"resync": { "ok": false, "reason": "<herdr stderr>" }`, every
`resync_status` is `"unqueried"`.

**Output-shape note against 0006 §5.1**, which says bare disband's shape is unchanged
from 0002 §8.3: this adds the `resync` sibling key and a per-member `resync_status`.
Both **additive** — every field 0002 §8.3 specifies keeps its name, position, and
meaning, and `tests/test-roster-disband.sh:58-59`'s `grep -q '"close"'` is unaffected.
A deliberate, recorded relaxation, not an oversight.

**A `not_found` member still gets its close command emitted** from its stale stored id,
with `"resync_status": "not_found"`. §7.1 applies with full force: a close aimed at a
dead pane is a harmless no-op; omitting it leaks a pane that may be alive.

**Spec 0003 does not object, and this was checked rather than assumed.**
`docs/specs/0003-roster-create-perf.md` contains **zero** occurrences of "disband". Its
goal (`0003:8-27`) is to make `/agent-roster create` stand up N members in the time of
the slowest rather than the sum. Every latency figure it cites (`0003:53` — `N ×
(split_latency + agent_ready_wait)`; `0003:117`) is on the create path. The protection
§6 invokes when refusing to add a herdr call to the spawn hot path is genuinely
create-only. Disband is once-per-team, human-confirmed, no fan-out.

---

## 6. `team.json` schema change

Per-member, additive, all optional:

| field | type | meaning |
|---|---|---|
| `tab_id` | string \| absent | herdr tab id, as of the last spawn or resync |
| `workspace_id` | string \| absent | herdr workspace id, ditto |
| `transport_stale` | `true` \| absent | last resync could not find this member's pane |

`transport_id` keeps its meaning and type. Nothing renamed, nothing removed. Pre-0008
readers (`launchMember` at `:320-322`, `disband` at `:681-687`) are unaffected — they
read only `transport_id`, which resync keeps accurate.

`transport_stale` is advisory. **Nothing branches on it** — `disband` still emits a
close for a stale member (§5.6). It exists so a human or a future health-check can see
what resync could not find. `disband`'s in-memory resync does not persist it; only
`resync` and `move` do.

**Deliberately not added:** a `transport_checked_at` timestamp. Nothing would read it.

**`create --spawn`:** when transport is herdr, populate `tab_id` and `workspace_id`
alongside `transport_id` from the launch result if it carries them, otherwise leave them
absent — the first `resync` fills them in. Do **not** add a herdr query to the spawn hot
path; spec 0003 exists because that path's latency matters (§5.6 explains why disband is
different).

---

## 7. Edge cases

### 7.1 Member's pane is closed or dead

`not_found`, `transport_stale: true`, three id fields **left as they were**.

Clearing `transport_id` would silently break `disband`, which builds its close command
from it (`:681-687`). A dead pane's close command is a harmless no-op; a *missing* one
means a pane that is actually alive — herdr briefly unreachable, say — never gets
closed. Stale-but-present beats absent.

### 7.2 `move` targets a tab or workspace that does not exist

herdr rejects the move with a non-zero exit. roster.mjs `fail()`s with herdr's stderr
and writes nothing (§5.4 step 6). The record is untouched and still correct, because the
pane never went anywhere.

### 7.3 Two rapid moves of the same member

Each `move` ends with its own fresh topology query, so the second run reads the world
after the first move landed. Last write wins with the true current location. No
sequencing protocol needed — this falls out of re-querying instead of parsing the move
response.

Residual race: a move performed by someone else *between* our move and our query. The
result is still a valid, herdr-sourced location, just possibly one move behind. The next
`resync` corrects it. Acceptable; do not engineer around it.

### 7.4 `disband` racing a `relocate` — largely closed by §5.6

Previously the sharpest edge, mitigated only by convention. §5.6 makes the resync
automatic, so the plan is derived from a topology read microseconds before it is
emitted. A member that moved at any point between spawn and disband is now closed at its
real location.

What remains:

- **A small residual window**: a move landing *between* disband's topology query and
  the orchestrator running the emitted closes. Nothing inside roster.mjs can close this
  — the closes are executed by the skill, by design (0006 §4). Bounded by how long the
  human confirmation takes.
- Both verbs go through `roster.mjs`, invoked serially, so `move` and `disband` cannot
  interleave mid-write.
- A resync landing after `--commit` cleared `team.json` reads null and emits
  `{"resynced": false, "reason": "no active team"}` — correct, unchanged.

`skills/agent-roster/SKILL.md:279-310` must be updated: the old manual "resync first"
advice is now wrong-by-obsolescence; the residual caveat above replaces it.

### 7.5 herdr is unreachable — the irreversibility rule

*Amended (b): this section previously gave a two-item list that read as "resync/move
fail, disband degrades". That framing put `move` on the wrong side of the line whenever
the query failure came **after** the pane had already moved. The governing rule:*

> **`roster.mjs` may `fail()` for a query failure only while it has caused no
> irreversible side effect. Once it has moved a pane — or otherwise changed the world —
> a later failure is REPORTED at exit 0, never converted into a non-zero exit that
> misrepresents the side effect as not having happened.**

Applied:

| caller | when the topology query fails | exit |
|---|---|---|
| `resync` | `fail()` with stderr; `team.json` untouched. Nothing has happened yet. | non-zero |
| `move`, before the pane moves (§5.4 step 6 path) | `fail()`; the pane never went anywhere (§7.2). | non-zero |
| `move`, after the pane moved (§5.4 step 8) | Emit `{"moved": true, "resync": {"ok": false, "reason": …}}`. | **0** |
| `disband` | Degrade to stored ids, emit the plan, `"resync": {"ok": false}` (§5.6 step 4). Disband must never lose the ability to emit a plan. | 0 |

In both exit-0 cases the remedy is the same and should be inferable from the output: run
`roster.mjs resync` once herdr is reachable.

Note that `resync`'s `fail()` must not degrade to "no panes found" — that would mark
every member `not_found`. A failed query and an empty topology must never be confused.

### 7.6 Two members resolve to the same live pane

Impossible in a correct world; possible after a partial spawn failure. Treat as data,
not a crash: assign the pane to the first match, mark the second `not_found`, include
`"warning": "duplicate pane match"` in the output.

### 7.7 A resync finds a member whose pane now hosts a *different* agent

Only reachable if pane ids are recycled and name-matching is unavailable (§5.3 step 2
fallback, gated on NEEDS-EVIDENCE item 4). The stored id would match someone else's
pane, and disband would emit a close for it. **Pre-existing hazard — today's disband has
the same exposure with none of the healing** — but name-first matching eliminates it
wherever names resolve. A further reason to prioritise item 4.

---

## 8. Change list

1. `hooks/roster.mjs` — `resync` and `move` cases in the dispatch switch; usage string
   and header comment block list them.
2. `hooks/roster.mjs` — `dry-run`, `new-tab`, `new-workspace` in `BOOL_FLAGS` so
   `parseArgs` (`:50-68`) does not swallow the following token as a value.
3. `hooks/roster.mjs` — per-verb allowed-flag validation (0006 §6) covers the new verbs.
   `DISBAND_FLAGS` **unchanged** — §5.6 adds no disband flag.
4. `hooks/roster.mjs` — `queryHerdrTopology()`, `matchMemberToPane()`, pure
   `resyncMembers(team)` (§5.1–§5.3). `resyncMembers` must not write.
5. `hooks/roster.mjs` — bare-disband branch calls `resyncMembers()`, builds `close` from
   healed records, adds the `resync` sibling key and per-member `resync_status` (§5.6).
   Still no `writeTeam`, still no close executed. `--commit` and `--keep-sessions`
   branches **untouched**.
6. `hooks/roster.mjs` — populate `tab_id` / `workspace_id` at spawn where already
   available (§6). No new herdr call on that path.
7. `hooks/lib-roster.mjs` — permit the three new member fields if validation would
   reject them (`:54` region).
8. `skills/agent-roster/SKILL.md` — document both verbs; rewrite the disband flow
   (`:279-310`) per §7.4, replacing manual resync-first advice with the automatic
   behaviour plus the residual-window caveat. Plus the §12 sentence.
9. `docs/specs/0006-disband-kill-by-default.md` — forward-reference note at §5.1
   recording that 0008 §5.6 relaxes "output shape unchanged" additively while preserving
   "writes nothing". Annotate; do not rewrite 0006's decision.
10. `tests/test-roster-resync.sh` — new, modelled on `tests/test-roster-disband.sh`'s
    herdr-absent stubbing pattern.
11. `tests/test-roster-disband.sh` — extend with the §10 disband-resync cases. Every
    existing assertion must still pass unmodified.

### 8.1 Still outstanding after review (amendment (b))

Items 1–11 above are implemented and reviewed. These two are **new work** created by
amendment (b):

- **A.** `move`: post-move topology-query failure must exit 0 with
  `"resync": {"ok": false, "reason": …}` instead of `fail()` (§5.4 step 8, §7.5).
- **B.** Drop `--level` from `RESYNC_FLAGS` and `MOVE_FLAGS` (§5.1).

§5.4 step 7 (whole-team resync) needs **no** change — it ratifies existing behaviour.

**Must not change:** `disband --commit` / `--keep-sessions` behaviour or output; bare
disband's "writes nothing" invariant; `create --spawn` beyond item 6; anything in
`hooks/lib-hier.mjs`, `hooks/msg.mjs`, or `peers.jsonl`. Peer messaging is keyed on
session/pid/role and holds no pane identifier — unaffected by pane moves, and not to be
touched by this work.

---

## 9. NEEDS-EVIDENCE

1. **BLOCKING, and on the disband path — herdr query response shapes.** Run
   `herdr agent list`, `herdr workspace list`, `herdr pane list --workspace <id>`;
   record exact field names and nesting. `SKILL.md` documents that the commands exist,
   not what they return. §5.2's parsing cannot be written without this. §5.6 step 4
   makes a *runtime* query failure survivable; a *misparsed* response is not — it would
   silently mark healthy members `not_found` and emit stale close commands under
   `"ok": true`. Verify against real output, not assumed shapes.
2. **Cross-workspace pane id stability.** `SKILL.md:68` says a pane moved into another
   workspace "receives a new workspace-qualified pane ID" — documented, never verified.
   Low priority: §5.3's name-first matching is correct either way; this only confirms
   the pane-id fallback must not be promoted to primary.
3. **tmux equivalent (deferred).** Does a tmux pane keep its `%N` id across `move-pane`
   / `break-pane` into another window? Is `tmux list-panes -a -F '#{pane_id}
   #{window_id} #{session_name}'` a usable topology? If both hold, a tmux resync path
   and a tmux §5.6 are a small follow-up spec. Not v1; tmux disband stays as it is.
   No interaction with the amendments — §5.6 step 2 short-circuits.
4. **Member name ↔ herdr agent name.** Reconcile `:670,686` reading `m.name` against the
   apparent prohibition at `lib-roster.mjs:54`; confirm the stored name is what
   `herdr agent list` reports. Gates §5.3 step 1 only. With it, disband heals a
   cross-workspace-moved member; without it that member returns `not_found` and disband
   emits its stale close (correct fallback, no improvement over today), and §7.7 stays
   open.

---

## 10. Verification

1. `tests/test-roster-resync.sh`:
   - No `team.json` → `{"resynced": false, "reason": "no active team"}`, exit 0.
   - `transport: "tmux"` → the §4 no-op, exit 0, file unchanged.
   - **Core case:** fixture records tab `w2:t1`; stubbed topology reports `w2:t3`.
     Assert `tab_id` becomes `w2:t3`, `transport_id` unchanged, status `updated`.
     **Must be shown to fail against unmodified `roster.mjs`.**
   - Member absent from topology → `not_found`, `transport_stale: true`, three id fields
     byte-identical to before.
   - `--dry-run` → same emitted plan, `team.json` mtime and contents unchanged.
   - Query exits non-zero → roster.mjs exits non-zero, `team.json` unchanged, no member
     marked `not_found`.
   - `move` with two of `--tab` / `--new-tab` / `--new-workspace` → non-zero, usage.
   - `move --dry-run` → emits the command string, executes nothing.
   - **(amendment b)** `--level` on `resync` and on `move` → non-zero exit, unknown-flag
     message. Guards against silent acceptance regressing back in.
   - **(amendment b)** move succeeds, then topology query fails → **exit 0**, output has
     `"moved": true` and `"resync": {"ok": false}`. **Must be shown to fail against the
     current implementation**, which `fail()`s.
   - **(amendment b)** move succeeds → assert an unrelated member's ids are also healed
     in the persisted `team.json` (ratifies §5.4 step 7 whole-team scope).
2. `tests/test-roster-disband.sh`, extended for §5.6:
   - **Core case:** member stored at `w2:pD`, stubbed topology reports `w2:pZ`. Assert
     the emitted `command` is `herdr pane close w2:pZ`. **Must be shown to fail against
     unmodified `roster.mjs`.**
   - Bare disband **still does not write `team.json`** — assert contents byte-identical
     before and after, not merely that the file exists (`:56-57` tests existence only).
   - Query fails → exit 0, plan still emitted from stored ids, `"resync": {"ok": false}`,
     every `resync_status` `"unqueried"`.
   - A `not_found` member still gets a non-null `command` from its stored id.
   - `--commit` and `--keep-sessions` emit **no** `resync` key and perform no topology
     query (stub the herdr binary to fail loudly if invoked; assert it was not).
   - `transport: "tmux"` bare disband → output byte-identical to today's.
   - Every pre-existing assertion passes unmodified.
3. Existing suite green — `test-roster-create-spawn.sh` especially.
4. One live herdr run: spawn two peers, `herdr pane move` one out-of-band, then
   (a) `roster.mjs resync` heals the record with no agent prompted, and (b) bare
   `roster.mjs disband` emits a close targeting the moved pane's current location.

---

## 11. Confidence and escalation

**High confidence** on: rejecting self-report (§2 — the stale-env-var result is measured,
not argued); single-writer (§3); re-querying instead of parsing the move response;
§7.1's stale-but-present decision; §5.6's in-memory heal, which delivers the user's
requirement while preserving 0006's read-only invariant exactly; and all three
amendment-(b) corrections, which move the spec toward what the code and good practice
already indicated.

**Low confidence** on: nothing that blocks implementation. The one genuine unknown is
NEEDS-EVIDENCE item 1, a lookup rather than a judgement call — though it is a lookup on
the teardown path, so treat it as a hard gate.

**Not escalated.** Blast radius is small: two additive verbs, one optional-field schema
extension, one branch of one existing verb gaining a read-only query and two output
keys, and two small post-review corrections.

**No open questions remain for the user.** The old §11 open item (automatic vs manual
resync) was answered 2026-08-23: automatic before `disband`, added round-trip explicitly
accepted, manual `resync`/`move` retained unchanged for every other use.

---

## 12. Adjacent docs defect — `create --spawn` does not persist (recorded, out of scope)

Surfaced during live verification of this spec's work, **not caused by it**, and fixed
here only because it is a one-sentence docs fix in a file §8 item 8 already opens.

`create --spawn` launches panes and returns `members[]`; it does **not** write
`team.json`. Only `create --commit --verified <json> --transport <t> --roster-level <L>`
persists. `SKILL.md:263` says to build the commit payload "directly from `--spawn`'s
`members[]`" but never states that the follow-up commit call is *required*, and
`roster.mjs`'s usage header lists `--spawn` and `--commit` as parallel forms without
saying that spawn alone persists nothing. Consequence observed live: peers running with
no `team.json` record at all — and therefore invisible to `resync`, `move`, and
`disband`, since all three start from `readTeam()`.

**Add to `SKILL.md`'s Create section, immediately before the `--spawn` step:**

> `--spawn` only launches the panes — it writes nothing; the Team does not exist until
> the follow-up `create --commit --verified <json> --transport <t> --roster-level <L>`
> call persists `team.json`, and until then `resync`, `move`, and `disband` cannot see
> the members at all.

**And to `roster.mjs`'s usage header**, on the `create` line:

> `--spawn` launches only; `--commit` persists. Both are required, in that order.

This does not change behaviour and needs no test. A larger question — whether `--spawn`
should persist a provisional record itself so a crash between the two calls does not
orphan live panes — is genuinely out of scope here and belongs in its own spec.
