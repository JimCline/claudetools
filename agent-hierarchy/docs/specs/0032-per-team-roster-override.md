# 0032 — Per-team roster override, and the two-resolver split

Status: proposed
Author: Architect (claudetools-architect)
Date: 2026-09-02
Revision: r3 (2026-09-02) — `add --team X` no longer auto-vivifies; see §3.4b.
Reverses an assertion r2 introduced. Prior: r2 (four amendments after the
Implementor's build), r1 (original). Every amendment is marked at the point of
change; §11 records what the errors have in common.
Issue: JimCline/claudetools#2
Files: `agent-hierarchy/hooks/lib-config.mjs`, `agent-hierarchy/hooks/roster.mjs`,
`agent-hierarchy/tests/test-roster-team-override.sh` (new),
`agent-hierarchy/tests/test-roster-worktree.sh` (extend)

Supersedes nothing. Extends 0027 (worktree roster resolution), whose design **is**
in the current code — verified by reading, not by trusting 0027's `proposed`
status line: `mainCheckoutRoot` (`lib-config.mjs:333-358`),
`rosterLevelCandidates` (`:361-372`), and the two-level loop in `resolveRoster`
(`:477-504`) all match 0027 §3/§4 as written.

---

## 1. What the issue reports, and what is actually true

Issue #2 makes three claims. **One is correct, one is correct-in-symptom but
wrong-in-cause, and one is false as stated against current code.** They must be
separated, because the fix for each is different and fixing the one the issue
names would not fix the one the reporter hit.

### 1.1 Claim A — "one roster template per repo, whole-level replace" — TRUE

`resolveRoster(cwd, team)` (`:477`) takes `team` and uses it for **exactly one
thing**: `teamPrefixInfo(cwd, team)` at `:479`, which yields the *naming prefix*
for derived member names. The member list itself comes from `data.roster.members`
(`:492`) — a single key, with no team dimension anywhere in the lookup.

So `--team X` scopes the live instance and the peer-name prefix. It does not, and
today cannot, scope *which members exist*. The issue's description of the
practical effect is exact: the only way to give a new named team a different
member list is to overwrite the shared `roster` key that every other team reads.

This is the primary ask and §3 addresses it.

### 1.2 Claim B — "repo-user collapses a worktree back to its main repo's identity" — FALSE

The opposite is true. `rosterLevelPaths` (`:316-324`) keys `repo-user` on
`pathSlug(findGitRoot(cwd))`, which in a worktree is the **worktree's** root, and
`rosterLevelCandidates` (`:361-372`) orders the worktree's own slug *first* and
appends the main root's slug only as a lower-precedence fallback. 0027 §5
explicitly refused to repoint `repo-user` at the main root, and that refusal
survives in the code.

There is no collapse. A worktree-local `repo-user` roster is found, and is found
*ahead* of the main root's.

### 1.3 Claim C — "a level present-but-empty wins and shadows a populated lower level" — FALSE of `resolveRoster`, TRUE of `resolveConfig`

`resolveRoster`'s loop body explicitly skips such a file:

```js
if (!r || typeof r !== "object" || Array.isArray(r) || !Array.isArray(r.members) || r.members.length === 0) continue;
```
`lib-config.mjs:492`

A file that exists with unrelated content, or with an empty member list, cannot
win the roster. 0027's test matrix never covered this (T1–T8 has no
"empty file at a higher-precedence level" case), so the guard was not *proven* —
but it is present and correct by reading.

**The reporter's symptom is nevertheless real, and §2 is where it comes from.**

> **[r2] Note the asymmetry this creates, because it is the root of the §4
> contradiction the Implementor found.** `resolveRoster` uses *first **useful**
> candidate* — it keeps scanning past a file that exists but carries nothing it
> needs. §4 as originally written gave the sibling resolver the opposite rule,
> *first **existing** candidate*. Praising the first guard in this section and
> then specifying its inverse two sections later is the defect; see §4.3.

---

## 2. The actual defect: two resolvers over the same files, only one of which got 0027

This is the finding that resolves the discrepancy the brief asked me to settle.
It is not implementation drift from 0027, not a second roster path, and not the
MCP server (`agent-hierarchy/mcp/server.mjs` is a thin stdio wrapper that execs
`roster.mjs` — grep confirms it holds no resolution logic of its own).

**`lib-config.mjs` contains two independent resolvers reading the same config
files under three different keying schemes:**

| Resolver | Level | Path expression | Worktree-aware? |
|---|---|---|---|
| `resolveRoster` (`:477`) | `repo-user` | `pathSlug(worktreeRoot)`, then `pathSlug(mainRoot)` | **yes** (0027) |
| `resolveRoster` | `repo` | `<worktreeRoot>/.claude/…`, then `<mainRoot>/.claude/…` | **yes** (0027) |
| `resolveConfig` (`:563`) | `repo-user` | `rosterLevelPaths(cwd)["repo-user"]` — `pathSlug(worktreeRoot)` only (`:569`) | **NO** |
| `resolveConfig` | `project` | `projectConfigPath(cwd)` = `join(resolve(cwd), ".claude", …)` (`:278-281`, used at `:568`) | **NO**, and not even repo-root-based — it is keyed on raw **cwd** |
| `resolveConfig` | `user` | `userConfigPath()` | n/a |

