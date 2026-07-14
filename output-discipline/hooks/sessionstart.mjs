#!/usr/bin/env node
/**
 * output-discipline — SessionStart context injection.
 *
 * A plugin's CLAUDE.md is NOT loaded as project context, so the rules are
 * injected here instead. Fires on startup, resume, clear, AND compact —
 * compaction can summarize the rules away, so they must be re-injected
 * afterwards. Keep this SHORT: it is paid for on every single session,
 * and a verbose lecture about saving tokens is self-defeating.
 */

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: [
        "Command output discipline (enforced by a PreToolUse hook — commands that violate this are blocked):",
        "- Never stream output: no `tail -f`, `watch`, `--follow`, `--watch`, `less`, `top`.",
        "- Long-running processes (servers, watchers) must use run_in_background: true, then the Monitor tool to wait for a specific line. Never foreground them.",
        "- Verbose commands (test suites, builds, installs) must capture to a file and filter: `cmd > /tmp/x.log 2>&1; echo \"exit=$?\"` then `grep -nE 'FAIL|ERROR' /tmp/x.log | head -40`. Report the exit code and where the log lives.",
        "- Delegate log-sifting and multi-file reading to a subagent so the intermediate output stays out of this context.",
      ].join("\n"),
    },
  })
);
