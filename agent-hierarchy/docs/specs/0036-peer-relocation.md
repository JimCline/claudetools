# 0036 — W-1 Tier 2: peer relocation

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Parent: 0034 (worktree audit), 0035 (Tier 1, placement at creation).
Adjudicated by Ultra-Advisor, 2026-09-02 — ruling in `20260902-140001-1tqp`.
Files: `agent-hierarchy/hooks/roster.mjs`, `agent-hierarchy/hooks/sessionstart.mjs`,
`agent-hierarchy/hooks/lib-roster.mjs`, `agent-hierarchy/tests/test-roster-relocation.sh` (new),
`agent-hierarchy/skills/agent-roster/SKILL.md`

**Goal.** A peer that launched in the wrong directory can reach the team's
directory and be recognised as part of the team — the user's requirement,
verbatim: *"once the peer agent was created, there needs to be a way it can be
switched to the correct folder."*

---

## 1. The shape, and why it is small

The relocation primitive is **the harness's own `EnterWorktree({path})`,
unmodified**. Ultra-Advisor verified (claude 2.1.258, scratch repo, headless)
that from a plain repo-root session it moves `pwd`, Bash cwd, and hook
`input.cwd` **together**. That is a genuine relocation, not a hook-only
rebinding, so 0027 §2's worktree-local identities — peer name, message dir, team
prefix — re-derive from the new real cwd for free.

**No hook changes. No effective-cwd override. `agent-hierarchy` writes no
relocation machinery of its own.** It adds only: a recorded expectation, a
detection, an instruction, a verification, and a fallback.

### 1.1 Why my earlier probe said the opposite — reconciled

I reported that EnterWorktree refuses this outright. It does not, and the
discriminator is **the caller, not the target**:

| | my probe | Ultra-Advisor's probe |
|---|---|---|
| caller | a plain **Agent-tool subagent** inheriting the repo-root cwd | a plain **top-level session** at the repo root |
| target | `<repo>/.claude/worktrees/ah-t2-probe` — registered, already under `.claude/worktrees/` | a registered worktree |
| result | refused | **success; pwd and hook cwd both moved** |

My target satisfied every documented constraint. The refusal string — *"switching
is only available to sessions whose working directory is inside a worktree of this
repository"* — is the **subagent** rule, not the session rule.

**The entity Tier 2 must relocate is a top-level peer session**, which is the case
that works. I probed a subagent because it was the safe vehicle, and **the safety
choice silently changed the thing under test.** Recorded here because it is the
reusable lesson, not the incidental one.

