#!/usr/bin/env node
/**
 * agent-hierarchy — UserPromptSubmit unread-reply nudge.
 *
 * A durable agent that finishes AFTER `send`'s poll window closed leaves its
 * reply on disk, and nothing wakes the Orchestrator. The primary channel for
 * that is the background `wait` the send-timeout output tells the model to
 * arm (the harness re-invokes the session when that task exits); this hook is
 * the backstop for an unarmed session — the next user turn carries a one-line
 * nudge for every durable agent with an UNREAD reply (a reply.*.json with no
 * .presented marker; pane.mjs writes the marker on every pickup path).
 *
 * Registry records are folded raw, without liveness checks: a dead pane's
 * unread reply still matters, and UserPromptSubmit must never spawn tmux.
 * The env and registry checks run before stdin is touched, so a machine with
 * no durable agents pays two lookups and exits. The nudge never contains any
 * reply text — pickup goes through `wait`, where the size gate applies.
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.env.AGENT_HIERARCHY_PANE_DIR) process.exit(0);
if (!existsSync(join(homedir(), ".claude", "agent-hierarchy.panes.jsonl"))) process.exit(0);

const { readHookInput, resolveConfig } = await import("./lib-config.mjs");
const input = await readHookInput();
const resolved = resolveConfig(input.cwd || process.cwd());
if (!resolved.configured || !resolved.enabled) process.exit(0);

const { foldRegistry, mailboxDir, unreadReplies } = await import("./lib-pane.mjs");
const cli = join(dirname(fileURLToPath(import.meta.url)), "pane.mjs");
const lines = [];
for (const rec of foldRegistry().values()) {
  const unread = unreadReplies(rec.dir || mailboxDir(rec.key));
  if (!unread.length) continue;
  lines.push(
    `Durable agent ${rec.key} has ${unread.length === 1 ? `an UNREAD reply (request ${unread[0].reqid})` : `${unread.length} UNREAD replies`} waiting on disk — pick it up now with: node "${cli}" wait --key ${rec.key}   (presents it through the size gate; do not read the reply file directly).`
  );
}
if (!lines.length) process.exit(0);

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: lines.join("\n"),
    },
  })
);
