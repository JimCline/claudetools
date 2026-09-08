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
 *                       [--route peer|subagent|pane] [--kind K] [--args '<json>'] [--auto-mode A]
 *                       [--on-missing auto|prompt|never] [--cwd <path>]
 *                       (spec 0044 §1.10: writes the roster template and spawns NOTHING —
 *                        supersedes spec 0039's auto-spawn. Use spawn-one, or spawn-ad-hoc.)
 *   roster.mjs edit    [level] [--level L] --member <NAME> [--role R] [--model M]
 *                       [--effort E] [--route ...] [--auto-mode A] [--on-missing auto|prompt|never] [--cwd <path>]
 *   roster.mjs remove  [level] [--level L] --member <NAME> [--cwd <path>]
 *   roster.mjs layout  [level] [--level L] [--layout <auto|columns|grid>] [--cwd <path>]
 *   roster.mjs create  [--plan] [--commit --verified <json> --transport <t>
 *                       (--verified: JSON array of member objects from the spawn/check-in
 *                       cycle, OR a JSON array of member-name strings hydrated from the
 *                       --roster-level roster)
 *                       --roster-level <L> [--partial]
 *                       [--orchestrator-pid <pid>]] [--cwd <path>]
 *   roster.mjs create  --spawn --mode <auto|columns|grid> [--roster-level <L>] [--cwd <path>]
 *   (`--spawn` launches only; `--commit` persists. Both are required, in that order.)
 *   roster.mjs next-split --mode <auto|columns|grid> --pane-count <N> --self <pane-id>
 *                       --created '<json array of pane ids>'
 *                       --geometry '<json array of {pane_id, rect}>'
 *   roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--cwd <p>]
 *                       (or --next --created <json>, or --apply --target <id> --direction <right|down>)
 *   roster.mjs disband [--commit|--keep-sessions] [--cwd <path>]
 *   roster.mjs dismiss <name> [--plan] [--cwd <path>] [--team <T>]
 *   roster.mjs dismiss <name> --close --confirm --plan-token <tok> [--allow-global] [--cwd <path>] [--team <T>]
 *   roster.mjs dismiss <name> --commit [--also-config] [--level L] [--cwd <path>] [--team <T>]
 *   roster.mjs resync  [--dry-run] [--cwd <path>]
 *   roster.mjs move    <name> --tab <tab_id> [--split right|down]
 *                       <name> --new-tab [--workspace <id>]
 *                       <name> --new-workspace
 *                       [--dry-run] [--cwd <path>]
 *   roster.mjs spawn-one <role> [--member <name>] [--cwd <path>] [--dry-run] [--allow-global] [--orchestrator-pid <pid>]
 *   roster.mjs spawn-ad-hoc <role> [--model M] [--effort E] [--route peer|pane] [--kind K]
 *                       [--args '<json>'] [--auto-mode A] [--on-missing ...] [--team T]
 *                       [--dry-run] [--allow-global] [--orchestrator-pid <pid>] [--cwd <path>]
 *                       (spec 0044 §1.4: spawn a member the roster does not define, or one whose
 *                        parameters diverge from it. Writes ONLY the team file — never the roster.)
 *   roster.mjs alias   [--level global|repo|repo-user] [--set <name>] [--clear] [--cwd <path>]
 *   roster.mjs teams   [--cwd <path>] [--orchestrator-pid <pid>]
 *   roster.mjs reap    [--commit] [--cwd <path>]
 *                       (bare: lists orphaned team records — dead/null orchestrator pid,
 *                       age never a factor — and deletes nothing; --commit removes them.)
 *   roster.mjs history [--cwd <path>]
 *   roster.mjs create  --from <id|alias> [--team <T>] [--plan|--commit|--spawn] [--cwd <path>]
 *   roster.mjs adopt   --orchestrator-pid <pid> [--team <T>] [--cwd <path>]
 *   roster.mjs checkin [--team <T>] [--cwd <path>] [--orchestrator-pid <pid>]
 *                       (spec 0036 §3.3: re-registers the current session with its current cwd;
 *                       exits non-zero when still misplaced relative to the team's expected_root.
 *                       Resolves the session pid the same way as create --commit/teams — process.ppid
 *                       is the transient Bash-tool shell, never the session, at this call site.)
 *
 * Spec 0044: the roster is a read-only TEMPLATE for the whole team lifecycle. `init`/`add`/`edit`/
 * `remove`/`layout`/`alias` write roster level files and spawn nothing; every other command writes
 * only a team file. A session that owns a live team is refused a roster edit (§1.3) unless the USER
 * passes `--allow-roster-edit` — no code path may supply that flag on the user's behalf. A team with
 * no `--team` lives at `teams/<effective-prefix>.json`, not the shared `team.json`; an existing
 * `team.json` keeps being used, unmigrated, until its own team disbands (§1.7).
 *
 * `--team <name>` (spec 0011 §5.1) selects a named team's `teams/<name>.json`
 * in place of the default `team.json`, on every subcommand above that touches
 * a team file; omitted, everything resolves the default team exactly as
 * before. `create --team <T>` (§5.2) writes `teams/<T>.json`.
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
import { createHash } from "node:crypto";
import { dirname } from "node:path";

import { CONFIG_VERSION, findGitRoot, hierarchyDir, PEER_ELIGIBLE_ROLES, ROLES, ROLE_DEFAULTS, ROSTER_LEVELS, resolveRoster, rosterLevelPaths, rosterMemberNames, teamPrefix, teamPrefixInfo, validateHerdrName, validateTeamAlias } from "./lib-config.mjs";
import { appendRosterRecord, latestRoster, livePeerSlots, newId, localIso, pidAlive, realCwd, recordLiveness } from "./lib-hier.mjs";
import { attributeSessionTeam, clearTeam, defaultTeamScope, fingerprint, herdrOnPath, historyEntryIsActive, KIND_DEFAULT, kindFieldErrors, listTeamNames, memberArgs, normalizeMembers, readHistory, readTeam, resolveKind, ROSTER_LAYOUT_VALUES, ROSTER_ROUTE_VALUES, routeHasPane, teamIsLive, teamIsOrphaned, teamMemberNameSet, teamPath, upsertHistory, validateMember, validateRosterBlock, validateTeamMember, writeTeam } from "./lib-roster.mjs";

const BOOL_FLAGS = new Set(["plain", "json", "plan", "commit", "partial", "manual", "next", "apply", "kill", "keep-sessions", "spawn", "dry-run", "new-tab", "new-workspace", "allow-global", "clear", "close", "confirm", "also-config", "no-spawn", "allow-roster-edit"]);
const DISBAND_FLAGS = new Set(["kill", "commit", "keep-sessions", "plan", "close", "confirm", "plan-token", "allow-global", "cwd", "team"]);
const DISMISS_FLAGS = new Set(["plan", "close", "commit", "confirm", "plan-token", "also-config", "level", "allow-global", "cwd", "team"]);
const RESYNC_FLAGS = new Set(["dry-run", "cwd", "team", "bind"]);
const MOVE_FLAGS = new Set(["tab", "split", "new-tab", "workspace", "new-workspace", "dry-run", "allow-global", "cwd", "team"]);
const SPAWN_ONE_FLAGS = new Set(["cwd", "dry-run", "allow-global", "team", "orchestrator-pid", "member"]);
/** Spec 0044 §1.4: the member-spec flags `add` takes, plus the spawn-side ones `spawn-one` takes.
    No `--level` and no `--member`: an ad hoc member has no roster level to land in, and its name
    is derived (point 5), never supplied. */
const AD_HOC_FLAGS = new Set(["role", "model", "effort", "route", "kind", "args", "auto-mode", "on-missing", "cwd", "dry-run", "allow-global", "team", "orchestrator-pid"]);
/** Spec 0044 §1.2/§1.3: the commands whose PURPOSE is writing a roster level file. The same list
    §1.5 classifies as legitimate roster writers and §8.1 puts on the `/agent-roster` surface —
    one list, so the gate and the surface split cannot drift apart. */
const ROSTER_MUTATING_CMDS = new Set(["init", "add", "edit", "remove", "layout", "alias"]);
const ALIAS_FLAGS = new Set(["level", "set", "clear", "cwd", "team", "allow-roster-edit", "orchestrator-pid"]);
const ADOPT_FLAGS = new Set(["orchestrator-pid", "team", "cwd"]);
const REAP_FLAGS = new Set(["commit", "cwd"]);
const CHECKIN_FLAGS = new Set(["cwd", "team", "orchestrator-pid"]);

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

/** `--team <name>` (spec 0011 §5.1), validated once with the same validator 0010's alias uses. */
function resolveTeamArg() {
  if (typeof opts.team !== "string") return null;
  const v = validateTeamAlias(opts.team);
  if (!v.ok) fail(`--team: ${v.why}`);
  return opts.team;
}
// `create --from` without an explicit --team defaults the team scope to the entry's own stored
// alias (spec 0015 §7.2) — the `create` case reassigns both before anything else reads them.
let teamArg = resolveTeamArg();
let repoBasename = teamPrefix(cwd, teamArg);

/**
 * Spec 0044 §1.1: which team FILE this invocation reads and writes. Deliberately NOT `teamArg`,
 * which also selects the roster CONFIG container (`rosters.<team>`) — defaulting that would make a
 * bare `add` start writing `rosters.<repo>` instead of `roster`. Two axes, two variables.
 *
 * `repoBasename` is unaffected either way: `teamPrefixInfo(cwd, "<X>")` returns prefix `<X>`, so
 * the derived default scope has the same prefix the unscoped path already computed. That identity
 * is what makes §1.1's migration claim true — only the file location moves, never the names.
 */
let teamFile = teamArg;
/** No `--team` was given, so the scope was derived — which is what decides whether a collision
    suggests a free candidate (§1.1) or tells the user to disband the team they named. */
let teamFileDefaulted = false;
function resolveTeamFileScope() {
  if (teamArg) {
    teamFile = teamArg;
    teamFileDefaulted = false;
    return;
  }
  const scope = defaultTeamScope(hierarchyDir(cwd), teamPrefix(cwd, null));
  teamFile = scope.team;
  teamFileDefaulted = scope.defaulted;
}
resolveTeamFileScope();

function levelArg() {
  if (typeof opts.level === "string") return opts.level;
  const bare = opts._[0];
  return typeof bare === "string" && ROSTER_LEVELS.includes(bare) ? bare : null;
}

function requireLevel(explicit) {
  if (!ROSTER_LEVELS.includes(explicit)) fail(`--level must be one of ${ROSTER_LEVELS.join(", ")}, got ${JSON.stringify(explicit)}`);
  return explicit;
}

/** For add/edit/remove: explicit --level, else whichever level currently resolves. Returns
    {level, wasDefaulted, teamKey}. `teamKey` is always the active `--team` scope (never
    resolveRoster's possibly-null match) — a write must target `rosters.<team>` whenever a
    team scope is active, even the first time, before any override exists anywhere (spec 0032
    §3.4: writing to `data.roster` while `--team` is active is the corruption this guards). */
// Spec 0038 §1.1 leaves the bootstrapped container's route unspecified, and the plugin has no
// roster-level default (a session's dispatch route "unset stays null"). "peer" is the superset:
// it tries a live peer first and falls back to a subagent, so nothing is foreclosed.
// Overridden by an explicit `add --route`.
const AUTO_INIT_ROUTE = "peer";

function targetLevel({ allowMissing = false } = {}) {
  const explicit = levelArg();
  if (explicit) return { level: requireLevel(explicit), wasDefaulted: false, teamKey: teamArg };
  const resolved = resolveRoster(cwd, teamArg);
  if (resolved) return { level: resolved.level, wasDefaulted: true, teamKey: teamArg };
  // Spec 0038 §1.1: with nothing resolving anywhere, `add` (only) may bootstrap at the same
  // default `targetLevel` would otherwise have picked — repo level when cwd is inside a git
  // repo. Team-scoped (§1.2, 0032 §3.4b) and non-repo cwds keep the existing failure.
  if (allowMissing && !teamArg) {
    if (findGitRoot(cwd)) return { level: "repo", wasDefaulted: true, teamKey: teamArg };
    // Spec 0038 §1.1: no git root → no auto-create; a bare `add` outside any repo must not write
    // the user-wide file as a side effect. The escape is explicit.
    fail(`no roster resolves at any level and ${cwd} is not inside a git repo — re-run with --level global to create the user-wide roster (~/.claude/agent-hierarchy.json), or cd into a repo`);
  }
  fail("no roster resolves at any level — run `roster.mjs init` first");
}

/** Spec 0038 §1.1 "one writer": the roster block `init` creates, shared with `add`'s auto-init so
    the shape is serialized in exactly one place (0035 §11's duplicate-representation family). */
function freshRosterBlock(route, layout) {
  if (!ROSTER_ROUTE_VALUES.includes(route)) fail(`--route must be "peer" or "subagent", got ${JSON.stringify(route)}`);
  const fresh = { route, members: [] };
  if (typeof layout === "string") {
    if (!ROSTER_LAYOUT_VALUES.includes(layout)) fail(`--layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(layout)}`);
    fresh.layout = layout;
  }
  return fresh;
}

/** Install a fresh block as the container for `teamKey` (`roster`, or `rosters.<team>`) — replaces wholesale. */
function installRosterBlock(data, teamKey, fresh) {
  data.version = data.version || CONFIG_VERSION;
  if (!teamKey) data.roster = fresh;
  else {
    data.rosters ||= {};
    data.rosters[teamKey] = fresh;
  }
}

/** The roster container to read/write at this level for the active team scope (spec 0032 §3.4).
    Never creates a container — `init` is the only path that may (spec 0032 §3.4b). No site may
    reach `data.roster` directly while a `--team` scope is active. */
function rosterContainer(data, teamKey) {
  if (!teamKey) return data.roster || null;
  return data.rosters && data.rosters[teamKey] ? data.rosters[teamKey] : null;
}

/** "roster" or `rosters.<name>` — for output/warning text naming which container a write hit (spec 0032 §3.4 point 5). */
function containerLabel(teamKey) {
  return teamKey ? `rosters.${teamKey}` : "roster";
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

/**
 * Spec 0043 §1.9: `--args` carries a JSON array of native CLI arguments for a non-claude kind.
 * Only the JSON shape is decoded here — whether the decoded value is a legal `args` (array of
 * non-empty strings, absent for kind claude) is `kindFieldErrors`' single answer, so the CLI and
 * a hand-edited config file are judged by exactly the same rule.
 *
 * An empty array clears the field (§1.9 makes absent and `[]` equivalent).
 */
function parseArgsFlag(value, cmd) {
  if (value === true) fail(`${cmd}: --args requires a value — a JSON array of strings, e.g. --args '["--profile","fast"]'`);
  const raw = String(value).trim();
  if (!raw) return null;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail(`${cmd}: --args must be a JSON array of strings, e.g. --args '["--profile","fast"]' (could not parse ${JSON.stringify(raw)})`);
  }
  if (Array.isArray(parsed) && parsed.length === 0) return null;
  return parsed;
}

/**
 * Spec 0043 §1.7: any member launched through Herdr — every non-claude member by §1.4, and a
 * claude member on the herdr transport — must have a name Herdr will accept. Checked against the
 * DERIVED name at add/edit, which is the only place it can be reported usefully; `validateMember`
 * cannot host it because it rejects a member carrying a stored `name` at all.
 *
 * Pre-existing latent defect for long repo basenames; in scope here because a non-claude member
 * has no non-Herdr transport to fall back to, so for it the failure is unconditional.
 */
function requireHerdrName(member, cmd) {
  if (!routeHasPane(member.route)) return;
  const check = validateHerdrName(member.name);
  if (check.ok) return;
  // A non-claude kind has no non-Herdr transport to fall back to (§1.4), so an unusable name is
  // an unconditional failure and must be refused now.
  if (resolveKind(member) !== KIND_DEFAULT) fail(`${cmd}: ${check.why}`);
  // A claude member still launches fine on tmux/terminal with a name Herdr would reject — a repo
  // directory containing a space is the common case, and tests/test-roster-spawn-cwd.sh asserts
  // it works. Spec 0043 §1.7 asks for this to be rejected for both kinds, but §3 forbids changing
  // the claude path "with or without Herdr", so this warns rather than refusing. See the spec-gap
  // note in the implementation report — this is the Architect's call to settle, not mine.
  process.stderr.write(`roster.mjs: warning — ${check.why}. This member spawns fine on the tmux/terminal transport, but \`herdr agent start\` will reject the name.\n`);
}

/**
 * Spec 0044 §1.4 point 1: the member-shaped fields `--role/--model/--effort/--route/--kind/--args/
 * --auto-mode/--on-missing` decode to, shared by `add` (which writes the result to the roster) and
 * `spawn-ad-hoc` (which writes it to the team file). One decoder, so "the same fields `add`
 * accepts" stays true by construction rather than by two lists agreeing today.
 *
 * Validation is NOT done here — the caller validates against its own effective route, which is the
 * roster block's for `add` and the member's own for an ad hoc spawn.
 */
