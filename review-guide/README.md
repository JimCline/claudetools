# review-guide

Note a PR's diff as work happens, then compile a reviewer's walkthrough from
those notes. An append-only, per-branch JSONL ledger; a CLI; a skill. Pure
tooling — no hooks, nothing enforced, nothing runs on its own.

## Install

Add this repo as a marketplace and install `review-guide`, same as the
other plugins here.

## Usage

```
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note "<narration>" [--watch "<flag>"]... [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note --skip "<why>" [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" status
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" guide [--out <path>] [--pr]
```

It is invoked, never automatic. Two patterns:

1. Run `/review-guide note ...` / `/review-guide guide --pr` yourself.
2. Give the session a standing instruction to run it before opening a PR,
   and it follows that like any other workflow habit.

Run `guide`/`status` with cwd inside the checkout of the branch being
compiled — the ledger key and the changed set are both read from the
current checkout.

See `skills/review-guide/SKILL.md` for what a note should contain.
