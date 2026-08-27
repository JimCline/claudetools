# Spec 0009 — global scope is never used silently, and a real peer is the default fallback

Status: **specified, fully closed, implemented, reviewed (PASS WITH NITS).** No open
NEEDS-EVIDENCE items.

Precedent: 0001 (roster), 0004 (layout), 0005 (`create --spawn`), 0006 (disband), 0008 (resync/move).

**Amended 2026-08-23 (a)** — requirement 3's scope widened to `move`. **Superseded by (b);
do not implement (a).**

**Amended 2026-08-23 (b)** — requirement 3 retracted: `/agent-roster` already is the
first-class surface, and the reported friction came from bypassing it. Two of (a)'s
premises disproved against SKILL.md (§2.4).

**Amended 2026-08-23 (c)** — two user decisions, and the resolution of an apparent
conflict between (b) and them:

1. **§3 flips.** Global-scope **role configuration** is now gated too, not only
   global-roster **identity**. These are two different predicates over two different
   mechanisms; §3 and §4.3 keep them separate on purpose. Knock-on effects in §8.2 (the
   `subagents` route stops being an escape), §4.7 (one verb, two scopes), and §8.11
   (a vocabulary trap that would make a naive implementation silently never fire).
2. **`spawn-one` is reinstated (§6), narrowly.** This is **not** a reversal of (b).
   (b) cut requirement 3's *full-team tooling* — `--help`, `--mode` defaulting, the
   `move` scope — and that stays cut. `spawn-one` returns as a **requirement 2**
   mechanism, justified **solely** by §8.5's partially-live gap: `create` refuses to run
   against an existing Team (`roster.mjs:732`), so there is no way to stand up one missing
   role mid-session. It is explicitly **not** justified by (a)'s two disproved premises
   (§2.4), which remain retracted.
3. **§4.4 stays strict.** Answer-or-stay-denied is not softened for the config gate, and
   the narrowed escape set in §8.2 is accepted with it. User's decision, recorded.

**Amended 2026-08-23 (d)** — evidence returned on five of six items, all confirming the
spec as written. Two consequences inline: §4.7 (`msg.mjs route` is bespoke, so the new
verb needs its own handler, not a parameterisation) and §6.3 step 7 (no Team upsert helper
exists in `lib-roster.mjs`, so `spawn-one` composes `readTeam` + `writeTeam` itself).

**Amended 2026-08-23 (e)** — **item 2 resolved: `--split` IS required with `--tab`.**
§6.6's first pre-decided branch is now the specification; change-list items 8 and 9 are
ungated. **Every NEEDS-EVIDENCE item is closed and the spec is ready to implement.**

**Amended 2026-08-23 (f)** — **two spec-defects found by review, both spec-text-only; the
implementation was faithful to the wrong text and does not need rebuilding beyond one
string.** (1) §6.4 mandated §4.8's scope-A wording on the CLI path, which claims something
was "declined" — but `roster.mjs` cannot read session gate records and can never know that.
§6.4 now carries its own text; the roster is *unconfirmed* there, not declined.
(2) §10.1's malformed-`gates.jsonl` bullet said "exit 0, no decision"; the reachable and
correct behaviour is **fail closed**. Reworded to match, no code or test change.
**Consequence for the Implementor's nit list:** the shared-string duplication between
`roster.mjs`'s `requireAllowGlobal` and the hook's `globalRosterDenyReason` is **resolved
by (f), not by de-duplication** — see §6.4's note. The two strings are now required to
differ. Do not merge them.

Requirements 1 and 2, verbatim:

1. *"if there's not a roster for the current repo either in the repo or at the user level
   scoped to that repo, it has to AskUserQuestion before using a global scoped agent.
   Never use a global scoped agent roster without prompting first."*
2. *"spawning a peer agent ought to be the goto action."*

Requirement 3 is retracted (§2.4, §6.5).

---

## 1. Goal

- **§4** — a hard PreToolUse gate with **two independent predicates**. No dispatch to a
  hierarchy role proceeds while either (a) the roster resolves to global scope, or (b) that
  role's configuration comes from the user-scope file — until the user has answered a
  recorded, session-scoped question **for that scope**. Not a reminder; answer-or-stay-denied.
- **§5** — the "no live peer" fallback prompt inverts: **stand up a real peer** becomes
  the recommended first option. No new persisted state is needed to make the choice
  stick — §5.3 explains why the existing live-peer branch already enforces it.
- **§6** — `roster.mjs spawn-one <role>`, scoped to the one job `create` cannot do:
  stand up a single role against a live Team. Plus §6.6's `--split` documentation fix.

No `--help`, no `--mode` defaulting, no change to `create` / `disband` / `resync` /
`move` beyond §6.6's one-line guard, no change to `resolveRoster`'s precedence, no change
to the tier gate.

---

## 2. Current behaviour, established from source

### 2.1 The global fall-through is silent and already plumbed

`resolveRoster(cwd)` (`hooks/lib-config.mjs:304-322`) walks `ROSTER_LEVELS` —
`repo-user`, `repo`, `global` (`rosterLevelPaths` at `:272-280` names the three paths;
`global` is `userConfigPath()`, i.e. `~/.claude/agent-hierarchy.json`) — and returns the
**first level with a non-empty `roster.members`, in its entirety, no merging**
(`:297-302` doc comment). It returns `{level, route, layout, members, path}`.

**Both predicates are already on the resolved config object.** `resolveConfig` calls
`resolveRoster` at `:491` and returns `roster` / `rosterLevel` at `:506-507`; it also
returns `sources` (`:501`), the per-role map of which config layer supplied that role,
populated at `:452`. The unconfigured early-return at `:376-393` returns
`rosterLevel: null` and an all-`"default"` `sources`.
`pretooluse-route-gate.mjs:136` already calls `resolveConfig(cwd)`.

**Consequence for implementation: the gate needs no new resolution plumbing.** Both
predicates are boolean tests on values already in hand. This is why §4 is a small change
and not a refactor.

The only place either surfaces to a human today is `statusReport` (`lib-config.mjs:726`,
`Roster: level=… route=… path=…`), which the Orchestrator sees only if it goes looking.

### 2.2 The route gate: what exists, and where §4/§5 attach

`hooks/hooks.json:15` registers three PreToolUse hooks on matcher `Agent|Task|SendMessage`,
in this order: `pretooluse-ultra-gate.mjs`, `pretooluse-msg-gate.mjs`,
`pretooluse-route-gate.mjs`. They are independent and each fails open.

`pretooluse-route-gate.mjs` (whole-file behaviour documented at `:2-49`):

- `:125-162` — resolve `role`. Dispatch: `hierarchyRoleOf(toolInput.subagent_type)`.
  SendMessage: Team member by name (`:155`) → config peer targets (`:157`) → roster
  instance name (`:160`).
