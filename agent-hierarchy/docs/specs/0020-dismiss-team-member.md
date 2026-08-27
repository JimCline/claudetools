# Spec 0020 — `dismiss`: drop ONE member from a live team

Status: draft
Companion to `docs/specs/0019-spawn-one-role-disambiguation.md` — `spawn-one` adds one member to a live
team; this is the missing inverse.
Mirrors, and must not fork, the three-phase shape of `disband` defined in
`docs/specs/0006-disband-kill-by-default.md` §5, extended by `0016` §4.5 (`--close`) and `0008` §5.6
(in-memory resync).

**Amended (a), before implementation — NEEDS-EVIDENCE #1 resolved from `0017` and `0006`.** The close gate
is an **exact-name** match, not a prefix or a category. §4 and §5 carry that as a hard requirement rather
than an open question, and §7 records the reconciliation with `0006` §4, which on its face forbids what
§3.3 does.

**Amended (b), before implementation — two Orchestrator decisions, plus one correction I owe from (a).**
1. **The verb is `dismiss`**, not `team-remove`. User-confirmed semantics: it dismisses one *instance* by
   derived name (`dismiss bps-implementor-2`), never a role. Renamed throughout, including the MCP tool
   names, the ask-hook entry, and the test file. The three-phase design and every verified property —
   token scoping, the reused close path, exact-name gate registration, the `0006` reconciliation — are
   unchanged.
2. **`--also-config` is added** (§3.5). `--commit --also-config` additionally removes the matching roster
   config entry. Default stays off.
3. **Correction to (a)'s §4.1:** the exact-name match lives in **two** places, not one — the hook body and
   the `hooks.json` matcher. (a) said "add one string to a list"; that was wrong and would have shipped a
   hook that never fires. §4.1 is rewritten.

**Amended (c), during review — NEEDS-EVIDENCE #2 closed by the Reviewer's investigation.** `partial` is
**display-only**: written at `create`/`spawn-one`, read only for status display in `lib-config.mjs` /
`lib-hier.mjs`, and never cross-checked against the live member count. `dismiss`'s `{...team}` spread
preserves it as-is, which is correct and deliberate — see §3.4. §9 no longer carries an open item.

## 1. Goal

There is no verb that removes a single member from a live `team.json`.

- `roster.mjs remove --member <NAME>` edits the roster **config** — the template for future teams. It does
  not touch the check-in registry.
- `disband` (every mode) operates on the **whole** team. There is no scoped subset.
- `create --commit` refuses while a live team exists (`roster.mjs:732`), so there is no rewrite-minus-one path.

Observed consequence: closing an idle `bps-task-runner` while four other peers stayed live required a
manual `herdr pane close` plus a config-level `remove`, leaving `team.json` holding a stale record for a
member that no longer exists. Every consumer that reads `team.json` as authoritative
(`teamMemberByName`, `roleForPeerName`, `buildStateBlock`, the route gate) then believes in a dead peer.

## 2. Design — mirror `disband`, scoped to one member

`disband` is already three separate calls, each with a distinct blast radius. Reuse that shape exactly;
do not invent a fourth pattern.

| `disband` | `dismiss <name>` | Effect |
|---|---|---|
| bare / `--plan` | bare / `--plan` | Read-only. Resync in memory, emit the close plan + `close_token`. Writes nothing. |
| `--close --confirm --plan-token <tok>` | `--close --confirm --plan-token <tok>` | Close the live pane(s). Does **not** touch `team.json`. |
| `--commit` | `--commit [--also-config]` | Rewrite `team.json`. Closes nothing. |
| `--keep-sessions` | *(not ported — §3.6)* | |

This answers the Orchestrator's original "one mode or two?" question: it is neither. It is the same
plan → close → commit split `disband` already has, and the two repro cases fall out of it for free:

- **Prune an already-dead member** (the reported repro): `dismiss <name> --commit`. One call.
- **Close a live member and prune it**: `dismiss <name>` (plan) → `--close --confirm --plan-token` →
  `--commit`. Three calls, same gating a whole-team close already carries.

## 3. Command surface

