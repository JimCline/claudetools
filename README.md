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

## License

MIT
