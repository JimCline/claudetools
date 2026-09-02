# Spec 0002 — `review-guide` plugin

Status: **r6** · Author: Architect · Source rulings: `20260901-123156-1ms9`,
`20260901-213034-1a0g`, `20260901-223748-ts1t` (see §11.1 for provenance)

**Revision log**

- **r2** — the 1a0g ruling response, absent at r1, was reconstructed to disk and read in
  full. Retracted r1's `{path, blob}` "correction"; adopted the ruling's `--skip` kind.
- **r3** — user overturn of the note-content rule (`ala6`): a note carries **both**
  narration and scrutiny flags, in two fields. Reasoning in §5.1b.
- **r4** — the `PreToolUse` gate deleted, and with it the plugin's last hook (`bioz`).
  Zero hooks. Rationale corrected mid-revision to the technical argument in §6a.
- **r5** — Ultra-Advisor pre-implementation review (`rh02`). **A** — base resolution was
  broken for the commonest case and pinned the wrong answer permanently; **B** — §3.1's
  rationale was factually wrong (conclusion survived, reason did not); **C** — `--pr`
  prints the `edit` form too.
- **r6** — Implementor question (`1kcf`): the deleted-file record shape was left implicit.
  Their reading is **confirmed** and is now written down. §3.3a. No behaviour change; this
  documents what was already built.

## [0] tldr

- New sibling plugin `review-guide/`. **Pure tooling: a ledger, a CLI, and a skill.**
  Nothing is enforced, nothing is blocked, nothing runs on its own.
- Append-only JSONL ledger, one file per branch, in the **git common dir** (§3.1).
  Records carry per-file **blob hashes** so drift is git-derived.
- `guide.mjs note` captures at per-turn-of-work grain: **narration plus zero or more
  scrutiny flags** (§5.1). `guide.mjs guide` compiles markdown, mechanically.
- **What stops this being skipped: nothing** (§6). Not an oversight and not taste — the
  gate designed for it could not do the job it appeared to do (§6a).
- **Operational rule:** run `guide`/`status` with cwd inside the checkout of the branch
  being compiled. §3.1.

---

## [1] Goal

Give a PR reviewer — human or LLM — a roadmap through the diff: an explanation of what was
done and why, written *while* the changes were made, when the knowledge existed, plus
flags for what deserves scrutiny.

## [2] What must NOT change

- No changes to `agent-hierarchy/` code. Do **not** add `msg.mjs guide`. Do **not** add a
  `## [6] reviewer_notes` msg section (§8).
- No new MCP server. No new agent. No new role.
- **No hooks.** See §7.
- Existing plugins' versions untouched except the marketplace entry addition (§9).

---

## [3] Store

### 3.1 Location — `<git-common-dir>/review-guide/`

Resolve with:

```
git rev-parse --git-common-dir
```

**Correction to the ruling.** 1a0g §[1].1 specifies
`$(git rev-parse --git-dir)/review-guide/<branch>.jsonl`. In a linked worktree
`--git-dir` returns that worktree's *private* directory (`<common>/worktrees/<name>`), so
the ledger would live inside a transient worktree and be destroyed by
`git worktree remove`. `--git-common-dir` belongs to the repository and outlives any
worktree.

> **r5 — Fix B: the conclusion stands, my reason for it did not.** r1–r4 justified
> `--git-common-dir` by claiming a worktree-routed Implementor and a main-checkout
> Orchestrator must "share one ledger", and called that a prerequisite for the hierarchy
> fold. **That is wrong.** The ledger is keyed by branch (§3.2), and git forbids the same
> branch being checked out in two worktrees simultaneously — so two live checkouts are on
> different branches and read *different* ledger files by construction. Sharing was never
> the mechanism, and no amount of path resolution creates it.

**The operational rule that replaces the sharing claim.** Both the ledger key and the
changed set (§4.1) are read from the **current checkout**. So:

> Run `guide` and `status` with cwd inside the checkout of the branch being compiled.

