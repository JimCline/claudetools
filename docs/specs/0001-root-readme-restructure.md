# 0001 — Root README restructure: feature `ah` and `task-gopher`

Spec. Documentation only — one file changes (`README.md` at repo root). No
plugin code, no plugin docs, no config. Baseline: root `README.md` at 176 lines.

**Spec location note.** No repo-level `docs/specs/` existed; `docs/` held only
loose files. Created it here to mirror the per-plugin convention
(`agent-hierarchy/docs/specs/NNNN-*.md`), because this change belongs to the
repo rather than to any one plugin and there will plausibly be more of them.
Numbering restarts at 0001 — this is a different series from agent-hierarchy's.

**r2 (2026-08-31).** Three changes: `## Using superpowers?` is now **removed**,
not retained (user ruling, §4.3); inline doc links **approved** as scoped
(§4.4); and **§6's stub finding is RETRACTED — it was based on a wrong line
count of mine.** See §6. The retraction un-gates §2's trim; E1 is closed and §8
is now empty.

## [0] tldr
- [1] **The brief's premise needs one correction.** `agent-hierarchy` is not
  under-featured for lack of room — it already occupies **52 of 176 lines**, the
  largest section in the file, and sits **last**. Featuring it means *moving and
  trimming* it, not expanding it. §2.
- [2] Four plugins, from `marketplace.json` (authoritative, not assumed): `ah`,
  `task-gopher`, `output-discipline`, `comment-discipline`. §1.
- [3] **`ah` is a rename** — directory `agent-hierarchy/`, install name `ah`.
  A reader who types the directory name gets an error. Must be stated. §4.2.
- [4] Install quickstart sourced from the manifest and from the shipped
  `agent-hierarchy/docs/getting-started.md`, not invented. §4.1.
- [5] Stale `/hierarchy set` at `README.md:171` — **resolved, not a guess**:
  `commands/hierarchy.md:153` says it is superseded by `/agent-roster edit`. §5.
- [6] `## Using superpowers?` is **deleted** (r2 ruling). §4.3.
- [7] **Nothing blocks implementation.** §6's concern was mine and it was wrong;
  §8 is empty.

## [1] what is actually in this repo

From `.claude-plugin/marketplace.json` — the authoritative list. Do not
re-derive it from directory names.

| Install name | Directory | Version | Manifest description |
|---|---|---|---|
| `ah` | `./agent-hierarchy` | 0.56.0 | Multi-agent role hierarchy, each on the right model. Optional herdr transport for pane-based teams. |
| `task-gopher` | `./task-gopher` | 0.15.1 | Delegates tool-heavy work to a cheap Haiku runner. |
| `output-discipline` | `./output-discipline` | 0.1.4 | Keeps command output from flooding the context window. |
| `comment-discipline` | `./comment-discipline` | 0.3.2 | Blocks comments that only make sense next to the diff. |

Manifest carries `"renames": {"agent-hierarchy": "ah"}`. This is the only
plugin whose install name differs from its directory. §4.2.

Existing per-plugin documentation:

| Plugin | README | Other docs |
|---|---|---|
| `agent-hierarchy` | 396 lines | `CONTEXT.md` (47), `docs/getting-started.md` (**105**), `docs/mcp-tools.md` (86), `docs/troubleshooting.md` (15), `docs/comms-protocol.md` (199), `docs/hierarchy.html` |
| `task-gopher` | 479 lines | `docs/smart-gopher-spec.md` |
| `comment-discipline` | 122 lines | none |
| `output-discipline` | 78 lines | none |

## [2] the brief's premise, corrected

The brief asks that `ah` and `task-gopher` be "promoted to top/featured" with
"other plugins get a lighter mention", which implies the featured plugins need
*more* space. Measured, the current file says otherwise:

| Section | Lines | Position |
|---|---|---|
| `## Install` | 6–12 | 2nd |
| `## Why hooks, not prompts` | 13–49 (37) | 3rd |
| `## Using superpowers?` | 50–78 (29) | 4th — **deleted in r2** |
| `### output-discipline` | 81–90 (10) | 1st plugin |
| `### comment-discipline` | 91–111 (21) | 2nd plugin |
| `### task-gopher` | 112–121 (10) | 3rd plugin |
| `### agent-hierarchy` | 122–173 (**52**) | **last plugin** |

