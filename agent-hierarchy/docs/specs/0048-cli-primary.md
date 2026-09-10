# 0048 — CLI-primary: drop the `ah` MCP server

Status: r1 · target 0.73.0 · supersedes 0047 (all of it; see §4)
Author: Architect · Request `20260909-211952-1hag`

## 0. Goal and anti-goals

User ruling after 0.72.0: the HTTP daemon is started only by SessionStart, `/reload-plugins`
fires no SessionStart, so the exact in-session-update case 0047 targeted produced
`ConnectionRefused`. Ruling: **every ah operation is a Bash call to the two CLIs that the
MCP tools already wrapped** (`hooks/roster.mjs`, `hooks/msg.mjs`). The MCP server, its
daemon, its ensure hook, its diagnostics and its tests are removed.

Anti-goal: any second transport that can be "down". Nothing in this spec starts, keeps
alive, or reconnects a process. A CLI call either runs or prints node's own error.

0047 rejected CLI-primary for three reasons; each is solved here, not waved:

| 0047 objection | Resolution | § |
|---|---|---|
| Bash permission prompt per call | plugin-shipped PreToolUse `allow` hook scoped to its own two scripts; settings allowlist documented as the opt-out | 2.2 |
| gates key on MCP tool names | both gates re-keyed on the parsed Bash command through one shared parser; same semantics, tests re-keyed | 2.4 |
| no schema | `docs/cli-tools.md` verb table (25 rows) + `--help` on both scripts; roster output is already always JSON | 2.6 |

## 1. Facts this design rests on (retrieved, not assumed)

- `mcp/server.mjs` registers 25 tools (5 `msg_*`, 8 roster/teams, 12 `team_*`); every one is
  `execCli(script, argv)` over `hooks/msg.mjs` or `hooks/roster.mjs` (server.mjs:582-614,
  643-958). No tool has logic of its own beyond argv assembly and, for `team_layout_splits`,
  tolerating exit 3 (server.mjs:829).
- `roster.mjs` resolves the session pid as `--orchestrator-pid` → `process.env.CLAUDE_PID`
  (roster.mjs:1109-1111, 2417, 3019); `checkin` adds a last-resort `process.ppid`
  (3087-3089); `adopt` requires the flag (2999-3000). Comment at 2410-2415 states the CLI was
  designed for Bash-tool invocation and that `CLAUDE_PID` is exported by every claude session.
  `msg.mjs` uses `process.env.CLAUDE_PID` for team-scope resolution (msg.mjs:105-119).
- All `roster.mjs` output is JSON (`out()` roster.mjs:146-147); `--json`/`--plain` are parsed
  and ignored (roster.mjs:99).
- `disband --close`/`dismiss --close` are already self-protecting in the CLI: `--confirm` +
  `--plan-token` must match a hash of the current close set (roster.mjs:1469-1472,
  1693-1700, 2657-2670). The token is stateless.
- Gates today: `pretooluse-disband-close-gate.mjs` matches four MCP tool names, returns
  `permissionDecision:"ask"` always, enriches the prompt from `tool_input.{mode,name,cwd,team}`
  (lines 30-35, 43, 55-66). `pretooluse-roster-skill-gate.mjs` matches 12 `team_*` names,
  returns `deny` once per session recorded in `hierarchyDir/gates.jsonl` (lines 33-46, 66-69).
  `pretooluse-msg-gate.mjs`, `pretooluse-sendmessage-response.mjs`,
  `subagentstop-msg-nudge.mjs` key on Agent/Task/SendMessage and the `[hierarchy-msg …]`
  pointer — **not** on MCP tool names. (v) of the brief confirmed: no change to them.
- `hooks/hooks.json`: two PreToolUse entries carry MCP matchers (disband-close gate,
  roster-skill gate); one SessionStart entry runs `sessionstart-mcp-ensure.mjs`.
- `sessionstart.mjs` computes the plugin root from `CLAUDE_PLUGIN_ROOT` with an
  `import.meta.url` fallback (lines 41, 50-51) and already injects a `--agent` role notice that
  spells the absolute `node "<root>/hooks/msg.mjs" new …` command; `stop-peer-nudge.mjs`
  prints the same absolute form. Hooks therefore already know and publish the CLI path.
