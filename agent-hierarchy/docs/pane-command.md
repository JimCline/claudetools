# Spec — `/agent-hierarchy:pane`

Design spec for a new command in the `agent-hierarchy` plugin. Written by the
Architect; implementable with no other context. Nothing in this document has
been executed by its author — every empirical claim is either a **verified
finding** handed down by the Orchestrator (marked `[A]`–`[L]`), a **settled
NEEDS-EVIDENCE result** (§15.1, measured on Claude Code v2.1.223), or an open
**NEEDS-EVIDENCE** item in §15.2.

---

## 0. Revision log

### Revision 3 — 2026-08-06 (post-smoke-test)

Amendments from the first live end-to-end run. The happy path **passed**; the
same run also exposed a **two-sources-of-truth** defect in agent-definition
resolution that the pass had concealed. Read this list first if you have seen
revision 2.

| What changed | Where |
| :-- | :-- |
| **E5 and E6 SETTLED**, both by live measurement. `#{pane_pid}` is `claude` itself and is its own **process-group leader**; the iTerm2 AppleScript **does** return the child session id (`701F8E11-663E-4E29-AD53-9458DE5C230A`). | §15.1, §13.3, §12.2, §13.1 |
| **Teardown now kills the process GROUP**, guarded by a `pgid === pane_pid` check. The single-pid kill left no strays in one clean run, but `claude` spawns ~6 MCP-server children in its own group and one run is not proof. | §13.3 |
| **NEW DEFECT — `pane.mjs` and Claude Code can read different copies of the same agent definition.** Under a local-path marketplace, hooks resolve from the **live checkout** while `pane.mjs` resolves from `installed_plugins.json`'s cache `installPath`. Policy computed from one copy, applied to an agent the harness resolved from the other. | §6.1, **§6.3a**, §11.3, §13.1, §16 |
| **Resolution now reads BOTH copies and takes the safe union.** It never silently prefers one, and it shows both in the confirmation when they differ. `installed_plugins.json` remains the **only** way a cache *version* is ever chosen, and the cache is still never globbed. | §6.3a |
| **The permission gate is inverted to fail SAFE** — prompt unless a definition positively proves execution is denied. This is what makes the divergence non-blocking. | **§14.1a** |
| **The live smoke test is recorded as a *conditional* pass**, not a verification: it ran under a local-path marketplace, with new hooks, against a cache-resolved definition. | §17.2 |
| **New: E12** — which copy does `claude --agent` itself read? Verified for hooks, **not** for agent definitions. Deliberately non-blocking. | §15.2 |

### Revision 2 — 2026-08-06

Amendments folded in from empirical results and user decisions. Read this list
first if you have seen revision 1.

| What changed | Where |
| :-- | :-- |
| **E1, E2, E3 settled** — `--agent` enforces tool restrictions; both SessionStart and Stop carry `agent_type`; it is **Stop** that fires, with `last_assistant_message` populated. | §15.1, §3, §8, §9 |
| **Agent teams claim withdrawn.** `claude --help` on v2.1.223 has zero "team" matches. §2 rewritten; **Q1 closed — build it.** E9 deleted. | §2, §19 |
| **`--tmux` assessed** (new platform capability). Rejected for pane *creation* with reasons; open question for the iTerm2 *presentation* layer only. | §2.3, E10 |
| **PRE-EXISTING BUG found in shipped code** — `isSubagent()` misclassifies every top-level `claude --agent …` session. Now a required fix, recommended as a **separate prior release**. | §8.1, §8.2, §18 |
| **The env var is still the gate, `agent_type` is the identity check.** The dispatch proposed gating on `agent_type`; that is weaker and more expensive. Reasoning in §9.3. | §8.2, §9.3 |
| **New hazard closed: env-var inheritance to a grandchild session.** A paned Implementor that shells out to `claude` would have hijacked the reply. Two new gates. | §9.3, §9.4 |
| **Q2 answered — orientation inverted.** `v` = vertical divider = **side by side**; `h` = horizontal divider = **stacked**. | §10.2, §12.2 |
| **Q3 answered — per-role permission split.** Implementor gets `acceptEdits`; everything else prompts normally. Non-role agents specified. | §14.1 |
| **Q4 answered — `model: inherit` allowed**, drift documented in user-facing docs, not only here. | §7.2, §18 |
| **New finding from E1's data:** a paned role has a **different tool surface** than the same role as a subagent — same denials, different base set. | §3.1, E11 |
| §6.5's hand-rolled frontmatter fallback **deleted** (E1 resolved in its favour). | §6.5 |

---

## 1. Goal

Add `/agent-hierarchy:pane`, a command that launches a file-backed agent as a
**real, interactive, top-level Claude Code session** inside a tmux pane. The user
can watch it and type into it. The Orchestrator delegates work to it and gets an
answer back — subagent semantics, interactive worker.

The settled user decisions this spec implements:

1. The pane is a **restricted role** — real tool restrictions from the agent's
   definition, not a full-tools peer session.
2. **Any file-backed agent** is launchable, not just the five hierarchy roles.
3. **Only the Orchestrator may initiate.** The pane can only ever reply.
4. The Orchestrator **must prompt the user** before sending work to a pane. The
   pane answers automatically.
5. The Orchestrator **does not need to be running inside tmux**.
6. The **artifact convention survives**: a paned Architect still writes its spec
   file and reports the path, exactly as the subagent does.
7. *(Q2)* The orientation letter names the **divider**: `v` = vertical divider =
   panes side by side; `h` = horizontal divider = panes stacked.
8. *(Q3)* Permission mode is **per role**: Implementor gets `acceptEdits`;
   every other agent prompts normally.
9. *(Q4)* `model: inherit` is **allowed**, and the resulting model drift is
   documented rather than prevented.

### Non-goals

- Pane-to-pane communication. Panes have no address for each other.
- Nested panes. A paned agent may not open panes.
- Replacing the subagent path. `/pane` is for work the user wants to *watch*.

---

## 2. Does the platform already do this? — resolved: no

> **Amended, revision 2.** Revision 1 opened with a fork built on a claimed
> "agent teams" feature. That claim is withdrawn. This section now records what
> the platform actually offers on the installed version, and why none of it
> replaces `/pane`.

### 2.1 Agent teams — claim WITHDRAWN

Revision 1 quoted `code.claude.com/docs/en/agent-teams` as if verbatim from live
documentation, and built a whole decision fork on it. **`claude --help` on
v2.1.223 is 230 lines and contains zero matches for "team".** There is no
team-related flag on the installed binary.

Being precise about what that does and does not prove:

- It **does** prove there is no agent-teams *CLI surface* on this version, so
  nothing in this spec may depend on one.
- It does **not** strictly prove the feature does not exist —
  `CLAUDE_CODE_EXPERIMENTAL_*` features are env-gated and would not appear in
  `--help` by nature.

Regardless, the Architect cannot substantiate those quotes against the installed
version. They came from model training, not from a fetch, and presenting them as
verbatim documentation overstated their standing. **They are withdrawn as a
load-bearing premise, and E9 is deleted.** Nothing else in this spec depends on
them.

By contrast, the `--agent` claims in §3 are *not* in this category: E1 confirmed
them empirically (§15.1). That is the difference between a doc quote and a
measurement, and it is why E1 was made blocking.

**Q1 is closed: build `/pane`.** Decisions 3 and 4 — one-way initiation and a
per-send user confirmation — are the point of the feature, and no platform
primitive expresses either.

### 2.2 `claude agents` — different product surface

