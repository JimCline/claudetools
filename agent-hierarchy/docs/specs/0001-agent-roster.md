# Spec 0001 — `/agent-roster`: roster levels, team creation, check-in registry

Status: draft (design settled in the 2026-08-21 grill-with-docs interview; not yet implemented)
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Roster level, Whole-level replace, Route, Auto-mode, Orchestrator, Team, Check-in registry, Disband)
Decisions referenced: `docs/adr/0001-multi-transport-peer-support.md`, `docs/adr/0002-check-in-registry-dispatch-source.md`

## 1. Goal

Move all team-shape configuration out of `/hierarchy` into a new `/agent-roster` skill, add
three-level roster resolution with whole-level replace, and make a per-team **Check-in registry**
the authoritative peer-dispatch source (ADR 0002), replacing `ListAgents` name-guessing inside a Team.

`/hierarchy` is reduced to on/off + handoff flow + read-only status/inspection.

## 2. What already exists (do not rewrite)

Verified against the tree at spec time:

- `hooks/lib-config.mjs` — two config layers: `~/.claude/agent-hierarchy.json` (`userConfigPath()`, L217)
  and `<cwd>/.claude/agent-hierarchy.json` (`projectConfigPath()`, L221). `resolveConfig(cwd)` (L256)
  merges them per-key, role objects replaced wholesale. `peerName(repoBasename, role)` (L139) returns
  `` `${repoBasename}-${role}` ``. `subagentType(role, entry)` (L393). `buildDirective` (L499),
  `buildNudge` (L547), `statusReport` (L573).
- `hooks/lib-hier.mjs` — runtime dir `hierarchyDir(cwd)` (L61, `.claude/hierarchy` at git root, or
  `~/.claude/hierarchy/<repo>`, `AGENT_HIERARCHY_DIR` override), `readJsonl`/`appendJsonl`,
  `newId(now)` (L118), `pidAlive(pid)` (L467), `peersPath` (L82), `readRoster`/`appendRosterRecord`
  (L440/L444), `roster(...)` (L482), `roleForPeerName(name, resolved, repoBasename)` (L433),
  `buildStateBlock(...)` (L601).
- `hooks/posttooluse-roster.mjs` — the actual `ListAgents` line parser (`LINE_RE`, L24) that appends
  `{type:"peer",status:"seen",name,ref,role,busy}` records to `peers.jsonl`.
- `hooks/pretooluse-route-gate.mjs` — role resolution for `Agent`/`Task` dispatch and `SendMessage`
  briefs (L144–158).
- `hooks/msg.mjs` — precedent for a deterministic CLI backing a prose command surface.
- `commands/hierarchy.md` — subcommands `init | status | set | on | off | flow | gate | usage | msgs | peers | route | sweep`.
- Skill convention in this repo: `<plugin>/skills/<name>/SKILL.md` with `name` + `description`
  frontmatter (only existing example: `output-discipline/skills/output-discipline/SKILL.md`).
  `agent-hierarchy/` currently has **no** `skills/` dir.
- Tests: `agent-hierarchy/tests/test-*.sh`, standalone bash, no harness.

**`hooks/lib-peer.mjs` is NOT part of this change.** The dispatch brief listed it, but it only tracks
peer report-back obligations in `~/.claude/agent-hierarchy.peer-pending.jsonl`. It touches neither
`peers.jsonl` nor `ListAgents` matching. Leave it alone.

## 3. Roster levels

### 3.1 Paths

| Level | Path |
|---|---|
| global | `~/.claude/agent-hierarchy.json` (existing `userConfigPath()`) |
| repo | `<repo-root>/.claude/agent-hierarchy.json` (existing `projectConfigPath()`) |
| repo-user | `~/.claude/agent-hierarchy/projects/<slug>/agent-hierarchy.json` (**new**) |

`<slug>` is the repo's absolute realpath with every `/` replaced by `-`, leading `-` preserved —
the same convention Claude Code uses for `~/.claude/projects/`. Confirmed by observation:
`/Users/jimcline/git/repos/claudetools` → `-Users-jimcline-git-repos-claudetools`.

Deliberately **not** written under `~/.claude/projects/<slug>/` — that directory is Claude Code's own
and a plugin writing into it risks collision. Use `~/.claude/agent-hierarchy/projects/<slug>/`.

