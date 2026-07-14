# output-discipline

A Claude Code plugin that stops command output from flooding the context window.

Tool output is re-sent as input tokens on **every subsequent turn** of a session.
A single `tail -f` or bare `npm test` can put thousands of lines into the context
and keep charging for them until the next compaction.

## What makes this different from a compressor

Tools like **squeez**, **rtk**, and **headroom** sit at `PostToolUse`: the command
runs, produces 5,000 lines, and they shrink what lands in context. That is real
savings — but you still pay for the compressed dump, and a compressor
fundamentally cannot turn a foreground `tail -f` into a background task.

`output-discipline` sits at `PreToolUse`. It blocks the command **before it runs**
and tells Claude what to run instead. Prevention, not compression.

**These compose. Run both.**

## What it does

A `PreToolUse` hook on the Bash tool denies three classes of command and returns a
message Claude reads and self-corrects from:

| Category | Examples | What Claude is told to do |
|---|---|---|
| Streaming | `tail -f`, `watch`, `--follow`, `less`, `top` | Use `run_in_background` + the Monitor tool, or a bounded `grep`/`tail -n` |
| Foreground long-runners | `npm run dev`, `vite`, `uvicorn`, `rails s` | Re-run with `run_in_background: true` |
| Verbose one-shots | `npm test`, `pytest`, `make`, `docker build` | Redirect to a file, then `grep`/`head` the interesting lines |

A verbose command passes through untouched if it already redirects (`>`), pipes to
a filter (`| grep`, `| head`, …), or uses `tee`. A long-runner passes through if it
is already backgrounded.

A `SessionStart` hook injects the same rules as context, so Claude writes
well-behaved commands in the first place rather than learning by rejection.

## Install

Local, no marketplace needed:

```bash
claude --plugin-dir /Users/jimcline/git/repos/claudetools/output-discipline
```

To make it permanent, add the plugin to your marketplace or reference it from
`settings.json`. Use `/reload-plugins` to pick up edits mid-session.

## Configuration

Environment variables, settable under `env` in `settings.json`:

- `OUTPUT_DISCIPLINE_DISABLE=1` — turn the gate off entirely.
- `OUTPUT_DISCIPLINE_ALLOW="foo,bar"` — comma-separated substrings; any command
  containing one is always allowed.

To change *which* commands are gated, edit the `STREAMING`, `LONG_RUNNING`,
`NOISY`, and `ALREADY_TAMED` regex arrays at the top of
`hooks/pretooluse-bash.mjs`.

## Safety

The hook **fails open**. Empty stdin, malformed JSON, an unexpected payload shape,
or any internal exception exits 0 and allows the command. A broken hook must never
brick the Bash tool.

## Layout

```
output-discipline/
├── .claude-plugin/plugin.json
├── hooks/
│   ├── hooks.json
│   ├── pretooluse-bash.mjs     # the gate
│   └── sessionstart.mjs        # injects the rules as context
└── skills/output-discipline/SKILL.md
```
