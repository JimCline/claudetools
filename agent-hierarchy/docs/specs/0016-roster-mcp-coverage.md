# 0016 — Roster MCP coverage

Status: **final.** Amended with Implementor evidence and user decisions (2026-08-26);
all NEEDS-EVIDENCE items resolved. Ready for implementation, no open questions.
Composes with: 0013 (MCP server), 0009 (allow-global confirm gate), 0011 (multi-roster), 0008 (resync/move), 0003/0005 (create/spawn sequencing).
Touches the same files as 0015 — see §9.

## 1. Goal

`mcp/server.mjs` registers 6 tools (msg_new/msg_list/msg_index/msg_roster at 40–98,
roster_show at 100, roster_teams at 113). Every other `roster.mjs` verb — `init`,
`add`, `edit`, `remove`, `layout`, `alias`, `create`, `layout-splits`,
`next-split`, `disband`, `resync`, `move`, `spawn-one` — plus disband's close
execution, is reachable only by shelling out.

**Hard requirement (user, 2026-08-26): the model must never need Bash for any of
this.** That is the acceptance criterion, and it supersedes the token-saving
framing this spec started from. Bash remains available as a fallback when the `ah`
server is not connected; it must never be *required* when it is.

## 2. Cost, for the record

The scope question this section originally posed is closed (§4.3), but the numbers
are worth knowing, so the analysis stays.

**Wrapping saves nothing on JSON parsing.** `mapExecResult` (server.mjs:132–144)
returns the CLI's stdout as text verbatim; the model reads the same bytes either
way. The saving is the Bash command string, the shell-invocation preamble, and the
repeated permission round-trips across a multi-step sequence (§ Create alone is up
to 5 invocations plus a manual-mode loop of 2 per pane).

**The cost** is that every registered tool's name, description, and inputSchema sit
in the context of *every* session connected to the `ah` server, every turn, whether
or not it ever touches a roster. Thirteen new tools is a permanent per-session tax
paid by all sessions.

The user has accepted that tax as the price of eliminating the Bash fallback.
Measuring it (NEEDS-EVIDENCE 1, non-blocking) is worth doing so the number is
known, not so anyone re-opens the question.

Keep tool `description` strings to one line. That is the only remaining lever on
the tax, and it is free.

## 3. What stays orchestrator-side

An MCP tool is a child process. It cannot call `ListAgents` and cannot call
`AskUserQuestion`. Everything below stays with the session no matter what is
wrapped. This is a capability boundary, not a preference.

From § Create (SKILL.md:160–391):

- **Step 0, layout confirmation** (SKILL.md:171–173) — AskUserQuestion, "always
  ask, every `create`".
- **Step 1, first-create naming confirmation** (SKILL.md:192–199, 0011
  §5.3.1–§5.3.3) — AskUserQuestion before `create --plan`. SKILL.md already states
  `roster.mjs create` "never prompts, refuses, or reads stdin for this".
- **Step 1, second-Team collision** (SKILL.md:212–224) — the CLI refuses and hands
  back a candidate; the skill must ask before retrying with `--team`.
- **Step 2 / manual mode** — per-member placement override.
- **Step 4, check-in** (SKILL.md:335–340) — `ListAgents`, poll every 2s, give up at
  60s. The most orchestrator-bound step in the sequence: no tool can produce the
  `ref` values step 5's `--verified` array requires.
- **§ Create manual-mode layout loop** — show geometry, offer
  accept/change-direction/change-target/skip, per iteration.

From § disband (SKILL.md:392–436):

- **Step 2, showing the member/close list and getting an explicit yes.** The
  *asking* stays with the session — a tool cannot ask. What changed is where the
  answer is enforced; see §4.5.
- **The plan → confirm → close → commit ordering.** Four distinct steps, and no
  tool may fold them. `disband --commit` must never run before the closes.

### 3.1 Reversal on record: disband's close execution

The previous revision refused to wrap disband's close commands, arguing they are
the one destructive step the user's Bash permission gate still sees, and that
moving them behind a tool relocates a destructive action out from under a user
decision.

