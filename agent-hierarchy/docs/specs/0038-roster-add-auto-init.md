# 0038 — `roster add` auto-creates a minimal roster

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Origin: same user report as 0037, **different root cause** — a loud feature gap,
not silent misdelivery. Split per 0033 §9's grounds.
Files: `agent-hierarchy/hooks/roster.mjs` (`add` fail path ~:1076-1082,
`readLevelFile` ~:183-191, `init`'s writer),
`agent-hierarchy/skills/agent-roster/SKILL.md`,
`agent-hierarchy/tests/test-roster-add-autoinit.sh` (new)

**Requirement (settled by the user — not an option to weigh):**
`roster add <role>` with zero existing roster MUST succeed by creating a
minimal roster containing just that role. It must never error with
"run init first".

Current behaviour (probed on a scratch repo, no config): exit=2,
`no roster resolves at any level — run \`roster.mjs init\` first`
(fail path roster.mjs:1076-1082; missing file reads as a `{version}` stub via
`readLevelFile` :183-191).

## 1. Design

### 1.1 Bare `add <role>`, nothing exists anywhere

Auto-create the minimal structure at the **default target level** and proceed
with the normal add. The default level is whatever `add` already resolves to
when a file exists (0032's `targetLevel` default = repo level when cwd is in a
repo); this spec adds no new level-selection logic — when nothing resolves, use
the same default `targetLevel` would have picked, honouring an explicit
`--level` if given.

*(Ruled at landing.)* Default when nothing resolves: **repo level when
`findGitRoot(cwd)` succeeds.** With **no git root and no explicit `--level`**,
`add` keeps failing — auto-creating the user-wide `~/.claude/agent-hierarchy.json`
(level `global`) as a side effect of a bare `add` in some random non-repo
directory is a global write from a local-looking command, and non-repo cwd is
already the degenerate zone (0037's vector c). The escape is explicit:
`add <role> --level global` auto-creates there. The no-git-root error message
must say so — name `--level global` as the option, the same
remedy-in-the-error pattern as 0037 §2.2.

**One writer.** The auto-created structure MUST be produced by the same
serialization path `init` uses (extract/reuse the function — do not hand-roll a
second literal). Minimal = init's non-interactive stub (version + empty
containers, whatever init writes before role selection) plus the one role row
`add` was invoked with. A second serializer is the duplicate-representation
failure family (0035 §11); the test suite pins this structurally (T5).

Output: the normal `add` success output, plus one line stating that the roster
file was created and where (absolute path). Creation of a file that didn't
exist should never be silent.

### 1.2 `--team <X>` — 0032's ruling stands

`add --team X` where `rosters.X` does not exist **still errors**, exactly per
0032 §3.4b. Its anti-typo rationale (a typo'd team name creates config that is
never selected and never errors) is unchanged by this spec.

Interaction rule when NOTHING exists at all: `add --team X` errors (no
container, no team) — auto-init does not extend to explicitly-named teams.
**Flag for the user:** this is an asymmetry (bare add bootstraps; team add does
not). It preserves a ruling the user was party to in 0032; reversing it is a
one-line change but a deliberate one — say the word and it becomes a follow-up.

### 1.3 Contradictory flags still error

Keep the error for anything contradictory or unresolvable that isn't the
plain missing-file case: `--level` naming a level whose parent directory cannot
be written, `--team` per §1.2, or an unknown role name (whatever validation
`add` already does — unchanged).

`--level global` (or user-level) auto-creation: allowed IFF adding at that
level is already allowed today under the same flags/guards (e.g. any
allow-global gate that exists applies identically — auto-init changes *whether
a file must pre-exist*, never *where writes are permitted*).

## 2. What must not change

- `init` — untouched behaviourally; only its writer may be extracted for reuse.
- `add` against an existing roster — byte-identical behaviour (regression tests
  in the existing suites must stay green).
- Level-resolution order, `--level`/`--team` semantics, role validation.
- 0032 §3.4b's team-must-exist rule (§1.2).

## 3. Docs

`skills/agent-roster/SKILL.md` add-section: one line — `add` auto-creates a
minimal roster when none exists; `init` is for choosing a full role set
interactively, not a prerequisite.

## 4. Tests

`agent-hierarchy/tests/test-roster-add-autoinit.sh` (HOME-redirect + scratch
repo pattern per existing suites).

| # | Scenario | Assert |
|---|---|---|
| T1 | Scratch repo, no config anywhere; `add reviewer` | Exit 0; roster file exists at repo level; contains exactly the reviewer role; creation notice line printed. **Expected to FAIL pre-fix (exit=2)** — the falsifying core |
| T2 | Same but `--level global` (spec draft said `user`; `ROSTER_LEVELS` is `repo-user | repo | global` — the user-wide file `~/.claude/agent-hierarchy.json` is level `global`) | File created at global level, not repo |
| T3 | No config; `add reviewer --team X` | Exit non-zero, 0032 §3.4b error — auto-init must NOT extend to named teams |
| T4 | Roster already exists; `add implementor` | Behaviour byte-identical to today (no creation notice, normal append) |
| T5 | Structural: the auto-init path calls init's shared writer | Grep-level assertion that `add`'s creation path routes through the same function `init` uses — no second serialization of the roster shape |
| T6 | Second `add` after a T1 auto-init | Appends to the created file; does not re-create or clobber |
| T7 | Bare `add`, no git root, no roster anywhere (§1.1 ruling) | Exit non-zero; error names `--level global`; nothing created at global level. Seen failing against the message reverted to "run init" (25/25 on the real tree) |

Mutation standard: T1 and T3 seen failing (T1 against the unmodified tree; T3
against a deliberately over-eager implementation that auto-vivifies teams).

**Status (landed):** 22/22 pass (T3 has a second half, T3b: default roster
present but no `rosters.X` — still refused, nothing auto-vivified). Mutations
run: unmodified tree (`git show HEAD:hooks/roster.mjs`) fails T1, T2, T4, T5,
T6 and T3b (14 assertions); replacing `add`'s team-scoped `fail(...)` with the
auto-init writer fails exactly T3b's two assertions. T3's no-config half
passes on both mutants — with no file anywhere, HEAD's `targetLevel` fails
first regardless, so the team-scoped refusal is only falsified by T3b.

Auto-created container carries `route: "peer"` unless `add --route` is given
— `validateRosterBlock` requires a route and the plugin has no roster-level
default; `peer` is the superset behaviour (live peer, else subagent). Not in
the spec draft; flagged for the Architect. **Ruled: `peer` confirmed** — the
superset degrades gracefully and `--route` overrides; `subagent` as default
would silently withhold peer routing from a bootstrap user who never learns
the flag exists.

## 5. NEEDS-EVIDENCE

1. Confirm `targetLevel`'s actual default when **no** file resolves at any
   level (spec assumes repo-level when cwd is in a repo; the current code may
   short-circuit to the error before choosing). ~~If the default is genuinely
   undefined in that state, the rule is: repo level when `findGitRoot(cwd)`
   succeeds, else user level~~ *(Superseded at landing: "user" is not a level —
   valid levels are `repo-user | repo | global` — and the no-git-root fallback
   is ruled OUT; see §1.1's ruling. Repo level when `findGitRoot(cwd)`
   succeeds; otherwise error naming `--level global`.)*
2. Confirm init's writer is extractable without behaviour change (it may be
   inline with the interactive flow); if extraction is invasive, report back
   rather than duplicating the literal.

