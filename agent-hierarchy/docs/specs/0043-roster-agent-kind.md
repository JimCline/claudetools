# 0043 — Per-member `kind`: roster members spawnable as non-Claude agent CLIs

Status: r7, implemented and under review. Author: Architect.
r7 changes: **text only, no code change** — §4.3 gains the `--` separator it
was missing (a spec error, not an implementation one) and now states
explicitly that it asserts substantively rather than by exact string equality,
with the reasoning for why it differs from §4.1 on that point. Closes the
Implementor's gap [3.7]; the shipped tests already match this and stay as they
are.
r6 changes: three spec-defects found by the Reviewer against the real diff, all
mine, all resolved here. (1) §1.4's `--timeout` requirement is **deleted** —
Herdr's documented default is 30000, which is exactly what was being passed, so
the flag was inert while being the sole cause of a §1.4-vs-§3 contradiction and
a wrong expected launch string. **This one needs a code change, not just text.**
(2) §1.7's name rule was written as one hard failure for all kinds; it is a
*herdr-transport* constraint, so it is now hard-error for non-claude (herdr is
mandatory there) and warn-only for claude (which may legitimately spawn on
tmux/terminal). `tests/test-roster-spawn-cwd.sh` T4 stands unchanged. (3) §1.1
claimed a "single application point" for the kind default; that was false as
built and dangerously so — corrected to single *definition*.
r5 changes: **N6 resolved POSITIVE** (brief `20260907-210706-1tgm`) — a codex
agent does reach a genuine interactive state under Herdr, so §1.4/§1.6's
premise holds. Two follow-on findings, both now specified: §1.6 separates
**liveness** from **readiness** (they are the same thing for a Claude peer and
are *not* for a Herdr-driven agent — `blocked` is live but not promptable), and
§1.4 handles the first-run trust prompt as a first-class startup outcome rather
than a failure. Auto-dismissing that prompt is **refused** — see §6.
r4 changes: live-herdr evidence folded in (brief `20260907-210039-ei1x`).
N1/N3/N4/N5 settled — §1.2 records the observed kind list, §1.6's liveness is
now written against the real `herdr agent get` shape. **One correction to my own
r2/r3 text:** the liveness table read "agent absent / command errors → not
live", which conflates `agent_not_found` with Herdr itself failing; a Herdr
outage would then mark every non-claude member dead and invite duplicate
spawns. Split into not-live vs indeterminate in §1.6. N2 produced a real
finding (run-and-exit `args` ⇒ startup timeout, name never registers, pane
orphaned): handled in §1.4 and §1.9. New **N6** — a *successful* non-claude
readiness detection has still never been observed, and that is now the largest
open risk in this spec.
r3 changes: both open forks settled by the user (brief `20260907-205844-1396`) —
F1 native-args passthrough YES, F2 route value name `pane`. F2 needed no text
change (the spec already chose `pane` throughout). **F1 did**: r2 had written it
as a refused item, so it appeared in no design section, no files-to-change and
no test — an Implementor reading r2 would not have built it. It is now §1.9,
with the shell-quoting requirement that a verbatim passthrough into
`/bin/sh -c` makes mandatory. §1.3, §2, §4.2/§4.5 and §6 updated to match.
r2 changes (late retrieval landed after r1 was written, four spec defects):
§1.3 the `ROLE_DEFAULTS` model trap that would have made non-claude members
uncreatable, plus `on-missing`'s status under `route: pane`; §1.5 `add` must
spawn a `pane` member rather than defer it; §1.7 the name check cannot live in
`validateMember`, which rejects a stored `name`; §2 corrected to
`ROSTER_ROUTE_VALUES` and the real edit sites. §4.2/§4.3 gained the tests that
catch each.
Briefs: `20260907-204436-pxvg` (base) + `20260907-204916-na9m` (comms refinement,
folded into §1.6). Investigation: `20260907-204606-1lqw` (Implementor trace).
Precedent: 0010 (herdr as an optional transport), 0021 (per-role spawn policy),
0025 (member validation), 0035 (spawn placement).

## Requirement (from the Orchestrator's brief)

A roster member is today always a Claude session at some model tier. The user
wants members spawnable as other agent CLIs too — Herdr's
`agent start <name> --kind <kind>` already starts `claude`, `codex`, and
whatever else that install recognizes.

**Explicit, non-negotiable user instruction:** when kind is unspecified, it is
`claude`. That must hold for configs written before this spec (no key present)
and for a member added without naming a kind.

