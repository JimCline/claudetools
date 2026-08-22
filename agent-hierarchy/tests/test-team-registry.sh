#!/bin/bash
# agent-hierarchy — team.json check-in registry (lib-roster.mjs) and its
# team-first lookup wired into pretooluse-route-gate.mjs's SendMessage branch
# and roleForPeerName in lib-hier.mjs.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-team-registry.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-registry-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

evalr() { # <js statements over lib-roster as R; last statement's value is written via out(...)>
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    const out = (v) => process.stdout.write(String(v));
    $1
  " 2>&1); RC=$?
}

evalr "out(R.readTeam('$HD'));"
check "readTeam: no team.json -> null" '[ "$OUT" = null ]'

evalr "
  R.writeTeam('$HD', { version: 1, team_id: 't1', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 'orch-1', pid: process.pid }, members: [ { role: 'reviewer', name: 'myrepo-reviewer', ref: 'r1' } ], partial: false });
  out(JSON.stringify(R.readTeam('$HD').members.map(m => m.name)));
"
check "writeTeam + readTeam roundtrip" '[ "$OUT" = "[\"myrepo-reviewer\"]" ]'

evalr "out(JSON.stringify(R.teamMemberByName('$HD', 'myrepo-reviewer')));"
check "teamMemberByName: match returns the member" 'echo "$OUT" | grep -q "\"role\":\"reviewer\""'

evalr "out(R.teamMemberByName('$HD', 'no-such-name'));"
check "teamMemberByName: no match -> null" '[ "$OUT" = null ]'

evalr "R.clearTeam('$HD'); out(R.readTeam('$HD'));"
check "clearTeam: removes the registry" '[ "$OUT" = null ]'

# ---- roleForPeerName (lib-hier.mjs): team.json resolves a name that has no
# config peer/roster entry naming it (team-first per ADR 0002)
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true }
EOF
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
  const L = await import('$H/lib-hier.mjs'); const R = await import('$H/lib-roster.mjs'); const C = await import('$H/lib-config.mjs');
  R.writeTeam('$HD', { version: 1, team_id: 't2', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 'orch-2', pid: process.pid }, members: [ { role: 'architect', name: 'team-only-architect', ref: 'r2' } ], partial: false });
  const resolved = C.resolveConfig('$PROJ');
  process.stdout.write(L.roleForPeerName('team-only-architect', resolved, 'myrepo'));
" 2>&1); RC=$?
check "roleForPeerName: resolves a team-only name via team.json (no config/roster entry needed)" '[ "$OUT" = architect ]'

# ---- route-gate SendMessage branch: same team-only name is recognized as a
# peer-eligible role and reaches the tier gate (proves the gate's own
# team-first lookup, not just lib-hier's)
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "route": "peers" }
EOF
PAYLOAD=$(node -e 'const [cwd]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd,model:"claude-opus-4",tool_name:"SendMessage",tool_input:{to:"team-only-architect",message:"[hierarchy-peer-brief reply-to=\"sender\" task=\"t\"]\n[hierarchy-msg /nowhere]\nq"}}));' "$PROJ")
OUT=$(echo "$PAYLOAD" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
check "route-gate: SendMessage to a team-only-named architect is tier-gated (role resolved via team.json)" 'echo "$OUT" | grep -q "tier rule"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
