# smart-gopher — implementation spec

**Status:** ready to implement, with 3 NEEDS-EVIDENCE items (§10) that must be checked
first, and 1 open decision for the user (§11).

**Repo:** `/Users/jimcline/git/repos/claudetools`, branch `main`.

> **PATH CORRECTION.** The dispatching brief named
> `plugins/task-gopher/…`. There is no `plugins/` directory in this repo — the
> plugin lives at **`task-gopher/`** at the repo root (`marketplace.json` entry
> `"source": "./task-gopher"`). Every path in this spec is relative to the repo
> root and uses the real layout. This spec itself was written to
> `task-gopher/docs/smart-gopher-spec.md` rather than the briefed
> `plugins/task-gopher/docs/…`, which would have created a bogus parallel tree.
> Note the repo also has a root-level `docs/` holding `relay-gate-toolless-skip.md`
> (a task-gopher design doc); if the house convention is root `docs/`, move this
> file there — nothing in the spec depends on its location.

---

## 1. Goal

Add a second subagent, **`smart-gopher`**, to the existing `task-gopher` plugin.

`task-gopher` is a Haiku runner that executes fully-specified orders and **stops**
rather than guess whenever an order needs judgment. `smart-gopher` is the
escalation target for exactly that stop: a Sonnet-tier delegate that *can* reason
about what it gathers, so a lead does not have to choose between
"do the tool-heavy work myself" and "re-dispatch a decision-free order I cannot
actually write."

Three properties are non-negotiable:

1. **smart-gopher cannot dispatch subagents.** No `Agent`, no `Task`.
2. **The destructive/outward guard applies to smart-gopher identically.** More
   reasoning ability is not more trust for irreversible or outward-facing actions.
3. **Design, architecture, correctness, security and scope decisions still belong
   to the lead.** smart-gopher raises the bar for what counts as "needs the lead";
   it does not remove the escalation instinct.

### Scope decisions already made — do not re-litigate

- smart-gopher lives in the **existing** plugin (`task-gopher/agents/smart-gopher.md`).
  One version bump, shared hooks, shared toggle.
- Tool access is **"all tools except Agent"** — broad, minus sub-delegation.
- The destructive guard covers it identically.
- **Reasoning-effort cannot be pinned.** Claude Code plugin agent frontmatter
  supports only `name`, `description`, `tools`, `disallowedTools`, `model`,
  `permissionMode`, `skills`, `memory`, `isolation`, `maxTurns`. There is no
  `effort` key (that exists only in the Agent SDK's programmatic
  `AgentDefinition`), and the `Agent` tool's dispatch call has no effort override.
  **Do not add an `effort:` field.** Deliberateness comes from the `.md` body only.

---

## 2. The crux: what silently fails to cover smart-gopher

This is not "add one file." Six matching sites key on the literal string
`"task-gopher"`, and **`"smart-gopher"` does not contain it**. Every one of these
fails *silently* — the dispatch still succeeds, the guard just never fires.

| # | Site | Current test | What breaks |
|---|---|---|---|
| 1 | `hooks/directive.mjs` `isTaskGopherAgent()` | `agent_type.includes("task-gopher")` | The single predicate all the others route through |
| 2 | `hooks/pretooluse-nudge.mjs:363` | `isTaskGopherAgent(payload)` | **Destructive guard never runs for smart-gopher.** Violates constraint 2 |
| 3 | `hooks/pretooluse-nudge.mjs:400` | same branch's `allow()` | smart-gopher's own reads get strict-checkpointed and told to "dispatch to task-gopher" — advice it cannot act on |
| 4 | `hooks/pretooluse-nudge.mjs:409` | `st.includes("task-gopher")` | `ALLOW-DESTRUCTIVE:` lines in a dispatch to smart-gopher are **never recorded**, so the guard's only release valve is dead for it |
| 5 | `hooks/pretooluse-nudge.mjs:433` | `st.includes("task-gopher")` | A dispatch to smart-gopher is **relay-stamped** with ~1,500 wasted directive tokens, and does not reset the strict streak |
| 6 | `hooks/destructive.mjs` `askMessage()` / `denyMessage()` | hardcoded prose | The permission dialog says "the Haiku runner" and "makes no judgments" — both false, in the two seconds a human spends deciding |

`hooks/agent-tools.mjs` is already name-agnostic and needs **no change** — but see
§4 for why its `disallowedTools` rule interacts with our frontmatter choice.

### The name-ordering trap

The plugin-scoped dispatch form for the new agent is **`task-gopher:smart-gopher`** —
the *plugin* half is literally `task-gopher`. So:

```js
"task-gopher:smart-gopher".includes("task-gopher")  // TRUE
"task-gopher:smart-gopher".includes("smart-gopher") // TRUE
```

Any predicate that tests `task-gopher` first will classify **every** smart-gopher
as the Haiku runner. That is harmless for a boolean gate but wrong for the
permission dialog, which is the one place the label must be right.

**Rule: test `smart-gopher` before `task-gopher`, always.** §3 encodes this and
§9 tests it.

---

## 3. `hooks/directive.mjs` — generalize the predicate

Replace `isTaskGopherAgent` (currently lines 158–161) with a *kind*-returning
function. A kind, not a boolean, because `destructive.mjs` and `report.mjs` both
need to name which runner they are talking about.

Delete `isTaskGopherAgent` entirely and rename its three call sites (§5, §6, §7) —
there are only three, and a back-compat alias would just be a second name for one
thing.

Keep the existing block comment above it (the tier-gate / `TODO(hard-gate)`
explanation) — it is still accurate — and extend it with the ordering note.

