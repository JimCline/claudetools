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

### [task-gopher](./task-gopher)

Makes the main, high-reasoning agent **dispatch the legwork to a cheap Haiku
runner** — running tests/builds, sifting logs, grepping the tree, gathering
information — and reason over the compact report it hands back. Expensive model
tokens go to judgment, not to tool output. The runner carries out explicit orders
only: it never reasons or decides, and stops to report back rather than guess.
Toggle on/off with `/task-gopher` (ships OFF, opt-in). Includes an escape hatch so
the main agent takes over if the runner falls short.

### [agent-hierarchy](./agent-hierarchy)

Splits work across **six roles with a model each** — Orchestrator (the session
agent itself), Ultra-Advisor, Architect, Reviewer, Implementor, Task-Runner.
Design reasoning goes to a strong model that writes a spec file and never
implements; the Implementor builds exactly that spec and reports gaps up instead
of deciding; a read-only Reviewer validates the diff and labels each finding
**impl-defect** or **spec-defect** so it routes back to the right role.
Run `/hierarchy` once to
assign the models — user-scoped or committed per-repo — and a `SessionStart` hook
injects the resolved role→model table plus the orchestration protocol, including
after compaction. Silent inside subagents, so role dispatches don't pay for it.

Above the Architect sits the **Ultra-Advisor** (defaults to `fable`; `opus` is
the only alternative — no `sonnet`, no `inherit`). It is an escalation apex, not
a routine step: it runs when the Architect couldn't resolve a fork or reported
low confidence, when the review loop stalls, when the blast radius is outsized
(security, auth, data migration, concurrency, public interfaces), or when you
say a problem is important. It adjudicates and never implements.

Tiered so small work stays cheap: trivial edits skip the chain entirely, and
fully-specified requests skip the Architect but keep the Reviewer. When
task-gopher is installed, the Task-Runner role delegates to it, so both plugins
point retrieval at the same Haiku runner. `/hierarchy status` shows the effective
table and where each value came from; `/hierarchy set <role> <model>` tweaks one
role; `/hierarchy off` silences it.

## License

MIT