**Resolved at landing:**

1. Confirmed: HEAD's `targetLevel` failed `run roster.mjs init first` before
   choosing any level — the default was genuinely undefined. Implemented as
   repo level when `findGitRoot(cwd)` succeeds. The "else user level" half is
   **not** implemented: with no git root and no roster anywhere, `add` still
   fails with the pre-existing message. The spec names a `user` level that
   does not exist (see T2), and silently creating `~/.claude/agent-hierarchy.json`
   from a bare `add` outside any repo is a user-wide side effect the Architect
   should confirm before it lands.
2. Confirmed extractable without behaviour change: init's block construction
   was a plain literal, now `freshRosterBlock(route, layout)` +
   `installRosterBlock(data, teamKey, block)`; `init` and `add` both call them
   and the `{ route, members: [] }` literal appears once (T5 asserts this).

*(Pointer, added post-landing:)* `add`'s ending is changed by 0039
(`0039-roster-add-spawns-peer.md`): a successful `add` now also spawns the
live peer when the member's route is `peer`. This spec's auto-init behaviour
is unchanged; only what happens after the write.

## 6. Out of scope

- Team auto-vivification (§1.2 — flagged, awaiting user word if wanted).
- Any change to init's interactive flow.
- 0037 (messaging) — separate spec, separate mechanism.
