# 0046 — "dismiss" means close: team lifecycle verbs get their plain-English meaning, and the two surfaces are renamed

Status: **r4, design.** Brief `20260909-123401-1gcs` + user rulings U1–U5
(§0) + GitHub issue #4 folded in. Fixes GitHub issues **#3** and **#4**.
**r4** (brief `20260909-162541-psdl`): E3/E4 answered by the Implementor's
code read — both overturned §2's assumptions about `livePeerSlots`
(`lib-hier.mjs:735-745`); §0 cause, §2.2 attribution, §2.4 resolver, §2.5,
§7 must-not-change, §8.3/§8.6/§8.7, §10 rewritten against what the code
and `peers.jsonl` actually carry; r2 alias residue (§5.8, §8.7) removed.
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
in `peers.jsonl`; the user closed them with raw `herdr pane close`. Cause
(r4, from the E3/E4 code read): the team.json row is the only name →
transport path close knows (`roster.mjs:2415` matches `m.name` only); the
peers.jsonl fallback (`peerFallbackMembers`, `:1457-1466` →
`livePeerSlots(dir, teamArg || null)`, `lib-hier.mjs:735-745`) does run —
`members: []` does **not** short-circuit; disband's close set is already
`closableMembers([...healedMembers, ...peerExtras(dir, team)])` (`:2313`)
— but `livePeerSlots` drops the live peers two independent ways:

- `:738` skips every record with no `name`. The rows `sessionstart.mjs:116-131`
  writes are `{status:"up", role, session_id, pid, ppid, cwd, pane_id,
  tab_id, workspace_id, team?}` — **never `name`** (deliberate, `:127-129`:
  `rosterKey = name || session_id`, and a name would merge the row with
  posttooluse-roster's differently-keyed rows). The only named rows are
  posttooluse-roster's `seen`/`briefed` rows (`:68`, `:76`), whose `name`
  is whatever string the orchestrator SendMessage'd — so a registered peer
  that was never briefed by name is invisible to the fallback, always.
- `:741` keeps a record only when its effective team `=== team`, and with
  no `--team` the scope is `null`; a peer tagged with the team it belongs
  to (`rec.team = resolved.teamName`, `sessionstart.mjs:130`) is filtered
  *out*. Only untagged peers survive a bare disband/dismiss fallback — the
  inverse of what #4 needed.

`peers.jsonl` carries no display name; `herdr agent get` (`roster.mjs:583-600`)
is keyed by name, but `herdr agent list` (`queryHerdrTopology`, `:688-692`)
returns `{name, pane_id, …}` for every live herdr agent — the display name
→ `pane_id` map exists, it is just not consulted. Nothing lists "live but
untracked" sessions anywhere (`show` lists team.json only; "orphaned" in
the code means orchestrator-dead teams, `:2921-2938`).

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
  **∪ live peers attributed to this team** (today's `peerExtras` union at
  `:2313`, kept), `source` per entry, resync summary. **Attribution rule
  (r4, replaces "exactly as `peerFallbackMembers` scopes today" — today's
  scoping is the #4 bug, §0):** let T be the team being disbanded (the
  team.json `readTeam` returned at the resolved scope, named or default).
  A live, not-`down` `peers.jsonl` record — **named or nameless** — is
  attributed to T iff its effective team **equals T's `teamName`**, where
  the default-scope team's `teamName` is `null` (`lib-roster.mjs:384`,
  `resolveSessionTeam` `:443-456`) — the same value `sessionstart.mjs:130`
  tags, so a default-team peer is *untagged* and a named-team peer carries
  that team's name. Effective team = team.json membership when the
  record's name has one, else its own `team` tag, exactly as `:739-741`
  computes today. A record whose effective team is a *different* team is
  excluded — disbanding named team T never closes default-team or sibling
  peers, and a bare default-team disband never closes a named team's
  (the isolation rule `roster()` states, `lib-hier.mjs:747-760`). In the
  no-team.json branch (`:2293`, spec 0040 §1.1) the scope is "no-team":
  attributed = untagged records **plus** records whose tag names no team
  file that exists in this checkout (orphans of a removed team — the
  untrack-all-then-disband path); a tag naming an existing team stays
  with that team.
  **What actually changes:** the comparison at `:741` is already this
  rule; the bug is the *scope passed in* — `peerFallbackMembers` passes
  `teamArg || null` (`:1463`, the `--team` flag), not the identity of the
  team the command is operating on (`readTeam(dir, teamFile)`, `:2292` /
  `:2410`). The scope must be **T's `teamName` as resolved for
  `teamFile`** — null for the default file — for every fallback caller
  (`peerExtras` `:1470`, dismiss `:2418`, no-team disband `:2296` with the
  "no-team" scope). The `:1458-1462` comment's fear ("a derived scope
  filters every untagged peer out") holds only when the derived team is
  named, and then excluding untagged (default-team) peers is *correct*;
  replace the comment with this rule. This is the Implementor's (b),
  stated with `null` as the default team's name; (a) "any team in the
  checkout" would close sibling teams on a bare disband; (c) "union of
  null and T" would close default-team peers when disbanding a named T.
  The rule lives in one place and every fallback caller reaches it
  through that one place; the second half of the fix — nameless rows — is
  §2.4's synthesized name.
  **Dedup:** the close set is deduplicated on `transport_id` (`pane_id`),
  falling back to `session_id` — the same session can appear as a nameless
  `up` row and a named `briefed` row (`rosterKey` partitions them) and
  must be closed once.
  **An empty `members: []` never short-circuits**: the union is non-empty
  whenever a live attributed peer exists (E4 resolved, §10; pinned by §8.6).
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
- **Output shape (r4 impl, accepted at review r1):** the two predecessors it
  "equals" had different shapes, so the single-member commit output leads with
  `untracked: true`, not the old `dismissed: true` — `dismiss` now means "closed
  the session", and a caller grepping `dismissed` on this output would read a
  still-live session as gone. It also carries `removed: <name>` alongside the
  existing `member`, `team_id`, `remaining`, `team_empty`, `config`, `store`.

