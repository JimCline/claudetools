---
name: agent-roster
description: Define, edit, or inspect the agent-hierarchy ROSTER — the template of which roles exist and their model/effort/route/kind. Use for /agent-roster, for "add a reviewer peer", "add a peer to the roster", "change the architect's model", "remove a role from the roster", "what's in my roster", or "set up a roster". Standing up, reshaping, or tearing down a LIVE Team is the agent-team skill, not this one.
---

# agent-roster

The roster is a `roster` block in the existing `agent-hierarchy.json` config,
at one of three levels (§ Levels below). `${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs` does all the file I/O and
validation; this skill is the interactive prose surface that drives it — do
not hand-edit the JSON, and do not duplicate its validation here.

**Roster vs. Team — the roster is definitions, a Team is an instance created
FROM it.** If a roster already exists (check `roster.mjs show`) and you just need
a live Team — including at a worktree, which usually inherits the repo's
existing roster — this is the wrong skill: invoke `ah:agent-team` and go
straight to its § Create. You do NOT need to add/edit/remove roster members
first; that's only for changing WHO belongs on
the roster (a template edit), not for bringing a Team up from one that
already fits. Only reach for `add`/`edit`/`remove` when the roster itself is
wrong or missing for this level.

**This skill is the TEMPLATE half.** A roster is definitions; a Team is a live
instance created FROM it. Editing the roster changes what FUTURE teams look
like and does not touch a running one — `roster.mjs` refuses a roster edit
outright while this session owns a live Team (spec 0044 §1.3). Standing up,
reshaping, or tearing down a live Team is the `ah:agent-team` skill.

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
losing level does not appear. To inspect the roster run `node ${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs show --cwd <abs cwd>`; never read `.claude/agent-hierarchy.json` directly — it misses the worktree/main-checkout and global fallback resolution that `show` implements. With no
`--level`/`level` argument it always prints the resolved (winning) roster;
with one, it prints that level's raw file and says if it's shadowed.
The ah CLI is the only interface: every roster/team/message operation is a Bash call to `node ${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs <verb> … --cwd <abs cwd>` or `node ${CLAUDE_PLUGIN_ROOT}/hooks/msg.mjs <verb> … --cwd <abs cwd>`. That placeholder reaches you resolved; if it is still literal, the `ah CLI root` line in your context is authoritative — when two disagree, the newest wins. Verb reference: `agent-hierarchy/docs/cli-tools.md`. Output is always JSON; a non-zero exit says why on stdout/stderr.

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

Every verb below runs as `node ${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs <verb> … --cwd <abs cwd>`
through the Bash tool — `${CLAUDE_PLUGIN_ROOT}` from this session's `ah CLI root` line, which is
authoritative when it and the placeholder disagree; with two such lines, the newest wins.
`docs/cli-tools.md` is the single source of truth for the full verb/flag surface;
the bullets below are this skill's operational notes on top of it.

All CLI subcommands run via `node "${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs" <cmd> ...`
with `--cwd "$(pwd)"` (or the relevant repo path). Level may be given as
`--level <L>` or as the first bare word: `roster.mjs add repo --role architect`
≡ `--level repo`.

`--team <name>` (spec 0011) selects the `rosters.<name>` roster block instead
of the default one, so a repo can keep more than one template. Omitted,
everything is the default roster exactly as before — most sessions never pass
it.

- `show [--level global|repo|repo-user]` — resolved roster, or one level's raw file.
- `init --level <L> --route <peer|subagent> [--layout auto|columns|grid]` — replaces that level's roster wholesale.
- `add --role <R> [--level L] [--model M] [--effort E] [--route peer|subagent|pane] [--kind K] [--args '<json>'] [--auto-mode A]` — writes the template row and **spawns nothing** (spec 0044 §1.10, superseding 0039). To start the member afterwards, that is `/agent-team`'s job: `spawn-one <role>` for a roster-conforming one, `spawn-ad-hoc` for a divergent or ad hoc one.
- `edit --member <NAME> [--level L] [--role R] [--model M] [--effort E] [--route ...] [--auto-mode A]`
- `remove --member <NAME> [--level L]` — edits the
  roster **template**, not a live Team; `/agent-team`'s `dismiss` is the live-Team equivalent.
