# Spec 0014 — herdr pane labeling for spawned peer panes

Status: **specified, NOT implemented, amended once. ALL 5 NEEDS-EVIDENCE ITEMS
RESOLVED. Nothing blocks implementation. Amendment (a) CORRECTS a wrong
insertion point in the original draft — see §2.2, which is my error and is
recorded as one.**

Author: Architect. Brief: `20260825-160350-a9ok`.
Amendment (a): `20260825-163957-mini`, folding in probe `20260825-160920-1jeo`
and one point confirmed directly by the user.
Spec number verified free — `0013` was the highest present.

**Amendment log**
- **(a)** — Probe answered all 5 evidence items. **Insertion point MOVED** from
  `roster.mjs:535` (which is pre-launch, so `herdr agent start` clobbers the
  label) into `launchMember()`, after that member's own launch. Mechanism
  DECIDED as `pane rename`. Visual render confirmed by the user. §5 gains a
  hazard that only exists at the new placement. Tests rewritten for ordering.

---

## 1. Goal

Every peer pane `agent-hierarchy` spawns should carry a border label of
`claude - <member-name>` (e.g. `claude - claudetools-architect`) instead of
herdr's generic auto-detected kind label `claude`, so panes are visually
identifiable by agent rather than all reading alike.

**This is a workaround for a missing herdr feature**, and the user's own
recipe says so: `show_agent_labels_on_pane_borders` is a **boolean, not a
template**, and no config key composes kind + name. **If herdr ever gains a
label template, this entire spec should be retired, not extended.** Record
that at the top of the implementation so it is discoverable later.

---

## 2. Acceptance (a) — how does roster.mjs actually spawn? BOTH, and it EXECUTES

Cited from source. The brief was right to insist on verifying this.

| transport | pane creation | agent launch | selected at |
|---|---|---|---|
| `herdr` | `runLayoutLoop()` → `herdrCall()` → `execFileSync("herdr", …)` **`:280`/`:514`**; new id read at `:396` from `.result.pane.pane_id` | command string built at **`:184`** — `` herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags} `` — run inside `launchMember()` via `runShell()` **`:461`** | `detectTransport()` **`:169`** |
| `tmux` | `execFileSync("tmux", ["new-window","-P","-F","#{pane_id}",…])` **`:518`** | string at **`:194`**, same `launchMember()` path | same |
| `terminal` | none | none | same |

So: **herdr is genuinely in the loop today**, and so is raw tmux. Which one
runs is a runtime branch, not a historical succession.

### 2.1 CORRECTION to a previously-recorded belief (original draft)

A note in this project's durable memory stated that `roster.mjs`'s
`transport_id` is *"used only at spawn time and at disband (emit-only, never
executed by roster.mjs itself)."*

**Stale.** `roster.mjs` executes child processes in **four** places
(`:169`, `:280`, `:461`, `:518`). Adding a rename to the spawn path is
therefore **not** a new architectural carve-out; it joins an execution path
that already exists. Corrected in the durable store.

### 2.2 CORRECTION to this spec's own original insertion point — MY ERROR

The original draft put the rename at **`:535`**, immediately after
`m.transport_id = panes[i]`, and gave as its third justification: *"the recipe
requires the rename run after `herdr agent start`, and `:535` is after
`runShell()` has executed the `:184` launch string."*

**That sentence was false, and I did not verify it before writing it.** The
actual structure of `layoutAndLaunch()` (`:506-540`):

```
:534-536   peerMembers.forEach((m, i) => { m.transport_id = … });   // ← :535 is HERE
:538       const settled = await Promise.allSettled(
             peerMembers.map((m) => launchMember(m, transport)));    // ← launch happens HERE
```

`:535` is **unambiguously before** any launch. The probe independently
confirmed the consequence: **`herdr agent start` clobbers a pre-set label**,
so the original placement would have produced a rename that silently did
nothing.

**Two lessons recorded rather than quietly patched:**

1. I asserted an ordering from adjacent line numbers instead of reading the
   control flow. Line proximity is not execution order — `:535` and `:538` are
   three lines apart and on opposite sides of the only `await` in the function.
2. **The original §4.1 offered three justifications for `:535`, and the other
   two were sound.** A wrong reason travelled inside a mostly-right argument.
   The two surviving reasons still hold and are carried into §4.1 below —
   which is precisely why the error was easy to miss.

---

