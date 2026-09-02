# Spec 0031 — SendMessage response-header nudge

Status: **r4** · Author: Architect · Requests: `20260901-222748-9qln`,
`20260901-224231-rh02`, `20260901-233158-1kcf`

**Revision log**

- **r2** — replaced r1's disk-scan trigger with `pendingFor(sessionId)`. r1's version was
  session-blind: stale requests would arm the gate permanently and two sessions sharing a
  role would cross-fire.
- **r3** — Ultra-Advisor review (`rh02`). **Fix D** invalidated r2's premise: `pendingFor`
  is never populated for the dispatches this gate exists to catch. Plus **E** (§9.4
  reworded) and **F** (`validateResponseToken` must match the id). Added §4.1a, a
  consequence of D the ruling did not flag.
- **r4** — Implementor found a real defect in r3's §3 (`1kcf`). `armed_by` never reaches
  the **persisted** record, so §4.1a's guard was inert on the only path that matters.
  §3 corrected: `userpromptsubmit-peer-tracking.mjs` **does** need a one-line change.
  §3.1 explains why explicit propagation and not a spread. Also confirms the two failing
  tests were correct and the code was wrong.

## [0] tldr

- New hook `pretooluse-sendmessage-response.mjs` on `PreToolUse`/`SendMessage`, mirroring
  the existing gate's polarity: that one covers **the Orchestrator dispatching**, this one
  covers **a subordinate role responding**. §2.
- Trigger is `pendingFor(session_id)`, which only works after **Fix D** widens what arms a
  pending record (§4.1) **and** r4's one-line propagation fix (§3.1).
- Fix D's consequences reach three consumers; the `stop-orchestrator-liveness.mjs` guard
  in §4.1a is required, not optional.
- One-round nudge keyed on the request id. Fail-open on every error path.

---

## [1] Goal

A subordinate hierarchy role answering a message-file request must deliver its answer as a
response **file**, and must name that file in the `SendMessage` reporting it. When it
doesn't, nudge once with the exact command, then get out of the way.

The motivating failure is concrete: the Architect answered `ala6` and `bioz` inline over
`SendMessage`. `stop-orchestrator-liveness.mjs` clears an outstanding dispatch only on a
matching response file, so it re-flagged both as stale on every Stop.

## [2] Why a new hook, and why `pretooluse-msg-gate.mjs` must not be extended

Two guards keep the existing gate away from this case, both load-bearing:

| Line | Guard | Why it exists |
|---|---|---|
| `:53-56` | `if (callerDirect && callerRole) decide(null)` — a positively-attributed subordinate role is exempt | Spec 0028 §3.2. The gate is about the **Orchestrator dispatching**; role agents never spawn gated roles. |
| `:74` | `if (!parseSentinel(text)) decide(null)` | Header comment `:13-14`: "pings / chat / replies" are deliberately exempt. `parseSentinel` matches only `[hierarchy-peer-brief reply-to="..."]` (`lib-peer.mjs:40`). |

**Do not relax either.** `:55`'s rationale is sound for dispatch and irrelevant for
response, but one line cannot express both polarities without a deny text that has to
guess which case it is in. `:74` is worse: the absence of a token is the bug, so a gate
keyed on a token's presence can never catch it.

Second hook, opposite polarity. Both register on `PreToolUse`/`SendMessage`; hooks compose
and the first deny wins.

**Out of scope:** the receiver-side no-Write gap for Ultra-Advisor and Reviewer (spec 0028
§3.6). Those roles *cannot* write a response file, so this gate must never fire for them
(§4 condition 4).

## [3] Files