0027 changed `resolveRoster` to use `rosterLevelCandidates`. It did not change
`resolveConfig`, which still calls the single-path `rosterLevelPaths` and
`projectConfigPath`. `rosterLevelCandidates` has exactly two call sites
(`resolveRoster` itself, and nothing else).

### 2.1 Consequence, which is what the reporter saw

`resolveConfig` is what produces `roles` (per-role `model`, `effort`, `dispatch`,
`peer`), `route`, `enabled`, `handoffs`, `msgs`, and `teamAlias`. `resolveRoster`
produces the member list. **From inside a worktree these disagree:** the member
list resolves to the main checkout (0027 working as designed) while every
per-role model/effort setting at the main checkout is invisible and each role
silently falls back to `ROLE_DEFAULTS` (`:594`).

That is the issue's *"silently falling back to unrelated built-in defaults"* —
verbatim the reported symptom, arrived at by the opposite mechanism from the one
the issue names. The issue says the main root's config wrongly wins; in truth the
main root's config wrongly **loses**, and the built-in defaults win.

### 2.2 And this is where "present-but-empty wins" is real

`resolveConfig` gates on `layers.length === 0` (`:598`) to return
`configured: false`. `loadScope` (`:507`) returns a layer for **any** readable
JSON object, regardless of content. So a worktree-local
`.claude/agent-hierarchy.json` holding a single unrelated field — the issue's
example — flips `configured` to `true` while every role stays at its default,
because the role loop skips layers with no `roles` key (`:669`).

A consumer branching on `configured` then treats an all-defaults roles table as
deliberately configured rather than absent. Presence alone changed the answer.
That is the reporter's second observation, located precisely.

### 2.3 The `projectConfigPath` cwd-keying is a third trap, and I am scoping it OUT

`projectConfigPath` resolves against raw `cwd`, not the git root. Running a hook
from any subdirectory of the repo makes the `project` layer silently vanish, in a
normal checkout, with no worktree involved. This is a live bug and it is adjacent,
but it is **not** what issue #2 reports and folding it in would widen this spec
into a rework of `resolveConfig`'s layering.

**Flagged, not fixed. It should get its own issue.** Named here so the next reader
does not conclude §2's table is a complete account of `resolveConfig`'s
correctness.

---

## 3. Fix 1 — per-team roster override (the primary ask)

### 3.1 Schema

A config file at any level may carry, alongside the existing `roster` key, an
optional `rosters` map keyed by team alias:

```jsonc
{
  "version": 1,
  "roster": {                       // the default template — UNCHANGED semantics
    "route": "…",
    "layout": "auto",
    "members": [ … ]
  },
  "rosters": {                      // NEW, optional
    "hotfix": {
      "route": "…",
      "layout": "auto",
      "members": [ { "role": "implementor", "model": "sonnet" } ]
    }
  }
}
```

Each value under `rosters` has **exactly the same shape** as `roster` — same
validator, same keys, no new fields. This is deliberate: it makes
`validateRosterBlock` (`lib-roster.mjs:168`) reusable verbatim and means a user
can move a block between `roster` and `rosters.<name>` without editing it.

> **[r2] Amendment — invalid `rosters` keys are ignored SILENTLY, not warned.**
> r1's prose here promised a `validateTeamAlias` check on each key, "ignored with
> a warning", while §3.2's code sample implemented no such check. The Implementor
> built the code sample and reported the mismatch. **The code sample was right and
> the prose was wrong; the prose is withdrawn.**
>
> Two reasons, and the second is the real one. First, `resolveRoster` has no
> warnings channel — it returns a plain result object, unlike `resolveConfig`'s
> `warnings[]` — so honouring the promise meant inventing a channel for one
> message. Second and decisive: **a `rosters` key that fails `validateTeamAlias`
> is unreachable by construction.** `team` reaches `resolveRoster` only after the
> CLI has validated it (`lib-config.mjs:531-537` documents exactly this), so an
> invalid key can never equal an active team name and can never be selected. It
> is dead config, not misapplied config. Warning about an entry that cannot
> affect any outcome is noise.
>
> T9 stands as the Implementor wrote it: no throw, falls through to the default.
>
> **[r3] This reasoning is about a key that is *syntactically* invalid, and it
> does NOT extend to a well-formed key nobody meant to create.** §3.4b draws that
> line — the difference matters, and r2 did not notice there was one.

The default team (`team === null`) has no alias and therefore **never** matches a
`rosters` entry. It reads `roster`, exactly as today. There is intentionally no
reserved key such as `"default"`: it would create two ways to spell the same
thing and a precedence question between them.

### 3.2 Resolution — two passes, and why

`resolveRoster(cwd, team)` gains a team-override pass **ahead of** the existing
loop. Both passes walk the full `ROSTER_LEVELS` × candidate-path order from
0027 §4; they differ only in which key they read.