## 3. Acceptance (e) — uniform across all roles

**Yes. No role-specific naming, and no per-role branch.**

The label is `claude - ${member.name}`. `member.name` already encodes both the
role and (under spec 0011) the team prefix — `claudetools-architect`,
`T-reviewer`. A role switch would duplicate naming logic that
`lib-config.mjs` already owns, and would drift from it.

**Applies to:** every peer member spawned on the `herdr` transport.
**Does not apply to:** `terminal` transport (no pane; `transport_id` is `null`
at `:535`) and the `tmux` transport (no herdr to call).

---

## 4. Insertion point and pane id — acceptance (b) and (c)

### 4.1 Insertion point: inside `launchMember()`, after that member's launch

**Put the rename inside `launchMember()` (`roster.mjs:473-498`), immediately
after its launch command has completed successfully and before it returns.**

Reasons:

1. **Ordering is mandatory, not stylistic.** NEEDS-EVIDENCE (1) resolved:
   `herdr agent start` **clobbers a pre-set label**. The rename must follow the
   launch of *that specific member*. `launchMember()` is the only scope where
   "after this member's launch" is expressible.
2. **Both callers still route through it** — `create --spawn` (`:605`) and
   `spawn-one` (`:1138`) both reach `layoutAndLaunch()` (`:506`), which calls
   `launchMember()` for every member at `:538`. **One insertion still covers
   both commands. Do not add a second call site in either handler.**
   *(Carried from the original draft — this reason was sound and survives the
   correction.)*
3. **Both values are in scope**: `m.name` and `m.transport_id`, the latter
   assigned at `:535` before `:538` dispatches the launches.

**Rejected alternative — a second pass after `:538`'s `Promise.allSettled`.**
It would work and is simpler to write, but launches are **concurrent**
(`:538` maps `launchMember` across all members). A post-pass appends N serial
`herdr` round-trips to the critical path *after* every launch has finished,
partially undoing the concurrency that spec 0003 exists to provide (`create`
standing up N members in roughly the time of the slowest single member).
Renaming inside `launchMember()` overlaps each rename with the other members'
launches and costs nothing.

### 4.2 The pane id — and why BOTH of the recipe's methods are WRONG here

The recipe offers `herdr pane current` or `$HERDR_PANE_ID`. **Neither is
usable, and either would label the wrong pane.**

- `roster.mjs:512` reads `const self = process.env.HERDR_PANE_ID;` and
  `:513` **fails hard if it is absent** (`needs HERDR_PANE_ID in the
  environment`). So on the herdr path this variable is **guaranteed present
  and in scope** — it is the orchestrator's own pane, used as the split
  origin. Labeling it renames the orchestrator after whichever peer it most
  recently spawned.
- `herdr pane current` resolves relative to the **calling** process — the same
  orchestrator pane, same wrong answer.

**The recipe is not wrong; it is written for a different case.** It describes
a pane labeling *itself*. We are labeling a pane we just created *for someone
else*. That inverts which pane "current" means.

**Use `m.transport_id`** — assigned at `:535` from `panes[i]`, originating at
`:396` as `splitResult.result.pane.pane_id`. It is the same value `disband`
(`:984`) and `move` (`:1069`) already rely on.

> **Implementor: `self` is right there, always populated, and wrong.** This is
> the single most likely way to implement this spec incorrectly *and have it
> look like it worked* — the orchestrator's own pane visibly relabels, which
> reads as success. §8 test 2 asserts no rename ever targets it.

### 4.3 Mechanism: `pane rename`, NOT `report-metadata`

**DECIDED: `herdr pane rename <pane-id> claude - <member.name>`.**

The probe established that `report-metadata`'s `display_agent` is *additive*
(adds a field, overrides nothing) while `rename` overrides the detected label
— and that **neither field reaches `terminal_title`**, the field every other
visible pane name comes from.

That looks like an argument for `report-metadata`. **It is not, and the reason
is an evidence asymmetry rather than a property comparison:**

| | renders visually? | additive? |
|---|---|---|
| `pane rename` | **YES — confirmed directly by the user**, who had it tested in a live herdr window (that test is what produced the original recipe) | no, overrides |
| `report-metadata` | **UNKNOWN — no evidence it renders at all** | yes |

**Choosing "additive" over "confirmed to work" would be choosing a property
over a result.** Additivity is only a benefit if the field is displayed
somewhere, and nothing establishes that it is.

