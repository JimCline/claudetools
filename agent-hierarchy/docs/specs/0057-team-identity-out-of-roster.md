# 0057 — Team identity leaves the roster: name and layout belong to the team, `--roster` selects a template

Status: r5, draft for implementation. r5 (review B1, blocking): the SessionStart sweep only touches
a team resolved by an owner step, or the legacy default when nothing resolved. It never touches one
resolved by env or pane. Attribution is never a destructive selector (§2.4 r5, §2.10 r5, B8–B10). Branch `feat/0056-user-defined-roles` at 0.87.0 (4e104fc).
Supersedes in part: 0010 Feature B (alias storage), 0011 §5.3.3/§5.3.4, 0032 §3 (team-keyed roster
selection), 0044 §1.1 constraint 4, and §8.1's placement of `layout`/`alias`. Each is cited where
overturned. 0044 F3/§9.1 "refuse, never auto-sanitize" **stands** (r3).

**r4 changes (review spec-defects S1, S4, S5, N5, N6, N7):**
- S1 (§2.4 step 2, B6/B7): the invoker's **own** team is live regardless of age. There is one
  owner predicate (pid equal and alive; session ids equal when both are known), and every liveness
  decision made for an invoker uses it, `sessionstart`'s sweep included.
- S4 (§2.7): stale-key warnings go to CLI output only (`status`, `doctor`, `create`), never to
  hook-injected context. Each says that deleting the key drops it.
- S5 (§2.5, C10, skill row): `create --plan` gains `named_rosters`, present only when non-empty.
- N5 (§4 exception 3): the `status-report.txt` line `Team alias: none` becomes
  `Team name: <X> (<source>)`.
- N6 (§2.10, P3/P3a): `whoami` `reason` is always the real outcome. An ignored `AH_TEAM_FILE` goes
  only in `env_team_invalid`, which distinguishes other-repo from malformed.
- N7 (§3): the `msg.mjs` row now names `resolveTeamArg`'s attribution fallback.

**r3 changes (user rulings on r2's U5/U6), confined to §2.2, §2.4's no-team bullet, §2.7's remedy
row, §2.8, §3's surface rows, step 5, step 6, and §6:**
- U5 accepted: first-ever create uses `auto` silently.
- U6 reversed. The user: *"This is one place where I think warrants asking the user."* The CLI never
  applies a sanitized name on its own, on any transport. An unusable default name is a **structured
  refusal** carrying `suggestTeamAlias`'s suggestion; whoever is driving asks the user and re-runs with
  `--team <chosen>` (§2.8). Steps 1–4 are unaffected.

**r2 changes (the user ruled on r1's U1–U4 and rejected r1 §2.3's accepted degradation):**
- U1: layout is a **stored global preference** (`teamLayout`), updated by an explicit `--mode` — §2.6.
- U3/U4: the default team name is sanitized when the basename is unusable, by **one** sanitizer
  (`suggestTeamAlias`, extended) that both the CLI and the skill's suggestion go through — §2.2, §2.8.
  *(r3: the sanitized name is now only ever suggested, never applied.)*
- U2: unchanged (warn, use the default block).
- r1 §2.3's "accepted degradation" is withdrawn. Peer sessions attribute their own team through a
  launch-time channel — new §2.10. Every gate that fails open because of a null peer scope now resolves.

## 0. Requirement

The user's principle, not negotiable:

> A roster defines only WHO can be put on a team — members and their per-member attributes (role,
> model, effort, kind, args, auto-mode, route default). A team is an instance created FROM a roster
> at spawn time; its name and its pane layout belong to the team, never to roster config.

Scope chosen by the user — "full split":

1. The team name is chosen at `create` (default: repo basename) and frozen with the team. Member names
   `<team>-<role>[-N]` derive from it. `teamAlias` leaves `agent-hierarchy.json` entirely.
2. Layout is a create/spawn option. `roster.layout` and the `layout` verb leave the roster.
3. `--team` stops meaning "pick `rosters.<t>`". A named roster gets its own selector, `--roster <r>`.
   `--team` means only the live team.

## 1. Findings — what is true at 0.87.0

Verified by read-only tracing (no execution). Line numbers are 0.87.0's.

- **[F1] Named-roster selection is spec 0032, not 0011.** 0011 introduced `--team` and `teams/<T>.json`;
  0032 §3 made the same value select `rosters.<T>`. The brief attributes it to 0011; the overturned
  contract is 0032's.
- **[F2] The fusion lives in two functions.** `resolveRoster(cwd, team)` (`lib-config.mjs:852-874`) uses
  one `team` value both to pick `rosters[team]` and to compute the naming prefix via
  `teamPrefixInfo(cwd, team)` (`:854`). `resolveConfig(cwd, {team})` calls it (`:1263`) and threads
  `resolved.team` onward into prefix derivation (`:1868`, `:1986`). Every other fused ("both") site
  is a caller of these two: `roster.mjs:737, 1125, 1826, 2569, 2802, 2816, 3200`, `msg.mjs:258`.
- **[F3] A team file stores no name, no roster key, no layout.** Keys written by `spawnOneCore`
  (`roster.mjs:2727-2738`) and `create --commit` (`:3235-3244`): `version, team_id, created,
  roster_level, transport, orchestrator{session_id,pid}, members[], partial, expected_root`. A named
  team's name is its filename (`teams/<n>.json`, `teamPath`, `lib-roster.mjs:91`), so it is **already
  frozen**. The legacy unscoped `team.json` has no stored prefix; every operation recomputes it from
  `teamAlias`/basename, which drifts mid-team if the alias changes (flagged in code, `roster.mjs:~2624`).
- **[F4] `teamPrefixInfo(cwd, team)`** (`lib-config.mjs:800-823`): string `team` → `team`; else
  `repo-user` `teamAlias` → `repo` `teamAlias` → `basename(repoRoot)`. `teamAlias` is read nowhere
  else except `resolveConfig`'s validation loop (`~:1085-1095`) and the `alias` verb (`roster.mjs:~3020-3066`).
- **[F5] Layout** is read from the roster in exactly one runtime place: `spawnOneCore`'s
  `layoutSource.layout` (`roster.mjs:2678`), sourced from `resolveRoster`'s `layout` (`lib-config.mjs:872`,
  default `"auto"`). Also `show` (`:2808`), `init` via `freshRosterBlock(route, opts.layout)` (`:2836`),
  and the `layout` verb (`:3002-3016`). `next-split`/`layout-splits` take `--mode`; `move` takes explicit
  placement. `create --spawn` already takes `--mode`.
- **[F6] Directive spawn lines carry no `--team`.** `pretooluse-route-gate.mjs:115-116` emits
  `spawn-one <role> --cwd <cwd>` / `spawn-ad-hoc <role> --cwd <cwd> [--model M]`; the verb is chosen by
  `rosterMemberFor(resolved, role)` (`lib-config.mjs:1653`).
- **[F7] Without `--team`, team verbs do NOT resolve the session's own team.** `resolveTeamFileScope`
  (`roster.mjs:693`) → `defaultTeamScope(dir, teamPrefix(cwd, null))` (`lib-roster.mjs:446-464`) →
  `settleWritableTeamScope` (`roster.mjs:1794-1821`): legacy `team.json` if present and not orphaned,
  else `teams/<teamPrefix(cwd,null)>.json`, created implicitly by `spawnOneCore` if absent, with
  `orchestrator.pid` from `--orchestrator-pid`/`CLAUDE_PID` (`:2605`). No step asks which team the
  invoking pid owns. **Consequence today:** an orchestrator that created `create --team ct` in a repo
  with no alias, then follows a directive `spawn-one architect`, gets a *second* team
  `teams/<basename>.json`. It works today only when the team name equals the alias. Removing the alias
  makes this the common case, so fixing it is in scope (§2.4), not garnish.
- **[F8] Hooks in peer sessions resolve `resolved.team === null`** (`resolveTeamScope`,
  `lib-config.mjs:1039-1053`, is orchestrator-only: `opts.team`, then `orchestrator.session_id`, then
  `orchestrator.pid`). Peer-side prefix consumers therefore get `teamPrefix(cwd, null)`. See §2.3.
- **[F9] Herdr name rule.** `validateHerdrName` (`lib-config.mjs:262-271`, `[a-z][a-z0-9_-]{0,31}`) is
  applied to *member* names: `spawnShape` when `transport === "herdr"` (`roster.mjs:1052`, refuses
  before that pane opens); `requireHerdrName` in `add`/`edit` for pane routes (`:838`); the `role set`
  warning (`:372-373`, prefix `teamPrefix(cwd, teamArg)`); `pretooluse-herdr-name-gate.mjs:43` on literal
  `herdr agent start` commands. Its failure text and the `role set` warning both name `alias --set` as
  the remedy; so does `failUnnamablePrefix` (`roster.mjs:704-710`).
- **[F10] Team history** (0015, `upsertHistory`, `lib-roster.mjs:658-681`) stores `alias` = the team
  file scope name (`roster.mjs:3257-3264`), not config `teamAlias`. No layout, no roster key.
- **[F11] No `mcp/*.mjs` exists in this tree.** 0044 §8.4's MCP tools are not present on this branch.
  Nothing to change there; if they are restored later they inherit this spec's CLI contract.
- **[F12] A sanitizer already exists.** `suggestTeamAlias(raw)` (`lib-config.mjs:775-782`): maps
  `[^A-Za-z0-9-]` → `-`, strips leading non-alphanumerics, truncates to 32, strips trailing `-`, then
  returns the first of `[s, "team-"+s (≤32)]` passing `validateTeamAlias`, else `"team"`. Callers:
  `defaultTeamScope` (`lib-roster.mjs:450`, fills `suggested`), `failUnnamablePrefix`
  (`roster.mjs:707`), `roster.mjs:1683`. It is case-preserving and knows nothing of Herdr's charset
  or of member-suffix length.
