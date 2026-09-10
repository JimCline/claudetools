# 0049 — Hardening audit: ah 0.73.1 (main 4a26001)

Status: r1 (Architect). Spec only — no product code changed by this document.
User ruling that motivates it: "I'm tired of these issues. I want this bullet proof."
CLI-primary (0048) is decided and not re-litigated here.

## 0. Scope, method, anti-goals

- Walked every lifecycle path (§2) asking: what does an agent need, who provides it, what happens
  when the provider did not fire. Providers today are exactly two: the plugin's hooks (only they
  know the install root) and the CLIs (`hooks/roster.mjs`, `hooks/msg.mjs`).
- Evidence: 4 read-only delegate sweeps of hooks/, lib-*.mjs, tests/, docs/, agents/, skills/,
  commands/ + Claude Code docs; every claim below cites `file:line` at 4a26001. Claims that need
  a live harness to settle are E# items (§8), not assertions.
- Anti-goals: no new transport, daemon, or state that can be "down"; no new abstraction for a
  one-off; deletion preferred over addition. Every fix is the smallest diff that removes the
  failure class, not the symptom.
- Ranking = severity × likelihood. Severity: H = a role cannot do its job / data loss;
  M = silent misbehaviour needing human diagnosis; L = cosmetic or self-healing.

## 1. Facts (cited)

Hook wiring (`hooks/hooks.json`, 17 entries, all `node "${CLAUDE_PLUGIN_ROOT}/hooks/…"`, none set
`timeout`): SessionStart `startup|resume|clear|compact|fork` ×1; UserPromptSubmit ×1;
PreToolUse `Agent|Task|SendMessage` ×4, `Bash` ×3, `AskUserQuestion|ExitPlanMode|SendUserFile|PushNotification` ×1;
SubagentStop ×2; PostToolUse ×2; Stop ×2; SessionEnd ×1. **No SubagentStart, PreCompact,
Notification, PostToolUseFailure entries.**

Root publication: `lib-config.mjs:45-55` — `MSG_CLI`/`ROSTER_CLI` from `import.meta.url`;
`cliRootLine()` = `ah CLI root: <root> — roster: node <abs>/roster.mjs … messages: node <abs>/msg.mjs …`.
Emitted by `sessionstart.mjs:191-192` (only when `context` non-null: role session, or
configured+enabled, or unconfigured nudge) and `userpromptsubmit-peer-tracking.mjs:89-90` (every
prompt, `!configured || enabled`, never for subagents `:55`). No on-disk existence check anywhere.

Session classification: `lib-config.mjs:295-307` — `isSubagent` = `agent_id` present;
`isTopLevelAgentSession` = `agent_type` present and no `agent_id`. `readHookInput`
(`:269-279`) returns `{}` on empty or unparseable stdin.

Claude Code facts (docs; delegate report): SessionStart/UserPromptSubmit do not fire inside
Agent-tool subagents; SubagentStart fires in the parent and its `additionalContext` reaches the
subagent (auto-memory: only via the `hookSpecificOutput` envelope); `/reload-plugins` reloads
hooks/agents/skills but fires no SessionStart; invalid hook JSON on exit 0 is silently ignored;
exit 1 is non-blocking; hook errors visible only under `--debug`; old plugin version dirs are not
removed; `agent_id` is documented only in SubagentStart/Stop payloads; `CLAUDE_PID`,
`CLAUDE_SESSION_ID`, `${CLAUDE_PLUGIN_ROOT}` inside agent/skill `.md` bodies — NOT documented.

Identity: `roster.mjs:1125` `--orchestrator-pid` → `process.env.CLAUDE_PID`; `:3100-3102`
(checkin) adds a third fallback `process.ppid`, then `:3104` fails "no existing roster record for
pid … SessionStart must run before checkin". `:60` comment: ppid is the transient Bash shell at
this call site. `msg.mjs:126` same two-step resolver. Hooks record `pid: process.ppid`
(`sessionstart.mjs:121`, `sessionend-roster.mjs:27`) — correct there (hook ppid = session pid,
Engram f27263).

