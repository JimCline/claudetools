---
description: Configure the model-name status-line banner. Usage: /model-banner [init|status|on|off|size <large|compact|small>|layout <stack|side>|color <tier> <color>|uninstall]
argument-hint: "[init|status|on|off|size <large|compact|small>|layout <stack|side>|color <tier> <color>|uninstall]"
---

The user ran `/model-banner` with argument: `$ARGUMENTS`

model-banner renders the current model's name as large, colour-coded ASCII
art in the Claude Code status line. Because a plugin cannot ship a
`statusLine` directly (only `agent`/`subagentStatusLine` are
plugin-installable), `init` performs an explicit, one-time edit to
`~/.claude/settings.json`: it preserves whatever status-line command you
already had (verbatim, chained below the banner) and backs up
`settings.json` first. `uninstall` puts it back.

Resolve the CLI, trying these in order (do NOT use a
`~/.claude/plugins/cache/*/…` glob to find it — multiple plugin versions can
coexist there and a glob picks the wrong one):

```sh
node "${CLAUDE_PLUGIN_ROOT:-}/hooks/cli.mjs" <args> 2>/dev/null \
  || node "$(cat ~/.claude/model-banner/plugin-root)/hooks/cli.mjs" <args>
```

Pick the ONE case matching the argument and run it with the Bash tool, then
show the CLI's own output to the user verbatim — it already reports exactly
what changed, do not summarize or re-derive it yourself:

- **`init`**: run the resolver above with `install` as `<args>`.
- **`uninstall`**: run the resolver above with `uninstall` as `<args>`.
- **`on`** / **`off`**: run the resolver above with `on` or `off` as `<args>`.
- **`status`** / empty: run the resolver above with `status` as `<args>`.
- **`size <large|compact|small>`**: run the resolver above with `size <value>`
  as `<args>`. `large` is 5-row block art, `compact` is 3-row thin line art
  (`| _ - \ /`), `small` is a single decorated text row.
- **`layout <stack|side>`**: run the resolver above with `layout <value>` as
  `<args>`. `stack` (default) prints your existing status line first and the
  banner below it. `side` prints the banner on the left with your existing
  status line's output to the right of it, row for row.
- **`color <tier> <color>`**: run the resolver above with `color <tier> <color>`
  as `<args>`. `<tier>` is one of `sonnet`, `opus`, `fable`, `haiku`,
  `default`; `<color>` is one of the named ANSI colours the CLI's own error
  message lists if you get it wrong.
- **anything else**: show the usage line from this command's `description`
  and do not run anything.

Changes from `on`/`off`/`size`/`layout`/`color` take effect within a second
or two without a restart — the status line re-runs on its own schedule and
re-reads the config every time. Say so in your closing line, unless the
subcommand was `init`, `uninstall`, or `status`.
