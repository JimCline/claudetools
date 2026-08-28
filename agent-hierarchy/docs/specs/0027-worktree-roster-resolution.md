# 0027 — Worktree roster resolution

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-08-28
Files: `agent-hierarchy/hooks/lib-config.mjs`, `agent-hierarchy/hooks/roster.mjs` (read path only), `agent-hierarchy/tests/test-roster-levels.sh` (or a new `test-roster-worktree.sh`)

## 1. Problem

From inside a git worktree, `resolveRoster` reports "no agent roster defined"
even when a roster exists at the *main* checkout.

Cause chain, all in `lib-config.mjs`:

- `findGitRoot` (`:263-271`) walks up to the nearest `.git` **entry** and stops.
  In a worktree, `.git` is a FILE containing `gitdir: <main>/.git/worktrees/<n>`.
  `findGitRoot` returns the *worktree's* root and never follows the pointer.
- `rosterLevelPaths` (`:295-303`) keys BOTH non-global levels off that value:
  - `repo` → `<worktreeRoot>/.claude/agent-hierarchy.json`
  - `repo-user` → `~/.claude/agent-hierarchy/projects/<pathSlug(worktreeRoot)>/agent-hierarchy.json`
- `resolveRoster` (`:408-434`) tries exactly one path per level and returns null.

So a roster at `<mainRoot>/.claude/agent-hierarchy.json`, or under
`pathSlug(mainRoot)`, is **unreachable** from any worktree. `global` is
unaffected (no repo dependency).

## 2. Goal / non-goals

**Goal.** From a worktree, resolution also considers the main checkout's `repo`
and `repo-user` paths, at lower precedence than the worktree's own. Behaviour in
a normal (non-worktree) checkout is bit-for-bit unchanged.

**Non-goals — do NOT change these, they are load-bearing elsewhere:**

- **`findGitRoot` itself.** It is also the basis of `hierarchyDir` (`:284`) and
  `teamPrefixInfo` (`:374`). Making it return the main root would relocate every
  worktree's `.claude/hierarchy/` message dir to the main checkout, so two
  worktrees would share one message space and one id sequence. Keep message
  dirs worktree-local. The fix lives in `rosterLevelPaths`/`resolveRoster`, not
  in `findGitRoot`.
- **`teamPrefixInfo` / peer-name prefix.** It stays keyed on the worktree
  basename, so peers spawned from two worktrees keep distinguishable names.
- **The write path.** See §6.
- **`ROSTER_LEVELS`.** No new level names — see §4.

## 3. Detecting the main checkout (pure fs, no `git` subprocess)

`lib-config.mjs` imports nothing from `node:child_process` today (confirmed:
zero matches). `execFileSync` exists only in `roster.mjs` (tmux/herdr) and in
tests. `lib-config.mjs` is loaded on every hook invocation, so **do not add a
`git rev-parse` subprocess here.** The pointer files are readable directly.

Add (not exported unless a test needs it — see §7):

```js
/**
 * Main checkout root when `worktreeRoot` is a linked worktree, else null.
 * A worktree's `.git` is a FILE holding `gitdir: <main>/.git/worktrees/<name>`;
 * that dir's `commondir` file points back at the main `.git`. A submodule uses
 * the same `.git`-file mechanism but resolves under `.git/modules/`, so the
 * `worktrees` check below is what keeps submodules out.
 */
function mainCheckoutRoot(worktreeRoot) {
  const dotgit = join(worktreeRoot, ".git");
  let raw;
  try {
    if (!statSync(dotgit).isFile()) return null;   // normal checkout: .git is a dir
    raw = readFileSync(dotgit, "utf8");
  } catch { return null; }
  const m = /^gitdir:\s*(.+)$/m.exec(raw);
  if (!m) return null;
  const gitdir = resolve(worktreeRoot, m[1].trim());   // pointer may be relative
  if (basename(dirname(gitdir)) !== "worktrees") return null;   // submodule, or unknown layout
  let commonDir;
  try {
    commonDir = resolve(gitdir, readFileSync(join(gitdir, "commondir"), "utf8").trim());
  } catch {
    commonDir = dirname(dirname(gitdir));            // .../.git/worktrees/<n> -> .../.git
  }
  // Only a `<root>/.git` common dir implies a working tree at `<root>`. A bare
  // repo's is `<name>.git` and `--separate-git-dir`'s is an arbitrary path;
  // deriving a root from either names a directory that is not a checkout.
  if (basename(commonDir) !== ".git") return null;
  const root = dirname(commonDir);
  return root && root !== worktreeRoot ? root : null;
}
```

Requires adding `statSync` to the existing `node:fs` import at `:28`.
`basename`, `dirname`, `join`, `resolve` are already imported (`:30`).

Every failure mode returns `null` — unreadable file, missing pointer, submodule,
bare-repo or separate-git-dir layout, unrecognised layout — which degrades to
exactly today's behaviour. That is the correct degradation direction here: this
is a *lookup*, and a wrong main-root guess would silently bind a session to
another repo's roster.

### 3.1 The `basename(commonDir) !== ".git"` guard — why it is required