`<repo-root>` for the repo level: reuse whatever `hierarchyDir()` already uses to find the git root,
so all three paths agree on what "this repo" means. Extract that into an exported helper if it is
currently inline.

### 3.2 File schema

The roster lives as a new top-level `roster` key in the **existing** config file at each level — one
file per level, not a second parallel file.

```jsonc
{
  "version": 1,
  "enabled": true,             // existing keys, existing per-key merge semantics
  "handoffs": "auto",
  "roster": {                  // NEW — resolved by whole-level replace, NOT per-key merge
    "route": "peer",           // team-wide default route: "peer" | "subagent"
    "members": [
      {
        "role": "architect",         // architect|implementor|reviewer|task-runner|ultra-advisor
        "model": "opus",             // same value set lib-config.mjs already validates per role
        "effort": "high",            // see NEEDS-EVIDENCE #1
        "route": "peer",             // OPTIONAL per-member override of roster.route
        "autoMode": "acceptEdits"    // see NEEDS-EVIDENCE #2
      }
    ]
  }
}
```

Constraints:
- `roster.members` MUST NOT contain a member with `role: "orchestrator"`. Reject at write time with a
  message pointing at the glossary: the Orchestrator is the session that runs `/agent-roster create`.
- Any role may appear multiple times. Order within the array is significant (§3.4).
- `roster.route` is required when `roster` is present. Member `route` is optional; absent ⇒ inherit.
- A member's `name` is **never stored** — it is derived (§3.4) so renaming the repo directory does not
  strand a stale roster.

### 3.3 Resolution — whole-level replace

Add to `lib-config.mjs`:

```js
export function rosterLevelPaths(cwd)   // → { global, repo, "repo-user" } absolute paths
export function pathSlug(absPath)       // → "-Users-..." slug
export function resolveRoster(cwd)      // → { level, route, members: [...withNames], path } | null
```

`resolveRoster` reads the three files in precedence order **repo-user → repo → global** and returns
the first one whose `roster` key is present and non-empty, in its entirety. No merging across levels.
The returned object records which `level` and `path` won, for `/agent-roster show` and `/hierarchy status`.

`resolveConfig(cwd)` changes:
- add `repo-user` as a **third layer at highest precedence** for the existing per-key merge
  (`enabled`, `handoffs`, `msgs`, `route`, `roles`). This is additive — no such file exists today, so
  no existing behaviour changes.
- expose `resolved.roster` (the `resolveRoster` result) and `resolved.rosterLevel`.
- keep `resolved.roles` and its defaults exactly as-is. It remains the fallback used when
  `resolved.roster` is `null` (§8 back-compat).

### 3.4 Member naming

Derived at resolve time, matching today's `peerName()` for the single-member case:

```
first member of a role  → `${repoBasename}-${role}`          // e.g. claudetools-architect
second, third, ...      → `${repoBasename}-${role}-2`, `-3`   // ordinal = 1-based index within
                                                              // that role, in array order, ordinal 1 bare
```

Implement as `rosterMemberNames(members, repoBasename)` in `lib-config.mjs`, returning `members` with a
`name` field added. `peerName()` stays as-is and is the ordinal-1 case of this function; do not
duplicate the template string.

Consequence to call out to the Implementor: removing a member shifts the ordinals of later same-role
members. That is acceptable because names are only meaningful for the lifetime of a Team, and a Team's
authoritative names live in the check-in registry (§5), not in the roster.

## 4. `/agent-roster` skill

### 4.1 Files

- **NEW** `agent-hierarchy/skills/agent-roster/SKILL.md` — the prose surface. Frontmatter `name: agent-roster`,
  `description:` naming the triggers (define/edit the team roster, spawn the team, disband it).
  Follow `output-discipline/skills/output-discipline/SKILL.md` for frontmatter shape.
- **NEW** `agent-hierarchy/hooks/roster.mjs` — deterministic CLI doing all file I/O, mirroring `msg.mjs`:
  `--cwd <path>` on every subcommand, JSON out unless `--plain`. The SKILL.md drives this CLI rather
  than hand-editing JSON, so validation lives in one place.
- **NEW** `agent-hierarchy/hooks/lib-roster.mjs` — roster + team schema, validation, check-in registry
  I/O. `lib-hier.mjs` is already 613 lines; do not grow it further.

### 4.2 Command surface

