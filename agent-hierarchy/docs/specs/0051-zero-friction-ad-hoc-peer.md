# Spec 0051 — Zero-friction ad hoc peer spawn

Status: r5, FINAL, ready for implementation.

r5 changes (Reviewer spec-defects on the R5 predicate):
- A missing `roster_level` now FAILS CLOSED; it is no longer exempt.
- A name held by several team records is exempt only if every such record is
  exempt.
- `roster_level` is read from team records only, never from
  `resolved.rosterLevel`.
- Exact SKILL.md `:620-622` replacement added (§5). AC8b and AC8c added.

r4 changes:
- R5 is narrowed to members of teams whose record is not global-derived (§2.4).
  This keeps spec 0011's BLOCKING tests (`tests/test-roster-multi-team.sh`
  cases 12 and 16) exactly as written and green.
- AC5 corrected to what the dry-run plan exposes. The shared launch-failure
  line is accepted. The real-Herdr name-taken shape is recorded as a known
  unknown (§4 R8).
- AC8 extended, AC17 added; §6 amended.

r3 changes:
- R7 is WITHDRAWN (§4). The 0044 §6 tests stay as they are.
- §5 SessionStart and orchestrator.md now give exact, size-neutral wording.
  The ceilings are unchanged.
- Line references fixed; leftover K1 conditionals purged. Plugin baseline: agent-hierarchy 0.78.0.

r2 changes:
- K1 ruled by the user: "Ungate both".
- K2 decided yes. It becomes R7.
- N1–N4 resolved (§13). N3 becomes R8, plus one Implementor-measured item.
- §3 and §5 amended for the subagent owner-pid and reply routing.
Paths are relative to `agent-hierarchy/` unless stated otherwise.

## 0. Goal

User requirement, verbatim:

> "I want there to be a way for any agent to spawn peer agents (teammates) using
> ah:agent-team but ad hoc and if there isn't an agent roster, that's okay, it
> should just smoothly create the agent. So I think we need to have a path that an
> agent can take to create an ad hoc peer agent with zero friction, no gate but if
> the user doesn't specify enough details for a team or teammember then go down
> the formal path with gates."

The spec defines two paths:

- **Ad hoc path.** Any agent, in any repo (including one with no roster, no team
  file and no hierarchy config), spawns ONE peer with ONE Bash call and then
  briefs it. There are no hook denies, no AskUserQuestion bounce, no "load the
  skill first" bounce and no `--allow-global` requirement. A missing roster is
  not an error.
- **Formal path.** Anything the ad hoc path cannot express goes through the
  existing gated flow, unchanged: a whole team, an unnamed role, or a lifecycle
  operation (create, adopt, move, dismiss, disband, untrack).

The ad hoc entry point is the existing verb `roster.mjs spawn-ad-hoc <role>`. It
already works with no roster (`hooks/roster.mjs:2118-2121`) and already derives
the name, the team file and every default. What stands in the way is hook and
flag ceremony around it, not missing machinery. **No new verb, flag, config knob
or helper is introduced.**

## 1. Friction inventory (traced)

Scenario: a main session in a git repo with no `.claude/agent-hierarchy.json`,
no team file and no hierarchy dir. `$HOME` either has no
`~/.claude/agent-hierarchy.json`, or has one with a roster (the "G" rows below).
The agent spawns a reviewer peer and then briefs it.

Classes:
- **S** = load-bearing safety; keep.
- **C** = ceremony for this case; remove on the ad hoc path.
- **E** = genuine environment error; keep, and the message must be actionable.

### 1.1 Spawn step: `node <root>/hooks/roster.mjs spawn-ad-hoc reviewer --cwd <repo>`

