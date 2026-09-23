#!/bin/bash
# agent-hierarchy — roster.mjs `disband --close` (spec 0016 §4.5): the destructive close step,
# gated by --confirm + --plan-token (bound to a close_token the plan call reports), building argv
# directly (never /bin/sh) for herdr/tmux, then reconciling team.json against what closed.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-disband-close.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-disband-close-test.XXXXXX")"
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

# stdin: one JSON object, bound to `o`; $1: a JS expression over it. Exit 0 iff truthy.
jsq() { TEAM_FILE="$TEAM_FILE" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{process.exit(1)}process.exit(eval(process.argv[1])?0:1)})' "$1"; }

# ---- fake herdr: `agent list` from $FAKE_HERDR_STATE; `pane close <id>` logs and succeeds unless
# $FAKE_HERDR_CLOSE_FAIL_ID matches, in which case it exits 1. Every invocation is logged verbatim
# (no shell re-interpretation) to $FAKE_HERDR_INVOKED_LOG, so a metacharacter-laden transport_id
# proves it never went through /bin/sh.
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
  if (process.env.FAKE_HERDR_CLOSE_FAIL_ID && args[2] === process.env.FAKE_HERDR_CLOSE_FAIL_ID) {
    process.stderr.write("fake herdr: forced close failure\n");
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

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_INVOKED_LOG="$INVOKED_LOG" FAKE_HERDR_CLOSE_FAIL_ID="${FAKE_HERDR_CLOSE_FAIL_ID:-}" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

write_team() {
  mkdir -p "$(dirname "$TEAM_FILE")"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "PANE1", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": "PANE;rm -rf /tmp/pwned", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": null, "ref": "r3", "route": "subagent", "model": "opus", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

# ---- plan mode gains close_token
write_team
: > "$INVOKED_LOG"
run disband
TOKEN=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
check "disband (plan): emits a non-empty close_token" '[ -n "$TOKEN" ]'

# ---- --close without --confirm: exit 2, close list echoed
run disband --close --plan-token "$TOKEN"
check "--close without --confirm: exit 2" '[ "$RC" -eq 2 ]'
check "--close without --confirm: close list (member names) present in the error payload" \
  'echo "$OUT" | grep -q "myrepo-architect" && echo "$OUT" | grep -q "myrepo-implementor"'
check "--close without --confirm: team.json untouched" '[ -e "$TEAM_FILE" ]'

# ---- --close without --plan-token: exit 2
run disband --close --confirm
check "--close without --plan-token: exit 2" '[ "$RC" -eq 2 ]'

# ---- --close with a stale/wrong token: refused, told to re-run the plan
run disband --close --confirm --plan-token "wrong-token-value"
check "--close with a stale token: exit 2, message says to re-run the plan" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "re-run"'
check "--close with a stale token: team.json untouched, herdr pane close never invoked" \
  '[ -e "$TEAM_FILE" ] && ! grep -q "\"close\"" "$INVOKED_LOG"'

# ---- --close builds argv directly: a transport_id with shell metacharacters is never
# interpreted by a shell (fake herdr just logs its argv verbatim; no side-effect file appears)
: > "$INVOKED_LOG"
run disband --close --confirm --plan-token "$TOKEN"
check "--close: exit 0, both peer members closed" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);process.exit(o.results.length===2&&o.results.every(r=>r.closed===true)?0:1)})"'
check "--close: the metacharacter-laden transport_id reached herdr as one argv element, not shell-expanded" \
  'grep -qF "PANE;rm -rf /tmp/pwned" "$INVOKED_LOG" && [ ! -e "/tmp/pwned" ]'
check "--close: every row closed or sessionless -> team.json removed" '[ ! -e "$TEAM_FILE" ]'
check "--close: reports team_removed, the pruned rows (null name shown as its role) and nothing kept" \
  'echo "$OUT" | jsq "o.team_removed===true&&o.team_file===process.env.TEAM_FILE&&o.kept.length===0&&JSON.stringify(o.pruned)===JSON.stringify([\"myrepo-architect\",\"myrepo-implementor\",\"reviewer\"])"'
check "--close: untrack --all --commit --keep-sessions still removes it afterward" \
  'run untrack --all --commit --keep-sessions; echo "$OUT" | grep -q "\"removed\""; [ ! -e "$TEAM_FILE" ]'

