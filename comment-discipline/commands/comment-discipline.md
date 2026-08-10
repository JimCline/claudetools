---
description: Initialize and toggle comment-discipline (no ephemeral comments). Usage: /comment-discipline [init [global|repo]|on|off|status]
argument-hint: "[init [global|repo]|on|off|status]"
---

The user ran `/comment-discipline` with argument: `$ARGUMENTS`

comment-discipline stores its state in `comment-discipline.json` under `.claude/`,
in one of two scopes:

- **global / user** — `~/.claude/comment-discipline.json`, applies to every project.
- **repo / project** — `<repo>/.claude/comment-discipline.json`, this repo only.

Both may exist; the project scope wins. `on`/`off` flip the **narrowest scope that
already exists**, so a repo-level opt-out never silently rewrites the global setting.

First resolve the CLI path (the plugin root is not always exported):

```bash
CLI="${CLAUDE_PLUGIN_ROOT:-}/hooks/cli.mjs"; [ -f "$CLI" ] || CLI="$(ls -t ~/.claude/plugins/cache/*/comment-discipline/*/hooks/cli.mjs 2>/dev/null | head -1)"
```

Then pick the ONE case matching the argument and run it with the Bash tool:

- **`init global`** / `init user`: `node "$CLI" init user`
- **`init repo`** / `init project` / `init local`: `node "$CLI" init project`
- **`init`** with no scope: ask the user which scope with AskUserQuestion — options
  "Every project (global)" and "Just this repo" — then run the matching command above.
  Recommend **global** for a personal machine, **repo** when the setting should travel
  with the codebase for everyone working in it.
- **`on`** / `enable`: `node "$CLI" on`
- **`off`** / `disable`: `node "$CLI" off`
- **`status`** / empty / anything else: `node "$CLI" status`

Show the CLI's output to the user verbatim — it names the scope and the file it wrote,
which is the part they need in order to trust what just happened.

If the result is **ON**, also adopt this behavior immediately for the rest of the session
(the SessionStart hook re-establishes it in future sessions, including after compaction):

> When you write or edit code, do not leave comments that only make sense while your diff
> is on screen. A comment's audience is the next person to READ the code, not whoever
> reviews this change — git history already records what changed. Do not write change
> narration (`// changed from foo to bar`, `// NEW: added validation`, `// now uses the new
> API`), reviewer-directed asides (`// as suggested, kept for backwards compat`),
> restatements of the line (`// increment counter` over `counter++`), task narration
> (`// Step 1: validate input`), or bare time markers (`// temporary`, `// for now`) — mark
> time only with an issue reference or a stated removal condition, which makes
> `// TODO(#4127): remove once the v2 endpoint lands` good and worth keeping. Do write
> public-API contracts and explanations of WHY non-obvious code is the way it is. This
> never asks you to document: when in doubt write nothing, and do not clean up
> pre-existing comments you were not asked to touch.

If the result is **OFF**, confirm the directive is disabled and that you will stop applying
it for the rest of this session.

If the CLI reports **not configured** for an `on`/`off`, tell the user to run
`/comment-discipline init` first and offer to do it.
