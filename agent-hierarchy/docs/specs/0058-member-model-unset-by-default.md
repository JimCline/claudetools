# 0058 — A member's model is the user's to define, not a default

Status: r5, ready for implementation. Base: 0057 r5 (committed 7a09186 on
`feat/0056-user-defined-roles`).

**r5** fixes a spec gap the Implementor verified.

- spawn-one and spawn-ad-hoc accept only chain roles, so r4's
  spawn-one/spawn-ad-hoc skip branch and `relaunch` could never run. Both
  are **removed**.
- The not-dispatchable case moves in front of create: the driver passes
  `create --no-legwork-handoff`.
- Tests B6c, B6c2, B6g and D2 are revised to match.
- Everything else is r4.

**r4 changes only** these parts:

- §2.4.2, per the ruling "Always skip, never ask": with task-gopher
  installed, a model-less legwork member is auto-skipped, never listed and
  never asked about, and the driver handles the not-dispatchable case via
  `relaunch`;
- the r4-marked lines in §2.3, §2.4's class table, §2.6, §3, §6 and §7;
- tests B6, B6c–B6h and D2.

r3's `--skip-member` flag and `{handoff}` fallback shape are **removed**.
Everything else is r2 as built.

r2 applies the user's rulings (full text in §6):

- **OQ1:** borrow the highest model. The member keeps its role; its work is
  never re-routed.
- **OQ2a:** Ultra-Advisor (advise-class) models are **not** fallback
  candidates. Only design, review and implement members count, custom roles
  included. This recomputes the §4 golden delta.
- **OQ2b:** a legwork member gets no fallback unless task-gopher is
  available. **r4:** when it is installed, the member is skipped
  automatically and never asked about, and its legwork goes to
  `task-gopher:task-gopher` subagents (§2.4.2).
- **OQ4:** only model asks. An undefined effort never triggers the ask.
- **OQ3 and OQ5:** deferred at their baselines.

r2 also adds §2.5's check of a custom role row stored with no model.

## 0. The user's ruling (verbatim, governing)

The user gave this ruling when asked which model and effort to set per role:

> "Only if defined by the user, otherwise left undefined which the user would
> have to define at invocation, otherwise, routes to the highest defined
> reasoning agent."

The user confirmed that it applies to **per-role model/effort**. It does not
apply to ultra-advisor membership.

The ruling has three parts, and the rest of this spec calls them by these names:

1. **Store:** a model is stored only if the user defined it.
2. **Ask:** an undefined model is defined by the user at invocation.
3. **Fallback:** otherwise, the member gets the model of the highest defined
   reasoning agent.

## 1. Facts this spec rests on (HEAD 7a09186)

- **Two separate model stores exist.** Do not conflate them.
  - (a) **Config `roles.<role>.model`.** Seeded from `ROLE_DEFAULTS`
    (lib-config.mjs:199-210, :1186) and overridden per config layer. It sets
    the model for **subagent (Agent-tool) dispatch**: the SessionStart
    directive prints it in `roleLines` (lib-config.mjs:1723-1742) and the
    Orchestrator passes it on the Agent call.
  - (b) **Roster member row `model`.** Read only when a member is
    **launched** as a pane or peer (spawnShape, roster.mjs:1251-1253).
  - Nothing reconciles (a) and (b).
- **`add` and `spawn-ad-hoc` fill in a model the user never typed.** Both
  build the member through `memberFromFlags` (roster.mjs:1027-1049). When
  `--model` is absent on a claude-kind member, :1033 fills it:
  - a **builtin** role gets `ROLE_DEFAULTS[role].model` (architect opus,
    reviewer opus, ultra-advisor fable, implementor inherit, task-runner haiku);
  - a **custom** role gets `registry().roles[role].model`.

  Effort has no default anywhere. `add` already leaves it unset (:1037).
- **`init` (roster.mjs:3050-3067) writes `{route, members: []}` and touches
  no model.** The per-role model questions live in the agent-roster skill,
  init step 5 (skills/agent-roster/SKILL.md:125-148). That step says
  "Prefill/offer defaults from `ROLE_DEFAULTS`".
- **`edit` can overwrite a model or effort but cannot clear one.** It sets
  them at roster.mjs:3143-3144. The precedent for clearing a field is
  `--args ""`, which deletes the key (:3183).
- **Spawn verbs read the stored row with no fallback.** This holds for
  spawn-one (`spawnOneCore`, :2791+), create --plan/--spawn
  (`resolveMembersPlan`, :2061-2074) and create --commit (hydration at
  :3394-3422).
  - `spawn-one` has no model flag (`SPAWN_ONE_FLAGS`, :122).
  - `spawn-ad-hoc` has `--model` and `--effort` (`AD_HOC_FLAGS`, :126).
- **A member with no model and a member with `inherit` launch identically.**
  The spawnShape guard (:1252) emits `--model` only when the value is truthy
  and not `"inherit"`. The child process then runs on its **own** default
  model, not the Orchestrator's.
- **Each class has a model allowlist** (`CLASSES`, lib-config.mjs:153-196):

  | Class | Allowed models |
  |---|---|
  | advise | `TOP_TIER_MODELS` = fable, opus. No inherit. |
  | design, review, implement | `REASONING_MODELS` = opus, sonnet, fable, inherit |
  | legwork | the reasoning models plus haiku |

  - `validateMember` (lib-roster.mjs:226-251) checks a model only when one
    is present. An absent model is valid in every class.
  - `checkCustomRow` (lib-config.mjs:1039-1046) requires an explicit
    fable/opus for an **advise-class role definition**. That check is on
    the config row, not on member rows.
  - Effort values are `EFFORT_VALUES` = low, medium, high, xhigh, max
    (lib-roster.mjs:77).
- **A model ranking already exists, and nothing uses it to pick a model.**
  It is `TIER = {haiku:1, sonnet:2, opus:3, fable:4}` with `tierOf`
  (lib-config.mjs:279-286). Today it is read only for display and the
  route gate's tier rule.