Team liveness/deletion: `sessionstart.mjs:73-78` `sweepStaleTeam` → `clearTeam` when
`!teamIsLive` (`lib-roster.mjs:465`: orchestrator pid alive AND age ≤ 24 h). `sweep(dir, 7)`
(`lib-hier.mjs:445`) only archives closed msg pairs. `pidAlive` treats EPERM as alive (`:37`).

Runtime dir: `lib-config.mjs:351-375` — `AGENT_HIERARCHY_DIR` env, else nearest `.git`
(**file or dir** → a worktree is its own root), else `~/.claude/hierarchy/<basename(cwd)>`.
Config candidates do have a main-checkout variant (`:428-439`); the runtime dir does not.
Peer obligations live globally: `~/.claude/agent-hierarchy.peer-pending.jsonl` (`lib-peer.mjs:35`).

Silent-failure surface (delegate table): 15/17 hook entrypoints wrap main in `try { … } catch {}`
and exit 0 / allow with no output; `sessionstart.mjs` (top-level await, `:80`) and
`pretooluse-ultra-gate.mjs:96-151` throw to node's default exit 1. **Zero** `console.error` /
`process.stderr` writes in hooks or libs; no `AH_DEBUG`/log env; no diagnostic file anywhere.

CLI text that names the CLI: `stop-peer-nudge.mjs` uses `MSG_CLI` (absolute);
`pretooluse-route-gate.mjs:130,165,185,209,219-220,239` print `$CLAUDE_PLUGIN_ROOT/hooks/{msg,roster}.mjs`
(shell-expanded at Bash time; the allow hook's grammar rejects `$` — `lib-ah-cli.mjs:56`).

Root-locating recipes in docs (drift): `docs/cli-tools.md:38` + `agents/orchestrator.md:59`
(`installed_plugins.json` one-liner); `commands/hierarchy.md:76`
(`ls -t ~/.claude/plugins/cache/*/agent-hierarchy/*/…` — installed dir is `…/claudetools/ah/<ver>`,
so this glob matches nothing, and `docs/cli-tools.md:34-35` says never to glob the cache);
`docs/comms-protocol.md:98` `"$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs"`. No doc mentions
`claude plugin update`, dirty marketplace clones, or `.bak` dirs.

Tests: every hook has ≥1 test; Stop hooks are fed `{session_id}`-shaped payloads only
(`test-peer-reportback.sh:32`, `test-orchestrator-liveness.sh:84`) — the `--agent` peer Stop path
(`agent_type` present; `stop-orchestrator-liveness.mjs:101-102`) is unit-untested; no test reads
real `~/.claude`; no test of the subagent root channel (there is none to test).

Verbs (`roster.mjs`): show init add edit remove layout alias next-split layout-splits create
disband dismiss untrack resync move spawn-one spawn-ad-hoc adopt teams checkin reap history.
No `doctor`/`status`/`version` verb.

This machine: hooks run from the local checkout (`ah CLI root: …/git/repos/claudetools/agent-hierarchy`),
so uncommitted working-tree edits to `hooks/*.mjs` are live in every session.

## 2. Lifecycle × provider matrix

Columns: root line | verb ref | identity | team/runtime dir | gates | peers.jsonl | Stop liveness.
"✓" = provided; "hook" = the named hook; "—" = nothing; "!" = finding.

| Path | root | verbs | identity | dir | gates | peers | Stop |
|---|---|---|---|---|---|---|---|
| fresh `claude` (startup) | SessionStart ✓ + UPS ✓ | in root line | `CLAUDE_PID` env (E1) | hierarchyDir(cwd) | all | plain: none; role: `up` row | ✓ |
| `--resume` / `--continue` | SessionStart(resume) ✓ | ✓ | same | same | all; one-shot gates already spent (gates.jsonl keyed by session) | new `up` row | ✓ |
| `/clear` | SessionStart(clear) ✓ | ✓ | same | same | spent gates stay if session_id unchanged (E7) | row | obligations keyed by old id if id changes (F12) |
| compaction | SessionStart(compact) ✓ | ✓ | same | same | skill-gate one-shot stays spent, body may be gone (F6) | — | ✓ |
| fork | SessionStart(fork) ✓ | ✓ | same | same | fresh | row | ✓ |
| `/reload-plugins` | UPS only, next prompt (0.73.1) — two roots in context (F5) | ✓ | same | same | hooks now from new dir (E8) | — | ✓ |
| `/reload-skills` | no hook; nothing changes | — | — | — | — | — | — |
| plugin update, sessions live | as reload once `/reload-plugins`; until then old hooks + old root | | | | | | |
| two machines, different versions | independent (all state is per machine) | | | | | | doctor shows version (F3) |
| local-checkout marketplace | hooks run from working tree (§1) — dirty edits live (F8) | | | | | | |
| Agent-tool subagent | **— (no SessionStart/UPS; no SubagentStart hook)** (F1) | only via `${CLAUDE_PLUGIN_ROOT}` in md (E2) | shares session env | parent's | msg/skill gates skip subagents; conduit/ultra apply | — | SubagentStop nudge names absolute path (only channel) |
| top-level `--agent` peer | SessionStart role notice ✓ + root ✓ | ✓ | `CLAUDE_PID` | hierarchyDir(cwd); worktree ≠ main (F10/E6) | all | `up` row with role, pid=ppid | Stop nudge; Architect has no Bash to obey it (F7) |
| Herdr pane peer | same as above + HERDR_* ids | | | | | pane_id recorded | |
| route:pane non-claude member | no hooks, no identity; herdrAgentState only (`roster.mjs:719`) | n/a | n/a | n/a | n/a | n/a | n/a |
| `msgs: off` | root ✓ | ✓ | ✓ | ✓ | msg gates off; peer-nudge still arms on wrapper | ✓ | ✓ |
| `enabled: false` | **no root line** (by design) | — | — | — | route/msg/ultra skip; allow hook + close gate still active | — | — |
| config absent | nudge + root ✓ | ✓ | ✓ | ✓ | as enabled | — | ✓ |
| garbled hook stdin | `{}` → treated as plain main session, no session_id (F11) | | | | gates fail open | | allow |

## 3. Ranked findings

Each: **severity×likelihood** · evidence · failure · minimal fix · test · refs.

### F1 — Subagents have no provider for the CLI root — H×H
- Evidence: no SubagentStart entry (§1); SessionStart/UPS do not fire for subagents (docs);
  `agents/{implementor,reviewer,task-runner,ultra-advisor,architect}.md` reach the CLI only through
  `${CLAUDE_PLUGIN_ROOT}` (`implementor.md:64,70` etc.), whose expansion in md bodies is
  undocumented (E2). Route-gate deny text uses `$CLAUDE_PLUGIN_ROOT` (§1), unset in a Bash-tool
  env (E3). The allow hook rejects any `$` → prompt, then `node /hooks/msg.mjs` → `Cannot find module`.
- Failure: exactly seed (2) one layer down — a subagent guesses the root (`find /`, cache glob).
  The only existing channel is `subagentstop-msg-nudge.mjs`, which arrives after the subagent has
  already stopped once.
- Fix (smallest): one new hook entry `SubagentStart` matcher `*` → new `hooks/subagentstart-cli-root.mjs`
  that emits `cliRootLine()` as `hookSpecificOutput.additionalContext` (envelope required — bare
  stdout is discarded for SubagentStart). No config gating beyond `enabled !== false` (a disabled
  hierarchy injects nothing anywhere; keep that invariant). Reuse `readHookInput` + `cliRootLine`;
  nothing else. Fail-open like the others, but logged (F2).
- Also: every hook-emitted sentence that names a CLI uses `MSG_CLI`/`ROSTER_CLI` absolute paths,
  never `$CLAUDE_PLUGIN_ROOT` — `pretooluse-route-gate.mjs` six sites. `check-gate-name-agreement.mjs`
  learns the new entry.
- agents/skills md: add one sentence next to every `${CLAUDE_PLUGIN_ROOT}` use: "the `ah CLI root:`
  line in your context is authoritative; if `${CLAUDE_PLUGIN_ROOT}` is still literal, use that line."
  Whether the placeholder stays at all is U1 (after E2).
- Test: `tests/test-subagentstart-cli-root.sh` — payload with `agent_id`+`agent_type` → exactly one
  JSON object, `hookEventName:"SubagentStart"`, `additionalContext` equals `cliRootLine()`;
  `enabled:false` → no output; hooks.json wiring asserted (extend `test-ups-cli-root.sh`'s
  hooks.json check). Grep invariant: no `$CLAUDE_PLUGIN_ROOT` / `${CLAUDE_PLUGIN_ROOT}` in `hooks/*.mjs`
  except `hooks.json`.

### F2 — Every hook fails silently — H×M
- Evidence: §1 silent-failure surface. Claude Code adds nothing: invalid JSON ignored, exit 1
  non-blocking, both visible only under `--debug`.
- Failure classes already seen: roster row never written → issue #4 class; HIERARCHY STATE block
  missing after compaction; a gate silently not enforced; a syntax error in a working-tree hook
  (F8) kills all 17 hooks with no trace. The user cannot distinguish "hook decided nothing" from
  "hook crashed".
- Fix: one function in `lib-config.mjs` (every hook already imports it) that appends one JSON line
  `{ts, hook, session_id, event, message, stack: first 3 frames}` to
  `~/.claude/hierarchy/hook-errors.jsonl` — global on purpose: `hierarchyDir()` can itself throw
  (no cwd, bad env), `homedir()` cannot. Bound it: if the file exceeds 1 MiB, rename to `.1` and
  start over (two lines; no rotation library). Every existing `catch {}` in the 17 entrypoints
  calls it and keeps its current fail-open behaviour (exit 0 / allow / decide(null)) —
  enforcement semantics do not change. The two unguarded hooks (`sessionstart.mjs` main body,
  `pretooluse-ultra-gate.mjs`) gain the same wrap: log, then exit 1 (they are non-gating; a visible
  non-blocking error is better than a silent one). `readHookInput` logs when stdin was non-empty
  but unparseable (F11).
- Surface it: `sessionstart.mjs` appends one line to its injection when the file has entries from
  the last 24 h: `ah: N hook error(s) since <ts> — node <ROSTER_CLI> doctor --cwd <cwd>` (U5).
  `doctor` (F3) prints the last 5.
- Test: `tests/test-hook-error-log.sh` — run one gate hook with `AGENT_HIERARCHY_DIR` pointing at
  an unwritable path (forces the catch) under redirected HOME → exit 0, no stdout, one line in
  `$HOME/.claude/hierarchy/hook-errors.jsonl` with `hook` and `message`; the 1 MiB rename branch
  with a pre-filled file; sessionstart surfacing line present iff entries < 24 h old.
- Explicitly not: no `AH_DEBUG` env, no verbose mode, no stderr chatter — one append-only file.

### F3 — No self-check: nothing tells the user what the plugin thinks its own state is — M×H
- Evidence: no `doctor`/`status`/`version` verb (§1); `commands/hierarchy.md:76` tries to be one by
  shelling to `lib-config.mjs` with a dead cache glob. Seeds (1)–(4) each cost a human a debugging
  session that a 1-second read-only report would have shortened to one line.
- Fix: new read-only verb `roster.mjs doctor --cwd <abs>` (a verb, not a new script: the allow hook
  and grammar already cover it, and `roster.mjs` already has `resolveConfig`/`statusReport`/
  `readTeam`/`teamIsLive`/`latestRoster` in reach). JSON output like every other verb, plus
  `--check` → exit 1 when any row is `red`. Rows (each `{name, status: ok|warn|red, detail}`):
  1. `version`: `plugin.json` version + own root (dirname of the script) + node version.
  2. `install`: `~/.claude/plugins/installed_plugins.json` `installPath` for `ah@…`/`agent-hierarchy@…`
     vs own root — `warn` when they differ (a stale root is in use: F5) — `ok` when unreadable and
     own root is not under `~/.claude/plugins/cache` (local checkout). Schema is undocumented: read
     defensively, `warn` on surprise, never throw (E5).
  3. `identity`: `CLAUDE_PID` present? integer? alive? — `red` when absent (F4).
  4. `runtime-dir`: `hierarchyDir(cwd)` path, exists, writable; whether cwd is a worktree whose
     `.git` is a file (F10 hint).
  5. `config`: `resolveConfig` summary (configured/enabled/msgs/route/sources) — existing
     `statusReport` content, not a reimplementation.
  6. `team`: team file present, `team_id`, orchestrator pid alive, age, `teamIsLive`.
  7. `peers`: rows in `peers.jsonl` by status, live vs dead pid count.
  8. `hook-errors`: last 5 entries (F2), count in 24 h → `warn` if any.
  9. `hooks-syntax`: `node --check` over `hooks/*.mjs` in own root (F8) → `red` on failure.
  10. `marketplace`: only when own root sits under a git checkout (local marketplace) or the
      marketplace clone path is derivable (E5): `git status --porcelain` count → `warn` if dirty.
- Wire: `docs/troubleshooting.md` first line = run doctor; `commands/hierarchy.md` replaces its
  `lib-config.mjs` invocation with doctor; `docs/cli-tools.md` gains the row.
- Test: `tests/test-roster-doctor.sh` under redirected HOME: all-green fixture; `CLAUDE_PID` unset →
  `identity red` and `--check` exit 1; syntax-broken copy of a hook in a temp root → `hooks-syntax red`;
  output is one JSON object.

### F4 — Identity falls back to the Bash shell's pid at CLI write sites — H×L (L only if E1 passes)
- Evidence: `roster.mjs:3100-3102` (checkin) third fallback `process.ppid`; the resolver used by
  `create --commit`/`teams` (`:1125`, `:1381` comment) — confirm whether it shares the ppid arm
  (E1b). Under the Bash tool `process.ppid` is the shell (`:60` comment), which exits immediately.
- Failure: a team written with the shell's pid is dead the moment the command returns;
  `sweepStaleTeam` (`sessionstart.mjs:73-78`) then **deletes it at the next SessionStart of any
  plain session in that repo**. Symptom: "my team vanished". checkin's arm is harmless (it fails —
  `:3104`) but its message blames SessionStart instead of the missing `CLAUDE_PID`.
