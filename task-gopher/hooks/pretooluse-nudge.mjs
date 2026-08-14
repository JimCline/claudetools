#!/usr/bin/env node
/**
 * task-gopher — PreToolUse gate. Two independent jobs:
 *
 * RELAY (active whenever the plugin is ON): subagents inherit neither the
 * parent's context nor the SessionStart/UserPromptSubmit injections — the
 * dispatch prompt is the only channel that reaches them at spawn. So this hook
 * REWRITES the dispatch in flight: it returns `updatedInput` with the directive
 * prepended to the subagent's prompt. The parent never sees it, spends no
 * output tokens copying it, and there is no bounce — the harness hands the
 * spawned subagent a prompt that already carries the directive. (Verified live:
 * a probe agent dispatched with a 300-char prompt reported receiving a
 * 7300-char one opening with the tier gate.)
 *
 * Because PreToolUse also fires inside a subagent's own loop, a subagent
 * dispatching a grandchild gets the same rewrite — the chain is automatic and
 * needs no cooperation from any model.
 *
 * Skipped: dispatches to task-gopher itself (they ARE the delegation), agents
 * that cannot dispatch and so can do nothing with the directive — builtins by
 * name (Explore, Plan, statusline-setup, output-style-setup), anything the user
 * listed in RELAY_EXEMPT_FILE, and anything whose definition declares a `tools:`
 * allow-list without Agent/Task (see agent-tools.mjs) — and any prompt that
 * already carries the sentinel near the top, so a parent that pasted the
 * directive by hand is not made to carry it twice. The sentinel check is
 * top-anchored so a mid-prompt *mention* of it does not count as a relay.
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
 * SCOPE: one streak per (session, agent, turn) — see `contextKey`. Each
 * subagent therefore gets its own checkpoint rather than spending the parent's
 * budget, which is deliberate: the directive applies to subagents too, and a
 * subagent that shares the parent's counter is almost never checkpointed at all
 * (the parent has usually spent the turn-start block before the subagent runs).
 * The cost is one extra round trip per retrieval-doing subagent; dispatches to
 * task-gopher itself are exempt at the top of the script, so the runner never
 * pays it.
 *
 * DESTRUCTIVE GUARD (active whenever the plugin is INSTALLED, on or off): the
 * runner's own Bash calls are classified, and any stage that destroys local
 * state or leaves the machine raises a permission prompt so a PERSON accepts
 * the risk. It asks every time — including when the lead pre-authorized the
 * command with an `ALLOW-DESTRUCTIVE:` line, which appears IN the prompt as
 * context rather than skipping it, because one model vouching for another is
 * not informed consent. Where no prompt can reach a human (guard set to
 * `block`, or a permission mode like bypassPermissions/dontAsk/auto), it falls
 * back to denying unless that written authorization exists.
 *
 * Unlike everything else here it does not respect the ON toggle, because the
 * agent stays dispatchable when the delegation directive is off — and a runner
 * with unrestricted `rm -rf` is exactly as dangerous either way. See
 * destructive.mjs.
 *
 * HONEST LIMITS: the checkpoint cannot verify the agent *genuinely*
 * reconsidered — a re-run always passes. And the relay depends on the harness
 * honoring `updatedInput` on the Agent tool; if a future version stops doing
 * so, delivery fails SILENTLY (the dispatch still succeeds, the subagent just
 * never sees the directive). Neither ever fires inside task-gopher itself.
 *
 * Fails open on any error, unknown shape, or unwritable state — a broken gate
 * must never brick tools or block a dispatch.
 */

import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { cannotDispatch } from "./agent-tools.mjs";
import { askMessage, classify, denyMessage, isAllowed, recordAllowances } from "./destructive.mjs";
import {
  FULL_DIRECTIVE,
  LOG_FILE,
  NUDGE_FILE,
  SENTINEL,
  canAskHuman,
  guardMode,
  isEnabled,
  isStrict,
  isTaskGopherAgent,
  readRelayExempt,
} from "./directive.mjs";

