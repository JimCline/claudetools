# Subagent Directive Relay — a portable design

**Problem:** a plugin injects a behavioral directive via `SessionStart` /
`UserPromptSubmit` hooks and intends it to bind subagents too — but those hooks
never fire for subagents, so every subagent runs directive-blind.

**Solution:** make the directive travel inside the dispatch prompt, written
there by a `PreToolUse` hook on the `Agent` tool — the only event that fires
*before* a subagent exists, and the only one that can rewrite the dispatch.

Reference implementations:
[task-gopher ≥ 0.6.0](https://github.com/JimCline/claudetools/tree/main/task-gopher)
([`hooks/pretooluse-nudge.mjs`](https://github.com/JimCline/claudetools/blob/main/task-gopher/hooks/pretooluse-nudge.mjs))
for the `updatedInput` rewrite, and
[comment-discipline ≥ 0.2.0](https://github.com/JimCline/claudetools/tree/main/comment-discipline)
([`hooks/posttooluse-inject.mjs`](https://github.com/JimCline/claudetools/blob/main/comment-discipline/hooks/posttooluse-inject.mjs))
for the targeted-injection flavor. Verified against Claude Code docs and
behavior, 2026-07 (`code.claude.com/docs/en/hooks`, `/sub-agents`).

**If you read only one section, read "Rewrite in flight".** That is the design;
everything after it is either how to choose a different channel, or a fallback
for harnesses that don't honor the rewrite.

## The facts that force this design

Which hook events touch subagents (everything else is main-session only):

| Event | Relationship to subagents |
|---|---|
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied` | Fire **inside** the subagent's loop, with `agent_id`/`agent_type` in the input. The only events that can inject `additionalContext` into a subagent's conversation. |
| `SubagentStart` / `SubagentStop` | Fire around the lifecycle, but `SubagentStart`'s `additionalContext` lands in the **parent's** context. Side-effects only (logging, state init). |
| `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop` | **Never** triggered by subagent activity. |

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
   in one of two flavors:
   - **5a. Directive shapes everything the subagent does** (how it plans, what
     it delegates) → **`PreToolUse` rewrite on `Agent`**. Delivery must be at
     spawn, because the behavior starts immediately. See "Rewrite in flight".
   - **5b. Directive only matters at a specific tool boundary** (how it writes
     code, how it runs commands) → relay clause + **targeted injection**: a
     `PostToolUse` hook on *those* tools that injects the directive once per
     `agent_id`. Charges the tokens only to agents that reach the boundary,
     needs no deny, and leaves the `Agent` tool free (see Composition). The
     tradeoff is that the *first* such tool call is unguarded — the relay
     clause is what covers it.

## Rewrite in flight — the primary mechanism

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

This is strictly better than the alternatives: no model has to cooperate, the
parent spends no output tokens, there is no bounce or retry, and it needs no
state file — so no counters, no fail-open, no concurrency. Because
`PreToolUse` also fires inside a subagent's loop, nested dispatches are
rewritten too and the chain is automatic.

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
   *mentions* the sentinel, e.g. when agents discuss the plugin itself), deny —
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

**Injection backstops cannot detect a relay.** A `PostToolUse` hook has no view
of the dispatch prompt, so it fires whether or not the parent relayed. The two
channels are additive, not complementary: a correctly relayed subagent receives
the directive twice. Budget for that duplication rather than claiming the
backstop "only fires when the relay didn't happen" — it can't know that.

Worked examples in this repo:

| Plugin | Channel | Why |
|---|---|---|
| task-gopher | `updatedInput` rewrite on `Agent` | Delegation shapes everything; needs at-spawn delivery |
| comment-discipline | relay clause (below task-gopher's block) + `PostToolUse` injection on `Edit`/`Write`/`NotebookEdit` | Only matters when authoring; keeps off `Agent`, whose input task-gopher already owns |
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
      directive (full and compact), unlikely to appear incidentally
      (task-gopher: `[task-gopher: ON]`), and check it only within the first
      couple hundred characters of the prompt. Its only job here is telling an
      already-stamped prompt from a fresh one.
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
`updatedInput` on `Agent`. That needs a live probe — dispatch a real subagent
with a short prompt and have it report the first N characters and total length
of the task prompt it received. If it echoes text you never sent, the rewrite
is working. Re-run that probe after harness upgrades.

## Limits and upgrades

- **The rewrite can fail silently.** Delivery depends on the harness honoring
  `updatedInput` on `Agent`. If that stops, the dispatch still succeeds and the
  subagent simply never sees the directive — no error anywhere. The injection
  count in your audit log is the tell; re-run the live probe after upgrades.
- **It doesn't cover every way a subagent gets spawned.** The hook fires on
  `Agent`/`Task` *tool calls*. Agents spawned by other machinery (e.g. a
  workflow runner that creates them internally) never produce that event, so
  they receive nothing. Check your own audit log for injections you expected
  and didn't get.
- **In the deny flavor, the sentinel proves presence, not a faithful copy** —
  a paraphrased body with a copied first line passes. Embedding the directive
  in the deny reason makes verbatim copies the path of least resistance, but
  nothing enforces it. The rewrite has no such gap: the hook writes the text.
- Delivery is at dispatch-composition time, which is spawn time from the
  subagent's perspective — strictly better than first-tool-call
  `additionalContext` injection (one call late; misses agents that make only
  one such call), which remains a valid *backstop* for tool-boundary rules.