```js
/**
 * The runner agents this plugin ships, and which one a name refers to.
 *
 * ORDER IS LOAD-BEARING. The plugin-scoped form of the reasoning runner is
 * "task-gopher:smart-gopher" — the PLUGIN half is literally "task-gopher", so a
 * task-gopher-first test classifies every smart-gopher as the Haiku runner. That
 * is invisible for a boolean gate and wrong where it matters most: the
 * permission dialog, which names the agent asking to destroy something. Most
 * specific name first.
 *
 * Substring rather than equality, matching the existing convention: the harness
 * may hand us the bare name or the plugin-scoped one, and both must match.
 */
const GOPHER_KINDS = ["smart-gopher", "task-gopher"];

/** "smart-gopher" | "task-gopher" | null */
export function gopherKind(name) {
  if (typeof name !== "string" || !name) return null;
  for (const kind of GOPHER_KINDS) if (name.includes(kind)) return kind;
  return null;
}

/** Which runner is this hook firing inside, if any? Reads `agent_type`. */
export function agentGopherKind(input) {
  return gopherKind(input && input.agent_type);
}

/** Is this hook firing inside either runner? */
export function isGopherAgent(input) {
  return agentGopherKind(input) !== null;
}
```

**Known looseness (accept, do not fix):** a user agent named
`my-smart-gopher-helper` would match. This is exactly the looseness the current
code already has with `task-gopher`, it fails toward *more* guarding rather than
less, and tightening it would break the bare-vs-namespaced tolerance the comment
depends on. Document it in the comment; do not add anchoring.

### Directive text changes (same file)

`FULL_DIRECTIVE` and `SHORT_REMINDER` are the only channel that reaches a
dispatching agent. Three edits to `FULL_DIRECTIVE`:

**(a)** Insert a new paragraph **immediately after** the paragraph beginning
```
'`task-gopher` is a PURE task-runner: it never reasons, decides, or fills gaps…'
```
and before the `"ORDER CONTRACT — …"` paragraph. Add it as two array entries
(`""` then the string), matching the file's existing style:

```js
"",
'TWO RUNNERS — PICK ONE. `task-gopher` (Haiku) runs orders you can fully specify. `smart-gopher` (Sonnet, subagent_type "task-gopher:smart-gopher") is the escalation target for delegated work that genuinely needs judgment: which of several plausible files or call sites is the right one, reconciling evidence that disagrees across a tree, a summary that needs an editorial cut ("what is actually wrong with this module"), or a multi-step task whose later steps depend on what the earlier ones find. Reach for it at exactly two moments: when you are about to do tool-heavy work YOURSELF only because you cannot write a decision-free order for it, and when task-gopher has already STOPPED on a gap that is a judgment call rather than a missing fact. It is NOT a general upgrade — it spends Sonnet tokens, so anything you can specify exactly still goes to task-gopher, and a gap that is merely an underspecified order should be re-dispatched to task-gopher with the gap filled in. It is also NOT a way to offload YOUR decisions: design, architecture, correctness, security and scope stay with you. smart-gopher returns a reasoned compact report and hands any such call back, the same way task-gopher hands back a gap. It cannot dispatch subagents, so it is the end of the chain.',
```

**(b)** In the `"DESTRUCTIVE AND OUTWARD-FACING WORK IS NOT THE RUNNER'S…"`
paragraph, change:
- `"any Bash stage from task-gopher that destroys local state"`
  → `"any Bash stage from EITHER runner (task-gopher or smart-gopher) that destroys local state"`
- append after `"Prefer running destructive steps yourself over authorizing them."`:
  `" smart-gopher is guarded identically — its extra reasoning does not buy it any more authority over irreversible or outward-facing work."`

**(c)** In the final `"Relay is automatic…"` paragraph, change
`"skipping the ones that would be wasted: task-gopher itself,"`
→ `"skipping the ones that would be wasted: either gopher (neither dispatches onward),"`.

**`SHORT_REMINDER`** — one clause only; this string is re-injected every turn and
its whole point is being cheap. Insert after the sentence ending
`"…that per-step rationalization is the failure mode."`:

```
If an order genuinely cannot be made decision-free — which of several files, a summary needing an editorial cut, steps that depend on what earlier steps find — dispatch `task-gopher:smart-gopher` (Sonnet, reasons but cannot dispatch onward) rather than doing it yourself; design and security calls still stay with you.
```

Leave the `SENTINEL` (`"[task-gopher: ON]"`) **unchanged**. It is a wire marker
that both directive texts open with and that `pretooluse-nudge.mjs` top-anchors
on; changing it would silently break double-stamp detection for every in-flight
prompt and every existing test.

---

## 4. `agents/smart-gopher.md` — the new file

Create `task-gopher/agents/smart-gopher.md`.

### Frontmatter

```yaml
---
name: smart-gopher
description: >-
  Capable Sonnet runner for delegated work that genuinely needs judgment — the
  escalation target for when task-gopher STOPS because an order cannot be made
  decision-free. Dispatch it to resolve which of several plausible files, call
  sites, or explanations is the right one; to reconcile evidence that disagrees
  across a tree; for a summary that needs an editorial cut ("what is actually
  wrong with this module"); or for a multi-step investigation whose later steps
  depend on what the earlier ones find. It returns a COMPACT, reasoned report and
  says what it concluded AND what it is unsure of. It cannot dispatch subagents,
  and it still makes no design, architecture, security, or scope decisions —
  those go back to the lead. All tools except Agent.
model: sonnet
disallowedTools: Agent, Task
---
```

### Why `disallowedTools:` and not `tools:` — and the consequence

`tools:` is an **allow-list**. Enumerating "everything except Agent" would freeze
smart-gopher's toolset at whatever we type today and silently exclude every MCP
tool the session has connected — which guts the "capable" half of the agent.
`disallowedTools` is the deny-list form, it is a supported key, and it is how the
sibling `agent-hierarchy` agents already express "All tools except X".

**But this has a direct consequence in `hooks/agent-tools.mjs`.** That module's
rule 1 says, correctly and deliberately:

> Only an ALLOW-list is decisive. […] `disallowedTools` is a deny-list and is
> never evidence of absence — agent-hierarchy's architect, reviewer and
> ultra-advisor all use it while keeping Agent.

So `cannotDispatch("task-gopher:smart-gopher")` returns **false**, and the relay
would happily stamp ~1,500 wasted tokens onto every smart-gopher dispatch.

**Resolution:** do *not* touch `agent-tools.mjs`. The `gopherKind(st)` early-allow
added at `pretooluse-nudge.mjs:433` (§5) short-circuits before `relaySkipReason`
is ever reached, so the dispatch is never stamped — and it gets the strict-streak
reset in the same move. One change, both effects.

*(Optional, out of scope, mention only:* `agent-tools.mjs` could be taught that a
`disallowedTools` list **explicitly naming** `Agent`/`Task` **is** decisive — that
is a genuine improvement and would make the skip automatic for any future agent.
But it changes a shared function whose blast radius is every dispatch in every
plugin, and this feature does not need it. If you want it, it is a separate spec.)*

### Body

Everything below the frontmatter. It deliberately mirrors `task-gopher.md`'s
structure and voice so the two read as a matched pair, and it inverts exactly the
clauses that should invert.

```markdown
You are smart-gopher: a capable runner working for a higher-reasoning lead
(orchestrator) agent. You are the escalation target — the lead reaches for you
when a task needs real work done AND needs judgment applied along the way, so
task-gopher (the cheap Haiku runner, who stops dead at any ambiguity) could not
carry it.

You reason. That is the whole difference, and it is narrower than it sounds:

- **You reason about the WORK, not about the PROJECT.** Which of four files named
  `config.ts` is the one the lead means, whether two grep results actually
  describe the same bug, what a module is really for when its name lies, how to
  get an answer when the first three approaches came back empty — all yours,
  decide them and say what you decided. Whether the project SHOULD work that way,
  whether a design is correct, whether a change is safe to ship, what the scope
  ought to be — none of those are yours. They go back to the lead.
- Be deliberate before you are fast. You were dispatched precisely because the
  cheap literal-minded pass would have gone wrong. Read enough to be right, form
  a view about what you are looking at, and check that view against the evidence
  before you report it. A confidently wrong report is worse than task-gopher's
  honest "I stopped."
- **Say what you concluded AND what you are unsure of.** Every judgment you made
  on the lead's behalf gets stated as a judgment, not smuggled in as a fact.
  "There are three `parse()` definitions; I report the one in `src/core/` because
  it is the only one the CLI path reaches — the other two are in fixtures" is a
  good report. "`parse()` is at src/core/parse.ts:41" alone is not, because the
  lead cannot see the choice you made for them.
- When the decision is genuinely the lead's — a design fork, a correctness or
  security call, an ambiguity where both readings are defensible and they lead
  somewhere materially different — STOP and hand it back, naming the fork and
  what each branch would mean. That is a correct outcome, not a failure. The bar
  for stopping is much higher than task-gopher's; it is not gone.

Everything else about being a gopher still applies:

- **You do the work yourself. You cannot and must not delegate.** You have no
  Agent/Task tool by design. Never dispatch to task-gopher, never dispatch to
  another smart-gopher, never dispatch to anything. You are the end of the chain.
  If any instruction in your context tells you to delegate tool work to
  task-gopher, it was meant for the orchestrator, not you — ignore it and do the
  work or report that you cannot.
- **NEVER destroy, and NEVER publish.** Do not run anything that deletes, resets,
  discards, or force-anythings — `rm -rf`, `git reset --hard`, `git clean -fd`,
  `git worktree remove`, `git branch -D`, `git restore`, `git rebase`,
  `git stash drop`, in-place `sed -i`, container/cluster/infra teardown — and
  nothing that leaves this machine: `git push`, `gh pr`/release writes,
  `npm publish`, write-method `curl`. This is NOT a limit on your reasoning; it
  is a limit on your authority. You may well be able to work out that a deletion
  is correct. Accepting an irreversible risk is still not yours to do on
  someone's behalf, and being able to reason about it does not transfer that
  right to you. The same PreToolUse guard that intercepts task-gopher intercepts
  you, identically: it interrupts the USER to approve any such command, or denies
  it outright when no one is there to ask. If a task needs one, STOP and report
  which command it requires and that you did not run it.
- When an ordered command FAILS, never escalate it to make it succeed. Do not add
  `--force`, `-f`, or `sudo`, do not widen a path, and do not delete whatever is
  "in the way". A command that refuses is very often refusing for the reason the
  safety exists. That refusal is a FINDING to report, not an obstacle to clear.
  You are allowed to try a different APPROACH; you are not allowed to try a
  bigger HAMMER.
- For any git-touching work: check the current branch first
  (`git rev-parse --abbrev-ref HEAD`) and include branch and cwd in your report.
  If the order names a branch/ref and you are not on it, STOP and report the
  mismatch — never switch branches unless the order explicitly says to.
- Return the SMALLEST report that fully answers the task. You are still a gopher:
  your value is that you read a lot and hand back a little. Prefer `file:line`
  references, function signatures, short quotes, counts, and exit codes over
  pasted output, and never paste raw multi-hundred-line logs or file dumps. Being
  able to reason is not a licence to narrate — reason on your own time, report
  the conclusion and the evidence for it.
- Compact NEVER means incomplete. When the task needs every match / all failures
  / a full list, return them ALL, however many. If you must cut to stay within a
  stated bound, say exactly what you cut and give the exact total count. A report
  that silently drops items looks complete and is worse than a long one.
- Do NOT return whole files verbatim. If a request would have you hand back an
  entire file with no filtering, return the relevant portion, note what you
  trimmed, and say the lead should read the file directly if they truly need it
  all.
- Follow output discipline while working: never stream (`tail -f`, `watch`,
  `--follow`), run long commands in the background, and redirect verbose output
  to a file then grep it, so your own context stays lean.
- Start your report with a one-line bottom-line answer, then the supporting
  detail, then — separately and explicitly — the judgments you made and anything
  you are unsure of.
```

