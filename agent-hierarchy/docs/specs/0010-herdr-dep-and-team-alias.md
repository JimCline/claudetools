# 0010 — herdr external-binary dependency + team-name alias

Status: **specified, fully closed, implementation in progress.**
All three design forks resolved (amendment (a)); all five NEEDS-EVIDENCE items
resolved (amendment (b)); site inventory corrected from 9 to 10 and re-verified
exhaustively (amendment (c)); test 28 waived and an alias/role-token collision
closed (amendment (d)); the collision rule's module placement fixed after a
verified circular-import crash (amendment (e)). No open questions.

> **Amended 2026-08-23 (a)** — the Orchestrator resolved all three open forks;
> each is now a decision with its rationale recorded at the point of change,
> and §13 is closed. (1) §2.3 — the inverted herdr case is **silent and out of
> scope**. (2) §4.3 — ignoring a `global`-level alias is **confirmed**. (3)
> §7.4 — the live-team warning **describes and stops**, with no disband
> recommendation; exact text now specified.

> **Amended 2026-08-23 (b)** — all five NEEDS-EVIDENCE items came back.
> §3.3's mismatch is **confirmed live**, not hypothetical. §4.4's character set
> is **tightened** to exclude `.` and `_`. §2.7 carries exact append text.
> **One dissent recorded:** the Orchestrator asked me to delete §4.5's
> behavior-change paragraph on the grounds that no test exercises it. I have
> **not** deleted it, and §4.5 explains why — "no test covers it" is a
> coverage gap, not evidence the change is invisible, and item 1 proved the
> change is real. The paragraph is reframed and a regression test is added
> instead (§11 test 13). *(Orchestrator accepted this reasoning; the dissent
> is settled in favour of keeping the paragraph.)*

> **Amended 2026-08-23 (c)** — **spec-defect: §3.1's inventory was incomplete.**
> Review found a **tenth** derivation site, `hooks/msg.mjs:141`, which the
> Implementor could not have rewired because this spec never named it. The
> implementation was faithful to an incomplete list. Row 10 added to §3.1,
> `msg.mjs` added to §9, and §3.1a records **why** the original sweep missed
> it — the grep matched an identifier (`repoBasename`) rather than the shape
> of a derivation, and `msg.mjs:141` inlines `basename(resolved.cwd)` with no
> such identifier. The inventory has been **re-verified by two independent
> methods** (§3.1b): ten is the complete set, there is no eleventh. §11 gains
> test 14, a cheap grep-based completeness guard that would have caught this
> and will catch any future re-introduction.

> **Amended 2026-08-23 (d)** — **test 28 is WAIVED as unachievable**, not
> merely hard: `msg.mjs roster` cannot observe which prefix was computed,
> because `roleFromName`'s unanchored substring match always recovers the role
> from a `<prefix>-<role>` name regardless of prefix. Mechanism recorded at
> §11 test 28 so nobody re-adds it. Verifying that surfaced a **real gap this
> feature introduces**: the same unanchored matching mis-resolves roles
> whenever the *prefix* contains a role token, which was unreachable before
> Feature B and is now one setup prompt away. §4.4's suffix rule is replaced
> by a containment rule and §11 gains test 29. §8 records the underlying
> `roleFromName` bug as out of scope with reasoning.

> **Amended 2026-08-23 (e)** — **spec-defect: (d)'s rule was unimplementable
> as placed.** It required `validateTeamAlias` in `lib-config.mjs` to call
> `roleFromName` in `lib-hier.mjs`, but `lib-hier.mjs` already imports `ROLES`
> from `lib-config.mjs` and consumes it at its own module top level, so the
> reverse static import is a circular-init deadlock — confirmed live as
> `ReferenceError: Cannot access 'ROLES' before initialization`, and
> unavoidable by statement placement because ES bindings hoist. §4.4 gains a
> **Module placement** block: `ROLE_TOKENS` and `roleFromName` **relocate to
> `lib-config.mjs`**, next to `peerName`. This costs nothing — both are pure
> leaves with a single in-file caller each and no external importer — and it
> corrects a pre-existing misplacement rather than working around one. §4.4
> also gains worked examples showing the rule correctly *accepts* `advisor`
> while rejecting `ultra-advisor`, which is the concrete justification for
> stating it behaviorally rather than as a blacklist.

Two independent features in one doc. They do not interact: Feature A is a
presence check for an external binary, Feature B is a naming prefix. Neither
depends on the other; they can be implemented and reviewed in either order, or
split across two Implementor dispatches.

---

## 1. Goals

**Feature A.** `agent-hierarchy` shells out to `herdr`, an external CLI the
user installs separately. Nothing checks whether it is present. A missing
binary surfaces only as a bare "command not found" from deep inside a
`create --spawn` or `spawn-one` run, after panes may already have been split.
Add a check that is loud, early, and impossible to trip for a user who does
not use herdr.

**Feature B.** Peer session names are derived as `<repo-basename>-<role>`.
For a repo named `claudetools` that yields `claudetools-architect`. The user
wants a short per-repo alias — `ct-architect` — chosen once during roster
setup.

Verbatim user request for Feature B, which is the requirement source:

> "I want to also create a way to have a repo/project alias to the repo name
> so that agent names can have shorter aliases for the team. For example,
> during setup of the project/repo for a team roster, ask the user to confirm
> that the team name is the repo (folder) name or provide an alias, whatever
> the user types. For example, this project is called 'claudtools' but I might
> want to abbreviate that as ct, so the team would use ct as the prefix for
> the agents"

This formalizes something users already do by hand. A live `ListAgents` on
this machine at spec time showed sessions named `bps-orchestrator`,
`ab-orchestrator`, `ctl-orchestrator`, `aegis-arch1`, `exp1-9c` — hand-typed
short prefixes, because the derived prefix is the full folder name and nothing
offers an alternative. Feature B is not introducing a new practice; it is
giving an existing one a supported path.

---

## 2. Feature A — herdr presence check

### 2.1 Correction to the dispatching brief: there is no roster transport field

The brief asked for a check that runs "only when the resolved roster's
transport is herdr". **No such field exists.** Transport is not configured on
the roster at all — it is detected from the environment at spawn time:

```
hooks/roster.mjs:150   if (process.env.HERDR_ENV === "1") return "herdr";
```

`detectTransport()` returns `herdr` when `HERDR_ENV=1`, else `tmux` if a tmux
server is reachable, else `terminal` (SKILL.md § Create step 1 documents the
same ordering). The roster's `route` (`peer`/`subagent`) and `layout`
(`auto`/`columns`/`grid`) are the only transport-adjacent stored fields, and
neither names a transport.

This is a better outcome than the brief assumed. The correct predicate is
environmental, needs no roster resolution, and has zero false positives by
construction — see §2.2.

### 2.2 The predicate

Warn if and only if **both**:

1. `process.env.HERDR_ENV === "1"` — the session is running inside a herdr
   environment, so herdr is unambiguously relevant; and
2. no executable named `herdr` is found on `PATH`.

A user who has never touched herdr never sets `HERDR_ENV`, so condition 1 is
false and they are never warned. This satisfies the brief's
"herdr-check false-positive avoidance for non-herdr-transport rosters"
acceptance criterion more strictly than a roster-derived predicate could: it
does not depend on roster state at all, so a user with a peer-routed roster on
tmux or terminal is also silent.

Deliberately **not** part of the predicate: whether a roster exists, whether
its route is `peer`, whether a `team.json` is live. Being inside a herdr
environment without the herdr binary is a broken environment regardless.

