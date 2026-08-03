# claudetools and superpowers

[obra/superpowers](https://github.com/obra/superpowers) is the best-known skills library
for Claude Code. claudetools gets compared to it, so this document does the comparison
honestly — including the places superpowers is the better answer.

**Visual version:** [docs/superpowers-comparison.html](./superpowers-comparison.html)
([rendered](https://htmlpreview.github.io/?https://github.com/JimCline/claudetools/blob/main/docs/superpowers-comparison.html))

---

## The short version

They operate at different layers, and almost every apparent overlap dissolves once you
see that.

**superpowers is the document layer.** Its unit of delivery is a `SKILL.md` the model
reads and chooses to follow. It covers *what process to run* — brainstorm first, write a
plan, test first, debug systematically, verify before claiming done.

**claudetools is the control layer.** Its unit of delivery is a hook that injects,
rewrites, or blocks. It covers *who executes the work and what is allowed to reach your
context* — with the model fixed in the role definition rather than chosen per dispatch.

superpowers would gain enforcement from these hooks. claudetools would gain a methodology
it currently has no opinion about. They are not competitors.

## What each repo contains

| | superpowers `6.2.0` | claudetools |
|---|---|---|
| Unit of delivery | Skill documents | Hook scripts |
| Enforcement | Advisory — the model reads and complies | Mechanical — injected, rewritten, or denied |
| Skills | 14 | 1 |
| Agent definitions | 0 registered (3 role prompt templates, each requiring an explicit `model:`) | 6 |
| Slash commands | 0 | 3 |
| Hook scripts | 1 | 10 |
| Lifecycle events hooked | 1 | 6 |
| Host platforms | Claude Code, Codex, Cursor, Kimi, Gemini, opencode | Claude Code only |

### Where each touches the request lifecycle

| Event | superpowers | claudetools |
|---|---|---|
| `SessionStart` | ✅ `startup\|clear\|compact` | ✅ all four plugins, plus `resume` (and `fork` on two) |
| `UserPromptSubmit` | — | ✅ task-gopher |
| `PreToolUse` | — | ✅ output-discipline (Bash gate), task-gopher (Agent rewrite) |
| `PostToolUse` | — | ✅ comment-discipline |
| `SubagentStart` | — | ✅ comment-discipline |
| `SubagentStop` | — | ✅ agent-hierarchy (token accounting) |

superpowers takes one seat and everything after it is persuasion. claudetools takes six,
including the two that change outcomes rather than suggest them: `PreToolUse` can deny a
call outright, and the same hook can rewrite a dispatch prompt before it leaves.

## Delegation economics

The easy reading is that superpowers delegates for focus and claudetools delegates for
cost. That reading is wrong. superpowers ships a four-tier model policy with an explicit
cost thesis — *"Use the least powerful model that can handle each role to conserve cost
and increase speed"* — and its design notes carry per-run dollar figures.

The two projects independently arrived at the same invariant, in almost the same words —
both of these are shipped, user-facing text:

> Use the least powerful model that can handle each role to conserve cost and increase
> speed.
>
> — superpowers, `skills/subagent-driven-development/SKILL.md`

> **Keep for yourself: ALL reasoning** — design decisions, correctness/security judgment,
> tradeoffs. For a task that needs reasoning, SPLIT it: have the runner gather the raw
> material and return a compact report, then you reason over the report.
>
> — claudetools, task-gopher directive

That is convergent evolution, not overlap to be resolved. superpowers' internal design
notes put the same guardrail more sharply still — *"cheapen mechanics, never judgment,"*
with the requirement that every cheapened decision be shown *mechanical*: deterministic,
scriptable, or cheaply verifiable after the fact. The disagreements are all downstream of
the shared rule.

### Divergence 1 — where the model decision lives

| | superpowers | claudetools |
|---|---|---|
| Granularity | Per dispatch | Per role |
| Chosen by | The controller, using judgment | Assigned once via `/hierarchy set`, or hard-pinned |
| Ladder | mechanical → cheap · integration → standard · architecture and final review → most capable · reviews scaled to diff risk · stuck fix-loop escalates "at least one tier above the implementer that got stuck" | Fixed per role for the session |

superpowers documents the failure mode itself: an omitted `model:` *"inherits your
session's model — often the most capable and most expensive — which silently defeats this
section."* A policy written in prose has to be remembered at every dispatch. A policy
written in frontmatter does not.

### Divergence 2 — what the cheapest tier is actually for

This reads at first like a direct challenge to the task-gopher design. Read in full, it
isn't — it's the same rule:

> **Turn count beats token price.** Wall-clock and context cost scale with how many turns
> a subagent takes, and the cheapest models routinely take 2-3× the turns on multi-step
> work — costing more overall. Use a mid-tier model as the floor **for reviewers and for
> implementers working from prose descriptions**. When the task's plan text contains the
> complete code to write, the implementation is transcription plus testing: **use the
> cheapest tier for that implementer.** Single-file mechanical fixes also take the
> cheapest tier.

The governing variable is not model tier — it is **specification completeness**. The 2-3×
multiplier is measured on cheap models asked to *derive* what to do from prose. Where the
work is fully specified, superpowers reaches for the cheapest tier itself.

task-gopher's runner operates inside exactly that carve-out by construction: it accepts
fully-specified, decision-free orders and stops rather than guessing. So the Haiku pin is
not in tension with the finding — it is the same rule stated twice, once as a judgment the
controller makes per dispatch, once as a contract the runner enforces.

**Where the churn relocates.** It does not vanish, and three things are worth naming:

- **Ambiguity detection is itself reasoning.** "Stop if the order is ambiguous" asks the
  runner to *recognize* ambiguity — a judgment call handed to the model instructed not to
  judge. It can fail in both directions: proceed on an ambiguous order, or bounce on a
  clear one. This is the softest joint in the design.
- **A bounce lands on the most expensive component.** It costs an orchestrator turn plus a
  re-dispatch, and the orchestrator is the largest line item in the breakdown below. A high
  bounce rate does not remove churn; it moves it onto the priciest model in the system.
- **The residual risk is quality, not turns.** A runner that does not reason also does not
  flag an implausible result. Constraining it to mechanical work relocates the requirement
  to the orchestrator's review of the report rather than eliminating it.

**The number that settles this is bounce rate** — the fraction of dispatches returning
incomplete, blocked, or needing takeover. Near zero, and pinning the runner beats the
mid-tier floor for this scope. High, and the churn has simply moved upward. It is cheap to
instrument: `SubagentStop` already parses transcripts for token counts, and classifying a
report as complete-versus-bounced is a text check, not a model call.

### Divergence 3 — what gets measured

superpowers' design spec breaks one plan-execution run down by component:

| Component | $ | Driver |
|---|---|---|
| Controller (session model, opus) | ~6-7 | ~150 turns × resident context; prompt-immune turn floor (46% thinking/narration) |
| Implementers (sonnet, 10-13 dispatches) | ~5-6 | the actual work; ~25 turns each |
| Task reviewers (sonnet, 10) | ~1-1.5 | 3-9 turns each with package |
| Final review + fixes | ~1 | 6 turns with branch package |

**The controller is the largest line item — not the workers.** Three things follow for
claudetools:

1. **This validates output-discipline more than it validates the Haiku pin.** If the
   coordinator's resident context is half the bill, the highest-value lever is whatever
   keeps tool output out of the orchestrator — the `PreToolUse` Bash gate and
   task-gopher's "dispatch must COMPRESS" rule — not which model runs the grep.
2. **"Prompt-immune turn floor" is a warning about directive stacking.** They measured 46%
   of controller turns going to thinking and narration, and found it did not respond to
   prompt changes. claudetools injects four directives at `SessionStart`; that is a cost
   hypothesis worth testing rather than assuming.
3. **The methodology is the borrowable part.** Blind A/B with a planted-defect quality
   gate over N=5 runs is a real answer to "did this actually save money, or just move it."
   `/hierarchy usage` already collects the spend side at zero model cost; pairing it with a
   quality gate is the next step, and superpowers has demonstrated the shape.

*The dollar figures come from `docs/superpowers/specs/2026-06-10-strict-cost-sdd-design.md`,
which describes a measured configuration but labels its own proposals "Proposed experiment
ladder (not implementation)" — the breakdown is measurement, the ladder above it is not
shipped behavior. The Model Selection guidance quoted above **is** shipped, in
`skills/subagent-driven-development/SKILL.md`.*

## Genuine overlap

Three more beyond delegation, each differing on axis rather than just in wording.

**Separating the plan from the build.** superpowers' `writing-plans` → `executing-plans`
separates them *in time*: a plan document of 2–5 minute tasks, loaded in a fresh session.
agent-hierarchy separates them *by capability*: the Architect is denied `Bash` and `Edit`,
so it structurally cannot start building, and the Implementor stops and reports upward
when the spec is silent rather than deciding.

**Code review as a dispatched role.** superpowers has `requesting-code-review` and
`receiving-code-review` — and it is the only one of the two with anything to say about
*receiving* a review. agent-hierarchy's Reviewer is read-only by construction and
classifies each finding **impl-defect** or **spec-defect**, which is the only one of the
two that turns a verdict into a routing decision.

**Surviving compaction.** Both inject at `SessionStart`. Identical mechanism, opposite
payload: superpowers injects a *table of contents* and spends its budget on skill
discovery; claudetools injects the *rules themselves* and spends its budget on compliance.

## What superpowers has that claudetools does not

Not gaps claudetools intends to fill — different scope. If you want these, install
superpowers.

- **Test-driven development** — red/green/refactor as a mandated cycle. claudetools has no
  opinion on testing whatsoever.
- **A brainstorming gate** before any creative work.
- **Systematic debugging** — four phases before a fix is proposed.
- **Verification before completion** — evidence before assertion.
- **Worktree isolation and branch landing** — setup up front, then merge/PR/keep with cleanup.
- **`writing-skills`** — a meta-skill for authoring skills, test-driven-documentation style.
- **Portability.** Documents travel between hosts; hooks do not. superpowers ships
  manifests for Codex, Cursor, Kimi, Gemini, and opencode.
- **Measured cost, not asserted cost.** Per-run dollar figures, a component-level
  breakdown, and quality gates over N=5 runs with blind A/B parity. claudetools collects
  per-role spend at zero model cost; the matching quality gate is open work.
- **An ecosystem** — a sibling marketplace with ten plugins.

## What claudetools has that superpowers does not

- **Hard blocking.** A `PreToolUse` gate denies `tail -f`, `watch`, and unfiltered test
  runs before they execute. superpowers registers no `PreToolUse` hook, so nothing it asks
  for is enforceable.
- **Rewriting a dispatch in flight.** task-gopher edits the `Agent` tool's prompt via
  `updatedInput` so every subagent carries the directive.
- **Policy that reaches subagents.** superpowers deliberately hands each subagent
  hand-crafted context and never the session's history — a sound choice for *task*
  context, but it leaves standing *policy* with no channel at all.
- **Per-role model assignment**, with `SubagentStop` recording usage per role at zero
  token cost.
- **Tool denial as design** — reasoning roles denied execution, the Reviewer denied writes.
- **Model choice that cannot be omitted.** The model lives in the agent definition, not in
  the dispatch prompt. superpowers warns that an omitted `model:` "silently defeats" its
  own cost section — a failure mode that is structurally impossible here.
- **Context-flood defense** — capture to a file, grep it, report the exit code.
- **Comment hygiene**, re-injected after every `Edit`/`Write`.

## Running both

They stack, with one decision to make first.

**Composes well**

- `verification-before-completion` × output-discipline. superpowers tells you to run the
  command and read the output; that is exactly the flood output-discipline gates. Together
  you get the right shape: run it, capture it, grep it, report the exit code.
- `subagent-driven-development` × the task-gopher relay. superpowers is right that a
  subagent should not inherit your session history — but standing policy is not history.
  The `PreToolUse` Agent rewrite carries rules to every child without carrying the
  transcript.
- `test-driven-development` × agent-hierarchy. The Implementor is the natural home for
  red/green/refactor, and a failing test routes more cleanly through the Reviewer's
  spec-defect classification than through a generic review comment.

**Friction to expect**

- **Contention for the top of the context.** superpowers wraps its injection in
  `<EXTREMELY_IMPORTANT>` and asks for a skill invocation before any response.
  task-gopher asks for a dispatch first. Two "before you do anything" mandates in one block.
- **Two org charts for one question.** `writing-plans`/`executing-plans` and
  Architect→Implementor are competing answers. Pick one — this is the decision to make
  before installing both.
- **Asymmetric survival on resume.** superpowers matches `startup|clear|compact` but not
  `resume`; every claudetools plugin matches `resume`. On a resumed session your rules are
  present and its mandate is not.
- **Skills that ask for denied tools.** `dispatching-parallel-agents` assumes the caller
  can dispatch. Inside an agent-hierarchy reasoning role, that tool may be denied.

**A reasonable combined setup:** superpowers for methodology (TDD, debugging, brainstorming,
verification, worktrees), claudetools for the control plane (output-discipline,
task-gopher, comment-discipline). Skip agent-hierarchy if you are already using
`writing-plans`/`executing-plans`, or skip those if you want the hierarchy's tool-level
enforcement instead.

## Why gates, and where they stop working

The failure claudetools exists to prevent is not disobedience. No model reads "delegate the
legwork" and decides to defy it. What happens is **erosion through locally-reasonable
exceptions**: this grep is tiny, that file is half in context already, dispatching has
overhead, the answer is needed now. Every individual call is defensible. The aggregate is
the directive ignored.

Prose defends against this badly, because the rationalization feels like judgment from the
inside — and judgment is exactly what the model has been told to keep for itself. So the
useful question is not "is this rule written down" but **how many times must the model
choose to obey it**. That gives a ladder, strongest first:

| | Mechanism | Example |
|---|---|---|
| 1 | **Structurally impossible** — the decision doesn't exist to be eroded | model pinned in agent frontmatter; Reviewer denied `Write`; Architect denied `Bash` |
| 2 | **Hard-denied** at `PreToolUse` | output-discipline's Bash gate. Only safe for machine-checkable invariants — `tail -f` is wrong every time |
| 3 | **Checkpoint with an escape hatch** | task-gopher strict mode, for rules where the call needs judgment and a deny would sometimes be wrong |
| 4 | **Injected directive** | restated at `SessionStart` / `SubagentStart` / `PostToolUse` — survives compaction, still re-decided every turn |
| 5 | **Prose in a document** | read once, decays with distance and context pressure — a `CLAUDE.md` paragraph, a `SKILL.md` section |

> A directive is a decision the model must re-make every turn.
> A structure is a decision made once.

Read that way, the strongest work here is not the blocking — it is rung 1. A model pinned in
an agent definition is not *enforced*, it is **unforgettable**: there is no per-dispatch
choice left to erode. The gates are the enforcement arm of a larger principle — move policy
out of the space of per-turn decisions, and gate only what has to stay behavioral. **Gate
mechanics; nudge judgment.**

The strongest independent evidence for this comes from the other side of this comparison.
superpowers closes its Model Selection section with a confession about its own medium:

> Always specify the model explicitly when dispatching a subagent. An omitted model
> inherits your session's model — often the most capable and most expensive — **which
> silently defeats this section.**
>
> — superpowers, `skills/subagent-driven-development/SKILL.md`

That is a document observing that documents fail, and prescribing more document. Their own
measurement found the ceiling directly: a "prompt-immune turn floor" of 46% of controller
turns spent on thinking and narration that *did not respond to prompt changes*. They
located the limit of prompt-only control empirically and kept building beneath it.

### Where this argument stops

- **Judgment cannot be gated.** "Is this step reasoning or legwork?" is not
  machine-checkable, which is why task-gopher ships a checkpoint rather than a deny. The
  thing you most want — good delegation *decisions* — lives on the nudge side of that line
  and always will. Hooks compress the rationalization space; they cannot close it.
- **Every gate is a tax on every turn.** False positives cost real time (see
  [output-discipline-false-positive-quoted-data.md](./output-discipline-false-positive-quoted-data.md)),
  and each injected directive is resident context on every request — the exact line item
  superpowers measured as the largest cost in their system. Four directives is fine; the
  drift toward ten is where a control plane starts costing what it saves.
- **Compliance is demonstrated; efficacy is not.** That the gates fire and change behavior
  is observable. Whether gated delegation nets out *cheaper* than good prompts plus nothing
  is measured nowhere, by either project. Applying to these plugins the same standard they
  apply to the model is the open work.

---

*Drawn against superpowers `6.2.0` (default branch `main`) and claudetools as of
agent-hierarchy 0.6.0, comment-discipline 0.3.0, output-discipline 0.1.2, task-gopher
0.7.1. Both projects move quickly, and the claudetools plugins are a work in progress —
their designs are expected to change as real-world findings come in, so where this page
reads a difference as a deliberate choice, treat it as the current state rather than a
settled position. Corrections welcome by issue or PR, particularly from the superpowers
side: that half was read from the shipped skills and hooks manifest rather than from
running it in anger.*