- **[F13] Global config.** `userConfigPath()` (`lib-config.mjs:599-601`) = `~/.claude/agent-hierarchy.json`.
  Recognised top-level keys outside `roster`/`rosters`: `teamAlias` (`:1092`, repo levels only),
  `enabled` (`:1131`), `handoffs` (`:1138`), `msgs` (`:1154`), `route` (`:1165`), `roles` (`:1179`).
  No single-key writer exists; the pattern is whole-file `readLevelFile`/`writeLevelFile`
  (`lib-roster.mjs:786-799`), as the `alias` verb does (`roster.mjs:3042-3043`).
- **[F14] The launch carries no team.** One builder, `spawnShape` (`roster.mjs:1040-1118`), via `shapeFor`
  (`:1156-1169`), run by `launchMember` (`:1970-2031`) through `runShell` = `execFile("/bin/sh",["-c",cmd])`
  with no `env` option (`:1890-1896`). Child flags (`agentFlags`, `:1070-1072`): `--agent`, `--name`,
  `--model`, `--effort`, `--permission-mode` — nothing else. Launch strings: herdr
  `herdr agent start <name> --kind claude --pane <T> -- <flags>` (`:1088-1090`); tmux
  `tmux send-keys -t <T> "claude <flags>" Enter`, typed into the pane's own shell (`:1105-1106`);
  terminal `claude <flags> --bg` (`:1117`). No `AH_*` env, no team name or path, anywhere.
- **[F15] What exists to attribute a session to a team.** Members record `transport_id` (pane id) at
  spawn — no `session_id`/`pid` per member. `sessionPaneId` (`roster.mjs:1712-1714`) =
  `HERDR_PANE_ID || record.pane_id || TMUX_PANE`. `resolveTeamByPane` (`lib-roster.mjs:478-496`) matches
  it against every team's `members[].transport_id`, null on miss/ambiguity. `resolveSessionTeam`
  (`:521-534`) is a role-count scan. `attributeSessionTeam` (`:516-519`) = pane, then role-scan; used
  by `checkin` (`roster.mjs:3927-3930`) and `whoami` (`:3966-4022`, also searches `mainHierarchyDir`
  for worktrees). `sessionstart.mjs:136` uses only the role-scan (the team file is usually not yet
  written when it fires, `:126-135`) to tag the peers.jsonl `up` row. `resolveTeamScope` never
  resolves a peer. The message frontmatter `team_file` comes from the sender (`teamFileFor`,
  `lib-hier.mjs:194-198`); `messageHome` (`:206-211`) is the reader-side check that a claimed
  team_file "sits where team files sit".
- **[F16] Correction to r1 §2.3.** `pretooluse-msg-gate.mjs` (`:52-54`) and `pretooluse-ultra-gate.mjs`
  (`:114-121`) return early for any session with a direct hierarchy role — they never run their team
  logic in a peer. In a peer, the team-dependent consumers are: `pretooluse-route-gate.mjs` (resolves
  `resolveConfig(cwd,{sessionId})` → `teamPrefix(cwd, resolved.team)` + roster read, `:162-165`; its
  peer branch is role-driven, `:169-170,212-215`); `sessionstart.mjs`'s `up`-row team tag (role-scan
  only); and `msg.mjs`/`createMessage` run from a peer, whose `team_file` falls back to the sender's
  team when the recipient name is found nowhere (`lib-hier.mjs:194-198`). `posttooluse-roster.mjs`
  does a by-name lookup and needs no scope; `herdr-name-gate` and `roster-skill-gate` read no team.
- **[F17] CLI output channels and the directive's failure branch (r3).** `fail(msg)`
  (`roster.mjs:155-158`) writes `roster.mjs: <msg>` to stderr and exits 2; `out(obj)` (`:160-162`) writes
  JSON to stdout, exit 0; `partial(obj)` (`:165-168`) writes JSON to stdout and exits 3. No existing
  `fail()` text tells the model to ask the user. The route gate's spawn directive (`spawnReason`,
  `pretooluse-route-gate.mjs:~119-132`) says: *"If the command fails (no herdr or tmux, launch error),
  tell the user and ask whether to opt into subagents"* — an unusable-name refusal left unmarked would
  land in that branch. Precedent for asking: `skills/agent-team/SKILL.md:249-267` has the model ask via
  AskUserQuestion, candidate first, before re-running with `--team` on the second-team collision.

## 2. Design

### 2.1 Invariant: a member name derives only from the team it is recorded in

> A member's name is `<team-name>-<role>[-N]`, where `<team-name>` is the name of the team file the
> member is, or is about to be, recorded in. No member name is ever derived from roster config.

The team name of a team file is:

| Team file | Its name |
|---|---|
| `teams/<n>.json` | `n` — the filename is the name; it is already frozen (F3). **No `name` field is added**: a second copy of the identity is a second thing that can disagree with the path. |
| legacy `team.json` | Its **frozen prefix**, inferred from its own members: the first member whose `name` ends in `-<its role>` or `-<its role>-<digits>` yields the prefix by stripping that suffix. No inferable member → repo basename. This replaces the live `teamAlias` recomputation that could drift (F3). |
| none yet (about to be created) | The name chosen at create: `--team <n>`, else the default candidate (§2.2). |

### 2.2 `teamPrefixInfo(cwd, team)` — new contract

Keep the function and its **two-argument** signature (so `test-roster-multi-team.sh` test 11's
single-argument ban still holds). Behaviour:

- `team` a non-empty string → `{ prefix: team, source: "team" }`.
- otherwise → the legacy `team.json`'s frozen prefix (§2.1) if that file exists and yields one,
  `source: "legacy-team"`; else `{ prefix: basename(repoRoot), source: "default" }`.