Compiling `feat-x`'s guide from a checkout sitting on `main` does not error — it reads
`main.jsonl`, diffs `main`'s tree, and silently emits the wrong document. That is the
failure mode worth a test (§10.2 #2) and a line in SKILL.md (§10.1 §8).

`--git-common-dir` may return a **relative** path (typically `.git`). Resolve it against
the repo root (`git rev-parse --show-toplevel`), never against `process.cwd()`.

Not committed, not in any diff, gone on a fresh clone. Intended: the ledger is scratch, the
guide is the artifact.

### 3.2 Ledger file — `<store>/<branchkey>.jsonl`

`branchkey` = current branch from `git symbolic-ref --short HEAD`, with every character
outside `[A-Za-z0-9._-]` replaced by `-`. So `feat/x` → `feat-x`. Flat file, no nested
dirs.

Detached HEAD (`symbolic-ref` exits non-zero): `branchkey` = `detached`. Do not use the
SHA — it changes every commit and would scatter the ledger.

Collision (`feat/x` and `feat-x` share a ledger) is accepted: consequence is a merged
ledger, not data loss, and the per-file drift check still produces correct output.

### 3.3 Record shape

Append-only, one JSON object per line, never rewritten.

```jsonc
// kind: "base" — exactly one, written on first use of the ledger
{"kind":"base","ts":"2026-09-01T21:00:00-04:00","base":"origin/main","base_sha":"a1b2c3d..."}

// kind: "note" — author-written. `note` is the narration and is REQUIRED.
// `watch` is the scrutiny-flag list and is OPTIONAL (absent or [] when nothing to flag).
{"kind":"note","ts":"...",
 "note":"Replaced the ad-hoc retry loop in the fetch path with a shared helper, so
   the timeout and backoff live in one place instead of three. Callers now pass a
   budget instead of a retry count.",
 "watch":["The backoff constant is deliberate — 250ms, not the 1s the old loop used;
   see the comment for why.",
   "fetchAll() is the one caller still on the old signature; it is adapted at the
   call site rather than migrated."],
 "files":[
  {"path":"src/retry.mjs","blob":"e69de29..."},
  {"path":"src/retry.test.mjs","blob":"f0a1b2c..."},
  {"path":"src/old-retry.mjs","blob":null}]}   // deleted at note time — §3.3a

// kind: "skip" — deliberate "this needs no note". `note` holds the reason. No `watch`.
{"kind":"skip","ts":"...","note":"typo fix","files":[
  {"path":"README.md","blob":"c1d2e3f..."}]}
```

`blob` = `git hash-object` of the file's content at note time. Hash the working-tree bytes
(`git hash-object --stdin`) so untracked and unstaged files hash identically to how git
would.

A `note` record with no `watch` key, or `watch: []`, is valid and normal. A record with an
empty or missing `note` is not (§5.1).

> **r2 — retraction, retained.** r1 recorded a "correction" that `files` had to become
> `[{path, hash}]` because the ruling gave a bare path list. **Wrong, and the error was
> mine.** 1a0g §[1].1 specifies `files:[{path, blob}]` with `blob` defined as
> `git hash-object` at note time — correct as written. The path-list form came from the
> dispatch request's *summary* of the ruling. **A summary is not the artifact, and a
> defect found in a summary must be re-checked against the source before it is reported as
> a defect in the source.**

#### 3.3a Deleted files — `{path, blob: null}` (r6, confirmed)

A path that is deleted at note time is recorded as `{path, blob: null}`. It is **recorded,
not omitted**.

The Implementor's reading is correct and is adopted verbatim. Both halves matter:

- **Recorded, because omitting loses information.** The note *did* cover that deletion, and
  the deletion is often the most reviewer-relevant part of a change. Dropping the entry
  would make a deliberately-explained deletion indistinguishable from an unexplained one.
- **`blob: null` rather than a sentinel hash**, because there is no content to hash and any
  stand-in value would be a hash that could collide with a real one.

Classification follows §4.2's existing rule with one consequence made explicit: for a path
that is currently deleted, **any** `note` record naming it counts as annotated, regardless
of `blob`. A hash comparison is meaningless when there is no current content, so presence
in the note is the whole test.

Two behaviours that fall out of this and are correct as-is:

- A file deleted *after* being noted with a real blob is annotated — the note named it, and
  the note's description of why it went away is what a reviewer wants.
- A file deleted, noted as `blob: null`, then **restored** becomes *unannotated*, because
  it now has content that no note's blob matches. That is right: the note described an
  absence, and the file is no longer absent. This is the ordinary §4.2 drift rule doing its
  job, not a special case.

`null` is a legal `blob` value only for a path absent from the working tree at note time.
Never write `null` for a file that exists.

#### The base must be written, not re-derived

1a0g §[1].3 derives drift against `git merge-base <default> HEAD`, computed fresh each
invocation. That names no durable source: re-deriving later silently changes answer once
`origin/HEAD` moves, an upstream is set mid-branch, or the default branch is renamed. The
`kind:"base"` record fixes it once, at first use. Every later `note`/`guide`/`status` reads
it from the ledger and never re-derives. If the ledger has no `base` record, `guide` writes
one at that moment and says so on stderr.

#### Base resolution order — used ONLY when writing the `base` record

1. `--base <ref>` flag, if given.
2. `git rev-parse --abbrev-ref @{upstream}` — **only when the upstream is not this
   branch's own remote-tracking ref.** Compare the upstream's branch component to the
   current branch name; if equal, skip to step 3.
3. `origin/HEAD` if it resolves.
4. `origin/main`, then `origin/master`, then `main`, then `master` — first that resolves.
5. None resolve → record `{"base":null}` and treat the change scope as "working tree vs
   `HEAD`" only. `guide` prints a one-line stderr warning.

Store `base_sha` = the resolved merge-base commit, not just the ref name. The ref is for
display; the SHA is what §4.1 diffs against.

> **r5 — Fix A: step 2's guard is load-bearing and was missing.** `git push -u` sets the
> upstream to `origin/<same-branch>`. Unguarded, step 2 resolves the base to
> `origin/feat-x`, whose merge-base with `HEAD` is `HEAD` itself — the change scope
> computes as **empty**, every guide reads `0 of 0 annotated`, and because the base is
> pinned by design, **that wrong answer is frozen for the life of the branch.**
>
> Not an edge case: it fires on the first `note` after any push, on a fresh clone, and on a
> second machine.
>
> The interaction that makes it severe: "write the base once, never re-derive" is correct
> — it is what keeps the compile and the gate agreeing — but it converts a transient wrong
> answer into a permanent one. A rule that pins a value must be paired with care about what
> it pins.

### 3.4 No config, no on/off switch

**r4:** deleted. Earlier revisions carried a `config.json` `{"enabled": …}`, a
`REVIEW_GUIDE=off` env var, and `guide.mjs on|off`. Their only consumer was the PR gate.
With no hook, **a tool that runs only when invoked has no off state**. Ship no config file,
no env var, and no `on`/`off` subcommands. Do not reintroduce a config "for future use".

---

## [4] Change scope and drift

`guide` and `status` need the same sets. Compute them in one shared function.

### 4.1 Changed files

Union of:

- `git diff --name-only <base_sha>...HEAD` (omit when `base` is null)
- `git diff --name-only HEAD` (unstaged)
- `git diff --name-only --cached` (staged)
- `git ls-files --others --exclude-standard` (untracked)

Deleted paths are included and marked.

### 4.2 Annotated, skipped, unannotated

A changed file is **annotated** iff some ledger `note` record contains an entry for that
path whose `blob` equals the file's *current* `git hash-object`. Same test against a `skip`
record makes it **skipped**. Everything else changed is **unannotated**.

**Deleted paths are the one exception**, and §3.3a states it in full: a path with no
current content is annotated if any `note` names it at all, regardless of `blob`.

Any subsequent edit makes a file unannotated again — that is the drift signal and the whole
point: a note describes the content it was written about. A skip drifts the same way,
deliberately.

Coverage = annotated / (changed − skipped). Skips are reported separately and never counted
as annotation.

---

## [5] The CLI — `review-guide/bin/guide.mjs`

**Naming.** The ruling's working name was `rg.mjs`. Renamed to `guide.mjs`: `rg` is
ripgrep, and prose reading `rg.mjs guide` invites a reader to run ripgrep.

Node, no dependencies. All git access via `child_process.execFileSync("git", [...])` —
never a shell string.

Subcommands, complete list: `note`, `status`, `guide`.

### 5.1 `guide.mjs note` — narration plus flags

```
guide.mjs note "<narration>" [--watch "<flag>"]... [--files a,b] [path ...]
guide.mjs note --skip "<why>" [--files a,b] [path ...]
```

- `<narration>` is **required**: what was done and why, in prose a reviewer can follow.
- `--watch "<flag>"` is **optional and repeatable**, stored as the `watch` array. Omit
  entirely when there is genuinely nothing to flag.
- Writes one `note` record. Writes the `base` record first if the ledger is new.
- With no `path` args and no `--files`, files default to **the changed set (§4.1)**.
- Accepts positional paths and the ruling's `--files a,b` comma form as an alias.
- Deleted paths in the set are recorded as `{path, blob: null}` (§3.3a).
- `--skip "<why>"` writes `kind:"skip"`. `--watch` with `--skip` is an error.
- Re-recording a path at a blob already present is a harmless duplicate; do not dedupe.
- Empty or whitespace-only narration → exit non-zero, write nothing. Same for an empty
  `--watch` value.

### 5.1a Schema decision — two fields, not one

`note` (string) and `watch` (array of strings) are **separate fields**. Rejected:
overloading one field with a prose convention.

1. **The compile renders them differently.** Narration belongs inline in the reading order;
   flags belong in a callout *and* aggregated into a cross-PR watch list (§5.3) — the view
   answering "what should I be suspicious of" without reading every entry. Free with a
   separate field; requires parsing prose without one.
2. **Different obligation.** Narration is always required; flags are legitimately often
   absent. One field cannot express that asymmetry.
3. **Cost is one CLI flag.**

Not gold-plated: `watch` is a flat string array. No severity, no category, no per-file
association within a note.

### 5.1b Why narration is in, over the Ultra-Advisor's exclusion

1a0g ruled: *"Content is NOT 'what changed' — it is what to LOOK AT."* The user overturned
it after the tradeoff was explained (`ala6` §[2]).

Recorded as reasoning, not just instruction, because a future reader who finds the ruling
will otherwise re-correct the spec back to it:

- The ruling's premise is that the diff already carries what changed. True of *content*,
  false of *intent and order*. A diff shows every edit with equal weight and no sequence;
  it cannot say which change is the point and which three are consequences, or why an
  approach was chosen over the obvious one.
- The ask was a **roadmap**. A pure risk-flag list is warnings about a journey nobody has
  described. The connective tissue is the half a diff cannot supply and the half that
  evaporates soonest.
- Flags-only fails the second audience: an LLM reviewer reconstructing intent from a diff
  is the reconstruction-loss both rulings set out to avoid.

The ruling's concern — narration degenerating into diff-restatement — is real and handled
in SKILL.md prose (§10.1 §4), not by removing the field.

### 5.2 `guide.mjs status`

Prints branch, base, ledger path, note count, `N of M annotated (K skipped)`, watch-flag
count, and the unannotated list.

### 5.3 `guide.mjs guide [--out <path>] [--pr]`

Writes markdown to `--out`, defaulting to `<store>/<branchkey>.guide.md`. Overwrites every
time; derived, never hand-edited.

```markdown
<!-- review-guide: generated branch=<branchkey> base=<base> head=<sha> annotated=7 changed=9 skipped=1 -->
## Reviewer's guide

_Generated by `review-guide`. Do not hand-edit — regenerate with `guide.mjs guide`._

**7 of 8 changed files annotated.** (1 skipped as trivial.)

### Watch list

Everything flagged for scrutiny, across the whole change:

- The backoff constant is deliberate — 250ms, not the 1s the old loop used. — `src/retry.mjs`
- `fetchAll()` is the one caller still on the old signature. — `src/retry.mjs`

_Omit this section entirely when no note carries a `watch` flag._

### Reading order

1. **`src/retry.mjs`, `src/retry.test.mjs`**

   Replaced the ad-hoc retry loop in the fetch path with a shared helper, so the
   timeout and backoff live in one place instead of three. Callers now pass a budget
   instead of a retry count.

   **Watch:**
   - The backoff constant is deliberate — 250ms, not the 1s the old loop used.
   - `fetchAll()` is the one caller still on the old signature.

### Changed but not annotated

- `src/util/fmt.mjs` (+4 −1) — _no note; auto-derived from diff stat_

### Skipped as trivial

- `README.md` — _typo fix_

### Diff stat

<output of `git diff --stat <base_sha>...HEAD` plus working-tree stat>
```

Rendering rules:

- **Watch list** first, before the walkthrough — a reviewer deciding where to spend
  attention should not read the whole guide to find the warnings. Each entry carries the
  files of the note it came from. Omitted when empty.
- **Reading order**: annotated files grouped by the note covering them, notes in ledger
  (time) order. Narration as prose; the note's own flags repeat under a **Watch:** sub-list
  so an entry is self-contained. The repetition is intentional.
- Deleted paths render with their path struck or marked `(deleted)`, under the note that
  covers them — a reviewer should see explained deletions in the walkthrough, not only in
  the diff stat.
- A file covered by more than one note appears under its **latest** matching note only.
  Earlier notes' `watch` flags still appear in the Watch list.
- Auto-derived entries stay mechanical: diff-stat only, no generated prose.

**The HTML marker line is informational.** It existed so the deleted PR gate could verify
provenance. Nothing validates it now. Keep it: one comment line, machine-readable counts,
and it marks the file as derived. Do not add anything inside this plugin that reads it back.

The `N of M` header exists so a **reviewer** knows how much of the PR was explained — a
fact about the artifact, not a nudge aimed at the author.

### 5.4 `--pr`

`--pr` writes the guide and **prints the commands**, without executing either:

```
# if no PR exists for this branch yet:
gh pr create --body-file <abs path to guide>

# if a PR already exists:
gh pr edit --body-file <abs path to guide>
```

**r5 — Fix C.** Earlier revisions printed only `create`, which is wrong the moment the
guide is regenerated for an existing PR — the common case, since the guide is meant to be
refreshed as work continues. Printing both is two lines of output. Shelling out to
`gh pr view` to detect which applies would make this script perform a network call as a
side effect of compiling a document, which the rule below already forbids.

It does **not** execute `gh`. 1a0g §[1].4 has `--pr` piping straight into
`gh pr create/edit --body-file`; not adopted. The r1–r3 reason (a second PR path would
bypass the gate) died with the gate, but the surviving reason suffices: **a helper script
should not perform an outward-facing action as a side effect of compiling a document.**

---

## [6] What stops this being skipped: nothing

**There is no enforcement.** No hook, no gate, no deny, no blocking, no automatic
invocation. `review-guide` produces a good artifact when someone runs it and nothing when
nobody does — the same trust model as every other skill in this repo.

The two ways it gets used:

1. The user runs `/review-guide note ...` / `/review-guide guide --pr` themselves.
2. The user gives their session a standing instruction — "always run the review guide
   before opening a PR" — and the LLM follows it like any other workflow habit.

Neither is provided by the plugin. Both are the user's to establish.

**Do not reintroduce enforcement as prose.** SKILL.md describes what the tool does and what
a good note looks like. It does not exhort, does not warn the model that skipping is bad,
and adds no "remember to" language. A soft-gate rebuilt out of nagging text is the thing
that was rejected, just cheaper to ignore and more annoying to read.

**Retained from the enforcement-era design, and why each still earns its place:**

- **Auto-derive for unannotated files** — a generated guide is complete regardless of how
  much was noted. Artifact honesty, not author pressure.
- **`N of M annotated` header** — a reviewer knows how much was explained before trusting
  the walkthrough.
- **`note --skip`** — "judged trivial" and "never looked at" stay distinguishable.

**Known consequence, stated not solved:** a guide can be generated with zero notes and will
then be a diff-stat listing with a `0 of N annotated` header. If the user later wants that
prevented, §6a is the constraint any proposal has to clear.

### 6a Why the PR gate was dropped — the real constraint

**This supersedes an earlier, wrong account.** The dispatch ordering r4 first characterized
the decision as a preference against hooks. The Orchestrator corrected it: the reason is
technical, and the distinction matters because "taste" and "this cannot work" lead future
readers to opposite conclusions.

The gate was a `PreToolUse` matcher on `Bash`, scanning for `gh pr create|edit`. Two
independent defects:

1. **It guards one path to an action reachable by many.** A PR can be opened through a
   GitHub MCP tool call that never produces a `Bash` invocation, or through the web UI, a
   different CLI, or a wrapper. This generalizes: **any gate that pattern-matches tool
   invocations is inherently incomplete against an open and growing set of tool surfaces.**
   MCP servers can be added at any time; a matcher written today cannot enumerate
   tomorrow's.
2. **A deny is an instruction, and instructions need a competent reader.** The invoking
   agent may be a cheap tier that retries the blocked call, works around it, or treats the
   deny as transient. The gate's effectiveness becomes a property of who happens to be
   calling.

**The compounding problem is false confidence, and it is the actual reason to delete rather
than improve.** A gate with 60% coverage believed to have 100% is worse than no gate: the
belief is what stops anyone from establishing the habit that would work. A partial
mechanism displaces the practice it was meant to guarantee.

**The bar for a future proposal.** Not "cover the MCP tools too" — enumerating today's
surfaces still fails tomorrow's, and defect 2 is untouched by better matching. A proposal
clears §6a only if it enforces at a choke point that *cannot* be routed around: server-side
(branch protection, a required CI check) rather than client-side.

**Status of 1a0g's contrary ruling.** It called the PR gate "load-bearing". **Superseded**,
on evidence it did not have: the ruling reasoned about capture discipline and did not
consider non-`Bash` paths to PR creation or the caller-competence assumption. Corrected on
the merits, not overridden by preference.

---

## [7] Hooks: none

**This plugin ships zero hooks.** No `review-guide/hooks/` directory, no `hooks.json`, no
hook script of any kind. No exception.

Deleted at r4: the `PreToolUse`/`Bash` gate, its script, its registration, its 11 test
cases, its 6 acceptance items (rationale §6a), and the on/off config that existed only to
disable it (§3.4). Deleted at r1 and staying deleted: the `Stop`/`SubagentStop` "unnoted
changes" gate from 1a0g §[1].3.

**No future-hook roadmap item.** §6a is why: an entry proposing a future hook would promise
what the mechanism cannot deliver, and a plan that cannot work reads as a commitment.

This is a constraint on **this plugin**, argued from §6a — not a general position that
hooks are wrong. Other plugins here enforce with hooks appropriately, because they gate
things with one surface. PR creation does not.

Two consequences, recorded so nobody re-derives them:

- 1a0g's "Not verified" item — whether a `Stop` block fires for `--agent`-launched
  top-level sessions — is permanently moot here.
- 1a0g's convergence argument assumed hierarchy Implementors' notes reach the ledger *via*
  Stop/SubagentStop hooks. They reach it because the Implementor runs `guide.mjs note`
  (§8).

---

## [8] Hierarchy fold

One store, one compile path. A hierarchy Implementor — peer session or subagent — is an
ordinary Claude Code session with this plugin installed. It runs `guide.mjs note` like
anyone else and writes to the ledger for **whatever branch its checkout is on**.

> **r5 — Fix B applies here too.** r1–r4 said `--git-common-dir` "is what makes a
> worktree-routed Implementor and the main-checkout Orchestrator share one ledger." It is
> not, and they do not: the ledger is branch-keyed and one branch cannot be checked out in
> two worktrees at once. Corrected: an Implementor working `feat-x` in a worktree writes
> `feat-x.jsonl`; an Orchestrator wanting that guide must run `guide` from a checkout **on
> `feat-x`** — which, while the Implementor holds it in a worktree, means running it in
> that worktree. The fold still works; it is invocation-located, not path-shared.

**Do not build `msg.mjs guide`.** **Do not add `## [6] reviewer_notes`.** 1ms9 put notes in
message files because no durable store existed; the ledger removes that premise, and 1a0g
itself downgrades the section to optional. Two stores with nothing reconciling them is the
failure to avoid.

1ms9's slug/parent-discipline gap (its §[4]) is moot: the compile no longer walks the msg
trail.

**Stated consequence of r4:** with no hooks, a dispatched Implementor will not write notes
unless its role prose or the dispatch tells it to. Nothing in this plugin makes that happen
and this spec does not add it (§2 forbids touching `ah`). If the user wants
hierarchy-routed work noted by default, that is an `ah` change and a separate decision.

---

## [9] Files to create / change

### New — `review-guide/`

| Path | Contents |
|---|---|
| `review-guide/.claude-plugin/plugin.json` | Mirror `output-discipline/.claude-plugin/plugin.json`: `name: "review-guide"`, `displayName: "Review Guide"`, `version: "0.1.0"`, description, `author: {name: "Jim Cline"}`, `license: "MIT"`, keywords (`review`, `pr`, `github`, `documentation`), `"skills": "./skills/"`. **No `mcpServers` key. No hooks key.** |
| `review-guide/bin/guide.mjs` | §5. |
| `review-guide/lib/store.mjs` | Shared: git-common-dir resolution, branchkey, ledger read/append, base record and its §3.3 resolution order, changed/annotated/skipped sets (§4). |
| `review-guide/skills/review-guide/SKILL.md` | §10.1. |
| `review-guide/commands/review-guide.md` | Thin: frontmatter `description` + `argument-hint: "note <text> [--watch <flag>] \| note --skip <why> \| status \| guide [--pr]"`. |
| `review-guide/README.md` | Short: what it does, install line, that it is invoked and never automatic, the two usage patterns from §6, and the §3.1 cwd rule. No roadmap section. |
| `review-guide/tests/test-review-guide.sh` | §10.2. |

**Not created:** `review-guide/hooks/` (any file), `hooks.json`, `pretooluse-gh-pr.mjs`,
`tests/test-pr-gate.sh`.

### Changed

| Path | Change |
|---|---|
| `.claude-plugin/marketplace.json` | Add a fifth entry to `plugins`, between `output-discipline` and `task-gopher` (the array is alphabetical). Shape mirrors the `output-discipline` entry: `name`, `source: "./review-guide"`, `description`, `version: "0.1.0"`, `author`, `license`, `keywords`, `category: "productivity"`. **Do not** add anything to `renames`. |

`plugin.json` and `marketplace.json` versions must agree (`0.1.0`). Every future change
bumps both.

---

## [10] SKILL.md and tests

### 10.1 SKILL.md content

1. **What it is** — note as you go, compile mechanically, attach to the PR. Say it only
   runs when invoked.
2. **The one rule** — write a note after each meaningful unit of work, before moving on.
   One note per turn-of-work, not per edit and not per PR; one note per *concern*, not per
   file.
3. **What a note contains — two halves.**
   - **The narration (required).** What you did and why: the point of the change, what
     approach you took and what over, and how the touched files relate. A few sentences.
   - **The watch flags (optional, repeatable `--watch`).** Risky choices, judgment calls
     where the spec was silent, deviations and why, invariants relied on,
     touched-but-untested areas. One flag per concern, one line each. Omit entirely when
     there is nothing — an empty flag is worse than none, because it reads as "reviewed and
     cleared".
4. **The narration failure mode, named.** Not a restatement of the diff. "Changed `foo()`
   to take a second argument" is worthless — the diff says that. "Callers now pass a budget
   instead of a retry count, so the timeout policy lives in one place" is the same edit at
   the level a reviewer needs. Rule of thumb: if the sentence would still be true and useful
   with the file names removed, it is narration; if it only makes sense as a caption on a
   hunk, it is diff-restatement.
5. **When to skip instead** — `note --skip` for genuinely trivial changes.
6. **Commands** — `note`, `note --watch`, `note --skip`, `status`, `guide`, `guide --pr`,
   with the full `node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" ...` invocation spelled out and
   one worked example of a note carrying both halves.
7. **When it runs** — the two patterns from §6. Nothing in the plugin enforces or triggers
   anything.
8. **Where to run it** — cwd must be inside the checkout of the branch being compiled;
   otherwise `guide` silently compiles the wrong branch. §3.1.
9. **Drift note** — a note goes stale when its file changes again; intentional, and
   `status` is how you see it. Mention the deleted-file case from §3.3a in one line: a
   deletion stays explained, and a restored file goes back to unannotated.
10. **Authority** — "this spec (`docs/specs/0002-review-guide-plugin.md`) is authoritative
    on behaviour; if this file disagrees with it, the spec wins."

**Tone constraint.** Descriptive, not hortatory. No "remember to", no "always run this
before", no warnings about skipping. §6's prohibition on prose-rebuilt enforcement governs
this file specifically.

Comment-discipline applies to all code. The `WHY` comments that *should* exist: §3.1's
git-common-dir reasoning, §3.3's Fix A guard (a bare `@{upstream}` check looks like an
omission without it), and §3.3a's deleted-path branch in `classify()`.

