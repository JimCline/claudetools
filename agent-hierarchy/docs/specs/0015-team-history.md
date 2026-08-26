# 0015 — Team history (recent team configs, reusable)

Status: implemented; amended 2026-08-26 with spec-defects found during
implementation and review (§14). Composes with: 0008 (roster relocate), 0011
(multi-roster per orchestrator), 0013 (MCP server), 0016 (roster MCP coverage).

## 1. Goal

Keep up to 5 recently-created team configurations per project so a user starting a
new team session can pick one and recreate it, instead of walking through
`init` / `add` / `create` setup again.

User decisions already made — do not re-litigate:

1. Cap 5 stored configs per project.
2. Eviction is automatic LRU on `last_used`. No prompt.
3. `active` means a live session/roster is running **right now**; it flips to idle
   the moment that session ends. Derived from real liveness, never stored, never
   a time-window guess.
4. Scope is per-project — same `hierarchyDir(cwd)` the roster already uses.
5. Dedupe by config fingerprint, not by id (confirmed with the user; see §3).

## 2. Why a sibling file and not the existing team files

Rejected: "stop deleting `teams/<T>.json` on disband; mark it `disbanded` and let
the team dir *be* the history."

- `clearTeam()` unlinking the file is what makes a team gone. Making `readTeam()`
  return a tombstone changes what every consumer sees — `roster()`,
  `buildStateBlock()`, and three `pretooluse-*` gates. 0011 §9.6 already deferred a
  smaller change to a fail-open gate as unsafe; this is a bigger one.
- The default team (`team.json`) has no name, so it cannot be archived under a key
  in `teams/`.
- Live team files are transient by design and owned by a single writer (0008 §3).
  History is neither.

So: one new file, reusing the existing helpers (`hierarchyDir`, tmp+`renameSync`
atomic write, `newId`, `localIso`, `pidAlive`, `ageSecOf`). No new format concepts.

Rejected: JSONL. `peers.jsonl` is append-only because it is an event stream.
History is a bounded set with read-modify-write and eviction — a 5-element doc
rewritten atomically is smaller than append + compaction.

## 3. Storage

Path: `<hierarchyDir(cwd)>/team-history.json`

Gitignored already — `ensureHierarchyDir()` (lib-hier.mjs:45–51) writes the
`.gitignore` covering the whole dir. Nothing to add.

Confirmed by evidence: no existing test asserts an exhaustive file listing of the
hierarchy dir, so adding a sibling file breaks nothing.

```json
{
  "version": 1,
  "teams": [
    {
      "id": "20260826-141233-a91c",
      "fingerprint": "9f2c1b7e",
      "alias": "backend",
      "label": "backend (4 roles)",
      "created_at": "2026-08-26T14:12:33-07:00",
      "last_used": "2026-08-26T18:44:02-07:00",
      "last_team_id": "20260826-184402-77bd",
      "roster_level": "repo",
      "transport": "herdr",
      "members": [
        { "role": "architect", "model": "opus", "effort": "high", "route": "peer" }
      ]
    }
  ]
}
```

`roster_level` is one of `ROSTER_LEVELS` — `global` / `repo` / `repo-user`. The
member object above omits `auto_mode` because it has no value; §3.1 drops
null/undefined keys, so absent is the correct representation, not `null`.

Field rules:

- `id` — `newId()` at first store. Stable identity for `--from <id>`.
- `fingerprint` — short stable hash (first 8 hex of sha256) over the canonical JSON
  of `{roster_level, transport, members}` **after normalization** (§3.1). The
  dedupe key, not `alias`.
- `alias` — team name (`--team <T>`), or `null` for the default team. Label only;
  never the identity key. Two different configs both created as the default team
  therefore get two history rows, which is the point — a project that only ever
  uses the default team still gets real history. Conversely the *same* roster
  created under two different team names dedupes to one row, because `name` is not
  part of the config (§3.1).
- `label` — display string. `alias ?? "default"` + ` (<N> roles)`. Regenerated on
  every upsert.
- `created_at` — first time this fingerprint was stored. Never updated.
- `last_used` — set on every store/reuse. LRU key.
- `last_team_id` — `team_id` of the most recent live team created from this entry.
  Used by §5 to correlate with a live team file.
- `roster_level`, `transport`, `members` — the config, sufficient to recreate the
  team without re-running `init`/`add`.

