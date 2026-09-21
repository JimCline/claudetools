#!/bin/bash
# agent-hierarchy — a session whose cwd is a linked worktree, briefing a teammate of the
# main checkout's Team: the request lands in that Team's pool, names its team file, and
# passes the msg gate from the worktree. HOME-redirected; real state untouched.
# Usage: bash tests/test-msg-worktree-team.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
GATE="$H/pretooluse-msg-gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-wtteam-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
MAIN="$SANDBOX/main"
WT="$SANDBOX/wt"
mkdir -p "$FAKEHOME/.claude" "$MAIN/.claude/hierarchy/teams"
unset AGENT_HIERARCHY_DIR
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400} ERR=${ERR:0:300})"; fi
}

git -C "$MAIN" init -q
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WT" -b wt-branch

cat > "$MAIN/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer" } } }
EOF
TEAM_FILE="$MAIN/.claude/hierarchy/teams/main.json"
cat > "$TEAM_FILE" <<EOF
{ "team_id": "t1", "roster_level": null, "members": [ { "role": "reviewer", "name": "main-reviewer", "transport_id": "P7" } ] }
EOF

msg() { OUT=$(HOME="$FAKEHOME" node "$MSG" "$@" 2>"$SANDBOX/err"); RC=$?; ERR=$(cat "$SANDBOX/err"); }
path_of() { node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT"; }

msg new --cwd "$WT" --to reviewer --from orchestrator --slug wt-task --to-name main-reviewer
REQ=$(path_of)
check "request to a main-checkout teammate, written from the worktree, lands in the Team's pool" \
  'case "$REQ" in "$MAIN/.claude/hierarchy/msgs/"*) true;; *) false;; esac'
check "it names the Team's file" 'grep -qxF "team_file: $TEAM_FILE" "$REQ"'
check "stderr says where it went and why" 'echo "$ERR" | grep -qF "$MAIN/.claude/hierarchy"'

OUT=$(node -e 'const[c,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd:c,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' \
  "$WT" main-reviewer "[hierarchy-peer-brief reply-to=\"sender\" task=\"wt-task\"]
[hierarchy-msg $REQ]" | HOME="$FAKEHOME" node "$GATE" 2>&1); RC=$?
check "msg gate, session cwd in the worktree: the brief passes" '[ $RC -eq 0 ] && [ -z "$OUT" ]'

msg new --cwd "$WT" --to reviewer --from orchestrator --slug local-task --to-name nobody-here
REQ2=$(path_of)
check "a name no Team holds stays in the worktree's own pool" \
  'case "$REQ2" in "$WT/.claude/hierarchy/msgs/"*) true;; *) false;; esac'
check "and names no team file" 'grep -qx "team_file: null" "$REQ2"'

OUT=$(env -u TMUX_PANE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID HOME="$FAKEHOME" HERDR_PANE_ID=P7 node "$H/roster.mjs" whoami --cwd "$WT" 2>&1); RC=$?
check "whoami from the worktree finds the member in the main checkout's Team and reports that file" \
  'node -e "const o=JSON.parse(process.argv[1]);process.exit(o.member&&o.member.name===\"main-reviewer\"&&o.team_file===process.argv[2]?0:1)" "$OUT" "$TEAM_FILE"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