The user decided otherwise. Recorded here so the tradeoff is not lost:

- Today's gate is **enforced by the harness against the user**: a Bash permission
  dialog the model cannot satisfy on its own.
- A required `confirm: true` tool parameter is **attested by the model**. Nothing
  in the parameter itself checks that a human was asked.

The user's counter-argument — that the requirement is *a* gate, not specifically
Bash's — is correct, and **NEEDS-EVIDENCE 4 has since confirmed the substitute gate
is real** (§4.5, §11.4). With the default `ask` rule of §4.5.1 in place, the
harness prompts the user interactively for `roster_disband_close` exactly as it
does for Bash, and the model cannot satisfy that prompt on its own. The gap this
section originally flagged is closed by default, not merely mitigated — provided
§4.5.1 ships. If §4.5.1 is dropped or disabled, the weakened-gate reading above
applies again in full.

## 4. Tools

### 4.1 The set

Naming: `roster_<verb>`, hyphens → underscores. All take required `cwd` (reusing
`cwdSchema`, server.mjs:34–37).

| Tool | CLI verb | Notes |
|---|---|---|
| `roster_init` | `init` | `--level`, `--route`, `--layout` |
| `roster_add` | `add` | `--level --role --model --effort --auto-mode` |
| `roster_edit` | `edit` | same fields as add |
| `roster_remove` | `remove` | `--level --role` |
| `roster_layout` | `layout` | `--layout <mode>` |
| `roster_alias` | `alias` | `--level`, `--set`; no args = read-only report |
| `roster_create` | `create` | `mode` enum, §4.2 |
| `roster_layout_splits` | `layout-splits` | `--mode --pane-count`, `--next`, `--apply --target --direction`, `--created`; expects exit 3, §5 |
| `roster_disband` | `disband` | `mode: plan\|commit\|keep-sessions`. **Non-destructive modes only** — never closes anything |
| `roster_disband_close` | `disband --close` | **Destructive.** §4.5. Separate tool by design; gated by default per §4.5.1 |
| `roster_resync` | `resync` | `--dry-run`, `--team` |
| `roster_move` | `move` | Blocked on §4.4. `name` + one of `--tab --split` / `--new-tab [--workspace]` / `--new-workspace`, `--dry-run`, `--allow-global` |
| `roster_spawn_one` | `spawn-one` | `role`, `--dry-run`, `--allow-global` |

Thirteen new tools; nineteen registered in total.

**Excluded: `next-split`.** SKILL.md:67–68 states verbatim that it is "exposed for
testing. The skill does not call it; `layout-splits` does." Not reachable from the
skill, so excluding it cannot force a Bash fallback. Tests keep calling the CLI.

Every tool that 0011 scopes takes an optional `team` (a shared `teamSchema`
fragment — currently duplicated inline at server.mjs:56, 70, 94, 107; factor it out
and reuse). `roster_alias` keeps 0011 §7.4's refusal when a team scope is active —
that lives in `roster.mjs`, so wrapping inherits it for free.

### 4.2 `roster_create` shape

One tool, not three. The CLI has one verb with three mutually-exclusive modes and
disjoint parameters.

```js
{
  name: "roster_create",
  description: "Plan, spawn, or commit a Team via roster.mjs create.",
  inputSchema: {
    type: "object",
    properties: {
      cwd: cwdSchema,
      mode: { type: "string", enum: ["plan", "spawn", "commit"] },
      team: teamSchema,
      roster_level: { type: "string" },
      layout_mode: { type: "string" },        // spawn
      transport: { type: "string" },          // commit
      verified: { type: "string", description: "JSON array, passed to --verified verbatim" },
      partial: { type: "boolean" },           // commit
      orchestrator_pid: { type: "integer" },  // commit — read only on the commit branch, roster.mjs:956
    },
    required: ["cwd", "mode"],
  },
}
```

`callTool` validates mode/parameter coherence before building argv — `mode:
"commit"` without `verified` fails naming the missing field. `verified` stays a
JSON *string*, passed through byte-identically; do not re-serialize it.

