# 0042 — Mechanical gate: the agent-roster skill must be consulted before standing up a Team

Status: r2, ready for Implementor. Not implemented. Author: Architect.
r2 changes: E2/E3 resolved (dual-prefix rule §1.3), §1.6 folds in the inert
disband-close gate, §1.4 pre-specifies both E1 branches, §1.5 ships and §1.2 is
in scope per user decision, E4 added.
Precedent: 0041 (mechanical
detection over careful prose), 0016/0020 (`pretooluse-disband-close-gate.mjs`
as the exact-name MCP gate pattern).

## Requirement (from the Orchestrator's brief)

Orchestrators keep failing to load `ah:agent-roster` when they need to spawn
peer agents/teammates, and go straight to Agent/SendMessage dispatch or raw
roster MCP calls instead. Prose reminders have not stuck. Fix mechanically.
Deny-with-instructions, never a silent block. Cover both entry points: the
`Agent` tool and the roster MCP tools.

## 0. Findings that shape the design

**F1 — The injected SessionStart directive never names the skill.**
`grep 'Skill' agent-hierarchy/hooks/*.mjs hooks.json` returns exactly one hit:
`lib-config.mjs:906`, the generic "Skills and commands override" line. The
roster/route protocol item (`lib-config.mjs` `protocolItems1214`, item 13) talks
about `peers.jsonl`, route values, and the route CLI, and `peerConfirmationParagraph`
walks the orchestrator through resolving a peer *name* by hand — but the string
`agent-roster` appears nowhere in what a session is actually told at runtime.
So the root cause is not "buried prose". The skill is **absent** from the
runtime directive. An orchestrator that follows the injected protocol perfectly
still never learns the skill exists.

**F2 — Every mutating roster MCP tool is ungated.**
`hooks.json` registers PreToolUse on exactly three matchers: `Agent|Task|SendMessage`
(ultra/msg/sendmessage-response/route gates), `mcp__ah__roster_disband_close|mcp__ah__roster_dismiss_close`
(destructive close), and `AskUserQuestion|ExitPlanMode|SendUserFile|PushNotification`
(conduit). `mcp__ah__roster_create`, `roster_spawn_one`, `roster_adopt`,
`roster_config`, `roster_move`, `roster_dismiss`, `roster_disband` reach the
server with no hook in front of them. An orchestrator can stand up, reshape, or
tear down a Team without anything ever referencing the procedure the skill
encodes (levels, layout splits, the `team.json` check-in registry, relocation).

**F3 — The reported symptom is a non-action, and PreToolUse cannot fire on one.**
"Went straight to Agent dispatch instead of setting up a team" produces no
roster tool call to intercept. The only observable events are (a) the Agent/Task/
SendMessage dispatch that happened instead, and (b) the user's prompt that asked
for a team. Gating (a) broadly is unacceptable: subagent dispatch is the
protocol-mandated path whenever route is `subagents`, and a gate that fires on
ordinary dispatch trains the user to blanket-allow — the failure mode
`pretooluse-disband-close-gate.mjs`'s header comment already warns about.

**F4 — There is already a once-per-session ask on the dispatch path.**
`pretooluse-route-gate.mjs` (417 lines, matcher `Agent|Task|SendMessage`) already
denies/asks once per session on the roster roles to settle the dispatch route,
recording `{type:"route-ask", session_id}` via `appendGate`. That existing,
already-paid-for interruption is the correct carrier for a pointer to the skill —
it costs zero additional prompts.

**F5 — Gate state is trivial and append-only.** `lib-hier.mjs`: `gatesPath(dir)`
= `<hierarchyDir>/gates.jsonl`; `appendGate(dir, rec)` stamps `ts` and appends;
`hasGate(dir, pred)` scans. Records are free-form objects keyed by convention on
`type` + `session_id`. Any new gate uses this, not a new store.

