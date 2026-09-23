#!/bin/bash
# agent-hierarchy — roster.mjs disband/dismiss fallback to live peer records when no team.json
# exists (spec 0040), plus disband's mixed whole-set teardown (§1.4a). HOME-redirected; fake herdr
# logs every invocation; fake peer records use this test's own pid so pidAlive is true.
# Usage: bash tests/test-roster-disband-peers.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-disband-peers-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

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
  // A pane closes once: a repeat close of the same id within one invocation log fails the way real herdr does.
  const log = process.env.FAKE_HERDR_INVOKED_LOG;
  if (log && fs.readFileSync(log, "utf8").split("\n").filter((l) => l === JSON.stringify(args)).length > 1) {
    process.stderr.write("pane_not_found\n");
    process.exit(1);
  }
  console.log(JSON.stringify({ id: "cli:pane:close", result: { ok: true } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(args) + "\n");
process.exit(1);
EOF
chmod +x "$SANDBOX/bin/herdr"
INVOKED_LOG="$SANDBOX/herdr-invoked.log"

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
closes() { grep -c '"pane","close"' "$INVOKED_LOG" 2>/dev/null || true; }
jq_() { echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);const v=(new Function("o","return ("+process.argv[1]+")"))(o);console.log(typeof v==="string"?v:JSON.stringify(v))})' "$1"; }

HIER="$PROJ/.claude/hierarchy"
# Spec 0044 §1.1: a team with no `--team` now lives at `teams/<effective-prefix>.json`,
# not the shared `team.json`. The prefix is the repo basename here, so the path is derived
# rather than spelled out — a renamed sandbox repo must not silently stop being checked.
TEAM_FILE="$HIER/teams/$(basename "$PROJ").json"
PEERS_FILE="$HIER/peers.jsonl"
mkdir -p "$HIER"
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"},{"role":"implementor","model":"sonnet"},{"role":"reviewer","model":"opus"}]}}
EOF

# Spec 0046 §2.2: the 6th arg is the checkin `team` TAG. sessionstart.mjs:130 writes
# `resolved.teamName` for every peer whose role resolves to a team, and this sandbox's team lives
# at teams/<basename>.json, so its peers are tagged with that basename. An UNTAGGED row is a peer
# of the legacy default team (team.json) — a different team, which a scoped disband must leave
# alone. Seeding extras untagged was how this fixture encoded the GitHub #4 scoping bug.
seed_peer() { # <name> <role> <status> <pid> [pane_id] [team]
  node -e 'const fs=require("fs");const[f,n,r,st,p,pane,team]=process.argv.slice(1);
    const rec={type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()};
    if(pane) rec.pane_id=pane;
    if(team) rec.team=team;
    fs.appendFileSync(f,JSON.stringify(rec)+"\n");' "$PEERS_FILE" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}"
}
TEAMTAG="$(basename "$PROJ")"
# A checkin row with no `name`: the registry shows it under the synthesized `role@sid8`.
seed_nameless() { # <role> <session_id> <pid> [pane_id] [team]
  node -e 'const fs=require("fs");const[f,r,sid,p,pane,team]=process.argv.slice(1);
    const rec={type:"peer",status:"up",role:r,session_id:sid,pid:Number(p)||undefined,ts:new Date().toISOString()};
    if(pane) rec.pane_id=pane;
    if(team) rec.team=team;
    fs.appendFileSync(f,JSON.stringify(rec)+"\n");' "$PEERS_FILE" "$1" "$2" "$3" "${4:-}" "${5:-}"
}
fresh() { rm -f "$TEAM_FILE" "$PEERS_FILE"; : > "$INVOKED_LOG"; }

