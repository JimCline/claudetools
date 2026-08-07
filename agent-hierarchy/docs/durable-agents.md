# Durable agents — spec (0.9.0)

Reframes `/pane` (0.8.0, spec: `pane-command.md`) as **durable agents**: long-lived,
top-level, interactive Claude Code sessions the Orchestrator hands work to instead of
spawning cold subagents. The 0.8.0 machinery is the substrate and is not redesigned
here; this spec covers the rename, the two awareness hooks, cross-session semantics,
and three review findings folded in as fixes.

## 1. Motivation

Observed failure economics: an Orchestrator fires an expensive subagent for one step,
then fires a fresh one of the same role for the next step. Each spawn starts from
scratch — the full spec re-read, the full briefing re-sent, zero prompt cache. Measured
in the session that built /pane: three Architect dispatches at 118k/124k/166k tokens,
each rebuilding context the previous one already held.

A durable agent inverts this:

- **Continuity** — context accumulates across sends; the architect still knows the
  spec it wrote. Follow-up sends are short.
- **Cache economics** — a living session's context stays prompt-cached; repeated sends
  hit cache. A fresh subagent re-pays full input price every spawn. Idle durable
  agents cost zero tokens.
- **User-controlled lifetime** — `create` and `close` are the user's calls, not
  buried inside a model's dispatch loop.
- **Visibility** — each agent is watchable (and interruptible, and typable-into) in
  its own terminal pane. `list` shows idle/WORKING state per agent.

The honest counterweight, which every piece of guidance text must carry: durable
context drifts, fills, and compacts on the pane's own schedule, invisible to the
Orchestrator. A subagent starts clean. The rule is **durable for continuity across
related tasks; subagent for independent or contamination-sensitive work**. Hooks
offer; they never force.

## 2. Rename (user-facing only)

The branch is unmerged, so the rename is free. "Pane" names the presentation;
"durable agent" names the thing.

- `commands/pane.md` → `commands/durable.md`; invocation `/agent-hierarchy:durable`.
- Subcommands: `create | list | send | peek | close | doctor`. `create` is the
  user-facing verb; `pane.mjs open` remains the CLI verb and `create` maps to it
  (`open` stays accepted).
- Every user-facing noun in command output, README, and injected text says "durable
  agent". The words "pane"/"opened to the right"/"opened below" survive only where
  they describe the literal terminal placement.
- Filenames `pane.mjs` / `lib-pane.mjs` / `stop-pane-relay.mjs` and the `ah-` key
  prefix and registry/mailbox paths are UNCHANGED. The mechanics are genuinely about
  panes, and existing registries must keep folding.
- Batch create (0.9.1) is a command-file flow, not a CLI verb:
  `/durable create <a> <b> [orientation]` dry-runs each agent, confirms the whole
  batch in ONE AskUserQuestion (each agent named, plus a permission-mode question
  per executing agent — per-create approval, gathered once), then runs N
  single-agent creates sequentially, stopping and reporting on the first failure.
  The CLI stays one agent per invocation: launches are cheap, and the
  confirmations and permission decisions were the real cost of a batch.

## 3. Awareness hook 1 — SessionStart roster

In `sessionstart.mjs`, the Orchestrator branch (configured + enabled only) appends a
roster section to the directive when the registry holds live entries:

```
Durable agents live right now (query anytime: node <plugin>/hooks/pane.mjs list):
- ah-…-architect-1 — agent-hierarchy:architect (opus) — idle — created 2026-08-07 by <orch-id>
Prefer sending related follow-up work to a live durable agent over spawning a fresh
subagent of the same role: it already holds the context, and its context is cached.
Send with:  node <plugin>/hooks/pane.mjs send --key <key>  (prompt on stdin, heredoc)
Use a subagent instead when the task is independent or needs a clean context.
```

- The fold MUST be the verify-and-reap fold (`livePanes()`), not the raw fold — an
  Orchestrator never boots seeing ghosts, and reaping at boot is the "polling" story
  (see §6).
- Silent when the registry is absent or has no live keys — zero cost in the common
  case.
- Individually guarded like the pane branch: a broken roster must not take down the
  directive.

