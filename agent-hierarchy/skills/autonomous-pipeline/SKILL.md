---
name: autonomous-pipeline
description: Run a plan/spec/AC list to completion with an autonomous multi-round agent pipeline, minimal check-ins, and a hard 3-round escalation cap. Use for /pipeline, "run this plan autonomously", "work through these ACs until done", "set the team going on this spec".
---

# autonomous-pipeline

Drives a plan, spec, or AC list to completion via multi-round
Architect→Implementor→Reviewer pipelining, with minimal check-ins and a hard
per-item escalation cap. Invoked as `/pipeline <plan-or-spec-path> [--branch
<name>]` or by a plain-language equivalent.

This is an **opt-in mode for the duration of one run** — it does not change
how an ordinary Orchestrator session behaves. Everything below applies only
while a `/pipeline` run is active.

Full spec: `docs/specs/0030-autonomous-pipeline-skill.md`. This document is
the operational surface; if the two disagree, the spec is authoritative and
this file has drifted — say so rather than silently picking one.

**What this skill is not:** a new mechanism. Liveness, report-back, the
conduit gate, and roster lifecycle are all shipped hooks and existing
skills. This document is pipeline *discipline* on top of them — routing
rules, a round cap, a completion gate, and a push regime. Nothing here
duplicates what already exists; where it doesn't, it links.

## Liveness — nothing new here

Every peer dispatch you make during a run carries `--eta` scaled honestly
to the task, via `mcp__ah__msg_new`. The Orchestrator's
standing check-in contract in `agents/orchestrator.md` governs everything
from there — thresholds, nudge counts, when to tell the user. This skill
adds nothing to it and does not restate it.

Always try `mcp__ah__*` first — it is the preferred path. Only if it is absent from your toolset or a call to it fails as not-connected, fall back to the CLI equivalents listed in `agent-hierarchy/docs/mcp-tools.md` rather than guessing the arguments, and say so ONCE: apply the notice per your role — if you are the top-level session, tell the user; if you were dispatched, add one line to your report.

**One gap the standing contract leaves open, and this skill closes it:**
after the liveness Stop hook's nudge budget (`MAX_NUDGES`, 2 per
`request_id`) is exhausted on a dispatch, that dispatch permanently stops
blocking the Orchestrator's Stop — by design, so an interactive session
never wedges. In an autonomous run that means a stalled peer can go quiet
with work unfinished and nothing further mentions it.

**Rule:** exhausting the nudge budget on a dispatch is a **terminal
condition for that work item** — route it to the run-start-notification's
exception list (below), not back into the queue. Do not add a third nudge;
the bound is deliberate.

`ScheduleWakeup` is used only the way `agents/orchestrator.md` already
allows — conditionally, when available. Never `CronCreate` as a substitute;
a cron entry outlives the session and fires without this run's context.

**Coverage is peer-route only.** The liveness mechanism keys on a
dispatch record that only a `SendMessage` (peer route) produces — a
subagent dispatch never creates one, so it is invisible to it, by
construction, not as a degradation. Resolve the active dispatch route at
bootstrap (below) and say so in the run-start notification:

- **`peers`** — liveness coverage applies in full.
- **`subagents`** — no liveness coverage; a stall surfaces only as the
  dispatching `Agent` call's own completion or failure.
- **`prefer-peers`** — coverage is per-dispatch, whichever way each one
  resolved. Do not describe a mixed team as uniformly covered.

## Bootstrap

Seven steps, in order:

1. **auto-mode is `bypassPermissions`, knowingly.** A fully hands-off run
   requires it; do not substitute `acceptEdits` or defer to per-member
   config. `bypassPermissions` can leave a headless peer stuck at a startup
   confirmation screen — state this as a fact in the run-start notification
   (below), not as a prompt, so a team that fails to come up already has a
   visible explanation. **Practical consequence:** if a member does not
   check in after spawn, a startup-confirmation hang is the first
   hypothesis to check, not the last.
