# 0037 — messaging: the reply lands beside the request

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Diagnosed and fix-shape adjudicated by Ultra-Advisor (msg `20260902-160228-196l` [2]);
this spec fills the API/edge-case/test gaps left to spec-authoring judgment.
Files: `agent-hierarchy/hooks/msg.mjs`, `agent-hierarchy/mcp/server.mjs`
(`msg_new` param), `agent-hierarchy/hooks/lib-config.mjs` (dispatch/nudge
instruction text), `agent-hierarchy/skills/agent-roster/SKILL.md`,
`agent-hierarchy/tests/test-msg-reply-beside-request.sh` (new)

Companion: 0038 (roster add auto-init) — same user report, **different root
cause**; deliberately split (0033 §9's grounds: different files, different
failure class — silent misdelivery here vs. a loud feature gap there — and
partial completion stays meaningful).

**Goal.** A peer's response must reach the requester regardless of where either
session sits. Today the response's destination is re-derived from the
**responder's** cwd (`hierarchyDir(cwd)`), and when the two sessions resolve
different roots — worktree vs. main checkout, a `cd` across a repo boundary, the
basename home-fallback, an `AGENT_HIERARCHY_DIR` set on one side — delivery
fails. *(Amended at landing — the original framing overstated the silent case.)*
Two failure modes, both closed by this spec:

- **Loud but unremediable (the common case, and the likely user-observed one):**
  pre-fix `createMessage` already refused a response whose `--id` had no request
  in the resolved pool (`no request with id X under <msgsDir>`) — but the error
  named no cause and no remedy, so a cross-pool peer simply could not respond.
- **Silent misdelivery (narrower, still real):** when the responder's resolved
  pool happened to hold a same-id request — a stale copy, or a pool the sessions
  shared before diverging — the write succeeded into a pool the requester never
  reads, with no error anywhere.

---

## 1. Principle (adjudicated, not re-arguable here)

**The reply lands beside the request. A response's destination is never
re-derived from the responder's cwd.**

0027 §2's worktree-local pooling is **untouched and stays correct** — it governs
where a location's own messages pool. It must simply not decide where a
**cross-location reply** goes. Unifying `hierarchyDir` across worktrees was
considered and rejected by Ultra-Advisor (contradicts 0027 §2, large blast
radius, and does not cover the non-worktree divergence vectors b–d).

**One copy.** The response is written **only** to the request's directory —
never duplicated into the responder's local pool. Two copies that nothing
reconciles is this repo's most-repeated failure family, and the requester's pool
is the only one whose reader is guaranteed to exist.

## 2. Design

### 2.1 `--req` on response creation

```
msg.mjs new --type response --id <X> --req <absolute path to the request file> …
```

MCP `msg_new` gains the matching **`req_path`** parameter (same validation).

Behaviour when `--req` is given:

1. **Path must be absolute.** Relative → hard error. The value comes verbatim
   from the brief's `[hierarchy-msg <path>]` line, which is always absolute;
   accepting relative paths would resolve them against the responder's drifted
   cwd — the exact bug, reintroduced through the fix's own flag.
