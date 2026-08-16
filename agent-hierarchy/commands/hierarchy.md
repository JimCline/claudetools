---
description: Assign a model to each hierarchy role, or inspect/toggle the hierarchy.
argument-hint: "[init|status|set <role> <model>|on|off|flow [auto|confirm]|gate [status|session|each|off|reset]|usage [day|week|month|all]]"
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
    "ultra-advisor": { "model": "fable", "dispatch": "peer", "peer": "auto" },
    "architect":     { "model": "opus", "dispatch": "model" },
    "reviewer":      { "model": "opus", "dispatch": "peer", "peer": "custom-reviewer-peer" },
    "implementor":   { "model": "inherit" },
    "task-runner":   { "model": "haiku", "delegate": "task-gopher" }
  }
}
```

A config written before Ultra-Advisor existed is still valid: a missing
`ultra-advisor` key resolves to the shipped default (`fable`) with no warning,
so `version` stays `1`. Same for `dispatch`/`peer`, added later: a role with
neither key (every config written before this feature existed) resolves to
`"dispatch": "peer", "peer": "auto"` — the named-peer-session route via the
`<repo>-<role>` convention, exactly what every role already did by default
before `dispatch` existed. `dispatch: "model"` (see `architect` above) opts a
role out of peer routing entirely — always a fresh subagent, never
SendMessage to a peer even if one with a matching name is running. `peer` is
only consulted when `dispatch` is `"peer"`: `"auto"` uses the `<repo>-<role>`
convention name; any other string (see `reviewer` above) is an explicit peer
session name. `task-runner` has no `dispatch`/`peer` concept — it keeps its
own `delegate: "task-gopher"` mechanism.

A role's `peer` name does not have to be settled through this wizard: this
document's steps 6-9 below run the settling once, up front. A role that
reaches a session with `peer` still `"auto"` — never run through `init`, or
hand-added to the config — gets settled lazily instead, the first time the
Orchestrator actually needs to dispatch it: the injected protocol's PEER NAME
CONFIRMATION section walks it through the same ranking, the same
AskUserQuestion shape, and writes the same recorded value back to config.
Either path is a one-time question per role per repo, not a per-dispatch one.

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
   - **task-gopher NOT installed** → Task-Runner gets a question in call 5
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
5. **AskUserQuestion call 2 — dispatch route, one question per reasoning
   role.** Ultra-Advisor, Architect, Reviewer, Implementor, all in a single
   call — exactly 4 questions, the hard maximum. Header is the short role
   label (`Advisor` for Ultra-Advisor — its full label is over the 12-char
   header limit; `Architect`, `Reviewer`, `Implementor` fit as-is). Each
   question: "How should `<Role>` be dispatched — a named peer session, or
   always a fresh subagent?" Exactly 2 options:
   - **"Peer agent (Recommended)"** — SendMessage to a running peer session
     when one exists; falls back to a subagent when it isn't. This is the
     existing default behavior every role has had until now.
   - **"Subagent only"** — always spawn a fresh `agent-hierarchy:<role>`
     subagent; never route to a peer, even if one with a matching name is
     running.

   **Prefill** the same way as the model-tier call below: pull `dispatch`
   from the chosen scope's existing config, or the other scope's if the
   chosen one has none, and say which scope you pulled from. A config with no
   `dispatch` key at all — every config written before this feature existed —
   prefills to **"Peer agent"**: that reproduces today's behavior exactly, so
   upgrading an existing config with no changes is a no-op.
6. **Gather peer-name work.** From call 2's answers, collect the roles that
   chose "Peer agent" into a working list. If it's empty, skip straight to
   step 10 (model tier) — nothing else in steps 6–9 applies. Otherwise call
   ListAgents **once**, now, before asking anything else. Its result is
   needed both to decide whether "pick from a list" is offerable in step 7
   and to build the ranked list in step 8.
7. **AskUserQuestion call 3 — peer name source, one question per role that
   chose "Peer agent".** Up to 4 questions (there are only 4 peer-eligible
   roles, so this never exceeds the cap), one per such role. Header: same
   short role label as call 2. Question: "How do you want to specify
   `<Role>`'s peer session?" Options:
   - **"Use \"`<repo>`-`<role>`\" (Recommended)"** — the standard convention
     name (`<repo>` = this repo's basename, `<role>` = the role key, e.g.
     `architect`); the Orchestrator will look for a peer with exactly this
     name at dispatch time.
   - **"Pick from a list"** — choose from currently running peer sessions,
     ranked by how likely they are to be the right one. **Omit this option
     for a role's question if the ListAgents result from step 6 has fewer
     than 2 sessions total** — AskUserQuestion needs 2–4 options, and with
     fewer than 2 real candidates this choice is degenerate; that role's
     question then has exactly 2 options (convention name, type it in).
   - **"Type in the exact name"** — enter the exact session name of a peer
     you already know; it doesn't need to be running right now.
8. **Resolve "Pick from a list" answers.** For every role that picked it,
   rank the ListAgents result from step 6 for that specific role, most
   likely first:
   1. Exact match: session name equals `<repo>-<role>`.
   2. Name contains **both** the repo basename **and** a role-match token
      (`architect`→`architect`; `reviewer`→`reviewer`;
      `implementor`→`implementor`; `ultra-advisor`→`ultra-advisor` or
      `advisor`).
   3. Name contains a role-match token only.
   4. Name contains the repo basename only.
   5. Everything else.

   Within a tier, more-recently-started sessions rank higher (ListAgents
   reports "started X ago"). Take the top 4 — AskUserQuestion's hard option
   cap — and ask one question per role needing this (bundle into one call,
   ≤4 questions): header = role label; question = "Pick `<Role>`'s peer
   session"; each option's label is the peer name, description is its status
   and "started X ago". AskUserQuestion's automatic "Other" stays available
   for anything not shown in the top 4.
9. **Resolve "Type in the exact name" answers.** For every role that picked
   it, ask directly in your response text — not via AskUserQuestion, which
   isn't built for pure freeform capture — naming all such roles together in
   one message (e.g. "What's the exact peer session name for Architect? For
   Reviewer?"), and take the user's next message as the value(s), trimmed of
   whitespace. One round-trip for all of them, not one per role.
10. **AskUserQuestion call 4 — the four reasoning roles' model.** One
    question each for Ultra-Advisor, Architect, Reviewer, and Implementor,
    all in a single call — exactly 4 questions, the hard maximum. **Always
    asked for all four roles regardless of their call-2 dispatch choice**:
    the model is used both when a role's dispatch is "Subagent only" (its
    only behavior) and as the **fallback** model when dispatch is "Peer
    agent" and no peer is present at dispatch time — so it is never dead
    weight even for a peer-routed role. **Maximum 4 options per question** is
    also a hard limit, so curate. **Prefill if a config exists at either
    scope**: use the chosen scope's current values as the first/recommended
    option for each role, or — if the chosen scope has no config but the
    other one does — prefill from that one instead, and tell the user which
    scope you pulled the values from. A role missing from the prefill source
    — an older config written before that role existed, which is every
    config predating Ultra-Advisor — uses its shipped default below as the
    recommended option, not whatever the file happens to contain. With no
    config anywhere, use these defaults (recommended first):
    - **Ultra-Advisor** — `fable` (recommended), `opus`. Only two options
      exist; do not offer `sonnet` or `inherit`. Say what the role is for:
      the escalation apex, dispatched only for the hardest or highest-stakes
      calls, so it is rarely used and its per-call cost matters less than its
      judgment.
    - **Architect** — `opus` (recommended), `sonnet`, `fable`, `inherit`
    - **Reviewer** — `opus` (recommended), `sonnet`, `fable`, `inherit`
    - **Implementor** — `inherit` (recommended — runs on the session model),
      `sonnet`, `opus`, `fable`
11. **AskUserQuestion call 5 — Task-Runner. Only when task-gopher is NOT
    installed** (when it is installed, step 3 already settled this and you
    ask nothing). One question, options: `Install task-gopher (recommended)`,
    `haiku`, `sonnet`, `opus`. If they pick the install option: write
    `{ "model": "haiku", "delegate": "task-gopher" }` and tell them to run
    `/plugin install task-gopher@claudetools` themselves (you cannot run
    `/plugin`). Until it is installed, the directive's fallback rule routes
    Task-Runner work to the bundled `agent-hierarchy:task-runner`, so nothing
    breaks in the meantime.

    For every question in steps 10 and 11: any other model (including full
    model IDs, which only work in agent frontmatter, not here) goes through
    AskUserQuestion's automatic "Other" free-text — validate anything typed
    there against **that role's** valid values (no `haiku` for reasoning
    roles; only `fable` or `opus` for `ultra-advisor`) and re-ask rather than
    writing something invalid. Peer names accepted via "Other" on step 7/8's
    questions, or typed in directly per step 9, are accepted as **any
    non-empty string, trimmed** — no format validation, no liveness check
    against ListAgents.
12. **Write nothing until the wizard completes.** If the user aborts, cancels,
    or the role calls do not come back with an answer for every asked role
    (including peer-name resolution for any role that chose "Peer agent"),
    write no file and say the config was left unchanged.
13. On completion, write the JSON with the Write tool to the chosen scope's
    path (`mkdir -p` the `.claude` directory first if needed). Set
    `"version": 1`, `"enabled": true`, and `"handoffs"` to the flow answer
    from call 1 ("auto" or "confirm" — write it explicitly even for auto, so
    the file documents the choice). For each reasoning role, always write
    `"dispatch"` explicitly (`"peer"` or `"model"` — write it even when it's
    the recommended default, same reasoning as `handoffs` always being
    explicit). When dispatch is `"peer"`, also write `"peer"`: `"auto"` if
    the convention was chosen, otherwise the picked or typed name. When
    dispatch is `"model"`, omit `peer` entirely — it isn't applicable. The
    Task-Runner entry comes from step 3 or step 11 (auto-assigned or
    answered); only the task-gopher deferral carries `delegate` — a plain
    model pick omits it.
14. **Echo the resolved effective table**, not what you just wrote — run the
    resolver command above and show its output. If it reports that a project
    config shadows user-scope values you just set, call that out explicitly:
    the values you wrote are not the ones in force.
15. Close with the propagation note: the assignments apply to **this** session
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

## `gate [status|session|each|off|reset]`

The Ultra-Advisor escalation gate. It runs on the most expensive model in the
hierarchy, so a PreToolUse hook denies the first escalation of every session
until the user has answered for themselves. Their answer is **session-scoped
only** — it lives in `~/.claude/agent-hierarchy.gate.json`, not in
`agent-hierarchy.json`, and a new session always asks again. That is deliberate:
a standing "yes" that outlived the session it was given in would make the gate a
formality rather than a consent check.

Every form needs this session's gate id, which the injected protocol gives you
in item 7 ("This session's gate id is ..."). Use the `gate.mjs` path from that
same line. If item 7 carries no gate id, say so and stop — do not guess one, and
do not fall back to a different session's id.

- **No argument or `status`**: run
  `node "<gate.mjs>" status --session "<gate id>"` and report the one-line
  answer, plus one sentence on what the three choices mean.
- **With `session`, `each`, or `off`**: run
  `node "<gate.mjs>" set --session "<gate id>" --choice <value>` and echo the
  confirmation. Takes effect immediately, for this session only.
- **With `reset`**: run `node "<gate.mjs>" reset --session "<gate id>"` so the
  next escalation asks again from scratch.
- Anything else as the argument: show the valid values and stop.

Like the flow switch, this belongs to the user at any time and in both
directions. If they say it in plain words ("don't use the ultra advisor",
"stop asking me about the advisor", "go ahead and escalate whenever"), do what
this section says without making them invoke the command. Setting `off` blocks
escalation only — the rest of the chain is untouched, and `/hierarchy off`
remains the way to stand the whole hierarchy down.

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
`/hierarchy [init|status|set <role> <model>|on|off|flow [auto|confirm]|gate [status|session|each|off|reset]|usage [day|week|month|all]]`,
then run `status`.
