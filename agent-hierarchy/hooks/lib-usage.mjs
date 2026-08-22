/**
 * agent-hierarchy — shared pieces of the zero-token usage tracker.
 *
 * The whole tracker is plain node against files already on disk: every
 * assistant turn in a transcript carries `message.usage` (input/output/cache
 * token counts) and `message.model`, and every subagent's transcript lives at
 * <project>/<session_id>/subagents/agent-<agent_id>.jsonl. Counting tokens
 * therefore never involves a model call — no agent is ever asked to report its
 * own numbers, which would spend output tokens to restate what the harness
 * already logged.
 */

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** One JSONL record per finished subagent, appended by the SubagentStop hook. */
export const USAGE_FILE = join(homedir(), ".claude", "agent-hierarchy.usage.jsonl");

/** Reporter's incremental-scan cache for main-session transcripts. */
export const CACHE_FILE = join(homedir(), ".claude", "agent-hierarchy.usage-cache.json");

export const PRUNE_AT = 50_000;
export const PRUNE_TO = 30_000;

/**
 * Attribute an agent_type to a hierarchy role, at REPORT time — records store
 * the raw agent_type, so this mapping can evolve without invalidating data.
 * task-gopher counts as Task-Runner because the role's default config delegates
 * to it. Everything unrecognized lands in "other" (the reporter shows a
 * breakdown), and the main session is "orchestrator" by construction.
 */
export function roleFor(agentType) {
  if (typeof agentType !== "string" || !agentType) return "other";
  if (agentType.startsWith("ah:")) return agentType.slice("ah:".length);
  if (agentType === "task-gopher:task-gopher" || agentType === "task-gopher") return "task-runner";
  return "other";
}

export const zeroUsage = () => ({ calls: 0, in: 0, out: 0, cache_read: 0, cache_create: 0 });

export function addUsage(acc, u) {
  acc.calls += u.calls || 0;
  acc.in += u.in || 0;
  acc.out += u.out || 0;
  acc.cache_read += u.cache_read || 0;
  acc.cache_create += u.cache_create || 0;
  return acc;
}

/**
 * Sum a transcript's assistant-turn usage. Returns null when the file can't be
 * read; skips unparseable lines rather than failing the whole sum (a live
 * transcript's last line may be mid-write).
 */
export function sumTranscript(file) {
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    return null;
  }
  const t = zeroUsage();
  const models = {};
  for (const line of raw.split("\n")) {
    if (!line) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const u = o?.message?.usage;
    if (o?.type !== "assistant" || !u) continue;
    t.calls += 1;
    t.in += u.input_tokens || 0;
    t.out += u.output_tokens || 0;
    t.cache_read += u.cache_read_input_tokens || 0;
    t.cache_create += u.cache_creation_input_tokens || 0;
    const m = o?.message?.model;
    if (typeof m === "string" && m) models[m] = (models[m] || 0) + 1;
  }
  const model = Object.entries(models).sort((a, b) => b[1] - a[1])[0]?.[0] || "";
  return { ...t, model };
}

/** Compact USAGE_FILE once it is far past what any report window needs. */
export function pruneUsageFile() {
  try {
    const lines = readFileSync(USAGE_FILE, "utf8").split("\n").filter(Boolean);
    if (lines.length <= PRUNE_AT) return;
    const tmp = `${USAGE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, lines.slice(-PRUNE_TO).join("\n") + "\n");
    renameSync(tmp, USAGE_FILE); // atomic; readers never see a partial file
  } catch {
    // best-effort: a skipped prune only costs disk
  }
}