**`orchestrator_pid` is commit-only.** An earlier revision of this spec marked it
`// spawn`; that was wrong — roster.mjs:956 reads it on the commit branch only.
Note that SKILL.md:237–238 shows `[--orchestrator-pid <pid>]` on the `create
--spawn` command line while SKILL.md step 5 describes it as a commit-step override.
If `--spawn` genuinely ignores the flag, that SKILL.md line is misleading and
should be corrected while §7's edits are being made — **verify against the CLI and
report; do not silently change behaviour to match either document.**

`roster_disband` follows the same one-tool/`mode`-enum pattern for its three
**non-destructive** modes.

### 4.3 Scope: resolved

All thirteen ship. The six-tool subset fallback is withdrawn — a subset would leave
verbs reachable only by Bash, which §1's hard requirement forbids.

### 4.4 Prerequisite: `move` needs an allow-global guard

Evidence: `requireAllowGlobal` is defined at roster.mjs:567 and called at exactly
two sites — 624 (`create --spawn`) and 1135 (`spawn-one`). `move` — which relocates
a live agent pane between tabs and workspaces — is unguarded on every path.

User's decision: **add a `requireAllowGlobal` call to the `move` case in
`roster.mjs` itself.** CLI-side, so the Bash path gains the same protection, which
is where the gap actually lives today.

Ordering is a hard requirement:

1. Add the guard to `move`, matching sites 624/1135 exactly — same helper, same
   argument shape, same failure-message style. Do not invent a variant.
2. Only then register `roster_move`.

**Do not implement `roster_move` before step 1 lands.**

This is a CLI behaviour change and may break callers or tests that run `move`
without `--allow-global`. Enumerate them and report before changing them, rather
than sprinkling `--allow-global` through the test suite to get green. Whether a
test legitimately needs an unguarded move is an Orchestrator question.

### 4.5 `disband --close` — the destructive step

#### Where the execution lives

**In `roster.mjs`, not in `mcp/server.mjs`.** Evidence makes this straightforward
rather than novel:

- `roster.mjs` already imports `execFile`/`execFileSync` (line 59) and already runs
  child processes in `layout-splits`, `move` (1099), `create --spawn` (628),
  `spawn-one`, and `resync` — via `herdrCall()` (276–290, `execFileSync("herdr",
  args)`), `runShell()` (459–465, `/bin/sh -c`), and direct `execFileSync("tmux",
  …)` (541).
- `disband` **already execs today**: bare/plan mode calls `resyncMembers` →
  `queryHerdrTopology` → `herdrCall(["agent","list"])` for the herdr transport
  (995 → 328 → 299). The claim that disband "only computes the plan and never runs
  anything" is false.

So this is the same pattern `move` uses, applied to the close step. Keeping it in
the CLI preserves §6's invariant that `server.mjs` is a pure argv wrapper, keeps one
implementation of the behaviour, and gives the Bash path the same capability.

#### Build argv; do not execute the plan's shell string

The plan's `command` field is a **shell string**, built at roster.mjs:1005–1014:

```javascript
let command = null;
if (m.route === "peer" && m.transport_id) {
  if (team.transport === "herdr") command = `herdr pane close ${m.transport_id}`;
  else if (team.transport === "tmux") command = `tmux kill-pane -t ${m.transport_id}`;
}
```

`--close` must **not** feed that string to `runShell`. It has the transport and the
`transport_id` already, so it builds argv directly — `herdrCall(["pane", "close",
id])` for herdr, `execFileSync("tmux", ["kill-pane", "-t", id])` for tmux —
avoiding `/bin/sh` and every quoting/injection question a `transport_id` could
raise. The `command` string stays in the plan output unchanged, for display and for
the Bash fallback path.

#### Contract

```
roster.mjs disband --close --confirm --plan-token <tok> [--team <T>] [--cwd <path>]
```

- `--confirm` is required and must be present. Absent → **exit 2**, echoing the
  full close list (member names + transport_ids) in the error payload. A hard
  refusal, never a silent no-op or a dry-run.
