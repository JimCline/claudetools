# Spec 0052 — One-call team lifecycle + peer-side lookup

Status: **r3 FINAL** (Architect)

r3 changes (Implementor gaps G1-G5):
- **B1 rewritten.** Close attempts are unchanged from 0.79.0; liveness only decides which rows are kept (G1).
  "Snapshot" means the team record at close start (G2). The `kept.why` enum is `added`/`close-failed`/`live`/
  `indeterminate` (G3). Name-null rows are pruned and never passed to `memberLiveness` (G4).
- B2 drops `dead`/`indeterminate` from the plan.
- §5 drops the unreachable cases, and B6 names the permitted edit set.
- C1 records the whoami resolution rulings (G5 i-v).

---
r2 status line (superseded): · base main @ 7177536 (v0.79.0) · target **0.80.0**
(bump `agent-hierarchy/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json` together).

r2 changes:
- User rulings: U1 → prune inside `--close`; U2 → the plan stays read-only.
- NE1 confirmed. `send_to` is best-effort, and the brief's reply-to is authoritative (C2/C3).
- NE2: `session_id` is documented as "usually null".
- NE3: whoami has no valueless flag, so it needs no `ROSTER_BOOL_FLAGS` entry. No allowlist exists, and the
  roster skill gate is a deny-list. C4 is reduced to docs.
- NE4: agent `.md` files and directive strings stay untouched (C4, A3).

## 1. Goal

