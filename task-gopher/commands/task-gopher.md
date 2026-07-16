---
description: Toggle task-gopher (Haiku delegation) on/off, or show status. Usage: /task-gopher [on|off|status]
---

The user ran `/task-gopher` with argument: `$ARGUMENTS`

task-gopher is controlled by a single marker file — `~/.claude/task-gopher.enabled`
(its existence means ON). Do exactly the following based on the argument:

- **`on`** (or `enable`): run
  `mkdir -p ~/.claude && touch ~/.claude/task-gopher.enabled && echo "task-gopher: ON"`
- **`off`** (or `disable`): run
  `rm -f ~/.claude/task-gopher.enabled && echo "task-gopher: OFF"`
- **`status`**: run
  `test -f ~/.claude/task-gopher.enabled && echo "task-gopher: ON" || echo "task-gopher: OFF"`
- **empty / `toggle` / anything else**: run
  `if [ -f ~/.claude/task-gopher.enabled ]; then rm -f ~/.claude/task-gopher.enabled && echo "task-gopher: OFF"; else mkdir -p ~/.claude && touch ~/.claude/task-gopher.enabled && echo "task-gopher: ON"; fi`

Run the single matching command with the Bash tool and report the resulting
state (ON or OFF) to the user in one line.

If the resulting state is **ON**, also adopt this behavior immediately for the
rest of the session (the SessionStart hook will re-establish it in future
sessions, but activate now):

> Dispatch expensive tool work to the `task-gopher` subagent (pinned to Haiku)
> instead of doing it yourself — reserve your own high-reasoning tokens for
> judgment. Dispatch tool/output-heavy steps (tests, builds, installs, verbose
> or long-running bash, log-sifting) and retrieval/summarization (find/list/
> summarize, reading or searching many files). Keep ALL reasoning — design,
> correctness, and security judgment — for yourself; for a reasoning task, have
> `task-gopher` gather the raw material or run the step and return a compact
> report, then reason over it. task-gopher never reasons or decides, so hand it
> a complete, decision-free order and state the exact expected result / compact
> output you want. Escape hatch: if it returns incomplete/wrong/insufficient
> info or reports it couldn't proceed, do it yourself or re-dispatch once with a
> sharper order — don't ping-pong more than about once.

If the resulting state is **OFF**, confirm that delegation is disabled and stop
dispatching to the task-gopher subagent; resume handling tool work yourself.
