# Spec 0006 — `disband` kills by default; the safe form becomes opt-out

Status: **final** (2026-08-22)
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Team, Orchestrator, Check-in registry)
Related: `docs/specs/0002-roster-spawn-defects.md` §8.1/§8.2/§8.3 — **this spec reverses §8.2** (see §2);
`docs/specs/0004-roster-layout.md` §12 item 5 (the execute-vs-emit boundary, which this spec does
**not** move); `docs/specs/0005-roster-create-spawn-launches.md` §2.1 (the start-but-never-stop
asymmetry this spec is the other half of)

## 1. Goal

Per explicit user direction, `roster.mjs disband` with no flags becomes the **kill-with-confirm** path
instead of the current remove-only path. The old behaviour — remove `team.json`, never touch a live
session — survives behind a new opt-out flag.

The user chose a **CLI-level default flip** over a skill-only change, with the reversal of `0002` §8.2
made explicit to them. This document exists because `0002` is shipped and committed, and by this
directory's own convention a reversal of an already-shipped decision arrives as a new spec, not as an
in-place edit of the old one — the same convention `0002` itself followed when it reversed `0004`'s
original self-exclusion rule.

## 2. This is a reversal — stated plainly

`0002` §8.2 reads, in full:

> ### 8.2 Why not just make plain `disband` always kill
>
> Rejected: it would silently invert a documented, deliberate safety default, and would make `disband`
> unsafe to run reflexively (e.g. from a script, or as a "just in case" cleanup step) the way it
> currently is. A separate opt-in form keeps the safe default and adds the convenience, rather than
> trading one for the other.

**That decision is reversed.** Not refined, not clarified — reversed. The user has decided to trade the
safe default for the convenience, which is exactly the trade §8.2 declined to make, and has done so
knowing that is what §8.2 said.

Two of §8.2's three claims still stand and are not disputed here:

- *"a documented, deliberate safety default"* — true. It is documented in `0002` §8.1/§8.3, in
  `skills/agent-roster/SKILL.md:279-310`, and asserted in `tests/test-roster-disband.sh:50-53`. §7
  reconciles all three.
- *"silently invert"* — this is the one claim this spec **defeats rather than accepts**. Nothing about
  the inversion is silent: it has its own numbered spec, it renames the prose rather than editing it in
  place, and §7 requires every encoding of the old invariant to be explicitly rewritten. Silence was a
  property of the change §8.2 imagined, not of this one.

The third claim — *"unsafe to run reflexively"* — is the substantive one, and §3 shows it does not
survive contact with how the two-call contract actually works.

## 3. The flip makes bare `disband` *less* destructive at the CLI, not more

This is the load-bearing finding of this spec and the reason its risk is far lower than §8.2's framing
implies. It is not a rationalisation of the user's decision; it falls out of reading the current arm.

**Today**, `hooks/roster.mjs:531-538` — plain `disband`, no flags — reads `team.json`, **deletes it**
(`:536`), and prints the member list. It is a destructive call. It destroys the registry rather than a
session, but the registry is precisely what holds the `transport_id`s needed to find those sessions
later. A reflexive `disband` today loses the ids and leaves the panes running: the worst of both, and
the exact failure `0002` §8.1's ordering note calls "back to hand-hunting pane ids".

**After this spec**, bare `disband` is the *first* call of the two-call contract: it emits the close
plan and **writes nothing**. `team.json` survives untouched. Destruction requires a second, explicit
`--commit`.

So the reflexive-invocation risk §8.2 worried about inverts:

| Invocation | Today | After 0006 |
|---|---|---|
| `disband` (bare, e.g. from a script) | **deletes `team.json`** | read-only; emits a plan; deletes nothing |
| destructive step | implicit in the bare call | requires explicit `--commit` |
| sessions killed by `roster.mjs` | never | **still never** — see §4 |

The system-level effect is more destructive only when a *human* is in the loop to confirm the plan and
a *skill* runs the emitted commands. An unattended script that reflexively calls `disband` and ignores
stdout now does strictly less damage than it does today.