**Settled by the user during design** (brief `na9m`, user's own words: *"So of
course if an orchestrator from claude is trying to talk to a Pi implementor for
example, it will need to use herdr's agent communication channels."*):
non-claude members are dispatched through Herdr's agent-control surface, not
SendMessage/ListAgents. §1.6 is written as design, not as an open question.

## 0. Findings that shape the design

**F1 — There is exactly one launch-shape function, and it already says
`claude` twice.** `hooks/roster.mjs:299-332` `spawnShape()` is the sole builder
of the launch command for all three transports, shared by `spawn-one`
(`:1188`), `create --spawn` (via `resolveMembersPlan` `:760`) and history
replay (`:809`) — extracted, not forked (header comment `:1120-1125`). It
hardcodes the binary name `claude` at `:301` and the literal `--kind claude` at
`:307`. This is the smallest possible seam for the change, and it means one
edit covers every spawn entry point.

**F2 — Two of the three transports cannot launch a non-Claude agent at all.**
`spawnShape`'s tmux branch (`:315-327`) sends the string `claude <flags>` into
a pane; the terminal branch (`:331`) execs `claude … --bg`. Only the herdr
branch (`:302-314`) delegates the "how do I start this kind of agent" question
to something that knows the answer. Teaching roster.mjs each kind's binary name
and argv would duplicate knowledge Herdr already owns and would go stale on
every new kind. Transport detection is `detectTransport()` `:289-297`
(`HERDR_ENV === "1"` → herdr, else tmux, else terminal).

**F3 — `model`, `effort` and `auto-mode` are Claude CLI flags, not abstract
concepts.** `spawnShape:300` renders them as `--model`, `--effort` and
`--permission-mode`; `auto-mode`'s value set (`hooks/lib-roster.mjs:68`) is
Claude Code's permission modes. `model` is validated against a Claude model
allowlist per role (`hooks/lib-roster.mjs:106-109` against
`VALID_MODELS_BY_ROLE`, `hooks/lib-config.mjs:107-113`). None of the three has
a meaning for a `codex` or `pi` process, and roster.mjs has no way to learn
another kind's spelling for them.

**F4 — Addressability is a property of the Claude Code CLI, not of the roster
or herdr layer.** A peer address is a derived *name* string
(`hooks/lib-config.mjs:379-387` `rosterMemberNames` → `peerName`), injected as
`--name` at `:300`; the Claude CLI itself registers that name in its
cross-session directory and opens the uds socket. Nothing in agent-hierarchy
registers an address — it only *observes*: the spawned session's own
SessionStart hook writes `status:"up"` into `peers.jsonl`
(`hooks/sessionstart.mjs:100-131`), and the orchestrator's PostToolUse scrapes
`ListAgents` output for `status:"seen"` (`hooks/posttooluse-roster.mjs:33,
60-70`). `transport_id` is used only for pane close/move (`:950-959`,
`:2050-2080`), never for messaging.

Consequence: a `codex`/`pi` process runs no Claude hooks, registers no name,
and appears in no `ListAgents` listing. It can never be SendMessage-addressable
and can never satisfy `memberIsLive()` (`hooks/roster.mjs:1001-1005`), which
reads `peers.jsonl`. This is not a gap to be plugged — it is the reason §1.5
and §1.6 exist.

**F5 — Herdr already documents the whole non-Claude control surface.** From
`~/.claude/skills/herdr/SKILL.md`: `agent start … --kind <k> --pane <p> [--
<agent-args…>]` (:111, :117); `agent prompt <name> "…" --wait --timeout <ms>`
(:125); `agent wait <name> [--until <state>] --timeout <ms>` (:135);
`agent read <name> --source recent-unwrapped --lines <n>` (:151);
`agent get <name>` (:150); `agent send-keys <name> <key>` (:143-144);
`agent list` (:85). Lifecycle states are `idle`, `working`, `blocked`, `done`,
`unknown` (:54, :58) — with the explicit warning that `unknown` "does not prove
completion". Most control commands return JSON (:44). **No `agent stop` or
`agent kill` is documented** (see §5 N4).

**F6 — Herdr constrains agent names more tightly than the roster does.**
SKILL.md:56-57: names must match `[a-z][a-z0-9_-]{0,31}` and be unique among
live agents. The roster's derived names (`<repo-basename>-<role>[-N]`) are not
checked against this today, so a long repo basename plus `ultra-advisor` can
already exceed 32 characters for a *claude*-kind herdr member. Pre-existing
latent defect; see §1.7.

**F7 — The `kind` term is unused in the schema.** `grep -rn 'kind'` over
`hooks/` returns only the hardcoded `--kind claude` at `:307` and unrelated
`{kind: "json"|"stdout"}` source descriptors (`:313`, `:326`, `:344`, `:346`).
No collision. The member record (`hooks/lib-roster.mjs:102-124` `validateMember`,
`:132-156` `validateTeamMember`) carries `role`, `model`, `effort`, `route`,
`autoMode`, `onMissing` (+ `name`, `transport_id`, `tab_id`, `workspace_id` on
the team record) and nothing that records *what was launched*.

## 1. Design

### 1.1 The field

Add `kind` to the roster member record: a per-member string, sibling of `role`
and `model`, JSON key `kind` (no case transformation needed, unlike
`auto_mode`/`autoMode`).

**Default.** Absent or null resolves to `"claude"`.

**One definition, many call sites — deliberately (corrected r6).** r5 said the
default is applied "at the single point… so no consumer has to re-apply the
default". That is false as built and, worse, is an invitation to break the
feature: the resolver is called again by `validateMember`, `normalizeMembers`,
`statusReport`, `spawnShape`, `memberLiveness`, `labelPane` and `spawnOneCore`.
Every one of those calls is correct and defensive — members reach those
functions by more paths than the normalize seam (a hand-edited config file
reaching `spawnShape` is the obvious one), and a reader who "removes the
redundancy" on the strength of r5's sentence reopens precisely the absent-kind
bug this feature exists to prevent.

The requirement is therefore: **a single shared definition of the default, and
no consumer that treats absent-kind as its own case.** Not a single call site.
Resolution must be idempotent and cheap enough that calling it defensively
costs nothing — which is what makes the repetition safe rather than smelly.
Note the resolver lives in `hooks/lib-config.mjs` and is re-exported into
`hooks/lib-roster.mjs`; that placement avoids a module cycle (`lib-roster.mjs`
already imports from `lib-config.mjs`) and is the right call, not an accident
to tidy away.

**Persistence.** Do not rewrite existing config files to add `kind: "claude"`.
Write the key only when it is not `claude`. Rationale: the default is total, so
writing it adds churn to every roster file for zero information. A file that
*does* carry `kind: "claude"` explicitly must be accepted unchanged.

### 1.2 Validation of the value

**Shape only.** A kind must be a non-empty string matching `[a-z][a-z0-9-]*`.
There is **no allowlist** of kind values in this codebase.

Rationale, and it is load-bearing: Herdr owns the installed-kind list, it
varies per machine and per Herdr version, and Herdr's own SKILL.md (:114)
instructs the reader to run `herdr agent` to discover it rather than assume.
An allowlist compiled into `roster.mjs` would be wrong the day a new kind
ships, and would reject a portable/global roster authored for a machine where
a kind is installed but this one where it is not. An unrecognized kind fails at
spawn time, where Herdr produces the authoritative error (§1.4).

Do **not** add a live `herdr agent` probe to `add`/`edit`. Config authoring
must not require a Herdr session, and the probe would only move the same
failure earlier while making a pure config edit depend on process exec.

**Observed list (r4, N1), for docs and examples only — not to be encoded as a
check:** `pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`,
`omp`, `mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`,
`grok`, `hermes`, `kilo`, `qodercli`, `qwen`, `maki` — 21 kinds on the install
tested. This is a snapshot of one machine's Herdr build and is exactly why §1.2
validates shape rather than membership: the list is long, install-specific, and
will grow.

### 1.3 What `kind` changes about the other fields

| field | `kind: claude` | `kind` anything else |
|---|---|---|
| `model` | unchanged — every existing per-role rule in `VALID_MODELS_BY_ROLE` (`lib-config.mjs:107-113`) still enforced | **must be absent/null** |
| `effort` | unchanged | **must be absent/null** |
| `auto-mode` | unchanged | **must be absent/null** |
| `route` | `peer` or `subagent`, unchanged | **must be `pane`** (§1.5) |
| `args` | **must be absent** (§1.9) | optional native-args passthrough (§1.9) |
| `role` | unchanged | any role; but see §1.8 — the role's `agents/*.md` contract is *not* loaded |

Presence of `model`, `effort` or `auto-mode` on a non-claude member is a **hard
error at add/edit**, naming the field and the reason (it is a Claude Code CLI
flag with no meaning for that kind). It must not be silently ignored: silently
ignoring it means `/agent-roster show` displays a model that has no effect on
anything, which is worse than a rejection.

**Trap — the role default would defeat this rule.** `roster.mjs`'s `add`
(`:1302`) fills `model` from `ROLE_DEFAULTS[role].model`
(`lib-config.mjs:81-87`) whenever `--model` is not supplied. Applied naively,
*every* non-claude add would auto-populate a model and then be rejected by the
rule above, making non-claude members impossible to create. Requirement: the
role-default model is applied only for `kind: claude`. A non-claude add leaves
`model` unset. The same holds for any other field that acquires a value by
default rather than by the user naming it.

**`on-missing`** stays legal for a `pane`-routed member and keeps its
spawn-selection meaning (`spawnOneCore` picks an `on-missing: auto` member
first, `:1144`). Only its *peer-fallback* meaning — what the route gate does
when no live instance answers — has no analogue here, because there is no
subagent to fall back to. The existing guard that rejects `on-missing` on a
`subagent`-routed member (`add` `:1305`, `edit` `:1373`) must not be extended
to `pane`; `show`'s inert-reason tag (`lib-config.mjs:986-990`) should say so
for `pane` rather than reusing the subagent wording.

Rejected alternative: reusing `model` as an opaque per-kind string passed
through to that kind's own model flag. We do not know any other kind's
model-flag spelling and roster.mjs cannot learn it — Herdr's `--` passthrough
is verbatim native args, not a translated interface. Making one field mean "a
validated Claude tier enum" for one kind and "an unvalidated opaque string" for
others buys nothing today and makes the field's type depend on a sibling field.
The way a non-claude member *does* get native flags is §1.9's passthrough.

### 1.4 Spawn

**The change to `spawnShape` (`hooks/roster.mjs:299-332`) is small and exact:**
the herdr branch's `--kind claude` (`:307`) becomes the member's resolved kind,
and the Claude-specific `agentFlags` are emitted only for `kind: claude`. For
every member resolving to `claude`, the produced launch string must be
**byte-identical to today's**. That identity is the backcompat proof and is
directly testable (§4).

**Non-claude kinds require the herdr transport.** Forced by F2, not chosen. If
`detectTransport()` returns `tmux` or `terminal` and a member's kind is not
`claude`, that member is **refused, not launched**: no command is shelled for
it, its `launch_status` is `failed`, and `launch_result` states the member
name, its kind, the detected transport, and that non-claude kinds require a
Herdr session (`HERDR_ENV=1`). Other members in the same `create --spawn`
continue — partial spawn is already the model (`createSpawn` reports `partial`,
`:1090`).

Add/edit of a non-claude member outside a Herdr session must still **succeed**,
with a warning. Rosters are portable and the global-level roster is explicitly
authored away from where it is spawned; refusing the edit would make a global
roster uneditable from a non-Herdr session.

**Herdr's own errors pass through verbatim.** If `herdr agent start` rejects
the kind, the message reaching the user is Herdr's stderr, unmodified, in
`launch_result`. Do not re-word it — Herdr knows what kinds it has and this
codebase does not (§1.2).

**Pane label.** `labelPane()` (`hooks/roster.mjs:838`) composes the pane border
from the literal string `"claude"`. It must use the member's kind, so a codex
member's pane reads as codex.

**Startup timeout (r4, amended r6).** `herdr agent start` blocks until Herdr
detects a ready agent, and fails with `{"error":{"code":"timeout",…}}` if it
never does. Requirement: treat `code: "timeout"` distinctly from other launch
failures in `launch_result`.

**Do not pass `--timeout`.** r4 required an explicit one on the reasoning that
"an unknown default governs". That reasoning was wrong: `herdr agent start
--help` documents `--timeout <MS>` with **default 30000, max 300000**, so the
default is known, and passing 30000 explicitly changes nothing while costing
two real things — it contradicts §3's byte-identical-claude-launch-string rule,
and it makes §4.3's expected string wrong. A flag that alters no behaviour and
breaks an invariant is strictly worse than its absence.

Upgrade path if evidence ever shows 30s is too short for some kind: add
`--timeout` **then**, with a non-default value, and **only for non-claude
members**, so the claude launch string stays byte-identical. No such evidence
exists today — the observed timeout case took the full 30s only because nothing
was ever going to become ready, and the blocked case returned immediately.

This is not a rare edge. It is the *guaranteed* outcome whenever a member's
`args` (§1.9) cause the target CLI to run and exit instead of staying
interactive — verified live: `--kind codex … -- --help` printed codex's help,
exited to a bare shell, and timed out at 30s. Because `args` is free text over
21 different CLIs, a wrong flag is an ordinary user error, not an exotic one.

**On a startup timeout the agent name is never registered** — verified:
`herdr agent get <name>` and `herdr agent get <pane_id>` both return
`agent_not_found` afterwards. So there is nothing to query, retry against, or
tear down by name; only the pane survives.

**Blocked-at-startup is a normal outcome, not a failure (r5, N6).** A kind with
its own onboarding gate returns, quickly and without waiting out the timeout,
`{"error":{"code":"agent_not_ready",…}}`, and `herdr agent get` then reports
`agent_status: "blocked"` with `launch_pending: true`. Verified live: codex's
first-run *"Do you trust the contents of this directory?"* prompt does this on
a fresh cwd. Herdr's detection is working correctly here — this simply is not
the ready state.

This is the **expected** result of the first spawn of such a kind in a given
directory, not an error, and it must be reported as its own launch outcome —
**distinct from `failed`** (the Implementor picks the spelling; the existing
set is `ready`/`dispatched`/`failed`/`null`). Requirements:

- The member **is live** and the agent **is queryable by name**. Nothing is
  orphaned; nothing needs cleanup. This is the opposite of the timeout case
  below, and conflating the two would either leak a live agent or destroy one.
- **Do not trigger `launchMember`'s herdr retry** (`:851-881`). Re-running
  `agent start` against a pane that already holds a blocked agent is wrong.
- **Do not report it as a spawn failure to the caller**, and in particular do
  not let `add`'s spec-0039 spawn path (§1.5) treat it as one — `add` of a
  codex member on a fresh cwd will land here routinely and it is a success with
  an action outstanding.
- Report the remedy concretely: the member's name, that it is awaiting a
  startup prompt, and that `herdr agent read <name>` shows the prompt and
  `herdr agent send-keys <name> …` answers it.

**Spawn must not auto-dismiss these prompts.** See §6 — this is a refusal on
principle, not an omission.

**The pane is orphaned, and spawn must report it rather than close it.**
`layoutAndLaunch` (`:889-923`) creates panes before launching into them, so a
failed launch leaves a pane holding `agent_status: "unknown"` and no `agent`
key. Requirement: include the orphaned `transport_id` in the failure result,
with `herdr pane close <id>` named as the remedy.

Deliberately **not** auto-closing it: closing a pane is destructive and
irreversible, and that pane holds the target CLI's own output — which on a
timeout is usually the only explanation of what went wrong. Silently destroying
the evidence for a failure the user must diagnose is the wrong default, and
`disband`/`dismiss` already own pane teardown. The cost is that repeated failed
spawns accumulate panes; the reported id plus the documented remedy is the
accepted mitigation. Cheap to flip to auto-close if the user prefers tidiness
over diagnostics — say so in the docs rather than assuming either preference.

### 1.5 Route: the third lane

`route` today is `peer` (a live session reached by SendMessage) or `subagent`
(spawned in-process by the Agent tool). Per F4 neither can reach a non-Claude
process: the Agent tool spawns Claude subagents only, and SendMessage resolves
names the Claude CLI registered.

Add a third route value, **`pane`**: *the member is not SendMessage-addressable;
it is driven through its Herdr pane.*

Rules:
- `kind != claude` ⇒ `route` **must** be `pane`. `peer` and `subagent` are hard
  errors at add/edit for a non-claude kind.
- `kind == claude` ⇒ `peer`, `subagent`, and `pane` are all legal. `pane` for a
  Claude member is unusual but coherent (a Claude session you drive by typing
  into it) and forbidding it would be *more* code, not less. It is not a
  documented workflow; it simply is not prohibited.
- `route: pane` members are excluded from every SendMessage/ListAgents-derived
  path: the `members.filter(m => m.route === "peer")` pane-count in
  `createSpawn` (`:1071`) and `layoutPlan` (`:337`) must count `pane`-routed
  members too (they need a pane), but the route gate
  (`hooks/pretooluse-route-gate.mjs`) and any "is a peer available" answer must
  not offer them as SendMessage targets.
- **`add` must spawn a `pane` member, not defer it.** Spec 0039 made a
  successful `add` end in a usable peer, but its condition is
  `effectiveRoute !== "peer"` → "dispatched on demand, no session spawned"
  (`roster.mjs:1332-1336`). A `pane` member has no on-demand dispatch — nothing
  can conjure a Herdr agent at dispatch time the way the Agent tool conjures a
  subagent — so falling into that branch would leave it permanently
  unreachable. `pane` must take the same spawn path as `peer` here, subject to
  `--no-spawn` and to the §1.4 transport refusal.

The distinction `route` now encodes is *how the Orchestrator reaches this
member*: `peer` = SendMessage, `subagent` = the Agent tool, `pane` = Herdr
agent-control (§1.6). `transport` remains a separate axis — *how the process was
placed* — and is unchanged.

On the name `pane`: chosen over `herdr` because `route` and `transport` are
different axes and a config value that names a specific multiplexer will read
wrong if a second pane transport ever gains agent-control. This is one string
constant and cheap to change — see §5 F2.

### 1.6 Dispatch and liveness for a non-claude member (settled by the user)

**Transport is Herdr's agent-control surface** (F5), addressed by the member's
name.

- **Addressing.** Reuse the *existing* derived name — the same
  `peerName(repoBasename, role)` value that is already passed as the first
  positional to `herdr agent start` (`:307`). No new naming scheme, no new
  field. Herdr's uniqueness is "among live agents", which the roster's ordinal
  suffixes already satisfy. `transport_id` (pane id) is already recorded in
  `team.json` and Herdr accepts either — record both, address by name, keep the
  pane id for close/move as today.
- **Send work:** `herdr agent prompt <name> "<brief>" --wait --timeout <ms>`.
- **Wait for a state:** `herdr agent wait <name> [--until blocked] --timeout <ms>`.
- **Read output:** `herdr agent read <name> --source recent-unwrapped --lines <n>`.
- **Interactive dialogs:** `herdr agent send-keys <name> <key>`.
- **Liveness / presence:** `herdr agent get <name>`.
- **Teardown:** there is **no** `herdr agent stop`/`release`/`kill` (r4, N4).
  `disband`/`dismiss` for a non-claude member use the `herdr pane close <id>`
  path the codebase already has (`roster.mjs:950-959`) — verified working.
  A `herdr pane release-agent` primitive exists but is the agent-detector's own
  self-report mechanism, not a user-facing stop; it is **out of scope** here,
  noted so nobody rediscovers it and assumes otherwise.

**The message-file protocol survives as a content convention, but its
notification transport does not.** Per the Implementor trace, `[hierarchy-msg]`
files are a shared-filesystem channel orthogonal to addressing. A codex/pi
agent has no `agents/*.md` contract, no knowledge of this repo's conventions,
and no SendMessage. Therefore:

1. The orchestrator's prompt to a non-claude member must be **self-contained**.
   A bare `[hierarchy-msg <path>]` token means nothing to it. Either inline the
   brief, or state explicitly in the prompt: read this absolute path, and write
   your report to *this* absolute path in *this* shape.
2. **Report-back is by file, not by screen-scrape.** The prompt names an
   absolute response path the agent must write; the orchestrator then reads
   that file. `herdr agent read` is the fallback and diagnostic channel, not
   the primary one — a terminal scrape is lossy, wrap-dependent, and truncates.
3. The response file should be created the normal way (`msg.mjs new --type
   response`) *by the orchestrator, up front*, and its path handed to the agent
   to fill in — a non-claude agent cannot be relied on to know the naming
   convention or the frontmatter shape.

**Liveness must not go through `peers.jsonl` for these members.** F4 is
decisive: `memberIsLive()` (`hooks/roster.mjs:1001-1005`) reads records written
by the *spawned session's own* Claude SessionStart hook, which never runs. Left
alone, a non-claude member is permanently "not live", and `spawn-one`'s
already-live refusal (`:1177-1184`) never fires — so a second `spawn-one` would
try to start a second agent under a name Herdr requires to be unique. That is
the concrete failure this must prevent.

Requirement: liveness becomes kind-aware. For `kind: claude` it is unchanged
(`peers.jsonl`, exactly as today). For a non-claude kind it is derived from
`herdr agent get <name>`, whose shape is now known (r4, N3):

- Lifecycle state is at **`result.agent.agent_status`**. Observed values:
  `idle`, `working`, `done`, `unknown` (SKILL.md:54 also documents `blocked`).
- A non-claude agent's record carries **no `agent_session` key**; a claude one
  does. Do not branch on that — `agent_status` is present and identical in
  both, and reading only it keeps one code path.
- A missing target exits **1** and writes its error as **JSON on stdout, not
  stderr**: `{"error":{"code":"agent_not_found",…}}`. Code that inspects stderr
  on failure will find nothing — read stdout on the error path too.

| `herdr agent get` outcome | member is |
|---|---|
| `agent_status` ∈ {`idle`, `working`, `blocked`, `done`} | **live** |
| `agent_status: "unknown"` | **live** — SKILL.md:58 is explicit it "does not prove completion" |
| exit 1 with `error.code === "agent_not_found"` | **not live** |
| anything else — Herdr absent from PATH, daemon unreachable, non-zero exit with any other code, unparseable output | **indeterminate — NOT "not live"** |

`done` is live-not-finished: per SKILL.md:58 it is the idle state after unseen
background work, i.e. the agent is still sitting in its pane.

**Liveness is not readiness (r5, N6).** For a Claude peer the two collapse into
one question — the session is up, therefore it can take a SendMessage. For a
Herdr-driven agent they are genuinely different, and the spec needs both:

| predicate | question it answers | governs |
|---|---|---|
| **live** | is there already an agent under this name? | duplicate-spawn refusal, `disband`, `dismiss`, `reap` |
| **ready** | can this member be prompted *right now*? | dispatching work to it (§1.6's `agent prompt`) |

`blocked` is the state that separates them: an agent sitting on a startup
prompt is unambiguously **live** (spawning a second under the same name would
be wrong) and unambiguously **not ready**. The table above is the *liveness*
table and is correct as written — note it already counts `done` as live, so the
observed codex ready-state (`agent_status: "done"`) does not misread as dead.

**Readiness signal: `result.agent.interactive_ready === true`.** Observed on a
ready codex agent alongside `agent_status: "done"`. Use this field, with
`agent_status` as diagnostic/reporting only.

Do **not** build a per-kind ready-state mapping. "codex is ready at `done`,
claude at `idle`, …" is the §1.2 allowlist mistake in a new costume: 21 kinds
whose state vocabularies would each need tracking per Herdr version.
`interactive_ready` is Herdr's own normalized answer across kinds — that is
precisely what it is for.

One trap: `interactive_ready` was observed on the codex payload and was not
visible in the claude payload captured for N3. **Absent must not be read as
false** — a missing field means "this Herdr build does not report it", so fall
back to the `agent_status` set. Reading absent-as-false would mark every ready
Claude member unpromptable. (Same shape of bug as the stdout-not-stderr trap
above: an unset value silently meaning "no".)

**The indeterminate row is load-bearing and was wrong in r2/r3**, which said
"agent absent / command errors → not live". Conflating the two means a Herdr
outage reports every non-claude member dead, and the first thing a caller does
with "dead" is spawn a replacement — so a transient daemon problem becomes
duplicate agents under names Herdr requires to be unique. An indeterminate
result must **refuse the operation that depended on it**, naming Herdr as
unreachable, rather than proceeding on an assumption of death. `herdrOnPath()`
(already imported, `roster.mjs:82`) covers the absent-binary case cheaply.

**These paths simply do not fire for a non-claude member, and that is correct
— do not "fix" them:** `hooks/sessionstart.mjs`'s `up` record;
`hooks/posttooluse-roster.mjs`'s `ListAgents` scrape (`:60-70`) and
`SendMessage` sentinel (`:71-79`); `hooks/lib-peer.mjs`'s
`<cross-session-message>` envelope parsing and both arming forms (`:106`,
`:135-149`); `roster.mjs`'s `checkin` (`:2185-2239`), which requires a
pre-existing hook-written record and a `CLAUDE_PID` the member does not export.
Each is Claude-session machinery by construction. Say so where they are
documented rather than adding non-claude branches to them.

### 1.7 Name-length validation (pre-existing, now unavoidable)

Any member launched through Herdr — which now includes every non-claude member
by §1.4 — must have a name matching Herdr's `[a-z][a-z0-9_-]{0,31}` (F6).

**This is a herdr-transport constraint, not a universal one (r6).** r5 wrote it
as a single hard failure for every kind and claimed that "fixes both". That was
wrong, and the Reviewer was right to call it: a *claude* member whose derived
name Herdr would reject can still spawn perfectly well on the tmux or terminal
transport, and refusing it at add/edit would reject a configuration that works.
`tests/test-roster-spawn-cwd.sh` T4 — a spaced repo path producing a working
claude-derived name — is asserting exactly that, and it is correct to. Which
transport a member will spawn on is not known at add/edit time, so the rule
splits by what *is* known there, the kind:

| kind | at add/edit |
|---|---|
| non-claude | **hard error** — Herdr is mandatory (§1.4), so an unusable name means the member can never spawn at all |
| `claude` | **warning only** — names the limit and the derived value; the member may legitimately never touch Herdr |

A claude member with a Herdr-invalid name that *does* get spawned under Herdr
still fails, with Herdr's own error, exactly as it does today. That is
unchanged and acceptable; the warning is the improvement.

Correcting r5's other overstatement: this **partially mitigates** the
pre-existing latent defect (it warns where it previously said nothing), it does
not fix it for claude members. Fixing it fully would mean a transport-time
check, which is out of scope here.

**Where this check goes matters.** `validateMember`
(`hooks/lib-roster.mjs:102-124`) explicitly *rejects* a member carrying a
stored `name` — names are derived at resolve time, never persisted — so this
check cannot live there. It belongs where the name is derived
(`hooks/lib-config.mjs:379-387` `rosterMemberNames`/`peerName`) or in the
add/edit paths right after derivation, reported against the derived value.

The underlying gap is **pre-existing** and already affects claude-kind herdr
members with long repo basenames; it is in scope here only because non-claude
members cannot fall back to a non-Herdr transport, so for them the failure is
unconditional and must be caught early.

### 1.8 Roles are labels for a non-claude member

`--agent ah:<role>` (`:300`) is a Claude Code plugin-agent reference and is not
emitted for a non-claude kind. The member's `role` therefore remains meaningful
as an organizational label — it still picks the derived name, the roster slot,
and what the Orchestrator expects back — but the role's behavioural contract in
`agents/*.md` is **not loaded into the agent**. An Orchestrator dispatching to a
non-claude member is responsible for putting the relevant expectations into the
prompt itself. Document this; do not restrict which roles a non-claude kind may
take (a codex implementor is a reasonable thing to want).

Accepted consequence: the `ultra-advisor` top-tier-model guarantee
(`TOP_TIER_MODELS`, `lib-config.mjs:106`) does not apply to a non-claude
ultra-advisor, because there is no model field to check. The user selects the
kind deliberately; this is a disclosure, not a hole to plug.

### 1.9 Native-args passthrough (`args`) — settled: ship it

Because §1.3 removes `model`/`effort`/`auto-mode` for non-claude kinds, without
a passthrough such a member could only ever be started *bare* — no model
selection, no flags at all. The user settled this: ship it in v1.

**Shape.** Optional per-member `args`: an array of strings. Each element is one
argument. Empty array and absent are equivalent (treat as absent; do not write
an empty array).

**Placement.** Appended after Herdr's `--` in the `agent start` line, which
already exists in `spawnShape`'s herdr branch — for a non-claude member the
`--` slot is otherwise empty, since no `agentFlags` are emitted (§1.4).

**Validation.**
- Array of non-empty strings, or absent. Reject a bare string, a nested array,
  or a non-string element, naming the offending element.
- **No validation of content.** These are native arguments for a CLI this
  codebase does not model. An arg Herdr or the target agent rejects surfaces as
  a launch failure with that tool's own message (§1.4).
- **`args` is a hard error for `kind: claude`.** Not merely unnecessary —
  actively unsafe. For a Claude member the `--` slot already carries the
  validated `agentFlags`, so an `args` entry would be a *second, unvalidated*
  way to set Claude CLI flags: `args: ["--model", "haiku"]` on an
  `ultra-advisor` would defeat `TOP_TIER_MODELS` (`lib-config.mjs:106`), and
  `["--permission-mode", "bypassPermissions"]` would bypass the `auto-mode`
  value set and its headless-peer warning entirely. Every model/effort/
  permission rule in §3 is only as strong as this rejection. Reject at add/edit
  **and** defensively at spawn, since a hand-edited config file reaches
  `spawnShape` without passing through `add`.

**Shell quoting — mandatory, and the reason is specific.** The launch string is
executed by `runShell` = `execFile("/bin/sh", ["-c", commandString])`
(`roster.mjs:819-825`). `args` is the first member field whose value is
authored as free text and interpolated into that string, so an element
containing `;`, `` ` ``, `$(…)`, or a redirect would execute as shell syntax
rather than being passed as an argument — a config-file-to-shell-execution
path that does not exist today. **Each element must be shell-quoted when
composed into the launch command.** Precedent in the same function: the tmux
branch already wraps its command in `JSON.stringify` (`:320`) for the same
class of reason.

The quoted form must also be what `--dry-run` prints, so the preview is honest
about what will run.

**The passthrough works (r4, N2 — settled).** Herdr forwards `--` args to a
non-claude kind verbatim, with no parsing of its own. The field is effective,
not inert.

**No validation that `args` keeps the agent interactive — and none is
possible.** The live test showed a run-and-exit flag guarantees a startup
timeout (§1.4). It is tempting to pre-screen for that, but this codebase cannot:
it would have to know, for each of 21 CLIs, which flags exit and which stay
resident. Any blocklist (`--help`, `--version`, …) is a guess that is wrong for
some CLI and, worse, grants false confidence for every flag not on it. Herdr's
timeout is the real and only enforcement.

What is required instead is an honest failure message: when `agent start`
returns `code: "timeout"` **and** the member has a non-empty `args`, the
reported failure must name the args as the most likely cause and print them.
That is a diagnostic, not a check — it must not be phrased as though the args
were validated.

## 2. Files to change

- `hooks/lib-roster.mjs` — `ROSTER_ROUTE_VALUES` (`:59`) gains `pane`;
  `validateMember`/`validateTeamMember` (`:102-124`, `:132-156`) gain the
  `kind` field, its default, its shape check, the model/effort/auto-mode
  exclusion and the route rule (§1.3, §1.5), and `args`' shape check plus its
  rejection for `kind: claude` (§1.9). **Not** the name check — see §1.7.
- `hooks/lib-config.mjs` — name derivation (`:379-387`) gains the Herdr
  name-shape check (§1.7); `ROLE_DEFAULTS` application is made kind-aware at
  its call site (§1.3); `statusReport`'s member line (`:994`) shows `kind`, and
  its inert-reason tag (`:986-990`) handles `pane`.
- `hooks/roster.mjs` — `spawnShape` (`:299-332`) kind-aware launch (§1.4);
  `labelPane` (`:838`) kind in the pane label; `memberIsLive` (`:1001-1005`)
  kind-aware liveness (§1.6); `createSpawn`'s (`:1071`, `:1077`, `:1091`) and
  `layoutPlan`'s (`:337`) route filters must include `pane`; `add` (`:1279`)
  and `edit` (`:1352`) accept `--kind`, skip the role-default model for
  non-claude (§1.3), and `add`'s spec-0039 spawn branch (`:1332-1336`) treats
  `pane` like `peer` (§1.5); `show`/`history` surface `kind`.
  `spawnShape` also composes and **shell-quotes** `args` into the herdr launch
  line, and re-rejects `args` on a `kind: claude` member reaching it from a
  hand-edited config (§1.9).
  `--kind` takes a value, so it must **not** be added to `BOOL_FLAGS` (`:84`);
  it does need adding to `SPAWN_ONE_FLAGS` (`:89`) only if `spawn-one` is ever
  to override it, which this spec does not require.
- `hooks/pretooluse-route-gate.mjs` — must not offer a `pane`-routed member as
  a SendMessage target.
- `mcp/server.mjs` — `roster_member`/`roster_config` (and whatever else takes
  per-member keys) accept `kind`; `roster_spawn_one`'s reported
  `launch_status`/`launch_result` carry the §1.4 refusal.
- `skills/agent-roster/SKILL.md` — member-field enumerations at `:330-332` and
  `:427-431`; the wizard/add flow must ask for or default the kind; a section
  on dispatching a non-claude member per §1.6.
- `docs/getting-started.md:34-40`, `docs/mcp-tools.md:98,:114` — field lists.
- `agents/orchestrator.md` (and any role doc that describes dispatching to
  peers) — the §1.6 lane: how to reach a non-claude member, and that
  SendMessage will not.
- New: `tests/test-roster-agent-kind.sh` (§4).
- Release chore: bump `agent-hierarchy/.claude-plugin/plugin.json` **and** root
  `marketplace.json` together.

## 3. Must not change

- Every per-role model rule for `kind: claude` (`VALID_MODELS_BY_ROLE`,
  `lib-config.mjs:107-113`), including `ultra-advisor`'s top-tier restriction
  and `task-runner`'s extra `haiku`. This spec adds a dimension; it relaxes
  nothing.
- The launch string produced for any `claude`-kind member, on any transport —
  byte-identical (§4.1).
- The SendMessage/ListAgents/`peers.jsonl` path for `route: peer` claude
  members, with or without Herdr.
- `spawnShape` remains the single launch-shape function. Do not fork a
  non-claude variant; `spawn-one`, `create --spawn` and history replay must
  keep sharing it (F1).
- `herdrCall()` (`:408-422`) remains the sole exec site for the `herdr` binary
  (spec 0002 §11.3's grep assertion). Any new Herdr call in §1.6 goes through
  it.
- Existing roster config files are not rewritten by a read (§1.1).
- `tests/test-roster-spawn-cwd.sh` T4 (r6): a spaced repo path's claude-derived
  name keeps working. §1.7's name rule must not turn that into a failure.
- The defensive re-resolution of `kind` at its seven call sites (§1.1) — not to
  be consolidated away as redundancy.

## 4. Verification

New `tests/test-roster-agent-kind.sh`, following the existing
`tests/test-roster-*.sh` pattern and the fake-`herdr` stub approach already
used by `tests/test-herdr-presence.sh` and `tests/test-herdr-pane-label.sh`.

### 4.1 Backcompat (the load-bearing test)
- A roster config with **no** `kind` key on any member: every member resolves
  to kind `claude`, and `spawn-one --dry-run` emits a launch string
  **byte-identical** to the pre-change output, for all three transports.
  Capture the current output before the change and assert equality after.
- A config with an explicit `kind: "claude"` produces the same result.
- Reading a roster does not rewrite the file (no `kind` key appears).

### 4.2 Validation
- `add --kind codex` with `--model sonnet` → rejected, message names `model`.
  Same for `--effort` and `--auto-mode`.
- `add --role implementor --kind codex` with **no** `--model` → **accepted**,
  and the stored member has no `model`. This is the §1.3 role-default trap; it
  is the test that catches "non-claude members cannot be created at all".
- `add --role implementor --kind claude` with no `--model` → still gets
  `ROLE_DEFAULTS.implementor.model` (`inherit`), unchanged.
- `add --kind codex --route pane --on-missing auto` → accepted (§1.3).
- `args` (§1.9): accepted on a non-claude member as an array of non-empty
  strings; rejected as a bare string, a nested array, or with a non-string /
  empty element, message naming the element.
- **`args` on a `kind: claude` member → rejected at add/edit**, and rejected
  again at spawn when injected directly into a config file (both paths tested
  — the second is the one a hand-edited roster takes).
- `args: ["--model","haiku"]` on a `kind: claude` ultra-advisor is rejected —
  assert the tier rule cannot be defeated this way.
- `add --kind codex --route peer` → rejected. `--route subagent` → rejected.
  `--route pane` → accepted.
- `add --kind claude --model sonnet` and every existing per-role model case →
  behaviour unchanged (regression pass over the current model-validation tests).
- `add --kind "Codex"` / `--kind ""` / `--kind "co dex"` → rejected on shape.
- `add --kind some-kind-nobody-has` → **accepted** (no allowlist, §1.2).
- A derived name over 32 chars, or outside `[a-z][a-z0-9_-]*` (§1.7, r6):
  **non-claude** → hard error naming the limit and the derived value;
  **claude** → warning only, the add/edit still succeeds. Assert both, and that
  `tests/test-roster-spawn-cwd.sh` T4 still passes unmodified.

### 4.3 Spawn
- `spawn-one --dry-run` for a `kind: codex` member under a fake herdr
  transport. The shape is `herdr agent start <name> --kind codex --pane
  <TARGET>` for a member with no `args`, and `… --pane <TARGET> -- <quoted
  args…>` for one with them (r7: the `--` separator §1.9 requires was missing
  from this line in r5/r6 — a spec text error, now fixed).

  **Assert substantively, not by exact string equality** (r7, answering the
  Implementor's gap [3.7]). Required assertions: the `--kind` flag carries the
  member's kind; the claude-only flags (`--agent`, `--name`, `--model`,
  `--effort`, `--permission-mode`) are **absent**; no `--timeout` appears; and
  the native args appear after a `--` separator.

  Rationale, since this deliberately differs from §4.1: §4.3's string contains
  shell-quoted `args`, so an exact literal would encode one particular quoting
  *style*. An equally-correct change to the quoting helper would then fail the
  test with no behaviour change, and — worse — the literal can keep passing
  while the quoting is wrong-but-consistent. The property actually worth
  guarding is behavioural and §4.5 already guards it by execution: the args
  arrive as N distinct arguments and shell metacharacters do not execute. That
  is strictly stronger than string equality, so substantive assertion is the
  better test here, not a concession.

  §4.1 keeps exact byte-equality, and that asymmetry is intentional: there the
  string is fully determined (claude members cannot carry `args` at all, §1.9),
  and byte-identity *is* the backcompat claim rather than a proxy for it.
- Same member with `HERDR_ENV` unset and tmux available: member is refused,
  nothing is shelled for it, `launch_status: failed`, `launch_result` names the
  kind and the detected transport.
- `create --spawn` with a mixed roster (claude peers + one codex member) under
  a non-herdr transport: claude members launch, the codex member is refused,
  result reports `partial`.
- `add --kind codex --route pane` under a fake herdr transport **spawns** the
  member (does not report "dispatched on demand") — §1.5's `add` rule.
- `add --kind codex --route pane --no-spawn` writes config and spawns nothing.
- Fake herdr stub exiting non-zero on an unknown kind: its stderr appears
  verbatim in `launch_result`.
- Pane label for a codex member carries `codex`, not `claude`.

### 4.4 Liveness
- Fake `herdr agent get` returning each of `idle`/`working`/`blocked`/`done`/
  `unknown` at `result.agent.agent_status` → member reports live.
- Exit 1 with `{"error":{"code":"agent_not_found"}}` **on stdout** → not live.
  (Assert the stdout path specifically — a reader that only checks stderr sees
  an empty string and must not silently fall through to "live".)
- **Herdr unreachable** — binary absent, or non-zero exit with any other error
  code, or unparseable output → **indeterminate**: the caller refuses and says
  Herdr is unreachable. Assert specifically that it does **not** report
  not-live, and that `spawn-one` does **not** proceed to launch a replacement.
  This is the duplicate-spawn regression the §1.6 correction exists to prevent.
- A non-claude `agent get` payload with no `agent_session` key parses fine
  (do not require that key).
- **Readiness vs liveness (§1.6, r5):** a payload with
  `agent_status: "done", interactive_ready: true` → **live and ready**.
  `agent_status: "blocked", launch_pending: true` → **live but NOT ready**;
  assert `spawn-one` refuses as already-live rather than starting a second
  agent, and that dispatch does not treat it as promptable.
- A payload with **no** `interactive_ready` key → readiness falls back to the
  `agent_status` set; assert a claude member at `idle` reads ready. (Absent must
  not read as false — otherwise every ready Claude member becomes unpromptable.)

### 4.6 Blocked-at-startup (§1.4, r5)
- Fake herdr stub returning exit 1 with
  `{"error":{"code":"agent_not_ready"}}`: the launch outcome is the distinct
  blocked value, **not** `failed`; the pane is not closed; `launchMember`'s
  herdr retry does **not** fire; the message names `agent read`/`send-keys` as
  the remedy.
- `add --kind codex --route pane` hitting that stub reports success-with-action
  -outstanding, not a failed add (§1.5).
- Assert no code path sends keystrokes to a blocked agent on its own (§6's
  refusal) — nothing in spawn may call `send-keys`.
- A `kind: codex` member with **no** `peers.jsonl` record and a live
  `herdr agent get` → `spawn-one` refuses as already-live (this is the failure
  §1.6 exists to prevent; assert it directly).
- A `kind: claude` member's liveness still comes from `peers.jsonl` and is
  unaffected by `herdr agent get`.

### 4.5 Passthrough quoting (§1.9)
- A `kind: codex` member with `args: ["--flag","value"]` under a fake herdr
  stub: the stub receives exactly two arguments after `--`, with those values.
- **Injection:** `args: ["; touch /tmp/ah-pwned"]` — assert the file is NOT
  created and the element arrives as a single literal argument. Repeat for an
  element containing `$(…)` and one containing a backtick. This is the test
  that proves §1.9's quoting requirement was actually implemented rather than
  the array simply being joined with spaces.
- `--dry-run` prints the quoted form, matching what is executed.
- **No `--timeout` appears in any launch string** (r6), for any kind or
  transport — assert its absence, since its presence is what broke §4.1's
  byte-identity claim.
- Fake herdr stub returning `{"error":{"code":"timeout"}}` for a member that
  has `args`: the failure message names the args as the likely cause and prints
  them, and reports the orphaned `transport_id` with `herdr pane close` as the
  remedy. The same stub for a member with **no** `args` does not blame args.
- The failed spawn does **not** close the pane (§1.4) — assert no close call.

## 5. NEEDS-EVIDENCE (for the Orchestrator to route)

**N1–N5 are SETTLED (r4)** by a live Herdr test — findings folded into §1.2
(kind list), §1.4 (timeout, orphaned pane), §1.6 (liveness shape, teardown) and
§1.9 (passthrough works). Nothing below blocks implementation. One new item,
N6, blocks *acceptance*.

**N6 — RESOLVED POSITIVE (r5).** A codex agent reaches a genuine interactive
state under Herdr: `agent_status: "done"`, `interactive_ready: true`, live TUI
accepting input. The premise under §1.4/§1.6 holds and this spec's approach is
sound. Getting there passed through the trust prompt (§1.4) — which is itself
the finding, not an obstacle to it.

Residual, non-blocking: readiness has been observed on exactly one non-claude
kind (codex). The `interactive_ready` fallback in §1.6 is written so that a
kind or Herdr build not reporting the field degrades to `agent_status` rather
than misreading as unready, so a second kind behaving differently is a
documentation matter, not a redesign. Worth spot-checking `pi` whenever
convenient; nothing waits on it.

### Settled (kept for the record)

- **N1 — the live kind list.** Run `herdr agent` (help) and report the
  installed `--kind` values. Decides: which kinds the docs and SKILL.md name as
  examples, and confirms the exact spelling of `pi`. Does **not** decide
  validation — §1.2 is shape-only by design either way.
- **N2 — non-claude native args.** Does `herdr agent start --kind <non-claude>`
  accept the `-- <agent-args…>` passthrough, and does `agent start`'s readiness
  detection (SKILL.md: "returns only after Herdr detects the expected agent …
  and considers it ready") actually settle for a non-claude kind, or can it
  hang? If it can hang, §1.4 needs a timeout story. Also decides whether §1.9's
  `args` is effective or merely inert (the field ships either way — r3).
- **N3 — `herdr agent get` output shape (BLOCKING for §1.6).** Start any agent
  and run `herdr agent get <name>`; report the exact JSON and the path to the
  lifecycle state, and what the command does when the name does not exist (exit
  code + output). §1.6's liveness table cannot be implemented without this.
- **N4 — is there a stop/release?** SKILL.md documents no `agent stop`/`kill`.
  Run `herdr agent` and report what teardown verbs exist. Decides what
  `disband`/`dismiss` do for a non-claude member. Expected fallback is the
  `herdr pane close` path already used at `:950-959`, which likely suffices —
  confirm rather than assume.
- **N5 — confirm the premise.** Start a non-claude agent via Herdr and check it
  does **not** appear in a Claude session's `ListAgents`. High confidence from
  F4, but it is the premise §1.5 and §1.6 rest on and it is cheap to verify.

## 6. Decisions made / refused

**Made:**
- `kind` as a per-member string defaulting to `claude`, normalized once on read
  (§1.1) — the only shape that makes the user's default requirement total
  without touching every consumer.
- No allowlist of kinds (§1.2) — Herdr owns that list, it is install-dependent,
  and Herdr's own docs say to discover it at runtime.
- `model`/`effort`/`auto-mode` are claude-only and rejected, not ignored, for
  other kinds (§1.3) — they are literally Claude CLI flags (F3).
- Non-claude ⇒ herdr transport required (§1.4) — forced by F2, not a preference.
- Third route value `pane` (§1.5) — the alternative (nullable `route`) is the
  same change spelled worse.
- Report-back by file, not by `herdr agent read` scrape (§1.6).
- Liveness for non-claude members via `herdr agent get`, not `peers.jsonl`
  (§1.6) — without this, re-spawn protection silently disappears.
- Name-length validation pulled in (§1.7) despite being pre-existing, because
  non-claude members have no non-Herdr fallback.

**Settled by the user (r3, brief `20260907-205844-1396`) — were open forks in r2:**
- **F1 — native-args passthrough: YES.** Specified in §1.9. Two things the r2
  sketch did not say, both added when it became real: `args` must be rejected
  for `kind: claude` (otherwise it is an unvalidated second channel for
  `--model`/`--permission-mode` and the `ultra-advisor` tier rule stops being
  enforceable), and each element must be shell-quoted because the launch string
  goes through `/bin/sh -c`.
- **F2 — route value name: `pane`.** Confirmed; the spec already used it
  throughout, so no text changed.

**Refused on principle (r5) — auto-dismissing first-run prompts.** The
Orchestrator asked whether `spawn-one` should auto-answer known onboarding
prompts per kind. No, for two independent reasons, either of which alone is
sufficient:

1. **It answers a security question on the user's behalf.** The concrete prompt
   is *"Do you trust the contents of this directory?"* — a deliberate gate
   asking a human to vouch for code the agent is about to act on. Roster
   automation silently replying "yes, continue" does not satisfy that gate; it
   removes it, for every future spawn, invisibly. Whether to trust a directory
   is the user's decision and must stay theirs.
2. **It does not scale and cannot be kept correct.** Per-kind prompt matching
   across 21 kinds, each free to reword its onboarding at any release, is a
   pattern-matching treadmill whose failure mode is sending keystrokes to a
   prompt that is no longer the one matched — i.e. answering an *unknown*
   question affirmatively.

The N2-consistent answer applies instead: detect the state, report it
precisely, and let the caller resolve it deliberately (§1.4). An Orchestrator
that wants to unblock a member does so with an explicit `send-keys`, which is a
visible act with a person behind it.

**Corrected in r6 after review against the real diff — all three were my
errors, not the Implementor's:**
- **`--timeout` deleted.** r4 justified it with "an unknown default governs";
  the default is documented (30000) and was exactly what got passed. The flag
  bought no behaviour and cost an invariant. Deleting it is the smaller and
  more correct spec. Requires a code change to land.
- **§1.7 split by kind.** The constraint belongs to the herdr transport, not to
  every member; r5's single hard failure would have rejected working claude
  configurations and broken an existing test that is right to assert them.
- **§1.1's "single application point" corrected to single *definition*.** The
  original sentence would have led a later reader to delete seven correct
  defensive calls and silently reopen the absent-kind bug. Worth noting the
  general shape: a spec sentence that describes an *invariant* ("the default
  lives in one place") is safe, while one that describes a *count of call
  sites* ages badly the moment the code is real.

**Still refused / left open:**
- Whether a non-claude member may hold reasoning roles at all (§1.8): left
  open, i.e. permitted. Restricting it is easy to add later and impossible to
  justify now.

## 7. Confidence

**High** on §1.1–§1.5: the seam is a single 33-line function, the constraint
that forces herdr-only is structural rather than stylistic, and backcompat is
provable by string equality.

**High** on §1.6's mechanics as of r4 — the `herdr agent get` shape, the
`agent_not_found` signal and teardown are all now measured rather than assumed.
The liveness rewrite remains the largest behavioural change here and the most
likely place to regress claude-kind teams, which is what §4.4 guards.

**The premise is now verified (r5, N6)** — the assumption everything in
§1.4/§1.6 rested on has been observed true, so the spec no longer carries an
unvalidated foundation.

What remains is ordinary implementation risk, concentrated in one place: three
separate findings in this spec have now been variations of the same bug —
reading an unset or unexpected value as a definite negative. `agent_not_found`
vs Herdr-unreachable (r4), absent `interactive_ready` vs `false` (r5), and
error-JSON on stdout vs stderr (r4). Each would produce a confident wrong
answer about whether an agent exists or can be prompted, and each ends in
either a duplicate agent or a stranded one. §4.4 and §4.5 test all three
explicitly; a Reviewer should weight them accordingly.

**Escalation not recommended**, with one thing worth a second pair of eyes at
review rather than design time: §1.9's `args` is the first roster field whose
free-text value reaches `/bin/sh -c`, so the quoting requirement and the
`kind: claude` rejection are the two places where getting it wrong is a real
hole rather than a bug. §4.5 and §4.2 test both directly; the Reviewer should
treat those as must-pass rather than nice-to-have. Nothing else here is
security-, auth-, or data-migration-shaped. The other thing to watch is scope: §1.6's liveness
change touches a path every disband/dismiss/resync decision reads, so if it is
implemented carelessly it can regress claude-kind teams. §4.4's last case
exists to catch exactly that.