- Fix: delete the `process.ppid` arm at every CLI site (hooks keep theirs). When neither
  `--orchestrator-pid` nor `CLAUDE_PID` resolves, fail with a message that names `CLAUDE_PID` and
  the flag. Fewer lines, no new mechanism. If E1 shows `CLAUDE_PID` absent in Bash-tool envs, the
  contingency from 0048 §2.3 applies (allow hook stamps `--orchestrator-pid <hook ppid>` via
  `updatedInput`) — that is a second spec round, not this one.
- Test: `test-orchestrator-identity.sh` gains: `CLAUDE_PID` unset, no flag → `create --commit`
  and `checkin` exit non-zero with `CLAUDE_PID` in the message; no team file written.

### F5 — Version skew inside one session after an update — M×M
- Evidence: old version dirs persist (docs); SessionStart's root line (old) and UPS's (new) both
  sit in context after `/reload-plugins`; the allow hook's sibling arm (`lib-ah-cli.mjs:170-172`)
  lets either run prompt-free; both CLIs write the same state files.
- Fix: `cliRootLine()` includes the version — `ah CLI root (v0.73.1): …` (read `plugin.json` once,
  fail to `v?`). One sentence in `docs/cli-tools.md` and the six agents md: "when two root lines
  disagree, the most recent one wins." Doctor row 2 flags a stale root in use. Keep the sibling
  arm (U2) — it is what makes the transition prompt-free.