- `--plan-token <tok>` is required. Plan mode gains a `close_token` in its output:
  a short hash over `team_id` + the sorted list of non-null `transport_id`s in the
  close set. `--close` recomputes it from the current `team.json` (after the same
  in-memory resync plan mode does) and refuses on mismatch, telling the caller to
  re-run the plan.

  This makes the close impossible without first running the plan that produces the
  member list, and catches a topology change between plan and close — narrowing the
  residual window SKILL.md § disband step 1 documents as uncloseable.
- `requireAllowGlobal` applies, matching sites 624/1135. `--close` is new, so
  guarding it from birth breaks nothing.
- Returns per-member `{name, transport_id, closed: bool, error}`. A failed close is
  **reported, not fatal** — unchanged from SKILL.md step 3's existing rule.
- `--close` does **not** remove `team.json`. `disband --commit` remains a separate
  call, per §3.

#### Tool

```js
{
  name: "roster_disband_close",
  description: "Close the live sessions of a Team. Destructive; requires prior user confirmation.",
  inputSchema: {
    type: "object",
    properties: {
      cwd: cwdSchema,
      team: teamSchema,
      confirm: { type: "boolean", description: "Must be true, and only after the user has been shown the close list and agreed." },
      plan_token: { type: "string", description: "close_token from the preceding roster_disband mode:plan call." },
      allow_global: { type: "boolean" },
    },
    required: ["cwd", "confirm", "plan_token"],
  },
}
```

`confirm !== true` → refuse in `callTool` *before* invoking the CLI, echoing back
that a plan call and user confirmation are required. The CLI-side `--confirm` check
is the backstop for the Bash path; both exist.

#### Why a separate tool, not `mode: "close"`

A distinct tool name is what makes this step independently permission-gateable
(§4.5.1 depends on it entirely), independently visible in an audit trail, and
impossible to reach by accident from a `roster_disband` call meant to be read-only.
Burying the one destructive operation as an enum value inside an otherwise-harmless
tool would make §4.5.1's rule un-writable without also gating the harmless modes.

### 4.5.1 Ship the gate by default — the plugin registers its own `ask` rule

Confirmed by NEEDS-EVIDENCE 4: permission rules and PreToolUse `matcher`s both
support exact MCP tool-name matching (`mcp__ah__roster_disband_close`) and
wildcards (`mcp__ah__*`), and a matching `ask` rule produces a genuine interactive
user approval prompt that the calling model cannot satisfy on its own.

**The `ah` plugin ships this gate itself rather than documenting a snippet and
hoping.** A gate each user has to configure is a gate most users will not have.

Mechanism: a **PreToolUse hook entry in the plugin's own hooks manifest**, matcher
`mcp__ah__roster_disband_close`, returning `permissionDecision: "ask"`. A plugin
can ship hooks; it must not write into the user's `settings.json`, so the hook is
the correct vehicle and a settings snippet is only the documented alternative for
users who want to *tighten* it (e.g. to `deny`, or to scope by directory).

Requirements on the hook:

- **Match only `mcp__ah__roster_disband_close`.** Do **not** use `mcp__ah__*`.
  Prompting on every roster tool trains users to blanket-allow the whole server,
  which destroys the one gate that matters. This is the single most important line
  in this section.
- **Ask every time.** No caching, no "don't ask again" path, no allowlisting after
  a first approval. Closing live sessions is exactly the operation that should
  re-prompt.
- **Name the members in the prompt.** The hook receives `tool_input` (cwd, team,
  plan_token, confirm) but not the close list. It should call `readTeam(dir, team)`
  and include the member names in the ask message, so the user is approving
  something legible rather than an opaque tool name. If that read fails for any
  reason, **still ask**, with a generic message. Never skip the prompt because the
  enrichment failed.
- **Keep it trivial.** No herdr calls, no network, no topology queries — just
  `readTeam` and a formatted string. A hook that errors may not block, so the only
  robust defence is a hook with nothing in it that can throw.

Defence in depth — the ask rule is one of four independent layers, and the spec
does not rely on any single one:

1. the harness `ask` prompt (user-enforced; this section),
2. `confirm: true` checked in `callTool` (model-attested),
3. `--confirm` + `--plan-token` checked in the CLI (backstops the Bash path and
   forces plan-then-close ordering),
4. `requireAllowGlobal`.

Opting out is the ordinary hook-configuration path; do **not** build a bespoke
toggle, config key, or `/hierarchy` switch for it. YAGNI until someone asks.

## 5. Server changes

Additive and mechanical, with two exceptions.

- **`pushFlag(args, flag, value)`** — new helper beside `pushArg` (server.mjs:168).
  `pushArg` only emits `--flag value`; the new verbs need bare booleans
  (`--dry-run`, `--next`, `--partial`, `--allow-global`, `--keep-sessions`,
  `--close`, `--confirm`).
- **`mapExecResult` must surface expected non-zero exits as usable results, with
  their partial semantics intact.** Evidence confirms the 0/2/else model is complete
  for all wrapped verbs *except* `layout-splits`'s exit 3, and that the current
  else-branch (server.mjs:141–144) absorbs exit 3 into a generic
  `spawn/exit failure … isError: true`, discarding the partial payload. SKILL.md
  § Create step 3a says of that payload: "`panes` holds the ids that *did* get
  created and they are real: use them."

  Fix: `mapExecResult` takes an optional set of expected non-zero exit codes. For a
  code in that set it returns a result that is:
  - **not** `isError` — the caller must read it as data;
  - carrying the **full stdout verbatim**, so `complete: false`, `panes`,
    `failed_at`, `attempted`, and `error` all survive;
  - prefixed with the exit code the way exit 2 already prefixes `exit=2`, so a
    partial is distinguishable from a clean success without re-deriving it;
  - appending stderr under a `stderr:` heading when non-empty, matching the exit-0
    branch.

  Merely not throwing is insufficient. `roster_layout_splits` passes `{3}`; every
  other tool passes nothing and behaves exactly as today.
- `cwdSchema` unchanged; extract `teamSchema`; add `levelSchema` if `--level`
  repeats across ≥3 tools.
- Router: one `case` per new tool in `callTool` (server.mjs:173), building argv via
  `pushArg`/`pushFlag`, plus the `confirm` pre-check in §4.5. `cwd` validation at
  175–178 is already shared — do not duplicate it per tool.

## 6. `roster.mjs` — two changes

Eleven of the thirteen tools are pure argv construction over the same script through
the same `execCli`, altering no verb's behaviour, flags, exit codes, or output
shape, leaving every existing `tests/test-roster.sh` case valid unmodified.

Two exceptions, both deliberate:

1. §4.4's `requireAllowGlobal` guard on `move` — a security fix that stands on its
   own and benefits the Bash path.
2. §4.5's new `disband --close` mode, plus the `close_token` field added to
   `disband` plan output. Additive: plan mode gains a key, no existing mode changes
   behaviour.

`server.mjs` remains a pure wrapper — it gains no execution logic of its own. If
implementing any *other* wrapper appears to require a `roster.mjs` change, stop and
report rather than editing the CLI.

## 7. SKILL.md changes

`skills/agent-roster/SKILL.md` is 514 lines. Do **not** document both a Bash form
and a tool form per verb — that duplicates the file's largest section for no gain.

- Replace each `Run \`roster.mjs <verb> …\`` instruction with the corresponding tool
  call and its parameters.
- Add **one** line near the top: each `roster_*` tool maps 1:1 to
  `node roster.mjs <verb>` with the same flags; if the `ah` MCP server is not
  connected, use Bash with that mapping. That is the entire fallback story.
- **§ Create's orchestration prose is unchanged.** Steps 0/1/2/4 and the manual-mode
  loop describe what the *session* must do; §3 makes clear none of it moves.
  Rewriting the invocation lines is the whole edit there.
- Resolve the `--orchestrator-pid` discrepancy noted in §4.2 (SKILL.md:237–238 vs
  step 5) — verify against the CLI first, correct the document, report if the CLI is
  the side that is wrong.
