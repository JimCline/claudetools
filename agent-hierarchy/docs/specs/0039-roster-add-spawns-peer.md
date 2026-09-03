# 0039 — `add` spawns the live peer, not just the config row

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Origin: user-settled requirement (same session as 0038's landing). Trigger
incident: a peer ran `roster_member add architect`, got a config row, and
misread it as a spawned peer — ListAgents showed nothing. 0038 made `add`
never error on an empty roster; this makes `add` end in a usable peer.
Files: `agent-hierarchy/hooks/roster.mjs` (`add` handler :1095-1138,
`spawn-one` handler :1872-1989, `layoutAndLaunch` :867),
`agent-hierarchy/mcp/server.mjs` (`roster_member` :511-542,
`roster_spawn_one` :658-670),
`agent-hierarchy/skills/agent-roster/SKILL.md` (add section :184-199),
`agent-hierarchy/docs/specs/0038-roster-add-auto-init.md` (pointer only),
`agent-hierarchy/tests/test-roster-add-spawn.sh` (new)

**Requirement (settled by the user — not an option to weigh):**
`add <role>` that succeeds must, when the member's route is `peer`, also
stand up the live peer session. Config-only success is the bug this spec
fixes.

## 1. Design

### 1.1 Flow: validate → write → spawn, in that order

1. All existing validation unchanged and FIRST: `--team X` with no
   `rosters.X` errors per 0032 §3.4b before any spawn attempt; unknown role,
   unwritable level — all pre-spawn. No spawn side effects on any validation
   failure.
2. Config write exactly as today (including 0038 auto-init via
   `freshRosterBlock`/`installRosterBlock`).
3. Then spawn, iff the added member's effective route is `peer`.

Never spawn-then-write: a live peer with no roster entry is the inverse of
the trigger incident.

### 1.2 One spawn implementation

`add` MUST route through the same mechanism as `spawn-one` — extract the
`spawn-one` handler's core (roster resolve → member find → liveness check →
pane placement → `layoutAndLaunch` → team.json persistence, :1872-1989) into
a function both subcommands call. Calling `layoutAndLaunch` directly from
`add` is forbidden: it would duplicate liveness/persistence/pane-seed logic —
the 0035 §11 duplicate-representation family. Structural test pins this (T6).

