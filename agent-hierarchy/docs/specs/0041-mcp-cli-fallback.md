# 0041 — Uniform CLI fallback when the `ah` MCP server is not connected

Status: proposed (r2 — amended after Reviewer spec-defects F2/F3/F4/F6; changes
confined to §1.3, §2, §2.1, §4.1-T4, §6. §0, §1.1, §1.2, §1.4 and §3 are
unchanged and were re-checked against the r2 facts.)
Related: 0024 (mcp-connect-failure-after-update) — cross-referenced, not modified. 0013 (mcp server coverage).

## Requirement (user-settled)

> "we need to have the fallback for agents to be able to call the mcp tools
> directly if the mcp isn't connected. It should also inform the user."

Two deliverables: (1) one uniform, discoverable fallback protocol every role
follows, and (2) a user-visible notice when it fires.

## 0. Findings that shape the design

Inventory of `agent-hierarchy/mcp/server.mjs` (21 registered tools) against the
CLI entry scripts:

- **Every one of the 21 MCP tools is a thin `execCli` wrapper** (`server.mjs:411-431`)
  that spawns `node <script> <subcommand> [args]`. There is **no MCP tool with
  inline logic and therefore no MCP tool without a CLI equivalent.** The
  fallback is a documentation + protocol problem, not a missing-capability
  problem. This is the single most important finding: nothing has to be built
  on the CLI side.
- Mapping (tool → script/subcommand): `msg_new|list|downstream|index|roster` →
  `hooks/msg.mjs new|list|downstream|index|roster`; `roster_show|teams|create|
  adopt|reap|layout-splits|disband|resync|move|history|spawn-one|dismiss` →
  `hooks/roster.mjs <same verb>`; `roster_disband_close` / `roster_dismiss_close`
  → `roster.mjs disband|dismiss --close`; `roster_member` → `roster.mjs
  init|add|edit|remove`; `roster_config` → `roster.mjs layout|alias`.
- **Reverse gaps (noted, out of scope):** `msg.mjs sweep|route|global-scope` and
  `roster.mjs next-split|checkin` have no MCP tool. `checkin` is hook-internal.
  Not this spec's concern; recorded so a later reader does not read the mapping
  table as bidirectional.
- **No include/snippet mechanism exists for `agents/*.md`** — they are static
  files. `buildDirective()` (`hooks/lib-config.mjs:868-913`) does assemble
  runtime directive text programmatically, but only for live roster sessions,
  not for Task-tool subagents that read `agents/*.md`. See §3 for the tradeoff.
- The fallback prose already exists but **non-uniformly**: `architect.md:127`,
  `implementor.md:68`, `reviewer.md:86`, `ultra-advisor.md:91`,
  `task-runner.md:69` each carry a variant of "prefer `mcp__ah__msg_new` when
  available; otherwise `msg.mjs new …`"; `orchestrator.md:53` mentions
  `msg.mjs new` with no fallback framing at all;
  `skills/agent-roster/SKILL.md:37,56` carries a third phrasing. **None of the
  eight mentions the user notice.**

## 1. Design

### 1.1 Single source of truth for the mapping — extend `docs/mcp-tools.md`

Add a **CLI equivalent** column to the existing tool reference in
`agent-hierarchy/docs/mcp-tools.md`, one row per registered tool, giving the
exact script path and argv form (`hooks/roster.mjs disband --close --confirm
--plan-token <t>`), plus a short preamble section titled **"If the `ah` server
is not connected"** carrying the protocol in §1.2-§1.3.

Rejected: a new `docs/mcp-cli-fallback.md`. The tool reference is already the
place a reader looks for "what does this tool do"; splitting "and how do I call
it without MCP" into a second file guarantees the two drift. One file, one
table, one row per tool.

Rejected: duplicating the argv forms into each role file. Eight copies of a
21-row mapping is exactly the drift this repo's one-implementation rule exists
to prevent.

### 1.2 Detection — no probing, two triggers, one rule

An agent falls back when **either**:

- **(a) absent** — no `mcp__ah__*` tool appears in its available toolset; or
- **(b) failing** — a call to an `mcp__ah__*` tool returns an error indicating
  the server is not connected / the tool is unavailable.

The rule is written to cover both because which one an agent actually sees is
unresolved (NEEDS-EVIDENCE 1) and may differ between a server that failed at
session start and one that died mid-session. **No agent is asked to probe.**
There is no "test the MCP connection first" step: the first real call either
works or it does not, and a fallback that costs one failed call is cheaper than
a probe on every session.

Explicitly forbidden: retry loops against the MCP tool, and calling the MCP
tool "to see if it works" before doing the real work.

### 1.3 Fallback execution — read the mapping, do not reconstruct it

On trigger, the agent:

1. Reads the CLI-equivalent row for the tool it wanted from
   `agent-hierarchy/docs/mcp-tools.md`. It does **not** guess argv from the MCP
   tool's JSON schema — parameter names and flag names are not guaranteed to
   match, and a wrong guess against `roster.mjs disband --close` is destructive.
2. Runs it with Bash: `node <plugin root>/hooks/<script>.mjs <subcommand> …`
   — **if, and only if, its own contract permits that.** This spec grants no
   capability to anybody. The per-role table in §1.3.1 is authoritative;
   `docs/mcp-tools.md` must reproduce it and nothing else.

#### 1.3.1 Per-role fallback capability (r2 — corrected per F3, was wrong in r1)

r1 asserted "Architect and Reviewer deny Bash". That is wrong: the actual
`disallowedTools` frontmatter is —

| Role | Frontmatter denials | Can run CLI? | Can Write a msg file? |
| --- | --- | --- | --- |
| architect | `NotebookEdit, Bash, advisor` | **No** (Bash denied) | Yes |
| reviewer | `Edit, Write, NotebookEdit, advisor` | Not by frontmatter, but **No by contract** — see §1.3.2 | **No** (Write denied) |
| implementor | `advisor` | Yes | Yes |
| orchestrator | `advisor` | Yes | Yes |
| ultra-advisor | `Edit, NotebookEdit, advisor` | Yes | Yes |
| task-runner | allowlist `Read, Grep, Glob, Bash, WebFetch, WebSearch` | Yes | **No** (no Write) |

Consequences: **Architect** falls back by writing the response file directly
with Write (the message format is a plain file; `msg.mjs new` is a
convenience) and notes it in its report — unchanged from r1, and the only case
r1 actually got right. **task-runner** can run any CLI form but cannot author a
message file; it reports its result to its dispatcher instead, as it already
does.

#### 1.3.2 The Reviewer has no self-serve fallback (r2 — resolves F2)

The Reviewer's blocker is **not** a Bash denial — Bash is not in its
`disallowedTools`. Its blocker is its **contract**: it never executes, and
delegates every test/build/CLI run to the task-runner. Write and Edit are
additionally denied, so it cannot author a message file either. It therefore
has **no compliant self-serve fallback for any `mcp__ah__*` tool**, and this
spec does not invent one — loosening the read-only contract to work around a
disconnected MCP server would trade a documentation problem for a
role-boundary problem.

The Reviewer's fallback is therefore:

- **For a read it needs** (`roster_show`, `msg_list`, `msg_index`, …): dispatch
  the task-runner with the exact CLI form from `docs/mcp-tools.md` and reason
  over the compact report — its existing delegation path, no new mechanism.
- **For a write it needs** (`msg_new` for its own response): it cannot produce
  the file. It delivers its report inline to whoever dispatched it (SendMessage
  / its normal report channel) and states in that report that the `ah` server
  is not connected and the response file was not written — the Orchestrator
  persists it. This is the §1.4 report-line notice doing double duty; no extra
  ceremony.

`docs/mcp-tools.md` currently says "Reviewer's contract denies Write, not Bash,
so it runs the CLI normally instead." **That sentence is wrong and must be
replaced** with the two bullets above — it is the specific defect F2 named.

3. Applies the §1.4 notice once (every role, including the Reviewer).

### 1.4 User notice — once per session, addressed by role

- **One-time per session, not per call.** After the first fallback, subsequent
  fallbacks in the same session are silent.
