#!/usr/bin/env node
/**
 * agent-hierarchy — SessionStart context injection.
 *
 * Injects the resolved role→model table plus the orchestration protocol, so a
 * fresh, resumed, forked, or post-compaction session starts already knowing
 * which model each role runs on and how to route work through the chain.
 *
 * Gating, in this order:
 *   - Inside a /pane session (`AGENT_HIERARCHY_PANE_DIR` set) → the pane
 *     protocol. The env var is the gate for pane-ness, not `agent_type`:
 *     `agent_type` is set on EVERY `claude --agent …` session on the machine,
 *     including ones a user launched by hand with no pane anywhere, and
 *     telling such a session that its final message is being relayed would be
 *     a lie.
 *   - Subagent (`agent_id` set) → inject NOTHING. `agent-hierarchy:*` role
 *     agents must never receive the protocol, since subagents can nest and an
 *     Implementor that starts orchestrating defeats the hierarchy; foreign
 *     subagents such as `task-gopher:task-gopher` should not pay for it
 *     either. Each role agent gets its own instructions from its `agents/*.md`
 *     body, which IS loaded at spawn. Unlike sibling plugins that must relay
 *     their directives into subagents to work at all (see
 *     docs/subagent-directive-relay.md), suppression is the INTENT here. A
 *     soft role-gate sentence stays in the directive as a backstop for paths
 *     where the hook does not run.
 *   - Top-level `--agent <hierarchy role>` (`agent_type` set, `agent_id` not)
 *     → the role-session notice. It is a main session, so the directive would
 *     otherwise reach it, but it is NOT the Orchestrator. A top-level
 *     `--agent` session running a non-hierarchy agent deliberately falls
 *     through: it is a legitimate main session that may orchestrate.
 *   - Top-level, configured, enabled  → the directive, plus a roster of live
 *     durable agents when the pane registry holds any (individually guarded,
 *     like the pane branch — the roster is additive and must never cost the
 *     session its directive).
 *   - Top-level, no usable config     → a one-line setup nudge.
 *   - Top-level, config with enabled:false → silence (the user opted out;
 *     nudging them to configure would be wrong).
 *
 * There is exactly ONE write to stdout in this file, at the very end. Two JSON
 * objects on stdout is malformed output, and the harness drops the injection
 * without saying so — so build the string first, then write it once.
 */

import {
  buildDirective,
  buildNudge,
  buildRoleSessionNotice,
  hierarchyRoleOf,
  isSubagent,
  isTopLevelAgentSession,
  readHookInput,
  resolveConfig,
} from "./lib-config.mjs";

const input = await readHookInput();

let context = null;

// Guarded on its own, and only here. The rest of this file has no try/catch by
// design, and wrapping it would change existing failure behaviour; a broken
// pane path must fall through to the correct pre-existing handling instead of
// taking the whole hook down. `lib-pane.mjs` is imported dynamically so an
// ordinary session never loads it, and so this file still works without it.
try {
  const paneDir = process.env.AGENT_HIERARCHY_PANE_DIR;
  if (paneDir) {
    const { buildPaneProtocol, recordPaneSession } = await import("./lib-pane.mjs");
    context = buildPaneProtocol({
      role: input.agent_type || process.env.AGENT_HIERARCHY_PANE_ROLE || null,
      declaredRole: process.env.AGENT_HIERARCHY_PANE_ROLE || null,
      key: process.env.AGENT_HIERARCHY_PANE_KEY || null,
    });
    // Separately guarded: a stale env var pointing at a deleted mailbox must
    // not cost the session its protocol injection.
    try {
      recordPaneSession(paneDir, input);
    } catch {
      /* the identity file is the session gate's belt-and-braces, not the protocol */
    }
  }
} catch {
  context = null;
}

if (!context && !isSubagent(input)) {
  const role = isTopLevelAgentSession(input) ? hierarchyRoleOf(input.agent_type) : null;

  if (role) {
    context = buildRoleSessionNotice(role, input.agent_type);
  } else {
    const resolved = resolveConfig(input.cwd || process.cwd());
    if (!resolved.configured) context = buildNudge(resolved);
    else if (resolved.enabled) {
      context = buildDirective(resolved, input.session_id);
      try {
        const { durableRoster } = await import("./lib-pane.mjs");
        const roster = durableRoster();
        if (roster) context += "\n\n" + roster;
      } catch {
        /* the directive stands on its own */
      }
    }
  }
}

if (context) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: context,
      },
    })
  );
}
