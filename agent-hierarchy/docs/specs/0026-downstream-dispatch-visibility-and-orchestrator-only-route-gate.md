# 0026 — Downstream-dispatch visibility, and an orchestrator-only route gate

Status: draft (Architect)
Author: claudetools-architect
Created: 2026-08-28
Source: request `20260828-091308-3dlj` (ct-orchestrator), reported live from
bear-poppa-promo usage via bps-ultra-advisor relaying the user.

Spec number was NOT dictated in the dispatch. `docs/specs/` holds `0001`–`0025`
contiguously, so `0026` is the next free slot by convention. If the Orchestrator
wanted a different path, this file should be renamed before implementation
starts.

---

## 1. Goal

Two independent defects in the msg/route plumbing, specced together because both
turn on the same missing primitive — **a session's knowledge of its own role**.

- **Bug 1 (visibility).** When a dispatched role (e.g. Ultra-Advisor) itself
  dispatches a further peer on the originating Orchestrator's behalf, the
  Orchestrator has no way to see that it happened.
- **Bug 2 (route gate).** The interactive peers/prefer-peers/subagents
  route-selection gate fires inside *any* session, including a subordinate role
  executing a brief it was handed. A subordinate must never interrupt the user
  to choose session-routing plumbing.

Bug 2 is the higher-severity of the two: it blocks work and interrupts a human,
whereas bug 1 degrades an Orchestrator's situational awareness. **Implement bug 2
first**; it is also the smaller diff.

---

## 2. What already exists (verified, do not re-derive)

Every line reference below was confirmed by reading the file. Treat this section
as the ground truth the design rests on.

### 2.1 The route gate

`agent-hierarchy/hooks/pretooluse-route-gate.mjs`, a **PreToolUse** hook.

- `:260` — `sessionId` is already in scope, and `resolveConfig` is already
  called with it.
- `:263` — `dir = hierarchyDir(cwd)`.
- `:268-289` — `role` is computed. **This is the TARGET role**, not the calling
  session's own role:
  - `:271` dispatch path — `role = hierarchyRoleOf(toolInput.subagent_type)`
  - `:282-288` send path — resolved from the recipient name.
- `:294-303` — global-scope confirm gates (spec 0009 §4). **Different purpose;
  out of scope here** — see §4.5.
- `:306-368` — the routing-preference block. Three separate interactive asks
  live inside it:
  - `:309-315` **route-ask** — the peers/prefer-peers/subagents question. This
    is the one the bug report names.
  - `:353-357` **peer-fallback-ask** — fires under `route === "peers"` when no
    live peer exists.
  - `:344-348` **on-missing-auto** — fires under `route === "peers"` with an
    `auto` on-missing policy.
- `:314` — the existing fall-through comment already documents that an
  unanswered route-ask enforces the `peers` default.

**The hook has no notion of the calling session's own role anywhere.** That
absence is the entire defect.

### 2.2 Session self-identity — the primitive both bugs need

- `agent-hierarchy/hooks/sessionstart.mjs:83` —
  `const role = isTopLevelAgentSession(input) ? hierarchyRoleOf(input.agent_type) : null;`
- `sessionstart.mjs:90-100` — appends `{status:"up", role, session_id, ...}` to
  `peers.jsonl` (write is guarded by not-a-subagent **and** a resolved role).
- `lib-config.mjs:235-238` — `isTopLevelAgentSession(input)`: `agent_type` is a
  non-empty string **and** not a subagent.
- `lib-config.mjs:248-251` — `hierarchyRoleOf(agentType)`: matches a bare role
  or a `plugin:role` suffix against `ROLES`.
- `lib-config.mjs:148` —
  `PEER_ELIGIBLE_ROLES = ["ultra-advisor", "architect", "reviewer", "implementor"]`.
  Note this list **excludes** `orchestrator` and `task-runner`; it is a list of
  dispatch *targets*, and must NOT be reused as the "am I subordinate?" test.
- `lib-hier.mjs:480-481` — **`upRecordFor(dir, sessionId)`** returns the "up"
  record for a session id. This is the exact lookup both bugs need, and it
  already exists. No new helper, no new persisted field.

There is **no** general "session id → role" wrapper beyond `upRecordFor`
(confirmed by search); callers read `.role` off its result.

### 2.3 Messages

- `lib-hier.mjs:213-269` — `createMessage`. Frontmatter written:
  `id, type, to, from, slug, parent, reason, to_name, from_name, team, created`.
  `parent` is already there (`opts.parent || null`).
