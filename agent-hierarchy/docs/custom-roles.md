# Custom roles, and members in other harnesses

Define your own role, put it on the roster, and — if you want — run a member
on Codex instead of Claude. Assumes you already know the roster, a Team and
peers ([getting-started.md](./getting-started.md)).

Every command is `node <AH_ROOT>/hooks/roster.mjs <verb> … --cwd <abs cwd>`
(`R` below); the full flag list is in [cli-tools.md](./cli-tools.md).
`/ah:agent-role` drives the `role` verbs for you, so you rarely type them.

## 1. What a custom role is

A `roles.<name>` row in `agent-hierarchy.json` with two things that matter: a
**class** and an **agent file**. `roster.mjs role` does every read, check and
write — don't hand-edit the JSON.

The class says which step of the chain the role may stand in for, and what its
agent file must look like. The contract is checked when you define the role:

| Class | Stands in for | Tool contract (errors) | Conventions (warnings) |
|---|---|---|---|
| `advise` | Escalate (Ultra-Advisor); every dispatch needs your approval | Read, SendMessage; an explicit `fable` or `opus` model | no Edit, NotebookEdit, advisor |
| `design` | Design (Architect); the tier rule applies | Read, SendMessage, Write | no Bash, NotebookEdit, advisor |
| `review` | Review (Reviewer) | Read, SendMessage; must **not** have Edit, Write, NotebookEdit | has Bash; no advisor |
| `implement` | Implement (Implementor) | Read, SendMessage, Edit or Write, Write or Bash | has Bash; no advisor |
| `legwork` | nothing — errands any role can dispatch | none | none |

Errors refuse the write; warnings print and the write goes ahead.

A bare `agent` name resolves to `<repo>/.claude/agents/<name>.md`, then
`~/.claude/agents/<name>.md`; the first that exists wins.

## 2. Where it sits in the chain

Two placements, for the chain classes (`advise`, `design`, `review`,
`implement`):

- **Alternative** — the row has `routes`, a sentence saying what work it takes.
  It is an in-chain alternative to the built-in for that step, for that work
  only. Example: a Docs-Writer with `routes: "standalone docs: READMEs, docs/,
  guides, changelogs"` takes the docs while the Implementor keeps the code.
  Both are live at once.
- **Side role** — no `routes`. Dispatched only when you ask for it or its
  description fits.

`routes` on a `legwork` role warns and is ignored.

**Who runs as what.** Only a `legwork`-class role can ever run as a subagent
(`--dispatch model`, or a roster `route: subagent`). Every other role — custom
or built-in — runs as a peer session, and the route gate denies a chain role
dispatched as a subagent.

## 3. Defining one

Ask for it, and answer the questions:

```
/ah:agent-role add
```

It suggests a name, the class, placement (and a drafted `routes`), the agent
file, the model, a one-line description and the level, then runs a dry run,
then the write.