**This does not make the change free.** The real exposures are (a) callers that today rely on bare
`disband` actually removing the file — §5, and this includes the automatic stale-Team sweep, which is
the sharpest edge in this spec; and (b) a mistyped opt-out flag falling through to the new default —
§6. Both are addressed as requirements, not notes.

## 4. What this spec does NOT change: `roster.mjs` still executes nothing destructive

`0002` §8.3 is **unchanged and reaffirmed**:

> `roster.mjs disband --kill --plan` prints the close commands; `--commit` removes `team.json`. Neither
> call runs a close command — the skill runs them, between the two. … "May split a pane" did not become
> "may close one".

That holds verbatim under the new default. The flip changes **which plan bare `disband` produces**, not
what `roster.mjs` is permitted to do. Specifically:

- `roster.mjs` still never invokes `herdr pane close`, `tmux kill-pane`, or any other close verb. The
  command strings at `:520-527` are still *emitted*.
- `0004` §12 item 5's boundary is not moved by this spec. `0005` moves it (to permit starting a
  process); this spec moves it not at all. The asymmetry `0005` §2.1 names — **`roster.mjs` may start a
  process and may not stop one** — is deliberate and is preserved here.
- The confirmation prompt stays in the skill, which is the only layer that both runs the closes and can
  talk to a human. A CLI cannot meaningfully confirm anything when its caller is an LLM.

Anyone reading this spec as licence to let `roster.mjs` execute a close has misread it. Say so in
review.

## 5. New command surface

```
roster.mjs disband                      # emit the close plan; read-only          (was: --kill --plan)
roster.mjs disband --commit             # remove team.json                        (was: --kill --commit)
roster.mjs disband --keep-sessions      # remove team.json, close nothing         (was: bare disband)
```

### 5.1 Bare `disband` — the new default

Behaviour is **byte-identical to today's `disband --kill --plan`** (`:515-529`): read `team.json`,
build the `close` array by the team's recorded transport, print `{"close": [...]}`, exit 0, write
nothing. No team → `{"disbanded": false, "reason": "no active team"}`, exit 0, unchanged.

Output shape is unchanged from `0002` §8.3:

```json
{"close": [{"role": "architect", "name": "wrangl-architect", "route": "peer",
            "transport": "herdr", "transport_id": "w2:p3",
            "command": "herdr pane close w2:p3"}, …]}
```

`command` stays `null` for terminal-routed, subagent-routed, and any member with no live
`transport_id`. The per-transport construction at `:520-527`, including the tmux `kill-pane` line at
`:524`, is not touched by this spec.

**Forward reference (spec 0008 §5.6, additive, not a rewrite of this decision):** for the herdr
transport, bare disband now resyncs the member list in memory (never persisted) before building
`close`, so the plan targets each member's current pane rather than its spawn-time one. This relaxes
"output shape unchanged" additively — a sibling `resync` key and a per-member `resync_status` field
are added, every field named above keeps its name, position, and meaning — and "writes nothing" is
preserved exactly as stated here. tmux and terminal disband are untouched.

### 5.2 `--commit` — unchanged, and no longer requires `--kill`

Behaviour is byte-identical to today's `disband --kill --commit` (`:504-512`): remove `team.json`,
print `{"removed": "<path>"}`, or `{"removed": false, "reason": "no active team"}` if none. Takes no
other arguments and does not re-read the member list.

**The two-call contract and all of its guarantees are preserved exactly.** They are the reason this
spec is safe to write at all, and none of them may be collapsed while changing the default:

- `team.json` survives a declined confirmation — bare `disband` wrote nothing.
- `team.json` survives a failed close — removal is a separate call the skill makes afterwards.
- Close-before-remove ordering is structural, not conventional: the skill cannot run the closes before
  it has received them, so any removal folded into the emitting call necessarily happens *before* the
  closes. That is `0002` §8.1's ordering note, and it is untouched.
- An interrupted teardown is resumable, because the ids are still on disk.

