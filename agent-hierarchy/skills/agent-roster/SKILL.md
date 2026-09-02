---
name: agent-roster
description: Define, edit, or inspect the agent-hierarchy roster (which roles exist, their model/effort/route), spawn the roster as a live Team, or disband one. Use for /agent-roster, for "set up my team", "add a reviewer peer", "spawn the team", "spawn the architect", "spawn just the reviewer", or "disband the team".
---

# agent-roster

The roster is a `roster` block in the existing `agent-hierarchy.json` config,
at one of three levels (§ Levels below). `$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs`
(preferably via `mcp__ah__roster_show` for reads) does all the file I/O and
validation; this skill is the interactive prose surface that drives it — do
not hand-edit the JSON, and do not duplicate its validation here.

Full spec: `docs/specs/0001-agent-roster.md`. This document is the operational
surface; if the two disagree, the spec is authoritative and this file has
drifted — say so rather than silently picking one.

## Levels

| Level | Path | Wins when |
|---|---|---|
| `repo-user` | `~/.claude/agent-hierarchy/projects/<slug>/agent-hierarchy.json` | always, if present and non-empty |
| `repo` | `<repo-root>/.claude/agent-hierarchy.json` | no repo-user roster |
| `global` | `~/.claude/agent-hierarchy.json` | no repo-user or repo roster |

Resolution is **whole-level replace**, not a per-key merge: the winning
level's `roster` block is used in its entirety — a member defined only at a
losing level does not appear. Prefer `mcp__ah__roster_show` (MCP tool) when
available; otherwise `roster.mjs show`. With no `--level`/`level` argument
it always prints the resolved (winning) roster; with one, it prints that
level's raw file and says if it's shadowed.

Member names are **derived, never stored**: the first member of a role at the
winning level is `<team-prefix>-<role>` (e.g. `claudetools-architect`) — the
team-prefix is the repo's `teamAlias` if one is set, else the repo basename;
see `roster.mjs alias`. A second, third, ... same-role member gets `-2`, `-3`
appended, in array order.
Removing an earlier member re-ordinals the ones after it — names are only
meaningful for a Team's lifetime, and a live Team's authoritative names are
frozen in `team.json` at check-in time (§ Check-in registry), not recomputed
from the roster.

## Command surface

Each `roster_*` MCP tool maps 1:1 to `node roster.mjs <verb>` with the same
flags (snake_case tool params ↔ kebab-case CLI flags, e.g. `auto_mode` ↔
`--auto-mode`). Prefer the tool — `mcp__ah__roster_<verb>` — whenever the `ah`
MCP server is connected; the model should never need Bash for any roster
operation. If the server is not connected, fall back to Bash with the CLI
form below using the same flag mapping. That is the entire fallback story;
this file does not document both forms per verb.

All CLI subcommands run via `node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" <cmd> ...`
with `--cwd "$(pwd)"` (or the relevant repo path). Level may be given as
`--level <L>` or as the first bare word: `roster.mjs add repo --role architect`
≡ `--level repo`.

`--team <name>` (spec 0011) lets one repo host more than one Team, each owned
by a distinct orchestrator session: it points every verb that reads or writes
`team.json` at `teams/<name>.json` instead of the default `team.json`, and
scopes the derived name-prefix to `<name>` instead of the repo's alias.
Omitted, everything is the default team exactly as before — most sessions
never pass it. See § Create for what happens when a bare `create` collides
with someone else's live default Team.

- `show [--level global|repo|repo-user]` (`mcp__ah__roster_show`) — resolved roster, or one level's raw file.
- `init --level <L> --route <peer|subagent> [--layout auto|columns|grid]` (`mcp__ah__roster_member`, `action: "init"`) — replaces that level's roster wholesale.
- `add --role <R> [--level L] [--model M] [--effort E] [--route peer|subagent] [--auto-mode A]` (`mcp__ah__roster_member`, `action: "add"`)
- `edit --member <NAME> [--level L] [--role R] [--model M] [--effort E] [--route ...] [--auto-mode A]` (`mcp__ah__roster_member`, `action: "edit"`)
- `remove --member <NAME> [--level L]` (`mcp__ah__roster_member`, `action: "remove"`) — edits the
  roster **config**, not a live Team; see § dismiss for the live-Team equivalent.
