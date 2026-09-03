#!/bin/bash
# agent-hierarchy — roster.mjs `dismiss <name>` (spec 0020): the missing inverse of `spawn-one` —
# drop ONE member from a live team via disband's plan/close/commit split, scoped to one member.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-dismiss.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-dismiss-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
HIER_DIR="$PROJ/.claude/hierarchy"
TEAM_FILE="$HIER_DIR/team.json"
PEERS_FILE="$HIER_DIR/peers.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr: `agent list` reads $FAKE_HERDR_STATE (defaults to `[]`, an empty topology —
# resync then reports every member not_found but keeps its stored transport_id, same convention
# test-roster-disband-close.sh uses); `pane close` logs and succeeds. Every invocation logged
# verbatim to $INVOKED_LOG.
echo '[]' > "$SANDBOX/agents.json"
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
if (process.env.FAKE_HERDR_INVOKED_LOG) fs.appendFileSync(process.env.FAKE_HERDR_INVOKED_LOG, JSON.stringify(args) + "\n");
if (args[0] === "agent" && args[1] === "list") {
  const agents = JSON.parse(fs.readFileSync(process.env.FAKE_HERDR_STATE, "utf8"));
  console.log(JSON.stringify({ id: "cli:agent:list", result: { agents, type: "agent_list" } }));
  process.exit(0);
}
if (args[0] === "pane" && args[1] === "close") {
  console.log(JSON.stringify({ id: "cli:pane:close", result: { ok: true } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(args) + "\n");
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"
INVOKED_LOG="$SANDBOX/herdr-invoked.log"

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

write_agents() { echo "$1" > "$SANDBOX/agents.json"; }

seed_peer() { # <name> <role> <status> <pid>
  mkdir -p "$(dirname "$PEERS_FILE")"
  "$NODE_BIN" -e 'const fs=require("fs");const[f,n,r,st,p]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4"
}

# 5-member team: architect/implementor/reviewer/ultra-advisor/task-runner, all herdr peers.
write_team() {
  mkdir -p "$HIER_DIR"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "P1", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": "P2", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": "myrepo-reviewer", "ref": "r3", "route": "peer", "model": "opus", "transport_id": "P3", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "ultra-advisor", "name": "myrepo-ultra-advisor", "ref": "r4", "route": "peer", "model": "opus", "transport_id": "P4", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "task-runner", "name": "myrepo-task-runner", "ref": "r5", "route": "peer", "model": "haiku", "transport_id": "P5", "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

plan_token() { # dismiss <name>, prints close_token from stdout
  echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))'
}

# ===========================================================================
# 1. The repro: dismiss a dead member --commit, prune, preserve everything else.
# ===========================================================================
write_team
BEFORE=$(cat "$TEAM_FILE")
run dismiss myrepo-task-runner --commit
check "1: dismiss --commit: exit 0, dismissed true" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"dismissed\": true"'
check "1: 4 members remain" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members.length===4?0:1)"'
check "1: team_id/created/transport/roster_level/orchestrator preserved, other 4 records byte-identical" \
  'node -e "
    const before=JSON.parse(process.argv[1]), after=JSON.parse(require(\"fs\").readFileSync(process.argv[2],\"utf8\"));
    const keep=[\"team_id\",\"created\",\"transport\",\"roster_level\"];
    const ok1=keep.every(k=>JSON.stringify(before[k])===JSON.stringify(after[k]));
    const ok2=JSON.stringify(before.orchestrator)===JSON.stringify(after.orchestrator);
    const survivors=before.members.filter(m=>m.name!==\"myrepo-task-runner\");
    const ok3=JSON.stringify(survivors)===JSON.stringify(after.members);
    process.exit(ok1&&ok2&&ok3?0:1);
  " "$BEFORE" "$TEAM_FILE"'

# ===========================================================================
# 2/9. Plan is read-only; stale registry still yields a command.
# ===========================================================================
write_team
BEFORE=$(cat "$TEAM_FILE")
: > "$INVOKED_LOG"
run dismiss myrepo-architect
check "2: plan emits member/live/close_token/remaining" \
  'echo "$OUT" | grep -q "\"member\"" && echo "$OUT" | grep -q "\"live\"" && echo "$OUT" | grep -q "\"close_token\"" && echo "$OUT" | grep -q "\"remaining\""'
check "2: plan never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'
check "2: team.json byte-identical after plan" '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'
check "9: stale registry (no peers.jsonl entry): live:false, command non-null" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.live===false&&o.member.command?0:1)})"'

# ===========================================================================
# 3/4. Close requires confirm, then a token.
# ===========================================================================
write_team
run dismiss myrepo-architect
TOKEN=$(plan_token)
check "3 setup: plan yields a non-empty close_token" '[ -n "$TOKEN" ]'
run dismiss myrepo-architect --close --plan-token "$TOKEN"
check "3: --close without --confirm: exit non-zero" '[ "$RC" -ne 0 ]'
check "3: --close without --confirm: close list (member name) present in the error" 'echo "$OUT" | grep -q "myrepo-architect"'
run dismiss myrepo-architect --close --confirm
check "4: --close without --plan-token: exit non-zero" '[ "$RC" -ne 0 ]'

# ===========================================================================
# 5. Token must match — a topology move between plan and close invalidates it.
# ===========================================================================
write_team
write_agents '[{"name":"myrepo-task-runner","pane_id":"P5"}]'
run dismiss myrepo-task-runner
TOKEN5=$(plan_token)
write_agents '[{"name":"myrepo-task-runner","pane_id":"P5-MOVED"}]'
run dismiss myrepo-task-runner --close --confirm --plan-token "$TOKEN5"
check "5: token from a plan before a topology move is rejected" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "topology may have changed"'
write_agents '[]'

# ===========================================================================
# 6. Cross-scope token rejection — a whole-team disband token cannot authorise a
#    dismiss close, and a dismiss token cannot authorise a disband close (§3.3).
# ===========================================================================
write_team
run disband
DISBAND_TOKEN=$(plan_token)
run dismiss myrepo-architect --close --confirm --plan-token "$DISBAND_TOKEN"
check "6: a whole-team disband token does not authorise dismiss --close" '[ "$RC" -ne 0 ]'

write_team
run dismiss myrepo-architect
DISMISS_TOKEN=$(plan_token)
run disband --close --confirm --plan-token "$DISMISS_TOKEN"
check "6: a single-member dismiss token does not authorise disband --close" '[ "$RC" -ne 0 ]'

# ===========================================================================
# 7. Close does not prune; a following --commit does.
# ===========================================================================
write_team
run dismiss myrepo-architect
TOKEN7=$(plan_token)
run dismiss myrepo-architect --close --confirm --plan-token "$TOKEN7"
check "7: --close: exit 0, closed true" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"closed\": true"'
check "7: --close: team.json still contains the member" 'grep -q "myrepo-architect" "$TEAM_FILE"'
run dismiss myrepo-architect --commit
check "7: a following --commit removes it" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members.some(m=>m.name===\"myrepo-architect\")?1:0)"'

# ===========================================================================
# 8. Live commit warns.
# ===========================================================================
write_team
: > "$PEERS_FILE"
seed_peer "myrepo-reviewer" "reviewer" "up" "$$"
run dismiss myrepo-reviewer --commit
check "8: --commit on a live member still succeeds" '[ "$RC" -eq 0 ]'
check "8: stderr warns, naming the member and its close command" \
  'echo "$OUT" | grep -q "myrepo-reviewer is still live" && echo "$OUT" | grep -q "herdr pane close P3"'
: > "$PEERS_FILE"

# ===========================================================================
# 10/11. Unknown member; role given instead of a derived name.
# ===========================================================================
write_team
run dismiss no-such-member
check "10: unknown member: exit non-zero, lists the team's actual names" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "myrepo-architect" && echo "$OUT" | grep -q "myrepo-task-runner"'
run dismiss task-runner
check "11: role given instead of a name: exit non-zero, says it is a role" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "that is a role, not a member name"'

# ===========================================================================
# 12. No active team.
# ===========================================================================
rm -f "$TEAM_FILE"
run dismiss anyone
check "12: no active team: exit 0, dismissed:false reason:no active team" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"dismissed\": false" && echo "$OUT" | grep -q "\"reason\": \"no active team\""'

# ===========================================================================
# 13. Last member: members:[], team_empty:true, team.json still exists.
# ===========================================================================
mkdir -p "$HIER_DIR"
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t2", "created": "2026-01-01T00:00:00Z", "roster_level": "repo",
  "transport": "herdr", "orchestrator": { "session_id": null, "pid": null },
  "members": [ {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": "P1"} ],
  "partial": false }
EOF
run dismiss myrepo-architect --commit
check "13: dismissing the only member: team_empty true" 'echo "$OUT" | grep -q "\"team_empty\": true"'
check "13: team.json still exists with members:[]" \
  '[ -e "$TEAM_FILE" ] && node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(Array.isArray(t.members)&&t.members.length===0?0:1)"'

# ===========================================================================
# 14/15/16. --also-config: happy path, ordinal-shift warning, config-miss non-fatal.
# ===========================================================================
run_roster_home() { HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" >/dev/null; }

build_two_implementor_config() {
  rm -f "$PROJ/.claude/agent-hierarchy.json" 2>/dev/null
  find "$PROJ/.claude" -maxdepth 1 -name "*.json" ! -name agent-hierarchy.json -delete 2>/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --model sonnet --cwd "$PROJ" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --model sonnet --cwd "$PROJ" >/dev/null
}
build_two_implementor_config

# 14: happy path — dismiss the second instance, config entry removed too.
mkdir -p "$HIER_DIR"
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t3", "created": "2026-01-01T00:00:00Z", "roster_level": "repo",
  "transport": "herdr", "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet", "transport_id": "P1"},
    {"role": "implementor", "name": "myrepo-implementor-2", "route": "peer", "model": "sonnet", "transport_id": "P2"}
  ], "partial": false }
EOF
run dismiss myrepo-implementor-2 --commit --also-config
check "14: also-config happy path: exit 0, config.removed true, names the level" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"removed\": true" && echo "$OUT" | grep -q "\"level\": \"repo\""'
run show --level repo
check "14: roster.mjs show now lists exactly one implementor" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const impl=o.roster.members.filter(m=>m.role===\"implementor\");process.exit(impl.length===1?0:1)})"'

# 15: ordinal-shift warning — both live, dismiss the FIRST; surviving record keeps its old name.
build_two_implementor_config
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t4", "created": "2026-01-01T00:00:00Z", "roster_level": "repo",
  "transport": "herdr", "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet", "transport_id": "P1"},
    {"role": "implementor", "name": "myrepo-implementor-2", "route": "peer", "model": "sonnet", "transport_id": "P2"}
  ], "partial": false }