- **Orchestrator / any top-level session:** tells the **user** directly, in its
  next user-facing message — one line, containing (i) that the `ah` MCP server
  is not connected, (ii) that it is using the CLI equivalents so work is not
  blocked, and (iii) the remedy from 0024: `/reload-plugins`, or restart the
  session. Remedy-in-the-notice is mandatory; a notice that only reports the
  fault makes the user go find the fix.
- **A dispatched or peer role reporting upward:** one line in its report/response
  message. It does **not** address the user; the Orchestrator relays if it
  judges the user should know. This keeps N subagents from producing N user
  notices for one root cause.
- The notice is informational. It never blocks, never asks for confirmation, and
  never becomes a reason to stop work.

Rejected: a per-call notice (spam), a state file to enforce once-per-session
(the constraint is one sentence of instruction; a file to track it is
machinery for nothing), and a hook-emitted mechanical notice (a hook has no
visibility into MCP connection state — see NEEDS-EVIDENCE 4).

## 2. Files to change

| File | Change |
| --- | --- |
| `agent-hierarchy/docs/mcp-tools.md` | Add the "If the `ah` server is not connected" section (§1.2-§1.4 protocol) + a CLI-equivalent column/row for all 21 tools. **The only place argv forms appear.** r2: its step-2 per-role text must reproduce §1.3.1's table and §1.3.2's Reviewer bullets; the existing sentence "Reviewer's contract denies Write, not Bash, so it runs the CLI normally instead" is wrong and must go. |
| `agent-hierarchy/agents/architect.md` (:127), `implementor.md` (:68), `reviewer.md` (:86), `ultra-advisor.md` (:91), `task-runner.md` (:69) | Replace the existing ad-hoc "prefer … otherwise …" clause with the standard sentence (§2.1). |
| `agent-hierarchy/agents/orchestrator.md` (:53) | Add the standard sentence, with the user-facing variant of the notice clause. |
| `agent-hierarchy/skills/agent-roster/SKILL.md` (:37, :56) | Normalize both phrasings to the standard sentence, with **clause C** (§2.1). Its pre-existing "Command surface" per-verb CLI reference is NOT in scope and must not be gutted. |
| `agent-hierarchy/skills/autonomous-pipeline/SKILL.md` (~:30) | Add the standard sentence with **clause C** where it directs MCP tool use. Its `msg.mjs route/sweep/list` mentions document CLI-only functionality (no MCP wrapper exists) and are NOT in scope. |

### 2.1 The standard sentence (identical text in all eight places)

> If the `ah` MCP tools are unavailable — not present in your toolset, or a call
> to one fails as not-connected — use the CLI equivalents listed in
> `agent-hierarchy/docs/mcp-tools.md` rather than guessing the arguments, and
> say so ONCE: <role-specific clause>.

Role-specific clause — three variants, one per audience (the third added in r2
to resolve F6):

- **A — user-facing.** `orchestrator.md` only: "tell the user in your next
  message that the `ah` server is not connected, that you are using the CLI,
  and that `/reload-plugins` or a restart fixes it."
- **B — report line.** `architect.md`, `implementor.md`, `reviewer.md`,
  `ultra-advisor.md`, `task-runner.md`: "add one line to your report."
- **C — defer to the invoking role.** Both `SKILL.md` files. **A skill is not a
  role**: the same skill text is read by a top-level session and by a
  dispatched subagent, so neither A nor B is correct for it unconditionally,
  and hard-coding either would make one of the two audiences wrong. Clause C
  reads: "apply the notice per your role — if you are the top-level session,
  tell the user; if you were dispatched, add one line to your report." What
  governs a skill is the role of whoever invoked it, never the skill file.

The sentence must be **byte-identical** across the eight files apart from that
clause, so drift is greppable (test T2), and clause C must be byte-identical
across both `SKILL.md` files (test T3).

### 2.2 Tradeoff: static files vs. `buildDirective()`

