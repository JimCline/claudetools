# 0034 — Worktree-correctness audit

Status: audit (catalog + punch-list; not a single implementable change)
Author: Architect (claudetools-architect)
Date: 2026-09-02
Revision: **r2** — real-world severity data arrived after r1 and corrected two
things: r1's "there is no lock of any kind" was overstated (§5.1), and W-2's
severity was understated (§4, W-2). One new finding, **W-6** (§4). Changes marked
**[r2]**.
Scope: every `cwd` / git-root dependency in `agent-hierarchy/`

**What this document is.** A catalog, a diagnosis of *why* worktree bugs keep
surfacing one at a time, and a prioritised punch-list. Several items are
spec-worthy now and are marked so; they are not specced here, because a spec that
tried to fix all of them at once would be unreviewable and unlandable in pieces.

**What it is not.** It does not re-open 0027, 0032, or 0033. Their outcomes are
referenced, and the two items 0032 explicitly deferred ("wants its own issue")
are folded in here rather than re-discovered — **W-3** and **W-4** below.

**Evidence basis.** Read, not run. Every `file:line` is from a grep of the
current tree (post-0032 build, `lib-config.mjs` is 1031 lines). Everything I
could not establish by reading is a NEEDS-EVIDENCE item in §8, and the headline
finding in §5 is among them.

---

## 1. Method and coverage

Swept: all 27 files in `agent-hierarchy/hooks/` and `agent-hierarchy/mcp/`, for
`process.cwd()`, `findGitRoot`, `hierarchyDir`, `input.cwd`/`opts.cwd`,
`pathSlug`, `projectConfigPath`, `userConfigPath`, `rosterLevelPaths`,
`rosterLevelCandidates`, `mainCheckoutRoot`, `homedir()`, and
`AGENT_HIERARCHY_DIR`. `commands/` and `skills/` contain only Markdown — no code
paths, nothing to audit.

**21 of 27 files carry a cwd or git-root dependency.** Two files hold nearly all
of the logic: `lib-config.mjs` (1031 lines — every path-resolution primitive) and
`roster.mjs` (2035 lines — every consumer that also *spawns* things). The other
19 are thin: they take `input.cwd`, call `hierarchyDir(cwd)`, and use the result.

That shape matters for the recommendation in §7: **the primitives are centralised
already.** This is not a codebase with path logic scattered everywhere. It is a
codebase with *five* centralised primitives that disagree with each other.

---

## 2. The systemic finding

Every worktree bug found so far — 0027's, 0032's, and the new ones below — is the
same defect in different clothing:

> **A function's *intent* about location and its *implementation* disagree, and
> nothing in the codebase declares intent, so nothing can test for the
> disagreement.**

There are exactly three intents in play, and they are genuinely different:

| Intent | Meaning | Two worktrees of one repo should… | Examples |
|---|---|---|---|
| **W — worktree-local** | belongs to *this checkout* | **differ** | message dir, peer name prefix, per-worktree personal config |
| **R — repo-wide** | belongs to *the project* | **agree** | roster templates, per-role model/effort, `enabled`/`route` |
| **S — session-local** | where the user actually is | n/a — it is an input | the pane's cwd, `input.cwd` |

And there are five primitives that answer "where am I", each landing on a
different one:

| Primitive | `lib-config.mjs` | Returns | Intent it serves |
|---|---|---|---|
| `findGitRoot(start)` | `:284-292` | nearest enclosing `.git` — **the worktree root** | W |
| `mainCheckoutRoot(root)` | `:333-358` | the main checkout behind a linked worktree | R |
| `resolve(cwd)` raw | `:280` in `projectConfigPath` | the literal cwd, no repo notion at all | *(none — see W-3)* |
| `homedir()` + `pathSlug(root)` | `:322`, `:368` | a per-root slot under `~/.claude` | W or R, depending on which root is passed |
| `AGENT_HIERARCHY_DIR` | `:302` | an explicit override | S |

Nothing at any call site says which intent it wants. So `resolveRoster` (R) and
`resolveConfig` (R) drifted apart for an entire release — 0027 fixed one and not
the other — and neither a reviewer nor a test could have noticed, because there
was no statement anywhere that they were *supposed* to agree.

