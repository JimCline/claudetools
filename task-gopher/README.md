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

The plugin ships a second bundled agent, `smart-gopher` (pinned to `model: sonnet`)
— the escalation target for delegated work that genuinely needs judgment along
the way, not just execution. See "When to escalate to smart-gopher" below.

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

...and smart-gopher is a decider about the *work*, never about the *project*. It
reasons about which file/call-site is meant, whether evidence disagrees, what a
confusing module actually does — and hands back design, architecture, security,
and scope calls to the lead exactly the way task-gopher hands back a gap.

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

### Writing orders — the four-part contract

The runner sees nothing but the dispatch prompt — it cannot see the
orchestrator's context, and it will not fill gaps. Worse, it may not *notice*
a gap: it runs the order literally, wherever and however it happens to land.
So every order carries four things:

- **Where** — absolute paths/cwd, and for git-touching work the exact repo and
  branch/ref. An order that assumes "the branch we're on" runs on whatever is
  checked out. If a branch is named, the runner verifies it before running and
  stops on a mismatch; if none is named, it flags the branch it actually ran on.
- **How** — the exact method: commands, search patterns, files. "Find where X
  is defined" invites improvisation; "run `grep -rn 'class X' src/`, report
  every file:line" does not. The runner uses exactly the method given and never
  substitutes its own; a failed or empty result is reported as the result.
- **What back** — the report format, a size bound, and the completeness bar
  (every match vs first N). Compact never means incomplete: the runner returns
  everything the order asks for, and anything cut to meet a size bound is named
  and counted, never silently dropped.
- **What if** — what to do on failure or empty results: almost always "report
  the exact outcome and stop", never try an alternative method uninvited.

An order the orchestrator can't specify to that level still contains a
judgment call — the directive tells it to resolve that itself first, because
handing Haiku an order with room for judgment doesn't delegate the judgment,
it randomizes it.

### A dispatch must compress

task-gopher only earns its keep when its **report is smaller than the raw material
it read** — it reads a lot and returns a little. The anti-pattern to avoid:
ordering it to *read a whole file and hand the contents back verbatim*. That
returns just as many tokens to the orchestrator's context, with an extra hop and
no saving. So the directive tells the orchestrator: if you genuinely need a full
file in front of you, **read it yourself**; otherwise **narrow the ask** — grep or
search and return only the matching `file:line` plus a little context, the one
function you care about, a direct answer, or a summary. *"Where is X handled, and
what does that code look like?"* — not *"send me all of foo.ts."* If you can't name
a compact expected output smaller than the source, narrow it or do it yourself.
The gopher's own prompt backs this up: it distills rather than pasting whole files.

## The runner never destroys, and never publishes

A runner that makes no judgments must not be allowed to take actions that
*require* one. The dangerous shape is not a runner deciding to delete something
— it is a runner whose ordered command **fails**, reaching for a bigger hammer
to make it succeed. `git worktree remove` becomes `git worktree remove
--force`, and the safety that just refused was the only thing standing between
the order and the work it destroyed.

So a PreToolUse guard classifies every `Bash` command the runner makes and, per
pipeline stage, **asks you to approve it** — the risk is yours, so the
acceptance has to be yours too. What it intercepts:

- **Destruction** — `rm -rf`/`rm -f`, `git reset --hard`, `git clean -fdx`,
  `git worktree remove`/`prune`, `git branch -D`, `git restore`,
  `git checkout --`, `git rebase`, `git commit --amend`, `git stash drop`,
  history rewrites, `find -delete`, in-place `sed -i`, recursive
  `chmod`/`chown`, `rsync --delete`, `dd`, `shred`, `docker`/`kubectl`/`helm`
  teardown, `terraform destroy`/`apply`, `dropdb`, SQL `DROP`/`TRUNCATE`.
- **Anything that leaves the machine** — `git push`, `gh pr`/`issue`/`release`
  writes, `npm`/`cargo`/`gem`/`poetry` publish, write-method `curl`.