### 2.3 RESOLVED (a) — the inverted case is deliberately silent

The predicate says nothing about the user who **has** herdr installed but is
running outside it (`HERDR_ENV` unset), and who might have wanted a herdr
team. They silently get the `tmux`/`terminal` fallback.

**Decision: stay silent. Do not spec, do not implement.** The documented
fallback chain already works, so nothing is broken in that state — it is not
the bug this feature fixes. A "you could be using herdr" nudge is speculative
noise nobody asked for, fired at users whose sessions are working correctly.

This is a scope boundary, not an oversight. A future reader tempted to "finish
the job" by adding the symmetric warning should read this paragraph first: the
asymmetry is the point. A missing binary in a herdr environment is a broken
setup; a working fallback outside one is not.

### 2.4 How to probe PATH — no subprocess

Do **not** shell out to `which herdr`. This runs on every SessionStart,
including `compact`, and a hook that spawns a process on every session start
pays that cost forever.

Add to `hooks/lib-roster.mjs` (it already owns transport-adjacent helpers) or
`hooks/lib-hier.mjs`:

```js
/**
 * True when an executable named `herdr` is on PATH. Pure fs — never spawns a
 * process, because this runs on every SessionStart including `compact`.
 */
export function herdrOnPath() { … }
```

Implementation: split `process.env.PATH` on `path.delimiter`, skip empty
entries, and for each candidate `join(entry, "herdr")` test
`accessSync(candidate, constants.X_OK)` inside a try/catch, returning `true`
on the first success. Return `false` if `PATH` is unset or empty. On Windows
this returns `false` for a `herdr.exe`; that is accepted — herdr is not
supported there and no other part of this plugin handles Windows executable
extensions either.

**Confirmed (b), NEEDS-EVIDENCE item 4:** `command -v herdr` →
`/opt/homebrew/bin/herdr`, `herdr --version` → `herdr 0.8.2`. It is a literal
PATH executable, not a shell function or alias, so a PATH walk can see it.
The probe design is valid as specified.

Cost is a handful of `access` syscalls, sub-millisecond, which settles the
brief's caching question: **run it every session, cache nothing.** A cache
would need an invalidation story, and its failure mode is the bad one — a
cached "missing" persisting after the user installs herdr, telling them a lie
they cannot clear without knowing about the cache. The check is cheaper than
the cache would be.

### 2.5 Where the warning is emitted

`hooks/sessionstart.mjs`, in the plain-top-level branch (the `else` that
builds the directive), appended to `context` exactly the way `teamSweepNote`
already is:

```js
if (herdrNote) context += "\n\n" + herdrNote;
```

Constraints:

- **Not** in the `role` branch. A `--agent <role>` member session does not
  spawn teams; warning it is noise.
- **Not** in the `!resolved.configured` nudge branch. An unconfigured user has
  a more basic problem and one message is enough.
- Inside a `try`/`catch` that swallows everything. This hook has exactly one
  stdout write and a throw would cost the user their whole directive
  injection — see the file's header comment. A failed herdr probe must never
  do that.
- It **does not block**. SessionStart hooks in this plugin are not blocking
  and this must not become the first one that is.

Exact text:

```
ah: HERDR_ENV=1 but no `herdr` binary was found on PATH. Roster spawning
(/agent-roster create, roster.mjs spawn-one) will fail when it tries to place
panes. Install herdr, or unset HERDR_ENV to fall back to tmux/terminal.
```

### 2.6 Second check at the point of use

The SessionStart warning is advisory and can be scrolled past. Add a hard,
local check where the binary is actually about to be invoked: in
`hooks/roster.mjs`, wherever `detectTransport()` has returned `"herdr"` and a
herdr command is about to run — the `create --spawn` path (via
`layoutAndLaunch`), the `spawn-one` path, and `layout-splits` (which already
`fail()`s on a non-herdr transport).

Behavior: `fail()` with

```
ah: transport is herdr (HERDR_ENV=1) but no `herdr` binary is on PATH — cannot
place panes. Install herdr, or unset HERDR_ENV to use tmux/terminal.
```

This IS a hard block, and that is correct and not in tension with §2.5: it
blocks a command that cannot possibly succeed, rather than blocking session
start. Failing here also prevents the worse outcome of splitting panes and
then discovering the launch cannot run.

Put the check next to the existing `detectTransport() !== "herdr"` guard style
so there is one obvious place a reader finds both.

### 2.7 Manifest and docs

Confirmed by the Orchestrator's `claude-code-guide` research dispatch, cited
here rather than re-derived: the Claude Code plugin manifest has **no**
first-class field for an external-binary dependency. `plugin.json`'s
`dependencies` covers plugin-to-plugin version constraints only, and the
omission is deliberate — binary presence, version, and permissions vary too
much across OS and package manager for the schema to model. Anthropic's own
LSP plugins (e.g. `rust-analyzer-lsp`) state the requirement in README and
marketplace metadata and let it fail at runtime.

So there is nothing to add to the manifest schema. Instead:

**`agent-hierarchy/.claude-plugin/plugin.json`** — current values confirmed
(NEEDS-EVIDENCE item 3):

- `description` is `"Multi-agent role hierarchy, each on the right model."`
  Append, do not replace:
  `"Multi-agent role hierarchy, each on the right model. Optional herdr transport for pane-based teams."`
- `keywords` is `["subagent", "delegation", "orchestration", "models", "review", "cost"]`.
  Append `"herdr"`.

**Root `.claude-plugin/marketplace.json`** — its top-level `description` is
`"Claude Code plugins by Jim Cline — context-window discipline and related tooling."`
and there is no top-level `keywords` field.

**Do not touch that top-level description, and do not add top-level
keywords.** It describes the whole marketplace across every plugin; one
plugin's optional binary dependency has no business in it, and a `herdr`
keyword at marketplace level would misdescribe the other plugins. The
standing "edit both files together" rule is about the **version bump** (§2.8)
and about per-plugin metadata — not about pushing one plugin's details up to
repo scope.

If `marketplace.json` carries a per-plugin entry for `agent-hierarchy` with
its own `description`, mirror the plugin.json change **there**. If it does
not, the version bump is the only edit that file needs.

**`agent-hierarchy/README.md`** — a **Prerequisites** section stating that
herdr is optional, needed only for the herdr transport, that without it the
plugin falls back to tmux and then to plain terminal, and where to install it.
`herdr 0.8.2` is the version this was verified against; state a minimum only
if the README already does so for other tools, otherwise name no version.

### 2.8 Version bump

Both `agent-hierarchy/.claude-plugin/plugin.json` and the root
`.claude-plugin/marketplace.json` must have their version bumped together.
This repo has been bitten by bumping only one.

---

## 3. Feature B — the call-site inventory

This is the complete set of places a naming prefix is derived. **It is ten
sites across eight files, corrected from nine in amendment (c)** — see §3.1a
for how the tenth was missed and §3.1b for how ten was then proven complete.

### 3.1 Derivation sites — these must resolve the alias