- `layout [--level <L>] [--layout auto|columns|grid]` — show or set the team-wide pane layout.
- `alias [--level global|repo|repo-user] [--set <name>] [--clear] [--cwd <path>]` — read, set, or
  clear the repo's `teamAlias` (the team-prefix members are named under). No `--set`/`--clear`
  reads the currently-effective alias; `--level` is required with `--set`/`--clear` when it can't
  be inferred from an already-resolving roster. Never accepts `--level global` — an alias is
  repo-scoped. `--set`/`--clear` refuse while `--team` is active (the team name already is
  that team's prefix); `alias` (read-only) reports both the config alias and the active team
  scope, distinguished.

`add`/`edit`/`remove` with no `--level` operate on whichever level currently
resolves (repo-user > repo > global) and print which level they picked — say
that back to the user in one line. If no roster resolves anywhere, the CLI
errors pointing at `init`; run `init` first (asking the user per § Init below).

Roles: `architect`, `implementor`, `reviewer`, `task-runner`, `ultra-advisor`.
`orchestrator` is rejected by the CLI — the Orchestrator is whatever session
runs `create`, never a roster entry.

**Everything that touches a LIVE Team lives in the `ah:agent-team` skill** —
`create`, `spawn-one`, `spawn-ad-hoc`, `dismiss`, `disband`, `adopt`, `move`,
`resync`, `reap`, `teams`, `history`, `checkin`. `/agent-roster <those>` still
works and behaves identically (a permanent alias, spec 0044 §8.3), but this
skill does not document them: if the request is about a running Team rather
than about which roles the template defines, invoke `ah:agent-team`.

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
   effort, and auto-mode. The auto-mode options are exactly `auto
   (Recommended)`, `acceptEdits`, `plan`, and `default (none)` —
   `bypassPermissions` is never offered, and is accepted only if the user
   types it into Other. Prefill/offer defaults from `ROLE_DEFAULTS` in
   `hooks/lib-config.mjs` — do not invent separate defaults here. For each
   picked role, run `roster.mjs add --level <L> --role <role>
   [--model ...] [--effort ...] [--auto-mode ...]`. `add` writes config and
   nothing else (spec 0044 §1.10), so this flow adds every role and then
   spawns once, at `create --spawn` — no per-add flag is needed to hold the
   spawn back, and none should be passed. A role can be added more than once —
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

`add` auto-creates a minimal roster when none exists (spec 0038) — repo level
when inside a git repo, or the explicit `--level` — and says so with the
file's path. `init` is for choosing a full role set interactively, not a
prerequisite. The one exception is `--team <X>`: a named team's container is
still created only by `init --team X` (0032 §3.4b), so `add --team X` against
no such container keeps erroring.

**`add` writes the roster and stops** (spec 0044 §1.10, an explicit
supersession of spec 0039's auto-spawn). It launches nothing, whatever the
member's route or kind, and returns no `spawn` field — it edits a template
for future Teams. Report what was written and, from its `next_step`, which
command starts the member:

- roster-conforming member → `spawn-one <role>` (§ spawn-one, on `/agent-team`).
- divergent or ad hoc member → `spawn-ad-hoc` (§ spawn-ad-hoc, on `/agent-team`).

Do not reach for `add` when what the user wants is a member of the *running*
team. Editing the roster does not change a live Team, and if you own a live
Team the CLI will refuse the edit outright and name `spawn-ad-hoc` instead
(spec 0044 §1.3). That refusal is not an obstacle to route around: the
`--allow-roster-edit` override is the **user's**, never one an agent adds to
get its call through.

`--no-spawn` (`no_spawn: true` on `roster.mjs add`) is still accepted and does
nothing at all — it is a no-op kept only so existing scripts do not break
(§1.10 R1). Do not pass it, and do not read it as evidence that spawning is
otherwise what happens.

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

### `--kind`: non-Claude members (spec 0043)

`--kind <k>` (`kind` on `roster.mjs add`) picks which agent CLI Herdr starts
for this member. **Omitted means `claude`**, including for every roster file
written before this key existed, and an explicit `--kind claude` is not
written to the file at all — the default is total.

Herdr owns the list of installed kinds and it differs per machine and per
Herdr version, so this codebase validates only the *shape*
(`[a-z][a-z0-9-]*`) and never a membership list. An unknown kind is accepted
at `add` and fails at spawn with Herdr's own error, unmodified. Run
`herdr agent` to see what an install actually has.

Choosing a non-claude kind changes four things, all enforced at `add`/`edit`:

| field | requirement |
|---|---|
| `route` | must be `pane` — `peer` and `subagent` are hard errors |
| `model` / `effort` / `auto-mode` | must be absent — they are literally the `--model`/`--effort`/`--permission-mode` Claude CLI flags and mean nothing to another CLI |
| `args` | optional; native CLI arguments, passed verbatim after Herdr's `--` |
| transport | spawning needs a Herdr session (`HERDR_ENV=1`); `add`/`edit` still work anywhere |

`--args '<json-array>'` (`args` on `roster.mjs add`, a real array there) is the
*only* way a non-claude member gets flags, since the three Claude flags are
rejected for it. Each element is one argument and is shell-quoted before it
reaches the launch line. `args` is a **hard error for `kind: claude`** — for a
Claude member the validated `--model`/`--effort`/`--auto-mode` already fill
that slot, and a second unvalidated channel would let
`args: ["--model","haiku"]` defeat the ultra-advisor top-tier rule. It is
rejected at `add`/`edit` and again at spawn, so a hand-edited config file
cannot slip past.

There is no pre-screen for whether an `args` value keeps the agent
interactive, and none is possible across 21 CLIs. A flag that makes the target
run and exit produces a Herdr startup timeout; the failure names the args as
the likely cause and reports the orphaned pane id with `herdr pane close` as
the remedy. The pane is **not** closed automatically — it holds the agent's
own output, which is usually the only explanation of what went wrong.

A member's `role` still picks its derived name and its roster slot, but the
role's `agents/*.md` contract is **not** loaded into a non-Claude agent. Put
whatever the role would have told it into the prompt instead.

