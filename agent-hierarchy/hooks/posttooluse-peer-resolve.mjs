#!/usr/bin/env node
/**
 * agent-hierarchy — PostToolUse resolver for the peer report-back contract.
 *
 * Fires on every SendMessage in the peer session. When the `to` target
 * satisfies a pending peer obligation for this session — it matches the
 * recorded delivery envelope's `from`, its `from_name`, or (for an explicit
 * third-party reply-to) the `reply_to` name itself, each compared the way
 * `isGatedPeerTarget` does (stripping a trailing " [ref]") — that obligation
 * is marked resolved. A single reply can resolve more than one pending
 * obligation if more than one owed report shares the same reply target; there
 * is nothing in a SendMessage call that says which task it answers, so this
 * resolves everything the target matches rather than guessing at one.
 *
 * No-ops for subagents (same `agent_id` discriminator as the rest of the
 * plugin — a subagent is not a peer) and for anything that is not a
 * SendMessage (the hooks.json matcher already narrows to SendMessage; this is
 * the same defensive re-check pretooluse-ultra-gate.mjs makes on tool_name).
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { appendPeerRecord, pendingFor, targetSatisfiesRecord } from "./lib-peer.mjs";

try {
  const input = await readHookInput();
  if (!isSubagent(input) && input.tool_name === "SendMessage") {
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
    const to = typeof toolInput.to === "string" ? toolInput.to : "";

    if (sessionId && to) {
      for (const rec of pendingFor(sessionId)) {
        if (targetSatisfiesRecord(to, rec)) {
          appendPeerRecord({ ...rec, ts: new Date().toISOString(), status: "resolved" });
        }
      }
    }
  }
} catch {
  // fail open: a resolver failure must never affect the SendMessage it observed
}
process.exit(0);
