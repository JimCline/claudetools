# Agent Hierarchy

Configures and runs a team of Claude Code agents (Orchestrator, Architect, Implementor, Reviewer, Task-Runner) that collaborate on a repo, either as peer sessions or as spawned subagents.

## Language

**Roster**:
The configured set of team members for a repo — which roles exist, how many of each, and each member's model/effort/route/auto-mode.
_Avoid_: config, team definition

**Roster level**:
One of three places a roster can be defined: **global** (user-wide, applies across all projects), **repo** (stored inside the repo), or **repo-user** (user-scoped, stored outside the repo but mapped to it). Precedence when resolving which roster applies to a repo: repo-user > repo > global.
_Avoid_: scope, tier

**Whole-level replace**:
The resolution rule for roster levels — the highest-precedence level that has a roster defined is used in its entirety; levels are never merged member-by-member.

**Route**:
Whether a roster member's role is dispatched as a **peer** (a separate live Claude Code session, reached via SendMessage) or a **subagent** (spawned in-process via the Agent tool). Set as a team-wide default at roster init, overridable per member.
_Avoid_: mode, dispatch type

**Auto-mode**:
A roster member's Claude Code permission mode (e.g. default / acceptEdits / plan / auto) — how autonomously that member's spawned session runs tool calls.
_Avoid_: handoff mode (that's a separate, existing `/hierarchy` setting — confirm vs. auto dispatch by the Orchestrator)

**Orchestrator**:
The single coordinating role, always exactly one per team. It has no roster entry — it's whatever session invokes `/agent-team create`, running as that session's own model/effort/permission mode.

**Team**:
A running instantiation of a Roster — the actual spawned sessions (peer panes and/or subagents) for one work session, created by `create`. Every Team has its own file: `teams/<name>.json`, named for the team, which is also its members' name prefix. Nothing writes the shared `team.json` any more; one that already exists is read and operated on until its team disbands, never migrated (spec 0044 §1.1/§1.7).
_Avoid_: session group

**Two entry points, one implementation (spec 0044 §8)**:
`/agent-roster` (skill `ah:agent-roster`) edits the **template**: `init`, `add`, `edit`, `remove`, `layout`, `alias`, `show`. `/agent-team` (skill `ah:agent-team`) operates the **instance**: `create`, `spawn-one`, `spawn-ad-hoc`, `dismiss`, `disband`, `untrack`, `adopt`, `move`, `resync`, `reap`, `teams`, `history`, `checkin`. The dividing test is mechanical and identical to §1.5's: a command belongs to `/agent-roster` if and only if writing a roster level file is its purpose. `roster.mjs` stays the single implementation — there is no second CLI, no second team-creation path, no second spawn builder. `/agent-roster <lifecycle command>` remains a **permanent** forwarding alias with identical behaviour (not a deprecation), and `pretooluse-roster-skill-gate.mjs` covers both surfaces; what changed is only what each skill *lists*, because an agent chooses its command from the menu it is shown.

**Read-only roster (spec 0044)**:
The Roster is a TEMPLATE and is read-only for the whole team lifecycle — this is enforced, not advised. Creating, populating, operating or tearing down a Team never writes a roster level file, and *divergence from the roster must never reach a roster write*: spawning a member whose model, effort, kind, route or args differ from the roster's, or whose role the roster does not define, writes only the team file. There is no divergence severity at which a roster write becomes correct.

Three things make that hold rather than merely state it:
- `init`/`add`/`edit`/`remove`/`layout`/`alias` are the only roster writers, and a session that owns a live Team is **refused** them (§1.3). The refusal names `spawn-ad-hoc`. Its `--allow-roster-edit` override is the user's — no agent may add it to get a call through.
- `spawn-ad-hoc` (§1.4) spawns a divergent or ad hoc member into the team file, through the same launch path as `spawn-one`. It exists because an agent asked for a member the roster does not describe previously had no non-roster-writing option.
- `add` writes the config row and **spawns nothing** (§1.10, superseding spec 0039). While one command both edited the template and produced a live member, the boundary was one rationalization away from being crossed.

**Check-in registry**:
A per-team, disk-persisted file recording each live member's name/address once the Orchestrator has verified the whole Team is up. Scoped to one Team's lifetime; removed on disband. Distinct from `peers.jsonl`, the longer-lived cross-session liveness log.
_Avoid_: peers.jsonl, roster (this is per-team, not per-repo-config)

**Disband**:
Tearing down a Team's **Check-in registry**. Triggered either by an explicit command, or by a safety-net cleanup sweep for abandoned/stale team files.

## Relationships

- A **Roster** is defined at exactly one **Roster level** at a time per repo, chosen by precedence (repo-user > repo > global) under **Whole-level replace**.
- Each roster member has a **Route** (peer or subagent), defaulted team-wide and overridable per member, and an **Auto-mode**.
- The **Orchestrator** is not a roster member; every other role can have multiple members in the roster.
- `/agent-team create` instantiates a **Roster** into a **Team**; the Orchestrator verifies the Team is up and writes its **Check-in registry**.
- Once a **Team**'s **Check-in registry** exists, it is the authoritative dispatch source for that Team's peer members; `ListAgents` name-matching remains only as the fallback for ad-hoc peers outside any Team.
- `/hierarchy` (on/off, handoff flow) triggers **Initial setup** — the peer-vs-subagent question, then `/agent-roster init` if no **Roster** resolves at any **Roster level** — when turning the hierarchy on with no existing Roster. `/agent-roster` otherwise owns all Roster/member config; `/hierarchy` no longer touches it.
