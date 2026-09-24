# 0056 — User-defined roles

Status: r3.7, design, final pending review. Author: Architect.

**r3.7** rules on the review's four spec-defects (`0056-review.md`):

- **N5:** the `remove` opt-in delete is guarded. It is offered only for a
  bare repo-level file, warned for a user-level file, and never offered for a
  plugin file (§1.15c).
- **N6:** the tier-rule prose sites are added to §1.6. They append custom
  labels only when any exist, so I1 holds.
- **N7:** `/ah:pipeline` now routes the Design and Escalate steps too
  (§1.14g).
- **N9:** the spec now states that the subagent-route routing block is
  unfiltered (§1.17).
- **S1 (a clarification that aligns with the review):** contract injection
  keys on the session's actual `agent_type`, not on the row (§1.17 Delivery).

**r3.6** fixes the root cause of the custom-name misparse (§1.10). Custom role
names now match only as a suffix-anchored trailing role segment, with the
longest match winning; they never match by substring. When the longest match
is a built-in, resolution falls through to the unchanged legacy scan.
Excluding such names at read time was refused. Test C18 covers it.

**r3.5** adds the fix kind `remove-file` to the §1.16d table. It is advisory
only: the skill's fix loop never deletes or renames a file for it, and shows
it as an instruction to the user instead (§1.15c).

**r3.4** rules on three gaps the Implementor raised, and confirms one of its
calls.

- **G1: two custom rows with the same agent.** Every colliding custom row is
  excluded, and each gets a warning (§1.4 Uniqueness).
- **G2: a built-in override that fails its contract.** It reverts to
  `ah:<role>` and is named in the Unavailable line, both in the directive at
  SessionStart (§1.9) and at spawn, where the member is spawned as
  `ah:<role>` rather than refused (§1.7).
- **G3: `agent` and `delegate` on the same task-runner row.** `agent` beats
  `delegate` (§1.6).
- **Directive item 8** now names a task-runner override when one is set
  (§1.6). This gap surfaced from G3.
- **Lookup step 2 never matches `delegate`.** This confirms the Implementor's
  call (§1.4 rules). **All forks are resolved**; §6
records I1 and J1.

**r3.2** reconciles the spec with `0056-evidence.md`:

- E1b, E1c, E2 (for project agents), E3 and E4 are done.
- The sections that changed:
  - §1.4: the lookup is confirmed against real payloads.
  - §1.4a: a new `shadowed-agent` warning.
  - §1.7: model precedence.
  - §1.15b/c: scoped tool entries are never used as restrictions.
  - §1.16a/c: new warnings `scoped-tool-entry` and `shadowed-agent`, and the
    tool semantics confirmed. r3.2 also added `model-conflict`, which r3.3
    dropped.
  - §1.17: subagent delivery confirmed viable.
  - §4: tests C12–C14.
  - §5: results, plus a new E5.
  - §8.
**r3.3** closes every NEEDS-EVIDENCE item:

- **E5.** An explicit `--model` or Agent `model` parameter beats frontmatter.
  `model-conflict` is dropped from §1.7, the §1.16a table, the §1.15c fix
  offers and C13; `model-not-allowed` is kept.
- **E1a / E1d / E2-user** matched the spec. User agents report the bare
  `agent_type`, and the project file beats the user file on both paths. §1.4,
  §1.4a, §1.17, C14, §5 and §8 are updated.
- **§8:** the `--setting-sources` known constraint. No ah path passes it, so
  there is no check.

**Nothing is gated any more.**

**r3 changes.** The user settled r2's forks as follows:

- **F:** F1 — `routes` makes a review role an alternative reviewer.
- **H:** H1 — no routing gate.
- **G:** neither option. In the user's words: *"I think an entirely custom
  agent should be supported. but should require what's needed for it to work.
  That contract should have to be adhered to by custom agents. A validator
  should validate it at add time."*

The resulting changes:

- **New §1.16, the class-contract validator.** It reverses F4's "documented,
  not enforced" for custom and overridden agents: the mechanical contract is
  enforced when a role is added, and again at every peer spawn.
- **New §1.17, runtime contract injection.** This is how the behavioural half
  of the contract is guaranteed without an LLM judge.
- **§1.15b scaffold:** now a minimal template that passes the validator. It no
  longer copies a built-in agent file, which removes the r2 drift problem.
- **Other sections:**
  - §1.2 gains the class tool contract.
  - §1.4 turns "agent not found" from a warning into a refusal.
  - §1.4a's reader becomes the shared frontmatter reader, now also reading
    `name`, `model`, `tools` and `disallowedTools`.
  - §1.7, §1.9, §1.11 and §1.15c add validation points.
  - §1.14e folds into §1.17.
  - §2–§8 are updated to match.

**r2 changes** (kept):

- **Resolved forks:**
  - A1 — a `roles.<name>` row, plus a skill-driven CLI;
  - B1 — five classes;
  - C2 — description fallback to frontmatter;
  - D1 — built-in agent override;
  - E reversed — chain-class custom roles are in-chain alternatives.
- **Added sections:** §1.14 chain routing, and §1.15 the `/ah:agent-role`
  skill.

## Requirement

The user's words: *"I want the user to be able to add their own role/agent files
and have the system fully support it."*

"Fully support" means a custom role works everywhere a built-in role does:

- roster add, edit and validate;
- team create, spawn-one, spawn-ad-hoc and disband;
- `msg.mjs` routing and gates;
- the Orchestrator directive;
- subagent and peer routes;
- `/agent-roster`, `/agent-team` and `/hierarchy`.

Nothing is special-cased by role name where a registry row would do. Existing
rosters and `team.json` files keep working unchanged.

Later rounds added four requirements:

- **r2:** custom roles are managed through a skill that drives a CLI.
- **r2:** chain-class custom roles are routed to *inside* the chain.
- **r3:** a fully custom agent file (any body) is first-class.
- **r3:** each class defines the contract an agent must meet to work, and a
  validator enforces it at add time.

The MCP server named in the brief was removed in 0.73.0 (spec 0048). Nothing
here touches it.

## 0. Findings that shape the design

### F1 — Fourteen hand-kept role lists, every one a derived property

| File | Lists |
|---|---|
| `lib-config.mjs` | `ROLES` :139, `ROLE_LABELS` :141, `ROLE_DEFAULTS` :150, `VALID_MODELS_BY_ROLE` :176, `ROSTER_ROLES` :246 (dead), `PEER_ELIGIBLE_ROLES` :278, `ROLE_TOKENS` :294 |
| `lib-hier.mjs` | `MSG_ROLES` :29 |
| `roster.mjs` | `HIERARCHY_NAME_ROLES` :1868 |
| `pretooluse-msg-gate.mjs` | `GATED_ROLES` :22 |
| `pretooluse-sendmessage-response.mjs` | `GATED_ROLES` :40 |
| `pretooluse-route-gate.mjs` | `TIER_ROLES` :64 |
| `subagentstop-msg-nudge.mjs` | `NUDGED_ROLES` :29 |
| `lib-gate.mjs` | `GATED_SUBAGENT_TYPES` :40 |
| `usage-report.mjs` | `ROLE_ORDER` :246 |

Only four facts are truly per role: the label, the default model, the agent,
and task-runner's `delegate`.

### F2 — Four "is this a role" predicates disagree

| Predicate | Match | Location |
|---|---|---|
| `hierarchyRoleOf` | suffix | `lib-config.mjs:410` |
| Ultra gate | exact list | `lib-gate.mjs:40` |
| `roleFor` | `ah:` prefix | `lib-usage.mjs:35` |
| `roleFromName` | substring | `lib-config.mjs:303` |

### F3 — Unmatched agents fall through

An agent that matches no role word passes every gate. A top-level
`claude --agent my-auditor` session is also given the Orchestrator directive.

### F4 — ah never reads `agents/*.md`

- The prose rules are hardcoded (`lib-config.mjs:1050-1118`).
- Tool rights are frontmatter, and Claude Code enforces them.
- r3 changes this:
  - for **custom and overridden** agents, ah now reads frontmatter:
    `description` (§1.4a), plus `name`, `model`, `tools` and
    `disallowedTools` (§1.16);
  - it validates those fields and injects the behavioural contract (§1.17);
  - shipped `ah:*` agents are never validated or injected.

### F5 — `roles.<R>` config layers

`roles.<R>` resolves across three layers:

- global: `~/.claude/agent-hierarchy.json`;
- repo: `<root>/.claude/agent-hierarchy.json`;
- repo-user: `~/.claude/agent-hierarchy/projects/<slug>/agent-hierarchy.json`.

Precedence is repo-user > repo > global. A row is replaced **whole** (:905).
`resolveConfig` iterates only `ROLES` (:901), so new rows are forward-safe.

### F6 — The agent reference is emitted in two places

- `spawnShape` (`roster.mjs:766`): `--agent ah:${role}`.
- `subagentType` (`lib-config.mjs:966`).

### F7 — Name parsing takes the first match

- `roleFromName` does substring matching. Its callers are `:588` and
  `lib-hier.mjs:706,729`, plus the route gate at `:204`.
- `hierarchyNameParts` does `endsWith` matching. It serves disband, dismiss and
  teams via `herdrArmMatches` (`roster.mjs:1928`).
- Result: `security-reviewer` misparses as `reviewer`.

### F8 — Registry validation is on write paths only

- `validateTeamMember`: `create` (`roster.mjs:2837`).
- `validateMember`: add, edit and spawn-ad-hoc (`:2500,:2604,:3418`), plus
  `validateRosterBlock` (`lib-roster.mjs:305`).

### F9 — Ultra-gate approval is per session

It is stored in `~/.claude/agent-hierarchy.gate.json`.

### F10 — Two agent files are at their size ceilings

- `agents/orchestrator.md`: 7350 of 7350 B.
- `agents/architect.md`: 9684 of 9700 B.

Neither can take a new instruction, so every new instruction is **injected**.

### F11 — The directive and notice are built only at SessionStart

- `buildDirective` and `buildRoleSessionNotice` are called only at SessionStart
  (`sessionstart.mjs:194,105`).
- SubagentStart (`subagentstart-cli-root.mjs`) injects one line into every
  subagent. It already calls `resolveConfig`.
- None of these runs per tool call.
- SubagentStart context arrives only via `hookSpecificOutput` (engram).

### F12 — Chain role names are fixed prose

- The directive names the chain in fixed prose: item 0 (:1072) and item 6
  (:1080).
- So does the pipeline skill: `skills/autonomous-pipeline/SKILL.md:116-121`,
  `:128-129`, `:79` and `:94`.

### F13 — What the built-ins' tool shapes actually are

From `agents/*.md` frontmatter:

| Agent | Tool restriction |
|---|---|
| architect | `disallowedTools: NotebookEdit, Bash, advisor` |
| implementor | `disallowedTools: advisor` |
| reviewer | `disallowedTools: Edit, Write, NotebookEdit, advisor` |
| ultra-advisor | `disallowedTools: Edit, NotebookEdit, advisor` |
| task-runner | `tools: Read, Grep, Glob, Bash, WebFetch, WebSearch` (an allowlist) |

