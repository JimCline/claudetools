# 0035 — W-1 Tier 1: correct-by-construction spawn placement

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Revision: r4 — T5 rebuilt (r3), mutation-proved at the real execution site `:850`
(not the `:254` plan string). tmux placement is now VERIFIED; herdr's remains
unverified (T6 skipped, §4.4). §3/§4.2/§4.4/§5/§6/§9 corrected to say so, and every
falsification-target citation corrected from `:254` to `:850`. §4.2's tmux-quoting
paragraph replaced — the execution site is not shell-interpreted; the residual
quoting risk is narrower, in `create --plan`'s published string only. New §11
records the error pattern (a display string beside the real call reads as the
implementation). Text-only; no behavior/test change from r3 (1461/1461 stands).
Revision: r3 — T5 as built asserts tmux's own `-c` behavior, not `roster.mjs`'s use
of it; passes even with `-c "${cwd}"` deleted from `:254`. §3/§4.2/§5/§6/§9
corrected to state tmux coverage was NOT converted; new §5 item 6 rebuilds T5 to
actually drive `roster.mjs create --spawn`.
Revision: r2 — T6 skip ruled acceptable; §4.2/§4.4/§5 amended so the claim T6 was
meant to retire stays explicitly OPEN. New §7.1 raises a scoping question the skip
surfaced.
Parent: 0034 §5 (worktree audit, W-1). **This spec supersedes 0034 §5's mechanism**
— see §1.1.
Files: `agent-hierarchy/hooks/roster.mjs`,
`agent-hierarchy/tests/test-roster-spawn-cwd.sh` (new)

