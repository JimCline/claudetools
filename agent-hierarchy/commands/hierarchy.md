---
description: Assign a model to each agent-hierarchy role, or inspect/toggle the hierarchy. Usage: /hierarchy [init|status|set <role> <model>|on|off|flow [auto|confirm]|usage [day|week|month|all]]
---

The user ran `/hierarchy` with argument: `$ARGUMENTS`

agent-hierarchy stores its config as JSON at `.claude/agent-hierarchy.json` in
one of two scopes:

- **User** — `~/.claude/agent-hierarchy.json` (applies to every repo)
- **Project** — `<repo>/.claude/agent-hierarchy.json` (this repo only, committable)

Config shape (`version` is the schema version, always `1`):

```json
{
  "version": 1,
  "enabled": true,
  "roles": {
    "ultra-advisor": { "model": "fable" },
    "architect":     { "model": "opus" },
    "reviewer":      { "model": "sonnet" },
    "implementor":   { "model": "inherit" },
    "task-runner":   { "model": "haiku", "delegate": "task-gopher" }
  }
}
```

A config written before Ultra-Advisor existed is still valid: a missing
`ultra-advisor` key resolves to the shipped default (`fable`) with no warning,
so `version` stays `1`.

Resolution rules you must respect in everything below:

- Merge is **shallow per role**: a role object in the project config replaces the
  user-scope role object entirely — never merge key by key.
- `enabled`: **most-specific scope wins** (project overrides user).
- Valid models are **per role**. `architect`, `reviewer`, and `implementor` are
  reasoning roles: `opus`, `sonnet`, `fable`, `inherit` only — **`haiku` is
  never valid for a reasoning role** and must never be offered or written for
  one. `task-runner` (legwork, no reasoning) additionally allows `haiku`.
  `ultra-advisor` is the escalation apex and is **top-tier only: `fable` or
  `opus`** — not `sonnet`, and not `inherit` (inheriting a lesser session model
  would make the tier meaningless), so its model is always explicit.
  `inherit` means "omit the `model` parameter on the Agent call" — it is a
  legal value in this JSON file only, and must never be passed to the Agent
  tool literally.
- Roles are `ultra-advisor`, `architect`, `reviewer`, `implementor`,
  `task-runner`. The **Orchestrator is not configurable** — it is always the
  session agent itself.

The resolved table is printed by the plugin's own resolver, so it can never
drift from what the hook injects. Run it with Bash from the repo you care about:

```
node "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib-config.mjs" 2>/dev/null || node "$(ls -t ~/.claude/plugins/cache/*/agent-hierarchy/*/hooks/lib-config.mjs 2>/dev/null | head -1)"
```

Pick the ONE case matching the argument:

---

## empty or `init` — the wizard

1. Tell the user the **Orchestrator is fixed**: it is this session's own agent,
   whatever model the session runs on. Only the other five roles are assignable.
2. Check for existing config: read `~/.claude/agent-hierarchy.json` and
   `<cwd>/.claude/agent-hierarchy.json` (either may be absent). Also check
   whether task-gopher is installed — `ls -d ~/.claude/plugins/cache/*/task-gopher 2>/dev/null` or the presence of a `task-gopher:task-gopher` agent type.
3. **Task-Runner is decided by the task-gopher check, not by a question:**
   - **task-gopher installed** → do NOT ask about Task-Runner. Auto-assign
     `{ "model": "haiku", "delegate": "task-gopher" }` and tell the user:
     "Task-Runner: deferring to task-gopher (already installed)." An existing
     explicit Task-Runner value in the config being prefilled still wins —
     the user chose it once; keep it and say so.
   - **task-gopher NOT installed** → Task-Runner gets a question in call 2
     (see below) whose recommended option is installing task-gopher.
