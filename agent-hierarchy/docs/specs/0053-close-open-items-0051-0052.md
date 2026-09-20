# 0053 — Close the open items left by 0051 (0.79.0) and 0052 (0.80.0)

Status: **r5 FINAL**. Base: main @ 9ad13d1, v0.80.0, tree clean. Target: 0.81.0.

r5 rules the Reviewer's members-less-record hazard (R1.6). It takes option (a),
and puts the predicate one level deeper than the Reviewer proposed — in
`readTeam` rather than only in the usable check — because that is the choke
point all the sibling crash paths route through too. This amends an r3 "must
not change" clause; see R1.6.

r4 generalises R1.4 into R1.5 after the Implementor found the hole it left: an
explicit `--team T` pointing at a corrupt `teams/T.json` was still silently
overwritten. R1.4 becomes one instance of a single rule, R8.4 loses a condition
it should never have had, and one doc line records an R1.2 side effect on read
verbs. Nothing else moves.

r3 answers eight gaps found by the Implementor on code read. One was a factual
error in r2 (R1's claim that no caller needed to act was wrong — see F21 and
R1.4), one test case is downgraded because it was untestable without a contract
change (R3.4), and R7 is closed as WONT-FIX on inspection. R4 and R8 gain the
exact key names and predicates their tests need to pin.

r2 folds in the user's rulings on both forks and the evidence for NE1-NE4. Two
things changed shape rather than just being confirmed: R3 no longer adds a
test-only knob (the harness already exports the session's own socket path, so
the directory is derivable), and R4 now pins the record lookup and the output
contract against the real store. NE4 is withdrawn as moot.

## 1. Goal

The user said, verbatim: **"Fix the remaining issues"**.

Ten items were left open by 0.79.0 and 0.80.0. Each gets either the smallest
requirement that holds or an explicit WONT-FIX with the reason. Items whose fix
costs more than the problem are ruled out in one line, not padded into work.

Requirement numbering follows the item numbering in the dispatch: R1 closes item
1, R2 item 2, and so on.

## 2. Established facts

Every fact below was read from the tree at 9ad13d1. Nothing here was executed.

- **F1** `readTeam` (lib-roster.mjs:272-281) returns `null` for a missing file,
  for an unparseable file, and for a parsed non-object/array alike. It does not
  distinguish them, and no function in lib-roster.mjs does.
- **F2** `teamPath` (lib-roster.mjs:91) → `dir/team.json` when `team` is null,
  `dir/teams/<team>.json` otherwise.
- **F3** `defaultTeamScope` (lib-roster.mjs:383-397) picks scope with
  `if (readTeam(dir, null)) return { team: null, ... }`. A corrupt legacy
  `team.json` therefore reads as absent and the scope resolves on to
  `teams/<prefix>.json`.
- **F4** `unreadableTeamFile` (roster.mjs:2061-2064) is
  `existsSync(teamPath(dir, teamFile)) ? path : null` — it reports the
  **active** scope only, and is called at roster.mjs:2913 and :2949.
- **F5** `untrack` with no readable team record (roster.mjs:3176-3179) exits 0
  with `{ untracked: false, already_untracked: true, reason: "no team file to
  forget" }`.
- **F6** `dismiss` with no readable team record and no peer-registry target
  (roster.mjs:3022-3032): if there are no closable peers it exits 0 with
  `{ dismissed: false, reason: "no active team and no live peers", sources }`;
  otherwise it `fail()`s (exit 2) listing the live untracked sessions and the
  name / pane_id / session_id values `dismiss` accepts.
- **F7** The disband plan emits `next: closeCommand("disband", null, planToken)`
  unconditionally (roster.mjs:2987). No condition on whether any member has a
  pane.
- **F8** The socket path is constructed in exactly one place, roster.mjs:3600:
  `const socket = pid == null ? null : \`/tmp/cc-socks/${pid}.sock\`;`, consumed
  at :3605 as `send_to: live && existsSync(socket) ? \`uds:${socket}\` : null`.
  The only other `cc-socks` occurrences in the repo are literal strings inside
  cross-session message fixtures in tests/test-msg-response.sh and
  tests/test-peer-reportback.sh; nothing redirects the directory.
- **F9** A team record is created in `spawnOneCore` (roster.mjs:2331-2342) with
  `orchestrator: { session_id: null, pid: newTeamOrchestratorPid }`, and the pid
  is later rewritten by `adopt` (roster.mjs:3437). No field holds a name.
- **F10** **No mechanism exists for a session to learn its own human-readable
  name.** Every `HERDR_*` read supplies a pane/tab/workspace id, not a name;
  `from-name` is parsed only off an *incoming* cross-session message
  (lib-peer.mjs:72-74) and recorded into the peer obligation/response records
  (lib-peer.mjs:127, :142). `msg.mjs --from-name` (msg.mjs:176) is
  caller-supplied.
- **F11** The route-gate exemption (pretooluse-route-gate.mjs, the
  `toTeamMember` block) collects holders as
  `[null, ...listTeamNames(dir)].map((t) => readTeam(dir, t)).filter((t) => t &&
  Array.isArray(t.members) && t.members.some((m) => m && m.name === to))` and
  sets `toTeamMember = holders.length > 0 && holders.every((t) =>
  EXEMPT_ROSTER_LEVELS.includes(t.roster_level))`, with
  `EXEMPT_ROSTER_LEVELS = [null, "repo", "repo-user"]`. An existing file that
  fails to parse is dropped by the `t &&` filter, so it is never counted as a
  holder.
- **F12** `spawn-ad-hoc` (roster.mjs:3389-3415) derives the name from the
  same-role members of the team record it just read, then checks
  `teamMemberNameSet(dir, teamFile)` and fails on collision, then
  `requireHerdrName`, then `await spawnOneCore(...)`. The check and the launch
  are separate reads of the same record with an open window between them.
