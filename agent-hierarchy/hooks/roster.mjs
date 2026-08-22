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
 *   roster.mjs next-split --mode <auto|columns|grid> --pane-count <N> --self <pane-id>
 *                       --created '<json array of pane ids>'
 *                       --geometry '<json array of {pane_id, rect}>'
 *   roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>]
 *                       (or --next --created <json>, or --apply --target <id> --direction <right|down>)
 *   roster.mjs disband [--kill --plan|--commit] [--cwd <path>]
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
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, resolve } from "node:path";

import { CONFIG_VERSION, findGitRoot, hierarchyDir, ROLES, ROLE_DEFAULTS, ROSTER_LEVELS, resolveRoster, rosterLevelPaths, rosterMemberNames } from "./lib-config.mjs";
import { newId, localIso, pidAlive } from "./lib-hier.mjs";
import { clearTeam, readTeam, ROSTER_LAYOUT_VALUES, ROSTER_ROUTE_VALUES, teamPath, validateMember, validateRosterBlock, writeTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "plan", "commit", "partial", "manual", "next", "apply", "kill"]);

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
  const direction = effectiveMode(mode, paneCount) === "columns" || rect.width > rect.height * 2 ? "right" : "down";
  return { target, direction };
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

      // Scoped inside this case so `herdrCall(` is reachable only from here (spec 0002 §11.3's grep assertion).
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
      out({ panes, splits, mode, pane_count: paneCount, complete: true });
      break;
    }

    case "create": {
      const dir = hierarchyDir(cwd);
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
      out({ level: resolved.level, path: resolved.path, transport, layout_plan: layoutPlan(resolved, transport, plan), members: plan });
      break;
    }

    case "disband": {
      const dir = hierarchyDir(cwd);
      if (opts.kill === true) {
        // Two-call contract (spec 0002 §8.1/§8.3): --plan emits, never removes; --commit removes,
        // never re-reads. Folding both into one call is what let a declined confirmation or a
        // failed close leave team.json already gone — the exact bug this split exists to prevent.
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
        if (opts.plan !== true) fail("disband --kill requires --plan or --commit");
        const team = readTeam(dir);
        if (!team) {
          out({ disbanded: false, reason: "no active team" });
          break;
        }
        const close = team.members.map((m) => {
          let command = null;
          if (m.route === "peer" && m.transport_id) {
            if (team.transport === "herdr") command = `herdr pane close ${m.transport_id}`;
            else if (team.transport === "tmux") command = `tmux kill-pane -t ${m.transport_id}`;
          }
          return { role: m.role, name: m.name, route: m.route, transport: team.transport, transport_id: m.transport_id, command };
        });
        out({ close });
        break;
      }
      const team = readTeam(dir);
      if (!team) {
        out({ disbanded: false, reason: "no active team" });
        break;
      }
      clearTeam(dir);
      out({ disbanded: true, team_id: team.team_id, members: team.members.map((m) => ({ role: m.role, name: m.name, transport_id: m.transport_id })) });
      break;
    }

    default:
      fail(`usage: roster.mjs show|init|add|edit|remove|layout|create|next-split|layout-splits|disband [--kill --plan|--commit] [--level global|repo|repo-user] [--cwd <path>]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
