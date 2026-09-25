# 0060 — Team lifecycle and name hygiene

Status: r5, in implementation. Base: HEAD plus 0058 and 0059.

**r5 (review findings 1 and 3, both spec defects):**

- **Finding 1 (§3.4).** The ultra-gate also gates the suffixed-name
  pattern `<prefix>-<advise role>-<n>` across every gated prefix, with no
  team file needed. This closes the window between `create --spawn` and
  `--commit`, and the gap left by an unrecorded second instance. Test:
  N7b.
- **Finding 3 (§4, K1).** SKILL.md must match, verify and select members by
  the `name` the CLI printed, never by a derived name.
- **§8** gains the worktree note for the route gate.

Implementer: implementor
Reviewer: reviewer

**r4 (Implementor gaps A and B, defaults C–G):**

- **A = A2.** For renaming, "the team's own" means a record the
  existing liveness check finds live. When the check finds a record not
  live but its name is in `--names-in-use`, an outside session holds that
  name, and the record is renamed in place (§3.6).
- **B = B1.** spawn-one maps records and renames over the whole roster in
  roster order, as create does, and only then selects. `--member` matches
  final names (§3.6).
- **B1 adds a claim rule** (§3.6): each record belongs to at most one
  roster member. The route gate never denies a name that is a current
  record of the team (§3.4).
- **C–G are confirmed as the Implementor proposed:** C in §3.3, D and G in
  §2, E and G in §3.4, F in §3.6, G in §4 and §6.
- **One exception (r4 G1):** the ultra-gate's "all teams" scope is
  withdrawn, because it reversed 0011 §7.10. Its lookup now matches
  `gatedPrefixes` (§3.4).
- **H:** the generic owned-team refusal also says "no members", and §6's
  premise is corrected (§2, §6).
- **§3.5's notice text** now reads "another session" instead of "a live
  session outside this team". The claim rule can rename a member whose
  derived name is held by one of the team's own members.

r2 applies the user's rulings (§7):

- Q1 = 1A: the last departure ends the team. untrack also clears, and no
  history is written.
- Q2a = D1: the skill checks names with ListAgents.
- Q2b = R2: colliding members get an automatic `-n` suffix.
- Q2c: exact matches only.

The options that were not chosen are removed. §3 designs R2's five points
(i)–(v).

**r3:**

- OQ-1 = YES, designed in §3.6: spawn-one and spawn-ad-hoc take
  `--names-in-use` with the same renaming; the team's own names are
  excluded; a renamed record is respawned by `renamed_from`; the link does
  not persist past record removal; spawnReason gains its line.
- OQ-2 = deny.
- §3.2's suffix is always `<team>-<role>-<n>`.
- Tests N9–N14 added. One golden exception is added in §5.

No open questions remain.

## 0. The two gaps (from the 0057/0058 walkthrough)

1. **An empty team outlives its last member.** In the walkthrough, a
   one-member team was stood up with `spawn-ad-hoc docs-writer --team walk`.
   `dismiss walk-docs-writer` then left `teams/walk.json` as
   `{members: [], partial: true}`, still owned by the invoker. `create`
   treated that team as live and refused, and the user had to run `disband`
   separately.
2. **`create --plan` offers names that live sessions already hold.** For
   team `claudetools`, the plan offered `claudetools-architect`,
   `-implementor` and `-reviewer` while three live peer sessions with those
   exact names were running.

## 1. Facts (read at HEAD plus the uncommitted 0058 work; line numbers are the working tree's)

### Gap 1

- **`dismiss` removes a member with a plain filter-write**
  (roster.mjs:3924): `writeTeam(dir, {...team, members: team.members.filter(…)})`.
  It never checks for an empty result, never calls `clearTeam`, and writes
  no history.
- **`disband --close` goes through `reconcileAfterClose`**
  (roster.mjs:2872-2899). When no rows are kept, that function calls
  `clearTeam` and returns `team_removed: true`. `dismiss` does not use it.
  That is the asymmetry.
- **`untrack <name>` is the same filter-write** (`untrackMember`,
  roster.mjs:1227-1229). It is the only place that notices emptiness, and it
  only **warns** (:1245-1247), suggesting `untrack --all` or
  `disband --close`. `untrack --all --commit` clears the file (:4009).