- **F13** `/Users/jimcline/git/repos/claudetools/.claude/agent-hierarchy.json`
  sets `roles.architect.peer = "ct-arch1"` and
  `roles.implementor.peer = "ct-implementor"`, while its `roster.members`
  entries carry no `peer` key. `resolvedPeerTargets` (lib-config.mjs:319-325)
  returns the explicit `entry.peer` when present and otherwise
  `peerName(repoBasename, role)` = `` `${repoBasename}-${role}` ``
  (lib-config.mjs:288-290). So the SessionStart directive advertises
  `ct-arch1` / `ct-implementor` while a spawn derives `claudetools-architect` /
  `claudetools-implementor`.
- **F21** `resolveWritableTeamScope` (roster.mjs:1403-1429) picks the write
  target with its **own** `readTeam(dir, null)` at :1405, independent of
  `defaultTeamScope`. A corrupt legacy `team.json` therefore reads as absent
  there too and the scope falls through to :1428,
  `teamFile = teamPrefix(cwd, null)`. Callers: roster.mjs:1375, :2183, :2770,
  :3403.
- **F22** `spawnOneCore` legitimately replaces an existing same-role dead row on
  the respawn path (`matches` / `existing`, roster.mjs:2236-2237, :2344-2346).
  The match may be by **role** rather than by name when `byName` is false.
- **F23** `whoami` finds the peers.jsonl row by **pid** —
  `latestRoster(dir).find((r) => r.pid === myPid)` (roster.mjs:3572) — and
  derives the pane id from that row, not the reverse. Its early-exit path is
  `empty()` at roster.mjs:3573.
- **F24** `send_to` is non-null only when `existsSync(socket)`
  (roster.mjs:3605); `whoami` never emits the constructed path itself.
- **F25** Inspection at r3 found no ragged comment wrap at roster.mjs:3372-3407.
- **F15** The harness exports a session's **own** messaging socket as
  `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<pid>.sock`, alongside `CLAUDE_PID`
  and `CLAUDE_CODE_SESSION_ID`. It is the session's own address, never another
  session's. A session's human-readable name is never in the environment — it
  appears only in its argv (`--name`, roster.mjs:763) and in its team row.
- **F16** The peer obligation store is
  `~/.claude/agent-hierarchy.peer-pending.jsonl` (lib-peer.mjs:35-36) — **global
  under the home directory, not under `hierarchyDir(cwd)`**. Append-only JSONL,
  readable cold via `readPeerRecords()` (lib-peer.mjs:155), which needs only
  `HOME`. An obligation row (userpromptsubmit-peer-tracking.mjs:~63) carries
  `{session_id, from, from_name, reply_to, task, armed_by, msg?, ts, status,
  nudges}`; `from_name` is persisted (`""` when absent) and survives the
  resolved / waived / nudge re-appends, because rows are spread. The same file
  also holds `type: "turn"` and `type: "dispatch"` rows (lib-peer.mjs:189, :208,
  :233).
- **F17** Rows key on `session_id` (`keyOf` lib-peer.mjs:177-179, `pendingFor`
  :202), and a cold CLI invocation has no hook payload to take it from. Only
  briefs matching the sentinel or the `[hierarchy-msg …--request.md]` form create
  a row (`extractPendingRecord` lib-peer.mjs:109-152) — a plain cross-session
  message creates none.
- **F18** `spawnOneCore` reuses one earlier read: a single `readTeam` at
  roster.mjs:2217 feeds the already-live logic (2238-2280), the dry-run return
  (2300), `let outTeam = team` (2330) and `writeTeam` (2347). The pane launch
  happens inside that window with no re-read.
- **F19** Existing environment-override precedent: `AGENT_HIERARCHY_DIR`
  (lib-config.mjs:441, state-dir override) and `AH_HERDR_TIMEOUT_MS`
  (roster.mjs:882, effectively test-only).
- **F20** The only malformed team-file fixture in the suite is
  tests/test-roster-disband-close.sh:223-225 — a **named-scope**
  `teams/myrepo.json` asserting `team_file_unreadable`. No test relies on a
  corrupt **legacy** `team.json` falling through to a named scope.
- **F14** `teamAlias` is read at repo / repo-user level only (lib-config.mjs:617,
  :676-677, :766-774) and feeds `repoBasename`, which feeds `peerName`.

## 3. Requirements

### R1 — a corrupt legacy `team.json` must claim the default scope, not be skipped

**Problem.** Per F1 and F3, an unparseable `team.json` is indistinguishable from
an absent one, so `defaultTeamScope` resolves past it to `teams/<prefix>.json`.
The corrupt file is then never the active scope, so the `team_file_unreadable`
reporting added by 0052 B4 (F4) can never fire for it, and a repo silently
acquires a second team record beside a broken one.

**Requirement.**

1. lib-roster.mjs gains one exported helper that answers the question F1 says
   nothing currently answers: for a given `(dir, team)`, whether the team file is
   **absent**, **present but unusable**, or **present and usable**. It must be
   built on the existing `teamPath` and `readTeam` and must not change
   `readTeam`'s signature or return values. Its three outcomes must be
   distinguishable by the caller without a second filesystem call.
2. `defaultTeamScope` must treat a present-but-unusable legacy `team.json` the
   same way it already treats a usable one: the scope stays `{ team: null }`. It
   must additionally carry the offending **absolute path** under the key
   **`unreadable`**, in the same style as the existing `unnamable` / `suggested`
   extras. The existing `unnamable` behaviour, the `suggested` value, and the
   shape of the returned object for the two cases that work today must not
   change.

   **G2 ruling:** `unreadable` and the `unnamable` / `suggested` pair are
   independent and **both appear when both apply** — one describes the repo
   basename, the other describes the legacy file, and neither suppresses the
   other.

3. *(r2 text was wrong — corrected at r3.)* Read-only callers need no change:
   once the scope is `null`, the existing `unreadableTeamFile` path (F4) reports
   the file for `disband --close`. **Writing verbs do need a change — see R1.4.**