The guard runs whether or not the delegation directive is toggled on, because
the agent stays dispatchable either way — and it applies to **both bundled
runners, task-gopher and smart-gopher**. Nobody else's hands are tied.

**Known gap:** the guard only sees `Bash`. `smart-gopher` also has `Edit`/`Write`
(see "task-gopher is a runner, never a decider" above), and `hooks.json`'s
`PreToolUse` matcher is `Read|Grep|Glob|Bash|Agent|Task` — an `Edit`/`Write` call
never reaches this hook at all. That means smart-gopher can overwrite or truncate
a tracked file with no guard involvement. This is accepted for v1: git is the
recovery path for tracked files, and `git reset --hard` / `git checkout --` are
themselves guarded, so an *un-doable* edit still requires a guarded Bash command
downstream. Widening the guard to `Edit`/`Write` with a path-based classifier is
real follow-up work, not something bolted on here.

### Why it asks you and not the lead

The obvious shortcut is to let the dispatching model authorize the command:
it's the expensive reasoner, it has the context, and it would save you an
interruption. It is still the wrong answer. One model vouching for another is
not informed consent — it is the same failure one level up, and the thing being
risked (your work, your repo, your production database) is not the model's to
risk.

So the guard asks **every time**, including when the lead pre-authorized the
command. The authorization is not ignored; it appears *inside* the prompt as
context, so you can see that the lead intended this:

```
Reinstall dependencies in /Users/me/proj.
ALLOW-DESTRUCTIVE: rm -rf /Users/me/proj/node_modules
Then run `npm install` and report the exit code.
```

→ the prompt tells you the runner wants `rm -rf /Users/me/proj/node_modules`,
that the runner cannot judge whether that is correct, and that its lead vouched
for this exact command. You still decide.

Verbatim matching is what makes that disclosure trustworthy: a different path
is a different command, and a command merely *mentioned* in the order's prose
grants nothing.

### When nobody is at the keyboard

A prompt is worthless in an unattended run, so the guard checks the session's
`permission_mode` first. In `default`, `acceptEdits`, and `plan` it asks. In
`auto`, `dontAsk`, and `bypassPermissions` — modes that exist precisely to stop
asking — no prompt would reach a person, so it **denies** instead, and says so
in the denial. An `ALLOW-DESTRUCTIVE` line is the only release there, which is
what it is really for: pre-committing to a specific command in a run you won't
be watching.

If the payload carries no permission mode at all, that counts as unaskable too.
The guard never gambles that someone is watching.

### Guard modes

`~/.claude/task-gopher.guard` holds one word; absent means `ask`.

| mode | behavior |
| --- | --- |
| `ask` *(default)* | prompt you every time; deny where no prompt can reach you |
| `block` | never prompt — hard-deny, releasable only by `ALLOW-DESTRUCTIVE` |
| `off` | no guard |

Set it with `/task-gopher guard ask|block|off`.

### What it does not catch

Pattern matching is not a shell parser. A command hidden in a variable, a
base64 blob, or a script file that does the deleting will get through — this
stops improvisation, not an adversary. Prompts, denials, and authorized runs
are all written to the audit log; `/task-gopher report` prints them.

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

- The directive reaches the **main session** via the injection hooks and reaches
  **subagents** via the relay checkpoint (see "Reaching subagents" below —
  `SessionStart`/`UserPromptSubmit` never fire for subagents). task-gopher itself
  is skipped by name via `agent_type`, so the recursion-prone runner never sees
  the directive through either channel.
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

`smart-gopher` is itself Sonnet-tier, so by the tier gate alone it would be a
legal dispatcher. What actually stops it from dispatching onward is its
frontmatter's `disallowedTools: Agent, Task` — not the tier gate, which governs
who may dispatch *to* a gopher, not what a gopher can do once dispatched.

## When to escalate to smart-gopher

Reach for `smart-gopher` at exactly two moments: when you are about to do
tool-heavy work yourself only because you cannot write a decision-free order for
it, and when task-gopher has already stopped on a gap that is a judgment call
rather than a missing fact. It is not a general upgrade — anything you can
specify exactly still goes to task-gopher — and it is not a way to offload your
own design, correctness, security, or scope decisions, which stay with you
either way.

