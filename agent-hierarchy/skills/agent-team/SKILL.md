---
name: agent-team
description: Stand up, inspect, reshape, or tear down a live Team of agent sessions from the existing agent-hierarchy roster. Use for /agent-team, for "set up my team", "set up a team", "spawn the team", "spawn my team", "spin up the team", "start the team", "spawn the architect", "spawn just the reviewer", "add a peer to the running team", "dismiss a member", "dismiss the architect", "remove the architect", "close that session", "close the sessions", "kick the reviewer", "dismiss the team", "close the team", "disband the team", "disband my team", "shut down the team", "tear down the team", "end the team", "stop tracking a member", "leave it running but forget it", or "untrack the team".
---

# agent-team

A **Team** is a live instance: real sessions, real panes, recorded in a team
file under `.claude/hierarchy/teams/`. It is created FROM the roster, which is
a template. This skill owns every process lifecycle operation — create, spawn,
dismiss, disband, untrack, move, resync, adopt, reap — and writes only the team file.

**It never edits the roster.** Changing WHO belongs on the roster is the
`ah:agent-roster` skill's job (`init`/`add`/`edit`/`remove`/`layout`/`alias`),
and those commands edit a template for FUTURE teams — they do not touch the
one that is running. `roster.mjs` refuses them outright while this session owns
a live team (spec 0044 §1.3). To add a member to the RUNNING team, including
one that diverges from the roster or a role the roster does not define, use
`spawn-ad-hoc` below.

If a roster already exists (inspect it with `node ${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs show --cwd <abs cwd>` — never read `.claude/agent-hierarchy.json` directly, which misses the worktree/main-checkout and global fallback resolution `show` implements) and you just need a live Team
— including at a worktree, which usually inherits the repo's existing roster —
go straight to § Create. You do NOT need to add/edit/remove roster members
first.

Roster levels and their resolution order are documented once, in the
`ah:agent-roster` skill's § Levels; this skill reads the roster through the
same resolution and does not restate it.

Full spec: `docs/specs/0001-agent-roster.md`, with the roster/team split in
`docs/specs/0044-roster-team-scope-split.md`. This document is the operational
surface; if the two disagree, the spec is authoritative and this file has
drifted — say so rather than silently picking one.

## Command surface

Every verb below runs as `node ${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs <verb> … --cwd <abs cwd>`
through the Bash tool — `${CLAUDE_PLUGIN_ROOT}` from this session's `ah CLI root` line (which is
authoritative when the two disagree; with two such lines, the newest wins), the
cwd the absolute repo path. The plugin's own PreToolUse hook allows those calls
without a permission prompt; a `--close` call still prompts, by design. Output is
always JSON. Full verb/flag reference: `docs/cli-tools.md`.

`--team <name>` (spec 0011) lets one repo host more than one Team, each owned
by a distinct orchestrator session: it points every verb that reads or writes
the team file at `teams/<name>.json`, and scopes the derived name-prefix to
`<name>` instead of the repo's alias. **Omitted, a team no longer lands in a
shared `team.json`** — spec 0044 §1.1 defaults the file to
`teams/<repo-alias>.json`, so two orchestrators in one repo do not collide.
A pre-0044 `team.json` keeps working, unmigrated. See § Create for what
happens when a bare `create` collides with someone else's live Team.

- `create [--plan | --commit ... | --spawn --mode <m>]` — see § Create.
- `spawn-one <role> [--member <name>] [--cwd <path>] [--dry-run] [--allow-global]` — stands up ONE missing or dead
  peer FROM THE ROSTER and persists it into the team file, without touching any other member. Prefer this over
  Create when a Team already exists and only one role needs (re)starting — Create refuses to run
  against a live Team. The direct match for "spawn the architect" / "spawn just the reviewer"
  style requests. See § spawn-one.
- `spawn-ad-hoc <role> [--model M] [--effort E] [--kind K] [--route R] [--args '<json>'] [--auto-mode A] [--on-missing O] [--dry-run] [--allow-global]` — stands up ONE member that is **not in the roster**: a divergent
  variant of a roster role, or a role the roster does not define at all. Launches through the same
  path as `spawn-one` and writes **only** the team file — the roster is never touched. This is the
  answer whenever the running team needs a member the roster does not describe; editing the roster
  to get one is the mistake spec 0044 exists to prevent. See § spawn-ad-hoc.
- `dismiss <name> [--plan | --close --confirm --plan-token <tok>] [--also-config]` — **CLOSES ONE MEMBER'S SESSION**
  and drops its row: the inverse of `spawn-one`, and what "dismiss the architect" / "remove that
  member" / "kick the reviewer" mean. The plan form (no `--close`) is read-only and returns a `close_token`;
  `--close` needs `--confirm` and that token, and the harness asks the user once.
  `<name>` accepts anything the user can see for a live session — the derived member name, a
  `pane_id`, a `session_id` or a unique 8+ character prefix of one, the `role@sid8` form
  `teams` prints, or the herdr display name (spec 0046 §2.4). `--also-config` additionally
  removes the row from the roster template and is the one command that crosses into roster
  territory: an explicit, never-inferred opt-in. To forget a record WITHOUT closing anything, that
  is `untrack`, never `dismiss`. See § dismiss.