- **§ disband step 3 is rewritten.** It currently says "run every non-null `command`
  in **one** Bash invocation". It becomes: call `roster_disband_close` with
  `confirm: true` and the `close_token` from step 1, after step 2's confirmation.
  Step 2's requirement to show the member list and get an explicit yes is unchanged
  and must be stated at least as strongly as today.
- Note that the harness will *also* prompt for `roster_disband_close` (§4.5.1), and
  that this does **not** replace step 2's conversational confirmation — the skill
  still shows the member list and asks first. Two prompts for one destructive action
  is intended: one legible and in-context, one harness-enforced.
- The two-call rule becomes plan → confirm → close → commit, with "never `--commit`
  before the closes" preserved in spirit.
- § move gains `--allow-global` per §4.4, and says why.
- Line 67–68's `next-split` testing-only note stays and now also explains why it has
  no tool.

Update the tool list in whatever 0013 wrote describing the server's surface.

## 8. Files to change

- `hooks/roster.mjs` — §4.4 guard; §4.5 `--close` mode and `close_token`.
- `mcp/server.mjs` — 13 tool registrations, router cases, `pushFlag`,
  `mapExecResult` expected-exit-codes parameter, `teamSchema` extraction, the
  `confirm` pre-check.
- **`hooks/pretooluse-disband-close-gate.mjs`** (new) — §4.5.1's ask hook.
- **The plugin's hooks manifest** (wherever the existing `pretooluse-*` hooks are
  registered) — one PreToolUse entry, matcher `mcp__ah__roster_disband_close`.
- `skills/agent-roster/SKILL.md` — invocation lines, the fallback line, the
  rewritten § disband step 3, the §4.5.1 note, the `move` guard note, the
  `--orchestrator-pid` fix.
- `tests/` — per §10.
- `plugin.json` **and** root `marketplace.json` — version bump. Both (0011 §14).

## 9. Sequencing with 0015

Both add tools to `mcp/server.mjs` and touch `skills/agent-roster/SKILL.md`;
independent in substance, mechanical overlap only.

Recommended order: **0016 first.** It refactors `mapExecResult`, adds `pushFlag`,
and extracts the shared schema fragments; 0015's single `roster_history` tool then
drops into the refactored shape as one more registration. Reverse works at the cost
of a small rebase. Neither blocks the other.

Both touch `hooks/roster.mjs` in unrelated places (0015: the `--commit` handler and
a new `history` verb; 0016: the `move` case and a new `disband --close` mode). No
conflict expected.

**If the two are implemented concurrently rather than in sequence**, watch the
shared-module boundary: 0015 adds helpers to `hooks/lib-roster.mjs` that
`hooks/sessionstart.mjs` imports, and a careless split there can produce a circular
import that breaks the suite. Land one, run the tests, then start the other.

## 10. Verification

- Every wrapped verb: tool call and the equivalent `node roster.mjs …` produce
  byte-identical stdout for the same inputs. Table-drive over all 13.
- `roster_layout_splits` on an exit-3 partial → **not** `isError`; the text carries
  the exit code *and* the full payload, `panes` / `complete: false` / `failed_at`
  all readable. Must fail before the `mapExecResult` change and pass after — a
  version that stops erroring but drops the payload does not pass.
- Exit 2 → `isError: true`, stderr prefixed `exit=2`, unchanged shape.
- Missing/blank `cwd` on every new tool → the existing 175–178 message.
- `roster_create` `mode: "commit"` without `verified` → error naming `verified`, no
  CLI invocation.
- `roster_create` `verified` round-trip: a JSON string with nested quotes reaches
  `--verified` unmodified.
- **`move` without `--allow-global` is refused**, same failure shape as sites
  624/1135. Assert on the CLI directly, not only through the tool.
- **`disband --close` without `--confirm` → exit 2, close list present in the error
  payload.** Assert the list is there, not just the non-zero exit.
- **`roster_disband_close` with `confirm: false` or omitted → refused in `callTool`,
  CLI never invoked.**