- It no longer reads any config file. The `alias` field and the `"repo"`/`"repo-user"` source values
  are removed; every consumer of `.alias`/`.source`/`teamAlias`/`teamAliasSource` (`resolveRoster`'s
  return, `show`'s `effectiveTeamAlias*`, the `alias` verb) is updated or deleted with it.

The null branch's legacy clause is deliberate: it is exactly what `teamAlias` supplied for a pre-0044
default team, sourced from the team instead of config, so a repo that still holds a legacy `team.json`
sees the same prefix it sees today.

**Default team name for a new team** (r2 — replaces r1's "default candidate = `teamPrefix(cwd, null)`").
Used only when a new team file is about to be created with no `--team`: `create` (every phase) and
`spawn-one`/`spawn-ad-hoc`'s implicit creation (§2.4 step 3). Computed from `p = teamPrefix(cwd, null)`,
the transport, and the roster block the team will be built from:

1. `p` passes §2.8's name check for that transport and block → `p` (source `basename`, or
   `legacy-team`). In a repo with no legacy file and a usable basename this is the repo basename, as
   the user specified, and member names are byte-identical to today's.
2. Otherwise → **refuse** with §2.8's structured refusal, carrying the sanitizer's suggestion (or none,
   when no team name can fit). Nothing is launched or written. *(r3 — r2 applied the suggestion
   silently; the user ruled that choosing it is the user's call.)*

It is a pure function of (repo, transport, roster block, legacy file), so every process computes the
same answer; nothing about it is stored. `teamPrefix(cwd, null)` itself stays §2.2's plain fallback —
the sanitizer is not pushed into `teamPrefixInfo`, which has no transport or block to reason with.

### 2.3 Consumer table — what each reads after the change

"Null scope" = no `--team`, and the session owns no team (§2.4).

| Site | Today | After |
|---|---|---|
| `resolveRoster` `lib-config.mjs:854` | prefix from the same `team` that selects the block | caller supplies the **roster key** and the **naming prefix** as two independent inputs (§2.5). Neither is derived from the other anywhere. |
| `resolveConfig` → `:1868`, `:1986` (directive / hierarchy-role text) | `teamPrefix(cwd, resolved.team)` | unchanged call; null scope now yields §2.2's fallback |
| `pretooluse-route-gate.mjs:165` | `teamPrefix(cwd, resolved.team)` | unchanged call. Role resolution already goes team-membership-first (0011 §9.1, `resolveMemberTeam`); null role still **allows** (0009 §8.12). |
| `pretooluse-msg-gate.mjs:82` | same | unchanged call. 0011 §9.6's fail-open degradation is unchanged in kind. |
| `pretooluse-ultra-gate.mjs:133,143` | same + predicate (ii) union | unchanged. Post-0044 every team is `teams/<n>.json`, so predicate (ii)'s union of all team names covers peer sessions regardless of the fallback. |
| `posttooluse-roster.mjs:54`, `sessionstart.mjs:198` | same | unchanged call |
| `msg.mjs:258-259` (`msg roster --team t`) | `resolveConfig(cwd,{team:t})` selects `rosters.t` **and** prefix `t` | `--team t` selects live team `t`; the roster block comes from team `t`'s recorded key (§2.5); prefix `t`. `msg new/list --team` (tagging, `team_file`, filter — `lib-hier.mjs:277-278,332`, `msg.mjs:187,205`) already mean the live team: **no change**. |
| `roster.mjs:666` (`repoBasename = teamPrefix(cwd, teamArg)`, used pervasively) | explicit `--team` or alias/basename | the name of the team file the verb resolved to (§2.4): explicit `--team` → it; owned team → its name; otherwise §2.2's fallback |
| `roster.mjs:693` `resolveTeamFileScope`, `:1820` `settleWritableTeamScope` | `teamPrefix(cwd, null)` | same call, preceded by §2.4's owned-team step |
| `roster.mjs:1668` `guardTeamPrefixCollision` | alias/basename | `teamPrefix(cwd, null)` — which now **is** the legacy team's frozen prefix when a legacy team exists, i.e. the thing the guard protects. Keep the guard (0044 §1.7). |
| `roster.mjs:1695` `refuseLiveDefaultTeam` | alias/basename as candidate base | the preferred name being created (`--team` or the default team name, §2.2) |
| `roster.mjs:362,372` `role set` collision + Herdr warning | `teamPrefix(cwd, teamArg)` | the invoking session's owned live team's name if any, else `teamPrefix(cwd, null)`. `role set` no longer takes `--team` (it is role config, not a team operation). Warning text names the prefix it assumed and gives the remedy "create the team with a shorter `--team` name" instead of `alias --set`. |
| `roster.mjs:2258`, `:3160` (create scope/labels) | `teamArg` | the team name being created |
| `roster.mjs:2803` `show` | alias fields + names under the team prefix | no alias fields. Member names displayed and accepted by roster verbs (`edit/remove --member`) use the default team name (§2.2) for the shown block and the configured transport — a roster has no team, so it shows names as they would be under that name. r3: when §2.2 refuses, `show` does not refuse — it shows names under `teamPrefix(cwd, null)` and notes that the name is unusable and `create` will ask for one. |
| `roster.mjs:3044-3066` `alias` verb | reads/writes `teamAlias` | removed (§2.7) |

**Peer sessions (r2 — r1's "accepted degradation" is withdrawn; the user rejected it).** The rows above
say "unchanged call" because the call is right once `resolved.team` is right. In a peer session it is
now right: §2.10 gives `resolveTeamScope` a peer step, so a peer's hooks get their own team, not
§2.2's fallback. r1 also overstated the exposure: msg-gate and ultra-gate never run their team logic
in a peer (F16). A "sole live team" fallback stays rejected: it makes one session's prefix depend on
whether some other session's team happens to be alive, which is hidden state the user never chose.

### 2.4 Team verbs without `--team` resolve the session's own team first

Applies to every team-side verb that resolves a team file scope when `--team` is absent: `create`
(all phases), `spawn-one`, `spawn-ad-hoc`, `dismiss`, `disband`, `untrack`, `resync`, `move`.
**Not** `adopt` (its `--orchestrator-pid` is the *new* owner, not a current one) and not the
peer-side `checkin`/`whoami` (their pid is a peer's and never owns a team; their existing
`attributeSessionTeam` path is unchanged).

Precedence:

1. `--team <t>` → `teams/<t>.json`, as today.
2. **Owned team:** scan `[null, ...listTeamNames(dir)]` for live teams whose `orchestrator.pid` equals
   the invoking pid (`--orchestrator-pid`, else `CLAUDE_PID` — the same resolution the commit path and
   `refuseRosterEditWhileOwningTeam` already use; reuse that scan's technique, not that function,
   since 0044 §1.11 notes it refuses on match). Exactly one → that team. More than one → refuse,
   exit non-zero, list them, require `--team`. Unresolvable pid → skip this step (as 0044 §1.3's
   deliberate hole).

   **"Owned" and "live" for this step (r4, review S1).** r3 said "live teams" without defining the
   term. The implementation used `teamIsLive` (`lib-roster.mjs:628`), which also requires `created`
   to be ≤ 24h old (`TEAM_STALE_AGE_SEC`). So after 24h the owner's bare `spawn-one` fell through
   to step 3 and started a second team, which is F7 again. The hooks' owner steps
   (`resolveTeamScope`) and `msg.mjs` `resolveTeamArg` have no age cap, so the CLI and the hooks
   disagreed about which team it was.

   A team is **owned by the invoker** when all of these hold:
   - its `orchestrator.pid` equals the invoking pid, and that pid is alive;
   - where the invocation carries a session id (`--session` on the CLI, `sessionId` in a hook)
     **and** the team records a non-null `orchestrator.session_id`, the two are equal. This check
     is the only guard against pid reuse; otherwise the pid alone decides.

   There is **no age cap**. The age cap only exists as an orphan heuristic for teams whose owner
   the reader cannot vouch for. The invoker vouches for its own team simply by being alive.

   **The same rule covers every liveness decision made for an invoker about its own team.** It is
   not limited to this step, because narrowing it here alone would make things worse:
   - With the step fixed, a bare `create --plan` by an owner after 24h resolves to the owned team.
     `refuseOrClearExistingTeam` (`roster.mjs:~1971`) would then find it "not live" and clear it,
     erasing a running team's member records on a plan.
   - `sessionstart.mjs`'s `sweepStaleTeam` (`:78-83`, called at `:194` for plain top-level sessions
     with `resolved.team`) already clears an orchestrator's **own** team when that session compacts
     or resumes after 24h.

   Rules:
   - Where `teamIsLive` is consulted by a caller that knows the invoker's pid (and session id, if
     any), a team owned by that invoker (as defined above) counts as live regardless of age. The
     age cap still applies unchanged to teams owned by anyone else.
   - Callers covered: `ownedLiveTeams`, `refuseOrClearExistingTeam`, `guardLiveTeamAtScope`,
     `settleWritableTeamScope`'s replacing branch, `refuseRosterEditWhileOwningTeam`, and
     `sweepStaleTeam`. In the hook, the invoker is `process.ppid` plus the input's session id.
   - Callers with no invoker identity keep today's predicate: `doctorReport` and
     `historyEntryIsActive`.
   - Implement it once, as one shared owner predicate that the liveness check consults (extend
     `teamIsLive` or give it a sibling). Do not write per-caller copies.

   0044 §1.11's table is unchanged in its rows: an owned team is now also "live" after 24h, so the
   owner gets "same owner, `--plan` → refuse" and "same owner, `--commit` → allow" instead of a
   silent clear.

   **Which team the sweep may touch (r5, review B1 — blocking defect in r4).**
   - What went wrong: r4 put the sweep under the invoker rule but left its target as
     `resolved.team`. After §2.10, `resolveTeamScope`'s steps (4)/(5) also resolve a **member's**
     team. A plain session attributed as a member could therefore delete another live
     orchestrator's team file once that file was older than 24h. The probe confirmed this:
     `TMUX_PANE` matching a member's `transport_id`, or `AH_TEAM_FILE` pointing at the team, deleted
     it. Real triggers are a crashed member relaunched by hand with plain `claude`, and `claude -p`
     run from a peer's Bash, which inherits `AH_TEAM_FILE`.
   - Rule: `sweepStaleTeam` considers a team only when `resolveTeamScope` answered from an
     **owner step** — explicit `opts.team`, `session_id`, or `pid` (steps 1–3) — or when no step
     answered, in which case it considers the legacy `team.json` as today. When step (4) or (5)
     answered, the sweep does nothing at all. This keys on **which step answered**, not on the
     value, because a pane match on a legacy team also yields `null`.
   - That is exactly HEAD's reach, minus one case: HEAD let a session later attributed as a member
     sweep the legacy `team.json`. Now any unattributed plain session sweeps it instead.
   - Within that reach, the S1 rule above still applies: the invoker's own team is never cleared by
     age. The 24h cap for teams the invoker does not own is unchanged. Option B (orphan-only for
     non-owned teams) is rejected because it would change that cap, which §4 holds fixed.
   - How the sweep learns which step answered is the Implementor's choice. For example,
     `resolveTeamScope` could report its answering step alongside the name. Whatever the
     mechanism, it must reuse `resolveTeamScope` and must not re-implement the owner steps.
   - The general rule is in §2.10: attribution never selects a team for a destructive action.
3. Otherwise: today's default-scope logic (F7), unchanged — legacy `team.json` if present and not
   orphaned, else `teams/<default team name>.json` (§2.2), created implicitly by `spawn-one`/`spawn-ad-hoc`.

This answers the two cases the brief names:

- **Session owns a live team** → directive `spawn-one`/`spawn-ad-hoc` (no `--team`, F6) join it. No
  change to the route gate's emitted command; the CLI resolves it, so hand-typed and skill-driven
  invocations get the same answer.
- **No team exists yet** (first directive spawn) → step 3: implicit team named the default team name
  (§2.2), roster key `null` (default roster), layout = the stored preference or `auto` (§2.6). An
  unusable default name → §2.8's structured refusal, whose text tells the model driving the directive
  to ask the user (r3). Until step 5 lands, today's `failUnnamablePrefix` refusal stands here
  unchanged. `spawn-one` does not accept `--roster`: a team built from a named roster must be made with
  `create --roster` first.

Consistency check against 0044 §1.11's truth table: with step 2, a bare `create --plan` by a session
that already owns a live team resolves to *that* team → "live, same owner, `--plan` → refuse", and a
bare `create --commit` → "same owner, `--commit` → allow". Both are the existing table's rows; no new
outcome is introduced.

Not changed: join-vs-create under step 3 still keys on liveness of the existing owner, not identity
(F7). Whether a session may join a live team it does not own is a separate question; not ruled here.

### 2.5 `--roster <r>` selects the template; the team records which it used

**Selector.** `--roster <r>` names a `rosters.<r>` block; absent means the default `roster` block.
Validated with `validateTeamAlias` (the existing rule, so every block 0032 made reachable stays
reachable). Accepted on:

- roster-template verbs: `init`, `add`, `edit`, `remove`, `show` (replacing their `--team`);
- `create` (`--plan`, `--spawn`, `--commit`). `create --from <history>` does not take it — a history
  entry carries its members explicitly.

**Discovering named rosters (r4, review S5).** No verb listed `rosters.*`, so a bare create could
never offer one. `create --plan` output gains **`named_rosters`**:
- the sorted, de-duplicated keys of `rosters.*` across every level `resolveRoster` reads (repo-user,
  repo, global), keeping only keys that pass `validateTeamAlias` (the others cannot be selected);
- **present only when non-empty**, and absent otherwise, so fixtures without named rosters —
  including every 0056-i1 golden (§4 forbids `rosters` in that fixture) — see no delta;
- listed the same whether or not `--roster` was given.

Reuse `doctorReport`'s existing enumeration of `rosters` (`roster.mjs:~462`) rather than writing a
second walk. `show` is not changed for this, because the create flow already runs `--plan` and one
place is enough.

**`--team` on roster-template verbs is an error**, not a silent alias: "`--team` names a live team; to
edit a named roster use `--roster <r>`". Reinterpreting it would perpetuate the conflation; ignoring it
would write the default block, which is 0032 §3.4's corruption hazard.

**The team records its template.** Every write that creates a team file (`create --commit`,
`create --spawn` if it writes, `spawnOneCore`'s implicit creation — state the rule at the write site,
as 0044 §1.11 did, rather than per branch) adds:

- `roster`: the block key it was built from — a string, or `null` for the default block.
- `layout`: `"auto" | "columns" | "grid"` (§2.6).

Later operations on a live team that need its template — `spawn-one`'s member lookup, `resync`,
`dismiss --also-config`, the route gate's `rosterMemberFor` (via `resolveConfig`), `msg roster` — read
the key from the team, never from `--team`.

**Resolution rules** (`resolveRoster` now takes the roster key and the naming prefix as separate
inputs; `resolveConfig` takes an optional explicit roster key and otherwise derives it from the
resolved team):

| Key source | Missing `rosters.<r>` at every level |
|---|---|
| explicit `--roster r` at `create` | **error**, exit non-zero, nothing launched or written. An explicit selector that silently falls back is 0032 §3.4b's "config that looks applied and never is". |
| explicit `--roster r` on `add`/`edit`/`remove` | 0032 §3.4b unchanged: "run `init --roster r` first" |
| a team's recorded `roster` field (read time) | fall through to the default block (0032 §3.3's lenient read), so deleting a block mid-team degrades rather than breaks |
| team file lacking the `roster` field (created before 0057) | **legacy rule**: exactly 0032 §3.2's two passes keyed by the team's name (`rosters.<team-name>`, then default). Preserves every live team across the upgrade. |

