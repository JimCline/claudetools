# 0028 — Orchestrator as sole user conduit; mandatory report-back and liveness

Status: revised (Architect), 2026-08-31 — Reviewer findings 1/2/3/5 folded in.
Supersedes nothing. Extends 0026 (orchestrator-only route gate).

Revision history, newest first:
- **r4** — Reviewer findings on tranche I, traced against shipped code:
  §4.2 rewritten (the emptiness test was inert on the CLI path — **blocking**);
  §4.3 corrected (the two hooks do not share a counter); §5.3's attribution
  premise replaced (it was unimplementable); §4.2's file attribution corrected.
  Three of the four were **my descriptive errors about existing code** — see §12.
- **r3** — UA ruling: §3.6 **BLOCKED** on the E1+E2 probe (§8.1); §3.6.3's
  peer-only fallback withdrawn as unimplementable; new §3.7 (attribution
  defect) applying to **both** gates; §2.1 implementation split added.
- **r2** — user decisions: §3.5 widened (F1), §3.6 added (E3), §5.7 added (F2).
- **r1** — original.

Changes are marked at the point of change. Superseded reasoning is struck and
explained rather than deleted.

## 0. Summary

Two enforcement gaps, one principle: **the Orchestrator is the only hierarchy
role that talks to the user, and the only role that can notice a dispatch has
stalled.** Both are prose today (`agents/orchestrator.md`: "a dispatched role's
only channel to the user runs through you"); neither is enforced.

- **(A)** A non-orchestrator hierarchy role can call `AskUserQuestion` and
  prompt the user directly. Nothing stops it.
- **(B)** Report-back is a bounded nudge that gives up silently, and the
  dispatching Orchestrator has no signal at all when a peer goes quiet.

Both fixes reuse existing machinery. (A) is a new PreToolUse hook in the shape
of the three existing gates. (B) is a hardening of two existing Stop-family
nudges, one new Orchestrator-side Stop check, and a timer layer above it.

A third change — path-scoped `Write` for roles that lack it (§3.6) — is
**blocked** pending evidence (§2.1, §8.1).

Scope discipline: this is a plumbing gap. No new mechanism style, no new state
store beyond a session-id-keyed role map and one dispatch record (§5.3).

## 1. Current state (verified this session)

`hooks/hooks.json` registers, relevant here:

| Event | Matcher | Script |
|---|---|---|
| SessionStart | `startup\|resume\|clear\|compact\|fork` | `sessionstart.mjs` |
| PreToolUse | `Agent\|Task\|SendMessage` | `pretooluse-ultra-gate.mjs` |
| PreToolUse | `Agent\|Task\|SendMessage` | `pretooluse-msg-gate.mjs` |
| PreToolUse | `Agent\|Task\|SendMessage` | `pretooluse-route-gate.mjs` |
| PostToolUse | `SendMessage` | `posttooluse-peer-resolve.mjs` |
| SubagentStop | `*` | `subagentstop-msg-nudge.mjs` |
| Stop | `*` | `stop-peer-nudge.mjs` |

Role detection already exists in `hooks/lib-config.mjs`:

- `isSubagent(input)` (:226) — true when `agent_id` is set.
- `isTopLevelAgentSession(input)` (:235) — `agent_type` set AND not a subagent.
- `hierarchyRoleOf(agentType)` (:248) — maps an `agent_type` to a role name.

`sessionstart.mjs:83` already computes `role` for a top-level agent session
exactly this way. `subagentstop-msg-nudge.mjs:79` does the same from
`input.agent_type` on the SubagentStop payload.

**No hook references `AskUserQuestion` as a matcher.** The only occurrences are
in *deny-instruction text* (`pretooluse-route-gate.mjs:126, 152, 160, 204,
223`; `pretooluse-ultra-gate.mjs:65`; `lib-config.mjs:787, 848`). §3.2 covers
why that matters.

Tool grants live in each `agents/*.md` frontmatter as a flat denylist — e.g.
Reviewer is "All tools except Edit, Write, NotebookEdit". **That format cannot
express path scoping, and it is per-agent-definition, shared by both the peer
and subagent routes.** Both facts constrain §3.6.

**Message-file creation** — `createMessage` (`lib-hier.mjs:272`)
unconditionally writes `skeletonBody(RESPONSE_KEYS)`. **Every file produced by
`msg.mjs new` has a non-empty body from birth.** This fact is load-bearing for
§4.2 and was missing from r1–r3.

## 2. Roles and routes — the two cases are not symmetric

| Route | User-conduit risk (A) | Stall risk (B) |
|---|---|---|
| **Subagent** (`Agent` tool, foreground) | Real — a subagent's `AskUserQuestion` surfaces to the user. | **None by construction.** The dispatching call blocks; the subagent's final text *is* the return value. |
| **Subagent** (background / async `Agent`) | Same as above. | Real but bounded — the harness delivers a completion notification. See §6.3. |
| **Peer session** (`SendMessage` to a live session) | Real, and worst — a peer has its own terminal and its own user-facing surface. | **Real and unbounded.** Nothing returns. |

So: (A) applies to all three. (B)(ii) — active check-in — applies meaningfully
only to the **peer** route.

### 2.1 Implementation split

| Tranche | Sections | Status |
|---|---|---|
| **I — conduit + report-back + liveness** | §3.1–3.5, §3.7, §4, §5 | **UNBLOCKED**, r4 corrections outstanding |
| **II — write carve-out** | §3.6 | **BLOCKED** on the §8.1 probe |

Tranche I carries E4 (§5.3) and E5 (§8) as its own gates. Neither requires the
probe. The probe can run in parallel; it shares no code.

## 3. (A) Block direct user contact from non-orchestrator roles

*(§3.1–§3.7 unchanged in r4. Reviewer's findings were all in §4/§5.)*

### 3.1 New hook: `hooks/pretooluse-conduit-gate.mjs`

Registered in `hooks/hooks.json` as:

```json
{ "matcher": "AskUserQuestion|ExitPlanMode|SendUserFile|PushNotification",
  "hooks": [ { "type": "command",
  "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse-conduit-gate.mjs" } ] }
```

Decision logic, in order:

1. Resolve the caller's hierarchy role **by positive direct attribution only**
   (§3.7). If it is `null` — not a hierarchy session, or the role could not be
   attributed to *this caller* — **allow**.
2. If the role is `orchestrator` — **allow**.
3. Otherwise — **deny** with the text in §3.4.

Degradation direction is load-bearing: **every unknown allows.** A false deny
wedges a session that has no way to proceed and no way to explain itself; a
false allow reproduces exactly today's behaviour. UA confirmed fail-open as
correct here.

Emit the denial in the same shape the existing gates use
(`permissionDecision: "deny"` + `permissionDecisionReason`).

**No one-shot state.** This gate has no user-selectable outcome to remember —
it is not offering a choice, it is closing a channel. Do not wire it into
`readGateState`/`setDecision`.

### 3.2 Interaction with the three existing gates — the deadlock

`pretooluse-route-gate.mjs` and `pretooluse-ultra-gate.mjs` resolve themselves
by instructing the denied session to **call `AskUserQuestion`**. If a
non-orchestrator role ever triggers one, it is told to ask the user, and the
conduit gate then denies that. Deadlock with no path forward.

Per 0026 the route gate is already orchestrator-only, so this may be
unreachable today. **It must not be left to chance.** Required:

- **Primary:** each of the three gates must positively confirm the session is
  the Orchestrator before firing. Where a gate already does (route gate, per
  0026), assert it with a test rather than assuming it.
- **Belt-and-braces:** the conduit gate's deny text names the case — "if you
  reached here because another gate told you to ask the user, that gate should
  not have fired for your role; report it as a defect in your response message
  rather than retrying."

**Do not** solve this by exempting `AskUserQuestion` when a gate is pending.
That hole is exactly the size of the thing being closed.

### 3.3 Role resolution inside a PreToolUse hook

Specify a resolution helper in `lib-config.mjs` that returns **both** a role
and how confidently it was attributed:

```js
// Returns { role, direct } — `direct: true` only when the payload itself
// identifies the caller. Callers that enforce policy must check `direct`.
export function resolveHierarchyRole(input) {
  const direct = input && input.agent_type ? hierarchyRoleOf(input.agent_type) : null;
  if (direct) return { role: direct, direct: true };
  const persisted = readSessionRole(normalizeSessionId(input && input.session_id));
  return { role: persisted, direct: false };
}
```

The persisted half requires `sessionstart.mjs` to store what it already
computes at :83 — a session-id-keyed map beside the existing gate state, same
append-and-cap discipline as `lib-gate.mjs` (`MAX_SESSIONS = 50`).

**Do not collapse the return to a bare role string.** The `direct` flag is what
§3.7 keys on.

### 3.4 Deny text

Requirements, not literal wording:

- Name the role and state the rule: this role does not talk to the user.
- Give the concrete alternative: put the question in the response message
  file's `open_questions` (or `want_back`), state each option and what it
  decides, and **return** — do not block waiting.
- State that returning with an unresolved question is a correct outcome, not a
  failure.
- Include the §3.2 belt-and-braces sentence.
- For `SendUserFile` / `PushNotification`, name the artifact by absolute path
  in the response message and let the Orchestrator surface it.

### 3.5 Which tools — DECIDED (was fork F1)

**User decision: gate (A) covers `SendUserFile` and `PushNotification` in
addition to `AskUserQuestion` and `ExitPlanMode`.** The reading is the strict
one: the user's attention is the Orchestrator's to spend, not just the user's
answers.

### 3.6 Write access for response and spec files — **BLOCKED**

> **DO NOT IMPLEMENT THIS SECTION.** Ultra-Advisor ruled that §3.6 must not
> land before the §8.1 probe answers E1 **and** E2.

**User decision:** *"Any agent should be able to write a new file especially
messages back to the orchestrator or specs."* Path-scoped `Write` for all
roles, limited to hierarchy message files and spec files. The gap is real —
and r4 note: **the Reviewer hit it live**, having to reply to this very review
inline via SendMessage because it has no `Write` to author a response file.

#### 3.6.1 Intended mechanism

1. **Remove `Write` from the denylist** in `agents/reviewer.md` (and any other
   role that lacks it, per E6).
2. **New `hooks/pretooluse-write-scope.mjs`**, matcher `Write`, denying a write
   outside the permitted directories, **for positively-attributed scoped roles
   only** (§3.7).

Scoped: `architect`, `reviewer`, `ultra-advisor`. This *tightens* the
Architect, which today has unrestricted `Write` against a contract saying Write
exists only to author specs. **Not scoped: `implementor`.** No `Write` for
`task-runner`.

#### 3.6.2 Permitted paths

- Messages dir via `hierarchyDir(cwd)` (`lib-config.mjs:280`) — **not** a
  literal `.claude/hierarchy/msgs`. That function honours
  `AGENT_HIERARCHY_DIR` and falls back to a homedir path.
- `<repoRoot>/**/docs/specs/` — repo root via `findGitRoot(cwd)`.

Matching requirements, all load-bearing: `resolve()` first; containment by path
**segment**, not string prefix (`/a/b` must not match `/a/bc`); reject escapes
on the resolved result; **resolve symlinks** (`realpathSync` on the nearest
existing ancestor) or a symlink inside `msgs/` is a write-anywhere primitive;
on any resolution error **allow**, per §3.7's fail-open rule.

#### 3.6.3 Why this is blocked — and the fallback that does not exist

The carve-out's safety rests entirely on attribution working. For the
**subagent** route that is unconfirmed (E2). If E2 is negative, a Reviewer
*subagent* gets **unrestricted** `Write`.

~~r2 proposed delivering the carve-out for peer sessions only.~~ **Withdrawn —
UA ruled it unimplementable and UA is right.** Frontmatter is per *agent
definition*; both routes read the same one. I proposed a scope split along a
boundary the mechanism cannot see. My error.

**Options if E2 is negative** (decide then, not now): **(i)** no `Write` grant
to Reviewer at all, §4.4's limitation stands; **(ii)** a subagent-identity
channel as **its own spec**. Do not resolve this inside 0028.

### 3.7 Attribution defect — the persisted fallback is not a substitute

**Root cause.** A subagent shares its parent session's `session_id`. So
`readSessionRole(session_id)` returns the *parent peer's* role even when the
caller is a subagent. The persisted map answers "what role is this session?";
the gates need "what role is this **caller**?"

**Face 1 — write-scope gate fails CLOSED.** Architect peer dispatches an
Implementor subagent; persisted map says `architect`, a scoped role, so the
subagent's product-code write is **denied**.

**Face 2 — conduit gate fails OPEN.** Orchestrator peer dispatches an Architect
subagent; persisted map says `orchestrator`, so `AskUserQuestion` is
**allowed** — the hole gate (A) exists to close.

**Required rule, both gates:** *enforce only on positive direct attribution.*
Deny (conduit) or scope (write) **only** when `direct: true`. When
`direct: false`, **allow**, whatever the persisted role says. The persisted map
may still be used for non-enforcement purposes; it must not gate a tool call.

**Consequence:** if the probe shows PreToolUse carries no `agent_type`, `direct`
is never true and **both gates are inert**. That is not a reason to relax the
rule — an inert gate is honest, a mis-attributing gate is worse than none — but
it means **E1 determines whether tranche I's gate (A) does anything at all.**

## 4. (B)(i) Make report-back non-optional

### 4.1 What exists — corrected in r4

Both nudges can block, but **they are not the same shape**, and r1–r3 wrongly
described them as symmetric:

- `stop-peer-nudge.mjs:49` emits `{"decision":"block","reason":...}` for a peer
  session with an unmet obligation, gated by `stop_hook_active` (:72), an armed
  turn marker (:82), and **`nudgeCount < MAX_NUDGES` (:89, `MAX_NUDGES = 2` in
  `lib-peer.mjs`)** — a counter.
- `subagentstop-msg-nudge.mjs:36` emits the same for a dispatched role
  subagent, when `hasResponseToken(last, meta.id)` is false (:100). **It has no
  counter.** It is **one-shot per `agent_id`** via `hasGate(... type ===
  "nudge")` at :84; the second stop always passes.

Both run on Stop-family events, which **do** carry `agent_type`, so §3.7's
attribution problem does not affect §4.

### 4.2 Hole 1: the emptiness test — REWRITTEN in r4 (Reviewer finding 1, blocking)

**The r1–r3 rule was inert on the path it was written for.**

r3 required a response file that "exists and is non-empty beyond the
frontmatter". But `createMessage` (`lib-hier.mjs:272`) unconditionally writes
`skeletonBody(RESPONSE_KEYS)`, so **every file produced by `msg.mjs new --type
response` — the exact command the nudge text prescribes at
`subagentstop-msg-nudge.mjs:101` — has a non-empty body from birth.** A role
could emit the token, run the one prescribed command, write nothing, and pass.
That is Hole 1 verbatim: the Orchestrator gets a path to nothing. Only the MCP
`msg_new` stub (§4.4) was actually caught.

**Required rule, restated.** The test is not "is the body non-empty" but **"did
the author write anything?"** Implement in `hasResponseToken`'s completion
check (`lib-hier.mjs:452-467`) — see §4.2.1 for why that placement:

1. Strip the frontmatter block.
2. From the remainder, discard every line that is **structurally generated**:
   blank lines, section headings of the form `## [n] <key>`, and bare
   placeholder bullets (`- none`, `- [n] <key>: ` with no trailing content).
3. If nothing remains → **unfilled** → block.

**Do not implement this as byte-identity against `skeletonBody(RESPONSE_KEYS)`.**
Reviewer offered it as one option; it is the more brittle of the two. An exact
comparison is defeated by one added space and breaks silently whenever the
skeleton's wording or key list changes — a check that fails open on a cosmetic
edit to an unrelated function. The line-class filter above tests the property we
actually care about and is stable across skeleton revisions.

**Accepted false-positive risk:** a genuinely minimal but valid response whose
every line looks structural. The bound in §4.3 is the escape hatch — this is
exactly the case it exists for, and it is why §4.4's bound is not negotiable.

#### 4.2.1 Placement — corrected in r4 (Reviewer finding 5)

~~r1–r3 said peer-side satisfaction happens in `stop-peer-nudge.mjs` "via
`targetSatisfiesRecord(to, rec)`".~~ **Wrong on both counts.**
`stop-peer-nudge.mjs` never calls that function and never imports it.
Satisfaction happens in `posttooluse-peer-resolve.mjs:45`, which routes through
`hasResponseToken`.

Consequence, and it is a helpful one: **`hasResponseToken` is the only
placement that reaches both consumers** — the subagent nudge and the peer
resolve path. Put the §4.2 rule there and both routes are fixed by one change.
Reviewer's Deviation 1 is approved; the spec named the wrong file.

### 4.3 Hole 2: giving up is silent — CORRECTED in r4 (Reviewer finding 2)

~~r1–r3: "At `MAX_NUDGES`, both hooks stop nudging."~~ **False of the subagent
hook**, which has no counter (§4.1). There is no second attempt to escalate
into, so the r3 instruction to "escalate the text across the two attempts"
was unexecutable there, and the Implementor correctly left it alone.

**Required, restated per hook:**

- **Peer route** (`stop-peer-nudge.mjs`): as r3. Escalate text across the two
  attempts — the first a reminder, the second stating it is the last and that
  stopping without a response file is recorded.
- **Subagent route** (`subagentstop-msg-nudge.mjs`): keep the one-shot shape.
  **Do not add a counter** — that is re-architecting a working hook for
  cosmetic symmetry with a different hook. The one-shot *is* its bound.

**Both routes must record the give-up.** This is the part that was missing on
the subagent side, and it is the actual point of §4.3 — a bounded give-up is
fine, a *silent* one is not. On the terminal allow:

- Peer: write an unmet-obligation record via `appendPeerRecord`
  (`lib-peer.mjs`) with a distinguishable status.
- Subagent: `appendGate(dir, {type: "nudge-unmet", agent_id, id})` on the
  second stop — i.e. when `hasGate` reports already-nudged and the hook is
  about to allow.

§5 consumes both.

### 4.4 Why the bound stays

`agents/reviewer.md` grants "All tools except Edit, Write, NotebookEdit". **A
Reviewer has no `Write` tool.** It can create a response file via
`mcp__ah__msg_new`, but filling the body is a write — and `msg_new`'s schema
takes `cwd/to/from/slug/type/id/parent/reason/team/to_name/from_name` and **no
body parameter**. Confirmed live in r4: the Reviewer could not author a
response file for this review and replied inline instead.

§3.6 was to fix this and is blocked (§3.6.3), which makes the bound **mandatory
rather than merely prudent**: an unbounded block on a role structurally
incapable of satisfying it wedges the session permanently — strictly worse than
the silent give-up §4.3 is fixing. §4.2's tightened test makes this sharper,
not softer: a Reviewer that creates a skeleton and cannot fill it now correctly
fails the check, and the bound is the only thing standing between that and a
wedged session.

Keep the bound even if §3.6 lands. A role can be blocked for reasons the hook
cannot see (full disk, revoked permission, a path outside §3.6.2).

**Residual (E6):** whether `msg.mjs new` accepts a body on stdin. If it does,
that answers the Reviewer gap without §3.6 at all — materially cheaper, and now
more interesting given §4.2's tightening.

## 5. (B)(ii) Orchestrator-side liveness check-in

Two layers. The Stop-driven check (§5.2) is primary; the timer (§5.7) covers
what the Stop check structurally cannot see.

### 5.1 The design choice: Stop-driven as the primary

The Orchestrator has no dependable wall-clock primitive. `ScheduleWakeup`
exists only in `/loop` dynamic mode; `Monitor` targets background tasks;
`CronCreate` schedules outside the session.

But consider *when the check matters*. If the Orchestrator is busy it does not
need reminding. The dangerous moment is when it **goes idle** while a peer's
response is outstanding — and that is exactly a `Stop` event, which fires
unconditionally in every session.

### 5.2 New hook: `hooks/stop-orchestrator-liveness.mjs`

Stop, matcher `*`. Logic:

1. Role is `orchestrator`, else allow. (Stop payloads carry `agent_type`, so
   this is a direct attribution — §3.7 satisfied.)
2. Guard on `stop_hook_active`, as `stop-peer-nudge.mjs:72` does.
3. Compute **outstanding dispatches** (§5.3).
4. None outstanding → allow.
5. Some outstanding → `decision: "block"` with the §5.4 text, bounded per
   outstanding id so an unresponsive peer cannot wedge the Orchestrator.

### 5.3 Outstanding dispatches — PREMISE REPLACED in r4 (Reviewer finding 3)

**Derivation of the pair.** For each request file in the hierarchy messages
directory with `from: orchestrator`, a matching response exists when a file
with the **same `id`** and `type: response` is present. Confirmed by existing
pairs in this repo. Outstanding = request with no matching response.

~~r1–r3: "Reuse the existing peer record store to identify which requests
belong to this session."~~ **Unimplementable, and the shipped code could not do
it.** The peer record's `session_id` is the **recipient's**, written by the
peer's own UserPromptSubmit tracking. There is no dispatcher identity in it.
Two consequences, both confirmed against the shipped code:

- **Over-firing.** With no dispatcher filter, any `from: orchestrator` open
  request in the team dir blocks *every* non-subordinate session in that repo,
  including one that never sent it. Two Orchestrator sessions in one repo
  cross-block on each other's dispatches.
- **Under-firing, and this is the sharper half.** The peer record exists only
  if the peer *received* the brief and its hook ran. **A peer that died before
  receiving — the stall most worth catching — is invisible**, and a
  cross-machine peer always is. The mechanism confirming "this was a peer
  route" is written only on successful delivery.

**Required replacement: record the dispatch on the sending side.**

`posttooluse-peer-resolve.mjs` already runs on `PostToolUse` / `SendMessage` in
the **dispatcher's** session and already parses `[hierarchy-msg <path>]` tokens.
Extend it: when the sent message carries a request token, append a **dispatch
record** — `{session_id, request_id, to, created}` — where `session_id` is the
*sender's*, taken from the hook payload.

This fixes both faces with one append, because the record is written by the
sender at send time:

- Attribution is correct: `session_id` is the dispatcher's by construction.
- Coverage no longer depends on delivery: a peer that never received the brief,
  or lives on another machine, still has a dispatch record.

`outstandingDispatches` then filters on `record.session_id === input.session_id`
and treats a request with a dispatch record as a peer route (§5.3's
peer-vs-subagent discriminator), rather than inferring the route from a
recipient-side artifact.

**Fallback if this proves unimplementable (do not choose it silently):** drop
the filter, accept cross-session over-firing, and name both limitations in §6.
That is materially worse and should be reported back before being taken.

**NEEDS-EVIDENCE E4 — still gates this section:** confirm (a) response files
reliably reuse the request's `id` across every producer, and (b) — **new in
r4** — that the `PostToolUse`/`SendMessage` payload in the *dispatcher's*
session carries both the sender's `session_id` and the message text needed to
parse the request token. If (b) is false, the §5.3 replacement does not work
and this section needs redesigning before §5.2 or §5.7 are written.

### 5.4 What "checking in" actually does

The block text tells the Orchestrator, concretely:

1. Name each outstanding dispatch: role, peer address, request id, and how long
   ago it was sent (from the dispatch record's `created` — no clock state).
2. Prescribe the action: `ListAgents` to confirm the peer is alive, then
   `SendMessage` a short status query.
3. Say what to do with the outcomes — a peer that answers is fine; a peer gone
   or silent after a check is a fact the Orchestrator **should** surface to the
   user, since the Orchestrator is the conduit.
4. Name the escape: a deliberately parked dispatch may be stopped on; the
   second block is the last.

### 5.5 Two Stop hooks, one session

`stop-peer-nudge.mjs` and the liveness hook both run on every Stop. Mutually
exclusive by role: peer-nudge handles a session that **owes** a report;
liveness handles one that is **owed** one. If `stop-peer-nudge` blocks, the
liveness hook must not also block in the same turn — the obligation owed takes
precedence, because the session above is blocked on it.

### 5.6 Complexity scaling

Requests carry an optional `eta:` frontmatter field:

| `eta` | threshold |
|---|---|
| `small` | 5 min |
| `medium` | 10 min |
| `large` | 20 min |
| absent / unrecognised | treat as `small` |

The Stop check suppresses its block until the dispatch is older than the
threshold. The timer uses the same value as its delay.
`agents/orchestrator.md` must instruct setting `eta:` on peer dispatch.

*(r4 note: Reviewer found the MCP `msg_new` schema is missing `--eta`. That is
an impl-defect, routed straight to Implementor — no spec change.)*

### 5.7 Timer layer — DECIDED (was fork F2)

**User decision: add the timer check-in on top of the Stop-driven check.**

#### 5.7.1 It cannot be a hook

Hooks are reactive. **No hook can schedule a wakeup.** Only the Orchestrator
session itself can call `ScheduleWakeup`. So the timer layer is **prose in
`agents/orchestrator.md` plus reuse of the §5.3 derivation**, not a new hook
file. Stated plainly because an Implementor reading "add a timer layer" beside
four hook specs will look for the fifth hook.

#### 5.7.2 Mechanism

- After `SendMessage`-ing a request to a peer, call `ScheduleWakeup` with
  `delaySeconds` = the `eta` threshold, and a `prompt` naming the outstanding
  request id and instructing the §5.4 check-in on wake.
- On wake, re-derive outstanding dispatches. Matching response → done, do not
  reschedule. Still outstanding → perform the §5.4 check-in, reschedule
  **once** at half the threshold. After the second miss, surface to the user.

#### 5.7.3 Availability constraint

`ScheduleWakeup` is available only in `/loop` dynamic mode. **In an ordinary
interactive session it does not exist.** The prose must be conditional:
schedule when available, rely on the Stop check when not.

**Do not substitute `CronCreate`.** Cron fires outside the session's context,
so the woken agent lacks the state the check-in needs, and the entry outlives
the session — a durable side effect from a transient safety net.

**NEEDS-EVIDENCE E7:** confirm whether `ScheduleWakeup` is genuinely
loop-mode-only. Emphasis, not design.

## 6. Known limitations, named and accepted

1. **Gate (A) may be inert on some or all routes** if PreToolUse carries no
   `agent_type` (§3.7). Determined by the §8.1 probe.
2. **An Orchestrator idle at a user prompt** past its second liveness block
   will not re-check until the user speaks or a wakeup fires.
3. **A hung background subagent** has no stall detection here.
4. **A role that ignores a deny and reports "I could not proceed"** is not
   prevented. No hook can compel good reporting; (B) makes the silence visible.
5. **The Reviewer response-file gap stays open** while §3.6 is blocked (§4.4),
   and §4.2's tightening makes it bite harder — a Reviewer can no longer pass
   the check with an unfillable skeleton. Confirmed live in r4.
6. **A dispatch sent before this spec lands has no dispatch record** (§5.3), so
   the liveness check is blind to it. Self-correcting after one dispatch cycle;
   no migration needed.

## 7. Test scenarios

**OUTCOME** tests hold before the fix by construction — regression guards, and
the Implementor should **not** try to make them fail.

Tranche I: T1–T15, T24–T30. Tranche II (blocked): T16–T23.

| # | Scenario | Expect | Kind |
|---|---|---|---|
| T1 | PreToolUse `AskUserQuestion`, `agent_type` = architect | deny | **falsifiable** |
| T2 | PreToolUse `AskUserQuestion`, `agent_type` = orchestrator | allow | OUTCOME |
| T3 | PreToolUse `AskUserQuestion`, no `agent_type`, no persisted role | allow | OUTCOME |
| ~~T4~~ | ~~persisted-role deny~~ | **REMOVED r3** — asserted what §3.7 forbids | — |
| T5 | PreToolUse `ExitPlanMode`, `agent_type` = implementor | deny | **falsifiable** |
| T5a | PreToolUse `SendUserFile`, `agent_type` = reviewer | deny | **falsifiable** |
| T5b | PreToolUse `PushNotification`, `agent_type` = architect | deny | **falsifiable** |
| T6 | ultra/route/msg gate invoked with a non-orchestrator role | gate does not fire | **falsifiable** |
| T7 | SubagentStop, token present, file **missing** | block | **falsifiable** |
| T8 | SubagentStop, hand-written frontmatter-only stub | block | **falsifiable** |
| **T8b** | SubagentStop, stub produced by `msg.mjs new --type response`, **not edited** | **block** | **falsifiable — THE blocking case (r4).** Must fail pre-fix. |
| ~~T9~~ | ~~CLI-created unedited file → allow, "real skeleton body"~~ | **INVERTED in r4** — this test *encoded* the hole. It is now T8b and expects block. | — |
| **T9b** | SubagentStop, file with genuine authored content under `## [1]` | allow | OUTCOME |
| **T9c** | Response file where the author filled only *one* section, rest skeleton | allow | **falsifiable** — guards against §4.2 over-rejecting |
| T10 | Peer Stop, obligation unmet, count at `MAX_NUDGES` | allow, **and** unmet record written | **falsifiable** |
| **T27** | SubagentStop, second stop for the same `agent_id` with obligation still unmet | allow, **and** `nudge-unmet` gate record written | **falsifiable** — §4.3, the r4 gap |
| T11 | Orchestrator Stop, one peer request with no matching response, older than `eta` | block, names request id and peer | **falsifiable** |
| T12 | Orchestrator Stop, request has a matching response | allow | OUTCOME |
| T13 | Orchestrator Stop, outstanding request newer than `eta` | allow | **falsifiable** |
| T14 | Orchestrator Stop, outstanding **subagent** dispatch only | allow | **falsifiable** |
| T15 | Session that both owes a report and is owed one | peer-nudge blocks; liveness does not | **falsifiable** |
| **T28** | Two Orchestrator sessions, same repo; session B Stops with only session A's request outstanding | **allow** — B is not blocked by A's dispatch | **falsifiable** — §5.3 over-firing |
| **T29** | Peer request sent, peer never received it (no peer record exists), older than `eta`; dispatcher Stops | **block** | **falsifiable** — §5.3 under-firing, the stall most worth catching |
| **T30** | Dispatch record written on `PostToolUse`/`SendMessage` carries the **sender's** `session_id` | contract test | **falsifiable** — §5.3 |
| T24 | Conduit gate: no `agent_type`, persisted role `architect` | allow | **falsifiable** — §3.7 face 1 |
| T25 | Conduit gate: no `agent_type`, persisted role `orchestrator` | allow | **falsifiable** — §3.7 face 2 |
| T26 | `resolveHierarchyRole` returns `{direct:false}` whenever `agent_type` absent | contract test | **falsifiable** |
| T16–T23 | *(tranche II — blocked, do not implement)* | — | blocked |

**r4 instruction to the Implementor, explicit:** T9 as shipped asserts the
defective behaviour. Do **not** merely add T8b alongside it — the suite would
then contradict itself and one of the two would have to be wrong. Invert T9
into T8b, and add T9b/T9c as the new allow-cases.

## 8. NEEDS-EVIDENCE

- **E1 / E2 — the probe.** §8.1. Gates §3.6 entirely, and determines whether
  gate (A) is deliverable (§3.7).
- **E4 — (a)** id reuse across producers; **(b, new in r4)** does the
  dispatcher-side `PostToolUse`/`SendMessage` payload carry the sender's
  `session_id` and the message text? **Gates §5.3 and both liveness layers.**
- **E5 — Confirm T1 fails pre-fix.** If it *passes*, §1's premise is wrong —
  **stop and report**.
- **E6 —** which roles other than `reviewer` lack `Write`, and **does `msg.mjs
  new` accept a body on stdin?** The second is now more interesting (§4.4).
- **E7 —** is `ScheduleWakeup` loop-mode-only? Emphasis, not design.

### 8.1 The E1+E2 probe — order text, ready to dispatch

> **Goal.** Determine what identity fields a PreToolUse hook payload carries,
> for (a) a top-level `--agent` session and (b) a subagent dispatched from one.
> Report the raw fields. Make no design decisions and change no product
> behaviour.
>
> **Build.** Create a temporary hook `agent-hierarchy/hooks/_probe-payload.mjs`:
> reads the hook input JSON from stdin; appends one JSON line to
> `/tmp/ah-probe.jsonl` containing `Object.keys(input)` and the values of
> `session_id`, `agent_id`, `agent_type`, `transcript_path`, `cwd`,
> `tool_name`, plus a `mark` passed through from an env var. **Always exits 0
> with no stdout**, whole body in try/catch — a probe that breaks a session is
> a failed probe. Register it in `hooks/hooks.json` as PreToolUse matcher `*`.
>
> **Run A.** Launch `claude --agent ah:architect` in this repo; have it make one
> trivial tool call (a `Read`). Record the probe line.
>
> **Run B.** From that same session, dispatch any subagent (e.g.
> `task-gopher:task-gopher`) with an order that makes exactly one tool call.
> Record the probe line(s) from the subagent's call.
>
> **Report, as a table.** For each run: every key present, and the values of the
> six named fields (redact absolute paths to their last two segments; do not
> paste transcripts). Then answer explicitly: **(1)** is `agent_type` present in
> run A? **(2)** are `agent_id` and/or `agent_type` present in run B? **(3)** is
> run B's `session_id` equal to run A's?
>
> **Clean up.** Remove the registration and delete `_probe-payload.mjs`.
> Confirm removal in your report.
>
> **If anything fails** — hook does not fire, log empty, session errors —
> report exactly what happened and stop. Do not iterate on the probe's design
> or infer the answer from documentation.

| Result | Consequence |
|---|---|
| E1 yes, E2 yes | Gate (A) covers both routes; §3.6 can proceed as §3.6.1. |
| E1 yes, E2 no | Gate (A) covers peer sessions only. §3.6 must **not** land — §3.6.3 (i) or (ii). |
| E1 no | **Gate (A) is inert.** §3 needs redesign; §4 and §5 unaffected. **Stop and report.** |
| `session_id` equal | Confirms §3.7's defect; the rule is required as written. |
| `session_id` differs | §3.7's rule is stricter than needed but still safe. **Do not relax without re-dispatching.** |

## 9. Decisions recorded

- **E3 → §3.6.** Path-scoped `Write`. **Blocked pending §8.1.**
- **F1 → §3.5.** Gate (A) covers `SendUserFile` and `PushNotification`.
- **F2 → §5.7.** Timer layer above the Stop-driven check.
- **UA ruling (r3).** Fail-open correct. §3.6 blocked. Peer-only fallback
  withdrawn. §3.7 added.
- **Reviewer findings (r4).** 1 → §4.2 rewritten + T8b/T9 inverted; 2 → §4.3
  corrected per-hook + T27; 3 → §5.3 premise replaced + T28/T29/T30; 5 → §4.2.1
  placement corrected, Deviation 1 approved.

## 10. Acceptance

**Tranche I:**

- A positively-attributed non-orchestrator role's `AskUserQuestion`,
  `ExitPlanMode`, `SendUserFile` and `PushNotification` are denied.
- The Orchestrator's own use of all four is unaffected; the three existing
  gates resolve exactly as today (§3.2, T6).
- **No tool call is ever gated on a persisted role** (§3.7, T24–T26).
- **A dispatched role cannot stop having merely run `msg.mjs new`** — an
  unedited CLI-produced skeleton fails the check (T8b), and a partially filled
  file passes (T9c). *(r4: the r3 wording of this bullet was satisfied by code
  that did not achieve it.)*
- **Both** routes record an unmet obligation when they give up (T10, T27).
- The liveness check blocks only the session that sent the dispatch (T28), and
  catches a peer that never received its brief (T29).
- An Orchestrator that stays active is reminded on a timer where the harness
  supports one, and loses nothing where it does not.
- No new state beyond the session-id-keyed role map (§3.3, non-enforcing) and
  the dispatch record (§5.3).

**Tranche II:** deferred. Acceptance restated when §8.1 reports.

## 11. Confidence

**Tranche I: medium on §3, medium-low on §4 and §5.**

§3's mechanism is sound but its *coverage* is contingent on the probe.

§4 I now rate lower than in r3. The Hole-1 rule shipped inert because I
specified a property ("non-empty body") without checking what the tool that
creates these files actually writes — and the suite encoded the hole rather
than catching it, which means the green run was evidence of nothing. §4.2's
replacement is a better test but it is still a heuristic about line shapes, and
T9c exists because I expect it to over-reject at some margin.

§5 rests on E4, which grew a second clause in r4: the §5.3 replacement is only
implementable if the dispatcher-side `PostToolUse` payload carries what it
needs. If it does not, §5.3 needs redesigning, not patching.

No further escalation recommended. Every remaining unknown is empirical and has
a written order.

## 12. Note on the r4 defects — a pattern, now named

Three of Reviewer's four findings (1, 2, 5) are the same error: **I described
what existing code does without tracing it, and specified against the
description.** §4.2 assumed `createMessage` wrote an empty body. §4.3 assumed
both nudge hooks shared `MAX_NUDGES`. §4.2.1 attributed peer satisfaction to a
function the named file never imports.

The mechanism, worth recording because it is subtle: I *did* have a delegate's
report on these files. It stated correctly that `stop-peer-nudge.mjs` blocks at
:49 and that `MAX_NUDGES = 2` lives in `lib-peer.mjs`. I generalized a fact
reported about one file to its sibling, and generalized "there is a bound" to
"both hooks share this bound".

Prior commitments covered claims about *outcomes* and *untraced paths* (0027's
bare-repo degradation, r3's unimplementable scope split). This is a third
variant: claims about *current implementation*. The rule that covers all three:

> Any statement in a spec about what shipped code does — its behaviour, its
> structure, or which function it calls — must cite `file:line` from something
> actually read, or be marked unverified. A fact reported about one file is not
> a fact about its sibling.

Reviewer tracing these against the code rather than trusting the green suite is
what caught them. The suite passing was not evidence; T9 asserted the defect.