| # | File:line | Expression | Derives from |
|---|---|---|---|
| 1 | `hooks/lib-config.mjs:306` | inside `resolveRoster` | **git root** |
| 2 | `hooks/lib-config.mjs:623` | `basename(resolved.cwd)` in `buildDirective` | **cwd** |
| 3 | `hooks/lib-config.mjs:711` | `basename(resolved.cwd)` in `statusReport` | **cwd** |
| 4 | `hooks/roster.mjs:104` | `basename(findGitRoot(cwd) \|\| resolve(cwd))`, module-level const | **git root** |
| 5 | `hooks/pretooluse-ultra-gate.mjs:102` | `basename(resolve(cwd))` | **cwd** |
| 6 | `hooks/pretooluse-ultra-gate.mjs:118` | `basename(resolve(cwd))` — a *second* derivation in the same file | **cwd** |
| 7 | `hooks/pretooluse-msg-gate.mjs:75` | `basename(resolve(cwd))` | **cwd** |
| 8 | `hooks/pretooluse-route-gate.mjs:239` | `basename(resolve(cwd))` | **cwd** |
| 9 | `hooks/posttooluse-roster.mjs:45` | `basename(resolve(cwd))` | **cwd** |
| **10** | **`hooks/msg.mjs:141`** | **`roster(dir, resolved, basename(resolved.cwd))` — inlined into the `roster` call, in the `case "roster":` branch** | **cwd** |

Plus `hooks/sessionstart.mjs:113`, which does not derive its own value but
passes `basename(resolved.cwd)` into `buildStateBlock` — it must be changed
alongside them.

Line numbers are from the pre-implementation tree and will drift as the change
lands; the *expressions* are the durable identifiers.

### 3.1a Why site 10 was missed (amendment (c))

Recorded because the failure was in the search method, not in the reading, and
the same method would miss it again.

The original inventory was built by grepping for the **identifier**
`repoBasename` across the tree. Sites 1–9 all either declare or consume a
variable of that name, so they matched. Site 10 does not:

```js
const ros = roster(dir, resolved, basename(resolved.cwd));
```

The derivation is **inlined directly into the argument list** and never bound
to a name, so an identifier grep cannot see it. `msg.mjs` did not appear in
the inventory or in §9's file list at all, which is why the Implementor —
correctly building exactly what this spec named — left it untouched. This is a
spec-defect, not an implementation defect.

**The lesson generalizes: grep for the shape of the thing, not for a name
someone chose to give it.** An identifier-based sweep silently under-reports
wherever an expression is used inline, and reports its under-count with the
same confidence as a complete result.

### 3.1b Proof that ten is complete (amendment (c))

Re-verified by two independent methods, both run against the tree after the
first nine rewires had landed.

**Method 1 — shape sweep.** Every occurrence of `basename(` in `hooks/`:

| Occurrence | Verdict |
|---|---|
| `lib-config.mjs:253`, `lib-hier.mjs:8` | comments |
| `lib-config.mjs:263` (`hierarchyDir`, `basename(resolve(base))`) | **path** derivation, out of scope (§8) |
| `lib-config.mjs:354` (`basename(repoRoot)` in `teamPrefixInfo`) | the **one legitimate** prefix derivation — this is the resolver itself |
| `lib-hier.mjs:135` (`basename(name)`), `lib-hier.mjs:315` (`basename(f.path)`) | operate on **file paths** (message-file name regex, archive rename), not repo identity |
| `msg.mjs:22` | the `import` statement |
| **`msg.mjs:141`** | **site 10** |

No other `basename(` in `hooks/` feeds a naming consumer.

**Method 2 — consumer call-site audit.** Every call site of every function
in §3.2 was inspected for what it passes as the prefix argument. All of them
pass a bound `repoBasename`/`prefix`/`teamPrefix(...)` value except
`msg.mjs:141`. `teamMemberByName` and `teamMembersForRole` were checked and
excluded: they take a name or a role, never a prefix, so they are not
derivation sites.

Both methods agree: **ten sites, no eleventh.** §11 test 14 converts this from
a one-time audit into a standing assertion.

### 3.2 Consumers — these take the prefix as a parameter and must NOT change

`peerName`, `resolvedPeerTargets`, `resolvedPeerTarget`, `rosterMemberNames`,
`roleLines`, `peerConfirmationParagraph` in `lib-config.mjs`;
`roleForPeerName`, `roster`, `buildStateBlock` in `lib-hier.mjs`;
`namedMembers` in `roster.mjs`.

Every one already accepts the prefix as an argument. **This is the seam.**
Feature B changes what is passed in, at ten call sites, and changes no
function signature and no consumer body. `peerName` in particular stays
byte-for-byte as it is — spec 0001 §7 already committed to that and there is
no reason to break it.

### 3.3 CONFIRMED (b) — two derivations that disagree, a real bug

Sites 1 and 4 use the **git root** basename. Sites 2, 3, 5–10 use the **cwd**
basename. These are the same string only when the session's cwd *is* the repo
root.

**Demonstrated live** (NEEDS-EVIDENCE item 1), executed against unmodified
code with `cwd = ~/git/repos/claudetools/agent-hierarchy`:

| Site | Result |
|---|---|
| `resolveRoster` (via `findGitRoot`) | `claudetools` |
| `pretooluse-route-gate.mjs:239` (`basename(resolve(cwd))`, no `findGitRoot` anywhere near it) | `agent-hierarchy` |

Different strings. So from any subdirectory, `resolveRoster` names members
`claudetools-architect` while the route gate looks up
`agent-hierarchy-architect` — **the gate cannot recognize its own roster's
member names.** This is not hypothetical and not caused by Feature B; it
predates it.

Site 10 is the same bug in a user-visible place — with the caveat, discovered
in amendment (d), that `msg.mjs roster`'s *output* happens to be masked by
`roleFromName`'s substring fallback, so the divergence is real in the computed
value but not observable in that command's output. See §11 test 28.

It is in scope because the fix — one resolver, one definition of "this repo" —
is exactly the change Feature B needs anyway, and because leaving it would
force the alias to be threaded into two mutually inconsistent notions of repo
identity.

The unification resolves it by construction: `teamPrefix` (§4.1) uses
`findGitRoot` for every site, so all ten agree.

---

## 4. Feature B — the resolver

### 4.1 New export in `hooks/lib-config.mjs`

```js
/**
 * The naming prefix for this repo's agents: the configured team alias if one
 * is set, else the repo's directory basename. The SINGLE definition of the
 * `<prefix>-<role>` prefix — every naming site calls this and none derives a
 * basename itself.
 */
export function teamPrefix(cwd) { … }
```

Behavior:

1. `repoRoot = findGitRoot(resolve(cwd)) || resolve(cwd)` — the same
   expression `resolveRoster` and `roster.mjs` already use, so git-root wins
   as the one definition of "this repo".
2. Walk the roster levels in `ROSTER_LEVELS` order (`repo-user`, `repo`,
   `global`) via `rosterLevelPaths(cwd)`, reading each existing file. The
   first level carrying a **valid** top-level `teamAlias` string wins — but
   see §4.3, `global` is skipped.
3. Unreadable file, non-object root, absent key, or a value failing §4.4
   validation → fall through to the next level. Never throw.
4. Nothing found → return `basename(repoRoot)`.

Add a companion returning provenance, for `show` and `statusReport`:

```js
/** `{prefix, alias, source}` — `source` is the level name, or "default". */
export function teamPrefixInfo(cwd) { … }
```

`alias` is `null` and `source` is `"default"` when no alias resolved.
`teamPrefix` is the one-value wrapper. Do not fork the resolution logic
between the two — one implementation, the wrapper calls the other.

### 4.2 Rewiring the ten sites

Every site in §3.1 becomes `teamPrefix(cwd)` for whichever cwd that file
already has in hand. No signature changes anywhere.

Three specific notes:

- `pretooluse-ultra-gate.mjs` derives the basename **twice** (sites 5 and 6).
  Collapse to one `teamPrefix(cwd)` call, not two.
- `roster.mjs`'s site 4 is a module-level const computed once at import from
  the argv-parsed cwd. It stays module-level; only its right-hand side changes.
