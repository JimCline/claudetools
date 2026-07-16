# task-gopher

A Claude Code plugin that makes the main, high-reasoning agent **dispatch the
legwork to a cheap Haiku runner** — so your expensive model tokens go to
judgment, not to tool output.

## The idea

You don't send your most expensive person to fetch things. A gopher (go-fer) does
the errands. `task-gopher` gives the lead agent a cheap one to dispatch the legwork
to: running the builds and tests, sifting the logs, grepping the tree, reading the
files — and fetching back a **compact report**. The lead agent reasons over that
report.

Tool output is expensive twice over: once when the pricey reasoning model
generates the tool call, and again on **every subsequent turn**, because tool
results are re-sent as input tokens until the next compaction. A single
unfiltered test run or big `grep` can park thousands of lines in the reasoning
model's context and keep charging for them. Having a cheap model do that work —
and return only the distilled answer — cuts both.

## What it does

When enabled, the plugin injects a directive telling the main agent to dispatch to
a bundled `task-gopher` subagent (pinned to `model: haiku`) for:

- **Tool/output-heavy** steps — test suites, builds, installs, verbose or
  long-running bash, log sifting.
- **Information gathering that can be summarized** — "find where X is defined",
  "list the callers of Y", "summarize module Z", reading or searching across many
  files.

The main agent keeps everything that needs reasoning — design decisions,
correctness and security judgment, tradeoffs, and writing/editing code. For a
task that needs reasoning, it **splits** the work: task-gopher runs the step or
gathers the raw material and reports back compactly; the main agent reasons over
the report.

The decision the main agent makes is deliberately shallow (it shouldn't burn
reasoning deciding what to dispatch):

> Would doing this myself flood my context, or is it a mechanical task I can
> specify exactly? → dispatch it. Does it need my judgment? → keep the judgment,
> dispatch only the legwork. When unsure, keep it.

It's a **default, not a per-step preference.** The failure mode the directive
guards against is talking yourself out of it one step at a time — "this single
read / grep / diff is quick enough to just do myself." Individually small
retrievals are exactly what floods context in aggregate, so the trigger is the
*kind* of work, not the size of any one step. When several small retrievals come
up together (read these 3 files, grep for X, diff against main), the agent
**batches them into one order** rather than doing them inline. And an explicit
skill/command override (e.g. a GitHub worker that owns the MCP connection) wins —
that's a deliberate exception, not a violation.

## task-gopher is a runner, never a decider

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

## Who may delegate — the tier gate

Delegation is gated by **model tier, not by position in the agent tree**: *any*
Sonnet-tier-or-higher agent — the top-level agent OR a subagent — may dispatch to
the Haiku task-gopher. A Haiku-tier agent may not, which is also what stops
task-gopher (itself Haiku) from dispatching to task-gopher and recursing.

The rationale: the whole point is to move cheap legwork off an *expensive*
reasoner. If the agent doing the work is already Haiku, there's nothing to save —
Haiku delegating to Haiku is pure overhead. But a capable reasoner should push
legwork down regardless of whether it's the main agent or a subagent it was itself
spawned into.