## 4. Awareness hook 2 — PreToolUse offer at the dispatch point

A new PreToolUse hook on the `Agent` tool (registered additively in `hooks.json`):

- Fires only when `tool_input.subagent_type` exactly matches the `agent` of a live
  durable agent (verify-and-reap fold, read at dispatch time — this is what makes
  awareness immune to roster staleness).
- **Deny-with-instructions, once**: the denial names the live durable agent(s), state
  (idle/WORKING), model, and the exact send command, and says how to proceed with the
  subagent anyway (re-run the same dispatch). The deny-to-prompt pattern already
  shipped in this plugin's ultra gate.
- **Bounce protection is load-bearing** (per the task-gopher relay lesson): offer at
  most once per (session_id, subagent_type), tracked in the append-only
  `~/.claude/agent-hierarchy.durable-offers.jsonl`. The re-run passes through
  untouched. Without this the Orchestrator ping-pongs. If the offer cannot be
  recorded, the dispatch passes rather than risking a deny loop.
- Never fires for: task-gopher / task-runner (legwork is cheap and stateless — the
  entire point of durable agents is reasoning-role continuity), a WORKING durable
  agent when an idle one of the same type does not exist (denying in favour of a busy
  agent trades a stall for a spawn), or when the dispatching session IS a pane
  (`AGENT_HIERARCHY_PANE_DIR` set — panes may use subagents freely; protocol item 5).
- In `handoffs: confirm` flow the AskUserQuestion gate already interposes a human;
  the hook still fires (once) because the gate's option list is model-authored and
  may have omitted the durable option. The denial text tells the Orchestrator to fold
  the durable agent into the user's choices rather than ask twice.

## 5. Cross-session semantics (what "durable" commits to)

- The registry, mailboxes, and tmux sessions already outlive the creating
  Orchestrator. This is now a FEATURE, stated in docs: close your session, come back,
  the architect is still warm; the new session's roster shows it.
- Discovery is global. `list` and `send` work from any session. Ownership
  (`orchestrator_session_id`) is display metadata, not an ACL.
- `close --all` stays creator-scoped (as shipped). `doctor` remains the global sweep.
- One outstanding request per durable agent (the single `pending` token) is the
  concurrency model, unchanged. Two orchestrators racing to `send` to the same agent:
  the second send fails with "still working", which is correct and needs no lock.

## 6. Lifecycle and cleanup — no poller

Decision recorded: **no polling daemon and no MCP server.**

- Every `list`, `send`, `close`, and now every Orchestrator SessionStart runs the
  verify-and-reap fold. Cleanup happens at the moments the answer matters and
  converges; a daemon would babysit a process to learn answers slightly earlier than
  anyone asks.
- Everything an MCP server would expose is `pane.mjs list --json` plus `send`, both
  already reachable via Bash, matching the plugin's hooks+CLI house style. Typed
  schemas do not pay for a server lifecycle.
- Crash cases and their catch points: user closes the terminal window (tmux session
  dies → next fold reaps); machine reboots (tmux server gone → fold reaps all);
  `claude` inside the pane exits (tmux session may linger empty → `isPaneLive` pane
  check fails → reaped); pane.mjs dies mid-create (see fix F2).

## 7. Fixes folded in (review findings, 2026-08-07)

- **F1 — boot-wait in `send` (moderate; spec-defect in 0.8.0).** `cmdSend` currently
  pastes even when the pane's `session` identity file is missing, which (a) can paste
  into a terminal whose input box does not exist yet — the delivery is silently lost —
  and (b) leaves `expect_session: null`, disarming gate D for the first request
  exactly when a first-task grandchild could exploit it. Fix: when the session file is
  absent, wait up to 30s (poll 1s) for it before pasting; on timeout, fail with
  "the durable agent has not finished booting — peek or attach", leaving no pending
  token. Cross-session sends make this window likelier, so the fix is required
  content of 0.9.0.
- **F2 — untracked session on mid-create crash (low).** Append a `{ev:"launching"}`
  registry event BEFORE `openTmuxSession`; the successful `open` event supersedes it.
  The fold treats a key whose last event is `launching` as dead-unless-tmux-confirms
  (reuse `isPaneLive` against the key alone); `doctor` reports and reaps them.
