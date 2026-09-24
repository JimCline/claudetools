---
name: agent-role
description: Define, edit, check, or remove a user-defined (custom) hierarchy ROLE and its agent file. Use for /ah:agent-role, for "add a custom role", "define my own agent/role", "make a ui-implementor", "custom reviewer/implementer/architect", "edit/remove a role", "which roles exist", or "why is my role unavailable". Adding a role to the roster afterwards is the agent-roster skill; standing up a live team is agent-team.
argument-hint: "[list|add|edit|remove|check] [name]"
---

# agent-role

A custom role is a `roles.<name>` row in `agent-hierarchy.json` with a
`class` (advise, design, review, implement, legwork) and an agent file.
`${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs role …` does every read, check and
write; this skill drives it. Never hand-edit the JSON, and never re-implement
its checks here.

`R` below is `node "${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs"`, always with
`--cwd <abs cwd>`. `R role set <name>` takes `--class <c>`, `--agent <ref>`,
`--label <l>`, `--description <d>`, `--routes <r>`, `--model <m>`,
`--dispatch peer|model`, `--level global|repo|repo-user`,
`--scaffold repo|user` and `--dry-run` (full reference: `docs/cli-tools.md`).

## What a class means

| Class | Step it can stand in for | Tool contract (errors) | Conventions (warnings) |
|---|---|---|---|
| advise | Escalate (Ultra-Advisor); every dispatch needs the user's approval | Read, SendMessage; explicit fable/opus model | no Edit, NotebookEdit, advisor |
| design | Design (Architect); tier rule applies | Read, SendMessage, Write | no Bash, NotebookEdit, advisor |
| review | Review (Reviewer) | Read, SendMessage; must NOT have Edit, Write, NotebookEdit | has Bash; no advisor |
| implement | Implement (Implementor) | Read, SendMessage, Edit or Write, Write or Bash | has Bash; no advisor |
| legwork | none (errands, dispatchable by any role) | none | none |

A row with `routes` is an in-chain **alternative** to its step's built-in for
that work. Without `routes` it is a **side role**, dispatched only when the
user asks for it or its description fits.

## Asking the user

Every question goes through AskUserQuestion: at most 4 options, the
recommended one first, free text via Other, and independent questions
batched (up to 4 per call).

## list

Run `R role list`. Render one line per role: name, built-in/custom, class,
agent, model, chain placement, and the contract status (`ok`,
`n warnings`, `UNAVAILABLE: n errors`, `UNAVAILABLE → reverted to ah:<role>`,
or `shipped`). List excluded rows with their reasons.

## check [name]

Run `R role list --json`. For each role (or just `name`) with findings, run
the fix loop below.

## add

1. **Name.** Suggest one from the user's words, plus up to two variants. Its
   peer name is `<team-prefix>-<name>`, which Herdr caps at 32 characters
   (`[a-z][a-z0-9_-]`) — suggest only names that fit here, and keep them short
   for a global role, since other repos have their own prefixes.
2. **Class.** Offer the inferred class first; the fifth is reachable via
   Other. Each option is one line: its gates and its tool contract (table
   above).
3. **Early check.** `R role set <name> --class <c> --dry-run`. A row-level
   refusal (reserved name, alias collision, bad charset) is re-asked now.
4. **Chain placement** (chain classes only): "Alternative to <Builtin> for
   specific work" or "Side role". An alternative needs `routes`: offer a
   drafted sentence, a tighter variant, or Other.
5. **Agent file**, from the dry-run's `agent_file` status:
   - found: "Use existing <path> (Recommended)" or "Point at a different agent";
   - not found: "Scaffold ~/.claude/agents/<name>.md — passes the contract,
     usable in every repo (Recommended)", "Scaffold .claude/agents/<name>.md
     in this repo only", "I'll write my own file first" (stop here —
     the user writes it and re-runs add or check), or "Use an existing agent"
     via Other.
6. **Model.** The class allowlist, class default first. advise needs an
   explicit fable or opus.
7. **Description.** "Use the agent file's description (Recommended)" when it
   has one, or "Write a one-line description".
8. **Level.** global (Recommended), repo, or repo-user — but when the agent
   file is repo-level, recommend repo instead, since a global row pointing at
   it is unavailable in every other repo. Say so when the level does not
   match where the agent file lives.
9. **Pre-flight.** The full `R role set … --dry-run`. Errors → the fix loop,
   then dry-run again until there are none.
10. **Commit.** Show the exact command, run `R role set …`, and report the row,
    the file path and any warnings.
11. **Specialisation** (scaffolded files only). Ask for it, then Edit only the
    placeholder line under `## Specialisation`.
12. **Offer** "Add it to the roster now?" → `/ah:agent-roster add`.

## Fix loop (add, edit, check)

For each **error** finding, one AskUserQuestion built from its `fix` list —
never invent a fix:

- "Fix the agent file for me (Recommended)" — only when the file is a
  user-owned bare-name file (repo or user level), never a plugin agent's
  file, and only for `edit-frontmatter` fixes. Apply exactly that frontmatter
  edit with one Edit (add or remove a tool, remove `model:`, fix `name:`),
  then re-validate. To restrict a tool, remove it from `tools` or add it to
  `disallowedTools` — never a scoped entry like `Bash(git:*)`, which grants
  the whole tool.
- "Change the role's class to <suggested>" — when a `change-class` fix is
  present (a review-class file with Edit suggests implement).
- "I'll fix it myself" — stops the loop.

`remove-file` fixes are instructions only: show them; never act on them, and
never offer "Fix … for me" for a finding whose only fix is `remove-file`.

Warnings: show them as a list, then one question — "Fix warnings too?" (all
or none) or "Leave them". The file body is never edited, except the scaffold
placeholder.

## edit

1. Pick the role.
2. MultiSelect the fields: routes, description, model, agent, class. For a
   built-in only agent and model.
3. Ask each chosen field as in add.
4. Dry-run and the fix loop.
5. `R role set <name>` with only the changed flags.

## remove

1. Confirm.
2. `R role remove <name>`. If it refuses because roster members use the role,
   offer removing them via `/ah:agent-roster`, or cancel.
3. Offer to delete the agent file, keyed on where it resolved (`role list`
   shows the path) — the default is always keep, and this is the only place
   this skill deletes an agent file:
   - bare repo-level file: "Keep it (Recommended)" / "Delete it";
   - bare user-level file: first say plainly that it may be live in other
     repos, then "Keep it (Recommended)" / "Delete it anyway";
   - `plugin:agent`: never offered — say in one line that the file belongs to
     the plugin;
   - a built-in override: the same rules, applied to the override's file after
     `role remove`.