| Path | Change |
|---|---|
| `agent-hierarchy/hooks/lib-peer.mjs` | **Fix D.** Widen `extractPendingRecord` (`:96-119`). §4.1. |
| `agent-hierarchy/hooks/userpromptsubmit-peer-tracking.mjs` | **r4 — one line.** Add `armed_by: rec.armed_by` to the `appendPeerRecord` call (`:52-61`). §3.1. |
| `agent-hierarchy/hooks/stop-orchestrator-liveness.mjs` | **Consequence of D.** Guard the `:107` cede check. §4.1a. |
| `agent-hierarchy/hooks/pretooluse-sendmessage-response.mjs` | New. §4–§6. |
| `agent-hierarchy/hooks/hooks.json` | New `PreToolUse` entry, `matcher: "SendMessage"`, **alongside** the existing `pretooluse-msg-gate.mjs` registration. Do not replace it. |
| `agent-hierarchy/hooks/lib-hier.mjs` | Add `validateResponseToken(text, dir, expectedFrom, expectedId)` beside `validateRequestToken` (`:426-437`). §6, Fix F. |
| `agent-hierarchy/tests/test-sendmessage-response-nudge.sh` | New. §8. |
| `agent-hierarchy/.claude-plugin/plugin.json` + root `.claude-plugin/marketplace.json` | Version bump, both files. |

`pretooluse-msg-gate.mjs` and `posttooluse-peer-resolve.mjs` are unchanged.

### 3.1 r4 — `armed_by` must be propagated explicitly

> **r3's §3 was wrong, and the Implementor was right to stop.** r3 instructed that
> `userpromptsubmit-peer-tracking.mjs` needed no edit, reasoning that it "already
> populates `msg` from `extractMsgToken` independently." That reasoning is true **about
> `msg`** and says nothing about `armed_by`. The `appendPeerRecord` call at `:52-61`
> builds its object from a **hand-listed field set** — `session_id, from, from_name,
> reply_to, task, msg?, ts, status, nudges` — and silently drops anything else
> `extractPendingRecord` returns. `extractPendingRecord` is called nowhere else, so **no
> persisted pending record would ever carry `armed_by`**, on either arming path. §4.1a's
> guard would read `undefined` for every record and cede on all of them — inert in exactly
> the case it was written to protect.
>
> Fourth instance of one error shape in this thread, and the sharpest: I checked that the
> file propagates the field I was thinking about, and concluded it needed no change,
> without checking whether it propagates the field I was *adding*. **"This call site
> already handles the adjacent case" is not evidence about the new case.**

