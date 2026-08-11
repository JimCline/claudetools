#!/usr/bin/env node
/**
 * agent-hierarchy — UserPromptSubmit tracker for the peer report-back contract.
 *
 * E2 (live-verified): UserPromptSubmit fires in the receiving session for a
 * SendMessage-delivered peer message, and the payload's `prompt` field carries
 * the full delivered text INCLUDING the `<cross-session-message>` wrapper —
 * there is no structured field that marks a delivery as a peer tasking, so
 * regexing `prompt` for the sentinel is the only and the correct mechanism.
 *
 * When the prompt carries a well-formed `[hierarchy-peer-brief reply-to="..."
 * task="..."]` sentinel inside its wrapper, this appends a "pending" record so
 * the Stop hook can hold the session to its report-back obligation. No
 * sentinel (the overwhelming majority of prompts) costs one failed regex test
 * and nothing else. Never blocks or alters the prompt — this hook only
 * observes and records; it exits silently either way.
 *
 * No-ops for subagents (same `agent_id` discriminator as the rest of the
 * plugin) — a subagent is not a peer, and its own SessionStart injection is
 * already suppressed for the same reason.
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { appendPeerRecord, extractPendingRecord } from "./lib-peer.mjs";

try {
  const input = await readHookInput();
  if (!isSubagent(input)) {
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    const prompt = typeof input.prompt === "string" ? input.prompt : "";

    if (sessionId && prompt) {
      const rec = extractPendingRecord(prompt);
      if (rec) {
        appendPeerRecord({
          session_id: sessionId,
          from: rec.from,
          from_name: rec.from_name,
          reply_to: rec.reply_to,
          task: rec.task,
          ts: new Date().toISOString(),
          status: "pending",
          nudges: 0,
        });
      }
    }
  }
} catch {
  // fail open: a tracking failure must never affect the prompt it observed
}
process.exit(0);
