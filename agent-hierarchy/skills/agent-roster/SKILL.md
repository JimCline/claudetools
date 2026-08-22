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
- `init --level <L> --route <peer|subagent>` — replaces that level's roster wholesale.
- `add --role <R> [--level L] [--model M] [--effort E] [--route peer|subagent] [--auto-mode A]`
- `edit --member <NAME> [--level L] [--role R] [--model M] [--effort E] [--route ...] [--auto-mode A]`
- `remove --member <NAME> [--level L]`
- `create [--plan | --commit ...]` — see § Create.
- `disband` — tears down `team.json` only; never kills sessions.

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
3. **Destructive check.** If that level already has a roster (`show --level
   <L>` returns members), confirm before replacing — `init` always replaces
   the whole level's block, never merges into it.
4. Run `roster.mjs init --level <L> --route <route>`.
5. **Walk the roles.** For each of `architect`, `implementor`, `reviewer`,
   `task-runner`, `ultra-advisor` in turn, ask (AskUserQuestion, batched into
   calls of up to 4 questions) whether to include it, and if so its model,
   effort, and auto-mode. Prefill/offer defaults from `ROLE_DEFAULTS` in
   `hooks/lib-config.mjs` — do not invent separate defaults here. For each
   role the user includes, run `roster.mjs add --level <L> --role <role>
   [--model ...] [--effort ...] [--auto-mode ...]`. A role can be added more
   than once if the user wants multiple instances of it.
6. Run `show` and echo the result.

Whole-level replace is a *read* rule; `init` itself only ever writes the one
level's file you asked for.

## `add` / `edit` / `remove`

Prompt for any field the user didn't already state (role for `add`; the
target member's derived name for `edit`/`remove`), then call the CLI. Report
the exact result the CLI returns, including which level it defaulted to when
`--level` was omitted.

## Create

`create [auto|manual]` (default `auto`) instantiates the resolved roster as a
live Team, verified via check-in. `roster.mjs create` only ever does file
I/O; spawning sessions and calling `ListAgents` are things only this skill's
running session can do — drive the sequence yourself:

1. **Plan.** Run `roster.mjs create --plan`. It resolves the roster, refuses
   if a live Team already exists (tell the user to `disband` first), clears
   an already-stale one automatically, detects the transport (`herdr` if
   `HERDR_ENV=1`, else `tmux` if a tmux server is reachable, else
   `terminal`), and returns each member's derived name, role, model,
   effort, route, and — for peer-routed members — a `spawn` shape (the
   concrete command(s) for the detected transport). If it errors because no
   roster resolves, hand off to § Init.
2. **`manual` mode**: before each spawn, show the intended placement (name,
   role, transport) and let the user override it (different pane, skip it,
   change the name) before proceeding. `auto` mode spawns straight through.
3. **Spawn every peer-routed member** using its `spawn.steps`, via Bash (or
   the `herdr` skill's tools when transport is `herdr`) — one running
   `claude --agent ah:<role> --model <model> --name
   <derived-name>` (plus `--effort <e>` / `--permission-mode <a>` when set)
   per member, in the repo root. Subagent-routed members are never spawned
   here — they stay ordinary Agent-tool dispatches, recorded in the Team with
   `name`/`ref`/`transport_id` null.
4. **Check in.** Call `ListAgents` and match each spawned member's derived
   name. **Poll every 2 seconds, give up at 60 seconds** — fixed interval,
   not backoff; this is not configurable.
5. **Commit.** Build the `verified` member array (one object per roster
   member: `role`, `name`, `ref` from ListAgents, `route`, `model`, `effort`,
   `auto_mode`, `transport_id`, `checked_in`; subagent-routed members get
   `name`/`ref`/`transport_id` null and `checked_in` set now). Run
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

If you hit a genuinely ambiguous case here beyond a plain partial check-in —
a transport that silently no-ops, a member that comes up under an unexpected
name, anything the plan above doesn't cover — stop and report it upward
rather than improvising; spec 0001 §13 flags this area as a real escalation
candidate, not a place for invented judgment calls.

## `disband`

Run `roster.mjs disband`. It only removes `team.json` — it never kills panes
or sessions, since they may hold work that already cost tokens. Print the
member names and `transport_id`s it returns so the user can close them
themselves if they want to.

A stale Team (dead orchestrator pid, or older than the fixed 24h cap) is also
swept automatically on the next plain top-level SessionStart — that safety
net needs no action here.

## Check-in registry (`team.json`)

One active Team per repo, at `<hierarchyDir>/team.json` alongside
`peers.jsonl`/`gates.jsonl`. Once it exists, it is the **authoritative**
source for peer dispatch (ADR 0002): a SendMessage `to` or role lookup that
matches a Team member's derived name resolves from `team.json` first, before
the existing config-peer and live-roster fallbacks — those two paths are
unchanged and still cover the ad-hoc-peer case outside any Team.