# ---- a close that fails for one member is reported, not fatal; others still close
write_team
run disband
TOKEN2=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
FAKE_HERDR_CLOSE_FAIL_ID="PANE1" run disband --close --confirm --plan-token "$TOKEN2"
check "--close: a per-member close failure is reported, call still succeeds overall" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const failed=o.results.find(r=>r.transport_id===\"PANE1\");const ok=o.results.find(r=>r.transport_id!==\"PANE1\");process.exit(failed&&failed.closed===false&&failed.error&&ok&&ok.closed===true?0:1)})"'
check "--close: the failed close is the one row kept, with its reason; the file is not removed" \
  'echo "$OUT" | jsq "o.team_removed===false&&o.kept.length===1&&o.kept[0].name===\"myrepo-architect\"&&o.kept[0].why===\"close-failed\"&&o.pruned.length===2" &&
   jsq "o.team_id===\"t1\"&&o.transport===\"herdr\"&&o.members.length===1&&o.members[0].name===\"myrepo-architect\"&&o.members[0].transport_id===\"PANE1\"" < "$TEAM_FILE"'
run untrack --all --commit --keep-sessions

# ---- --close --commit / --close --keep-sessions: mutually exclusive
write_team
run disband --close --confirm --plan-token x --commit
check "--close --commit: rejected, exit 2" '[ "$RC" -eq 2 ]'
run disband --close --confirm --plan-token x --keep-sessions
check "--close --keep-sessions: rejected, exit 2" '[ "$RC" -eq 2 ]'
run untrack --all --commit --keep-sessions

# ---- team_disband mode:close against a global roster needs no --allow-global
mkdir -p "$FAKEHOME/.claude"
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
write_team
run disband
TOKEN3=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
run disband --close --confirm --plan-token "$TOKEN3"
check "--close: succeeds against the global roster without --allow-global" '[ "$RC" -eq 0 ]'
run untrack --all --commit --keep-sessions
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"

# ---- disband's three non-destructive modes never invoke herdr pane close (spec 0016 §4.5) —
# live panes survive plan/keep-sessions/commit
write_team
: > "$INVOKED_LOG"
run disband
check "disband (plan): never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

write_team
: > "$INVOKED_LOG"
run untrack --all --commit --keep-sessions
check "untrack --all --commit --keep-sessions: never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

write_team
: > "$INVOKED_LOG"
run untrack --all --commit --keep-sessions
check "untrack --all --commit --keep-sessions: never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

# ---- the plan hands back the whole close command; the token is still a hash of team_id plus the
# sorted closable pane ids and nothing else
write_team
run disband
NEXT=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).next||""))')
PLAN_TOKEN=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
WANT_TOKEN=$(node -e 'console.log(require("crypto").createHash("sha256").update(JSON.stringify({team_id:"t1",ids:["PANE1","PANE;rm -rf /tmp/pwned"]})).digest("hex").slice(0,16))')
check "disband (plan): close_token is the hash of team_id + sorted closable pane ids only" '[ "$PLAN_TOKEN" = "$WANT_TOKEN" ]'
check "disband (plan): next is an absolute-path close command carrying the token and --cwd, no --allow-global" \
  'case "$NEXT" in "node $H/roster.mjs disband --close --confirm --plan-token $PLAN_TOKEN --cwd $PROJ") true;; *) false;; esac'
: > "$INVOKED_LOG"
OUT=$(eval "HOME=\"\$FAKEHOME\" PATH=\"\$SANDBOX/bin:\$NODE_DIR\" FAKE_HERDR_STATE=\"\$SANDBOX/agents.json\" FAKE_HERDR_INVOKED_LOG=\"\$INVOKED_LOG\" $NEXT" 2>&1); RC=$?
check "disband (plan): next runs verbatim -> exit 0, both panes closed, team.json removed" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.closed===true&&o.results.length===2&&o.team_removed===true" && [ ! -e "$TEAM_FILE" ]'

mkdir -p "$FAKEHOME/.claude"
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
write_team
run disband
check "disband (plan): next carries no --allow-global even when the roster resolves at global level" \
  'echo "$OUT" | jsq "typeof o.next === \"string\" && !/allow-global/.test(o.next)"'
rm -f "$FAKEHOME/.claude/agent-hierarchy.json" "$TEAM_FILE"

# ---- a row with no pane to close survives only while its session is provably or possibly there
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<'EOF'
{
  "version": 1, "team_id": "t2", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "transport_id": "PANE1"},
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "transport_id": null},
    {"role": "reviewer", "name": "myrepo-reviewer", "route": "peer", "transport_id": null}
  ],
  "partial": false
}
EOF
node -e 'const fs=require("fs");const[f,p]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",name:"myrepo-implementor",role:"implementor",pid:Number(p),ts:new Date().toISOString()})+"\n");' \
  "$PROJ/.claude/hierarchy/peers.jsonl" "$$"
run disband
TOKEN4=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
run disband --close --confirm --plan-token "$TOKEN4"
check "--close: paneless live member kept as live, paneless dead member pruned, closed member pruned" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.team_removed===false&&o.kept.length===1&&o.kept[0].name===\"myrepo-implementor\"&&o.kept[0].why===\"live\"&&JSON.stringify(o.pruned)===JSON.stringify([\"myrepo-architect\",\"myrepo-reviewer\"])" &&
   jsq "o.team_id===\"t2\"&&o.members.length===1&&o.members[0].name===\"myrepo-implementor\"" < "$TEAM_FILE"'