function memberFromFlags(role, cmdLabel) {
  if (opts.kind === true) fail(`${cmdLabel}: --kind requires a value (e.g. claude, codex, pi)`);
  const kind = typeof opts.kind === "string" ? opts.kind : KIND_DEFAULT;
  // Spec 0043 §1.3 (the role-default trap): ROLE_DEFAULTS fills `model` whenever --model is
  // absent. Applied to a non-claude member that model would then be rejected by §1.3's own
  // rule, making non-claude members impossible to create. The default is claude-only.
  const defaultedModel = kind === KIND_DEFAULT ? (ROLE_DEFAULTS[role] || {}).model : undefined;
  const member = { role, model: typeof opts.model === "string" ? opts.model : defaultedModel };
  if (member.model === undefined) delete member.model;
  if (kind !== KIND_DEFAULT) member.kind = kind;
  if (typeof opts.effort === "string") member.effort = opts.effort;
  if (typeof opts.route === "string") member.route = opts.route;
  if (typeof opts["auto-mode"] === "string") member.autoMode = opts["auto-mode"];
  // §1.9 makes absent and `[]` equivalent, so an empty --args omits the key rather than
  // writing `"args": null`.
  if (opts.args !== undefined) {
    const parsed = parseArgsFlag(opts.args, cmdLabel);
    if (parsed !== null) member.args = parsed;
  }
  if (opts["on-missing"] === true) fail(`${cmdLabel}: --on-missing requires a value (auto, prompt, or never)`);
  if (typeof opts["on-missing"] === "string") member.onMissing = opts["on-missing"];
  return member;
}

function findMemberIndex(members, name) {
  return namedMembers(members).findIndex((m) => m.name === name);
}

/** Spec 0020 §3.5/§3.6: remove one member by derived name from a roster CONFIG level (the
    template for future teams) — shared by `remove` and `dismiss --also-config` so there is
    exactly one config-edit path. Resolves the level exactly as `remove` always has
    (targetLevel()). Writes nothing when the member isn't found. */
function removeConfigMember(name) {
  const { level, wasDefaulted, teamKey } = targetLevel();
  const path = rosterLevelPaths(cwd)[level];
  const data = readLevelFile(path);
  const container = rosterContainer(data, teamKey);
  if (!container || !Array.isArray(container.members)) {
    return { level, path, wasDefaulted, removed: false, reason: `no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init\` first` };
  }
  const idx = findMemberIndex(container.members, name);
  if (idx === -1) return { level, path, wasDefaulted, removed: false, reason: "no such member" };
  const before = namedMembers(container.members);
  // Spec 0032 §3.4 point 4: splice only — never delete the container itself, even down to
  // members: []. An empty rosters.<team> block and an absent one differ (the former still
  // no-matches per §3.2's guard, but only `remove --team X --all` may erase the block).
  container.members.splice(idx, 1);
  const after = namedMembers(container.members);
  writeLevelFile(path, data);
  return { level, path, wasDefaulted, removed: true, idx, before, after, container: containerLabel(teamKey) };
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

/**
 * Single-quote one string for `/bin/sh -c` (spec 0043 §1.9). `args` is the first member field
 * whose value is authored as free text and interpolated into `runShell`'s command string, so an
 * element containing `;`, a backtick, `$(…)` or a redirect would otherwise execute as shell
 * syntax instead of arriving as one argument. Same class of reason as the tmux branch's
 * `JSON.stringify` below.
 */
function shQuote(s) {
  return `'${String(s).split("'").join(`'\\''`)}'`;
}

/**
 * The single launch-shape seam (spec 0009 §6.3) — `spawn-one`, `create --spawn` and history
 * replay all build their command here. Spec 0043 §1.4 branches it on `kind`: a claude member's
 * string is unchanged byte-for-byte (§3/§4.1), and every other kind gets Herdr's own `--kind`
 * with its native arguments after `--`. No `--timeout` on either path — r6 dropped it once
 * Herdr's own default was confirmed to be the same value it was passing.
 */
function spawnShape(member, transport) {
  const kind = resolveKind(member);
  const isClaude = kind === KIND_DEFAULT;
  // §1.9: `add`/`edit` already refuse these combinations, but a hand-edited config reaches this
  // function without passing through either — and for `args` on a claude member the consequence
  // is an unvalidated second channel for --model/--permission-mode, so re-check here.
  const configErrors = kindFieldErrors(member);
  if (configErrors.length) {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name} (kind ${kind}) has an invalid configuration: ${configErrors.join("; ")}` };
  }
  // §1.4: forced by F2 — the tmux branch sends the literal string `claude <flags>` into a pane
  // and the terminal branch execs `claude`; neither can start another kind, and teaching them
  // each kind's binary would duplicate knowledge Herdr owns. Refuse rather than launch a claude.
  if (!isClaude && transport !== "herdr") {
    return { transport, kind, layout: [], launch: [], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null, refuse: `member ${member.name} has kind ${JSON.stringify(kind)}, which requires the herdr transport, but the detected transport is ${JSON.stringify(transport)} — start a Herdr session (HERDR_ENV=1) to spawn non-claude kinds` };
  }
  // §1.4: emitted only for kind claude — `--agent ah:<role>` is a Claude Code plugin-agent
  // reference and --model/--effort/--permission-mode are Claude CLI flags (§F3, §1.8).
  const agentFlags = isClaude
    ? [`--agent ah:${member.role}`, `--name ${member.name}`, member.model && member.model !== "inherit" ? `--model ${member.model}` : null, member.effort ? `--effort ${member.effort}` : null, member.autoMode ? `--permission-mode ${member.autoMode}` : null].filter(Boolean)
    : [];
  const nativeArgs = isClaude ? null : memberArgs(member);
  const claudeCmd = `claude ${agentFlags.join(" ")}`;
  if (transport === "herdr") return {
    transport,
    kind,
    args: nativeArgs ? [...nativeArgs] : null,
    // Layout is team-level and geometry-dependent: `roster.mjs layout-splits` computes and
    // performs the split sequence from live `herdr pane layout` output. See spec 0004 §3.2.
    layout: [],
    launch: [
      isClaude
        ? `herdr agent start ${member.name} --kind claude --pane <TARGET> -- ${agentFlags.join(" ")}`
        : `herdr agent start ${member.name} --kind ${kind} --pane <TARGET>${nativeArgs ? ` -- ${nativeArgs.map(shQuote).join(" ")}` : ""}`,
    ],
    // Placement comes from the layout step's own --cwd (runLayoutLoop :641), not from here —
    // carried for output parity (spec 0035 §2.2/§2.4).
    launch_cwd: cwd,
    target_placeholder: "<TARGET>",
    target_from: null,
    target_source: { kind: "json", path: ".result.pane.pane_id" },
  };
  if (transport === "tmux") return {
    transport,
    kind,
    args: null,
    // -P -F prints the new window's pane id: an untargeted `send-keys` writes to
    // whatever pane is active, which cannot survive two launches being in flight.
    layout: [`tmux new-window -P -F '#{pane_id}' -c "${cwd}"`],
    launch: [`tmux send-keys -t <TARGET> ${JSON.stringify(claudeCmd)} Enter`],
    // Placement comes from the layout step's own -c above, not from here — carried for output
    // parity (spec 0035 §2.2/§2.4).
    launch_cwd: cwd,
    target_placeholder: "<TARGET>",
    target_from: 0,
    target_source: { kind: "stdout", trim: true },
  };
  // Spec 0035 §2: the only branch with no separate layout step, so launch_cwd here is not just
  // for output parity — launchMember must actually apply it (§2.3), or the child inherits
  // roster.mjs's own process cwd instead of the resolved --cwd.
  return { transport, kind, args: null, layout: [], launch: [`${claudeCmd} --bg`], launch_cwd: cwd, target_placeholder: null, target_from: null, target_source: null };
}

/** Plan-level herdr layout instructions for the orchestrator to drive (spec 0004 §5.2). Null for non-herdr or an all-subagent roster. */
function layoutPlan(resolved, transport, plan) {
  if (transport !== "herdr") return null;
  const paneCount = plan.filter((m) => routeHasPane(m.route)).length;
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
function herdrCall(args, opts = {}) {
  const timeout = Number(process.env.AH_HERDR_TIMEOUT_MS || 10000);
  let stdout;
  try {
    stdout = execFileSync("herdr", args, { encoding: "utf8", timeout, maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    // Spec 0043 §1.6: `herdr agent get` on a missing name exits 1 and writes its error as JSON
    // on STDOUT, not stderr — so the failure path has to be inspectable, not just thrown. Kept
    // inside this function rather than adding a second exec site: spec 0002 §11.3's grep
    // assertion requires `herdr` to be spawned from exactly one place.
    if (opts.allowFailure && !err.signal) {
      return { ok: false, stdout: err.stdout ? String(err.stdout) : "", stderr: err.stderr ? String(err.stderr) : "", status: typeof err.status === "number" ? err.status : null };
    }
    if (err.signal) throw new Error(`herdr ${args.join(" ")} timed out after ${timeout}ms`);
    throw new Error(`herdr ${args.join(" ")} failed: ${(err.stderr && String(err.stderr).trim()) || err.message}`);
  }
  if (opts.allowFailure) return { ok: true, stdout, stderr: "", status: 0 };
  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(`herdr ${args.join(" ")} produced unparseable output`);
  }
}

/**
 * Spec 0043 §1.6: liveness AND readiness for a non-claude member, from `herdr agent get <name>`.
 * These are two different predicates for a Herdr-driven agent (they collapse into one only for a
 * Claude peer): a `blocked` agent sitting on a startup prompt is unambiguously LIVE — spawning a
 * second under the same name would be wrong — and unambiguously NOT READY.
 *
 * Three-way by design. "Herdr could not answer" is NOT "the agent is dead": the first thing a
 * caller does with "dead" is spawn a replacement, so a transient daemon outage would become
 * duplicate agents under names Herdr requires to be unique. Indeterminate must refuse the
 * operation instead.
 *
 * Returns `{live, indeterminate, why, agent_status, ready}`.
 */
const HERDR_LIVE_STATES = ["idle", "working", "blocked", "done", "unknown"];

function herdrAgentState(name) {
  if (!herdrOnPath()) {
    return { live: false, indeterminate: true, why: "no `herdr` binary on PATH — cannot ask whether this agent is live", agent_status: null, ready: false };
  }
  let res;
  try {
    res = herdrCall(["agent", "get", name], { allowFailure: true });
  } catch (err) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} failed: ${err.message}`, agent_status: null, ready: false };
  }
  let parsed = null;
  for (const stream of [res.stdout, res.stderr]) {
    if (typeof stream !== "string" || !stream.trim()) continue;
    try {
      parsed = JSON.parse(stream);
      break;
    } catch {
      // try the other stream
    }
  }
  if (!parsed) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} produced unparseable output`, agent_status: null, ready: false };
  }
  const code = parsed.error && parsed.error.code;
  // The ONLY signal that means "no such agent". Any other error code is Herdr failing to answer.
  if (code === "agent_not_found") {
    return { live: false, indeterminate: false, why: "agent_not_found", agent_status: null, ready: false };
  }
  if (code) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned error code ${JSON.stringify(code)}`, agent_status: null, ready: false };
  }
  const agent = parsed.result && parsed.result.agent;
  if (!agent || typeof agent !== "object") {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned no .result.agent`, agent_status: null, ready: false };
  }
  const status = typeof agent.agent_status === "string" ? agent.agent_status : null;
  // A non-claude record carries no `agent_session` key and a claude one does — deliberately NOT
  // branched on, so both kinds take one code path through `agent_status`.
  //
  // §1.6's "anything else" row: only a status Herdr has told us is terminal can mean not-live.
  // A missing status, or one this build does not recognize (a newer Herdr, a state added later),
  // is Herdr declining to answer — indeterminate. Reading it as a definite not-live is the
  // duplicate-spawn bug: the caller starts a second agent under a name Herdr requires unique.
  if (status === null) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned no agent_status`, agent_status: null, ready: false };
  }
  // §1.6's table has exactly ONE not-live row — exit 1 with `agent_not_found`, handled above.
  // A status outside the live set is therefore not a fifth terminal state this build happens not
  // to know; it is Herdr saying something this build cannot interpret, which is the "anything
  // else" row.
  if (!HERDR_LIVE_STATES.includes(status)) {
    return { live: false, indeterminate: true, why: `herdr agent get ${name} returned unrecognized agent_status ${JSON.stringify(status)}`, agent_status: status, ready: false };
  }
  const live = true;
  // Readiness: Herdr's own cross-kind normalized answer. ABSENT IS NOT FALSE — the field was not
  // present on the claude payload, and reading absent-as-false would mark every ready Claude
  // member unpromptable. Absent falls back to the lifecycle set.
  const ready =
    agent.interactive_ready === undefined || agent.interactive_ready === null
      ? status !== null && ["idle", "done"].includes(status)
      : agent.interactive_ready === true;
  return { live, indeterminate: false, why: `agent_status ${status}`, agent_status: status, ready };
}

/**
 * Live herdr topology: agent name (if any) plus pane/tab/workspace ids for every live pane
 * (spec 0008 §5.2). `herdr agent list` is the preferred single-call source — field names
 * (`.result.agents[].{name?,pane_id,tab_id,workspace_id}`) verified against a live herdr this
 * session; `name` is absent for a pane hosting no `herdr agent start`-named agent. `cwd` (spec
 * 0025 §12.3) is read from either `cwd` or `foreground_cwd` — the true key is unconfirmed and
 * this repo consumed neither before now, so both are read as cheap insurance.
 */
function queryHerdrTopology() {
  const result = herdrCall(["agent", "list"]);
  const agents = result && result.result && Array.isArray(result.result.agents) ? result.result.agents : null;
  if (!agents) throw new Error("herdr agent list produced unexpected shape (missing .result.agents)");
  return agents.map((a) => ({ name: a.name || null, pane_id: a.pane_id, tab_id: a.tab_id, workspace_id: a.workspace_id, cwd: a.cwd || a.foreground_cwd || null }));
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
 * Pure heal pass over `team.members` against live herdr topology (spec 0008 §5.1, multi-pass
 * matching added spec 0025 §12.3-§12.6). No I/O beyond the topology query and, when `dir`/`teamCwd`
 * are supplied, reading peers.jsonl — never writes team.json. Shared by `resync` (persists the
 * result, and the only caller that can supply `dir`/`teamCwd`/`selfPaneId`/`bind`) and `disband`'s
 * bare/`--plan` path plus `move` (both call with no options object, so passes 2/3 and `--bind` are
 * inert and behavior is byte-identical to before this amendment).
 *
 * Returns `{ members, counts, query_ok, query_error, warning?, bind_error? }`; on topology-query
 * failure `members`/`counts` are null and the caller decides whether to fail() (resync/move) or
 * degrade (disband). On a `--bind` validation failure `members`/`counts` are also null (no partial
 * application) and `bind_error` names the problem — the caller must fail() before any write.
 *
 * Pass 1 (identity, via `matchMemberToPane`) is unchanged in behavior. Passes 2 (peers.jsonl exact
 * match) and 3 (cwd narrowing) consider only members pass 1 left `not_found` with `transport_id ===
 * null` — a member that HAD a transport_id and failed pass 1 stays `not_found` forever, since it
 * moved or died and a weaker signal must not re-home it onto another session's pane.
 */
function resyncMembers(team, { dir = null, teamCwd = null, selfPaneId = null, bind = null } = {}) {
  let topology;
  try {
    topology = queryHerdrTopology();
  } catch (err) {
    return { members: null, counts: null, query_ok: false, query_error: err.message };
  }
  const claimed = new Set();
  let duplicate = false;
  const counts = { updated: 0, unchanged: 0, not_found: 0, skipped: 0, malformed: 0, ambiguous: 0 };

  // Pass 1 — identity. Behavior for every member matching here is unchanged from before §12.3.
  const members = team.members.map((m) => {
    // Spec 0025 §6: a malformed (non-object) entry must round-trip byte-identical, never `{ ...m }` —
    // spreading a string produces exactly the char-indexed garbage that corrupted team.json in the wild.
    if (!m || typeof m !== "object" || Array.isArray(m)) {
      counts.malformed++;
      return m;
    }
    if (!routeHasPane(m.route)) {
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

  // --bind (spec 0025 §12.5): validate every entry as a WHOLE before applying any of them, so a
  // validation failure never partially writes. Claims its panes before pass 2, so an explicit
  // instruction always outranks an inferred one.
  if (bind) {
    const topologyIds = new Set(topology.map((p) => p.pane_id));
    const knownNames = members.filter((m) => m && typeof m === "object" && !Array.isArray(m)).map((m) => m.name).filter(Boolean);
    // Seeded from `claimed` and grown as each entry validates, so a later entry in the SAME
    // --bind object sees an earlier entry's claim — `claimed` alone only reflects pass 1.
    const willClaim = new Set(claimed);
    for (const [name, paneId] of Object.entries(bind)) {
      const idx = members.findIndex((m) => m && typeof m === "object" && !Array.isArray(m) && m.name === name);
      if (idx === -1) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: unknown member "${name}" (known: ${knownNames.join(", ") || "none"})` };
      }
      if (!routeHasPane(members[idx].route)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: member "${name}" has route "${members[idx].route}", not "peer"` };
      }
      if (!topologyIds.has(paneId)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is not in live herdr topology` };
      }
      if (willClaim.has(paneId)) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is already claimed` };
      }
      if (selfPaneId && paneId === selfPaneId) {
        return { members: null, counts: null, query_ok: true, query_error: null, bind_error: `--bind: pane "${paneId}" (for "${name}") is the caller's own pane` };
      }
      willClaim.add(paneId);
    }
    for (const [name, paneId] of Object.entries(bind)) {
      const idx = members.findIndex((m) => m.name === name);
      const m = members[idx];
      const topo = topology.find((p) => p.pane_id === paneId);
      const from = { transport_id: m.transport_id, tab_id: m.tab_id, workspace_id: m.workspace_id };
      const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
      const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
      delete healed.transport_stale;
      claimed.add(paneId);
      // Decrement whichever bucket the member actually held before the bind — a --bind target
      // is not required to be `not_found` (spec 0025 §12.5 lists no such restriction), so it may
      // already be `updated`/`unchanged` from pass 1.
      if (m.status === "not_found") counts.not_found--;
      else if (m.status === "unchanged") counts.unchanged--;
      else if (m.status === "updated") counts.updated--;
      counts.updated++;
      members[idx] = { ...healed, status: "updated", from, to, match_by: "bind" };
    }
  }

  // Recomputed fresh each time rather than snapshotted once — pass 2's binds must be visible to
  // pass 3's gating (exactly one member still awaiting repair).
  const awaitingRepair = () =>
    members.map((m, i) => ({ m, i })).filter(({ m }) => m && typeof m === "object" && !Array.isArray(m) && m.status === "not_found" && m.transport_id == null);

  // Pass 2 — peers.jsonl exact match (spec 0025 §12.4). Only runs when the caller can locate both
  // the peer roster and the team's directory.
  if (dir && teamCwd) {
    const teamCwdReal = realCwd(teamCwd);
    const liveRoster = latestRoster(dir);
    const topologyIds = new Set(topology.map((p) => p.pane_id));
    for (const { m, i } of awaitingRepair()) {
      const candidates = liveRoster.filter(
        (rec) =>
          rec.status === "up" &&
          pidAlive(rec.pid) &&
          rec.pane_id != null &&
          rec.cwd != null &&
          realCwd(rec.cwd) === teamCwdReal &&
          rec.role === m.role &&
          topologyIds.has(rec.pane_id) &&
          !claimed.has(rec.pane_id) &&
          rec.pane_id !== selfPaneId
      );
      // Two members sharing a role and both awaiting repair each see both records here (>1), so
      // both correctly fall through to pass 3 rather than being zipped — no separate role-grouping
      // pass needed (spec 0025 §12.4, §14 item 12).
      if (candidates.length !== 1) continue;
      const rec = candidates[0];
      const topo = topology.find((p) => p.pane_id === rec.pane_id);
      claimed.add(rec.pane_id);
      counts.not_found--;
      counts.updated++;
      const from = { transport_id: null, tab_id: m.tab_id, workspace_id: m.workspace_id };
      const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
      const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
      delete healed.transport_stale;
      members[i] = { ...healed, status: "updated", from, to, match_by: "peers_jsonl" };
    }
  }

  // Pass 3 — cwd narrowing (spec 0025 §12.5-§12.6). Auto-bind only when the caller's own pane is
  // known AND excluded, exactly one candidate pane remains, and exactly one member awaits repair —
  // never zip N members onto N candidates by order (spec 0025 §14 item 9). Every other shape reports
  // `ambiguous` with the candidate list rather than guessing.
  if (teamCwd) {
    const teamCwdReal = realCwd(teamCwd);
    // Raw candidates (before self-pane exclusion) decide zero vs. many; `candidatePanes` (after
    // exclusion) decides auto-bind eligibility and what gets reported. A single raw candidate that
    // turns out to be the caller's own pane is NOT "zero" — a pane genuinely exists there, it is
    // just unsafe to guess, which is the "ambiguous" case, not "not_found" (spec 0025 §12.5,
    // Architect ruling 2026-08-27).
    const rawCandidates = topology.filter((p) => p.cwd != null && realCwd(p.cwd) === teamCwdReal && !claimed.has(p.pane_id));
    const candidatePanes = rawCandidates.filter((p) => p.pane_id !== selfPaneId);
    const awaiting = awaitingRepair();
    const autoBindEligible = selfPaneId != null && candidatePanes.length === 1 && awaiting.length === 1;
    for (const { m, i } of awaiting) {
      if (autoBindEligible) {
        const topo = candidatePanes[0];
        claimed.add(topo.pane_id);
        counts.not_found--;
        counts.updated++;
        const from = { transport_id: null, tab_id: m.tab_id, workspace_id: m.workspace_id };
        const to = { transport_id: topo.pane_id, tab_id: topo.tab_id, workspace_id: topo.workspace_id };
        const healed = { ...m, transport_id: to.transport_id, tab_id: to.tab_id, workspace_id: to.workspace_id };
        delete healed.transport_stale;
        members[i] = { ...healed, status: "updated", from, to, match_by: "cwd" };
      } else if (rawCandidates.length === 0) {
        // Nothing ambiguous about a member with no candidate pane — it is simply not running,
        // which is what `not_found` already means on the pass-1 path. `transport_stale` means
        // "the id we had is now wrong"; a repair-case member never had one, so strip it.
        const { transport_stale, ...clean } = m;
        members[i] = { ...clean, status: "not_found" };
      } else {
        counts.not_found--;
        counts.ambiguous++;
        members[i] = {
          ...m,
          status: "ambiguous",
          candidates: candidatePanes.map((p) => ({ pane_id: p.pane_id, tab_id: p.tab_id, workspace_id: p.workspace_id, cwd: p.cwd })),
        };
      }
    }
  }

  return { members, counts, query_ok: true, query_error: null, warning: duplicate ? "duplicate pane match" : undefined };
}