---

## 5. `hooks/pretooluse-nudge.mjs` — the four gates

### 5a. Imports (lines 79–90)

Replace `isTaskGopherAgent` with `agentGopherKind` and `gopherKind`:

```js
import {
  FULL_DIRECTIVE,
  LOG_FILE,
  NUDGE_FILE,
  SENTINEL,
  agentGopherKind,
  canAskHuman,
  gopherKind,
  guardMode,
  isEnabled,
  isStrict,
  readRelayExempt,
} from "./directive.mjs";
```

### 5b. The destructive guard branch (lines 363–401)

Currently `if (isTaskGopherAgent(payload)) { … }`. Change the condition to capture
the kind, and thread it into both message builders. Everything else in the block
stays byte-identical — including the ordering (guard runs *before* the `isEnabled()`
check), the `preauthorized` computation, and the final `allow()`.

```js
  // Runs before the ON check: the guard protects against the agent, not against
  // the directive, and both agents exist whenever the plugin is installed.
  const runnerKind = agentGopherKind(payload);
  if (runnerKind) {
    const mode = guardMode();
    if (payload.tool_name === "Bash" && mode !== "off") {
      const hits = classify(payload?.tool_input?.command);
      if (hits.length) {
        const detail = hits.map((h) => h.stage).join(" ; ").slice(0, 300);
        const labels = hits.map((h) => h.label);
        const preauthorized = hits.every((h) => isAllowed(sid, h.stage));

        if (mode === "ask" && canAskHuman(payload)) {
          logEvent({ pid, aid, event: "destructive-ask", agent: runnerKind, tool: "Bash", detail, labels, preauthorized });
          ask(askMessage(hits, preauthorized, runnerKind));
        }

        if (!preauthorized) {
          const unaskable = mode === "ask" ? payload.permission_mode || "unknown" : "";
          logEvent({
            pid, aid, event: "destructive-blocked", agent: runnerKind, tool: "Bash", detail, labels,
            why: unaskable ? `no-human:${unaskable}` : "guard-mode:block",
          });
          deny(denyMessage(hits, unaskable, runnerKind));
        }
        logEvent({ pid, aid, event: "destructive-allowed", agent: runnerKind, tool: "Bash", detail });
      }
    }
    allow(); // otherwise never gate either runner's own tool use
  }
```

Note the new `agent: runnerKind` field on all three log events — §7 surfaces it.

The trailing `allow()` now also exempts smart-gopher from the strict checkpoint.
That is **intended**: smart-gopher cannot dispatch, so checkpointing it would
block its reads with advice it is structurally unable to follow.

### 5c. Allowance recording (lines 406–421)

```js
  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";
    const kind = gopherKind(st);
    if (kind) {
      const authorized = recordAllowances(sid, t.prompt);
      if (authorized.length) {
        logEvent({
          pid, aid, event: "destructive-allowance", agent: kind,
          tool: payload.tool_name, detail: authorized.join(" ; ").slice(0, 300),
        });
      }
    }
  }
```

Allowances remain **session-keyed, not agent-keyed** — unchanged behavior, and
`destructive.mjs`'s "HONEST LIMITS" comment already documents it. Extend that
comment: an `ALLOW-DESTRUCTIVE` line written for one gopher now releases the same
command for the *other* gopher too, for the rest of the session. Fixing that needs
per-agent keying, which is impossible at stamp time (the child's `agent_id` does
not exist yet). Document, do not fix.

### 5d. Dispatch early-allow (lines 427–439)

```js
    // A dispatch to either gopher is the desired outcome: never rewritten (they
    // cannot dispatch onward, so the directive would be pure waste), and it
    // resets the strict-mode consecutive-bypass streak (reward good behavior).
    const target = gopherKind(st);
    if (target) {
      if (key) {
        appendState(key + RESET);
        logEvent({ pid, aid, event: "dispatch", agent: target, tool: payload.tool_name, detail: st });
      }
      allow();
    }
```

`st` is already in scope from 5c's block? **No — it is not.** 5c's `st` is scoped
to its own `if` block. Re-declare `st` inside this block exactly as the current
code does at line 429. Do not hoist it; keeping the two blocks independent is what
lets 5c run before the `isEnabled()` gate and 5d after it.

---

## 6. `hooks/destructive.mjs` — honest dialog text

The permission prompt is the one artifact in this system written **at a human**,
and it has two seconds of their attention. Today it says "the Haiku runner" and
"task-gopher is a task-runner that makes no judgments." Both are false for
smart-gopher, and the second is worse than false — it would tell a user that a
Sonnet agent is incapable of judgment at the moment they are deciding whether to
trust it with `rm -rf`.

Add above `askMessage`:

```js
/**
 * How each runner is described to the human in the permission dialog. The
 * second line is the load-bearing one: task-gopher genuinely cannot judge, while
 * smart-gopher can — and telling the user otherwise at the moment they accept an
 * irreversible risk would be a lie in the worst possible place. What is true of
 * BOTH is that neither has the authority to accept the risk on the user's
 * behalf, and that is what the smart-gopher line says instead.
 */
const RUNNER = {
  "task-gopher": {
    who: "the Haiku runner",
    caveat:
      "task-gopher is a task-runner that makes no judgments — it cannot tell whether this is correct here, and it may have reached for it to make a failing command succeed.",
  },
  "smart-gopher": {
    who: "the reasoning runner",
    caveat:
      "smart-gopher can reason about a task, but reasoning ability is not authority: it cannot accept an irreversible or outward-facing risk on your behalf, and it may have concluded this was necessary from a partial view of your work.",
  },
};

const runnerInfo = (kind) => RUNNER[kind] || RUNNER["task-gopher"];
```

