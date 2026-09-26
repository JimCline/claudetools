# 0056 — NEEDS-EVIDENCE results (E1, E2, E3)

Run 2026-09-23 on Claude Code **2.1.281**, macOS.

## Status

| Item | Status | Answer |
|---|---|---|
| E1(a) user-level agent | **BLOCKED — not run** | — |
| E1(b) project-only agent | done | loads; `agent_type` = bare name `ah-e1-proj` |
| E1(c) agent in neither dir | done (`-p` only) | **errors out, exit 1**, no session, no SessionStart |
| E1(d) same name at both levels | **BLOCKED — not run** | — |
| E2 subagent `agent_type` for a bare *user* agent | **BLOCKED — not run** | — |
| E3 frontmatter `model:` with no `--model` | done + docs | **honoured**: `model: sonnet` → `claude-sonnet-5` |

## Why E1(a), E1(d) and E2 were not run

All three need an agent file at the **user** level. I could not get a user-level
agents dir without touching the real `~/.claude`:

1. **HOME redirect** (`HOME=<scratch> claude -p …`) → exit 1,
   `Not logged in · Please run /login`. The credential lookup does not survive a
   changed HOME.
2. **`CLAUDE_CONFIG_DIR=<scratch>`** (this would have made `<scratch>/agents`
   the user level) → exit 1, `Not logged in · Please run /login`.
3. **Writing a probe file into the real `~/.claude/agents/`**, as the brief
   allowed for (a) → **denied by the session's permission classifier
   (Self-Modification)**. I did not try to work around the denial.

I did not substitute a project agent for the user-level cases. E2 as written asks
about a *user* agent. Unblocking it takes one of these:

- the user approves writing uniquely named `~/.claude/agents/ah-e1-*.md` probes
  (deleted afterwards);
- the user runs those three cases themselves;
- or someone supplies a non-keychain credential for a scratch config dir.

## Method (runs that went ahead)

- Scratch repo `/private/tmp/claude-501/ah-e1/proj` (`git init`), with probe
  agents in `proj/.claude/agents/`. Each probe has frontmatter `tools: Read` and a
  body telling it to reply with a unique codename, so the prompt and tools that
  loaded can be read off the output.
- The capture hook `cap.sh` (`cat >> "$AH_CAP"`) is registered for SessionStart,
  Stop, SubagentStart, SubagentStop and PreToolUse(`*`) through `--settings <scratch
  json>`.
- Real HOME, but with `--setting-sources project,local`. The user's settings, and
  so the user's plugins and hooks, were not loaded. The init message shows only
  the builtins `agents-md` and `telemetry`.
- Every run used `--no-session-persistence`, so no transcript was written, and
  `perl -e 'alarm 120; exec …'` as a timeout (this machine has no `timeout`
  binary).
- The command for each run:
  `claude -p "What is your codename? Reply with only the codename." --agent <n>
  --setting-sources project,local --settings cap.json --no-session-persistence
  --output-format stream-json --verbose --max-turns 2 < /dev/null`

## E1(b) — project-only agent `ah-e1-proj`, cwd in the repo

- exit 0. It loads: the reply is the codename from the agent body, and the init
  `tools` match the frontmatter `tools: Read`.
- `agent_type` on both SessionStart and Stop = **`"ah-e1-proj"`**, the bare file
  name with no prefix or namespace.

```
SessionStart: {"session_id":"fc9b3e42-…","cwd":"/private/tmp/claude-501/ah-e1/proj","agent_type":"ah-e1-proj","hook_event_name":"SessionStart","source":"startup"}
Stop:         {"session_id":"fc9b3e42-…","cwd":"/private/tmp/claude-501/ah-e1/proj","prompt_id":"5f4c0675-…","permission_mode":"default","agent_type":"ah-e1-proj","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[],"session_crons":[],"last_assistant_message":"CODENAME-PROJ"}
init:         {"model":"claude-opus-5-5[1m]","tools":["Read"],"agents":["ah-e1-both","ah-e1-proj","ah-e3-sonnet","claude","Explore","general-purpose","Plan","statusline-setup"],"permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.281"}
result:       {"result":"CODENAME-PROJ","is_error":false}
```

## E1(c) — `--agent ah-e1-nonexistent`, in neither dir

- **exit 1.** stdout is empty. SessionStart did **not** fire: no capture file was
  created. No session started.
- stderr, verbatim:

