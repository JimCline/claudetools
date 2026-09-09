# 0046 — "dismiss" means close: team lifecycle verbs get their plain-English meaning, and the two surfaces are renamed

Status: **r3, design.** Brief `20260909-123401-1gcs` + user rulings U1–U5
(§0) + GitHub issue #4 folded in. Fixes GitHub issues **#3** and **#4**.
Ships as agent-hierarchy **0.71.0** (after 0.70.0 from spec 0045);
`.claude-plugin/plugin.json:4` and root `.claude-plugin/marketplace.json:19`
bump together. r1 shipped only the four #3 tools and deferred the rename to
a 0047; r2 did the full rename with permanent aliases; **r3 (U5): hard
rename, no aliases — old names are deleted** (§3, §7 exception note).

## 0. The problems and the rulings

**#3**: "dismiss the team" mapped to the tracking-only `roster_dismiss`;
sessions stayed open; nothing at call time said a destructive twin
(`roster_dismiss_close`) existed. Today (`mcp/server.mjs:373-403`,
`:259-285`): `roster_dismiss` = drop one member's row from team.json
(plan/commit); `roster_dismiss_close` = close the session; `roster_disband` =
plan / remove team.json / keep-sessions; `roster_disband_close` = close all.
Destructive twins sit behind plan → `close_token` → `confirm:true` and a
PreToolUse `ask` (`hooks/pretooluse-disband-close-gate.mjs`, matcher
`hooks.json:37`).

**#4** (same incident, second half): after `roster_dismiss --commit` left
`members: []`, every close form failed for every name the user could see
(ListAgents display name `cam423-architect`; `msg_roster` form
`architect@754fffb1`): *"no member named … it has: (none); checked live
peer records too"* (`roster.mjs:2431`). Sessions were live with `pane_id`
in `peers.jsonl`; the user closed them with raw `herdr pane close`. Cause:
the team.json row is the only name → transport path close knows
(`roster.mjs:2415` matches `m.name` only); the peers.jsonl fallback
(`peerFallbackMembers`, `:1457-1466`) does run when no row matches, but it
matches on its own derived `s.name` from `livePeerSlots`, which is none of
the names the user had in hand — and `peers.jsonl` records carry
`role, session_id, pid, pane_id, tab_id, cwd, team` (`sessionstart.mjs:119-138`),
no display name. Nothing lists "live but untracked" sessions anywhere
(`show` lists team.json only; "orphaned" in the code means orchestrator-dead
teams, `:2921-2938`).

User rulings (design targets, not options):

1. *"when the user tells the LLM to dismiss the team, that should go to the
   agent-team command and actually dismiss the team. Not sure we need a
   dismiss team on the roster."* → **dismiss/disband ARE the destructive
   verbs.** No `_close` twin. The plan→token→confirm gate stays on them.
2. Team-lifecycle tools live under `/agent-team` with a **`team_*`** MCP
   prefix; *"roster should have more explicit CRUD ops and agent-team should
   have more user semantics."* → roster = mechanical verbs on the template,
   team = the words a user says.
3. **U1**: tracking-only removal is named `team_untrack`.
4. **U2**: dismiss removes the config row (§2.1, `also_config`).
5. **U3**: full rename in one go — every row of §6 ships in 0046.
6. **U4**: "remove / drop / forget X" on a **live** target **defaults to
   close** (`team_dismiss`); the user says "keep it running" to get
   `team_untrack`. **No AskUserQuestion.** Reverses r1 §5.3.
7. **U5 (r3)**: *"We don't care about anyone else, they can reinstall."*
   → **no aliases.** Old tool names are deleted, not forwarded; tool
   surface stays ~22 (25, §6). Deliberate exception to 0044 §8.3,
   recorded in §7 so nobody re-adds them.

## 1. Design in one paragraph

