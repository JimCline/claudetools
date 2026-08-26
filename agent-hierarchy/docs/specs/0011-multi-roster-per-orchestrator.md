# 0011 — Multiple team rosters per repo, scoped per orchestrator

Status: **specified, implemented, amended nine times. Code signed off by
Reviewer. NO OPEN ITEMS BLOCKING CLOSE-OUT. One defect created by this spec is
explicitly DEFERRED to its own item, with reasons, at §9.6 — deferred, not
inherited.**

Amendment (a) replaced directory scoping with record-tagging. (b) closed a
**security-adjacent** gate blackout. (c) extended name confirmation to the first
team. (d) resolved a record-attribution gap and a resolution-mechanism fork.
(e) corrected §4.5's default-team wording. (f) **withdrew an incorrect
requirement** (d) placed on two gates. (g) **confirmed a third gate blackout**
and escalated it. (h) recorded the Ultra-Advisor's **predicate (ii)** ruling as
shipped, retired §5.6, and corrected §7.10. (i) **rules on a fourth
manifestation of the same root cause (§9.6), corrects §4.4.1's msg-gate row,
and closes the remaining stale references.**

> **Amendment (a) — 2026-08-25.** Directory scoping replaced by record-tagging.
> 1. **My "`msgs/` mis-delivery" claim was wrong.** Briefs are delivered by
>    absolute path over `SendMessage`, never by directory polling (§2.1).
> 2. **Directory scoping rejected** for the user's shared-files/tagged-records
>    proposal — ~4 call sites instead of 20.
> 3. **The `(b)` blocker dissolved** — the mechanism requires a peer to know
>    nothing about its team (§4.1).

> **Amendment (b) — 2026-08-25, post-review.** Three review findings, all mine.
> 1. **§9's hook exemptions were wrong and a gate went dark (B3).** Four files,
>    not one. §9 now carries a *rule*, not a file list (§9.1).
> 2. **§4.2's absolutes contradicted baseline invariance (S1)** → §4.2.1.
> 3. **§4.4 rung 2 was undeliverable from the CLIs (S4)** → §4.4 rewritten.

> **Amendment (c) — 2026-08-25, user design feedback.** *"The default team name
> should be prefixed with the repo, asking the user to confirm or provide a
> different name."* **Accepted in full**, zero code (§5.3). Baseline invariance
> **preserved, not traded** — §10 gains the definition.

> **Amendment (d) — 2026-08-25, post-implementation.** Two items the Implementor
> correctly refused to decide alone. **Both spec-clarity defects of mine.**
> 1. **§7.5 and §7.6 partition the same input space without showing the
>    partition** → §4.5's table. **The Implementor was right and the Reviewer's
>    S2 was wrong** about which section governs.
> 2. **My §9.1 citation of `roleForPeerName` was ambiguous** → §4.4.1, §9.1.

> **Amendment (e) — 2026-08-25, Reviewer final pass.** §4.5's default-team row
> said *"today's behaviour, in full"* then gave two examples. **Reviewer right —
> that overstates the row.** Corrected to delegate to §10/§11.1.

> **Amendment (f) — 2026-08-25, Implementor stop.** **(d)'s §4.4.1 table was
> wrong about msg-gate and ultra-gate.** Neither has ever resolved a name
> against `team.json`. **Requirement WITHDRAWN; no code change.** §4.4.1 gains
> question (C); §9.3 states the deny-default asymmetry.
> **(i) corrects this further: the withdrawal's OUTCOME was right; its
> CLASSIFICATION of msg-gate was wrong. See §9.6.**

> **Amendment (g) — 2026-08-25, Reviewer second closing pass.** **§9.3's
> "nothing is lost" cell was FALSE.** Confirmed at source: **every peer session
> in a named team resolves `null` and gates the wrong prefix** — structural, not
> an edge case. §9.5 opened and **escalated to Ultra-Advisor**. **I rejected the
> "accepted limitation" framing: 0011 creates this divergence, so 0011 owns it.**

> **Amendment (h) — 2026-08-25, post-ruling close-out.** Ultra-Advisor ruled
> **predicate (ii)** (msg `20260825-121657-997n`); Implementor shipped it
> (`20260825-125913-1k1w`). **Verified at source before marking resolved.**
> §9.5 OPEN → RESOLVED-(ii); **§5.6 RETIRED** (its warning had become factually
> false); **§7.10 CORRECTED** — (ii) makes "a sibling's ultra-advisor is not
> gated" conditional, and left flat it would have been this spec's third stale
> negative. §7.10 was **not** on the list I was asked to fix.

> **Amendment (i) — 2026-08-25, Reviewer third closing pass.** **Code signed
> off** — predicate (ii) confirmed against the ruling, all five divergence
> points traced, 49/49 reproduced independently. Four documentation items:
> 1. **§9.6 NEW — a fourth manifestation of the §9.5 root cause, in msg-gate.**
>    **Real, created by 0011, and DEFERRED by explicit decision.** The obvious
>    fix would convert a fail-open gate into one that can fail closed on a bad
>    inference — **not a same-session change on a signed-off diff.**
> 2. **§4.4.1's msg-gate row was wrong** — and (f) is *why* it was wrong.
> 3. **§5.6's tombstone gains the finding that matters more than the
>    retirement: the warning it marked REQUIRED was never implemented, and
>    three review passes did not catch it** (§14 defect 9).
> 4. **§12(e) RESOLVED from shipped code**; §11 gains an explicit note that
>    test numbers are not this spec's contract.

---

## 1. Goal

Let one repo host **N independent teams**, each owned by a distinct orchestrator
session, instead of today's one-team-per-repo model.

Concrete trigger: nothing forces one orchestrator per repo. Two top-level
sessions in the same working directory both resolve to the same `teamPrefix`,
`team.json`, and `peers.jsonl`. The second `create --spawn` either fights the
first team or silently adopts it.

**Backward compatibility is a hard requirement.**

---

## 2. What actually collides — corrected inventory

### 2.1 The correction (amendment (a))

The original spec called `msgs/` "the deepest problem" and claimed Team B's
architect could pick up Team A's brief. **That was wrong**, and it drove the
whole rejected design.

- `buildDirective` item 12 (`lib-config.mjs:723`) tells every role session that
  briefs arrive as an **in-band pointer**: `[hierarchy-msg <abs request path>]`.
  Nothing tells a peer to poll.
- `openExchanges` (`lib-hier.mjs:283`) has two callers: `roster()` and
  `buildStateBlock()`. `msg.mjs list`/`sweep` are operator-facing.

Delivery is **name-addressed over `SendMessage`**. Mis-delivery was never
possible by that route.

**What is genuinely damaged:** counts and readouts in one shared namespace.