- `lib-hier.mjs:122-124` — filename `${id}--${to}--${slug}--${type}.md`.
- `lib-hier.mjs:53` — `msgsDir(dir) => join(dir, "msgs")`.
- `lib-hier.mjs:272-283` — `listExchanges(dir)` returns
  `{id, request, response, open, to, slug}`, newest-first, **pairing a request
  and its response by shared `id`**. A response is therefore *not* a child via
  `parent`; it reuses the request's id.
- `hooks/msg.mjs:128-145` — the `new` subcommand; `:138` passes `parent`
  through. `:147-166` — the `list` subcommand.
- `pretooluse-route-gate.mjs:377-379` — `extractMsgToken(text)` and
  `readMsgFile(path)` already parse a msg path out of prose and read its
  frontmatter. **Reuse both**; do not write a second parser.

### 2.4 Gate ledger

- `lib-hier.mjs:381-383` `appendGate(dir, rec)`, `:385-387` `hasGate(dir, pred)`,
  `:57` `gatesPath(dir) => join(dir, "gates.jsonl")`. Append-only JSONL.

### 2.5 The constraint that shapes bug 1

**There is no programmatic cross-session send anywhere in this plugin.**
`posttooluse-peer-resolve.mjs:37` *observes* `SendMessage` after the fact; no
code initiates one. A "notify the Orchestrator" design that assumes a push
channel would have to invent transport. §5 does not.

---

## 3. Bug 2 — the route gate becomes orchestrator-only

### 3.1 The self-role predicate

Add to `pretooluse-route-gate.mjs`, after `dir` is available (`:263`):

```js
// The route question is the Orchestrator's to answer. A session running as a
// dispatched subordinate role must resolve routing without a human in the loop
// — it is executing someone else's brief, and the human it would interrupt is
// not the one who chose to dispatch it.
const selfRole = (upRecordFor(dir, sessionId) || {}).role || null;
const isSubordinateSession = selfRole !== null && selfRole !== "orchestrator";
```

Import `upRecordFor` from `lib-hier.mjs` alongside the existing imports.

Semantics, stated exhaustively so the Implementor does not have to infer them:

| `upRecordFor(...).role` | Session is | `isSubordinateSession` |
|---|---|---|
| no record at all | a plain session with no `--agent` flag — the ordinary Orchestrator | `false` |
| `"orchestrator"` | explicitly launched `--agent ah:orchestrator` | `false` |
| any other role | a dispatched subordinate (architect, implementor, reviewer, ultra-advisor, task-runner) | `true` |

**The absent-record case must resolve to `false` (Orchestrator).** That is the
common case — most Orchestrators are plain sessions — and getting it backwards
would silently disable the gate for everybody. Write the predicate as
"non-null and not orchestrator", never as "is in some list of subordinate
roles"; a role added to `ROLES` later must default to *subordinate*, because a
new role is far more likely to be a dispatch target than a second orchestrator.

Do **not** use `PEER_ELIGIBLE_ROLES` for this test. It omits `task-runner`, and
it is semantically a list of who can be dispatched *to*, not who is acting.

### 3.1.1 The `__nosession__` sentinel — do NOT "fix" this

`pretooluse-route-gate.mjs:260` carries a `"__nosession__"` sentinel for the
case where the hook input has no session id:

    resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined })

Meanwhile `sessionstart.mjs:90-100` writes `session_id: input.session_id || null`
— i.e. `null`, not the sentinel, for that same case.

So when no session id exists, `upRecordFor`'s `r.session_id === sessionId`
evaluates `null === "__nosession__"` ⇒ no match ⇒ `selfRole` is null ⇒ the
session is treated as an Orchestrator ⇒ the route gate fires, exactly as it does
today.

**That is the intended behaviour and it must not be "repaired".** The two
representations disagreeing is what produces the safe outcome. Making them
match — coercing `null` and `"__nosession__"` to be equal on either side — would
cause every session lacking a session id to adopt whatever role sits in the
earliest null-keyed peers.jsonl record, silently suppressing the route gate for
real Orchestrators. The failure would be invisible: no error, no test failure,
just a gate that stopped asking.

The degradation direction is load-bearing, the same way §12.3 of spec 0025's
`realCwd` is: an unresolvable self-identity must produce "I am the Orchestrator,
ask the question", never "I am some subordinate, stay silent". Asking a question
that turns out to be unnecessary costs one prompt; skipping one that was
necessary routes work wrongly with no signal.

### 3.1.2 `latestRoster` drops unidentifiable records — this is correct