- **`disband --close` with a stale/absent `--plan-token` → refused**, message says
  to re-run the plan. Construct the stale case by closing one pane out of band
  between plan and close.
- `disband --close` builds argv, never `/bin/sh`: assert with a `transport_id`
  containing shell metacharacters that no shell interpretation occurs.
- `disband --close` leaves `team.json` in place; a following `disband --commit`
  removes it.
- A close that fails for one member → that member reported `closed: false` with
  `error`, others still closed, overall call not fatal.
- `roster_disband` in all three non-destructive modes closes nothing. Assert live
  panes survive.
- **§4.5.1 hook: fires on `mcp__ah__roster_disband_close` and returns
  `permissionDecision: "ask"`.** Test the hook directly with a synthetic PreToolUse
  payload (the existing `pretooluse-*` hook tests are the model — reuse their
  harness rather than inventing one).
- **§4.5.1 hook does NOT fire on any other `mcp__ah__*` tool.** Assert against at
  least `roster_disband` (the near-miss that matters) and one unrelated tool.
- **§4.5.1 hook still asks when `readTeam` fails** (point it at a cwd with no
  `team.json`): `permissionDecision: "ask"` with a generic message, never a skipped
  prompt.
- Baseline: full existing test suite green; `roster_show`/`roster_teams`/`msg_*`
  outputs unchanged.

## 11. NEEDS-EVIDENCE — all resolved

1. **(informational, non-gating)** Measure §2: (a) tokens for one full `auto`
   create + disband via Bash vs via the tools; (b) added per-turn context cost of
   +13 tool schemas on a session that connects `ah` and does nothing
   roster-related. Record the numbers; the scope decision is made either way.

2. ~~Enumerate every wrapped verb's exit codes.~~ **Resolved.** 0/2/else is complete
   except `layout-splits` exit 3. Folded into §5.

3. ~~Does 0009's confirm gate fire on the MCP path?~~ **Resolved.**
   `requireAllowGlobal` is called inside `roster.mjs` (567 def; 624, 1135 calls), so
   it fires identically via Bash or MCP, and `create --spawn` / `spawn-one` were
   always safe to wrap. The investigation instead surfaced that `move` is unguarded
   on every path — §4.4.

4. ~~Can this harness gate MCP tools by name?~~ **Resolved: yes, all three points**
   (verified against Claude Code's documentation). Permission rules support exact
   MCP tool-name matching (`mcp__ah__roster_disband_close`) and wildcards
   (`mcp__ah__*`); PreToolUse `matcher` supports the same form; and a matching `ask`
   rule produces a real interactive user approval prompt, not bypassable by the
   calling model. Acted on in §4.5.1 — the plugin ships the rule itself rather than
   leaving it to each user's config.

## 12. Status: no open questions

The one item that could have warranted escalation — whether a destructive MCP tool
can carry a user-enforced gate — resolved affirmatively, and §4.5.1 turns that
answer into a shipped default rather than a recommendation. **No Ultra-Advisor
escalation needed.**

The rest is mechanical wrapping plus two well-precedented CLI additions. Two
findings worth carrying into implementation: the `move` guard gap (§4.4) predates
this spec and is a real security fix to the existing Bash path, and the
close-execution design follows the existing `move` pattern (roster.mjs:1099) rather
than needing new machinery.

If §4.5.1 is dropped, descoped, or disabled during implementation, that reopens
§3.1 and must be reported upward rather than absorbed — it is the layer that makes
the disband reversal safe.

### 12.1 Amendment log

- **2026-08-26, §4.2** — `orchestrator_pid` was annotated `// spawn`; corrected to
  `// commit` per roster.mjs:956 (reviewer-reported spec-defect). Added the
  SKILL.md:237–238 discrepancy as a verify-and-report item in §7, since the two
  documents disagree about which mode accepts the flag.
- **2026-08-26, §9** — added the concurrent-implementation note about the
  `lib-roster.mjs` / `sessionstart.mjs` import boundary, after a circular import
  from parallel 0015 work broke the suite.
