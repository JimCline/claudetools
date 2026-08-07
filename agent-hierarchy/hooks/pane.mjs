#!/usr/bin/env node
/**
 * agent-hierarchy — durable-agent helper CLI (/agent-hierarchy:durable).
 *
 *   node pane.mjs create --agent <name> --orient <right|below>
 *                        [--model <alias>] [--permission-mode <mode>]
 *                        [--cwd <dir>] [--session <id>] [--no-iterm] [--dry-run]
 *                        (`open` is the older synonym; both are accepted)
 *   node pane.mjs list  [--json]
 *   node pane.mjs send  --key <key> [--summary <text>] [--timeout <seconds>] [--boot-wait <seconds>]
 *   node pane.mjs peek  --key <key> [--lines <n>]
 *   node pane.mjs close --key <key> | --all [--session <id>]
 *   node pane.mjs doctor
 *
 * Exit 0 on success, 1 on a user-correctable error, 2 on a refusal.
 *
 * `send` reads the prompt from STDIN, never argv. That is the whole quoting
 * story: the caller heredocs the prompt in, and it goes straight to
 * `tmux load-buffer -`, so no prompt text ever crosses a shell word-splitting
 * boundary.
 *
 * All the mechanics live in lib-pane.mjs. This file is argument handling,
 * policy, and printing — the things a model generating one-off bash gets wrong
 * intermittently and silently belong in tested code, not in a command file.
 */

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { REASONING_MODELS, resolveConfig } from "./lib-config.mjs";
import {
  ARGV_PERMISSION_MODES,
  AGENT_RE,
  BUILTIN_AGENTS,
  KEY_RE,
  MAILBOX_ROOT,
  REGISTRY_PATH,
  MODEL_ALIASES,
  MODEL_RE,
  NO_PROMPT_ROLES,
  PERMISSION_MODE_NOTES,
  agentsTreeDivergence,
  appendRegistry,
  buildLaunchCommand,
  buildTmuxArgv,
  canExecute,
  capturePane,
  closedPaneGroupPids,
  compactRegistry,
  foldRegistry,
  isPaneLive,
  itermAvailable,
  itermSelfUuid,
  itermSplit,
  itermSplitScript,
  killPane,
  launchingKeys,
  mailboxDir,
  makeKey,
  openTmuxSession,
  orientationPhrase,
  paneLog,
  panesConfig,
  parseOrientation,
  readJsonFile,
  resolveAgent,
  roleOfAgent,
  sendPrompt,
  survivingGroupProcesses,
  tmuxAvailable,
  tmuxPath,
  tmuxSessionExists,
  verifyAndReapLive,
  writeJsonAtomic,
} from "./lib-pane.mjs";

const REASONING_ROLES = ["ultra-advisor", "architect", "reviewer", "implementor"];

/** How long `send` waits for the pane's session identity file before refusing to paste. */
const BOOT_WAIT_SECONDS = 30;

// ------------------------------------------------------------------ output

const out = [];
function say(line = "") {
  out.push(line);
}
function flush(code) {
  if (out.length) process.stdout.write(out.join("\n") + "\n");
  process.exit(code);
}
function refuse(message) {
  process.stderr.write(message.trimEnd() + "\n");
  process.exit(2);
}
function fail(message) {
  process.stderr.write(message.trimEnd() + "\n");
  process.exit(1);
}

// ------------------------------------------------------------------- argv

function parseArgs(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      positional.push(a);
      continue;
    }
    const name = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) flags[name] = true;
    else {
      flags[name] = next;
      i++;
    }
  }
  return { flags, positional };
}

// ------------------------------------------------------------------ config

/**
 * The `panes` block, layered project-over-user.
 *
 * Read straight from the config files the resolver already located, rather
 * than through `resolveConfig()`'s return value: /pane is a consumer of the
 * config and must not change the resolver's semantics or its shape.
 */
function readPanes(resolved) {
  const byScope = {};
  for (const layer of resolved.layers || []) {
    const data = readJsonFile(layer.path);
    if (data && typeof data.panes === "object") byScope[layer.scope] = data.panes;
  }
  return panesConfig({ ...(byScope.user || {}), ...(byScope.project || {}) });
}