- **Site 10 (`msg.mjs:141`)** becomes
  `roster(dir, resolved, teamPrefix(resolved.cwd))`. `msg.mjs` already imports
  `basename` from `node:path` (line 22) solely for this call — if no other use
  remains after the rewire, **drop the now-unused import** rather than leaving
  it as a false signal that the file still derives a prefix.

`sessionstart.mjs` passes `teamPrefix(resolved.cwd)` into `buildStateBlock`.

### 4.3 DECISION (confirmed, amendment (a)) — a `teamAlias` at `global` level is ignored

An alias is inherently repo-specific: "ct" means `claudetools` and nothing
else. A `teamAlias` sitting in `~/.claude/agent-hierarchy.json` would rename
the agents of **every repo on the machine**, which no user typing "ct" into a
setup prompt for one project could reasonably intend.

So `teamPrefix` reads `teamAlias` from `repo-user` and `repo` only. A
`teamAlias` at `global` is ignored, and `roster.mjs alias --set` refuses
`--level global` (§5.2).

This deliberately does **not** introduce a second precedence system, which the
brief warned against. It is the same ordered `ROSTER_LEVELS` walk that
`resolveRoster` performs, minus the one level that cannot hold a meaningful
value. And it composes with spec 0009: a global-scope value silently renaming
this repo's agents is precisely the class of surprise 0009 exists to gate.

**Amended (a): the Orchestrator reviewed and confirmed this reading.** It was
originally flagged as a fork because it is an interpretation of user intent
rather than a fact about the code. It is now settled: an alias is a property
of one repo, not a machine-wide default, and the `--level global` refusal is
correct. Do not re-open it as a "missing feature".

### 4.4 Alias validation

The alias becomes a live session name: it reaches `herdr agent start --name`,
`ListAgents` matching, and SendMessage `to`. It must be safe in all three, and
— added in amendment (d) — it must not collide with role-token matching.

**Character set (amended (b)).** Accept only:

```
/^[A-Za-z0-9][A-Za-z0-9-]{0,31}$/
```

- must start alphanumeric;
- 1–32 characters;
- letters, digits, and `-` thereafter;
- **rejects** `.`, `_`, whitespace, `/`, quotes, `$`, backticks, and every
  shell metacharacter.

**Why `.` and `_` are excluded (NEEDS-EVIDENCE item 5).** herdr 0.8.2 exposes
no `--dry-run`, `--validate`, or other no-op flag on `agent start` or
`agent rename`, so whether it accepts those characters cannot be tested
without spawning a live agent into a real pane. That side effect is not worth
incurring to settle a regex, so the character set goes conservative instead.

The asymmetry is what makes this the right default: **loosening later is
non-breaking** (every alias valid under the strict rule stays valid under a
looser one), while an optimistic rule that herdr rejects fails at spawn time —
after the user has named their team, run `init`, and started a create. A
validator that is slightly too strict costs one retry at setup; a validator
that is too permissive costs a failed spawn discovered live.

**Role-token collision (amendment (d)) — replaces the old suffix rule.**

Additionally reject any alias for which, for some role in
`PEER_ELIGIBLE_ROLES`:

```js
roleFromName(peerName(alias, role)) !== role
```

Rationale. `roleFromName` matches with an **unanchored substring** test —
`for (const [token, role] of ROLE_TOKENS) if (name.includes(token)) return
role;` — and returns the *first* token found anywhere in the name, in array
order. So an alias that contains a role token anywhere makes derived names
ambiguous: alias `architect` produces `architect-reviewer`, and `roleFromName`
resolves it to `architect` rather than `reviewer`. Every role-less roster
record for that team then resolves to the wrong role.

This **supersedes** the earlier rule ("reject an alias ending in `-<role>`"),
which was too narrow — the hazard is containment anywhere in the string, not
just at the end. Delete the suffix rule; keep only this one, which subsumes it.

**State it behaviorally, as above — never as a blacklist of role words.** The
worked examples below are the reason, not a stylistic preference. `ROLE_TOKENS`
is confirmed to be:

```js
[["ultra-advisor","ultra-advisor"], ["architect","architect"],
 ["reviewer","reviewer"], ["implementor","implementor"],
 ["advisor","ultra-advisor"]]
```

- Alias **`ultra-advisor`** → `peerName("ultra-advisor","architect")` =
  `"ultra-advisor-architect"`. The scan hits `"ultra-advisor"` at index 0
  before reaching `"architect"`, returning `ultra-advisor ≠ architect` →
  **rejected**. Correct.
- Alias **`advisor`** → `"advisor-architect"` does *not* contain
  `"ultra-advisor"`, so the scan reaches `"architect"` → returns `architect` ✓.
  Likewise for reviewer and implementor. And
  `peerName("advisor","ultra-advisor")` = `"advisor-ultra-advisor"` **does**
  contain `"ultra-advisor"` → returns `ultra-advisor` ✓. So `advisor`
  **passes all four and is genuinely safe.**

A blacklist of role-looking words would have wrongly rejected `advisor`. The
behavioral rule admits exactly the aliases that actually work, and it stays
correct if `ROLE_TOKENS` ever changes. It also covers the array-order
asymmetry without enumerating it: a name containing `"ultra-advisor"` shadows
the three tokens below it, `"architect"` shadows two, `"reviewer"` shadows one.

**Module placement (amendment (e)) — required, not optional.**

`validateTeamAlias` lives in `lib-config.mjs` and needs `roleFromName`, which
today lives in `lib-hier.mjs`. **That import direction cannot work.**
`lib-hier.mjs` already imports `ROLES` from `lib-config.mjs` (`lib-hier.mjs:23`)
and consumes it at its own module top level (`lib-hier.mjs:28`,
`export const MSG_ROLES = ["orchestrator", ...ROLES];`). Adding the reverse
static import is a circular-init deadlock — confirmed live as
`ReferenceError: Cannot access 'ROLES' before initialization` — and no
statement placement inside `lib-config.mjs` avoids it, because ES module
bindings hoist. (`lib-config.mjs`'s existing header comment about its safe
`lib-roster.mjs` cycle explains the difference: that cycle is safe *because*
neither module touches the other's export at module top level, a precondition
`lib-hier.mjs` violates.)

**Therefore: relocate `ROLE_TOKENS` and `roleFromName` from `lib-hier.mjs`
into `lib-config.mjs`, adjacent to `peerName`.**

This is nearly free, and the cost was verified rather than assumed:

- `ROLE_TOKENS` (`lib-hier.mjs:42-48`) is `const`, **not exported**, with
  exactly **one** reference in the whole tree: `lib-hier.mjs:410`.
- `roleFromName` (`lib-hier.mjs:408-412`) is exported but **no file imports
  it**; its only caller is `roleForPeerName` at `lib-hier.mjs:429`, in the
  same file.
- Both are **pure leaves** — `ROLE_TOKENS` is a bare array literal and
  `roleFromName` reads nothing else.

So **`lib-config.mjs` must gain no new import as a result of this move**, and
no new edge appears in the module graph. If an implementation finds itself
adding an import to `lib-config.mjs` here, something has gone wrong — stop and
report. The only other edit is adding `roleFromName` to `lib-hier.mjs`'s
**already-existing** line-23 import from `lib-config.mjs`. No new import
statement anywhere in the repo.

