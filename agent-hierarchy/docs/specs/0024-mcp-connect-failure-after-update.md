# 0024 — `ah` MCP server shows failed/disconnected after plugin update

Status: diagnosis + small hardening + evidence protocol.
Author: Architect. Spec path was NOT dictated by the dispatch; `0024` follows the
established `docs/specs/NNNN-slug.md` convention (0023 was the highest existing).

## 1. Goal

Explain why `/mcp` reports the `ah` server as failed/disconnected after every
`ah` plugin update on the user's work machine, and say plainly which part is a
repo defect and which part is Claude Code platform behavior.

## 2. Determination — there are TWO symptoms and they must not be conflated

The dispatch and the prior Engram record describe them as one thing. They are
not, and the discriminator is **whether a fresh session fixes it**.

### 2.1 Symptom A — fails right after an update, in the SAME session

**This is documented platform behavior. There is no repo-side fix.**

- Claude Code installs each plugin version into its own cache directory,
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. A version bump
  creates a *new* directory; the old one is marked orphaned and reaped later.
  (`plugins-reference` — "Installation and Caching".)
- `${CLAUDE_PLUGIN_ROOT}` in `plugin.json`'s `mcpServers.ah.args` therefore
  resolves to a **version-specific absolute path**. Every version bump changes
  the server's resolved command line.
- Plugin MCP servers connect at session start. Mid-session, the only thing that
  re-evaluates them is `/reload-plugins`, which keeps live connections whose
  config is unchanged and reconnects those whose config changed.
- **stdio MCP servers do not auto-reconnect on a drop.** Only HTTP/SSE servers
  retry with backoff. (`mcp` docs — "Automatic Reconnection Triggers".)

So: update the plugin mid-session, and the running `ah` server is a process
launched from a path that is now the *old* version. Nothing reconnects it
automatically because it is stdio. `/mcp` shows failed/disconnected. This is
expected, matches the docs exactly, and is fixed by `/reload-plugins` or a
session restart.

**Workaround (§5), not a bug in this repo.** Do not attempt a code fix for this.

### 2.2 Symptom B — fails in THREE CONSECUTIVE FRESH sessions, one machine only

**This is NOT explained by §2.1 and is the real open question.**

A fresh session reads the currently-installed plugin and spawns its current
command. No stale path, no stale approval key, and no stale process can survive
a fresh process start. So the path-versioning story — which is the intuitive
explanation and the one I expected to confirm — **cannot** account for the
recorded symptom of three consecutive fresh sessions failing.

That leaves a genuine startup failure of `mcp/server.mjs` on that machine. Two
candidates, in order of likelihood:

**B1 — `"command": "node"` is bare and PATH-resolved. (Top hypothesis.)**

`plugin.json` declares:

```json
"mcpServers": { "ah": { "command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/server.mjs"] } }
```

`node` is resolved from whatever `PATH` Claude Code hands the spawned child. If
the work machine's node comes from nvm, asdf, volta, or a shell-rc-only Homebrew
prefix, and Claude Code is launched in a context that does not source that rc
(GUI launch, a desktop/IDE-spawned terminal, a login-vs-interactive shell
difference), the spawn fails outright. That produces "failed to connect" on
**every** session, on **that machine only**, while the home machine — where node
is on the default PATH — works fine.

This is the only hypothesis I have that explains all three observed properties
at once: persistent, machine-specific, and total. It is unconfirmed. See §4.

**B2 — unguarded top-level file read in `server.mjs`.**

`mcp/server.mjs:40`:

```js
const PLUGIN_MANIFEST = JSON.parse(readFileSync(join(HERE, "..", ".claude-plugin", "plugin.json"), "utf8"));
```

This runs at module evaluation, before any MCP handshake. If it throws — file
missing, mid-write during an update, JSON truncated, a cache layout where that
relative path does not hold — the process exits non-zero and the client reports
"failed to connect" with no useful message. `PLUGIN_MANIFEST` is used at exactly
one site, `server.mjs:699`, for the cosmetic `serverInfo.version`. **The only
line in the file that can kill startup buys nothing but a version string.** That
is a bad trade regardless of whether it is the current cause, so §3 hardens it
unconditionally.

B2 is a lower-probability cause than B1 but a zero-risk fix.

**B3 — node version too old for the syntax in `server.mjs`.** Same failure
shape as B1 (persistent, machine-specific). Cheap to rule out; folded into §4.

### 2.3 Ruled out: plugin.json / marketplace.json mismatch

Verified this session. `agent-hierarchy/.claude-plugin/plugin.json` and the `ah`
entry in the repo-root `.claude-plugin/marketplace.json` are both at `0.50.0`
and carry **byte-identical** `mcpServers` blocks. This is not the cause.

Note for the record: Engram holds one fact (`f41947`) claiming the marketplace
mirror is unnecessary and three (`f42128`, `f42241`, `f42054`) claiming it is
empirically required, the latter backed by `claude plugin details` showing
"MCP servers (0)" → "(1)". The current both-places state is the safe superset.
**Do not remove either block** on the strength of the dissenting fact.