4. **AskUserQuestion call 1 — scope and flow.** Two questions in one call:
   - **Scope**: "User (all repos)" and "Project (this repo, committable)". If a
     config already exists at either scope, say so in the question header and
     mark that scope's option as the existing one.
   - **Handoff flow**: "Automatic handoffs (Recommended)" — the Orchestrator
     runs the chain itself and reports; and "Confirm each handoff" — before
     every reasoning-role dispatch (Architect, Implementor, Reviewer,
     Ultra-Advisor) the user is asked to approve, redirect, or skip it. Say in
     the description that this is switchable at ANY time afterwards — via
     `/hierarchy flow` or just by telling the Orchestrator mid-session — so
     nothing is locked in here. Prefill from an existing config's `handoffs`
     key if present.
5. **AskUserQuestion call 2 — the four reasoning roles.** One question each for
   Ultra-Advisor, Architect, Reviewer, and Implementor, all in a single call.
   That is exactly 4 questions, the hard AskUserQuestion maximum — so
   Task-Runner never rides along here; it gets its own call in step 6.
   **Maximum 4 options per question** is also a hard limit, so curate.
   **Prefill if a config exists at either scope**: use the chosen scope's
   current values as the first/recommended option for each role, or — if the
   chosen scope has no config but the other one does — prefill from that one
   instead, and tell the user which scope you pulled the values from. A role
   missing from the prefill source — an older config written before that role
   existed, which is every config predating Ultra-Advisor — uses its shipped
   default below as the recommended option, not whatever the file happens to
   contain. With no config anywhere, use these defaults (recommended first):
   - **Ultra-Advisor** — `fable` (recommended), `opus`. Only two options exist;
     do not offer `sonnet` or `inherit`. Say what the role is for: the
     escalation apex, dispatched only for the hardest or highest-stakes calls,
     so it is rarely used and its per-call cost matters less than its judgment.
   - **Architect** — `opus` (recommended), `sonnet`, `fable`, `inherit`
   - **Reviewer** — `sonnet` (recommended), `opus`, `fable`, `inherit`
   - **Implementor** — `inherit` (recommended — runs on the session model),
     `sonnet`, `opus`, `fable`
6. **AskUserQuestion call 3 — Task-Runner. Only when task-gopher is NOT
   installed** (when it is installed, step 3 already settled this and you ask
   nothing). One question, options: `Install task-gopher (recommended)`,
   `haiku`, `sonnet`, `opus`. If they pick the install option: write
   `{ "model": "haiku", "delegate": "task-gopher" }` and tell them to run
   `/plugin install task-gopher@claudetools` themselves (you cannot run
   `/plugin`). Until it is installed, the directive's fallback rule routes
   Task-Runner work to the bundled `agent-hierarchy:task-runner`, so nothing
   breaks in the meantime.

   For every question in steps 5 and 6: any other model (including full model
   IDs, which only work in agent frontmatter, not here) goes through
   AskUserQuestion's automatic "Other" free-text — validate anything typed
   there against **that role's** valid values (no `haiku` for reasoning roles;
   only `fable` or `opus` for `ultra-advisor`) and re-ask rather than writing
   something invalid.
7. **Write nothing until the wizard completes.** If the user aborts, cancels, or
   the role calls do not come back with an answer for every asked role, write
   no file and say the config was left unchanged.
8. On completion, write the JSON with the Write tool to the chosen scope's path
   (`mkdir -p` the `.claude` directory first if needed). Set `"version": 1`,
   `"enabled": true`, and `"handoffs"` to the flow answer from call 1 ("auto"
   or "confirm" — write it explicitly even for auto, so the file documents the
   choice). The Task-Runner entry comes from step 3 or step 6 (auto-assigned or
   answered); only the task-gopher deferral carries `delegate` — a plain model
   pick omits it.
9. **Echo the resolved effective table**, not what you just wrote — run the
   resolver command above and show its output. If it reports that a project
   config shadows user-scope values you just set, call that out explicitly:
   the values you wrote are not the ones in force.
10. Close with the propagation note: the assignments apply to **this** session
    immediately, and other live sessions pick them up at their next start,
    clear, or compaction.

---

## `status`

