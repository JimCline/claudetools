# The team file

A message's frontmatter names two absolute paths: `team_file`, the live Team this
exchange belongs to, and `team_guide`, this document. Read this when you hold a
`team_file` path and need to know what to do with it.

## What it is

One JSON file per live Team — `<hierarchy dir>/teams/<name>.json`, or the legacy
`<hierarchy dir>/team.json`. It is the authoritative record of who is on the Team:
the orchestrator that owns it and every member, under the names they are addressed by.
The message pool is its sibling: `<hierarchy dir>/msgs/`.

The path in the message is absolute on purpose. Every other way of finding the team
file derives it from the session's cwd, and a cwd inside a git worktree or another
repo resolves to a different hierarchy dir with no Team in it. **When the cwd-derived
answer and `team_file` disagree, `team_file` is right.**

## What is in it

| field | meaning |
|---|---|
| `team_id` | identifies this Team instance |
| `orchestrator.pid` | the owning session's process; dead pid = orphaned Team |
| `expected_root` | the directory members' sessions should be running in |
| `roster_level` | which roster level the Team was stood up from (`null` for an ad hoc one) |
| `roster` | which roster block it was built from: `rosters.<roster>`, or `null` for the default `roster` block (and for a Team replayed from history). A file without the field predates it and is read by the old rule, `rosters.<team name>` then the default |
| `layout` | the Team's pane layout, `auto`, `columns` or `grid`; later `spawn-one` panes use it. A file without it uses `auto` |
| `transport` | `herdr`, `tmux`, or `terminal` |
| `partial` | true when some member never checked in — the Team is degraded |
| `members[]` | one row per member: `role` (a built-in, or a custom role name from `roster.mjs role list`), `name`, `route`, `model`, `effort`, `autoMode`, `transport_id` (its pane); `kind` and `args` only for a non-Claude member; `tab_id`/`workspace_id` under herdr |

`members[].name` is the address: it is the `to` of a SendMessage and the `--to-name`
of `msg.mjs new`. It is `<team name>-<role>[-N]`: for `teams/<name>.json` the team name
is `<name>`; the legacy `team.json` records none, so its name is read off its own members
(the first whose name ends in `-<its role>`), never recomputed from config.

## How a session knows its Team

Every member the launcher starts is given this file's absolute path as `AH_TEAM_FILE`
(through `claude --settings`, so its hooks and its Bash commands all see it). A session's
Team is resolved in this order: the Team it owns as orchestrator; else `AH_TEAM_FILE`,
accepted only when it names `<hierarchy dir>/teams/<name>.json` or `<hierarchy dir>/team.json`
of this repo (or its main checkout); else the one live Team whose member row holds this
session's pane. `whoami` says which answered (`answered_by`) and reports a rejected
`AH_TEAM_FILE` in `env_team_invalid`, as another repo's team file or as malformed.

## What to do with it

- **Read it; never edit it.** Every write goes through `roster.mjs` (`spawn-one`,
  `spawn-ad-hoc`, `dismiss`, `disband`, `untrack`, `resync`, `move`, `adopt`).
- **Find a teammate's name or role:** read `members[]`.
- **Find who to reply to:** the brief's `reply-to` is authoritative. If it is lost,
  `roster.mjs whoami` derives the orchestrator's address from this file.
- **Run a CLI verb against this Team from a drifted cwd:** pass
  `--cwd <expected_root>` so the verb resolves the same hierarchy dir this file is in,
  plus `--team <name>` when the file is `teams/<name>.json`.
- **Reply to a request:** `msg.mjs new --type response --id <id> --req <request path>`
  writes the response beside the request, in this Team's pool, whatever your cwd is.
- **A gate says it found no team record, or that a file is outside the message pool:**
  compare the directory it names with the directory of `team_file`. If they differ,
  your cwd has moved; the message and the Team are fine.

`team_file: null` means the message was written where no team file existed — an
exchange outside any Team. There is nothing to look up.