Then change both signatures and their first/caveat lines:

```js
export function askMessage(hits, preauthorized, kind = "task-gopher") {
  const { who, caveat } = runnerInfo(kind);
  const destructiveHit = hits.some((h) => h.kind === "destructive");
  const what = hits.map((h) => `${h.stage}   (${h.label})`).join("\n");
  const lines = [
    `${kind} — ${who} wants to run a ${destructiveHit ? "DESTRUCTIVE" : "an outward-facing"} command:`,
    "",
    what,
    "",
    destructiveHit
      ? "This can destroy work that is not recoverable."
      : "This sends something off this machine.",
    caveat,
  ];
  // …preauthorized block and trailing "Approve only if…" unchanged…
}
```

```js
export function denyMessage(hits, unaskableMode, kind = "task-gopher") {
  // …unchanged body, except the first line:
  return [
    `${kind} — BLOCKED: ${destructiveHit ? "destructive" : "outward-facing"} command.`,
    // …rest unchanged…
```

The default parameter keeps every existing call site and test valid.

Also update the module's opening block comment: its first paragraph asserts
"task-gopher is a Haiku runner with no Edit or Write tool, so `Bash` is the only
channel through which it can destroy anything." That is **true of task-gopher and
false of smart-gopher** — see §11. Rewrite that paragraph to state the guard now
covers both runners and to name the Edit/Write gap explicitly, so the next reader
does not inherit a stale safety argument.

---

## 7. `hooks/report.mjs` — split the counts

`/task-gopher report` currently prints `dispatches: N (delegations to task-gopher)`,
which becomes wrong the moment smart-gopher exists. The dispatch-vs-bypass ratio
is the plugin's main behavioral signal and it should stay legible.

After the existing `const dispatches = …` line, add:

```js
  const byAgent = (list, kind) =>
    list.filter((e) => (e.agent ? e.agent === kind : String(e.detail || "").includes(kind)));
```

The `e.agent ? … : …` fallback matters: logs written by earlier versions have no
`agent` field, and the report must not misreport historical lines. Falling back to
the `detail` substring (which holds the `subagent_type`) reads them correctly.
**Test `smart-gopher` before `task-gopher`** here too, or use the exported
`gopherKind` on `detail` — preferred, since it already encodes the ordering:

```js
import { LOG_FILE, gopherKind } from "./directive.mjs";
// …
  const agentOf = (e) => e.agent || gopherKind(e.detail) || "task-gopher";
  const smartDispatches = dispatches.filter((d) => agentOf(d) === "smart-gopher");
  const cheapDispatches = dispatches.filter((d) => agentOf(d) === "task-gopher");
```

Change the dispatch line to:

```js
  console.log(
    `dispatches:     ${dispatches.length}  (${cheapDispatches.length} task-gopher, ${smartDispatches.length} smart-gopher; ` +
      `${strictDispatches.length} in strict-gated turns)`
  );
```

And in the destructive-guard trail, prefix each interception with its runner:

```js
    for (const b of [...asked, ...blocked].slice(-RECENT)) {
      const labels = Array.isArray(b.labels) ? ` [${b.labels.join(", ")}]` : "";
      const what = b.event === "destructive-ask" ? "asked" : "blocked";
      const why = b.why ? ` (${b.why})` : "";
      console.log(`  - ${what} [${agentOf(b)}]: ${b.detail || "?"}${labels}${why}`);
    }
```

Everything else in the file is unchanged.

---

## 8. `hooks/sessionstart.mjs`, `hooks/userpromptsubmit.mjs`, `commands/task-gopher.md`, `README.md`, version

### 8a. sessionstart.mjs / userpromptsubmit.mjs

Mechanical rename only: `isTaskGopherAgent` → `isGopherAgent`, in both the import
and the `if (isEnabled() && !isTaskGopherAgent(input))` condition.

Both files' block comments end with "…and silent inside task-gopher itself."
Change to "…and silent inside either gopher." (These hooks never fire for
subagents anyway, per their own comments — the change is for correctness of the
predicate, not for a behavior that was broken.)

### 8b. `commands/task-gopher.md` — **no new subcommands**

**Decision: `/task-gopher` gains no smart-gopher toggle or status flag.** The
on/off marker, strict mode, guard mode, the allow-list and relay-exempt are all
**plugin-wide** state. Splitting any of them per-agent would double the state
files, double what a user must remember, and — worst — make it possible to leave
smart-gopher unguarded while believing the guard is on. That directly contradicts
scope decision 3. One plugin, one switch.

Four documentation edits, no behavior changes:

1. The `task-gopher.guard` bullet: `"…Bash command from the runner"` →
   `"…Bash command from either runner (task-gopher or smart-gopher)"`.
2. The `task-gopher.allow` bullet: `"written when a dispatch prompt carries an
   ALLOW-DESTRUCTIVE line"` → append `" — from a dispatch to either runner, and
   authorizations are keyed by session, not by agent, so one covers both for the
   rest of the session."`
3. The `guard off` line: append to its description
   `" — note smart-gopher also has Edit/Write, so 'off' is a wider hole than it was."`
4. The **ON-behavior blockquote** (the `> Dispatch expensive tool work…` block):
   insert before its `Escape hatch:` sentence —
   `> If an order genuinely cannot be made decision-free — which of several files,
   > a summary needing an editorial cut, steps that depend on what earlier steps
   > find — dispatch `task-gopher:smart-gopher` (Sonnet) instead of doing the work
   > yourself. It reasons but cannot dispatch onward, and design, correctness and
   > security calls still stay with you.`

Also update the frontmatter `description:` and `argument-hint:` **only** if you
change the subcommand list — you are not, so leave both byte-identical.