`lib-hier.mjs:524-533`:

    function rosterKey(rec) { return rec.name || rec.session_id || ""; }
    export function latestRoster(dir) {
      const byKey = new Map();
      for (const rec of readRoster(dir)) {
        const key = rosterKey(rec);
        if (key) byKey.set(key, rec);
      }
      return [...byKey.values()];
    }

A record with no `name` and `session_id: null` yields `rosterKey === ""`, and
`if (key)` drops it. Such a record therefore never reaches `upRecordFor`'s own
filter.

**Do NOT "fix" this.** A record naming neither a peer nor a session is
unidentifiable, and an unidentifiable record must match nobody. Allowing `""` as
a map key would collide every such record from every session into one slot
(last write wins), and `upRecordFor`'s `r.session_id === sessionId` filter would
then match `null` to `null` — letting one session adopt a different session's
recorded role. That is strictly worse than dropping it.

Same degradation-direction principle as §4.2's termination rule and spec
0025 §12.3's `realCwd`: an unresolvable identity must produce a refusal, never
a fabricated match.

**Consequence for testing.** `selfRole` is unresolvable for a no-session-id
record via TWO independent mechanisms — this one, and §3.1.1's sentinel-vs-null
mismatch between a missing `session_id` in the hook input (held as the
`"__nosession__"` sentinel) and a peers.jsonl record's `session_id: null`.
Each masks the other, so neither can be neutralised alone to make the
combined outcome flip. §6 items 8a, 8b and 8c are split along exactly that line: 8a asserts the
combined outcome, 8b falsifiably pins this mechanism, and 8c falsifiably pins
§3.1.1's — using a NAMED record with `session_id: null`, which survives this
drop and therefore isolates the sentinel mismatch on its own.

Discovered by the Implementor while attempting to prove item 8a catches a
regression — the attempt failed, and the failure was the finding. That is the
attempt working as intended, not a wasted step.

### 3.2 Suppress the route-ask

At `:309-315`, the ask is currently gated only on the route being unresolved.
Add the session-role condition:

```js
if (routeInfo.source !== "session" && !configRoute && !isSubordinateSession) {
  ...existing appendGate + decide("deny", askReason(...))...
}
```

Do not delete the block and do not change what it asks. The gate's purpose —
letting an Orchestrator choose peer vs subagent routing — is untouched; only
*when it is allowed to fire* narrows. This is the constraint from the dispatch
and it is deliberate.

### 3.3 The route a subordinate resolves to

With the ask suppressed, a subordinate session needs a deterministic route.

**Decision: `resolved.route` when config sets one, otherwise `prefer-peers`.**

Config already wins today (`:307`, `:309` — the ask only fires when
`!configRoute`), so this is only about the unset case. Implement as:

```js
const routeInfo = effectiveRoute(dir, resolved, sessionId);
const route = isSubordinateSession && routeInfo.source !== "session" && !configRoute
  ? "prefer-peers"
  : routeInfo.value;
```

placed so that the existing `const route = routeInfo.value;` at `:316` is
replaced by this. Everything downstream of `:316` already reads `route` and
needs no other change.

**Rationale — why `prefer-peers` and not `peers`.** The dispatch suggested
"peers, when live peers exist for the target role". `prefer-peers` *is* that
rule, and it is already implemented at `:360-365`: if a free live peer exists,
deny and redirect to it; otherwise fall through and allow the subagent. Crucially
the `prefer-peers` branch **contains no interactive ask at all**, whereas the
`peers` branch contains two (`:344-348`, `:353-357`). Choosing `prefer-peers`
therefore satisfies the requirement using a code path that already exists and
cannot interrupt a human. Choosing `peers` would satisfy the same routing
preference but re-introduce the exact class of interruption this spec exists to
remove.

Note the one behavioural difference the Orchestrator should be aware of:
`prefer-peers` skips a peer that is *busy* (`:361` filters `!i.busy`) and spawns
a subagent instead, where `peers` would redirect to it regardless. For a
subordinate doing evidence-gathering on a deadline this is the better default —
but it is a real difference, not a no-op, and it is called out here rather than
buried.

### 3.4 The residual asks under an explicit `route: "peers"` config

If a repo's `.claude/agent-hierarchy.json` sets `route: "peers"`, a subordinate
session lands in the `peers` branch and can still hit **peer-fallback-ask**
(`:353-357`) or **on-missing-auto** (`:344-348`). Both interrupt the user. Both
must be suppressed for a subordinate:

- `:344-348` — wrap the `if (!askedAuto)` block so a subordinate skips straight
  to the existing `decide(null, null, ...)` that spawns the subagent. Adjust the
  narration string to say the ask was skipped because this is a subordinate
  session, not because the user was already asked — a false explanation in a
  hook message is worse than none.
