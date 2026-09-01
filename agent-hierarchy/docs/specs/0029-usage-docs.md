# 0029 — Usage documentation for the agent-hierarchy plugin

Spec. Documentation only: no behaviour change, no code change, no test change
except the one doc-lint check in §7. Baseline: plugin.json `0.56.0`.

**r2 (2026-08-31):** §4.1 step 7 corrected — its disband/disband-close gloss was
inverted and, separately, wrong about what bare `disband` does. Traced against
source this time; see the amendment note at step 7.

## [0] tldr
- [1] **Do not start from a blank page.** `README.md` (385 lines) already covers
  roles, flow, lanes, gates, usage tracking, peer-vs-subagent, message files,
  commands, layout. The gap is narrower and different from a "write the docs"
  framing.
- [2] **Structure decision: README stays the entry point.** Add three new pages
  under `docs/`, do NOT create a top-level `USAGE.md`. Rationale §2.
- [3] **The single largest real gap is the MCP surface** — ~20 tools, and the
  README mentions MCP zero times. §4.2.
- [4] **Second gap: no troubleshooting content exists anywhere in the plugin.**
  Zero matches across all non-spec `.md`. §4.3.
- [5] **README contains at least one documented-but-apparently-absent command**
  (`/hierarchy set`) and a stale `## Layout` block. These are doc *defects*, not
  gaps — §5, and one is a **NEEDS-EVIDENCE** item (§8/E1).
- [6] **Hard rule for the Implementor: link, do not restate.** §3. The brief
  explicitly asks that already-spec'd internals not be re-documented; §3 is how
  that is enforced, and §7's lint is how it is checked.
- [7] One follow-up logged, deliberately out of scope for this pass: §9.

## [1] current state — what already exists

Verified by directory listing and grep on 2026-08-31. Line counts are `wc -l`.

| File | Lines | What it already covers | Audience |
|---|---|---|---|
| `README.md` | 385 | roles+models table, prerequisites, flow, lanes, flow control, escalation gate, usage tracking, peer-vs-subagent dispatch, message-file/roster/tier summary, commands, layout, license | user |
| `CONTEXT.md` | 47 | glossary: Roster, Roster level, Whole-level replace, Route, Auto-mode, Orchestrator, Team, Check-in registry, Disband | both |
| `docs/comms-protocol.md` | 199 | message-file format, `msg.mjs` CLI, dispatch/response gates, peer roster, routing preference, tier rule | contributor |
| `docs/hierarchy.html` | 16.7KB | static visual map of roles/lanes/flow | user |
| `skills/agent-roster/SKILL.md` | 620 | roster levels, resolution, the interactive roster surface, **the disband contract** | user |
| `docs/specs/0001`–`0028` | ~28 files | per-feature design records | contributor |
| `docs/adr/0001`, `0002` | 3 each | two ADR stubs (effectively empty) | contributor |
| `docs/retired/` | 3 files | removed features, kept for history | contributor |

Two facts about this table drive the whole spec:

- **The README is not thin.** At 21KB it is already at the upper edge of what a
  README is read as. Absorbing install + ~20 MCP tools + troubleshooting inline
  would roughly double it and make the overview unusable as an overview.
- **`docs/comms-protocol.md` is a version-stamped spec, not a user doc.** Its
  title line reads `agent-hierarchy 0.29.0 — ...` and its body is written in
  spec voice (`## [0] tldr`, "Bump plugin.json AND root marketplace.json").
  Plugin is now `0.56.0`. It is being used as documentation while presenting as
  a historical spec. §5.4, and the follow-up in §9.

## [2] structure decision — README + three docs/ pages

**Decision: extend `README.md` (trim + add a doc map) and add exactly three new
files under `docs/`. Do not create a top-level `USAGE.md`.**

New files:

| Path | Purpose | Audience |
|---|---|---|
| `docs/getting-started.md` | zero → running team, task-ordered | user (a) |
| `docs/mcp-tools.md` | the MCP tool surface + `msg.mjs` CLI reference | user (a) |
| `docs/troubleshooting.md` | symptom → cause → fix | user (a) |

Contributors (audience (b)) get **no new prose file** — see §4.4.

**Why not a top-level `USAGE.md`:** it would compete with `README.md` for the
"start here" role, and neither would win. A reader landing on the repo sees the
README first regardless of what we intend; a second general-purpose entry point
guarantees the two drift and that half the audience reads the stale one. The
README already *is* the overview — the missing thing is depth beneath it, not a
rival to it.

