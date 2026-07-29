# comment-discipline

Stops Claude from writing **ephemeral comments** — the ones that only parse while the
diff is on screen:

```js
// changed from foo to bar
// NEW: added validation
// now uses the new API
// as suggested, kept this for backwards compat
// increment counter          ← above counter++
// temporary
```

Once the change merges, every one of those describes a transition nobody can see. Git
history already records what changed; the code does not need to narrate its own edit.

`github-pr-toolkit`'s `/code-critic` **catches** these at review time. This plugin stops
them being written in the first place.

## What it injects

A `SessionStart` hook injects the authoring rule on `startup`, `resume`, `clear`, `fork`,
and `compact` — the last one matters most, since compaction is what silently drops a
directive mid-session and lets the old habit creep back.

## Reaching subagents

`SessionStart` fires for the **main session only** — a subagent is not a session, so no
injection hook ever runs inside one. That gap matters here more than for most plugins:
subagents write plenty of code, and an Implementor or a general-purpose agent is exactly
who leaves `// NEW: added validation` behind.

So the rule reaches them two ways:

1. **Relay at dispatch.** The directive asks the dispatching agent to copy the rule
   verbatim into the prompt of any subagent that will *write or edit code* — the only
   channel that reaches a subagent at spawn. Retrieval, search, and review-only dispatches
   are deliberately skipped: they author nothing, so the copy would be pure token cost. The
   copy goes *below* any directive block already leading the prompt, because a sibling
   plugin may run a top-anchored check on the first line. The copy carries the relay
   instruction with it, so it chains onward.
2. **Injection on the first edit.** A `PostToolUse` hook on `Edit`/`Write`/`NotebookEdit`
   injects the rule once per subagent. Tool events are the only hooks that fire *inside* a
   subagent's loop, so this is the one channel that works without the parent's cooperation.

Keying that injection to the edit tools rather than gating `Agent` dispatches is deliberate:
the rule only matters to an agent that actually authors code, so this charges the directive
only to agents that write, never to the retrieval traffic that dominates dispatches. It
also keeps this plugin off the `Agent` tool, where `task-gopher`'s relay gate already
denies — the hook docs don't define how two denying hooks combine, so stacking a second one
there would be a guess.

Two honest limits, since the two channels are additive rather than complementary:

- The hook **cannot tell whether the relay happened** — `PostToolUse` carries no dispatch
  prompt — so it always injects. A correctly relayed subagent therefore receives the rule
  twice, about 2.4KB of avoidable duplication once per code-writing subagent. That is the
  price of covering the agents the relay missed.
- The **first edit is unguarded**, since the injection lands with that edit's result and
  shapes everything after it. The relay is what covers edit #1 — and it is the only thing
  that covers a subagent which makes exactly one edit.

The full design, and how to choose a channel in other plugins, is written up in
[docs/subagent-directive-relay.md](../docs/subagent-directive-relay.md).

## The rule

**Don't write:** change narration, reviewer-directed asides, restatements of the line,
task narration (`// Step 1: …`), or bare time markers.

**Do write:** public-API behavior and contracts, and **why** non-obvious code is the way
it is — a workaround, an external constraint, a deliberate tradeoff, a spec or bug ref.

Two guards keep it from backfiring:

1. **It never asks you to document.** A review lens can be purely subtractive; an authoring
   directive can't, because the model is deciding whether to write a comment at all.
   Without this guard it degenerates into defensive doc-comments added to prove compliance
   — worse than the problem. When in doubt, write nothing.
2. **It only governs comments you write or edit.** No drive-by cleanup of pre-existing
   comments; that produces noisy diffs and is out of scope.

Time markers are allowed *with a qualifier* — `// TODO(#4127): remove once the v2 endpoint
lands` is good and stays. Bare `// for now` is not.

## Setup

```
/comment-discipline init        # asks: every project, or just this repo?
/comment-discipline init global # ~/.claude/comment-discipline.json
/comment-discipline init repo   # <repo>/.claude/comment-discipline.json
```

Then it just works. To toggle:

```
/comment-discipline on
/comment-discipline off
/comment-discipline status
```

## Scopes

| Scope | File | Applies to |
|---|---|---|
| global / user | `~/.claude/comment-discipline.json` | every project |
| repo / project | `<repo>/.claude/comment-discipline.json` | that repo only |

Both may exist — **project wins**, so a repo can opt out of a global install without
touching it. `on`/`off` flip the narrowest scope that already exists, so a repo-level
toggle never silently rewrites your global setting.

Three states: unconfigured emits a one-line setup nudge; enabled injects the directive;
`enabled: false` is **silent**, because nudging someone to configure a thing they
deliberately turned off is the annoying failure mode.

A config file that isn't valid JSON is ignored with a warning rather than crashing the
hook — a hook that throws on every SessionStart is miserable to diagnose.