- `:353-357` — same: a subordinate skips the ask and falls through to the
  existing `decide(null, ...)` at `:358`, again with corrected narration.

Do not touch the non-interactive `policy === "never"` path at `:335-337`; it
already decides without asking.

### 3.5 What must NOT change

- The global-scope confirm gates at `:294-303` (spec 0009 §4) keep firing in
  every session, subordinate included. They are a **scope/permission**
  confirmation, not routing plumbing, and the dispatch's constraint was scoped
  to the route decision. Suppressing a permission confirmation because the
  session is subordinate would let a dispatched role reach global scope without
  the confirmation an Orchestrator would have had to give — that is precisely
  the escalation shape the hierarchy forbids.
  **Flagging this as a decision I made, not one the dispatch settled.** If the
  Orchestrator wants those suppressed too, that is a separate and more
  security-sensitive change, and I would want it escalated rather than folded in
  here.
- The tier gate at `:370+`. Untouched.
- `route-deny` / `subagentsDenyReason` behaviour for an Orchestrator session:
  byte-identical.
- The three `askReason` builders. Not edited, only conditionally reached.

### 3.6 Known limitation, stated not fixed

A **subagent** inherits its parent's `session_id`, so `upRecordFor` resolves to
the *parent's* role. A subagent of an Orchestrator is therefore treated as an
Orchestrator and can still trip the ask. This is the status quo, it is not what
was reported, and fixing it needs a subagent-detection signal in PreToolUse
input that has not been verified to exist (see **E-2**). Out of scope; recorded
so a future reader does not mistake it for an oversight.

---

## 4. Bug 1 — surfacing downstream dispatches

### 4.1 Definitions

**Root requester.** Given message `M`, walk `parent` upward until reaching a
message with `parent: null`. That message is `root(M)`; its `from` / `from_name`
identify the originating session. A message with `parent: null` is its own root.

**Downstream dispatch.** `M` is a downstream dispatch iff all hold:
1. `M.type === "request"` — responses reuse the request's id and are paired by
   `listExchanges` (`lib-hier.mjs:272-283`), so they are never children and must
   never be reported as downstream dispatches.
2. `M.parent` is non-null and resolves to an existing message.
3. `root(M)` and `M` were created by *confirmably different* senders — see the
   sender-identity rule below. Note this is NOT `root(M).from_name !==
   M.from_name`, which is what this spec said before 2026-08-28 and what the
   first implementation encoded.

Condition 3 is what makes this "downstream" rather than merely "a follow-up":
an Orchestrator sending a second request parented to its own first request is
not a downstream dispatch and must not be reported as one.

**Sender-identity rule (amendment, 2026-08-28).** `from_name` is OPTIONAL:
`msg.mjs:147-148` defaults it to null and `lib-hier.mjs:240-241` writes
`opts.fromName || null`. A bare `!==` therefore reads absence as a value, and
gets both directions wrong — two unnamed senders compare *equal* and the
dispatch is silently dropped.

Suppress a row only on a CONFIRMED same-sender match:
  - Both `from_name`s present → compare them. Names are authoritative.
  - Otherwise → compare `from` (the role), which is always present.

Emit when the comparison does not confirm sameness. This deliberately inverts
§3.1.2's refuse-on-unresolvable rule: §3.1.2 guards a GATE, where a false match
grants something; this is a MONITOR, where a false negative hides the very thing
being surfaced. Unconfirmed ⇒ surface and mark, never hide.

**Known residual.** Two DIFFERENT sessions of the SAME role, neither stamping
`from_name`, still compare equal and emit no row. This cannot be closed without
either resolving E-3 (senders stamp `from_name`) or adding `session_id` to
message frontmatter. Do not attempt to close it with a roster lookup keyed on
role — role is not unique, and that fabricates an identity. Reopen this when
E-3 lands or frontmatter gains `session_id`; either makes the fix safe and
small.

Worked example, the reported case:

```
R  parent=null  from_name=bear-poppa-promo-3b  to=ultra-advisor
D  parent=R.id  from_name=bps-ultra-advisor    to=implementor   (20260828-090433-17t8)
root(D) = R;  R.from_name ("bear-poppa-promo-3b") != D.from_name ("bps-ultra-advisor")
⇒ D is a downstream dispatch whose root requester is bear-poppa-promo-3b.
```

### 4.2 New library function

Add to `lib-hier.mjs`, beside `listExchanges`:

