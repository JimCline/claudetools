# Troubleshooting

Symptom → likely cause → what to run.

| Symptom | Likely cause | What to run |
|---|---|---|
| MCP tools missing / `ah` server shows failed or disconnected | Four distinct shapes — run the diagnosis below, which tells you which one you have | `node <plugin root>/mcp/server.mjs --diag` |
| Peer is offline / a dispatch says no live peer | `peers.jsonl` liveness check (`kill(pid, 0)`) shows the peer as down or stale | `/hierarchy peers` to see the roster; `mcp__ah__team_spawn_one` to respawn just that role |
| Roster looks stale or the wrong members appear | Whole-level replace — a higher-precedence level is winning entirely, not merging. Precedence and resolution order are in [SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) | `mcp__ah__roster_show --level <level>` to inspect each level; `team_resync` to re-derive live topology |
| Team orphaned after the orchestrator session died | `team.json`'s `orchestrator.pid` points at a dead process | `mcp__ah__team_adopt` — recovery only, refuses to hijack a still-live team |
| Two checkouts / a worktree see different rosters | Worktree roster resolution — see [spec 0027](./specs/0027-worktree-roster-resolution.md) | Point `AGENT_HIERARCHY_DIR` at the same directory in both checkouts if you want them joined |
| Peers in different repos share no messages | Cross-repo limitation, documented in [README.md](../README.md) — different repos resolve different hierarchy dirs | Set `AGENT_HIERARCHY_DIR` to the same path in both sessions |
| A dispatch is denied for a missing `[hierarchy-msg]` pointer | The dispatch/response gate requires a message-file pointer in-band | Follow the deny text's `msg.mjs new` instructions — see [docs/comms-protocol.md](./comms-protocol.md) §5/§6 |
| Tier gate denies a dispatch | Dispatching Architect or Ultra-Advisor at or below your own model's tier | Do it inline, or set `reason: context\|second-opinion\|parallel` in the request file and re-issue |
| Usage report shows nothing, or looks smaller than expected | **Known limitation:** usage collection is `SubagentStop`-driven (`hooks/subagentstop-usage.mjs` requires an `agent_id`, i.e. a subagent). A **peer** is a separate top-level session, not a subagent, and never fires this hook — its token usage is not captured by `/hierarchy usage` at all | No workaround in this plugin; peer-routed work's token cost has to be read from that peer session directly |

## The `ah` server is disconnected

Run this first. It reads logs that already exist, starts nothing, and always
exits 0:

```
node <plugin root>/mcp/server.mjs --diag          # add --json for machine output
```

It prints one classified line per server process the harness has run in this
working directory, newest first, plus the plugin's own lifecycle log
(`~/.claude/hierarchy/mcp-server.log`, or `$AGENT_HIERARCHY_DIR/mcp-server.log`)
and the HTTP daemon's `/health`. The shape letter is the diagnosis:

The table is **transport-aware**: the harness owns a stdio child but does not own
the daemon, so under HTTP it never writes `Sending SIGINT` and every close line is
just the harness closing its own client — never evidence of anything.

| Shape | stdio logs | http logs | What it means | Remedy |
|---|---|---|---|---|
| **ok** | connected, and either still running or shut down by the harness | connected; any close line, or none | nothing wrong | — |
| **A** | `Starting connection` but never `Successfully connected` | same, with `ConnectionRefused` and nothing ever on the port | the handshake never completed: `node` not on the harness's PATH, a throw before `initialize`, a node too old; under http, no daemon and the SessionStart hook could not start one | check `exec` and `node` on the lifecycle log's `start` line, and its `exit`/`bind-error` events; then `claude --debug=mcp` and read `~/.claude/debug/<session-id>.txt` |
| **B** | connected, then a transport-closed line with **no** preceding `Sending SIGINT` | connected, and then a connection error (`ConnectionRefused` / `ECONNRESET` / `fetch failed` / `Connection failed`) **later in the same file** | it died mid-session — a handler throw, stdin EOF (stdio), or an external kill | find the `uncaught` / `unhandled` / `signal` line for that pid in the lifecycle log and paste it into an issue. A `signal` the log does not pair with a `stop` was not asked for by `--stop` |
| **C** | `Sending SIGINT` + `exited cleanly`, then a new connection seconds later; **also** a still-open session answering as an older version than the one installed | does not occur — the URL is constant, so there is no config change to drop the server over | the registered config changed (almost always a version bump), so the harness dropped the server | `/reload-plugins`. **Gone as of 0.72.0**: the server is registered at a constant `http://127.0.0.1:7434/`, so a version bump no longer changes the config — the daemon re-execs itself from the new install instead |
| **C′** | connected fine, then **every** tool call fails `exit=1 … Cannot find module …/hooks/*.mjs` | the same text, at most one request wide (the daemon replaces itself on the next request) | the old version's directory was deleted while its server was still running | restart the session; 0.72.0's daemon notices the new install on its next request and replaces itself |

The http **B** row is deliberately under-sensitive: no real mid-session daemon
death has been captured yet, and the harness's exact error text on a dropped
HTTP connection is only partly known. A daemon death also shows up in the
lifecycle log, which `--diag` prints whatever the classification says — so the
evidence is never only the shape letter. Note too that the harness's own
cold-start retry writes a `ConnectionRefused` **before** the handshake on every
hook-started daemon; only a failure after `Successfully connected` counts.

On this machine, at the time 0047 shipped, all 43 recorded connections were
shape **C** (30) or **ok** (13) — zero A, B, or C′. That is what phase 2 below
is aimed at.

### The daemon (0.72.0+)

`mcpServers.ah` is `{"type":"http","url":"http://127.0.0.1:${AH_MCP_PORT:-7434}/"}`
in both manifests. A SessionStart hook (`hooks/sessionstart-mcp-ensure.mjs`)
starts the daemon if nothing answers `/health`; it is silent on success and
prints one line only if the spawn itself fails.

The first session after an install connects on the harness's own retry, about
2 s in — the harness's connect attempt beats the hook's daemon by ~120 ms, fails
`ConnectionRefused`, and the retry succeeds unattended. Nothing to do.

A version bump is handled by the daemon replacing itself. A marketplace rename
or a cache relocation is not: the new install is no longer a sibling of the
running daemon's directory, so it takes a session restart (the same as before
0.72.0).

| Want to | Run |
|---|---|
| see what is running | `curl -s http://127.0.0.1:7434/health` or `--diag` |
| stop it | `node <plugin root>/mcp/server.mjs --stop` |
| run a dev checkout's daemon alongside the installed one | `AH_MCP_PORT=7435 claude --plugin-dir <checkout>` — without this a `--plugin-dir` session silently talks to the *installed* daemon |
| start it by hand | `node <plugin root>/mcp/server.mjs --http` |

The daemon is unauthenticated on 127.0.0.1, the same trust boundary the
`roster.mjs` / `msg.mjs` CLIs already sit behind: any process running as you can
drive it. It outlives individual sessions, holds no per-cwd state (every tool
takes `cwd`), and exits on `SIGTERM`.

If the daemon cannot run on a machine at all, the stdio loop is still there —
see [docs/mcp-tools.md](./mcp-tools.md).
