# 0044 — Roster/team scope split: the roster is read-only reference, the team file is private

Status: r3 — implementation in progress. All three forks resolved by the user; two
post-review spec-defects ruled on in r3 (§9 lists them).
Briefs: `20260908-095332-12i8` (+ amendment `20260908-095610-16vk`, fork answers
`20260908-114010-nzp3`, CLI split `20260908-114146-gi03` / `20260908-114221-1trx`,
r3 rulings `20260908-124657-1u06`).

Two things a reader should not have to hunt for:

- **Supersedes spec 0039's auto-spawn.** `add` no longer spawns — §1.10.
- **The CLI surface splits.** `/agent-roster` edits the template, `/agent-team`
  operates the instance — §8. In scope here, not deferred.

## Requirement

From the user, verbatim:

> "The roster was intended as default. The team file was intended to be what the
> orchestrator creates from the roster. The roster should not be edited by
> orchestrators while trying to create a team. It is just a reference. If the user
> wants to create a new team from the roster as is, fine, it should happen. If the
> user wants to create an ad hoc team, fine, it should happen without the need for
> the orchestrator or team itself needing to do anything to the roster. Every
> orchestrator creating a team or ad hoc team members, should have its own team
> file that is used by it and its team. That's the only thing it should ever have
> to edit and only thing team members should reference. So an orchestrator,
> wherever it is working, should have its own private team file that it shares with
> its team and only its team."

And the amendment, verbatim:

> "Yes but I've also seen agents wanting to change the Roster file just because I
> asked it to spawn a team member that differed from the roster, that just
> shouldn't be a factor."

**ANTI-REQUIREMENT (stated by name so nobody re-derives it later).**
*Divergence from the roster must never reach a roster write.* Spawning a team
member whose parameters differ from the roster's definition for that role —
different model, different effort, different kind, different route, different
args, or a role not on the roster at all — must not cause, and must not create a
plausible reason for an agent to cause, any write to any roster config file. The
divergence lives only in that orchestrator's team file. This is not a default, a
preference, or a judgment call; there is no divergence severity at which a roster
write becomes correct.

## 0. Findings — what is actually true today

The brief's premises were checked against the code and two of them are wrong.
The corrections shrink the work substantially, so they are recorded before the
design rather than in a footnote.

**[0.1] `spawnOneCore` does NOT mix roster writes with team writes. The brief's
central premise is false.** `spawnOneCore` ends at `roster.mjs:1563` and contains
exactly one write: `writeTeam` at `:1551`. Every `writeLevelFile` line the brief
attributed to it — `:1605`, `:1669`, `:1784`, `:1810`, `:1840`, `:1853` — lies
*below* it in the top-level `switch (cmd)`, in `init`, `add`, `edit`, `layout`,
`alias --set`, and `alias --clear` respectively. All six are explicit,
user-invoked roster commands, which the brief itself scopes as legitimate. There
is no tangled function to unpick and **no roster write site needs removing or
relocating** (see §1.5 for the full classification, which is the answer to
acceptance item 2).

**[0.2] Two orchestrators in one repo cannot currently clobber each other.** The
brief supposes they can. Spec 0011 §7.2 already guards it: `refuseLiveDefaultTeam`
(`roster.mjs:911`) refuses a bare `create` when another live team owns the default
scope and hands back an auto-derived candidate name from `deriveTeamCandidate`
(`:900`); `guardTeamPrefixCollision` (`:887`) separately refuses a `--team` name
equal to the effective unscoped prefix while a live default team exists. What is
wrong is not safety but *the default*: bare `create` still writes the shared
`team.json`, so the first orchestrator to arrive owns "the default" and the second
is met with a refusal it must resolve. The user's directive is that nobody should
own it.

**[0.3] The per-orchestrator mechanism already exists and is already correct.**
`teamPath(dir, team)` (`lib-roster.mjs:87`) resolves `teams/<name>.json`;
`teamPrefixInfo` (`lib-config.mjs:505-527`) returns `prefix = team` whenever a team
name is given, so a named team's derived member names are automatically scoped and
two named teams cannot collide in `ListAgents`; `listTeamNames` enumerates them;
`teams` (`roster.mjs:2551`) inventories them; `reap` cleans orphans by dead
orchestrator pid. This spec therefore does not introduce a scoping scheme. It
promotes the existing one from opt-in to mandatory.

**[0.4] The real defect behind the user's complaint is a missing command.**
`spawn-one <role>` can only spawn a member the roster already defines. `add`
(`roster.mjs:1610-1704`) writes the roster and *then* spawns (`:1698`, spec 0039).
There is no command anywhere that spawns a member with divergent parameters and
writes only the team file. An agent asked for a divergent member has no
non-roster-writing option, so it reaches for the one option that exists — and that
option happens to write the roster on the way. The user's amendment describes
precisely this. §1.4 supplies the missing command; §1.10 removes the roster-writing
one that was standing in for it.

**[0.5] `teamPath` is a clean single seam.** `lib-roster.mjs:87` is the only site
holding the `team.json` literal, and `tests/test-roster-multi-team.sh:120` already
asserts that. Every consumer routes through `teamPath`/`readTeam`/`writeTeam`/
`clearTeam`.

**[0.6] Team attribution for peers rests on a heuristic this change would
break.** `resolveSessionTeam` (`lib-roster.mjs:370-383` as of r1; now `:432` — the
r1 line range points at `defaultTeamScope` in the implemented tree, so do not chase
it) infers a session's team by
scanning `[null, ...listTeamNames(dir)]` for the one team containing exactly one
member of that session's role, and returns `null` as soon as a second team also
matches (`:379`). Today that ambiguity is rare because the common case is a single
default team. Under §1.1 it becomes the normal case: two concurrent orchestrators
each holding an architect means *both* peers resolve to `null`, silently lose their
`team` field in `peers.jsonl`, and fall into `misplaced_unattributed` in `teams`
(`roster.mjs:2578-2580`). This is a pre-existing weakness that the change would
promote from edge case to default, and §1.6 is not optional garnish — without it
the change is a regression.