### The smart-gopher gate

Least-privilege-first is enforced, not just advised. A `PreToolUse` hook
checkpoints each **distinct** dispatch to `smart-gopher`: it denies the
attempt with a nudge to confirm task-gopher genuinely couldn't do it, the
same "re-run to proceed" shape as the strict retrieval checkpoint. Unlike
that checkpoint, this one:

- fires **once per exact request**, not once per turn — the *identical*
  retry goes straight through for good, but any **other** smart-gopher
  prompt, even later in the same session, gets its own fresh checkpoint.
  Passing the gate buys trust for that one request, not a session-wide pass;
- matches on the **exact prompt text** (hashed, not stored raw) — a
  trivially reworded retry is a different request and gets re-challenged.
  That fails toward more checkpointing, not less;
- does **not** require strict mode — it runs whenever the plugin is ON;
- only ever gates dispatches **to smart-gopher**. task-gopher dispatches are
  never checkpointed this way.

It's a speed bump, not a hard wall: it can't verify the agent genuinely
reconsidered, only that it paused once per request. `smart-gate-checkpoint`
lines in the audit log are the record of when it fired.

### Escape hatch

Dispatching isn't a trap. If task-gopher returns incomplete, wrong, or
insufficient information — or reports it couldn't proceed because an order needed a
decision — the main agent may do the task itself or re-dispatch once with a
sharper, fully-specified order. It won't ping-pong; a stalled dispatch costs more
than just doing the work.

## Reaching subagents — the relay checkpoint

The directive claims to bind subagents too — but Claude Code's `SessionStart`
and `UserPromptSubmit` hooks **never fire for subagents** (a subagent is not a
session). A subagent inherits its own agent file, the CLAUDE.md hierarchy, and
the dispatch prompt — nothing else. So without help, a Sonnet-tier subagent
would never see the directive at all.

`SubagentStart` is a second viable channel (it does reach the subagent, given a
JSON payload), but it carries no dispatch prompt, so it cannot skip dispatches
to task-gopher itself or to agents that have no `Agent` tool. This plugin needs
both of those, so it rewrites the prompt instead. See
[docs/subagent-directive-relay.md](../docs/subagent-directive-relay.md).

The fix is a **relay applied before the subagent exists**: spawning a subagent
is just an `Agent` tool call, and `PreToolUse`
fires for it in the spawning agent's loop with the full dispatch prompt visible
in the hook input — and, crucially, that hook can **rewrite the call before it
runs**. Whenever the plugin is ON (strict not required):

- The hook returns `hookSpecificOutput.updatedInput` with the directive
  prepended to the dispatch prompt. The subagent spawns with the directive at
  the top of its context. **The parent is never involved** — it doesn't see the
  rewrite, isn't bounced, and spends no output tokens copying anything.
- Because `PreToolUse` also fires inside a subagent's own loop, a subagent
  dispatching a grandchild gets the same rewrite. The chain is automatic and
  depends on no model's cooperation.
- **Skipped:** dispatches to either bundled gopher (they are the point, and
  neither can dispatch onward), built-in
  subagents without the `Agent` tool (`Explore`, `Plan`, `statusline-setup`,
  `output-style-setup`), and any prompt already carrying the `[task-gopher: ON]`
  sentinel near the top — a hand-pasted directive isn't duplicated. That check
  is top-anchored, so a mid-prompt *mention* of the sentinel doesn't count.
  The directive also opens with an escape clause for tool-less agents.

This replaced an earlier deny-and-retry design, where the hook rejected
directive-less dispatches and made the parent paste the block in. That worked,
but cost a round trip plus ~1.4K tokens of parent output per dispatch, and
needed per-context bounce counters to avoid deny loops. Rewriting in flight
costs none of it.

> **Honest limit:** delivery now depends on the harness honoring `updatedInput`
> on the `Agent` tool (verified live — a probe dispatched with a 300-character
> prompt reported receiving a 7,300-character one opening with the tier gate).
> If a future version stops honoring it, the relay fails **silently**: the
> dispatch still succeeds, the subagent just never sees the directive. The
> `relay-injected` count in `/task-gopher report` is how you'd notice.

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
getting stopped.

