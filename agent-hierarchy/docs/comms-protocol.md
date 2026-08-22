# agent-hierarchy 0.29.0 — file-based messages, peer roster, tier rule

Spec. Three rules, one version. Baseline: `49bb157` (0.28.0). Bump plugin.json AND
root marketplace.json to 0.29.0.

## [0] tldr
- [1] why: three observed failures — compaction loses briefs; orchestrator forgets live peers; same-tier downward delegation
- [2] runtime dir: `.claude/hierarchy/` project-preferred, user fallback; self-gitignored
- [3] message files: `<id>--<to>--<slug>--<type>.md`, flat YAML frontmatter, `## [N] key` anchors, grep-then-Read
- [4] msg.mjs CLI: `new | list | index | sweep` — writers never hand-roll ids/skeletons
- [5] dispatch gate: role dispatch (Agent or peer brief) must carry `[hierarchy-msg <request-path>]`; deny-with-instructions otherwise
- [6] response gate: role subagent's last message / peer's reply must carry `[hierarchy-msg <response-path>]`; one nudge, fail-open
- [7] peer roster: `peers.jsonl`, written by peers (SessionStart/End) and by orchestrator PostToolUse on ListAgents/SendMessage
- [8] routing preference: ask ONCE per session peers|subagents|prefer-peers, then enforce silently; replaces per-role roster deny
- [9] tier rule: haiku<sonnet<opus<fable; Architect/Ultra-Advisor at ≤ own tier → do inline unless `reason:` given; one-shot gate when model known
- [10] SessionStart: compact/resume/startup inject open exchanges + roster + tier line
- [11] directive/agent-file text changes
- [12] tests
- [13] docs, command, version
- [14] non-goals / open items

## [1] why
- Peer/subagent briefs sent as long prose; receiver compacts, loses the ask, sender re-sends. Fix: durable, progressively-readable file per exchange; in-band text is a pointer + TL;DR.
- Orchestrator forgot which peers it had confirmed/briefed and spawned subagents while peers sat idle. Fix: hook-owned roster + one-shot deny gate; roster re-injected on compact.
- Orchestrator on Fable/Opus dispatched Architect (Opus) / Ultra-Advisor for reasoning. Fix: tier rule in directive + one-shot gate; delegating downward buys context isolation or parallelism, never reasoning.
- Token math, stated in README: file protocol does not make hop 1 cheaper; it removes re-sends and keeps orchestrator context small.

## [2] runtime dir
- `hierarchyDir(cwd)` in new `hooks/lib-hier.mjs`:
  - walk up from `cwd` for `.git` (file or dir); if found → `<root>/.claude/hierarchy/`
  - else → `~/.claude/hierarchy/<basename(cwd)>/`
  - env override `AGENT_HIERARCHY_DIR` wins (tests use it; also lets a user pin one dir across clones)
- `ensureHierarchyDir(cwd)`: mkdir -p `msgs/`, `msgs/archive/`, `specs/`; write `.gitignore` containing `*\n` if absent. Idempotent.
- Files: `msgs/*.md`, `peers.jsonl`, `gates.jsonl` (one-shot deny records, replaces nothing existing), `specs/` (suggested default for Architect spec paths; not enforced).
- Cross-repo peers (different checkouts) get different dirs. Out of scope; note in README.