```js
export function resolveRoster(cwd, team) {
  const candidates = rosterLevelCandidates(cwd);
  const { prefix, alias, source } = teamPrefixInfo(cwd, team);

  // Pass 1 (NEW): a roster defined for THIS team name, at any level.
  // Pass 2: the default template, at any level — today's behaviour, unchanged.
  const passes = team ? [team, null] : [null];

  for (const teamKey of passes) {
    for (const level of ROSTER_LEVELS) {
      for (const path of candidates[level]) {
        if (!existsSync(path)) continue;
        let data;
        try { data = JSON.parse(readFileSync(path, "utf8")); } catch { continue; }
        if (!data || typeof data !== "object" || Array.isArray(data)) continue;
        const r = teamKey ? pickTeamRoster(data, teamKey) : data.roster;
        if (!r || typeof r !== "object" || Array.isArray(r) || !Array.isArray(r.members) || r.members.length === 0) continue;
        return {
          level, route: r.route, layout: r.layout || "auto",
          members: rosterMemberNames(r.members, prefix),
          path, teamAlias: alias, teamAliasSource: source,
          teamKey,                     // NEW — null means the default `roster` key
        };
      }
    }
  }
  return null;
}

/** The `rosters[team]` block at one level, or null. No alias validation — see §3.1 [r2]. */
function pickTeamRoster(data, team) {
  const map = data.rosters;
  if (!map || typeof map !== "object" || Array.isArray(map)) return null;
  return Object.prototype.hasOwnProperty.call(map, team) ? map[team] : null;
}
```

**The two-pass ordering is a real design choice and it is mine, not derived.**
It means a per-team roster at `global` beats the default `roster` at `repo`.

The alternative — one pass, checking `rosters[team] ?? roster` per file — would
let a repo-level default shadow a global per-team override, and the user would
have to place every override at or above the level of the highest-precedence
default. That defeats the feature: the issue's whole complaint is that getting a
team-specific list forces you to touch a shared, higher-precedence file.

The principle: **team-specificity is a stronger signal than location-specificity,
because the team name was named explicitly in this invocation, whereas the level
was not.** Location precedence still fully decides which of two competing
per-team blocks wins, and which of two competing defaults wins. It only stops
deciding *across* the two kinds.

If the user disagrees, the single change is to collapse `passes` to one iteration
and read `pickTeamRoster(data, team) || data.roster` in the body. Flagging rather
than silently picking — see §8.

### 3.3 `configured`/no-match behaviour

If `team` is given and no `rosters[team]` exists anywhere, pass 2 finds the
default and the result is **bit-for-bit what happens today**. A named team with
no override is not an error and must not warn — that is the normal case for every
existing team.

**[r3] Note the scope of this rule: it governs *resolution*, not *writes*.** A
`--team X` with no override resolves happily to the default; a `--team X` write
against a non-existent override fails (§3.4b). Those are consistent, because
reading asks "what applies" and writing asks "what am I modifying" — the same
distinction §3.4 point 1 turns on.

### 3.4 Write path — the hazard that must not be got wrong

`roster.mjs` has twelve `rosterLevelPaths(cwd)[level]` sites that read a level
file, mutate `data.roster.members`, and write it back
(`:185, 966, 989, 1004, 1036, 1088, 1123, 1136, 1268` and the `add`/`edit` bodies
at `:1006-1029` / `:1038-1073`). Every one of them hard-codes `data.roster`.

**Left as-is, `roster add --team hotfix` would resolve the `hotfix` override for
its level choice via `targetLevel()` (`:148-154`) and then append the member to
`data.roster` — silently editing the shared default that the user was explicitly
trying not to touch.** That is a data-corrupting outcome and is strictly worse
than the bug being fixed.

Required, and non-optional:

1. **[r2 — CORRECTED]** `targetLevel()` (`:148`) returns
   `{ level, wasDefaulted, teamKey }`, where **`teamKey` is the active `--team`
   argument (`teamArg`), NOT the `teamKey` field of the `resolveRoster` result.**

   > r1 said to take it from the `resolveRoster` result at `:151`. **That was
   > wrong, and wrong in exactly the direction this section exists to prevent.**
   > The Implementor caught it and deviated; the deviation is approved and is now
   > the spec.
   >
   > Traced: when `--team X` is active but no `rosters.X` exists *anywhere yet*,
   > pass 1 finds nothing, pass 2 returns the default with `teamKey: null`. So the
   > **first ever** `roster add --team X` would have written to the shared
   > `data.roster`. r1's own motivating paragraph, three lines above, describes
   > precisely this corruption.
   >
   > The underlying confusion: **resolution and write-targeting answer different
   > questions.** `resolveRoster` answers "what applies right now"; a write must
   > answer "what did the user ask to modify". Deriving the second from the first
   > makes the write target depend on whether the thing being created already
   > exists — which is backwards for any create operation. `teamArg` is correct by
   > construction and needs no liveness of the override.
   >
   > `level` and `wasDefaulted` still come from the `resolveRoster` result as
   > before — those genuinely are "what applies now" questions.

