#!/bin/bash
# agent-hierarchy — roster.mjs CLI: init/add/edit/remove/show, level defaulting,
# orchestrator-role rejection, invalid-level rejection.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-cli.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-cli-test.XXXXXX")"
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

run init --level repo --route peer
check "init: creates roster with route, empty members" 'echo "$OUT" | grep -q "\"route\": \"peer\"" && [ "$RC" -eq 0 ]'

run init --level bogus --route peer
check "init: invalid level rejected" '[ "$RC" -ne 0 ]'

run init --level repo --route bogus
check "init: invalid route rejected" '[ "$RC" -ne 0 ]'

run add --level repo --role reviewer --model opus
check "add: appends a reviewer, derived name returned" 'echo "$OUT" | grep -q "\"name\": \"myrepo-reviewer\"" && [ "$RC" -eq 0 ]'

run add --level repo --role reviewer --model opus
check "add: second reviewer gets -2 suffix" 'echo "$OUT" | grep -q "\"name\": \"myrepo-reviewer-2\"" && [ "$RC" -eq 0 ]'

run add --role orchestrator --model opus
check "add: role orchestrator rejected" '[ "$RC" -ne 0 ]'

run add --level repo --role not-a-role --model opus
check "add: unknown role rejected" '[ "$RC" -ne 0 ]'

run add --role implementor --model sonnet
check "add: no --level given defaults to the resolving level (repo)" 'echo "$OUT" | grep -q "\"level\": \"repo\"" && echo "$OUT" | grep -q "\"wasDefaulted\": true"'

run edit --member myrepo-reviewer-2 --model sonnet
check "edit: updates by derived name" 'echo "$OUT" | grep -q "\"model\": \"sonnet\""'

run edit --member no-such-member --model sonnet
check "edit: unknown member name rejected" '[ "$RC" -ne 0 ]'

run show
check "show: resolved roster lists 3 members" 'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).members.length===3?0:1))"'

run remove --member myrepo-reviewer-2
check "remove: drops the member by derived name" 'echo "$OUT" | grep -q "\"removed\": \"myrepo-reviewer-2\""'

run show
check "show: resolved roster now lists 2 members" 'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).members.length===2?0:1))"'

run remove --member myrepo-reviewer-2
check "remove: re-removing an already-gone member fails" '[ "$RC" -ne 0 ]'

# ---- create --plan: herdr spawn shape carries agent flags after `--`, including --name (0002 Defect D)
run init --level repo --route peer
run add --level repo --role architect --model opus
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1); RC=$?
check "create --plan: herdr transport detected" 'echo "$OUT" | grep -q "\"transport\": \"herdr\""'
check "create --plan: herdr spawn step carries agent flags after --, includes --name (0002 Defect D)" \
  'echo "$OUT" | grep -q "herdr agent start myrepo-architect --kind claude --pane <TARGET> -- --agent ah:architect --name myrepo-architect --model opus"'

# ---- create --commit: orchestrator pid comes from CLAUDE_PID, not the CLI's own ppid
# (spec 0018 §3: the pid must be live at write time, so these use real backgrounded
# sleeps rather than arbitrary numbers — both alive and, by construction, distinct
# from $$, the shell that's actually this script's own pid / roster.mjs's ppid.)
VERIFIED='[{"role":"architect","name":"myrepo-architect","ref":"r1","route":"peer","model":"opus","transport_id":null,"checked_in":"2026-01-01T00:00:00Z"}]'
( sleep 30 ) & ALIVEPID_A=$!
( sleep 30 ) & ALIVEPID_B=$!
OUT=$(HOME="$FAKEHOME" CLAUDE_PID="$ALIVEPID_A" node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --verified "$VERIFIED" --cwd "$PROJ" 2>&1); RC=$?
check "create --commit: orchestrator.pid taken from CLAUDE_PID env, not process.ppid" 'echo "$OUT" | grep -q "\"pid\": $ALIVEPID_A" && ! echo "$OUT" | grep -q "\"pid\": $$"'
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --verified "$VERIFIED" --orchestrator-pid "$ALIVEPID_B" --cwd "$PROJ" 2>&1); RC=$?
check "create --commit: --orchestrator-pid overrides the env var" 'echo "$OUT" | grep -q "\"pid\": $ALIVEPID_B"'
kill "$ALIVEPID_A" "$ALIVEPID_B" 2>/dev/null

# ---- spec 0018 §3/§9: Bash-path refusals — create --commit and spawn-one must never
# write orchestrator.pid: null or a dead pid; both write sites, both distinct messages.
rm -f "$PROJ/.claude/hierarchy/team.json"
OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --verified "$VERIFIED" --cwd "$PROJ" 2>&1); RC=$?
check "create --commit: CLAUDE_PID unset, no --orchestrator-pid -> refuses, exit 2" '[ "$RC" -eq 2 ]'
check "create --commit: CLAUDE_PID unset -> no team.json written" '[ ! -e "$PROJ/.claude/hierarchy/team.json" ]'
MISSING_PID_MSG="$OUT"
OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --verified "$VERIFIED" --orchestrator-pid 99999999 --cwd "$PROJ" 2>&1); RC=$?
check "create --commit: --orchestrator-pid <dead pid> -> refuses, exit 2" '[ "$RC" -eq 2 ]'
check "create --commit: dead --orchestrator-pid -> no team.json written" '[ ! -e "$PROJ/.claude/hierarchy/team.json" ]'
check "create --commit: missing-pid and dead-pid refusals have distinct messages" '[ "$OUT" != "$MISSING_PID_MSG" ]'

# ---- 0004 §11.2: roster.layout validation and the `layout` subcommand
cat > "$SANDBOX/validate-layout.mjs" <<EOF
import { validateRosterBlock } from "$H/lib-roster.mjs";
const bad = validateRosterBlock({ route: "peer", layout: "quadrant", members: [] });
const okAbsent = validateRosterBlock({ route: "peer", members: [] });
console.log(JSON.stringify({ bad, okAbsent }));
EOF
OUT=$(node "$SANDBOX/validate-layout.mjs" 2>&1); RC=$?
check "roster.layout: invalid value rejected, message names the allowed values" \
  'echo "$OUT" | grep -q "auto, columns, grid"'
check "roster.layout: absent key -> no validation error (contrast with roster.route, which must error)" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).okAbsent.length===0?0:1))"'

run layout --level repo --layout grid
check "layout: writes the level file" 'echo "$OUT" | grep -q "\"layout\": \"grid\"" && [ "$RC" -eq 0 ]'
run show --level repo
check "layout: a subsequent show reports the new value" 'echo "$OUT" | grep -q "\"layout\": \"grid\""'

run layout --level repo --layout bogus
check "layout: invalid mode rejected" '[ "$RC" -ne 0 ]'

# a per-member "layout" field is a stray key that validation ignores (there is no per-member layout)
ROSTER_PATH="$PROJ/.claude/agent-hierarchy.json"
node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
data.roster.members[0].layout = "grid";
fs.writeFileSync(process.argv[1], JSON.stringify(data, null, 2));
' "$ROSTER_PATH"
run show --level repo
check "add/edit: a stray per-member layout field is ignored, not rejected" '[ "$RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