### 10.2 Test plan

One file: `review-guide/tests/test-review-guide.sh`. HOME-redirect + temp git repo, per
`agent-hierarchy/tests/test-*.sh`. Shell, no framework.

1. `note` on a fresh repo writes a `base` record then a `note` record; ledger lands under
   the path `git rev-parse --git-common-dir` reports.
2. **Worktree behaviour.** `git worktree add` a *different* branch, `note` in each checkout,
   and assert: two distinct ledger files (one per branch) both under the common dir;
   `guide` run in the worktree compiles the worktree's branch; `guide` in the main checkout
   compiles the main branch. Then `git worktree remove` and assert the worktree branch's
   ledger still exists. The pre-r5 test — "a record written in a worktree appears in the
   main checkout's ledger" — asserted something untrue and must not be reinstated.
3. **Base with `push -u` (Fix A).** Branch off `main`, `git push -u` to a local bare remote
   so the upstream is `origin/<same-branch>`, then run the **first** `note`. Assert the
   recorded `base_sha` is **not** `HEAD` and that `status` reports a non-empty changed set.
4. **Base is not re-derived.** Write the base record, then move `origin/HEAD` (or set an
   upstream) and assert `status` still reports the originally recorded base.
5. Branch with a slash (`feat/x`) produces a flat `feat-x.jsonl`, not a nested dir.
6. Detached HEAD: `note` succeeds and writes to `detached.jsonl`.
7. Drift: note a file, assert `status` says annotated; modify it, assert it flips to
   unannotated. Same for a `--skip` record.