0032 §3.2's level ordering (a per-key block at any level beats the default at a higher level; level
precedence decides within a kind) is retained for the explicit and recorded keys.

**`dismiss --also-config`** maps a live member to its roster row by stripping the team's own name
(§2.1) from the member name to get `<role>[-N]`, then matching in the team's recorded block. A member
with no matching row (ad hoc) writes nothing and says so.

**Migration hazard — `create --team T` where `rosters.T` exists and no `--roster` is given.** Before
0057 that picked `rosters.T`; after, it picks the default block. `create` must **warn** in its output
(plan and commit), naming `--roster T`. Not a refusal: `create --plan` is always shown before spawning
in the agent-team flow, and a refusal needs a way to say "the default block", which 0032 §3.1
deliberately has no spelling for. **User call** — see §6 U2.

### 2.6 Layout is a create option recorded on the team

- `create --plan`, `--spawn`, `--commit` take `--mode <auto|columns|grid>` (the spelling `--spawn`,
  `next-split`, and `layout-splits` already use; values `ROSTER_LAYOUT_VALUES`). `--plan` echoes the
  layout in `layout_plan`; commit and implicit creation record it as the team's `layout`.
- `spawnOneCore`'s layout source (F5, `roster.mjs:2678`) reads the team's `layout`; a team lacking the
  field (pre-0057, or legacy) uses `auto`. No read of any roster `layout` remains.
- Team history (F10) does **not** record layout (r2: the stored preference, not an old team's layout,
  is what the user asked to govern new teams, so a history layout would have no reader). The history
  field named `alias` keeps its name (it is the team name; renaming breaks existing history files) —
  documentation calls it the team name.

**Stored preference (r2, user ruling on U1).** The user's words: *"store the user's last choice in the
global config, used as the default going forward, only prompt if the user asks to change it or honor
an ad-hoc choice without prompting."*

- **Key:** top-level `teamLayout` in the **global** config file only (`userConfigPath()`, F13), value in
  `ROSTER_LAYOUT_VALUES`. Never inside `roster`/`rosters` (the principle). Named `teamLayout`, not
  `layout`, so it cannot be confused with the removed `roster.layout` key in a stale file or in the
  stale-key warning. A `teamLayout` at `repo`/`repo-user` level is ignored with the §2.7 warning
  ("global only"); an invalid value is ignored with a warning and treated as absent.
- **Layout used by a create** (every phase, `create --from`, and implicit creation), first that applies:
  1. explicit `--mode m` → `m` (source `explicit`);
  2. global `teamLayout` → it (source `stored`);
  3. `auto` (source `default`).
  `--plan` output reports the layout **and its source**, so the skill can show what will be used.
- **Write-back:** an explicit `--mode` on `create --spawn` or `create --commit` (the phases that create
  something; also `create --from ... --mode`) writes `teamLayout = m` to the global file. `--plan`
  never writes — it is the read-only phase and a plan may be abandoned. Sources 2 and 3 never write.
  Skip the write when the stored value already equals `m`.
  Write-back failure (unwritable file, unparseable JSON) is a **warning**, never a create failure: the
  team is already correct; only the preference is lost.
- **Write mechanics:** whole-file read-modify-write through the existing `readLevelFile`/`writeLevelFile`
  (F13), preserving every other key byte-for-byte in value. If no global file exists, create it with
  `version` and `teamLayout` only. **Invariant:** a global file holding only `version`+`teamLayout`
  must not change any resolution — roster level selection, `enabled`, `route`, `msgs`, `handoffs`,
  `roles`, or any "is a roster configured" check (sessionstart, `agent-roster` skill gate). §5 A6 pins it.
- **First-ever create, nothing stored:** `auto`, **no prompt**, nothing written. Chosen over "prompt
  once" because the user's rule is "only prompt if the user asks to change it", and a first create
  with no ask is not a change request. Flagged in §6 (U5) in case the user meant otherwise.
- **The skill never asks about layout** unless the user asks to change it in this conversation, in
  which case it asks once (current stored value marked) and passes the answer as `--mode`, which
  stores it. A layout the user names unprompted ("spawn a team in grid") is passed as `--mode`
  without asking.
- Not built: a verb to change the stored preference outside a create. `create --mode` already does
  it; add a verb when someone needs to change it without creating a team.
- Concurrency: the write-back is last-writer-wins on the whole global file, as every level-file
  writer is today. A concurrent `roster.mjs add --level global` could lose one side's edit; the
  skip-when-equal rule keeps the window to the rare create that changes the layout. Accepted; same
  class as today's level writers.

### 2.7 What leaves the roster surface

| Removed | Replacement behaviour |
|---|---|
| config key `teamAlias` (any level) | never read for naming. `resolveConfig` emits a warning naming the file and saying the key is ignored and team names are chosen with `create --team <name>`. **No config rewrite** (0001 §8 and 0044 §1.7 precedent: read-never-migrate). Bare `create` in a repo whose config still carries a `teamAlias` different from the default team name adds the warning to its output, naming `--team <alias>` as the way to keep the old member names. |
| `roster.layout`, `rosters.<r>.layout` | ignored; same warning mechanism. `init` writes blocks without it. |
| `alias` verb | kept as a stub that exits non-zero with the replacement (`create --team <name>`). Stale transcripts and skills keep landing on a signpost, not "unknown verb". |
| `layout` verb | same stub, replacement `create --mode <m>`, and the text says an explicit `--mode` also becomes the default for future teams (§2.6). |
| `teamLayout` at a non-global level | ignored; same warning mechanism, saying it is read from the global file only. |
| `init --layout` | error naming `create --mode`. |
| `--team` on roster-template verbs | error (§2.5). |
| `alias --set` in remedy texts | `validateHerdrName`'s `why`, `failUnnamablePrefix` (`roster.mjs:704-710`), and the `role set` warning name `create --team <short>` instead. r3: every unusable-name refusal — default name or explicit `--team`, any transport — is §2.8's one structured refusal; `failUnnamablePrefix` becomes (or is replaced by) its emitter. The suggestion is offered, never applied (0044 F3/§9.1). |

**Where the stale-key warnings surface (r4, review S4).** "Same warning mechanism" above means the
`staleTeamKeys` warnings (`teamAlias`, any `roster`/`rosters.<r>` `layout`, a non-global `teamLayout`).
r3 let them ride `resolveConfig`'s warnings into every SessionStart context and nudge, which would
repeat them in every session with nothing but a config edit to stop them; the old `init` asked for a
layout, so most existing rosters carry one.

- They appear in **CLI output only**: `status`, `doctor`, and `create` (every phase, `--from`
  included, where the `teamAlias` → `--team <alias>` hint already lives). Nowhere else is required.
- They never appear in hook-injected model context: SessionStart context, the SessionStart nudge,
  or any gate's reason text. Other `resolveConfig` warnings keep their channels unchanged. How the
  stale-key warnings are kept apart from the others is the Implementor's choice.
- Each warning's text ends by saying the key has no effect and that deleting it from the named file
  drops the warning.
- Still no config rewrite and no cleanup verb. The key is inert and the file is the user's; deleting
  a JSON key needs no tool.

`validateTeamAlias` keeps its name, rule, `why` strings, and role-token collision check (0010 §4.4); it
now validates team names and roster keys. Renaming it is churn with golden-file blast radius
(`tests/fixtures/0056-i1/golden/derived.json` records its results).

### 2.8 Team name check and the sanitizer

**Name check.** A team name is checked at `create` (every phase, and `spawn-one`/`spawn-ad-hoc`'s
implicit creation) by:

1. `validateTeamAlias` — always (it is a path segment and a prefix), as today.
2. **When the team's transport is `herdr`:** every member name the create would produce for a
   pane-routed member of the team's roster block — every role, with `-N` for counted members — must
   pass `validateHerdrName`, checked **before any pane opens**.

Any name that fails (1) or (2) — the default name (§2.2) or an explicit `--team`, on any transport —
gets the **structured refusal** below (r3). Nothing is launched or written.

Not transport-independent on purpose: tmux and terminal have no such rule today, and a repo named
`MyRepo` works there. Tightening every transport to Herdr's charset would break those users for a
constraint they do not have. `spawnShape`'s existing per-member check (`roster.mjs:1052`) stays as the
backstop for `spawn-one`/`spawn-ad-hoc` into an existing team. Whether (2) already holds via
`--plan` calling `spawnShape` is NEEDS-EVIDENCE N1.

**The sanitizer (r2, user ruling on U3/U4).** One implementation: **extend `suggestTeamAlias`**
(`lib-config.mjs:775`, F12) — do not add a second sanitizer. It gains optional context: the transport
and the roster block's member suffixes. Every caller that wants a suggestion goes through it: the
structured refusal below and `defaultTeamScope`'s `suggested` (`lib-roster.mjs:450`). Its result is
**only ever offered** — no code path creates a team under a name the sanitizer produced unless that
name arrived back as an explicit `--team` (0044 F3/§9.1 stands, r3). The skill **never** sanitizes;
it shows the suggestion the refusal carries (§3, agent-team row).