Placement rationale beyond mechanics: `lib-config.mjs` already owns the role
vocabulary — `ROLES`, `ROLE_LABELS`, `PEER_ELIGIBLE_ROLES`, `ROLE_DEFAULTS`,
`VALID_MODELS_BY_ROLE`, `TIER`, `tierOf`, `peerName`, `resolvedPeerTargets` —
and `roleFromName` is **the inverse of `peerName`** (name→role against
role→name). It belongs beside it. A third "shared leaf" module for two symbols
the vocabulary owner should already hold was considered and rejected: it
fragments the vocabulary for no gain.

**This relocation corrects a pre-existing misplacement rather than working
around one.** `roleFromName` is pure role-vocabulary logic that was sitting in
the hierarchy/messaging module; the collision rule merely exposed it.

**Where rejection happens.** At write time (`roster.mjs alias --set`) a
`fail()` naming the rule that was violated — character set or role collision,
distinctly, so the user knows which. At read time (`teamPrefix` finding a
hand-edited invalid value) fall through to the next level and ultimately the
basename — never throw, never block a session. Emit a warning through the
existing `resolveConfig` warnings array so the user learns why their hand-edit
was ignored, rather than silently getting the old names back.

### 4.5 Zero change when no alias is set — with one real exception

Required by the brief and load-bearing. With no `teamAlias` anywhere,
`teamPrefix` returns `basename(repoRoot)`, which is byte-identical to what
sites 1 and 4 produce today. Existing configs gain no key, need no migration,
and `CONFIG_VERSION` does **not** change — `teamAlias` is an additive optional
key and an older plugin reading a config that has one simply ignores it.

**The exception is real and must stay documented.** Sites 2, 3, 5–10 move from
cwd-basename to git-root basename. For a session whose cwd is the repo root —
the overwhelming majority — that is the same string and the change is
invisible. For a session started from a **subdirectory** it is a genuine
user-visible behavior change: those sites start producing a different prefix
than they do today. It is a *fix* (§3.3 confirms the current behavior is
broken), but a fix is still a change. Note it in the changelog; do not
describe this work as purely additive.

> **Dissent recorded (b), since accepted.** The Orchestrator initially asked
> for this paragraph to be deleted, reasoning from NEEDS-EVIDENCE item 2 that
> since no existing test exercises a subdirectory cwd, the change is
> "test-invisible … nothing exercises it either way."
>
> That inference does not hold. Item 2 established that **the test suite has
> no subdirectory coverage** — a gap in the tests, not a property of the
> system. Item 1 independently established, by live execution, that the
> behavior difference is **real**. "No test would catch it" and "it does not
> happen" are different claims, and only the first is supported. Deleting the
> paragraph would leave the spec asserting a zero-change guarantee that item 1
> disproves, and would drop the changelog note for the one class of user who
> sees a difference.
>
> The correct response to a coverage gap is to close it, so §11 test 13 adds
> the subdirectory case that should have existed all along. **The Orchestrator
> reviewed this reasoning and accepted it**; the paragraph stays.

---

## 5. Feature B — persistence

### 5.1 Where the alias is stored, and why

Top-level `teamAlias` in the level's `agent-hierarchy.json`, a **sibling of**
`roster`, not a key inside it:

```json
{
  "version": 1,
  "teamAlias": "ct",
  "roster": { "route": "peer", "layout": "auto", "members": [ … ] }
}
```

The reason is mechanical, not aesthetic. `roster.mjs`'s `init` does:

```js
const data = readLevelFile(path);
data.version = data.version || CONFIG_VERSION;
data.roster = { route, members: [] };
```

It **replaces `data.roster` wholesale and preserves every other top-level
key**. A `teamAlias` inside `roster` would be destroyed by the next `init`;
a top-level sibling survives it. Since `init` is documented as a whole-level
replace of the roster block (SKILL.md § init, closing note), and since an
alias is a property of the repo rather than of one roster revision, surviving
re-`init` is the correct behavior — the user should not have to re-answer the
alias question every time they rebuild a roster.

It also means the write order between the alias step and `init` does not
matter, which keeps §6's flow flexible.

A separate file was considered and rejected: it would need its own path
resolution, its own level semantics, and its own precedence — a second system
where the existing one already does the job.

### 5.2 New subcommand: `roster.mjs alias`

```
roster.mjs alias [--level global|repo|repo-user] [--set <name>] [--clear] [--cwd <path>]
```

- **No `--set`/`--clear`** — read-only. Prints
  `{alias, source, prefix, effective_names_sample}` where `prefix` is
  `teamPrefix(cwd)` and the sample shows one derived name, e.g.
  `ct-architect`, so the user sees the consequence rather than the input.
- **`--set <name>`** — validates per §4.4, then writes top-level `teamAlias`
  via the existing `readLevelFile`/`writeLevelFile` pair, preserving every
  other key. Defaults `--level` to whichever level currently resolves,
  matching the documented `add`/`edit`/`remove` behavior, and prints which
  level it picked.
- **`--clear`** — deletes the key at that level. Prints the prefix that now
  applies.
- **`--level global` with `--set` or `--clear`** — `fail()` per §4.3, with a
  message saying an alias is repo-scoped and naming `repo` / `repo-user`.

Register the case in the switch alongside `layout`, which is the closest
existing analogue: a small team-wide scalar with show-or-set semantics.

### 5.3 Live-team warning on write

If `readTeam(hierarchyDir(cwd))` returns a team, `alias --set` and
`alias --clear` still perform the write but **must** print the §7.4 warning.

The write is not blocked. Blocking would strand a user who wants the alias to
take effect on their next team, and the consequence is confusing rather than
destructive.

---

## 6. Feature B — the `init` flow

`skills/agent-roster/SKILL.md` § init currently runs: 1 Level, 2 Route,
3 Layout, 4 Destructive check, 5 run `init`, 6 walk roles, 7 `show`.

Insert a new step between **4 and 5** — after the destructive check, before
the CLI call:

> **4a. Team name.** Ask via AskUserQuestion what prefix this repo's agent
> names should use. Show the derived name it produces, not just the prefix:
> offer `"<repo-basename>" — agents named <repo-basename>-architect,
> <repo-basename>-reviewer, … (Recommended)` as the first option, and
> `"Use a shorter alias"` as the second, which prompts for free text.
> Whatever the user types is validated by `roster.mjs alias --set`; on
> rejection, report the CLI's message and ask again rather than silently
> correcting it. Skip this question entirely if `roster.mjs alias` already
> reports an alias for this repo — say in one line what it is and move on.
> If the user picks the alias option, run
> `roster.mjs alias --level <L> --set <name>`.

Placement rationale: it is after the level is known (4a needs `--level`) and
before role-walking, so step 6's per-role prompts and step 7's `show` echo
already display the final names. Asking after the roles were named would make
the echo contradict what the user just chose.

The "skip if already set" clause matters because §5.1 makes the alias survive
re-`init`. Re-asking an unchanged question on every rebuild is exactly the
friction that makes users stop running `init` properly.

Also update SKILL.md:

- § Levels, the "Member names are **derived, never stored**" paragraph — it
  currently states the first member of a role is `<repo-basename>-<role>`.
  Amend to `<team-prefix>-<role>`, defining team-prefix as the alias if set
  else the repo basename, and pointing at `roster.mjs alias`.
- § Command surface — add the `alias` line.

---

## 7. Feature B — edge cases

### 7.1 Alias set while a Team is live

The brief asks whether adding an alias later renames live members, orphans
them, or forces `resync`/`disband`. The existing architecture already answers
this and the answer needs no new mechanism.

SKILL.md § Levels states names are "only meaningful for a Team's lifetime, and
a live Team's authoritative names are frozen in `team.json` at check-in time
… not recomputed from the roster." SKILL.md § Check-in registry adds that once
`team.json` exists it is the **authoritative** source for peer dispatch
(ADR 0002), consulted before the config-peer and live-roster fallbacks.