- `disband [--plan | --close --confirm --plan-token <tok>]` — **CLOSES EVERY MEMBER'S SESSION** and drops the team
  record: what "disband the team" / "close the team" / "tear down the team" mean. The plan form (no `--close`) is
  read-only and returns the close list plus a `close_token`; `--close` needs `--confirm`
  and that token, and the harness asks the user once. The close list is `team.json`'s members
  **plus any live peer attributed to this team** with no row of its own (spec 0046 §2.2). To drop
  the record without closing anything, that is `untrack --all`. See § disband.
- `untrack <name>|--all [--plan|--commit] [--keep-sessions] [--also-config]` — **forgets a tracking record and
  touches no session**: the non-destructive counterpart to `dismiss`/`disband`. Use it only when
  the user says to KEEP the session running ("leave it up", "just stop tracking it"), or when the
  target is already dead. On a live target it REFUSES unless `--keep-sessions`, because forgetting
  a live session leaves it running with nothing naming it, and the record cannot be recovered.
  Untracking something already gone succeeds with `already_untracked: true`. See § untrack.
- `resync [--dry-run]` — re-derives every peer member's herdr pane/tab/workspace location from
  herdr's live topology and rewrites the team file. See § resync / move.
- `move <name> --tab <id> --split right|down | --new-tab [--workspace <id>] | --new-workspace
  [--dry-run] [--allow-global]` — relocates a member's pane via `herdr pane move`, then resyncs its record.
  Needs `--allow-global` whenever the roster resolves at the global level, exactly like `spawn-one`/`create --spawn` (§4.4) —
  `move` relocates a live agent pane, so it gets the same confirm-gate protection. See § resync / move.
- `adopt [--orchestrator-pid <pid>] [--team <name>]` — re-stamps
  `orchestrator.pid` on an ORPHANED team. Recovery only; it refuses to hijack a live team.
- `reap [--commit]` — lists orphaned team records, or removes them with
  `--commit`.
- `teams [--cwd <path>]` — read-only: every team file in this hierarchy dir (default plus every
  named team), with member count, orchestrator pid, whether that pid is alive, and whether it's
  this session's own. Use it to see a stale or a sibling orchestrator's Team before `create`. Also
  reports `misplaced_members` (peers confirmed relocated away from where the Team expects them)
  and `misplaced_unattributed` (a count of misplaced peers this session could not safely attribute
  to a specific member) — see § Relocation. Each row also carries `untracked_live`: live peers
  attributed to that team with no `team.json` row, plus a top-level `untracked_live` for peers
  attributed to no team at all (spec 0046 §2.5). An `untracked_live` entry is closed with
  `dismiss <pane_id | role@sid8>` or `disband` — nothing else lists it.
- `history [--json]` — recent team-history entries, the input to
  `create --from`. See § Create.
- `checkin [--team <T>] [--cwd <path>]` — re-registers the *current*
  session's cwd. Spec 0036 §3.3. See § Relocation.
- `layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>] [--next|--apply …]` — performs
  the herdr layout phase. Used by § Create phase 3a. Not a user-facing command.
- `next-split --mode <m> --pane-count <n> --self <id> --created <json> --geometry <json>` — the pure
  decision function, exposed for testing. The skill does not call it; `layout-splits` does. No
  tool wraps it — it is unreachable from the skill, so it never forces a Bash fallback; tests keep
  calling the CLI directly.

Roles: `architect`, `implementor`, `reviewer`, `task-runner`, `ultra-advisor`.
`orchestrator` is rejected by the CLI — the Orchestrator is whatever session
runs `create`, never a team member.

## Dispatching to a `route: pane` member

A non-Claude agent runs no Claude hooks, registers no name with the Claude
CLI, and appears in no `ListAgents` listing — so **SendMessage cannot reach
it**, and `peers.jsonl` will never show it. Drive it through Herdr instead,
addressed by the same derived name the roster already uses:

| need | command |
|---|---|
| send work | `herdr agent prompt <name> "<brief>" --wait --timeout <ms>` |
| wait for a state | `herdr agent wait <name> [--until blocked] --timeout <ms>` |
| read output | `herdr agent read <name> --source recent-unwrapped --lines <n>` |
| answer a dialog | `herdr agent send-keys <name> <key>` |
| is it there? | `herdr agent get <name>` |
| tear down | `herdr pane close <id>` (there is no `herdr agent stop`) |

Three rules that are easy to get wrong:

1. **The prompt must be self-contained.** A bare `[hierarchy-msg <path>]`
   token means nothing to a codex or pi agent — it has no idea what this
   repo's conventions are. Either inline the brief, or spell out: read this
   absolute path, write your report to *this* absolute path, in this shape.