Every lifecycle tool moves to `team_*`; every template tool becomes one
explicit CRUD verb under `roster_*`; **the old names are removed** (U5 —
an unknown old name gets the router's existing unknown-tool error,
`server.mjs:788-790`). Three tools are new in substance:
**`team_dismiss`** (one member, plan → close), **`team_disband`** (whole
team, plan → close), **`team_untrack`** (forget the record, touch no
session). Close keeps plan → `close_token` → `confirm` and the harness
`ask`, and now **does its own bookkeeping** (drops the row / the file on
success) — the old third `--commit` call goes away. For #4, close tools
**resolve a target through `peers.jsonl` by any identifier the user can
see** (pane id, session id or its 8-char prefix, `role@sid8`, the herdr
agent / ListAgents display name) whenever no team.json row matches, so an
untracked-but-live session is closable from tooling; and `team_list` shows
those sessions as **`untracked_live`** so the orphan is visible before
anyone hunts for it. `team_untrack` refuses a live target unless
`keep_sessions:true` — the clarifying beat for the *tool*; the harness
`ask` on close is the clarifying beat for the *user*. Intent phrases
("dismiss the team", "close the team", "tear down the team" …) join the
SKILL.md description so the existing UserPromptSubmit nudge
(`lib-team-intent.mjs`) routes them for free.