write_team() {
  mkdir -p "$(dirname "$TEAM_FILE")"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "PANE1", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": null, "ref": "r3", "route": "subagent", "model": "opus", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

# ---- T1: live records, no team.json -> fallback plan (the falsifying core)
fresh
seed_peer myrepo-architect architect up $$ pA
seed_peer myrepo-implementor implementor up $$ pB
run disband
check "T1: plan exit 0 with source:peers" '[ "$RC" -eq 0 ] && [ "$(jq_ o.source)" = "peers" ]'
check "T1: plan lists both records with close commands" \
  '[ "$(jq_ "o.close.length")" = "2" ] && [ "$(jq_ "o.close.map(c=>c.command).sort().join(\"|\")")" = "herdr pane close pA|herdr pane close pB" ]'
check "T1: plan carries a close_token and no team_id" '[ -n "$(jq_ o.close_token)" ] && [ "$(jq_ "o.team_id===undefined")" = "true" ]'
check "T1: plan invoked no pane close" '[ "$(closes)" = "0" ]'
TOKEN="$(jq_ o.close_token)"

# ---- T3: wrong token -> refused, nothing closed (before T2 so the panes are still "open")
run disband --close --confirm --plan-token wrong-token
check "T3: stale token refused, exit 2, says re-run" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "re-run"'
check "T3: nothing closed" '[ "$(closes)" = "0" ]'
run disband --close --plan-token "$TOKEN"
check "T3b: --close without --confirm refused, close list names both" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q myrepo-architect && echo "$OUT" | grep -q myrepo-implementor && [ "$(closes)" = "0" ]'

# ---- T2: close with the plan's token
run disband --close --confirm --plan-token "$TOKEN"
check "T2: --close exit 0, closed:true, source:peers" '[ "$RC" -eq 0 ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(jq_ o.source)" = "peers" ]'
check "T2: one pane close per member" '[ "$(closes)" = "2" ] && grep -q "\"pA\"" "$INVOKED_LOG" && grep -q "\"pB\"" "$INVOKED_LOG"'
check "T2: results carry both names" '[ "$(jq_ "o.results.map(r=>r.name).sort().join(\",\")")" = "myrepo-architect,myrepo-implementor" ]'
check "T2: no team.json was created" '[ ! -e "$TEAM_FILE" ]'

# ---- T4: no team.json, no records
fresh
run disband
check "T4: plan no-op with extended reason" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.disbanded===false && Object.keys(o).length===3 && o.reason")" = "no active team and no live peers" ]'
run disband --close --confirm --plan-token x
check "T4: --close no-op with extended reason" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.closed===false && Object.keys(o).length===3 && o.reason")" = "no active team and no live peers" ]'
run dismiss myrepo-architect
check "T4: dismiss no-op with extended reason" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.dismissed===false && Object.keys(o).length===3 && o.reason")" = "no active team and no live peers" ]'

# ---- T5: --commit / --keep-sessions byte-identical no-ops without team.json, even with live records
seed_peer myrepo-architect architect up $$ pA
run untrack --all --commit --keep-sessions
check "T5 (0046 §2.3): untrack --all with no team.json is idempotent, closes nothing" '[ "$RC" -eq 0 ] && [ "$(jq_ o.already_untracked)" = "true" ]'
run disband --commit
check "T5 (0046 §3): disband --commit is gone and the error names untrack" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "untrack --all"'
run dismiss myrepo-architect --commit
check "T5 (0046 §3): dismiss --commit is gone and the error names untrack" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "untrack <name>"'
check "T5: nothing closed" '[ "$(closes)" = "0" ]'

# ---- T6: dismiss <name> without team.json
fresh
seed_peer myrepo-architect architect up $$ pA
seed_peer myrepo-implementor implementor up $$ pB
run dismiss myrepo-implementor
check "T6: plan for exactly that member, source:peers" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ o.source)" = "peers" ] && [ "$(jq_ o.member.name)" = "myrepo-implementor" ] && [ "$(jq_ o.member.command)" = "herdr pane close pB" ] && [ "$(jq_ o.live)" = "true" ]'
DTOKEN="$(jq_ o.close_token)"
run disband
check "T6: single-member token differs from the whole-set token" '[ "$(jq_ o.close_token)" != "$DTOKEN" ]'
run dismiss myrepo-implementor --close --confirm --plan-token "$(jq_ o.close_token)"
check "T6: whole-set token cannot authorise the single-member close" '[ "$RC" -eq 2 ] && [ "$(closes)" = "0" ]'
run dismiss myrepo-implementor --close --confirm --plan-token "$DTOKEN"
check "T6: --close closes exactly that member" '[ "$RC" -eq 0 ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(jq_ o.source)" = "peers" ] && [ "$(closes)" = "1" ] && grep -q "\"pB\"" "$INVOKED_LOG"'
run dismiss nobody
check "T6b: unknown name with records -> not-found error listing every visible identifier (0046 §2.1)" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "live untracked sessions" && echo "$OUT" | grep -q myrepo-architect && echo "$OUT" | grep -q "pA"'