```js
/**
 * Downstream dispatches: requests created by a session other than the one that
 * rooted their parent chain. Derived entirely from existing frontmatter — no
 * new persisted field.
 * Returns newest-first: { id, parent, root_id, root_from, root_from_name,
 *                         from, from_name, to, to_name, slug, created }
 */
export function listDownstreamDispatches(dir) { ... }
```

Requirements:

- Build an `id → frontmatter` index once from `msgsDir(dir)`. Reuse the existing
  frontmatter reader (`readMsgFile`) rather than adding a second parser.
- Index requests only when resolving `parent` (a `parent` id could otherwise
  match a response file sharing that id).
- **Termination rule (amendment, 2026-08-28).** The walk yields a root ONLY by
  reaching a message with `parent: null` within the hop cap. It returns nothing
  in every other case:
  - a cycle (an id revisited — track with a `seen` Set),
  - the hop cap exhausted (cap at 32),
  - a `parent` naming an id with no request file.

  A message whose walk returns nothing is **not** a downstream dispatch and
  emits no row. Do not guess a root, do not partially attribute, do not error —
  a partially-cleaned or hand-edited msgs dir is normal and must not produce a
  hook failure.

  Correction: an earlier draft of this section said a cycle should "stop and
  treat the last non-repeating message as the root", while the bullet directly
  above it degraded a missing parent to no row. Those are opposite degradation
  directions three lines apart, and the cycle one was wrong.

  The reason is not merely consistency. Condition 3 of §4.1 tests
  `root(M).from_name !== M.from_name`. If the root is a guess, condition 3's
  answer is a guess — and a row is a positive claim that one named session
  dispatched work downstream on another named session's behalf. A wrong row
  mis-attributes work to an Orchestrator that never requested it. In a feature
  whose entire purpose is visibility, a false line is strictly worse than a
  missing one: the missing line leaves the reader where they already were, the
  false line sends them somewhere wrong with confidence. Same degradation-
  direction principle as spec 0025 §12.3's `realCwd` — an unresolvable input
  must produce a refusal, never a fabricated match.

  Note the hop cap is covered by this rule deliberately, not incidentally. A
  chain deeper than the cap terminates without reaching `parent: null` and is
  therefore rootless for exactly the same reason a cycle is; treating it any
  other way would reintroduce the same defect behind a rarer trigger.
- Sort newest-first, consistent with `listExchanges`.
- **Condition 2 must be checked explicitly.** The first implementation elided it
  (`lib-hier.mjs:324-325`: "a parentless message roots itself... no separate
  'has a parent' check needed") and let name-equality exclude parentless
  messages instead.

  That worked because `rootOf` returns the message's own frontmatter object for
  a parentless message, so ANY sender comparison — the old `!==` or the new
  `sameSender` — is reflexive and excludes it. The exclusion is correct but
  emergent: it depends on an object-identity property of `rootOf` that nothing
  states or tests, rather than on the condition the spec actually specifies.

  Check condition 2 explicitly anyway. This is a clarity and durability change,
  NOT a bug fix: it makes the spec's stated condition the reason the behaviour
  holds, and it survives a `rootOf` that stops self-referencing. It changes no
  output today and is safe to land independently of the sender-identity change.
  (Corrected 2026-08-28: an earlier revision of this bullet claimed the two
  changes were coupled and that splitting them caused false positives. That was
  wrong — see item 10a.)

- Rows carry an `identity` field, `"name"` or `"role-only"`, recording which
  comparison decided the row. `msg.mjs` marks role-only rows in its output so a
  reader can tell a confirmed cross-session dispatch from an inferred one.

```js
for (const [id, fm] of byId) {
  if (!fm.parent) continue;                          // §4.1 condition 2, explicit
  const root = rootOf(byId, id);
  if (!root || root.id === id) continue;             // unresolvable, or self-rooted
  if (sameSender(root.fm, fm)) continue;             // §4.1 condition 3
  out.push({ ..., identity: bothNamed(root.fm, fm) ? "name" : "role-only" });
}

// `from_name` is optional (msg.mjs:147-148), so absence must never read as a
// value. Confirm sameness on names when both are present; otherwise fall back
// to the always-present role. Unconfirmed sameness is not sameness.
function bothNamed(a, b) { return Boolean(a.from_name && b.from_name); }
function sameSender(a, b) {
  return bothNamed(a, b) ? a.from_name === b.from_name : a.from === b.from;
}
```
`root.id === id` is belt-and-braces given the explicit parent check above; keep it — a cycle is the one other way a message can resolve to itself.

Note the `{ ..., identity: ... }` object literal above is illustrative — preserve every other existing field on the emitted row (id/parent/root_id/root_from/root_from_name/from/from_name/to/to_name/slug/created per the original §4.2 spec), just add `identity`.

This function is pure and read-only. It adds no writes, no frontmatter fields,
and no state, which is what the dispatch's constraint asked for.

### 4.3 Surfacing (the actual fix)

`hooks/msg.mjs` gains a `downstream` subcommand, and the `list` subcommand
(`:147-166`) gains a downstream section.

- `msg.mjs downstream [--root-name <name>]` — prints one line per downstream
  dispatch, newest-first:
  ```
  <root_from_name> → <from_name> → <to>: <slug>  (id <id>, parent <parent>)
  ```
  matching the shape the dispatch asked for
  (`"ultra-advisor → implementor: <slug>, parent <id>"`), with the root
  requester prefixed so the reader can tell at a glance whether a row is theirs.
- `--root-name` filters to rows whose `root_from_name` equals the argument.
- `msg.mjs list` appends a `downstream:` section when
  `listDownstreamDispatches(dir)` is non-empty, and prints nothing extra when it
  is empty. **No empty-section header** — a permanently-present empty heading
  trains readers to skip the region where the signal will eventually appear.

Expose the same data through the MCP surface as `msg_list`'s output (and/or a
`msg_downstream` tool) so an Orchestrator using MCP rather than the CLI sees it
too. `mcp/server.mjs` already wraps msg.mjs subcommands; follow the existing
pattern there rather than inventing a new one.

