#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse durable-agent offer.
 *
 * When the Orchestrator dispatches a subagent whose type exactly matches a
 * live, IDLE durable agent, the dispatch is denied ONCE with instructions to
 * offer the durable agent to the user; the identical re-run passes through
 * untouched. Bounce protection is load-bearing (the task-gopher relay lesson):
 * offers are recorded per (session_id, subagent_type) in an append-only file,
 * so the hook can never ping-pong a dispatch.
 *
 * Never fires for: task-gopher / task-runner (legwork is cheap and stateless —
 * durable agents exist for reasoning-role continuity), a dispatching session
 * that IS a pane (panes may use subagents freely; pane protocol item 5), a
 * WORKING durable agent with no idle sibling (denying in favour of a busy
 * agent trades a stall for a spawn), or when the hierarchy is unconfigured or
 * disabled.
 *
 * The env and registry checks run before stdin is touched, so a machine with
 * no durable agents pays two lookups and exits.
 */
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.env.AGENT_HIERARCHY_PANE_DIR) process.exit(0);
if (!existsSync(join(homedir(), ".claude", "agent-hierarchy.panes.jsonl"))) process.exit(0);

const { readHookInput, resolveConfig } = await import("./lib-config.mjs");
const input = await readHookInput();
if (input.tool_name !== "Agent" && input.tool_name !== "Task") process.exit(0);
const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
const wanted = typeof toolInput.subagent_type === "string" ? toolInput.subagent_type : null;
if (!wanted) process.exit(0);
if (wanted === "task-gopher:task-gopher" || wanted === "task-runner" || wanted.endsWith(":task-runner")) process.exit(0);

const resolved = resolveConfig(input.cwd || process.cwd());
if (!resolved.configured || !resolved.enabled) process.exit(0);

const { appendRegistry, foldRegistry, isPaneLive, mailboxDir, readJsonFile } = await import("./lib-pane.mjs");
const idle = [];
for (const rec of foldRegistry().values()) {
  if (rec.agent !== wanted) continue;
  if (!isPaneLive(rec)) {
    appendRegistry({ ev: "close", key: rec.key, at: new Date().toISOString(), reason: "dead" });
    continue;
  }
  if (!readJsonFile(join(rec.dir || mailboxDir(rec.key), "pending"))) idle.push(rec);
}
if (!idle.length) process.exit(0);

const OFFERS_PATH = join(homedir(), ".claude", "agent-hierarchy.durable-offers.jsonl");
const sessionId = typeof input.session_id === "string" ? input.session_id : "unknown";
let alreadyOffered = false;
try {
  alreadyOffered = readFileSync(OFFERS_PATH, "utf8")
    .split("\n")
    .some((line) => {
      try {
        const rec = JSON.parse(line);
        return rec.session_id === sessionId && rec.subagent_type === wanted;
      } catch {
        return false;
      }
    });
} catch {
  /* no offers recorded yet */
}
if (alreadyOffered) process.exit(0);
try {
  appendFileSync(OFFERS_PATH, JSON.stringify({ session_id: sessionId, subagent_type: wanted, at: new Date().toISOString() }) + "\n");
} catch {
  // If the offer cannot be recorded, denying would repeat forever — let it pass.
  process.exit(0);
}

const cli = join(dirname(fileURLToPath(import.meta.url)), "pane.mjs");
const reason = [
  `A durable agent running \`${wanted}\` is already live and idle. This dispatch was blocked ONCE so you can offer it to the user — the identical re-run will pass.`,
  "",
  ...idle.map((r) => `  ${r.key} — ${r.agent} (${r.model || "inherited model"}) — idle`),
  "",
  "It already holds the context from its earlier tasks and its context is prompt-cached, so related follow-up work is cheaper there than in a fresh subagent. Put the choice to the user — in confirm flow, fold it into the handoff question rather than asking twice:",
  `  - Durable agent: node "${cli}" send --key <key> --summary "<one line>"  (prompt on stdin via heredoc; the send itself still needs the user's approval, per /agent-hierarchy:durable)`,
  "  - Fresh subagent: re-run this exact Agent call — it will not be blocked again this session.",
  "Prefer the durable agent for related follow-up work; prefer a subagent for independent work or a clean context.",
].join("\n");

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  })
);