## [3] message files
- Path: `<dir>/msgs/<id>--<to>--<slug>--<type>.md`
  - `id` = `YYYYMMDD-HHMMSS-<4 base36>` (writer's local time; base36 from crypto random). Request and response share it.
  - `to` ∈ `orchestrator|architect|implementor|reviewer|ultra-advisor|task-runner`. Response's `to` = original `from`.
  - `slug` = `[a-z0-9-]{1,32}` (issue/defect/short title)
  - `type` ∈ `request|response`
- Frontmatter — flat scalars only, no nesting, no lists (so it cannot break):
  ```
  ---
  id: 20260816-143201-k7q2
  type: request
  to: implementor
  from: orchestrator
  slug: peer-roster
  parent: null            # id of a prior exchange this follows, or null
  reason: null            # request only, see [9]: context | second-opinion | parallel | null
  to_name: null           # optional: the specific instance — peer session name or subagent id
  from_name: null         # optional: sender's instance name
  created: 2026-08-16T14:32:01-04:00
  ---
  ```
- MULTIPLE INSTANCES PER ROLE are normal (two implementor peers, or three implementor subagents in flight). Roles are categories; instances are named by `to_name`/`from_name`. Nothing keys on role alone except the one-shot deny records ([8], [9]), which are deliberately per-role reminders.
- Body — sections are `## [N] key` at column 0; NOTHING else in the file may start with `## [`. Fixed keys per type; every key present even if `- none`.
  - request: `[0] tldr` `[1] goal` `[2] context` `[3] constraints` `[4] files` `[5] acceptance` `[6] want_back`
  - response: `[0] tldr` `[1] status` (`done|partial|blocked` first bullet) `[2] changes` `[3] evidence` `[4] gaps` `[5] open_questions`
- `[0] tldr` = one bullet per following section: `- [N] key: <≤10-word gist>` — this is the index.
- Style rules (in directive + agent files): bullets, imperative, no prose, no restating what the reader can see; every constraint / negative / acceptance criterion survives verbatim — brevity is the tie-breaker, never the goal.
- Reader protocol (in directive + agent files): `grep -n '^## \[' <path>` → line-numbered index; `Read(offset,limit)` only the sections tldr says matter. Whole-file Read is fine when small.
- Closure: response file exists ⇒ exchange closed. New work = new id (`parent:` links it). Never append to a closed file.
- In-band text:
  - Agent prompt / SendMessage body for a role tasking: first line `[hierarchy-msg <abs request path>]`, then ≤3 lines of TL;DR. Peer briefs additionally keep the existing `[hierarchy-peer-brief ...]` sentinel line.
  - Role's final text / peer reply: first line `[hierarchy-msg <abs response path>]`, then the `[1] status` bullet. Nothing else required.

## [4] msg.mjs CLI
- `hooks/msg.mjs`, node, no deps. All subcommands take `--cwd <path>` (default `process.cwd()`), resolve dir via [2], print JSON on stdout unless `--plain`.
- `new --to <role> --from <role> --slug <s> [--to-name <n>] [--from-name <n>] [--parent <id>] [--reason <r>] [--type request|response] [--id <id>]`
  - `request` (default): generates id, writes skeleton with all section anchors and `- none` placeholders (`[0] tldr` gets one `- [N] key:` line per section), prints `{ "id", "path" }`.
  - `response`: `--id` REQUIRED and must match an existing `--request.md`; `to`/`from` swapped from the request; `parent` copied.
- `list [--open|--closed|--all] [--to <role>] [--json]` — pairs by id; `open` = request without response. Default `--open`. Plain form: `id  to  slug  age  [open|closed]`.
- `index <path>` — prints `line:## [N] key` for every anchor (portable equivalent of the grep; agents may use either).
- `sweep [--days 7]` — moves closed pairs whose response is older than N days to `msgs/archive/`. Prints count.
- `roster` — see [7]; prints roster summary.
- `route [peers|subagents|prefer-peers]` — with no argument prints the effective route and its source (session|config|default); with one, appends `{type:"route", session_id, value, ts}` to `gates.jsonl`. Requires `--session <id>` (hooks pass it; the orchestrator is told the id in the deny text). Rejects any other value.
- Exit non-zero with one-line stderr on bad args / missing request for a response.

## [5] dispatch gate (PreToolUse)
- New `hooks/pretooluse-msg-gate.mjs`, wired on `Agent|Task|SendMessage` (same matcher line as the ultra gate; order in hooks.json: ultra gate first, then msg gate, then roster/tier gate — a deny anywhere stops the call).
- Applies to:
  - `Agent`/`Task` where `subagent_type` ∈ `ah:{architect,implementor,reviewer,ultra-advisor}` (also bare names, mirroring `GATED_SUBAGENT_TYPES` style).
  - `SendMessage` whose `message` contains the `[hierarchy-peer-brief` sentinel (a tasking). Pings, chat, replies pass.
- Exempt: task-runner / task-gopher (errands stay inline); any subagent context (`isSubagent(input)`) — subagents dispatching subagents are already relayed by other plugins; keep this orchestrator-only in 0.29.0.
- Check: prompt/message contains `[hierarchy-msg <path>]` where `<path>` is absolute, exists, is under `<dir>/msgs/`, ends `--request.md`, frontmatter parses, `type: request`, and `to:` matches the dispatched role (`subagentType→role` via existing `roleFor`; for peer briefs, the role whose `resolvedPeerTarget` equals `to`, or skip the role check if `to` matches no configured peer).
- Deny (`permissionDecision:"deny"`) with reason:
  ```
  ah: role dispatches carry their brief as a message file, not inline prose.
  1. node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" new --to <role> --from orchestrator --slug <slug> [--parent <id>] [--reason context|second-opinion|parallel]
  2. Fill every section (bullets, no prose; keep every constraint verbatim; [0] tldr indexes the rest).
  3. Re-issue this exact dispatch with first line: [hierarchy-msg <path>] then ≤3 TL;DR lines. Peer briefs keep the [hierarchy-peer-brief ...] sentinel too.
  Reason this call was denied: <missing token | path not found | wrong to: (file says X, dispatch is Y) | not a request file>.
  ```
- Fail-open on any internal error (unreadable dir, malformed input): allow.
- Config: `msgs: "required" | "off"` top-level key in agent-hierarchy.json, default `"required"`. `off` disables [5] and [6] but not the CLI or SessionStart listing.

## [6] response gate
- Subagent side — `hooks/subagentstop-msg-nudge.mjs` on `SubagentStop` (matcher `*`, after usage collector):
  - Only for `agent_type` ∈ hierarchy reasoning roles. Read `last_assistant_message` (present on Stop; verify on SubagentStop — if absent, read the last assistant line of `transcript_path` as `subagentstop-usage.mjs` already does).
  - If it lacks `[hierarchy-msg <path>--response.md]` with an existing file: `decision:"block"`, reason: `write your response file (node ".../msg.mjs" new --type response --id <id> ...; fill it) and return exactly: [hierarchy-msg <path>] + the [1] status bullet`. Find `<id>` from the request token in the first user turn of `transcript_path`; if none (brief was inline / gate off) → allow silently.
  - One nudge per `agent_id` (record in `gates.jsonl` `{type:"nudge", agent_id, ts}`); second stop always allowed. Fail-open.
- Peer side — extend `lib-peer.mjs`:
  - `parseSentinel` unchanged; `userpromptsubmit-peer-tracking.mjs` also records `msg: <request path>` on the obligation when the brief carries `[hierarchy-msg`.
  - `posttooluse-peer-resolve.mjs`: an obligation with `msg` set resolves only if the reply `message` contains `[hierarchy-msg <path>--response.md]` for that id and the file exists; otherwise leave pending. Obligations without `msg` resolve as today.
  - `stop-peer-nudge.mjs` `owedLine`: when `msg` set, say `your reply must carry [hierarchy-msg <response path>] — write it with msg.mjs new --type response --id <id>`. `MAX_NUDGES` unchanged.

## [7] peer roster
- File: `<dir>/peers.jsonl`, append-only, latest-per-key like `lib-peer.mjs`. Key = `name` when known, else `session_id`.
- Record: `{type:"peer", name?, role?, session_id?, pid?, cwd?, status, task?, ts}`; `status` ∈ `up|down|seen|briefed|reported`.
- Writers:
  - Peer session `sessionstart.mjs` (startup/resume/clear): if `agent_type` is a hierarchy role (top-level `--agent` — the existing role-session branch) → append `{status:"up", role, session_id, pid: process.ppid? , cwd}`. NEEDS-EVIDENCE: which pid in hook env is the session's; try `process.ppid` and record both `pid`/`ppid`; liveness check uses whichever survives a live test. If unresolvable, omit pid and rely on ts age.
  - New `SessionEnd` hook `hooks/sessionend-roster.mjs` (matcher `*`): same branch → `{status:"down"}`. Also `Stop`? No — Stop is a turn end, not session end.
  - Orchestrator `PostToolUse` on `ListAgents` (new `hooks/posttooluse-roster.mjs`, matcher `ListAgents|SendMessage`; the existing SendMessage resolver stays a separate hook): parse `tool_response` lines under `Peer sessions` — regex `^\s*(.+?) \[([0-9a-f]+)\]\s+·\s+(\w+)\s+·\s+(idle|busy)\s+·` — for each name that (a) equals a `resolvedPeerTarget` for some role, or (b) contains a role token (`architect|reviewer|implementor|ultra-advisor|advisor`) → `{status:"seen", name, ref, role, busy:bool, ts}`. Names matching nothing are ignored.
  - Same hook on `SendMessage` with `[hierarchy-peer-brief` in message → `{status:"briefed", name: stripRef(to), role (via resolvedPeerTarget lookup or role token), task: sentinel task, ts}`.
  - `posttooluse-peer-resolve.mjs` unchanged; orchestrator side "reported" is inferred from a closed exchange, not written.
- `roster(dir, config, repoBasename)` in `lib-hier.mjs` returns per role a LIST of instances: `[{name, live: bool, how: "up-pid"|"seen"|"briefed", ageSec, busy, openBriefs}]`, sorted live-first then freshest. `openBriefs` = open request files with `to:<role>` AND (`to_name` == this name, or `to_name` null → counted for every instance of the role, flagged `unassigned`). `live` = `up` with pid alive (`process.kill(pid,0)`), or `seen`/`briefed` within `ROSTER_FRESH_SEC = 1800`. `down` supersedes.
- Config: `peer` accepts a string OR an array of names. `resolvedPeerTarget` becomes `resolvedPeerTargets(role, entry, repoBasename) → string[]` (keep the old name as a one-element convenience wrapper for existing callers/tests); ultra gate and roster match ANY of them. PEER NAME CONFIRMATION still writes a single string; users hand-edit arrays. Names matched only by role token (unconfigured peers) are still recorded and count as candidates.
- `msg.mjs roster` prints it. `/hierarchy peers` calls it.

## [8] routing preference gate (PreToolUse)
- REPLACES the earlier "deny once per role" roster gate. One routing question per session, asked before the FIRST roster dispatch, then honored silently. Rationale: `handoffs:"confirm"` item 0 and a per-role deny were both asking about the same choice; three prompts for one decision is worse than one.
- In `hooks/pretooluse-route-gate.mjs` (also hosts [9]); matcher `Agent|Task|SendMessage`.
- ROUTE values: `peers` (peers only — never spawn a roster subagent), `subagents` (never route to a peer), `prefer-peers` (peer when one is live and free, else subagent). Default when the user has not answered: `prefer-peers`.
- Precedence: session answer (`gates.jsonl`) > config `route` key in agent-hierarchy.json > `prefer-peers`. A config `route` value means never ask — the user already decided durably.
- Trigger: a dispatch that would task a peer-eligible role (Agent/Task with a roster `subagent_type`, or SendMessage carrying `[hierarchy-peer-brief`), when NO `{type:"route", session_id, value}` record exists this session AND no config `route` key. Task-runner/task-gopher exempt — errands are not roster dispatches.
- On trigger, DENY once with:
  ```
  ah: choose this session's dispatch route before tasking roles. Live peers: <Role>="<name>" <how> <age><, busy><, N open>; … | none.
  Ask the user with AskUserQuestion, exactly these options in this order:
    "Prefer peer agents, fall back to subagents (Recommended)" — reuse a live peer when one is free; spawn only when none is.
    "Peer agents only" — never spawn a roster subagent; wait or tell the user when no peer is free.
    "Subagents only" — ignore peers entirely this session.
  Record it: node "$CLAUDE_PLUGIN_ROOT/hooks/msg.mjs" route <prefer-peers|peers|subagents> --session <session_id>
  (the deny text must interpolate the real session id; `route` requires it — see [4])
  Then re-issue this exact dispatch. Say in one line what you recorded.
  ```
  Do not reword the options and do not record a choice the user did not pick.
- After a route is recorded, enforce it (no further prompts):
  - `subagents`: allow every Agent spawn; DENY a SendMessage peer brief with "route is subagents this session — spawn the subagent instead, or change route with msg.mjs route".
  - `peers`: DENY an Agent spawn of a roster role while `roster()` shows ANY live instance for it, listing them and instructing SendMessage with `to_name` set. Allow the spawn when no live instance exists (nothing to route to) and say so in a `systemMessage`.
  - `prefer-peers`: DENY an Agent spawn only while a live instance for that role is NOT busy, listing candidates; allow when all are busy or none is live. This is the only value where "busy" matters.
  - Every deny under an established route is ONE-SHOT per (session, role): the identical re-issue passes, so the orchestrator can always override with intent. Record `{type:"route-deny", session_id, role}`.
- `/hierarchy route [peers|subagents|prefer-peers]` prints or sets it; setting with no session answer yet also writes the session record. Saying "use peers only" etc. in chat is honored the same way (directive item 13 tells the orchestrator to record it).
- Interaction with `handoffs:"confirm"`: item 0 still asks per dispatch, but its peer-vs-subagent options are now FILTERED by the session route — under `peers` it offers only the peer option, under `subagents` only the subagent option, under `prefer-peers` both with the peer first. One decision, asked once; item 0 remains about whether to hand off at all.
- Fail-open on any internal error. Inert for subagents (`isSubagent`).

## [9] tier rule
- `TIER = {haiku:1, sonnet:2, opus:3, fable:4}`; `tierOf(modelString)` matches family token in `claude-<family>-…` or bare family; unknown → null.
- Session model source, in order: hook input `model` (NEEDS-EVIDENCE: confirm SessionStart/PreToolUse payload carries `model`; if it does, cache `{session_id, model}` in `gates.jsonl` at SessionStart so PreToolUse can read it) → env `CLAUDE_MODEL` → null.
- Directive text (SessionStart) item 12, always emitted; with model known: `TIER RULE — you are <model> (tier n). Architect opus(3), Ultra-Advisor fable(4). haiku<sonnet<opus<fable.` With model unknown: `TIER RULE — read your own model from your environment line and rank haiku<sonnet<opus<fable; Architect opus(3), Ultra-Advisor fable(4).` Then in both: `Do not dispatch Architect or Ultra-Advisor for REASONING when its tier ≤ yours — take that role's contract inline (write the spec at the spec path yourself; adjudicate yourself). Same-or-lower-tier dispatch is allowed only for: context — the design is large and belongs out of your window; second-opinion — the user asked for one, or you want a fresh-context check; parallel — you are running other work meanwhile. Put the reason in the request file's reason: field and one tldr line. Ultra-Advisor: escalate only when strictly higher than you; same tier → decide it yourself and say so. Reviewer is exempt — review buys independence, not tier.`
- Gate (in `pretooluse-route-gate.mjs`): when session tier known, `subagent_type` ∈ architect|ultra-advisor, role tier ≤ session tier, and the request file's `reason:` is null/absent → one-shot deny per (session, role) with: `tier rule: you are <m>(n) ≥ <role> <m2>(n2). Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.` Second attempt passes. Same for peer briefs to those roles (SendMessage with sentinel + `[hierarchy-msg`) — read `reason` from the file.
- Ultra gate ordering: ultra approval gate still runs first and independently.
- With `msgs:"off"` there is no request file to carry `reason`. The tier gate still fires its one-shot deny (the reminder is the point), but the denial text must drop the `reason:` instruction and read: `Do it inline, or re-issue this exact dispatch to proceed.`

## [10] SessionStart injection
- `sessionstart.mjs` (top-level, configured, enabled branch), all matchers incl. `compact`: append after the directive:
  ```
  HIERARCHY STATE (<dir>):
  open exchanges: <n> — <id> <to> <slug> <age> … (max 10; "+k more: msg.mjs list")  |  none
  peers: architect=<name> live 4m briefed(spec-x); reviewer=<name> seen 12m; implementor: none  |  none
  route: <prefer-peers|peers|subagents> (from session|config|default) — change with /hierarchy route or just say so
  tier: you are <model>(n); architect opus(3); ultra-advisor fable(4)  |  tier: model unknown — see TIER RULE
  ```
- On `startup` only: run sweep (7 days) silently first.
- Peer role-session branch (top-level `--agent` role): append `{status:"up"}` per [7] and add one line to the notice: `You are a peer <Role>. Briefs arrive as [hierarchy-msg <path>]; read via grep '^## \[' then Read; reply with a response file (msg.mjs new --type response --id <id>) and [hierarchy-msg <path>] first line.`
- Subagent branch: unchanged (inject nothing).

## [11] text changes
- `lib-config.mjs buildDirective`: add item 12 (message files: writer/reader protocol, CLI, in-band pointer rule, style rules), item 13 (roster + route: "peers.jsonl is ground truth; after compaction trust HIERARCHY STATE over memory; this session's route is <value> — honor it without re-asking; if the user changes it in chat, record it with `msg.mjs route <v>` and confirm in one line"), item 14 (tier rule per [9]). PEER BRIEF CONTRACT: add bullet "first line after the sentinel is `[hierarchy-msg <request path>]`". Item 3 (spec path): default `<dir>/specs/<slug>.md`.
- `agents/orchestrator.md`: same three rules, compressed.
- `agents/architect.md`, `agents/reviewer.md`, `agents/implementor.md`, `agents/ultra-advisor.md`: add "BRIEF INTAKE — your brief is a file: `[hierarchy-msg <path>]`. `grep -n '^## \[' <path>` for the index, Read only what you need. REPORT — write `msg.mjs new --type response --id <id> --to <from> --from <role>` and fill it (bullets, no prose, status first); your final message is `[hierarchy-msg <response path>]` + status bullet — nothing else." Architect/Ultra-Advisor additionally: "If the request's `reason:` is `second-opinion`, the caller is your tier or higher: give a verdict, not a tutorial."
- `commands/hierarchy.md`: add `/hierarchy msgs [open|closed|all]` → `msg.mjs list`; `/hierarchy peers` → `msg.mjs roster`; `/hierarchy route [peers|subagents|prefer-peers]` → `msg.mjs route` (no arg prints; with arg records session value, and offers to persist it as the config `route` key); `/hierarchy sweep [days]`; `/hierarchy msgs off|required` toggles config key.
- README: new section "Message files, roster, tier rule" — the protocol, the token-math caveat, the one-shot gate semantics, cross-repo limitation.
- `docs/hierarchy.html`: add the three rules to the mechanics page (brief).

## [12] tests
- All bash, HOME-redirect + `AGENT_HIERARCHY_DIR` + cwd injection, per existing style; run via `for t in tests/test-*.sh`.
- `test-msg-cli.sh`: new request skeleton (anchors, tldr lines, frontmatter flat); response requires id; list open/closed; index line numbers match grep; sweep archives only closed > N days; `.gitignore` written; project vs user dir resolution; env override.
- `test-msg-gate.sh`: deny on missing token / missing file / wrong `to` / response file used as request; allow with valid file; task-gopher exempt; SendMessage without sentinel passes, with sentinel + no token denied; subagent context passes; `msgs:"off"` disables; malformed input fails open.
- `test-msg-response.sh`: SubagentStop blocks once without pointer, allows second time; allows when no request token in transcript; peer resolve requires pointer when obligation has `msg`; nudge text names msg.mjs.
- `test-roster.sh`: peer SessionStart writes `up`, SessionEnd writes `down`; ListAgents PostToolUse parses the fixture (use the exact line format above, incl. busy) and records only role-matching names; SendMessage brief records `briefed`; `roster()` live/stale by age and pid; TWO peers for one role both listed, `openBriefs` split by `to_name` and unassigned counted for both; config `peer` as array resolves all; `msg.mjs roster` output.
- `test-route-gate.sh`: route unset → deny with the three-option prompt, exactly once, and only for roster dispatches (task-gopher exempt); `msg.mjs route <v>` records it; config `route` key means never ask; precedence session>config>default. Then per value: `subagents` denies a peer brief and allows spawns; `peers` denies a spawn while a live instance exists and allows when none does; `prefer-peers` denies only while a live instance is not busy, allows when all busy. Every deny one-shot per (session, role) — identical re-issue passes. Tier deny once when model known and reason null; passes with reason; unknown model → no tier deny; `msgs:"off"` tier denial omits the `reason:` instruction. Ultra gate still runs first (existing test-ultra-gate.sh must stay green).
- `test-sessionstart-agent.sh` extended: HIERARCHY STATE block on compact and startup; peer role-session notice line; subagent gets nothing.
- Fixture for `last_assistant_message` on SubagentStop: capture a real payload once (NEEDS-EVIDENCE) and commit it under `tests/fixtures/`.
- `test-hook-syntax.sh` (NEW, cheap, runs first): every `hooks/*.mjs` passes `node --check`. Rationale: hooks load from the working tree, so an uncommitted syntax error breaks hooks in EVERY live session on the machine the instant it is saved — observed during the 0.29.0 build (unescaped apostrophe in a single-quoted directive string in lib-config.mjs took out the Stop hook). The suite must catch this, not the user. Anyone editing hooks runs the same check after each edit, not batched at the end. Long directive strings containing apostrophes should use backticks.

## [13] docs, command, version
- Bump `agent-hierarchy/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` to 0.29.0. hooks.json `description` paragraph: append the three mechanisms in the same voice.
- Commit message: `agent-hierarchy 0.29.0: file-based briefs, peer roster gate, tier rule`.

## [14] non-goals / open items
- Not gating subagent-initiated dispatches (nested hierarchies) — 0.30.0 if wanted.
- Not enforcing brevity by size; only structure. Revisit if files bloat.
- Cross-repo peers share no dir; user may set `AGENT_HIERARCHY_DIR` in both.
- Engram: optional secondary write of exchange summaries is NOT in scope; the directory is the record.
- NEEDS-EVIDENCE (Implementor resolves during build, records answer in README "Verified payloads"): (a) does SessionStart/PreToolUse hook input carry `model`; (b) does SubagentStop carry `last_assistant_message`; (c) which pid in a hook env identifies the session for liveness. Each has a stated fallback above; none blocks the build.