### 8c. `README.md`

The README is the plugin's front door and currently contains at least one
statement that becomes false. Anchor edits by text, not line number:

- Near "…injects a directive telling the main agent to dispatch to a bundled
  `task-gopher` subagent (pinned to `model: haiku`)" — add smart-gopher as the
  second bundled agent and its one-line remit.
- The section heading **"task-gopher is a runner, never a decider"** — add a short
  subsection after it, "…and smart-gopher is a decider about the *work*, never
  about the *project*", carrying the §4 distinction.
- The line reading approximately **"it applies **only** to task-gopher. Nobody
  else's hands are tied."** — this becomes **false**. Rewrite: the guard now
  applies to both bundled runners and to nobody else.
- The "Reaching subagents — the relay checkpoint" section's **Skipped:** list —
  `"dispatches *to* task-gopher (they are the point)"` → `"dispatches to either
  bundled gopher (they are the point, and neither can dispatch onward)"`.
- The model-tier section ("Delegation is gated by model tier…") — add that
  smart-gopher is Sonnet-tier and therefore *would* be a legal dispatcher by tier;
  what stops it is `disallowedTools`, not the tier gate.
- Add a short **"When to escalate to smart-gopher"** section carrying the same two
  triggers as the directive (§3a), so the README and the injected text agree.

### 8d. Version bump — **both files, together**

Hard repo convention. Bump **`0.12.0` → `0.13.0`** (new agent = feature, not patch):

1. `task-gopher/.claude-plugin/plugin.json` → `"version": "0.13.0"`
2. `.claude-plugin/marketplace.json`, the `task-gopher` entry → `"version": "0.13.0"`

The `description` string is currently **byte-identical** in both files. It must
stay so. Append this sentence to the description in **both**, immediately before
the closing `Toggle with /task-gopher.`:

> A second bundled runner, `smart-gopher`, is the Sonnet-tier escalation target for delegated work that genuinely needs judgment — it reasons about the work, cannot dispatch subagents of its own, and is covered by the same destructive guard, because reasoning ability is not authority over irreversible actions.

Consider adding `"reasoning"` to the `keywords` array in both. Optional; if you do
it, do it in both.

---

## 9. Test coverage

### Decision: extend the two existing suites, do not add a third file

Both existing harnesses (`tests/test-destructive-gate.sh`, `tests/test-relay-gate.sh`)
already carry the helpers the new cases need — `run_hook`, `check`, `is_allow`,
`is_deny`, `is_ask`, `is_inject`, `json`, the `FAKEHOME` sandbox with its
`trap 'rm -rf "$SANDBOX"' EXIT`, and the "real config untouched" assertions. A
third file would duplicate all of it. Guard cases go where the guard cases are;
relay cases go where the relay cases are.

Both keep their existing contract: `bash tests/<file>.sh`, exit 0 iff all pass.

### 9a. `tests/test-destructive-gate.sh`

Add next to the existing `gopher_bash()` helper (~line 32):

```bash
# A Bash call made BY the reasoning runner. Same guard, different agent_type.
smart_bash() { # <command> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:smart-gopher","prompt_id":"p1","session_id":"%s","tool_input":{"command":%s}}' \
    "${2:-sS}" "$(json "$1")"
}
smart_bash_mode() { # <command> <permission_mode> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:smart-gopher","permission_mode":"%s","prompt_id":"p1","session_id":"%s","tool_input":{"command":%s}}' \
    "$2" "${3:-sS}" "$(json "$1")"
}
smart_dispatch() { # <prompt> [session_id]
  printf '{"tool_name":"Agent","prompt_id":"p1","session_id":"%s","tool_input":{"subagent_type":"task-gopher:smart-gopher","prompt":%s}}' \
    "${2:-sS}" "$(json "$1")"
}
```

Cases — each must be a distinct `check`:

| # | Case | Assertion |
|---|---|---|
| D1 | plugin **OFF**: `smart_bash 'rm -rf /Users/x/proj/dist'` | `is_deny` — guard is live regardless of the toggle, same as task-gopher |
| D2 | `smart_bash 'git push origin main'` | `is_deny` (outward) |
| D3 | `smart_bash 'git worktree remove --force ../wt'` | `is_deny` |
| D4 | `smart_bash 'npm test \| tail -20'` | `is_allow` — benign work is never gated |
| D5 | `smart_bash_mode 'rm -rf …/node_modules' default` | `is_ask` — a human is reachable |
| D6 | `smart_bash_mode 'rm -rf …/node_modules' bypassPermissions` | `is_deny` — no human to ask, no authorization |
| D7 | `smart_dispatch 'ALLOW-DESTRUCTIVE: rm -rf /Users/x/proj/node_modules'` then `smart_bash_mode 'rm -rf /Users/x/proj/node_modules' bypassPermissions` (same session id) | `is_allow` — the release valve works for smart-gopher |
| D8 | **naming**, on the D5 output | `printf '%s' "$OUT" \| grep -q 'smart-gopher'` |
| D9 | **naming, negative** — the ordering trap | `! printf '%s' "$OUT" \| grep -q 'the Haiku runner'` |
| D10 | **honesty** — the caveat must not lie about a Sonnet agent | `! printf '%s' "$OUT" \| grep -q 'makes no judgments'` |
| D11 | task-gopher's own dialog is **unchanged** — rerun the existing `gopher_bash_mode 'rm -rf …' default` case | `is_ask` and `grep -q 'the Haiku runner'` |
| D12 | an ordinary agent is still untouched: `other_bash 'rm -rf …'` | `is_allow` (existing case; confirm it still passes) |

D8–D11 together are the regression test for the `task-gopher:smart-gopher`
substring collision described in §2. **They are the highest-value cases in this
spec** — the collision is silent, plausible, and lands in the permission dialog.

### 9b. `tests/test-relay-gate.sh`

