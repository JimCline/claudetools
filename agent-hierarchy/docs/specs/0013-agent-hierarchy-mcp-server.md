# Spec 0013 — agent-hierarchy MCP server

Status: **specified, IMPLEMENTED as 6 tools, amended four times. GREENLIT by
Ultra-Advisor (ruling `20260825-155425-1r26`). BOTH BLOCKING NEEDS-EVIDENCE
ITEMS RESOLVED against live evidence. Amendment (c) RETRACTS §8's claimed
`gate.mjs` cwd defect — the claim was FALSE, `gate.mjs` is correct as written
and is not to be touched — and rules the tool inventory at SIX, final.
Amendment (d) resolves §4.3's pre-ship check: the root `marketplace.json`
mirror is REQUIRED and is the copy that actually registers the server. One
decision remains open and non-blocking: §11's tool count, which is the
USER'S.**

Author: Architect. Brief: `20260825-153349-fo5z`.

**Amendment log**
- **(a)** `20260825-155928-15lk` — Ultra-Advisor ruled: **hand-roll the
  JSON-RPC loop, no SDK.** §6 rewritten with protocol guardrails; §9 gains the
  blanket-allow caveat; §13's SDK risk struck; §12 test 1 promoted to the
  empirical interop check.
- **(b)** `20260825-161929-mnjy` — **NEEDS-EVIDENCE (a) and (b) RESOLVED** from
  15 live stdio handshakes (evidence: `20260825-160305-p41a`). §4 gains the
  registration mechanism decision and the **hard** `${CLAUDE_PLUGIN_ROOT}`
  placement rule; §5's design confirmed empirically necessary; §14 gains risk
  8; §12 gains tests 10 and 11; §13's (a)/(b) marked RESOLVED.
- **(c)** `20260825-180834-1afo` — **§8's defect claim RETRACTED as factually
  false**, on the Reviewer's reading of the shipped source
  (`20260825-180250-1jw4`) and an independent confirmation at
  `lib-gate.mjs:48-50`. There is no `gate.mjs` cwd defect and there never was.
  §8 rewritten as a correction record; the spec-0011-§9.6 citation **struck as
  invalid**; `gate_status` **ruled out on its own merits** (§8.3), fixing the
  inventory at **6 tools**. Cascading count/scope edits in §2.1, §3.2, §3.4,
  §4.3, §9, §10, §11, §12 (test 1 recount, test 7 struck), §14 risk 5, §15.
- **(d)** `20260825-182506-ik14` — **§4.3's "CHECK BEFORE SHIPPING" is
  ANSWERED, empirically, and the answer is the load-bearing one.** The root
  `marketplace.json`'s `ah` entry is what actually registers the server
  (`MCP servers (0)` → `(1) ah`); `plugin.json` alone was **insufficient**.
  §4.1 and §4.3 rewritten to make the mirror a hard requirement rather than a
  check; **§12 test 10 widened to assert the §4.2 placement rule on BOTH
  copies** (it was asserting it only on the non-registering one); **test 13
  added** for the drift hazard two copies create; §13 gains a RESOLVED entry;
  §14 risk 6 rewritten and risk 8 widened.

---

## 1. Goal

Agents (main session and subagents) repeatedly `find`/`grep` for
`agent-hierarchy/hooks/{msg,roster,gate}.mjs` before they can invoke it,
and intermittently fail with `MODULE_NOT_FOUND` when the cwd assumption is
wrong. Expose the operations as MCP tools so there is a **fixed handle** and
no path resolution in the caller's head.

**Non-goal:** changing what any subcommand does. This is a transport, not a
rewrite. Every semantic contract below (`msg.mjs new` output shape,
`validateRequestToken`, roster level defaulting, gate decisions) is preserved
byte-for-byte.

---

## 2. What investigation changed about the problem

Three findings, verified at source, that the brief did not have and that
change the design:

### 2.1 The cwd problem is ALREADY SOLVED at the CLI layer

**Every subcommand of all three scripts already accepts `--cwd <path>`.**

| file:line | expression |
|---|---|
| `hooks/msg.mjs:86` | `const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();` |
| `hooks/roster.mjs:111` | `const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();` |
| `hooks/lib-config.mjs:279` | `const env = process.env.AGENT_HIERARCHY_DIR; if (…) return resolve(env.trim());` |
| `hooks/lib-config.mjs:281-284` | `findGitRoot(base)` → `<root>/.claude/hierarchy`, else `~/.claude/hierarchy/<basename>` |

The brief asked "does an MCP tool call carry cwd?" — the right answer is
**it does not need to.** The MCP tool takes `cwd` as an explicit required
parameter and forwards it as `--cwd`. There is a second escape hatch
(`AGENT_HIERARCHY_DIR`) if one is ever wanted. **No new resolution
mechanism is to be invented.** See §5.

**`gate.mjs` is NOT an exception and NOT a defect** (corrected by amendment
(c)). Its state is not repo-scoped at all — one global HOME-anchored file,
keyed by session id — so `--cwd` is not a path selector there and nothing in
it needs threading. Full correction at §8. *An earlier revision of this
sentence said the opposite; it was wrong.*

### 2.2 The PreToolUse gates are NOT on Bash, so nothing is bypassed

`hooks/hooks.json:15` registers the three PreToolUse gates
(`route-gate`, `ultra-gate`, `msg-gate`) on matcher **`Agent|Task|SendMessage`**.
They gate *dispatch*, not *script invocation*. `node hooks/msg.mjs new` was
never gated, so routing it through MCP instead removes no control.

**This is stated explicitly because it is the first thing a reviewer should
worry about and the answer is non-obvious.** The claim to check if you doubt
it: `hooks.json:15`'s matcher string contains no `Bash` and no `mcp__`.

Corollary: if any of the new tools ever *should* be gated, the mechanism is
adding `mcp__<server>__<tool>` to a PreToolUse matcher (a pattern already used
elsewhere on this machine). Nothing in this spec adds such a gate.

**Amendment (a) note:** §9 now records a *separate* consent asymmetry that
this section does not cover — blanket-allow of `mcp__ah__*` versus per-command
Bash scrutiny. "No gate is bypassed" and "no consent posture changes" are two
claims, and only the first one belongs here.

### 2.3 The surface is far larger than the friction

`roster.mjs` alone has **15 subcommands** — `show init add edit remove layout
alias next-split layout-splits create disband resync move spawn-one teams` —
several with 5+ flags, several that spawn tmux panes and run for tens of
seconds, and one (`layout-splits`) with **exit code 3 meaning partial
success**. `msg.mjs` has 7, `gate.mjs` has 3 (`set`, `status`, `reset` —
`gate.mjs:59`, `:70`, `:94`). Twenty-five subcommands total.

The reported friction is about **path resolution**, not argv complexity, and
it occurs on a *small* subset: the subcommands that appear in prose an agent
reads and then types. That distinction is the design's spine — §3.

