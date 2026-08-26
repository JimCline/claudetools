#!/bin/bash
# agent-hierarchy — team-history.json (spec 0015): fingerprint dedupe, LRU eviction, derived
# active/idle, and `create --from`. HOME-redirected; real state untouched.
# Usage: bash tests/test-team-history.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-history-test.XXXXXX")"
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
HISTORY_FILE="$PROJ/.claude/hierarchy/team-history.json"
DEAD_PID=999999
LIVE_PID=$$

json_field() { echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);console.log($1)})"; }

# member(role, model, effort, route, automode) -> one verified-array member JSON object
member() {
  local role=$1 model=$2 effort=$3 route=$4 automode=$5
  echo "{\"role\":\"$role\",\"name\":\"n\",\"ref\":\"r\",\"route\":\"$route\",\"model\":\"$model\",\"effort\":\"$effort\",\"autoMode\":\"$automode\",\"transport_id\":\"P\",\"checked_in\":\"2026-01-01T00:00:00Z\"}"
}

commit() {
  # commit <pid|DEAD_PID> <verified_json_array> [--team T]
  # spec 0018 §3: create --commit needs a genuinely live pid at write time. LIVE_PID ($$,
  # this script) stays alive for the whole run. DEAD_PID is a sentinel: spawn a real
  # process, commit with its (momentarily live) pid, then kill it — the entry reads
  # non-live immediately after, matching every caller's original "not live" intent.
  local pid=$1; local verified=$2; shift 2
  if [ "$pid" = "$DEAD_PID" ]; then
    ( sleep 30 ) & pid=$!
    run create --commit --verified "$verified" --transport terminal --roster-level repo --orchestrator-pid "$pid" "$@"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return
  fi
  run create --commit --verified "$verified" --transport terminal --roster-level repo --orchestrator-pid "$pid" "$@"
}

# ---- baseline: no history file present, history reads back empty (spec §11/§12)
run history
check "history: no team-history.json present -> {\"teams\":[]}" '[ "$RC" -eq 0 ] && [ "$(json_field "o.teams.length")" = "0" ]'

# ---- commit twice with different rosters -> 2 entries, distinct fingerprints, newest first
CONFIG_A="[$(member architect opus high peer acceptEdits)]"
CONFIG_B="[$(member architect opus high peer acceptEdits),$(member implementor sonnet medium peer auto)]"
commit "$DEAD_PID" "$CONFIG_A"
check "commit A: exit 0" '[ "$RC" -eq 0 ]'
commit "$DEAD_PID" "$CONFIG_B"
check "commit B: exit 0" '[ "$RC" -eq 0 ]'
run history
check "history: 2 distinct-config commits -> 2 entries" '[ "$(json_field "o.teams.length")" = "2" ]'
FP_A_ID=$(json_field "o.teams[1].id")
FP_B_ID=$(json_field "o.teams[0].id")
check "history: newest first (B before A)" '[ -n "$FP_B_ID" ] && [ "$FP_A_ID" != "$FP_B_ID" ]'

# ---- commit twice with the SAME roster -> 1 more entry only (not 2), created_at unchanged
run history
BEFORE_COUNT=$(json_field "o.teams.length")
run history --json
CREATED_BEFORE=$(json_field "o.teams.find(t=>t.id===\"$FP_A_ID\").created_at")
commit "$DEAD_PID" "$CONFIG_A"
run history
AFTER_COUNT=$(json_field "o.teams.length")
check "commit same roster again: entry count unchanged" '[ "$BEFORE_COUNT" = "$AFTER_COUNT" ]'
CREATED_AFTER=$(json_field "o.teams.find(t=>t.id===\"$FP_A_ID\").created_at")
check "commit same roster again: created_at unchanged" '[ "$CREATED_BEFORE" = "$CREATED_AFTER" ]'