Every chain built-in uses `disallowedTools`, never a `tools` allowlist. It
therefore keeps SendMessage, which a peer needs in order to report back.

The response-file obligation is met in two ways:

- by Bash (`msg.mjs new`) for implementor;
- by Write alone for architect, which hand-writes response files (engram
  f19856).

Reviewer has neither Write nor Edit. It is excluded from the response-file
gate for that reason (`pretooluse-sendmessage-response.mjs:16-18`).

## 1. Design

### 1.1 One registry; a role is a row; behaviour comes from its class

The **role registry** for a cwd is:

- the five shipped built-in rows;
- plus every valid custom row from the resolved `roles` config.

Each resolved row carries:

- `name`, `builtin`, `class`, `label`, `agent` (effective);
- `model`, `dispatch`, `peer`;
- `description` and `routes` (custom rows only);
- `source`.

The built-in rows and the class table (§1.2) are **one** table in
`lib-config.mjs`. They replace `ROLES`, `ROLE_LABELS`, `ROLE_DEFAULTS` and
`VALID_MODELS_BY_ROLE`. The registry *is* `resolveConfig`'s output
(`resolved.roles` and `resolved.sources` grow). There is no second resolver.
A consumer that needs "all roles" must never use a built-in-only list.

### 1.2 Classes — the one table where class behaviour lives

**Gate behaviour.**

| Property | `advise` | `design` | `review` | `implement` | `legwork` |
|---|---|---|---|---|---|
| Built-in | ultra-advisor | architect | reviewer | implementor | task-runner |
| Chain step (§1.14) | Escalate | Design | Review | Implement | — |
| Allowed models | fable, opus | opus, sonnet, fable, inherit | same as design | same as design | same as design, plus haiku |
| **Chain role**: peer-eligible, message-file gated, SubagentStop nudge, confirm handoff | yes | yes | yes | yes | no |
| Tier rule | yes | yes | no | no | no |
| Owes a response file | no | yes | no | yes | no |
| Ultra approval gate | yes | no | no | no | no |
| Role sessions may dispatch it | no | no | no | no | yes |
| Conduit gate (never talks to the user) | yes | yes | yes | yes | yes |

**Tool contract (r3).** The validator checks this (§1.16). It uses the
effective-tool semantics in §1.16c.

| Check | `advise` | `design` | `review` | `implement` | `legwork` |
|---|---|---|---|---|---|
| **Required** (error) | Read, SendMessage | Read, SendMessage, Write | Read, SendMessage | Read, SendMessage, (Edit or Write), (Write or Bash) | — |
| **Forbidden** (error) | — | — | Edit, Write, NotebookEdit | — | — |
| **Discouraged** (warn) | Edit, NotebookEdit, advisor | Bash, NotebookEdit, advisor | advisor, *absent* Bash | advisor, *absent* Bash | — |

**Why each required entry:**

- **Read:** briefs arrive as message files.
- **SendMessage:** every chain role is peer-eligible, and a peer reports back
  by SendMessage.
- **design, Write:** the spec, plus hand-written response files.
- **implement, (Edit or Write):** it has to change files.
- **implement, (Write or Bash):** response files.

**Why review forbids editing tools.** The reviewer's verdict is independent
validation of *someone else's* diff. A reviewer that can edit ends up
validating its own fixes. That breaks the review loop's impl-defect → the
implementer who owns the work routing (§1.14c). Fork I lets the user move this
check between severities.

**Why the rest are warnings.** They mirror the built-in conventions (F13):
design never executes, advise never implements, no generic `advisor`, and
review and implement want Bash. Breaking one costs efficiency or discipline,
but the chain still works.

Legwork has no chain protocol, so it has no tool contract.

### 1.3 A custom role is a `roles.<name>` config row (A1)

Illustrative, not prescriptive:

```json
"roles": {
  "ui-implementor": {
    "class": "implement",
    "agent": "ui-implementor",
    "label": "UI-Implementor",
    "routes": "UI work — Godot Control/Theme scenes, HUD, menus, UI styling",
    "description": "Implements UI specs: Control nodes, containers, themes.",
    "model": "inherit"
  }
}
```

**Name rules:**

- matches `^[a-z][a-z0-9-]{0,30}$`;
- does not end in `-` or `-<digits>`;
- is not a built-in, `orchestrator`, `advisor` or `other`.

**Fields:**

| Field | Custom row | Built-in row |
|---|---|---|
| `class` | **required**, one of the five | warning; ignored |
| `agent` | optional; defaults to the name (§1.4) | optional override (D1) |
| `label` | optional; defaults to the capitalised hyphen words (`Ui-Implementor`); `^[A-Za-z0-9][A-Za-z0-9 -]{0,31}$` | warning; ignored |
| `description` | optional; one line, ≤160 chars, no newline or backtick; absent → §1.4a | warning; ignored |
| `routes` | optional, chain classes only, same format as `description`. **Present = in-chain alternative (§1.14); absent = side role.** On legwork: warning, ignored. | warning; ignored |
| `model` | must be in the class allowlist. Default `inherit`; `advise` requires an explicit model other than `inherit` | as today |
| `dispatch`, `peer` | as for built-ins; chain classes only | as today |

**Levels.** A custom row uses the same three layers and whole-row precedence as
built-in rows (F5). Rows are never merged across levels, so a partial
more-specific row (for example `{ "model": … }` alone) is **invalid**. The CLI
never writes a partial row.

**An invalid row** is one that fails §1.3 or §1.4.

- **On read:** it is excluded from the registry. One warning goes to the
  existing `resolveConfig` warnings channel. Nothing throws, and there is no
  fallback to a wider level.
- **On CLI write:** it is refused, with the reason.

Contract (§1.16) failures are a separate outcome. They do **not** exclude a row
on read; §1.9 says what happens to them.

### 1.4 Agent references and identity lookup

**Format.** `agent` must match
`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}(:[A-Za-z0-9][A-Za-z0-9_.-]{0,63})?$`.

