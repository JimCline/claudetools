# 0047 — A stable `ah` MCP server: diagnose first, then move the transport to a local HTTP daemon

Status: **r2, amended after implementation** (brief `20260909-201437-1jd1`;
Implementor report `20260909-193547-15ua`). r2 changes: §0 E6 misread
corrected; §1 table is transport-aware (D2); §3.2 `exec-error` trigger
widened + log-dir citation fixed (D1, M); §4.2 `server/discover` + batch
gate (I2); §4.3 self-replace rule restated (I1), first-install reload
sentence dropped (I3), `--stop` logs; §4.4 method 1 struck (E1 failed),
ambiguity rule; §6 results recorded; §12 lists the Implementor's
follow-up edits. r1 brief `20260909-162045-y0fj`. Ships as
agent-hierarchy **0.72.0** (after 0046's 0.71.0; whichever lands second
takes the next free minor — `.claude-plugin/plugin.json` and root
`.claude-plugin/marketplace.json` `ah` entry bump together). Written
against 0046 **r3/r4 tool names** (`team_*`, `roster_*`, `msg_*`); nothing
here touches the rename.

## 0. Goal, anti-goal, and what the evidence already says

Goal: the user stops having to restart / `/reload-plugins` the `ah` server.
Anti-goal: a fix that only works on this machine (a work machine runs the
same plugin from the same marketplace; it failed to connect there across
three fresh sessions at 0.41.0, spec 0024 §2.2, cause never found).

Facts (Engram + reads this round; all `file:line` in `agent-hierarchy/`):

- `mcp/server.mjs` (889 lines) is a hand-rolled, zero-dependency stdio
  JSON-RPC 2.0 loop (spec 0013 §4: SDK rejected for 17 deps):
  `readline` over `process.stdin` (`:24`, `:861-863`); every tool is an
  `execCli` `spawn(process.execPath, [hooks/msg.mjs | hooks/roster.mjs, …])`
  (`:28-29`, `:434-454`); `cwd` is a required param on every tool (`:47-50`,
  `:472-475`) — the server holds **no per-cwd state**. It has **no**
  `uncaughtException` / `unhandledRejection` / signal / `exit` handlers, no
  stderr logging, no timers, no `process.exit`. It dies silently.
- Identity (spec 0018 §4): `SESSION_PID = process.ppid` captured once at
  startup (`:31-37`) because the harness spawns the stdio server as a
  direct child and `CLAUDE_PID` is not in its env; seven `team_*`
  handlers pass it as `--orchestrator-pid` (`:533, :577, :597, :619, :708,
  :729, :773`), overridable by the `orchestrator_pid` param. **Any
  transport that is not a per-session child must supply this another way.**
- Registration: `mcpServers.ah = {command:"node", args:["${CLAUDE_PLUGIN_ROOT}/mcp/server.mjs"]}`
  in **both** `.claude-plugin/plugin.json` and the root marketplace entry
  (must stay identical — `tests/test-mcp-server.sh:349-403` test 13).
  `${CLAUDE_PLUGIN_ROOT}` is version-pathed
  (`~/.claude/plugins/cache/claudetools/ah/<version>`), so every version
  bump changes the resolved command line.
- Harness behaviour (code.claude.com/docs `mcp.md`, `plugins.md`, verified
  this round): stdio servers **never** auto-reconnect; HTTP servers retry
  **3×** on initial connect (connection refused / timeout / 5xx) and **5×
  with 1 s-doubling backoff** on a mid-session drop; `/reload-plugins`
  reconnects only plugin servers whose config **changed** and preserves
  the rest; plugin `mcpServers` may be `{type:"http", url}` exactly like
  project `.mcp.json`; `${VAR}` / `${VAR:-default}` expand in `command`,
  `args`, `env`, `url`, `headers`; approval is per server name; MCP-vs-
  SessionStart ordering is **undocumented**. Upstream #36308 and #54136
  (auto-reconnect) are open.
- The harness keeps a per-server, per-process log the user has never been
  pointed at: `~/Library/Caches/claude-cli-nodejs/<cwd with / → ->/mcp-logs-plugin-ah-ah/<ISO-time>.jsonl`
  (43 files in the claudetools cwd, 24 other cwds have one). Entries seen:
  `Starting connection with timeout of 30000ms` → `Successfully connected
  (transport: stdio) in 291ms` → `Connection established with capabilities
  {… serverVersion:{name:"ah",version:"0.70.0"} …}` → `Calling MCP tool: x`
  / `Tool 'x' completed successfully in 42ms` / `{"error":"exit=2\n…"}` +
  `Tool 'x' failed after 0s` (these are **tool-level** CLI exit codes, not
  crashes) → `Sending SIGINT to MCP server process` → `MCP server process
  exited cleanly`. One sampled server lived 2026-09-08 00:42 → 09-09 18:42
  (42 h, v0.66.0), was SIGINT'd by the harness, and four new log files
  appeared 13 s later within 80 ms (`…-917Z`, `-922Z`, `-968Z`, `-997Z`).
  **r2 correction (E6):** those four files carry four *different*
  `sessionId`s — four concurrent claude sessions each spawning its own
  server, not four servers for one session. r1's "same `sessionId`" was
  a misread. Separately, a live check during implementation found one
  `ah` stdio server (pid 40784) at **v0.67.0**, 29 h old and four
  releases behind the installed 0.71.0, still serving a session whose
  tool list showed pre-0046 names — shape C caught in the act: the
  harness keeps the old process until a reload/restart. E5 over all 43
  logs here: 30 × C, 13 × ok, 0 × A/B/C′ — every disconnect on this
  machine is the post-update shape the constant URL removes.