Therefore: setting an alias mid-Team **renames nothing and orphans nothing**.
Live members keep their `team.json` names and keep receiving dispatch. The
roster now derives different names, which take effect for the next Team.

### 7.2 The real hazard: a mixed-name team

The genuine problem is not the live members, it is what happens next.

If a role dies and the user runs `spawn-one` after setting an alias, the new
member is placed under the **new** prefix while its siblings keep the old one
— `team.json` ends up holding `claudetools-architect` and `ct-reviewer`. That
team still functions (every name is resolved from `team.json`), but it is
confusing, and the mixed state is invisible unless someone reads the file.

Required behavior: **do not auto-rename and do not auto-disband.** Both would
destroy or disturb sessions that already hold work, which this project's
standing rule forbids without asking. Instead, `spawn-one` must detect that
the prefix it is about to use differs from the prefix of the existing
`team.json` members and print the §7.4 warning, so a mixed team is announced
rather than discovered.

### 7.3 `roleForPeerName` and historical `peers.jsonl` records

`roleForPeerName` maps a session name back to a role by testing
`resolvedPeerTargets(...)`. After an alias change it will no longer recognize
old-prefix names appearing in `peers.jsonl` at that step.

Impact is bounded twice over. First, `roster()` prefers `rec.role` and only
calls `roleForPeerName` when the record has no role
(`rec.role || roleForPeerName(...)`, `lib-hier.mjs:483`), and records written
by `sessionstart.mjs` carry `role` explicitly. Second, when it *is* called,
`roleFromName`'s substring fallback still recovers the role from the name's
own role token (§11 test 28). **Accepted, not fixed** — no back-compat alias
list, which would be a second naming system for a transient cosmetic effect.

### 7.4 RESOLVED (a) — the live-team warning describes, and stops

Fires from two places: `alias --set`/`--clear` against a live team (§5.3), and
`spawn-one` when the prefix it would use differs from the existing
`team.json` members' prefix (§7.2).

**Decision: state the consequence and stop. Do NOT recommend
disband-and-recreate, and do not offer to do it.**

The rationale is a standing rule in this environment, not a style preference:
stopping or discarding in-flight work that has already cost tokens is the
user's call, never a tool's default suggestion. A live team's sessions may
hold work nobody else can reproduce. A warning that nudges toward teardown
converts a cosmetic naming inconsistency into destroyed work, and it does so
at the moment the user is least likely to push back, because the tool sounds
authoritative.

So the warning is informational only. It must:

1. name the live team id and the members that carry the old prefix;
2. state both prefixes explicitly;
3. say the live members are unaffected and keep receiving dispatch;
4. say a fresh Team picks up the new prefix;
5. **stop there** — no recommendation, no "you may want to", no offer.

Exact text for the `alias --set` path:

```
ah: team <team_id> is live with N member(s) named "<old-prefix>-<role>".
Their names are frozen in team.json and are unaffected — they keep receiving
dispatch under those names. The new prefix "<new-prefix>" applies to the next
Team you create.
```

Exact text for the `spawn-one` path:

```
ah: this member will be named "<new-prefix>-<role>", but team <team_id>'s
existing members are named "<old-prefix>-*". The team will hold both prefixes.
Every name still resolves from team.json, so dispatch is unaffected.
```

Point 4 is what makes describe-and-stop sufficient rather than unhelpful: the
user learns the path to a consistent team without being pushed down it. If
they want it now, they already know `disband` exists.

### 7.5 Smaller cases

| Case | Behavior |
|---|---|
| Alias identical to the repo basename | Accepted and written. Harmless, and refusing would force a confusing "that's already the default" dialogue. |
| Alias at `repo` and `repo-user` both set | `repo-user` wins, same precedence as roster resolution. `alias` (read-only) reports the winner and its source. |
| Alias set at a level with no roster | Legal. `teamPrefix` is independent of roster presence; the alias applies as soon as a roster exists at any level. |
| Hand-edited invalid alias | Ignored per §4.4, warning emitted, names fall back. Never throws. |
| Not a git repo | `findGitRoot` returns null, `repoRoot` is the resolved cwd, basename of that is the fallback. Unchanged from today. |
| Alias containing only digits (`"42"`) | Accepted — matches the regex, contains no role token. Ugly, not harmful. |
| Alias `"ultra-advisor"` | **Rejected** by §4.4's collision rule, and correctly so — every name it derives would resolve to `ultra-advisor`. Nobody should alias a team to a role name; the rule enforces it rather than relying on nobody trying. |
| Alias `"advisor"` | **Accepted**, and correctly so — it collides with nothing, because `"advisor-<role>"` never contains `"ultra-advisor"`. See §4.4's worked examples; this is the case that rules out a blacklist implementation. |
| Two sibling repos aliased identically | Not detected. Their teams live in different `hierarchyDir`s; a `ListAgents` collision is possible but is the user's own doing. Out of scope. |

---

## 8. Explicitly out of scope

- **`pathSlug` and `rosterLevelPaths` (`lib-config.mjs`).** The brief flags
  this and it is right: `pathSlug` derives the `repo-user` directory name from
  the absolute repo path. It is a path component, not a name. Aliasing it
  would relocate config files and break every existing `repo-user` roster.
  **Do not touch it.** The alias affects naming only.
- **`hierarchyDir`.** Same reasoning — it is a path. Its
  `basename(resolve(base))` is a path component and is deliberately excluded
  from §3.1 (see §3.1b).
- **`lib-hier.mjs`'s `basename(name)` / `basename(f.path)`.** These operate on
  message-file paths, not repo identity. Excluded by §3.1b, not overlooked.
- **`roleFromName`'s unanchored substring matching.** `name.includes(token)`
  mis-resolves any session name whose non-role portion contains a role token,
  and the result depends on `ROLE_TOKENS` iteration order. This is a
  **pre-existing latent correctness bug**, not one this spec introduces — but
  Feature B makes it *reachable*, since the user now types the prefix. The
  proper fix is to anchor the match to the trailing `-<token>` segment.
  **Deliberately not fixed here**: it changes role resolution for every
  consumer, carries its own blast radius, and folding it into an alias-naming
  spec at this stage is scope creep on otherwise-finished work. §4.4's
  collision rule defends Feature B against it without changing it.
  **Recommend filing separately.**
  *(Note: per amendment (e) this function now lives in `lib-config.mjs`, not
  `lib-hier.mjs`. The relocation is required and in scope — §4.4 Module
  placement — but its behavior is unchanged, which is the part that stays out
  of scope.)*
- **The inverted herdr case** (herdr installed, `HERDR_ENV` unset). Silent by
  decision, §2.3.
- **The root `marketplace.json` top-level description and keywords.** §2.7 —
  marketplace scope, not plugin scope.
- **Orchestrator session naming.** The alias governs derived member names.
  The Orchestrator is whatever session runs `create` and is never a roster
  entry (SKILL.md § Command surface); this spec does not rename it.
- **Renaming live sessions.** No mechanism exists to rename a running Claude
  session, and inventing one is far outside this change.
- **`CONFIG_VERSION`.** Unchanged; §4.5.

---

## 9. Files to change

