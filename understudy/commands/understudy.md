---
description: Toggle understudy (Haiku delegation) on/off, or show status. Usage: /understudy [on|off|status]
---

The user ran `/understudy` with argument: `$ARGUMENTS`

understudy is controlled by a single marker file — `~/.claude/understudy.enabled`
(its existence means ON). Do exactly the following based on the argument:

- **`on`** (or `enable`): run
  `mkdir -p ~/.claude && touch ~/.claude/understudy.enabled && echo "understudy: ON"`
- **`off`** (or `disable`): run
  `rm -f ~/.claude/understudy.enabled && echo "understudy: OFF"`
- **`status`**: run
  `test -f ~/.claude/understudy.enabled && echo "understudy: ON" || echo "understudy: OFF"`
- **empty / `toggle` / anything else**: run
  `if [ -f ~/.claude/understudy.enabled ]; then rm -f ~/.claude/understudy.enabled && echo "understudy: OFF"; else mkdir -p ~/.claude && touch ~/.claude/understudy.enabled && echo "understudy: ON"; fi`

Run the single matching command with the Bash tool and report the resulting
state (ON or OFF) to the user in one line.

If the resulting state is **ON**, also adopt this behavior immediately for the
rest of the session (the SessionStart hook will re-establish it in future
sessions, but activate now):

> Delegate expensive tool work to the `understudy` subagent (pinned to Haiku)
> instead of doing it yourself — reserve your own high-reasoning tokens for
> judgment. Delegate tool/output-heavy steps (tests, builds, installs, verbose
> or long-running bash, log-sifting) and retrieval/summarization (find/list/
> summarize, reading or searching many files). Keep design, correctness, and
> security judgment for yourself; for a reasoning task, have `understudy` gather
> the raw material and return a compact report, then reason over it. Give it a
> precise, self-contained task and state the exact compact output you want.
> Escape hatch: if it returns incomplete/wrong/insufficient info or reports it
> couldn't do the task, do it yourself or re-delegate once with a sharper spec —
> don't ping-pong more than about once.

If the resulting state is **OFF**, confirm that delegation is disabled and stop
deferring to the understudy subagent; resume handling tool work yourself.
