/**
 * task-gopher — shared state + directive text.
 *
 * Enabled state is a single marker file at ~/.claude/task-gopher.enabled.
 * Existence = ON. It lives in the user's home (not the plugin cache, which is
 * wiped on update) so the toggle survives plugin upgrades. Default is OFF:
 * this materially changes how the main agent works, so it is opt-in.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const STATE_FILE = join(homedir(), ".claude", "task-gopher.enabled");

export function isEnabled() {
  return existsSync(STATE_FILE);
}

/** Read the hook's stdin JSON payload; returns {} if absent or unparseable. */
export async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/**
 * Who may delegate is gated by MODEL TIER, not by orchestrator-vs-subagent: any
 * Sonnet-tier-or-higher agent (main OR subagent) may dispatch to the Haiku
 * task-gopher; a Haiku-tier agent may not. Crucially, the hook payload exposes
 * NO model field (verified against the Claude Code CLI: the base hook input is
 * session_id/transcript_path/cwd/prompt_id/permission_mode/agent_id/agent_type/
 * effort — `effort` is the thinking level low|medium|high, not a capability
 * tier). So the hook cannot read the tier; the tier gate lives in the directive
 * text itself, where each agent self-excludes if it is Haiku-tier.
 *
 * The one thing the hook CAN do reliably is skip task-gopher itself by name
 * (`agent_type` carries the subagent's name), so the recursion-prone runner
 * never even receives the directive. Substring match tolerates the plugin-scoped
 * form (e.g. "task-gopher:task-gopher").
 */
export function isTaskGopherAgent(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.includes("task-gopher");
}

/** Full directive — injected at SessionStart (and re-injected post-compaction). */
export const FULL_DIRECTIVE = [
  "[task-gopher: ON] TIER GATE — read first: this directive is for Sonnet-tier models and above (Sonnet, Opus, and the Mythos-class Fable/Mythos). If YOU are a Haiku-tier model, IGNORE everything below and just do the work yourself — you are the cheap runner, not the expensive reasoner this optimizes for. This is also what stops a task-gopher (Haiku) runner from dispatching to task-gopher and recursing. Otherwise, if you are Sonnet-tier or higher, follow the rest — and note it applies whether you are the top-level agent or a subagent: any capable reasoner should push cheap legwork down to Haiku.",
  "",
  "Dispatch expensive tool work to the `task-gopher` subagent (pinned to Haiku) instead of doing it yourself. Spend YOUR expensive high-reasoning tokens on judgment, not on tool output or log dumps. task-gopher is a hired runner that carries out explicit orders and reports back.",
  "",
  'Dispatch to `task-gopher` (Agent tool, subagent_type: "task-gopher") when a step is:',
  "- Tool/output-heavy: running test suites, builds, installs, long or verbose bash; sifting logs.",
  '- Retrieval / summarization: "find where X is defined", "list the callers", "summarize module Y", reading many files, searching a large tree.',
  "- Long-running or high-output, or otherwise likely to dump lots of tokens into your context.",
  "",
  "Keep for yourself: ALL reasoning — design decisions, correctness/security judgment, tradeoffs, and writing/editing code. For a task that needs reasoning, SPLIT it: have `task-gopher` gather the raw material or run the step and return a compact report, then you reason over the report.",
  "",
  'Decision rule (apply fast, do not overthink it): "Would doing this myself flood my context, OR is it a mechanical task I can specify exactly? -> dispatch it. Does it need MY judgment? -> keep the judgment, dispatch only the legwork." When unsure whether a step needs reasoning, keep it.',
  "",
  '`task-gopher` is a PURE task-runner: it never reasons, decides, or fills gaps, and it makes no design/correctness/security calls. It will STOP and report back if an order is ambiguous rather than guess. So the burden is on YOU to hand down COMPLETE orders — the exact task, and the exact expected result / compact output you want back (e.g. "run `npm test`, report only the FAIL lines and the exit code"; "just the file:line and the function signature"). Never dispatch a step that would require the runner to make a choice. It cannot see your context — every order must be self-contained.',
  "",
  "Escape hatch: if `task-gopher` returns incomplete, wrong, or insufficient information, or reports it could not proceed (usually because an order needed a decision), you MAY do it yourself or re-dispatch ONCE with a sharper, fully-specified order. Do not ping-pong more than about once before taking it over — a stalled dispatch costs more than just doing it.",
].join("\n");

/** Compact per-turn reminder — injected at UserPromptSubmit to keep the behavior alive. */
export const SHORT_REMINDER =
  "[task-gopher: ON] If you are Sonnet-tier or higher (any agent, top-level or subagent): prefer dispatching tool-heavy and info-gathering steps to the `task-gopher` (haiku) runner with complete, decision-free orders, and keep reasoning for yourself. If you are Haiku-tier, ignore this. Escape hatch: take it over if the runner fails or returns too little.";
