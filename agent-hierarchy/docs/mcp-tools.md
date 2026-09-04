# MCP tools

`plugin.json` registers agent-hierarchy's MCP server as `ah`
(`mcpServers.ah`), so every tool is addressed `mcp__ah__<tool>`. This page is
generated from [`mcp/server.mjs`](../mcp/server.mjs)'s tool list — that file
is the source of truth; if this page and the server ever disagree, the server
wins.

## If the `ah` server is not connected

**Always try the `mcp__ah__*` tool first — it is the preferred path.** Only
fall back when either: **(a) absent** — no `mcp__ah__*` tool appears in your
toolset; or **(b) failing** — a call to an `mcp__ah__*` tool returns an error
indicating the server is not connected / the tool is unavailable. Do not probe
first: there is no "test the connection" step, and no retry loop against the
MCP tool — the first real call either works or it doesn't, and a fallback that
costs one failed call is cheaper than a probe on every session. The CLI is a
last resort, not an equal alternative.

On trigger:

1. Read the **CLI equivalent** row for the tool you wanted, below. Do not
   guess argv from the MCP tool's JSON schema — parameter names and flag
   names are not guaranteed to match (snake_case tool params become
   kebab-case CLI flags, and a few are renamed outright — see the tables), and
   a wrong guess against `roster.mjs disband --close` is destructive. Running
   the script with no arguments, an unknown subcommand, or `--help` also
   prints its usage line as a second, self-describing discovery path if this
   table ever goes stale.
2. Run it with Bash: `node <plugin root>/hooks/<script>.mjs <subcommand> …`
   — **if, and only if, your own contract permits that.** This protocol
   grants no new capability to anybody:

   | Role | Frontmatter denials | Can run CLI? | Can Write a msg file? |
   | --- | --- | --- | --- |
   | architect | `NotebookEdit, Bash, advisor` | **No** (Bash denied) | Yes |
   | reviewer | `Edit, Write, NotebookEdit, advisor` | Not by frontmatter, but **No by contract** — see below | **No** (Write denied) |
   | implementor | `advisor` | Yes | Yes |
   | orchestrator | `advisor` | Yes | Yes |
   | ultra-advisor | `Edit, NotebookEdit, advisor` | Yes | Yes |
   | task-runner | allowlist `Read, Grep, Glob, Bash, WebFetch, WebSearch` | Yes | **No** (no Write) |

   **Architect** falls back by writing the response file directly with Write
   (the message format is a plain file; `msg.mjs new` is a convenience) and
   notes that in its report. **task-runner** can run any CLI form but cannot
   author a message file; it reports its result to its dispatcher instead,
   as it already does.

   **Reviewer has no self-serve fallback.** Its blocker is not a Bash
   denial — Bash is not in its `disallowedTools`. Its blocker is its
   contract: it never executes, and delegates every test/build/CLI run to
   the task-runner; Write and Edit are additionally denied, so it cannot
   author a message file either.
   - For a **read** it needs (`roster_show`, `msg_list`, `msg_index`, …):
     dispatch the task-runner with the exact CLI form from this page and
     reason over the compact report — its existing delegation path, no new
     mechanism.
   - For a **write** it needs (`msg_new` for its own response): it cannot
     produce the file. It delivers its report inline to whoever dispatched
     it and states in that report that the `ah` server is not connected and
     the response file was not written — the Orchestrator persists it. This
     is the once-per-session notice below doing double duty; no extra
     ceremony.
3. Say so **once per session**, not once per call — subsequent fallbacks in
   the same session are silent:
   - **Orchestrator / any top-level session:** tell the user directly, in
     your next user-facing message — one line covering (i) that the `ah` MCP
     server is not connected, (ii) that you're using the CLI equivalents so
     work isn't blocked, and (iii) the remedy: `/reload-plugins`, or restart
     the session (see [0024](./specs/0024-mcp-connect-failure-after-update.md)).
   - **A dispatched or peer role reporting upward:** one line in your
     report/response message. Don't address the user directly — the
     Orchestrator relays it if it judges the user should know.

   The notice is informational: it never blocks, never asks for confirmation,
   and is never a reason to stop work.

## `msg_*` — message-file exchanges

