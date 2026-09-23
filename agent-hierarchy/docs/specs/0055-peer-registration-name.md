# 0055 — Peer liveness by pane attribution; ah dispatch is always a peer

Status: r5, ready for implementation. Target version: agent-hierarchy 0.85.0.

**r5 changes (a spec-defect found in review 20260922-223947-1m1e):**
- §8's test-hygiene rule was overbroad. It now allows a private, sandbox-confined tmux server; the real herdr and the user's tmux server stay forbidden.
- New open item O2 beside O1: cwd drift can hide a role session's identity. Recorded only; no design change.

**r4 changes (rulings on the Implementor gaps in response 20260922-215708-f31c §[4]):**
- G1 (NE1 = no): new B9. Team scope resolves by orchestrator pid when the team file has no session_id.
- G2: agent-contract size ceilings are raised (§8).
- G3: B2's route clauses use the effective route; the per-role opt-ins are independent of the route (B2).
- New: a test-hygiene rule (§8).
- For the record: the PEER BRIEF stall line has been added to §4.8.

**r3 changes (user ruled D5 as "Roles route back via Orchestrator"):**
- Role sessions, peer or subagent, never dispatch ah roles. They route each need back as NEEDS-<ROLE> or NEEDS-EVIDENCE.
- The spec 0026 subordinate `prefer-peers` path is removed.
- The Architect's and Ultra-Advisor's `ah:implementor` gathering path is removed.
- The subagent exemption is narrowed.
- Legwork stays allowed.
- Rewritten: §4 B7/B8, §4.8 audit, §6, §7 (NE3 is dropped), §8 test 18 plus the new tests 19-20.

**r2 changes (user rulings on r1 D1-D4, relayed by the orchestrator 2026-09-22):**
- D1: ah role dispatch is always a peer unless the user explicitly opts in. The r1 roster-aware `prefer-peers` default is gone. The default stays `peers`, and `peers` becomes a wall that carries a spawn command.
- D2: with a roster and no live peer, the answer is spawn-one with no ask. `ON_MISSING_DEFAULT` becomes `"auto"`.
- D3: the peer-name ceremony is dropped. Its replacement line says "else spawn the peer", never "else Agent".
- D4: both global-scope confirm gates (scope A and scope B) are removed, together with their CLI half.
- New in r2:
  - §4.4: who runs the spawn.
  - §4.7: behaviour in subordinate and subagent contexts.
  - §4.8: wording audit.
  - Decision D5 and NE3 for the user.

Part A (bug 1) is unchanged from r1. Parts A, B and C are independent commits.

---

## 0. Evidence gathered (read, not run)

- `.claude/hierarchy/peers.jsonl:357`: the first `ct-architect` (pane `w16:p8`) row has no `name` and no `team`.
- `.claude/hierarchy/peers.jsonl:359`: **the Architect's own row** (pane `w16:p9`, session `683eca62-…`, started about 6 minutes after `ct.json` existed) **also has no `name` and no `team`**. Timing is not the cause.
- `.claude/hierarchy/teams/ct.json`: member `{name:"ct-architect", role:"architect", transport_id:"w16:p9"}`. The team file holds the name↔pane join key.
- `pid == ppid` is deliberate: `sessionstart.mjs:137-138` writes `process.ppid` into both fields. Out of scope.

## 1. Root cause — bug 1 (CONFIRMED from source)

This is not a race. **No SessionStart row ever carries `name`, on any spawn path, at any timing.** That is by design:

- `hooks/sessionstart.mjs:144-147` never writes `name` (spec 0036). The reason: `rosterKey` (`lib-hier.mjs:753-755`) is `name || session_id`, and a name on up-rows would merge them with `posttooluse-roster.mjs`'s name-keyed `seen`/`briefed` rows.
- `hooks/sessionstart.mjs:118-127`: spec 0044 §1.6 chose **read-time attribution**, matching the session's pane against team member rows after `writeTeam` lands. Only `roster teams` and `checkin` implement it.
- **The defect: the liveness readers were never converted to read-time attribution.** They join only by `rec.name`, a field that only `seen`/`briefed` rows carry:
  - `hooks/roster.mjs:1777-1779` `memberIsLive`. A never-briefed peer is never live. A briefed one reads live for `ROSTER_FRESH_SEC` (1800 s, `lib-hier.mjs:38`), then reads dead while its pid is alive.
  - `hooks/lib-hier.mjs:831-835` `livePeerSlots`: a nameless row becomes `role@sid8` and falls out of team scope. This produces `sources.peers.live:0` (`roster.mjs:1981`) and a false `untracked_live` entry (`roster.mjs:2038-2041`).
  - `hooks/lib-hier.mjs:872-884` `roster()`: a nameless row is only ever `unattributed` or a default-team `role@sid8` instance. It feeds the route gate's live list and the state block.

About the timing hypothesis: it explains only the missing `team` tag. `sessionstart.mjs:128`'s role scan runs before `spawnOneCore`'s `writeTeam`. After Part A the tag no longer matters.

