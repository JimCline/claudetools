# 0030 — Autonomous pipeline skill

Spec. New skill + thin slash command. **No new hook, no new timer, no new state
store.** Baseline: plugin 0.56.0, spec 0028 shipped (conduit gate, report-back,
Stop-driven liveness all present in `hooks/`).

**r4 (2026-08-31).** S1 — the anchor could not be *found* post-compaction; the
injected state block is a capped index, not content. Anchor location now
specified explicitly (§7.3.1), with a reserved slug and a multi-run ambiguity
halt the review did not ask for but the trace exposed. S2 — Bootstrap
renumbered to match the implementation (§4.2), and §10's stale "step 5"
corrected.

**r3.** F1 — re-derive-branch rule was unsatisfiable, anchored and given its
failure mode. F2 — secret-scan range named. F3 — `--all` rationale's primary
cause corrected.

**r2.** E1/E2/E3 resolved; `bypassPermissions`; UA's two-guard push regime;
slug-based round counting.

## [0] tldr
- [1] **§8 of the brief is already built** — `agents/orchestrator.md:65–76` plus
  `stop-orchestrator-liveness.mjs`. §3.
- [2] **`ScheduleWakeup` is the wrong primitive** — `/loop`-only. The Stop hook
  delivers no-idle-polling. §3.2.
- [3] **Liveness covers the PEER route only, by construction**
  (`stop-orchestrator-liveness.mjs:60–62`). §6.
- [4] **auto-mode is `bypassPermissions`**, knowingly, warning surfaced. §4.1.
- [5] **Ultra-Advisor cannot page the user.** UA → response file → Orchestrator
  → user. §5.3.
- [6] **Push: two guards, a named scan range, and a two-source branch check that
  fails closed.** §7.3.
- [7] **The run anchor is located by reserved slug via `msg.mjs list --all` in
  JSON mode — never from the injected state block**, which is a capped index
  carrying no bodies. §7.3.1.
- [8] **Round counting is by slug and MUST use `--all`** — the default listing
  is open-only, so a default count is near-zero always. §7.1.
- [9] Lives as `skills/autonomous-pipeline/SKILL.md` + `commands/pipeline.md`.
  **Not** a change to `agents/orchestrator.md`. §2.

## [1] what already exists — read before designing anything

Traced, with citations. Every one of these is shipped code, not plan.

| Mechanism | Where | What it does |
|---|---|---|
| Per-dispatch check-in contract | `agents/orchestrator.md:65–76` | `--eta`; `ScheduleWakeup` *only when available*; re-check at half threshold; after second miss tell the user; never `CronCreate` |
| `--eta` plumbing | `msg.mjs:7,148`; `mcp/server.mjs:71,448`; `lib-hier.mjs:31` | flag → frontmatter `eta:` |
| Threshold values | `stop-orchestrator-liveness.mjs:50` | `small=5min, medium=10min, large=20min` |
| Outstanding-dispatch detection | `stop-orchestrator-liveness.mjs:64–78` | dispatch records × open exchanges, age ≥ threshold. **`:68` — an exchange with no dispatch record is skipped entirely** |
| Stop blocking + bounded nudges | `stop-orchestrator-liveness.mjs:113–125` | `liveness-nudge` gate per `request_id`, capped at `MAX_NUDGES` (2), then permanently allows |
| Conduit gate | `pretooluse-conduit-gate.mjs:31,62–65` | denies user-facing tools for directly-attributed non-Orchestrator roles |
| Report-back | `subagentstop-msg-nudge.mjs`, `stop-peer-nudge.mjs` | dispatched role must return a response pointer |
| Exchange listing | `msg.mjs:157–172` | **default filter `open`** (`:158`); JSON rows carry `request`/`response` **paths** (`:170–171`); **plain rows do not** (`:178`) |
| Open/closed definition | `lib-hier.mjs:289` | `open: !e.response` — a completed round is **closed** |
| Exchange ordering | `lib-hier.mjs:288` | `a.id < b.id ? 1 : -1` — **newest first** |
| Injected state block | `lib-hier.mjs:782–787` | **`open.slice(0, 10)`**, each rendered `id to slug age` — **no paths, no bodies**; overflow becomes `+N more: msg.mjs list` |
| Frontmatter writer | `lib-hier.mjs:186` | **fixed key order**, no arbitrary keys |
| Message body skeleton | `lib-hier.mjs:176,274`; `REQUEST_KEYS` `:33` | free-form sections: `tldr, goal, context, constraints, files, acceptance, want_back` |
| CLI output mode | `msg.mjs:81–83` | `--plain` → `String(obj)`; default → `JSON.stringify(obj)` |
| Roster/team lifecycle | `roster.mjs`, `mcp__ah__roster_*`, `skills/agent-roster/SKILL.md` | create, spawn-one, dismiss, disband |

