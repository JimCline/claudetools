# claudetools

A Claude Code plugin marketplace.

## Install

```
/plugin marketplace add JimCline/claudetools
/plugin install output-discipline@claudetools
```

## Plugins

### [output-discipline](./output-discipline)

Stops command output from flooding the context window. A `PreToolUse` hook blocks
context-flooding Bash commands **before they run** — `tail -f`, `watch`, foreground
servers, unfiltered test suites — and tells Claude what to run instead (background
tasks, redirect-then-grep, subagent delegation). A `SessionStart` hook injects the
rules, including after compaction.

Prevention, not compression. Composes with `PostToolUse` compressors like squeez.

### [task-rabbit](./task-rabbit)

Makes the main, high-reasoning agent **dispatch the legwork to a cheap Haiku
runner** — running tests/builds, sifting logs, grepping the tree, gathering
information — and reason over the compact report it hands back. Expensive model
tokens go to judgment, not to tool output. The runner carries out explicit orders
only: it never reasons or decides, and stops to report back rather than guess.
Toggle on/off with `/task-rabbit` (ships OFF, opt-in). Includes an escape hatch so
the main agent takes over if the runner falls short.

## License

MIT