Canonical form is flags. Level may also be given positionally as the first bare word (the shape the
user asked for): `/agent-roster add repo --role architect` ≡ `--level repo`.

```
/agent-roster                     → same as `show`
/agent-roster show    [--level global|repo|repo-user]
/agent-roster init    [--level L] [--route peer|subagent]
/agent-roster add     [--level L] --role R [--model M] [--effort E] [--route peer|subagent] [--auto-mode A]
/agent-roster edit    [--level L] --member NAME [--role R] [--model M] [--effort E] [--route ...] [--auto-mode A]
/agent-roster remove  [--level L] --member NAME
/agent-roster create  [auto|manual]
/agent-roster disband
```

Behaviour:

- **`show`** — prints the resolved roster: winning level, path, each member's derived name, role, model,
  effort, effective route, auto-mode. With `--level`, prints that level's file even if it loses
  precedence, and says so ("shadowed by repo-user").
- **`init`** — writes a fresh `roster` block at one level, **replacing** whatever was there.
  - Missing `--level` ⇒ ask via AskUserQuestion (global / repo / repo-user), with one line each on what
    the level means.
  - Missing `--route` ⇒ ask peer-vs-subagent as the **team-wide default** (this is the first question in
    the Initial Setup flow, §7).
  - Then walk the roles interactively: for each of architect / implementor / reviewer / task-runner /
    ultra-advisor, ask whether to include it and with what model/effort/auto-mode. Defaults offered
    should be `ROLE_DEFAULTS` from `lib-config.mjs` — do not invent a second default table.
  - Destructive: if that level already has a roster, confirm before replacing.
  - Note the asymmetry explicitly in SKILL.md: whole-level replace is a *read-time* rule; `init` itself
    only ever writes one level's file.
- **`add` / `edit`** — operate on one level's file. Any field not supplied on `add` is prompted for;
  `edit` changes only supplied fields.
  - **RESOLVED (confirmed 2026-08-21):** a bare `add`/`edit` with no `--level` defaults to the level the
    roster currently resolves from (repo-user > repo > global) and **must print which level it chose**.
    If no roster resolves at any level, error and point at `init`.
- **`remove`** — **RESOLVED (confirmed 2026-08-21):** the signature is
  `remove [level] --member <name>`, where `<name>` is the derived name from §3.4. The interview's
  original `remove [level] [auto-mode]` shape was a transcription artefact — auto-mode identifies no
  member — and is not implemented. There is no auto-mode-filtered removal.
- **`create [auto|manual]`** — §6.
- **`disband`** — §5.3.

`--level` values are exactly `global`, `repo`, `repo-user`.

## 5. Check-in registry

### 5.1 Location and schema

One active Team per repo. File: `<hierarchyDir(cwd)>/team.json` — i.e. alongside `peers.jsonl` and
`gates.jsonl`, inside the existing runtime dir, so `AGENT_HIERARCHY_DIR` overriding still works and
tests can redirect it.

JSON (not JSONL — this file is rewritten as a whole, and is small):

```jsonc
{
  "version": 1,
  "team_id": "20260821-101500-a3f2",        // lib-hier.mjs newId()
  "created": "2026-08-21T10:15:00-07:00",   // lib-hier.mjs localIso()
  "roster_level": "repo-user",              // which level this Team was instantiated from
  "transport": "herdr",                     // "herdr" | "tmux" | "terminal"  (ADR 0001)
  "orchestrator": { "session_id": "…", "pid": 12345 },
  "members": [
    {
      "role": "architect",
      "name": "claudetools-architect",      // the VERIFIED live session name
      "ref": "3fa9c1",                      // ListAgents ref, if known
      "route": "peer",                      // "subagent" members are recorded too, see below
      "model": "opus",
      "effort": "high",
      "auto_mode": "acceptEdits",
      "transport_id": "%12",                // herdr pane id / tmux pane id / null
      "checked_in": "2026-08-21T10:15:42-07:00"
    }
  ]
}
```

Writes are atomic: write `team.json.tmp` then `rename()`.

`route: "subagent"` members ARE recorded, with `name`/`ref`/`transport_id` null and `checked_in` set at
create time. They are not dispatch targets by name, but recording them makes `show`/status honest about
what the Team is, and lets a later `create` detect that the roster already ran.

### 5.2 Authoritative dispatch (ADR 0002)

