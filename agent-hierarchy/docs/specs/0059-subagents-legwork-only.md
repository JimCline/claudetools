# 0059 — Only legwork roles run as subagents

Status: r7, in implementation.

**r7:**

- G6 is reworded to the two injections the build uses. The §2.1.8
  Orchestrator text is reachable only through a throw inside config
  resolution.
- The route gate trims `subagent_type` on its normal path (§2.1.8, G7).
- The `roster.members:[null]` crash goes to §8.

**r6** (review finding 2, a spec defect): the route gate's `catch` fails
**closed** for the five built-in chain refs (§2.1.8, G6). Base: HEAD
7a09186 plus 0058.

r2 applies the user's answers to OQ-A through OQ-D (§6):

- §2.2 is rewritten as ladders: §2.2.1 design/review/implement, §2.2.2 the
  Ultra-Advisor escalation, §2.2.3 the three-ping stall rule, §2.2.4 a
  declined spawn;
- §2.3 gains S7–S9, so 0057's stale keys also migrate on write;
- the §2.4 pointers, §2.6 and tests D1, K2 and M1b change to match.

r2 is accepted. OQ-F is ruled "instruction only", and S9 is confirmed (§6).
No open questions remain.

**r3** answers the Implementor's NEEDS-ARCHITECT on §2.4 and §2.6:

- **GAP-1:** "PANE UNAVAILABLE" is dropped as a name. §2.4 now gives the
  exact new text of every directive edit, including roleLines :1741, and G5
  is reworded.
- **GAP-2:** item 13 loses its route sentence, and its gate sentence becomes
  unconditional. render.sh inputs are unchanged.
- **GAP-3:** item 0's dead route text is removed, with the exact wording
  given.