# ---- same roster under --team a then --team b -> 1 entry, alias now b
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$DEAD_PID" "$CONFIG_A" --team a
commit "$DEAD_PID" "$CONFIG_A" --team b
run history
check "same roster under --team a then --team b: 1 entry" '[ "$(json_field "o.teams.length")" = "1" ]'
check "same roster under --team a then --team b: alias now b" '[ "$(json_field "o.teams[0].alias")" = "b" ]'
rm -f "$PROJ/.claude/hierarchy/teams/a.json" "$PROJ/.claude/hierarchy/teams/b.json"

# ---- stored members contain exactly the five §3.1 keys; regression test for the amendment
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$DEAD_PID" "[$(member architect opus high peer acceptEdits)]"
STORED_KEYS_JSON="$(node -e "console.log(JSON.stringify(Object.keys(JSON.parse(require('fs').readFileSync('$HISTORY_FILE','utf8')).teams[0].members[0]).sort()))")"
check "stored member: exactly role/model/effort/route/auto_mode, sorted" \
  '[ "$STORED_KEYS_JSON" = "[\"auto_mode\",\"effort\",\"model\",\"role\",\"route\"]" ]'
check "stored member: no launch_status/launch_result/retried/error/ref/transport_id/checked_in/name" \
  '! echo "$STORED_KEYS_JSON" | grep -qE "launch_status|launch_result|retried|error|\"ref\"|transport_id|checked_in|\"name\""'

# ---- 6 distinct dead configs -> 5 entries retained, oldest last_used evicted
# (localIso has 1s resolution; sleep between commits so last_used actually orders them)
rm -f "$HISTORY_FILE" "$TEAM_FILE"
for e in low medium high xhigh max; do
  commit "$DEAD_PID" "[$(member architect opus "$e" peer acceptEdits)]"
  sleep 1.1
done
run history
check "6th distinct dead config triggers no eviction yet at 5: 5 entries so far" '[ "$(json_field "o.teams.length")" = "5" ]'
OLDEST_ID=$(json_field "o.teams[4].id")
commit "$DEAD_PID" "[$(member implementor sonnet high peer acceptEdits)]"
run history
check "6 distinct dead configs: capped at 5 entries" '[ "$(json_field "o.teams.length")" = "5" ]'
check "6 distinct dead configs: oldest (by last_used) evicted" \
  '! echo "$OUT" | grep -q "$OLDEST_ID"'

# ---- 6 configs where 5 are live, the 6th is a brand-new non-live entry -> 6 entries retained,
# cap_exceeded note (spec §6, amended: the just-upserted entry is excluded from eviction
# candidates unconditionally — this is the regression case that fails against the
# pre-amendment pseudocode, which had only the 6th non-live entry as a candidate and evicted it
# right back down to 5 on the same write that created it).
rm -f "$HISTORY_FILE" "$TEAM_FILE"
for e in low medium high xhigh max; do
  commit "$LIVE_PID" "[$(member architect opus "$e" peer acceptEdits)]" --team "live-$e"
done
commit "$DEAD_PID" "[$(member implementor sonnet high peer acceptEdits)]"
check "6th commit (non-live), 5 pre-existing entries live: cap_exceeded note in output" \
  '[ "$(json_field "o.history.cap_exceeded")" = "true" ]'
run history
check "6 configs, 5 live + new non-live 6th: all 6 entries retained (self-eviction regression)" \
  '[ "$(json_field "o.teams.length")" = "6" ]'
for e in low medium high xhigh max; do rm -f "$PROJ/.claude/hierarchy/teams/live-$e.json"; done

# ---- history on a project with a live team -> active:true; kill the pid -> active:false
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$LIVE_PID" "$CONFIG_A"
run history
check "live team: active:true" '[ "$(json_field "o.teams[0].active")" = "true" ]'
commit "$DEAD_PID" "$CONFIG_A"
run history
check "orchestrator pid dead: active:false" '[ "$(json_field "o.teams[0].active")" = "false" ]'