- `layout [--level <L>] [--layout auto|columns|grid]` (`mcp__ah__roster_config`, `target: "layout"`) — show or set the team-wide pane layout.
- `create [--plan | --commit ... | --spawn --mode <m>]` (`mcp__ah__roster_create`, `mode: plan|spawn|commit`) — see § Create.
- `layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>] [--next|--apply …]` (`mcp__ah__roster_layout_splits`) — performs
  the herdr layout phase. Used by § Create phase 3a. Not a user-facing command.
- `next-split --mode <m> --pane-count <n> --self <id> --created <json> --geometry <json>` — the pure
  decision function, exposed for testing. The skill does not call it; `layout-splits` does. No
  tool wraps it — it is unreachable from the skill, so it never forces a Bash fallback; tests keep
  calling the CLI directly.
- `disband [--commit|--keep-sessions]` (`mcp__ah__roster_disband`, `mode: plan|commit|keep-sessions`, default `plan`) —
  tears down the Team. Bare `disband`/`mode: plan` emits close commands (read-only); `--commit`
  removes `team.json` after the closes have actually run; `--keep-sessions` removes `team.json`
  without closing anything. **Never closes anything itself** — see § disband and § disband's close
  step below for the separate, destructive `roster_disband_close`.
- `disband --close --confirm --plan-token <tok>` (`mcp__ah__roster_disband_close`) — **destructive**:
  closes the live sessions the preceding plan call named. Gated by default: the harness itself
  prompts the user for `roster_disband_close` (see § disband step 3). Never call it without the
  `close_token` from a `disband`/`mode: plan` call immediately before it.
- `resync [--dry-run]` (`mcp__ah__roster_resync`) — re-derives every peer member's herdr pane/tab/workspace location from
  herdr's live topology and rewrites `team.json`. See § resync / move.
- `move <name> --tab <id> --split right|down | --new-tab [--workspace <id>] | --new-workspace
  [--dry-run] [--allow-global]` (`mcp__ah__roster_move`) — relocates a member's pane via `herdr pane move`, then resyncs its record.
  Needs `--allow-global` whenever the roster resolves at the global level, exactly like `spawn-one`/`create --spawn` (§4.4) —
  `move` relocates a live agent pane, so it gets the same confirm-gate protection. See § resync / move.
- `spawn-one <role> [--cwd <path>] [--dry-run] [--allow-global]` (`mcp__ah__roster_spawn_one`) — stands up ONE missing or dead
  peer and persists it into `team.json`, without touching any other member. Prefer this over
  Create when a Team already exists and only one role needs (re)starting — Create refuses to run
  against a live Team. The direct match for "spawn the architect" / "spawn just the reviewer"
  style requests. See § spawn-one.
- `dismiss <name> [--plan | --close --confirm --plan-token <tok> | --commit [--also-config]]`
  (`mcp__ah__roster_dismiss`/`roster_dismiss_close`) — drops ONE member from a live Team by its
  derived name, the inverse of `spawn-one`. See § dismiss.
