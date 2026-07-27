---
description: Assign a model to each agent-hierarchy role, or inspect/toggle the hierarchy. Usage: /hierarchy [init|status|set <role> <model>|on|off]
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
    "architect":   { "model": "opus" },
    "reviewer":    { "model": "sonnet" },
    "implementor": { "model": "inherit" },
    "task-runner": { "model": "haiku", "delegate": "task-gopher" }
  }
}
```

Resolution rules you must respect in everything below:

- Merge is **shallow per role**: a role object in the project config replaces the
  user-scope role object entirely — never merge key by key.
- `enabled`: **most-specific scope wins** (project overrides user).
- Valid models: `opus`, `sonnet`, `haiku`, `fable`, `inherit`. `inherit` means
  "omit the `model` parameter on the Agent call" — it is a legal value in this
  JSON file only, and must never be passed to the Agent tool literally.
- Roles are `architect`, `reviewer`, `implementor`, `task-runner`. The
  **Orchestrator is not configurable** — it is always the session agent itself.

The resolved table is printed by the plugin's own resolver, so it can never
drift from what the hook injects. Run it with Bash from the repo you care about:

```
node "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib-config.mjs" 2>/dev/null || node "$(ls -t ~/.claude/plugins/cache/*/agent-hierarchy/*/hooks/lib-config.mjs 2>/dev/null | head -1)"
```

Pick the ONE case matching the argument:

---

## empty or `init` — the wizard

1. Tell the user the **Orchestrator is fixed**: it is this session's own agent,
   whatever model the session runs on. Only the other four roles are assignable.
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
4. **AskUserQuestion call 1 — scope.** One question, two options: "User (all
   repos)" and "Project (this repo, committable)". If a config already exists at
   either scope, say so in the question header and mark that scope's option as
   the existing one.
5. **AskUserQuestion call 2 — the remaining roles.** One question per role, all
   in a single call: three questions when task-gopher is installed, four when it
   is not. **Maximum 4 options per question** — this is a hard AskUserQuestion
   limit, so curate. **Prefill if a config exists at either scope**: use the
   chosen scope's current values as the first/recommended option for each role,
   or — if the chosen scope has no config but the other one does — prefill from
   that one instead, and tell the user which scope you pulled the values from.
   With no config anywhere, use these defaults (recommended first):
   - **Architect** — `opus` (recommended), `sonnet`, `fable`, `inherit`
   - **Reviewer** — `sonnet` (recommended), `opus`, `haiku`, `inherit`
   - **Implementor** — `inherit` (recommended — runs on the session model),
     `sonnet`, `opus`, `haiku`
   - **Task-Runner** (only when task-gopher is NOT installed) —
     `Install task-gopher (recommended)`, `haiku`, `sonnet`, `opus`.
     If they pick the install option: write
     `{ "model": "haiku", "delegate": "task-gopher" }` and tell them to run
     `/plugin install task-gopher@claudetools` themselves (you cannot run
     `/plugin`). Until it is installed, the directive's fallback rule routes
     Task-Runner work to the bundled `agent-hierarchy:task-runner`, so nothing
     breaks in the meantime.

   Any other model (including full model IDs, which only work in agent
   frontmatter, not here) goes through AskUserQuestion's automatic "Other"
   free-text — validate anything typed there against the five valid values and
   re-ask rather than writing something invalid.
6. **Write nothing until the wizard completes.** If the user aborts, cancels, or
   the role call does not come back with an answer for every asked role, write
   no file and say the config was left unchanged.
7. On completion, write the JSON with the Write tool to the chosen scope's path
   (`mkdir -p` the `.claude` directory first if needed). Set `"version": 1` and
   `"enabled": true`. The Task-Runner entry comes from step 3 (auto-assigned or
   answered); only the task-gopher deferral carries `delegate` — a plain model
   pick omits it.
8. **Echo the resolved effective table**, not what you just wrote — run the
   resolver command above and show its output. If it reports that a project
   config shadows user-scope values you just set, call that out explicitly:
   the values you wrote are not the ones in force.
9. Close with the propagation note: the assignments apply to **this** session
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

1. Validate `<role>` is one of `architect`, `reviewer`, `implementor`,
   `task-runner` and `<model>` is one of `opus`, `sonnet`, `haiku`, `fable`,
   `inherit`. If not, say what is valid and stop — write nothing.
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

## anything else

Show the usage line: `/hierarchy [init|status|set <role> <model>|on|off]`, then
run `status`.
