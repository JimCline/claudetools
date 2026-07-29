#!/usr/bin/env node
/**
 * task-gopher — PreToolUse gate. Two independent jobs:
 *
 * RELAY GATE (active whenever the plugin is ON): subagents inherit neither the
 * parent's context nor the SessionStart/UserPromptSubmit injections — the
 * dispatch prompt is the only channel that reaches them at spawn. So this gate
 * bounces any Agent/Task dispatch missing the directive sentinel near the top
 * of its prompt (top-anchored so a mid-prompt *mention* of the sentinel doesn't
 * count as a relay), and puts the FULL directive in the deny reason so the
 * retry is a mechanical copy, not a reconstruction from memory. Dispatches to
 * task-gopher itself are never bounced (they ARE the delegation), and built-in
 * subagents without the Agent tool (Explore, Plan, statusline-setup,
 * output-style-setup) are exempt — they cannot act on the directive. After
 * RELAY_FORGO_AFTER bounces per context — counted per (session, agent, turn),
 * since one shared counter would let concurrent sessions starve each other's
 * cap — the gate stands down: a missed relay is a mild inefficiency, a deny
 * loop is a real failure.
 *
 * STRICT CHECKPOINT (requires strict mode on top of ON): nudges the agent to
 * consider dispatching to task-gopher before it does retrieval work itself.
 * This is the "double-check gate": a conscious, deliberate beat, not a hard
 * wall — re-running the same call proceeds.
 *
 * ESCALATION: rather than nudging only once per turn, it tracks CONSECUTIVE
 * bypasses. It blocks the first retrieval of a turn, then lets the next two
 * direct retrievals through silently, then RE-BLOCKS on the 3rd consecutive
 * bypass (and every 3rd after that). Dispatching to task-gopher resets the
 * streak — good behavior buys a clean slate. So an agent that keeps pulling
 * things into its own context gets re-checkpointed; an agent that delegates is
 * left alone.
 *
 * Turn = one user prompt, tracked by the payload's `prompt_id`. Checkpoint
 * state lives in NUDGE_FILE, relay-bounce state in RELAY_FILE, both as JSON
 * {pid, n}.
 *
 * HONEST LIMIT: the checkpoint cannot verify the agent *genuinely* reconsidered
 * — a re-run always passes — and the relay gate checks for the sentinel string,
 * not for a faithful copy. Both are forcing functions, not guarantees. Neither
 * ever fires inside task-gopher itself.
 *
 * Fails open on any error, unknown shape, missing prompt_id, or unwritable
 * state — a broken gate must never brick tools or trap an agent in a deny loop.
 */

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import {
  FULL_DIRECTIVE,
  LOG_FILE,
  NUDGE_FILE,
  RELAY_FILE,
  SENTINEL,
  isEnabled,
  isStrict,
  isTaskGopherAgent,
} from "./directive.mjs";

// Re-block on the Nth consecutive bypass within a turn (N-1 pass silently).
const RENUDGE_AFTER = 3;

// Stop bouncing relay-less dispatches after this many denies per context.
const RELAY_FORGO_AFTER = 2;

// A faithful copy puts the directive at the top of the dispatch prompt, so the
// sentinel must appear this early; anywhere later is a mention, not a relay.
const SENTINEL_WINDOW = 200;

// Contexts tracked in RELAY_FILE before the oldest are pruned.
const RELAY_MAX_KEYS = 32;

// Built-in subagents without the Agent tool: they can't act on the directive,
// so a missing relay there isn't worth a bounce.
const RELAY_EXEMPT = new Set(["Explore", "Plan", "statusline-setup", "output-style-setup"]);

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

// A short description of WHAT the agent ran directly, for the audit log.
function detailOf(payload) {
  const t = payload.tool_input || {};
  switch (payload.tool_name) {
    case "Bash":
      return String(t.command || "").slice(0, 160);
    case "Read":
      return String(t.file_path || "");
    case "Grep":
      return String(t.pattern || "");
    case "Glob":
      return String(t.pattern || t.glob || "");
    default:
      return "";
  }
}

// Append one audit line. Never throws — logging must not break the tool.
function logEvent(entry) {
  try {
    let ts = "";
    try {
      ts = new Date().toISOString();
    } catch {
      ts = "";
    }
    appendFileSync(LOG_FILE, JSON.stringify({ ts, ...entry }) + "\n");
  } catch {
    // best-effort; drop on failure
  }
}

function readCounter(file) {
  try {
    const o = JSON.parse(readFileSync(file, "utf8"));
    if (o && typeof o.pid === "string") {
      return { pid: o.pid, n: Number.isInteger(o.n) ? o.n : 0 };
    }
  } catch {
    // no/broken state -> fresh
  }
  return { pid: "", n: 0 };
}

function writeCounter(file, pid, n) {
  try {
    writeFileSync(file, JSON.stringify({ pid, n }));
    return true;
  } catch {
    return false;
  }
}

