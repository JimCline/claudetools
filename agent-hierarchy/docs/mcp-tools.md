# MCP tools

`plugin.json` registers agent-hierarchy's MCP server as `ah`
(`mcpServers.ah`), so every tool is addressed `mcp__ah__<tool>`. Since 0.72.0
that registration is an HTTP URL — `http://127.0.0.1:${AH_MCP_PORT:-7434}/` — and
the server is a per-user daemon a SessionStart hook starts on demand, rather
than a per-session stdio child (spec 0047). The URL is a constant, so a version
bump no longer changes the config and no longer costs you a `/reload-plugins`;
the daemon notices the new install and re-execs itself from it. The first
session after an install connects on the harness's own retry, about 2 s in, with
nothing to do. A marketplace rename or a cache relocation still needs a session
restart — the new install is no longer a sibling of the running daemon's
directory, so the daemon does not replace itself for it. This page is
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
     work isn't blocked, and (iii) the remedy: run
     `node <plugin root>/mcp/server.mjs --diag` and paste its output — it
     classifies the failure and names the fix — falling back to
     `/reload-plugins` or restarting the session (see
     [0024](./specs/0024-mcp-connect-failure-after-update.md),
     [0047](./specs/0047-mcp-stability.md) and
     [troubleshooting](./troubleshooting.md#the-ah-server-is-disconnected)).
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

## `roster_*` / `team_*` — roster and team management

| Tool | Does | Mutates | CLI equivalent |
|---|---|---|---|
| `roster_show` | Show the resolved roster, or one level's raw file | no | `node hooks/roster.mjs show [--level global\|repo\|repo-user] [--team <name>] --cwd <path>` |
| `team_list` | List every team in the hierarchy dir | no | `node hooks/roster.mjs teams [--orchestrator-pid <pid>] --cwd <path>` |
| `roster_init` | Replace a roster level wholesale | yes | `node hooks/roster.mjs init --level <L> --route peer\|subagent\|pane [--layout auto\|columns\|grid] --cwd <path>` |
| `roster_add` | Add a member row to the roster TEMPLATE (spawns nothing) | yes | `node hooks/roster.mjs add --role <role> [--level <L>] [--model <m>] [--effort <e>] [--route peer\|subagent\|pane] [--auto-mode <a>] [--on-missing auto\|prompt\|never] [--kind <k>] [--args <json-array>] --cwd <path>` (`auto_mode`→`--auto-mode`, `on_missing`→`--on-missing`) |
| `roster_edit` | Edit a roster TEMPLATE member row | yes | `node hooks/roster.mjs edit --member <NAME> [--level <L>] [--role <role>] [--model <m>] [--effort <e>] [--route ...] [--auto-mode <a>] [--on-missing <o>] [--kind <k>] [--args <json-array>] --cwd <path>` |
| `roster_remove` | Remove a roster TEMPLATE member row | yes | `node hooks/roster.mjs remove --member <NAME> [--level <L>] --cwd <path>` |
| `roster_layout` | Show or set a roster level's pane layout | yes (when setting) | `node hooks/roster.mjs layout [--level <L>] [--layout auto\|columns\|grid] --cwd <path>` |
| `roster_alias` | Show, set, or clear the repo's team-name alias | yes (when setting) | `node hooks/roster.mjs alias [--level <L>] [--set <alias>] [--clear] [--team <name>] --cwd <path>` |
| `team_create` | Plan, spawn, or commit a Team | yes | `node hooks/roster.mjs create --plan\|--spawn\|--commit [--team <name>] [--roster-level <L>] [--mode <layout_mode>] [--transport <t>] [--verified <json>] [--orchestrator-pid <pid>] [--session <orchestrator_session_id>] [--partial] --cwd <path>` (`mode`→`--<mode>`; `layout_mode`→`--mode`; `orchestrator_session_id`→`--session`; `roster_level`→`--roster-level`) |
| `team_layout_splits` | Run or drive the herdr layout-splits phase | yes, unless `next`/dry-run | `node hooks/roster.mjs layout-splits [--mode <m>] [--pane-count <n>] [--next] [--created <json>] [--apply] [--target <id>] [--direction right\|down] --cwd <path>` (`pane_count`→`--pane-count`) |
| `team_disband` | **Close every member's session** and drop the team record | `mode:plan` no; `mode:close` **yes — destructive; requires prior user confirmation** | `node hooks/roster.mjs disband [--close --confirm --plan-token <t>] [--team <name>] [--allow-global] --cwd <path>` (`mode:close`→`--close`. To forget the record without closing anything, use `team_untrack --all`.) |
| `team_resync` | Re-derive every peer member's herdr location from live topology | yes, unless `dry_run` | `node hooks/roster.mjs resync [--dry-run] [--team <name>] [--bind <b>] --cwd <path>` |
| `team_move` | Relocate a member's pane | yes, unless `dry_run` | `node hooks/roster.mjs move <name> [--tab <t>] [--split right\|down] [--new-tab] [--workspace <w>] [--new-workspace] [--dry-run] [--allow-global] [--team <name>] --cwd <path>` |
| `team_history` | List recent team-history entries (for `create --from`) | no | `node hooks/roster.mjs history --cwd <path>` |
| `team_spawn_one` | Spawn or restart one missing/dead peer role | yes, unless `dry_run` | `node hooks/roster.mjs spawn-one <role> [--member <name>] [--dry-run] [--allow-global] [--team <name>] [--orchestrator-pid <pid>] --cwd <path>` |
| `team_spawn_ad_hoc` | Spawn a member that is NOT in the roster — a divergent or one-off role; writes the team file only, never the roster | yes, unless `dry_run` | `node hooks/roster.mjs spawn-ad-hoc <role> [--model <m>] [--effort <e>] [--kind <k>] [--route <r>] [--args '[...]'] [--auto-mode <m>] [--on-missing <o>] [--dry-run] [--allow-global] [--team <name>] [--orchestrator-pid <pid>] --cwd <path>` |
| `team_dismiss` | **Close one live team member's session** and drop its row | `mode:plan` no; `mode:close` **yes — destructive; requires prior user confirmation** | `node hooks/roster.mjs dismiss <name> [--close --confirm --plan-token <t>] [--also-config] [--level <L>] [--team <name>] [--allow-global] --cwd <path>` (`mode:close`→`--close`; `also_config`→`--also-config`; `name` accepts a member name, pane_id, session_id or 8+ char prefix, `role@sid8`, or a herdr display name — spec 0046 §2.4) |
| `team_untrack` | Forget a member row or a whole team record **without touching any session** | yes (registry only) | `node hooks/roster.mjs untrack <name>\|--all [--plan\|--commit] [--keep-sessions] [--also-config] [--level <L>] [--team <name>] --cwd <path>` (`all`→`--all`; `keep_sessions`→`--keep-sessions`, required for a live or unknown-liveness target) |
| `team_adopt` | Re-stamp `orchestrator.pid` on an orphaned team — recovery only, refuses to hijack a live team | yes | `node hooks/roster.mjs adopt [--orchestrator-pid <pid>] [--team <name>] --cwd <path>` |
| `team_reap` | List orphaned team records (plan, read-only), or remove them (commit) | yes, when `commit` | `node hooks/roster.mjs reap [--commit] --cwd <path>` (`mode`→`--commit` flag) |

Roster levels (`repo-user` > `repo` > `global`), resolution order, and the
per-member keys (`kind`, `model`, `effort`, `route`, `auto_mode`, `args`) are documented in
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

## If the daemon cannot run at all

The stdio server is still the same file and still works: run `mcp/server.mjs`
with no arguments and it speaks newline-delimited JSON-RPC on stdin/stdout,
exactly as it did before 0.72.0. To register it that way for one project,
bypassing the plugin's HTTP registration:

```
claude mcp add ah -- node <plugin root>/mcp/server.mjs
```

The name collides with nothing — plugin servers are namespaced `plugin:ah:ah` —
and every tool, schema and output is identical. What you give up is what the
daemon buys: the harness will not reconnect a stdio server, so a version bump
costs a `/reload-plugins` again.
