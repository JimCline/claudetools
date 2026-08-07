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

# A throwaway cwd with no project config, so the resolver sees a stable world.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

start() { # payload JSON on stdin -> hook stdout
  echo "$1" | node "$H/sessionstart.mjs" 2>/dev/null
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
  '[ "$(classify "{\"agent_id\":\"a1\",\"agent_type\":\"agent-hierarchy:architect\"}" isSubagent)" = true ]'
# This is the bug. It must fail against the pre-fix code.
check "isSubagent: agent_type set, no agent_id -> FALSE" \
  '[ "$(classify "{\"agent_type\":\"agent-hierarchy:architect\"}" isSubagent)" = false ]'
check "isSubagent: neither set -> false" \
  '[ "$(classify "{\"session_id\":\"s1\"}" isSubagent)" = false ]'
check "isTopLevelAgentSession: agent_type only -> true" \
  '[ "$(classify "{\"agent_type\":\"agent-hierarchy:architect\"}" isTopLevelAgentSession)" = true ]'
check "isTopLevelAgentSession: agent_id too -> false" \
  '[ "$(classify "{\"agent_id\":\"a1\",\"agent_type\":\"agent-hierarchy:architect\"}" isTopLevelAgentSession)" = false ]'
check "hierarchyRoleOf: anchored on (^|:)role\$" \
  '[ "$(classify "{\"agent_type\":\"agent-hierarchy:architect\"}" hierarchyRoleOf)" = architect ]'
check "hierarchyRoleOf: non-role -> null" \
  '[ "$(classify "{\"agent_type\":\"some-plugin:notetaker\"}" hierarchyRoleOf)" = null ]'
check "hierarchyRoleOf: substring must not match" \
  '[ "$(classify "{\"agent_type\":\"some-plugin:architecture\"}" hierarchyRoleOf)" = null ]'

# ---- 4: top-level --agent running a hierarchy role -> the role notice
ROLE_OUT="$(start "{\"session_id\":\"s4\",\"cwd\":\"$TMP\",\"agent_type\":\"agent-hierarchy:architect\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}")"
check "top-level --agent role: emits something" '[ -n "$ROLE_OUT" ]'
check "top-level --agent role: says MAIN session" 'echo "$ROLE_OUT" | grep -q "MAIN session"'
check "top-level --agent role: names the agent_type" 'echo "$ROLE_OUT" | grep -q "agent-hierarchy:architect"'
check "top-level --agent role: NOT told it is the Orchestrator" '! echo "$ROLE_OUT" | grep -q "You are the Orchestrator"'
check "top-level --agent role: no role->model table" '! echo "$ROLE_OUT" | grep -q "Agent(subagent_type:"'
check "top-level --agent role: no pane/relay talk" '! echo "$ROLE_OUT" | grep -qiE "pane|relay"'

# ---- 5 + 6a: a non-hierarchy --agent session and an ordinary session agree,
#      and both match what the builders produce for this cwd (the pre-change
#      behaviour of the only path this change does not touch).
ORDINARY_OUT="$(start "{\"session_id\":\"sX\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"
FOREIGN_OUT="$(start "{\"session_id\":\"sX\",\"cwd\":\"$TMP\",\"agent_type\":\"some-plugin:notetaker\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"
EXPECTED="$(node --input-type=module -e "
  import { buildDirective, buildNudge, resolveConfig } from '$H/lib-config.mjs';
  const resolved = resolveConfig('$TMP');
  let context = null;
  if (!resolved.configured) context = buildNudge(resolved);
  else if (resolved.enabled) context = buildDirective(resolved, 'sX');
  if (context) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: context } }));
")"

check "ordinary session: output is byte-identical to the resolver's own text" '[ "$ORDINARY_OUT" = "$EXPECTED" ]'
check "non-hierarchy --agent session: byte-identical to an ordinary session" '[ "$FOREIGN_OUT" = "$ORDINARY_OUT" ]'

# ---- 6b: a subagent gets nothing at all
SUB_OUT="$(start "{\"session_id\":\"s6\",\"cwd\":\"$TMP\",\"agent_id\":\"a6\",\"agent_type\":\"agent-hierarchy:implementor\",\"hook_event_name\":\"SessionStart\"}")"
check "subagent: no output at all" '[ -z "$SUB_OUT" ]'

# ---- 7: one stdout write site (§8.2a trap 1)
check "sessionstart.mjs writes to stdout exactly once" \
  '[ "$(grep -c "process.stdout.write" "$H/sessionstart.mjs")" -eq 1 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