No `active` field. See §5.

### 3.1 Member normalization

A stored member keeps **at most these five config fields** and nothing else:

```
role, model, effort, route, auto_mode
```

Everything else is stripped:

| Key | Why stripped |
|---|---|
| `name` | Derived: `peerName(prefix, role)` = `<prefix>-<role>` (0011). The prefix is team-scoped, so a stored name is wrong the moment the entry is replayed under a different `--team`. Recompute, never store. |
| `ref` | ListAgents handle for a specific live session. |
| `transport_id` | Pane/session id. Dead on replay. |
| `checked_in` | Per-spawn check-in result. |
| `launch_status` | Transient launch outcome (`ready`/`dispatched`/`failed`). |
| `launch_result` | Transient launch payload. |
| `retried` | Transient retry marker. |
| `error` | Failure-only launch error. |
| `session_id`, `pid` | Runtime identity. |
| `tab_id`, `workspace_id`, `transport_stale` | 0008 relocation runtime state. |

Dropping `name` also makes `fingerprint` prefix-independent, which is what makes
the same roster under two team names collapse to one history row.

**Key casing (see §14.1).** An earlier revision asserted that the member objects
reaching `create --commit` already use snake_case `auto_mode`, so no rename was
needed on the store side. **That premise was wrong.** The `--verified` array is
built from `createSpawn`'s `outputMembers`/`spawnShape`, which carry camelCase
**`autoMode`** at that point.

Resolution, as implemented and endorsed here: `normalizeMembers()` **accepts either
casing on read** (`autoMode` or `auto_mode`, preferring whichever is present) and
**always writes `auto_mode` to disk**. Tolerating both on the read side is the right
call — the input shape is not this feature's to control, and a strict reader would
break the moment an upstream refactor flipped the casing again.

Normalization for hashing: keep only the five fields, drop keys whose value is
`undefined` or `null`, sort members by `role`, sort keys within each member, then
hash the canonical JSON. Because the store side always emits `auto_mode`, the
fingerprint is unaffected by the input casing — a config committed via either shape
hashes identically. **This is load-bearing for dedupe** and must have a test.

**If the Implementor finds a member key not listed above**, stop and report rather
than guessing which column it belongs in. A runtime key stored in history gets
replayed into a new team and points at something dead.

## 4. Write points

Exactly one place writes history: **`create --commit`, after `writeTeam()`
succeeds** (roster.mjs:914–938). Sequence:

1. `writeTeam(...)` succeeds (unchanged).
2. Normalize the committed members (§3.1), compute `fingerprint`.
3. Read `team-history.json` (missing/corrupt → treat as `{version:1, teams:[]}`).
4. Upsert: if an entry with this `fingerprint` exists, set `last_used`,
   `last_team_id`, `alias`, `label`. Else push a new entry with a fresh `id` and
   `created_at = last_used = localIso()`.
5. Evict per §6.
6. Sort `teams` by `last_used` descending.
7. Atomic write: `writeFileSync(path + ".tmp")` then `renameSync` — the same
   pattern as `writeTeam` (lib-roster.mjs:120–126). Factor the tmp+rename into a
   shared helper in lib-roster.mjs and have `writeTeam` use it too; do not write a
   second copy of it.

A history-write failure must **not** fail `create`. The team is already committed
and running; a missing history row is cosmetic. Catch, emit a `history` key in the
command's JSON output (`{"history": {"ok": false, "why": "..."}}`), exit 0.

`disband` writes nothing. `sweepStaleTeam` writes nothing. Both change liveness,
and liveness is derived (§5) — there is no stored bit to update, which is exactly
why §5 is derived.

## 5. Deriving active/idle

An entry is **active** iff a live team file exists for it. One predicate, one
implementation:

```js
// lib-roster.mjs
export function teamIsLive(t) {
  if (!t) return false;
  const pid = t.orchestrator && t.orchestrator.pid;
  return pidAlive(pid) && ageSecOf(t.created) <= TEAM_STALE_AGE_SEC;
}
```

This is the exact inverse of the staleness test in `sweepStaleTeam`
(sessionstart.mjs:74–82). **`sweepStaleTeam` must be refactored to call
`teamIsLive`** — one implementation per behaviour. `TEAM_STALE_AGE_SEC` moves to
lib-roster.mjs next to it; sessionstart.mjs imports it.

