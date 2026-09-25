# 0061 — Follow-up hygiene: test env, bad roster rows, orphaned live teams, `partial`

Status: r4, final and ready for implementation. Base: 0.91.0 (1bd09ad).

**r4:** §3.4 is replaced. A missing team file never decides identity,
because members legitimately launch before the commit writes it. Only
readers that need the file's content treat a missing file as "no record",
and none may error. O7 is rewritten to match, and O7b and O7c are added.

**Rulings:**

- OQ-1: no; `--names-in-use` stays optional.
- OQ-2 (`track`): no.
- All of §6's decisions are accepted.

**Final (r3).** §3.6's and §3.7's evidence is folded in:

- ct's records are dead, and no fourth session exists.
- 0.91.0 cannot mismatch a member's name and its team file, except
  through a theoretical race and a hand-edited record. §3.7 adds one cheap
  invariant at `spawnShape` for those.

Ready to build.

r2 applies the Orchestrator's §3.5 evidence. For ct, the names **and** the
panes differ from the live sessions, and the only link is `AH_TEAM_FILE`.
§3 therefore changes:

- It gains `attributed_live`: sessions that claim the team through their
  environment only.
- reap keeps an orphan while such sessions live.
- Adopting is never suggested when the only link is the environment.
- A dangling `AH_TEAM_FILE` must read as unset.
- ct is resolved by waiting, not by adopting.
- OQ-2 is added.

Implementer: implementor
Reviewer: reviewer

Four independent items. Each has its own acceptance, and they can land in
any order.

## 1. Tests must not inherit `CLAUDE_PID`

### Facts

- These checks fail when `CLAUDE_PID` is absent and pass inside a Claude
  session, which exports it:
  - test-custom-roles.sh T1, T13 and T16 (T16 also fails at base);
  - test-role-contract.sh C10 (both halves) and C16;
  - the "invariant" check at test-roster-layout-splits.sh:236;
  - test-roster-surface-split.sh check 7.
- The CLI reads `CLAUDE_PID` as the orchestrator pid whenever
  `--orchestrator-pid` is absent:
  - roster.mjs:2262, :3211, :3387, :3836-3844 and :4476;
  - msg.mjs:124, :272 and :293;
  - doctor at roster.mjs:527-533 reports it red when unset.
- `AH_TEAM_FILE` has a precedent. 20+ suites start with
  `unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it`
  (for example test-agent-frontmatter.sh:10).
  test-orchestrator-identity.sh:29 and :44 already use `env -u CLAUDE_PID`.
- No suite sources a shared helper, and there is no runner script.

### Requirement

- **Never inherit.** Every suite that already unsets `AH_TEAM_FILE`, plus
  the four suites above, also unsets `CLAUDE_PID` at its top, with the same
  style of comment.
- **Set explicitly where needed.** A suite whose checks need an orchestrator
  pid sets `CLAUDE_PID` itself, or passes `--orchestrator-pid`, to the value
  that check intends:
  - `$$` when the fixture is meant to be owned by the invoker;
  - otherwise a live pid that matches no fixture. That reproduces what
    the check sees inside Claude, where `CLAUDE_PID` is an ancestor
    process. For example, a background `sleep` the suite starts and kills
    on exit.
  - Pick per check, never by blanket export. A blanket `CLAUDE_PID=$$`
    would make every fixture written with `pid: $$` owned by the invoker,
    and would change what those checks test.
- **Record the dependency.** For each failing check listed above, the
  change states in one line which value it needs, as a comment at the point
  where it is set. The Implementor diagnoses this per check.