| # | Where | What happens | Class |
|---|---|---|---|
| F1 | `hooks/pretooluse-roster-skill-gate.mjs:36` (`VERBS` includes `spawn-ad-hoc`, `spawn-one`), `:83-86` | The first call in the session is DENIED with "lifecycle ops are owned by `ah:agent-team`". The record is written at deny time, so the identical retry passes. Nothing detects a skill load: `Skill("ah:agent-team")` fires no hook, and `commands/agent-team.md` is a 9-line wrapper with no skill body (orchestrator friction #2). This deny contradicts SessionStart item 13 (`hooks/lib-config.mjs:1023`: "Spawning one session is a direct call, not a skill"). Subagents are exempt (`:73`); a top-level `--agent <role>` session is gated. | **C** |
| F2 | `hooks/roster.mjs:2122` → `requireAllowGlobal` `:1672-1677` (G only) | When a global-level roster resolves, spawn-ad-hoc fails without `--allow-global`, even though it takes no member from that roster. It uses only layout mode and route fallback (`:2210-2216`). | **C** (see §2.3) |
| F3 | `hooks/roster.mjs:2150-2157` | Creating a new team file with no `--orchestrator-pid` and no `CLAUDE_PID` is refused, and so is a dead pid. This prevents an ownerless team that reap and disband cannot attribute. | **S** (N1) |
| F4 | `hooks/roster.mjs:1418` → `failUnnamablePrefix` `:404-410` | The repo basename fails `validateTeamAlias`, so the team file cannot be named. The refusal suggests an alias. | **E**, kept (R7 withdrawn in r3) |
| F5 | `hooks/roster.mjs:3319` → `requireHerdrName` `:536-551` | For a non-claude kind, a name that does not match `^[a-z][a-z0-9_-]{0,31}$` fails. For the claude kind it is only a warning. | **E**, non-claude only |
| F6 | `hooks/roster.mjs:3316-3318` | The derived name already exists in the team file, so the command refuses. The ordinal is pre-bumped (`:3313-3315`), so this only fires on inconsistent state. | **S** |
| F7 | `hooks/roster.mjs:2178-2184`, `:1633-1659`, `:1576-1590` | Herdr is unreachable, the binary or `HERDR_PANE_ID` is missing, tmux fails, or the launch fails or times out. | **E** |
| F8 | `hooks/roster.mjs:3293` vs `:2116` | `task-runner` passes the `ROLES` check and then fails later with the message "spawn-one: role must be one of…" (wrong verb, late). | **E**, bad message |
| F9 | `hooks/pretooluse-ah-cli.mjs:38-41` | Auto-allows parsed ah commands, so there is no permission prompt. It only applies when the command is `node <absolute root>/hooks/roster.mjs …` with no shell metacharacters (`hooks/lib-ah-cli.mjs:116-151`). A relative path or a `&&` chain falls back to the user's normal permission prompt. | n/a (doc point) |
| F10 | `hooks/pretooluse-disband-close-gate.mjs` | Only fires on `dismiss`/`disband --close`, so it cannot trigger on a spawn. | **S**, kept |

### 1.2 Brief step: `msg.mjs new …`, then `SendMessage(to: <derived name>, "[hierarchy-msg <path>]…")`

| # | Where | What happens | Class |
|---|---|---|---|
| F11 | `hooks/pretooluse-route-gate.mjs:331-338` | For a peer-eligible `to`, with no session route, no config route and a caller that is not subordinate, the first SendMessage peer brief is DENIED with "choose this session's dispatch route" (AskUserQuestion plus `msg.mjs route … --session`). This fires in a repo with no roster, because nothing checks for one. For a top-level `--agent <role>` session with no `up` record, the ask cannot be answered at all: `pretooluse-conduit-gate.mjs:57-65` denies that caller AskUserQuestion. The role resolves from the team file (`:305-307`), so the gate knows the target is an already-spawned teammate. | **C** |
| F12 | `hooks/pretooluse-route-gate.mjs:319-324` (G only) | Scope A, the global-roster confirm, denies a brief to a team-file member until `msg.mjs global-scope roster allow` is run. Sending to a peer recorded in this repo's team file borrows nothing from the global roster. | **C** |
| F13 | `hooks/pretooluse-route-gate.mjs:318, 326-328` | Scope B fires when `sources[role] === "user"` (the user-level config sets that role). A brief to an existing teammate uses none of that config: its model was fixed at spawn. | **C** |
| F14 | `hooks/pretooluse-route-gate.mjs:347-351` | The session route is explicitly `subagents`, so a peer brief is denied once. That is an explicit user choice. | **S**, kept |
| F15 | `hooks/pretooluse-msg-gate.mjs:73-90` | The SendMessage sentinel must name a valid request file (`msgs` defaults to `"required"`). This is the message protocol, not a spawn gate. It never bounces an agent that follows the documented two-step brief. | **S**, kept |
| F16 | `hooks/pretooluse-sendmessage-response.mjs` | Only concerns replies from architect or implementor callers. Not on this path. | n/a |

### 1.3 Session-start and naming

| # | Where | What happens | Class |
|---|---|---|---|
| F17 | `hooks/lib-config.mjs:989-999`, emitted by `buildDirective` `:1035-1045` | The PEER NAME CONFIRMATION paragraph. It is emitted when a peer-eligible role has dispatch `peer` and peer `auto`, and suggests `<prefix>-<role>`. It is injection text only; no CLI or hook enforces it. A name that spawn-ad-hoc or spawn-one just reported is authoritative through the team file (the route gate resolves the team file first, `pretooluse-route-gate.mjs:305`), so asking anyone to confirm it is ceremony. | **C** (text) |
| F18 | `/Users/jimcline/git/repos/claudetools/.claude/agent-hierarchy.json:11-12` (`"peer":"ct-arch1"`) vs `hooks/lib-config.mjs:288-290` `peerName` | Orchestrator friction #4. The config `roles.*.peer` value is hand-authored and never consulted by the spawn verbs. Both derivations agree only for `"auto"` or `<prefix>-<role>`. This cannot occur in a repo with no config. | out of scope (§7) |
| F19 | `agent_name_taken` | This string appears nowhere in hooks. A Herdr duplicate-name failure falls through to the generic launch failure (`hooks/roster.mjs:1590`). | **E** (N3) |

### 1.4 The other entry point, Agent-tool dispatch (`Agent(ah:reviewer)`)

This spawns a subagent, not a teammate, so it is **not** the ad hoc peer path.
It can hit the route-ask (F11), the peer-fallback-ask
(`pretooluse-route-gate.mjs:386-390`) and the msg-gate token deny
(`pretooluse-msg-gate.mjs:88-90`, not one-shot). Orchestrator friction #1 was
this path. **It is unchanged by this spec**: it is the formal subagent-dispatch
flow, and the route question it asks is a real product choice. The docs changes
in §5 steer "spawn a peer or teammate" requests away from it.

## 2. Design

### 2.1 Entry point

`node <root>/hooks/roster.mjs spawn-ad-hoc <role> --cwd <abs cwd>`, with every
other flag optional. The Bash call must use an absolute path and no chaining, so
that `pretooluse-ah-cli.mjs` auto-allows it (F9).

### 2.2 Sufficiency predicate, decided in ONE place: the `spawn-ad-hoc` CLI argument validation

A request is **sufficiently specified** for the ad hoc path iff it names
**exactly one member** and **one role that is in `PEER_ELIGIBLE_ROLES`**
(`hooks/lib-config.mjs:282`: ultra-advisor, architect, reviewer, implementor).
Nothing else is required.

Defaults are filled silently. All of them already exist; none are new.

| Field | Default |
|---|---|
| model | `ROLE_DEFAULTS[role].model` (`lib-config.mjs:154-160`) for the claude kind |
| effort | the agent file's own |
| kind | claude |
| route | `peer` (`AUTO_INIT_ROUTE`) |
| team | the derived `teams/<prefix>.json` |
| name | `<prefix>-<role>[-n]` |
| owner pid | `CLAUDE_PID` |

These defaults are safe because every one of them is reversible with `dismiss`
and none reaches outside this repo.

The mechanism is `spawn-ad-hoc`'s existing argument validation. No hook
re-implements the predicate: the hook side of the change is only "stop gating the
verb" (§2.4), so the CLI is the single arbiter. Required CLI changes:

- **R1.** Validate the role against `PEER_ELIGIBLE_ROLES` up front, in
  spawn-ad-hoc's own argument check (today `:3293` checks `ROLES`). The refusal
  names spawn-ad-hoc and lists the eligible roles. This fixes F8.
- **R2.** Rewrite the missing-role refusal (`:3291`) and the ineligible-role
  refusal. Each must state that the request is under-specified and name the
  formal path: ask the user which role, or for a whole team use
  `Skill ah:agent-team` (Create). Exit code stays 2.

**What is NOT sufficient, and therefore goes down the formal path:**
- no role named, or a phrase that does not map to one role ("spin up some help");
- more than one member or "a team"; that is `create`, which is still skill-gated;
- any lifecycle operation other than spawning one member;
- a named team the user wants populated from a roster, which is `spawn-one`
  (ungated, §2.4).

Agent-side interpretation, mapping the user's words to a role, is judgment and
cannot be mechanised. The docs (§5) tell the agent: role named or clearly
implied → spawn-ad-hoc; otherwise → the formal path. If the agent calls
spawn-ad-hoc with no role or a bad one, R2's refusal is the route to the formal
path. The fall-through is therefore a CLI message, not a new gate.

### 2.3 Global roster on the ad hoc path (F2): stop reading it, instead of gating it

- **R3.** `spawn-ad-hoc` resolves the roster **only at repo-user or repo level**.
  A roster that would resolve at global level is treated as **no roster**:
  - synthetic `{route, layout: "auto", members: []}` (`:2216`);
  - team record `roster_level: null`;
  - no `requireAllowGlobal` call.

  `--allow-global` stays accepted and becomes a documented no-op for
  spawn-ad-hoc, so existing callers do not break.
- Rationale: spec 0009 exists to stop a repo from silently borrowing another
  project's roster. After R3, spawn-ad-hoc borrows nothing from the global
  roster, so the harm cannot occur. Removing the read closes the hole outright;
  a gate only guards it.
- **Kept unchanged:**
  - `spawn-one` and `create` still require `--allow-global` (they take members
    from the global roster);
  - route-gate scope A still applies to Agent/Task dispatch and to SendMessage
    targets that are not team-file members.

### 2.4 Hooks bypassed on the ad hoc path, and by what mechanism

- **R4, F1: remove from the skill gate.** Drop BOTH `spawn-ad-hoc` and
  `spawn-one` from `VERBS` in `hooks/pretooluse-roster-skill-gate.mjs:36`. K1
  was ruled by the user in r2: "Ungate both". Update, all in the same change:
  - the gate's header comment (`:10-15`);
  - `DENY_REASON` (`:52-58`) if it enumerates those verbs;
  - `tests/check-gate-name-agreement.mjs:37`, where `expect` becomes exactly
    create, adopt, move, dismiss, disband, untrack.

  The mechanism is verb removal, not a flag or a marker. Every other gated verb
  is untouched.
- **R5, F11–F13: exempt team-member sends in the route gate.** In
  `hooks/pretooluse-route-gate.mjs`, when a **SendMessage** carries the sentinel
  and its `to` resolves to a **team-file member** (`teamMember` non-null at
  `:306`), skip the scope A and scope B confirms (`:319-328`) and the route-ask
  (`:334-338`).
  - Do not append a `route-ask` record in that case, so a later
    Agent-dispatch ask is not suppressed by it.
  - The explicit-`subagents` enforcement (`:347-351`, F14) still runs. Compute
    the route for that check from `effectiveRoute`, as today.
  - Rationale: the routing question asks whether this work should go to a peer
    or a subagent. Once a teammate exists in this repo's team file and the
    caller addresses it by name, that question is already answered. The only
    live signal to the contrary is an explicit `subagents` choice, and that is
    honoured.
  - Not affected: Agent/Task dispatch, and SendMessage to config-named or
    roster-named peers that are absent from every team file.
  - **r4 scope: the exemption is keyed on the member's TEAM RECORD.** "Team-file
    member" above means an **exempt team member**:
    - `to` resolves to a member (as today, via `resolveMemberTeam` and then
      `teamMemberByName`; role resolution is unchanged); AND
    - (r5) **every** team record that has a member whose `name` equals `to`
      exactly carries an exempt `roster_level` (table below). The records
      searched are the legacy `team.json` and every `teams/*.json`: the same
      set `resolveMemberTeam` scans, read with the existing `readTeam` and
      `listTeamNames` (`hooks/lib-roster.mjs`). One non-exempt record anywhere
      removes the exemption, so the result never depends on scan order.
    - `roster_level` is read ONLY from those team records, never from
      `resolved.rosterLevel`. `resolved.rosterLevel` still decides whether
      scope A fires at all for a non-exempt target, exactly as in 0.78.0.
  - Value handling (r5: an allow-list, so everything else fails closed):

    | Team record `roster_level` | Exempt? |
    |---|---|
    | `null` (spawn-ad-hoc always writes it explicitly after R3) | yes |
    | `"repo"` / `"repo-user"` (built from this repo's roster) | yes |
    | `"global"` | **no**: 0.78.0 behaviour exactly |
    | field missing | **no** (r5, flipped from r4): 0.78.0 behaviour |
    | any other value | no: 0.78.0 behaviour |

    Why missing is not exempt (r5): a record without the field predates the
    0.38.0 confirm gate, so its members may be global-derived and never
    confirmed. No zero-friction case needs the exemption, because every
    roster.mjs team write since 0.32.0 sets the field (`roster.mjs:2268`,
    `:2773`) and spawn-ad-hoc writes an explicit `null`. The cost is at most
    one scope-A ask per session, and only when `resolved.rosterLevel` is
    global. In JavaScript terms "missing" means the key is absent
    (`undefined`); an explicit `null` is exempt.
  - **One predicate for all three skips.** Scope A, scope B and route-ask are
    all skipped for an exempt team member, and none is skipped for a member of
    a `"global"` team. A global-derived team was stood up through the formal
    path, which §2.5 promises to leave unchanged. Its members therefore keep
    every 0.78.0 gate, the route-ask included.
  - The route-ask non-append rule applies only when the member is exempt.
  - Consequence: a member added by spawn-ad-hoc INTO an existing team whose
    record says `"global"` is NOT exempt, because the team record decides and
    not the member. This is intended. Record it in the SKILL.md "One peer,
    zero ceremony" section as one clause: "briefs to members of a team built
    from the global roster still get the 0009 confirm".
  - The repo-level roster case, which is the user's friction report (the live
    team in this repo was built from its repo roster): the record says `"repo"`,
    so the member is exempt and all three skips apply.
  - The rationale is narrowed to match: an exempt team borrows nothing from
    the global roster, so 0009 scope A has nothing to confirm. That is true of
    a team whose record says `null`, `"repo"` or `"repo-user"`, and false of
    one whose record says `"global"`.
- **Kept, with the reason:**

| Gate | Why it stays |
|---|---|
| disband/close gate (F10) | Destructive. Cannot trigger on a spawn. |
| msg-gate token (F15) | The protocol itself. Not a bounce when followed. |
| ultra-gate | Spends ultra-advisor tokens. User-owned choice, via `~/.claude/agent-hierarchy.gate.json`. Spawning an ultra-advisor peer via spawn-ad-hoc is not gated by it (Bash). Briefing that peer by SendMessage IS gated (`pretooluse-ultra-gate.mjs:142-146`). Intentional: the cost control belongs on the ultra tier. |
| conduit gate | Unrelated to spawning. |
| owner-pid refusal (F3) | Unowned teams break reap and attribution. |
| collision refusal (F6) | Protects an existing record. |
| environment errors (F7) | Genuine. |

### 2.5 How the formal path is reached

The formal path is reached only through R2's refusal or through the agent's own
reading of the request (§5 text). Both land on the unchanged Skill
`ah:agent-team` flow, where the skill gate still guards
`create`/`adopt`/`move`/`dismiss`/`disband`/`untrack`, and where `spawn-one`
and `create` still require `--allow-global` and still hit the route gate on
dispatch. **No formal-path behaviour changes.**

- **R6.** `spawn-one` with no roster (`hooks/roster.mjs:2121`): extend the
  message so its first remedy is `spawn-ad-hoc <role>`, which needs no roster.
  The `/agent-roster` Init remedy stays second. Text only.

## 3. Any agent: subagents and non-Orchestrator sessions

| Caller | Spawn (Bash) | Brief (SendMessage) |
|---|---|---|
| Main or Orchestrator session | Ungated after R4. Auto-allowed (F9). | Route-ask and scopes skipped for a team member (R5). msg-gate token required (F15). |
| Top-level `--agent <role>` session | Ungated after R4 (it was gated before). | R5 removes the unanswerable route-ask (F11). msg-gate exempts a directly attributed caller (`pretooluse-msg-gate.mjs:53-56`). |
| Subordinate peer (has an `up` record) | Ungated after R4 (it was gated before). | No route-ask even today. Route becomes `prefer-peers` (`:344`). |
| Subagent (`agent_id` set) | Already exempt from the skill gate (`:73`) and the route gate (`:263`). See the bullets below. | A subagent MAY brief the peer. Its SendMessage goes out under the parent session's address, and any reply lands in the PARENT's conversation, not the subagent's (N2). |

Subagent ownership and replies (N1 and N2, resolved in r2):
- The owner pid of a team created by a subagent's ad hoc spawn is the PARENT
  session's pid. In a subagent, `CLAUDE_PID` equals the parent `claude`
  process. This is **intended behaviour**, not a gap: the team outlives the
  subagent, and reap and disband must attribute it to a live session.
- A subagent must not wait for the peer's reply. The parent receives it.

- The CLI performs no caller-identity check beyond the owner-pid liveness
  (F3). This spec adds none: "any agent" is the requirement.
- The request file's `from:` should be the caller's own role. §5 text must not
  hard-code `--from orchestrator` for the ad hoc brief.

## 4. Naming and collision with no roster

This section changes nothing. It records the existing contract so the docs
state it.

- **Prefix** (`teamPrefixInfo`, `hooks/lib-config.mjs` ~`:601`): the first of
  - `--team`;
  - else the first valid `teamAlias` in the repo-user or repo config (never
    global);
  - else the basename of the git root, or of the cwd.
- **Name.** `peerName` = `<prefix>-<role>` (`lib-config.mjs:288-290`). The nth
  same-role member in the team file is `<prefix>-<role>-n`
  (`roster.mjs:3313-3315`). The name is never caller-chosen.
- **Team file.** `<hierarchyDir>/teams/<prefix>.json`. `hierarchyDir` is
  `<gitroot>/.claude/hierarchy`, or `~/.claude/hierarchy/<basename>` outside
  git (`lib-config.mjs:440-447`). It is created on first spawn with
  `partial: true` and `roster_level: null`. That file is the only state
  spawn-ad-hoc writes.
- **Collision.** A name taken in the team file is refused (F6), with no
  auto-suffix beyond the pre-bumped ordinal.
- **R8, derived name already live outside the team file** (N3; added in r2).
  Before launching, `spawn-ad-hoc` checks whether the derived name is live. It
  must reuse the liveness check `spawnOneCore` already applies to a member
  (`hooks/roster.mjs:2178-2203`); no new liveness mechanism. If the name is
  live:
  - `spawn-ad-hoc` REFUSES: exit 2, nothing written, no launch;
  - the message names the taken name and the remedies (`dismiss <name>`,
    `untrack <name>`, or `--team <other>`);
  - it must NOT return the `{spawned:false, reason:"already live"}` success
    shape that `spawn-one` uses. For spawn-ad-hoc that shape would hand the
    caller someone else's session as if it were the new member.

  `spawn-one`'s existing "already live" no-op is unchanged.
  - Indeterminate liveness keeps the existing refusal (`:2178-2184`).
  - Implementor-measured item: the shape of the Herdr launch failure for a
    name that is taken but not visible to the liveness check. If Herdr reports
    a distinct code, map it to the same refusal. If it does not, the generic
    failure at `:1590` must still exit non-zero with the attempted name in its
    message. Do not start a colliding herdr agent on the user's desktop to find
    out: measure only under an isolated herdr session, or leave the generic
    path and say so in the report.
  - **r4, known unknown:** the real Herdr's name-taken return shape is
    UNMEASURED. Only the fake-herdr path was exercised. The guarantee is the
    generic path: a non-zero exit whose message carries the attempted name. A
    distinct code can be mapped later if it is ever measured; do not measure
    it on the user's desktop.
  - **r4, accepted:** the shared launch-failure line is
    `<verb>: launching <name> failed — <transport error> — …`. It is shared
    by spawn-ad-hoc and spawn-one, so spawn-one's text changes too. This is
    accepted because the old text lacked the name. Assumption, not verified by
    the Architect: no hook or skill parses this line. The Implementor confirms
    this by grep and reports any hit. Update any test that greps the old spawn-one text in the same change.
- **R7: WITHDRAWN in r3.** The Implementor must revert any R7 code and
  test edits, so that `teamPrefixInfo` is byte-identical to 0.78.0 and
  `tests/test-roster-team-scope.sh` §6 (6a–6e) stays exactly as it is and
  green. Reasons:
  - `teamPrefixInfo` feeds the route gate, the SessionStart name suggestion
    and legacy `team.json` resolution, so R7's blast radius is wider than this
    spec;
  - spec 0044 [9.1]/R2 deliberately refuses an unnamable default prefix. That
    includes 6d/6d3: an orphaned legacy `team.json` must NOT let a create path
    fall through to a derived name. Overturning that is its own design
    decision, not a side effect here;
  - narrowing R7 to spawn-ad-hoc alone would make spawn-ad-hoc name a team
    that `dismiss`/`disband`/the route gate then resolve under a different
    prefix, which is worse than the refusal.

  Therefore F4 stays an E-class refusal. It fires once per repo, and its
  message already gives the exact remedy
  (`roster.mjs alias --level repo --set <suggested>`). `failUnnamablePrefix`
  stays, reached by §6 unchanged. A possible follow-up spec is
  default-prefix sanitisation across all consumers, including a ruling on
  0044 R2.
- **Output.** The CLI output must carry the derived name. The agent reports it
  in one line, as SKILL.md `:746` already says.

## 5. Discovery: text changes, so the ad hoc path is found FIRST

Each change is a short insertion or reword. No restructuring.

- **`skills/agent-team/SKILL.md`**
  - Add a short section immediately after the intro, before `## Command surface`
    (`:35`): "One peer, zero ceremony". It says:
    - `roster.mjs spawn-ad-hoc <role> --cwd <abs>` works in any repo, roster or
      not, with no skill load, no route question and no `--allow-global`;
    - the brief is `msg.mjs new --to <role> --from <your role> …` followed by
      SendMessage to the reported name;
    - a subagent may spawn and brief a peer, but the reply is delivered to its
      parent session, never to the subagent, so the subagent must not wait
      for it;
    - a repo whose name is refused as a team prefix needs one
      `roster.mjs alias --level repo --set <suggested>`, which the refusal
      prints;
    - the formal path applies only when no single role is named, when a whole
      team is wanted, or for lifecycle ops.
  - Rewrite `## spawn-ad-hoc` (`:723-747`):
    - "use it whenever the roster does not have…" becomes "use it whenever one
      peer is wanted and the roster (if any) has no live member for it";
    - item 4 drops `--allow-global` from the "behave identically" list and
      states R3;
    - the `:728` "reads the roster" sentence becomes "repo-level roster only".
  - In the gates block (`:595-605`), add one line: spawn-ad-hoc is exempt from
    `--allow-global` (R3).
  - (r5) In the same gates block (`:620-622`), replace the bullet starting
    `**The PreToolUse global-scope confirm gate**` with exactly:
    ```
    - **The PreToolUse global-scope confirm gate** (spec 0009 §4) still applies
      to any Agent/Task dispatch to the resulting peer, and to a SendMessage to
      it unless every team record naming it has `roster_level` `null`, `repo` or
      `repo-user` — `--allow-global` only unblocks the CLI command that stands
      the peer up, not later dispatch to it.
    ```
- **`commands/agent-team.md`**
  - The description drops "from the existing agent-hierarchy roster". Suggested:
    "…a live Team of agent sessions — one peer ad hoc with no roster needed, or
    a whole Team from the roster".
  - The body stays a wrapper. This spec does not make the command inline the
    skill body; after R4 the ad hoc path does not need it.
- **`agents/orchestrator.md:60-62`** (r3: exact text; the file is at
  7300/7350 B).
  - Replace:
    ``One session: `roster.mjs spawn-one <role> [--member <n>]`, or `roster.mjs spawn-ad-hoc <role> [--kind pi|codex|claude] [--route peer|pane]` when the roster has no such member.``
  - With:
    ``One session: `roster.mjs spawn-ad-hoc <role> [--kind pi|codex|claude] [--route peer|pane]` (no roster needed), or `roster.mjs spawn-one <role> [--member <n>]` for a roster member.``
  - Keep the existing line wrapping style.
  - Net change: +3 B (hand-counted: " when the roster has no such member" is
    35 B; " (no roster needed)" is 18 B; " for a roster member" is 20 B). The
    size test is authoritative.
- **`docs/cli-tools.md:135-136`**
  - spawn-ad-hoc row: "no roster needed; not skill-gated; global roster ignored
    (`--allow-global` accepted, no-op)".
  - spawn-one row: add "not skill-gated".
- **SessionStart injection** (r3). Directive size ceilings in
  `tests/test-directive-size.sh` stay UNCHANGED. The additions are paid for
  inside the same strings. Baseline headroom is about 53 B (auto) and about
  49 B (confirm).
  - **Item 13** (`hooks/lib-config.mjs:1023`). Do NOT append "No roster
    needed: `spawn-ad-hoc <role>`." It duplicates item 13's existing clause
    "with no roster, or for a role the roster does not carry, `… spawn-ad-hoc
    <role> …`". Remove it if it was already added.
  - In item 13, replace `create/spawn a Team, spawn or dismiss one member,
    disband` with `create/spawn a Team, dismiss one member, disband`. This
    saves 9 B and removes item 13's self-contradiction with its own "Spawning
    one session is a direct call, not a skill" after R4.
  - **PEER NAME CONFIRMATION** (`peerConfirmationParagraph`,
    `lib-config.mjs:995`). In the first array string, replace exactly:
    `Resolve ONCE, the first time you need to dispatch that role, before dispatching:`
    (80 B)
  - with:
    ``Skip if `spawn-one`/`spawn-ad-hoc` reported the name this session. Else resolve ONCE, at that role's first dispatch:``
    (116 B)
  - Remove the r2 sentence "A name that `spawn-ad-hoc` or `spawn-one`
    reported … ask nobody." if it was already added.
  - Net across both strings: +36 −9 = +27 B. That is inside both headrooms
    with about 20 B to spare. Byte counts are hand-counted; the size test is
    authoritative. If it still fails, report the measured sizes back. Do NOT
    raise a ceiling.
- **`hooks/pretooluse-roster-skill-gate.mjs` `DENY_REASON`**: if the verbs are
  listed, drop the spawn verbs (R4).
- **`docs/specs/0042-agent-roster-skill-gate.md`**: add a one-line status note
  that spec 0051 removed the spawn verbs from the gated set.
- **`docs/specs/0009-global-roster-confirm-gate.md`**: add a one-line status
  note that spec 0051 §2.3 made spawn-ad-hoc ignore the global roster.

## 6. Must NOT change

- The skill gate still gates create, adopt, move, dismiss, disband and untrack. Its one-shot semantics, compact re-arm
  (`sessionstart.mjs:96-99`) and fail-open behaviour are unchanged.
- The disband/close gate, msg-gate, ultra-gate, conduit gate and
  sendmessage-response hook are unchanged.
- In the route gate:
  - Agent/Task dispatch behaviour is unchanged in every branch;
  - SendMessage to a target that is not a team member is unchanged;
  - SendMessage to a member of a team whose record says `"global"` is
    unchanged (r4). `tests/test-roster-multi-team.sh` cases 12 and 16 (spec
    0011 §11 test 7 and §9.1 amendment d, BLOCKING) pass unmodified;
  - the `subagents` deny is unchanged.
- `spawn-one` and `create` keep the `--allow-global` requirement.
- The name-derivation algorithm is unchanged.
- The team-file schema is unchanged.
- The owner-pid refusal is unchanged.

## 7. Out of scope, noted

- **F18, orchestrator friction #4 (`ct-arch1` vs `claudetools-architect`).**
  This is a hand-authored config value in this repo
  (`.claude/agent-hierarchy.json:11-12`). The fix is a config edit to `"auto"`,
  or a separate spec that makes SessionStart prefer live team-file names over
  config `peer` strings. It is not needed for repos with no roster.
- **Agent-tool subagent dispatch friction (§1.4).** This is the formal path by
  definition.
- **Concurrent spawn-ad-hoc of the same role by two agents.** Both compute the
  same ordinal, and the team-file write may race. This is pre-existing. Flag it
  if R5 makes ad hoc spawning common enough to matter.

## 8. Edge cases

| Case | Required behaviour |
|---|---|
| No role / `task-runner` / `orchestrator` | Exit 2 with the R1/R2 message naming the formal path. Nothing written. |
| Global roster only (G), no `--allow-global` | spawn-ad-hoc succeeds with `roster_level: null` (R3). spawn-one still fails naming `--allow-global`. |
| Repo-level roster present | spawn-ad-hoc uses the repo roster's route and layout, as today. |
| Team file already has `<prefix>-reviewer` | New member `<prefix>-reviewer-2`. |
| Not a git repo | hierarchyDir is `~/.claude/hierarchy/<basename>`. Works otherwise. |
| `CLAUDE_PID` unset and no team file yet | Refused, unchanged (F3). N1 decides whether this ever happens in practice. |
| `--dry-run` | Plan JSON. No team file, and no gates.jsonl record (the skill gate no longer fires). |
| Brief to the spawned peer, session route `subagents` | Denied once (F14), unchanged. |
| Brief to the spawned peer, global roster present, never answered | Passes (R5): the team record says `null`. |
| Brief to a member of a team whose record says `"global"` | 0.78.0 behaviour: scope A, scope B and route-ask as today (r4). |
| Brief to a member of a repo-roster team (`"repo"` / `"repo-user"`) | Passes (R5). |
| Brief to a member whose team record has no `roster_level` key | 0.78.0 behaviour (r5, fail closed). |
| Name held by two team records, one of them `"global"` | 0.78.0 behaviour, whichever record is scanned first (r5). |
| Brief to a config-only peer name absent from team files | Route-ask as today. |
| Compact mid-session | The skill gate re-arms for the remaining gated verbs only. Spawns are unaffected. |
| Non-claude `--kind` with a non-herdr transport | Refused, unchanged (E). |

## 9. Acceptance criteria (checkable)

- **AC1.** Fresh session, repo with no config, HOME redirected to an empty dir:
  running `pretooluse-roster-skill-gate.mjs` on a Bash `spawn-ad-hoc reviewer`
  command emits no deny and appends nothing to `gates.jsonl`. Same result for
  `spawn-one reviewer`.
- **AC2.** The same gate still denies `create` on the first call and passes the
  retry.
- **AC3.** `tests/check-gate-name-agreement.mjs` passes with the new `expect`.
  It fails if `spawn-ad-hoc` is re-added to `VERBS` without updating `expect`.
- **AC4.** `roster.mjs spawn-ad-hoc reviewer --dry-run --cwd <tmp git repo>`
  with `CLAUDE_PID=<live pid>`, no config and an empty HOME: exit 0, and the plan
  names `<basename>-reviewer`.
- **AC5.** As AC4 but with HOME containing a global roster and no
  `--allow-global`: exit 0. (r4) The dry-run plan exposes `mode`, not
  `layout` or `roster_level`, so the check is: set the global roster's layout
  to `grid`, and the plan's `mode` must equal the `mode` of the AC4 no-roster
  run. With `--allow-global`: also exit 0, with the same `mode`.
  `roster_level: null` on the written record is covered by the R3 unit path if
  one exists; do not add a real launch to prove it.
- **AC6.** `roster.mjs spawn-one reviewer --dry-run` with only a global roster
  and no `--allow-global`: exit 2 with the 0009 message (unchanged).
- **AC7.** `spawn-ad-hoc` with no role, with `task-runner`, and with
  `orchestrator`: each exits 2, and stderr names `spawn-ad-hoc` and the formal
  path.
- **AC8.** Route gate, main session, no route recorded, no config route, with
  `teams/<x>.json` containing `<x>-reviewer`: SendMessage with the sentinel
  `to: "<x>-reviewer"` is not denied, and no `route-ask` record is appended.
  Same with a global roster in HOME: no scope-A deny. (r4) The same holds when
  the fixture team's `roster_level` is `null` (existing TM1/TM4) or `"repo"`.
  Add the `"repo"` case to `tests/test-roster-global-gate.sh`, next to
  TM1–TM5.
- **AC8b (r5).** Missing field: a team fixture with no `roster_level` key,
  member `myrepo-reviewer`, and a global roster in HOME, never answered. A
  sentinel SendMessage to `myrepo-reviewer` gets the 0.78.0 behaviour: denied
  with a `scope:"roster"` record.
- **AC8c (r5).** Same name in two records: legacy `team.json` with
  `roster_level: null` and `teams/other.json` with `roster_level: "global"`,
  both holding `myrepo-reviewer`, and a global roster in HOME, never
  answered. The send is denied with a `scope:"roster"` record. Swap the two
  levels between the files: still denied. With both records `null`: allowed,
  and no `route-ask` record.
- **AC17 (r4).** Global-derived team control, in
  `tests/test-roster-global-gate.sh`: team fixture `roster_level: "global"`
  with member `myrepo-reviewer`, global roster config in HOME, never answered.
  A sentinel SendMessage to `myrepo-reviewer` is denied with a `scope:"roster"`
  record, the same as TM5. `tests/test-roster-multi-team.sh` cases 12 and 16
  pass with no edit to that file.
- **AC9.** Route gate control: SendMessage with the sentinel to a peer-eligible
  name that is in no team file still gets the route-ask deny.
- **AC10.** Route gate: session route `subagents` plus a SendMessage to a team
  member is still denied once.
- **AC11.** `spawn-one reviewer` with no roster: exit 2, and the message lists
  `spawn-ad-hoc` as the first remedy.
- **AC12 (r3).** When the injection has the PEER NAME CONFIRMATION paragraph,
  it contains "Skip if `spawn-one`/`spawn-ad-hoc` reported the name this
  session." Item 13 does not contain "spawn or dismiss one member".
  `tests/test-directive-size.sh` passes with its ceilings unchanged, and
  `agents/orchestrator.md` stays within its 7350 B ceiling.
- **AC14 (R8).** A stubbed or seeded liveness source reports
  `<prefix>-reviewer` live while the team file lacks it. `spawn-ad-hoc reviewer`
  then exits 2, the message names `<prefix>-reviewer`, the team file is
  unchanged, and no launch command runs. Use `--dry-run`, or the existing
  test seam for liveness; if none exists, the Implementor reports that rather
  than inventing one. `spawn-one` "already live" behaviour is unchanged
  (regression check).
- **AC15 (r3, replaces the withdrawn R7 AC).** `tests/test-roster-team-scope.sh`
  §6 (6a0–6e) passes unmodified, and `teamPrefixInfo` has no diff against
  0.78.0.
- **AC16 (F3).** With `CLAUDE_PID` unset and no `--orchestrator-pid`, the first
  spawn refuses, and the message names `--orchestrator-pid`. The message at
  `roster.mjs:2153` already does this; this is a regression check only.
- **AC13.** The version is 0.79.0 in both `agent-hierarchy/.claude-plugin/plugin.json:4`
  and root `.claude-plugin/marketplace.json:19`.

## 10. Test plan

Hooks are tested without installing: feed the hook script a JSON stdin payload
whose `cwd` is a temp git repo, with `HOME` and `AGENT_HIERARCHY_DIR` redirected
into temp dirs. Assert on stdout JSON and on `gates.jsonl` contents. This is the
existing pattern in `tests/`; follow the nearest existing route-gate and
skill-gate test files and extend them rather than adding a new harness.

- Skill gate: AC1 and AC2, with one payload per verb.
- Name agreement: AC3 by running the existing check. To prove it can fail,
  temporarily mutate `expect` in a scratch copy, not in the repo.
- CLI: AC4–AC7 and AC11 as subprocess runs of `roster.mjs` with `--dry-run`.
  Never run a real launch: dry-run must not spawn panes.
- Route gate: AC8–AC10, with a seeded `teams/<x>.json` and seeded `gates.jsonl`
  route records.
- SessionStart: AC12, by string assertions on the directive output of the
  function that builds it.
- Run the full existing suite. It must stay green: 393 tests or more at the time
  of writing.

## 11. Version bump

This is a minor bump, 0.78.0 → **0.79.0**, because it changes behaviour.
`agent-hierarchy/.claude-plugin/plugin.json:4` and
`/Users/jimcline/git/repos/claudetools/.claude-plugin/marketplace.json:19` (the
`"ah"` entry) must move together, in the same commit.

## 12. Open forks (decide before implementation)

Both forks are closed in r2:
- K1 was ruled by the user: "Ungate both" (R4).
- K2 was adopted in r2 as R7, then WITHDRAWN in r3 (§4). The blast radius was
  too wide, and it conflicts with 0044 [9.1]/R2. Deferred to a follow-up spec.

The original reasoning is kept below for the record.

- **K1. Also ungate `spawn-one`?** RULED: yes.
  - Recommendation: **yes**. It is also a single, role-specified member, and
    SessionStart item 13 already calls it "a direct call, not a skill".
  - If only spawn-ad-hoc is ungated, agents in rostered repos learn to prefer
    spawn-ad-hoc, which ignores the roster's model and effort for that role.
    That is a worse outcome than ungating spawn-one.
  - spawn-one's real safety check (`--allow-global`) lives in the CLI and is
    unaffected.
  - Confidence: medium-high.
  - This is the user's call only insofar as it reverses part of spec 0042.
- **K2. Unnamable repo basename (F4).**
  - Recommendation: make the **basename fallback** in `teamPrefixInfo`
    normalise to the same suggestion `failUnnamablePrefix` already prints.
    Explicit `teamAlias` and `--team` stay strictly validated.
  - Because the change sits in the shared prefix function, every verb, the
    SessionStart suggestion and the route gate agree on the result.
  - Such repos currently refuse every team verb, so no persisted team state
    depends on the old behaviour.
  - Confidence: medium, conditional on N4.
  - If declined, F4 stays a one-time E-class refusal with an exact remedy.

## 13. NEEDS-EVIDENCE (resolved in r2)

- **N1.** `CLAUDE_PID` was measured in a subagent's Bash tool and equals the
  parent `claude` pid, so it is set for the main session too.
  - `roster.mjs:2744` states every claude session exports it. The top-level
    `--agent` session was not measured; treat it as set.
  - The `:2153` refusal stays as the fallback, and its message already names
    `--orchestrator-pid` (AC16).
  - No owner-pid change.
- **N2.** A subagent can SendMessage. Its send goes out under the parent's
  address, and the reply lands with the parent. Reflected in §3 and §5.
- **N3.** There is no taken-name handling anywhere in `hooks/*.mjs`, only the
  team-level "already exists" refusals at `roster.mjs:1290` and `:1373`.
  Resolved by R8 (a liveness pre-check that reuses the existing liveness
  check). The Herdr return shape stays an Implementor-measured item under R8.
- **N4.** `validateTeamAlias` is at `lib-config.mjs:546-562`, and
  `suggestTeamAlias` at `:576-583` is pure. K2 was adopted as R7, then
  withdrawn in r3.

The original questions follow.

- **N1. Is `CLAUDE_PID` set in the Bash tool environment for (a) a main session,
  (b) a subagent, and (c) a top-level `--agent` session?**
  - Measure: run `echo "${CLAUDE_PID:-UNSET}"` via Bash in each.
  - If set in all three: no change.
  - If unset in any of them: every first ad hoc spawn from that caller is
    refused (F3), and the Architect must amend §2 with an owner-pid fallback.
    Do not implement a guess.
- **N2. Can a subagent call SendMessage to a peer session?**
  - If yes: §3 holds and a subagent can spawn and brief a peer.
  - If no: §5 text must say that a subagent spawns and then hands the derived
    name to its parent to brief. No code change either way.
- **N3. What does `herdr agent start <name>` return when `<name>` is already
  taken by an untracked agent?** Report the exit code, the stderr, and whether
  there is a distinct code such as `agent_name_taken`.
  - Distinct code: the CLI maps it to the F6-style refusal naming
    `dismiss`/`untrack`, with no auto-retry.
  - No distinct code: leave the generic failure (`roster.mjs:1590`).
- **N4. (K2 only.) What exactly does `validateTeamAlias` reject, and which
  function produces `failUnnamablePrefix`'s suggested name?** Report file:line
  for both, and whether the suggestion is a pure function of the basename.
  - Pure function: K2 is implementable as stated.
  - Not pure: K2 returns to the Architect.