**Consequence: the skill is mostly a routing policy, not a mechanism.** What
does not exist is the pipeline discipline — the queue, the round cap, the
completion gate, the push regime.

## [2] where it lives, and what invokes it

**Decision: `skills/autonomous-pipeline/SKILL.md` + a thin `commands/pipeline.md`.
Do NOT modify `agents/orchestrator.md`.**

- **Not a standing-directive change.** Editing `agents/orchestrator.md` would
  make *every* Orchestrator session run this way. This is a mode a user opts
  into for a specific body of work. Blast radius of getting it wrong is every
  session the user ever starts.
- **Skill + command mirrors `agent-roster`** — a 9-line command pointing at a
  620-line SKILL.
- **A command, because invocation takes an argument.**

```yaml
---
description: Run a plan, spec, or AC list to completion autonomously — multi-round Architect→Implementor→Reviewer pipelining with a hard escalation cap and minimal check-ins.
argument-hint: "<plan-or-spec-path> [--branch <name>]"
---
```

```yaml
---
name: autonomous-pipeline
description: Run a plan/spec/AC list to completion with an autonomous multi-round agent pipeline, minimal check-ins, and a hard 3-round escalation cap. Use for /pipeline, "run this plan autonomously", "work through these ACs until done", "set the team going on this spec".
---
```

**SKILL.md must carry the standard drift clause** (`agent-roster/SKILL.md:12`):
the spec is authoritative; if they disagree the skill has drifted — say so
rather than silently picking one.

## [3] liveness (brief §8) — use what exists, add nothing

### 3.1 what the skill says

> Every peer dispatch carries `--eta` scaled honestly to the task. The
> Orchestrator's standing contract in `agents/orchestrator.md` governs check-in
> from there; this skill adds nothing to it.

No thresholds restated, no nudge logic re-derived.

### 3.2 `ScheduleWakeup` — not the primitive to build on

`agents/orchestrator.md:65` already qualifies it: available in `/loop` dynamic
mode, absent in an ordinary interactive session, with a Stop hook as the safety
net there.

**The Stop hook — not a timer — produces the brief's stated net effect.** It
fires when the Orchestrator tries to *end its turn* and blocks while dispatches
are outstanding past threshold. The Orchestrator cannot go idle with work in
flight and never polls to discover it.

**Must not require `ScheduleWakeup`, must not substitute `CronCreate`**
(prohibited at `orchestrator.md:76`).

### 3.3 the give-up gap the skill DOES need to handle

`stop-orchestrator-liveness.mjs:118–123`: after `MAX_NUDGES` (2) for a given
`request_id`, that dispatch stops blocking Stop forever. Correct interactively;
in autonomous mode **a stalled peer stops being mentioned and the pipeline can
go quiet with work unfinished.**

**Skill requirement:** nudge-budget exhaustion is terminal for that item — it
goes to §7.4's notification path, not back in the queue. Do not add a third
nudge; the escape hatch is load-bearing.

## [4] bootstrap and membership (brief §1, §2, §3)

### 4.1 auto-mode — `bypassPermissions`, knowingly

**User decision.** Fully hands-off is the requirement; this is the value that
delivers it. Do not substitute `acceptEdits`; do not defer to per-member config.

**Keep the warning.** `roster.mjs:1021` warns it "can leave a headless peer
stuck at a startup confirmation screen". Surface it **once at bootstrap**, as a
stated fact in the run-start notification — not a prompt.