### 4.4 Protocol requirement (docs, not code)

Add one line to the role contracts for any role that may dispatch further work
(Ultra-Advisor and Architect at minimum), in the same file(s) that carry their
existing "report back compactly" instruction:

> If you dispatched a downstream peer while executing this brief, name it in
> your report: the role, the slug, and the msg id.

This is the cheapest part of the fix and the one that would have prevented the
reported surprise outright, because it delivers the fact on the path the
Orchestrator is already reading. It complements §4.3 rather than replacing it:
prose can be forgotten, the derived view cannot.

### 4.5 Rejected alternatives, with reasons

- **Push a notification to the root requester's session.** No programmatic
  cross-session send exists (§2.5), so this means inventing transport. Deferred,
  and blocked on **E-3** regardless.
- **Auto-create a notice *message file* addressed to the root requester.** This
  is writes-for-nothing: the Orchestrator still only sees it by looking at its
  msgs, which is exactly what §4.3 already gives it — but §4.3 costs no files,
  cannot go stale, and works retroactively on chains that already exist.
- **Add a `root_requester` frontmatter field at create time.** Denormalises data
  that is already derivable, and would be wrong for every message already on
  disk. The dispatch's own constraint rules it out and I agree with it.

---

## 5. NEEDS-EVIDENCE

I cannot run anything. Each item below states exactly what to check and what
each outcome decides. **E-1 and E-2 gate bug 2's implementation**; E-3 and E-4
do not block anything in §3 or §4.

- **E-1 — does `ROLES` in `lib-config.mjs` include `"orchestrator"`?**
  RESOLVED 2026-08-28 (Orchestrator). `ROLES` (lib-config.mjs:68) =
  ["ultra-advisor","architect","reviewer","implementor","task-runner"] — no
  "orchestrator". A session launched `--agent ah:orchestrator` therefore resolves
  `hierarchyRoleOf(...)` to null at sessionstart.mjs:83, writes no peers.jsonl
  record, and lands in §3.1's absent-record row ⇒ Orchestrator. Correct outcome,
  reached by the absent-record path rather than the `!== "orchestrator"` clause.

  The clause is dead code today. KEEP IT. If "orchestrator" is ever added to
  `ROLES`, removing the clause would flip explicitly-launched Orchestrators to
  subordinate and disable the route gate for them with no test failing.

- **E-2 — does PreToolUse hook input carry the same `session_id` that
  `sessionstart.mjs` wrote to `peers.jsonl`, for a top-level `--agent` peer
  session?**
  RESOLVED 2026-08-28 (Orchestrator). sessionstart.mjs:90-100 writes
  `session_id: input.session_id || null`; pretooluse-route-gate.mjs:259 reads
  `input.session_id`; upRecordFor (lib-hier.mjs:480-482) matches
  `r.session_id === sessionId`. All three read the identical field off the
  identical PreToolUse hook-input object within one session — no separate or
  derived value anywhere in the chain. The approach is sound.

  Also confirmed: PreToolUse input carries NO `agent_type` field. §3.1 stays on
  `upRecordFor`; the agent_type shortcut floated in the original E-2 is not
  available.

  See §3.1.1 for the one consequence this resolution surfaces.

