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
 * resolves everything the target matches rather than guessing at one. An
 * obligation recorded with `msg` (the brief carried a message-file pointer)
 * additionally requires the reply to carry `[hierarchy-msg <path>--response.md]`
 * for that id, with the file present; otherwise it stays pending.
 *
 * No-ops for subagents (same `agent_id` discriminator as the rest of the
 * plugin — a subagent is not a peer) and for anything that is not a
 * SendMessage (the hooks.json matcher already narrows to SendMessage; this is
 * the same defensive re-check pretooluse-ultra-gate.mjs makes on tool_name).
 *
 * Also records this session's own outstanding peer-route dispatches (spec
 * 0028 §5.3): any SendMessage carrying a `[hierarchy-msg <path>--request.md]`
 * token is one, recorded under THIS (the sender's) session_id regardless of
 * whether the recipient ever receives or acknowledges it — see
 * `appendDispatchRecord` in lib-peer.mjs for why that independence matters.
 */

import { isSubagent, readHookInput } from "./lib-config.mjs";
import { extractMsgToken, hasResponseToken, parseMsgFilename } from "./lib-hier.mjs";
import { appendDispatchRecord, appendPeerRecord, pendingFor, targetSatisfiesRecord } from "./lib-peer.mjs";

/** An obligation with `msg` set resolves only against a reply carrying `[hierarchy-msg <path>--response.md]` for the same id, file present. */
function replySatisfiesMsg(message, rec) {
  if (!rec.msg) return true;
  const meta = parseMsgFilename(rec.msg);
  return hasResponseToken(message, meta ? meta.id : null);
}

try {
  const input = await readHookInput();
  if (!isSubagent(input) && input.tool_name === "SendMessage") {
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
    const to = typeof toolInput.to === "string" ? toolInput.to : "";
    const message = typeof toolInput.message === "string" ? toolInput.message : "";

    if (sessionId && to) {
      for (const rec of pendingFor(sessionId)) {
        if (targetSatisfiesRecord(to, rec) && replySatisfiesMsg(message, rec)) {
          appendPeerRecord({ ...rec, ts: new Date().toISOString(), status: "resolved" });
        }
      }

      // §5.3 (r4): this SendMessage is a peer-route dispatch iff it carries a
      // request-file token — record it under THIS session's own id, whether
      // or not the recipient ever receives or acknowledges it (finding 3).
      const reqPath = extractMsgToken(message);
      if (reqPath && reqPath.endsWith("--request.md")) {
        const meta = parseMsgFilename(reqPath);
        if (meta && meta.type === "request") appendDispatchRecord(sessionId, meta.id, meta.to);
      }
    }
  }
} catch {
  // fail open: a resolver failure must never affect the SendMessage it observed
}
process.exit(0);
