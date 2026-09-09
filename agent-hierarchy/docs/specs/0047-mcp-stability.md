# 0047 — A stable `ah` MCP server: diagnose first, then move the transport to a local HTTP daemon

Status: **r1, design.** Brief `20260909-162045-y0fj`. Ships as
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
  (42 h, v0.66.0), was SIGINT'd by the harness, and **four** new servers
  were spawned 13 s later within 80 ms for the same `sessionId`
  (`…-917Z`, `-922Z`, `-968Z`, `-997Z`), one connecting at 0.70.0 in 291 ms.
  So the reload path *works* here; what fails is unmeasured.
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

| shape | harness jsonl (`mcp-logs-plugin-ah-ah/`) | server lifecycle log (new, §3.2) | likely cause |
|---|---|---|---|
| **A — fails at start** | file has `Starting connection` and **no** `Successfully connected`; an error/timeout line; `/mcp` shows failed from the first prompt | no `start` line at all (never ran) **or** `start` then `exit` before `initialize` | 0024 B1 `command:"node"` PATH-resolved on that machine; B2 throw before handshake (guarded since 0.50.1); node too old |
| **B — dies mid-session** | `Successfully connected`, tool calls, then a transport-closed / exited line **without** a preceding `Sending SIGINT` | `start` … `uncaught` / `signal` / `stdin-end` / `exit` with a reason and a stack | a handler throw; stdin EOF; external kill (pane close, OOM) |
| **C — post-update / reload drop** | `Sending SIGINT` + `exited cleanly`, then new file(s) `Starting connection` within seconds — reconnect either succeeds (nothing to fix) or fails (→ shape A on the new version) | `exit {signal:SIGINT}` then a new `start` with the new `version` | documented: config path changed → harness drops the server; `/reload-plugins` required |
| **C′ — files moved under a running server** | connected fine; later **every** tool call fails with `spawn … ENOENT` on `hooks/*.mjs` | `execCli` error lines naming the missing path | the old version dir removed after an update while the old server still runs |

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

One append-only file, **`~/.claude/hierarchy/mcp-server.log`** (the
plugin's existing global dir, `lib-config.mjs:366`; honour
`AGENT_HIERARCHY_DIR` the same way the hooks do), one JSON object per line,
written with the same append primitive the hooks use for `peers.jsonl`.
Events, each with `ts`, `pid`, `transport` (`stdio`|`http`), `version`:

- `start` — plus `ppid`, `session_pid` (stdio: the 0018 value), `node`
  (`process.version`), `exec` (`process.execPath`), `root` (the plugin
  dir the server is running from), `cwd`, `argv`.
- `stdin-end` (stdio: the harness closed the pipe), `signal` (`SIGINT`,
  `SIGTERM`, `SIGHUP` — logged, then default behaviour), `uncaught` /
  `unhandled` (message + stack, then exit 1 — a hung server is worse than
  a dead one), `exit` (`code`).
- `exec-error` — `execCli`'s `child.on("error")` (`:447`): the script
  path and `err.code` (this is how shape C′ becomes visible).
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
its start time, the shape from §1's table (`ok` when connected and
SIGINT'd or still running), version served, transport, tool-call count,
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
touching the installed one. With §4.4's header variant the block also
carries `"headers": {"X-Ah-Session-Pid": "${CLAUDE_PID}"}` — only if E1
confirms the expansion.

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
- `GET /` → `405` (no server-initiated stream). `DELETE /` with a session
  id → `200`, session dropped.
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
  exits 0 — no pidfile. Ordering vs the harness's connect is E3; the
  harness's 3 startup retries and 30 s timeout cover a hook that runs a
  few hundred ms after the connect attempt; if E3 says connect can *win*
  by seconds, the mitigation is documenting one `/reload-plugins` on the
  very first session after install — no worse than today.
- **Self-replacement on update:** on each request (cheap: one `stat`),
  compare `installed_plugins.json`'s current `ah@*` `installPath` against
  the daemon's `root`. On mismatch: answer the in-flight request, stop
  accepting, close the listener, spawn the replacement from the new
  `installPath` exactly as the hook would, log `replace {from, to}`, exit
  0. The harness sees a connection drop and retries (1 s first) — the
  replacement is listening well inside that. A daemon started from a
  root that is **not** in `installed_plugins.json` (a `--plugin-dir`
  checkout) never self-replaces. Whether the harness refreshes
  `tools/list` on reconnect is E4 — if not, renamed tools still need a
  session restart (no worse than today), and the doc says so.
- **Stop:** `node mcp/server.mjs --stop` — `GET /health` → `pid` →
  `SIGTERM`; the daemon's `SIGTERM` handler closes the listener and exits
  0. Also reachable as `roster.mjs`? No — the daemon is not a roster
  concern; one flag on the server is the whole CLI.
- **Logs:** daemon stdout/stderr are the §3.2 file (`start` line carries
  `transport:"http"`, `port`).
- **Reboot:** nothing persists; the next session's hook starts it.

### 4.4 Identity (spec 0018 under a shared daemon)

The daemon has no session parent; `process.ppid` is meaningless. The
value seven tools pass as `--orchestrator-pid` must come from the
connection:

1. **Header, if E1 confirms** `${CLAUDE_PID}` expands in the manifest's
   `headers`: the harness sends `X-Ah-Session-Pid` on every request; the
   daemon reads it at `initialize`, binds it to the `Mcp-Session-Id`, and
   uses it as that session's `SESSION_PID`. Zero code beyond a header read.
2. **Fallback — socket peer lookup:** at `initialize`, resolve the
   client's ephemeral port (`req.socket.remotePort`) to its owning pid —
   darwin `lsof -nP -iTCP:<port> -sTCP:ESTABLISHED -Fp`, Linux
   `ss -tnpH 'sport = :<port>'` — once per MCP session, cached on the
   session; failure → `session_pid: null` (today's behaviour when
   reparented). Ugly, ~20 lines, needs no harness cooperation.
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

If E1 fails **and** the peer-socket lookup proves unreliable on the work
machine (E1b), identity degrades to `orchestrator_pid`-or-null for the
seven tools — `team_create`/`adopt`/`spawn_*` would record a null
orchestrator and `team_reap` would see every team as orphaned. That is
the one outcome that should send this back to the Architect (or the
Ultra-Advisor: it is a public-interface question — should those tools
*require* `orchestrator_pid` under HTTP?). Everything else in §4 is
additive or behind the transport flag.

## 5. Skills / agents text

No change to `agents/*.md` or `skills/agent-team|agent-roster/SKILL.md`
"try MCP first, fall back to CLI, say so once" — still correct and
transport-independent. Only the docs in §3.5 and §4.5 change.

## 6. NEEDS-EVIDENCE (Implementor runs; results decide as stated)

- **E1** — does `"headers": {"X-Ah-Session-Pid": "${CLAUDE_PID}"}` in the
  plugin manifest reach the daemon with the harness's pid? Probe: a
  `--plugin-dir` plugin whose http server logs request headers. Yes →
  §4.4 method 1; no / empty → method 2 (**E1b**: `lsof` variant returns
  the harness pid on darwin; run once on the work machine too).
- **E2** — the harness accepts a plain `application/json` POST response
  and a server-issued `Mcp-Session-Id` (the engram daemon already does
  both and works here — expected yes; confirm with the same probe).
- **E3** — SessionStart hook vs MCP connect ordering on a cold machine
  (daemon not running): lifecycle `start` ts vs harness jsonl `Starting
  connection` ts. Connect first by > 30 s → document one reload on first
  install; otherwise nothing.
- **E4** — after the daemon self-replaces with a version whose
  `tools/list` differs, does the reconnected session see the new list?
  Decides the §4.3 doc sentence only.
- **E5** — phase-1 `--diag` output from the user's next real
  disconnect, both machines: which of A/B/C/C′. Decides nothing in this
  spec (phase 2 covers all four) but is the evidence the user asked for
  and closes 0024's open question.
- **E6** — the four simultaneous spawns per session seen 2026-09-09
  18:43:01: are four server processes alive concurrently (`pgrep -fl
  mcp/server.mjs` in a fresh session)? Harmless on stdio; under HTTP they
  are four sessions on one daemon. Record only.
- **E7** — Linux harness log dir for `--diag` (`~/.cache/claude-cli-nodejs/`
  assumed).

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
   result **and** an `exec-error` line naming the path.
4. `--diag` on `tests/fixtures/mcp-logs/{ok,fail-start,mid-session,
   reload}.jsonl` (hand-written from the real entry shapes in §0) →
   exactly one classification per file, matching the fixture name;
   missing dir → "no harness logs for <cwd>", exit 0.
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
3. Identity: (header variant) a request carrying `X-Ah-Session-Pid:
   <shell pid>` → `team_create` `dry_run` reports that pid as
   orchestrator; (socket variant) the same without the header → the
   test's own pid. Whichever E1 selects is asserted; the other is skipped
   with a printed reason, not silently.
4. Self-replacement: `HOME`-redirected `installed_plugins.json` pointing
   `installPath` at copy A of the checkout; start the daemon from A; edit
   the JSON to copy B (plugin.json version bumped in B); one request →
   within 2 s `/health` on the **same port** reports B's version and a
   new pid; the log has `replace`. A daemon started from a root absent
   from the JSON never replaces.
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
- First session on a cold machine may connect before the hook starts the
  daemon (E3) — bounded by the harness's retries; at worst one reload on
  first install, which is today's baseline.
- Old version dir removed while the daemon runs old code (C′): the
  self-replace check runs on every request, so the window is one
  request; `exec-error` logging makes it visible if it ever bites.
- `--plugin-dir` dev sessions talk to whatever daemon owns port 7434;
  without `AH_MCP_PORT` a dev checkout is silently testing the installed
  daemon. `--diag` prints `root`, and the doc says to set the port.
- Log growth bounded at ~2 MiB by the cap.

## 11. Confidence

High on phase 1 (pure additive, mirrors 0.50.1's guard pattern). High on
the transport (engram's identical registration works in this
environment daily; the server is already cwd-stateless). Medium on
identity until E1/E1b — the fallback is known to work in principle but
is untested on the work machine. Recommend Ultra-Advisor **only** on the
§4.6 outcome (both identity mechanisms fail); otherwise no escalation.