- Claude Code docs (code.claude.com/docs/en/permissions, /hooks): Bash allow rules accept `*`
  anywhere, matching any text including spaces and `/`; compound commands are split on
  `&& || ; | |& &` and newline and each segment matched separately; allow rules do not match
  past an assignment of an unknown env var. PreToolUse `permissionDecision:"allow"` skips the
  prompt; `updatedInput` may accompany it; settings deny > settings ask > hook allow.
  **Not documented**: hook-vs-hook precedence when one returns `allow` and another `ask`;
  whether `${CLAUDE_PLUGIN_ROOT}` expands inside `agents/*.md`; whether plugins can ship
  permission rules (they cannot, per docs silence + memory); the Bash tool's env vars.
- Engram f27263: inside a hook `process.ppid === CLAUDE_PID`; one level deeper (a CLI under
  the Bash tool) `process.ppid` is the shell. Engram f19540: hook `allow` short-circuits the
  permission system.

## 2. Mechanism

### 2.1 Invocation form and path discovery

Canonical form, the only one the allow hook (§2.2) and the gates (§2.4) recognise:

```
node <AH_ROOT>/hooks/roster.mjs <verb> [args…] --cwd <absolute cwd>
node <AH_ROOT>/hooks/msg.mjs   <verb> [args…] --cwd <absolute cwd>
```

- `<AH_ROOT>` is an absolute path (bare, or single/double quoted as a whole). No `cd … &&`
  prefix, no env-var assignment prefix, no `$VAR` anywhere (see §2.2 grammar) — `--cwd` and
  `--orchestrator-pid` exist precisely so nothing needs shell expansion.
- `--cwd` stays mandatory in the documented form for every verb (it already is in the CLI
  usage; the MCP `cwd` input becomes it). Roles pass the literal absolute cwd they were given.
- **Who tells a role the path.** Hooks own it (they have `CLAUDE_PLUGIN_ROOT`). Requirements:
  1. `sessionstart.mjs` emits, for every session it injects anything into (enabled sessions
     and `--agent` role sessions) and on every matcher it already handles
     (`startup|resume|clear|compact|fork`), one line naming the root:
     `ah CLI root: <AH_ROOT> — roster: node <AH_ROOT>/hooks/roster.mjs …, messages: node <AH_ROOT>/hooks/msg.mjs … (verbs: docs/cli-tools.md)`.
     Exact wording is the Implementor's; it must contain the absolute root once and both
     script paths once.
  2. Every hook text that today names an `mcp__…` tool as the remedy (deny reasons, Stop/
     SubagentStop nudges, skill-gate deny reason) names the full `node <AH_ROOT>/hooks/…`
     command instead. This is how subagents learn the path — `sessionstart.mjs` gives
     subagents nothing (line 83) and that stays.
  3. `agents/*.md` (all six) replace the "Always try `mcp__ah__*` first …" paragraph with:
     the ah CLI is the only interface; the root is on the session's `ah CLI root:` line (or
     in the hook message that sent you here); verb reference `docs/cli-tools.md`; never guess
     a path — if no root line is in context, ask the Orchestrator for it. The "fall back to
     the CLI" sentence goes away (there is nothing to fall back from).
- Post-update inside a session: the context still holds the old `<AH_ROOT>`. Old and new
  version dirs coexist under the plugin cache (memory: "multiple versions coexist"), so the old
  CLI keeps running until the next session. That is the stdio-era C shape reduced to
  "stale code, still works" — accepted; documented in troubleshooting. If the old dir is gone,
  node prints `Cannot find module` and the role reads it; `/reload-plugins` + the new root line
  from a fresh session is the remedy. No machinery.

### 2.2 Permission: plugin-shipped allow hook (i)

New hook `hooks/pretooluse-ah-cli.mjs`, `hooks.json` PreToolUse matcher `Bash`. Contract:

- Input: the PreToolUse payload for Bash. Parse `tool_input.command` with the shared parser
  (§2.4.1). Not an ah CLI invocation → exit 0, no output (no `permissionDecision` key at all,
  per f19540).
