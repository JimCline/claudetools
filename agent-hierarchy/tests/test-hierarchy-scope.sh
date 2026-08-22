#!/bin/bash
# agent-hierarchy — /hierarchy scope reduction (spec 0001 §8): statusReport
# gains Roster/Team sections; back-compat, resolution with `roles` set and no
# roster is unaffected by the roster machinery entirely.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-hierarchy-scope.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-scope-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

status() { OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const C = await import('$H/lib-config.mjs');
  process.stdout.write(C.statusReport('$PROJ'));
" 2>&1); RC=$?; }

# ---- back-compat: roles set, no roster -> resolution table is exactly today's shape
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": "auto" } } }
EOF
status
check "status: no roster -> 'Roster: none configured' line, roles table still printed" \
  'echo "$OUT" | grep -q "Roster: none configured" && echo "$OUT" | grep -q "Reviewer"'
check "status: no roster -> 'Team: none active' line" 'echo "$OUT" | grep -q "Team: none active"'

# ---- roster present -> status shows level, path, and each member
cat >> "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
EOF
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const d = JSON.parse(fs.readFileSync(p, "utf8"));
  d.roster = { route: "peer", members: [ { role: "architect", model: "opus" } ] };
  fs.writeFileSync(p, JSON.stringify(d, null, 2));
' "$PROJ/.claude/agent-hierarchy.json"
status
check "status: roster present -> level/route/path line" 'echo "$OUT" | grep -qE "Roster: level=repo route=peer path=.*agent-hierarchy\.json"'
check "status: roster present -> member line with derived name" 'echo "$OUT" | grep -q "myrepo-architect"'

# ---- team present -> status shows team id
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs'); const C = await import('$H/lib-config.mjs');
  R.writeTeam(C.hierarchyDir('$PROJ'), { version: 1, team_id: 'tid-1', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal', orchestrator: { session_id: 's', pid: process.pid }, members: [], partial: false });
"
status
check "status: active team -> Team id line" 'echo "$OUT" | grep -q "Team: tid-1"'

# ---- commands/hierarchy.md itself: removed surfaces are gone, roster/team documented, set/route point elsewhere
DOC="$PLUGIN/commands/hierarchy.md"
check "hierarchy.md: no 'set <role> <model>' command heading remains" '! grep -q "^## .set <role> <model>.$" "$DOC"'
check "hierarchy.md: no '/hierarchy route [...]' command heading remains" '! grep -q "^## .route \[peers" "$DOC"'
check "hierarchy.md: set is documented as moved to /agent-roster edit" 'grep -q "/agent-roster edit" "$DOC"'
check "hierarchy.md: route machinery documented as kept, surface moved" 'grep -q "roster.route" "$DOC"'
check "hierarchy.md: status section documents the Roster/Team sections" 'grep -qi "Team.*section" "$DOC"'
check "hierarchy.md: init hands off to /agent-roster init per §7" 'grep -q "/agent-roster init" "$DOC"'
check "hierarchy.md: kept surfaces (status/on/off/flow/gate/usage/msgs/peers/sweep) still present" \
  'grep -q "^## .status.$" "$DOC" && grep -q "^## .on. / .off.$" "$DOC" && grep -q "^## .flow" "$DOC" && grep -q "^## .gate" "$DOC" && grep -q "^## .usage" "$DOC" && grep -q "^## .peers.$" "$DOC" && grep -q "^## .sweep" "$DOC"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
