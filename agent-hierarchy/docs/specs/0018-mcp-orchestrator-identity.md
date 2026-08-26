# 0018 — Orchestrator identity on the MCP path

Status: implemented and certified; amended 2026-08-26 with two doc-only points from
review (§12). Fixed a defect introduced by 0016 (roster MCP coverage) that defeated
safety checks in 0011 and destroyed team files via 0015's liveness path.

## 1. The defect

`roster_create mode:"commit"` via MCP wrote
`orchestrator: {pid: null, session_id: null}`.

Root cause: **`CLAUDE_PID` is not passed to plugin MCP server subprocesses.** Only
`CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, and `CLAUDE_PLUGIN_DATA` are.
roster.mjs:1036:

```js
const orchestratorPid = typeof opts["orchestrator-pid"] === "string"
  ? Number(opts["orchestrator-pid"])
  : Number(process.env.CLAUDE_PID);
```

`Number(undefined)` is `NaN`, and line 1043 turns a non-integer into `null`. On the
Bash path `CLAUDE_PID` is set and this works as documented; via `execCli`
(server.mjs:318–338, which spawns with `{stdio}` only and inherits the server's env)
the variable was never there to inherit.

Not a bug in `execCli`: the value does not exist in the server's environment, and no
documented mechanism exposes calling-session identity to an MCP server — not the
`initialize` handshake, not a per-session env var. §4 obtains it from the process
tree instead.

### 1.1 Blast radius — worse than mis-reported metadata

**Team files are deleted.** `pidAlive` (lib-hier.mjs:484–492) opens
`if (!Number.isInteger(pid) || pid <= 0) return false;`, so a null pid is not live.
`sweepStaleTeam` (sessionstart.mjs:71–76):

```js
const t = readTeam(dir, team);
if (!t || teamIsLive(t)) return null;
clearTeam(dir, team);
```

On the next plain top-level SessionStart, `team.json` is **cleared** — taking the
member list, refs, and `transport_id`s with it. Panes that team spawned are then
orphaned: `disband` cannot enumerate them, because the file it reads is gone. Data
loss, not a display bug, and it puts §5's `adopt` in a race against the sweep.

**A second guard is silently disabled.** roster.mjs:414, in
`guardTeamPrefixCollision`:

```js
if (existing && pidAlive(existing.orchestrator && existing.orchestrator.pid)) {
```

With a null pid this is `true && false`, so the guard is skipped and 0011 §7.2's
prefix-collision refusal never fires. Two teams can derive identical peer names — the
exact failure 0011 §7.2 exists to prevent, unrepairable by tagging because
ListAgents' namespace is machine-global. The null pid defeated two independent safety
checks (this and 0011 §5.3.5), not one.

**Ownership matching fails.** `roster_move` / `roster_resync` report "known members:
(none)".

### 1.2 Three affected sites, not one

`orchestrator` is written at exactly two places, and read for identity at a third:

| Site | Path | Override flag before this spec | Severity |
|---|---|---|---|
| roster.mjs:1036/1043 | `create --commit` | `--orchestrator-pid` **exists** | Corruption (§1.1) |
| roster.mjs:1347/1354 | `spawn-one` (creates a team when none exists) | **none — env only** | Corruption (§1.1) |
| roster.mjs:1372 | `teams` (computes `myPid` for the `own` field) | none | Degradation |

The `spawn-one` site is the one a commit-path-only fix would have missed, and it was
worse than the commit site in one respect: `Number(process.env.CLAUDE_PID)` with **no
flag to override it**, so via MCP there was no way to get a correct owner onto a team
`spawn-one` created — not even by passing a parameter.

The `teams` site is read-only: `myPid` was `NaN` via MCP, so `roster_teams`' per-team
`own` determination never matched. Wrong output, nothing corrupted.

## 2. Non-negotiable: do not fix this in `teamIsLive` or `pidAlive`

The symptom surfaces in 0015's liveness check, so the fix looks like it belongs
there. **It does not.** Making `pidAlive(null)` or `teamIsLive` treat a null pid as
alive would make every genuinely-dead team read as live forever: 0011 §5.3.5 would
refuse new creates because a corpse owns the team, the 24h sweep would never fire,
and 0015's liveness design would collapse to a constant `true`.

**0015's code is correct**, and so is `pidAlive`. The defect was entirely in what got
*written*. Any patch to the liveness predicates as part of this fix is out of scope
and should be rejected in review.

## 3. Fix A — never write an unresolvable owner

`create --commit` and `spawn-one` must **refuse** rather than write
`orchestrator.pid: null`.

- If the pid cannot be resolved from any source, `fail()` naming what was missing and
  how to supply it. Exit 2, consistent with the CLI's other user errors.
- **No `team.json` is written** on failure. A half-created team is worse than none:
  panes may already be launched and the caller needs a clean retry.
- **Check `pidAlive` at write time**, not only at read time — a supplied-but-dead pid
  is as useless as a null one. Refuse both, with **distinct messages**, so the caller
  can tell "you gave me nothing" from "you gave me a corpse".

**Not merely a backstop.** With §4 in place it should never fire on the MCP path, but
it fires for real on the **Bash** path whenever `CLAUDE_PID` is unset — a cron
invocation, a bare shell, a nested non-Claude subprocess, a test harness. §1.1's
consequences apply identically there. Its tests therefore exercise the Bash path, not
only the MCP one.

## 4. Fix B — the server derives the pid from its own process tree

**The MCP server is a direct child of the Claude Code session process** — verified
empirically: the server's PPID equals the session's `CLAUDE_PID`. So `process.ppid`
inside `server.mjs` *is* the orchestrating session's pid: the same identity
`CLAUDE_PID` carries for Bash-tool subprocesses, reached through the process tree
instead of an env var Claude Code never populates for MCP servers.

Consequences:

- **No Bash call**, by the model or the server. 0016 §1's no-Bash requirement survives
  intact — no amendment needed.
- **No caller parameter required.** `orchestrator_pid` stays an *optional override*,
  matching its existing "Override" schema wording.
- **No stamped-pid file and no multi-session ambiguity rule** (§7).

### 4.1 Capture at startup — the load-bearing detail

Read `process.ppid` **once, at module load, into a constant**. Never at call time.

```js
// mcp/server.mjs, beside HERE / MSG_CLI / ROSTER_CLI
// The session pid, captured at startup: this server is a direct child of the Claude
// Code session, and CLAUDE_PID is not exported to MCP server subprocesses. Read once —
// after the parent exits this process is reparented and process.ppid becomes 1.
const SESSION_PID = process.ppid;
```

If the session dies while the server is still up, the server is reparented (to pid 1,
or a subreaper) and `process.ppid` returns **1** — and `pidAlive(1)` is **true**,
because pid 1 always exists. A lazy read at commit time would stamp an owner that
reads alive forever: the team never sweeps, 0011 §5.3.5 refuses new creates because a
corpse owns it, and liveness pins to true for that team.

Strictly worse than the bug being fixed: **null fails closed and loudly; pid 1 fails
open and silently, permanently.** Capturing at startup closes it — at that moment the
parent is definitely the session, and the constant remains the true session pid after
any later reparenting, so the team correctly reads dead once the session ends.

Two belts:

- **If `process.ppid === 1` at capture time, treat the pid as unresolvable** — set
  `SESSION_PID` to null rather than 1. Already orphaned at startup means the parent
  assumption is broken; falling through to Fix A's loud refusal beats stamping a lie.
- **Never re-read or refresh the constant.** Its correctness comes from *when* it was
  read.

### 4.2 Resolution order

1. explicit `orchestrator_pid` tool parameter (override — always wins),
2. `SESSION_PID` captured at startup,
3. the CLI's own `CLAUDE_PID` default — which never fires on this path.

In `server.mjs`'s `roster_create` case, the `orchestrator-pid` push becomes
`args_in.orchestrator_pid ?? SESSION_PID` (`pushArg` already skips
null/undefined/empty, so a null `SESSION_PID` correctly sends no flag and lands on
Fix A's refusal).

### 4.3 The three sites

- **`roster_create mode:"commit"`** — pass the resolved pid as `--orchestrator-pid`.
  The flag already exists.
- **`roster_spawn_one`** — **roster.mjs gains `--orchestrator-pid` on the `spawn-one`
  verb**, since 1347 read env only with no override. Mirror 1036's precedence exactly
  so the two write sites resolve identity identically — one behaviour at two call
  sites, not two behaviours. Then have the server pass the resolved pid.
- **`roster_teams`** — pass the resolved pid so `myPid` (1372) is correct and the
  `own` field works via MCP. Lowest severity; must not delay the first two, but not to
  be silently skipped either — an `own` field that is always false is a wrong answer,
  not a missing one.

## 5. Fix C — recovery for already-broken teams

Teams committed before this fix have a null owner, and §1.1 means they are on a clock.
Disband-and-recreate is wrong: it tears down running sessions holding real work, for a
metadata problem.

```
roster.mjs adopt --orchestrator-pid <pid> [--team <T>] [--cwd <path>]
```

Re-stamps `orchestrator.pid` on an existing `team.json` without touching `members` or
`team_id`, through the same atomic tmp+`renameSync` helper.

**`adopt` is an ownership-hijack primitive and must be guarded:**

- **Refuse if the recorded owner pid is non-null AND alive AND different from the
  supplied pid.** Adoption is only for orphaned teams — owner null or dead. Without
  this, any session could seize another live session's team.
- The supplied pid must itself be alive (`pidAlive`), same as §3.
- **No `--force`.** Stealing a live team is a design conversation, not a flag.

Do **not** fold this into `resync`. `resync` re-derives member *locations* from herdr
topology (0008 §5.1); ownership identity is a different concern, and overloading it
would make a read-mostly healing verb quietly rewrite identity.

MCP surface: `roster_adopt`, defaulting `--orchestrator-pid` to `SESSION_PID` per
§4.2. Not destructive to live sessions, so no §4.5.1-style ask gate — but
identity-mutating, so a distinct named tool (0016 §4.5's gateability argument) rather
than folded into `roster_config`.

**Operational note:** because the sweep deletes on the next SessionStart, an existing
broken team must be adopted *before* that session restarts. Say so in SKILL.md and in
the release note.

### 5.1 No `--allow-global` guard — intentional (see §12.1)

`adopt` deliberately does **not** call `requireAllowGlobal`, unlike `create --spawn`
(roster.mjs:624), `spawn-one` (1135), and `move` (0016 §4.4). This is a decision, not
an oversight.

0009's gate exists to stop a session from acting at **global breadth** — operating on
a roster definition that spans every repo on the machine. The guarded verbs all
*launch or relocate live sessions* derived from a possibly-global roster.

`adopt` has no breadth. It rewrites one field of one `team.json` inside one project's
`hierarchyDir(cwd)`. It launches nothing, relocates nothing, reads no roster config,
and creates no file. A team's `roster_level` may read `global`, but that records where
the *roster definition* came from — it does not make the team file itself global, and
adoption does not touch that definition.

The threat `adopt` actually carries is ownership seizure, and the §5 hijack guard
addresses it directly and more tightly than a breadth gate would: adoption is
permitted **only** when the recorded owner is null or dead, i.e. only as a repair to a
team nobody is running. Adding `requireAllowGlobal` on top would be consistency
cargo-culting — a prompt for a risk this verb does not carry, which is how gates get
reflexively approved and stop meaning anything.

**Revisit if either becomes true:** `adopt` gains the ability to target a team outside
the current cwd's hierarchy dir, or to change a team's `roster_level`. Both would give
it breadth, and then 0009 applies.

## 6. `session_id` — a pre-existing gap, not part of this regression

roster.mjs:1043 reads the `--session` flag **only** — no env fallback, no other
source. roster.mjs:1354 (`spawn-one`) hardcodes `session_id: null`. So
`orchestrator.session_id` has been null for **every team ever created, on the Bash
path as much as the MCP path**, unless a caller explicitly passed `--session`, which
SKILL.md's § Create step 5 does not.

**Pre-existing and unrelated to 0016.** Consequence: 0011 §4.4 rung 2
self-identification has presumably been degraded since it shipped — team
self-resolution falls back to the default team, making `msg.mjs` auto-resolve and
`buildStateBlock` team scoping less precise.

Severity differs in kind: **a null pid is corruption** (team reads dead, file swept);
**a null `session_id` is degradation** (less precise scoping, nothing destroyed,
nothing misread as dead).

- Accept an optional `orchestrator_session_id` parameter and pass it through when
  supplied. **Do not** hard-refuse when absent.
- **Do not hold a release for this.** Not a regression, not introduced by 0016/0017.

### 6.1 Resolved: how a model could get its own session id — and why neither route is taken

No **direct** mechanism exists: the session id appears in hook payloads, but nothing
exposes it to the model or to an MCP server, and there is no `CLAUDE_SESSION_ID`
analogue to `CLAUDE_PID`.

The **indirect** route is a SessionStart hook stamping it into the hierarchy dir for
the server to read — **which is exactly the pattern §7 withdrew for the pid, and it
fails for exactly the same reasons**: the hierarchy dir is per-*project* while
sessions are many, so a shared stamp file holds several ids and picking one is a
guess; and guessing identity is the failure this spec exists to eliminate.

Note the asymmetry that makes the pid solvable and the session id not: `process.ppid`
works because the process tree is authoritative and per-server, needing no shared
file. There is no process-tree equivalent for a session *id* — it is an application-
level identifier with no OS-level counterpart.

So `session_id` stays null by construction on both paths unless a caller passes
`--session`, and 0011 §4.4 rung 2's degradation is **permanent** absent a new
mechanism from Claude Code itself. Recorded here so the stamping idea is not
rediscovered as a fresh proposal.

## 7. Withdrawn — hook-stamped pid

An earlier revision proposed a SessionStart hook stamping `CLAUDE_PID` into the
hierarchy dir, with an ambiguity rule for multi-session projects. **Superseded by §4**
and not to be built: `process.ppid` gives the same answer with no file, no staleness
window, and no ambiguity, because the server is per-session and the process tree is
authoritative. Recorded so the idea is not revived. See §6.1 for why the same pattern
also fails for `session_id`.

## 8. Files changed

- `hooks/roster.mjs` — §3 refusals at both write sites (1036–1043, 1347–1354); new
  `--orchestrator-pid` flag on `spawn-one`; a pid flag for `teams`' `own` computation
  (§4.3); new `adopt` verb (§5). The `CLAUDE_PID` default and the existing
  `--orchestrator-pid` flag on `create` untouched.
- `mcp/server.mjs` — `SESSION_PID` constant beside `HERE`/`MSG_CLI`/`ROSTER_CLI`
  (§4.1); resolution order at the `roster_create`, `roster_spawn_one`, and
  `roster_teams` pushes; optional `orchestrator_session_id`; new `roster_adopt` tool.
- `skills/agent-roster/SKILL.md` — § Create step 5: the pid is supplied automatically
  by the server, and `orchestrator_pid` is an override, not a requirement. Plus §5's
  operational note.
- `tests/` — §9.
- `plugin.json` **and** root `marketplace.json` — version bump. Both (0011 §14).

## 9. Verification

- **A team committed via MCP has a live, correct owner pid**, `teamIsLive` true,
  `move`/`resync` match members, `history` shows `active: true`, and
  **`sweepStaleTeam` does not clear it** — assert the file survives a simulated
  SessionStart sweep. The data-loss regression test.
- **`spawn-one` via MCP with no existing team** produces a team with a live owner pid,
  not null. The §1.2 site a commit-only fix would have missed.
- `roster_teams` via MCP reports `own` correctly for a team this session owns.
- `guardTeamPrefixCollision` fires again for a properly-owned team (roster.mjs:414).
- **Explicit `orchestrator_pid` overrides the derived value** (§4.2 ordering).
- `SESSION_PID` is read once at module load — `process.ppid` appears exactly once in
  `server.mjs`, at module level. Simulating reparenting in a test is not worth
  building; this structural assertion is the practical check.
- **Bash path unchanged**: `create --commit` with `CLAUDE_PID` set and no explicit
  flag still stamps that pid. `tests/test-roster-cli.sh:75–78` and
  `test-roster-multi-team.sh:203–224` already exercise `CLAUDE_PID` and stay green.
- **Bash path with `CLAUDE_PID` unset** → Fix A refusal, exit 2, **no `team.json`
  written** (assert the file's absence). Both write sites.
- `create --commit --orchestrator-pid <dead pid>` → refused, message distinct from the
  missing-pid one.
- `adopt` on a null-owner team → owner re-stamped; `members` and `team_id`
  byte-identical before and after.
- `adopt` on a team whose recorded owner is alive and different → **refused, before
  any write**. The hijack guard.
- `adopt` on a team whose recorded owner is dead → allowed.
- Full existing suite green.

**Test-harness note:** `tests/test-mcp-server.sh:16` spawns the server directly, so
`SESSION_PID` there is the *test runner's* pid, not a Claude session's. That is correct
and makes the derivation easy to assert — compare the stamped pid against the spawning
shell's `$$`.

## 10. Assessment

Blocking before release, on the grounds that 0016 made the MCP path the *default* way
to create teams, and on that path this wrote a team file deleted at the next
SessionStart, orphaning any panes it spawned — silent data loss in the newly-default
path, surfacing later and in a different subsystem than the one that caused it.

The fix was small: one constant, a resolution order at three call sites, one new CLI
flag, one refusal, one recovery verb.

## 11. Evidence log

All from reading source or direct process inspection:

- `CLAUDE_PID` absent from MCP server subprocess env; no mechanism exposes
  calling-session identity via the MCP protocol (claude-code-guide, against Claude
  Code's documentation).
- **The `ah` MCP server's PPID equals the session's `CLAUDE_PID`** (verified with
  `ps -o pid,ppid,command`). Basis for §4.
- `pidAlive` rejects null/undefined/0 (lib-hier.mjs:484–492); `pidAlive(1)` returns
  true — basis for §4.1's capture-at-startup rule.
- `sweepStaleTeam` calls `clearTeam` on a non-live team (sessionstart.mjs:71–76) —
  deletion, not mis-reporting.
- `guardTeamPrefixCollision` skips its refusal on a null pid (roster.mjs:414).
- `orchestrator` written at exactly two sites, 1043 and 1354; 1354 (`spawn-one`) had
  **no override flag** — basis for §1.2 and §4.3.
- `teams` computes `myPid` from `CLAUDE_PID` at 1372 — read-only degradation.
- `session_id` sourced from `--session` only at 1043, hardcoded null at 1354 —
  establishing §6 as pre-existing.
- `requireAllowGlobal` called at roster.mjs:624 (`create --spawn`) and 1135
  (`spawn-one`) only — basis for §5.1's scope comparison.
- `execCli` spawns with `{stdio}` only, inheriting the server env (server.mjs:318–338).

## 12. Amendment log

### 12.1 `adopt` and the allow-global gate — decided, not deferred

Review noted that §5's `adopt` carries no `--allow-global` guard despite mutating team
ownership. Now answered explicitly in **§5.1: intentional, and it should stay that
way.** 0009's gate guards *breadth* — acting on a roster definition spanning every repo
— and `adopt` has none: one field, one file, one project's hierarchy dir, nothing
launched or relocated. The real threat is ownership seizure, which §5's hijack guard
addresses more tightly by permitting adoption only when the owner is null or dead.

Recorded as a decision rather than left open, because an unanswered "should this have a
gate?" gets re-raised every review, and because adding a prompt for a risk a verb does
not carry is how gates become reflexive and stop meaning anything. §5.1 names the two
conditions that would reverse it.

### 12.2 `session_id` — the indirect route is the withdrawn §7 pattern

§6's conclusion ("no mechanism") was accurate but imprecise. Sharpened in **§6.1**: no
*direct* mechanism exists, and the *indirect* one — a SessionStart hook stamping the id
into the hierarchy dir — is exactly the pattern §7 withdrew for the pid, failing for
the same per-project-file ambiguity reason.

Also recorded there: the asymmetry explaining why the pid was solvable and the session
id is not. `process.ppid` works because the process tree is authoritative and
per-server, requiring no shared file; a session *id* is an application-level
identifier with no OS-level counterpart, so no equivalent exists. The 0011 §4.4 rung 2
degradation is therefore permanent absent a new mechanism from Claude Code itself.