`claude agents` manages **background** agents ("sessions dispatched from agent
view"). Background is the opposite of what `/pane` is for: the whole premise is a
session the user can *watch* and *type into*. Not an alternative. No further
evaluation warranted.

### 2.3 `--tmux` — assessed, rejected for creation

`claude --help`, lines 192–195, verbatim:

```
--tmux    Create a tmux session for the worktree ... native panes when available;
          use --tmux=classic for traditional tmux.
```

Claude Code does have a tmux + native-panes primitive. **It cannot be used for
pane creation in this design.** Three disqualifiers, each independent, and none
of them is something the flag text could be hiding:

1. **It is worktree-scoped.** It creates a session *for the worktree*. `/pane`
   must run the pane in the Orchestrator's own `cwd` (§12.1 passes `-c "$CWD"`);
   silently relocating a paned Implementor into a fresh worktree would change
   what it edits.
2. **It is inside-out.** `--tmux` is a flag on the session that *is being
   launched*, arranging its own terminal. `/pane` needs an **outside** caller to
   create a **detached, named** session and then drive it. `--tmux` offers no
   documented session name, so there is nothing to `paste-buffer` into. §13.4
   forbids discovering it by scanning, and that rule is not negotiable.
3. **No environment injection.** §9.3 requires `tmux new-session -e` to plant
   `AGENT_HIERARCHY_PANE_*` in the child. `--tmux` exposes no equivalent, and
   without it the pane has no address for its reply.

**Decision: `open` continues to run `tmux new-session -d` itself (§12.1).**
Confidence: high — the three disqualifiers are structural, not gaps in the help
text.

**Not settled:** whether `--tmux`'s "native panes when available" machinery could
replace the AppleScript/iTerm2 presentation layer (§12.2) and, with it, findings
[G] and [H] including the focus-targeting bug. That machinery is internal to the
launching session and there is no documented way to invoke it from a parent
process, but the question is worth ten minutes. → **E10 (§15.2).** Until E10
runs, §12.2 ships as written. Do **not** assume `--tmux` solves it.

---

## 3. The design pivot: `--agent` — CONFIRMED BY MEASUREMENT

The original dispatch asked for a translation layer that reads an agent's
frontmatter and hand-assembles `--append-system-prompt`, `--model`, and
`--disallowedTools`. **That layer must not be built.** The CLI already does it,
and E1 confirmed it live.

**E1 result (§15.1), v2.1.223.** A session launched as
`claude -p '…' --agent agent-hierarchy:architect` reported its toolset as exactly:

```
Agent, Read, ReportFindings, ScheduleWakeup, Skill, ToolSearch, Workflow, Write
```

`Bash`, `Edit`, and `NotebookEdit` were **absent** — not merely discouraged.
Those are precisely the three the `agent-hierarchy:architect` definition denies.
`--agent` takes the namespaced `plugin:agent` form and enforces the definition's
restrictions on the main thread.

So the launch is one flag, and it satisfies user decision 1 with no parsing.

**Consequences:**

- Local agent-definition resolution is still needed, but only for
  **validation, model policy, and refusal** (§6) — never to build the prompt.
- **§6.5's hand-rolled fallback is deleted.** Do not build it. Do not build a
  frontmatter → CLI translation layer of any kind.
- `initialPrompt` frontmatter still needs handling — see §6.5.

### 3.1 New finding: a paned role's tool surface differs from the subagent's

E1's toolset is worth reading twice. It contains `ReportFindings`,
`ScheduleWakeup`, and `Workflow` — tools the same Architect does **not** have as
a subagent. It does **not** list `Grep` or `Glob`, which the Architect's own
contract calls its instruments.

The likely explanation for the absences is **tool deferral**: `ToolSearch` is
present, and under deferral most tools are reachable only after a `ToolSearch`
call, so they do not appear in an initial roster. That is a plausible reading,
not a verified one.

Either way, the structural fact stands and must be documented:

> **A paned role has the same *denials* as the subagent role, but a different
> *base* tool set.** `--agent` applies the definition's restrictions to whatever
> toolset that session would otherwise have, and a top-level interactive session
> does not have the same toolset as a spawned subagent.

Consequences:

- `agents/*.md` bodies that name specific tools ("Read, Grep, and Glob are your
  instruments") may be describing tools the pane cannot see. → **E11 (§15.2)**
  settles whether `Grep`/`Glob` are reachable in a paned Architect.
- The pane has the **`Agent` tool**. It genuinely can dispatch subagents. §8.3
  point 6 ("do not open panes") is therefore a live restriction, not a
  formality — and it does *not* forbid ordinary subagent dispatch, which remains
  correct behaviour for a paned Architect.
- Combined with Q4's model drift (§7.2), a paned role differs from the subagent
  role along **two** axes: model *and* tool surface. Both belong in the
  user-facing docs (§18), not only here.
- **Revision 3:** this also bounds how much a definition's `tools:` allowlist can
  ever tell us about a pane's real capability, which is why the permission gate
  must fail safe rather than trust it. See §14.1a.

---

## 4. Files to create and change

| Path | Action |
| :-- | :-- |
| `agent-hierarchy/commands/pane.md` | **New.** The command surface. Separate file, not a `hierarchy.md` subcommand — already decided, because `hierarchy.md` is 280 lines and every `/hierarchy status` would otherwise load the pane docs too. |
| `agent-hierarchy/hooks/pane.mjs` | **New.** Helper CLI holding all the mechanics. See §5. |
| `agent-hierarchy/hooks/lib-pane.mjs` | **New.** Registry, mailbox, tmux, and iTerm2 primitives, imported by `pane.mjs` and `stop-pane-relay.mjs`. |
| `agent-hierarchy/hooks/stop-pane-relay.mjs` | **New.** The Stop-hook reply relay. §9. |
| `agent-hierarchy/hooks/lib-config.mjs` | **Edit.** Fix `isSubagent()` (§8.1) and add `isTopLevelAgentSession()` / `hierarchyRoleOf()`. **This is the pre-existing-bug fix.** |
| `agent-hierarchy/hooks/sessionstart.mjs` | **Edit.** Three-way branch. §8. |
| `agent-hierarchy/hooks/hooks.json` | **Edit.** Register `Stop`. Update the `description`. |
| `agent-hierarchy/tests/test-pane.sh` | **New.** §17. |
| `agent-hierarchy/tests/test-sessionstart-agent.sh` | **New.** §17.1a — the bug-fix tests, separable from `/pane`. |
| `agent-hierarchy/README.md` | **Edit.** §18. |
| `agent-hierarchy/plugin.json` | **Edit.** Version bump. §18. |
| `.claude-plugin/marketplace.json` | **Edit.** Version bump. §18. |

> **Amended, revision 3.** Everything in the table above has now been
> implemented. Revision 3 adds no new files. Its changes — §6.3a (definition
> divergence), §14.1a (fail-safe permission gate), §13.3 step 2 (process-group
> kill), §12.2/§13.1 (E6 settled), §16 (one config key), and tests 25–32 in
> §17.1b — land in `hooks/lib-pane.mjs`, `hooks/pane.mjs`, `tests/test-pane.sh`,
> `commands/pane.md`, and `README.md` only.

### What must NOT change

- The Orchestrator directive text in `lib-config.mjs` `buildDirective()`, other
  than an optional single sentence pointing at `/pane`. The pane protocol is a
  **separate** string; do not fold it into `buildDirective`.
- `lib-config.mjs` `resolveConfig()` / `subagentType()` semantics. `/pane` is a
  consumer of the config, not an author of it.
- `gate.mjs`, `lib-gate.mjs`, `pretooluse-ultra-gate.mjs`, `lib-usage.mjs`,
  `subagentstop-usage.mjs` — untouched.
- Behaviour for an **ordinary** top-level session (payload has neither
  `agent_type` nor `agent_id`) must be **byte-identical** to today. Test 6a
  (§17) asserts this.
- Behaviour for a **subagent** must remain "inject nothing".
- Existing state files (`agent-hierarchy.json`, `.usage.jsonl`, `.gate.json`)
  keep their shapes. Pane state is new, separate files.
- **Revision 3:** `canExecute()`'s fail-safe behaviour on empty frontmatter.
  See §14.1a — it looks like a redundancy and it is not.

> **Amended, revision 2.** Revision 1 said "the existing `isSubagent()` guard in
> `sessionstart.mjs` stays exactly as it is." **That is now false** — the guard
> is wrong and must be fixed. See §8.1.

---

## 5. Architecture: a helper CLI, not model-written bash

**Decision.** All mechanics live in `hooks/pane.mjs`, invoked by the command
file. The command file tells the model *which* subcommand to run and how to
present the result — matching the house style already used by `hierarchy.md`:

> Run the resolver command above and show its output verbatim … Do not
> recompute the table yourself.

**Rationale.** Atomic rename, append-only fold, tmux buffer quoting, AppleScript
window-walking, pid reaping, and timeout polling are all things a model
generating one-off bash gets wrong intermittently and silently. They belong in
tested code. This also mirrors the existing `gate.mjs` / `usage-report.mjs`
pattern, so it is not a new convention.

### 5.1 `pane.mjs` interface

All subcommands print a human-readable block on stdout, plus `--json` for a
machine-readable form. Exit `0` on success, `1` on a user-correctable error
(with a one-line reason on stderr), `2` on a refusal (§13).

```
node pane.mjs open  --agent <name> --orient <right|below>
                    [--model <alias>] [--permission-mode <mode>]
                    [--cwd <dir>] [--no-iterm] [--dry-run]
node pane.mjs list  [--json]
node pane.mjs send  --key <key> [--timeout <seconds>]      # prompt on STDIN
node pane.mjs peek  --key <key> [--lines <n>]
node pane.mjs close --key <key> | --all
node pane.mjs doctor
```

`send` reads the prompt from **stdin**, never argv. This is the whole quoting
story: the model heredocs the prompt into `pane.mjs`, which pipes it to
`tmux load-buffer -b <name> -`. No prompt text ever passes through a shell
word-splitting boundary.

`--dry-run` on `open` performs all validation, resolution, and registry-record
construction, prints the argv it *would* run, and exits without invoking tmux.
Several tests in §17 depend on it; it is required, not optional.

---

## 6. Agent resolution

### 6.1 What resolution is for

Not for building the prompt (§3). It exists to:

- **Validate** before launching, so a bad name fails in 50 ms instead of
  spawning a pane that dies silently.
- **Report** the resolved definition path in the confirmation line, so the user
  can see *which copy* is being used.
- **Apply model policy** (§7) and **permission policy** (§14.1, §14.1a).
- **Refuse built-ins** (§6.4) and **detect `initialPrompt`** (§6.5).

> **Amended, revision 3.** Revision 2 carried this as a parenthetical: *"Known
> hazard: a local-checkout marketplace can disagree with the installed cache."*
> That hazard has now been **measured**, it is more serious than a display
> problem, and it has its own section. **Read §6.3a before implementing any of
> this.** Resolution does not select which agent runs — the harness does that —
> so a wrong file is not a wrong agent; it is *wrong policy applied to the right
> agent*, which is the more dangerous shape because nothing looks wrong.

### 6.2 Resolution order

Mirrors the documented precedence table, highest first. Managed settings and
`--agents` are out of scope (a fresh process has neither).

| # | Scope | Where |
| :-- | :-- | :-- |
| 1 | Project | `<cwd>/.claude/agents/**/*.md` |
| 2 | User | `~/.claude/agents/**/*.md` |
| 3 | Plugin | via `~/.claude/plugins/installed_plugins.json` (**and §6.3a**) |

For scopes 1 and 2, match on the frontmatter `name:` field, **not the
filename** — the docs are explicit that "The filename doesn't have to match."
Scan recursively; on a duplicate `name` within one scope, take the
lexicographically first path and emit a warning naming both.

Scopes 1 and 2 have exactly one copy of a file by construction and are not
affected by §6.3a.

### 6.3 Plugin resolution — installed_plugins.json ONLY

**Hard requirement: never glob the plugin cache.** Multiple plugin versions
coexist under `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, and a
glob picks an arbitrary one.

`~/.claude/plugins/installed_plugins.json` has this shape (verified on this
machine):

```json
{
  "version": 2,
  "plugins": {
    "<pluginId>@<marketplace>": [
      {
        "scope": "user",
        "installPath": "/Users/…/.claude/plugins/cache/claudetools/task-gopher/0.8.0",
        "version": "0.8.0",
        "installedAt": "…",
        "lastUpdated": "…",
        "gitCommitSha": "…"
      }
    ]
  }
}
```

Algorithm for an agent name of the form `plugin:agent` or `plugin:sub:agent`:

1. Split on the **first** `:`. Left side is the plugin id, right side is the
   remaining path.
2. Find every key in `plugins` whose portion before `@` equals the plugin id.
   If none, refuse: *"no installed plugin named `<id>`"*.
3. The value is an **array** of install records. Choose one: prefer
   `scope: "project"`, then `"user"`; among ties prefer the record whose
   `installPath` exists on disk; among remaining ties take the highest
   `version` by semver, then the newest `lastUpdated`. Refuse if no chosen
   `installPath` exists.
4. Look for `<installPath>/agents/<remaining path with ':' → '/'>.md`.
   So `agent-hierarchy:architect` → `<installPath>/agents/architect.md`;
   `my-plugin:review:security` → `<installPath>/agents/review/security.md`.
5. If absent, refuse and list the `.md` basenames actually present in
   `<installPath>/agents/` — that error is what tells the user they typed
   `reviewers` instead of `reviewer`.

Call the result the **recorded copy**. Record `installPath` and the resolved
`.md` path in the registry.

> **Amended, revision 3.** The recorded copy is no longer the whole story, and
> the confirmation line no longer echoes a single path unconditionally. Continue
> to **§6.3a**, which is a required part of `open`.

> Note: plugin agent names are namespaced `plugin:agent`, and the bare name does
> not resolve. Match anchored on `(^|:)name$`, never on a bare substring, or a
> same-named agent from a different plugin will match too.

### 6.3a Two sources of truth — the divergence rule (NEW, revision 3)

> **This is the defect the live smoke test exposed.** It is not hypothetical and
> it is not cosmetic.

**What was measured.** `claudetools` is registered in
`~/.claude/plugins/known_marketplaces.json` as:

```json
"claudetools": {
  "source": { "source": "directory", "path": "/Users/jimcline/git/repos/claudetools" },
  "installLocation": "/Users/jimcline/git/repos/claudetools",
  "lastUpdated": "2026-07-19T15:00:29.501Z"
}
```

— a **local-path marketplace**, whose `installLocation` *is* the working
checkout. Claude Code resolved this plugin's **hooks** from that checkout: a
brand-new `hooks/stop-pane-relay.mjs` fired inside a pane even though the cached
tree contained no such file and no `Stop` entry in its `hooks.json`. Meanwhile
`installed_plugins.json` records

```
agent-hierarchy@claudetools → /Users/…/.claude/plugins/cache/claudetools/agent-hierarchy/0.7.0
```

which is a real directory (not a symlink) and is genuinely behind the checkout.
`pane.mjs` therefore resolved `…/0.7.0/agents/architect.md` and printed that path
in its confirmation. **New relay code ran against a cache-resolved definition.**

Four of the ten marketplaces on the development machine use
`"source": "directory"`. This is not an exotic configuration; it is what every
plugin author has.

**What the divergence actually endangers.** `claude --agent <plugin:name>` means
*Claude Code* resolves the agent. `pane.mjs` reading a definition does **not**
select which agent runs, and cannot. What it drives is **policy**:

| Policy | Reads the definition? | Consequence of reading a stale copy |
| :-- | :-- | :-- |
| Validation / built-in refusal (§6.4) | yes — needs *a* file to exist | a rename reads as "no such agent" against the wrong copy. Annoying, safe, self-announcing. |
| Model policy (§7) | **no** for the five hierarchy roles — `resolveConfig()` is the source. The definition's `model` matters only for non-role agents. | drift on non-role agents only, and §7.2 already documents model drift as an accepted property of panes. |
| `initialPrompt` warning (§6.5) | yes | a newly-added `initialPrompt` goes unwarned. Token waste, not a safety issue. |
| **Permission gate (§14.1a / `canExecute`)** | **yes** | **a definition that newly gains `Bash` or `Edit` does not trigger the prompt** — while the pane still gets the capability, because the harness resolved the other copy. This is the security-relevant one, and it is the only one. |

The asymmetry is exact, and the whole design turns on it: reading the *older*
copy is dangerous **only** in the direction "the newer definition is *more*
capable." A newer definition that *removes* capability makes the gate
over-prompt, which is harmless.

**Current state, measured.** `architect.md`, `implementor.md`, and `reviewer.md`
are **byte-identical** between the checkout and the cached `0.7.0` tree today.
The drift the smoke test hit was in `hooks/`, not in `agents/`. So the divergence
is **latent, not active**: the smoke test's policy happened to be correct, by
coincidence rather than by construction. That is precisely why this is a required
guard and *not* a release blocker (§18).

#### The decision — read both, prefer neither, take the safe union

Three options were considered. Rejecting two:

- ***Mirror Claude Code's own resolution*** (honour `known_marketplaces.json` the
  way the harness does). **Rejected.** The precedence is undocumented; we
  verified it for **hooks** and not for **agent definitions**, which are a
  different subsystem (→ E12); and a helper that guesses at an internal
  resolution order fails the same way again the first time the harness changes
  its mind — only *silently*, because it would then believe it was right. Buying
  correctness with an unverifiable assumption is how this defect happened.
- ***Silently prefer one copy.*** **Rejected outright.** Whichever we picked, the
  confirmation line would assert a definition the pane may not be running under,
  and the user would have no way to tell. A wrong answer that announces itself is
  strictly better than a right answer that cannot be checked.

What ships instead:

1. **`installed_plugins.json` remains the ONLY way a cache version is chosen.**
   §6.3's hard rule is unchanged and unweakened: **never glob
   `~/.claude/plugins/cache/`.** That rule exists because multiple versions
   coexist under `…/<plugin>/<version>/` and a glob picks an arbitrary one.
2. **Additionally**, compute a **live-checkout candidate**, when and only when one
   exists. *This does not violate rule 1, and the reason is the crux:* a
   local-path marketplace has **no version directories at all** — the checkout
   *is* the source tree, exactly one copy per plugin, nothing to choose between.
   There is no arbitrary pick to make, so the failure the rule guards against
   cannot occur. Every path below is constructed from named manifest fields; none
   is discovered by globbing or `readdir`.

#### Resolving the live-checkout candidate — deterministic, no globbing

1. From the plugin id, take its `@<marketplace>` key in `installed_plugins.json`
   (§6.3 step 2 already found it).
2. Look that marketplace up in `~/.claude/plugins/known_marketplaces.json`.
   Treat it as local-path **iff** `source.source === "directory"` **and**
   `source.path` is a non-empty string. Measured values of `source.source` on
   this machine: `"directory"`, `"github"`, `"git"`. For `github` and `git` there
   is exactly one copy and this entire subsection is inert.
3. `root = installLocation || source.path`. If `root` is not an existing
   directory, abandon the live candidate (warn once).
4. Read `<root>/.claude-plugin/marketplace.json` and find the entry in `plugins`
   whose `name` equals the plugin id. Its `source` field is a **relative path
   string** — measured: `"source": "./agent-hierarchy"`. If `source` is absent,
   is not a string, or resolves outside `root` after normalisation, **abandon the
   live candidate** and record `definition_source: "recorded-only"` with a
   warning. **Do not guess a layout** — in particular, do not assume
   `<root>/<pluginId>`; that happens to be right for `claudetools` and is not a
   documented invariant.
5. Live candidate = `<root>/<that relative path>/agents/<name path>.md`, using
   the same `:` → `/` mapping as §6.3 step 4.

#### The rule when the two candidates disagree

Applies to **`open` only**. `send`, `peek`, `close`, and `list` never re-resolve
a definition — they read the registry record written at creation (§13.4 rule 1).

| Case | Behaviour |
| :-- | :-- |
| No live candidate (not a local-path marketplace, or step 3/4 abandoned) | §6.3 exactly as before. `definition_source: "recorded"`. |
| Both exist, **byte-identical** | No divergence. `definition_source: "identical"`. Display the recorded path only. **Say nothing else** — this is the normal case and it must stay quiet, or the warning becomes noise and stops being read. |
| Only one of the two exists | Use the one that exists. `definition_source: "recorded-only"` or `"live-only"`. Warn, naming the path that is missing. |
| Both exist and **differ** | **Divergence** — see below. |

On divergence, all five of these:

1. **Compute every definition-derived policy over BOTH copies and take the
   conservative result of each:**
   - `canExecute` → `canExecute(recorded) || canExecute(live)`. If *either* copy
     can execute, ask.
   - Haiku-for-a-reasoning-role refusal (§7.1) → refuse if *either* resolves to
     Haiku.
   - `initialPrompt` warning (§6.5) → warn if *either* declares it.
   - Built-in / missing-file refusal (§6.4) → unchanged; by construction a file
     exists on at least one side.

   **This is what makes E12 non-blocking.** The safe answer does not depend on
   knowing which copy the harness picked, because the more-capable copy is always
   one of the two.
2. **Show both paths in the confirmation** (§11.3), labelled, and say plainly
   that they differ and what was done about it.
3. **Record both in the registry** (§13.1) with `definition_source: "divergent"`.
4. **Never use mtime to pick a winner, or to decide which is "newer".** Measured
   on this machine, the *cache* copy of `architect.md` has the **later** mtime
   (Aug 4) than the *checkout* copy (Jul 31), because installation copies files.
   mtime records when a file was written, not whether its content is current.
5. **The default action is WARN, not refuse** — `panes.onDefinitionDivergence`
   (§16), default `"warn"`. Refusing by default would make `/pane` unusable
   inside the very repository that develops it, where the checkout is ahead of
   the cache as a matter of ordinary work. **Point 1 is what earns the right to
   warn rather than refuse**; without the union rule, warn-and-continue would be
   the silently-prefer-one option wearing a disclaimer. Setting the key to
   `"refuse"` exits 2 on divergence and names both paths.

The warning must be actionable, not merely alarming:

```
Note: two copies of agent-hierarchy:architect are on disk and they differ.
  live checkout   /Users/…/claudetools/agent-hierarchy/agents/architect.md
  installed copy  /Users/…/cache/claudetools/agent-hierarchy/0.7.0/agents/architect.md
claudetools is a local-path marketplace, so Claude Code may launch this pane
from either copy. The permission and model policy shown below was computed
from BOTH, taking the stricter answer of each.
Resync with: /plugin marketplace update claudetools
```

#### `doctor` gains a divergence check

For every entry in `installed_plugins.json` whose marketplace resolves as
local-path (steps 2–4 above), compare the recorded `<installPath>/agents/` tree
against the live `<root>/<source>/agents/` tree and report, per plugin: identical
/ N files differ / M files present on only one side. Name the resync command.
**This is where a stale cache should be noticed** — at `doctor` time, deliberately
— not at `open` time under time pressure with a user waiting.

`doctor` compares `agents/` only. Divergence in `hooks/`, `commands/`, or `skills/`
is real (it is what the smoke test hit) but it is the platform's business, not
`/pane`'s, and reporting it would put `/pane` in the position of auditing the
harness.

### 6.4 Built-ins: REFUSE (policy, not capability)

`Explore`, `Plan`, `general-purpose`, `claude`, `statusline-setup`, and
`claude-code-guide` are harness built-ins compiled into Claude Code. They have
no definition file on disk.

**Decision: refuse, by policy.** Reasoning:

- The premise of the feature (user decision 1) is a **restricted role whose
  restrictions come from a definition**. With no definition we cannot validate
  what the pane may do, cannot report it in the confirmation line, and cannot
  record it meaningfully in the registry. The user would be approving a send to
  a role nobody can describe.
- `claude` and `general-purpose` are all-tools. Launching one produces exactly
  the "full-tools peer session" decision 1 rejects.
- `Explore` and `Plan` are read-only and short-lived. The subagent path already
  serves them better, cheaper, and without a billed interactive session.
- Approximating them by hand-writing a system prompt would be fabricating a role
  the harness defines differently, and it would drift silently on every upgrade.

Refusal message:

```
Explore is a Claude Code built-in with no definition file on disk.
/pane launches file-backed agents only, because the pane's restrictions
come from its definition. Use the Agent tool for built-ins.
```

**This is a policy refusal, not a claim that it would fail.** `claude --agent
Explore` may well work, since the harness resolves the name internally. Keep the
door open with a config key `panes.allowBuiltins` (default `false`, §16); when
true, the refusal downgrades to a warning and the registry records
`agent_source: "builtin"` with a null definition path. Do not implement any
approximation.

> **Revision 3:** when `allowBuiltins` is true, `canExecute` has no definition to
> read, so §14.1a's invariant makes it `true` and the permission question is
> always asked for a built-in. That is the correct outcome and it must not be
> special-cased away.

### 6.5 `initialPrompt`

> **Amended, revision 2.** The "frontmatter fallback path" that used to occupy
> the rest of this section is **deleted**. E1 resolved in favour of `--agent`
> (§3), so there is nothing to fall back to. Do not build
> `--append-system-prompt` / `--tools` / `--disallowedTools` assembly.

Read the resolved definition's frontmatter and act on two fields:

- **`initialPrompt` present** → the pane will auto-submit a first turn the
  instant it opens, before any `pending` token exists. Per §9 that turn is
  correctly swallowed (no pending → no relay), so it is not a correctness bug,
  but it burns tokens the user did not ask for and may leave the pane mid-work
  when the first real send arrives. **Warn at open time** and name the field.
  Do not refuse.
- **`background: true`** → irrelevant to a top-level session. Ignore.

Under divergence, "the resolved definition's frontmatter" means both copies, per
§6.3a point 1.

---

## 7. Model resolution

1. **If `<agent>` is one of the five hierarchy roles** (`ultra-advisor`,
   `architect`, `reviewer`, `implementor`, `task-runner` — matched anchored on
   `(^|:)role$`), take the effective model from
   `resolveConfig(cwd).roles[role].model` by **importing `lib-config.mjs`**. Do
   not reimplement config resolution or re-read the JSON.
2. **`inherit` means OMIT `--model` entirely.** Never pass the literal string
   `inherit`; it is not a valid `--model` value. `--model` accepts an alias
   (`sonnet`, `opus`, `haiku`, `fable`) or a full model id.
3. **Non-role agents**: pass no `--model`. `--agent` applies the definition's own
   `model`, which itself defaults to `inherit`.
4. **`--model <alias>` on the command line** overrides both. Validate against the
   four aliases plus `^claude-[a-z0-9.-]+$`; refuse anything else.

Note for §6.3a: steps 1 and 2 read `resolveConfig()`, **not** the definition
file, so the five hierarchy roles' model policy is immune to definition
divergence entirely. Only step 3 touches the file.

### 7.1 Haiku is never valid for a reasoning role

Reasoning roles are `ultra-advisor`, `architect`, `reviewer`, and `implementor`
(the Implementor writes code — that is reasoning). Only `task-runner` may be
Haiku, and it defaults to Haiku.

If the model resolved by steps 1–4 is `haiku` (or a `claude-haiku-*` id) for a
reasoning role, **refuse the open**:

```
Refusing to open a pane: architect resolves to haiku, and reasoning roles
run on Sonnet, Opus, or Fable only. Fix with /hierarchy set architect opus,
or pass an explicit --model.
```

*Assumption I could not verify by reading:* `lib-config.mjs` may already reject
this at config-write time. If it does, this check is belt-and-braces and should
stay anyway — `/pane --model` is a new write path that bypasses config
validation entirely.

### 7.2 `model: inherit` drift — ACCEPTED by the user (Q4), and it must be documented

`model: inherit` on a **subagent** means "the model of the main conversation."
A pane **has no main conversation** — it *is* a main conversation. So a paned
Implementor with `model: inherit` runs on **the user's default model**, not on
whatever the Orchestrator is currently running.

**User decision (Q4): allow it.** Omit `--model` and let the session default
apply. Do **not** require an explicit `--model` on every open.

The Orchestrator cannot fix, detect, or correct this: hook payloads carry no
model field, so it cannot reliably learn its own model. Surface it instead. Three
places, all required:

1. **The confirmation line**, whenever the resolved model is `inherit`:

```
model: (inherited — the pane will use your default model, not the
Orchestrator's current one). Pass --model to pin it.
```

2. **`commands/pane.md`** — a short paragraph under a "Known differences from a
   subagent" heading.
3. **`agent-hierarchy/README.md`** (§18) — the same paragraph. **This is the one
   the user actually reads**, and Q4's answer was explicitly "document the
   drift", so a spec-only note does not discharge it.

The paragraph must say all three of:

> A paned role may run on a **different model** than the same role would as a
> subagent. It may also have a **different tool surface** (§3.1). The
> Orchestrator cannot detect either difference, and cannot correct it. Pass
> `--model` to pin the model; there is no equivalent for the tool surface.

---

## 8. Hook 1 — `sessionstart.mjs`: a pre-existing bug, and the pane branch

### 8.1 REQUIRED FIX — `isSubagent()` is wrong today, independent of this feature

Current shipped code, `agent-hierarchy/hooks/lib-config.mjs:112–115`:

```js
export function isSubagent(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.length > 0;
}
```

`agent-hierarchy/hooks/sessionstart.mjs:32` guards the entire body with
`if (!isSubagent(input)) { … }`, and the file's own comment (lines 9–12)
justifies it as *"belt-and-braces only: SessionStart fires for the main session
alone."*

**E2 falsified that assumption.** A top-level `claude --agent <plugin:name>`
session has a SessionStart payload of:

```
session_id, transcript_path, cwd, agent_type, hook_event_name, source
```

`agent_type` is `"agent-hierarchy:architect"`; `source` is `"startup"`; there is
**no `agent_id`**. So `isSubagent()` returns `true`, and a genuine top-level
session is misclassified as a subagent and gets **nothing injected**.

**This is live in shipped code today.** Anyone running `claude --agent …`
silently gets no agent-hierarchy context at all. It is not caused by `/pane` and
it does not need `/pane` to fix.

**The correct discriminator is `agent_id`, not `agent_type`.** `agent_type` is
set on *both* subagents and top-level `--agent` sessions; `agent_id` is set only
on subagents.

```js
export function isSubagent(input) {
  // agent_type alone is NOT a subagent marker: a top-level
  // `claude --agent <name>` session sets it too (verified, v2.1.223).
  const id = input && input.agent_id;
  return typeof id === "string" && id.length > 0;
}

export function isTopLevelAgentSession(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.length > 0 && !isSubagent(input);
}

export function hierarchyRoleOf(agentType) {
  // anchored (^|:)role$ — the same matcher §7 uses, for consistency
  // returns "architect" | … | null
}
```

**Also update the JSDoc block at the top of `sessionstart.mjs`** (lines 9–21).
Its stated premise is now false and a future reader would re-derive the same bug
from it. Rewrite the "Gating" list to match §8.2. This is not drive-by comment
editing — the comment is the thing that was wrong.

**Risk, stated plainly.** `agent_id`-on-subagent-payloads is carried as a
verified fact from prior sessions, but this Architect could not verify it *for
SessionStart specifically* by reading. If SessionStart fires for subagents and
those payloads lack `agent_id`, this change would leak the Orchestrator directive
into subagents — the exact failure the original guard exists to prevent. Two
things bound that risk:

- The platform, per the file's own comment, does not fire SessionStart for
  subagents at all. The guard is belt-and-braces by its author's own account.
- §8.2's case 3 means even a leaked hierarchy-role subagent gets the **role
  notice**, not "You are the Orchestrator".

Confidence: **medium-high**. If the Orchestrator wants it airtight, add a
one-line evidence item: dispatch any subagent with a SessionStart hook attached
and dump the payload. It is cheap and it removes the last doubt.

### 8.2 The three-way branch

> The dispatch's phrasing was *"gate on `agent_type`, address by env var."* For
> SessionStart that is not quite right, and the difference matters: `agent_type`
> is set on **every** `claude --agent …` session, including ones the user
> launched by hand with no pane anywhere. Injecting "you are in an
> agent-hierarchy pane, your final message is relayed" into such a session would
> be a lie. **The env var is the gate for pane-ness; `agent_type` is the
> identity and the bug fix.** Same conclusion in §9.3, for a different reason.

Four cases, in this order:

| # | Condition | Inject |
| :-- | :-- | :-- |
| 1 | `AGENT_HIERARCHY_PANE_DIR` set | the **pane protocol** (§8.3) |
| 2 | else `isSubagent(input)` (`agent_id` set) | nothing |
| 3 | else `isTopLevelAgentSession(input)` **and** `hierarchyRoleOf(agent_type)` is non-null | the **role-session notice** (§8.4) |
| 4 | else | **unchanged**: directive / nudge / silence, exactly as today |

Case 3 is deliberately narrow. A top-level `--agent` session running a
*non-hierarchy* agent falls to case 4 and gets the ordinary directive, because it
is a legitimate main session that may orchestrate. A top-level `--agent` session
running a *hierarchy role* must never be told it is the Orchestrator — that is
§8.5's failure mode arriving by a second route.

Known, accepted imprecision: `hierarchyRoleOf` uses the anchored `(^|:)role$`
matcher, so a foreign `someplugin:architect` is treated as a hierarchy role. The
notice is generic enough that the false positive is harmless, and consistency
with §7 is worth more than the precision. A tighter matcher
(`^agent-hierarchy:role$` or a bare `role`) is a valid alternative if the
Implementor prefers it; say which was chosen.

### 8.2a Implementation shape — exactly ONE write to stdout

```js
const input = await readHookInput();

let context = null;

try {
  const paneDir = process.env.AGENT_HIERARCHY_PANE_DIR;
  if (paneDir) {
    context = buildPaneProtocol({
      role: input.agent_type || process.env.AGENT_HIERARCHY_PANE_ROLE || null,
      declaredRole: process.env.AGENT_HIERARCHY_PANE_ROLE || null,
      key: process.env.AGENT_HIERARCHY_PANE_KEY || null,
    });
    try { recordPaneSession(paneDir, input); } catch { /* §8.2b */ }
  }
} catch {
  context = null;
}

if (!context) {
  if (isSubagent(input)) {
    // nothing — unchanged intent
  } else if (isTopLevelAgentSession(input) && hierarchyRoleOf(input.agent_type)) {
    context = buildRoleSessionNotice(hierarchyRoleOf(input.agent_type), input.agent_type);
  } else {
    const resolved = resolveConfig(input.cwd || process.cwd());
    if (!resolved.configured) context = buildNudge(resolved);
    else if (resolved.enabled) context = buildDirective(resolved, input.session_id);
  }
}

if (context) emit(context);   // the ONLY stdout write in the file
```

Three implementation traps, all load-bearing:

1. **One emit site.** A hook that writes two JSON objects to stdout produces
   malformed output and the harness silently drops the injection. Build the
   string, then write once. Never `emit()` inside a branch and fall through.
2. **`sessionstart.mjs` has no try/catch anywhere in its 52 lines.** Do **not**
   wrap the whole file — that would change existing failure behaviour silently
   and is out of scope. Wrap **only** the new pane branch, so a broken pane path
   falls through to the correct pre-existing behaviour instead of taking the
   whole hook down.
3. **`buildPaneProtocol` builds a string and does no I/O.** The filesystem write
   is `recordPaneSession`, separately guarded, because a stale env var pointing
   at a deleted mailbox dir must not cost the session its protocol injection.

`buildPaneProtocol`, `buildRoleSessionNotice`, and `recordPaneSession` live in
`lib-pane.mjs`, **not** in `lib-config.mjs`, and must not be reachable from
`buildDirective`. (`isSubagent` / `isTopLevelAgentSession` / `hierarchyRoleOf`
*do* belong in `lib-config.mjs` — they are session classification, not pane
mechanics, and the bug fix must be shippable without `lib-pane.mjs` existing.)

### 8.2b `recordPaneSession` — the session-identity file

Writes `<paneDir>/session` as JSON:

```json
{ "session_id": "…", "agent_type": "agent-hierarchy:architect", "at": "…" }
```

**First-writer-wins**: create with an exclusive flag (`wx`); if it already
exists, leave it alone and do not error. The pane's own boot is the first
SessionStart that can possibly run against that directory, so the first write is
the real one.

This file exists for one reason: §9.4's session gate. See §9.3 for the hazard it
closes.

### 8.3 The injected pane protocol — required content

Exact wording is the Implementor's, but every one of these must appear. This
text owns the **top slot** of the pane session's injected context (plugin
convention: one plugin owns the top slot).

1. **Identity.** "You are running as `<role>` in an agent-hierarchy pane. You are
   NOT the Orchestrator. Do not decompose-and-dispatch; do the role's own work."
2. **One channel, inbound only.** "You have exactly one channel: you answer the
   turn you were given. You cannot initiate contact with the Orchestrator, and
   there is no tool and no address for doing so. Your final assistant message IS
   your reply; it is captured automatically."
3. **The reply is the whole payload.** "Only your final assistant message is
   relayed. Thinking, tool output, and intermediate turns are discarded. Make the
   final message a complete, standalone answer."
4. **The artifact convention survives** (user decision 6). "If you produce an
   artifact — a spec file, a diff, a report — write it to disk and put the
   ABSOLUTE PATH in your final message. Do not paste the artifact into the
   reply."
5. **The human may type here.** "A human may type into this pane directly. That
   input is the user's own instruction and you should treat it as such. Note that
   a turn the Orchestrator did not solicit is not relayed anywhere — that
   conversation is between you and the human only."
6. **No nesting.** "Do not open panes. Do not run `/agent-hierarchy:pane`." —
   note this is a live restriction: E1 confirmed the pane **has** the `Agent`
   tool (§3.1). Ordinary subagent dispatch remains allowed; panes do not.
7. **Role contract still applies.** "Your `agents/*.md` body governs. Nothing
   here relaxes it."

Point 5 is a free and pleasant consequence of the pending-token design (§9):
user-initiated turns are *naturally* private to the pane.

**Role mismatch.** If `input.agent_type` is non-empty and differs from
`AGENT_HIERARCHY_PANE_ROLE`, trust the **payload** for the identity in point 1
(it is what the session actually is) and append one line: *"(Note: this pane was
opened for `<declaredRole>`; the session reports `<agent_type>`. Tell the user.)"*
That mismatch means an env var reached a session it was not meant for, and it is
better surfaced than swallowed.

### 8.4 The role-session notice (case 3) — new in revision 2

Short. Three sentences, no table, no protocol:

> You are running as `<agent_type>` as the **main session** of this Claude Code
> instance, launched with `--agent`. The agent-hierarchy Orchestrator protocol
> does **not** apply to you: do not decompose-and-dispatch, and do not treat
> yourself as the top of the chain. Your `agents/*.md` body governs.

It must **not** contain the string `You are the Orchestrator`, must not contain
the role→model table, and must not mention panes or relays (there is no pane
here).

### 8.5 Why any of this matters (finding [E])

A fresh session is currently told, verbatim: *"Agent hierarchy ACTIVE. You are
the Orchestrator."* A paned Architect that received that would boot believing it
is the Orchestrator, and would start dispatching. §8.2 case 1 prevents it for
panes; case 3 prevents it for hand-launched role sessions.

---

## 9. Hook 2 — the Stop relay, and the pending-token protocol

### 9.1 Why this shape — E3 CONFIRMED IT

**E3 result (§15.1).** In a `claude --agent …` session it is **`Stop`** that
fires, not `SubagentStop`, and `last_assistant_message` is fully populated.
Observed Stop payload keys:

```
session_id, transcript_path, cwd, prompt_id, permission_mode, agent_type,
effort, hook_event_name, stop_hook_active, last_assistant_message,
background_tasks, session_crons
```

The reply design survives unchanged. The `SubagentStop` contingency in
revision 1's E3 is dead — do not register `SubagentStop`, and do not touch the
existing `SubagentStop` usage collector.

Finding [C] still governs the source: **do NOT parse `transcript_path` at Stop
time — it is racy.** Measured: the hook saw 23 transcript lines while the
finished file had 27; the assistant's text entry was not yet flushed (only its
`thinking` block existed) and extraction returned 0 chars. Reading
`last_assistant_message` returned the correct answer immediately.

Finding [F]: the relay fires **only when a `pending` marker exists**. Both
branches verified — a solicited turn relayed correctly; an unsolicited turn
logged "stayed silent" and wrote nothing.

**This is what enforces user decision 3.** The pane cannot initiate because
there is no mechanism for it to, not because it was told not to. The pane agent
needs no tool and no address to reply.

### 9.2 State layout

Plugin convention: state lives in the user's own Claude config directory, not in
the version-pinned plugin cache, so it survives plugin auto-updates.

```
~/.claude/agent-hierarchy.panes.jsonl          append-only registry event log
~/.claude/agent-hierarchy.panes/<key>/         per-pane mailbox
    session                                    written by SessionStart (§8.2b)
    pending                                    presence == a send is outstanding
    task.<reqid>.md                            long prompts (§10.4)
    reply.<reqid>.json                         written by the Stop hook
    log.jsonl                                  append-only per-pane audit
```

`<key>` is `ah-<orch8>-<roleslug>-<n>`: `ah-`, the first 8 chars of the
Orchestrator's `session_id`, the agent name with `:` and `/` → `-`, and a
monotonic counter. It is also the tmux session name. Constrain to
`^ah-[a-z0-9-]{1,60}$` and reject anything else before it reaches a shell.

### 9.3 Env vars: the GATE and the ADDRESS are the same variable

Set by `open` via `tmux new-session -e`:

| Var | Value | Read by | Purpose |
| :-- | :-- | :-- | :-- |
| `AGENT_HIERARCHY_PANE_DIR` | absolute path to the mailbox dir | both hooks | **gate + address** |
| `AGENT_HIERARCHY_PANE_ROLE` | the agent name as given, e.g. `agent-hierarchy:architect` | both hooks | identity cross-check |
| `AGENT_HIERARCHY_PANE_KEY` | the pane key | both, for logging | logging |

**Why not gate on `agent_type` (correcting the dispatch's framing).** Both
payloads carry `agent_type`, so gating on it is *possible* — but for the Stop
relay it is strictly worse on two counts:

- **Precision.** `agent_type` is set on every `claude --agent …` session on the
  machine, pane or not. It does not distinguish a pane from a hand-launched
  role session, so it cannot be the gate; the dir would still have to be
  consulted, and absent-dir would still have to exit.
- **Cost.** Reading `AGENT_HIERARCHY_PANE_DIR` is one `process.env` lookup with
  no imports. Reading `agent_type` requires consuming and parsing stdin first.
  The relay runs on **every Stop in every session on the machine**; the env-var
  fast path is the cheapest possible no-op.

`agent_type` is genuinely valuable — but as an **identity check**, not a gate.
See gate B below.

**The hazard that makes the identity check load-bearing.** Env vars are
inherited by child processes. A paned **Implementor** (or `task-runner`) has
`Bash`, so it can run `claude …` as a subprocess. That grandchild inherits
`AGENT_HIERARCHY_PANE_DIR`, and its Stop hook would write `reply.<reqid>.json`
into the *parent pane's* mailbox and consume the pending token. The Orchestrator
would then receive an answer from an unvetted grandchild, attributed to a trusted
role. That is a correctness **and** trust failure, and §9.4's gates B and D close
it.

### 9.4 `stop-pane-relay.mjs` — exact behaviour

```
A. dir = process.env.AGENT_HIERARCHY_PANE_DIR
   if (!dir) exit 0 silently, WITHOUT reading stdin.   ← every non-pane session
B. read the payload. If AGENT_HIERARCHY_PANE_ROLE is set and
   input.agent_type !== AGENT_HIERARCHY_PANE_ROLE:
        append {"ev":"foreign","reason":"agent_type",
                expected, got: input.agent_type ?? null, at} to <dir>/log.jsonl
        exit 0.                                        ← grandchild / wrong session
C. read <dir>/pending.
   missing or unparseable  → append {"ev":"silent", at} to <dir>/log.jsonl
                           → exit 0.                   ← the pane cannot initiate
D. if pending.expect_session is a non-empty string and
   input.session_id !== pending.expect_session:
        append {"ev":"foreign","reason":"session_id",
                expected: pending.expect_session, got: input.session_id, at}
        exit 0.                                        ← belt-and-braces on B
E. reqid = pending.reqid
F. write <dir>/reply.<reqid>.json.tmp :
     { reqid, answered_at, session_id, agent_type, transcript_path,
       text: input.last_assistant_message ?? "" }
   then rename → <dir>/reply.<reqid>.json              ← atomic; never a partial read
G. unlink <dir>/pending                                ← consume the token
H. append {"ev":"replied", reqid, at, chars} to <dir>/log.jsonl
I. exit 0
```

**Step order F-then-G is load-bearing.** If the process dies between them the
reply exists and `pending` survives, so the Orchestrator retries or sees a
stale-pending error. Unlinking first and crashing would lose the reply and erase
the evidence.

**Gates B and D never consume the pending token.** A rejected foreign Stop must
leave `pending` untouched so the real pane can still answer. Only step G removes
it, and only after a reply has landed.

Wrap the whole body in `try { … } catch { }` and always `exit 0`. A broken hook
must never block the session it is attached to. (`sessionstart.mjs` is *not*
wrapped this way; per §8.2a, do not retrofit it — guard only the new branch.)

`stop_hook_active` is present in the payload. If it is true, still relay — a
continuation turn is the answer. Do not special-case it.

`permission_mode` and `effort` are present in the payload. Record `permission_mode`
in the reply record; it is free diagnostic value when §14 fires a stall.

### 9.5 Registering the hook

Add to `hooks.json`:

```json
"Stop": [
  {
    "matcher": "*",
    "hooks": [
      { "type": "command",
        "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/stop-pane-relay.mjs\"" }
    ]
  }
]
```

Finding [D]: plugin `hooks.json` **does** load in a fresh/pane session, and
`--settings <file>` **merges** rather than replaces. So the pane hooks belong in
agent-hierarchy's own `hooks.json`, self-gated on the env var. **No generated
settings file is needed** — do not build one.

> **Revision 3, and this is the observation that produced §6.3a:** under a
> local-path marketplace, `${CLAUDE_PLUGIN_ROOT}` resolves to the **live
> checkout**, not to the `installed_plugins.json` `installPath`. This is how the
> smoke test's brand-new `stop-pane-relay.mjs` ran at all. It is verified for
> hooks and **not** for agent definitions (→ E12).

`hooks.json` currently registers `SessionStart`, `PreToolUse`, and
`SubagentStop`. `Stop` is a fourth, additive entry; do not merge it into the
`SubagentStop` block.

The cost of this on ordinary sessions is one `node` process per Stop that reads
one env var and exits. Keep it that cheap: no imports beyond `node:process` on
the fast path, and read `AGENT_HIERARCHY_PANE_DIR` **before** stdin and before
any other import work. Update the `hooks.json` `description` string to mention
the Stop hook and its env gate.

---

## 10. Command surface

### 10.1 Grammar

```
/agent-hierarchy:pane <agent> [v|h|right|below]   open a pane running <agent>
/agent-hierarchy:pane open <agent> [v|h|…]        explicit form
/agent-hierarchy:pane list                        show live panes
/agent-hierarchy:pane ask <key|agent> <text…>     send work (user-confirmed)
/agent-hierarchy:pane close <key|agent>           close one
/agent-hierarchy:pane close all                   close every pane
/agent-hierarchy:pane doctor                      dependency + health check
```

`open`, `list`, `ask`, `close`, and `doctor` are **reserved first words**. An
agent genuinely named one of them is shadowed; `open` is the documented escape
(`/pane open list v`). State this in `pane.md`.

Frontmatter for `commands/pane.md`, matching the one-key house style of
`hierarchy.md`:

```yaml
---
description: Launch a file-backed agent as an interactive Claude Code session in a tmux pane you can watch and talk to, and delegate work to it. Usage: /pane <agent> [v|h] | list | ask <key> <text> | close <key|all> | doctor
---
```

### 10.2 `<v|h>` — orientation. THE LETTER NAMES THE DIVIDER.

> **Amended, revision 2 — this is an inversion of revision 1.** Q2 is settled by
> the user. Revision 1 made the letter follow tmux; it now follows the divider.
> If you are porting anything from revision 1, re-read this table.

**The letter names the DIVIDER, not the stacking direction:**

- **`v`** = **v**ertical divider = panes **side by side** = new pane **to the RIGHT**
- **`h`** = **h**orizontal divider = panes **stacked** = new pane **BELOW**

**This is the feature's single most likely bug, because the two backends
disagree.** iTerm2's naming *matches* the divider convention; tmux's *inverts*
it:

| user says | means | registry | iTerm2 AppleScript | tmux (documentation only) |
| :-- | :-- | :-- | :-- | :-- |
| `v` / `right` / `r` | side by side | `"right"` | `split vertically with default profile` | `split-window -h` |
| `h` / `below` / `b` | stacked | `"below"` | `split horizontally with default profile` | `split-window -v` |

Two rules follow, both mandatory:

1. **Never echo a flag back to the user.** Every confirmation, every registry
   field, and every log line says `right` or `below` **in words**. The registry
   stores `orientation: "right" | "below"`, never `-h`/`-v`, never `v`/`h`.
   Confirmations read *"opened to the right"* / *"opened below"*.
2. **Translate at exactly one boundary** — the AppleScript call site in
   `lib-pane.mjs` — and nowhere else.

**The tmux column is documentation only.** §10.3's one-session-per-pane decision
means `split-window` is never invoked; `open` always calls `new-session`. Keep
the tmux column in the table anyway: it is the inverted one, and without it a
future maintainer adding a real split will "correct" the mapping and silently
flip every pane.

**Also accept `right`, `below`, `r`, `b`** as unambiguous aliases, and prefer
them in all documentation and examples. Prefer them in the command file's own
usage string too — the letters are the trap, the words are not.

### 10.3 `<v|h>` has no referent on the first pane

There is nothing to split against yet. Resolved by a structural decision:

**Decision: one tmux session per pane.** `open` always runs
`tmux new-session -d`, never `tmux split-window`.

Rationale: independent lifecycle (closing one pane cannot disturb another),
trivially unique `pane_id`/`pane_pid`, and `kill-session` becomes exactly
per-pane. It also relocates `<v|h>` to the only place it has a visible meaning —
**the optional iTerm2 presentation split** (§12.2), which is where the user
actually sees geometry.

So:

- **With iTerm2**: `<v|h>` places the iTerm2 pane relative to the Orchestrator's
  own pane. Confirmation: `opened below` / `opened to the right`.
- **Without iTerm2**: `<v|h>` is inert. Confirmation says so explicitly:
  `orientation ignored (no iTerm2 presentation layer); attach with:
  tmux attach -t <key>`.

### 10.4 Sending work: prompt delivery

Finding [B], verified. **Use exactly this, in this order:**

```bash
tmux load-buffer  -b <buf> -            # heredoc via stdin — no quoting hazard
tmux paste-buffer -b <buf> -p -t <pane_id>
tmux send-keys    -t <pane_id> Enter    # separate, deliberate submit
tmux delete-buffer -b <buf>             # cleanup
```

- `-p` is **bracketed paste**: multi-line text stays intact, lands as a
  `[Pasted text #1 +N lines]` chip, and **does not auto-submit**.
- Plain `send-keys` with embedded newlines submits on the first newline and
  mangles `$`, backticks, and quotes. **It is WRONG for prompts.**
- Verified round trips: `BANANA 3`, `MANGO 3`, `PANE OK 2` — correct line counts
  every time. Revision 3: `SMOKE` also round-tripped live in ~2s.

`<buf>` is `ahp-<reqid>`. Delete it after pasting so buffers do not accumulate.
(`paste-buffer -d` would also work but was not what was verified; keep the
verified invocation and clean up separately.)

**Long prompts go through a file, not the paste.** Any prompt over **2000
characters** is written to `<paneDir>/task.<reqid>.md`, and the pasted text
becomes a short pointer:

```
Your task for this turn is in /Users/…/task-<reqid>.md — read that file
and carry it out. Reply per your pane protocol.
```

Rationale: finding [B] verified short round trips; a 300-line paste is a
different regime and this sidesteps it entirely, is cheaper, and leaves the task
on disk for the user to read. NEEDS-EVIDENCE **E8** only decides whether long
inline pastes are *additionally* allowed — it does not gate this design.

### 10.5 Send sequence, end to end

```
1. Resolve <key> (§10.6). Refuse per §13 if the target is bad.
2. If <paneDir>/pending exists → refuse: "pane <key> is still working on
   request <reqid> (sent <n>s ago). Wait, or run /pane peek <key>."
3. reqid = crypto.randomUUID()
   expect_session = JSON.parse(<paneDir>/session).session_id, or null if the
   file is missing or unreadable. (Missing means the pane has not booted its
   SessionStart yet — warn, do not refuse; gate B in §9.4 still applies.)
4. AskUserQuestion — the confirmation (§11.1). Abort on anything but Send.
5. If prompt > 2000 chars → write task.<reqid>.md; replace the paste text.
6. Write <paneDir>/pending.tmp then rename → pending.
     { reqid, sent_at, from_session, expect_session, summary }
   Written BEFORE the paste, so a fast pane cannot Stop before the token exists.
7. load-buffer / paste-buffer -p / send-keys Enter / delete-buffer.
8. Poll <paneDir>/reply.<reqid>.json every 2s until it appears or timeout.
   (Measured round trip, finding [K]: ~4–7s on Haiku; ~2s live in the §17.2
   smoke test.)
9. Print the reply text verbatim, plus reqid, elapsed seconds, and char count.
   If <paneDir>/log.jsonl gained a "foreign" event during the wait, surface it
   — that is the grandchild hazard (§9.3) firing, and it must not look like a
   plain timeout.
```

Step 6 before step 7 is required. Writing `pending` after the paste opens a
window where a very fast pane replies into a missing token and is swallowed.

`send` does **not** re-resolve the agent definition. Everything it needs was
decided and recorded at `open` time (§6.3a, §13.1).

### 10.6 Resolving `<key|agent>`

Accept either the exact key, or an agent name when **exactly one** live pane
runs it. Two live panes for the same agent → refuse and list the keys. This is
resolution against the **registry only** — never by scanning tmux (§13.4).

### 10.7 Output style

Follow `hierarchy.md`: the command file instructs the model to run the helper
and **show its output verbatim**, not to re-render it. The one thing the model
owns is the AskUserQuestion in step 4 and the judgment of what to put in the
prompt.

---

## 11. The user confirmation, and `handoffs: auto|confirm`

### 11.1 Always on, for both `open` and `ask`

User decision 4 is unconditional. The pane confirmation is a **separate,
always-on gate** and it does **not** respect `handoffs: "auto"`.

Rationale to record in the code: `handoffs` governs subagent dispatch, whose
cost is bounded and whose output returns to the Orchestrator alone. A pane send
drives a **long-lived, separately-billed interactive session the user is
watching**, by injecting keystrokes into a terminal. That earns its own
confirmation regardless of the handoff setting.

`open` is gated too — opening a pane starts a billed session.

### 11.2 No double-prompting under `handoffs: "confirm"`

When `handoffs` is `"confirm"`, the directive already tells the Orchestrator to
`AskUserQuestion` before dispatching a role. **The pane confirmation subsumes
it.** One question, not two. State this explicitly in `pane.md` so the
Orchestrator does not stack them.

### 11.3 What the confirmation shows

```
Send to pane ah-3f2a91b0-architect-1?
  agent      agent-hierarchy:architect
  definition /Users/…/cache/claudetools/agent-hierarchy/0.8.0/agents/architect.md
  model      opus
  perms      (normal prompting — will stall if it hits a prompt unattended)
  where      opened to the right  (tmux attach -t ah-3f2a91b0-architect-1)
  work       Design the pane command's registry and teardown
  prompt     "Write a design spec for a new command in the agent-hierarchy…"
             (2,940 chars → delivered as task-<reqid>.md)
```

`perms` is required whenever the resolved mode is anything other than the
default, and required for the Implementor (`acceptEdits`) always — see §14.1.

> **Amended, revision 3 — the `definition` line was misleading.** It printed one
> path as though it were authoritative, while a second copy may have been the one
> the harness launched (§6.3a). Two changes:
>
> - **When `definition_source` is `identical`, `recorded`, `recorded-only`, or
>   `live-only`**, keep the single `definition` line exactly as above. Do not add
>   noise to the common case.
> - **When `definition_source` is `divergent`**, replace that single line with
>   both paths and the §6.3a warning block:
>
> ```
>   definition TWO COPIES DIFFER — policy computed from BOTH (stricter wins)
>     live      /Users/…/claudetools/agent-hierarchy/agents/architect.md
>     installed /Users/…/cache/claudetools/agent-hierarchy/0.7.0/agents/architect.md
> ```
>
> The same rule applies to `open`'s own confirmation, not only to `ask`'s.

Options: **Send** / **Edit the prompt first** / **Do it inline instead** /
**Cancel**. "Do it inline" means the Orchestrator takes that role's contract on
itself for the step, matching the existing `handoffs: confirm` wording.

---

## 12. Portability

### 12.1 tmux is mandatory

Detect with `command -v tmux`. If absent, **refuse — do not fall back to
anything.**

```
/pane needs tmux, which is not on your PATH.
  macOS:  brew install tmux
  Debian: sudo apt install tmux
Then run /pane doctor.
```

`tmux new-session` must always pass `-x 200 -y 50` (finding [A]) — **the 80x24
detached default mangles the Claude Code UI.** Also `-c <cwd>` and one `-e` per
env var from §9.3. Finding [A] confirms an Orchestrator **outside** tmux can
drive a pane, so user decision 5 costs nothing.

Full launch:

```bash
tmux new-session -d -s "$KEY" -x 200 -y 50 -c "$CWD" \
  -e AGENT_HIERARCHY_PANE_ROLE="$AGENT" \
  -e AGENT_HIERARCHY_PANE_KEY="$KEY" \
  -e AGENT_HIERARCHY_PANE_DIR="$DIR" \
  -P -F '#{pane_id} #{pane_pid}' \
  "claude --agent $AGENT $MODEL_FLAG $PERM_FLAG"
```

`$AGENT` is interpolated into a shell command string, so it **must** be
validated against `^[A-Za-z0-9_:-]{1,80}$` before this line runs. Reject
anything else. Same for `$KEY` (§9.2), `$MODEL_FLAG` (§7 step 4), and
`$PERM_FLAG` (§14.1's whitelist). This is the one injection surface in the
feature and it is closed by **whitelist, not by quoting**.

Capture `#{pane_id}` and `#{pane_pid}` **here, at creation** — never rediscover
them later (§13.4, finding [J]). E4 is settled: `-P -F` prints both on one line
(e.g. `%0 58354`), so the `tmux display-message -p` fallback is not needed.

### 12.2 iTerm2 is an OPTIONAL presentation layer

Finding [G]: `osascript` reaches iTerm2 from the Bash tool with no TCC prompt and
no sandbox block. `split vertically with default profile` then
`write text "tmux attach -t <session>"` yields a real iTerm2 pane showing the
tmux session, **still driven entirely by tmux**. This keeps the macOS-only part
to **one optional call at creation**; everywhere else the user runs
`tmux attach` and nothing changes.

See **E10** (§15.2) for whether `claude --tmux`'s native-pane machinery could
replace this layer entirely. Until E10 runs, build this.

**Detection — all three must hold, else skip silently:**

```
process.platform === "darwin"
process.env.TERM_PROGRAM === "iTerm.app"
process.env.ITERM_SESSION_ID is set
```

Plus `--no-iterm` forces the tmux-only path.

**Targeting — finding [H], this cost a misplaced pane when it was got wrong:**

- **NEVER** split `current session of current window`. It follows the user's
  **focus**, so the pane can land in a different tab — potentially inside a
  *different running Claude Code session*. Three others were present when this
  was hit live.
- **NEVER** parse the `w0t2p0` prefix of `$ITERM_SESSION_ID`. It records where
  the session was **born** and goes stale (observed `w0t2p0` for a session
  actually at w1 t4 p1). **Only the UUID is stable.**

Correct form: `UUID="${ITERM_SESSION_ID#*:}"`, then walk windows → tabs →
sessions matching `id of s` against that UUID. Verified to land in the
Orchestrator's own tab regardless of focus.

**Orientation at this boundary — and only at this boundary** (§10.2):

| user says | registry | AppleScript |
| :-- | :-- | :-- |
| `v` / `right` / `r` | `"right"` | `split vertically with default profile` |
| `h` / `below` / `b` | `"below"` | `split horizontally with default profile` |

**Failure is never fatal.** If AppleScript errors, times out, or finds no
matching session, the pane already exists and works. Report:

```
Pane opened (not shown — could not reach iTerm2). Attach with:
  tmux attach -t ah-3f2a91b0-architect-1
```

Give the `osascript` call a hard **5-second timeout**; a hung AppleScript must
not hang the command.

**Shrinkage warning.** Every pane splits the *Orchestrator's own* iTerm2 session,
because that is the only stably-addressable target (finding [H]). At the 3rd
live pane and beyond, add to the confirmation: *"this is pane 3; the
Orchestrator's pane is getting small — consider `tmux attach` in a separate
window instead."*

> **Amended, revision 3 — E6 is SETTLED: the AppleScript does return the child
> session id.** A live split recorded
> `iterm_child_uuid: 701F8E11-663E-4E29-AD53-9458DE5C230A`. So
> `iterm_child_uuid` is now a **required** registry field on a successful split
> (§13.1), `null` only when the split was skipped or failed.
>
> Splitting the *previous* pane instead of the Orchestrator's is therefore
> unblocked — and it is **explicitly deferred past 0.8.0**. Keep splitting the
> Orchestrator and keep the pane-3 shrinkage warning. The deferral is deliberate,
> not an oversight: chained splits need their own decision about what happens
> when a middle pane is closed and its child UUID becomes the anchor for the
> next open. Recording the UUID now is what makes that a later, cheap change.

### 12.3 Non-macOS / non-iTerm2

tmux-only, silently. `list` and `open` both print the `tmux attach -t <key>`
line so the user always has a way in.

---

## 13. Registry, liveness, teardown, and the safety rails

### 13.1 Registry shape

`~/.claude/agent-hierarchy.panes.jsonl`, **append-only** — never
read-modify-write. (Measured on this plugin's sibling state: read-modify-write
under concurrency dropped roughly 4 of 12 writes.) Current state is a **fold**
over the log: a key is live iff its most recent event is `open`.

`{"ev":"open", …}` record — every field is required unless marked:

| Field | Notes |
| :-- | :-- |
| `key` | pane key, also the tmux session name |
| `agent` | as given, e.g. `agent-hierarchy:architect` |
| `agent_source` | `plugin` \| `project` \| `user` \| `builtin` |
| `definition_path` | the **recorded** copy (§6.3), or `null` for a built-in |
| `definition_path_live` | the **live-checkout** copy (§6.3a), or `null` when the marketplace is not local-path or the candidate was abandoned — *new in revision 3* |
| `definition_source` | `recorded` \| `identical` \| `divergent` \| `recorded-only` \| `live-only` \| `builtin` (§6.3a) — *new in revision 3* |
| `install_path` | plugin `installPath`, or `null` |
| `model` | resolved alias, or `null` when `--model` was omitted |
| `permission_mode` | resolved mode, or `null` when the flag is omitted (§14.1) |
| `tmux_session` | == `key` |
| `pane_id` | `#{pane_id}`, e.g. `%17` — **captured at creation** (finding [H]/[L]) |
| `pane_pid` | `#{pane_pid}` — **captured at creation**, required for reaping (finding [J]). E5: this is `claude` itself and leads its own process group. |
| `cwd` | |
| `orchestrator_session_id` | hook `session_id` of the launching Orchestrator |
| `orchestrator_iterm_uuid` | `${ITERM_SESSION_ID#*:}` — **UUID only**, never the `w0t2p0` prefix (finding [H]); `null` off iTerm2 |
| `iterm_child_uuid` | the created pane's id — **E6 settled: the AppleScript does return it.** `null` only when the iTerm2 split was skipped or failed. |
| `orientation` | `"right"` \| `"below"` — words, never a flag and never a letter (§10.2) |
| `created_at` | ISO 8601 |
| `dir` | absolute mailbox path |

`{"ev":"close", "key", "at", "reason"}` where `reason` ∈
`user` | `all` | `dead` | `orphan-reaped`.

**Compaction**, mirroring `pruneUsageFile()`: when the file exceeds 2000 lines,
rewrite it to a `.tmp` containing only the events of currently-live keys, then
atomic-rename. Never rewrite in place.

**Adding `definition_path_live` and `definition_source` is additive.** Older
records lack both; the fold must treat a missing `definition_source` as
`"recorded"` and a missing `definition_path_live` as `null`, and must not
invalidate or rewrite an existing log.

### 13.2 Liveness and pruning

```
tmux has-session -t <key>                          exit 0 → session alive
tmux list-panes  -t <key> -F '#{pane_id}'          must contain the recorded pane_id
```

Both must hold. Run this fold-and-check at the top of `list`, `send`, `peek`, and
`close`; for any key that fails, append `{"ev":"close", reason:"dead"}` and carry
on. Pruning is therefore an append, never a rewrite.

`list -F` on a **key we recorded** is not pane discovery — see §13.4.

### 13.3 Teardown

Finding [J], found during cleanup: **`tmux kill-session` did NOT reliably kill
the Claude Code process inside the pane** — an orphaned `claude` survived and had
to be killed by pid. Without reaping, the feature leaks billed sessions.

> **Amended, revision 3 — E5 is SETTLED and step 2 has changed.** `#{pane_pid}`
> is the `claude` process itself (`comm=claude`, args = the full command), **not**
> an intermediate shell, and `claude` is its own **process-group leader**
> (PGID == `pane_pid`). `pgrep -P <pane_pid>` returns only MCP-server children —
> roughly six of them (`codebase-memory-mcp`, a `godot-mcp` node, an `hy3d`
> `uv`/python, `gemini-media-mcp`, a `nano-banana` node, an `sfx-gen` uv/python)
> — and all of them share that PGID.
>
> One live `close` in the §17.2 smoke test left **no** surviving member of the
> group after the single-pid kill. That is **evidence, not proof**, and it is
> deliberately *not* what this design rests on.

```
1. tmux kill-session -t <key>          (ignore failure — may already be gone)
2. if pane_pid recorded and kill(pane_pid, 0) succeeds:
     pgid = `ps -o pgid= -p <pane_pid>`, trimmed to an integer
     if pgid === pane_pid AND pgid !== (pane.mjs's own pgid):
        target = -pane_pid    ← the process GROUP: claude + its MCP children
     else:
        target = pane_pid     ← single pid; report that children may survive
     kill(target, SIGTERM)
     poll kill(pane_pid, 0) every 250ms for 3s
     if still alive: kill(target, SIGKILL)
3. append {"ev":"close", key, at, reason}
4. leave the mailbox dir on disk (replies and log.jsonl are the audit trail);
   delete mailbox dirs whose key has been closed for >7 days, at `doctor` time
```

**Why the group and not the pid.** The group is exactly
`{claude} ∪ {its MCP servers}` and nothing else, *because `claude` leads it*. So
a group kill is not wider than intended — it is precisely as wide as the pane.
The single-pid kill's failure mode is an MCP server (a `uv`/python or `node`
process) outliving its parent and holding a port, a model handle, or GPU memory.
The smoke test suggests that may not happen often; "not often" is not a teardown
guarantee, and the group kill costs one extra `ps` read.

**Why the `pgid === pane_pid` guard is mandatory, not defensive padding.**
`kill(-N)` addresses *"the process group whose leader is N"*. If `claude` were
not the leader, `-pane_pid` would name **some other group entirely**, and under
pid reuse that could be an unrelated process tree. The guard restricts the group
kill to the exact case E5 measured and falls back to the previously-specced
single-pid kill otherwise. The second half of the guard — refusing when the
pane's pgid equals `pane.mjs`'s own — prevents the pathological case where a
group kill would take down the Orchestrator's own terminal.

`close --all` closes every key live for **this Orchestrator's
`orchestrator_session_id`**, not globally. A global sweep belongs in `doctor`,
where it is explicit.

**Kill safety rails — all mandatory:**

- Only ever kill a pid recorded as `pane_pid` in the registry at creation. Never
  a pid derived from `ps`, `pgrep`, or any live scan. (The `ps -o pgid=` read
  above is a *lookup on a recorded pid*, not a scan for a target.)
- **Never pass a negative argument to `kill` unless `ps` has confirmed
  `pgid(pane_pid) === pane_pid` on that same invocation.** Do not cache it, do
  not infer it from a previous `close`.
- Refuse the group kill if the pane's pgid equals `pane.mjs`'s own pgid.
- Refuse if `pane_pid === process.pid` or `=== process.ppid`.
- Refuse if the recorded `tmux_session` does not match `^ah-`.
- If `pane_pid` was never captured, do **not** guess. Report the orphan and the
  exact command for the user to run.

`doctor` should still report any surviving `claude` whose recorded `ah-*` pane is
dead, and — new in revision 3 — any surviving MCP-server process whose parent pid
is gone and whose pgid matches a closed pane's `pane_pid`. Report only; `doctor`
never kills without being asked.

### 13.4 The "Tmux Self Drive" shape — design away from it

Finding [L]: a subagent doing tmux reconnaissance tripped a security detector for
the shape *"locate its own pane → send itself keystrokes → alter its own
permissions/oversight."* These rules keep `/pane` out of that shape, and they are
correctness rules as much as security ones:

1. **Never discover panes by scanning.** No `tmux ls`, no `list-sessions`, no
   `list-panes` for the purpose of *finding* a target. Every id comes from the
   registry, recorded at creation. `list-panes -t <recorded-key>` for a liveness
   check is fine — it verifies a known id, it does not search for one.
2. **Assert before every send, peek, or kill**: the target key matches `^ah-`
   **and** appears live in the registry.
3. **Hard-refuse sending to the Orchestrator's own pane.** If `$TMUX` is set and
   the target `pane_id === $TMUX_PANE`, refuse. If the target's
   `iterm_child_uuid` equals the Orchestrator's `orchestrator_iterm_uuid`,
   refuse. Splitting the Orchestrator's iTerm2 session is fine; typing into it
   never is. (E6 makes `iterm_child_uuid` reliably present, so this second check
   is now live rather than usually-skipped.)
4. **The only literal keystroke this feature ever sends is `Enter`.** All content
   goes through `paste-buffer`. This is simultaneously the correctness argument
   (finding [B]) and the security argument (finding [L]), and it should be
   written as a comment at the send site.
5. `peek` (`tmux capture-pane -p -t <recorded pane_id> -S -<n>`) is read-only and
   allowed, but only against a registry-recorded `pane_id`, and never against the
   Orchestrator's own.

---

## 14. Permission-prompt stalls

A paned agent that hits a permission prompt with nobody attached blocks the
Orchestrator's wait **indefinitely**. Q3's per-role split (§14.1) reduces this
but **does not remove it**, so everything in this section ships regardless.

- **Default timeout: 300 seconds.** Configurable via `panes.timeoutSeconds`
  (§16). Justified against finding [K]'s measured ~4–7s round trip on Haiku:
  300s is ~40× the observed reply time, which is generous for a real Architect
  turn while still bounded.
- **Poll interval: 2 seconds.**
- **On timeout, never kill.** Print:

```
No reply from ah-3f2a91b0-implementor-2 after 300s (request 8e1c…).
The pane may be sitting on a permission prompt with nobody attached.

  Attach and answer it:  tmux attach -t ah-3f2a91b0-implementor-2
  Peek without attaching: /pane peek ah-3f2a91b0-implementor-2

Last 20 lines of the pane:
  …
```

  Auto-run `peek` and inline the tail — so the user can *see* the prompt without
  attaching. Then offer: **Keep waiting (another 300s)** / **Abandon this
  request** / **Close the pane**. "Abandon" leaves `pending` in place; the reply
  still lands in `reply.<reqid>.json` if the pane finishes later, and `list`
  reports it as an unread reply.

- **`open` must warn at launch time** for any agent whose definition does not
  restrict Edit, Write, and Bash:

```
Note: this agent can edit and run commands, so it will hit permission
prompts. Nobody is attached to answer them. Keep the pane visible, or
attach with: tmux attach -t <key>
```

### 14.1 Permission mode — RESOLVED per role (Q3)

> **Amended, revision 2.** Revision 1 refused to choose and defaulted to "no
> flag for everyone". The user has now settled it.

**User decision (Q3): reasoning roles run with normal prompting — their
restricted toolsets rarely trip one. The Implementor gets `acceptEdits` so it is
not blocked constantly.**

**Resolution order** — first match wins:

| # | Source | Effect |
| :-- | :-- | :-- |
| 1 | `--permission-mode <mode>` on the command line | wins; `bypassPermissions` is **refused** from this path (see below) |
| 2 | `panes.permissionMode` in config (default `null`) | blanket override; applies to **every** pane including reasoning roles |
| 3 | Role default | `implementor` → `acceptEdits`; **everything else** → omit the flag entirely |

**"Everything else" is explicit and covers the case the dispatch asked about:**

| Agent | Mode | Why |
| :-- | :-- | :-- |
| `architect`, `reviewer`, `ultra-advisor` | none (normal prompting) | Q3, verbatim |
| `implementor` | `acceptEdits` | Q3, verbatim |
| `task-runner` | none (normal prompting) | **Architect's call.** Q3 named only the Implementor. `task-runner`'s pain is `Bash`, which `acceptEdits` does not cover, so granting it would buy nothing while widening blast radius. Flagged to the user as **Q5**. |
| **any non-role file-backed agent** | none (normal prompting) | **Architect's call.** The alternative — inferring a relaxed mode from whether the definition grants Edit/Write — means `/pane` unilaterally relaxes oversight for an agent nobody vetted. That is precisely the hazard Q3 was careful about. The blanket `panes.permissionMode` key remains the deliberate opt-in. |

**`acceptEdits` does not cover Bash.** State this in `pane.md` and the README: a
paned Implementor with `acceptEdits` will still stall on `Bash` permission
prompts when it runs tests or builds. §14's timeout, `peek` tail, and attach
message therefore remain mandatory for the Implementor too. Do not let the Q3
answer be read as "the Implementor cannot stall."

**Validation, because `$PERM_FLAG` reaches a shell (§12.1).** Whitelist the mode
against a constant array in `lib-pane.mjs` before interpolation; refuse anything
else with exit 2. The exact accepted set of `--permission-mode` values is
**E7** — until E7 reports, the whitelist contains only `acceptEdits` (the one
value Q3 requires) plus whatever E7 confirms.

**`bypassPermissions`:** refuse from the command line unconditionally; permit it
only via `panes.permissionMode` in a config file. Rationale: a config file is a
deliberate, persistent, reviewable act; a command-line flag typed by a model
mid-conversation is not. This is the Architect's call, and it is flagged as part
of **Q5**.

**Whether the flag works at all under `--agent` is E7, and E7 is now BLOCKING**
for this section: frontmatter `permissionMode` is documented as ignored for
plugin subagents, and whether that carries over to `--agent` is unknown. If E7
shows the flag is ignored, Q3's answer is **unimplementable as stated** and must
go back to the user — do not silently ship an Implementor that still prompts.
(Note: that documentation claim is from the same unverified-doc source as §2.1
and should itself be treated as unconfirmed.)

### 14.1a The permission gate must fail SAFE (NEW, revision 3)

§14.1 decides *which mode* to pass. Separately, `open` **asks the user to choose a
permission mode** for any agent that can execute, and says nothing for read-only
agents — an agent that can only read has no decision to make. That question is
answered by `canExecute(frontmatter)` in `lib-pane.mjs`, and it is the single
place where reading the wrong definition file (§6.3a) turns into a **missing
safety prompt**.

**The contract, stated as an invariant the Implementor must preserve:**

> `canExecute` returns `false` **only** when a definition positively demonstrates
> that both `Bash` and `Edit` are unavailable. Every other input — absent
> frontmatter, absent `tools` *and* `disallowedTools`, an unparseable file, a
> partial parse, a built-in with no file at all, a divergent pair — returns
> `true`.

The shipped implementation already satisfies this for the empty case: with
neither `tools:` nor `disallowedTools:`, `deny` is `[]` and the final expression
`!denies("Bash") || !denies("Edit")` evaluates to `true`. **That is the invariant,
not a redundancy to be tidied away.** A future "simplification" to
`deny.includes("Bash") || deny.includes("Edit")` would invert it and silently
remove the prompt for every unrestricted agent — which is exactly the class of
change a reviewer waves through. Test 25 (§17.1b) pins all four branches.

Three consequences:

1. **Divergence resolves by OR**, per §6.3a point 1:
   `canExecute(recorded) || canExecute(live)`. The stale-definition hazard is
   dangerous only in the "newer copy is *more* capable" direction, and the newer
   copy is always one of the two operands.
2. **A definition that cannot be read is `true`, not an error.** If the file
   resolves but the frontmatter parse yields nothing usable, ask; do not refuse,
   and do not skip. Refusing would turn a parse quirk into an outage; skipping
   would turn it into a silent capability grant.
3. **§3.1's warning applies here too, and it is the deeper limit.** `--agent`
   applies the definition's *denials* to whatever toolset a top-level session
   would otherwise have. A definition's `tools:` **allowlist** therefore
   describes a subagent's roster, not a guarantee about a pane's. **The gate is a
   heuristic in principle**; failing safe is what makes a heuristic acceptable
   here. Do not describe it in `pane.md` or the README as proof that a
   non-prompting pane cannot execute — say that `/pane` asks whenever it cannot
   rule execution out.

---

## 15. NEEDS-EVIDENCE

### 15.1 SETTLED — verified 2026-08-06, Claude Code v2.1.223

Verified via `claude -p '…' --agent agent-hierarchy:architect`, plus the live
`/pane` smoke test (§17.2) for E4–E6. These are now facts and the spec above is
written against them. Kept here as the record of what was measured and what it
decided.

#### E1 — Does `--agent <plugin:agent>` apply real tool restrictions? **YES.** ✅

Session toolset came back as exactly `Agent, Read, ReportFindings,
ScheduleWakeup, Skill, ToolSearch, Workflow, Write`. `Bash`, `Edit`, and
`NotebookEdit` were **absent**, not merely discouraged — matching the
`agent-hierarchy:architect` definition's denials.

**Decided:** build the `--agent` path (§3). **Deleted:** the frontmatter → CLI
translation layer (old §6.5 fallback). **Raised:** §3.1 — the paned tool
*surface* differs from the subagent's even though the *denials* match, and
`Grep`/`Glob` did not appear (→ E11).

#### E2 — Does an `--agent` session have `agent_type` at SessionStart? **YES.** ✅

Payload keys: `session_id`, `transcript_path`, `cwd`, `agent_type`,
`hook_event_name`, `source`. `agent_type` was `"agent-hierarchy:architect"`;
`source` was `"startup"`; **no `agent_id`**.

**Decided:** the discriminator is `agent_id`, not `agent_type` — and that
**falsified the assumption behind shipped code**, producing the required fix in
§8.1. Also decided: `agent_type` is an identity cross-check, not a gate (§8.2,
§9.3).

#### E3 — Does `Stop` fire, with `last_assistant_message`? **YES — `Stop`, not `SubagentStop`.** ✅

Payload keys: `session_id`, `transcript_path`, `cwd`, `prompt_id`,
`permission_mode`, `agent_type`, `effort`, `hook_event_name`,
`stop_hook_active`, `last_assistant_message`, `background_tasks`,
`session_crons`. `last_assistant_message` fully populated.

**Decided:** §9 ships unchanged. Register `Stop` only; the `SubagentStop`
contingency is dead and the existing usage collector is untouched.

#### E4 — Does `tmux new-session -d -P -F '#{pane_id} #{pane_pid}'` print both? **YES.** ✅

Prints both fields on one line, e.g. `%0 58354`.

**Decided:** one call. The `tmux display-message -p` fallback in §12.1 is not
needed and should not be built.

#### E5 — Is `#{pane_pid}` the `claude` process or an intermediate shell? **The `claude` process, and it leads its own group.** ✅

`ps -o pid,ppid,comm -p <pane_pid>` returned `comm=claude` with the full command
as args — no intermediate shell. `pgrep -P <pane_pid>` returned only MCP-server
children (~6 of them). **PGID == `pane_pid`**: `claude` is its own process-group
leader, and every MCP child shares that PGID.

**Decided:** §13.3 step 2 kills the process **group**, guarded by a
`pgid === pane_pid` check plus a self-pgid refusal. Separately observed on one
live `close`: the single-pid kill left no surviving group member. That is
evidence the leak may be narrow; it is **not** why the group kill ships — one
clean run does not establish a teardown guarantee, and the guard makes the group
kill no wider than the pane.

#### E6 — Can the iTerm2 AppleScript return the new session's id? **YES.** ✅

A live split returned the child session id;
`iterm_child_uuid: 701F8E11-663E-4E29-AD53-9458DE5C230A` was recorded.

**Decided:** `iterm_child_uuid` becomes a required registry field on a successful
split (§13.1), which also makes §13.4 rule 3's second self-send check live rather
than usually-skipped. Splitting the *previous* pane instead of the Orchestrator's
is unblocked but **explicitly deferred past 0.8.0** (§12.2) — the chained-split
geometry needs its own decision about closing a middle pane.

#### E9 — Do agent teams already deliver this? **WITHDRAWN.** ❌

`claude --help` (230 lines, v2.1.223) has zero matches for "team". The premise
was unsubstantiable. See §2.1. **Q1 closed: build.**

### 15.2 OPEN

Numbering is stable across revisions — E7, E8, E10, E11 are unchanged. E4, E5,
and E6 moved to §15.1 in revision 3. E12 is new in revision 3.

#### E7 — `--permission-mode`: does it exist, what values, and does it apply under `--agent`? **(BLOCKING for §14.1 / Q3)**

Three questions, one session:

1. `claude --help | grep -A3 -- '--permission-mode'` → does the flag exist on
   v2.1.223, and what is its documented value set? **The whitelist in §14.1 is
   built from this answer**; until then it contains only `acceptEdits`.
2. Launch a paned Implementor with `--permission-mode acceptEdits`, send it work
   requiring a file write, do not attach. Does it write without prompting?
   - **Yes** → Q3 is implementable as specced.
   - **No / flag ignored** → **Q3 is unimplementable. Stop and re-ask the user.**
     Do not substitute a different mode.
3. Same paned Implementor, **no** `--permission-mode`, work requiring a write, do
   not attach, watch for 10 minutes.
   - **Blocks indefinitely** → §14's timeout + attach message is mandatory and
     300s is the right order of magnitude.
   - **Auto-denies after N seconds** → the Stop hook fires with a "couldn't do
     it" message and the relay works normally; the timeout can be much longer.

#### E8 — Does the Claude Code UI accept a bracketed paste of a 300-line prompt at 200x50?

Paste a 300-line prompt whose first and last lines are distinctive, press Enter,
ask the pane to echo both and the total line count.

- **Correct** → long inline pastes may *additionally* be allowed above the 2000-
  char threshold.
- **Truncated or mangled** → the §10.4 file-handoff is the only path, and the
  threshold should drop. Either way §10.4 ships as written; this only widens it.

#### E10 — Can `claude --tmux`'s native-pane machinery replace the iTerm2 layer? *(new in revision 2; affects §12.2 only)*

Pane **creation** is already decided against `--tmux` on structural grounds
(§2.3) — this item is only about the presentation layer.

```bash
claude --help | grep -B2 -A8 -- '--tmux'      # full flag text, incl. any sub-values
# then, from inside an iTerm2 tab, in a scratch git repo:
claude --tmux --agent agent-hierarchy:architect
```

Report: (a) does it require a git worktree, and does it *create* one; (b) is the
resulting tmux session **named** and discoverable without scanning; (c) does the
new pane land in the **current tab** or somewhere else; (d) does `--tmux=classic`
differ.

- **A named session in the current tab, no worktree side effects** → a later
  amendment may replace §12.2's AppleScript with it, removing findings [G]/[H]
  and the focus-targeting bug from the codebase. Even then, creation stays with
  `tmux new-session` (§2.3) — this would be presentation only.
- **Anything else** → §12.2 ships as written; close E10.

**This does not gate the build.** §12.2 is the last thing to land (§18 ship
order), so E10 can run at any point before then.

#### E11 — Are `Grep` and `Glob` reachable in a paned Architect? **SETTLED NEGATIVE — they are genuinely absent.** ❌

> **Amended, revision 3.** This ran. Measured on a live paned Architect
> (`claude --agent agent-hierarchy:architect`, v2.1.223): the pane reported
> verbatim *"No Grep/Glob tool is exposed to me directly"* and reached its answer
> by dispatching `task-gopher` and by `Read` instead. They are **absent, not
> merely deferred behind `ToolSearch`**.

**Decided:** §3.1's tool-deferral explanation is **wrong** and must not be
repeated as fact — keep the structural claim (different base set, same denials),
drop the deferral hypothesis as the explanation. A paned Architect is materially
weaker at research than the same Architect as a subagent, and that belongs in the
README's "Known differences from a subagent" paragraph (§18.3) in bold, together
with the recommendation to **prefer the subagent path for research-heavy
Architect work**. The pane does keep the `Agent` tool and can delegate, which is
how it works around the gap.

#### E12 — Which copy of an agent definition does `claude --agent` actually read? *(new in revision 3; affects §6.3a display only)*

Verified for **hooks**: under the local-path `claudetools` marketplace,
`${CLAUDE_PLUGIN_ROOT}` resolved to the **live checkout** — a brand-new
`hooks/stop-pane-relay.mjs` fired inside a pane although the cached `0.7.0` tree
contained neither the file nor a `Stop` entry in its `hooks.json`. **Not**
verified for **agent definitions**, which are a different plugin subsystem, and
E1 cannot discriminate because both copies of `architect.md` carry the same
denials.

**This is deliberately NOT blocking, and that is the point of §6.3a.** The union
rule makes every policy decision correct without the answer. E12 decides only
which path `pane.mjs` should *emphasise* in the confirmation.

Experiment:

```
# in the LIVE CHECKOUT only — do NOT touch the cache copy
add a distinctive sentinel line to
  /Users/jimcline/git/repos/claudetools/agent-hierarchy/agents/<some agent>.md
(e.g. a one-line sentence in the body: "SENTINEL-E12-<random>")

claude -p 'Quote the sentinel line in your own instructions, verbatim, or say NONE' \
  --agent agent-hierarchy:<that agent>

then revert the sentinel
```

- **Sentinel appears** → the harness reads the live checkout. Label the live path
  *"in force"* and the recorded path *"installed"* in §11.3's divergent block.
- **Sentinel absent (`NONE`)** → the harness reads the cache. Invert the labels.
- **Either way** the union rule in §6.3a stays. It is what covers the case where
  a future harness version changes its mind, which is the failure the
  mirror-the-harness option would have walked into.

Note for whoever runs this: it modifies a tracked file in the checkout. Use a
scratch agent definition or revert immediately; do not leave a sentinel in a real
role's body.

---

## 16. Config keys

New optional block in `~/.claude/agent-hierarchy.json` (and the project-scoped
file), resolved by the existing `resolveConfig()` layering. All keys optional;
absent block means all defaults.

```json
{
  "panes": {
    "timeoutSeconds": 300,
    "pollSeconds": 2,
    "inlinePromptMaxChars": 2000,
    "iterm2": true,
    "allowBuiltins": false,
    "permissionMode": null,
    "onDefinitionDivergence": "warn",
    "size": { "x": 200, "y": 50 }
  }
}
```

`permissionMode` is the **blanket override** described in §14.1 step 2; when
non-null it applies to every pane, including reasoning roles, and the
confirmation must show it. It is the only path by which `bypassPermissions` can
ever be set.

`onDefinitionDivergence` (*new in revision 3*, §6.3a) accepts `"warn"` (default)
or `"refuse"`. `"warn"` shows both paths and continues with the union-computed
policy; `"refuse"` exits 2 and names both paths. There is deliberately **no**
`"ignore"` value and no option to silently prefer one copy — that is the choice
§6.3a rejects, and offering it as a key would reintroduce it.

`resolveConfig()` must keep accepting configs with **no** `panes` block — this
is additive and must not bump the config `version` or invalidate existing files.
Unknown keys inside `panes` are ignored with a warning, matching how the
resolver already handles the rest.

---

## 17. Verification

### 17.1a Bug-fix tests — `tests/test-sessionstart-agent.sh`

Separate file, because §8.1 ships as its own release (§18) and must be testable
with no `/pane` code present.

1. **`isSubagent` — `agent_id` set** → true.
2. **`isSubagent` — `agent_type` set, no `agent_id`** → **false**. *This is the
   bug. The assertion must fail against today's shipped code.*
3. **`isSubagent` — neither set** → false.
4. **sessionstart, top-level `--agent` hierarchy role** — payload
   `{agent_type: "agent-hierarchy:architect", source: "startup"}`, no pane env.
   Assert: emits the role-session notice; output does **not** contain
   `You are the Orchestrator`; output does **not** contain the role→model table.
5. **sessionstart, top-level `--agent` non-hierarchy agent** — payload
   `{agent_type: "some-plugin:notetaker"}`, no pane env. Assert: emits the
   ordinary directive (or nudge, per config), byte-identical to case 6a.
6a. **sessionstart, ordinary session** — payload with neither `agent_type` nor
   `agent_id`. Assert output is **byte-identical** to the pre-change behaviour.
   Capture the expected string as a fixture before making the change.
6b. **sessionstart, subagent** — payload with `agent_id` set. Assert: no output
   at all.
7. **Exactly one stdout write** — `grep -c 'process.stdout.write' sessionstart.mjs`
   must be `1`. *Guards §8.2a trap 1.*

### 17.1b `/pane` tests — `tests/test-pane.sh`

House style, matching `tests/test-agent-frontmatter.sh`: bash, `PASS`/`FAIL`
counters, a `check()` helper, pipe JSON to the hook on stdin. **Assert on the
emitted output's shape, not only the exit code** — an exit-code-only assertion
cannot distinguish an active decision from silently falling through.

No tmux and no live Claude session required for any of these:

1. **Stop relay, unsolicited** — pane env set, payload `agent_type` matching
   `AGENT_HIERARCHY_PANE_ROLE`, **no** `pending` file. Assert: exit 0, **no**
   `reply.*.json` created, `log.jsonl` gained one `"ev":"silent"` line.
   *This is the test that proves the pane cannot initiate.*
2. **Stop relay, solicited** — `pending` present with a known `reqid` and no
   `expect_session`; payload `agent_type` matches; `last_assistant_message` is
   `"PANE OK 2"`. Assert: exit 0, `reply.<reqid>.json` exists, its `text` is
   exactly `PANE OK 2`, `pending` is **gone**, `log.jsonl` gained
   `"ev":"replied"`.
3. **Stop relay, not a pane** — env vars unset. Assert: exit 0, no files created
   anywhere, no stdout, **and stdin was never read** (pipe a payload and assert
   the process exits without consuming it, or assert via a `strace`-free proxy:
   the fast path must appear before any stdin read in the source).
4. **Stop relay never reads the transcript** — assert no `readFileSync` /
   `createReadStream` of `transcript_path` in `stop-pane-relay.mjs`.
   *Guards finding [C]'s race.*
5. **Stop relay, agent_type mismatch (grandchild hazard)** — pane env set with
   `AGENT_HIERARCHY_PANE_ROLE=agent-hierarchy:implementor`, `pending` present,
   payload has **no** `agent_type`. Assert: exit 0, **no** `reply.*.json`,
   `pending` still **present**, `log.jsonl` gained `"ev":"foreign"` with
   `reason:"agent_type"`. Repeat with a *different* `agent_type`. *Guards §9.3.*
6. **Stop relay, session mismatch** — `pending` carries
   `expect_session: "AAA"`, payload `session_id: "BBB"`, `agent_type` matches.
   Assert: no reply, `pending` still present, `"ev":"foreign"` with
   `reason:"session_id"`.
7. **sessionstart pane branch** — `AGENT_HIERARCHY_PANE_DIR` set to a temp dir;
   payload with **and** without `agent_type`. Assert both emit the pane protocol,
   that the output does **not** contain `You are the Orchestrator`, and that
   `<dir>/session` was created with the payload's `session_id`.
8. **sessionstart pane branch is first** — pane env set **and** `agent_id` set
   (a nonsense payload). Assert the pane protocol wins. *Guards §8.2 ordering.*
9. **sessionstart pane branch survives a broken mailbox** — pane env pointing at
   a **non-existent** directory. Assert: still emits the pane protocol, exit 0,
   no throw. *Guards §8.2a trap 3.*
10. **Registry fold** — a hand-written `.panes.jsonl` with open/open/close/open
    sequences. Assert `list --json` reports exactly the expected live set.
11. **Orientation, `v` means RIGHT** — `open --dry-run <agent> v`. Assert the
    registry record's `orientation` is `"right"` and the AppleScript the dry-run
    prints contains `split vertically`. *Guards the Q2 inversion.*
12. **Orientation, `h` means BELOW** — same with `h`. Assert `"below"` and
    `split horizontally`.
13. **Orientation never leaks a flag or a letter** — `grep -E '"(-[hv]|[hv])"'`
    over the dry-run registry record. Assert zero hits.
14. **Model `inherit` never reaches argv** — dry-run `open` for a role configured
    `inherit`. Assert the built argv contains no `--model` and no substring
    `inherit`.
15. **Haiku refusal** — dry-run `open --agent architect --model haiku`.
    Assert exit 2 and a message naming the role.
16. **Permission mode, reasoning role** — dry-run `open agent-hierarchy:architect`.
    Assert argv contains **no** `--permission-mode`.
17. **Permission mode, Implementor** — dry-run `open agent-hierarchy:implementor`.
    Assert argv contains `--permission-mode acceptEdits`.
18. **Permission mode, non-role agent** — dry-run `open some:other-agent`.
    Assert argv contains **no** `--permission-mode`.
19. **`bypassPermissions` refused from argv** — `open <agent> --permission-mode
    bypassPermissions`. Assert exit 2, before any tmux invocation.
20. **Built-in refusal** — `open --agent Explore`. Assert exit 2 and that the
    message names `Explore`.
21. **Injection whitelist** — `open --agent 'a;rm -rf /'` and
    `open --agent '$(id)'`. Assert exit 2 **before** any tmux invocation. Repeat
    for `--model` and `--permission-mode`.
22. **Self-send refusal** — registry entry whose `pane_id` equals `$TMUX_PANE`.
    Assert `send` exits 2. *Guards finding [L].*
23. **No pane discovery** — `grep -nE 'tmux (ls|list-sessions)' hooks/*.mjs`.
    Assert zero hits. Assert every `list-panes` call site passes an explicit
    `-t "$KEY"`. *Guards finding [L].*
24. **Kill safety** — `close` against a registry record whose `pane_pid` is
    `process.pid`. Assert refusal, and that no signal was sent.

*New in revision 3 — tests 25–32. Tests 25 and 27 are the security tests; do not
let them be dropped as "internal detail".*

25. **`canExecute` fails safe — all four branches** (§14.1a):
    - frontmatter `{}` (neither `tools` nor `disallowedTools`) → **`true`**.
      *This is the case a "simplification" would invert.*
    - `disallowedTools: [Bash, Edit, NotebookEdit]` → `false`.
    - `disallowedTools: [Bash]` only → `true`.
    - `tools: ["Read", "Grep"]` → `false`; `tools: ["*"]` → `true`.
26. **Divergence detected** — build a fake `HOME` containing
    `known_marketplaces.json` with a `"source": {"source":"directory","path":…}`
    entry, an `installed_plugins.json` pointing at a fake cache tree, a fake
    checkout tree with `.claude-plugin/marketplace.json`, and an `agents/x.md`
    that **differs** between the two trees. Dry-run `open`. Assert: exit 0,
    `definition_source` is `"divergent"`, **both** paths appear in the output,
    and `definition_path_live` is populated.
27. **Divergence resolves by OR** — same fixture; cache copy has
    `disallowedTools: [Bash, Edit, NotebookEdit]`, checkout copy has
    `tools: ["Bash"]`. Assert the dry-run reports the agent as
    execution-capable (the permission question is asked). **Then swap the two
    trees and assert the identical result.** *This is the security test: the
    answer must not depend on which side is stale.*
28. **No divergence stays quiet** — identical `agents/x.md` on both sides.
    Assert `definition_source` is `"identical"` and that the output contains
    **no** divergence warning at all.
29. **`onDefinitionDivergence: "refuse"`** — fixture 26 plus the config key set
    to `"refuse"`. Assert exit 2 and that both paths are named in the message.
30. **Non-local marketplace is inert** — `known_marketplaces.json` entry with
    `"source": {"source":"github", …}`. Assert no live candidate is computed,
    no divergence warning, `definition_path_live` is `null`, and
    `definition_source` is `"recorded"`.
31. **The cache is never globbed** — `grep -nE 'plugins/cache' hooks/*.mjs`.
    Every hit must be a path *built from* an `installPath` read out of
    `installed_plugins.json`. Assert there is no `readdir`/glob rooted at
    `~/.claude/plugins/cache`. *Guards §6.3's hard rule against the new
    revision-3 code.*
32. **Group kill is guarded** — `close` against a registry record whose
    `pane_pid` has `pgid !== pane_pid` (stub the `ps` reader). Assert the
    single-pid path is taken and that `kill` was **never** called with a
    negative argument. Repeat with `pgid === pane_pid` and assert the negative
    argument **is** used. Third case: pgid equal to `pane.mjs`'s own → assert the
    single-pid path. *Guards §13.3.*

Add both test scripts to whatever runner already invokes the other four.

### 17.2 Manual — the one live smoke test

> **Amended, revision 3 — this test has now been RUN and it PASSED. Read the
> caveat before treating the pass as verification.**
>
> Verified live on 2026-08-06, full happy path: `doctor` → `open` (tmux session
> created **and** iTerm2 pane split, `pane_id` and `pane_pid` captured at
> creation, `iterm_child_uuid` returned per E6) → `send` (prompt on stdin,
> `pending` token written before the paste, bracketed paste delivered) → relay
> reply `"SMOKE"` in **~2s** with the pending token cleared → `close` (clean
> teardown, no surviving processes).
>
> **What the pass does NOT establish.** It ran on a machine where `claudetools`
> is a **local-path marketplace**. The new hooks executed from the live checkout
> while `pane.mjs` resolved the agent definition out of the cached `0.7.0` tree
> (§6.3a). Policy was therefore computed from a *different copy* than the one the
> harness may have launched. It came out correct only because the three role
> definitions happen to be byte-identical across the two trees today — a
> coincidence, not a property, and not something a user installing from git
> shares.
>
> **Required before calling the feature verified:** re-run this smoke test after
> §6.3a and §14.1a land, and run it **once more on a machine (or a fake `HOME`)
> where the plugin was installed from git**, so the cache is the only copy.

```
/agent-hierarchy:pane agent-hierarchy:architect v
  → confirmation shows agent, definition path(s), model, perms,
    and "opened to the right"   ← v means SIDE BY SIDE (§10.2)
  → an iTerm2 pane appears IN THE ORCHESTRATOR'S OWN TAB (finding [H])
  → the pane shows an Architect session, not "You are the Orchestrator"

/agent-hierarchy:pane ask <key> "Reply with exactly: PANE OK 2"
  → user confirmation appears BEFORE anything is sent
  → the pane shows a [Pasted text] chip, then submits
  → reply comes back in ~2–7s, text is exactly "PANE OK 2"

  then, in the pane, the user types "what is 2+2" directly
  → the pane answers the human; NOTHING is relayed to the Orchestrator
    (finding [F], and the §8.3-point-5 behaviour)

/agent-hierarchy:pane close <key>
  → tmux session gone
  → ps shows NO surviving `claude` for that pane_pid (finding [J])
  → ps shows NO surviving MCP-server child in that pane's process group (E5)
```

The last two lines are the ones that have bitten before. Check both explicitly —
the MCP-child check is new in revision 3 and is what the group kill exists for.

Also run once, by hand, with no pane involved at all:

```
claude --agent agent-hierarchy:architect
  → the session gets the ROLE NOTICE (§8.4), not silence and not
    "You are the Orchestrator"                        ← the §8.1 bug fix
```

---

## 18. Rollout

### 18.1 Two releases, not one

**Recommendation: ship the §8.1 bug fix first, on its own.**

| Release | Contents | Version |
| :-- | :-- | :-- |
| **First** | §8.1 `isSubagent` fix + §8.2 three-way branch (cases 2/3/4 only, no pane branch) + §8.4 role notice + `tests/test-sessionstart-agent.sh` + the corrected JSDoc | `0.7.1` |
| **Second** | everything else in this spec | `0.8.0` |

Why separate:

- The bug is **live today** and independent of `/pane`. If `/pane` slips or is
  cut, the fix should not go with it.
- It touches `lib-config.mjs`, which the rest of the plugin depends on. A small,
  reviewable diff with its own tests is much easier to judge than the same change
  buried in a 1500-line feature.
- The pane branch (case 1) then lands on an already-correct guard rather than
  papering over a wrong one.

The Orchestrator may overrule and bundle; if so, ship straight to `0.8.0` and
keep `tests/test-sessionstart-agent.sh` as a separate file anyway.

> **Amended, revision 3 — does the divergence defect block the release?**
>
> **No, and the guard is not optional.** Stating both halves precisely:
>
> - **It does not block**, because the divergence is currently **latent**: the
>   three role definitions are byte-identical across the two trees today (§6.3a),
>   and for a user who installs claudetools normally from git there is exactly
>   one copy and no divergence is possible at all. The affected population is
>   plugin authors working from a local-path marketplace.
> - **§6.3a and §14.1a are required content of the second release.** Without
>   §14.1a's fail-safe inversion, the permission gate can silently skip a prompt
>   for an agent that gained `Bash` — a security-relevant miss, in a small but
>   high-agency population, and one nothing in the current code would surface.
>   With §14.1a landed, the residual consequence is a possibly-misleading printed
>   path, which §6.3a's dual display closes.
> - **What IS blocked is the claim.** §17.2's pass may not be described as
>   verifying the feature until it is re-run per §17.2's amended note. Ship the
>   code; do not ship the claim.
>
> E12 does **not** block: §6.3a is deliberately designed so the release does not
> need its answer.

### 18.2 Version bumps

**Required in BOTH files, together** — a plugin change that bumps only one is a
known recurring defect in this repo:

- `/Users/jimcline/git/repos/claudetools/agent-hierarchy/plugin.json`
- `/Users/jimcline/git/repos/claudetools/.claude-plugin/marketplace.json`

> **Amended, revision 3.** Revision 2 said "both currently read `0.7.0`." That is
> now stale: `.claude-plugin/marketplace.json` reads `0.8.0` for
> `agent-hierarchy`. Before shipping revision 3's changes, **check that
> `plugin.json` matches**, and if `0.8.0` has already been published, bump both
> to `0.8.1` rather than re-publishing `0.8.0` with different contents.

*Note for the Implementor:* the original dispatch called this "root
`marketplace.json`", but the file resolved on disk is at
`.claude-plugin/marketplace.json`. If a root-level `marketplace.json` also
exists, bump it too — check before committing.

### 18.3 Documentation

`agent-hierarchy/README.md` gains a `/pane` section covering:

- the grammar, with **words** (`right`/`below`) preferred over the letters;
- **`v` = side by side, `h` = stacked** stated explicitly, once, near the top;
- the one-way-initiation guarantee;
- the tmux requirement and the `tmux attach -t <key>` escape hatch;
- a **"Known differences from a subagent"** paragraph carrying §7.2's model
  drift **and** §3.1's tool-surface difference. Q4's answer was "document the
  drift" — a spec-only note does not discharge it; this paragraph does. Revision
  3: that paragraph must also carry **E11's settled negative** — a paned
  Architect has no `Grep` and no `Glob`, so prefer the subagent path for
  research-heavy Architect work.
- the per-role permission table (§14.1), including that `acceptEdits` does not
  cover `Bash`;
- *(revision 3)* one short paragraph on **definition divergence**: if you develop
  plugins from a local-path marketplace, `/pane` may find two copies of an agent
  definition; it computes policy from both and takes the stricter answer, shows
  you both paths, and `/pane doctor` tells you when a cache is stale. State that
  `/pane` **asks** whenever it cannot rule out that an agent can execute — do not
  state that a non-prompting pane cannot execute (§14.1a point 3).

Update the `description` string in `hooks/hooks.json` to cover the new `Stop`
hook and state that it is inert unless `AGENT_HIERARCHY_PANE_DIR` is set. Also
correct the sentence in that description that currently asserts *"SessionStart
does not fire for subagents"* — it is the same falsified assumption as §8.1.

### 18.4 Ship order within release two

§8 (sessionstart pane branch) and §9 (Stop relay) are independently testable with
no tmux at all, and are what make the feature *safe*. Land and test them first,
then §12–§13 (tmux + registry), then §12.2 (iTerm2) last, as the optional layer
it is. E10 can run any time before that last step.

*Revision 3:* §14.1a is a two-line invariant plus tests and should land **before**
§6.3a — it is what makes the divergence non-critical, and it is independently
valuable even if §6.3a slipped. §13.3's group kill is independent of both.

---

## 19. Confidence, and what I am NOT settling

**Now resting on measurement, not documentation:** §3 (`--agent`), §8's
discriminator, §9's `Stop` + `last_assistant_message`, §12.1's `-P -F` capture,
§13.3's process-group premise, §12.2's child-UUID return, and §3.1's tool-surface
difference. E1–E6 and E11 settled all of them.

**Reasonably confident:** the pending-token protocol (§9), the registry and
teardown shape (§13), the prompt-delivery sequence (§10.4), the tmux/iTerm2 split
of responsibilities (§12), and the §2.3 rejection of `--tmux` for creation. The
full happy path has now run end to end (§17.2).

**Lower confidence, flagged:**

- **§6.3a — the divergence rule is new and it is mine.** *Medium-high.* The
  union rule is sound because it does not depend on E12, and the failure
  direction is toward over-prompting, which is safe. What I am *less* sure of is
  step 4 of the live-candidate resolution: I verified `"source": "./agent-hierarchy"`
  for two plugins in one marketplace manifest, and I am assuming — not
  verifying — that a relative-path string is the general shape. The spec handles
  the other shapes by **abandoning** the live candidate rather than guessing,
  which is the conservative direction, but a marketplace format I have not seen
  would quietly degrade `/pane` to today's single-source behaviour without
  saying so. If that matters, the fix is to warn on an unrecognised `source`
  shape rather than abandon silently.
- **§14.1a's invariant is stated but not enforced by types.** It lives in one
  boolean expression that reads like a redundancy. Test 25 is the only thing
  standing between it and a well-meaning cleanup. If the Reviewer can think of a
  way to make it structurally obvious rather than test-enforced, take it.
- **§8.1 — the bug fix touches shipped, shared code.** The `agent_id`
  discriminator is carried as a verified fact from prior sessions, but not
  verified *for SessionStart payloads specifically* by this Architect. If
  SessionStart does fire for subagents and those payloads lack `agent_id`, the
  fix leaks the directive into subagents. §8.1 states the bounding argument and
  the one-line experiment that would remove the doubt. **Medium-high.**
- **§8.2 case 3 — what a hand-launched `--agent` session should receive** is a
  genuine design choice I made, not a user decision. I chose "role notice for
  hierarchy roles, ordinary directive for everything else." The conservative
  alternative is "inject nothing for every `--agent` session", which preserves
  today's behaviour while still fixing the falsified comment. If the Reviewer
  thinks case 3 is scope creep, that alternative is a one-line change and I will
  not defend mine hard.
- **§14.1 / E7.** Q3's answer is only implementable if `--permission-mode`
  applies under `--agent`. That is unverified, and the documentation claim
  pointing the other way comes from the same unsubstantiated source as §2.1.
  E7 is blocking.
- **§13.3 — the group kill is designed, not measured.** E5 settled the *premise*
  (claude leads its own group; MCP children share the PGID). The single clean
  `close` observed in §17.2 is weak evidence that the leak may be narrow, and it
  is **not** evidence that the group kill behaves as intended. Test 32 covers the
  guard; the actual signal delivery is only covered by §17.2's amended manual
  check.
- **§2.1.** I withdrew a section that revision 1 presented as verbatim
  documentation. The lesson generalises: **treat every doc quote in this spec
  that is not backed by an E-item as unverified.** The remaining ones are the
  `initialPrompt` semantics (§6.5) and the "frontmatter `permissionMode` is
  ignored for plugin subagents" claim (§14.1). Neither is load-bearing on its
  own, but neither should be cited as settled.

### Open questions for the user

- ~~**Q1 — §2.** Agent teams.~~ **CLOSED** — no such CLI surface on v2.1.223;
  build `/pane`. (§2.1)
- ~~**Q2 — §10.2.** Orientation letters.~~ **ANSWERED** — the letter names the
  divider: `v` = side by side, `h` = stacked. Applied throughout. (§10.2, §12.2)
- ~~**Q3 — §14.1.** Permission mode.~~ **ANSWERED** — per-role split; Implementor
  gets `acceptEdits`, everything else prompts normally. Applied. (§14.1) Two
  sub-decisions I made on the user's behalf are open as **Q5**.
- ~~**Q4 — §7.2.** `model: inherit`.~~ **ANSWERED** — allowed; drift documented
  in the README, not only the spec. Applied. (§7.2, §18.3)
- **Q5 — §14.1.** Two permission sub-decisions Q3 did not cover, both made
  by the Architect and both cheap to reverse:
  1. **`task-runner` gets normal prompting.** It has `Bash`, which `acceptEdits`
     does not cover, so granting it would widen blast radius while buying almost
     nothing. Confirm, or say what it should get.
  2. **`bypassPermissions` is refusable from the command line, permitted only
     from a config file.** Confirm, or relax.
- **Q6 — §8.2 case 3.** Should a hand-launched `claude --agent
  agent-hierarchy:architect` session (no pane) receive the short role notice
  (§8.4), or nothing at all? I chose the notice. Nothing-at-all is the smaller,
  safer diff.
- **Q7 — §6.3a, NEW (revision 3).** On definition divergence, the default is
  **warn and continue with the stricter policy**, not refuse
  (`panes.onDefinitionDivergence`, default `"warn"`). My reasoning: you develop
  plugins from a local checkout, so divergence is the *normal* state of your own
  repo and refusing by default would make `/pane` unusable exactly where it is
  built — while the union rule already removes the safety consequence. **If you
  would rather `/pane` stop and make you resync, say so and I will flip the
  default to `"refuse"`.** This is a product-behaviour call and it is yours, not
  mine; I picked a default rather than block on it.

### Escalation

I still do not think this needs the Ultra-Advisor, and E7's resolution is the
thing most likely to change that. If E7 shows `--permission-mode` is ignored
under `--agent`, then the only route to a non-blocking paned Implementor is
something more permissive than `acceptEdits` running unattended — an
agent-acting-without-oversight decision with real blast radius, and one I would
want adjudicated rather than defaulted. **Escalate at that point with this
question:** *"A paned Implementor cannot be given `acceptEdits`. What, if
anything, may an unattended interactive agent be allowed to do without a human
in the loop — and is a stalling Implementor the correct failure mode instead?"*

**Revision 3 does not raise a second escalation.** I considered whether the
definition-divergence defect warranted one, given it is security-adjacent, and
concluded no: the failure direction is bounded (over-prompting), the fix does not
depend on an unverified assumption, and the residual risk is a display detail
that E12 closes cheaply. If the Reviewer disagrees with §6.3a's *warn* default or
with §14.1a's fail-safe framing, that disagreement is worth escalating — those
are the two judgment calls in this revision that a second opinion would actually
change.
