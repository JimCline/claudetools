# claudetools

A Claude Code plugin marketplace — hooks that enforce agent behaviour instead of
asking for it.

## Install

```
/plugin marketplace add JimCline/claudetools
/plugin install output-discipline@claudetools
```

## Why hooks, not prompts

The failure these plugins exist to prevent is not disobedience. No model reads "delegate
the legwork" and decides to defy it. What happens is **erosion through locally-reasonable
exceptions**: this grep is tiny, that file is half in context already, dispatching has
overhead, the answer is needed now. Every individual call is defensible. The aggregate is
the directive ignored.

Prose defends against this badly, because the rationalization feels like judgment from the
inside — and judgment is exactly what the model has been told to keep for itself. So the
useful question is not "is this rule written down" but **how many times must the model
choose to obey it**. That gives a ladder, strongest first:

| | Mechanism | Here |
|---|---|---|
| 1 | **Structurally impossible** — the decision doesn't exist | model pinned in agent frontmatter; Reviewer denied `Write`; Architect denied `Bash` |
| 2 | **Hard-denied** at `PreToolUse` | output-discipline's Bash gate. Only safe for machine-checkable invariants |
| 3 | **Checkpoint with an escape hatch** | task-gopher strict mode, for rules where a deny would sometimes be wrong |
| 4 | **Injected directive** | survives compaction, but is re-decided every turn |
| 5 | **Prose in a document** | read once, decays with distance |

> A directive is a decision the model must re-make every turn.
> A structure is a decision made once.

Read that way, the strongest thing here isn't the blocking — it's rung 1. A model pinned in
an agent definition isn't *enforced*, it's **unforgettable**: there's no per-dispatch choice
left to erode. The gates are the enforcement arm of a larger principle — move policy out of
the space of per-turn decisions, and gate only what has to stay behavioral. **Gate
mechanics; nudge judgment.**

**Where this stops.** Judgment can't be gated: "is this step reasoning or legwork" isn't
machine-checkable, which is why task-gopher ships a checkpoint rather than a deny. Every
gate is also a tax — false positives cost real time, and each injected directive is
resident context on every request. And while it's observable that the gates fire and change
behavior, whether gated delegation nets out *cheaper* than good prompts plus nothing is
not yet measured. That's open work.

## Using superpowers?

