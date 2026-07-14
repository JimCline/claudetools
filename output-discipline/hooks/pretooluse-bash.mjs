#!/usr/bin/env node
/**
 * output-discipline — PreToolUse gate on the Bash tool.
 *
 * Blocks commands that would flood the context window, and tells Claude what to
 * run instead. This is a PREVENTION layer: it stops the output from ever being
 * produced, which is strictly cheaper than compressing it after the fact.
 *
 * Fails open. Any parse error, unknown shape, or internal exception exits 0 and
 * allows the command — a broken hook must never brick the Bash tool.
 */

import { readFileSync } from "node:fs";

// --- config (env-overridable) ------------------------------------------------
const OFF = process.env.OUTPUT_DISCIPLINE_DISABLE === "1";
const EXTRA_ALLOW = (process.env.OUTPUT_DISCIPLINE_ALLOW || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// Commands that stream forever. These never belong in the foreground.
const STREAMING = [
  /\btail\s+(-\w*[fF]|--follow)/,
  /\bjournalctl\b[^|]*\s-f\b/,
  /\b(kubectl|docker|docker-compose|podman)\s+logs\b[^|]*\s(-f|--follow)\b/,
  /\bwatch\s+/,
  /--watch\b/,
  /--follow\b/,
  /\bless\b/,
  /\btop\b|\bhtop\b/,
];

// Long-lived foreground processes. These belong in a background task.
const LONG_RUNNING = [
  /\bnpm\s+(run\s+)?(dev|start|serve|watch)\b/,
  /\b(yarn|pnpm|bun)\s+(dev|start|serve|watch)\b/,
  /\b(vite|nodemon|webpack-dev-server)\b/,
  /\bnext\s+dev\b/,
  /\bflask\s+run\b/,
  /\b(uvicorn|gunicorn|hypercorn)\b/,
  /\brails\s+s(erver)?\b/,
  /\bpython\s+-m\s+http\.server\b/,
  /\bjest\b[^|]*--watch/,
  /\bvitest\b(?![^|]*\brun\b)/,
];

// Verbose one-shot commands. Fine to run — but the output must be captured to a
// file and filtered, not dumped whole.
const NOISY = [
  /\bnpm\s+(test|run\s+build|run\s+lint|install|ci)\b/,
  /\b(yarn|pnpm|bun)\s+(test|build|lint|install)\b/,
  /\b(pytest|tox|nox)\b/,
  /\bcargo\s+(build|test|clippy|check)\b/,
  /\bgo\s+(build|test)\b/,
  /\b(make|cmake|ninja)\b/,
  /\b(gradle|gradlew|mvn)\b/,
  /\bdocker\s+build\b/,
  /\bterraform\s+(plan|apply)\b/,
  /\bpip\s+install\b/,
  /\bcat\s+[^|]*\.log\b/,
];

// If the command already captures or filters its own output, it is well-behaved.
const ALREADY_TAMED = [
  />\s*\S+/, // redirect to a file
  /\|\s*(grep|rg|ag|head|tail|awk|sed|jq|wc|sort|uniq|cut)\b/,
  /\btee\b/,
];

// --- helpers ----------------------------------------------------------------
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

const matches = (patterns, cmd) => patterns.some((re) => re.test(cmd));

// --- main -------------------------------------------------------------------
try {
  if (OFF) allow();

  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  if (payload.tool_name !== "Bash") allow();

  const cmd = payload?.tool_input?.command;
  if (typeof cmd !== "string" || !cmd.trim()) allow();

  const isBackground = payload?.tool_input?.run_in_background === true;

  if (EXTRA_ALLOW.some((frag) => cmd.includes(frag))) allow();

  // 1. Streaming commands: never acceptable, background or not. A backgrounded
  //    `tail -f` still floods the moment its output is read back.
  if (matches(STREAMING, cmd)) {
    deny(
      `output-discipline: this command streams output indefinitely, which floods the context window.\n\n` +
        `Command: ${cmd}\n\n` +
        `Do this instead:\n` +
        `  - To wait for a condition in a live process: start it with run_in_background: true, then use the Monitor tool to wait for the specific line you care about.\n` +
        `  - To inspect a log that already exists: read a bounded slice — 'grep -nE "ERROR|WARN" FILE | head -40' or 'tail -n 50 FILE'.\n\n` +
        `Do not retry this command as-is.`
    );
  }

  // 2. Long-running foreground processes: fine, but they must be backgrounded.
  if (!isBackground && matches(LONG_RUNNING, cmd)) {
    deny(
      `output-discipline: this is a long-running process and must not run in the foreground — it will block and its output will flood the context window.\n\n` +
        `Command: ${cmd}\n\n` +
        `Re-run the exact same command with run_in_background: true, then use the Monitor tool to wait for the line that tells you it is ready (e.g. a "listening on" / "ready" message).`
    );
  }

  // 3. Verbose one-shot commands: must capture to a file and filter.
  if (!isBackground && matches(NOISY, cmd) && !matches(ALREADY_TAMED, cmd)) {
    deny(
      `output-discipline: this command can emit hundreds of lines straight into the context window, where they are re-sent on every subsequent turn.\n\n` +
        `Command: ${cmd}\n\n` +
        `Capture the output to a file, then extract only what you need:\n\n` +
        `  ${cmd} > /tmp/od.log 2>&1; echo "exit=$?"\n` +
        `  grep -nE "FAIL|ERROR|error:|✕|warning" /tmp/od.log | head -40\n\n` +
        `Then read specific line ranges from /tmp/od.log only if you need more. Report the exit code and say where the full log lives.\n\n` +
        `If you genuinely need the full unfiltered output, append '| tail -n 100' to bound it, or pipe through 'tee'.`
    );
  }

  allow();
} catch {
  allow(); // fail open, always
}