- `:164-174` — **route-ask**, once per session, `{type:"route-ask", session_id}` in
  `gates.jsonl`. Deny with `askReason` (`:85-100`), which instructs an AskUserQuestion
  with three options and a `msg.mjs route <peers|prefer-peers|subagents> --session <id>`
  record. **Unanswered, it falls through to the `peers` default** (`:173` comment) — the
  precedent contrast for §4.4.
- `:178-206` — enforcement per route. Under `peers` with a live instance: deny once
  (`:186-190`, `peersDenyReason`). Under `peers` with **no** live instance
  (`:191-198`): ask once per (session, role) via `peerFallbackAskReason` (`:110-112`),
  record `{type:"peer-fallback-ask", session_id, role}`, and **the identical re-issue then
  passes regardless of the answer** (`:197`).
- `:209-225` — the tier gate. Untouched by this spec.

`peerFallbackAskReason` (`:110-112`) today offers, verbatim, `"Yes, spawn a subagent
(Recommended)"` and `"No, wait — I'll start the peer myself"`. **That is the inversion
requirement 2 names** — the subagent is literally labelled Recommended, and the peer
option is framed as manual work with no procedure attached.

Note `:165`'s guard: the entire routing block runs only for
`PEER_ELIGIBLE_ROLES`. §4.6 explains why the config gate must sit **outside** it.

### 2.3 Liveness, and the scope it is actually keyed on

`roster(dir, resolved, repoBasename)` (`hooks/lib-hier.mjs:474-512`) reads
`latestRoster(dir)` from `peers.jsonl`, drops `status === "down"`, and marks `live` by
`pidAlive(rec.pid)` for `up` records or an age window for `seen`/`briefed`.

`dir` is `hierarchyDir(cwd)` = **`~/.claude/hierarchy/<basename(cwd)>`**
(`lib-hier.mjs:8`). So live-peer enumeration is scoped by **repo basename**, not by
realpath. See §8.6.

### 2.4 The `/agent-roster` surface is complete — two claims of (a) were wrong

*Retained from (b). These retractions stand; (c) does not restore them.*

`skills/agent-roster/SKILL.md` already documents the whole Create sequence:

