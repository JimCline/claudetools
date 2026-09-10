# ah CLI reference

Every agent-hierarchy operation is a Bash call to one of two scripts this plugin ships:

```
node <AH_ROOT>/hooks/roster.mjs <verb> [args…] --cwd <absolute cwd>
node <AH_ROOT>/hooks/msg.mjs    <verb> [args…] --cwd <absolute cwd>
```

There is no MCP server as of 0.73.0 (spec 0048; it was removed because the daemon could be
"down" — `/reload-plugins` fires no SessionStart, so an in-session update left the tools
disconnected). A CLI call either runs or prints node's own error.

`<AH_ROOT>` is the plugin's installed root. Hooks publish it: every session the SessionStart hook
injects into gets a line reading

```
ah CLI root: <AH_ROOT> — roster: `node <AH_ROOT>/hooks/roster.mjs <verb> --cwd <abs cwd>`, messages: `node <AH_ROOT>/hooks/msg.mjs <verb> --cwd <abs cwd>` (verbs: agent-hierarchy/docs/cli-tools.md)
```

and every hook message that tells a role to run something spells the absolute command. Subagents
get no SessionStart injection by design; the hook messages are their channel. Never guess the
path — if no root line is in context, ask the Orchestrator for it.

## Invocation rules

- `--cwd <absolute path>` on every verb. The CLIs resolve the hierarchy dir, the git root and the
  worktree/main-checkout relationship from it; a relative path or a missing one is a bug in the
  caller, not a default.
- One simple command. No `cd … &&` prefix, no `VAR=1` prefix, no pipe, no redirection, no `$VAR`
  and no command substitution — `--cwd` and `--orchestrator-pid` exist precisely so nothing needs
  shell expansion. The permission hook below recognises only this form.
- JSON arguments (`--args`, `--verified`, `--created`, `--geometry`) travel **single-quoted**.
- Output is always JSON. A non-zero exit means the JSON or the stderr line says why. Exit 3 is a
  *partial* result (`layout-splits`, `create`): real work happened, not all of it — read the JSON.
- `--help`, or no verb at all, prints the script's usage block and exits 0.
- Identity: both CLIs resolve the orchestrator session pid from `--orchestrator-pid` if given,
  else `CLAUDE_PID`, which every Claude Code session exports into the Bash tool's environment.
  The documented form omits the flag; tests, a human shell, and `adopt` (which requires it) use it.

## Permission

The plugin ships a PreToolUse hook (`hooks/pretooluse-ah-cli.mjs`) that returns `allow` for these
two scripts, so ah calls raise no Bash permission prompt. It allows only the grammar above, only
when the script's realpath is under the hook's own installed root or a sibling of it, and never for
a `dismiss`/`disband … --close` command — those stay behind the always-ask close gate
(`hooks/pretooluse-disband-close-gate.mjs`), which prompts every single time. The roster skill
gate's one-per-session `deny` also outranks the `allow`.

Posture: this grants prompt-free execution of two scripts the plugin itself ships, with arguments
restricted to that grammar. The remaining state-changing verbs (`untrack --commit`, `reap
--commit`, `create --commit`, `remove`) are bookkeeping on ah's own state files and were
auto-allowed as MCP calls too.

If you run without plugin hooks, allowlist the two scripts yourself in **user** scope
(`~/.claude/settings.json`) — user, not project, because the path lives under
`~/.claude/plugins/cache` and the rule has to survive version bumps:

```json
{
  "permissions": {
    "allow": ["Bash(node */hooks/roster.mjs *)", "Bash(node */hooks/msg.mjs *)"]
  }
}
```

Spell them exactly like that: the leading `node ` with its space is what keeps a `nodejs-foo`
binary from matching.

## Reading the roster

To inspect the roster run `node <AH_ROOT>/hooks/roster.mjs show --cwd <abs cwd>`; never read
`.claude/agent-hierarchy.json` directly — it misses the worktree/main-checkout and global fallback
resolution that `show` implements.

## After an update, mid-session

Your context still holds the old `<AH_ROOT>`. Old and new version dirs coexist under the plugin
cache, so the old CLI keeps running — stale code, still working. If the old dir is gone, node says
`Cannot find module …/hooks/roster.mjs`; start a new session and use the `ah CLI root:` line it
prints.

## Verbs

`--cwd <abs>` is required on every line below and elided from the table. `<R>` = `<AH_ROOT>`.

