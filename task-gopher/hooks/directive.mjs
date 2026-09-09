/**
 * task-gopher — shared state + directive text.
 *
 * Enabled state is a single marker file at ~/.claude/task-gopher.enabled.
 * Existence = ON. It lives in the user's home (not the plugin cache, which is
 * wiped on update) so the toggle survives plugin upgrades. Default is OFF:
 * this materially changes how the main agent works, so it is opt-in.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const STATE_FILE = join(homedir(), ".claude", "task-gopher.enabled");

export function isEnabled() {
  return existsSync(STATE_FILE);
}

/**
 * Strict mode — an optional enforcement layer ON TOP of `enabled`. When both are
 * set, a PreToolUse hook blocks the FIRST direct retrieval of each turn once, so
 * the agent has to consciously decide "should this go to task-gopher?" before
 * doing tool work itself. It's a speed-bump, not a hard block: re-running the
 * same call proceeds, and the gate stays quiet for the rest of that turn.
 */
export const STRICT_FILE = join(homedir(), ".claude", "task-gopher.strict");

/** Records {pid, n} for the current turn, so the checkpoint escalates by bypass count. */
export const NUDGE_FILE = join(homedir(), ".claude", "task-gopher.nudge");

/**
 * Optional user-maintained list of `subagent_type`s the relay must never stamp —
 * one per line, `#` comments and blank lines ignored, missing file means nothing
 * is exempt. It exists because the automatic tool-less check in agent-tools.mjs
 * can only read definitions that are ON DISK: an agent defined through the SDK
 * has no file to parse, so no amount of frontmatter reading will ever classify
 * it. Managed with `/task-gopher relay-exempt`.
 */
export const RELAY_EXEMPT_FILE = join(homedir(), ".claude", "task-gopher.relay-exempt");

