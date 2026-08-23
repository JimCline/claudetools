#!/usr/bin/env node
/**
 * agent-hierarchy — /agent-roster CLI: deterministic roster + team file I/O.
 * Modelled on msg.mjs. Interactive prompting (AskUserQuestion, ListAgents
 * polling, actually spawning sessions) is the SKILL.md's job; this CLI does
 * validation and reads/writes only, so validation lives in one place.
 *
 *   roster.mjs show   [global|repo|repo-user] [--level L] [--cwd <path>]
 *   roster.mjs init    [level] [--level L] --route <peer|subagent> [--layout <mode>] [--cwd <path>]
 *   roster.mjs add     [level] [--level L] --role <R> [--model M] [--effort E]
 *                       [--route peer|subagent] [--auto-mode A] [--cwd <path>]
 *   roster.mjs edit    [level] [--level L] --member <NAME> [--role R] [--model M]
 *                       [--effort E] [--route ...] [--auto-mode A] [--cwd <path>]
 *   roster.mjs remove  [level] [--level L] --member <NAME> [--cwd <path>]
 *   roster.mjs layout  [level] [--level L] [--layout <auto|columns|grid>] [--cwd <path>]
 *   roster.mjs create  [--plan] [--commit --verified <json> --transport <t>
 *                       --roster-level <L> [--partial]
 *                       [--orchestrator-pid <pid>]] [--cwd <path>]
 *   roster.mjs create  --spawn --mode <auto|columns|grid> [--roster-level <L>]
 *                       [--orchestrator-pid <pid>] [--cwd <path>]
 *   (`--spawn` launches only; `--commit` persists. Both are required, in that order.)
 *   roster.mjs next-split --mode <auto|columns|grid> --pane-count <N> --self <pane-id>
 *                       --created '<json array of pane ids>'
 *                       --geometry '<json array of {pane_id, rect}>'
 *   roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>]
 *                       (or --next --created <json>, or --apply --target <id> --direction <right|down>)
 *   roster.mjs disband [--commit|--keep-sessions] [--cwd <path>]
 *   roster.mjs resync  [--dry-run] [--cwd <path>]
 *   roster.mjs move    <name> --tab <tab_id> [--split right|down]
 *                       <name> --new-tab [--workspace <id>]
 *                       <name> --new-workspace
 *                       [--dry-run] [--cwd <path>]
 *
 * `--level`/the positional bare word are equivalent; `add`/`edit`/`remove`
 * with neither default to the level the roster currently resolves from
 * (repo-user > repo > global) and print which level they chose.
 *
 * `create` is two-phase, both file-I/O-only: `--plan` (default) resolves the
 * roster, refuses a live Team, clears a stale one, and reports the transport
 * plus each member's derived name and spawn shape — it spawns nothing.
 * `--commit` persists a Team the caller (the SKILL.md flow) has already
 * spawned and verified via ListAgents, writing team.json.
 *
 * `resync` re-derives every peer member's herdr location from herdr's own live
 * topology and rewrites team.json; `move` executes a `herdr pane move` then
 * resyncs that one member. Bare `disband`/`--plan` also resyncs first, in
 * memory only (no write) — see docs/specs/0008-roster-relocate.md.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFile, execFileSync } from "node:child_process";
import { basename, dirname, resolve } from "node:path";

import { CONFIG_VERSION, findGitRoot, hierarchyDir, ROLES, ROLE_DEFAULTS, ROSTER_LEVELS, resolveRoster, rosterLevelPaths, rosterMemberNames } from "./lib-config.mjs";
import { newId, localIso, pidAlive } from "./lib-hier.mjs";
import { clearTeam, readTeam, ROSTER_LAYOUT_VALUES, ROSTER_ROUTE_VALUES, teamPath, validateMember, validateRosterBlock, writeTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "plan", "commit", "partial", "manual", "next", "apply", "kill", "keep-sessions", "spawn", "dry-run", "new-tab", "new-workspace"]);
const DISBAND_FLAGS = new Set(["kill", "commit", "keep-sessions", "plan", "cwd"]);
const RESYNC_FLAGS = new Set(["dry-run", "cwd"]);
const MOVE_FLAGS = new Set(["tab", "split", "new-tab", "workspace", "new-workspace", "dry-run", "cwd"]);

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (!BOOL_FLAGS.has(key) && next !== undefined && !next.startsWith("--")) {
        opts[key] = next;
        i++;
      } else {
        opts[key] = true;
      }
    } else {
      opts._.push(a);
    }
  }
  return opts;
}

function fail(msg) {
  process.stderr.write(`roster.mjs: ${msg}\n`);
  process.exit(2);
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + "\n");
}

/** A partial layout-splits result: real work happened, but not all of it. Bypasses the outer try/catch. */
function partial(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + "\n");
  process.exit(3);
}

const all = parseArgs(process.argv.slice(2));
const cmd = all._.shift();
const opts = all;
const cwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();
const repoBasename = basename(findGitRoot(cwd) || resolve(cwd));

function levelArg() {
  if (typeof opts.level === "string") return opts.level;
  const bare = opts._[0];
  return typeof bare === "string" && ROSTER_LEVELS.includes(bare) ? bare : null;
}