## 3. Repo-side change — harden the one startup crash path

Small, unconditional, independent of which hypothesis §4 confirms.

**File:** `agent-hierarchy/mcp/server.mjs`

Replace line 40 with a guarded read. Exact shape:

```js
let PLUGIN_MANIFEST;
try {
  PLUGIN_MANIFEST = JSON.parse(readFileSync(join(HERE, "..", ".claude-plugin", "plugin.json"), "utf8"));
} catch {
  PLUGIN_MANIFEST = { version: "unknown" };
}
```

Requirements:
- The `serverInfo` site at `server.mjs:699` is otherwise **unchanged** — it keeps
  reading `PLUGIN_MANIFEST.version`.
- Do NOT inline the version literal. That would create a third place to bump
  alongside `plugin.json` and `marketplace.json`, and the standing repo rule
  already requires two.
- Do NOT log to stdout in the catch. stdout is the MCP stdio transport; writing
  anything non-protocol there corrupts the session. stderr is acceptable but not
  required — prefer silence.

**Verification:** the server still starts and `serverInfo.version` still reports
`0.50.0` on a normal machine. There is no test to add; the existing MCP tests
exercise startup already.

## 4. NEEDS-EVIDENCE — the actual deliverable

Prior investigation burned three sessions and found nothing because none of this
was captured. Run these **on the work machine**, in the failing state.

**E1 — is it B1 (PATH)? This is the decisive one. Run it first.**

From a terminal launched **the same way the user launches Claude Code** on that
machine (not a hand-opened login shell — that is the whole point):

```
which node; node --version; echo "$PATH"
```

- `which node` empty or a path that does not exist → **B1 confirmed.** The fix
  is environment-side (make node resolvable in Claude Code's launch context), or
  repo-side by pinning an absolute interpreter — but **do not pin a path in
  `plugin.json` without a further design pass**, since a hardcoded absolute node
  path is not portable across the user's other machines. Re-dispatch me.
- node present and modern → B1 falsified, go to E2.

**E2 — capture the verbatim error.** Currently nobody has ever recorded what
`/mcp` actually says. Capture, verbatim:
- the `ah` row's full status/error text in `/mcp`;
- the `/plugin` manager's **Errors** tab contents;
- output of `claude --debug` on a fresh session start, filtered to lines
  mentioning `ah`, `mcp`, or `server.mjs`.

**E3 — run the server by hand.** From the installed cache dir on that machine:

```
node ~/.claude/plugins/cache/<marketplace>/ah/0.50.0/mcp/server.mjs < /dev/null; echo "exit=$?"
```

A non-zero exit with a stack trace names the cause outright. A hang (no exit) is
the *correct* behavior for a stdio server and means startup is fine — which
would falsify both B1 and B2 and point back at the client side.

**E4 — confirm the installed path exists.** `ls ~/.claude/plugins/cache/*/ah/` —
if the version directory named by the current install is absent or empty, the
update itself did not land, which is a different bug from all of the above.

**E5 — settle the §2.1 / §2.2 split.** The single most valuable observation and
the cheapest: after the next update fails, **start a completely fresh session and
look at `/mcp` before doing anything else.**
- Fresh session is healthy → it is Symptom A only, platform behavior, close this
  spec with the §5 workaround and ship only §3.
- Fresh session still failed → Symptom B is real, and E1–E3 identify it.

## 5. Workaround (correct for Symptom A, harmless either way)

After any `ah` plugin update, run `/reload-plugins` — the documented mechanism
that reconnects plugin MCP servers whose config changed. If that does not clear
it, restart the session. There is no settings key that makes stdio plugin MCP
servers auto-reconnect; GitHub issues #36308 and #54136 are open feature
requests for exactly that, so this is a known platform gap, not a local
misconfiguration.

## 6. What must NOT change

- Both `mcpServers` blocks stay, in both files, in sync (§2.3).
- No stdout writes from `server.mjs` outside the MCP protocol.
- No version literal inlined into `server.mjs`.
- No change to `serverInfo` beyond tolerating a missing manifest.
- No absolute interpreter path committed to `plugin.json` without a further
  design pass (see E1).

## 7. Confidence and limits

- §2.1 is **documented fact** and I am confident in it.
- §2.2's B1 is my **best hypothesis and it is unverified.** I am explicitly not
  prescribing a fix for it; E1 decides.
- I could not determine — and the docs do not state — what key Claude Code uses
  to store plugin MCP approval state (server name vs. resolved command path). If
  it is path-keyed, that would strengthen a stale-approval story for Symptom A,
  but it still cannot explain a fresh-session failure, so it does not change any
  conclusion here.
- No Ultra-Advisor escalation needed. §3 is three lines behind an existing seam;
  everything else is diagnosis.
