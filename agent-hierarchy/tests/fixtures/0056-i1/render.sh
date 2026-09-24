#!/bin/bash
# Renders every surface that must stay byte-identical when no custom roles and no overrides are
# configured: derived role lists, buildDirective (auto/confirm, with and without a roster),
# each built-in's role-session notice, SubagentStart output, and spawn plans for every transport.
# Sandbox paths, the plugin root and the plugin version are normalised so output is comparable
# across runs and across the version bump.
# Usage: bash render.sh <outdir>
set -u
OUTDIR=$1
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd -P)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-0056-i1.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin" "$OUTDIR"
(cd "$PROJ" && git init -q)
cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"
NODE_DIR="$(dirname "$(command -v node)")"

norm() { sed -e "s#$SANDBOX#<SANDBOX>#g" -e "s#$PLUGIN#<PLUGIN>#g" -e 's#(v[0-9][0-9.]*)#(v<VER>)#g'; }

# ---- derived views + directives, from the library directly
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roles":{}}
EOF
HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const Hr = await import('$H/lib-hier.mjs');
  const r = L.resolveConfig('$PROJ');
  const names = ['myrepo-architect','myrepo-reviewer-2','x-advisor','security-reviewer','myrepo-implementor','myrepo-task-runner','nope'];
  const types = ['ah:architect','architect','foo:architect','ah:ultra-advisor','x:ultra-advisor','task-gopher:task-gopher','my-auditor',''];
  const out = {
    ROLES: L.ROLES, ROLE_LABELS: L.ROLE_LABELS, ROLE_DEFAULTS: L.ROLE_DEFAULTS,
    VALID_MODELS_BY_ROLE: L.VALID_MODELS_BY_ROLE, PEER_ELIGIBLE_ROLES: L.PEER_ELIGIBLE_ROLES,
    MSG_ROLES: Hr.MSG_ROLES,
    resolvedRoles: r.roles, resolvedSources: r.sources, warnings: r.warnings,
    subagentType: Object.fromEntries(L.ROLES.map((x) => [x, L.subagentType(x, r.roles[x])])),
    roleFromName: Object.fromEntries(names.map((n) => [n, L.roleFromName(n)])),
    hierarchyRoleOf: Object.fromEntries(types.map((t) => [t, L.hierarchyRoleOf(t)])),
    validateTeamAlias: Object.fromEntries(['architect','myrepo','advisor','ui'].map((a) => [a, L.validateTeamAlias(a)])),
  };
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
" 2>&1 | norm > "$OUTDIR/derived.json"

directive() { # <file> <handoffs> <sessionId|null> <model|null> <route-json|null>
  local f=$1 h=$2 sid=$3 model=$4 route=$5
  node -e "
    const fs=require('fs');const p='$PROJ/.claude/agent-hierarchy.json';
    const d=JSON.parse(fs.readFileSync(p,'utf8'));d.handoffs='$h';fs.writeFileSync(p,JSON.stringify(d));"
  HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$H/lib-config.mjs');
    const r = L.resolveConfig('$PROJ');
    process.stdout.write(L.buildDirective(r, $sid, { hierDir: '/tmp/h', model: $model, route: $route }));
  " 2>&1 | norm > "$OUTDIR/$f"
}
directive directive-auto.txt auto "'s1'" "'opus'" null
directive directive-confirm.txt confirm "'s1'" "'opus'" null
directive directive-auto-nosession.txt auto null null null
directive directive-confirm-subagents.txt confirm "'s1'" "'sonnet'" "{value:'subagents',source:'session'}"

# explicit peer names, a dispatch:model role, a delegate override, and a roster (spawn-one verbs)
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"handoffs":"auto","roles":{"architect":{"model":"opus","peer":["a1","a2"]},"reviewer":{"model":"sonnet","dispatch":"model"},"task-runner":{"model":"haiku","delegate":"none"}},
 "roster":{"route":"peer","members":[{"role":"architect","model":"opus"},{"role":"implementor"},{"role":"reviewer","model":"opus"},{"role":"ultra-advisor","model":"fable"},{"role":"task-runner","model":"haiku"},{"role":"implementor","model":"opus"}]}}
EOF
directive directive-roster-auto.txt auto "'s2'" "'opus'" null
directive directive-roster-confirm.txt confirm "'s2'" "'fable'" "{value:'prefer-peers',source:'config'}"
HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.statusReport('$PROJ') + '\n');
" 2>&1 | norm > "$OUTDIR/status-report.txt"

# ---- spawn plans, all three transports, from the roster above
HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1 | norm > "$OUTDIR/plan-herdr.json"
env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1 | norm > "$OUTDIR/plan-tmux.json"
env -u HERDR_ENV HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1 | norm > "$OUTDIR/plan-terminal.json"
for role in ultra-advisor architect reviewer implementor task-runner; do
  HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" spawn-ad-hoc "$role" --dry-run --cwd "$PROJ" 2>&1 | norm > "$OUTDIR/adhoc-$role.json"
done

# ---- hooks: role-session notices (top-level --agent) and SubagentStart
for role in ultra-advisor architect reviewer implementor task-runner; do
  printf '{"session_id":"sess-%s","cwd":"%s","agent_type":"ah:%s","hook_event_name":"SessionStart","source":"startup"}' "$role" "$PROJ" "$role" \
    | env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>&1 | norm > "$OUTDIR/notice-$role.json"
done
for t in ah:architect task-gopher:task-gopher; do
  printf '{"session_id":"sub-1","cwd":"%s","agent_type":"%s","agent_id":"a123","hook_event_name":"SubagentStart"}' "$PROJ" "$t" \
    | HOME="$FAKEHOME" node "$H/subagentstart-cli-root.mjs" 2>&1 | norm > "$OUTDIR/subagentstart-${t%%:*}.json"
done

# ---- gate decisions per built-in: the tier rule (route gate, session model fable, subagents opted
# in so the peer wall stays out of the way) and the message-file gate (no request file)
cat > "$PROJ/.claude/agent-hierarchy.json" <<'JSON'
{"version":1,"enabled":true,"roles":{}}
JSON
for role in ultra-advisor architect reviewer implementor task-runner; do
  HOME="$FAKEHOME" node "$H/msg.mjs" route subagents --session "gate-$role" --cwd "$PROJ" >/dev/null 2>&1
  printf '{"session_id":"gate-%s","cwd":"%s","model":"claude-fable-5","tool_name":"Agent","tool_input":{"subagent_type":"ah:%s","prompt":"x"},"hook_event_name":"PreToolUse"}' "$role" "$PROJ" "$role" \
    | env -u HERDR_ENV -u HERDR_PANE_ID HOME="$FAKEHOME" node "$H/pretooluse-route-gate.mjs" 2>&1 | norm > "$OUTDIR/gate-route-$role.json"
  printf '{"session_id":"msg-%s","cwd":"%s","tool_name":"Agent","tool_input":{"subagent_type":"ah:%s","prompt":"x"},"hook_event_name":"PreToolUse"}' "$role" "$PROJ" "$role" \
    | env -u HERDR_ENV -u HERDR_PANE_ID HOME="$FAKEHOME" node "$H/pretooluse-msg-gate.mjs" 2>&1 | norm > "$OUTDIR/gate-msg-$role.json"
done