export function readRelayExempt() {
  try {
    return readFileSync(RELAY_EXEMPT_FILE, "utf8")
      .split("\n")
      .map((line) => line.replace(/#.*$/, "").trim())
      .filter(Boolean);
  } catch {
    return []; // absent or unreadable -> nothing exempt, current behavior
  }
}


/**
 * How the destructive guard resolves a destructive or outward-facing command
 * from the runner. File contents, not existence — three states need three
 * values, and the marker-file idiom only carries two.
 *
 * - `ask` (DEFAULT, and what the plugin exists to do): raise a permission
 *   prompt so a PERSON decides. The runner cannot judge the risk and neither
 *   can its lead — an agent authorizing an agent is not informed consent.
 * - `block`: hard-deny, releasable only by the lead's written
 *   ALLOW-DESTRUCTIVE line. Correct for unattended runs where no one is at the
 *   keyboard to answer a prompt.
 * - `off`: no guard at all.
 */
export const GUARD_FILE = join(homedir(), ".claude", "task-gopher.guard");

export function guardMode() {
  try {
    const v = readFileSync(GUARD_FILE, "utf8").trim().toLowerCase();
    if (v === "block" || v === "off" || v === "ask") return v;
  } catch {
    // absent or unreadable -> the default
  }
  return "ask";
}

/**
 * Permission modes in which a prompt actually reaches a human. `auto`,
 * `dontAsk`, and `bypassPermissions` all exist precisely to stop asking, and
 * the hook docs do not say what becomes of an `ask` decision inside them — an
 * `ask` that is silently auto-approved would be the exact failure this guard
 * exists to prevent, so those modes fall back to denying instead.
 *
 * An ABSENT mode is treated as unaskable for the same reason: if the payload
 * cannot tell us a person is reachable, we do not gamble that one is.
 * (Modes per the hook docs: default, plan, acceptEdits, auto, dontAsk,
 * bypassPermissions.)
 */
const ASKABLE_PERMISSION_MODES = new Set(["default", "acceptEdits", "plan"]);

export function canAskHuman(input) {
  const mode = input && input.permission_mode;
  return typeof mode === "string" && ASKABLE_PERMISSION_MODES.has(mode);
}

/**
 * Commands the lead has explicitly authorized the runner to execute despite the
 * destructive guard, one `sessionId\tcommand` per line. Written when a dispatch
 * carrying `ALLOW-DESTRUCTIVE:` lines goes out; read when the runner's Bash call
 * is classified. See destructive.mjs.
 */
export const ALLOW_FILE = join(homedir(), ".claude", "task-gopher.allow");

/**
 * Append-only JSONL audit log. Checkpoint/bypass lines require strict mode;
 * dispatch, relay-ok/relay-injected, and destructive-guard lines are written
 * whenever the plugin is installed.
 */
export const LOG_FILE = join(homedir(), ".claude", "task-gopher.log");

export function isStrict() {
  return existsSync(STRICT_FILE);
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
 * The one thing the hooks CAN do reliably is skip either gopher itself by name
 * (`agent_type` carries the subagent's name), so no gate ever fires inside a
 * recursion-prone runner. Substring match tolerates the plugin-scoped form
 * (e.g. "task-gopher:task-gopher"). Note the injection hooks (SessionStart,
 * UserPromptSubmit) only ever run for the MAIN session — they never fire for
 * subagents. Subagents receive the directive solely via the relay gate in
 * pretooluse-nudge.mjs, which makes parents copy it into dispatch prompts.
 *
 * TODO(hard-gate): the tier gate is currently SOFT — the directive asks each
 * agent to self-exclude if it is Haiku-tier, which the hook cannot enforce
 * because no model/tier field exists in the hook payload (as of Claude Code
 * v2.1.211). If a future version adds one (e.g. `model` or a capability tier
 * to the SessionStart/UserPromptSubmit payload), convert this to a HARD gate:
 * read the field here and suppress injection for any Haiku-tier agent, so the
 * gate no longer relies on the model recognizing its own tier. Re-check the
 * payload shape in the CLI (function `Uf`, the base hook-input builder) when
 * upgrading. Track: https://code.claude.com/docs/en/hooks
 */

/**
 * The runner agents this plugin ships, and which one a name refers to.
 *
 * ORDER IS LOAD-BEARING. The plugin-scoped form of the reasoning runner is
 * "task-gopher:smart-gopher" — the PLUGIN half is literally "task-gopher", so a
 * task-gopher-first test classifies every smart-gopher as the Haiku runner. That
 * is invisible for a boolean gate and wrong where it matters most: the
 * permission dialog, which names the agent asking to destroy something. Most
 * specific name first.
 *
 * Substring rather than equality, matching the existing convention: the harness
 * may hand us the bare name or the plugin-scoped one, and both must match.
 * Known looseness (accept, do not fix): a user agent named
 * `my-smart-gopher-helper` would match. This is exactly the looseness the
 * existing code already had with `task-gopher`, it fails toward *more* guarding
 * rather than less, and tightening it would break the bare-vs-namespaced
 * tolerance this depends on.
 */
const GOPHER_KINDS = ["smart-gopher", "task-gopher"];

/** "smart-gopher" | "task-gopher" | null */
export function gopherKind(name) {
  if (typeof name !== "string" || !name) return null;
  for (const kind of GOPHER_KINDS) if (name.includes(kind)) return kind;
  return null;
}

/** Which runner is this hook firing inside, if any? Reads `agent_type`. */
export function agentGopherKind(input) {
  return gopherKind(input && input.agent_type);
}

/** Is this hook firing inside either runner? */
export function isGopherAgent(input) {
  return agentGopherKind(input) !== null;
}

/**
 * agent-hierarchy roles. Each one's own md already carries the delegation rule,
 * so paying for the directive again — relayed into a dispatch, injected into a
 * `--agent ah:<role>` session at start and on every compact, or reminded each
 * turn — buys nothing. Exact names, not an `ah:` prefix test: the set is small
 * and a prefix rule would silently swallow future non-role `ah:` agents.
 */
export const AH_ROLE_AGENTS = new Set([
  "ah:architect",
  "ah:implementor",
  "ah:orchestrator",
  "ah:reviewer",
  "ah:ultra-advisor",
  "ah:task-runner",
]);

/** Is this hook firing inside a `--agent ah:<role>` session? Reads `agent_type`. */
export function isHierarchyRoleAgent(input) {
  return AH_ROLE_AGENTS.has(input && input.agent_type);
}

/**
 * A range this long or longer is a whole-file hand-back in disguise: ~4 KB, one
 * Read chunk. Below it, batching a few small ranges into one dispatch is a
 * defensible trade against N tool round trips. Tuning knob (spec 0001 §2).
 */
export const LARGE_RANGE_LINES = 80;

/**
 * A match is a MENTION, not an order, when the text just before it negates it
 * ("don't dump the whole file") or frames it as something being described:
 * a spec, a test case, a labelling rule, a regex. Both live FPs this guard was
 * widened for were orders ABOUT the gate — describing the phrase is exactly
 * what spec- and test-writing work does, and under a hard deny there is no
 * workaround but to reword a description whose point is to name the phrase.
 *
 * The quote rule tests the QUALIFIER, never the path: paths are routinely
 * backticked in legitimate orders.
 */
const GUARD_WINDOW = 60;
const NEGATION = /\b(not|never|no|don'?t|do not|without|unless|instead of|rather than|avoid)\b/i;
const META =
  /\b(deny|denies|denied|denial|refuse[sd]?|reject[sd]?|block[sed]?|gate[sd]?|flag[sged]*|detect[sed]?|forbid[s]?|pattern|regex|test case|assert|counts? as|true positive|false positive|TP|FP|label[sled]*|classif\w*|definition|defined?|means|i\.e\.|e\.g\.)\b/i;

/**
 * A path token names a file: it holds a directory separator, or ends in an
 * extension whose first character is a letter. A trailing slash makes it a
 * directory ("docs/"), and a version string ("v0.16.0") has digits where an
 * extension's letters would be — neither is a file.
 */
const PATH_TOKEN =
  /(?<![\w./~-])[`"']?((?:[\w.~@+-]*\/[\w.~@/+-]*[\w~+-])|(?:[\w-]+\.[A-Za-z]\w{0,4}(?![\w-]|\.\w)))[`"']?(?![\w/~-])/g;

/** Glue may run this far between the qualifier and the path before they stop being one breath. */
const GLUE_MAX = 40;
const GLUE_WORDS = /^(?:[\s:,(—–]|\b(?:of|for|from|in|at|and|the|this|these|those|each|both|files?)\b)*$/i;

/**
 * Is the text between a qualifier and a path token nothing but glue? Any other
 * word breaks adjacency — that is what keeps "full text of the section
 * beginning ## Scope in docs/a.md" out. One newline is allowed, optionally
 * followed by a list marker, so "these files:\n- path" still reads as adjacent.
 */
function glueOk(between) {
  if (between.length > GLUE_MAX) return false;
  const flattened = between.replace(/\n[ \t]*(?:[-*]|\d+\.)?[ \t]*/, " ");
  if (flattened.includes("\n")) return false;
  return GLUE_WORDS.test(flattened);
}

function pathTokens(text) {
  PATH_TOKEN.lastIndex = 0;
  const out = [];
  let m;
  while ((m = PATH_TOKEN.exec(text)) !== null) {
    out.push({ start: m.index, end: m.index + m[0].length, text: m[1] });
  }
  return out;
}

/** Is [start,end) inside a `…` or "…" span? Quotes are paired left to right. */
function quoted(text, start, end) {
  for (const q of ["`", '"']) {
    let open = -1;
    for (let i = 0; i < text.length; i++) {
      if (text[i] !== q) continue;
      if (open < 0) open = i;
      else {
        if (start > open && end <= i) return true;
        open = -1;
      }
    }
  }
  return false;
}

function mentioned(text, index, end) {
  const before = text.slice(Math.max(0, index - GUARD_WINDOW), index);
  return NEGATION.test(before) || META.test(before) || quoted(text, index, end);
}

// The object is the discriminator, never the word "verbatim": 70% of real
// gopher orders contain it and mean "don't paraphrase" (spec 0001 §2).
const H1_QUALIFIERS = [
  /\b(full|entire|whole|complete)\b,?(?:\s+\w+){0,2}\s+(file|files|contents?|text|source)\b/gi,
  /\b(full|entire|whole|complete)\b[^.\n]{0,20}\bcontents?\s+of\b/gi,
];
/**
 * Path-first accepts only a TERMINAL whole-file qualifier. `verbatim` is not
 * one: it means "do not paraphrase", and 21 of r8's 33 false positives were
 * bounded excerpts and grep output that happened to say it after a path.
 * `full source` / `full text` / `complete text` stay qualifier-first only, and
 * a trailing `of` means the object is something inside the file, not the file.
 */
const H1_MIRROR =
  /\bin full\b|\bin (its )?entirety\b|\bentirely\b|\b(full|entire|whole|complete)\s+(file|files|contents?)\b(?!\s+of\b)/gi;
const READ_WHOLE = [/\bread\s+(the\s+)?(whole|entire|full)\s+(file|thing)\b/i, /\bin (its )?entirety\b/i];

/**
 * The order names a file but the object is not the file: a search filters it, a
 * listing names it, and "read it in full and report back compactly" asks for a
 * distillation. `report` alone is NOT a distil signal — "report back VERBATIM,
 * the entire file" is the order this gate exists for.
 */
const SEARCH_VERB = /\b(search|grep|scan|find)\b/i;
const LISTING_NOUN = /^.{0,3}\b(list|listing|names?|paths?|count|size|tree)\b/i;
const DISTIL = /\b(compact\w*|summar\w*|answer\w*)\b/i;

/** A distil word inside a filename (/tmp/rh-summary.log) is not a distil instruction. */
function blankPaths(s) {
  return s.replace(PATH_TOKEN, (m) => " ".repeat(m.length));
}

function targetGuarded(text, start, end) {
  if (SEARCH_VERB.test(text.slice(Math.max(0, start - 40), start))) return true;
  if (LISTING_NOUN.test(text.slice(end, end + 20))) return true;
  if (DISTIL.test(blankPaths(text.slice(end, end + 60)))) return true;
  return false;
}

/** Qualifier-first: the qualifier names the object, the path follows through glue. */
function pathAdjacent(text, paths, start, end) {
  return paths.some((p) => p.start >= end && glueOk(text.slice(end, p.start)));
}

/** H3 names a range, and a range reads the same on either side of its file. */
function pathEitherSide(text, paths, start, end) {
  return paths.some(
    (p) =>
      (p.start >= end && glueOk(text.slice(end, p.start))) ||
      (p.end <= start && glueOk(text.slice(p.end, start))),
  );
}

function pathBefore(text, paths, start) {
  return paths.some((p) => p.end <= start && glueOk(text.slice(p.end, start)));
}

const RANGE_TOOLS = [
  { re: /sed\s+-n\s+'?(\d+),(\d+)p'?/gi, span: (m) => Number(m[2]) - Number(m[1]) + 1 },
  { re: /head\s+(?:-n\s*|-)(\d+)/gi, span: (m) => Number(m[1]) },
  { re: /tail\s+(?:-n\s*|-)(\d+)/gi, span: (m) => Number(m[1]) },
];
const LINES_RANGE = /lines?\s+(\d+)\s*(?:-|–|—|to|through)\s*(\d+)/gi;
const READ_CALL = /Read\(([^)]*)\)/gi;

/** Only flags and whitespace may sit between the tool and its file. */
const TOOL_ARG_SKIP = /^(?:\s|-{1,2}\w+\s*)*/;

/**
 * A shell filter reads a stream, not a file, and a redirect sends the bytes to
 * disk instead of into the runner's context. Either way nothing is handed back.
 */
function pipedOrRedirected(text, toolStart, pathEnd) {
  const lineStart = text.lastIndexOf("\n", toolStart - 1) + 1;
  const before = text.slice(Math.max(lineStart, toolStart - 40), toolStart);
  let after = text.slice(pathEnd, pathEnd + 20);
  const nl = after.indexOf("\n");
  if (nl >= 0) after = after.slice(0, nl);
  return before.includes("|") || after.includes("|") || after.includes(">");
}

function h3Hit(text, paths) {
  for (const { re, span } of RANGE_TOOLS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      const end = m.index + m[0].length;
      const skip = TOOL_ARG_SKIP.exec(text.slice(end))[0].length;
      const p = paths.find((t) => t.start === end + skip);
      if (!p) continue;
      if (pipedOrRedirected(text, m.index, p.end)) continue;
      if (span(m) >= LARGE_RANGE_LINES) return m[0];
    }
  }
  READ_CALL.lastIndex = 0;
  let r;
  while ((r = READ_CALL.exec(text)) !== null) {
    const limit = /limit\D*(\d+)/i.exec(r[1]);
    if (!limit || Number(limit[1]) < LARGE_RANGE_LINES) continue;
    if (paths.some((p) => p.start > r.index && p.end < r.index + r[0].length)) return r[0];
  }
  LINES_RANGE.lastIndex = 0;
  let l;
  while ((l = LINES_RANGE.exec(text)) !== null) {
    if (Number(l[2]) - Number(l[1]) + 1 < LARGE_RANGE_LINES) continue;
    if (pathEitherSide(text, paths, l.index, l.index + l[0].length)) return l[0];
  }
  return null;
}

/**
 * Does this dispatch prompt order the runner to hand back a file whole?
 * Returns null, or {rule, text} where rule is "H1" (a whole-file qualifier
 * naming an explicit path), "H2" (read-the-whole-thing) or "H3" (a range tool
 * applied directly to a path, LARGE_RANGE_LINES or more).
 *
 * r8 NARROW (user ruling): deny only when the order names an explicit file AND
 * asks for it whole in the same breath. Whole-file orders whose path sits
 * further off are accepted misses — see spec 0001 §2 and §6 case 14.
 */
export function verbatimReadHit(prompt) {
  if (typeof prompt !== "string" || !prompt) return null;
  const paths = pathTokens(prompt);

  for (const re of H1_QUALIFIERS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(prompt)) !== null) {
      const end = m.index + m[0].length;
      if (mentioned(prompt, m.index, end)) continue;
      if (targetGuarded(prompt, m.index, end)) continue;
      if (pathAdjacent(prompt, paths, m.index, end)) return { rule: "H1", text: m[0] };
    }
  }
  H1_MIRROR.lastIndex = 0;
  let mm;
  while ((mm = H1_MIRROR.exec(prompt)) !== null) {
    const end = mm.index + mm[0].length;
    if (mentioned(prompt, mm.index, end)) continue;
    if (targetGuarded(prompt, mm.index, end)) continue;
    if (pathBefore(prompt, paths, mm.index)) return { rule: "H1", text: mm[0] };
  }

  for (const re of READ_WHOLE) {
    const m = re.exec(prompt);
    if (m && !mentioned(prompt, m.index, m.index + m[0].length)) return { rule: "H2", text: m[0] };
  }

  const h3 = h3Hit(prompt, paths);
  if (h3) return { rule: "H3", text: h3 };
  return null;
}

/**
 * Denial for a verbatim hand-back order. States the cost argument once so the
 * dispatcher learns the rule rather than rewording the order: there is no retry
 * pass, so the only ways forward are a narrower order or a direct Read.
 */
export function verbatimDenyMessage(prompt, hit) {
  const first = pathTokens(typeof prompt === "string" ? prompt : "")[0];
  const path = first ? first.text : "<path>";
  return (
    `task-gopher: this order asks the runner to hand a file back whole (matched: \`${hit.text}\`). ` +
    `That costs MORE than reading it yourself: Haiku reads it (input), re-emits it (output), and you read it again (input) — ` +
    `three times the bytes plus a dispatch. Read(${path}[, offset, limit]) directly. ` +
    `Dispatch gopher only when the answer is SMALLER than the source: grep → file:line + a few lines of context, the one function, ` +
    `a summary, a count, the first N matches. Rewrite the order that way, or read the file yourself; ` +
    `this dispatch will not be allowed as written.`
  );
}

/**
 * Marker the relay gate looks for at the top of Agent dispatch prompts, to tell
 * an already-stamped dispatch from one that still needs the directive. Both
 * directive texts open with it.
 */
export const SENTINEL = "[task-gopher: ON]";

/** Full directive — injected at SessionStart (and re-injected post-compaction). */
export const FULL_DIRECTIVE = [
  "[task-gopher: ON] TIER GATE — read first: this directive is for Sonnet-tier models and above (Sonnet, Opus, and the Mythos-class Fable/Mythos). If YOU are a Haiku-tier model, IGNORE everything below and just do the work yourself — you are the cheap runner, not the expensive reasoner this optimizes for. This is also what stops a task-gopher (Haiku) runner from dispatching to task-gopher and recursing. Likewise if you have NO Agent/Task tool: you cannot dispatch, so ignore this directive and simply work efficiently. Otherwise, if you are Sonnet-tier or higher, follow the rest — and note it applies whether you are the top-level agent or a subagent: any capable reasoner should push cheap legwork down to Haiku.",
  "",
  "Dispatch expensive tool work to the `task-gopher` subagent (pinned to Haiku) instead of doing it yourself. Spend YOUR expensive high-reasoning tokens on judgment, not on tool output or log dumps. task-gopher is a hired runner that carries out explicit orders and reports back.",
  "",
  'Dispatch with the Agent tool, subagent_type: "task-gopher:task-gopher" — plugin agents are namespaced `plugin:agent`, and the bare name does NOT resolve ("Agent type \'task-gopher\' not found"). If your available-agents list shows a different exact spelling, use that. Dispatch when a step is:',
  "- Tool/output-heavy: running test suites, builds, installs, long or verbose bash; sifting logs.",
  '- Retrieval / summarization: "find where X is defined", "list the callers", "summarize module Y", reading many files, searching a large tree.',
  "- Long-running or high-output, or otherwise likely to dump lots of tokens into your context.",
  "",
  "Keep for yourself: ALL reasoning — design decisions, correctness/security judgment, tradeoffs, and writing/editing code. For a task that needs reasoning, SPLIT it: have `task-gopher` gather the raw material or run the step and return a compact report, then you reason over the report.",
  "",
  'Decision rule (apply fast, do not overthink it): "Would doing this myself flood my context, OR is it a mechanical task I can specify exactly? -> dispatch it. Does it need MY judgment? -> keep the judgment, dispatch only the legwork." When unsure whether a step needs reasoning, keep it.',
  "",
  "This is a DEFAULT, not a preference you re-decide per step. The failure mode to avoid: talking yourself out of it one step at a time — \"this single read / grep / diff is quick enough to just do myself.\" Individually small retrievals are EXACTLY what floods your context in aggregate, and \"it's quick\" is not a reason to keep it. The trigger is the KIND of work (reading files, grepping, diffing, running commands), not the size of any one step. If you notice you are about to run a Read/Grep/Glob/Bash retrieval directly, treat that as the signal to dispatch instead.",
  "",
  'Batch, do not skip: when you have several small retrieval steps (read these 3 files, grep for X, diff against main), bundle them into ONE task-gopher order rather than doing them inline because each looks trivial. One dispatch with a clear spec returns one compact report — that is cheaper than both doing them yourself AND than many tiny dispatches.',
  "",
  "Reserve doing it yourself for: work that needs YOUR judgment, or a genuinely singular trivial peek where a dispatch would plainly cost more than the step (e.g. re-reading one short file already partly in your context). Everything else in the retrieval/tool-heavy category is a dispatch by default.",
  "",
  'Dispatch must COMPRESS. task-gopher earns its keep only when its report is SMALLER than the raw material it reads — it reads a lot and returns a little. So NEVER order it to read a whole file (or several) and hand the contents back verbatim: that returns just as many tokens to your context, with an extra hop and no saving. If you genuinely need a full file in front of you, read it yourself. Otherwise NARROW the ask — have gopher grep/search and return only the matching file:line plus a little context, the one function or section you care about, a direct answer, or a summary. Ask "where is X handled, and what does that code look like?", not "send me all of foo.ts." Rule of thumb: if you cannot name a compact expected output that is smaller than the source, either narrow the question or do it yourself — do not dispatch. A PreToolUse gate denies any gopher order that asks for a whole file or a ≥ 80-line range back — no retry passes; narrow the order or Read it yourself.',
  "",
  "Skill/command overrides win: if an active skill or command explicitly mandates a DIFFERENT subagent for a class of work (e.g. a GitHub worker that owns the MCP connection), follow that — it is a deliberate override, not a violation of this directive. Absent such an override, task-gopher is the default for tool-heavy and info-gathering work.",
  "",
  '`task-gopher` is a PURE task-runner: it never reasons, decides, or fills gaps, and it makes no design/correctness/security calls. It will STOP and report back if an order is ambiguous rather than guess. So the burden is on YOU to hand down COMPLETE orders — the exact task, and the exact expected result / compact output you want back (e.g. "run `npm test`, report only the FAIL lines and the exit code"; "just the file:line and the function signature"). Never dispatch a step that would require the runner to make a choice. It cannot see your context — every order must be self-contained.',
  "",
  'TWO RUNNERS — PICK ONE, LEAST-PRIVILEGED FIRST. `task-gopher` (Haiku) runs orders you can fully specify — it is the default, always try it first. `smart-gopher` (Sonnet, subagent_type "task-gopher:smart-gopher") is the escalation target for delegated work that genuinely needs judgment: which of several plausible files or call sites is the right one, reconciling evidence that disagrees across a tree, a summary that needs an editorial cut ("what is actually wrong with this module"), or a multi-step task whose later steps depend on what the earlier ones find. Reach for it at exactly two moments: when you are about to do tool-heavy work YOURSELF only because you cannot write a decision-free order for it, and when task-gopher has already STOPPED on a gap that is a judgment call rather than a missing fact. It is NOT a general upgrade — it spends Sonnet tokens, so anything you can specify exactly still goes to task-gopher, and a gap that is merely an underspecified order should be re-dispatched to task-gopher with the gap filled in. It is also NOT a way to offload YOUR decisions: design, architecture, correctness, security and scope stay with you. smart-gopher returns a reasoned compact report and hands any such call back, the same way task-gopher hands back a gap. It cannot dispatch subagents, so it is the end of the chain. Each DISTINCT smart-gopher dispatch is checkpointed once — a one-time nudge to confirm task-gopher genuinely could not do it — before the identical retry proceeds; this does not require strict mode. It checkpoints per exact request, not once per session: re-running the SAME prompt passes for good, but any OTHER smart-gopher dispatch, even later in the same session, gets its own fresh checkpoint.',
  "",
  "ORDER CONTRACT — every dispatch prompt must spell out all four of these, because the runner sees nothing but the prompt and will not fill gaps (worse: it may not NOTICE a gap — it will run the order literally, wherever and however it happens to land):",
  "- WHERE: absolute paths/cwd, and for any git-touching work the exact repo and branch/ref. An order that assumes \"the branch we're on\" runs on whatever is checked out in the runner's cwd. Name the branch and the runner verifies it before running; leave it out and nobody checks anything.",
  '- HOW: the exact method — commands, search patterns, files — not just the goal. "Find where X is defined" invites improvisation; "run `grep -rn \'class X\' src/`, report every file:line" does not. If a step could be done more than one way and the difference matters, make the choice in the order.',
  '- WHAT BACK: the exact report — format, size bound, and the completeness bar. Say explicitly whether you need EVERY match or only the first N: "compact" without a stated completeness bar is exactly how silently truncated reports happen.',
  "- WHAT IF: what to do on failure or an empty result — almost always \"report the exact error/empty outcome and stop\". Never leave it free to try an alternative method uninvited.",
  "If you cannot fill in all four, the step still contains a judgment call — resolve it yourself FIRST, then dispatch. Handing Haiku an order with room for judgment does not delegate the judgment; it randomizes it.",
  "",
  'DESTRUCTIVE AND OUTWARD-FACING WORK IS NOT THE RUNNER\'S. A PreToolUse guard intercepts any Bash stage from EITHER runner (task-gopher or smart-gopher) that destroys local state (`rm -rf`, `git reset --hard`, `git clean -fd`, `git worktree remove`, `git branch -D`, `git rebase`, `git restore`, `docker`/`kubectl`/`terraform` teardown, in-place `sed -i`) or that leaves the machine (`git push`, `gh pr`/`release` writes, `npm publish`, `curl -X POST`), and asks THE USER to approve it. Neither the runner nor you can consent on their behalf, so do not plan around the prompt: assume a person will be interrupted and decide. If you believe a specific destructive command is right, you may state so with a line reading "ALLOW-DESTRUCTIVE: <the exact command>" in the dispatch prompt — that is a recommendation shown to the user in the prompt, NOT a bypass, and it becomes the release only where no one can be asked (unattended runs). Prefer running destructive steps yourself over authorizing them. smart-gopher is guarded identically — its extra reasoning does not buy it any more authority over irreversible or outward-facing work.',
  "",
  "Escape hatch: if `task-gopher` returns incomplete, wrong, or insufficient information, or reports it could not proceed (usually because an order needed a decision), you MAY do it yourself or re-dispatch ONCE with a sharper, fully-specified order. Do not ping-pong more than about once before taking it over — a stalled dispatch costs more than just doing it.",
  "",
  "Relay is automatic — do NOT copy this directive into subagent prompts yourself. Subagents do not inherit it, so a PreToolUse hook stamps it onto dispatch prompts in flight, skipping the ones that would be wasted: either gopher (neither dispatches onward), and any agent whose tool list gives it no Agent/Task tool to dispatch with. Writing it out by hand would just spend your own output tokens on something the harness already did.",
].join("\n");

/** Compact per-turn reminder — injected at UserPromptSubmit to keep the behavior alive. */
export const SHORT_REMINDER =
  "[task-gopher: ON] If you are Sonnet-tier or higher (any agent, top-level or subagent): by DEFAULT dispatch tool-heavy and info-gathering steps to the `task-gopher` (haiku) runner with complete, decision-free orders, and keep reasoning for yourself. A complete order names WHERE (paths, branch for git work), HOW (exact commands/method), WHAT BACK (format + every-match-or-first-N completeness), and WHAT IF (on failure: report and stop) — the runner fills no gaps and may not notice them. Don't do small reads/greps/diffs inline because they seem quick — batch them into one order; that per-step rationalization is the failure mode. Order NARROW queries (grep/answer/summary that come back smaller than the source), never \"read the whole file and send it back\" — if you need a full file, read it yourself. If an order genuinely cannot be made decision-free — which of several files, a summary needing an editorial cut, steps that depend on what earlier steps find — dispatch `task-gopher:smart-gopher` (Sonnet, reasons but cannot dispatch onward) rather than doing it yourself; design and security calls still stay with you. task-gopher is the default — always the least-privileged option that could do the job. Each distinct smart-gopher dispatch is checkpointed once with a nudge to confirm task-gopher couldn't do it; re-run the identical prompt to proceed for good, but any other smart-gopher dispatch gets its own fresh checkpoint even later in the same session. If you are Haiku-tier or have no Agent tool, ignore this. Destructive and outward-facing commands (rm -rf, git reset --hard/clean/worktree remove/branch -D/rebase, push, publish, PR writes, infra teardown) from the runner are intercepted by a guard that asks THE USER to approve them — you cannot consent for them, so prefer doing those steps yourself rather than dispatching them. Escape hatch: take it over if the runner fails or returns too little. Don't copy this directive into subagent prompts — a hook stamps it onto the dispatches that can use it automatically. A PreToolUse gate denies any gopher order that asks for a whole file or a ≥ 80-line range back — no retry passes; narrow the order or Read it yourself.";