- Precedent in this environment: the engram plugin is `{type:"http",
  url:"http://127.0.0.1:7433/"}` with a SessionStart `ensure-server.sh`
  that idempotently starts the daemon (silent on success, exit 0 always,
  speaks only when the binary is missing); it has never needed a reload.
  engram's server is session-agnostic; `ah`'s is not (0018) — that is the
  one real design problem below.
- `~/.claude/plugins/installed_plugins.json` carries
  `"ah@claudetools": [{scope:"user", installPath:".../cache/claudetools/ah/0.70.0", version:"0.70.0", …}]`
  — the sanctioned way to find the current install (memory rule: never
  glob the cache; versions coexist).

## 1. Diagnosis step — ships first, unconditionally

The user cannot say which shape they hit. Three shapes, distinguishable
from data that already exists plus one lifecycle log this spec adds.

**r2 (D2): the table is transport-aware.** The transport is read from the
file's `Successfully connected (transport: stdio|http)` line (a file
that never connected is classified by the registration in force: `A`).
The reason: under §4's daemon the harness owns no process, so it never
writes `Sending SIGINT`, and *any* close line in an http file is the
harness closing its own client — normal, never evidence. r1's B rule
("closed without a preceding SIGINT") therefore classified every healthy
http session as B; the Implementor's interim "close not marked
`(cleanly)`" rule is replaced by the rows below.

| shape | stdio: harness jsonl | http: harness jsonl | lifecycle log (§3.2) | likely cause |
|---|---|---|---|---|
| **A — fails at start** | `Starting connection`, **no** `Successfully connected`, an error/timeout line | same; the error is `ConnectionRefused` × 3 (nothing on the port) | stdio: no `start` (never ran) **or** `start` → `exit` before `initialize`. http: no daemon `start` since the last `exit`/`EADDRINUSE`, or hook spawn failure | stdio: 0024 B1 `command:"node"` PATH-resolved; throw before handshake; node too old. http: ensure hook did not run / spawn failed / daemon exited (§3.2 `exit` says why) |
| **B — dies mid-session** | `Successfully connected`, tool calls, then a transport-closed / exited line **without** a preceding `Sending SIGINT` | `Successfully connected`, then a connection error (`ConnectionRefused` / `ECONNRESET` / `fetch failed` / `Connection failed`) or a retry `Starting connection` **later in the same file** | daemon pid serving that window has `uncaught` / `unhandled` / `signal` (not preceded by `stop`, §4.3) / `exit` without `replace` | a handler throw; stdin EOF (stdio); external kill; OOM |
| **C — post-update / reload drop** | `Sending SIGINT` + `exited cleanly`, then new file(s) `Starting connection` within seconds — reconnect either succeeds (nothing to fix) or fails (→ A on the new version). **Also C:** a file still serving a `serverVersion` older than the installed one (the 0.67.0-under-0.71.0 case, §0) | does not occur — URL is constant. A `replace` in the lifecycle log with the harness reconnecting is **ok** | stdio: `exit {signal:SIGINT}` then a new `start` with the new `version`. http: `replace {from,to}` → new `start` | documented: config path changed → harness drops the server; `/reload-plugins` required (stdio only) |
| **C′ — files moved under a running server** | connected fine; later **every** tool call fails with `exit=1 … Cannot find module …/hooks/<x>.mjs` (r2: spawn of `process.execPath` succeeds; it is node that fails — not `spawn ENOENT`) | same text, at most one request wide (self-replace, §4.3) | `exec-error` lines (§3.2, widened trigger) naming the missing module | the old version dir removed after an update while the old server still runs |
| **ok** | connected; SIGINT'd by the harness or still running | connected; any or no close line | — | — |

**r2.1 (Orchestrator rulings on the Implementor's two readings of this
table, both ACCEPTED):**

1. The "**Also C**" stale-`serverVersion` arm is evaluated **after** B and
   C′, and only for a file with **no close line**. "Still serving" means
   the session has not closed; unordered and unqualified the arm swallows
   C′ and B (both are old-version logs) and every historical file, which
   names an older version merely by being old. Consequence recorded: on
   the Implementor's machine `--diag` now reports 43 × C where E5
   recorded 30 C / 13 ok — the 13 were open sessions on an older version,
   which this table calls C.
2. The http-B "connection error … later in the same file" is **strictly
   after the handshake**. A presence test fails on real data: the harness's
   own cold-start retry writes a `ConnectionRefused` and a second
   `Starting connection` *before* `Successfully connected` on every
   hook-started daemon (E3), so presence alone classifies every healthy
   http session as B. This is why the `http-ok` fixture must be a real
   capture.

The http-B row is **under-sensitive by construction**: no real
mid-session daemon death has been captured yet (E8), the `http-down`
fixture is synthesized, and the harness's exact error strings on a
dropped http connection are only partly known. A daemon death is also
independently visible in the lifecycle log, which `--diag` prints
regardless of classification — so the user is never left with nothing.

Where to look, in order (goes into `docs/troubleshooting.md`, §5):

1. `/mcp` — status text and error for `ah`; `/plugin` → Errors tab.
2. `node <plugin root>/mcp/server.mjs --diag` (new, §3.4): reads the newest
   harness jsonl files for the current cwd and the lifecycle log, prints
   one classified line per server process (`A|B|C|C′|ok`, timestamps,
   version served, last error) and, after §4 lands, the daemon's
   `/health`. This is the thing the user runs on either machine when it
   happens again; its output is the evidence this spec's phase-2 fork
   (§4.6) is decided on.
3. `claude --debug=mcp` → `~/.claude/debug/<session-id>.txt` for the
   harness side of a startup failure (spawn error text, PATH).

**Protocol:** phase 1 (§3) ships now; the user runs `--diag` the next time
they reach for `/reload-plugins`; the Orchestrator files the output as
evidence against §6 E5/E6. Phase 2 (§4) is **not** gated on it (§2 says
why) but its identity fallback is.