**Practical consequence:** if a member does not check in after spawn, the
startup-confirmation hang is the **first** hypothesis, not the last.

Valid values (`lib-roster.mjs:68`): `acceptEdits`, `auto`, `bypassPermissions`,
`manual`, `dontAsk`, `plan`.

### 4.2 bootstrap — seven steps, in order

*(r4 — S2: renumbered to match the implementation.)*

1. **Set auto-mode** — `bypassPermissions` (§4.1).
2. **Resolve the roster** (`mcp__ah__roster_show`).
3. **Resolve the active route** (§6) — determines liveness coverage.
4. **Create the team** — `roster_create` plan → confirm → commit per
   `skills/agent-roster/SKILL.md` § Create. **Link that section; do not restate
   the create contract** (0029 §3's rule).
5. **Run the §7.3 pre-push checks** — both guards, before any work starts.
   Discovering at the first push is discovering too late.
6. **Write the run anchor** (§7.3.1) — the durable branch record. **Without
   this step the per-push check in §7.3 is unsatisfiable.**
7. **Run-start notification** (§7.4).

**Step 7 is required.** If the shipped bootstrap has only six steps, the
run-start notification is missing — that is a defect to report, not a
renumbering artifact. §7.4 requires exactly one proactive notification, and it
is what makes an otherwise-silent run observable.

### 4.3 elastic membership

`mcp__ah__roster_spawn_one` adds one role to a live team without touching the
rest. That is the growth primitive; it exists.

1. **Never dismiss or close a member that is mid-task.** The user's standing
   rule is that in-flight work which has already spent tokens is not abandoned
   without asking. A pipeline optimising for throughput is exactly the process
   that would otherwise reap a "slow" agent mid-reasoning.
2. **Growth is bounded by the work.** Add a member when there is queued work no
   live member can take. Do not pre-spawn.

### 4.4 "keep every agent busy" — bounded, or it becomes an anti-goal

Taken literally this manufactures work. **Stated as a prohibition:** assign only
work already in the plan or the rework queue. **Idle is the correct state** when
the queue is empty, when items are blocked on a dependency, or when the only
available work would preempt something in progress. Utilisation is a consequence
of having work, never a goal.

## [5] pipeline discipline (brief §4)

### 5.1 routing

| Trigger | Goes to |
|---|---|
| design or a decision about *how* | Architect |
| a call that is properly the user's | Ultra-Advisor (§5.3) |
| work that is specified and ready to build | Implementor |
| Implementor reports done | Reviewer — **and** the next queued item to Implementor |
| Reviewer finding, `impl-defect` | rework queue → Implementor when free |
| Reviewer finding, `spec-defect` | Architect |

The `impl-defect`/`spec-defect` split is the Reviewer's existing contract.

### 5.2 the pipelining rule, and its one constraint

When the Implementor finishes item N, the Reviewer gets N *and* the Implementor
gets N+1.

**Rework never preempts.** A finding on N queues and is applied when the
Implementor next comes free. Interrupting mid-item produces a half-built N+1 and
a rework landing on a moving base.

**Route-dependence:** under `subagents` a dispatched role has no persistent
identity between dispatches; under `peers` it is a live session that keeps
context. Works under both, but must not assume a peer is there to receive N+1.

### 5.3 Ultra-Advisor cannot page the user

`pretooluse-conduit-gate.mjs:31,62–65` denies `AskUserQuestion`, `ExitPlanMode`,
`SendUserFile`, `PushNotification` for any directly-attributed non-Orchestrator
role. Its deny text (`:33–34`) prescribes the path:

> put the question in your response message file's `open_questions` … then
> return — do not block waiting for an answer.

**UA escalation is: UA → `open_questions` → Orchestrator → user.** Three hops;
no UA-to-user channel exists and the skill must not imply one.

## [6] route interaction — the constraint that most limits this design

`stop-orchestrator-liveness.mjs:60–62`, verbatim:

> A subagent dispatch never goes through SendMessage, so it never gets a
> dispatch record either — that alone is what excludes it here (T14), no
> separate check needed.

**Under `subagents` there is no liveness coverage at all** — absent by
construction, not degraded. Not a defect: a foreground subagent cannot stall
unboundedly, since the dispatching call returns its result.

- **`peers`:** applies in full. **`subagents`:** inapplicable.
  **`prefer-peers`:** per-dispatch — **do not assume uniform coverage.**

**Skill requirement:** resolve the route at bootstrap, state it in the run-start
notification, never describe liveness as covering subagent-routed members.

## [7] caps, completion, commits, notification (brief §5, §6, §7, §9)

### 7.1 the 3-round cap — count slugs, with `--all`

**A round is one Implementor→Reviewer cycle on a single work item that ends in
rework.** Per item, never global. At 3 rounds, **stop that item and notify**.
No 4th.

`msg_list` carries no `parent`, but each rework is a **new exchange with the
same `slug`**, and `slug` is in the row shape. So:

> **round count for a work item = number of exchanges whose `slug` is that
> item's slug.**

Two requirements:

1. **Slugs deterministic and item-scoped.** Derive from the work item the same
   way every time. Regex `^[a-z0-9-]{1,32}$` (`lib-hier.mjs:34`) — 32 chars.
2. **Count with `--all`. This is not an optimisation; the default is wrong.**
   - **Primary: the default filter is `open`-only.** `msg.mjs:158`, and
     `listExchanges` defines `open: !e.response` (`lib-hier.mjs:289`). **A
     completed round has a response, so it is closed, so the default drops it.**
     A default-filter count returns only *in-flight* rounds — near-zero at all
     times, on runs of any length. The cap would essentially never fire.
   - **Secondary: `msg.mjs sweep` archives closed exchanges** (`SWEEP_DAYS = 7`).

   Both push the count **downward** — the direction that permits a 4th round
   past a hard ceiling. The primary cause bites on *every* run, including short
   ones, which is where an operator reading only the sweep rationale would judge
   `--all` unnecessary.

**Do not conflate with `MAX_NUDGES`** — 2, per `request_id`, for liveness. This
is 3, per work item, for rework.

### 7.2 completion gate

1. **Reviewer: one adversarial review of the entire completed body of work** —
   not the last round's diff. Supply the full change range explicitly.
2. **Architect: sign-off on that review.**

**Precision the brief's wording needs:** the Architect cannot run anything — no
Bash, by contract. It signs off on *the review and the evidence reported*;
"builds/tests green" is established by the Implementor or task-runner. An
Architect asserting green builds would be asserting something it cannot observe.

### 7.3 commits and push — two guards, an anchor, and a halt

Commit after each step; push after each commit; **isolated branch only**. User
confirmed against both alternatives.

**Ultra-Advisor's ruling and reasoning, recorded rather than paraphrased:** a
pushed branch is deletable and inert. The irreversible parts are **secrets
scraped the moment they land on a remote** and **CI/deploy triggers firing
repeatedly** across a many-step run. Isolation addresses neither.

**Guard 1 — secret scan gates every push.** `gitleaks` or equivalent; a finding
blocks that push.

> **Scan range:** `origin/<branch>..HEAD` — every commit not yet on the remote,
> not just the newest. When the remote ref does not exist yet, scan the **whole
> branch**. A per-commit-only scan on a per-commit-push regime lets a secret
> introduced at step 1 reach the remote when step 2 pushes.

*Scanner unavailable* → **degraded mode**: commit locally, do not push, take one
end-of-run push approval.

**Guard 2 — CI-deploy check, once at bootstrap.** Establish the remote's CI does
not deploy from arbitrary branches. *Unknown or yes* → **degraded mode**.
Unknown counts as yes.

**Degraded mode is user-visible** (§7.4). A run that silently stops pushing looks
identical to one pushing fine.

**Unconditional:** never force-push · never add or modify a remote (push only to
existing `origin`) · never `main` or a protected branch · never push a red build.

#### 7.3.1 the run anchor — writing it, and finding it again

**Writing (bootstrap step 6).** A request file whose body records, in its
`## constraints` section, a line of the literal form `branch: <name>`, plus the
plan path. Reserved slug **`pipeline-run-anchor`** (19 chars, fits
`^[a-z0-9-]{1,32}$`). Leave the exchange **open** for the life of the run.

**The slug is reserved.** No work-item slug scheme may ever produce it. If one
did, the anchor would add 1 to that item's round count — which **fails safe**
(an early stop, never a 4th round through) but is a silent off-by-one, so it is
prohibited by name rather than left to chance.

**Frontmatter cannot carry the branch** — `frontmatterText` (`lib-hier.mjs:186`)
emits a fixed key order and `createMessage` builds from a closed set;
`msg_new`'s schema has no branch parameter. The body is free-form; that is why
the value lives there.

**Finding it again (r4 — S1).** r3 claimed the anchor would come back via
SessionStart's re-injected state. **It will not, for two independent reasons,
and the correct property is narrower than r3 stated:**

> **SessionStart re-injects a capped, newest-first INDEX of open exchanges —
> ids, roles, slugs and ages only (`lib-hier.mjs:784`), never bodies — capped at
> 10 (`open.slice(0, 10)`), with any remainder collapsed to `+N more:
> msg.mjs list`. It is not a content channel and is not guaranteed to contain
> the anchor.**

1. **The cap evicts it.** `listExchanges` sorts newest-id-first
   (`lib-hier.mjs:288`), and the anchor is written at bootstrap — so it is
   permanently the **oldest** open exchange of the run. Once 10 newer open
   exchanges exist, which is the steady state of a multi-round pipeline with
   concurrent dispatches, the anchor is outside the slice.
2. **Even inside the cap it carries no branch.** The block emits `id to slug
   age`. The `branch:` line is in the body, which the block never renders. So
   the state block could at best confirm the anchor *exists* — never supply its
   value.

**Location procedure, and it must be exactly this:**

1. `msg.mjs list --all --team <team>` **in JSON mode — not `--plain`.** Plain
   rows are `id  to  slug  age  state` (`msg.mjs:178`) and **carry no path**;
   only the JSON rows include `request: <path>` (`msg.mjs:170`). A plain-mode
   lookup returns an id the Orchestrator then cannot open.
2. Select rows where `slug === "pipeline-run-anchor"`.
3. **Exactly one match is required.** Read its `request` path and parse the
   `branch:` line from the `## constraints` section.

**Ambiguity halts.** More than one open anchor for this team means more than one
pipeline run is or was live in this repo, and nothing in the file distinguishes
which run this session belongs to. **Halt and notify — do not take the newest.**
Taking the newest would silently bind an older run to a newer run's branch,
which is precisely a wrong-branch push. Zero matches halts for the same reason.

*(This case was not in the review finding; it surfaced from
`lib-hier.mjs:288`'s ordering while confirming the cap. Recorded because
"newest wins" is the obvious reflex and is wrong here.)*

**Before every push, two sources must agree:**

1. the anchor's `branch:` line, and
2. `git rev-parse --abbrev-ref HEAD`.

**If they disagree, or the anchor is missing or ambiguous: HALT and notify. Do
not push. Never push from memory.** Two independent sources agreeing is what
makes the push safe; one missing is not a degraded case to work around, it is
the stop condition. **This is the only rule in the spec that fails closed** —
the opposite direction from every gate in §1, deliberately, because it is the
only one whose violation writes to a remote.

### 7.4 notification

**One proactive notification, at run start**, naming: the branch, the resolved
route (§6), the auto-mode and its startup-hang caveat (§4.1), and whether either
guard put the run in degraded mode.

Per the Ultra-Advisor's reasoning: it converts "nobody is looking until it
finishes" into "the user can watch the remote whenever they like".

**After that, notify only on:** the 3-round cap hit; genuinely blocked; a UA
escalation; liveness nudge-budget exhaustion (§3.3); a red build that stops the
run; entering degraded push mode; a secret-scan finding; **a push halt from the
anchor check (§7.3.1)**. **Not** a running commentary, not per-step progress.

All of it through the Orchestrator, the only role that can reach the user (§5.3).

## [8] what the skill must NOT contain

- **No timer logic.** No polling loop, no sleep, no `CronCreate`, no
  reimplementation of eta thresholds.
- **No new state file.** Rounds derive from slug counts; the branch anchor is a
  message file; team state is `team.json`; dispatch state is `peers.jsonl`.
- **No new hook.** 0028 shipped what this depends on.
- **No change to `msg_list`'s row shape, no new frontmatter key, no change to
  the state block's cap or fields.** All recorded as possible separate
  enhancements, out of scope here.
- **No reliance on the injected state block as a content channel.** §7.3.1.
- **No restatement of the roster create/disband contracts.** Link the SKILL.
- **No second conduit path.** §5.3.
- **No modification of `agents/orchestrator.md`.** §2.

## [9] evidence — all resolved

**E1 — auto-mode.** User decision: `bypassPermissions`, knowingly. §4.1.
**E2 — round depth.** Negative: no `parent` in the row shape; counting by `slug`
gives the same answer from the existing shape. §7.1.
**E3 — autonomous push.** User decision plus UA ruling. §7.3.

## [10] acceptance

- `skills/autonomous-pipeline/SKILL.md` and `commands/pipeline.md` exist with
  the §2 frontmatter; SKILL.md carries the drift clause.
- `agents/orchestrator.md` is **unmodified**.
- No new file under `hooks/` or `mcp/`; no existing hook modified; `msg_list`'s
  row shape, the frontmatter key set, and the state block are unchanged.
- Liveness content is a pointer to `agents/orchestrator.md` plus §3.3's give-up
  rule.
- The skill states liveness covers peer-routed dispatches only (§6).
- UA escalation is written as UA → `open_questions` → Orchestrator → user.
- auto-mode is `bypassPermissions`, caveat in the run-start notification.
- Round counting is by slug, uses `--all`, and gives the open-only default as
  the **primary** reason. Distinguished from `MAX_NUDGES`.
- Completion gate: Architect signs off on the review, does not assert build
  results.
- **Bootstrap has seven steps in §4.2's order; the anchor is step 6 and the
  run-start notification is step 7.** *(r4 — was "step 5", stale after S2.)*
- **The anchor uses the reserved slug `pipeline-run-anchor`, and no work-item
  slug can produce it.**
- **Anchor location is by `msg.mjs list --all --team <team>` in JSON mode, never
  from the injected state block; zero or multiple matches halt.**
- **Every push is preceded by the two-source agreement check; disagreement,
  missing, or ambiguous anchor halts and notifies.**
- Secret scan range is `origin/<branch>..HEAD`, or the whole branch on first push.
- Both guards, both degraded modes, all four unconditional constraints present.
- Exactly one proactive notification (run start) with the four facts in §7.4.
- Roster create/disband contracts linked, not restated.

## [11] confidence

**High** on §1, §3, §5.3, §6, §7.1, and §7.3.1 — all traced to shipped code,
including the five facts r4 turns on: `lib-hier.mjs:784`'s 10-item cap and
field set, `:288`'s newest-first ordering, `:289`'s open/closed definition,
`msg.mjs:178` vs `:170`'s plain-vs-JSON path difference, and `:158`'s open-only
default.

**On the three successive failures of the same fix.** r2's remedy died on a
fixed frontmatter schema; r3's on a 10-item cap and a body-free index. Both were
one grep away, and the Reviewer's framing of the lesson is better than my r3
wording, so it is adopted here rather than paraphrased:

> The check for a fix is not "does the mechanism exist" but **"what exactly is
> in the string it emits, and is the value I need actually in it."**

r3 asserted a *true* property — SessionStart re-injects open exchanges — and
built on it without reading what the injection contains. A true statement about
a mechanism is not a statement about its payload. §7.3.1 now states the property
at the resolution the design needs: capped, newest-first, ids and slugs only.

The same check produced §7.3.1's multi-run ambiguity halt, which no review
raised: reading `:288`'s sort to confirm the eviction argument also showed that
"newest anchor wins" would silently bind an older run to a newer run's branch.

**High** on §7.3's push regime — the UA's ruling. My original bound was wrong in
an instructive way: I reasoned about *where* work lands, the UA about *what
cannot be undone once it lands*.

**No escalation.** Ready for the Implementor.
