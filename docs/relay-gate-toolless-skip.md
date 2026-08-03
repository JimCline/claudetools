# Relay gate: skip agents that cannot dispatch

**Component:** `task-gopher` (reported against v0.7.1, fixed in v0.8.0)
**Files:** `hooks/pretooluse-nudge.mjs`, `hooks/directive.mjs`, `hooks/agent-tools.mjs` (new),
`hooks/report.mjs`, `commands/task-gopher.md`, `tests/test-relay-gate.sh`
**Status:** implemented — all three parts shipped
**Reported:** a `thread-assessor` subagent (from `github-pr-toolkit`'s
`/resolve-pr-comments`) opened its turn with *"I don't have an Agent tool available, so
I'll do the reads directly."*

---

## The problem

The relay gate rewrites every `Agent`/`Task` dispatch in flight, prepending
`FULL_DIRECTIVE` to the subagent's prompt (`pretooluse-nudge.mjs:315-337`). It skips only
four hard-coded built-ins:

```js
// pretooluse-nudge.mjs:79
const RELAY_EXEMPT = new Set(["Explore", "Plan", "statusline-setup", "output-style-setup"]);
```

Any other agent is stamped — **including agents whose `tools:` allow-list has no `Agent`
or `Task` entry, which therefore cannot dispatch at all.**

A concrete case, from `github-pr-toolkit` v0.29.2 `agents/thread-assessor.md`:

```yaml
tools: >-
  Read,
  Grep,
  Glob,
  advisor
```

No `Agent`. No `Task`. It receives ~1,467 tokens of instructions telling it to delegate,
reads the escape clause, and correctly does nothing with it.

### This is not a behavioral bug

The directive already carries a self-exclusion clause, and it works — the agent
identified that it could not dispatch and proceeded. `docs/subagent-directive-relay.md:260-261`
records this as the deliberate design:

> Custom tool-less agents can't be enumerated, so also give the directive itself an
> escape clause ("no Agent tool? ignore this").

The defect is **cost and accuracy**, not behavior:

1. **Cost.** Measured on v0.7.1: `FULL_DIRECTIVE` is 5,868 chars ≈ **1,467 tokens**,
   prepended to every dispatch to an agent that can never act on it. On a flow that fans
   out one assessor per PR thread, this multiplies by thread count.
2. **Accuracy.** `directive.mjs:126` tells every agent that the harness already handles
   this:

   > "a PreToolUse hook stamps it onto every dispatch prompt in flight (skipping
   > task-gopher itself and tool-less scouts)"

   No tool-less skip is implemented. `RELAY_EXEMPT` is four names. The sentence is
   read by every agent that receives the directive, and it is wrong.

### Why the hook cannot currently detect this

`directive.mjs:56,69-73` documents that hook input carries no model or tier field. The
same limit applies here: the `PreToolUse` payload for an `Agent` dispatch exposes
`tool_input.subagent_type` (used at `pretooluse-nudge.mjs:316`) but **not the target
agent's tool list**. The gate knows the agent's *name*, not its *capabilities*.

---

## The fix

Two parts. Part 1 is small and complete on its own; part 2 removes the manual step.
Both shipped, along with the part 3 text correction.

### Part 1 — user-extensible exempt list

Add a `RELAY_EXEMPT_FILE` alongside the existing state files in `directive.mjs`
(`STATE_FILE:14`, `STRICT_FILE:27`, `NUDGE_FILE:30`, `LOG_FILE:38`), following the same
convention:

```js
export const RELAY_EXEMPT_FILE = join(homedir(), ".claude", "task-gopher.relay-exempt");
```

One `subagent_type` per line; `#` comments and blank lines ignored. Read it in
`pretooluse-nudge.mjs` and union it with the built-in `RELAY_EXEMPT` set before the
check at line 328. Missing file → empty set, current behavior unchanged.

Ship `/task-gopher relay-exempt [add|remove|list] <agent-type>` in
`commands/task-gopher.md` to manage it, matching the existing `strict`/`report`/`log`
subcommands.

**Why first:** ~15 lines, no new failure modes, no path resolution, and it gives users an
immediate lever for any agent — including ones whose definitions the hook could never
find (SDK-defined agents have no file on disk).

### Part 2 — automatic detection from the agent definition

Resolve `subagent_type` to its definition file and parse the frontmatter:

- `plugin:agent` → search plugin roots for `<plugin>/agents/<agent>.md`
- bare name → `.claude/agents/<name>.md` (project), then `~/.claude/agents/<name>.md` (user)

Skip the relay when the frontmatter declares a `tools:` **allow-list** that contains
neither `Agent` nor `Task`.

Three rules that keep this safe:

1. **Only an allow-list is decisive.** An agent with no `tools:` line inherits every
   tool, so it *can* dispatch — stamp it. `disallowedTools` is a deny-list and cannot be
   read as evidence of absence.
2. **Fail toward current behavior.** Any resolution failure — file not found, unparseable
   frontmatter, ambiguous name — falls through to stamping. A broken lookup must never
   silently disable the relay for agents that should get it.
3. **Cache per process.** The gate runs on every dispatch; resolve each `subagent_type`
   once and memoize. Never let a filesystem walk sit on the hot path of a `Read`.

**NEEDS-EVIDENCE — RESOLVED.** There is a reliable way, so part 2 covers plugin agents too.
`~/.claude/plugins/installed_plugins.json` maps `<plugin>@<marketplace>` to an array of
`{scope, installPath, version}`, and agents live at `<installPath>/agents/<name>.md`.
Verified against the reported case: `github-pr-toolkit@jimcline` resolves to
`~/.claude/plugins/cache/jimcline/github-pr-toolkit/0.16.0`, where `agents/thread-assessor.md`
exists. A dispatch carries only the plugin half of that key, so the lookup matches on the
prefix before `@`.