- **F3 — pane-count NOTE miscounts without iTerm2 (trivial).** The `liveCount`
  filter matches `null === null`; scope it to `useIterm && selfUuid`.

## 8. Out of scope

- Multiple outstanding requests per durable agent (mailbox queueing).
- Any ACL between orchestrator sessions.
- MCP surface (decision recorded in §6).
- Broadcast sends ("ask all durable agents"). One agent per send.
- E12 (which definition copy `claude --agent` reads) remains open and non-blocking.

## 9. Reply-channel hardening (0.10.0)

Frugality is the point of the whole feature — the Orchestrator and every
durable agent budget tokens — and 0.9.x had two holes: nothing tied a Stop to
the request it answered (turn-order trust; a human typing into the pane
mid-request could have their answer relayed as the Orchestrator's reply), and
nothing capped what a reply could pour into the Orchestrator's context.

- **R1 — request-id echo (gate E in the relay).** `send` stamps
  `[ah-request <reqid>]` into every delivery; the agent's final message must
  open with the exact line `[ah-reply <reqid>]`. The relay verifies content,
  not just identity: no echo or a wrong id → the turn is written to the
  mailbox as `unmatched.<ts>.json` (evidence, never lost), the token
  survives, and `ev:"unmatched"` is logged. On a match the echo line is
  stripped before the reply is written. Pendings without the `echo` flag
  (pre-0.10.0) relay on turn order as before — cross-version safe.
- **R2 — the reply contract is stamped, not requested.** The envelope
  (`wrapPrompt`, tested code) carries: echo the id, final results only, no
  progress narration, bulk to disk with absolute paths. The Orchestrator
  never writes contract text by hand; the pane protocol repeats the rules at
  session scope so they survive the agent's own compaction.
- **R3 — the size gate is mechanism, not instruction.** `send` withholds any
  reply body over `panes.replyInlineMaxChars` (default 4000 chars): body to
  `reply.<reqid>.md` in the mailbox; printed instead are the size, path, the
  `## TL;DR` section (or first lines), and the `## ` heading list. Instructing
  the Orchestrator to "check size first" cannot work — the text is in context
  the moment the tool result returns, so the withholding must happen in the
  helper.
- **R4 — greppable reply structure.** Long replies open with `## TL;DR` (one
  bullet per section, naming the `## ` headings that follow), then `## `
  sections — so task-gopher can fetch named sections from the body file with
  a plain awk/sed order and the Orchestrator reasons over bullets, not bodies.
- **`cancel <key>`** clears a stuck outstanding request (an agent that forgot
  the echo line leaves `pending` standing forever, and `send` refuses seconds
  sends while it does). Works against dead panes; the mailbox outlives the
  session.
- **`wait <key>` and the harness-kill constraint (0.11.0).** The Bash tool
  kills commands at 120s by default, and a killed `send` prints none of its
  guidance — so `timeoutSeconds` defaults to 80 (worst case 30s boot-wait +
  80s poll stays under 120s), long tasks end in a graceful timeout, and the
  reply is collected later with `wait --key <key>`: with a request
  outstanding it re-polls for that reqid, with none it re-presents the newest
  reply file on disk. Both paths run through the same presentation as `send`
  (size gate included), so a late reply never enters context raw. Raising
  `--timeout` past ~90 requires passing a matching Bash `timeout` parameter
  alongside it.

## 10. Versioning, tests, rollout

- 0.9.0 in `agent-hierarchy/.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json`.
- Tests to add: boot-wait (present/late/never session file, no token on timeout);
  launching-event fold semantics; roster injection (HOME-redirect fixture with live
  and dead entries — assert dead ones are reaped, not shown); PreToolUse offer
  (deny once per session+type, re-run passes, task-runner exempt, pane-session
  exempt, WORKING-with-no-idle exempt); rename surface (`create` maps to open;
  user-facing text says "durable agent").
- The 297-case 0.8.0 suites must pass unchanged except where the rename touches
  literal expected output.
- Ship order: F1 first (it is a live hardening fix), rename second, roster third,
  PreToolUse offer last (it depends on nothing else and is the riskiest to word).