- **Team liveness is pid-based, never member-count-based.** See `teamIsLive`
  and `teamOwnedBy` (lib-roster.mjs:637-654, with 0057's owned-team rule).
  An empty team owned by the invoker is live.
  - `create --plan`/`--spawn` → `refuseOrClearExistingTeam`
    (roster.mjs:2150-2163) refuses: "a live Team … already exists — disband
    it first".
  - For the derived default scope, `refuseLiveDefaultTeam` (:2081-2088) says
    "its members are dispatched under that prefix", which is wrong when
    `members` is `[]`.
  - `create --commit` → `guardLiveTeamAtScope` (:2119-2148) returns early for
    an owned team (:2125) and overwrites it.
- **spawn-one and spawn-ad-hoc join any existing team file, empty or not**
  (roster.mjs:3019-3024, :3140ff). `readTeam` returns an empty team as a
  normal record (lib-roster.mjs:318-329).
- **`partial` is written at birth and never recomputed:**
  - `create --commit` takes it from a caller flag (roster.mjs:3659);
  - spawnOneCore's new team sets `members.length > 1` of the roster
    (:3156);
  - the live `teams/ct.json` has `partial: true` with three members.
- **History has one writer.** `upsertHistory` (lib-roster.mjs:765-790) is
  called only by `create --commit`. `dismiss`, `disband` and `untrack` write
  no history.

### Gap 2

- **`create` never looks at liveness.** Member names come from
  `rosterMemberNames` (lib-config.mjs:750-758): `<prefix>-<role>`, then
  `-2`, `-3`, and so on. It reads only the roster array and the prefix.
- Nothing on the create path (`resolveMembersPlan`, `createSpawn`,
  `guardLiveTeamAtScope`, `refuseOrClearExistingTeam`,
  `settleWritableTeamScope`) consults a liveness source. The only
  collision guards are team-level:
  - `teamNameProblem`: Herdr legality of the team name;
  - `guardTeamPrefixCollision` (:2049-2057): an explicit `--team` equal to
    the live default prefix;
  - whole-team liveness at the target file.
- **spawn-one and spawn-ad-hoc do check members** (`memberLiveness`,
  :2579-2585; refusal at :3064/:3080-3082). They use peers.jsonl via
  team-file names for claude kinds, and herdr status for other kinds.
- **Where the CLI can learn a live session's *name*:**
  - peers.jsonl `up` rows carry **no name** (sessionstart.mjs:144-165;
    lib-hier.mjs:155-158). A name is attributed only by joining `pane_id` to
    a team file's `transport_id` (`attributedRoster`, lib-hier.mjs:785-814).
  - peers.jsonl `seen`/`briefed` rows carry `name`, but only when the
    Orchestrator's tool output mentioned the peer (posttooluse-roster.mjs:68,
    :76). Freshness is `ROSTER_FRESH_SEC` = 1800 s.
  - Other teams' files hold `members[].name` plus `transport_id`.
  - `herdr agent list` gives live pane names (`herdrArmMatches`,
    roster.mjs:2701-2718), for herdr only.
  - For terminal and tmux sessions, nothing the CLI reads gives a session's
    name.
  - All of the name-aware readers above are used today only by
    `disband`/`dismiss`/`teams`/`reap`.
- **Why the walkthrough plan saw nothing.** This checkout's only team file
  is `teams/ct.json`: members `ct-architect`, `ct-implementor` and
  `ct-reviewer` on panes w16:p9, w16:pA and w16:pG. No file names
  `claudetools-*`.
  - The only `claudetools-*` rows in peers.jsonl are `briefed` rows from
    2026-09-10, stale by the freshness rule.
  - Yet sessions named `claudetools-architect` and `claudetools-implementor`
    are live **now**. This Architect is one of them, and the Implementor is
    another.
  - So the live sessions' real names (the ones ListAgents shows) are
    recorded in **no source the CLI reads**. Only the driver's ListAgents
    sees them.

## 2. Gap 1: an empty team

**Any option.** `refuseLiveDefaultTeam`'s text stops claiming "its members
are dispatched" when `members` is empty. It says instead that the team has
no members, and names the verb that ends it: `disband` (r4, D).

**(r4, H) The generic owned-team refusal gets the same text rule.**

- A bare `create` against the invoker's own empty team does not reach
  `refuseLiveDefaultTeam`. `resolveTeamFileScope` (roster.mjs:744-753)
  resolves it to the owned team with `teamFileDefaulted=false`, so
  `refuseOrClearExistingTeam`'s generic "a live Team <id> already exists —
  disband it first" is what fires. That is the refusal the walkthrough hit.
- When `members` is empty, that refusal also says the team has no members.
  It already names `disband`.
- Only the text changes. An empty team still blocks `create`, because 1B
  was not chosen.

**Output fields (r4, G):**

- `team_removed` is present only when it is true.
- `untrack` keeps its existing `team_empty` field. `team_removed` is added
  alongside it.

### The last member's departure ends the team (ruled 1A; Q1b and Q1c take the recommendations)

