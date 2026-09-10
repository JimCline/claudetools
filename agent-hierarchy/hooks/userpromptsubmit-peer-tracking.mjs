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
 * observes and records; it exits silently either way. A brief that also
 * carries `[hierarchy-msg <request path>]` records that path as `msg` on the
 * obligation, which then resolves only against a reply carrying the matching
 * response pointer (see posttooluse-peer-resolve.mjs).
 *
 * Amendment 2 (interactive peers): a peer session doubles as an interactive
 * one, and enforcement must fire only on turns the PEER's own tasking work
 * touches, never on a turn the USER is driving. So, in addition to the brief
 * detection above, this arms a `{"type":"turn","status":"armed"}` marker
 * whenever BOTH: the prompt carries a `<cross-session-message>` wrapper at
 * all (ANY peer delivery — a brief, a ping, an unrelated peer message; this
 * check is intentionally unanchored, unlike the brief sentinel above), AND
 * the session has at least one pending obligation afterward — read via
 * `pendingFor` AFTER the append above, so it also catches an obligation this
 * very prompt just created. A typed prompt, or a session with no pending
 * obligations, arms nothing, which is what keeps state growth bounded to
 * active-obligation windows.
 *
 * No-ops for subagents (same `agent_id` discriminator as the rest of the
 * plugin) — a subagent is not a peer, and its own SessionStart injection is
 * already suppressed for the same reason.
 *
 * Team-intent nudge (spec 0042 §1.5): a prompt matching one of the
 * team-lifecycle phrases from `skills/agent-team/SKILL.md`'s frontmatter
 * `description` gets exactly one injected line naming the `ah:agent-team`
 * skill — read from that file at hook time so the phrase list has one
 * source of truth (the test asserts the two match). No new prompt, no
 * instruction, no restating the protocol; a prompt with no match injects
 * nothing.
 */

import { cliRootLine, isSubagent, readHookInput, resolveConfig } from "./lib-config.mjs";
import { extractMsgToken } from "./lib-hier.mjs";
import { matchedTeamIntentPhrase } from "./lib-team-intent.mjs";
import { appendPeerRecord, appendTurnMarker, extractPendingRecord, parseWrapper, pendingFor } from "./lib-peer.mjs";

try {
  const input = await readHookInput();
  const parts = [];
  if (!isSubagent(input)) {
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    const prompt = typeof input.prompt === "string" ? input.prompt : "";

    if (sessionId && prompt) {
      const rec = extractPendingRecord(prompt);
      if (rec) {
        const msg = extractMsgToken(prompt);
        appendPeerRecord({
          session_id: sessionId,
          from: rec.from,
          from_name: rec.from_name,
          reply_to: rec.reply_to,
          task: rec.task,
          armed_by: rec.armed_by,
          ...(msg ? { msg } : {}),
          ts: new Date().toISOString(),
          status: "pending",
          nudges: 0,
        });
      }

      if (parseWrapper(prompt) && pendingFor(sessionId).length > 0) {
        appendTurnMarker(sessionId, "armed");
      }
    }

    if (prompt && matchedTeamIntentPhrase(prompt)) {
      parts.push('ah: standing up, reshaping, or tearing down a live Team goes through the `ah:agent-team` skill.');
    }

    // `/reload-plugins` fires no SessionStart, so a session that updates mid-flight never hears the
    // root line that hook injected — and the CLI paths are the whole interface since 0.73.0. Every
    // prompt re-states it, on the same classification SessionStart uses.
    const resolved = resolveConfig(typeof input.cwd === "string" ? input.cwd : process.cwd());
    if (!resolved.configured || resolved.enabled) parts.push(cliRootLine());
  }
  if (parts.length) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: parts.join("\n\n"),
        },
      })
    );
  }
} catch {
  // fail open: a tracking failure must never affect the prompt it observed
}
process.exit(0);