2. **[r3 — AMENDED]** Add one helper in `roster.mjs`, and route **every**
   config-mutating site through it — no site may reach `data.roster` directly.
   **It does not create anything; see §3.4b for why the `create` option r2
   specified is withdrawn.**

   ```js
   /** The roster container to read/write at this level for the active team scope.
       Returns null when the container does not exist — callers fail with the
       "run init first" guard (§3.4b). Never auto-creates. */
   function rosterContainer(data, teamKey) {
     if (!teamKey) return data.roster || null;
     return data.rosters && data.rosters[teamKey] ? data.rosters[teamKey] : null;
   }
   ```
3. `init --team X` creates `rosters.X`, never `roster`. `init` with no `--team`
   keeps writing `roster`. **[r3] `init` is now the *only* thing that creates a
   container, for either kind.**
4. `remove`/`dismiss --also-config` (`removeConfigMember`, `:182-193`) uses the
   same container. Removing the last member of a `rosters.X` block leaves an
   empty `members: []`, which §3.2's guard treats as no-match, so the team falls
   back to the default. **Do not delete the empty block** — an empty override and
   an absent override then differ, and only `roster remove --team X --all` (not
   in scope here) should be able to erase the block itself.
5. Wherever `roster.mjs` prints the resolved/created location it already prints
   the absolute path (0027 §6). It must now also print **which container**
   (`roster` vs `rosters.<name>`), because path alone no longer identifies what
   was edited.

Point 4's "leave the empty block" and point 3's "no `--team` still writes
`roster`" are the two rules that keep an existing single-team repo behaving
identically.

### 3.4a Read sites are in scope too — `create --commit` hydration **[r2]**

The Implementor found `create --commit`'s `allStrings` hydration
(`roster.mjs:1268-1272`) reads `data.roster.members` directly by level, ignoring
any active `--team` scope, and reported it as an adjacent gap for a future spec
on the grounds that §3.4's list covers *writes* and this is a read.

**Ruling: it is in scope, it must be fixed here, and it is not parkable.** Two
reasons:

1. **`:1268` is explicitly in §3.4's own site list.** r1's prose framed the list
   as read-mutate-write sites, which made excluding a read-only one defensible —
   the Implementor's reading was reasonable and the framing was mine. But the
   site was named, and §3.4's actual rule is *nothing may reach `data.roster`
   directly*, which this does.
2. **Without it the feature does not work for its own motivating use case.**
   Issue #2's scenario is "create a team with members X, Y, Z". That runs
   `create --plan` then `create --commit --verified <names>`. If `--plan`
   resolved from `rosters.hotfix` but `--commit` hydrates from `data.roster`, the
   names do not match and the commit **fails** — loudly, so nothing is corrupted,
   but the end-to-end path the whole spec exists to enable is broken.

Fix: `:1266-1270` takes the container via `rosterContainer(rosterData, teamArg)`
instead of `rosterData.roster`, and `rosterRoute` comes from the same container.
Falling back to the default when the container is absent is correct **for this
read** and matches §3.2 pass 2 — a team with no override commits against the
default, which is what `--plan` would have resolved too.

New test **T17** (§6) covers the round trip, which is the only way this is
caught: `--plan` and `--commit` must agree about which container they read.

### 3.4b `add --team X` does NOT auto-vivify — `init --team X` first **[r3, NEW]**

**The Reviewer flagged that `add --team X` auto-creates `rosters.X` (with an
inherited route) when it does not exist, that this is spec-silent, and that
`add --team typo` therefore writes a stray block. They are right on the substance.
It is not spec-silent, though — it is worse than that: r2's T18 asserts it, and
r2's `rosterContainer({create: true})` specified it. This is my defect, not an
unwritten default, and r3 reverses it.**

**Ruling: `add --team X` fails when `rosters.X` does not exist**, with the same
"run `roster.mjs init` first" guard the general case already uses at `:1006`.
`init --team X` is the only way to bring a container into being.

Three reasons, the second decisive:

1. **Consistency.** `add` against a level with no `roster` already fails that way
   (`:1006`, a guard restored earlier this round). Having `add` refuse to create
   the default container but silently create a team container is an inconsistency
   with no justification behind it — and I never argued for one, because I never
   noticed I was introducing it.
2. **A typo'd team name has the worst possible feedback profile.**
   `add --team hotfx` writes `rosters.hotfx`, which **can never be selected**:
   `resolveRoster` matches only an *active* team name, and nobody will ever
   activate `hotfx`. So the user gets no error at write time and no error at any
   later time — the config is permanently inert and permanently silent. Compare a
   typo under the init-first rule: `add --team hotfx` fails immediately, naming
   the missing container. **The failure mode of auto-vivification here is not "an
   extra file entry"; it is a configuration that looks applied and never is.**
   That is the same class of silent-wrongness this entire spec exists to remove
   (§2.1, §2.2), which is why shipping it inside the fix would be poor.
3. **The inherited route makes it magic as well as silent.** r2 never specified
   where an auto-created block's `route` comes from; the implementation inherited
   it. An implicit container with implicitly-sourced fields is two unspecified
   behaviours stacked, and neither was argued.