`buildDirective()` (`lib-config.mjs:868-913`) would inject the sentence into
every live roster session from one edit — attractive, and it is where the
duplication would ideally live. It is **not** chosen because it reaches only
roster-spawned sessions: Task-tool subagents dispatched from `agents/*.md` never
see it, and those are exactly the agents most likely to be running when a
plugin update kills the server. Eight copies of one sentence with a
grep-equality test is the smaller risk than a shared injection that silently
misses half the audience. Revisit if a real include mechanism for `agents/*.md`
ever lands.

## 3. Must not change

- No change to `mcp/server.mjs`, `hooks/roster.mjs`, `hooks/msg.mjs` — no new
  CLI subcommand, no new flag, no schema change. Every tool already has its CLI
  equivalent (§0); this spec adds documentation and protocol only.
- No new capability for any role. A role denied Bash stays denied Bash (§1.3.2).
- Spec 0024 is not edited; `docs/mcp-tools.md` cross-references it for the
  root cause and the `/reload-plugins` remedy.
- No probe, no retry loop, no connection health check anywhere.

## 4. Verification

### 4.1 Tests (new: `agent-hierarchy/tests/test-mcp-cli-fallback.sh`)

- **T1 — mapping completeness (drift guard).** Extract every registered tool
  name from `mcp/server.mjs`; assert each appears in `docs/mcp-tools.md` with a
  non-empty CLI-equivalent entry. Falsifier: add a fake `roster_bogus`
  registration → T1 must fail. Control mutation: delete one row from the doc
  table → T1 must fail.
- **T2 — uniform prose.** Assert the §2.1 standard sentence's invariant portion
  appears exactly once in each of the six `agents/*.md` and both `SKILL.md`
  files. Falsifier: delete it from one file → T2 must fail (this is the
  mutation-standard check for the whole change).
- **T3 — notice clause present, correct variant per file.** Assert each of the
  eight files contains the once-per-session notice clause; that
  `orchestrator.md` carries variant A (naming `/reload-plugins`); that the five
  other `agents/*.md` carry variant B; and (r2, per F6) that **both `SKILL.md`
  files carry variant C byte-identically**, and neither carries A or B.