function orchestratorId(flags) {
  const explicit = flags.session && flags.session !== true ? String(flags.session) : null;
  return explicit || process.env.AGENT_HIERARCHY_ORCH_SESSION || itermSelfUuid() || "nosess";
}

// -------------------------------------------------------------- resolution

function resolveModel(agent, role, flags, resolved) {
  if (flags.model && flags.model !== true) {
    const m = String(flags.model);
    if (!MODEL_ALIASES.includes(m) && !MODEL_RE.test(m)) {
      refuse(`Refusing to open a pane: --model "${m}" is not one of ${MODEL_ALIASES.join(", ")} or a claude-* model id.`);
    }
    return { model: m, source: "--model" };
  }
  if (role) {
    const entry = (resolved.roles || {})[role];
    const configured = entry && entry.model;
    // `inherit` means OMIT the flag. It is a legal config value, never a
    // legal --model value.
    if (configured && configured !== "inherit") return { model: configured, source: `config (${role})` };
    return { model: null, source: configured === "inherit" ? "inherit" : "definition default" };
  }
  return { model: null, source: "definition default" };
}

/**
 * Permission mode, and whether the user still has to be asked for one.
 *
 * `--permission-mode` at startup wins over settings AND over the agent
 * definition's own frontmatter, so this is the only place the decision is
 * made. The rule is: ask unless execution can be ruled out (§14.1a — the gate
 * fails safe, so `executable` is true for unreadable or unrestricted
 * definitions, and on divergence it is the OR over both copies). The four
 * reasoning/legwork roles are settled by policy and never asked; the
 * Implementor and any non-role agent whose toolset includes Bash or Edit are
 * always asked, because relaxing oversight for an agent nobody vetted is not
 * /pane's call to make silently.
 */
function resolvePermissionMode(role, executable, flags, panes) {
  if (flags["permission-mode"] && flags["permission-mode"] !== true) {
    const mode = String(flags["permission-mode"]);
    if (mode === "bypassPermissions") {
      refuse(
        "Refusing --permission-mode bypassPermissions from the command line: it disables every permission check.\n" +
          "It is available only via `panes.permissionMode` in ~/.claude/agent-hierarchy.json — a deliberate, persistent, reviewable choice."
      );
    }
    if (!ARGV_PERMISSION_MODES.includes(mode)) {
      refuse(`Refusing --permission-mode "${mode}": not one of ${ARGV_PERMISSION_MODES.join(", ")}.`);
    }
    return { mode, source: "--permission-mode", askUser: false };
  }
  if (panes.permissionMode) {
    return { mode: panes.permissionMode, source: "panes.permissionMode", askUser: false };
  }
  if (role && NO_PROMPT_ROLES.includes(role)) {
    return { mode: null, source: "role policy (normal prompting)", askUser: false };
  }
  if (executable) {
    return { mode: null, source: "unset", askUser: true };
  }
  return { mode: null, source: "read-only agent (normal prompting)", askUser: false };
}

function permissionLine(mode) {
  if (!mode) return "manual (normal prompting) — will stall if it hits a prompt with nobody attached";
  return `${mode} — ${PERMISSION_MODE_NOTES[mode] || "see the permission-modes reference"}`;
}

// ----------------------------------------------------------------- liveness

/** The verify-and-reap fold, shared with the SessionStart roster and the PreToolUse offer. */
function livePanes() {
  return verifyAndReapLive();
}

/** Accept an exact key, or an agent name when exactly one live pane runs it. */
function resolveTarget(live, target) {
  if (live.has(target)) return live.get(target);
  const matches = [...live.values()].filter((r) => r.agent === target);
  if (matches.length === 1) return matches[0];
  if (matches.length > 1) {
    fail(`"${target}" matches ${matches.length} live durable agents: ${matches.map((m) => m.key).join(", ")}. Name one by key.`);
  }
  fail(`no durable agent named "${target}". Run \`pane.mjs list\` to see what is running.`);
  return null;
}

/**
 * Splitting the Orchestrator's own iTerm2 session is fine; typing into it
 * never is. Both addresses it could be reached by are refused.
 */
function refuseSelfTarget(record) {
  if (process.env.TMUX && process.env.TMUX_PANE && record.pane_id === process.env.TMUX_PANE) {
    refuse(`Refusing: ${record.key} is this session's own pane (${record.pane_id}).`);
  }
  const self = itermSelfUuid();
  if (self && record.iterm_child_uuid && record.iterm_child_uuid === self) {
    refuse(`Refusing: ${record.key} is this session's own iTerm2 session.`);
  }
}