User, verbatim:
> "If the user names the team, that's what gets used as the alias. The team json (as opposed to the roster)
> should be updated and pruned by querying what's actually live when tearing down a team. All of these should be
> built in commands in the CLI so the orcehstrating agent doesn't have to reason about how to form the command but
> just calls tools that does the work in one call. Peer agents should have CLI tools for responding or locating its
> orechestrator if needed (although that's part of the message contract)"

Three areas: **A** team name = member-name prefix; **B** teardown reconciles and prunes the team file;
**C** a peer-side lookup verb.

## 2. Established facts (read from source @ 7177536; cite, don't re-derive)

- F1. `teamPrefixInfo(cwd, team)` `hooks/lib-config.mjs:601-624`: a non-empty `team` short-circuits to
  `{prefix: team, alias: team, source: "team"}` (:602), ahead of any `teamAlias` config. `roster.mjs:368` sets the
  module prefix from `--team` once; `namedMembers` (`roster.mjs:501-503`) → `rosterMemberNames`
  (`lib-config.mjs:524-532`) names members `<team>-<role>[-N]`. Applies to `create`, `spawn-one`
  (via `spawnOneCore`), and `spawn-ad-hoc` (`roster.mjs:3324-3331`).
- F2. Two named teams in one repo already get independent prefixes (`teamA-…`, `teamB-…`). `alias --set` refuses when
  `--team` is active (`roster.mjs:2561-2563`); it is a per-repo default only for the unnamed/default team.
- F3. `--team` is validated by `validateTeamAlias` (`lib-config.mjs:546-562`; `^[A-Za-z0-9][A-Za-z0-9-]{0,31}$` +
  role-token collision) at `roster.mjs:359-364`.
- F4. "PEER NAME CONFIRMATION" is emitted in one place, directive text `lib-config.mjs:933-999` (text :991). No CLI or
  hook enforces it. It fires only for a peer-eligible role with unsettled `peer:"auto"`. :950 already says to skip it
  if `spawn-one`/`spawn-ad-hoc` reported the name.
- F5. `disband --close` (`roster.mjs:2836-2865`) closes panes and **does not write or remove the team file**. Test
  "--close: team.json left in place (not removed)" in `tests/test-roster-disband-close.sh` pins that. Spec 0046 split
  bookkeeping out to `untrack --all --commit --keep-sessions`. `skills/agent-team/SKILL.md:475-477` still claims
  `--close` removes the file / rewrites it minus successful closes. **That doc is wrong today.**
- F6. `dismiss <name> --close` already prunes its one row on success (`roster.mjs:3029-3031`).
  `untrack` prunes (`untrackMember` :595-665) and clears the file (`clearTeam` :3112).
- F7. Confirmation for closes has two layers: the plan→`close_token` contract (`closeToken` :1683-1686,
  `gateClose` :2017-2030) and `hooks/pretooluse-disband-close-gate.mjs`, which always asks.
- F8. `memberLiveness(dir, member)` (`roster.mjs:1762-1768`) returns `{live, indeterminate, why, …}`. By spec 0043
  §1.6, `indeterminate` must never be treated as dead. `resyncMembers` (:1043-1222) heals pane ids and never throws.
- F9. `readTeam` (`lib-roster.mjs:272-281`) returns `null` for both a missing file and an unparseable one, so the two
  cannot be told apart.
- F10. Team record carries `orchestrator: {session_id, pid}` (`roster.mjs:2270`, `:2775`). A peer learns its reply
  address only from each brief's `[hierarchy-peer-brief reply-to="…"]` / the `<cross-session-message from="uds:…">`
  wrapper. No uds path is persisted anywhere. No `cc-socks` reference exists in the repo.
- F11. Peer self-identity: SessionStart knows only the role (`sessionstart.mjs:90`, :118-128). Pane→member matching
  is `attributeSessionTeam` / `resolveTeamByPane` (`lib-roster.mjs:411`, :442), already used by `checkin`
  (`roster.mjs:3423-3483`). `checkin` outputs only `{checked_in, cwd, expected_root, misplaced}` and re-registers
  (side effect).
- F12. Read-only verbs exempt from the roster skill gate: `hooks/pretooluse-roster-skill-gate.mjs:14`
  (show, teams, history, reap, resync, layout-splits).

## 3. Requirements

### Area A — team name is the prefix (docs-only delta)

- **A1 (no code).** F1/F2 already deliver the behaviour: a user-named team passed as `--team <name>` names its members
  `<name>-<role>[-N]` with no alias read or write. Do NOT change `teamPrefixInfo`, `defaultTeamScope`, or the
  unnamable-basename path (spec 0044 tests 6a-6e; 0051 R7 withdrawal stands).
- **A2 (SKILL.md).** In `skills/agent-team/SKILL.md`, at the create / spawn-one / spawn-ad-hoc guidance, state these
  points:
  - "When the user names the team, pass that name as `--team <name>`; it is the member-name prefix."
  - "Do not run `alias --set` and do not ask a PEER NAME CONFIRMATION for it."
  - "If the name fails validation, the CLI's error names a legal suggestion; offer that to the user."
  `alias --set` stays documented as the repo default for the *unnamed* team only.
- **A3 (optional, byte-neutral).** The skip clause at `lib-config.mjs:950` may also cover "or the user named the team".
  This applies ONLY if `tests/test-directive-size.sh` byte counts do not increase (the auto/confirm ceilings are never
  raised; headroom is ~25/21 B). If no offsetting trim exists in the same string, drop A3. SKILL.md (A2) is sufficient.

### Area B — teardown reconciles the team file (reverses the 0046 split, per user request)

- **B1 (r3, replaces r1/r2 B1). `disband --close` prunes; close behaviour is unchanged.**
  - Keep the existing `--close --confirm --plan-token <tok> [--allow-global]` flags, gates (F7), and **every close
    attempt exactly as today**. Every closable member still gets a close attempt whatever its liveness; a dead claude
    whose pane survives must still have the pane closed. Liveness decides only which rows are kept.
  - "Snapshot" means the team record read at `--close` start, the one the token validated against. Nothing is
    persisted between plan and close (U2). A member with a pane added after the plan changes the closable set, so the
    token fails with exit 2, as today.
  - After the closes run:
    1. Re-read the team file. Never write back the snapshot.
    2. For each row of the re-read `members`, in this order (first match wins):
       - name non-null and not in the snapshot's names → **keep**, `why:"added"`.
       - its close was attempted and failed → **keep**, `why:"close-failed"`.
       - its close was attempted and succeeded → **prune**.
       - no close attempt (not closable), name non-null, `memberLiveness` live → **keep**, `why:"live"`.
       - no close attempt, name non-null, `memberLiveness` indeterminate → **keep**, `why:"indeterminate"`.
       - otherwise → **prune**. This covers not-closable dead members and name-null subagent-route rows, which hold no
         session. `memberLiveness` is never called with a null name.
    3. If nothing is kept, remove the file with the existing `clearTeam`. Otherwise write it with the existing
       `writeTeam`, with only `members` changed.
  - Peer-fallback source (no team file; `source:"peers"`): nothing to prune, no file created.
- **B2 (r3). The plan adds only `next`.** Bare `disband` / `disband --plan` stays read-only and otherwise unchanged.
  `dead`/`indeterminate` plan fields are **dropped**, because liveness is evaluated at close time only (G1/G2).
  - `next: "<exact command string>"` — the full `--close` command to run after the user says yes. It uses an absolute
    `node <root>/hooks/roster.mjs` path and carries `--confirm --plan-token <tok>`, plus `--team <T>` and `--cwd <abs>`
    when they were given, and `--allow-global` only when `gateClose` would demand it. The agent copies it and
    assembles nothing.
  - `close_token` semantics are unchanged.
- **B3. Close output.** Existing `{closed, results, sources}` plus:
  - `pruned: [name…]` (r3: a name-null row appears as its `role`, e.g. `"reviewer"`, never `null`);
  - `kept: [{name, why}]` (r3: why ∈ `added` | `close-failed` | `live` | `indeterminate`);
  - `team_removed: bool`;
  - `team_file: <abs path>|null`.
  Exit codes are unchanged: 0 on success, including partial close failure; 2 via `fail()` on usage, token, or confirm
  errors.
- **B4. Unreadable team file.** In `disband` (plan and close) only, add a check:
  - Condition: the resolved team file path exists but `readTeam` returned `null`.
  - Output: `team_file_unreadable: <abs path>` in the output, with the existing peer-fallback behaviour otherwise.
  - The file is never written or removed in that state.
  - Do not change `readTeam`'s signature or its other callers.
  - (Scope note: the Orchestrator's premise of a "0051 corrupt-file gap" was not found in spec 0051. This requirement
    is the minimal guard for the new delete path, not a general fix.)
- **B5. `dismiss`.** Add `next` to its plan output (same rule as B2). Pruning behaviour is already correct (F6).
- **B6. Must not change:**
  - the PreToolUse close gate (always asks);
  - the plan→token→close two-call contract and the conversational user confirm (SKILL.md:462-469, :479-482 — never
    fold into one call);
  - `untrack` semantics (still the close-nothing bookkeeping path);
  - `--commit`/`--keep-sessions` rejection on `disband`;
  - spec-0011 multi-team resolution;
  - every 0051 requirement.
  **"One call" here means the agent runs no bookkeeping command after `--close`. It does NOT mean the user's
  confirmation is removed.**

### Area C — peer-side lookup

- **C1. New read-only verb `roster.mjs whoami [--team <T>] --cwd <abs>`.**
  - It has no side effects: no re-registration, no `peers.jsonl` write, no team write.
  - **r3 (G5) rulings:**
    - (iv) **Pane id:** same precedence chain as `checkin`: `HERDR_PANE_ID`, then the `peers.jsonl` `pane_id` via
      `CLAUDE_PID`, then `TMUX_PANE`. Reading `peers.jsonl` is allowed; writing is not. If checkin's chain is inline,
      reuse it by extraction rather than copying it.
    - (i) **Matching:** whoami does its own scan over `[null, …listTeamNames]` with `readTeam`, collecting every
      member whose `transport_id` equals the pane id. That is needed because `resolveTeamByPane` returns `null` for
      both not-found and ambiguous. With `--team T`, it scans only T. It must not change `resolveTeamByPane`.
    - (iii) **Pane-only identity.** Do NOT use `attributeSessionTeam`'s role-scan fallback, because a role match is
      not identity.
    - (ii) **`reason`**, first match wins:
      - `no-pane-id`: the chain yields nothing;
      - `no-team`: `--team T` names a missing or unreadable record, or no team record exists at all;
      - `not-a-member`: records exist but none holds the pane;
      - `ambiguous`: more than one match, with `candidates` listed;
      - `null`: exactly one match.
    - (v) **Legacy `team.json`:** `team: null`, with `team_file` set.
- **C2. Output** (stdout JSON, exit 0 whenever the lookup ran, even if it found nothing):
  ```
  { "member": {name, role, route}|null,
    "team": <team name>|null, "team_file": <abs>|null,
    "orchestrator": { "pid": n|null, "session_id": s|null, "live": bool|null, "send_to": "uds:…"|null } | null,
    "reason": null | "no-pane-id" | "no-team" | "not-a-member" | "ambiguous",
    "candidates": [ {team, name} ]   // only when ambiguous
  }
  ```
  - `live` comes from the existing `pidAlive` on `orchestrator.pid`.
  - **r2 (NE1 confirmed):** `send_to` is the string `uds:/tmp/cc-socks/<pid>.sock`, emitted only when `pid` is
    non-null, `pidAlive(pid)` is true, AND that socket file exists at call time. Otherwise it is `null`. The value is
    usable directly as SendMessage `to`.
    - It is best-effort: the directory is owned by the Claude Code harness and not guaranteed stable.
    - Hardcode it in exactly one place, with a comment naming it as a harness-owned path. Add no config knob.
    - Testing:
      - If the suite already has a mechanism for redirecting harness paths to fixtures, use it for the socket-present
        case.
      - If none exists, test only the `send_to:null` cases and report the gap. Do not add a knob for it.
      - Never create files in the real `/tmp/cc-socks`.
  - `session_id` (NE2): passed through as recorded. It is null on every path SKILL.md uses; say so in cli-tools.md.
  - Orchestrator session **name**: not emitted. No record holds it (`from-name` is never persisted). Adding it would
    need a new spawn-time field; that is out of scope, add it if `send_to:null` proves common.
  - Exit 2 only for a usage error (unknown flag).
- **C3. Reply precedence.** Document this in SKILL.md and cli-tools.md; the directive is not changed:
  - The brief's `reply-to` (or the orchestrator's session name from `ListAgents`) is authoritative.
  - `whoami.send_to` is a derived fallback.
  - `whoami` is the fallback when that is lost (compaction, a peer with no pending brief) and for "who/where am I".
  - Do not restate the message contract; link to it.
  - No second "reply" verb: the CLI cannot call SendMessage, and a verb that only prints `send_to` would duplicate C2.
