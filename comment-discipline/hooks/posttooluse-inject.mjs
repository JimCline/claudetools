#!/usr/bin/env node
/**
 * comment-discipline — subagent backstop.
 *
 * SessionStart reaches the main session only, so a subagent starts without the
 * authoring rule unless the dispatching agent relayed it into the prompt. This
 * hook delivers it on the subagent's first edit.
 *
 * Why PostToolUse on the edit tools rather than a gate on `Agent` dispatches:
 * this rule only matters to an agent that actually authors code, and tool
 * events are the only hooks that fire INSIDE a subagent's loop (their input
 * carries `agent_id`/`agent_type`). Keying on the first edit therefore charges
 * the ~2.4KB directive only to agents that write, and never to the retrieval
 * and review dispatches that make up most subagent traffic. It also keeps this
 * plugin off the `Agent` tool, where task-gopher's relay gate already denies —
 * the docs do not define how two denying hooks combine, so not stacking a
 * second one there is deliberate.
 *
 * Two honest limits:
 *   - It CANNOT tell whether the relay already happened: PostToolUse carries no
 *     dispatch prompt. So it injects unconditionally on the first edit, and a
 *     subagent that WAS correctly relayed receives the rule twice (~2.4KB of
 *     avoidable duplication, once per code-writing subagent). That is the price
 *     of covering the agents the relay missed.
 *   - The first edit itself is unguarded — the injection lands with that edit's
 *     result and shapes every edit after it. Relaying into the dispatch prompt
 *     is what covers edit #1, and it is the ONLY thing that covers a subagent
 *     which makes exactly one edit.
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