**Why r2 got this wrong, stated because the reasoning error is reusable.** T18
existed to guard §3.4 point 1's corruption fix — to prove the first
`add --team X` does not write to `data.roster`. I wrote it asserting *creates
`rosters.X`*, having conflated **"must not write to the default"** with **"must
create the override."** Failing satisfies the first without the second, and
failing is in fact the *stronger* assertion: "writes nothing anywhere" is a
tighter guarantee than "writes to the right place." The corruption guard never
needed auto-vivification; I attached it without noticing it was a separate
decision that wanted its own argument.

**§3.1's silent-ignore ruling does not extend here, and r2 should have seen the
distinction.** That ruling is about a key that is *syntactically invalid* and
therefore unreachable — dead config that cannot mislead. A well-formed key nobody
meant to create is *reachable in principle* and looks exactly like real config.
"Cannot ever apply because it is malformed" and "does not apply because you
mistyped it" are different situations; the first is safely ignorable, the second
is precisely what a user needs told.

T18 is rewritten accordingly (§6).

---

## 4. Fix 2 — close the `resolveConfig` worktree gap

`resolveConfig` (`:563-574`) switches to the candidate lists, matching
`resolveRoster`:

```js
const candidates = rosterLevelCandidates(cwd);
// `global`/`repo`/`repo-user` here map to resolveConfig's `user`/`project`/`repo-user`
// scope names. Names differ for historical reasons (spec 0001); the files are the same.
const userPath = candidates.global[0];
const projectPaths = candidates.repo;
const repoUserPaths = candidates["repo-user"];
```

and `loadScope` is called for the **first existing** path in each level's list,
preserving the one-layer-per-scope shape that `layers`, `sources`, and `shadowed`
all depend on:

```js
const firstExisting = (paths) => paths.find((p) => existsSync(p)) || null;
```

**Deliberately NOT merging across candidates within a level.** `shadowed`
(`:681`) is computed from how many *scopes* defined a role; letting one scope
contribute two layers would change what `shadowed` means and would surface in
`/hierarchy` output. Most-specific-existing-wins, one layer per scope, is the
minimal change that fixes the gap.

### 4.1 Scope-name divergence is real and is left alone

`resolveConfig` calls them `user`/`project`/`repo-user`; `ROSTER_LEVELS` calls
them `global`/`repo`/`repo-user`. These are the same three files under two
vocabularies, and the `project` one is additionally keyed differently (§2.3).
Unifying the vocabulary is a rename across warning strings, `sources` values, and
`/hierarchy` output that users read. **Out of scope. Do not do it here.** The
comment in the snippet above exists so the next reader is not misled.

### 4.2 What Fix 2 does NOT change

- `projectConfigPath`'s cwd-keying stays (§2.3). Fix 2 replaces the *call* at
  `:568` with the repo-root-based `candidates.repo`, which incidentally also
  corrects the subdirectory case for this call site — but the function keeps its
  other caller at `:920` and its current definition. Note the behaviour change in
  the commit message: running a hook from a subdirectory now finds the repo's
  project config where before it found none. That is a fix, but it is a
  *behaviour change* and must not be described as a no-op.
- `configured`'s presence-only gate (§2.2) stays. Making `configured` mean
  "something was actually configured" is a semantic change with unknown blast
  radius across `/hierarchy` and the route gate. **NEEDS-EVIDENCE, §7 item 3.**

### 4.3 The T15 contradiction — the Implementor is right, and T15 is amended **[r2]**

**r1 contradicted itself and the Implementor found it.** §6's T15 asserted that a
worktree-local file carrying only `teamAlias` would let the main root's `roles`
through; §4's `firstExisting` and §4.2's explicit refusal to touch the
presence-only gate both say it will not. The Implementor built §4's literal code,
verified the behaviour empirically both ways before deciding, wrote T15 to assert
what actually happens, and reported rather than silently picking. That is the
correct handling and the judgment was right.

**Ruling: keep `firstExisting`. T15 is amended to assert the real behaviour, and
the residual is recorded as a named limitation rather than a test.**

Why not implement T15's stated outcome:

- Doing so means **merging within a scope** — per-key candidate scanning — which
  §4 rejects on `shadowed`'s behalf, and which changes `layers`, `sources`, and
  `/hierarchy`'s user-visible output. That is a design change to a public surface,
  not a test fix.
- It would **pre-empt §7 item 3**, the evidence I asked for and have not received.
  Deciding the merge question before knowing what consumes `configured` is
  exactly the ordering error this spec is supposed to avoid.
- **T14 — the actual reported symptom — is fixed either way.** Fix 2's value is
  the case where the worktree has no config file at all, which is the common one.

**The residual, stated plainly because it is not exotic.** A worktree that has
*any* `.claude/agent-hierarchy.json` — including one containing only a
`teamAlias`, which is what `roster alias --level repo` writes — blocks the main
root's `roles` for that scope, and every role silently falls to `ROLE_DEFAULTS`.
That is a plausible sequence, not a contrived one: set a team alias in a
worktree, lose your model configuration, get no diagnostic. **This wants its own
issue, tracked alongside §2.3.** It is §2.2's mechanism surviving Fix 2, which
§4.2 said it would — but §4.2 said it in the abstract, and this is the concrete
form the user meets.