### 5.3 `--keep-sessions` — the opt-out

Behaviour is **byte-identical to today's bare `disband`** (`:531-538`): read `team.json`, remove it,
print

```json
{"disbanded": true, "team_id": "...", "members": [{"role": "...", "name": "...", "transport_id": "..."}]}
```

or `{"disbanded": false, "reason": "no active team"}`. Single call — no `--plan`/`--commit` split,
because nothing destructive to a live session happens and there is nothing to confirm.

**Name rationale.** It states positively what is preserved (the sessions), so its meaning is readable
at a call site with no memory of what the default is. Rejected alternatives:

- `--no-kill` — a negation of a flag that no longer exists as the operative one, and short enough to be
  typed reflexively, which is the opposite of the requirement. See §6: it must be *rejected*, not
  quietly accepted as a synonym.
- `--registry-only` — accurate but requires knowing that `team.json` is "the registry".
- `--safe` — vague, and invites the reading "this call is safe" rather than "sessions are kept".

### 5.4 `--kill` — accepted and ignored

`--kill` is accepted as a no-op for backward compatibility and is **not** documented in `SKILL.md`.
Every `0002`-era invocation therefore keeps working with identical behaviour:

| `0002`-era invocation | After 0006 | Same behaviour? |
|---|---|---|
| `disband --kill --plan` | `--kill` ignored → bare `disband` | **yes** |
| `disband --kill --commit` | `--kill` ignored → `--commit` | **yes** |
| `disband --kill` (bare) | `--kill` ignored → bare `disband` | **no** — see below |
| `disband` (bare) | now the close plan | **no** — this is the flip |

Bare `--kill` today fails at `:514` with an error naming `--plan` and `--commit`. After this spec it
behaves as bare `disband`: it emits the plan. That is a strictly read-only outcome, so the changed
behaviour cannot destroy anything — but it *is* a changed behaviour and `tests/test-roster-disband.sh:63-64`
asserts the old one. §7 handles that assertion explicitly rather than letting it fail as a surprise.

### 5.5 Combination rules

- `--keep-sessions` with `--commit` → exit 2. Contradictory: one says "remove and close nothing", the
  other is half of the closing contract. Do not silently pick one.
- `--keep-sessions` with `--kill` → exit 2, same reason, even though `--kill` is otherwise ignored. An
  explicitly contradictory pair is a caller who does not know what they are asking for.
- `--plan` is accepted as an explicit synonym for bare `disband` (read-only, emits the plan).

  Note what this fixes in passing: **today, `disband --plan` without `--kill` deletes `team.json`** —
  `opts.plan` is only read at `:514`, inside the `opts.kill` branch, so a bare `--plan` falls through
  to `:531` and removes the file. A flag whose entire meaning elsewhere in this CLI is "read-only,
  show me what you would do" currently destroys the registry. After this spec it is read-only, as its
  name has always implied.

## 6. Unknown flags must be rejected — a required compensating control

**Requirement: the `disband` arm rejects any flag it does not recognise with exit 2, printing usage
that names `--commit`, `--keep-sessions`, and `--plan`. It performs no action, destructive or
otherwise, before exiting.**

This is not a nicety and is not optional. `parseArgs` (`:47-65`) folds every `--flag` into a map, and
the `disband` arm reads exactly three keys — `opts.kill` `:500`, `opts.commit` `:504`, `opts.plan`
`:514`. Everything else is silently discarded.

Under the current safe default that is harmless: a mistyped flag degrades to the *safe* path. Under the
flipped default the polarity reverses — `--keep-session`, `--keepsessions`, `--no-kill`, `--dry-run`
all silently become **bare `disband`**, which is now the kill plan. A user reaching for the safe form
and fumbling its spelling gets handed the destructive plan, and if they are in the habit of confirming
prompts, the sessions die.

The typo cases are precisely the ones where a caller has *demonstrated* they want the safe path. Falling
through to the destructive default there is the single worst outcome this change can produce, and it is
entirely preventable.

Two consequences worth stating:

- `--no-kill` must **fail**, not be accepted as a synonym. It is the name a user is most likely to
  guess, and the exit-2 message naming `--keep-sessions` is how they learn the real one. Accepting it
  silently would mean two documented-nowhere spellings for the same safety-critical flag.
- **Scope.** This spec requires unknown-flag rejection for the `disband` arm only. Extending it to
  every subcommand is a larger, and probably correct, change — but it would alter the behaviour of
  commands this spec is not otherwise touching, so it is **out of scope here** and should be its own
  spec. Do not do it as a drive-by while implementing this one.

## 7. Reconciliation — every encoding of the old invariant

The invariant *"plain `disband` never kills"* is recorded in three places. All three are being
deliberately inverted. Each must be **rewritten as a reversal**, never quietly edited — the same
standard `0002` applied when it reversed `0004`'s self-exclusion rule.

### 7.1 `docs/specs/0002-roster-spawn-defects.md`

`0002` is shipped and is **not rewritten**. Add a short amendment note at the top of the file, in the
style of `0004`'s:

> **Amended 2026-08-22 by `0006-disband-kill-by-default.md`.** §8.2's decision — keep plain `disband`
> safe, put the destructive form behind `--kill` — is **reversed** by user direction. Bare `disband` is
> now the close-plan call and `--keep-sessions` is the safe form. §8.1's two-call contract, §8.1's
> close-before-remove ordering, and §8.3's emit-don't-execute rule are all **unchanged** — only which
> flag selects which path changed. Read §8.2 as history.

Nothing in §8.1 or §8.3 is edited. Their content is preserved wholesale by §5.1–§5.3 above; only the
flag that selects each path differs, and that mapping is the table in §5.4.

### 7.2 `skills/agent-roster/SKILL.md:279-310`

The section currently opens:

> Run `roster.mjs disband`. It only removes `team.json` — it never kills panes or sessions, since they
> may hold work that already cost tokens.

That sentence is now false and is the highest-risk line in the repo after this change: it tells the
orchestrator the default is safe. Rewrite the section so that:

1. Bare `disband` is documented as **step 1 of the teardown contract** — it emits the close plan and
   writes nothing.
2. The existing numbered steps 1–4 (`:294-305`) are preserved almost verbatim, with step 1's command
   changed from `roster.mjs disband --kill --plan` to `roster.mjs disband` and step 4's from
   `--kill --commit` to `--commit`. The confirmation prompt at step 2, the per-member outcome reporting
   at step 3, and the "a failed close is reported, not fatal" rule are unchanged.
3. The closing warning (`:307-310`) — *"never call `--commit` before running the closes … never skip
   `--plan`'s confirmation step"* — is **kept**, with `--plan` re-worded to "the plan call". It is more
   important now than it was, not less: the call it guards is now the default one.
4. `--keep-sessions` is documented as the form to use when the sessions should survive, with the
   original rationale carried over: *they may hold work that already cost tokens*.
5. `--kill` is **not** documented (§5.4).
6. The stale-Team sweep paragraph (`:286-288`) is updated per §7.4.

### 7.3 `tests/test-roster-disband.sh`

The suite encodes the old default directly. Required changes, assertion by assertion — note that most
of the file is unchanged, because the *behaviours* are unchanged and only their selecting flags moved:

| Line | Current assertion | Action |
|---|---|---|
| 50-51 | plain `disband` reports `disbanded=true`, no `close` key | **move to `--keep-sessions`**, otherwise unchanged |
| 52-53 | plain `disband` removes `team.json` | **move to `--keep-sessions`**, otherwise unchanged |
| 57-58 | plain `disband`, no team → `disbanded=false` | **move to `--keep-sessions`**, otherwise unchanged |
| 63-64 | bare `--kill` exits 2 naming `--plan`/`--commit` | **delete** — `--kill` is now ignored (§5.4). Replaced by the new assertions below. |
| 69-76 | `--kill --plan` herdr close commands, null commands, no removal | **re-target to bare `disband`**; assertions themselves unchanged |
| 80-86 | `--kill --commit` removal, and removal on an already-gone team | **re-target to `--commit`**; assertions themselves unchanged |
| 91-92 | `--kill --plan` tmux `kill-pane` | **re-target to bare `disband`**; unchanged |
| 98-99 | `--kill --plan` terminal, all commands null | **re-target to bare `disband`**; unchanged |
| 105-106 | `--kill --plan` succeeds with no herdr on `PATH` (emits, does not execute) | **re-target to bare `disband`**; assertion unchanged and now *more* load-bearing — it is the runtime proof of §4 on the default path |