// --------------------------------------------------------------- open

function cmdOpen(flags, positional) {
  const agent = flags.agent && flags.agent !== true ? String(flags.agent) : positional[0];
  if (!agent) fail("create needs an agent: pane.mjs create --agent <name> --orient <right|below>");

  // The whitelist runs before anything else touches this value, because it is
  // interpolated into a command string tmux hands to `sh`.
  if (!AGENT_RE.test(agent)) {
    refuse(`Refusing agent name "${agent}": it must match ^[A-Za-z0-9_:-]{1,80}$.`);
  }

  const orientation = parseOrientation(flags.orient !== undefined ? flags.orient : positional[1]) || "right";
  const cwd = flags.cwd && flags.cwd !== true ? String(flags.cwd) : process.cwd();
  const dryRun = Boolean(flags["dry-run"]);
  const resolved = resolveConfig(cwd);
  const panes = readPanes(resolved);

  if (BUILTIN_AGENTS.includes(agent) && !panes.allowBuiltins) {
    refuse(
      `${agent} is a Claude Code built-in with no definition file on disk.\n` +
        "Durable agents are file-backed agents only, because the pane's restrictions\n" +
        "come from its definition. Use the Agent tool for built-ins."
    );
  }

  const found = resolveAgent(agent, cwd);
  const builtinAllowed = !found.ok && found.builtin && panes.allowBuiltins;
  if (!found.ok && !builtinAllowed) refuse(`Refusing to open a pane: ${found.error}`);

  // Every definition-derived policy below is the conservative union over all
  // copies on disk (§6.3a): an allowed built-in has no definition, so its one
  // "copy" is {} and §14.1a's fail-safe makes it execution-capable — which is
  // the correct outcome and must not be special-cased away.
  const frontmatters = builtinAllowed ? [{}] : found.frontmatters && found.frontmatters.length ? found.frontmatters : [found.frontmatter || {}];
  const executable = frontmatters.some((fm) => canExecute(fm));
  const role = roleOfAgent(agent);
  const warnings = [...(found.warnings || []), ...panes.warnings];

  const divergent = !builtinAllowed && found.definitionSource === "divergent";
  if (divergent && panes.onDefinitionDivergence === "refuse") {
    refuse(
      `Refusing to open a pane: two copies of ${agent} are on disk and they differ, and panes.onDefinitionDivergence is "refuse".\n` +
        `  live checkout   ${found.definitionPathLive}\n` +
        `  installed copy  ${found.definitionPath}\n` +
        `Resync with: /plugin marketplace update ${found.marketplace}`
    );
  }
  if (divergent) {
    warnings.push(
      `two copies of ${agent} are on disk and they differ.\n` +
        `  live checkout   ${found.definitionPathLive}\n` +
        `  installed copy  ${found.definitionPath}\n` +
        `${found.marketplace} is a local-path marketplace, so Claude Code may launch this pane from either copy. ` +
        `The permission and model policy was computed from BOTH, taking the stricter answer of each.\n` +
        `Resync with: /plugin marketplace update ${found.marketplace}`
    );
  }

  const { model, source: modelSource } = resolveModel(agent, role, flags, resolved);
  if (role && REASONING_ROLES.includes(role) && (model === "haiku" || /^claude-haiku/.test(model || ""))) {
    refuse(
      `Refusing to open a pane: ${role} resolves to haiku, and reasoning roles\n` +
        `run on ${REASONING_MODELS.filter((m) => m !== "inherit").join(", ")} only. Fix with /hierarchy set ${role} opus,\n` +
        "or pass an explicit --model."
    );
  }

  const perm = resolvePermissionMode(role, executable, flags, panes);
  if (perm.askUser && !dryRun) {
    fail(
      `This agent can execute — its toolset includes Bash or Edit, or its definition does not rule them out — so its permission mode is the user's call.\n` +
        `Ask the user which mode to open \`${agent}\` with, then re-run with --permission-mode <mode>:\n` +
        ARGV_PERMISSION_MODES.map((m) => `  ${m.padEnd(12)} ${PERMISSION_MODE_NOTES[m]}`).join("\n")
    );
  }

  if (frontmatters.some((fm) => fm.initialPrompt)) {
    warnings.push(
      `\`${agent}\` declares an \`initialPrompt\`, so the pane auto-submits a first turn the instant it opens. That turn is not relayed (no pending token yet), but it costs tokens and may leave the pane mid-work when your first real send arrives.`
    );
  }
  if (executable && !perm.mode) {
    warnings.push("This agent can edit files and run commands, so it will hit permission prompts, and nobody is attached to answer them. Keep the pane visible, or attach to it.");
  }
  if (perm.mode === "acceptEdits") {
    warnings.push("`acceptEdits` does not cover general Bash: this pane will still stall on a permission prompt when it runs tests or builds.");
  }
  if (perm.mode === "dontAsk") {
    warnings.push("`dontAsk` auto-DENIES anything that would have prompted. The pane never stalls, but un-preapproved Bash silently fails rather than running.");
  }
  if (!model) {
    warnings.push("model: (inherited — the pane will use your default model, not the Orchestrator's current one). Pass --model to pin it.");
  }

  if (!tmuxAvailable()) {
    fail("/pane needs tmux, which is not on your PATH.\n  macOS:  brew install tmux\n  Debian: sudo apt install tmux\nThen run /pane doctor.");
  }

  const key = makeKey(orchestratorId(flags), agent, new Set(foldRegistry().keys()));
  if (!key) fail("could not allocate a pane key — close some panes first.");
  const dir = mailboxDir(key);

  const useIterm = !flags["no-iterm"] && panes.iterm2 && itermAvailable();
  const selfUuid = itermSelfUuid();

  let command;
  let tmuxArgv;
  try {
    command = buildLaunchCommand({ agent, model, permissionMode: perm.mode });
    tmuxArgv = buildTmuxArgv({
      key,
      cwd,
      size: panes.size,
      env: {
        AGENT_HIERARCHY_PANE_ROLE: agent,
        AGENT_HIERARCHY_PANE_KEY: key,
        AGENT_HIERARCHY_PANE_DIR: dir,
      },
      command,
    });
  } catch (err) {
    refuse(`Refusing to open a pane: ${err.message}`);
  }

  const record = {
    ev: "open",
    key,
    agent,
    agent_source: builtinAllowed ? "builtin" : found.source,
    definition_path: builtinAllowed ? null : found.definitionPath,
    definition_path_live: builtinAllowed ? null : found.definitionPathLive || null,
    definition_source: builtinAllowed ? "builtin" : found.definitionSource || "recorded",
    install_path: builtinAllowed ? null : found.installPath || null,
    model: model || null,
    permission_mode: perm.mode || null,
    tmux_session: key,
    pane_id: null,
    pane_pid: null,
    cwd,
    orchestrator_session_id: orchestratorId(flags),
    orchestrator_iterm_uuid: selfUuid,
    iterm_child_uuid: null,
    orientation,
    created_at: new Date().toISOString(),
    dir,
  };

  if (dryRun) {
    say("DRY RUN — nothing was launched.");
    say("");
    say(`tmux ${tmuxArgv.map((a) => (/\s/.test(a) ? `'${a}'` : a)).join(" ")}`);
    say("");
    say(`launch command: ${command}`);
    say(`permission prompt required: ${perm.askUser ? "yes" : "no"} (source: ${perm.source})`);
    say(`orientation: ${orientation} (${orientationPhrase(orientation)})`);
    say("");
    say("registry record:");
    say(JSON.stringify(record, null, 2));
    say("");
    say("iTerm2 presentation split:");
    say(useIterm || selfUuid ? itermSplitScript(selfUuid || "DRYRUN-UUID", key, orientation) : itermSplitScript("DRYRUN-UUID", key, orientation));
    for (const w of warnings) say(`WARNING: ${w}`);
    flush(0);
  }

  mkdirSync(dir, { recursive: true });
  // A crash between here and the `open` event must not leave an untracked tmux
  // session (durable-agents §7 F2): `launching` marks the attempt, the `open`
  // event supersedes it, and doctor reaps keys stuck at `launching`.
  appendRegistry({ ev: "launching", key, agent, at: new Date().toISOString(), dir });
  const launched = openTmuxSession(tmuxArgv, key);
  if (!launched.ok) {
    appendRegistry({ ev: "close", key, at: new Date().toISOString(), reason: "launch-failed" });
    fail(`could not create the tmux session: ${launched.error}`);
  }
  record.pane_id = launched.paneId;
  record.pane_pid = launched.panePid;

  let itermNote = null;
  if (useIterm && selfUuid) {
    const split = itermSplit(selfUuid, key, orientation);
    if (split.ok) record.iterm_child_uuid = split.childUuid || null;
    else itermNote = `Pane opened (not shown — could not reach iTerm2: ${split.error}).`;
  } else if (!useIterm) {
    itermNote = "orientation ignored (no iTerm2 presentation layer)";
  }

  appendRegistry(record);
  compactRegistry();
  paneLog(dir, { ev: "opened", key, agent, model: model || null, permission_mode: perm.mode || null });

  // Scoped to iTerm2 splits from THIS window: without a self uuid the filter
  // would count every `null === null` record (durable-agents §7 F3).
  const liveCount = useIterm && selfUuid ? [...foldRegistry().values()].filter((r) => r.orchestrator_iterm_uuid === selfUuid).length : 0;

  say(`durable    ${key}`);
  say(`agent      ${agent}`);
  if (record.definition_source === "divergent") {
    say(`definition TWO COPIES DIFFER — policy computed from BOTH (stricter wins)`);
    say(`  live      ${record.definition_path_live}`);
    say(`  installed ${record.definition_path}`);
  } else if (record.definition_source === "live-only") {
    say(`definition ${record.definition_path_live}`);
  } else {
    say(`definition ${record.definition_path || "(built-in, no definition file)"}`);
  }
  say(`model      ${model || `(inherited — ${modelSource})`}`);
  say(`perms      ${permissionLine(perm.mode)}`);
  say(`where      ${itermNote || orientationPhrase(orientation)}  (tmux attach -t ${key})`);
  if (record.pane_pid) say(`process    pane ${record.pane_id}, pid ${record.pane_pid}`);
  for (const w of warnings) say(`WARNING: ${w}`);
  if (useIterm && liveCount >= 3) {
    say(`NOTE: this is durable agent ${liveCount} split off this window; the Orchestrator's pane is getting small — consider \`tmux attach -t ${key}\` in a separate window instead.`);
  }
  flush(0);
}