These plugins compose with [obra/superpowers](https://github.com/obra/superpowers)
rather than competing with it. superpowers is the **document layer**: fourteen skills
describing *what process to run* — brainstorm, plan, test first, debug, verify.
claudetools is the **control layer**: ten hook scripts across six lifecycle events
deciding *who executes the work and what reaches your context* — with the model fixed in
the role definition rather than chosen per dispatch.
superpowers hooks `SessionStart` and everything after it is persuasion; these plugins
also hook `PreToolUse`, so a rule can deny a call rather than suggest against it.

Both projects independently landed on the same delegation rule — superpowers writes it
"cheapen mechanics, never judgment", task-gopher writes it "keep the judgment, dispatch
only the legwork". What differs is where the model decision lives: a tier superpowers'
controller picks per dispatch, versus a value fixed in an agent definition here.
superpowers documents the failure mode of its own approach — an omitted `model:`
"silently defeats" its cost section — which is the gap these plugins close.

Two other places they fit: `verification-before-completion` tells Claude to run the
command and read the output, which is exactly the flood `output-discipline` gates; and
superpowers is right that a subagent shouldn't inherit your session history, but standing
policy isn't history — `task-gopher`'s `PreToolUse` rewrite carries rules to every child
without carrying the transcript.

Full comparison, including what superpowers does better and the one genuine conflict:
**[docs/superpowers-comparison.md](./docs/superpowers-comparison.md)**
(visual version: [docs/superpowers-comparison.html](./docs/superpowers-comparison.html),
[rendered](https://htmlpreview.github.io/?https://github.com/JimCline/claudetools/blob/main/docs/superpowers-comparison.html)).

## Plugins

### [output-discipline](./output-discipline)

Stops command output from flooding the context window. A `PreToolUse` hook blocks
context-flooding Bash commands **before they run** — `tail -f`, `watch`, foreground
servers, unfiltered test suites — and tells Claude what to run instead (background
tasks, redirect-then-grep, subagent delegation). A `SessionStart` hook injects the
rules, including after compaction.

Prevention, not compression. Composes with `PostToolUse` compressors like squeez.

### [comment-discipline](./comment-discipline)

Stops Claude writing **ephemeral comments** — `// changed from foo to bar`,
`// NEW: added validation`, `// as suggested, kept for backwards compat`,
`// for now` — the narration that only parses while the diff is on screen and
describes a transition nobody can see once it merges. A comment's audience is the
next person to *read* the code, not whoever reviews the change; git history
already records what changed.

Where `github-pr-toolkit`'s `/code-critic` catches these at review time, this stops
them being written. A `SessionStart` hook injects the rule on startup and after
compaction — and unlike the plugins above it deliberately does **not** suppress
itself inside subagents, since subagents write plenty of code too.

It never asks for prose: the absence of a comment is not a defect, so it can't
backfire into defensive doc-comments. Public-API contracts and why-this-is-non-obvious
explanations are explicitly encouraged, and time markers survive with a qualifier —
`// TODO(#4127): remove once the v2 endpoint lands` is good, bare `// for now` is not.
Run `/comment-discipline init` once to enable it globally or per-repo (project scope
wins over user); `/comment-discipline on|off|status` toggles it.

### [task-gopher](./task-gopher)

Makes the main, high-reasoning agent **dispatch the legwork to a cheap Haiku
runner** — running tests/builds, sifting logs, grepping the tree, gathering
information — and reason over the compact report it hands back. Expensive model
tokens go to judgment, not to tool output. The runner carries out explicit orders
only: it never reasons or decides, and stops to report back rather than guess.
Toggle on/off with `/task-gopher` (ships OFF, opt-in). Includes an escape hatch so
the main agent takes over if the runner falls short.

### [agent-hierarchy](./agent-hierarchy)

Splits work across **six roles with a model each** — visual map in
[docs/hierarchy.html](./agent-hierarchy/docs/hierarchy.html)
([rendered](https://htmlpreview.github.io/?https://github.com/JimCline/claudetools/blob/main/agent-hierarchy/docs/hierarchy.html)) —
Orchestrator (the session
agent itself), Ultra-Advisor, Architect, Reviewer, Implementor, Task-Runner.
Design reasoning goes to a strong model that writes a spec file and never
implements; the Implementor builds exactly that spec and reports gaps up instead
of deciding; a read-only Reviewer validates the diff and labels each finding
**impl-defect** or **spec-defect** so it routes back to the right role.
Run `/hierarchy` once to
assign the models — user-scoped or committed per-repo — and a `SessionStart` hook
injects the resolved role→model table plus the orchestration protocol, including
after compaction. Silent inside subagents, so role dispatches don't pay for it.

Above the Architect sits the **Ultra-Advisor** (defaults to `fable`; `opus` is
the only alternative — no `sonnet`, no `inherit`). It is an escalation apex, not
a routine step: it runs when the Architect couldn't resolve a fork or reported
low confidence, when the review loop stalls, when the blast radius is outsized
(security, auth, data migration, concurrency, public interfaces), or when you
say a problem is important. It adjudicates and never implements.

Tool access follows the roles rather than describing them, and **the reasoning
tiers never execute**: the Architect is denied `Bash` outright — an empirical
question becomes a NEEDS-EVIDENCE item handed back through the Orchestrator —
and the Reviewer reads diffs itself (read-only git) but must delegate every
suite, build, or script run to the Haiku runner and judge the compact report.
The Reviewer is denied `Edit`, `Write`, and `NotebookEdit`, so read-only is
structural; the Architect and Ultra-Advisor are denied `Edit` and keep `Write`
only to author a spec; the Implementor — the one role that both changes product
code and runs what it builds — is denied nothing but the generic `advisor`
tool, which every reasoning role refuses: escalation goes through the
Orchestrator, not sideways to a model you may already be running. Task-Runner
stays on a fixed read/search/bash allowlist with no MCP access. The
Orchestrator polices all of it: work a role did outside its lane is rejected
and re-routed, not accepted.

**Handoffs are the user's to control**: `auto` (default) runs the chain and
reports; `confirm` asks before each reasoning-role dispatch — approve, do it
inline, or skip — switchable mid-session in plain words, in either direction.
A `SubagentStop` hook also records every subagent's token usage from its
transcript at **zero model cost**; `/hierarchy usage` renders per-role
session/day/week/month reports, `/usage`-style.

Tiered so small work stays cheap: trivial edits skip the chain entirely, and
fully-specified requests skip the Architect but keep the Reviewer. When
task-gopher is installed, the Task-Runner role delegates to it, so both plugins
point retrieval at the same Haiku runner. `/hierarchy status` shows the effective
table and where each value came from; `/hierarchy set <role> <model>` tweaks one
role; `/hierarchy flow` switches handoff mode; `/hierarchy off` silences it.

## License

MIT