| File | Change |
|---|---|
| `hooks/lib-config.mjs` | Add `teamPrefix`, `teamPrefixInfo`, `validateTeamAlias`. **Receive `ROLE_TOKENS` and `roleFromName`, placed next to `peerName` (§4.4 Module placement) — must add no new import.** Rewire sites 1, 2, 3. Add alias line to `statusReport`. Alias-validation warning into the `resolveConfig` warnings array. |
| `hooks/lib-hier.mjs` | **Remove `ROLE_TOKENS` (:42-48) and `roleFromName` (:408-412); add `roleFromName` to the existing line-23 import from `lib-config.mjs`.** No other change — `roleForPeerName` at :429 keeps calling it unqualified. Added in amendment (e). |
| `hooks/lib-roster.mjs` *(or `lib-hier.mjs`)* | Add `herdrOnPath()` (§2.4). |
| `hooks/roster.mjs` | Rewire site 4. Add the `alias` subcommand (§5.2), including the §4.4 role-collision validation. Add herdr presence `fail()` on the herdr paths (§2.6). Add the mixed-prefix warning to `spawn-one` (§7.2, text in §7.4). Surface alias in `show` (§10). |
| `hooks/sessionstart.mjs` | herdr warning (§2.5). `teamPrefix(resolved.cwd)` into `buildStateBlock`. |
| `hooks/pretooluse-ultra-gate.mjs` | Rewire sites 5 and 6, collapsing to one call. |
| `hooks/pretooluse-msg-gate.mjs` | Rewire site 7. |
| `hooks/pretooluse-route-gate.mjs` | Rewire site 8. |
| `hooks/posttooluse-roster.mjs` | Rewire site 9. |
| `hooks/msg.mjs` | Rewire site 10 (`case "roster":`) to `teamPrefix(resolved.cwd)`; drop the now-unused `basename` import if nothing else uses it (§4.2). Added in amendment (c). |
| `skills/agent-roster/SKILL.md` | init step 4a; § Levels naming paragraph; § Command surface `alias` line (§6). |
| `agent-hierarchy/README.md` | herdr Prerequisites section (§2.7). |
| `agent-hierarchy/.claude-plugin/plugin.json` | description + keywords, exact text in §2.7; version bump (§2.8). |
| `.claude-plugin/marketplace.json` (root) | Version bump (§2.8). Per-plugin `agent-hierarchy` description if such an entry exists — **not** the top-level description or keywords (§2.7). |

---

## 10. Surfacing the alias

Required by the brief so the alias is not invisible after setup.

- **`roster.mjs show`** — both branches. Add `teamAlias` and
  `teamAliasSource` to the emitted object. The resolved branch gets them
  because `resolveRoster` now carries them (§10.1); the `--level` branch
  reports that level's own raw value plus the effective one, so a shadowed
  alias is visible as shadowed.
- **`statusReport`** (`lib-config.mjs`) — one line in the roster section:
  `Team alias: ct (from repo-user) — agents named ct-<role>`, or
  `Team alias: none — agents named claudetools-<role>` when unset. It must
  print in **both** cases; a line that appears only when set is a line nobody
  learns exists.
- **`roster.mjs alias`** with no flags (§5.2).

### 10.1 `resolveRoster`'s return shape

`resolveRoster` gains `teamAlias` and `teamAliasSource` alongside the existing
`{level, route, layout, members, path}`. Additive only — every existing
consumer destructures what it needs and is unaffected.

---

## 11. Tests

New assertions. Every one must be shown to **fail against unmodified code**
before it counts, per this project's standing discipline.

**Feature A** — new `tests/test-herdr-presence.sh`:

1. `herdrOnPath()` true when a fake `herdr` is on a sandboxed `PATH`.
2. False when `PATH` has no `herdr`.
3. False when `PATH` is unset. Must not throw.
4. False when `herdr` exists but is not executable.
5. `sessionstart.mjs` with `HERDR_ENV=1` and no `herdr` on PATH emits the
   §2.5 warning in `additionalContext`.
6. Same, but with `herdr` present → **no** warning.
7. `HERDR_ENV` unset, no `herdr` on PATH → **no** warning. The false-positive
   guard; this is the acceptance criterion the brief names.
8. `HERDR_ENV` unset **with** `herdr` present → **no** warning. Guards §2.3's
   deliberate silence against a future "helpful" addition.
9. `sessionstart.mjs` still emits exactly one well-formed JSON object on
   stdout in every case above, and still emits the directive when the probe
   is made to fail.
10. `roster.mjs spawn-one` with `HERDR_ENV=1` and no `herdr` → `fail()` with
    the §2.6 message, before any pane is placed.
11. Same for `create --spawn`.

**Feature B** — extend `tests/test-roster-names.sh`, add `tests/test-team-alias.sh`:

12. `teamPrefix(cwd)` with no alias anywhere → repo basename. **The
    zero-change guarantee** (§4.5).
13. **Subdirectory coverage — closes the gap NEEDS-EVIDENCE item 2 found.**
    With cwd set to a subdirectory of the sandbox repo root and no alias set,
    `teamPrefix(subdir)` returns the **git-root** basename, and the prefix used
    by `pretooluse-route-gate.mjs` matches the prefix `resolveRoster` used to
    name members. Against unmodified code these two differ (§3.3), so this
    test must fail before the change and pass after. No existing test
    exercises a non-root cwd — this is the regression guard for the §4.5
    behavior change, and its absence is why the §3.3 bug survived.
14. **Inventory completeness guard — added in amendment (c).** Assert that
    ```
    grep -rn 'basename(resolved\.cwd)\|basename(resolve(cwd))' hooks/
    ```
    returns **no matches**. After the rewire, no file in `hooks/` should derive
    a repo prefix from a cwd basename — `teamPrefix`/`teamPrefixInfo` is the
    only place that derives one, and it does so from `repoRoot`. The two
    legitimate survivors do not match this pattern: `hierarchyDir` uses
    `basename(resolve(base))` and `teamPrefixInfo` uses `basename(repoRoot)`.
    This assertion would have caught site 10, and it is what stops an eleventh
    from being introduced silently later. If a future change legitimately needs
    a cwd basename, the test failing is the prompt to justify it in this spec
    rather than to loosen the grep.
15. Alias at `repo` → alias.
16. Alias at `repo-user` and `repo` → `repo-user` wins.
17. Alias at `global` only → **ignored**, basename returned (§4.3).
18. Invalid alias values each rejected by `alias --set` with a message naming
    the rule: empty, whitespace, `a/b`, `-lead`, 33 chars, and — per the
    amended (b) character set — `ct.x` and `ct_x`.
19. Hand-edited invalid alias in the file → `teamPrefix` falls back, no throw,
    warning present.
20. `rosterMemberNames` unchanged: still pure, still takes a prefix
    parameter, existing assertions in `test-roster-names.sh` still pass
    verbatim. The seam guard (§3.2).
21. End-to-end: alias `ct` set at `repo` → `resolveRoster` names
    `ct-architect`, `ct-reviewer`, `ct-reviewer-2`; ordinals unaffected.
22. `init` after an alias is set preserves `teamAlias` (§5.1) — the
    survives-re-init guarantee.
23. `alias --clear` restores basename-derived names.
24. `alias --level global --set x` → `fail()`.
25. `show` reports `teamAlias`/`teamAliasSource` in both branches; `statusReport`
    prints the alias line when set **and** when unset (§10).