`agent-hierarchy` is already the longest section in the README — 30% of the
file — and it is last. `task-gopher`, at 10 lines, is the one genuinely
under-served.

**So the fix is position and framing, not volume.** And for `ah` specifically
the correct edit is a **trim**: 52 lines of detail in the root README, when the
plugin ships a 396-line README of its own plus five further documents, is
duplication — the same link-don't-restate problem that spec 0029 §3 addresses
one level down. A root README's job is to route, not to explain.

**Target: `ah`'s root section drops from 52 lines to roughly 15.** That is not a
demotion. Being first, with a sharp value proposition and a clear path to real
docs, features a plugin better than being last with 52 lines of detail the
reader cannot act on yet.

**This trim is unblocked (r2).** It was provisionally gated on §6's stub
concern; that concern was wrong and is retracted. `getting-started.md` is a
complete 105-line document, so the detail this trim pushes downstream genuinely
lands somewhere.

Net effect: with `## Using superpowers?` also removed (§4.3), the restructured
README should come in **well under 176 lines**. If it does not, something was
restated that should have been linked.

## [3] the link-don't-restate rule (this file's §3-equivalent)

Same discipline as `agent-hierarchy/docs/specs/0029-usage-docs.md` §3, applied
at the repo level. Homes:

| Topic | Home | Root README must NOT |
|---|---|---|
| how the six roles work, models, lanes, gates | `agent-hierarchy/README.md` | re-explain the role model or reproduce the roles table |
| ah setup walkthrough | `agent-hierarchy/docs/getting-started.md` | duplicate init/roster/spawn steps |
| ah MCP tools | `agent-hierarchy/docs/mcp-tools.md` | list tools |
| how task-gopher delegation works, dispatch rules | `task-gopher/README.md` | re-explain the runner contract |
| per-plugin behaviour and config | that plugin's own `README.md` | restate its options |
| the plugin list, versions, install names | `.claude-plugin/marketplace.json` | hand-maintain a second copy that can drift |

**Permitted:** one to three lines per plugin saying what it is and why you would
want it, then a link. That is a value proposition, not documentation.

**The test the Implementor should apply to every line written:** if this
sentence would need editing when the plugin changes, it belongs in the plugin's
own docs, not here. Version numbers, flag names, and command syntax all fail
this test. What the plugin *is for* passes it.

## [4] the restructure

### 4.1 `## Install` — marketplace + per-plugin

Sourced from the manifest and from `agent-hierarchy/docs/getting-started.md:13`,
both read directly. Not invented.

```
/plugin marketplace add JimCline/claudetools
```

Then per plugin, any subset:

```
/plugin install ah@claudetools
/plugin install task-gopher@claudetools
/plugin install output-discipline@claudetools
/plugin install comment-discipline@claudetools
```

Current `## Install` (lines 6–12) shows the marketplace line plus
`/plugin install output-discipline@claudetools` as its only example — which
silently signals that `output-discipline` is the headline plugin. Replacing the
single example with all four is most of the fix the brief is asking for.

State that the plugins are independent: install one or all, and nothing
requires the others. Worth one line — a marketplace of four related tools reads
as a bundle otherwise.

**One genuine interaction is worth naming, because it changes what a user
should install:** when `task-gopher` is present, `ah`'s Task-Runner role
delegates to it, so the two are better together than either alone. The current
README already says this at ~line 168; keep the fact, move it into the featured
section. Do not expand it into an integration guide.

### 4.2 the `ah` rename — a real trap, state it plainly

The directory is `agent-hierarchy/`; the install name is `ah`. A reader who
browses the repo, sees `agent-hierarchy/`, and types
`/plugin install agent-hierarchy@claudetools` gets an error with nothing
explaining why.

Every place the root README names this plugin must make both names visible —
heading it as **`agent-hierarchy` (installs as `ah`)** is sufficient and needs
no further prose. `agent-hierarchy/docs/getting-started.md:17` already handles
this correctly; match its wording rather than inventing new.

### 4.3 section order, and one deletion