- **T4 — the removed ad-hoc clauses stay removed** (r2 — redefined per F4; r1's
  wording was unimplementable and is superseded). r1 asked for a blanket ban on
  any literal `roster.mjs <verb>` / `msg.mjs <verb>` form in `agents/*.md` or
  `SKILL.md`. Taken literally that also forbids two things §2's file table never
  asked to touch: `agent-roster/SKILL.md`'s pre-existing "Command surface"
  per-verb reference, and `autonomous-pipeline/SKILL.md`'s `msg.mjs
  route/sweep/list` mentions — which document **CLI-only** functionality with no
  `mcp__ah__*` wrapper at all, and use the CLI as the pipeline's own primary
  mechanism rather than as an MCP fallback. Enforcing r1's wording would delete
  real documentation.

  T4 is therefore scoped to exactly the clauses §2's file table removes:
  - no `--type response --id` literal remains in any of the eight files;
  - no `msg.mjs new ... --to` literal remains in `orchestrator.md`;
  - no `msg.mjs new --eta` literal remains in `autonomous-pipeline/SKILL.md`;
  - falsifier: a scratch copy of `implementor.md` with the old clause appended
    must be caught.

  This is what the Implementor built and the Reviewer validated; the spec is
  being made to agree with a validated fix, not redesigned. The r1 intent —
  "the mapping is not re-copied into role files" — survives as a **review
  convention**, not a test: a future diff that pastes mapping rows back into a
  role file is a review reject, and no grep can distinguish that from
  legitimate CLI-only documentation.
- Existing suites (`test-mcp-server.sh` and all roster/msg tests) must stay
  green **byte-for-byte**: this change touches no executable code.

Every test must be seen failing before the change lands (per repo mutation
standard), and each falsifier above exercised.

### 4.2 Release chore

Any release-worthy `agent-hierarchy` change bumps the version in **both**
`agent-hierarchy/.claude-plugin/plugin.json` and root
`.claude-plugin/marketplace.json`, together, in the same commit. The Implementor
performs the bump; this spec does not choose the number.

## 5. NEEDS-EVIDENCE (for the Implementor; none blocks starting)

1. **Does a not-connected stdio MCP server leave its tools listed?** When the
   `ah` server is failed/disconnected mid-session (the 0024 scenario), does an
   already-spawned agent still see `mcp__ah__*` in its toolset and get a
   catchable error on call, or do the tools simply not appear? Observe both the
   session-start-failure case and the died-mid-session case if possible.
   *Decides:* nothing structural — §1.2 already covers both triggers — but if
   the tools are always simply **absent**, trigger (b) is dead prose and the
   standard sentence can be shortened to the absence case alone. If a call
   error IS surfaced, record its exact text so §1.2 can name it.
2. **Do `roster.mjs` / `msg.mjs` print a usage listing** on `--help` or on an
   unknown subcommand (non-zero exit)? *Decides:* if yes, add "or run the script
   with `--help`" as a second, self-describing discovery path in §1.3, which
   makes the fallback survive a stale doc. If no, the doc table is the only
   path and T1's drift guard carries the whole weight.
3. **Do any `execCli` handlers rewrite argument names** between the MCP schema
   and the CLI flags (e.g. an MCP param `member` becoming `--name`)? Spot-check
   the argv assembly for `roster_member`, `roster_config`,
   `roster_disband_close`. *Decides:* whether the doc table can be written as
   "same names" or must spell out every rename. Assumed: renames exist (which is
   precisely why §1.3 forbids guessing from the schema).
4. **Can a hook see MCP connection state?** If a SessionStart/PreToolUse hook can
   detect that `ah` is not connected, a mechanical one-time notice becomes
   possible and would beat prose. Observation only — out of scope for 0041
   either way; report the answer so a follow-up spec can be judged.

## 6. Decisions made / refused

**Made (mine):**
- Fallback mapping lives in one file (`docs/mcp-tools.md`), never copied into
  role files (§1.1, enforced by T4).
- Detection is "absent OR failing", with no probe and no retry (§1.2).
- Notice is once per session, user-addressed only from the top-level session,
  and must carry the `/reload-plugins` remedy (§1.4).
- Eight literal copies of one sentence, with a grep-equality test, in preference
  to `buildDirective()` injection (§2.2).
- No code change anywhere; this is documentation + protocol (§3).

**Made in r2 (Reviewer spec-defects):**
- **F3:** r1's claim that Architect and Reviewer both deny Bash was factually
  wrong. Corrected against actual frontmatter in §1.3.1 — only Architect denies
  Bash; Reviewer denies Edit/Write/NotebookEdit; task-runner has an allowlist
  with Bash but no Write.
- **F2:** the Reviewer gets **no self-serve fallback** (§1.3.2). Its blocker is
  its read-only *contract*, not a Bash denial, and the fix is its existing
  delegation path (reads → task-runner) plus reporting inline for writes it
  cannot make. Rejected: relaxing the Reviewer's contract or granting it Write
  for the fallback path — that trades a docs problem for a role-boundary one.
- **F4:** T4 redefined to the shipped, scoped check. r1's blanket ban would have
  deleted legitimate CLI-only documentation in both skills; the "don't re-copy
  the mapping" intent survives as a review convention, since no grep separates
  it from valid CLI-only prose.
- **F6:** skills get a third notice variant (clause C) that defers to the
  invoking role, because a skill is read by both top-level and dispatched
  sessions and neither A nor B is unconditionally correct for it.

**Refused (user's call, flagged, not silently picked):**
- **F1 — should the fallback be mechanical rather than prose?** A hook that
  detects the disconnect and injects the notice + mapping would remove the
  reliance on every agent remembering. Blocked on NEEDS-EVIDENCE 4 and a
  materially larger change. Say the word and it becomes a follow-up spec.
- **F2 — the reverse gaps** (`msg.mjs sweep|route|global-scope`,
  `roster.mjs next-split` have no MCP tool). Out of scope here; a one-step
  follow-up if wanted.

## 7. Confidence

Normal. No security, auth, migration, or concurrency exposure; the change is
inert with respect to executable behaviour. No escalation recommended.