Rules:

- **No context, or a non-Herdr transport:** today's behaviour, **byte-identical** (F12). Existing
  suggestion outputs and any test pinning them do not move.
- **Herdr transport** (the result must satisfy both `validateTeamAlias` and, prefixed to every
  suffix, `validateHerdrName` — i.e. charset `[a-z0-9-]`, first character `[a-z]`):
  1. lowercase;
  2. map every character outside `[a-z0-9-]` to `-` (so `_` and `.` become `-`; a team name may not
     contain `_` even though Herdr allows it, because `validateTeamAlias` forbids it);
  3. collapse runs of `-` to one;
  4. strip leading characters until the first `[a-z]` (Herdr names cannot start with a digit or `-`);
  5. **budget** `B = 32 − L`, where `L` is the length of the longest member suffix `-<role>[-N]` over the
     block's pane-routed members; truncate to `B`, then strip trailing `-`;
  6. candidates in order: the result; `team-<result>` truncated to `B` with trailing `-` stripped;
     `team` if `B ≥ 4`. Return the first that passes `validateTeamAlias` (with the resolved config, so
     the role-token collision rule applies) **and** makes every member name pass `validateHerdrName`.
  7. none passes, or `B < 1`, or some role suffix is itself not Herdr-valid (e.g. a custom role with
     an uppercase letter) → **no suggestion**. No team name can fix that; the refusal names the
     offending member suffix and says to shorten or rename the role or its `--member` name.

Illustrative, not prescriptive — a block whose longest pane-routed suffix is `-ultra-advisor` (14 →
`B = 18`):
`My_Repo.Tools` → `my-repo-tools`; `2024-Experiments` → `experiments`;
`claude-tui-line-experimental-branch` → `claude-tui-line-ex`.

The budget uses the whole block, not only the members being spawned now, because later
`spawn-one`s into the same team derive names from the same frozen team name. Members added ad hoc
later with longer suffixes are caught by `spawnShape`'s backstop, as today.

**The structured refusal (r3, user ruling on U6).** The user: *"This is one place where I think
warrants asking the user."* Emitted by `create` (every phase, `--from` included), and by `spawn-one`
/ `spawn-ad-hoc` when they would create a team (§2.4 step 3), whenever the name fails the check
above. One emitter for all of them; `failUnnamablePrefix` (`roster.mjs:704-710`) becomes it or is
replaced by it. It follows the CLI's existing channels (F17): **JSON on stdout** (as `out()`/`partial()`
write it) **and exit 2** (as `fail()` exits), plus the `message` line on stderr prefixed `roster.mjs: `
so plain-text consumers still see a failure. It writes nothing and launches nothing.

Fields (all present on every refusal; `null` where not applicable):

| Field | Value |
|---|---|
| `ok` | `false` |
| `refused` | `"team-name-unusable"` — stable code; callers branch on it, not on text |
| `needs_user_choice` | `true` when `suggestion` is non-null (the fix is a name the user picks); `false` when no name can fit |
| `verb` | `"create"`, `"spawn-one"`, or `"spawn-ad-hoc"` |
| `name` | the rejected team name |
| `name_source` | `"basename"`, `"legacy-team"`, or `"explicit"` |
| `transport` | the transport the check used |
| `why` | the failing validator's `why` (`validateTeamAlias` or `validateHerdrName`) |
| `failing_member` | `{ "name", "length" }` of the longest failing derived member name under Herdr, else `null` |
| `suggestion` | `suggestTeamAlias`'s result with transport/block context, or `null` |
| `suggestion_why` | when `suggestion` is `null`: why no name can fit (names the role suffix) |
| `rerun` | the invoking command with `--team <TEAM>` added (any existing `--team` replaced), `<TEAM>` **literal**. A placeholder, not the suggestion, so the command cannot be run verbatim without a choice being made. `null` when `needs_user_choice` is `false` |
| `message` | the instruction text below |

**`message`** is written for a model that ran the command from a directive spawn line and has no
skill loaded, so it must carry the whole procedure. Required content (wording illustrative, content
normative):

- `needs_user_choice: true`: *"Team name `<name>` (`<name_source>`) can't be used: `<why>`. Do not pick
  a name yourself. Ask the user with AskUserQuestion — first option "Use `<suggestion>`
  (Recommended)", and let them type another name. Then re-run `<rerun>` with `<TEAM>` replaced by
  their answer. This is not a launch failure: do not offer the subagent opt-in."*
- `needs_user_choice: false`: *"No team name can make member names valid under `<transport>`:
  `<suggestion_why>`. Tell the user; the fix is a shorter or renamed role or `--member` name. Do not
  retry with a name of your own."*

A name the user typed that also fails produces the same refusal with `name_source: "explicit"`; the
driver asks again. Out of scope: the 0044 second-team collision refusal (`refuseLiveDefaultTeam`)
keeps its current form — it already asks via the skill, and unifying the two is not required.

**Route gate.** `spawnReason` (F17) gains one line **before** its failure line: if the command
refuses with `refused: "team-name-unusable"`, follow its `message` (ask the user for the team name,
re-run with `--team`); that is not a launch failure and does not lead to the subagent opt-in. The
existing failure line's scope is unchanged. After the re-run creates the team, later bare directive
spawns join it through §2.4 step 2 — no `--team` needs to be carried forward.

### 2.9 Live team files

- `teams/<n>.json`: nothing migrates. Missing `roster` → legacy rule (§2.5); missing `layout` → `auto`.
  A pre-upgrade live team whose roster had `layout: "grid"` gets `auto` for later `spawn-one` panes —
  cosmetic, accepted, noted in the changelog.
- legacy `team.json`: never moved or rewritten (0044 §1.7). Its prefix is frozen by inference (§2.1),
  which removes the alias-drift population F3 describes.

### 2.10 Peer self-attribution — a launch-time channel (r2)

**Goal.** Every session `roster.mjs` launches knows, in its own hook processes, which team file it
was launched into — from its first hook (`SessionStart`, before the team file may exist) onward —
without inferring it from other sessions' state.

**Channel.** An environment variable, **`AH_TEAM_FILE`**, whose value is the **absolute path** of the
team file the member is being launched into (`teamPath(home, team)` — `teams/<n>.json`, or the legacy
`team.json`). A path, not a name, because it is the identity form the message frontmatter already uses
(`team_file`, F15), it covers the legacy file (which has no name), and it survives a worktree peer
whose cwd is not the main checkout. Set by the launcher on every launch (`create --spawn`, `spawn-one`,
`spawn-ad-hoc`, any respawn) for every transport, always **explicitly** to the target team — never left
to inheritance, because a launch run from inside a peer's Bash tool would otherwise pass that peer's
own value to the new member.

A member's team is fixed for its lifetime: no verb moves a member between teams (`move` is pane
placement), so a launch-time value cannot go stale while the session runs. A team disbanded under a
running peer leaves the value pointing at a missing file; consumers treat that exactly as they treat a
missing team today.

**How the launcher sets it — decided by evidence (N3, N4), in this order of preference:**

1. **`claude --settings '{"env":{"AH_TEAM_FILE":"<path>"}}'`**, added to `agentFlags` (`roster.mjs:1070`).
   One mechanism for all three transports, including herdr (whose flags ride after `--`), with no shell
   dependence. Used **if N3 confirms** that settings `env` reaches hook processes and Bash-tool children,
   and that `--settings` merges with (does not replace) user, project, and plugin settings.
2. Otherwise, **`env AH_TEAM_FILE=<path> claude …`** as the command prefix for tmux (typed into the pane
   shell; `env` is an external binary, so it is shell-agnostic) and terminal (`/bin/sh -c`). For herdr,
   per N4: an env option on `herdr agent start` if one exists; else the launching process's own env if
   herdr passes the client's env to the agent (then `launchMember` sets it for that exec); else herdr
   members rely on the pane step below alone.

Either way the value must round-trip through every quoting layer (tmux's double-quoted `send-keys`
argument included): a repo path containing a space is a required test (P5). Reuse `spawnShape`'s
existing quoting; do not hand-roll a second quoter.

**Resolution — one implementation, two entry points.**

- `attributeSessionTeam` (`lib-roster.mjs:516`) gains a first step: the validated `AH_TEAM_FILE`. Order:
  **env → pane → role-scan**. `checkin`, `whoami`, and `sessionstart.mjs`'s `up`-row tag all go through
  it; `sessionstart.mjs:136` switches from `resolveSessionTeam` to `attributeSessionTeam` so the tag is
  right at launch. The pane step returning null at `SessionStart` (file not yet written) is harmless —
  env already answered. `whoami` output names which step answered (`env` / `pane` / `role-scan`).
- `resolveTeamScope` (`lib-config.mjs:1039-1057`) gains two steps **after** its three orchestrator
  steps: **(4)** the validated `AH_TEAM_FILE`; **(5)** the pane step, restricted to **live** teams
  (orchestrator pid alive), ambiguous → null. The role-scan is **not** added here: it is inference over
  other sessions' state, and a peer of a team whose file is not yet written would be attributed to a
  different team that happens to have one member of its role. Owner steps first means a session that
  owns a team always resolves to it, whatever its environment says. Reuse `attributeSessionTeam`'s env
  and pane steps rather than re-implementing them; if the `lib-config` → `lib-roster` import direction
  forbids that, move the shared piece — do not copy it.

**Validation of the env value (a path from the environment becomes a file path — trust boundary).**
Accept only if: absolute; its directory's realpath is `<H>/teams` with a basename `<n>.json` where
`validateTeamAlias(n)` passes, or the file is `<H>/team.json`; and `H`'s realpath is
`hierarchyDir(cwd)` or `mainHierarchyDir(cwd)` (the set `whoami` searches). The file need not exist
yet (SessionStart race). Anything else → the step yields null and resolution continues; no throw, no
block. Where `messageHome` (`lib-hier.mjs:206-211`) already implements "sits where team files sit",
share that check rather than writing a second one. `whoami` reports an ignored value in its
`env_team_invalid` detail field so a bad launch is diagnosable.

