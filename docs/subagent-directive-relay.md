# Subagent Directive Relay — a portable design

**Problem:** a plugin injects a behavioral directive via `SessionStart` /
`UserPromptSubmit` hooks and intends it to bind subagents too — but those hooks
never fire for subagents, so every subagent runs directive-blind.

**Solution:** make the directive travel inside the dispatch prompt, and enforce
that mechanically with a `PreToolUse` hook on the `Agent` tool — the only event
that fires *before* a subagent exists.

Reference implementation: [task-gopher ≥ 0.5.0](https://github.com/JimCline/claudetools/tree/main/task-gopher)
([`hooks/pretooluse-nudge.mjs`](https://github.com/JimCline/claudetools/blob/main/task-gopher/hooks/pretooluse-nudge.mjs)).
Verified against Claude Code docs 2026-07 (`code.claude.com/docs/en/hooks`,
`/sub-agents`).

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
4. **Toggleable plugin directives that shape behavior** → **this relay design.**

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
