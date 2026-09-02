---
name: review-guide
description: Note a PR's diff as work happens, then compile a reviewer's walkthrough from those notes. Use when the user asks to note a change, check review-guide status, compile a guide, or attach one to a PR.
---

# Review guide

`guide.mjs` keeps an append-only ledger of narration and scrutiny flags,
keyed by branch, and compiles it into a markdown walkthrough for a reviewer.
It only runs when invoked — nothing in this plugin enforces or triggers it.

## What a note contains — two halves

- **The narration (required).** What you did and why, in prose a reviewer
  can follow: the point of the change, what approach you took and what over,
  and how the touched files relate. A few sentences.
- **The watch flags (optional, repeatable `--watch`).** Risky choices,
  judgment calls where the spec was silent, deviations and why, invariants
  relied on, touched-but-untested areas. One flag per concern, one line
  each. Omit entirely when there is nothing to flag — an empty flag is
  worse than none, because it reads as "reviewed and cleared".

Not a restatement of the diff. "Changed `foo()` to take a second argument" is
worthless — the diff already says that. "Callers now pass a budget instead of
a retry count, so the timeout policy lives in one place" is the same edit at
the level a reviewer needs. Rule of thumb: if the sentence would still be
true and useful with the file names removed, it is narration; if it only
makes sense as a caption on a hunk, it is diff-restatement.

## The one rule

Write a note after each meaningful unit of work, before moving on. One note
per turn-of-work, not per edit and not per PR; one note per *concern*, not
per file.

## When to skip instead

`guide.mjs note --skip "<why>"` for a genuinely trivial change — a typo, a
formatting pass. It shows up in the guide as a deliberate call, distinct
from a file nobody looked at.

## Commands

```
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note "<narration>" [--watch "<flag>"]... [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note --skip "<why>" [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" status
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" guide [--out <path>] [--pr]
```

With no paths given, `note` covers the current changed set (working tree,
staged, and committed-since-base). Worked example, both halves:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note \
  "Replaced the ad-hoc retry loop in the fetch path with a shared helper, so the timeout and backoff live in one place instead of three. Callers now pass a budget instead of a retry count." \
  --watch "The backoff constant is deliberate — 250ms, not the 1s the old loop used." \
  --watch "fetchAll() is the one caller still on the old signature; it is adapted at the call site rather than migrated." \
  src/retry.mjs src/retry.test.mjs
```

`guide.mjs guide --pr` writes the guide and prints the `gh pr create` /
`gh pr edit` commands — it does not run either.

## When it runs

Nothing here is automatic. Two patterns:

1. Run `/review-guide note ...` / `/review-guide guide --pr` directly.
2. Give the session a standing instruction — "always run the review guide
   before opening a PR" — and follow it like any other workflow habit.

## Where to run it

Run `guide`/`status` with cwd inside the checkout of the branch being
compiled. The ledger key and the changed set are both read from the current
checkout; compiling `feat-x`'s guide from a checkout sitting on `main` does
not error — it reads `main.jsonl`, diffs `main`'s tree, and silently emits
the wrong document.

## Drift

A note goes stale when its file changes again — that is intentional, and the
whole point of keying annotation to the file's current content hash.
`status` is how you see what has drifted back to unannotated.

## Authority

This spec (`docs/specs/0002-review-guide-plugin.md`) is authoritative on
behaviour; if this file disagrees with it, the spec wins.