4. **G1 ruling — writing verbs fail closed.** Per F21, `resolveWritableTeamScope`
   makes its own `readTeam(dir, null)` call and falls through to
   `teams/<prefix>.json` on a corrupt legacy file, so R1.2 alone does **not**
   stop `spawn-one` / `spawn-ad-hoc` / `create` writing a second team record
   beside an unreadable one. Requirement:

   - When `resolveWritableTeamScope` is **defaulting** the scope — that is, no
     explicit `--team` was supplied — and the legacy `team.json` exists but is
     unusable, the command fails (exit 2) and writes nothing.
   - The failure message must name the absolute path of the unreadable file and
     state both remedies: repair or remove that file, or pass an explicit
     `--team <name>`.
   - When an explicit `--team` **was** supplied, the corrupt legacy file is
     irrelevant to that write and nothing changes. This is the escape hatch, and
     it is why the refusal is safe.

   **Checked against 0051's zero-friction promise, as asked.** Zero-friction
   governs the ordinary case: one ungated command, no ceremony. A corrupt legacy
   `team.json` is not the ordinary case, and the friction it costs is one flag,
   named in the error text itself. The alternative — silently starting a second
   team beside a record nobody can read — defers a much worse problem to
   teardown, when two records disagree about who is live. Refusing to write
   beside a record you cannot read is the same call R6 makes for the route gate.

5. **r4 — the general rule: a writing verb never overwrites an unusable team
   file, whatever scope it resolved to.** R1.4 covered only the defaulted
   legacy case, which left a hole: with an explicit `--team T` naming a corrupt
   `teams/T.json`, `spawn-one` / `spawn-ad-hoc` / `create` replaced an
   unreadable record with a fresh team and lost whatever it held. Because
   `readTeam` cannot tell missing from corrupt (F1), this also covered a file
   that was already corrupt at the first read.

   - `resolveWritableTeamScope` checks the **resolved** write target — the scope
     it just settled on, defaulted or explicitly given — and refuses when that
     file is present but unusable: exit 2, nothing written, message naming the
     absolute path and the remedy (repair or remove the file, or name a
     different `--team`).
   - **R1.4 is now simply the defaulted instance of this rule** and needs no
     separate mechanism. Keep its wording only where the remedy differs: a
     defaulted scope can also be escaped by supplying `--team`, which a resolved
     explicit scope cannot.

   **Where the check goes: `resolveWritableTeamScope`, not `spawnOneCore` or
   `create`.** It is the single choke point every writing verb already routes
   through (F21 callers: roster.mjs:1375, :2183, :2770, :3403), it is where R1.4
   already lands, and it runs **before the pane launch** in every path — so a
   refusal can never strand a session, which is the property that matters most
   here. Putting it in the individual verbs would duplicate the rule four times
   and risk one of them checking after the launch.

   **`create`'s plan path refuses too, rather than reporting.** One rule at one
   choke point, uniform across dry-run and execution. A plan whose only content
   would be "I intend to overwrite a record I cannot read" is not worth a
   special branch to produce, and failing there tells the operator the same
   thing sooner.

6. **r5 — a record with no `members` array is not a usable team record.**
   The Reviewer found that `{"version":1}` classifies as usable, so R1.5 and
   R8.4 both pass it and `outTeam.members.findIndex(...)` then throws **after**
   the pane launched: uncaught stack, orphan session, no `transport_id` in the
   message. The same hazard existed in 0.80.0. "Parses to a record" and "is a
   team record" are not the same predicate, and the codebase has been relying on
   them being the same.

   **Ruling: option (a), and the predicate goes in `readTeam`, not only in the
   usable check.** `readTeam` returns `null` for an object whose `members` is
   absent or not an array, exactly as it already does for an array or a
   non-object (F1). `teamFileState` inherits this, so such a file classifies
   **unusable** with no separate rule.

   **Exact predicate.** A parsed value is a team record iff it is a non-null
   object, is not an array, **and** `Array.isArray(value.members)`. Anything
   else → `readTeam` returns `null`, `teamFileState` returns unusable.

   **Why `readTeam` rather than the usable check alone.** Folding it only into
   `usable` fixes R1.5, R6 and disband's reporting, but leaves the sibling crash
   paths that reach `.members` straight off a `readTeam` result — dismiss
   (roster.mjs:3135), untrack (:604, :3214-3230) and adopt (:3467, which
   re-stamps `orchestrator.pid` and writes the record back without ever
   touching `members`). One predicate at the shared choke point fixes the
   reported hazard and those together; guarding call sites fixes one and leaves
   the rest, in a file with roughly 60 unguarded `.members` accesses.

   **Evidence that this rejects nothing legitimate.** No writer omits
   `members`: every `writeTeam` call site either sets it explicitly or spreads a
   record that already had it, and the three that merely propagate it
   (roster.mjs:604, :3135, :3467) can never *create* the absence. An emptied
   team is **deleted**, not written with `members` missing — `clearTeam` at
   roster.mjs:2112, :3220 and :3498. No test fixture omits the key. So a
   members-less record cannot arise from this codebase at all; it can only be
   hand-edited or truncated, which is precisely the case this rule is for.

   **Option (b) rejected.** Normalising `outTeam.members ??= []` at the write
   site silently repairs a record the same spec has just declared unwritable,
   and it would write a fresh empty team over a file whose real contents were
   truncated — the exact data loss R1.5 and R8.4 exist to prevent.

   **Consequences to expect, all improvements on a thrown stack.** Against a
   members-less file: writing verbs refuse before launch (R1.5); the route gate
   denies the exemption (R6); `disband --close` reports `team_file_unreadable`;
   `dismiss` and `untrack` take their existing no-team paths (F5, F6) instead of
   throwing; `adopt` reports no team rather than rewriting the file.

**Must not change.** `readTeam`'s collapse to `null` (F1) stays — callers that
only want "is there a usable record" keep working unchanged. **Amended at r5:**
R1.6 widens *what* collapses to `null` by one case (a members-less object), but
does not change *that* it collapses, and still does not distinguish missing from
corrupt. Missing-vs-corrupt remains the job of `teamFileState` alone.
`teamPrefixInfo` is not touched. Read-only verbs are unaffected by R1.4 and
R1.5 — neither refuses anything that does not write.

