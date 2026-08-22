# Spec 0002 — `roster.mjs` spawn-shape defects: `--model inherit` and namespace release lag

Status: draft (defects observed 2026-08-22 during a live `/agent-roster create` in `~/git/repos/wrangl`)
Terms: see `agent-hierarchy/CONTEXT.md` (Roster, Route, Auto-mode, Team, Check-in registry)
Related: `docs/specs/0001-agent-roster.md` §6 (`create` — instantiating a Team)

## 1. Goal

Fix `spawnShape()` in `hooks/roster.mjs` so the spawn commands it emits are directly
runnable, and close the release gap that let an already-fixed defect reach a user.

Both defects originate on a single line — `hooks/roster.mjs:132`, the `agentFlags`
array inside `spawnShape()`.

## 2. How this surfaced

A `/agent-roster create` run against `wrangl` produced a plan whose `spawn.steps`
could not be executed as given. The orchestrating session copied the emitted steps
verbatim, which is exactly what `0001` §6 step 3 instructs it to do — the steps are
presented as concrete commands, so treating them as authoritative is the intended
behaviour, not operator error.

The run was aborted before any agent started. Two panes were split and closed.

## 3. Defect A — `--model inherit` is emitted literally

**Severity: live defect, present in source at 0.32.0 and in every installed cache.**

Line 132 builds the model flag as:

```js
member.model ? `--model ${member.model}` : null
```

`inherit` is a legal *config* value meaning "omit the `model` parameter". It is
never a model id. `commands/hierarchy.md` states this in two places, and
`lib-config.mjs` resolves it correctly for the Agent-tool path — the resolver's own
output annotates it (`inherit* … * inherit = omit the model parameter, never pass
"inherit"`). `spawnShape()` is the one place that does not honour it.

`ROLE_DEFAULTS.implementor` is `{ model: "inherit" }`, so **the default roster hits
this on every create.** A roster built entirely from defaults emits:

```
herdr agent start <repo>-implementor --kind claude --pane <id> -- \
  --agent ah:implementor --model inherit --permission-mode <mode>
```

`--model inherit` is not a valid model id, so the implementor pane fails to start.
Under `0001` §6 step 5 that is a partial check-in, and the Team commits degraded —
missing the one member that does the building.

### 3.1 Required change

Treat `inherit` as absent when building the flag, not as a value:

```js
member.model && member.model !== "inherit" ? `--model ${member.model}` : null
```

The check belongs in `spawnShape()` rather than at the call site: the same array
feeds all three transport branches (`herdr` L135, `tmux` L136, `terminal` L137), so
one guard covers every transport.

### 3.2 Why not fix it in the roster instead

Storing the implementor with no `model` key would also avoid the flag, but it
discards information: `inherit` is a deliberate, distinct choice from "unset", and
`lib-config.mjs` and `roster.mjs show` both surface it as such. The roster schema is
correct; the flag builder is what is wrong.

## 4. Defect B — the `ah:` rename shipped to source but not to the cache

**Severity: not a source defect. A release/install gap that presented as one.**

The agents were renamed from `agent-hierarchy:<role>` to `ah:<role>`. Source at
version `0.32.0` reflects this — line 132 reads `` `--agent ah:${member.role}` ``,
and the only remaining `agent-hierarchy:` strings anywhere in the tree are 39
occurrences confined to `docs/retired/` (historical design docs; correctly left
alone).

The newest installed cache is `0.31.0`, where line 132 still reads
`` `--agent agent-hierarchy:${member.role}` ``. That single line is the **only**
difference in `roster.mjs` between the two versions:

```
132c132
<   const agentFlags = [`--agent ah:${member.role}`, …
---
>   const agentFlags = [`--agent agent-hierarchy:${member.role}`, …
```

So every peer-routed member planned from the installed plugin names an agent type
that no longer resolves, and all peer spawns fail — while a reader of the source
tree sees correct code and cannot reproduce it.

### 4.1 Required change

No source edit. Ship `0.32.0`. Ten versions are stacked in the cache directory
(`0.12.1` … `0.31.0`), so installs are landing routinely; this one simply has not.

### 4.2 The part worth fixing

The failure mode is the real finding: a `spawnShape()` regression is invisible until
a human runs `create` and watches panes die. Nothing compares the emitted `--agent`
value against the agent types that actually exist.

`tests/test-*.sh` is standalone bash with no harness (per `0001` §2). A test in that
style should assert that for a roster exercising every role, each emitted step's
`--agent` argument names an agent definition present in `agents/`, and that no step
contains `--model inherit`. Both are string assertions over `create --plan` output —
no spawning, no transport, no live session.

That test fails today on the `inherit` bug alone, which is the point: it would have
caught Defect A at author time and Defect B at install time.

## 5. Change list

| File | Change |
|---|---|
| `hooks/roster.mjs` L132 | Guard `inherit` in the `--model` flag (§3.1) |
| `tests/test-roster-spawn.sh` (new) | Assert emitted `--agent` types exist; assert no `--model inherit` (§4.2) |
| — | Release `0.32.0` so the `ah:` rename reaches installs (§4.1) |

## 6. What must NOT change

- The roster schema. `inherit` stays a storable, displayable member model.
- `docs/retired/**`. Its `agent-hierarchy:` strings are historical record.
- `0001` §6's instruction that the orchestrator spawns from the plan's emitted
  steps. The steps must become correct; the contract that they are runnable as
  given is the right one and should hold.

## 7. Verification

1. `roster.mjs create --plan` on a default roster (implementor model `inherit`)
   emits no `--model` flag for the implementor, and `--agent ah:implementor`.
2. A roster with an explicit `--model opus` still emits `--model opus`.
3. All three transport branches (`herdr`, `tmux`, `terminal`) are covered by 1–2.
4. The new test fails against `0.31.0` and passes against a fixed `0.32.0`.

## 8. Open items

- Whether `spawnShape()` should validate `member.model` against the per-role valid
  sets (`commands/hierarchy.md`: reasoning roles reject `haiku`; `ultra-advisor` is
  `fable`/`opus` only). Out of scope here — `inherit` is a type error, whereas an
  out-of-set model is a policy question, and the CLI does not currently validate
  `--model` or `--auto-mode` on `add`/`edit` either.
- Whether the plan should carry a checksum or version stamp so an orchestrator can
  notice it is planning from a stale install.