EOF
: > "$PEERS_FILE"
seed_peer "myrepo-implementor" "implementor" "up" "$$"
seed_peer "myrepo-implementor-2" "implementor" "up" "$$"
run dismiss myrepo-implementor --commit --also-config
check "15: ordinal-shift: exit 0, stderr names the re-ordinaling" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "re-ordinals later implementor members"'
check "15: output carries config.reordinaled [{from:...-implementor-2,to:...-implementor}]" \
  'echo "$OUT" | sed -n "/^{/,\$p" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const r=o.config.reordinaled;process.exit(Array.isArray(r)&&r.length===1&&r[0].from===\"myrepo-implementor-2\"&&r[0].to===\"myrepo-implementor\"?0:1)})"'
check "15: surviving team.json record is still named myrepo-implementor-2" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members.some(m=>m.name===\"myrepo-implementor-2\")?0:1)"'
: > "$PEERS_FILE"

# 16: also-config miss is not fatal — member in team.json, absent from roster config.
# resolveRoster only matches a level with >=1 member, so the config needs a real (unrelated)
# entry — an empty `members: []` roster would make targetLevel() itself fail to resolve.
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role architect --model opus --cwd "$PROJ" >/dev/null
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t5", "created": "2026-01-01T00:00:00Z", "roster_level": "repo",
  "transport": "herdr", "orchestrator": { "session_id": null, "pid": null },
  "members": [ {"role": "reviewer", "name": "myrepo-reviewer", "route": "peer", "model": "opus", "transport_id": "P1"} ],
  "partial": false }
