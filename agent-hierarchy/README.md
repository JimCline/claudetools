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
| **Reviewer** | `sonnet` | validates the diff against the spec | edit anything, or **run** anything |
| **Implementor** | `inherit` (session model) | builds exactly the spec; runs what it builds | design; fill spec gaps with its own judgment |
| **Task-Runner** | `haiku` (delegates to task-gopher when installed) | explicit-order legwork | reason or decide |

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

## Commands

```
/hierarchy init                     # wizard: scope, flow mode, model per role
/hierarchy status                   # resolved table + where each value came from
/hierarchy set <role> <model>       # one role (validated per-role)
/hierarchy flow [auto|confirm]      # who advances the chain
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
  sessionstart.mjs        injects table + protocol (main session only)
  subagentstop-usage.mjs  zero-token usage collector
  usage-report.mjs        standalone reporter
  lib-config.mjs          config resolution + directive text (run directly for status)
commands/hierarchy.md     the /hierarchy command
tests/                    3 suites, 88 cases (HOME-redirected; real config untouched)
```

## License

MIT