26. `spawn-one` against a `team.json` whose members carry a different prefix →
    mixed-prefix warning present, and it **does not** contain the word
    "disband" (§7.4's describe-and-stop rule, asserted rather than trusted).
27. Setting an alias while a team is live does not modify `team.json` (§7.1),
    and its warning likewise does not recommend teardown.
28. **WAIVED — not achievable, do not re-add (amendment (d)).**
    Originally: "`msg.mjs roster` from a subdirectory cwd reports peer names
    under the git-root prefix." **`msg.mjs roster`'s output cannot observe
    which prefix was computed**, so no fixture can make this discriminate
    pre-fix from post-fix. The chain:
    `roster()` (`lib-hier.mjs:483`) consults the prefix only for records with
    no `role`; for those it calls `roleForPeerName`, whose only
    prefix-dependent step compares against
    `peerName(prefix, role)` = `` `${prefix}-${role}` ``
    (`lib-config.mjs:153,167`); when that comparison misses, `roleFromName`
    recovers the role by unanchored substring — and a `<prefix>-<role>` name
    **always contains its own role token**. So both the right-prefix and
    wrong-prefix names resolve to the same role, and no other field `roster()`
    emits (`name`, `live`, `how`, `ageSec`, `busy`, `task`, `openBriefs`,
    `unassigned`) derives from the prefix.
    Site 10's rewire is guarded **statically by test 14** instead, which is the
    stronger check: total rather than behavioral, and not subject to masking.
    A white-box spy on `msg.mjs`'s `teamPrefix` import was considered and
    rejected — it would add coverage only for a hypothetical *third* wrong
    derivation of a different shape, at the cost of ESM import-spying in a bash
    suite.
29. **Role-token collision (amendment (d), §4.4).** `alias --set` rejects an
    alias that collides with role-token matching, with a message distinguishing
    the collision from a character-set violation.
    **Reject:** `architect` (equal to a token), an alias containing a token
    mid-string, one ending in `-<role>` (the superseded suffix rule's case),
    and `ultra-advisor`.
    **Accept:** `ct` and — importantly — **`advisor`**, which collides with
    nothing (§4.4 worked examples). The accept cases are the over-broadness
    guard: a blacklist implementation passes the reject cases and **fails on
    `advisor`**, so this test is what pins the rule to its behavioral form.
30. **No new module edge (amendment (e)).** Assert `hooks/lib-config.mjs`
    contains no `import` from `./lib-hier.mjs`. One grep; it fails loudly if a
    future change reintroduces the circular-init crash that §4.4's Module
    placement block exists to prevent.

**Regression** — the whole existing suite must stay green, with particular
attention to `test-roster-names.sh`, `test-roster-spawn-one.sh`,
`test-roster-create-spawn.sh`, `test-roster-cli.sh`, and
`test-team-registry.sh`, which construct names like `myrepo-architect` and
would break if the seam were cut in the wrong place. NEEDS-EVIDENCE item 2
confirmed every existing `--cwd` in the suite points at a git-root sandbox, so
no existing expectation depends on cwd-basename behavior and none should need
updating. **If one does, stop and report it** — that would mean the seam was
cut in the wrong place.

---

## 12. NEEDS-EVIDENCE — all resolved (amendment (b))

| # | Question | Result | Effect on spec |
|---|---|---|---|
| 1 | Does the cwd-vs-git-root split mis-resolve today? | **Confirmed live.** `resolveRoster` → `claudetools`; route-gate → `agent-hierarchy`, same cwd. | §3.3 promoted from suspected to confirmed; §4.5's exception is a documented fix, and test 13 added. |
| 2 | Any existing test with cwd below the repo root? | **None.** ~50 `--cwd` hits across 15 files, all git-root sandboxes. | No existing expectation to update. Recorded as a **coverage gap**, closed by test 13 — see §4.5's dissent note. |
| 3 | Current `description`/`keywords` in both manifests? | plugin.json: `"Multi-agent role hierarchy, each on the right model."` / 6 keywords. Root marketplace.json: repo-level description, **no** keywords field. | §2.7 now carries exact append text and rules the root-level fields out of scope. |
| 4 | Is `herdr` a real PATH executable? | **Yes.** `/opt/homebrew/bin/herdr`, `herdr 0.8.2`. | §2.4's PATH-walk probe validated as designed. |
| 5 | Does `herdr agent start --name` accept `.` and `_`? | **Unverifiable without a live spawn** — herdr 0.8.2 has no dry-run/validate flag. | §4.4 tightened to `/^[A-Za-z0-9][A-Za-z0-9-]{0,31}$/`; rationale and the loosen-is-cheap asymmetry recorded there. Test 18 extended. |

---

## 13. Design forks — CLOSED (amendment (a))

All forks raised in this spec were resolved by the Orchestrator and folded
into the sections they belong to. Recorded so nobody re-opens them:

| Fork | Resolution | Where |
|---|---|---|
| Nudge when herdr is installed but `HERDR_ENV` is unset? | **No.** Silent, out of scope — the fallback chain works and the nudge is speculative noise. | §2.3, §8 |
| Ignore a `global`-level `teamAlias`? | **Yes, confirmed.** An alias is a property of one repo, not a machine-wide default. `--level global` refusal stands. | §4.3 |
| Should the live-team warning recommend disband? | **No.** Describe-and-stop. Discarding work that already cost tokens is the user's call, never a tool's default suggestion. | §7.4 |
| Keep or delete §4.5's behavior-change paragraph? | **Keep.** Raised as a dissent in (b); the Orchestrator accepted the reasoning. Coverage gap closed by test 13 instead. | §4.5 |
| Test 28 blocked — waive, redefine white-box, or missed code path? | **Waive.** Not merely hard to test: unobservable in principle through `msg.mjs roster`. Test 14 is the stronger guard. Verifying it surfaced the §4.4 collision gap. | §11 test 28, §4.4, §8 |
| Circular import blocking §4.4 — relocate, dynamic import, or duplicate? | **Relocate**, into `lib-config.mjs` next to `peerName`. Free (both symbols are pure leaves with one in-file caller and no external importer) and it corrects a pre-existing misplacement. Dynamic import rejected: turns a sync path async and leaves the layering error standing. Duplication rejected: contradicts the behavioral rule's rationale. | §4.4 Module placement, §9, §11 test 30 |

Nothing is open for the user.

## 14. Confidence

**High on the design, and materially higher on the inventory than it was
before amendment (c).**

Three of my own errors are worth stating plainly rather than burying:

1. §3.1 claimed to be "the complete set" on the strength of an identifier
   grep, and was wrong by one (amendment (c)).
2. Test 28 was specified without checking whether the value it asserted on was
   observable — it isn't (amendment (d)).
3. §4.4's collision rule was specified without checking the existing import
   direction between the two modules it spans, making it unimplementable as
   placed (amendment (e)).

**All three share one shape: asserting or requiring a property without first
checking the precondition that would make it detectable or possible.** A grep
that cannot see inline expressions; a test whose signal is masked downstream;
a call that the module graph forbids. The generalization for the rest of this
work — and for future specs — is to check the *mechanism* before committing to
the rule that depends on it. Each was caught by the Implementor or Reviewer
stopping rather than improvising, which is the process working; but a spec
should not need three catches.

The rest holds as before: the seam (§3.2) is clean because every consumer
already takes the prefix as a parameter, the §3.3 bug is confirmed by live
execution rather than inference, the herdr probe is validated against the real
binary, and the live-team question (§7.1) is answered by an invariant the
architecture already committed to.

The one deliberately conservative choice is §4.4's character set, taken
because the alternative could not be tested without a real side effect and the
failure modes are asymmetric. It is the cheap-to-reverse direction. §4.4's
role-collision rule is the one place this spec defends against a bug it
declines to fix (§8) — that boundary is deliberate and stated, not an
oversight.

Nothing here rises to Ultra-Advisor escalation: no security, auth, data
migration, or concurrency surface, and the one irreversible-feeling area —
renaming live agents — turns out to be a non-event because `team.json` freezes
names at check-in.