2. **Report back by file, not by screen-scrape.** Create the response file
   yourself up front with `msg.mjs new --type response` and hand the agent its
   absolute path. `herdr agent read` is the diagnostic channel, not the
   primary one — a terminal scrape is lossy, wrap-dependent, and truncates.
3. **Live is not ready.** `herdr agent get` reports both. An agent sitting on
   a startup prompt is live (never start a second under the same name) but not
   promptable. If Herdr cannot answer at all, that is *indeterminate*, not
   dead — `spawn-one` refuses rather than starting a duplicate.

## Create

`create [auto|manual]` (default `auto`) instantiates the resolved roster as a
live Team, verified via check-in. `roster.mjs create` only ever does file
I/O; spawning sessions and calling `ListAgents` are things only this skill's
running session can do — drive the sequence yourself:

**Reuse a recent team (spec 0015).** Before planning a Team from the roster
files, offer to reuse a recent one: run `roster.mjs history --json`, and if it returns any entries, present them via
**AskUserQuestion** (label, role list, active/idle, last-used) alongside a
"start fresh from the roster" option. If the user picks an entry, run
`roster.mjs create --from <id> --commit --spawn` (its own id, not the alias)
in place of the roster-driven plan below — same downstream steps (layout
confirmation, spawn, check-in) apply unchanged. This capability is skill-only:
recreating a Team still needs 0009's confirm gates, which only fire on the
skill path.

0. **Confirm the layout.** Read the roster's `layout` (via `roster.mjs show`;
   it is `auto` unless set). Ask the user to confirm it for this Team with
   AskUserQuestion, marking the stored value "(current default)": `auto` —
   columns for 1-2 members, grid beyond; `columns` — one vertical column per
   member; `grid` — balanced quadrants. **Always ask, every `create`** — a
   persisted default is not a licence to apply it silently. If the user picks
   something other than the stored value, ask once whether to make it the new
   default, and only if yes run `roster.mjs layout --layout <mode>`. Never
   persist a divergent choice without asking. This step applies to `auto` and
   `manual` alike. Skip it entirely when the transport is not `herdr`.