| Surface | Real damage |
|---|---|
| `peers.jsonl` | `roster()` buckets every record by role → Team A lists Team B's architect. **Real.** |
| `msgs/` | `roster()` counts open briefs per role and fans a `to_name: null` exchange out to every peer of that role; `buildStateBlock()` runs in **every** session. Contamination of counts and state text, **not** misrouting. |
| `team.json` | One slot, two owners. **Structural.** |
| `gates.jsonl` | See §6.2 — resolved as shared. |

### 2.2 Naming — one prefix per repo

`peerName(prefix, role)` → `<prefix>-<role>`. Both teams want
`myrepo-architect`, in the **machine-global `ListAgents` namespace**.

### 2.3 What already knows about identity

- `team.json` carries `orchestrator: { session_id, pid }`.
- `team.json` carries `members`, from which names derive.
- `roleForPeerName` already consults `teamMemberByName` first.

**The orchestrator already knows the exact set of names belonging to its team.**
**No peer session does** — see §9.5 and §9.6, which is where that asymmetry bit,
twice.

---

## 3. The design decision (amendment (a))

**One shared set of files. Team identity carried by the peer *name*, resolved
against the caller's own `team.json`. Only `team.json` splits.**

```
<hierarchyDir(cwd)>/
    team.json            ← the default team (today's file, untouched)
    teams/<name>.json    ← one FILE per named team, same schema
    peers.jsonl          ← SHARED, records tagged, filtered on read
    msgs/                ← SHARED, frontmatter tagged, filtered on read
    gates.jsonl          ← SHARED, unchanged
```

### 3.1 Why the user's proposal wins

1. **It matches where the damage is** — every real problem is *read-side
   filtering*.
2. **~4 call sites, not 20.**
3. **It requires the peer to know nothing** (§4.1) — decisive, given no
   environment channel to a spawned peer exists.
4. **Untagged records degrade correctly.** Migration is a no-op.

**Caveat added by (g), doubled by (i):** reason 3 is a virtue for *reading
shared records* and a liability for **anything that runs inside a peer session
and must decide something about that session**. §9.5 was the first bill; §9.6 is
the second. **The design is still right; the caveat is now a known cost with a
known shape, not a surprise.**

### 3.2 What is NOT conceded

- **`team.json` still splits per team.** A single-slot document cannot be
  coherently tagged.
- **The prefix is still team-scoped.** Tagging fixes what *this tool* reads; it
  does nothing about `ListAgents`.

### 3.3 The prefix is scoped by the team name

> With team scope `T` active, `teamPrefixInfo(cwd, T)` returns
> `{ prefix: T, alias: T, source: "team" }` — highest precedence, above
> `repo-user`, `repo`, and `default`.

Validated by the **existing** `validateTeamAlias` (spec 0010).

**Load-bearing beyond naming — with one boundary, stated precisely because
getting it wrong produced two defects:**