8. **Deleted files (r6, §3.3a).** Delete a tracked file, `note` it, and assert: the record
   carries `{path, blob: null}` rather than omitting the entry; `status` counts it
   annotated; `guide` renders it under its note marked as deleted. Then **restore** the file
   and assert it flips to unannotated.
9. `guide` output contains the marker line, the `N of M` count, an auto-derived entry for an
   unnoted changed file, a separate skipped section, and never an empty body.
10. `guide --pr` prints **both** a `gh pr create --body-file` and a `gh pr edit --body-file`
    line, and invokes **neither** (assert with a `gh` stub on PATH that fails loudly if
    called).
11. `note ""` exits non-zero and writes no record.
12. `--files a,b` comma form accepted and equivalent to positional paths.
13. **Two-field schema:** two `--watch` flags store a 2-element `watch` array; none stores
    no `watch` key (or `[]`) and is valid.
14. **Watch rendering:** with flags, output contains a top-level **Watch list** listing both
    with their file, *and* a per-entry **Watch:** sub-list. With no flags anywhere, the
    Watch list section is absent entirely — not present-and-empty.
15. **Narration required:** `note --watch "x"` with empty narration exits non-zero and
    writes no record. `note --skip "why" --watch "x"` is an error.
16. **Zero-note guide:** `guide` on a branch with changes but no notes succeeds, exits zero,
    and produces a `0 of N annotated` header with auto-derived entries.