- Test: `test-ups-cli-root.sh` asserts the `(v<plugin.json version>)` token; `test-ah-cli.sh`
  unchanged.

### F6 — Skill body absent after "already loaded" / compaction — M×M
- Evidence (seed 3): Skill tool answered "already loaded above" with no body in context. The
  roster skill gate is one-shot per session in `gates.jsonl` (`pretooluse-roster-skill-gate.mjs:66-72`),
  so after compaction the agent has neither the body nor a fresh deny to fetch it.
- Fix: (a) deny text adds the fallback: "if Skill reports it already loaded but its body is not in
  your context, `Read <root>/skills/agent-team/SKILL.md`" — path from `ROSTER_CLI`'s root, absolute.
  (b) SessionStart `source === "compact"` re-arms the one-shot: append a gate record of the same
  type with `reset: true`; the gate treats a session as un-denied when its latest record is a
  reset (U3, default yes). ≈5 lines.
- Test: `test-roster-skill-gate.sh` gains: deny → reset record → deny again; deny text contains
  the absolute SKILL.md path.

### F7 — A Bash-less role is told to run Bash to answer a peer brief — M×H (Architect peers)
- Evidence: `stop-peer-nudge.mjs` and the SendMessage refusal name
  `node "<MSG_CLI>" new --type response …`; `agents/architect.md` denies Bash by contract (this
  session hit it: the file had to be hand-written). MCP tools that used to cover this are gone.
