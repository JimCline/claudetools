---
description: Toggle task-gopher (Haiku delegation) and strict mode. Usage: /task-gopher [on|off|status|strict [on|off]]
---

The user ran `/task-gopher` with argument: `$ARGUMENTS`

task-gopher uses two marker files under `~/.claude/`:
- `task-gopher.enabled` — delegation directive ON (existence = ON).
- `task-gopher.strict` — strict mode: a PreToolUse checkpoint that blocks the
  first direct retrieval of each turn once so you consciously consider dispatching
  to task-gopher. Strict is meaningful only while enabled, so turning strict ON
  also turns the plugin ON, and turning the plugin OFF also clears strict.

Pick the ONE case matching the argument and run its command with the Bash tool:

- **`on`** / `enable`:
  `mkdir -p ~/.claude && touch ~/.claude/task-gopher.enabled && echo "task-gopher: ON"`
- **`off`** / `disable` (also clears strict):
  `rm -f ~/.claude/task-gopher.enabled ~/.claude/task-gopher.strict ~/.claude/task-gopher.nudge && echo "task-gopher: OFF (strict cleared)"`
- **`strict`** / `strict on`:
  `mkdir -p ~/.claude && touch ~/.claude/task-gopher.enabled ~/.claude/task-gopher.strict && echo "task-gopher: ON + STRICT"`
- **`strict off`**:
  `rm -f ~/.claude/task-gopher.strict ~/.claude/task-gopher.nudge && echo "task-gopher: strict OFF (delegation still ON)"`
- **`status`**:
  `if [ -f ~/.claude/task-gopher.enabled ]; then if [ -f ~/.claude/task-gopher.strict ]; then echo "task-gopher: ON + STRICT"; else echo "task-gopher: ON"; fi; else echo "task-gopher: OFF"; fi`
- **empty / `toggle` / anything else** (toggles the base on/off; leaves strict as-is unless turning off):
  `if [ -f ~/.claude/task-gopher.enabled ]; then rm -f ~/.claude/task-gopher.enabled ~/.claude/task-gopher.strict ~/.claude/task-gopher.nudge && echo "task-gopher: OFF"; else mkdir -p ~/.claude && touch ~/.claude/task-gopher.enabled && echo "task-gopher: ON"; fi`

Run the single matching command and report the resulting state to the user in one line.

If the result includes **ON**, also adopt this behavior immediately for the rest
of the session (the SessionStart hook re-establishes it in future sessions):

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

If the result also says **STRICT**, note to the user that from now on the first
direct Read/Grep/Glob or retrieval-style Bash call of each turn will be blocked
once as a checkpoint; re-running the call proceeds.

If the result is **OFF**, confirm delegation is disabled and resume handling tool
work yourself.