- `alias [--level global|repo|repo-user] [--set <name>] [--clear] [--cwd <path>]` (`mcp__ah__roster_config`, `target: "alias"`) — read, set, or
  clear the repo's `teamAlias` (the team-prefix members are named under). No `--set`/`--clear`
  reads the currently-effective alias; `--level` is required with `--set`/`--clear` when it can't
  be inferred from an already-resolving roster. Never accepts `--level global` — an alias is
  repo-scoped. `--set`/`--clear` refuse while `--team` is active (the team name already is
  that team's prefix); `alias` (read-only) reports both the config alias and the active team
  scope, distinguished.
- `teams [--cwd <path>]` (`mcp__ah__roster_teams`) — read-only: every team file in this hierarchy dir (default plus every
  named team), with member count, orchestrator pid, whether that pid is alive, and whether it's
  this session's own. Use it to see a stale or a sibling orchestrator's Team before `create`. Also
  reports `misplaced_members` (peers confirmed relocated away from where the Team expects them)
  and `misplaced_unattributed` (a count of misplaced peers this session could not safely attribute
  to a specific member) — see § Relocation.
- `checkin [--team <T>] [--cwd <path>]` (CLI only, no MCP tool yet) — re-registers the *current*
  session's cwd. Spec 0036 §3.3. See § Relocation.

`add`/`edit`/`remove` with no `--level` operate on whichever level currently
resolves (repo-user > repo > global) and print which level they picked — say
that back to the user in one line. If no roster resolves anywhere, the CLI
errors pointing at `init`; run `init` first (asking the user per § Init below).

Roles: `architect`, `implementor`, `reviewer`, `task-runner`, `ultra-advisor`.
`orchestrator` is rejected by the CLI — the Orchestrator is whatever session
runs `create`, never a roster entry.

## `/agent-roster` bare, or `show`

Run `show` and print its output. If it reports `roster: null` (nothing
configured at any level), say so and offer to run `init`.

## `init`

1. **Level.** If not given, ask via AskUserQuestion: `global` (all repos),
   `repo` (this repo, committable), `repo-user` (this repo, this machine
   only — not committed). One line each on what the level means.
2. **Route.** If not given, ask peer-vs-subagent as the roster's team-wide
   default: "Peer agent (Recommended)" — spawned as a named live session,
   SendMessage'd from then on; "Subagent only" — always a fresh Agent-tool
   dispatch, never a standing session. A member can override this later via
   its own `--route`.
3. **Layout.** If not given, ask the team-wide pane layout: `auto`
   (Recommended) — columns for 1-2 members, grid beyond; `columns` — one
   vertical column per member, narrow past three; `grid` — balanced
   quadrants. Pass it as `--layout <mode>` to `roster.mjs init`. Only
   meaningful for the `herdr` transport; harmless otherwise.
4. **Destructive check.** If that level already has a roster (`show --level
   <L>` returns members), confirm before replacing — `init` always replaces
   the whole level's block, never merges into it.
4a. **Team name.** Ask via AskUserQuestion what prefix this repo's agent
   names should use. Show the derived name it produces, not just the prefix:
   offer `"<repo-basename>" — agents named <repo-basename>-architect,
   <repo-basename>-reviewer, … (Recommended)` as the first option, and
   `"Use a shorter alias"` as the second, which prompts for free text.
   Whatever the user types is validated by `roster.mjs alias --set`; on
   rejection, report the CLI's message and ask again rather than silently
   correcting it. Skip this question entirely if `roster.mjs alias` already
   reports an alias for this repo — say in one line what it is and move on.
   If the user picks the alias option, run
   `roster.mjs alias --level <L> --set <name>`.
5. Run `roster.mjs init --level <L> --route <route> [--layout <mode>]`.
6. **Pick the roles.** Ask a single AskUserQuestion call with
   `multiSelect: true` — one question ("Which roles should this roster
   include?"), one option per role with a one-line description:
   `architect` (design authority — specs, never implements), `implementor`
   (builds exactly what the spec says), `reviewer` (validates an
   Implementor's diff against the spec), `task-runner` (cheap runner for
   tests/builds/log-sifting/search), `ultra-advisor` (deepest-reasoning
   escalation for hard or high-stakes calls). Then, for each role picked,
   ask (AskUserQuestion, batched into calls of up to 4 questions) its model,
   effort, and auto-mode. Prefill/offer defaults from `ROLE_DEFAULTS` in
   `hooks/lib-config.mjs` — do not invent separate defaults here. For each
   picked role, run `roster.mjs add --level <L> --role <role> [--model ...]
   [--effort ...] [--auto-mode ...]`. A role can be added more than once —
   if the user wants multiple instances of a role, that's a follow-up ask,
   not part of the multiselect (its options must stay distinct picks).
7. Run `show` and echo the result.

Whole-level replace is a *read* rule; `init` itself only ever writes the one
level's file you asked for.

## `add` / `edit` / `remove`

Prompt for any field the user didn't already state (role for `add`; the
target member's derived name for `edit`/`remove`), then call the CLI. Report
the exact result the CLI returns, including which level it defaulted to when
`--level` was omitted.

Layout (`roster.layout`) is team-wide, not a per-member field — there is no
`--layout` on `add`/`edit`. Use `roster.mjs layout` (§ Command surface) to
change it outside of `init`.

`--on-missing auto|prompt|never` (spec 0021, peer-routed members only) sets
what the route gate does when this role has no live peer: `prompt` (default)
is today's three-option ask; `never` falls straight through to a subagent,
no prompt; `auto` denies once naming the `spawn-one` command instead of
asking — **spawn without asking**, still one orchestrator turn, never a
zero-turn spawn. It never bypasses the global-scope confirm gate (§4.4 of the
spec) — a global-level roster still asks before it is used at all, regardless
of any member's `onMissing`.

## Create

`create [auto|manual]` (default `auto`) instantiates the resolved roster as a
live Team, verified via check-in. `roster.mjs create` only ever does file
I/O; spawning sessions and calling `ListAgents` are things only this skill's
running session can do — drive the sequence yourself:

**Reuse a recent team (spec 0015).** Before planning a Team from the roster
files, offer to reuse a recent one: run `roster.mjs history --json`
(`mcp__ah__roster_history`), and if it returns any entries, present them via
**AskUserQuestion** (label, role list, active/idle, last-used) alongside a
"start fresh from the roster" option. If the user picks an entry, run
`roster.mjs create --from <id> --commit --spawn` (its own id, not the alias)
in place of the roster-driven plan below — same downstream steps (layout
confirmation, spawn, check-in) apply unchanged. This capability is skill-only
— `--from` composes with `roster.mjs create` directly and is deliberately
**not** an MCP tool, for the same reason `create --spawn`/`--commit` aren't
skipped over: recreating a Team still needs 0009's confirm gates, which only
fire on the CLI/skill path.

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
   `transport`, and `members[]` — each entry carries `role`, `name`, `model`,
   `route`, `autoMode`, `transport_id`, and `launch_status`
   (`ready`|`dispatched`|`failed`; `null` for subagent-routed members), plus
   `error` when `failed`. `partial: true` iff any peer-routed member's
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
   confirmation screen instead of ready.

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
   member: `role`, `name`, `ref` from ListAgents, `route`, `model`, `effort`,
   `auto_mode`, `transport_id`, `checked_in`; subagent-routed members get
   `name`/`ref`/`transport_id` null and `checked_in` set now). In `auto` mode,
   build this directly from `--spawn`'s `members[]` (`role`, `name`, `route`,
   `model`, `autoMode`, `transport_id` are already there) plus each member's
   `ref` from `ListAgents` — do not recompute the rest by hand. Run
   `roster.mjs create --commit --transport <t> --roster-level <L> --verified
   '<json>'` (add `--partial` if any peer-routed member never checked in). The
   orchestrator pid it records is supplied automatically — via `mcp__ah__roster_create`
   (spec 0018), the server derives it from its own process tree; on the Bash CLI path it
   comes from the `CLAUDE_PID` env var (the same source `sessionstart.mjs` uses for peer
   liveness records). `--orchestrator-pid <pid>` / `orchestrator_pid` is an override, not
   a requirement, on either path — pass it only to supply an identity neither source has.
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

