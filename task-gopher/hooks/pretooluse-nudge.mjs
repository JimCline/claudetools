#!/usr/bin/env node
/**
 * task-gopher — strict-mode PreToolUse checkpoint.
 *
 * Active only when BOTH task-gopher is enabled AND strict mode is on. It blocks
 * the FIRST direct retrieval of each turn exactly once, nudging the agent to
 * consider dispatching to task-gopher before it does tool work itself. This is
 * the "double-check gate": a conscious, deliberate beat, not a hard wall —
 * re-running the same call proceeds, and the gate stays silent for the rest of
 * the turn.
 *
 * Turn = one user prompt, tracked by the payload's `prompt_id`: the first gated
 * call of a turn writes that prompt_id to NUDGE_FILE and denies; any later call
 * in the same turn (including the re-run) sees the matching id and is allowed.
 *
 * HONEST LIMIT: this cannot verify the agent *genuinely* reconsidered — a re-run
 * always passes. It is a forcing function, not a guarantee. It never fires inside
 * task-gopher itself (retrieval is that runner's whole job).
 *
 * Fails open on any error, unknown shape, or missing prompt_id — a broken gate
 * must never brick the Read/Grep/Glob/Bash tools.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { NUDGE_FILE, isEnabled, isStrict, isTaskGopherAgent } from "./directive.mjs";

const allow = () => process.exit(0);

const deny = (reason) => {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
};

// Bash commands that are retrieval/search/read/heavy — the delegatable kind.
// (Plain state changes like git add/commit, mkdir, cd, echo are intentionally
// NOT gated: they aren't what floods context and aren't task-gopher's job.)
const RETRIEVAL_BASH = [
  /\b(grep|rg|ack|ag)\b/,
  /\bfind\b/,
  /\b(cat|head|tail|bat|less)\b/,
  /\bgit\s+(diff|log|show|blame|grep)\b/,
  /\b(npm|yarn|pnpm|bun)\s+(test|run\s+build|run\s+lint)\b/,
  /\b(pytest|jest|vitest|tox|nox)\b/,
  /\b(cargo|go)\s+(test|build)\b/,
  /\b(make|gradle|gradlew|mvn)\b/,
];

function isRetrieval(payload) {
  const tool = payload.tool_name;
  if (tool === "Read" || tool === "Grep" || tool === "Glob") return true;
  if (tool === "Bash") {
    const cmd = payload?.tool_input?.command;
    return typeof cmd === "string" && RETRIEVAL_BASH.some((re) => re.test(cmd));
  }
  return false;
}

function nudgeMessage(payload) {
  const what =
    payload.tool_name === "Bash"
      ? "this command (`" + String(payload?.tool_input?.command || "").slice(0, 80) + "`)"
      : "a " + payload.tool_name;
  return [
    "task-gopher (strict) — one-time checkpoint for this turn.",
    "",
    `You're about to run ${what} directly. If you're Sonnet-tier or higher: could task-gopher do this retrieval instead? Bundle it with any other reads/greps/diffs you need this turn into ONE dispatched order and keep your own context clean.`,
    "",
    "If you've considered that and still want to do it yourself — it needs YOUR judgment, or it's a single trivial peek — just RE-RUN the exact same call. This gate fires only once per turn and won't ask again until the next user message. (Haiku-tier: this isn't for you — re-run.)",
  ].join("\n");
}

try {
  if (!isStrict() || !isEnabled()) allow();

  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  if (isTaskGopherAgent(payload)) allow(); // never gate the gopher's own retrievals
  if (!isRetrieval(payload)) allow();

  const pid = payload.prompt_id;
  if (typeof pid !== "string" || !pid) allow(); // can't scope a turn -> fail open

  let last = "";
  try {
    last = readFileSync(NUDGE_FILE, "utf8").trim();
  } catch {
    last = "";
  }
  if (last === pid) allow(); // already nudged this turn

  try {
    writeFileSync(NUDGE_FILE, pid);
  } catch {
    // if we can't record it, don't trap the agent in a re-nudge loop
    allow();
  }
  deny(nudgeMessage(payload));
} catch {
  allow(); // fail open, always
}