> **Scoping the prefix completely answers question (C) ("is this one of MY
> peers"). It does NOT answer question (A) ("what role is THIS name"), because
> (A) must succeed for names outside the caller's own prefix — and in a peer
> session the caller's prefix is not even its own team's.**

Amendment (f) turned on the first half and was right about it. **Amendment (i)
found a caller that computes a value the (C) way and consumes it the (A) way**
(§9.6). Predicate (ii) is the repair where the prefix cannot be trusted at all
(§9.5).

---

## 4. Resolution

### 4.1 How a peer's team is determined — without the peer knowing it

No environment channel to a spawned peer exists (`execFile("/bin/sh", ["-c",
cmd])` with no `env`; `herdr` is a compiled binary). **It is not needed** — for
record filtering.

> A `peers.jsonl` record belongs to team `T` if its `name` is in `T`'s
> `team.json` member-name set.

Every filter runs **read-side, in the reader's own process**.

**Do not reintroduce `AGENT_HIERARCHY_TEAM`, `session-teams.jsonl`, or a herdr
`--env` flag** for this purpose.

> **(g) and (i) qualify "it is not needed."** True of every *read-side filter*;
> false for **hooks that must decide something about the session they run in**.
> Two such hooks exist: `pretooluse-ultra-gate.mjs` (§9.5, closed by (ii)) and
> `pretooluse-msg-gate.mjs` (§9.6, deferred). **NEEDS-EVIDENCE (d) would close
> both at the root** — see §12.

### 4.2 The unattributed window

`sessionstart.mjs` appends `{ status:"up", role, session_id, pid, ppid, cwd }` —
**no `name`**. A session knows its `role` and `session_id` but not its own peer
name. So between a peer's SessionStart and the first `ListAgents`, its record
cannot be attributed.

> **Recorded, amendment (g), unverified intent:** `sessionstart.mjs:100-101`
> writes `pid: process.ppid` **and** `ppid: process.ppid` — the same value in
> both fields. `pid: process.ppid` is plausibly deliberate (in a hook,
> `process.pid` is the hook, `process.ppid` is the session), but it makes `ppid`
> a duplicate carrying no ancestry information — **so there is no recorded
> peer→orchestrator link.** That is why process ancestry was never a candidate
> fix for §9.5 or §9.6. Reported as an observation, not a diagnosed bug; out of
> scope (§8).

**Required behaviour under a named team scope:** such records go to a separate
`unattributed` bucket — reported, never counted as a team member, never assigned
to a role bucket by guessing. **See §4.5 for the complete rule.**

#### 4.2.1 The default-team carve-out (amendment (b), finding S1)

**When `resolved.team === null`, the above does not apply. `roster()` keeps
today's behaviour exactly, including synthesizing
`` `${role}@${session_id.slice(0,8)}` `` and placing the record in its role
bucket.**

- `tests/test-roster.sh:113-114` requires a nameless `up` record to appear as
  `implementor@live-s` in the `implementor` bucket — **today's contracted
  behaviour**.
- §11.1 makes baseline invariance a hard requirement, **outranking** the tidiness
  of a uniform rule.
- **The rule loses nothing where it is waived.** In a single-team repo there is
  no other team, so role-bucket synthesis is not a wrong guess.

> **Guessing an unattributed record's team by role is forbidden exactly when
> another team could own it — i.e. when a named team scope is active.**

`tests/test-roster.sh` is **not** modified.

### 4.3 Who tags what

| Record | Written by | Tagged? |
|---|---|---|
| `peers.jsonl` `status:"up"` | the peer, `sessionstart.mjs` | **No** — cannot. |
| `peers.jsonl` `status:"seen"`/`"briefed"` | the **orchestrator**, `posttooluse-roster.mjs` | Yes — `team` alongside `name`. |
| `msgs/` frontmatter | the orchestrator, `msg.mjs new` | Yes — `team:` field. |
| `team.json` | the orchestrator, `roster.mjs` | N/A — the file *is* the team. |

Name-membership is the primary filter; the `team:` tag is a redundant
confirmation. **Where they disagree, name-membership wins** — spec 0008 §3.

### 4.4 Resolving the active team (amendment (b), finding S4)

**(A) "Which team owns this *name*?"** — asked by anything resolving an
arbitrary peer name to a role. Answered from the name alone, **no session
identity required**: `resolveMemberTeam(dir, name)`.

**(B) "Which team am *I* in?"** — asked when a caller must scope something with
no name in hand:

1. `--team <name>` explicit flag (CLIs).
2. `opts.sessionId` matches a team's `orchestrator.session_id` — hooks with a
   `session_id`.
3. **`Number(process.env.CLAUDE_PID)` matches a team's `orchestrator.pid`, and
   that pid is alive** — the CLI path. The `pidAlive` guard is **required**.
4. `null` → the default team.

Where no rung resolves, an operation that *needs* a team scope must require an
explicit `--team` rather than silently acting on the default team.

> **Amendment (g) — the rung chain's real reach.** Rungs 2 and 3 both match
> against `orchestrator.*`, and **`team.json` stores identity for the
> orchestrator only.** Therefore:
>
> **(B) can only ever succeed in the orchestrator's own session, or where
> `--team` was passed. In every peer session, (B) returns `null`, always, by
> construction — not as a failure mode but as the design.**
>
> Fine wherever `null` means "the default team, which is also the only team."
> **Not fine where a named team exists.** §9.5 (closed), §9.6 (deferred).

**(C) "Is this name one of the peers *I* would address?"** — added by amendment
(f). Answered **entirely from the team-scoped prefix**, no `team.json` lookup:
resolve (B), derive `teamPrefix(cwd, resolved.team)`, compare against
`peerName(prefix, role)` / `resolvedPeerTargets(...)`. **Inherits (B)'s reach
exactly.**

> **The trap, from (i):** (C)'s mechanism *returns a role* as a by-product of
> answering a yes/no question. **A caller that keeps that role and uses it as an
> answer to (A) has silently substituted a (C)-shaped computation for an
> (A)-shaped one, and it fails in every session where (B) fails.** That is
> §9.6 — and §4.4.1's msg-gate row said (C) because the *mechanism* is (C),
> which is exactly the error §4.4.1's own rule forbids.

#### 4.4.1 Which question to ask

> **Ask (A), (B), or (C) according to what the caller needs, NOT according to
> which identity or data the caller happens to have available — and NOT
> according to which mechanism the code currently uses** (added by (i); the
> second clause is what I violated).

| Caller | Needs | Question | Mechanism |
|---|---|---|---|
| `roster()` | "who is on **my** team" | **(B)** | team-scoped membership |
| `buildStateBlock()` | "**my** open exchanges" | **(B)** | team-scoped |
| `pretooluse-route-gate.mjs` | "what role is **this arbitrary name**" | **(A)** | `resolveMemberTeam` — §9.1 |
| `pretooluse-msg-gate.mjs` :75→:79 | **"what role is this name", fed to `validateRequestToken` as `expectedTo`** | **(A)** — *implemented as (C)* | **MISMATCH — §9.6, deferred** |
| `pretooluse-ultra-gate.mjs` | "is this **an** ultra-advisor I should gate" | **(C) + §9.5(ii)** | scoped prefix, **widened to the union when (B) cannot succeed** |
| `posttooluse-roster.mjs` | tags a record with the team owning a name | **(A)** | `resolveMemberTeam` — **verified shipped, `:29`** |

> **Amendment (f) correction — itself corrected by (i).** (f) reclassified
> msg-gate from (A) to (C) and withdrew a required code change. **The
> withdrawal's outcome was right** — the change (f) was withdrawing would have
> added a membership stage to the wrong predicate, and it was not needed then.
> **The classification was wrong**, and §9.6 is what that cost. **Neither (g)
> nor (h) nor (i) reopens the ultra-gate half of (f): (ii) widens a prefix set
> and performs no membership lookup.**

### 4.5 Record attribution — the complete rule (amendment (d))

§4.2, §7.5, and §7.6 each described one case of the same decision and never
showed the partition, so they appeared to disagree about a record that is
**untagged and matches no team**. This table is the single authority.

**Under a named team scope (`resolved.team !== null`):**

| # | Record has a name? | Name in **my** team's member set? | Name in **another** team's set? | Result |
|---|---|---|---|---|
| 1 | no | — | — | `unattributed` |
| 2 | yes | yes | — | **my member** — normal role bucket |
| 3 | yes | no | yes | **excluded entirely** — theirs, not my `unattributed` |
| 4 | yes | no | no | `unattributed` |

**Under the default team (`resolved.team === null`): rows 1–4 do not apply, and
this spec does not restate what happens instead.**

> **Amendment (e).** This row previously read *"today's behaviour, in full,"*
> then listed two examples. **The row is a deferral, not an enumeration** — two
> examples cannot be "in full," and a later reader would treat the pair as the
> closed set and read omission as prohibition.

The definition of default-team behaviour is **§10's baseline-invariance rule and
the suite that enforces it** (§11 test 1). If a behaviour is not named here, that
is silence, **not prohibition.**

Two behaviours, **as illustrations only**, because they superficially look like
violations of rows 1–4 and are not:

- A nameless record is synthesized into its role bucket (§4.2.1).
- A named non-member is still listed via `roleFromName` —
  `tests/test-roster.sh:104`.

**§7.5 and §7.6 are both preserved**, and neither is the general rule:

- §7.5 governs **tag present, contradicted by membership** — row 3 or 4.
- §7.6 governs **no tag** — a *degradation* rule about reading legacy data.

**Ruling on S2: §7.6 governs; the Implementor's reading was correct.**
Verification is §11 test 12.

---

## 5. Command surface

### 5.1 `--team <name>` on `roster.mjs` and `msg.mjs`
Validated with `validateTeamAlias`; on failure `fail()` with the validator's
`why` string **verbatim**.

### 5.2 `roster.mjs create --team <T>`
Writes `teams/<T>.json`; binds `orchestrator.session_id`/`.pid`; member names
derive from prefix `T`.

### 5.3 Naming a team is always confirmed, never silent (amendment (c))

**The first team is just the first team.** Its name governs every peer name in
the repo and appears in every `ListAgents` listing.

#### 5.3.1 The rule

> **Before the first `create` in a repo with no existing team, the agent
> proposes a repo-derived candidate name and asks the user to accept it or
> supply a different one.**

Candidate: the effective prefix from `teamPrefixInfo(cwd)`.

#### 5.3.2 Where each half lives

| Half | Where | Change |
|---|---|---|
| Asking | `skills/agent-roster/SKILL.md` — agent calls `AskUserQuestion` before `create` | **New text. No code.** |
| Doing | `roster.mjs create` | **None.** |

**`roster.mjs create` must NOT refuse, prompt, or read stdin on the first
create.** It runs in tests, CI, and scripts, none of which can answer a question.

#### 5.3.3 What each answer does

- **Accept** → run `create` exactly as today. **Byte-identical output.**
- **Override** → `roster.mjs alias --set <name>`, then `create`.

The prompt must say an override persists for the repo.

#### 5.3.4 Naming is not scoping

- **Naming** — which prefix the team's peers use. Stored as 0010's alias.
- **Scoping** — whether a team gets its own `teams/<T>.json`. Collision-only.

#### 5.3.5 The collision case

> `create` with no `--team`, where the base `team.json` exists with a **live**
> orchestrator that is not this session, `fail()`s with the live team's name and
> pid, a candidate, and the exact command to accept or override.

**Never applied unconfirmed.** This path *does* produce a scoped team.

#### 5.3.6 Should this live in 0010 instead?

**No.** 0010 owns the alias *mechanism and storage*; 0011 owns the *command
surface and when the user is asked*. Splitting one flow across two specs is how
the half you are not editing stops getting re-read — §14 defect 4.

### 5.6 ~~The named-team escalation-gate warning~~ — **RETIRED (h), and it was never built (i)**

**This section required `SKILL.md` to warn the user, at every named-team creation
point, that peer sessions in a named team did not have their Ultra-Advisor
escalations gated. Predicate (ii) closed that blackout (§9.5), which made the
warning factually false. It is retired — along with the `SKILL.md` requirement in
§9's table and the pointer from §5.3.5.**

**Two findings, and the second is the important one.**

**1. Why retiring beats softening.**

- **A safety warning that states a false fact is worse than no warning.** It
  trains the reader to discount the next one, and it misdescribes the system to
  someone making a consent decision. "Retain as-is with a note" was not
  available, for the same reason "accepted limitation" was not available when
  §9.5 opened.
- **No replacement warning is warranted, and I looked for one rather than
  assuming.** (ii)'s residual asymmetries (§7.10) all move toward **more**
  gating. §5.6 existed because a user silently *lost* a consent control by
  opting in; nothing is lost now. Manufacturing a softened warning to justify
  keeping the section would be the same error pointed the other way.

**2. It was never implemented — and that is a worse defect than the staleness.**

Verified at source: `skills/agent-roster/SKILL.md` contains **zero** escalation-
or ultra-gate-warning text. Its only `ultra-advisor` matches are the role list
(`:95`) and the spawn-order line (`:135`).

> **This section said REQUIRED, shipped with the spec, and nothing was written.
> Three review passes verified code against spec and none of them checked that a
> spec-mandated piece of *documentation* had shipped.** Recorded as §14 defect 9.
> It is luck, not process, that the un-written warning was also the one that
> would have become false.

Kept as a tombstone rather than deleted, because both findings are worth more
than the section was. The exposure itself stays on record in §9.5 and (g).

---

## 6. Composition with 0008, 0009, 0010

### 6.1 Spec 0008
- **§3 "`team.json` has exactly one writer" — PRESERVED**, load-bearing for §4.3
  and §4.5.
- **§5.1 "`resync`/`move` locate `team.json` by `--cwd` alone" — AMENDED** to
  "`--cwd` and the active team scope".
- **0008's `teamPrefix` unification — PRESERVED.**

### 6.2 Spec 0009 — see §9.1, §9.3, §9.5, §9.6
`gates.jsonl` stays shared: predicates A and B read config-file-derived values,
per-repo and per-user, not per-team. **§8.12's fail-open catch — PRESERVED.**

**0009's ultra-gate semantics are deliberately widened, once, by §9.5's
predicate (ii)** — under a single guard condition, and by Ultra-Advisor ruling
(`20260825-121657-997n`) rather than by my judgment. **This is the only 0009
behaviour 0011 changes**, and it changes it to *restore* coverage 0011 itself
had removed. **§9.6 is a 0009 behaviour 0011 degrades and does NOT repair** —
recorded there, deferred deliberately.

### 6.3 Spec 0010 — reused, not amended
`validateTeamAlias` reused verbatim; amendment (c) reuses `alias --set`. **No
0010 amendment required.** 0010 §8's out-of-scope note on unanchored matching is
one reason predicate (iii) was not chosen — **and the reason §9.6's obvious fix
is not safe to apply on a signed-off diff.**

---

## 7. Edge cases

### 7.1 Orchestrator dies leaving a team file
Existing stale sweep runs per resolved team; `roster.mjs teams` surfaces orphans.
Nothing is auto-deleted.

### 7.2 Team name equals the effective default prefix
`create --team <T>` must `fail()` when `T` equals the effective unscoped prefix
**and** a live default team exists.

### 7.3 Same team name in different repos
Pre-existing; peer names have always been prefix-derived and machine-global.

### 7.4 `alias --set` while a team scope is active
`alias --set`/`--clear` `fail()`; `alias show` allowed, reporting both values
distinctly.

### 7.5 A member renamed out of `team.json` while live
**Membership wins** (§4.3) — row 3 or row 4 of **§4.5**.

### 7.6 Pre-existing untagged records
No `team` field → default-team degradation, **no migration, no backfill**.

### 7.7 `to_name: null` exchanges
Filter exchanges by team **before** the null-name fan-out.

### 7.8 A name that exists in two teams
**Prefer the team whose `orchestrator.pid` is alive; if still ambiguous, treat
the name as unattributed rather than picking one.**

### 7.9 Renaming an existing single-team repo
Past §5.3.1's trigger. Renaming is `alias --set`, offered when asked, never
volunteered.

### 7.10 Messaging a sibling team's ultra-advisor — **CONDITIONAL since (ii)**

> **Amendment (h) — corrected, and nobody asked me to.** (f) wrote this as a
> flat claim: *"a sibling's ultra-advisor is not gated by this hook."* (g)
> narrowed it to "given the session knows its own team." **Predicate (ii) makes
> it genuinely conditional, and a flat claim here would have been this spec's
> third stale negative** (§14 defects 4, 8).

| Acting session | (B) resolves? | Gated set | Sibling `U-ultra-advisor` |
|---|---|---|---|
| Orchestrator of `T`, session_id matching | **yes** | `T` only | **not gated** — file test 20 |
| Peer of `T`; or orchestrator post-resume | **no** | **union of all team prefixes** | **GATED** |
| Any session, repo with no named teams | n/a — guard no-ops | default prefix only | **not gated** — file test 19b |

**So the same `SendMessage` is gated from a peer session and ungated from its
orchestrator's.** A **deliberate, accepted consequence** of (ii): the union is
what a session falls back to precisely because it *cannot tell* which of those
names is its own, and over-gating there is the safe direction for a deny-default
gate (§9.3). Recorded here rather than left for a future reader to find and
mistake for a bug.

**Not gated in the resolution-succeeds case remains correct** — 0009's gate is a
per-session escalation control, not a repo-wide firewall, and cross-team
messaging stays out of scope (§8).

---

## 8. Out of scope

- Auto-detecting concurrent orchestrators beyond §5.3.5's `create`-time check.
- Screen real estate.
- Migrating a default team into a named one. Disband and re-create.
- Cross-team **messaging as a feature**.
- `roleFromName`'s unanchored substring matching (spec 0010 §8) — **and §9.6
  turns on this being out of scope.**
- **Changing `sessionstart.mjs`'s roster-record fields**, including the
  `pid`/`ppid` duplication (§4.2). Recorded, not fixed here.
- **§9.6's msg-gate `expectedTo` degradation** — deferred by explicit decision,
  with reasons, to its own item.

---

## 9. Files to change

| File | Change |
|---|---|
| `hooks/lib-config.mjs` | `teamPrefixInfo(cwd, team)`/`teamPrefix(cwd, team)`; `resolveConfig` gains `opts.team`/`opts.sessionId`, returns `resolved.team`; §4.4 rung 3. **`buildDirective` must pass `resolved.team` — §9.2.** |
| `hooks/lib-roster.mjs` | `teamPath(dir, team)`; `readTeam`/`writeTeam`/`clearTeam` forward it; member-name-set helper; `resolveMemberTeam(dir, name)`. |
| `hooks/lib-hier.mjs` | `roster()` implements **§4.5**; `buildStateBlock()` filters exchanges by team; `roleForPeerName` stays **team-scoped**; `roleForAnyPeerName(dir, name, resolved, repoBasename)` is the name-only **(A)** form. |
| `hooks/roster.mjs` | `--team`; `create` writes `teams/<T>.json`; `teams` verb; §5.3.5 refusal; §7.2/§7.4 guards. **No change to bare `create`.** |
| `hooks/msg.mjs` | `--team`; `new` writes frontmatter `team:`; `list` filters by team; read `CLAUDE_PID`. |
| `hooks/posttooluse-roster.mjs` | Tag `seen`/`briefed`; scope its `teamPrefix` call; **question (A) — VERIFIED SHIPPED**, `resolveMemberTeam` at `:29`, `roleForAnyPeerName` at `:66`/`:75`. |
| `hooks/sessionstart.mjs` | Pass `resolved.team` into the prefix. Roster-record write **unchanged** (§8). |
| `hooks/pretooluse-route-gate.mjs` | Uses **`resolveMemberTeam`** (§9.1). |
| `hooks/pretooluse-msg-gate.mjs` | **Scoped `teamPrefix(cwd, resolved.team)` ONLY. No membership lookup under this spec.** **§9.6 records a known degradation here and DEFERS it — do not fix it under 0011.** |
| `hooks/pretooluse-ultra-gate.mjs` | Scoped `teamPrefix`, **plus §9.5's predicate (ii)**. Still **no membership lookup.** |
| `docs/specs/0008-roster-relocate.md` | Amendment: §5.1 includes team scope. |
| `skills/agent-roster/SKILL.md` | `--team`, `teams`, §5.3.5, per-command `--team` needs, amendment (c)'s confirm flow. **§5.6's warning requirement is RETIRED — do not add it** (h). **It was never written in the first place** (i, §5.6). |
| `tests/test-roster-multi-team.sh` | New. §11. |
| `plugin.json` **and** root `marketplace.json` | Version bump — both. |

**Not changed:** `hooks/subagentstop-msg-nudge.mjs`, `hooks/sessionend-roster.mjs`,
`tests/test-roster.sh` (§4.2.1).

### 9.1 The gate blackout (amendment (b), finding B3)

Original §9 exempted route-gate because `hierarchyDir` was no longer re-scoped —
sound for `hierarchyDir`, **irrelevant to the actual dependency**: amendment (a)
had made `teamMemberByName`, `roster()`, and the prefix all team-sensitive.

Verified at source: `:235` `resolveConfig(cwd)` with **no `sessionId`**; `:237`
`teamPrefix(cwd)` unscoped; `:254`/`:256`/`:259` all miss a named team's members;
**no `roleFromName` fallback**; `role` stays `null` and both `:266` and `:273`
skip.

**Wider than reported:** the same unscoped `teamPrefix(cwd)` at
`pretooluse-msg-gate.mjs:73`, `pretooluse-ultra-gate.mjs:102`,
`posttooluse-roster.mjs:54`.

**Required — a rule, because a file list is what failed. Two independent
clauses; amendment (f) exists because I conflated them:**

> **(i)** Every hook that resolves a peer name to a **role** MUST resolve team
> scope first, per §4.4.1's assignment.
> **(ii)** Every hook that derives a **naming prefix** MUST pass the resolved
> team: **no hook may call `teamPrefix(` with a single argument.**

**Clause (ii) applies to every hook. Clause (i) applies only to hooks that
actually derive a role.**

> **Amendment (g) adds the clause nobody wrote:** satisfying (ii) makes a hook's
> prefix *as correct as its team resolution*, and **says nothing about whether
> that resolution can succeed in the session the hook runs in.** **A hook can be
> fully clause-(ii)-compliant and still be wrong every time it runs.** That was
> §9.5 — invisible to the static grep (test 6) by construction. **§9.6 is the
> same sentence applied to clause (i): msg-gate satisfies (i) as written, and is
> still wrong in every peer session.**

**route-gate's mechanism (amendment (d)):**

> **route-gate must use `resolveMemberTeam(dir, name)` — question (A).**

1. **It is the question actually being asked.**
2. **Consistency with the `roleFromName` widening** — **specific to an
   allow-default gate; does not generalise (§9.3).**
3. **The team-scoped form reintroduces B3's own failure mode** — a `null` there
   means the gate silently goes dark.

**What must NOT change:** the `null` role case must keep *allowing* (0009 §8.12).

### 9.2 `buildDirective` (amendment (d), recorded)

`buildDirective` computed `resolved.team` correctly and then **discarded it**,
calling single-arg `teamPrefix(resolved.cwd)`. **A genuine pre-existing bug**,
found only because §9.1 was a rule with a mechanical sweep rather than a file
list.

### 9.3 Widening resolution is not universally safe (f), corrected by (g) and (i)

| | route-gate | ultra-gate | **msg-gate `expectedTo`** |
|---|---|---|---|
| Posture | allow-default (0009 §8.12) | **deny-default** | **allow-default — an unresolved role SKIPS the check** |
| Failing to resolve **the target's role** | silent blackout | the message is simply not an escalation | **silent blackout — §9.6** |
| Failing to resolve **its own team** | (n/a — question (A)) | ~~nothing is lost~~ → was a BLACKOUT; **closed by §9.5(ii)** | **causes the above, since the role is derived from the prefix** |
| Resolving one more name | one more confirm — cheap | **one more denial** | **one more possible false rejection of a legitimate brief** |

> **Amendment (g).** The ultra-gate "own team" cell originally read *"nothing is
> lost"* undifferentiated. **False.** It conflated failing to resolve the
> *target's role* (harmless — the role is hardcoded) with failing to resolve
> *the session's own team* (a blackout). **Only one of those is benign.**

> **Before widening a gate's resolution, check which way the gate fails.
> Widening is a fix for a gate that fails open and a regression for a gate that
> fails closed.**

**(ii) widens a deny-default gate, which this rule warns against — and is still
correct**, because the rule is about *cost*, not prohibition: the alternative was
a blackout, and (ii)'s widening is confined by a guard to exactly the sessions
that cannot know better. **That was the Ultra-Advisor's call, not mine** (§9.5).

> **Amendment (i) removes a sentence and adds a warning.** §9.3 previously said
> msg-gate's prefix scoping made its predicate **complete**. **That is true of
> question (C) and false of the (A)-shaped use at `:79`** — see §3.3's boundary
> and §9.6.
>
> **And msg-gate is the case where the rule above cuts BOTH ways at once**: the
> gate fails open today (widening is indicated), but the available widening can
> make it fail closed on a wrong inference (widening is contraindicated).
> **When both directions apply, the rule does not decide — it tells you the
> change needs its own evidence, which is why §9.6 is deferred rather than
> patched.**

### 9.4 `posttooluse-roster.mjs` — **RESOLVED (i)**

§4.4.1 assigned it question (A) by reasoning, not verification. **Now verified at
source:** `resolveMemberTeam(dir, name)` at `:29` via `teamTagFor`, and
`roleForAnyPeerName(dir, name, resolved, repoBasename)` at `:66`/`:75`. **The
assignment was right and the code already implements it.** NEEDS-EVIDENCE (e)
closed.

### 9.5 RESOLVED-(ii) — ultra-gate in sessions that cannot resolve their own team

**Opened by (g); ruled by Ultra-Advisor (`20260825-121657-997n`); shipped by
Implementor (`20260825-125913-1k1w`); verified at source by me; code signed off
by Reviewer's third pass — all five divergence points traced.**

**The defect, as confirmed:** `resolveTeamScope` (`lib-config.mjs:467-483`)
returns a team only via `opts.team` (:468) or an `orchestrator.session_id` match
(:476), and **`team.json` stores identity for the orchestrator only** — so every
peer session resolved `null`, took the default prefix, and
`pretooluse-ultra-gate.mjs` (which has **no** session-type guard — `isSubagent(`,
`agent_type`, `source` all absent) tested for a `<default>-ultra-advisor` that
typically does not exist. **Escalations from peer sessions in a named team were
ungated.**

**The ruling: predicate (ii)** — gate the union of all team prefixes **when and
only when** team resolution fails in a repo that has named teams. Rejected: (i)
accept the blackout; (iii) role-suffix matching (over-broad, and colliding with
0010 §8).

**Verified as shipped** — `pretooluse-ultra-gate.mjs:120-121`:

```js
const teamNames = resolved.team === null ? listTeamNames(hierarchyDir(cwd)) : [];
const gatedPrefixes = teamNames.length > 0
  ? [repoBasename, ...teamNames.map((team) => teamPrefix(cwd, team))]
  : [repoBasename];
```

Both halves of the guard are present and correctly ordered: `resolved.team ===
null` gates the lookup, `teamNames.length > 0` gates the union, and the `else`
branch is `[repoBasename]` — **byte-identical to pre-(ii) behaviour**, so §10
holds by construction rather than by test alone. **No membership lookup was
added**, so (f)'s ultra-gate half stands untouched.

**Coverage:** file tests 18 (peer → own team's ultra-advisor **IS** gated),
19a/19b (no named teams → byte-identical), 20 (§7.10 preserved where resolution
succeeds). **File test 18 is the inverted characterization test** §11 required —
written to pass against the blackout, flipped when the ruling landed.

**Residual, accepted, documented:** §7.10's asymmetry. All residuals move toward
**more** gating; none removes a control. **This is why §5.6 is retired rather
than softened.**

### 9.6 DEFERRED — msg-gate's `expectedTo` is dark in every peer session of a named team

**Found by the Reviewer's third closing pass. Verified at source by me. Real,
created by 0011, and deferred by explicit decision — recorded here so it cannot
be inherited silently the way §9.5 nearly was.**

**The chain, verified:**

| Step | Evidence |
|---|---|
| `role` starts null; set only on the dispatch path | `pretooluse-msg-gate.mjs:57`, `:60` |
| on the `SendMessage` path it is derived from the **scoped prefix** | `:69` `resolveConfig(cwd, {sessionId})`; `:74` `teamPrefix(cwd, resolved.team)`; `:75` `PEER_ELIGIBLE_ROLES.find(r => resolvedPeerTargets(r, resolved.roles[r], repoBasename).includes(to)) \|\| null` |
| in a peer session `resolved.team` is `null` (§4.4 (B)) ⇒ default prefix ⇒ `T-architect` never matches ⇒ **`role === null`** | by construction |
| that null is passed as `expectedTo` | `:79` `validateRequestToken(text, dir, role)` |
| and the check is **skipped**, not failed | `lib-hier.mjs:358` `if (expectedTo && parsed.fm.to !== expectedTo)` |

**What is actually lost: only the `to:`-matches-role cross-check.** Everything
security-relevant in `validateRequestToken` is **unconditional and unaffected** —
token present (`:353`), absolute and existing (`:354`), **under `msgsDir(dir)`**
and named `--request.md` (`:355`), parses with frontmatter `type: request`
(`:357`). **A routing lint, not a consent control.** That is the whole reason
this is not §9.5.

**It is nonetheless 0011's.** Pre-0011 every session derived the repo basename,
orchestrator and peers agreed, and `:75` resolved. **The divergence is ours** —
the same refusal I made in (g) applies, so this is *deferred*, never *inherited*.

**Ruling: DEFER, out of scope for 0011.** Three reasons, in order of weight:

1. **The obvious fix can fail in the dangerous direction.** The in-repo (A)-form
   is `roleForAnyPeerName(dir, name, resolved, repoBasename)`
   (`lib-hier.mjs:441-455`) — `resolveMemberTeam` first, then the prefix scan,
   **then `roleFromName(name)` as a final fallback** (`:454`). That tail is
   0010 §8's **unanchored substring matcher, explicitly out of scope** (§8).
   Swapping it in converts *"check skipped"* into *"check runs against a
   possibly-wrong inferred role"*, and a wrong `expectedTo` makes
   `validateRequestToken` return `{ok:false}` — **rejecting a legitimate brief.**
   **A fail-open gate becoming capable of failing closed is not a change to make
   in the same session that a diff was signed off in.**
2. **A safer variant exists but is unspecified and unmeasured** — membership-only
   resolution with no `roleFromName` tail. That is a **new function**, not a
   swap, and I cannot design it against evidence I do not have.
3. **NEEDS-EVIDENCE (d) would dissolve it at the root**, exactly as it would have
   dissolved §9.5: if a peer can resolve its own team, `:75` resolves correctly
   with **no change to msg-gate at all** and no new matching semantics anywhere.
   **Fixing this hook before (d) is answered risks paying for a mechanism that
   (d) makes unnecessary.**

**What the deferred item must carry:** this section by reference, the two fix
candidates and why candidate 1 is not safe on its own, and the dependency on
NEEDS-EVIDENCE (d).

**Confidence: moderate on the deferral, high on the diagnosis.** The chain is
verified line by line. The *scope* call rests on my reading that `expectedTo` is
a lint rather than a control — **if a reviewer thinks that check is load-bearing
for something I have not considered, that reading is the thing to attack**, and
the ruling should be revisited rather than the section reworded.

---

## 10. What must not change

**Baseline invariance, defined (amendment (c)):**

> **Absent an explicit user choice, a repo behaves exactly as it does today —
> identical paths, names, and file contents. A confirmation the user *accepts*
> must produce byte-identical output to today; only an override changes
> anything, and an override is by definition the user opting in.**

**This section, not §4.5, is the definition of default-team behaviour.**

**Amendment (h):** (ii) preserves this **structurally, not incidentally** — its
`else` branch is literally the pre-(ii) expression, so a repo with no named teams
cannot take the widened path. File tests 19a/19b pin it; the code shape is the
actual guarantee. **§9.6's degradation is likewise unreachable without a named
team**, which is why it does not block merge either.

Also unchanged:

- `hierarchyDir(cwd)`'s signature, meaning, and all 20 call sites.
- `validateTeamAlias`'s rule and its `why` strings.
- `createMessage`'s delivery model.
- `validateRequestToken`'s unconditional checks (`lib-hier.mjs:353-357`) — **§9.6
  degrades only the guarded `expectedTo` branch at `:358`.**
- `sessionstart.mjs`'s roster-record fields, including the `pid`/`ppid`
  duplication (§4.2, §8).
- 0009's fail-open catch, including the allow-on-`null`-role posture.
- **0009's ultra-gate deny semantics**, with **one deliberate, ruled exception**:
  §9.5's predicate (ii) widens the *gated name set* under its guard. Recorded as
  a change, not smuggled as a fix.
- 0008's single-writer rule.
- **All default-team `roster()` output.**

---

## 11. Verification

> **Test numbers below are logical. The implementation file numbers them
> differently, and renumbered them twice during this spec's life. The file's
> numbering is internal to the file and is NOT part of this spec's contract —
> cite behaviour, not a number, when referring to a test from outside the file.**
> (Added by (i); the numbering drift was itself one of the stale references this
> amendment closed.)

1. **Baseline invariance.** Existing suite passes unchanged with no `--team`.
   Run first. **Hard requirement.**
2. **Two teams, isolated rosters**, from the **shared** `peers.jsonl`.
3. **Exchange-count isolation**, including `to_name: null` (§7.7).
4. **Unattributed bucket, both sides of the §4.2.1 carve-out**, in one test.
5. **Static grep.** No file outside `lib-roster.mjs` constructs a `team.json`
   path.
6. **Static grep.** No file in `hooks/` calls `teamPrefix(`/`teamPrefixInfo(`
   with one argument — clause (ii). **Note its limit (§9.1): it proves the
   argument is passed, never that it holds the right value. §9.5 and §9.6 are
   both invisible to it.**
7. **Gate liveness under a named team.** **The failing state is silence — assert
   positively that the gate spoke.**
8. **Degradation.** Missing `team` field and missing `teams/<T>.json` both
   resolve to the default team without throwing.
9. **CLI rung 3.** `CLAUDE_PID` matching a live team resolves it; pid dead →
   falls through.
10. **Non-interactive `create`.** Bare `create`, no TTY, still succeeds.
11. **Collision refusal**; **alias refusal**; **name validation** with 0010's
    exact `why` text.
12. **§4.5 attribution rows.** All four under a named scope — especially **row 3,
    a sibling's member absent from both my role buckets and my `unattributed`** —
    plus the default-team counterpart.
13. **Gate resolution mechanism, route-gate only.** **Do NOT extend to msg-gate
    or ultra-gate** (f) — **and note (i): that instruction is about the
    *mechanism*, and it is not an assertion that msg-gate is correct. §9.6 is.**
14. **Ultra-gate scope where resolution succeeds** (f). Gates its own
    `T-ultra-advisor`; does **not** gate a sibling's.
15. **§9.5's blackout — INVERTED (h).** Originally specified as a known-failing
    characterization test asserting the gate does **not** fire, labelled so
    whoever implemented the ruling had to consciously flip it. **It was
    flipped**: a peer session escalating to its own named team's
    `T-ultra-advisor` **IS** gated. **The mechanism worked as intended** — the
    open question lived in executable form until it was answered, instead of
    only in prose.
16. **(ii) does not touch the baseline (h).** No named teams ⇒ default-prefix
    ultra-advisor still gated, unrelated prefix not — the guard no-ops.
17. **§7.10's asymmetry (h).** An orchestrator that resolves its own team still
    does not gate a sibling's `U-ultra-advisor`.
18. **§9.6, characterization — OPTIONAL, and deliberately so (i).** If the
    deferred item is picked up, it should open with a test asserting today's
    behaviour: in a peer session of a named team, a brief whose `to:` does
    **not** match its addressee is **allowed through**, because `expectedTo` is
    null. **Not required under 0011** — 0011 is not fixing this, and a
    characterization test with no owner and no scheduled inversion is a
    tripwire nobody is watching. **The §9.5 pattern earned its keep because the
    ruling was already in flight; this one has no such deadline.**

---

## 12. NEEDS-EVIDENCE

- **(a), (b), (c) — resolved.**
- **(d) — OPEN, and it is now the root fix for TWO defects.** Does the claude CLI
  surface `--name <peer-name>` to hooks? (g) promoted it because it would have
  dissolved §9.5; (ii) has since closed §9.5, **but §9.6 is the same root cause
  and is NOT closed.** A peer that knows its own team would make (ii)'s guard
  never fire, remove §7.10's asymmetry, **and fix §9.6 with no code change to
  msg-gate.** **Still not blocking, and now the single highest-leverage open
  question in this spec's orbit.**
- **(e) — RESOLVED (i), from shipped source.** `posttooluse-roster.mjs` derives a
  *team for a name*: `resolveMemberTeam` at `:29`, `roleForAnyPeerName` at
  `:66`/`:75`. §4.4.1's (A) assignment was correct. See §9.4.

---

## 13. Open items

> **Amendment (g) — this section once read "Open questions: **None**" while §12
> listed open evidence items. The Reviewer flagged the contradiction and was
> right.** Cause: I used "open questions" to mean *questions only the user can
> answer* while §12 tracked empirical ones, **and never said so.** Listing by
> **owner** is the fix; deleting either side would have hidden a real item.

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | **§9.5** — ultra-gate's predicate | Ultra-Advisor | **RESOLVED** — (ii) ruled, shipped, verified at source, code signed off |
| 2 | **NEEDS-EVIDENCE (e)** — `posttooluse-roster.mjs`: team or prefix? | Implementor | **RESOLVED (i)** — team, already shipped (§9.4) |
| 3 | **§9.6** — msg-gate's `expectedTo` blackout | **a NEW item, not 0011** | **DEFERRED by explicit ruling (i).** Diagnosis complete; scope call is mine and is stated with its reasoning and its weak point |
| 4 | **NEEDS-EVIDENCE (d)** — does `--name` reach hooks? | Implementor | Open. **Root fix for §9.6 and for §7.10's residual.** Not blocking |

**Questions for the user: none.** Amendment (c) settled the only one.
**Nothing open blocks close-out.** Item 3 must be **filed**, not forgotten — that
is the whole difference between deferring and inheriting.

---

## 14. Confidence and escalation

**High on the mechanism.** Amendment (a)'s design is smaller than what it
replaced, requires nothing of peer processes, and degrades correctly.

**§9.5 was escalated, and the escalation was the right call.** The fix turned on
what 0009's ultra-gate is *for*; two of three options widened a deny-default gate
against my own §9.3 rule; and **I had already been wrong about this hook family
twice in this spec.** The Ultra-Advisor chose (ii) — the option I recommended,
but at low confidence and for reasons I could not fully settle alone. **Being
right about the answer would not have made deciding it alone correct.**

**§9.6 I did NOT escalate, and that is a judgment worth stating plainly.** The
diagnosis is verified line by line; the *scope* call is a design decision inside
my remit, its stakes are bounded (a routing lint, with every authorization check
unaffected), and I have named the reading it depends on so it can be attacked
directly. **If the `expectedTo` check turns out to be load-bearing for something
I have not seen, this needs the Ultra-Advisor, not a reword.**

My *original* escalation trigger — *"if (b) comes back negative, ask
Ultra-Advisor how peers get a team scope without a race"* — came back negative
and I withdrew it as **the wrong question**, on the grounds that peers need no
team scope. **(g) showed that withdrawal was half right; (i) shows how expensive
the other half was.** Peers need no team scope *to filter shared records*, which
is what I was looking at. Peers absolutely need one *for anything that decides
something about the session it runs in* — **and there turned out to be two such
hooks, not one.** **The right response to a trigger firing is to re-scope the
question, not to drop it.**

**Nine defects of mine, in three shapes.**

*Shape 1 — asserting a property without checking the precondition that makes it
true or detectable:*

1. **Asserted a delivery mechanism I had not traced** (a) — the strongest
   argument for directory scoping, and false.
2. **Test 5 asserted a fact I never checked** (20 sites, 9 files).
3. **§4.2 stated two absolutes without checking the baseline** (S1).
4. **§9's exemption list survived a change to its own premise** (B3). **A safety
   gate went dark and I shipped the spec that did it.**
8. **§9.3's "nothing is lost" asserted a negative about a gate I had not traced
   into the sessions it runs in** (g) — **same shape as defect 4, in the very
   section written to stop repeating defect 4.**
9. **§5.6 marked a `SKILL.md` warning REQUIRED and nothing was ever written**
   (i) — zero matches at source. **Three review passes verified code against
   spec; none checked that spec-mandated *documentation* shipped.** The
   asymmetry is the lesson: **a spec's non-code deliverables have no test, no
   diff, and no reviewer by default** — so "REQUIRED" in a spec means "someone
   will notice" only for things that appear in a diff.

Shared variant: **an amendment invalidates its own document's earlier reasoning,
and the parts justified by the old premise are the parts nobody re-reads.**
Exemptions, exclusions, and "nothing is lost" claims state a *negative*, and
**a stale negative is invisible.**

> **(h) was the first time this was caught before it shipped.** (ii) falsified
> two standing claims at once: §5.6's warning and §7.10's flat "siblings are not
> gated." **Only §5.6 was routed to me.** §7.10 came out of deriving (ii)'s
> consequences against every claim the spec already made. Honest asterisk:
> **externally triggered, internally extended** — better than defect 8, short of
> noticing unprompted.

*Shape 2 — writing prose that permits a reading I did not mean:*

5. **§10's invariance rule said less than I meant** (c) — I nearly rejected good
   user feedback by citing my own sentence back at it. **When a rule I wrote
   appears to forbid a reasonable request, check first whether the rule says what
   I meant.**
6. **Five instances:** §7.5/§7.6's unshown partition; §9.1's ambiguous
   `roleForPeerName` citation; §4.5's *"in full"* over a two-item list; §13's
   "Open questions: None" contradicting §12; **and §9.3's "so it is complete"
   about msg-gate, true of (C) and false of the (A)-shaped use it actually
   feeds** (i). **A section that defers should say only that it defers, and name
   where.**

*Shape 3 — a rule with two clauses, applied as if it had one:*

7. **§9.1's rule ORs "resolves a name to a role" and "derives a naming prefix,"
   and §4.4.1's table gave every hook in the sweep the role-resolution
   mechanism** (f) — which would have **widened what a deny-default gate
   denies.** Lessons: **a rule that ORs two conditions produces a set, and
   assigning one mechanism to that whole set silently claims the conditions are
   equivalent**; and **"more resolution is safer" is a property of the gate's
   failure direction, not of gates.**

   **From (g):** clause (ii) is *mechanically checkable* (test 6) and clause (i)
   is not, so the sweep went green while proving only that an argument was
   *passed*, never that it held a *correct value*. **A static check on a call
   signature is not a check on a call's meaning.**

   **From (i), the sharpest version:** (f) reclassified msg-gate as (C) **by
   looking at the mechanism `:75` uses** rather than at what `:79` does with the
   result — **precisely the error §4.4.1's own rule forbids, committed in the
   amendment that wrote the rule.** The correction to §4.4.1 now names the
   mechanism trap explicitly, because stating the rule was demonstrably not
   enough to make me follow it.

**Every countermeasure that worked was external:** the Orchestrator routing
(b)/(c) as real experiments and re-routing the close-out sweep twice; the
Reviewer tracing §9's exemption at source, catching (e)'s wording, catching §9.5
in a table written *specifically* to reason carefully about gates, and then
catching §9.6 — **the same root cause, one hook over, after I had already
declared the family clean**; the user asking why the first team never gets a say;
the Ultra-Advisor settling a fork I should not have settled; and — twice — **the
Implementor stopping rather than implementing a spec instruction that did not
match the code in front of it.** Amendment (f) exists only because a role
forbidden to make design decisions declined to enact one.

**One internal countermeasure demonstrably worked:** §11's inverted
characterization test carried an open question forward in executable form until
the ruling landed. **A blackout recorded only in prose is how B3 survived two
reviews** — and §9.6 is now recorded in both prose and a filed item, because
that is the lesson's actual price.