**Blast radius.** Every `memberLiveness` caller is affected: `roster.mjs:608`, `:658`, `:677` `liveField`, `:686`, `:2122`, `:2250`, `:2285/:2289/:2311` (the spawn-one already-live refusal, which lets a duplicate herdr-unique agent start), and `:3188`. So are `livePeerSlots` users (`sourcesField`, `untrackedLive`, dismiss and disband fallback) and `roster()` users (the route gate and the state block). `create --spawn`, `spawn-one` and `spawn-ad-hoc` all produce the same nameless rows.

## 2. Root cause — bug 2 (CONFIRMED from source)

- `hooks/pretooluse-route-gate.mjs:368-372`: the route-ask fires on any peer-eligible dispatch with no session route record and no config `route` key. `.claude/agent-hierarchy.json` has `roster.route` but no top-level `route`, and `resolved.route` reads only the top-level key.
- Even when the route is known, `peers` is a one-shot reminder. After one deny or ask, the identical re-issue spawns the subagent (`:379-393` route-deny, `:406-416` on-missing-auto fallthrough, `:420-429` peer-fallback-ask). That contradicts D1.
- The injected directive advertises subagent fallback in several places (§4.8).

---

## 3. Part A — attribute peers.jsonl records to team members by pane at read time (unchanged from r1)

**A1.** One read-time attribution view in `hooks/lib-hier.mjs`, beside `latestRoster`. `memberIsLive` (`roster.mjs`), `livePeerSlots` and `roster()` (`lib-hier.mjs`) all read through it instead of `latestRoster`, with no per-caller copies. `latestRoster` and `rosterKey` stay unchanged: keys are computed on the raw record, and the spec 0036 prohibition stands.

**A2. Attribution.** A record with no `name` and a non-null `pane_id` is attributed to team member M iff:
- `resolveTeamByPane` (`lib-roster.mjs:471`; reuse it, since its unique-or-null contract is exactly what is needed) returns M across all team files; and
- `rec.role === M.role`.

An attributed record behaves for every reader as if `name === M.name`. Membership and team come from the existing name lookup, and a stale `rec.team` tag on it is ignored. Records that do not attribute behave exactly as today, including the `role@sid8` synthesis.

**A3. Collapse per name.** This applies only when at least one pane-attributed record exists for that name. Otherwise the view is byte-identical to today's.
- Representative (liveness, `pid`, `pane_id`, `session_id`, `cwd`, `status`): the pane-attributed record with the latest `ts`. It wins over `seen`/`briefed` freshness.
- `busy` and `task` come from the latest named `seen`/`briefed` row, if one exists.
- Exactly **one** entry per name, so dismiss-by-name (`roster.mjs:1813-1829`) never reports a false "ambiguous".

**A4.** `hooks/sessionend-roster.mjs:27`'s `down` row carries `pane_id`, taken from the `up` record it already looks up (`upRecordFor`), falling back to `HERDR_PANE_ID` and then null. Without it a closed peer keeps reading live on a fresh briefed row.

**A5.** Team files are read once per view computation, not once per record.

**A6.** `memberIsLive`/`memberLiveness` signatures and the three-valued contract are unchanged. The non-claude herdr branch (`roster.mjs:1799`) is untouched.

**Must NOT change:**
- `sessionstart.mjs` never writes `name`. `rosterKey`, `latestRoster`, `upRecordFor`, `whoami`, `checkin`, `resolveTeamByPane` and `attributeSessionTeam` keep their behaviour.
- The named-team isolation in `roster()` (spec 0011 §4) is unchanged.
- tmux members get no attribution, because `sessionstart.mjs:140` records only `HERDR_PANE_ID` (NE2).

**Spawn does not verify check-in (decision).** Blocking on the peer's SessionStart row would add latency and a timeout path to every spawn. After Part A, one `roster.mjs teams` call answers "is it up".

---

## 4. Part B — ah dispatch is always a peer unless the user opted in

The user, verbatim: *"Spawning via ah should always be peer agent/teammates, never a sub-agent unless the user specifically says so."*

### B1. Delete the route question
- Remove the route-ask block (`pretooluse-route-gate.mjs:368-374`) and `askReason` (`:119-135`).
- No `route-ask` record is written. Old records are inert.
- `effectiveRoute` (`lib-hier.mjs:682-686`) is **unchanged**: session record, then config `route`, then default `"peers"`.

### B2. Subagent opt-in: one predicate, one implementation
A single predicate answers whether role R may be spawned as a subagent in this session. Both the gate (B3) and the directive (§5) consume it, and neither re-derives it. It is true iff any of the following holds:
1. **Session opt-in** (the user said so this session): the effective route's source is `session` and its value is `subagents`, or `prefer-peers` when no free live R peer exists. The user opts in with `node <MSG_CLI> route subagents --session <id>`, or `route prefer-peers` for "peer when free, else subagent". Revoke with `route peers`.
2. **Config opt-in** (the user wrote it): a config `route` key of `subagents`, or `prefer-peers` under the same rule; or `roles.R.dispatch === "model"` **when that value comes from a user-written config level** (`resolved.sources[R] !== "default"`). The built-in default for every peer-eligible role must resolve to peer dispatch. If `lib-config.mjs`'s default resolves any `PEER_ELIGIBLE_ROLES` member to `dispatch:"model"`, change that default.
3. **Roster opt-in** (the user wrote it): the roster member for R has `route: "subagent"`, or has `onMissing: "never"` and no live R peer exists.

