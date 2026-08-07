---
description: Create a durable agent — a long-lived, interactive Claude Code session running one file-backed agent in a tmux pane, which the Orchestrator hands work to instead of re-spawning cold subagents. Usage: /durable create <agent> [<agent>…] [right|below] | list | ask <key> <text> | wait <key> | cancel <key> | close <key|all> | doctor
---

The user ran `/agent-hierarchy:durable` with argument: `$ARGUMENTS`

A durable agent is a **real, top-level Claude Code session** running one agent,
in its own tmux session, which the user can watch and type into. It exists so
repeated work for the same role stops paying the subagent cold-start tax: its
context accumulates across sends and stays prompt-cached, its lifetime belongs
to the user, and everything it does is visible in its own terminal pane. It is
not a subagent: it is a peer session that happens to be restricted to an
agent's definition, and it can only ever **reply** — it has no way to contact
you first.

The rule of thumb, which you should say when the choice comes up: prefer the
durable agent for related follow-up work it already has context for; prefer a
fresh subagent for independent work or when a clean context matters — durable
context drifts, fills, and compacts on the agent's own schedule, invisibly to
you.

All the mechanics live in a helper CLI. Run it and **show its output verbatim**;
do not recompute, re-render, or summarise what it prints. Resolve it once:

```
PANE="${CLAUDE_PLUGIN_ROOT:-}/hooks/pane.mjs"; [ -f "$PANE" ] || PANE="$(ls -t ~/.claude/plugins/cache/*/agent-hierarchy/*/hooks/pane.mjs 2>/dev/null | head -1)"
```

## Grammar

```
/agent-hierarchy:durable create <agent> [right|below]   create one running <agent>
/agent-hierarchy:durable <agent> [right|below]          same, short form
/agent-hierarchy:durable create <agent> <agent> […] [right|below]
                                                        create several — one confirmation
/agent-hierarchy:durable list                           show live durable agents (every session's)
/agent-hierarchy:durable ask <key|agent> <text…>        send work (user-confirmed)
/agent-hierarchy:durable wait <key>                     pick up a reply after a send timed out
/agent-hierarchy:durable cancel <key>                   clear a stuck outstanding request
/agent-hierarchy:durable close <key|agent>              close one
/agent-hierarchy:durable close all                      close every one you created
/agent-hierarchy:durable doctor                         dependency + health check
```

In the batch form, every word after `create` is an agent name except a trailing
orientation word, which applies to all of them. An agent genuinely named
`right` or `below` is therefore shadowed in last position — put it earlier in
the batch, or create it on its own.

`create`, `open`, `list`, `ask`, `wait`, `cancel`, `close`, and `doctor` are
**reserved first words** (`open` is the older synonym of `create`; both reach
the same code). An agent genuinely named one of them is shadowed; `/durable create list
right` is the documented escape.

## Orientation: prefer the words

**`right` = side by side. `below` = stacked.** The letters `v` and `h` are
accepted, and they name the **divider**: `v` is a vertical divider, so it puts
the panes side by side; `h` is a horizontal divider, so it stacks them. Use the
words in everything you say to the user — never echo a letter or a flag back to
them, and never say "vertical" or "horizontal" without saying which way the
panes end up.

## Every create and every ask needs the user's approval first

This is unconditional and it does **not** respect `handoffs: "auto"`. An ask
drives a long-lived, separately-billed interactive session the user is
watching, by injecting keystrokes into their terminal; creating one starts that
session. Both earn their own confirmation regardless of the handoff setting.

When `handoffs` is `"confirm"`, this confirmation **replaces** the directive's
per-dispatch question. Ask once, not twice.

### Creating

1. Run `node "$PANE" create --agent <name> --orient <right|below> --dry-run --session "<your gate id>"`.
   The gate id is the session id the agent-hierarchy directive gave you; pass it
   so `close all` can scope to the agents you created.
2. Read the dry-run output. If it says `permission prompt required: yes`,
   the helper could not rule out that the agent can execute — its toolset
   includes `Bash` or `Edit`, or its definition is missing, unreadable, or
   unrestricted — and **you must ask the user which permission mode to open it
   with** before launching. The gate fails safe: it asks whenever execution
   cannot be ruled out, so never present a non-prompting create as proof the
   agent cannot execute. Offer exactly these four, with these descriptions:
   - **manual** — prompts for anything beyond reads. Safest; the agent will sit
     and wait if nobody is attached to answer.
   - **acceptEdits** — auto-accepts file edits and safe filesystem commands.
     **It does not cover general `Bash`**, so the agent still stalls on a
     permission prompt when it runs tests or builds.
   - **auto** — no routine prompts, with a background safety classifier.
   - **dontAsk** — auto-**denies** anything that would have prompted. It never
     stalls, but un-preapproved `Bash` silently fails rather than running. It is
     not a fix for stalling; it is a different failure.

   `bypassPermissions` is not offered and is refused from the command line. It
   is available only through `panes.permissionMode` in
   `~/.claude/agent-hierarchy.json`.