**Amended 2026-08-28 (Reviewer spec-defect, correcting this section's original
claim).** An earlier revision asserted that a worktree linked from a **bare**
repository "returns null and falls through". That was wrong, and it was wrong in
the dangerous direction. Traced: `commondir` resolves to the bare repo dir
(`~/projects/repo.git`), `dirname` of it is the bare repo's **parent**
(`~/projects`), which is non-null and `!== worktreeRoot` — so it was pushed as a
candidate. If `~/projects/.claude/agent-hierarchy.json` exists, the worktree
binds to a roster belonging to nothing, which is precisely the "silently bind a
session to another repo's roster" failure the paragraph above says the design
avoids.

The original text also said "document it, do not code around it", which was
correct advice for the limitation I *described* and wrong advice for the
behaviour that actually existed. It is withdrawn: **the guard is required, not
optional.** A silent bind to an unrelated roster is not an acceptable residual.

`--separate-git-dir` checkouts also return null under this guard. That is a lost
*gain*, not a regression — those worktrees resolve exactly as they do today.

**Genuinely residual, accepted:** a bare repository whose directory is literally
named `.git`. Indistinguishable from a real checkout without reading git config,
and not worth a config parse in a per-hook code path.

## 4. Resolution order

`ROSTER_LEVELS` stays `["repo-user", "repo", "global"]`. It is validated against
in `roster.mjs:139/143` as the set of user-facing `--level` names; adding
`repo-main` / `repo-user-main` would expand the CLI surface and force a decision
about what `--level repo-main` means when you are *not* in a worktree. Instead a
level maps to a **list of candidate paths**, tried in order.

Add alongside `rosterLevelPaths` (which is unchanged — 10 call sites in
`roster.mjs` depend on its one-path-per-level shape):

```js
/** Candidate config paths per roster level, most specific first. */
export function rosterLevelCandidates(cwd) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  const roots = [repoRoot];
  const main = mainCheckoutRoot(repoRoot);
  if (main) roots.push(main);          // empty for a normal checkout
  return {
    "repo-user": roots.map((r) => join(homedir(), ".claude", "agent-hierarchy", "projects", pathSlug(r), CONFIG_BASENAME)),
    repo: roots.map((r) => join(r, ".claude", CONFIG_BASENAME)),
    global: [userConfigPath()],
  };
}
```

`resolveRoster` changes only its loop head — the per-path parse/validate body is
unchanged, and `path` in the returned object becomes the candidate that matched:

```js
for (const level of ROSTER_LEVELS) {
  for (const path of candidates[level]) {
    if (!existsSync(path)) continue;
    ...unchanged body, `return { level, ..., path }`...
  }
}
```

Effective order **from a worktree**:

| # | Level | Path |
|---|-------|------|
| 1 | `repo-user` | `~/.claude/agent-hierarchy/projects/<pathSlug(worktreeRoot)>/agent-hierarchy.json` |
| 2 | `repo-user` | `~/.claude/agent-hierarchy/projects/<pathSlug(mainRoot)>/agent-hierarchy.json` |
| 3 | `repo` | `<worktreeRoot>/.claude/agent-hierarchy.json` |
| 4 | `repo` | `<mainRoot>/.claude/agent-hierarchy.json` |
| 5 | `global` | `~/.claude/agent-hierarchy.json` |

**From a normal checkout** the two-element lists collapse to one and the order is
1, 3, 5 — identical to today.

### 4.1 Deviation from the literal request — read this, it is a real choice

The reported ask was `worktree → repo root (committed) → repo root (user) →
global`, i.e. **location-major with committed ahead of user-level at the main
root**. The table above is location-major but keeps `repo-user` ahead of `repo`
*within each location*, because that is the established precedence
(`ROSTER_LEVELS`, spec 0001): an uncommitted personal roster outranks the
committed one. Inverting it only at the main root would make precedence depend
on where you are standing.

Reading the request as "walk further up when nothing is found here", not as a
re-litigation of level precedence. It only differs in one situation — a
main-root committed roster AND a main-root user roster both present, with
nothing at the worktree. **If the user meant the literal order, this is the line
to change; flag it back rather than silently reinterpreting again.**

## 5. `pathSlug` — an addition, not a correction

The brief suggests `repo-user` keying on `pathSlug(worktreeRoot)` is itself a
latent bug. It is not: a per-worktree personal roster is a coherent thing to
have, and it is what any existing worktree-created `repo-user` config is keyed
under today.

**Do not repoint `repo-user` at `pathSlug(mainRoot)`.** That would silently
orphan every existing worktree-keyed config — a config that works today would
stop being found, with no error, which is a worse failure than the one being
fixed. The main-root slug is *added* as candidate #2 (§4), which reaches the
main-root config while leaving worktree-keyed ones working.

## 6. Write path stays put

`rosterLevelPaths` is unchanged, so `roster create --level repo-user` from a
worktree still writes the worktree-keyed path. Zero write-side behaviour change
in this spec — deliberately, because the read fix is the reported bug and a
write relocation is independently arguable.