---

## 3. Design

### 3.1 The split: hand-typed vs. skill-scripted

Two populations of subcommand, and only one of them has the problem:

- **Hand-typed** — named in instructional text an LLM reads and then invokes
  ad hoc (`agents/*.md`, `commands/hierarchy.md`, `skills/agent-roster/SKILL.md`,
  README). These are where the `find`/`grep` tax is paid.
- **Skill-scripted / plumbing** — invoked as steps of the `agent-roster`
  skill's own procedure, or by tests, with the path already established by the
  surrounding flow (`next-split`, `layout-splits`, `create --spawn/--commit`,
  `resync`, `move`, `disband`).

**Only the hand-typed set becomes MCP tools.** The plumbing set stays
CLI-only.

**This criterion is the one that decides §8.3.** A subcommand earns a tool by
costing an agent a path resolution it cannot shortcut — not by being small,
safe, or read-only. Read-only is a *permission* to include, never a *reason*
to.

### 3.2 Tool inventory (the decision)

**6 tools.** Server name: `ah` (matches `plugin.json`'s `"name": "ah"`), so
tools are `mcp__ah__<name>`.

| tool | wraps | why in |
|---|---|---|
| `msg_new` | `msg.mjs new` | the single most-invoked op in the whole hierarchy; every role's `agents/*.md` tells it to run this |
| `msg_list` | `msg.mjs list` | orchestrator's open/closed sweep |
| `msg_index` | `msg.mjs index <path>` | the `grep -n '^## \['` step every role brief prescribes |
| `msg_roster` | `msg.mjs roster` | status read |
| `roster_show` | `roster.mjs show` | `SKILL.md:27-34` tells agents to run this by hand |
| `roster_teams` | `roster.mjs teams` | read-only multi-team listing |

**Deliberately EXCLUDED, with reasons:**

| excluded | reason |
|---|---|
| `msg.mjs route`, `msg.mjs global-scope` | invoked from `pretooluse-route-gate.mjs:120-202` as text the *user* is told to run, in a consent flow. A consent record written by a tool the model can call unprompted is a different security object than one a human pastes. **Out of scope; do not add without a separate ruling.** |
| `gate.mjs set`, `gate.mjs reset` | same class — these write escalation-gate decisions. |
| **`gate.mjs status`** | **read-only and harmless, and still excluded — it has no path-resolution friction to remove. Full reasoning at §8.3. Was tool 7 in revisions (a) and (b); removed by amendment (c).** |
| `roster.mjs init/add/edit/remove/layout/alias` | config mutation across three levels (`global`/`repo`/`repo-user`) with a defaulting warning on stderr. Wrappable later; not the reported friction. |
| `roster.mjs create/spawn-one/disband/move/resync/next-split/layout-splits` | spawn panes, run long, and `layout-splits` signals partial success via **exit 3**. See NEEDS-EVIDENCE (c) and (d): until we know MCP's timeout and whether exit codes survive, wrapping these trades a path problem for a truncation problem. |
| `msg.mjs sweep` | destructive-ish (archives files), rarely hand-typed. |

**Note the shape of the exclusion list:** every excluded item is either a
*write to a consent record*, a *long-running spawn*, or — the `gate.mjs
status` case — an operation with **no friction to remove**. Those are the
categories where "the model can now call this without typing a path" is a
downside, or simply not an upside.

> **This boundary is load-bearing and Ultra-Advisor endorsed it as such
> (`20260825-155425-1r26`).** The "do not add without a separate ruling"
> language in the first two rows is not decoration — §9's consent caveat rests
> on the inventory staying read-mostly. **A future tool addition that crosses
> this line silently invalidates §9's conclusion.**

### 3.3 Every tool is a thin exec, not a reimplementation

Each tool spawns `node <resolved>/hooks/<script>.mjs <subcommand> …
--cwd <cwd> --json` and returns stdout. **No logic is reimplemented.** This
is what makes "must not change the underlying CLIs' semantics" true by
construction rather than by test: there is one implementation and the MCP
tool drives it, exactly as a Bash caller does.

The server resolves the script path **once, from its own module location**
(`import.meta.url` → `hooks/`), which is the fixed handle the whole spec
exists to provide.

### 3.4 DECISION FOR THE USER — the cheaper fix is already 2/3 built

I am flagging this rather than deciding it, because it is a cost/benefit call
the user owns. **Ultra-Advisor endorsed the do-both / interpolation-first
ordering as-is.**

`hooks/lib-config.mjs:41-43` **already** defines:

```js
const GATE_CLI  = …/gate.mjs
const MSG_CLI   = …/msg.mjs
```

— resolved absolute paths, in the module that builds the SessionStart-injected
directive text. The rejected "cheap fix" (bake resolved paths into the
directive) is therefore already implemented for two of the three scripts. The
residual gap is that **there is no `ROSTER_CLI` constant**, and
`skills/agent-roster/SKILL.md` carries 40+ lines of `roster.mjs` instruction
with no resolved path anywhere.

So: adding one constant and interpolating the three into the directive and
SKILL text would remove most of the reported friction for roughly the effort
of this spec's §12 test plan alone.

> **Amendment (c) note — this section quietly contains §8.3's answer.**
> `GATE_CLI` is one of the two constants that **already exists, already
> resolved**. `gate.mjs` is the script with the *least* path friction in the
> repo, and it has been that way since before this spec was written.

**What the MCP server buys beyond that**, honestly stated:
- a handle that survives an agent not reading the directive (subagents whose
  context was trimmed),
- typed argument schemas instead of argv quoting,
- no `node` / Bash permission needed to send a message.

**What it costs:** every MCP tool's schema occupies context in *every*
session, always, whether used or not — 6 tools' worth, permanently. There is
a real irony risk in spending a permanent context tax to fix an intermittent
token waste.

**My recommendation: do both, in order.** Ship the `ROSTER_CLI` +
interpolation change first (it is small, helps immediately, and helps the
excluded 19 subcommands that this spec deliberately does *not* wrap), then
ship the server. The server is not a substitute for the directive text being
correct — §7 depends on that text either way.

**If the user wants only one: I would take the interpolation fix.** But the
brief records that the user already chose the server having been shown both
options, so this spec designs the server. Flagging, not overriding.

---

## 4. Files and server registration

### 4.1 Registration mechanism — RESOLVED (b), CORRECTED (d)

**Evidence (b):** 15 live stdio MCP handshakes against real Claude Code
sessions (`20260825-160305-p41a`). Both `.mcp.json` at the plugin root (4/4)
and an `mcpServers` key in `.claude-plugin/plugin.json` (5/5) register a real,
callable stdio tool.

**DECISION: declare `mcpServers` in `.claude-plugin/plugin.json`. Do not
create `.mcp.json`.** Rationale: the `plugin.json` variant is independently
corroborated by `hy3d-gen` — a real **cache-installed** plugin using the
identical shape — whereas `.mcp.json` was proven only under `--plugin-dir`
session-scoped loading, against `type:"http"` entries on a different code
path. **Both variants work; only one is proven in the mode we ship.**

**This remains a preference between two working options, not a correctness
finding.** §4.2 and §4.3 are the parts that are load-bearing.

> ### CORRECTION (amendment (d)) — `plugin.json` alone is NOT sufficient
>
> Revision (b) added a second rationale for `plugin.json`: **"one fewer
> file."** *That rationale is now false and is struck.* The Implementor proved
> empirically that the **root `marketplace.json`'s `ah` entry is what actually
> registers the server** — `MCP servers (0)` → `(1) ah` appeared only once it
> was present, and `plugin.json` on its own left the count at zero.
>
> **Both files carry the `mcpServers` block. This is not a choice and not a
> tidiness matter — it is the registration path.** The mechanism decision
> above survives (it is about `plugin.json` vs. `.mcp.json`, which is
> untouched by this); only its second supporting reason dies.
>
> **Note what that means for the *first* rationale, which did survive:**
> `hy3d-gen` corroborated the `plugin.json` shape in a cache install. It could
> not have told us the mirror was required, because a cache-installed plugin
> is read through the marketplace manifest already. **The corroboration was
> real and was still blind to this.** Evidence from one install mode does not
> enumerate what the *other* mode reads.

### 4.2 HARD REQUIREMENT — `${CLAUDE_PLUGIN_ROOT}` goes in `args`, NEVER in `command`

**This is a requirement, not a preference. It applies to EVERY copy of the
`mcpServers` block — see §4.3.**

```json
"command": "node",
"args": ["${CLAUDE_PLUGIN_ROOT}/mcp/server.mjs"]
```

**Evidence:** `${CLAUDE_PLUGIN_ROOT}` expanded correctly in `args` **9/9**
runs. Placed directly in `command` it worked **only 4/6** — and the two
failures produced **no error, no crash, and no diagnostic**: the tool simply
never appeared that turn, with server-side logs confirming the client never
attempted the spawn at all. **A reproduced ~33% intermittent registration
failure that is completely silent.**

This upgrades the earlier observation — *0 of 22 installed plugins use
`${CLAUDE_PLUGIN_ROOT}` in `command`* — from an absence of documentation into
a **reproduced defect**. The convention was not stylistic; it was other people
having hit this.

> **You cannot test your way out of this one.** A 33% intermittent,
> silent, client-side registration failure is exactly the class of bug a test
> suite cannot reliably catch — a passing run proves nothing. **The only
> viable guard is preventing the config shape that triggers it**, which is
> what §12 test 10 does statically. Note the shape of that argument: the test
> is not checking behaviour, it is checking that a known-cursed construct is
> absent.

### 4.3 The `marketplace.json` mirror — REQUIRED (amendment (d))

**Revision (b) filed this as a "CHECK BEFORE SHIPPING". The check has been
run and the answer is the load-bearing one, so it is promoted from a check to
a requirement.**

**The root `marketplace.json`'s `ah` entry must carry the same `mcpServers`
block as `.claude-plugin/plugin.json`.** Empirically demonstrated by the
Implementor: with the block in `plugin.json` only, the session reported
**`MCP servers (0)`**; adding it to the root `marketplace.json` produced
**`(1) ah`**. `marketplace.json` mirrors *keys*, not merely the version.

**Consequences, all of which the spec previously got only half-right:**

1. **The `${CLAUDE_PLUGIN_ROOT}` rule (§4.2) binds both copies.** Prior to
   this amendment, §12 test 10 asserted that rule against `plugin.json`
   alone — **the copy that does not register the server.** The most important
   test in the file was guarding the wrong file. Widened by test 10.
2. **Two copies of one config is a drift hazard**, and neither the §4.2 rule
   nor a per-file placement assertion detects drift: both copies can be
   individually well-formed and disagree with each other. **Test 13 exists
   for exactly that gap** and is new, not a restatement of test 10.
3. **A missing block is the silent-failure shape all over again.** If
   `marketplace.json` lacks it, registration works from a local checkout and
   fails from a marketplace install — with no error, exactly as §4.2's
   `command` placement fails with no error. **Absence must fail the suite,
   not merely a wrong value.**

> **The general shape, worth carrying past this spec:** revision (b) wrote
> *"this is a five-minute read, not an evidence item."* **That was correct
> about the cost and wrong about the consequence.** A cheap question can still
> gate a load-bearing fact, and filing it as cheap is what let it ship
> unanswered while a test was written against the assumption it would have
> corrected. **Cost of answering and cost of being wrong are independent
> axes.**

### 4.4 File list

**New:**
- `agent-hierarchy/mcp/server.mjs` — the server (§6).
- `agent-hierarchy/tests/test-mcp-server.sh` — §12.

**Modified:**
- `.claude-plugin/plugin.json` — add the `mcpServers` key per §4.1/§4.2, and
  bump the version.
- **root `marketplace.json`** — bump the version in the same commit (standing
  repo rule) **and mirror the `mcpServers` block into the `ah` entry, per
  §4.3. This is required for registration, not bookkeeping.**
- `hooks/lib-config.mjs` — add `ROSTER_CLI`; amend directive text (§7).
- `skills/agent-roster/SKILL.md` — amend `roster.mjs show` references (§7).
- `agents/architect.md:369`, `implementor.md:68`, `reviewer.md:86`,
  `task-runner.md:69`, `ultra-advisor.md:91` — the `msg.mjs new --type
  response` line (§7).

**Must NOT change:** `hooks/msg.mjs`, `hooks/roster.mjs`, `hooks/lib-hier.mjs`,
`hooks/hooks.json`, **`hooks/gate.mjs`, `hooks/lib-gate.mjs`**.

> **Amendment (c) — `gate.mjs` and `lib-gate.mjs` moved from "changes ONLY per
> §8" to "must NOT change."** §8 previously authorised a two-line edit to
> `gate.mjs`. **That authorisation is REVOKED: the defect it was fixing does
> not exist.** If a diff touches either file under this spec, it is out of
> scope regardless of how it is justified.

**Must NOT be created:** `.mcp.json` (§4.1), or `package.json`,
`package-lock.json`, `node_modules/` anywhere under `agent-hierarchy/` (§6.1,
§14 risk 7).

---

## 5. cwd / hierarchyDir resolution under MCP (acceptance (b))

**Rule: `cwd` is a REQUIRED parameter on every tool. The server never calls
`process.cwd()` and never guesses.**

### 5.1 EMPIRICALLY CONFIRMED NECESSARY (amendment (b))

This design was originally justified on principle. **It is now demonstrated.**

Live probe (`20260825-160305-p41a`): the server's launch cwd matches the
session's cwd at spawn time exactly — **including subdirectories** — and is
**frozen for the server's entire lifetime.** Confirmed by a verified,
actually-executed in-session `cd /var/tmp && pwd` followed by an unchanged
`probe_cwd` result from the **same server pid**.

**So the failure mode §5 guards against is real and reproducible, not
hypothetical.** A `process.cwd()` fallback would have silently written
messages into whatever directory the session happened to launch from, and
would have kept doing so after the user moved. **The required parameter is
necessary, not precautionary — this section is not over-engineered.**

**Scope of that necessity (amendment (c)):** it applies to every tool in the
inventory, all of which reach **repo-scoped** state under
`<root>/.claude/hierarchy`. It is *not* a universal property of the three
scripts — `gate.mjs`'s state is HOME-anchored and immune (§8). The frozen-cwd
finding is real; §8's former use of it as proof of a `gate.mjs` divergence was
not.

### 5.2 Why the parameter, restated with the evidence

The difference between the two transports is not whether cwd is *available*
but whether it is *current*:

| | Bash | stdio MCP server |
|---|---|---|
| process lifetime | one call | **whole session (confirmed: same pid throughout)** |
| cwd origin | inherited from session, per call | **frozen at spawn (confirmed)** |
| caller can change it | `cd` | **no (confirmed: `cd` had no effect)** |

Explicit, required, no default. If the model omits it, the tool errors with a
message naming the parameter. **Do not implement a "helpful" fallback to
`process.cwd()`** — a fallback here converts a loud error into a silent
misfile into a directory the user may have left an hour ago.

`AGENT_HIERARCHY_DIR` (`lib-config.mjs:279`) takes precedence over `--cwd`
inside the CLI and is left exactly as-is. The server must **not** set it.

---

## 6. Server shape (acceptance (d))

- **Transport: stdio.** Now doubly corroborated — 15 live handshakes (§4.1).
- **Location: inside the existing `ah` plugin**, at `agent-hierarchy/mcp/server.mjs`.
  Not a new package. Rationale: the server's entire value is resolving a path
  *relative to the scripts*, which requires it to ship next to them. A separate
  package would reintroduce the resolution problem one level up.
- **No state.** The server holds nothing between calls. Every call is
  `spawn → collect → return`. This keeps subagent-shares-parent's-server
  (see §9) from mattering.

### 6.1 Dependencies — ZERO. Hand-rolled JSON-RPC. (amendment (a))

**Ruled by Ultra-Advisor, `20260825-155425-1r26`: hand-roll the MCP stdio
JSON-RPC loop as dependency-free `.mjs`. The MCP SDK is REJECTED.**

Evidence behind the ruling: SDK v1.30.0 carries **17 direct dependencies** —
an HTTP + OAuth stack (express, hono, cors, jose, …). This plugin has no
`package.json` and no `node_modules`. Taking the SDK means either vendoring
`node_modules` into the repo or adding a manual install step, in exchange for
~150–200 lines of protocol whose **only client is Claude Code itself**. The
dependency-free property flagged as an open risk in the original draft is
therefore **confirmed intentional and load-bearing**, not incidental.

**Implementor guardrails — all from the ruling:**

1. **Framing is newline-delimited JSON** (current MCP stdio). It is **NOT**
   LSP-style `Content-Length` headers. Getting this wrong is the single most
   likely way a hand-rolled loop fails, and it fails at handshake with no
   useful error. **Test 1 is the empirical check against the real client
   (§12).**
2. **`initialize`** result echoes a **pinned, spec-named `protocolVersion`**,
   and declares **only the `tools` capability**. Do not advertise resources,
   prompts, sampling, or logging.
3. **Error codes:** unknown method → `-32601`. Unparseable line → `-32700`.
   Malformed request object → `-32600`. **Unknown *notifications* are ignored
   silently** — that silence is deliberate forward-compatibility, not an
   oversight; do not "fix" it into an error.
4. **Answer `ping`.**
5. **Do not assume serial calls.** Match responses to request `id`s.
   Concurrent `tools/call` is legal. Spawn-per-call (§3.3) already makes this
   safe — **the only requirement is not writing a read loop that blocks on one
   child while another request waits.**

### 6.2 Error and exit-code mapping

| CLI outcome | tool result |
|---|---|
| exit 0 | `content: [{type:"text", text: stdout}]`, `isError` unset |
| exit 2 (all three scripts' error path) | `isError: true`, text = **stderr verbatim**, prefixed with `exit=2` |
| exit 3 (`layout-splits` partial) | not reachable — that subcommand is excluded (§3.2). If it is ever wrapped, exit 3 must map to a **non-error result carrying the partial JSON**, never to `isError`. |
| spawn failure / timeout | `isError: true`, text names the resolved script path |

**stderr is never discarded.** `roster.mjs add/edit` emit a level-defaulting
warning on stderr alongside exit 0; that warning must reach the caller or the
agent silently writes to the wrong roster level. **On exit 0 with non-empty
stderr, append stderr to the text output under a `stderr:` line.**

Note the distinction from §6.1's item 3: those are **JSON-RPC protocol**
errors (the request was malformed). These are **tool-level** errors (the
request was fine, the wrapped command failed). A failed CLI invocation is a
successful JSON-RPC call returning `isError: true` — **never a `-32xxx`
response.**

---

## 7. Directive / instructional text (acceptance (c))

**Ruling: coexistence, and the CLI text stays authoritative.**
**Endorsed as-is by Ultra-Advisor.**

The MCP tools are added as the *preferred* handle; the `node <path>` text is
**corrected, not deleted.** Three reasons:

1. **19 of 25 subcommands have no MCP tool** (§3.2). Deleting the CLI
   invocation text would strand every one of them.
2. **The MCP server may be absent.** A user with the plugin's hooks but the
   server disabled, or an older install, still needs working instructions.
   Instructions that name only a tool that isn't there are worse than
   instructions that name a path. **§4.2's silent ~33% failure makes this
   sharper than it was — and §4.3 adds a second silent path to the same
   place: a marketplace install missing the mirror registers nothing, with no
   error. The CLI text is what keeps that session working.**
3. The text is *wrong today* independently of this spec — that is the actual
   root cause of the reported `MODULE_NOT_FOUND`. Fixing it is required either
   way.

**Concrete edits:**

- `hooks/lib-config.mjs`: add `ROSTER_CLI` beside the existing `GATE_CLI` /
  `MSG_CLI` at `:41-43`. Interpolate all three into the directive text so no
  agent ever sees a bare relative `hooks/X.mjs`. **`GATE_CLI` remains the only
  handle `gate.mjs` gets, and it is sufficient — §8.3.**
- Each of `agents/{architect,implementor,reviewer,task-runner,ultra-advisor}.md`:
  the `msg.mjs new --type response` line gains a preceding sentence naming
  `mcp__ah__msg_new` as the preferred form, with the `node <absolute path>`
  form retained immediately after as the fallback.
- `skills/agent-roster/SKILL.md:27-34`: `roster.mjs show` → prefer
  `mcp__ah__roster_show`. **Lines 117-259 are left alone** — they instruct the
  plumbing subcommands, which have no tools.

> **Carried forward from spec 0011 defect 9:** a spec that marks a
> documentation edit REQUIRED gets no test, no diff signal, and no reviewer by
> default. §12.5 exists specifically to make these edits mechanically
> checkable. Do not drop it.

---

## 8. RETRACTED — the claimed `gate.mjs` cwd defect does not exist

> **Amendment (c), `20260825-180834-1afo`.** Revisions (a) and (b) of this
> section asserted a latent `gate.mjs` cwd-handling defect, ruled it in scope,
> cited spec 0011 §9.6 as precedent, and made `gate_status` conditional on
> fixing it. **All of that was built on a false reading of the source. This
> section now records the correction rather than the claim.** The prior text
> is not preserved; the amendment log and §8.1 are the record of what it said.

### 8.1 What `gate.mjs` actually does

Verified at source, and independently confirmed by the Reviewer against the
shipped build (`20260825-180250-1jw4`):

| file:line | fact |
|---|---|
| `lib-gate.mjs:48-50` | `gatePath()` returns `join(homedir(), ".claude", "agent-hierarchy.gate.json")` — **one global, HOME-anchored file. No parameter. No `cwd`. No repo scoping of any kind.** |
| `lib-gate.mjs:90` | `getDecision(sessionId)` — takes a session id, nothing else |
| `lib-gate.mjs:91-92` | `const key = normalizeSessionId(sessionId); const entry = readGateState().sessions[key];` — **the index is the session id** |
| `lib-gate.mjs:116` | `setDecision(sessionId, choice, cwd)` |
| `lib-gate.mjs:122` | `state.sessions[key] = { choice, at: …, ...(cwd ? { cwd } : {}) };` — **`cwd` is stored as a descriptive field on the record** |
| `gate.mjs:89` | `status` prints `entry.cwd` as a display column |

**`setDecision`'s `cwd` parameter is a note-to-self written into the record so
a human reading `status` can see which repo a decision came from. It has never
selected a path.** `getDecision` and `gatePath` do not take a `cwd` because
there is nothing for one to select.

**Therefore:**
- `gate.mjs status` and `gate.mjs set` read and write **the same file, always**,
  in every cwd, under every transport. They cannot diverge.
- There is **no** "2 of 3 code paths ignore `--cwd`" bug. Two of three code
  paths correctly have no use for it.
- **The spec-0011-§9.6 citation is STRUCK as invalid.** 0011 §9.6 forbids
  shipping an exposure while filing its cause elsewhere. **There is no cause.**
  Invoking a precedent to justify fixing a non-defect does not merely fail —
  it launders a false premise through a real principle, which is worse than
  stating the premise plainly and being wrong.
- **§5.1's frozen-cwd finding is unaffected and remains correct.** It was
  simply applied to a mechanism it does not touch. A demonstrated property of
  the transport does not automatically implicate every consumer; §5.1 proves
  MCP freezes cwd, and that is only a problem for state selected *by* cwd.

### 8.2 How the false claim survived to a shipped build

Recorded because the failure mode is reusable, not to assign blame:

- The three call sites (`gate.mjs:65`, `:72`, `:83`) **look** asymmetric —
  one passes a cwd, two do not. That asymmetry is real and visible in a
  one-screen read of `gate.mjs`.
- **The reading stopped at the call sites and never opened `lib-gate.mjs`.**
  The asymmetry is fully explained one file over, at `lib-gate.mjs:48-50`,
  in three lines.
- **§15 listed the §8 defect as "high confidence … read from source and
  checkable."** It *was* checkable. It was not checked past the caller.
- Two review passes and an Ultra-Advisor endorsement ("endorsed as-is") went
  over it. **An endorsement corroborates the reasoning, not the premise the
  reasoning stands on** — nobody re-read the source, because the section
  presented itself as already source-verified.

**The general lesson, worth carrying:** *an argument that a parameter is
"ignored" is unfinished until you have read what the callee would have done
with it.* A parameter that is absent because it is meaningless is
indistinguishable, at the call site, from one that is absent by mistake.

### 8.3 RULING — `gate_status` stays out. The build stands at 6 tools.

**Decision: accept the 6-tool build as FINAL. Do not reinstate `gate_status`.**

The Implementor dropped it under the old §8's escape hatch — correct process,
false premise — so the outcome must be re-earned on real merits rather than
inherited. It is re-earned. **The reasoning below is independent of the
retracted defect; none of it depends on §8's old claim.**

**Why not, on merits:**

1. **It fails §3.1's inclusion criterion — the decisive reason.** A subcommand
   earns a tool by costing an agent a path resolution. **`gate.mjs` is the
   script with the least path friction in the entire plugin**: `GATE_CLI`
   (`lib-config.mjs:41-43`) already exists, already resolved to an absolute
   path, already interpolated into the SessionStart directive — it predates
   this spec. **The problem 0013 exists to solve is already solved for
   `gate.mjs`, and was before anyone wrote 0013.** Contrast `roster.mjs`,
   which has no constant at all (§3.4) and is exactly why §7 adds one.
2. **Its data has a second, tool-free handle.** The gate file is at a fixed,
   documented, HOME-anchored path (`~/.claude/agent-hierarchy.gate.json`,
   `lib-gate.mjs:48-50`). Any agent that wants gate state can `Read` that path
   directly with **no resolution step whatsoever**. `status` adds sorting and
   column formatting over it — real, but not worth a permanent context tax.
   **This is the only tool in the inventory whose underlying data an agent can
   reach without knowing where the plugin is installed.**
3. **Read-only was its entire stated justification, and read-only is a
   permission, not a reason.** §3.2's original "why in" column for
   `gate_status` read, in full, *"read-only"* — a licence to include with no
   friction claim behind it. Every other row names a specific document that
   tells an agent to type that command. **Nothing tells an agent to type
   `gate.mjs status`.** That absence is the finding.
4. **§11's open cost question cuts against the marginal tool.** The
   per-session schema tax is unmeasured (NEEDS-EVIDENCE (e)) and permanent.
   With the count genuinely in question and the alternatives on the table being
   3 and 1, **adding back the tool that its own §14 risk 5 called "the least
   valuable of the seven" is the wrong direction under uncertainty.**
5. **The 6-tool build exists, is reviewed, and passes.** Reinstating costs a
   new tool, a test-count change, and a new test — for the weakest member of
   the set. Not decisive alone; it is the tiebreaker, not the argument.

**What would reopen this** (stated so a future reader can reverse it cleanly,
rather than re-deriving from scratch): a documented instruction — in
`agents/*.md`, `commands/hierarchy.md`, or `SKILL.md` — that actually tells an
agent to run `gate.mjs status` ad hoc. **That would make it hand-typed under
§3.1 and flip reason 1**, which is the reason the other four exist to support.
Absent that, this is settled and not to be re-litigated.

**Had it been reinstated,** the contract would have been: thin exec over the
global file, `cwd` **still a required parameter** for uniformity with the other
six even though `gate.mjs` ignores it (a tool whose parameter contract differs
from its siblings' is a trap for the next reader). Recorded only so the
"reinstate" branch is not left as an unspecified hole.

**Confidence: HIGH.** Reason 1 is checkable at `lib-config.mjs:41-43` in one
read, and reasons 2–5 each survive independently. **No Ultra-Advisor
escalation recommended** — the blast radius is one absent read-only tool,
trivially reversible, and the retraction removes risk rather than adding it.

---

## 9. Identity, consent posture, and what this spec does NOT claim

- **Subagents share the parent session's MCP server.** A tool call from a
  subagent is indistinguishable from one by the main session.
- This changes **nothing**, because `msg.mjs new --from <role>` is
  caller-asserted today too. Bash could not verify `--from` either. **No
  regression, and no new guarantee.** Explicitly: the MCP server MUST NOT be
  described anywhere as authenticating the sender.
- The server has no `session_id`. Everything requiring one (`msg.mjs route`,
  `gate.mjs set`) is excluded from the inventory (§3.2) — which is the same
  boundary drawn for a different reason there, and the agreement between the
  two lines of reasoning is a mild point in the design's favour.
  **Precision note (amendment (c)):** this argument does **not** extend to
  `gate.mjs status`, which takes `--session` optionally and dumps every session
  when omitted (`gate.mjs:70-92`). **`gate_status` is excluded by §8.3's
  friction argument, not by this one** — do not cite the session-id boundary
  against it.
- Same family as spec 0011/0012's NEEDS-EVIDENCE (d) — peer identity does not
  reach the transport. **This spec does not fix that and does not depend on
  it being fixed.**

### 9.1 Consent asymmetry (amendment (a), per Ultra-Advisor)

**Users commonly blanket-allow a trusted server's `mcp__ah__*` tools, whereas
Bash invocations get per-command scrutiny.** That is a real difference in
consent posture and it is not covered by §2.2's "no gate is bypassed" finding
— the two are separate claims.

**It is acceptable here precisely because the inventory is read-mostly and
every consent-write operation is excluded (§3.2).** The acceptability is
therefore *conditional on that exclusion boundary holding*, not intrinsic to
the design.

**Amendment (c) strengthens this rather than weakening it:** dropping to 6
tools removes the only inventory member that touched the escalation-gate
mechanism at all, even read-only. The boundary is now further from the
consent-write surface than when Ultra-Advisor endorsed it.

> **Consequence for future work:** §3.2's "do not add without a separate
> ruling" is load-bearing and must be kept. **Any future tool addition that
> crosses the exclusion boundary silently invalidates this section's
> conclusion** — it does not merely extend the inventory, it revokes the
> reasoning that made blanket-allow tolerable. Re-derive §9.1 before adding
> any write tool.

Ultra-Advisor separately answered §15's narrow security question — whether
model-callable exposure changes the posture versus today's Bash + gate
arrangement — as **no posture change**, with the reasoning folded into this
section. §15 records that as answered.

---

## 10. Migration (acceptance (e))

**Coexistence, indefinite. No cutover date. Endorsed as-is by Ultra-Advisor.**

1. Ship the `ROSTER_CLI` + directive interpolation fix (§3.4, §7) — this is
   independently valuable and unblocks nothing else.
2. Ship the server with the 6 read-mostly tools, **registered in both
   `plugin.json` and the root `marketplace.json` (§4.3).**
3. Instructional text names the tool first, the CLI second, everywhere.
4. **No step 4.** A hard cutover is rejected: it would require deleting CLI
   instructions for 19 subcommands that have no tool, and would break any
   install where the server is not running — **including, per §4.2 and §4.3,
   an install where a config mistake or a missing mirror silently prevents
   registration.**

Revisit only if usage shows the CLI fallback is never taken — and that is a
measurement, not a plan.

---

## 11. DECISION FOR THE USER — tool count vs. permanent context cost

**The only open item in this spec, and it does not block implementation.
Ultra-Advisor's advisory lean was 7, contingent on running NEEDS-EVIDENCE (e)
first. Amendment (c) has since removed one tool on merits (§8.3), so the
shipped count is 6 and the question below is now "6 vs. 3 vs. 1."**

Six MCP tool schemas are loaded into **every session, always**. The friction
being fixed is intermittent. If the user's judgment is that the permanent cost
outweighs it, the correct smaller design is **3 tools** — `msg_new`,
`msg_index`, `roster_show` — which covers the overwhelming majority of
hand-typed invocations, or **1 tool** (`msg_new`) which covers the single
most-repeated one.

I chose a broad inventory because each addition is cheap *given* the server
exists and the excluded set is where the real cost lives. **I did not measure
the schema cost.** That makes this a judgment, not a derivation — see
NEEDS-EVIDENCE (e).

**Note the direction of travel.** §8.3 subtracted a tool by asking "what
friction does this remove?" rather than "is this safe to include?" **If the
user wants 3, that same question is the one to apply to the remaining
inventory** — it is a sharper instrument than the schema measurement, and it
is available now without running anything.

---

## 12. Test plan (acceptance (f))

New: `agent-hierarchy/tests/test-mcp-server.sh`, in the style of the existing
32 test scripts.

1. **Protocol interop against the real client — the handshake test.**
   *(Amendment (a) promoted this from a smoke test: with the SDK rejected, the
   framing/`initialize`/error-code contract in §6.1 is now OUR code.)*
   - Handshake over stdio with the real client; assert the server is reachable
     and reports exactly the **6** tool names, so an accidental seventh fails
     the suite. *(Count corrected from 7 by amendment (c). The assertion's
     purpose is unchanged — it is the tripwire on §3.2's boundary, and
     `gate_status` reappearing must fail it.)*
   - Assert `initialize` echoes the pinned `protocolVersion` and declares
     **only** `tools`.
   - Assert unknown method → `-32601`; a garbage line → `-32700`; an unknown
     **notification** → **no response at all** (this one is easy to write
     backwards — the assertion is silence).
   - Assert `ping` is answered.
2. **`cwd` is required.** Call `msg_new` with no `cwd`. Assert `isError` and
   that the message names the parameter. **This test must fail if someone adds
   a `process.cwd()` fallback** — that is its whole purpose (§5).
3. **Equivalence, the load-bearing test.** In a temp git repo, run
   `msg_new` via the tool and `node hooks/msg.mjs new --cwd <tmp> --json` via
   Bash with identical args. Assert the produced message files are
   **byte-identical apart from the id/timestamp**. Repeat for `roster_show`
   (pure read → assert byte-identical JSON, no exemption). This is what makes
   "semantics unchanged" a checked claim rather than an assertion.
4. **Wrong-cwd isolation.** Two temp repos A and B. `msg_new` with `cwd=A`;
   assert B's `msgs/` is empty. This is the §5 failure mode, tested directly.
5. **Directive/doc assertions (static greps).** Assert `lib-config.mjs`
   defines `ROSTER_CLI`; assert no `agents/*.md` or `SKILL.md` contains a bare
   relative `hooks/msg.mjs` / `hooks/roster.mjs` outside a code fence; assert
   each of the 5 `agents/*.md` files names `mcp__ah__msg_new`.
   **Stated limit, honestly:** this proves the strings are *present*, not that
   they are *correct or useful*. It catches the "marked REQUIRED, never
   written" failure (0011 defect 9) and nothing beyond it.
6. **stderr preservation.** Invoke `roster_show` in a state that produces the
   level-defaulting stderr warning at exit 0; assert the warning appears in the
   tool output (§6.2).
7. **STRUCK by amendment (c).** *This was `gate_status` cwd correctness — set
   under cwd A, read from a server whose own cwd is B, asserting the decision
   is found. It asserted a divergence that cannot occur: one global
   HOME-anchored file (§8.1). It would have **passed on unmodified code**,
   which is the opposite of what §12's original text claimed for it ("this test
   fails on today's code — that is the point"). **Do not resurrect it in any
   form.** The number is retired rather than reused so that a later reader
   comparing revisions does not silently match a new test against the old
   rationale.*
8. **No npm lifecycle.** Assert no `package.json`, `package-lock.json`, or
   `node_modules/` exists under `agent-hierarchy/` (§6.1, §14 risk 7).
9. **No `.mcp.json`.** Assert the file does not exist at the plugin root —
   §4.1 chose the `plugin.json` key, and two registrations of the same server
   is a configuration nobody intends. *(Weak assertion, stated as such: this
   guards tidiness, not correctness. Both mechanisms work.)*
10. **`${CLAUDE_PLUGIN_ROOT}` is not in `command` — in BOTH registration
    copies.** *(Added by amendment (b); **scope widened by amendment (d)** —
    see the note below, which is the reason this test exists in its current
    form.)*

    Parse **both** files:
    - `.claude-plugin/plugin.json`
    - the **root `marketplace.json`** — specifically the `ah` entry's
      `mcpServers` block (§4.3)

    For **each** file independently, assert:
    - a. an `mcpServers` block for `ah` **is present**. *Absence must FAIL,
      not skip.* A missing block in `marketplace.json` is precisely the
      marketplace-install silent failure §4.3 describes, and a test that
      quietly passes when the thing it guards is absent is worse than no test.
    - b. **no** `mcpServers` entry's `command` field contains the literal
      `${CLAUDE_PLUGIN_ROOT}`.
    - c. the `ah` entry **does** have `${CLAUDE_PLUGIN_ROOT}` in `args`.

    **This is the most important test in the file and the one whose value is
    least obvious.** §4.2's failure is silent, intermittent (~33%), and
    client-side — **a behavioural test would pass two runs in three and prove
    nothing.** This test does not check behaviour; it checks that a
    known-cursed construct is absent. **Do not "improve" it into a live
    registration check — that guard now applies to both copies, not just
    `plugin.json`.**

    > **Why it was widened, recorded because the failure is instructive.**
    > Revision (b) wrote this test against `plugin.json` alone, because §4.3
    > had filed the `marketplace.json` mirror as an unanswered pre-ship check.
    > The Implementor later proved the mirror is **what actually registers the
    > server**. So for one revision, *the file's self-described most important
    > test asserted the placement rule on the copy that does NOT register the
    > server, and not at all on the copy that does.* **A static test inherits
    > the blind spot of whatever the spec believed when it was written** — it
    > cannot notice a file nobody told it about, and it fails green while
    > doing so.

11. **Regression:** the existing suite must pass unchanged. Note the known
    order-dependent flake in `test-roster-create-spawn.sh` (independently
    reproduced as clean 3/3 standalone, unrelated to this spec) — it is not
    evidence of a regression here.
12. **`gate.mjs` and `lib-gate.mjs` are untouched.** *(Added by amendment
    (c).)* Assert the diff for this spec's commit modifies neither file. §8's
    retracted ruling authorised a two-line edit to `gate.mjs`; **that
    authorisation is revoked (§4.4), and an authorisation that briefly existed
    in a spec is exactly the kind of thing that gets acted on later by someone
    reading a stale revision.** Cheap, static, and it closes the retraction.
13. **The two `mcpServers` blocks agree.** *(Added by amendment (d).)* Parse
    both files as in test 10 and assert the `ah` server's `mcpServers` block is
    **deep-equal** between `.claude-plugin/plugin.json` and the root
    `marketplace.json`.

    **This is NOT redundant with test 10, and the distinction is the point:**
    test 10 asserts each copy is individually well-formed. **Two copies can
    both satisfy test 10 and still disagree with each other** — different
    `args` paths, a stale server filename in one, an entry added to one and
    not the other. §4.3 makes duplication mandatory, and **mandatory
    duplication without an equality check is a drift hazard with a delay
    fuse**: the copies diverge on some later edit, the local checkout keeps
    working, and only a marketplace install sees the stale one.

    *Deliberately an equality assertion, not a "both are valid" assertion.
    Validity is test 10's job; this test's only job is that there is one
    configuration, stored twice.*

---

## 13. NEEDS-EVIDENCE

**(a) — RESOLVED (amendment (b)).** How is a plugin's stdio MCP server
declared, and does `${CLAUDE_PLUGIN_ROOT}` expand in `command`?
**Answer:** both `.mcp.json` and `plugin.json`'s `mcpServers` register a
working stdio tool (4/4 and 5/5). `${CLAUDE_PLUGIN_ROOT}` is reliable in
`args` (9/9) and **fails silently ~33% of the time in `command` (4/6, no
error, client never attempts the spawn).** Folded into **§4.1** (mechanism
choice: `plugin.json`) and **§4.2** (the hard placement rule). Guarded by §12
test 10, risk 8.

**(a′) — RESOLVED (amendment (d)). Does `marketplace.json` mirror
`plugin.json`'s KEYS, or only its version?** *Filed in revision (b) as a
"five-minute read, not an evidence item" — that framing was the mistake; see
§4.3's closing note.* **Answer: it mirrors keys, and the mirror is what
actually registers the server.** With `mcpServers` in `plugin.json` only, the
session reported `MCP servers (0)`; adding the root `marketplace.json` `ah`
entry produced `(1) ah`. Folded into **§4.1** (the "one fewer file" rationale
struck), **§4.3** (mirror promoted from check to requirement), **§4.4**.
Guarded by §12 tests 10 and 13, risk 6.

**(b) — RESOLVED (amendment (b)).** Server launch cwd and whether it tracks
the session. **Answer:** it equals the session's cwd at spawn exactly,
including subdirectories, and is **frozen for the server's lifetime** —
confirmed by an executed in-session `cd` producing an unchanged result from
the same pid. Folded into **§5.1**. The required-`cwd`-parameter design is
**confirmed necessary, not precautionary.**

**(c) — non-blocking, still open. MCP tool call timeout.**
- Run: a stub tool that sleeps 30s, then 120s. Record where it is cut off.
- Decides: whether the excluded spawning subcommands (`create --spawn`,
  `spawn-one`) could ever be wrapped in a follow-up. Does not affect the 6.

**(d) — non-blocking, still open. Do distinct exit codes survive to the tool
result?**
- Run: a stub exiting 3 with JSON on stdout; observe what the caller sees.
- Decides: §6.2's exit-3 row, i.e. whether `layout-splits` is wrappable later.

**(e) — non-blocking, still open; it is the evidence behind §11. What does a
tool schema cost in per-session context?**
- Run: compare the session's initial context size with the server enabled vs.
  disabled.
- Decides: 6 tools vs. 3 vs. 1. Until measured, §11 is my judgment and the
  user's call, not a derivation.

**RESOLVED — the MCP SDK dependency risk** (amendment (a)). The plugin's
dependency-free property is **intentional**, and the SDK is rejected
(`20260825-155425-1r26`). Test 1 is the interop check the SDK would have
provided.

**NOT an evidence item — the retracted `gate.mjs` defect (amendment (c)).**
Recorded here only to close the loop: it was never an evidence question. It
was a source-reading question, answerable in three lines at
`lib-gate.mjs:48-50`, and it was answered wrongly by stopping at the call
sites. **Nothing needs to be run to confirm the retraction.**

---

## 14. Risks for the Implementor

1. **Do not add a `process.cwd()` fallback.** It will look like a kindness.
   §5.1 now *demonstrates* it would write into a stale directory. Test 2
   exists to stop you.
2. **Do not reimplement any CLI logic** in the server. Spawn the script. The
   moment a tool computes something the CLI also computes, the "one
   implementation" property is gone and every later divergence is a bug that
   only shows on one transport.
3. **Do not wrap the spawning subcommands** because they were easy to add.
   §3.2 excludes them for two independent reasons and (c)/(d) are unanswered.
4. **Do not delete CLI invocation text** anywhere (§7). Correct it.
5. **Do not touch `gate.mjs` or `lib-gate.mjs`, and do not add a `gate_status`
   tool.** *(Rewritten by amendment (c) — this risk previously said the
   opposite, making `gate_status` conditional on a two-line `gate.mjs` fix.)*
   **The defect that edit was fixing does not exist (§8.1), and the tool is
   ruled out on independent merits (§8.3).** If you find yourself about to
   thread a `cwd` into `getDecision` or `gatePath`, stop: `gatePath()` takes no
   arguments and returns a HOME-anchored constant, and passing it one would be
   dead code at best.
6. **The `mcpServers` block lives in TWO files and they must stay identical.**
   *(Rewritten by amendment (d) — this risk previously said "check whether
   `marketplace.json` mirrors keys." It does, and the mirror is the copy that
   registers the server: §4.3.)* Bump the version in both, and mirror the
   block into the root `marketplace.json`'s `ah` entry. **The failure mode of
   getting this wrong is not an error — it is a session that reports
   `MCP servers (0)` and says nothing about why.** Tests 10 and 13 guard it.
7. **Do not add the MCP SDK "to be safe."** Ruled out
   (`20260825-155425-1r26`). **The plugin has no npm lifecycle and must not
   gain one under a transport spec.** No `package.json`, no `node_modules`,
   no vendoring. Test 8 detects a violation. If the hand-rolled loop seems to
   need a library, re-read §6.1's guardrails rather than installing something.
8. **NEVER move `${CLAUDE_PLUGIN_ROOT}` into the `command` field** (§4.2), and
   do not accept a future edit that does — **in either file.** It will appear
   to work — that is the trap. **It fails roughly one run in three, silently,
   with the tool simply absent and nothing logged.** Anyone debugging that will
   look at the server first and never find anything wrong with it. Test 10 is
   the only guard, and it is only a guard on the files it was told to parse.
9. **The tool count is 6 and the test asserts it.** *(Amendment (c).)* If a
   later change adds a seventh, §12 test 1 fails **by design** — that failure
   is the boundary in §3.2 working, not a stale test. Re-derive §9.1 and get a
   ruling; do not update the number to make the suite green.

---

## 15. Confidence and escalation

**Escalated and answered. Ultra-Advisor ruling `20260825-155425-1r26` GREENLIT
this spec.** Both blocking evidence items are resolved live.

- High confidence: the `--cwd`-already-exists finding (§2.1), the
  gates-are-not-on-Bash finding (§2.2), and the thin-exec rule (§3.3) — all
  read from source and checkable.
- **RETRACTED (amendment (c)):** the `gate.mjs` defect, which this section
  previously listed under "high confidence … read from source and checkable."
  **It was checkable and it was wrong** — see §8.1 for the source and §8.2 for
  how it survived. **The confidence label was doing harm here:** it is what
  told two review passes and an Ultra-Advisor endorsement that the premise had
  already been verified, so nobody re-opened the file. *Treat "read from
  source" as a claim about which file was read, not as a warrant.*
- **Confirmed by live evidence:** the registration mechanism and the
  `${CLAUDE_PLUGIN_ROOT}` placement rule (§4.2), the required
  `marketplace.json` mirror (§4.3, amendment (d)), and the frozen-cwd premise
  behind §5 — the last still correct, and correct independently of the §8
  retraction that misapplied it.
- **Resolved by the ruling:** the dependency question (§6.1).
- **High confidence, newly settled:** the 6-tool inventory (§8.3). Reason 1 —
  `GATE_CLI` already exists resolved — is verifiable at `lib-config.mjs:41-43`
  in a single read, and the ruling holds even if the other four reasons are
  discarded.
- **Still low confidence, still the user's, still non-blocking:** the tool
  *count* (§11 — unmeasured; run NEEDS-EVIDENCE (e)).

**Two amendments in a row (c and d) corrected something this section had
marked settled.** They are unrelated defects with one shape in common: *a
claim about a file that was reasoned about but not read.* (c) reasoned about
`lib-gate.mjs` from its callers; (d) wrote a test against `marketplace.json`'s
role without checking it. **Neither needed an experiment — both needed one
file opened.** Weigh that before adding another "high confidence, read from
source" line here.

The narrow security question this section originally raised — *"does exposing
hierarchy operations as model-callable tools, rather than as commands a model
must compose and a Bash permission must approve, change the security posture
in a way §3.2's no-consent-writes exclusion does not fully cover?"* — was put
to Ultra-Advisor and answered: **no posture change.** The reasoning is
recorded at **§9.1**, along with the condition that makes it true and the
consequence if a future addition breaks that condition. **My belief that the
answer turned on the exclusion boundary was correct; what I had not stated was
the blanket-allow asymmetry that makes the boundary matter.** That is now
§9.1's first sentence.