- `:52` lists `create [--plan | --commit ... | --spawn --mode <m>]`.
- `:153-154` states that **`--spawn` only launches the panes — it writes nothing; the Team
  does not exist until the follow-up `create --commit --verified <json> --transport <t>
  --roster-level <L>`** runs (0008 §12's fix, landed).
- `:156` states that until then `resync`, `move`, and `disband` **cannot see the members
  at all**.
- `:161` gives the invocation as `create --spawn --mode <layout_plan.mode> …` — the mode
  comes **from the `--plan` output**.
- `:268-271` gives the `--commit` follow-up and says to build `--verified` from
  `--spawn`'s `members[]`.

Therefore:

1. **`create --spawn` failing on a missing `--mode` is unreachable on the documented
   path.** A bare-CLI robustness nit, not a first-class defect. **No `--mode` default is
   specified for `create`.**
2. **`roster.layout` is NOT ignored.** `resolveMembersPlan` computes `layout_plan`
   (`roster.mjs:399`, via `layoutPlan(resolved, …)`) from the resolved roster, and `:161`
   feeds `layout_plan.mode` back in. (a)'s claim was an artifact of reading `createSpawn`
   (`:443-471`) in isolation from the phase sequence that calls it. **Retracted.**

Recorded because it is the root cause of the reported friction: **`roster.mjs`'s per-function
source does not carry the phase ordering; the skill does.** An agent reading the CLI instead
of the skill will reliably reconstruct an incomplete sequence.

§6.6 is the one place that pattern inverts: there the **skill** is wrong and the runtime is
right. See its note.

§6 does not otherwise contradict this. `spawn-one` is not a second way to do what the skill
does — it is the one operation the skill's Create flow **cannot** reach (§6.1).

### 2.5 The overlap question: there is no competing mismatch guard

The brief asked whether an already-decided "mismatched peer from a different repo should
be flagged" rule subsumes §4. **It does not, because no such rule is implemented.** A
case-insensitive `mismatch` grep over `agent-hierarchy/` (excluding `node_modules`,
`.git`) returns 12 hits, **all** in `tests/*.sh` (plugin-version assertions),
`agents/task-runner.md:37`, `docs/specs/0002`, `docs/specs/0004`, and `docs/retired/*`.
Zero in `hooks/*.mjs`. `lib-peer.mjs` contains no `cwd` reference at all.
**Confirmed by the Orchestrator (NEEDS-EVIDENCE item 1, resolved): no such guard exists
elsewhere either.**

**Even had one existed it would not subsume §4:**

| | a runtime cwd-mismatch guard | §4's gates |
|---|---|---|
| fires on | a *live* peer whose cwd differs from ours | configuration resolving to global/user scope |
| catches | dispatching to an already-running foreign session | the roster and role config for agents we are about to **create** |
| when | after the foreign agent exists | before anything is created |

The dangerous case — an empty repo silently adopting another project's roster shape — has
no live peer to mismatch against. Build §4; **do not also build a runtime mismatch check
as part of this spec.**

---

## 3. Scope: BOTH identity and configuration are gated

*Amended (c). (b) gated identity only and flagged the alternative as the user's call. The
user chose the broader reading; this section is rewritten accordingly.*

**GATED — scope A, roster identity.** An Agent/Task dispatch to a peer-eligible role, or a
SendMessage peer brief, while `resolveRoster` resolves to the **global** level. The harm:
members that may belong to an unrelated repo/project treated as valid dispatch targets.

**GATED — scope B, role configuration.** Any dispatch to a hierarchy role whose
`model` / `effort` / `dispatch` / `peer` settings were supplied by the **user-scope**
config file — `resolved.sources[role] === "user"`. The harm: a repo with no local config
silently inheriting another project's tier and dispatch decisions.

**NOT GATED — built-in defaults.** `sources[role] === "default"` (`lib-config.mjs:373`,
seeded from `ROLE_DEFAULTS`) is the plugin's own shipped configuration, not a global
scope the user set for a different project. Gating it would fire on **every dispatch in
every unconfigured repo**, which is not a policy, it is a wall. See §8.10 — this is the
single most likely implementation error in the spec.

**Why two predicates and not one.** They are computed by different mechanisms over
different files and can fire independently: a repo-level roster (scope A silent) coexists
happily with user-scope role config (scope B firing), and vice versa. Collapsing them
into one boolean would make one of them unreportable, and the two questions have genuinely
different answers — "yes, use those peers" does not imply "yes, use that model tier".
§4.7's record carries a `scope` field for exactly this reason.

**Cost, stated honestly.** Scope B fires in more situations than scope A — including
plain subagent dispatch (§8.2) and every dispatch from a session whose cwd is `$HOME`
(§8.9). Combined with §4.4's strict answer-or-stay-denied, which the user confirmed is not
to be softened, this is the most intrusive mechanism in the plugin. That is the accepted
tradeoff, not an oversight.

---

## 4. Requirement 1 — the global-scope confirm gate

### 4.1 Mechanism: a hard PreToolUse gate, in the existing route gate

**Recommended: mechanical, in `pretooluse-route-gate.mjs`, not injected protocol text.**

1. **Injected text is advisory and demonstrably lossy.** The observed failure — treating
   global members as valid targets — happened *with* the roster already resolvable, and
   the same session also bypassed a complete SKILL.md (§2.4). Documentation is not
   enforcement; this spec has two independent demonstrations of that.
2. **The precedent is explicit.** The routing-preference gate asks once via
   AskUserQuestion, records with `msg.mjs route`, then enforces silently; the msg-file and
   ultra gates likewise deny mechanically.
3. **Both predicates are free** (§2.1).
4. **The gate fires at the moment of use.** "Never *use* … without prompting" is a
   statement about the dispatch. Only a PreToolUse decision attaches there.

**A new hook file is NOT warranted.** `pretooluse-route-gate.mjs` already resolves the
config, the role, the hierarchy dir, and the session id, and owns every peer-vs-subagent
decision. A fourth hook would duplicate all of it and add an ordering question against the
route-ask.

### 4.2 Placement

Insert **between the role resolution (`:162`) and the routing-preference block (`:164`)**.

**It must run before the route-ask, not after.** `askReason` (`:85-100`) enumerates live
peers into its prompt and offers "Peer agents only (Recommended)". Under an unconfirmed
global roster, that prompt presents unconfirmed peers to the user as the recommended
route — laundering exactly what §4 exists to stop.

### 4.3 The two predicates

Evaluate **scope A first**, then scope B. Both require `resolved.enabled` (already
checked at `:137`) and a resolved `role`.

| scope | predicate | additional condition |
|---|---|---|
| A — roster identity | `resolved.rosterLevel === "global"` | `PEER_ELIGIBLE_ROLES.includes(role)`, and not (`isDispatch` && effective route is `subagents`) — §8.2 |
| B — role config | `resolved.sources[role] === "user"` | none beyond a resolved `role` — §4.6 |

`rosterLevel === null` never fires scope A (§8.1). `sources[role] === "default"` never
fires scope B (§3, §8.10).

If both fire on one dispatch, deny for **scope A first** and mention that scope B is also
pending, so the user is not surprised by a second deny (§8.7). Do not merge them into one
question.

### 4.4 Answer-or-stay-denied — strict, confirmed by the user

This gate does **not** adopt route-ask's fall-through-when-unanswered behaviour (`:173`),
**for either scope**. Requirement 1 says *never* without prompting; a gate that asks once
then passes on the identical re-issue satisfies the letter and defeats the purpose, since
the re-issue is precisely what an unconvinced model does next.

**The user was asked whether scope B should be softened to route-ask's fall-through given
its wider blast radius (§8.2), and answered: keep it strict.** Recorded here so a future
reader does not "fix" it as an inconsistency.

Persisted state in `gates.jsonl`, via the existing `appendGate` / `hasGate`:

| record | meaning |
|---|---|
| `{type:"global-scope-ask", session_id, scope}` | the question has been put once for this scope (loop suppression only; authorises nothing) |
| `{type:"global-scope", session_id, scope, answer}` | the user's answer, `scope` ∈ `roster`\|`config`, `answer` ∈ `allow`\|`deny` |

Per firing scope:

| recorded answer for that scope | action |
|---|---|
| `allow` | fall through. Never ask again this session **for that scope**. |
| `deny` | `decide("deny", …)` with §4.8's refusal text. Every time — a standing no, not one-shot. |
| none | append the `-ask` record if absent, then `decide("deny", …)` with §4.7's text. If the ask record exists and no answer does, **still deny**, with a shorter "you were asked and did not record an answer" reason. |

An `allow` for one scope **never** implies the other.

### 4.5 Scope A's prompt

Name the resolved roster's **path** and **member names** — `resolved.roster.path` and
`resolved.roster.members[].name` are both in hand:

```
ah: no roster is configured for this repo (checked repo and repo-user). The roster
resolving here is the GLOBAL one at <resolved.roster.path>, members:
<name(role), …>. It may belong to an unrelated project.
Ask the user with AskUserQuestion, exactly these options in this order:
  "Create a roster for this repo (Recommended)" — run the /agent-roster skill's Init
     then Add flow for this repo, then re-issue.
  "Use the global roster for this session" — records allow; no further prompting for this scope.
  "Subagents only this session" — node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" route subagents --session <id>
Record the answer: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" global-scope roster <allow|deny> --session <id>
Then re-issue this exact dispatch. Say in one line what you recorded.
```

Option 1 is Recommended: a repo roster is the correct end state, and it also satisfies
requirement 2's precondition.

**Option 1 points at the skill, not a raw `roster.mjs init` line.** `SKILL.md:66-69`
documents that `add`/`edit`/`remove` without `--level` act on whichever level resolves and
print which; `:69` that `init` comes first; `:71-73` constrains valid roles. An inlined CLI
fragment would re-create the partial-sequence failure §2.4 diagnosed.

**Option 3 is a genuine escape for scope A only** — see §8.2.

### 4.6 Scope B's prompt, and why it sits outside the peer-eligible guard

Scope B must be evaluated for **every** hierarchy role `hierarchyRoleOf` resolves, not
only `PEER_ELIGIBLE_ROLES`. `task-runner` and `ultra-advisor` take their model and effort
from the same config layers, and a subagent dispatch to either borrows user-scope settings
just as a peer-eligible role does. `:165`'s existing guard is therefore **too narrow for
scope B**; scope B's block must sit outside it (scope A stays inside).

**Dedupe against `pretooluse-ultra-gate.mjs`**, which already gates `ultra-advisor`
dispatch and runs first (`hooks.json:15`). Two denies on one ultra dispatch is
user-hostile noise. Rule: **if the role is `ultra-advisor`, scope B does not fire** — the
ultra gate's own approval already puts a human in the loop on that dispatch, which is the
protection scope B exists to provide.

```
ah: <Role>'s configuration here comes from your USER-scope config
(~/.claude/agent-hierarchy.json): model=<m> effort=<e> dispatch=<d>. This repo has no
project or repo-user config for <Role>, so those settings may have been set for a
different project.
Ask the user with AskUserQuestion, exactly these options in this order:
  "Use the user-scope settings for this session (Recommended)" — records allow.
  "Set this role for this repo instead" — run the /agent-roster skill's Add/Edit flow
     at repo level, then re-issue.
  "Stop — I'll decide later" — do not dispatch; say you are blocked on <Role>.
Record the answer: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" global-scope config <allow|deny> --session <id>
Then re-issue this exact dispatch. Say in one line what you recorded.
```

**Scope B's option 1 is Recommended, and scope A's is not.** Deliberate asymmetry:
inheriting a model tier from a user-scope default is ordinary, intended use, and the gate
exists to surface it once rather than to discourage it. Inheriting *another project's
peers* is the actual hazard. Do not "harmonise" these.

**Scope B's answer is per-session, not per-role.** One `config allow` covers every role
this session. Per-role would mean up to five prompts in a session that dispatches widely —
disproportionate to a question about which config file won.

### 4.7 `msg.mjs global-scope <roster|config> <allow|deny> --session <id>`

New verb. Validates the scope against `["roster","config"]` and the answer against
`["allow","deny"]`, appends `{type:"global-scope", session_id, scope, answer}` to
`gates.jsonl`, prints a one-line confirmation. Last write wins per scope, so a mid-session
change of mind works with no extra machinery.

**It needs its own handler.** NEEDS-EVIDENCE item 3 is resolved: `msg.mjs`'s `route` verb
is **bespoke**, not a generic answer-recording path. Copy its shape — argument validation,
`appendGate`, one-line confirmation — but do not attempt to parameterise `route` into
serving both. Two small handlers beat one flag-driven one.

Two scopes, one verb — approved as proposed. This is the **only** new command surface in
§4.

### 4.8 Refusal text (answer = `deny`) — hook side only

*Amended (f): this text is for the **hook**, which can read `gates.jsonl` and therefore
knows a decline actually happened. It is **not** reusable on the CLI path — see §6.4.*

Scope A:
```
ah: the global roster was declined for this session. Create a repo roster with the
/agent-roster skill, or switch to subagents (msg.mjs route subagents --session <id>).
```

Scope B:
```
ah: user-scope role configuration was declined for this session. Set <Role> at repo
level with the /agent-roster skill, then re-issue.
```

---

## 5. Requirement 2 — a real peer is the default fallback

### 5.1 What changes

Only `peerFallbackAskReason` (`pretooluse-route-gate.mjs:110-112`) and the branch that
selects it (`:191-198`). No new gate record, no new state.

```
ah: route is peers this session, but no live instance of <Role> exists to route to.
A roster entry for <Role> exists at <level> level (name: <name>).
Ask the user with AskUserQuestion, exactly these options in this order:
  "Stand up the real <Role> peer (Recommended)" — node "$CLAUDE_PLUGIN_ROOT/hooks/roster.mjs" spawn-one <role> --cwd <cwd>
     Then SendMessage the peer instead of re-issuing this dispatch.
  "Spawn a one-off subagent instead" — re-issue this exact dispatch.
  "Neither — I'll start it myself" — do not dispatch; say you are blocked on <Role>.
```

**Amendment (c): option 1 carries the `spawn-one` one-liner.** (b) pointed at the skill
here, because at that point no single command existed that both stood up one role and
persisted it. §6 creates one. For **full-team** Create the skill remains the only
sanctioned path (§2.4, §6.5) — the gate must not inline a `create` fragment.

### 5.2 When the peer option is offered

Offer option 1 only when a roster entry for that role exists at a level this session may
use:

- `resolved.rosterLevel` is `repo` or `repo-user`, **or** it is `global` with a recorded
  scope-A `allow` (§4) — and
- `resolved.roster.members` contains an entry for `role`.

Otherwise omit it and degrade to today's two options with the subagent recommended, plus a
line naming why (`no roster entry for <Role>` / `global roster not confirmed`).
Recommending a command that will fail is worse than not recommending one.

The `rosterLevel === "global"` + no answer case cannot reach here: §4 denied earlier.

### 5.3 Why the choice sticks with no new state

The current branch passes the identical re-issue "regardless of the answer" (`:22-23`,
`:197`). **Left exactly as it is**, and still correct, because the world changes between
the two dispatches:

- User picks **stand up the peer** → the peer session starts and `sessionstart.mjs`
  appends its `status:"up"` record to `peers.jsonl` (`:81-88`) → the next `roster()` call
  sees `live.length > 0` → the dispatch takes the `:186-190` branch and is denied with
  `peersDenyReason`, which says to SendMessage it. **The existing live-peer branch
  enforces the choice.**
- User picks **subagent** → nothing becomes live → the re-issue passes, as today.
- `spawn-one` **fails** → nothing becomes live → the re-issue passes and a subagent is
  spawned. Graceful degradation, not a wedge.

**Do not add a `peer-spawn-chosen` gate record.** It would duplicate a liveness fact
`peers.jsonl` already holds authoritatively, and go stale the moment the peer died.

Accepted consequence: `peersDenyReason` is itself one-shot per (session, role, route)
(`:176`, `:187-190`), so on the *second* re-issue after the peer came up, the dispatch
passes and a subagent is spawned alongside a live peer. Pre-existing reminder-gate
behaviour, unchanged here, recorded in §11.

### 5.4 The recommendation is a default, not a wall

The user can still pick the subagent; `prefer-peers` / `subagents` routes are untouched.
Requirement 2 says "goto action", not "only action".

---

## 6. `spawn-one` — the one operation Create cannot reach

*Amended (c). Reinstated from (a) §6.1, re-justified, and narrowed.*

### 6.1 The justification, and the two it is NOT

**The only justification: §8.5's partially-live gap.** `create` routes through
`resolveMembersPlan` (`roster.mjs:384`), which **refuses to run against a live Team**
(`:732`). So once a Team exists and one member has died — or was never launched — there is
no supported way to stand up that single role. The skill's Create flow cannot express it,
and `create --commit --verified` hand-editing is precisely the archaeology §2.4 forbids.
This is a genuine capability gap, not an ergonomics complaint.

**Explicitly NOT justified by** (a)'s two premises, both disproved in §2.4 and still
retracted: the `--mode` failure (unreachable on the documented path) and
`roster.layout` being ignored (it is not). If the partially-live gap were closed some other
way — say the skill grew a documented single-role flow — `spawn-one` would lose its
justification entirely and should be cut. **Recorded so the cut stays reversible on
evidence.**

### 6.2 Command surface

```
roster.mjs spawn-one <role> [--cwd <path>] [--dry-run] [--allow-global]
```

One required positional. Flag validation follows spec 0006 §6 (unknown flag → loud
`fail`); add `SPAWN_ONE_FLAGS = new Set(["cwd","dry-run","allow-global"])` beside
`DISBAND_FLAGS`/`RESYNC_FLAGS`/`MOVE_FLAGS` (`roster.mjs:59-61`).

**No `--mode` flag.** `spawn-one` sources its layout mode the way `SKILL.md:161` sources
`create`'s: from the resolved plan's `layout_plan.mode` (`roster.mjs:399`). One pane is
being placed, so the mode barely matters, and exposing the flag would re-open the
retracted requirement-3 surface. **This is not the `--mode` defaulting (b) cut** — that was
a change to `createSpawn`'s existing flag, which stays exactly as it is.

### 6.3 Algorithm

1. Validate `<role>` against `PEER_ELIGIBLE_ROLES`; else `fail` listing them.
2. `resolveRoster(cwd)`. Null → `fail("no roster configured for <cwd>; run the
   /agent-roster skill's Init flow")`. Level `global` → §6.4.
3. Find the member for `role`. Absent → `fail` listing the roles the roster does define.
4. `readTeam(dir)`:
   - member present **and live** (pid alive) → `out({spawned:false, reason:"already
     live", member})`, **exit 0**. Idempotent; a duplicate peer is worse than a no-op.
   - member present, not live → replace its record after a successful launch.
   - no team, or no record for this role → append after a successful launch.
5. Resolve the layout mode per §6.2; place one pane via
   `runLayoutLoop({mode, paneCount: 1, self: HERDR_PANE_ID, splitCwd: cwd})`, then the
   existing launch-and-retry path (`roster.mjs:417-441`). **Extract the per-member
   spawn+verify into one function called by both `createSpawn` and `spawn-one`. Do not
   fork it** — same rule as 0008 §5.1's `resyncMembers`. `createSpawn`'s observable
   behaviour must not change. *(`paneCount: 1` confirmed workable — NEEDS-EVIDENCE item 6,
   resolved.)*
   **Correction (`0023` §2.4): `paneCount: 1` is superseded.** "Confirmed workable" only
   established that the call completes and returns one pane id — it did not establish that
   the resulting arrangement honours `roster.layout`, which it does not (a single-candidate,
   `total`-always-2 loop right-splits P0 every time). `0023` fixes this by seeding
   `runLayoutLoop` with the team's live sibling pane ids and deriving the tiling total from
   that seed, rather than passing `paneCount: 1`. Everything else in this step — the liveness
   short-circuit, the merge-write, the persistence requirement, the shared-implementation
   rule — stands unchanged.
6. `--dry-run` → emit the resolved member, mode, and launch command; execute nothing,
   write nothing.
7. On launch success, **merge-write `team.json`** (single writer, whole-file rewrite —
   0008 §3): preserve `team_id`, `created`, `transport`, `roster_level`, and every other
   member; replace or append only this role's record. Create the team with a new `team_id`
   if none exists, taking `roster_level` from step 2. On launch failure, `fail` with the
   error and **write nothing**.
   *Confirmed (item 4): `lib-roster.mjs` has no member-upsert helper, so `spawn-one`
   composes `readTeam` + `writeTeam` itself. Keep the merge inside `spawn-one`; do not add
   a helper with one caller.*
8. Emit `{spawned:true, member:{role,name,transport_id,…}, team_id, roster_level}`.

**Non-negotiable: `spawn-one` persists.** A verb that launched panes without recording
them would reproduce the trap `SKILL.md:153-156` documents, in the one command whose whole
purpose is to be safe to reach for.

### 6.4 Global-scope guard on the CLI path

`spawn-one` and `create --spawn` run as Bash subprocesses; §4's PreToolUse gate cannot see
them. They must not become the laundering path around it.

**Rule:** when `resolveRoster(cwd).level === "global"`, both require `--allow-global` and
otherwise `fail`.

**The CLI's refusal text (amended (f)) — do NOT reuse §4.8's.** `roster.mjs` does not read
`gates.jsonl` and has no session id, so it cannot know whether the user ever declined
anything. §4.8's "was declined for this session" is therefore a false statement on this
path: the roster here is merely **unconfirmed**. Required text:

```
ah: this roster resolves at GLOBAL level (<path>) and may belong to an unrelated project.
Re-run with --allow-global, or create a repo roster with the /agent-roster skill.
```

`<path>` is `resolveRoster(cwd).path`. The flag is deliberately awkward and
self-documenting in a transcript.

**The two texts are required to differ; this is not drift.** The hook knows a decline
happened and says so; the CLI cannot know and must not claim it. A future reader — or a
de-duplication pass — must not collapse `roster.mjs`'s refusal string and the hook's
`globalRosterDenyReason` into one shared constant. They describe two genuinely different
situations. **What IS shared is the predicate** (`resolveRoster(cwd).level === "global"`),
kept as one exported helper so the *rule* cannot drift even though the *wording* is
deliberately distinct.

**A second, weaker gate on the same rule — accepted rather than elegant.** A hook cannot
see inside a Bash subprocess, so a CLI-side check is the only enforcement available.

No CLI equivalent is specified for scope B: `roster.mjs` does not act on
`resolved.roles[role]`, so there is nothing to launder.

### 6.5 Still cut by (b) — listed so absence is not mistaken for oversight

- `roster.mjs --help` / per-verb flag grammar — `SKILL.md:44-64` is that surface.
- `--mode` defaulting in `createSpawn` — unreachable on the documented path (§2.4.1).
- The `move` scope amendment of (a) — except §6.6.
- `move`/`resync` "no active team" message extensions — `SKILL.md:153-156` says it already.
- Anything premised on `roster.layout` being ignored — it is not (§2.4.2).

### 6.6 `--split` IS required with `--tab` — RESOLVED, specified

*Amended (e). Item 2 is closed; this is no longer conditional.*

**Evidence, and why the weaker source loses.** Two sources said optional:
`SKILL.md:62`/`:376` bracket it (`--tab <id> [--split right|down]`), spec 0008 §5.4 step 4
says *"only valid with `--tab`"*, and herdr's own `--help` lists `--tab` and `--split` as
independent optional flags with no requires-together annotation. Against that, the
Orchestrator has **first-hand same-session runtime evidence**: `move` without `--split`
failed with a herdr usage error demanding it; adding `--split right` succeeded.

**Runtime wins over three documents, including herdr's own `--help`.** Note the inversion
of §2.4's lesson: there the skill was right and the CLI source misled; here every document
is wrong and only the observed behaviour is right. The general rule is not "trust the
skill" — it is **prefer the source that was actually executed**.

**The fix, three parts, all mechanical:**

1. **`skills/agent-roster/SKILL.md:62` and `:376`** — drop the brackets in both places:
   `move <name> --tab <id> --split right|down | --new-tab [--workspace <id>] | --new-workspace`.
   Both lines must change; a fix to one leaves the other to mislead the next reader.
2. **`docs/specs/0008-roster-relocate.md` §5.4 step 4** — append a correction note; do not
   silently rewrite the original sentence. Suggested: *"Correction (spec 0009 §6.6):
   `--split` is not merely 'only valid with `--tab`' — herdr **requires** it whenever
   `--tab` is given. Verified at runtime; herdr's `--help` does not annotate the
   dependency."*
3. **`hooks/roster.mjs`, `move` case** — `fail()` on `--tab` without `--split`, beside the
   existing exactly-one-of check. One line. Rationale: forwarding a call that cannot
   succeed turns a clear local error into an opaque herdr usage dump, which is the exact
   friction this spec was opened over.

**Test** (add to whichever `tests/*.sh` covers `move`): `move <name> --tab <id>` with no
`--split` exits non-zero **before** the herdr stub is invoked, and the message names
`--split`. Must be shown to fail against unmodified code.

**Do not** add a `--split` default. Guessing `right` on the user's behalf makes pane
placement silently arbitrary; the flag is one token and the error now says so.

---

## 7. Injected protocol text

**Primary: the gate's deny reasons (§4.5, §4.6, §5.1).** Read at the moment of need,
scoped to the role in question.

**Secondary: two lines in the SessionStart block.** `sessionstart.mjs:112` builds the
directive via `buildDirective` (`lib-config.mjs:618`) and the state block via
`buildStateBlock` (`lib-hier.mjs`). Add to the roster line `statusReport` already formats
(`lib-config.mjs:726`):

- when `rosterLevel === "global"`: `— GLOBAL roster; confirmation required before
  dispatching to its members (spec 0009 §4).`
- when any role has `sources[role] === "user"`: `— role config for <roles> comes from
  user scope; confirmation required (spec 0009 §4).`
- always: `Stand up one missing peer: roster.mjs spawn-one <role> --cwd <cwd>. Full-team
  Create is the /agent-roster skill's job — do not hand-assemble create calls.`

**Do not write a protocol section about peer spawning** — the skill is that document, and
a second copy would drift from it.

`sessionstart.mjs` does not call `resolveRoster` directly (imported at `:51`, unused);
both predicates are available via `resolveConfig` (`:93`, `lib-config.mjs:501,507`).

---

## 8. Edge cases

### 8.1 No roster at any level (`rosterLevel === null`)

Scope A does **not** fire — nothing global is being used silently, and firing would block
every repo that never configured a roster. Scope B is independent and may still fire.
The route-ask and the fallback prompt still run; §5.2 omits the peer option.

### 8.2 Route is `subagents` — an escape for scope A, NOT for scope B

*The principal knock-on of (c)'s §3 flip.*

- **Scope A**: does not fire on an Agent/Task spawn under route `subagents` — no peer
  identity is being used. It **does** still fire on a SendMessage peer brief (the
  `subagents` route denies those at `:179-182`, but scope A runs first and is the more
  specific reason). This keeps §4.5's option 3 a genuine escape.
- **Scope B**: **fires regardless of route, including on a plain subagent dispatch.** A
  subagent borrows `model` / `effort` from the same user-scope config; that is exactly the
  inheritance the user asked to be gated.

**Consequence, accepted deliberately:** "Subagents only this session" is no longer a
universal escape hatch. Scope B's remaining escapes are recording `config allow` or
setting the role at project/repo-user level. Combined with §4.4's strict
answer-or-stay-denied — which the user confirmed — this is the narrowest escape set in the
plugin. Stated plainly here so it is a known cost, not a surprise.

### 8.3 The config or roster file changes mid-session

`resolveConfig` runs per hook invocation, so both predicates are re-read on every
dispatch — no caching to invalidate.

- global → repo (option 1 taken): the predicate stops holding; that scope goes quiet. A
  recorded answer becomes inert, which is correct — it was an answer about a scope no
  longer in effect.
- repo → global: the gate starts firing and the user is asked. Correct.
- Answers are keyed on `(session_id, scope)` only, **not** on file path or contents. A
  path key would re-ask on every trivial edit; the scope flip is the event that matters.

### 8.4 Repo roster configured, zero live members

The case the reporting session hit. Scope A does not fire. The `:191-198` fallback fires
with §5.1's text, peer recommended, `spawn-one` inline.

### 8.5 Repo roster configured, partially live — closed by §6

`roster()` (`lib-hier.mjs:474-512`) is per-role and `:184` filters per-role: a role with a
live instance takes `:186-190` (SendMessage it); a role without takes §5.1's prompt. No
cross-role coupling.

At the CLI, `create` refuses a live Team (`roster.mjs:732`), so this case previously had
no supported command. **§6's `spawn-one` exists for exactly this** — step 4 no-ops on a
live member and step 7 merges rather than replacing the Team. This is the gap (b) recorded
as given-up; (c) closes it.

### 8.6 Two repos with the same basename

`hierarchyDir(cwd)` is `~/.claude/hierarchy/<basename(cwd)>` (`lib-hier.mjs:8`), so
`~/work/api` and `~/oss/api` **share** `peers.jsonl`, `gates.jsonl`, and `team.json`.

Pre-existing, none introduced here: sibling-repo peers can appear live in `roster()`; a
`global-scope` answer file is shared, though the `session_id` key means answers are not.

**Do not fix the basename keying in this spec** — a storage-layout change touching every
hook, deserving its own.

### 8.7 Several gates want to fire on one dispatch

Order: ultra gate → msg gate → scope A → scope B → route-ask → route enforcement → tier.
**Consecutive denies on one logical dispatch are intended** — each carries a distinct
question and a distinct recording command, and the answers go to different records.

Do not merge them into one prompt. Do soften the surprise: §4.3 requires scope A's deny to
mention that scope B is also pending, so the user knows a second question is coming.

`ultra-advisor` is the one exception, and it is handled by suppression rather than
ordering: scope B does not fire for it at all (§4.6).

### 8.8 `role` does not resolve

Scope A inherits `:165`'s existing guard. Scope B requires a resolved `role` and is
skipped otherwise. A SendMessage to an unknown name is unaffected.

### 8.9 cwd is `$HOME`

`lib-config.mjs:363` nulls the project layer when `projectPath === userPath`, and `:364`
nulls repo-user likewise. So in `$HOME` the user scope is the **only** layer, every
configured role reports `sources[role] === "user"`, and **scope B fires on the first
dispatch of every such session**.

Correct by the letter of the requirement and not worth special-casing: one prompt, one
`config allow`, silent thereafter. Stated because it will look like a bug on first
encounter.

### 8.10 `sources[role] === "default"` must never fire — the likeliest implementation error

`lib-config.mjs:373` seeds every role `"default"` before any layer is applied, and
`:376-393` returns an all-`"default"` `sources` when no config file exists anywhere. An
implementation that gates "anything not repo-scoped" fires on **every dispatch in every
unconfigured repo** — a wall, not a policy.

The predicate is exactly `=== "user"`. §10.1 asserts it directly.

### 8.11 The vocabulary trap — `"user"` and `"global"` are the same file

Config scopes are `"user"` / `"project"` / `"repo-user"` (`loadScope` calls at
`lib-config.mjs:360-364`). Roster levels are `"global"` / `"repo"` / `"repo-user"`
(`rosterLevelPaths:272-280`). **Config scope `"user"` IS roster level `"global"`** — the
same `~/.claude/agent-hierarchy.json`, reached by two mechanisms that name it differently.

An implementor who reasonably writes `sources[role] === "global"` gets a predicate that is
**silently never true**, and scope B never fires — a passing test suite and a dead gate.
§10.1 asserts the string explicitly for this reason.

### 8.12 Hook internal error

`:228-229`'s bare `catch { decide(null) }` fails open, as every gate here does.
**Preserve it.** §4 is a correctness guard on a delegation policy, not a security
boundary; a crashing hook must never wedge a session.

Note the distinction from a *malformed record*, amended (f): a corrupt or dropped line in
`gates.jsonl` does not throw — `readJsonl()` skips it — so it never reaches this catch. It
degrades to "no recorded answer", which under §4.4 **fails closed** (deny). The fail-open
catch here covers a genuine crash only. §10.1's shared bullet asserts the fail-closed
property, not a pass-through.

---

## 9. Change list

**Nothing here is gated on outstanding evidence.**

1. `hooks/pretooluse-route-gate.mjs` — scope A block between `:162` and `:164`
   (§4.2–§4.5); scope B block **outside** `:165`'s peer-eligible guard, with the
   `ultra-advisor` suppression (§4.6); `globalRosterAskReason()` /
   `globalConfigAskReason()` / the two refusal builders beside `askReason` (`:85-100`);
   §8.2's per-scope route conditions. Update the header doc-comment (`:2-49`), which is
   this hook's de-facto spec.
2. `hooks/pretooluse-route-gate.mjs` — rewrite `peerFallbackAskReason` (`:110-112`) per
   §5.1. The `:191-198` branch structure is **unchanged** (§5.3).
3. `hooks/msg.mjs` — `global-scope <roster|config> <allow|deny> --session <id>` as its own
   handler (§4.7); `route` is bespoke and must not be parameterised into serving both.
4. `hooks/roster.mjs` — `spawn-one` case in the dispatch switch; `SPAWN_ONE_FLAGS`; usage
   header (`:3-52`) lists it.
5. `hooks/roster.mjs` — extract the per-member spawn+verify path shared by `createSpawn`
   (`:443-471`) and `spawn-one` (§6.3 step 5). One implementation; `createSpawn`'s
   observable behaviour unchanged.
6. `hooks/roster.mjs` — `--allow-global` guard on `spawn-one` and `create --spawn` (§6.4),
   with the **predicate** shared as one exported helper with the hook and the **refusal
   text** deliberately distinct from the hook's (§6.4, amendment (f)).
7. `hooks/roster.mjs`, `move` case — `fail()` on `--tab` without `--split` (§6.6 part 3).
8. `hooks/lib-config.mjs` — `statusReport` (`:692`, roster line `:726`) gains §7's lines.
9. `skills/agent-roster/SKILL.md` — document `spawn-one` and when to prefer it over
   Create; the two gates and `--allow-global`; the new fallback ordering; **and** fix the
   `--split` bracketing at **both** `:62` and `:376` (§6.6 part 1).
10. `docs/specs/0008-roster-relocate.md` — §5.4 step 4 correction note, appended not
    rewritten (§6.6 part 2).
11. `tests/test-roster-global-gate.sh` — new (§10.1).
12. `tests/test-roster-spawn-one.sh` — new (§10.2).
13. Existing `move` test — add §6.6's `--tab`-without-`--split` case.
14. `plugin.json` **and** the root `marketplace.json` — version bump in both, together.

**Must not change:** `resolveRoster`'s precedence or return shape; the tier gate
(`:209-225`); `disband` / `resync` behaviour; `move` behaviour beyond item 7's guard;
`create --plan` / `--spawn` / `--commit` semantics beyond items 5 and 6; `createSpawn`'s
`--mode` handling (§2.4.1, §6.5); the `:228` fail-open catch; `peers.jsonl`'s record shape.

---

## 10. Verification

Every core assertion **must be shown to fail against unmodified code** before its fix
lands — the 0008 §10 rule.

### 10.1 `tests/test-roster-global-gate.sh`

Drive `pretooluse-route-gate.mjs` with synthetic hook JSON on stdin; fixture `HOME`.

**Scope A:**
- Global roster, no answer, Agent dispatch to `implementor` → `deny`, reason names the
  global path.
- **Identical re-issue, still no answer → still `deny`** (§4.4 vs route-ask).
- After `msg.mjs global-scope roster allow --session S` → scope A passes.
- After `global-scope roster deny` → `deny` with §4.8's text, on **every** attempt.
- Repo-level roster → scope A never fires (no `global-scope-ask` record with
  `scope:"roster"`).
- No roster anywhere → scope A never fires (§8.1).
- Route `subagents` + Agent dispatch → scope A **passes**; same with SendMessage → denied
  (§8.2).
- Scope A's deny precedes any `route-ask` record (§4.2) — assert ordering in
  `gates.jsonl`.

**Scope B:**
- Role defined **only** in the user-scope file → `deny`, reason names model/effort.
- **Route `subagents` + plain Agent dispatch → still denied** (§8.2). The sharpest
  behavioural difference (c) introduces; must fail against unmodified code.
- Same role also defined at project level → `sources[role] === "project"` → **never
  fires**.
- **No config file anywhere → `sources[role] === "default"` → never fires** (§8.10).
  Assert explicitly; this is the wall-vs-policy test.
- **Assert the literal string `"user"`, not `"global"`** (§8.11) — e.g. a fixture where
  only the user file defines the role, asserting the gate fires. A test that only checks
  "does not fire" would pass with a permanently-dead predicate.
- `global-scope config allow` → passes for **every** role thereafter (§4.6, per-session).
- Scope-A `allow` alone does **not** satisfy scope B, and vice versa (§4.4).
- Dispatch to `ultra-advisor` with user-scope config → scope B does **not** fire (§4.6).
- cwd `$HOME` → fires on the first dispatch (§8.9).

**Shared:**
- Both scopes firing → scope A's deny mentions scope B is pending (§4.3, §8.7).
- Peers route, no live peer, repo roster → fallback lists the peer option **first** and
  carries the `spawn-one` command (§5.1). Must fail today, where `:111` recommends the
  subagent.
- Peers route, no live peer, no roster entry for the role → peer option omitted (§5.2).
- **Malformed `gates.jsonl` → the hook never crashes; corrupt lines degrade to "no
  recorded answer", which fails closed.** *(Amended (f). The earlier wording, "exit 0, no
  decision", was unachievable: `readJsonl()` skips bad lines rather than throwing, so a
  corrupt file never reaches §8.12's fail-open catch — it presents as an unanswered gate,
  and §4.4 denies. That is also the safer behaviour, and hard-failing `readJsonl()`, which
  every hook shares and which predates 0009, would be worse.)*