3. Put the whole thing to the user with AskUserQuestion: the agent, the resolved
   definition path, the model, the permission mode, and where the pane will
   land. If the dry-run's registry record shows
   `definition_source: "divergent"`, TWO copies of the definition exist and
   differ — show **both** paths, labelled, and say the policy was computed from
   both with the stricter answer winning. Then run the same command without
   `--dry-run`, adding `--permission-mode <their choice>` if one was needed.
4. Show the confirmation block verbatim.

If `permission prompt required: no`, skip step 2 — execution was ruled out by
the definition, or the mode is already settled by policy or config — but still
confirm the create.

### Creating several at once

`create` with several agent names — `/durable create architect reviewer below`
— is a batch: the same rules per agent, gathered into ONE confirmation. The
helper CLI stays one agent per invocation; you run it once per agent.

1. Dry-run each agent in order, collecting everything step 1–2 of "Creating"
   collects: definition path, model, `permission prompt required`, divergence.
   If any dry-run refuses (exit 2), report it and drop that agent from the
   batch — do not silently continue as if it were included.
2. Ask ONCE with AskUserQuestion: one question confirming the batch — every
   agent listed by name with its resolved definition, model, and where it will
   land — plus one permission-mode question (the four modes above) for each
   agent whose dry-run said `permission prompt required: yes`. AskUserQuestion
   holds at most 4 questions; a batch needing more splits into further calls,
   batch confirmation first. This satisfies "every create needs the user's
   approval": each agent is approved by name, gathered in one question — and
   in confirm flow it still replaces the handoff question. Ask once, not
   N times.
3. On approval, run the creates sequentially without `--dry-run`, adding each
   agent's chosen `--permission-mode`. Show every confirmation block verbatim.
4. If a create fails partway, STOP the batch and report both lists: what
   launched (live and tracked) and what did not. Nothing needs rolling back —
   each create is registered individually.

Placement: with iTerm2, every split subdivides the same window further, and the
helper warns at three. For a batch of three or more, offer to skip the splits
and have the user attach with `tmux attach -t <key>` in separate windows.

### Asking

1. `node "$PANE" list` to find the key.
2. AskUserQuestion showing: the key, the agent, the model, the permission
   mode, where it is, a one-line summary of the work, and the first ~100
   characters of the prompt. If `list` marks the agent's definition as
   `TWO COPIES DIFFER`, include both paths in the confirmation. Options:
   **Send** / **Edit the prompt first** / **Do it inline instead** /
   **Cancel**. "Do it inline" means you take that role's contract on yourself
   for this step.
3. On Send, heredoc the prompt into the helper on **stdin** — never as an
   argument:

```
node "$PANE" send --key <key> --summary "<one line>" <<'PROMPT'
…the prompt, any length, any characters…
PROMPT
```

   Write only the task. The helper stamps the reply contract onto every
   delivery itself — the `[ah-request <id>]` envelope, the echo requirement,
   final-results-only, the TL;DR structure — so do **not** add any of that by
   hand; you would just duplicate it.

4. It blocks until the agent replies (default 80s — deliberately under the
   Bash tool's 120s command kill, so the helper always gets to print its own
   guidance instead of dying mid-poll). **If you raise `--timeout` past ~90,
   you MUST also pass a Bash `timeout` parameter of at least
   `(--timeout + 30) × 1000` ms on that tool call**, or the harness kills the
   command first. For long tasks, don't raise it: let the send time out
   gracefully and pick the reply up later (step below). A **small reply is
   printed whole** — show it verbatim. A **large reply is withheld**: the
   helper writes the body to `reply.<reqid>.md` in the agent's mailbox and
   prints only its size, the path, the reply's `## TL;DR` section, and the
   list of `## ` section headings. Do NOT read the body file by default —
   that would defeat the point. Put it to the user with AskUserQuestion:
   **Fetch specific sections via task-gopher (Recommended)** — order it to
   print just the named `## ` sections from the body file — / **Read the
   whole file into context** / **Leave it on disk**. A prompt over 2000
   characters is likewise delivered as a file pointer, which the output tells
   you about.