The same reconciliation explains the Enter/Exit asymmetry I reported: the
`ExitWorktree` refusal (*"would mutate the parent session's process-wide working
directory"*) is the harness protecting a **subagent's parent**. Different case
from a top-level peer.

### 1.2 What survived from that probe, and is load-bearing here

**A tool's success return is not evidence that the move happened.** In that probe
`EnterWorktree` returned success while a sandbox layer held the agent in place.
§3.4 exists because of it: relocation is confirmed by **read-back**, never by the
tool's return value. Same rule as 0035 §2.4, one layer up.

---

## 2. Two facts established before writing this, both of which change the plan

Confirmed by direct lookup, not assumed:

1. **`team.json` does NOT record an expected root.** The record written at
   `roster.mjs:1397-1406` (and `:1945-1954`) is
   `{version, team_id, created, roster_level, transport, orchestrator{session_id,pid}, members, partial}`.
   There is no cwd field anywhere in `lib-roster.mjs`. **The field must be added
   (§3.1)** — Ultra-Advisor's ruling said "confirm it lands; if not, add it," and
   it does not.

2. **There is no check-in command.** No `roster.mjs` subcommand appends to
   `peers.jsonl`; `roster.mjs` does not even import `appendRosterRecord`.
   Registration happens in **hooks**: `sessionstart.mjs:98-108` appends
   `{status:"up", role, session_id, pid, ppid, cwd, pane_id, …}` —
   **and it already records `cwd`.**

Fact 2 cuts both ways and is the crux of this spec:

- **Good:** the detection input already exists. `sessionstart.mjs` writes the
  peer's cwd today; nothing new is needed to *notice* misplacement.
- **Bad:** `SessionStart` fires **once, at launch**, before any relocation could
  occur. So the ruling's "relocate, then **re-check-in**, and verify by read-back"
  step **has no mechanism.** Nothing re-registers a peer mid-session.

**§3.3 adds that missing primitive.** It is the one genuinely new thing in this
spec, and it was not visible from the ruling.

---

## 3. Design

### 3.1 Record the expected root at team creation

Add **`expected_root`** to the team record, at both construction sites
(`roster.mjs:1397-1406`, `:1945-1954`):

```js
expected_root: cwd,   // the resolved --cwd; 0035's launch_cwd, same value
```

Set from the same resolved `cwd` that 0035 threads as `launch_cwd`, so placement
and expectation cannot disagree by construction — one value, two consumers.

**Store it realpath-normalised** (`realCwd`, `roster.mjs:379`), because every
comparison against it is a path comparison and `/tmp` vs `/private/tmp` will
otherwise produce false misplacement reports on macOS.

**Honest limitation, stated in the spec because it will bite otherwise:**
`expected_root` records *intent as the orchestrator understood it*. Under W-1's
confirmed mechanism the orchestrator's own cwd was stale, so it would have
recorded the wrong root confidently. **0036 detects a peer that disagrees with the
team; it cannot detect a team that is wrong about itself.** That remains Tier 1's
unbuilt half (§7.1) and this spec does not close it.

Backward compatibility: teams written before this field exists have
`expected_root === undefined`. **Absent means "no expectation recorded" — skip
detection entirely.** Never treat absent as a mismatch.

### 3.2 Detect at SessionStart

In `sessionstart.mjs`, where `cwd` is already computed (`:85`) and appended
(`:98-108`):

```js
const misplaced = expectedRoot && realCwd(cwd) !== expectedRoot;
```

**Team-resolution rule (F4/F6).** SessionStart has no `--team` and no known peer
name, only its role, and yet resolving the WRONG team is worse than resolving
none: §3.5's fallback is destructive (dismiss+respawn), so a false attribution
to another team's member destroys a healthy peer's context. This is a
correctness property, not a reporting one (§8).

1. SessionStart resolves its team using **one shared helper**, also used by
   §3.3/`checkin` — a requirement, not an implementation detail, so the two
   entry points can never disagree about which team a session belongs to.
2. It reads that team's record and compares against that team's
   `expected_root`.
3. A session that resolves to no team **skips detection entirely, silently** —
   not every session is a team peer, and a non-peer session must not be told
   it's misplaced. Same reasoning as §3.1's absent-field case.
4. The resolved team goes on the row as **`team`**.

**Record the peer either way — do NOT refuse to register.**

This is a deliberate divergence from the ruling, which suggested refusing
check-in while misplaced so nothing stale is written. **I am ruling the other
way, and the reason is the failure mode:** a peer that does not register is
invisible to `roster teams`, to `resync`, and to the orchestrator's fallback in
§3.5 — which cannot dismiss a peer it cannot see. The staleness concern is real
but is solved by *accuracy*, not by *silence*: the row says where the peer
actually is, and that this is wrong.

So append the existing row **plus** `misplaced: true`, `expected_root`, and,
when a team resolved, `team`.

**The row must NOT gain `name`.** Two reasons: (a) `peers.jsonl`'s `rosterKey`
is `rec.name || rec.session_id` — adding `name` silently repartitions
latest-per-key resolution for every existing consumer; (b) worse,
`posttooluse-roster.mjs`'s seen/briefed rows already carry `name` in a
*different* partition (keyed by session_id) from up/down rows — adding `name`
to the up row merges those partitions, and a later `seen` row (no cwd, no pid)
would then supersede the up row under latest-per-key, destroying this spec's
own misplacement data on the peer's next tool call. `team` is safe: it is not
part of `rosterKey`, and `posttooluse-roster.mjs` already sets a `team` field,
so the shape already exists.

A consumer that does not know the field ignores it; `roster teams` and the state
block surface it (§3.6).

**Instruction text**, emitted through SessionStart's existing additionalContext
channel alongside the hierarchy state block:

> Misplaced: this session is at `<cwd>`; team `<team>` expects `<expected_root>`.
> Run `EnterWorktree` with `path=<expected_root>`, then run
> `roster.mjs checkin` to re-register. **`cd` will not work** — a shell `cd` does
> not move this session's `input.cwd`; only `EnterWorktree` does.
> If `EnterWorktree` is refused or denied, report to the orchestrator for respawn.

The `cd` sentence is not padding. Ultra-Advisor confirmed shell `cd` does **not**
move `input.cwd`, and `cd` is the first thing any agent will reach for — the
incident's 300K tokens were spent largely on workarounds of exactly that kind.

**Nudge, not a gate.** No PreToolUse block, no refusal to work. A misplaced peer
that ignores the instruction is still a working session; it is simply flagged.

### 3.3 NEW: `roster.mjs checkin` — the missing primitive

Nothing today re-registers a session. Add a subcommand that appends a fresh `up`
row for the *current* session with its *current* cwd:

```
node roster.mjs checkin [--team <T>]
```

- Appends via `appendRosterRecord` — the same writer `sessionstart.mjs:98` uses,
  with the same field shape, so `peers.jsonl`'s latest-per-key semantics resolve
  it as the newer truth with no new merge rule.
- Re-runs §3.2's comparison and sets `misplaced` accordingly.
- Exits **non-zero when still misplaced**, so the peer and any script can tell
  success from failure without parsing prose.
- Prints the observed cwd and the expected root, both realpath-normalised.

`roster.mjs` does not currently import `appendRosterRecord` from `lib-hier.mjs`;
this adds that import. **That is the only new coupling in this spec** — flagged
explicitly because `roster.mjs`'s separation from the hook-side writers has been
deliberate until now, and a reviewer should confirm it is acceptable rather than
discover it.

### 3.4 Verify by read-back, never by tool return

**Load-bearing (§1.2).** The peer is considered relocated **only** when a
subsequent `checkin` reports a matching cwd. `EnterWorktree` returning success is
not sufficient and must not be treated as sufficient anywhere — not in the
instruction text, not in the orchestrator's logic, not in a test assertion.

A test must pin this: **`EnterWorktree` succeeding while the observed cwd is
unchanged must leave the peer `misplaced` (T6).**

### 3.5 Fallback: replace

When relocation is refused, denied, or impossible — headless sessions, permission
gates, a peer wedged past prompting — the orchestrator falls back to the Tier 1
path that is already built and tested:

`roster dismiss <name>` then `roster spawn-one <name> --cwd <expected_root>`.

**No new code.** This is 0035's placement path, which is now correct for the
terminal transport and verified for tmux. It is the answer whenever relocation
cannot be confirmed, and it must never be attempted *before* relocation — a
respawn discards the peer's context, which is the cost the user is trying to
avoid.

### 3.6 Surface it

- `roster teams` — a misplaced peer is attributed to a specific team member
  only under a two-case rule:
  - **Correlated:** the peer record's `team` matches the team AND `role`
    matches exactly one member of that team → flag that member (with its
    observed cwd).
  - **Not correlated:** no `team` on the record (a pre-0036 row), or the team
    has more than one member with that role → do NOT flag any member. Report
    it instead in a `misplaced_unattributed` count on the team output,
    carrying the observed cwd and role.

  An unattributed count tells the orchestrator to look; a wrongly-attributed
  flag tells it to act, and §3.5's action is destructive. Under-reporting is
  recoverable, mis-reporting is not.
- The SessionStart hierarchy state block — a misplaced peer count, so the
  orchestrator sees it without asking.

Same argument as 0035 §2.4: a placement fact this consequential must not be
silent.

---

## 4. What must not change

- **No hook honours any cwd other than `input.cwd`.** No `AGENT_HIERARCHY_DIR`-style
  effective-cwd override. Explicit non-goal — it would rebind the hook contract
  while leaving process cwd, Bash cwd, and the stdio MCP server's cwd stale,
  producing a half-relocated peer. That is the 0035 bug class rebuilt one layer up.
- **`ExitWorktree` is not the return path.** Re-issue `EnterWorktree` with `path`.
- **0027 §2's worktree-local identities** — peer name, message dir, team prefix —
  keep deriving from the real cwd. Relocation moves the real cwd, so they follow
  correctly with no special handling. **Nothing in 0027 is modified.**
- **0035's placement path** — untouched. 0036 consumes it (§3.5) and adds one
  field beside it (§3.1).
- `sessionstart.mjs`'s existing row shape — **added to, never altered.**
- Detection is a nudge. **No PreToolUse gate**, no refusal to work.

---

## 5. Tests

New `agent-hierarchy/tests/test-roster-relocation.sh`. Fixture pattern per the
existing worktree tests: temp repo, `git worktree add`, `HOME` redirected.

| # | Scenario | Assert |
|---|---|---|
| **T1** | Team created with `--cwd <worktree>` | `team.json` has `expected_root` = the worktree, realpath-normalised |
| **T2** | Peer's cwd = `expected_root` | row has `misplaced` falsy; no instruction text emitted |
| **T3** | Peer's cwd = repo root, `expected_root` = worktree | row **is written**, `misplaced: true`, instruction text names `EnterWorktree` **and** contains the "`cd` will not work" sentence |
| **T4** | T3's peer, then `checkin` from the correct cwd | new row `misplaced` falsy; **exit 0** |
| **T5** | T3's peer, then `checkin` still from the wrong cwd | still `misplaced: true`; **exit non-zero** |
| **T6** | Source-level assertion: no code path treats a relocation tool's return value as evidence of the move | The check name records §3.4's rule. Structural, not behavioural — see §6 item 6. |
| **T7** | Team record with **no** `expected_root` (pre-0036) | no detection, no `misplaced`, no instruction text. Absent ≠ mismatch |
| **T8** | `expected_root` and observed cwd differ only by a symlink (`/tmp` vs `/private/tmp`) | **not** flagged misplaced |
| **T9** | `roster teams` with one misplaced member | reports it, with the observed cwd |
| **T10** | Misplaced peer | is still visible to `roster teams` and dismissable by `roster dismiss` — §3.2's whole argument for recording rather than refusing |
| **T11** | Peer relocated into a worktree with its own separate `hierarchyDir` (0027 §2) | Detection structurally CANNOT fire — peer and orchestrator do not share a hierarchyDir, so the peer cannot read the team record. The check name records why. This is a named blind spot, not covered behaviour (§7). |
| **T11b** | `checkin` invoked through a real subshell (the actual production process shape — a Bash-tool call's node process is a transient shell's child, not the session) | still resolves the session correctly. Reviewer F1/F2's regression guard — this is the exact shape that hid F1 (a bare `process.ppid` never matching production). |
| **T12** | Two teams, each with an implementor; team A's is misplaced | team B's implementor is NOT flagged. F4's falsifying test — must be seen failing against the pre-fix implementation |
| **T13** | Named team (`--team X`), peer misplaced | detection fires and instruction text is emitted at SessionStart, no manual `checkin` needed. F6's falsifying test |
| **T14** | Team with two members of the same role, one misplaced | no member flagged, `misplaced_unattributed = 1` |
| **T15** | A session resolving to no team | no detection, no instruction text, no `misplaced` field |
| **T16** | A peer record with `team` absent (pre-0036 row) | unattributed — never attributed by role alone |

**Falsifiability:** T3 and T5 fail against a "refuse to register" implementation.
T6 fails when the source gains a signal-shaped flag. It does not detect a
behavioural regression that preserves the source shape — §6 item 6. T8 fails
against a non-realpath comparison — and will pass spuriously on Linux, so it must
be written to construct the symlink explicitly rather than rely on `/tmp`.
**T10 is the test that would catch §3.2's divergence being silently reverted.**

Mutation standard (adopted in 0035's review): each of T3, T5, T8, T12 must be
seen failing against a deliberately broken implementation before being scored
as coverage.

---

## 6. NEEDS-EVIDENCE

1. **Does `EnterWorktree` work from an interactive pane session at a repo root?**
   Ultra-Advisor verified headless only; the expected delta is a one-time approval
   prompt. The user's decision to require team worktrees under
   `<repo>/.claude/worktrees/` should make it prompt-free — **confirm that, since
   the whole design's usability rests on it.** If a prompt appears anyway, the
   instruction text must say so.
2. **Relocating an already-registered-wrong peer.** ANSWERED: yes — T4 confirms
   `peers.jsonl`'s latest-per-key resolution supersedes the old `misplaced:true`
   row with `checkin`'s freshly appended row; nothing stale is left visible.
3. **Does `roster.mjs` importing `appendRosterRecord` (§3.3) break any existing
   test or layering assertion?** ANSWERED: no — the full regression suite
   (all `tests/*.sh`) passes clean; no existing assertion about roster/hook
   separation broke.
4. **Confirm `resync` does not need to learn about `expected_root`.** ANSWERED:
   they do **not** fully agree — see the §7.1 addition below. `resync`'s
   reference (`teamCwd = findGitRoot(cwd) || cwd`) is recomputed per call;
   `expected_root` is frozen at team creation. This is a finding, not a
   cleanup, and it is Tier 1's to resolve (§7.1).
5. **ANSWERED: does SessionStart have the peer's own NAME available, or only
   its ROLE?** Only the role — SessionStart's hook `input` carries `session_id`,
   `cwd`, and `agent_type`, no name field. That is why §3.2's resolution rule is
   role-scoped and why §3.6's `misplaced_unattributed` bucket carries real
   traffic rather than being an edge case.
6. **OPEN: §3.4's read-back rule is guarded structurally (T6), not
   behaviourally.** A behavioural test needs an injectable relocation path that
   can report success while the cwd stays put. Not built; named here so it is
   not assumed covered.

---

## 7. Out of scope

### 7.1 Tier 1's unbuilt half — still open, and 0036 does not close it

`expected_root` is only as good as the orchestrator's own cwd (§3.1). Under W-1's
confirmed mechanism the orchestrator was stale and would have recorded a wrong
root with full confidence. The user named the requirement directly: *"the
orchestrator actively determines correct dir, not passive
inherit-my-own-directory."*

`createSpawn:974` still passes the ambient `cwd` with no check. **0035 shipping
and 0036 shipping still leaves that gap.** It is its own small spec, and it is the
last piece of the original complaint.

**A second root of truth for the same fact (§6 item 4).** `resync` compares
member cwd against `teamCwd = findGitRoot(cwd) || cwd`, recomputed on every
call; `expected_root` is frozen once, at team creation (§3.1). They are not the
same value by construction, and nothing unifies them today — they simply have
not yet been observed to disagree. Tier 1's unbuilt half (above) is exactly
what will make them diverge in practice: once the orchestrator's own cwd
determination becomes non-trivial, a `resync`-computed root and a
`expected_root` frozen at an earlier, possibly-stale moment can point at
different places for the same team. Tier 1's spec must unify them into one
reference, not leave two.

### Also out of scope

- **W-6** (0034 §4) — `resync` mislocation reporting. Overlaps §3.6; land 0036
  first, then decide whether W-6 is already covered.
- **0034 §7.3** cross-consistency test — still unlanded, still recommended.
- The tmux plan-string quoting / duplicate-representation items (0035 §4.2).
- `roster.mjs:1261`'s duplicate `splitCwd` derivation.

---

## 8. Confidence

**High on the shape.** The relocation primitive is verified by an independent
empirical probe rather than by reading, the design adds no persistent new concept,
and 0027 is untouched by construction.

**Medium on §3.3**, the one part not covered by the ruling: `checkin` is new, and
it introduces the only new coupling here (`roster.mjs` → `appendRosterRecord`).
It is small and mechanical, but it was invented in this spec rather than
adjudicated, so it deserves the reviewer's attention rather than the ruling's
authority.

**§3.2's divergence from the ruling is deliberate and argued** — record-and-flag
rather than refuse-check-in. If the Reviewer or Ultra-Advisor disagrees, T10 is
the test that encodes the disagreement, and reversing it is a small change.

**§3.6's correlation rule is a correctness property, not a reporting one
(F4).** §3.5's fallback is destructive (dismiss+respawn), so a wrong
attribution does not just mis-inform — it destroys a healthy peer's context in
a different team. The two-case rule exists because under-reporting
(`misplaced_unattributed`) is recoverable and mis-reporting (a false flag) is
not; any change to that rule must preserve the asymmetry, not just the count.

**No further escalation.** The hard call was made; what remains is buildable.
