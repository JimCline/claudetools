# MCP tools

`plugin.json` registers agent-hierarchy's MCP server as `ah`
(`mcpServers.ah`), so every tool is addressed `mcp__ah__<tool>`. This page is
generated from [`mcp/server.mjs`](../mcp/server.mjs)'s tool list — that file
is the source of truth; if this page and the server ever disagree, the server
wins.

## When to use MCP vs. the CLI

`msg.mjs`/`roster.mjs` (under `hooks/`) are the underlying implementation;
the MCP tools are thin wrappers around them. The MCP tools are the
**preferred read path** — `roster_show` in particular resolves worktree and
global-fallback levels that a hand-rolled `cat .claude/agent-hierarchy.json`
would miss (see the server's own `initialize` instructions). Reach for the
CLI only when MCP is unavailable.

## `msg_*` — message-file exchanges

| Tool | Does | Mutates |
|---|---|---|
| `msg_new` | Create a request or response message file | yes |
| `msg_list` | List exchanges (open/closed/all), optionally filtered by recipient | no |
| `msg_downstream` | List requests dispatched by a session other than the one that rooted their parent chain | no |
| `msg_index` | List a message file's `## [N] key` section anchors | no |
| `msg_roster` | Show live/stale peer roster status | no |

Message-file format, frontmatter keys, and the dispatch/response gates these
tools implement are documented in
[docs/comms-protocol.md](./comms-protocol.md) — not restated here.

## `roster_*` — roster and team management

| Tool | Does | Mutates |
|---|---|---|
| `roster_show` | Show the resolved roster, or one level's raw file | no |
| `roster_teams` | List every team in the hierarchy dir | no |
| `roster_member` | Init a roster level, or add/edit/remove a member | yes |
| `roster_config` | Show or set a roster level's pane layout, or the repo's team-name alias | yes (when setting) |
| `roster_create` | Plan, spawn, or commit a Team | yes |
| `roster_layout_splits` | Run or drive the herdr layout-splits phase | yes, unless `next`/dry-run |
| `roster_disband` | Plan, commit, or keep-sessions a Team teardown — non-destructive, never closes sessions | yes (registry only) |
| `roster_disband_close` | **Close the live sessions of a Team** | **yes — destructive; requires prior user confirmation** |
| `roster_resync` | Re-derive every peer member's herdr location from live topology | yes, unless `dry_run` |
| `roster_move` | Relocate a member's pane | yes, unless `dry_run` |
| `roster_history` | List recent team-history entries (for `create --from`) | no |
| `roster_spawn_one` | Spawn or restart one missing/dead peer role | yes, unless `dry_run` |
| `roster_dismiss` | Dismiss one member from a live team's check-in registry — does not close sessions | yes (registry only) |
| `roster_dismiss_close` | **Close one live team member's session** | **yes — destructive; requires prior user confirmation** |
| `roster_adopt` | Re-stamp `orchestrator.pid` on an orphaned team — recovery only, refuses to hijack a live team | yes |

Roster levels (`repo-user` > `repo` > `global`), resolution order, and the
per-member keys (`model`, `effort`, `route`, `auto_mode`) are documented in
[skills/agent-roster/SKILL.md](../skills/agent-roster/SKILL.md) — not
restated here.

## The `msg.mjs` CLI

`hooks/msg.mjs`'s own usage line lists:

```
new | list | downstream | index | sweep | roster | route | global-scope
```

`new`, `list`, `downstream`, `index`, and `roster` back the `msg_*` MCP tools
above and share their semantics. The remaining three are not documented in
the CLI's own `--help`/usage output; from reading `hooks/msg.mjs` directly:

- **`sweep [--days 7]`** — archives closed request/response pairs whose
  response is older than N days (default 7) into `msgs/archive/`. Runs
  silently at session startup, or on demand via `/hierarchy sweep [days]`.
- **`route [peers|subagents|prefer-peers] --session <id>`** — with no value,
  prints this session's effective peer/subagent routing preference and where
  it came from (session record, config, or default); with a value, records
  it. Internal plumbing for the routing-preference gate described in
  [docs/comms-protocol.md](./comms-protocol.md); not currently exposed as a
  standalone `/hierarchy` subcommand (see `commands/hierarchy.md`'s
  `route` section for the still-supported inspection form).
- **`global-scope <roster|config> <allow|deny> --session <id>`** — records a
  one-shot gate answer (allow/deny reading or writing a *global*-level
  roster or config from this session), appended to `gates.jsonl`. Internal
  plumbing for the global-roster confirmation gate (spec
  [0009](./specs/0009-global-roster-confirm-gate.md)); no direct `/hierarchy`
  or MCP surface — the gate itself invokes it.

None of these three has an MCP wrapper.