- **The route gate never spawns** (pretooluse-route-gate.mjs:26-27). It
  denies and prints the command for the Orchestrator to run: `spawn-one
  <role>`, or `spawn-ad-hoc <role> [--model <Agent call's model>]`
  (:114-117, :248).
- **No hook launches anything.** No hook uses child_process.
- **0057's structured refusal (U6) is the pattern to follow.** It is
  `refused:"team-name-unusable"` (0057 §2.8, emitted by `refuseTeamName`,
  roster.mjs:827-858):
  - JSON on stdout, exit 2, with the `message` also on stderr as
    `roster.mjs: <msg>`;
  - a `rerun` built by `rerunWithTeamPlaceholder` (:812-825), which
    shell-quotes argv;
  - the agent-team skill asks via AskUserQuestion and reruns
    (SKILL.md:52-56, :225-243, :644-645).
- **The golden fixture writes its roster JSON directly**
  (tests/fixtures/0056-i1/render.sh:70). In it, `{"role":"implementor"}` has
  no model; the other rows carry opus, opus, fable, haiku and opus.
  - render.sh:84 runs `spawn-ad-hoc <role> --dry-run` with no `--model`, so
    today's adhoc-*.json goldens carry the `ROLE_DEFAULTS` model.
  - `tests/test-custom-roles.sh:56-58` (T1) diffs the whole golden
    directory.

## 2. Design

### 2.1 Scope

The scope is **roster and team member rows**, meaning store (b): the model a
**launched** member runs on.

Config `roles.<role>.model` stays exactly as it is: `ROLE_DEFAULTS` as its
seed, the directive lines, subagent dispatch, `role set --model`, and the
`/hierarchy` task-runner row. Whether the ruling reaches that store too is
OQ3, and a yes there becomes a separate spec.

Rationale for this scope:

- The friction reported is `add` writing a model the user never typed.
- Subagent dispatch has a different asker (the Orchestrator's own Agent
  call) and its own fallback (agent frontmatter).
- Folding both into one change would alter every directive golden.

### 2.2 Store

1. **`add` and `spawn-ad-hoc` store a model only when `--model` was given.**
   `memberFromFlags` stops defaulting `model` for every role, builtin and
   custom. `ROLE_DEFAULTS` is no longer read by roster.mjs. It stays the
   config seed in lib-config.mjs.
   - Effort is unchanged: stored only when `--effort` is given.
   - Auto-mode is unchanged and not covered by the ruling.
   - `add --model ""` keeps today's behaviour: it fails validation, exit 2.
2. **`edit --model ""` and `edit --effort ""` clear the field.** They delete
   the key from the row, the same way `--args ""` does (roster.mjs:3183).
   The row is then validated as today.
   - Clearing is allowed on every class, advise included: an absent model
     is valid storage, and §2.3 handles it at launch.
   - A non-empty value behaves as today.
3. **`init` needs no CLI change.** It already stores no model.
4. **Rows that already exist on disk are left alone (baseline; see OQ5).**
   A stored value is treated as user-defined. Nothing on disk records whether
   a stored `opus` was typed or defaulted, so any automatic strip would also
   delete genuine user choices. A user removes one with `edit --model ""`.
5. **Nothing a spawn verb receives at invocation is written back to a roster
   row.**
   - The team file's member record still records the model the member
     launched with, as it does today. That record is a fact about the live
     instance, not roster config.
   - Roster files are byte-identical before and after every spawn verb.

### 2.3 Ask: a structured refusal, then the driver asks

**Where the check applies.** It covers every **claude-kind** member that the
invocation would **launch**:

- `create --spawn`, `spawn-one`, `spawn-ad-hoc`, including their `--dry-run`
  (a dry run previews the real run, so it refuses the same way);
- members routed `peer` or `pane`.

It does not cover:

- non-claude kinds (a model means nothing to another CLI, matching
  `kindFieldErrors`);
- members routed `subagent` that are not launched. This exclusion stays for
  as long as that route exists. Whether it should exist for roles other than
  task-runner is §8's follow-up, not 0058;
- `create --plan` (§2.3.3) or `create --commit` (§2.3.4).

A member **needs a model** when it has no stored model and none was supplied
at invocation (§2.3.1). A stored `inherit` counts as defined: it is the
user's explicit "launch without --model".

**Refusal.** If any member needs a model, the verb refuses before it
launches anything or creates a team file. It creates no team file and
launches nothing. The stale-team clear that already runs before this check,
the same one `--plan` does, is unaffected.

- JSON on stdout, exit 2, `message` also on stderr prefixed `roster.mjs: `.
  This is exactly 0057 §2.8's emission.
- Reuse `refuseTeamName`'s emission path and `rerunWithTeamPlaceholder`'s
  argv rebuilding and quoting. Generalize them; do not write a second
  quoting implementation.

| field | value |
|---|---|
| `ok` | `false` |
| `refused` | `"member-model-undefined"` |
| `verb` | `"create"` \| `"spawn-one"` \| `"spawn-ad-hoc"` |
| `members` | array, in roster order, one entry per member needing a model: `{name, role, class, allowed, fallback}` |
| `members[].allowed` | the member's class allowlist (`CLASSES[class].models`), in allowlist order |
| `members[].fallback` | `{model, from}` per §2.4, where `from` is the name of the member it came from; `null` when §2.4 yields none. **r4:** a legwork member is listed only when task-gopher is not installed, and then always has `null` (§2.4.2). |
| `rerun` | the invoking argv plus one invocation flag per listed member with the literal placeholder `<MODEL>` (see below). Any existing invocation flag for those members is stripped first. |
| `rerun_fallback` | the same argv with each `<MODEL>` replaced by that member's `fallback.model`; `null` if any listed member's `fallback` is `null`. (r4: auto-skipped legwork members never appear here; see §2.4.2.) |
| `message` | self-sufficient instructions for a driver that is not running the agent-team skill (see below) |

Illustrative `rerun` forms (not prescriptive):
- create: `… --member-model myrepo-implementor=<MODEL>`
- spawn-one: `… --member myrepo-implementor --model <MODEL>`. The rerun
  pins `--member` so the answer reaches the member that was named.