- **C4. Discoverability without directive bytes.**
  - Add `whoami` to `docs/cli-tools.md` (verb table + one-line row) and to SKILL.md.
  - **r2 (NE3):**
    - No gate or allowlist change: `pretooluse-ah-cli.mjs:38-41` allows every non-close verb.
    - The roster skill gate's `VERBS` (`pretooluse-roster-skill-gate.mjs:38`) is a deny-list, and whoami must NOT join
      it.
    - whoami takes only valued flags (`--team`, `--cwd`), so it needs no `ROSTER_BOOL_FLAGS` (`lib-ah-cli.mjs:30`)
      entry. If the Implementor adds any valueless flag, it must join that list.
  - **r2 (NE4):** No directive or agent `.md` text. The headroom (implementor.md 11 B, auto 25 B) cannot carry a
    useful clause. Peers discover whoami via SKILL.md / cli-tools.md, and the verb list in the `ah CLI root` line
    already points there.

## 4. Files expected to change

- `hooks/roster.mjs`: disband plan/close (B1–B4), dismiss plan `next` (B5), `whoami` case + flag set (C1–C2), verb
  list/usage.
- (r2) No hook/gate file changes: see C4.
- `skills/agent-team/SKILL.md`:
  - A2;
  - fix :475-477 to the B1 truth;
  - drop the now-redundant "then `untrack --all --commit --keep-sessions` after `--close`" advice wherever it appears
    (keep untrack as the close-nothing path);
  - C3.