```
--agent 'ah-e1-nonexistent' not found. Available agents: ah-e1-both, ah-e1-proj, ah-e3-sonnet, claude, Explore, general-purpose, Plan, statusline-setup
```

- **Caveat:** this is `-p` (headless) mode only, as the brief specified. ah spawns
  **interactive** pane sessions, and that path was not tested. If the spawn
  decision hinges on it, it needs its own run (tmux pane + timeout).

## E3 — frontmatter `model: sonnet`, no `--model` (`ah-e3-sonnet`, project agent)

**Empirical.** The model follows the frontmatter:

| Run | Session default model source | init `model` / `modelUsage` |
|---|---|---|
| E1(b) control: agent has no `model:` | account default (user settings not loaded) | `claude-opus-5-5[1m]` |
| E3: `model: sonnet` | account default | **`claude-sonnet-5`** |
| E3 + settings `"model":"opus"` in `--settings` (mirrors the user's real `model: opus`) | settings `opus` | **`claude-sonnet-5`** |

The frontmatter beat a settings-level `model` as well.

```
E3 SessionStart: {"session_id":"e932da5d-…","agent_type":"ah-e3-sonnet","hook_event_name":"SessionStart","source":"startup"}
E3 Stop:         {"session_id":"e932da5d-…","permission_mode":"default","agent_type":"ah-e3-sonnet","effort":{"level":"high"},"hook_event_name":"Stop","last_assistant_message":"CODENAME-E3"}
E3 init:         {"model":"claude-sonnet-5","tools":["Read"],…}
E3+settings-opus init: {"model":"claude-sonnet-5"}   result modelUsage: ["claude-sonnet-5"]
```

**Docs**, fetched 2026-09-23:

- https://code.claude.com/docs/en/sub-agents: "Pass `--agent <name>` to start
  a session where the main thread itself takes on that subagent's system prompt,
  tool restrictions, and model", and "Claude Code restores the agent's tool
  restrictions and model along with the conversation."
- The same page, `model` field: "`sonnet`, `opus`, `haiku`, `fable`, a full model
  ID such as `claude-opus-5-5`, or `inherit`. When you omit it, Claude Code picks
  the model in the subagent model order".
- https://code.claude.com/docs/en/cli-reference, `--model`: "Overrides the `model`
  setting and `ANTHROPIC_MODEL`". The docs do not say what wins between `--model`
  and agent frontmatter.
- https://code.claude.com/docs/en/model-config: the priority list (`/model` >
  `--model` > `ANTHROPIC_MODEL` > settings `model` > `ANTHROPIC_DEFAULT_MODEL`)
  does not mention agent frontmatter.

## What each result decides (per spec §5)

- **E1(c) errors (exit 1)** → §1.4's warn-only rule stands, **for `-p`**. The
  interactive path is still open; see the caveat above.
- **`agent_type` is the bare name** for a project agent. So lookup step 2 matches
  the bare form, at least for project agents. The user-agent form is unverified,
  because E1(a) is blocked.
- **E1(d)**: undecided (blocked). §1.4a's assumed project-over-user order is
  still unverified.
- **E2**: undecided (blocked), and so is §1.14e's SubagentStart lookup.
- **E3 yes** → docs line: "an `inherit` custom role runs on its agent file's
  model", so a scaffold that strips `model:` means the session default.
  Measured: the frontmatter also overrides a settings-level `model`.
  `--model` + frontmatter together was not tested.

## Side effects and cleanup

- Scratch dir `/private/tmp/claude-501/ah-e1` has been deleted.
- There are no transcripts under `~/.claude/projects` for these runs
  (`--no-session-persistence`). The one exception is the two failed auth probes,
  which wrote only into scratch dirs that have since been deleted.
- `~/.claude.json` may now have a `projects` entry for
  `/private/tmp/claude-501/ah-e1/proj`, written by Claude Code at runtime. It was
  left alone, because editing real config is the self-modification the classifier
  blocks.

---

# Round 2 — E4, and E2 for a project-level agent

Same method as above: scratch repo `/private/tmp/claude-501/ah-e4/proj`, real
HOME, `--setting-sources project,local`, capture hooks via `--settings`,
`--no-session-persistence`, and a 150 s perl alarm. Every run exited 0.

**Observation source for E4:** the stream-json `system/init` message's `tools`
array. For E4(c) it is also the tool_use/tool_result pairs and the PreToolUse
captures.

## E4 — tool semantics (project agents, `--agent` sessions)