`PEER_ELIGIBLE_ROLES` is `["ultra-advisor","architect","reviewer","implementor"]` (`lib-config.mjs:282`). Task-Runner and non-ah agent types are outside all of this and unchanged. The opt-ins govern **only an Orchestrator session**. No opt-in lets a role session or a subagent dispatch an ah role (B7).

**Precedence (r4, G3; this confirms the Implementor's reading).**
- The *route* parts of clauses 1 and 2 read the **effective** route (`effectiveRoute`: session, then config, then default). So a session `route peers` revokes a config `route: subagents` for that session: the most recent explicit say-so wins, as it always has.
- The *per-role* opt-ins are independent of the route and stand under any route: clause 2's user-level `roles.R.dispatch:"model"`, and clause 3's roster `route:"subagent"` / `onMissing:"never"`. They are structural:
  - a `route:"subagent"` member has no session to spawn (spawn-ad-hoc refuses that route), so walling it would print a command that cannot work;
  - `onMissing` has always overridden the `peers` default for its member (spec 0021).

### B3. Enforcement for Agent/Task(ah:R), R peer-eligible, in an Orchestrator session (not subordinate, not subagent)
If the B2 predicate is true, the dispatch passes. `prefer-peers` keeps its existing one-shot deny when a free live peer exists. Otherwise it is **denied every time**. This is a wall: the `route-deny` one-shot record is no longer consulted for this path, and the `on-missing-auto` record and fallthrough are removed. The reason is chosen as follows:

| state (live = Part A attribution) | deny reason carries |
|---|---|
| a live R instance exists | `SendMessage "<name>"` (a free one first), with the brief this Agent call carried |
| none live; the roster has a member for R; its `onMissing` is `"auto"` or absent | the exact spawn-one command (§4.4) |
| none live; roster member with **explicit** `onMissing: "prompt"` | today's one-shot peer-fallback ask (`:420-424`), reworded so the spawn-the-peer option is first and Recommended. The subagent option is the user specifically saying so, and today's re-issue-passes behaviour stays for that explicit value only. |
| none live; no roster member for R (or no roster) | the exact spawn-ad-hoc command (§4.4) |

- `ON_MISSING_DEFAULT` (`lib-roster.mjs:88`) becomes `"auto"`.
- The no-usable-roster degrade in the `auto` path (`:401-418`) goes to the spawn-ad-hoc row, never to an ask.
- `ON_MISSING_VALUES` is unchanged.

### B4. Who runs the spawn: the Orchestrator, through its own Bash
The PreToolUse hook never spawns. Launching panes from a hook would sidestep the session's own Bash permission prompts, making the hook a laundering path. It would also race hook timeouts against the pane launch, and fire in dry contexts. The deny reason is the whole instruction and must contain:
1. The exact command, with the absolute `ROSTER_CLI` path, the role, and `--cwd <abs cwd>`:
   - roster member for R: `node "<ROSTER_CLI>" spawn-one <R> --cwd <cwd>`;
   - otherwise: `node "<ROSTER_CLI>" spawn-ad-hoc <R> --cwd <cwd>`, plus `--model <m>` when the denied Agent call carried `model`.
2. "Then SendMessage the `name` the command prints, with the brief you gave this Agent call. The session takes a few seconds to boot: if the name is not in ListAgents yet, wait until it is (`roster.mjs teams` reports it live)."
3. "If the command reports the member already exists or is already live, SendMessage the name it reports." This is the escape hatch against a team-scope mismatch (NE1).
4. "If the command fails (no herdr or tmux, launch error), tell the user and ask whether to opt into subagents: `node "<MSG_CLI>" route subagents --session <id>`. Re-issue this Agent call only after that is recorded; it is denied every time until then."
5. For a roster member whose route is `pane`: "drive it with `herdr agent prompt`, not SendMessage" (the existing `lib-config.mjs:1032` rule).

### B5. D4: remove both global-scope confirm gates and their CLI half
- **Gate:** delete scope A and scope B (`pretooluse-route-gate.mjs:350-362`), `enforceGlobalScope`, `globalScopeAnswer`, and every global-roster and global-config ask, re-ask and deny reason builder. `rosterUsable` (`:157`, `:403`) becomes simply "a roster resolved".
- **Now-dead exemption machinery:** delete `toTeamMember`, `EXEMPT_ROSTER_LEVELS` and `noTeamRecordNote` (`:296-341`) where they only served the removed gates. The team-member role lookup (`teamMemberByName` → `role`) stays.
- **msg.mjs:** delete the `global-scope` verb (`msg.mjs:295-306`, the usage string at `:308`, and the header at `:18`).
- **CLI half:** `requireAllowGlobal` (`roster.mjs:1701-1709`) exists only so a Bash subprocess cannot launder around scope A. With scope A gone it must not refuse. `--allow-global` stays **accepted as a no-op** in every flag set, so existing `next` strings and docs do not break, and `closeCommand` (`roster.mjs:2090`) stops appending it.
- `roster_level` is still written to team files; nothing in the gate reads it any more.

### B6. SendMessage peer briefs
- From an Orchestrator: unchanged, except that the scope A/B confirms are gone.
- From a role session or subagent: denied by B7.
- Under an explicit `subagents` route, the existing one-shot SendMessage deny stays.

### B7. Role sessions and subagents never dispatch ah roles; they route the need back (D5, r3)
The user's ruling: "Roles route back via Orchestrator." Only an Orchestrator session dispatches ah roles.

**Who counts as what.**
- A **role session** is a subordinate peer session. It is identified by `isSubordinateSession` (`pretooluse-route-gate.mjs:288-289`: the session's own `up` row carries a role other than `orchestrator`), and that determination is unchanged.
- A **subagent** is any hook input with `agent_id` (`isSubagent`, `lib-config.mjs:367-370`). This covers ah-role subagents and non-ah subagents (general-purpose, Explore…) alike, so the r2 residual gap closes, and it needs no session lookup, so NE3 is moot.

**What is denied, every time (a wall; a one-shot deny would let the re-issue through).** Both of these, whatever the route, opt-in or config:
- an Agent/Task call whose `subagent_type` resolves to a role in `PEER_ELIGIBLE_ROLES`;
- a SendMessage that carries the peer-brief sentinel (`parseSentinel`, `lib-peer.mjs:58`) to a target whose role resolves (existing mechanism, `:309-347`) to a peer-eligible role.

**What passes, unchanged.**
- Legwork. This interpretation is stated explicitly and matches the Orchestrator's read: `ah:task-runner` and every `task-gopher:*` type (including `task-gopher:smart-gopher`) are not teammates. The same goes for non-ah agent types.
- Replies. A role's `[hierarchy-msg <response>]` SendMessage to its Orchestrator carries no brief sentinel and does not target a peer-eligible role, so it passes.
- Everything else a subagent does, which skips the gate as today. The tier gate is not newly applied to subagents.

**Deny text** (the whole instruction; the wording is the Implementor's, the content is required):
- that role sessions and subagents do not dispatch ah roles;
- "route it back to your Orchestrator as **NEEDS-<TARGET ROLE>**", with the role label uppercased and hyphenated (for example `NEEDS-IMPLEMENTOR`, `NEEDS-ULTRA-ADVISOR`), or as **NEEDS-EVIDENCE** when what is needed is a run or a measurement. Say what is needed and why;
- where it goes: for a peer role session, into its report (response file or reply to `reply-to`); for a subagent, into its final report to the session that spawned it;
- that legwork (`task-gopher:*`, `ah:task-runner`) remains available.

**Removed as dead:**
- the spec 0026 subordinate branch (`:375-378`: subordinate means `prefer-peers`);
- every `isSubordinateSession` narration variant (`:407`, `:411-415`, `:421`, `:425-428`). Subordinates never reach route enforcement now.

**Unresolvable self-identity.** With no `session_id`, `selfRole` is null and the session is treated as an Orchestrator (existing, `:279-287`). It therefore gets the B3 wall with a spawn command. This is kept, and the spec 0026 note about the `__nosession__` sentinel still holds.

**Open item O1 (not built).** A role session that has Bash could run `roster.mjs spawn-one`/`spawn-ad-hoc` directly. It cannot brief the spawned peer, because the sentinel send is denied above, so the path is inert. A guard in the ah-CLI PreToolUse hook that refuses spawn verbs from a role session is a follow-up, only if it is ever observed.

**Open item O2 (r5, recorded only; act only if drift is observed).**
- Source: review 20260922-223947-1m1e [4], low confidence, unverified.
- The problem: the gate's self-identity is `upRecordFor(hierarchyDir(cwd), session_id)` (`:288`). A role session whose cwd drifts, for example into a linked worktree with its own hierarchy dir, finds no `up` row there. It then reads as an Orchestrator, so:
  - it gets the B3 wall, which hands it a spawn command;
  - its sentinel briefs escape B7.
- That weakens O1's "inert" argument: a drifted role session with Bash could spawn a peer and then brief it.
- Candidate fix, not adopted: fall back to the per-session role that `sessionstart.mjs:109` already persists (`writeSessionRole`), which is cwd-independent. Spec 0028 §3.7 declared that store deliberately **non-enforcing**, so using it for B7 enforcement reverses a recorded decision. That needs its own ruling, together with evidence that drift actually happens to role sessions.
- Mitigations already in place:
  - the role contracts (§4.8) forbid ah dispatch regardless of what the gate sees;
  - `sessionstart.mjs:158-168`'s misplaced nudge tells a drifted peer to `EnterWorktree` back and `checkin`.

### B8. Must NOT change
- The tier gate (`:441-457`), the ultra gate, the msg gate, the conduit gate and the disband-close gate.
- `subagents` and `prefer-peers` enforcement once explicitly chosen, which applies to Orchestrator sessions only.
- `ON_MISSING_VALUES`, and `"never"`/`"prompt"` when set explicitly.
- A subagent's non-ah and legwork dispatches, and its other tool calls, which still pass the gate untouched.

### B9. An ad-hoc team belongs to the session that spawned it (r4, G1)
**Defect (NE1 = no).**
- `spawn-one`/`spawn-ad-hoc` write `teams/<prefix>.json` with `orchestrator: {session_id: null, pid: <orchestrator pid>}`.
- `resolveTeamScope` (`lib-config.mjs:753-769`) binds a session to a team only by `orchestrator.session_id`. The spawning Orchestrator therefore resolves `team: null`.
- `roster()`'s named-team isolation then hides every member it just spawned. That affects the route gate (the B3 wall re-prints spawn-ad-hoc) and the SessionStart state block after compaction alike.

**Fix, at the shared resolver.** Neither of the two options the Implementor raised is chosen:
- widening only the gate's lookup is a per-caller patch that leaves the state block blind;
- stamping `session_id` at spawn needs the harness to export the session id into Bash, which is unverified (`whoami` already treats `CLAUDE_CODE_SESSION_ID` as possibly absent).

The team file already records the orchestrator pid, so:
- `resolveTeamScope` gains a rung after the session_id rung (rung 2) and before the `null` fallback (rung 3). If no team binds the session id, a team, default or named, **in the same scan order**, whose `orchestrator.session_id` is null or absent and whose `orchestrator.pid` equals the **calling Claude session's pid** is this session's team. First match wins, the same as rung 2.
- "Calling Claude session's pid": in a hook, `process.ppid`, the same value `sessionstart.mjs:137` records as `pid`. In a CLI (`roster.mjs`, `msg.mjs`), the pid is derived the same way spawn-* derives the `orchestrator.pid` it records. A caller that cannot derive a pid skips the rung.
- A team whose `orchestrator.session_id` is non-null is **never** adopted by pid. An exact id always outranks a pid.
- Fail-open is unchanged: any read error degrades to `null`.
- Accepted ceiling: a later, unrelated Claude process that reuses a dead orchestrator's pid would adopt that orchestrator's session-less team. The window is pid reuse against an orphaned team file, so it is rare, and orphan reaping (`teamIsOrphaned`) already exists. The upgrade path is stamping `session_id` once the harness is shown to export it.

**Effect.** Every session-scoped consumer now sees the ad-hoc team: the route gate's `roster()`, the state block, the directive, and `msg.mjs route` queries. Test 17 goes green through this path, not through B4 step 3. B4 step 3 stays as the recovery path for multi-team orchestrators and for CLI callers without a pid.

### 4.8 Wording audit: text that contradicts D1 or D4 must be rewritten
Acceptance: after the change, no injected or documented text tells an Orchestrator to fall back to, offer, or default to a subagent for a peer-eligible role without a B2 opt-in, and none mentions a route question or a global-scope confirm. Found sites:

- `hooks/lib-config.mjs`
  - `:129`: route doc comment. `peers` is the default: no live peer, so spawn one.
  - `:950-971`: `roleLines` and its doc comment (see §5).
  - `:1022`: the null-route text says "will ask". Remove.
  - `:1032`: item 13. Drop "one-shot per role per session" and "A one-off subagent dispatch of a role is ordinary protocol, no skill". State the B3 wall and the B2 opt-in commands.
  - `:1055`: the Roles header ("…else the subagent. No peer target → always the subagent"). Restate as peer-or-spawn, with the subagent only on opt-in. Task-Runner is unchanged.
  - `:1069`: item 0, the handoff gate. The "Peer target but not listed → … offer the subagent-only three" branch becomes "Spawn the <role> peer (Recommended)", "Do it inline", "Skip". The "Dispatch <role> subagent instead" option appears only when B2 is true.
  - `:1162-1170`: the roster display's onMissing/fallback wording, to match the new default `auto`.
  - (r4, recorded) The PEER BRIEF stall line (around `:1062`, "dispatch the role's subagent") also violated the acceptance criterion. The Implementor has already rewritten it. It is in scope.
- `agents/orchestrator.md`
  - `:67`: "A gate will stop you once if you spawn a subagent past a live peer." Restate as B3: every ah-role Agent call is denied unless the user opted in, and the deny carries the spawn command.
  - `:17`: check the "fallback)" sentence in context.
- `skills/agent-team/SKILL.md`
  - `:41-42`, `:795`: drop the route-question and global-scope mentions.
  - `:111`, `:645-653`: `--allow-global` "required" and "the PreToolUse global-scope confirm gate still applies". Restate as an accepted no-op; no confirm.
  - `:656-662`: "Fallback ordering when route is peers and no live peer…one-off subagent instead". Replace with the B3 table.
- `skills/agent-roster/SKILL.md:208-215`: the onMissing default becomes `auto`, and "never bypasses the global-scope confirm gate" goes.
- `skills/autonomous-pipeline/SKILL.md:62,76`: the route description must say `peers` is the default without asking, with the others only as opt-ins.
- `README.md:302-310`: the route section: "reminder gate — the re-issue passes" becomes the wall; the default is spawn-the-peer.
- `docs/cli-tools.md`
  - `:131,133,135,137`: `--allow-global` becomes an accepted no-op.
  - `:143`: route preference, now the opt-in command.
  - `:144`: the global-scope row. Delete.
  - `:122-123`: `--on-missing` default `auto`.

**r3: role contracts (B7).** None of these may tell a role to dispatch an ah role. Each states the route-back rule and keeps legwork.
- `agents/architect.md`
  - `:58` (the `ah:implementor` "when the gathering needs some reasoning" clause) and `:90-104` (the "Delegate READ-ONLY retrieval" bullet, "dispatch `ah:implementor` instead"): reasoning-light gathering goes to `task-gopher:smart-gopher`, which is legwork. When task-gopher is not installed, route it back as NEEDS-IMPLEMENTOR. Mechanical gathering is unchanged (`task-gopher:task-gopher`, else `ah:task-runner`).
  - `:104`: "Never dispatch ultra-advisor, architect, or reviewer" becomes all four ah roles, plus the NEEDS-<ROLE> route-back.
- `agents/ultra-advisor.md:32`, `:60-67`: the same change as the architect (its `ah:implementor` legwork path becomes `task-gopher:smart-gopher`, or NEEDS-IMPLEMENTOR). The "Never dispatch…" line covers all four roles.
- `agents/implementor.md:43`, `agents/reviewer.md:61`: already "never dispatch" all role agents. Add the NEEDS-<ROLE> route-back sentence so the deny text and the contract agree.
- `hooks/lib-config.mjs:1105-1114` `buildRoleSessionNotice`: add one sentence. It says role sessions do not dispatch ah roles, that any need goes back to the Orchestrator as NEEDS-<ROLE>/NEEDS-EVIDENCE, and that legwork (`task-gopher:*`, `ah:task-runner`) is allowed.
- Skills: a grep for "subordinate" in `skills/` found nothing. The Implementor also greps `skills/` for `ah:(implementor|architect|reviewer|ultra-advisor)` in any passage where a *role* (not the Orchestrator) dispatches, and fixes each one.

The Implementor re-greps before finishing (`fall ?back|subagent instead|one-off subagent|route question|global-scope|allow-global|on-?missing|subordinate` across `hooks/lib-config.mjs agents/ skills/ docs/ README.md`) and fixes any site this list missed.

---

## 5. Part C — drop the peer-name confirmation ceremony (D3)

- Delete the `peer:"auto"` special case at `lib-config.mjs:962-964`, `peerConfirmationParagraph` (`:1002-1012`), and the code that appends it.
- `roleLines`, for a peer-eligible role where B2 is false, renders one line with:
  1. the SendMessage target: the configured peer name(s) when `entry.peer` is an explicit name or list (`resolvedPeerTargets`, `:319-325`); otherwise "its live teammate (names: `ListAgents` / `roster.mjs teams`)";
  2. "none live → `node "<ROSTER_CLI>" spawn-one <role> --cwd <cwd>`" when the resolved roster has a member for the role, else "`… spawn-ad-hoc <role> --cwd <cwd>`", then "SendMessage the name it prints";
  3. "Subagent only if the user opts in: `node "<MSG_CLI>" route subagents --session <id>`".
- The line must **not** contain "else Agent" or "else the subagent".
- Where B2 is true for the role (config `dispatch:"model"` from a user level, or a roster `route:"subagent"` member), it renders the `Agent(...)` call as today.
- Non-peer-eligible roles are unchanged.

---

## 6. Decisions

**Made (r1, kept):**
- Read-time pane attribution rather than a launch-time name or a late re-stamp. A launch-time name repartitions `rosterKey`, which is the spec 0036 hazard. A late re-stamp races the peer's boot.
- A3's pane-wins rule.
- No check-in wait in spawn.

**Made (r2):**
- The hook never spawns; the deny carries the command (B4).
- The wall is permanent under `peers` (B3). One-shot would let the re-issue spawn a subagent, which violates D1.
- Explicit `onMissing:"prompt"` keeps its ask. Only the default changes (D2 says drop it "as the default path").
- `--allow-global` becomes a no-op rather than an error, so existing command strings still run.
- `roles.R.dispatch:"model"` from a user-written level counts as an opt-in.

**Ruled by the user:**
- D1-D4 (see the header).
- D5 (r3): roles route back via the Orchestrator. That overrides r2's recommendation to keep spec 0026.

**Made (r3):**
- The wall is keyed on "role session or subagent", not on the subagent's own type. That closes the non-ah-subagent path and needs no NE3 evidence.
- Legwork (`ah:task-runner`, `task-gopher:*`) stays allowed. This agrees with the Orchestrator's read.
- The Architect and Ultra-Advisor's reasoning-light gathering moves to `task-gopher:smart-gopher`.
- The role-session spawn-CLI guard is left as O1.

**Still for the user:** none.

## 7. NEEDS-EVIDENCE

- **NE1: answered "no" by the Implementor (r4). Fixed by B9.** Original question, kept for the record: In the Orchestrator session that owns team `ct`, what does `resolveConfig(cwd,{sessionId}).team` return? Does `roster()` then see members that `spawn-one`/`spawn-ad-hoc` wrote under their default team for that cwd?
  - If yes: B3 briefs the live peer.
  - If no: B3 prints a spawn command, the spawn refuses with "already exists/live", and B4 step 3 recovers. The flow is correct but costs one round trip. The follow-up fix is to have the gate's live lookup include the team scope the spawn commands default to.
  - Test 17 encodes the intended outcome. If it fails for this reason, the Implementor reports it as a spec gap rather than choosing a fix.
- **NE2.** tmux: what does a member's `transport_id` hold, and is `TMUX_PANE` present at SessionStart? This decides a follow-up that records `pane_id: HERDR_PANE_ID || TMUX_PANE`.
- ~~NE3~~ is dropped in r3. The subagent rule in B7 is unconditional, so it needs no session lookup.

## 8. Verification — every test must FAIL on current code first (prove it before the fix)

Harness: model it on `tests/test-roster-spawn-one.sh`: sandbox, `HOME` and `AGENT_HIERARCHY_DIR` redirect, the fake herdr stub with a call counter, hand-written `peers.jsonl` and team files, and a live `sleep` pid killed at exit alongside a reaped dead pid.

**Part A (new test file; unchanged from r1):**
1. Nameless up row on the member's pane with a live pid: `spawn-one` gives `already live` and zero launches.
2. `teams` shows the member live, and `untracked_live` lacks `role@sid8`. The dismiss plan shows `live:true` and `sources.peers.live == 1`.
3. Dead pid: not live.
4. Role mismatch, or a pane present in two team files: not attributed.
5. Pane up row plus a fresh `briefed` row: one slot, dismiss-by-name is not ambiguous, and `busy`/`task` are borrowed.
6. Pane-attributed `down` row plus a fresh `briefed` row: not live. The SessionEnd down row carries `pane_id`.
7. Default-team fixture: `Agent(ah:architect)` is denied, naming the attributed member.

**Part B:** rewrite every existing case that asserts a route-ask, a one-shot `peers` pass-through, a default-`prompt` ask, `on-missing-auto` fallthrough, a global-scope ask or answer, or a `requireAllowGlobal` refusal. Find them with `grep -rlE "route-ask|peer-fallback-ask|on-missing-auto|global-scope|allow-global|onMissing|on-missing" agent-hierarchy/tests`; known files are `test-route-gate.sh`, `test-route-gate-subordinate.sh`, `test-roster-global-gate.sh` and `test-on-missing.sh`.

8. No roster, no route, none live: `Agent(ah:architect)` is denied with the spawn-ad-hoc command (absolute path, `--cwd`, and `--model` when given). The **identical re-issue is denied again**. No `route-ask` record exists.
9. Roster with an architect member and no `onMissing`, none live: denied every time with the spawn-one command, and no AskUserQuestion text. With a live one: denied every time naming it.
10. Roster without an architect member: the spawn-ad-hoc command.
11. Each opt-in passes:
    - session `route subagents`;
    - session `route prefer-peers` with none free;
    - config `route: "subagents"`;
    - user-level `roles.architect.dispatch: "model"`;
    - roster member `route: "subagent"`;
    - `onMissing: "never"` with none live.

    The built-in default config does **not** pass.
12. The SessionStart directive (Orchestrator branch) contains none of "will ask", "choose this session's dispatch route", "one-shot per role", "else the subagent" or "one-off subagent dispatch" for a peer-eligible role, and it does contain the spawn command form.
13. Part C: a `peer:"auto"` role's directive has no "PEER NAME CONFIRMATION" and no "not yet confirmed", renders the §5 line, and has no "else Agent".
14. Explicit `onMissing: "prompt"`, none live: asks once, with spawn-the-peer first and Recommended. The re-issue passes.
15. D4, global roster (fake-HOME global config): no global-roster ask on Agent or SendMessage. `spawn-one --dry-run` against the global roster succeeds **without** `--allow-global`, and still accepts the flag. `closeCommand` output has no `--allow-global`.
16. D4, user-scope role config (the old scope B trigger): no "USER-scope config" ask. `msg.mjs global-scope …` exits with the usage error.
17. NE1 flow, no roster: in an Orchestrator session, run `spawn-ad-hoc architect` (fake herdr), hand-write the peer's up row on the returned pane, then `Agent(ah:architect)`. It must be denied naming the spawned member (SendMessage), not with a spawn command.
18. Subordinate denied, legwork allowed. This replaces r2's "subordinate unchanged" case. Rewrite `tests/test-route-gate-subordinate.sh` to cover it, and drop its route-ask and `prefer-peers` expectations. The fixture is a session whose own `up` row has `role: "architect"`.
    - `Agent(ah:implementor)` is denied with route-back text containing `NEEDS-IMPLEMENTOR`. The **identical re-issue is denied again**, and so is the same call with `msg.mjs route subagents` recorded for that session.
    - `Agent(ah:task-runner)`, `Agent(task-gopher:task-gopher)` and `Agent(task-gopher:smart-gopher)` are allowed.
    - A sentinel SendMessage brief to a reviewer peer is denied with the route-back text. A `[hierarchy-msg <response>]` SendMessage to the Orchestrator is allowed.
    - No session_id (the `__nosession__` case): treated as an Orchestrator, so the B3 wall with a spawn command applies.
19. Subagent denied, legwork allowed. The payload has `agent_id` set; run it once with `agent_type: "ah:architect"` and once with `agent_type: "general-purpose"`.
    - `Agent(ah:reviewer)` is denied with route-back text that names the final report to the parent, `NEEDS-REVIEWER`.
    - `Agent(ah:task-runner)` and `Agent(task-gopher:smart-gopher)` are allowed.
    - A non-dispatch tool call passes.
20. Contracts. These are grep assertions in a test:
    - `agents/architect.md` and `agents/ultra-advisor.md` contain no instruction to dispatch `ah:implementor`;
    - all four `agents/{architect,implementor,reviewer,ultra-advisor}.md` contain the NEEDS-<ROLE> route-back rule;
    - `buildRoleSessionNotice` output contains the route-back and legwork sentence.

    Also check whether `tests/test-conduit-gate.sh` and `tests/test-orchestrator-liveness.sh` (both mention "subordinate") assert any subordinate dispatch behaviour. Rewrite them only if they do.

21. (r4, B9) Resolver unit test.
    - A team file with `orchestrator: {session_id: null, pid: P}`, and a hook whose `process.ppid` is P: `resolveConfig(cwd,{sessionId: S}).team` is that team.
    - Another pid: `null`.
    - A team with a non-null, non-matching `session_id` and `pid: P`: not adopted.
    - A team with `session_id: S` beats a session-less team with `pid: P`.
    - On current code the first case is red.

**Directive-size ceilings (r4, G2).** Raise the four agent-contract ceilings in `tests/test-directive-size.sh:54-59` (spec 0045 §9.5):

| contract | ceiling |
|---|---|
| architect | 9600 → **9700** |
| ultra-advisor | 7100 → **7300** |
| reviewer | 6400 → **6500** |
| implementor | 5100 → **5300** |

Orchestrator stays at 7350.
- Rationale: the ceilings guard against *unreviewed* growth. This growth is a user-ruled contract rule (D5 route-back) that must appear in every role contract, and it has been reviewed here. The overage is 67-112 B, about 20-30 tokens, per contract.
- The new values are measured size rounded up to the next 100 B, which is the same tight-guard intent as 0045.
- No existing contract text is trimmed: every candidate sentence is a rule some earlier spec paid for, and 30 tokens does not justify re-litigating one.
- Any comment beside the numbers states the reason in plain words, with no spec reference.

**Test hygiene (r4; amended r5).** Removing the `--allow-global` refusal let a test reach the real herdr. That leak was latent before and is now exposed. Rule: **no test may reach the real herdr or the user's tmux server.**
- Every test that can reach a launch path (`create --spawn`, `spawn-one`, `spawn-ad-hoc`, `move`, `disband --close`, `dismiss --close`) puts a stub `herdr` first on `PATH`; a fail-every-call stub is the default.
- For tmux, the test either stubs it the same way or uses a **private tmux server confined to the sandbox**:
  - its socket lives under the sandbox dir, for example `tmux -S <sandbox>/tmux.sock`, or `TMUX_TMPDIR` pointed at the sandbox;
  - the test starts it itself, and kills it on every exit path with a `trap … EXIT` running `kill-server`.

  A private server is allowed when the test needs real tmux behaviour, for example `tests/test-roster-spawn-cwd.sh` T5's real `pane_current_path`. That file is accepted as-is.
- The test unsets `HERDR_ENV`, `HERDR_PANE_ID`, `TMUX` and `TMUX_PANE` unless it sets them itself, and any value it does set points into the sandbox. An inherited `TMUX` would aim tmux clients at the user's server.
- The Implementor audits every `tests/*.sh` for this, not only `test-team-history.sh`.

Gate: the full `agent-hierarchy/tests/*.sh` suite is green. Bump **both** `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` to 0.85.0.

## 9. Confidence
- Bug 1 root cause and fix: high.
- Bug 2 location: high.
- r2/r3 contract: high. Every product decision is now the user's.
- B9 (r4): high. It rests on hook `process.ppid` being the Claude pid, which `sessionstart.mjs`'s `pid` and all pid-based liveness already depend on. It also rests on spawn-* recording the same pid (`ct.json` `orchestrator.pid` 62782 matches the Orchestrator's socket `62782.sock`).
- Risks for the Implementor:
  - A3 collapse: keep names with no pane-attributed row byte-identical to today.
  - The B3 wall turns any team-scope blindness (NE1) into extra round trips, never into a subagent.
  - Removing `requireAllowGlobal` is deliberate: its only purpose was scope A.
- No Ultra-Advisor escalation needed.