Each streak is scoped to one **agent** within one **turn** — keyed on
`session_id`, `agent_id`, and `prompt_id` together. All three matter. Keying on
the turn alone (as versions before 0.7.0 did) put the main agent, every subagent
it spawns, and every other Claude Code session on this machine into a single
shared counter, which broke the gate in both directions: a subagent almost never
got checkpointed at all, because the parent had already spent the turn's one
block before the subagent ran; and any other context writing its own id made the
next reader see a foreign turn and re-fire the first-retrieval checkpoint, so the
"re-run to proceed" escape hatch silently didn't work. Measured over five days of
real use, **76% of first-retrieval checkpoints fired on a turn already in
progress**, a median 2.7 seconds after that turn's previous event.

Subagents therefore get their own checkpoint now. That costs one extra round trip
per retrieval-doing subagent; dispatches to task-gopher itself are exempt, so the
runner never pays it.

> **Honest limit:** this is a *forcing function, not a guarantee*. The hook can't
> verify the agent genuinely reconsidered — a re-run always passes, and it can't
> tell a retrieval-read from a read the agent needs for its own reasoning/editing
> (which is why it escalates rather than hard-blocking every read). It makes the
> deliberate choice explicit; it doesn't force a good one. That's also why strict
> mode is opt-in and separate from base ON — and why it keeps an audit log so you
> can check whether the choices *were* good.

### Audit log and report

The plugin writes an append-only JSONL log to `~/.claude/task-gopher.log` — one
line per **checkpoint** (the strict gate blocked), **bypass** (a direct retrieval
done anyway, recording the exact file/command), **dispatch** (a delegation to
task-gopher), and **relay event** (`relay-injected` when a dispatch was stamped
with the directive, `relay-ok` when it already carried one), each stamped with a
`prompt_id` and time. Checkpoint and bypass lines require strict mode; dispatch
and relay lines are written whenever the plugin is ON. Because a re-run always
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
turns logged:   5  (3 saw the strict gate)
checkpoints:    3  (times the strict gate blocked)
bypasses:       4  (direct retrievals done anyway)
dispatches:     2  (delegations to task-gopher; 1 in strict-gated turns)
bypass/dispatch ratio: 4.00  (strict-gated turns only; lower is better)
bypassed tools: Read 3, Bash 1
subagent relay:  5 stamped, 1 already carried it
recent bypasses (last 4) — what was run directly:
  - 2026-07-16 14:40:00  Read: src/app.ts
  - 2026-07-16 14:40:00  Bash: git diff main -- config/
  ...
```

## How it's wired

- **`agents/task-gopher.md`** — the Haiku runner: read/search/run tools
  (`Read, Grep, Glob, Bash, WebFetch, WebSearch`), no file mutation, prompted to
  execute exact orders only, return the smallest report that fully answers,
  stop-and-report rather than decide, never delegate onward, verify a named
  branch before running, and never silently truncate.
- **`hooks/`** — `SessionStart` (startup/resume/clear/**compact**) injects the
  full directive; `UserPromptSubmit` injects a one-line reminder each turn;
  `PreToolUse` enforces the subagent **relay checkpoint** whenever ON, the
  per-request **smart-gopher gate**, and, in strict mode, the escalating
  retrieval checkpoint — all three write the audit log; `report.mjs` renders
  that log. All hooks are no-ops when the plugin is
  OFF, and no-ops inside task-gopher itself. See "Who may delegate" for the tier
  gate and "Reaching subagents" for the relay.
- **`commands/task-gopher.md`** — the on/off/status/toggle/strict/report/log-clear
  slash command.

## Composes with output-discipline

Pairs naturally with the [output-discipline](../output-discipline) plugin:
output-discipline blocks context-flooding commands before they run; task-gopher
moves the work that survives that gate onto a cheaper model. The task-gopher
runner follows output discipline too, keeping its own context lean while it works.

## License

MIT