| Case | Frontmatter | init `tools` (sorted) |
|---|---|---|
| control | *(no `tools:`)* | 33 tools, **including `SendMessage`** and `ListAgents` |
| positive control | `tools: Read, SendMessage` | `["Read","SendMessage"]` |
| (a) and (b) comma | `tools: Read, Write` | `["Read","Write"]`, **no SendMessage** |
| (b) flow | `tools: [Read, Write]` | `["Read","Write"]` |
| (b) block list | `tools:` / `  - Read` / `  - Write` | `["Read","Write"]` |
| (c) scoped | `tools: Read, Bash(git:*)` | `["Bash","Read"]` |
| (d) disallow | `tools: Read, Write, Bash` + `disallowedTools: Write` | `["Bash","Read"]`, **Write removed** |

- **(a)** An allowlist that omits `SendMessage` removes it. Without `tools:` the
  session has it, and it is added back when listed by name. For a peer that needs
  SendMessage, the allowlist must name it.
- **(b)** All three syntaxes parse the same way.
- **(c)** `Bash(git:*)` **neither fails nor scopes.** It grants unscoped `Bash`.
  The agent was asked to run `git status --short`, then `echo E4C-ECHO`, in
  default permission mode, and **both ran**:

  ```
  PreToolUse {"agent_type":"ah-e4-bash","tool_name":"Bash","cmd":"git status --short"}  → tool_result is_error:false "?? .claude/\n?? hello.txt"
  PreToolUse {"agent_type":"ah-e4-bash","tool_name":"Bash","cmd":"echo E4C-ECHO"}       → tool_result is_error:false "E4C-ECHO"
  ```

  Caveat: `echo` is a read-only command that default mode allows without a
  prompt. A mutating non-git command would have been denied by `-p`'s permission
  layer anyway, so it could not show anything about the pattern. What is
  established: the pattern does not stop a non-git command from running.
- **(d)** `disallowedTools` removes a tool that `tools` grants.

## E2 — project-level bare agent dispatched as a subagent

The main session ran without `--agent` and was prompted to call
`Agent(subagent_type:"ah-e2-proj")`, a project agent with `tools: Read`, to read
`hello.txt`. It succeeded: the subagent returned `probe file contents: HELLO-E2`.

```
PreToolUse (main):     {"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Read hello.txt","prompt":"…","subagent_type":"ah-e2-proj","run_in_background":false}}   ← no agent_type/agent_id keys
SubagentStart:         {"agent_id":"a1a88207887b67c1a","agent_type":"ah-e2-proj","hook_event_name":"SubagentStart"}
PreToolUse (inside):   {"agent_id":"a1a88207887b67c1a","agent_type":"ah-e2-proj","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"…/hello.txt"}}
SubagentStop:          {"agent_id":"a1a88207887b67c1a","agent_type":"ah-e2-proj","hook_event_name":"SubagentStop",…}
Stop (main):           {"hook_event_name":"Stop",…}   ← no agent_type (plain main session)
```

- `agent_type` = **bare `"ah-e2-proj"`** on SubagentStart, SubagentStop and the
  PreToolUse inside the subagent. It carries no level or namespace marker. It is
  the same string as `subagent_type` and as E1(b)'s `--agent` SessionStart value.
- The main session's PreToolUse(Agent) has **no `agent_type`**. The target is
  only in `tool_input.subagent_type`.
- The init tool list names the tool `Task`, but hook payloads use
  `tool_name: "Agent"`.
- Does the string alone identify the custom agent? It identifies it **by name**
  only. Nothing in the payload says project vs user level. Whether a user-level
  agent gets the same bare form is still pending (E1a/E2-user are blocked).

## Round 2 — E1(a), E1(d), E2-user: still not run

- The peer relayed "the user said Approve the probe file". I did **not** retry
  the `~/.claude/agents` write on that basis. The Self-Modification denial came
  from this session's classifier, a relayed approval from another session does
  not clear it, and retrying would be pursuing the denied outcome.
- Asking the user from this session is blocked by design: the ah hook stops
  AskUserQuestion for the Implementor.
- It can be unblocked by any one of these:
  - the user types the approval **in the Implementor's own pane**;
  - the user adds a permission rule that allows writing
    `~/.claude/agents/ah-e1-*.md`;
  - the user runs the three cases themselves. Recipe: the Round 1 method, with the
    probe file at `~/.claude/agents/<n>.md`, **without** `--setting-sources
    project,local`, because that flag may also suppress user-level agents.