### 10.2 `tests/test-roster-spawn-one.sh`

Stub `herdr` as `tests/test-roster-create-spawn.sh` does.

- Repo roster, no team → launches once; `team.json` written with that member,
  `roster_level: "repo"`.
- **Live Team present, `spawn-one` for a role whose member is dead → succeeds and
  preserves `team_id` and every other member** (§8.5 — the whole justification; must fail
  today, where `create` refuses at `:732` and no other verb exists).
- Live member → `{spawned:false, reason:"already live"}`, exit 0, `team.json`
  byte-identical.
- Roster has no `reviewer` entry → non-zero, message lists the roles it defines.
- Unknown role → non-zero.
- Launch fails → non-zero, `team.json` unchanged.
- `--dry-run` → emits the plan; `herdr` stub never invoked; no write.
- Unknown flag → non-zero (0006 §6).
- Global-level roster → non-zero naming `--allow-global`; with the flag → proceeds; same
  two for `create --spawn` (§6.4). The message must say the roster is at GLOBAL level and
  **must not** claim it was "declined" (§6.4, amendment (f)).
- `test-roster-create-spawn.sh` and `test-roster-disband.sh` pass **unmodified** —
  guards the §6.3 step 5 extraction.

### 10.3 `move` — one added case (§6.6)

