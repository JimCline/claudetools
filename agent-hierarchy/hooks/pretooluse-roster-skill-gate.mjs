#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate: the mutating roster MCP tools must go
 * through the `ah:agent-team` skill at least once per session (spec 0042
 * §1.3). Modeled structurally on pretooluse-disband-close-gate.mjs: an
 * exact-name matcher, no wildcards, matching set duplicated in hooks.json
 * (load-bearing in both places — see that file's header for why).
 *
 * Gated verbs: team_create, team_spawn_one, team_spawn_ad_hoc,
 * team_adopt, team_move, team_dismiss, team_disband, team_untrack — the team-side
 * lifecycle verbs (spec 0046 §3.3). NOT gated: the read-only tools
 * (roster_show, team_list, team_history, team_reap, team_resync,
 * team_layout_splits), the roster-TEMPLATE CRUD tools, and roster_layout /
 * roster_alias (spec 0042 E3: only ever called internally by
 * the skill's own flow) are deliberately NOT in this set.
 *
 * One-shot per session, recorded at DENY time: the immediate identical
 * retry always proceeds, whether or not the skill was actually consulted.
 * This gate's job is to make the skill unmissable once, not to police
 * compliance — a gate re-enterable indefinitely would deadlock a session
 * where the skill genuinely does not apply.
 *
 * No subagent context: only an orchestrator session stands up Teams. Fails
 * OPEN (allow) on any parse/state-read error — the opposite of the
 * disband-close gate's fail-closed choice, because that gate guards an
 * irreversible destructive act and this one guards a procedural miss; a
 * crashing hook must never make roster operations unusable.
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { appendGate, hasGate, hierarchyDir } from "./lib-hier.mjs";

const VERBS = ["team_create", "team_spawn_one", "team_spawn_ad_hoc", "team_adopt", "team_move", "team_dismiss", "team_disband", "team_untrack"];
const GATED_TOOLS = new Set(VERBS.flatMap((v) => [`mcp__plugin_ah_ah__${v}`, `mcp__ah__${v}`]));

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

const DENY_REASON = [
  "ah: BLOCKED — this call did not run.",
  "Team lifecycle operations (create/spawn/adopt/move/dismiss/disband) are owned by the `ah:agent-team` skill, which encodes the roster levels, spawn layout, the team file check-in registry, and relocation rules that a raw tool call skips. The `ah:agent-roster` skill covers the other half — editing the roster TEMPLATE (init/add/edit/remove/layout/alias) — and does not stand up or tear down anything.",
  'Invoke it: Skill with skill: "ah:agent-team". The skill may resolve this request differently than the tool call you were about to make — follow the skill, do not resume the original call by reflex.',
  "Re-issuing this exact call will proceed after that — this gate is one-shot per session.",
].join(" ");

try {
  const input = await readHookInput();
  if (isSubagent(input)) process.exit(0);
  if (!GATED_TOOLS.has(input.tool_name)) process.exit(0);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof toolInput.cwd === "string" && toolInput.cwd ? toolInput.cwd : typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const dir = hierarchyDir(cwd);

  if (hasGate(dir, (r) => r.type === "roster-skill-gate" && r.session_id === sessionId)) process.exit(0);

  appendGate(dir, { type: "roster-skill-gate", session_id: sessionId });
  deny(DENY_REASON);
} catch {
  process.exit(0);
}