17. **No hooks:** assert `review-guide/hooks/` does not exist and `plugin.json` has no
    `hooks` key.

---

## [11] Open items

### 11.1 Ruling provenance

1a0g's response file did not exist on disk at r1; the Orchestrator reconstructed it at r2
from the verbatim SendMessage reply and it was read in full. Substance confirmed — but
reading the source still changed three things, which is the practical argument for reading
sources rather than summaries even when the summary is faithful.

**Caveat that stands, and applies twice:** both the 1a0g and ts1t rulings are
*reconstructions*, not original artifacts — the Ultra-Advisor has no Write tool (spec 0028
§3.6) and replies inline. Treat as faithful transcripts, not untouched primary sources.
**The ts1t response file should be written by the Orchestrator from the verbatim reply it
holds, not by me** — reconstructing from a summary would produce a lower-fidelity document
under the Ultra-Advisor's name.

### 11.2 Resolved decisions

- **Note content (r3):** narration **and** flags, overturning 1a0g's flags-only
  restriction. §5.1b.
- **Per-turn enforcement (r1):** no Stop/SubagentStop gate.
- **PR-time enforcement (r4):** no `PreToolUse` gate, no hooks. §6a, a *technical*
  argument, not a preference.
- **Thin guides (§6):** not prevented. Auto-derive and the coverage header are honesty in
  the artifact, not pressure.