```
roster.mjs dismiss <name> [--plan] [--cwd <path>] [--team <T>]
roster.mjs dismiss <name> --close --confirm --plan-token <tok> [--allow-global] [--cwd <path>] [--team <T>]
roster.mjs dismiss <name> --commit [--also-config] [--level L] [--cwd <path>] [--team <T>]
```

One required positional: the **derived member name** from `team.json` (`bps-implementor-2`), never a role.
A role is ambiguous under `0019`'s same-role members and must be rejected as such — and the verb's whole
point is per-instance dismissal.

Add beside the other flag sets (`roster.mjs:59-65`):

```js
const DISMISS_FLAGS = new Set(["plan", "close", "commit", "confirm", "plan-token", "also-config", "level", "allow-global", "cwd", "team"]);
```

Unknown flag → loud `fail` listing the valid ones. This is `0006` §6's requirement, and it applies here
for the same reason it applies to `disband`: a mistyped flag must not fall through to a mode with a
different blast radius.

Mutually exclusive: `--close` with `--commit` → `fail`. `--plan` with either → `fail`.
`--also-config` or `--level` without `--commit` → `fail` (they mean nothing on the read-only and close
paths, and silently ignoring them would let a caller believe the config was edited).
Bare (no mode flag) = `--plan`, exactly as `disband`.

Add the three lines to the usage banner at the top of `roster.mjs` (after the `disband` line, before
`resync`).

### 3.1 Name resolution

```
team = readTeam(dir, teamArg)
if (!team)                       → out({ dismissed:false, reason:"no active team" }), exit 0
target = team.members.find(m => m.name === name)
if (!target)                     → fail("dismiss: no member named <name> in team <team_id> — it has: <names…>")
```

Exit-0-with-reason for "no active team" (not `fail`) matches every `disband` mode; the absence of a team
is not a usage error.

If `<name>` matches no member but **does** match a role in the team, the failure message must say so
explicitly: `"... — that is a role, not a member name; dismiss takes a derived name (0019 §3.2)"`.

### 3.2 `--plan` (default)

Read-only. For `transport === "herdr"`, call `resyncMembers(team)` first and use the healed record for the
target when `query_ok` — so the plan names the member's *current* pane. Never persist the heal; on a query
error degrade to the stored ids with `status: "unqueried"`. This is `disband`'s existing `0008` §5.6
behaviour, applied to one member.

Output:

```json
{"member": {"role":"task-runner","name":"bps-task-runner","route":"peer",
            "transport":"herdr","transport_id":"%17","command":"herdr pane close %17",
            "resync_status":"unchanged"},
 "live": true,
 "close_token": "<hash>",
 "team_id": "…",
 "remaining": ["bps-architect","bps-implementor","bps-reviewer","bps-ultra-advisor"]}
```

- `command` is `null` when the member is not closable (`route !== "peer"` or `transport_id == null`) —
  same predicate as `closableMembers`.
- `live` is `memberIsLive(dir, target.name)`. This is what tells the caller whether it needs the
  close phase at all, and is the field the SKILL.md flow should branch on.
- `remaining` exists so the caller can see, before committing, that it is not about to empty the team.

**Note the store split (`0019` §3.3.1):** `live` comes from the registry (`latestRoster`), while `target`
comes from `team.json`. Here that split is benign in one direction and worth stating in the other: a
member recorded in `team.json` whose registry entry has gone stale reports `live:false`, yet its
`transport_id` still yields a `command`. So the close path stays available even when liveness says
otherwise — do **not** gate the emission of `command` on `live`.

### 3.3 `--close --confirm --plan-token <tok>`

Reuse the existing machinery verbatim — `closeToken`, `closableMembers`, `closeMemberPane`,
`requireAllowGlobal`. **Do not write a second close path.** (On why a CLI may close a pane at all, see §7 —
`0006` §4 forbade it and `0016` §4.5 deliberately moved that boundary. This spec inherits the new one and
adds nothing to it.)