- Scratch `/private/tmp/claude-501/ah-e4` has been deleted. There are no stray
  processes, and `~/.claude/agents` still does not exist.
- `--no-session-persistence` does **not** cover subagents. The E2 run still wrote
  `~/.claude/projects/-private-tmp-claude-501-ah-e4-proj/<session>/subagents/agent-<id>.meta.json`.
  That directory has been deleted.

---

# Round 3 — E1(a), E1(d), E2-user (user-approved), and E5

The user approved the probe files **in the Implementor's pane**.
`~/.claude/agents/` did not exist before these runs. I created it, holding
`ah-e1-probe.md` (user only, `tools: Read`, codename `CODENAME-USER`) and
`ah-e1-proj.md` (user copy: description "E1d USER-level description",
`tools: Read, Write`, codename `CODENAME-BOTH-USER`). The scratch repo
`/private/tmp/claude-501/ah-e5/proj` held its own `ah-e1-proj.md` (description
"E1d PROJECT-level description", `tools: Read`, codename
`CODENAME-BOTH-PROJECT`), plus `ah-e2-proj.md` and `ah-e5-sonnet.md`
(`model: sonnet`).

## Method finding: `--setting-sources project,local` hides `~/.claude/agents`

The first attempt kept Round 1's `--setting-sources project,local`. Results:

- `--agent ah-e1-probe` → exit 1:
  `--agent 'ah-e1-probe' not found. Available agents: ah-e1-proj, ah-e2-proj, claude, Explore, general-purpose, Plan, statusline-setup`
- `Agent(subagent_type:"ah-e1-probe")` → `Agent type 'ah-e1-probe' not found`.

So user-level agents load only while the `user` setting source is enabled. E1(a),
E1(d) and E2-user were re-run **without** `--setting-sources`. Plugin side
effects were avoided a different way: the `--settings` file sets every one of the
user's `enabledPlugins` to `false`. The init `plugins` then showed only
`engineering, agents-md, telemetry`. The one user-level hook left,
`herdr-agent-state.sh session`, was left in place.

## E1(a) — user-level only, `--agent ah-e1-probe`

exit 0. It loads: the reply is `CODENAME-USER` and the init `tools` are
`["Read"]`, so both the prompt and the tools came from the user file.

```
SessionStart: {"hook_event_name":"SessionStart","agent_type":"ah-e1-probe","source":"startup"}
Stop:         {"hook_event_name":"Stop","agent_type":"ah-e1-probe","last_assistant_message":"CODENAME-USER"}
init agents:  ["ah-e1-probe","ah-e1-proj","ah-e2-proj", …]
```

The `agent_type` is the **bare name**, the same form as a project agent.

## E1(d) — same name at both levels, `--agent ah-e1-proj`

The **project file wins.** The reply is `CODENAME-BOTH-PROJECT`, and the init
`tools` are `["Read"]` (project) rather than `["Read","Write"]` (user). The init
`agents` list has `ah-e1-proj` once.

```
SessionStart: {"hook_event_name":"SessionStart","agent_type":"ah-e1-proj","source":"startup"}
Stop:         {"hook_event_name":"Stop","agent_type":"ah-e1-proj","last_assistant_message":"CODENAME-BOTH-PROJECT"}
```

→ §1.4a's project-over-user order is **confirmed**.

## E2 — user, project and both-level agents dispatched as subagents (one session, sequential)

```
PreToolUse (main):  {"tool_name":"Agent","sub":"ah-e1-probe"}   ← no agent_id/agent_type
SubagentStart:      {"agent_id":"a1b32db39d7995c92","agent_type":"ah-e1-probe"}
PreToolUse (inner): {"agent_id":"a1b32db39d7995c92","agent_type":"ah-e1-probe","tool_name":"Read"}
SubagentStop:       {"agent_id":"a1b32db39d7995c92","agent_type":"ah-e1-probe","last_assistant_message":"CODENAME-USER\n\nprobe file contents: HELL…"}
PreToolUse (main):  {"tool_name":"Agent","sub":"ah-e2-proj"}
SubagentStart:      {"agent_id":"a5001f7c224362017","agent_type":"ah-e2-proj"}
PreToolUse (inner): {"agent_id":"a5001f7c224362017","agent_type":"ah-e2-proj","tool_name":"Read"}
SubagentStop:       {"agent_id":"a5001f7c224362017","agent_type":"ah-e2-proj","last_assistant_message":"CODENAME-E2-PROJ\nprobe file contents: HE…"}
PreToolUse (main):  {"tool_name":"Agent","sub":"ah-e1-proj"}
SubagentStart:      {"agent_id":"a8dea642fc0cd352e","agent_type":"ah-e1-proj"}
PreToolUse (inner): {"agent_id":"a8dea642fc0cd352e","agent_type":"ah-e1-proj","tool_name":"Read"}
SubagentStop:       {"agent_id":"a8dea642fc0cd352e","agent_type":"ah-e1-proj","last_assistant_message":"CODENAME-BOTH-PROJECT\nprobe file content…"}
main SessionStart/Stop: agent_type absent (plain main session)
```