- `docs/cli-tools.md`: `whoami` row; disband/dismiss output fields.
- `lib-config.mjs`: only for A3, and only if it proves byte-neutral (C4 adds no directive text).
- Tests:
  - `tests/test-roster-disband-close.sh`: **flip** "--close: team.json left in place (not removed)" to assert removal;
    add cases for B1–B4.
  - `tests/test-roster-dismiss.sh`: `next`.
  - A new `tests/test-roster-whoami.sh`.
- Versions: plugin.json + marketplace.json → 0.80.0.

## 5. Test plan (HOME-redirected fixtures, fake herdr; never the real ~/.claude or live team 20260918-201850-gdxf)

| Req | Case |
|---|---|
| A1 | Existing coverage in `test-roster-team-scope.sh` and `test-team-alias.sh` passes unmodified. Add one case: two `--team` names in one repo, `spawn-ad-hoc` each → names `a-<role>`, `b-<role>`; no `teamAlias` key written to any level file. |
| A3/C4 | `test-directive-size.sh` passes with ceilings unchanged; byte counts ≤ 14575 / 16479. |
| B1 (r3) | Existing `test-roster-disband-close.sh` fixture: every close assertion (:104-107, :116-118) is unchanged. All closes succeed → file removed, `team_removed:true`; the subagent row is pruned. One close fails (existing forced-fail case) → file holds exactly that row plus nothing else closable, `why:"close-failed"`. Not-closable member with a live `peers.jsonl` row (transport_id null) → kept, `why:"live"`. The `added` path is NOT tested: it is reachable only via a herdr stub that mutates the team file mid-close. Dropped per "don't contort". |
| B2 | Plan output contains `next`; running `next` verbatim (harness ask auto-approved in the test) succeeds. The `close_token` for a fixture equals its 0.79.0 value. |
| B3 | Output field shape and exit 0 on partial failure. |
| B4 | Garbage-bytes team file → plan and close both report `team_file_unreadable`; file bytes unchanged afterward. |
| B5 | dismiss plan `next` runs verbatim. |
| B6 | Full existing suites for disband, dismiss, untrack, disband-close-gate and multi-team pass. r3: the only permitted edits are assertions about the team file's existence or contents *after* `disband --close` (the F5 flip set). Any other assertion needing an edit → stop and report. |
| C1/C2 | Fixture with the member's `transport_id` = fake `HERDR_PANE_ID` → member/team/orchestrator filled. No pane env → `no-pane-id`. Pane not in any team → `not-a-member`. Pane in two team records → `ambiguous` + candidates. Dead orchestrator pid → `live:false`, `send_to:null`. `peers.jsonl` and the team file are byte-identical before and after. |
| C2 (r2) | Live pid with no socket file → `send_to:null`. Socket-present case only via fixture redirect (see C2); never touch the real `/tmp/cc-socks`. |
| C4 | whoami is not blocked by the roster skill gate or `pretooluse-ah-cli` (add one row to the existing gate test matrix). `whoami --team X --cwd Y` parses with no token eaten. |

