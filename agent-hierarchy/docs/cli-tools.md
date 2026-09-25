# ah CLI reference

Every agent-hierarchy operation is a Bash call to one of two scripts this plugin ships:

```
node <AH_ROOT>/hooks/roster.mjs <verb> [args…] --cwd <absolute cwd>
node <AH_ROOT>/hooks/msg.mjs    <verb> [args…] --cwd <absolute cwd>
```

There is no MCP server as of 0.73.0 (spec 0048; it was removed because the daemon could be
"down" — `/reload-plugins` fires no SessionStart, so an in-session update left the tools
disconnected). A CLI call either runs or prints node's own error.

`<AH_ROOT>` is the plugin's installed root. Three independent channels publish it, because no one
of them covers every case:

1. **The skill and agent files name it directly.** `${CLAUDE_PLUGIN_ROOT}` is substituted at load
   time in `skills/*/SKILL.md` and `agents/*.md` as well as `commands/`, so a role's own contract
   arrives carrying the absolute path.
2. **SessionStart and UserPromptSubmit inject a root line** — `lib-config.mjs`'s `cliRootLine()`,
   one source of truth for both:

   ```
   ah CLI root (v<version>): <AH_ROOT> — roster: `node <AH_ROOT>/hooks/roster.mjs <verb> --cwd <abs cwd>`, messages: `node <AH_ROOT>/hooks/msg.mjs <verb> --cwd <abs cwd>` (verbs: agent-hierarchy/docs/cli-tools.md)
   ```

   SessionStart alone is not enough: `/reload-plugins` fires no SessionStart, so a session that
   updates mid-flight would never hear the new root. UserPromptSubmit repeats the line on every
   prompt, which covers that and survives compaction. Both use the same classification — nothing
   for subagents, nothing when the hierarchy is configured-and-disabled. The `(v…)` token is the
   plugin version that emitted the line: when two root lines in one context disagree, the most
   recent one wins.
3. **SubagentStart injects the same line into an Agent-tool subagent** — the only event that fires
   there, and it carries the line only inside its `hookSpecificOutput` envelope.
4. **Hook messages** that tell a role to run something spell the absolute command.

If all four somehow failed you, resolve the root — do not guess it, and never glob the cache dir
(several versions coexist there):

```
node -e 'const p=require(process.env.HOME+"/.claude/plugins/installed_plugins.json").plugins,k=Object.keys(p).find(x=>/^(ah|agent-hierarchy)@/.test(x));console.log([].concat(p[k])[0].installPath)'
```

The key is `ah@<marketplace>` (or `agent-hierarchy@<marketplace>`) and its value is an **array** of
install records — hence `[].concat(p[k])[0]`.

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