| Tool | Does | Mutates | CLI equivalent |
|---|---|---|---|
| `msg_new` | Create a request or response message file (`req_path`: the request's absolute path — a response then lands beside it, spec 0037) | yes | `node hooks/msg.mjs new --to <role> --from <role> --slug <slug> [--to-name <n>] [--from-name <n>] [--parent <id>] [--reason <r>] [--eta small\|medium\|large] [--type request\|response] [--id <id>] [--req <req_path>] [--team <name>] --cwd <path>` |
| `msg_list` | List exchanges (open/closed/all), optionally filtered by recipient | no | `node hooks/msg.mjs list [--closed\|--all] [--to <role>] [--team <name>] --cwd <path>` |
| `msg_downstream` | List requests dispatched by a session other than the one that rooted their parent chain | no | `node hooks/msg.mjs downstream [--root-name <name>] --cwd <path>` |
| `msg_index` | List a message file's `## [N] key` section anchors | no | `node hooks/msg.mjs index <path> --cwd <path>` |
| `msg_roster` | Show live/stale peer roster status | no | `node hooks/msg.mjs roster [--team <name>] --cwd <path>` |

Message-file format, frontmatter keys, and the dispatch/response gates these
tools implement are documented in
[docs/comms-protocol.md](./comms-protocol.md) — not restated here.

## `roster_*` — roster and team management

| Tool | Does | Mutates | CLI equivalent |
|---|---|---|---|
| `roster_show` | Show the resolved roster, or one level's raw file | no | `node hooks/roster.mjs show [--level global\|repo\|repo-user] [--team <name>] --cwd <path>` |
| `roster_teams` | List every team in the hierarchy dir | no | `node hooks/roster.mjs teams [--orchestrator-pid <pid>] --cwd <path>` |
| `roster_member` | Init a roster level, or add/edit/remove a member | yes | `node hooks/roster.mjs <init\|add\|edit\|remove> [--level <L>] [--role <role>] [--member <name>] [--model <m>] [--effort <e>] [--route peer\|subagent] [--auto-mode <a>] [--on-missing auto\|prompt\|never] [--layout auto\|columns\|grid] [--no-spawn] [--allow-global] [--orchestrator-pid <pid>] --cwd <path>` (`action` selects the subcommand; `auto_mode`→`--auto-mode`, `on_missing`→`--on-missing`, `no_spawn`→`--no-spawn`, `allow_global`→`--allow-global`, `orchestrator_pid`→`--orchestrator-pid`) |
| `roster_config` | Show or set a roster level's pane layout, or the repo's team-name alias | yes (when setting) | `node hooks/roster.mjs <layout\|alias> [--level <L>] [--layout auto\|columns\|grid] [--set <alias>] [--clear] [--team <name>] --cwd <path>` (`target` selects the subcommand) |
| `roster_create` | Plan, spawn, or commit a Team | yes | `node hooks/roster.mjs create --plan\|--spawn\|--commit [--team <name>] [--roster-level <L>] [--mode <layout_mode>] [--transport <t>] [--verified <json>] [--orchestrator-pid <pid>] [--session <orchestrator_session_id>] [--partial] --cwd <path>` (`mode`→`--<mode>`; `layout_mode`→`--mode`; `orchestrator_session_id`→`--session`; `roster_level`→`--roster-level`) |
| `roster_layout_splits` | Run or drive the herdr layout-splits phase | yes, unless `next`/dry-run | `node hooks/roster.mjs layout-splits [--mode <m>] [--pane-count <n>] [--next] [--created <json>] [--apply] [--target <id>] [--direction right\|down] --cwd <path>` (`pane_count`→`--pane-count`) |
| `roster_disband` | Plan, commit, or keep-sessions a Team teardown — non-destructive, never closes sessions | yes (registry only) | `node hooks/roster.mjs disband [--commit\|--keep-sessions] [--team <name>] --cwd <path>` (`mode`→flag) |
| `roster_disband_close` | **Close the live sessions of a Team** | **yes — destructive; requires prior user confirmation** | `node hooks/roster.mjs disband --close --confirm --plan-token <plan_token> [--team <name>] [--allow-global] --cwd <path>` |
| `roster_resync` | Re-derive every peer member's herdr location from live topology | yes, unless `dry_run` | `node hooks/roster.mjs resync [--dry-run] [--team <name>] [--bind <b>] --cwd <path>` |
| `roster_move` | Relocate a member's pane | yes, unless `dry_run` | `node hooks/roster.mjs move <name> [--tab <t>] [--split right\|down] [--new-tab] [--workspace <w>] [--new-workspace] [--dry-run] [--allow-global] [--team <name>] --cwd <path>` |
| `roster_history` | List recent team-history entries (for `create --from`) | no | `node hooks/roster.mjs history --cwd <path>` |
| `roster_spawn_one` | Spawn or restart one missing/dead peer role | yes, unless `dry_run` | `node hooks/roster.mjs spawn-one <role> [--member <name>] [--dry-run] [--allow-global] [--team <name>] [--orchestrator-pid <pid>] --cwd <path>` |
| `roster_dismiss` | Dismiss one member from a live team's check-in registry — does not close sessions | yes (registry only) | `node hooks/roster.mjs dismiss <name> [--commit] [--also-config] [--level <L>] [--team <name>] --cwd <path>` (`mode`→`--commit` flag; `also_config`→`--also-config`) |
| `roster_dismiss_close` | **Close one live team member's session** | **yes — destructive; requires prior user confirmation** | `node hooks/roster.mjs dismiss <name> --close --confirm --plan-token <plan_token> [--team <name>] [--allow-global] --cwd <path>` |
| `roster_adopt` | Re-stamp `orchestrator.pid` on an orphaned team — recovery only, refuses to hijack a live team | yes | `node hooks/roster.mjs adopt [--orchestrator-pid <pid>] [--team <name>] --cwd <path>` |
| `roster_reap` | List orphaned team records (plan, read-only), or remove them (commit) | yes, when `commit` | `node hooks/roster.mjs reap [--commit] --cwd <path>` (`mode`→`--commit` flag) |

Roster levels (`repo-user` > `repo` > `global`), resolution order, and the
per-member keys (`model`, `effort`, `route`, `auto_mode`) are documented in
[skills/agent-roster/SKILL.md](../skills/agent-roster/SKILL.md) — not
restated here.

## When to use MCP vs. the CLI

`msg.mjs`/`roster.mjs` (under `hooks/`) are the underlying implementation;
the MCP tools are thin wrappers around them. The MCP tools are the
**preferred read path** — `roster_show` in particular resolves worktree and
global-fallback levels that a hand-rolled `cat .claude/agent-hierarchy.json`
would miss (see the server's own `initialize` instructions). Reach for the
CLI only when MCP is unavailable, per the fallback protocol above.

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
