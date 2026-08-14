---
description: Toggle task-gopher (Haiku delegation), strict mode, the destructive guard, and audit report. Usage: /task-gopher [on|off|status|strict [on|off]|report|log clear|guard [ask|block|off|status]|allow [list|clear]|relay-exempt [list|add|remove] <agent-type>]
argument-hint: "[on|off|status|strict [on|off]|report|log clear|guard [ask|block|off|status]|allow [list|clear]|relay-exempt [list|add|remove] <agent-type>]"
---

The user ran `/task-gopher` with argument: `$ARGUMENTS`

task-gopher uses these files under `~/.claude/`:
- `task-gopher.enabled` — delegation directive ON (existence = ON).
- `task-gopher.strict` — strict mode: a PreToolUse checkpoint that blocks the
  first direct retrieval of each turn once so you consciously consider dispatching
  to task-gopher. Strict is meaningful only while enabled, so turning strict ON
  also turns the plugin ON, and turning the plugin OFF also clears strict.
- `task-gopher.relay-exempt` — optional list of `subagent_type`s the relay must
  never stamp, one per line (`#` comments ignored). The gate already skips agents
  whose definition file declares a `tools:` list without `Agent`/`Task`; this file
  covers the ones it cannot read, notably SDK-defined agents that have no file on
  disk. Exempting an agent that CAN dispatch just means it stops being told to.
- `task-gopher.guard` — how the destructive guard resolves a destructive or
  outward-facing Bash command from the runner. Contents, not existence: `ask`
  (default when the file is absent — prompt the USER to approve, every time),
  `block` (hard-deny), or `off`. The guard is NOT part of the on/off toggle: it
  is live whenever the plugin is installed, since the runner stays dispatchable
  while the delegation directive is off.
- `task-gopher.allow` — commands the lead has vouched for, one
  `sessionId<TAB>command` per line, written when a dispatch prompt carries an
  `ALLOW-DESTRUCTIVE: <exact command>` line. In `ask` mode this does NOT skip
  the prompt — it is disclosed inside it. It becomes the actual release only in
  `block` mode, or where the permission mode means no prompt can reach a human.

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
- **`report`** (print the strict-mode audit summary): locate and run the report
  script — `node "${CLAUDE_PLUGIN_ROOT:-}/hooks/report.mjs" 2>/dev/null || node "$(ls -t ~/.claude/plugins/cache/*/task-gopher/*/hooks/report.mjs 2>/dev/null | head -1)"`.
  Show its output verbatim to the user; do not summarize or re-run any retrievals yourself.
- **`log clear`** (wipe the audit log): run
  `rm -f ~/.claude/task-gopher.log && echo "task-gopher: audit log cleared"`
- **`guard`** / `guard status`:
  `M=ask; [ -f ~/.claude/task-gopher.guard ] && M=$(tr -d "[:space:]" < ~/.claude/task-gopher.guard); case "$M" in ask|block|off) ;; *) M="ask (unrecognized value, using default)";; esac; echo "task-gopher destructive guard: $M"`
- **`guard ask`** (prompt the user to approve every destructive/outward command):
  `mkdir -p ~/.claude && printf 'ask\n' > ~/.claude/task-gopher.guard && echo "task-gopher guard: ASK (you approve each one)"`
- **`guard block`** (never prompt; hard-deny unless the lead wrote ALLOW-DESTRUCTIVE):
  `mkdir -p ~/.claude && printf 'block\n' > ~/.claude/task-gopher.guard && echo "task-gopher guard: BLOCK"`
- **`guard off`** (no guard at all — the runner may destroy and publish freely):
  `mkdir -p ~/.claude && printf 'off\n' > ~/.claude/task-gopher.guard && echo "task-gopher guard: OFF (runner is unrestricted)"`
- **`allow list`** (show the destructive-guard authorizations recorded so far):
  `if [ -s ~/.claude/task-gopher.allow ]; then cat ~/.claude/task-gopher.allow; else echo "no ALLOW-DESTRUCTIVE authorizations recorded"; fi`
- **`allow clear`** (revoke them all):
  `rm -f ~/.claude/task-gopher.allow && echo "task-gopher: destructive authorizations cleared"`
- **`relay-exempt`** / `relay-exempt list`:
  `if [ -s ~/.claude/task-gopher.relay-exempt ]; then echo "relay-exempt:"; grep -v '^\s*\(#\|$\)' ~/.claude/task-gopher.relay-exempt; else echo "relay-exempt: (empty — no user exemptions)"; fi`
- **`relay-exempt add <agent-type>`** (use the exact namespaced `subagent_type`,
  e.g. `github-pr-toolkit:thread-assessor`):
  `mkdir -p ~/.claude && touch ~/.claude/task-gopher.relay-exempt && grep -qxF "<agent-type>" ~/.claude/task-gopher.relay-exempt || echo "<agent-type>" >> ~/.claude/task-gopher.relay-exempt; echo "relay-exempt: <agent-type> exempt"`
- **`relay-exempt remove <agent-type>`**:
  `if [ -f ~/.claude/task-gopher.relay-exempt ]; then grep -vxF "<agent-type>" ~/.claude/task-gopher.relay-exempt > ~/.claude/task-gopher.relay-exempt.tmp && mv ~/.claude/task-gopher.relay-exempt.tmp ~/.claude/task-gopher.relay-exempt; fi; echo "relay-exempt: <agent-type> removed"`
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
> output you want. A complete order names where (paths, branch for git work),
> how (exact commands/method), what back (format + completeness bar: every
> match or first N), and what to do on failure (report and stop). Escape hatch: if it returns incomplete/wrong/insufficient
> info or reports it couldn't proceed, do it yourself or re-dispatch once with a
> sharper order — don't ping-pong more than about once. Do NOT copy the
> [task-gopher: ON] directive into dispatch prompts yourself: subagents don't
> inherit your context, so a PreToolUse hook rewrites each dispatch in flight to
> carry it, skipping the agents that have no Agent/Task tool to act on it.

If the result also says **STRICT**, note to the user that from now on the first
direct Read/Grep/Glob or retrieval-style Bash call of each turn will be blocked
once as a checkpoint; re-running the call proceeds.

If the result is **OFF**, confirm delegation is disabled and resume handling tool
work yourself.
