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
  re-dispatches) it asks first: role, model, what's being handed off. When
  that role has a peer target configured (see below) and it's listed, the
  options are **Task peer / Dispatch subagent / Do it inline / Skip**;
  otherwise it's **Dispatch / Do it inline / Skip**. Skipping obliges it to
  say what goes undesigned or unverified. Legwork dispatches are never gated;
  errands are not handoffs.

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

The gate watches both routes to the role: an `Agent`/`Task` dispatch matched
by `subagent_type`, and a `SendMessage` matched by its `to` target naming the
Ultra-Advisor's peer session — so tasking the peer instead of spawning a
subagent can't sidestep your approval. Everything else passes through
untouched: a `SendMessage` to any other peer, and the gate is inert when the
hierarchy is disabled. In `confirm` flow the gate's prompt replaces the
ordinary handoff confirmation for that dispatch, so you are asked once, not
twice.

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

## Durable agents (retired)

Durable agents were an experiment in keeping a role's Claude Code session alive
in a tmux pane between sends, so repeated work for the same role could skip the
subagent cold-start tax — full spec re-read, full briefing re-sent, zero prompt
cache — every time. The economics behind that idea held. The substrate did not:
it only ever worked on macOS with iTerm2, and driving a terminal emulator to
type into a live session proved a fragile way to solve what is really a
headless-server problem — session ids rotate, relays break on `/clear`, and
every fix bought another edge case.

The feature has been removed. herdr's headless server is the direction being
explored instead. The design specs and the incident report from the experiment
are kept for reference in `docs/retired/`.

## Handoff dispatch: peer agent vs subagent, set per role

The harness ships a native way to reach another running session —
`ListAgents` to see it, `SendMessage` to task it — which is the headless
mechanism the durable-agents experiment above was reaching for. For each of
Ultra-Advisor, Architect, Reviewer, and Implementor, `/hierarchy init` asks
for an explicit **`dispatch`** route, stored per role in the config:

- **`"peer"`** (the recommended default, and what every config written
  before this option existed already did) — check `ListAgents` for that
  role's peer session and `SendMessage` it instead of spawning a fresh
  subagent when one is listed, falling back to a subagent when it isn't —
  the same cold-start and re-briefing tax the pane experiment was trying to
  avoid, solved without a terminal in the loop. The peer's name is either the
  `<repo>-<role>` convention (e.g. `agent-hierarchy-architect`) or an
  explicit name you pick or type during `init` — stored as the role's
  `"peer"` config value.
- **`"model"`** — always spawn a fresh subagent for that role; never route to
  a peer, even if one with a matching name is running.

`/hierarchy init` offers both up front — pick from currently running peers
(ranked, most-likely-name-match first) or type a name in directly — rather
than only ever defaulting to the convention name.

Ultra-Advisor's peer route carries the same approval gate as its subagent
route (see the next section) — the `PreToolUse` hook watches `SendMessage`
calls addressed to the Ultra-Advisor's named peer, not just `Agent`/`Task`,
so routing through a peer can't skip your approval. Task-Runner has no
`dispatch` concept — it stays subagent-only, with task-gopher as its
dedicated fast path.

### The peer must report back — the brief makes it

A subagent's report is **structural**: its final text returns to whatever
dispatched it, automatically. A peer's report is **voluntary**: it exists only
if the peer chooses to SendMessage it back, and a peer that finishes the work
and goes idle without doing so strands whoever tasked it — nothing else
notices or nudges it.

Every peer brief opens with one machine-parseable line, the sentinel:

```
[hierarchy-peer-brief reply-to="sender" task="<short-slug>"]
```

`reply-to="sender"` is the norm: a delivered peer message always arrives
wrapped as `<cross-session-message from="uds:/..." from-name="...">`, and
copying that `from` into the reply's `to` is the reliable route — the sender
is often not discoverable via the peer's own `ListAgents`, so the envelope,
not the sentinel, is what the reply address actually comes from. Write an
explicit `reply-to="<name> [ref]"` only to redirect the report to a third
session. `task` is a short slug that distinguishes concurrent briefs to the
same peer and gives the reply a subject line.

The injected directive obliges every peer brief to: open with the sentinel;
carry the same self-contained brief a subagent would get, since the peer
shares none of the caller's context; end with an explicit report-back order
naming the exact report expected and stating plainly that the task is not
complete until that report is sent; and, if no reply arrives and `ListAgents`
shows the peer idle, ping it once before falling back to a subagent and
telling the user the peer stalled.

On the peer side, hooks enforce the obligation rather than relying on prose
alone: a `UserPromptSubmit` hook records an owed reply when a brief's sentinel
arrives, a `PostToolUse` hook (matching `SendMessage`) marks it resolved once
the peer sends a reply to the recorded address, and a `Stop` hook blocks the
peer's turn from ending while a reply is still owed — nudging at most twice
per obligation before waiving it, so a broken or unresolvable brief can never
trap a session. State lives in
`~/.claude/agent-hierarchy.peer-pending.jsonl`, append-only and
session-scoped like the rest of this plugin's state. Enforcement arms only on
a peer-delivered turn — a brief, a ping, or any other wrapped message — so
directly chatting with a tasked peer neither triggers a nudge nor spends one.

## Commands

```
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
  sessionstart.mjs               injects the role notice or the directive
  pretooluse-ultra-gate.mjs      gates Ultra-Advisor escalation on the user
  subagentstop-usage.mjs         zero-token usage collector
  usage-report.mjs               standalone reporter
  gate.mjs                       escalation-gate CLI (set/status/reset)
  lib-config.mjs                 config resolution + directive text (run directly for status)
  lib-gate.mjs                   session-scoped gate state
  lib-peer.mjs                   peer report-back state (sentinel/wrapper parse, JSONL)
  userpromptsubmit-peer-tracking.mjs   records a peer-brief obligation
  posttooluse-peer-resolve.mjs         resolves it on a matching SendMessage reply
  stop-peer-nudge.mjs                  nudges (blocks) until replied or waived
commands/hierarchy.md        the /hierarchy command
docs/hierarchy.html          static visual map of roles, lanes, and flow
docs/retired/                 durable-agents design specs and incident report — feature removed
tests/                        (HOME-redirected; real config untouched)
  test-peer-reportback.sh     peer report-back contract: sentinel/wrapper parse, tracking, resolve, nudge/waive
```

## License

MIT
