#!/bin/bash
# agent-hierarchy — session classification at SessionStart.
#
# `agent_type` is set on BOTH a subagent and a top-level `claude --agent <name>`
# session; only a subagent carries `agent_id`. Testing `agent_type` therefore
# classifies a genuine main session as a subagent and injects nothing into it.
# These cases pin the discriminator, and pin what each kind of session receives.
# Usage: bash tests/test-sessionstart-agent.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# The pane env var is case 1 of the branch and would shadow everything below.
unset AGENT_HIERARCHY_PANE_DIR AGENT_HIERARCHY_PANE_ROLE AGENT_HIERARCHY_PANE_KEY
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID

# A throwaway cwd with no project config, so the resolver sees a stable world.
# HOME and the hierarchy runtime dir are redirected: the hook now writes roster
# and state files at SessionStart, and those must never touch real state.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FAKEHOME="$TMP/home"
HD="$TMP/hier"
PROJ="$TMP/proj"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

start() { # payload JSON on stdin -> hook stdout
  echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" 2>/dev/null
}

classify() { # <field> <value> -> "true"/"false" from the named predicate
  node --input-type=module -e "
    import { isSubagent, isTopLevelAgentSession, hierarchyRoleOf } from '$H/lib-config.mjs';
    const input = JSON.parse(process.argv[1]);
    const fn = { isSubagent, isTopLevelAgentSession };
    process.stdout.write(String(process.argv[2] === 'hierarchyRoleOf'
      ? hierarchyRoleOf(input.agent_type)
      : fn[process.argv[2]](input)));
  " "$1" "$2"
}

# ---- 1-3: the discriminator itself
check "isSubagent: agent_id set -> true" \
  '[ "$(classify "{\"agent_id\":\"a1\",\"agent_type\":\"ah:architect\"}" isSubagent)" = true ]'
# This is the bug. It must fail against the pre-fix code.
check "isSubagent: agent_type set, no agent_id -> FALSE" \
  '[ "$(classify "{\"agent_type\":\"ah:architect\"}" isSubagent)" = false ]'
check "isSubagent: neither set -> false" \
  '[ "$(classify "{\"session_id\":\"s1\"}" isSubagent)" = false ]'
check "isTopLevelAgentSession: agent_type only -> true" \
  '[ "$(classify "{\"agent_type\":\"ah:architect\"}" isTopLevelAgentSession)" = true ]'
check "isTopLevelAgentSession: agent_id too -> false" \
  '[ "$(classify "{\"agent_id\":\"a1\",\"agent_type\":\"ah:architect\"}" isTopLevelAgentSession)" = false ]'
check "hierarchyRoleOf: anchored on (^|:)role\$" \
  '[ "$(classify "{\"agent_type\":\"ah:architect\"}" hierarchyRoleOf)" = architect ]'
check "hierarchyRoleOf: non-role -> null" \
  '[ "$(classify "{\"agent_type\":\"some-plugin:notetaker\"}" hierarchyRoleOf)" = null ]'
check "hierarchyRoleOf: substring must not match" \
  '[ "$(classify "{\"agent_type\":\"some-plugin:architecture\"}" hierarchyRoleOf)" = null ]'

# ---- 4: top-level --agent running a hierarchy role -> the role notice
ROLE_OUT="$(start "{\"session_id\":\"s4\",\"cwd\":\"$TMP\",\"agent_type\":\"ah:architect\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}")"
check "top-level --agent role: emits something" '[ -n "$ROLE_OUT" ]'
check "top-level --agent role: says MAIN session" 'echo "$ROLE_OUT" | grep -q "MAIN session"'
check "top-level --agent role: names the agent_type" 'echo "$ROLE_OUT" | grep -q "ah:architect"'
check "top-level --agent role: NOT told it is the Orchestrator" '! echo "$ROLE_OUT" | grep -q "You are the Orchestrator"'
check "top-level --agent role: no role->model table" '! echo "$ROLE_OUT" | grep -q "Agent(subagent_type:"'
check "top-level --agent role: no pane/relay talk" '! echo "$ROLE_OUT" | grep -qiE "pane|relay"'
check "top-level --agent role: peer msg-protocol addendum" 'echo "$ROLE_OUT" | grep -q "hierarchy-msg"'
check "top-level --agent role: up roster record written" 'grep -q "\"status\":\"up\"" "$HD/peers.jsonl" && grep -q "\"role\":\"architect\"" "$HD/peers.jsonl"'

# ---- 4a (spec 0025 §14 item 19): herdr env vars unset -> pane_id/tab_id/workspace_id null, no throw
check "top-level --agent role: pane_id/tab_id/workspace_id null when env unset" \
  'grep -q "\"pane_id\":null" "$HD/peers.jsonl" && grep -q "\"tab_id\":null" "$HD/peers.jsonl" && grep -q "\"workspace_id\":null" "$HD/peers.jsonl"'