- **`dismiss --close`.** When the member it removes is the last one, the
  team file is cleared, the same way `disband --close` does it.
  - The close path goes through `reconcileAfterClose` (roster.mjs:2872-2899),
    or at least its clear branch. Do not write a second "clear when empty"
    path.
  - The output gains `team_removed: true`, the field disband already
    reports.
  - The non-destructive plan phase of `dismiss` gains
    `team_will_be_removed: true` when the named member is the last one, so
    the confirmation shows it.
  - Dismissing a member that is not the last one is unchanged.
- **`untrack <name>` (Q1b: clear).** When it removes the last member it
  clears the file the way `untrack --all --commit` does (`clearTeam`), and
  reports `team_removed: true`.
  - Its current "no members left… use `untrack --all`…" warning
    (roster.mjs:1245-1247) is replaced by a one-line notice that the team
    was removed.
  - The session is not touched: untrack only ever affects tracking.
- **History (Q1c: none).** No history entry is written for a team that
  ends this way. `create --commit` stays the only history writer.
- **Unchanged:** `create` still refuses a live team that has members.
  spawn-one and spawn-ad-hoc into a missing team still create one.
- *(1B, where an empty team persists but blocks nothing, and 1C, messages
  only, were not chosen.)*

## 3. Gap 2: planned names that live sessions already hold

*r2 rulings: detection is **D1** (the driver, through ListAgents; no CLI
detection). The response is **R2**, the user's knowing choice: suffix the
colliding members automatically. Only **exact** matches collide (Q2c). D2,
D3 and R1 were not chosen.*

**More facts behind (iv) (read at the working tree).**

- **The directive's peer target for a role is derived, not read from the
  team.** `resolvedPeerTargets` (lib-config.mjs:437-444) returns
  `peerName(prefix, role)`, the plain `<team>-<role>`, whenever `peer` is
  `auto`.
- **The ultra-gate matches plain names only.** Its SendMessage branch
  (pretooluse-ultra-gate.mjs:157) compares `to` against
  `peerName(prefix, r)` and `resolvedPeerTargets` with `isGatedPeerTarget`
  (lib-gate.mjs:58-62), which is an exact match after stripping `[ref]`. So
  a SendMessage to `<team>-ultra-advisor-2` is **not gated today**. That
  already affects a second Ultra-Advisor instance, and R2 would make it
  affect a renamed first one.
- **The route gate uses real names.** It resolves a SendMessage's role from
  live roster instances by their recorded `name` (pretooluse-route-gate.mjs:183),
  and `peersDenyReason` names `ordered[0].name`. The live roster comes from
  team-file names.

### 3.1 (i) How the skill tells create which names are taken: `--names-in-use`

- **`create --names-in-use <name>`**, repeatable, on **every** phase
  (`--plan`, `--spawn`, `--commit`, `--from`).
  - The values are session names as ListAgents shows them, with any
    trailing `[ref]` stripped.
  - The CLI cannot see ListAgents, so this flag is its only knowledge of
    outside names. It does no detection of its own.
- **The skill (D1)** runs ListAgents before the team-name question, as
  ruled.
  - It collects every live name that begins with `<team>-`, for the derived
    team name and for any team name the user then chooses.
  - The team-name question's option for a name with collisions carries the
    renames in its label, for example "claudetools (architect →
    claudetools-architect-2)".
  - Once the team name is settled, the skill **captures the set once** and
    passes it **unchanged** to every later phase.
  - It must **not** re-read ListAgents after `--spawn`. By then the team's
    own new sessions are live, and re-reading would rename them again at
    `--commit`.

### 3.2 (ii) How the suffix is chosen

- This happens in **one place in the CLI**: immediately after
  `rosterMemberNames` derives the plan's names, so every phase and the
  `--commit` hydration by name share it.
- Walk the members in roster order. A member whose derived name
  **exactly equals** a `--names-in-use` value (Q2c) gets
  **`<team>-<role>-<n>`**. That is always built on the role base, never by
  appending to an already-suffixed name, so it is never `x-implementor-2-2`.
  n is the smallest integer ≥ 2 for which that name is:
  - not in `--names-in-use`;
  - not already assigned to an earlier member of this plan;
  - not the derived name of any later member that is not itself
    colliding;
  - (r3, spawn verbs) not the name of any current member record of the
    target team.
- Members that do not collide keep their derived names. So when a roster
  has two architects and the plain name is taken, the first becomes `-3`
  and the second stays `-2`. The rule is "only colliding members change".
- **0057 §2.8's team-name check runs on the final names.** A suffix makes a
  name longer and can fail Herdr's length limit. That gives today's
  `team-name-unusable` refusal, with `failing_member` naming the suffixed
  member. Precedence is unchanged.

### 3.3 (iii) The plain-name rule and 0057's naming

- Every name stays in 0057's grammar, `<team>-<role>[-<n>]`. So
  `roleFromName`, prefix matching and the team scope keep working.