**This is why fixing symptoms has not worked.** Each fix corrects one function's
implementation without recording its intent, so the next function to drift is
invisible until a user hits it. §7 proposes the structural fix; §6 is what to do
before that lands.

---

## 3. Catalog

Marked **OK** (worktree-correct), **BUG**, or **?** (needs evidence). "Intent"
is my reading of what the code is *for*, since the code does not say.

### 3.1 Primitives — `lib-config.mjs`

| # | Site | Intent | Status | Note |
|---|---|---|---|---|
| P1 | `findGitRoot` `:284` | W | **OK** | Correct by definition — a worktree's `.git` file stops the walk. 0027 §2 keeps it worktree-local deliberately. |
| P2 | `mainCheckoutRoot` `:333` | R | **OK** | Pure-fs pointer follow, with the bare-repo guard from 0027 §3.1. Every failure returns null → degrades to pre-0027. |
| P3 | `pathSlug` `:311` | — | **OK** | Pure function. |
| P4 | `userConfigPath` `:274` | R (global) | **OK** | No repo dependency. |
| P5 | `projectConfigPath` `:278-281` | R | **BUG — W-3** | `join(resolve(cwd), ".claude", …)` — raw cwd, never `findGitRoot`. Breaks from any subdirectory, worktree or not. |
| P6 | `rosterLevelPaths` `:316-324` | W (write-side) | **OK** | Worktree-local by design (0027 §6). Correct for writes; wrong if ever used for a repo-wide read — see C3. |
| P7 | `rosterLevelCandidates` `:361-372` | R | **OK** | 0027's fix. Worktree first, main root second. |
| P8 | `hierarchyDir` `:301-308` | W | **OK, with W-5** | Git-root branch is correct (worktree-local message dirs, 0027 §2). **The no-git-root fallback keys on `basename`** — see W-5. |

### 3.2 Consumers

| # | Site | Intent | Status | Note |
|---|---|---|---|---|
| C1 | `resolveRoster` `:493` | R | **OK** | Uses `rosterLevelCandidates`. 0027 + 0032 §3. |
| C2 | `resolveConfig` `:590` | R | **OK (as of 0032)** | Now uses `rosterLevelCandidates`. Was the 0032 §2 defect. **Residual: W-4.** |
| C3 | `statusReport` `:945-946` | R | **BUG — W-3** | Second `projectConfigPath(cwd)` call site; 0032 fixed only `resolveConfig`'s. `/hierarchy` output disagrees with what the hooks actually resolve, from a subdirectory. |
| C4 | `resolveTeamScope` `:562` | W | **OK** | `hierarchyDir(cwd)` — team records are correctly worktree-local. |
| C5 | `teamPrefixInfo` / `teamPrefix` | W | **OK** | Worktree basename by design (0027 §2) so peers from two worktrees get distinct names. |
| C6 | `resync` `roster.mjs:1742` | W | **OK-but-see-W-2** | `teamCwd: findGitRoot(cwd) \|\| cwd` — the worktree root. Correct *in itself*, and it is what makes W-2's consequence bite. |
| C7 | 19 hook files (`pretooluse-*`, `stop-*`, `sessionstart`, …) | W | **OK** | All follow `input.cwd ?? process.cwd()` → `hierarchyDir(cwd)`. Uniform and correct; the harness supplies the session's real cwd. |
| C8 | `mcp/server.mjs` | S | **OK** | Requires `cwd` on every tool call, never defaults to the server's own. Correct design — but it makes the *caller* responsible, which is where W-1 originates. |
| C9 | `create --spawn` → pane cwd `roster.mjs:972` | S/R | **BUG — W-1** | See §5. The headline finding. |
| C10 | `spawn-one` → pane cwd `roster.mjs:1935` | S/R | **BUG — W-1** | Same mechanism, same line of argument. |
| C11 **[r2]** | *(absent)* — no mislocation detection anywhere | R | **BUG — W-6** | Nothing compares a live member's cwd to the team's expected root. See W-6. |

---

## 4. Findings