- Fix: both texts also print the computed response path and the minimal frontmatter, so a
  Write-only role can create the file: "no Bash? Write `<response path>` with frontmatter
  `id,type:response,to,from,slug,parent,reason,eta,to_name,from_name,team,created` and the
  `## [0] tldr` … sections". The response-path derivation already exists in `msg.mjs`
  (reply-beside-request, `test-msg-reply-beside-request.sh`) — export and reuse it; do not
  duplicate the naming rule in the hook.
- Test: `test-peer-reportback.sh` asserts the nudge contains the derived response path.

### F8 — Local-checkout marketplace: dirty tree is live, and update can fail silently — M×M
- Evidence: seed (4) work machine `git pull` failed (dirty clone, `.bak` beside it); no doc covers
  `claude plugin update`, dirty clones, or `.bak`; on the dev machine hooks run from the working
  tree (§1), and `git status` shows `hooks/lib-config.mjs` modified right now — an edit with a
  syntax error disables all 17 hooks with no trace (F2).
- Fix: `tests/test-hook-syntax.sh` — `node --check` every `hooks/*.mjs` (seconds; catches the
  whole class before a session does); doctor rows 9–10; `docs/troubleshooting.md` entry:
  "update fails / old version stays": `git -C <marketplace clone> status --porcelain` → stash or
  `checkout -- . && clean -fd` → rerun `claude plugin update` → delete any `*.bak` beside the clone.
  Dev machine keeps the live checkout (U4).