There's a catch that shapes the implementation: **Claude Code hook payloads carry
no model field.** (Verified against the CLI — the payload is `session_id`,
`transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `agent_id`, `agent_type`,
and `effort`; that `effort` is the thinking level `low|medium|high`, not a
capability tier. There is no "reasoning index" exposed to hooks.) So the hook
*can't* read the tier. Instead:

- The hook injects the directive to **every** agent (except task-gopher itself,
  which it skips by name via `agent_type` so the recursion-prone runner never even
  sees it).
- The directive **opens with a tier gate**: if you are Haiku-tier, ignore it and do
  the work yourself; if you are Sonnet-tier or higher, follow it. Each agent
  self-excludes based on its own model identity — which the model knows reliably,
  far better than any payload field could tell it.
- task-gopher's own prompt is the hard backstop: it never delegates onward, period.

> **Note — the tier gate is currently soft.** Because no model/tier field is
> exposed to hooks, the gate relies on each agent recognizing its own tier and
> self-excluding; the plugin cannot enforce it. This is reliable for "am I
> Haiku?" but it is not a hard guarantee. If a future Claude Code version adds a
> model or capability-tier field to the hook payload, this becomes a hard gate —
> the hook would suppress injection for Haiku-tier agents directly. Tracked as a
> `TODO(hard-gate)` in `hooks/directive.mjs`.

### Escape hatch

Dispatching isn't a trap. If task-gopher returns incomplete, wrong, or
insufficient information — or reports it couldn't proceed because an order needed a
decision — the main agent may do the task itself or re-dispatch once with a
sharper, fully-specified order. It won't ping-pong; a stalled dispatch costs more
than just doing the work.

## Toggle it on and off

Ships **OFF** — it changes how the agent works, so it's opt-in.

```
/task-gopher on         # enable delegation
/task-gopher off        # disable, main agent handles tools itself
/task-gopher status     # show current state
/task-gopher            # toggle
/task-gopher strict     # enable strict mode (also turns delegation on)
/task-gopher strict off # back to guidance-only
```

State is a marker file at `~/.claude/task-gopher.enabled` (existence = ON). It
lives in your home directory, so the setting survives plugin updates. Turning it
on takes effect on your next prompt; it's re-established automatically in new
sessions and after compaction.

## Strict mode — the double-check gate

The directive is guidance; a capable agent can still rationalize *"this one read
is quick enough to just do myself"* on every small step and never actually
delegate. Strict mode adds a **hard checkpoint** on top: when it's on, a
`PreToolUse` hook **blocks a direct retrieval** — a `Read`/`Grep`/`Glob`, or
retrieval-style `Bash` (`grep`, `find`, `cat`, `git diff`, a test/build run, …) —
with a message telling the agent to consider dispatching to task-gopher and to
batch this with other reads/greps/diffs into one order. Re-running the same call
proceeds. It never fires on non-retrieval commands (`git commit`, `mkdir`, …) or
inside task-gopher itself.

It doesn't just nudge once and then give up for the turn — it **escalates on
consecutive bypasses**. It blocks the first retrieval of a turn, lets the next two
direct retrievals through silently, then **re-blocks on the 3rd consecutive
bypass**, and every 3rd after that. So an agent that keeps pulling things into its
own context gets re-checkpointed instead of quietly drifting.

**Dispatching to task-gopher resets the streak** — good behavior buys a clean
slate, so an agent that delegates is left alone while one that doesn't keeps
getting stopped. A "turn" is one user prompt (tracked by the payload's
`prompt_id`); a new turn re-arms the first-retrieval checkpoint.

> **Honest limit:** this is a *forcing function, not a guarantee*. The hook can't
> verify the agent genuinely reconsidered — a re-run always passes, and it can't
> tell a retrieval-read from a read the agent needs for its own reasoning/editing
> (which is why it escalates rather than hard-blocking every read). It makes the
> deliberate choice explicit; it doesn't force a good one. That's also why strict
> mode is opt-in and separate from base ON — and why it keeps an audit log so you
> can check whether the choices *were* good.

### Audit log and report

Strict mode writes an append-only JSONL log to `~/.claude/task-gopher.log` — one
line per **checkpoint** (the gate blocked), **bypass** (a direct retrieval done
anyway, recording the exact file/command), and **dispatch** (a delegation to
task-gopher), each stamped with a `prompt_id` and time. Because a re-run always
passes, this log is where the gate actually gets its teeth: it's the record of
what the agent chose to do directly.

```
/task-gopher report      # summarize the log
/task-gopher log clear   # wipe it
```

The report shows totals, the **bypass-to-dispatch ratio** (lower is better), which
tools get bypassed most, and the most recent bypasses with *what was run
directly* — so you can see at a glance whether the orchestrator is being
deliberate or just rubber-stamping past the checkpoint. Example:

```
checkpoints:    3  (times the gate blocked)
bypasses:       4  (direct retrievals done anyway)
dispatches:     1  (delegations to task-gopher)
bypass/dispatch ratio: 4.00  (lower is better)
bypassed tools: Read 3, Bash 1
recent bypasses (last 4) — what was run directly:
  - 2026-07-16 14:40:00  Read: src/app.ts
  - 2026-07-16 14:40:00  Bash: git diff main -- config/
  ...
```

## How it's wired

- **`agents/task-gopher.md`** — the Haiku runner: read/search/run tools
  (`Read, Grep, Glob, Bash, WebFetch, WebSearch`), no file mutation, prompted to
  execute exact orders only, return the smallest report that fully answers,
  stop-and-report rather than decide, and never delegate onward.
- **`hooks/`** — `SessionStart` (startup/resume/clear/**compact**) injects the
  full directive; `UserPromptSubmit` injects a one-line reminder each turn;
  `PreToolUse` (strict mode only) is the escalating checkpoint that also writes the
  audit log; `report.mjs` renders that log. All hooks are no-ops when the plugin is
  OFF (and the checkpoint also requires strict mode), and no-ops inside task-gopher
  itself. See "Who may delegate" for the tier gate.
- **`commands/task-gopher.md`** — the on/off/status/toggle/strict/report/log-clear
  slash command.

## Composes with output-discipline

Pairs naturally with the [output-discipline](../output-discipline) plugin:
output-discipline blocks context-flooding commands before they run; task-gopher
moves the work that survives that gate onto a cheaper model. The task-gopher
runner follows output discipline too, keeping its own context lean while it works.

## License

MIT
