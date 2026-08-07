# agent-hierarchy

Runs work through **six roles, each on a model priced for what that role
actually does** — so design happens on a strong model, review on a mid one,
legwork on Haiku, and no tier ever spends its tokens doing a cheaper tier's
job.

| Role | Default model | Does | Never does |
|---|---|---|---|
| **Orchestrator** | the session itself | decomposes, dispatches, synthesizes, polices the lanes | design or implement non-trivial changes |
| **Ultra-Advisor** | `fable` | adjudicates the hardest calls | implement; run routine steps |
| **Architect** | `opus` | design reasoning; writes the spec | implement or **execute** — no tests, builds, experiments |
| **Reviewer** | `opus` | validates the diff against the spec | edit anything, or **run** anything |
| **Implementor** | `inherit` (session model) | builds exactly the spec; runs what it builds | design; fill spec gaps with its own judgment |
| **Task-Runner** | `haiku` (delegates to task-gopher when installed) | explicit-order legwork | reason or decide |

**Visual map:** [docs/hierarchy.html](./docs/hierarchy.html) — the full flow,
lanes, and tiers on one static page
([rendered](https://htmlpreview.github.io/?https://github.com/JimCline/claudetools/blob/main/agent-hierarchy/docs/hierarchy.html)).

Run `/hierarchy init` once — user-scoped (`~/.claude/agent-hierarchy.json`) or
committed per-repo (`<repo>/.claude/agent-hierarchy.json`, project wins) — and
a `SessionStart` hook injects the resolved role→model table plus the
orchestration protocol, re-injected after compaction so it survives long
sessions. Silent inside subagents by design: role agents carry their own
contracts in `agents/*.md`, and a worker that starts orchestrating would
defeat the point.

## The flow

Trivial edits (a typo, a config value) skip the chain entirely. A
fully-specified request skips the Architect but keeps the Reviewer. Everything
else:

```
Orchestrator → Architect (spec file) → Implementor (builds it) → Reviewer
        ↑            ↑                        ↑                     |
        |            └── spec-defect ─────────┼───── impl-defect ───┘
        └── Ultra-Advisor, only when the chain can't settle it
```

The spec file is the contract: the Orchestrator dictates one absolute path,
every role works against it, and it is *living* — amended before the Reviewer
runs, so review always validates the current design. The Reviewer labels every
finding **impl-defect** (code wrong → Implementor) or **spec-defect** (spec
wrong → Architect); after two round-trips the loop escalates to the
Ultra-Advisor instead of churning.

## Lanes: reasoning roles never execute

The expensive roles read; they do not run. This is enforced three ways at
once, because prose alone has already failed once — a live Architect ran test
cycles because its old charter *licensed* "execution legwork":

- **Mechanically** — the Architect's frontmatter denies `Bash` outright. The
  Reviewer keeps `Bash` (the diff must sit in its own context to be judged —
  `git diff`/`status`/`show` are its instruments) but is contract-bound to
  read-only inspection.
- **Contractually** — when the Architect's design depends on an empirical
  result, it writes a **NEEDS-EVIDENCE** item (what to run, what each outcome
  decides) into the spec and stops. The Reviewer's "verify, don't assume"
  reads "have it RUN": every suite, build, or repro script is a mandatory
  task-gopher dispatch with a decision-free order, judged from the compact
  report.
- **By the Orchestrator** — protocol item 11 makes lane enforcement its job:
  dispatch the Architect with design questions only (never "and verify it
  works"), route NEEDS-EVIDENCE gruntwork to the Implementor at
  implementation rates, and when any role's report shows it did another
  role's work, reject that part and re-route it.

All four reasoning roles also deny the harness's generic `advisor` tool: the
hierarchy's escalation path runs through the Orchestrator to the
Ultra-Advisor, and a sideways advisor call frequently lands on the very model
the role already runs — a second opinion from yourself, at full price.

## Flow control: automatic or confirmed handoffs

Who advances the chain is the user's choice, stored as `handoffs` in the
config:

- **`auto`** (default) — the Orchestrator performs handoffs itself and
  reports.
- **`confirm`** — before every reasoning-role dispatch (including review-loop
  re-dispatches) it asks first: role, model, what's being handed off —
  **Dispatch / Do it inline / Skip**, where skipping obliges it to say what
  goes undesigned or unverified. Legwork dispatches are never gated; errands
  are not handoffs.

Switch **at any time, in either direction, in plain words** — "ask me before
handoffs", "stop asking" — or with `/hierarchy flow auto|confirm`. The
Orchestrator updates the config and honors the new mode immediately; no
restart.

## The escalation gate: the Ultra-Advisor is yours to authorize

The Ultra-Advisor is the apex of the hierarchy and its most expensive tier, and
"escalate to the best model" is exactly the judgment an Orchestrator is worst
placed to make about its own work. So it does not get to decide alone: a
PreToolUse hook **denies the first Ultra-Advisor dispatch of every session** and
hands back the question to put to you. You answer once:

- **Yes, rest of session** — escalate now and every later time, no more prompts.
- **Ask me each time** — escalate now; each later escalation prompts again.
- **No, not this session** — escalation is blocked; the Orchestrator resolves
  the question with the Architect or inline and says what that leaves
  unadjudicated.

The answer is **session-scoped only**. It lives in
`~/.claude/agent-hierarchy.gate.json`, keyed by session, never in
`agent-hierarchy.json` — a new session always asks again. A standing "yes" that
outlived the session it was given in would turn a consent gate into a one-time
formality, which is the failure this is built to avoid.

Everything else passes through untouched: the gate reads only Ultra-Advisor
dispatches, and is inert when the hierarchy is disabled. In `confirm` flow the
gate's prompt replaces the ordinary handoff confirmation for that dispatch, so
you are asked once, not twice.

Change it any time in plain words — "don't use the ultra advisor", "go ahead and
escalate whenever" — or with `/hierarchy gate [status|session|each|off|reset]`.

## Usage tracking: zero tokens to count tokens

A `SubagentStop` hook sums each finished subagent's transcript — token counts
the harness already logged — into `~/.claude/agent-hierarchy.usage.jsonl`.
Plain node against local files: no model is ever asked to count or report its
own usage.

```
SESSION 4eff7610 (latest with subagent activity)
  role           agents  calls       out        in  cache-read
  orchestrator        1    777      1.4M      1.6k      152.0M
  task-runner        30    428     72.8k      3.7k        4.7M
  other               3     28      8.4k       352      645.5k

LAST 7 DAYS — output tokens by role
  orchestrator  ████████████████████████ 1.4M
  task-runner   █                        72.8k
```

`/hierarchy usage [day|week|month|all]` renders it (the only token cost is the
printed report entering context), or run it for free in any terminal:

```
node <repo>/agent-hierarchy/hooks/usage-report.mjs [day|week|month|all] [--json]
```

Roles are attributed at report time from each record's raw `agent_type`;
main-session transcripts are scanned incrementally (byte-offset cache), so
closed sessions are never re-parsed. Fresh input and cache reads are separate
columns — a cache-read token is ~10× cheaper, and folding them together would
flatter nothing. If the report says `(N transcripts not found)`, the
collector's path derivation broke: that is a bug report, not user error.

## Panes: a role you can watch and talk to

`/pane` launches a file-backed agent as a **real, top-level Claude Code
session** in its own tmux session — not a subagent. The Orchestrator delegates
to it and gets an answer back, but you can also watch it work and type into it
yourself.

```
/agent-hierarchy:pane <agent> [right|below]     open a pane running <agent>
/agent-hierarchy:pane list                      show live panes
/agent-hierarchy:pane ask <key|agent> <text…>   send work (always confirmed)
/agent-hierarchy:pane close <key|agent|all>     close
/agent-hierarchy:pane doctor                    dependency + health check
```

**`right` = side by side, `below` = stacked.** The letters `v` and `h` also
work, and they name the **divider**: `v` is a vertical divider, so the panes end
up side by side; `h` is a horizontal divider, so they stack. Prefer the words.

**Only the Orchestrator can start a conversation.** The pane has no tool and no
address for reaching it. When work is sent, a token is left in the pane's
mailbox and the pane's Stop hook turns its final assistant message into the
reply; with no token there is no reply. A turn *you* type into the pane is
therefore never relayed anywhere — that conversation is yours alone.

**Every open and every send asks you first**, regardless of `handoffs: "auto"`.
A pane is a separately-billed interactive session driven by keystrokes into your
terminal; that earns its own confirmation.

**tmux is required** (`brew install tmux`). iTerm2 is an optional presentation
layer: with it, the pane appears split off your own tab; without it, the pane
still runs and you attach with `tmux attach -t <key>`, which every command
prints.

### Permission modes

You are asked to pick one whenever `/pane` **cannot rule out** that the agent
can execute — when its toolset includes `Bash` or `Edit`, and also when its
definition is missing, unreadable, or unrestricted. The gate fails safe: it
asks unless the definition positively proves both `Bash` and `Edit` are
unavailable, and a non-prompting pane is not proof the agent cannot execute.
In practice that covers the Implementor and any non-role agent you launch. The
Architect, Reviewer, Ultra-Advisor, and Task-Runner are not asked; they run
with normal prompting.

| Mode | What it actually does |
| :-- | :-- |
| `manual` | Prompts for anything beyond reads. Will sit and wait if nobody is attached. |
| `acceptEdits` | Auto-accepts file edits and safe filesystem commands. **Does not cover general `Bash`** — the pane still stalls on a test or build run. |
| `auto` | No routine prompts, with a background safety classifier. |
| `dontAsk` | Auto-**denies** anything that would have prompted. Never stalls, but un-preapproved `Bash` silently fails. Not a fix for stalling — a different failure. |

`bypassPermissions` is refused from the command line and available only through
`panes.permissionMode` in `~/.claude/agent-hierarchy.json`: a config file is a
deliberate, persistent, reviewable act; a flag typed mid-conversation is not.

A mode passed at startup wins over settings *and* over the agent definition's
own frontmatter.

### Known differences from a subagent

A paned role may run on a **different model** than the same role would as a
subagent. It may also have a **different tool surface**. The Orchestrator cannot
detect either difference, and cannot correct it. Pass `--model` to pin the
model; there is no equivalent for the tool surface.

The model half has a specific cause: `model: inherit` on a subagent means "the
model of the main conversation", but a pane *is* a main conversation, so it runs
on your **default** model rather than whatever the Orchestrator is currently
using. The tool half is that `--agent` applies the definition's *denials* to
whatever toolset a top-level session would otherwise have, and that base set is
not a subagent's base set.

**A paned Architect has no `Grep` and no `Glob`** — measured, not inferred. Asked
to search a file, a live paned Architect reported "No Grep/Glob tool is exposed
to me directly" and had to reach the answer by dispatching a subagent and by
reading the file whole. Its `agents/architect.md` body calls those tools its
instruments, so **a paned Architect is materially weaker at research than the
same Architect as a subagent.** Prefer the subagent path for research-heavy
Architect work, and use a pane when the point is to watch and talk to it. The
pane does keep the `Agent` tool, so it can still delegate the search — that is
exactly what it did.

### Two copies of a definition

If you develop plugins from a **local-path marketplace** (a
`"source": "directory"` entry in `known_marketplaces.json`), an agent
definition can exist twice: once in the installed plugin tree and once in your
live checkout — and Claude Code may launch the pane from either. `/pane` reads
**both** copies. When they differ it computes the permission and model policy
from both and takes the **stricter** answer of each, shows you both paths, and
warns; set `panes.onDefinitionDivergence: "refuse"` to make it refuse instead.
There is deliberately no way to silently prefer one copy. When the copies are
byte-identical — the normal state — it says nothing. `/pane doctor` compares
the whole `agents/` tree per plugin and tells you when an installed copy is
stale, with the resync command.

### Optional config

```json
{ "panes": { "timeoutSeconds": 300, "pollSeconds": 2,
             "inlinePromptMaxChars": 2000, "iterm2": true,
             "allowBuiltins": false, "permissionMode": null,
             "onDefinitionDivergence": "warn",
             "size": { "x": 200, "y": 50 } } }
```

All keys are optional and the whole block may be absent; it does not change the
config schema version. `onDefinitionDivergence` is `"warn"` (default) or
`"refuse"`.

## Commands

```
/agent-hierarchy:pane …             # see "Panes" above
/hierarchy init                     # wizard: scope, flow mode, model per role
/hierarchy status                   # resolved table + where each value came from
/hierarchy set <role> <model>       # one role (validated per-role)
/hierarchy flow [auto|confirm]      # who advances the chain
/hierarchy gate [status|session|each|off|reset]   # Ultra-Advisor escalation gate (this session)
/hierarchy usage [day|week|month]   # per-role token report
/hierarchy on | off                 # toggle without losing the config
```

Model validity is per-role: `haiku` is never valid for a reasoning role, and
the Ultra-Advisor is top-tier only (`fable` or `opus` — inheriting a lesser
session model would make the tier decorative). `inherit` means "omit the
`model` parameter on the Agent call"; it is never passed literally.

## Layout

```
agents/          one contract per role (frontmatter pins model + tool denies)
hooks/
  sessionstart.mjs           injects the pane protocol, the role notice, or the directive
  pretooluse-ultra-gate.mjs  gates Ultra-Advisor escalation on the user
  subagentstop-usage.mjs     zero-token usage collector
  stop-pane-relay.mjs        pane reply relay (inert outside a pane)
  usage-report.mjs           standalone reporter
  pane.mjs                   /pane CLI (open/list/send/peek/close/doctor)
  gate.mjs                   escalation-gate CLI (set/status/reset)
  lib-config.mjs             config resolution + directive text (run directly for status)
  lib-gate.mjs               session-scoped gate state
  lib-pane.mjs               registry, mailbox, tmux, and iTerm2 primitives
commands/hierarchy.md        the /hierarchy command
commands/pane.md             the /pane command
docs/hierarchy.html          static visual map of roles, lanes, and flow
docs/pane-command.md         the /pane design spec
tests/                       6 suites, 263 cases (HOME-redirected; real config untouched)
```

## License

MIT
