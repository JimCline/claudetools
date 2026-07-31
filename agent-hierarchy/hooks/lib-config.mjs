#!/usr/bin/env node
/**
 * agent-hierarchy — config resolution + injected directive text.
 *
 * Two config scopes, both plain JSON at `.claude/agent-hierarchy.json`:
 *   - user:    ~/.claude/agent-hierarchy.json          (all repos)
 *   - project: <cwd>/.claude/agent-hierarchy.json      (committable)
 *
 * Resolution rules (from the design spec):
 *   - Merge is SHALLOW per role: a role object present in the project config
 *     replaces the user-scope role object entirely — no key-level deep merge.
 *   - `enabled`: most-specific scope wins (project overrides user).
 *   - `inherit` is a legal CONFIG value meaning "omit the `model` parameter on
 *     the Agent call". It is never emitted as a literal model value.
 *   - Invalid model → fall back to the role default + a one-line warning.
 *   - Missing `version` → treat as 1. A version newer than this plugin
 *     understands → that scope is ignored (with a note); if nothing valid is
 *     left, the session is treated as unconfigured.
 *
 * Run directly (`node lib-config.mjs`) to print the resolved status table for
 * the current working directory — that is what `/hierarchy status` uses.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

/** Config schema version this plugin understands. */
export const CONFIG_VERSION = 1;

/** Selectable roles, in display order. Orchestrator is the session agent and is not configurable. */
export const ROLES = ["ultra-advisor", "architect", "reviewer", "implementor", "task-runner"];

export const ROLE_LABELS = {
  "ultra-advisor": "Ultra-Advisor",
  architect: "Architect",
  reviewer: "Reviewer",
  implementor: "Implementor",
  "task-runner": "Task-Runner",
};

/** Shipped defaults — these mirror the agent-file frontmatter (implementor has no `model:` key). */
export const ROLE_DEFAULTS = {
  "ultra-advisor": { model: "fable" },
  architect: { model: "opus" },
  reviewer: { model: "sonnet" },
  implementor: { model: "inherit" },
  "task-runner": { model: "haiku", delegate: "task-gopher" },
};

/**
 * Accepted model values, per role. `inherit` is accepted here and converted at
 * render time into "omit the model parameter" — it is NOT a legal Agent-tool
 * value and must never be passed through literally.
 *
 * Architect, Reviewer, and Implementor are REASONING roles: haiku is never
 * valid for them — a Haiku-tier model cannot carry design, review, or
 * implementation judgment. Only Task-Runner (legwork, no reasoning) may run
 * on haiku.
 *
 * Ultra-Advisor is the escalation apex: it exists only to bring MORE reasoning
 * than the Architect already applied, so it takes top-tier models only and
 * never `inherit` — inheriting a Sonnet session would make the tier
 * decorative, which is the same argument that keeps haiku out of the
 * reasoning roles. Its model is always explicit.
 */
export const REASONING_MODELS = ["opus", "sonnet", "fable", "inherit"];
export const TOP_TIER_MODELS = ["fable", "opus"];
export const VALID_MODELS_BY_ROLE = {
  "ultra-advisor": TOP_TIER_MODELS,
  architect: REASONING_MODELS,
  reviewer: REASONING_MODELS,
  implementor: REASONING_MODELS,
  "task-runner": [...REASONING_MODELS, "haiku"],
};

export const CONFIG_BASENAME = "agent-hierarchy.json";

/**
 * Flow control: who advances the chain. `auto` (default) — the Orchestrator
 * performs handoffs itself and reports. `confirm` — the Orchestrator asks the
 * user before each reasoning-role dispatch, so every handoff is a decision the
 * user makes. Legwork dispatches (Task-Runner / task-gopher) are exempt in
 * both modes: errands are not handoffs.
 */
export const HANDOFF_MODES = ["auto", "confirm"];

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
 * True for any subagent session. The spec calls out two cases — an
 * `agent-hierarchy:*` agent type (hard recursion suppression, since subagents
 * can nest up to three layers) and any other agent type (a foreign subagent,
 * e.g. `task-gopher:task-gopher`) — and both suppress every injection, so a
 * single non-empty-agent_type test covers them.
 */