// ---------------------------------------------------------------- list

function cmdList(flags) {
  const live = livePanes();
  if (flags.json) {
    process.stdout.write(JSON.stringify({ panes: [...live.values()] }, null, 2) + "\n");
    process.exit(0);
  }
  if (!live.size) {
    say("no durable agents running.");
    flush(0);
  }
  for (const rec of live.values()) {
    const dir = rec.dir || mailboxDir(rec.key);
    const pending = readJsonFile(join(dir, "pending"));
    const unread = existsSync(dir)
      ? readdirSync(dir).filter((f) => /^reply\..*\.json$/.test(f)).length
      : 0;
    say(`${rec.key}`);
    say(`  agent      ${rec.agent}  (${rec.model || "inherited model"}, ${permissionLine(rec.permission_mode)})`);
    say(`  where      ${orientationPhrase(rec.orientation)}  (tmux attach -t ${rec.key})`);
    say(`  cwd        ${rec.cwd}`);
    say(`  state      ${pending ? `WORKING on ${pending.reqid} since ${pending.sent_at}` : "idle"}${unread ? `, ${unread} reply file(s) on disk` : ""}`);
    // Quiet in every non-divergent case (§6.3a): a warning printed for the
    // normal state stops being read.
    if (rec.definition_source === "divergent") {
      say(`  definition TWO COPIES DIFFER — policy computed from BOTH (stricter wins)`);
      say(`    live      ${rec.definition_path_live}`);
      say(`    installed ${rec.definition_path}`);
    }
  }
  flush(0);
}

