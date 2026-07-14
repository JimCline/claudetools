---
name: output-discipline
description: Inspect, tune, or temporarily disable the output-discipline hook — the PreToolUse gate that blocks context-flooding Bash commands. Use when a command was blocked and the user wants it allowed, when tuning which commands are gated, or when the user asks why a command was denied.
---

# Output discipline

A PreToolUse hook on the Bash tool blocks commands that would flood the context
window, and tells Claude what to run instead. It is a *prevention* layer — it
stops the output from ever being produced.

## What gets blocked, and the fix

| Category | Examples | Required alternative |
|---|---|---|
| Streaming | `tail -f`, `watch`, `--follow`, `less`, `top` | `run_in_background` + Monitor tool, or a bounded `grep`/`tail -n` |
| Foreground long-runners | `npm run dev`, `vite`, `uvicorn`, `rails s` | Same command with `run_in_background: true` |
| Verbose one-shots | `npm test`, `pytest`, `make`, `docker build` | Redirect to a file, then `grep`/`head` the interesting lines |

A verbose one-shot is allowed through untouched if it already redirects (`>`),
pipes to a filter (`| grep`, `| head`, …), or uses `tee`.

## Tuning it

Both knobs are environment variables, set in `settings.json` under `env`:

- `OUTPUT_DISCIPLINE_DISABLE=1` — turn the gate off entirely.
- `OUTPUT_DISCIPLINE_ALLOW="foo,bar"` — comma-separated substrings; any command
  containing one is always allowed. Use this for a project-specific command that
  is being gated but is genuinely quiet.

To change *which* commands are gated, edit the `STREAMING`, `LONG_RUNNING`,
`NOISY`, and `ALREADY_TAMED` pattern lists at the top of
`hooks/pretooluse-bash.mjs`. They are plain regex arrays.

## Relationship to squeez / rtk / other compressors

These are complementary, not competing. A compressor sits at PostToolUse and
shrinks output *after* the command has run. This hook sits at PreToolUse and
stops the command from producing the output at all. A compressor cannot turn a
foreground `tail -f` into a background task; this can. Run both.

## When a block is wrong

The hook fails open by design — any internal error allows the command. If it is
blocking something it shouldn't, prefer adding to `OUTPUT_DISCIPLINE_ALLOW` over
disabling the whole gate.