# ---- alias reuse: create backend config A, disband, create backend config B -> 2 entries,
# only B active while B runs
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$LIVE_PID" "$CONFIG_A" --team backend
run disband --commit --team backend
commit "$LIVE_PID" "$CONFIG_B" --team backend
run history
check "alias reuse: 2 entries" '[ "$(json_field "o.teams.length")" = "2" ]'
check "alias reuse: only the current (B) config is active" \
  '[ "$(json_field "o.teams.find(t=>JSON.stringify(t.roles)===JSON.stringify([\"architect\",\"implementor\"])).active")" = "true" ] && [ "$(json_field "o.teams.find(t=>JSON.stringify(t.roles)===JSON.stringify([\"architect\"])).active")" = "false" ]'
rm -f "$PROJ/.claude/hierarchy/teams/backend.json"

# ---- create --from <id> --plan: role/model/effort/route match stored, autoMode present
# (camelCase, auto_mode absent), name/spawn freshly derived for a different --team
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$DEAD_PID" "[$(member architect opus high peer acceptEdits)]"
run history
FROM_ID=$(json_field "o.teams[0].id")
run create --from "$FROM_ID" --plan --team newteam
check "create --from --plan: exit 0" '[ "$RC" -eq 0 ]'
check "create --from --plan: role/model/effort/route match stored" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members[0];process.exit(m.role===\"architect\"&&m.model===\"opus\"&&m.effort===\"high\"&&m.route===\"peer\"?0:1)})"'
check "create --from --plan: autoMode present (camelCase), auto_mode absent" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members[0];process.exit(m.autoMode===\"acceptEdits\"&&m.auto_mode===undefined?0:1)})"'
check "create --from --plan: name reflects the new --team prefix" \
  'echo "$OUT" | grep -q "newteam-architect"'

# ---- create --from <id> without --team defaults the team scope to the entry's own stored
# alias (spec §7.2) -- and an explicit --team still overrides it
rm -f "$TEAM_FILE" "$PROJ/.claude/hierarchy/teams/origteam.json" "$PROJ/.claude/hierarchy/teams/overrideteam.json"
commit "$DEAD_PID" "[$(member reviewer opus medium peer acceptEdits)]" --team origteam
run disband --commit --team origteam
run history
FROM_ALIASED_ID=$(json_field "o.teams.find(t=>t.alias===\"origteam\").id")
run create --from "$FROM_ALIASED_ID" --plan
check "create --from without --team: name uses the entry's own alias as prefix" \
  'echo "$OUT" | grep -q "origteam-reviewer"'
( sleep 30 ) & FROM_COMMIT_PID=$!
run create --from "$FROM_ALIASED_ID" --commit --transport terminal --verified "[$(member reviewer opus medium peer acceptEdits)]" --roster-level repo --orchestrator-pid "$FROM_COMMIT_PID"
kill "$FROM_COMMIT_PID" 2>/dev/null; wait "$FROM_COMMIT_PID" 2>/dev/null
check "create --from without --team: commit writes teams/origteam.json" '[ -e "$PROJ/.claude/hierarchy/teams/origteam.json" ]'
run history
check "create --from without --team: history row's alias is still origteam (not overwritten to null)" \
  '[ "$(json_field "o.teams.find(t=>t.id===\"$FROM_ALIASED_ID\").alias")" = "origteam" ]'
run disband --commit --team origteam
run create --from "$FROM_ALIASED_ID" --plan --team overrideteam
check "create --from with an explicit --team: explicit --team still wins" \
  'echo "$OUT" | grep -q "overrideteam-reviewer"'
rm -f "$PROJ/.claude/hierarchy/teams/origteam.json" "$PROJ/.claude/hierarchy/teams/overrideteam.json"

# ---- create --from <id> --commit on an entry whose model no longer validates -> non-zero
# exit, why names the field, no team file written
node -e "
const fs = require('fs');
const p = '$HISTORY_FILE';
const h = JSON.parse(fs.readFileSync(p, 'utf8'));
h.teams.find(t => t.id === '$FROM_ID').members[0].model = 'not-a-real-model';
fs.writeFileSync(p, JSON.stringify(h, null, 2));
"
rm -f "$PROJ/.claude/hierarchy/teams/badmodel.json"
run create --from "$FROM_ID" --commit --team badmodel
check "create --from --commit, invalid stored model: non-zero exit" '[ "$RC" -ne 0 ]'
check "create --from --commit, invalid stored model: why names the field" 'echo "$OUT" | grep -qi "model"'
check "create --from --commit, invalid stored model: no team file written" '[ ! -e "$PROJ/.claude/hierarchy/teams/badmodel.json" ]'

# ---- create --from bogus -> non-zero exit listing available ids
run create --from "definitely-not-a-real-id" --plan
check "create --from bogus: non-zero exit" '[ "$RC" -ne 0 ]'
check "create --from bogus: message lists available ids" 'echo "$OUT" | grep -qi "available ids"'

# ---- corrupt team-history.json -> create --commit still exits 0 and rewrites it
echo 'not json{{{' > "$HISTORY_FILE"
commit "$DEAD_PID" "$CONFIG_A"
check "corrupt team-history.json: create --commit still exits 0" '[ "$RC" -eq 0 ]'
check "corrupt team-history.json: rewritten as valid JSON" 'node -e "JSON.parse(require(\"fs\").readFileSync(\"$HISTORY_FILE\",\"utf8\"))"'

# ---- history-write failure must not fail create (spec §4): make team-history.json itself an
# unwritable target (a directory, so writeHistory's atomic rename onto it fails) and assert
# create --commit still exits 0 with history.ok === false
rm -f "$TEAM_FILE"
rm -rf "$HISTORY_FILE"
mkdir -p "$HISTORY_FILE"
commit "$DEAD_PID" "$CONFIG_A"
check "history-write failure: create --commit still exits 0" '[ "$RC" -eq 0 ]'
check "history-write failure: team.json still committed" '[ -e "$TEAM_FILE" ]'
check "history-write failure: history.ok === false in the command output" \
  '[ "$(json_field "o.history.ok")" = "false" ]'
rm -rf "$HISTORY_FILE"

# ---- create --from <id> --spawn at global scope: BLOCKING fix regression — requireAllowGlobal
# must fire from the *entry's own* stored roster_level even though --from never resolves a live
# roster (spec 0015 §7.2 composed with spec 0009's confirm gate; createSpawn previously only
# guarded the non-`--from` branch, so `--from ... --spawn` at global scope launched ungated)
rm -f "$HISTORY_FILE" "$TEAM_FILE"
commit "$DEAD_PID" "[$(member architect opus high peer acceptEdits)]" --roster-level global
run history
GLOBAL_ENTRY_ID=$(json_field "o.teams[0].id")
run create --from "$GLOBAL_ENTRY_ID" --spawn --mode auto
check "create --from --spawn, entry's stored roster_level is global, no --allow-global: exit 2" '[ "$RC" -eq 2 ]'
check "create --from --spawn, global scope: message names allow-global" 'echo "$OUT" | grep -qi "allow-global"'

# ---- fingerprint-casing-equivalence: both auto_mode and autoMode input casings on an
# otherwise-identical member must normalize to the SAME fingerprint (what dedupe depends on)
FP_CASING_RESULT="$(node --input-type=module -e "
import { fingerprint, normalizeMembers } from '$H/lib-roster.mjs';
const base = { role: 'architect', model: 'opus', effort: 'high', route: 'peer' };
const snake = normalizeMembers([{ ...base, auto_mode: 'acceptEdits' }]);
const camel = normalizeMembers([{ ...base, autoMode: 'acceptEdits' }]);
const fp1 = fingerprint({ roster_level: 'repo', transport: 'terminal', members: snake });
const fp2 = fingerprint({ roster_level: 'repo', transport: 'terminal', members: camel });
console.log(fp1 === fp2 && fp1.length === 8 ? 'PASS' : 'FAIL ' + JSON.stringify({ fp1, fp2, snake, camel }));
" 2>&1)"
check "fingerprint: auto_mode vs autoMode input casing produces the same fingerprint" \
  '[ "$FP_CASING_RESULT" = "PASS" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
