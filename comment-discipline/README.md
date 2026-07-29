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

`SessionStart` fires for the **main session only** — a subagent is not a session, so that
hook never runs inside one. The gap matters here more than for most plugins: subagents
write plenty of code, and an Implementor or a general-purpose agent is exactly who leaves
`// NEW: added validation` behind.

So the rule reaches them two ways:

1. **At spawn, via `SubagentStart`.** A hook injects the rule into the subagent's own
   context as it starts, before its first turn. This event *does* deliver into the subagent
   — but **only** when the hook emits a JSON `hookSpecificOutput` object. The same text
   written as plain stdout is discarded silently, with no error, which is the opposite of
   `SessionStart` and the reason this channel is easy to write off as broken.
   Known-non-authoring agent types (`Explore`, `Plan`, a task-gopher runner) are skipped, so
   the ~2.4KB is charged only where code might get written.
2. **On the first edit, as a backstop.** A `PostToolUse` hook on
   `Edit`/`Write`/`NotebookEdit` injects the rule once per subagent. `SubagentStart` marks
   each agent it reached, so for an ordinary dispatch this hook finds the mark and stays
   quiet.

Before 0.3.0 the first channel was a *relay clause*: the directive asked the dispatching
agent to copy the rule into code-writing dispatch prompts by hand. That cost the parent
output tokens on every dispatch, depended on the model cooperating, and had to carefully
place its copy *below* any block already leading the prompt so it didn't break a sibling
plugin's top-anchored sentinel check. `SubagentStart` needs none of that, and doesn't
contend for the `Agent` tool's input — which `task-gopher`'s relay already owns.

Two honest limits:

- **Whether the backstop is still load-bearing is unknown.** It now only covers spawns that
  produce no `SubagentStart` event. Whether any exist — agents created by a workflow runner
  rather than an `Agent` tool call, say — has not been measured. It is kept because the cost
  is one file read per edit and it removes a silent-failure mode.
- The **first edit is unguarded** *by the backstop*, since that injection lands with the
  edit's result. `SubagentStart` is what covers edit #1, and it is the only thing that
  covers a subagent which makes exactly one edit.

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