- spawn-ad-hoc: `… --model <MODEL>`

The `message` must say all of the following, in plain words:

- these members have no model;
- the model is the user's choice: ask with AskUserQuestion, one question per
  member, with the `fallback` model as the first option when there is one,
  then rerun `rerun` with each `<MODEL>` replaced by the answer;
- only if the driver is a top-level session that cannot ask the user
  (§2.4.1), run `rerun_fallback`;
- a subagent never runs `rerun_fallback`; it returns this refusal to its
  caller;
- if `rerun_fallback` is null, stop and report the members;
- never choose a model any other way;
- this is not a launch failure, so do not offer the subagent opt-in.

**Precedence.** 0057 §2.8's `team-name-unusable` check runs first. The model
check runs only once the team name is usable.

#### 2.3.1 Invocation-time model flags

- **`create` (every phase: `--plan`, `--spawn`, `--commit`, `--from`):**
  `--member-model <name>=<model>`, repeatable.
  - `<name>` must be a member of this invocation's plan.
  - `<model>` must pass that member's class allowlist, reusing
    `validateMember`'s check and error text.
  - Fail with exit 2 when the name is unknown (list the valid names), when
    the same name appears twice, or when the member is non-claude.
  - The value overrides a stored model for this invocation only.
- **`spawn-one`:** `--model <model>`, applied to the member it launches, with
  the same validation and override rule. `SPAWN_ONE_FLAGS` gains `model`.
- **`spawn-ad-hoc`:** keeps `--model`. With no row, the flag is the
  definition.
- Values supplied at invocation are never written to a roster (§2.2.5).
  Docs: `docs/cli-tools.md` and the roster.mjs usage header list the new
  flags.

#### 2.3.2 History

`create --from <history>` builds members from history records
(`planMembersFromHistory`, :2112-2124). A model on a history record counts as
**defined**: it is what that recorded team ran on, and re-creating the team
means reproducing it. A history record with no model needs one, exactly as a
roster row does.

#### 2.3.3 `create --plan` reports and does not refuse

`--plan`, bare or not, never refuses on models. The skill builds the
team-name question from the bare plan (0057), and the model questions join
that same round.

- The plan output gains top-level `members_needing_model`. Its entries have
  the same shape as the refusal's `members`, built by the same code.
- The key is present only when non-empty, and placed last among the plan's
  keys.
- Each member entry's `model` reflects the stored or `--member-model` value,
  so its `spawn.launch` carries `--model` when that value is not inherit.
- A listed member's `spawn.launch` stays as today (no `--model`). The skill
  must not launch from a plan that still lists members.

#### 2.3.4 `create --commit` never refuses on model

The panes are already up, so refusing would strand them.

- When members are hydrated by name, the team record's `model` is the
  `--member-model` value if one is given, else the row's value, else absent.
- A `--verified` object keeps its own model, as today.

### 2.4 Fallback: the highest defined reasoning agent

**Interpretation (ruled, OQ1: "Borrow the highest model").** An undefined
member keeps its own role and contract. It launches on the highest defined
**model** its class allows. Its work is never re-routed to a different agent.

**Candidates (r2, OQ2a).** Models defined for claude-kind members of the
**chain work classes `design`, `review` and `implement`**, custom roles of
those classes included, drawn from:

- the stored rows of the roster block this invocation reads its members from
  (the same `resolveRoster` result; for spawn-ad-hoc, the block its scope
  resolves, if any);
- plus any model supplied at invocation for such a member.

Excluded:

- **advise-class members (the Ultra-Advisor);**
- legwork members;
- non-claude kinds;
- `inherit`, because the CLI cannot know its tier (an inherit-launched pane
  runs the child's own default model);
- team member records.

Select candidates by class, not by role name, so a custom class member counts
exactly as its class does.

**Pick.** For a member of class C:

1. Drop candidates not in C's allowlist.
2. Take the highest tier, ranked by the existing `TIER`/`tierOf`. Do not add
   a second ranking.
3. Break ties by roster order.
4. `fallback = {model, from: <that member's name>}`, or `null` when no
   candidate survives.

What this gives each class:

| Class | Fallback |
|---|---|
| design, review, implement | the highest defined chain model (the filter removes nothing) |
| advise | the highest defined **fable/opus** among the chain candidates. If they hold only sonnet, or nothing, `null`: an Ultra-Advisor never launches unattended on a non-top-tier model. This is the member-row counterpart of the advise rule. An advise member can borrow from the chain; the chain never borrows from it. |
| legwork | never borrows a chain model. **r4:** with task-gopher installed it is skipped automatically and never listed; otherwise it is listed with `null` (§2.4.2, OQ2b). |
| any reasoning class, when no chain candidate exists | `null`. There is no defined agent to borrow from. |

Effort is untouched by the fallback (ruled, OQ4: "only model asks"). An
undefined effort is never asked about and launches with Claude's default, as
today. A fallback copies only a model.

#### 2.4.2 Legwork: skipped automatically and handed to task-gopher, never asked

*r4. The OQ2b ruling came in three steps:*

1. *Verbatim: "no fallback unless task-gopher is available".*
2. *The reading "hand its work to task-gopher" (r3).*
3. *For the handoff: "Always skip, never ask" (r4).*

*Withdrawn: r2's borrowed task-gopher model, and r3's asked handoff with its
`{handoff}` fallback shape and `--skip-member` flag. Nothing outside this
subsection and the lines marked "r4" changes.*

**The rule.** This applies to a claude-kind legwork-class member (task-runner,
or a custom legwork role) with no stored and no invocation model.

- **task-gopher installed** (the CLI check below): the member is **skipped
  automatically**.
  - It is never launched.
  - It is never listed in the §2.3 refusal or in `members_needing_model`,
    and it is never asked about.
  - Its legwork goes to `task-gopher:task-gopher` subagents, which the
    standing rule permits for legwork.
  - The skip happens the same way whether the driver is interactive,
    unattended or a subagent.
- **task-gopher not installed:** exactly §2.3, as for any member. It is listed
  with `fallback:null`. An interactive driver asks; an unattended one stops
  and reports.
- A legwork member **never borrows a chain model**.
- A legwork member **with** a model (stored or supplied) launches normally.
  It is never skipped.

**create (every phase).**

- A skipped member is left out of the launch set and out of the team file's
  `members`: it never ran.
- Skipping is not a launch failure, so it never marks the team `partial`.
- It never causes a refusal. If it is the only member without a model,
  create proceeds.
- Output (`--plan`, `--spawn`, `--commit`) lists it under a top-level
  `skipped_members: [{name, role, handoff:"task-gopher:task-gopher"}]`.
  - The key is present only when non-empty. The fixture's task-runner holds
    `haiku`, so no golden changes and §4 exception 1 stands.
  - In `--plan`, a skipped member appears in neither `members[]` nor
    `members_needing_model`.
  - *(r5: r4's `relaunch` field is removed; see below.)*
- **Nothing persists.** The roster row is untouched and stays model-less, and
  every invocation decides again.

**spawn-one and spawn-ad-hoc never see a legwork member (r5, verified by the
Implementor).**

- `spawnOneCore` accepts only `chainRoles(registry())`.
- spawn-ad-hoc's `adHocRoles` is `chainRoles(registry())`.
- `CLASSES.legwork` is `chain:false`.
- `spawn-one task-runner` and `spawn-ad-hoc task-runner` exit 2 on the role
  check before any model logic, as they do today. **create is the only verb
  that launches a legwork member.**
- So r4's spawn-one/spawn-ad-hoc skip branch is unreachable, and **is
  deleted**. Those verbs' role check and messages are unchanged.
- Rejected: widening spawn-one/spawn-ad-hoc to launch legwork. That would be
  a new capability, would change the adhoc-task-runner.json golden (which
  pins today's refusal), and would serve only r4's `relaunch`.

**`rerun` and `rerun_fallback` are r2's.** An auto-skipped member is never
listed, so it never appears in either. A legwork member that *is* listed
(task-gopher not installed) has `fallback:null`, so `rerun_fallback` is
`null`, meaning stop and report.

**Installed but not dispatchable: the driver checks *before* create, and
tells the CLI (r5, replacing r4's `relaunch`).** The CLI sees installs, not
enablement. Only the driver's list of available agent types shows whether
`task-gopher:task-gopher` can actually be dispatched, for example when the
plugin is installed but disabled.

- **`create --no-legwork-handoff`** (boolean, every phase): for this
  invocation the CLI treats task-gopher as **not installed**.
  - A model-less legwork member is then handled by plain §2.3: it is listed
    in `members_needing_model` and the refusal with `fallback:null`.
  - So an interactive driver asks, and supplies the model with
    `--member-model <name>=<model>` (legwork allowlist, haiku first).
  - An unattended driver gets `rerun_fallback:null`, stops and reports.
  - This is exactly OQ2b's "no fallback" for an unavailable task-gopher.
- **The driver passes it** on every create phase, the way `--roster` is
  carried, whenever `task-gopher:task-gopher` is not among its available
  agent types. The agent-team skill decides this before the bare `--plan`.
- **A driver that skipped the check** (no skill) and learns only after
  `--spawn` that task-gopher is not dispatchable has launched a team without
  that member. The `skipped_members` `message` tells it to tell the user
  which member was not launched and why. Adding it means `disband`, then
  `create --no-legwork-handoff`. No single-member legwork launch verb exists
  (see above), and this spec does not add one.
- The flag is the smallest mechanism that lets the only party who can see
  enablement tell the one party who decides the skip. r4's "no flag"
  depended on `relaunch`, which cannot work.

The `message` on every output that carries `skipped_members` states the
handoff and the not-dispatchable rule, so a driver without the skill acts
correctly.

**The subagent dispatch after a handoff** uses the Task-Runner line the
directive already prints. Under the default config that line is
`Agent(subagent_type:"task-gopher:task-gopher", …)`, from `subagentType` in
lib-config.mjs:1708-1714. Its model is config-roles territory (OQ3 deferred),
and 0058 does not set it.

- **Edge, not changed here:** if the user's config overrides the task-runner
  delegate, the directive names `ah:task-runner` rather than task-gopher. The
  handoff still means "task-gopher", per the ruling. The skip output's
  `message` names task-gopher explicitly, so the ruling wins for that legwork.

**"Available" means installed, detected in the CLI.** This is unchanged from
r2, except that the frontmatter model is no longer read.

- `roster.mjs` decides it where it resolves the members an invocation would
  launch. No hook needs it.
- Reuse `locateAgentFile` (lib-config.mjs:1392-1426). It reads
  `~/.claude/plugins/installed_plugins.json` and takes the first install
  record whose `installPath` holds `agents/task-gopher.md`.
- If that record or file is not found, or installed_plugins.json is
  unreadable, task-gopher is not installed. The member is then listed with
  `fallback:null`, with no error.
- **Never a cache glob.** The prose check at commands/hierarchy.md:112 is the
  anti-pattern (§8).
- **Enabled/disabled state (r4).** The CLI does not read `enabledPlugins`.
  No code in the repo reads it today, and whether an absent key means enabled
  is unverified. The driver's own list of available agent types reflects
  enablement exactly. Its check is the "Installed but not dispatchable" rule
  above.

`ROLE_DEFAULTS["task-runner"]`, config `roles.task-runner.*` and task-gopher's
frontmatter `model:` are not read for this fallback.

#### 2.4.1 When the fallback applies instead of asking

*r2 revision, standing user rule, verbatim: "no agent in hierarchy should
ever be sent to a subagent except for task-runner".* Under that rule no
hierarchy role, the Orchestrator included, runs as a subagent. So r1's
"subagent driver" case is gone.

The fallback applies **only** when the driver is a **top-level session that
cannot ask**: AskUserQuestion is unavailable because the run is
non-interactive (`claude -p`, the SDK, headless). An interactive top-level
driver always asks.

- **A subagent never applies the fallback.** A task-runner subagent is the
  only kind that may exist. If one runs a spawn verb and gets this refusal,
  it returns the refusal to its caller unchanged, and does not run
  `rerun_fallback`. Spawning members is the Orchestrator's job, and its
  caller can ask.
- **The CLI never applies the fallback on its own.** It cannot tell whether
  its caller can ask, because it always runs under the Bash tool with no
  TTY. So it always refuses and leaves the choice to the driver.
- **SessionStart and the other hooks** never launch anything.
- **The route gate never spawns** (fact §1). **r2 change:** the
  `spawn-ad-hoc` command it prints no longer carries `--model` copied from
  the denied Agent call (pretooluse-route-gate.mjs:114-117, :248).
  - Why: that model is not a user definition. The Orchestrator took it from
    the directive, which prints config `roles.<role>.model` seeded from
    `ROLE_DEFAULTS`. Copying it would launch a pane on a model the user never
    defined, which is exactly what this spec stops.
  - It would also make a config-role model count as a member's definition,
    contrary to OQ3(b)'s deferred baseline.
  - The printed command therefore reaches the §2.3 refusal and its ask.
  - Nothing else in the gate changes. This spec does not decide whether the
    gate may still let a non-task-runner role through as a subagent; that is
    the separate audit (§8).

### 2.5 The interactions the brief asked about

- **The advise-class rule (ultra-advisor needs an explicit fable/opus).**
  Unchanged for role definitions (`checkCustomRow`, `role set`). For member
  rows:
  - storage may be empty (`add` without `--model`, `edit --model ""`);
  - at launch the model comes from the stored row, the invocation, or a
    fable/opus fallback, and nothing else;
  - `inherit` stays refused by the advise allowlist, as today.
- **`inherit` as the implementor default.**
  - `add --role implementor` no longer stores `inherit`.
  - `inherit` stays a valid explicit value for design, review, implement and
    legwork, and is offered in the question where the class allows it.
  - It is never a fallback (§2.4).
  - `ROLE_DEFAULTS.implementor = inherit` stays as the config seed, so the
    directive's "OMIT model" line is unchanged.
  - The implementor agent frontmatter keeps no `model:`
    (tests/test-agent-frontmatter.sh:61).
- **The SessionStart directive's per-role lines are unchanged.** They print
  store (a), which this spec does not touch. A peer-mode "spawn" line leads
  the Orchestrator to `spawn-one`, whose refusal carries its own instructions,
  so no directive text changes and no directive golden changes.
- **Custom roles' `--model`.**
  - `role set <custom> --model` keeps defining the role's subagent-dispatch
    model, including `checkCustomRow`'s implicit `inherit` and the advise
    rule. It is no longer **copied into member rows** at `add`.
  - This removes today's asymmetry, where builtin members were seeded from
    `ROLE_DEFAULTS` and custom members from the registry. Neither is seeded
    now.
  - Whether a user-set role model should count as the member's definition is
    OQ3(b).
- **A custom role defined with no model (r2 check; the user's `docs-writer`,
  class implement, global, saved with "Leave unset"). This is sane today, and
  0058 changes nothing for it at the role level.**
  - **On disk:** `roles.docs-writer` in `~/.claude/agent-hierarchy.json`
    stores `{class, routes}` with no `model` key. `role set` writes the raw
    row (roster.mjs:443) and adds `model` only when `--model` is given
    (:332).
  - **Resolved:** `checkCustomRow` fills in `"inherit"` in memory
    (lib-config.mjs:1042/1046). The implement class raises no warning.
  - **`role list`** shows `inherit` (roster.mjs:266).
  - **Directive:** the role appears as an in-chain alternative to Implementor
    with the "OMIT `model`" Agent line (lib-config.mjs:1730-1731), or the
    peer/spawn variant depending on the subagent opt-in.
  - **Dispatch** passes no model. The scaffolded agent file has no `model:`
    (`scaffoldText`, roster.mjs:287-304; `~/.claude/agents/docs-writer.md`
    confirmed), so the subagent runs on the session's model.
  - **Nothing breaks:** `tierOf("inherit")` returns null safely, and no
    reader accesses `.model` unguarded.
  - **Caveat:** "unset" and an explicit `--model inherit` cannot be told
    apart once resolved. Under OQ3's deferral that does not matter.
  - **What 0058 does change here is member rows.** Today `add` and
    `spawn-ad-hoc --role docs-writer` copy the *resolved* `"inherit"` into
    the member row (memberFromFlags :1033 reads `registry()`), even though
    the user chose to leave it unset. That is the friction behind this spec.
    After 0058 nothing is copied, and a docs-writer member is asked for its
    model at launch.
  - The agent-role skill's model question (skills/agent-role/SKILL.md:74:
    "class default first") is role-level, so it is deferred with OQ3. The
    "Leave unset" option the user saw was improvised by the session and does
    not appear in the skill.
- **`create --plan` goldens.** See §4 exception 1.
- **Status.** `statusReport` already prints `model=?` for a row with no model
  (lib-config.mjs:2118). Unchanged.

### 2.6 Skills

**skills/agent-roster/SKILL.md**

- **Init step 5 (:125-148).** Keep asking each picked role's model, effort
  and auto-mode, but:
  - delete "Prefill/offer defaults from `ROLE_DEFAULTS`… do not invent
    separate defaults here";
  - the model question's **first option is "Undefined — choose at each
    spawn"**, followed by models valid for the role's class, with the rest
    via Other;
  - no model option is marked "(Recommended)" and none is preselected;
  - the effort question likewise starts with "Undefined";
  - run `add` with `--model` or `--effort` only for values the user picked;
  - the auto-mode question is unchanged.
- **The verb list (:85-86)** documents `edit --model ""` and
  `edit --effort ""` as "clear". Line 3 is unchanged.

**skills/agent-team/SKILL.md**

- **Create flow (:225-243).** When the bare `--plan` output has
  `members_needing_model`:
  - add one question per listed member to the same AskUserQuestion round as
    the team name and roster questions (at most 4 per call; further calls if
    needed);
  - options: the member's `fallback` model first when there is one,
    labelled with its source (for example "fable — highest defined
    (myrepo-architect)") and not marked Recommended, then `allowed` entries,
    up to 4 options. Legwork lists haiku before the reasoning models;
  - **r5, before the bare `--plan`:** if `task-gopher:task-gopher` is not
    among the session's available agent types, add `--no-legwork-handoff`
    to every create phase. Model-less legwork members then arrive in
    `members_needing_model` and are asked about like any other member;
  - **r4/r5, `skipped_members`** (create output): never ask about these
    members, and send their legwork to `task-gopher:task-gopher` subagents;
  - carry `--member-model <name>=<answer>` to every later phase, the same
    way `--roster <r>` is carried;
  - if the skill cannot ask (§2.4.1), use each member's `fallback`; if any
    is null, stop and report.
- **Quick one-peer path (:52-56), spawn-one path (:644-645), and spawn-ad-hoc
  (:86).** Handle `refused: "member-model-undefined"` the way
  `team-name-unusable` is handled: follow its `message`, ask, rerun `rerun`.
  It is not a launch failure, and the subagent opt-in is not offered.

### 2.7 Tests that encode the old default

These tests assert that `add` or `spawn-ad-hoc` fills in a model. They are
updated to the new rule, and this is expected, not a regression:

- test-roster-agent-kind.sh:301-302 (4.2e "still gets ROLE_DEFAULTS.implementor
  (inherit)") inverts: the row has no `model` key.
- test-roster-agent-kind.sh:768+ (§1.3 "`add` fills model from ROLE_DEFAULTS")
  inverts in the same way.
- test-roster-worktree.sh:~160 and test-roster-spawn.sh:35-62: the
  Implementor adapts them, keeping what each one asserts.

Any other test that `add`s or ad-hoc-spawns without `--model` and then
launches gains an explicit `--model` equal to the old default for that role.
That preserves the test's subject.

- **Never weaken an assertion to get past the refusal.**
- The Implementor reports the full list of tests touched and the reason for
  each.

## 3. Files

| File | Change |
|---|---|
| hooks/roster.mjs | `memberFromFlags` stops defaulting model (§2.2.1); `edit` clears on `""` (§2.2.2); the §2.3 check and refusal, generalizing 0057's emission and rerun helpers; the §2.4 fallback using `TIER`/`tierOf`; `--member-model` on create (all phases) and `--model` on spawn-one (§2.3.1); `members_needing_model` in plan output (§2.3.3); commit hydration honours `--member-model` (§2.3.4); usage header; stale "role-default trap" comments at :1030/:3155 rewritten or removed |
| hooks/lib-roster.mjs | only if the shared allowlist check needs exporting for `--member-model` validation. No rule changes. |
| hooks/pretooluse-route-gate.mjs | the printed `spawn-ad-hoc` command drops the copied `--model` (r2, §2.4.1). Nothing else changes. |
| hooks/lib-ah-cli.mjs | `ROSTER_BOOL_FLAGS` gains `no-legwork-handoff` (r5), which keeps the existing drift test against roster.mjs's `BOOL_FLAGS` passing |
| skills/agent-roster/SKILL.md | §2.6 |
| skills/agent-team/SKILL.md | §2.6 |
| docs/cli-tools.md | new flags (`--member-model`, spawn-one `--model`, r5 `--no-legwork-handoff`); `edit ""` clears; the `member-model-undefined` refusal; r4 legwork auto-skip and `skipped_members` |
| tests/fixtures/0056-i1/render.sh | :84 passes `--model <the role's old default>` (§4 exception 2) |
| tests/fixtures/0056-i1/golden/plan-{terminal,tmux,herdr}.json | §4 exception 1 |
| tests/ (new file or an existing roster test file, Implementor's choice) | §5 cases |
| tests enumerated in §2.7 | updated per §2.7 |
| plugin.json and root marketplace.json | version bump together (repo convention) |

## 4. Must not change

**Ruled exceptions:**

1. **Plan goldens (recomputed in r2 for OQ2a).** In `plan-terminal.json`,
   `plan-tmux.json` and `plan-herdr.json` exactly one thing changes: a
   trailing top-level `members_needing_model` with one entry, in `out()`'s
   formatting:
   ```
   {"name":"myrepo-implementor","role":"implementor","class":"implement",
    "allowed":["opus","sonnet","fable","inherit"],
    "fallback":{"model":"opus","from":"myrepo-architect"}}
   ```
   How the fallback is derived from the fixture roster (render.sh:70):

   | Row | Model | Candidate? |
   |---|---|---|
   | architect | opus | yes |
   | implementor | none | the member needing a model |
   | reviewer | opus | yes |
   | ultra-advisor | fable | no, advise class is excluded (OQ2a) |
   | task-runner | haiku | no, legwork is excluded |
   | implementor-2 | opus | yes |

   The highest tier among candidates is opus (3). The tie goes to roster
   order, so the first opus row, **myrepo-architect**, wins. r1's
   `fable`/`myrepo-ultra-advisor` value is withdrawn.
2. **render.sh:84 input.** For each chain role it passes `--model` equal to
   that role's old `ROLE_DEFAULTS` value: `opus` for architect and reviewer,
   `fable` for ultra-advisor, and `inherit` for implementor. The task-runner
   iteration passes **no** `--model` (see the r5 note below). Every adhoc-*.json golden stays **byte-identical**, which keeps
   their launch-shape coverage.
   - *r5 note:* adhoc-task-runner.json pins spawn-ad-hoc's role-check
     refusal, because legwork is not ad-hoc-spawnable. The task-runner
     iteration needs no `--model`. Leave it as it is, so the refusal text
     cannot pick up the extra flag. The new refusal is covered by §5, not by
   these goldens.

**No other golden changes.** That includes every directive-*.txt,
status-report.txt, derived.json, notice-*.json and gate-*.json.

**Unchanged behaviour:**

- `ROLE_DEFAULTS` (values, and its role as the config seed), `resolveConfig`,
  config `roles.<role>.model`, the directive, subagent dispatch, `role set`,
  `checkCustomRow`, `/hierarchy`.
- `CLASSES` allowlists, `EFFORT_VALUES`, `validateMember`'s rules, and the
  spawnShape `inherit` guard.
- Effort storage and launch (OQ4 baseline), and auto-mode.
- Non-claude kinds and subagent-routed members: never asked, never refused
  on model.
- The route gate never spawns. Its printed commands are unchanged except that
  `spawn-ad-hoc` no longer carries a `--model` copied from the Agent call
  (r2, §2.4.1). The gate-*.json goldens stay byte-identical, because
  render.sh:104's Agent input has no `model`. The gate's allow and deny
  decisions are unchanged.
- 0057 §2.8's team-name check and its precedence.
- No spawn verb writes a roster file.
- `create --commit` never refuses on model.

## 5. Acceptance

Tests run in a sandbox with HOME redirected.

- **A1.** `add --role R` with no `--model`, for each builtin role and for a
  custom role whose `roles.<name>.model` is set: the row has no `model` key.
  With `--model opus`, it is stored.
- **A2.** `edit --member X --model ""` removes `model`, `--effort ""` removes
  `effort`, and the rest of the file is byte-identical. This works on an
  ultra-advisor row too. `add --model ""` still exits 2.
- **A3.** A pre-existing row holding `"model":"opus"` is untouched by every
  0058 path.
- **B1.** `spawn-one implementor --dry-run` against a model-less implementor
  row:
  - exit 2;
  - stdout JSON with `refused:"member-model-undefined"`, `verb:"spawn-one"`
    and `members[0]` fields per §2.3;
  - `rerun` contains `--member <name> --model <MODEL>`;
  - stderr starts `roster.mjs: `;
  - no team file is created.
- **B2.** B1 with `--model sonnet`: the launch carries `--model sonnet`, the
  team record has `model:"sonnet"`, and the roster file is byte-identical.
- **B3 (r2).** Fallback. Roster: ultra-advisor fable, architect opus,
  reviewer sonnet, implementor with no model.
  - The implementor's `fallback` is `{model:"opus", from:<architect name>}`.
    The Ultra-Advisor's fable is not a candidate.
  - `rerun_fallback` equals `rerun` with `<MODEL>` replaced by `opus`.
- **B3a (r2).** Roster: ultra-advisor fable, implementor with no model, and
  nothing else. `fallback:null`, because the only defined model is
  advise-class.
- **B3b (r2).** A custom implement-class role member holding `fable`, plus a
  model-less architect: the architect's fallback is `fable` from the custom
  member. This proves candidates are chosen by class.
- **B4 (r2).** A model-less ultra-advisor:
  - with an architect on `opus`: `fallback {model:"opus", from:<architect>}`;
  - with only `sonnet` among chain members: `fallback:null` and
    `rerun_fallback:null`.
- **B5.** No non-inherit chain model defined, or only `inherit` defined:
  every reasoning-class `fallback` is null.
- **B6 (r4).** A model-less task-runner is auto-skipped when task-gopher is
  installed, and otherwise listed with `fallback:null`. It never gets a chain
  model.

The redirected-HOME fixture "TG" for B6c–B6h: `installed_plugins.json` has a
task-gopher record whose `installPath` holds `agents/task-gopher.md`.

- **B6c (r4).** TG, plus a roster of architect `opus`, reviewer `opus` and a
  model-less task-runner.
  - `create --spawn` exits 0 with **no refusal**, and launches the architect
    and reviewer only.
  - Output has `skipped_members:[{name, role:"task-runner",
    handoff:"task-gopher:task-gopher"}]`, with no `relaunch` (r5).
  - The team file has no task-runner member and is not `partial`.
  - The roster file is byte-identical.
  - `create --plan` on the same roster: the task-runner appears in neither
    `members[]` nor `members_needing_model`, and is in `skipped_members`.
- **B6c2 (r5, replaces r4's).** TG. `spawn-one task-runner` and
  `spawn-ad-hoc task-runner` behave exactly as before 0058: the role check
  exits 2, with the same messages and no skip output. The adhoc-task-runner.json
  golden is byte-identical.
- **B6c3 (r4).** TG, plus a model-less architect and a model-less
  task-runner.
  - `create --spawn` refuses, listing **only** the architect. Neither `rerun`
    nor `rerun_fallback` mentions the task-runner.
  - Running `rerun` with the architect's model launches it and auto-skips the
    task-runner.
- **B6d (r4).** No task-gopher record: the task-runner is listed with
  `fallback:null`, and `rerun_fallback` is `null`. Add a
  `~/.claude/plugins/cache/x/task-gopher/` directory with no record: still
  listed, which proves no cache glob is used.
- **B6e (r4).** A record exists but `agents/task-gopher.md` is missing, or
  `installed_plugins.json` is unreadable: the task-runner is listed with
  `null`, with no crash.
- **B6f (r4).** TG, plus an architect holding `opus`: the task-runner is
  skipped, never `{model:"opus"}`.
- **B6g (r5, replaces r4's).** TG, plus B6c's roster, with
  `create --spawn --no-legwork-handoff`:
  - it refuses, listing the task-runner with `fallback:null`, and
    `rerun_fallback` is `null`;
  - rerunning with `--member-model <tr>=haiku --no-legwork-handoff` launches
    all three, the task-runner on haiku;
  - `create --plan --no-legwork-handoff` lists it in `members_needing_model`
    and has no `skipped_members`;
  - the roster is byte-identical throughout.
- **B6h (r4).** TG, plus a task-runner storing `haiku`: it launches normally,
  is never skipped and is never listed.
- **B6a (r2).** Effort is never listed and never asked (OQ4). A member with a
  stored model and no effort launches with no refusal and no `--effort`.
- **B6b (r2).** The route gate's denial text for an Agent call that carried
  `model:"opus"` prints a `spawn-ad-hoc` command with **no** `--model`.
  Nothing else in the denial text changes.
- **B7.** `create --spawn` with two model-less members:
  - refuses listing both, and nothing is launched;
  - rerunning with `--member-model` for both proceeds.
- **B8.** `create --plan`:
  - never exits 2 on models;
  - `members_needing_model` is present only when a member needs one;
  - `--member-model` for all such members removes the key, and each
    `spawn.launch` carries its `--model`.
- **B9.** `--member-model` with an unknown name, a duplicate name, a
  non-claude member, or a model outside the class allowlist (for example
  `ultra-advisor=sonnet`, `architect=haiku`): exit 2.
- **B10.** `spawn-ad-hoc architect` without `--model`: refuses with
  `verb:"spawn-ad-hoc"`. With `--model opus` it behaves as today.
- **B11.** A roster that triggers both `team-name-unusable` and a model-less
  member: the team-name refusal is the one returned.
- **B12.** `create --commit --verified <names> --member-model X=opus`: the
  team record for X has `opus`. The same command without the flag records the
  row's value or no model, and exits 0.
- **B13.** A non-claude-kind member and a subagent-routed member with no
  model: never listed, never refused.
- **C1.** test-custom-roles.sh T1: the only golden diff is §4 exception 1.
- **C2.** The full suite is green. §2.7's touched-test list is reported, and
  the Reviewer confirms no assertion was weakened.
- **D1.** agent-roster SKILL.md no longer contains "Prefill/offer defaults
  from `ROLE_DEFAULTS`". Step 5 offers "Undefined" first.
- **D2.** agent-team SKILL.md handles `member-model-undefined` at all three
  sites in §2.6, and the create flow reads `members_needing_model`.
  - **r4:** it covers `skipped_members`: legwork goes to
    `task-gopher:task-gopher` and nothing is asked.
  - **r5:** it covers the not-dispatchable case: check the available agent
    types before the bare `--plan`, and carry `--no-legwork-handoff`.

## 6. Rulings (r2) and deferred questions

**Ruled:**

- **OQ1 — ruled "Borrow the highest model".** The member keeps its role and
  launches on the highest defined model its class allows. Its work is never
  re-routed (§2.4).
- **OQ2a — ruled "No, exclude it".** Advise-class (Ultra-Advisor) models are
  not fallback candidates. Only design, review and implement members count,
  custom roles of those classes included (§2.4). An advise member can still
  *borrow* a fable/opus chain model.
- **OQ2b — ruled, verbatim: "no fallback unless task-gopher is available".
  r3: the user chose the reading "hand its work to task-gopher". r4: "Always
  skip, never ask".** With task-gopher installed, a model-less legwork member
  is skipped automatically and never listed or asked about, and its legwork
  goes to `task-gopher:task-gopher` subagents. Otherwise there is no fallback.
  See §2.4.2.
- **OQ4 — ruled "No, only model asks".** An undefined effort never triggers
  the ask; Claude's default applies. No `--member-effort` flag and no
  explicit-default effort token.

**Standing rule (r2), verbatim:** "no agent in hierarchy should ever be sent
to a subagent except for task-runner". 0058 applies it to the fallback trigger
(§2.4.1). Removing the existing subagent paths for other roles is a separate
audit (§8), not part of this spec.

**Deferred (non-blocking; baselines stand):**

- **OQ3 — config `roles.<role>.model`.** Deferred: config roles, the
  directive and subagent dispatch are unchanged; `role set --model` does not
  define members' models.
  - (a) Largely overtaken by the standing rule. Once non-task-runner roles
    are never subagents, their `roles.<role>.model` has no dispatch to
    govern. That belongs to the §8 follow-up.
  - (b) Whether a user-set `role set <R> --model` should count as the
    definition for R's model-less members remains open.
- **OQ5 — rows already holding a default.** Deferred: they are left alone
  and count as defined. A user clears one with `edit --model ""`.

## 7. Decisions made here (overridable)

- The invocation flags are `--member-model <name>=<model>` on every create
  phase, and `--model` on spawn-one. spawn-ad-hoc keeps its `--model`.
- An invocation value overrides a stored one for that run only. It is never
  written back.
- History records count as defined.
- The team record keeps the launched model.
- `--dry-run` refuses like the real run.
- `create --plan` reports and never refuses; `--commit` never refuses on
  model.
- The fallback is offered first in the question but not marked Recommended.
- The render.sh adhoc input passes explicit models, so those goldens stay
  byte-identical.

Added in r2:

- Candidates are chosen by class, not role name, so custom design, review and
  implement members count.
- Ties in the fallback go to roster order.
- A subagent never runs `rerun_fallback`; it returns the refusal to its
  caller.
- The route gate stops copying the Agent call's model into its printed
  `spawn-ad-hoc`.
- task-gopher availability means installed, via `locateAgentFile`. r3 amends
  this in §2.4.2.
- *(r2's "legwork fallback value is task-gopher's frontmatter `model:`" is
  withdrawn in r3.)*

Added in r4 (r3's `--skip-member`, `{handoff}` fallback and asked handoff are
withdrawn):

- The legwork auto-skip is decided in the CLI on "installed".
- A skip is not a launch failure, so it never makes the team `partial`.
- *(r5)* Dispatchability is checked by the driver **before** create and
  passed as `--no-legwork-handoff`. r4's `relaunch`, its "no flag" decision
  and its spawn-one/spawn-ad-hoc skip branch are withdrawn, because those
  verbs never launch legwork.

## 8. Out of scope, noted for follow-up (not specified here)

- **Subagent paths for roles other than task-runner** (the standing rule).
  The audit was reported to the Orchestrator for the user's scope choice.
  0058 only changes the fallback trigger (§2.4.1) and the gate's `--model`
  copy.
- **commands/hierarchy.md:112 detects task-gopher with a cache glob.** It
  should use the installed_plugins.json lookup that §2.4.2 uses.
- **Walkthrough gaps reported by the Orchestrator:**
  1. `dismiss` of a team's last member leaves an empty, still-owned team
     file, which `create` then treats as live.
  2. `create --plan` does not flag derived member names that live sessions
     already hold.

  Both are team-lifecycle and naming hygiene, not member models.