export function isSubagent(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.length > 0;
}

export function userConfigPath() {
  return join(homedir(), ".claude", CONFIG_BASENAME);
}

export function projectConfigPath(cwd) {
  if (typeof cwd !== "string" || !cwd) return null;
  return join(resolve(cwd), ".claude", CONFIG_BASENAME);
}

/** Load one scope. Returns null when absent/unreadable/not an object. */
function loadScope(path, scope, warnings) {
  if (!path || !existsSync(path)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    warnings.push(`agent-hierarchy: ${scope}-scope config at ${path} is not valid JSON — ignoring it.`);
    return null;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    warnings.push(`agent-hierarchy: ${scope}-scope config at ${path} is not a JSON object — ignoring it.`);
    return null;
  }
  const version = data.version === undefined ? CONFIG_VERSION : data.version;
  if (!Number.isInteger(version) || version > CONFIG_VERSION) {
    warnings.push(
      `agent-hierarchy: ${scope}-scope config at ${path} declares version ${JSON.stringify(data.version)}, which this plugin (v${CONFIG_VERSION}) does not understand — ignoring it.`
    );
    return null;
  }
  return { scope, path, data };
}

/**
 * Resolve the effective hierarchy for a session.
 *
 * @returns {{configured: boolean, enabled: boolean, roles: object, sources: object,
 *            shadowed: string[], layers: object[], warnings: string[]}}
 */
export function resolveConfig(cwd) {
  const warnings = [];
  const userPath = userConfigPath();
  const projectPath = projectConfigPath(cwd);
  const user = loadScope(userPath, "user", warnings);
  // When the session's cwd IS the home directory the two scopes are the same
  // file; loading it twice would report every role as shadowed by itself.
  const project = projectPath === userPath ? null : loadScope(projectPath, "project", warnings);

  // Least specific first: project layers are applied last so they win.
  const layers = [user, project].filter(Boolean);

  const roles = {};
  const sources = {};
  for (const role of ROLES) {
    roles[role] = { ...ROLE_DEFAULTS[role] };
    sources[role] = "default";
  }

  if (layers.length === 0) {
    return {
      configured: false,
      enabled: true,
      handoffs: "auto",
      handoffsSource: "default",
      roles,
      sources,
      shadowed: [],
      layers,
      warnings,
    };
  }

  let enabled = true;
  for (const layer of layers) {
    if (typeof layer.data.enabled === "boolean") enabled = layer.data.enabled;
  }

  // Most-specific scope wins, same rule as `enabled`.
  let handoffs = "auto";
  let handoffsSource = "default";
  for (const layer of layers) {
    if (typeof layer.data.handoffs === "string") {
      handoffs = layer.data.handoffs;
      handoffsSource = layer.scope;
    }
  }
  if (!HANDOFF_MODES.includes(handoffs)) {
    warnings.push(
      `agent-hierarchy: handoffs ${JSON.stringify(handoffs)} is not a mode (allowed: ${HANDOFF_MODES.join(", ")}) — using "auto".`
    );
    handoffs = "auto";
    handoffsSource = "default";
  }

  const definedBy = {};
  for (const layer of layers) {
    const layerRoles = layer.data.roles;
    if (!layerRoles || typeof layerRoles !== "object" || Array.isArray(layerRoles)) continue;
    for (const role of ROLES) {
      const entry = layerRoles[role];
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
      // Shallow replacement: the whole role object is swapped, not merged key-by-key.
      roles[role] = { ...entry };
      sources[role] = layer.scope;
      (definedBy[role] ||= []).push(layer.scope);
    }
  }

  // A user-scope role value that a project config also defines is shadowed.
  const shadowed = ROLES.filter((role) => (definedBy[role] || []).length > 1);

  for (const role of ROLES) {
    const model = roles[role].model;
    const valid = VALID_MODELS_BY_ROLE[role];
    if (typeof model !== "string" || !valid.includes(model)) {
      warnings.push(
        `agent-hierarchy: model ${JSON.stringify(model)} is not allowed for role "${role}" (allowed: ${valid.join(", ")}) — using the default "${ROLE_DEFAULTS[role].model}".`
      );
      roles[role] = { ...roles[role], model: ROLE_DEFAULTS[role].model };
    }
  }

  return { configured: true, enabled, handoffs, handoffsSource, roles, sources, shadowed, layers, warnings };
}