# ---- T7c: team.json with zero extras -> plan/token byte-identical to the pre-0040 team path
fresh
write_team
run disband
BASE_OUT="$OUT"
check "T7c: team-only plan has no source field and no extra rows" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.source===undefined")" = "true" ] && [ "$(jq_ "o.close.length")" = "2" ] && [ "$(jq_ "o.close.some(c=>c.source)")" = "false" ]'
BASE_TOKEN="$(jq_ o.close_token)"
# The same plan computed by hand from the team-only close set: token = sha256({team_id, ids}) over PANE1 only.
EXPECT_TOKEN="$(node -e 'const {createHash}=require("crypto");console.log(createHash("sha256").update(JSON.stringify({team_id:"t1",ids:["PANE1"]})).digest("hex").slice(0,16))')"
check "T7c: token is the team-only token" '[ "$BASE_TOKEN" = "$EXPECT_TOKEN" ]'

# ---- T7: mixed — team.json + an extra live peer record
seed_peer myrepo-architect architect up $$ PANE1
seed_peer myrepo-implementor-2 implementor up $$ pX "$TEAMTAG"
run disband
check "T7: plan keeps team rows unchanged and adds the extra labeled source:peers" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "3" ] && [ "$(jq_ "o.close.filter(c=>c.source===\"peers\").map(c=>c.name).join()")" = "myrepo-implementor-2" ] && [ "$(jq_ "o.close[0].source===undefined && o.close[0].name")" = "myrepo-architect" ] && [ "$(jq_ "o.source===undefined")" = "true" ]'
check "T7: a record matching a team member name is that member, not an extra" '[ "$(jq_ "o.close.filter(c=>c.name===\"myrepo-architect\").length")" = "1" ]'
MTOKEN="$(jq_ o.close_token)"
EXPECT_UNION="$(node -e 'const {createHash}=require("crypto");console.log(createHash("sha256").update(JSON.stringify({team_id:"t1",ids:["PANE1","pX"]})).digest("hex").slice(0,16))')"
check "T7: token covers the union" '[ "$MTOKEN" = "$EXPECT_UNION" ] && [ "$MTOKEN" != "$BASE_TOKEN" ]'
run disband --close --plan-token "$MTOKEN"
check "T7: --confirm-less close fails and its list includes the labeled extra" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "myrepo-implementor-2" && echo "$OUT" | grep -q "\"source\":\"peers\""'
run disband --close --confirm --plan-token "$BASE_TOKEN"
check "T7: the team-only token no longer authorises the mixed close" '[ "$RC" -eq 2 ] && [ "$(closes)" = "0" ]'
run disband --close --confirm --plan-token "$MTOKEN"
check "T7: --close closes BOTH team member and extra" \
  '[ "$RC" -eq 0 ] && [ "$(closes)" = "2" ] && grep -q "\"PANE1\"" "$INVOKED_LOG" && grep -q "\"pX\"" "$INVOKED_LOG"'
check "T7: close results label the extra row only" \
  '[ "$(jq_ "o.results.find(r=>r.name===\"myrepo-implementor-2\").source")" = "peers" ] && [ "$(jq_ "o.results.find(r=>r.name===\"myrepo-architect\").source===undefined")" = "true" ] && [ "$(jq_ "o.source===undefined")" = "true" ]'
check "T7: every team row closed -> team file removed" '[ ! -e "$TEAM_FILE" ]'
write_team
: > "$INVOKED_LOG"
run dismiss myrepo-implementor-2
check "T7: dismiss <extra> falls back per-member with the team-scoped single token" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ o.source)" = "peers" ] && [ "$(jq_ o.member.name)" = "myrepo-implementor-2" ] && [ "$(jq_ o.close_token)" = "$(node -e "const {createHash}=require(\"crypto\");console.log(createHash(\"sha256\").update(JSON.stringify({team_id:\"t1\",ids:[\"pX\"]})).digest(\"hex\").slice(0,16))")" ]'
run dismiss myrepo-implementor-2 --close --confirm --plan-token "$(jq_ o.close_token)"
check "T7: dismiss --close on the extra closes exactly it" '[ "$RC" -eq 0 ] && [ "$(closes)" = "1" ] && grep -q "\"pX\"" "$INVOKED_LOG"'
run untrack myrepo-implementor-2 --commit
check "T7 (0046 §2.3): untrack never falls back to a live peer — it names dismiss instead" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "LIVE untracked session" && echo "$OUT" | grep -q "closes it"'

# ---- T7b: plan taken, then a new extra appears -> old token refused
: > "$INVOKED_LOG"
run disband
OLD="$(jq_ o.close_token)"
seed_peer myrepo-reviewer-9 reviewer up $$ pNEW "$TEAMTAG"
run disband --close --confirm --plan-token "$OLD"
check "T7b: token from before the new extra is refused" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "re-run"'
check "T7b: nothing unlisted ever closes" '[ "$(closes)" = "0" ]'