## 2. Candidates, ranked

Costs scored on: permission prompts · daemon/process lifecycle ·
multi-repo cwd · work-machine portability · code size · what it fixes
(A start / B mid-session / C update / freshness = new code after update).

1. **(a) HTTP daemon on localhost, started by a SessionStart hook — PICK
   (phase 2, §4).** Fixes A (the hook starts it with the node that ran
   the hook — `process.execPath` — not PATH), B (harness retries 5× on a
   drop; the daemon outlives any one session), C (**the config is a
   constant URL; it never changes across versions, so nothing to
   re-evaluate**) *and* freshness (the daemon re-execs itself from the
   new install when it notices the version changed; the harness sees a
   sub-second drop and reconnects). Costs: one approval prompt when the
   `ah` config changes shape (once); a per-user background process
   (start/stop/health, §4.3); the 0018 identity problem — solved with a
   header the harness expands, with a peer-socket fallback (§4.4, E1);
   ~150 lines of stdlib `http` transport; multi-repo cwd is free (every
   tool already takes `cwd`; the daemon has no cwd state); portable
   (node stdlib + `installed_plugins.json`, no launchd). engram proves
   the hook-started-daemon pattern in this exact environment.
2. **(d) Stable stdio launcher** — `command:"sh", args:["-c","exec \"$HOME/.claude/hierarchy/ah-mcp\""]`,
   a hook-written shim pinning `process.execPath` and resolving the
   current install from `installed_plugins.json` at spawn. Fixes A and
   C's *drop* with ~40 lines and no daemon, keeps 0018 identity free —
   but **not freshness**: with an unchanging config, an update leaves the
   old server running old code and `/reload-plugins` (unchanged config →
   preserved) will not replace it; a session restart will. For a user who
   updates this plugin several times a day and wants the new tools
   immediately (0046's renames), that trades one reload for a restart.
   And it cannot fix B. **Loses on freshness.** Kept as the documented
   escape hatch (§4.5): the stdio loop stays and can be registered by
   hand with `claude mcp add`.
3. **(c) Harden stdio only** — the logging half is phase 1 and ships
   regardless; a supervisor that respawns a crashed child behind the same
   pipe would fix B but not C or freshness, and nothing on stdio can fix
   C: the harness never reconnects a stdio transport. **Loses: it cannot
   remove the reload.**
4. **(b) CLI-primary, drop MCP** — every call becomes a Bash tool call:
   a permission prompt (or a broad allow-rule) per invocation, raw CLI
   output in context, no JSON schema, and the two PreToolUse gates
   (`hooks.json` close gate + skill gate) key on **MCP tool names** and
   would have to be rebuilt as Bash-pattern matchers; 0041 and 0046 both
   invested in the tool surface. The CLI stays what it is today: the
   documented fallback (`docs/mcp-tools.md`). **Loses on prompts and gates.**
5. **launchd / systemd unit** (variant of (a)) — macOS-only plist or a
   Linux unit per machine to install by hand; the hook-started daemon
   gives the same lifetime without an installer. Rejected (anti-goal).

## 3. Phase 1 — instrumentation and `--diag` (no transport change)

Files: `mcp/server.mjs`, `docs/troubleshooting.md`, `docs/mcp-tools.md:69`,
`tests/test-mcp-server.sh`, `tests/fixtures/mcp-logs/*.jsonl` (new).

### 3.1 Invariants that must survive everything below

- **stdout is the protocol.** No code path may write a non-JSON-RPC byte
  to stdout in stdio mode (0013 §6; 0024 §6). All diagnostics go to the
  lifecycle log file and, in stdio mode, to stderr.
- Startup must not throw before the handshake: every new module-level
  read (log dir creation, `installed_plugins.json`) is guarded like the
  0.50.1 manifest read (`:40-44`) — failure degrades to "no log" /
  "unknown version", never to a dead server.
- Tool behaviour, schemas, `tools/list` contents, `instructions`, and the
  `execCli` result mapping (`:413-432`) are unchanged.

### 3.2 Lifecycle log

One append-only file, **`~/.claude/hierarchy/mcp-server.log`**. r2 (M):
this is deliberately **not** `hierarchyDir(cwd)` — that resolves per cwd
(git root first, `lib-config.mjs:334-366`; `:366` is only its no-git
fallback `~/.claude/hierarchy/<basename(cwd)>`) and the server, stdio or
daemon, is cwd-stateless. The log lives in the *parent* of that fallback,
`~/.claude/hierarchy/`, with `AGENT_HIERARCHY_DIR` (`:361`) replacing
`~/.claude/hierarchy` when set — one file per user, whatever cwd the
harness or the daemon's clients use. One JSON object per line,
written with the same append primitive the hooks use for `peers.jsonl`.
Events, each with `ts`, `pid`, `transport` (`stdio`|`http`), `version`:

- `start` — plus `ppid`, `session_pid` (stdio: the 0018 value), `node`
  (`process.version`), `exec` (`process.execPath`), `root` (the plugin
  dir the server is running from), `cwd`, `argv`.
- `stdin-end` (stdio: the harness closed the pipe), `signal` (`SIGINT`,
  `SIGTERM`, `SIGHUP` — logged, then default behaviour), `uncaught` /
  `unhandled` (message + stack, then exit 1 — a hung server is worse than
  a dead one), `exit` (`code`).
- `exec-error` — **r2 (D1), trigger widened.** Fires on **either**
  (i) `execCli`'s `child.on("error")` (`:447`) — spawn itself failed,
  e.g. `process.execPath` removed by a node upgrade under a running
  daemon (`err.code`, script path); **or** (ii) a non-zero exit whose
  stderr matches `ERR_MODULE_NOT_FOUND` / `Cannot find module` — the
  shape C′ actually produces (measured: with `hooks/` deleted the spawn
  succeeds and node exits 1 with `Cannot find module …/hooks/roster.mjs`;
  `child.on("error")` never fires). Fields: `script`, `code`
  (`err.code` for (i), `"MODULE_NOT_FOUND"` for (ii)), `missing` (the
  path in node's message when it can be extracted, else the script
  path). Kept rather than dropped because (i) is a real, distinct failure
  the harness log cannot show, and (ii) makes C′ visible in the one log
  that is not per-cwd. Every occurrence is logged; the 1 MiB cap bounds it.
- `stop` — written by `--stop` (a separate process appending to the same
  file) **before** it signals: `{target_pid}`. Lets `--diag` tell an
  operator stop (`stop` → `signal SIGTERM` → `exit`) from an external
  kill (`signal SIGTERM` with no `stop` within 5 s before it).
- `identity-ambiguous` — §4.4.
- **Not** per-tool-call lines (the harness jsonl already has them).

Size cap: at `start`, if the file exceeds 1 MiB rename it to `.1`
(overwriting) — no rotation library, no scheduler. Never throw from
logging.

### 3.3 Process handlers

Register handlers for `uncaughtException`, `unhandledRejection`,
`SIGINT`, `SIGTERM`, `SIGHUP`, `process.on("exit")`, and stdin `end`/
`close` (stdio mode) that emit §3.2 events. Signal handlers must **not**
swallow the signal in stdio mode — log and re-raise / exit with the
conventional code, so the harness's `exited cleanly` line stays true.

### 3.4 `--diag`

`node mcp/server.mjs --diag [--cwd <path>] [--json]`: no server is
started. It reads (i) the harness log dir for the cwd — darwin
`~/Library/Caches/claude-cli-nodejs/<encoded cwd>/mcp-logs-plugin-ah-ah/`
(encoding verified: `/Users/jimcline/git/repos/claudetools` →
`-Users-jimcline-git-repos-claudetools`); Linux path is assumed
`~/.cache/claude-cli-nodejs/…` (E7) — (ii) the lifecycle log, (iii) after
§4, `GET /health`. It prints, newest first, one line per harness log file:
its start time, the shape from §1's table (per transport — r2 D2),
version served, transport, tool-call count,
last error text (truncated), and the matching lifecycle `start`/`exit`
pair when `pid`/time correlate. Unknown or missing inputs are reported
as such, exit 0 always. Classification rules are exactly §1's table —
make the rule table data so the test fixtures (§7.3) pin each row.

### 3.5 Docs (phase 1)

- `docs/troubleshooting.md`: new section "The `ah` server is
  disconnected" = §1's table + where-to-look list + the one-line remedy
  per shape (A: check `--diag` `exec`/`node`; B: paste the `uncaught`
  line into an issue; C: `/reload-plugins` today, "goes away in 0.72.0
  phase 2"; C′: restart the session).
- `docs/mcp-tools.md:64-70` (the say-so-once remedy sentence): add "run
  `node <plugin root>/mcp/server.mjs --diag` and paste its output" before
  the `/reload-plugins` remedy. `agents/*.md` remedy sentences stay
  (still true; not the place for a diagnostic recipe — the skill/doc is).

## 4. Phase 2 — HTTP daemon

Files: `mcp/server.mjs`, new `hooks/sessionstart-mcp-ensure.mjs` +
`hooks/hooks.json` SessionStart entry, `.claude-plugin/plugin.json` and
marketplace `mcpServers.ah`, `docs/mcp-tools.md:1-8`, `README.md:387`,
`CONTEXT.md` (if it names the transport), tests (§7).

### 4.1 Registration

```json
"mcpServers": { "ah": { "type": "http", "url": "http://127.0.0.1:${AH_MCP_PORT:-7434}/" } }
```

Identical in both manifests (test 13 flips to assert this shape and the
**absence** of `command`/`args`/`${CLAUDE_PLUGIN_ROOT}`). Port 7434 is
the default (engram is 7433, sfx-gen 8756; no other local listener is
known). `AH_MCP_PORT` is honoured identically by the daemon, the ensure
hook, `--diag` and `--stop`, so a dev session can run a checkout's daemon
on another port (`AH_MCP_PORT=7435 claude --plugin-dir …`) without
touching the installed one. **No `headers` block** — E1 failed (§6):
the harness does not populate `CLAUDE_PID` for manifest expansion, and
when the launching shell happens to export it the value is the *parent*
session's pid, not the connecting one's.

### 4.2 Transport contract (Streamable HTTP, server side)

Bind **127.0.0.1 only**. Node stdlib `http`; no dependency (0013 §4 rule
stands). Endpoints:

- `POST /` — body is one JSON-RPC message (or a batch; treat a batch as
  sequential). Reply `200` `application/json` with the single response —
  the harness sends `Accept: application/json, text/event-stream` and the
  spec permits a plain JSON response; no SSE is emitted, ever. A
  notification (no `id`) → `202`, empty body. `initialize` → allocate an
  opaque session id, return it in `Mcp-Session-Id`; every later request
  must carry it (`400` if missing, `404` if unknown/expired) — the docs
  say the harness expects session ids; do not run stateless (E2 checks a
  stateless server is *not* required).
- **r2 (I2, blessed):** the harness POSTs **`server/discover` before
  `initialize`** (observed, undocumented). It cannot carry a session id.
  The sessionless exemption is exactly two methods — `initialize` and
  `server/discover` — and `server/discover` is answered with an empty
  result object. Nothing else is exempt. Session gate on a batch: every
  message in the batch is gated individually; if any message needs a
  session id the batch has not supplied, the whole request is `400` —
  an exempt method cannot smuggle a non-exempt one through.
- `GET /` → `405` (no server-initiated stream; the harness also probes
  `GET /` with `Accept: text/event-stream` and tolerates the 405 —
  observed). `DELETE /` with a session id → `200`, session dropped.
- `GET /health` → `200` `{name:"ah", version, pid, root, port, started,
  sessions:<count>, node}` — consumed by the ensure hook, `--diag`,
  `--stop`, and the tests. Unauthenticated, localhost only, like every
  other local MCP daemon here (engram, sfx-gen); document that any local
  process can drive it, which is the same trust the CLI scripts already
  have.
- Sessions expire after 24 h idle; a `notifications/initialized` after
  `initialize` is required by the protocol but must not be *waited* on.
- Every `tools/call` reaches the **same dispatch function the stdio loop
  uses** — one implementation of the JSON-RPC methods (`initialize`,
  `ping`, `tools/list`, `tools/call`), two thin transports. The stdio
  loop is kept: no args = stdio (tests, `claude mcp add` escape hatch);
  `--http` = daemon.
- Concurrency: requests are independent `execCli` spawns; nothing is
  serialised. Per-session state = `{session_pid, created, lastSeen}` only.

### 4.3 Daemon lifecycle

- **Start:** `hooks/sessionstart-mcp-ensure.mjs` on every SessionStart
  matcher (`startup|resume|clear|compact|fork`, same as
  `sessionstart.mjs`): `GET /health` with a ≤300 ms timeout; if it answers
  with a `version` equal to the plugin's own → done; if it answers with
  another version → do nothing (the daemon self-replaces, below); if it
  does not answer → spawn `process.execPath [<CLAUDE_PLUGIN_ROOT>/mcp/server.mjs, "--http"]`
  `detached`, `stdio: ["ignore", <log fd>, <log fd>]` (log = the §3.2
  file), `unref()`, exit. **Silent on success (SessionStart stdout is
  injected into context — engram's rule), exit 0 always**, one line on
  stdout only when the spawn itself fails (so the model can tell the user
  the daemon could not start and the CLI fallback applies). The bind
  **is** the lock: a second starter's daemon gets `EADDRINUSE`, logs it,
  exits 0 — no pidfile. Ordering vs the harness's connect: **measured
  (E3)** — on a cold machine the connect attempt wins by ~120 ms, fails
  `ConnectionRefused`, and the harness's own retry connects 1.6 s later,
  unattended. **r2 (I3): no first-install `/reload-plugins` sentence
  anywhere** — docs state the measured fact instead ("first session
  after install connects on the harness's retry, ~2 s").
- **Self-replacement on update.** On each request (cheap: one `stat`),
  compare `installed_plugins.json`'s current `ah@*` `installPath` against
  the daemon's `root`. **r2 (I1, blessed and restated):** replace iff
  `installPath ≠ root` **and** `dirname(installPath) === dirname(root)`
  — i.e. both are version dirs under the same marketplace cache dir
  (`…/cache/<marketplace>/ah/`). r1's "root not in the JSON never
  replaces" cannot be read literally: after an update the daemon's own
  root is the *previous* install path, which is exactly what is no longer
  listed. The sibling-dir rule admits a genuine version bump and
  excludes every `--plugin-dir` checkout; a marketplace rename or a
  cache relocation also does not self-replace (session restart, today's
  baseline — acceptable, note in the doc). **Order on mismatch (r2.1, Orchestrator
  ruling — replaces r2's spawn-first order, which was a bind race: the
  child inherits a port its own parent still holds, takes `EADDRINUSE`
  and exits 0 per the bind-is-lock rule, after which the parent closes
  and the port is dead):** answer the in-flight request →
  `server.close()` (stop accepting; in-flight drain) →
  `spawnDaemon(next)` → poll `GET /health` on the port every 100 ms up
  to 3 s → health answers with `root === next` → log
  `replace {from, to}` → exit 0. No answer in 3 s, or the spawn throws
  (e.g. `execPath` gone) → log `replace-failed {to, err | "no health in
  3s"}` → `server.listen(port)` again, `replacing = false`, and **keep
  serving** the old code — a stale daemon beats a dead port; the next
  SessionStart hook will not fix it either (same `execPath`), so
  `--diag` must print `replace-failed` prominently. The
  harness sees a connection drop and retries (1 s first) — the
  replacement is listening well inside that. Whether the harness
  refreshes `tools/list` on reconnect is E4 (still unmeasured — needs an
  installed 0.72.0 and a live bump) — if not, renamed tools still need a
  session restart (no worse than today), and the doc says so.
- **Stop:** `node mcp/server.mjs --stop` — `GET /health` → `pid` → append
  `stop {target_pid}` to the §3.2 log → `SIGTERM`; the daemon's `SIGTERM`
  handler closes the listener and exits 0. Also reachable as
  `roster.mjs`? No — the daemon is not a roster concern; one flag on the
  server is the whole CLI.
- **Logs:** daemon stdout/stderr are the §3.2 file (`start` line carries
  `transport:"http"`, `port`).
- **Reboot:** nothing persists; the next session's hook starts it.

### 4.4 Identity (spec 0018 under a shared daemon)

The daemon has no session parent; `process.ppid` is meaningless. The
value seven tools pass as `--orchestrator-pid` must come from the
connection:

1. ~~Header `${CLAUDE_PID}`~~ — **struck in r2: E1 failed.** The
   harness does not populate `CLAUDE_PID` for manifest expansion (literal
   `${CLAUDE_PID}` arrives when the env lacks it; the launching shell's
   *parent* pid arrives when it has it). Not built; no `headers` block.
2. **Socket peer lookup — the shipped mechanism (E1b passed on darwin):**
   at `initialize`, resolve the client's ephemeral port
   (`req.socket.remotePort`) to its owning pid — darwin
   `lsof -nP -iTCP:<port> -sTCP:ESTABLISHED -Fp`, Linux
   `ss -tnpH 'sport = :<port>'` — once per MCP session, cached on the
   session, the daemon's own pid filtered out; failure → `session_pid:
   null` (today's behaviour when reparented). **More than one non-self
   candidate** (a forked client sharing the socket): log
   `identity-ambiguous {pids, chosen}` and take the **smallest** pid —
   the ancestor in practice (ponytail ceiling: pid wrap; upgrade path is
   walking ppid chains to pick the candidate that is not a descendant of
   another). Unmeasured on the work machine (E1b there is still open).
3. `orchestrator_pid` param override — unchanged, still wins.

The `start` log line and `/health` report which method is in use. The
resolved pid must be the **harness** pid (what `sessionstart.mjs:120`
records as `pid`), which is what 0018 verified `process.ppid` to be — the
§7.2 identity test asserts equality with the test's own harness stand-in.

### 4.5 Escape hatch

`docs/mcp-tools.md` gets one paragraph: if the daemon cannot run on a
machine, `claude mcp add ah -- node <plugin root>/mcp/server.mjs`
registers the stdio loop per-project (name collides with nothing —
plugin servers are namespaced `plugin:ah:ah`); everything else is
unchanged. Not tested beyond §7.1's stdio suite staying green.

### 4.6 The fork this phase leaves open

E1 has failed (r2). If the peer-socket lookup **also** proves unreliable
on the work machine (E1b there), identity degrades to
`orchestrator_pid`-or-null for the seven tools — `team_create`/`adopt`/`spawn_*` would record a null
orchestrator and `team_reap` would see every team as orphaned. That is
the one outcome that should send this back to the Architect (or the
Ultra-Advisor: it is a public-interface question — should those tools
*require* `orchestrator_pid` under HTTP?). Everything else in §4 is
additive or behind the transport flag.

## 5. Skills / agents text

No change to `agents/*.md` or `skills/agent-team|agent-roster/SKILL.md`
"try MCP first, fall back to CLI, say so once" — still correct and
transport-independent. Only the docs in §3.5 and §4.5 change.

## 6. NEEDS-EVIDENCE — results as of r2

- **E1** — `${CLAUDE_PID}` in manifest `headers`: **NO.** Literal string
  when unset in the launching env; the *parent* session's pid when set.
  → §4.4 method 1 struck.
- **E1b** — socket peer lookup: **YES on darwin** (`lsof` returned daemon
  pid + connecting `claude` pid; end-to-end test asserts `team.json`'s
  `orchestrator.pid` = the client's pid, ≠ the daemon's). **Work machine:
  still open** — run `tests/test-mcp-http.sh` there once 0.72.0 is
  installed; failure → §4.6.
- **E2** — plain JSON + server-issued `Mcp-Session-Id`: **YES**, probe and
  real harness (`Successfully connected (transport: http) in 78ms`).
  Bonus facts: `server/discover` before `initialize`; `GET /` SSE probe
  tolerates 405 (§4.2).
- **E3** — cold-machine ordering: **connect wins by ~120 ms; harness retry
  connects 1.6 s later**, unattended. → first-install reload sentence
  dropped (§4.3).
- **E4** — `tools/list` refresh after self-replace: **NOT MEASURED**
  (needs an installed 0.72.0 + a live bump). Open; decides one doc
  sentence. Orchestrator: measure on the first real bump after 0.72.0
  installs.
- **E5** — 43 harness logs, this machine: **30 × C, 13 × ok, 0 × A/B/C′.**
  0024's open question closed for this machine; work machine unmeasured.
- **E6** — four files = **four sessionIds** (four concurrent sessions,
  one server each), not four servers per session. §0 corrected.
- **E7** — Linux log dir: **unverified**; implemented as assumed with a
  call-site comment.
- **E8 (new, r2)** — a real captured http mid-session daemon death
  (harness jsonl + lifecycle log) to replace the synthesized `http-down`
  fixture and confirm the harness's error strings in §1's http-B row.
  Until then B-http is under-sensitive (§1). Capture: `kill -9` the
  daemon during a live session, save both logs.

## 7. Verification — tests that fail without the change

Existing suites use `HOME` redirection + `spawn(process.execPath,
[serverPath])` (`tests/test-mcp-server.sh:27-29`, `:62`); reuse that.

### 7.1 Phase 1 (`tests/test-mcp-server.sh` extended; fixtures)

1. Lifecycle: run the stdio server, complete `initialize`, close stdin →
   log has `start` (with `version`, `session_pid` = the test's pid,
   `exec`, `root`) then `stdin-end` then `exit`. Fails on HEAD (no file).
2. Crash path: with `AH_MCP_TEST_CRASH=1` a `tools/call` for
   `__test_crash` throws inside the handler → `uncaught` line with a
   stack, process exit code 1, nothing extra on stdout. (Test-only knob,
   gated on the env var; absent it the name is an unknown tool.)
3. `exec-error`: point the server at a missing `hooks/` (copy the
   `mcp/` dir alone) → a `tools/call` yields the existing `isError`
   result **and** an `exec-error` line with `code:"MODULE_NOT_FOUND"`
   naming the missing module (r2: trigger (ii) in §3.2 — the r1
   wording assumed spawn ENOENT, which cannot happen with `execPath`).
4. `--diag` on `tests/fixtures/mcp-logs/*.jsonl` → exactly one
   classification per file, matching the fixture name; missing dir →
   "no harness logs for <cwd>", exit 0. r2 fixture set: stdio
   `{ok,fail-start,mid-session,reload,files-moved}` as shipped, plus
   **`http-ok`** (a real file from the E2 run — a healthy http session
   with its close line; must classify `ok`), **`http-fail-start`**
   (`ConnectionRefused` × 3, never connected → `A`), **`http-down`**
   (connected, then a connection error later in the file → `B`;
   synthesized — header comment says so and names E8). Also a
   lifecycle-log fixture pair proving `stop → signal SIGTERM → exit` is
   reported as an operator stop and a bare `signal SIGTERM → exit` as
   external.
5. Cap: a 1 MiB + 1 byte log is renamed to `.1` on `start`.

### 7.2 Phase 2 (`tests/test-mcp-http.sh` new; `test-mcp-server.sh` test 13)

1. Test 13 → both manifests' `mcpServers.ah` are byte-identical, `type`
   `http`, `url` `http://127.0.0.1:${AH_MCP_PORT:-7434}/`, no `command`,
   no `args`, no `CLAUDE_PLUGIN_ROOT`. Fails on HEAD.
2. Daemon on a free port (`AH_MCP_PORT=<picked by the test>`): `initialize`
   → `200`, `Mcp-Session-Id` present; `tools/list` **byte-equal** to the
   stdio loop's; `tools/call msg_new` with `cwd` creates the file;
   notification → `202`; `GET /` → `405`; missing session id → `400`,
   unknown → `404`; `DELETE` → `200` then the id is `404`; `/health`
   reports the checkout's version, `transport:"http"`; five concurrent
   sessions each get distinct ids and all succeed.
3. Identity (socket variant only — r2): a client with no
   `orchestrator_pid` → `team.json`'s `orchestrator.pid` equals the
   client process's pid and not the daemon's (as shipped). Header
   variant: gone, not "skipped".
4. Self-replacement: `HOME`-redirected `installed_plugins.json` pointing
   `installPath` at copy A of the checkout; start the daemon from A; edit
   the JSON to copy B (**B a sibling dir of A**, plugin.json version
   bumped in B); one request → within 2 s `/health` on the **same port**
   reports B's version and a new pid; the log has `replace`. A daemon
   started from a root **outside** the JSON's `dirname(installPath)`
   never replaces. r2 adds: JSON repointed at a sibling path that does
   not exist (or whose `mcp/server.mjs` is missing) → `replace-failed`
   logged, old daemon still answers `/health` with its old version and
   pid.
5. Ensure hook (cwd-injection + `HOME` redirect, the pattern in
   `memory/testing-claudetools-hook-plugins.md`): daemon absent → after
   the hook, `/health` answers within 2 s and the hook printed nothing;
   daemon present → no second process (`pgrep` count unchanged), hook
   printed nothing; unstartable root → hook exits 0 with one line.
6. `--stop` → `/health` stops answering; log has `signal SIGTERM` + `exit`.
7. Bind: a second daemon on the same port exits 0 with an `EADDRINUSE`
   log line, no stdout.
8. Whole `agent-hierarchy/tests` suite green; the stdio suite is
   unchanged except test 13 and the phase-1 additions.

## 8. Files — summary

- `mcp/server.mjs`: §3.2-3.4 (log, handlers, `--diag`), §4.2-4.4
  (`--http`, `/health`, sessions, identity, self-replace, `--stop`).
- `hooks/sessionstart-mcp-ensure.mjs` (new) + `hooks/hooks.json`
  SessionStart entry (same matcher as `sessionstart.mjs`; separate script
  so `sessionstart.mjs`'s subagent/`--agent` guard and the roster write
  stay untouched).
- `.claude-plugin/plugin.json`, root `.claude-plugin/marketplace.json`
  (`mcpServers.ah`, versions).
- `docs/troubleshooting.md`, `docs/mcp-tools.md` (§3.5, §4.1 wording,
  §4.5), `README.md:387` one line, `CONTEXT.md` if it names stdio.
- `tests/test-mcp-server.sh`, `tests/test-mcp-http.sh` (new),
  `tests/fixtures/mcp-logs/` (new).

Must NOT change: tool names/schemas/outputs and `instructions`
(0046 owns the surface); `execCli`'s result mapping; the hooks' state
files (`peers.jsonl`, team.json); `sessionstart.mjs`; the CLI fallback
protocol in `docs/mcp-tools.md:9-70` beyond the two sentences named; spec
0018's `orchestrator_pid` override semantics.

## 9. Decisions

Made: (a) over (d) because (d) cannot deliver freshness on stdio and the
user updates daily; hook-started daemon over launchd (portable, engram
precedent); stdlib `http`, no SDK (0013 rule); keep the stdio loop (tests
+ escape hatch, ~30 lines); fixed default port with `AH_MCP_PORT`
override; self-replacement on version change rather than "old code until
restart"; bind-as-lock, no pidfile; `/health` unauthenticated on
localhost; `--diag` as a server flag rather than a new script; phase 1
and phase 2 in one release.

**User decisions — asked 2026-09-09, user accepted all three defaults (U1 yes, U2 together, U3 localhost no auth):**

- **U1** — a per-user background daemon that outlives sessions (engram
  already is one). Default yes.
- **U2** — ship phase 1 + phase 2 together in 0.72.0, or phase 1 alone
  and wait for E5 evidence. Default together: the C shape is documented
  and certain, and every phase-1 line survives either answer.
- **U3** — localhost daemon with no auth (same trust as the CLI). Default
  yes; the alternative is a shared secret in `headers` via `${VAR}`,
  which E1's answer also settles the feasibility of.

Refused: rewriting the server on the MCP SDK; CLI-primary; a launchd
plist; a supervisor wrapper on stdio; changing 0018's override param.

## 10. Risks

- **Identity is the only real design risk** (§4.4/§4.6). Two mechanisms
  plus the override; the tests assert the harness pid, not merely a pid.
- A changed `mcpServers` shape may re-prompt approval once per
  workspace (keyed by name); one-time, documented.
- First session on a cold machine connects before the hook starts the
  daemon (E3, measured) — the harness's retry absorbs it in 1.6 s; no
  user action.
- Old version dir removed while the daemon runs old code (C′): the
  self-replace check runs on every request, so the window is one
  request; `exec-error` (trigger (ii)) makes it visible if it ever bites.
- A node upgrade that removes the daemon's `process.execPath`: every
  tool call logs `exec-error` (trigger (i)) and self-replace logs
  `replace-failed`; the fix is `--stop` + a new session (the hook
  spawns with the new node). `--diag` must say exactly that when it sees
  `replace-failed`.
- Test cleanup must never sweep processes by command line
  (`pkill -f "mcp/server.mjs --http"` would kill the user's live daemon
  once 0.72.0 is installed) — port-scoped kills over test-claimed ports
  only. Reviewer's first check.
- `resolveIsMain()` compares a real path with `process.argv[1]` as given:
  invoking the server through a symlinked path (macOS `/var` →
  `/private/var`) silently runs nothing. Pre-existing, out of scope here;
  tests `pwd -P` their sandboxes. Worth its own one-line fix later.
- `--plugin-dir` dev sessions talk to whatever daemon owns port 7434;
  without `AH_MCP_PORT` a dev checkout is silently testing the installed
  daemon. `--diag` prints `root`, and the doc says to set the port.
- Log growth bounded at ~2 MiB by the cap.

## 11. Confidence

High on phase 1 (pure additive, mirrors 0.50.1's guard pattern). High on
the transport (engram's identical registration works in this
environment daily; the server is already cwd-stateless; the real harness
connected first try). Medium-high on identity: the socket lookup is
proven end to end on darwin, untested on the work machine. Medium on
`--diag`'s http-B row (no real sample, E8). Recommend Ultra-Advisor
**only** on the §4.6 outcome (socket lookup fails on the work machine);
otherwise no escalation.

## 12. r2 — Implementor follow-up edits (exact)

No new files. All in `agent-hierarchy/`.

- **F1** `mcp/server.mjs` `execCli`: add §3.2 trigger (ii) — non-zero
  exit with stderr matching `ERR_MODULE_NOT_FOUND|Cannot find module` →
  `exec-error {script, code:"MODULE_NOT_FOUND", missing}`. Remove the
  "reported defect" comment. `tests/test-mcp-server.sh` §7.1.3 asserts
  the line.
- **F2** `DIAG_RULES`: replace the interim `(cleanly)` rule with §1's
  transport-aware rows; add the fixtures named in §7.1.4 (`http-ok` real,
  `http-fail-start`, `http-down` synthesized + header comment naming
  E8); `docs/troubleshooting.md` table gains the stdio/http split and
  the E3/E5 facts as written in §4.3/§0.
- **F3** `--stop`: append `stop {target_pid}` to the lifecycle log before
  `SIGTERM`; `--diag` reports `stop → signal SIGTERM → exit` as an
  operator stop, bare `signal SIGTERM → exit` as external. Fixture pair
  per §7.1.4.
- **F4** `peerSessionPid`: >1 non-self candidate → log
  `identity-ambiguous {pids, chosen}`, choose the smallest pid. One unit
  case with a stubbed `lsof` output.
- **F5′** (replaces F5; ruling recorded as "Orchestrator r2.1") —
  self-replace ordering per §4.3 as amended: answer the in-flight
  request → `server.close()` (stop accepting; in-flight drain) →
  `spawnDaemon(next)` → poll `GET /health` on the port every 100 ms up
  to 3 s → health answers with `root === next` → log
  `replace {from, to}` → exit 0. No answer in 3 s, or spawn throws →
  log `replace-failed {to, err | "no health in 3s"}` →
  `server.listen(port)` again, `replacing = false`, keep serving the old
  code; `--diag` prints the `replace-failed` remedy (§10). **r2.1: after a
  `replace-failed`, do not attempt a self-replace again for 5 minutes**
  (`REPLACE_RETRY_MS`, an in-memory timestamp on the daemon; `--diag`
  unchanged) — otherwise a permanently broken `next` root costs one doomed
  child per request. Test: a broken `next` root → exactly one spawn
  attempt across N requests inside the window. r2's
  spawn-before-close is a bind race — the child gets `EADDRINUSE` from
  its own parent and exits per the bind-is-lock rule, then the parent
  closes → dead port. Test §7.2.4: (a) happy path = a new pid serving on
  the same port; (b) `next` pointing at a root whose `server.mjs` exits
  immediately → the old daemon still answers `/health` after 4 s, with a
  `replace-failed` line logged.
- **F6** `runHttp` session gate: per-message gating on a batch; any
  ungated non-exempt message → whole request `400`. One test: batch of
  `[initialize, tools/list]` without a session id → `400`.
- **F7** docs: wherever the Implementor wrote the r1 "one
  `/reload-plugins` on first install" sentence (`docs/mcp-tools.md`,
  `docs/troubleshooting.md`), replace with the measured E3 sentence in
  §4.3. Add the §4.3 note that a marketplace rename / cache relocation
  needs a session restart.
- **F8** `replacementRoot()`'s comment: keep; it now matches §4.3
  verbatim, so drop any "interpretation" wording.

Not follow-ups (already correct as shipped): `server/discover` handling
(I2 blessed), sibling-dir self-replace rule (I1 blessed), no `headers`
block (E1), `AGENT_HIERARCHY_DIR` handling at the log path (only the
citation was wrong — fixed in §3.2, no code change).