The honest summary: Fix 2 fixes "worktree with no config" and does not fix
"worktree with a nearly-empty config". Both were in §2's diagnosis; only the first
is in §4's remedy.

---

## 5. What must not change

- `findGitRoot`, `hierarchyDir`, `teamPrefixInfo`, `pathSlug`, `mainCheckoutRoot`,
  `rosterLevelPaths`, `rosterLevelCandidates` — all untouched (0027 §2 non-goals
  still hold).
- `ROSTER_LEVELS` — no new level names. Per-team is a new *axis*, not a new level.
- `lib-config.mjs` still imports nothing from `node:child_process`.
- A repo with no `rosters` key anywhere resolves identically to today, at every
  level, in a worktree and in a normal checkout.
- **[r3]** `add`'s existing "run `init` first" precondition, for the default
  container — §3.4b extends that guard, it does not replace or weaken it.
- 0027 §6's open question — *should `roster create` from a worktree default to
  writing at the main root?* — is **still open and is still the user's call.**
  This spec does not resolve it and must not be read as having resolved it. §3.4
  changes which *container* a write targets, never which *file*.

---

## 6. Tests

New `agent-hierarchy/tests/test-roster-team-override.sh`, plus additions to
the 0027 worktree tests. Fixture pattern is the existing one: temp repo, `HOME`
redirected to a temp dir.