### W-1 — Spawned panes inherit the orchestrator's cwd, not the roster's. **(highest friction)**

Full treatment in §5. Still a traced hypothesis, not reproduced — §8.1.

### W-2 — `resync`'s cwd-narrowing cannot match panes that W-1 misplaced. **[r2 — severity raised]**

`resync` matches members to live panes by, among other things,
`realCwd(rec.cwd) === teamCwdReal` (`roster.mjs:527`, `:562`), where `teamCwd` is
`findGitRoot(cwd) || cwd` — **the worktree root** (`:1742`).

But under W-1 the panes were created at the **orchestrator's** cwd. When those
differ, the cwd-narrowing pass silently matches nothing.

**[r2] r1 called this "degraded, fails safe" and ranked it fourth. That
understated it, and the real-world report is what showed why.** The framing
should be:

> **The one mechanism that could have *detected* a mislocated peer is disabled
> by the mislocation itself.**

`resync` is the tool an operator reaches for when the team's recorded state and
reality have diverged. A peer sitting in the wrong directory is precisely that
divergence — and the cwd comparison that would surface it silently matches
nothing, so `resync` reports no problem. The system's own diagnostic goes quiet
in exactly the case it exists for.

It still fails *safe* in the narrow sense — name and pane-id matching (`:386-396`)
continue to work, so nothing is corrupted. But "fails safe" and "fails silent"
are different properties, and this fails silent. Combined with W-6, that is how an
agent can spend 300K tokens without ever being told what is wrong.

### W-3 — `projectConfigPath` keys on raw cwd. *(carried from 0032 §2.3, still unfixed)*

`:278-281`. Running any hook from a subdirectory makes the `project` config layer
vanish. **No worktree required** — this is a plain-checkout bug that has been
sitting behind the worktree symptoms.

0032 Fix 2 replaced the *call* inside `resolveConfig` (`:590`), so the hook path
is now correct. **The function and its second caller at `:946` were left alone**,
so `statusReport` — what `/hierarchy` prints — still resolves the old way. That
is the worst residual shape: the diagnostic tool and the thing it diagnoses now
disagree, and the diagnostic is the one that is wrong.

### W-4 — A near-empty worktree config silently drops all roles. *(carried from 0032 §4.3, still unfixed)*

`resolveConfig` takes the **first existing** candidate per scope
(`firstExisting`), not the first *useful* one. A worktree file containing only
`teamAlias` — which is exactly what `roster alias --level repo` writes — wins the
`project` scope, the main root is never consulted, and every role falls to
`ROLE_DEFAULTS` with no diagnostic.

Note the asymmetry that makes this a *design* inconsistency rather than a mere
gap: `resolveRoster` on the sibling path uses first-**useful**-candidate — it
skips a file whose `roster.members` is empty and keeps scanning. Two resolvers,
same candidate lists, opposite skip rules.

0032 §4.3 deferred this deliberately: fixing it means merging within a scope,
which changes `shadowed`, `layers`, `sources`, and `/hierarchy`'s output. That
reasoning stands. It is a real deferral, not an oversight — but it should be an
issue, not a paragraph in a spec nobody re-reads.

### W-5 — `hierarchyDir`'s no-git-root fallback collides on basename. *(low frequency, high blast radius)*

```js
return join(homedir(), ".claude", "hierarchy", basename(resolve(base)));
```
`lib-config.mjs:307`

When there is no git root, the message dir is keyed on the **directory basename
alone**. Two unrelated directories named `api`, or `web`, or `repo` share one
`.claude/hierarchy/` — one `peers.jsonl`, one `msgs/` namespace, one message-id
sequence, one `team.json`.

Contrast `repo-user`, which keys on `pathSlug(root)` (the **full path**, `:322`)
precisely to avoid this. The two primitives disagree about how to name a
location, which is §2 again. Reachability unconfirmed — §8.4.

### W-6 — Nothing detects or remedies a live-but-mislocated peer. **[r2 — NEW]**

**There is no concept anywhere of "this member is running in the wrong place."**
A peer whose session cwd does not match the team's root is, to every part of the
system, a completely normal member.

Checked against 0033's machinery, since the shapes look similar and are not:

| 0033 verb | Applies to a mislocated live peer? |
|---|---|
| `roster reap` | **No.** Predicate is `!pidAlive(pid)` (0033 §3.3). The peer is *alive*, so reap must never touch it — correct by design, and it means reap offers nothing here. |
| `roster adopt` | **No.** Re-stamps `orchestrator.pid` on an orphaned *team*. Does not relocate, or even inspect, a member. |
| `roster resync` | **Should**, and is exactly the tool for it — but W-2 makes it silent in this case. |
| `roster dismiss --close` | **Partially.** Closing the member and `spawn-one`-ing a replacement *is* the working remedy today — but only for an operator who has already diagnosed the problem, which nothing helps them do. |

**So this is a distinct failure mode 0033 does not cover, and should not be
expected to.** 0033 is about records outliving their process; W-6 is about a
process outliving its usefulness while its record stays perfectly valid. The user's
phrase — *"orphaned the architect… at the root repo"* — is the right intuition
attached to a different mechanism: the *architect* was orphaned from its work,
not the *record* from its process.

**Why this deserves its own line rather than folding into W-1.** Even after W-1 is
fixed, a peer can end up mislocated — a hand-launched session, an old team, a
`--cwd` passed wrongly, a worktree removed from under a running peer. W-1 removes
the common cause; W-6 is the absence of a safety net, and the safety net is what
turns a five-minute problem into a 300K-token one.

**Direction (not specced here):** `resync` already collects each live pane's cwd
(`queryHerdrTopology` `:364-369` reads `cwd`/`foreground_cwd`) and already knows
`teamCwd`. The comparison exists; only the *report* is missing. Making `resync`
say "member X is at `<path>`, expected `<teamCwd>`" is a small change to an
existing pass — and it is worth doing **even before W-1**, because it converts a
silent unwinnable state into a named one.

---

## 5. W-1 — the live repro, and what the "lock" actually is

**[Amendment] This section's mechanism is superseded by
`0035-spawn-placement-terminal-cwd.md`.** The reported incident (orchestrator
inside a worktree, peer landed at repo root anyway) contradicted the mechanism
below — it predicted the opposite outcome. 0035 §1.1 records why and supplies
the corrected, live-confirmed mechanism (the terminal transport's spawn call
carries no `cwd` option, so the peer inherits `roster.mjs`'s own process cwd
rather than the resolved `--cwd`); its Tier 1 fix is implemented. Left below
for its historical trace of the wrong hypothesis, not as current fact.

The user's report: *"a peer agent architect was spawned at the repo root folder
instead of the work tree folder and now it can't cwd into the work tree because
the orchestrator has 'lock' on it."*

Traced mechanism:

1. `roster.mjs:126` — `const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();`
   One module-level `cwd`, from `--cwd` or the process's own.
2. `createSpawn` `:972` — `layoutAndLaunch(peerMembers, transport, mode, cwd, "create --spawn")`.
   **The orchestrator's cwd is passed as the pane cwd.** Nothing consults the
   roster that was just resolved, or its `path`, or `findGitRoot`.
3. The pane is created *at* that directory, at creation time:
   - herdr: `herdrCall(["pane","split", …, "--cwd", splitCwd, "--no-focus"])` (`:641`)
   - tmux: `execFileSync("tmux", ["new-window","-P","-F","#{pane_id}","-c", splitCwd])` (`:848`)
4. `claude` is then launched **inside that pane** (`herdr agent start …` `:249`,
   or `tmux send-keys` `:259`), so the new session's cwd is the pane's cwd.

**Why `cd` does not rescue it.** A pane's shell can `cd` anywhere. But the Claude
session captured its working directory when the process started, and *every*
hierarchy hook keys off `input.cwd` (C7 — all 19 files). So after `cd`, the shell
is in the worktree while the session's entire hierarchy identity — `hierarchyDir`,
the roster it resolves, its team, its peer name — is still bound to the launch
directory. **Immutable-after-launch.** Restarting the session in the right
directory is the only remedy available today.

### 5.1 Correction to r1: "there is no lock of any kind" was overstated **[r2]**