Bare `disband` tears the Team all the way down by default. It is a **two-call
contract**, mirroring `create`'s `--plan`/`--commit` split, so removal cannot
happen before the real closes do:

1. Run `roster_disband` (`mode: plan`, or bare `roster.mjs disband`). Read-only — `team.json` is untouched. Its output now carries a `close_token`, bound to this exact plan — keep it, step 3 needs it. For the
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
3. Call `roster_disband_close` with `confirm: true` and the `close_token`
   from step 1. The harness will *also* prompt the user interactively for
   `roster_disband_close` — every time, unconditionally — before it runs; that
   prompt is enforced by the plugin itself and cannot be satisfied by this
   session on its own. Report, per member, whether its session actually
   closed or the close call failed (e.g. the pane was already gone) — a
   failed close is reported, not fatal. If the token is stale (the topology
   changed since step 1), it refuses — go back to step 1, plan again, and
   redo steps 2–3 with the fresh token.
4. Only now run `roster_disband` `mode: commit` (or `roster.mjs disband --commit`)
   to remove `team.json`. If it reports no active team (e.g. a retry after
   step 4 already ran), that's fine — the teardown already completed.

Never call `mode: commit` before running the close from the plan call, and
never skip the plan call's confirmation step — folding plan → confirm → close
→ commit into fewer calls is exactly what would leave `team.json` gone before
a declined prompt or a failed close could be honored. `roster_disband`'s
non-destructive modes (`plan`/`commit`/`keep-sessions`) never close anything;
only `roster_disband_close` does, and it is deliberately a separate tool so it
can carry its own always-ask permission gate without gating the harmless modes.