**Why not fold everything into the README:** stated in §1 — size. Also, the
three new pages have genuinely different read-triggers: getting-started is read
once, mcp-tools is read as reference, troubleshooting is read under duress. One
file cannot be organized for all three.

**Why `docs/` and not `docs/usage/`:** `docs/` currently holds 3 loose files and
3 subdirectories. Three more loose files is fine; a subdirectory for three files
adds a path segment and buys nothing.

## [3] the single-source rule — READ THIS BEFORE WRITING ANY PAGE

This is the constraint the brief cares most about ("don't have Implementor
re-document internals already spec'd"). It is a hard rule, not a preference.

**Every fact in this repo has exactly one home. New pages link to the home; they
never restate it.**

| Topic | Home — link here | New pages must NOT |
|---|---|---|
| role → model table, what each role does/never does | `README.md` | re-list the six roles with their models |
| roster levels + resolution (`repo-user` > `repo` > `global`, whole-level replace) | `skills/agent-roster/SKILL.md` §Levels | restate the precedence table |
| **the disband four-call contract** | `skills/agent-roster/SKILL.md` §`disband` | reproduce the plan→confirm→close→commit steps |
| message-file format, frontmatter keys, `## [N] key` anchors, the gates | `docs/comms-protocol.md` | restate the frontmatter key list or the id format |
| terminology (Roster, Team, Route, Auto-mode, Check-in registry, …) | `CONTEXT.md` | redefine any term defined there |
| per-feature design rationale | `docs/specs/NNNN-*.md` | restate design reasoning |

**Permitted duplication, and only this:** a one-line orienting gloss immediately
followed by a link. Example of the allowed shape:

> Roles are dispatched either as a **peer** (separate live session) or a
> **subagent** (in-process). Set per member — see
> [SKILL.md](../skills/agent-roster/SKILL.md).

Example of what is forbidden — restating the table:

> ~~Route may be `peer` or `subagent`. Peer means a separate live Claude Code
> session reached via SendMessage. Subagent means spawned in-process via the
> Agent tool. It is set team-wide at roster init and overridable per member.~~

That paragraph is already in `CONTEXT.md` verbatim. Copying it creates a second
copy that nothing reconciles, which is exactly the failure this rule exists to
prevent.

**Corollary for the Implementor:** if writing a section requires you to explain
a mechanism from scratch, stop — either the mechanism has a home you should be
linking to, or it has no home and that is a finding to report, not a licence to
invent a second one.

## [4] page-by-page outline

### 4.1 `docs/getting-started.md` — the task-ordered path

Target length: **under 150 lines.** This page's failure mode is becoming a
second README; the length cap is the guard.

Sections, in this order:

1. **Prerequisites** — one line + link to `README.md#prerequisites`. Node only;
   `herdr` optional. Do not restate the fallback chain.
2. **Install** — how the plugin is actually installed from the marketplace.
   **NEEDS-EVIDENCE E2** — do not invent this; see §8.
3. **`/hierarchy init`** — what the wizard asks, what it writes, and *where*
   (the three config levels — gloss + link, per §3). State the one thing a new
   user always gets wrong: init sets up the hierarchy; it does **not** define
   the roster. That is `/agent-roster`.
4. **Defining a roster** — `/agent-roster init`, then `add`. Name the four
   per-member keys (`model`, `effort`, `route`, `auto_mode`) with a one-line
   gloss each, then link to SKILL.md rather than documenting their value spaces.
5. **Spawning a team** — `/agent-roster create`. What a Team is vs a Roster (one
   line, link `CONTEXT.md`). What "auto" vs "manual" changes.
6. **The first dispatch** — a worked example: Orchestrator dispatches the
   Architect, Architect writes a spec, Implementor builds it. This is the
   section that makes the model *click*; give it the most room. Show the
   `[hierarchy-msg <path>]` pointer in context, since a user will see it in
   their terminal and otherwise have no idea what it is.

7. **Tearing down** — `/agent-roster disband`.

   > **r2 AMENDMENT.** r1 said "the distinction between disband (registry) and
   > disband-close (kills sessions)". That was wrong in two ways, and the
   > Implementor wrote `getting-started.md` from it (Reviewer finding B1).
   > Recorded rather than silently replaced, because the *shape* of the error
   > matters more than the error: I described a user-facing command using a
   > fact that was true of an internal MCP tool. Traced this time —
   > `roster.mjs:1416,1429`, `SKILL.md` §`disband`.

   What is actually true, and what the page must convey:

   - **Bare `disband` writes nothing.** It is read-only: it emits a close plan
     plus a `close_token` (`roster.mjs:1429`, "the new default", spec 0006 §5.1).
     It does not remove the registry and it does not close a session. r1's gloss
     had it removing the registry; it does not.
   - It is the **first step of a four-call contract** — plan → confirm with the
     user → `roster_disband_close` → `disband --commit`. Only
     `roster_disband_close` ever closes a live session, and it carries its own
     unconditional harness prompt.
   - **`disband --keep-sessions` is the single-call safe form**: removes
     `team.json`, closes nothing (`roster.mjs:1416`).

   **Do not reproduce the contract on this page** — §3 now lists it with
   `SKILL.md` §`disband` as its home. One-line gloss plus a link.

   The two facts a getting-started reader actually needs:
   1. Bare `disband` is safe — it shows you what *would* close and waits.
   2. `--keep-sessions` is what you want when those sessions hold work worth
      keeping. SKILL.md's own rationale is that sessions "may hold work that
      already cost tokens" — that is the user-facing reason, and it is worth
      stating rather than leaving as a flag name.

   **Name the ordering hazard explicitly:** never run `--commit` before the
   close has run. `--commit` removes `team.json`, which is what identifies the
   members — doing it first orphans live sessions with nothing left pointing at
   them. This is the one destructive mistake the page can actually prevent, so
   it earns its line.

8. **Where to go next** — links to the other two new pages and to the README.

### 4.2 `docs/mcp-tools.md` — the largest genuine gap

`README.md` mentions MCP **zero times** (grep for `mcp|roster_show|msg_new|
roster_create` → no matches). The MCP server shipped in spec 0013 and has grown
through 0016, 0017, 0018, 0019, 0020, 0024. `plugin.json` registers it as server
name `ah`, so tools are addressed `mcp__ah__<tool>`.

Content:

1. **What the MCP server is and when it is used instead of the CLI.** The
   important user-facing point: MCP tools are the *preferred read path* (SKILL.md
   already says "preferably via `mcp__ah__roster_show` for reads"), while
   `roster.mjs`/`msg.mjs` remain the underlying implementation. A user does not
   choose between them arbitrarily — the MCP tool is the one to reach for, and
   the CLI is the fallback when MCP is unavailable.
2. **Tool table**, grouped as `msg_*` and `roster_*`, with one line each:
   name, what it does, and **whether it mutates**. The mutation column matters —
   `roster_disband_close` and `roster_dismiss_close` are destructive and their
   own descriptions say they require prior user confirmation. Mark them.
   **Watch the naming trap here:** `roster_disband`'s description reads
   "Non-destructive modes only — never closes anything", which is true *of the
   tool* and misleading about the *command* `/agent-roster disband`. This is the
   exact confusion that produced the r2 amendment in §4.1 step 7. When the table
   describes a tool, say so — do not let a tool's semantics be read as the
   command's.
3. **The `msg.mjs` CLI**, for the same surface without MCP. Its `--help` lists
   `new|list|downstream|index|sweep|roster|route|global-scope`. **Three of those
   (`sweep`, `route`, `global-scope`) are not described in the help output** —
   document what they do, or state plainly that they are internal. Do not guess:
   read the source, and if a subcommand's purpose is not determinable from it,
   list it as undocumented rather than inventing a description.
4. **A pointer**, not a copy, to `docs/comms-protocol.md` for the message
   protocol the `msg_*` tools implement.

**Enumerate the tool list from `mcp/server.mjs` at implementation time.** Do not
trust any count quoted in this spec or in a report — the inventory this spec was
written from produced a self-inconsistent count (said 18, listed 20). The source
is authoritative; the list must be complete, and it must be generated by reading
the file, not by copying from here.

### 4.3 `docs/troubleshooting.md` — currently zero coverage

Nothing in the plugin outside `docs/specs/` matches `troubleshoot|FAQ|not
working|stale roster|peer offline` or similar. This page is entirely new.

Format: **symptom → likely cause → what to run.** Not prose. A reader here is
already frustrated; make it scannable.

Minimum entries — each traceable to a real, already-documented failure:

| Symptom | Where the answer comes from |
|---|---|
| MCP tools missing / server won't connect after a plugin update | spec `0024-mcp-connect-failure-after-update.md` |
| Peer is offline / dispatch says no live peer | `peers.jsonl`, `kill(pid,0)` liveness, `/hierarchy peers`, `roster_spawn_one` |
| Roster looks stale or wrong members appear | whole-level replace — a higher level is winning entirely; `roster_show --level`, `roster_resync` |
| Team orphaned after the orchestrator session died | `roster_adopt` (recovery only; refuses to hijack a live team) |
| `team.json` gone but sessions still running | `--commit` ran before the close — see §4.1 step 7's ordering hazard; close the panes by hand |
| Two checkouts / worktree see different rosters | spec `0027-worktree-roster-resolution.md`; `AGENT_HIERARCHY_DIR` |
| Peers in different repos share no messages | README already names this as a cross-repo limitation — link it, point at `AGENT_HIERARCHY_DIR` |
| A dispatch is denied for a missing `[hierarchy-msg]` pointer | `docs/comms-protocol.md` §5/§6 |
| Tier gate denies a dispatch | tier rule; the `reason:` escape (`context`, `second-opinion`, `parallel`) |
| Usage report shows nothing | usage tracking is SubagentStop-driven — peers are not subagents |

The last row is a **NEEDS-EVIDENCE** item, E3 — I have not traced whether peer
token usage is captured. Do not assert either way without checking; if
unresolved, write the row as a known limitation with the uncertainty stated.

### 4.4 contributors (audience (b)) — no new prose file

The brief asks for contributor-facing mechanics: message files, dispatch
protocol, roster.jsonl, peer resolution. **These are already written**, in
`docs/comms-protocol.md` and across 28 specs. Writing a contributor guide would
be a second copy of `comms-protocol.md` — precisely what §3 forbids.

Instead: **add a short "Internals" section to `README.md`** (see §6) that is a
map into the existing material — comms-protocol for the wire format, CONTEXT.md
for vocabulary, `docs/specs/` for per-feature rationale, with three or four
specs called out by name as the high-value entry points (0001 roster, 0013 MCP
server, 0026 route gate, 0028 conduit/liveness).

**If the Implementor finds that `comms-protocol.md` no longer describes shipped
behaviour, that is a finding to report — not a rewrite to undertake.** It is a
0.29.0 document and the plugin is 0.56.0; assessing its accuracy is a separate
task with its own spec, and folding it into a docs pass would hide a
behaviour-drift question inside a documentation commit. Ruled on — §9.

## [5] defects found while scoping — fix, flag, or escalate

These were found while inventorying and are **not** part of "write the docs".
They are listed because shipping new docs alongside known-wrong old docs is
worse than either alone.

### 5.1 `README.md` `## Commands` documents `/hierarchy set` — NEEDS-EVIDENCE E1

README (line ~336) lists:

```
/hierarchy set <role> <model>       # one role (validated per-role)
```

But `commands/hierarchy.md`'s own description says *"Model/roster assignment
lives in /agent-roster"*, and its argument-hint is
`[init|status|on|off|flow|gate|usage|msgs|peers|sweep]` — **no `set`**.

Either the command was moved to `/agent-roster` and the README was not updated,
or `set` still exists and is undocumented in its own command file. **I cannot
run anything to determine which.** See §8/E1. Do not "fix" the README until it
is known which side is wrong — the two possible fixes are opposite edits.

### 5.2 `README.md` `## Commands` omits `/agent-roster` entirely

The Commands block lists only `/hierarchy` subcommands. `/agent-roster` — which
owns roster definition, `create`, and `disband`, and is where a user spends most
of their setup time — does not appear. This is a straightforward omission; add
it. Its argument-hint is
`[show|init|add|edit|remove|layout|create [auto|manual]|disband]`.

### 5.3 `README.md` `## Layout` is stale

The Layout block lists ~20 files under `hooks/`. The directory currently holds
26 `.mjs` files plus `hooks.json`. Absent from the block, among others:
`pretooluse-conduit-gate.mjs`, `stop-orchestrator-liveness.mjs`,
`pretooluse-disband-close-gate.mjs`, `lib-roster.mjs`, `lib-session-role.mjs`,
`lib-usage.mjs`, `roster.mjs`. The `mcp/` directory does not appear at all, nor
does `skills/`.

**Recommendation: do not re-enumerate it.** A hand-maintained file listing in a
README is a guaranteed staleness source — it has already drifted once. Replace
the per-file list with a short directory-level map (`hooks/` — hooks and their
libraries; `mcp/` — the MCP server; `agents/`, `commands/`, `skills/`,
`docs/specs/`, `tests/`) and let the filesystem be the file list. This is a
deletion, and it is the point: the block's value was never worth its upkeep.

### 5.4 `docs/comms-protocol.md` presents as current but is version-stamped 0.29.0

Add a status line at the top marking what it is and what version it describes,
so a reader knows whether to trust it against 0.56.0 behaviour. **Header only —
do not revise the body.** See §9 for the ruling and the exact header content.

### 5.5 README's "Verified payloads" paragraph is pinned to a Claude Code version

It states findings probed against *Claude Code v2.1.233*, including that the
tier gate is inert because no `model` field is present. Version-pinned empirical
claims silently rot. Keep the paragraph — it is genuinely useful — but mark it
as "verified against v2.1.233, not re-verified since". Re-verifying is out of
scope for a docs task.

## [6] `README.md` — the edits, and only these

1. Add a **doc map** near the top (just after the roles table / visual-map line):
   four links — getting-started, mcp-tools, troubleshooting, comms-protocol —
   each with a half-line of what it is for.
2. Add `/agent-roster` to `## Commands` (§5.2).
3. `/hierarchy set` line — **hold pending E1** (§5.1).
4. Replace `## Layout`'s file listing with a directory-level map (§5.3).
5. Add a short **Internals** section for contributors (§4.4).
6. Add the staleness marker to the Verified-payloads paragraph (§5.5).

**Do not restructure the README beyond this.** Its existing sections are
accurate and well-organized; this is additive plus two targeted corrections. A
docs pass that rewrites working prose produces a diff nobody can review.

## [7] verification

Documentation cannot be verified by a test suite, so verification is mechanical
and narrow. The Implementor must:

1. **Every link resolves.** Check every relative link in the new and edited
   files against the filesystem. Broken relative links are the single most
   common defect in a docs commit and the cheapest to catch.
2. **Every command string is real.** For each command or tool name written in
   any new page, confirm it exists in `commands/`, `mcp/server.mjs`, or the
   relevant CLI's argument parsing. Report any that do not resolve rather than
   removing them silently — a documented-but-absent command is the §5.1 defect
   class and is worth surfacing, not burying.
3. **MCP tool list is complete.** Cross-check `docs/mcp-tools.md` against every
   tool registered in `mcp/server.mjs`. Both directions: no tool missing from
   the doc, no tool in the doc that is not registered.
4. **§3 spot-check.** For each new page, confirm no section restates a table or
   definition whose home is elsewhere per §3's table.
5. **Destructive-semantics check (added r2).** For every statement in the new
   docs about what a command or flag *destroys, closes, or removes*, cite the
   line in `roster.mjs`/`msg.mjs` it came from. This spec got exactly such a
   statement backwards, and it reached shipped docs. Prose about destructive
   behaviour is the class where being wrong costs the reader most, so it is the
   class that gets traced rather than paraphrased.

Add **one** check to the test suite: a doc-lint that fails if any relative link
in `README.md` or `docs/*.md` (excluding `docs/specs/`, `docs/retired/`) points
at a path that does not exist. Nothing more — this is a docs change, and a test
suite that asserts prose content will be wrong within a release.

## [8] NEEDS-EVIDENCE

Design decisions in this spec that depend on facts I could not establish by
reading. **I did not run anything; these go to the Orchestrator to route.**

**E1 — does `/hierarchy set <role> <model>` exist?** (blocks §5.1, §6.3)
Run: `grep -n 'set' commands/hierarchy.md` and grep the hooks for a `set`
subcommand handler (`lib-config.mjs`, `gate.mjs`).
- If `set` exists and works → README is right; fix `commands/hierarchy.md`'s
  argument-hint instead.
- If it does not → remove the line from README and point at `/agent-roster`.
- If it exists but is deprecated in favour of `/agent-roster` → README says so
  explicitly rather than listing it as current.

**E2 — what is the actual install procedure?** (blocks §4.1 step 2)
The plugin lives in a marketplace (`marketplace.json` at repo root, per the
version-bump convention). Determine the exact user-facing install steps —
marketplace add + plugin install, or whatever the real sequence is.
**Do not write install instructions from assumption.** An install section that
is wrong is worse than absent: it fails the reader at step one, which is the
step where they have the least context to recover.

**E3 — is peer token usage captured in `/hierarchy usage`?** (blocks §4.3's last
row)
Usage collection is `subagentstop-usage.mjs` — a SubagentStop hook. A peer is a
separate session, not a subagent, so it plausibly never fires. Confirm by
reading `lib-usage.mjs` and `subagentstop-usage.mjs`.
- If peers are not counted → document it as a known limitation. Users comparing
  a usage report against their actual bill need to know what it omits.
- If they are counted by another path → document that path.

## [9] logged follow-up — NOT this pass

**FOLLOW-UP: `docs/comms-protocol.md` body may be stale post-0026/0028.**

The document describes 0.29.0; the plugin is 0.56.0, i.e. ~27 minor versions of
drift, and at least two intervening specs (0026 route gate, 0028 conduit and
liveness) changed gates it documents. Its accuracy against shipped behaviour is
**unassessed** — not "believed accurate", not "believed stale". Nobody has
checked.

**Ruled (Orchestrator, 2026-08-31): out of scope for this pass. Do not assess it
now.** Folding an accuracy audit into a docs commit would hide a behaviour-drift
question inside unrelated work — the audit's findings would land in a diff
reviewed as documentation, where a reviewer is not looking for behaviour
regressions. It needs its own spec and its own review.

**What this pass does instead:** §5.4's status header, whose job is to stop a
reader trusting the document silently. The header must say all three of:
what the document is (a spec, not a maintained user doc), which version it
describes (0.29.0), and that its accuracy against current behaviour is
unverified. A header that gives only the version implies someone checked the
rest; that is the failure mode to avoid.

**Trigger for picking this up:** anyone changing the message protocol, the
dispatch gate, or the response gate should either re-verify this document or
widen their own spec to supersede it. Whoever does it inherits the question of
whether comms-protocol.md should remain a frozen 0.29.0 spec (with a current
user-facing doc written beside it) or be maintained as living documentation —
that is the real fork, and it should be decided deliberately rather than by
whoever edits it next.

## [10] acceptance

- `docs/getting-started.md`, `docs/mcp-tools.md`, `docs/troubleshooting.md`
  exist, each covering §4's outline for its page.
- **`getting-started.md`'s teardown section matches §4.1 step 7 as amended in
  r2** — bare `disband` described as read-only, `--keep-sessions` as the
  single-call safe form, the `--commit`-before-close hazard named, and the
  four-call contract linked rather than reproduced.
- `README.md` has the doc map, `/agent-roster` in Commands, a directory-level
  Layout map, an Internals section, and the Verified-payloads staleness marker.
- `docs/comms-protocol.md` has a status/version header carrying all three facts
  named in §9; **its body is unchanged**.
- Every MCP tool in `mcp/server.mjs` appears in `docs/mcp-tools.md`, and every
  tool named there is registered.
- Every relative link in the new/edited files resolves; the §7 doc-lint check
  is in the suite and passes.
- **No new file restates a table or definition whose home is §3's table.**
- E1/E2/E3 either resolved and reflected, or explicitly written as open
  limitations in the docs.
- No behaviour change: no `.mjs` under `hooks/` or `mcp/` is modified.

## [11] confidence

**High** on structure (§2) and on the gap analysis (§4.2, §4.3) — both rest on
directory listings and greps with unambiguous results, and the MCP gap in
particular is a zero-match grep, not a judgment call.

**Medium** on §5's defect list: I found these by reading the README against the
command files, not by executing anything, which is exactly why E1 exists rather
than a fix. §5.1's two possible resolutions are opposite edits, and picking one
from inference is how a doc gets confidently wrong.

**Downgraded on §4's behavioural glosses (r2).** Step 7 shipped inverted and
reached user-facing docs before the Reviewer caught it. The cause was not
carelessness about disband specifically — it was describing a *command* from a
report about an internal *tool* whose semantics genuinely differ. §7.5 now
requires a citation for any destructive-behaviour claim, which is the check that
would have caught it. Treat every remaining unattributed behavioural gloss in §4
as unverified.

**Not escalating.** Nothing here is hard to reverse and no decision has outsized
blast radius — this is a documentation task with a genuine but bounded scoping
question (§9), now ruled on.
