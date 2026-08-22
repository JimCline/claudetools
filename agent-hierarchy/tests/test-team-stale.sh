#!/bin/bash
# agent-hierarchy — sessionstart.mjs stale-team sweep (spec 0001 §5.3): a
# team.json is cleared when its orchestrator pid is dead OR it is older than
# the 24h age cap; a live, fresh team is left alone; the sweep never runs for
# a `--agent <role>` member session (only a plain top-level session sweeps).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-team-stale.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-stale-test.XXXXXX")"
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

cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true }
EOF

writeTeam() { # <team_id> <pid> <created-iso>
  node --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    R.writeTeam('$HD', { version: 1, team_id: '$1', created: '$3', roster_level: 'repo', transport: 'terminal',
      orchestrator: { session_id: 'orch', pid: $2 }, members: [], partial: false });
  "
}
readTeam() {
  OUT=$(node --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    const t = R.readTeam('$HD');
    process.stdout.write(t ? JSON.stringify(t) : 'null');
  " 2>&1)
}

run() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" 2>&1); RC=$?; }

# ---- dead pid -> swept
writeTeam "dead-1" 2147483000 "$(node -e 'process.stdout.write(new Date().toISOString())')"
run "{\"session_id\":\"s1\",\"cwd\":\"$PROJ\",\"source\":\"resume\",\"hook_event_name\":\"SessionStart\"}"
check "sessionstart injects the sweep note for a dead-pid team" 'echo "$OUT" | grep -q "cleared stale team dead-1"'
readTeam
check "dead-pid team actually cleared from team.json" '[ "$OUT" = null ]'

# ---- fresh + alive pid -> left alone
writeTeam "live-1" "$$" "$(node -e 'process.stdout.write(new Date().toISOString())')"
run "{\"session_id\":\"s2\",\"cwd\":\"$PROJ\",\"source\":\"resume\",\"hook_event_name\":\"SessionStart\"}"
check "sessionstart: no sweep note for a live, fresh team" '! echo "$OUT" | grep -q "cleared stale team"'
readTeam
check "live-pid fresh team left in place" 'echo "$OUT" | grep -q "live-1"'

# ---- alive pid but past the 24h age cap -> swept
writeTeam "old-1" "$$" "$(node -e 'process.stdout.write(new Date(Date.now() - 25*3600*1000).toISOString())')"
run "{\"session_id\":\"s3\",\"cwd\":\"$PROJ\",\"source\":\"resume\",\"hook_event_name\":\"SessionStart\"}"
check "sessionstart: >24h-old team swept even with a live pid" 'echo "$OUT" | grep -q "cleared stale team old-1"'
readTeam
check "old team actually cleared" '[ "$OUT" = null ]'

# ---- a `--agent <role>` member session never sweeps
writeTeam "dead-2" 2147483000 "$(node -e 'process.stdout.write(new Date().toISOString())')"
run "{\"session_id\":\"s4\",\"cwd\":\"$PROJ\",\"agent_type\":\"ah:implementor\",\"source\":\"resume\",\"hook_event_name\":\"SessionStart\"}"
check "role session: no sweep note" '! echo "$OUT" | grep -q "cleared stale team"'
readTeam
check "role session: dead team left untouched (sweep is a plain-session-only safety net)" 'echo "$OUT" | grep -q "dead-2"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