- **Deleted-file shape (r6):** `{path, blob: null}`, recorded not omitted. §3.3a.

A future reader finding 1a0g's "load-bearing" description of the PR gate should read it as
superseded on the merits (§6a), not dropped by oversight or taste.

### 11.3 Confidence

- HIGH: store design (§3), drift rule (§4), and the r4 deletions (§7).
- HIGH on Fix A (§3.3) — a mechanical git fact whose severity comes from an interaction
  this spec created (pinning the base).
- HIGH on Fix B (§3.1, §8) — the two-worktrees-one-branch constraint is a hard git rule.
- HIGH on §3.3a — it is the only shape consistent with §4.2, and the restore-flips-to-
  unannotated consequence falls out of the existing rule rather than needing a new one.
- HIGH on §5.1a (two fields) and §6a's first defect (coverage).
- MEDIUM-HIGH on §6a's second defect (caller competence): directionally right, unmeasured.
  The first defect alone is sufficient.
- MEDIUM on §10.1 §4's narration-quality guidance — the design's largest soft spot. With no
  gate, *every* quality property of the output depends on prose discipline and the user's
  standing instruction. Per §6a that is the honest position, but it should be named rather
  than glossed.
- MEDIUM: §5.3's "latest matching note wins" for reading order. Cheap and reversible.
- Retracted: r1's `{path, blob}` correction (§3.3 box); r1–r4's worktree-sharing rationale
  (§3.1 box).

