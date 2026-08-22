#!/usr/bin/env node
/**
 * agent-hierarchy — /agent-roster CLI: deterministic roster + team file I/O.
 * Modelled on msg.mjs. Interactive prompting (AskUserQuestion, ListAgents
 * polling, actually spawning sessions) is the SKILL.md's job; this CLI does
 * validation and reads/writes only, so validation lives in one place.
 *
 *   roster.mjs show   [global|repo|repo-user] [--level L] [--cwd <path>]
 *   roster.mjs init    [level] [--level L] --route <peer|subagent> [--cwd <path>]
 *   roster.mjs add     [level] [--level L] --role <R> [--model M] [--effort E]
 *                       [--route peer|subagent] [--auto-mode A] [--cwd <path>]
 *   roster.mjs edit    [level] [--level L] --member <NAME> [--role R] [--model M]
 *                       [--effort E] [--route ...] [--auto-mode A] [--cwd <path>]
 *   roster.mjs remove  [level] [--level L] --member <NAME> [--cwd <path>]
 *   roster.mjs create  [--plan] [--commit --verified <json> --transport <t>
 *                       --roster-level <L> [--partial]
 *                       [--orchestrator-pid <pid>]] [--cwd <path>]
 *   roster.mjs disband [--cwd <path>]
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
import { clearTeam, readTeam, ROSTER_ROUTE_VALUES, validateMember, validateRosterBlock, writeTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "plan", "commit", "partial"]);

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
  // herdr's own `--name` positional already names the pane/agent — duplicating
  // it after `--` would pass claude a second, redundant --name.
  const agentFlags = [`--agent ah:${member.role}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null].filter(Boolean);
  const claudeFlags = [...agentFlags, `--name ${member.name}`];
  const claudeCmd = `claude ${claudeFlags.join(" ")}`;
  if (transport === "herdr") return { transport, steps: [`herdr pane split --current --direction right --cwd "${cwd}" --no-focus`, `herdr agent start ${member.name} --kind claude --pane <pane-id-from-split> -- ${agentFlags.join(" ")}`] };
  if (transport === "tmux") return { transport, steps: [`tmux new-window -c "${cwd}"`, `tmux send-keys ${JSON.stringify(claudeCmd)} Enter`] };
  return { transport, steps: [`${claudeCmd} --bg`] };
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
          roster: data.roster && data.roster.members ? { route: data.roster.route, members: namedMembers(data.roster.members) } : null,
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
      out({ level: resolved.level, path: resolved.path, transport, members: plan });
      break;
    }

    case "disband": {
      const dir = hierarchyDir(cwd);
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
      fail(`usage: roster.mjs show|init|add|edit|remove|create|disband [--level global|repo|repo-user] [--cwd <path>]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