/** Strip resyncMembers()'s per-pass bookkeeping fields before a healed member array is persisted. */
function stripResyncMeta(m) {
  // A malformed (non-object) passthrough must stay byte-identical — object-destructuring a
  // string here would recreate the same char-indexed corruption this guards against (spec 0025 §6).
  if (!m || typeof m !== "object" || Array.isArray(m)) return m;
  const { status, from, to, match_by, candidates, ...member } = m;
  return member;
}

/** Spec 0008 §4: the no-op reason for a non-herdr transport, shared by `resync` and `move`. */
function transportNoop(transport) {
  return transport === "tmux" ? "transport tmux not supported (spec 0008 §4)" : "transport terminal has no panes";
}

/** Spec 0004 §6.6 sequential split loop, shared by `layout-splits` (bare form) and `create --spawn`'s layout phase (spec 0005 §4 step 3). Stops at the first failure. */
function runLayoutLoop({ mode, paneCount, self, splitCwd, seedPanes = [] }) {
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

    // Seed the candidate set with sibling panes that are actually on screen right now.
    // Filtered against live geometry every iteration: a stale transport_id in team.json is
    // routine (it is why `resync` exists), and an absent candidate is a hard fail in nextSplit.
    const present = new Set(geometry.map((g) => g.pane_id));
    const liveSeed = [...new Set(seedPanes)].filter((id) => id !== self && present.has(id));

    const decision = nextSplit({
      mode,
      paneCount: liveSeed.length + paneCount, // live total: what is on screen + what we are adding
      self,
      created: [...liveSeed, ...panes],
      geometry,
    });
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

/** Spec 0011 §7.2: `--team <T>` cannot equal the effective unscoped prefix while a live default team
    exists — two teams would derive the same peer names, and tagging cannot fix ListAgents' namespace. */
function guardTeamPrefixCollision(dir, team) {
  if (!team) return;
  const unscoped = teamPrefix(cwd, null);
  if (team !== unscoped) return;
  const existing = readTeam(dir, null);
  if (existing && pidAlive(existing.orchestrator && existing.orchestrator.pid)) {
    fail(`--team ${JSON.stringify(team)} equals the effective default prefix "${unscoped}", and a live default team (${existing.team_id}) already exists — pick a different --team name`);
  }
}

/** Spec 0011 §5.3: effective prefix, then -2, -3, ... until a name has no `teams/<name>.json` yet
    and is itself `validateTeamAlias`-clean. The bare prefix is never offered here — the caller only
    reaches this path because a live default team already holds it (§7.2 would refuse it anyway). */
function deriveTeamCandidate(dir, basePrefix) {
  for (let n = 2; n <= 1000; n++) {
    const candidate = `${basePrefix}-${n}`;
    if (validateTeamAlias(candidate).ok && !readTeam(dir, candidate)) return candidate;
  }
  fail(`could not derive a free --team candidate from "${basePrefix}" after 1000 attempts`);
}

/** Spec 0011 §5.3: the hybrid prompt. `create` cannot read stdin (it runs inside an agent session,
    not a TTY), so a bare `create` colliding with someone else's live default team refuses with a
    candidate name instead of guessing — SKILL.md surfaces this via AskUserQuestion. */
function refuseLiveDefaultTeam(dir, existing) {
  const basePrefix = teamPrefix(cwd, null);
  const candidate = deriveTeamCandidate(dir, basePrefix);
  fail(
    `a live team "${existing.team_id}" (orchestrator pid ${existing.orchestrator && existing.orchestrator.pid}) already holds the name "${basePrefix}" here, ` +
      `and its members are dispatched under that prefix. ` +
      `Re-run with --team ${candidate} to accept the auto-derived name, or --team <your-name> to choose your own.`
  );
}

/** Shared by `resolveMembersPlan` and `planMembersFromHistory` (spec 0015 §7.2): refuse a live Team, clear a stale one. */
function refuseOrClearExistingTeam(dir) {
  const existing = readTeam(dir, teamFile);
  if (!existing) return;
  if (teamIsLive(existing)) {
    // Spec 0044 §1.1 (fork F3): a scope the caller did not name is one this command derived, so a
    // collision there is answered with a free candidate to accept — never silently applied. An
    // explicit `--team` the user chose gets the plain "disband it first" instead.
    if (teamFileDefaulted) refuseLiveDefaultTeam(dir, existing);
    fail(`a live Team ${existing.team_id} already exists — disband it first`);
  }
  clearTeam(dir, teamFile);
}

/** Shared by `create --plan` and `create --spawn` (spec 0005 §9 item 1): resolve the roster, refuse/clear a stale Team, compute members[] + spawn shapes. */
function resolveMembersPlan(dir) {
  refuseOrClearExistingTeam(dir);
  const resolved = resolveRoster(cwd, teamArg);
  if (!resolved) fail("no roster resolves at any level — hand off to `roster.mjs init`");
  const transport = detectTransport();
  const plan = resolved.members.map((m) => {
    const route = m.route || resolved.route;
    return { role: m.role, name: m.name, kind: resolveKind(m), model: m.model, effort: m.effort, route, autoMode: m.autoMode, args: memberArgs(m), spawn: routeHasPane(route) ? spawnShape({ ...m, route }, transport) : null };
  });
  return { level: resolved.level, path: resolved.path, transport, layout_plan: layoutPlan(resolved, transport, plan), members: plan };
}

/** `create --from <id|alias>` (spec 0015 §7.2): resolve which history entry `--from` names. */
function resolveHistoryEntry(dir) {
  const key = opts.from;
  const h = readHistory(dir);
  const byId = h.teams.find((t) => t.id === key);
  if (byId) return byId;
  const byAlias = h.teams.filter((t) => t.alias === key).sort((a, b) => (a.last_used < b.last_used ? 1 : -1));
  if (byAlias.length) return byAlias[0];
  fail(`create --from: no history entry matches ${JSON.stringify(key)} — available ids: ${h.teams.map((t) => t.id).join(", ") || "(none)"}`);
}

/**
 * Rename stored history members (role/model/effort/route/auto_mode, snake_case, no name — spec
 * 0015 §3.1) to the plan-shape's camelCase `autoMode` and validate. Renaming before validating
 * matters: `validateMember` checks the camelCase key and rejects any member carrying a "name"
 * (spec §7.2: the rename is history->plan only, one direction). Returns the renamed members, or
 * `fail()`s naming the invalid field — never silently repairs a stale entry.
 */
function validateHistoryMembers(entry) {
  const stored = Array.isArray(entry.members) ? entry.members : [];
  const renamed = stored.map((m) => {
    const out = { role: m.role, model: m.model, effort: m.effort, route: m.route };
    if (m.auto_mode !== undefined) out.autoMode = m.auto_mode;
    return out;
  });
  const rosterBlock = { route: (renamed[0] && renamed[0].route) || "peer", layout: "auto", members: renamed };
  const errors = validateRosterBlock(rosterBlock);
  if (errors.length) fail(errors.join("; "));
  return renamed;
}

/**
 * `create --from <id|alias>` (spec 0015 §7.2): the member source is a stored history entry
 * instead of a live roster level. Everything downstream — refuse/clear a stale Team, validation,
 * derived names, spawn shapes — is the existing `resolveMembersPlan` path, unchanged.
 */
function planMembersFromHistory(entry, dir) {
  refuseOrClearExistingTeam(dir);
  const renamed = validateHistoryMembers(entry);
  const rosterBlock = { route: (renamed[0] && renamed[0].route) || "peer", layout: "auto", members: renamed };
  const transport = detectTransport();
  const named = namedMembers(renamed);
  const plan = named.map((m) => {
    const route = m.route || rosterBlock.route;
    return { role: m.role, name: m.name, kind: resolveKind(m), model: m.model, effort: m.effort, route, autoMode: m.autoMode, args: memberArgs(m), spawn: routeHasPane(route) ? spawnShape({ ...m, route }, transport) : null };
  });
  return { level: entry.roster_level || null, path: null, transport, layout_plan: layoutPlan(rosterBlock, transport, plan), members: plan };
}

/** `create`'s member source: history (`--from`) or the live roster (default). */
function getMembersPlan(dir) {
  return typeof opts.from === "string" ? planMembersFromHistory(resolveHistoryEntry(dir), dir) : resolveMembersPlan(dir);
}

function runShell(commandString, opts = {}) {
  return new Promise((resolvePromise) => {
    execFile("/bin/sh", ["-c", commandString], { encoding: "utf8", maxBuffer: 1024 * 1024, cwd: opts.cwd }, (err, stdout, stderr) => {
      resolvePromise({ err, stdout, stderr });
    });
  });
}

/**
 * Best-effort peer-pane border label (spec 0014) — herdr's
 * `show_agent_labels_on_pane_borders` is a boolean, not a template, so no
 * config key composes "claude" + the member's name. If herdr ever gains a
 * label template, this workaround should be retired, not extended. Must
 * never throw: `launchMember()`'s caller (`:538`) maps a rejected promise to
 * `launch_status: "failed"`, and a cosmetic label error is not a launch
 * outcome.
 */
function labelPane(member) {
  try {
    // Spec 0043 §1.4: the kind, not the literal "claude" — a codex member's pane must read as
    // codex. `member.kind` is always explicit here (defaulted at the read seam, §1.1).
    herdrCall(["pane", "rename", member.transport_id, resolveKind(member), "-", member.name]);
    return null;
  } catch {
    return "failed";
  }
}

/**
 * Spec 0043 §1.4: Herdr reports launch problems as JSON with an `error.code`, and — verified
 * live (r4) — writes that JSON to STDOUT on the error path, not stderr. A reader that inspects
 * only stderr finds an empty string and silently misreads the outcome, so both are parsed.
 * Returns the error code, or null when nothing parseable carries one.
 */
function herdrErrorCode(attempt) {
  for (const stream of [attempt.stdout, attempt.stderr]) {
    if (typeof stream !== "string" || !stream.trim()) continue;
    try {
      const parsed = JSON.parse(stream);
      const code = parsed && parsed.error && parsed.error.code;
      if (typeof code === "string" && code) return code;
    } catch {
      // not JSON — try the other stream
    }
  }
  return null;
}

/**
 * One member's launch, with the herdr-only retry (spec 0005 §4 step 6). NEEDS-EVIDENCE item 2 (§9)
 * is unresolved — no live pane was available to reproduce the retryable "pane busy" condition, only
 * the non-retryable ones (bad --kind, nonexistent pane) — so this uses the spec's documented safe
 * fallback: retry once on any herdr failure, herdr-only.
 */
async function launchMember(member, transport) {
  // Spec 0043 §1.4: a member whose kind cannot be started on this transport (or whose config is
  // invalid) is REFUSED — nothing is shelled for it at all, and it fails alone so the rest of a
  // mixed `create --spawn` still launches.
  if (member.spawn.refuse) {
    return { ...member, launch_status: "failed", launch_result: { reason: "refused", detail: member.spawn.refuse }, retried: false, error: member.spawn.refuse };
  }
  const template = member.spawn.launch[0];
  const cmd = member.spawn.target_placeholder && member.transport_id != null ? template.split(member.spawn.target_placeholder).join(member.transport_id) : template;
  let attempt = await runShell(cmd, { cwd: member.spawn.launch_cwd });
  let retried = false;
  // §1.4: `agent_not_ready` means an agent IS running and is sitting on its own startup prompt.
  // Re-running `agent start` against that pane is wrong, so this one code suppresses the retry.
  const firstCode = attempt.err && transport === "herdr" ? herdrErrorCode(attempt) : null;
  if (attempt.err && transport === "herdr" && firstCode !== "agent_not_ready") {
    retried = true;
    attempt = await runShell(cmd, { cwd: member.spawn.launch_cwd });
  }
  const errorText = () => (attempt.stderr && String(attempt.stderr).trim()) || (attempt.stdout && String(attempt.stdout).trim()) || (attempt.err && attempt.err.message) || "launch failed";
  if (transport === "herdr") {
    if (attempt.err) {
      const code = herdrErrorCode(attempt);
      // §1.4: blocked-at-startup is a first-class outcome, NOT a failure. The agent is live and
      // queryable by name, nothing is orphaned, and spawn must never answer the prompt itself
      // (§6) — it reports the remedy and leaves the decision with a human.
      if (code === "agent_not_ready") {
        return {
          ...member,
          launch_status: "blocked-at-startup",
          launch_result: {
            code,
            detail: errorText(),
            remedy: `${member.name} is live but awaiting a startup prompt — \`herdr agent read ${member.name} --source recent-unwrapped --lines 40\` shows it, \`herdr agent send-keys ${member.name} <key>\` answers it`,
          },
          retried,
        };
      }
      // §1.4/§1.9: on a startup timeout the agent name never registers, so only the pane
      // survives. Report it with the close command rather than closing it — that pane holds the
      // target CLI's own output, which is usually the only explanation of what went wrong.
      if (code === "timeout") {
        const args = member.spawn.args;
        const result = {
          code,
          detail: errorText(),
          orphaned_transport_id: member.transport_id || null,
          remedy: member.transport_id ? `the pane is orphaned (the agent name never registered) — close it with \`herdr pane close ${member.transport_id}\`` : "the agent name never registered",
        };
        if (args && args.length) {
          result.likely_cause = `args ${JSON.stringify(args)} most likely made ${resolveKind(member)} run and exit instead of staying interactive — these are passed through unvalidated, so this is a diagnostic, not a verdict`;
        }
        return { ...member, launch_status: "failed", launch_result: result, retried, error: errorText() };
      }
      return { ...member, launch_status: "failed", launch_result: null, retried, error: errorText() };
    }
    if (!attempt.err) {
      let parsed = null;
      try {
        parsed = JSON.parse(attempt.stdout);
      } catch {
        /* non-JSON success output — reported as ready with a null launch_result */
      }
      const result = { ...member, launch_status: "ready", launch_result: parsed, retried };
      if (member.transport_id && herdrOnPath()) {
        const labelResult = labelPane(member);
        if (labelResult) result.label = labelResult;
      }
      return result;
    }
  }
  // tmux and terminal: no readiness handshake, and no retry (spec 0005 §4 step 6 [correction]).
  if (!attempt.err) return { ...member, launch_status: "dispatched", launch_result: null, retried: false };
  return { ...member, launch_status: "failed", launch_result: null, retried: false, error: errorText() };
}

/**
 * Per-member layout+launch+retry (spec 0009 §6.3 step 5): place `peerMembers.length` panes via the
 * transport, assign each member's `transport_id`, then launch+retry each with `launchMember`.
 * Mutates `peerMembers` in place (`transport_id`); returns launch results aligned to `peerMembers`.
 * Shared by `createSpawn` (spec 0005) and `spawn-one` (spec 0009 §6) — one implementation.
 */
async function layoutAndLaunch(allMembers, transport, mode, splitCwd, callerLabel, layoutOpts = {}) {
  // Spec 0043 §1.4/§4.3: a refused member has nothing shelled for it — and a pane IS something
  // shelled for it, so the refusal must land BEFORE the layout step, not inside launchMember.
  // Partitioned here rather than at each call site because this is the one seam `create --spawn`,
  // `spawn-one`, and history replay all pass through.
  const refused = allMembers.filter((m) => m.spawn && m.spawn.refuse);
  const peerMembers = allMembers.filter((m) => !(m.spawn && m.spawn.refuse));
  for (const m of refused) m.transport_id = null;

  let panes = [];
  if (transport === "herdr" && peerMembers.length > 0) {
    if (!herdrOnPath()) {
      fail("transport is herdr (HERDR_ENV=1) but no `herdr` binary is on PATH — cannot place panes. Install herdr, or unset HERDR_ENV to use tmux/terminal.");
    }
    const self = process.env.HERDR_PANE_ID;
    if (!self) fail(`${callerLabel} needs HERDR_PANE_ID in the environment`);
    ({ panes } = runLayoutLoop({ mode, paneCount: peerMembers.length, self, splitCwd, seedPanes: layoutOpts.seedPanes || [] }));
  } else if (transport === "tmux") {
    for (let i = 0; i < peerMembers.length; i++) {
      try {
        panes.push(execFileSync("tmux", ["new-window", "-P", "-F", "#{pane_id}", "-c", splitCwd], { encoding: "utf8" }).trim());
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
      fail(`${callerLabel}: layout produced ${JSON.stringify(panes)} for ${peerMembers.length} peer member(s) — expected that many distinct, non-empty target ids`);
    }
  }
  peerMembers.forEach((m, i) => {
    m.transport_id = transport === "terminal" ? null : panes[i];
  });

  const settled = await Promise.allSettled(peerMembers.map((m) => launchMember(m, transport)));
  const launched = settled.map((r, i) => (r.status === "fulfilled" ? r.value : { ...peerMembers[i], launch_status: "failed", launch_result: null, retried: false, error: String(r.reason) }));
  // Results stay aligned to the caller's original array so an index-keyed caller still lines up.
  return allMembers.map((m) => (m.spawn && m.spawn.refuse ? { ...m, transport_id: null, launch_status: "failed", launch_result: { reason: "refused", detail: m.spawn.refuse }, retried: false, error: m.spawn.refuse } : launched[peerMembers.indexOf(m)]));
}

/** Spec 0009 §6.4: shared CLI-side guard for `spawn-one`, `create --spawn`, `move` (spec 0016
    §4.4), and `disband --close` (spec 0016 §4.5) — a Bash subprocess that §4's PreToolUse gate
    cannot see inside must not become the laundering path around it. */
function requireAllowGlobal(level, path) {
  if (level !== "global" || opts["allow-global"] === true) return;
  fail(
    `ah: this roster resolves at GLOBAL level (${path}) and may belong to an unrelated project. Re-run with --allow-global, or create a repo roster with the /agent-roster skill.`
  );
}

/** Spec 0016 §4.5: short hash over `team_id` + the sorted non-null `transport_id`s of the close
    set — binds `disband --close --plan-token` to the exact plan that `disband` (bare/plan mode)
    reported, so a stale plan or a topology change between plan and close is caught rather than
    silently closing the wrong panes. */
function closeToken(teamId, closable) {
  const ids = closable.map((m) => m.transport_id).filter((id) => id != null).sort();
  return createHash("sha256").update(JSON.stringify({ team_id: teamId, ids })).digest("hex").slice(0, 16);
}

/** Members with something addressable to close — spec 0016 §4.5's "close set". */
function closableMembers(members) {
  return members.filter((m) => routeHasPane(m.route) && m.transport_id != null);
}

/** Build argv directly and close one member's pane — never `/bin/sh` (spec 0016 §4.5): a
    `transport_id` reaches here from herdr/tmux's own output, but running it through a shell
    string (as the display-only `command` field does) would make it an injection vector. */
function closeMemberPane(transport, transportId) {
  if (transport === "herdr") {
    herdrCall(["pane", "close", transportId]);
    return;
  }
  if (transport === "tmux") {
    execFileSync("tmux", ["kill-pane", "-t", transportId]);
    return;
  }
  throw new Error(`disband --close: transport ${JSON.stringify(transport)} has no addressable pane to close`);
}

/** Strip a member's role (and any -<ordinal> suffix) off its derived name to recover its naming prefix. */
function prefixOfMemberName(name, role) {
  if (typeof name !== "string" || typeof role !== "string") return name;
  return name.replace(new RegExp(`-${role}(?:-\\d+)?$`), "");
}

/** Spec 0010 §5.3/§7.4: `alias --set`/`--clear` still write even with a live Team, but must
    warn — names are frozen in team.json (ADR 0002); the new prefix only applies to the next Team. */
function warnLiveTeamAlias(dir, newPrefix) {
  const team = readTeam(dir);
  if (!team || !Array.isArray(team.members) || team.members.length === 0) return;
  const sample = team.members[0];
  const oldPrefix = prefixOfMemberName(sample.name, sample.role);
  process.stderr.write(
    `roster.mjs: ah: team ${team.team_id} is live with ${team.members.length} member(s) named "${oldPrefix}-${sample.role}". ` +
      `Their names are frozen in team.json and are unaffected — they keep receiving dispatch under those names. ` +
      `The new prefix "${newPrefix}" applies to the next Team you create.\n`
  );
}

/** Spec 0010 §7.2/§7.4: `spawn-one` after an alias change can add a member under a different
    prefix than the Team's existing members — no auto-rename, no auto-disband, just a warning. */
function warnMixedPrefixSpawnOne(dir, member) {
  const team = readTeam(dir, teamFile);
  if (!team || !Array.isArray(team.members) || team.members.length === 0) return;
  const newPrefix = prefixOfMemberName(member.name, member.role);
  const mismatched = team.members.find((m) => m.name && m.role && prefixOfMemberName(m.name, m.role) !== newPrefix);
  if (!mismatched) return;
  const oldPrefix = prefixOfMemberName(mismatched.name, mismatched.role);
  process.stderr.write(
    `roster.mjs: ah: this member will be named "${member.name}", but team ${team.team_id}'s existing members are named "${oldPrefix}-*". ` +
      `The team will hold both prefixes. Every name still resolves from team.json, so dispatch is unaffected.\n`
  );
}

/** Spec 0009 §6.3 step 4: the same up/pid, seen|briefed/freshness liveness rule `roster()`
    (lib-hier.mjs) applies per-record, applied here to one named team member. */
function memberIsLive(dir, name) {
  const rec = latestRoster(dir).find((r) => r.name === name);
  return Boolean(rec) && rec.status !== "down" && recordLiveness(rec).live;
}

/**
 * Spec 0043 §1.6: liveness for one member, kind-aware, three-valued.
 *
 * `kind: claude` is unchanged — `peers.jsonl`, written by the spawned session's own SessionStart
 * hook. A non-claude process runs no Claude hooks and can never satisfy that, so left alone it
 * would read as permanently not-live and `spawn-one`'s already-live refusal would never fire —
 * a second `spawn-one` would then start a second agent under a name Herdr requires to be unique.
 * That is the concrete failure this exists to prevent.
 *
 * Returns `{live, indeterminate, why, agent_status, ready}`; callers must treat `indeterminate`
 * as "refuse", never as "dead".
 */
function memberLiveness(dir, member) {
  if (resolveKind(member) === KIND_DEFAULT) {
    const live = memberIsLive(dir, member.name);
    return { live, indeterminate: false, why: live ? "peers.jsonl up" : "no live peers.jsonl record", agent_status: null, ready: live };
  }
  return herdrAgentState(member.name);
}

/** Spec 0040 §1.2: the live peer records for the current team, shaped like team.json members so
    closableMembers/closeToken/closeMemberPane apply verbatim. Records store the herdr pane id
    from checkin (HERDR_PANE_ID); a record without one has no transport_id and is listed but
    never closable. `source: "peers"` marks the row as coming from the registry, not team.json. */
function peerFallbackMembers(dir) {
  // Spec 0044: `teamArg`, NOT `teamFile`. This filters `peers.jsonl`'s `team` TAG, which is a
  // different axis from which team file a command writes — the whole point of this fallback is
  // peers that no team record accounts for, and those are exactly the rows carrying no tag. An
  // explicit `--team` is the only narrowing that was ever meant here; a derived scope would
  // filter every untagged peer out and turn the fallback into a no-op.
  return livePeerSlots(dir, teamArg || null)
    .filter((s) => s.live)
    .map((s) => ({ role: s.role, name: s.name, route: "peer", transport_id: s.pane_id, live: s.live, how: s.how, source: "peers" }));
}

/** Spec 0040 §1.4a: registry peers not named in team.json — a record matching a member's name IS
    that member, never an extra. */
function peerExtras(dir, team) {
  const named = new Set(team.members.map((m) => m.name));
  return peerFallbackMembers(dir).filter((m) => !named.has(m.name));
}

function peerFallbackPlanEntry(m) {
  return { role: m.role, name: m.name, route: m.route, transport: "herdr", transport_id: m.transport_id, command: m.transport_id ? `herdr pane close ${m.transport_id}` : null, live: m.live, how: m.how, source: "peers" };
}

/** Close one member of a (possibly mixed, spec 0040 §1.4a) close set: team rows use the team's
    transport; registry rows are herdr by construction and carry `source` through to the result. */
function closeOne(m, teamTransport) {
  const row = { name: m.name, transport_id: m.transport_id };
  try {
    closeMemberPane(m.source === "peers" ? "herdr" : teamTransport, m.transport_id);
    Object.assign(row, { closed: true, error: null });
  } catch (err) {
    Object.assign(row, { closed: false, error: err.message });
  }
  if (m.source === "peers") row.source = "peers";
  return row;
}

/** Shared token/confirm/allow-global gate for every --close variant (spec 0016 §4.5, 0040 §1.3). */
function gateClose(verb, scope, closable) {
  const closeList = closable.map((m) => ({ name: m.name, transport_id: m.transport_id, ...(m.source === "peers" ? { source: "peers" } : {}) }));
  if (opts.confirm !== true) {
    fail(`${verb} --close: --confirm is required to close ${verb === "dismiss" ? "a live session" : "live sessions"}. Close list: ${JSON.stringify(closeList)}`);
  }
  if (typeof opts["plan-token"] !== "string" || !opts["plan-token"]) {
    fail(`${verb} --close needs --plan-token <tok>, from a preceding \`${verb}${verb === "dismiss" ? " <name>" : ""}\` (plan) call`);
  }
  if (opts["plan-token"] !== closeToken(scope, closable)) {
    fail(`${verb} --close: --plan-token does not match the current close plan (the topology may have changed) — re-run \`${verb}\` and retry with the fresh token`);
  }
  const preResolved = resolveRoster(cwd, teamArg);
  if (preResolved) requireAllowGlobal(preResolved.level, preResolved.path);
}

/** `create --spawn` (spec 0005): resolve + layout + launch + retry in one script invocation. */
async function createSpawn(dir) {
  const mode = opts.mode;
  if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`--mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);
  // --from only changes where the member list comes from — it must not change whether a spawn
  // is gated, so this runs unconditionally either way (a prior version skipped it for --from).
  if (typeof opts.from === "string") {
    const entry = resolveHistoryEntry(dir);
    requireAllowGlobal(entry.roster_level, "stored in team-history.json");
  } else {
    const preResolved = resolveRoster(cwd, teamArg);
    if (preResolved) requireAllowGlobal(preResolved.level, preResolved.path);
  }
  const { level, transport, layout_plan, members } = getMembersPlan(dir);
  const peerMembers = members.filter((m) => routeHasPane(m.route));

  const launched = await layoutAndLaunch(peerMembers, transport, mode, cwd, "create --spawn");
  const launchByName = new Map(peerMembers.map((m, i) => [m.name, launched[i]]));

  // Spec 0043 §1.1: `kind` is written only when it is not the default, so claude rows stay
  // byte-identical to pre-0043. `create --spawn` does not write team.json itself — the
  // Orchestrator builds it from these rows (SKILL.md), so a row that omits `kind` becomes a
  // team.json entry that resolves to claude and asks `peers.jsonl` about a process that never
  // writes it: the member reads dead forever, and `dismiss` drops a live agent's record without
  // the warning that is supposed to stop exactly that. (`spawn-one` is unaffected — it sources
  // its member from the roster config and takes only the name from the team record.)
  const kindFields = (m) => {
    const f = {};
    if (resolveKind(m) !== KIND_DEFAULT) f.kind = resolveKind(m);
    if (memberArgs(m)) f.args = [...memberArgs(m)];
    return f;
  };
  const outputMembers = members.map((m) => {
    if (!routeHasPane(m.route)) return { role: m.role, name: m.name, ...kindFields(m), model: m.model, route: m.route, autoMode: m.autoMode, transport_id: null, launch_status: null, launch_cwd: null };
    const lm = launchByName.get(m.name);
    // Spec 0035 §2.4: placement is consequential and must not be silent — report where each
    // peer actually launched, not just that it launched.
    const entry = { role: m.role, name: m.name, ...kindFields(m), model: m.model, route: m.route, autoMode: m.autoMode, transport_id: m.transport_id, launch_status: lm.launch_status, launch_result: lm.launch_result, retried: lm.retried, launch_cwd: m.spawn ? m.spawn.launch_cwd : null };
    if (lm.error) entry.error = lm.error;
    if (lm.label) entry.label = lm.label;
    // Spec 0008 §6: populate tab_id/workspace_id from the launch result when it carries them.
    // No new herdr query on this path — if absent, the first `resync` fills them in.
    const launchedPane = transport === "herdr" && lm.launch_result && lm.launch_result.result && lm.launch_result.result.pane;
    if (launchedPane && launchedPane.tab_id != null) entry.tab_id = launchedPane.tab_id;
    if (launchedPane && launchedPane.workspace_id != null) entry.workspace_id = launchedPane.workspace_id;
    return entry;
  });
  const isPartial = outputMembers.some((m) => routeHasPane(m.route) && m.launch_status === "failed");
  out({ level, transport, members: outputMembers, partial: isPartial });
}

/** One team's inventory row (spec 0011 §5.4 / 0033 §3.1): `null` for the default team, or
    `name` == readdirSync's entry basename == the value listTeamNames(dir) returns. Never
    writes. Shared by `teams` and `reap` (spec 0033 §3.2) so the two commands cannot drift
    apart about what a team is. */
function describeTeamRow(dir, name, myPid) {
  const t = readTeam(dir, name);
  if (!t) return null;
  const pid = t.orchestrator && t.orchestrator.pid;
  return {
    name,
    team_id: t.team_id,
    members: Array.isArray(t.members) ? t.members.length : 0,
    orchestrator_pid: pid ?? null,
    pid_alive: pidAlive(pid),
    orphaned: teamIsOrphaned(t), // pid null/unresolvable/dead — spec 0033 §3.1
    own: Number.isInteger(myPid) && pid === myPid,
    created: t.created,
  };
}

/** Every team in this hierarchy dir — default team first, then every named team (spec 0033 §3.2). */
function allTeamRows(dir, myPid) {
  return [describeTeamRow(dir, null, myPid), ...listTeamNames(dir).map((name) => describeTeamRow(dir, name, myPid))].filter(Boolean);
}

/** Spec 0009 §6 / 0039 §1.2: stand up ONE missing or dead peer — the single spawn path shared by
    `spawn-one` and `add`. Extracted, not forked, from `createSpawn`'s launch path. Resolves the
    roster, picks the member (`--member`, else the sole/first-dead candidate), refuses when the
    peer is already live, places the pane, launches, and persists team.json. Returns the JSON the
    caller prints; every refusal goes through `fail()`. `callerLabel` prefixes the error text and
    the layout call. */
async function spawnOneCore(role, callerLabel, adHocMember = null) {
  if (!PEER_ELIGIBLE_ROLES.includes(role)) fail(`${callerLabel}: role must be one of ${PEER_ELIGIBLE_ROLES.join(", ")}, got ${JSON.stringify(role)}`);
  const resolved = resolveRoster(cwd, teamArg);
  // Spec 0044 §1.4 point 2: an ad hoc member need not exist in the roster, and need not have a
  // roster to exist in. The roster is still read when there IS one — for the level gate and the
  // layout mode — but its absence is only fatal on the roster-sourced paths.
  if (!resolved && !adHocMember) fail(`no roster configured for ${cwd}; run the /agent-roster skill's Init flow`);
  if (resolved) requireAllowGlobal(resolved.level, resolved.path);
  const candidates = adHocMember ? [adHocMember] : resolved.members.filter((m) => m.role === role);
  if (candidates.length === 0) {
    const roles = [...new Set(resolved.members.map((m) => m.role))];
    fail(`${callerLabel}: no ${role} member in the roster — roles it defines: ${roles.join(", ") || "(none)"}`);
  }
  const dir = hierarchyDir(cwd);
  // §3.2: --member is value-taking; parseArgs sets it to `true` (not a string) when given
  // with no value or immediately followed by another flag — that must fail loudly, never
  // silently fall through to implicit selection.
  if (opts["member"] === true) fail(`${callerLabel}: --member requires a value (the derived member name)`);
  let member;
  if (adHocMember) {
    member = adHocMember;
  } else if (typeof opts["member"] === "string") {
    member = candidates.find((m) => m.name === opts["member"]);
    if (!member) fail(`${callerLabel}: no member named ${opts["member"]} for role ${role} in the roster — it defines: ${candidates.map((m) => m.name).join(", ") || "(none)"}`);
  } else if (candidates.length === 1) {
    member = candidates[0];
  } else {
    member = candidates.find((m) => !memberLiveness(dir, m).live) || candidates[candidates.length - 1];
  }

  const team = readTeam(dir, teamFile);
  // Spec 0018 §3/§4.3: creating a new team here needs a resolvable, live owner pid — refuse
  // before anything spawns, so a half-launched team (panes up, no persisted owner) never
  // happens. Only relevant when no team file exists yet; an existing team already has one.
  let newTeamOrchestratorPid = null;
  if (!team) {
    newTeamOrchestratorPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
    if (!Number.isInteger(newTeamOrchestratorPid)) {
      fail(`${callerLabel}: no orchestrator pid resolvable (CLAUDE_PID unset and no --orchestrator-pid given) — refusing to create a team with an unowned pid`);
    }
    if (!pidAlive(newTeamOrchestratorPid)) {
      fail(`${callerLabel}: --orchestrator-pid ${newTeamOrchestratorPid} is not a live process — refusing to create a team owned by a dead pid`);
    }
  }
  // Spec 0044 §1.4 point 5: an ad hoc member is ALWAYS matched by name. Matching by role would
  // make `matches` find a different, same-role member already in the team and overwrite its
  // record — which is the one outcome that point forbids, and which the name-collision refusal
  // above does not catch because the two names differ.
  const byName = Boolean(adHocMember) || candidates.length > 1;
  const matches = (m) => (byName ? m.name === member.name : m.role === role);
  const existing = team && Array.isArray(team.members) ? team.members.find(matches) : null;
  // §3.3(i)/§3.3.1, amendment (b): the already-live decision is a disjunction over TWO names,
  // both asked of the registry (`memberIsLive`) — never the team-record lookup by itself.
  // - memberIsLive(dir, member.name): the name we're about to launch is already running
  //   (population 1 — a live member whose team.json slot got overwritten by a sibling spawn).
  // - liveRecord: this slot's EXISTING record is live under a different (stale-drifted) name
  //   (population 2 — alias drift, spec 0010 §7.2). A dead existing record must NOT block a
  //   legitimate spawn, which is why liveness is asked about its name too, not just its presence.
  // Collapsing to either disjunct alone reopens the other population — see §3.3.1.
  // Spec 0043 §1.6: liveness is kind-aware and THREE-valued. An indeterminate answer (Herdr
  // unreachable) must refuse rather than proceed — proceeding means launching a replacement for
  // an agent that may well be alive, under a name Herdr requires to be unique.
  const selfState = memberLiveness(dir, member);
  if (selfState.indeterminate) {
    fail(`${callerLabel}: cannot determine whether ${member.name} (kind ${resolveKind(member)}) is already live — ${selfState.why}. Refusing to spawn: a duplicate agent under a name Herdr requires to be unique is worse than not spawning. Fix Herdr and retry.`);
  }
  const existingState = existing ? memberLiveness(dir, { ...member, name: existing.name }) : null;
  if (existingState && existingState.indeterminate) {
    fail(`${callerLabel}: cannot determine whether the existing record ${existing.name} (kind ${resolveKind(member)}) is still live — ${existingState.why}. Refusing to spawn; fix Herdr and retry.`);
  }
  const liveRecord = existingState && existingState.live ? existing : null;
  if (selfState.live || liveRecord) {
    const out_member = liveRecord || existing || { role: member.role, name: member.name };
    const state = selfState.live ? selfState : existingState;
    // §1.6: live and ready are different questions for a Herdr-driven agent — a member blocked
    // on its own startup prompt is live (do not spawn a second) but not promptable.
    const liveInfo = { agent_status: state.agent_status, ready: state.ready };
    if (byName && typeof opts["member"] !== "string") {
      // Reporting only (the load-bearing refusal already fired above). An indeterminate candidate
      // is listed with a marker rather than dropped — vanishing from the list would read as
      // "confirmed not live", which is exactly what indeterminate does not mean.
      const candidatesLive = candidates
        .map((c) => ({ name: c.name, st: memberLiveness(dir, c) }))
        .filter(({ st }) => st.live || st.indeterminate)
        .map(({ name, st }) => (st.indeterminate ? `${name} (liveness unknown)` : name));
      return { spawned: false, reason: "already live", member: out_member, role, candidates_live: candidatesLive, ...liveInfo };
    }
    return { spawned: false, reason: "already live", member: out_member, ...liveInfo };
  }
  warnMixedPrefixSpawnOne(dir, member);

  const transport = detectTransport();
  // Spec 0043 §1.5: the member's own route, not a hardcoded "peer" — a `pane` member must be
  // recorded as `pane` or disband/dismiss/move would never find it, and `spawnShape` needs the
  // effective route to apply §1.3's non-claude rule.
  const blockRoute = resolved ? resolved.route : null;
  const memberRoute = routeHasPane(member.route || blockRoute) ? member.route || blockRoute : "peer";
  const planEntry = { role: member.role, name: member.name, kind: resolveKind(member), model: member.model, effort: member.effort, route: memberRoute, autoMode: member.autoMode, args: memberArgs(member), spawn: spawnShape({ ...member, route: memberRoute }, transport) };
  // §1.4 point 3 (one launch path): an ad hoc member with no roster behind it still goes through
  // layoutPlan, given the same block shape a roster would have supplied. A second, simpler layout
  // branch here is exactly the fork the spec forbids.
  const layoutSource = resolved || { route: memberRoute, layout: "auto", members: [] };
  const layoutInfo = layoutPlan(layoutSource, transport, [planEntry]);
  const mode = layoutInfo ? layoutInfo.mode : layoutSource.layout;
  if (!ROSTER_LAYOUT_VALUES.includes(mode)) fail(`${callerLabel}: layout mode must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(mode)}`);

  if (opts["dry-run"] === true) {
    return { dry_run: true, role: member.role, name: member.name, mode, launch: planEntry.spawn.launch };
  }

  const seedPanes = team && Array.isArray(team.members)
    ? team.members
        .filter((m) => routeHasPane(m.route) && m.transport_id != null && m.name !== member.name)
        .map((m) => m.transport_id)
    : [];

  const [launched] = await layoutAndLaunch([planEntry], transport, mode, cwd, callerLabel, { seedPanes });
  if (launched.launch_status === "failed") {
    // Spec 0043 §1.4/§1.9: the orphaned-pane id, its close command and the args-blame diagnostic
    // live in `launch_result`. `fail()` prints one line, so they have to be folded into it —
    // dropping them leaves the user with a bare timeout and no way to find either the evidence
    // or the pane it is sitting in.
    const lr = launched.launch_result;
    const extra = lr ? [lr.likely_cause, lr.remedy].filter(Boolean) : [];
    fail([launched.error || `${callerLabel} launch failed`, ...extra].join(" — "));
  }

  const newRecord = { role: member.role, name: member.name, route: memberRoute, model: member.model, effort: member.effort, autoMode: member.autoMode, transport_id: launched.transport_id };
  // §1.1: written only when it is not the default, so claude-kind team.json rows are unchanged.
  if (resolveKind(member) !== KIND_DEFAULT) newRecord.kind = resolveKind(member);
  if (memberArgs(member)) newRecord.args = [...memberArgs(member)];
  const launchedPane = transport === "herdr" && launched.launch_result && launched.launch_result.result && launched.launch_result.result.pane;
  if (launchedPane && launchedPane.tab_id != null) newRecord.tab_id = launchedPane.tab_id;
  if (launchedPane && launchedPane.workspace_id != null) newRecord.workspace_id = launchedPane.workspace_id;

  let outTeam = team;
  if (!outTeam) {
    outTeam = {
      version: 1,
      team_id: newId(),
      created: localIso(),
      roster_level: resolved ? resolved.level : null,
      transport,
      orchestrator: { session_id: null, pid: newTeamOrchestratorPid },
      members: [],
      partial: resolved ? resolved.members.length > 1 : true,
      expected_root: realCwd(cwd),
    };
  }
  const idx = outTeam.members.findIndex(matches);
  if (idx === -1) outTeam.members.push(newRecord);
  else outTeam.members[idx] = newRecord;
  writeTeam(dir, outTeam, teamFile);
  const outMember = launched.label ? { ...newRecord, label: launched.label } : newRecord;
  // Spec 0035 §2.4: report where this peer actually launched, not just that it launched.
  const spawnOut = { spawned: true, member: outMember, team_id: outTeam.team_id, roster_level: outTeam.roster_level, launch_cwd: planEntry.spawn.launch_cwd };
  // Spec 0043 §1.4: blocked-at-startup is success WITH AN ACTION OUTSTANDING, not a failure —
  // the agent is live and queryable, so the team row stands and the caller is told what to do.
  if (launched.launch_status === "blocked-at-startup") {
    spawnOut.launch_status = launched.launch_status;
    spawnOut.launch_result = launched.launch_result;
    spawnOut.ready = false;
  }
  return spawnOut;
}

/**
 * Spec 0044 §1.3: mechanical enforcement of §1.2's boundary. Prose in CONTEXT.md is what already
 * existed and is what failed, so this refuses instead — the roster is a template for FUTURE teams,
 * and a session that currently owns a live one has no business editing it mid-flight.
 *
 * Every team file in this hierarchy dir is checked, not just the one at the resolving scope: an
 * orchestrator holding `--team foo` is just as much an owner while it runs a bare `add`.
 *
 * The message leads with §1.4's command and mentions the override second, deliberately. An agent
 * that reads a prohibition looks for a way around it; an agent that reads an instruction follows
 * it. The override is the USER's — no code path may supply it, and an agent adding it to get past
 * this refusal is precisely the failure this exists to prevent.
 */
function refuseRosterEditWhileOwningTeam(command) {
  if (!ROSTER_MUTATING_CMDS.has(command)) return;
  if (opts["allow-roster-edit"] === true) return;
  const dir = hierarchyDir(cwd);
  let myPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
  if (!Number.isInteger(myPid)) return; // no identity to compare against — nothing to enforce
  // Spec 0044 §1.3 scopes this to "the team file at the resolving scope" — the one THIS command
  // would sit alongside. Scanning every team file instead would refuse `--team B` work merely
  // because the session happens to own a live team A.
  const existing = readTeam(dir, teamFile);
  if (!existing || Number(existing.orchestrator && existing.orchestrator.pid) !== myPid || !teamIsLive(existing)) return;
  fail(
    `${command} edits the roster TEMPLATE, and this session owns live team ${existing.team_id} (${teamFile ? `team "${teamFile}"` : "the default team"}). ` +
      `To add or change a member of the RUNNING team — including one that diverges from the roster, or a role the roster does not define — run \`roster.mjs spawn-ad-hoc <role> [--model M] [--kind K] [--args '[...]']\`, which writes only the team file. ` +
      `If you genuinely mean to edit the template for future teams while this one runs, the user can re-run with --allow-roster-edit.`
  );
}

try {
  refuseRosterEditWhileOwningTeam(cmd);
  switch (cmd) {
    case "show": {
      const explicit = levelArg();
      if (explicit) {
        const level = requireLevel(explicit);
        const path = rosterLevelPaths(cwd)[level];
        const data = readLevelFile(path);
        const container = rosterContainer(data, teamArg);
        const resolved = resolveRoster(cwd, teamArg);
        const effective = teamPrefixInfo(cwd, teamArg);
        out({
          level,
          path,
          container: containerLabel(teamArg),
          roster: container && Array.isArray(container.members) ? { route: container.route, layout: container.layout || "auto", members: namedMembers(container.members) } : null,
          shadowed: resolved && resolved.level !== level ? `shadowed by ${resolved.level}` : null,
          teamAlias: level === "global" ? undefined : typeof data.teamAlias === "string" ? data.teamAlias : null,
          effectiveTeamAlias: effective.alias,
          effectiveTeamAliasSource: effective.source,
        });
      } else {
        out(resolveRoster(cwd, teamArg) || { roster: null });
      }
      break;
    }

    case "init": {
      const level = requireLevel(levelArg() || fail("init needs --level global|repo|repo-user (or the level as the first word)"));
      const route = opts.route;
      if (!ROSTER_ROUTE_VALUES.includes(route)) fail(`--route must be "peer" or "subagent", got ${JSON.stringify(route)}`);
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      // Spec 0032 §3.4 point 3: `init --team X` creates `rosters.X`, never `roster`; `init`
      // with no `--team` keeps writing `roster`, unchanged. A fresh object, not a mutation of
      // whatever was there — `init` REPLACES the block wholesale (pre-existing behavior for the
      // default `roster`), so a stale `layout` (or any other key) from a prior init must not
      // survive a re-init.
      const fresh = freshRosterBlock(route, opts.layout);
      installRosterBlock(data, teamArg, fresh);
      writeLevelFile(path, data);
      out({ level, path, container: containerLabel(teamArg), roster: fresh });
      break;
    }

    case "add": {
      const { level, wasDefaulted, teamKey } = targetLevel({ allowMissing: true });
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      let container = rosterContainer(data, teamKey);
      // 0032 §3.4b: a team-scoped container is created only by `init --team` — no
      // auto-vivification, since a typo'd --team writes a block that can never be selected
      // (resolveRoster only matches an active team name), which is silent-wrong forever.
      // Spec 0038 §1.1/§1.2: the DEFAULT container is the one exception — bare `add <role>`
      // with no roster bootstraps a minimal one here, through init's own writer.
      if (!container && teamKey) {
        fail(`no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init --team ${teamKey}\` first`);
      }
      const created = !container;
      if (created) {
        container = freshRosterBlock(typeof opts.route === "string" ? opts.route : AUTO_INIT_ROUTE, undefined);
        installRosterBlock(data, teamKey, container);
      }
      if (!Array.isArray(container.members)) container.members = [];
      const role = opts.role;
      if (role === "orchestrator") fail('role "orchestrator" is not a roster member — the Orchestrator is whatever session runs /agent-roster create');
      if (!ROLES.includes(role)) fail(`--role must be one of ${ROLES.join(", ")}, got ${JSON.stringify(role)}`);
      const member = memberFromFlags(role, "add");
      if (member.onMissing !== undefined && (member.route || container.route) === "subagent") {
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      // Spec 0043 §1.3's route rule is about the member's EFFECTIVE route, and a member with no
      // route of its own inherits the block's — the same `member.route || container.route` the
      // on-missing check above already uses. Validating the bare member instead would reject
      // `add --kind codex` under a `route: pane` roster block, which is the one place it belongs.
      const memberErrors = validateMember({ ...member, route: member.route || container.route });
      if (memberErrors.length) fail(memberErrors.join("; "));
      if (member.autoMode === "bypassPermissions" && (member.route || container.route) === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen\n');
      }
      container.members.push(member);
      const blockErrors = validateRosterBlock(container);
      if (blockErrors.length) fail(blockErrors.join("; "));
      const addedNamed = namedMembers(container.members).at(-1);
      requireHerdrName({ ...addedNamed, route: addedNamed.route || container.route }, "add");
      writeLevelFile(path, data);
      if (created) process.stderr.write(`roster.mjs: no roster existed — created a minimal one at level "${level}": ${path}\n`);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — added at the currently-resolving level "${level}" (${path})\n`);
      const added = namedMembers(container.members).at(-1);
      const result = { level, path, wasDefaulted, container: containerLabel(teamKey), member: added };
      process.stderr.write(`roster.mjs: added ${role} to ${path}\n`);
      // Spec 0044 §1.10 supersedes spec 0039: `add` writes the template and stops. Editing the
      // roster and standing up a live member are two acts, and while one command did both, that
      // command was the only way an agent had to get a divergent member running — so it reached
      // for it and wrote the roster on the way, which is the whole defect this spec closes.
      // Saying nothing here would silently strand anyone who relied on the old behaviour, so the
      // next step is named rather than left to be discovered.
      const effectiveRoute = member.route || container.route;
      result.spawned = false;
      result.next_step = routeHasPane(effectiveRoute) && PEER_ELIGIBLE_ROLES.includes(role)
        ? `config only — nothing was launched. To start this member: roster.mjs spawn-one ${role} --member ${added.name}`
        : `config only — nothing was launched. ${!routeHasPane(effectiveRoute) ? `route ${effectiveRoute}` : `role ${role} is never a peer session`}: dispatched on demand.`;
      process.stderr.write(`roster.mjs: ${result.next_step}\n`);
      out(result);
      break;
    }

    case "edit": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("edit needs --member <derived-name>");
      const { level, wasDefaulted, teamKey } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      const container = rosterContainer(data, teamKey);
      if (!container || !Array.isArray(container.members)) fail(`no ${containerLabel(teamKey)} at level "${level}" (${path}) — run \`roster.mjs init\` first`);
      const idx = findMemberIndex(container.members, memberName);
      if (idx === -1) fail(`no member named ${JSON.stringify(memberName)} at level "${level}"`);
      const updated = { ...container.members[idx] };
      if (typeof opts.role === "string") updated.role = opts.role;
      if (typeof opts.model === "string") updated.model = opts.model;
      if (typeof opts.effort === "string") updated.effort = opts.effort;
      if (typeof opts.route === "string") updated.route = opts.route;
      if (typeof opts["auto-mode"] === "string") updated.autoMode = opts["auto-mode"];
      if (opts.kind === true) fail("edit: --kind requires a value (e.g. claude, codex, pi)");
      if (typeof opts.kind === "string") {
        // §1.1: the default is total, so an explicit `claude` is stored as "no key" — a roster
        // file never gains `kind: "claude"` through an edit.
        if (opts.kind === KIND_DEFAULT) delete updated.kind;
        else updated.kind = opts.kind;
        if (opts.kind !== KIND_DEFAULT) {
          // §1.3: model/effort/auto-mode are Claude CLI flags and are rejected for another kind.
          // A member added as claude always carries a `model` from ROLE_DEFAULTS, so without this
          // every `edit --kind codex` on an existing member would be unreachable. Cleared with a
          // notice rather than a new flag, following the on-missing route-switch precedent below:
          // clear what the switch stranded, and say so.
          const stranded = ["model", "effort", "autoMode"].filter((k) => updated[k] !== undefined && updated[k] !== null);
          // Supplied together in one invocation is a contradiction, not a stranding — never guess
          // which the user meant (§3.2(i)'s precedent).
          const suppliedNow = [
            typeof opts.model === "string" ? "--model" : null,
            typeof opts.effort === "string" ? "--effort" : null,
            typeof opts["auto-mode"] === "string" ? "--auto-mode" : null,
          ].filter(Boolean);
          if (suppliedNow.length) {
            fail(`edit: ${suppliedNow.join(", ")} cannot be combined with --kind ${opts.kind} — model, effort, and auto-mode are Claude CLI flags and apply only to kind claude. Pass native arguments with --args instead.`);
          }
          for (const k of stranded) delete updated[k];
          if (stranded.length) {
            process.stderr.write(
              `roster.mjs: ah: cleared ${stranded.join(", ")} — ${stranded.length > 1 ? "they are" : "it is"} a Claude CLI setting and this member is now kind "${opts.kind}". Pass native arguments with --args.
`
            );
          }
        }
      }
      if (opts.args !== undefined) {
        const parsedArgs = parseArgsFlag(opts.args, "edit");
        if (parsedArgs === null) delete updated.args;
        else updated.args = parsedArgs;
      }
      if (opts["on-missing"] === true) fail("edit: --on-missing requires a value (auto, prompt, or never)");
      // §3.2.1: supplied-ness must be read from `opts`, never from `updated` — `updated` already
      // carries a value merged in via {...existing}, so once merged, "supplied now" and "was already
      // there" are indistinguishable on `updated` alone. That conflation is the trap amendment (c) fixes.
      const onMissingSupplied = typeof opts["on-missing"] === "string";
      if (onMissingSupplied) updated.onMissing = opts["on-missing"];
      if (onMissingSupplied && (updated.route || container.route) === "subagent") {
        // §3.2(i): both supplied in one invocation — a contradiction, never guess which one wins.
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      if (!onMissingSupplied && updated.route === "subagent" && updated.onMissing !== undefined) {
        // §3.2(ii): a route switch stranded an inherited onMissing — clear it and say so, rather than
        // silently discarding something the user configured earlier or making the switch unreachable.
        const dropped = updated.onMissing;
        delete updated.onMissing;
        process.stderr.write(`roster.mjs: ah: dropped on-missing "${dropped}" — it applies only to peer-routed members, and this member is now route "subagent"\n`);
      }
      if (updated.role === "orchestrator") fail('role "orchestrator" is not a roster member');
      const errors = validateMember({ ...updated, route: updated.route || container.route });
      if (errors.length) fail(errors.join("; "));
      if (updated.autoMode === "bypassPermissions" && (updated.route || container.route) === "peer") {
        process.stderr.write('roster.mjs: warning — auto-mode "bypassPermissions" can leave a headless peer stuck at a startup confirmation screen\n');
      }
      container.members[idx] = updated;
      const editedNamed = namedMembers(container.members)[idx];
      requireHerdrName({ ...editedNamed, route: editedNamed.route || container.route }, "edit");
      writeLevelFile(path, data);
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — edited at the currently-resolving level "${level}" (${path})\n`);
      out({ level, path, wasDefaulted, container: containerLabel(teamKey), member: namedMembers(container.members)[idx] });
      break;
    }

    case "remove": {
      const memberName = typeof opts.member === "string" ? opts.member : fail("remove needs --member <derived-name>");
      const result = removeConfigMember(memberName);
      if (!result.removed) fail(result.reason === "no such member" ? `no member named ${JSON.stringify(memberName)} at level "${result.level}"` : result.reason);
      if (result.wasDefaulted) process.stderr.write(`roster.mjs: no --level given — removed from the currently-resolving level "${result.level}" (${result.path})\n`);
      out({ level: result.level, path: result.path, wasDefaulted: result.wasDefaulted, removed: memberName, container: result.container, store: `${result.container} config at "${result.level}" (${result.path})` });
      break;
    }

    case "layout": {
      const { level, wasDefaulted, teamKey } = targetLevel();
      const path = rosterLevelPaths(cwd)[level];
      const data = readLevelFile(path);
      const container = rosterContainer(data, teamKey);
      if (!container || !Array.isArray(container.members)) fail(`no ${containerLabel(teamKey)} at level "${level}" — run \`roster.mjs init\` first`);
      if (typeof opts.layout === "string") {
        if (!ROSTER_LAYOUT_VALUES.includes(opts.layout)) fail(`--layout must be one of ${ROSTER_LAYOUT_VALUES.join(", ")}, got ${JSON.stringify(opts.layout)}`);
        container.layout = opts.layout;
        const blockErrors = validateRosterBlock(container);
        if (blockErrors.length) fail(blockErrors.join("; "));
        writeLevelFile(path, data);
      }
      if (wasDefaulted) process.stderr.write(`roster.mjs: no --level given — using the currently-resolving level "${level}" (${path})\n`);
      out({ level, path, wasDefaulted, container: containerLabel(teamKey), layout: container.layout || "auto" });
      break;
    }

    case "alias": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!ALIAS_FLAGS.has(key)) fail(`alias: unrecognized flag --${key} (use --level, --set, --clear, --team, or --cwd)`);
      }
      if (opts.set !== undefined && opts.clear === true) fail("alias: --set and --clear are mutually exclusive");
      // Spec 0011 §7.4: the alias writes a repo/repo-user CONFIG file, which is not team-scoped —
      // setting one from inside a team scope would rename a team the caller isn't in. The team name
      // already IS that team's prefix, so --set/--clear only ever make sense for the default team.
      if ((opts.set !== undefined || opts.clear === true) && teamArg) {
        fail(`alias: a team scope is active ("${teamArg}") — the team name is the prefix; alias --set/--clear only affect the default team's config alias`);
      }
      const dir = hierarchyDir(cwd);

      if (opts.set !== undefined) {
        if (typeof opts.set !== "string") fail("alias --set needs a value: roster.mjs alias --set <name>");
        const v = validateTeamAlias(opts.set);
        if (!v.ok) fail(`alias: ${v.why}`);
        const { level } = targetLevel();
        if (level === "global") fail("alias: an alias is repo-scoped — use --level repo or --level repo-user, not global (spec 0010 §4.3)");
        const path = rosterLevelPaths(cwd)[level];
        const data = readLevelFile(path);
        data.teamAlias = opts.set;
        writeLevelFile(path, data);
        const prefix = teamPrefixInfo(cwd, teamArg).prefix;
        warnLiveTeamAlias(dir, prefix);
        out({ level, path, teamAlias: opts.set, prefix });
        break;
      }

      if (opts.clear === true) {
        const { level } = targetLevel();
        if (level === "global") fail("alias: an alias is repo-scoped — use --level repo or --level repo-user, not global (spec 0010 §4.3)");
        const path = rosterLevelPaths(cwd)[level];
        const data = readLevelFile(path);
        delete data.teamAlias;
        writeLevelFile(path, data);
        const prefix = teamPrefixInfo(cwd, teamArg).prefix;
        warnLiveTeamAlias(dir, prefix);
        out({ level, path, teamAlias: null, prefix });
        break;
      }

      // Read-only. `alias`/`source` report the config-level alias regardless of team scope;
      // `teamScope`/`prefix` report what's actually active — spec 0011 §5.4 wants both, distinguished.
      const info = teamPrefixInfo(cwd, teamArg);
      const underlying = teamArg ? teamPrefixInfo(cwd, null) : info;
      out({ alias: underlying.alias, source: underlying.source, teamScope: teamArg, prefix: info.prefix, effective_names_sample: `${info.prefix}-architect` });
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
      if (!herdrOnPath()) {
        fail("transport is herdr (HERDR_ENV=1) but no `herdr` binary is on PATH — cannot place panes. Install herdr, or unset HERDR_ENV to use tmux/terminal.");
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
      const { panes, splits } = runLayoutLoop({ mode, paneCount, self, splitCwd });
      out({ panes, splits, mode, pane_count: paneCount, complete: true });
      break;
    }

    case "create": {
      if ([opts.plan === true, opts.commit === true, opts.spawn === true].filter(Boolean).length > 1) {
        fail("create: --plan, --commit, and --spawn are mutually exclusive");
      }
      const dir = hierarchyDir(cwd);
      // Spec 0015 §7.2: --from without an explicit --team targets the entry's own alias (or the
      // default team when the alias is null) — an explicit --team still wins. Must happen before
      // anything below reads teamArg/repoBasename (naming, file target, history upsert alias).
      if (typeof opts.from === "string" && !teamArg) {
        const entry = resolveHistoryEntry(dir);
        teamArg = entry.alias || null;
        repoBasename = teamPrefix(cwd, teamArg);
        // The stored alias names the team FILE the entry was committed under, so re-derive the
        // scope from it — a null alias (a pre-0044 default team) still resolves through §1.1.
        resolveTeamFileScope();
      }
      guardTeamPrefixCollision(dir, teamFile);
      if (opts.spawn === true) {
        await createSpawn(dir);
        break;
      }
      if (opts.commit) {
        // `--from --commit` (spec 0015 §7.2): --commit still reads members from --verified, not
        // history (only a real spawn/check-in cycle has ref/transport_id/checked_in) — but a
        // stored entry that no longer validates must fail() before anything else runs, so this
        // eager check is the only place --from's validation happens on the commit path.
        if (typeof opts.from === "string") validateHistoryMembers(resolveHistoryEntry(dir));
        const verified = typeof opts.verified === "string" ? JSON.parse(opts.verified) : fail("--commit needs --verified <json array>");
        if (!Array.isArray(verified)) fail(`create --commit: --verified must be a JSON array, got ${typeof verified}`);
        const transport = typeof opts.transport === "string" ? opts.transport : fail("--commit needs --transport");
        const rosterLevel = typeof opts["roster-level"] === "string" ? opts["roster-level"] : fail("--commit needs --roster-level");
        // Spec 0025 §3/§4: --verified is either a JSON array of member objects (validated per
        // validateTeamMember, §3) or member-name strings (hydrated from the --roster-level
        // roster, §4). Mixed shapes, unknown names, or invalid entries fail before any write.
        const allStrings = verified.length > 0 && verified.every((m) => typeof m === "string");
        const allObjects = verified.every((m) => m && typeof m === "object" && !Array.isArray(m));
        let members;
        let needsResync = false;
        if (allStrings) {
          // Spec 0032 §3.4a/§3.4c: reuse resolveRoster's own resolution and no-match predicate
          // directly, rather than re-deriving the container from --roster-level by hand — a
          // hand-rolled predicate drifted from resolveRoster's (`!members.length` vs null-only),
          // so an override with `members: []` was picked here while --plan correctly fell
          // through to the default. resolveRoster is exactly what --plan itself calls.
          const resolved = resolveRoster(cwd, teamArg);
          const rosterMembers = resolved ? resolved.members : [];
          const rosterRoute = resolved ? resolved.route : undefined;
          members = verified.map((name) => {
            const found = rosterMembers.find((m) => m.name === name);
            if (!found) {
              fail(`create --commit: --verified names no member ${JSON.stringify(name)} in the ${rosterLevel} roster — it defines: ${rosterMembers.map((m) => m.name).join(", ") || "(none)"}`);
            }
            return { role: found.role, name: found.name, model: found.model, effort: found.effort, route: found.route || rosterRoute, autoMode: found.autoMode, transport_id: null };
          });
          needsResync = true;
        } else if (allObjects) {
          const offenses = verified.map((m, i) => ({ i, errs: validateTeamMember(m) })).filter((o) => o.errs.length > 0);
          if (offenses.length > 0) {
            const detail = offenses.map((o) => `--verified entry ${o.i} is not a valid member: ${o.errs.join("; ")}`).join(". ");
            fail(`create --commit: ${detail}. --verified takes either a JSON array of member objects (as produced by the spawn/check-in cycle) or a JSON array of member-name strings (hydrated from the roster at --roster-level).`);
          }
          members = verified;
        } else {
          fail("create --commit: --verified must be either all member objects or all member-name strings, not a mix");
        }
        // roster.mjs runs as a transient Bash-tool subprocess, so process.ppid here is
        // that shell, not the orchestrator's own long-lived process — using it would make
        // the staleness sweep (sessionstart.mjs) tear the Team down almost immediately.
        // CLAUDE_PID is the env var every claude session exports as its own pid (see
        // sessionstart.mjs/README's peers.jsonl liveness records, which rely on the same
        // invariant); an explicit --orchestrator-pid overrides it for tests or an
        // unusual environment where the env var isn't propagated.
        const orchestratorPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
        // Spec 0018 §3: an unresolvable or dead owner pid must refuse, not write null — a null
        // pid reads as dead and gets the team swept (deleted) on the next SessionStart.
        if (!Number.isInteger(orchestratorPid)) {
          fail("create --commit: no orchestrator pid resolvable (CLAUDE_PID unset and no --orchestrator-pid given) — refusing to write a team with an unowned pid");
        }
        if (!pidAlive(orchestratorPid)) {
          fail(`create --commit: --orchestrator-pid ${orchestratorPid} is not a live process — refusing to write a team owned by a dead pid`);
        }
        const team = {
          version: 1,
          team_id: newId(),
          created: localIso(),
          roster_level: rosterLevel,
          transport,
          orchestrator: { session_id: typeof opts.session === "string" ? opts.session : null, pid: orchestratorPid },
          members,
          partial: opts.partial === true,
          expected_root: realCwd(cwd),
        };
        writeTeam(dir, team, teamFile);
        // A history-write failure must not fail `create` — the Team is already committed and
        // running; a missing history row is cosmetic (spec 0015 §4).
        const outObj = { committed: true, team };
        // Spec 0025 §4: a hydrated commit has names but no panes yet — tell the caller the next
        // step (`resync`) instead of letting `move` fail confusingly on "no pane to move".
        if (needsResync) outObj.needs_resync = true;
        try {
          const normalized = normalizeMembers(team.members);
          const historyResult = upsertHistory(dir, {
            fingerprint: fingerprint({ roster_level: team.roster_level, transport: team.transport, members: normalized }),
            // The team FILE scope, so `create --from` and historyEntryIsActive resolve back to the
            // file this commit actually wrote (§1.1 moved that off the shared default).
            alias: teamFile || null,
            roster_level: team.roster_level,
            transport: team.transport,
            members: normalized,
            team_id: team.team_id,
          });
          // Spec 0015 §6: exceeding the 5-entry cap because every eviction candidate is a live
          // team is temporary but must not be silent.
          if (historyResult.capExceeded) outObj.history = { ok: true, cap_exceeded: true };
        } catch (err) {
          outObj.history = { ok: false, why: err && err.message ? err.message : String(err) };
        }
        out(outObj);
        break;
      }
      // --plan (default): resolve, refuse a live Team, clear a stale one, report the spawn plan.
      out(getMembersPlan(dir));
      break;
    }

    case "disband": {
      // Spec 0006 §6: an unrecognized flag must fail loudly, not degrade to the (now destructive-
      // by-default) bare path. --kill is accepted-and-ignored (§5.4) for 0002-era callers.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!DISBAND_FLAGS.has(key)) fail(`disband: unrecognized flag --${key} (use --commit, --keep-sessions, --plan, or --close --confirm --plan-token <tok>)`);
      }
      if (opts["keep-sessions"] === true && (opts.commit === true || opts.kill === true)) {
        fail("disband --keep-sessions cannot be combined with --commit or --kill");
      }
      if (opts.close === true && (opts.commit === true || opts["keep-sessions"] === true || opts.kill === true)) {
        fail("disband --close cannot be combined with --commit, --keep-sessions, or --kill");
      }
      const dir = hierarchyDir(cwd);

      // --close (spec 0016 §4.5): closes the live sessions the preceding plan call named, via
      // argv built directly (never runShell's /bin/sh). Does not remove team.json — --commit
      // remains a separate call, per §3.
      if (opts.close === true) {
        const team = readTeam(dir, teamFile);
        if (!team) {
          // Spec 0040 §1.1/§1.3: no team.json — close the live registry peers instead, under the
          // same three gates, with the literal "no-team" standing in for team_id in the token.
          const closable = closableMembers(peerFallbackMembers(dir));
          if (closable.length === 0) {
            out({ closed: false, reason: "no active team and no live peers" });
            break;
          }
          gateClose("disband", "no-team", closable);
          const results = closable.map((m) => closeOne(m, null));
          out({ closed: results.every((r) => r.closed), source: "peers", results });
          break;
        }
        let healedMembers = team.members;
        if (team.transport === "herdr") {
          const result = resyncMembers(team);
          if (result.query_ok) healedMembers = result.members;
        }
        // Spec 0040 §1.4a: the close set is the union of team.json members and live registry
        // peers outside it; the token pins exactly that union.
        const closable = closableMembers([...healedMembers, ...peerExtras(dir, team)]);
        gateClose("disband", team.team_id, closable);
        const results = closable.map((m) => closeOne(m, team.transport));
        out({ closed: results.every((r) => r.closed), results });
        break;
      }

      // --commit: removes team.json only, never re-reads the member list (spec 0002 §8.1/§8.3,
      // spec 0006 §5.2 — no longer gated on --kill).
      if (opts.commit === true) {
        const team = readTeam(dir, teamFile);
        if (!team) {
          out({ removed: false, reason: "no active team" });
          break;
        }
        clearTeam(dir, teamFile);
        out({ removed: teamPath(dir, teamFile) });
        break;
      }

      // --keep-sessions: the old safe default (spec 0006 §5.3) — single call, removes team.json,
      // emits nothing, closes nothing.
      if (opts["keep-sessions"] === true) {
        const team = readTeam(dir, teamFile);
        if (!team) {
          out({ disbanded: false, reason: "no active team" });
          break;
        }
        clearTeam(dir, teamFile);
        out({ disbanded: true, team_id: team.team_id, members: team.members.map((m) => ({ role: m.role, name: m.name, transport_id: m.transport_id })) });
        break;
      }

      // Bare disband / --plan / --kill (ignored): the new default (spec 0006 §5.1). Read-only,
      // emits the close plan, writes nothing. Spec 0008 §5.6 (AMENDMENT): for herdr, resync the
      // member list in memory first — the plan then targets each member's *current* pane — but
      // never persist the heal and never fail() on a query error (degrade to the stored ids).
      const team = readTeam(dir, teamFile);
      if (!team) {
        // Spec 0040 §1.1/§1.5: plan over the live registry peers; `source: "peers"` says so.
        const fallback = peerFallbackMembers(dir);
        const closable = closableMembers(fallback);
        if (closable.length === 0) {
          out({ disbanded: false, reason: "no active team and no live peers" });
          break;
        }
        out({ close: fallback.map(peerFallbackPlanEntry), close_token: closeToken("no-team", closable), source: "peers" });
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
        if (routeHasPane(m.route) && m.transport_id) {
          if (team.transport === "herdr") command = `herdr pane close ${m.transport_id}`;
          else if (team.transport === "tmux") command = `tmux kill-pane -t ${m.transport_id}`;
        }
        const entry = { role: m.role, name: m.name, route: m.route, transport: team.transport, transport_id: m.transport_id, command };
        if (team.transport === "herdr") entry.resync_status = m.status;
        return entry;
      });
      // Spec 0040 §1.4a: live registry peers outside team.json join the plan, labeled, and the
      // token hashes the union — with none present, output and token are exactly the team-only ones.
      const extras = peerExtras(dir, team);
      for (const m of extras) close.push(peerFallbackPlanEntry(m));
      const disbandOut = { close, close_token: closeToken(team.team_id, closableMembers([...healedMembers, ...extras])) };
      if (resyncSummary) disbandOut.resync = resyncSummary;
      out(disbandOut);
      break;
    }

    case "dismiss": {
      // Spec 0020: the missing inverse of `spawn-one` — drop ONE member from a live team.
      // Mirrors disband's plan/close/commit split exactly, scoped to one member; reuses every
      // close-path helper verbatim (§2/§3.3). Do not fork a second close implementation.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!DISMISS_FLAGS.has(key)) fail(`dismiss: unrecognized flag --${key} (use --plan, --close --confirm --plan-token <tok>, or --commit [--also-config] [--level L])`);
      }
      if (opts.close === true && opts.commit === true) fail("dismiss --close cannot be combined with --commit");
      if (opts.plan === true && (opts.close === true || opts.commit === true)) fail("dismiss --plan cannot be combined with --close or --commit");
      if ((opts["also-config"] === true || typeof opts.level === "string") && opts.commit !== true) {
        fail("dismiss: --also-config and --level are only valid with --commit");
      }
      const name = typeof opts._[0] === "string" ? opts._[0] : fail("dismiss needs a member name: roster.mjs dismiss <name> [--plan|--close --confirm --plan-token <tok>|--commit [--also-config]]");
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      if (!team && opts.commit === true) {
        out({ dismissed: false, reason: "no active team" });
        break;
      }
      const target = team ? team.members.find((m) => m.name === name) : null;
      // Spec 0040 §1.4b: a name absent from team.json (or no team.json at all) is looked up in
      // the live registry for plan/--close; --commit is team.json-only and never falls back.
      const fallback = target || opts.commit === true ? [] : peerFallbackMembers(dir);
      const fbTarget = target ? null : fallback.find((m) => m.name === name) || null;
      if (!team && !fbTarget) {
        if (closableMembers(fallback).length === 0) {
          out({ dismissed: false, reason: "no active team and no live peers" });
          break;
        }
        fail(`dismiss: no member named ${JSON.stringify(name)} — no team.json; live peer records have: ${fallback.map((m) => m.name).join(", ")}`);
      }
      if (!target && !fbTarget) {
        if (team.members.some((m) => m.role === name)) {
          fail(`dismiss: no member named ${JSON.stringify(name)} in team ${team.team_id} — that is a role, not a member name; dismiss takes a derived name (0019 §3.2)`);
        }
        fail(`dismiss: no member named ${JSON.stringify(name)} in team ${team.team_id} — it has: ${team.members.map((m) => m.name).join(", ") || "(none)"}${opts.commit === true ? "" : "; checked live peer records too"}`);
      }
      if (fbTarget) {
        // Spec 0040 §1.4b/§1.5: single-record plan/close, same shapes as the team path plus
        // `source: "peers"`; the token scope is the team's id when one exists, else "no-team".
        const scope = team ? team.team_id : "no-team";
        const closable = closableMembers([fbTarget]);
        if (opts.close === true) {
          if (closable.length === 0) fail(`dismiss --close: ${name} has no addressable pane (live peer record without a pane_id)`);
          gateClose("dismiss", scope, closable);
          const results = closable.map((m) => closeOne(m, null));
          out({ closed: results.every((r) => r.closed), source: "peers", results });
          break;
        }
        out({ member: peerFallbackPlanEntry(fbTarget), live: fbTarget.live, close_token: closeToken(scope, closable), source: "peers" });
        break;
      }

      // --close --confirm --plan-token <tok>: reuse disband --close's machinery verbatim.
      if (opts.close === true) {
        let healedMembers = team.members;
        if (team.transport === "herdr") {
          const result = resyncMembers(team);
          if (result.query_ok) healedMembers = result.members;
        }
        const healedTarget = healedMembers.find((m) => m.name === name) || target;
        const closable = closableMembers([healedTarget]);
        if (closable.length === 0) {
          fail(`dismiss --close: ${name} has no addressable pane (route=${target.route}, transport_id=${target.transport_id ?? null}) — use --commit to prune the record`);
        }
        const closeList = closable.map((m) => ({ name: m.name, transport_id: m.transport_id }));
        if (opts.confirm !== true) {
          fail(`dismiss --close: --confirm is required to close a live session. Close list: ${JSON.stringify(closeList)}`);
        }
        if (typeof opts["plan-token"] !== "string" || !opts["plan-token"]) {
          fail("dismiss --close needs --plan-token <tok>, from a preceding `dismiss <name>` (plan) call");
        }
        // §3.3: token scoping is load-bearing and falls out for free — closeToken hashes
        // {team_id, ids:[...]} over exactly THIS member's closable set (one id here, vs a
        // whole-team disband plan's every-id set), so a whole-team token can never authorise
        // this close and this token can never authorise a whole-team close. Do not widen the
        // hash input to "simplify" this later.
        const expectedToken = closeToken(team.team_id, closable);
        if (opts["plan-token"] !== expectedToken) {
          fail("dismiss --close: --plan-token does not match the current close plan (the topology may have changed) — re-run `dismiss` and retry with the fresh token");
        }
        const preResolved = resolveRoster(cwd, teamArg);
        if (preResolved) requireAllowGlobal(preResolved.level, preResolved.path);
        const results = closable.map((m) => {
          try {
            closeMemberPane(team.transport, m.transport_id);
            return { name: m.name, transport_id: m.transport_id, closed: true, error: null };
          } catch (err) {
            return { name: m.name, transport_id: m.transport_id, closed: false, error: err.message };
          }
        });
        out({ closed: results.every((r) => r.closed), results });
        break;
      }

      // --commit [--also-config]: merge-write team.json minus this member. Closes nothing.
      if (opts.commit === true) {
        const outTeam = { ...team, members: team.members.filter((m) => m.name !== name) };
        writeTeam(dir, outTeam, teamFile);
        // §3.4: a commit on a still-live member is allowed, but must never be silent about it.
        // Spec 0043 §1.6: kind-aware, and an indeterminate answer warns too — the whole point of
        // the third value is that "Herdr did not answer" must not be spent as "it is dead".
        const commitState = memberLiveness(dir, target);
        if (commitState.live || commitState.indeterminate) {
          let command = null;
          if (routeHasPane(target.route) && target.transport_id) {
            if (team.transport === "herdr") command = `herdr pane close ${target.transport_id}`;
            else if (team.transport === "tmux") command = `tmux kill-pane -t ${target.transport_id}`;
          }
          process.stderr.write(
            `roster.mjs: ah: ${target.name} ${commitState.indeterminate ? `may still be live — could not determine (${commitState.why})` : `is still live`} (${team.transport} ${target.transport_id}). Its record is gone from team ${team.team_id}.` +
              (command ? ` Close it with \`${command}\` if you did not mean to leave it running.\n` : "\n")
          );
        }
        const teamEmpty = outTeam.members.length === 0;
        if (teamEmpty) {
          process.stderr.write(`roster.mjs: ah: team ${team.team_id} has no members left. If you meant to end the team entirely, use \`disband --commit\`.\n`);
        }
        const dismissOut = {
          dismissed: true,
          member: { role: target.role, name: target.name },
          team_id: team.team_id,
          remaining: outTeam.members.map((m) => m.name),
          team_empty: teamEmpty,
          config: null,
          store: `team ${JSON.stringify(team.team_id)}`,
        };
        if (opts["also-config"] === true) {
          const result = removeConfigMember(target.name);
          if (!result.removed) {
            process.stderr.write(
              `roster.mjs: ah: dismissed ${target.name} from team ${team.team_id}, but no roster member named ${target.name} exists at level "${result.level}" — the config was not changed.\n`
            );
            dismissOut.config = { removed: false, level: result.level, reason: result.reason };
          } else {
            // §3.5.1: ordinal shift. `result.before`/`result.after` are the config's
            // ordinal-derived names before/after this removal, in array order. Everything at or
            // before the removed index is unaffected; every later same-role sibling's ordinal
            // (and therefore derived name) shifts down by one. Warn — never refuse — whenever a
            // shifted name belongs to a member team.json still records as live under the OLD name.
            const reordinaled = [];
            for (let i = result.idx; i < result.before.length - 1; i++) {
              const oldName = result.before[i + 1].name;
              const newName = result.after[i].name;
              if (oldName === newName) continue;
              const teamHasRecord = outTeam.members.some((m) => m.name === oldName);
              // Spec 0043 §1.6: ask the recorded member (kind-aware), not a bare name. An
              // indeterminate answer warns — a Herdr blip must not silently drop the shift notice.
              const oldMember = outTeam.members.find((m) => m.name === oldName);
              const oldState = oldMember ? memberLiveness(dir, oldMember) : null;
              if (teamHasRecord && oldState && (oldState.live || oldState.indeterminate)) reordinaled.push({ from: oldName, to: newName });
            }
            dismissOut.config = { removed: true, level: result.level, path: result.path, reordinaled };
            if (reordinaled.length > 0) {
              const pairs = reordinaled.map((r) => `${r.from} is now derived as ${r.to}`).join(", ");
              process.stderr.write(
                `roster.mjs: ah: removing ${target.name} from the roster re-ordinals later ${target.role} members: ${pairs}. ` +
                  `Live team records keep their original names and still dispatch correctly; a future create/spawn-one will use the new names.\n`
              );
            }
          }
        }
        out(dismissOut);
        break;
      }

      // Bare dismiss / --plan: read-only. For herdr, resync in memory first (0008 §5.6) so the
      // plan names the member's current pane; never persist the heal.
      let healedMembers = team.members;
      if (team.transport === "herdr") {
        const result = resyncMembers(team);
        healedMembers = result.query_ok ? result.members : team.members.map((m) => ({ ...m, status: "unqueried" }));
      }
      const healedTarget = healedMembers.find((m) => m.name === name) || target;
      let command = null;
      if (routeHasPane(healedTarget.route) && healedTarget.transport_id) {
        if (team.transport === "herdr") command = `herdr pane close ${healedTarget.transport_id}`;
        else if (team.transport === "tmux") command = `tmux kill-pane -t ${healedTarget.transport_id}`;
      }
      // §3.2 store split (0019 §3.3.1): `live` reads the registry; `command` reads team.json's
      // transport_id regardless of `live` — a stale-registry member still yields a close command.
      const memberOut = { role: healedTarget.role, name: healedTarget.name, route: healedTarget.route, transport: team.transport, transport_id: healedTarget.transport_id, command };
      if (team.transport === "herdr") memberOut.resync_status = healedTarget.status || "unqueried";
      out({
        member: memberOut,
        // Spec 0043 §1.6 three-valued: `null` is "could not determine", distinct from `false`.
        ...(() => {
          const st = memberLiveness(dir, healedTarget);
          return st.indeterminate ? { live: null, live_unknown: st.why } : { live: st.live };
        })(),
        close_token: closeToken(team.team_id, closableMembers([healedTarget])),
        team_id: team.team_id,
        remaining: team.members.filter((m) => m.name !== name).map((m) => m.name),
      });
      break;
    }

    case "resync": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!RESYNC_FLAGS.has(key)) fail(`resync: unrecognized flag --${key} (use --dry-run, --team, --bind, or --cwd)`);
      }
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      if (!team) {
        out({ resynced: false, reason: "no active team" });
        break;
      }
      if (team.transport !== "herdr") {
        out({ resynced: false, reason: transportNoop(team.transport) });
        break;
      }
      let bind = null;
      if (opts.bind !== undefined) {
        try {
          bind = JSON.parse(opts.bind);
        } catch {
          fail("resync: --bind is not valid JSON");
        }
        if (!bind || typeof bind !== "object" || Array.isArray(bind)) fail("resync: --bind must be a JSON object mapping member name to pane id");
      }
      const result = resyncMembers(team, { dir, teamCwd: findGitRoot(cwd) || cwd, selfPaneId: process.env.HERDR_PANE_ID || null, bind });
      if (!result.query_ok) fail(result.query_error);
      if (result.bind_error) fail(result.bind_error);
      const dryRun = opts["dry-run"] === true;
      const membersOut = result.members.map((m) => {
        if (!m || typeof m !== "object" || Array.isArray(m)) return { status: "malformed", raw: m };
        const entry = { role: m.role, name: m.name, status: m.status };
        if (m.status === "updated") {
          entry.from = m.from;
          entry.to = m.to;
          if (m.match_by) entry.match_by = m.match_by;
        }
        if (m.status === "ambiguous") entry.candidates = m.candidates;
        return entry;
      });
      if (!dryRun) {
        team.members = result.members.map(stripResyncMeta);
        writeTeam(dir, team, teamFile);
      }
      const resyncOut = { resynced: true, dry_run: dryRun, transport: "herdr", members: membersOut, counts: result.counts };
      if (result.warning) resyncOut.warning = result.warning;
      // Spec 0025 §6: a duplicate-pane warning must not silently drop this one, or vice versa —
      // distinct key, since `warning` is an established string field callers already match on.
      if (result.counts.malformed > 0) {
        resyncOut.warning_malformed = `${result.counts.malformed} member(s) in team.json are malformed (not objects) and were left untouched — re-run \`create --commit\` with --verified as an array of member names to repair (spec 0025 §4)`;
      }
      out(resyncOut);
      break;
    }

    case "move": {
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!MOVE_FLAGS.has(key)) fail(`move: unrecognized flag --${key} (use --tab/--split, --new-tab[/--workspace], --new-workspace, or --allow-global)`);
      }
      const name = typeof opts._[0] === "string" ? opts._[0] : fail("move needs a member name: roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace");
      const preResolved = resolveRoster(cwd, teamArg);
      if (preResolved) requireAllowGlobal(preResolved.level, preResolved.path);
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      const teamMembers = team && Array.isArray(team.members) ? team.members : [];
      const member = teamMembers.find((m) => m.name === name);
      if (!member) fail(`move: no member named ${JSON.stringify(name)} — known members: ${teamMembers.map((m) => m.name).filter(Boolean).join(", ") || "(none)"}`);
      if (!routeHasPane(member.route) || member.transport_id == null) fail(`move: member ${name} has no pane to move`);
      if (team.transport !== "herdr") {
        out({ moved: false, reason: transportNoop(team.transport) });
        break;
      }
      const modeCount = [opts.tab !== undefined, opts["new-tab"] === true, opts["new-workspace"] === true].filter(Boolean).length;
      if (modeCount !== 1) fail("move: exactly one of --tab, --new-tab, --new-workspace is required");
      const moveUsage = "roster.mjs move <name> --tab <id> [--split right|down] | --new-tab [--workspace <id>] | --new-workspace";
      if (opts.tab !== undefined && typeof opts.tab !== "string") fail(`move: --tab requires a value: ${moveUsage}`);
      if (opts.tab !== undefined && opts.split === undefined) fail(`move: --tab requires --split right|down: ${moveUsage}`);
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
      writeTeam(dir, team, teamFile);
      const healed = result.members.find((m) => m.name === name);
      const resyncOut = { ok: true, status: healed.status };
      if (healed.status === "updated") {
        resyncOut.from = healed.from;
        resyncOut.to = healed.to;
      }
      if (result.warning) resyncOut.warning = result.warning;
      const noop = healed.status === "unchanged";
      const payload = { moved: !noop, member: { role: member.role, name: member.name }, command: commandString, resync: resyncOut };
      if (noop) {
        payload.reason =
          `no-op: herdr accepted the command but pane ${member.transport_id} is in the same tab and ` +
          `workspace as before (re-query reports no change)`;
      }
      out(payload);
      break;
    }

    case "spawn-one": {
      // Spec 0009 §6: the one operation `create` cannot reach — a live Team with one role
      // dead or never launched. Extracted, not forked, from `createSpawn`'s launch path.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!SPAWN_ONE_FLAGS.has(key)) fail(`spawn-one: unrecognized flag --${key} (use --cwd, --dry-run, --allow-global, --team, --orchestrator-pid, or --member)`);
      }
      out(await spawnOneCore(opts._[0], "spawn-one"));
      break;
    }

    case "spawn-ad-hoc": {
      // Spec 0044 §1.4: the command that was missing. `spawn-one` can only stand up a member the
      // roster already defines, and `add` used to be the only other way to get a member running —
      // which is why an agent asked for a DIVERGENT member reached for the one command that writes
      // the roster. This spawns any member spec, roster-defined or not, matching or diverging, and
      // touches no roster level file under any input (§1.2's anti-requirement).
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!AD_HOC_FLAGS.has(key)) fail(`spawn-ad-hoc: unrecognized flag --${key} (use --role, --model, --effort, --route, --kind, --args, --auto-mode, --on-missing, --team, --cwd, --dry-run, --allow-global, --orchestrator-pid)`);
      }
      const role = typeof opts.role === "string" ? opts.role : opts._[0];
      if (!role) fail("spawn-ad-hoc needs a role: spawn-ad-hoc <role> [--model M] [--kind K] ...");
      if (role === "orchestrator") fail('role "orchestrator" is not a team member — the Orchestrator is whatever session runs create');
      if (!ROLES.includes(role)) fail(`spawn-ad-hoc: --role must be one of ${ROLES.join(", ")}, got ${JSON.stringify(role)}`);
      const adHoc = memberFromFlags(role, "spawn-ad-hoc");
      // §1.4 point 1: the same validation rules, unrelaxed. An ad hoc member has no roster block
      // to inherit from, so its own route IS the effective route — defaulted to "peer", the same
      // superset `add`'s auto-init uses, when the caller does not say.
      adHoc.route = adHoc.route || AUTO_INIT_ROUTE;
      if (adHoc.onMissing !== undefined && adHoc.route === "subagent") {
        fail('on-missing applies only to peer-routed members (this member\'s route is "subagent")');
      }
      const adHocErrors = validateMember(adHoc);
      if (adHocErrors.length) fail(adHocErrors.join("; "));
      if (!routeHasPane(adHoc.route)) {
        fail(`spawn-ad-hoc: route ${JSON.stringify(adHoc.route)} has no session to spawn — a subagent-routed member is dispatched on demand by the Agent tool, so there is nothing to launch`);
      }
      const dir = hierarchyDir(cwd);
      // §1.4 point 5: the name is derived with the TEAM's prefix, against the members that team
      // already holds, so a second member of the same role gets the next ordinal instead of the
      // first one's name. Derived, then checked — a collision refuses rather than overwriting a
      // row that may name a live agent.
      const existingTeam = readTeam(dir, teamFile);
      const sameRole = existingTeam && Array.isArray(existingTeam.members) ? existingTeam.members.filter((m) => m && m.role === role) : [];
      adHoc.name = namedMembers([...sameRole.map((m) => ({ role: m.role })), adHoc]).at(-1).name;
      if (teamMemberNameSet(dir, teamFile).has(adHoc.name)) {
        fail(`spawn-ad-hoc: team ${teamPath(dir, teamFile)} already has a member named ${adHoc.name} — refusing to overwrite its record. Dismiss it first, or spawn into a different --team`);
      }
      requireHerdrName(adHoc, "spawn-ad-hoc");
      out(await spawnOneCore(role, "spawn-ad-hoc", adHoc));
      break;
    }

    case "adopt": {
      // Spec 0018 §5: recovery for a team whose owner pid is null or dead (e.g. hit by the
      // pre-fix null-pid bug) — re-stamps orchestrator.pid without touching members/team_id.
      // Not a hijack primitive: refuses whenever the recorded owner is alive and different.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!ADOPT_FLAGS.has(key)) fail(`adopt: unrecognized flag --${key} (use --orchestrator-pid, --team, or --cwd)`);
      }
      const suppliedPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : NaN;
      if (!Number.isInteger(suppliedPid)) fail("adopt needs --orchestrator-pid <pid>");
      if (!pidAlive(suppliedPid)) fail(`adopt: --orchestrator-pid ${suppliedPid} is not a live process`);
      const dir = hierarchyDir(cwd);
      const team = readTeam(dir, teamFile);
      if (!team) fail("adopt: no team file at this scope to adopt");
      const currentPid = team.orchestrator && team.orchestrator.pid;
      if (currentPid != null && pidAlive(currentPid) && currentPid !== suppliedPid) {
        fail(`adopt: team is owned by live pid ${currentPid} — refusing to hijack a live team (no --force)`);
      }
      team.orchestrator = { ...(team.orchestrator || {}), pid: suppliedPid };
      writeTeam(dir, team, teamFile);
      out({ adopted: true, team_id: team.team_id, orchestrator: team.orchestrator });
      break;
    }

    case "teams": {
      // Spec 0011 §5.4: read-only inventory of every team file in this hierarchy dir — otherwise a
      // stale or a sibling orchestrator's team is invisible. Never writes.
      const dir = hierarchyDir(cwd);
      const myPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : Number(process.env.CLAUDE_PID);
      const rows = allTeamRows(dir, myPid);
      // Spec 0036 §3.6 (F4 fix): a misplaced row is attributed to a specific member ONLY when its
      // own `team` matches this team's identity AND its role names exactly one peer member of
      // THIS team — role alone is not unique across DIFFERENT teams, and §3.5's action on a wrong
      // match is destructive (dismiss+respawn of a healthy peer). A row with no `team` (pre-0036),
      // or a role shared by >1 member of the same team, is never attributed — counted in
      // `misplaced_unattributed` instead: under-reporting is recoverable, mis-reporting is not.
      // Filtered to live rows (status "up" and a live pid — same convention upRecordFor uses) —
      // an unclean exit (crash, killed pane, no SessionEnd) otherwise leaves misplaced:true as the
      // latest row forever, nagging about a peer that no longer exists.
      const liveMisplaced = latestRoster(dir).filter((r) => r.misplaced && r.status === "up" && pidAlive(r.pid));
      for (const row of rows) {
        const t = readTeam(dir, row.name);
        const members = t && Array.isArray(t.members) ? t.members : [];
        const flagged = [];
        let unattributed = 0;
        for (const r of liveMisplaced) {
          // A pre-0036 row (no `team` at all) falls into the default team's bucket — the only
          // shape that existed before named teams — but is NEVER flagged, only counted: T16.
          const hasExplicitTeam = Object.prototype.hasOwnProperty.call(r, "team");
          const rowTeam = hasExplicitTeam ? r.team : null;
          if (rowTeam !== row.name) continue;
          const roleMembers = members.filter((m) => m.role === r.role && routeHasPane(m.route));
          if (hasExplicitTeam && roleMembers.length === 1) flagged.push({ role: r.role, name: roleMembers[0].name, observed_cwd: r.cwd });
          else unattributed++;
        }
        row.misplaced_members = flagged;
        row.misplaced_unattributed = unattributed;
      }
      out({ teams: rows });
      break;
    }

    case "checkin": {
      // Spec 0036 §3.3: the missing re-registration primitive — SessionStart fires once, at
      // launch, so nothing else re-appends to peers.jsonl mid-session. Re-runs §3.2's comparison
      // and appends a fresh row via the same writer sessionstart.mjs:98 uses.
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!CHECKIN_FLAGS.has(key)) fail(`checkin: unrecognized flag --${key} (use --team, --cwd, or --orchestrator-pid)`);
      }
      const dir = hierarchyDir(cwd);
      // roster.mjs runs as a transient Bash-tool subprocess (see :1381's identical warning at
      // create --commit) — process.ppid here is that shell, not the session SessionStart wrote
      // pid: process.ppid FOR (the session itself). Resolve the session pid the same way
      // teams/create --commit already do, falling back to process.ppid only if both are unset.
      let myPid = typeof opts["orchestrator-pid"] === "string" ? Number(opts["orchestrator-pid"]) : NaN;
      if (!Number.isInteger(myPid)) myPid = Number(process.env.CLAUDE_PID);
      if (!Number.isInteger(myPid)) myPid = process.ppid;
      const existing = latestRoster(dir).find((r) => r.pid === myPid);
      if (!existing) fail(`checkin: no existing roster record for pid ${myPid} — SessionStart must run before checkin`);
      // Spec 0036 §3.2/§3.3 (F4/F6): the same shared resolver sessionstart.mjs uses — an explicit
      // --team is a direct lookup (unchanged from before); omitted, it now scans for the one team
      // whose members contain exactly one of this role, instead of silently defaulting.
      // Spec 0044 §1.6: the pane this session sits in is authoritative — the orchestrator wrote it
      // into the member row — so ask that before falling back to the role scan, which under §1.1's
      // concurrent teams is ambiguous far more often than it used to be.
      const resolved = attributeSessionTeam(dir, existing.role, {
        explicitTeam: teamArg,
        paneId: process.env.HERDR_PANE_ID || existing.pane_id || process.env.TMUX_PANE || null,
      });
      // G8: an EXPLICIT --team that resolves to nothing is a typo, not a legitimate absence —
      // 0032 §3.4b's same precedent (add --team X refuses a nonexistent container) rather than
      // silently reporting misplaced:false forever. An omitted --team still skips silently
      // (§3.2 point 3), unaffected.
      if (teamArg && !resolved) fail(`checkin: no such team "${teamArg}"`);
      const team = resolved && resolved.team;
      const expectedRoot = (team && team.expected_root) || null;
      const observed = realCwd(cwd);
      const misplaced = Boolean(expectedRoot) && observed !== expectedRoot;
      const rec = {
        status: "up",
        role: existing.role,
        session_id: existing.session_id || null,
        pid: myPid,
        ppid: process.ppid,
        cwd: observed,
        pane_id: process.env.HERDR_PANE_ID || existing.pane_id || null,
        tab_id: process.env.HERDR_TAB_ID || existing.tab_id || null,
        workspace_id: process.env.HERDR_WORKSPACE_ID || existing.workspace_id || null,
      };
      // §3.2/§3.3: gains `team` when a team resolved — never `name` (see sessionstart.mjs's
      // identical comment; rosterKey/posttooluse-roster.mjs partitioning risk).
      if (resolved) rec.team = resolved.teamName;
      // Spec 0036 §3.1: absent expected_root means no expectation recorded — never write
      // misplaced/expected_root fields in that case, so an old team is never read as a mismatch.
      if (expectedRoot) {
        rec.expected_root = expectedRoot;
        rec.misplaced = misplaced;
      }
      appendRosterRecord(dir, rec);
      out({ checked_in: true, cwd: observed, expected_root: expectedRoot, misplaced });
      if (misplaced) process.exitCode = 1;
      break;
    }

    case "reap": {
      // Spec 0033 §3.2: explicit verb, plan-by-default like `create`/`disband`. Bare form lists
      // orphans and deletes nothing; --commit removes them. Any other flag fails loudly rather
      // than degrading to the destructive path (mirrors disband's guard, §3.2).
      for (const key of Object.keys(opts)) {
        if (key === "_") continue;
        if (!REAP_FLAGS.has(key)) fail(`reap: unrecognized flag --${key} (use --commit)`);
      }
      const dir = hierarchyDir(cwd);
      const orphans = allTeamRows(dir, null).filter((t) => t.orphaned);
      if (opts.commit === true) {
        for (const t of orphans) clearTeam(dir, t.name);
        out({ committed: true, reaped: orphans });
      } else {
        out({ committed: false, orphans });
      }
      break;
    }

    case "history": {
      // Spec 0015 §7.1: read-only inventory of stored roster configs, for `create --from`.
      const dir = hierarchyDir(cwd);
      const h = readHistory(dir);
      const teams = h.teams.map((e) => ({
        id: e.id,
        label: e.label,
        alias: e.alias,
        active: historyEntryIsActive(dir, e),
        last_used: e.last_used,
        created_at: e.created_at,
        roles: [...new Set((e.members || []).map((m) => m.role))],
        member_count: Array.isArray(e.members) ? e.members.length : 0,
        roster_level: e.roster_level,
        transport: e.transport,
      }));
      out({ teams });
      break;
    }

    default:
      fail(`usage: roster.mjs show|init|add|edit|remove|layout|alias|create|next-split|layout-splits|disband|resync|move|spawn-one|spawn-ad-hoc|adopt|teams|reap|history|checkin [--commit|--keep-sessions] [--level global|repo|repo-user] [--team <name>] [--cwd <path>]${cmd ? ` (unknown command ${JSON.stringify(cmd)})` : ""}`);
  }
} catch (err) {
  fail(err && err.message ? err.message : String(err));
}