For a history entry `e`, active iff `readTeam(dir, e.alias)` exists, `teamIsLive`
is true for it, and its `team_id` equals `e.last_team_id`.

The `team_id` equality matters: an alias can be reused by a *different* config, and
without it a live `backend` team would mark a stale `backend` history row active.

Cost: at most 5 `readTeam` + `pidAlive` calls per listing. No caching.

Consequence, and it is the desired one: the moment the orchestrator process dies,
`pidAlive` goes false and the next listing shows idle. Nothing has to run at
session end.

## 6. LRU eviction

Trigger: step 5 of §4 only — the single history write. Nowhere else.

```
if (teams.length <= 5) return
candidates = teams.filter(e => !isActive(e) && e.id !== justUpserted.id)
if (candidates.length === 0) return      // keep >5 rather than forget a live team
victim = min(candidates) by (last_used, then created_at, then id)   // all ascending
remove victim; repeat while teams.length > 5 && candidates remain
```

**The `e.id !== justUpserted.id` clause is required (see §14.2).** Without it, a
write that inserts a non-live entry which is also the *only* non-active candidate
evicts the entry it just created, on the same write. That happens whenever the
committing orchestrator's recorded pid is not alive at write time — routinely in
tests, and reachable in production. An entry that survives zero writes is never
useful, so exclude the just-upserted entry unconditionally, whatever its liveness.

Tie-breaking among the remaining candidates: `last_used` ascending, then
`created_at` ascending, then `id` lexicographically ascending. `id` is
timestamp-prefixed (`newId()`, lib-hier.mjs:92–97), so the third key is total and
deterministic — no coin flip.

Never evicting a live team is a correctness rule, not a nicety: forgetting the
config of a team that is currently running strands the user. Exceeding the cap is
temporary — the next write after any of them idles trims back down. Emit a note in
the command output when the cap is exceeded, so it is not silent.

With the self-exclusion clause, the cap is exceeded whenever the five pre-existing
entries are all active, **or** when they are all active except that the new entry
itself is the only idle one. Both reach 6; §12 tests both.

## 7. Reuse flow

### 7.1 `roster.mjs history [--cwd <path>]`

Output is JSON, always. **There is no `--json` flag and no human-readable mode** —
`out()` is JSON-always across every `roster.mjs` verb including `teams`, and adding
a second output mode here would make this the only verb with one (§14.3).

```json
{ "teams": [ { "id": "...", "label": "...", "alias": "backend", "active": true,
               "last_used": "...", "created_at": "...", "roles": ["architect","implementor"],
               "member_count": 4, "roster_level": "repo", "transport": "herdr" } ] }
```

Entries are ordered most-recent-first. Does **not** dump full member objects — 
`roles` and `member_count` are the summary; a consumer wanting the full config reads
the file. Keep the listing narrow.

### 7.2 `roster.mjs create --from <id|alias>`

The plan shape and the committed shape are **not** structurally identical:

```
resolveMembersPlan returns:  role, name, model, effort, route, autoMode, spawn
committed member shape:      role, name, ref, route, model, effort, autoMode,
                             transport_id, checked_in  (+ launch-merge keys)
```

So `--from` needs an explicit mapping step. It is small, because §3.1 stores only
config — history members supply the config and **everything else is derived by the
existing plan code exactly as it is today**:

| Plan field | Source under `--from` |
|---|---|
| `role` | stored `role` |
| `model` | stored `model` |
| `effort` | stored `effort` |
| `route` | stored `route` |
| `autoMode` | stored `auto_mode` — **rename, snake→camel** |
| `name` | **derived**, not stored: `peerName(prefix, role)` for the *target* team's prefix |
| `spawn` | **derived**, not stored: produced by the existing transport-detection step at plan time |

`--from` therefore replaces only the "read the roster config levels" step of
`resolveMembersPlan`. Name derivation, transport detection, and `spawn`-shape
construction run unchanged. Implement as `planMembersFromHistory(entry, ctx)`
returning the same shape `resolveMembersPlan` returns, and branch to it from the
`create` path when `--from` is present.

The reverse direction (committed → history, §4 step 2) is §3.1's strip plus its
casing normalization: read `autoMode` **or** `auto_mode`, write `auto_mode`.

Full command:

```
roster.mjs create --from <id|alias> [--team <T>] [--plan|--commit] [--spawn]
```

`--from` resolves against `id` first, then `alias` (exact match; if two entries
share an alias, prefer the most recent `last_used` — do not prompt, this is a CLI).
Unresolvable → `fail()` naming the value and listing available ids.

**Flag interaction (corrected — see §14.4).** `--from` is mutually exclusive with
flags that supply members *at plan time*. It is **not** exclusive with
`--commit`/`--verified`: the four-step create sequence requires `--verified` at the
commit step, so forbidding the combination would make `--from --commit`
unreachable. When both are present, members come from `--verified` — that is the
verified, checked-in reality — and the history entry named by `--from` is still
**eagerly validated**, so a stored config that no longer validates fails the commit
rather than being ignored. That eager validation is what makes §12's
"`--from --commit` on an invalid stored entry fails" testable at all.

Everything downstream is the existing path, unchanged:

- `validateRosterBlock` / `validateMember` still run. A stored config referencing a
  model, route, or role that is no longer valid must `fail()` with the exact `why`
  — never silently repair. This is the main failure mode for old entries.
- The 0011 §5.3.5 collision check still runs.
- **`requireAllowGlobal` still applies to `--spawn`.** `--from` changes where the
  member plan comes from; it must not change which guards run. See §11.
- `--team <T>` selects the target file. **If omitted, the target is the entry's own
  `alias`** (or the default team when `alias` is null) — a reused team should land
  where it lived, not silently on the default team. An explicit `--team` wins, and
  the resulting history upsert records the new alias against the same fingerprint —
  one row, two aliases over time.
- `--commit` and `--spawn` otherwise behave exactly as today (`createSpawn`,
  roster.mjs:620–646). No skip-straight-to-spawn shortcut: spawning requires a
  committed team file, and `--commit` is what mints the fresh `team_id`,
  orchestrator pid, and history upsert.

`roster.mjs create` must not prompt (0011 amendment c). Selection UI lives in the
skill.

### 7.3 Skill surface

`ah:agent-roster` gains a "reuse a recent team" path: call `roster.mjs history`,
present entries with `AskUserQuestion` (label + active/idle + roles), then run
`create --from <id> --commit --spawn`. Idle entries are the useful ones; selecting
an active entry is allowed (it creates a second team under a different `--team`)
but the skill should say so.

## 8. Concurrency

The single-writer invariant of 0008 §3 does **not** extend to history: two
orchestrators in the same project can both run `create --commit`.

Decision: accept the lost update. Read-modify-write with tmp+rename means a
simultaneous pair can drop one row. Consequences are bounded — one forgotten
history entry, no corruption (rename is atomic, so a reader sees old or new, never
half). 0008 §2.3 accepted the same trade for `team.json`; introducing a lock here
and not there would be inconsistent for a strictly less important file.

Mitigation, required: do the read at step 3 and the write at step 7 with nothing
slow in between — no herdr queries, no spawns.

Mark it in the code:

```js
// ponytail: last-writer-wins on concurrent create in one project; a lost history
// row is cosmetic. Upgrade to an O_EXCL lockfile if history rows start going missing.
```

Corrupt/partial file: parse failure is treated as empty history, and the next write
replaces it. Do not attempt repair, do not crash `create`.

## 9. MCP surface

Add one tool: `roster_history`, wrapping `roster.mjs history --cwd <path>`, mapped
through the existing `mapExecResult` (mcp/server.mjs:132–144). Same shape as
`roster_teams` (mcp/server.mjs:113–122) — copy that tool's definition and change
the subcommand. No `--json` flag to pass (§7.1).

Do not overload `roster_show` or `roster_teams`: `roster_show` returns a resolved
roster config, `roster_teams` returns live team files. History is a third thing
with a third shape, and widening either return type breaks existing callers.

Do **not** expose recreation over MCP. `create --commit --spawn` launches processes
and moves panes; that stays on the CLI/skill path where the existing confirm gates
(0009) apply.

If 0016 lands first, register `roster_history` in its refactored tool shape (0016 §9).

## 10. Files to change