// ---------------------------------------------------------------- send

async function cmdSend(flags, positional) {
  const target = flags.key && flags.key !== true ? String(flags.key) : positional[0];
  if (!target) fail("send needs a target: pane.mjs send --key <key|agent>   (prompt on stdin)");

  const live = livePanes();
  const record = resolveTarget(live, target);
  if (!KEY_RE.test(record.key)) refuse(`Refusing: "${record.key}" is not a /pane key.`);
  refuseSelfTarget(record);

  const dir = record.dir || mailboxDir(record.key);
  const resolved = resolveConfig(record.cwd || process.cwd());
  const panes = readPanes(resolved);
  const timeout = Number(flags.timeout) > 0 ? Number(flags.timeout) : panes.timeoutSeconds;

  const existing = readJsonFile(join(dir, "pending"));
  if (existing) {
    const age = Math.round((Date.now() - Date.parse(existing.sent_at || 0)) / 1000);
    fail(`durable agent ${record.key} is still working on request ${existing.reqid} (sent ${age}s ago). Wait, or run \`pane.mjs peek --key ${record.key}\`.`);
  }

  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const prompt = Buffer.concat(chunks).toString("utf8");
  if (!prompt.trim()) fail("send read an empty prompt from stdin.");

  const reqid = randomUUID();

  // Never paste into a session that has not booted (durable-agents §7 F1). The
  // identity file is written by the pane's own SessionStart; until it exists
  // the input box may not exist either — a paste now can be silently lost, and
  // `expect_session` would be null exactly when gate D matters most.
  const bootWait = flags["boot-wait"] !== undefined && Number(flags["boot-wait"]) >= 0 ? Number(flags["boot-wait"]) : BOOT_WAIT_SECONDS;
  let session = readJsonFile(join(dir, "session"));
  const bootDeadline = Date.now() + bootWait * 1000;
  while (!session && Date.now() < bootDeadline) {
    await sleep(1000);
    session = readJsonFile(join(dir, "session"));
  }
  if (!session) {
    fail(
      `${record.key} has not finished booting after ${bootWait}s — its session identity file is still missing.\n` +
        `Nothing was sent and no request is outstanding. Look at it, then retry:\n` +
        `  Peek:   pane.mjs peek --key ${record.key}\n` +
        `  Attach: tmux attach -t ${record.key}`
    );
  }
  const expectSession = typeof session.session_id === "string" ? session.session_id : null;
  const notes = [];
  if (!expectSession) notes.push("the durable agent recorded no session id; the agent_type gate still applies.");

  let pasteText = prompt;
  if (prompt.length > panes.inlinePromptMaxChars) {
    const taskPath = join(dir, `task.${reqid}.md`);
    writeFileSync(taskPath, prompt);
    pasteText = `Your task for this turn is in ${taskPath} — read that file and carry it out. Reply per your pane protocol.`;
    notes.push(`prompt was ${prompt.length} chars, delivered as ${taskPath}`);
  }

  // The token is written BEFORE the paste. The other order leaves a window in
  // which a fast pane replies into a missing token and is swallowed.
  writeJsonAtomic(join(dir, "pending"), {
    reqid,
    sent_at: new Date().toISOString(),
    from_session: orchestratorId(flags),
    expect_session: expectSession,
    summary: flags.summary && flags.summary !== true ? String(flags.summary) : prompt.slice(0, 120),
  });

  const sent = sendPrompt(record.pane_id, reqid, pasteText);
  if (!sent.ok) {
    try {
      unlinkSync(join(dir, "pending"));
    } catch {
      /* nothing was delivered, so the token must not linger */
    }
    fail(`could not deliver the prompt to ${record.key}: ${sent.error}`);
  }
  paneLog(dir, { ev: "sent", reqid, chars: prompt.length });

  const started = Date.now();
  const replyPath = join(dir, `reply.${reqid}.json`);
  const logBefore = countForeign(dir);
  while ((Date.now() - started) / 1000 < timeout) {
    await sleep(panes.pollSeconds * 1000);
    const reply = readJsonFile(replyPath);
    if (reply) {
      const elapsed = Math.round((Date.now() - started) / 1000);
      say(reply.text || "(the pane's final message was empty)");
      say("");
      say(`— ${record.key} · request ${reqid} · ${elapsed}s · ${(reply.text || "").length} chars`);
      for (const n of notes) say(`note: ${n}`);
      flush(0);
    }
    const foreignNow = countForeign(dir);
    if (foreignNow > logBefore) {
      say(`A Stop hook fired for ${record.key} from a session that is NOT the pane — a foreign reply was rejected and`);
      say(`the request is still outstanding. This is the grandchild-hijack gate firing, not a timeout.`);
      say(`Inspect ${join(dir, "log.jsonl")}.`);
      flush(1);
    }
  }

  const tail = capturePane(record.pane_id, 20);
  say(`No reply from ${record.key} after ${timeout}s (request ${reqid}).`);
  say("The agent may be sitting on a permission prompt with nobody attached.");
  say("");
  say(`  Attach and answer it:   tmux attach -t ${record.key}`);
  say(`  Peek without attaching: pane.mjs peek --key ${record.key}`);
  say("");
  say(`Last 20 lines of the pane:`);
  say(tail || "  (could not capture the pane)");
  say("");
  say("`pending` was left in place: if the agent finishes later the reply still lands in");
  say(`${replyPath}, and \`list\` reports it as an unread reply.`);
  flush(1);
}