# ---- T11: a nameless registry row on a member's own pane is that member, not an extra
fresh
write_team
seed_nameless architect 47ce3168aaaabbbb $$ PANE1 "$TEAMTAG"
run disband
check "T11: the pane appears once in the plan, as the team row" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.filter(c=>c.transport_id===\"PANE1\").length")" = "1" ] && [ "$(jq_ "o.close.find(c=>c.transport_id===\"PANE1\").source===undefined")" = "true" ] && [ "$(jq_ "o.close.find(c=>c.transport_id===\"PANE1\").name")" = "myrepo-architect" ]'
check "T11: sources still reports the raw per-source yield" '[ "$(jq_ o.sources.team.members)" = "2" ] && [ "$(jq_ o.sources.peers.live)" = "1" ]'
run disband --close --confirm --plan-token "$(jq_ o.close_token)"
check "T11: --close attempts the pane once and succeeds" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.results.filter(r=>r.transport_id===\"PANE1\").length")" = "1" ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(closes)" = "1" ]'
check "T11: no result carries pane_not_found" '[ "$(jq_ "o.results.some(r=>/pane_not_found/.test(r.error||\"\"))")" = "false" ]'

# ---- T12: same, but the stored pane id is stale and only the resync heal lands it on the row's pane
fresh
write_team
sed -i.bak 's/"PANE1"/"PANE_OLD"/' "$TEAM_FILE" && rm -f "$TEAM_FILE.bak"
echo '[{"name":"myrepo-architect","pane_id":"PANE1","tab_id":"T1","workspace_id":"W1"}]' > "$SANDBOX/agents.json"
seed_nameless architect 47ce3168aaaabbbb $$ PANE1 "$TEAMTAG"
run disband
check "T12: healed pane appears once in the plan, as the team row" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.filter(c=>c.transport_id===\"PANE1\").length")" = "1" ] && [ "$(jq_ "o.close.find(c=>c.transport_id===\"PANE1\").resync_status")" = "updated" ] && [ "$(jq_ "o.close.some(c=>c.source)")" = "false" ]'
run disband --close --confirm --plan-token "$(jq_ o.close_token)"
check "T12: --close attempts the healed pane once and succeeds" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.results.filter(r=>r.transport_id===\"PANE1\").length")" = "1" ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(closes)" = "1" ]'
echo '[]' > "$SANDBOX/agents.json"