- **GAP-4 and GAP-5:** agents/*.md are left unchanged. r1's description
  rewrite is withdrawn, and no agent budget moves.

**r5 (GAP-7):** in §4 class 2, render.sh's gate section drops the route
opt-in. The Agent goldens show `spawnReason`, with no live peer and no age
text. The tier rule gets new SendMessage goldens, and tier tests move to the
SendMessage path.

**r4 (GAP-6):**

- §4 class 3 now enumerates the stale-key-warning golden deltas in
  plan-*.json and status-report.txt (option a). render.sh inputs stay
  unchanged.
- User-facing messages cite no spec number.

## 0. The rule and the user's rulings (verbatim where quoted)

**Standing rule:** "no agent in hierarchy should ever be sent to a subagent
except for task-runner".

| Ruling | Decision |
|---|---|
| **(a) Existing subagent-enabling state** | "Migrate on write". The next CLI write to that file drops or rewrites the key. |
| **(b) A chain role that can't get a pane** | "Orchestrator does it itself". |
| **(c)** | The exception covers **any legwork-class role**, custom ones included, not only task-runner. |
| **(d)** | "Off means off": with `enabled:false`, nothing is gated. |
| **(e)** | The gate denies `ah:orchestrator` as a subagent. |

Terms used below:

- **Chain role:** any role whose class has `chain: true` (advise, design,
  review, implement), custom roles included, plus the Orchestrator.
- **Legwork role:** any role of class `legwork` (`chain: false`), custom
  roles included.

## 1. Facts (HEAD 7a09186)

**Every subagent path for a chain role goes through one function.**
`subagentOptIn()` (lib-config.mjs:460-469) returns true for any of:

- an effective route of `subagents`, or `prefer-peers` with no free peer
  (:463);
- config `roles.<role>.dispatch === "model"` from a non-default source
  (:465);
- the role's roster member has `route === "subagent"`, its own or inherited
  from the block, or has `onMissing === "never"` with no live instance
  (:468).

**The route gate (pretooluse-route-gate.mjs) acts on it like this:**

- `enabled:false` passes everything (:164).
- A role is peer-eligible when `classProp(role, "chain") === true` (:210).
  Anything else passes (:210-219). That includes legwork, and
  `ah:orchestrator`: `hierarchyRoleOf` returns null for it, because the name
  is reserved (lib-config.mjs:540-556, :975), so today it passes untouched
  (:272).
- Subagent and subordinate callers are denied (:212-216).
- The Orchestrator branch, in order:
  - route (:220);
  - a one-shot deny for `prefer-peers` (:233-237);
  - opt-in passes (:238);
  - a live peer gives a `peersDenyReason` deny (:239);
  - `onMissing:"prompt"` gives a one-shot ask, `promptAskReason` (:135-144,
    :241-247);
  - otherwise `spawnReason` (:123-133), whose launch-failure line offers the
    subagent opt-in.
- The gate fails open on error (:273-276).

**Where the opt-in values live:**

- `ROUTE_VALUES = ["peers","subagents","prefer-peers"]` (lib-config.mjs:133).
- Config `route` is validated in `resolveConfig` (:1246-1257).
- `effectiveRoute` (lib-hier.mjs:683-688): the session record, then config,
  then `"peers"`.
- `sessionRouteRecord` (lib-hier.mjs:668-672) is the only reader of
  `gates.jsonl` `{type:"route"}` records. It already filters on
  `ROUTE_VALUES`.
- `msg.mjs route` (:291-305) appends those records.
- `ROSTER_ROUTE_VALUES = ["peer","subagent","pane"]` (lib-roster.mjs:71).
- `ON_MISSING_VALUES = ["auto","prompt","never"]` (lib-roster.mjs:87-88).
- `DISPATCH_MODES = ["peer","model"]` (lib-config.mjs:365).
  `normalizeDispatch` (:1054-1075) is the one place dispatch is normalized.

**Roster route and `onMissing` are defaulted in four places, not one.**
`resolveRoster` (lib-config.mjs:871-893) passes raw fields through. The four
sites:

- `statusReport` (lib-config.mjs:2100-2107);
- the route gate (:241);
- `resolveMembersPlan` (roster.mjs:2068);
- `planMembersFromHistory` (roster.mjs:2119).

**Directive text.**

- The Orchestrator line (lib-config.mjs:1965): "do not design or implement
  non-trivial changes yourself".
- Subagent and opt-in text appears at :1733 (the Agent-line branch), :1741
  (the "Subagent only if the user opts in: … route subagents" sentence),
  :1967, :1976, :1981, and item 13 at :1939.
- All six directive-*.txt goldens contain it.

**Nothing enforces "do not implement yourself".** hooks.json has no
PreToolUse matcher on Edit, Write or NotebookEdit.

**Launch failure is reported three ways:**

- spawn-one and spawn-ad-hoc: `launch_status === "failed"` leads to `fail()`,
  exit 2 (roster.mjs:2916-2925);
- create --spawn: exit 0, with the member's `launch_status:"failed"` and
  `partial:true` (:2718-2758);
- a layout break part-way: `partial()`, exit 3.

**There is always a transport.** Transport detection falls back to
`terminal` (`claude … --bg`) (:1190-1198, :1298), so "no transport" never
happens.

**Config writers.** In the CLI, only `writeLevelFile` (roster.mjs:963)
writes config. Its callers:

- `role set` (:443) and `role remove` (:483);
- `removeConfigMember` (:1186), reached from `remove`,
  `untrack --also-config` and `dismiss --also-config`;
- `storeTeamLayout` (:1397), reached from create with an explicit
  `--mode`, which writes the global file;
- `init` (:3064), `add` (:3110) and `edit` (:3213).

No hook writes config. `msg.mjs` never writes config. The `/hierarchy`
command has the **model** write config with the Write tool
(commands/hierarchy.md:140, :208).

**Stale-key channel.** `staleTeamKeys(cwd)` (lib-config.mjs:934-962)
returns `{warnings, aliases}`. It surfaces only in `status`, `doctor` and
every create phase, never in SessionStart. That is 0057 r4 S4's ruling.

**Team files can hold `route:"subagent"` chain members.** create --commit
hydration copies the route verbatim (roster.mjs:3402). spawn-one already
coerces a subagent-routed member to peer (:2895).

**Doc drift.** The hooks.json `description` and docs/comms-protocol.md:20,
:136 and :143-146 describe the pre-0055 "ask once, prefer-peers default"
gate.

**agents/{architect,implementor,reviewer,ultra-advisor}.md descriptions say
"Dispatch it …".** No test asserts on them.

## 2. Design

### 2.1 Route gate

Keep today's order. Change these branches:

1. **`enabled:false` passes everything** (d). Unchanged.
2. **`ah:orchestrator` is always denied (new)** when `subagent_type` is
   exactly `ah:orchestrator`, on either tool matched (Agent or Task), for
   every caller. The reason says: "The Orchestrator is the top-level session
   and never runs as a subagent. Do this orchestration here."
   - A bare `orchestrator` agent ref is not ours and is not matched.
3. **Legwork roles pass** (c): task-runner, `task-gopher:task-gopher` and
   custom legwork roles. Unchanged.
4. **Subagent and subordinate callers dispatching a chain role are
   denied.** Unchanged.
5. **An Orchestrator dispatching a chain role is never let through as a
   subagent:**
   - The `subagentOptIn` pass (:238) is deleted.
   - The `prefer-peers` one-shot (:233-237) is deleted.
   - The `onMissing:"prompt"` ask (:241-247, `promptAskReason`) is deleted.
   - What remains: a live peer gives `peersDenyReason`; otherwise
     `spawnReason`. Both deny every time.
   - `subagentOptIn` is deleted if nothing else uses it.
6. **`spawnReason` text:**
   - The opt-in line (:130) is replaced (r2) by: "If the command fails to
     launch, follow agent-team's 'When a role can't take the work'." For
     design, review and implement, that means doing the work yourself. For
     an advise role, it means continuing the escalation ladder.
   - The team-name-unusable line and 0058's member-model-undefined handling
     keep saying "not a launch failure". They drop "does not lead to the
     subagent opt-in".
   - The opening sentence becomes "ah chain roles run as peers, never
     subagents."
7. **Unchanged:** the tier gate (:255-270) and `pretooluse-ultra-gate`,
   which gates advise roles on both Agent and SendMessage. Its Agent branch
   now only precedes a route-gate deny, which is harmless.
8. **(r6, review finding 2) Fail closed for the built-in chain refs.** The
   `catch` is the one place where fail-open would let a chain role through
   as a subagent.
   - **The rule.** In the `catch`, when the tool is Agent or Task and
     `tool_input.subagent_type` (with whitespace trimmed) is exactly one of
     `ah:orchestrator`, `ah:ultra-advisor`, `ah:architect`, `ah:reviewer` or
     `ah:implementor`, **deny**. Everything else stays fail-open as today:
     legwork refs, custom-role refs, any other agent, SendMessage, and every
     other tool.
     - These five refs are known without config, which is why only they are
       listed.
     - Custom chain roles need config to classify, so they cannot be denied
       in the `catch`. That is an accepted limit.
   - **The error is still logged** first, with `logHookError`, as today.
   - *(r7)* The Orchestrator deny text below is reachable only through a
     throw inside config resolution. A readable config has already denied
     `ah:orchestrator` through the pre-resolution check (:161).
   - **(r7) Trim on the normal path too.** The route gate trims
     `tool_input.subagent_type` before its `ah:orchestrator` check and
     before role resolution, the same way the `catch` and the ultra-gate
     already do. Otherwise `" ah:architect "` would resolve to no role and
     pass, a bypass of "never" if Claude Code accepts padded names, which is
     unverified. The trim is harmless either way, so it needs no evidence
     first.
   - **Deny text.** It is built from the input alone, with no config read
     and nothing that can throw again:
     "ah: the route gate hit an internal error and could not check this
     dispatch (logged to <the file logHookError writes>). <Role> never runs
     as a subagent: SendMessage its live peer, or start one with
     `node "<ROSTER_CLI>" spawn-one <role> --cwd <input cwd>`."
     - For `ah:orchestrator` it says instead: "The Orchestrator never runs
       as a subagent."
   - **(d) "off means off".** `enabled:false` still returns `decide(null)`
     before any of this runs (:164), so an off hierarchy is never gated.
     - The only overlap is a throw **inside** config resolution, before
       `enabled` is known. The `catch` then denies the five refs.
     - A throwing config read is a fault, not the user's "off". The rule is
       "never". The denial names the error log and the peer route, so the
       user is not stuck.
     - This is my ruling, not a user question. The user can overturn it by
       asking that an unknown `enabled` fail open.

### 2.2 Ruling (b): the Orchestrator does a chain role's work itself

**When.** The Orchestrator does the work itself only when it tried to launch
that role's pane for the work at hand, and the launch **failed**:

- spawn-one or spawn-ad-hoc exited 2 with a launch error, which is not a
  structured refusal;
- create reported that member `launch_status:"failed"`;
- or a layout break (exit 3) left that member unlaunched.

These are **not** launch failures:

- `team-name-unusable` and `member-model-undefined`, which are handled as
  their specs say;
- 0058's legwork `skipped_members`;
- a spawn command the user **declined** at the permission prompt. That is a
  user decision (OQ-C, confirmed; §2.2.4).

A transport is always available (§1), so there is no "no transport" case.

*r2: the user clarified OQ-A, verbatim: "Wait, paneless doesn't mean it
can't spawn a role into a new pane. Paneless meant, it physically could not
spawn a new pane for some reason and can't fallback to subagents. In the case
of Ultra Advisor, should still be able to spawn one if it is defined with a
model or ask the user to spawn one or if that fails fallback to the highest
reasoning role if alive or spawn it, or fallback to itself."*

This matches the r1 trigger above: **paneless = a physical launch failure**,
and not "no live pane". The ladders below are the full rule.

**Scope.** The Orchestrator taking over covers only the work at hand. The
next time that role is needed, the ladder starts again from the top.

#### 2.2.1 Design, review and implement roles (custom included)

Each step runs only if the one before it fails.

1. **Live instance.** A live instance of the role gets the brief by
   SendMessage. This is unchanged.
2. **Spawn a pane.** Otherwise spawn it with spawn-one, or spawn-ad-hoc when
   the roster has no member for the role. When the member has no model,
   0058's ask or fallback supplies one. A 0058 refusal is not a failure: it
   is handled as 0058 says, and the spawn is retried.
3. **Paneless.** Only when that launch **physically fails**, the
   Orchestrator does the work itself. It works in its own session, under that
   role's contract, which is directive item 0's existing meaning of "do it
   inline". First it tells the user one line: "<Role> could not be launched
   (<reason>); doing its work here."

There is no cross-role step for these classes. Sending implementation work to
an Architect, for example, would break that role's contract, and the user's
ruling names such a step only for the Ultra-Advisor.

#### 2.2.2 Ultra-Advisor escalation (advise class, custom included): the user's ladder

**Approval comes first, per escalation.** The Orchestrator reads
`gate.mjs status --session <id>` before step 1.

| Recorded decision | What happens |
|---|---|
| None | Ask the gate's first-use question: firstUseReason's three options, verbatim (pretooluse-ultra-gate.mjs:71-89). Record the answer with `gate.mjs set`, then continue by the answer. |
| `off` | **No ladder.** Handle the question the way blockedReason already says: "with the Architect or inline, and state plainly what that leaves unadjudicated". |
| `session` | Run the ladder. Nothing more is asked. |
| `each` | Run the ladder. At steps 1–2 the gate's own `ask` prompt fires when the brief is delivered to the Ultra-Advisor peer. If the ladder reaches step 3 or 4 before any such prompt was answered for this escalation, ask once with AskUserQuestion ("Escalate this to <role> (<model>) / adjudicate here, since no Ultra-Advisor could be launched?") before delivering. One answer covers the rest of that escalation. |

**The ladder.** Each step runs only if the one before it fails.

1. **An Ultra-Advisor that can be reached.**
   - A live Ultra-Advisor peer gets the brief by SendMessage, gated by the
     ultra-gate as today.
   - Otherwise, if a roster Ultra-Advisor member is **defined with a model**,
     spawn it with spawn-one, then SendMessage it.
2. **Ask the user to spawn one.** This covers a member with no model, or no
   member at all (spawn-ad-hoc). 0058's `member-model-undefined` refusal
   drives the ask.
   - The question carries 0058's options, plus **"Don't spawn an
     Ultra-Advisor"**, which goes to step 3.
   - An unattended driver takes 0058's advise fallback (a borrowed fable/opus
     chain model) if there is one. Otherwise it goes to step 3.
   - A physical launch failure of the spawned member also goes to step 3.
3. **The highest-reasoning chain role.** Rank the design, review and
   implement members (custom included) visible to the Orchestrator:
   - its live team's members, by their recorded model;
   - its roster's members, by their stored model.

   The rank is the model's tier from the existing `TIER`/`tierOf`. An
   `inherit` model, or none, ranks below every tiered model. Ties go to a
   live member first, then design before review before implement, then
   roster order.
   - The top member gets the **same escalation brief**: spec path, the
     specific question, and a request to adjudicate and advise, answered
     within its own contract.
   - If it is live, SendMessage it. Otherwise spawn it, then SendMessage it.
   - If no such member exists, or its launch physically fails, go to step 4.
4. **The Orchestrator adjudicates itself**, on its own model. It first tells
   the user one line: "No Ultra-Advisor or <role> could take this (<reasons>);
   adjudicating here on this session's model."

**How step 4 sits with the gate.** Step 4 dispatches nothing, so no hook can
see it. It is reached only inside an escalation the user already approved:
`session`, or `each` with the step-3/4 question answered. With `off`, the
ladder never starts. So step 4 needs no extra question beyond the approval
table, and **no open question is raised**.

The approval for step 3 is enforced only by the directive, because its
delivery is a SendMessage to a chain peer, which the ultra-gate does not
watch. That is the same enforcement level as "do not implement yourself"
(§1). Mechanical enforcement is OQ-F.

#### 2.2.3 A stalled peer: three pings, then take over

*r2, OQ-B ruled verbatim: "Ping the agent, get it to respond, only after 3
attempts, take over".*

This replaces the directive's single ping (lib-config.mjs:1976).

- **Stalled** means both of these hold:
  - the peer **owes the Orchestrator a reply**: the Orchestrator's brief or
    last message is the latest in that exchange, so a peer waiting on the
    Orchestrator's answer to its own question is not stalled;
  - its ListAgents row shows it **idle**.

  A **busy** peer is working. It is never pinged, and it never counts
  toward the three. The user's standing rule against abandoning in-flight
  work applies.
- **Cadence** is driven by events, with no timers.
  - Each ping is one SendMessage to that peer, sent with
    `notify_when_idle: true`: "Ping n/3: you owe a report on task <slug> —
    SendMessage it back to the sender."
  - The next ping is sent only when that idle notice arrives with no reply.
  - A subscription that expires without a notice means the peer stayed
    busy. Keep waiting, without adding to the count.
  - A peer that has left ListAgents is **gone**, not stalled. Treat it as a
    missing peer, which is the §2.2.1 or §2.2.2 ladder.
- **A response** is any SendMessage from that peer to the Orchestrator, or a
  response file for the brief's request id.
  - The report itself ends the protocol.
  - A non-report reply, such as an acknowledgement, means the peer is not
    stalled at that moment. The count is **per brief and never resets**, so
    at most three pings per brief are ever sent.
- **Take over** after the third ping's idle notice arrives with no reply:
  - design, review or implement: the Orchestrator does the work, as §2.2.1
    step 3 describes, with the same one-line notice;
  - Ultra-Advisor: continue §2.2.2 **from step 3**. A second Ultra-Advisor
    is not spawned beside the stalled one.
- **The stalled pane is left running, not closed.** The Orchestrator tells
  the user it is still up and can be closed with agent-team's `dismiss`.
- **A report that arrives after the takeover** is shown to the user, not
  dropped.

#### 2.2.4 Declined spawn (OQ-C, confirmed)

When the user declines the spawn's Bash permission prompt, ask with
AskUserQuestion: "Do the <Role> work here" or "Stop". It is not a launch
failure.

#### 2.2.5 Where this lives

- The full procedure (§2.2.1–2.2.4) goes in **skills/agent-team/SKILL.md** as
  a new section, "When a role can't take the work".
- The directive carries only short pointers (§2.4), because it must stay
  within test-directive-size.sh's budget (auto ≤ 14600 B, confirm ≤ 16500 B),
  which is **not** raised.
- The directive's Orchestrator line (:1965) gains: "…except where agent-team's
  'When a role can't take the work' has you take it over."
- **No hook changes for this.** Nothing enforces the prohibition (§1). The
  ultra-gate stays as it is, and its blockedReason text already matches the
  `off` row.

**Role sessions (peers) are unchanged.** They never do another role's work;
they route back to the Orchestrator.

### 2.3 Ruling (a): migrate on write, ignored until then

**Stale state.** "Non-legwork" means the member's or role's class, resolved
with the existing `roleClass`. A member whose role cannot be resolved is
left untouched.

| # | Where | Stale value | Read-time meaning until migrated | Migration on write |
|---|---|---|---|---|
| S1 | roster block `route` (`roster`, `rosters.<r>`) | `"subagent"` | chain members: `"peer"`; legwork members inheriting it: still `"subagent"` | block `route` becomes `"peer"`. Every legwork member *without* its own `route` gets `route:"subagent"`, so its effective route is preserved. |
| S2 | member `route` on a non-legwork member | `"subagent"` | the block's route, or `"peer"` if the block's is also stale | delete the member's `route` |
| S3 | member `onMissing` | `"never"` or `"prompt"` | `"auto"` | delete `onMissing` |
| S4 | `roles.<role>.dispatch` on a non-legwork role | `"model"` | `"peer"` | delete `dispatch` |
| S5 | top-level `route` | `"subagents"` or `"prefer-peers"` | `"peers"` | delete `route` |
| S6 | `gates.jsonl` `{type:"route"}` records | `"subagents"` or `"prefer-peers"` | `"peers"` | **never rewritten** (see below) |
| S7 (r2, OQ-D) | top-level `teamAlias` (0057 stale key) | any | ignored, as 0057 already rules | delete `teamAlias` |
| S8 (r2, OQ-D) | `roster.layout` / `rosters.<r>.layout` (0057) | any | ignored, as 0057 | delete that `layout` |
| S9 (r2, OQ-D) | `teamLayout` in a **non-global** file (0057) | any | ignored, as 0057 | delete `teamLayout` from that non-global file. The global file's `teamLayout` is live, and is never touched. |

**Until migrated: ignored, with a warning in the stale-key channel only.**

- **One normalization, applied at read.** Every consumer sees the read-time
  meaning, and the four ad-hoc defaulting sites (§1) go through it rather
  than being patched one by one. The Implementor chooses the seam;
  `resolveRoster` is the natural one.
- For S4, `normalizeDispatch` maps non-legwork `"model"` to `"peer"`
  **without** pushing its usual resolveConfig warning. resolveConfig
  warnings reach the SessionStart directive, and 0057 S4 keeps stale-key
  warnings out of it.
- For S5, the same applies to the config `route` validation (:1246-1257).
- **S1–S5 warnings are added to `staleTeamKeys`'s output**, reusing it and
  not building a second channel. They surface only in `status`, `doctor`
  and every create phase. Each names the file and key, says it is ignored
  because only legwork roles run as subagents, and says it will be removed
  at the next CLI write to that file, or can be deleted by hand.
- They never appear in the SessionStart context, the nudge, or gate reason
  text.

**"Write" means a CLI write the user started, to that file only.**

- Migration happens inside `writeLevelFile` (roster.mjs:963). It is the one
  choke point, and every CLI config write goes through it: role set, role
  remove, remove, untrack/dismiss `--also-config`, init, add, edit, and
  create's `storeTeamLayout`.
- It transforms only the file being written. Other level files keep their
  stale keys until they are written.
- Keys that are not stale, and key order, are preserved.
- The verb's output gains `migrated: [{path, key, from, to}]`, where `to` is
  `null` for a deletion. It is present only when non-empty, with one stderr
  notice per file.
- `--dry-run` writes nothing and migrates nothing.

**Never migrated:**

- Hooks never write config, and nothing in this spec makes them.
- Model-driven Write-tool edits (`/hierarchy`) are not CLI writes. They
  preserve other keys, so stale keys survive them, ignored and warned. §2.6
  stops `/hierarchy` offering the stale values.
- *(r2, OQ-D ruled "yes, same rule")* 0057's stale keys (S7–S9) now
  **also migrate on CLI writes** through `writeLevelFile`. This reverses 0057
  r4 S4's "never rewritten" for CLI writes only. Hooks and read-only verbs
  still never rewrite config.
  - 0057's warning text ("delete it from <path> to drop this warning")
    gains "or it is removed at the next CLI write to that file", the same
    wording as S1–S5.
  - S9 is included with S7 and S8 because it is the third key of the same
    0057 stale set that `staleTeamKeys` already reports.
- Team files are not rewritten for this. A chain member recorded with
  `route:"subagent"` reads as `"peer"` through the same normalization:
  spawn-one already launches it as a peer (:2895), and the gate treats it
  as a missing peer.

**S6, `gates.jsonl` (append-only).** "Migrate" means old records become
**inert**, and nothing is rewritten.

- `ROUTE_VALUES` becomes `["peers"]`. `sessionRouteRecord` already filters
  on it (lib-hier.mjs:668-672), so a stale record is simply not found and the
  effective route is `"peers"`.
- The only write after this is `msg.mjs route peers`, which appends
  `"peers"`.
- No warning: route records are session-scoped and only ever affected the
  session that wrote them.

### 2.4 Directive (lib-config.mjs)

*r3: the exact text of every edit, so there is no interpretation left.
"PANE UNAVAILABLE" was an r1 name. It exists nowhere and is **not**
introduced; every pointer names the agent-team section instead.* The
quoted strings below are the new text as it renders. Keep the existing
template variables and escaping around them.

- **:1965, the Orchestrator line, becomes:**
  "Agent hierarchy ACTIVE. You are the Orchestrator: decompose, dispatch,
  synthesize — do not design or implement non-trivial changes yourself,
  except where agent-team 'When a role can't take the work' has you take a
  role over."
- **roleLines (:1723-1743):**
  - A chain role never gets an Agent line. The opt-in branch at :1733 goes;
    the :1733 condition keeps only the non-chain half.
  - At :1741, the trailing sentence ``Subagent only if the user opts in:
    `node "${MSG_CLI}" route subagents --session …`.`` is **replaced by**
    `Can't launch → agent-team 'When a role can't take the work'.` Everything
    before it on that line is unchanged.
  - Legwork lines are unchanged.
- **:1967, the roles intro, becomes:**
  "Roles — dispatch route per role below. Ultra-Advisor, Architect,
  Reviewer, Implementor are peer sessions, never subagents: SendMessage the
  live one; none live → spawn it with the command on its line, then
  SendMessage the name it prints (Ultra-Advisor is approval-gated — item 7).
  Legwork (Task-Runner) always spawns or delegates to task-gopher; pass
  `model` on the Agent call — agent frontmatter is fallback only:"
- **:1976, the PEER BRIEF CONTRACT stall line, becomes:**
  "- No reply and ListAgents shows the peer idle → ping it with
  notify_when_idle (\"Ping n/3: you owe a report on task <slug> —
  SendMessage it back to the sender\"); never ping a busy peer; 3 unanswered
  pings → take over per agent-team 'When a role can't take the work',
  leaving its pane running."
- **Item 7 (:1990):** insert this sentence immediately before
  `${gateSentences(sessionId)}`: "No Ultra-Advisor reachable → the
  escalation ladder in agent-team 'When a role can't take the work'."
- **Item 0 (:1981, confirm flow only):** delete all the dead route text
  (GAP-3).
  - Delete "read that role's dispatch line in Roles above. Line shows an
    Agent call (the user opted into subagents for it) → skip ListAgents for
    it; offer \"Dispatch <role> (Recommended)\", \"Do it inline yourself\",
    \"Skip this step\". Otherwise". The text then reads "…review-loop
    re-dispatches included — ListAgents first: is its peer present?…".
  - Delete the sentence "Add \"Dispatch <role> subagent instead\" only when
    the user opted in (route subagents/prefer-peers, item 13)."
  - "This item decides only WHETHER to hand off — the route decides HOW."
    becomes "This item decides only WHETHER to hand off."
  - "Ultra-Advisor: both routes equally gated by item 7's PreToolUse
    approval gate (it watches SendMessage to the Ultra-Advisor peer as it
    watches Agent/Task) — the peer option never skips user approval."
    becomes "Ultra-Advisor: gated by item 7's PreToolUse approval gate (it
    watches SendMessage to the Ultra-Advisor peer) — the peer option never
    skips user approval."
  - Everything else in item 0 is unchanged, including "Do it inline
    yourself" and the "Task peer" definition.
- **Item 13 (protocolItems ~:1939) (GAP-2):**
  - The heading "PEER ROSTER + ROUTE" becomes "PEER ROSTER".
  - Delete the opt-in text, from "A subagent for those roles only when the
    user opts in" through "\"peers only\" revokes it.", including the
    `msg.mjs route` command.
  - **Delete the route sentence** "This session's dispatch route is
    ${routeText} — honor it without re-asking."
  - Make the gate sentence unconditional: "Under \"peers\" a PreToolUse gate
    denies EVERY Agent call …" becomes "A PreToolUse gate denies EVERY Agent
    call …", with the rest of the sentence unchanged.
  - Drop `routeText`, and the `effectiveRoute` read that feeds it, if
    nothing else in buildDirective uses them.
  - The rest of item 13 is unchanged.
  - **render.sh inputs are not changed.** The prefer-peers config behind
    directive-roster-confirm.txt and the `subagents` session record behind
    directive-confirm-subagents.txt stay as they are. Those two goldens now
    show that stale route state is ignored: they carry no route or opt-in
    text and no chain-role Agent lines.
- **The procedures stay out of the directive (r2).** It holds only the
  pointers above. The full procedure lives in the agent-team skill (§2.2.5).
  - Stay within test-directive-size.sh's budget (auto ≤ 14600 B, confirm
    ≤ 16500 B), which **must not be raised**. The deleted opt-in text should
    pay for the pointers.
  - If it does not fit, stop and report NEEDS-ARCHITECT; do not trim other
    items on your own judgment.

### 2.5 CLI validation for new writes

All of these exit 2 with a message saying only legwork roles run as
subagents. The message cites no spec number (r4).

- `init --route subagent`. Its message says to route individual legwork
  members instead.
- `add`, `edit` or `spawn-ad-hoc` with `--route subagent` for a non-legwork
  role. This also applies to `edit --role` into a non-legwork role while the
  row is subagent-routed.
- `--on-missing never|prompt`. `ON_MISSING_VALUES` becomes `["auto"]`
  (OQ-E).
- `role set <R> --dispatch model` for a non-legwork class, builtin or custom.
- `msg.mjs route subagents|prefer-peers`. `ROUTE_VALUES` becomes
  `["peers"]`. A bare `route` prints `peers`.

Validation lives where it does today: `validateMember` (lib-roster.mjs:
226-251), init's route check, and `roleSet`. **Legwork `--route subagent`
and `--dispatch model` stay valid.**

### 2.6 Skills, commands, docs, agents

- **skills/agent-roster/SKILL.md, init step 2 (:116-120):** remove the
  peer-vs-subagent question. init always runs `--route peer`. Renumber the
  steps.
- **skills/agent-team/SKILL.md:**
  - :56 and any other "subagent opt-in" text becomes "not a launch failure".
  - A launch failure points to the new section.
  - **(r2) New section "When a role can't take the work"** with §2.2.1–2.2.4
    written out for the driver:
    - the design/review/implement ladder;
    - the approval table and escalation ladder, including the "Don't spawn
      an Ultra-Advisor" option added to 0058's question for an advise member
      when escalating;
    - the three-ping stall rule;
    - the declined-spawn question.
- **skills/agent-role/SKILL.md:** `--dispatch model` is offered only for
  legwork-class roles.
- **commands/hierarchy.md:**
  - The `dispatch` and route docs (:18-42) say `model` is legwork-only and
    that route opt-ins no longer exist.
  - The `/hierarchy` flows never write `dispatch:"model"` for non-legwork
    roles, or a non-`peers` `route`.
  - :112 drops the `ls -d ~/.claude/plugins/cache/*/task-gopher` cache glob
    and keeps only the "task-gopher:task-gopher agent type present" check.
    This carries over 0058 §8.
- **hooks/hooks.json `description`** and **docs/comms-protocol.md** (:20,
  :136, :143-146) are rewritten to current behaviour: a permanent peer wall
  for chain roles, legwork subagents allowed, no route question.
- **agents/*.md are not changed (r3, GAP-4/GAP-5, withdrawing r1's
  description rewrite).**
  - In this plugin "dispatch" already means tasking a peer: the directive
    says "decompose, dispatch, synthesize" and "dispatch route per role". So
    "Dispatch it …" does not claim an Agent-tool route.
  - The route gate enforces the rule mechanically (G1, G3).
  - Both readings of the rewrite cost something:
    - replacing the whole sentence drops each role's purpose clause;
    - rewording in place grows each file by about 130 B, past the
      test-directive-size.sh agent budgets (orchestrator.md is at
      7350/7350).
  - **No agent-file budget is raised.**
- **Not changed:**
  - subagentstart-cli-root.mjs (:20-48), which injects into custom
    chain-role subagents. That is reachable only with `enabled:false`, where
    (d) says nothing is gated.
  - pretooluse-ultra-gate.

## 3. Files

| File | Change |
|---|---|
| hooks/pretooluse-route-gate.mjs | §2.1 |
| hooks/lib-config.mjs | `ROUTE_VALUES`; `subagentOptIn` removal; the read-time normalization (§2.3); `normalizeDispatch`; config `route` validation; `staleTeamKeys` S1–S5; directive (§2.4) |
| hooks/lib-hier.mjs | only if `effectiveRoute`/`sessionRouteRecord` need more than the `ROUTE_VALUES` change |
| hooks/lib-roster.mjs | `ON_MISSING_VALUES`; `validateMember` route/class rule |
| hooks/roster.mjs | `writeLevelFile` migration plus the `migrated` output; init/add/edit/spawn-ad-hoc/role-set validation; consumers switched to the shared normalization |
| hooks/msg.mjs | the `route` verb accepts only `peers` |
| skills/agent-roster, agent-team, agent-role SKILL.md; commands/hierarchy.md; hooks/hooks.json; docs/comms-protocol.md; docs/cli-tools.md; agents/*.md | §2.6 |
| tests/fixtures/0056-i1/golden/ | §4 exceptions |
| tests/* | §5, plus updating the existing subagent-routing tests (§5 T-list) |
| plugin.json and root marketplace.json | version bump together |

## 4. Must not change

**Ruled golden exceptions.** Regenerate them with render.sh. The Reviewer
checks every diff hunk falls in these classes:

1. **All six directive-*.txt:** only the §2.4 edits, as given there in r3's
   exact text. That includes:
   - item 13 losing its route sentence, its opt-in text and the "Under
     \"peers\"" qualifier, in every variant;
   - item 0 losing its dead route text, in the confirm variants.
   - directive-confirm-subagents.txt and directive-roster-{auto,confirm}.txt
     also lose their chain-role `Agent(...)` lines, which become peer lines,
     because their opt-ins are now ignored.
2. **(r5, GAP-7) Route-gate goldens.** render.sh:99-104's gate section
   changes inputs. r3's "render.sh inputs unchanged" covered only the
   config fixture behind the directive, plan and status goldens, not this
   section.
   - **Delete the `msg.mjs route subagents --session gate-<role>` step.**
     It now exits 2, and a session opt-in no longer exists.
   - **gate-route-<chain role>.json**, the `Agent(ah:<role>)` case, is run
     with **no live peer for that role**. Each golden is then exactly
     `spawnReason` (§2.1.6). How the no-live-peer state is reached (running
     the case before the notice step, or in a fresh hierarchy dir) is the
     Implementor's choice, but it must be deterministic.
     - **No golden may pin `peersDenyReason`'s age text** ("Ns ago"), so it
       cannot flake.
   - **The tier rule moves to the path where it still fires.** Add
     `gate-route-send-<chain role>.json`: the route gate on an Orchestrator
     **SendMessage** peer brief to that role's live peer, with the session
     model `claude-fable-5`, as today.
     - architect and ultra-advisor must carry the tier-rule deny that HEAD's
       gate-route-{architect,ultra-advisor}.json carried. Only wording the
       gate itself already varies by tool (Agent vs SendMessage) may
       differ.
     - reviewer and implementor are empty.
     - These are new files, not deltas.
   - gate-route-task-runner.json is unchanged, because legwork passes.
3. **(r4, GAP-6, option (a)) The stale-key warning, and the opt-in state it
   normalizes, in these goldens only:**
   - **plan-{terminal,tmux,herdr}.json:** a first line
     `roster.mjs: warning — ah: roles.reviewer.dispatch "model" in <SANDBOX>/myrepo/.claude/agent-hierarchy.json is ignored …`,
     with the S4 text per the note below, and a trailing JSON `"warnings":[…]`
     holding the same text. Nothing else changes.
   - **status-report.txt:**
     - :11 `Reviewer … [dispatch: subagent-only]` becomes
       `[dispatch: peer "myrepo-reviewer"]`, from the S4 read-time
       normalization;
     - one new warning line (:25) with the same S4 text.

     Nothing else changes.
   - **Why these change:** render.sh:67's
     `"reviewer":{"model":"sonnet","dispatch":"model"}` is S4-stale. The
     fixture inputs are **kept** (r3). They are now the golden proof that
     stale state is ignored at read and warned in the CLI channel. Dropping
     the fixture's `dispatch:"model"` (option b) would lose that proof and
     change the directive-roster inputs. Keeping S4 out of create (option c)
     would contradict M3.
   - derived.json, notice-*.json, adhoc-*.json and every gate-*.json other
     than §4 class 2 must be byte-identical.

   **No spec numbers in user-facing text (r4).** Stale-key warnings,
   validation refusals (§2.5) and the `msg.mjs route` refusal cite no spec,
   so "(spec 0059)" is dropped. The S4 warning reads: `ah: roles.<role>.dispatch "model" in <path> is ignored — only legwork roles run as subagents. It is migrated at the next CLI write to that file, or delete it by hand.`
   The other S-keys follow the same pattern.

**Unchanged behaviour:**

- Legwork subagent dispatch: the directive's legwork Agent lines, and the
  gate letting legwork through.
- `enabled:false` passes everything.
- The tier gate, the ultra-gate, and SubagentStart.
- 0057's read-side handling of `teamAlias`, `layout` and non-global
  `teamLayout`: they are ignored and warned in the CLI only. r2 changes only
  what happens on a CLI write (S7–S9).
- All 0058 behaviour.
- Hooks never write config. `gates.jsonl` is never rewritten. Team files
  are never rewritten for this spec.
- spawn-one's existing coercion of a subagent-routed member to peer (:2895),
  and spawn-ad-hoc's refusal and create's exclusion of subagent-routed
  **legwork** members.

## 5. Acceptance

Tests run with HOME redirected.

- **G1.** With no live peer, an Orchestrator `Agent(ah:architect)` is
  **denied with `spawnReason`** under each former opt-in, one at a time:
  - a session `route subagents` record;
  - config `route:"prefer-peers"`, with and without a free peer;
  - the roster member `route:"subagent"`, its own and block-inherited;
  - `onMissing:"never"`;
  - `onMissing:"prompt"`, and the identical re-issue is also denied;
  - `roles.architect.dispatch:"model"`.

  The same holds for a custom implement-class role.
- **G2.** `Agent(ah:task-runner)`, `Agent(task-gopher:task-gopher)` and a
  custom legwork role pass.
- **G3.** `Agent(ah:orchestrator)` and `Task(ah:orchestrator)` are denied
  from the Orchestrator and from a subagent caller. A bare `orchestrator`
  ref is not denied.
- **G4.** `enabled:false`: `Agent(ah:architect)` and `Agent(ah:orchestrator)`
  pass.
- **G6 (r7 wording), fail closed.** There are two deterministic injections,
  and neither uses a test-only code path in the hook.
  - **(a) A throw after role resolution:** `<hierarchy dir>/msgs` exists as a
    plain file, so the roster read throws ENOTDIR.
    - `Agent(ah:ultra-advisor|architect|reviewer|implementor)` are denied
      with the §2.1.8 role text, and the error is logged.
    - `Task(ah:orchestrator)` gets its **normal** pre-resolution denial
      (`ORCHESTRATOR_REASON`, :161). The Orchestrator check runs before role
      resolution, so the injection never reaches it.
    - `Agent(ah:task-runner)`, `Agent(task-gopher:task-gopher)`,
      `Agent(<custom implement role>)` and a SendMessage pass.
  - **(b) A throw inside config resolution:** the config has
    `roster.members:[null]`, so resolveConfig throws in `rosterMemberNames`.
    - `Task(ah:orchestrator)` gets the exact §2.1.8 Orchestrator text.
    - `Agent(ah:architect)` is denied with the §2.1.8 role text.
    - `Agent(ah:task-runner)` passes.
  - **`enabled:false`** with a readable config and injection (a):
    `Agent(ah:architect)` passes, because of the early return.
- **G7 (r7), padded refs.** `Agent(" ah:architect ")`, with surrounding
  whitespace, is treated exactly like `Agent("ah:architect")` on the
  non-error path: denied by the peer wall. The same holds for
  `" ah:orchestrator "`.
- **G5 (r3).** The `spawnReason` text contains §2.1.6's line "If the command
  fails to launch, follow agent-team's 'When a role can't take the work'."
  It contains no `route subagents` command, and no opt-in or "does not lead
  to the subagent opt-in" text.
- **D1.** The directive, in every golden scenario:
  - contains no "opts in", "route subagents" or "prefer-peers";
  - no chain role renders as an `Agent(` line;
  - legwork lines are unchanged;
  - the Orchestrator line carries the takeover exception;
  - (r2) the peer-brief contract carries the three-ping rule (ping n/3,
    `notify_when_idle`, busy never pinged, leave the pane running);
  - (r2) item 7 carries the ladder pointer;
  - test-directive-size.sh passes with its budget unchanged.
- **K2 (r2).** The agent-team SKILL.md section "When a role can't take the
  work" contains:
  - the design/review/implement ladder, with a physical launch failure as
    the only takeover trigger;
  - the approval table with its four rows (none, off, session, each), the
    `gate.mjs status` read, and the verbatim first-use options;
  - escalation steps 1–4 in order, including "Don't spawn an
    Ultra-Advisor", the step-3 ranking rule, and continuing a stalled
    Ultra-Advisor from step 3;
  - the stall definition (owes a reply and is idle), the per-brief count of
    three that never resets, the response definition, "leave the pane
    running", and "surface a late report";
  - the declined-spawn question.

  These ladders are carried out by the model. The directive and skill text
  are the contract, so acceptance for them is by text check. The Reviewer
  reads the section against §2.2.
- **M1.** A repo-level file with S1–S5 plus an unrelated key, then
  `roster.mjs add …` to that file:
  - each stale key is migrated per §2.3's table;
  - a legwork member that inherited the block's `subagent` now has its own
    `route:"subagent"`;
  - a legwork member's own `route:"subagent"` is kept;
  - legwork `dispatch:"model"` is kept;
  - the unrelated key and the order are preserved;
  - `migrated` lists each change.

  The same holds when the write comes from `edit`, `remove`, `role set` or
  `init`.
- **M1b (r2).** A repo-level file with `teamAlias`, `roster.layout`,
  `rosters.alt.layout` and `teamLayout`, then `roster.mjs add …` to it: all
  four are deleted and listed in `migrated`. A global file's `teamLayout`
  survives a write to the global file.
- **M2.** M1 against the repo file leaves the global file's stale keys
  byte-identical.
- **M3.** With stale keys present:
  - `show`, `status`, `doctor`, `create --plan`, `--dry-run` verbs, and
    every hook (SessionStart, route gate, the others) leave every config
    file byte-identical;
  - `status`, `doctor` and `create --plan` print the S1–S5 warnings;
  - the SessionStart context and the directive contain none of them.
- **M4.** Before any write, an architect member with `route:"subagent"`:
  - `create --plan` shows it peer-routed with a `spawn` shape;
  - `status` shows the effective `peer`;
  - the gate denies its Agent dispatch (G1).
- **M5.** `gates.jsonl` holding a `route subagents` record for session S:
  - `msg.mjs route --session S` prints `peers`;
  - the gate treats S as `peers`;
  - `gates.jsonl` is byte-identical after every verb;
  - `msg.mjs route subagents --session S` exits 2;
  - `route peers` appends.
- **V1.** Each of these exits 2:
  - `init --route subagent`;
  - `add --role architect --route subagent`;
  - `edit` of an architect to `--route subagent`;
  - `edit --role architect` on a subagent-routed task-runner row;
  - `--on-missing never` and `--on-missing prompt`;
  - `role set architect --dispatch model`;
  - `role set <custom implement> --dispatch model`.

  These succeed: `add --role task-runner --route subagent`, and `role set
  <custom legwork> --dispatch model`.
- **T1.** A hand-written team file with an architect `route:"subagent"`
  record: the gate treats it as a missing peer, and `spawn-one architect`
  launches it as a peer.
- **K1.** Text checks:
  - agent-roster init has no "Subagent only" option;
  - hooks.json and comms-protocol.md no longer describe a route question or
    the prefer-peers default;
  - agents/*.md are byte-identical, and every test-directive-size.sh agent
    budget is unchanged (r3);
  - commands/hierarchy.md has no `plugins/cache/*/task-gopher` glob.
- **T-list.** Existing tests that assert the removed opt-ins are updated to
  assert the new denials:
  - test-on-missing.sh (all 19 checks);
  - test-route-wall.sh, test-route-gate.sh, test-custom-roles.sh,
    test-route-gate-subordinate.sh, test-peer-dispatch.sh,
    test-sessionstart-agent.sh, test-roster-cli.sh, test-role-contract.sh;
  - subagent cases in test-roster-{commit,add-spawn,global-gate,multi-team,spawn}.sh.

  The Implementor reports every touched test with a reason. An assertion
  about **legwork** subagent behaviour must not be removed.
  - *(r5)* **Tier-gate tests** that reached the tier rule through an
    `Agent(ah:<chain role>)` dispatch are **moved** to an Orchestrator
    SendMessage peer brief, not deleted. The Agent path now hits the peer
    wall first. Each tier assertion keeps its expectation: a one-shot deny,
    then the re-issue passes.
- **C1.** The full suite is green. The golden diff is limited to §4.

## 6. Rulings (r2) and open questions

**Ruled:**

- **OQ-A.** Paneless means a physical launch failure. The Ultra-Advisor
  escalation follows the user's four-step ladder (§2.2.2). Design, review
  and implement try a pane first, and the Orchestrator takes over only on a
  physical failure (§2.2.1).
- **OQ-B.** Three pings, then take over (§2.2.3). The stalled pane is left
  running and reported; the user did not rule on this, so it is the default.
- **OQ-C.** Confirmed (§2.2.4).
- **OQ-D.** Yes: 0057's stale keys also migrate on CLI writes (§2.3,
  S7–S9).
- **OQ-E.** Not asked, so the baseline stands: `--on-missing` is kept with
  only `auto`.

- **OQ-F — ruled "instruction only".** The approval for §2.2.2 step 3 is
  enforced by the directive and skill text. There is no gate marker and no
  ultra-gate change.
- **S9** (non-global `teamLayout` migrating on write) was confirmed by the
  user.

No open questions remain.

## 7. Decisions made here (overridable)

- The normalization is at read, with one seam. Migration happens in
  `writeLevelFile`.
- Stale warnings reuse `staleTeamKeys`, in the CLI only.
- `gates.jsonl` is made inert through `ROUTE_VALUES`, never rewritten.
- `ah:orchestrator` is matched exactly. A bare `orchestrator` is not.
- Ruling (b) applies only to launch failures, not refusals, legwork skips
  or declined prompts. The exception lasts for the work at hand only.
- *(r2)* Ranking for escalation step 3: model tier; then a live member
  first; then design, review, implement; then roster order.
- *(r2)* Escalation approval is checked once per escalation with
  `gate.mjs status`. The `each` question for steps 3–4 is asked once per
  escalation.
- *(r2)* Stall cadence is driven by `notify_when_idle` events, not timers.
  The count is per brief and never resets, and a gone peer is not a stalled
  one.
- *(r2)* The procedures live in the agent-team skill, and the directive
  holds only pointers, which keeps the size budget.
- The ultra-gate and SubagentStart are left as they are.
- *(r3: r1's "agent descriptions are rewritten away from 'Dispatch it'" is
  withdrawn. agents/*.md are unchanged; see §2.6.)*
- commands/hierarchy.md's cache-glob check is fixed here, carried over from
  0058 §8.

## 8. Not in this spec

- 0060 covers team lifecycle and name hygiene: `dismiss` of the last member
  leaving an owned empty team, and `create --plan` offering names that live
  sessions already hold.
- The spawn-one, spawn-ad-hoc and create asymmetry on subagent-routed
  **legwork** members is left as it is.
- **Follow-up (pre-existing, found in review):** a config with
  `roster.members:[null]` makes `resolveConfig` throw in `rosterMemberNames`,
  so every hook falls into its `catch`. Row validation at read should reject
  or skip non-object members, with a warning.
  - **G6 (b) uses this crash as its injection.** Whoever fixes it must, in
    the same change, either supply another deterministic throw inside config
    resolution for G6 (b), or drop that half of G6.
- **Follow-up (pre-existing, found in review):** these tests fail when
  `CLAUDE_PID` is absent, which is a test-hermeticity gap:
  - test-custom-roles.sh T1 and T13 (and T16 on base);
  - test-role-contract.sh C10 (×2) and C16;
  - the roster-layout-splits invariant;
  - test-roster-surface-split.sh 7.
