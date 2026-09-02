# 0033 — Orphaned team records: discovery and reaping

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Files: `agent-hierarchy/hooks/roster.mjs`, `agent-hierarchy/hooks/lib-roster.mjs`,
`agent-hierarchy/mcp/server.mjs`, `agent-hierarchy/hooks/lib-hier.mjs` (state block),
`agent-hierarchy/tests/test-roster-reap.sh` (new)

Split out from the issue-#2 work (spec 0032) deliberately — see §9.

**Line-number caveat:** the `sessionstart.mjs` listing this spec was written
against came back from a runner with two visibly duplicated lines (a transcription
artifact — the duplicate would be a redeclaration error). Line numbers in §2 are
therefore approximate to ±2. Function names and control flow are reliable;
**re-locate by name, not by line number.**

---

## 1. The reported symptom, and what is actually true

Reported: killing a session ungracefully leaves the team's name/record behind
with nothing live backing it, and nothing reaps it.

Confirmed, with the mechanism below. But three things the brief asked me to check
turn out **not** to be missing, and building the obvious feature would have
duplicated them:

- **Discovery already exists.** `roster teams` (`roster.mjs:1899-1920`) is a
  read-only inventory over `[defaultTeam, ...listTeamNames(dir)]` that already
  reports `orchestrator_pid`, **`pid_alive`**, and `own` per team. It is already
  exposed as the `roster_teams` MCP tool. An orphan is already visible; it is
  just not *labelled* as one and nothing routine looks.
- **A single-team reaper already exists.** `sweepStaleTeam`
  (`sessionstart.mjs:~71`) clears an abandoned team on SessionStart.
- **A recovery verb already exists.** `roster adopt` (`:1875-1897`) re-stamps
  `orchestrator.pid` on an orphaned team, refusing when the recorded owner is
  live. Its MCP description already uses the word "orphaned".

So the gap is narrower than "nothing reaps it", and naming it precisely is what
keeps this spec small.

## 2. The actual gap: the sweep is scoped to one team, and it is never the orphan

`sessionstart.mjs` (~`:130`):

```js
if (!isTopLevelAgentSession(input)) teamSweepNote = sweepStaleTeam(dir, resolved.team);
```

`resolved.team` comes from `resolveTeamScope` (`lib-config.mjs:539-555`), which
returns:

1. `opts.team` if explicitly passed — SessionStart passes none;
2. the team whose `team.json` binds `orchestrator.session_id === opts.sessionId`;
3. otherwise `null` — the **default** team.

`sweepStaleTeam` then reads exactly that one file.

**The consequence is a closed loop that can never reach the orphan.** A named
team is only ever swept by a session that *owns* it (branch 2). When that
session dies ungracefully, no surviving session resolves to that team — so
branch 2 never matches it again, branch 3 sends every other session to the
default team's file, and `teams/<name>.json` is never opened by the sweep at all.
The one code path that reaps is structurally unable to see the records that need
reaping.

The default team is fine: every unbound session sweeps it (branch 3). This is a
**named-teams-only** defect, which is why it appeared alongside the multi-team
work in issue #2 rather than earlier.

### 2.1 Why the leftover record actually hurts

Not merely cosmetic:

- `guardTeamPrefixCollision` (`:623-631`) fails `create --team X` when `X` equals
  the default prefix and a live default team exists. Broader: an orphaned
  `teams/X.json` makes `create --team X` collide with a team that no longer runs,
  so the name is burned.
- `resolveTeamScope` and `msg.mjs:110` iterate `listTeamNames` — orphans are
  scanned on hot paths.
- `pretooluse-ultra-gate.mjs:129` reads `listTeamNames` for gate decisions.

## 3. Design

Three changes, in increasing order of what they let a user do. Nothing here
deletes anything without an explicit commit step.

### 3.1 Label the orphan in `roster teams` (read-only)

`describe()` in `case "teams"` gains one field:

```js
orphaned: !pidAlive(pid),        // pid null/unresolvable/dead
```

`pid_alive` already exists and stays; `orphaned` is the negation stated as an
answer rather than a fact to interpret, and it is what the `--plan` output and
the MCP tool description key off. No other change to that block. It still never
writes.

### 3.2 `roster reap` — explicit, plan-by-default

New subcommand, following the established `create`/`disband` convention that a
bare invocation is read-only and `--commit` is the destructive step:

```
roster.mjs reap [--commit] [--cwd <path>]
```

- **Bare (`--plan` semantics, the default):** prints every orphaned team
  (`{name, team_id, orchestrator_pid, members, created}`) and deletes nothing.
