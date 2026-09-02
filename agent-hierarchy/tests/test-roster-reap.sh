#!/bin/bash
# agent-hierarchy — orphaned team reaping (spec 0033): `roster teams` labels orphans
# (dead/null orchestrator pid, never age); `roster reap` lists them (plan, default) or
# removes them (--commit), using `teamIsOrphaned` — never `!teamIsLive`, which would
# also flag a >24h-old but still-running team. HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-reap.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-reap-test.XXXXXX")"
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

# A dead pid that is definitely not reused: spawn+reap a child, use its pid.
( sleep 0 ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null
LIVEPID=$$

writeTeam() { # <name-or-empty> <pid> <created-iso>
  local nameArg="null"
  [ -n "$1" ] && nameArg="'$1'"
  node --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    R.writeTeam('$HD', { version: 1, team_id: 'id-$1$2', created: '$3', roster_level: 'repo', transport: 'terminal',
      orchestrator: { session_id: 'orch', pid: $2 }, members: [], partial: false }, $nameArg);
  "
}
teamExists() { # <name-or-empty>
  local nameArg="null"
  [ -n "$1" ] && nameArg="'$1'"
  OUT=$(node --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    process.stdout.write(R.readTeam('$HD', $nameArg) ? 'yes' : 'no');
  "); RC=$?
}

rcli() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
NOW="$(node -e 'process.stdout.write(new Date().toISOString())')"
OLD="$(node -e 'process.stdout.write(new Date(Date.now()-25*3600*1000).toISOString())')"

# T1/T2: roster teams labels orphaned correctly
writeTeam "hotfix" "$DEADPID" "$NOW"
rcli teams
check "T1: dead-pid named team reports orphaned:true, pid_alive:false" \
  'echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c);process.stdin.on(\"end\",()=>{const t=JSON.parse(d).teams.find(t=>t.name===\"hotfix\");process.exit(t&&t.orphaned===true&&t.pid_alive===false?0:1)})"'
writeTeam "hotfix" "$LIVEPID" "$NOW"
rcli teams
check "T2: live-pid named team reports orphaned:false" \
  'echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c);process.stdin.on(\"end\",()=>{const t=JSON.parse(d).teams.find(t=>t.name===\"hotfix\");process.exit(t&&t.orphaned===false?0:1)})"'

# T3/T4: bare reap lists, deletes nothing; --commit removes and reports it
writeTeam "hotfix" "$DEADPID" "$NOW"
rcli reap
check "T3a: bare reap succeeds" '[ "$RC" -eq 0 ]'
check "T3b: bare reap lists the orphan" 'echo "$OUT" | grep -q hotfix'
teamExists "hotfix"
check "T3c: bare reap deletes nothing — file still exists" '[ "$OUT" = yes ]'
rcli reap --commit
check "T4a: reap --commit succeeds" '[ "$RC" -eq 0 ]'
check "T4b: reap --commit output names the removed team" 'echo "$OUT" | grep -q hotfix'
teamExists "hotfix"
check "T4c: reap --commit actually removed the file" '[ "$OUT" = no ]'

# T5: LIVE named team, created >24h ago; reap --commit must NOT remove it (the §3.3 predicate test)
writeTeam "oldlive" "$LIVEPID" "$OLD"
rcli reap --commit
teamExists "oldlive"
check "T5: a live team is never reaped regardless of age (would fail under !teamIsLive)" '[ "$OUT" = yes ]'
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
" # no-op, keep tooling warm
# clean up
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.clearTeam('$HD', 'oldlive');
"

# T6: mixed — one live, two orphans; reap --commit removes exactly the two orphans
writeTeam "live1" "$LIVEPID" "$NOW"
writeTeam "orph1" "$DEADPID" "$NOW"
writeTeam "orph2" "$DEADPID" "$NOW"
rcli reap --commit
teamExists "live1"; L="$OUT"
teamExists "orph1"; O1="$OUT"
teamExists "orph2"; O2="$OUT"
check "T6: mixed reap removes exactly the two orphans, live team untouched" '[ "$L" = yes ] && [ "$O1" = no ] && [ "$O2" = no ]'
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.clearTeam('$HD', 'live1');
"

# T7: orphaned DEFAULT team (team.json, dead pid); reap --commit removes it too
writeTeam "" "$DEADPID" "$NOW"
rcli reap --commit
teamExists ""
check "T7: reap covers the default team too" '[ "$OUT" = no ]'

# T8: no teams at all — reap and reap --commit are empty, exit 0, no throw
rcli reap
check "T8a: reap with no teams exits 0" '[ "$RC" -eq 0 ]'
rcli reap --commit
check "T8b: reap --commit with no teams exits 0, no throw" '[ "$RC" -eq 0 ]'

# T9: reap --bogus fails loudly; nothing deleted
writeTeam "guardme" "$DEADPID" "$NOW"
rcli reap --bogus
check "T9a: reap --bogus fails loudly" '[ "$RC" -ne 0 ]'
teamExists "guardme"
check "T9b: reap --bogus deleted nothing" '[ "$OUT" = yes ]'
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.clearTeam('$HD', 'guardme');
"

# T10: adopt un-orphans a team; reap --commit does not remove it
writeTeam "adoptme" "$DEADPID" "$NOW"
rcli adopt --team adoptme --orchestrator-pid "$LIVEPID"
check "T10a: adopt succeeds" '[ "$RC" -eq 0 ]'
rcli reap --commit
teamExists "adoptme"
check "T10b: the adopted team is not removed" '[ "$OUT" = yes ]'
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.clearTeam('$HD', 'adoptme');
"

# T11: orchestrator.pid null -> orphaned:true, reaped by --commit
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$HD', { version: 1, team_id: 'id-nullpid', created: '$NOW', roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 'orch', pid: null }, members: [], partial: false }, 'nullpid');
"
rcli teams
check "T11a: null orchestrator.pid reports orphaned:true" \
  'echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c);process.stdin.on(\"end\",()=>{const t=JSON.parse(d).teams.find(t=>t.name===\"nullpid\");process.exit(t&&t.orphaned===true?0:1)})"'
rcli reap --commit
teamExists "nullpid"
check "T11b: null-pid team reaped by --commit" '[ "$OUT" = no ]'

# T12: SessionStart with an orphaned NAMED team present — state block mentions it, file NOT deleted
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "enabled": true }
EOF
writeTeam "crashed" "$DEADPID" "$NOW"
SSOUT=$(echo "{\"session_id\":\"s1\",\"cwd\":\"$PROJ\",\"source\":\"resume\",\"hook_event_name\":\"SessionStart\"}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" 2>&1)
check "T12a: SessionStart state block mentions the orphaned named team" 'echo "$SSOUT" | grep -q "orphaned team record"'
teamExists "crashed"
check "T12b: SessionStart does not delete the orphaned named team's file" '[ "$OUT" = yes ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
