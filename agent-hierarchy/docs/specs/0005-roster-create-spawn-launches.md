# Spec 0005 — `/agent-roster create`: launch agents inside the script, not across LLM turns

Status: **final** (drafted 2026-08-22; refined 2026-08-22 — §9's NEEDS-EVIDENCE list resolved except
item 2, which stays open by design; see §9 and §12)
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Team, Orchestrator, Check-in registry)
Related: `docs/specs/0003-roster-create-perf.md` (introduced the layout/launch phase split and the
`N × ready_wait → max(ready_wait)` batching, driven from the orchestrating session);
`docs/specs/0004-roster-layout.md` (moved the herdr *layout* phase itself into `roster.mjs` via
`layout-splits`, amending the "roster.mjs spawns nothing" rule — see its §12 item 5 and the
2026-08-22 amendment note at the top of that file)

> **Refinement note (2026-08-22).** Resolving §9 turned up three corrections to the draft, not just
> confirmations. They are marked **[correction]** at the point of change:
> 1. §4.1 — `launch_status` cannot be `ready` for tmux. `send-keys` has no readiness handshake, so a
>    third status was added. The draft's stated justification for a two-value enum was herdr-specific.
> 2. §4 step 6 — the retry rule is now explicitly herdr-only. `pane_not_available` is a herdr
>    condition; a `send-keys` failure is a different thing and must not be retried by the same branch.
> 3. §4 step 3 — `0003` §6.2's "N distinct, non-empty target ids" assertion was absent from the draft.
>    It moves *into* the script along with the layout phase, or the move silently drops it.

## 1. Goal

`0003` collapsed N serial split→launch→wait cycles into two batched phases, but "batched" still means
the orchestrating LLM session issues N concurrent tool calls per phase and waits on the result before
its next turn. `0004` went further for the *layout* phase only: `layout-splits` (bare form) now runs
the whole sequential split loop inside one script invocation, so the orchestrator makes one tool call
instead of N.

This spec applies the same move to the *launch* phase. Extend `roster.mjs create` with a spawn mode
that, in one script invocation:

1. Resolves the roster and computes members (as `--plan` already does).
2. Runs the layout phase (reusing `0004`'s sequential split loop — unchanged).
3. Fires every peer-routed member's launch command **concurrently, from inside the script**, waits for
   all of them to settle, retries a single `pane_not_available` failure once per member (the existing
   SKILL.md 3b rule, herdr only — §4 step 6), and returns one JSON result: per-member launch outcome
   plus enough identity to build `--commit`'s `verified` array.

The orchestrating session's job shrinks to: one call to run this, one `ListAgents` call to pick up each
member's `ref`, then `--commit` — matching the user's ask: "rely on the LLM turn" only to *validate*
after the fact, not to *drive* the spawn.

## 2. Why this is possible now and wasn't ruled out already

`0003` kept the launch phase at the orchestrator level for two stated reasons (its §"What must NOT
change" item 1, and the general "`roster.mjs` performs zero spawning" rule): visibility of side effects,
and no documented need to violate it yet. `0004` already broke that rule once, deliberately and
narrowly, for `pane split`/`pane layout` — see its amendment note: *"§12 item 5 — 'roster.mjs spawns
nothing' — is scoped down, not deleted. One subcommand, `layout-splits`, may now execute `herdr pane
layout` and `herdr pane split` directly."*

This spec proposes the same kind of scoped exception for a second subcommand: launching the agent
process itself is still a side effect, but so is splitting a pane, and `0004` already accepted that
trade for a script-internal loop when the alternative is N wasted LLM turns. The boundary that
survives both amendments is: **`roster.mjs create --plan` and `--commit` stay pure file I/O; only a
named, narrow subcommand may shell out, and only for the two things that are pure orchestration
mechanics (creating a pane, starting a process in it) — never for anything that decides Team
membership or writes `team.json`.**

`0004` §12 item 5 closes with *"this boundary is a decision, not a slope. Moving it again requires its
own spec and its own decision. Do not extend it by analogy."* This document is that spec, arriving the
way that clause requires. Note what it does **not** claim: starting a process is a materially bigger
step than splitting a pane, and §2.1 below states the residual asymmetry rather than papering over it.

### 2.1 The asymmetry this spec accepts

`layout-splits` executes two verbs that are recoverable by hand in seconds (a stray pane is closed by
closing it). `create --spawn` executes a verb that starts a `claude` process which will consume tokens
until something stops it. If `--spawn` misfires — wrong count, wrong panes, a loop that runs twice —
the cost is real money, not a cosmetic layout.

Two properties keep that bounded, and both are requirements, not observations:

- **The member list is computed before any launch fires**, from the same `resolveRoster` path `--plan`
  uses. `--spawn` never discovers members as it goes, so the number of processes it can start is fixed
  and known before the first one starts. It is `members.filter(route === "peer").length`, full stop.
- **`--spawn` starts processes; it never stops one.** There is no kill path in this subcommand, and
  `0006` deliberately keeps teardown on the emit side for the same reason. `roster.mjs` may now start
  a process and may not stop one — an asymmetry that is intentional, since the failure mode of a
  buggy killer is unrecoverable and the failure mode of a buggy starter is expensive.

## 3. What does NOT change

- `create --plan` and `create --commit` are untouched — same inputs, same outputs, same "pure file I/O"
  contract. This spec adds a third mode; it does not alter the existing two. See §9 item 1 for the
  exact line ranges, which confirm the two paths are already disjoint in the source.
- The derived-name scheme, the two-phase layout algorithm (`nextSplit`), `layout-splits`'s existing
  bare/`--next`/`--apply` forms, and 0004's split policy are all reused as-is, not reimplemented.
- 0001 §13's partial-success behavior: a member whose launch never becomes ready is still just a member
  that didn't check in — commit anyway with `--partial`, name it, don't block, don't tear down. This
  spec produces the same shape of failure, just detected earlier and in one place instead of scattered
  across N Bash tool calls.
- The check-in poll (`ListAgents`, every 2s, give up at 60s) stays with the orchestrating session — see
  §5, this is not something a script can do at all, not just something this spec chooses not to move.
- `manual` mode's per-split confirmation loop (0004 §"Create manual-mode layout") is unaffected; the new
  spawn mode is an `auto`-mode-only fast path (§6).
- `disband` in every form. `--spawn` starting processes does not license this file to stop them; see
  §2.1 and `0006` §4.

## 4. New subcommand: `create --spawn`

```
roster.mjs create --spawn --mode <auto|columns|grid> --cwd <repo-root> [--roster-level <L>] [--orchestrator-pid <pid>]
```

`--spawn` is mutually exclusive with `--plan` and with `--commit`; passing more than one is exit 2 with
no side effect. Add `spawn` to `BOOL_FLAGS` (`parseArgs`, `hooks/roster.mjs:47-65`) — a boolean flag
that is not in that set swallows the following argv token, which is a live trap in this file, not a
hypothetical (0002 §5.3.2 item 1).

Internally, in one Node process:

1. Resolve the roster exactly as `--plan` does today; compute `members[]` (role, derived name, model,
   effort, route, autoMode) and each peer member's `spawn` shape (unchanged from `0004`'s
   `target_placeholder`/`target_source` contract). This is the shared-function extraction of
   `hooks/roster.mjs:481-494` — see §9 item 1.
2. Detect transport (unchanged `detectTransport()`, `:131-139`).
3. **Layout phase** — for `herdr`, call the *existing* bare `layout-splits` loop in-process (factor it
   into a function both CLI branches call, rather than duplicating it) to get `panes: string[]` in plan
   order. For `tmux`, run each member's `new-window -P -F '#{pane_id}'` sequentially. For `terminal`,
   no layout step.

   **[correction]** `0003` §6.2 attaches a mandatory assertion to this phase — *"N layout commands must
   yield N distinct, non-empty target ids … implement the assertion; do not skip it because the batch
   looked fine."* The draft of this spec omitted it. Moving the layout phase inside `--spawn` moves the
   assertion inside with it: after step 3, assert `panes.length === peerMembers.length`, every entry
   non-empty, and `new Set(panes).size === panes.length`. A failure here is exit 2 **before any launch
   fires** — this assertion is positioned where it is precisely so that a bad layout cannot become N
   `claude` processes in the wrong places.

   On tmux the sequential ordering is a *choice*, not a constraint: `0003` §6.2 states `new-window`
   batching is safe ("there is no shared target being read-modified"). It stays sequential so window
   order matches plan order deterministically, which is what step 4's positional assignment relies on.
   The gain from batching it is nil — §6.2's own point is that the launch phase is where the time is.
4. Assign each peer member its target id from step 3, in plan order (same assignment rule the skill
   currently performs by hand).
5. **Launch phase** — substitute each member's `target_placeholder`, then launch every peer member's
   `launch` command **concurrently** via `child_process.execFile` (not `execSync`), collecting each as a
   `Promise`. `Promise.allSettled` over all of them — one member's failure must not throw away another's
   result.
6. **Retry rule, moved into the script — herdr only.** If a member's launch result indicates
   `pane_not_available` / "not at a prompt" (the existing SKILL.md 3b condition), retry that one
   member's launch once, in-process, before recording it as failed. This is a straight port of the
   prose rule in `skills/agent-roster/SKILL.md` § Create step 3 3b — not a new policy.

   **[correction]** The draft wrote this transport-neutrally. It is not transport-neutral.
   `pane_not_available` is a herdr condition arising from herdr's readiness detection; tmux
   `send-keys` has no such condition — a `send-keys` failure means the target pane is *gone*, which is
   not retryable by re-sending, and `terminal` has no target at all. **The retry branch runs only when
   `transport === "herdr"`.** For tmux and terminal, a launch failure is recorded as `failed` on the
   first attempt with `retried: false`.
7. Emit one JSON object (§4.1) and exit.

### 4.1 Output shape

```json
{
  "level": "repo-user",
  "transport": "herdr",
  "members": [
    {
      "role": "architect",
      "name": "wrangl-architect",
      "model": "opus",
      "route": "peer",
      "autoMode": "auto",
      "transport_id": "w3:pQ",
      "launch_status": "ready",
      "launch_result": { "...": "raw parsed JSON from the successful `herdr agent start` call" },
      "retried": false
    },
    {
      "role": "reviewer",
      "name": "wrangl-reviewer",
      "model": "opus",
      "route": "peer",
      "autoMode": "auto",
      "transport_id": "w3:pS",
      "launch_status": "failed",
      "launch_result": null,
      "retried": true,
      "error": "herdr agent start ... failed: pane not at an interactive prompt"
    }
  ],
  "partial": true
}
```

**[correction] `launch_status` is one of `ready` | `dispatched` | `failed`.** The draft specified only
`ready | failed`, justified by *"herdr's own `agent start` already blocks until ready-or-timeout"* —
which is true, and **herdr-specific**. `tmux send-keys` returns as soon as the keystrokes are written
to the pane; it makes no claim whatsoever about whether `claude` started, or is even the process
reading that pane. Reporting a tmux member as `ready` would be asserting something the transport
cannot know.

- `ready` — herdr only. `herdr agent start` returned success, which means herdr detected the agent.
- `dispatched` — tmux only. The keystrokes were delivered to a known-good pane id with exit 0.
  Readiness is **unknown** and is established downstream by the orchestrator's `ListAgents` poll (§5),
  which every route already goes through regardless.
- `failed` — the launch command exited non-zero, or (herdr) failed again after its one retry. A herdr
  readiness timeout surfaces here, with herdr's own error text in `error`, since `agent start` reports
  timeout as a failure.

`partial` is `true` iff any peer-routed member's `launch_status` is `failed`. **`dispatched` does not
count as partial** — it is the normal, successful terminal state for tmux, and treating it as a failure
would mark every tmux Team partial. This is the one place the three-value enum changes a downstream
computation, and getting it wrong is silent: the Team would commit with `--partial` and name members
that are in fact fine.

Subagent-routed members are included with `route: "subagent"`, `transport_id: null`,
`launch_status: null` — informational only, so the orchestrator doesn't have to re-merge `--plan`
output separately to build `--commit`'s `verified` array (§5).

## 5. What still can't move into the script — and why

Two things are excluded from `--spawn` because they are not shell operations `roster.mjs` can perform
at all, not things this spec declines to move for caution:

- **`ListAgents`** — this is a Claude Code product surface, not a CLI or an MCP tool a Node subprocess
  can call; only the orchestrating Claude Code session has it. It is the only source of each member's
  `ref`, and `ref` is a required field of `--commit`'s `verified` array (0001 §"Create" step 5). The
  orchestrator must still run one `ListAgents` call after `--spawn` returns, matching each `--spawn`
  member's `name` against a `ListAgents` row. For tmux this call is not a formality — it is the only
  thing that turns `dispatched` into knowledge (§4.1).
- **`--commit`** itself stays a separate, explicit call — not folded into `--spawn` — preserving the
  existing plan→commit two-step (0003 §"What must NOT change" item 2): a `--spawn` that also committed
  would let `team.json` be written before the orchestrator has verified anything against `ListAgents`,
  which is exactly the ordering `--plan`/`--commit` exists to prevent.

So the full sequence after this spec ships is exactly three orchestrator-driven steps, down from
`1 (plan) + 1 (layout-splits) + N (launches) + 1 (ListAgents) + 1 (commit)`:

1. `roster.mjs create --spawn ...` — one call, does resolve+layout+launch+retry internally.
2. `ListAgents` — one call, unchanged, still required and still not scriptable.
3. `roster.mjs create --commit --verified <json built from steps 1+2> ...` — unchanged.

## 6. Scope: `auto` mode only

`manual` mode's whole point is a human decision point *before* each split (0004's manual-mode layout
loop) and, per `0003` §11.3, deliberately does not get a pause between layout and launch either. A
script-internal `--spawn` has no way to surface a per-split confirmation mid-run, so:

- `create auto` (the default) uses `--spawn` for the herdr/tmux layout+launch work.
- `create manual` keeps the existing orchestrator-driven step-by-step flow entirely unchanged; `--spawn`
  is not invoked in that mode. This spec adds nothing for `manual` and removes nothing from it.

## 7. Concurrency safety

The herdr argument is unchanged from `0003` §6.1 (batched `agent start` across distinct existing panes
is safe: unique derived names, unique explicit `--pane` targets, pane-scoped detection). Nothing about
*who* issues the concurrent calls (Node `Promise.allSettled` vs. one Claude Code message with N tool
calls) changes why they are safe to run at once.

### 7.1 tmux — resolved, and it holds for a different reason than herdr

The draft flagged this as unverified (§9 item 4). Re-reading `0003` §4.3 and §6.2 against the current
source resolves it: **concurrent tmux launch is safe, and the argument is simpler than herdr's.**

`hooks/roster.mjs:158-159` constructs the tmux pair as:

```js
layout: [`tmux new-window -P -F '#{pane_id}' -c "${cwd}"`],
launch: [`tmux send-keys -t <TARGET> ${JSON.stringify(claudeCmd)} Enter`],
```

`-P -F '#{pane_id}'` yields a tmux **pane id** (`%NN`) — stable for the life of the server and never
reused, unlike a window/pane *index*, which renumbers as windows come and go. So each `send-keys`
addresses a distinct, stable, private target. There is no shared mutable state between two concurrent
`send-keys` calls: no active-pane cursor is read, no id is recomputed.

This is worth stating precisely because it is **not** an instance of `0003` §6.1. §6.1's herdr argument
turns on *detection being pane-scoped* — herdr watches a buffer, and the claim is that two watchers
don't watch the same one. tmux has no detection to race at all; `send-keys` writes bytes and returns.
The tmux argument is the strictly weaker "no shared state", which is also strictly easier to satisfy.

The hazard `0003` §4.3 identified was the *absence* of `-t`, which made every launch race for whatever
pane happened to be active. That fix is already in the file at `:159`, with the reason recorded in the
comment above it. Concurrency does not reintroduce it.

**What this does not buy:** safety of *dispatch* is not evidence of *success*. See §4.1 — the price of
tmux having no detection is that tmux can never report `ready`.

### 7.2 Process supervision

- **`execFile`'s child process must not be detached.** If `roster.mjs` exits before a slow
  `herdr agent start` resolves, that launch is lost. Await every promise before the CLI process exits;
  do not fire-and-forget. §11.2's timing assertion exists to catch a regression here.
- **Per-member timeout still belongs to herdr**, not to this script — do not add a second timeout layer
  on top of `herdr agent start`'s own (0003 §10 item 1 already flagged raising herdr's own timeout as
  NEEDS-EVIDENCE; that item is unaffected by this spec and still open). A blanket `execFile` timeout
  would cut herdr off mid-detection and report `failed` for an agent that is in fact coming up.

## 8. Change list (for implementation)

| File | Change |
|---|---|
| `hooks/roster.mjs` | Add `spawn` to `BOOL_FLAGS` (`:47-65`). Add a `--spawn` branch to the `create` case (`:452-496`). Factor `:481-494` (the `--plan` resolve/compute block) into a shared function called by both the `--plan` and `--spawn` branches — see §9 item 1; `--commit` (`:454-479`) is untouched. Factor the existing bare `layout-splits` loop body into a function callable from both `layout-splits` and `create --spawn`. Add the step-3 layout assertion, the concurrent-launch logic, and the herdr-only retry (§4). |
| `skills/agent-roster/SKILL.md` | § Create: for `auto` mode, replace step 3 (layout+launch) with a single "run `roster.mjs create --spawn ...`, read its `members[]`" step. Step 4 (`ListAgents` check-in) and step 5 (`--commit`) unchanged in substance, but step 5's `verified` array is now built directly from `--spawn` output plus `ListAgents` refs rather than assembled by hand. Step 4 must state that a `dispatched` member is *expected* and not a partial — see §4.1. `manual` mode's steps are untouched (§6). |
| `tests/test-roster-create-spawn.sh` (new) | Concurrent-launch, retry, assertion, and supervision coverage. Fully designed in §11. |
| `docs/specs/0001-agent-roster.md`, `0003`, `0004` | No edits — this spec is additive; none of their described behavior for `--plan`/`--commit`/`layout-splits`/`manual` changes. `0004` §12 item 5's boundary is extended by *this* document, per its own "requires its own spec" clause; that clause is satisfied by 0005 existing, not by editing 0004. |

## 9. NEEDS-EVIDENCE — status

**1. Exact current line ranges for `create --plan`'s member/spawn computation and `--commit`. RESOLVED.**

| What | Where |
|---|---|
| `case "create":` arm | `hooks/roster.mjs:452-496` |
| `--commit` path (entire `if (opts.commit)` block) | `:454-479` — `writeTeam(dir, team)` at `:476`, `out({committed:true, team})` at `:477` |
| `--plan` path | `:481-494` |
| ↳ roster resolution | `:487` — `const resolved = resolveRoster(cwd);` |
| ↳ member computation | `:490-493` — `resolved.members.map(...)` |
| ↳ spawn shape | `:492` — `spawn: route === "peer" ? spawnShape(m, transport) : null` |
| ↳ output | `:494` — also the only call site of `layoutPlan(...)` |
| Helpers | `parseArgs` `:47-65`, `fail` `:67-70`, `out` `:72-74`, `detectTransport` `:131-139`, `spawnShape` `:141-165`, `layoutPlan` `:167-181` |
| `resolveRoster` | **not in this file** — imported from `lib-config.mjs` |

The practical answer for implementation: **"factor into a shared function" touches `:481-494` and
nothing else** — a ~14-line block. The `--commit` path at `:454-479` is already disjoint from it and
needs no edit, which is what makes §3's "untouched" claim checkable rather than aspirational.

**2. Whether `herdr agent start`'s failure text reliably distinguishes `pane_not_available` from other
failures. OPEN — NEEDS-EVIDENCE, for the Implementor to gather.**

This is an empirical question about a live tool and is deliberately not answered here. Same discipline
as `0002` §12.1's auto-mode enum: it is gathered by running the thing, not by reasoning about it.

*What to run:* against a live herdr session, invoke `herdr agent start` in each of these conditions and
capture the **full** stdout, stderr, and exit code verbatim:
  a. target pane busy / not at an interactive prompt (the condition the retry exists for);
  b. target pane id does not exist;
  c. invalid `--kind`;
  d. herdr daemon not running;
  e. readiness timeout (start an agent in a pane where nothing will ever become ready).

*What each result decides:*
- If (a) is distinguishable from (b)–(e) by a **structured field** (an error code/kind in JSON) → the
  retry branch matches on that field. Best case; specify the field name in §4 step 6.
- If (a) is distinguishable only by **substring** of an error message → the retry branch matches the
  substring, and the spec must record the exact string plus the herdr version it was observed on,
  because a message-text match is a version-coupled dependency and must be labelled as one.
- If (a) is **not** reliably distinguishable → do not guess. Fall back to: retry once on *any* failure,
  for herdr only, and record `retried: true`. This is safe because a retry of (b)/(c)/(d) fails again
  the same way and costs one extra sub-second call; it is not safe for tmux, which is why §4 step 6 is
  herdr-scoped regardless of how this resolves.

Implementation may proceed on everything else in this spec before this is answered; only §4 step 6's
match condition depends on it.

**3. How to test the concurrent-launch path without a live herdr/tmux session. RESOLVED — see §11.**

**4. Whether tmux's launch phase is safe to fire concurrently. RESOLVED — see §7.1.** It is, for a
different and simpler reason than herdr's. Resolving it also surfaced §4.1's `dispatched` correction,
which the draft's "design intent, not a verified fact" caveat had concealed.

## 10. Verification

1. `--plan` and `--commit` outputs are byte-identical before and after the shared-function extraction,
   for at least one roster of each transport. This is the check that §3's first bullet is true.
2. `--spawn` with `--plan` or with `--commit` → exit 2, nothing resolved, nothing launched.
3. `--spawn --mode auto` on a herdr roster of N=3 peers → three distinct panes, three launches, one
   JSON object, `partial: false`, every `launch_status: "ready"`.
4. Same on tmux → every peer `launch_status: "dispatched"`, `partial: false`.
5. A layout that yields a duplicate or empty target id → exit 2 with **zero** launch calls made
   (§11.2 assertion 6 proves the ordering, not just the exit code).
6. A single herdr member failing with the retryable condition → `retried: true` and, if the second
   attempt succeeds, `launch_status: "ready"`; the other members are unaffected and still `ready`.
7. A tmux member failing → `retried: false`. The retry branch must not fire.
8. `manual` mode's flow is unchanged end to end.

## 11. Test design (resolves §9 item 3)

New file `tests/test-roster-create-spawn.sh`, extending the fake-binary-on-`PATH` technique already
used by `tests/test-roster-spawn.sh:27-32` and the stateful fake herdr specified in `0002` §11.3.

### 11.1 The fake must be per-invocation-append, not shared-mutate

`0002` §11.3's fake herdr keeps a single JSON state file and read-modify-writes it. That is correct for
`layout-splits`, whose calls are **sequential by construction**. It is *wrong* here and would produce a
flaky suite: N concurrent fake processes read-modify-writing one JSON file will interleave and lose
writes, and the resulting failures would look like `--spawn` bugs.

**Requirement: each fake invocation writes exactly one new file and mutates nothing.**

```
$FAKE_STATE_DIR/calls/$$-<monotonic-counter>.json
```

Each call file records: `argv`, `start_ms`, `end_ms`, `exit`, and the invocation's own `pid`. Nothing
is ever appended to by two processes. The assertions read the directory afterwards and sort by
`start_ms`. The layout-phase calls, which remain sequential, use the same mechanism — one mechanism,
not two.

`$$` alone is sufficient for uniqueness in practice, but the counter is cheap and removes the argument.

### 11.2 Assertions

1. **Concurrency actually happens.** Fake `agent start` sleeps `FAKE_HERDR_SLEEP=400`. With N=4 peers,
   total wall clock is `< 4 × 400ms` by a wide margin (assert `< 1000ms`); sequential execution cannot
   pass. Deliberately loose — this is a coarse discriminator between "concurrent" and "serial", not a
   performance benchmark, and a tight bound here would be a flaky test on a loaded CI box.
2. **Concurrency is real, not just fast.** Stronger and timing-margin-free: read the call files and
   assert that the launch calls' `[start_ms, end_ms]` intervals **overlap** — at least one pair where
   `a.start_ms < b.start_ms < a.end_ms`. Prefer this assertion; keep (1) as the cheap smoke version.
3. **Supervision.** The `--spawn` process's own exit time is after `max(end_ms)` across all launch
   calls. This is the regression test for §7.2's "must not be detached" — a detached implementation
   passes assertions 1 and 2 and fails only this one.
4. **Layout is sequential.** The `pane split` call intervals do **not** overlap. This guards the
   §4 step 3 ordering that step 4's positional assignment depends on.
5. **Layout precedes launch.** `max(end_ms)` over layout calls `< min(start_ms)` over launch calls.
6. **The assertion fires before any launch.** With the fake configured to return a duplicate pane id,
   `--spawn` exits 2 and `$FAKE_STATE_DIR/calls/` contains **zero** `agent start` entries. Asserting
   the exit code alone would pass an implementation that launches first and validates after.
7. **Retry, herdr, success.** `FAKE_HERDR_FAIL_ONCE_NAME=<name>:pane_not_available` — that member gets
   exactly two `agent start` call files, ends `ready`, `retried: true`. Every other member has exactly
   one call file and is unaffected.
8. **Retry, herdr, hard failure.** `FAKE_HERDR_FAIL_ALWAYS_NAME=<name>` → exactly two call files,
   `launch_status: "failed"`, `retried: true`, `error` non-empty, and top-level `partial: true`.
9. **No retry on a non-retryable herdr failure** — once §9 item 2 resolves. If it resolves to
   "not distinguishable", this assertion is replaced by its documented fallback (retry-any) and the
   test file says so at the assertion site; it is not silently dropped.
10. **tmux dispatch.** Fake `tmux` on `PATH`. Every peer ends `launch_status: "dispatched"`,
    `retried: false`, and top-level **`partial: false`**. This is §4.1's downstream trap; without this
    assertion, treating `dispatched` as partial is invisible.
11. **tmux does not retry.** Fake `tmux send-keys` fails for one member → exactly one `send-keys` call
    file for it, `launch_status: "failed"`, `retried: false`.
12. **tmux targets a pane id.** Every `send-keys` call file's argv contains `-t` followed by the exact
    `%NN` id the corresponding `new-window` returned. This is the standing regression test for
    `0003` §4.3 — the defect it fixed is invisible in a single-member test and catastrophic at N>1.
13. **Mutual exclusion.** `--spawn --plan` and `--spawn --commit` → exit 2, `calls/` empty.
14. **`--plan` parity.** `create --plan` output is unchanged from a recorded fixture, proving the
    shared-function extraction did not alter it (§10 item 1).

### 11.3 The connection-free invariant still holds for everything else

`0002` §11.3 established a runtime assertion that no subcommand except `layout-splits` touches herdr:
a fake `herdr` that touches a marker file and exits 1, run against every other subcommand, asserting
the marker never appears — backed by a grep that the exec helper is referenced only from permitted
call sites.

**That test must be updated, not bypassed.** `create --spawn` joins `layout-splits` on the permitted
list; `create --plan`, `create --commit`, `show`, `init`, `add`, `edit`, `remove`, `layout`,
`next-split`, and every `disband` form stay on the marker-must-not-appear list. Adding `--spawn` to the
permitted set without re-running the invariant against the rest is how the exception becomes the slope
`0004` §12 item 5 warns about.

## 12. Confidence and escalation

**High** — that the architectural precedent holds. `0004`'s amendment note establishes that a named,
narrow `roster.mjs` subcommand may shell out while `--plan`/`--commit` stay pure, and its "requires its
own spec" clause is satisfied by this document rather than circumvented by it.

**High** — §9 item 1. Read from the source; the two paths are disjoint and the extraction is 14 lines.

**High** — §7.1, tmux concurrency. This is now an argument from the actual constructed command and
tmux's documented pane-id semantics, not an extrapolation from herdr's case. It also came with a
correction, which is the useful kind of verification.

**Medium-high** — §11's test design. The per-invocation-append fake and the overlap assertion are
sound, but this is the first test in the plugin that asserts anything about *timing*, and timing
assertions are the ones that rot on CI. Assertion 2 (interval overlap) is preferred over assertion 1
(wall clock) specifically to limit that exposure; if the suite proves flaky anyway, drop assertion 1
and keep 2, do not loosen 2.

**Medium** — §4 step 6's retry match condition, pending §9 item 2. Flagged, not guessed, with a stated
safe fallback so implementation is not blocked on it.

**No Ultra-Advisor escalation recommended** — but this is a closer call than `0003`/`0004` and the
reason is worth recording rather than asserting a clean "same shape as before". Starting a `claude`
process is a materially more consequential verb than splitting a pane: the failure mode has an ongoing
token cost rather than a cosmetic one. What keeps it inside the Architect's remit is §2.1 — the process
count is fixed and known before the first launch fires, it derives from the same `resolveRoster` path
`--plan` already uses, and `--spawn` has no kill path at all. Those are structural bounds, not caution.

If any of those three properties is dropped during implementation — in particular if `--spawn` ever
discovers or extends its member list mid-run, or acquires the ability to stop a process — that is a
different risk class and should come back as a new spec, exactly as this one did.