**One documented side effect of R1.2 (r4).** With a corrupt legacy `team.json`,
bare read verbs now resolve `teamFile = null` instead of the prefix. The suite
shows no regression, but it changes what a read verb reports in that state, so
**docs/cli-tools.md gets one line saying so** — a user staring at a `show` that
suddenly describes a different scope deserves to find the reason in the docs
rather than in this spec. One line, no behaviour change, no test.

### R2 — specify and test `dismiss` / `untrack` with no team file

**Problem.** Nothing covers either verb run immediately after
`disband --close` removed the team file. test-roster-disband-peers.sh T7
(lines 165-195) re-writes the fixture at :185 before its dismiss/untrack
assertions, so the no-file state is never the state under test.

**Requirement — behaviour is already correct; this is test and documentation
work only. No behaviour change.**

1. `untrack` with no team file: exit 0, stdout exactly as F5. This is the right
   answer — `untrack` is idempotent by design and "already forgotten" is success.
2. `dismiss` with no team file: exit 0 with F6's `{ dismissed: false, reason:
   "no active team and no live peers", ... }` when the peer registry offers no
   closable session; exit 2 via `fail()` with F6's message when it does. This is
   the right answer — with the record gone, a live untracked session is exactly
   the case the operator must be told about rather than have silently ignored.
3. Both behaviours get documented in docs/cli-tools.md under their verbs.
4. T7 in test-roster-disband-peers.sh must be left as it is. The new coverage
   goes where the file removal is the subject, tests/test-roster-disband-close.sh.

### R3 — derive the socket directory instead of hardcoding it

**Decision changed in r2: no test-only knob. Derive the directory from the
harness-supplied value the session already has.** Per F15 the harness exports
`CLAUDE_CODE_MESSAGING_SOCKET` — this session's own socket, in the same
directory every session's socket lives in. Its directory portion is therefore
the authoritative answer to the question roster.mjs:3600 currently guesses.

This is strictly better than r1's override on all three counts: it removes the
hardcoded harness path rather than adding an indirection beside it, it follows
the harness automatically if the directory ever moves, and it makes the branch
testable with no new configuration surface — so spec 0052 C2's "no config knob"
stands unweakened rather than revisited. **NE4 is moot and withdrawn.**

**Requirement.**

1. The directory portion of the path built at roster.mjs:3600 comes from the
   directory of `CLAUDE_CODE_MESSAGING_SOCKET` when that variable is set and
   non-empty, and falls back to `/tmp/cc-socks` when it is unset or empty. The
   pid used in the filename is still the **orchestrator's** pid from the team
   record — only the directory is derived, never the pid. The `existsSync` guard
   and the `uds:` prefix are unchanged.
2. The fallback must remain, because nothing guarantees the variable is present
   in every invocation context. When it is absent the behaviour is byte-identical
   to 0.80.0.
3. docs/cli-tools.md states in one line that the directory follows the harness's
   own socket path when available, that the real directory is harness-owned, and
   that `send_to` stays best-effort.
4. tests/test-roster-whoami.sh gains a case that sets
   `CLAUDE_CODE_MESSAGING_SOCKET` to a path inside a temporary directory,
   creates `<orchestrator pid>.sock` there for a live pid, and asserts `send_to`
   is `uds:<that path>`; plus a case with the file absent asserting
   `send_to: null`. **No test may create, write, read or remove anything under
   the real `/tmp/cc-socks`.**

   **G3 ruling — the unset-fallback case is downgraded, not forced.** Per F24
   `whoami` never emits the constructed path, and `send_to` is non-null only
   when the socket file exists, so with the variable unset a test can only ever
   observe `send_to: null`. That is what it asserts: **variable unset → exit 0,
   `send_to: null`, and nothing touched under the real `/tmp/cc-socks`.**

   Both alternatives are rejected. Adding an output field carrying the
   constructed path changes a CLI contract to serve a test. Extracting a pure
   helper into a lib so a node one-liner can import it moves code across a file
   boundary to test one `||`. The fallback is a single default on a value whose
   live branch is now covered directly; that is enough.

### R4 — the orchestrator's name: WONT-FIX as posed, with a narrower answer

**WONT-FIX: persisting the orchestrator's name at team-record write time.**
F10 settles it — the session writing the record cannot learn its own
human-readable name. There is no source to persist. The dispatch's
"NEEDS-EVIDENCE if unknown" resolves to "known, and the answer is no".

**User ruling (r2): adopt the last-observed name, labelled as observed rather
than verified.** The narrower requirement below is confirmed and now pinned
against the real store.

`whoami` exists for the peer that has no message in hand — most often one that
lost context. For that peer, the last session that briefed it is the most useful
reply target available.

1. `whoami` output gains a **last-observed brief** block, read from the existing
   store at F16. Nothing new is persisted and no team record gains a field, so
   existing records cannot break and there is nothing to migrate.
2. **The block is the top-level key `last_observed_brief` in whoami's output,
   NOT a field inside the existing `orchestrator` object.** They answer
   different questions:
   `orchestrator` is what the team record says, this is who last spoke to this
   session, and the two can legitimately differ. Nesting the observed value
   inside the recorded one would imply a verification that did not happen.
3. **Output contract.** The block is `null` when no matching row exists.
   Otherwise it carries, under these exact keys: `from`, `from_name`,
   `reply_to`, `ts`. `from_name` is `null` rather than `""` when the stored
   value is empty (F16). `reply_to` is surfaced alongside the name deliberately
   — it is the address, while the name is what SendMessage takes, and a caller
   may need either.

   **G4 ruling:** since the inner keys mirror the stored row, the "observed, not
   verified" labelling lives entirely in the key name `last_observed_brief` and
   in docs/cli-tools.md. That is sufficient and no inner field restates it.
4. **Row selection.** The last row in file order whose `session_id` equals this
   session's, excluding `type: "turn"` and `type: "dispatch"` rows (F16), any
   `status`. Read via the existing `readPeerRecords()` (lib-peer.mjs:155); do
   not write a second reader.
5. **Resolving this session's own id** (F17 — a cold CLI has no hook payload):
   prefer `CLAUDE_CODE_SESSION_ID` from the environment, and fall back to the
   `session_id` on this pid's `peers.jsonl` row. **G5(v) confirmed:** that row
   is found by pid (F23), `latestRoster(dir).find((r) => r.pid === myPid)` —
   the same row the pane id is derived from, reached the same way. There is no
   pane-id-to-row lookup to reuse, because the derivation runs the other
   direction.

   **G5 rulings.**

   - **(i) and (ii) — `reason` is not touched.** It keeps meaning exactly what
     it means today: member resolution, with `null` for success. When the block
     cannot be produced, `last_observed_brief` is simply `null`, and no cause
     field is added anywhere. The two causes — no resolvable session id, and no
     matching row — are documented in docs/cli-tools.md rather than encoded in
     output. Distinguishing them in the payload would cost a new enum that no
     caller has asked for, and overloading `reason` would change what every
     existing caller branching on it sees.
   - **(iii)** therefore does not arise: there is no precedence question between
     `last_observed_brief` and the `reason` enum, because they no longer
     interact.
   - **(iv) — yes, the block is always computed, including on every early
     exit.** `empty()` at roster.mjs:3573 must carry it too. This is the point:
     `CLAUDE_CODE_SESSION_ID` needs neither a pane nor a team, so the peer with
     no pane id, no team, or an ambiguous match is exactly the lost-context peer
     this block exists to serve. A whoami that resolves no member must still be
     able to say who last briefed this session. **`last_observed_brief` is
     therefore present as a key on every whoami output, `null` or populated.**
6. **When no row exists** — which is the normal case for a session briefed by a
   plain cross-session message, since only sentinel and `[hierarchy-msg …]`
   briefs create a row (F17) — the block is `null`. This must be documented as
   expected, not as a failure: the absence of a row means nobody filed an
   obligation, not that the session is unaddressable.
7. Precedence is unchanged from 0052 C3: a brief's `reply-to` and the ListAgents
   name remain authoritative; this block, like `send_to`, is a fallback for when
   neither is in hand. docs/cli-tools.md must say so where it documents the
   block, and must label the values observed, not verified.
8. `whoami` stays read-only. Reading the store is permitted; writing to it is
   not. The store is global under `HOME` (F16), so **every test covering this
   must HOME-redirect, and no test may read or write the real
   `~/.claude/agent-hierarchy.peer-pending.jsonl`.**

### R5 — the disband plan's unconditional `next`: keep as is, document

**Decision: no code change.** Per F7 the plan always emits `next`. Under 0052
B1 a `--close` with zero closable members is still meaningful work: reconcile
prunes dead and nameless rows and may delete the team record entirely.
Suppressing `next` in that case would hand the agent a plan it has to turn into a
command itself, which is exactly what 0052's "the agent assembles nothing" rule
forbids.

**Requirement.** docs/cli-tools.md states, in one line under `disband`, that
`next` is always present and that running it with no live panes still
reconciles the record. No behaviour change, no new test.

### R6 — the route-gate exemption must fail closed on an unreadable team record

**Problem.** Per F11 a team file that exists but does not parse is dropped by the
`t &&` filter. The `holders.every(...)` check then runs only over the records
that did parse, so a corrupt record lets the exemption pass on the strength of
the others — a fail-open in a gate whose own comment says an unrecognised
`roster_level` must fail closed.

**Requirement.**

1. The exemption uses the R1 helper. Any candidate team file — the legacy one
   and every name from `listTeamNames` — that exists but does not yield a usable
   record **denies the exemption outright**: `toTeamMember` is false and every
   confirm the exemption would have removed stays in place.
2. This is deliberately coarser than "only records holding this name matter": an
   unreadable record cannot be searched for the name, so it cannot be excluded
   from the set that might hold it. Failing closed on any unreadable candidate is
   the only safe reading.
3. Everything else about the exemption is unchanged: `EXEMPT_ROSTER_LEVELS`, the
   `holders.length > 0` requirement, the `every` over `roster_level`, the
   all-teams name search of spec 0011 §4.4.1/§9.1, and the role-resolution chain
   that follows.

**Consequence to accept.** One corrupt team file in a repo makes every peer send
fall back to the ordinary confirm path. That is a prompt, not a failure, and it
is recoverable by fixing or removing the file.

### R7 — ragged comment wrap (cosmetic): WONT-FIX, closed at r3

Inspection of roster.mjs:3372-3407 found nothing ragged (F25). Per r2's own
instruction — say so rather than reflowing something to have made a change —
this closes with no edit. No file changes for R7.

### R8 — concurrent same-role `spawn-ad-hoc`: minimal guard, not a lock

**Problem.** Per F12 the name is derived and checked against one read of the team
record, and the record is written after the launch. Two agents spawning the same
role into the same team can both derive the same name, both pass the check, and
both launch. **Today's failure:** two live sessions answer to one name, and the
second write can drop or duplicate the first's row, leaving a live pane that no
`dismiss` can address.

**Decision: guard against losing the record, do not try to close the race.**
A reservation protocol (a placeholder row written before launch) would close it
but leaves orphan rows on any crash between reserve and launch, and the race
needs two agents spawning the same role into the same team within about a second.
Detect-and-report is the smallest thing that prevents the unrecoverable outcome.

**Requirement.**

1. Per F18 `spawnOneCore` reuses a single read taken at roster.mjs:2217 and
   writes at :2347, with the launch inside that window. So this requirement is a
   **fresh read plus a check** immediately before the write, not merely a check:
   the derived name is re-checked against the record as it stands at write time.
2. **G7 ruling — the collision predicate.** The Implementor's reading is
   correct and is hereby the contract. Per F22, `spawnOneCore` legitimately
   replaces an existing dead row on the respawn path, and the match may be by
   role rather than by name, so "a row with that name exists" is the wrong
   test. The right one:

   > It is a collision iff the **fresh** record holds a row satisfying the same
   > `matches` predicate whose `transport_id` differs from that of the
   > `existing` row seen at roster.mjs:2237 — including the case where
   > `existing` was `null` and a match is now present.

   A row that is the same row this spawn already intended to replace is not a
   collision, and the respawn path keeps working unchanged.

   On collision the command fails (exit 2) and **must not overwrite the existing
   row**. The failure message must name the collision and report the
   just-launched session's `transport_id`, so the operator can dismiss or adopt
   the now-orphaned session.

   **R8 covers `spawn-one` as well as `spawn-ad-hoc`**, confirmed: the guard
   lives in `spawnOneCore`, both verbs route through it, and both carry the same
   launch window.

3. **G6 ruling — the write is based on the FRESH record, never the stale one.**
   Basing the write on the record read at :2217 would drop any differently-named
   row added during the launch window even when the collision check passes,
   which is the same record loss this requirement exists to prevent.
   Specifically:

   - Stale read usable, fresh read usable: the fresh record is the base. This
     spawn's member is added to it; every other row it carries is preserved.
   - **Stale read `null`, fresh read usable** (two first-spawns of different
     roles racing): the fresh record is the base and its `team_id`, `created`,
     `orchestrator` and all existing rows are preserved. The new-team
     construction at roster.mjs:2331-2343 **must not run** — minting a second
     `team_id` over a record that already exists overwrites the other spawn's
     team wholesale, which is the worst outcome available here.

4. **G8 ruling — an unusable fresh read fails, whatever the stale read was.**
   *(r4: the "while the stale read was usable" condition is removed — it let a
   stale-`null` plus unusable-fresh case through, which built a new team and
   overwrote the file. With R1.5 catching the already-unusable case before
   launch, what remains here is a file that became unusable during the window,
   but the rule is stated unconditionally so no third path can reopen the
   hole.)* This covers both the team being disbanded during the launch window
   and the file being corrupted during it. Writing would either resurrect
   a record the user had just deliberately removed, or overwrite a damaged file
   and destroy whatever it still held — and it would do so from data known to be
   stale. Exit 2, write nothing, report the just-launched `transport_id` so the
   session is recoverable, and let the message distinguish "the team file is
   gone" from "the team file is no longer readable" so the operator knows which
   happened. This is the same fail-closed direction as R1.4 and R6.
5. The launched session is deliberately left running. Killing it would be the
   command destroying work it just created on the strength of a race it detected
   late; reporting it is recoverable, and silently closing it is not.
6. Renaming the just-launched member to the next ordinal is explicitly rejected:
   `requireHerdrName` has already given the pane the derived name, so a renamed
   record would disagree with the live pane.

### R9 — default-prefix sanitisation for an unnamable repo basename: stays out

**WONT-FIX.** `teamPrefixInfo` feeds the route gate, the SessionStart suggestion
and legacy resolution, which is why 0051 R7 was withdrawn and why spec 0044 tests
6a-6e encode the refusal deliberately. `defaultTeamScope` already surfaces both
`unnamable` and `suggested`, so the user is handed a usable name to pass as
`--team`. No narrower fix is worth the blast radius.

### R10 — this repo's `.claude/agent-hierarchy.json` (recommendation only; do not edit)

**Problem.** Per F13 the SessionStart directive advertises `ct-arch1` and
`ct-implementor` while spawns derive `claudetools-<role>`. The two named peers
disagree with every live peer name.

**User ruling (r2): option 1 — delete the two `peer` keys, no `teamAlias`.**
The Orchestrator makes that repo-config edit with the user. It is **not** part
of the plugin change list for 0.81.0 and no implementation of 0053 touches any
file under `/Users/jimcline/git/repos/claudetools/.claude/`. Recorded here only
so the reasoning survives.

**Recommendation as given, smallest first.**

1. **Chosen — delete the two `peer` keys** (`roles.architect.peer`,
   `roles.implementor.peer`), keeping `dispatch: "peer"`. Both then fall through
   to `peerName(repoBasename, role)` (F13) and the directive advertises exactly
   what a spawn derives: `claudetools-architect`, `claudetools-implementor`. No
   other behaviour moves.
2. **Not chosen — `teamAlias: "ct"`** plus
   deleting the same two `peer` keys. `ct-implementor` already equals
   `ct-<role>`, which is evidence the intent was a prefix and that `ct-arch1` is
   the hand-picked outlier. `teamAlias` is the right expression of that intent,
   because it says it once instead of per role.

**Blast radius that ruled option 2 out.** Per F14 `teamAlias`
feeds `repoBasename`, which also drives the default team prefix and team file
naming — not just peer names. Any currently live peer named `claudetools-*`
would stop matching. Option 1 has none of that.

Either way the per-role `peer` overrides should go: they name individuals where
the rest of the system derives from a role.

**Not touched by this spec.** No file under `/Users/jimcline/git/repos/claudetools/.claude/`
is edited by the implementation of 0053.

## 4. Files expected to change

| File | Why |
| --- | --- |
| `hooks/lib-roster.mjs` | R1: new three-outcome helper; `defaultTeamScope` change; R1.6: `readTeam` requires an array `members` |
| `hooks/roster.mjs` (`resolveWritableTeamScope`, :1403-1429) | R1.4 + R1.5: writing verbs refuse to write to, or beside, an unusable team file at the resolved scope — one check, before any launch |
| `hooks/pretooluse-route-gate.mjs` | R6: fail closed using the R1 helper |
| `hooks/roster.mjs` | R3 socket dir derived at :3600; R4 `last_observed_brief` on every whoami output incl. `empty()` :3573; R8 fresh read, collision predicate, and fresh-record write base at :2331-2347 |
| `docs/cli-tools.md` | R2, R3, R4, R5 documentation; R1.5 refusal; one line on R1.2's read-verb scope side effect |
| `tests/test-roster-disband-close.sh` | R2: dismiss/untrack with the team file gone |
| `tests/test-roster-whoami.sh` | R3: all three `send_to` cases; R4: block present, absent, and unresolvable session id — HOME-redirected throughout |
| `tests/test-roster-team-scope.sh` | R1: corrupt legacy `team.json` keeps the default scope |
| `tests/test-roster-skill-gate.sh` or the route-gate test file | R6: exemption denied when a candidate record is unreadable |
| `tests/test-roster-spawn-one.sh` | R8: pre-write collision fails without overwriting |
| `.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json` | 0.81.0 — both, together |

No hook registration, gate allowlist, or deny-list changes. No directive or
agent `.md` text changes — the size ceilings (auto 14575/14600, confirm
16479/16500, orchestrator.md 7304/7350, implementor.md 5089/5100) are not
approached, let alone raised.

`tests/test-roster-disband-peers.sh` is explicitly **not** edited (R2.4).

## 5. Test plan

| Req | Case | Expectation |
| --- | --- | --- |
| R1 | Corrupt legacy `team.json`, valid basename | scope stays `{ team: null }`, offending path reported on the scope object |
| R1 | Absent `team.json`, valid basename | unchanged: scope is the prefix |
| R1 | Absent `team.json`, unnamable basename | unchanged: `unnamable` + `suggested` as today |
| R1 | Corrupt legacy `team.json`, then `disband --close` | `team_file_unreadable` names it; file is neither written nor removed (0052 B4) |
| R1 | Both apply: corrupt legacy file **and** unnamable basename | `unreadable`, `unnamable` and `suggested` all present |
| R1.4 | Corrupt legacy `team.json`, `spawn-ad-hoc` with no `--team` | exit 2, nothing written, message names the file and both remedies |
| R1.4 | Same, `spawn-one` with no `--team` | exit 2, nothing written |
| R1.4 | Same, `create` with no `--team` | exit 2, nothing written |
| R1.4 | Corrupt legacy `team.json`, `spawn-ad-hoc --team <name>` | unchanged: succeeds, writes `teams/<name>.json` |
| R1.4 | Valid or absent legacy `team.json` | unchanged for every writing verb |
| R1.5 | Corrupt `teams/T.json`, `spawn-ad-hoc --team T` | exit 2, file untouched, message names the path and the remedy |
| R1.5 | Same, `spawn-one --team T` | exit 2, file untouched |
| R1.5 | Same, `create --team T` (execution path) | exit 2, file untouched |
| R1.5 | Same, `create` plan / dry-run path | exit 2, no plan emitted |
| R1.5 | Refusal happens before any pane launch | no session is spawned; nothing to strand |
| R1.5 | Corrupt `teams/T.json`, a **read** verb with `--team T` | unchanged — read verbs never refuse |
| R1.6 | `{"version":1}` (no `members`) at the resolved scope, `spawn-ad-hoc` | exit 2 **before** launch; no session spawned, no stack trace, file untouched |
| R1.6 | `{"version":1,"members":"x"}` (non-array) | same as above — the predicate is `Array.isArray`, not presence |
| R1.6 | `{"version":1,"members":[]}` | **usable**: an empty team is legitimate and must still work |
| R1.6 | Members-less file, `disband --close` | `team_file_unreadable` names it; file neither written nor removed |
| R1.6 | Members-less file, `dismiss` | existing no-team path (F6); no throw |
| R1.6 | Members-less file, `untrack` | existing no-team path (F5), exit 0; no throw |
| R1.6 | Members-less file, `adopt` | reports no team; the file is **not** rewritten with a new `orchestrator.pid` |
| R1.6 | Members-less file, route-gate exemption | denied, fail closed (R6) |
| R1.6 | Every existing fixture | unchanged — none omits `members` |
| R2 | `disband --close` removes the record, then `untrack` | exit 0, `already_untracked: true`, reason as F5 |
| R2 | Same, then `dismiss <name>` with no closable peer | exit 0, `dismissed: false`, reason as F6 |
| R2 | Same, then `dismiss <name>` with a live untracked peer | exit 2, message lists the live sessions and the accepted identifiers |
| R3 | `CLAUDE_CODE_MESSAGING_SOCKET` set under a temp dir, `<orch pid>.sock` present, pid alive | `send_to` is `uds:<temp dir>/<orch pid>.sock` |
| R3 | Same, socket file absent | `send_to: null` |
| R3 | Variable unset | exit 0, `send_to: null`, nothing touched under the real `/tmp/cc-socks` (G3 — the path itself is not observable) |
| R3 | Variable set | the pid in the filename is still the orchestrator's, not this session's |
| R4 | HOME-redirected store, obligation row for this `session_id` with a `from_name` | block carries `from`, `from_name`, `reply_to`, `ts`; labelled observed |
| R4 | Row exists with `from_name: ""` | `from_name` is `null`, not `""` |
| R4 | Store holds only `type: "turn"` / `type: "dispatch"` rows | block is `null` |
| R4 | Store holds rows for a different `session_id` only | block is `null` |
| R4 | Several matching rows | the last in file order wins, whatever its `status` |
| R4 | No store file at all | block is `null`; whoami otherwise unchanged; no file created |
| R4 | Session id unresolvable by env or `peers.jsonl` | block is `null`; `reason` is unchanged from today's value for that case |
| R4 | No pane id / no team / not-a-member / ambiguous early exit | `last_observed_brief` is still present and populated when a row matches |
| R4 | Env id absent, `peers.jsonl` row present for this pid | block resolves from that row's `session_id` |
| R4 | Team record predating this change | whoami behaves identically; no migration, no write |
| R4 | Any R4 case | the real `~/.claude/agent-hierarchy.peer-pending.jsonl` is never opened |
| R5 | Plan with zero members having panes | `next` present and identical in shape to the non-empty case |
| R6 | One candidate team file corrupt, name held by another exempt record | exemption denied; confirms preserved |
| R6 | All candidate records readable and exempt | unchanged: exemption granted |
| R6 | All readable, one with a non-exempt `roster_level` | unchanged: exemption denied |
| R8 | Matching row with a different `transport_id` present at write time, absent at derive time | exit 2, existing row intact, message carries the launched `transport_id` |
| R8 | Respawn over a same-role dead row (`existing` non-null, same `transport_id`) | unchanged: not a collision, the row is replaced as today |
| R8 | A differently-named row added during the launch window, no collision | it survives the write (fresh record is the base) |
| R8 | Stale read `null`, fresh read usable | fresh `team_id`/`created`/`orchestrator`/rows all preserved; no new team minted |
| R8 | Team file removed during the launch window | exit 2, nothing written, message says the file is gone, `transport_id` reported |
| R8 | Team file corrupted during the launch window | exit 2, nothing written, message says it is unreadable, `transport_id` reported |
| R8 | Stale read `null` **and** fresh read unusable | exit 2, nothing written — no new team built over the unreadable file |
| R8 | `spawn-one` on the same collision shape | behaves identically to `spawn-ad-hoc` |
| R8 | No collision | unchanged spawn behaviour |

Whole-suite regression is required for R1 and R6 — both change decisions that
many tests depend on. See NE5 and NE6. R1.4 widens R1's blast radius to every
spawning verb, so NE5 now covers the spawn and create tests too.

## 6. NEEDS-EVIDENCE

NE1-NE4 were answered by the Implementor at r2 and are recorded as facts F16-F20.
NE5 and NE6 remain open. **I did not run any of them.**

- **NE1 — RESOLVED (F20).** No test relies on a corrupt legacy `team.json`
  falling through; the only malformed fixture is named-scope. R1 proceeds as
  written.
- **NE2 — RESOLVED, positive with a catch (F16, F17).** The store exists,
  persists `from_name`, and is readable cold — but it is global under `HOME`,
  rows key on `session_id`, and only sentinel / `[hierarchy-msg …]` briefs
  create one. R4 proceeds with all three consequences pinned in R4.4-R4.6 and
  R4.8.
- **NE3 — RESOLVED (F18).** An earlier read is reused, so R8 is a fresh read
  plus a check.
- **NE4 — WITHDRAWN, moot.** R3 no longer adds an environment override, so the
  naming question disappeared. F19 records the precedent anyway, since a future
  spec may want it.
- **NE5** Full suite after R1, **including R1.4** — the spawn, spawn-ad-hoc and
  create tests are now in scope because a writing verb can newly refuse.
- **NE7 (r5)** Full suite after R1.6. `readTeam` is the most widely shared
  helper this spec touches, and the change is a widening of what returns `null`.
  *Any* failure comes back to me before being patched: a test that breaks here is
  either relying on a members-less record (which no fixture does today) or is
  exercising a `.members` path that was silently depending on the old
  permissiveness — and the second case is a finding, not a fix. *Any failure whose fixture involves a malformed
  team file comes back to me before being "fixed" — it may be encoding the
  behaviour R1 deliberately changes.*
- **NE6** Full suite after R6, with particular attention to the route-gate and
  skill-gate tests. *A failure here means either a fixture leaves a corrupt team
  file behind unintentionally, or R6.2's coarseness is wider than a test
  expects; either way it comes back to me, not to a local patch.*

## 7. Decisions, and what I refused to decide

**Decided.**

- R1: scope must be claimed by a corrupt file, not skipped past — the
  alternative leaves an unreachable broken record and a silent second team.
- R3 (revised at r2): derive the directory from the harness's own exported
  socket path rather than adding a knob beside a hardcoded guess. Removes an
  assumption instead of adding an indirection, and leaves 0052 C2 intact.
- R4: persisting the name is impossible (F10), so the only available answer is
  observational; the user ruled to take it, labelled as observed. It sits in its
  own output block rather than inside `orchestrator`, and surfaces `reply_to`
  next to the name because the address and the name serve different callers.
- R5, R9: no change, for the reasons stated in each.
- R6: fail closed, coarsely, because an unreadable record cannot be searched.
- R8: prevent record loss; do not attempt to close the race.

**Ruled by the user at r2 — both forks closed, none left open.**

1. **R4's observational name:** take it, labelled as observed rather than
   verified.
2. **R10:** delete the two `peer` keys; no `teamAlias`. The Orchestrator makes
   that edit with the user, outside this spec.

**Confidence at r3: high across every requirement.** r2's one factual error is
corrected (R1.3 claimed no caller needed to act; F21 shows every writing verb
did), and the r3 rulings pin the key names, predicates and write base that the
tests must hold to.

**r5 note.** R1.6 is the third instance of the same rule and the last one
available: after it, "this file parses" and "this file is a team record" are the
same statement, which is what R1.5 and R8.4 already assumed. It fixes a
pre-existing 0.80.0 hazard rather than one this spec introduced, and it is in
scope under "fix the remaining issues". The one thing to watch is NE7 — it
widens the most shared helper in the change set.

**r4 note.** R1.5 generalises the rule the user already chose for R1.4 rather
than introducing a new one, and it reduces the design to a single sentence — a
writing verb never overwrites a team file it cannot read — enforced at one
choke point. The user's R1.4 ruling is not reopened by it.

**The one judgement call worth re-reading before implementation** is R1.4: it
makes a corrupt legacy `team.json` refuse an ad hoc spawn that used to succeed
quietly. I weighed that against 0051 and took the refusal, because the escape
hatch is one flag named in the error text and the alternative defers a worse
failure to teardown. If the user disagrees, the fallback is R1.4 option (b) —
keep the retargeting and correct only the Consequence prose — and nothing else
in this spec moves.

Nothing here needs the Ultra-Advisor. The one thing that would is unchanged: if
a *verified* orchestrator name is ever wanted in `whoami`, that means telling a
session its own name at spawn time — a new cross-session contract rather than a
lookup, and a decision above this spec.