New assertions required:

1. **Bare `disband` does not remove `team.json`.** The direct inverse of the old `:52-53`, and the
   single assertion that proves the flip landed on the safe side of §3.
2. **Bare `disband` emits a `close` key.** The direct inverse of the old `:50-51`.
3. **`--keep-sessions` emits no `close` key** and its output is byte-identical to the pre-change plain
   `disband` output, from a recorded fixture. This is what makes "the old behaviour survives intact" a
   checkable claim rather than an assurance.
4. **Unknown flag rejection** (§6) — `disband --no-kill`, `disband --keep-session`, and
   `disband --nonsense` each exit 2, `team.json` is still on disk, and stdout contains no `close` key.
   Assert *all three* of those conditions: an implementation that prints usage but has already emitted
   the plan passes a weaker check.
5. **`--keep-sessions --commit` and `--keep-sessions --kill`** each exit 2 with `team.json` intact.
6. **`--kill` is a no-op**: `disband --kill --plan`, `disband --kill`, and bare `disband` all produce
   identical stdout; `disband --kill --commit` and `disband --commit` produce identical stdout.
7. **`--plan` is read-only** — `disband --plan` leaves `team.json` on disk. This is the regression test
   for the §5.5 defect, which exists today.

### 7.4 The stale-Team sweep — the sharpest edge in this change

`SKILL.md:286-288` documents an automatic sweep:

> A stale Team (dead orchestrator pid, or older than the fixed 24h cap) is also swept automatically on
> the next plain top-level SessionStart — that safety net needs no action here.

**This is an unattended, non-interactive caller of teardown, and the flip is exactly the kind of change
that breaks it silently.** If that sweep shells out to plain `roster.mjs disband`, then after this spec
it stops removing anything and starts printing a close plan into a hook context where nothing will ever
run it or confirm it. The stale `team.json` then persists indefinitely and the safety net is gone —
with no error anywhere, because emitting a plan is a successful exit 0.

**Required implementation step, before any other change lands:**

1. `grep -rn 'disband' agent-hierarchy/` across hooks, skills, scripts, and tests — every occurrence,
   not just the obvious ones.
2. For **every** call site that is not a human-or-LLM-driven teardown — the SessionStart sweep first
   among them — route it to `--keep-sessions`. An unattended sweeper must never emit a kill plan, and
   must certainly never have one run for it: a Team is swept because it is *stale*, and a pane
   belonging to a stale Team may well have been reused by something else entirely.
3. If the sweep does not shell out to `roster.mjs disband` at all but clears `team.json` directly, note
   that in the implementation report and take no action — but confirm it by reading, rather than
   assuming it, because the failure is invisible.

This step is a **verification gate**, not a suggestion. The reversal is not safe to ship until every
non-interactive caller has been found and re-pointed.

## 8. Change list

| File | Change |
|---|---|
| `hooks/roster.mjs` | Rework the `disband` arm (`:498-539`). Bare/`--plan` → today's `:515-529` plan body. `--commit` → today's `:504-512` body, no longer gated on `opts.kill`. `--keep-sessions` → today's `:531-538` body. `--kill` accepted and ignored. Unknown-flag rejection with exit 2 (§6). Add `keep-sessions` to `BOOL_FLAGS` (`:47-65`) — a boolean not in that set swallows the next argv token. Update the usage string. The close-command construction (`:520-527`, incl. tmux `:524`) is untouched. |
| `skills/agent-roster/SKILL.md` | Rewrite `:279-310` per §7.2, incl. the sweep paragraph per §7.4. |
| `tests/test-roster-disband.sh` | Re-target and add assertions per §7.3. |
| `docs/specs/0002-roster-spawn-defects.md` | Amendment note only, per §7.1. §8.1 and §8.3 not edited. |
| SessionStart sweep call site (location TBD — §7.4) | Route to `--keep-sessions`. |