2. **Resolve the roster** (`mcp__ah__roster_show`).
3. **Resolve the active dispatch route** (`msg.mjs route` / the session's
   recorded answer: `peers`, `subagents`, or `prefer-peers`) — never assume
   one. It determines liveness coverage (§ Liveness) and is one of the four
   facts the run-start notification carries.
4. **Create the team** — `roster_create` plan → confirm → commit exactly as
   [`skills/agent-roster/SKILL.md` § Create](../agent-roster/SKILL.md#create)
   describes — do not re-derive that contract here.
5. **Run the push pre-flight checks** — both guards, before any work starts
   (§ Push regime). Their result (clean vs. degraded) is also one of the
   four run-start-notification facts. Finding out at the first push is
   finding out too late.
6. **Write the run anchor** (§ Push regime's "run anchor" subsection) — the
   durable branch record. This step is what makes the per-push
   re-derivation possible; without it, the re-derive rule has nothing to
   re-derive from.
7. **Send the one run-start notification** (§ Notification).

### Elastic membership

`mcp__ah__roster_spawn_one` adds one role to a live team without touching
the rest — that's the whole growth primitive, already shipped. Two hard
constraints on the other direction:

- **Never dismiss or close a member mid-task.** In-flight work that has
  already spent tokens is not abandoned without asking — same standing rule
  as everywhere else in this hierarchy.
- **Grow only when there is queued work no live member can take.** Don't
  pre-spawn ahead of demand.

### "Keep everyone busy" is a prohibition, not a mandate

Assign only work that already exists in the plan or the rework queue.
**Idle is the correct state** when the queue is empty, when remaining items
are blocked on a dependency, or when the only available work would preempt
something in progress. Never invent work to satisfy utilization — that
inverts the goal.

## Routing

| Trigger | Goes to |
|---|---|
| design or a decision about *how* | Architect |
| a call that is properly the user's | Ultra-Advisor (§ UA escalation) |
| work that is specified and ready to build | Implementor |
| Implementor reports done | Reviewer — **and** the next queued item to Implementor |
| Reviewer finding, `impl-defect` | rework queue → Implementor when free |
| Reviewer finding, `spec-defect` | Architect |

The `impl-defect`/`spec-defect` split is the Reviewer's existing contract
(`agents/reviewer.md`) — route on it, don't reinterpret it.

### The pipelining rule

When the Implementor finishes item N, the Reviewer gets N **and** the
Implementor gets N+1 in the same move — the Implementor does not idle
through review. That overlap is the entire point of this skill.

**Rework never preempts.** A finding on item N joins the rework queue and
is applied when the Implementor next comes free — never by interrupting a
half-built N+1. Interrupting produces a half-built item and a rework that
lands on a moving base.

**Route-dependence is a real limit, not a detail.** Under `subagents`, a
dispatched role is an in-process agent with no identity between dispatches
— there is no live peer sitting there to hand N+1 to the moment N finishes.
Under `peers`, there is. Pipeline within whatever the resolved route (see
Bootstrap) actually allows; do not assume a peer is available under
`subagents`.

## Ultra-Advisor escalation — three hops, no direct channel

There is no UA-to-user channel. The conduit gate
(`hooks/pretooluse-conduit-gate.mjs`) denies `AskUserQuestion`,
`ExitPlanMode`, `SendUserFile`, and `PushNotification` to every
non-Orchestrator role, Ultra-Advisor included. The path is:

**UA writes the question into its response file's `open_questions` →
Orchestrator reads the response → Orchestrator pages the user.**

Do not dispatch Ultra-Advisor expecting it to reach the user directly, and
do not describe the escalation any other way in status or notifications.

## The 3-round cap — per item, counted by slug

**A round is one Implementor→Reviewer cycle on a single work item that ends
in rework.** At 3 rounds on an item, **stop that item and notify the
user** — do not start a 4th. This is per work item, never a global counter
(a global counter would halt an entire long plan on its third rework
anywhere).

**Round count for an item = the number of message exchanges whose `slug`
equals that item's slug**, via `mcp__ah__msg_list` / `msg.mjs list`
**with `--all`** — not the default listing. Two requirements make this
work:

1. **Slugs must be deterministic and item-scoped.** Derive each item's slug
   the same way every time (e.g. from its AC number or step id) so it
   identifies exactly that one item for the whole run. The slug format is
   `^[a-z0-9-]{1,32}$` — fit your scheme inside 32 characters.
2. **Always count with `--all`. This is not an optimisation — the default
   is wrong.**
   - **Primary reason: the default listing is `open`-only, and a completed
     rework round is closed** (it has a response). A default-filter count
     for a slug therefore returns only whatever round is currently
     in-flight for it — near-zero at all times, on a run of any length,
     not just a long one. Left uncorrected, the cap would essentially
     never fire.
   - **Secondary reason: `msg.mjs sweep` archives closed exchanges** after
     7 days, which would additionally drop them from any listing, `--all`
     included, once archived — a longer-run-only compounding of the same
     problem.

   Both push the count downward, which is the direction that matters: an
   undercount is what lets a 4th round through a hard ceiling.

**This is a different counter from `MAX_NUDGES`.** `MAX_NUDGES` is 2, per
`request_id`, for liveness nudging (§ Liveness). This cap is 3, per work
item, for rework rounds. Do not conflate them.

## Completion gate

Once every item is done and builds/tests are reported green, two steps in
order:

1. **Reviewer: one adversarial review of the entire completed body of
   work** — not just the last round's diff. Hand it the full change range
   explicitly; a Reviewer only reviews what it's given.
2. **Architect: sign-off on that review** — on the review and the evidence
   reported, **not** on the build/test results themselves. The Architect
   has no `Bash` and cannot assert it observed a green build; "builds/tests
   green" is established by the Implementor or task-runner and reported to
   it. Don't ask the Architect to assert something it structurally cannot
   observe.

## Push regime

Commit after each step; push after each commit; isolated branch only —
never `main`. Two guards gate every push, because a pushed branch alone is
reversible (delete it) but what a push can trigger downstream often is not.

**Guard 1 — secret scan gates every push.** Run `gitleaks` or an
equivalent, scanning `origin/<branch>..HEAD` — every commit not yet on the
remote, not just the newest — or the whole branch when the remote ref
doesn't exist yet (first push of a new branch). A finding blocks that
push. **Scan the full range, not just the latest commit:** on a
per-commit-push regime, a per-commit-only scan lets a secret introduced at
step 1 ride out onto the remote when step 2 pushes — the exact harm this
guard exists to prevent.

If no scanner is available: **degraded mode** — commit locally, do not
push, and take one end-of-run push approval from the user instead.

**Guard 2 — CI-deploy check, once at bootstrap.** Establish that the
remote's CI does not deploy from arbitrary branches. If this is unknown, or
the answer is yes: **degraded mode**, same as Guard 1. Unknown counts as
yes — an unverified "probably doesn't deploy" is exactly the assumption a
many-step autonomous run would end up testing repeatedly.

**Entering degraded mode is itself a notification event** (§ Notification)
— a run that silently stopped pushing looks identical to one pushing fine,
and the user should not discover the difference only at the end.

**Unconditional, regardless of guard state:**

- **Never force-push.**
- **Never add or modify a remote.** Push only to the existing `origin`.
- **Never push to `main` or any protected branch.**
- **Never push a red build.** Commit locally, halt, notify instead.

### The run anchor, and the halt

A remembered branch name is not trustworthy after compaction — and this is
the one decision in the whole skill where being wrong writes to a remote.
Frontmatter cannot carry the fix: `frontmatterText`'s key order is fixed
and `msg_new`'s schema has no branch parameter, so adding one is a
`lib-hier.mjs` change, out of scope here. The message **body** is
free-form, so that's where the durable record goes.

**Bootstrap step 6 writes a run anchor:** a request-type message file whose
body records the resolved branch — and the plan path — in its
`## constraints` section, on a line of the literal form `branch: <name>`.
**Leave this exchange open for the life of the run — never `SendMessage`
it, never close it.**

**Reserved slug: `pipeline-run-anchor`** (19 chars, fits
`^[a-z0-9-]{1,32}$`). No work-item slug scheme may ever produce it. If one
did, the collision would add 1 to that item's round count — which **fails
safe** (an early stop, never a 4th round through) but is a silent
off-by-one, which is exactly what reserving the name prevents.

Leaving the exchange open, never `SendMessage`d, is deliberate:

- **It cannot trip liveness.** `stop-orchestrator-liveness.mjs` skips any
  exchange with no dispatch record from this session, and a dispatch
  record is only ever written on `SendMessage` — an anchor that is never
  sent gets none, so it is invisible to the Stop hook's nudge/block logic
  and cannot block it.

**Finding it again is NOT via the injected state block.** SessionStart
re-injects only a capped, newest-first **index** of open exchanges — ids,
roles, slugs, and ages, never bodies — capped at 10, with any remainder
collapsed to `+N more: msg.mjs list`. It is not a content channel: even
when the anchor is inside the cap, the index has no `branch:` line to
read, and because the anchor is written first (bootstrap step 6) it is
permanently the *oldest* open exchange of the run — once 10 newer open
exchanges exist, the steady state of a multi-round pipeline, it falls
outside the slice entirely. Do not rely on it appearing there.

**Location procedure — exactly this, every time:**

1. `msg.mjs list --all --team <team>` **in JSON mode, not `--plain`.**
   Plain rows are `id  to  slug  age  state` and carry no path; only JSON
   rows include `request: <path>`. A plain-mode lookup returns an id the
   Orchestrator then cannot open.
2. Select rows where `slug === "pipeline-run-anchor"`.
3. **Exactly one match is required.** Read its `request` path and parse
   the `branch:` line from the `## constraints` section.

**Zero or multiple matches halt — never take the newest.** More than one
open anchor for this team means more than one pipeline run is or was live
in this repo, and nothing distinguishes which run this session belongs
to; taking the newest would silently bind this (older) run to a newer
run's branch — a wrong-branch push. Zero matches halts for the same
reason: there is nothing to trust instead.

**Before every push, two independent sources must agree:**

1. the anchor's `branch:` line, and
2. `git rev-parse --abbrev-ref HEAD`.

**If they disagree, or the anchor is missing or ambiguous: halt and
notify. Do not push. Never push from memory.** This is the **one rule in
this entire skill that fails closed** — every other gate here degrades
and continues; this one stops the run instead. Two sources agreeing is
what makes a push safe; either one missing, ambiguous, or contradicting
the other is not a case to work around with a fallback, it is the stop
condition itself.

## Notification

**Exactly one proactive notification, at run start**, once bootstrap
completes, naming all four:

1. The branch.
2. The resolved dispatch route (§ Bootstrap / § Liveness coverage).
3. Auto-mode (`bypassPermissions`) and its startup-hang caveat.
4. Whether either push guard put the run in degraded mode.

**After that, notify only on:** the 3-round cap being hit on an item; the
run being genuinely blocked; a Ultra-Advisor escalation reaching the
Orchestrator; a liveness nudge-budget exhaustion (§ Liveness); a red build
that halts the run; entering degraded push mode; a secret-scan finding;
**a push halt from the run-anchor check** (§ Push regime). Nothing else — no running commentary, no per-step progress. Suppressing
that is the point of running this way. Every notification goes through the
Orchestrator; nothing here offers a second path to the user.

## What this skill does not do

- No timer logic — no polling loop, no `sleep`, no `CronCreate`, no
  reimplementation of `--eta` thresholds.
- No new state file — rounds derive from slug counts; the branch anchor is
  a message file; team state is `team.json`; dispatch state is
  `peers.jsonl`.
- No new hook — everything this depends on shipped with spec 0028.
- No change to `msg_list`'s row shape, no new frontmatter key, and no
  change to the injected state block's cap or fields.
- No reliance on the injected state block as a content channel — see
  § Push regime's run anchor.
- No restatement of the roster create/disband contracts —
  [`skills/agent-roster/SKILL.md`](../agent-roster/SKILL.md) is the home.
- No second conduit path to the user — the Orchestrator is the only role
  that talks to the user, and the gate enforces it.
- No modification to `agents/orchestrator.md` — this is an invoked skill,
  not a standing-directive change.
