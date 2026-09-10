# Troubleshooting

Start here, whatever the symptom:

```
node <AH_ROOT>/hooks/roster.mjs doctor --cwd <abs cwd>
```

One read-only JSON object, one row per thing that can be wrong — version and
running root, install path, `CLAUDE_PID`, runtime dir, resolved config, team,
peers, hook errors in the last 24 h, hook syntax, and whether the checkout the
hooks run from is dirty. `--check` exits 1 when any row is red. `<AH_ROOT>` is
on this session's `ah CLI root` line; with no such line, resolve it with the
recipe in [cli-tools.md](./cli-tools.md).

Then: symptom → likely cause → what to run.

| Symptom | Likely cause | What to run |
|---|---|---|
| Anything at all, and you want one place to look first | — | `roster.mjs doctor --cwd <abs cwd>` (above); `--check` for a pass/fail exit |
| A hook seems to do nothing | a hook threw; Claude Code reports that only under `--debug` | the `hook-errors` row of `doctor`, or read `~/.claude/hierarchy/hook-errors.jsonl` |
| Team is gone after a reboot | by design: the team file is cleared once its orchestrator pid is dead | recreate the team through the `ah:agent-team` skill |
| A permission prompt appears for `node …/hooks/roster.mjs` | the plugin's allow hook is not running, or the path is not the installed one — see below | print the session's `ah CLI root:` line and compare it with the path you ran |
| Peer is offline / a dispatch says no live peer | `peers.jsonl` liveness check (`kill(pid, 0)`) shows the peer as down or stale | `/hierarchy peers` to see the roster; `roster.mjs spawn-one <role>` to respawn just that role |
| Roster looks stale or the wrong members appear | Whole-level replace — a higher-precedence level is winning entirely, not merging. Precedence and resolution order are in [SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) | `roster.mjs show --level <level>` to inspect each level; `roster.mjs resync` to re-derive live topology |
| Team orphaned after the orchestrator session died | `team.json`'s `orchestrator.pid` points at a dead process | `roster.mjs adopt --orchestrator-pid <pid>` — recovery only, refuses to hijack a still-live team |
| Two checkouts / a worktree see different rosters | Worktree roster resolution — see [spec 0027](./specs/0027-worktree-roster-resolution.md) | Point `AGENT_HIERARCHY_DIR` at the same directory in both checkouts if you want them joined |
| Peers in different repos share no messages | Cross-repo limitation, documented in [README.md](../README.md) — different repos resolve different hierarchy dirs | Set `AGENT_HIERARCHY_DIR` to the same path in both sessions |
| A dispatch is denied for a missing `[hierarchy-msg]` pointer | The dispatch/response gate requires a message-file pointer in-band | Follow the deny text's `msg.mjs new` instructions — see [docs/comms-protocol.md](./comms-protocol.md) §5/§6 |
| Tier gate denies a dispatch | Dispatching Architect or Ultra-Advisor at or below your own model's tier | Do it inline, or set `reason: context\|second-opinion\|parallel` in the request file and re-issue |
| Usage report shows nothing, or looks smaller than expected | **Known limitation:** usage collection is `SubagentStop`-driven (`hooks/subagentstop-usage.mjs` requires an `agent_id`, i.e. a subagent). A **peer** is a separate top-level session, not a subagent, and never fires this hook — its token usage is not captured by `/hierarchy usage` at all | No workaround in this plugin; peer-routed work's token cost has to be read from that peer session directly |

## The ah CLI

Every ah operation is `node <AH_ROOT>/hooks/roster.mjs <verb> --cwd <abs cwd>` or the same with
`msg.mjs` — see [docs/cli-tools.md](./cli-tools.md). There is no server to be disconnected as of
0.73.0 (spec 0048): a call either runs or prints node's own error in the Bash output.

**"I get a permission prompt for `node …/hooks/roster.mjs`."** The plugin's PreToolUse allow hook
(`hooks/pretooluse-ah-cli.mjs`) did not recognise the call. Either plugin hooks are disabled in this
session, or the path is not the installed root (or a sibling of it) — a copy under `/tmp`, or your
own checkout while the installed plugin lives in the cache. Print the session's `ah CLI root:` line
and run that exact path. A command with a `cd … &&` prefix, a pipe, a `$VAR` or a redirection is
also not recognised, by design. If you run without plugin hooks, use the settings allowlist in
[docs/cli-tools.md](./cli-tools.md#permission). A `dismiss`/`disband … --close` command always
prompts — that one is the close gate, and it is meant to.

**"`no orchestrator pid resolvable (CLAUDE_PID unset …)`."** The call is not running inside a Claude
Code Bash tool (a plain terminal, a CI job, a wrapper that strips the environment). Pass
`--orchestrator-pid <pid>` explicitly.

**"`Cannot find module …/hooks/roster.mjs`."** The version directory your context names was removed
by an update. Old and new version dirs normally coexist, so the old CLI keeps working until the
session ends; when it does not, start a new session and use the `ah CLI root:` line it prints.

After an update, the six things no unit test can see are in
[live-checks.md](./live-checks.md) — one line each, per machine.
