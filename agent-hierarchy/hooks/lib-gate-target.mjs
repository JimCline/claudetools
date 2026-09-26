/**
 * agent-hierarchy — what the PreToolUse gates share about a target: which hierarchy role a name
 * stands for, and which `herdr` subcommands a Bash command runs. The ultra-gate and the Herdr-name
 * gate both read targets through here, so the scope rule and the command matcher exist once.
 */

import { hierarchyDir, KIND_DEFAULT, peerName, resolvedPeerTargets, resolveKind, teamPrefix } from "./lib-config.mjs";
import { isGatedPeerTarget } from "./lib-gate.mjs";
import { stripRef } from "./lib-peer.mjs";
import { listTeamNames, readTeam, teamMemberByName } from "./lib-roster.mjs";

/** Herdr's global options that take a value; every other option it accepts is a bare flag. */
const HERDR_VALUE_OPTIONS = new Set(["--session", "--remote", "--remote-keybindings"]);

/**
 * Every `herdr <group> <verb>` in a shell command string (`group` is `agent`, `pane`, …) whose verb
 * is one of `verbs` (a verb may be two words, as `session control`): `{group, verb, name, pane,
 * args}`, where `name` is the first word after the verb that is not a flag, `pane` is its `--pane`,
 * and `args` are the words after the name. Herdr takes its global options (`--session <name>`,
 * `--remote <target>`, a bare flag, …) before the group and between the group and the verb, so
 * those are stepped over. After the verb a flag takes the next word as its value unless written
 * `--flag=value`, and the scan stops at `--`. A backslash-newline continues the line, and the
 * command word may be quoted.
 */
export function herdrCalls(command, group, verbs) {
  const calls = [];
  for (const m of String(command).replace(/\\\n/g, " ").matchAll(/(?<![\w.-])["']?herdr["']?(?=\s)([^;&|\n]*)/g)) {
    const tokens = m[1].trim().split(/\s+/).filter(Boolean).map((t) => t.replace(/^(['"])(.*)\1$/, "$2"));
    let i = 0;
    const skipOptions = () => {
      while (i < tokens.length && tokens[i].startsWith("-") && tokens[i] !== "--") {
        if (HERDR_VALUE_OPTIONS.has(tokens[i++])) i++;
      }
    };
    skipOptions();
    if (tokens[i] !== group) continue;
    i++;
    skipOptions();
    const verb = verbs.find((v) => v.split(" ").every((word, k) => tokens[i + k] === word));
    if (!verb) continue;
    let name = null;
    let pane = null;
    const args = [];
    for (i += verb.split(" ").length; i < tokens.length; i++) {
      const t = tokens[i];
      if (t === "--") break;
      if (t.startsWith("--")) {
        const [flag, inline] = t.split("=", 2);
        const value = inline !== undefined ? inline : tokens[++i];
        if (flag === "--pane") pane = value || null;
        continue;
      }
      if (name === null) name = t;
      else args.push(t);
    }
    if (name !== null) calls.push({ group, verb, name, pane, args });
  }
  return calls;
}

/**
 * The Herdr CLI verbs that write input into a pane, by group. Their target is required: an agent
 * name or its pane's id for `agent`, a pane id for `pane`, and a terminal id or target for
 * `terminal`, whose verbs attach the caller's stdin as the pane's input.
 */
export const HERDR_INPUT_VERBS = {
  agent: ["prompt", "send-keys", "attach"],
  pane: ["send-text", "send-keys", "run"],
  terminal: ["attach", "session control"],
};

/** Every Herdr CLI call in `command` that writes input into a pane. */
export function herdrInputCalls(command) {
  return Object.entries(HERDR_INPUT_VERBS).flatMap(([group, verbs]) => herdrCalls(command, group, verbs));
}

/**
 * The hierarchy role a peer or agent name stands for, among `roles`, as `{role, kind, member}`, or
 * null. A name is a role's when it is `<prefix>-<role>` or `<prefix>-<role>-<n>` on a gated prefix
 * (which needs no team file: `create --spawn` launches members before `--commit` records them), one
 * of the role's configured peer targets, or the recorded name of a member in scope, or the pane id
 * such a member is recorded in (`transport_id`), since Herdr's input verbs also take a pane id. The
 * scope is the session's own team when it resolves one, else the default team and every named team,
 * and the gated prefixes follow it. `kind` is the recorded member's, else that of the role's first
 * non-claude roster row, else claude.
 */
export function gateTarget(toRaw, { resolved, cwd, roles }) {
  if (typeof toRaw !== "string" || !toRaw.trim()) return null;
  const to = stripRef(toRaw.trim());
  const dir = hierarchyDir(cwd);
  const repoBasename = teamPrefix(cwd, resolved.team);
  // A session that could not resolve its own team cannot compute the one correct prefix, so when
  // named teams exist every team's prefix is tested rather than only the default one.
  const teamNames = resolved.team === null ? listTeamNames(dir) : [];
  const gatedPrefixes = teamNames.length > 0 ? [repoBasename, ...teamNames.map((team) => teamPrefix(cwd, team))] : [repoBasename];
  const suffixed = (name) => to.startsWith(`${name}-`) && /^\d+$/.test(to.slice(name.length + 1));
  const byName =
    roles.find(
      (r) =>
        gatedPrefixes.some((prefix) => isGatedPeerTarget(toRaw, peerName(prefix, r)) || suffixed(peerName(prefix, r))) ||
        resolvedPeerTargets(r, resolved.roles[r], repoBasename).some((name) => isGatedPeerTarget(toRaw, name))
    ) || null;
  const teams = resolved.team !== null ? [resolved.team] : [null, ...teamNames];
  const byPane = (team) => {
    const t = readTeam(dir, team);
    return t && Array.isArray(t.members) ? t.members.find((m) => m && typeof m === "object" && m.transport_id === to) || null : null;
  };
  const member = teams.flatMap((team) => [teamMemberByName(dir, to, team), byPane(team)]).find((m) => m && roles.includes(m.role)) || null;
  const role = byName || (member ? member.role : null);
  if (!role) return null;
  if (member && member.role === role) return { role, kind: resolveKind(member), member };
  const rows = resolved.roster && Array.isArray(resolved.roster.members) ? resolved.roster.members : [];
  const foreign = rows.find((m) => m && m.role === role && resolveKind(m) !== KIND_DEFAULT);
  return { role, kind: foreign ? resolveKind(foreign) : KIND_DEFAULT, member: null };
}