- What R2 gives up is only the convention that a role's first member
  carries the plain name. A renamed member's team-file record gains
  **`renamed_from: "<derived name>"`**. Nothing else is added to the record.
- The roster is untouched: names are never stored there.
- History stores no names, so it is unaffected.
- Output of every create phase gains
  **`renamed_members: [{name, role, renamed_from}]`**, present only when
  non-empty. Goldens are unchanged, because the fixture passes no
  `--names-in-use`.
- **`create --commit --verified <objects>` (r4, C).**
  - It re-derives the renames from its own `--names-in-use`, through the
    same step (§3.2).
  - It stamps `renamed_from` on each verified member whose name and role
    match a renamed member.
  - Member objects in the `--plan` and `--spawn` output do not carry
    `renamed_from`; only `renamed_members` does.
  - The skill's capture-once rule (§3.1) is what makes `--commit` derive
    the same renames.

### 3.4 (iv) Messages reach the suffixed member, not the old session

- **Route gate (new check).** An Orchestrator SendMessage whose `to`, with
  `[ref]` stripped, equals a `renamed_from` in the resolved team, and that
  carries **no** `[ref]`, is **denied** with the correction: "<to> is not in
  your team; its <Role> is <name>. SendMessage \"<name>\". To reach the other
  session on purpose, address it with its [ref]." (OQ-2.)
  - This is the mechanical guarantee. The directive's plain-name target
    lines (`resolvedPeerTargets`) are left as they are: they are built at
    SessionStart, usually before the team exists, and the gate corrects any
    stale use.
  - (r4) **Never deny a name the team itself holds.** A `to` that is also
    the name of a current record in that team passes this check. The §3.6
    claim rule can give a member `renamed_from` equal to another member's
    name.
  - (r4, E) **Scope and order.**
    - The check applies to every Orchestrator SendMessage. It runs
      **before** the brief-sentinel early return, because a brief sent to
      the wrong session is exactly the harm it exists to stop.
    - `renamed_from` is looked up only in the session's resolved team file.
- **Ultra-gate (required, or R2 opens an approval bypass).** The SendMessage
  branch also gates any `to` equal to the name of a **resolved-team member
  whose role is advise-class**, alongside today's plain-name matches.
  - That covers a renamed Ultra-Advisor and closes the existing
    second-instance gap.
  - The team-file lookup it needs is the same one the route gate already
    uses. Reuse it, and do not add another reader.
  - **(r4, G amended to G1) The lookup's scope matches the ultra-gate's
    `gatedPrefixes` exactly.**
    - This withdraws r4's "every team file" scope, which silently reversed
      0011 §7.10 and broke test-roster-multi-team.sh 17b and 20. Those
      tests are unchanged.
    - **Resolved team:** when `resolved.team` resolves, the lookup covers
      that team's members only. A sibling team's Ultra-Advisor stays
      ungated.
    - **Unresolved, with named teams:** when `resolved.team` is null and
      named teams exist, it covers the default team plus every named team.
      This is 0011 §9.5's predicate (ii): the session cannot tell which
      team is its own, and over-gating is the safe direction.
    - **No named teams:** it covers the default team only.
    - **(r5) The suffixed-name pattern, which needs no team file.**
      - Alongside the record lookup, which stays, the gate also gates a
        `to`, `[ref]` stripped, that exactly matches
        `<peerName(prefix, r)>-<one or more digits>`. That applies for
        every prefix in `gatedPrefixes` and every advise-class role r.
      - **Why:** `create --spawn` launches a renamed Ultra-Advisor before
        any team file exists, because `--commit` writes it. Without the
        pattern, a SendMessage to it goes ungated in that window, and
        indefinitely if `--commit` never runs. That would make the gate
        weaker than it was before 0060.
      - The pattern also gates an unrecorded second instance.
      - It is safe under 0057's grammar: `<team>-<role>[-<n>]` makes any
        such name an advise-class member of that prefix. An outside session
        that happens to match is over-gated, which is the safe direction.
      - Its scope is the same as G1's, since it is built only from
        `gatedPrefixes`.
    - The route gate's `renamed_from` check keeps its own scope, the
      resolved team (E). Sharing a reader does not mean sharing a scope.
    - **Why 0011 scoped it this way, and why it still holds:** the gate is
      a per-session escalation control, not a repo-wide firewall.
      Cross-team messaging is out of scope (0011 §7.10, §8). A sibling
      team's Ultra-Advisor is spent under its own Orchestrator's approval.
      0060 changes how names are matched, not what the user's approval
      covers.
- The spawn and create outputs already print real names, and the skill's
  notice (v) names them.

### 3.5 (v) The user is told, in one line

