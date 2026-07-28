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

It is delivered to **subagents too**. Sibling plugins (`task-gopher`, `agent-hierarchy`)
deliberately suppress themselves inside subagents to prevent dispatch recursion; there is
no recursion here, and subagents write plenty of code, so the gate is intentionally absent.

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
