#!/bin/bash
# agent-hierarchy — roster.mjs `create --commit --verified` (spec 0025 §3/§4): validates an
# array of member objects, or hydrates an array of member-name strings from the resolved roster;
# rejects malformed/mixed/unresolvable input before team.json is ever written.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-commit.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-commit-test.XXXXXX")"
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

run() { OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

run init --level repo --route peer
run add --no-spawn --level repo --role reviewer --model opus
run add --no-spawn --level repo --role implementor --model sonnet
# roster now defines: myrepo-reviewer, myrepo-implementor

# ---- 1: names present in the roster -> hydrated, transport_id null, needs_resync true
rm -f "$TEAM_FILE"
run create --commit --verified '["myrepo-reviewer","myrepo-implementor"]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "1: create --commit with roster names succeeds" '[ "$RC" -eq 0 ]'
check "1: team.json holds two well-formed members with transport_id null" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members.length===2&&t.members.every(m=>m.role&&m.name&&m.route&&m.transport_id===null)?0:1)"'
check "1: output carries needs_resync true" \
  'echo "$OUT" | grep -q "\"needs_resync\": true"'

# ---- 2: one name absent from the roster -> non-zero exit, message names it and lists roster names
rm -f "$TEAM_FILE"
run create --commit --verified '["myrepo-reviewer","no-such-member"]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "2: unknown name -> non-zero exit" '[ "$RC" -ne 0 ]'
check "2: message names the unknown name" 'echo "$OUT" | grep -q "no-such-member"'
check "2: message lists the roster names" 'echo "$OUT" | grep -q "myrepo-reviewer" && echo "$OUT" | grep -q "myrepo-implementor"'

# ---- 3: mixed shape (object + string) -> non-zero exit
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":"myrepo-reviewer","role":"reviewer","route":"peer"},"oops"]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "3: mixed --verified -> non-zero exit" '[ "$RC" -ne 0 ]'

# ---- 4: name absent from the roster -> team.json is NOT written (failure precedes the write)
rm -f "$TEAM_FILE"
run create --commit --verified '["nope-not-a-member"]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "4: unresolvable name -> non-zero exit" '[ "$RC" -ne 0 ]'
check "4: team.json was not written" '[ ! -f "$TEAM_FILE" ]'

# ---- 6a: subagent-routed member with name:null (SKILL.md's hand-built recipe shape) -> succeeds
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":null,"role":"reviewer","route":"subagent"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "6a: subagent member with name null succeeds" '[ "$RC" -eq 0 ]'
check "6a: team.json records the member with name still null" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members[0].name===null?0:1)"'

# ---- 6b: subagent-routed member with a real derived name (--spawn auto-mode shape) -> also succeeds
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":"myrepo-reviewer-2","role":"reviewer","route":"subagent"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "6b: subagent member with a real name succeeds" '[ "$RC" -eq 0 ]'

# ---- 6c: name:"" is invalid on every route
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":"","role":"reviewer","route":"subagent"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "6c: subagent member with name \"\" -> non-zero exit" '[ "$RC" -ne 0 ]'
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":"","role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "6c: peer member with name \"\" -> non-zero exit" '[ "$RC" -ne 0 ]'

# ---- 6d: the carve-out is route-scoped -- a PEER-routed member with name:null still fails
rm -f "$TEAM_FILE"
run create --commit --verified '[{"name":null,"role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "6d: peer member with name null -> non-zero exit" '[ "$RC" -ne 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