// Re-block on the Nth consecutive bypass within a turn (N-1 pass silently).
const RENUDGE_AFTER = 3;

// A relayed directive leads the prompt, so the sentinel must appear this early;
// anywhere later is a mention, not a relay.
const SENTINEL_WINDOW = 200;

// Built-in subagents without the Agent tool: they can't act on the directive,
// so rewriting their prompt would only cost tokens. Built-ins ship with no
// definition file, so they are the one group that has to be named outright —
// everything else is decided from the agent's own `tools:` list or the user's
// exempt file.
const RELAY_EXEMPT = new Set(["Explore", "Plan", "statusline-setup", "output-style-setup"]);

/**
 * Why this dispatch must not be stamped, or "" to stamp it. Ordered cheapest
 * first: a name match, then a small file read, then resolving the agent's
 * definition off disk.
 */
function relaySkipReason(subagentType, cwd) {
  if (RELAY_EXEMPT.has(subagentType)) return "builtin";
  if (readRelayExempt().includes(subagentType)) return "user-exempt";
  if (cannotDispatch(subagentType, cwd)) return "no-dispatch-tool";
  return "";
}

const allow = () => process.exit(0);

/**
 * Rewrite the dispatch in flight. Passes the whole tool_input back with only
 * `prompt` changed, so it is correct whether the harness merges or replaces.
 */
const injectDirective = (toolInput) => {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: { ...toolInput, prompt: FULL_DIRECTIVE + "\n\n" + toolInput.prompt },
      },
    })
  );
  process.exit(0);
};

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

/** Hand the decision to the user. The reason text is what they see in the dialog. */
const ask = (reason) => {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
};

// Bash commands that are retrieval/search/read/heavy — the delegatable kind.
// (Plain state changes like git add/commit, mkdir, cd, echo are intentionally
// NOT gated: they aren't what floods context and aren't task-gopher's job.)
const RETRIEVAL_ANY = [
  /\b(grep|rg|ack|ag)\b/,
  /\bfind\b/,
  /\bgit\s+(diff|log|show|blame|grep)\b/,
  /\b(npm|yarn|pnpm|bun)\s+(test|run\s+build|run\s+lint)\b/,
  /\b(pytest|jest|vitest|tox|nox)\b/,
  /\b(cargo|go)\s+(test|build)\b/,
  /\b(make|gradle|gradlew|mvn)\b/,
];

/**
 * These count ONLY when they lead the command. `tail -50 app.log` reads a file;
 * `git push | tail -10` TRIMS output — which is the habit this plugin exists to
 * encourage, so gating it was backwards. Same for `cmd | head`, `... | less`.
 */
const READER_LEADING = [/\b(cat|head|tail|bat|less)\b/];

/**
 * A retrieval word inside a quoted span is text, not a command:
 * `git commit -m "add tail support"` is not a read, and neither is
 * `git commit -m "$(cat <<'EOF' ...)"`. Both were being blocked.
 */
function stripQuoted(cmd) {
  return cmd.replace(/'[^']*'/g, " ").replace(/"[^"]*"/g, " ");
}

/**
 * Match per pipeline/sequence stage rather than against the raw string, so a
 * word's POSITION decides what it means.
 */