Mechanisms from the brief, ranked: **(a) rename — chosen**, in the user's
direction (user's word keeps user's meaning; mechanical op gets the
mechanical name). **(b) description + skill** — support only; descriptions
already said "Does not close sessions" (`server.mjs:375`) and the agent
still picked it. **(c) PreToolUse liveness deny** — loses as a hook (a
second `memberLiveness` pass racing the CLI's; every legitimate
keep-sessions use pays deny + retry); survives as the parameter check
inside `team_untrack`, which dead targets never see (brief's anti-goal).

## 2. Contracts — the three new-in-substance tools

All tools: `cwd` required, optional `team`. One implementation in
`hooks/roster.mjs` (0044 §8.2); `mcp/server.mjs` only maps tool →
subcommand + flags (`:733-769`, `:638-667`).

### 2.1 `team_dismiss` — close ONE member's session

Params: `name` (any form in §2.4), `mode: plan | close` (default plan),
`confirm`, `plan_token`, `allow_global`, `also_config`, `level`.

- **plan** (read-only): today's `roster_dismiss` plan output — member,
  three-valued `live` (spec 0043 §1.6), `close_token`, `team_id`,
  `remaining`, `source: 'team' | 'peers'` — with the target resolved per
  §2.4. `closeToken` (`roster.mjs:1366`, sha256 of `{team_id, ids}` over
  this member's closable set) is untouched; for a peers-resolved target
  `team_id` is the team tag on the peer record or `null`, and the id set is
  the transport id — the token still binds plan to close.
- **close**: today's `roster_dismiss_close` (`:2449-2489`: resync in
  memory, token check, `requireAllowGlobal`, `closeMemberPane`) **plus
  bookkeeping**: on success the team.json row is removed (the rewrite
  `dismiss --commit` does at `:2493-2494`); on failure the row stays and
  the output says so. Output = today's `closed` / `results[]` +
  `untracked: true | false` (`false` also when there was no row — a
  peers-resolved target has nothing to untrack, and `results[].source`
  says `peers`). **U2**: `also_config:true` on a successful close removes
  the roster row via `removeConfigMember` (`:2523-2556`), with the
  ordinal-shift warning unchanged; remains opt-in per 0044 §8.1 (reading of
  U2 flagged in §9).
- Target `live:false` → close mode fails naming `team_untrack` as the
  remedy (today's `:2458` text, new name). No close attempted.
- Target unresolvable → the error lists **both** the team.json names and
  the `untracked_live` sessions (§2.5) with every accepted identifier form
  for each, so the #4 dead-end ("it has: (none)") can no longer occur while
  a live session exists.

### 2.2 `team_disband` — close the whole Team

Params: `mode: plan | close` (default plan), `confirm`, `plan_token`,
`allow_global`.

- **plan**: today's `roster_disband` plan — close list = team.json members
  **∪ live peers attributed to this team** (today's `peerExtras`; a peer is
  attributed by its `team` tag, or — untagged — by `cwd` under this
  checkout, exactly as `peerFallbackMembers` scopes today), `source` per
  entry, resync summary. **An empty `members: []` must not short-circuit
  the plan**: the close list is the union, and the union is non-empty
  whenever a live attributed peer exists (E4: the Implementor confirms why
  #4's `roster_disband_close` failed and pins it with the §8 test).
- **close**: today's `roster_disband_close` (`:2291-2317`) **plus
  bookkeeping**: every team.json member closed → team file removed
  (`clearTeam`, `:2328`); some failed → team.json rewritten minus the ones
  that closed, output `partial: true` with the failures. Peer-only entries
  never affect the file decision. No-team.json path (spec 0040) writes
  nothing.

### 2.3 `team_untrack` — forget the record, touch no session

Params: `name` (team.json derived name only — a peers-resolved target has
no record to forget; such a `name` fails with "not tracked; it is live —
`team_dismiss` closes it") **or** `all: true`; `mode: plan | commit`
(default plan); `keep_sessions`; `also_config`; `level`.

- Equals today's `roster_dismiss mode:commit` (one row) and
  `roster_disband mode:commit | keep-sessions` (whole file) including the
  `also_config` ordinal-shift warning.
- **Live guard (the tool-side clarifying beat):** commit on a target whose
  liveness is `true` or indeterminate (for `all`, any member) **fails**
  unless `keep_sessions: true`; the message names both options
  (`team_dismiss`/`team_disband` closes; `keep_sessions:true` forgets and
  leaves it running). Today's non-fatal warning at `:2505-2508` becomes
  this error; with `keep_sessions:true` it degrades back to the warning.
  Dead targets never see it. **#4 prevention (r3)**: with no aliases and
  no CLI `--commit` forms (§3), `team_untrack` is the *only* way to drop a
  record without closing, so the guard covers every caller; #4's exact
  path (`roster_dismiss --commit` on a live member) no longer exists. The
  guard message also says the record cannot be recovered — untrack is not
  undo — the fact #4's user lacked.
- **Idempotent:** untracking a member not in team.json, or `all` with no
  team file, succeeds with `already_untracked: true` (a skill-driven
  agent that untracks after a close that already dropped the row must not
  see an error).
- `plan` reports what would be removed and each target's liveness.

### 2.4 Target resolution for `team_dismiss` (and `team_move` unchanged)

Order, first match wins; every form case-sensitive as stored:

1. team.json `members[].name` (derived name; today's `:2415`). A **role**
   name that is not a member name keeps today's `:2429` refusal *unless*
   exactly one live peer of that role is attributed to the team, in which
   case it resolves (form 3 below) — one architect, "dismiss the
   architect" is unambiguous.
2. — when 1 fails, over **live** `peers.jsonl` records attributed to the
   team (same scoping as `peerFallbackMembers`) — `pane_id` exact;
   `session_id` exact or unique ≥ 8-char prefix; `role@<session_id prefix>`
   (the `msg_roster` form, `architect@754fffb1`); `livePeerSlots`' own
   `s.name` (today's fallback, kept); and the herdr agent / ListAgents
   display name when the transport can report one (E3).
3. Ambiguous (two live peers match) → fail listing the candidates with all
   their identifiers; never pick.

A peers-resolved member carries `source: 'peers'`, `route: 'peer'`,
`transport_id: pane_id` — the shape `peerFallbackMembers` already returns
(`:1465`), so `closeOne` (`:1481`, reads `name`, `transport_id`, `source`)
needs no change. Resolution lives in one place and is reused by dismiss
plan, dismiss close, and the §2.1 error text.

### 2.5 Orphan visibility — `untracked_live`

`team_list` (renamed `roster_teams`, §6.1) output gains, per team, an
`untracked_live: [...]` array — live peers attributed to that team with no
team.json row — and a top-level `untracked_live` for live peers attributed
to no team; each entry carries `role`, `pane_id`, `session_id`, `pid`,
`cwd`, and the `role@sid8` form. `team_reap` reports the same list in its
output (`untracked_live`, no action taken — reap's contract stays
orchestrator-dead teams only). The `/agent-team` skill's status/`list`
guidance says: an `untracked_live` entry is closed with `team_dismiss
<pane_id | role@sid8>` or `team_disband`. Nothing else lists it.

### 2.6 Everything else keeps its contract

Every other tool in §6 renames only: same params, same output, same
CLI subcommand. `roster_show` and `msg_*` are untouched.

## 3. Migration — hard rename, no aliases (U5, r3)

Old MCP names are **removed from `TOOLS` and the router**. Mapping (for
the reference sweep, not for code):

| old | new |
|---|---|
| `roster_dismiss` mode plan / `roster_dismiss_close` | `team_dismiss` mode plan / close |
| `roster_dismiss` mode commit | `team_untrack` name, commit (+ `keep_sessions:true` if live) |
| `roster_disband` mode plan / `roster_disband_close` | `team_disband` mode plan / close |
| `roster_disband` mode commit \| keep-sessions | `team_untrack` all, commit (+ `keep_sessions:true` if live) |
| `roster_create / spawn_one / spawn_ad_hoc / adopt / move / resync / reap / history / layout_splits` | same-named `team_*` |
| `roster_teams` | `team_list` |
| `roster_member` action init / add / edit / remove | `roster_init` / `roster_add` / `roster_edit` / `roster_remove` |
| `roster_config` target layout / alias | `roster_layout` / `roster_alias` |

CLI (`hooks/roster.mjs`): subcommand spellings for the unchanged verbs
stay. **`dismiss` and `disband` lose their `--commit` / `--keep-sessions`
modes** — they are plan | close only, matching the MCP contract; one new
subcommand **`untrack <name>|--all [--plan|--commit] [--keep-sessions]
[--also-config] [--level L]`** is the only tracking-only path. `dismiss`
accepts the §2.4 name forms. `teams` gains `untracked_live`. `member
<action>` / `config <target>` CLI forms may stay as-is (the CLI is not the
surface the user is renaming; the Implementor keeps whichever spelling
`roster.mjs` already routes and updates the usage header `:8-60`).
Slash-command verbs (`/agent-team dismiss`, `/agent-roster add`) unchanged.

An old MCP name in a call → the existing unknown-tool error
(`server.mjs:788-790`); no special message. Users of other installs
reinstall (user's words).

## 4. Gates and hooks

- **Close gate** (`hooks.json:37`, `pretooluse-disband-close-gate.mjs`):
  matcher = **`team_dismiss` | `team_disband` only**, both prefixes
  (`mcp__plugin_ah_ah__`, `mcp__ah__`); old names dropped. Emit `ask` only
  when `tool_input.mode === "close"` (E1); plan passes. `ask` text
  unchanged.
- **Skill gate** (`hooks.json:46`, `pretooluse-roster-skill-gate.mjs:38`
  `VERBS`): matcher and `VERBS` = the **new** lifecycle names only
  (`team_create, team_spawn_one, team_spawn_ad_hoc, team_adopt, team_move,
  team_dismiss, team_disband, team_untrack`). Once-per-session deny
  unchanged.
- **Intent phrases** (`skills/agent-team/SKILL.md:3` description, read by
  `lib-team-intent.mjs`; ≥ 3 words each per
  `test-roster-skill-gate.sh:123-128`): add "dismiss the team", "close the
  team", "close the sessions", "shut down the team", "tear down the team",
  "end the team", "dismiss the architect", "remove the architect". Existing
  phrases stay.
- No new hook.

## 5. Skill text — `skills/agent-team/SKILL.md` (and `skills/agent-roster/SKILL.md`)

Rewrite the command-surface entries (`agent-team/SKILL.md:66-79`) and the
`## disband` section (`:403-470`) to the new contract; every `roster_*`
lifecycle name in either skill becomes its `team_*` name and every
`roster_member`/`roster_config` mention becomes the CRUD verb. Required
content (wording is the Implementor's; every point must be present):

1. **Verb meaning, first line of each:** dismiss = close that member's
   session; disband = close every member's session. Both drop the record
   after a successful close. Neither has a non-destructive mode other than
   `plan`.
2. **Flow:** `mode: plan` → show the user the close list → `mode: close`
   with `confirm:true` and the token → the harness asks once → report
   `closed` / `untracked`. Two calls; never `team_untrack` after a close.
3. **Word → tool table:** dismiss / close / end / tear down / shut down /
   kill / **remove / drop / forget** (a member or the team) →
   `team_dismiss` / `team_disband`. **U4:** on a live target these all
   close; the only route to `team_untrack` is the user saying "keep it
   running" / "leave the session up" / "just stop tracking" — then
   `team_untrack … keep_sessions:true`, and say in one line that the
   session stays open and the record is gone for good. No question either
   way; the harness `ask` on close is the confirmation.
4. **Dead member:** plan reports `live:false` → `team_untrack`, one line to
   the user, no question.
5. **Untracked but live** (`team_list` → `untracked_live`, or a dismiss
   error listing them): close by `pane_id` or `role@sid8` with
   `team_dismiss`; never `herdr pane close` by hand.
6. **Before `create` with a team already present** (`:173`): `team_untrack
   all keep_sessions:true` when the user wants old sessions kept,
   `team_disband` when not — this is the one place to ask which, once.
7. `--also-config` paragraph stays (0044 §8.1); note it now applies to
   `team_dismiss` too (U2).
8. Remove every `roster_dismiss*` / `roster_disband*` / `_close` mention
   from both skills, `commands/agent-team.md` (argument-hint gains
   `untrack`), `commands/agent-roster.md:11-13`, `CONTEXT.md:34`,
   `README.md:366`, `docs/mcp-tools.md` (20 refs — the CLI-fallback table
   must list the new names with the old as aliases), `docs/troubleshooting.md`
   (3). Spec files are history and stay.

## 6. Rename map — all in 0046 (U3)

### 6.1 `/agent-team` — MCP `team_*`

| today (`server.mjs` line) | new | refs |
|---|---|---|
| `roster_dismiss` :373 + `roster_dismiss_close` :389 | `team_dismiss` (+ `team_untrack`) | 61 + 40 |
| `roster_disband` :259 + `roster_disband_close` :272 | `team_disband` (+ `team_untrack`) | 109 + 70 |
| `roster_create` :196 | `team_create` | 51 |
| `roster_spawn_one` :332 | `team_spawn_one` | 40 |
| `roster_spawn_ad_hoc` :349 | `team_spawn_ad_hoc` | 12 |
| `roster_adopt` :216 | `team_adopt` | 19 |
| `roster_move` :301 | `team_move` | 23 |
| `roster_resync` :287 | `team_resync` | 16 |
| `roster_reap` :229 | `team_reap` (+ `untracked_live`) | 14 |
| `roster_teams` :144 | `team_list` (+ `untracked_live`) | 27 |
| `roster_history` :321 | `team_history` | 15 |
| `roster_layout_splits` :241 | `team_layout_splits` | 12 |

### 6.2 `/agent-roster` — MCP `roster_*`, explicit CRUD

| today | new | refs |
|---|---|---|
| `roster_member` :156 `{action: init\|add\|edit\|remove}` | `roster_init`, `roster_add`, `roster_edit`, `roster_remove` (each: the action's params only, `action` gone) | 89 |
| `roster_config` :179 `{target: layout\|alias}` | `roster_layout`, `roster_alias` (each: that target's params, `target` gone) | 38 |
| `roster_show` :131 | unchanged | — |
| `msg_*` | unchanged | — |

Tool inventory: 22 today (17 `roster_*` + 5 `msg_*`) → **25** (13
`team_*` + 7 `roster_*` incl. `roster_show` + 5 `msg_*`). No old name
survives. Slash-command verbs already read correctly (`/agent-roster add`,
`/agent-team dismiss`) and do not change; `roster.mjs` stays the one
implementation. The MCP server instructions text (`roster_show` reference)
is unchanged.

## 7. Files to change

- `mcp/server.mjs`: 19 new `TOOLS` entries + router cases; the 16
  renamed/removed old entries (`:144-403`, all but `roster_show`) and their
  router cases deleted. Net 25 tools.
- `hooks/roster.mjs`: `untrack` subcommand; bookkeeping after close in both
  close branches; live guard + idempotency; §2.4 resolver (one function,
  reused); `teams`/`reap` `untracked_live`; `dismiss`/`disband` `--commit`
  / `--keep-sessions` branches removed; usage header.
- `hooks/hooks.json:37`, `:46`; `hooks/pretooluse-disband-close-gate.mjs`
  mode check; `hooks/pretooluse-roster-skill-gate.mjs:38` `VERBS`.
- Skills, commands, docs per §5.8 — plus `README.md` / getting-started and
  `CONTEXT.md` wherever they name a tool or the `--commit` forms.
  `tests/*.sh` (27 files, 169 `roster_` lines; `test-mcp-server.sh` 57,
  `test-disband-close-gate.sh` 22, `test-roster-resync.sh` 12,
  `test-roster-spawn-one.sh` 12, `test-roster-surface-split.sh` 10,
  `test-roster-multi-team.sh` 9, `test-roster-dismiss.sh` 8,
  `test-roster-skill-gate.sh` 6, rest ≤4): the exact-set assertion
  (`test-mcp-server.sh:116-121`) becomes the 25-name set; every reference
  switches to the new name; tests of `dismiss --commit` / `disband
  --commit|--keep-sessions` become `untrack` tests.
- `.claude-plugin/plugin.json:4` → 0.71.0; root
  `.claude-plugin/marketplace.json:19`.

**Exception to 0044 §8.3 (forward-permanently) — deliberate, U5.** This
is a single-user plugin; a 22-entry alias surface would cost context in
every session forever, and the compat value is nil ("they can reinstall").
Old names are deleted, not aliased. Do not re-add them. 0044 §8.3 remains
the rule for *future* renames unless the user rules otherwise again.

Must NOT change: `closeToken` inputs (`roster.mjs:1366-1369`; comment at
`:2470-2474`); the `ask` text; `resyncMembers`, `closeOne`,
`closeMemberPane`, `clearTeam`, `writeTeam`, `peerFallbackMembers`
signatures; spec 0040 no-team.json outputs; `roster_show`; `msg_*`; the
peers.jsonl record shape (`sessionstart.mjs:119-138`) — resolution reads
it, never widens it.

## 8. Verification — tests that fail without the change

Extend `tests/test-mcp-server.sh`, `test-roster-dismiss.sh`,
`test-roster-disband-close.sh`, `test-disband-close-gate.sh`,
`test-roster-skill-gate.sh`, `test-roster-surface-split.sh`; new
`tests/test-team-untrack.sh` and `tests/test-team-untracked-live.sh`
(#4). Fake transport as the existing suites use.

1. `tools/list` is exactly the 25-name set (§6) and contains no
   `roster_dismiss*`, `roster_disband*`, `roster_teams`, `roster_member`,
   `roster_config`, or lifecycle `roster_*` name — fails on HEAD.
2. `team_dismiss` close on a live fake member: pane closed AND row gone,
   `untracked:true`; forced close failure → row kept, `untracked:false`.
3. `team_disband` close: all closed → team file gone; one failure → file
   rewritten minus the closed, `partial:true`.
4. `team_untrack` live member without `keep_sessions` → non-zero, message
   names `team_dismiss` and `keep_sessions`; with it → row removed, no close
   recorded. Dead member → removed, no guard. Missing → `already_untracked`.
5. Removal: a `tools/call` with any old name → the unknown-tool error;
   CLI `dismiss --commit` and `disband --commit` / `--keep-sessions` →
   usage error naming `untrack`. `roster_add` / `roster_alias` etc. reject
   a stray `action` / `target` param. Renamed tools' outputs equal HEAD's
   for the old name (byte-for-byte on the fake transport) except the
   additive fields (`untracked`, `partial`, `already_untracked`,
   `untracked_live`).
6. **#4 fails-without**: `team_untrack <name> keep_sessions:true` on a live
   fake member (the incident's `roster_dismiss --commit` path, now this),
   then `team_dismiss` plan+close by (a) `pane_id`, (b) `role@sid8`, (c)
   session-id prefix, (d) `s.name` → each closes; HEAD fails "no member
   named". `team_disband` close after `members: []` with one live attributed
   peer → closes it (E4). `team_list` shows the member under
   `untracked_live` before the close and not after. Unresolvable name →
   error lists the `untracked_live` entries with their id forms; ambiguous
   prefix → error lists both candidates, closes nothing.
7. Close gate: `team_dismiss` plan → pass; close → `ask` (existing text);
   `roster_dismiss_close` → `ask`. Matcher near-miss test extended to the
   new names, both prefixes.
8. Skill gate denies each of the eight lifecycle verbs once per session;
   the matcher near-miss test asserts no `roster_*` name is in either
   matcher.
9. Intent: "dismiss the team", "close the team", "remove the architect"
   inject the skill line; ≥3-words assertion passes; phrase list equals
   SKILL.md's.
10. Whole `agent-hierarchy/tests` suite green; task-gopher and
    comment-discipline suites untouched and green.

## 9. Decisions

Made: destructive path = the user's verb; tracking-only = `team_untrack`
(two real uses: member died externally; pre-`create` keep-sessions,
`SKILL.md:459`; `reap` covers neither). Bookkeeping after close. Live guard
as a parameter, not a hook. #4 recovery = resolution by any visible
identifier + `untracked_live` on `team_list` and `team_reap` (not
`roster_show` — that is the template surface). Full rename in one release
(U3). No ask on remove/drop/forget (U4). No aliases (U5, r3).

Ruled (r3): **U2** = `also_config` on `team_dismiss`, opt-in, as written.
**U5** = no aliases; §7 exception note.

Refused: a PreToolUse liveness hook; a "dismiss the team?" question for
close verbs (the harness `ask` is one); deleting tracking-only; changing
slash-command verb names; a special "renamed to X" error for old tool
names (the reinstall is the user's answer); widening the peers.jsonl
record to carry a display name (resolution reads what is there; E3 decides
whether the transport can supply the display name at resolve time).

## 10. NEEDS-EVIDENCE

- **E1** — PreToolUse payload for an MCP tool carries `tool_input.mode` as
  a string (the close gate already reads `tool_input` at `:55-56`; expected
  yes). If not: new-name gate always `ask` — safe, noisier.
- **E2** — the fake transport in `test-roster-disband-close.sh` can fail
  one member's close (needed for §8.3); else add the knob to the stub.
- **E3** — how `livePeerSlots` derives `s.name`, and which of #4's two
  forms (`cam423-architect`, `architect@754fffb1`) it would have produced;
  whether the herdr transport can report the agent/display name for a
  `pane_id` at resolve time (`herdr agent get`, `:583-602`). Decides
  whether §2.4's "display name" form is resolvable or documented as
  "use `pane_id` / `role@sid8`".
- **E4** — why `roster_disband_close` failed in #4 with `members: []` and a
  live attributed peer: empty-members short-circuit, peer not attributed
  (no `team` tag and `teamArg` scoping), or token mismatch. The answer
  fixes §2.2's plan-list rule or the attribution rule; the §8.6 test pins
  whichever it is.

## 11. What the full rename makes risky

- **No compat at all (U5)**: any session, skill, memory note, or Engram
  fact that names an old tool is wrong the moment 0.71.0 installs. Inside
  this repo the sweep is §7; outside it (other checkouts, `~/.claude`
  memory, the UPS nudge text if it names tools) the user reinstalls and
  re-learns — by ruling. The Implementor greps the *whole* claudetools
  repo for `roster_` and for `--commit`/`keep-sessions` in prose, not just
  `agent-hierarchy/`.
- **Reference churn**: grep -c lines — tests 169 across 27 files, skills
  46 (`agent-team` 31, `agent-roster` 15), `docs/mcp-tools.md` 20,
  `docs/troubleshooting.md` 3, plus `server.mjs`, both hook scripts,
  `hooks.json`, commands, README/getting-started, CONTEXT.md (CLI-verb
  refs not counted by `roster_`). A missed test rename now fails loudly
  (unknown tool) rather than silently — that is the upside of U5.
- **Two hook matchers** are name-lists in JSON (`hooks.json:37`, `:46`);
  a name missing there is a silent gate bypass (skill gate) or a missing
  `ask` (close gate). §8.7–8.8 cover every name; the near-miss test
  enumerates the 25 and asserts no `roster_*` lifecycle name remains.
- **`roster_member`/`roster_config` split** changes schemas (the
  discriminator param disappears). The new tools must not accept a stray
  `action`/`target` silently — reject unknown params as the server does
  today.
- **CLI `dismiss --commit` removal** breaks any shell alias or note the
  user has; the usage error names `untrack` so the fix is one word.
- **Skill-name collision**: `team_list` vs `roster_show` — both "show me
  the state"; the skill text must say list = live teams, show = template.
- **Docs drift**: `docs/mcp-tools.md` is the CLI-fallback contract the
  Architect/Reviewer roles read when MCP is absent; a stale row there
  misroutes a fallback. Update it in the same commit.

## 12. Confidence

High on the #3 shape and the rename mechanics (every step reuses an
existing function; no alias layer to get wrong). Medium on #4 recovery until
E3/E4 — the resolver's forms are right by construction, but whether #4's
*specific* failure was name-form or attribution is unmeasured, and the
§8.6 test must reproduce the incident's exact path (`roster_dismiss
--commit` then close by display name) before it is believed. Not
recommending Ultra-Advisor: the destructive gate is unchanged; new
behaviour is additive or behind an explicit parameter; U5 is ruled.