**`roster.mjs disband --keep-sessions`** — the safe form: removes `team.json`
and closes nothing, since sessions may hold work that already cost tokens.
Single call, no confirmation needed since nothing destructive to a live
session happens. Print the member names and `transport_id`s it returns so
the user can close them themselves if they want to.

A stale Team (dead orchestrator pid, or older than the fixed 24h cap) is also
swept automatically on the next plain top-level SessionStart — that sweep
clears `team.json` directly and never runs `roster.mjs disband`, so it is
unaffected by which flag is the default here.

**Recovering an orphaned Team (spec 0018 §5).** A Team whose `orchestrator.pid`
is `null` (a team hit by the pre-0018 MCP bug) reads as dead and is on the same
sweep clock — it must be re-owned via `mcp__ah__roster_adopt` /
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
`dismiss` mirrors `disband`'s plan/close/commit split, scoped to one member:

1. `roster_dismiss` `mode: plan` (or bare `roster.mjs dismiss <name>`) —
   read-only, resyncs that one member in memory for herdr, and returns
   `member`/`live`/`close_token`/`remaining`. `live` reads the check-in
   registry; a stale-registry member can still report a non-null `command`.
2. If `live` is true and the session should actually close, prompt the user,
   then call `roster_dismiss_close` with `confirm: true` and the `close_token`
   from step 1 — same always-ask harness gate as `roster_disband_close`. This
   never touches `team.json`.
3. `roster_dismiss` `mode: commit` (or `roster.mjs dismiss <name> --commit`)
   removes the member's record from `team.json`. Safe to call directly,
   skipping 1-2, when the member is already dead (the common case: pruning a
   stale record). A commit against a still-live member succeeds but warns.

`--also-config` (commit only) additionally removes the matching roster config
entry, so a future `create`/`spawn-one` doesn't rebuild the instance just
dismissed. Default off — plain `dismiss` never touches the config. Removing a
non-last same-role config entry re-ordinals later siblings' derived names
(§3.5.1) — the CLI warns and reports it (`config.reordinaled`); live
`team.json` records keep their original names regardless.

Dismissing the last member leaves `team.json` with `members: []` rather than
removing the file — `team_empty: true` in the output flags this; point the
user at `disband --commit` if they meant to end the Team entirely.

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
