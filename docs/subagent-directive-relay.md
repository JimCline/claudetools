# Subagent Directive Relay — a portable design

**Problem:** a plugin injects a behavioral directive via `SessionStart` /
`UserPromptSubmit` hooks and intends it to bind subagents too — but those hooks
never fire for subagents, so every subagent runs directive-blind.

**Solution:** deliver the directive at spawn, by one of two channels. Either a
`PreToolUse` hook on the `Agent` tool rewrites the dispatch prompt in flight —
the only event that fires *before* the subagent exists and the only one that can
see what it was asked to do — or a `SubagentStart` hook injects
`additionalContext` as the subagent starts, which is simpler but blind to the
task. Which one you want depends on whether your directive's content varies with
the dispatch.

Reference implementations:
[task-gopher ≥ 0.6.0](https://github.com/JimCline/claudetools/tree/main/task-gopher)
([`hooks/pretooluse-nudge.mjs`](https://github.com/JimCline/claudetools/blob/main/task-gopher/hooks/pretooluse-nudge.mjs))
for the `updatedInput` rewrite, and
[comment-discipline ≥ 0.2.0](https://github.com/JimCline/claudetools/tree/main/comment-discipline)
([`hooks/posttooluse-inject.mjs`](https://github.com/JimCline/claudetools/blob/main/comment-discipline/hooks/posttooluse-inject.mjs))
([`hooks/subagentstart.mjs`](https://github.com/JimCline/claudetools/blob/main/comment-discipline/hooks/subagentstart.mjs))
for at-spawn `SubagentStart` injection, with
[`hooks/posttooluse-inject.mjs`](https://github.com/JimCline/claudetools/blob/main/comment-discipline/hooks/posttooluse-inject.mjs)
as its targeted-injection backstop. Verified against Claude Code docs and
behavior, 2026-07 (`code.claude.com/docs/en/hooks`, `/sub-agents`).

**On evidence.** Claims below are marked *live-probed* or *doc-sourced*, and the
distinction is load-bearing. An earlier revision of this document ruled out the
`SubagentStart` channel on a doc-sourced claim that sat in the same table, in
the same voice, as a live-probed one — and it was wrong (see the `SubagentStart`
row). The mechanism that got an instrument pointed at it was sound; the premise
that was merely read was not. Nobody builds an experiment for the road they've
decided not to take, so mark the basis and treat an unprobed premise as
provisional no matter how confidently the docs state it.

**If you read two sections, read "Rewrite in flight" and "At-spawn
injection".** Those are the two working channels: rewrite the dispatch prompt
when your directive's content depends on the task, inject at `SubagentStart`
when it doesn't. Everything else is how to choose between them, or a fallback
for harnesses that honor neither.

## The facts that force this design

Which hook events touch subagents (everything else is main-session only):

| Event | Relationship to subagents |
|---|---|
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied` | Fire **inside** the subagent's loop, with `agent_id`/`agent_type` in the input. Can inject `additionalContext` into a subagent's conversation, but only from the first tool call onward. *(live-probed)* |
| `SubagentStart` | Fires at spawn and **can** inject `additionalContext` into the **subagent's** context — but **only** via a JSON `hookSpecificOutput` payload. Plain stdout is discarded silently, which is what makes this event look dead: it is the opposite of `SessionStart`, where bare stdout *is* injected. Input carries `agent_id`, `agent_type`, `cwd`, `prompt_id`, `session_id`, `transcript_path` — but **not the dispatch prompt**, so injected content cannot depend on the task. *(live-probed)* |
| `SubagentStop` | Side-effects only (logging, state teardown). |
| `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop` | **Never** triggered by subagent activity. *(live-probed: a dispatched subagent reports no `SessionStart` block while the parent has one from the same hook.)* |

The `SubagentStart` row previously read "`additionalContext` lands in the
parent's context — side-effects only." That was wrong, and the way it was wrong
is instructive: the docs never said it. Checked 2026-07-29, `hooks-guide` and
the hooks reference are **silent** on where `SubagentStart`'s `additionalContext`
is delivered. The claim was an inference from that silence, written down in the
voice of a documented fact and then reused as a premise.

Corrected on live evidence gathered in a separate session: a probe
hook emitting JSON `additionalContext` was quoted back verbatim by the spawned
subagent, under the harness-generated label `SubagentStart hook additional
context:`, including a key list the hook generated at runtime — while a
`PreToolUse` hook on the same dispatch independently measured the prompt at 392
characters, ruling out prompt-carriage. Three probes plus one end-to-end run
with a ~7.5 KB payload delivered untruncated.

**Independently reproduced 2026-07-29** on a second machine with a different
instrument: comment-discipline's own `SubagentStart` hook, whose side-log
records every invocation. A dispatched subagent quoted the payload back under
the harness label `SubagentStart hook additional context:`, the side-log gained
exactly one line, and its agent id matched the subagent's own. That plugin
registers no `PreToolUse` hook at all, so it has no way to write into a dispatch
prompt — the text is attributable to `SubagentStart` alone.

The tell that exposed it: two `SubagentStart` hooks sitting side by side, one
emitting JSON and working, one emitting plain stdout via `printf` and never
arriving. Same event, same lifecycle, one variable.

What a subagent's starting context contains: its own agent-`.md` body (as
system prompt), the full CLAUDE.md hierarchy, and the dispatch prompt. It does
**not** contain the parent's conversation, auto-memory, or anything hooks
injected into the parent. Built-in `Explore`/`Plan` skip CLAUDE.md and lack the
`Agent` tool. Subagents can spawn subagents (≈3 levels), so enforcement must
chain.

## Choosing a channel (decision tree)

1. **Static, always-on content** → put it in CLAUDE.md. Subagents inherit it
   at true spawn time; zero machinery. Wrong for plugins (they'd have to edit a
   user-owned file, and it ignores any ON/OFF toggle).
2. **Content for agents you author** → put it in the agent's `.md` body.
3. **Rules you can enforce mechanically** (e.g. a command-blocking `PreToolUse`
   gate) → you may not need delivery at all: tool-event hooks already fire
   inside subagent loops, and deny reasons teach the rule in-context.
4. **Directives that shouldn't reach subagents at all** → do nothing. Some
   plugins genuinely want suppression (an orchestration protocol that would
   make a worker start orchestrating). The platform already suppresses; just
   don't mistake the dead `isSubagent()` branch in a `SessionStart` hook for
   the mechanism that's doing it.
5. **Toggleable plugin directives that shape behavior** → **this relay design**,
   in one of three flavors:
   - **5a. Directive shapes everything the subagent does, and its content
     depends on the dispatch prompt** → **`PreToolUse` rewrite on `Agent`**.
     Delivery is at spawn, and this is the only channel that can see what the
     subagent was asked to do. See "Rewrite in flight".
   - **5b. Directive only matters at a specific tool boundary** (how it writes
     code, how it runs commands) → relay clause + **targeted injection**: a
     `PostToolUse` hook on *those* tools that injects the directive once per
     `agent_id`. Charges the tokens only to agents that reach the boundary,
     needs no deny, and leaves the `Agent` tool free (see Composition). The
     tradeoff is that the *first* such tool call is unguarded — the relay
     clause is what covers it.
   - **5c. Directive is static / task-independent** → **`SubagentStart` with a
     JSON `additionalContext` payload**. Simpler than 5a wherever it applies.
     See "At-spawn injection".

**Choosing between 5a and 5c** — the payload shape decides it, not preference.
`SubagentStart` receives no dispatch prompt, so it cannot classify the task,
build a retrieval query from it, or vary its content by what was asked. If your
directive's text is the same every time, take 5c. If it must depend on the
dispatch, take 5a. Prefer 5c when both would work: it needs no sentinel, no
dedup, no double-stamp check, and it doesn't contend for the `Agent` tool's
input (see Composition).

## Rewrite in flight — rewriting the dispatch prompt

A `PreToolUse` hook can return `hookSpecificOutput.updatedInput` to replace a
tool's arguments before it runs, and **this works on the `Agent` tool**: return
the original `tool_input` with `prompt` replaced by `directive + "\n\n" +
prompt`, and the spawned subagent receives the rewritten prompt.

```js
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: { ...toolInput, prompt: DIRECTIVE + "\n\n" + toolInput.prompt },
  },
}))
```

Verified live (2026-07-29, Claude Code 2.1.x): a probe agent dispatched with a
~300-character prompt reported receiving a ~7,300-character one beginning with
the injected directive. The docs describe `updatedInput` generically but do not
document it for `Agent`, so re-verify after harness upgrades.

Pass the **whole** `tool_input` back with only `prompt` changed, so the result
is correct whether the harness merges or replaces the object.

This is strictly better than the deny-and-retry fallback below: no model has to
cooperate, the parent spends no output tokens, there is no bounce or retry, and
it needs no state file — so no counters, no fail-open, no concurrency. Because
`PreToolUse` also fires inside a subagent's loop, nested dispatches are
rewritten too and the chain is automatic. It is *not* strictly better than
at-spawn injection (5c): where a directive is task-independent, 5c wins on every
axis listed there. What the rewrite uniquely has is sight of the dispatch
prompt.

Still skip: dispatches to your own runner/worker agents, agent types that
cannot act on the directive, and prompts that already carry the sentinel near
the top (don't duplicate a hand-pasted copy).

**The one real risk.** Claude Code's auto-mode permission classifier evaluates
the *final* dispatch prompt — orchestrator text plus anything a hook injected.
A third-party plugin, `context-mode`, hit exactly this: its `Agent` hook
appended a ~4.5KB routing block to every dispatch, whose "keep raw bytes out of
the transcript" phrasing pattern-matched an oversight-evasion signature, so
dispatches were rejected as "Auto-Mode Bypass" *no matter how clean the
orchestrator's own prompt was*, and re-sending stripped didn't help because the
injection was re-added downstream. Keep injected directives plainly about the
work (cost, style, correctness) and free of anything that reads like evading
oversight or hiding activity. If dispatches start failing that way, fall back to
the deny flavor below, where the text is the parent's own.

## At-spawn injection — `SubagentStart` with JSON

When the directive's content doesn't depend on the dispatch prompt, this is the
shortest path. A `SubagentStart` hook returning `additionalContext` puts the
text directly into the spawning subagent's context, before its first turn:

```js
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "SubagentStart",
    additionalContext: DIRECTIVE,
  },
}))
```

**The JSON envelope is mandatory.** A `SubagentStart` hook that `printf`s or
heredocs the same text as bare stdout delivers nothing, with no error and no log
line. This trips people because `SessionStart` accepts plain stdout as context,
so the habit transfers and fails silently. If you are porting a `SessionStart`
hook, converting its output format is the whole job.

This one *is* in the docs, by exclusion — they state that stdout is added to
context for `UserPromptSubmit`, `UserPromptExpansion`, and `SessionStart`, and
that list is closed. `SubagentStart` isn't on it. No per-event table spells out
the consequence, which is why the rule is easy to miss even when you've read the
page.

Payload gotchas:

- **The key is `agent_type`, not `subagent_type`.** `subagent_type` is the
  `PreToolUse` `tool_input` name. A hook gating on the wrong one silently never
  matches. Gate on `cwd` when you need something present in both events.
- **No dispatch prompt** — that's the channel's real limitation, and the reason
  5a still exists.
- `agent_id`, `prompt_id`, and `session_id` are all present, so per-dispatch
  state keying works the same as in the fallback design.

Size: a ~7.5 KB payload was delivered untruncated in an end-to-end run (the
receiving agent acted on the full contents). No truncation threshold has been
found; if you're pushing well past that, measure rather than assume.

What this flavor buys over the rewrite, where both apply:

- No sentinel, no dedup, no double-stamp risk — it isn't a prompt, so the whole
  class of failures below (including the sentinel-in-the-test-prompt trap) does
  not exist.
- No exposure to the auto-mode permission classifier, since the text never
  becomes part of a dispatch prompt. That retires "the one real risk" above for
  such plugins.
- No contention for the `Agent` tool's input, which matters more than it looks —
  see Composition.
- **Better coverage.** It fires for every spawn, not only those originating from
  an `Agent`/`Task` *tool call* — confirmed live against workflow-spawned agents,
  which the rewrite cannot reach at all. See Limits.

## The fallback design (deny and retry)

Use this only where `updatedInput` isn't honored. Three cooperating parts:

1. **Relay instruction inside the directive itself.** The injected directive
   tells the agent: *when you dispatch any subagent (except <exempt targets>),
   copy this entire block verbatim to the top of the dispatch prompt.* A
   verbatim copy contains the relay instruction, so it chains to grandchildren
   automatically. Over-delivery must be harmless — give the directive a
   self-exclusion gate at the top (task-gopher's tier gate) so agents it
   doesn't apply to can ignore it.
2. **Sentinel check with deny at `PreToolUse` (matcher includes `Agent`).**
   Spawning a subagent is just a tool call; `PreToolUse` fires in the spawning
   agent's loop with the full `tool_input` (prompt + `subagent_type`) visible,
   *before the subagent exists*. If a sentinel substring that every faithful
   copy contains is absent from the **top of the prompt** (top-anchor the
   check — an unanchored `includes()` false-passes any prompt that merely
   *mentions* the sentinel), deny —
   **and embed the full directive in the deny reason**, so the retry is a
   mechanical copy from the message just received, not a reconstruction from
   distant context (that's where paraphrase drift lives). The parent re-issues;
   the subagent spawns with the directive at position one of its context.
   Because `PreToolUse` also fires inside subagent loops, nested dispatches hit
   the same checkpoint.
3. **Guardrails.** Both are load-bearing:
   - **Exemptions:** never bounce dispatches the directive shouldn't reach —
     the plugin's own runner/worker agents (match `tool_input.subagent_type`),
     and agent types that cannot act on it (the built-ins without the `Agent`
     tool: `Explore`, `Plan`, `statusline-setup`, `output-style-setup`).
     Exempt from *enforcement* only; a parent volunteering the directive there
     is harmless. Custom tool-less agents can't be enumerated, so also give the
     directive itself an escape clause ("no Agent tool? ignore this").
   - **Fail-open, everywhere:** after N bounces (task-gopher: 2) log it and
     allow. **Key the counter per (session_id, agent_id, prompt_id)** — all in
     the hook payload — in a small pruned map, NOT a single shared slot: the
     state file is shared machine-wide, so a single-slot counter lets
     interleaved sessions reset each other's count (starving the cap into an
     unbounded deny loop) while sibling agents in one turn would exhaust it
     for each other. Also allow on missing `prompt_id`, non-string `prompt`
     (schema drift), unwritable state, unparseable stdin. A missed relay
     degrades to today's behavior; a deny loop bricks the session.

Audit trail for this flavor: `relay-ok` / `relay-bounce` / `relay-forgone`
JSONL events, which also measure the real-world first-try relay rate. (The
rewrite flavor logs `relay-injected` / `relay-ok` instead — see below for why
that count matters.)

## Composition — don't stack deny gates on one tool

The docs state that all matching hooks for an event **run in parallel**, and
that when several return `additionalContext` for the same event *"Claude
receives all of the values."* But they are **silent** on how conflicting
`permissionDecision` results combine: whether every denying hook's
`permissionDecisionReason` is surfaced, or only one wins. That gap is load-
bearing when two plugins both gate the `Agent` tool — if only one reason
surfaces, each dispatch costs an extra round trip per plugin, and the plugins'
independent fail-open counters multiply.

So: **at most one plugin should sentinel-deny a given tool.** A second plugin
wanting the same tool should use flavor 5b (targeted injection on a *different*
tool), where the documented aggregation behavior applies and no deny is needed.
The rewrite flavor sidesteps this entirely — it never denies — but two plugins
*both* rewriting one tool's input is equally undefined, so the rule generalizes:
**one plugin owns a given tool's input.**

**The top slot belongs to the rewriting plugin.** A top-anchored sentinel check
(first ~200 chars) and a second plugin that also puts its block at the top are a
live conflict: whichever lands first pushes the other's sentinel out of the
window, so the first plugin re-stamps a prompt that was already stamped (or, in
the deny flavor, bounces every dispatch until fail-open). Only one plugin may
claim the top; any other relaying directive must be placed *below* whatever
already leads the prompt. Note the rewrite mechanism prepends, so it naturally
takes the top — a second plugin relaying by instruction must say "below any
directive already leading the prompt."

**`SubagentStart` dissolves this contention.** The "one plugin owns a given
tool's input" rule has a cost that isn't obvious: once one plugin claims
`Agent` — in this repo, task-gopher — every *other* plugin needing at-spawn
delivery is pushed to flavor 5b and its unguarded-first-call tradeoff. Flavor 5c
gives those plugins at-spawn delivery without touching `Agent` at all, and the
docs say `additionalContext` from multiple hooks on one event is aggregated
("Claude receives all of the values"), so several plugins can inject at
`SubagentStart` concurrently without a defined-behavior gap. This is arguably
the most useful consequence of the channel: it removes a forced tradeoff rather
than just adding an option.

**Injection backstops cannot detect a relay.** A `PostToolUse` hook has no view
of the dispatch prompt, so it fires whether or not the parent relayed. The two
channels are additive, not complementary: a correctly relayed subagent receives
the directive twice. Budget for that duplication rather than claiming the
backstop "only fires when the relay didn't happen" — it can't know that.

Worked examples in this repo:

| Plugin | Channel | Why |
|---|---|---|
| task-gopher | `updatedInput` rewrite on `Agent` | Delegation shapes everything; needs at-spawn delivery |
| comment-discipline ≥ 0.3.0 | `SubagentStart` JSON injection (5c), backstopped by `PostToolUse` on `Edit`/`Write`/`NotebookEdit` | Directive is static, so it needs no sight of the dispatch prompt; keeps off `Agent`, whose input task-gopher already owns. Migrated from a hand-relay clause, which cost parent output tokens and left edit #1 unguarded. |
| output-discipline | nothing added | Its `PreToolUse` Bash gate already fires inside subagent loops; deny reasons teach in-context |
| agent-hierarchy | nothing added | Suppression is the intent; role agents carry their own `agents/*.md` |

Also weigh the cumulative prompt cost: each relaying plugin adds its directive
to every dispatch it covers. Scoping a relay clause ("copy this only when
dispatching an agent that will write code") keeps that bounded.

## Implementation checklist

For the rewrite (the primary design):

- [ ] `hooks.json`: `PreToolUse` matcher includes `Agent|Task` (match against
      `tool_name` **inside the script too** — the matcher is an unanchored
      regex, so e.g. `TaskCreate` or `ReadMcpResourceTool` may also route
      events to your script; non-dispatch tools must fall through unharmed).
- [ ] Pick a sentinel: a short literal that opens every injected form of the
      directive (full and compact), and check it only within the first couple
      hundred characters of the prompt. Its only job here is telling an
      already-stamped prompt from a fresh one.
- [ ] Make the sentinel **implausible in prose _about_ your plugin**, not merely
      unlikely to appear by accident. `[task-gopher: ON]` is good because it
      reads as machine state; `[my-plugin relay]` is precisely what a human
      writes when discussing the relay. This is not an edge case — it is the
      default outcome the first time you test, debug, or document your own
      relay, because those prompts necessarily contain the sentinel. It has
      already burned one live probe: the prompt asked the subagent whether the
      sentinel was in its context, so the hook matched its own sentinel in the
      *question* and logged "already stamped" while injecting nothing.
- [ ] Script logic, in order: plugin enabled? → payload parse (fail open) →
      inside own runner (`agent_type`)? allow → is `Agent`/`Task` call? →
      target exempt (`subagent_type`)? allow → `prompt` not a string? allow →
      sentinel near top of `prompt`? allow (already stamped) → emit
      `updatedInput` with the directive prepended. **No state, no counters, no
      fail-open** — there is nothing to persist and nothing to livelock.
- [ ] Tell the directive text NOT to relay by hand: agents that copy it are
      spending expensive output tokens on something the hook already did.
      Keep the self-exclusion gate at the top ("Haiku-tier / no Agent tool →
      ignore this") so over-delivery stays harmless.
- [ ] Log an injection count. It is the only way to notice if a harness
      upgrade silently stops honoring `updatedInput`.
- [ ] Version-bump everywhere your marketplace requires (this repo: plugin's
      `plugin.json` **and** root `marketplace.json`).

For at-spawn injection (flavor 5c), the list is much shorter:

- [ ] `hooks.json`: a `SubagentStart` entry. Emit **JSON**
      (`hookSpecificOutput.additionalContext`) — bare stdout is discarded
      silently.
- [ ] Gate on `agent_type` (not `subagent_type`) to skip your own runner agents,
      and on `cwd` for per-project enable/disable. No sentinel, no dedup, no
      state.
- [ ] Keep the self-exclusion gate in the directive text anyway — you can't
      enumerate every custom agent type, and over-delivery must stay harmless.
- [ ] Log each injection. Same reasoning as the rewrite: silent-failure channels
      need an external tell.

Only if you fall back to the deny flavor, or add a `PostToolUse` backstop —
both of which need shared state:

- [ ] Make state **append-only**, not a JSON map rewritten in place. Hook state
      lives in one file shared by every concurrent session and parallel
      subagent, so a read-modify-write silently drops entries when two hooks
      interleave (measured: ~3 of 12 lost in a parallel fan-out), and a reader
      landing in `writeFileSync`'s truncation window sees a torn file and
      discards *everything*. Store one short line per event — an `O_APPEND`
      write is atomic, so concurrent writers just queue — and derive state by
      scanning (set membership, or counting occurrences). Compact occasionally
      via temp-file + `renameSync`, keeping the most recent lines.
- [ ] `mkdirSync` the state directory before writing — it may not exist — and
      prefer failing toward delivery (inject/allow anyway) over failing silent
      when state can't be persisted. A dead safety net is worse than a
      duplicated directive, and a silent one is never diagnosed.
- [ ] Clear the state file wherever the plugin's `off` path clears state.
- [ ] Add the relay paragraph to every injected directive text (full + any
      per-turn reminder), naming the exemptions and, for the deny flavor,
      warning that a checkpoint bounces non-compliant dispatches.

## Test plan (HOME-redirect harness, no install needed)

Run the hook directly — `printf '<payload>' | HOME=$FAKEHOME node hooks/<gate>.mjs`
— and assert on exit code + stdout. Cover at minimum: plugin OFF passthrough;
dispatch-to-exempt-target allowed; missing sentinel → `updatedInput` whose
prompt carries both the directive and the original task text, with every other
`tool_input` field preserved and no `permissionDecision`; sentinel at top →
plain allow (no double-stamp); sentinel buried mid-prompt → still stamped;
non-string `prompt` → allow; inside-own-runner passthrough (`agent_type`);
`Task` alias; malformed/empty stdin; any pre-existing gate in the same script
unchanged; real `~/.claude` untouched afterward. Assert too that retired
machinery is actually gone — a grep for the old symbols catches the dead
references docs and reports keep referring to. Working example:
[`task-gopher/tests/test-relay-gate.sh`](https://github.com/JimCline/claudetools/blob/main/task-gopher/tests/test-relay-gate.sh)
(46 cases).

What the harness **cannot** tell you: whether the harness actually honors
`updatedInput` on `Agent`, or delivers `SubagentStart` `additionalContext`. That
needs a live probe — dispatch a real subagent and have it report the first N
characters and total length of the task prompt it received, plus verbatim any
text labelled `SubagentStart hook additional context`. If it echoes text you
never sent, the channel works. Re-run after harness upgrades.

Three rules that make the difference between a probe and a wasted afternoon:

- **The probe prompt must not contain the sentinel or marker it is testing
  for.** Otherwise your own gate matches the question text and skips. Have the
  probe report the prompt's *length and leading characters* and infer injection
  from those.
- **Have the probe hook write a side log on every invocation**, before deciding
  anything. Without it, "hook never ran" and "hook ran but the mechanism was
  ignored" are indistinguishable — and the first one is far more common than it
  looks (see next).
- **Probe under a throwaway version number.** Editing `hooks/` in a working tree
  registered as a directory marketplace has **no effect**: the copy that loads
  is version-pinned under
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, refreshed only
  when `plugin.json`'s `version` changes. So a hook edit without a version bump
  is inert, and shipping probe code under the version you intend to release
  poisons that cache entry so later edits at that version don't take. `hooks.json`
  isn't re-read mid-session either, so every probe needs a **fresh session**.
  Wiring the hook at user level in `~/.claude/settings.json` skips the cache
  entirely. This exact trap produced a false negative indistinguishable from
  "the mechanism doesn't work."

## Limits and upgrades

- **The rewrite can fail silently.** Delivery depends on the harness honoring
  `updatedInput` on `Agent`. If that stops, the dispatch still succeeds and the
  subagent simply never sees the directive — no error anywhere. The injection
  count in your audit log is the tell; re-run the live probe after upgrades.
- **The rewrite doesn't cover every way a subagent gets spawned.** The hook
  fires on `Agent`/`Task` *tool calls*. Agents spawned by other machinery (e.g.
  a workflow runner that creates them internally) never produce that event, so
  they receive nothing. Measured in this repo: a 47-agent workflow run produced
  zero relay events. Check your own audit log for injections you expected and
  didn't get.
- **`SubagentStart` DOES close that gap.** *(live-probed 2026-07-29 — this was
  the document's single most consequential open question.)* A workflow was run
  with two agents, neither spawned by an `Agent` tool call. Both received the
  `SubagentStart` payload and quoted it back under the harness label, and the
  hook's own side-log gained exactly two lines whose agent ids matched the two
  workflow agents. So flavor 5c reaches spawns that the rewrite structurally
  cannot. **This is the strongest reason to prefer 5c** where the directive is
  task-independent: it is not merely simpler, it has strictly better coverage.
- **Whether `SubagentStart`'s `additionalContext` *also* reaches the parent is
  unverified.** Both can be true. It changes no advice here — but it would
  explain how the original parent-only claim formed.
- **`SubagentStart` can fail silently too**, in two distinct ways: wrong output
  format (bare stdout), and gating on `subagent_type` instead of `agent_type`.
  Neither produces an error. Log every injection.
- **In the deny flavor, the sentinel proves presence, not a faithful copy** —
  a paraphrased body with a copied first line passes. Embedding the directive
  in the deny reason makes verbatim copies the path of least resistance, but
  nothing enforces it. The rewrite has no such gap: the hook writes the text.
- Both spawn-time channels (5a and 5c) beat first-tool-call `additionalContext`
  injection, which arrives one call late and misses agents that never reach the
  boundary. 5b remains a valid *backstop* for tool-boundary rules — but it is no
  longer the only option for a plugin that can't claim the `Agent` tool.
