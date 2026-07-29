#!/usr/bin/env node
/**
 * comment-discipline — subagent backstop.
 *
 * As of 0.3.0 this is a BACKSTOP, not the primary channel. subagentstart.mjs
 * delivers the rule at spawn and marks the agent in SEEN_FILE, so for an
 * ordinary dispatch this hook finds the key already present and stays silent.
 * What is left for it: spawns SubagentStart does not reach.
 *
 * Whether any such spawns exist is genuinely UNKNOWN. A spawn-lifecycle event
 * could reasonably fire for every subagent regardless of origin, in which case
 * this hook is dead weight — but agents created by machinery other than an
 * `Agent`/`Task` tool call (a workflow runner, say) have already been measured
 * to bypass one at-spawn channel, and nothing has probed whether they bypass
 * this one too. Keeping the backstop costs a `seenKeys()` read per edit and
 * removes a silent-failure mode. Delete it once someone measures.
 *
 * It also still covers the case where SubagentStart fired but could not persist
 * its mark.
 *
 * The standing limit: the first edit is unguarded. The injection lands with
 * that edit's RESULT, so it shapes every edit after it but not the one that
 * triggered it — and a subagent making exactly one edit is never covered by
 * this hook at all. Only at-spawn delivery covers edit #1, which is precisely
 * why subagentstart.mjs is the primary channel now.
 *
 * Injects at most once per (session, agent), tracked in SEEN_FILE. Silent for
 * the main session (`agent_id` absent — SessionStart already covered it) and
 * when unconfigured or disabled. Never throws: a backstop must not break an
 * edit. When the seen-mark cannot be persisted it injects ANYWAY — a duplicated
 * directive is a cheaper failure than a safety net that has silently died.
 */

import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { DIRECTIVE, SEEN_FILE, SEEN_MAX_KEYS, readHookInput, resolveConfig } from "./lib-config.mjs";

const quit = () => process.exit(0);

// hooks.json's matcher is an unanchored regex, so tools like `TodoWrite` also
// route here. Only real file-authoring tools should spend the directive.
const EDIT_TOOLS = new Set(["Edit", "Write", "NotebookEdit", "MultiEdit"]);

/**
 * The seen-set is an append-only line log, one `session|agent` key per line,
 * NOT a JSON map rewritten in place. SEEN_FILE is shared by every concurrent
 * session and parallel subagent, and a read-modify-write loses marks whenever
 * two hooks interleave — measured at ~4 dropped in 12 parallel edits. An
 * O_APPEND write of a short line is atomic, so concurrent marks simply queue.
 */
function seenKeys() {
  try {
    return new Set(readFileSync(SEEN_FILE, "utf8").split("\n").filter(Boolean));
  } catch {
    return new Set(); // absent or unreadable -> nothing seen yet
  }
}

/** Compact the log once it has grown well past what it needs to remember. */
function pruneIfLarge() {
  try {
    const lines = readFileSync(SEEN_FILE, "utf8").split("\n").filter(Boolean);
    if (lines.length <= SEEN_MAX_KEYS * 2) return;
    const keep = [...new Set(lines)].slice(-SEEN_MAX_KEYS);
    const tmp = `${SEEN_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, keep.join("\n") + "\n");
    renameSync(tmp, SEEN_FILE); // rename is atomic; readers never see a partial file
  } catch {
    // best-effort: a skipped prune only costs disk
  }
}

function markSeen(key) {
  try {
    mkdirSync(dirname(SEEN_FILE), { recursive: true });
    appendFileSync(SEEN_FILE, key + "\n");
    pruneIfLarge();
    return true;
  } catch {
    return false;
  }
}

try {
  const input = await readHookInput();

  if (!EDIT_TOOLS.has(input.tool_name)) quit();

  const agentId = typeof input.agent_id === "string" ? input.agent_id : "";
  if (!agentId) quit(); // main session — SessionStart already injected the rule

  const resolved = resolveConfig(input.cwd || process.cwd());
  if (!resolved.configured || !resolved.enabled) quit();

  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  const key = sessionId + "|" + agentId;
  if (seenKeys().has(key)) quit();

  markSeen(key); // inject even if the mark did not persist

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: DIRECTIVE,
      },
    })
  );
} catch {
  quit(); // never break an edit
}