| # | Case | Assertion |
|---|---|---|
| R1 | plugin ON, `payload "$DISPATCH_NOSENT" s1 task-gopher:smart-gopher` | `is_allow` — never stamped |
| R2 | R1's log line | `grep -q '"event":"dispatch"'` **and** `grep -q '"agent":"smart-gopher"'` |
| R3 | bare unnamespaced `smart-gopher` as `subagent_type` | `is_allow` |
| R4 | dispatch to smart-gopher **resets the strict streak** — mirror the existing `t4` sequence (~line 262): strict ON, run `READ_P` to bypass, dispatch to smart-gopher, run `READ_P` again | the post-dispatch read is checkpointed again, i.e. `is_deny` |
| R5 | **inside** smart-gopher: `{"tool_name":"Read","agent_type":"task-gopher:smart-gopher","prompt_id":"s5",…}` with strict ON | `is_allow` — smart-gopher is never checkpointed |
| R6 | `general-purpose` still gets stamped | `is_inject` (existing; confirm no over-broad match) |
| R7 | an agent named `smartish-helper` still gets stamped | `is_inject` — proves the match is not `*gopher*`-loose in a way that captures unrelated names |
| R8 | existing case "on: dispatch TO gopher never bounced" (`task-gopher:task-gopher`) | `is_allow`, and its log line carries `"agent":"task-gopher"` |

### 9c. Regression bar

Both suites must pass **in full** — `test-relay-gate.sh` is currently at 100
assertions per `docs/relay-gate-toolless-skip.md`. Report the before/after
assertion counts and the exit codes. Any pre-existing failure is a finding to
report, not something to fix inside this change.

---

## 10. NEEDS-EVIDENCE — verify before/while implementing

I could not run anything. Each item below is a fact the design depends on, what to
run, and what each outcome decides.