- **`--commit`:** `clearTeam(dir, name)` for each, and reports what was removed.
- Rejects any other flag, matching `disband`'s `Object.keys(opts).some(...)`
  guard at `:1338` — an unrecognized flag must fail loudly rather than degrade
  to the destructive path.
- Operates on the **default team and every named team**, i.e. the same
  `[describe(null), ...listTeamNames(dir)]` enumeration `teams` already uses.
  Factor that enumeration into one helper so `teams` and `reap` cannot drift
  apart about what a team is.

### 3.3 The reap predicate — dead pid ONLY, never the age cap

**This is the most important decision in this spec and it must not be
simplified back to `teamIsLive`.**

```js
export const TEAM_STALE_AGE_SEC = 24 * 3600;
export function teamIsLive(t) {
  if (!t) return false;
  const pid = t.orchestrator && t.orchestrator.pid;
  return pidAlive(pid) && ageSecOf(t.created) <= TEAM_STALE_AGE_SEC;
}
```
`lib-roster.mjs:275-282`

`teamIsLive` is `pidAlive(pid) && age <= 24h`. It is a *liveness heuristic*
suited to a single-team safety net, and it is **wrong as a bulk deletion
criterion**: a team whose orchestrator has been running for more than 24 hours is
alive and reads as not-live. A reaper built on `!teamIsLive` would delete the
records of currently-running long-lived teams, in bulk, in one command.

Reap uses a separate, stricter predicate:

```js
/** Reapable: the owning process is provably gone. Age is NOT a factor — see 0033 §3.3. */
export function teamIsOrphaned(t) {
  if (!t) return false;
  const pid = t.orchestrator && t.orchestrator.pid;
  return !pidAlive(pid);
}
```

**Why dead-pid is sound, and one-sided-safe.** `pidAlive` uses
`process.kill(pid, 0)` (`lib-roster.mjs:29-37`, treating `EPERM` as alive). Pid
reuse is the obvious objection, and it errs in the harmless direction only: a
recycled pid makes a dead team read as *alive*, so it is **not** reaped — a
missed cleanup, never a wrong deletion. The inverse cannot occur: a live process
never reports as dead. Every error mode of this predicate is a false negative,
which is exactly the asymmetry a deletion primitive needs.

`teamIsLive` is left completely unchanged. The existing `disband`-refuses and
SessionStart-sweep behaviours keep their current semantics; this spec adds a
predicate, it does not retune one. (That `disband` can currently delete a
>24h-old *running* team's record via `teamIsLive` is a pre-existing hazard,
noted, **out of scope** — reap does not inherit it, and reap does not fix it.)

### 3.4 Surface the orphan count, do not auto-delete

`buildStateBlock` gains one advisory line when any orphan exists:

> `ah: 2 orphaned team record(s) (hotfix, spike) — their orchestrator process is gone. \`roster.mjs reap\` to list, \`reap --commit\` to remove.`

Best-effort, inside the existing try/catch, never blocking.

**Automatic reap-on-resolve is deliberately rejected**, though the brief offered
it as an acceptable alternative:

- The acceptance bar itself forbids adding a new destructive default, and
  deleting another session's record from a passive read path is exactly that.
- It would silently destroy the input `roster adopt` exists to consume. Adopt's
  entire purpose is recovering an orphan; a resolver that reaps on sight makes
  recovery a race against the next hook invocation.
- The blast radius is unbounded in a way the current sweep's is not: today's
  sweep clears one file it is already scoped to. Reap-on-resolve would clear
  arbitrarily many, from any session, including teams belonging to a user who
  has not looked at them yet.

The existing single-team `sweepStaleTeam` stays exactly as it is. **Do not widen
it to iterate `listTeamNames`** — that would convert it into precisely the
automatic bulk deleter this section rejects, and would do so on the
`teamIsLive` predicate §3.3 rules out.

### 3.5 MCP surface

One new tool, mirroring `roster_disband`'s framing (which is already the
non-destructive half of a destructive pair):

```
roster_reap — "List orphaned team records (mode: plan, default, read-only), or
remove them (mode: commit). A team is orphaned when its orchestrator process is
gone. Never touches a team whose orchestrator is alive."
```

`server.mjs` is a thin exec wrapper (confirmed: it holds no resolution logic of
its own), so this is a tool definition plus a `case "roster_reap"` that shells
`roster.mjs reap [--commit]`. `mode: "commit"` requires prior user confirmation,
same convention as `roster_disband_close`.

Existing surface, unchanged, for the record — the four similarly-named tools the
brief asked about:

| Tool | Destructive? | What it does |
|---|---|---|
| `roster_disband` | no | plan/commit/keep-sessions teardown of **one** team; `--commit` removes that team's file. Refuses while `teamIsLive`. |
| `roster_disband_close` | **yes** | closes the team's live **sessions**; needs user confirmation |
| `roster_dismiss` | no | removes **one member** from `team.json`; closes nothing |
| `roster_dismiss_close` | **yes** | closes that one member's session |
| `roster_reap` (new) | commit only | removes **every** team record whose orchestrator is gone |

An abnormal exit skips all four, because all four are things a session does on
its way out. That is why reap has to be driven by a *surviving* session against
liveness evidence, rather than by the dying one.

---

## 4. What must not change

- `teamIsLive`, `TEAM_STALE_AGE_SEC`, `ageSecOf`, `pidAlive` — untouched (§3.3).
- `sweepStaleTeam` and its SessionStart call site — untouched (§3.4).
- `roster adopt` — untouched. Reap and adopt are the two ends of one recovery
  story and must both keep working on the same record.
- `clearTeam` (`lib-roster.mjs:210-218`) — already no-op-on-absent and
  swallows unlink races. Reuse it; do not write a second delete path.
- `disband`'s refuse-while-live guard.
- `teamPath`'s layout: default team at `<dir>/team.json`, named at
  `<dir>/teams/<name>.json`.

## 5. Tests

New `agent-hierarchy/tests/test-roster-reap.sh`. Existing `test-team-stale.sh`
and `test-roster-multi-team.sh` must both still pass untouched.

Fixture note: the tests need a **dead** pid that is definitely not reused, and a
**live** one. Use `$$` for live, and for dead spawn `sleep 0` (or `true`) in the
background, `wait` for it, then use its recorded pid — a just-reaped child's pid
is the most reliable "recently dead" value available in a shell.

| # | Scenario | Assert |
|---|---|---|
| T1 | `teams/hotfix.json` with a dead orchestrator pid; run `roster teams` | that entry has `orphaned: true`, `pid_alive: false` |
| T2 | Same, with a live pid | `orphaned: false` |
| T3 | Orphaned named team; `roster reap` (no flags) | lists it; **the file still exists on disk** — the plan-default guard |
| T4 | Same; `roster reap --commit` | file gone; output names it |
| T5 | **Live** named team (live pid), `created` timestamp set **>24h ago**; `reap --commit` | **file still exists** — this is the §3.3 predicate test and it FAILS against any implementation that reaps on `!teamIsLive` |
| T6 | Mixed: one live team, two orphans; `reap --commit` | exactly the two orphans removed, the live one untouched |
| T7 | Orphaned **default** team (`team.json`, dead pid); `reap --commit` | removed — reap covers the default team too |
| T8 | No teams at all; `reap` and `reap --commit` | empty list, exit 0, no throw |
| T9 | `reap --bogus` | fails loudly; nothing deleted (mirrors `disband`'s flag guard) |
| T10 | Orphaned team; run `roster adopt --orchestrator-pid <live>`, then `reap --commit` | the adopted team is **not** removed — adopt un-orphans it |
| T11 | Team whose `orchestrator.pid` is `null` | `orphaned: true`; reaped by `--commit` |
| T12 | SessionStart with an orphaned **named** team present | the state block mentions it; **the file is NOT deleted** — guards §3.4's no-auto-delete rule |

**Falsifiability:**

- **T5 is the core falsifiable test.** It is the one that fails if someone
  implements the obvious thing (`!teamIsLive`) instead of §3.3's predicate. It
  targets a mistake this spec is trying to prevent, not one the code makes today.
- **T3, T9, T12 are the destructive-default guards** — each fails if reaping
  leaks into a read path.
- T1/T2/T4/T6/T7/T11 are straightforward behaviour tests for new code and have no
  pre-fix meaning.
- **T10 is the adopt/reap interaction** and is the reason §3.4 rejects
  auto-reaping; it should be read as executable rationale.

## 6. NEEDS-EVIDENCE — for the Implementor; I do not execute

1. **Confirm §2's closed loop by reproduction.** Create a named team bound to a
   session, kill that session ungracefully, then start a fresh session and show
   `teams/<name>.json` survives SessionStart. If it is swept, §2's analysis is
   wrong and this spec needs rewriting rather than implementing — stop and
   report.
2. **Re-verify `sessionstart.mjs`'s sweep call by reading the file directly**
   (see the line-number caveat at the top). Specifically: confirm the argument to
   `sweepStaleTeam` is `resolved.team` and that there is no second sweep call
   anywhere. The whole diagnosis rests on that one argument.
3. **Confirm `pidAlive`'s `EPERM`-means-alive branch behaves as assumed** for a
   pid owned by another user, if that is reachable in this deployment. §3.3's
   one-sided-safety argument depends on it never reporting a live process as
   dead.
4. **Report whether any consumer of `listTeamNames` currently misbehaves in the
   presence of an orphan** (`lib-config.mjs:546`, `msg.mjs:110`,
   `pretooluse-ultra-gate.mjs:129`). §2.1 asserts these merely scan orphans; if
   one of them errors or mis-gates instead, that is a second defect and belongs
   in this spec.

## 7. Acceptance

1. `roster teams` reports `orphaned` for the default team and every named team,
   and still writes nothing.
2. `roster reap` with no flags lists orphans and **deletes nothing**.
3. `roster reap --commit` deletes exactly the team records whose orchestrator pid
   is dead or null, and no others.
4. A team with a live orchestrator is never reaped, **regardless of its age**
   (T5).
5. No read path, hook, or resolver deletes a team record as a side effect (T12).
6. `teamIsLive`, `TEAM_STALE_AGE_SEC`, `sweepStaleTeam`, `roster adopt`, and
   `disband`'s live-guard are unchanged.
7. `roster_reap` is exposed via MCP with `plan` as the default mode.
8. `test-team-stale.sh`, `test-roster-multi-team.sh`, `test-roster-disband.sh`,
   `test-roster-dismiss.sh` and every other pre-existing test still pass.
9. All four §6 NEEDS-EVIDENCE items are answered in the implementation report.

## 8. Decisions made, and what I am NOT deciding

**Made:**

- Explicit `reap` verb over automatic reap-on-resolve (§3.4), on the grounds that
  the alternative is a destructive default and destroys adopt's input.
- A new `teamIsOrphaned` predicate rather than reusing `teamIsLive` (§3.3). This
  is the decision most likely to be "simplified" away by an implementor who sees
  an existing predicate that looks close enough. It is not close enough.
- Plan-by-default with `--commit`, matching `create`/`disband`.
- Reap covers the default team as well as named ones (T7) — a crashed default
  orchestrator leaves the same debris.

**Not decided, and left alone on purpose:**

- Whether `disband`'s use of `teamIsLive` (which lets a >24h *running* team be
  disbanded) should change. Pre-existing, real, and a separate fix.
