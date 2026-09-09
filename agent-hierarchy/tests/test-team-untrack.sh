#!/bin/bash
# agent-hierarchy — spec 0046 §2.3/§8: `untrack` is the sole tracking-only verb. Plan is
# read-only; commit refuses a live or unknown-liveness target without --keep-sessions; a live
# session team.json never recorded has no record to forget and is named as `dismiss`'s job;
# untracking something already gone is idempotent, not an error.
# Usage: bash tests/test-team-untrack.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-untrack-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
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

# $1=key $2=value, matched against the whitespace-stripped JSON so pretty-printing is irrelevant.
has() { echo "$OUT" | tr -d " \n" | grep -q "\"$1\":$2"; }
run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

HIER="$PROJ/.claude/hierarchy"
TEAM_FILE="$HIER/teams/$(basename "$PROJ").json"
PEERS_FILE="$HIER/peers.jsonl"
mkdir -p "$HIER"
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"},{"role":"reviewer","model":"opus"}]}}
EOF
TEAMTAG="$(basename "$PROJ")"

seed_peer() { # <name> <role> <status> <pid> [pane_id] [team] [session_id]
  node -e 'const fs=require("fs");const[f,n,r,st,p,pane,team,sid]=process.argv.slice(1);
    const rec={type:"peer",status:st,name:n||undefined,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()};
    if(pane) rec.pane_id=pane;
    if(team) rec.team=team;
    if(sid) rec.session_id=sid;
    fs.appendFileSync(f,JSON.stringify(rec)+"\n");' "$PEERS_FILE" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-}"
}
fresh() { rm -f "$TEAM_FILE" "$PEERS_FILE"; }
write_team() {
  mkdir -p "$(dirname "$TEAM_FILE")"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "PANE1", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": "myrepo-reviewer", "ref": "r2", "route": "peer", "model": "opus", "transport_id": "PANE2", "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

# ---- U1: plan is read-only and reports liveness, even for a live target
fresh; write_team
seed_peer myrepo-architect architect up $$ PANE1 "$TEAMTAG"
run untrack myrepo-architect
check "U1: plan on a LIVE member succeeds, is read-only, and reports live" \
  '[ "$RC" -eq 0 ] && has plan .untrack. && has live true && [ -f "$TEAM_FILE" ]'

# ---- U2: commit on a LIVE member REFUSES without --keep-sessions, naming both remedies
run untrack myrepo-architect --commit
check "U2: commit on a live member refuses" '[ "$RC" -ne 0 ]'
check "U2b: refusal names dismiss as the close path" 'echo "$OUT" | grep -q "dismiss"'
check "U2c: refusal names --keep-sessions as the other remedy" 'echo "$OUT" | grep -q -- "--keep-sessions"'
check "U2d: refusal says the record cannot be recovered" 'echo "$OUT" | grep -qi "cannot be"'
check "U2e: the refused commit left team.json untouched" 'node -e "const t=require(\"$TEAM_FILE\"); process.exit(t.members.length===2?0:1)"'

# ---- U3: --keep-sessions is the explicit opt-in and removes only that row
run untrack myrepo-architect --commit --keep-sessions
check "U3: --keep-sessions untracks the live member" '[ "$RC" -eq 0 ] && has untracked true'
check "U3b: only that row is gone; the sibling stays" \
  'node -e "const t=require(\"$TEAM_FILE\"); process.exit(t.members.length===1 && t.members[0].name===\"myrepo-reviewer\"?0:1)"'

# ---- U4: idempotent — untracking something already gone is not an error
rm -f "$PEERS_FILE"
run untrack myrepo-architect --commit
check "U4: re-untracking an already-gone member reports already_untracked, RC 0" \
  '[ "$RC" -eq 0 ] && has already_untracked true'

# ---- U5: a DEAD member needs no --keep-sessions
fresh; write_team
run untrack myrepo-reviewer --commit
check "U5: a dead member untracks without --keep-sessions" '[ "$RC" -eq 0 ] && has untracked true'

# ---- U6: a LIVE session team.json never recorded has no record to forget
fresh; write_team
seed_peer "" implementor up $$ PANEX "$TEAMTAG" "sess-untracked-0001"
run untrack PANEX --commit
check "U6: untracking a live UNTRACKED session fails and names dismiss" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "dismiss"'

# ---- U7: --all forgets the whole record and closes nothing
fresh; write_team
seed_peer myrepo-architect architect up $$ PANE1 "$TEAMTAG"
run untrack --all --commit --keep-sessions
check "U7: --all removes the team file" '[ "$RC" -eq 0 ] && [ ! -f "$TEAM_FILE" ]'
check "U7b: --all reports the members it forgot so the user can close them" 'echo "$OUT" | grep -q "myrepo-architect"'
run untrack --all --commit
check "U7c: --all is idempotent once the file is gone" '[ "$RC" -eq 0 ] && has already_untracked true'

# ---- U8: --all with a live member refuses without --keep-sessions
fresh; write_team
seed_peer myrepo-architect architect up $$ PANE1 "$TEAMTAG"
run untrack --all --commit
check "U8: --all refuses while a member is live" '[ "$RC" -ne 0 ] && [ -f "$TEAM_FILE" ]'

# ---- U9: flag hygiene — the removed destructive flags are not silently accepted
run untrack myrepo-architect --close
check "U9: --close is not an untrack flag" '[ "$RC" -ne 0 ]'
run untrack --all --also-config --commit --keep-sessions
check "U9b: --also-config is refused with --all" '[ "$RC" -ne 0 ]'

# ---- U10: the destructive verbs no longer carry the tracking-only flags (spec 0046 §2.1)
fresh; write_team
run dismiss myrepo-architect --commit
check "U10: dismiss --commit is gone" '[ "$RC" -ne 0 ]'
run disband --commit
check "U10b: disband --commit is gone" '[ "$RC" -ne 0 ]'
run disband --keep-sessions
check "U10c: disband --keep-sessions is gone" '[ "$RC" -ne 0 ]'

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