`/reload-plugins` fires no SessionStart, so nothing re-announces the root at update time — but the
UserPromptSubmit hook re-states the `ah CLI root:` line on your next prompt, and after a reload that
line comes from the NEW version dir. Take the most recent one in context. Until then the old CLI
keeps running from the old version dir (they coexist under the cache) — stale code, still working.
If the old dir is gone, node says `Cannot find module …/hooks/roster.mjs`; send another prompt and
read the fresh root line, or resolve it with the recipe above.

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
| show roster | `node <R>/hooks/roster.mjs show [global\|repo\|repo-user] [--level <L>] [--roster <r>]` — members are shown under the default team name; when a team could not use that name, a `team_name_note` says so |
| list teams | `node <R>/hooks/roster.mjs teams [--orchestrator-pid <pid>]`. The top-level object carries the same `sources` block as `disband`; `untracked_live` rows from `herdr agent list` alone are marked `source: "herdr"`. |
| init roster level | `node <R>/hooks/roster.mjs init [level] [--level <L>] --route peer\|subagent\|pane [--roster <r>]` |
| add roster member | `node <R>/hooks/roster.mjs add [level] [--level <L>] [--roster <r>] --role <R> [--model <M>] [--effort <E>] [--route peer\|subagent\|pane] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing auto\|prompt\|never]` — `--on-missing` defaults to `auto`; a model and an effort are stored only when given, so a member added without `--model` is asked for one when it is spawned |
| edit roster member | `node <R>/hooks/roster.mjs edit [level] [--level <L>] [--roster <r>] --member <name> [--role <R>] [--model <M>] [--effort <E>] [--route …] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing …]` — `--model ""` and `--effort ""` clear the field |
| remove roster member | `node <R>/hooks/roster.mjs remove [level] [--level <L>] [--roster <r>] --member <name>` |
| create a team | plan: `node <R>/hooks/roster.mjs create [--plan] [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--roster-level <L>]` · spawn: `… create --spawn [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--roster-level <L>]` · commit: `… create --commit --verified '<json>' --transport <t> --roster-level <L> [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--partial] [--session <orchestrator session id>] [--orchestrator-pid <pid>]` · from history: `… create --from <id\|alias> [--team <t>] [--mode …] [--plan\|--commit\|--spawn]`. `--team` is the team's name (default: the repo basename, or a legacy `team.json`'s own prefix); `--roster <r>` builds it from `rosters.<r>` (default: the `roster` block) and a missing block is an error; a `rosters.<t>` block matching `--team <t>` without `--roster` is only warned about (`warnings`). `--mode` defaults to the global `teamLayout` (`~/.claude/agent-hierarchy.json`), else `auto`; a plan reports `layout: {mode, source}` with source `explicit` \| `stored` \| `default`, and an explicit `--mode` on `--spawn`/`--commit` is stored as `teamLayout` for future teams (`--plan` stores nothing). The committed team file records `roster` (the block key, `null` for the default) and `layout`. A roster-driven plan lists `named_rosters` (the valid `rosters.*` keys at every level, sorted) when there are any. Config keys that no longer do anything — `teamAlias`, a roster block's `layout`, a `teamLayout` outside the global file — are reported in every phase's `warnings` (and by `doctor` and `/hierarchy status`), never in session context. A name that cannot be used gets the `team-name-unusable` refusal below. Every phase also takes `--member-model <name>=<model>` (repeatable: the model that member runs on this time, never written to the roster); an unknown or repeated name, a non-claude member, or a model its class does not allow exits 2. A plan lists `members_needing_model` (last) when a launched member has no model — entries shaped as in the `member-model-undefined` refusal below — and never refuses on models; `--spawn` refuses. A claude-kind legwork member with no model is skipped while task-gopher is installed (per `installed_plugins.json`): it is not launched, listed or recorded, never makes the team `partial`, and every phase reports it in `skipped_members: [{name, role, handoff: "task-gopher:task-gopher"}]` with a `message` — its legwork goes to task-gopher subagents. `--no-legwork-handoff` (every phase) counts task-gopher as not installed, so such a member is listed for a model like any other; a driver that cannot dispatch `task-gopher:task-gopher` passes it. |
| adopt an orphaned team | `node <R>/hooks/roster.mjs adopt --orchestrator-pid <pid> [--team <t>]` |
| reap orphaned records | `node <R>/hooks/roster.mjs reap [--commit]` |
| herdr layout phase | `node <R>/hooks/roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--next --created '<json>'] [--apply --target <pane id> --direction right\|down]` — exit 3 = partial, read the JSON |
| disband a team | plan: `node <R>/hooks/roster.mjs disband [--plan] [--team <t>]` · close: `… disband --close --confirm --plan-token <tok> [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op). Every plan and close result carries `sources` — which of team file / peers.jsonl / `herdr agent list` was consulted, what each yielded, and the name prefix searched under. A plan also carries `next`: the exact close command to run once the user agrees (absolute path, `--confirm --plan-token`, plus `--team`/`--cwd` as given and `--allow-global` only when the close would demand it) — copy it, assemble nothing. A close result adds `pruned: [name…]` (a nameless row appears as its role), `kept: [{name, why}]` (`why` ∈ `added` \| `close-failed` \| `live` \| `indeterminate`), `team_removed`, and `team_file` (`null` when no team file was involved): `--close` reconciles the team file itself, so no bookkeeping call follows it. Top-level `closed` is true iff every close that was attempted succeeded (vacuously true when nothing was closable); whether every member is gone is what `pruned` / `kept` / `team_removed` report. The resolved team file, when it exists but does not read as a team record (unparseable, or parsing to something with no `members` array), is reported as `team_file_unreadable: <path>` and is never written or removed. A plan always carries `next`, even when no member has a pane: running it then closes nothing and still reconciles the record. |
| resync member locations | `node <R>/hooks/roster.mjs resync [--dry-run] [--team <t>] [--bind <b>]` |
| move a member's pane | `node <R>/hooks/roster.mjs move <name> --tab <t> [--split right\|down]` · `… move <name> --new-tab [--workspace <w>]` · `… move <name> --new-workspace` · all take `[--dry-run] [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op) |
| team history | `node <R>/hooks/roster.mjs history` |
| spawn one roster member | `node <R>/hooks/roster.mjs spawn-one <role> [--member <name>] [--model <M>] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` — `--model` launches the member on `M` this time only (a member with no model stored needs it: `member-model-undefined` below); not skill-gated; `--allow-global` is an accepted no-op — under Herdr the member name must be `[a-z][a-z0-9_-]`, at most 32 characters; a longer one is refused before any pane opens |
| spawn an ad hoc member | `node <R>/hooks/roster.mjs spawn-ad-hoc <role> [--model <M>] [--effort <E>] [--kind <K>] [--route peer\|pane] [--args '<json>'] [--auto-mode <A>] [--on-missing …] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` (`--role <role>` is accepted in place of the positional) — no roster needed; not skill-gated; global roster ignored (`--allow-global` accepted, no-op) — under Herdr the member name must be `[a-z][a-z0-9_-]`, at most 32 characters; a longer one is refused before any pane opens |
| dismiss one member | plan: `node <R>/hooks/roster.mjs dismiss <name> [--plan] [--team <t>]` · close: `… dismiss <name> --close --confirm --plan-token <tok> [--also-config] [--level <L>] [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op). Plans and close results carry the same `sources` block as `disband`, and a plan carries the same `next` close command. With no team file (for instance right after `disband --close` removed it): exit 0 with `dismissed: false, reason: "no active team and no live peers"` when the peer registry offers no closable session; exit 2, listing the live untracked sessions and the name / pane_id / session_id values `dismiss` accepts, when it does. |
| untrack (close nothing) | `node <R>/hooks/roster.mjs untrack <name>\|--all [--plan\|--commit] [--keep-sessions] [--also-config] [--level <L>] [--team <t>]`. Idempotent: with no team file it exits 0 with `untracked: false, already_untracked: true, reason: "no team file to forget"`. |
| re-register this session | `node <R>/hooks/roster.mjs checkin [--team <t>] [--orchestrator-pid <pid>]` — the output carries `team` when this session is attributed to one (`null` for a legacy `team.json`); a create commit refuses a verified member object whose `team` is not the team being committed |
| who am I / where is my orchestrator (peer) | `node <R>/hooks/roster.mjs whoami [--team <t>]` — read-only, writes nothing, exit 0 whenever the lookup ran. Matches this session's pane id (`HERDR_PANE_ID`, else this pid's `peers.jsonl` row, else `TMUX_PANE`) against every team record, or only `--team`'s. A launched member knows its team first from `AH_TEAM_FILE`, which the launcher sets on every member it starts; the pane match is the fallback. Output: `member: {name, role, route}\|null`, `team` (`null` for the legacy `team.json`), `team_file`, `orchestrator: {pid, session_id, live, send_to}\|null`, `answered_by`: `env` \| `pane` \| `null`, `reason`: `null` \| `no-pane-id` \| `no-team` \| `not-a-member` \| `ambiguous` (then `candidates: [{team, name}]`). An `AH_TEAM_FILE` that is not a team file of this repo is never followed; it is reported, beside that real outcome, as `env_team_invalid: {value, kind, why}` with `kind` `other-repo` (a well-formed team file of another repo's hierarchy dir) or `malformed`, and is absent when the variable is unset or accepted. `session_id` is passed through as recorded, and is `null` on every path the agent-team skill uses. `send_to` is usable directly as SendMessage `to`, but is best-effort — derived from the pid, non-null only while the orchestrator is alive and its session socket exists. Reply precedence: the brief's `reply-to` (or the orchestrator's session name from `ListAgents`) is authoritative — see [comms-protocol.md](comms-protocol.md); `send_to` is the fallback when that is lost. The socket directory follows this session's own `CLAUDE_CODE_MESSAGING_SOCKET` when the harness exports it (else `/tmp/cc-socks`); the real directory is harness-owned, so `send_to` stays best-effort. Every output, whatever its `reason`, also carries `last_observed_brief: {from, from_name, reply_to, ts}\|null` — the last obligation row a hook filed for this session in `~/.claude/agent-hierarchy.peer-pending.jsonl`, any status, with `from_name` `null` when none was recorded. These values are observed, not verified: they say who last briefed this session, which can differ from the recorded `orchestrator`, and like `send_to` they are a fallback below the brief's `reply-to` and the `ListAgents` name. `null` is the expected value, not a failure, in two cases: no session id resolves (`CLAUDE_CODE_SESSION_ID`, else the `session_id` on this pid's `peers.jsonl` row), or no row exists — only a sentinel or `[hierarchy-msg …]` brief files one, a plain cross-session message does not, and its absence does not make the session unaddressable. It never changes `reason`. |
| list roles | `node <R>/hooks/roster.mjs role list [--json]` — every built-in and custom role: class, agent, model, level, chain placement (`alt. to <Builtin>: <routes>`, `side`, `legwork`), effective description, and contract status (`shipped`, `ok`, `n warnings`, `UNAVAILABLE: n errors`, or `UNAVAILABLE → reverted to ah:<role>` for a failing built-in override). Invalid rows are listed as `excluded` with their reasons. `--json` adds each role's findings, and `path` names the agent-file copy that was checked. |
| define or change a role | `node <R>/hooks/roster.mjs role set <name> [--class advise\|design\|review\|implement\|legwork] [--agent <ref>] [--label <l>] [--description <d>] [--routes <r>] [--model <M>] [--dispatch peer\|model] [--level global\|repo\|repo-user] [--scaffold repo\|user] [--dry-run]` — upserts one row at one level (default: the level the role is already defined at, else `repo` with `--scaffold repo`, else `global`), seeded from the effective row. A built-in takes only `--agent`, `--model` and `--dispatch`. `--routes ""` / `--description ""` delete the key. The agent file is validated against the class contract: errors refuse the write and print each finding with its fix; warnings print and the write proceeds. `--scaffold` writes a template that passes the contract, and removes it again if the write fails. `--dry-run` writes nothing. |
| remove a role | `node <R>/hooks/roster.mjs role remove <name> [--level <L>]` — refused while any roster member uses the role; never deletes an agent file. For a built-in, removes only its `agent` override. |
| self-check this install | `node <R>/hooks/roster.mjs doctor [--check]` — read-only JSON, one row per thing that can be wrong; `--check` exits 1 on any red row |
| split decision (tests) | `node <R>/hooks/roster.mjs next-split --mode <m> --pane-count <N> --self <pane id> --created '<json>' --geometry '<json>'` |
| route preference | `node <R>/hooks/msg.mjs route peers\|subagents\|prefer-peers --session <id>` — `peers` is the default; `subagents`/`prefer-peers` are the user's opt-in, `peers` revokes it |

A team file that exists but does not read as a team record (unparseable, or parsing to something
with no `members` array) is never written over. `create` (plan included),
`spawn-one` and `spawn-ad-hoc` exit 2 before anything launches when the file they resolve to —
`--team <t>`'s, the default `teams/<prefix>.json`, or a legacy `team.json` — is in that state, naming
its absolute path and the remedy: repair or remove it, or use a different `--team`. Read verbs never
refuse; beside an unparseable legacy `team.json` a bare read verb resolves to that legacy file
rather than to `teams/<prefix>.json`, so it reports that scope.

Flags are validated per verb: `spawn-one`, `spawn-ad-hoc`, `adopt`, `checkin`, `whoami`, `dismiss`,
`disband`, `untrack`, `resync`, `move` and `reap` reject any flag not in their own set, so
the lists above are exhaustive for those verbs rather than indicative.

`--team <t>` names a live team, never a roster: `show`, `init`, `add`, `edit` and `remove` refuse it
and point at `--roster <r>`. On team verbs, a session that owns exactly one live team and passes no
`--team` acts on that team; owning several, it must pass `--team`. The removed `alias` and `layout`
verbs exit 2 naming their replacements (`create --team`, `create --mode`), as does `init --layout`.

**`team-name-unusable`.** When the name a team would be created under cannot be used — it fails the
team-name rule on any transport, or, under herdr, some pane-routed member name it derives breaks
Herdr's `[a-z][a-z0-9_-]{0,31}` — `create` (every phase), and `spawn-one` / `spawn-ad-hoc` when they
would create a team, exit 2 with this JSON on stdout and its `message` on stderr, having launched
and written nothing: `ok: false`, `refused: "team-name-unusable"`, `needs_user_choice`, `verb`,
`name`, `name_source` (`basename` \| `legacy-team` \| `explicit`), `transport`, `why`,
`failing_member: {name, length}\|null`, `suggestion` (a name to OFFER, never applied), `suggestion_why`
(when there is no suggestion), `rerun` (the same command with a literal `--team <TEAM>`, `null` when
`needs_user_choice` is false) and `message`. The name is the user's choice: ask, then re-run with
`<TEAM>` replaced by their answer.

**`member-model-undefined`.** When a claude-kind member that `create --spawn`, `spawn-one` or
`spawn-ad-hoc` would launch (`--dry-run` included) has no model — none stored, none given with
`--member-model` / `--model` — the verb exits 2 the same way, after the team-name check and before
anything is launched or written: `ok: false`, `refused: "member-model-undefined"`, `verb`, `members`
(roster order: `{name, role, class, allowed, fallback}`), `rerun`, `rerun_fallback` and `message`.
`allowed` is the class's model allowlist. `fallback` is `{model, from}` — the highest-tier model a
claude-kind design, review or implement member holds that the class allows (`inherit` never counts),
first in roster order on a tie — or `null`; a legwork member never borrows one, and is listed only
when task-gopher is not installed or `--no-legwork-handoff` is given (otherwise it is skipped, as
under `create` above; `spawn-one` and `spawn-ad-hoc` launch no legwork role). `rerun` is the same command
with one `<MODEL>` flag per listed member (`--member-model <name>=<MODEL>`; `--member <name> --model
<MODEL>`; `--model <MODEL>`). `rerun_fallback` applies every fallback, and is `null` when any is. The
model is the user's choice: ask, then re-run `rerun` with each `<MODEL>` replaced; only a top-level
session that cannot ask runs `rerun_fallback`, and a subagent never does.

`/agent-team` (teams), `/agent-roster` (the roster template) and `/ah:agent-role` (custom roles) are the skills that drive these
verbs; their SKILL.md files are the operational protocol, this file is the surface.