- **E-3 — how does a session learn its own instance name (its `from_name`)?**
  Needed only for a future push notification (§4.5), and for `msg.mjs downstream`
  to default `--root-name` to "me" instead of requiring it. Nothing in §3 or §4
  is blocked by this. If no mechanism exists, `--root-name` stays explicit and
  that is acceptable.

- **E-4 — confirm no existing message sets `parent` to a *response* id.**
  Since responses reuse the request id, a `parent` pointing at a response is
  indistinguishable from one pointing at its request, and §4.2 resolves it to the
  request. Scan the existing `msgs/` dirs for any `parent` value that has a
  response file but no request file.
  - If none: §4.2's "index requests only" rule is safe as written.
  - If some exist: §4.2 needs a documented tie-break, and I should be
    re-dispatched to write it.

---

## 6. Verification

Bug 2 — `pretooluse-route-gate.mjs`. Each item asserts the *exact* decision, not
merely that something was allowed:

1. Plain session (no peers.jsonl "up" record for its session id), route unset in
   config and session → the route-ask fires exactly as it does today. **This is
   the regression that matters most**; the gate must be unchanged for the common
   Orchestrator case.
2. Session with an "up" record of `role: "orchestrator"`, same conditions → the
   route-ask fires.
3. Session with an "up" record of `role: "ultra-advisor"`, same conditions → the
   route-ask does **not** fire, no `route-ask` gate record is appended, and the
   effective route is `prefer-peers`.
4. Same as 3 with a free live peer for the target role → decision is `deny` with
   the existing `preferPeersDenyReason` (redirect to the peer), and no
   AskUserQuestion.
5. Same as 3 with no live peer for the target role → decision is allow (spawn
   the subagent), and no gate record of type `peer-fallback-ask` or
   `on-missing-auto` is appended.
6. Subordinate session with config `route: "peers"` and no live peer, on-missing
   policy `prompt` → allow, no `peer-fallback-ask` record. (§3.4)
7. Subordinate session with config `route: "peers"`, no live peer, on-missing
   policy `auto` → allow, no `on-missing-auto` record. (§3.4)
8. Subordinate session, `resolved.rosterLevel === "global"` → the global-scope
   confirm gate at `:294-303` **still fires**. (§3.5 — this is the assertion
   that stops a later "simplification" from widening the suppression into a
   permission bypass.)
8a. Unresolvable self-identity ⇒ gate fires. With a peers.jsonl "up" record
    carrying `session_id: null`, `role: "implementor"`, and NO `name` field (the
    exact shape sessionstart.mjs:90-100 writes when `input.session_id` is
    falsy), `selfRole` resolves to null, the session is treated as an
    Orchestrator, and the route-ask FIRES.

    This is an OUTCOME assertion, and it is deliberately guaranteed by two
    independent mechanisms — see §3.1.2. Neither can be neutralised in isolation
    to make this test fail, so do NOT attempt to prove it fails by breaking one;
    that attempt is what surfaced §3.1.2 in the first place. Its value is as a
    regression guard on the combined outcome. Each underlying mechanism gets its
    own falsifiable test: §3.1.2's drop is
    item 8b and §3.1.1's sentinel mismatch is item 8c. 8a asserts the outcome
    that must survive either mechanism being changed.
8b. `latestRoster` drops unidentifiable records (unit-level, falsifiable). A
    peers.jsonl containing exactly one record with no `name` and
    `session_id: null` → `latestRoster(dir)` returns `[]`.

    This test pins §3.1.2's rule directly and WILL fail if `rosterKey`'s
    truthiness check is relaxed. It is the falsifiable half that 8a cannot be.
8c. §3.1.1's sentinel/null mismatch, isolated (unit-level, falsifiable).
    peers.jsonl containing exactly one record:
      {"type":"peer","status":"up","name":"anything","session_id":null,
       "role":"implementor"}
    → `upRecordFor(dir, "__nosession__") === null`.

    The record is NAMED, so `rosterKey` is truthy and `latestRoster` keeps it —
    §3.1.2's drop is deliberately taken out of the picture, leaving the
    sentinel/null mismatch as the only thing that can prevent a match. This
    test WILL fail if `"__nosession__"` is ever coerced to null (or vice versa)
    at any point on the resolution path.

    8b and 8c together are the falsifiable halves of 8a: 8b pins the drop, 8c
    pins the sentinel mismatch, 8a asserts the combined outcome that survives
    either one being changed.

Bug 1 — `listDownstreamDispatches`:

9.  Fixture reproducing §4.1's worked example → exactly one row, with
    `root_from_name` equal to the orchestrator's name and `from_name` equal to
    the ultra-advisor's.
