# Spec 0022 — background peer spawn: standing a peer up with no orchestrator turn

> **STATUS: WITHDRAWN — DO NOT IMPLEMENT.** Superseded by `docs/specs/0021-per-role-spawn-policy.md` §4.2.
> The user considered the zero-turn design and chose the one-orchestrator-turn version instead: `auto`
> denies once with the `spawn-one` command and the re-issue passes. `0021` is complete and self-contained
> and does not depend on anything here.
>
> **This file is kept as a record, not as a plan.** It holds three things worth not re-deriving: §1's
> proof that "zero turns" and "this dispatch uses the peer" cannot both hold at a missing-peer dispatch;
> §2's finding that nothing in this codebase detaches a child process; and §3.2 plus §10's
> provenance-vs-scope lesson from the Ultra-Advisor ruling, which is a general result about roster levels
> and outlives this spec. **Do not resurrect the design without a new user decision.**

Was: implements `onMissing: "auto"`, deferred from `0021` §4.2.
Was bound by `0021` §4.4 (scope gates are not bypassed) and `0021` §4.3 (`0009` §5.2's availability guard).
Was constrained by `0006` §4 and `0016` §4.5 (*hooks decide; `roster.mjs` executes*).

**Amended (a) — Ultra-Advisor ruling (retained; it is the most valuable part of this file).**
The draft asked whether a repo-scoped roster is adequate authorisation for creating live agent sessions
with no synchronous supervisor. The answer was **no as specified, and no new consent mechanism is needed —
the predicate was simply too wide.** §3.2 treated "repo" and "repo-user" as equivalently user-authorised.
They are not, and the difference is dispositive:

| level | path | who can create it |
|---|---|---|
| `global` | `~/.claude/agent-hierarchy.json` | this user, but applies to every repo |
| `repo` | `<repoRoot>/.claude/agent-hierarchy.json` | **anyone who can commit to the repo** — arrives via `git clone` |
| `repo-user` | `~/.claude/agent-hierarchy/projects/<slug>/agent-hierarchy.json` | **only this user, on this machine** |

A committed repo-level config carrying `onMissing: "auto"` would spawn live `claude` sessions on merely
**opening a cloned folder** — the same self-signed-permission failure global is excluded for, except
*third-party*-signed, which is strictly worse.

## 1. The constraint that killed the zero-turn framing

The user wanted a peer standing when needed with **zero orchestrator turns**. `0021` §4.2 established that
a PreToolUse hook cannot deliver that by returning a decision: the peer takes seconds to come up and the
dispatch must return now.

**The sharper constraint, and the durable finding of this investigation:**

> A spawn started at dispatch time cannot make *that* dispatch use the peer. The peer does not exist yet.

"Zero-turn" and "this dispatch uses the peer" are not simultaneously achievable at a missing-peer
dispatch. Only three outcomes exist:

| | turns | does THIS dispatch use the peer? |
|---|---|---|
| deny + instruct — **this is what `0021` §4.2 ships** | 1 | yes, after the re-issue |
| background-spawn + allow as subagent | 0 | **no** — it warms the peer for next time |
| background-spawn + block until up | 0 | yes, but the tool call hangs for seconds — unacceptable |

This table is why the design moved the spawn earlier (§3) rather than making dispatch-time spawning
faster, and it is the analysis that led the user to conclude the one-turn version was the better trade.

## 2. What the codebase does today — the finding that shaped the mechanism

Every child-process call in `agent-hierarchy/` is **synchronous or awaited**:

- `roster.mjs:175` `execFileSync("tmux", …)` — transport detection
- `roster.mjs:286` `execFileSync("herdr", …)` — every herdr call
- `roster.mjs:524` `execFile("/bin/sh", …)` inside `runShell`, awaited via a Promise
- `mcp/server.mjs:347` `spawn(process.execPath, …, {stdio:["ignore","pipe","pipe"]})` — awaited for output

**Nothing is detached. Nothing outlives its caller. `detached` and `.unref()` appear nowhere in the tree.**

Still true, and still worth knowing: any future proposal that wants a process to outlive the thing that
started it is the first of its kind here, and inherits this spec's §9/§10 questions.

Available hook events (all wired in `hooks/hooks.json`): `SessionStart`
(`startup|resume|clear|compact|fork`), `PreToolUse`, `PostToolUse`, `SubagentStop`, `UserPromptSubmit`,
`Stop`, `SessionEnd`.

## 3. Was: primary mechanism — pre-warm at SessionStart

`hooks/sessionstart.mjs` already resolves the config and roster, computes `hierarchyDir`, and performs a
write (the stale-team sweep, `0001` §5.3). The design added one step after the sweep:

```
for each roster member where:
      resolved.rosterLevel === "repo-user"              // ONLY — §3.2. Not repo. Not global.
  AND member.route === "peer"
  AND member.role is in PEER_ELIGIBLE_ROLES
  AND member.onMissing === "auto"
  AND no live instance of that member exists            // memberIsLive(dir, member.name)
→ detachedSpawnOne(cwd, member, orchestratorPid = process.ppid)
```

### 3.1 Only on `source === "startup"`

The `SessionStart` matcher includes `compact` and `fork`. A pre-warm on `compact` would fire mid-session,
repeatedly, for the life of a long conversation. `resume` excluded too.

Ultra-Advisor sub-answer (a), settled: this **is** the whole rate limit, no explicit cap needed. Bounded by
roster size; the liveness check skips anything already running; the worst case — respawning genuinely dead
peers — is the feature working.

### 3.2 Pre-warm requires a `repo-user` roster — the rule the ruling produced

`0021` §4.4 requires the scope-gate property to survive. At SessionStart that property is not merely
unenforced, it is **unenforceable**: `0009` §4's scope-A gate is session-scoped and answered *during* the
session, and no answer can exist before the first dispatch. Pre-warm cannot ask, so its authorisation has
to come from the roster's **provenance** — from who was able to put the file there.

Only `repo-user` clears that bar (see the table in amendment (a)). It is outside every working tree,
per-user, per-machine, per-project, and **creatable only by an act of this user on this machine** — the
only level whose existence is itself evidence of user intent.

### 3.3 Ownership pid

`0018` requires a live orchestrator pid before a team is created. A detached child's parent (the hook)
exits immediately, so the child cannot infer it — it would have to be passed explicitly as
`--orchestrator-pid <process.ppid>`, and a spawn with no resolvable pid must not happen at all.

Retained because it generalises: **any** future detached path in this codebase inherits this problem.

## 4. Was: secondary mechanism — dispatch-time catch-up

In `pretooluse-route-gate.mjs`'s `peers` / no-live-instance branch, `auto` would apply `0009` §5.2's
`rosterUsable` guard, `detachedSpawnOne(...)`, then **allow** the dispatch with a `systemMessage` saying
plainly that *this* dispatch runs as a subagent and the peer will be available for the next one.

`0021` §4.2's shipped design replaces this with a deny-plus-instruction, which costs a turn and gets the
peer used on the re-issue.

### 4.1 Why not block, poll, or deny — retained

- **Block until up** — hangs the orchestrator's tool call for seconds. Rejected outright.
- **Poll on a later hook** — `PostToolUse`/`Stop` could notice the peer came up, but nothing can retroact
  the dispatch that already ran. Adds machinery, changes nothing observable.
- **Deny and re-issue** — was rejected here as costing a turn; **is now the shipped design** (`0021` §4.2),
  because the turn turned out to be acceptable and buying the peer for *this* dispatch turned out to matter
  more than avoiding it.

### 4.2 Why §4 would have kept repo-level rosters when §3 did not

Pre-warm has no synchronous supervisor — nobody initiated it, nobody sees it, the scope gate cannot run.
None of that is true at dispatch time: a live session initiated it, the `0009` §4 scope gates run first,
and the `systemMessage` announces it in the transcript. The leash property holds there regardless of
provenance.

*(Ultra-Advisor confidence: high on the §3 repo/repo-user split; medium-high on allowing §4 at repo level.)*

## 5. Was: the launcher

```js
export function detachedSpawnOne(cwd, member, orchestratorPid, logPath) {
  const child = spawn(process.execPath,
    [rosterCliPath(), "spawn-one", member.role, "--member", member.name,
     "--cwd", cwd, "--orchestrator-pid", String(orchestratorPid)],
    { detached: true, stdio: ["ignore", fd(logPath), fd(logPath)], cwd });
  child.unref();
}
```

Properties retained as guidance for any future detached path:

- `roster.mjs` stays the executor; the hook decides and detaches (`0006` §4 survives).
- `detached: true` + `.unref()` so the hook exits immediately and the child survives it.
- **stdio to a file, never `"ignore"`** — a background failure with no output is undiagnosable, and this is
  the one path with no human watching.
- **No `shell: true`.** Argv only. A member name reaching `/bin/sh` from a config file is an injection
  surface with no reason to exist.

### 5.1 Failure observability

Ultra-Advisor sub-answer (b), settled: log-only is sufficient **provided failure never blocks** — a failed
background spawn degrades to today's subagent dispatch, so there is nothing to halt for. But the surfacing
(next-session state block line, `/hierarchy status`) is **load-bearing**: it is the only thing between a
silently-broken mechanism and a user who believes it works.

## 6–9. Was: files, verification, non-goals, escalation

Not reproduced in full — the file list and the 14 test cases described an implementation that is not
happening. Two items are worth carrying forward if a zero-turn design is ever revisited:

- The security test that mattered most: a **`repo`-level (committed) roster with `onMissing:"auto"` and
  `source:"startup"` must produce no spawn and no spawn attempt.** That is the `git clone` scenario.
- The asymmetry test: dispatch-time spawning must still work at repo level, or a suite that only asserts
  "repo never pre-warms" passes just as happily when the whole feature is broken.

The escalation question, answered: *is a repo-scoped roster adequate authorisation for creating live agent
sessions with no synchronous supervisor?* **No — but the fix was to narrow the predicate to `repo-user`,
not to add a consent mechanism.**

## 10. The lesson worth keeping

My original §3.2 reasoned about roster levels by **scope** — how many repos they affect — and concluded
repo-level was narrow enough. The right axis is **provenance** — who could have written the file. On that
axis repo-level is the **widest** of the three, not the middle one, because it is the only level a *third
party* can write.

This generalises past this spec. Any future feature that keys a privilege off "which level did this config
resolve from" should ask who can write that level, not how far it reaches.

## 11. Possible successor — `0023`, if ever

An acknowledged repo-level roster: a one-time, per-repo acknowledgment in `gates.jsonl` promoting a
committed `auto` to pre-warm eligibility, which is what a team sharing a roster would want. It needs its
own spec — the acknowledgment would be a **durable, cross-session** consent record, a different animal
from `0009`'s session-scoped answers, and it must answer what happens when the committed roster changes
under an existing acknowledgment. **Recorded so the idea is not lost. Not scheduled, and moot unless a
zero-turn design is revived.**
