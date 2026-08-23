---
name: agent-roster
description: Define, edit, or inspect the agent-hierarchy roster (which roles exist, their model/effort/route), spawn the roster as a live Team, or disband one. Use for /agent-roster, for "set up my team", "add a reviewer peer", "spawn the team", or "disband the team".
---

# agent-roster

The roster is a `roster` block in the existing `agent-hierarchy.json` config,
at one of three levels (§ Levels below). `hooks/roster.mjs` does all the file
I/O and validation; this skill is the interactive prose surface that drives
it — do not hand-edit the JSON, and do not duplicate its validation here.

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
losing level does not appear. `roster.mjs show` (no `--level`) always prints
the resolved (winning) roster; `roster.mjs show --level <L>` prints one
level's raw file and says if it's shadowed.

Member names are **derived, never stored**: the first member of a role at the
winning level is `<repo-basename>-<role>` (e.g. `claudetools-architect`); a
second, third, ... same-role member gets `-2`, `-3` appended, in array order.
Removing an earlier member re-ordinals the ones after it — names are only
meaningful for a Team's lifetime, and a live Team's authoritative names are
frozen in `team.json` at check-in time (§ Check-in registry), not recomputed
from the roster.

## Command surface

All subcommands run via `node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" <cmd> ...`
with `--cwd "$(pwd)"` (or the relevant repo path). Level may be given as
`--level <L>` or as the first bare word: `roster.mjs add repo --role architect`
≡ `--level repo`.

- `show [--level global|repo|repo-user]` — resolved roster, or one level's raw file.
- `init --level <L> --route <peer|subagent> [--layout auto|columns|grid]` — replaces that level's roster wholesale.
- `add --role <R> [--level L] [--model M] [--effort E] [--route peer|subagent] [--auto-mode A]`
- `edit --member <NAME> [--level L] [--role R] [--model M] [--effort E] [--route ...] [--auto-mode A]`
- `remove --member <NAME> [--level L]`
- `layout [--level <L>] [--layout auto|columns|grid]` — show or set the team-wide pane layout.
- `create [--plan | --commit ... | --spawn --mode <m>]` — see § Create.
- `layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>] [--next|--apply …]` — performs
  the herdr layout phase. Used by § Create phase 3a. Not a user-facing command.
- `next-split --mode <m> --pane-count <n> --self <id> --created <json> --geometry <json>` — the pure
  decision function, exposed for testing. The skill does not call it; `layout-splits` does.
- `disband [--commit|--keep-sessions]` — tears down the Team. Bare `disband` emits close commands
  (read-only); `--commit` removes `team.json` after the skill has actually run them; `--keep-sessions`
  removes `team.json` without closing anything. See § disband.
- `resync [--dry-run]` — re-derives every peer member's herdr pane/tab/workspace location from
  herdr's live topology and rewrites `team.json`. See § resync / move.
- `move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace
  [--dry-run]` — relocates a member's pane via `herdr pane move`, then resyncs its record. See
  § resync / move.

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
5. Run `roster.mjs init --level <L> --route <route> [--layout <mode>]`.
6. **Walk the roles.** For each of `architect`, `implementor`, `reviewer`,
   `task-runner`, `ultra-advisor` in turn, ask (AskUserQuestion, batched into
   calls of up to 4 questions) whether to include it, and if so its model,
   effort, and auto-mode. Prefill/offer defaults from `ROLE_DEFAULTS` in
   `hooks/lib-config.mjs` — do not invent separate defaults here. For each
   role the user includes, run `roster.mjs add --level <L> --role <role>
   [--model ...] [--effort ...] [--auto-mode ...]`. A role can be added more
   than once if the user wants multiple instances of it.
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

## Create

`create [auto|manual]` (default `auto`) instantiates the resolved roster as a
live Team, verified via check-in. `roster.mjs create` only ever does file
I/O; spawning sessions and calling `ListAgents` are things only this skill's
running session can do — drive the sequence yourself:

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
2. **`manual` mode**: before each spawn, show the intended placement (name,
   role, transport) and let the user override it (different pane, skip it,
   change the name) before proceeding. `auto` mode spawns straight through.

   `--spawn` only launches the panes — it writes nothing; the Team does not
   exist until the follow-up `create --commit --verified <json> --transport
   <t> --roster-level <L>` call persists `team.json`, and until then
   `resync`, `move`, and `disband` cannot see the members at all.
3. **Spawn.**

   **`auto` mode:** run one command:

       roster.mjs create --spawn --mode <layout_plan.mode> [--roster-level <L>] [--orchestrator-pid <pid>] --cwd <repo root>

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
   orchestrator pid it records comes from the `CLAUDE_PID` env var by default
   (the same source `sessionstart.mjs` uses for peer liveness records) — pass
   `--orchestrator-pid <pid>` only to override that.
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

1. Run `roster.mjs disband`. Read-only — `team.json` is untouched. For the
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
   naming the members. Stop here if they decline.
3. Run every non-null `command` in **one** Bash invocation and report, per
   member, whether its session actually closed or the close call failed
   (e.g. the pane was already gone) — a failed close is reported, not fatal.
4. Only now run `roster.mjs disband --commit` to remove `team.json`. If it
   reports no active team (e.g. a retry after step 4 already ran), that's
   fine — the teardown already completed.

Never call `--commit` before running the closes from the plan call, and never
skip the plan call's confirmation step — folding the two into one call is
exactly what would leave `team.json` gone before a declined prompt or a
failed close could be honored.

**`roster.mjs disband --keep-sessions`** — the safe form: removes `team.json`
and closes nothing, since sessions may hold work that already cost tokens.
Single call, no confirmation needed since nothing destructive to a live
session happens. Print the member names and `transport_id`s it returns so
the user can close them themselves if they want to.

A stale Team (dead orchestrator pid, or older than the fixed 24h cap) is also
swept automatically on the next plain top-level SessionStart — that sweep
clears `team.json` directly and never runs `roster.mjs disband`, so it is
unaffected by which flag is the default here.

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
- **`roster.mjs move <name> --tab <id> [--split right|down] | --new-tab
  [--workspace <id>] | --new-workspace [--dry-run]`** — runs `herdr pane
  move` for that member, then resyncs its record from a fresh topology query
  (the move's own response body is ignored). `--dry-run` prints the `herdr
  pane move …` command and runs nothing. Failure paths: an unresolved member
  name, or a herdr move that itself fails, both `fail()` with `team.json`
  untouched — the pane never moved, so the record is still correct as-is.

## Check-in registry (`team.json`)

One active Team per repo, at `<hierarchyDir>/team.json` alongside
`peers.jsonl`/`gates.jsonl`. Once it exists, it is the **authoritative**
source for peer dispatch (ADR 0002): a SendMessage `to` or role lookup that
matches a Team member's derived name resolves from `team.json` first, before
the existing config-peer and live-roster fallbacks — those two paths are
unchanged and still cover the ad-hoc-peer case outside any Team.