- `hooks/lib-roster.mjs` — `teamIsLive()`, `TEAM_STALE_AGE_SEC`, shared atomic-write
  helper (and route `writeTeam` through it), `historyPath(dir)`, `readHistory(dir)`,
  `writeHistory(dir, h)`, `upsertHistory(dir, entry)` incl. eviction,
  `normalizeMembers()`, `fingerprint()`.
- `hooks/roster.mjs` — history upsert after `writeTeam` in the `--commit` handler
  (914–938); `history` subcommand; `--from` on `create`;
  `planMembersFromHistory(entry, ctx)` per §7.2; `--from` validation.
- `hooks/sessionstart.mjs` — `sweepStaleTeam` calls `teamIsLive`; import the
  constant instead of defining it (currently line 71). **Watch the import
  direction**: sessionstart imports from lib-roster, never the reverse — see §13.
- `mcp/server.mjs` — `roster_history` tool.
- `skills/agent-roster/SKILL.md` — reuse path.
- `tests/test-roster.sh` — new cases, §12.
- `plugin.json` **and** root `marketplace.json` — version bump. Both. This has been
  a defect in prior specs (0011 §14).

## 11. Must not change

- `readTeam` / `writeTeam` / `clearTeam` semantics and their return shapes.
- `team.json` / `teams/<T>.json` schema. History is additive and lives elsewhere.
- Behaviour of any `pretooluse-*` gate. If a change here would touch a gate, stop
  and report — it is out of scope.
- **Which guards run on the `create` path.** `--from` substitutes the source of the
  member plan and nothing else. Every guard that fires on a normal
  `create --spawn` / `create --commit` must fire identically on the `--from`
  variant — specifically `requireAllowGlobal` (roster.mjs:567, called at 624) and
  the 0011 §5.3.5 collision check. A new entry point that bypasses an existing
  confirm gate is a security regression, not a feature of the shortcut.
- 0008 §3 single-writer for team files; 0011 §10 baseline invariance — with no
  history file present and no `--from` used, every existing command must behave
  byte-identically to today.
- `sweepStaleTeam`'s observable behaviour. The refactor to `teamIsLive` must be
  pure extraction; if the predicates are not exactly equivalent, keep the old one
  and report the difference rather than "fixing" it here.

## 12. Verification

- `create --commit` twice with different rosters → 2 entries, distinct
  fingerprints, newest first.
- `create --commit` twice with the *same* roster → 1 entry, `created_at` unchanged,
  `last_used` advanced.
- Same roster committed under `--team a` then `--team b` → **1 entry**
  (fingerprint excludes `name`/alias), `alias` now `b`.
- Stored members contain only the §3.1 keys, and keys with no value are absent
  rather than `null`. Assert specifically that `launch_status`, `launch_result`,
  `retried`, `error`, `ref`, `transport_id`, `checked_in`, and `name` are **absent**.
- **Casing (§3.1, §14.1):** a member arriving as `autoMode` and the same member
  arriving as `auto_mode` both store `auto_mode` on disk **and produce the same
  fingerprint** — i.e. they dedupe to one entry, not two. The fingerprint half is
  the one that matters; assert it explicitly.
- **Self-eviction (§6, §14.2):** 5 active entries + a commit whose new entry is
  *not* live (fake/dead orchestrator pid) → **6 entries**, and the new entry is
  present. Must fail against the pre-amendment pseudocode.
- 6 distinct configs, none active → 5 entries; oldest `last_used` gone, and the
  just-created entry is never the one evicted.
- 6 configs where all 6 are live → 6 entries retained, cap-exceeded note emitted.
- `history` on a project with a live team → `active: true`; kill the orchestrator
  pid → next `history` shows `active: false`, with no other command run between.
- `history` emits JSON with no flag passed, and rejects `--json` as an unknown flag
  (or ignores it consistently with how `roster.mjs` treats unknown flags elsewhere —
  match existing behaviour, do not special-case).
- Alias reuse: create `backend` config A, disband, create `backend` config B →
  2 entries; only B active while B runs.
- `create --from <id> --plan` → plan members' `role`/`model`/`effort`/`route` equal
  the stored values, `autoMode` equals stored `auto_mode` (**camelCase key present,
  `auto_mode` key absent**), and `name`/`spawn` are freshly derived — for a `--team`
  different from the entry's alias, `name` must reflect the *new* prefix.
- `create --from <id>` with **no** `--team` targets the entry's own alias, not the
  default team.