r1 asserted flatly that the user's "lock" was not a lock — *"not `git worktree
lock`, not `index.lock`, not a mutex"* — on the strength of one true fact:
**`agent-hierarchy/` takes no locks; a grep for lock primitives finds none.**

**That fact does not support that conclusion, and I stated it as though it did.**
`agent-hierarchy` holding no lock says nothing about whether *git* refused
something. And the follow-up report contains a detail r1 did not have —
*"refused to unlock the work tree to let it enter"* — which sounds much more like
a real refusal encountered by an agent than like a metaphor for immutable cwd.

At least one genuine git-level constraint is in scope and I dismissed it too
fast: **git forbids the same branch being checked out in two worktrees at once.**
An agent at the repo root attempting to reach the worktree's branch would be
refused by git, in terms that read exactly like a lock. `git worktree lock`
itself is also a real command that a user or tool may have invoked.

**What stands and what does not:**

- **Stands:** the immutable-after-launch mechanism (§5 steps 1–4). It is traced in
  the source and is independent of any lock question.
- **Withdrawn:** the claim that no lock of any kind is involved. I do not know
  that. §8.6 is the check.
- **Consequence:** advice of the form "tell the user there is no lock to release"
  should **not** be relayed until §8.6 answers. It may be actively unhelpful — if
  git is refusing a branch checkout, there is a real thing happening and telling
  someone it is imaginary sends them the wrong way.

Recorded rather than quietly edited because it is the fifth instance of one error
shape in this thread (see 0032 §11): *a locally true statement standing in for a
claim it does not support.* Here the true statement was "this codebase has no lock
primitives" and the unsupported claim was "no lock is involved."

### 5.2 Why W-1 is a design bug and not just a missing flag

`--cwd` exists on `create --spawn`, and the MCP layer requires `cwd` on every
call (C8) — so an orchestrator that *knows* it wants a worktree can already pass
it. But:

- Nothing tells the caller that this parameter decides where its peers will live
  for the rest of their lives. `--cwd` reads as "where to run this command", not
  "where to found the team".
- **The roster's own resolution already knows better.** `resolveRoster` returns
  `path`, and 0027's machinery knows worktree root from main root.
  `create --spawn` resolves the roster (`:966`) and then ignores all of it when
  choosing the pane cwd.
- The default is the failure. An orchestrator started at the repo root silently
  founds every team at the repo root, whatever worktree the work is in.

### 5.3 The decided fork, and the gap in how I framed it **[r2]**

The user has decided: **the orchestrator's checkout root wins**, and any fix that
leaves the pane misplaced and compensates with fully-qualified paths is
explicitly rejected.

The second half is unambiguous and is a hard constraint (§9.1). **The first half
has an ambiguity that is mine, not theirs**, and it must be resolved before the
fix is specced:

- If the orchestrator was **at the repo root** when the incident happened, then
  "orchestrator's checkout root wins" describes what already happens (§5 step 2)
  and is a **no-op for the reported symptom**.
- If the orchestrator was **inside the worktree**, then §5's traced mechanism
  would have put the peer there too — so W-1 as traced is **not** what bit them.

My §9 option (a) meant a *passive default derivation*. The user's words — *"the
peer agent should work where the orchestrator tells it… the orchestrator should in
fact make sure the peer agents are working in the correct folder"* — read closer
to an *active* obligation: choose deliberately, and verify. Those two designs
diverge precisely in the repo-root case. **Open question, §9.**

---

## 6. Punch-list, ordered by friction

**[r2] Cost signal now in the ranking.** A real session burned **~300K tokens**
attempting to self-remediate this. Per §5, no session-level remediation exists —
that agent was working an unwinnable problem for its entire run. Two consequences
for prioritisation: W-1's true cost is far above "peers start in the wrong
directory", and **W-6 — being told the state is unwinnable — may be worth more
per unit of effort than W-1 itself.**

| Rank | Item | Frequency | Severity when hit | Spec-worthy now? |
|---|---|---|---|---|
| **1** | **W-1** — spawned panes get the orchestrator's cwd | Every team created from an orchestrator not in the target worktree. For this user, near-constant. | **Very high.** Peers permanently bound to the wrong checkout; only remedy is respawn; ~300K tokens observed burned on one incident | **YES** — but blocked on §8.1 *and* §5.3's open question |
| **2** | **W-6** — no mislocation detection | Every occurrence of W-1, plus hand-launched and stale sessions | High — converts a bounded problem into an unbounded one | **YES.** Small (`resync` already has both values). **Consider landing before W-1** |
| **3** | **W-4** — near-empty worktree config drops all roles | Any worktree holding a config file, including one `roster alias` wrote | High and **silent** | **YES**, own spec — `resolveConfig` layering change |
| **4** | **W-3** — `projectConfigPath` raw cwd | Any command from a subdirectory; no worktree needed | Medium — layer vanishes; `/hierarchy` disagrees with the hooks | **YES**, small. Fix the function *and* `:946` |
| **5** | **W-2** — `resync` cwd-narrowing inert | Whenever W-1 has misplaced panes | Medium — **fails silent**, and is W-6's blocker | No separate spec — it *is* the mechanism W-6 must fix |
| **6** | **W-5** — `hierarchyDir` basename collision | Rare (session outside any git repo) | High if hit — silent cross-talk between projects | Not yet — confirm reachability (§8.4) |

**[r2] Ordering change from r1:** W-6 inserted at 2, W-2 reframed as its
mechanism and dropped to 5. Rationale: W-1 is gated on two unresolved questions
(§8.1, §5.3) and may take a while, whereas W-6 is small, unblocked, and its value
does not depend on either — a system that *says* "this peer is in the wrong
place" is worth having whether or not W-1's fix lands, and would have capped the
300K incident early.

---

## 7. The systemic recommendation

Fixing W-1 through W-6 individually leaves the §2 defect intact, and a seventh
will surface. The structural fix is small, because the primitives are already
centralised (§1):

**7.1 — One context, computed once.**

```js
/** Everything a caller needs to know about "where am I", answered once. */
export function repoContext(cwd) {
  const resolvedCwd = resolve(cwd || process.cwd());
  const worktreeRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  const mainRoot = mainCheckoutRoot(worktreeRoot);        // null in a normal checkout
  return { cwd: resolvedCwd, worktreeRoot, mainRoot, isWorktree: mainRoot !== null };
}
```

Every primitive in §3.1 takes this instead of re-deriving. That alone removes the
class of bug where two functions call `findGitRoot` and one of them forgets.

**7.2 — Make the intent nameable, so it can be tested.**

The point is not the helper; it is that **a call site should have to say which of
the three intents it wants.** `repoWideRoots(ctx)` returns `[worktreeRoot,
mainRoot]`; `worktreeLocalRoot(ctx)` returns `worktreeRoot`. A reader — and a
reviewer — then sees the intent at the call site instead of inferring it.

**7.3 — The test that would have caught 0027-vs-0032, and would catch the next one.**

One test, and it is the highest-value *structural* item in this document:

> Create a repo, add a worktree, put a config **only** at the main root. From
> inside the worktree, assert that **every R-intent consumer agrees**:
> `resolveRoster`, `resolveConfig`, and `statusReport` all report the same
> resolved level and the same source path.

It fails today (W-3 via `statusReport`), would have failed for the whole window
between 0027 and 0032, and will fail the next time someone adds an R-intent
consumer that re-derives its own root. **A cross-consumer agreement test is the
thing this codebase has never had**, and it is cheap: one fixture, three
assertions.

Add the mirror for W-intent — two worktrees must produce *different*
`hierarchyDir` and different peer prefixes — so "make everything use the main
root" can never be the accidental fix.

**Sequencing.** 7.3 first, on its own, before any of the §6 fixes. It is a test
against current behaviour, it documents the invariant, and it will pin whichever
fixes land afterwards.

---

## 8. NEEDS-EVIDENCE — I do not execute

1. **W-1: confirm the spawn cwd, in both orchestrator positions.** Start an
   orchestrator at the repo root, spawn a peer, record the pane's cwd and the
   peer session's `input.cwd`. Repeat with the orchestrator inside a worktree.
   **Both scenarios are required** — §5.3 shows the one-scenario version cannot
   distinguish "W-1 confirmed" from "W-1 confirmed but irrelevant to the report".
   If panes land at the checkout root in both, W-1 withdraws — stop and report.
2. **W-1: confirm the immutability.** In a misplaced peer, `cd` into the other
   directory, trigger a hook, and check whether `input.cwd` changes. §5 asserts
   it does not.
3. **W-3: confirm `statusReport` diverges.** From a repo **subdirectory**, compare
   what `/hierarchy` reports as the project config source against what
   `resolveConfig` actually used.
4. **W-5: is the basename fallback reachable?** Determine whether a session
   outside any git repo actually reaches `lib-config.mjs:307`. If unreachable,
   W-5 drops off the list rather than being fixed.
5. **Confirm the catalog is complete.** §3 is from greps for a fixed token list.
   Report any path-deriving code that does not use those tokens — string
   concatenation onto `.claude`, a hard-coded `".."`, or `dirname` chains.
   **A catalog's value is its completeness claim, and mine is bounded by the
   tokens I chose.**
6. **[r2] Was a real lock involved?** From the incident: capture the *exact* error
   text the mislocated agent received when it tried to enter the worktree. Check
   whether the worktree was `git worktree lock`ed, and whether the agent was
   attempting to check out a branch already checked out elsewhere (which git
   refuses in lock-like language). §5.1 withdrew r1's claim that no lock was
   involved; this decides it. **Until it answers, do not tell the user there is
   no lock.**

---

## 9. What I am not deciding

### 9.1 Settled by the user, recorded here

- **Fully-qualified-path workarounds are rejected.** Hard constraint on any W-1
  fix. It rules out the subtle version too: telling a peer its "real" directory
  in a prompt while its actual cwd stays wrong is the same workaround, and leaves
  `hierarchyDir`, roster resolution, team binding, and peer naming all keyed to
  the wrong root. Consistent with §5: cwd is captured at process start, so the
  only correct fix places the pane correctly **at creation**.

### 9.2 Still open

- **§5.3's ambiguity — the live one.** Does "the orchestrator's checkout root
  wins" mean *inherit the orchestrator's directory* (passive) or *the orchestrator
  must specify it deliberately and be prevented from getting it wrong* (active)?
  They differ exactly in the case that appears to have occurred. **W-1 cannot be
  specced until this is answered**, and answering it needs §8.1's second scenario
  plus one question to the user.
- **W-4's remedy**, for the reasons 0032 §4.3 gave. Gated on 0032 §7 item 3.
- **0027 §6's open question** (should `roster create` from a worktree write at the
  main root?). Adjacent to W-1 and possibly settled by the same decision; still
  the user's call.
- **Renaming the `user`/`project`/`repo-user` vs `global`/`repo`/`repo-user`
  vocabularies** (0032 §4.1). §7.2 makes intent explicit *without* touching those
  names deliberately, so the two changes stay independent.

---

## 10. Confidence

**§2's diagnosis and §3's catalog: high.** Both are direct readings, and the
catalog's structure is corroborated by every worktree bug found so far fitting one
of its three intents.

**W-3, W-4: high** — carried from 0032 where they were traced in detail; W-3's
second call site at `:946` is a fresh grep.

**W-6: high on the gap, high on the direction.** That reap/adopt do not apply
follows directly from 0033's own predicates, and that `resync` already has both
values needed for the comparison is read from `:364-369` and `:1742`.

**W-2: high on the mechanism.** r1 understated the severity; r2 corrects it.

**W-1: medium on the mechanism, and NOT demonstrated.** The chain
`:126 → :972 → :641/:848` is unambiguous in the source. But §5.3's ambiguity means
that even if the chain is confirmed, it may not be the mechanism that produced the
user's incident. **[r2] r1 rated this medium-high; lowered, because §5.1 showed I
had over-claimed once already on this same finding.**

**W-5: low confidence on reachability**, high on the consequence if reachable.

**No Ultra-Advisor escalation recommended.** Nothing here is security, auth,
migration, or concurrency. The open questions are product-behaviour calls for the
user and empirical checks for the Implementor, not reasoning problems.