## 6. NEEDS-EVIDENCE: all resolved in r2

The resolutions are folded into C2, C4 and A3:
- NE1 confirmed: `/tmp/cc-socks/<claude pid>.sock`. The directory is harness-owned.
- NE2: `session_id` is null in practice.
- NE3: there is no allowlist.
- NE4: headroom as measured. A3 remains an Implementor measurement at net ≤ 0 bytes.

Original items, kept for history:

- **NE1: orchestrator reply address.** On any live peer brief already received, compare the `from="uds:…"` value
  with that team record's `orchestrator.pid`. Is it exactly `uds:/tmp/cc-socks/<pid>.sock`, and is the socket file
  present at that path?
  - Yes → C2 derives `send_to` as that string when the file exists.
  - No, or the directory is configurable or varies → `send_to` is dropped from C2 (always `null`, field removed).
    whoami then returns pid/liveness only, and SKILL.md says to reply via the brief's `reply-to` or `ListAgents`.
  - Read-only observation only. Do not message or start sessions to test it.
- **NE2: session_id.** Is `orchestrator.session_id` ever non-null on `spawn-one` / `spawn-ad-hoc`-created teams?
  (`:2270` writes `null`.) The answer decides whether C2 documents it as "usually null". There is no design change
  either way.
- **NE3: read-only allowlist.** Does `hooks/pretooluse-ah-cli.mjs` / `lib-ah-cli.mjs` hold a read-only verb
  allowlist separate from `pretooluse-roster-skill-gate.mjs:14`? If yes, whoami joins it; if no, C4's gate entry is
  enough.
- **NE4: A3/C4 byte-neutrality.** Can the named strings absorb the clause at net ≤ 0 bytes? If not, skip. This is
  an Implementor measurement; it is not a design question.

## 7. Decisions and forks

- **Made:**
  - A is docs-only because the code already does it.
  - B reuses `clearTeam`/`writeTeam`/`memberLiveness`, with no new verb and no new flag.
  - C is one read-only verb, not two.
  - B4 is scoped to disband only.
- **U1 RULED (user): prune inside `--close`; no `--prune` flag.**
- **U2 RULED (user): the plan stays read-only.**
- Original fork text:
- **FORK U1 (user):** B1 reverses spec 0046's deliberate separation of "close sessions" from "drop the team record".
  The recommendation is to reverse it, because the user asked for pruning at teardown and SKILL.md already documents
  the pruned behaviour. The alternative keeps `--close` pure and adds `--prune`, which the agent must remember: that
  is a new flag, and it contradicts "one call".
- **FORK U2 (user, minor):** should `dead` members that were never closed also be pruned by `disband` *plan*
  (read-only today)? The recommendation is no: the plan stays read-only and all pruning happens under the confirmed
  `--close`.
- **Residual risk:**
  - B1 has a read→write race with a concurrent `spawn-one` into the same team between re-read and write. The window
    is the same as the existing `dismiss` prune (F6); it is accepted, not solved.
  - Flipping the F5 test is the one intentional assertion change.