| # | Scenario | Assert |
|---|----------|--------|
| T1 | `roster` at `repo` with members A,B; no `rosters`. Resolve with `--team hotfix` | members A,B; `teamKey === null` — **regression guard, the no-override case** |
| T2 | `roster` at `repo` (A,B) **and** `rosters.hotfix` at `repo` (C). Resolve `--team hotfix` | members C only; `teamKey === "hotfix"` |
| T3 | Same file, resolve with **no** team | members A,B; `teamKey === null` |
| T4 | Same file, resolve `--team other` (no such key) | members A,B — falls through to default |
| T5 | `rosters.hotfix` at **`global`**, `roster` at **`repo`**. Resolve `--team hotfix` | the `global` per-team block wins — **this is the §3.2 two-pass decision; it is the test that fails under the single-pass alternative** |
| T6 | `rosters.hotfix` at `global` AND at `repo`. Resolve `--team hotfix` | the `repo` one wins — location precedence still decides *within* a pass |
| T7 | `rosters.hotfix` present with `members: []` | falls through to the default `roster` (empty is no-match, §3.2) |
| T8 | `rosters` is a JSON array, or a string | ignored, no throw; default `roster` resolves |
| T9 | `rosters` key that fails `validateTeamAlias` | ignored, no throw, **no warning** (§3.1 [r2]); default resolves |
| T10 | `roster add --team hotfix --role implementor` against a file where `rosters.hotfix` **already exists** | **`data.rosters.hotfix.members` grew; `data.roster.members` is byte-identical** — §3.4's corruption guard |
| T11 | `roster add` with **no** `--team`, `roster` exists | `data.roster.members` grew; `data.rosters` untouched |
| T12 | `roster init --team hotfix` on a file holding only `roster` | creates `rosters.hotfix`; `roster` untouched |
| T13 | `roster remove --team hotfix` removing the last member | `rosters.hotfix.members === []`, block still present (§3.4 point 4) |
| T14 | Worktree; per-role `model` config ONLY at `<mainRoot>/.claude/agent-hierarchy.json`; resolve from the worktree | `resolveConfig` returns that model, `sources[role] !== "default"` — **the §2.1 gap; expected to FAIL pre-fix** |
| T15 **[r2 — AMENDED]** | Worktree; worktree-local config exists carrying ONLY `teamAlias`; main root sets `roles` | **roles are `ROLE_DEFAULTS`; the main root is NOT consulted.** The worktree file wins its scope by existing (§4's `firstExisting`). Asserts the §4.3 residual deliberately. **r1 asserted the opposite and was self-contradictory** — do not "fix" this back without changing §4 first. |
| T16 | Normal checkout, config at `<root>/.claude/…`, cwd = root | `resolveConfig` output byte-identical to pre-fix — regression guard for Fix 2 |
| T17 **[r2]** | `rosters.hotfix` at `repo` (members C). `create --plan --team hotfix`, take the reported names, then `create --commit --team hotfix --verified '<those names>' --roster-level repo` | **commit succeeds**; committed members are C's. Guards §3.4a — fails where `--plan` reads `rosters.hotfix` and `--commit` hydrates from `data.roster`. |
| T18 **[r3 — REWRITTEN]** | File with `roster` (A,B) and **no** `rosters` key. `roster add --team hotfix --role implementor`, no `--level` | **FAILS with the "run `roster.mjs init` first" guard.** `data.roster.members` byte-identical (still A,B), **and `data.rosters` is still absent** — nothing written anywhere. Guards §3.4b **and** §3.4 point 1's corrected `teamKey` at once: it still fails against r1's `resolveRoster`-derived `teamKey` (which appended to `data.roster`), and now also against r2's auto-vivify. **r2 asserted the opposite outcome; see §3.4b for why that was wrong.** |
| T19 **[r3 — NEW]** | Same file. `roster init --team hotfix` **then** `roster add --team hotfix --role implementor` | both succeed; `rosters.hotfix.members` has the member; `data.roster.members` byte-identical. The supported path T18 refuses, proving the guard blocks the mistake and not the workflow. |

**Falsifiability, stated honestly:**

- **T5, T10, T14 are the falsifiable core.** T5 fails under the rejected
  single-pass design; T10 fails against any implementation that leaves the
  `data.roster` write sites alone; T14 fails against current code and is the
  §2.1 defect.
- **[r2] T17 and T18 exist because the build found gaps no existing test could
  reach** — T10–T13 all use fixtures where the override already exists, so the
  steady state was covered and the create path was not. A suite that only tests
  the steady state cannot catch a create-path bug.
- **[r3] T18 and T19 are a pair and must stay one.** T18 alone proves a refusal;
  T19 proves the refusal is not simply "the feature is broken". A guard test
  without its companion happy-path test cannot distinguish a working guard from a
  dead code path.
- **T1, T3, T16 are outcome assertions** that hold pre-fix by construction. They
  are regression protection. Do not try to make them fail first.
- T7/T8/T9 target mistakes *this spec* could invite (treating empty as valid,
  trusting `rosters`' type), not mistakes the existing code makes.
- **T15 is a limitation-pinning test**, not a fix-verifying one. Its job is to
  make §4.3's residual visible and to fail loudly if someone changes
  `firstExisting` without reading §4.3.

---

## 7. NEEDS-EVIDENCE — I do not execute; these are for the Implementor

1. **Confirm T14 fails against the unmodified tree.** Write it, run it before
   changing anything, record the failure. §2.1 is traced by reading, not
   demonstrated. **If T14 *passes* pre-fix, stop and report** — it means
   `resolveConfig` reaches the main root by some route this spec has not
   accounted for, and §2's entire diagnosis is wrong.
2. **Confirm the reporter's actual scenario.** Issue #2 is a narrative, not a
   repro. Before landing, reproduce: worktree + a main-root roster + a named
   team, and record which of §2.1 / §2.2 the user actually hit. If neither
   reproduces, the issue describes a fourth mechanism and this spec is
   incomplete — report rather than proceeding.
3. **Blast radius of `configured` (§4.2).** `grep -rn "configured" agent-hierarchy/`
   and report every consumer and what it does when `configured` is true with
   all-default roles. Do not change `configured`; just report. That decides
   whether §2.2 needs its own follow-up spec. **[r2] This item is now also what
   gates §4.3's residual** — same mechanism, and the follow-up issue §4.3 asks
   for should be filed with this item's findings attached.
4. **Enumerate the `data.roster` access sites before editing.** §3.4 lists the
   ones a grep found; confirm the list is complete
   (`grep -n "\.roster\b" agent-hierarchy/hooks/roster.mjs`) and report any site
   §3.4 missed. A missed site is a silent corruption of the default template.
   **[r2] This covers read sites as well as writes** — §3.4a exists because
   `:1268` was a read, and the original "write sites" framing is what let it
   through. The rule is *no direct `data.roster` access*, either direction.
5. **[r3] Report every other `add`-like path that could create a container.**
   `init`, `add`, `edit`, `layout`, `alias` — confirm that after §3.4b only
   `init` brings a `roster` or `rosters.<name>` block into existence, and report
   any other site that would auto-create one. §3.4b is a rule about the whole
   surface, not a patch to one call site, and r2's defect was exactly a
   creation path nobody had enumerated.

---

## 8. Decisions I made, and the one I am handing back

**Made, with rationale in place:**

- Two-pass team-before-level resolution (§3.2) rather than per-file fallback.
- `rosters` as a sibling map with the identical block shape (§3.1) rather than a
  new level name or a `team` field inside `roster`.
- Empty `members` means no-match and falls through (§3.2, §3.4 point 4).
- Fix 2 takes first-existing-candidate per scope, not a merge (§4), **and [r2]
  keeps that rule under challenge — see §4.3.**
- **[r2]** Write-container comes from `teamArg`, not from the resolution result
  (§3.4 point 1).
- **[r2]** Invalid `rosters` keys are ignored silently (§3.1) — **[r3]** which
  does *not* extend to well-formed keys nobody meant to create (§3.4b).
- **[r2]** `create --commit` hydration is in scope, not deferred (§3.4a).
- **[r3]** `add --team X` requires `init --team X` first; no auto-vivification,
  anywhere, by anything but `init` (§3.4b).
- §2.3 (`projectConfigPath` cwd-keying) and §4.1 (scope-name divergence) flagged
  and deliberately excluded. §4.3's residual joins them.

**Handed back — the user's call, not mine:**

**§3.2's precedence.** Should a per-team roster at a *lower* level outrank the
default at a *higher* one? I chose yes, and argued it from the feature's purpose,
but this is a product-behaviour preference and someone could coherently want
location precedence to dominate absolutely. The change is two lines (§3.2), so it
is cheap to invert — but it should be inverted by a decision, not discovered by
surprise. **Ask before landing if there is any doubt.**

Also still open, inherited and untouched: 0027 §6's write-location question (§5).

---

## 9. Acceptance

1. A config with no `rosters` key resolves identically to pre-fix at every level,
   with and without `--team`, in a worktree and a normal checkout (T1, T3, T16).
2. `rosters.<team>` at any level is selected when that team is active (T2).
3. A named team with no matching `rosters` entry silently gets the default **on
   resolution** (T4).
4. A per-team block outranks a default at a higher level (T5); two per-team
   blocks are ranked by the 0027 level order (T6).
5. Malformed `rosters` (wrong type, bad alias key, empty members) degrades to the
   default without throwing and without warning (T7, T8, T9).
6. **No `roster` code path reaches `data.roster` directly while a `--team` scope
   is active — reads included** (T10, T11, T12, T13, T17, T18).
7. **[r3]** `add --team X` against a non-existent `rosters.X` **fails** with the
   "run `init` first" guard and writes **nothing** — not to `roster`, not to
   `rosters` (T18). `init --team X` then `add --team X` succeeds (T19).
8. **[r3]** `init` is the only command that creates a roster container, of either
   kind (§7 item 5).
9. `create --plan --team X` and `create --commit --team X` read the same
   container (T17).
10. `resolveConfig` finds the main checkout's config from inside a worktree when
    the worktree has **no** config file (T14).
11. T15's residual is asserted, not fixed, and §4.3 is filed as an issue.
12. `lib-config.mjs` imports nothing from `node:child_process`.
13. `findGitRoot`, `hierarchyDir`, `teamPrefixInfo`, `rosterLevelPaths`,
    `rosterLevelCandidates`, `mainCheckoutRoot` are untouched.
14. `ROSTER_LEVELS` is unchanged.
15. Every pre-existing test in `agent-hierarchy/tests/` still passes.
16. All five §7 NEEDS-EVIDENCE items are answered in the implementation report.

---

## 10. Confidence and escalation

**Fix 1 (§3): high.** Every defect found in review has been in the
write/read-targeting layer, which is where r1 already said the risk was
concentrated — and each has narrowed the rule rather than complicating it. r3's
rule is the simplest of the three: *only `init` creates; everything else requires
an existing container.*

**Fix 2 (§4): medium, and narrower than r1 claimed.** §4.3 is the honest
statement of what it does and does not fix. §7 items 1 and 2 remain the checks
that could falsify the diagnosis.

**No Ultra-Advisor escalation recommended.** Nothing here is a security, auth,
migration, or concurrency call; the blast radius is one plugin's config
resolution, guarded by an unchanged-by-default path and a regression suite. The
open item in §8 is a product preference for the user, not a technical question
that more reasoning would settle.

---

## 11. Error record

r1 shipped four defects; r2 shipped one more. Four of the five share one shape —
the fifth appearance in this thread (0027 §3.1, 0030 S1, 0031 §3).

- **[r1] T15 vs §4/§4.2** — a test asserting a fix the same document had
  explicitly declined to make.
- **[r1] §3.4 point 1's `teamKey`** — a *write target* derived from a *resolution
  result*, so the target depended on whether the thing being created already
  existed. True of the steady state, false of the create path.
- **[r1] §3.1's warning promise vs §3.2's code** — prose describing behaviour the
  adjacent code sample did not implement.
- **[r2] T18's auto-vivification** — a test written to guard corruption, which
  quietly asserted a *second, unargued* behaviour on the way. I conflated "must
  not write to the default" with "must create the override"; failing satisfies
  the first without the second, and is the stronger assertion.

The shape: **a locally true statement standing in for a claim it does not
support**, where the gap opens only on a path the surrounding prose was not
considering — the first write, the empty file, the create rather than the update,
the typo rather than the intended name. Every sentence was checkable; what was
missing each time was asking *which path does this actually run on*.

**[r3] The fourth instance has a variant worth naming separately**, because it
is a failure mode of *fixing* rather than of designing: a corrective test can
smuggle in a new decision. T18 was written to close a real gap and did close it —
but it also silently settled an adjacent question (does `add` create?) that had
never been asked. A test added during a fix deserves the same "what else is this
asserting?" scrutiny as the fix itself, and gets less of it precisely because it
arrives framed as a guard.

Three process notes worth keeping:

1. **The Implementor caught three of these by building the literal spec and
   reporting divergence rather than smoothing it over**, verifying T15
   empirically both ways first. A builder who silently "fixed" any of them would
   have buried the contradiction in working code.
2. **The Reviewer caught the fourth**, and caught it in a test I had just added —
   the place least likely to be re-examined, since a new test reads as the
   product of scrutiny rather than a subject for it.
3. **§7 item 4 originally said "write sites", and that framing let §3.4a's read
   site through.** When a rule is *no direct access*, an evidence item asking
   only about writes confirms the wrong thing. Widened at r2; §7 item 5 [r3]
   applies the same lesson to creation paths.
