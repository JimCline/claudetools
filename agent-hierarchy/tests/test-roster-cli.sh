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

# spec 0021: --on-missing round-trips through add/edit/show; invalid value and subagent-route
# combination are rejected; a missing value is never silently parsed as `true`.
run edit --member myrepo-implementor --on-missing auto
check "edit --on-missing: persists the value" 'echo "$OUT" | grep -q "\"onMissing\": \"auto\"" && [ "$RC" -eq 0 ]'
run show
check "edit --on-missing: a subsequent show reports it" 'echo "$OUT" | grep -q "\"onMissing\": \"auto\""'

run edit --member myrepo-implementor --on-missing bogus
check "edit --on-missing: invalid value rejected, listing the three values" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "auto" && echo "$OUT" | grep -q "prompt" && echo "$OUT" | grep -q "never"'

run add --role reviewer --route subagent --on-missing auto
check "add --on-missing with route subagent: rejected" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "on-missing applies only to peer-routed members"'

run add --role reviewer --on-missing
check "add --on-missing with no value: rejected, names --on-missing (never parsed as true)" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "--on-missing"'

# spec 0021 §3.3 (amendment (c) reviewer nit): a non-peer-eligible role's onMissing is inert, and
# show must name the reason, not a bare "(inert)".
run add --role task-runner --on-missing auto
check "add: task-runner accepts on-missing (inert, but not rejected at write time)" '[ "$RC" -eq 0 ]'
STATUS_OUT=$(HOME="$FAKEHOME" node --input-type=module -e '
  import { statusReport } from "'"$H"'/lib-config.mjs";
  process.stdout.write(statusReport(process.argv[1]));
' "$PROJ" 2>&1)
check "statusReport: task-runner's on-missing is marked inert WITH the reason (role is not peer-eligible), not a bare (inert)" \
  'echo "$STATUS_OUT" | grep -q "inert: role is not peer-eligible" && ! echo "$STATUS_OUT" | grep -qE "\(inert\)[^:]"'
run remove --member myrepo-task-runner
check "cleanup: task-runner removed" '[ "$RC" -eq 0 ]'

# spec 0021 §3.2, amendment (c) — the two cases must not collapse into one answer (§3.2.1).
# myrepo-implementor is peer-routed and currently carries onMissing:"auto" from the round-trip
# test above.
run edit --member myrepo-implementor --route subagent --on-missing auto
check "12: edit, --on-missing supplied THIS invocation + route subagent: fails, names the route" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "route is \"subagent\""'
run show
check "12: the failed edit did not mutate the member (still peer, still onMissing auto)" \
  'echo "$OUT" | grep -q "\"name\": \"myrepo-implementor\"" && echo "$OUT" | grep -q "\"onMissing\": \"auto\""'

# ---- 13: the trap — a route switch with NO --on-missing supplied must clear an inherited value
# and warn, never carry it forward into an invalid route:subagent + onMissing:auto state, and never
# hard-fail on a value the user did not type this time.
#
# The must-fail-against-pre-amendment-(c)-code proof was run once by hand (not automated here): a
# validation rule written against a merged `updated` object, without reading supplied-ness from
# `opts` first, hard-fails this exact edit — treating the carried-forward value as "supplied" — which
# is the amendment-(c) defect this fix closes. Not re-automated as a self-mutating test: it would have
# to patch the real `$H/roster.mjs` (this file's own product code) in place, with no interrupt-safe
# restore path, which is unsafe regardless of how careful the backup/restore bookkeeping is. A future
# re-automation belongs in a $SANDBOX-copied, patched fixture — never a write to $PLUGIN — the way
# 0020's hooks.json-matcher must-fail proofs already do it.
run edit --member myrepo-implementor --route subagent
check "13 (post-fix): exit 0" '[ "$RC" -eq 0 ]'
check "13 (post-fix): stderr names the dropped value" 'echo "$OUT" | grep -q "dropped on-missing \"auto\""'
run show
check "13 (post-fix): member's route is now subagent" 'echo "$OUT" | grep -q "\"name\": \"myrepo-implementor\"" && echo "$OUT" | grep -q "\"route\": \"subagent\""'
check "13 (post-fix): onMissing key is absent from the level file (not null, not retained)" \
  '! (echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const m=JSON.parse(s).members.find(x=>x.name===\"myrepo-implementor\");process.exit(\"onMissing\" in m?0:1)})")'

# ---- 14: round-trip — the transition is not one-way
run edit --member myrepo-implementor --route peer --on-missing prompt
check "14: switching back to peer + supplying on-missing again succeeds" '[ "$RC" -eq 0 ]'
run show
check "14: onMissing is back" 'echo "$OUT" | grep -q "\"onMissing\": \"prompt\""'

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