function isRetrieval(payload) {
  const tool = payload.tool_name;
  if (tool === "Read" || tool === "Grep" || tool === "Glob") return true;
  if (tool !== "Bash") return false;

  const cmd = payload?.tool_input?.command;
  if (typeof cmd !== "string") return false;

  const stages = stripQuoted(cmd).split(/\|\||&&|[|;\n]/);
  return stages.some(
    (stage, i) =>
      RETRIEVAL_ANY.some((re) => re.test(stage)) ||
      (i === 0 && READER_LEADING.some((re) => re.test(stage)))
  );
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

/**
 * Identifies ONE agent's streak within ONE turn. All three parts are load-
 * bearing: `prompt_id` alone is a turn but not a context, so the main agent and
 * every subagent it spawns shared a single counter — and `session_id` is what
 * keeps concurrent Claude Code sessions off each other's state, since
 * NUDGE_FILE is shared by every session under this HOME.
 *
 * Empty `agent_id` means the main session, which is a context like any other.
 */
function contextKey(payload) {
  const p = typeof payload.prompt_id === "string" ? payload.prompt_id : "";
  if (!p) return ""; // can't scope a turn -> caller fails open
  const s = typeof payload.session_id === "string" ? payload.session_id : "";
  const a = typeof payload.agent_id === "string" ? payload.agent_id : "";
  return `${s}|${a}|${p}`;
}

/**
 * Streak state is an append-only line log, NOT a single {pid, n} slot rewritten
 * in place. The slot was the bug: one shared record for the whole machine meant
 * any other context writing its own id made the next reader see a foreign turn
 * and re-fire the turn-start checkpoint — so the "just RE-RUN to proceed"
 * escape hatch this gate advertises did not actually work. Measured over five
 * days: 76% of turn-start checkpoints fired on a turn already in progress,
 * median 2.7 seconds after that turn's previous event.
 *
 * An O_APPEND write of a short line is atomic, so concurrent contexts queue
 * instead of clobbering. A bare key line is one bypass; `key\tR` resets the
 * streak to zero. Resets are markers rather than deletions because the log
 * cannot be rewritten safely, and because "seen but reset to 0" must stay
 * distinguishable from "never seen" — that distinction is exactly what tells a
 * re-run apart from a fresh turn.
 */
const RESET = "\tR";
const NUDGE_MAX_LINES = 400;

function readLines() {
  try {
    return readFileSync(NUDGE_FILE, "utf8").split("\n").filter(Boolean);
  } catch {
    return []; // absent or unreadable -> nothing seen yet
  }
}

/** Replay one context's lines: has it been checkpointed, and how many bypasses since its last reset. */
function readStreak(lines, key) {
  const reset = key + RESET;
  let seen = false;
  let n = 0;
  for (const line of lines) {
    if (line === key) {
      seen = true;
      n++;
    } else if (line === reset) {
      seen = true;
      n = 0;
    }
  }
  return { seen, n };
}

/** Compact once the log has grown well past what any live turn needs. */
function pruneIfLarge() {
  try {
    const lines = readLines();
    if (lines.length <= NUDGE_MAX_LINES * 2) return;
    const tmp = `${NUDGE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, lines.slice(-NUDGE_MAX_LINES).join("\n") + "\n");
    renameSync(tmp, NUDGE_FILE); // rename is atomic; readers never see a partial file
  } catch {
    // best-effort: a skipped prune only costs disk
  }
}

function appendState(line) {
  try {
    mkdirSync(dirname(NUDGE_FILE), { recursive: true });
    appendFileSync(NUDGE_FILE, line + "\n");
    pruneIfLarge();
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
  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  const pid = typeof payload.prompt_id === "string" ? payload.prompt_id : "";
  const aid = typeof payload.agent_id === "string" ? payload.agent_id : "";
  const sid = typeof payload.session_id === "string" ? payload.session_id : "";

  // Runs before the ON check: the guard protects against the agent, not against
  // the directive, and the agent exists whenever the plugin is installed.
  if (isTaskGopherAgent(payload)) {
    const mode = guardMode();
    if (payload.tool_name === "Bash" && mode !== "off") {
      const hits = classify(payload?.tool_input?.command);
      if (hits.length) {
        const detail = hits.map((h) => h.stage).join(" ; ").slice(0, 300);
        const labels = hits.map((h) => h.label);
        const preauthorized = hits.every((h) => isAllowed(sid, h.stage));

        // ASK, even when the lead pre-authorized. A lead's ALLOW-DESTRUCTIVE
        // line is one model vouching for another; the risk is the user's to
        // accept, so the authorization becomes CONTEXT IN the prompt rather
        // than a way around it.
        if (mode === "ask" && canAskHuman(payload)) {
          logEvent({ pid, aid, event: "destructive-ask", tool: "Bash", detail, labels, preauthorized });
          ask(askMessage(hits, preauthorized));
        }

        // Either the guard is set to block outright, or the session runs in a
        // permission mode where no prompt reaches anyone. Both fall back to the
        // lead's written authorization as the only remaining release.
        if (!preauthorized) {
          const unaskable = mode === "ask" ? payload.permission_mode || "unknown" : "";
          logEvent({
            pid,
            aid,
            event: "destructive-blocked",
            tool: "Bash",
            detail,
            labels,
            why: unaskable ? `no-human:${unaskable}` : "guard-mode:block",
          });
          deny(denyMessage(hits, unaskable));
        }
        logEvent({ pid, aid, event: "destructive-allowed", tool: "Bash", detail });
      }
    }
    allow(); // otherwise never gate the gopher's own tool use
  }

  // Authorization is recorded before the ON check for the same reason the guard
  // runs there — a guard that is live while the plugin is off needs a release
  // valve that is live too.
  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";
    if (st.includes("task-gopher")) {
      const authorized = recordAllowances(sid, t.prompt);
      if (authorized.length) {
        logEvent({
          pid,
          aid,
          event: "destructive-allowance",
          tool: payload.tool_name,
          detail: authorized.join(" ; ").slice(0, 300),
        });
      }
    }
  }

  if (!isEnabled()) allow();

  const key = contextKey(payload);

  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";

    // A dispatch to task-gopher is the desired outcome: never rewritten, and it
    // resets the strict-mode consecutive-bypass streak (reward good behavior).
    if (st.includes("task-gopher")) {
      if (key) {
        appendState(key + RESET);
        logEvent({ pid, aid, event: "dispatch", tool: payload.tool_name, detail: st });
      }
      allow();
    }

    // Logged rather than silent: a skip that fires wrongly is invisible from the
    // outside — the dispatch still succeeds, the subagent just never sees the
    // directive — so the audit log is the only place it can be caught.
    const skip = relaySkipReason(st, payload.cwd);
    if (skip) {
      logEvent({ pid, aid, event: "relay-skip", tool: payload.tool_name, detail: st, reason: skip });
      allow();
    }

    if (typeof t.prompt !== "string") allow(); // unexpected payload shape -> fail open
    if (t.prompt.slice(0, SENTINEL_WINDOW).includes(SENTINEL)) {
      logEvent({ pid, aid, event: "relay-ok", tool: payload.tool_name, detail: st });
      allow(); // already carries it — don't double up
    }

    logEvent({ pid, aid, event: "relay-injected", tool: payload.tool_name, detail: st });
    injectDirective(t);
  }

  if (!isStrict()) allow();
  if (!isRetrieval(payload)) allow();
  if (!key) allow(); // can't scope a turn -> fail open

  const { seen, n } = readStreak(readLines(), key);
  const tool = payload.tool_name;
  const detail = detailOf(payload);

  // First retrieval by THIS agent in this turn: the checkpoint. Only block if
  // the mark persists, else the re-run would re-trigger forever.
  if (!seen) {
    if (!appendState(key + RESET)) allow();
    logEvent({ pid, aid, event: "checkpoint", kind: "turn-start", tool, detail });
    deny(nudgeMessage(payload, 0));
  }

  // Already checkpointed this turn: this retrieval is a bypass.
  const next = n + 1;
  if (next >= RENUDGE_AFTER) {
    if (!appendState(key + RESET)) allow(); // reset streak; re-block once
    logEvent({ pid, aid, event: "checkpoint", kind: "escalated", bypasses: next, tool, detail });
    deny(nudgeMessage(payload, next));
  }

  if (!appendState(key)) allow(); // record the bypass and allow
  logEvent({ pid, aid, event: "bypass", n: next, tool, detail });
  allow();
} catch {
  allow(); // fail open, always
}
