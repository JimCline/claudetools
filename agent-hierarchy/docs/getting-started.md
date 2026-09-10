# Getting started

Zero to a running team, in the order you'll actually do it.

## 1. Prerequisites

Node only; `herdr` is optional — see
[README.md#prerequisites](../README.md#prerequisites) for the fallback chain.

## 2. Install

```
/plugin marketplace add JimCline/claudetools
/plugin install ah@claudetools
```

`ah` is the plugin's short name (`agent-hierarchy` is the directory it ships
from — see the root [marketplace.json](../../.claude-plugin/marketplace.json)).

## 3. `/hierarchy init`

Run `/hierarchy init` once. The wizard turns the hierarchy on and sets its
handoff flow (`auto` or `confirm`), at either user scope
(`~/.claude/agent-hierarchy.json`) or project scope
(`<repo>/.claude/agent-hierarchy.json`, committable).

**The one thing every new user gets wrong:** `/hierarchy init` does **not**
define who's on the roster or what model they run. That's a separate step —
`/agent-roster` — and `/hierarchy init` hands off into it automatically when
no roster exists yet.

## 4. Defining a roster

`/agent-roster init` sets the roster's route (peer or subagent) and layout,
then `/agent-roster add` adds a member per role. Each member has these keys:

- `kind` — which agent CLI Herdr starts for this member. Omitted means
  `claude`, and that stays true for every roster written before this key
  existed. Any other value (`codex`, `pi`, … — Herdr owns the list; run
  `herdr agent` to see what your install has) makes the member a *non-Claude*
  agent, which changes the four keys below.
- `model` — which model that role runs on. **`kind: claude` only.**
- `effort` — reasoning effort, where the model supports it. **`kind: claude` only.**
- `route` — `peer` (a separate live session, reached with SendMessage),
  `subagent` (spawned in-process by the Agent tool), or `pane` (driven through
  its Herdr pane). A non-claude kind **must** be `pane`.
- `auto_mode` — the spawned session's permission mode. **`kind: claude` only.**
  `auto` (`--permission-mode auto`) is the hands-off mode. `bypassPermissions`
  is still accepted, but that session can get stuck at a startup confirmation
  screen instead of coming up ready — prefer `auto`.
- `args` — native CLI arguments passed verbatim to the agent. **Non-claude
  kinds only** — for a Claude member, `model`/`effort`/`auto_mode` are the
  validated way to set flags, and `args` would bypass that validation.

`model`, `effort` and `auto_mode` are literally Claude Code CLI flags
(`--model`, `--effort`, `--permission-mode`), which is why they are *rejected*
rather than ignored for another kind: a setting that silently affects nothing
is worse than one that refuses.

A non-claude member requires a Herdr session (`HERDR_ENV=1`) to spawn — tmux
and terminal transports can only start `claude`. Adding one from a non-Herdr
session still works (rosters are portable); only spawning it needs Herdr.

Value spaces and validation rules are in
[SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) and
[SKILL.md — `add` / `edit` / `remove`](../skills/agent-roster/SKILL.md#add--edit--remove).

## 5. Spawning a team

`/agent-roster create` spawns the resolved roster as a live **Team** — a
Roster is the definition, a Team is the running instantiation of it (see
[CONTEXT.md](../CONTEXT.md) for the exact distinction). Layout confirmation
is asked every time, `auto` or `manual` alike — `auto` only skips the
per-member placement prompt; `manual` walks you through each member's
placement individually.

## 6. The first dispatch

This is the part that makes the model click. Say the Orchestrator (your
session) needs a design for a new feature:

1. The Orchestrator dispatches the **Architect** with the problem and
   constraints. The Architect writes a spec file and stops — it never
   implements.
2. The Orchestrator dispatches the **Implementor** with the spec's absolute
   path. The Implementor builds exactly what the spec says.
3. The Orchestrator dispatches the **Reviewer** with the spec path and the
   diff. The Reviewer validates it and labels any finding **impl-defect**
   (back to the Implementor) or **spec-defect** (back to the Architect).

Every one of those dispatches carries a message-file pointer, not inline
prose — you'll see a line like this in your terminal:

```
[hierarchy-msg /path/to/.claude/hierarchy/msgs/20260826-101500-a1b2--architect--new-feature--request.md]
```

That's normal: it's the brief, written to a file so it survives compaction
and re-dispatch. You write one with the message CLI:

```
node <AH_ROOT>/hooks/msg.mjs new --to architect --from orchestrator --slug new-feature --cwd "$(pwd)"
```

`<AH_ROOT>` comes from the `ah CLI root:` line the plugin injects at session
start. See [docs/cli-tools.md](./cli-tools.md) and
[docs/comms-protocol.md](./comms-protocol.md) for the format.

## 7. Tearing down

Bare `roster.mjs disband` is **read-only** — it's just the plan step,
showing what would close. `/agent-team disband` runs the whole contract
(plan → confirm → close) and **will close sessions** once you confirm — see
[SKILL.md — `disband`](../skills/agent-team/SKILL.md#disband) for the full
sequence.

Use `roster.mjs untrack --all --keep-sessions --commit` when you just want the
bookkeeping cleared and the sessions left running — a single, non-destructive
call that removes `team.json` and closes nothing, for when those sessions hold
work worth keeping.

## 8. Where to go next

- [docs/cli-tools.md](./cli-tools.md) — the `roster.mjs` / `msg.mjs` verb
  surface, the invocation form, and permissions.
- [docs/troubleshooting.md](./troubleshooting.md) — symptom → cause → fix.
- [README.md](../README.md) — the full picture: roles, lanes, gates, usage
  tracking.