New in `lib-roster.mjs`:

```js
export function readTeam(dir)                     // → team object | null
export function writeTeam(dir, team)              // atomic
export function teamMemberByName(dir, name)       // → member | null
export function teamMembersForRole(dir, role)     // → [member]  (peer-routed only)
export function clearTeam(dir)                    // unlink team.json; no-op if absent
```

Consumers change as follows — **team.json first, existing paths as fallback**:

- `hooks/pretooluse-route-gate.mjs` L144–158: in the `SendMessage` branch, resolve the role by
  `teamMemberByName(dir, to)?.role` **before** the existing `resolvedPeerTargets` config lookup and
  before the live-roster fallback. Both existing lookups stay, unchanged, as the ad-hoc-peer path.
- `hooks/lib-hier.mjs` `roleForPeerName(name, resolved, repoBasename)` L433: same — consult
  `teamMemberByName` first, then the existing config-target match, then the token fallback. This is the
  single choke point `posttooluse-roster.mjs` goes through, so `peers.jsonl` classification improves for
  free without touching that file.
- `hooks/lib-hier.mjs` `buildStateBlock(...)` L601: when a team.json exists, render the Team table
  (role → verified name → busy/idle from the live roster) as the dispatch table, and label it
  "Team <team_id> (authoritative)". When absent, render today's roster block unchanged.

Do **not** delete the `ListAgents` path. Per ADR 0002 it remains the ad-hoc-peer fallback.

### 5.3 Disband and staleness

Disband tears down the **registry only**. It does NOT kill panes or sessions — those may hold work that
has already cost tokens, and terminating them is the user's call. `disband` prints the member names and
`transport_id`s so the user can close them, and unlinks `team.json`.

- Explicit: `/agent-roster disband`.
- Safety net: a stale-team sweep in **`hooks/sessionstart.mjs`**, which already runs on every session
  start and already has `hierarchyDir` and `resolveConfig` in hand. No new hook, no timer.

Sweep rule, evaluated once per SessionStart, before the state block is built:

```
team = readTeam(dir)
if team and (
     !pidAlive(team.orchestrator.pid)                    // orchestrator gone
  || ageSec(team.created) > 24*3600                      // hard age cap
) → clearTeam(dir), and note "cleared stale team <id>" in the injected block
```

`pidAlive` (lib-hier.mjs L467) and `ageSecOf` (L141) already exist. 24h is a deliberate blunt ceiling —
mark it with a `ponytail:` comment naming the ceiling, not a config knob.

Guard: the sweep must not fire in the Orchestrator's own session before it has written the registry, and
must not fire in a member session. Both are covered by running it only when
`!isSubagent(input) && !isTopLevelAgentSession(input)` — i.e. only in plain top-level sessions, which is
exactly where a *different* session's abandoned team would be observed. Member sessions launched with
`--agent <role>` are `isTopLevelAgentSession` and skip it.

## 6. `create` — instantiating a Team

`/agent-roster create [auto|manual]`, default `auto`.

1. Refuse if `readTeam(dir)` returns a live team (orchestrator pid alive). Tell the user to `disband`
   first. A stale one is cleared by the same rule as §5.3 and create proceeds.
2. Resolve the roster (§3.3). If none, hand off to `init`.
3. Pick the transport (ADR 0001): Herdr if `HERDR_ENV=1`, else tmux if inside a tmux server, else
   background terminal. Record it in `team.transport`.
4. Compute the layout: peer-routed members split evenly across available panes/windows.
5. For each **peer-routed** member, spawn a session running:
   `claude --agent ah:<role> --model <model> --name <derived-name> [effort flag] [permission-mode flag]`
   in the repo root. `--name` is the derived name from §3.4 — this is what makes check-in verifiable.
6. **`manual`** uses the same layout engine but pauses before each spawn to show the intended placement
   and let the user override it, then spawns.
7. Subagent-routed members are not spawned — they are recorded (§5.1) and dispatched on demand via the
   Agent tool, as today.
8. **Check-in**: after spawning, the Orchestrator verifies every peer member is up — call `ListAgents`
   and match each derived name; retry until all are seen or the timeout elapses.
   **RESOLVED (confirmed 2026-08-21): poll every 2s, give up at 60s.** Fixed interval, not backoff.
   On full success, `writeTeam(dir, …)` with the verified names/refs. On partial success, report exactly
   which members did not come up and write the registry with only the verified ones, marking the Team
   partial (`"partial": true`) — do not silently pretend a missing member exists.