// Relay bounces are counted per (session, agent, turn): RELAY_FILE is shared by
// every session under this HOME, and a single {pid,n} slot would let interleaved
// contexts reset each other's count — starving the fail-open cap exactly when
// it's needed — while sibling agents in one turn would exhaust it for each other.
function relayKey(payload, pid) {
  const sid = typeof payload.session_id === "string" ? payload.session_id : "";
  const aid = typeof payload.agent_id === "string" ? payload.agent_id : "";
  return sid + "|" + aid + "|" + pid;
}

function readRelayCount(key) {
  try {
    const o = JSON.parse(readFileSync(RELAY_FILE, "utf8"));
    const n = o && o.entries ? o.entries[key] : 0;
    return Number.isInteger(n) ? n : 0;
  } catch {
    return 0;
  }
}

function bumpRelayCount(key) {
  // Unlocked read-modify-write: a concurrent fan-out can drop an increment,
  // which only delays that context's fail-open by one bounce.
  let entries = {};
  try {
    const o = JSON.parse(readFileSync(RELAY_FILE, "utf8"));
    if (o && o.entries && typeof o.entries === "object") entries = o.entries;
  } catch {
    // no/broken state -> fresh
  }
  entries[key] = (Number.isInteger(entries[key]) ? entries[key] : 0) + 1;
  const keys = Object.keys(entries);
  for (let i = 0; i < keys.length - RELAY_MAX_KEYS; i++) delete entries[keys[i]];
  try {
    writeFileSync(RELAY_FILE, JSON.stringify({ entries }));
    return true;
  } catch {
    return false;
  }
}

function relayMessage() {
  return [
    "task-gopher — relay checkpoint: this dispatch prompt is missing the delegation directive.",
    "",
    "Subagents do not inherit your context, so the directive reaches them only inside the dispatch prompt. RE-ISSUE this exact call with the FULL directive block below copied VERBATIM to the TOP of `prompt` (the check is top-anchored), then your task text unchanged. Dispatches to task-gopher itself never need it. (This won't loop: after two bounces it stands down for this turn.)",
    "",
    "--- COPY EVERYTHING BELOW THIS LINE TO THE TOP OF THE DISPATCH PROMPT ---",
    FULL_DIRECTIVE,
  ].join("\n");
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
  if (!isEnabled()) allow();

  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  if (isTaskGopherAgent(payload)) allow(); // never gate the gopher's own tool use

  const pid = typeof payload.prompt_id === "string" ? payload.prompt_id : "";

  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";

    // A dispatch to task-gopher is the desired outcome: never bounced, and it
    // resets the strict-mode consecutive-bypass streak (reward good behavior).
    if (st.includes("task-gopher")) {
      if (pid) {
        writeCounter(NUDGE_FILE, pid, 0);
        logEvent({ pid, event: "dispatch", tool: payload.tool_name, detail: st });
      }
      allow();
    }

    if (RELAY_EXEMPT.has(st)) allow();

    if (typeof t.prompt !== "string") allow(); // unexpected payload shape -> fail open
    if (t.prompt.slice(0, SENTINEL_WINDOW).includes(SENTINEL)) {
      logEvent({ pid, event: "relay-ok", tool: payload.tool_name, detail: st });
      allow();
    }

    if (!pid) allow(); // can't scope the stand-down counter -> fail open

    const key = relayKey(payload, pid);
    const n = readRelayCount(key);
    if (n >= RELAY_FORGO_AFTER) {
      logEvent({ pid, event: "relay-forgone", tool: payload.tool_name, detail: st });
      allow();
    }
    if (!bumpRelayCount(key)) allow();
    logEvent({ pid, event: "relay-bounce", n: n + 1, tool: payload.tool_name, detail: st });
    deny(relayMessage());
  }

  if (!isStrict()) allow();
  if (!isRetrieval(payload)) allow();
  if (!pid) allow(); // can't scope a turn -> fail open

  const state = readCounter(NUDGE_FILE);
  const tool = payload.tool_name;
  const detail = detailOf(payload);

  // New turn: initial checkpoint. Only block if we can persist state, else the
  // re-run would re-trigger forever.
  if (state.pid !== pid) {
    if (!writeCounter(NUDGE_FILE, pid, 0)) allow();
    logEvent({ pid, event: "checkpoint", kind: "turn-start", tool, detail });
    deny(nudgeMessage(payload, 0));
  }

  // Same turn: this retrieval is a bypass.
  const next = state.n + 1;
  if (next >= RENUDGE_AFTER) {
    if (!writeCounter(NUDGE_FILE, pid, 0)) allow(); // reset streak; re-block once
    logEvent({ pid, event: "checkpoint", kind: "escalated", bypasses: next, tool, detail });
    deny(nudgeMessage(payload, next));
  }

  writeCounter(NUDGE_FILE, pid, next); // record the bypass and allow
  logEvent({ pid, event: "bypass", n: next, tool, detail });
  allow();
} catch {
  allow(); // fail open, always
}
