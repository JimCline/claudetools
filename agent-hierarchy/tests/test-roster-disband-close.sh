#!/bin/bash
# agent-hierarchy — roster.mjs `disband --close` (spec 0016 §4.5): the destructive close step,
# gated by --confirm + --plan-token (bound to a close_token the plan call reports), building argv
# directly (never /bin/sh) for herdr/tmux. Never removes team.json — --commit stays separate.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-disband-close.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-disband-close-test.XXXXXX")"
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
check "--close: team.json left in place (not removed)" '[ -e "$TEAM_FILE" ]'
check "--close: disband --commit still removes it afterward" \
  'run disband --commit; echo "$OUT" | grep -q "\"removed\""; [ ! -e "$TEAM_FILE" ]'

# ---- a close that fails for one member is reported, not fatal; others still close
write_team
run disband
TOKEN2=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
FAKE_HERDR_CLOSE_FAIL_ID="PANE1" run disband --close --confirm --plan-token "$TOKEN2"
check "--close: a per-member close failure is reported, call still succeeds overall" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const failed=o.results.find(r=>r.transport_id===\"PANE1\");const ok=o.results.find(r=>r.transport_id!==\"PANE1\");process.exit(failed&&failed.closed===false&&failed.error&&ok&&ok.closed===true?0:1)})"'
run disband --commit

# ---- --close --commit / --close --keep-sessions: mutually exclusive
write_team
run disband --close --confirm --plan-token x --commit
check "--close --commit: rejected, exit 2" '[ "$RC" -eq 2 ]'
run disband --close --confirm --plan-token x --keep-sessions
check "--close --keep-sessions: rejected, exit 2" '[ "$RC" -eq 2 ]'
run disband --commit

# ---- roster_disband_close's --allow-global guard, matching spawn-one/create --spawn (spec 0016 §4.5)
mkdir -p "$FAKEHOME/.claude"
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
write_team
run disband
TOKEN3=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).close_token))')
run disband --close --confirm --plan-token "$TOKEN3"
check "--close: refused without --allow-global when the roster resolves at global level" \
  '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "allow-global"'
check "--close: team.json untouched by the refused attempt" '[ -e "$TEAM_FILE" ]'
run disband --close --confirm --plan-token "$TOKEN3" --allow-global
check "--close --allow-global: succeeds against the global roster" '[ "$RC" -eq 0 ]'
run disband --commit
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"

# ---- disband's three non-destructive modes never invoke herdr pane close (spec 0016 §4.5) —
# live panes survive plan/keep-sessions/commit
write_team
: > "$INVOKED_LOG"
run disband
check "disband (plan): never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

write_team
: > "$INVOKED_LOG"
run disband --keep-sessions
check "disband --keep-sessions: never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

write_team
: > "$INVOKED_LOG"
run disband --commit
check "disband --commit: never invokes pane close" '! grep -q "\"close\"" "$INVOKED_LOG"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