**[0.7] `session_id` is not available to the roster CLI.** It is read only from
SessionStart hook input (`sessionstart.mjs:92,113`). Orchestrator identity in this
codebase is carried by pid — `--orchestrator-pid` / `CLAUDE_PID`, used at
`roster.mjs:1444`, `:2015`, `:2535`, `:2555`, `:2602`. Any identity scheme in this
spec must work from what the CLI can actually observe.

## 1. Design

### 1.1 Every team gets its own file; nothing new writes the shared default

**Invariant.** After this change, no code path creates or writes
`<hierarchyDir>/team.json`. Every team an orchestrator creates lives at
`teams/<name>.json`, identified by a team name that is also that team's member-name
prefix.

The identifier is the **team name**, not a pid and not a session id. Rationale,
because the alternatives are tempting and both are wrong:

- A pid in the path breaks `adopt` (`roster.mjs:2527`), whose entire purpose is to
  re-stamp a *new* pid onto an *existing* team. Under pid-keyed paths adopt becomes
  a file rename, and every peer that already resolved its team is stranded.
- A session id is unavailable to the CLI at all ([0.7]).
- The team name already scopes both the file *and* the derived member names
  ([0.3]). Introducing a second identity axis would let the two disagree, which is
  the class of bug this spec exists to end.

**Name selection for a bare `create`.** The name must default to the effective
unscoped prefix that `teamPrefixInfo(cwd, null)` computes today (the `teamAlias`,
else the repo basename) whenever that name is free. This is load-bearing for
migration, not cosmetic: because `teamPrefixInfo(cwd, "<X>")` returns prefix `<X>`,
writing `teams/<effective-prefix>.json` yields **byte-identical derived member
names** to what bare `create` produces today. A single-orchestrator user sees no
name churn — only the file location moves.

**When the preferred name is already taken by a live team, the command refuses and
asks** — today's `refuseLiveDefaultTeam` behaviour is retained unchanged (r2,
fork F3 resolved: no silent derivation). The refusal must still offer
`deriveTeamCandidate`'s free candidate as a *suggestion* the user can accept, but
must not apply it on its own. Rationale: a silently derived name is a name the
user never chose, appearing in their `ListAgents` output and in every member name
under that team.

