# understudy

A Claude Code plugin that makes the main, high-reasoning agent **delegate the
legwork to a cheap Haiku subagent** — so your expensive model tokens go to
judgment, not to tool output.

## The idea

An understudy does all the rehearsal legwork so the lead can focus on the
performance. Here, Haiku is the understudy: it runs the builds and tests, sifts
the logs, greps the tree, reads the files, and hands back a **compact report**.
The lead agent reasons over that report.

Tool output is expensive twice over: once when the pricey reasoning model
generates the tool call, and again on **every subsequent turn**, because tool
results are re-sent as input tokens until the next compaction. A single
unfiltered test run or big `grep` can park thousands of lines in the reasoning
model's context and keep charging for them. Having a cheap model do that work —
and return only the distilled answer — cuts both.

## What it does

When enabled, the plugin injects a directive telling the main agent to defer to a
bundled `understudy` subagent (pinned to `model: haiku`) for:

- **Tool/output-heavy** steps — test suites, builds, installs, verbose or
  long-running bash, log sifting.
- **Information gathering that can be summarized** — "find where X is defined",
  "list the callers of Y", "summarize module Z", reading or searching across many
  files.

The main agent keeps what actually needs reasoning — design decisions,
correctness and security judgment, tradeoffs, and writing/editing code. For a
task that needs reasoning, it **splits** the work: the understudy gathers the raw
material and reports back compactly; the main agent reasons over the report.

The decision the main agent makes is deliberately shallow (it shouldn't burn
reasoning deciding what to delegate):

> Would doing this myself flood my context, or is it retrieval I can specify
> precisely? → delegate. Does the answer need my judgment? → keep the judgment,
> delegate the gathering. When unsure, keep it.

### Escape hatch

Delegation isn't a trap. The `understudy` subagent is told to **explicitly flag**
anything it couldn't do or is unsure about, rather than guess. If it returns
incomplete, wrong, or insufficient information, the main agent may do the task
itself or re-delegate once with a sharper spec — it won't ping-pong. A stalled
delegation costs more than just doing the work.

## Toggle it on and off

Ships **OFF** — it changes how the agent works, so it's opt-in.

```
/understudy on        # enable delegation
/understudy off       # disable, main agent handles tools itself
/understudy status    # show current state
/understudy           # toggle
```

State is a marker file at `~/.claude/understudy.enabled` (existence = ON). It
lives in your home directory, so the setting survives plugin updates. Turning it
on takes effect on your next prompt; it's re-established automatically in new
sessions and after compaction.

## How it's wired

- **`agents/understudy.md`** — the Haiku subagent: read/search/run tools
  (`Read, Grep, Glob, Bash, WebFetch, WebSearch`), no file mutation, prompted to
  return the smallest report that fully answers and to flag gaps instead of
  guessing.
- **`hooks/`** — `SessionStart` (startup/resume/clear/**compact**) injects the
  full directive; `UserPromptSubmit` injects a one-line reminder each turn. Both
  are no-ops when the plugin is OFF.
- **`commands/understudy.md`** — the on/off/status/toggle slash command.

## Composes with output-discipline

Pairs naturally with the [output-discipline](../output-discipline) plugin:
output-discipline blocks context-flooding commands before they run; understudy
moves the work that survives that gate onto a cheaper model. The understudy
subagent follows output discipline too, keeping its own context lean while it works.

## License

MIT