## 9. Verification

1. Bare `disband` on a live Team: emits `close`, exit 0, `team.json` **still on disk**.
2. `disband --commit`: `team.json` gone, `{"removed": "<path>"}`.
3. `disband --keep-sessions`: `team.json` gone, no `close` key, output byte-identical to the
   pre-change plain-`disband` fixture.
4. Full teardown end to end through the skill: plan → confirm → closes run → `--commit`. Declining at
   the confirmation leaves `team.json` and every session intact.
5. A close command failing mid-teardown: reported per member, not fatal, `--commit` still runs
   afterwards (`0002` §8.1, unchanged).
6. `disband --no-kill` / `--keep-session` / `--nonsense`: exit 2, `team.json` intact, no `close` on
   stdout.
7. `--keep-sessions --commit` and `--keep-sessions --kill`: exit 2, `team.json` intact.
8. No herdr binary on `PATH`: bare `disband` still succeeds and emits — the runtime proof that
   `roster.mjs` executes nothing (§4).
9. `grep -rn 'disband'` shows no non-interactive caller invoking the bare form (§7.4).
10. A stale Team is still swept on the next top-level SessionStart, with `team.json` actually removed.

## 10. Confidence and escalation

**High** — that the mechanism is right. Every behaviour already exists in the file and is already
tested; this spec re-points which flag selects which one and adds a guard. The three properties that
make teardown safe — the two-call split, close-before-remove ordering, and emit-don't-execute — are
carried through untouched, and §9 items 1/4/8 check each one directly.

**High** — that `roster.mjs` gains no destructive capability (§4). This is the property that keeps the
blast radius bounded, and it is asserted at runtime by §9 item 8, not merely stated.

**High** — §3, that bare `disband` becomes read-only and so the reflexive-script risk §8.2 named is
reduced rather than realised. This is checkable from the current source, not a judgement call.

**Medium** — §7.4, the sweep. This is the one place the change can fail silently and in a way no
existing test would catch, and I could not resolve it by reading: I do not know the sweep's call site.
It is written as a verification gate for exactly that reason. If the Implementor finds the sweep does
shell out to bare `disband`, that discovery does not change this design — it just makes step 2
mandatory rather than a confirmation.

**No Ultra-Advisor escalation recommended** — but the reasoning matters more here than the verdict, so
it is recorded rather than asserted.

Inverting a documented safety default for a destructive action is normally exactly the shape that
warrants escalation. Three things pull this one back inside the Architect's remit:

1. The decision itself is the user's, made explicitly and with `0002` §8.2 in front of them. What is
   left to me is *how* to invert it safely, which is a design question, not a judgement about whether
   the risk is worth taking.
2. `roster.mjs` acquires no new destructive verb (§4). The blast radius is "which JSON plan is printed",
   not "what gets killed".
3. The CLI-level effect of the reflexive invocation the safety default existed to protect is
   **strictly safer** after the change than before (§3).

**One thing does warrant a note to the user even though they have already decided**, and it is not the
reversal itself:

> §6 (unknown-flag rejection) and §7.4 (re-pointing the stale-Team sweep) are not refinements — they are
> the two things that make the flip safe, and both are invisible in the diff's headline. Without §6, a
> mistyped `--keep-sessions` hands the user the kill plan, and a typo is strongest evidence they wanted
> the safe path. Without §7.4, an automatic safety net stops working and reports success while doing so.
> If implementation pressure ever trims this spec, these are the two items that must not be the ones
> that get trimmed.

That note is about implementation discipline, not about revisiting the decision. The decision stands.