```
# claudetools                     (keep; one-paragraph what-this-is)
## Install                        (§4.1 — marketplace + four plugins)
## The two you probably want      (ah, then task-gopher)
## Also here                      (output-discipline, comment-discipline)
## Why hooks, not prompts         (keep, unchanged, demoted below the plugins)
## License
```

**`## Using superpowers?` is DELETED (r2, user ruling).** The restructured
README targets newcomers, and a 29-line comparison against another project does
not serve a reader who does not yet know what this repo is. Delete the section
outright — do not relocate it, do not condense it into a line elsewhere. If it
is wanted later it is in git history.

Two ordering decisions, both deliberate:

- **Plugins move above the philosophy section.** `## Why hooks, not prompts`
  (37 lines) currently sits between the install block and the plugin list. The
  thesis is good and stays in the file, but a cold reader wants *what is this
  and how do I install it* first. Keep the section **textually unchanged**;
  only its position moves.
- **`ah` before `task-gopher`.** Both are featured; the list has an order
  regardless, and `ah` is the larger surface.

Heading wording is the Implementor's to set — the two above are illustrative,
not mandated. What is mandated is that the featured pair is visually separated
from the other two, so the distinction survives skimming.

### 4.4 per-plugin doc links — inline, not a table

**APPROVED as scoped (r2).** The brief originally asked for a link-out table;
inline placement was proposed as a deviation and has been accepted. Recorded
here so it is not re-litigated.

Reason it was proposed: the four plugins have very unequal doc surfaces. `ah`
has six link targets; `output-discipline` and `comment-discipline` have one
each. A uniform table gives one row six links and two rows one link —
unreadable in the wide cell, padded in the narrow ones. Inline placement also
puts the link where the reader's attention already is.

For `ah`, a short nested list under its section:

> **Docs:** [getting started](./agent-hierarchy/docs/getting-started.md) ·
> [MCP tools](./agent-hierarchy/docs/mcp-tools.md) ·
> [troubleshooting](./agent-hierarchy/docs/troubleshooting.md) ·
> [full README](./agent-hierarchy/README.md)

For the other three, a single link to their README suffices.

**Do not link `docs/comms-protocol.md` from the root README.** It is a
version-stamped 0.29.0 spec whose accuracy against current behaviour is
unassessed (0029 §9). Linking it from the repo's front door presents it as
current documentation, which is precisely what that follow-up is about. It stays
reachable from the plugin's own docs.

## [5] the stale `/hierarchy set` line — E1 resolved

`README.md:171` currently reads:

> `/hierarchy status` shows the effective table and where each value came from;
> `/hierarchy set <role> <model>` tweaks one role; `/hierarchy flow` switches
> handoff mode; `/hierarchy off` silences it.

**Resolved by reading `agent-hierarchy/commands/hierarchy.md:153–158`** — this is
0029's E1, and the answer is definite:

> `## set <role> <model>` — moved
> Superseded by `/agent-roster edit`, which operates on roster members instead
> of the legacy `roles` table.

So the third of 0029 §8/E1's three branches applies: it existed, and it is
superseded. **Fix:** replace the `/hierarchy set <role> <model>` clause with
`/agent-roster edit`. Leave the `status`, `flow`, and `off` clauses alone — they
are still current.

Do not add a migration note or explain the supersession here. A root README
lists what a command does now; the history belongs in the command's own file,
which already carries it.

**Verify, do not assume:** `agent-hierarchy/README.md:370` also matches
`/hierarchy set`, but the surrounding text appears to be the already-corrected
wording explaining the supersession. Read that line before touching it — the
brief states this one is already fixed, and re-fixing corrected prose would
reintroduce the defect.

## [6] RETRACTED (r2) — the stub finding was wrong

r1 §6 claimed `agent-hierarchy/docs/getting-started.md` was a 22-line stub
against 0029 §4.1's eight-section requirement, and flagged it as gating §2's
trim.

**That was wrong. The file is 105 lines and carries all eight sections**,
including the worked first-dispatch example and a teardown section that
correctly reflects 0029's r2 disband amendment. Verified by reading it directly.

`troubleshooting.md` at 15 lines is **conformant**: it is exactly the nine-row
symptom→cause→fix table 0029 §4.3 specified, with a title and one intro line and
no filler. r1 allowed this was possible; it is what shipped. It also resolves
0029's E3 — its last row documents that peer token usage is not captured by
`/hierarchy usage`, as a stated known limitation.