### 11.4 NEEDS-EVIDENCE

**None.**

---

## [12] Acceptance checklist

1. `review-guide/` exists with the 7 files in §9, and no changes under `agent-hierarchy/`.
2. **No `review-guide/hooks/` directory, no `hooks.json`, no hook script.** `plugin.json`
   has no `hooks` key (test 17).
3. **No config file, no `REVIEW_GUIDE` env var, no `on`/`off` subcommands.** Subcommands
   are exactly `note`, `status`, `guide`.
4. `plugin.json` version `0.1.0`; `marketplace.json` has a matching entry at `0.1.0`,
   `source: "./review-guide"`, no `renames` addition.
5. Ledger path resolves via `git rev-parse --git-common-dir`, resolved against the repo
   root.
6. **Base resolution skips `@{upstream}` when it is this branch's own remote-tracking ref**
   (Fix A), with test 3 covering the `push -u` case.
7. Exactly one `base` record per ledger, written on first use, never re-derived (test 4).
8. `base_sha` stored alongside `base`, and §4.1 diffs against the SHA.
9. `note` records carry `files: [{path, blob}]` — field name `blob`.
10. **Deleted paths are recorded as `{path, blob: null}`, never omitted; any note naming a
    currently-deleted path counts as annotated; a restored file returns to unannotated**
    (§3.3a, test 8). `null` is never written for a file that exists.