# ---- 4b (spec 0025 §14 item 19): herdr env vars set -> written verbatim, no throw
rm -f "$HD/peers.jsonl"
PANE_OUT="$(echo "{\"session_id\":\"s4b\",\"cwd\":\"$TMP\",\"agent_type\":\"ah:architect\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" HERDR_PANE_ID="wG:p1" HERDR_TAB_ID="wG:t1" HERDR_WORKSPACE_ID="wG" node "$H/sessionstart.mjs" 2>/dev/null)"
check "top-level --agent role: herdr env set -> still emits the role notice, no throw" '[ -n "$PANE_OUT" ]'
check "top-level --agent role: pane_id/tab_id/workspace_id written from env" \
  'grep -q "\"pane_id\":\"wG:p1\"" "$HD/peers.jsonl" && grep -q "\"tab_id\":\"wG:t1\"" "$HD/peers.jsonl" && grep -q "\"workspace_id\":\"wG\"" "$HD/peers.jsonl"'

# ---- 5 + 6a: a non-hierarchy --agent session and an ordinary session agree,
#      and both match what the builders produce for this cwd. Unconfigured cwd
#      -> the nudge, with no state block.
ORDINARY_OUT="$(start "{\"session_id\":\"sX\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"
FOREIGN_OUT="$(start "{\"session_id\":\"sX\",\"cwd\":\"$TMP\",\"agent_type\":\"some-plugin:notetaker\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"
EXPECTED="$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
  import { buildDirective, buildNudge, resolveConfig } from '$H/lib-config.mjs';
  const resolved = resolveConfig('$TMP');
  let context = null;
  if (!resolved.configured) context = buildNudge(resolved);
  else if (resolved.enabled) context = buildDirective(resolved, 'sX');
  if (context) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: context } }));
")"

check "ordinary session: output is byte-identical to the resolver's own text" '[ "$ORDINARY_OUT" = "$EXPECTED" ]'
check "non-hierarchy --agent session: byte-identical to an ordinary session" '[ "$FOREIGN_OUT" = "$ORDINARY_OUT" ]'
check "unconfigured cwd: nudge carries no state block" '! echo "$ORDINARY_OUT" | grep -q "HIERARCHY STATE"'

# ---- 5b: configured + enabled -> directive + HIERARCHY STATE block, and the
#      whole output is byte-identical to the builders given the same extras.
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "model" } } }
EOF
CONF_OUT="$(start "{\"session_id\":\"sC\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"
check "configured session: directive present" 'echo "$CONF_OUT" | grep -q "Agent hierarchy ACTIVE"'
check "configured session: HIERARCHY STATE block appended" 'echo "$CONF_OUT" | grep -q "HIERARCHY STATE" && echo "$CONF_OUT" | grep -q "open exchanges:" && echo "$CONF_OUT" | grep -q "tier:"'
check "configured session: message-protocol items 12-14 in directive" 'echo "$CONF_OUT" | grep -q "MESSAGE FILES" && echo "$CONF_OUT" | grep -q "PEER ROSTER" && echo "$CONF_OUT" | grep -q "TIER RULE"'
CONF_EXPECTED="$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
  import { basename } from 'node:path';
  import { buildDirective, resolveConfig } from '$H/lib-config.mjs';
  import { buildStateBlock, effectiveRoute, ensureHierarchyDir, sessionModel } from '$H/lib-hier.mjs';
  const resolved = resolveConfig('$PROJ');
  const dir = ensureHierarchyDir('$PROJ');
  const model = sessionModel({ session_id: 'sC' }, dir);
  const route = effectiveRoute(dir, resolved, 'sC');
  let context = buildDirective(resolved, 'sC', { hierDir: dir, model, route });
  context += '\n\n' + buildStateBlock(dir, resolved, basename(resolved.cwd), model, 'sC', route);
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: context } }));
")"
check "configured session: byte-identical to buildDirective(extra) + state block" '[ "$CONF_OUT" = "$CONF_EXPECTED" ]'
COMPACT_OUT="$(start "{\"session_id\":\"sC\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}")"
check "compact source: state block re-injected" 'echo "$COMPACT_OUT" | grep -q "HIERARCHY STATE"'

# ---- 6b: a subagent gets nothing at all
SUB_OUT="$(start "{\"session_id\":\"s6\",\"cwd\":\"$TMP\",\"agent_id\":\"a6\",\"agent_type\":\"ah:implementor\",\"hook_event_name\":\"SessionStart\"}")"
check "subagent: no output at all" '[ -z "$SUB_OUT" ]'

# ---- 7: one stdout write site (§8.2a trap 1)
check "sessionstart.mjs writes to stdout exactly once" \
  '[ "$(grep -c "process.stdout.write" "$H/sessionstart.mjs")" -eq 1 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