*(r4, review N6 — r3 made it the `reason`, which hid the real outcome.)* `whoami`'s `reason` is always
the attribution outcome the remaining steps produced (`null` on success, else `no-pane-id` / `no-team` /
`not-a-member` / `ambiguous`), never `env-team-invalid`. The ignored value goes only in
`env_team_invalid`, which carries the value and why it was ignored, and tells apart two cases:

- **other repo:** a well-formed team-file path under a hierarchy directory that is not this `--cwd`'s
  (`whoami --cwd <other repo>` from a correctly launched peer). The value is not wrong; it belongs to
  another repo.
- **malformed:** anything else validation rejects (relative, `../` escape, bad team name, not a
  team-file path).

The field is absent when `AH_TEAM_FILE` is unset or was accepted.

The value is not a privilege: a model cannot change its own hook processes' environment (a Bash-tool
`export` reaches only that command's children), and the only readers use it to pick a team scope,
which is what the launcher already chose. Owner steps precede it, so it cannot redirect an orchestrator.

**Attribution is never a destructive selector (r5, review B1).** r4's claim above, that "the only
readers use it to pick a team scope", was false: `sessionstart`'s stale sweep also read the scope, and
it deletes. The rule is:
- A team found only by attribution (the env step or the pane step, in `resolveTeamScope`,
  `attributeSessionTeam`, `memberTeam`, or `msg.mjs` `resolveTeamArg`) may be used to read, tag,
  scope a gate, and address messages.
- It must **never** be used to clear, delete, rename, or rewrite a team file, or to remove or
  overwrite a member record.