### F9 — Three root-locating recipes, one of them dead — M×M
- Evidence: §1 drift list; `commands/hierarchy.md:76` glob can never match (wrong dir name) and
  contradicts `docs/cli-tools.md:34-35`; `docs/comms-protocol.md:98` uses shell-expanded form.
- Fix: exactly one recipe, in `docs/cli-tools.md` (the `installed_plugins.json` one-liner, plus
  doctor once it exists); every other place links there. Delete the glob in `commands/hierarchy.md`.
  Grep invariant added to `test-cli-tools-doc.sh`: no `ls -t ~/.claude/plugins/cache` anywhere;
  no `$CLAUDE_PLUGIN_ROOT` (unbraced) outside `hooks.json`.

### F10 — Runtime dir splits per worktree — M×L (needs E6)
- Evidence: `findGitRoot` accepts a `.git` file (§1) → a peer placed in a worktree (spec 0036's
  intended layout) computes `<worktree>/.claude/hierarchy` while the orchestrator in the main
  checkout reads `<main>/.claude/hierarchy`; config resolution has a main-checkout variant, the
  runtime dir does not. `test-roster-worktree.sh` exists — whether it covers the runtime dir is E6.
- Fix if E6 confirms the split: `hierarchyDir` resolves a `.git` **file** to the main checkout
  (parse `gitdir:` → strip `/.git/worktrees/<name>`), ≈6 lines, no new state. If E6 shows the
  readers already reconcile, no change; doctor row 4 keeps the hint either way.

### F11 — Garbled hook stdin degrades to "plain main session" — L×M
- Evidence: `readHookInput` `{}` (§1) → gates skip, SessionStart injects the unconfigured nudge
  with no session_id, Stop allows. Fail-open is right; the silence is not.