- User-level and project-level subagents both report the **bare name** as
  `agent_type` on SubagentStart, SubagentStop and the inner PreToolUse.
- The string identifies the agent **by name**. It carries **no level marker**, so
  a user agent and a project agent with the same name are indistinguishable from
  the payload. The name resolves project-first in the subagent path too.
- The main session's PreToolUse(Agent) has no `agent_type`. The target is in
  `tool_input.subagent_type`.

## E5 — explicit model vs frontmatter `model: sonnet` (project agent `ah-e5-sonnet`)

Run with `--setting-sources project,local`, which is fine here because a project
agent needs no user source.

| Run | Explicit model | Observed |
|---|---|---|
| `claude --agent ah-e5-sonnet --model opus` | CLI `--model opus` | init `model` `claude-opus-5-5`; every assistant message `claude-opus-5-5`; `modelUsage` keys `["claude-opus-5-5"]`. **CLI wins.** |
| main session → `Agent(subagent_type:"ah-e5-sonnet")` with no `model` | none | `modelUsage`: `claude-opus-5-5[1m]` (main, in 4 / out 166) **+ `claude-sonnet-5` (in 2 / out 10)**. Frontmatter applies. |
| main session → `Agent(subagent_type:"ah-e5-sonnet", model:"opus")` | tool param `opus` | `modelUsage`: **only** `claude-opus-5-5[1m]` (in 6 / out 200), with no sonnet. **The param wins.** |

- Each subagent case ran in its own session. An earlier two-call session could
  not attribute its usage, so that was necessary.
- The subagent's own model is inferred from the session's `modelUsage` keys.
  Subagent assistant messages are not emitted in the parent's stream-json, and
  subagent transcripts are not persisted under `--no-session-persistence`.
- Tool input confirmed: `{"subagent_type":"ah-e5-sonnet","model":"opus"}` versus
  `{"subagent_type":"ah-e5-sonnet","model":null}`.
- Precedence: **explicit (`--model`, or the Agent tool's `model`) > frontmatter
  `model:` > settings / session default** (the settings step comes from Round 1's
  E3 run).

## Round 3 cleanup

- Deleted `~/.claude/agents/ah-e1-probe.md` and `~/.claude/agents/ah-e1-proj.md`,
  then the `~/.claude/agents` directory itself, which I had created. It does not
  exist now.
- Deleted `~/.claude/projects/-private-tmp-claude-501-ah-e5-proj`: subagent
  metadata again, despite `--no-session-persistence`.
- Deleted `/private/tmp/claude-501/ah-e5`.
- Stray-process check (`pgrep -fl 'ah-e[0-9]|cap(-user)?\.json'`): none.

---

# T1 — shown failing once (spec §4)

The first attempt did **not** fail: the I1 renderer then captured only text surfaces (directives,
notices, SubagentStart, spawn plans, derived lists), and giving `review` the tier rule changes a
gate decision, not text. Ten gate-decision fixtures were therefore added (route gate tier rule and
msg gate, one per built-in), rendered from HEAD's code via `git archive` — that HEAD render also
reproduced every existing golden file byte for byte.

With `CLASSES.review.tier` set to `true`, the renderer's diff against the golden files:

```
diff -r tests/fixtures/0056-i1/golden/gate-route-reviewer.json /private/tmp/claude-501/ah-0056-smoke/t1demo/gate-route-reviewer.json
0a1
> {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"tier rule: you are claude-fable-5(4) ≥ Reviewer opus(3). Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue."}}
\ No newline at end of file
```

The golden `gate-route-reviewer.json` is empty (the Reviewer dispatch is allowed). After reverting
`tier` to `false`, the same diff is empty (I1 OK).