A send to an agent that has not finished booting waits up to 30s for its
session identity file, then fails with "has not finished booting" — nothing was
sent and no request is outstanding. Peek or attach to see what it is doing,
then retry.

A timed-out send is the **normal ending for long tasks**, not a failure: it
prints the last 20 lines of the pane (so the user can see whether the agent is
sitting on a permission prompt) and leaves the request outstanding. The pickup
is `node "$PANE" wait --key <key>` — it re-polls for the reply without sending
anything, presents it through the same size gate, and with no request
outstanding it re-presents the newest reply file on disk. Run it when you come
back to that agent, or offer the user: wait now / keep working and collect
later / attach with `tmux attach -t <key>`. Running `send` again is **not** the
way (it is refused while the request is outstanding), and never read
`reply.<reqid>.json` files directly — that hands the full body to your context,
which is exactly what the size gate exists to prevent.

If the timeout output mentions **unmatched turns**, the agent (or a human
typing in the pane) produced a final message that did not carry the request's
`[ah-reply <id>]` echo line, so the relay saved it to the mailbox instead of
delivering it. Peek at the newest `unmatched.*.json` there; if the request is
genuinely dead, `node "$PANE" cancel --key <key>` clears it so a new send can
go out.

## Durable means durable

- The registry and the agents **outlive your session**. Close this
  conversation, come back tomorrow, and the architect is still warm — the new
  session's startup roster names it, and `list` finds it.
- Discovery is global: `list` shows every live durable agent on the machine,
  including ones other sessions created. Ownership is display metadata, not an
  ACL — any session may `ask` any durable agent. `close all` closes only the
  ones YOUR session created; `doctor` is the global sweep.
- One outstanding request per agent: a second `ask` while one is WORKING fails
  cleanly with "still working". Wait, peek, or pick another agent.
- Cleanup needs no daemon: every `list`, `send`, `close`, and Orchestrator
  session start verifies live agents against tmux and reaps dead entries.

## Known differences from a subagent

Say these to the user when they matter; they are not obvious and neither is
detectable from inside the pane.

- A durable role may run on a **different model** than the same role would as a
  subagent. `model: inherit` on a subagent means "the model of the main
  conversation", but a durable agent *is* a main conversation, so it uses the
  user's **default** model rather than yours. Pass `--model` to pin it.
- A durable role may also have a **different tool surface**. `--agent` applies
  the definition's *denials* to whatever toolset a top-level session would
  have, and that base set is not the same as a subagent's. There is no
  equivalent of `--model` for this.
- Specifically: **a durable Architect has no `Grep` and no `Glob`** (measured).
  It is therefore materially weaker at research than the same Architect as a
  subagent. Prefer the subagent path for research-heavy Architect work; use a
  durable agent when the point is continuity, or to watch and talk to it. It
  keeps the `Agent` tool, so it can still delegate a search to a runner.
- You cannot detect or correct either difference.

## What a durable agent may not do

The agent is told, at startup: it is not the Orchestrator; its final assistant
message is the entire reply and everything else is discarded; artifacts go to
disk with the absolute path in the reply; it may not create durable agents of
its own. Ordinary subagent dispatch remains correct for it — durable agents
specifically are what it may not nest.

A turn the **user** types into the pane directly is never relayed to you —
even mid-request. Every delivery carries a request id and the relay only
accepts a final message that opens with that id's `[ah-reply]` echo line; a
non-matching turn is saved to the mailbox as `unmatched.*.json`, the token
survives, and the turn that does echo still gets through. That conversation is
between them and the agent.

## Two copies of a definition

If the user develops plugins from a local-path marketplace, an agent definition
can exist twice: the installed copy and the live checkout. `create` reads both;
when they differ it computes every policy from both, takes the stricter answer
of each, shows both paths, and warns (set
`panes.onDefinitionDivergence: "refuse"` to make it refuse instead — there is
no "ignore"). When the copies are identical it says nothing. `/durable doctor`
reports any stale installed tree and names the resync command.

## Requirements

tmux is mandatory; `/durable doctor` reports it, along with whether the
optional iTerm2 presentation layer is available. Without iTerm2 the agent still
runs and orientation is inert — the user attaches with `tmux attach -t <key>`,
which every command prints. `doctor` also compares installed agent definitions
against a local-path marketplace's checkout, reaps registry entries stuck
mid-create, and names any process that outlived a closed pane's process group
(report only).

Pick the ONE case matching the argument, run the helper, and show its output
verbatim.
