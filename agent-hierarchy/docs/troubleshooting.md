# Troubleshooting

Symptom → likely cause → what to run.

| Symptom | Likely cause | What to run |
|---|---|---|
| MCP tools missing / `ah` server shows failed or disconnected after a plugin update | Two distinct causes — see [spec 0024](./specs/0024-mcp-connect-failure-after-update.md) for the full diagnosis | Same-session failure right after an update: run `/reload-plugins`, or restart the session (stdio MCP servers don't auto-reconnect). Still failing in a **fresh** session: follow spec 0024's NEEDS-EVIDENCE steps (E1–E4) |
| Peer is offline / a dispatch says no live peer | `peers.jsonl` liveness check (`kill(pid, 0)`) shows the peer as down or stale | `/hierarchy peers` to see the roster; `mcp__ah__roster_spawn_one` to respawn just that role |
| Roster looks stale or the wrong members appear | Whole-level replace — a higher-precedence level is winning entirely, not merging. Precedence and resolution order are in [SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) | `mcp__ah__roster_show --level <level>` to inspect each level; `roster_resync` to re-derive live topology |
| Team orphaned after the orchestrator session died | `team.json`'s `orchestrator.pid` points at a dead process | `mcp__ah__roster_adopt` — recovery only, refuses to hijack a still-live team |
| Two checkouts / a worktree see different rosters | Worktree roster resolution — see [spec 0027](./specs/0027-worktree-roster-resolution.md) | Point `AGENT_HIERARCHY_DIR` at the same directory in both checkouts if you want them joined |
| Peers in different repos share no messages | Cross-repo limitation, documented in [README.md](../README.md) — different repos resolve different hierarchy dirs | Set `AGENT_HIERARCHY_DIR` to the same path in both sessions |
| A dispatch is denied for a missing `[hierarchy-msg]` pointer | The dispatch/response gate requires a message-file pointer in-band | Follow the deny text's `msg.mjs new` instructions — see [docs/comms-protocol.md](./comms-protocol.md) §5/§6 |
| Tier gate denies a dispatch | Dispatching Architect or Ultra-Advisor at or below your own model's tier | Do it inline, or set `reason: context\|second-opinion\|parallel` in the request file and re-issue |
| Usage report shows nothing, or looks smaller than expected | **Known limitation:** usage collection is `SubagentStop`-driven (`hooks/subagentstop-usage.mjs` requires an `agent_id`, i.e. a subagent). A **peer** is a separate top-level session, not a subagent, and never fires this hook — its token usage is not captured by `/hierarchy usage` at all | No workaround in this plugin; peer-routed work's token cost has to be read from that peer session directly |