- **Lint against drift.** One cheap check fails if any tests/*.sh unsets
  `AH_TEAM_FILE` without also unsetting `CLAUDE_PID`. Put it in an existing
  meta-suite, such as the one that already scans tests/ or docs, or in a
  new small suite.

### 0059's K1 collides with this item (r4)

**The collision.** K1 (test-subagents-legwork-only.sh:231) runs
`git diff --quiet HEAD -- agents tests/test-directive-size.sh`. §1 adds
`unset CLAUDE_PID` to test-directive-size.sh, so K1 fails in every run
before this change is committed.

**The ruling: replace K1's HEAD comparison with the invariant it stood
for.**

- **Why not a HEAD diff.** Now that 0059 is committed, the diff guards
  nothing specific to 0059, and it fails on every future edit to those
  files until that edit is committed.
- **Why not a content hash against fe21040 for agents/*.md** (the
  Orchestrator's other suggestion). "0059 left agents/*.md unchanged" is
  now settled history that git already records. A permanent hash pin would
  turn every legitimate later edit into a test edit, and 0062 will edit
  agents/orchestrator.md. The agents/*.md size budgets already bound those
  files.
- **The new K1.** It pins each budget constant to its current value:
  - the directive budgets in test-directive-size.sh (auto 14600, confirm
    16500);
  - every agents/*.md budget, wherever its test defines it, including
    orchestrator.md's 7350.
  - It reads the constants from the test files and fails if any is
    raised.
  - Raising a budget stays possible, but only by also editing K1, which
    makes it a deliberate, reviewed act.
- test-directive-size.sh gets §1's `unset CLAUDE_PID` like every other
  suite, with no lint exception.

**For the record, two 0058 test collisions were resolved without
weakening either test (r4):**

- D2's `! grep relaunch`: the §3.3 skill text is worded without that word.
- B6c: the stored `partial === false` became the derived
  `teamIsPartial(…) === false` (§4.1). That is stricter, because `null`
  also fails.

### Acceptance

- **T-H0 (r4).** The new K1 fails when any pinned budget constant is
  raised in a scratch copy, and passes on the tree before and after this
  change is committed.
- **T-H1.** Every suite named in the facts passes under
  `env -u CLAUDE_PID bash tests/<suite>.sh`. It also passes under
  `CLAUDE_PID=<a live, unrelated pid>`.
- **T-H2.** The whole tests/ directory passes the same way under both
  environments.
- **T-H3.** The lint fails on a scratch suite that unsets only
  `AH_TEAM_FILE`, and passes on the real tree.

## 2. `roster.members` entries that are not objects

### Facts

- `rosterMemberNames` (lib-config.mjs:731-739) dereferences `m.role`, so
  `members: [null]` throws `TypeError` from `resolveConfig`.
- Roster blocks are parsed in `resolveRoster` (lib-config.mjs:876-895). It
  catches parse errors and validates shape, but not each element.
  `loadScope` (:1105-1128) reads config scopes, with warnings.
- 0059 §2.1.8's test G6 (b) uses exactly this crash as its "throw inside
  config resolution" injection (test-subagents-legwork-only.sh:132-184).
  0059 §8 requires that the change fixing the crash also either replaces
  that injection or drops that half of G6.

### Requirement

- **Skip, with a warning, at read.** Wherever a roster block's `members`
  array is read from disk, drop every element that is not a plain object:
  `null`, arrays, strings, numbers and booleans.
  - Do this in one normalization point, so every consumer sees only
    objects: `rosterMemberNames`, role resolution, the route gate and CLI
    verbs.
  - The survivors keep their order. A dropped element has no role, so
    same-role ordinals, and therefore derived names, do not shift.
- **Why skip rather than reject.** One bad row must not disable a team.
  Hooks must never crash on config, because a crash in the route gate
  fails closed for built-in chain refs (0059 §2.1.8), and a bad config row
  should not have that effect.
- **Where the warning goes.**
  - Text: "roster `<file>`: `members[<i>]` is not an object (`<type>`);
    ignored".
  - It uses the existing CLI warning channel, the one 0059's stale-key
    warnings use (`staleTeamKeys`, reported in `warnings` by
    status/doctor/create). Extend that channel; do not add a second one.
  - It never goes into session context or hook output.
- **Cleaned on the next write.** `writeLevelFile`'s migrate-on-write
  (0059 §2.3) also drops such elements, so the file is cleaned by the next
  CLI write, as stale keys are.
- **Out of scope:** objects without a string `role`. They do not crash
  today, and existing validation reports them.

### G6 (b)'s replacement injection

- **Mechanism.** A test-only Node module-customization hook, loaded with
  `node --import <fixture>` on the gate's command line only in G6 (b).
  - It rewrites `hooks/lib-config.mjs`'s source as it loads, so that
    `resolveConfig` throws on entry.
  - It must fail loudly if it cannot find `resolveConfig` in the source,
    by exiting non-zero or making the check fail. A rename must turn G6 (b)
    red, never let it pass vacuously.
- **Why this one.** Every input-based injection, such as malformed config
  or a bad file shape, is exactly what hardening like this change removes,
  which is the trap 0059 §8 records.
  - A load-time rewrite puts no test seam in product code.
  - It stays a throw inside config resolution for as long as the gate
    calls `resolveConfig` inside its `try`, and that is precisely what
    G6 (b) exists to pin.
- G6 (b)'s assertions are unchanged: the fail-closed deny for the five
  built-in refs, deny text built from the input, and fail-open for
  everything else.
- **Assumption, not verified.** The repo's Node supports `module.register`
  (Node ≥ 20.6 or 18.19). If it does not, use `--experimental-loader` with
  the same rewrite. Either way the product code does not change.

### Acceptance

- **R1.** With `members: [null, {role:"architect"}, 7]`, every roster and
  status verb exits normally:
  - the architect member is present as `<prefix>-architect`;
  - `warnings` names indices 0 and 2;
  - a route-gate run on that config produces the same decision as it does
    without the bad elements, and no hook-error log entry.
- **R2.** The next `add` or `edit` at that level rewrites the file without
  the bad elements.
- **R3.** G6 (b) passes with the new injection. Deleting the rewrite target
  makes the fixture fail loudly.
- **R4.** The old `members:[null]` input now takes G6's normal path, not
  the catch.

## 3. An orphaned team whose members are live and serve another orchestrator

### Facts

- `.claude/hierarchy/teams/ct.json` (team_id 20260922-205150-ha7g, herdr):
  - `orchestrator.pid` is 62782, which is dead;
  - its members are `ct-architect`, `ct-implementor` and `ct-reviewer`, all
    route peer;
  - it has `partial: true`.
- The live Implementor was launched with `AH_TEAM_FILE` pointing to that
  file, which `spawnShape` sets on every claude member it starts
  (roster.mjs:1576).
- **`adopt --orchestrator-pid <pid> [--team <t>]`** (roster.mjs:4444-4470)
  already does the takeover:
  - it requires the given pid to be live;
  - it refuses when the current owner is alive and different;
  - it re-stamps only `orchestrator.pid`;
  - it does not touch members or `team_id`, and it closes nothing.
- **`reap [--commit]`** (roster.mjs:4673-4692) takes every orphaned team
  (`allTeamRows(dir, null).filter(t => t.orphaned)`) and, with `--commit`,
  runs `clearTeam` on each. It closes no pane.
  - It does **not** look at member liveness. On a team like ct it forgets
    the records of live sessions.
  - Those sessions keep an `AH_TEAM_FILE` that now names a missing file.
  - The live orchestrator also loses them, so a later spawn-one can launch
    a duplicate.
- **Who a session is serving is already observed.** `whoami`'s
  `last_observed_brief: {from, from_name, reply_to, ts}` comes from
  `~/.claude/agent-hierarchy.peer-pending.jsonl`, and it is best-effort
  (docs/cli-tools.md, whoami row).
- Liveness per member already exists: `memberLiveness` (roster.mjs:2744-2750)
  uses peers.jsonl for claude members and `herdr agent get` for others.
- **(r2) ct's actual state,** from the Orchestrator's reading:
  - ct's records are `ct-architect` on w16:p9, `ct-implementor` on w16:pA
    and `ct-reviewer` on w16:pG. Whether those panes are alive is
    unverified; `teams` does not list them as live members.
  - The live sessions are `claudetools-architect` on pP,
    `claudetools-implementor` on pQ and `claudetools-reviewer` on pS. They
    are served by the live Orchestrator claudetools-d5. **Neither their
    names nor their panes match any ct record.**
  - The only link is their launch environment, `AH_TEAM_FILE=…/teams/ct.json`.
    `teams` shows them as ct's `untracked_live` rows: live sessions whose
    peers.jsonl rows carry ct's team tag and that have no record.
- **(r2) Who reads `AH_TEAM_FILE` inside a running session:**
  - `envTeamFile` (lib-roster.mjs:591);
  - `attributeSessionTeam` (sessionstart.mjs:139), which runs again on
    compact or resume;
  - `createMessage`'s `team_file` fallback;
  - `whoami`, which already refuses to follow a value that is not this
    repo's team file (`env_team_invalid`).
  - The ultra-gate and msg-gate return early in role sessions. The route
    gate's peer-side rule, that a role session never dispatches an ah role,
    does not depend on the team.

### Verdict: does reap or adopt already cover it?

- **Adopt covers the takeover only when the records are the live
  sessions.** Nothing is killed and the members are untouched, and
  afterwards the members' `AH_TEAM_FILE` is valid again.
- **(r2) Adopt is harmful when the link is only the environment,** as for
  ct:
  - the adopter's team becomes ct, whose records are dead;
  - the route gate's spawnReason and `spawn-one` then target
    `ct-architect` and the others;
  - a duplicate of every live role would be launched.
- **Reap does not cover it safely.** It clears orphans without looking at
  liveness or at environment attribution.
- **Nothing reports either case.** No output says that an orphaned team has
  live members, or sessions claiming it.

### 3.1 Report live members of orphaned teams

- `teams` and the `reap` plan add, for each orphaned team,
  `live_members: [{name, role, last_brief_from}]`. The list holds only
  members that `memberLiveness` finds live.
  - `last_brief_from` is that session's latest peer-pending row's
    `from_name`, else `from`, else null. It is labelled best-effort in
    cli-tools.md.
  - The field is absent when no member is live.
- Liveness is asked with the existing function. An **indeterminate** member
  is listed with `indeterminate: true`, never dropped. Dropping it would
  read as "not live".
- **(r2) `attributed_live: [{name, role, pane_id, last_brief_from}]`.**
  These are live sessions that claim this team through their environment
  and have no record.
  - They are exactly the rows `teams` already reports as that team's
    `untracked_live`, drawn from the same source; do not add a second
    reader.
  - The field is absent when there are none.
  - **(r5, Reviewer nit; r6 clarified) The legacy `team.json` (tag null)
    never has `attributed_live`.** Neither of its arms is a positive
    claim:
    - an untagged peers row cannot be told apart from a session never
      launched with `AH_TEAM_FILE`;
    - the legacy name prefix is the repo basename, which plain
      role-session names share.
    A legacy orphan is kept only by `live_members`.
  - **(r6) A named team keeps its whole `untracked_live`,** both arms:
    - peers rows tagged with that team;
    - Herdr rows matched by the `<t>-` name prefix (`source: "herdr"`).
    §3.7's invariant makes `<t>-<role>[-<n>]` a claim on team t. A
    non-Claude member (0062) writes no peers row, so the name is its only
    link.
    - r5's "explicitly tagged only" wording was wrong for named teams.
    - The environment-only `why` becomes "live sessions claim this team
      (through AH_TEAM_FILE or a `<t>-` Herdr name) but match no record…";
      the rest is unchanged.
  - `teams`' `untracked_live` is unchanged.
  - Tests:
    - the legacy orphan with dead records and one live untagged
      `reviewer@sid-x` → no `attributed_live`, and `reap --commit` clears
      it;
    - **O6c (r6):** a named orphan whose only live link is a Herdr-only
      `<t>-reviewer` → it is in `attributed_live`, and `reap --commit`
      KEEPS the team.

### 3.2 `reap --commit` never clears a team that live sessions depend on

- **An orphaned team is not cleared** if it has any live or indeterminate
  member, or any `attributed_live` session. It is reported in
  `kept: [{team, live_members?, attributed_live?, next, why}]`.
  - **With `live_members`:** `next` is the exact adopt command for the
    invoking pid, `adopt --orchestrator-pid <pid> --team <t> --cwd <abs>`,
    or null when no invoking pid resolves.
    `why` is "its records are live sessions".
  - **With only `attributed_live`:** `next` is null, and `why` is
    "sessions claim this team through AH_TEAM_FILE but match no record.
    Adopting would relaunch its dead records beside them. Run reap again
    after those sessions exit."
- **An orphaned team with neither is cleared,** as today.
- **Why keep it rather than clear it.**
  - Clearing does not touch the sessions, and §3.4 makes a dangling
    `AH_TEAM_FILE` harmless.
  - But keeping costs nothing, and the file still documents what those
    sessions believe.
  - It clears itself on the first reap after they exit.
- This is the safe direction of an existing verb, so it is decided here,
  not asked. It is recorded in §6.

### 3.3 The skill says who adopts, and when not to

In agent-team SKILL.md, under teams or reap:

- **An orphaned team with live members** (by record) is adopted, never
  reaped.
  - **Adopt it yourself** when every live member's `last_brief_from` is
    you: your session name, or your own reply-to. That is the case after
    an Orchestrator restart or resume changes its pid.
  - **Otherwise ask the user** with AskUserQuestion. Options:
    - "Adopt it" (recommended when you are briefing those members);
    - "Leave it" (nothing changes).
    - Reaping is not offered, because 3.2 keeps the team anyway.
- **(r2) An orphaned team with only `attributed_live` sessions: leave it.**
  - Never adopt it: that relaunches its dead records as duplicates.
  - Never `disband --close` it: read the plan's `sources` and never close
    a session that you or another Orchestrator is briefing.
  - Say so to the user in one line. reap removes it after those sessions
    exit.
- Adopting never closes or relaunches anything.

### 3.4 A missing team file is never an error, and existence never decides identity (r4, replaces r2)

**Why r2 was wrong.** r2 said a missing file reads as unset. But members
launch before `create --commit` writes `teams/<t>.json`, so at every new
member's startup SessionStart a missing file is correct and expected.

- `envTeamFile`'s contract says "the file need not exist".
- The up-row tag (sessionstart.mjs:131-160) and `memberTeam`, which gives
  a role session its team scope (lib-roster.mjs:611-620, used at
  lib-config.mjs:1196), rely on that.
- A file not yet written and a file already removed look the same at read
  time.
- Telling them apart by history or by file age is not decisive: history
  also lists a re-created name, and a missing file has no age. So it is
  not attempted.

**The rule (r4):** readers split by what they need.

- **Identity readers take the team from the value's path alone, whether or
  not the file exists.** The path is validated as today: this repo's
  hierarchy dir, `teams/<t>.json`, the name grammar. These readers are:
  - `envTeamFile`;
  - SessionStart's `attributeSessionTeam` and its up-row tag, for every
    `source`;
  - `memberTeam` and `resolveConfig`'s role-session scope;
  - `createMessage`'s `team_file` fallback.
  - This is unchanged from today.
- **Content readers treat a missing file as "no record", never as an
  error.** These are the ones that need the members or the owner:
  - `whoami`'s member lookup, which reports `not-a-member` or `no-team`;
  - the route gate's `messageHome` member lookup;
  - any other reader of `members`.
- **A malformed value or another repo's value is treated as unset.** This
  is the existing validator, as `whoami` reports it today
  (`env_team_invalid`).
- **Therefore, for the sessions whose file was reaped, disbanded or
  untracked:**
  - they keep their team's name as their identity until they exit;
  - lookups of their record find none;
  - nothing errors, and nothing changes mid-session beyond the missing
    record.
  - That answers the original question: reaping or adopting ct does not
    change those sessions' hook behaviour.
- **Accepted residual.** If a new team is created under the same name
  while such a session still runs, that session is attributed to the new
  team. This was true before 0061.
  - Telling the two incarnations apart would need the team's id in the
    launch environment, and `create --spawn` would have to assign it
    before `--commit`.
  - That is a follow-up, not specified here.
- **What the Implementor does:** list each reader, confirm which of the
  two it is, and fix any content reader that throws on a missing file.
  Code changes are expected only in such a reader.

### 3.5 Unchanged

- `adopt`'s checks and output.
- `disband` and `dismiss`.
- `reap` on teams with no live member and no attributed session.
- No hook writes team files, and nothing adopts automatically. The CLI
  cannot tell which orchestrator a session serves; `last_brief_from` is
  best-effort, so the adoption is the driver's decision.

### 3.6 ct itself (r2): wait it out, no code, and nothing touches the live sessions

The evidence puts ct in the environment-only case. The live sessions
building this project must not be disturbed.

- **Now:**
  - do **not** adopt ct;
  - do **not** `disband --close` it;
  - do **not** reap it before this change lands. Today's reap would clear
    it, which is harmless only once §3.4 holds.
  - The claudetools-d5 Orchestrator keeps briefing the three sessions by
    their ListAgents names, as it does now.
- **The read-only check has been done (r3).** `herdr agent get` for
  ct-architect, ct-implementor and ct-reviewer each returned
  `agent_not_found` (exit 1).
  - All three records are dead, and no fourth session exists.
  - ct has no live member; its only live link is the three environment
    attributions.
- **After the three sessions exit,** at the end of this build, with this
  change in: `reap --commit` removes ct.json, because it then has no live
  member and no attributed session.
- **Not designed:** recording the three live sessions as a team without
  relaunching them (OQ-2).

### 3.7 How did a `claudetools-*` session get ct's team file? (noted)

- `spawnShape` sets `AH_TEAM_FILE` from the team being spawned into
  (roster.mjs:1576). The name comes from that team's prefix, so the two
  should agree.
- A session named `claudetools-implementor` that carries
  `AH_TEAM_FILE=ct.json` means that at some point they did not agree. That
  was most likely before 0057, under the old `teamAlias`.
- **Evidence (r3): no, with two unreachable edges.**
  - `AH_TEAM_FILE`'s only setter is `spawnShape` (roster.mjs:1576), fed by
    `resolveMembersPlan` (:2401), `planMembersFromHistory` (:2457) and
    `spawnOneCore` (:3282).
  - Every name comes from `repoBasename`, and every `teamFile` assignment
    sets or recomputes it from the same source (:717/:740, :752-754, :758,
    :2385, :3719-3723).
  - **Edge (1), a race.** `teamPrefix(cwd, null)` is read again at :718,
    :758 and :2385, so a concurrent legacy `team.json` write between those
    reads would produce exactly ct's shape. This is theoretical and was not
    reproduced.
  - **Edge (2), a hand-edited record.** 0060's `renamed_from` claim
    (:971) adopts `record.name` verbatim, so a hand-edited record with a
    foreign prefix would do it.
  - **Verdict:** ct is an artifact of the pre-0057 `teamAlias`.
- **Requirement (r3): one invariant at `spawnShape`.**
  - **The rule.** A member launched with `AH_TEAM_FILE` set to
    `teams/<t>.json` must have a name of the form `<t>-<role>` or
    `<t>-<role>-<n>`, in 0057's grammar.
  - **On a mismatch,** the spawn refuses before any pane opens. It exits 2
    and names the member, the team file, and the expected prefix.
  - **The check uses the file name alone,** never a new prefix read, so
    the check cannot itself race.
  - **The legacy `team.json` is exempt.** Its prefix lives in its content,
    and that path is being retired.
  - **Why keep it although edge (1) is theoretical:** it is one guard at
    the only setter. It turns the whole class of silent misattribution
    that produced ct into a loud refusal, and it also covers edge (2).
- **Acceptance S1:**
  - a team record hand-edited to `renamed_from`-claim a foreign-prefixed
    name makes `spawn-one` exit 2 with no pane opened;
  - every existing spawn test is unchanged.

### Acceptance

- **O1.** Fixture: an orphaned team with one live claude member, via a
  peers.jsonl up row, and one dead member.
  - The `teams` and `reap` plans list only the live one under
    `live_members`.
  - `reap --commit` keeps the file and lists it in `kept` with the adopt
    `next`.
- **O2.** An orphaned team with no live member is cleared by
  `reap --commit`, exactly as today.
- **O3.** A non-claude member whose Herdr state is indeterminate is listed
  with `indeterminate: true` and keeps the team.
- **O4.** `adopt` with the invoker's live pid, then `teams`: the team is no
  longer orphaned, and its members are unchanged byte for byte.
- **O5.** A text check on SKILL.md: adopt, never reap, a team with live
  members; adopt it yourself when the last brief came from you; otherwise
  ask, with the two options.
- **O6 (r2).** Fixture: an orphaned team whose records are dead, plus a
  live peers.jsonl row tagged with that team and no record.
  - `teams` and the reap plan list it under `attributed_live`.
  - `reap --commit` keeps the file, with `next:null` and the
    environment-only `why`.
  - Once that row is down, reap clears it.
- **O7 (r4, replaces r2).** With `AH_TEAM_FILE` set to a well-formed
  `teams/<t>.json` of this repo that does not exist, both before a commit
  and after a removal:
  - SessionStart, with `source` of startup and compact, tags the up row
    with team `t`;
  - `resolveConfig` gives a role session team `t`;
  - `whoami` exits 0 with `member:null` and reason `not-a-member` or
    `no-team`, and no `env_team_invalid`;
  - `msg.mjs new --type response --req …` succeeds;
  - the route gate decides as it does with the file present;
  - no hook-error log entry is written, and no reader throws.
- **O7b (r4).** A malformed value, or another repo's, is treated as unset
  and reported as `env_team_invalid` by `whoami`, as today.
- **O7c (r4).** create `--spawn` members that check in before `--commit`
  still carry team `t` on their up rows (the regression r2 would have
  caused).
- **O8 (r2).** A text check on SKILL.md: an orphan with only
  `attributed_live` sessions is left alone, never adopted, never
  closed.

## 4. The two noted items from 0060 §8

### 4.1 `partial` is derived at read, not stored

#### Facts

- The team file's `partial` is written at birth only:
  - by `create --commit` from `--partial` (roster.mjs:3861);
  - by spawn-one's new team, as `members.length > 1` of the roster
    (:3344).
- It is never recomputed.
- It is read only for display:
  - the status line "(N member(s), partial)" (lib-config.mjs:2159);
  - HIERARCHY STATE's "[partial]" (lib-hier.mjs:1064).
- `create --spawn`'s output field `partial` (roster.mjs:3117) is a
  different thing, a launch result. It is out of scope.

#### Requirement

- **Both display sites derive it.** A team is partial iff some roster
  member that `create` would launch has no team record. That means a
  pane-route member (peer or pane), excluding legwork auto-skipped under
  0058.
  - Use the team's recorded roster block (0057's `roster` key).
  - "Has a record" uses 0060 §3.6's claim mapping: a record whose name
    equals the member's derived name, or whose `renamed_from` equals it.
  - Records beyond the roster, meaning ad hoc members, never make a team
    partial or complete.
- **Writers stop writing the field.** The stored `partial` is ignored at
  read, and the key may remain in old files.
  - `create --commit --partial` stays accepted, as a no-op, so older
    driver text does not break.
  - SKILL.md stops passing it (SKILL.md:486 and :493).
- **Why derive rather than recompute on write:** a roster edit changes the
  answer with no team write, so any stored value can go stale again.
- **When the roster block cannot be resolved,** for example because it was
  deleted, nothing is shown. Showing "[partial]" would be a guess.

#### Acceptance

- **P1.** Roster of architect, reviewer and implementor; team records for
  architect and reviewer: the display shows partial. Spawn the implementor:
  it no longer shows partial, with no other write.
- **P2.** Dismiss a member of a full team: it shows partial.
- **P3.** A renamed member (`renamed_from` equal to the derived name)
  counts as present.
- **P4.** An ad hoc extra member does not make a partial team complete.
- **P5.** Old team files that carry `partial:true` display by derivation.
  Goldens change only where the fixture's team is actually complete or
  incomplete; the Implementor reports any such change.

### 4.2 spawn-one's liveness sees only team files: closed by 0060, no code

- `memberIsLive` finds a Claude session by name only through team-file
  attribution, because peers.jsonl `up` rows carry no name. So a live
  session outside any team file is invisible to spawn-one's "already live"
  check.
- 0060's D1 closes the naming half.
  - The driver passes `--names-in-use` from ListAgents, and spawn-one
    renames around any live outside name.
  - It cannot launch a duplicate name, and a duplicate *name* was the harm.
- 0062 extends this to non-Claude Herdr agents.
- **What remains is a driver that omits `--names-in-use`.**
  spawnReason already tells it to add the flag. Making the flag mandatory
  is a product choice, raised as OQ-1 in §7.

## 5. Files

| File | Change |
|---|---|
| tests/*.sh | `unset CLAUDE_PID` beside `unset AH_TEAM_FILE`; explicit pid per dependent check; the lint (§1) |
| tests/test-subagents-legwork-only.sh (r4) | K1: the HEAD diff replaced by budget-constant pins (§1) |
| hooks/lib-config.mjs | non-object roster members dropped at the read normalization point, with the warning through the existing stale-key warning channel (§2); derived `partial` for the status line (§4.1) |
| hooks/roster.mjs | `writeLevelFile` migration drops non-object members (§2); `teams`/`reap` `live_members` and `attributed_live` (r2); `reap --commit` keeps teams with either, and lists them in `kept` with `next` and `why` (§3); spawn-one and create stop writing `partial`, and `--partial` becomes a no-op (§4.1) |
| hooks/lib-roster.mjs, hooks/sessionstart.mjs, hooks/lib-hier.mjs (r4) | classify each `AH_TEAM_FILE` reader as identity or content (§3.4); fix only content readers that throw on a missing file; identity behaviour unchanged |
| hooks/roster.mjs (r3) | `spawnShape`'s name/team-file invariant (§3.7) |
| hooks/lib-hier.mjs | derived `partial` for HIERARCHY STATE (§4.1) |
| tests/test-subagents-legwork-only.sh + a fixture file | G6 (b)'s load-time rewrite injection (§2) |
| skills/agent-team/SKILL.md | the adopt, never reap, guidance (§3.3); drop `--partial` (§4.1) |
| docs/cli-tools.md | `live_members`, `kept`, the non-object member warning, `--partial` as a no-op |
| plugin.json and root marketplace.json | version bump together |

## 6. Decisions made here (all accepted by the user)

- **§2: skip rather than reject.** Rejecting would disable a team over one
  row.
- **§3.2: `reap --commit` keeps teams with live members or attributed
  sessions.** This is the safe direction; today's behaviour silently drops
  live sessions' records.
- **§3.4 (r4): a missing team file never decides identity.** Content
  readers treat it as "no record", and nothing errors. This replaces r2's
  "treated as unset", which would have untagged every member between
  `create --spawn` and `--commit`.
- **§3.6 (r2): ct is resolved by waiting,** with no adopt and no close.
- **§3.3: nothing adopts automatically.** The serving orchestrator is known
  only best-effort.
- **§4.1: derive `partial` at read,** and stop storing it.

## 7. Questions put to the user (all ruled)

- **Ruled: OQ-1 = no and OQ-2 = no,** both as recommended. Neither
  `--names-in-use` enforcement nor a `track` verb is built. The text below
  is kept as the record.
- **OQ-1 (§4.2).** Should `spawn-one` and `spawn-ad-hoc` *require*
  `--names-in-use`, so that skipping the ListAgents check is impossible?
  - Recommended: **no.** spawnReason already instructs the driver to pass
    it, and requiring it breaks hand use of the CLI, where there is no
    ListAgents to read.
  - If yes: an explicit empty `--names-in-use ""` would mean "checked, none
    in use".
- **OQ-2 (r2, §3.6).** Do you want a `track` verb, the inverse of
  `untrack`, that records live sessions into a team without relaunching
  them?
  - That would let the three live sessions become a proper team
    immediately, instead of staying untracked until they exit.
  - Recommended: **no, not now.**
    - ct is a one-off. Its sessions are ephemeral and work correctly
      untracked; the Orchestrator briefs them by name.
    - Recording a live session needs its pane, session id and role
      confirmed from outside the session, which is a new trust surface.
  - If yes, it gets its own spec.

## 8. Must not change

- 0058, 0059 and 0060 behaviour, except G6 (b)'s injection (§2), which
  0059 §8 authorised.
- `adopt`'s semantics.
- `disband`, `dismiss` and `untrack`.
- The directive size budgets. This spec adds no directive text.