**F6 — No hook currently observes the `Skill` tool** (F1's grep). Whether a
`Skill` invocation even surfaces as a PreToolUse event with `tool_name: "Skill"`
is unverified in this repo. See NEEDS-EVIDENCE E1.

## 1. Design

Three layers, cheapest first. Layers 1.1 and 1.2 are required; 1.3 is the
mechanical core; 1.4 is conditional on E1; 1.5 is optional and flagged.

### 1.1 Name the skill in the injected directive (necessary, not sufficient)

`lib-config.mjs` must state, in the roster/route protocol item, that standing up,
reshaping, or tearing down a live Team goes through the `ah:agent-roster` skill —
naming it in the exact form an orchestrator can invoke (`Skill(skill:"ah:agent-roster")`,
or `/agent-roster`), and saying which operations it owns: create/spawn a Team,
spawn or dismiss one member, add/edit/remove a roster role, disband, resync/move.
It must also say what the skill is *not* for: a one-off subagent dispatch of a
role is ordinary protocol and needs no skill.

This is prose and prose is what failed — it is included because the gates below
tell the orchestrator to invoke something it must already know exists, and
because F1 means the current absence is a real defect independent of any gate.

**Must not change:** the existing role lines, `peerConfirmationParagraph`, and
protocol items 12/14 keep their current meaning and wording. This adds; it does
not rewrite.

### 1.2 Point at the skill from the ask the orchestrator already sees

The route-gate's one-per-session ask (F4) must carry one additional sentence
naming the skill as the path for "I need live peers that do not exist yet". No
new prompt, no new denial, no change to the route gate's own trigger, decision
values, or recorded gate types.

### 1.3 Hard gate on the mutating roster MCP tools (the mechanical core)

A new PreToolUse hook, registered in `hooks.json` under its own matcher, modeled
structurally on `pretooluse-disband-close-gate.mjs`.

**Gated verbs:** `roster_create`, `roster_spawn_one`, `roster_adopt`,
`roster_move`, `roster_dismiss`, `roster_disband`.

**Gated tool names — BOTH prefixes, exact names, no wildcard matching (r2, resolves E2).**
Each gated verb must be enumerated under *both* `mcp__plugin_ah_ah__<verb>` and
`mcp__ah__<verb>`. The live name depends on how the server is installed: a
plugin-supplied MCP server surfaces to the model as
`mcp__plugin_<plugin>_<server>__<verb>` — confirmed for this plugin as
`mcp__plugin_ah_ah__roster_create` etc. — while the same server configured
directly in a `.mcp.json` as `ah` would surface as `mcp__ah__<verb>`. Both
install shapes are plausible across users, the cost of listing both is one extra
string per verb, and the cost of picking wrong is a gate that never fires and
still passes its own tests. Enumerate both; do not try to detect which is live.

`mcp__plugin_ah_ah__` is the shape *this* repo has been observed to use, so it is
the one that must be present if only one somehow survives review.

**Not gated:** `roster_show`, `roster_teams`, `roster_history`, `roster_member`,
`roster_reap`, `roster_resync`, `roster_layout_splits`, `roster_disband_close`,
`roster_dismiss_close`, and every `msg_*` tool. Rationale: read-only inspection
must stay frictionless (the MCP server's own instructions push callers toward
`roster_show`), and the two `*_close` tools already have their own always-ask
destructive gate — stacking a second prompt on them is the "train the user to
blanket-allow" failure.

`roster_config` is **excluded** from the gated set — see §6.

As with the disband-close gate, the exact-name set lives in two load-bearing
places (the hook body and the `hooks.json` matcher); a tool present in one and
absent from the other is a silent hole. The implementation must keep them in
lockstep and the test must assert the two agree.

**Trigger condition.** Deny when *all* hold:
1. `tool_name` is in the gated set;
2. the session has no `roster-skill-gate` record in `gates.jsonl` (F5);
3. the session has no skill-invoked marker for `ah:agent-roster` (§1.4; if E1
   resolves negative this clause is simply absent and the gate is
   unconditional-once).

Otherwise allow (exit 0, no output).

**Behavior on deny.** Emit the deny-with-instructions payload in the shape
`pretooluse-route-gate.mjs` already produces (`hookSpecificOutput` with
`permissionDecision: "deny"` plus `permissionDecisionReason`). The reason text
must state, in this order:

- the call was BLOCKED and did not run;
- that Team lifecycle operations are owned by the `ah:agent-roster` skill,
  which encodes the roster levels, spawn layout, `team.json` check-in registry,
  and relocation rules that a raw tool call skips;
- the exact invocation to run (`Skill` with `skill: "ah:agent-roster"`), and that
  the skill may resolve the request differently than the tool call the
  orchestrator was about to make — it must follow the skill, not resume the
  original call by reflex;
- that re-issuing the identical call after consulting the skill will proceed,
  because this gate is one-shot per session.

**Idempotence / self-clearing.** The hook records `{type: "roster-skill-gate",
session_id}` via `appendGate` **at deny time**, so the immediate retry proceeds
whether or not the orchestrator actually invoked the skill. This is deliberate:
the gate's job is to make the skill unmissable once, not to police compliance.
A gate that can be re-entered indefinitely would deadlock any session where the
skill genuinely does not apply.

**Subagent context.** The gate must not fire inside subagent sessions — only a
session acting as the orchestrator stands up Teams, and the route gate already
establishes the precedent of exiting early in subagent context. Reuse whatever
`lib-hier`/`lib-session-role` predicate the route gate uses; do not invent a new
detection.

**Failure mode.** Fail *open* (exit 0, allow) on any parse or state-read error.
This is the opposite of the disband-close gate's fail-closed choice, and the
difference is intentional: that gate protects against irreversible session
destruction, this one protects against a procedural miss. A crashing hook must
never make roster operations unusable.

### 1.4 Skill-invocation marker (conditional on E1)

If a `Skill` tool invocation is observable via PreToolUse, a marker hook records
`{type: "skill-invoked", session_id, skill}` when the invoked skill is
`ah:agent-roster`, and §1.3's trigger clause 3 consults it. Effect: an
orchestrator that did the right thing never sees a denial at all — the gate is
invisible on the correct path and only bites on the wrong one. This is the
property that makes the gate cheap enough to keep.

**E1 is not left to the Implementor's judgment (r2).** The order is fixed:

1. Before writing any of §1.4, run the E1 probe (§5, E1) as the first step of
   implementation.
2. **If the probe shows a `Skill` invocation reaches PreToolUse with an
   identifiable skill name:** implement §1.4 — the marker hook, its `hooks.json`
   registration, trigger clause 3 in §1.3, and test assertion 7.
3. **If it does not** (no event, no usable matcher, or no way to tell which skill
   was invoked): implement none of §1.4. Do not create the marker hook, do not
   add trigger clause 3, do not add test assertion 7, and do not substitute an
   alternative detection mechanism. Ship §1.3 as an unconditional one-shot gate,
   record the probe's result in the spec (§5, E1) as an amendment, and report it.

Either branch is a complete, shippable result. Nothing else in this spec depends
on E1, so it never blocks §1.1, §1.2, §1.3, or §1.5.

### 1.5 Prompt-intent nudge (r2: SHIPPING — user decided)

`userpromptsubmit-peer-tracking.mjs` already runs on every user prompt. It could
additionally detect team-intent phrasing and inject a single line naming the
skill. The phrase set should be taken from the skill's own frontmatter
`description` (it already enumerates "set up my team", "add a reviewer peer",
"spawn the team", "spawn the architect", "spawn just the reviewer", "disband the
team") rather than invented here — one source of truth.

This is the only layer that addresses F3's non-action directly. It is also the
only one with a false-positive cost, and keyword matching on natural language is
inherently brittle. Cost of a false positive is one injected line; cost of a
false negative is the status quo.

**r2 — the user decided to ship this alongside §1.1–1.4** (the Architect's r1
lean was to defer; overridden, and the override is the user's call to make).
Two constraints follow from shipping it:

- The injected line is **one line**, and it points at the skill. It does not
  restate the protocol, does not instruct, and does not fire more than once per
  prompt.
- The phrase set is read from `skills/agent-roster/SKILL.md`'s frontmatter
  `description`, not hardcoded a second time in the hook. If reading the skill
  file at hook time is impractical, the hook may carry the list, but the test
  must assert it matches what the SKILL.md description contains — two copies
  that nothing reconciles will drift.

### 1.6 Fold-in: the existing disband-close gate is inert (r2, new finding)

While resolving E2, the Orchestrator found the already-shipped gate uses the
short prefix: `hooks.json:38` matcher `mcp__ah__roster_disband_close|mcp__ah__roster_dismiss_close`,
and `pretooluse-disband-close-gate.mjs:27` `GATED_TOOLS`, plus its `:47`
comparison against `mcp__ah__roster_dismiss_close`. If the live tool name is
`mcp__plugin_ah_ah__*`, that gate has never fired — meaning the destructive
"close live sessions" confirmation prompt from specs 0016 §4.5.1 and 0020 §4.1
is not actually in place, despite its tests passing.

**This fix lives in 0042, not a separate spec.** Same root cause, same two files,
same test gap, and it is the identical one-line-per-name change the new gate
already requires. Splitting it would ship a corrected new gate next to an
uncorrected old one whose failure is more consequential.

**Requirement:** `pretooluse-disband-close-gate.mjs` and its `hooks.json` matcher
must each enumerate **both** prefixes for both close verbs, per §1.3's dual-prefix
rule. The `:47` single-name comparison that selects the single-member path must
accept either prefix for `roster_dismiss_close`; getting that one wrong degrades
the prompt to the generic wording rather than breaking it, but it must still be
right.

**Must not change** about that gate: it stays always-ask (no caching, no
allowlist, no one-shot), it stays fail-closed, and its prompt text is unchanged.
This is a name fix only. Do not "harmonize" it with the new gate's one-shot,
fail-open behavior — the two gates protect against different things and the
difference is deliberate (§1.3, §6).

**Its existing test** `tests/test-disband-close-gate.sh` currently passes against
the wrong literal, which is how this survived. It must be extended by the same
name-agreement assertion §4 item 4 requires, and must exercise the live-shape
`mcp__plugin_ah_ah__` names explicitly.

## 2. Files to change

- `agent-hierarchy/hooks/lib-config.mjs` — §1.1 directive text.
- `agent-hierarchy/hooks/pretooluse-route-gate.mjs` — §1.2, one sentence in the
  existing ask reason. No logic change.
- `agent-hierarchy/hooks/pretooluse-roster-skill-gate.mjs` — new, §1.3.
- `agent-hierarchy/hooks/hooks.json` — new PreToolUse entry with the exact-name
  matcher for §1.3; plus, if E1 is positive, a `Skill` matcher for §1.4.
- `agent-hierarchy/hooks/pretooluse-skill-marker.mjs` — new, only if E1 positive.
  May instead be folded into an existing hook if one already fires on a matcher
  that can be widened cheaply; the Implementor decides, given E1's result.
- `agent-hierarchy/hooks/userpromptsubmit-peer-tracking.mjs` — §1.5 (r2: shipping).
- `agent-hierarchy/hooks/pretooluse-disband-close-gate.mjs` — §1.6, name fix only.
- `agent-hierarchy/tests/test-disband-close-gate.sh` — §1.6, extended assertions.
- `agent-hierarchy/tests/test-roster-skill-gate.sh` — new, §4.
- `agent-hierarchy/skills/agent-roster/SKILL.md` — no behavioral change required.
  If the deny text quotes any invocation form, it must match what this file's
  frontmatter `name` supports.
- Version bump in **both** `agent-hierarchy/.claude-plugin/plugin.json` and the
  repo-root `.claude-plugin/marketplace.json` (both currently 0.65.0 — they must
  move together).

## 3. Must not change

- The route gate's trigger, decision values, recorded gate types, or its
  one-shot-per-role-per-session semantics.
- The disband-close/dismiss-close gates: still always-ask, still fail-closed,
  still unstacked with any other prompt.
- Existing `gates.jsonl` record types and the append-only contract.
- Read-only roster MCP tools stay ungated.
- Protocol items 12 and 14, `peerConfirmationParagraph`, and the role lines keep
  their current semantics.
- No change to how peers are actually spawned — this spec adds a gate in front
  of the existing mechanism and changes nothing downstream of it.

## 4. Verification

New `tests/test-roster-skill-gate.sh`, following the existing shell-test
conventions (see `test-disband-close-gate.sh`, `test-route-gate.sh`,
`test-ultra-gate.sh` for the harness shape). It must assert:

1. Each gated tool name — **under both prefixes** — called with a clean
   `gates.jsonl`, produces `permissionDecision: "deny"` and a reason mentioning
   the skill by name.
2. The same call immediately repeated produces no deny (the gate self-cleared).
3. Each explicitly-not-gated tool from §1.3 produces no output at all.
4. The hook's gated-name set and the `hooks.json` matcher enumerate the same
   tools — a name in one and not the other fails the test. This assertion is
   **generic and applied to every PreToolUse gate that enumerates MCP tool
   names**, not just the new one; §1.6's gate must be covered by it too. It must
   additionally assert that every enumerated verb appears under both prefixes.
   (This is the exact hole that made the disband-close gate inert while its own
   tests passed; assert it, don't trust it.)
5. In subagent context, no gated tool produces a deny.
6. Malformed/unreadable input allows (fail-open), and does not throw.
7. If §1.4 ships: with a `skill-invoked` marker for `ah:agent-roster` present,
   the first gated call produces no deny.
8. `test-doc-links.sh` still passes with this spec added.
9. §1.5: a prompt containing a team-intent phrase from SKILL.md's description
   injects exactly one line naming the skill; an unrelated prompt injects
   nothing; and the hook's phrase list matches SKILL.md's description.
10. §1.6: `test-disband-close-gate.sh` asserts `ask` for both close verbs under
    **both** prefixes, and that the single-member path (naming the member) is
    selected for `roster_dismiss_close` under either prefix.

Release chore: version bump in the two files named in §2, per this repo's
established two-place rule.

## 5. NEEDS-EVIDENCE (for the Orchestrator to route; none blocks starting §1.1–1.3)

- **E1 — RESOLVED (Implementor, negative).** Registered a throwaway PreToolUse
  hook on matcher `Skill` (a temporary entry in hooks.json pointing at a
  logging script) that appended raw stdin to a log file, then invoked
  `ponytail:ponytail-help` (a harmless one-shot skill) both from the live
  session and from a freshly-spawned subagent. No log entry was produced
  either time — no PreToolUse event reached the matcher at all. The probe's
  own plumbing is not in question: the identical `"${CLAUDE_PLUGIN_ROOT}"`
  command pattern is what the ultra/route/msg gates use on `Agent|Task|
  SendMessage`, and those verifiably fire for subagents (they contain
  explicit `isSubagent` early-return branches), so `CLAUDE_PLUGIN_ROOT`
  resolution and hook dispatch are not the failure. Conclusion: a `Skill`
  invocation does not surface as an observable PreToolUse event under this
  repo's Claude Code version — "no event" per §1.4's pre-specified negative
  branch. §1.4 is not implemented: no marker hook, no trigger clause 3, no
  test assertion 7. §1.3 ships as an unconditional one-shot gate. Probe
  artifacts (temporary hooks.json entry and logging script) were removed
  before the real implementation.
- **E2 — RESOLVED (r2).** The live name is `mcp__plugin_ah_ah__<verb>`: this
  plugin's server is registered as `ah` under plugin `ah`, giving the
  `mcp__plugin_<plugin>_<server>__` shape Claude Code uses for plugin-supplied
  MCP servers, and it was confirmed against a live session's tool enumeration.
  The short `mcp__ah__` form the existing gate uses is not what PreToolUse
  receives under this install shape. Design response: enumerate both prefixes
  (§1.3) rather than betting on one, and fix the existing gate (§1.6).
- **E3 — RESOLVED (r2), no hole.** `roster_config` is never called as a
  standalone verb by SKILL.md's documented procedure; it is invoked internally by
  `roster.mjs layout` and `roster.mjs alias`, both of which are only reached from
  inside the skill's own flow. Excluding it from the gate leaves nothing
  unguarded. §1.3's exclusion list stands as written.
- **E4 — NEW (r2), non-blocking: has the disband-close gate actually been inert
  in production, and since when?** The inference (§1.6) is strong but rests on
  the name mismatch, not on an observed missed prompt. *Decides:* nothing about
  the fix — the dual-prefix change in §1.6 is correct either way, which is
  precisely why it was designed not to need this answer. It decides only whether
  a release note should tell users that destructive team-close has been
  unprompted, which is a user-facing disclosure question, not a design one.
  *How:* the E1 probe's payload log answers it incidentally; otherwise ask a user
  who has run a disband whether they were prompted. **Route the disclosure
  question to the user, not to the Implementor.**

## 6. Decisions made / refused

**Made:**
- Root cause is F1 (skill absent from the runtime directive) compounded by F2
  (mutating roster tools ungated) — not "the prose is too weak". This reframes
  the fix: §1.1 is a bug fix, not a doc tweak.
- Gate the MCP mutation surface, not the `Agent` tool. F3: broad Agent gating is
  noise that destroys the value of every other gate in this plugin.
- One-shot per session, recorded at deny time, self-clearing on retry. Matches
  the ultra-gate/route-gate family; avoids any possibility of deadlock.
- Fail open, unlike the disband-close gate. Procedural miss ≠ destructive act.
- `roster_config` excluded from the gated set: it is a settings write, plausibly
  reached outside any Team-lifecycle flow, and gating it risks a denial in a
  context where the skill has nothing to say. Pending E3.
- `roster_show` and friends stay ungated.

**Made in r2:**
- Enumerate **both** MCP name prefixes rather than switching to the newly-confirmed
  one. E2 resolved which shape this install uses, but the shape is a function of
  how the server is installed, not of the code; a spec that hardcodes one shape
  reproduces the same class of bug for a differently-installed user. Listing both
  costs one string per verb.
- Fold the disband-close fix into 0042 (§1.6) rather than splitting it. Same root
  cause, same files, same test gap; splitting risks shipping a correct new gate
  beside a broken old one whose failure is worse.
- Pre-specify both E1 branches (§1.4) so the Implementor never chooses.
- §1.5 ships, per the user. §1.2 is in scope, per the user.

**Refused / routed to the user:**
- Whether to disclose in release notes that destructive team-close may have been
  unprompted since the disband-close gate shipped (E4). That is a user-facing
  disclosure call about an already-shipped defect, not a design call, and it
  should not be decided inside an Implementor pass.

**Settled in r1, no longer open:** §1.5 ship-or-defer, §1.2 scope. Both went to
the user and both came back as the Architect's lean.

## 7. Confidence

High on §1.1–1.3 and §1.6 as the right shape; the findings are direct
observations of the current tree plus a resolved E2. §1.5 ships on the user's
call rather than mine — the keyword heuristic is still the least certain part of
the design, and the constraints in §1.5 (one line, phrase list not duplicated)
exist to bound what a bad match can cost. E1 is the only open branch and both of
its outcomes are pre-specified.

No escalation to Ultra-Advisor recommended. Nothing here is irreversible or a
public interface. §1.6 touches a destructive-operation confirmation, which is the
one place in this spec worth a careful review pass — but the change there is a
string fix under an explicit must-not-change list, not a redesign.