function requireLevel(explicit) {
  if (!ROSTER_LEVELS.includes(explicit)) fail(`--level must be one of ${ROSTER_LEVELS.join(", ")}, got ${JSON.stringify(explicit)}`);
  return explicit;
}

/** For add/edit/remove: explicit --level, else whichever level currently resolves. Returns {level, wasDefaulted}. */
function targetLevel() {
  const explicit = levelArg();
  if (explicit) return { level: requireLevel(explicit), wasDefaulted: false };
  const resolved = resolveRoster(cwd);
  if (!resolved) fail("no roster resolves at any level — run `roster.mjs init` first");
  return { level: resolved.level, wasDefaulted: true };
}

function readLevelFile(path) {
  if (!existsSync(path)) return { version: CONFIG_VERSION };
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    return data && typeof data === "object" && !Array.isArray(data) ? data : { version: CONFIG_VERSION };
  } catch {
    return { version: CONFIG_VERSION };
  }
}

function writeLevelFile(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function namedMembers(members) {
  return rosterMemberNames(members, repoBasename);
}

function findMemberIndex(members, name) {
  return namedMembers(members).findIndex((m) => m.name === name);
}

function detectTransport() {
  if (process.env.HERDR_ENV === "1") return "herdr";
  try {
    execFileSync("tmux", ["list-sessions"], { stdio: "ignore" });
    return "tmux";
  } catch {
    return "terminal";
  }
}

function spawnShape(member, transport) {
  const agentFlags = [`--agent ah:${member.role}`, `--name ${member.name}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null].filter(Boolean);
  const claudeCmd = `claude ${agentFlags.join(" ")}`;
  if (transport === "herdr") return {
    transport,
    // Layout is team-level and geometry-dependent: `roster.mjs layout-splits` computes and
    // performs the split sequence from live `herdr pane layout` output. See spec 0004 §3.2.
    layout: [],
    launch: [`herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`],
    target_placeholder: "<TARGET>",
    target_from: null,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
  if (transport === "tmux") return {
    transport,
    // -P -F prints the new window's pane id: an untargeted `send-keys` writes to
    // whatever pane is active, which cannot survive two launches being in flight.
    layout: [`tmux new-window -P -F '#{pane_id}' -c "${cwd}"`],
    launch: [`tmux send-keys -t <TARGET> ${JSON.stringify(claudeCmd)} Enter`],
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "stdout", trim: true },
  };
  return { transport, layout: [], launch: [`${claudeCmd} --bg`], target_placeholder: null, target_from: null, target_source: null };
}

/** Plan-level herdr layout instructions for the orchestrator to drive (spec 0004 §5.2). Null for non-herdr or an all-subagent roster. */
function layoutPlan(resolved, transport, plan) {
  if (transport !== "herdr") return null;
  const paneCount = plan.filter((m) => m.route === "peer").length;
  if (paneCount === 0) return null;
  return {
    mode: resolved.layout,
    computed_by: "roster.mjs layout-splits",
    pane_count: paneCount,
    inspect_command: `herdr pane layout --current`,
    inspect_source: { kind: "json", path: ".result.layout.panes" },
    split_command: `herdr pane split --pane <SPLIT_TARGET> --direction <DIRECTION> --cwd "${cwd}" --no-focus`,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
}

/** `auto` resolves once from the final target pane count, never from splits done so far (spec 0004 §6.3). */
function effectiveMode(mode, paneCount) {
  if (mode !== "auto") return mode;
  return paneCount <= 2 ? "columns" : "grid";
}

/**
 * Pure greedy split-target algorithm (spec 0004 §6.7, amended). No I/O —
 * arithmetic over `self`, `created` (pane ids created so far, in creation
 * order) and `geometry` (`[{pane_id, rect: {width, height, x, y}}]`). `self`
 * is an ordinary candidate at every call, first in candidate order for
 * tie-breaking. Exists so the rule is unit-tested and the orchestrator never
 * improvises it.
 */
function nextSplit({ mode, paneCount, self, created, geometry }) {
  const byId = new Map(geometry.map((g) => [g.pane_id, g.rect]));
  let target = null;
  let bestArea = -1;
  for (const id of [self, ...created]) {
    const rect = byId.get(id);
    if (!rect) fail(`next-split: pane ${JSON.stringify(id)} is not present in the reported geometry`);
    const area = rect.width * rect.height;
    if (area > bestArea) {
      bestArea = area;
      target = id;
    }
  }
  const rect = byId.get(target);

  // Plan constants, spec 0007 §5.2 — derived from paneCount alone, no persisted state.
  const total = paneCount + 1;
  const bands = Math.max(total >= 3 ? 2 : 1, 2 ** Math.floor(Math.log2(total) / 2));
  const cols = Math.ceil(total / bands);

  // Root rect, spec 0007 §5.3 — bounding box of the candidate panes only.
  const cands = [self, ...created].map((id) => byId.get(id));
  const rootX = Math.min(...cands.map((r) => r.x));
  const rootY = Math.min(...cands.map((r) => r.y));
  const rootWidth = Math.max(...cands.map((r) => r.x + r.width)) - rootX;
  const rootHeight = Math.max(...cands.map((r) => r.y + r.height)) - rootY;

  // Direction rule, spec 0007 §5.4.
  let direction;
  if (effectiveMode(mode, paneCount) === "columns") {
    direction = "right";
  } else if (rootWidth > 0 && rootHeight > 0 && rect.height * 2 * bands > rootHeight * 3) {
    direction = "down"; // spans >1.5 bands
  } else if (rootWidth > 0 && rootHeight > 0 && rect.width * 2 * cols > rootWidth * 3) {
    direction = "right"; // spans >1.5 columns
  } else {
    direction = rect.width > rect.height * 2 ? "right" : "down"; // 0004 §6.1, verbatim
  }

  return { target, direction };
}

// Sole exec site for herdr (spec 0002 §11.3's grep assertion; spec 0005 extends the permitted
// callers to `create --spawn` alongside `layout-splits` — see tests/test-roster-layout-splits.sh).
function herdrCall(args) {
  const timeout = Number(process.env.AH_HERDR_TIMEOUT_MS || 10000);
  let stdout;
  try {
    stdout = execFileSync("herdr", args, { encoding: "utf8", timeout, maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    if (err.signal) throw new Error(`herdr ${args.join(" ")} timed out after ${timeout}ms`);
    throw new Error(`herdr ${args.join(" ")} failed: ${(err.stderr && String(err.stderr).trim()) || err.message}`);
  }
  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(`herdr ${args.join(" ")} produced unparseable output`);
  }
}

/**
 * Live herdr topology: agent name (if any) plus pane/tab/workspace ids for every live pane
 * (spec 0008 §5.2). `herdr agent list` is the preferred single-call source — field names
 * (`.result.agents[].{name?,pane_id,tab_id,workspace_id}`) verified against a live herdr this
 * session; `name` is absent for a pane hosting no `herdr agent start`-named agent.
 */
function queryHerdrTopology() {
  const result = herdrCall(["agent", "list"]);
  const agents = result && result.result && Array.isArray(result.result.agents) ? result.result.agents : null;
  if (!agents) throw new Error("herdr agent list produced unexpected shape (missing .result.agents)");
  return agents.map((a) => ({ name: a.name || null, pane_id: a.pane_id, tab_id: a.tab_id, workspace_id: a.workspace_id }));
}

/** Spec 0008 §5.3: name first (durable across workspace moves), pane id second, else no match. */
function matchMemberToPane(member, topology) {
  if (member.name) {
    const byName = topology.find((p) => p.name === member.name);
    if (byName) return byName;
  }
  if (member.transport_id) {
    const byId = topology.find((p) => p.pane_id === member.transport_id);
    if (byId) return byId;
  }
  return null;
}

/**
 * Pure heal pass over `team.members` against live herdr topology (spec 0008 §5.1). No I/O beyond
 * the topology query — never writes team.json. Shared by `resync` (persists the result) and
 * `disband`'s bare/`--plan` path (does not persist) — one implementation, two callers.
 * Returns `{ members, counts, query_ok, query_error, warning? }`; on query failure `members` and
 * `counts` are null and the caller decides whether to fail() (resync/move) or degrade (disband).
 */
function resyncMembers(team) {
  let topology;
  try {
    topology = queryHerdrTopology();
  } catch (err) {
    return { members: null, counts: null, query_ok: false, query_error: err.message };
  }
  const claimed = new Set();
  let duplicate = false;
  const counts = { updated: 0, unchanged: 0, not_found: 0, skipped: 0 };
  const members = team.members.map((m) => {
    if (m.route !== "peer" || m.transport_id == null) {
      counts.skipped++;
      return { ...m, status: "skipped" };
    }
    let match = matchMemberToPane(m, topology);
    if (match && claimed.has(match.pane_id)) {
      duplicate = true; // spec 0008 §7.6: first match wins, later claimants fall through to not_found
      match = null;
    }
    if (!match) {
      counts.not_found++;
      return { ...m, status: "not_found", transport_stale: true };
    }
    claimed.add(match.pane_id);
    const from = { transport_id: m.transport_id, tab_id: m.tab_id, workspace_id: m.workspace_id };
    const to = { transport_id: match.pane_id, tab_id: match.tab_id, workspace_id: match.workspace_id };
    const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
    delete healed.transport_stale;
    if (from.transport_id !== to.transport_id || from.tab_id !== to.tab_id || from.workspace_id !== to.workspace_id) {
      counts.updated++;
      return { ...healed, status: "updated", from, to };
    }
    counts.unchanged++;
    return { ...healed, status: "unchanged" };
  });
  return { members, counts, query_ok: true, query_error: null, warning: duplicate ? "duplicate pane match" : undefined };
}

/** Strip resyncMembers()'s per-pass bookkeeping fields before a healed member array is persisted. */
function stripResyncMeta(m) {
  const { status, from, to, ...member } = m;
  return member;
}

/** Spec 0008 §4: the no-op reason for a non-herdr transport, shared by `resync` and `move`. */
function transportNoop(transport) {
  return transport === "tmux" ? "transport tmux not supported (spec 0008 §4)" : "transport terminal has no panes";
}

/** Spec 0004 §6.6 sequential split loop, shared by `layout-splits` (bare form) and `create --spawn`'s layout phase (spec 0005 §4 step 3). Stops at the first failure. */
function runLayoutLoop({ mode, paneCount, self, splitCwd }) {
  const panes = [];
  const splits = [];
  for (let i = 1; i <= paneCount; i++) {
    let geomResult;
    try {
      geomResult = herdrCall(["pane", "layout", "--current"]);
    } catch (err) {
      if (panes.length === 0) fail(err.message);
      partial({ panes, splits, mode, pane_count: paneCount, complete: false, failed_at: i, attempted: null, error: err.message });
    }
    const geometry = geomResult.result.layout.panes;
    const decision = nextSplit({ mode, paneCount, self, created: panes, geometry });
    let splitResult;
    try {
      splitResult = herdrCall(["pane", "split", "--pane", decision.target, "--direction", decision.direction, "--cwd", splitCwd, "--no-focus"]);
    } catch (err) {
      if (panes.length === 0) fail(err.message);
      partial({ panes, splits, mode, pane_count: paneCount, complete: false, failed_at: i, attempted: decision, error: err.message });
    }
    const newPaneId = splitResult.result.pane.pane_id;
    panes.push(newPaneId);
    splits.push({ i, target: decision.target, direction: decision.direction, pane_id: newPaneId });
  }
  return { panes, splits };
}

/** Shared by `create --plan` and `create --spawn` (spec 0005 §9 item 1): resolve the roster, refuse/clear a stale Team, compute members[] + spawn shapes. */
function resolveMembersPlan(dir) {
  const existing = readTeam(dir);
  if (existing) {
    const stale = !pidAlive(existing.orchestrator && existing.orchestrator.pid) || Date.now() - Date.parse(existing.created) > 24 * 3600 * 1000;
    if (!stale) fail(`a live Team ${existing.team_id} already exists — disband it first`);
    clearTeam(dir);
  }
  const resolved = resolveRoster(cwd);
  if (!resolved) fail("no roster resolves at any level — hand off to `roster.mjs init`");
  const transport = detectTransport();
  const plan = resolved.members.map((m) => {
    const route = m.route || resolved.route;
    return { role: m.role, name: m.name, model: m.model, effort: m.effort, route, autoMode: m.autoMode, spawn: route === "peer" ? spawnShape(m, transport) : null };
  });
  return { level: resolved.level, path: resolved.path, transport, layout_plan: layoutPlan(resolved, transport, plan), members: plan };
}

function runShell(commandString) {
  return new Promise((resolvePromise) => {
    execFile("/bin/sh", ["-c", commandString], { encoding: "utf8", maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
      resolvePromise({ err, stdout, stderr });
    });
  });
}

/**
 * One member's launch, with the herdr-only retry (spec 0005 §4 step 6). NEEDS-EVIDENCE item 2 (§9)
 * is unresolved — no live pane was available to reproduce the retryable "pane busy" condition, only
 * the non-retryable ones (bad --kind, nonexistent pane) — so this uses the spec's documented safe
 * fallback: retry once on any herdr failure, herdr-only.
 */
async function launchMember(member, transport) {
  const template = member.spawn.launch[0];
  const cmd = member.spawn.target_placeholder && member.transport_id != null ? template.split(member.spawn.target_placeholder).join(member.transport_id) : template;
  let attempt = await runShell(cmd);
  let retried = false;
  if (attempt.err && transport === "herdr") {
    retried = true;
    attempt = await runShell(cmd);
  }
  const errorText = () => (attempt.stderr && String(attempt.stderr).trim()) || (attempt.err && attempt.err.message) || "launch failed";
  if (transport === "herdr") {
    if (!attempt.err) {
      let parsed = null;
      try {
        parsed = JSON.parse(attempt.stdout);
      } catch {
        /* non-JSON success output — reported as ready with a null launch_result */
      }
      return { ...member, launch_status: "ready", launch_result: parsed, retried };
    }
    return { ...member, launch_status: "failed", launch_result: null, retried, error: errorText() };
  }
  // tmux and terminal: no readiness handshake, and no retry (spec 0005 §4 step 6 [correction]).
  if (!attempt.err) return { ...member, launch_status: "dispatched", launch_result: null, retried: false };
  return { ...member, launch_status: "failed", launch_result: null, retried: false, error: errorText() };
}

/** `create --spawn` (spec 0005): resolve + layout + launch + retry in one script invocation. */
async function createSpawn(dir) {
  const mode = opts.mode;
  if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
  const { level, transport, layout_plan, members } = resolveMembersPlan(dir);
  const peerMembers = members.filter((m) => m.route === "peer");

  let panes = [];
  if (transport === "herdr" && peerMembers.length > 0) {
    const self = process.env.HERDR_PANE_ID;
    if (!self) fail("create --spawn needs HERDR_PANE_ID in the environment");
    ({ panes } = runLayoutLoop({ mode, paneCount: peerMembers.length, self, splitCwd: cwd }));
  } else if (transport === "tmux") {
    for (let i = 0; i < peerMembers.length; i++) {
      try {
        panes.push(execFileSync("tmux", ["new-window", "-P", "-F", "#{pane_id}", "-c", cwd], { encoding: "utf8" }).trim());
      } catch (err) {
        // Mirrors runLayoutLoop's herdr-path partial(): preserve the windows already created
        // rather than losing them to the generic top-level catch (spec 0005 review, tmux gap).
        partial({ panes, mode, pane_count: peerMembers.length, complete: false, failed_at: i, error: err.message });
      }
    }
  }

  // [correction] spec 0003 §6.2: N layout commands must yield N distinct, non-empty target ids —
  // asserted before any launch fires, so a bad layout cannot become N claude processes in the wrong places.
  if (transport !== "terminal" && peerMembers.length > 0) {
    if (panes.length !== peerMembers.length || panes.some((p) => !p) || new Set(panes).size !== panes.length) {
      fail(`create --spawn: layout produced ${JSON.stringify(panes)} for ${peerMembers.length} peer member(s) — expected that many distinct, non-empty target ids`);
    }
  }
  peerMembers.forEach((m, i) => {
    m.transport_id = transport === "terminal" ? null : panes[i];
  });

  const settled = await Promise.allSettled(peerMembers.map((m) => launchMember(m, transport)));
  const launchByName = new Map(
    settled.map((r, i) => [peerMembers[i].name, r.status === "fulfilled" ? r.value : { ...peerMembers[i], launch_status: "failed", launch_result: null, retried: false, error: String(r.reason) }])
  );

  const outputMembers = members.map((m) => {
    if (m.route !== "peer") return { role: m.role, name: m.name, model: m.model, route: m.route, autoMode: m.autoMode, transport_id: null, launch_status: null };
    const lm = launchByName.get(m.name);
    const entry = { role: m.role, name: m.name, model: m.model, route: m.route, autoMode: m.autoMode, transport_id: m.transport_id, launch_status: lm.launch_status, launch_result: lm.launch_result, retried: lm.retried };
    if (lm.error) entry.error = lm.error;
    // Spec 0008 §6: populate tab_id/workspace_id from the launch result when it carries them.
    // No new herdr query on this path — if absent, the first `resync` fills them in.
    const launchedPane = transport === "herdr" && lm.launch_result && lm.launch_result.result && lm.launch_result.result.pane;
    if (launchedPane && launchedPane.tab_id != null) entry.tab_id = launchedPane.tab_id;
    if (launchedPane && launchedPane.workspace_id != null) entry.workspace_id = launchedPane.workspace_id;
    return entry;
  });
  const isPartial = outputMembers.some((m) => m.route === "peer" && m.launch_status === "failed");
  out({ level, transport, members: outputMembers, partial: isPartial });
}

try {
  switch (cmd) {
    case "show": {
      const explicit = levelArg();
      if (explicit) {
        const level = requireLevel(explicit);
        const path = rosterLevelPaths(cwd)[level];
        const data = readLevelFile(path);
        const resolved = resolveRoster(cwd);
        out({
          level,
          path,
          roster: data.roster && data.roster.members ? { route: data.roster.route, layout: data.roster.layout || "auto", members: namedMembers(data.roster.members) } : null,
          shadowed: resolved && resolved.level !== level ? `shadowed by ${resolved.level}` : null,
        });
      } else {
        out(resolveRoster(cwd) || { roster: null });
      }
      break;
    }

    case "init": {
      const level = requireLevel(levelArg() || fail("init needs --level global|repo|repo-user (or the level as the first word)"));
      const route = opts.route;
      if (!ROSTER_ROUTE_VALUES.includes(route)) fail(`--route must be "peer" or "subagent", got ${JSON.stringify(route)}`);
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      data.version = data.version || CONFIG_VERSION;
      data.roster = { route, members: [] };
      if (typeof opts.layout === "string") {
        if (!ROSTER_LAYOUT_VALUES.includes(opts.layout)) fail(`--layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(opts.layout)}`);
        data.roster.layout = opts.layout;
      }
      writeLevelFile(path, data);
      out({ level, path, roster: data.roster });
      break;
    }

    case "add": {
      const { level, wasDefaulted } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      if (!data.roster || !Array.isArray(data.roster.members)) fail(`no roster at level "${level}" — run \`roster.mjs init\` first`);
      const role = opts.role;
      if (role === "orchestrator") fail('role "orchestrator" is not a roster member — the Orchestrator is whatever session runs /agent-roster create');
      if (!ROLES.includes(role)) fail(`--role must be one of ${ROLES.join(", ")}, got ${JSON.stringify(role)}`);
      const member = { role, model: typeof opts.model === "string" ? opts.model : (ROLE_DEFAULTS[role] || {}).model };
      if (typeof opts.effort === "string") member.effort = opts.effort;
      if (typeof opts.route === "string") member.route = opts.route;
      if (typeof opts["auto-mode"] === "string") member.autoMode = opts["auto-mode"];
      const memberErrors = validateMember(member);
      if (memberErrors.length) fail(memberErrors.join("; "));
      if (member.autoMode === "bypassPermissions" && (member.route || data.roster.route) === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen\n');
      }
      data.roster.members.push(member);
      const blockErrors = validateRosterBlock(data.roster);
      if (blockErrors.length) fail(blockErrors.join("; "));
      writeLevelFile(path, data);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — added at the currently-resolving level "${level}"\n`);
      out({ level, path, wasDefaulted, member: namedMembers(data.roster.members).at(-1) });
      break;
    }

    case "edit": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("edit needs --member <derived-name>");
      const { level, wasDefaulted } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      if (!data.roster || !Array.isArray(data.roster.members)) fail(`no roster at level "${level}" — run \`roster.mjs init\` first`);
      const idx = findMemberIndex(data.roster.members, memberName);
      if (idx === -1) fail(`no member named ${JSON.stringify(memberName)} at level "${level}"`);
      const updated = { ...data.roster.members[idx] };
      if (typeof opts.role === "string") updated.role = opts.role;
      if (typeof opts.model === "string") updated.model = opts.model;
      if (typeof opts.effort === "string") updated.effort = opts.effort;
      if (typeof opts.route === "string") updated.route = opts.route;
      if (typeof opts["auto-mode"] === "string") updated.autoMode = opts["auto-mode"];
      if (updated.role === "orchestrator") fail('role "orchestrator" is not a roster member');
      const errors = validateMember(updated);
      if (errors.length) fail(errors.join("; "));
      if (updated.autoMode === "bypassPermissions" && (updated.route || data.roster.route) === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen\n');
      }
      data.roster.members[idx] = updated;
      writeLevelFile(path, data);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — edited at the currently-resolving level "${level}"\n`);
      out({ level, path, wasDefaulted, member: namedMembers(data.roster.members)[idx] });
      break;
    }

    case "remove": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("remove needs --member <derived-name>");
      const { level, wasDefaulted } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      if (!data.roster || !Array.isArray(data.roster.members)) fail(`no roster at level "${level}" — run \`roster.mjs init\` first`);
      const idx = findMemberIndex(data.roster.members, memberName);
      if (idx === -1) fail(`no member named ${JSON.stringify(memberName)} at level "${level}"`);
      data.roster.members.splice(idx, 1);
      writeLevelFile(path, data);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — removed from the currently-resolving level "${level}"\n`);
      out({ level, path, wasDefaulted, removed: memberName });
      break;
    }

    case "layout": {
      const { level, wasDefaulted } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      if (!data.roster || !Array.isArray(data.roster.members)) fail(`no roster at level "${level}" — run \`roster.mjs init\` first`);
      if (typeof opts.layout === "string") {
        if (!ROSTER_LAYOUT_VALUES.includes(opts.layout)) fail(`--layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(opts.layout)}`);
        data.roster.layout = opts.layout;
        const blockErrors = validateRosterBlock(data.roster);
        if (blockErrors.length) fail(blockErrors.join("; "));
        writeLevelFile(path, data);
      }
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — using the currently-resolving level "${level}"\n`);
      out({ level, path, wasDefaulted, layout: data.roster.layout || "auto" });
      break;
    }

    case "next-split": {
      const mode = opts.mode;
      if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
      const paneCountRaw = opts["pane-count"];
      const paneCount = typeof paneCountRaw === "string" ? Number(paneCountRaw) : fail("next-split needs --pane-count <N>");
      if (!Number.isInteger(paneCount) || paneCount < 0) fail(`--pane-count must be a non-negative integer, got ${JSON.stringify(paneCountRaw)}`);
      const self = typeof opts.self === "string" ? opts.self : fail("next-split needs --self <pane-id>");
      const created = typeof opts.created === "string" ? JSON.parse(opts.created) : fail("next-split needs --created <json array>");
      const geometry = typeof opts.geometry === "string" ? JSON.parse(opts.geometry) : fail("next-split needs --geometry <json array>");
      out(nextSplit({ mode, paneCount, self, created, geometry }));
      break;
    }

    case "layout-splits": {
      if (opts.next === true && opts.apply === true) fail("--next and --apply are mutually exclusive");
      if (detectTransport() !== "herdr") fail("layout-splits requires the herdr transport");

      const splitCwd = typeof opts.cwd === "string" ? opts.cwd : process.cwd();

      if (opts.apply === true) {
        const target = typeof opts.target === "string" ? opts.target : fail("layout-splits --apply needs --target <pane-id>");
        const dir = opts.direction;
        if (dir !== "right" && dir !== "down") fail(`--direction must be "right" or "down", got ${JSON.stringify(dir)}`);
        let result;
        try {
          result = herdrCall(["pane", "split", "--pane", target, "--direction", dir, "--cwd", splitCwd, "--no-focus"]);
        } catch (err) {
          fail(err.message);
        }
        out({ pane_id: result.result.pane.pane_id, target, direction: dir });
        break;
      }

      const mode = opts.mode;
      if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
      const paneCountRaw = opts["pane-count"];
      const paneCount = typeof paneCountRaw === "string" ? Number(paneCountRaw) : fail("layout-splits needs --pane-count <N>");
      if (!Number.isInteger(paneCount) || paneCount < 0) fail(`--pane-count must be a non-negative integer, got ${JSON.stringify(paneCountRaw)}`);
      const self = typeof opts.self === "string" ? opts.self : process.env.HERDR_PANE_ID;
      if (!self) fail("layout-splits needs --self <pane-id> (or HERDR_PANE_ID in the environment)");

      if (opts.next === true) {
        const created = typeof opts.created === "string" ? JSON.parse(opts.created) : fail("layout-splits --next needs --created <json array>");
        let geomResult;
        try {
          geomResult = herdrCall(["pane", "layout", "--current"]);
        } catch (err) {
          fail(err.message);
        }
        const geometry = geomResult.result.layout.panes;
        const decision = nextSplit({ mode, paneCount, self, created, geometry });
        const targetRect = geometry.find((g) => g.pane_id === decision.target).rect;
        out({
          index: created.length + 1,
          pane_count: paneCount,
          mode,
          target: decision.target,
          direction: decision.direction,
          target_rect: targetRect,
          target_is_self: decision.target === self,
          geometry,
        });
        break;
      }

      // Bare form: perform the whole spec 0004 §6.6 loop, stop at the first failure.
      if (paneCount === 0) {
        out({ panes: [], complete: true });
        break;
      }
      const { panes, splits } = runLayoutLoop({ mode, paneCount, self, splitCwd });
      out({ panes, splits, mode, pane_count: paneCount, complete: true });
      break;
    }

    case "create": {
      if ([opts.plan === true, opts.commit === true, opts.spawn === true].filter(Boolean).length > 1) {
        fail("create: --plan, --commit, and --spawn are mutually exclusive");
      }
      const dir = hierarchyDir(cwd);
      if (opts.spawn === true) {
        await createSpawn(dir);
        break;
      }
      if (opts.commit) {
        const verified = typeof opts.verified === "string" ? JSON.parse(opts.verified) : fail("--commit needs --verified <json array>");
        const transport = typeof opts.transport === "string" ? opts.transport : fail("--commit needs --transport");
        const rosterLevel = typeof opts["roster-level"] === "string" ? opts["roster-level"] : fail("--commit needs --roster-level");
        // roster.mjs runs as a transient Bash-tool subprocess, so process.ppid here is
        // that shell, not the orchestrator's own long-lived process — using it would make
        // the staleness sweep (sessionstart.mjs) tear the Team down almost immediately.
        // CLAUDE_PID is the env var every claude session exports as its own pid (see
        // sessionstart.mjs/README's peers.jsonl liveness records, which rely on the same
        // invariant); an explicit --orchestrator-pid overrides it for tests or an
        // unusual environment where the env var isn't propagated.
        const orchestratorPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
        const team = {
          version: 1,
          team_id: newId(),
          created: localIso(),
          roster_level: rosterLevel,
          transport,
          orchestrator: { session_id: typeof opts.session === "string" ? opts.session : null, pid: Number.isInteger(orchestratorPid) ? orchestratorPid : null },
          members: verified,
          partial: opts.partial === true,
        };
        writeTeam(dir, team);
        out({ committed: true, team });
        break;
      }
      // --plan (default): resolve, refuse a live Team, clear a stale one, report the spawn plan.
      out(resolveMembersPlan(dir));
      break;
    }

    case "disband": {
      // Spec 0006 §6: an unrecognized flag must fail loudly, not degrade to the (now destructive-
      // by-default) bare path. --kill is accepted-and-ignored (§5.4) for 0002-era callers.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!DISBAND_FLAGS.has(key)) fail(`disband: unrecognized flag --${key} (use --commit, --keep-sessions, or --plan)`);
      }
      if (opts["keep-sessions"] === true && (opts.commit === true || opts.kill === true)) {
        fail("disband --keep-sessions cannot be combined with --commit or --kill");
      }
      const dir = hierarchyDir(cwd);

      // --commit: removes team.json only, never re-reads the member list (spec 0002 §8.1/§8.3,
      // spec 0006 §5.2 — no longer gated on --kill).
      if (opts.commit === true) {
        const team = readTeam(dir);
        if (!team) {
          out({ removed: false, reason: "no active team" });
          break;
        }
        clearTeam(dir);
        out({ removed: teamPath(dir) });
        break;
      }

      // --keep-sessions: the old safe default (spec 0006 §5.3) — single call, removes team.json,
      // emits nothing, closes nothing.
      if (opts["keep-sessions"] === true) {
        const team = readTeam(dir);
        if (!team) {
          out({ disbanded: false, reason: "no active team" });
          break;
        }
        clearTeam(dir);
        out({ disbanded: true, team_id: team.team_id, members: team.members.map((m) => ({ role: m.role, name: m.name, transport_id: m.transport_id })) });
        break;
      }

      // Bare disband / --plan / --kill (ignored): the new default (spec 0006 §5.1). Read-only,
      // emits the close plan, writes nothing. Spec 0008 §5.6 (AMENDMENT): for herdr, resync the
      // member list in memory first — the plan then targets each member's *current* pane — but
      // never persist the heal and never fail() on a query error (degrade to the stored ids).
      const team = readTeam(dir);
      if (!team) {
        out({ disbanded: false, reason: "no active team" });
        break;
      }
      let healedMembers = team.members;
      let resyncSummary = null;
      if (team.transport === "herdr") {
        const result = resyncMembers(team);
        if (result.query_ok) {
          healedMembers = result.members;
          resyncSummary = { ok: true, counts: result.counts };
          if (result.warning) resyncSummary.warning = result.warning;
        } else {
          healedMembers = team.members.map((m) => ({ ...m, status: "unqueried" }));
          resyncSummary = { ok: false, reason: result.query_error };
        }
      }
      const close = healedMembers.map((m) => {
        let command = null;
        if (m.route === "peer" && m.transport_id) {
          if (team.transport === "herdr") command = `herdr pane close ${m.transport_id}`;
          else if (team.transport === "tmux") command = `tmux kill-pane -t ${m.transport_id}`;
        }
        const entry = { role: m.role, name: m.name, route: m.route, transport: team.transport, transport_id: m.transport_id, command };
        if (team.transport === "herdr") entry.resync_status = m.status;
        return entry;
      });
      const disbandOut = { close };
      if (resyncSummary) disbandOut.resync = resyncSummary;
      out(disbandOut);
      break;
    }

    case "resync": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!RESYNC_FLAGS.has(key)) fail(`resync: unrecognized flag --${key} (use --dry-run or --cwd)`);
      }
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir);
      if (!team) {
        out({ resynced: false, reason: "no active team" });
        break;
      }
      if (team.transport !== "herdr") {
        out({ resynced: false, reason: transportNoop(team.transport) });
        break;
      }
      const result = resyncMembers(team);
      if (!result.query_ok) fail(result.query_error);
      const dryRun = opts["dry-run"] === true;
      const membersOut = result.members.map((m) => {
        const entry = { role: m.role, name: m.name, status: m.status };
        if (m.status === "updated") {
          entry.from = m.from;
          entry.to = m.to;
        }
        return entry;
      });
      if (!dryRun) {
        team.members = result.members.map(stripResyncMeta);
        writeTeam(dir, team);
      }
      const resyncOut = { resynced: true, dry_run: dryRun, transport: "herdr", members: membersOut, counts: result.counts };
      if (result.warning) resyncOut.warning = result.warning;
      out(resyncOut);
      break;
    }

    case "move": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!MOVE_FLAGS.has(key)) fail(`move: unrecognized flag --${key} (use --tab/--split, --new-tab[/--workspace], or --new-workspace)`);
      }
      const name = typeof opts._[0] === "string" ? opts._[0] : fail("move needs a member name: roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace");
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir);
      const teamMembers = team && Array.isArray(team.members) ? team.members : [];
      const member = teamMembers.find((m) => m.name === name);
      if (!member) fail(`move: no member named ${JSON.stringify(name)} — known members: ${teamMembers.map((m) => m.name).filter(Boolean).join(", ") || "(none)"}`);
      if (member.route !== "peer" || member.transport_id == null) fail(`move: member ${name} has no pane to move`);
      if (team.transport !== "herdr") {
        out({ moved: false, reason: transportNoop(team.transport) });
        break;
      }
      const modeCount = [opts.tab !== undefined, opts["new-tab"] === true, opts["new-workspace"] === true].filter(Boolean).length;
      if (modeCount !== 1) fail("move: exactly one of --tab, --new-tab, --new-workspace is required");
      const moveUsage = "roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace";
      if (opts.tab !== undefined && typeof opts.tab !== "string") fail(`move: --tab requires a value: ${moveUsage}`);
      if (opts.workspace !== undefined && typeof opts.workspace !== "string") fail(`move: --workspace requires a value: ${moveUsage}`);
      if (opts.split !== undefined && opts.tab === undefined) fail("move: --split is only valid with --tab");
      const herdrArgs = ["pane", "move", member.transport_id];
      if (opts.tab !== undefined) {
        herdrArgs.push("--tab", opts.tab);
        if (opts.split !== undefined) {
          if (opts.split !== "right" && opts.split !== "down") fail(`move: --split must be "right" or "down", got ${JSON.stringify(opts.split)}`);
          herdrArgs.push("--split", opts.split);
        }
      } else if (opts["new-tab"] === true) {
        herdrArgs.push("--new-tab");
        if (typeof opts.workspace === "string") herdrArgs.push("--workspace", opts.workspace);
      } else {
        herdrArgs.push("--new-workspace");
      }
      const commandString = `herdr ${herdrArgs.join(" ")}`;
      if (opts["dry-run"] === true) {
        out({ moved: false, dry_run: true, command: commandString });
        break;
      }
      try {
        herdrCall(herdrArgs);
      } catch (err) {
        fail(err.message);
      }
      // Ignore the move response body entirely (spec 0008 §2/§5.4 step 7) — re-query instead.
      const result = resyncMembers(team);
      if (!result.query_ok) {
        // spec 0008 §7.5: the pane already moved, so a query failure is reported at exit 0, never fail() —
        // a non-zero exit here would misrepresent the move (which succeeded) as having failed.
        out({ moved: true, command: commandString, resync: { ok: false, reason: result.query_error } });
        break;
      }
      team.members = result.members.map(stripResyncMeta);
      writeTeam(dir, team);
      const healed = result.members.find((m) => m.name === name);
      const resyncOut = { ok: true, status: healed.status };
      if (healed.status === "updated") {
        resyncOut.from = healed.from;
        resyncOut.to = healed.to;
      }
      if (result.warning) resyncOut.warning = result.warning;
      out({ moved: true, member: { role: member.role, name: member.name }, command: commandString, resync: resyncOut });
      break;
    }

    default:
      fail(`usage: roster.mjs show|init|add|edit|remove|layout|create|next-split|layout-splits|disband|resync|move [--commit|--keep-sessions] [--level global|repo|repo-user] [--cwd <path>]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
