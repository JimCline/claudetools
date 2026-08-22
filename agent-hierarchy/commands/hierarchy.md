---
description: Enable/disable the hierarchy and its handoff flow, or inspect it. Model/roster assignment lives in /agent-roster.
argument-hint: "[init|status|on|off|flow [auto|confirm]|gate [status|session|each|off|reset]|usage [day|week|month|all]|msgs [open|closed|all|off|required]|peers|sweep [days]]"
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

## empty or `init` — enable + handoff flow

This wizard only turns the hierarchy on and sets its handoff flow. Model and
roster assignment (which roles exist, their model/effort/route) lives in
**`/agent-roster init`** — see the handoff in step 6 below.

1. Tell the user the **Orchestrator is fixed**: it is this session's own agent,
   whatever model the session runs on.
2. Check for existing config: read `~/.claude/agent-hierarchy.json` and
   `<cwd>/.claude/agent-hierarchy.json` (either may be absent). Also check
   whether task-gopher is installed — `ls -d ~/.claude/plugins/cache/*/task-gopher 2>/dev/null` or the presence of a `task-gopher:task-gopher` agent type.
3. **Task-Runner is decided by the task-gopher check, not by a question:**
   - **task-gopher installed** → do NOT ask about Task-Runner. Auto-assign
     `roles.task-runner`: `{ "model": "haiku", "delegate": "task-gopher" }`
     and tell the user: "Task-Runner: deferring to task-gopher (already
     installed)." An existing explicit Task-Runner value in the config being
     prefilled still wins — the user chose it once; keep it and say so.
   - **task-gopher NOT installed** → ask one question: options
     `Install task-gopher (recommended)`, `haiku`, `sonnet`, `opus`. If they
     pick the install option: write `roles.task-runner`:
     `{ "model": "haiku", "delegate": "task-gopher" }` and tell them to run
     `/plugin install task-gopher@claudetools` themselves (you cannot run
     `/plugin`). Until it is installed, the directive's fallback rule routes
     Task-Runner work to the bundled `ah:task-runner`, so
     nothing breaks in the meantime. Any other model typed via "Other" is
     accepted as-is (`haiku` is valid for this legwork-only role).
4. **AskUserQuestion call — scope and flow.** Two questions in one call:
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
5. Write the JSON with the Write tool to the chosen scope's path (`mkdir -p`
   the `.claude` directory first if needed), preserving every other existing
   key at that scope. Set `"version": 1`, `"enabled": true`, `"handoffs"` to
   the flow answer (write it explicitly even for `"auto"`, so the file
   documents the choice), and `roles.task-runner` from step 3. Echo the
   resolved effective table (resolver command above), and close with the
   propagation note: this applies to **this** session immediately, and other
   live sessions pick it up at their next start, clear, or compaction.
6. **Initial Setup trigger.** Run `resolveRoster(cwd)` (or read `.roster`/
   `.rosterLevel` off the resolver output). If it is `null` at all three
   levels (global, repo, repo-user — no roster configured anywhere), hand off
   directly into `/agent-roster init`'s flow now: its route question first,
   then its per-role walk. If a roster already resolves, just say so and
   point at `/agent-roster show` — do not re-run its wizard.

---

## `status`

Run the resolver command above and show its output verbatim: whether the plugin
is configured/on/off, which file each scope resolved to, the effective model for
each role, which scope each value came from, any shadowing or validation
warning, and the propagation note. Do not recompute the table yourself.

The resolver output also carries a **roster** section (winning level, path,
each member's name/role/model/effort/route/auto-mode) when a roster resolves,
and a **Team** section (active `team_id`, or "none active") when `team.json`
exists — both are printed as part of the same verbatim output, nothing extra
to run.

---

## `set <role> <model>` — moved

Superseded by `/agent-roster edit`, which operates on roster members instead
of the legacy `roles` table. Point the user at
`/agent-roster edit --member <name> --model <model>` (or `/agent-roster add`
if the role isn't in the roster yet).

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

## `msgs [open|closed|all]`

List message-file exchanges. Run and show verbatim in a code block:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/msg.mjs" list --plain <--open|--closed|--all per the argument; default open> --cwd "$(pwd)"
```

Each line is `id  to  slug  age  state`. The files live under the hierarchy
runtime dir (`<git root>/.claude/hierarchy/msgs/`, or
`~/.claude/hierarchy/<repo>/msgs/` outside a repo; `AGENT_HIERARCHY_DIR`
overrides both) — point the user there if they want to read one.

## `msgs off` / `msgs required`

Toggle the message-file protocol. Set the top-level `msgs` key in the config
JSON (same scope rules as `set`: edit the file that currently defines the
config, project scope if both exist) to `"off"` or `"required"`, then confirm
the new value. `"required"` is the default when the key is absent: role
dispatches must carry a `[hierarchy-msg <request path>]` pointer or a
PreToolUse gate denies them. `"off"` disables the msg gate and the response
nudge; the route and tier gates are unaffected.

## `peers`

Show the live peer roster. Run and show verbatim in a code block:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/msg.mjs" roster --plain --cwd "$(pwd)"
```

One line per known instance: `role: name  live|stale  how  age ago  [busy]
[task=...]  open=N`. Ground truth is `peers.jsonl` in the hierarchy runtime
dir, fed by peer-session SessionStart/SessionEnd hooks and by ListAgents /
SendMessage observations.

## `route` — moved

The `/hierarchy route` command surface is gone; the machinery it drove
(the per-session dispatch-route answer, and the `pretooluse-route-gate.mjs`
gate that asks once per session and enforces it silently) is unchanged and
still runs. Team-wide route now lives in the roster (`roster.route`, with an
optional per-member override) — set it via `/agent-roster init`/`edit`. This
session's own route answer can still be inspected directly:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/msg.mjs" route --session "$CLAUDE_SESSION_ID" --plain --cwd "$(pwd)"
```

## `sweep [days]`

Archive closed exchanges older than N days (default 7). Run and show the
count:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/msg.mjs" sweep --plain --days <N or omit> --cwd "$(pwd)"
```

Closed request/response pairs move to `msgs/archive/`; open exchanges are
never touched. The same sweep runs silently at session startup.

---

## anything else

Show the usage line:
`/hierarchy [init|status|on|off|flow [auto|confirm]|gate [status|session|each|off|reset]|usage [day|week|month|all]|msgs [open|closed|all|off|required]|peers|sweep [days]]`,
then run `status`.