`move <name> --tab <id>` with no `--split` → non-zero, message names `--split`, and the
herdr stub is **never invoked**. Must fail against unmodified code, which forwards.

### 10.4 Live

In a repo with a configured roster and no live peers: dispatch to a role; confirm the
prompt recommends `spawn-one` and that it runs **verbatim, first try, with no file
reading**; confirm the re-issued dispatch is then denied toward SendMessage (§5.3);
confirm `team.json` shows the new member beside any pre-existing ones. Then kill that peer
and re-run `spawn-one` for it against the now-partially-live Team (§8.5).

---

## 11. Confidence, open questions, escalation

**High confidence:** the mechanical-gate choice (§4.1 — both predicates are already
computed, and this spec contains two independent demonstrations that documentation is not
enforcement); placement before route-ask (§4.2); §5.3's no-new-state argument (it follows
from `peers.jsonl` liveness, not from preference); §2.5's finding that no competing guard
exists (confirmed); §2.4's retractions (grounded in SKILL.md line numbers); and §6.1's
narrowed justification for `spawn-one`.

§3's scope-B predicate was the one design assumption carrying real downside risk, and it is
**confirmed empirically** (§12 item 5): `sources[role]` reports `"user"` when the user
layer wins and `"project"` when shadowed, exactly as §4.3 assumes.