**Consequence to make visible, and the one UX change required here:** creating a
roster in a worktree produces one the sibling worktrees will not see. Wherever
`roster.mjs` reports the created/resolved config location, it must print the
**absolute path**, not just the level name, so this is legible rather than
mysterious.

**OPEN QUESTION (user's call, not mine):** should `roster create` from a
worktree default to writing at the *main* root, since a roster is usually a
property of the project rather than of one worktree? Arguments both ways;
whichever way it goes it is a separate change, not a widening of this one.

## 7. Tests

New file `agent-hierarchy/tests/test-roster-worktree.sh` (or a section in
`test-roster-levels.sh`, which already drives `rosterLevelPaths` at `:32`).
Fixture: `git init` a temp repo, commit, `git worktree add <wt>`, redirect
`HOME` to a temp dir so `global`/`repo-user` paths are sandboxed (the pattern
`test-roster-levels.sh` already uses). Shelling out to `git` in a **test** is
fine — the §3 no-subprocess rule is about `lib-config.mjs`, not the harness.

| # | Scenario | Assert |
|---|----------|--------|
| T1 | Roster ONLY at `<mainRoot>/.claude/agent-hierarchy.json`; resolve from inside the worktree | non-null; `level === "repo"`; `path` is the main-root path |
| T2 | Roster ONLY at `~/.claude/agent-hierarchy/projects/<pathSlug(mainRoot)>/…`; resolve from the worktree | non-null; `level === "repo-user"`; `path` is the main-root-slug path |
| T3 | Rosters at BOTH `<worktreeRoot>/.claude/…` and `<mainRoot>/.claude/…`, distinguishable (e.g. different member counts); resolve from the worktree | the **worktree's** is returned |
| T4 | Normal checkout, roster at its `<root>/.claude/…`; no worktree anywhere | unchanged: `level === "repo"`, root path — regression guard |
| T5 | Worktree, nothing at either location, roster only at `~/.claude/agent-hierarchy.json` | `level === "global"` |
| T6 | Submodule (`.git` FILE pointing under `.git/modules/…`) | `mainCheckoutRoot` returns null; resolution identical to pre-fix. Guards §3's `worktrees` check. |
| T7 | Worktree whose `.git` file is unreadable/malformed | returns null, no throw; resolution degrades to pre-fix |
| T8 | **Bare-repo-linked worktree.** `git clone --bare <src> <tmp>/repo.git`; `git -C <tmp>/repo.git worktree add <tmp>/wt`; place a roster at `<tmp>/.claude/agent-hierarchy.json` — i.e. beside the bare repo, the position the un-guarded code would bind to. Resolve from `<tmp>/wt`. | that roster is **NOT** returned (falls through to `global`, or null). Guards §3.1. |

**Falsifiability, stated honestly:**

- **T3, T4, T5 are OUTCOME assertions.** They hold under the pre-fix code by
  construction (T3/T4 because `findGitRoot` already returns the worktree root as
  candidate #1; T5 because `global` has no repo dependency). Do not try to make
  them fail pre-fix. Their value is regression protection.
- **T1 and T2 are the falsifiable pair** — they are the bug. They are *expected*
  to return null against pre-fix code.
- **T6, T7** exercise `mainCheckoutRoot`'s null paths; falsifiable against a
  naive implementation that omits the `worktrees` check or the try/catch.
- **T8 is falsifiable against the §3.1 defect specifically** — it is expected to
  fail if the `basename(commonDir) !== ".git"` guard is dropped. It is the only
  test here that targets a mistake this spec made rather than one the original
  code made.

**NEEDS-EVIDENCE (for the Implementor, before landing):** confirm by execution
that tests **T1** and **T2** actually fail against the pre-fix code — write them,
run them on the unmodified tree, record the failure, then fix. If either
*passes* pre-fix, stop and report: it means resolution reaches the main root by
some path this spec has not accounted for, and §1's causal claim is wrong. This
spec asserts that they fail; it does not demonstrate it, because the Architect
does not execute.

**NEEDS-EVIDENCE, second item:** confirm **T8** fails with the §3.1 guard removed
and passes with it present. The claim that the guard is load-bearing is
Reviewer-traced but, like the above, not demonstrated by me.

## 8. Acceptance

- From a worktree with a roster only at the main checkout (either level),
  `resolveRoster` returns it and `msg`/`roster` no longer say "no agent roster
  defined".
- `resolveRoster`, `rosterLevelPaths`, and every existing test behave identically
  in a non-worktree checkout.
- A bare-repo-linked worktree pushes **no** main-root candidate (§3.1).
- `lib-config.mjs` still imports nothing from `node:child_process`.
- `findGitRoot`, `hierarchyDir`, and `teamPrefixInfo` are untouched.

## 9. Confidence and escalation

Medium-high. The mechanism is small, contained, and degrades to current
behaviour on every unknown. Two things are judgement, not derivation, and are
flagged in place rather than settled silently: the §4.1 precedence deviation from
the literal request, and the §6 write-location question. Neither warrants
Ultra-Advisor escalation — they are product-preference calls for the user, not
hard technical ones.

One correction has already been folded in (§3.1) after review; it is noted at the
point of change rather than silently rewritten.