**How the error happened, recorded because the mechanism recurs.** The line
count came from a delegate's inventory report and I put it in a spec without
opening the file. The same report was correct about everything else, including
a verbatim quote from that very file — which is what made the bad number easy to
miss. Two plausible causes, and I cannot distinguish them: a miscount, or a read
that raced the Implementor still writing the file.

The rule this sits under is already written, in 0029 §11 and 0028 §12 — a
claim about an artifact needs to come from reading the artifact. What this
instance adds: **an otherwise-accurate delegate report is not a warrant for any
single fact in it**, and a fact that gates a decision is exactly the one to
verify directly. Cheap to check; I did not, and it cost a review cycle.

Consequence for this spec: **§2's trim is unblocked and §8 is empty.** Nothing
about the link-out design needs to change — the targets are real.

## [7] verification

1. **Every link resolves.** Every relative link in the restructured README
   checked against the filesystem.
2. **Install names match the manifest.** All four `/plugin install` lines
   cross-checked against `.claude-plugin/marketplace.json` `plugins[].name` —
   in particular that it reads `ah@claudetools`, never
   `agent-hierarchy@claudetools`.
3. **No version numbers in the root README.** Versions live in the manifest and
   go stale on every release. If the current file carries any, drop them.
4. **`/hierarchy set` is gone** from the root README, and no other command
   string in the file is absent from its plugin's command definition — same
   check that caught this one.
5. **Length.** Baseline 176, minus 29 deleted (`## Using superpowers?`) and
   roughly 37 trimmed from `ah`'s section. Result should land near 120 and must
   not exceed **150**. Over that, §3's rule was violated somewhere.
6. **`## Why hooks, not prompts` is byte-identical to its current text.** It
   moves; it does not get edited. A diff showing changes inside it means the
   restructure overreached.
7. **`## Using superpowers?` is absent** — deleted, not relocated or condensed.

No test-suite change. The root README has no doc-lint; adding one for a
four-plugin file is more machinery than the problem warrants.

## [8] NEEDS-EVIDENCE

**None.** r1's E1 was retracted in §6. Install commands, the plugin list, the
rename, and the `/hierarchy set` resolution were all read from source.

## [9] decisions

**Mine:**
- Spec path and the new `docs/specs/` directory (header note).
- Plugins above the philosophy section — §4.3.
- Trim `ah`'s root section 52 → ~15 rather than expand it — §2.
- Do not link `comms-protocol.md` from the root README — §4.4.

**Ruled by the user (r2):**
- `## Using superpowers?` deleted — §4.3.
- Inline doc links approved over a table — §4.4.

## [10] acceptance

- Root `README.md` leads with what the repo is, then `## Install` carrying the
  marketplace line plus all four `/plugin install` lines from the manifest.
- `ah` and `task-gopher` appear in a featured section above the other two, and
  above `## Why hooks, not prompts`.
- `ah` is presented so both its directory name and its install name `ah` are
  visible.
- `ah`'s root section is materially shorter than its current 52 lines, with
  detail replaced by links.
- Each plugin section carries a link to that plugin's own docs;
  `comms-protocol.md` is not linked from the root README.
- The `/hierarchy set <role> <model>` clause at line ~171 is replaced with
  `/agent-roster edit`; `status`/`flow`/`off` are untouched.
- `## Using superpowers?` is gone.
- `## Why hooks, not prompts` is unchanged in content.
- Total length ≤ 150 lines.
- No file other than root `README.md` is modified.

## [11] confidence

**High** on the plugin inventory, install commands, the rename, and the
`/hierarchy set` resolution — all read from the manifest, the shipped
getting-started, and the command definition, with citations in §1/§4.1/§5.

**High** on §2's reframe: it rests on the README's own heading line numbers,
which are unambiguous.

**§6 downgraded to retracted** — see §6 for what went wrong. The remaining
figures in §1's doc table were re-verified directly for the two files the
retraction touched; the others are still delegate-reported and are not load
bearing for any decision in this spec.

**Not escalating.** One file, no behaviour change, everything reversible.
