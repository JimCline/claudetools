# Live checks

Six things this plugin depends on cannot be unit-tested: they are properties of
the running Claude Code session, not of any file in this repo. Run them once per
machine after an update — each is one line, and each has a right answer.

`<AH_ROOT>` below is on this session's `ah CLI root` line; with no such line, use
the recipe in [cli-tools.md](./cli-tools.md).

| # | Question | How to check | Expected |
|---|---|---|---|
| 1 | Is `CLAUDE_PID` this session's own pid? | `node <AH_ROOT>/hooks/roster.mjs doctor --cwd <abs cwd> --check` | exit 0; the `identity` row is `ok` and names a live pid |
| 2 | Does `${CLAUDE_PLUGIN_ROOT}` expand inside `agents/*.md` and `skills/*/SKILL.md`? | dispatch any role and ask it to echo the CLI path it was given | an absolute path, not the literal placeholder |
| 3 | Is `CLAUDE_PLUGIN_ROOT` set in the Bash tool's environment? | `echo "[${CLAUDE_PLUGIN_ROOT}]"` through the Bash tool | `[]` — it is EMPTY, which is why every hook message spells the absolute path |
| 4 | Do subagents receive the root line? | spawn any subagent and ask what its `ah CLI root` line says | the line, with the version token, from the running root |
| 5 | Do two checkouts / a worktree share one runtime dir? | `roster.mjs doctor --cwd <abs cwd>` in each | the `runtime-dir` rows agree, or you intended them not to |
| 6 | After `/reload-plugins`, does the next prompt name the NEW version? | run `/reload-plugins`, send any prompt, read the newest `ah CLI root` line | `(v<new version>)` and the new directory; the most recent line wins |

Anything that disagrees is a real finding: the plugin's own tests cannot see any
of it.