> **NEEDS-EVIDENCE #1 — effort flag.** This spec assumes members carry an `effort` and that the CLI can
> set it at launch. I could not verify a `--effort`/reasoning-effort flag exists on `claude`.
> Run `claude --help` and report the exact flag name and accepted values.
> - If it exists → use it, and constrain `roster.members[].effort` to its value set.
> - If it does not → drop `effort` from the schema entirely (do not store a field nothing can apply),
>   and note it in `show` output as unsupported.

> **NEEDS-EVIDENCE #2 — permission-mode flag / auto-mode values.** This spec assumes
> `--permission-mode <default|acceptEdits|plan|bypassPermissions>`. Verify the exact flag spelling and
> the exact accepted value strings from `claude --help`, and constrain `autoMode` to them. Do not ship
> a validator built on this spec's guess.

> **NEEDS-EVIDENCE #3 — spawn recipe per transport.** The tmux recipe is recorded in memory as
> load-buffer → paste-buffer -p → send-keys Enter; the Herdr path goes through the `herdr` skill.
> Before implementing step 5, confirm each transport's exact spawn command in this environment and
> record it in the implementation, not in prose here.

## 7. Initial Setup trigger

`/hierarchy on` (and any other enable action) gains one branch: after enabling, if
`resolveRoster(cwd)` returns `null` at all three levels, hand off into `/agent-roster init`'s flow —
route question first, then roster contents.

This is the **only** automatic trigger. Explicitly out of scope: any SessionStart-hook proactive prompt.
`sessionstart.mjs`'s existing `buildNudge` path stays as-is (a one-line nudge, not a flow).
`/agent-roster init` remains independently runnable at any time.

## 8. `/hierarchy` scope reduction

`commands/hierarchy.md` — keep: `status`, `on`, `off`, `flow`, `gate`, `usage`, `msgs`, `peers`, `sweep`.

Remove:
- `set <role> <model>` — superseded by `/agent-roster edit`. Replace with a one-line pointer.
- `route [peers|subagents|prefer-peers]` — superseded by roster route (team-wide) + per-member override.
  **Keep the per-session route override machinery** in `lib-hier.mjs` (`sessionRouteRecord`,
  `recordRoute`, `effectiveRoute`) and the route gate — only the `/hierarchy route` *command surface*
  goes away. Removing the session override is not in scope.
- `init`'s role/model-assignment wizard — that half moves to `/agent-roster init`. `/hierarchy init`
  keeps only the enable + handoff-flow + task-gopher-detection portion, then hands off per §7.

`status` gains a roster section: winning level, path, and each member (name, role, model, effort, route,
auto-mode), plus the active Team id if `team.json` exists. Implement in `statusReport(cwd)`
(lib-config.mjs L573).

**Back-compat.** Do not delete `resolved.roles` or `ROLE_DEFAULTS`. When `resolveRoster` returns `null`,
everything behaves exactly as today, driven by `roles`. When a roster resolves, the roster's per-member
model/route supersedes `roles` for that role. Existing installs with `roles`/`route` set and no roster
keep working untouched — this is the migration path, and there is no config-rewriting migration step.

## 9. File-by-file change list

| File | Change |
|---|---|
| `hooks/lib-config.mjs` | Add `pathSlug`, `rosterLevelPaths`, `resolveRoster`, `rosterMemberNames`. Add repo-user as a third, highest-precedence layer in `resolveConfig`. Expose `resolved.roster`/`rosterLevel`. Extend `statusReport` with roster + team sections. `peerName` unchanged. |
| `hooks/lib-roster.mjs` | **NEW.** Roster + team schema validation, `readTeam`/`writeTeam`/`clearTeam`/`teamMemberByName`/`teamMembersForRole`, atomic write. |
| `hooks/roster.mjs` | **NEW.** CLI: `show|init|add|edit|remove|create|disband`, `--cwd`, JSON out / `--plain`. Modelled on `msg.mjs`. |
| `skills/agent-roster/SKILL.md` | **NEW.** Prose surface + interactive prompts; drives `roster.mjs`. First `skills/` dir in this plugin. |
| `hooks/lib-hier.mjs` | `roleForPeerName`: consult `teamMemberByName` first. `buildStateBlock`: render the Team table when a team exists. No other change. |
| `hooks/sessionstart.mjs` | Add the stale-team sweep (§5.3) for plain top-level sessions only, before the state block. |
| `hooks/pretooluse-route-gate.mjs` | `SendMessage` branch (L144–158): team-first role resolution, existing two lookups kept as fallback. |
| `commands/hierarchy.md` | Remove `set` and `route` surfaces; split `init`; add §7 handoff; document the roster/team sections in `status`. |
| `hooks/posttooluse-roster.mjs` | **No change** — it improves via `roleForPeerName`. |
| `hooks/lib-peer.mjs` | **No change** (§2). |
| `.claude-plugin/plugin.json` + root `marketplace.json` | Version bump in **both** — this repo requires it. |