1. **Plan.** Run `roster.mjs create --plan`. It resolves the roster, refuses
   if a live Team already exists (tell the user to `disband` first), clears
   an already-stale one automatically, detects the transport (`herdr` if
   `HERDR_ENV=1`, else `tmux` if a tmux server is reachable, else
   `terminal`), and returns each member's derived name, role, model,
   effort, route, and — for peer-routed members — a `spawn` shape (`layout`
   and `launch` command lists for the detected transport, plus how to thread
   the target id from one to the other). If it errors because no roster
   resolves, hand off to § Init.

   **First-create naming confirmation (spec 0011 §5.3.1-§5.3.3, amendment
   (c)).** Before the very first `create` in a fresh repo (no existing
   `team.json` anywhere under this hierarchy dir), surface the repo-derived
   candidate — the prefix `roster.mjs alias` (read-only) reports, itself the
   repo basename or an existing 0010 alias — via **AskUserQuestion**, before
   running `create --plan`. Offer:
   - **Accept `<candidate>` (Recommended)** — proceed with `create` exactly
     as below. Nothing is written that isn't written today; this is
     byte-identical to not asking at all.
   - **Use a different name** — run `roster.mjs alias --set <name>` first,
     then proceed with `create`. This is 0010's existing alias verb,
     unchanged, and the override **persists for the repo** (config-level,
     not a one-off for this session) — say so when offering it.

   `roster.mjs create` itself never prompts, refuses, or reads stdin for
   this — it runs the same in tests, CI, and scripts either way; asking is
   entirely this skill's job, done once, here, before the first `create`. A
   repo that already has a live default Team is past this trigger — do not
   ask again; renaming later is `alias --set`, offered only if the user asks.

   **Second-Team collision (spec 0011 §5.3).** A bare `create` (no `--team`)
   can fail because a *different*, live orchestrator already owns the default
   Team here — the CLI cannot read stdin to ask, so it refuses and hands back
   the live Team's name and pid plus an auto-derived candidate team name. Do
   not retry with `--team <candidate>` on your own judgment: surface it to the
   user with **AskUserQuestion**, offering the candidate as the first option
   ("Start a second Team named `<candidate>`") and free-text override as the
   second ("Use a different name"). Re-run `create --plan --team <name>` (the
   accepted or overridden name) only after the user answers — the candidate
   never applies unconfirmed. Every subsequent step (`--spawn`, `--commit`,
   `spawn-one`, `disband`, `resync`, `move`, `msg.mjs new`, `msg.mjs list`)
   then needs that same `--team <name>` to keep operating on this Team
   instead of the default one. `roster.mjs` subcommands require the flag
   explicitly. `msg.mjs new`/`msg.mjs list` also auto-resolve the active team
   (spec 0011 §4.4 rung 3) when run from this Team's own orchestrator process
   — `CLAUDE_PID`, `pidAlive`-guarded, matched against the Team's recorded
   `orchestrator.pid` — but pass `--team <name>` explicitly whenever you are
   not certain that rung will fire (e.g. tooling running outside the
   orchestrator's own process).
2. **`manual` mode**: before each spawn, show the intended placement (name,
   role, transport) and let the user override it (different pane, skip it,
   change the name) before proceeding. `auto` mode spawns straight through.

   `--spawn` only launches the panes — it writes nothing; the Team does not
   exist until the follow-up `create --commit --verified <json> --transport
   <t> --roster-level <L>` call persists `team.json`, and until then
   `resync`, `move`, and `disband` cannot see the members at all.
3. **Spawn.**

   **`auto` mode:** run one command:

       roster.mjs create --spawn --mode <layout_plan.mode> [--roster-level <L>] --cwd <repo root>

   It resolves the roster, runs the layout phase, asserts one distinct
   non-empty target id per peer-routed member before launching anything, then
   launches every peer-routed member's `agent start`/`send-keys` concurrently
   (herdr retries a single `pane_not_available`-class failure once, in-process;
   tmux and terminal never retry). It returns one JSON result: `level`,
   `transport`, and `members[]` — each entry carries `role`, `name`, `kind`,
   `args`, `model`, `route`, `autoMode`, `transport_id`, and `launch_status`
   (`ready`|`dispatched`|`blocked-at-startup`|`failed`; `null` for
   subagent-routed members), plus `error` when `failed`. `blocked-at-startup`
   is a **success**, not a failure: the agent is live and queryable but is
   sitting on its own first-run prompt (a non-Claude kind's "do you trust this
   directory?" gate). Resolve it deliberately with `herdr agent read <name>`
   then `herdr agent send-keys <name> <key>` — nothing answers it for you, by
   design. `partial: true` iff any peer-routed member's
   `launch_status` is `failed` — a `dispatched` member (tmux only) is not
   partial, see step 4. Skip straight to step 4 with this `members[]` — do not
   recompute placements or drive `layout-splits`/`layout` commands yourself in
   `auto` mode.

   **`manual` mode:** spawn every peer-routed member in two batched phases
   yourself, exactly as below. Do not run one member's full sequence before
   starting the next — that serializes an `agent start` wait per member.

   **3a — Layout.** For the `herdr` transport, `spawn.layout` is empty and the
   plan carries a top-level `layout_plan`. Run **one** command:

       roster.mjs layout-splits --mode <layout_plan.mode> --pane-count <layout_plan.pane_count> --cwd <repo root>

   It inspects the live geometry, computes every decision, and performs every
   split itself. Read `panes` from its JSON — the new pane ids, in creation
   order.

   - **exit 0** — `complete: true`, you have all `pane_count` ids.
   - **exit 3** — partial. `panes` holds the ids that *did* get created and
     they are real: use them. `failed_at` and `error` say which split failed
     and why, and `attempted` carries the decision it was about to run. Retry
     that one split with `layout-splits --apply --target … --direction …`; if
     it fails again, carry the members that have no pane into step 5's
     partial handling. **Do not discard the panes you already have** — they
     cost real work and their members can still be launched.
   - **exit 2** — nothing was done; the message says why. No panes were
     created; treat the layout phase as failed and stop before 3b.

   **Do not drive the split loop yourself, and do not compute targets or
   directions yourself.** `layout-splits` owns both. The `layout_plan`
   command templates in the plan document the contract and are the fallback
   if `layout-splits` is unavailable; they are not a second way to do this.

   **Your own pane is one of the panes being laid out**, and may be split
   more than once. That is correct; do not "protect" it.

   In `manual` mode, drive it one iteration at a time with `--next` /
   `--apply` — see § Create manual-mode layout below.

   For `tmux`, phase 3a is unchanged from 0003: issue every member's
   `spawn.layout` commands **in a single message**, one tool call per member,
   so they run concurrently. Extract each target id using its
   `target_source`: `kind: "json"` means read the given path out of the JSON
   response; `kind: "stdout"` means take stdout and trim it.

   For `terminal`, there is no layout phase.

   **Assert before continuing:** you must hold one non-empty target id per
   peer-routed member — for herdr, exactly `layout_plan.pane_count` distinct
   pane ids, minus any that failed after a retry or were deliberately skipped
   in `manual` mode; for tmux, one per member with a `layout`. If a tmux
   target is missing, empty, or duplicated, re-run that member's `layout`
   commands **one at a time**; if a member still yields no target, treat it
   as a member that did not come up and carry it into step 5's partial
   handling.

   Assign the pane/target ids to peer-routed members in plan order, then
   continue to 3b unchanged.

   `layout-splits` removes the model-turn cost that made the serial herdr
   loop expensive in practice: the whole loop now runs inside a single tool
   call instead of one round trip per inspect/decide/split step. All of
   0003's real saving — the batched `launch` phase, `N × ready_wait`
   collapsing to `max(ready_wait)` — is untouched.

   If any peer-routed member's `auto_mode` is `bypassPermissions`, say once
   before launching that it can leave that session stuck at a startup
   confirmation screen instead of ready, and suggest `auto` instead.

   **3b — Launch.** Substitute each member's target id for its
   `target_placeholder` inside its `launch` commands, then issue every member's
   `launch` **in a single message**, one tool call per member. Members with
   `target_placeholder: null` need no substitution.

   If a launch reports that the pane is not available or not at a prompt, retry
   that one member's launch once before treating it as failed — the shell may not
   have reached its prompt yet.

   Subagent-routed members are never spawned here — they stay ordinary Agent-tool
   dispatches, recorded in the Team with `name`/`ref`/`transport_id` null.

   The `manual`-mode rule in step 2 is unchanged and still applies: in `manual`,
   show the intended placement and allow an override **before** phase 3a, per
   member. Manual mode may present all members' placements at once; it must not
   be silently converted into a per-member pause between 3a and 3b.
4. **Check in.** Call `ListAgents` and match each spawned member's derived
   name. **Poll every 2 seconds, give up at 60 seconds** — fixed interval,
   not backoff; this is not configurable. A member `--spawn` reported as
   `dispatched` (tmux only — `send-keys` has no readiness signal to wait on)
   is *expected* to still be checking in here; it is not a partial and needs
   no special handling — poll it exactly like a `ready` member.
5. **Commit.** Build the `verified` member array (one object per roster
   member: `role`, `name`, `ref` from ListAgents, `route`, `kind`, `args`, `model`,
   `effort`, `auto_mode`, `transport_id`, `checked_in`; subagent-routed members
   get `name`/`ref`/`transport_id` null and `checked_in` set now).
   **`route: pane` members never appear in `ListAgents`** — they are not
   Claude sessions and have no `ref`; check them in with `herdr agent get
   <name>` instead and leave `ref` null. **Carry `kind` and `args` through
   verbatim** (both are absent for a `claude` member, and absent is correct —
   do not write `kind: "claude"`). A committed member missing its `kind` reads
   as `claude`, so every later liveness question about it goes to
   `peers.jsonl`, which a non-Claude agent never writes: it reports dead
   forever, and `dismiss` stops warning that a running agent is about to be
   dropped. In `auto` mode, build this directly
   from `--spawn`'s `members[]` (`role`, `name`, `route`, `kind`, `args`, `model`,
   `autoMode`, `transport_id` are already there) plus each member's
   `ref` from `ListAgents` — do not recompute the rest by hand. Run
   `roster.mjs create --commit --transport <t> --roster-level <L> --verified
   '<json>'` (add `--partial` if any peer-routed member never checked in). The
   orchestrator pid it records comes from the `CLAUDE_PID` env var, the same
   source `sessionstart.mjs` uses for peer liveness records, so it is supplied
   automatically. `--orchestrator-pid <pid>` overrides it — pass it only to
   supply an identity `CLAUDE_PID` does not carry; with neither, the verb
   refuses rather than guessing.
   On a full success, report the Team id and every member. **On partial
   success — the default per spec 0001 §13 — commit anyway with `--partial`,
   and tell the user exactly which member(s) never checked in and that the
   Team is degraded**; do not silently pretend a missing member exists, and
   do not block or tear down on a partial check-in unless the user says to.

**§ Create manual-mode layout.** In `manual` mode, run the layout phase one
iteration at a time. For each of the `layout_plan.pane_count` iterations:

1. `roster.mjs layout-splits --next --mode <m> --pane-count <n> --created '<ids so far, JSON>'`
   — this reads the live geometry and returns the decision **without
   splitting anything**.
2. Show the user: the iteration (`split 2 of 4`), the target pane id and its
   current size in cells, whether it is this session's own pane, the
   direction, and the mode that chose it.
3. Offer: **accept**, **change direction** (`right`/`down`), **change
   target** (any pane id in the returned geometry — including panes this
   loop did not create), or **skip this split**.
4. Unless skipped, run
   `roster.mjs layout-splits --apply --target <id> --direction <dir> --cwd <repo root>`
   and append the returned `pane_id` to your list.

The next iteration re-reads geometry, so an amendment is absorbed rather than
compounding.

**Skip** means that member gets no pane: it is carried into step 5's partial
handling as a member that did not come up, exactly as a failed split would
be. Say so when offering the option — a skip is not free, it degrades the
Team.

This pause is inside 3a, before each split — never a pause between 3a and 3b,
which 0003 §5 forbids because it would re-serialize the batched launch phase.

If you hit a genuinely ambiguous case here beyond a plain partial check-in —
a transport that silently no-ops, a member that comes up under an unexpected
name, anything the plan above doesn't cover — stop and report it upward
rather than improvising; spec 0001 §13 flags this area as a real escalation
candidate, not a place for invented judgment calls.

## `disband`

`disband` **closes every member's session** and drops the team record. It is a
**two-call contract** — plan, then close — so nothing is destroyed before the
user has seen exactly what would be. To drop the record and leave the sessions
running, that is `untrack --all` (§ untrack), never `disband`.

**No `team.json`?** (spec 0040) Plan and `--close` do not no-op: they operate on
the live peer records in `peers.jsonl` instead — the peers `add`/`spawn-one`
brought up, or a Team whose `team.json` was lost. The same plan → `close_token`
→ `--close --confirm` two-step applies, and every such output carries
`source: "peers"`. When a `team.json` exists, the plan also lists live peers
that are not in it, each row labeled `source: "peers"`, and `--close` closes
that whole set — the token pins the union, so a peer appearing after the plan
forces a re-plan. Only herdr peers are closable this way: checkin records the
herdr pane id, so a tmux peer surfaces with `command: null`.

1. Run `roster.mjs disband` — the plan form, i.e. no `--close`. Read-only — `team.json` is untouched. Its output now carries a `close_token`, bound to this exact plan — keep it, step 3 needs it. For the
   herdr transport it resyncs the member list **in memory** first (never
   persisted), so the plan targets each member's *current* pane rather than
   the one it was spawned into — you do **not** need to run `resync` first;
   that manual-resync-first advice is obsolete (spec 0008 §5.6/§7.4). It
   returns a `close` array, one entry per member, with a `command` (or `null`
   for terminal-routed, subagent-routed, or a member with no live
   `transport_id`) and, for herdr, a `resync_status` per member plus a
   sibling `resync` key (`{"ok": true, "counts": {...}}`, or `{"ok": false,
   "reason": "..."}` if herdr was unreachable — the plan still comes from the
   stored ids in that case, never blocked). The one residual gap: a move that
   lands *between* this query and step 3's actual closes is still possible —
   nothing inside `roster.mjs` can close that window, it's bounded by how
   long your step-2 confirmation takes.
2. Prompt the user once: "this will close N live sessions — proceed?",
   naming the members. Stop here if they decline. This conversational
   confirmation is still required and is not replaced by step 3's harness
   prompt below — the two are independent layers, both intended.
3. Call `roster.mjs disband --close` with `--confirm` and the `close_token`
   from step 1. The harness will *also* prompt the user interactively for
   `roster.mjs disband --close` — every time, unconditionally — before it runs; that
   prompt is enforced by the plugin itself and cannot be satisfied by this
   session on its own. Report, per member, whether its session actually
   closed or the close call failed (e.g. the pane was already gone) — a
   failed close is reported, not fatal. If the token is stale (the topology
   changed since step 1), it refuses — go back to step 1, plan again, and
   redo steps 2–3 with the fresh token.
   `--close` removes the team file itself once the closes have run. If some
   closes failed, the file is rewritten minus the ones that closed and the
   output reports `partial: true` — re-plan and close the remainder.

Never skip the plan call or its confirmation step — folding plan → confirm →
close into fewer calls is exactly what would close sessions before a declined
prompt could be honored. The plan form (no `--close`) never closes anything; only
`--close` does, and only it carries the always-ask permission gate.

**Want the bookkeeping cleared without closing anything?** That is
`untrack --all --keep-sessions --commit` (§ untrack) — sessions may hold work
that already cost tokens. Print the member names and `transport_id`s it returns
so the user can close them themselves if they want to.

A stale Team (dead orchestrator pid, or older than the fixed 24h cap) is also
swept automatically on the next plain top-level SessionStart — that sweep
clears `team.json` directly and never runs `roster.mjs disband`, so it is
unaffected by which flag is the default here.

**Recovering an orphaned Team (spec 0018 §5).** A Team whose `orchestrator.pid`
is `null` (a team hit by the pre-0018 identity bug) reads as dead and is on the same
sweep clock — it must be re-owned via
`roster.mjs adopt --orchestrator-pid <pid>` **before the next SessionStart**,
or the sweep deletes it (members, refs, `transport_id`s — everything) before
`adopt` gets a chance to run. `adopt` refuses to touch a Team whose recorded
owner is alive and different — it is recovery for an orphan, not a way to
steal a live Team.

## `resync` / `move`

Spec 0008. `team.json`'s recorded pane/tab/workspace location can go stale —
the user drags a pane in the Herdr UI, or an orchestrator-issued move happens
— without `roster.mjs` ever being told. Both verbs are additive; nothing else
changes, and neither is part of the normal roster-building flow above.

- **`roster.mjs resync [--dry-run]`** — queries herdr's live topology once,
  matches each peer member by herdr agent name first (falls back to pane id),
  and rewrites `team.json` with each member's current `transport_id`,
  `tab_id`, `workspace_id`. A member with no live match is left with its ids
  **unchanged** and gets `transport_stale: true` — a dead pane's close is a
  harmless no-op later, whereas clearing the id would leak a still-live one.
  `--dry-run` computes and prints the plan without writing. Non-herdr
  transports are a clean no-op. Run it any time the recorded location might
  be wrong; disband no longer needs it run first (see § disband).
- **`roster.mjs move <name> --tab <id> --split right|down | --new-tab
  [--workspace <id>] | --new-workspace [--dry-run]`** — runs `herdr pane
  move` for that member, then resyncs its record from a fresh topology query
  (the move's own response body is ignored). `--dry-run` prints the `herdr
  pane move …` command and runs nothing. Failure paths: an unresolved member
  name, or a herdr move that itself fails, both `fail()` with `team.json`
  untouched — the pane never moved, so the record is still correct as-is.
  `--split` is required whenever `--tab` is given — herdr rejects the move
  without it (spec 0009 §6.6), so `roster.mjs` `fail()`s locally before
  calling herdr rather than forwarding a call that cannot succeed.

## `spawn-one`

Spec 0009 §6. `roster.mjs create` refuses to run against a live Team
(`create --spawn`/`--commit`/`--plan` all `fail()` when one already exists),
so once a Team exists and one role has died — or was never launched — there
is no supported way to stand up just that role. `spawn-one` closes that one
gap; it is not a lighter-weight alternative to Create for a full team.

- **`roster.mjs spawn-one <role> [--member <name>] [--cwd <path>] [--dry-run] [--allow-global]`**
  — resolves the roster, finds `<role>`'s member, and:
  - bare `spawn-one <role>` picks the first member of that role that is not
    live; `--member <name>` targets one specific same-role instance by its
    derived name (spec 0019).
  - a live team member for that role already exists → no-op,
    `{spawned:false, reason:"already live"}`.
  - otherwise → places one pane, launches and verifies it the same way
    `create --spawn` does, then merge-writes `team.json`: every other
    member is preserved, only this role's record is replaced or appended.
  - `--dry-run` prints the resolved member, layout mode, and launch command;
    executes and writes nothing.

  Prefer `spawn-one` over Create whenever a Team already (partially) exists —
  Create's whole-team flow is the `/agent-roster` skill's job for building a
  fresh Team, never for patching one member into an existing one.

**Two gates guard both `spawn-one` and full-team `create --spawn`/Create's
peer-dispatch entry points**, because `roster.mjs` runs as a Bash subprocess
that the PreToolUse hook cannot see inside:

- **`--allow-global`** — required whenever the roster resolves at the
  `global` level (`~/.claude/agent-hierarchy.json`'s roster block, not a
  repo-scoped one); omitting it `fail()`s naming the flag. This mirrors the
  PreToolUse gate's scope-A confirmation (spec 0009 §4) for the CLI path.
- **The PreToolUse global-scope confirm gate** (spec 0009 §4) still applies
  to any Agent/Task/SendMessage dispatch to the resulting peer — `--allow-global`
  only unblocks the CLI command that stands the peer up, not later dispatch to it.

**Fallback ordering when the `route` is `peers` and no live peer exists for a
role** (spec 0009 §5): the dispatch is denied with a prompt that recommends,
in order, (1) stand up the real peer with `spawn-one` (Recommended, offered
only when a roster entry for that role exists at a usable level), (2) spawn a
one-off subagent instead, (3) neither — wait. This replaces the previous
subagent-only recommendation; a real, persisted peer is now the default
fallback, not a disposable subagent.

## `dismiss`

Spec 0020. `remove --member <NAME>` edits the roster **config** (the template
for future Teams); `dismiss <name>` edits the **live Team's `team.json`** —
they write different stores, and each names the store it wrote in its output.
`dismiss` mirrors `disband`'s plan/close split, scoped to one member. Spec 0040:
a name that is not in `team.json` — or no `team.json` at all — is looked up in
the live peer records, output carrying `source: "peers"`; spec 0046 §2.4 widens
what `<name>` accepts to any identifier the user can see for such a session —
a `pane_id`, a `session_id` or a unique 8+ character prefix of one, the
`role@sid8` form `teams` prints, or the herdr display name. An ambiguous
identifier fails and lists every candidate rather than guessing.

1. `roster.mjs dismiss <name>` — the plan form, i.e. no `--close` —
   read-only, resyncs that one member in memory for herdr, and returns
   `member`/`live`/`close_token`/`remaining`. `live` reads the check-in
   registry; a stale-registry member can still report a non-null `command`.
2. If `live` is true and the session should actually close, prompt the user,
   then call `roster.mjs dismiss <name> --close` with `--confirm` and the `close_token`
   from step 1 — same always-ask harness gate as `roster.mjs disband --close`. This
   never touches `team.json`.
   On a successful close the `team.json` row is removed too (`untracked: true`);
   if the close failed, the row stays, because a live session with no record is
   exactly the orphan spec 0046 exists to prevent. A member that is already
   dead has nothing to close — prune its record with `untrack` instead.

`--also-config` (with `--close`) additionally removes the matching roster
config entry, so a future `create`/`spawn-one` doesn't rebuild the instance just
dismissed. Default off — plain `dismiss` never touches the config. Removing a
non-last same-role config entry re-ordinals later siblings' derived names
(§3.5.1) — the CLI warns and reports it (`config.reordinaled`); live
`team.json` records keep their original names regardless.

Dismissing the last member leaves `team.json` with `members: []` rather than
removing the file — `team_empty: true` in the output flags this; point the
user at `disband` if they meant to end the Team entirely.

## `untrack`

Spec 0046 §2.3. `untrack` is the **only** verb that forgets a record without
touching a session, and it is the answer to exactly two situations:

- the user explicitly wants the session kept — "leave it running", "just stop
  tracking it", "forget the team but don't close anything";
- the target is already gone, and its record is stale bookkeeping to prune.

Anything else — "dismiss", "remove", "drop", "kick", "close", "disband", "tear
down", "get rid of" — means `dismiss`/`disband`, which CLOSE the session. When
the user's words are genuinely ambiguous, ask; do not pick.

1. Bare `roster.mjs untrack <name>|--all` (or with `--plan`) is read-only:
   it reports what would be forgotten and each target's liveness.
2. `--commit` removes the record. A target that is live, or whose liveness
   cannot be determined, is REFUSED unless `--keep-sessions` is passed — the
   refusal names both remedies (`dismiss` to close it, or `--keep-sessions` to
   leave it running untracked) and says the record cannot be recovered.

`--all` forgets the whole team file instead of one member. Untracking
something already gone succeeds with `already_untracked: true`, so a retry is
never an error. `--also-config` (single member only) additionally removes the
roster template row, with the same ordinal-shift warning `dismiss` gives.

## Check-in registry (`team.json`)

One active Team per repo, at `<hierarchyDir>/team.json` alongside
`peers.jsonl`/`gates.jsonl`. Once it exists, it is the **authoritative**
source for peer dispatch (ADR 0002): a SendMessage `to` or role lookup that
matches a Team member's derived name resolves from `team.json` first, before
the existing config-peer and live-roster fallbacks — those two paths are
unchanged and still cover the ad-hoc-peer case outside any Team.

## Relocation (`checkin`, `misplaced`)

Spec 0036. A Team records `expected_root` — the directory a peer's session
should be running in — at creation. SessionStart compares a peer's actual cwd
against it and, if they disagree, marks that peer's roster row
`misplaced: true` and prints an instruction. It never refuses to register a
misplaced peer — a peer that doesn't register is invisible to `roster teams`
and to dismiss/respawn, which is worse than being visibly wrong.

**If you are a misplaced peer:** run `EnterWorktree` with `path=<expected_root>`,
then run `roster.mjs checkin` to re-register. **`cd` will not work** — a shell
`cd` does not move this session's `input.cwd`; only `EnterWorktree` does. If
`EnterWorktree` is refused or denied, report to the orchestrator for respawn.

`checkin` re-runs the same comparison against the *current* cwd and appends a
fresh roster row — it's the only thing that re-checks a session mid-run,
since SessionStart only fires once, at launch. It exits **non-zero while still
misplaced**, so a script (or the peer itself) can tell success from failure
without parsing prose.

**`misplaced_unattributed`** (on `roster teams`'s output): a count of
misplaced peers this session could not safely attribute to one specific Team
member — a role shared by more than one member of that Team, or a row with no
recorded Team at all (a pre-0036 row). **This means "do not guess which
member"** — the orchestrator's fallback for a misplaced peer (below) is
destructive, so guessing wrong is worse than not attributing at all.

**Fallback, when relocation is refused, denied, or impossible:**
`roster dismiss <name>` then `roster spawn-one <name> --cwd <expected_root>`.
**This discards the dismissed peer's context** — only use it after relocation
has genuinely failed, never as a first resort, and never against a peer
`misplaced_unattributed` couldn't confidently name.


## `spawn-ad-hoc`

`spawn-ad-hoc <role>` is `spawn-one` for a member the roster does not
describe. Use it whenever the running team needs something the roster does not
have — a second implementor on a different model, a codex member, a role the
roster never defined. It reads the roster only for the team's route/layout
defaults, and writes only the team file.

1. **The name is derived, not chosen.** It uses the team's own prefix and the
   next free ordinal for that role, exactly as `create`/`spawn-one` do
   (`myrepo-implementor`, then `myrepo-implementor-2`). If the derived name is
   already taken in the team file, the command refuses rather than overwriting
   the existing member's record.
2. **Every member field is accepted** — `--model`, `--effort`, `--kind`,
   `--route`, `--args`, `--auto-mode`, `--on-missing` — and validated by the
   same rules `add` uses. There are no relaxed rules for ad hoc members.
3. **The route must have a pane** (`peer`, or `pane` for a non-Claude kind).
   A `subagent` member is dispatched on demand and has nothing to launch.
4. It launches through the same `spawn-one` machinery, so `--dry-run`,
   `--allow-global`, the herdr-vs-terminal transport choice, and the
   blocked-at-startup reporting all behave identically. See § spawn-one for
   those; only the member's source differs.

Report the derived name back to the user in one line — they did not choose it,
and they need it for a later `dismiss`.