- Recognised **and** not a close command (§2.4.2) → output
  `hookSpecificOutput.permissionDecision: "allow"` with a one-line reason naming script+verb.
- Recognised close command (`roster.mjs dismiss|disband … --close`) → **no output**. The
  close gate's `ask` must stand alone; this avoids the undocumented hook-vs-hook `allow`+`ask`
  precedence entirely rather than depending on it.
- Path rule: the script token's realpath must be `<R>/hooks/roster.mjs` or `<R>/hooks/msg.mjs`
  where `<R>` is the hook's own plugin root **or any sibling directory of it**
  (`dirname(ownRoot)/<x>`). Sibling rule = 0047's self-replace rule reused: after an in-session
  bump the hook may run from the new version dir while the role's context holds the previous
  one; both live under the same parent. Anything else (a copy in `/tmp`, a user checkout when
  the installed root is the cache, `~/foo/roster.mjs`) → no output → normal prompt. Local-
  checkout marketplaces (this repo) make siblings = other plugin dirs; only a sibling that
  itself contains `hooks/roster.mjs` could match — accepted, noted in the hook's header comment.
- Command grammar (the parser's acceptance set; the allow hook allows nothing outside it):
  - exactly one simple command: the string contains none of `; & | < > ( ) \` $ \n` outside
    single quotes, and no `\` outside quotes;
  - first token is `node` (bare); the harness's PATH node is the executor — the hook does not
    care which node;
  - second token is the script path, bare or wholly quoted;
  - remaining tokens: bare words (`[^\s'"`$\\;&|<>()]+`), single-quoted strings (no `'`
    inside), or double-quoted strings containing no `$`, backtick or `\`. JSON arguments
    (`--args`, `--verified`, `--created`) therefore travel single-quoted.
  - `--cwd` present with an absolute value is **not** required by the hook (the CLI errors
    usefully without it); it is required by the docs.
- The hook never rewrites the command (no `updatedInput`) unless N1 fails — see §2.3.
- Settings-allowlist alternative (documented in `docs/cli-tools.md` for users who disable the
  hook or run without plugins hooks): user-level `~/.claude/settings.json`
  `permissions.allow`: `Bash(node */hooks/roster.mjs *)` and `Bash(node */hooks/msg.mjs *)`.
  User scope, not project: the path lives under `~/.claude/plugins/cache` and the rule must
  survive version bumps, which the mid-pattern `*` gives per the docs. Shape confirmed legal by
  docs; matching in practice is N5. The two entries must be spelled exactly this way in the doc
  — the docs say a rule's leading `node ` with the space is what keeps `nodejs-foo` from
  matching.
- Security posture (stated in the hook header and `docs/cli-tools.md`): the hook grants
  prompt-free execution of two scripts the plugin itself ships, with arguments restricted to the
  grammar above; the only destructive verbs (`--close`) are excluded and remain behind the
  always-ask gate; `untrack --commit`, `reap --commit`, `create --commit`, `remove` are
  bookkeeping on ah's own state files, previously auto-allowed as MCP calls too.

### 2.3 Identity (iv)

Decision: **no new mechanism**; the CLI's existing `--orchestrator-pid` → `CLAUDE_PID`
resolution (§1) is the 0018 identity under Bash. The MCP server's `sessionPid` (its own
`process.ppid`) is replaced by `CLAUDE_PID` in the Bash tool's environment, which the same
claude process exports. Subagents run in the orchestrator's process → same pid, same as the
stdio-era server; peers export their own.

Consequences to implement:
- `msg.mjs` gains `--orchestrator-pid <pid>` as the first choice in its team-scope resolution
  (before `CLAUDE_PID`), mirroring roster.mjs, so tests and a human shell can pin it.
- Documented form omits `--orchestrator-pid`; it stays available for tests/humans/adopt.
- `adopt` keeps requiring it (it is a deliberate re-stamp).
- The MCP-era `orchestrator_pid` override input on `team_list`/`team_create`/`team_spawn_*`/
  `team_adopt` is just the flag.

**N1 decides this** (§8). Contingency if `CLAUDE_PID` is absent or wrong in the Bash env:
the allow hook stamps `--orchestrator-pid <its own process.ppid>` via `updatedInput` on every
recognised command that lacks the flag (f27263: the hook's ppid is the session). That is a
~10-line addition to the hook and its test, not a redesign; do not build it unless N1 fails.

### 2.4 Gates re-keyed (ii)

#### 2.4.1 One shared parser

One module under `hooks/` (name is the Implementor's) exporting a pure function
`command string → null | { script: "roster"|"msg", scriptPath, verb, positional[], flags{} }`
per the grammar in §2.2, plus the path-rule check as a separate pure function taking the
hook's root. Used by the allow hook, the close gate, and the skill gate — three consumers,
one grammar, one test file for the grammar. Flags: `--k v` and bare `--k` per the CLIs' own
`BOOL_FLAGS` (roster.mjs:99, msg.mjs:55) — the parser must not need to know verb-specific
flag sets; it only needs to distinguish bool flags from valued ones, and the bool sets are the
CLIs' own lists (import them or copy them with a test that asserts equality).

#### 2.4.2 Close gate (`pretooluse-disband-close-gate.mjs`)

- `hooks.json` matcher → `Bash`.
- Fires iff parsed `script === "roster"`, `verb ∈ {dismiss, disband}`, and `flags.close`.
  Plan calls (no `--close`) are not gated — same as today's `mode !== "close"` pass-through.
- Semantics unchanged: **always `ask`**, never cached, never one-shot. Enrichment inputs move
  from `tool_input.{name,team,cwd}` to `positional[0]` (dismiss name), `flags.team`,
  `flags.cwd`; on parse failure of the enrichment (as today, line 80) the deny text stands.
- MCP tool names removed from the matcher and the script.

#### 2.4.3 Skill gate (`pretooluse-roster-skill-gate.mjs`)

- `hooks.json` matcher → `Bash`.
- Fires iff `script === "roster"` and
  `verb ∈ {create, spawn-one, spawn-ad-hoc, adopt, move, dismiss, disband, untrack}` — the
  same eight the 12-name MCP matcher covered (the four extra names were the `mcp__ah__`
  aliases).
- Semantics unchanged: one `deny` per session recorded as `type:"roster-skill-gate"` in
  `gates.jsonl`; identical retry passes. `cwd`/`team` for the record come from `flags`.
- DENY_REASON text: replace the MCP-tool wording with the CLI wording; must still name the
  skill to load and say "re-run the same command".

#### 2.4.4 Ordering with the allow hook

Close command: allow hook silent, close gate asks → prompt. Skill-gated first call: allow hook
allows, skill gate denies → deny wins (documented precedence). Retry: allow hook allows, skill
gate silent → runs. Any other recognised command: allow hook allows → runs. Unrecognised
command → no ah hook speaks → the user's normal permission flow.

#### 2.4.5 `tests/check-gate-name-agreement.mjs`

It verifies hook matchers against gate names; it must be updated so that a `Bash` matcher
paired with the parser's verb set is what "agreement" means, and it must fail if either gate's
verb set drifts from the list in §2.4.2/§2.4.3.

### 2.5 `roster_show` instruction (iii)

The server's `instructions` string (server.mjs:991-995) dies with the server. Its content
moves, verbatim in meaning, to: `agents/orchestrator.md` (orchestration protocol section),
`skills/agent-roster/SKILL.md`, `skills/agent-team/SKILL.md`:
"To inspect the roster run `node <AH_ROOT>/hooks/roster.mjs show --cwd <abs cwd>`; never read
`.claude/agent-hierarchy.json` directly — it misses worktree/main-checkout and global fallback
resolution that `show` implements." `skills/autonomous-pipeline/SKILL.md` gets the same line
only if it currently references `roster_show` (grep says 2 `mcp-tools` hits in skills/; check).

### 2.6 Verb reference (`docs/cli-tools.md`) — what each role types

`docs/mcp-tools.md` is deleted; `docs/cli-tools.md` replaces it with this table (the
Implementor fills flag lists from the CLI usage blocks, roster.mjs:9-57, msg.mjs:5-15; the
MCP input → flag mapping is server.mjs:643-958 and is one-to-one: `snake_case` input →
`--kebab-case` flag, `mode: plan|close|commit|spawn` → the bare flag, `cwd` → `--cwd`).
`<R>` = `<AH_ROOT>`. `--cwd <abs>` on every line, elided here.

| was (MCP) | now (Bash) |
|---|---|
| `msg_new` | `node <R>/hooks/msg.mjs new --to <role> --from <role> --slug <s> [--to-name --from-name --parent --reason --eta --type --id --team] [--req <abs request path>]` |
| `msg_list` | `node <R>/hooks/msg.mjs list [--open|--closed|--all] [--to <role>] [--team <t>]` |
| `msg_downstream` | `node <R>/hooks/msg.mjs downstream [--root-name <n>]` |
| `msg_index` | `node <R>/hooks/msg.mjs index <abs path>` |
| `msg_roster` | `node <R>/hooks/msg.mjs roster [--team <t>]` |
| `roster_show` | `node <R>/hooks/roster.mjs show [global|repo|repo-user] [--team <t>]` |
| `team_list` | `node <R>/hooks/roster.mjs teams` |
| `roster_init` | `node <R>/hooks/roster.mjs init [level] --route peer|subagent|pane [--layout <m>]` |
| `roster_add` | `node <R>/hooks/roster.mjs add [level] --role <R> [--model --effort --route --kind --args '<json>' --auto-mode --on-missing]` |
| `roster_edit` | `node <R>/hooks/roster.mjs edit [level] --member <name> [same optional flags as add]` |
| `roster_remove` | `node <R>/hooks/roster.mjs remove [level] --member <name>` |
| `roster_layout` | `node <R>/hooks/roster.mjs layout [level] [--layout auto|columns|grid]` |
| `roster_alias` | `node <R>/hooks/roster.mjs alias [--level L] [--set <name>] [--clear] [--team <t>]` |
| `team_create` | `node <R>/hooks/roster.mjs create --plan` / `--spawn [--layout-mode …]` / `--commit --verified '<json>' --transport <t> --roster-level <L> [--partial] [--orchestrator-session-id <id>]` |
| `team_adopt` | `node <R>/hooks/roster.mjs adopt --orchestrator-pid <pid> [--team <t>]` |
| `team_reap` | `node <R>/hooks/roster.mjs reap [--commit]` |
| `team_layout_splits` | `node <R>/hooks/roster.mjs layout-splits [--mode --pane-count --next --created '<json>' --apply --target --direction]` — exit 3 = partial, read the JSON |
| `team_disband` | plan: `node <R>/hooks/roster.mjs disband [--team <t>]` · close: `… disband --close --confirm --plan-token <tok> [--allow-global] [--team <t>]` |
| `team_resync` | `node <R>/hooks/roster.mjs resync [--dry-run] [--team <t>] [--bind <b>]` |
| `team_move` | `node <R>/hooks/roster.mjs move <name> --tab <t> [--split right|down] | --new-tab [--workspace <w>] | --new-workspace [--dry-run --allow-global --team <t>]` |
| `team_history` | `node <R>/hooks/roster.mjs history` |
| `team_spawn_one` | `node <R>/hooks/roster.mjs spawn-one <role> [--member <name>] [--dry-run --allow-global --team <t>]` |
| `team_spawn_ad_hoc` | `node <R>/hooks/roster.mjs spawn-ad-hoc --role <role> [--model --effort --kind --route --args '[…]' --auto-mode --on-missing --dry-run --allow-global --team <t>]` |
| `team_dismiss` | plan: `node <R>/hooks/roster.mjs dismiss <name> [--team <t>]` · close: `… dismiss <name> --close --confirm --plan-token <tok> [--also-config --level L --allow-global --team <t>]` |
| `team_untrack` | `node <R>/hooks/roster.mjs untrack <name>|--all [--plan|--commit] [--keep-sessions --also-config --level L --team <t>]` |

Verify against the usage blocks: `team_create --spawn`'s layout flag spelling and
`spawn-ad-hoc`'s role position (positional in roster.mjs:45 usage, `--role` in server.mjs:888-
907) — the CLI usage wins; the table must show what the CLI actually parses. Any MCP input that
has no CLI flag (none found; `orchestrator_pid` = the flag) is a gap to report, not invent.

The doc also carries: the invocation form (§2.1), the allow-hook posture and the settings
allowlist (§2.2), "output is always JSON; exit ≠ 0 = the JSON/stderr says why; exit 3 =
partial (layout-splits, create)", the roster_show sentence (§2.5), the post-update note
(§2.1), and `--help`: both scripts must print their usage block and exit 0 on `--help` or on
no verb (roster.mjs already has the block; confirm the exit code; msg.mjs likewise).

## 3. Removal list (exact)

Delete:
- `mcp/server.mjs` (whole `mcp/` dir).
- `hooks/sessionstart-mcp-ensure.mjs` and its `hooks.json` SessionStart entry.
- `tests/test-mcp-http.sh`, `tests/test-mcp-server.sh`, `tests/fixtures/mcp-logs/` (10 files).
- `tests/test-mcp-cli-fallback.sh` → replaced by §6 T6 (same intent, new source of truth).
- `docs/mcp-tools.md` → `docs/cli-tools.md` (§2.6). Every link to `mcp-tools.md` (README:387,
  415; getting-started:350, 388; skills ×2; agents ×6; hooks ×1; tests ×4) repointed.
- `mcpServers` block from `agent-hierarchy/.claude-plugin/plugin.json` **and**
  `/.claude-plugin/marketplace.json` (both — memory: version bump in two places, same rule for
  this block).
- The lifecycle log (`~/.claude/hierarchy/mcp-server.log`), `--diag`, `--stop`, `--http`,
  `DIAG_RULES`, `classifyHarnessLog`, `peerSessionPid`, `installedAhRoot`, `replacementRoot`,
  `spawnDaemon`, `runHttp`, `AH_MCP_PORT` — all in `mcp/server.mjs`, gone with it. Any hook
  that appends to the lifecycle log (grep hit `hooks/ ×1` for `mcp-server.log`) loses that
  code path.
- `docs/troubleshooting.md` "## The `ah` server is disconnected" section and every
  `--diag`/`server.mjs`/`AH_MCP` line (docs: 14 + 62 + 3 hits outside specs) → replaced by
  §5's CLI troubleshooting entries.
- README "## Layout" `mcp/` line.
- Test files that reference `server.mjs` only for its callTool path
  (`test-msg-downstream.sh`, `test-msg-reply-beside-request.sh`, `test-roster-add-spawn.sh`,
  `test-roster-surface-split.sh`): delete the server-side cases, keep the CLI cases. Tests that
  assert MCP tool names (`test-disband-close-gate.sh`, `test-roster-skill-gate.sh`,
  `test-orchestrator-identity.sh`): re-key per §6.

Do **not** touch: `docs/specs/*` history (add one line at the top of 0047: "Superseded by
0048 — MCP server removed in 0.73.0"), `CONTEXT.md` (no MCP content), `hooks/msg.mjs`
beyond §2.3, roster.mjs beyond `--help` exit code if needed.

## 4. Disposition of 0047

Superseded entirely. Phase 1 (lifecycle log, `--diag`, exec-error classification) instrumented
the server process; with no server process there is nothing for it to observe — a CLI failure
is node's stderr in the calling Bash tool's output, which is strictly better diagnostics than
any log. Drop. The two 0047 facts that survive are reused, not kept as code: the sibling-dir
rule (§2.2 path rule) and "test cleanup must never `pkill -f`" (moot — no daemon; remove
`kill_port` helpers with the tests). Engram facts f93015-f93017 and f92553 describe the
removed design; the Orchestrator should supersede f92553 with this ruling.

## 5. Docs, agents, skills, commands

- `agents/*.md` ×6: §2.1 item 3. Every `mcp__` mention (6 hits) goes.
- `skills/agent-team/SKILL.md`, `skills/agent-roster/SKILL.md`, `skills/autonomous-pipeline/
  SKILL.md`: every MCP tool name → the §2.6 spelling; the "Always try" paragraphs (2 hits)
  → the §2.1 text; the roster_show sentence (§2.5).
- `commands/*.md`: grep shows no `mcp__` hits; verify and leave.
- `README.md`: line 387/415 links; Layout; any "MCP" feature bullet → "CLI (`docs/cli-tools.md`)".
- `docs/getting-started.md` §6, §8: the first-dispatch example shows the Bash form.
- `docs/troubleshooting.md`: replace the server section with three entries:
  (1) "I get a permission prompt for `node …/roster.mjs`" → the allow hook is not running
  (plugin hooks disabled / path outside the installed root — print the root line) or you are
  using a copied path; alternative: the settings allowlist; (2) "`no orchestrator pid
  resolvable (CLAUDE_PID unset …)`" → not in a Claude Code Bash tool; pass
  `--orchestrator-pid`; (3) "`Cannot find module …/hooks/roster.mjs`" → the version dir in
  your context was removed by an update; start a new session and use the root line it prints.
- Version 0.73.0 in `plugin.json` and `marketplace.json`; CHANGELOG entry if the plugin keeps
  one (not verified — Implementor checks).

## 6. Tests (each must fail without the change it covers)

Existing harness pattern (stdin JSON → hook, HOME/cwd redirected) applies.

- **T1 parser** (new): table-driven over the grammar — accepts each §2.6 row rendered with a
  real absolute path; rejects: `cd /x && node …`, `node … ; rm -rf /`, `node … | cat`,
  `node … --cwd "$PWD"`, `node … $(id)`, backtick, `FOO=1 node …`, `nodejs …`, path via
  `/tmp/x/roster.mjs`, newline inside. Asserts the bool-flag set equals the CLIs' sets.
- **T2 allow hook** (new): recognised non-close command under own root → `allow`; same under a
  sibling dir → `allow`; outside → no output; `dismiss x --close …` → no output; unrelated
  Bash → no output; every rejection in T1 → no output.
- **T3 close gate** (re-key `test-disband-close-gate.sh`): the four MCP cases become four Bash
  commands (`disband --close`, `dismiss bob --close`, plan forms → pass-through); still `ask`
  every time (two calls, two asks, nothing in `gates.jsonl`); enrichment text names the member/
  team from argv.
- **T4 skill gate** (re-key `test-roster-skill-gate.sh`): first `create --plan` denied with the
  CLI wording, identical retry passes, record in `gates.jsonl`; a `show` command never gated;
  an MCP tool name in `tool_name` no longer gated (proves the old key is gone).
- **T5 identity** (re-key `test-orchestrator-identity.sh`): `msg.mjs` honours
  `--orchestrator-pid` over `CLAUDE_PID`; roster cases already exist.
- **T6 verb coverage** (replaces `test-mcp-cli-fallback.sh`): every verb in roster.mjs's and
  msg.mjs's usage blocks appears in `docs/cli-tools.md` with the same spelling, and every
  flag named in the doc appears in the corresponding usage line.
- **T7 no-MCP invariant** (new, cheap): `grep -rl 'mcp__\|mcpServers\|server\.mjs\|AH_MCP'`
  over `agents/ skills/ commands/ hooks/ README.md docs/*.md .claude-plugin/` returns nothing
  (specs excluded); `hooks.json` has no `mcp` matcher; `mcp/` absent.
- **T8 hook wiring**: `hooks.json` has the allow hook and both gates on matcher `Bash`, and
  no `sessionstart-mcp-ensure` entry. `check-gate-name-agreement.mjs` passes (§2.4.5).
- Full suite (`tests/*.sh`) stays green; count drops by the deleted files only.

## 7. Version

0.73.0 — `agent-hierarchy/.claude-plugin/plugin.json` + `/.claude-plugin/marketplace.json`.

## 8. NEEDS-EVIDENCE (Orchestrator routes; results decide as stated)

- **N1 (blocks §2.3)** In a live Claude Code session run, via the Bash tool:
  `echo "CLAUDE_PID=$CLAUDE_PID PPID=$PPID"; ps -o pid=,ppid=,comm= -p $$` and compare
  `CLAUDE_PID` with the session's own pid (the `pid:` the ah SessionStart hook recorded for this
  session, or `pgrep -f 'claude'` narrowed to the session). Repeat once from inside an
  Agent-tool subagent's Bash. **Same pid, both places** → §2.3 as written, no stamping.
  **Unset or different** → implement the §2.3 contingency (hook stamps
  `--orchestrator-pid <hook ppid>` via `updatedInput`) and add its T2 case.
- **N2 (blocks nothing; confirms §2.4.4)** With the allow hook installed, run a
  `dismiss <name> --close …` plan-token-invalid command in a throwaway team: the prompt must
  appear (close gate `ask`) and the CLI must reject the token. If no prompt appears, the
  allow hook is speaking on close commands — a T2 bug, not a design change.
- **N3 (only if U1 = docs-only)** Add `Bash(node */hooks/roster.mjs *)` to a scratch
  settings file and run `node <cache root>/hooks/roster.mjs show --cwd …` → no prompt confirms
  the wildcard shape; a prompt means the rule needs `Bash(node *roster.mjs*)` (docs allow
  either; the second is looser).
- **N4 (informational)** After `/reload-plugins` with a bumped version, does a hook run from
  the new version dir? (`sessionstart` cannot tell; put a one-line `console.error` of
  `CLAUDE_PLUGIN_ROOT` in any PreToolUse hook temporarily.) Yes → the sibling rule in §2.2 is
  load-bearing; No → it is merely harmless. Either way it stays.
- **N5 (deferred, cheap)** Does `${CLAUDE_PLUGIN_ROOT}` expand inside `agents/*.md` bodies?
  If yes, a later spec can put the literal root in the role prompts and drop the SessionStart
  line; not needed for 0.73.0.

## 9. Decisions for the user — asked 2026-09-09, all defaults accepted (U1 hook, U2 drop, U3 moot); N1 measured: CLAUDE_PID = $PPID = session pid in the Bash tool

- **U1** Ship the plugin's own allow hook (default **yes**) vs docs-only settings allowlist.
  Hook: zero setup, version-proof, close commands still prompt. Docs-only: user edits
  `~/.claude/settings.json` once; every ah call is then allowlisted including `--close`
  (the gate's `ask` still prompts — settings ask/allow vs hook ask: docs say settings *ask*
  beats hook allow; a settings *allow* vs hook *ask* is the same undocumented pair as N2).
- **U2** Drop `--diag`/lifecycle log entirely (default **drop**, §4).
- **U3** Allowlist scope if U1 = docs-only: user (default) — the path is under `~/.claude`.

## 10. Risks the Implementor should know

- The grammar is the security boundary of the allow hook. Fail closed: anything the parser is
  unsure about → `null` → no output → normal prompt. Never "allow" on a partial parse.
- `roster.mjs` accepts unknown flags on some verbs and rejects them on others
  (spawn-one/ad-hoc/adopt/checkin reject, roster.mjs:2941-3080). The doc table must not show a
  flag a verb rejects; T6 catches spelling, not acceptance — read the per-verb flag sets.
- `sessionstart.mjs` line 83 skips subagents; do not "fix" that to inject the root — the
  hook-message path (§2.1 item 2) is the subagent channel by design.
- The close gate's enrichment previously read `tool_input.mode`; the Bash form has no `mode`
  — `--close` presence is the mode. Do not gate plan calls.
- `check-gate-name-agreement.mjs` will fail the moment matchers change; update it in the same
  commit as `hooks.json`.
- Comment discipline: the new hook's header states the posture (§2.2) and the sibling rule's
  reason; no change narration.

## 11. Must not change

Tool/verb names and flag spellings of `roster.mjs` and `msg.mjs` (0046 owns them); the
`[hierarchy-msg …]` message-file protocol and its gates; `gates.jsonl` record types; the
roster/team file formats; `CONTEXT.md`; everything under `docs/specs/` except the one
superseded line in 0047.