After any create phase whose output has `renamed_members`, the skill tells
the user one line per team, and asks nothing:

"Renamed <renamed_from> → <name> (and …): another session already holds
that name."

(r4: the text was "a live session outside this team". It changed because
the §3.6 claim rule can rename a member whose derived name is held by one of
the team's own members.)

(r3) The same line follows any spawn-one or spawn-ad-hoc whose output has
`renamed_members`.

### 3.6 spawn-one and spawn-ad-hoc (r3, OQ-1 ruled YES)

- **Both verbs take `--names-in-use <name>`**, repeatable, and apply **the
  same renaming step** as create, from one shared implementation.
  - spawn-one follows "spawn-one's order" below (r4, B1).
  - spawn-ad-hoc renames the new member's derived ordinal name.
  - The output carries `renamed_members`, and the team record carries
    `renamed_from`, exactly as for create.
  - (r4, F) `renamed_members` lists only members whose name changed in
    this run. A respawn under a record's existing name emits none.
- **The team's own names are not outside names (r4, A2).** A
  `--names-in-use` value is ignored for renaming only when it equals the
  name of a current record of the target team that the existing liveness
  check (`memberLiveness`) finds **live** or **indeterminate**.
  - **Live:** today's "already live" refusal fires, with no rename and no
    launch (N12).
  - **Indeterminate:** the record is not renamed. Today's indeterminate
    refusal fires if that member is selected.
  - **Found not live:** an outside session holds the name, and the record
    is renamed in place (see "Respawning" below).
  - **Why:** the exclusion exists only so that the team's own live
    sessions, which ListAgents also shows, reach the "already live"
    refusal. A record that is not live cannot be the session ListAgents
    shows under that name.
- **spawn-one's order (r4, B1).** It covers every roster member of the
  role, in roster order, the same way create does:
  1. **Derive** names with `rosterMemberNames`.
  2. **Claim records.** Each record is claimed by at most one member.
     - First, a member whose derived name equals a record's `renamed_from`
       takes that record and its name.
     - Then, a member whose derived name equals the name of a record no one
       has claimed takes that record.
  3. **Rename** by §3.2's rules. `renamed_from` is always the member's
     **derived** name, never an intermediate one. A member collides when
     either:
     - its name after step 2 is in `--names-in-use`, less the own exclusion
       above; or
     - its derived name equals the name of a record another member claimed
       in step 2. This happens when the roster gained a same-role member
       after an earlier rename.
  4. **Select** exactly as today, on the final names:
     - `--member` matches a final name, and its "no member named" error
       lists final names;
     - otherwise the sole candidate;
     - otherwise the first candidate that is not live;
     - otherwise the last candidate.
  5. **Refuse or respawn:** today's liveness refusals and existing-record
     lookup run unchanged, on the selected member's final name.
- **Respawning a renamed member, while its record exists** (for example its
  pane died):
  - Step 2 gives the candidate the record's name, for example
    `x-architect-2`. Today's existing-record path then runs under that
    name: the "already live" refusal if the record is live, or a respawn
    that updates it in place.
  - `renamed_from` is kept. No new record is added.
  - This holds with or without `--names-in-use`.
  - (r4, A2) **The record is renamed again, in place,** when it is not live
    and its name is in `--names-in-use`: an outside session took the name
    while the record was dead.
    - It gets the next free `<team>-<role>-<n>` and keeps `renamed_from`,
      which is still the derived name.
    - It is listed in `renamed_members`. No new record is added.
    - A dead record with a plain name is renamed the same way when its name
      is in `--names-in-use`, and gains `renamed_from` at that point.
    - The record's previous name is not kept anywhere (§8).
- **After the record is removed (dismiss or untrack),** the link is gone.
  `renamed_from` lives only on the team record and **does not persist**
  past it: the roster stores no names. A later spawn-one derives the plain
  name again and renames only against the `--names-in-use` it is given now.
  - If the outside session still holds the plain name, it gets the smallest
    free suffix again, with a fresh `renamed_from`.
  - If that session has exited, it gets the plain name.
  - If the Orchestrator omits `--names-in-use`, the plain name is used and
    can duplicate an outside session's name. That is the limit of D1: the
    CLI cannot see ListAgents. spawnReason (below) is what prevents it.
- **`spawnReason` (pretooluse-route-gate.mjs) gains one line** after its
  `Run:` line: "Before running it, run ListAgents and add
  `--names-in-use <name>` for every live name that starts with `<team>-`."
  - `<team>` is the resolved team prefix the gate already computes.
  - The existing "SendMessage the `name` the command prints" already covers
    a renamed result.

## 4. Files

| File | Change |
|---|---|
| hooks/roster.mjs | `refuseLiveDefaultTeam` text; `dismiss` close path reuses `reconcileAfterClose` plus the `team_removed`/`team_will_be_removed` output; `untrackMember` clears on the last member; `--names-in-use` on every create phase, plus the suffix step after `rosterMemberNames`; `renamed_from` on team records; `renamed_members` output |
| hooks/lib-ah-cli.mjs | (r4, G) unchanged: value flags need no entry in its tables. The drift test must stay green. |
| hooks/pretooluse-route-gate.mjs | the `renamed_from` SendMessage check (§3.4); `spawnReason`'s ListAgents / `--names-in-use` line (§3.6, r3) |
| hooks/roster.mjs (r3) | `--names-in-use` on spawn-one and spawn-ad-hoc, through the shared renaming step; the own-member exclusion; the respawn of a renamed record by `renamed_from` (§3.6) |
| hooks/pretooluse-ultra-gate.mjs | gate advise-class team-member names (§3.4), reusing the route gate's team-member reader, scoped exactly as `gatedPrefixes` is (r4, G1); plus the `<prefix>-<advise role>-<n>` pattern over `gatedPrefixes` (r5) |
| skills/agent-team/SKILL.md | dismiss and untrack can end a team; the D1 ListAgents check, the rename labels in the team-name question, the capture-once rule, and the one-line rename notice. **(r5)** Every step that matches, checks, verifies or selects a member uses the member's `name` as the CLI printed it, renamed or not, and never its derived name. After a rename, the derived name belongs to the live outside session. Checking it would verify the wrong session, `--verified` would record it, and the route gate would stop denying it. Known sites (line numbers per the review): step 4's "match each spawned member's derived name" (:462) becomes "match each member's `name` as `--spawn` printed it (renamed or not)"; "returns each member's derived name" (:230); "show the derived names" (:267); and "`--member` … by its derived name" (:701-702), which becomes the final name as spawn output or the team record shows it (§3.6 B1). |
| docs/cli-tools.md | `--names-in-use`; the new output fields |
| tests/ | §6 |
| plugin.json and root marketplace.json | version bump together |

## 5. Must not change (any option)

- `disband` and `untrack --all` behaviour and output.
- spawn-one and spawn-ad-hoc per-member liveness refusals.
- 0057's owned-team liveness rule for teams **with** members.
- 0057 §2.8's team-name check and its precedence. It now runs on the
  final, suffixed names (§3.2).
- The directive's `resolvedPeerTargets` target lines and every directive
  golden.
- **The one golden exception (r3).** gate-route-{architect,reviewer,implementor,ultra-advisor}.json
  (0059 r5's `spawnReason` goldens) gain exactly the §3.6 ListAgents /
  `--names-in-use` line. Nothing else in them changes, and
  gate-route-task-runner.json is unchanged.
- No detection in the CLI: nothing reads ListAgents, herdr lists or
  peers.jsonl for renaming. Only `--names-in-use` drives it.
- 0058 and 0059 behaviour.
- No golden changes are expected. The fixture has no live sessions or empty
  teams. The Implementor reports any golden change with its reason.

## 6. Acceptance

- **any (r4, H: premise corrected).**
  - **Owned by the invoker.** With the invoker's own empty team at the
    default scope, a bare `create --plan` gets `refuseOrClearExistingTeam`'s
    generic refusal. Its text says the team has no members and names
    `disband`.
  - **Held by another live pid.** When another live pid holds an empty
    default-scope team, `refuseLiveDefaultTeam` fires instead. It says the
    team has no members and names `disband`, and the "members are
    dispatched" wording is gone.
  - With members present, both texts are unchanged.
- **L1 (1A).** `spawn-ad-hoc … --team walk`, then
  `dismiss walk-<m> --close --confirm …`:
  - no `teams/walk.json` remains, and the output has `team_removed:true`;
  - the dismiss plan phase showed `team_will_be_removed:true`;
  - a following `create --team walk --plan` succeeds;
  - no history row is written.
- **L2.** Dismissing a member that is not the last leaves the file with the
  rest, and the output has no `team_removed`.
- **L3 (Q1b).** `untrack <last member>` clears the file and reports
  `team_removed:true`. The session is untouched, so the pane is still up.
  The old "no members left" warning is gone.
  - (r4, G) `team_empty` is still reported.
  - test-roster-dismiss.sh #13 asserts that team.json survives the last
    untrack. L3 reverses that behaviour, so #13 is reversed with it.
- **N1 (i, ii).** A roster with architect, reviewer and implementor, then
  `create --team x --plan --names-in-use x-architect`:
  - the architect is `x-architect-2`, and the others keep their derived
    names;
  - `renamed_members:[{name:"x-architect-2", role:"architect", renamed_from:"x-architect"}]`.

  With `--names-in-use x-architect --names-in-use x-architect-2`, the
  architect is `x-architect-3`.
- **N2 (ii).** A roster with two architects plus
  `--names-in-use x-architect`: the first architect becomes `x-architect-3`
  and the second stays `x-architect-2`.
- **N3 (Q2c).** `--names-in-use x-architect-2` alone, with one architect:
  no rename, because only an exact match collides.
- **N4 (ii).** A team name long enough that the suffix breaks Herdr's limit:
  `team-name-unusable`, with `failing_member` naming the suffixed member.
- **N5 (iii).**
  - Through `--spawn` and then `--commit --verified <names>` with the same
    `--names-in-use`, the team file records `x-architect-2` with
    `renamed_from:"x-architect"`.
  - Hydration by name finds it.
  - The roster file is byte-identical.
  - The history entry carries no names.
- **N6 (iv), route gate.** With that team, an Orchestrator
  `SendMessage(to:"x-architect")`:
  - is denied, and the text names `x-architect-2`;
  - `to:"x-architect [abc123]"` passes;
  - `to:"x-architect-2"` passes the route gate's rename check.
- **N7 (iv), ultra-gate.** A renamed Ultra-Advisor `x-ultra-advisor-2`, with
  no gate decision: a SendMessage to it is gated (the first-use deny). The
  same holds for an unrenamed second instance `x-ultra-advisor-2`.
  - (r4, G1) The session is team T's Orchestrator and resolves T. Sibling
    team U has `U-ultra-advisor-2` (renamed). A SendMessage to it is
    **not** gated.
  - (r4, G1) A session that does not resolve its team, with T and U both
    present: that same SendMessage **is** gated.
  - test-roster-multi-team.sh 17b and 20 pass unchanged.
- **N7b (r5), the pattern gate, with no team file.** In repo `q`, with no
  team file and no gate decision:
  - **Gated:**
    - a SendMessage to `q-ultra-advisor-2`, which is what a bare
      `create --spawn --names-in-use q-ultra-advisor` launches before
      `--commit`;
    - the same with a `[ref]`;
    - a SendMessage to `q-ultra-advisor-3`, an unrecorded second instance.
  - **Not gated by the pattern:**
    - `q-ultra-advisor-2x`;
    - `q-ultra-advisor-2-architect`;
    - `q-architect-2`.
  - **Scope.** The session is team T's Orchestrator and resolves T. A
    SendMessage to `U-ultra-advisor-2` is not gated when U has no file
    recording it: the pattern does not widen G1's scope.
- **N8.** With no `--names-in-use`, every create, spawn-one and spawn-ad-hoc
  output is byte-identical to pre-0060. The only golden change is §5's r3
  exception.
- **N9 (r3).** No team record for the architect, then
  `spawn-one architect --names-in-use x-architect`:
  - it launches `x-architect-2`, with a record carrying
    `renamed_from:"x-architect"`;
  - the output has `renamed_members`.
- **N10 (r3), respawn with the record present.** The team has `x-architect-2`
  (`renamed_from:"x-architect"`) with a dead pane. `spawn-one architect`, run
  with and without `--names-in-use x-architect`, respawns as `x-architect-2`:
  - the same record is updated;
  - `renamed_from` is kept;
  - the team has no other architect record.

  If the record's pane is live, the result is today's "already live" refusal.
- **N11 (r3), respawn after removal.** Dismiss `x-architect-2`, which ends
  its record, then:
  - `spawn-one architect --names-in-use x-architect` gives `x-architect-2`
    with a fresh `renamed_from`;
  - with the outside name absent from `--names-in-use`, it gives the plain
    `x-architect`, with no `renamed_from`.
- **N12 (r3), own names excluded.** The team has a live `x-reviewer`, then
  `spawn-one reviewer --names-in-use x-reviewer` gives today's "already
  live" refusal, with no rename and no launch.
- **N13 (r3), spawn-ad-hoc.** The team has `x-implementor` and
  `x-implementor-2`, then `spawn-ad-hoc implementor --model opus --names-in-use x-implementor-3`:
  - it launches `x-implementor-4`, with `renamed_from:"x-implementor-3"`;
  - it never produces an `-n-n` name.
- **N14 (r3), spawnReason.** The route-gate text for a chain role with no
  live peer contains the ListAgents / `--names-in-use` line, with the
  resolved `<team>-` prefix.
- **N15 (r4, A2), re-rename in place.**
  - The team has `x-architect-2` (`renamed_from:"x-architect"`) with a dead
    pane. `spawn-one architect --names-in-use x-architect --names-in-use x-architect-2`
    gives the following:
    - the same record now has the name `x-architect-3`;
    - `renamed_from` is still `"x-architect"`;
    - `renamed_members:[{name:"x-architect-3", role:"architect", renamed_from:"x-architect"}]`;
    - the team has no other architect record.
  - **Plain variant.** The team has a dead `x-architect` with no
    `renamed_from`, and the command is
    `spawn-one architect --names-in-use x-architect`. The same record
    becomes `x-architect-2` with `renamed_from:"x-architect"`.
  - **Live variant.** The same record is live, and the command is the same.
    The result is today's "already live" refusal, with no rename.
- **N16 (r4, B1), rename before selection.** The roster has two
  architects, the team has no records, and the command is
  `spawn-one architect --names-in-use x-architect`:
  - it launches the first architect as `x-architect-3`, with
    `renamed_from:"x-architect"`;
  - with `--member x-architect-2`, it launches the second architect
    unrenamed, and the record matched is that architect's own;
  - with `--member x-architect`, it fails, and the error lists
    `x-architect-3, x-architect-2`.
- **N17 (r4), claim rule.** The roster has two architects. The team has a
  live `x-architect-2` (`renamed_from:"x-architect"`) and no second
  architect record.
  - `spawn-one architect`, with no `--names-in-use`:
    - it launches the second architect as `x-architect-3`, with
      `renamed_from:"x-architect-2"`;
    - the `x-architect-2` record is untouched.
  - Then an Orchestrator `SendMessage(to:"x-architect-2")` passes the route
    gate's rename check, because the name is a current record of the team.
- **N18 (r4, E).** The N6 deny also fires for a SendMessage carrying the
  brief sentinel.
- **K1 (D1, v).** Text checks on agent-team SKILL.md:
  - it runs ListAgents before the team-name question;
  - it compares exact names with `[ref]` stripped;
  - it labels the renames in the question;
  - it captures the set once and passes it unchanged to every phase, never
    re-reading after `--spawn`;
  - it gives the one-line rename notice;
  - (r5) the create verification step matches each member's `name` as
    `--spawn` printed it, "renamed or not";
  - (r5) `--member` is described as taking the final name;
  - (r5) no step tells the driver to match, check, verify or select a
    member by its "derived name". The phrase may still describe what
    renaming starts from.

## 7. Rulings (r2) and open questions

**Ruled:**

- **Q1: 1A.** Q1b clears. Q1c writes no history. Q1b and Q1c take the
  recommendations; the user was not asked them.
- **Q2a: D1.**
- **Q2b: R2**, the user's knowing choice against the recommendation.
- **Q2c: exact matches only.**

- **OQ-1 (r3): YES.** spawn-one and spawn-ad-hoc take `--names-in-use`,
  with the same renaming, and spawnReason tells the Orchestrator to add it
  (§3.6).
- **OQ-2 (r3): deny.** A plain-name SendMessage without `[ref]` to a
  `renamed_from` name is denied, with the correction. With `[ref]` it passes
  (§3.4).

- **A (r4): A2.** "The team's own" means a record found live or
  indeterminate. A record found not live, whose name is in
  `--names-in-use`, is renamed in place (§3.6).
- **B (r4): B1.** spawn-one claims records and renames across the whole
  roster before it selects. The claim rule is added (§3.6).
- **C–G (r4):** the Implementor's defaults are confirmed, as recorded at
  each point of use.

No open questions remain.

- **Noted, not a question.** The ultra-gate change in §3.4 also closes a
  gap that exists today: a second Ultra-Advisor instance (`-2`) is not
  gated. R2 needs the change, so it is in scope.

## 8. Noted, not specified here

- **`partial` is never recomputed** after spawn-one, dismiss or untrack. The
  live `ct.json` has `partial:true` with three members. Who reads `partial`,
  and whether it should be recomputed, is a separate question.
- **spawn-one's per-member liveness** finds names only through team files,
  so it has the same blind spot as D2 for sessions not in any team file.
  Under D1 that stays as it is.
- **(r4) A re-renamed record's previous name is not gated.** When
  `x-architect-2` is renamed in place to `x-architect-3` (§3.6, A2), a stale
  plain SendMessage to `x-architect-2` reaches the outside session that now
  holds that name.
  - The route gate's check covers only `renamed_from`, which is the derived
    name.
  - What mitigates it: the spawn output prints the new name, and the skill
    shows the rename notice.
  - Closing it would need a record of every previous name. That is not
    specified until the gap is seen in use.
- **(r5) The route gate reads `renamed_from` from `hierarchyDir(cwd)`, not
  from a worktree's team home.**
  - An Orchestrator whose cwd moved can therefore miss a `renamed_from`
    record. It loses only that deny, the rename correction.
  - It never loses an approval: the ultra-gate's pattern (§3.4) needs no
    team file.
