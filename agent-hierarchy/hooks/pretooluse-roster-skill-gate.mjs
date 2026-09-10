#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate: the mutating roster CLI verbs must go
 * through the `ah:agent-team` skill at least once per session (spec 0042
 * §1.3). Keyed on the parsed Bash command since 0048 §2.4.3 — the ah CLIs
 * are invoked through the Bash tool and the MCP tool names are gone. The
 * gated verb set lives here alone and tests/check-gate-name-agreement.mjs
 * asserts it against hooks.json's matcher.
 *
 * Gated verbs: create, spawn-one, spawn-ad-hoc, adopt, move, dismiss,
 * disband, untrack — the team-side lifecycle verbs (spec 0046 §3.3). NOT
 * gated: the read-only verbs (show, teams, history, reap, resync,
 * layout-splits), the roster-TEMPLATE CRUD verbs, and layout / alias (spec
 * 0042 E3: only ever called internally by the skill's own flow) are
 * deliberately NOT in this set. Nor is anything in msg.mjs.
 *
 * One-shot per session, recorded at DENY time: the immediate identical
 * retry always proceeds, whether or not the skill was actually consulted.
 * This gate's job is to make the skill unmissable once, not to police
 * compliance — a gate re-enterable indefinitely would deadlock a session
 * where the skill genuinely does not apply. Its `deny` outranks
 * pretooluse-ah-cli.mjs's `allow` (documented precedence, 0048 §2.4.4).
 *
 * No subagent context: only an orchestrator session stands up Teams. Fails
 * OPEN (allow) on any parse/state-read error — the opposite of the
 * disband-close gate's fail-closed choice, because that gate guards an
 * irreversible destructive act and this one guards a procedural miss; a
 * crashing hook must never make roster operations unusable.
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { appendGate, hasGate, hierarchyDir } from "./lib-hier.mjs";
import { parseAhCommand } from "./lib-ah-cli.mjs";

const VERBS = ["create", "spawn-one", "spawn-ad-hoc", "adopt", "move", "dismiss", "disband", "untrack"];
const GATED_VERBS = new Set(VERBS);

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
  "ah: BLOCKED — this command did not run.",
  "Team lifecycle operations (create/spawn-one/spawn-ad-hoc/adopt/move/dismiss/disband/untrack on `hooks/roster.mjs`) are owned by the `ah:agent-team` skill, which encodes the roster levels, spawn layout, the team file check-in registry, and relocation rules that a raw CLI call skips. The `ah:agent-roster` skill covers the other half — editing the roster TEMPLATE (init/add/edit/remove/layout/alias) — and does not stand up or tear down anything.",
  'Invoke it: Skill with skill: "ah:agent-team". The skill may resolve this request differently than the command you were about to run — follow the skill, do not resume the original command by reflex.',
  "Re-running the same command will proceed after that — this gate is one-shot per session.",
].join(" ");

try {
  const input = await readHookInput();
  if (isSubagent(input)) process.exit(0);
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  if (!parsed || parsed.script !== "roster" || !GATED_VERBS.has(parsed.verb)) process.exit(0);

  const cwd = typeof parsed.flags.cwd === "string" && parsed.flags.cwd ? parsed.flags.cwd : typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const dir = hierarchyDir(cwd);

  if (hasGate(dir, (r) => r.type === "roster-skill-gate" && r.session_id === sessionId)) process.exit(0);

  appendGate(dir, { type: "roster-skill-gate", session_id: sessionId });
  deny(DENY_REASON);
} catch {
  process.exit(0);
}
