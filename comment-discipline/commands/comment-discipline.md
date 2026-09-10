---
description: Initialize, toggle, or sweep for comment-discipline (no ephemeral comments). Usage: /comment-discipline [init [global|repo]|on|off|status|sweep [path]]
argument-hint: "[init [global|repo]|on|off|status|sweep [path]]"
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
- **`sweep [path]`**: see the sweep section at the bottom of this file — do NOT run `$CLI` for it.
- **`status`** / empty / anything else: `node "$CLI" status`

Show the CLI's output to the user verbatim — it names the scope and the file it wrote,
which is the part they need in order to trust what just happened.

If the result is **ON**, also adopt this behavior immediately for the rest of the session
(the SessionStart hook re-establishes it in future sessions, including after compaction):

> When you write or edit code, do not leave comments that only make sense while your diff
> is on screen. A comment's audience is the next person to READ the code, not whoever
> reviews this change — git history already records what changed. Do not write change
> narration (`// changed from foo to bar`, `// NEW: added validation`, `// now uses the new
> API`), references of any kind (ticket or issue IDs, spec numbers and sections, finding
> IDs, review-round labels, decision markers), reviewer-directed asides (`// as suggested,
> kept for backwards compat`), restatements of the line (`// increment counter` over
> `counter++`), task narration (`// Step 1: validate input`), or bare time markers
> (`// temporary`, `// for now`) — mark time with a stated removal condition, which makes
> `// TODO: remove once the v2 endpoint lands` good and worth keeping. Do write public-API
> contracts and explanations of WHY non-obvious code is the way it is, describing how the
> CURRENT code works rather than what changed or what was decided; a TODO for a decided
> deferral is the one place a reminder about a decision belongs. This never asks you to
> document: when in doubt write nothing, and do not clean up pre-existing comments you were
> not asked to touch.

If the result is **OFF**, confirm the directive is disabled and that you will stop applying
it for the rest of this session.

If the CLI reports **not configured** for an `on`/`off`, tell the user to run
`/comment-discipline init` first and offer to do it.

## `sweep [path]` — audit existing comments against the rule

`/comment-discipline sweep [path]`.

`sweep` is the retrospective half: the directive governs what gets written from now on, this finds
what is already there. It is a two-stage job on purpose — a deterministic finder, then judgment —
because a regex cannot tell a durable WHY comment that happens to cite a ticket from a comment whose
only content IS the ticket.

**Stage 1 — find candidates (no judgment).** Run, with `path` defaulting to the repo root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/hooks/sweep.mjs" <path> --json
```

It reads git-tracked source files only, excludes `docs/specs/**`, and reports one record per flagged
comment line as `{file, line, class, text}` over the do-not classes `references`,
`change-narration`, `time-markers`, `todo-with-ref`. `--count` gives just a number; no flag gives a
grouped human-readable report. It is a pre-filter tuned for precision: expect false positives, and
expect it to miss comments whose wording it cannot pattern-match.

**Stage 2 — judge each candidate** against the directive (the rule text, verbatim, is in the block
above). For every candidate decide exactly one of:

- **keep** — the comment is legitimate under the rule as it stands.
- **rewrite** — the comment is legitimate WHY but carries a reference or a bare marker; strip only
  that clause. No new prose, no rewording of what survives.
- **remove** — the comment's whole content is change narration, a reference, a reviewer aside, a
  restatement, or a bare marker.

With **more than 40 candidates**, do not judge them inline — fan out per directory to
`task-gopher:smart-gopher` (or `general-purpose` if task-gopher is not installed), one dispatch per
directory, each given the directive text and that directory's candidate list, each returning
`file:line → keep|rewrite|remove` plus the replacement text for a rewrite. Collect the verdicts.

**Stage 3 — report, then ask once.** Show a report grouped by class, with a per-class count and the
file:line list, and say how many are keep / rewrite / remove. Then ask with **AskUserQuestion**,
exactly one question, three options:

- **Apply all removals and rewrites** — edit the files.
- **Show the diff first** — print the proposed edits without writing, then stop.
- **Report only** — change nothing.

Hard limits when applying: touch comment lines only, never a line of code; delete a whole-line
comment with its line, strip only the offending clause from a trailing or mixed comment; and never
edit a file the user excluded. Guard 2 of the directive does not apply here — the user asked for
this cleanup, which is what makes it not a drive-by.