> **Do not transfer the render confirmation across mechanisms.** The user
> confirmed **`pane rename`**, because `pane rename` is what the recipe used.
> It says nothing about `display_agent`. The `terminal_title` finding applies
> to both equally and therefore distinguishes neither — herdr's border UI
> evidently reads the label field directly rather than via `terminal_title`.

**`rename`'s override cost is now known to be small:** NEEDS-EVIDENCE (2)
resolved **NO** — the label does not freeze out live agent state. That was the
one finding that could have killed this design, and it did not.

**Filed alternative, not an open item:** if anyone later confirms
`display_agent` renders, `report-metadata` becomes the better mechanism on
additivity grounds and §4.3 should be revisited. **Nobody needs to go looking
— this is a note for whoever finds themselves already holding that answer.**

### 4.4 The call

Invoke through the existing `herdrCall()` (`:280`, `execFileSync` with an argv
**array**) — not `runShell()`. No shell quoting of a label containing spaces,
and it matches every other structured herdr command in the file.

```
["pane", "rename", m.transport_id, "claude", "-", m.name]
```

**NEEDS-EVIDENCE (5) resolved:** an `execFileSync` argv array with a bare `-`
element works; no escaping workaround is needed.

---

## 5. Failure handling — acceptance (d)

**Rename is BEST-EFFORT. A rename failure must never affect spawn success.**

### 5.1 A hazard that exists ONLY at the new insertion point

`:538` is `await Promise.allSettled(peerMembers.map((m) => launchMember(m,
transport)))`, and `:539` maps a **rejected** settlement to
`launch_status: "failed"`.

> **Therefore an unhandled throw from the rename — inside `launchMember()` —
> is INDISTINGUISHABLE from a launch failure.** A cosmetic label error would
> mark a perfectly healthy, running agent as failed, and `create --spawn`
> would report `partial`.

This hazard did not exist at the original `:535` placement and is a direct
consequence of moving the call. **Wrap the rename in a `try`/`catch` that
swallows everything** — non-zero exit, throw, timeout, malformed JSON, `herdr`
missing. Nothing may escape into the promise.

### 5.2 The rest

1. **Do not change the member's launch status.** The values `launchMember()`
   returns (`launch_status`, `launch_result`, `retried`) and the `partial`
   flag at `:621` must be computed exactly as today. A cosmetic label is not a
   launch outcome.
2. **Skip, do not attempt, when inapplicable:** `transport !== "herdr"`, or
   `m.transport_id` falsy. Use the existing `herdrOnPath()`
   (`lib-roster.mjs:42`) for the installed check rather than adding a second
   mechanism.
3. **Surface it quietly:** on failure, add a non-fatal field to that member's
   result (e.g. `label: "failed"`, omitted on success). **Do not write to
   stderr** — `roster.mjs`'s stderr already carries the level-defaulting
   warning that callers parse.
4. **Only rename after a SUCCESSFUL launch.** If the launch command failed,
   skip the rename: the pane may hold no agent, and labeling it
   `claude - <name>` would assert something false about a failed member.

**Explicitly out of scope:** retrying, verifying the label took effect, and
reverting on teardown. `herdr pane close` (`:984`) destroys the pane.
**NEEDS-EVIDENCE (4) resolved:** the label survives `pane move` at the herdr
layer, so `roster.mjs move` (`:1069`) needs **no** re-label step and §4.1's
one-call-site claim stands.

---

## 6. Files

**Modified:**
- `agent-hierarchy/hooks/roster.mjs` — one helper plus one guarded call inside
  `launchMember()` (`:473-498`).
- `.claude-plugin/plugin.json` — version bump. **Standing repo rule: the root
  `marketplace.json` must be bumped in the same commit.**

**Must NOT change:** `hooks/lib-roster.mjs`, `hooks/lib-config.mjs`, the
member-naming logic, `spawnShape()` (`:184`/`:194`), `layoutAndLaunch()`'s
control flow (`:506-540` — add nothing at `:535`), the `disband`/`move`
command builders, or anything computing launch status.

**Do NOT add a `--label` / `--no-label` flag** unless the user asks. It is a
config knob for a value that never varies (§3).

---

## 7. NEEDS-EVIDENCE — ALL RESOLVED