**Medium confidence, flagged:**

- **§4.6's `ultra-advisor` suppression.** A judgement call to avoid double-prompting. If
  the ultra gate is ever made conditional, this suppression silently opens a hole. Worth a
  comment at the suppression site referencing `pretooluse-ultra-gate.mjs`.
- **§4.6's per-session (not per-role) scope-B answer.** Proportionate, but it means one
  `allow` covers a role the user never saw named.
- **§8.3's session-only answer key.** A config edit that keeps the scope unchanged does
  not re-ask.
- **§8.2's narrowed escape set**, combined with §4.4's strictness. The user decided both
  deliberately; the risk is a session burning turns re-issuing rather than recording. If
  that is observed in practice, the first thing to reconsider is scope B's strictness —
  **not** scope A's, which is the requirement's core.

**No open questions for the user, and no outstanding evidence.** The spec is closed.

**Not escalated to Ultra-Advisor.** No security, auth, data-migration, or concurrency
surface: additive gate records in an append-only file, two read-only predicates, one new
`msg.mjs` verb, one new CLI verb over an extracted existing code path, one guard flag, two
prompt rewrites, and three documentation/guard lines. Every mechanism has a working
precedent in this plugin.

**Recorded, out of scope:**

- `peersDenyReason`'s one-shot-per-(session, role, route) behaviour (`:176`) lets a second
  re-issue spawn a subagent beside a live peer (§5.3).