This covers hook code and the CLIs alike. Inherited or hand-set environment (`claude -p` from a
peer's Bash, a member relaunched by hand) can put any session in a team's scope, and being in scope
must not give it destructive reach. Destructive actions keep their existing selectors, none of which
is attribution: an explicit `--team`, an owner step, or §2.4 step 3's default scope. The sweep's
instance of this rule is in §2.4 (r5).

**Guard at commit.** `create --spawn` launches under a team name and `create --commit` persists under
one; both resolve it the same way (§2.2/§2.4), but a hand-typed mismatched `--team` would leave peers
pointing at a different file than the commit writes. `checkin` output carries the attributed team;
`create --commit` **refuses** when any `--verified` member object carries a `team` that is not the team
being committed, naming both. Member objects without a `team` field (hand-built JSON) are not checked.

**Effect on each peer-side consumer (F16):**

| Consumer in a peer session | Before | After |
|---|---|---|
| `pretooluse-route-gate.mjs` scope, prefix, roster read (`:162-165`) | null → basename fallback / default scope | the peer's own team |
| `sessionstart.mjs` `up`-row `team` tag | role-scan (null or wrong when ambiguous/unwritten) | env → pane → role-scan |
| `msg.mjs`/`createMessage` from a peer (`team_file` fallback) | fallback to a null team | the peer's own team |
| `checkin`, `whoami` | pane → role-scan | env → pane → role-scan |
| msg-gate, ultra-gate | never run for a peer (F16) | unchanged |
| `posttooluse-roster`, herdr-name-gate, roster-skill-gate | no team scope | unchanged |

**Residual null, stated so nobody rediscovers it:** a session `roster.mjs` did not launch and whose pane
matches no live team's member (a hand-started session), and a peer launched before this change on the
terminal transport (no pane). Both keep today's behaviour until respawned; neither is a spawned member
of a post-0057 team. A persisted per-session team (e.g. from an explicit `checkin --team`) would close
the first; not built until someone runs hand-started peers inside teams.

## 3. Files

| File | Change |
|---|---|
| `hooks/lib-config.mjs` | `teamPrefixInfo` per §2.2; `resolveRoster` takes roster key and prefix separately (§2.5); `resolveConfig` takes an optional roster key, else derives it from the resolved team; stale-key warnings (§2.7); remove `teamAlias` from the naming path and validation loop; `validateHerdrName` remedy text; `suggestTeamAlias` Herdr/budget mode (§2.8); global `teamLayout` read + validation (§2.6); `resolveTeamScope` steps 4–5 (§2.10). |
| `hooks/lib-roster.mjs` | legacy prefix inference (§2.1); team-file `roster`/`layout` fields; `attributeSessionTeam` env step first (§2.10); `defaultTeamScope`'s `suggested` passes transport/block context when the caller has it. |
| `hooks/roster.mjs` | owned-team scope step (§2.4); default team name (§2.2); the structured unusable-name refusal (§2.8, r3 — step 5); `--roster` on template verbs and `create`; `--team` refusal on template verbs; `create --mode` on all phases + `teamLayout` resolution and write-back (§2.6); record `roster`/`layout` at every team-creating write; `spawnOneCore` layout from team; `dismiss --also-config` mapping; `alias`/`layout` stubs; `init --layout` refusal; `role set` prefix + text; remedy texts; migration warnings; name check (§2.8); `show` alias fields removed; `AH_TEAM_FILE` on every launch (§2.10, mechanism per N3/N4); `whoami` answering-step + `env_team_invalid` detail (not a `reason`, r4); `checkin` output carries `team`; `create --commit` team-mismatch guard. |
| `hooks/msg.mjs` | `resolveConfig`'s new semantics — verify `msg roster --team` resolves the team's recorded key. *(r4, review N7 — r3 said "none", which was wrong: §2.10's `msg.mjs` consumer row needs this.)* `resolveTeamArg` (`msg.mjs:116-147`), with no `--team`, keeps its owner-pid scan first and then falls back to the session's attributed team — validated `AH_TEAM_FILE`, then the live-team pane match — through the same shared implementation `resolveTeamScope`'s steps (4)/(5) use (`memberTeam`), never a copy. The role-scan is not added here, for §2.10's reason. |
| `hooks/sessionstart.mjs` | `up`-row team tag via `attributeSessionTeam` instead of `resolveSessionTeam` (§2.10). r4 (S1): `sweepStaleTeam` passes the session's own identity (`process.ppid` + session id) so it never clears the session's own team by age (§2.4). r4 (S4): stale-key warnings excluded from its context and nudge (§2.7). |
| `hooks/lib-roster.mjs` (r4 addition) | the shared owner predicate and `teamIsLive`'s owned-team age exemption (§2.4, S1). |
| `hooks/pretooluse-route-gate.mjs` | r3, step 5: `spawnReason` gains the `team-name-unusable` line (§2.8). Otherwise as the next row. |
| `hooks/pretooluse-*.mjs`, `posttooluse-roster.mjs` | none expected; calls keep their two-argument form and gain correctness through `resolveTeamScope`. |
| `skills/agent-roster/SKILL.md` | remove init step 3 (layout), step 4a (team name), the `alias` and `layout` verb entries, `--layout` on `init`, and "team-prefix is the repo's `teamAlias`" (`:51`); `:74` and `:184-186` become `--roster <r>` (and say `--team` is refused here). |
| `skills/agent-team/SKILL.md` | create phase (r3): run a bare `create --plan` first. **Team name** question (moved 4a), one AskUserQuestion either way: if the plan succeeded, first option = the plan's team name (basename or legacy prefix); if it refused with `team-name-unusable` and `needs_user_choice`, first option = "Use `<suggestion>` (Recommended)"; then up to two recent names from `roster.mjs history` for this repo; free text via Other. The skill never computes or sanitizes a name (§2.8). If the user keeps a successful bare plan's name, keep every later phase bare; otherwise pass `--team <chosen>` to `--plan`/`--spawn`/`--commit` alike, and on a repeat refusal ask again. `needs_user_choice: false` → tell the user its `message`, stop. The existing unusable-name passages (`:51-55`, `:211-227`, which name `alias --set`) are replaced by this; **roster** question only when the plan output carries `named_rosters` (r4, S5), asked in the **same** AskUserQuestion call as the team name (a second question): first option the default roster, then up to three named keys, with Other for the rest. A named choice adds `--roster <r>` to every later phase; **no layout question** — pass `--mode` only when the user names a layout or asks to change it, and then ask once with the stored value marked (§2.6). Replace the `roster.mjs show`/"read roster's layout" step (`:198-208`) and every `alias --set` remedy (`:238-247`) with `--team`/`--mode`. State that the name is per-team and does not persist, and that an explicit layout becomes the default for future teams. |
| `skills/agent-role/SKILL.md` | only if it quotes the `role set` Herdr warning or `alias --set`; gopher found no mention — verify. |
| `docs/cli-tools.md` | rows `:119` (show `--roster`), `:121` (init: drop `--layout`, add `--roster`), `:125` layout and `:126` alias rows → removed (or one line: "removed; see create"), `:127` create gains `--roster <r>` and `--mode` on plan/commit (an explicit `--mode` is stored as the global `teamLayout`); note on `--team` = live team only; `whoami` answering-step field; r3: the `team-name-unusable` refusal's fields and exit code (§2.8). |
| `docs/team-file.md` | document `roster` and `layout` fields; legacy prefix inference; `AH_TEAM_FILE` and the attribution order. |
| `CONTEXT.md` | Roster: no name, no layout. Team: name chosen at create, frozen by its file; layout is the team's, defaulted from the global `teamLayout`. A member knows its team from its launch (`AH_TEAM_FILE`). |
| `docs/specs/0010-*.md`, `0011-*.md` (§5.3.3, §5.3.4), `0032-*.md` (§3), `0044-*.md` (§1.1 constraint 4, §8.1 `layout`/`alias`; r3: **no** note on F3/§9.1, which stands) | one-line supersession notes at the cited sections; do not rewrite. |
| `.claude-plugin/plugin.json` + root `.claude-plugin/marketplace.json` | minor version bump, both together. |

## 4. Must not change

- Derived member names for a repo with **no** `teamAlias` and no named rosters: byte-identical.
- `tests/fixtures/0056-i1/golden/*` byte-identical (`tests/test-custom-roles.sh` T1). If
  `tests/fixtures/0056-i1/render.sh`'s fixture config carries `teamAlias`, `layout`, or `rosters`,
  **stop and report** — golden churn would be a visible behaviour change this spec did not rule on.
  Ruled exceptions — the **only** permitted deltas; regenerate, and the Reviewer checks each golden's
  diff contains nothing else:
  1. (r2) where a golden records launch commands/flags: §2.10's `AH_TEAM_FILE` channel.
  2. (r3 amendment, orchestrator ruling) `plan-{herdr,tmux,terminal}.json`, which capture the full
     `create --plan` JSON: one added `layout: { mode, source }` object (§2.6's "reports the layout and
     its source"). Its values must follow from the fixture's inputs — with no `--mode` and no global
     `teamLayout` under the redirected `HOME`, `{ "mode": "auto", "source": "default" }`. Any other
     key added, removed, or reordered is not covered.
  3. (r4, review N5) the `status-report.txt` golden: exactly one line changes. `statusReport`'s
     (`lib-config.mjs:~2091`) `Team alias: none — agents named <X>-<role>` names a config concept
     this spec removes, so it becomes `Team name: <X> (<source>) — agents named <X>-<role>`.
     - `<X>` is the prefix the line already prints.
     - `<source>` is `team` when `statusReport`'s resolved team scope is non-null. Otherwise it is
       `teamPrefixInfo(cwd, null)`'s source: `legacy-team` or `default`.
     - In the golden this reads `Team name: <X> (default) — agents named <X>-<role>`, with `<X>`
       unchanged. No other line of that golden may move.
     - `status` does not run §2.8's check and never refuses.
- Suggestions from `suggestTeamAlias` with no context or a non-Herdr transport: byte-identical (§2.8).
- A machine with no global config file gets none from a create without `--mode` (§2.6).
- `teamPrefix(`/`teamPrefixInfo(` keep two arguments; test 11's static rule stays.
- `validateTeamAlias`'s rule and `why` strings (0011 §10).
- 0044's invariants: no new shared `team.json`; roster read-only during a team lifecycle (§1.2/§1.3
  refusal unchanged); one launch path; `add` spawns nothing.
- 0044 §1.11's ownership truth table for `create`.
- The 24h age cap for teams **not** owned by the invoker, and `teamIsLive`'s answer for callers
  that have no invoker identity (`doctorReport`, `historyEntryIsActive`) (r4, S1).
- The stale sweep's reach never grows beyond HEAD's. A team found only by attribution (env or pane)
  is never the target of any destructive action (r5, B1, §2.10).
- `msg new/list --team` semantics; `createMessage`'s delivery model.
- Every gate's fail-open posture (0009 §8.12, 0011 §9.6) and predicate (ii) — a null scope still
  never blocks; §2.10 only makes null rarer.
- `peers.jsonl` format (the `up` row's `team` field just gets a better value); the pane and role-scan
  steps of `attributeSessionTeam` and their order relative to each other.
- `resolveTeamScope`'s three orchestrator steps and their precedence over §2.10's steps.
- Live teams across the upgrade (§2.9).

## 5. Implementation plan — ordered, each step buildable and green

**Step 1 — the team carries its own identity (additive).**
Team-creating writes record `roster` and `layout`; `create` accepts `--mode` on all phases; global
`teamLayout` resolution and write-back (§2.6); `spawnOneCore` reads layout from the team (falling back
to the roster's for this step only, so nothing regresses before step 5); legacy `team.json` prefix
inference; `teamPrefixInfo`'s null branch prefers the legacy frozen prefix, then alias, then basename
(alias removed in step 5). All tests redirect `HOME` (the global file is `~/.claude/agent-hierarchy.json`).
*Accept:* A1 a new team file has `roster` (null) and `layout`; A2 `create --plan --mode grid` → plan and
committed team say `grid`, next `spawn-one` pane uses `grid`; A3 a legacy `team.json` whose members are
`ct-*` yields prefix `ct` with no `teamAlias` configured; A4 no global file, bare `create --plan/--commit`
→ layout `auto` source `default`, no prompt, no global file created; A5 `create --commit --mode columns`
→ global `teamLayout: "columns"`, every other key of a pre-existing global file unchanged; the next bare
`create --plan` reports `columns` source `stored`; `create --plan --mode grid` alone writes nothing;
A6 with no global file, after A5's write the resolved roster, `enabled`, `route`, `msgs`, `handoffs`,
`roles`, and `show`'s level report are identical to before; A7 `teamLayout` in a repo-level file or an
invalid value → ignored with a warning; A8 unwritable global file → create succeeds, warns; A9 full suite
green.

**Step 2 — owned-team scope (§2.4).**
*Accept:* B1 session pid P owns live `teams/ct.json`, repo basename `claudetools`, no alias: bare
`spawn-one architect` (as the directive emits it) joins `ct`, member `ct-architect`, no
`teams/claudetools.json` written — **fails against 0.87.0**; B2 P owns two live teams → bare `spawn-one`
refuses, lists both, writes nothing; B3 no pid resolvable → today's behaviour; B4 bare `create --plan` by
the owner of a live team → refused (0044 §1.11 row), bare `create --commit` → allowed; B5 `adopt`
unaffected; B6 (r4, S1) the same setup as B1 and B4 with `created` backdated 25h:
- bare `spawn-one architect` joins `ct`, and no `teams/claudetools.json` is written;
- bare `create --plan` refuses, and `teams/ct.json` is byte-identical afterwards;
- `sweepStaleTeam`, run for a session whose pid is P, leaves it in place;
- a 25h-old team owned by a *different* live pid is still treated as stale exactly as today.

B7 (r4, S1) `create --commit --session s2` into a team recording `session_id: "s1"` under the same pid
→ not owned by the invoker (the pid-reuse guard).

B8–B10 (r5, review B1) use the probe's shape, with a redirected `HOME`. Setup:
`teams/tt.json` whose owner pid is a live process (e.g. `sleep`) that is **not** the SessionStart
invoker, `created` 25h ago, and one member with `transport_id: "%77"`. Each runs a plain (no `--agent`)
SessionStart for a different session.
- B8, pane case: `TMUX_PANE=%77` → `teams/tt.json` still exists, byte-identical.
- B9, env case: `AH_TEAM_FILE=<abs …/teams/tt.json>` → same assertion.
- B10, control that keeps the sweep's reach:
  - with no env and no pane, a legacy `team.json` whose owner pid is dead is still cleared, as at
    HEAD;
  - with `AH_TEAM_FILE` or a pane match set, that same legacy file is left alone.

**Step 3 — peer self-attribution (§2.10).** Blocked on N3 (and N4 if N3 is negative) for the
launcher mechanism only; the resolution side (`attributeSessionTeam`, `resolveTeamScope`, validation,
`sessionstart` tag, commit guard) does not depend on it and can land first, tested by setting
`AH_TEAM_FILE` in the hook's test environment directly.
*Accept:* P1 hook run with `AH_TEAM_FILE=<repo>/.../teams/ct.json`, session owning nothing →
`resolveConfig(cwd,{sessionId}).team === "ct"`, and route-gate derives `ct-*` names — **fails against
0.87.0**; P2 same env, but the session's pid owns live `teams/zz.json` → `zz` (owner steps first);
P3 values rejected by validation (relative path, `../` escape, a `teams/` dir in another repo, a name
failing `validateTeamAlias`) → step yields null, no throw, `whoami`'s `env_team_invalid` names the
value as malformed while `reason` stays the outcome of the pane/role-scan steps (r4, N6); P3a a
well-formed team-file path of repo A, `whoami --cwd <repo B>` → `env_team_invalid` says other repo,
not malformed; P4
`sessionstart` with env set and no team file yet → `up` row tagged with the env team; P5 dry-run
launch shapes for tmux, terminal, and herdr carry the channel with the correct value for a repo path
containing a space, and a launch run with a different `AH_TEAM_FILE` already in the environment sets
the target team's value, not the inherited one; P6 no env, pane matching a live team's
`transport_id` → that team; pane matching only a dead team → null; P7 `create --commit --team b` with
a verified member object carrying `team: "a"` → refused, nothing written; P8 full suite green. Live
end-to-end (a real spawned peer's hook sees the value) is covered by N3/N4's run, not by this suite.

**Step 4 — `--roster` splits from `--team` (§2.5).**
*Accept:* C1 `create --team hotfix --roster hotfix` builds from `rosters.hotfix`, team file `roster:
"hotfix"`; C2 `create --team hotfix` with `rosters.hotfix` present and no `--roster` → default block +
warning naming `--roster hotfix`; C3 `create --roster nope` → error, nothing written/launched; C4
`init/add --team X` → error naming `--roster`, all level files byte-identical; C5 a team file lacking
`roster` named `hotfix` resolves `rosters.hotfix` (legacy rule); C6 `spawn-one` into a team with
`roster: "hotfix"` uses that block's definition without `--roster`; C7 `msg roster --team hotfix` lists
from the recorded block; C8 `dismiss --also-config` on `hotfix-implementor` edits `rosters.hotfix`, and on
an ad hoc member edits nothing; C9 0032's T5/T6 level-precedence cases pass with `--roster`.
C10 (r4, S5) with `rosters.hotfix` at repo level and `rosters.alt` at global, bare `create --plan`
output has `named_rosters: ["alt", "hotfix"]`; with no `rosters` anywhere the key is absent.
Rewrite `tests/test-roster-team-override.sh` (0032 T1–T19) to the new flags; T17 becomes
`create --plan/--commit --team X --roster hotfix`.

**Step 5 — `teamAlias` and roster layout leave; the unusable-name refusal (§2.2, §2.7, §2.8).**
*Accept:* D1 config with `teamAlias: "ct"`, no teams: bare `create --plan` names `claudetools`, output
warns and names `--team ct`; D2 `alias` and `layout` verbs exit non-zero naming the replacement; D3
`init --layout grid` errors; D4 a roster `layout: "grid"` no longer affects any plan, and resolveConfig
warns; D5 static: `teamAlias` appears in `hooks/` only in the stale-key warning; no `hooks/` file reads a
roster block's `layout`; D6 (r3) unnamable basename `my_repo` on tmux: bare `create --plan` exits 2,
stdout is the §2.8 JSON with `refused: "team-name-unusable"`, `needs_user_choice: true`, `name: "my_repo"`,
`name_source: "basename"`, `suggestion: "my-repo"`, `rerun` containing `--team <TEAM>` literally;
stderr carries the `message`; no team file, history row, or global file written; D7 (r3) herdr
transport, basename whose longest member name exceeds 32 or contains uppercase: bare `create --plan`
**and** a bare `spawn-one`/`spawn-ad-hoc` with no team yet each give the same refusal (`verb` set
accordingly), `failing_member` set, `suggestion` = the Herdr-mode name whose every derived member
passes `validateHerdrName`; nothing launched; re-running with `--team <suggestion>` succeeds and a
following bare `spawn-one` joins that team (§2.4 step 2); D8 herdr, explicit `--team` whose longest
member name exceeds 32: the same refusal with `name_source: "explicit"`, before any pane opens; the
same `--team` on tmux proceeds; D9 a block with a Herdr-invalid role suffix under herdr →
`needs_user_choice: false`, `suggestion`/`rerun` null, `suggestion_why` names the role; D9a the
`message` for D6–D8 contains "AskUserQuestion", "(Recommended)", the suggestion, and an instruction
not to pick a name, and does **not** contain the subagent opt-in command; D9b static: `spawnReason`
names `team-name-unusable` ahead of its launch-failure line; D10 `suggestTeamAlias` without context returns today's outputs for a fixed table of inputs
(including `My_Repo`, `.hidden`, a 40-char name); D11 `role set` warning names the assumed prefix and
`--team`, not `alias --set`; D12 all goldens byte-identical apart from §4's ruled exceptions (three as of r4); D13 (r4, S4) a
repo config holding `teamAlias` and `roster.layout`: SessionStart context and nudge contain neither
warning; `status`, `doctor`, and bare `create --plan` output each contain both, and each ends by saying
that deleting the key drops the warning.
Rewrite the `teamAlias`/alias-verb suites (grep `tests/` for `alias`, `teamAlias`, ` layout `,
`--layout`): they encode removed behaviour — invert to D1–D3, don't delete coverage of validation.
`test-roster-multi-team.sh` 8a/8b (alias refusal / read-only alias) → replaced by D2; its
`resolveConfig({team:'alpha'})` roster-filtering lines (~52-61) → C5/C6 shape. Existing tests that
assert bare `create` refuses on an unnamable basename stay refusals (0044 §9.1 stands, r3); update
their expected output to D6's JSON and replace any `alias --set` expectation.

**Step 6 — surface (§3 docs/skills rows), supersession notes, version bump.**
*Accept:* E1 `skills/agent-roster/SKILL.md` contains no `alias`, `teamAlias`, `layout`, `--layout`, or
`--team`; E2 `skills/agent-team/SKILL.md`'s create phase runs a bare `create --plan`, asks the team name
in one AskUserQuestion (plan's name, or the refusal's suggestion marked "(Recommended)", plus history
names), re-runs with `--team` on any non-default choice, handles `needs_user_choice: false` by telling
the user, asks the roster only when the plan's `named_rosters` is present (r4, S5), asks **no** layout question unless the user asks to change the
layout, and contains no `alias --set`; E3 `docs/cli-tools.md` has no `alias`/`layout` verb row and
documents `--roster`, `teamLayout`, and the `team-name-unusable` refusal; E4 both version files bumped
equally; E5 (r3) 0044 §9.1 carries **no** supersession note.

Mechanism-before-surface ordering follows 0044 §8.5.

## 6. Decisions

**Made:**
- No `name` field in `teams/<n>.json`; the filename is the frozen identity (§2.1).
- Legacy `team.json` prefix frozen by inference from its members, not by rewriting it (§2.1, §2.9).
- `teamPrefixInfo` keeps its signature; null → legacy frozen prefix → basename (§2.2).
- ~~Peer-side hooks accept the fail-open degradation~~ (r1; withdrawn in r2 — user rejected it).
  Peers attribute their team from a launch-time `AH_TEAM_FILE` (absolute path), resolved env → pane
  (→ role-scan only in `attributeSessionTeam`), owner steps always first (§2.10). "Sole live team"
  fallback still rejected (§2.3).
- Stored layout is a top-level **global-only** key `teamLayout`; an explicit `--mode` on `--spawn`/
  `--commit` writes it; `--plan` never writes; history no longer records layout (§2.6).
- One sanitizer: `suggestTeamAlias` extended with a Herdr/budget mode, byte-identical without context.
  r3: its result is **only offered**, in one structured refusal (`team-name-unusable`, stdout JSON +
  exit 2, `rerun` with a literal `<TEAM>` placeholder) whose `message` tells any driver to ask the
  user; the route gate's spawn directive points at it (§2.2, §2.8).
- Team verbs resolve the invoking session's owned team before the default scope (§2.4) — required,
  because directive spawn lines carry no `--team` (F6/F7).
- Team records `roster` and `layout`; explicit `--roster` is strict at create, recorded keys are
  lenient at read, pre-0057 teams keep 0032's name-keyed rule (§2.5).
- `--team` on template verbs errors rather than aliasing to `--roster` (§2.5).
- Layout option spelled `--mode` (existing spelling) on every create phase (§2.6).
- Removed verbs become signpost stubs; stale config keys warn, never rewritten (§2.7).
- Herdr check at create is transport-conditional (§2.8).

**Ruled by the user (r2):**
- **U1** → stored global preference, updated by an explicit choice, prompt only on a change request (§2.6).
- **U2** → warn and use the default block (r1's choice stands).
- **U3/U4** → default = basename; skill also offers history names; an unusable basename gets a
  sanitized suggestion (§2.2, §2.8) — r3: offered to the user via a refusal, never applied.

- **U5** (r3) → accepted: first-ever create with nothing stored uses `auto`, no prompt.
- **U6** (r3) → reversed: the CLI never applies a sanitized name, on any transport; it refuses with a
  suggestion and the driver asks the user ("This is one place where I think warrants asking the
  user."). 0044 F3/§9.1 stands.

**Open:** none from r2. One consequence to know: in a repo whose basename is unusable, every new team
triggers the question (nothing stores the answer — the name is per-team, U3). The skill's history
option makes a repeat choice one click.
- Not ruled: whether a session may join a live team it does not own (§2.4); `disband --commit` on a
  foreign team (0044 §10.3, still open).

## 7. NEEDS-EVIDENCE

- **N1.** Under `transport: herdr`, does `create --plan` (or `--spawn` before its first pane) already
  run `validateHerdrName` on every planned member via `spawnShape`? Run `create --plan` in a sandbox repo
  whose basename makes `<basename>-ultra-advisor` exceed 32 chars, with Herdr transport forced. *Refuses
  before output of any launch* → §2.8(2) is test-only plus message text. *Plans successfully* → §2.8(2)
  is new code in the plan path.
- **N2.** Does `create --spawn` write a team file itself, or only `--commit`/`spawnOneCore`? Decides
  which write sites §2.5/§2.6's "record at every team-creating write" touches. Answerable by reading;
  the Implementor settles it at step 1 and reports.
- **N3 (r2, blocks §2.10's launcher mechanism).** Launch `claude --settings '{"env":{"AH_TEAM_FILE":"/tmp/x y/teams/t.json"}}' -p "run: echo \"$AH_TEAM_FILE\""`
  in a sandbox with a throwaway plugin whose `SessionStart` and `PreToolUse` hooks append
  `process.env.AH_TEAM_FILE` to a file, and with a user-level `settings.json` holding its own `env` key
  and a plugin hook. Record: (a) does each hook see the value; (b) does the Bash-tool child see it;
  (c) do the user-level `env` key and the pre-existing plugin hooks still apply (merge, not replace);
  (d) does the same hold when the flags ride after `herdr agent start … --`. **All yes** → mechanism 1
  for every transport. **(a) no, or (c) no** → mechanism 2 and run N4. **(b) no** → mechanism 1 still
  serves hooks; report it, since `checkin`/`whoami` run via Bash would then need the pane step.
- **N4 (r2, only if N3 is negative).** Herdr: does `herdr agent start` take an env option; does the
  started agent inherit the env of the `herdr agent start` client process; and is `HERDR_PANE_ID` set
  in the agent's env (F15's pane step depends on it, unverified from this repo). **Env option** → use
  it. **Inherits client env** → set it on the launch exec. **Neither, but `HERDR_PANE_ID` present** →
  herdr members use the pane step alone; §2.10's `SessionStart` tag falls back to role-scan for them.
  **Neither and no `HERDR_PANE_ID`** → herdr peers cannot be attributed; stop and report — that is the
  one outcome this spec cannot close (see §8).

## 8. Confidence and escalation

High on §2.1, §2.2, §2.5–§2.8: traced at the cited lines, local, reversible, with read-compat for every
live artefact. Medium on §2.4: it changes which team a bare team verb acts on for any session that owns
one — correct by the principle and fixes F7, but it is a behaviour change on a shipped surface; B1–B5 pin
it. §2.6's global write-back: high on the logic, medium on the A6 invariant (that a key-only global file
changes no resolution) until A6 runs.

§2.10: high on the resolution side (it extends existing primitives and keeps owner-first precedence);
the launcher mechanism is **decided by N3/N4, not by reasoning** — the spec gives the rule for each
outcome. Not recommending Ultra-Advisor: the env value is validated as a path, confers no privilege, and
cannot redirect an owner; every gate keeps its fail-open posture. Escalate only on N4's last outcome
(herdr offers no env path and no pane id), with the question: *how does a herdr-launched peer learn its
team when neither environment nor pane identity reaches it?*