- Whether `TEAM_STALE_AGE_SEC`'s 24h is the right number for the SessionStart
  sweep.
- Any change to how teams are *named* or how prefix collisions are guarded
  (§2.1 explains why orphans burn names; reaping them is the fix offered here,
  and re-designing collision handling is not).

## 9. Why this is its own spec and not part of 0032

The brief asked me to judge fold-in vs. split. **Split**, on three grounds:

1. **Different data, different directory.** 0032 is about roster *templates* —
   `agent-hierarchy.json` under `.claude/` and `~/.claude/…/projects/`, config
   that describes teams that do not exist yet. 0033 is about *runtime records* —
   `team.json` / `teams/<n>.json` under `.claude/hierarchy/`, which describe
   teams that did exist. The two share the word "team" and essentially nothing
   else; no file is touched by both specs.
2. **Different failure classes.** 0032 fixes a resolution bug (wrong answer from
   a read). 0033 adds a lifecycle capability (a missing verb) and its central
   risk is *deleting too much*. Bundling them makes one spec whose acceptance
   list mixes "resolves correctly" with "does not destroy data".
3. **Partial completion has to be meaningful.** 0032 already carries two fixes
   and four NEEDS-EVIDENCE items, one of which (§7 item 2) could invalidate half
   of it. If that happens, 0033 should still be implementable unchanged. A single
   merged spec could not be partially accepted.

They can be implemented in either order and share no code. If one Implementor
takes both, 0032 first is marginally better — its §7 evidence items are the ones
that might change the plan.

## 10. Confidence

**High on the diagnosis (§2)** — the closed loop follows from
`resolveTeamScope`'s three branches and the single sweep call site, and it is
directly checkable by §6 item 1.

**High on the design**, with one caveat: §3.3's predicate is the load-bearing
part, and it is guarding against a mistake that is *easier* to make than the
correct version. T5 exists specifically to catch it, and if T5 is ever deleted as
redundant the guard is gone.

**No Ultra-Advisor escalation recommended.** The one genuinely risky element —
bulk deletion — is contained by a predicate whose failure modes are all
false-negative (§3.3), a plan-by-default CLI, and an explicit refusal to put
deletion on any read path.

**Worth recording:** three capabilities the brief assumed were missing already
exist (`roster teams`' `pid_alive`, `sweepStaleTeam`, `roster adopt`). The
useful fix turned out to be one scoping bug plus one verb, rather than a new
subsystem. Checking what was already there before designing is what kept this
spec from re-implementing an inventory command that already ships.