10. An Orchestrator's own follow-up request parented to its own earlier request
    (same `from_name` as the root) → **zero rows**.
10a. Parentless request, NO `from_name` → zero rows.

     OUTCOME assertion, not falsifiable against the current implementation.
     Three independent mechanisms each guarantee it today: the explicit
     `if (!fm.parent) continue`, the `root.id === id` guard, and — underneath
     both — `rootOf` returning the message's OWN frontmatter object for a
     parentless message, which makes any sender comparison reflexively true.
     Do NOT attempt to prove this test fails by reverting the comparator; it
     will not, and that attempt is what produced this correction.

     Its value is as a guard on a FUTURE change: if `rootOf` is ever altered to
     return a copy or a distinct object for a parentless message, reflexivity
     disappears and the explicit condition-2 check becomes the only thing
     excluding these rows. Item 10e pins that dependency directly.
10b. Root unnamed, descendant named, different roles → exactly one row, with
     `root_from_name: null`, `root_from` set to the root's role, and
     `identity: "role-only"`. The live-verified case; asserts a null name is
     displayed, not treated as an error.
10c. Root unnamed AND descendant unnamed, different roles → exactly one row,
     `identity: "role-only"`. **This is the false negative being closed** — the
     pre-amendment implementation returns zero rows here. The regression test
     that matters most for item A.
10d. Root unnamed AND descendant unnamed, SAME role → zero rows. Pins §4.1's
     known residual as a deliberate, documented limitation rather than an
     untested edge. If this item ever starts failing, E-3 or a frontmatter
     `session_id` has landed and §4.1's residual paragraph should be revisited.

     Items 9 and 10 (existing) are unaffected in outcome but now pass for the
     right reason (item 10's fixture stamps the same name on both sides, so the
     name branch decides it, not an accidental null-equality).
10e. `rootOf` self-reference contract (unit-level, falsifiable). For a message
     with `parent: null`, `rootOf(byId, id)` returns an object whose `fm` is the
     SAME REFERENCE as `byId.get(id)`.

     Items 10a and the `root.id === id` guard both silently depend on this. It
     is currently an unstated implementation detail; this test makes it a pinned
     contract, and WILL fail if `rootOf` is changed to return a copy or a
     reconstructed object. That change would be reasonable-looking and would
     silently remove one of 10a's three guarantees, which is precisely why it
     needs a test rather than a comment.
11. A response file sharing an id with a request → zero rows from it.
12. A message whose `parent` names a nonexistent id → zero rows, no throw.
13. A hand-made cycle (A.parent=B, B.parent=A) → zero rows, no throw, and the
    call returns. Assert termination explicitly, not just the row count.
13a. Cycle fixture requirements. Item 13's fixture MUST give the two cycle
     members DIFFERENT `from_name` values. With equal names, §4.1 condition 3
     fails on name equality and the walk's cycle behaviour is never exercised —
     the test passes on a weaker property than the one it states. Assert zero
     rows AND that the call returned (a hang and a zero-row result are not
     distinguishable by row count alone).
13b. Depth-cap fixture. A parent chain longer than the 32-hop cap, with a
     `from_name` on the deepest message differing from the head's, → zero rows.
     Without this, the cap's termination path is untested and can silently
     regress to emitting a guessed root.
14. Empty `msgs/` dir → empty array, and `msg.mjs list` prints no `downstream:`
    header.

---

## 7. Confidence and escalation

- **Bug 2, §3.1–§3.4: high confidence.** The primitive (`upRecordFor`) already
  exists, the target route (`prefer-peers`) is an already-implemented code path,
  and the change is three conditions plus two narration strings.
- **Bug 2, §3.5 (global-scope gates keep firing): my call, and the one thing in
  this spec I would most want a second opinion on.** It is a security-shaped
  decision — suppressing those would let a subordinate reach global scope without
  the confirmation an Orchestrator would have had to give. I chose the
  conservative side, but if the reported interruption was in fact a global-scope
  gate rather than the route-ask, this spec addresses the wrong prompt and the
  question should go to the Ultra-Advisor. The bug report names the
  peers/prefer-peers/subagents question specifically, which is why I read it as
  the route-ask.
- **Bug 1, §4: high confidence in the derivation, moderate in the surfacing
  being sufficient.** A derived view only helps an Orchestrator who looks. I
  believe §4.4's protocol line is what actually closes the reported gap in
  practice, and §4.3 is what makes it durable. If the Orchestrator wants a true
  push, that is a separate spec gated on **E-3**, and I would rather write it
  properly than bolt a transport onto this one.