| verb | command |
|---|---|
| new message file | `node <R>/hooks/msg.mjs new --to <role> --from <role> --slug <s> [--to-name <n>] [--from-name <n>] [--parent <id>] [--reason context\|second-opinion\|parallel] [--eta small\|medium\|large] [--type request\|response] [--id <id>] [--team <t>] [--req <abs request path>]` |
| list exchanges | `node <R>/hooks/msg.mjs list [--open\|--closed\|--all] [--to <role>] [--team <t>] [--plain]` |
| downstream dispatches | `node <R>/hooks/msg.mjs downstream [--root-name <n>]` |
| index one message file | `node <R>/hooks/msg.mjs index <abs path>` |
| message roster line | `node <R>/hooks/msg.mjs roster [--team <t>]` |
| sweep closed exchanges | `node <R>/hooks/msg.mjs sweep [--days 7]` |
| show roster | `node <R>/hooks/roster.mjs show [global\|repo\|repo-user] [--level <L>] [--team <t>]` |
| list teams | `node <R>/hooks/roster.mjs teams [--orchestrator-pid <pid>]` |
| init roster level | `node <R>/hooks/roster.mjs init [level] [--level <L>] --route peer\|subagent\|pane [--layout <mode>]` |
| add roster member | `node <R>/hooks/roster.mjs add [level] [--level <L>] --role <R> [--model <M>] [--effort <E>] [--route peer\|subagent\|pane] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing auto\|prompt\|never]` |
| edit roster member | `node <R>/hooks/roster.mjs edit [level] [--level <L>] --member <name> [--role <R>] [--model <M>] [--effort <E>] [--route …] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing …]` |
| remove roster member | `node <R>/hooks/roster.mjs remove [level] [--level <L>] --member <name>` |
| team-wide pane layout | `node <R>/hooks/roster.mjs layout [level] [--level <L>] [--layout auto\|columns\|grid]` |
| team alias | `node <R>/hooks/roster.mjs alias [--level global\|repo\|repo-user] [--set <name>] [--clear] [--team <t>]` |
| create a team | plan: `node <R>/hooks/roster.mjs create [--plan] [--team <t>] [--roster-level <L>]` · spawn: `… create --spawn --mode auto\|columns\|grid [--roster-level <L>]` · commit: `… create --commit --verified '<json>' --transport <t> --roster-level <L> [--partial] [--session <orchestrator session id>] [--orchestrator-pid <pid>]` · from history: `… create --from <id\|alias> [--team <t>] [--plan\|--commit\|--spawn]` |
| adopt an orphaned team | `node <R>/hooks/roster.mjs adopt --orchestrator-pid <pid> [--team <t>]` |
| reap orphaned records | `node <R>/hooks/roster.mjs reap [--commit]` |
| herdr layout phase | `node <R>/hooks/roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--next --created '<json>'] [--apply --target <pane id> --direction right\|down]` — exit 3 = partial, read the JSON |
| disband a team | plan: `node <R>/hooks/roster.mjs disband [--plan] [--team <t>]` · close: `… disband --close --confirm --plan-token <tok> [--allow-global] [--team <t>]` |
| resync member locations | `node <R>/hooks/roster.mjs resync [--dry-run] [--team <t>] [--bind <b>]` |
| move a member's pane | `node <R>/hooks/roster.mjs move <name> --tab <t> [--split right\|down]` · `… move <name> --new-tab [--workspace <w>]` · `… move <name> --new-workspace` · all take `[--dry-run] [--allow-global] [--team <t>]` |
| team history | `node <R>/hooks/roster.mjs history` |
| spawn one roster member | `node <R>/hooks/roster.mjs spawn-one <role> [--member <name>] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` |
| spawn an ad hoc member | `node <R>/hooks/roster.mjs spawn-ad-hoc <role> [--model <M>] [--effort <E>] [--kind <K>] [--route peer\|pane] [--args '<json>'] [--auto-mode <A>] [--on-missing …] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` (`--role <role>` is accepted in place of the positional) |
| dismiss one member | plan: `node <R>/hooks/roster.mjs dismiss <name> [--plan] [--team <t>]` · close: `… dismiss <name> --close --confirm --plan-token <tok> [--also-config] [--level <L>] [--allow-global] [--team <t>]` |
| untrack (close nothing) | `node <R>/hooks/roster.mjs untrack <name>\|--all [--plan\|--commit] [--keep-sessions] [--also-config] [--level <L>] [--team <t>]` |
| re-register this session | `node <R>/hooks/roster.mjs checkin [--team <t>] [--orchestrator-pid <pid>]` |
| split decision (tests) | `node <R>/hooks/roster.mjs next-split --mode <m> --pane-count <N> --self <pane id> --created '<json>' --geometry '<json>'` |
| route preference | `node <R>/hooks/msg.mjs route peers\|subagents\|prefer-peers --session <id>` |
| global-scope answer | `node <R>/hooks/msg.mjs global-scope roster\|config allow\|deny --session <id>` |

Flags are validated per verb: `spawn-one`, `spawn-ad-hoc`, `adopt`, `checkin`, `dismiss`,
`disband`, `untrack`, `resync`, `move`, `alias` and `reap` reject any flag not in their own set, so
the lists above are exhaustive for those verbs rather than indicative.

`/agent-team` (teams) and `/agent-roster` (the roster template) are the skills that drive these
verbs; their SKILL.md files are the operational protocol, this file is the surface.