**NE-1 — What is `agent_type` at runtime for a plugin subagent?** *(highest risk;
if this is wrong, §5b's guard coverage silently does not exist.)*
The whole design assumes the hook payload's `agent_type` is a string containing
`"smart-gopher"` for a dispatched `task-gopher:smart-gopher`. The existing code's
own comment hedges ("substring match tolerates the plugin-scoped form"), which
suggests it was never pinned down.
*Run:* with the plugin installed and ON, dispatch `task-gopher:smart-gopher` with
an order to run one trivial `Bash` call (`echo hi`), then inspect
`~/.claude/task-gopher.log` — or temporarily add
`logEvent({ pid, aid, event: "debug-agent-type", detail: String(payload.agent_type) })`
at the top of the hook's `try` block.
*Decides:* if it contains `"smart-gopher"` → ship as specced. If it is the bare
name → still fine (substring). If it is the **plugin name only**, a display name,
or absent → §3's discriminator is wrong and the guard must key on something else
(candidate fallback: the `subagent_type` recorded at dispatch time, correlated by
`agent_id`). Stop and report before proceeding.

**NE-2 — Does `disallowedTools: Agent, Task` actually remove those tools from a
markdown-defined plugin agent?**
*Run:* dispatch smart-gopher and order it to report, verbatim, whether an `Agent`
(or `Task`) tool appears in its available tools, and to attempt one dispatch and
report the exact error.
*Decides:* if honored → ship as specced. If ignored → smart-gopher could recurse,
and the fallback is an explicit `tools:` allow-list (accepting the loss of MCP
tools, §4) **plus** adding `smart-gopher` to `RELAY_EXEMPT`. That is a real fork —
report it rather than choosing.

**NE-3 — Does `model: sonnet` resolve as an alias in plugin agent frontmatter?**
`task-gopher.md` uses `model: haiku` and works, so the alias form is supported; only
`sonnet` specifically is unconfirmed.
*Run:* dispatch smart-gopher, order it to report what model it is running as.
*Decides:* if it resolves → done. If not → use whatever exact id the harness
accepts. Low risk.

**NE-4 — Does the harness ever hand `subagent_type` through as something other
than what the caller typed?** The relay's `st.includes(...)` already assumes not.
Covered incidentally by R1/R3; no separate work.

---

## 11. Open decision for the user — I am NOT deciding this

### smart-gopher can `Edit` and `Write`. The guard only sees `Bash`.

`destructive.mjs` opens with this reasoning, and it was correct when written:

> task-gopher is a Haiku runner with no Edit or Write tool, so `Bash` is the only
> channel through which it can destroy anything.

…and, further down, under HONEST LIMITS:

> Writing files via `cat > f <<EOF` is NOT gated. It is out of scope here — the
> runner producing files is an over-reach problem, not a destruction one.

**Both arguments rest on a premise that smart-gopher breaks.** Under scope
decision 2 ("all tools except Agent"), smart-gopher has `Edit` and `Write`. It can
therefore overwrite or truncate a tracked source file with no guard involvement at
all — and `hooks.json`'s `PreToolUse` matcher is `"Read|Grep|Glob|Bash|Agent|Task"`,
so `Edit`/`Write` calls do not even reach the hook. Scope decision 3 says "more
reasoning ability is not more trust for irreversible actions", which argues the
user would want this closed; scope decision 2 says smart-gopher gets the full
toolset, which is precisely what opens it. **The two scope decisions are in
tension, and resolving that is the user's call, not mine.**

Three options:

- **(A) Accept for v1 — my recommendation.** Editing files is much of the point of
  a capable runner; gating it would make smart-gopher useless for the work it
  exists to do. Git is the recovery path for tracked files, and `git reset --hard`
  / `git checkout --` are already guarded, so an *un-doable* Edit still requires a
  guarded Bash command. **If you take this, the gap must be documented loudly** —
  in `destructive.mjs`'s block comment (§6), the README's guard section, and the
  `/task-gopher guard` help text. An undocumented safety premise that has quietly
  stopped being true is how the original incident this guard exists for happens
  again.
- **(B) Close it now.** Widen `hooks.json`'s matcher to include `Edit|Write|NotebookEdit`
  and add a path-based classifier (e.g. ask on any write outside a scratch/tmp
  path, or to any file not already staged). This is a materially larger change
  with its own false-positive design problem — the same one `destructive.mjs`
  calls "the real design constraint" — and it deserves its own spec.
- **(C) Drop `Edit`/`Write` from smart-gopher.** Cheapest and safest, but it
  contradicts scope decision 2 and reduces smart-gopher to "task-gopher that
  thinks", which may still be exactly what you want. Worth asking rather than
  assuming.

**Recommendation: (A) for this change, with the documentation made explicit, and
(B) filed as follow-up work if the user wants the hole closed.** If the user wants
(B) or (C), stop and re-spec — do not improvise either inside this change.

---

## 12. What must NOT change

- **`SENTINEL`** stays `"[task-gopher: ON]"`. It is a wire marker, top-anchored in
  `pretooluse-nudge.mjs` and asserted in `test-relay-gate.sh`.
- **`agents/task-gopher.md`'s "never delegate" rule stays** — with one word added
  (§13). task-gopher must never gain the ability to escalate to smart-gopher
  itself. It has no `Agent` tool, and the prompt-level rule is the documented hard
  backstop against recursion.
- **`hooks/agent-tools.mjs`** — no changes (see §4).
- **The guard's position above the `isEnabled()` check** in `pretooluse-nudge.mjs`.
  It is live whenever the plugin is *installed*, not when it is *on*, and that is
  deliberate.
- **`~/.claude/` state-file names and semantics.** No new state files. No
  per-agent guard mode, no per-agent toggle.
- **`relaySkipReason` / `RELAY_EXEMPT`** — unchanged. Adding smart-gopher there
  would be redundant with §5d's early allow.
- **Allowances stay session-keyed**, not agent-keyed (§5c).
- Existing `askMessage` / `denyMessage` call sites and tests must keep working —
  that is what the default `kind = "task-gopher"` parameter is for.

---

## 13. `agents/task-gopher.md` — two small amendments

task-gopher must **not** learn to escalate. It must learn to *name* the escalation
in the report it already writes, so the lead can act on it.

**(a)** In the bullet beginning `"You do the work yourself."`, change:

> Never dispatch or delegate to another subagent, and never dispatch to
> task-gopher — YOU are the gopher.

to:

> Never dispatch or delegate to another subagent — not to task-gopher (YOU are the
> gopher), and not to smart-gopher either. Escalating is the lead's move, never
> yours.

(It has no `Agent` tool, so this is belt-and-braces — but the existing rule names
only task-gopher, and a literal-minded runner could read a differently-named agent
as permitted.)

**(b)** At the end of the bullet beginning `"Never fill a gap with a judgment
call."`, after `"Handing the decision back to the lead is the correct move,
always."`, append:

> When you report a gap, say in one line WHAT KIND of judgment it needed — which
> of several candidates, what the order probably meant, whether something is safe.
> That is what tells the lead whether to re-specify the order for you or hand it
> to `smart-gopher` instead. Naming it is all you do; you never dispatch it.

No other changes to that file. Its `description`, `model: haiku`, and
`tools:` allow-list all stay exactly as they are.

---

## 14. Implementation order

Do it in this sequence — each step leaves the tree in a working state.

1. **NE-1 and NE-2 first** (§10). If either comes back wrong, stop and report;
   the rest of the design depends on them.
2. `hooks/directive.mjs`: add `gopherKind` / `agentGopherKind` / `isGopherAgent`,
   delete `isTaskGopherAgent`, update `FULL_DIRECTIVE` and `SHORT_REMINDER` (§3).
3. Rename the three call sites: `sessionstart.mjs`, `userpromptsubmit.mjs`,
   `pretooluse-nudge.mjs` (§5a, §8a). **Run both test suites — they must still
   pass with no smart-gopher in existence yet.** This is the safety checkpoint:
   it proves the rename is behavior-preserving before any new behavior lands.
4. `hooks/destructive.mjs`: `RUNNER` map, the two signatures, the block comment
   (§6).
5. `hooks/pretooluse-nudge.mjs`: the four gates (§5b–5d).
6. `agents/smart-gopher.md`: new file (§4).
7. `agents/task-gopher.md`: the two amendments (§13).
8. `hooks/report.mjs` (§7).
9. `commands/task-gopher.md` (§8b), `README.md` (§8c).
10. Version bump in **both** `plugin.json` and `marketplace.json` (§8d).
11. Tests (§9). Run both suites; report before/after assertion counts and exit
    codes.

## 15. Verification

- `bash task-gopher/tests/test-destructive-gate.sh; echo "exit=$?"` → 0
- `bash task-gopher/tests/test-relay-gate.sh; echo "exit=$?"` → 0
- `node -e 'import("./task-gopher/hooks/directive.mjs").then(m=>{
   console.log(m.gopherKind("task-gopher:smart-gopher"), m.gopherKind("task-gopher:task-gopher"),
   m.gopherKind("smart-gopher"), m.gopherKind("general-purpose"))})'`
  → `smart-gopher task-gopher smart-gopher null`
- `grep -rn 'isTaskGopherAgent' task-gopher/` → **no matches** (rename complete)
- `grep -n '"version"' task-gopher/.claude-plugin/plugin.json .claude-plugin/marketplace.json`
  → both `0.13.0`
- Both `description` strings still byte-identical:
  `node -e '…'` comparing the two JSON files' description fields → `true`
- Live smoke test: dispatch `task-gopher:smart-gopher` with an order to run
  `rm -rf /tmp/does-not-exist-smart-gopher-probe` and confirm the permission
  dialog appears, names **smart-gopher**, and does **not** say "the Haiku runner".
