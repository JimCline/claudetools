/**
 * understudy — shared state + directive text.
 *
 * Enabled state is a single marker file at ~/.claude/understudy.enabled.
 * Existence = ON. It lives in the user's home (not the plugin cache, which is
 * wiped on update) so the toggle survives plugin upgrades. Default is OFF:
 * this materially changes how the main agent works, so it is opt-in.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const STATE_FILE = join(homedir(), ".claude", "understudy.enabled");

export function isEnabled() {
  return existsSync(STATE_FILE);
}

/** Full directive — injected at SessionStart (and re-injected post-compaction). */
export const FULL_DIRECTIVE = [
  "[understudy: ON] Delegate expensive tool work to the `understudy` subagent (pinned to Haiku) instead of doing it yourself. Spend YOUR expensive high-reasoning tokens on judgment, not on tool output or log dumps.",
  "",
  'Delegate to `understudy` (Agent tool, subagent_type: "understudy") when a step is:',
  "- Tool/output-heavy: running test suites, builds, installs, long or verbose bash; sifting logs.",
  '- Retrieval / summarization: "find where X is defined", "list the callers", "summarize module Y", reading many files, searching a large tree.',
  "- Long-running or high-output, or otherwise likely to dump lots of tokens into your context.",
  "",
  "Keep for yourself: design decisions, correctness/security judgment, tradeoffs, and writing/editing code. For a task that needs reasoning, SPLIT it — have `understudy` gather the raw material and return a compact report, then you reason over the report.",
  "",
  'Decision rule (apply fast, do not overthink it): "Would doing this myself flood my context, OR is it retrieval I can specify precisely? -> delegate. Does the answer need MY judgment? -> keep the judgment, delegate the gathering." When unsure whether a step needs reasoning, keep it.',
  "",
  'Give `understudy` a precise, self-contained task and state the exact compact output you want back (e.g. "just the file:line and the function signature", "just the FAIL lines and the exit code"). It cannot see your context.',
  "",
  "Escape hatch: if `understudy` returns incomplete, wrong, or insufficient information, or reports it could not do the task, you MAY do it yourself or re-delegate ONCE with a sharper spec. Do not ping-pong more than about once before taking it over — a stalled delegation costs more than just doing it.",
].join("\n");

/** Compact per-turn reminder — injected at UserPromptSubmit to keep the behavior alive. */
export const SHORT_REMINDER =
  "[understudy: ON] Prefer delegating tool-heavy and info-gathering steps to the `understudy` (haiku) subagent and keep reasoning for yourself. Escape hatch: take it over if the subagent fails or returns too little.";