- The basename-keyed `hierarchyDir` collision (§8.6).
- `create --spawn`'s bare-CLI `--mode` requirement (§2.4.1) and its non-persistence
  (0008 §12) — both real, both already documented around, neither this spec's business.
- herdr's `--help` does not annotate the `--tab` → `--split` dependency (§6.6). Upstream,
  not ours; noted so the next reader who checks `--help` and disbelieves §6.6 finds the
  answer here.
- `readJsonl()`'s skip-bad-lines behaviour (§8.12, §10.1) predates 0009 and is shared by
  every hook. It is the reason a corrupt `gates.jsonl` fails closed rather than crashing.
  Not changed here; hard-failing it would be a regression.

---

## 12. NEEDS-EVIDENCE — all closed

**None were run by the Architect;** all six were routed by the Orchestrator and have
returned.

| # | question | status |
|---|---|---|
| 1 | Does a realpath-based cwd-mismatch guard exist outside `agent-hierarchy/hooks/`? | **RESOLVED — none exists.** §2.5 stands; §4 is not subsumed. |
| 2 | Is `--split` required with `--tab`, defaulted, or optional? | **RESOLVED — required.** Runtime failure without it, success with it, overriding SKILL.md, spec 0008, and herdr's own `--help`. §6.6 is now the specification; change-list items 7, 9, 10, 13 follow from it. |
| 3 | Is `msg.mjs route` a generic answer-recording path or bespoke? | **RESOLVED — bespoke.** §4.7: the new verb gets its own handler. |
| 4 | Does `lib-roster.mjs` expose a Team member upsert to reuse? | **RESOLVED — no.** §6.3 step 7: `spawn-one` composes `readTeam` + `writeTeam` itself; no one-caller helper. |
| 5 | Does `sources[role]` report `"user"` only when the user layer actually won? | **RESOLVED — yes.** `"user"` unshadowed, `"project"` when shadowed, exactly as §4.3 / §10.1 assume. |
| 6 | Does `runLayoutLoop({paneCount: 1})` yield one distinct non-empty target? | **RESOLVED — yes.** §6.3 step 5 unblocked. |

**Nothing in this spec is blocked. It is ready for the Implementor.**

---

## 13. Post-review amendments (f) — what the Implementor still has to do

Review verdict was PASS WITH NITS; both spec-defects are text-only. Remaining code work is
**one string**:

- `hooks/roster.mjs`'s `requireAllowGlobal` — replace the borrowed §4.8 wording with
  §6.4's CLI text. Update `tests/test-roster-spawn-one.sh`'s global-level assertion to
  match (§10.2).
- **Nothing else.** §10.1's malformed-`gates.jsonl` change is spec text only; the
  Implementor's existing test already asserts the corrected fail-closed property.
- **Drop the shared-string-duplication nit** from the Implementor's optional list. §6.4
  now *requires* the two texts to differ; de-duplicating them would re-introduce the
  defect this amendment fixes.