function countForeign(dir) {
  try {
    return readFileSync(join(dir, "log.jsonl"), "utf8")
      .split("\n")
      .filter((l) => l.includes('"ev":"foreign"')).length;
  } catch {
    return 0;
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------- peek

function cmdPeek(flags, positional) {
  const target = flags.key && flags.key !== true ? String(flags.key) : positional[0];
  if (!target) fail("peek needs a target: pane.mjs peek --key <key|agent>");
  const record = resolveTarget(livePanes(), target);
  if (!KEY_RE.test(record.key)) refuse(`Refusing: "${record.key}" is not a /pane key.`);
  refuseSelfTarget(record);
  const lines = Number(flags.lines) > 0 ? Number(flags.lines) : 40;
  const text = capturePane(record.pane_id, lines);
  if (text === null) fail(`could not capture ${record.key} (${record.pane_id}).`);
  say(text);
  flush(0);
}

// --------------------------------------------------------------- close

function cmdClose(flags, positional) {
  const live = livePanes();
  const mine = orchestratorId(flags);
  let targets;
  if (flags.all || positional[0] === "all") {
    // Scoped to this Orchestrator on purpose. A global sweep is `doctor`'s job,
    // where it is explicit.
    targets = [...live.values()].filter((r) => r.orchestrator_session_id === mine);
    if (!targets.length) {
      say("no durable agents created by this session.");
      flush(0);
    }
  } else {
    const target = flags.key && flags.key !== true ? String(flags.key) : positional[0];
    if (!target) fail("close needs a target: pane.mjs close --key <key|agent> | --all");
    targets = [resolveTarget(live, target)];
  }

  for (const record of targets) {
    const result = killPane(record);
    if (!result.ok) {
      say(`${record.key}: ${result.error}`);
      continue;
    }
    appendRegistry({ ev: "close", key: record.key, at: new Date().toISOString(), reason: flags.all || positional[0] === "all" ? "all" : "user" });
    paneLog(record.dir || mailboxDir(record.key), { ev: "closed", reason: "user" });
    say(`${record.key}: closed.`);
    for (const n of result.notes || []) say(`  ${n}`);
  }
  compactRegistry();
  say("");
  say("Mailbox directories are left on disk — replies and log.jsonl are the audit trail.");
  flush(0);
}

// -------------------------------------------------------------- doctor

function cmdDoctor() {
  say(`tmux            ${tmuxAvailable() ? tmuxPath() : "NOT FOUND — /pane cannot run. brew install tmux"}`);
  say(`platform        ${process.platform}`);
  say(`iTerm2 layer    ${itermAvailable() ? `available (session ${itermSelfUuid() || "uuid unreadable"})` : "unavailable — panes open in tmux only, attach with tmux attach -t <key>"}`);
  say(`registry        ${existsSync(REGISTRY_PATH) ? REGISTRY_PATH : `${REGISTRY_PATH} (not created yet)`}`);

  const folded = foldRegistry();
  say("");
  say(`recorded live keys: ${folded.size}`);
  const orphans = [];
  for (const [key, rec] of folded) {
    const alive = isPaneLive(rec);
    say(`  ${key}  ${alive ? "alive" : "DEAD (registry says live)"}  agent=${rec.agent} pid=${rec.pane_pid ?? "unrecorded"}`);
    if (!alive && rec.pane_pid) {
      try {
        process.kill(rec.pane_pid, 0);
        orphans.push(rec);
      } catch {
        /* the process is gone too, which is the healthy case */
      }
    }
  }
  if (orphans.length) {
    say("");
    say("ORPHANED PROCESSES — the tmux session is gone but the recorded pid is still alive:");
    for (const rec of orphans) say(`  ${rec.key}: pid ${rec.pane_pid} — close it with \`pane.mjs close --key ${rec.key}\``);
  }

  // Keys stuck at `launching` (durable-agents §7 F2): a create crashed — or is
  // mid-flight right now — between the tmux launch and its `open` event.
  const stuck = launchingKeys();
  if (stuck.length) {
    say("");
    say("STUCK AT LAUNCHING — a create recorded its launch but never its open:");
    for (const rec of stuck) {
      if (tmuxSessionExists(rec.key)) {
        say(`  ${rec.key}: a tmux session EXISTS but was never recorded open. A create may be in flight right now; if not, kill it: tmux kill-session -t ${rec.key}`);
      } else {
        appendRegistry({ ev: "close", key: rec.key, at: new Date().toISOString(), reason: "launch-crashed" });
        say(`  ${rec.key}: no tmux session — reaped.`);
      }
    }
  }

  // Survivors of CLOSED panes: a process still in a closed pane's group whose
  // parent is gone is an MCP server that outlived its `claude`. Report only —
  // doctor never kills without being asked.
  const closed = closedPaneGroupPids();
  const survivors = survivingGroupProcesses(closed.map((c) => c.pane_pid));
  if (survivors.length) {
    say("");
    say("SURVIVING PANE-GROUP PROCESSES — a closed pane's process group still has live members");
    say("(report only; doctor never kills without being asked):");
    for (const s of survivors) {
      const owner = closed.find((c) => c.pane_pid === s.pgid);
      say(`  pid ${s.pid} (${s.comm}) in closed pane group ${s.pgid}${owner ? ` (${owner.key})` : ""}`);
    }
  }

  say("");
  say("agent definitions, installed copy vs live checkout (directory-sourced marketplaces only):");
  const divs = agentsTreeDivergence();
  if (!divs.length) say("  nothing to compare — no installed plugin comes from a directory-sourced marketplace.");
  for (const d of divs) {
    if (d.identical) {
      say(`  ${d.pluginId}@${d.marketplace}: identical (${d.checked} file${d.checked === 1 ? "" : "s"})`);
    } else {
      const bits = [];
      if (d.differ.length) bits.push(`${d.differ.length} differ (${d.differ.join(", ")})`);
      if (d.onlyInstalled.length) bits.push(`${d.onlyInstalled.length} only installed`);
      if (d.onlyLive.length) bits.push(`${d.onlyLive.length} only in the checkout`);
      say(`  ${d.pluginId}@${d.marketplace}: STALE — ${bits.join("; ")}. Resync with: /plugin marketplace update ${d.marketplace}`);
    }
  }

  // Mailboxes for keys closed more than 7 days ago are the only thing removed.
  let swept = 0;
  try {
    const cutoff = Date.now() - 7 * 24 * 3600 * 1000;
    for (const name of readdirSync(MAILBOX_ROOT)) {
      const dir = join(MAILBOX_ROOT, name);
      if (folded.has(name)) continue;
      let mtime;
      try {
        mtime = statSync(dir).mtimeMs;
      } catch {
        continue;
      }
      if (mtime < cutoff) {
        rmSync(dir, { recursive: true, force: true });
        swept++;
      }
    }
  } catch {
    /* no mailbox root yet */
  }
  say("");
  say(`swept ${swept} mailbox director${swept === 1 ? "y" : "ies"} closed for more than 7 days.`);
  flush(0);
}

// ----------------------------------------------------------------- main

const { flags, positional } = parseArgs(process.argv.slice(2));
const sub = positional.shift();

switch (sub) {
  case "create":
  case "open":
    cmdOpen(flags, positional);
    break;
  case "list":
    cmdList(flags);
    break;
  case "send":
    await cmdSend(flags, positional);
    break;
  case "peek":
    cmdPeek(flags, positional);
    break;
  case "close":
    cmdClose(flags, positional);
    break;
  case "doctor":
    cmdDoctor();
    break;
  default:
    fail("usage: pane.mjs create|open|list|send|peek|close|doctor  (see the header of this file)");
}
