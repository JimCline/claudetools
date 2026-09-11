# 0050 — disband/dismiss find live peers themselves

Status: r2 · Base: main @ 0.74.1 (impl at 0.75.0 working tree) · Request: `20260910-205409-ube6`, r2 rulings `20260910-213113-ls7w` · Author: architect

## r2 — rulings on Implementor gaps (impl response `20260910-210203-1tom`)

- **R1 (Q1/G1) — title fallback: YES, (a)+(c).** `herdr agent list` carries `name` only for `herdr agent start --name` agents; roster-spawned panes carry `terminal_title_stripped` set by roster's own `herdr pane rename` (roster.mjs:1471). The title is therefore roster's own naming channel, not a foreign input. Match key = `name` when present, else `terminal_title_stripped`; when both present and they disagree, `name` wins. Threat check: forging a title to `<P>-<role>` requires local control of the herdr session, at which point closing panes directly is easier — and the pane still has to pass the cwd gate (live on every agent per E1), be listed with its pane_id in the single confirmation, pass the always-ask harness gate, and match the plan token. Not a trust boundary this feature can add or remove. Slot `how` must say which key matched (`herdr agent list (name)` / `(title)`) so the confirmation shows it. (c) is conditional on **E4** below: if `herdr agent start` accepts a name flag, roster's spawn line (:751) passes it in the same release so `name` is populated going forward; `pane rename` stays (title is what humans and ListAgents see). If no such flag, (c) is dropped, not emulated.
- **R2 (Q2/G2) — non-herdr-team skip: ACCEPTED as written.** A team file declaring tmux/terminal has no herdr registry to consult; querying herdr for it contradicts spec 0002-era invariants (test-roster-disband.sh zero-herdr-execs, test-roster-layout-splits.sh) and §2.1's "tmux out of scope". `sources.herdr = {ok:false, reason:"team transport is not herdr"}` is the correct report. No team file → arm runs. Recorded as D7.
- **R3 (G3) — populate `session_id`: YES.** Arm slots take `session_id` from `agent_session.value` (E1 shows it is the real Claude session id; the Implementor's own scratchpad dir matched). Consequences, all required: `dismiss <session_id>` and `dismiss <8+ char prefix>` resolve herdr-only agents; dedup (registry wins) keys on pane_id OR name OR session_id; liveness stays presence-based (no change); `pid` stays null (absent in payload). Slot shape in §2.1 amended.
- **R4 (E3 → U2 wording)** — peers do have `EndConversation`; the disband notice becomes: `[hierarchy-disband] <P>: disbanded by the orchestrator — stop work, send no further reports, and end your session if you can.` Report stays "notified, not closed".
- **E1/E2/E3 answered** (impl [3]): both `cwd` and `foreground_cwd` present → T3 live; other repos ARE listed (7 checkouts) → D3 prefix filter load-bearing; ListAgents has name + 6-char sid suffix only, herdr-spawned and plain `--agent` peers indistinguishable → §3 step 4 name-only match stands.
- **G4/G5** — as designed; no change.
- **New tests:** T6 gains `dismiss <session_id>` and `dismiss <sid8>` resolving a herdr-only agent; T4 gains a dedup case on `session_id` alone (peers row with session_id S + herdr agent with `agent_session.value` S, different/absent pane); **T12** title-only agent (`name` absent, `terminal_title_stripped: "myrepo-architect"`) is matched, and an agent with `name: "foo-x"` + title `myrepo-architect` is NOT (name wins); T12b title `myrepo-architect` with cwd under another git root excluded. Fixtures for T1–T11 must be re-shaped to the real payload (`agent_session`, `terminal_title_stripped`, `cwd`+`foreground_cwd`) — a fixture that only ever sets `name` is what hid G1.
- **E4 (NEEDS-EVIDENCE)** — `herdr agent start --help`: does it accept a name flag (or is the positional at :751 already meant to be the name — if so, why is `name` absent on those agents)? Decides R1(c).

## 0. Problem

Ad-hoc peers (spawn-one / spawn-ad-hoc, rows never landed or swept) → `roster.mjs disband` returns `{disbanded:false, reason:"no active team and no live peers"}` (roster.mjs:2679/2713; dismiss :2782) and the LLM gives up or asks the user where the sessions are, while `herdr agent list` and `ListAgents` both show `<repo>-<role>` sessions.

Root cause, code side: with no team.json the plan reads **peers.jsonl only** (`peerFallbackMembers` → `livePeerSlots`, lib-hier.mjs:785-798). Herdr topology is consulted only to *heal* rows that already exist (`resyncMembers` :1005-1008, dismiss step 5 :1743-1790 still requires a peers row). No path feeds a herdr-only pane into a close set, even though the close step needs nothing but a pane_id (`closeMemberPane` :1658-1668).

Root cause, skill side: `skills/agent-team/SKILL.md` §disband (:405-475) and §dismiss (:550-595) have no step for an empty plan; `herdr agent list` appears nowhere; `ListAgents` matching exists only in §create step 4 (:341).

## 1. Decisions

- **D1 — CLI side: yes.** The registry-fallback list gains a herdr-topology arm. Rationale: every reader (disband no-team plan/close, disband-with-team extras, dismiss fallback, `teams untracked_live`) routes through the same peers.jsonl reader; one arm there fixes all five call sites, the close path already accepts any pane_id, and the LLM should never have to re-derive from `herdr agent list` what the CLI already queried. Skill-only was rejected: it would leave the CLI's plan lying (`no live peers`) and put a JSON-parsing loop on the LLM.
- **D2 — Skill side: mandatory recovery step** in §disband and §dismiss for what the CLI cannot see: `ListAgents` (LLM-only tool) and other team files (`roster.mjs teams`). Three sources, fixed order, all consulted **before** the single confirmation.
- **D3 — Match rule (both sides):** an agent belongs to this repo's hierarchy iff its name is `<P>-<role>` or `<P>-<role>-<n>` where `<role>` ∈ the hierarchy role set already used by `hierarchyRoleOf`/`rosterMemberNames` and `<P>` **equals exactly** the prefix this command would use to spawn (`teamPrefix(cwd, --team)`, lib-config.mjs:601-624: `--team` > alias > basename(git root)). Parse from the right (strip `-<n>`, then `-<role>`; remainder must equal P) because P may contain hyphens. Names not matching contribute nothing — never "any agent in herdr".
- **D4 — Never close the caller.** A herdr agent whose pane_id equals `HERDR_PANE_ID` of the running command is excluded from the herdr arm.
- **D5 — "Exhaustive" = exactly these sources**, and the empty report must name each with its outcome and the prefix P used (§4).
- **D3a (r2)** — the herdr agent "name" for D3 is `name`, else `terminal_title_stripped`; `name` wins on disagreement (R1).
- **D7 (r2)** — the herdr arm and its query are skipped when the scope's team file declares a non-herdr transport; `sources.herdr` reports `{ok:false, reason:"team transport is not herdr"}`. No team file → arm runs (R2).
- **D6 — Unchanged:** plan→confirm→close two-step and its token; harness always-ask gate on `--close`; untrack/track semantics; team.json row lifecycle; peers.jsonl never written by this feature; no new verbs.

## 2. CLI contract (roster.mjs / lib-hier.mjs)

### 2.1 Herdr arm of the live-registry fallback

Where: the one function that turns peers.jsonl into live slots for fallback/extras/untracked (today `livePeerSlots`, lib-hier.mjs:785-798) — or its immediate callers `peerFallbackMembers` (roster.mjs ~1825), `peerExtras` (:1825-1828), `untrackedLive` (:1842-1846) if the scope/prefix plumbing is cleaner there. Implementor's call; the requirement is that **all five consumers** below see the arm with no per-site logic:
1. disband plan, no team.json (:2705-2716)
2. disband `--close`, no team.json (:2670-2686)
3. disband with team.json — extras beyond `team.members` (:2743)
4. dismiss fallback resolution (:2779-2790, `resolvePeerTarget`)
5. `teams` → per-team and top-level `untracked_live` (:3242, :3246)

Behaviour:
- Query `herdr agent list` through the existing `herdrCall` site (:855-877, `queryHerdrTopology` :967-972). **One** query per command; reuse the result if the command already queried (disband-with-herdr-team already calls `resyncMembers`).
- Select agents by D3 with P = `teamPrefix(cwd, --team)` for NO_TEAM_SCOPE; for a team scope, P = that team's name (the value member names were derived from). Apply D4.
- If the topology reports a cwd (`cwd` / `foreground_cwd` — E1) and it is non-null, require `findGitRoot(realpath(cwd))` to equal this command's git root; mismatch → excluded. Null/absent cwd → name match suffices (U1).
- Each selected agent becomes a slot with the same shape the consumers already accept: `name` (per D3a), `role` (parsed), `transport: "herdr"`, `transport_id: pane_id`, `session_id: agent_session.value` when present else null (r2 R3), `pid: null`, `cwd` (topology value or null), `live: true`, `source: "herdr"`, `how` naming the matched key (r2 R1). Presence in `herdr agent list` **is** liveness — no per-agent `herdr agent get` (ponytail: N extra execs for a status the pane close does not need; if a dead agent's pane lingers, closing it is still the disband intent).
- **Dedup, registry wins:** an agent whose `pane_id` matches a team.json member's `transport_id` or a peers.jsonl slot's `transport_id`, or whose `name` matches either, or whose `session_id` matches a registry row's (r2 R3), is not added — the richer row already represents it (`resyncMembers` already heals team rows from the same query).
- Scope isolation already tested for peers rows (test-team-untracked-live.sh L3/L4) must hold for herdr rows: an agent whose P is another team's name never appears under NO_TEAM_SCOPE or under a different team.
- **Herdr unavailable or query fails** (not on PATH, non-zero exit, unparseable JSON): the arm contributes nothing and never throws or `fail()`s — same degrade rule as :2725-2730. The outcome is *reported*, not hidden (§2.2).
- Transport hint: for `source:"peers"` rows `closeOne` already forces herdr (:1854-1864); herdr rows carry `transport:"herdr"` explicitly so nothing new is needed there. tmux teams are out of scope (no tmux registry to query; unchanged).

### 2.2 Plan / result output additions

Every plan and close result of `disband` and `dismiss`, and the `teams` top-level object, gains one sibling field:

```
"sources": {
  "team":  { "file": "<path>|null", "members": <n> },
  "peers": { "live": <n> },
  "herdr": { "ok": true, "agents": <total listed>, "matched": <n>, "prefix": "<P>" }
         | { "ok": false, "reason": "<query error or 'herdr not on PATH'>", "prefix": "<P>" }
}
```
Existing fields and the reason strings `"no active team and no live peers"` are **unchanged** (tests grep them); the reason is now only emitted when peers AND herdr both yield nothing. Plan `close` entries from the herdr arm carry `source: "herdr"` (peers entries already carry `source` at the result level; per-entry is what the confirmation message needs — Implementor: add per-entry `source` for peers entries too only if it is a one-line change; otherwise result-level is acceptable).

### 2.3 Close token

`closeToken()` sorts member ids without dedup (comment at :2675-2678). Herdr slots have `session_id: null`; the id used for the token must be deterministic and unique per slot — pane_id when session_id is null. Requirement: plan token == close token for the same topology; a pane that moved between plan and close invalidates the token (already the behaviour for healed team rows, test-roster-dismiss.sh:139-146).

### 2.4 dismiss

No new selector forms. Because the fallback list now contains herdr slots, the existing resolution (:1743-1790: pane_id, session_id, ≥8-char prefix, name, herdr display name) resolves a herdr-only agent by `pane_id` or by exact `name` with no code change beyond §2.1. Ambiguity rule (>1 match → `fail`) unchanged. The :2785 `fail` text ("live untracked sessions: […]") automatically lists herdr-only agents; that is the CLI's own "here is what I found" — keep it.

## 3. Skill contract (`skills/agent-team/SKILL.md`)

Add one subsection, referenced from **both** §disband (after the plan step, before confirm) and §dismiss (after the plan step): **"Plan came back empty — search before you say so."** Content (requirements, not final prose):

1. **Trigger:** plan result has `disbanded:false`/`dismissed:false` with reason `no active team and no live peers`, or `close` is empty, or dismiss `fail`s with "no member named". Do not stop, do not report yet, do not ask the user where the sessions are.
2. **Source 1 — other team files:** `node <root>/hooks/roster.mjs teams --cwd <abs cwd>`. If any team lists live members or `untracked_live` rows matching D3, re-run the plan with `--team <that team>` (disband) or with that member's `pane_id`/`role@sid8` (dismiss). This catches "disband the team" when the peers are tracked under an alias.
3. **Source 2 — the CLI's own herdr result:** read `sources.herdr` from the plan. `ok:false` → note the reason for the report; do **not** shell out to `herdr agent list` yourself (same PATH, same answer; the CLI already tried).
4. **Source 3 — `ListAgents`:** call it once; select rows whose name matches D3 with P = the prefix shown in `sources.herdr.prefix`. Rows not already in the plan's `close` set (by name) are **ListAgents-only** sessions: reachable by SendMessage, not by pane close (`route: pane` members never appear here, :351; `--agent` peers started outside herdr appear only here).
5. **One confirmation**, listing every entry found with its source (`team` / `peers` / `herdr` / `ListAgents-only`) and the pane or address that will be acted on. The rule "still exactly one conversational confirmation, independent of the harness gate" (:existing) is unchanged.
6. **Close:** pane rows → the existing `--close --confirm --plan-token` step. ListAgents-only rows → after the same confirmation, one `SendMessage` per session: `[hierarchy-disband] <team/prefix>: disbanded by the orchestrator — stop work, send no further reports, and end your session if you can.` (r2 R4) Report them as *notified, not closed* (U2). Never silently drop them.
7. **Forbidden phrasing** (grep-invariant, T10): the skill must not contain "ask the user where", "ask the user to locate", or present `no live peers` as a terminal outcome; it must contain the literal `ListAgents` in both §disband and §dismiss.
8. **Empty report wording**, only after steps 2-4 all came back empty:
   > Nothing to disband. Searched with prefix `<P>`: team files in `<hierarchy dir>` (N teams, 0 live members), peers.jsonl (0 live), herdr agent list (`ok`: M agents, none named `<P>-*` | `unavailable: <reason>`), ListAgents (K sessions, none named `<P>-*`). If the sessions were started under another name or from another checkout, say which and I will retry with `--team <name>`.
   Naming P is the point: a prefix mismatch (alias vs basename, other checkout) is the one thing the user can spot instantly.

§teams text (:95-104) gains one sentence: `untracked_live` also lists herdr agents named by convention that have no registry row (`source: "herdr"`).

`docs/cli-tools.md`: document the `sources` field on disband/dismiss/teams in one line each.

## 4. What must NOT change

- Two-step plan→confirm→close, token semantics, harness always-ask gate on `--close`.
- `resyncMembers` never persists; `peers.jsonl` is never written by disband/dismiss; team.json row removal rules (:2861-2865) unchanged.
- No new verbs, no new selector forms, no tmux topology query.
- Reason strings and existing JSON fields (additive only).
- Scope isolation (L3/L4) for peers rows.

## 5. Tests (all falsifiable; `tests/test-roster-disband-herdr-only.sh` unless noted; fake `herdr` on PATH as in test-roster-dismiss.sh:139)

- T1 no team.json, no peers.jsonl, fake `agent list` → `myrepo-architect` pane `P7`: plan `close` has one entry `source:"herdr"`, `sources.herdr.matched:1`; `--close --confirm` with the token closes exactly `P7` (argv-verbatim assertion as test-roster-disband-close.sh).
- T2 same, agent named `otherrepo-architect` → plan reason `no active team and no live peers`, `sources.herdr.{ok:true,matched:0}`.
- T3 (conditional on E1 = cwd present) `myrepo-architect` with cwd under another git root → excluded, `matched:0`.
- T4 dedup: peers.jsonl live row with `pane_id P7` + herdr `P7` → one close entry, token stable.
- T5 `FAKE_HERDR_FAIL=1` → exit 0, `sources.herdr.ok:false` with reason, plan otherwise as today.
- T6 dismiss `myrepo-architect` and dismiss `P7` each resolve the herdr-only agent and close `P7`; `dismiss architect` (role only) still fails as today (:2792).
- T7 `teams` top-level `untracked_live` lists the herdr-only agent with `source:"herdr"`, `session_id:null`.
- T8 team.json present (transport herdr, members [reviewer]) + herdr agent `myrepo-implementor` not in members → disband close set includes it as an extra; team member still healed as before.
- T9 ordinal `myrepo-implementor-2` matches; `myrepo-implementor-x` and `myrepoarchitect` do not; `--team foo` → prefix `foo`, so `foo-architect` matches and `myrepo-architect` does not.
- T10 (`tests/test-skill-disband-search.sh` or extend an existing skill-grep test): SKILL.md §disband and §dismiss each contain `ListAgents`; SKILL.md contains none of the forbidden phrases; `docs/cli-tools.md` mentions `sources`.
- T11 self-exclusion: `HERDR_PANE_ID=P7` → `P7` never in the close set.
- Existing suites must stay green; test-team-untracked-live.sh and test-roster-disband-peers.sh run without a fake herdr on PATH → herdr arm silent (`sources.herdr.ok:false`).

## 6. NEEDS-EVIDENCE

- **E1** — on the dev machine with one roster-spawned pane live: `herdr agent list` raw JSON. Decides: which cwd key exists (`cwd` vs `foreground_cwd` vs none — :963-966 says unconfirmed), whether a pid/session id is present (would let dedup and liveness be stronger; not required), and whether agents of *other* repos are listed (confirms D3's prefix filter is load-bearing). Absent cwd → T3 dropped, U1 stands.
- **E2** — `ListAgents` output in an orchestrator session while (a) a herdr-spawned `--name claudetools-reviewer` peer and (b) a plain-terminal `claude --agent ah:reviewer` peer are live: the name column for each, and any pid/cwd column. Decides the exact D3 match text in §3 step 4 and whether (b) is even discoverable.
- **E3** — does a `--agent` peer session have any way to end itself on request (an `EndConversation`-type tool in its toolset)? Decides U2's message text: "stop work" vs "end your session".

## 7. User decisions

- **U1** — herdr agent with matching name but **no reported cwd**: include (default, per "assume the sessions exist") vs exclude. Risk: same-basename repo in another checkout gets its peer closed — mitigated by the confirmation listing.
- **U2** — ListAgents-only matches: notify via SendMessage after confirmation and report "notified, not closed" (default) vs list-only and report "found, not closable". No option asks the user to find them.
- **U3** — include `orchestrator`-role agents in the herdr arm (default yes, minus D4 self-exclusion) vs exclude that role.

## 8. Version plan

One release, minor bump (new CLI behaviour + output field): bump `agent-hierarchy/.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json` together. No commits by the Implementor (per brief). Order: lib/roster arm + tests → skill + cli-tools.md + T10 → bump.

## 9. Implementor risks

- `livePeerSlots` is also read by `inScope`-sensitive callers; keep the herdr arm's scope rule (§2.1) strictly on P, never on the peers `team` tag.
- `closeToken` ids: null session_id must not collapse two herdr slots into one id.
- `queryHerdrTopology` is called from `resyncMembers` and dismiss step 5 already — do not add a second exec per command; thread the result.
- Do not touch `sweepStaleTeam`/peers.jsonl writers — this feature reads only.
