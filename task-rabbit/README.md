# task-rabbit

A Claude Code plugin that makes the main, high-reasoning agent **dispatch the
legwork to a cheap Haiku runner** — so your expensive model tokens go to
judgment, not to tool output.

## The idea

You don't hire your most expensive person to run errands. `task-rabbit` gives the
lead agent a cheap runner to dispatch the legwork to: running the builds and
tests, sifting the logs, grepping the tree, reading the files — and handing back a
**compact report**. The lead agent reasons over that report.

Tool output is expensive twice over: once when the pricey reasoning model
generates the tool call, and again on **every subsequent turn**, because tool
results are re-sent as input tokens until the next compaction. A single
unfiltered test run or big `grep` can park thousands of lines in the reasoning
model's context and keep charging for them. Having a cheap model do that work —
and return only the distilled answer — cuts both.

## What it does

When enabled, the plugin injects a directive telling the main agent to dispatch to
a bundled `task-rabbit` subagent (pinned to `model: haiku`) for:

- **Tool/output-heavy** steps — test suites, builds, installs, verbose or
  long-running bash, log sifting.
- **Information gathering that can be summarized** — "find where X is defined",
  "list the callers of Y", "summarize module Z", reading or searching across many
  files.

The main agent keeps everything that needs reasoning — design decisions,
correctness and security judgment, tradeoffs, and writing/editing code. For a
task that needs reasoning, it **splits** the work: task-rabbit runs the step or
gathers the raw material and reports back compactly; the main agent reasons over
the report.

The decision the main agent makes is deliberately shallow (it shouldn't burn
reasoning deciding what to dispatch):

> Would doing this myself flood my context, or is it a mechanical task I can
> specify exactly? → dispatch it. Does it need my judgment? → keep the judgment,
> dispatch only the legwork. When unsure, keep it.

## task-rabbit is a runner, never a decider

This is the core contract, enforced in the subagent's own instructions:

- **It carries out explicit orders — nothing more.** It never reasons, plans,
  designs, or makes decisions. It makes no design/correctness/security/scope calls.
- **Running state-changing tasks is fine** (a build, a migration, a script) — but
  only when the order says precisely what to do and what result to expect. It runs
  it and reports whether the actual result matched. (It has no file-editing tools;
  it is a task runner, not an editor.)
- **It never fills a gap with a guess.** If an order is ambiguous or would require
  it to *decide* anything (which file, which flag, whether something is "safe",
  what the user "probably meant"), it **stops and reports exactly what's missing**
  and hands the decision back.

Because the runner won't improvise, the burden is on the orchestrator to hand down
complete, decision-free orders with the exact expected result.

### Escape hatch

Dispatching isn't a trap. If task-rabbit returns incomplete, wrong, or
insufficient information — or reports it couldn't proceed because an order needed a
decision — the main agent may do the task itself or re-dispatch once with a
sharper, fully-specified order. It won't ping-pong; a stalled dispatch costs more
than just doing the work.

## Toggle it on and off

Ships **OFF** — it changes how the agent works, so it's opt-in.

```
/task-rabbit on        # enable delegation
/task-rabbit off       # disable, main agent handles tools itself
/task-rabbit status    # show current state
/task-rabbit           # toggle
```

State is a marker file at `~/.claude/task-rabbit.enabled` (existence = ON). It
lives in your home directory, so the setting survives plugin updates. Turning it
on takes effect on your next prompt; it's re-established automatically in new
sessions and after compaction.

## How it's wired

- **`agents/task-rabbit.md`** — the Haiku runner: read/search/run tools
  (`Read, Grep, Glob, Bash, WebFetch, WebSearch`), no file mutation, prompted to
  execute exact orders only, return the smallest report that fully answers, and
  stop-and-report rather than decide.
- **`hooks/`** — `SessionStart` (startup/resume/clear/**compact**) injects the
  full directive; `UserPromptSubmit` injects a one-line reminder each turn. Both
  are no-ops when the plugin is OFF.
- **`commands/task-rabbit.md`** — the on/off/status/toggle slash command.

## Composes with output-discipline

Pairs naturally with the [output-discipline](../output-discipline) plugin:
output-discipline blocks context-flooding commands before they run; task-rabbit
moves the work that survives that gate onto a cheaper model. The task-rabbit
runner follows output discipline too, keeping its own context lean while it works.

## License

MIT