# ---- T13: a nameless row on a pane no member holds is still an extra, and still closed
fresh
write_team
seed_nameless implementor 99aa77bbccddeeff $$ pFREE "$TEAMTAG"
run disband
check "T13: untracked pane surfaces labeled source:peers under its synthesized name" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.length")" = "3" ] && [ "$(jq_ "o.close.find(c=>c.transport_id===\"pFREE\").source")" = "peers" ] && [ "$(jq_ "o.close.find(c=>c.transport_id===\"pFREE\").name")" = "implementor@99aa77bb" ]'
run disband --close --confirm --plan-token "$(jq_ o.close_token)"
check "T13: both the member pane and the untracked pane close" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(closes)" = "2" ] && grep -q "\"PANE1\"" "$INVOKED_LOG" && grep -q "\"pFREE\"" "$INVOKED_LOG"'

# ---- T14: a paneless nameless row is listed, adds nothing to the token, and is never closed
fresh
write_team
seed_nameless implementor 99aa77bbccddeeff $$ "" "$TEAMTAG"
run disband
check "T14: paneless row listed as an extra with transport_id null and no command" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.find(c=>c.name===\"implementor@99aa77bb\").transport_id")" = "null" ] && [ "$(jq_ "o.close.find(c=>c.name===\"implementor@99aa77bb\").command")" = "null" ] && [ "$(jq_ "o.close.find(c=>c.name===\"implementor@99aa77bb\").source")" = "peers" ]'
check "T14: token is the team-only token" '[ "$(jq_ o.close_token)" = "$EXPECT_TOKEN" ]'
run disband --close --confirm --plan-token "$EXPECT_TOKEN"
check "T14: only the member pane is closed" '[ "$RC" -eq 0 ] && [ "$(closes)" = "1" ] && grep -q "\"PANE1\"" "$INVOKED_LOG" && [ "$(jq_ "o.results.length")" = "1" ]'

# ---- T15: a plan token predating a new untracked pane is refused
fresh
write_team
seed_nameless architect 47ce3168aaaabbbb $$ PANE1 "$TEAMTAG"
run disband
OLD="$(jq_ o.close_token)"
seed_nameless implementor 99aa77bbccddeeff $$ pLATE "$TEAMTAG"
run disband --close --confirm --plan-token "$OLD"
check "T15: stale token refused, exit 2, says re-run, nothing closed" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "re-run" && [ "$(closes)" = "0" ]'

# ---- T9: dead-pid up record and down record are not closable
fresh
seed_peer myrepo-architect architect up 999999999 pDEAD
seed_peer myrepo-implementor implementor up $$ pB
seed_peer myrepo-implementor implementor down $$
seed_peer myrepo-reviewer reviewer up $$ pC
run disband
check "T9: only the live reviewer is in the plan/closable set" \
  '[ "$RC" -eq 0 ] && [ "$(jq_ "o.close.filter(c=>c.command).map(c=>c.name).join()")" = "myrepo-reviewer" ] && [ "$(jq_ "o.close.some(c=>c.name===\"myrepo-implementor\")")" = "false" ]'
run disband --close --confirm --plan-token "$(jq_ o.close_token)"
check "T9: close touches only the live pane" '[ "$RC" -eq 0 ] && [ "$(closes)" = "1" ] && grep -q "\"pC\"" "$INVOKED_LOG" && ! grep -q pDEAD "$INVOKED_LOG"'

# ---- T9b: a live record with no pane_id is listed with command:null and never closed
fresh
seed_peer myrepo-architect architect up $$
run disband
check "T9b: only a no-pane record -> zero closable -> no-op" '[ "$(jq_ "o.disbanded===false && Object.keys(o).length===3 && o.reason")" = "no active team and no live peers" ]'
seed_peer myrepo-reviewer reviewer up $$ pC
run disband
check "T9b: no-pane record listed with command:null beside the closable one" \
  '[ "$(jq_ "o.close.find(c=>c.name===\"myrepo-architect\").command")" = "null" ] && [ "$(jq_ "o.close.length")" = "2" ]'
run dismiss myrepo-architect --close --confirm --plan-token x
check "T9b: dismiss --close on a no-pane record fails before any gate" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no addressable pane" && [ "$(closes)" = "0" ]'

# ---- T10: team exists, name in neither store
fresh
write_team
seed_peer myrepo-implementor-2 implementor up $$ pX "$TEAMTAG"
run dismiss ghost
check "T10: not-found error names the team and lists every live untracked identifier (0046 §2.1)" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no member named" && echo "$OUT" | grep -q "live untracked sessions" && echo "$OUT" | grep -q "pX" && echo "$OUT" | grep -q "myrepo-implementor-2"'
run dismiss architect
check "T10: role-vs-name hint preserved" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "that is a role"'

# ---- T8: structural — one liveness implementation
check "T8: roster.mjs no longer carries the freshness arithmetic" '! grep -q "ROSTER_FRESH_SEC" "$H/roster.mjs"'
check "T8: lib-hier computes the freshness comparison exactly once" '[ "$(grep -c "ageSec < ROSTER_FRESH_SEC" "$H/lib-hier.mjs")" = "1" ]'
check "T8: roster() and livePeerSlots both route through recordLiveness" '[ "$(grep -c "recordLiveness(rec, now)" "$H/lib-hier.mjs")" = "2" ]'
check "T8: the fallback enumerates via livePeerSlots (no second enumeration in roster.mjs)" 'grep -q "livePeerSlots(dir, scope)" "$H/roster.mjs" && [ "$(grep -c "attributedRoster(dir).find((r) => r.name === name)" "$H/roster.mjs")" = "1" ]'
# Spec 0046 §2.2: the scope is the operated-on team's identity, never the --team FLAG. Passing
# `teamArg` here WAS GitHub #4 — a bare disband scoped to null and excluded every tagged peer.
check "T8: peerFallbackMembers never scopes on teamArg again (0046 §2.2)" '! grep -q "livePeerSlots(dir, teamArg" "$H/roster.mjs"'

# ---- the fallback close under a global roster needs no --allow-global
fresh
rm -f "$PROJ/.claude/agent-hierarchy.json"
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
seed_peer myrepo-architect architect up $$ pA
run disband
run disband --close --confirm --plan-token "$(jq_ o.close_token)"
check "global roster: the fallback close proceeds without --allow-global" '[ "$RC" -eq 0 ] && [ "$(closes)" = "1" ]'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