**When the default prefix is not a usable team name, the command refuses too** (r3,
Implementor's §6 gap, Reviewer-confirmed). `teamPrefixInfo` falls back to
`basename(repoRoot)` **unvalidated** (`lib-config.mjs:527`), while a team name is a
`teams/<name>.json` path segment and must clear `validateTeamAlias`
(`lib-config.mjs:466`, `/^[A-Za-z0-9][A-Za-z0-9-]{0,31}$/`). Any repo whose
basename holds `_`, `.`, a space, or exceeds 32 characters therefore has no usable
default name. This is a class of repos, not an edge case.

**Requirement.** An unnamable default prefix must not create an unscoped
`team.json`. `defaultTeamScope` (`lib-roster.mjs:373`) currently returns
`{ team: null, defaulted: true, unnamable: prefix }` at `:380`, and its caller
(`roster.mjs:190`) reads only `team`/`defaulted` — so the invocation proceeds and
writes the shared default file. That is a direct violation of this section's
invariant, and it lands in exactly the repos where the user never chose anything.
Instead: bare `create` refuses, exits non-zero, and offers a *suggested* valid name,
by the same rule as the collision refusal above — suggested, never applied.

Four constraints on that refusal:

1. **Only the bare form is affected.** `create --team <valid-name>` in such a repo
   works unchanged. The refusal is about the *derivation* having no answer, not
   about the repo being unusable.
2. **Reading an existing legacy `team.json` is untouched.** `defaultTeamScope`'s
   first branch (`:374`, `readTeam(dir, null)` non-empty → unscoped) is §1.7
   backcompat and must stay. The invariant forbids *creating* the shared default,
   not resolving one that is already there. These two branches return the same
   shape today for opposite reasons; only the second one changes.
3. **The suggestion must clear the validator, and may be absent.** Whatever
   sanitization produces it, the candidate must pass `validateTeamAlias` and must
   not already name a team — the same two conditions `deriveTeamCandidate` already
   applies at `roster.mjs:963`. If no candidate can be produced (a basename with no
   alphanumeric to start from), refuse with no suggestion rather than inventing one.
   The sanitization algorithm itself is the Implementor's call.
4. **Name `alias --set` as the durable fix, not just the one-shot `--team`.** An
   unnamable basename is precisely the condition `teamAlias` exists for
   (`lib-config.mjs:521-523`), and setting it fixes every future invocation in that
   repo instead of one. The refusal should lead with it.

The `unnamable` field may stay as the refusal's reason, but no code may branch on it
to select a scope; if after this change nothing reads it, delete it.

**Rationale, and the cost, stated plainly.** Sanitizing silently was the tempting
alternative and it is the same move fork F3 already rejected: a derived name is a
name the user never chose, and it appears in their `ListAgents` output and in every
member name under that team. Truncating a >32-character basename is worse than the
character substitutions — it is lossy and not canonical, so there is no "obvious"
name to apply on the user's behalf. The cost of refusing is real and should not be
glossed: bare `create` stops working out of the box in a repo named `my_repo`, where
today it succeeds. That is a first-run regression for a common naming convention,
traded for never assigning a name the user did not pick. It is the same tradeoff the
user settled at F3, decided the same way for consistency — but it is theirs to
reverse. If they would rather have the sanitize in the no-choice-made case, this
paragraph and requirement 3 are the only things that change.

**What must not change:** `readTeam(dir, null)` must keep working, and every
subcommand must keep operating on a legacy `team.json` that already exists. See
§1.7.

### 1.2 The roster is read-only for the whole team lifecycle

**Invariant.** No command whose purpose is to create, populate, operate, or tear
down a team may open any roster level file for writing — not conditionally, not
on divergence, not "to keep the roster in sync". The roster is input.

The roster-mutating commands remain exactly `init`, `add`, `edit`, `remove`,
`layout`, and `alias`. These are the user editing a template, which the brief
explicitly preserves. They are not part of the team lifecycle even when a team
happens to be live.

The one boundary case is `dismiss --also-config`, which reaches
`removeConfigMember` behind an explicit opt-in flag. It stays, and the flag stays
opt-in: dismissing a member must never imply the roster edit, and no condition
(the member diverged, the member is not in the roster, the roster looks stale) may
cause `--also-config` to be inferred.

### 1.3 Mechanical enforcement, not a doc note

The brief asks for a structural fix. Prose in `CONTEXT.md` is what already exists
and is what failed. The enforcement is a refusal:

**Requirement.** When a roster-mutating command (§1.2's list) is invoked by a
session that currently owns **any** live team, the command must refuse and exit
non-zero without writing. The refusal message must name the ad hoc command from
§1.4 as the remedy, in the imperative, so an agent reading it has somewhere to go
rather than a prohibition to route around.

**Ownership is session-wide, not scope-local** (r3, Reviewer finding S3). r2 said
"the team file at the resolving scope", which is narrower than the sentence it was
meant to implement: an orchestrator that owns `--team foo` could edit the roster
freely just by omitting `--team`, because the scope the invocation resolves to is
then the one it does *not* own. The gate must instead ask whether the invoking
session owns any live team at all: scan `[null, ...listTeamNames(dir)]` and refuse
if any team file has an `orchestrator.pid` equal to the invoking session's resolved
pid with `teamIsLive` holding. This restates §1.2's "not part of the team lifecycle
even when a team happens to be live" — the roster is off limits for the duration of
ownership, not merely for one argument spelling.

Two properties of that mechanism are load-bearing and must not be traded away:

- **It is pid equality, not inference.** It does not use `resolveSessionTeam`'s
  role scan and therefore does not inherit [0.6]'s ambiguity: a pid either matches
  or it does not, so there is no case where the gate has to guess. This is also why
  the tightening is independent of §1.6 — the gate keys on orchestrator identity
  from the owner's side, §1.6 keys on member identity from the peer's side. They
  can land in either order.
- **An unresolvable pid does not refuse.** With no `--orchestrator-pid` and no
  `CLAUDE_PID` the gate cannot establish ownership, and it must then allow the
  write. That hole is deliberate and correctly aimed: it is the plain user shell
  editing a template, which §1.2 exists to preserve. The agent-invoked paths this
  spec is actually defending against are exactly the ones where the pid is
  available. Do not "fix" this by refusing on unknown identity — that breaks the
  legitimate case to harden a case that is already covered.

**Refuse plus an explicit override flag** (r2, fork F1 resolved as recommended).
Not warn-only — a warning is exactly what already exists in prose form and exactly
what failed. Not per-command — a uniform rule is one thing to state in the docs
and one thing an agent cannot reason its way around case by case. The override
flag exists so a user who genuinely intends to edit the template mid-team can, and
it must be the *user's* flag: no code path may supply it on the user's behalf, and
an agent adding it to get past a refusal is the failure this spec exists to
prevent. The refusal message must therefore lead with §1.4's command and mention
the override second, as the narrow exception it is.

This repo already has the mechanism for this shape of gate
(`pretooluse-roster-skill-gate.mjs`, `pretooluse-route-gate.mjs`). Whether the
refusal lives in the CLI, in a PreToolUse gate, or both is the Implementor's call;
the requirement is the behaviour, and it must hold for the MCP tool surface as
well as the CLI, since `roster_member`/`roster_config` reach the same writers.

### 1.4 The missing command: spawn a divergent or ad hoc member

**Requirement.** There must be one command that:

1. Accepts a full member specification: a role, plus any of model, effort, route,
   kind, args, auto-mode, on-missing — the same fields `add` accepts and the same
   validation rules (`validateMember`, and every kind/model rule spec 0043 §1.3
   established; nothing here relaxes them).
2. Works whether or not the roster defines that role, and whether or not the
   supplied parameters match the roster's definition of it. Divergence is the
   normal case, not an error and not a warning.
3. Spawns through the **same** `spawnOneCore`/`spawnShape` seam `spawn-one` and
   `create --spawn` already use. One launch path, per 0043's finding — a second
   launch builder is how the kind/args/quoting rules get silently forked.
4. Writes the resulting member row to the active team file and **nothing else**.
   It must not open any path returned by `rosterLevelPaths` for writing, under any
   input.
5. Derives the member name with the team's own prefix, and refuses a name that
   already names a member of that team rather than overwriting the row.

6. Lives on the `/agent-team` surface (§8.1) and is named as a team-lifecycle
   command. It is new, so it has no muscle memory to preserve — it must be born on
   the correct side rather than renamed later.

The command's name, flags, and internal structure are otherwise the Implementor's
call. Its observable contract is the six points above.

### 1.5 Classification of every roster-config write site

This is the answer to acceptance item 2. Every site, with a verdict:

| Site | Command | Verdict |
|---|---|---|
| `roster.mjs:1605` | `init` | Legitimate — user creates a template. Keep. |
| `roster.mjs:1669` | `add` | Legitimate — user edits the template. Keep the *write*; remove the auto-spawn that follows it at `:1698` (§1.10). |
| `roster.mjs:1784` | `edit` | Legitimate. Keep. |
| `roster.mjs:1810` | `layout` | Legitimate. Keep. |
| `roster.mjs:1840` | `alias --set` | Legitimate. Keep. |
| `roster.mjs:1853` | `alias --clear` | Legitimate. Keep. |
| `removeConfigMember`, `roster.mjs:331` via `remove` (`:1792`) | `remove` | Legitimate. Keep. |
| `removeConfigMember` via `dismiss --also-config` | `dismiss` | Legitimate **only** behind the explicit flag; never inferred (§1.2). |
| `spawnOneCore` | — | **No roster write exists.** Correct as built ([0.1]). |

**Nothing is removed or relocated.** All eight surviving sites become subject to
§1.3's refusal. The defect was never a misplaced write; it was a missing
alternative ([0.4]) plus an unenforced boundary (§1.3).

### 1.6 Team attribution must travel with the spawn

**Requirement.** A peer's team attribution must not depend on inferring it from
the peer's role after the fact. `resolveSessionTeam`'s role scan must be demoted
to a *fallback*, used only when no authoritative attribution is available (an
adopted session, a session that predates this change).

The authoritative source is the orchestrator: at spawn time it knows both the team
name and the member name, and the member name is already team-prefixed and
therefore unique across concurrent teams ([0.3]).

Two candidate channels, and the choice between them is **empirical, not a design
preference** — see §5:

- **(a) Carry the team name to the peer at launch**, so the peer records it
  directly. Natural, and the `AH_` env-var convention already exists
  (`AH_HERDR_TIMEOUT_MS`). Requires that the value actually reaches the spawned
  process on all three transports.
- **(b) Attribute at read time**, matching a peer's recorded `pane_id` /
  `transport_id` against the member rows the orchestrator wrote into the team file.
  Needs no new channel and no new evidence. It is also the more robust ordering:
  the peer's `peers.jsonl` row is written by its own SessionStart, which fires
  *before* the orchestrator's `writeTeam` lands, so a peer cannot reliably know its
  team at the moment it registers.

**Default to (b)** unless §5's evidence shows (a) works on all three transports,
in which case (a) may be layered on top as the fast path. Whichever lands, the
existing safe-refuse behaviour must be preserved: an unresolvable attribution
records *no* `team` field and is counted as unattributed. It must never guess.
Under-reporting is recoverable; mis-attribution drives `teams`' misplacement
remedy, which dismisses and respawns a peer (`roster.mjs:2557-2562`) — a wrong
match there destroys a healthy session.

### 1.7 Backcompat and migration

**An existing `team.json` is read, never moved, never rewritten, never migrated.**

- Every read path keeps calling `readTeam(dir, null)`; `resolveSessionTeam` already
  iterates `[null, ...listTeamNames(dir)]`, so a legacy default team and new named
  teams coexist with no change.
- A team that is live across an upgrade keeps working and can be disbanded,
  dismissed, resynced, and reaped exactly as before.
- **No rename-on-upgrade.** Renaming a live team's file would strand every peer
  whose `peers.jsonl` row records `team: null` and would break attribution for
  members already up. The legacy file ages out when its team disbands; `reap`
  already collects it if the orchestrator dies first.
- `guardTeamPrefixCollision` must stay. Under §1.1 there is normally no live
  default team for it to fire against, but a legacy one may still exist and the
  collision it prevents is still real.

A second orchestrator arriving in a repo that already holds a legacy `team.json`
gets a name that does not collide with it, by the same free-name selection §1.1
describes.

### 1.8 `teams/<name>.json` is not superseded — it is the scheme

Answering acceptance item 4 directly: the named-team feature from spec 0011 is
neither an orthogonal axis to build on top of nor a different problem. It is
exactly per-orchestrator isolation, built already and left opt-in. This spec makes
it the only path. No new axis is introduced ([0.3], §1.1).

### 1.9 Documentation

`CONTEXT.md:7-31` and `skills/agent-roster/SKILL.md:14-21` already describe the
roster/team split correctly in concept. They must be updated to say that it is now
*enforced* — naming the refusal (§1.3), the ad hoc command (§1.4), the removal of
`add`'s spawn (§1.10), and the anti-requirement above — so the docs stop reading as
an aspiration a reader can talk themselves out of. They must also describe the two
surfaces (§8) as the primary way the split is expressed to a reader, since that is
what an agent encounters before it encounters any of the mechanism.

### 1.10 `add` no longer spawns — an explicit supersession of spec 0039

**This section reverses a shipped decision deliberately.** Spec 0039 gave `add` an
auto-spawn: after writing the new member into the roster config, `add` spawned that
member (`roster.mjs:1698`, `result.spawn = await spawnOneCore(role, "add")`). The
user's instruction, verbatim:

> "Drop it, roster editing and team creation are two distinct things we should
> never had blurred."

**Requirement.** `add` writes the roster config and stops. It must not call
`spawnOneCore`, must not launch any process, and must not return a `spawn` field.
Removing it is the point — this is not satisfied by leaving the call in place and
making it unreachable while a team is live (§1.3 would do that on its own, and the
user asked for more than that).

Note this is a stronger reading than §1.3 alone requires, and it is the correct
one: 0039's auto-spawn is *why* `add` looks to an agent like the way to get a
member running. As long as one command both edits the template and produces a live
member, the anti-requirement above stays one convenient rationalization away from
being violated. §1.4's command and §1.3's refusal only work if `add` has nothing
left to offer an agent that wants a member spawned.

**What replaces it.** Nothing, in `add` itself. Spawning becomes a separate,
explicit step:

- Roster-conforming member → the existing `spawn-one <role>` path.
- Divergent or ad hoc member → §1.4's command.

`add`'s output should say so — on success it must point at the spawn step rather
than leaving the user to discover that the member was added but not started.
Whether that is a printed next-step line or a structured field is the
Implementor's call; the requirement is that the change is not silent to a user who
relied on the old behaviour.

#### Ripple — larger than the fork brief assumed, surveyed and settled here

The auto-spawn is not one line. 0039 grew a flag and a plumbing path around it,
and both have reached widely into the tree.

**[R1] `--no-spawn` is passed at roughly 80 call sites across 15+ test suites**
(`test-roster-agent-kind.sh`, `test-roster-spawn-one.sh`, `test-roster-cli.sh`,
`test-roster-relocation.sh`, `test-roster-add-autoinit.sh`, `test-mcp-server.sh`
and more), because 0039 made spawn the default and every suite that only wanted a
config row had to opt out. Once `add` never spawns, every one of those flags is
meaningless.

**Ruling: keep `--no-spawn` accepted and silently ignored at the CLI and on MCP;
remove it from all documentation, from `roster.mjs`'s usage header (`:12`), and
from `roster_member`'s tool schema description.** Rationale, and this is a
deliberate asymmetry:

- Erroring on it would break ~80 in-tree call sites and any user script, to
  express a point the docs already make.
- Documenting it would keep a flag whose *name asserts the old default* — a reader
  seeing `--no-spawn` correctly infers that spawning is what happens without it.
  That inference is the confusion this spec exists to remove.
- Accepting-and-ignoring costs one branch, breaks nothing, and lets the ~80 call
  sites be cleaned up opportunistically instead of in this diff.

The Implementor should **not** bulk-edit those 80 call sites as part of this
change. They are harmless and the churn would bury the real diff.

**[R2] `test-roster-add-spawn.sh` is 0039's dedicated suite and asserts the
behaviour being removed** — its T1 ("add spawns"), T3, T4, T7, T8, T9, T10 all
encode spawn-on-add. This suite must be rewritten to assert the *new* contract
(add writes config, spawns nothing, under every route/level/kind combination it
currently varies), not deleted. Its coverage of `add`'s validation and level
handling is worth keeping; only the spawn assertions invert. `test-roster-agent-
kind.sh:437` ("add --no-spawn writes config and spawns nothing") stays green
unchanged and becomes the unconditional case.

**[R3] MCP `roster_member` carries three add-only parameters that exist solely for
the spawn** — `no_spawn`, `allow_global`, `orchestrator_pid` (`mcp/server.mjs:
173-175`, plumbed at `:551-554`). Under R1's rule all three stay accepted and
ignored for `action: add`, and all three leave the descriptions. `allow_global`
and `orchestrator_pid` remain live for the tools that genuinely spawn.

**[R4] Cross-references in other specs must be annotated, not rewritten.**
`0039-roster-add-spawns-peer.md` gets a supersession note at the top;
`0038-roster-add-auto-init.md:157` (which forward-references 0039's spawn) gets a
pointer to it. `0043`'s mentions at `:387` and `:782` describe `--no-spawn`
behaviour that still holds under R1 and need no change.

**[R5] A simplification falls out, and it should be taken.** 0039 §"SKILL.md Init
flow" noted that per-`add` spawning made the flow's later `create --spawn` a noisy
no-op re-check, and that a batch spawn is the right shape. With §1.10 that tension
disappears: the init flow adds roles, then spawns once. The SKILL.md init flow
(0039 cites `:68`, `:184-199`) should be simplified accordingly, and its
`--no-spawn` arguments dropped from the documented commands.

**[R6] `pretooluse-roster-skill-gate.mjs:37` already gates exactly the team-side
verbs** — `roster_create`, `roster_spawn_one`, `roster_adopt`, `roster_move`,
`roster_dismiss`, `roster_disband` — and does *not* gate `roster_member`. That is
independent confirmation of §8.1's boundary, and it means the gate's verb list
needs extending only with §1.4's new tool, not restructuring.

## 2. Files to change

- `agent-hierarchy/hooks/lib-roster.mjs` — `teamPath` and the default-name
  resolution behind it; `resolveSessionTeam` (§1.6).
- `agent-hierarchy/hooks/roster.mjs` — `create`'s name selection (§1.1); the
  refusal in the roster-mutating commands (§1.3); the new ad hoc command (§1.4).
- `agent-hierarchy/hooks/sessionstart.mjs` — team attribution at `:73`/`:105`
  (§1.6).
- `agent-hierarchy/hooks/lib-config.mjs` — only if `teamPrefixInfo` needs to
  distinguish "no team" from "the default-named team"; verify before touching.
- `agent-hierarchy/hooks/roster.mjs` again for §1.10: remove the `add` auto-spawn
  at `:1698` and whatever flag/plumbing exists only to serve it.
- The MCP tool surface — `roster_member`, `roster_config`, a new tool for §1.4's
  command, and the description rewrite of every `roster_*` tool (§8.4). §1.3 must
  hold on all of them.
- `agent-hierarchy/skills/agent-roster/SKILL.md` — §1.9, and stripped of the
  lifecycle commands (§8.1).
- **New: an `/agent-team` skill/slash-command surface** (`agent-hierarchy/skills/
  agent-team/SKILL.md` and its command registration, mirroring however
  `agent-roster` is registered) — §8.
- `agent-hierarchy/hooks/pretooluse-roster-skill-gate.mjs` — must cover the new
  surface as well as the old (§8.3); a split that leaves it keyed only to
  `agent-roster` silently disarms it.
- `agent-hierarchy/CONTEXT.md` — §1.9 plus the two-surface description (§8).
- `agent-hierarchy/docs/specs/0039-*.md` — mark the auto-spawn superseded by this
  spec (§1.10). The rest of 0039 stands; do not delete it.
- Tests: `tests/test-roster-multi-team.sh` (asserts the `team.json` literal
  location at `:120` and team paths at `:118`), plus whichever suites assert bare
  `create` writes `team.json`. These encode the superseded default and need
  updating deliberately, called out in the report, not silently.
- `agent-hierarchy/tests/test-roster-add-spawn.sh` — rewritten, not deleted
  (§1.10 R2). This is the only suite whose assertions invert.
- `agent-hierarchy/docs/specs/0039-roster-add-spawns-peer.md` (supersession note)
  and `0038-roster-add-auto-init.md:157` (forward-reference pointer) — §1.10 R4.
  The ~80 `--no-spawn` call sites across the other suites are **deliberately left
  alone** (§1.10 R1); do not bulk-edit them.
- `agent-hierarchy/plugin.json` **and** the root `marketplace.json` — both version
  numbers, together.

## 3. Must not change

- Any model/kind/effort/route validation rule, including everything spec 0043
  established. This spec changes *where things are written*, never *what is legal*.
- The derived member names a single-orchestrator user sees today (§1.1).
- `readTeam(dir, null)` and every consumer of a legacy `team.json` (§1.7).
- The safe-refuse property of team attribution: never guess (§1.6).
- The legitimate roster-mutating commands' *config-writing* behaviour when no live
  team is owned (§1.5) — the same rows land in the same files, with the same
  validation. The one deliberate exception is `add`'s auto-spawn, removed by §1.10;
  `add`'s roster write itself is unchanged.
- One launch path. No second spawn-command builder (§1.4 point 3).

## 4. Verification

1. **The anti-requirement, directly.** Spawn an ad hoc member that diverges from
   the roster on every field at once (different model, effort, kind, args, and a
   role absent from the roster). Assert the content of every path in
   `rosterLevelPaths(cwd)` is byte-identical before and after. This is the test the
   amendment exists to demand; it must fail if any future change reintroduces a
   divergence-driven roster write.
2. Two concurrent orchestrators in one repo each create a team and each spawn an
   architect. Assert: two distinct `teams/*.json`, neither writes `team.json`,
   member names do not collide, and each peer's `peers.jsonl` row carries its own
   correct `team` (§1.6 — this is the case that fails today).
3. A roster-mutating command invoked by a session owning a live team refuses,
   exits non-zero, writes nothing, and names the §1.4 command in its message.
   With the override flag, it succeeds. Assert the refusal message leads with the
   §1.4 command, not with the override (§1.3).
3a. **`add` spawns nothing (§1.10).** Run `add` with no live team — the case where
   0039's spawn used to fire — and assert no process is launched, no `spawn` field
   is returned, and the team file is untouched. Assert the roster config gained
   exactly the expected member row, so the removal is proven surgical. Cover
   `route: peer` explicitly: that was 0039's spawning case and is the one a
   regression would reach first.
3c. **`--no-spawn` is still accepted and still a no-op (§1.10 R1).** `add
   --no-spawn` and MCP `no_spawn: true` exit 0 with the row written, identically
   to the flagless form. The ~80 existing call sites passing it are the test.
3b. `create` against a taken team name refuses, exits non-zero, writes no team
   file, and suggests a free candidate without applying it (§1.1, fork F3).
4. Single-orchestrator bare `create` produces derived member names byte-identical
   to the pre-change output (§1.1's migration claim — assert the names, since that
   is the property, not the file path).
5. A repo with a pre-existing live legacy `team.json` upgrades: the team is still
   readable, disbandable, and resyncable, and a second orchestrator arriving gets a
   non-colliding name (§1.7).
6. Full existing suite green, with any test that encoded bare-`create`-writes-
   `team.json` updated deliberately and the update called out in the report.
7. **The alias holds (§8.3).** Every lifecycle command invoked through
   `/agent-roster` produces the same result as through `/agent-team`. Assert this
   for at least `create`, `spawn-one`, `dismiss`, `disband` — the ones with the
   most existing callers.
8. **The gate covers both surfaces (§8.3).** A roster-mutating command refused
   under §1.3 is refused identically whether reached via `/agent-roster`,
   `/agent-team`'s alias if one exists, or the MCP tool. A split that disarms
   `pretooluse-roster-skill-gate.mjs` on one path is the failure mode to test for
   explicitly.
9. **The surfaces list the right commands (§8.1).** Assert `/agent-roster`'s skill
   text no longer lists any lifecycle command and `/agent-team`'s lists no
   roster-editing command. This is the part of §8 that does the actual work, so it
   needs an assertion rather than a reviewer's glance.

## 5. NEEDS-EVIDENCE

Both items decide §1.6(a) versus (b). **Neither is mine to run.** §1.6 defaults to
(b), which needs no evidence, so these gate only whether the (a) fast path is
available — the design does not stall on them.

- **[N1] Does `herdr agent start` forward the caller's environment to the spawned
  agent process?** Run a spawn with a distinctive variable set in the caller's
  environment and read it back from inside the agent. *Decides:* if yes, an env
  channel works on herdr; if no, (a) is dead for the herdr transport and (b) is the
  only option. Note the tmux branch already needs the variable prefixed into the
  command string rather than inherited, since a tmux pane inherits the tmux
  server's environment, not the orchestrator's.
- **[N2] Does SessionStart's hook input expose the session's own `--name`?**
  Inspect a real SessionStart payload for a peer launched with `--name`. *Decides:*
  if yes, a peer can self-attribute by matching its own team-prefixed name with no
  new channel at all, which is cleaner than either (a) or (b). Worth settling
  first — it may make N1 moot.

## 6. Decisions made, and decisions refused

**Made:**
- Reuse the team name as the sole identity; reject pid-keyed and session-id-keyed
  paths (§1.1, with reasons).
- Default a bare `create` to the current effective prefix so member names do not
  churn (§1.1).
- Read-and-never-migrate for legacy `team.json`; no rename-on-upgrade (§1.7).
- No roster write site is removed or relocated (§1.5) — correcting the brief.
- Attribution must travel from the spawn; the role scan becomes a fallback (§1.6).
- `add` stops spawning; 0039's auto-spawn is superseded, not merely gated (§1.10,
  on the user's instruction).
- The CLI split's boundary is "does writing a roster level file constitute this
  command's purpose" — mechanical, and consistent with §1.5 (§8.1).
- Permanent forwarding alias rather than a hard rename or a deprecation window;
  what changes is what is documented, not what is accepted (§8.3).
- MCP tool *names* unchanged, tool *descriptions* carry the split (§8.4).
- One implementation under both surfaces; no second CLI program (§8.2).
- `--no-spawn` and its MCP siblings stay accepted but become undocumented no-ops
  rather than erroring — the ~80 call sites are left alone (§1.10 R1). This is the
  one place the spec deliberately tolerates a name that no longer describes
  anything, and the reason is that erroring buys nothing the docs do not.
- Considered and rejected: scoping via `AGENT_HIERARCHY_DIR`. It would give each
  orchestrator a private everything for free, but it also isolates `peers.jsonl`,
  which spec 0011 §3 deliberately shares across teams. Wrong lever.

**Referred to the user, and answered (r2). No open forks remain.**
- **F1 — how hard §1.3's gate bites.** Answered: refuse plus an explicit override
  flag, as recommended. Spelled out in §1.3.
- **F2 — does `add` keep spec 0039's auto-spawn?** Answered **against my lean**.
  I leaned keep-but-unreachable; the user said drop it outright: *"Drop it, roster
  editing and team creation are two distinct things we should never had blurred."*
  Spelled out in §1.10 as an explicit supersession of 0039. Recorded here as an
  overruled recommendation rather than quietly absorbed — and on reflection the
  user is right for a reason my lean missed: as long as one command both edits the
  template and produces a live member, the anti-requirement stays one
  rationalization away from being violated. §1.3's gate suppresses the symptom;
  removing the spawn removes the incentive.
- **F3 — silent auto-naming vs. refuse-and-ask.** Answered: keep today's
  refuse-and-ask. Spelled out in §1.1.
- **F4 — split the CLI surface?** Raised by the user, and I recommended splitting
  but deferring it to a follow-on spec. **Overruled: it is in scope here** (§8).
  Recorded as overruled rather than absorbed. My deferral argument was about
  commit hygiene, not about design, so it survives intact as §8.5's sequencing
  instruction — the concern is addressed by ordering two commits, which never
  required two specs.

## 7. Confidence

**High** on §§1.1, 1.2, 1.4, 1.5, 1.7, 1.8 — these rest on code I read directly,
and the two brief corrections in §0 are verifiable at the cited lines.

**Medium** on §1.6. The *problem* is certain (`lib-roster.mjs:379` is explicit and
§1.1 makes its failure case the default). The *remedy* depends on N1/N2, and I
have specified a default that works without either.

**High** on §8.1's boundary rule and §8.3's alias-forward shape — the rule is
mechanical and agrees with §1.5's already-verified classification, and the alias
is the strictly-less-disruptive option. **Medium** on §8.4: I have not read the MCP
tool definitions, and the claim that descriptions rather than names are what an
agent selects on, while I believe it, is a behavioural claim I did not verify here.
If the Implementor finds the tool surface is generated from a schema where a
namespace split is nearly free, that is worth reporting back rather than following
§8.4 literally.

**Not escalating to Ultra-Advisor.** No irreversible surface: no data migration
(§1.7 moves nothing), no auth or concurrency change. The one genuinely risky
interaction — mis-attributing a peer and having `teams` dismiss a healthy session
— is closed by preserving the existing safe-refuse property (§1.6), not by new
judgment.

One correction to r1's confidence note: r2 *does* break a public behaviour — `add`
no longer spawns (§1.10). It is a deliberate, user-instructed break of a
documented behaviour, it is trivially reversible, and it is called out at the top
of this spec rather than buried. But it should not be described as "no public
interface break", and the Implementor should treat it as a change users will
notice.

## 8. The entry point splits too: `/agent-roster` edits, `/agent-team` operates

Decided by the user (briefs `20260908-114146-gi03`, `20260908-114221-1trx`),
verbatim: *"agent-roster tools for editing the roster / agent-team tools for
managing a team"*. In scope for this spec, not deferred.

**Why this is not merely cosmetic**, since the obvious objection is that §1.3's
refusal is the correctness mechanism and a second command name only renames the
door. That objection is right about humans and wrong about the failure this spec
exists to fix. The recurring failure is an *agent* choosing a command, and an agent
chooses from the skill text and subcommand list it is shown. One surface listing
`add`/`edit`/`remove` alongside `create`/`spawn-one`/`dismiss` presents template
editing and instance management as peers in a single menu — the exact conflation
the user has now described four times. The entry point is where the confusion is
formed; the gate is where it is caught. This spec now does both.

### 8.1 The split

**`/agent-roster` — the template. Reads and edits roster level files, never
launches or terminates anything.**
`init`, `add`, `edit`, `remove`, `layout`, `alias`, `show`.

**`/agent-team` — the instance. Reads the roster, writes only the team file,
owns every process lifecycle operation.**
`create`, `spawn-one`, §1.4's divergent/ad hoc spawn command, `dismiss`,
`disband`, `adopt`, `move`, `resync`, `reap`, `teams`, `history`.

The boundary is the same one §1.5 used to classify the write sites, applied to the
command surface: **a command belongs to `/agent-roster` if and only if writing a
roster level file is its purpose.** That test is mechanical, it agrees with the
user's own phrasing, and it puts `layout` and `alias` on the roster side (both go
through `writeLevelFile`, `roster.mjs:1810`/`:1840`/`:1853`) where a
surface-appearance reading might have misfiled them.

`dismiss --also-config` is the one command that crosses. It stays on
`/agent-team`, because dismissing a running member is a lifecycle act; the
`--also-config` flag remains the explicit, never-inferred opt-in of §1.2. It does
not get a second home on `/agent-roster`.

### 8.2 One implementation underneath

**`roster.mjs` remains the single implementation.** The split is at the skill,
slash-command, and MCP-tool surface. There must not be a second CLI program, a
second team-creation path, or a second spawn builder — §1.4 point 3 and §3's "one
launch path" bind here too. Two implementations of team creation would be a
materially worse outcome than the confusion this section is fixing.

Whether the file is later divided for readability is the Implementor's call and
not required by this spec; if it is, the seam is the command dispatch table, not
the writers.

### 8.3 Backcompat: alias forward, permanently

**Every invocation that works today keeps working.** `/agent-roster create`,
`/agent-roster spawn-one`, `/agent-roster dismiss`, and the rest forward to the
`/agent-team` implementation and behave identically. This is a permanent alias, not
a deprecation with a removal date, and it is the least disruptive shape available:

- Existing docs, automation, muscle memory, and any transcript an agent learned
  from keep working.
- `pretooluse-roster-skill-gate.mjs` keys on the existing skill; a hard rename
  would silently disarm it, which is the opposite of this spec's purpose. The gate
  must cover *both* surfaces after the split — verify this explicitly, it is easy
  to miss.
- A hard rename would break callers to buy discoverability the alias already
  delivers.

What changes is what is *documented and advertised*: `/agent-team` becomes the only
place the lifecycle commands are listed, and `/agent-roster`'s skill text stops
listing them. The agent-facing menu is what needed splitting, and hiding them from
that menu is what accomplishes it.

**Refused, and left to the user:** whether a lifecycle command invoked via the
`/agent-roster` alias should also print a one-line pointer to `/agent-team`. It is
a taste call about how noisy a *correct* invocation should be — it changes no
behaviour, and I will not make it. Default to silent if nobody decides.

### 8.4 MCP tools

The existing `roster_*` tools split by the same rule. `roster_config` and
`roster_member` are roster-side; `roster_create`, `roster_spawn_one`,
`roster_dismiss`, `roster_disband`, `roster_adopt`, `roster_move`, `roster_resync`,
`roster_reap`, `roster_teams`, `roster_history` are team-side, plus a new tool for
§1.4's command.

**Existing tool names do not change.** Renaming them would break every agent that
has one in context, for no gain — an MCP tool is chosen from its description, not
its namespace prefix. The split is expressed in the *descriptions*: each tool's
description must state which surface it belongs to and, for the roster-side tools,
that it edits the template and does not affect a running team. That is what an
agent actually reads.

Both surfaces' tools must enforce §1.3.

### 8.5 Sequencing (an instruction to the Implementor, not a design constraint)

Land this in two commits, mechanism first: §§1.1–1.10 (the boundary becomes real),
then §8 (the boundary becomes visible). Both are in this spec and both must ship,
but a single commit changing the enforcement *and* the command surface has no
intermediate state where either is independently verifiable, and every test naming
a command would churn twice. If the Implementor finds a reason the order must be
reversed or merged, that is a report-back, not a silent choice.

## 9. r3 — post-review rulings (brief `20260908-124657-1u06`)

Two spec-defects raised after the first implementation round. Both are ruled on in
place, in the sections they belong to; this section is only the changelog.

**[9.1] Unnamable default prefix → §1.1.** Ruled: refuse with a validated
suggestion; do **not** fall back to creating an unscoped `team.json`. The shipped
fallback at `lib-roster.mjs:380` is safe (it never puts a bad name in a path) but it
reinstates the shared-default ownership problem §1.1 exists to end, in a whole class
of repos, and it does so silently. Reading an existing legacy `team.json` (`:374`) is
untouched — the invariant forbids creating the shared default, not resolving one
already there, and those two branches of `defaultTeamScope` return the same shape for
opposite reasons. Consistency with fork F3 decided the sanitize-vs-refuse call. The
first-run cost is named in §1.1 and is the user's to reverse.

**[9.2] §1.3's gate was scope-local, not session-wide → §1.3.** Ruled: tighten to
"any team this session owns", implemented as a pid-equality scan over
`[null, ...listTeamNames(dir)]`. r2's "the team file at the resolving scope" let an
orchestrator owning `--team foo` edit the roster by omitting `--team` — narrower
than the sentence it was implementing. Two properties are load-bearing and recorded
in §1.3: it is pid equality rather than `resolveSessionTeam`'s inference (so it never
guesses and does not inherit [0.6]), and an unresolvable pid must **not** refuse (that
hole is the plain user shell §1.2 preserves).

**No interaction with the parallel Implementor round.** The Orchestrator asked
whether [9.2] collides with the B2 attribution work. It does not: the gate keys on
orchestrator identity from the owner's side (pid on the team file), attribution keys
on member identity from the peer's side (`attributeSessionTeam` →
`resolveTeamByPane` / `resolveSessionTeam`, `lib-roster.mjs:427-430`). Different
inputs, different direction, no shared state. They can land in either order.

**Verification added by r3** (§4's list gains these):

- In a repo whose basename fails `validateTeamAlias` and with no pre-existing
  `team.json`: bare `create` exits non-zero, writes no file under `<hierarchyDir>`,
  and its message names both a valid suggested name and `alias --set`.
- Same repo, with `teamAlias` set to a valid name: bare `create` succeeds and writes
  `teams/<alias>.json`. Confirms the alias is a real remedy and not just advice.
- Same repo, with a pre-existing legacy `team.json`: bare `create` behaves exactly as
  before (§1.7 backcompat), proving the `:374` branch was not caught by the change.
- A session owning `teams/foo.json` (its pid, `teamIsLive`) runs a roster-mutating
  command with **no** `--team`: refused. This is the S3 regression test and it fails
  against r2's wording.
- The same command with no resolvable pid (`--orchestrator-pid` absent, `CLAUDE_PID`
  unset) while that same live team exists: **allowed**. Guards the deliberate hole
  against a well-meaning tightening.

**Scope of r3.** Nothing else in this spec changes. §§1.2, 1.4–1.10 and §8 stand as
written in r2.