This is a **security requirement**, because the value is interpolated into
shell strings (spawnShape and the directive's spawn lines). spawnShape
re-validates it at the spawn seam (compare `roster.mjs:750-756`).

**Reserved.** `ah:*` belongs to built-ins.

- A custom row with an `ah:` agent is invalid.
- An override may not name another role's `ah:` agent.

**Uniqueness.** An effective agent maps to exactly one role. Collisions are
evaluated on the **resolved** registry, after whole-row level precedence, so
the same role name defined at two levels is not a collision.

- **A custom row vs a built-in** (shipped agent or override): the custom row
  is invalid and the built-in wins.
- **Two or more custom rows with the same agent** (r3.4, ruling G1): **every**
  colliding custom row is invalid and excluded. Each gets one warning that
  names the other rows.
  - First-by-name wins was rejected. Which row the user meant is unknowable,
    and an alphabetical winner would silently decide which class's gates
    apply to that agent.
  - `role set` refuses a new or edited row whose agent collides, so only
    hand-edits can reach this read-time case.

**Identity lookup.** One function replaces all four F2 predicates. It resolves
`agent_type` and `subagent_type` in this order:

1. Exactly `ah:<builtin>` → that built-in. **No config read.**
2. Exact match on a registry row's effective `agent` → that row. This needs the
   registry.
3. `<builtin>` or `*:<builtin>` → that built-in. This is legacy behaviour,
   unchanged.
4. Otherwise → `null`.

**Evidence (E1a, E1b, E2, E2-user).** For both project and user agents,
`agent_type` is the **bare file name**, with no prefix, namespace or level
marker. It appears as follows:

| Payload | `agent_type` | Also carries |
|---|---|---|
| SessionStart / Stop of an `--agent` session | bare name | — |
| SubagentStart, SubagentStop, and PreToolUse inside a subagent | bare name | `agent_id` |
| The parent's PreToolUse(`Agent`) | **none** | target in `tool_input.subagent_type` only |

What this means for the lookup:

- **Step 2 matches the bare form.** Because no level marker is present, *which
  file* a bare name denotes follows Claude Code's own project/user precedence
  (E1d). The same order appears in §1.4a.
- **The gates already read the target** from `tool_input.subagent_type`, which
  is unchanged.
- The init tool list calls the tool `Task`, but hook payloads say
  `tool_name: "Agent"`. The existing matcher `Agent|Task` covers both.

Rules for using the lookup:

- **Config is read lazily:** only when step 1 misses. Hooks that already hold
  `resolved` pass it in.
- **Ultra-gate target** becomes "the lookup says class `advise`". This is a
  deliberate tightening: `*:ultra-advisor` is now gated.
- **`roleFor`** (usage) gains step 2 only (§1.13).
- **Delegates never match** (r3.4, confirming the Implementor's call). Step 2
  matches only a row's `agent`, meaning a custom agent, an override, or
  `ah:<role>`. It never matches `delegate`.
  - Why: matching the delegate would resolve `task-gopher:task-gopher` to
    task-runner. That would trip the conduit gate and legwork role handling
    for every task-gopher dispatch, breaking I4 and T17.
  - `lib-usage.mjs roleFor` keeps its existing task-gopher → task-runner
    mapping. That mapping is usage attribution only, not identity.
- **Role-session detection** uses the lookup: sessionstart,
  `resolveHierarchyRole().direct`, sessionend, liveness, the nudge, and
  subagentstart. An unregistered foreign agent still falls through to the
  Orchestrator directive.

**Existence (r3).** The validator must find the file (§1.16b). Otherwise the
row cannot be written, and a peer cannot be spawned. Hooks never check
existence.

### 1.4a The frontmatter reader (description resolution, C2)

This is **one** bounded reader in `lib-config.mjs`. It serves both the
description fallback and the validator (§1.16). It never throws. It returns:

- `found` (the path, or null);
- `frontmatter` (true or false);
- `name`, `description`, `model`, `tools`, `disallowedTools`;
- `parseErrors`: the fields present but unparseable.

**Locating the file.**

- A bare name `n` is looked up at `<repoRoot>/.claude/agents/<n>.md`, then
  `~/.claude/agents/<n>.md`. The first that exists wins. This is Claude Code's
  own order: E1d confirmed that the project file beats the user file, on both
  the `--agent` path and the subagent path.
  - **Shadowing.** When the file exists at **both** levels, the reader reports
    it. The validator then warns `shadowed-agent`, naming the repo file (the
    one it validated) and the shadowed user file. This is a warning because the
    user file is dead for this repo but may be live in others.
- `plugin:agent` goes through `~/.claude/plugins/installed_plugins.json`: for
  each install record of the plugin, try `<installPath>/agents/<agent>.md`,
  and take the first that exists.
- Only files named `<agent>.md` are found. A mismatch between filename and
  frontmatter `name` is a validator error (§1.16).

**Parsing.**

- It reads at most the first 16 KB.
- Frontmatter is the block between a first line of `---` and the next `---`.
- Scalars may be plain, single- or double-quoted (with `\n` escapes), or `|`
  and `>` block scalars.
- Tool lists may be:
  - a comma-separated scalar (`Read, Grep, Bash`);
  - a flow list (`[Read, Grep]`);
  - a block list (`- Read` lines).
- Anything else in a tools field is recorded in `parseErrors`.
- There is **no YAML dependency.**

**Normalising the description.**

1. Drop `<example>…</example>`.
2. Turn `\n` into spaces and collapse whitespace.
3. Remove backticks.
4. Keep the first sentence if it is ≤160 chars; otherwise truncate to 157
   chars + `…`.

**Where the effective description is used.** It is the config `description`,
else the normalised frontmatter description, else none. It appears only in
side-role directive lines (§1.9), in `role list` and in dry-runs. Routing
never uses it.

**Callers and cost.**

| Caller | When | Why |
|---|---|---|
| `buildDirective` / `buildRoleSessionNotice` | SessionStart | description + validation (§1.9) |
| `roster.mjs role` verbs | CLI | — |
| spawn verbs | CLI | revalidation (§1.7) |

- There is at most one ≤16 KB read per custom or overridden row per call.
- **No cache.** None of these callers runs per tool call, and a cache would
  need invalidating on agent-file edits.
- **Upgrade path, if a per-tool-call caller is ever added:** a memo keyed on
  (path, mtime, size). It is not built.
- **No PreToolUse, PostToolUse, UserPromptSubmit, Stop or SubagentStart hook
  reads an agent file (I7).**

**Trust.** Plugin descriptions are already shown verbatim by Claude Code's
Agent listing. Repo config sits at the trust level of `CLAUDE.md`. The caps are
directive hygiene.

**Plugin-copy caveat.** For a local-path marketplace, `installPath` may be the
cache rather than the live checkout (engram f129), so the validated copy can
differ from what loads. This is accepted and documented. Fork J covers plugin
agents that cannot be resolved at all.

### 1.5 Overriding a built-in's agent (D1)

`roles.<builtin>.agent` may name any agent that is valid under §1.4 **and**
passes the built-in's class contract (§1.16).

- The override changes only which agent is launched (`--agent` and
  `subagent_type`).
- The override is also validated and receives contract injection (§1.17).
- The class, gates, label, directive prose and default step stay the
  built-in's.
- `ah:<builtin>` still resolves to the built-in.
- Removing the override restores `ah:<role>`.

### 1.6 Every consumer and what it derives

| Site (today) | Becomes |
|---|---|
| `lib-config.mjs:139,141,150,176` | built-in rows + the class table (§1.1, §1.2) |
| `:246` `ROSTER_ROLES` | deleted |
| `:278`, `:315`, `:337` | chain-class registry roles |
| `:294`/`:303`; `roster.mjs:1868` `hierarchyNameParts` | §1.10 |
| `:410`, `:427` | §1.4 lookup |
| `:588` `validateTeamAlias` | all chain-class registry roles |
| `:824-923` `resolveConfig` | built-ins + every non-built-in `roles` key in any layer; validates rows per §1.3–1.4 (no contract check on this path) |
| `:966` `subagentType` | the row's effective `agent`. For task-runner, `agent` beats `delegate` (r3.4, ruling G3): `agent` set → that agent; else `delegate:"task-gopher"` → `task-gopher:task-gopher`; else `ah:task-runner`. |
| `:1082` directive item 8 ("Task-Runner: prefer `task-gopher:task-gopher` …") | byte-identical unless `roles.task-runner.agent` is set; then it names the override agent instead of the task-gopher preference, so it cannot contradict the Task-Runner role line (r3.4) |
| `lib-config.mjs:1824` `roleTierText` (directive items 12–14) and `lib-hier.mjs:1028` (tier-rule prose, r3.7 N6) | Derive the named roles from the **tier-rule class property**. The built-in labels (Architect, Ultra-Advisor) render **byte-identically** to today. Available custom design- and advise-class labels are appended **only when any exist**, e.g. ", and custom: Game-Architect". So I1 holds, and the Orchestrator learns a custom role is tier-gated before its first dispatch rather than from a deny. Budget: ≤ 40 B + labels per site, counted in T16. |
| `:983` `roleLines`, `:1050` `buildDirective`, `:1142` `statusReport` | §1.9, §1.14d |
| `:1108` `buildRoleSessionNotice` | §1.9, §1.17 |
| `lib-hier.mjs:29,253-254` | `orchestrator` + registry names |
| `lib-hier.mjs:703,726,897,967,1054` | chain-class registry roles |
| `lib-roster.mjs:225-226`, `:256` | role ∈ registry; model ∈ the class allowlist |
| `roster.mjs:573` | default model = the row's model |
| `roster.mjs:766` `spawnShape` | `--agent <row.agent>`, plus revalidation (§1.7) |
| `roster.mjs:2197,2491,2524,3406`; `msg.mjs:262` | registry / chain-class registry roles |
| `pretooluse-msg-gate.mjs:22,69,84`; `subagentstop-msg-nudge.mjs:29,93` | chain class; lookup |
| `pretooluse-route-gate.mjs:64,175,184-206,251` | the tier-rule property; chain class; lookup; §1.10 |
| `pretooluse-sendmessage-response.mjs:40,118` | the owes-response property |
| `lib-gate.mjs:40`; `pretooluse-ultra-gate.mjs:142-146` | advise class; the peer targets of every advise row |
| `pretooluse-conduit-gate.mjs:62`, `stop-orchestrator-liveness.mjs:127`, `sessionend-roster.mjs:23`, `sessionstart.mjs:90,109,133` | lookup; the custom name is recorded in peers.jsonl and session-roles |
| `subagentstart-cli-root.mjs` | §1.17 injection |
| `posttooluse-roster.mjs:66,75` | §1.10 |
| `lib-usage.mjs:35`, `usage-report.mjs:246` | §1.13 |
| `skills/autonomous-pipeline/SKILL.md:9,116-121,128-129` | §1.14g |

### 1.7 Spawn

- **Agent flag.** spawnShape emits `--agent <effective agent>`. A built-in with
  no override produces a **byte-identical** command. A non-claude kind ignores
  `agent`.
- **Unknown role.** A member whose role is not in the registry is refused:
  `role "<x>" is not defined here — roster.mjs role list`.
- **Revalidation (r3).** Before spawning a claude-kind member whose agent is
  custom or overridden, the spawn paths re-run the §1.16 validator. The paths
  are spawn-one, spawn-ad-hoc, `create --spawn` and history replay.
  - **Errors** refuse *that* member, with the findings and their fixes. Other
    members of a `create --spawn` still spawn, reported as partial, following
    the existing partial-team convention.
  - **Warnings** are printed.

  The agent file can change after `role set`, and a peer that cannot meet its
  contract is worse than no peer, because the Orchestrator would wait on it.

  **Overrides revert, consistent with §1.9** (r3.4, ruling G2). When a
  built-in override fails revalidation at spawn, the member is **spawned
  with the shipped `--agent ah:<role>`** instead of being refused.
  - The spawn result carries the findings and says plainly that it spawned
    `ah:<role>` in place of `<override agent>`, so the substitution is never
    silent.
  - Refusal applies only to **custom** roles, which have no shipped
    fallback.
  - The directive and the spawn therefore agree: while the override fails,
    the role behaves as if it had no override.
- **Default model.** `memberFromFlags` takes the default model from the row. A
  custom `inherit` omits `--model`.
- **Model precedence (E3 and E5, settled in r3.3).** Two sources can set a
  custom role's model:
  - the **row** model, sent as `--model` at peer spawn and as the Agent
    `model` parameter for a subagent (omitted for `inherit`);
  - the agent file's frontmatter `model:`.

  Measured precedence (Claude Code 2.1.281):
  - **An explicit row model always runs.** `--model` beats frontmatter, and
    the Agent `model` parameter beats frontmatter (E5).
  - **With a row of `inherit`, the frontmatter model runs.** It beats a
    settings `model`. With no frontmatter model, the session default runs
    (E3).

  The advertised model and the one that runs therefore agree whenever the row
  is explicit, so there is no conflict check. (r3.2's `model-conflict` has been
  **dropped**.) The allowlist holds on both paths:
  - an explicit row model is checked at write time (§1.3);
  - a frontmatter model is checked by `model-not-allowed` (§1.16a).

  `model-not-allowed` stays an error even under an explicit row. The frontmatter
  model becomes live the moment the row goes to `inherit`, or when a subagent is
  dispatched with no `model` parameter. `role set` and spawn re-validate
  anyway, so it is cheaper to reject the latent hazard than to track when it
  arms.

  With a row of `inherit`, the tier rule treats the model as unknown, as it
  does today for implementor's `inherit`. It never reads the agent file to
  learn the model (I7).
- **spawn-ad-hoc** accepts any chain-class registry role. The name follows
  `<prefix>-<role>[-n]` and is checked with `validateHerdrName`.
- **Visibility warnings** (add and edit):
  - a global roster whose role is defined below global;
  - a repo roster whose role is defined below repo.

### 1.8 Messaging

- `msg.mjs new --to` and `--from` accept `orchestrator` or any registry role.
  The error message lists the valid set.
- `msg.mjs roster` lists the chain-class roles.
- The message format is unchanged.

### 1.9 Directive and role-session notice

**SessionStart contract check (r3).** When building the directive,
`buildDirective` validates every custom and overridden row (§1.16), reusing
the §1.4a read it already does. A row with **errors** is **unavailable**.

- It stays in the registry, so gates, messaging, teardown and `msg.mjs` still
  work (I3).
- Its role line and routing lines are **omitted**. Routing for its step falls
  back to the built-in.
- The directive gains exactly one line:
  `Unavailable user-defined roles (agent file fails its class contract — /ah:agent-role): <names>.`
  Its budget is ≤ 120 B plus the names.
- Warnings are not shown in the directive. They appear in `role list` and
  doctor.
- **A built-in override that fails its contract** (r3.4, ruling G2) is
  treated differently: the built-in is **never omitted**. It **reverts** to the
  shipped `ah:<role>`, which is trusted and always valid.
  - The role's line, routing default and chain step stay present, rendered
    exactly as if there were no override.
  - The Unavailable line names it as `<role> (<override agent>)`, e.g.
    `architect (my-architect)`.
  - Rationale: a built-in is the chain's "otherwise" for its step. Omitting
    it would leave, for example, no Architect at all. That is strictly worse
    than falling back to the shipped contract the user started from.
  - `role list` shows the override as
    `UNAVAILABLE → reverted to ah:<role>`, with its findings.

**Role lines** (`roleLines`).

- Built-in lines come first, in today's order, **byte-identical**.
- Available custom rows follow, sorted by name, each in its class's dispatch
  shape:
  - a **chain alternative** carries `[custom · <class> · alt. to <BuiltinLabel>]`,
    with its routes in §1.14d;
  - a **side role** (no routes, or legwork) carries `[custom · <class>]` plus
    its quoted effective description.

  Illustrative:
  `- UI-Implementor [custom · implement · alt. to Implementor] — SendMessage its live teammate …; none live → \`node "…/roster.mjs" spawn-ad-hoc ui-implementor --cwd …\`, then …`
- If any side role exists, one sentence is added: *custom side roles are
  dispatched when the user asks for one or when its quoted description fits;
  they are never substituted into the chain.*

**Invariants for the directive:**

- With zero custom rows and no overrides, it is byte-identical to today's (I1).
- Items 0, 1 and 6 stay byte-identical. Their overrides for alternatives live
  in §1.14d.

**Role-session notice** (`buildRoleSessionNotice`).

- For a built-in with no override, the notice is **byte-identical**.
- For custom and overridden roles, it names the agent file ("Your <Label>
  contract … your agent file (`<agent>`) governs, subject to the hierarchy
  contract below"). It then appends the §1.17 contract block. A chain
  alternative also gets "alternative to <BuiltinLabel> for: <routes>".
- Design-class notices (built-in or custom) gain §1.17's routing block when
  routing exists.

### 1.10 Peer-name parsing

- **Matching rule (r3.6, replacing r3's "custom names first").**
  `roleFromName` and `hierarchyNameParts` match custom names **only as the
  trailing role segment** of a peer name `<prefix>-<role>[-<digits>]`, and
  **never by substring**. Resolution runs in two passes.

  **Pass 1 (suffix-anchored).** Among **all** registry names, built-in and
  custom, find the longest name `r` such that the peer name ends with `-r` or
  `-r-<digits>`.
  - If that longest match is a **custom** role → return it.
  - If it is a built-in, or nothing matched → go to pass 2.

  **Pass 2 (legacy, unchanged).** Today's built-in scan, byte-for-byte: the
  substring `ROLE_TOKENS` order for `roleFromName`, and the
  `HIERARCHY_NAME_ROLES` `endsWith` order for `hierarchyNameParts`. Custom
  names never take part in pass 2.

  **Why this shape:**
  - With zero custom roles, pass 1 accepts nothing, so parsing is identical to
    today's (I1). That includes explicit peer names like `custom-reviewer-peer`
    → reviewer.
  - A custom name that is a substring or a hyphen-segment of a built-in
    (`imp`, `rev`, `runner`) can never capture a built-in session. For example,
    `claudetools-implementor` does not end in `-imp`. In
    `proj-task-runner`, the longest suffix match is the built-in
    `task-runner`, which falls to pass 2.
  - `proj-security-reviewer` still resolves to the custom
    `security-reviewer`, because it is longer than `reviewer`.

  **Refused (r3.6): excluding such rows at read time.** That would treat the
  symptom rather than the matcher. It would also silently disable reasonable
  user-chosen names (`rev`, `arch`, `imp`). With suffix anchoring those names
  are harmless, so no read-time exclusion is needed. `role set`'s collision
  check remains as write-time UX.
- A team record's `role` beats the parsed name everywhere.
- `role set` runs the generalised `validateTeamAlias` collision check and
  refuses on a collision.

**Orphan tolerance.** disband, dismiss, untrack and reap still act on a
`team.json` member whose role has gone from the registry, using its recorded
`name` and `transport_id`. If `herdrArmMatches` reaches such a member only
through `hierarchyNameParts`, the Implementor makes the team-record arm cover
it and reports which arm did.

### 1.11 CLI: `roster.mjs role` — the backbone the skill drives

**`role list [--json] --cwd <abs>`**

One row per registry role, with:

- name, builtin/custom, class, agent, model, source;
- chain placement: `alt. to <Builtin>: <routes>` or `side`;
- effective description and its source;
- **contract status** (r3): `ok`, `n warnings` or `UNAVAILABLE: n errors`. This
  is computed by the validator for custom and overridden rows, and is `shipped`
  for `ah:*`.

Excluded (invalid) rows are listed with their reasons. With `--json`, each
row's full finding list is included (§1.16d).

**`role set <name> [flags] --cwd <abs>`**

Flags:

- `--class <c>`, `--agent <ref>`, `--label <l>`, `--description <d>`,
  `--routes <r>`, `--model <m>`, `--dispatch peer|model`;
- `--level global|repo|repo-user`;
- `--scaffold repo|user`;
- `--dry-run`.

Behaviour:

- **Upsert** at one level. The default level is the same as `add`'s.
- **Seeding.** When there is no row at that level, the row is seeded from the
  effective row; the given flags then apply. This holds for built-ins too.
- **Custom name.** `--class` is required when nothing can be seeded. The row
  must pass §1.3 and §1.4.
- **Clearing.** `--routes ""` and `--description ""` delete the key.
- **Built-in name.** Only `--agent`, `--model` and `--dispatch` are accepted.
- **Contract gate (r3).** After the row checks and any scaffolding, the
  validator runs against the row's class and effective agent. Any **error**
  refuses the write and prints every finding with its fix (§1.16d). Warnings
  are printed and the write proceeds. It runs for custom rows and for built-in
  overrides, and **also** on a `role set` that changes only `model` or
  `routes`, since the whole row is being re-committed.
- **`--scaffold repo|user`.**
  - Writes the §1.15b template, then validates it; the template must pass.
  - Refuses if the file already exists, the agent is a `plugin:agent`, or
    `repo` is used outside a git repo.
  - All-or-nothing with the row write: if the row write or the validation
    fails, the scaffolded file is removed.
- **`--dry-run`.** Validates everything, including the contract, and prints
  the row it would write, the agent-file status, the effective description,
  and the full finding list. **It writes nothing.** With `--scaffold`, it
  validates the template in memory.
- **Warnings** (non-contract):
  - a repo-level row whose bare agent exists only under `~/.claude/agents`;
  - `routes` on a class that already has an alternative (first match in name
    order wins).

**`role remove <name> [--level L] --cwd <abs>`**

- **Custom role.** Removes the row. It refuses while a roster member uses the
  role, and lists those members. It never deletes agent files.
- **Built-in.** Removes only the `agent` override.

**Conventions.**

- Output uses the JSON result convention of the other verbs.
- `pretooluse-ah-cli.mjs` allow-lists `role` as it does `add` and `edit`.
- The skill-first gate is not extended, so `check-gate-name-agreement.mjs`
  `VERBS` is unchanged.

### 1.12 Skills and docs

- **New:** `skills/agent-role/SKILL.md` (§1.15).
- **New:** `agent-hierarchy/contracts/` (§1.17), the contract text files.
- **`skills/agent-roster/SKILL.md`:**
  - :97 roles line → "built-ins … plus custom roles (`role list`; define with
    `/ah:agent-role`)";
  - :143-150 init wizard lists the available custom roles.
- **`skills/agent-team/SKILL.md:147`:** the same roles line.
- **`skills/autonomous-pipeline/SKILL.md`:** §1.14g.
- **`commands/hierarchy.md` :20-27, :58-70:** custom rows, class allowlists,
  `routes`, the class contract, and a pointer to `/ah:agent-role`.
- **`docs/cli-tools.md`:** the `role` verbs.
- **`docs/team-file.md`:** `role` may be a custom name.
- **No `agents/*.md` changes** (F10, I8).

### 1.13 Usage report

`roleFor` keeps report-time attribution, plus lookup step 2 against the
report cwd's registry.

- Custom roles sort after the built-ins, alphabetically, before `other`.
- Repo-level custom roles from other repos show as `other`. This is
  documented.

### 1.14 Chain routing — custom roles as in-chain alternatives

#### 1.14a What makes a role an alternative

A chain-class custom row that has `routes` **and is available** (§1.9) is an
alternative to its class's built-in at that class's step:

| Step | Class | Built-in |
|---|---|---|
| Escalate | advise | ultra-advisor |
| Design | design | architect |
| Implement | implement | implementor |
| Review | review | reviewer |

- The built-in is always the "otherwise".
- `routes` is an explicit field rendered as a rule, not left to description
  judgment. A picker description says what an agent *is*; a routing rule says
  *when it wins*.
- Keyword and path-glob matching are refused (§7).

#### 1.14b The spec header

When the registry has an alternative for Implement or Review, a design-class
role writing a spec names its choice:

- within the spec's first 40 lines;
- on a line that is exactly `Implementer: <role>` and/or `Reviewer: <role>`;
- where `<role>` is any registry role of that class, built-ins included.

When no alternative exists, specs are unchanged.

#### 1.14c Who chooses, in precedence order

1. The **user**, if they named a role.
2. A valid **spec header**. A header naming an unknown, wrong-class or
   unavailable role is ignored: the step falls to rule 3, and the user is told.
3. The **routing rule** (§1.14d). Candidates are taken in name order; the first
   fit wins.
4. **Unsure:** the built-in (auto flow), or ask (confirm flow), offering the
   candidates and the built-in.

Choices are **sticky per item**: the routed role owns the item's work *and its
rework*.

#### 1.14d The generated directive item

The item is generated only when at least one available custom row has
`routes`. It is appended after the last numbered item, and numbered next.

**Required parts.** The wording is illustrative, and no part may be dropped:

1. A header.
2. One line per step that has alternatives. For example:
   `· Implement: UI-Implementor for "<routes>"; otherwise Implementor.`
3. Header precedence: "A spec's `Implementer:`/`Reviewer:` decides; unsure →
   built-in (auto) or ask (confirm)."
4. Ownership: "impl-defect goes back to the role that implemented,
   spec-defect to the role that designed."
5. Gate parity: "The handoff gate, review loop and message-file rules apply to
   an alternative as to the built-in it stands in for."

**Budget:** ≤260 B, plus 220 B per alternative. Items 0 and 6 stay
byte-identical.

#### 1.14e *(r3: merged into §1.17)*

#### 1.14f Several roles of one class

Every gate is class-derived, so an alternative inherits the gates of its step:

| Concern | Treatment |
|---|---|
| Response-file obligation | Class property; the validator guarantees the tools (§1.2). |
| Confirm handoff | Asks before dispatch, naming the routed role and its alternatives. |
| Review after an alternative's diff | Review is routed independently. Its impl-defects return to the role that produced the diff. |
| Architect names the implementer | §1.14b and §1.17. |
| Tier rule, Ultra approval (shared per session across advise), liveness, busy/free, `prefer-peers`, `subagentOptIn`, spawn verbs, `msg.mjs roster` | Already per role or per class. |

There is **no routing gate** (H1).

#### 1.14g `/ah:pipeline` (`skills/autonomous-pipeline/SKILL.md`)

Every change below must stay behaviour-equivalent when there are no custom
rows.

- **:116-121:**
  - "Implementor" and "Reviewer" become "the item's implementer / reviewer".
    Each resolves to the spec header, else the routing rule, else the built-in.
  - spec-defect goes to the design-class role that wrote the item's spec.
  - impl-defect goes to the item's implementer's rework queue.
- **:128-129:** one queue per implement-class role in use. When X finishes N,
  N goes to its reviewer and X takes its own next item. Items routed to
  different implementers run concurrently.
- **:79/:94:** a routed role with no live peer is spawned with spawn-one (if it
  is a roster member), else spawn-ad-hoc. A spawn refused by revalidation
  (§1.7) makes that item fall back to its step's built-in. The fallback is
  recorded and reported.
- **Resolution timing:** each item's roles are resolved once, at queue time,
  and recorded in the item's state.
- **Design and Escalate route too (r3.7, N7).** The pipeline resolves **every**
  chain step's role (Design, Implement, Review and Escalate) with the same
  §1.14c precedence:
  1. the user;
  2. the spec header (Implement and Review only, since design precedes the
     spec);
  3. the routing rule;
  4. the built-in.

  This covers two cases:
  - **Design.** An item that needs design, or a spec-defect, goes to the
    item's **designer**. At queue time that is the routed design-class role.
    For a spec-defect it is the role that wrote the spec (sticky).
  - **Escalate.** The skill's UA-escalation path goes to the routed
    advise-class role. The Ultra approval gate is already shared across the
    advise class (§1.14f).

  This is a consistency fix, not a new product choice. §1.14a already makes
  design and advise alternatives in-chain alternatives, and the pipeline was
  the one place that did not honour them.
- The caps are unchanged.

#### 1.14h Custom review roles: alternative reviewers (F1)

- With `routes`, a review role replaces the reviewer for matching work.
- Without `routes`, it is a side role, dispatched only on request.
- There is no extra-stage review. That was F2, which was not chosen.

#### 1.14i Budgets

**I1 holds:** with zero custom rows, nothing is generated, so `AUTO_MAX 14600`
and `CONFIRM_MAX 16500` hold untouched.

Test T16 checks the per-row growth caps:

| Item | Cap |
|---|---|
| Custom role line | ≤600 B |
| Routing item | ≤260 + 220·alts B |
| Unavailable line | ≤120 B + names |
| §1.17 blocks | their own caps |

### 1.15 The `/ah:agent-role` skill and scaffolding

#### 1.15a Why a new skill

Defining a role contract and its agent file is a different job from composing
a roster. `agent-roster/SKILL.md` is already 16,148 B and loads on every roster
touch. A separate skill loads only on its own triggers, and the roster skill
links to it.

- **Location:** `skills/agent-role/SKILL.md`.
- **Invocation:** `/ah:agent-role [list|add|edit|remove|check] [name]`.
- **Triggers:** "add a custom role", "define my own agent/role", "make a
  ui-implementor", "custom reviewer/implementer/architect", "edit/remove a
  role", "which roles exist", "why is my role unavailable".
- **Scope:** it drives only the `roster.mjs role` verbs. Its Edits are
  confined to fixing frontmatter the user approved (§1.15c) and to the
  scaffold's Specialisation line.

#### 1.15b Scaffold content (`--scaffold`, r3)

A **minimal template that passes the validator** — the class's §1.2 contract
— written by the CLI. Its path depends on the flag:

- `repo`: `<repoRoot>/.claude/agents/<agent>.md`
- `user`: `~/.claude/agents/<agent>.md`

**Frontmatter:**

- `name: <agent>`
- `description:` the config `description`, else `<Label> — <routes>`, else
  refuse ("give --description or --routes").
- **No `model:`.** The row owns the model.
- **No `tools:` allowlist.** An allowlist would drop SendMessage and every
  other harness tool the chain needs.
- `disallowedTools:` the class's **forbidden + discouraged** tools, so the
  template is warning-free. Per class:

  | Class | `disallowedTools` |
  |---|---|
  | design | `Bash, NotebookEdit, advisor` |
  | review | `Edit, Write, NotebookEdit, advisor` |
  | implement | `advisor` |
  | advise | `Edit, NotebookEdit, advisor` |
  | legwork | none |

  These equal the built-ins' shapes (F13). A restriction is always written as
  a `disallowedTools` entry, never as a scoped `tools` entry such as
  `Bash(git:*)`. E4c showed that a scoped entry grants the **whole** tool.

**Body.**

- A short identity paragraph: "You are the <Label>, a <class>-class role in the
  agent hierarchy[, standing in for the <BuiltinLabel> for: <routes>]. The
  hierarchy contract you receive at session or subagent start governs your
  protocol; this file adds your specialisation."
- A `## Specialisation` section with one placeholder line. The skill replaces
  the placeholder with the user's text.
- **No protocol restatement.** The contract arrives by injection (§1.17), so
  there is nothing to drift.

**A user-authored file is first-class.** Any body, and any tool shape, is
accepted as long as it passes §1.16.

#### 1.15c Skill flows

All questions go through AskUserQuestion:

- at most 4 options each, recommended first;
- free text via Other;
- independent questions batched, up to 4 per call.

**`list`** — runs `role list` and renders contract status.

**`check [name]`** — runs `role list --json`. For each role with findings, it
walks the fix loop (below).

**`add`**

1. **Name.** Suggest one from the user's words, plus up to two variants.
2. **Class.** Offer the inferred class first. The fifth class is available via
   Other. Each option describes that class's gates and its §1.2 tool contract
   in one line.
3. **Early validation.** Run `role set <name> --class <c> --dry-run`. Row-level
   refusals (name, collisions) are re-asked now, before anything else.
4. **Chain placement** (chain classes). "Alternative to <Builtin> for specific
   work" or "Side role". An alternative leads to `routes`: a drafted sentence
   plus a tighter variant, or Other.
5. **Agent file**, driven by the dry-run's status:
   - **Found:** "Use existing <path> (Recommended)" or "Point at a different
     agent".
   - **Not found:**
     - "Scaffold .claude/agents/<name>.md in this repo — passes the contract
       (Recommended inside a repo)";
     - "Scaffold ~/.claude/agents/<name>.md";
     - "I'll write my own file first" — the skill stops. The user writes the
       file and re-runs `add` or `check`.
     - "Use an existing agent" (Other).
6. **Model.** The class allowlist, with the class default first.
7. **Description.** "Use the agent file's description (Recommended)" when one
   exists, or "Write a one-line description".
8. **Level.** repo (Recommended inside a repo), repo-user, or global. Say so if
   the level mismatches the file location.
9. **Contract pre-flight.** Run the full `role set … --dry-run`. If it reports
   errors, run the fix loop, then re-run the dry-run until there are no errors.
10. **Commit.** Show the exact command. Run `role set …` and report the row,
    the file path and any warnings.
11. **Specialisation** (if scaffolded). Ask for it, and Edit only the
    placeholder line.
12. **Offer** "Add it to the roster now? → `/ah:agent-roster add`".

**Fix loop** (in `add`, `edit` and `check`). For each **error** finding
(§1.16d), one AskUserQuestion. The options are chosen from the finding's `fix`
list:

- **"Fix the agent file for me (Recommended)".** Offered only when the agent
  file is a user-owned bare-name file (repo or user level). **Never** for a
  plugin agent's file, since that file belongs to the plugin.
  - The skill applies **only** the finding's frontmatter edit: add or remove a
    tool, remove `model:`, or fix `name:`.
  - It uses one Edit, then re-validates.
  - To restrict a tool, it removes the tool from `tools` or adds it to
    `disallowedTools`. It never suggests a scoped entry such as `Bash(git:*)`,
    which does not scope (E4c).- **"Change the role's class to <suggested>".** Offered when the finding's
  `fix` suggests another class; for example, a review-class file with Edit
  suggests `implement`.
- **"I'll fix it myself"**, which stops the loop.
- **Advisory fixes (r3.5).** A finding whose only fix is `remove-file` gets no
  "Fix … for me" option. The skill prints the instruction and moves on. The
  one place the skill deletes an agent file is the explicit opt-in question in
  `remove`, which defaults to keep.

Warnings are shown as a list, with one question: "Fix warnings too?" (all or
none) or "Leave them". The file body is **never** edited, except for the
scaffold placeholder.

**`edit`**

1. Pick the role.
2. MultiSelect which fields to change: routes, description, model, agent,
   class. For built-ins, only agent and model.
3. Ask each chosen field as in `add`.
4. Run a dry-run and the fix loop.
5. Run `role set` with only the changed flags.

**`remove`**

1. Confirm.
2. Run `role remove`. If it refuses because roster members use the role, offer
   removing them via `/ah:agent-roster`, or cancel.
3. **Deleting the agent file (r3.7, N5).** Whether to offer it depends on
   where the file resolved (§1.4a):
   - **A bare repo-level file** (`<repo>/.claude/agents/<n>.md`): ask "Delete
     the agent file too?" The options are "Keep it (Recommended)" and "Delete
     it".
   - **A bare user-level file** (`~/.claude/agents/<n>.md`): the question
     carries an explicit warning that this file may be the live agent in
     other repos, and that removing the role here does not remove it there.
     The options are "Keep it (Recommended)" and "Delete it anyway".
   - **A `plugin:agent` file:** never offered, because the file belongs to the
     plugin. The skill says so, in one line.
   - **An override on a built-in:** `role remove` deletes only the override,
     and the file is offered under the same rules.

   The default is always to keep the file. This is the only place the skill
   deletes a file (compare `remove-file`, §1.16d).

### 1.16 The class-contract validator (r3)

#### 1.16a What it validates

The validator runs for:

- every **custom** row, against the row's class;
- every **built-in override**, against the built-in's class.

It never runs for shipped `ah:*` agents (they are trusted, which keeps I1).

The mechanical contract, taken from §1.2's tool table plus the file-level
checks, is:

| Code | Level | Check |
|---|---|---|
| `agent-not-found` | error | The file is not found (§1.4a). |
| `plugin-unresolvable` | error (Fork J) | A `plugin:agent` has no install record, or no `agents/<a>.md` under any install path. |
| `no-frontmatter` | error | No `---` block. |
| `unparseable-field` | error | `tools`, `disallowedTools`, `model` or `name` is present but unparseable. |
| `name-mismatch` | error | Frontmatter `name` ≠ the ref's agent part (Claude Code loads by `name`). |
| `model-not-allowed` | error | Frontmatter `model` is outside the class allowlist. Under `inherit` that model would run, so a haiku reviewer would break the no-Haiku rule. |
| `missing-tool:<T>` | error | A required tool (or neither of a required pair) is absent from the effective tool set. |
| `forbidden-tool:<T>` | error | A forbidden tool is present. |
| `discouraged-tool:<T>` / `missing-recommended:<T>` | warn | Per §1.2. |
| `no-description` | warn | No config and no frontmatter description; a side role would have an empty directive line. |
| `scoped-tool-entry` | warn | A `tools` entry of the form `T(…)`. It grants the **whole** tool `T` (E4c), and the message says so. The fix removes the entry, or lists plain `T` knowingly; to restrict, use `disallowedTools`. |
| `shadowed-agent` | warn | A bare name exists at both repo and user level (§1.4a). The message names the file validated and the one shadowed. The fix removes or renames one of them. |

**Behavioural clauses are not checked from file text.** Spec-path intake,
response files, stop-and-report on gaps, and never talking to the user are
all guaranteed by §1.17 injection plus the existing gates:

- conduit (user contact);
- route wall (no role dispatch);
- msg and response gates (message files).

Checking for required headings or markers would prove only that text is
present, not that it is followed. It would also force every custom file to
copy boilerplate that then drifts. That is refused (§7).

#### 1.16b Where it runs

| Point | Severity | Notes |
|---|---|---|
| `role set` (custom and override) | error → refuse; warn → print | §1.11. Includes `--scaffold` output. |
| `role set --dry-run` | report only | The skill's pre-flight. |
| `role list` | status column | Plus findings in `--json`. |
| `/ah:agent-role` add, edit, check | fix loop | §1.15c. |
| Peer spawn: spawn-one, spawn-ad-hoc, `create --spawn`, replay | error → refuse that member; warn → print | §1.7. The file may have changed since add. |
| SessionStart (`buildDirective`) | error → the role is *unavailable* (omitted from the directive and routing); warn → silent | §1.9. It catches changes made since add on the subagent route. |
| Per-tool-call hooks (route gate, etc.) | **never** | I7. An unavailable role is not advertised. If the Orchestrator dispatches one anyway at the user's request, it still runs under §1.17's injected contract and the existing gates. |

#### 1.16c Effective-tool semantics

A tool `T` is present when both of these hold:

- the `tools` field is absent, or is `*`, or lists `T`;
- `disallowedTools` does not list `T`.

"Lists `T`" means an entry equal to `T`, or an entry starting with `T(`. Any
other entry is kept but not interpreted, and is not a parse error.

MCP tool names (`mcp__…`) are ignored by every check.

**E4 confirmed these semantics against Claude Code 2.1.281** (r3.2):

| Case | Observed |
|---|---|
| (a) No `tools` field | The full set (33 tools, SendMessage included). |
| (a) An allowlist | Exactly the listed tools. An allowlist that omits SendMessage **removes** it, which confirms `missing-tool:SendMessage` as an error. |
| (b) List syntax | Comma, flow and block lists all parse identically. |
| (c) `Bash(git:*)` | Grants **unscoped** Bash. Counting `T(…)` as `T` is therefore correct for the required, forbidden and discouraged checks, and `scoped-tool-entry` warns the user that the scope is not enforced. |
| (d) `disallowedTools` | Removes a tool that `tools` grants. |

#### 1.16d Output — one finding per failure, each with its fix

Each finding carries:

| Field | Meaning |
|---|---|
| `level` | `error` or `warn` |
| `code` | a stable code (§1.16a) |
| `path` | the agent file path, or null |
| `field` | the frontmatter key, or null |
| `message` | one sentence saying what is wrong |
| `fix` | an array of fix objects, `{ kind, detail }` |

The fix kinds are:

| `kind` | Meaning |
|---|---|
| `edit-frontmatter` | The exact change, e.g. "remove `Edit` from `tools`" or "add `Write` to `tools` (you use an allowlist)" or "remove `Write` from `disallowedTools`". |
| `change-class` | The suggested class. |
| `scaffold` | `role set … --scaffold repo\|user`. |
| `create-file` | The path to create. |
| `copy-agent` | For plugin agents: copy it to `.claude/agents/<name>.md` as a user-owned file. |
| `set-description` | Set a description. |
| `remove-file` (r3.5) | **Advisory only.** `detail` names the file to delete or rename, with the alternative. For `shadowed-agent`: "delete or rename the shadowed user file `<path>`, or rename the repo agent". The skill and CLI **never act on it**: they show it to the user as an instruction. The shadowed user file may be the live agent in other repos, so deleting it is destructive beyond this repo. |

Plain output prints `<LEVEL> <code>: <message>` and then one `  fix: …` line
per fix. `--json` returns the array.

The skill's fix loop consumes `fix` directly. The skill never invents a fix.

#### 1.16e Which refs can be validated

| Ref | Resolution |
|---|---|
| Bare repo-level file | full validation |
| Bare user-level file | full validation |
| `plugin:agent` | the `installed_plugins.json` `installPath` copy (§1.4a caveat) |
| Claude Code built-in agents (`Explore`, `general-purpose`, …) or dev-loaded plugins with no install record | no file → `agent-not-found` / `plugin-unresolvable` → **refused** under Fork J1 |

If a file is **not found at add time**, `role set` refuses. The fixes offered
are scaffold, create, or correct the ref. The skill offers the scaffold.

### 1.17 Runtime contract injection (r3) — the behavioural half

The behavioural contract is supplied **by ah at runtime**. The agent file does
not have to restate it, and cannot opt out of it.

**Source.** One text file per part, shipped in the plugin:

- `agent-hierarchy/contracts/common.md`: all chain classes;
- `contracts/advise.md`, `design.md`, `review.md`, `implement.md`.

Legwork gets no injection: it has no chain protocol. The conduit gate still
binds it.

Placeholders are substituted at injection time:

- `<Label>`, `<class>`, `<BuiltinLabel>`, `<routes>`;
- the CLI root.

Size caps (tested): `common.md` ≤ 900 B; each class file ≤ 450 B.

**Required clauses.** The Implementor writes the prose; every clause listed
must be present.

**`common`:**

1. **Identity.** "You are <Label>, a <class>-class role in the agent hierarchy
   [, standing in for <BuiltinLabel> for: <routes>]."
2. **Precedence.** "This contract overrides anything in your agent file that
   conflicts with it."
3. **Intake.** Briefs arrive as `[hierarchy-msg <path>]`. Read the index with
   `grep '^## \['`, then Read only the sections you need. The request's
   `team_file` is authoritative.
4. **Report.** Reply with a response message file:
   - `msg.mjs new --type response --id <id> --req <request path>`;
   - or, without Bash, Write it beside the request with matching frontmatter.

   The final message is `[hierarchy-msg <path>]` plus one status bullet. On a
   `[hierarchy-peer-brief reply-to=…]`, the report must be *delivered* by
   SendMessage to that address.
5. **Gaps.** When the brief or spec is silent, ambiguous or wrong, stop and
   report the gap upward. Never choose silently.
6. **Boundaries.** Never address the user; the Orchestrator is the sole
   conduit. Never dispatch hierarchy roles; route needs back as
   `NEEDS-<ROLE>` or `NEEDS-EVIDENCE`. Legwork (`task-gopher:*`,
   `ah:task-runner`) is allowed.

**Class clauses:**

| Class | Clauses |
|---|---|
| `design` | Write the spec at the path dictated. Never implement product code, and never execute. Empirical questions → `NEEDS-EVIDENCE`. **Routing block**, when Implement/Review alternatives exist: list each step's roles with their `routes`, and require the spec header `Implementer:`/`Reviewer:` (§1.14b). |
| `implement` | Implement exactly what the spec says; make no design decisions; report the files changed; a spec gap → stop and report. |
| `review` | Validate the diff against the spec; never edit; classify each finding as `impl-defect` or `spec-defect`; delegate test and build runs to legwork. |
| `advise` | Adjudicate the specific question asked; never implement; give a verdict with its rationale. |

**Delivery.**

- **The injection key is the session's actual `agent_type`, not the row (r3.7,
  aligning with review S1).** The contract is injected, and the notice names
  "your agent file", only when both hold:
  - the session's `agent_type` is the row's **effective non-shipped agent**:
    a custom agent, or the override agent itself;
  - it resolves through lookup step 2.

  A session running as `ah:<role>` resolves at step 1 and **never** gets
  injection. That holds even when `roles.<role>.agent` is set, which covers
  the G2 spawn revert, the SessionStart revert and a direct `ah:<role>`
  dispatch. Such a session gets the byte-identical built-in notice (I5). The
  design routing block may still apply to it (built-in design roles, below).
- **Peer route.** `buildRoleSessionNotice` appends `common` + class for any
  session that meets the key above and whose row is chain-class.
  Clauses that already appear in the notice (the peer-brief and response-file
  lines) are **not repeated**; the Implementor de-duplicates.
- **Subagent route.** `subagentstart-cli-root.mjs` appends `common` + class,
  and design's routing block, **only** when the subagent's `agent_type`
  resolves through the lookup to a custom or overridden chain-class row. Every
  other subagent's output stays **exactly** today's one line (I1). The hook
  reads the contract files (plugin files, not agent files, so I7 holds) and
  the config it already reads.

  **Viability confirmed by E2** for project agents: SubagentStart carries
  `agent_type` = the bare agent name, with `agent_id` alongside. Lookup step 2
  resolves the name to the custom row, so the subagent route gets the contract
  **by name**. User-level agents behave the same way (E2-user, r3.3).

  **The subagent route's routing block is not filtered for availability (r3.7,
  N9).** It lists every custom alternative that has `routes`, whether or not
  its agent currently passes its contract. Availability needs an agent-file
  read, which I7 forbids in SubagentStart. The peer notice (SessionStart) and
  the Orchestrator directive **do** filter.

  The gap self-heals. If a subagent designer names an unavailable role in a
  spec header, the Orchestrator ignores it and tells the user (§1.14c rule 2).
  The pipeline falls back to the built-in (§1.14g). Caching SessionStart's
  availability for SubagentStart was considered and refused: it adds a state
  file that can go stale, to save one ignored header line.
- **Built-in design roles.** Built-in design roles (`ah:architect`) are not
  given the contract (their body carries it). When routing exists, they
  receive **only** the design routing block, through both routes. This is the
  former r2 §1.14e.

**Budgets:**

| Element | Budget |
|---|---|
| Injected contract (common + class) | ≤ 1350 B |
| Routing block | ≤ 200 B, plus 200 B per role |

**The known duplication.** Built-in agent bodies carry their own statements of
these same rules. They are **not** switched to injection in this spec: I8
forbids it, and F10's ceilings forbid growing them. The contract text now
exists twice, once in `contracts/` and once in the built-in bodies. The
`contracts/` files are the source of truth for custom agents, and any
wording change to a rule must be made in both.

- TODO for a follow-up spec: move the built-ins onto injected contracts and
  shrink their bodies. This is done once F10's ceilings are re-measured against
  the injected path.

## 2. Invariants — what must NOT change

- **I1.** With no custom rows and no overrides, the following equal today's
  output byte for byte:
  - the derived lists;
  - `buildDirective` (auto and confirm);
  - role-session notices;
  - SubagentStart output;
  - spawn commands;
  - `msg.mjs` results;
  - gate decisions.

  Existing suites pass with **no assertion edits**.
- **I2.** Existing configs, rosters, `team.json`, message files, gate.json and
  session-roles load unchanged. `CONFIG_VERSION` stays 1, and no migration is
  needed.
- **I3.** Teardown and lifecycle paths never refuse or drop a member because
  its role is absent, unavailable or invalid. These paths are disband,
  dismiss, untrack, reap, resync, whoami, teams, the SessionStart sweep, and
  SessionEnd/Stop.
- **I4.** Unregistered foreign agents are unchanged at every gate, with one
  exception: the Ultra-gate tightening for `*:ultra-advisor`.
- **I5.** `ah:*` resolves only to built-ins. Shipped `ah:*` agents are never
  validated or injected.
- **I6.** No hook throws on a malformed row, an unreadable or unparseable
  agent file, or a missing contract file. A missing contract file → inject
  nothing, and log once via `logHookError`.
- **I7.** No per-tool-call hook reads an agent file or validates. Readers are
  limited to SessionStart, SubagentStart (contract files only), and the CLI.
  Config reads stay lazy for non-`ah:` identities.
- **I8.** No `agents/*.md` file changes.

## 3. Files to touch

**Code:**

- `hooks/lib-config.mjs`, which holds the registry, the class and contract
  table, the lookup, the frontmatter reader, the validator, and contract-text
  loading;
- `hooks/lib-hier.mjs`, `hooks/lib-roster.mjs`, `hooks/roster.mjs`,
  `hooks/msg.mjs`, `hooks/lib-gate.mjs`, `hooks/lib-usage.mjs`,
  `hooks/usage-report.mjs`;
- the gates: `hooks/pretooluse-msg-gate.mjs`, `-route-gate.mjs`,
  `-sendmessage-response.mjs`, `-ultra-gate.mjs`, `-conduit-gate.mjs` and
  `-ah-cli.mjs`;
- `hooks/subagentstop-msg-nudge.mjs`, `sessionstart.mjs`,
  `sessionend-roster.mjs`, `stop-orchestrator-liveness.mjs`,
  `subagentstart-cli-root.mjs`, and `posttooluse-roster.mjs` (via lib-hier if
  possible).

**New files:**

- `agent-hierarchy/contracts/{common,advise,design,review,implement}.md`;
- `skills/agent-role/SKILL.md`;
- `tests/test-custom-roles.sh`;
- `tests/test-role-contract.sh`.

**Docs:**

- `skills/agent-roster/SKILL.md`, `skills/agent-team/SKILL.md`,
  `skills/autonomous-pipeline/SKILL.md`;
- `commands/hierarchy.md`, `docs/cli-tools.md`, `docs/team-file.md`.

**Version.** Bump `agent-hierarchy/.claude-plugin/plugin.json` **and** the
root `.claude-plugin/marketplace.json` together, to 0.86.0.

**Must NOT touch:** `agents/*.md`, the gate.json format, the message format,
the `team.json` format, and `CONFIG_VERSION`.

## 4. Verification

All tests run in a sandboxed HOME with cwd injection. No real config is
touched.

### `tests/test-custom-roles.sh`

**Baseline and the `role` verbs**

- **T1 (I1).** Capture golden fixtures **before the first edit**:
  - derived views;
  - `buildDirective` (auto and confirm);
  - each built-in's role-session notice;
  - SubagentStart output for `ah:architect` and for `task-gopher:task-gopher`;
  - spawn commands for all three transports.

  After the change, each must be byte-equal. **Show T1 failing once** (give
  `review` the tier rule), revert it, and paste the failure.
- **T2.** Round-trip `role set`/`list`/`remove` at every level. Check that
  seeding preserves unrelated keys, that a partial hand-edited row is
  excluded, and that `--routes ""` demotes an alternative to a side role.
- **T3.** Row refusals:
  - reserved or colliding names;
  - an agent charset violation (`;`, space, `$(`);
  - `ah:x` on a custom row;
  - a duplicate agent;
  - an advise-class role with a missing model or `inherit`;
  - haiku on a non-legwork role;
  - `--class`/`--routes`/`--scaffold` on a built-in;
  - legwork `routes`, which warns and is not written;
  - `remove` while a roster member uses the role;
  - `--scaffold` over an existing file, or onto a plugin ref.
- **T3b.** `--dry-run` writes nothing (neither the row nor a file), even with
  `--scaffold`.

**Spawn, identity and gates**

- **T5.** A custom member's spawn uses `--agent ui-implementor` and omits
  `--model`. With `--model opus`, the spawn includes `--model opus`.
  Checked on all three transports.
- **T6.** SessionStart with `agent_type:"ui-implementor"` gives the
  role-session notice, including the §1.17 contract and "alternative to
  Implementor for: …". peers.jsonl records the custom role. An unregistered
  agent type gets the Orchestrator directive.
- **T7 (route gate).**
  - An Orchestrator dispatch to the custom role is walled, with `spawn-ad-hoc`
    in the deny.
  - Custom legwork passes.
  - A role session dispatching a custom chain role is walled.
  - A role session dispatching custom legwork is allowed.
- **T8 (message gates).**
  - A dispatch without a message file is blocked.
  - `msg.mjs new --to ui-implementor` works.
  - `--to nope` fails and lists the custom roles.
  - The response-file gate applies to a `ui-implementor` session.
- **T9 (other gates).** The tier rule applies to custom design roles, and not
  to custom review roles. The Ultra gate fires for custom advise roles and for
  `x:ultra-advisor`. The conduit gate blocks a custom role session.

**Resilience**

- **T10.** Name parsing, and refusal of alias collisions.
- **T11 (I3).** Delete the row of a live member. SessionStart does not throw,
  doctor warns, and dismiss/disband still close the member.
- **T12 (I6).** Garbage rows produce warnings without throwing. So do a
  missing `contracts/` file (inject nothing, log once) and an unreadable agent
  file.
- **T13 (D1).** `roles.architect.agent:"my-architect"` with a design-valid
  file. Spawn uses it, `agent_type` resolves to Architect, `ah:architect` is
  still Architect, and the Architect line dispatches `my-architect` with the
  contract injected. An override file with `Edit` in `disallowedTools`
  missing is fine for design; an override file lacking `Write` is refused.
- **T14 (C2).** Description forms: plain, quoted with `\n`, `|` block,
  `<example>`-laden. Also the missing, no-frontmatter and 40 KB cases, and a
  plugin ref resolved via a sandboxed `installed_plugins.json`.

**Routing and budgets**

- **T15 (routing).**
  - The routing item, with every §1.14d part present.
  - Items 0 and 6 byte-identical.
  - The design routing block reaches the built-in Architect's notice and its
    SubagentStart.
  - A `task-gopher` SubagentStart is still exactly one line.
  - All of it disappears when `routes` is removed.
- **T16 (budgets).**
  - Custom line ≤600 B.
  - Routing item ≤260 + 220·n B.
  - Unavailable line ≤120 B + names.
  - Injected contract ≤1350 B.
  - Routing block ≤200 + 200·n B.
  - The default config stays within `AUTO_MAX` and `CONFIRM_MAX`.
- **T17 (I4).** `foo:bar` and `task-gopher:task-gopher` are unchanged at every
  gate.

### `tests/test-role-contract.sh` — the validator (§1.16)

**Tool contract**

- **C1.** For each class, a fixture file that passes, plus one fixture per
  failure code.
- **C2.** Per class, each `missing-tool`, including both halves of the
  either-or pairs for implement.
- **C3.** Review with `Edit`, and with `Write`, gives `forbidden-tool` errors.
- **C4.** A `tools` allowlist without SendMessage gives
  `missing-tool:SendMessage`. `tools` absent gives no error.

**File-level checks**

- **C5.** `name-mismatch`, `model-not-allowed` (haiku on review),
  `no-frontmatter`, and `unparseable-field` (a `tools: {weird}` value).
- **C6.** All three tools-list syntaxes parse. `Bash(git:*)` counts as Bash.
  `mcp__x__y` is ignored.
- **C7.** `agent-not-found` for a bare ref. `plugin-unresolvable` for a plugin
  with no install record, via a sandboxed `installed_plugins.json`.

**Output and enforcement points**

- **C8.** Every finding has a non-empty `fix`. `--json` output is valid, and
  the plain form prints the `fix:` lines.
- **C9.** `role set` refuses on errors and writes on warnings. `--scaffold`
  output passes with zero findings for each of the four chain classes, and for
  legwork.
- **C10.**
  - Revalidation at spawn: set a role valid, then break its file (remove
    `Write` for implement). spawn-one refuses with findings.
  - `create --spawn` spawns the other members and reports partial.
  - SessionStart marks the role unavailable: its lines are omitted, the
    unavailable line is present, and routing falls back to the built-in.
- **C11 (I7).** Instrument agent-file reads with a counting stub, or assert
  via strace-free file-timestamp stubbing, as the Implementor chooses.
  Running every PreToolUse, PostToolUse, UserPromptSubmit and Stop hook
  against a config with custom rows performs **zero** agent-file reads.
- **C12 (r3.2).** Each of these produces a `scoped-tool-entry` warning, and
  still counts as the tool for every check:
  - `tools: Read, SendMessage, Write, Bash(git:*)` on a design role produces
    `discouraged-tool:Bash`;
  - on a review role the same list produces `forbidden-tool:Write`.
- **C13 (r3.3).** Frontmatter `model: haiku` on a review agent produces a
  `model-not-allowed` error under both an `inherit` row and an explicit `opus`
  row. A row of `opus` with frontmatter `model: sonnet` produces **no**
  finding.
- **C14 (r3.2).** `shadowed-agent` fires when the same bare name exists in the
  sandboxed repo and user agent dirs. The validated path is the repo file,
  because project beats user (E1d).
- **C15 (r3.4, G1).** Two hand-edited custom rows share an agent. Both are
  excluded, and each warning names the other. A `role set` that would create
  the collision is refused.
- **C16 (r3.4, G2).** Set `roles.architect.agent:"my-architect"` to a valid
  file, then break the file.
  - SessionStart: the Architect line dispatches `ah:architect`, and the
    Unavailable line contains `architect (my-architect)`.
  - spawn-one architect: the launch has `--agent ah:architect`, and the result
    carries the findings plus the substitution notice.
  - `role list` shows `UNAVAILABLE → reverted to ah:architect`.
- **C17 (r3.4, G3).** `roles.task-runner` with `agent:"my-runner"` and
  `delegate:"task-gopher"`:
  - `subagentType` returns `my-runner`;
  - directive item 8 names `my-runner`;
  - the lookup resolves `my-runner` to task-runner;
  - the lookup resolves `task-gopher:task-gopher` to null (T17 still holds).
- **C19 (r3.7, N6).** With an available custom `design` row, directive items
  12–14 and the `lib-hier.mjs` tier text name its label, and still name
  Architect and Ultra-Advisor exactly as before. With no custom design or
  advise rows, both sites are byte-identical (T1). A custom `review` row adds
  no label.
- **C16 addition (r3.7, S1).** With `roles.architect.agent` set:
  - a session or subagent whose `agent_type` is `ah:architect` gets the
    byte-identical built-in notice or SubagentStart output, with no injected
    contract and no "your agent file";
  - one whose `agent_type` is `my-architect` gets the injection.
- **C18 (r3.6, name matching).** Run the cases below through both
  `roleFromName` and `hierarchyNameParts`. The hand-edited custom rows are
  `imp`, `runner` and `security-reviewer`; none is excluded.

  | Name | Resolves to |
  |---|---|
  | `claudetools-implementor` | implementor |
  | `claudetools-imp` | imp |
  | `claudetools-imp-2` | imp |
  | `proj-task-runner` (via `hierarchyNameParts`) | task-runner |
  | `proj-runner` | runner |
  | `proj-security-reviewer` | security-reviewer |
  | `proj-reviewer` | reviewer |

  With **zero** custom rows, every name in the T1 name-parsing fixture set
  resolves exactly as before, including `custom-reviewer-peer` → reviewer.
  Also include one multi-token legacy case, asserting today's order-based
  result.

### Existing suites

All green with no assertion edits. This includes `test-directive-size.sh`,
`check-gate-name-agreement.mjs` and `test-agent-frontmatter.sh`.

### Prose deliverables

`/ah:agent-role`, the pipeline changes and the `contracts/` wording are
checked by the Reviewer against §1.14g, §1.15c and §1.17's clause lists.

## 5. NEEDS-EVIDENCE

### Results (r3.2, from `0056-evidence.md`, Claude Code 2.1.281)

| Item | Result | Decision taken |
|---|---|---|
| E1b: project agent via `--agent` | Loads; `agent_type` = the bare name on SessionStart and Stop. | Lookup step 2 matches the bare name (§1.4). |
| E1c: missing agent | `-p` exits 1 with "not found", and no session starts. The interactive path is untested. | **Moot.** The validator refuses a missing file at add and at every peer spawn (§1.16b). |
| E2 (project agent) | `agent_type` = the bare name on SubagentStart, SubagentStop and in-subagent PreToolUse, with `agent_id`. The parent's PreToolUse(Agent) has no `agent_type`; the target is only in `tool_input.subagent_type`. | §1.17 subagent delivery is viable by name. No re-think needed. |
| E3: frontmatter `model:` | Honoured for `--agent`, and beats a settings `model`. | §1.7 model precedence. |
| E5: `--model` / Agent `model` vs frontmatter (r3.3) | `--agent n --model opus` and `Agent(subagent_type:n, model:"opus")` both run **opus** over frontmatter `model: sonnet`. | The explicit row model wins, so `model-conflict` is **dropped** (§1.7, §1.16a, §1.15c, C13). |
| E1a / E2-user: user-level agent (r3.3) | `agent_type` = the bare name, both on the `--agent` path and as a subagent. | Lookup step 2 unchanged. §1.17 subagent delivery works for user agents. |
| E1d: same name at both levels (r3.3) | The **project** file wins, on both the `--agent` path and the subagent path. | The §1.4a order is confirmed. `shadowed-agent` names the user file as shadowed. |
| E4a: allowlist without SendMessage | SendMessage is **removed**. | `missing-tool:SendMessage` stays an error. |
| E4b: list syntaxes | Comma, flow and block all work. | The reader accepts all three (unchanged). |
| E4c: `Bash(git:*)` | Grants **unscoped** Bash. | Count it as the tool; add the `scoped-tool-entry` warning. The scaffold and skill never use scoped entries as restrictions. |
| E4d: `disallowedTools` | Removes the tool. | The semantics are confirmed (§1.16c). |

### Still open

None. Every NEEDS-EVIDENCE item is closed (r3.3).

### Original questions (r3)

These go to an Implementor or runner. Use a scratch HOME and repo, and kill
every `claude` process started.

**None of these blocks this design.** E1 and E4 must land before the lookup and
the validator code are written.

**E1 — how `claude --agent <bare-name>` resolves.** Run it in three setups:

- (a) the agent exists only in `~/.claude/agents/<n>.md`;
- (b) it exists only in `<repo>/.claude/agents/<n>.md`, with the cwd in that
  repo;
- (d) both exist, with different descriptions.

For each setup, report whether the agent loads, the exact `agent_type` in
SessionStart, and, for (d), which file wins.

What the results decide:

- An `agent_type` that is not exactly the bare name → lookup step 2 must match
  whatever form appears.
- In (d), if the user-level file wins → the §1.4a lookup order flips.

(The r2 case (c), "missing agent", is **moot** in r3: the validator refuses a
missing file at add and at spawn.)

**E2 — the subagent's `agent_type`.** For
`Agent(subagent_type:"<bare user agent>")`, report `agent_type` as seen in
SubagentStart, SubagentStop, and a PreToolUse fired inside the subagent.

It decides two things: the key the lookup matches on, and whether SubagentStart
can recognise a custom subagent at all, which §1.17 injection depends on.

**E3 — frontmatter `model:`.** Run `claude --agent <n>` where the frontmatter
has `model: sonnet` and no `--model` flag is passed. Which model runs?

This affects docs only, plus the rationale for `model-not-allowed`. That check
stays an error either way.

**E4 — tool semantics (new).** Check each of these:

- (i) An `--agent` session, and a subagent, whose `tools:` allowlist omits
  SendMessage: can it call SendMessage?
- (ii) With `tools` absent: are SendMessage, Write, Bash and so on all
  present?
- (iii) Does Claude Code honour all three list syntaxes: comma scalar, flow
  list, block list?
- (iv) Is `Bash(git:*)` accepted in an agent's `tools`, and how does it
  behave?

What the results decide:

- (i) SendMessage survives an allowlist → `missing-tool:SendMessage` is
  dropped.
- (iii) Some syntax is not honoured → the reader reports it as
  `unparseable-field` rather than accepting it.
- (iv) Scoped entries are not honoured → they do not count as present.

## 6. Forks

### Resolved by the user

| Fork | Round | Decision |
|---|---|---|
| A | r2 | A1 + a skill-driven CLI |
| B | r2 | B1 |
| C | r2 | C2 |
| D | r2 | D1 |
| E | r2 | reversed: in-chain alternatives |
| F | r3 | F1: alternative reviewer only |
| G | r3 | neither option: a user-authored file is first-class, validated against the class contract; the scaffold is a minimal passing template |
| H | r3 | H1: no routing gate |
| I | r3.1 | **I1**: errors only for what the chain needs (the required tools, and review may not Edit or Write). The built-in conventions are warnings. §1.2 and §1.16a stand as written. |
| J | r3.1 | **J1**: agents that cannot be validated are refused. The fix is to copy the agent into `.claude/agents/` as a user-owned file. There is no `--unvalidated` flag. §1.16e and C7 stand as written. |

### Options as they were presented (kept for the record)

**Fork I — how strict the tool contract's role-separation checks are.**

- **I1 (recommended).** Errors cover only what the chain needs to function:
  - the required tools;
  - review may not Edit or Write (verdict independence).

  Built-in conventions are warnings: design with Bash, advise with Edit, the
  generic `advisor`, missing Bash for review and implement.
- **I2.** Every built-in restriction is an error. A custom role must mirror its
  built-in's tool shape exactly, so design has no Bash and advise has no Edit.
  This is stricter and safer, but it blocks legitimate variants, such as a
  design role that may run read-only commands.
- **I3.** Only required tools are errors. Nothing is forbidden, so even a
  reviewer that can edit is allowed, with a warning.

Picking I2 or I3 changes the §1.2 tool table, §1.16a and C3.

**Fork J — agents that cannot be validated.** This covers Claude Code's
built-in agents, plugins with no install record, and any agent whose file is
not found.

- **J1 (recommended).** Refuse, with the fix: copy the agent into
  `.claude/agents/` as a user-owned file. This keeps "validated at add time"
  absolute.
- **J2.** Allow with an explicit `--unvalidated` flag. Such a role is marked
  `UNVALIDATED` in `role list` and in its directive line. It is skipped at
  spawn revalidation, and still gets §1.17 injection.

Picking J2 adds the flag to §1.11 and the skill, and changes §1.16e and C7.

## 7. Decisions made here, and what was refused

**Behavioural contract (r3).** The behavioural half of the contract is
enforced by **runtime injection** (§1.17), not by file text. Required headings,
markers, or an `ah-class:` frontmatter key were all considered and refused:

- Only text in the model's context changes behaviour. Injection puts one
  versioned text there for every custom agent, from one source, with no drift.
- Markers prove presence, not adherence, and they force boilerplate copies.
- A required frontmatter key makes unmodifiable plugin agents unregistrable,
  while proving nothing a tool check does not already prove.

The validator therefore checks only mechanically checkable, load-bearing facts:
tools, model, name and existence. The gates enforce the hard behavioural lines.

**Other r3 decisions:**

- **Revalidation.** At peer spawn, errors refuse. At SessionStart, errors mark
  the role *unavailable*. There is no validation in any per-tool-call hook.
- **The scaffold** is a minimal template that passes the contract, using
  `disallowedTools` and never a `tools` allowlist.
- **The fix loop** edits only frontmatter, and only in user-owned bare-name
  files. It never edits a plugin's file or an agent body.
- **Validator scope.** It runs for custom rows and for built-in overrides.
  Shipped `ah:*` agents are trusted.
- **Known duplication.** The built-in bodies and `contracts/` both state the
  rules. A TODO names the follow-up that removes this.

**Decisions kept from r1 and r2:**

- A new `/ah:agent-role` skill.
- Explicit `routes` plus a spec header; routing is sticky per item. When
  unsure, auto mode uses the built-in and confirm mode asks.
- Items 0 and 6 stay byte-identical.
- No C2 cache.
- An invalid row is excluded and never merged down.
- Custom roles default to `inherit`; advise requires an explicit model.
- Ultra approval is shared per session.
- The Ultra-gate tightening.
- The `role` verbs are not gated behind the skill.

**Refused:**

- keyword or glob routing;
- per-row allowlist narrowing;
- existence checks or validation in hooks;
- LLM-judged or marker-based behavioural checks;
- a required `ah-class` key;
- parsing frontmatter keys beyond `name`, `description`, `model`, `tools` and
  `disallowedTools`;
- custom classes;
- legwork `routes`;
- drift detection;
- a `CONFIG_VERSION` bump;
- `agents/*.md` edits.

## 8. Risks for the Implementor

- **Blast radius.** The change touches every enforcement hook. I1 and the T1
  fixtures are the net, so capture the fixtures **first**.
- **Order of work:**
  1. E1, E2 and E4.
  2. The registry and the lookup.
  3. The frontmatter reader and the validator (with `test-role-contract.sh`).
  4. The gates.
  5. Spawn and revalidation.
  6. The directive, routing, `contracts/` and injection.
  7. The CLI and scaffold.
  8. The skills.
- **Hot path.** No agent-file read or validation may happen outside the I7
  callers. C11 guards this.
- **Import cycle.** The cycle is `lib-roster.mjs` ↔ `lib-config.mjs`. The new
  tables, the reader and the validator live in the leaf, `lib-config.mjs`.
- **Shell injection.** `agent`, `name` and `label` are validated at write time
  **and** at the spawn seam. `routes`, `description` and the contract text
  appear only in injected prose, never in shell.
- **Scaffold atomicity.** When the row write or the validation fails, the
  scaffolded file is removed.
- **Plugin-copy divergence.** For a local-path marketplace, validation reads the
  `installPath` copy (§1.4a caveat). Say so in `role list --json` output as
  `path`, so the user can see which copy was checked.
- **E2 was load-bearing for §1.17 and is now fully resolved** (r3.3). The bare
  name identifies both project and user agents.
- **Known constraint: `--setting-sources` (r3.3).** A `claude` process started
  with `--setting-sources` that excludes `user` cannot see
  `~/.claude/agents/` at all. The evidence showed `--setting-sources
  project,local` gives "not found". A user-level custom role would then pass
  the validator and still fail at spawn.

  The failure is **not reachable through ah today**:
  - no spawn path passes the flag: `spawnShape` for tmux, terminal and herdr
    `--kind claude`, and the codex `nativeArgs`;
  - claude-kind members cannot carry `args` (`lib-roster.mjs:215-217`), so the
    roster cannot inject it;
  - no hits in the herdr skill or the user's `settings.json` /
    `settings.local.json`.

  The residual routes are all outside ah's view:
  - a user's shell wrapper or alias for `claude`;
  - herdr's own internal launch of kind `claude` (a binary, not inspected);
  - a future change that adds the flag.

  So there is no check. If it happens, the peer exits 1 before SessionStart,
  and the existing spawn-failure path reports it: the startup timeout, and a
  partial team. **Any future change that adds `--setting-sources` to a spawn
  path must keep `user` in it, or refuse user-level custom roles at spawn.**
  This belongs in the review checklist for such a change.
