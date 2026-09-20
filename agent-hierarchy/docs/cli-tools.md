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
| show roster | `node <R>/hooks/roster.mjs show [global\|repo\|repo-user] [--level <L>] [--team <t>]` |
| list teams | `node <R>/hooks/roster.mjs teams [--orchestrator-pid <pid>]`. The top-level object carries the same `sources` block as `disband`; `untracked_live` rows from `herdr agent list` alone are marked `source: "herdr"`. |
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
| disband a team | plan: `node <R>/hooks/roster.mjs disband [--plan] [--team <t>]` · close: `… disband --close --confirm --plan-token <tok> [--allow-global] [--team <t>]`. Every plan and close result carries `sources` — which of team file / peers.jsonl / `herdr agent list` was consulted, what each yielded, and the name prefix searched under. A plan also carries `next`: the exact close command to run once the user agrees (absolute path, `--confirm --plan-token`, plus `--team`/`--cwd` as given and `--allow-global` only when the close would demand it) — copy it, assemble nothing. A close result adds `pruned: [name…]` (a nameless row appears as its role), `kept: [{name, why}]` (`why` ∈ `added` \| `close-failed` \| `live` \| `indeterminate`), `team_removed`, and `team_file` (`null` when no team file was involved): `--close` reconciles the team file itself, so no bookkeeping call follows it. Top-level `closed` is true iff every close that was attempted succeeded (vacuously true when nothing was closable); whether every member is gone is what `pruned` / `kept` / `team_removed` report. The resolved team file, when it exists but does not read as a team record (unparseable, or parsing to something with no `members` array), is reported as `team_file_unreadable: <path>` and is never written or removed. A plan always carries `next`, even when no member has a pane: running it then closes nothing and still reconciles the record. |
| resync member locations | `node <R>/hooks/roster.mjs resync [--dry-run] [--team <t>] [--bind <b>]` |
| move a member's pane | `node <R>/hooks/roster.mjs move <name> --tab <t> [--split right\|down]` · `… move <name> --new-tab [--workspace <w>]` · `… move <name> --new-workspace` · all take `[--dry-run] [--allow-global] [--team <t>]` |
| team history | `node <R>/hooks/roster.mjs history` |
| spawn one roster member | `node <R>/hooks/roster.mjs spawn-one <role> [--member <name>] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` — not skill-gated |
| spawn an ad hoc member | `node <R>/hooks/roster.mjs spawn-ad-hoc <role> [--model <M>] [--effort <E>] [--kind <K>] [--route peer\|pane] [--args '<json>'] [--auto-mode <A>] [--on-missing …] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>]` (`--role <role>` is accepted in place of the positional) — no roster needed; not skill-gated; global roster ignored (`--allow-global` accepted, no-op) |
| dismiss one member | plan: `node <R>/hooks/roster.mjs dismiss <name> [--plan] [--team <t>]` · close: `… dismiss <name> --close --confirm --plan-token <tok> [--also-config] [--level <L>] [--allow-global] [--team <t>]`. Plans and close results carry the same `sources` block as `disband`, and a plan carries the same `next` close command. With no team file (for instance right after `disband --close` removed it): exit 0 with `dismissed: false, reason: "no active team and no live peers"` when the peer registry offers no closable session; exit 2, listing the live untracked sessions and the name / pane_id / session_id values `dismiss` accepts, when it does. |
| untrack (close nothing) | `node <R>/hooks/roster.mjs untrack <name>\|--all [--plan\|--commit] [--keep-sessions] [--also-config] [--level <L>] [--team <t>]`. Idempotent: with no team file it exits 0 with `untracked: false, already_untracked: true, reason: "no team file to forget"`. |
| re-register this session | `node <R>/hooks/roster.mjs checkin [--team <t>] [--orchestrator-pid <pid>]` |
| who am I / where is my orchestrator (peer) | `node <R>/hooks/roster.mjs whoami [--team <t>]` — read-only, writes nothing, exit 0 whenever the lookup ran. Matches this session's pane id (`HERDR_PANE_ID`, else this pid's `peers.jsonl` row, else `TMUX_PANE`) against every team record, or only `--team`'s. Output: `member: {name, role, route}\|null`, `team` (`null` for the legacy `team.json`), `team_file`, `orchestrator: {pid, session_id, live, send_to}\|null`, `reason`: `null` \| `no-pane-id` \| `no-team` \| `not-a-member` \| `ambiguous` (then `candidates: [{team, name}]`). `session_id` is passed through as recorded, and is `null` on every path the agent-team skill uses. `send_to` is usable directly as SendMessage `to`, but is best-effort — derived from the pid, non-null only while the orchestrator is alive and its session socket exists. Reply precedence: the brief's `reply-to` (or the orchestrator's session name from `ListAgents`) is authoritative — see [comms-protocol.md](comms-protocol.md); `send_to` is the fallback when that is lost. The socket directory follows this session's own `CLAUDE_CODE_MESSAGING_SOCKET` when the harness exports it (else `/tmp/cc-socks`); the real directory is harness-owned, so `send_to` stays best-effort. Every output, whatever its `reason`, also carries `last_observed_brief: {from, from_name, reply_to, ts}\|null` — the last obligation row a hook filed for this session in `~/.claude/agent-hierarchy.peer-pending.jsonl`, any status, with `from_name` `null` when none was recorded. These values are observed, not verified: they say who last briefed this session, which can differ from the recorded `orchestrator`, and like `send_to` they are a fallback below the brief's `reply-to` and the `ListAgents` name. `null` is the expected value, not a failure, in two cases: no session id resolves (`CLAUDE_CODE_SESSION_ID`, else the `session_id` on this pid's `peers.jsonl` row), or no row exists — only a sentinel or `[hierarchy-msg …]` brief files one, a plain cross-session message does not, and its absence does not make the session unaddressable. It never changes `reason`. |
| self-check this install | `node <R>/hooks/roster.mjs doctor [--check]` — read-only JSON, one row per thing that can be wrong; `--check` exits 1 on any red row |
| split decision (tests) | `node <R>/hooks/roster.mjs next-split --mode <m> --pane-count <N> --self <pane id> --created '<json>' --geometry '<json>'` |
| route preference | `node <R>/hooks/msg.mjs route peers\|subagents\|prefer-peers --session <id>` |
| global-scope answer | `node <R>/hooks/msg.mjs global-scope roster\|config allow\|deny --session <id>` |

A team file that exists but does not read as a team record (unparseable, or parsing to something
with no `members` array) is never written over. `create` (plan included),
`spawn-one` and `spawn-ad-hoc` exit 2 before anything launches when the file they resolve to —
`--team <t>`'s, the default `teams/<prefix>.json`, or a legacy `team.json` — is in that state, naming
its absolute path and the remedy: repair or remove it, or use a different `--team`. Read verbs never
refuse; beside an unparseable legacy `team.json` a bare read verb resolves to that legacy file
rather than to `teams/<prefix>.json`, so it reports that scope.

Flags are validated per verb: `spawn-one`, `spawn-ad-hoc`, `adopt`, `checkin`, `whoami`, `dismiss`,
`disband`, `untrack`, `resync`, `move`, `alias` and `reap` reject any flag not in their own set, so
the lists above are exhaustive for those verbs rather than indicative.

`/agent-team` (teams) and `/agent-roster` (the roster template) are the skills that drive these
verbs; their SKILL.md files are the operational protocol, this file is the surface.
