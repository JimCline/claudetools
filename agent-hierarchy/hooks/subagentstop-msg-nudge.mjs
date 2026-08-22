#!/usr/bin/env node
/**
 * agent-hierarchy — SubagentStop response nudge for the message-file protocol.
 *
 * A hierarchy reasoning-role subagent that was briefed with
 * `[hierarchy-msg <request path>]` owes a response FILE, and its final text
 * must open with `[hierarchy-msg <response path>]`. When the finishing
 * message lacks that pointer (to an existing `--response.md` for the same
 * id), the stop is blocked ONCE per agent_id with instructions; the second
 * stop always passes. One-shot record: `{type:"nudge", agent_id}` in
 * `<dir>/gates.jsonl`.
 *
 * `last_assistant_message` is present on SubagentStop (verified on v2.1.233;
 * fixture under tests/fixtures/); if absent, the last assistant line of the
 * subagent's transcript is read instead. The request id comes from the
 * pointer in the first user turn of the SUBAGENT's transcript
 * (`agent_transcript_path`, or the usage collector's derived path) — that is
 * where the dispatch prompt lives; the parent's `transcript_path` opens with
 * the user's own prompt. No pointer there (brief was inline / gate off) → allow
 * silently. `msgs:"off"` → allow. Any failure → allow.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { hierarchyRoleOf, MSG_CLI, readHookInput, resolveConfig } from "./lib-config.mjs";
import { appendGate, extractMsgToken, hasGate, hasResponseToken, hierarchyDir, parseMsgFilename, readMsgFile } from "./lib-hier.mjs";

const NUDGED_ROLES = ["architect", "implementor", "reviewer", "ultra-advisor"];

function allow() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

function textOf(message) {
  if (typeof message === "string") return message;
  if (Array.isArray(message)) return message.map((p) => (p && typeof p.text === "string" ? p.text : "")).join("\n");
  return "";
}

/** `{ firstUser, lastAssistant }` text from a JSONL transcript; either may be "". */
function scanTranscript(path) {
  const out = { firstUser: "", lastAssistant: "" };
  if (!path || !existsSync(path)) return out;
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return out;
  }
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const msg = rec && rec.message;
    if (!msg || typeof msg !== "object") continue;
    const role = rec.type || msg.role;
    if (role === "user" && !out.firstUser) out.firstUser = textOf(msg.content);
    if (role === "assistant") {
      const t = textOf(msg.content);
      if (t.trim()) out.lastAssistant = t;
    }
  }
  return out;
}

try {
  const input = await readHookInput();
  const agentId = typeof input.agent_id === "string" ? input.agent_id : "";
  const role = hierarchyRoleOf(input.agent_type);
  if (!agentId || !role || !NUDGED_ROLES.includes(role)) allow();

  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd);
  if (!resolved.enabled || resolved.msgs === "off") allow();

  const dir = hierarchyDir(cwd);
  if (hasGate(dir, (r) => r.type === "nudge" && r.agent_id === agentId)) allow();

  let agentTranscript = typeof input.agent_transcript_path === "string" ? input.agent_transcript_path : "";
  if (!agentTranscript && typeof input.transcript_path === "string" && typeof input.session_id === "string") {
    agentTranscript = join(dirname(input.transcript_path), input.session_id, "subagents", `agent-${agentId}.jsonl`);
  }
  const scanned = scanTranscript(agentTranscript);

  const requestPath = extractMsgToken(scanned.firstUser);
  const meta = requestPath ? parseMsgFilename(requestPath) : null;
  if (!meta || meta.type !== "request") allow();

  const last = typeof input.last_assistant_message === "string" ? input.last_assistant_message : scanned.lastAssistant;
  if (hasResponseToken(last, meta.id)) allow();

  const req = readMsgFile(requestPath);
  const from = req && req.fm && req.fm.from ? req.fm.from : "orchestrator";
  appendGate(dir, { type: "nudge", agent_id: agentId, session_id: input.session_id || null, id: meta.id });
  block(
    `ah: your brief was a message file (${requestPath}); write your response file — node "${MSG_CLI}" new --type response --id ${meta.id} --to ${from} --from ${role}; fill every section (bullets, no prose; [1] status first bullet done|partial|blocked) — and return exactly: [hierarchy-msg <response path>] + the [1] status bullet.`
  );
} catch {
  allow();
}