- `create --from <id> --commit --verified '<json>'` succeeds, members come from
  `--verified`, and the history entry is still validated (§7.2).
- `create --from <id> --commit` on an entry whose model no longer validates →
  non-zero exit, `why` names the invalid field, no team file written.
- **`create --from <id> --spawn` without `--allow-global` is refused**, same failure
  shape as a non-`--from` `create --spawn`. This is the §11 guard-parity assertion.
- `create --from bogus` → non-zero exit listing available ids.
- Corrupt `team-history.json` → `create --commit` still exits 0 and rewrites it.
- Baseline: full existing `tests/test-roster.sh` green with no history file present.

## 13. Sequencing with 0016

Independent in substance. Both touch `mcp/server.mjs` and
`skills/agent-roster/SKILL.md`, and both touch `hooks/roster.mjs` in unrelated
places (0015: the `--commit` handler and a new `history` verb; 0016: the `move` case
and a new `disband --close` mode).

**Do not implement them concurrently.** This spec moves `teamIsLive` and
`TEAM_STALE_AGE_SEC` out of `sessionstart.mjs` into `lib-roster.mjs`, which makes a
circular import between those two modules reachable if the split is done carelessly
while another change is in flight. Land one, run the suite, then start the other.

## 14. Amendment log

### 14.1 `auto_mode` casing (spec-defect, found in implementation)

§3.1/§7.2 asserted the committed member shape already used snake_case `auto_mode`
and concluded no rename was needed on the store side. Wrong: the `--verified` array
is built from `createSpawn`'s `outputMembers`/`spawnShape`, which use camelCase
`autoMode`.

Resolved by making `normalizeMembers()` accept either casing and always write
`auto_mode`. The plan-side rename direction (`auto_mode` → `autoMode`) in §7.2's
table was already correct and is unchanged. Endorsed — a tolerant reader is right
here, since the input shape belongs to `createSpawn`, not to this feature. Added the
fingerprint-stability assertion to §12, because tolerant reading is only correct if
both input casings hash identically.

### 14.2 Self-eviction on insert (spec-defect, found in implementation)

§6's pseudocode, applied literally, evicted the just-inserted entry on the same
write whenever that entry was non-live and the sole non-active candidate — the
normal case in tests, reachable in production whenever the committing orchestrator's
recorded pid is not alive.

§12's prose described the intent correctly; the pseudocode failed to implement it.
**The pseudocode was the defect, not the prose.** Fixed by excluding the
just-upserted entry from the candidate set unconditionally.

### 14.3 Four wording defects (found in review; implementation was correct)

All four were spec text describing something the implementation correctly did not
do. Doc-only fixes:

1. **§7.1 invented a `--json` flag and a human-readable mode.** No `roster.mjs` verb
   has one — `out()` is JSON-always everywhere, including `teams`, which §7.1 cited
   as the style to match. Dropped the flag and the human-output paragraph. This
   rippled: §9's MCP wrapper and §7.3's skill invocation both said `history --json`
   and are corrected too.
2. **§3's example used `"roster_level": "project"`** — not a member of
   `ROSTER_LEVELS` (`global` / `repo` / `repo-user`). Changed to `repo`.
3. **§3's example carried `"auto_mode": null`**, contradicting §3.1's own rule that
   null/undefined keys are dropped. Removed the key from the example and stated the
   absent-not-null rule explicitly next to it.
4. **§7.2's exclusivity clause forbade `--from` with any member-supplying flag**,
   which would have made `--from --commit` unreachable, since the commit step
   requires `--verified`. Reworded to exempt `--commit`/`--verified`: members come
   from `--verified`, and the `--from` entry is eagerly validated anyway. The
   implementor's resolution was correct and is now what the spec says.

### 14.4 Guard parity for `--from` (spec omission)

Review found `create --from --spawn` skipping the global-roster confirm gate. The
spec said `--spawn` "behaves exactly as today" but never stated guard parity as an
invariant, which left it as an inference rather than a requirement.

Now explicit in §11 and asserted in §12: `--from` substitutes the source of the
member plan and nothing else; every guard that fires on a normal `create` must fire
identically on the `--from` variant. Also made §7.2's `--team`-defaults-to-alias
behaviour a positive statement rather than a parenthetical, since review found it
unimplemented. Both fixes are the implementor's; the spec now says plainly what the
code must do.