*(Amended at gap-ruling — the original "comes free" sentence was overbroad.)*
Two populations, both correct as landed:
- **Live slot record, no roster row** (spawn-one's population 2): `add`
  appends the row and reports "already live" — no second session (T8).
- **Roster row exists AND its peer is live**: `add <role>` deliberately
  appends a second member (`<role>-2`) and spawns it. Appending has always
  been `add`'s config semantics; 0039 spawns what was added. A user asking
  `add reviewer` with a reviewer already up is asking for another one — the
  idempotent "make sure one exists" intent belongs to `spawn-one`, which the
  output of the already-live case already names. Target-by-role was
  considered and rejected: it would make `add` silently not do the one thing
  it always did (append).

### 1.3 Route gating

- `route: peer` (explicit or 0038's auto-init default): spawn. The 0038
  empty-roster case therefore ends in a spawned peer (constraint d).
- `route: subagent`: nothing to spawn — config write only, plus one output
  line saying so ("route subagent — dispatched on demand, no session
  spawned"). Silence here recreates the trigger incident's ambiguity.
- *(Ruled at gap-ruling.)* **Never-peer roles** (`task-runner`, i.e. not
  PEER_ELIGIBLE) under a peer-route container: same treatment — config-only
  plus the explicit notice, NOT exit 3. Nothing failed and there is nothing
  to retry; a "spawn FAILED" here would be a false alarm. Landed behaviour
  confirmed.

### 1.4 Spawn failure after a successful config write (ruled here)

**Keep the entry. Fail loudly. Never roll back.**

- The roster row is valid durable state; the spawn is retryable. `spawn-one`
  already exists to "stand up ONE missing or dead peer" — a kept entry plus
  a retry command is strictly better than rollback, which would discard a
  valid write on a transient failure and, in the auto-init case, would have
  to delete the file 0038 just created.
- Exit code **3** (the existing recoverable-partial convention from
  `layoutAndLaunch`). Not 0 — a caller scripting `add` must be able to see
  the peer is not up. Not the validation-failure code — the config DID land.
- Output must state both facts separately and name the remedy
  (remedy-in-the-error, per 0037 §2.2 / 0038 §1.1):
  `added <role> to <path>` then
  `spawn FAILED: <reason> — retry with roster.mjs spawn-one <role> (or roster_spawn_one)`.

### 1.5 Output is never ambiguous about what exists

Every `add` outcome states, explicitly and separately: (a) what was written
and where, (b) whether a session was spawned / already live / not applicable
(subagent route, `--no-spawn`) / failed. The trigger incident was an output
that let a config row read as a live peer.

### 1.6 `--no-spawn` escape

`add --no-spawn` restores config-only behaviour (scripted roster assembly,
tests, pre-staging a roster for a team not yet running). Default is
spawn-on. Exposed on MCP `roster_member` add as `no-spawn` alongside the
existing args.

*(Ruled at gap-ruling.)* `add` also gains **`--allow-global`**, passed
through to the shared core exactly as `spawn-one`'s flag is — no change to
`requireAllowGlobal` itself. Without it, `add <role> --level global` (route
peer) can only end in exit 3: the row lands but the spawn is guard-blocked
with no in-command remedy. The flagless exit-3 remedy text must name BOTH
escapes: `--allow-global` on `add`, or `spawn-one <role> --allow-global`.
Mirror on MCP `roster_member` add (`allow-global`), matching
`roster_spawn_one`.

### 1.7 MCP `roster_member` add

Goes through the CLI `add` (server.mjs:511-542 → `execCli`), so it inherits
spawning automatically — but spawn needs the orchestrator context
`roster_spawn_one` already plumbs (`orchestrator-pid` defaulting to
SESSION_PID, server.mjs:658-670). `roster_member` add gains the same
plumbing; the CLI `add` accepts the same `--orchestrator-pid` arg `spawn-one`
does. NEEDS-EVIDENCE §5.2 covers whether the MCP exec environment carries
what pane placement needs.

## 2. What must not change

- All `add` validation and its ordering; 0032 §3.4b team-must-exist; 0038
  auto-init behaviour (only its ending gains a spawn).
- `spawn-one` CLI behaviour — byte-identical; only its core may be extracted
  for reuse (same rule as 0038's init-writer extraction).
- `layoutAndLaunch`, route semantics, `edit`/`remove` (out of scope).
- `create --spawn` flow and its tests.

## 3. Docs

- SKILL.md add section (:68, :184-199): `add` spawns the peer on success
  (route peer), `--no-spawn` for config-only, subagent route writes config
  only. One short paragraph.
- *(Ruled at gap-ruling.)* SKILL.md Init flow step 6: the per-role `add`
  calls gain `--no-spawn`; `create --spawn` at the end stays the flow's
  single spawn point. Per-add spawning there would spawn incrementally into
  a half-built roster and make `create --spawn` a noisy no-op re-check —
  the flow's deliberate batch spawn is the right shape.
- 0038 spec: one pointer line — "`add`'s ending changed by 0039: successful
  add now spawns the peer."

## 4. Tests

`agent-hierarchy/tests/test-roster-add-spawn.sh`, reusing the launch
stub/fake pattern of `test-roster-spawn-one.sh` (NEEDS-EVIDENCE §5.3).

| # | Scenario | Assert |
|---|---|---|
| T1 | `add reviewer` (route peer), spawnable env | Roster row present AND spawn path invoked / peer record in team.json — verified by read-back, not tool return (W-1 lesson). **Expected to FAIL pre-fix** — the falsifying core |
| T2 | `add reviewer --no-spawn` | Config only; no spawn attempt (stub records zero calls) |
| T3 | `add reviewer --route subagent` | Config only; "no session spawned" notice; no spawn attempt |
| T4 | Spawn failure injected after config write | Entry persists; exit 3; output names both facts and the `spawn-one` retry remedy |
| T5 | `add r --team X`, no `rosters.X` | Errors per 0032 §3.4b; zero spawn side effects |
| T6 | Structural | `add`'s spawn path calls the same extracted function as the `spawn-one` handler; no direct `layoutAndLaunch` call from `add` |
| T7 | Empty roster (0038 T1 scenario), `add reviewer` | File auto-created AND spawn path invoked (route peer default) |
| T8 | `add` of a role whose peer is already live — *as landed:* the role's team.json slot record is live in the registry and the roster has no row for it (spawn-one's population 2). See §5 note on the multi-row case | Config append + "already live"; no second spawn |
| T9 | MCP `roster_member` add through `server.mjs` with the measured live-server env (HERDR vars, PATH, **no** `CLAUDE_PID`) | Result not error; row written; peer spawned (server-plumbed `--orchestrator-pid`). T9b: `no_spawn: true` writes config only |

Mutation standard: T1 seen failing against the unmodified tree; T4 against a
mutant that rolls back the entry on spawn failure; control mutation proving
the anchor site per the standing convention. 0038's suite (22/22) and the
spawn suites stay green.

| T10 | Global-level roster, route peer (§1.6 ruling): flagless `add --level global` / `add --level global --allow-global` / MCP `allow_global: true` | Flagless: exit 3, row written, remedy names BOTH escapes, nothing launched. With the flag (CLI and MCP): spawned. Seen failing (T10a remedy) against a mutant with the both-escapes branch removed |

**Status (landed, after review):** 41/41 pass (T11 added for the level-mismatch
refusal — F1 of the review). Earlier: 38/38 pass (33/33 before T10 and the
Init-flow `--no-spawn` / `--allow-global` amendments). Mutations (temp copies, real tree untouched):
unmodified `roster.mjs` (HEAD) fails T1/T2/T3/T4/T6/T7/T8/T10 (17 assertions;
Reviewer-measured — subtract 4 constant MCP-driver artifacts, T9×2/T9b/T10c,
when reading any copied-tree mutant run, see below);
rollback mutant (`fail()` pops the row and rewrites the file before exit 3)
fails exactly "T4: roster entry persists"; control mutant (`add` skips the
core and fakes `spawned: true`) fails T1/T4/T6/T7/T8 (8); both-escapes
remedy branch removed → exactly "T10a: remedy names both escapes" fails.
**T9/T9b/T10c (MCP-driven) have no mutant evidence:** the inline server
driver reports TIMEOUT on every copied tree, including an unmodified
control copy, so a "HEAD server.mjs" mutant cannot be run that way — the
falsification for the pid plumbing is the live probe in §5.2 (pre-plumbing
server → exit 3 through MCP), and the cases pass only in the real tree. Full regression 54/54 after every existing suite's `add`
gained `--no-spawn` (§1.6's "tests" case — 13 suites, ~80 call sites) and
`test-mcp-server.sh`'s `eq()` learned to strip the MCP `stderr:` block that a
successful `add` now always carries. The first regression run, before those
suites were converted, spawned seven real peer sessions through the live
herdr transport — see the landing report.

## 5. NEEDS-EVIDENCE (route to Implementor)

1. **Extractability of the `spawn-one` core** (:1872-1989) into a shared
   function without behaviour change — same question 0038 §5.2 asked of
   init's writer (answer there: extractable). If invasive, report back
   rather than duplicating.
2. **MCP exec environment**: does `execCli` from server.mjs carry the
   tmux/pane/orchestrator context `layoutAndLaunch` needs when `add` is
   invoked via `roster_member`? Probe with a real MCP call in a live
   session. If it cannot, `roster_member` add must pass `--orchestrator-pid`
   explicitly (§1.7) — confirm that suffices.
3. **Launch stubbing**: how `test-roster-spawn-one.sh` fakes/isolates the
   actual launch, and whether the new suite can reuse it verbatim. If spawn
   tests require a live tmux, say so — do not silently skip T1/T7.
4. **Fresh auto-init container satisfies spawn preconditions**: `spawn-one`
   covers team creation (test-roster-spawn-one.sh), but confirm the 0038
   auto-init'd container (default team, `route: peer`, empty history)
   resolves cleanly through the shared spawn path with no team.json yet.

**Resolved at landing:**

1. Extractable without behaviour change: the handler body became
   `spawnOneCore(role, callerLabel)` returning the JSON the caller prints;
   the `spawn-one` case is now flag validation + `out(await spawnOneCore(...))`.
   Error prefixes take `callerLabel` (`spawn-one:` / `add:`); refusals still
   go through `fail()`. `test-roster-spawn-one.sh` 48/48 unchanged.
2. Measured on the live MCP servers (`ps eww`): env carries `HERDR_ENV=1`,
   `HERDR_PANE_ID`, `PATH`, `CLAUDECODE=1` — **no `CLAUDE_PID`**. A real
   `roster_member add` from this session before the server gained the
   plumbing: row written, then `spawn FAILED: add: no orchestrator pid
   resolvable … retry with roster.mjs spawn-one reviewer` (exit 3, surfaced
   through MCP). `server.mjs` now passes `--orchestrator-pid` (SESSION_PID)
   and `--no-spawn` for action add; T9 drives the real server with that env.
3. `test-roster-spawn-one.sh` fakes launch with a per-invocation-append
   `herdr` stub on PATH (`FAKE_STATE_DIR` call log, `FAKE_HERDR_FAIL_ALWAYS_NAME`
   for injected failure) under `HERDR_ENV=1 HERDR_PANE_ID=p0`; copied
   verbatim into the new suite. No live tmux/herdr needed; T1/T7 run for real.
4. Confirmed: the 0038 auto-init'd container (route peer, no team.json)
   resolves through the shared path and creates the team (T7).

Not resolved here — Architect's call: (a) **T8's multi-row case.** With a live
`myrepo-reviewer` and a roster row for it, `add reviewer` appends a second
row (`myrepo-reviewer-2`) and, since `add` targets the member it just added
(`--member <derived name>` through the core), spawns that new peer — a second
session, which §1.2's "comes free" sentence says should not happen. The
shared path's own semantics agree with the implementation: `spawn-one`
would pick the not-live `-2` too. As landed, "already live" fires only when
the slot record for that role is live (T8). (b) **Roles that are never peers**
(`task-runner`) under a peer-route container: spec gates on route alone; a
spawn attempt would exit 3 with a misleading "spawn FAILED". Landed as
config-only plus `role task-runner is never a peer session — dispatched on
demand, no session spawned`. (c) **SKILL.md Init flow** (step 6) runs `add`
per picked role and later `create --spawn`; each add now spawns unless the
flow passes `--no-spawn`. Text left untouched pending a ruling. (d)
`add --level global` (route peer) spawns through `requireAllowGlobal`, which
`add` has no `--allow-global` for → exit 3 with the spawn-one remedy.

## 6. Decisions made / refused

- **Made** (constraint b was my call): keep-entry + exit 3 + loud remedy on
  spawn failure; rollback rejected (§1.4).
- **Made**: `--no-spawn` escape; spawn default-on (the settled requirement).
- **Made**: subagent route spawns nothing but says so (§1.3).
- **Refused / out of scope**: `edit`/`remove` lifecycle effects (constraint
  e); any second spawn implementation; changes to `create --spawn`.