```
closable = closableMembers([healedTarget])          // 0 or 1 entries
if (closable.length === 0)  → fail("dismiss --close: <name> has no addressable pane (route=<r>, transport_id=<id>) — use --commit to prune the record")
if (opts.confirm !== true)  → fail("dismiss --close: --confirm is required to close a live session. Close list: <json>")
if (!opts["plan-token"])    → fail("dismiss --close needs --plan-token <tok>, from a preceding `dismiss <name>` (plan) call")
if (opts["plan-token"] !== closeToken(team.team_id, closable)) → fail(<disband's topology-changed text, verbatim>)
requireAllowGlobal(resolveRoster(cwd, teamArg)?.level, …)      // same pre-close gate disband --close has
closeMemberPane(team.transport, healedTarget.transport_id)
out({ closed: true|false, results: [ … ] })
```

**Token scoping is load-bearing and falls out for free.** `closeToken` hashes
`{team_id, ids:[…sorted]}`. A whole-team `disband` plan produces a token over *all* pane ids; a
single-member plan produces one over exactly one id. They cannot collide, so a stale full-team token can
never authorise a single-member close, and a single-member token can never authorise a whole-team close.
No new token type, no new validation rule. Say this in a comment at the call site so a later
"simplification" does not widen the hash input.

`--close` deliberately does **not** rewrite `team.json` — identical to `disband --close`. The record is
removed by a following `--commit`. Splitting them is what makes a failed close observable instead of
leaving a registry that disagrees with reality.

### 3.4 `--commit`

Merge-write, mirroring `spawn-one`'s append (0019 §3.3) in reverse:

```
outTeam = { ...team, members: team.members.filter(m => m.name !== name) }
writeTeam(dir, outTeam, teamArg)
```

Preserve `team_id`, `created`, `transport`, `roster_level`, `orchestrator`, `partial`, and every other
member — whole-file rewrite, single writer (0008 §3). Use `writeTeam`; do not hand-roll a write.

**`partial` is preserved as-is, and must not be recomputed** *(amendment (c), Reviewer-verified)*.
It is written at `create`/`spawn-one` and read **only** for status display (`lib-config.mjs`,
`lib-hier.mjs`); nothing cross-checks it against the live member count. The `{...team}` spread above
already carries it forward correctly. Dismissing a team below its original membership therefore does
**not** flip `partial` to `true` — deliberate, and cosmetic either way. Do not add a recompute; it would
change a display value to describe a different thing than it describes everywhere else it is written.

**A `--commit` on a still-live member is allowed, and must warn.** This is the exact contract
`disband --keep-sessions` already has at team scale: the registry stops claiming the member, the session
keeps running, and the user is told how to close it. Required stderr line when `memberIsLive` is true:

```
roster.mjs: ah: <name> is still live (<transport> <transport_id>). Its record is gone from team <team_id>;
close it with `<command>` if you did not mean to leave it running.
```

Silently pruning a live peer with no warning is the one outcome this spec must not produce.

Output: `{"dismissed": true, "member": {…}, "team_id": "…", "remaining": [...], "team_empty": false,
"config": null}` — `config` is populated only by §3.5.

### 3.5 `--also-config` (with `--commit` only)

`--commit --also-config` additionally removes the matching roster **config** entry, so a future `create`
does not rebuild the instance that was just dismissed. Default off: without the flag, `dismiss` is
`team.json`-only.

**Order is fixed: `team.json` first, config second.** The registry write is the operation the user asked
for; the config edit is the convenience. If the config edit fails, the dismissal has still happened and
must be reported as such — never fail the whole call after a successful `writeTeam`.

Level selection reuses `remove`'s existing `targetLevel()` helper: `--level L`, else the currently
resolving level, and it must print which level it chose exactly as `add`/`edit`/`remove` do. Removal
reuses `findMemberIndex(members, name)` against `namedMembers(...)`. **Do not write a second config-edit
path** — if the shared logic is not already factored out of `case "remove"`, factor it once and have both
call it.

Not found in that level's config → **warn, do not fail**:

```
roster.mjs: ah: dismissed <name> from team <team_id>, but no roster member named <name> exists at level
"<level>" — the config was not changed.
```

Report the outcome rather than hiding it: `"config": {"removed": true, "level": "repo-user", "path": "…"}`
or `{"removed": false, "level": "…", "reason": "no such member"}`.

#### 3.5.1 Ordinal shift — the sharp edge of this flag

`0001` §3.4 derives names by 1-based ordinal within a role, and explicitly accepts that removing a member
re-ordinals the later same-role members. Under `--also-config` that acceptance is no longer free, because
a **live** team record can now be stranded:

> Roster has `implementor`, `implementor-2`. Both live. `dismiss bps-implementor --commit --also-config`
> removes the config entry for the first. The remaining config member now derives as **`bps-implementor`**,
> while the still-running session and its `team.json` record are named **`bps-implementor-2`**.

Nothing breaks — `team.json` is authoritative for dispatch names (`0001` §5.2), so `teamMemberByName`,
`roleForPeerName`, the route gate, `resync`, `move`, and a later `dismiss` of that member all keep
working on `bps-implementor-2`. What changes is that a future `create` or `spawn-one` would derive
`bps-implementor` for it, and `warnMixedPrefixSpawnOne`'s sibling condition (`0019` §3.5) is exactly this
shape.

**Required: warn loudly and name every affected member**, whenever `--also-config` removes an entry that
is not the last of its role AND a live team record exists for a later same-role sibling:

```
roster.mjs: ah: removing <name> from the roster re-ordinals later <role> members: <old> is now derived as
<new>. Live team records keep their original names and still dispatch correctly; a future create/spawn-one
will use the new names.
```

Include the same mapping in the output as `"config": {..., "reordinaled": [{"from":"bps-implementor-2","to":"bps-implementor"}]}`.

**Deliberately not refused.** Refusing would make `--also-config` unusable in exactly the multi-instance
case `dismiss` exists for, and the consequence is a naming inconsistency the user can see and act on, not
data loss. But it must never be silent.

### 3.6 Deliberate non-goals

- **No `--keep-sessions`.** At single-member scope it is exactly `--commit`, which already leaves the
  session alone. A second spelling for the same thing is the kind of surface `0009` (b) cut.