EOF
run dismiss myrepo-reviewer --commit --also-config
check "16: also-config miss: exit 0, dismissed true, config.removed false with a reason" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"dismissed\": true" && echo "$OUT" | grep -q "\"removed\": false"'
check "16: stderr says the config was not changed" 'echo "$OUT" | grep -q "the config was not changed"'
check "16: team.json IS modified (member removed)" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));process.exit(t.members.length===0?0:1)"'

# ===========================================================================
# 17. Flag misuse.
# ===========================================================================
write_team
run dismiss myrepo-architect --also-config
check "17a: --also-config without --commit: exit non-zero" '[ "$RC" -ne 0 ]'
run dismiss myrepo-architect --level repo
check "17b: --level without --commit: exit non-zero" '[ "$RC" -ne 0 ]'
run dismiss myrepo-architect --close --commit
check "17c: --close --commit: exit non-zero" '[ "$RC" -ne 0 ]'

# ===========================================================================
# 18. Global gate on --close.
# ===========================================================================
rm -f "$PROJ/.claude/agent-hierarchy.json"
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
write_team
run dismiss myrepo-architect
TOKEN18=$(plan_token)
run dismiss myrepo-architect --close --confirm --plan-token "$TOKEN18"
check "18: --close refused without --allow-global when roster resolves at global level" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "allow-global"'
run dismiss myrepo-architect --close --confirm --plan-token "$TOKEN18" --allow-global
check "18: --close --allow-global succeeds" '[ "$RC" -eq 0 ]'
run dismiss myrepo-architect --commit
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"

# ===========================================================================
# 19. Unknown flag — 0006 §6's three conditions: non-zero exit, team.json intact, no plan on stdout.
# ===========================================================================
write_team
BEFORE19=$(cat "$TEAM_FILE")
run dismiss myrepo-architect --bogus-flag
check "19: unknown flag: exit non-zero" '[ "$RC" -ne 0 ]'
check "19: unknown flag: team.json intact" '[ "$(cat "$TEAM_FILE")" = "$BEFORE19" ]'
check "19: unknown flag: no plan on stdout" '! echo "$OUT" | grep -q "\"close_token\""'

# ===========================================================================
# 20. Named team — --team T operates on teams/T.json, default team.json untouched.
# ===========================================================================
write_team
BEFORE20=$(cat "$TEAM_FILE")
run create --team named1 --commit --verified '[{"name":"named1-reviewer","role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "20 setup: create --team named1 --commit succeeds" '[ "$RC" -eq 0 ]'
run dismiss named1-reviewer --commit --team named1
check "20: dismiss --team named1 --commit succeeds" '[ "$RC" -eq 0 ]'
check "20: teams/named1.json now has no members" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$HIER_DIR/teams/named1.json\",\"utf8\"));process.exit(t.members.length===0?0:1)"'
check "20: default team.json untouched" '[ "$(cat "$TEAM_FILE")" = "$BEFORE20" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
