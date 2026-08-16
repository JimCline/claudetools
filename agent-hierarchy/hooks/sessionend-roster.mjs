#!/usr/bin/env node
/**
 * agent-hierarchy — SessionEnd roster writer.
 *
 * A top-level `--agent <hierarchy role>` peer session recorded `{status:"up"}`
 * at SessionStart; this appends the matching `{status:"down"}` when it ends.
 * The SessionEnd payload carries no `agent_type` (verified on v2.1.233:
 * session_id, transcript_path, cwd, prompt_id, hook_event_name, reason), so
 * the branch is: `agent_type` names a role, OR the roster's latest record for
 * this session_id is `up`. Anything else — an ordinary session, a subagent —
 * writes nothing. Fail-open.
 */

import { hierarchyRoleOf, isSubagent, isTopLevelAgentSession, readHookInput } from "./lib-config.mjs";
import { appendRosterRecord, hierarchyDir, upRecordFor } from "./lib-hier.mjs";

try {
  const input = await readHookInput();
  if (!isSubagent(input)) {
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = hierarchyDir(cwd);
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    let role = isTopLevelAgentSession(input) ? hierarchyRoleOf(input.agent_type) : null;
    const up = sessionId ? upRecordFor(dir, sessionId) : null;
    if (!role && up) role = up.role || null;
    if (role) {
      appendRosterRecord(dir, { status: "down", role, session_id: sessionId || null, pid: up ? up.pid : process.ppid, cwd });
    }
  }
} catch {
  // fail open
}
process.exit(0);
