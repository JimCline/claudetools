#!/usr/bin/env node
/**
 * agent-hierarchy — SessionStart context injection.
 *
 * Injects the resolved role→model table plus the orchestration protocol, so a
 * fresh, resumed, forked, or post-compaction session starts already knowing
 * which model each role runs on and how to route work through the chain.
 *
 * Gating, in this order:
 *   - Subagent (`agent_id` set) → inject NOTHING. `ah:*` role
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
 *     → the role-session notice, and an `up` record in the peer roster
 *     (the session's pid is `process.ppid` — verified: every hook's parent is
 *     the claude process, also exposed as env CLAUDE_PID). It is a main
 *     session, so the directive would otherwise reach it, but it is NOT the
 *     Orchestrator. A top-level `--agent` session running a non-hierarchy
 *     agent deliberately falls through: it is a legitimate main session that
 *     may orchestrate.
 *   - Top-level, configured, enabled  → the directive + HIERARCHY STATE block
 *     (open exchanges, peer roster, tier line) on every matcher including
 *     compact; on `startup` a silent sweep of closed exchanges runs first.
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
  teamPrefix,
} from "./lib-config.mjs";
import { appendRosterRecord, buildStateBlock, cacheSessionModel, effectiveRoute, ensureHierarchyDir, sessionModel, sweep, SWEEP_DAYS } from "./lib-hier.mjs";
import { clearTeam, herdrOnPath, readTeam, teamIsLive } from "./lib-roster.mjs";
import { writeSessionRole } from "./lib-session-role.mjs";

/** Feature A (spec 0010 §2.5): advisory only, never blocks. */
function herdrWarning() {
  try {
    if (process.env.HERDR_ENV === "1" && !herdrOnPath()) {
      return (
        "ah: HERDR_ENV=1 but no `herdr` binary was found on PATH. Roster spawning " +
        "(/agent-roster create, roster.mjs spawn-one) will fail when it tries to place " +
        "panes. Install herdr, or unset HERDR_ENV to fall back to tmux/terminal."
      );
    }
  } catch {
    // advisory only — never let a probe failure cost the directive
  }
  return null;
}

/** Clear an abandoned team.json (default, or the resolved team's file): dead orchestrator pid or past the age cap. Returns a note string, or null. */
function sweepStaleTeam(dir, team = null) {
  const t = readTeam(dir, team);
  if (!t || teamIsLive(t)) return null;
  clearTeam(dir, team);
  return `cleared stale team ${t.team_id}`;
}

const input = await readHookInput();

let context = null;

if (!isSubagent(input)) {
  const role = isTopLevelAgentSession(input) ? hierarchyRoleOf(input.agent_type) : null;
  const cwd = input.cwd || process.cwd();

  if (role) {
    context = buildRoleSessionNotice(role, input.agent_type);
    // Spec 0028 §3.3: the persisted half of resolveHierarchyRole's fallback —
    // non-enforcing (§3.7), best-effort like the roster record beside it.
    try {
      writeSessionRole(input.session_id || null, role);
    } catch {
      // best-effort — the role notice still goes out
    }
    try {
      const dir = ensureHierarchyDir(cwd);
      appendRosterRecord(dir, {
        status: "up",
        role,
        session_id: input.session_id || null,
        pid: process.ppid,
        ppid: process.ppid,
        cwd,
        pane_id: process.env.HERDR_PANE_ID || null,
        tab_id: process.env.HERDR_TAB_ID || null,
        workspace_id: process.env.HERDR_WORKSPACE_ID || null,
      });
    } catch {
      // roster is best-effort; the notice still goes out
    }
  } else {
    const resolved = resolveConfig(cwd, { sessionId: input.session_id || null });
    if (!resolved.configured) context = buildNudge(resolved);
    else if (resolved.enabled) {
      let dir = null;
      let model = null;
      let route = null;
      let state = null;
      let teamSweepNote = null;
      try {
        dir = ensureHierarchyDir(cwd);
        model = sessionModel(input, dir);
        if (input.model && input.session_id) cacheSessionModel(dir, input.session_id, input.model);
        if (input.source === "startup") sweep(dir, SWEEP_DAYS);
        // Stale-team safety net (spec 0001 §5.3): only a plain top-level session can
        // legitimately observe a DIFFERENT session's abandoned team — never the
        // Orchestrator's own session before it has written the registry, and never a
        // `--agent <role>` member session (excluded above by the `role` branch, but
        // guarded again here per the spec's exact condition).
        if (!isTopLevelAgentSession(input)) teamSweepNote = sweepStaleTeam(dir, resolved.team);
        route = effectiveRoute(dir, resolved, input.session_id || null);
        state = buildStateBlock(dir, resolved, teamPrefix(resolved.cwd, resolved.team), model, input.session_id || null, route);
      } catch {
        // state block is best-effort; the directive still goes out
      }
      context = buildDirective(resolved, input.session_id, { hierDir: dir, model, route });
      if (teamSweepNote) context += "\n\n" + teamSweepNote;
      if (state) context += "\n\n" + state;
      const herdrNote = herdrWarning();
      if (herdrNote) context += "\n\n" + herdrNote;
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