**The name.** Lowercase letters, digits and `-`, starting with a letter, at
most 31 characters (`/^[a-z][a-z0-9-]{0,30}$/`). It can't end in `-` or
`-<digits>` (that suffix is a peer's instance number), and it can't be a
built-in role's name or `orchestrator`, `advisor` or `other`. It also becomes
part of the peer name (`<team-prefix>-<name>`), which Herdr caps at 32
characters in total (`[a-z][a-z0-9_-]{0,31}`) — keep it short, especially for
a global role, since every repo has its own prefix.

The command underneath:

```
R role set docs-writer --class implement \
  --routes "standalone docs: READMEs, docs/, guides, changelogs" \
  --scaffold user --dry-run
```

| Flag | Meaning |
|---|---|
| `--class advise\|design\|review\|implement\|legwork` | the class (§1) |
| `--agent <ref>` | the agent file: a bare name, or `plugin:agent` |
| `--routes "<sentence>"` | makes it an alternative; `--routes ""` demotes it to a side role |
| `--description`, `--label`, `--model` | as named; `--description ""` deletes the key |
| `--dispatch model` | legwork only (exit 2 otherwise) |
| `--level global\|repo\|repo-user` | where the row lives; default is where the role is already defined, else `repo` with `--scaffold repo`, else `global` |
| `--scaffold user\|repo` | write a template agent file that passes the contract: `~/.claude/agents/<agent>.md` or `<repo>/.claude/agents/<agent>.md` |
| `--dry-run` | write nothing; print the findings |

Drop `--dry-run` to commit. If the agent file is repo-level, define the role at
`repo` too — a global row pointing at it is unavailable in every other repo.

**The fix loop.** Each error finding prints its fix. In `/ah:agent-role` you
choose: let it apply a frontmatter fix for you (only to your own bare-name
file, never a plugin's), change the role's class to the one it suggests, or
fix it yourself. To restrict a tool, remove it from `tools` or add it to
`disallowedTools` — never a scoped entry like `Bash(git:*)`, which grants the
whole tool. Then it dry-runs again until there are no errors.

**The Specialisation section.** A scaffolded file is a short identity
paragraph, then `## Specialisation` with one placeholder line. Replace that
line with what makes this role yours; the hierarchy contract arrives by
injection, so the file never restates it. `/ah:agent-role` asks you for the
text and edits only that line.

Check and inspect:

```
R role list            # class, agent, model, placement, contract status
R role list --json     # adds each role's findings
R role remove <name>   # refused while a roster member uses it; never deletes a file
```

A role that fails its contract shows `UNAVAILABLE: n errors`.

## 4. Using it

Add it to the roster, then start it:

```
R add --role docs-writer --model opus
R spawn-one docs-writer          # a roster-conforming member
R spawn-ad-hoc docs-writer       # a member the roster doesn't describe
R create --spawn                 # or the whole team
```

The spawn verbs also take `--dry-run`, which prints the launch line and starts
nothing. `add` only writes the template; it launches nothing. A live Team is not
changed by a roster edit — use `spawn-one` or `spawn-ad-hoc` to add a member.
`/agent-team` and `/agent-roster` drive these.

**Models.** A member's model is stored only when you set one. Add it without
`--model` and you are asked at spawn; answer with `--model <M>` on `spawn-one`,
or `--member-model <name>=<M>` on `create`, for that spawn only. Without one,
the spawn is refused with `member-model-undefined` and lists the models the
class allows. `edit
--model ""` clears a stored one. An `advise` role always needs an explicit
`fable` or `opus`.

## 5. A member in another harness (Codex)

A roster member's `kind` picks the agent CLI Herdr starts. Omitted means
`claude`. Set `kind: codex` and it runs in Codex:

```
R add --role architect --kind codex --model <codex-model> --route pane
```

Which model names are valid depends on your account; `codex debug models`
lists them.

What changes for a non-Claude member:

- **`route` must be `pane`**, and spawning needs a Herdr session
  (`HERDR_ENV=1`). `add` and `edit` work anywhere.
- **`model`** is the harness's own model name, checked for shape only; the
  harness checks it at the first turn. `effort` is rejected. `auto_mode` is
  translated into Codex's sandbox and approval flags. `args` passes native
  flags verbatim, but not a model flag if `model` is set, nor Codex's approvals
  setting (`approvals_reviewer`, which every member launches with its own), and
  not at all on an advise-class member.
- **Its contract** is not loaded the way a Claude agent's is. Each spawn writes
  standing instructions to `<hierarchy dir>/instructions/<name>.md` — identity,
  the role's agent body, how a brief and a report work outside Claude Code —
  and launches Codex with them.
- A Codex member whose `auto_mode` leaves a read-only sandbox (`manual`,
  `plan`) gets a warning: it can't write its report without an approval in its
  pane.

**Tiers.** The hierarchy ranks models by Claude's tiers. For a Codex model,
you declare where it stands:

```
R tier set codex <codex-model> opus
R tier list
R tier remove codex <codex-model>
```

It is stored only in the global config. An **Ultra-Advisor** (advise class) on
a non-Claude kind must run on a model declared `opus` or `fable`; otherwise the
spawn is refused with `advise-model-tier` and prints the `tier set` command to
re-run. The tier is your call — an agent asks you rather than declaring it.

**Briefing it.** Claude Code's SendMessage can't reach a non-Claude member. The
Orchestrator briefs it with `deliver`, in the background:

```
R deliver <name> --req <abs request path>
```

It sends the request's `[hierarchy-msg …]` line, a `Report to:` path and the
standing-instructions path, waits for the turn to end, and returns a `status`
(`reported`, `no-report`, `busy`, `blocked`, …). The report is only the
response file. Nothing is sent to a member that is working or at a prompt. A
brief to an Ultra-Advisor needs your approval for the session, as it does for a
Claude one.

**Prompts.** Codex can stop at a trust dialog, a sign-in or an approval. Spawn
and `deliver` report it as `blocked` with the screen verbatim and the options
it recognises. The Orchestrator asks you, then sends your choice:

```
R answer <name> --prompt <blocked_by> --choice <id> --screen-hash <hash>
```

It sends only when the screen still shows that prompt and option, and never
free text. If no option is offered, or you'd rather do it yourself, answer in
the pane and the Orchestrator re-runs. Trusting a directory is always yours.
If Codex shows its trust dialog, that is a prompt like any other: it comes back
`blocked` with trust and distrust options, and you pick. Only when no prompt is
recognised *and* Codex's own config says the directory is untrusted is the
spawn refused (`harness-cwd-untrusted`) and its pane closed; run `codex` there
once and answer its question.

**Limits.**

- **Tool limits are advisory outside Claude.** A Codex member's agent file
  can't enforce `disallowedTools`; Codex's own sandbox is the only real limit,
  and it follows your Codex configuration.
- **Keys are pinned to the tested Codex version.** The prompt options and the
  idle-composer check match `codex-cli 0.154.0-alpha.6.2`. A changed label or
  layout is not offered or sent (it fails closed): the brief comes back
  `blocked` with `harness-prompt` and no options, and you answer in the pane.

## Where to go next

- [cli-tools.md](./cli-tools.md) — every verb and flag.
- [`agent-role`](../skills/agent-role/SKILL.md),
  [`agent-roster`](../skills/agent-roster/SKILL.md),
  [`agent-team`](../skills/agent-team/SKILL.md) — the protocols behind the
  commands.
- [troubleshooting.md](./troubleshooting.md) — symptom → cause → fix.