- Fix: covered by F2 (log the unparseable payload's length and first 80 chars). No behaviour change.

### F12 — `/clear` or fork orphans peer obligations — L×M (needs E7)
- Evidence: obligations are keyed by `session_id` (`lib-peer.mjs`); if `/clear` issues a new id the
  Stop nudge never fires for the old brief and the orchestrator waits.
- Fix: doc line in `docs/comms-protocol.md` ("a peer that `/clear`s mid-brief must be re-briefed").
  No code unless E7 shows the id is stable (then nothing at all).

### F13 — Live-only behaviour is unit-untested — M×M
- Evidence: §1 tests. Stop hooks never see `agent_type`; the subagent root channel, `/reload-plugins`
  root switch, `${CLAUDE_PLUGIN_ROOT}` expansion, and `CLAUDE_PID` presence can only be checked in
  a harness.
- Fix: (a) `test-orchestrator-liveness.sh` + `test-peer-reportback.sh` gain a `--agent`-shaped Stop
  payload case (`agent_type: "ah:architect"`, `stop_hook_active`, `last_assistant_message`) —
  fixture built from E9; (b) `docs/live-checks.md`: six one-line checks, run after every release on
  each machine, each answerable by `doctor --check` or a single `echo`: E1, E2, E3, E4, E6, E8.
  A doc, not a harness — the harness is what cannot be unit-tested.

### Checked and found sound (no finding)
- msg gate / SendMessage-response / SubagentStop nudge key on `[hierarchy-msg]`, not tool names.
- SessionStart matcher covers `compact|resume|clear|fork`; UPS re-emits the root every prompt.
- Allow hook fails closed on any partial parse; close gate independent of it.
- Peer obligations file is global → survives cwd/worktree changes.
- `sweep` archives, never deletes; `pidAlive` EPERM = alive; no hook has a timeout risk (default 600 s,
  SessionStart's `sweep` is the heaviest and is file-local).
- Stale-team clearing after a reboot is by design; add one troubleshooting line ("team gone after
  reboot: expected, recreate") — not a fix.

## 4. Contracts for the three structural additions

4.1 `hooks/subagentstart-cli-root.mjs` — input: SubagentStart payload; output: nothing, or one
JSON object `{hookSpecificOutput:{hookEventName:"SubagentStart", additionalContext:<cliRootLine()>}}`;
skips when `resolveConfig(cwd).configured && !enabled`; any throw → log (F2) + exit 0.

4.2 Hook error log — path `~/.claude/hierarchy/hook-errors.jsonl`; one line per catch;
fields `ts` (ISO), `hook` (basename of the entrypoint), `event` (`hook_event_name` if parsed),
`session_id` (if parsed), `message`, `stack` (≤3 frames); size cap 1 MiB → rename to `.1`,
overwrite any previous `.1`. Never throws (its own catch is empty — the one place that is allowed).
No behaviour change to any hook's decision.

4.3 `roster.mjs doctor` — read-only, JSON on stdout at every exit code, `--check` → exit 1 iff any
row `red`; rows 1–10 as F3; never spawns anything but `git status --porcelain` (row 10) and
`node --check` (row 9); both wrapped, a spawn failure is a `warn` row, not an exception.
Prompt-free under the existing allow hook without grammar changes (it is a `roster.mjs` verb with
bare-word args).

## 5. Deletions
- `process.ppid` fallback at every CLI identity site (F4).
- `commands/hierarchy.md:76` cache glob (F9).
- `$CLAUDE_PLUGIN_ROOT` in route-gate deny text (F1) — replaced by absolute paths already in scope.

## 6. Tests (new / extended)
T1 `test-subagentstart-cli-root.sh` (F1). T2 `test-hook-error-log.sh` (F2). T3 `test-roster-doctor.sh`
(F3). T4 `test-orchestrator-identity.sh` +2 cases (F4). T5 `test-ups-cli-root.sh` version token (F5).
T6 `test-roster-skill-gate.sh` reset + path (F6). T7 `test-peer-reportback.sh` response path (F7).
T8 `test-hook-syntax.sh` (F8). T9 `test-cli-tools-doc.sh` grep invariants (F9). T10 Stop
`--agent` payload cases (F13). `check-gate-name-agreement.mjs` updated with the SubagentStart entry.
All under redirected HOME (existing convention).

## 7. Version plan — one release, 0.74.0
- Everything in §3 except F10/F12 (gated on E6/E7 → 0.74.1 if needed) and the E1-fail contingency
  (separate spec round). Bump `agent-hierarchy/.claude-plugin/plugin.json` AND root
  `.claude-plugin/marketplace.json`.
- Suggested commit order for reviewability: (1) F2 log + F8 syntax test; (2) F1 hook + route-gate
  text; (3) F4 deletion; (4) F3 doctor; (5) F5/F6/F7 text + small logic; (6) docs F9/F13; (7) bump.
- After install on each machine: `docs/live-checks.md` (F13) once.

## 8. NEEDS-EVIDENCE
- **E1** (decides F4 severity + whether the 0048 §2.3 contingency is needed): in a main session,
  an Agent-tool subagent, and a `--agent` peer, Bash: `echo "[$CLAUDE_PID] [$PPID]"` vs the session's
  pid (`ps -o pid,command | grep claude`). E1b: confirm whether `create --commit`/`teams` share the
  `process.ppid` arm (`roster.mjs` around `:1125`/`:1381`).
- **E2** (decides U1): dispatch `ah:task-runner` with "quote verbatim the first line of your
  instructions containing CLAUDE_PLUGIN_ROOT". Literal `${…}` → not expanded in md bodies.
- **E3**: Bash `echo "[$CLAUDE_PLUGIN_ROOT]"` in a main session and a subagent.
- **E4** (post-implementation): a subagent reports whether `ah CLI root` appears in its context.
- **E5** (scopes doctor rows 2/10): contents/shape of `~/.claude/plugins/installed_plugins.json`
  and `known_marketplaces.json` (keys only) on the dev machine.
- **E6** (decides F10): from a worktree cwd, `roster.mjs teams --cwd <worktree>` vs
  `--cwd <main>`; and whether `test-roster-worktree.sh` asserts the runtime dir.
- **E7** (decides F12): SessionStart `clear` payload `session_id` equal to the pre-clear id or not.
- **E8** (0048 N4): after `/reload-plugins`, next prompt's root line shows the new version dir
  (trivial once F5 adds the version token).
- **E9** (F13 fixture): capture one real Stop payload from a `--agent` peer (fields only).

## 9. User decisions
- **U1** RULED 2026-09-10: keep + sentence (E2 verified live by Reviewer: substitution works in agents/*.md). `${CLAUDE_PLUGIN_ROOT}` in agents/skills md: keep (if E2 passes) + add the root-line
  sentence, vs replace outright with "use the `ah CLI root:` line". Default: keep + sentence.
- **U2** RULED: keep. keep the allow hook's sibling-dir arm. Default: keep.
- **U3** RULED: yes. re-arm the skill gate on compaction. Default: yes.
- **U4** RULED: yes. dev machine keeps the live local-checkout marketplace (with T8 + doctor as the guard).
  Default: yes.
- **U5** RULED: yes. SessionStart surfaces recent hook errors as one injected line. Default: yes (one line,
  only when errors exist).

## 10. Must not change
- Gate semantics: one-shot deny (skill gate), always-ask (close gate), fail-open on error. F2 adds
  logging only.
- Allow-hook grammar (`lib-ah-cli.mjs`) — doctor rides on it unchanged.
- `isSubagent`/`isTopLevelAgentSession` discriminators; hooks' own `pid: process.ppid`.
- Message-file protocol, file naming, reply-beside-request.
- `enabled:false` injects nothing (the new SubagentStart hook honours it).

## 11. Risks for the Implementor
- F2 touches 17 files with a one-line change each — mechanical, but do not alter any exit code or
  decision in the same edit.
- F4: grep every `process.ppid` in `roster.mjs`/`msg.mjs` before deleting — hooks legitimately use
  it; only CLI verb code loses it.
- F3 row 2: `installed_plugins.json` schema is undocumented; treat every field as optional.
- F6b: the reset record must use the same `type` as the deny so `readGates` filtering stays one
  query; do not add a new gate type.
- Do not make SubagentStart emit anything but the root line — the SubagentStart channel is also
  used by other plugins; one line is the whole budget.
