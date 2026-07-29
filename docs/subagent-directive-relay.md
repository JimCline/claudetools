# Subagent Directive Relay — a portable design

**Problem:** a plugin injects a behavioral directive via `SessionStart` /
`UserPromptSubmit` hooks and intends it to bind subagents too — but those hooks
never fire for subagents, so every subagent runs directive-blind.

**Solution:** make the directive travel inside the dispatch prompt, and enforce
that mechanically with a `PreToolUse` hook on the `Agent` tool — the only event
that fires *before* a subagent exists.

Reference implementations:
[task-gopher ≥ 0.5.0](https://github.com/JimCline/claudetools/tree/main/task-gopher)
([`hooks/pretooluse-nudge.mjs`](https://github.com/JimCline/claudetools/blob/main/task-gopher/hooks/pretooluse-nudge.mjs))
for the deny-gate flavor, and
[comment-discipline ≥ 0.2.0](https://github.com/JimCline/claudetools/tree/main/comment-discipline)
([`hooks/posttooluse-inject.mjs`](https://github.com/JimCline/claudetools/blob/main/comment-discipline/hooks/posttooluse-inject.mjs))
for the targeted-injection flavor. Verified against Claude Code docs 2026-07
(`code.claude.com/docs/en/hooks`, `/sub-agents`).

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
     it delegates) → relay clause + `PreToolUse` sentinel-deny on `Agent`.
     Delivery must be at spawn, because the behavior starts immediately.
   - **5b. Directive only matters at a specific tool boundary** (how it writes
     code, how it runs commands) → relay clause + **targeted injection**: a
     `PostToolUse` hook on *those* tools that injects the directive once per
     `agent_id`. Charges the tokens only to agents that reach the boundary,
     needs no deny, and leaves the `Agent` tool free (see Composition). The
     tradeoff is that the *first* such tool call is unguarded — the relay
     clause is what covers it.

## The design

Three cooperating parts:

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

Optionally add an audit trail (`relay-ok` / `relay-bounce` / `relay-forgone`
JSONL events) so you can measure the real-world first-try relay rate.

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

**The top slot belongs to the gate.** A top-anchored sentinel check (first ~200
chars) and a second plugin that also says "copy this to the top of the prompt"
are a live conflict: whichever block lands first pushes the other's sentinel out
of the window, and the gate then denies every dispatch — bouncing until its
fail-open trips, on every dispatch. Only the deny-gating plugin may claim the
top; every other relaying directive must tell agents to place its block *below*
any directive already leading the prompt. Enforce this in the directive text,
because the gate cannot detect the ordering problem — it just sees a missing
sentinel.

**Injection backstops cannot detect a relay.** A `PostToolUse` hook has no view
of the dispatch prompt, so it fires whether or not the parent relayed. The two
channels are additive, not complementary: a correctly relayed subagent receives
the directive twice. Budget for that duplication rather than claiming the
backstop "only fires when the relay didn't happen" — it can't know that.

Worked examples in this repo:

| Plugin | Channel | Why |
|---|---|---|
| task-gopher | relay clause + deny gate on `Agent` | Delegation shapes everything; needs at-spawn delivery |
| comment-discipline | relay clause (below task-gopher's block) + `PostToolUse` injection on `Edit`/`Write`/`NotebookEdit` | Only matters when authoring; keeps off `Agent`, where task-gopher already denies |
| output-discipline | nothing added | Its `PreToolUse` Bash gate already fires inside subagent loops; deny reasons teach in-context |
| agent-hierarchy | nothing added | Suppression is the intent; role agents carry their own `agents/*.md` |

Also weigh the cumulative prompt cost: each relaying plugin adds its directive
to every dispatch it covers. Scoping a relay clause ("copy this only when
dispatching an agent that will write code") keeps that bounded.

## Implementation checklist

- [ ] `hooks.json`: `PreToolUse` matcher includes `Agent|Task` (match against
      `tool_name` **inside the script too** — the matcher is an unanchored
      regex, so e.g. `TaskCreate` or `ReadMcpResourceTool` may also route
      events to your script; non-dispatch tools must fall through unharmed).
- [ ] Pick a sentinel: a short literal that opens every injected form of the
      directive (full and compact), unlikely to appear incidentally
      (task-gopher: `[task-gopher: ON]`), and check it only within the first
      couple hundred characters of the prompt.
- [ ] Script logic, in order: plugin enabled? → payload parse (fail open) →
      inside own runner (`agent_type`)? allow → is `Agent`/`Task` call? →
      target exempt (`subagent_type`)? allow → `prompt` not a string? allow →
      sentinel near top of `prompt`? allow → no `prompt_id`? allow → bounce
      count ≥ N for this (session, agent, turn) key? allow (log forgone) →
      increment that key's counter (fail open if unwritable), deny with
      directive in reason.
- [ ] Add the relay paragraph to every injected directive text (full + any
      per-turn reminder), naming the exemptions and warning that a checkpoint
      bounces non-compliant dispatches.
- [ ] Make state **append-only**, not a JSON map rewritten in place. Hook state
      lives in one file shared by every concurrent session and parallel
      subagent, so a read-modify-write silently drops entries when two hooks
      interleave (measured: ~3 of 12 lost in a parallel fan-out), and a reader
      landing in `writeFileSync`'s truncation window sees a torn file and
      discards *everything*. Both of this repo's gates store one short line per
      event — an `O_APPEND` write is atomic, so concurrent writers just queue —
      and derive state by scanning (set membership, or counting occurrences).
      Compact occasionally via temp-file + `renameSync`, keeping the most
      recent lines so live contexts keep their counts.
- [ ] `mkdirSync` the state directory before writing — it may not exist — and
      prefer failing toward delivery (inject/allow anyway) over failing silent
      when state can't be persisted. A dead safety net is worse than a
      duplicated directive, and a silent one is never diagnosed.
- [ ] Clear the relay state file wherever the plugin's `off` path clears state.
- [ ] Version-bump everywhere your marketplace requires (this repo: plugin's
      `plugin.json` **and** root `marketplace.json`).

## Test plan (HOME-redirect harness, no install needed)

Run the hook directly — `printf '<payload>' | HOME=$FAKEHOME node hooks/<gate>.mjs`
— and assert on exit code + stdout. Cover at minimum: plugin OFF passthrough;
dispatch-to-exempt-target allowed; missing sentinel → deny whose reason
contains the directive; sentinel at top → allow; sentinel buried mid-prompt →
still deny; N bounces then fail-open; a different `session_id`/`agent_id`/
`prompt_id` gets its own bounce budget (no cross-context reset or exhaustion);
non-string `prompt` → allow; inside-own-runner passthrough (`agent_type`);
`Task` alias; malformed/empty stdin; any pre-existing gate in the same script
unchanged; real `~/.claude` untouched afterward. Working example:
[`task-gopher/tests/test-relay-gate.sh`](https://github.com/JimCline/claudetools/blob/main/task-gopher/tests/test-relay-gate.sh)
(36 cases).

## Limits and upgrades

- The sentinel proves *presence*, not a *faithful copy* — a paraphrased body
  with a copied first line passes. In practice the deny-reason-carries-the-text
  mechanism makes verbatim copies the path of least resistance.
- Delivery is at dispatch-composition time, which is spawn time from the
  subagent's perspective — strictly better than first-tool-call
  `additionalContext` injection (one call late; misses tool-less agents),
  which remains a valid *backstop* if you want belt-and-suspenders.
- **Untested upgrade:** `PreToolUse` supports `hookSpecificOutput.updatedInput`
  (replaces tool arguments before the tool runs). If it works on the `Agent`
  tool's `prompt` — the docs demonstrate it only for regular tools — the hook
  could append the directive silently and the deny/retry bounce disappears
  entirely. Verify empirically before building on it; if it works, the
  sentinel deny becomes the fallback for harness versions without it.