Run the resolver command above and show its output verbatim: whether the plugin
is configured/on/off, which file each scope resolved to, the effective model for
each role, which scope each value came from, any shadowing or validation
warning, and the propagation note. Do not recompute the table yourself.

---

## `set <role> <model>`

1. Validate `<role>` is one of `ultra-advisor`, `architect`, `reviewer`,
   `implementor`, `task-runner` and `<model>` is valid **for that role**
   (`architect`/`reviewer`/`implementor`: `opus`, `sonnet`, `fable`, `inherit`;
   `task-runner` also allows `haiku`; `ultra-advisor`: `fable` or `opus` only).
   If not, say what is valid for that role and stop — write nothing.
2. Edit **the most specific config that already exists**: the project config if
   `<cwd>/.claude/agent-hierarchy.json` exists, otherwise the user config. If
   neither exists, tell the user to run `/hierarchy init` first and stop.
3. Read that file, replace that role's object entirely (shallow replacement —
   this drops `delegate` unless you are setting task-runner back to task-gopher),
   and write it back with the Write tool, preserving every other key.
4. Echo the resolved table (resolver command) and the propagation note.

---

## `on` / `off`

Set `"enabled": true` / `false` in the most specific config that already exists
(project if present, else user), preserving all other keys. If neither exists,
say so and suggest `/hierarchy init`. Then echo the resolved table and the
propagation note.

Note when turning it **off**: the SessionStart hook goes fully silent — no
protocol directive and no setup nudge — from the next session start onward, and
for the rest of *this* session you should stop routing work through the role
chain and handle it yourself.

---

## `flow [auto|confirm]`

Who advances the chain. `auto` — the Orchestrator performs handoffs itself and
reports (the default). `confirm` — before each reasoning-role dispatch
(Architect, Implementor, Reviewer, Ultra-Advisor, including review-loop
re-dispatches) the user is asked to approve, redirect, or skip. Legwork
dispatches (Task-Runner / task-gopher) are never gated — errands are not
handoffs.

- **No argument**: run the resolver command above and report the `handoff flow`
  line, plus one sentence on what each mode means.
- **With `auto` or `confirm`**: set `"handoffs": "<value>"` in the most
  specific config that already exists (project if present, else user),
  preserving every other key, with the Write tool. If neither config exists,
  say so and suggest `/hierarchy init`. Then echo the resolved table and the
  propagation note — and **honor the new mode immediately in this session**;
  the config write is for future sessions, not a restart requirement.
- Anything else as the argument: show the two valid values and stop.

This switch belongs entirely to the user, at any time, in both directions. If
they ask for it mid-conversation in plain words ("ask me before each handoff",
"stop asking, just run it"), do exactly what this section says without making
them invoke the command.

---

## `usage [day|week|month|all]`

Run the reporter and show its output verbatim in a code block — do not
recompute, reformat, or editorialize the numbers:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/usage-report.mjs" <the day/week/month/all argument, if any>
```

The report covers: the latest session's per-role breakdown (agents, calls,
output/input/cache tokens), a windowed by-role bar chart, and daily totals.
Data comes from `~/.claude/agent-hierarchy.usage.jsonl`, written by a
`SubagentStop` hook that sums each finished subagent's transcript — token
counts the harness already logged, so collection costs zero tokens and no
agent is ever asked to report its own numbers.

Two things to tell the user when relevant:

- **Zero-token viewing**: running the same command themselves — with the `!`
  prefix, or in any terminal — keeps the report out of this conversation
  entirely. Through this command, the only token cost is the printed report
  entering context.
- If the report says **"No usage recorded yet"**, the collector has not fired:
  either the plugin was just enabled (hooks load at session start) or no
  subagents have finished since. If records show `transcripts not found`, the
  collector's path derivation broke — that is a bug report, not user error.

---

## anything else

Show the usage line:
`/hierarchy [init|status|set <role> <model>|on|off|flow [auto|confirm]|usage [day|week|month|all]]`,
then run `status`.
