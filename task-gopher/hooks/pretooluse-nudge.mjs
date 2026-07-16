#!/usr/bin/env node
/**
 * task-gopher — strict-mode PreToolUse checkpoint.
 *
 * Active only when BOTH task-gopher is enabled AND strict mode is on. It nudges
 * the agent to consider dispatching to task-gopher before it does tool work
 * itself. This is the "double-check gate": a conscious, deliberate beat, not a
 * hard wall — re-running the same call proceeds.
 *
 * ESCALATION: rather than nudging only once per turn, it tracks CONSECUTIVE
 * bypasses. It blocks the first retrieval of a turn, then lets the next two
 * direct retrievals through silently, then RE-BLOCKS on the 3rd consecutive
 * bypass (and every 3rd after that). Dispatching to task-gopher resets the
 * streak — good behavior buys a clean slate. So an agent that keeps pulling
 * things into its own context gets re-checkpointed; an agent that delegates is
 * left alone.
 *
 * Turn = one user prompt, tracked by the payload's `prompt_id`. State lives in
 * NUDGE_FILE as JSON {pid, n} where n is the bypass count within the turn.
 *
 * HONEST LIMIT: this cannot verify the agent *genuinely* reconsidered — a re-run
 * always passes. It is a forcing function, not a guarantee. It never fires inside
 * task-gopher itself (retrieval is that runner's whole job).
 *
 * Fails open on any error, unknown shape, missing prompt_id, or unwritable state
 * — a broken gate must never brick the Read/Grep/Glob/Bash tools or trap the
 * agent in a re-nudge loop.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { NUDGE_FILE, isEnabled, isStrict, isTaskGopherAgent } from "./directive.mjs";

// Re-block on the Nth consecutive bypass within a turn (N-1 pass silently).
const RENUDGE_AFTER = 3;

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

function isTaskGopherDispatch(payload) {
  if (payload.tool_name !== "Agent") return false;
  const st = payload?.tool_input?.subagent_type;
  return typeof st === "string" && st.includes("task-gopher");
}

function readState() {
  try {
    const o = JSON.parse(readFileSync(NUDGE_FILE, "utf8"));
    if (o && typeof o.pid === "string") {
      return { pid: o.pid, n: Number.isInteger(o.n) ? o.n : 0 };
    }
  } catch {
    // no/broken state -> fresh
  }
  return { pid: "", n: 0 };
}

function writeState(pid, n) {
  try {
    writeFileSync(NUDGE_FILE, JSON.stringify({ pid, n }));
    return true;
  } catch {
    return false;
  }
}

function nudgeMessage(payload, bypasses) {
  const what =
    payload.tool_name === "Bash"
      ? "this command (`" + String(payload?.tool_input?.command || "").slice(0, 80) + "`)"
      : "a " + payload.tool_name;
  if (bypasses >= RENUDGE_AFTER) {
    return [
      `task-gopher (strict) — checkpoint again: ${RENUDGE_AFTER} direct retrievals in a row this turn without dispatching.`,
      "",
      `You're about to run ${what}. You've been pulling tool output into your own context repeatedly — that's the drift this guards against. Batch the retrievals you still need into ONE task-gopher order instead of continuing.`,
      "",
      "If you genuinely must keep doing these yourself, RE-RUN to proceed. Dispatching to task-gopher clears this streak so the checkpoint stops recurring. (Haiku-tier: re-run; this isn't for you.)",
    ].join("\n");
  }
  return [
    "task-gopher (strict) — checkpoint for this turn.",
    "",
    `You're about to run ${what} directly. If you're Sonnet-tier or higher: could task-gopher do this retrieval instead? Bundle it with any other reads/greps/diffs you need this turn into ONE dispatched order and keep your own context clean.`,
    "",
    "If you've considered that and still want to do it yourself — it needs YOUR judgment, or it's a single trivial peek — just RE-RUN the exact same call. This won't ask again until you've done a few more direct retrievals. (Haiku-tier: this isn't for you — re-run.)",
  ].join("\n");
}

try {
  if (!isStrict() || !isEnabled()) allow();

  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  if (isTaskGopherAgent(payload)) allow(); // never gate the gopher's own retrievals

  const pid = payload.prompt_id;

  // A dispatch to task-gopher resets the consecutive-bypass streak (reward good
  // behavior). Agent calls are never themselves gated.
  if (payload.tool_name === "Agent") {
    if (isTaskGopherDispatch(payload) && typeof pid === "string" && pid) {
      writeState(pid, 0);
    }
    allow();
  }

  if (!isRetrieval(payload)) allow();
  if (typeof pid !== "string" || !pid) allow(); // can't scope a turn -> fail open

  const state = readState();

  // New turn: initial checkpoint. Only block if we can persist state, else the
  // re-run would re-trigger forever.
  if (state.pid !== pid) {
    if (!writeState(pid, 0)) allow();
    deny(nudgeMessage(payload, 0));
  }

  // Same turn: this retrieval is a bypass.
  const next = state.n + 1;
  if (next >= RENUDGE_AFTER) {
    if (!writeState(pid, 0)) allow(); // reset streak; re-block once
    deny(nudgeMessage(payload, next));
  }

  writeState(pid, next); // record the bypass and allow
  allow();
} catch {
  allow(); // fail open, always
}
