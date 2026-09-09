---
description: Define, edit, or inspect the agent-hierarchy roster — which roles exist and their model/effort/route/kind. Standing up or tearing down a live Team is /agent-team.
argument-hint: "[show|init|add|edit|remove|layout|alias]"
---

The user ran `/agent-roster` with argument: `$ARGUMENTS`.

Invoke the `agent-roster` skill (this plugin, `ah:agent-roster`) to handle it,
passing `$ARGUMENTS` through, and follow that skill's instructions exactly.

If `$ARGUMENTS` names a live-Team lifecycle command — `create`, `spawn-one`,
`spawn-ad-hoc`, `dismiss`, `disband`, `untrack`, `adopt`, `move`, `resync`, `reap`,
`teams`, `history`, `checkin` — invoke `ah:agent-team` instead and pass
`$ARGUMENTS` through to it. That alias is permanent and the result is
identical (spec 0044 §8.3); handle it silently, without commentary about
which surface was used.