| # | question | answer | folded into |
|---|---|---|---|
| 1 | does `herdr agent start` clobber a pre-set label? | **YES** | §2.2, §4.1 — **this is what moved the insertion point** |
| 2 | does a manual label freeze out live agent state? | **NO** | §4.3 — the finding that could have killed the design, and did not |
| 3 | is `report-metadata` additive? | **YES**, but no evidence it renders | §4.3 — decided *against* it on evidence asymmetry |
| 4 | does the label survive `pane move`? | **YES** | §5.2 — no re-label step needed |
| 5 | argv array with a bare `-`? | **fine** | §4.4 |

**Separately confirmed by the user, not by probe:** the `pane rename` label
**does render visibly** in a live herdr window, despite not reaching
`terminal_title`. Recorded as user-confirmed at §4.3. **Not to be re-derived
or re-tested.**

---

## 8. Test plan (acceptance (f))

New: `agent-hierarchy/tests/test-herdr-pane-label.sh`, in the style of the
existing 32 test scripts. **All herdr interaction is stubbed** — a fake `herdr`
earlier on `PATH` that logs its argv, as the existing herdr tests already do.
**No test may require a real terminal.**

1. **Right label, right pane.** Spawn two members against the stub; assert one
   `pane rename` per member, each pairing that member's own name with **that
   member's** `transport_id`.
2. **Never the orchestrator's pane.** Assert no `pane rename` targets the value
   of `HERDR_PANE_ID`. **This is the §4.2 trap and the test that catches the
   plausible wrong implementation.**
3. **Ordering.** Assert each member's `pane rename` appears **after that same
   member's `agent start`** in the stub's log. Per-member, not globally —
   launches are concurrent, so a global ordering assertion would be both weaker
   and flaky.
4. **Rename failure does not fail the launch.** Stub exits non-zero for
   `pane rename` only. Assert the member's `launch_status` is **not** `failed`,
   `partial` is unchanged, and `team.json` is written with the correct
   `transport_id`. **This is §5.1 and it is the highest-value test here** —
   the new insertion point is inside the promise whose rejection means
   "launch failed".
5. **Rename *throw* does not fail the launch.** Stub that makes the rename
   raise rather than exit non-zero. Same assertions as 4. Separate test because
   a `try`/`catch` that only handles exit codes passes 4 and fails 5.
6. **No rename after a failed launch.** Stub fails `agent start` for one
   member. Assert no `pane rename` is issued for that member (§5.2 item 4).
7. **`herdr` absent.** Remove the stub from `PATH`. Assert spawn succeeds and
   no rename is attempted.
8. **Non-herdr transports.** Force `transport=tmux`, then `terminal`. Assert
   **zero** `herdr` invocations of any kind.
9. **Regression:** existing suite passes unchanged. Note the known
   order-dependent flake in `test-roster-create-spawn.sh` (independently
   reproduced clean 3/3 standalone, unrelated) — not evidence of a regression
   here.

**Stated limit, honestly:** every test above asserts that *the right command
was issued*, never that *the border visually changed*. That gap is closed by
the user's direct confirmation (§7), not by this suite. **Do not read a green
run as proof the feature works.**

---

## 9. Risks for the Implementor

1. **Do not put the rename at `:535`.** It is pre-launch and `agent start`
   clobbers it (§2.2). The original draft said otherwise and was wrong.
2. **Do not use `HERDR_PANE_ID` or `herdr pane current`** (§4.2). Both are in
   scope, both are guaranteed populated on the herdr path, and both are wrong.
3. **Swallow every rename failure inside `launchMember()`** (§5.1). An escaping
   throw marks a healthy agent as a failed launch.
4. **One call site** (§4.1). Not one in `create --spawn` and one in
   `spawn-one`.
5. **Use `herdrCall()`, not `runShell()`** (§4.4) — the label contains spaces.
6. **Do not switch to `report-metadata` because it is "cleaner"** (§4.3). It is
   additive but unproven; `rename` is proven to render.
7. **Version bump in two places.**

---

## 10. Confidence

**High**, and higher than the original draft — every open question is now
answered, and the one wrong claim in v1 was found and corrected rather than
shipped.

The residual uncertainty is not about the design but about the feature's
worth, and it is small: the label overrides herdr's detected label, which is
now known **not** to suppress live agent state. If a future herdr release adds
a label template, retire this (§1).

**No Ultra-Advisor escalation.** A handful of guarded lines, cosmetic,
best-effort, trivially reversible, touching no consent, security, or data
path.