This registry is load-bearing rather than a convenience: the cache holds **several versions
of the same plugin side by side** (`github-pr-toolkit/0.12.2` and `0.16.0` both present), so
a glob would have to guess which one is live. `installed_plugins.json` pins it.

`known_marketplaces.json` is also consulted, because a marketplace served from a local
checkout (`claudetools` → `~/git/repos/claudetools`) is edited in place while its cached copy
under a version number goes stale.

That staleness forced one rule the original proposal did not have: **copies that disagree are
stamped.** `code-reviewer-general` is the live example — the cached 0.16.0 copy declares a
`tools:` allow-list with no `Agent`, while the local checkout declares only `disallowedTools`.
One says "cannot dispatch", the other says "can". We cannot tell which the harness loaded, and
not knowing has to mean stamping. Verified: it stamps.

### Part 3 — correct the directive text

`directive.mjs:126` currently promises a skip that does not exist. Either implement part 2
and leave the sentence true, or reword it now to describe what the gate actually does:

> "a PreToolUse hook stamps it onto every dispatch prompt in flight (skipping
> task-gopher itself and a short list of built-in agents)"

The same sentence appears in `SHORT_REMINDER` territory at `directive.mjs:131` — check
both. This is worth doing regardless of parts 1 and 2, because the claim is read by every
agent that receives the directive.

Part 2 shipped, so the sentence is now true and was reworded to say precisely what the gate
skips: task-gopher itself, and any agent whose tool list gives it no `Agent`/`Task` tool.
`SHORT_REMINDER` was narrowed from "every dispatch" to "the dispatches that can use it".

**One more stale claim, found while doing this.** `commands/task-gopher.md` still carried the
instructions from *before* the relay was automatic:

> When dispatching any subagent except task-gopher itself and tool-less scouts (Explore, Plan),
> copy the full [task-gopher: ON] directive block verbatim to the top of the dispatch prompt —
> subagents don't inherit your context, and a relay checkpoint bounces dispatches that omit it.

Both halves are wrong: the bounce was retired when the gate moved to `updatedInput`, and
hand-copying is now exactly what the directive tells agents *not* to do. Replaced with a
description of the automatic relay, and a test asserts the old wording cannot come back.

---

## Tests

`tests/test-relay-gate.sh` went from 68 to 100 assertions, all passing. Every case from the
original list landed, plus the ones the implementation turned up:

Part 1 — exempt file: listed type not stamped; comments and blanks ignored; entries trimmed;
a comment line is not itself an entry; missing file leaves behavior identical; removing the
file restores stamping; a `task-gopher` dispatch still takes the reset path even if someone
exempts it.

Part 2 — frontmatter: `tools:` without `Agent`/`Task` not stamped; **no** `tools:` key stamped;
`disallowedTools` alone stamped; wildcard `*` stamped; `Task` counts as dispatch-capable;
inline, folded (`>-`), block-sequence and flow-sequence YAML all parse; no frontmatter stamped;
unresolvable name stamped; path-traversal name stamped; project `.claude/agents` resolved from
the payload's `cwd`; plugin agents resolved via `installed_plugins.json`; unknown plugin stamped;
local-checkout marketplace resolved; **disagreeing copies stamped**; an unparseable registry
leaves the gate working.

Part 3 — the directive's skip claim must be backed by code, and the retired hand-copy paragraph
must not return.

The harness already redirects `HOME` (`docs/subagent-directive-relay.md:405`), so the exempt
file, the fake `~/.claude/agents/*.md` definitions and a fake `installed_plugins.json` all drop
into the sandbox with no install.

**The tests were checked for the ability to fail.** Mutating `grantsDispatch` so an absent
`tools:` list reads as "cannot dispatch" — i.e. breaking rule 1 — turns the suite red on exactly
the two assertions that guard that rule (`NO tools key -> stamped`, `disallowedTools is NOT
evidence of absence`), 98/100. Reverting returns it to 100/100.

---

## Effect

Removes ~1,467 tokens per dispatch to each exempted agent. Largest on flows that fan out
one tool-less assessor per work item. No behavior change for agents that *can* dispatch,
which is every agent the directive is actually aimed at.

Probed against the real installed set (`cannotDispatch` called directly, no state written):

| dispatch target | verdict | why |
| --- | --- | --- |
| `github-pr-toolkit:thread-assessor` | **skip** | the reported case — `Read, Grep, Glob, advisor` |
| `github-pr-toolkit:github-worker` | **skip** | MCP tools only |
| `github-pr-toolkit:critic-worker` | **skip** | `Bash` + MCP tools |
| `agent-hierarchy:task-runner` | **skip** | `Read, Grep, Glob, Bash, WebFetch, WebSearch` |
| `github-pr-toolkit:code-reviewer-general` | stamp | installed copies disagree — see above |
| `agent-hierarchy:architect` / `:reviewer` | stamp | `disallowedTools` only, so they keep `Agent` |
| `godot-prompter:godot-animator` | stamp | no `tools:` key |
| `general-purpose`, `Explore` | stamp | no definition file (`Explore` is already a built-in exempt) |

Because a skip is otherwise invisible — the dispatch still succeeds, the subagent simply never
sees the directive — each one now writes a `relay-skip` line to the audit log with its reason
(`builtin`, `user-exempt`, `no-dispatch-tool`), and `/task-gopher report` breaks them down by
reason. A `no-dispatch-tool` skip against an agent that obviously *can* delegate is the one
failure this feature can introduce, so it has to be legible somewhere.