**The fix (Implementor's option (a), approved):** add `armed_by: rec.armed_by` to that
object literal. One line.

**Explicitly rejected: replacing the hand-listed fields with `...rec`.** A spread would
auto-propagate this and any future field, which looks like the recurrence-proof answer and
is the wrong call here. That literal is a **persistence boundary** — an allowlist deciding
what from an in-memory helper becomes durable state in a store three hooks read. Spreading
makes every future field of `extractPendingRecord`'s return value silently durable,
including ones added for local use with no thought given to on-disk compatibility. Explicit
is correct at a boundary; the cost is remembering to update it.

So that it *is* remembered, the implementation carries a comment on the literal saying the
field set is a deliberate allowlist and a new field on `extractPendingRecord` must be added
here to persist. That is a WHY comment about a non-obvious constraint, not change
narration — it stays correct after this diff merges.

**`armed_by` must never be `undefined`.** §4.1 requires both arming paths to set it
(`"sentinel"` or `"msg-token"`), so `rec.armed_by` is always a string at this call site.
This matters because §4.1a's guard treats a *missing* field as sentinel-armed for legacy
compatibility — if a live path could also produce a missing field, legacy records and
new-path records would be indistinguishable.

**The two failing tests were right and the code was wrong.** Tests 1 and 4 route through
the real pipeline, which is what the spec asks them to do. The Implementor's decision to
verify §4.1a's guard separately by seeding records directly — proving the guard logic
correct while the propagation was broken — is the right way to isolate the two, and is why
this came back as one precise question instead of a rewrite.

## [4] When it fires

Fires **only** when all hold. Evaluate in order; `allow()` on the first failure.

1. `tool_name === "SendMessage"`.
2. Not a subagent context (`isSubagent(input)` → allow). Matches the existing gate `:47`.
3. Hierarchy enabled and `msgs !== "off"` (`resolveConfig`). Matches `:79`.
4. `resolveHierarchyRole(input)` returns `{ role, direct: true }` and `role` is
   `architect` or `implementor` — **not** `reviewer` or `ultra-advisor` (§2), and not the
   Orchestrator.
5. `pendingFor(input.session_id)` returns at least one record carrying a `msg` field.
   Zero → allow.
6. The outgoing `tool_input.message` contains no `[hierarchy-msg ` token at all.
   Present-but-invalid is handled at §6.

The request path named in the deny text is the pending record's `msg` value.

### 4.1 Fix D — the trigger does not fire without widening what arms a pending record

**r2's premise was false.** r2 verified that `pendingFor` exists (`lib-peer.mjs:169-171`)
and what its records contain. It did not verify that such a record is ever written for the
dispatches this gate exists to catch. It is not.

`extractPendingRecord` (`:96-119`) arms only when `SENTINEL_RE` —
`[hierarchy-peer-brief reply-to="..."]` — **anchors the first non-blank line after the
`<cross-session-message>` wrapper** (`:108-110`, `if (!m || m.index !== 0) return null`).
Orchestrator dispatches carry `[hierarchy-msg <path>]` on that line. The Orchestrator
confirmed by grepping the peer-pending store: for `ala6` and `bioz` only send-side
`"type":"dispatch"` records exist, and no receiver-side pending record was ever armed.

> **The recurring error, stated once for all four instances.** *(a)* SessionStart
> re-injects open exchanges — true, but the payload is a capped index with no bodies (spec
> 0030 S1). *(b)* The 1a0g record shape — read from a summary, not the artifact (spec 0002
> §3.3). *(c)* `pendingFor` exists and is well-formed — and is never populated on this path
> (§4.1). *(d)* The tracker propagates `msg`, so it needs no edit — but it does not
> propagate `armed_by` (§3.1). **Every one is a true statement standing in for a claim it
> does not support.** Reading the implementation cannot settle these: in (c) and (d) the
> code is correct, and it is the traffic or the field set that does not match. Checking the
> live store is what found both.

**The fix.** Widen `extractPendingRecord` to arm on a second, equally anchored form: the
first non-blank line after the wrapper matches `[hierarchy-msg <path>]` where `<path>`
ends in `--request.md`, `parseMsgFilename(path)` yields `type === "request"`, and the file
exists. Then:

- `reply_to` = the wrapper's `from` (`parseWrapper` `:65-74` already returns it).
- `from` / `from_name` = the wrapper's, as today.
- `task` = the parsed slug.
- `armed_by: "msg-token"` on this path, `armed_by: "sentinel"` on the existing one.
  **Both paths must set it; it is never absent from a live return value** (§3.1).

The sentinel path keeps its current behaviour otherwise. Both remain anchored to the first
non-blank line — an unanchored match would arm on any message that merely quotes a path.

### 4.1a Consequence of Fix D

`pendingFor` has three consumers, not one. Widening what arms a record widens all three:

| Consumer | Effect of D | Verdict |
|---|---|---|
| This gate (§4 condition 5) | Starts working at all | The point of D |
| `stop-peer-nudge.mjs:89` | Now nudges at Stop when a msg-file obligation is unanswered | **Desirable** |
| `stop-orchestrator-liveness.mjs:107` | `if (sessionId && pendingFor(sessionId).length > 0) allow()` — a session owing a peer report stops being held to its **own** outstanding dispatches | **Regression — must be guarded** |

**The `stop-peer-nudge` widening is a benefit.** It gives the same failure a second,
independent enforcement point: the PreToolUse gate catches the moment of the mistake, the
Stop nudge catches the session trying to finish its turn still owing a response file.
Neither depends on the other. Test 15.

**The liveness widening is a regression.** Post-D, any session receiving a msg-file
request — including an Orchestrator receiving one addressed to `orchestrator` — arms a
pending record and stops being nudged about dispatches *it* has outstanding, silently
suppressing the mechanism this thread exists to repair.

**Guard:** `:107`'s cede check counts only records with `armed_by !== "msg-token"`. A
missing `armed_by` (every record written before this change) must be treated as
sentinel-armed, so legacy behaviour is bit-for-bit unchanged. Test 16.

Per §3.1 this guard is only meaningful once `armed_by` actually reaches disk — the r4 fix
and this guard are one unit and must land together.

### 4.2 Why not a content heuristic

A `PreToolUse` hook sees only `to` and `message`, never intent, so any rule reading the
message body to guess "is this a response?" is a heuristic on free text that misfires both
ways. Condition 5 replaces the guess with recorded state. The recipient's identity is
useless for the same reason: responses and pings go to the same peer.

### 4.3 Known false positive, accepted and mitigated

A subordinate role sending a genuine mid-task status ping *while holding a live
obligation* satisfies every condition and gets nudged once. Real, not theoretical.

Accepted because the one-round nudge makes it **recoverable in one retry**. This is the
actual justification for nudge-over-block: a hard block on a predicate with a known
false-positive class would strand a session that has done nothing wrong, and a subordinate
role cannot escalate — the conduit gate denies `AskUserQuestion` to every non-Orchestrator
role (`pretooluse-conduit-gate.mjs:31`).

The nudge text must say plainly that a status ping is a legitimate reason to re-send
unchanged. §6.

## [5] One-round nudge mechanics

Mirror `subagentstop-msg-nudge.mjs:106-116`, including what that revision learned the hard
way (0028 §4.3 r4, finding 2): the second pass **records** rather than silently allowing.

Keyed on the **request id** parsed from the pending record's `msg` path:

1. If `hasGate(dir, r => r.type === "send-nudge" && r.id === requestId)` → append
   `{ type: "send-nudge-unmet", id: requestId }` and **allow**.
2. Otherwise append `{ type: "send-nudge", id: requestId, session_id }` and **deny** with
   §6's text.

With more than one qualifying pending record, key on the **oldest** and name all of them
in the deny text.

**The hook writes nothing to the peer-record store.** `appendPeerRecord` is owned by the
tracker, the resolver, and `stop-peer-nudge`. Nudge state goes to the gate store
(`hasGate`/`appendGate`), a different file. Test 14 asserts byte-identity.

## [6] Deny text and `validateResponseToken`

The deny must contain, in order:

1. What was blocked, and that it did not send.
2. The open request id(s) this session has not answered.
3. The exact command with values filled in from the request file's frontmatter — not
   placeholders:
   `node "${MSG_CLI}" new --type response --id <id> --to <from> --from <role>`
4. What to send after: `[hierarchy-msg <response path>]` as the first line, then the
   `[1] status` bullet.
5. **The escape:** "if this message is a status update or check-in rather than your
   answer, send it again unchanged and it will go through." §4.3 — a deny whose false
   positives have no stated exit is a trap.

**Fix F — `validateResponseToken(text, dir, expectedFrom, expectedId)`.** Mirror
`validateRequestToken` (`lib-hier.mjs:426-437`) and add the id check:

- token present; path absolute and exists; under `msgsDir(dir)`; ends `--response.md`
- frontmatter `type === "response"`
- `fm.from === expectedFrom` (the sending role)
- **`fm.id === expectedId`** — the pending record's request id.

Without the last check, a pointer at any older or unrelated response passes, letting a
session close an obligation with a document about something else — worse than the
missing-token case, because it looks answered.

A token present but failing any check gets a **different** deny naming the specific reason
and is **not** subject to the one-round allowance.

## [7] Interaction with the liveness tracker

- The gate **reduces the cause** of spurious stale-dispatch flags. Post-D,
  `stop-peer-nudge` adds a second catch at turn's end (§4.1a).
- It **does not change** the tracker's clearing logic and does not make a stale flag
  impossible. A role that takes the one-round allowance and sends inline anyway still
  leaves an open exchange, and the Orchestrator will still be flagged. Correct, and must
  not be softened to compensate.
- The one tracker change is §4.1a's guard, which *preserves* existing behaviour.

Symmetry worth preserving: `posttooluse-peer-resolve.mjs:59-62` records a dispatch only
when the outgoing message carries a `--request.md` token — the request half is already
token-gated by evidence, not guess. This spec gives the response half the same property.

## [8] Test plan

`agent-hierarchy/tests/test-sendmessage-response-nudge.sh`, HOME-redirect + temp hierarchy
dir, per the existing hook tests.

Tests 1 and 4 **must route through `userpromptsubmit-peer-tracking.mjs`'s real pipeline**
and assert on the **persisted** record, not an in-memory return value. That is what caught
the r4 defect, and a version of these tests that seeds records directly would have passed
against broken code.

1. **Fix D, tonight's exact scenario:** feed `userpromptsubmit-peer-tracking.mjs` a prompt
   consisting of a `<cross-session-message from="...">` wrapper whose first non-blank line
   is `[hierarchy-msg <abs path to a --request.md>]` (no peer-brief sentinel anywhere).
   Assert the **persisted** record carries `msg` = that path, `reply_to` = the wrapper's
   `from`, and `armed_by: "msg-token"`.
2. Same, but the token is not on the first non-blank line → **no** record armed.
3. Same, but the path does not exist, or is a `--response.md`, or `parseMsgFilename`
   rejects it → **no** record armed.
4. Existing sentinel form still arms, unchanged, and the **persisted** record carries
   `armed_by: "sentinel"`.
5. `architect` caller, pending record with `msg`, SendMessage with no token → **deny**;
   reason contains the filled-in `--id` and `--to`.
6. Same, second attempt → **allow**, and `send-nudge-unmet` is written.
7. No pending record for this session → **allow**.
8. Pending record exists but has **no `msg`** (brief arrived inline) → **allow**.
9. A *different* session's pending record exists → **allow**.
10. Orchestrator caller (no direct subordinate role) → **allow**.
11. `reviewer` and `ultra-advisor` with a qualifying pending record → **allow** (§3.6).
12. Valid `[hierarchy-msg <response path>]` whose `id` matches → **allow**.
13. **Fix F:** token points at a valid response whose `id` is a *different* request →
    **deny**, and **deny again on retry**. Repeat for a missing file, a `type: request`,
    and a mismatched `from:`.
14. The peer-record store is byte-identical before and after a deny and after an allow.
15. **§4.1a benefit:** a session with a msg-token-armed pending record and an armed turn
    marker is blocked by `stop-peer-nudge.mjs` at Stop with the response-file instruction.
16. **§4.1a guard:** `stop-orchestrator-liveness.mjs` does **not** cede on a
    msg-token-armed record; **does** cede on a sentinel-armed record; **does** cede on a
    legacy record with no `armed_by` field.
17. Subagent context (`agent_id` set) → **allow**.
18. Hierarchy disabled, and `msgs: "off"` → **allow** in both cases.
19. Malformed hook input / unreadable hierarchy dir → **allow** (fail open).

## [9] Open items

### 9.1 Corrections to earlier framing

- **"New hook on SendMessage"** — a SendMessage gate already exists
  (`pretooluse-msg-gate.mjs:60`). A new hook is still right, but for §2's reasons.
- **"Peer-role dispatch needing the header"** — the failing case is a **response**, not a
  dispatch.
- **r3 §3's "unmodified" instruction** — wrong for `armed_by`. §3.1.

### 9.2 NEEDS-EVIDENCE — not blocking

The §4.3 misfire rate on legitimate mid-task pings. Nothing depends on the answer: the
design is fail-open after one round either way. If noisy, the cheap fixes are a
message-length exemption or once-per-session instead of once-per-obligation.

### 9.3 Escalation

Ultra-Advisor reviewed at r3 and returned GO conditional on D/E/F, all applied. r4 is a
one-line propagation fix to a defect the Implementor found and diagnosed correctly; it
changes no design decision and needs no further pass.

### 9.4 Consistency with spec 0002 §6a

Spec 0002 argued *against* a `PreToolUse` gate. Two things carry the distinction:

1. **This gate fails open after one round; 0002's blocked.** 0002's effectiveness was a
   property of who happened to be calling. This one is fail-open by design.
2. **This gate makes no completeness claim.** 0002's deeper objection was false
   confidence — a partial gate displacing the habit it was meant to guarantee. §7 says out
   loud that this one does not make stale flags impossible.

> **r3 — Fix E.** r2 led with "SendMessage is a closed surface, nothing to route around."
> Overstated and removed: a peer can decline to reply, or use another transport. Coverage
> here is *better* than 0002's, not complete — resting the distinction on a completeness
> claim would have reproduced the exact error §6a names.

### 9.5 Confidence

- HIGH on §2, on Fix D's diagnosis (`lib-peer.mjs:108-110` plus the store grep), and on
  §4.1a's three consumers (enumerated from grep, not inferred).
- HIGH on §3.1's fix and on rejecting the spread — the persistence-boundary argument is
  about what *should* be durable, which a spread cannot express.
- HIGH on §5's mechanics — a transcription of a shipped, debugged pattern.
- MEDIUM on §4.3's false-positive rate. §9.2.
- MEDIUM on excluding `reviewer`/`ultra-advisor` long-term rather than as a §3.6
  workaround. If those roles gain Write, revisit; test 11 will fail loudly.
- Retracted: r1's disk-scan predicate; r2's assumption that `pendingFor` is populated on
  this path; r3's claim that `userpromptsubmit-peer-tracking.mjs` needs no edit.

## [10] Acceptance checklist

1. `extractPendingRecord` arms on an anchored `[hierarchy-msg <...--request.md>]` first
   line with `armed_by: "msg-token"`; the sentinel path is unchanged and tagged
   `armed_by: "sentinel"`. Neither path ever returns a record without `armed_by`.
2. Anchoring is preserved on the new path (test 2).
3. **`userpromptsubmit-peer-tracking.mjs`'s `appendPeerRecord` call includes
   `armed_by: rec.armed_by`**, and the persisted record carries it on both paths
   (tests 1 and 4). The field set stays a hand-listed allowlist — **not** replaced by a
   spread — and carries a comment saying so (§3.1).
4. `stop-orchestrator-liveness.mjs:107` cedes only on non-`msg-token` records, and treats
   a missing `armed_by` as sentinel-armed (test 16).
5. New hook file exists; `pretooluse-msg-gate.mjs` is **unmodified**.
6. `hooks.json` registers both hooks on `PreToolUse`/`SendMessage`.
7. `validateResponseToken` checks path, `type: response`, `from`, **and `id`** (test 13).
8. Gate fires only for directly-attributed `architect` / `implementor`, only with a
   `msg`-bearing pending record for this session.
9. `reviewer` and `ultra-advisor` are never gated (test 11).
10. A pending record with no `msg` never triggers a nudge (test 8).
11. One nudge per request id; the retry is allowed and writes `send-nudge-unmet`.
12. A malformed or id-mismatched pointer denies every time, with no one-round allowance.
13. Deny text carries the filled-in `--id`/`--to`, the response-file command, and the
    "re-send unchanged if this is a check-in" escape.
14. The hook writes nothing to the peer-record store (test 14).
15. `stop-peer-nudge` fires for msg-file obligations (test 15).
16. Fails open on every error path.
17. `plugin.json` and root `marketplace.json` both bumped.
18. All 19 tests pass, and the 46 pre-existing tests still pass.