2. **The request file must exist and parse.** Missing file → hard error naming
   both likely causes (typo'd path; request archived/moved) — do NOT fall back
   to writing into `dirname(req)` anyway, because a typo'd-but-plausible
   directory is silent misdelivery again.
3. **Frontmatter cross-check** against the request: `--id` equals the request's
   `id`; the response's `to` equals the request's `from` (and `to_name`/`from_name`
   swap likewise). Mismatch → hard error quoting both values. This is what makes
   `--req` self-verifying rather than just a destination override.
4. **Write to `dirname(req)`.** Filename convention unchanged.
5. If a file with the same response filename already exists there → existing
   duplicate-response behaviour, unchanged (whatever msg.mjs does today for a
   same-pool duplicate — this spec does not alter it).
6. **Divergence telemetry, cheap:** after a successful `--req` write, if the
   responder's own resolved pool (`hierarchyDir(cwd)`) differs from
   `dirname(req)`'s parent, print one info line naming both. Not an error — this
   is the fix working as intended — but it is exactly the observability that
   would have found this bug a day earlier.

### 2.2 The guard: no `--req`, no matching request → loud failure

Creating a `--type response --id X` **without** `--req`, where the resolved pool
contains no `X--*--request.md`, becomes a **hard error** (non-zero exit):

> no request `<X>` found in `<resolved msgs dir>` — if you are answering a
> request delivered as `[hierarchy-msg <path>]`, re-run with
> `--req <that path>`. A response created here would land in a pool the
> requester never reads.

*(Amended at landing.)* The hard error itself is not new — pre-fix code already
refused this case (see Goal). What is new and load-bearing is the **remedy
text**: the error now names the resolved dir and instructs `--req`, turning a
dead end into a self-explaining fix. The genuinely-silent vector (same-id
request in the responder's pool) is closed by `--req` being the instructed path
in every brief (§2.3), plus the divergence notice (§2.1.6). **The local
same-pool flow is unaffected:** when the request IS in the resolved pool, no
`--req` is needed and nothing changes.

Backward-compat note: largely moot — the failing cases already failed; only the
message improves. No behaviour break to changelog beyond the new flag.

### 2.3 Instruction text carries `--req`

Everywhere the plugin tells an agent how to respond — the dispatch/nudge text in
`lib-config.mjs`, the peer-brief response instructions, SKILL.md — the command
gains `--req <request path>`, sourced from the brief's own `[hierarchy-msg]`
line. Zero new plumbing: the path already travels in every brief's first line.

MCP-first phrasing stays (per existing convention): `msg_new` with `req_path`
preferred, CLI fallback shown with `--req`.

### 2.4 Failure fallback — never silent, never local

If the write to `dirname(req)` **fails** (permissions, sandbox, read-only tree):
fail loudly with the OS error verbatim, and instruct the responder to deliver
the response content via SendMessage to the requester, naming the path that
failed. **Never** fall back to writing the response into the local pool — a
successfully-written-but-invisible file is this bug; an explicit failure with a
workaround instruction is its fix.

## 3. What must not change

- **0027 §2 intra-location pooling** — untouched. Requests still pool
  sender-local; delivery of requests remains the absolute path in
  `[hierarchy-msg]`.
- `hierarchyDir()` (`lib-config.mjs:301-308`) — untouched. This spec adds no new
  resolution logic; it bypasses resolution for exactly one operation.
- Request creation, listing, indexing — untouched. `msg_list`/`msg_index` keep
  reading the local pool; the requester's pool is where cross-location responses
  now correctly land, which is the pool the requester lists.
- Write-error loudness (`msg.mjs:266-268`) — already correct, keep.
- The response filename convention and frontmatter schema (beyond the
  cross-check reading them).

## 4. Supersession note — 0036 T11

0036's T11 records that **misplacement detection** structurally cannot fire when
peer and orchestrator do not share a `hierarchyDir`. That half of T11 is
**unchanged** — this spec does not make detection work across pools.

What 0037 supersedes is the **messaging consequence** of the same structural
split: a cross-pool peer could previously not deliver a response at all; with
`--req` it can. Add one line to 0036 §7 pointing here (status-section
reconciliation rule applies: that line lands with this implementation, not
before).

## 5. Tests

`agent-hierarchy/tests/test-msg-reply-beside-request.sh`. Fixture: temp repo +
`git worktree add`, HOME redirected (existing pattern).

| # | Scenario | Assert |
|---|---|---|
| T1 | Request created in main checkout's pool; responder runs from the **worktree** with `--req <abs request path>` | Response file exists in the **main checkout's** msgs dir; responder's worktree pool contains **no** copy |
| T2 | Same, responder cwd is a non-repo dir (`/tmp/...`) — vector c | Same assertions as T1 |
| T3 | No `--req`, request absent from resolved pool | **Exit non-zero**; stderr names the resolved dir and the `--req` remedy. **Premise corrected at landing:** the pre-fix tree already refused this case (`createMessage` threw `no request with id X under <msgsDir>`), so the exit-code and nothing-written halves of T3 pass against the unmodified tree; only the `--req`-remedy assertion is falsifying (seen failing pre-fix). The silent-misdelivery vectors §2.2 lists were real only where the responder's pool *did* hold a same-id request or the responder resolved to a pool it shared with a stale copy — the guard closes the message, not a previously-succeeding write |
| T4 | No `--req`, request IS in the resolved pool (the normal local flow) | Succeeds exactly as today — the guard must not tax the common case |
| T5 | `--req` with a relative path | Exit non-zero, no file written anywhere |
| T6 | `--req` naming a nonexistent file (plausible dir) | Exit non-zero, **no file written into that dir** |
| T7 | `--req` frontmatter mismatch (id differs; separately, to≠request.from) | Exit non-zero, both values quoted |
| T8 | MCP `msg_new` with `req_path` (via test-mcp-server harness) | Same behaviour as T1 |
| T9 | Divergence info line (§2.1.6): `--req` write from a divergent pool | The one-line notice appears; exit 0 |
| T10 | `AGENT_HIERARCHY_DIR` set for the responder only — vector d | With `--req`: lands beside the request (T1's assertions). Without: T3's guard fires |
| DUP | Second `--req` response for the same id (§2.1.5) | Exit non-zero, `already exists` |

**Status (landed):** 36/36 pass. Mutation standard (docs/spec-process.md)
applied — each seen failing against a deliberately broken copy, then passing
on the real tree: T1/T2/T8/T9/T10a vs `targetMsgs` forced to the local pool
(9 assertions fail); T7b/T7c vs the §2.1.3 cross-check block deleted (T7a
survives that mutation via the filename-id check, so the id half of T7 is
covered by filename parsing, not frontmatter); T6 vs the existence check
deleted; T3's remedy text, T5, T7, T8, T9, T10 and DUP vs the unmodified
tree (`git show HEAD:` for `lib-hier.mjs`, `msg.mjs`, `server.mjs`; 21
assertions fail, T3's exit-code/nothing-written halves pass — see T3's row).
T4 passes on every mutant and on HEAD: the local flow is untaxed.

Mutation standard applies: T1, T3, T6, T7 must each be seen failing against a
deliberately broken implementation before being scored as coverage. T3
additionally must be seen failing against the **unmodified** tree.

## 6. NEEDS-EVIDENCE

1. **Cross-tree write, not just read** (extends Ultra-Advisor's flagged item):
   can a worktree peer session actually WRITE into the main checkout's
   `.claude/hierarchy/msgs/`? The earlier W-1 probe found a sandbox guard that
   pinned an `isolation:"worktree"` **subagent** to its own tree ("must run
   inside its worktree"); whether any such wall applies to a top-level peer
   session writing across trees is **unknown and is this fix's critical path**.
   Test it live (a real peer session, not a subagent — the W-1 probe's
   caller-identity lesson applies verbatim). If blocked: §2.4's fallback is the
   designed behaviour; say so in the report rather than working around it.
2. **Cross-tree read** (Ultra-Advisor's original item): a worktree peer reading
   a main-checkout `[hierarchy-msg]` path. Same probe, one extra step.
3. Confirm where the dispatch/nudge response-instruction strings actually live
   (`lib-config.mjs` assumed from the state-block text at `:858`; there may be a
   second site in the Stop-hook nudge). Every site must gain `--req`, or the
   guard in §2.2 will fire on agents following stale instructions — grep for the
   current instruction phrasing and enumerate.

**Resolved at landing:**

1. **Cross-tree write — confirmed.** A real top-level headless session
   (`claude -p`, cwd = the registered worktree
   `.claude/worktrees/ah-t2-probe`, not an Agent-tool subagent) ran
   `msg.mjs new --type response --req <request path in another tree>`: exit 0,
   the response landed beside the request, zero copies in the worktree's pool
   or `~/.claude/hierarchy`, and the §2.1.6 divergence note printed. No sandbox
   wall applies to a peer session; §2.4's fallback was not needed. A first run
   with `--to-name`/`--from-name` accidentally unswapped was refused by the
   §2.1.3 cross-check (`response has "main-orch", request has "wt-impl"`) —
   the guard fires in a real session, not only under the test harness.
2. **Cross-tree read — confirmed.** Same probe session read the request file
   and reported a marker appended to its last line verbatim.
3. **Instruction-text sites enumerated** (grep for `--type response`,
   `msg_new`, `[hierarchy-msg` across hooks/, agents/, skills/, docs/) — every
   site now carries `--req`: `hooks/stop-peer-nudge.mjs`,
   `hooks/lib-config.mjs` (buildRoleSessionNotice),
   `hooks/subagentstop-msg-nudge.mjs`, `hooks/pretooluse-sendmessage-response.mjs`
   (deny-reason line; `--req` placed after `--from` so the existing nudge
   test's `--id X --to Y` adjacency assertion holds), `agents/{architect,
   implementor, reviewer, task-runner, ultra-advisor}.md`,
   `docs/comms-protocol.md`, `docs/mcp-tools.md` (msg_new row). No
   response-instruction text exists in `skills/agent-roster/SKILL.md` or
   `skills/autonomous-pipeline/SKILL.md` (their `msg_new` mentions are
   request-only). MCP `msg_new` gained `req_path` → `--req`.

## 7. Out of scope

- Making 0036's misplacement **detection** work across pools (T11's other half).
- Any change to where **requests** pool (0027 §2).
- Cross-machine delivery.
- `reap`/0033, 0038 — separate.

## 8. Confidence

**High** on mechanism and shape — code-verified diagnosis, adjudicated
principle, and the fix touches one operation in one file plus a parameter and
strings. The genuine unknown is §6.1 (cross-tree write permission), and the
design already contains its answer either way: writes work → done; writes
blocked → §2.4 is the behaviour, and the failure is loud.

No further Ultra-Advisor round needed before implementation.
