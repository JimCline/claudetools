# model-banner

Renders the current Claude model's name as large, colour-coded ASCII art in
the Claude Code status line — sonnet green, opus yellow, fable red, haiku
cyan — so it's always visually obvious which model a session is running on.

## Why the status line, not a session-start message

The natural instinct is a hook that fires once when a session starts. Claude
Code hooks can't do it in colour, though: `additionalContext` never reaches
the terminal (it only feeds the model's own context), the visible
`systemMessage` field gets Claude Code's fixed warning styling with no
per-message colour control, and `terminalSequence` — the one hook channel
that talks to the terminal directly — explicitly excludes colour/CSI
sequences from its allowlist.

The status line is the one surface that renders real ANSI colour, and it
already re-runs at session start, at resume, and right when `/compact`
finishes — so the "fires on those events" want isn't actually lost, only the
"flash and disappear" quality is. In exchange the banner is never stale: if
the model changes mid-session, the banner follows it immediately.

## The cost, stated plainly

A plugin can't ship a `statusLine` directly (only the `agent` and
`subagentStatusLine` settings keys are plugin-installable), so getting this
banner onto your status line means an explicit edit to your own
`~/.claude/settings.json` — not something the plugin can do just by being
enabled. `/model-banner init` does this for you: it's non-destructive (any
status-line command you already had is preserved and chained *below* the
banner, not replaced) and it backs up `settings.json` first.
`/model-banner uninstall` puts your original command back.

At `size: "large"` (the default) the banner is 5 rows, always on screen —
that's real terminal space spent permanently, not a one-time announcement.
`/model-banner size compact` switches to a 3-row thin line-art font (drawn
with only `| _ - \ /` and space); `/model-banner size small` collapses it to
a single coloured text row.

By default your existing status line prints first and the banner follows it
below (`layout: "stack"`). `/model-banner layout side` instead prints the
banner on the left with your existing status line's output to the right of
it, row for row.

## Setup

```
/model-banner init       # wires the banner into your status line
/model-banner status     # show current config + whether it's wired up
/model-banner uninstall  # restore your original status line
```

## Configuration

```
/model-banner on | off                  # whether the banner renders at all
/model-banner size large | compact | small  # 5 rows / 3 rows / 1 row — applies to every model
/model-banner layout stack | side       # banner below your status line, or beside it
/model-banner color <tier> <color>      # <tier>: sonnet | opus | fable | haiku | default
```

Config lives at `~/.claude/model-banner.json`, with an optional project-scope
override at `<repo>/.claude/model-banner.json` (project wins per-key: a
project config that sets only `colors.sonnet` overrides just that tier,
leaving the rest at their user-scope-or-default values — the same layering
agent-hierarchy uses). Colours are a fixed named palette (`green`, `yellow`,
`red`, `cyan`, `blue`, `magenta`, `white`, `black`, `gray`, and `bright*`
variants) mapped to basic ANSI SGR codes — the status-line docs only
demonstrate basic codes, so that's what this ships with.

An unrecognized model falls back to a generic `CLAUDE` label in `default`'s
colour (white) rather than guessing or crashing — tier matching is a
substring match against the model's id and display name, so it survives
model-id changes across releases without needing an update.

## How it's wired

- **`statusline/render.mjs`** — the renderer. Reads config, resolves the
  current model to a tier, prints the coloured banner, then runs whatever
  status-line command you had before (the "chain") and passes its output
  through unchanged. Never throws, never exits non-zero, and never skips the
  chain — turning the banner off, or a bug in it, must never take your
  existing status line down with it.
- **`hooks/cli.mjs`** — backs every `/model-banner` subcommand, including the
  install/uninstall logic that's the only thing in this plugin allowed to
  touch `~/.claude/settings.json`.
- **`hooks/sessionstart.mjs`** — a silent maintenance hook. Marketplace
  plugins live under a version-stamped cache path that changes on every
  update, so a generated shim at a stable path
  (`~/.claude/model-banner/statusline.mjs`) is what your `settings.json`
  actually points at; this hook keeps that shim's pointer current across
  plugin updates. It never touches `settings.json` itself and emits nothing.
- **`hooks/lib-tiers.mjs`** — the model registry (`TIERS`). Adding a tier is
  one row here, nothing else.
- **`hooks/lib-font.mjs`** — the hand-rolled glyph table (there's no
  npm dependency in this repo, so no figlet). Full A–Z/0–9 so an unrecognized
  model's display name can still render.
- **`hooks/lib-config.mjs`** — config resolution (user + project layering).
- **`commands/model-banner.md`** — the slash command.

## License

MIT