### 2.4 Target resolution for `team_dismiss` (and `team_move` unchanged)

Order, first match wins; every form case-sensitive as stored. (r4:
rewritten against what `peers.jsonl` carries — `sessionstart` rows have
`role, session_id, pid, ppid, cwd, pane_id, tab_id, workspace_id, team?`
and **no `name`**; `seen`/`briefed` rows have `name, role, team` and no
`session_id`/`pane_id`. `livePeerSlots` must stop skipping nameless rows
(`lib-hier.mjs:738`) and must carry `session_id` in each slot, §7.)

1. team.json `members[].name` (derived name; today's `:2415`). A **role**
   name that is not a member name keeps today's `:2429` refusal *unless*
   exactly one live peer of that role is attributed to the team (§2.2
   scope), in which case it resolves — one architect, "dismiss the
   architect" is unambiguous.
2. — when 1 fails, over **live** `peers.jsonl` records attributed to the
   team (§2.2 scope, through the same one place):
   - `pane_id` exact (`sessionstart` rows);
   - `session_id` exact, or a unique prefix of ≥ 8 chars;
   - the **synthesized name `role@<first 8 chars of session_id>`** —
     byte-identical to what `roster()` builds for a nameless record at
     `lib-hier.mjs:786` (`${role}@${session_id.slice(0,8)}`), which is
     the name `team_list` / `msg_roster` print (#4's `architect@754fffb1`).
     Invariant: **every name `team_list` prints for a live peer is
     accepted by `team_dismiss`** — reuse that expression, never a second
     formatter;
   - a `briefed`/`seen` row's `name` (today's `s.name` form, kept —
     matches only peers the orchestrator has addressed by that string);
   - **herdr display name** (#4's `cam423-architect`): when the team's
     transport is herdr (or no team.json and herdr is on PATH), map the
     name → `pane_id` through `queryHerdrTopology()` (`roster.mjs:688-692`,
     `herdr agent list`, the single herdr exec site — spec 0002 §11.3
     forbids a second), then match that `pane_id` as above. Tried last
     because it costs a herdr call; skipped, not failed, when herdr is
     absent or the call fails (`allowFailure`). `herdr agent get` (`:583`)
     is keyed by name and is *not* the path — the Implementor's E3 read
     looked there only.
3. Ambiguous (two live records match — e.g. a session-id prefix shared by
   two rows) → fail listing every candidate with all its identifiers
   (`role@sid8`, `pane_id`, `session_id`, `pid`); never pick. A nameless
   `up` row and a `briefed` row for the same session are one candidate
   when they share `pane_id` (or the briefed row has none) — dedup as
   §2.2.

A peers-resolved member carries `source: 'peers'`, `route: 'peer'`,
`transport_id: pane_id`, `name` (the synthesized or briefed name),
`session_id` — the shape `peerFallbackMembers` returns today (`:1465`)
plus `session_id`, so `closeOne` (`:1481`, reads `name`, `transport_id`,
`source`) needs no change. A resolved record with no `pane_id` keeps
today's `:2439` "no addressable pane" failure. Resolution lives in one
place and is reused by dismiss plan, dismiss close, and the §2.1 error
text (which lists the unresolved target's candidates as `untracked_live`
entries, §2.5).

### 2.5 Orphan visibility — `untracked_live`

`team_list` (renamed `roster_teams`, §6.1) output gains, per team, an
`untracked_live: [...]` array — live peers attributed to that team with no
team.json row (§2.2 attribution) — and a top-level `untracked_live` for
live peers attributed to no existing team; each entry carries `name` (the
§2.4 synthesized `role@sid8`, from the same `lib-hier.mjs:786` expression,
or the briefed name), `role`, `pane_id`, `session_id`, `pid`, `cwd`.
Today's `teams` output (`roster.mjs:2802-2856`: `name, team_id, …,
members, partial, orphaned, misplaced_members, misplaced_unattributed`)
is unchanged otherwise. `team_reap` reports the same list in its
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
   lists the new names only; no alias column, U5), `docs/troubleshooting.md`
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
`closeMemberPane`, `clearTeam`, `writeTeam` signatures; spec 0040
no-team.json outputs; `roster_show`; `msg_*`; the peers.jsonl **record**
shape (`sessionstart.mjs:116-131`) — resolution reads it, never widens it;
`rosterKey` / `latestRoster` partitioning (`lib-hier.mjs:679-691`); the
`roster()` function's output (`:762+`, the `team_list`/status surface —
its synthesized name for nameless records is *reused*, not changed).

**Relaxed in r4 (brief ruling): `livePeerSlots` (`lib-hier.mjs:735-745`)
and `peerFallbackMembers` (`roster.mjs:1457-1466`).** Their RETURN shape
widens — each slot/member also carries `session_id` and, for a nameless
record, `name` = the synthesized `role@…` name `roster()` produces for
that record (§2.4) — and their attribution scoping changes per §2.2. The
`!rec.name` skip at `:738` goes. Signatures may gain a scope argument;
`closeOne` keeps reading only `name`, `transport_id`, `source`, so the
widened shape is additive for it. The peers.jsonl record itself is not
widened — no `name` on `sessionstart` rows (the `:127-129` comment stands).

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
   rewritten minus the closed, `partial:true`. Failure knob = the existing
   `FAKE_HERDR_CLOSE_FAIL_ID=<pane_id>` in the fake herdr
   (`test-roster-disband-close.sh:40-46`; E2 resolved r4); the fixture's
   `$FAKE_HERDR_STATE` agents plus a `peers.jsonl` with one nameless `up`
   row (`pane_id` set, `team` tag = the team's name or absent for the
   default team) so the close set exercises §2.2's union.
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
6. **#4 fails-without** (`tests/test-team-untracked-live.sh`): fixture =
   team.json with one member, `peers.jsonl` with that member's
   `sessionstart`-shaped row — **nameless**: `{status:"up", role, session_id,
   pid (alive: the test's own shell pid), pane_id:"PANE1", cwd}` and the
   team's tag as `sessionstart.mjs:130` would write it (absent/`null` for
   the default team; run the case twice, default team and `--team named`)
   — and `$FAKE_HERDR_STATE` listing `{name:"cam423-architect",
   pane_id:"PANE1"}`. Then `team_untrack <name> keep_sessions:true` (the
   incident's `roster_dismiss --commit` path) leaves `members: []` and the
   row. Then `team_dismiss` plan+close by (a) `pane_id`, (b) `role@sid8`
   built from the fixture's `session_id`, (c) an 8-char session-id prefix,
   (d) the herdr display name `cam423-architect` (fake `herdr agent list`
   read from `$FAKE_HERDR_STATE`), (e) a `briefed` row's name after
   appending one → each closes `PANE1` (invocation log) and reports
   `untracked:true`; HEAD fails "no member named … checked live peer
   records too" (`:2431`) for every form. `team_disband` close on the same
   `members: []` state → closes `PANE1` (E4, both team scopes). `team_list`
   shows the peer under `untracked_live` with `name` equal to the string
   (b) used, before the close and not after. Unresolvable name → error
   lists the `untracked_live` entries with their id forms; two rows sharing
   a prefix → error lists both candidates, closes nothing. Named team T +
   an untagged (default-team) live row → `team_disband --team T` does
   **not** list or close it (isolation).
7. Close gate: `team_dismiss` / `team_disband` plan → pass; close → `ask`
   (existing text). Matcher near-miss test extended to the new names, both
   prefixes; an old `_close` name is *not* in the matcher (it no longer
   exists — asserting `ask` on it was r2 residue, removed r4).
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

Ruled (r4, Architect — no new user decision): **attribution scope** = the
operated-on team's `teamName` (null = default), passed by every fallback
caller in place of `teamArg` (§2.2, Implementor's option (b)). **Nameless
rows** become slots named by `roster()`'s own `role@sid8` expression —
one formatter, so `team_list` output and `team_dismiss` input agree.
**Display name** form stays, resolved via `queryHerdrTopology()`
(`herdr agent list`), herdr transport only. `livePeerSlots` /
`peerFallbackMembers` leave the must-not-change list for return shape and
scope (§7); the peers.jsonl record does not. E1 accepted on the
Implementor's inference (the close gate already reads `tool_input` for
this tool class; `test-disband-close-gate.sh:25`, `:73`) — no live
capture.

Refused: a PreToolUse liveness hook; a "dismiss the team?" question for
close verbs (the harness `ask` is one); deleting tracking-only; changing
slash-command verb names; a special "renamed to X" error for old tool
names (the reinstall is the user's answer); widening the peers.jsonl
record to carry a display name (resolution reads what is there; E3 decides
whether the transport can supply the display name at resolve time).

## 10. NEEDS-EVIDENCE

All four resolved in r4; none open.

- **E1** — accepted by inference (§9): PreToolUse passes the MCP tool's
  argument object through as `tool_input`, so `mode` is present as a
  string. Fallback if a live run ever disagrees: new-name gate always
  `ask` — safe, noisier.
- **E2** — resolved: the fake herdr already has `FAKE_HERDR_CLOSE_FAIL_ID`
  (`test-roster-disband-close.sh:40-46`); §8.3 uses it.
- **E3** — resolved: `livePeerSlots`' `s.name` is only ever a
  `seen`/`briefed` row's SendMessage-target string (`posttooluse-roster.mjs:68`,
  `:76`); `sessionstart` rows have no `name` and were skipped outright
  (`lib-hier.mjs:738`) — neither of #4's forms could match. The display
  name IS resolvable, via `herdr agent list` (`queryHerdrTopology`,
  `roster.mjs:688-692`), not `agent get`. §2.4 rewritten accordingly.
- **E4** — resolved: not a short-circuit and not the token; the peers were
  excluded by `livePeerSlots` (`:738` nameless skip; `:741` scope
  mismatch because `peerFallbackMembers` passes `teamArg`, not the
  operated-on team). §2.2 rewritten; §8.6 pins both, in both team scopes.

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
existing function; no alias layer to get wrong). High on #4 after r4: the
cause is read off two lines of `livePeerSlots`, both fixes reuse existing
expressions (`roster()`'s `role@sid8`, `queryHerdrTopology`), and §8.6
reproduces the incident's exact path in both team scopes. Residual risk:
the scope change touches every fallback caller — the isolation case in
§8.6 (named-team disband must not close default-team peers) is the guard
against over-closing. Not recommending Ultra-Advisor: the destructive gate
is unchanged; new behaviour is additive or behind an explicit parameter;
U5 is ruled.