Scope: **Tier 1 only** — the peer lands in the right directory at creation.
Tier 2 (a mislocated peer's recovery path) is explicitly out of scope; §8.

---

## 1. The defect

`spawnShape` (`roster.mjs:241-265`) has three transport branches. Two pass the
target directory to the thing that creates the process:

- **herdr** `:249` → placed by `runLayoutLoop` `:641`, `["pane","split", …, "--cwd", splitCwd, …]`
- **tmux** `:258` → `tmux new-window -P -F '#{pane_id}' -c "${cwd}"`

The third does not:

```js
return { transport, layout: [], launch: [`${claudeCmd} --bg`], target_placeholder: null, … };
```
`roster.mjs:264` — the **terminal** branch. No directory is passed at any point.

That command is executed by `runShell` (`:766`, called from `launchMember`
`:801`), which passes **no `cwd` option** to `execFile`. The child therefore
inherits **`roster.mjs`'s own process working directory**.

**And `--cwd` never changes that.** `:126` assigns the module-level `cwd` variable
from `opts.cwd ?? process.cwd()`; it is used for path *computation* throughout and
never calls `process.chdir()`. So the process cwd and the `cwd` variable are
independent values, and the terminal branch uses the wrong one.

**Confirmed live** (Implementor, evidence-only dispatch): the terminal
`execFile` call has no `cwd` option and inherits `roster.mjs`'s process cwd;
reproduced directly against the mechanism. Additionally, `mcp/server.mjs`'s spawn
of `roster.mjs` also passes no `cwd` option, and `lsof` on ~3 live MCP server
processes shows a fixed server cwd.

### 1.1 Why 0034 §5's mechanism was wrong, recorded

0034 §5 said the pane cwd *is* the orchestrator's cwd, and concluded that all
three transports misplace peers. That predicted an orchestrator inside a worktree
would produce a peer inside that worktree — and the reported incident had exactly
that setup with the opposite outcome. The mechanism above is what actually
explains it, and it is narrower: **the value `roster.mjs` computed was already
correct; one branch simply never applied it.**

The practical consequence of the difference: 0034 §5's version implied changing
how the target directory is *derived*. This one changes nothing about derivation.

### 1.2 The two-layer shape, and why only one layer needs fixing

There are two independent process-spawn boundaries that omit `cwd`:

| # | Boundary | Omits cwd? | Needs a fix here? |
|---|---|---|---|
| L1 | `server.mjs` → `roster.mjs` | yes | **No — see below** |
| L2 | `roster.mjs` → `claude` (terminal branch) | yes | **Yes.** This is the defect. |

L1 is real but **inert**, because `mcp/server.mjs` requires `cwd` on every tool
call and forwards it as `--cwd`. So `opts.cwd` is always set on the MCP path and
`:126`'s `process.cwd()` fallback never fires there. On the direct-Bash path the
fallback *does* fire, and is correct — `roster.mjs` is then a child of the
orchestrator's own session.

**Do not "fix" L1 by adding a `cwd` to the server's spawn.** It would be a no-op
against `--cwd` and would create a second source of truth for the same value.
L1 is called out here so a reader who greps for the pattern does not think it was
missed. It becomes live only if some future caller omits `--cwd`, which §4.3
guards.

---

## 2. The fix

**One idea: the launch step must receive the directory the caller already
computed.** No derivation changes.

### 2.1 `runShell` takes a cwd

`runShell` (`:766`) gains an options parameter and passes it through to
`execFile`:

```js
function runShell(commandString, opts = {}) {
  // … existing body, plus `cwd: opts.cwd` on the execFile options object.
}
```

Existing callers that pass nothing keep today's behaviour exactly.

### 2.2 The spawn shape carries the directory

`spawnShape(member, transport)` gains the launch directory as an explicit field
on every branch, so the value is visible in the returned plan rather than
implicit in one branch's command string:

```js
// terminal
return { transport, layout: [], launch: [`${claudeCmd} --bg`], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null };
```

`herdr` and `tmux` set `launch_cwd` to the same value for reporting parity
(§2.4); their placement continues to come from the layout step, unchanged.

### 2.3 `launchMember` applies it

`launchMember` (`:798`) passes it through:

```js
let attempt = await runShell(cmd, { cwd: member.spawn.launch_cwd });
```

Both the initial call `:801` and the herdr retry `:805` must pass it — a retry
that drops the cwd would place a peer differently from its first attempt, which
is the kind of intermittent, near-unreproducible placement bug this spec exists to
end.

**This is the entire behavioural change.** The terminal transport now launches
`claude` in the directory `--cwd` named, exactly as herdr and tmux already do.

### 2.4 Report the directory

`create --spawn` and `spawn-one` must include the launch directory in their
output, per member. 0034 §5.2's point stands and the 300K-token incident is the
argument: a placement decision this consequential must not be silent. A caller —
human or agent — has to be able to see where a peer was put without inferring it.

### 2.5 Deliberately NOT doing: `process.chdir()`

An early `process.chdir(cwd)` in `roster.mjs` would fix L2 and L1 at once, for
free, and would immunise any future transport branch.

**Rejected.** It is action-at-a-distance: it changes the meaning of every relative
path in the process, including inside `herdrCall`, `execFileSync`, and any future
code, and its correctness depends on nothing in the file relying on the original
cwd. That is a property no reviewer can check locally and no test asserts. The
explicit-argument version is longer and is checkable at the call site.

§4.3's test is what protects a future fourth transport instead.

---

## 3. What must not change

- **`cwd` derivation.** `:126` (`opts.cwd ?? process.cwd()`) is correct and stays.
  This spec changes only whether the computed value is *applied* at L2.
- **herdr and tmux placement.** `--cwd` at `:641` and `-c` at `:850` (the real
  execution site — `:254` is `spawnShape`'s plan-output string) are already
  correct; they keep placing panes exactly as today. See §4.2 — herdr placement
  is unverified (T6 skipped, §4.4). tmux placement is verified end-to-end by the
  rebuilt T5 (r3), proved load-bearing by mutation at `:850`.
- **`mcp/server.mjs`.** No change (§1.2).
- **`spawnShape`'s command strings** for herdr and tmux — byte-identical.
- The `--cwd` flag's meaning and every `*_FLAGS` set.
- 0034's other findings. W-2 through W-6 are untouched here.

---

## 4. Tests

New `agent-hierarchy/tests/test-roster-spawn-cwd.sh`.

**Fixture technique — this is the part that makes the tests real.** Do not launch
an actual `claude`. Put a stub named `claude` early on `PATH` that writes its own
`pwd` to a file and exits:

```sh
printf '#!/bin/sh\npwd > "$SPAWN_CWD_LOG"\n' > "$tmp/bin/claude"
```

The assertion is then on **where the process actually ran**, not on the command
string that was built. A test that only inspects the constructed command cannot
catch this class of bug — the terminal branch's command string is *correct*; what
was missing was the execution option beside it.

To create the divergence the bug needs, the test must run `roster.mjs` with a
**process cwd different from `--cwd`** — e.g. `cd /tmp && node …/roster.mjs
create --spawn --cwd "$repo"`. If those two are the same, every test here passes
vacuously.

| # | Scenario | Assert |
|---|---|---|
| **T1** | Terminal transport. `roster.mjs` process cwd = `/tmp`; `--cwd` = `$repo`. Spawn one peer. | Stub logs **`$repo`**. **Expected to FAIL pre-fix** (logs `/tmp`). This is the defect. |
| **T2** | Same, with `--cwd` = a **worktree** path while the process cwd is the main checkout | Stub logs the worktree path. The reported incident, in miniature. |
| **T3** | Terminal, `--cwd` omitted, `roster.mjs` run *from* `$repo` | Stub logs `$repo` — the direct-Bash path still works via `:126`'s fallback (§1.2) |
| **T4** | Path containing a **space** (`$repo/dir with space`), terminal transport | Stub logs it exactly. Guards the options-object approach against a naive `cd $dir &&` string fix, which would break here |
| **T5** | **tmux** transport, process cwd ≠ `--cwd` | New window's `#{pane_current_path}` is `--cwd`'s value. **Converts §4.2's inference into a fact for tmux.** Expected to pass pre-fix |
| **T6** | **herdr** transport, process cwd ≠ `--cwd` | Pane cwd is `--cwd`'s value. **[r2] SKIPPED as shipped — see §4.4.** Skip must be loud and must name the still-open claim |
| **T7** | Terminal, herdr-style retry path forced (first attempt fails) | The retry runs in the same directory as the first attempt (§2.3) |
| **T8** | `create --spawn` output | Contains the launch directory per member (§2.4) |

**Falsifiability:**

- **T1 is the falsifiable core** and must be seen failing against the unmodified
  tree before the fix lands.
- **T2** is the user-facing scenario; it fails pre-fix for the same reason as T1.
- **T4** targets a mistake *this spec* could invite — a string-prefix `cd` fix
  instead of the options object.
- **T5 and T6 are the honesty tests.** They are expected to pass both before and
  after, and their whole purpose is to check §4.2's claim rather than assume it.
- **T3** is a regression guard for the non-MCP path.

### 4.2 herdr/tmux being clean is an INFERENCE, not a checked fact

The Orchestrator asked me to be explicit, and the answer is: **inference.**

The Implementor's dispatch confirmed the terminal-branch mechanism. It did **not**
directly verify that herdr and tmux place panes at the `--cwd` value. My claim
that they are fine rests on reading `:641` and `:258` and seeing an explicit
directory argument in each.

That is good evidence but it is the same *kind* of evidence that produced 0034
§5's wrong mechanism — a plausible reading of a code path nobody had run.
**T5 and T6 exist to close that gap and should not be dropped as redundant.**

**[r2] Status after the build: T5 as built asserts that tmux honours `-c`, which
was never in doubt; it never invokes `roster.mjs` and passes with
`-c "${cwd}"` removed from `:254`. Coverage NOT converted for either branch.**
herdr — T6 was skipped for a safety reason, so the inference above still stands
unretired for the herdr branch. §4.4.

**[r3] Superseded for tmux.** T5 was rebuilt to drive `roster.mjs create --spawn`
with a process cwd ≠ `--cwd` and assert the resulting window's path.
Mutation-proved: deleting `"-c", splitCwd` from the `execFileSync` argv at `:850`
makes it fail; deleting `-c "${cwd}"` from the `:254` plan string does not. tmux
coverage is converted. herdr's is not — §4.4 stands unchanged.

**[r3] Corrected.** An earlier revision claimed the tmux branch was exposed to
shell quoting. It is not at the execution site: `:850` passes an argv array, the
same shape as herdr's `:641`, and neither is shell-interpreted.

The residual concern is narrower and real: the plan string at `:254` embeds the
directory with only double quotes and is published in `create --plan` output. A
consumer that copy-pastes that string into a shell can hit quoting trouble with a
path containing `"`, `$`, or a backtick. That is a plan-output fidelity issue, not
a placement bug — file it as such, alongside the duplicate-representation
question in this section's `[r3]` note above.

### 4.3 One guard against the next transport

Add an assertion — a test, not a runtime check — that **every** branch of
`spawnShape` returns a non-null `launch_cwd`. When someone adds a fourth
transport, that test fails until they decide where its peers go. This is the
cheap substitute for §2.5's rejected `process.chdir()`.

### 4.4 [r2] T6 skip — ruling

The Implementor skipped T6 rather than building it: this session's own shell is
ambiently inside a real herdr pane (`HERDR_ENV=1`, live `HERDR_PANE_ID`), so a
live `herdr pane split` would create a visibly disruptive pane in the user's
actual session. It extended §4's "SKIP loudly if herdr is absent" provision to
cover "herdr present, but only as the live session itself."

**The skip is ACCEPTED. The conclusion it would license is NOT.**

- **Accepted as an execution decision.** Disrupting the user's live session to
  satisfy a test is a real cost against a low-probability finding, and stopping to
  ask rather than either wrecking the pane or silently dropping the test is the
  right call. The extension of the skip provision is a reasonable reading of
  intent — **and is generalised here so it stops being a reading:** T6 skips when
  herdr is absent **or** when the only available herdr instance is the live
  session running the test.
- **Rejected as coverage.** T6's entire purpose was to retire §4.2's inference for
  herdr. A skipped T6 does not retire it, and nothing else in the suite does
  either. **T5 does not transfer to herdr because they are different call sites in
  different code paths** — `execFileSync("tmux", …)` at `:850` versus
  `herdrCall(["pane","split", …])` at `:643`, the latter computed against live
  pane geometry each iteration. A test that exercises one says nothing about the
  other. (An earlier revision gave the reason as a quoting-shape difference; that
  was wrong — both are argv — but the conclusion was not.) **T7 does not
  transfer** — it exercises retry logic against a fake herdr, which is not
  placement.

Honest post-build status, and it must be recorded this way anywhere the result is
summarised: **herdr placement is unverified.** Not "verified by proxy", not
"covered by T5/T7".

**This does not block the commit.** 0035 does not touch the herdr path, so
whatever is true of `:641` today stays true — the exposure is a *pre-existing*
defect if it exists at all, never a regression this change introduces.

**How T6 should eventually be run** (§5 item 4): against an **isolated, throwaway
herdr session**, not the live one — a dedicated session name torn down in the
test's cleanup trap. That is the Implementor's own suggestion and it is correct:
small fixture work, removes the safety objection entirely. Until someone does it,
the skip stays and the claim stays open.

**The in-file skip reason must say the claim is open**, not merely that herdr was
unavailable. A reader six months out must not be able to read the skip as "tested
elsewhere."

---

## 5. NEEDS-EVIDENCE

1. **T1 must be observed failing pre-fix** — `/tmp` rather than `$repo`. If it
   passes pre-fix the mechanism is not what §1 says; stop and report.
   *[r2: ANSWERED — confirmed.]*
2. **T5/T6 results, reported either way.** A pre-fix failure in either means §3's
   "must not change" is wrong and the spec needs widening.
   *[r4: tmux half ANSWERED — T5 rebuilt (r3), mutation-proved at the real
   execution site `:850`. T6 half remains OPEN — not run — §4.4.]*
3. **Confirm no other `runShell` caller is affected.**
   *[r2: ANSWERED.]*
4. **[r2, OPEN] Run T6 against an isolated throwaway herdr session.** Does
   `runLayoutLoop:641`'s `--cwd splitCwd` actually place the pane there? Not a
   blocker (§4.4); a standing item that closes W-1's last unverified branch. If it
   comes back wrong, that is a **new** defect needing its own spec, not an
   amendment to this one.
5. **[r2, OPEN] Which transport was in play during the original incident?** §7.1.
   Decides whether 0035 removes the user's friction or fixes a real bug adjacent
   to it. Cheaper to ask than to discover later.
6. **[r4: ANSWERED.] Rebuild T5 so it actually tests the claim.** It must drive
   `roster.mjs create --spawn` with a process cwd ≠ `--cwd` and assert
   `#{pane_current_path}` on the resulting tmux window — the test the table in
   §4.2 always described, not a standalone tmux invocation that mirrors
   `roster.mjs`'s command construction by hand. Deleting `"-c", splitCwd` from the
   `execFileSync` argv at `:850` (the real execution site) must make the rebuilt
   T5 fail. A test that passes with the feature deleted is worse than no test,
   because it is scored as coverage. Evidence: rebuilt T5 passes post-fix;
   confirmed FAILING when `:850`'s `-c` argument is stripped; restored, byte-diff
   verified clean; T5 passes again. Deleting `:254`'s plan string does NOT make it
   fail — that line is display-only, never executed.

---

## 6. Acceptance

1. Terminal-transport peers launch in the `--cwd` directory, not `roster.mjs`'s
   process cwd (T1, T2).
2. Paths with spaces work (T4).
3. The direct-Bash path with no `--cwd` is unchanged (T3).
4. herdr placement recorded as unverified with a loud skip naming the open claim
   (T6, §4.4); tmux placement verified (T5, r3).
5. A launch retry uses the same directory as its first attempt (T7).
6. `create --spawn` and `spawn-one` report the launch directory per member (T8).
7. Every `spawnShape` branch returns a non-null `launch_cwd` (§4.3).
8. `mcp/server.mjs` is unmodified.
9. `:126`'s derivation is unmodified.
10. Every pre-existing test still passes — particularly
    `test-roster-create-spawn.sh`, `test-roster-spawn-one.sh`,
    `test-roster-spawn.sh`, `test-roster-layout-splits.sh`.
11. §5 items 1–3 answered in the implementation report; items 4–5 carried forward
    as **open**, not closed.

---

## 7. The ExitWorktree lead — my read: **low priority, probably a red herring, do not pursue now**

The Implementor found that Claude Code's `ExitWorktree` tool refuses to remove a
worktree with uncommitted changes unless `discard_changes` is set, and flagged the
phrasing match to *"refused to unlock the work tree."*

**The phrasing matches; the mechanism does not.** `ExitWorktree` refuses to
**remove** a worktree. The user's peer was trying to **enter** one. A refusal to
tear something down does not prevent entry, so on its face this cannot be what
blocked the architect.

It stays *possible* only in an indirect form: an agent flailing at a mislocated
state tried `ExitWorktree`, was refused, and reported that refusal as the reason
it could not proceed — a real message attached to the wrong cause. That fits the
300K-token picture, and would make the "lock" a red herring the *agent*
introduced rather than a mechanism.

**Record it, do not chase it.** The user cannot recall the error text, so there is
nothing to match against, and Tier 1 does not depend on the answer. Cheap settle
if it ever matters: grep the incident session's transcript for `refus|lock|worktree`.

**0034 §5.1's withdrawal stands.** I over-claimed once that no lock was involved;
I am not now claiming the opposite on this evidence either.

### 7.1 [r2] A question the T6 skip surfaced, and it is not a small one

The reason T6 could not be run is that **this session is ambiently inside a live
herdr pane.** That is a fact about the user's normal working environment, and it
bears directly on W-1.

`detectTransport` (`:231-239`) selects herdr when the herdr environment is
present. If the user's orchestrator sessions habitually run under herdr — as this
one does — then **the transport in play during the original incident was plausibly
herdr, not terminal**, and 0035 fixes a real defect that is not the one that cost
them 300K tokens.

This is the same shape as the fork problem raised before the W-1 experiment (case
(i) vs. case (ii)): a fix that lands cleanly and changes nothing the user notices.
Not asserted — the terminal defect is real, confirmed, and should ship regardless.

**Ask the user, or check the incident transcript, before treating W-1 as closed:
was the incident session running under herdr, tmux, or neither?**

- **terminal** → 0035 is the fix; W-1 closes.
- **herdr** → 0035 is correct but insufficient; §5 item 4 becomes urgent rather
  than standing, and is no longer merely a coverage gap.
- **tmux** → T5 says the placement is right, so the friction came from elsewhere
  and W-1's diagnosis needs revisiting.

Does not block the commit. Blocks declaring the user's problem solved.

---

## 8. Out of scope

- **Tier 2 — recovery for an already-mislocated peer.** Its own spec, still gated
  on the unanswered half of 0034 §8.2. The Implementor's partial answer —
  *SessionStart cwd is fixed at boot by construction; whether a live `cd`
  propagates to later hooks needs harness-level confirmation* — establishes the
  launch-time binding but not the post-launch question, and that is the question
  that decides whether Tier 2 is cheap or expensive.
- **W-6** (0034 §4) — detecting a mislocated peer. Independent, small, worth
  landing regardless; `resync` already holds both values it would compare.
- **The tmux quoting issue** (§4.2). File separately.
- **W-2 through W-5** (0034 §6). Unchanged priority.
- **0034 §7.3's cross-consistency test.** Still unlanded, still recommended, still
  independent of everything here.

---

## 9. Confidence

**High** on the fix itself. The mechanism is confirmed by live reproduction rather
than reading, the change is one options argument threaded through two functions,
and the derivation logic — the part 0027/0032 kept getting wrong — is untouched.

**Lower on whether it closes the user's complaint**, for one reason: §7.1's
scoping question — one question to the user answers it. (tmux placement is no
longer a reason — T5 now verifies it end-to-end, mutation-proved at `:850`.)

**No Ultra-Advisor escalation.** No security, auth, migration, or concurrency
dimension; the blast radius is one transport branch of one command.

---

## 11. Error record

A declaration sitting beside the real call, in the same function, describing the
same command, is an attractor for exactly this — it reads as the implementation
and reviews as the implementation. Every claim about the tmux branch must be
anchored at `:850`, and any claim about `:254` must say "plan output" in the same
sentence.
