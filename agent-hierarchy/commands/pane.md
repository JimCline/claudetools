---
description: Launch a file-backed agent as an interactive Claude Code session in a tmux pane you can watch and talk to, and delegate work to it. Usage: /pane <agent> [right|below] | list | ask <key> <text> | close <key|all> | doctor
---

The user ran `/agent-hierarchy:pane` with argument: `$ARGUMENTS`

A pane is a **real, top-level Claude Code session** running one agent, in its
own tmux session, which the user can watch and type into. It is not a subagent:
it is a peer session that happens to be restricted to an agent's definition, and
it can only ever **reply** — it has no way to contact you first.

All the mechanics live in a helper CLI. Run it and **show its output verbatim**;
do not recompute, re-render, or summarise what it prints. Resolve it once:

```
PANE="${CLAUDE_PLUGIN_ROOT:-}/hooks/pane.mjs"; [ -f "$PANE" ] || PANE="$(ls -t ~/.claude/plugins/cache/*/agent-hierarchy/*/hooks/pane.mjs 2>/dev/null | head -1)"
```

## Grammar

```
/agent-hierarchy:pane <agent> [right|below]     open a pane running <agent>
/agent-hierarchy:pane open <agent> [right|below]  explicit form
/agent-hierarchy:pane list                      show live panes
/agent-hierarchy:pane ask <key|agent> <text…>   send work (user-confirmed)
/agent-hierarchy:pane close <key|agent>         close one
/agent-hierarchy:pane close all                 close every pane you opened
/agent-hierarchy:pane doctor                    dependency + health check
```

`open`, `list`, `ask`, `close`, and `doctor` are **reserved first words**. An
agent genuinely named one of them is shadowed; `/pane open list right` is the
documented escape.

## Orientation: prefer the words

**`right` = side by side. `below` = stacked.** The letters `v` and `h` are
accepted, and they name the **divider**: `v` is a vertical divider, so it puts
the panes side by side; `h` is a horizontal divider, so it stacks them. Use the
words in everything you say to the user — never echo a letter or a flag back to
them, and never say "vertical" or "horizontal" without saying which way the
panes end up.

## Every open and every ask needs the user's approval first

This is unconditional and it does **not** respect `handoffs: "auto"`. A pane
send drives a long-lived, separately-billed interactive session the user is
watching, by injecting keystrokes into their terminal; opening one starts that
session. Both earn their own confirmation regardless of the handoff setting.

When `handoffs` is `"confirm"`, this confirmation **replaces** the directive's
per-dispatch question. Ask once, not twice.

### Opening

1. Run `node "$PANE" open --agent <name> --orient <right|below> --dry-run --session "<your gate id>"`.
   The gate id is the session id the agent-hierarchy directive gave you; pass it
   so `close all` can scope to your own panes.
2. Read the dry-run output. If it says `permission prompt required: yes`,
   `/pane` could not rule out that the agent can execute — its toolset includes
   `Bash` or `Edit`, or its definition is missing, unreadable, or unrestricted —
   and **you must ask the user which permission mode to open it with** before
   launching. The gate fails safe: it asks whenever execution cannot be ruled
   out, so never present a non-prompting pane as proof the agent cannot
   execute. Offer exactly these four, with these descriptions:
   - **manual** — prompts for anything beyond reads. Safest; the pane will sit
     and wait if nobody is attached to answer.
   - **acceptEdits** — auto-accepts file edits and safe filesystem commands.
     **It does not cover general `Bash`**, so the pane still stalls on a
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
confirm the open.

### Asking

1. `node "$PANE" list` to find the key.
2. AskUserQuestion showing: the pane key, the agent, the model, the permission
   mode, where it is, a one-line summary of the work, and the first ~100
   characters of the prompt. If `list` marks the pane's definition as
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

4. It blocks until the pane replies (default 300s) and prints the reply. Show it
   verbatim. A prompt over 2000 characters is written to a file in the pane's
   mailbox and delivered as a pointer, which the output tells you about.

If it times out, it prints the last 20 lines of the pane so the user can see
whether it is sitting on a permission prompt, and leaves the request
outstanding. Offer: keep waiting (run `send` again is **not** the way — the
reply still lands on disk; re-run `list`), attach with `tmux attach -t <key>`,
or close the pane.

## Known differences from a subagent

Say these to the user when they matter; they are not obvious and neither is
detectable from inside the pane.

- A paned role may run on a **different model** than the same role would as a
  subagent. `model: inherit` on a subagent means "the model of the main
  conversation", but a pane *is* a main conversation, so it uses the user's
  **default** model rather than yours. Pass `--model` to pin it.
- A paned role may also have a **different tool surface**. `--agent` applies the
  definition's *denials* to whatever toolset a top-level session would have, and
  that base set is not the same as a subagent's. There is no equivalent of
  `--model` for this.
- Specifically: **a paned Architect has no `Grep` and no `Glob`** (measured). It
  is therefore materially weaker at research than the same Architect as a
  subagent. Prefer the subagent path for research-heavy Architect work; use a
  pane when the point is to watch and talk to it. The pane keeps the `Agent`
  tool, so it can still delegate a search to a runner.
- You cannot detect or correct either difference.

## What a pane may not do

The pane is told, at startup: it is not the Orchestrator; its final assistant
message is the entire reply and everything else is discarded; artifacts go to
disk with the absolute path in the reply; it may not open panes. Ordinary
subagent dispatch remains correct for it — panes specifically are what it may
not nest.

A turn the **user** types into the pane directly is never relayed to you. That
conversation is between them and the pane.

## Two copies of a definition

If the user develops plugins from a local-path marketplace, an agent definition
can exist twice: the installed copy and the live checkout. `open` reads both;
when they differ it computes every policy from both, takes the stricter answer
of each, shows both paths, and warns (set
`panes.onDefinitionDivergence: "refuse"` to make it refuse instead — there is
no "ignore"). When the copies are identical it says nothing. `/pane doctor`
reports any stale installed tree and names the resync command.

## Requirements

tmux is mandatory; `/pane doctor` reports it, along with whether the optional
iTerm2 presentation layer is available. Without iTerm2 the pane still runs and
orientation is inert — the user attaches with `tmux attach -t <key>`, which
every command prints. `doctor` also compares installed agent definitions
against a local-path marketplace's checkout, and names any process that
outlived a closed pane's process group (report only).

Pick the ONE case matching the argument, run the helper, and show its output
verbatim.