/** The subagent_type to dispatch for a role, honouring task-runner's `delegate`. */
export function subagentType(role, entry) {
  if (role === "task-runner" && entry && entry.delegate === "task-gopher") {
    return "task-gopher:task-gopher";
  }
  return `agent-hierarchy:${role}`;
}

/** One dispatch line per role. `inherit` renders as "omit the parameter", never as a value. */
function roleLines(roles) {
  return ROLES.map((role) => {
    const entry = roles[role];
    const type = subagentType(role, entry);
    if (entry.model === "inherit") {
      return `- ${ROLE_LABELS[role]} — Agent(subagent_type:"${type}") — OMIT \`model\` entirely (inherits this session's model). Never pass "inherit" as a value.`;
    }
    return `- ${ROLE_LABELS[role]} — Agent(subagent_type:"${type}", model:"${entry.model}")`;
  });
}

/** The full SessionStart injection for a configured, enabled session. */
export function buildDirective(resolved) {
  const confirm = resolved.handoffs === "confirm";
  const lines = [
    "Agent hierarchy ACTIVE. You are the Orchestrator: decompose, dispatch, synthesize — do not design or implement non-trivial changes yourself.",
    "",
    "Roles (pass `model` on the Agent call; agent frontmatter is only a fallback):",
    ...roleLines(resolved.roles),
    "",
    "Protocol (hard default, not a preference):",
    ...(confirm
      ? [
          '0. Handoff gate — the user chose to approve each handoff (config handoffs:"confirm"). Before dispatching Ultra-Advisor, Architect, Implementor, or Reviewer — including review-loop re-dispatches — call AskUserQuestion first: name the role, its model, and one line on what you will hand it; offer "Dispatch <role> (Recommended)", "Do it inline yourself", and "Skip this step". Ask per dispatch, not per plan, and never re-ask for a dispatch the user already approved. Legwork (Task-Runner / task-gopher) is exempt — errands are not handoffs. "Do it inline" means you take that role\'s contract on yourself for that step; "Skip" means the step does not happen and you say plainly what that leaves undesigned or unverified.',
        ]
      : []),
    "1. Gate: binds the top-level Orchestrator only. Role agents never spawn ultra-advisor/architect/reviewer/implementor. They MAY dispatch task-gopher for legwork — that is not recursion.",
    "2. Scope: the chain governs changes. Analysis, debugging, and research go to Architect (design reasoning) or Task-Runner (retrieval) alone — no Reviewer without a diff.",
    "3. Tiers: trivial (one blind Edit, no verification — typo, config value) → do it yourself. Determined (the request fixes the spec; no design choices left) → Implementor, then Reviewer. Everything else → Architect → spec → Implementor → Reviewer, with Ultra-Advisor inserted ahead of the Architect when one of item 7's triggers fires.",
    "4. Spec handoff: generate one unique absolute spec path (scratchpad dir + task slug), dictate it in the Architect's prompt, and give the same path to Implementor and Reviewer. Dispatches are self-contained — subagents share no context.",
    "5. Living spec: if the Implementor reports a spec gap or a deviation is agreed, amend the spec file (yourself, or re-dispatch the Architect for design questions) BEFORE the Reviewer runs. The Reviewer always validates against the current spec.",
    "6. Review loop: the Reviewer classifies each finding impl-defect or spec-defect. Impl-defects go back to the Implementor, spec-defects to the Architect. Max 2 round-trips; if findings are still open after that, escalate to Ultra-Advisor rather than looping again, then surface its verdict to the user.",
    "7. Ultra-Advisor — escalation apex, never a routine step. It reasons and adjudicates; it never implements. Dispatch it ONLY when: the user says the problem is hard, important, or high-stakes, or asks for a second opinion; the Architect reports low confidence or a fork it could not resolve; the review loop hits its cap in item 6; or the change carries outsized blast radius (security, auth, data migration, concurrency, a public interface, anything hard to reverse). Give it the same absolute spec path plus the specific question. Its answer is authoritative: fold it into the spec before the Implementor runs again. Do not escalate merely because a task feels large — size is the Architect's job.",
    "8. Task-Runner: prefer `task-gopher:task-gopher`; if that agent type is unavailable use `agent-hierarchy:task-runner`. task-gopher's on/off toggle controls only its directive, not the agent — delegation works either way.",
    "9. Skills and commands override: a skill mandating a different flow (tdd, diagnose, review) wins over this protocol for its scope.",
    `10. Flow control — handoffs are currently "${resolved.handoffs}"${confirm ? " (ask before each reasoning-role dispatch, per item 0)" : " (you advance the chain yourself and report)"}. The user owns this switch and may flip it AT ANY TIME, in either direction, just by telling you — "ask me before handoffs", "stop asking", or /hierarchy flow auto|confirm. When they do: update the "handoffs" key in the most specific agent-hierarchy.json that exists (project if present, else user) with the Write tool, preserving every other key; confirm the change in one line; and honor the new mode immediately for the rest of this session — do not wait for a restart.`,
    "11. Evidence loop — YOU keep the roles in their lanes. The Architect reasons and designs; it never executes — no tests, builds, or experiments, direct or via a runner (Bash is denied to it). (a) Dispatch it with design questions only: never fold \"and verify it works\" into an Architect prompt. (b) When its report or spec carries NEEDS-EVIDENCE items, route that gruntwork to the Implementor (write/run/measure, at implementation rates; Task-Runner for a pure run-and-report), then re-dispatch the Architect with the results and the same spec path. (c) If any role's report shows it did another role's work — an Architect that ran tests, an Implementor that redesigned — do not accept that part: note the overstep, and route the work to the role that owns it. Design-tier tokens buy judgment, not gruntwork; enforcing that split is YOUR job, not the roles' goodwill.",
  ];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/** One-line setup nudge for an unconfigured top-level session. */
export function buildNudge(resolved) {
  const lines = ["agent-hierarchy is installed but not configured — run `/hierarchy init` to assign a model to each role."];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/** Human-readable resolved table for `/hierarchy status` and the wizard's echo. */
export function statusReport(cwd) {
  const resolved = resolveConfig(cwd);
  const out = [];
  const userPath = userConfigPath();
  const projectPath = projectConfigPath(cwd);
  const seen = Object.fromEntries(resolved.layers.map((l) => [l.scope, l.path]));

  out.push(`agent-hierarchy: ${!resolved.configured ? "NOT CONFIGURED" : resolved.enabled ? "ON" : "OFF (enabled:false)"}`);
  out.push(`user config:    ${seen.user || `${userPath} (none)`}`);
  out.push(`project config: ${seen.project || `${projectPath || "(unknown cwd)"} (none)`}`);
  out.push(
    `handoff flow:   ${resolved.handoffs} ${resolved.handoffs === "confirm" ? "(ask before each reasoning-role dispatch)" : "(automatic handoffs)"} — from ${resolved.handoffsSource}; switch anytime with /hierarchy flow or by asking the Orchestrator`
  );
  out.push("");
  out.push("Resolved effective table:");
  out.push(`  Orchestrator  ${"session model".padEnd(14)} fixed (this session's agent)`);
  for (const role of ROLES) {
    const entry = resolved.roles[role];
    const model = entry.model === "inherit" ? "inherit*" : entry.model;
    out.push(`  ${ROLE_LABELS[role].padEnd(13)} ${model.padEnd(14)} from ${resolved.sources[role].padEnd(8)} -> ${subagentType(role, entry)}`);
  }
  out.push("");
  out.push("* inherit = omit the `model` parameter on the Agent call (never pass \"inherit\").");
  if (resolved.shadowed.length) {
    out.push(`WARNING: project config shadows user-scope values for: ${resolved.shadowed.join(", ")}.`);
  }
  for (const warning of resolved.warnings) out.push(warning);
  out.push("Changes apply to this session now; other live sessions pick them up at their next start, clear, or compaction.");
  return out.join("\n");
}

// Run directly: print the status table for the current working directory.
if (process.argv[1] && resolve(process.argv[1]).endsWith("lib-config.mjs")) {
  process.stdout.write(statusReport(process.cwd()) + "\n");
}
