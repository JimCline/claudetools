# claudetools

A Claude Code plugin marketplace — hooks that enforce agent behaviour instead of
asking for it.

## Install

```
/plugin marketplace add JimCline/claudetools
```

Install any plugin, or all four — they're independent, nothing requires the
others:

```
/plugin install ah@claudetools
/plugin install task-gopher@claudetools
/plugin install output-discipline@claudetools
/plugin install comment-discipline@claudetools
```

## The two you probably want

### `agent-hierarchy` (installs as `ah`)

Splits work across **six roles, each on a model priced for what that role
does** — Orchestrator, Ultra-Advisor, Architect, Reviewer, Implementor,
Task-Runner — and the reasoning tiers are structurally barred from
executing: the Architect can't run `Bash`, the Reviewer must delegate every
test/build run it needs, tool access follows the role rather than describing
it. When `task-gopher` is installed, `ah`'s Task-Runner role delegates to
it, so both plugins point retrieval at the same Haiku runner.

`/hierarchy status` shows the effective table and where each value came
from; `/agent-roster edit` tweaks one role's model; `/hierarchy flow`
switches handoff mode; `/hierarchy off` silences it.

**Docs:** [getting started](./agent-hierarchy/docs/getting-started.md) ·
[MCP tools](./agent-hierarchy/docs/mcp-tools.md) ·
[troubleshooting](./agent-hierarchy/docs/troubleshooting.md) ·
[full README](./agent-hierarchy/README.md)

### task-gopher

Makes the main, high-reasoning agent **dispatch the legwork to a cheap
Haiku runner** — running tests/builds, sifting logs, grepping the tree,
gathering information — and reason over the compact report it hands back.
Expensive model tokens go to judgment, not to tool output. The runner
carries out explicit orders only: it never reasons or decides, and stops to
report back rather than guess. Includes an escape hatch so the main agent
takes over if the runner falls short.

Toggle on/off with `/task-gopher` (ships OFF, opt-in).

**Docs:** [full README](./task-gopher/README.md)

## Also here

### output-discipline

Stops command output from flooding the context window. A `PreToolUse` hook
blocks context-flooding Bash commands **before they run** — `tail -f`,
`watch`, foreground servers, unfiltered test suites — and tells Claude what
to run instead.

**Docs:** [full README](./output-discipline/README.md)

### comment-discipline

Stops Claude writing **ephemeral comments** — narration that only parses
while the diff is on screen and describes a transition nobody can see once
it merges. Public-API contracts and why-this-is-non-obvious explanations
are explicitly encouraged.

**Docs:** [full README](./comment-discipline/README.md)

## Why hooks, not prompts

The failure these plugins exist to prevent is not disobedience. No model reads "delegate
the legwork" and decides to defy it. What happens is **erosion through locally-reasonable
exceptions**: this grep is tiny, that file is half in context already, dispatching has
overhead, the answer is needed now. Every individual call is defensible. The aggregate is
the directive ignored.

Prose defends against this badly, because the rationalization feels like judgment from the
inside — and judgment is exactly what the model has been told to keep for itself. So the
useful question is not "is this rule written down" but **how many times must the model
choose to obey it**. That gives a ladder, strongest first:

| | Mechanism | Here |
|---|---|---|
| 1 | **Structurally impossible** — the decision doesn't exist | model pinned in agent frontmatter; Reviewer denied `Write`; Architect denied `Bash` |
| 2 | **Hard-denied** at `PreToolUse` | output-discipline's Bash gate. Only safe for machine-checkable invariants |
| 3 | **Checkpoint with an escape hatch** | task-gopher strict mode, for rules where a deny would sometimes be wrong |
| 4 | **Injected directive** | survives compaction, but is re-decided every turn |
| 5 | **Prose in a document** | read once, decays with distance |

> A directive is a decision the model must re-make every turn.
> A structure is a decision made once.

Read that way, the strongest thing here isn't the blocking — it's rung 1. A model pinned in
an agent definition isn't *enforced*, it's **unforgettable**: there's no per-dispatch choice
left to erode. The gates are the enforcement arm of a larger principle — move policy out of
the space of per-turn decisions, and gate only what has to stay behavioral. **Gate
mechanics; nudge judgment.**

**Where this stops.** Judgment can't be gated: "is this step reasoning or legwork" isn't
machine-checkable, which is why task-gopher ships a checkpoint rather than a deny. Every
gate is also a tax — false positives cost real time, and each injected directive is
resident context on every request. And while it's observable that the gates fire and change
behavior, whether gated delegation nets out *cheaper* than good prompts plus nothing is
not yet measured. That's open work.

## License

MIT