- **Config editing is opt-in only.** Without `--also-config`, `dismiss` touches `team.json` and nothing
  else. **Both verbs must name the store they wrote** in their output (`remove` → "roster config at
  `<level>` (`<path>`)"; `dismiss` → "team `<team_id>`", plus the `config` block when `--also-config`),
  because the two now overlap and a reader must be able to tell which store changed.
- **No orchestrator dismissal.** The orchestrator is not a member (`0001` §3.2); `<name>` can never match it.

### 3.7 Emptying the team

Dismissing the last member leaves `members: []` rather than unlinking `team.json`. `team_id`, `created`,
and `orchestrator` still identify a real session that `spawn-one` can repopulate, and unlinking would make
`dismiss` silently a `disband`. Emit `"team_empty": true` and a stderr note pointing at `disband --commit`
if the user actually wanted the team gone.

## 4. MCP surface — and the gate that must be extended with it

`0017` keeps the destructive three (`roster_disband_close`, `roster_move`, `roster_spawn_one`) as
distinct tools for "independent permission-gateability and independent audit visibility", and records:

> `mcp__ah__roster_disband_close` in particular is matched **by exact name** by the §4.5.1 ask hook and by
> `tests/test-disband-close-gate.sh`; collapsing it would break the one user-enforced gate in the system.

**That settles the shape.** Two tools — the mode tool and a separately-named close tool — and because the
match is by exact name, the new close tool is **ungated until it is registered in both places named in §4.1**.

```jsonc
{ "name": "roster_dismiss",
  "description": "Dismiss ONE member from a live team's check-in registry by derived name (e.g. 'dismiss bps-implementor-2'). Does not close sessions.",
  "inputSchema": { "type":"object", "properties": {
      "cwd": cwdSchema, "team": teamSchema,
      "name": { "type":"string", "description":"Derived member name from team.json, not a role." },
      "mode": { "type":"string", "enum":["plan","commit"], "description":"plan (default) is read-only; commit rewrites team.json minus this member." },
      "also_config": { "type":"boolean", "description":"With mode:commit, also remove the matching roster config entry so a future create does not rebuild it." },
      "level": { "type":"string", "enum":["global","repo","repo-user"], "description":"Config level for also_config; defaults to the resolving level." }
    }, "required": ["cwd","name"] } }

{ "name": "roster_dismiss_close",
  "description": "Close ONE live team member's session. Destructive; requires prior user confirmation.",
  "inputSchema": { "type":"object", "properties": {
      "cwd": cwdSchema, "team": teamSchema,
      "name": { "type":"string" },
      "confirm": { "type":"boolean", "description":"Must be true, and only after the user has been shown the close list and agreed." },
      "plan_token": { "type":"string", "description":"close_token from the preceding roster_dismiss mode:plan call." },
      "allow_global": { "type":"boolean" }
    }, "required": ["cwd","name","confirm","plan_token"] } }
```

### 4.1 REQUIRED — register the close tool in BOTH gate locations, same commit

*Rewritten by amendment (b). (a) said "add one string to a list" — that was wrong.*

`hooks/pretooluse-disband-close-gate.mjs` gates the existing tool. The exact name appears **twice**, and
both are load-bearing:

1. **The `hooks.json` PreToolUse matcher** that fires the hook only for
   `mcp__ah__roster_disband_close`. If the new tool is absent here, the hook **never runs at all** and the
   in-body check below is dead code.
2. **The hook body:** `if (input.tool_name !== "mcp__ah__roster_disband_close") process.exit(0);`

The matcher is the load-bearing half in a way worth stating: the hook's `catch` block **fails closed** and
asks anyway on a parse error, and its own comment explains that this is safe *because the matcher
guarantees the tool identity*. A tool that reaches the body without being in the matcher gets no gate; a
tool in the matcher but not the body gets `exit(0)` and no gate either. **Both, or neither works.**

Implementation choice — either is acceptable, pick one and say which:
- extend the existing hook to match both names (matcher gains the name; body compares against a
  two-element set), or
- add a sibling hook file for `roster_dismiss_close`.

Extending is the smaller diff and keeps one fail-closed path; a sibling duplicates the catch-block
reasoning and is easier to get subtly wrong.

**Do not "improve" the match into a prefix or suffix rule** (`_close`, `roster_*`) as part of this change.
`0017` chose exact-name matching deliberately and the hook's own comment says a wildcard "would train
users to blanket-allow the whole server, destroying the one gate that matters here." Widening a security
predicate as a drive-by is exactly the kind of edit that should be its own spec with its own review.

`tests/test-disband-close-gate.sh` must gain a parallel case for the new tool — see §6, item 21. That test
is the only thing that will notice if a future refactor drops either registration.

## 5. Files to change

| File | Change |
|---|---|
| `agent-hierarchy/hooks/roster.mjs` | `DISMISS_FLAGS`; usage banner; new `case "dismiss":` per §3. Reuses `resyncMembers`, `closableMembers`, `closeToken`, `closeMemberPane`, `memberIsLive`, `requireAllowGlobal`, `readTeam`, `writeTeam`, and (for `--also-config`) `targetLevel`/`readLevelFile`/`findMemberIndex`/`namedMembers`/`writeLevelFile`. **No new helper unless it has two callers.** (`plan`/`close`/`commit`/`confirm` are already in `BOOL_FLAGS`; add `also-config`.) |
| `agent-hierarchy/hooks/roster.mjs` (`remove` case) | Output/message names the store: "roster config at `<level>` (`<path>`)" (§3.6). Factor the config-removal body if `--also-config` cannot reuse it as-is. |
| `agent-hierarchy/mcp/server.mjs` | `roster_dismiss` + `roster_dismiss_close` per §4, modelled on `roster_disband`/`roster_disband_close`. |
| **`hooks/hooks.json` PreToolUse matcher** | **Add `mcp__ah__roster_dismiss_close` — §4.1, non-negotiable, same commit.** |
| **`hooks/pretooluse-disband-close-gate.mjs`** | **Match both tool names in the body — §4.1.** Rename the file only if you also update every reference to it; the rename is optional and not required by this spec. |
| `agent-hierarchy/skills/agent-roster/SKILL.md` | Document the three calls, `--also-config`, and the `remove` vs `dismiss` distinction in one line. |
| `agent-hierarchy/tests/test-roster-dismiss.sh` | **NEW**, §6. |
| `agent-hierarchy/tests/test-disband-close-gate.sh` | Parallel case for `roster_dismiss_close` (§6 item 21). |
| `agent-hierarchy/tests/test-mcp-server.sh` | Passthrough cases for both new tools; add both names to the tool-list assertion at `:116`. |
| `.claude-plugin/plugin.json` + root `marketplace.json` | Version bump in **both** — this repo requires it. |

## 6. Verification

New `agent-hierarchy/tests/test-roster-dismiss.sh`, stubbing `herdr` the way
`tests/test-roster-disband-close.sh` does:

1. **The repro** — 5-member team, `bps-task-runner` dead: `dismiss bps-task-runner --commit` leaves 4
   members, preserves `team_id`/`created`/`transport`/`roster_level`/`orchestrator`, and the other 4
   records are byte-identical.
2. **Plan is read-only** — bare `dismiss <name>` emits `member`/`live`/`close_token`/`remaining`; the
   herdr stub is never asked to close; `team.json` byte-identical afterwards.
3. **Close requires confirm** — `--close --plan-token <valid>` without `--confirm` exits non-zero and the
   message contains the close list.
4. **Close requires a token** — `--close --confirm` with no `--plan-token` exits non-zero.
5. **Token must match** — a token from a plan taken *before* a `resync` moved the pane is rejected with
   the topology-changed message.
6. **Cross-scope token rejected** — a `close_token` from a whole-team `disband` plan does NOT authorise
   `dismiss --close`, and vice versa. (This is the §3.3 claim; assert it, do not assume it.)
7. **Close does not prune** — after a successful `--close`, `team.json` still contains the member.
   `--commit` then removes it.
8. **Live commit warns** — `--commit` on a live member succeeds, and stderr contains the member name and
   its close command.
9. **Stale registry still yields a command** — member present in `team.json` with a `transport_id` but no
   fresh registry entry: plan reports `live:false` **and** a non-null `command` (§3.2).
10. **Unknown member** — non-zero, message lists the team's actual member names.
11. **Role instead of name** — `dismiss task-runner` (a role) exits non-zero and says it is a role.
12. **No active team** — exit 0 with `{"dismissed":false,"reason":"no active team"}`.
13. **Last member** — dismissing the only member yields `members: []`, `team_empty: true`, and `team.json`
    still exists.
14. **`--also-config` happy path** — roster has `implementor` + `implementor-2`, team has both;
    `dismiss bps-implementor-2 --commit --also-config` removes the team record AND the config entry;
    output's `config.removed` is true and names the level; a subsequent `roster.mjs show` lists one
    implementor.
15. **`--also-config` ordinal warning** — same roster, both live;
    `dismiss bps-implementor --commit --also-config` succeeds, stderr names the re-ordinaling, and output
    carries `config.reordinaled: [{from:"bps-implementor-2", to:"bps-implementor"}]`. The surviving
    `team.json` record is still named `bps-implementor-2` (§3.5.1).
16. **`--also-config` miss is not fatal** — member exists in `team.json` but not in the roster config:
    exit 0, `dismissed:true`, `config.removed:false` with a reason, and stderr says the config was not
    changed. `team.json` **is** modified.
17. **`partial` is untouched** — a team written with `partial: true` still has `partial: true` after a
    `--commit`, and one written with `partial: false` still has `false` even when the dismissal drops it
    below its original membership (§3.4, amendment (c)).
18. **Flag misuse** — `--also-config` without `--commit` exits non-zero; `--level` without `--commit`
    exits non-zero; `--close --commit` exits non-zero.
19. **Global gate** — global-level roster + `--close` without `--allow-global` → non-zero naming
    `--allow-global`; with the flag → proceeds. (`--commit` is not gated, matching `disband --commit`.)
20. **Unknown flag** — non-zero, `team.json` intact, and **no plan on stdout** (`0006` §6 requires all
    three conditions; a run that prints usage after emitting the plan passes a weaker check).
21. **Named team** — `--team <T>` operates on `teams/<T>.json` and leaves the default `team.json` untouched.
22. **Gate coverage (in `test-disband-close-gate.sh`)** — `mcp__ah__roster_dismiss_close` produces
    `permissionDecision: ask` exactly as `mcp__ah__roster_disband_close` does, **and** a case asserting the
    hook is reached at all (i.e. the matcher registration, §4.1 item 1 — a body-only fix passes an
    in-process hook test while being ungated in production). **Both must be shown to fail before the
    registrations are added**, or they prove nothing.

Regression bar: `test-roster-disband.sh`, `test-roster-disband-close.sh`, `test-disband-close-gate.sh`
(pre-existing cases), `test-roster-spawn-one.sh`, `test-roster-cli.sh` (the `remove` cases, if the
config-removal body is factored), `test-roster-multi-team.sh`, and `test-roster-resync.sh` pass
**unmodified**.

## 7. Reconciliation with `0006` §4 — read this before objecting

`0006` §4 states, emphatically, that `roster.mjs` executes nothing destructive:

> `roster.mjs` still never invokes `herdr pane close`, `tmux kill-pane`, or any other close verb. …
> **`roster.mjs` may start a process and may not stop one** … Anyone reading this spec as licence to let
> `roster.mjs` execute a close has misread it. Say so in review.

**That boundary was moved by `0016` §4.5, which is shipped**: `closeMemberPane` exists in `roster.mjs`
today and `disband --close` calls it, behind `--confirm` + `--plan-token` + the ask hook. This spec does
not move it again — it reuses the *existing* gated close path at single-member scope.

Recorded here explicitly because a reviewer reading `0006` §4 in isolation will correctly flag §3.3 as a
violation. The answer is that `0006` §4 is superseded on this point by `0016` §4.5, and the safety
property that replaced it is *"a close is executed only behind confirm + a topology-bound token + a
name-matched ask hook"* — which §3.3 and §4.1 both satisfy. **If `0016` §4.5 does not in fact carry that
supersession in its own text, that is a documentation defect worth fixing while here** (a one-line
amendment note on `0006`, in the style `0006` §7.1 itself prescribes), because the next spec author will
hit the same contradiction.

## 8. Decisions made here

- **Three phases, not two modes.** Both of the Orchestrator's cases, but as `disband`'s existing
  plan/close/commit split rather than a new `--kill`-style boolean. The already-dead case collapses to a
  single `--commit`; the live case pays the same confirmation cost a whole-team close pays. No new gating
  concept enters the codebase.
- **`--close` does not imply `--commit`.** Two calls, deliberately, exactly as `disband`. A close that
  fails must not leave the registry claiming the member is gone.
- **`--also-config` warns rather than refuses on ordinal shift** (§3.5.1). Refusing would make the flag
  unusable in the multi-instance case `dismiss` exists for; the consequence is a visible naming
  inconsistency, not data loss. Silence is the only unacceptable option.
- **`team.json` first, config second** (§3.5), and a config miss is a warning, not a failure. Failing
  after a successful registry write would leave the caller unsure what happened.
- **`partial` is carried forward, never recomputed** (§3.4) — it is a display value describing what
  `create`/`spawn-one` observed, and recomputing it on dismissal would make it mean something different
  here than everywhere else it is written.
- **Empty team survives** rather than auto-disbanding (§3.7): a verb that sometimes silently becomes a
  different, more destructive verb is a trap.

## 9. Open — nothing

Both NEEDS-EVIDENCE items are closed:

- **#1 — the close-gate mechanism.** Exact-name match in two places; see §4.1 and amendments (a)/(b).
- **#2 — `partial` and member-count assumptions.** Closed by the Reviewer's investigation (amendment (c)):
  `partial` is display-only, written at `create`/`spawn-one`, read only for status display in
  `lib-config.mjs` / `lib-hier.mjs`, never cross-checked against the live member count. `dismiss`'s
  `{...team}` spread preserves it correctly. §3.4 carries the rule; §6 case 17 pins it.

The verb name and `--also-config` are resolved by Orchestrator decision (amendment (b)). No open questions
remain for the user or the Ultra-Advisor.

## 10. Confidence

High on the CLI shape and reuse boundaries. This is `disband` with a one-element member list: every
helper it needs already exists and is already tested, and the token scoping falls out of the existing hash.

Two residual risks, both discipline rather than design:
- **§4.1.** A tool that ships one commit ahead of *either* gate registration is ungated in the interval,
  and nothing in the build will say so. §6 item 22 exists to catch exactly the body-only fix.
- **§3.5.1.** `--also-config` is the one part of this spec that can leave the system in a state the user
  did not picture. It is warned, reported in the output, and tested — but it is the part to read twice.

No Ultra-Advisor escalation recommended.