rm -f "$PROJ/.claude/hierarchy/peers.jsonl" "$TEAM_FILE"

# ---- untrack / dismiss run straight after a close that removed the team file
write_team
run disband
TOKEN5=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
run disband --close --confirm --plan-token "$TOKEN5"
check "--close removed the team file (precondition for the no-file cases)" '[ "$RC" -eq 0 ] && [ ! -e "$TEAM_FILE" ]'
run untrack myrepo-architect
check "untrack with the team file gone: exit 0, already_untracked, nothing to forget" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.untracked===false&&o.already_untracked===true&&o.reason===\"no team file to forget\""'
run dismiss myrepo-architect
check "dismiss with the team file gone and no closable peer: exit 0, dismissed false" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.dismissed===false&&o.reason===\"no active team and no live peers\"&&\"sources\" in o"'
node -e 'const fs=require("fs");const[f,p]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",name:"myrepo-reviewer-9",role:"reviewer",pid:Number(p),pane_id:"pLIVE",session_id:"s-live-9",ts:new Date().toISOString()})+"\n");' \
  "$PROJ/.claude/hierarchy/peers.jsonl" "$$"
run dismiss myrepo-architect
check "dismiss with the team file gone and a live untracked peer: exit 2, lists the session and the accepted identifiers" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "live untracked sessions" && echo "$OUT" | grep -q "myrepo-reviewer-9" && echo "$OUT" | grep -q "pLIVE" && echo "$OUT" | grep -q "name / pane_id / session_id"'
check "no-file untrack/dismiss created no team file" '[ ! -e "$TEAM_FILE" ]'
rm -f "$PROJ/.claude/hierarchy/peers.jsonl"

# ---- a team file that exists but cannot be parsed is reported, and never written or removed
BAD_FILE="$PROJ/.claude/hierarchy/teams/myrepo.json"
mkdir -p "$(dirname "$BAD_FILE")"
printf 'not json {{{' > "$BAD_FILE"
GARBAGE_SUM=$(cksum < "$BAD_FILE")
run disband
check "disband (plan): unparseable team file -> team_file_unreadable names it" \
  'echo "$OUT" | TEAM_FILE="$BAD_FILE" jsq "o.team_file_unreadable===process.env.TEAM_FILE"'
run disband --close --confirm --plan-token x
check "--close: unparseable team file -> team_file_unreadable names it" \
  'echo "$OUT" | TEAM_FILE="$BAD_FILE" jsq "o.team_file_unreadable===process.env.TEAM_FILE"'
check "unparseable team file: bytes unchanged after plan and close" '[ "$(cksum < "$BAD_FILE")" = "$GARBAGE_SUM" ]'
rm -f "$BAD_FILE"
run disband
check "disband (plan): a merely absent team file is not reported unreadable" 'echo "$OUT" | jsq "!(\"team_file_unreadable\" in o)"'

# ---- valid JSON that holds no members array is no team record: reported, never thrown on, never rewritten
mkdir -p "$(dirname "$TEAM_FILE")"
printf '{"version":1,"team_id":"t-trunc","orchestrator":{"session_id":null,"pid":null}}' > "$TEAM_FILE"
TRUNC_SUM=$(cksum < "$TEAM_FILE")
no_stack() { ! echo "$OUT" | grep -qE "TypeError|^ +at "; }
run disband --close --confirm --plan-token x
check "members-less team file, disband --close -> team_file_unreadable names it, no stack" \
  'echo "$OUT" | jsq "o.team_file_unreadable===process.env.TEAM_FILE" && no_stack'
run dismiss myrepo-architect
check "members-less team file, dismiss -> the no-team answer, exit 0, no stack" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.dismissed===false&&o.reason===\"no active team and no live peers\"" && no_stack'
run untrack myrepo-architect
check "members-less team file, untrack -> the no-team answer, exit 0, no stack" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | jsq "o.untracked===false&&o.already_untracked===true" && no_stack'
run adopt --orchestrator-pid "$$"
check "members-less team file, adopt -> exit 2 naming the file and the remedy, not the absent-file message, no stack" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qF "$TEAM_FILE" && echo "$OUT" | grep -qi "repair or remove" && ! echo "$OUT" | grep -q "no team file at this scope" && no_stack'
check "members-less team file: bytes unchanged by close, dismiss, untrack and adopt" '[ "$(cksum < "$TEAM_FILE")" = "$TRUNC_SUM" ]'
rm -f "$TEAM_FILE"
run adopt --orchestrator-pid "$$"
check "absent team file, adopt -> the plain no-team-file message, and none is created" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "adopt: no team file at this scope to adopt" && [ ! -e "$TEAM_FILE" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
