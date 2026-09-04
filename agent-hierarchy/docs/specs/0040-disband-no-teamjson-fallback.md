# 0040 — disband/dismiss fallback for route:peer rosters with no team.json

Status: implemented (r2 — §1.4a mixed whole-set disband added at user's request); see §4 status block
Author: Architect (claudetools-architect)
Date: 2026-09-04
Origin: live cross-session report (waves repo, 5 route:peer members spawned via
`add`/`spawn-one`, no team.json): every disband/dismiss variant no-ops with
`{"reason":"no active team"}` while the peers are genuinely live. Only manual
per-peer SendMessage exit requests work today.
Files: `agent-hierarchy/hooks/roster.mjs` (disband :1625-1726, dismiss
:1728-1875), `agent-hierarchy/hooks/lib-hier.mjs` (`roster()` :723-791,
`latestRoster`, liveness predicate), `agent-hierarchy/mcp/server.mjs`
(descriptions only), `agent-hierarchy/skills/agent-roster/SKILL.md`,
`agent-hierarchy/tests/test-roster-disband-peers.sh` (new)

**Requirement (settled by the user):** disband must still be able to tear down
live peer agents when no team.json exists.

## 1. Design

### 1.1 Trigger — automatic on `!team`, no new flag

When `readTeam` returns null, the **plan** and **--close** variants of both
`disband` and `dismiss` fall back to the live-peer registry instead of
no-opping. No `--peers`/`--no-team` flag.

Rationale: the plan variant is read-only — an accidental team-less invocation
prints a plan and changes nothing. The destructive path already has three
gates that survive intact in the fallback: a `--plan-token` obtainable only
from a preceding plan call (and hashing exactly the fallback close set), an
explicit `--confirm`, and `requireAllowGlobal` on the resolved config level.
A gating flag would recreate the trigger incident's failure shape: the agent
hits "no active team", and the remedy is a flag it has to be told about.

When `!team` AND the fallback finds **zero closable live peers**, the existing
no-op fires with an extended reason:
`{ disbanded: false, reason: "no active team and no live peers" }` (dismiss:
`dismissed: false`, same reason). A stray invocation in an empty directory
stays a loud no-op.

### 1.2 Enumeration — peers.jsonl correlation, one liveness implementation

Fallback member set = latest record per name from `latestRoster(dir)`
(peers.jsonl), using **exactly the liveness rules `roster()` already
implements** (lib-hier.mjs:733-741): skip `status:"down"`; `"up"` is live iff
`pidAlive(rec.pid)`; `"seen"`/`"briefed"` live iff `ageSec <
ROSTER_FRESH_SEC`. Team scoping mirrors `roster()`'s: honour `--team` /
default-team tagging the same way roster_show does.

**One implementation.** Extract the record→liveness correlation into a shared
lib-hier helper (e.g. `livePeerSlots(dir, team)` returning
`[{name, role, pid, pane_id, live, how}]`) that BOTH `roster()` and the
fallback call, or have the fallback call through `roster()`'s machinery — the
liveness arithmetic (`pidAlive` + `ROSTER_FRESH_SEC` comparison) must appear
once (0035 §11 family; T8 pins structurally). Duplicating the predicate in
roster.mjs is forbidden.

Closable fallback member shape: build the same member objects the team path
uses — `{ role, name, route: "peer", transport_id: rec.pane_id }` — so
`closableMembers`, `closeToken`, and `closeMemberPane` are reused **verbatim**
with zero signature changes. A record with no `pane_id` appears in the plan
with `command: null` and is excluded from the closable set (same as the team
path's non-peer rows).

Transport: records store `pane_id` from `HERDR_PANE_ID` at checkin; the
fallback assumes transport `herdr` for records that have one. See
NEEDS-EVIDENCE 3 for tmux.

No resync in the fallback: `resyncMembers` takes a team; fallback pane ids
are self-reported by the peer's own checkin env and are the current ones.

### 1.3 Mechanism — pane-kill via existing close path; no new message type

Teardown per member is `closeMemberPane(transport, transport_id)` (roster.mjs
:952-962), identical to team `--close`. **No graceful-exit message type**:
`MSG_TYPES` stays `["request","response"]` (lib-hier.mjs:29). A
shutdown-request protocol needs delivery/timeout/refusal semantics that are a
separate spec if ever wanted; today's team members are pane-killed and the
fallback gets parity, not a superset.

Token scope for the fallback: `closeToken("no-team", closable)` — the literal
`"no-team"` stands in for `team_id`. Deterministic across the plan→close
pair; cannot authorise (or be authorised by) any team-scoped token because no
team_id is `"no-team"` and the id set is hashed regardless. Same
topology-changed re-plan error text as the team path.

Guards unchanged and applied identically: `--confirm` required (fail names the
close list), `--plan-token` required and verified, `resolveRoster` →
`requireAllowGlobal` before any close.

Post-close record state: team `--close` writes no `"down"` records today
(sessionend hooks may or may not fire on pane kill); the fallback matches —
`pidAlive` makes dead peers drop out of roster_show liveness either way.
NEEDS-EVIDENCE 2 records what actually happens.

### 1.4a disband — mixed-roster whole-set teardown *(Amended r2: user accepted flag #1 — reverses r1's "disband does NOT get a mixed mode")*

When team.json exists, `disband` (plan) ALSO enumerates **extras**: live peer
records from the §1.2 fallback enumeration (same team-tag scoping) whose names
are NOT in `team.members` (dedupe by name — a record matching a team member's
name is that member, not an extra). Extras are appended to the plan's `close`
array as §1.2-shaped entries, each carrying `source: "peers"` per entry; team
entries are untouched. `close_token` = `closeToken(team.team_id,
closableMembers(team ∪ extras))` — the union.

`--close` then closes the whole union. **Confirmation-before-close is the
existing two-step, not a new gate:**

- the plan call lists every peer that will die, with extras explicitly
  labeled `source:"peers"` so the caller (and the user shown the list per
  roster_disband_close's contract) sees which come from outside team.json;
- the token hashes exactly that union — an extra peer appearing (or dying)
  after the plan invalidates the token and forces a re-plan, so nothing can
  be closed that was never listed;
- `--confirm` absent still fails loudly, and that failure's close list
  includes the labeled extras.

A third gate specific to the mixed case would gate on information the token
already pins; rejected.

Byte-compatibility: with **zero extras**, plan output and token are
byte-identical to today (extras contribute no fields when absent). Close
results: extra rows carry `source:"peers"`; team rows unchanged.

Extras are not resynced (§1.2 — their pane ids are self-reported and current);
team members resync as today. `--commit`/`--keep-sessions` unchanged — they
touch team.json only, and extras have no rows there.

### 1.4b dismiss — per-member fallback, including mixed rosters

`dismiss <name>`: when the name is not found in team.json's members — because
there is no team.json, **or** because the team exists but the name matches a
live peer record only (mixed roster: team members + extra `add`-spawned
peers) — consult the fallback enumeration. Found there → proceed with
plan/`--close` against that one record, same shapes as §1.2/§1.3
(single-member token, per 0020 §3.3's scoping). Not found in either store →
the existing not-found error, extended to say both stores were checked. The
role-vs-name hint (roster.mjs:1747-1750) is preserved when a team exists.

*(r1's paragraph refusing disband a mixed mode is superseded by §1.4a — the
user accepted flag #1 with the confirm-listing requirement §1.4a satisfies.)*

### 1.5 Output — same shape family plus a source discriminator

- Fallback plan: the team plan's shape with `source: "peers"` added and no
  `team_id`: `{ close: [{role, name, route, transport, transport_id, command,
  live, how}], close_token, source: "peers" }`. (`live`/`how` replace the team
  path's `resync_status` — they carry the same freshness information from the
  registry.)
- Fallback close: `{ closed: <all-ok>, source: "peers", results: [{name,
  transport_id, closed, error}] }` — team shape plus `source`.
- Team-path outputs: byte-identical to today (no `source` field added there —
  its absence IS the discriminator for existing callers).
- Every fallback output states it operated without team.json (the `source`
  field is that statement); nothing about the fallback is silent.

### 1.6 --commit and --keep-sessions — unchanged no-ops

Both exist to remove team.json. With no team.json there is nothing to commit
or keep-sessions around: they keep today's `{removed|disbanded: false,
reason: "no active team"}` byte-identically. Same for `dismiss --commit`
(rewrites team.json) — its fallback would be pure config editing with no
team semantics; `--also-config` without `--commit` stays invalid. Flag for
the user: a config-only removal surface for team-less rosters
(`dismiss <name> --commit --also-config` equivalent) is a one-step follow-up
if wanted; not in this spec.

### 1.7 MCP surface — no schema change

`roster_disband`, `roster_disband_close`, `roster_dismiss`,
`roster_dismiss_close` inherit via `execCli` → CLI, untouched handlers. Update
the four descriptions to say they fall back to live peer records when no
team.json exists (plan/close modes), and that disband plan/close include
extra non-team live peers labeled `source:"peers"` (§1.4a). No new tool, no
new input.

## 2. What must not change

- All four variants against an existing team.json **with no extra live
  peers**: byte-identical (existing suites test-roster-disband.sh,
  test-roster-disband-close.sh, test-roster-dismiss.sh,
  test-disband-close-gate.sh stay green — their fixtures have no extras).
  *(r2: qualifier added for §1.4a; with extras present, plan/close outputs
  gain the labeled extra rows by design.)*
- `closeMemberPane`, `closeToken`, `closableMembers` signatures.
- `MSG_TYPES` (no exit/shutdown type).
- disband/dismiss remain separate subcommands (the brief's collapse question:
  ruled out of scope — 0006/0020 semantics stand).
- `--commit` / `--keep-sessions` team-less no-ops (§1.6).
- The token-scoping invariant (0020 §3.3): a whole-set token never authorises
  a single-member close and vice versa — holds for fallback tokens too.

## 3. Docs

`skills/agent-roster/SKILL.md` disband/dismiss sections: one short paragraph —
with no team.json, plan and `--close` operate on live peer records
(peers.jsonl) instead of no-opping; `--commit`/`--keep-sessions` still require
a team.json; output carries `source: "peers"`.

## 4. Tests

`agent-hierarchy/tests/test-roster-disband-peers.sh` (HOME-redirect + scratch
repo + herdr stub pattern per test-roster-add-spawn.sh; fake records use the
test's own live pid for `pidAlive` truth).

| # | Scenario | Assert |
|---|---|---|
| T1 | Live peer records (status up, live pid, pane_id), no team.json; `disband` | Plan with `source:"peers"`, entries with commands, `close_token`. **Expected to FAIL pre-fix** (`{"disbanded":false}`) — the falsifying core |
| T2 | T1 then `disband --close --confirm --plan-token <tok>` | Exit 0; herdr stub log shows one `pane close <id>` per member; `closed:true`, `source:"peers"` |
| T3 | `--close` with a stale/wrong token | fail; stub log empty (nothing closed) |
| T4 | No team.json, no live records | `{disbanded:false, reason:"no active team and no live peers"}` |
| T5 | No team.json: `--commit` and `--keep-sessions` | Byte-identical to today's no-ops |
| T6 | `dismiss <name>` no team.json, name in records | Plan for that one member; `--close` closes exactly it (stub log = 1 call); single-member token verified |
| T7 | Mixed: team.json + extra peer record; `disband` plan lists team rows unchanged + extra row labeled `source:"peers"`; token covers the union; `--close --confirm --plan-token` closes BOTH (stub log shows every pane); `dismiss <extra-name>` still falls back per-member | *(Amended r2 for §1.4a — was "closes team members only")* |
| T7b | Mixed: plan taken, THEN a new extra record appears; `--close` with the old token | fail (token mismatch); stub log empty — nothing unlisted ever closes |
| T7c | Team.json with zero extras | plan + token byte-identical to pre-0040 output (regression guard for §1.4a's compat claim) |
| T8 | Structural | Liveness arithmetic (`pidAlive`/`ROSTER_FRESH_SEC`) appears once, shared by `roster()` and the fallback — grep-level |
| T9 | Record status up but dead pid; record status down | Both excluded from plan's closable set (dead-pid row may appear with `live:false`, no command execution on close) |
| T10 | Team exists, `dismiss <name>` matching neither store | Existing error text + "checked live peer records" extension; role-hint preserved |

MCP: one row in test-mcp-server.sh — `roster_disband` on a team-less
peer-record fixture returns the `source:"peers"` plan (inherits via execCli).

Mutation standard: T1 seen failing against HEAD; control mutant (e.g. fallback
that skips the token check) seen failing T3.

**Status (landed):** `tests/test-roster-disband-peers.sh` 51/51 (T1–T10 plus
T3b confirm-less close, T6b unknown-name error, T9b no-pane_id rows, and an
`--allow-global` pair for the fallback close). MCP row in test-mcp-server.sh
green (50/50). Mutations: unmodified HEAD `roster.mjs` + `lib-hier.mjs` fails
36 of 51 (T1 included — the falsifying core; T4/T5-commit/T10-role-hint style
rows pass on HEAD by construction); the control mutant (`gateClose`'s token
comparison disabled) fails exactly the 10 token-bearing assertions — T3 ×2,
T3b, T6 ×2, T7 ×2, T7b ×2, and T2's "one pane close per member" (the earlier
wrong-token T3 close now goes through, so T2 counts 4). Full regression 55
suites with a no-op `claude` shim (0 invocations): 54 green + one
**spec-driven** change in `test-roster-dismiss.sh` case 12 — it pinned the
literal `"no active team"` reason for a team-less `dismiss` plan, which §1.1
extends to `"no active team and no live peers"`; the assertion was updated to
the §1.1 string. §2's "stay green" claim for that suite is therefore
qualified by §1.1 — flagged for the Reviewer/Architect, reverse if §2 is meant
to win.

Landing notes (not in the draft): (a) fallback dismiss's token scope is the
team's id when a team.json exists (mixed roster) and `"no-team"` otherwise —
0020 §3.3's single-id set keeps whole-set/single tokens disjoint either way;
(b) `dismiss --commit` never consults the registry (§1.1 names plan/--close
only), so a mixed-roster extra under `--commit` gets the existing not-found
error; (c) a team-less `dismiss <name>` whose name is in neither store exits
2 naming the registry's names, while a team-less dismiss with ZERO closable
records is the §1.1 no-op regardless of name; (d) dead-pid/down records are
dropped from the fallback set entirely (T9's "may appear with live:false" is
not exercised — the plan lists only live records, with `command: null` for a
live record lacking a pane_id); (e) `livePeerSlots` attributes a record to a
team by its team.json membership when one exists, else by the record's own
checkin `team` tag (untagged = default team) — roster() would send a tagged
record with no membership to `unattributed`, which for a team-less roster
would make every `--team X` fallback empty; the tag rule is the minimal
departure and is called out in the helper's doc comment; (f) `memberIsLive`
(roster.mjs) already duplicated the liveness predicate pre-0040 and now routes
through the same `recordLiveness`, so T8's "once" holds for all three readers.

## 5. NEEDS-EVIDENCE

1. Why the waves-repo peers have no team.json: does `spawnOneCore`'s team.json
   persist run conditionally (only when one already exists)? Inspection, not
   an experiment. If spawn-one can be made to always persist team.json, that
   is a **separate follow-up spec** (root-cause companion) — this fallback is
   still required for existing rosters and for lost/deleted team.json.
2. Does killing a pane cause sessionend-roster.mjs to write a `"down"` record?
   Observe once during T2 development; either answer is acceptable (parity
   with team `--close`), record which.
3. Do tmux-transport peers ever check in with an addressable pane id? checkin
   (roster.mjs:2159) captures `HERDR_PANE_ID` only — if tmux peers have no
   recorded id, the fallback covers herdr only and tmux records surface as
   `command: null` rows. Confirm and state in the SKILL.md paragraph if so.
4. The herdr test stub handles `pane close` (it was built for spawn calls) —
   extend the stub if not, same call-log pattern.

**Resolved at landing:**

1. `spawnOneCore` persists team.json **unconditionally** (roster.mjs
   `writeTeam(dir, outTeam, teamArg)` right after the launch; it creates the
   team object when none exists). So the waves-repo state is not a conditional
   persist — team.json was removed/lost afterwards or lives under a different
   hierarchy dir (worktree vs main checkout). No root-cause follow-up spec
   indicated by inspection.
2. Not observed: the fake herdr stub closes nothing real, and no live pane was
   killed during development (user's no-kill rule). By inspection
   sessionend-roster.mjs:27 appends `{status:"down"}` only when Claude's
   SessionEnd hook fires, which a pane kill may or may not trigger — same
   uncertainty as team `--close`; parity holds either way, and `pidAlive`
   drops the record from liveness regardless.
3. Confirmed: checkin (and sessionstart) record `pane_id` from
   `HERDR_PANE_ID` only — a tmux peer has no addressable id in peers.jsonl, so
   the fallback closes herdr peers only and a tmux record surfaces with
   `command: null`. Stated in SKILL.md's disband paragraph.
4. The add-spawn stub has no `pane close`; the new suite uses
   test-roster-disband-close.sh's stub (`agent list` + `pane close`, verbatim
   argv log), which already fits.

## 6. Decisions made / refused

- Made: auto-fallback on `!team` (no flag) — §1.1 rationale.
- Made: pane-kill parity, no graceful-exit message protocol — §1.3.
- Made: `"no-team"` token scope literal — §1.3.
- Made: dismiss gets per-member fallback including mixed rosters — §1.4b.
- Made *(r2, user accepted flag #1)*: disband gets mixed whole-set teardown;
  confirmation-before-close is the existing plan→token→--confirm two-step over
  the union with labeled extras, no third gate — §1.4a.
- Refused (user's call, flagged): config-only removal for team-less rosters
  (§1.6 — user declined, stays out); graceful-exit protocol; making
  spawn-one always persist team.json (follow-up spec if evidence item 1 says
  it is conditional).

## 7. Out of scope

- Any change to team-path behaviour, spawn paths (0039), or `create`.
- disband/dismiss collapse into one subcommand.
- New MCP tools or schema fields.