## 10. What must NOT change

- `peers.jsonl` semantics, format, and lifetime. It stays the longer-lived cross-session liveness log.
- The `ListAgents` name-matching dispatch path — kept as the ad-hoc-peer fallback (ADR 0002).
- `lib-peer.mjs` and the peer report-back obligation machinery.
- The per-session route override (`recordRoute`/`effectiveRoute`) and the route gate's ask-once behaviour.
- The tier rule in `pretooluse-route-gate.mjs`.
- Behaviour of any existing install that has no `roster` key at any level.

## 11. Verification

New bash tests in `agent-hierarchy/tests/`, following the existing standalone-script convention and the
recorded HOME-redirect + cwd-injection technique:

- `test-roster-levels.sh` — write rosters at all three levels; assert repo-user wins whole, that a member
  present only in `global` does **not** appear when `repo-user` defines a roster (whole-level replace),
  and that `pathSlug` produces `-Users-…`-style output for a known absolute path.
- `test-roster-names.sh` — one architect ⇒ `<repo>-architect`; three ⇒ bare, `-2`, `-3`; removing the
  first re-ordinals the rest.
- `test-roster-cli.sh` — `init` replaces a level wholesale; `add`/`edit`/`remove` round-trip; `remove`
  resolves its target by `--member <name>`; a bare `add` picks the resolving level and says so; adding an
  `orchestrator` member is rejected; invalid `--level` is rejected.
- `test-team-registry.sh` — `writeTeam`/`readTeam` round-trip; `teamMemberByName` resolves a role that
  `roleForPeerName`'s config path would miss (the ADR 0002 case); `clearTeam` is idempotent.
- `test-team-stale.sh` — team with a dead orchestrator pid is swept on SessionStart; team older than 24h
  is swept; live team is NOT swept; sweep does not fire in a `--agent` session.
- `test-hierarchy-scope.sh` — `/hierarchy status` shows the roster/team sections; back-compat: with
  `roles` set and no roster, resolution is byte-identical to before.

Regression bar: all 13 existing `tests/test-*.sh` must still pass unchanged.

## 12. Open items, collected

Still open — route to the Implementor at build time, do not guess:

- **NEEDS-EVIDENCE #1** — does `claude` have an effort/reasoning flag? Determines whether `effort` stays
  in the schema at all.
- **NEEDS-EVIDENCE #2** — exact permission-mode flag spelling and value set; constrains `autoMode`.
- **NEEDS-EVIDENCE #3** — exact spawn command per transport (Herdr / tmux / background terminal).

Resolved (user-confirmed 2026-08-21, folded into the body above — no longer open questions):

- `remove` takes `--member <name>`, not an auto-mode (§4.2).
- A bare `add`/`edit` defaults to the currently-resolving level and prints which it chose (§4.2).
- Check-in polls every 2s with a 60s timeout (§6.8).

## 13. Confidence and escalation

Medium-high on the roster schema, levels, naming, and the `/hierarchy` scope split — these are local and
reversible. Lower on §6 `create`: multi-transport spawning plus a verification handshake is the part with
real failure modes (partial check-in, a member that comes up under an unexpected name, a transport that
silently no-ops). If the Implementor hits ambiguity there, that is a genuine escalation candidate for the
Ultra-Advisor rather than an improvised choice — specifically the question: *what should the Orchestrator
do when check-in partially fails — proceed with a partial Team, block, or tear down and retry?* This spec
picks "proceed and mark partial" as the default; it is the least destructive, not necessarily the right one.