11. Branch `feat/x` → flat `feat-x.jsonl`. Detached HEAD → `detached.jsonl`.
12. `note` takes a required narration and zero or more `--watch` flags, stored as separate
    `note` (string) and `watch` (array) fields. Empty narration is an error.
13. `guide` renders an aggregate `Watch list` first, with each flag's files, omitted
    entirely when no flags exist.
14. Reading-order entries render narration as prose with the note's own flags under a
    `Watch:` sub-list, and show deleted paths marked as deleted.
15. `note --skip` writes `kind:"skip"`; skipped files get their own guide section, never
    counted as annotated. `--skip` with `--watch` is an error.
16. `--files a,b` accepted as an alias for positional paths.
17. `guide` output always non-empty, carries the marker line and the `N of M` header, and
    auto-derives entries for unannotated files — mechanically, no generated prose.
18. **`guide` with zero notes succeeds and exits zero** (test 16).
19. **`guide --pr` prints both the `create` and `edit` forms and executes neither**
    (test 10).
20. **Two worktrees on different branches keep separate ledgers, both under the common dir,
    and a ledger survives `worktree remove`** (test 2).
21. No `msg.mjs guide` subcommand and no `## [6] reviewer_notes` section exist.
22. SKILL.md states both halves of a note, the diff-restatement failure mode, and the §3.1
    cwd rule, with a worked two-half example.
23. **SKILL.md and README contain no enforcement language** — no "remember to", no "always
    run before", no warning about skipping, no future-hook roadmap item.
24. The test script passes.
