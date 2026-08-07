#!/bin/bash
# agent-hierarchy /pane — the parts that must hold with no live Claude session.
#
# Two properties carry most of the weight here and both are asserted on the
# emitted OUTPUT, not only on exit codes: the pane cannot initiate (no pending
# token, no reply), and nothing that reaches a shell escapes its whitelist.
# Usage: bash tests/test-pane.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; tmux kill-session -t ah-panetest-1 2>/dev/null; tmux kill-session -t ah-panetest-2 2>/dev/null' EXIT

# A private HOME, so no test can see or touch the real registry, mailboxes, or
# config. node's os.homedir() reads $HOME on POSIX, which is what lib-pane uses.
export HOME="$WORK/home"
mkdir -p "$HOME/.claude/plugins"
cat > "$HOME/.claude/agent-hierarchy.json" <<JSON
{ "version": 1, "enabled": true,
  "roles": {
    "ultra-advisor": { "model": "fable" },
    "architect":     { "model": "opus" },
    "reviewer":      { "model": "opus" },
    "implementor":   { "model": "inherit" },
    "task-runner":   { "model": "haiku", "delegate": "task-gopher" }
  } }
JSON
# Resolve plugin agents out of this checkout, never out of the installed cache,
# so the assertions do not drift with whatever version happens to be installed.
cat > "$HOME/.claude/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": { "agent-hierarchy@claudetools": [
  { "scope": "user", "installPath": "$PLUGIN", "version": "9.9.9", "lastUpdated": "2026-01-01T00:00:00Z" } ] } }
JSON

pane() { node "$H/pane.mjs" "$@" 2>"$WORK/err" ; }
relay() { echo "$1" | node "$H/stop-pane-relay.mjs" ; }

mailbox() { # -> a fresh mailbox dir
  local d; d="$(mktemp -d "$WORK/mbox.XXXXXX")"; echo "$d"
}

# ================================================= Stop relay (§9.4)

# ---- 1: unsolicited turn. No pending token, so nothing is relayed. This is
#         the test that proves the pane cannot initiate.
D="$(mailbox)"
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s1","agent_type":"agent-hierarchy:architect","last_assistant_message":"unsolicited"}'; RC=$?
check "relay: unsolicited turn exits 0" '[ "$RC" -eq 0 ]'
check "relay: unsolicited turn writes no reply" '! ls "'$D'"/reply.*.json >/dev/null 2>&1'
check "relay: unsolicited turn logs ev=silent" 'grep -q "\"ev\":\"silent\"" "'$D'/log.jsonl"'

# ---- 2: solicited turn relays the final message and consumes the token.
D="$(mailbox)"
echo '{"reqid":"r-abc","sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s2","agent_type":"agent-hierarchy:architect","last_assistant_message":"PANE OK 2"}'
check "relay: solicited turn writes reply.<reqid>.json" '[ -f "'$D'/reply.r-abc.json" ]'
check "relay: reply text is exactly the final message" \
  '[ "$(node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"'$D'/reply.r-abc.json\",\"utf8\")).text)")" = "PANE OK 2" ]'
check "relay: pending token is consumed" '[ ! -f "'$D'/pending" ]'
check "relay: logs ev=replied" 'grep -q "\"ev\":\"replied\"" "'$D'/log.jsonl"'
check "relay: records permission_mode for diagnostics" 'grep -q "permission_mode" "'$D'/reply.r-abc.json"'

# ---- 3: not a pane at all. No env, no work, and stdin is never touched.
D="$(mailbox)"
env -u AGENT_HIERARCHY_PANE_DIR -u AGENT_HIERARCHY_PANE_ROLE -u AGENT_HIERARCHY_PANE_KEY \
  bash -c 'echo "{\"session_id\":\"s3\",\"last_assistant_message\":\"x\"}" | node "'$H'/stop-pane-relay.mjs"' > "$WORK/out3" 2>&1; RC=$?
check "relay: non-pane session exits 0" '[ "$RC" -eq 0 ]'
check "relay: non-pane session prints nothing" '[ ! -s "$WORK/out3" ]'
check "relay: non-pane session creates no files" '[ -z "$(ls -A "'$D'")" ]'
GATE_LINE=$(grep -n 'AGENT_HIERARCHY_PANE_DIR' "$H/stop-pane-relay.mjs" | head -1 | cut -d: -f1)
STDIN_LINE=$(grep -n 'process.stdin' "$H/stop-pane-relay.mjs" | head -1 | cut -d: -f1)
check "relay: the env gate precedes any stdin read in the source" '[ "$GATE_LINE" -lt "$STDIN_LINE" ]'

# ---- 4: the transcript is never read. Reading it at Stop time is racy.
check "relay: never reads transcript_path" \
  '! grep -nE "(readFileSync|createReadStream)[^\n]*transcript" "$H/stop-pane-relay.mjs"'
check "relay: no createReadStream at all" '! grep -q "createReadStream" "$H/stop-pane-relay.mjs"'

# ---- 5: the grandchild hazard. A child `claude` inherits the pane env vars.
for BAD in '{"session_id":"g1","last_assistant_message":"hijack"}' \
           '{"session_id":"g1","agent_type":"some-other:agent","last_assistant_message":"hijack"}'; do
  D="$(mailbox)"
  echo '{"reqid":"r-keep","sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
  AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:implementor" relay "$BAD"
  check "relay: foreign agent_type writes no reply" '! ls "'$D'"/reply.*.json >/dev/null 2>&1'
  check "relay: foreign agent_type does NOT consume pending" '[ -f "'$D'/pending" ]'
  check "relay: foreign agent_type logs reason=agent_type" 'grep -q "\"reason\":\"agent_type\"" "'$D'/log.jsonl"'
done

# ---- 6: session mismatch, belt-and-braces on gate B.
D="$(mailbox)"
echo '{"reqid":"r-sess","sent_at":"2026-01-01T00:00:00Z","expect_session":"AAA"}' > "$D/pending"
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"BBB","agent_type":"agent-hierarchy:architect","last_assistant_message":"wrong session"}'
check "relay: session mismatch writes no reply" '! ls "'$D'"/reply.*.json >/dev/null 2>&1'
check "relay: session mismatch does NOT consume pending" '[ -f "'$D'/pending" ]'
check "relay: session mismatch logs reason=session_id" 'grep -q "\"reason\":\"session_id\"" "'$D'/log.jsonl"'

# ================================================= sessionstart pane branch (§8)

start() { echo "$2" | env AGENT_HIERARCHY_PANE_DIR="$1" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  AGENT_HIERARCHY_PANE_KEY="ah-test-architect-1" node "$H/sessionstart.mjs" 2>/dev/null ; }

# ---- 7: pane protocol is injected with and without agent_type, and the pane
#         records its session identity for §9.4's gate D.
D="$(mailbox)"
P1="$(start "$D" '{"session_id":"p1","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"startup"}')"
check "sessionstart pane: emits the pane protocol" 'echo "$P1" | grep -q "agent-hierarchy PANE"'
check "sessionstart pane: says NOT the Orchestrator" 'echo "$P1" | grep -q "You are NOT the Orchestrator"'
check "sessionstart pane: never says You are the Orchestrator" '! echo "$P1" | grep -q "You are the Orchestrator\\."'
check "sessionstart pane: states the one-channel rule" 'echo "$P1" | grep -q "inbound only"'
check "sessionstart pane: states artifacts go to disk by path" 'echo "$P1" | grep -q "ABSOLUTE PATH"'
check "sessionstart pane: forbids nesting panes" 'echo "$P1" | grep -q "Do not open panes"'
check "sessionstart pane: records <dir>/session with the session_id" 'grep -q "\"session_id\":\"p1\"" "'$D'/session"'

D2="$(mailbox)"
P2="$(start "$D2" '{"session_id":"p2","cwd":"'$WORK'","source":"startup"}')"
check "sessionstart pane: protocol emitted even with no agent_type" 'echo "$P2" | grep -q "agent-hierarchy PANE"'

D3="$(mailbox)"
echo '{"session_id":"first","agent_type":"agent-hierarchy:architect","at":"x"}' > "$D3/session"
start "$D3" '{"session_id":"second","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect"}' >/dev/null
check "sessionstart pane: session file is first-writer-wins" 'grep -q "\"session_id\":\"first\"" "'$D3'/session"'

# ---- 8: the pane branch wins over the subagent branch.
D="$(mailbox)"
P3="$(start "$D" '{"session_id":"p3","cwd":"'$WORK'","agent_id":"sub-1","agent_type":"agent-hierarchy:architect"}')"
check "sessionstart pane: pane branch beats the subagent branch" 'echo "$P3" | grep -q "agent-hierarchy PANE"'

# ---- 9: a broken mailbox must not cost the session its protocol.
P4="$(start "$WORK/no/such/dir/anywhere" '{"session_id":"p4","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect"}')"
check "sessionstart pane: survives a non-existent mailbox dir" 'echo "$P4" | grep -q "agent-hierarchy PANE"'

# ---- role mismatch is surfaced, not swallowed.
D="$(mailbox)"
P5="$(echo '{"session_id":"p5","cwd":"'$WORK'","agent_type":"agent-hierarchy:implementor"}' | \
  env AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" node "$H/sessionstart.mjs" 2>/dev/null)"
check "sessionstart pane: role mismatch is reported" 'echo "$P5" | grep -q "this pane was opened for"'

# ================================================= registry (§13.1)

REG="$HOME/.claude/agent-hierarchy.panes.jsonl"
mkdir -p "$HOME/.claude"
cat > "$REG" <<'JSON'
{"ev":"open","key":"ah-aaa-architect-1","agent":"a","pane_id":"%1"}
{"ev":"open","key":"ah-bbb-reviewer-1","agent":"b","pane_id":"%2"}
{"ev":"close","key":"ah-aaa-architect-1","reason":"user"}
{"ev":"open","key":"ah-ccc-implementor-1","agent":"c","pane_id":"%3"}
{"ev":"open","key":"ah-aaa-architect-1","agent":"a","pane_id":"%9"}
JSON
FOLD="$(node --input-type=module -e "
  import { foldRegistry } from '$H/lib-pane.mjs';
  process.stdout.write([...foldRegistry('$REG').keys()].sort().join(','));
")"
check "registry: fold takes the most recent event per key" \
  '[ "$FOLD" = "ah-aaa-architect-1,ah-bbb-reviewer-1,ah-ccc-implementor-1" ]'
check "registry: a reopened key keeps its newest record" \
  '[ "$(node --input-type=module -e "import { foldRegistry } from \"$H/lib-pane.mjs\"; process.stdout.write(foldRegistry(\"$REG\").get(\"ah-aaa-architect-1\").pane_id)")" = "%9" ]'
# `list` prunes by APPENDING a close event, never by rewriting the file.
BEFORE=$(wc -l < "$REG")
pane list >/dev/null
check "registry: list prunes dead keys by appending, never rewriting" '[ "$(wc -l < "'$REG'")" -gt "'$BEFORE'" ]'
check "registry: list reports nothing live once tmux disagrees" '[ "$(pane list)" = "no live panes." ]'
rm -f "$REG"

# ================================================= open policy (§7, §10.2, §14.1)

dry() { pane open --agent "$1" ${2:+--orient "$2"} "${@:3}" --dry-run --cwd "$WORK" ; }

# ---- 11/12/13: orientation. THE LETTER NAMES THE DIVIDER.
V="$(dry agent-hierarchy:architect v)"
check "orientation: v records \"right\"" 'echo "$V" | grep -q "\"orientation\": \"right\""'
check "orientation: v is an iTerm2 VERTICAL split (side by side)" 'echo "$V" | grep -q "split vertically"'
check "orientation: v confirms in words" 'echo "$V" | grep -q "opened to the right"'
Hh="$(dry agent-hierarchy:architect h)"
check "orientation: h records \"below\"" 'echo "$Hh" | grep -q "\"orientation\": \"below\""'
check "orientation: h is an iTerm2 HORIZONTAL split (stacked)" 'echo "$Hh" | grep -q "split horizontally"'
check "orientation: h confirms in words" 'echo "$Hh" | grep -q "opened below"'
check "orientation: aliases right/below agree with the letters" \
  '[ "$(dry agent-hierarchy:architect right | grep -c "\"orientation\": \"right\"")" = 1 ] && [ "$(dry agent-hierarchy:architect below | grep -c "\"orientation\": \"below\"")" = 1 ]'
# The registry never carries a flag or a bare letter.
check "orientation: registry record leaks no flag and no letter" \
  '! echo "$V" | grep -E "\"orientation\": \"(-?[hv])\""'
check "orientation: no tmux -h/-v ever reaches the registry" \
  '! echo "$Hh" | grep -E "\"orientation\": \"-"'

# ---- 14: `inherit` must never reach argv. The Implementor is configured
#          `inherit` in this test's config.
INH="$(dry agent-hierarchy:implementor v --permission-mode manual)"
check "model: inherit omits --model entirely" '! echo "$INH" | grep "^launch command" | grep -q -- "--model"'
check "model: the literal string inherit never reaches the launch command" \
  '! echo "$INH" | grep "^launch command" | grep -q "inherit"'
check "model: inherit drift is surfaced to the user" 'echo "$INH" | grep -q "inherited"'
check "model: a configured role model IS passed" 'dry agent-hierarchy:architect v | grep "^launch command" | grep -q -- "--model opus"'

# ---- 15: haiku is never valid for a reasoning role.
# `check` clobbers $? before it evals, so every exit code is captured first.
node "$H/pane.mjs" open --agent agent-hierarchy:architect --model haiku --dry-run --cwd "$WORK" >/dev/null 2>"$WORK/e15"; RC=$?
check "model: haiku for a reasoning role is refused with exit 2" '[ "$RC" -eq 2 ]'
check "model: the haiku refusal names the role" 'grep -q "architect resolves to haiku" "$WORK/e15"'

# ---- 16-18: permission mode. Ask when the agent can execute; don't when it can't.
for R in architect reviewer ultra-advisor task-runner; do
  check "perms: $R is not asked and gets no --permission-mode" \
    '! dry "agent-hierarchy:'$R'" v | grep "^launch command" | grep -q -- "--permission-mode" && dry "agent-hierarchy:'$R'" v | grep -q "permission prompt required: no"'
done
check "perms: the Implementor requires a user decision" \
  'dry agent-hierarchy:implementor v | grep -q "permission prompt required: yes"'
pane open --agent agent-hierarchy:implementor --dry-run --cwd "$WORK" | grep -q "permission prompt required: yes"
check "perms: an executing agent without a mode is a hard stop outside --dry-run" \
  'pane open --agent agent-hierarchy:implementor --cwd "$WORK" >/dev/null 2>&1; [ $? -eq 1 ]'
check "perms: an explicit mode reaches the launch command" \
  'dry agent-hierarchy:implementor v --permission-mode acceptEdits | grep "^launch command" | grep -q -- "--permission-mode acceptEdits"'
check "perms: acceptEdits carries its Bash caveat" \
  'dry agent-hierarchy:implementor v --permission-mode acceptEdits | grep -q "does not cover general Bash"'
check "perms: dontAsk is described as auto-DENY, not as a fix for stalling" \
  'dry agent-hierarchy:implementor v --permission-mode dontAsk | grep -q "auto-DENIES"'

# ---- panes.permissionMode is the blanket override, and the ONLY route to
#      bypassPermissions. It applies to every pane, reasoning roles included.
CFG="$HOME/.claude/agent-hierarchy.json"
cp "$CFG" "$WORK/cfg.bak"
node -e "
  const fs=require('fs'); const c=JSON.parse(fs.readFileSync('$CFG','utf8'));
  c.panes={ permissionMode:'auto', timeoutSeconds:9, nonsenseKey:1 };
  fs.writeFileSync('$CFG', JSON.stringify(c));
"
check "config: panes.permissionMode reaches the launch command" \
  'dry agent-hierarchy:architect v | grep "^launch command" | grep -q -- "--permission-mode auto"'
check "config: panes.permissionMode satisfies the user-decision requirement" \
  'dry agent-hierarchy:implementor v | grep -q "permission prompt required: no"'
check "config: panes.permissionMode is reported as the source" \
  'dry agent-hierarchy:implementor v | grep -q "source: panes.permissionMode"'
check "config: an unknown panes key warns rather than failing" \
  'dry agent-hierarchy:architect v | grep -q "unknown key .panes.nonsenseKey"'
check "config: --permission-mode on argv still beats the config" \
  'dry agent-hierarchy:implementor v --permission-mode acceptEdits | grep "^launch command" | grep -q -- "--permission-mode acceptEdits"'
node -e "
  const fs=require('fs'); const c=JSON.parse(fs.readFileSync('$CFG','utf8'));
  c.panes={ permissionMode:'bypassPermissions' }; fs.writeFileSync('$CFG', JSON.stringify(c));
"
check "config: bypassPermissions IS permitted from a config file" \
  'dry agent-hierarchy:implementor v | grep "^launch command" | grep -q -- "--permission-mode bypassPermissions"'
node -e "
  const fs=require('fs'); const c=JSON.parse(fs.readFileSync('$CFG','utf8'));
  c.panes={ permissionMode:'nonsense' }; fs.writeFileSync('$CFG', JSON.stringify(c));
"
check "config: a bogus panes.permissionMode is ignored with a warning" \
  'dry agent-hierarchy:architect v | grep -q "ignoring panes.permissionMode"'
check "config: a bogus panes.permissionMode never reaches the launch command" \
  '! dry agent-hierarchy:architect v | grep "^launch command" | grep -q "nonsense"'
cp "$WORK/cfg.bak" "$CFG"
check "config: a config with NO panes block is still valid" \
  'dry agent-hierarchy:architect v | grep -q "\"orientation\": \"right\""'

# ---- 19/21: refusals must land BEFORE tmux is ever executed.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<SH
#!/bin/sh
echo invoked >> "$WORK/tmux-was-run"
exit 0
SH
chmod +x "$WORK/bin/tmux"
rm -f "$WORK/tmux-was-run"
shielded() { PATH="$WORK/bin:$PATH" node "$H/pane.mjs" "$@" --cwd "$WORK" >/dev/null 2>"$WORK/err" ; echo $? ; }

check "refuse: bypassPermissions from argv exits 2" \
  '[ "$(shielded open --agent agent-hierarchy:implementor --permission-mode bypassPermissions)" = 2 ]'
check "refuse: bypassPermissions names the config-only path" 'grep -q "panes.permissionMode" "$WORK/err"'
check "refuse: an unknown permission mode exits 2" \
  '[ "$(shielded open --agent agent-hierarchy:implementor --permission-mode wideOpen)" = 2 ]'
check "refuse: a shell metacharacter in --agent exits 2" \
  '[ "$(shielded open --agent "a;rm -rf /")" = 2 ]'
check "refuse: command substitution in --agent exits 2" \
  '[ "$(shielded open --agent "\$(id)")" = 2 ]'
check "refuse: a backtick in --agent exits 2" \
  '[ "$(shielded open --agent "a\`id\`")" = 2 ]'
check "refuse: a shell metacharacter in --model exits 2" \
  '[ "$(shielded open --agent agent-hierarchy:architect --model "foo;id")" = 2 ]'
check "refuse: a shell metacharacter in --permission-mode exits 2" \
  '[ "$(shielded open --agent agent-hierarchy:implementor --permission-mode "auto;id")" = 2 ]'
check "refuse: NONE of those refusals executed tmux" '[ ! -f "$WORK/tmux-was-run" ]'

# ---- 20: built-ins are refused by policy, and the message names the agent.
check "refuse: a built-in exits 2" '[ "$(shielded open --agent Explore)" = 2 ]'
check "refuse: the built-in message names Explore" 'grep -q "^Explore is a Claude Code built-in" "$WORK/err"'
check "refuse: the built-in message points at the Agent tool" 'grep -q "Use the Agent tool for built-ins" "$WORK/err"'
check "refuse: an unknown plugin agent lists what does exist" \
  'shielded open --agent agent-hierarchy:reviewers >/dev/null; grep -q "it defines: architect" "$WORK/err"'

# ================================================= §13.4 — no pane discovery

check "no discovery: nothing runs \`tmux ls\` or list-sessions" \
  '! grep -nE "\"(ls|list-sessions)\"|tmux (ls|list-sessions)" "$H"/*.mjs'
check "no discovery: every list-panes passes an explicit -t" \
  '[ "$(grep -c "list-panes" "$H"/*.mjs | cut -d: -f2 | paste -sd+ - | bc)" = "$(grep "list-panes" "$H"/*.mjs | grep -c -- "\"-t\"")" ]'
SENDKEYS=$(grep -c '"send-keys"' "$H"/*.mjs | cut -d: -f2 | paste -sd+ - | bc)
SENDKEYS_ENTER=$(grep '"send-keys"' "$H"/*.mjs | grep -c '"Enter"')
check "no discovery: at least one send-keys call site exists to check" '[ "$SENDKEYS" -ge 1 ]'
check "no discovery: every send-keys call sends only the Enter key" '[ "$SENDKEYS" = "$SENDKEYS_ENTER" ]'
check "no discovery: kills are never derived from ps or pgrep" \
  '! grep -nE "\"(pgrep|pkill)\"|spawnSync\(\"ps\"" "$H"/*.mjs'

# ================================================= live tmux: self-send and kill safety

if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t ah-panetest-1 2>/dev/null
  INFO="$(tmux new-session -d -s ah-panetest-1 -x 200 -y 50 -c "$WORK" -P -F '#{pane_id} #{pane_pid}' 'sleep 300')"
  T_PANE="${INFO%% *}"; T_PID="${INFO##* }"

  reg() { # write a one-line registry pointing at the live test session
    cat > "$REG" <<JSON
{"ev":"open","key":"ah-panetest-1","agent":"agent-hierarchy:architect","pane_id":"$T_PANE","pane_pid":$1,"tmux_session":"ah-panetest-1","cwd":"$WORK","dir":"$WORK/mbox-live","orientation":"right","orchestrator_session_id":"testorch","model":null,"permission_mode":null}
JSON
  }

  # ---- 22: hard-refuse sending to the Orchestrator's own pane.
  # $TMUX must be WELL-FORMED (socket,pid,session): tmux parses it and a
  # garbage value makes every tmux client call fail with "error connecting",
  # which would make this pass for the wrong reason.
  T_SOCK="$(tmux display-message -p '#{socket_path}')"
  T_SPID="$(tmux display-message -p '#{pid}')"
  reg "$T_PID"
  echo hi | TMUX="$T_SOCK,$T_SPID,0" TMUX_PANE="$T_PANE" node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 >/dev/null 2>"$WORK/e22"; RC=$?
  check "self-send: refuses when the target is this session's own pane" '[ "$RC" -eq 2 ]'
  check "self-send: the refusal names the pane id" 'grep -q "'"$T_PANE"'" "$WORK/e22"'
  check "self-send: nothing was delivered to the pane" '[ ! -f "$WORK/mbox-live/pending" ]'

  # ---- peek is read-only and works against a recorded pane id.
  reg "$T_PID"
  check "peek: reads a recorded pane without attaching" 'node "$H/pane.mjs" peek --key ah-panetest-1 --lines 5 >/dev/null 2>&1'

  # ---- send delivers through paste-buffer and leaves a pending token.
  reg "$T_PID"
  mkdir -p "$WORK/mbox-live"
  # Every send in this file passes an explicit short --timeout: the pane is a
  # `sleep`, so nothing ever replies and the 300s default would stall the suite.
  printf 'hello pane\n' | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 >/dev/null 2>&1
  check "send: writes the pending token before pasting" '[ -f "$WORK/mbox-live/pending" ]'
  check "send: leaves pending in place on timeout, so a late reply still lands" '[ -f "$WORK/mbox-live/pending" ]'
  check "send: logs ev=sent" 'grep -q "\"ev\":\"sent\"" "$WORK/mbox-live/log.jsonl"'
  check "send: refuses a second send while one is outstanding" \
    'printf x | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 >/dev/null 2>&1; [ $? -eq 1 ]'
  check "send: the text actually landed in the pane" 'tmux capture-pane -p -t "$T_PANE" | grep -q "hello pane"'
  rm -f "$WORK/mbox-live/pending"

  # ---- 24: kill safety. A record whose pane_pid is our own pid is refused,
  #          and no signal reaches it — this script surviving to the next line
  #          IS the assertion that no SIGTERM was delivered to $$.
  reg "$$"
  node "$H/pane.mjs" close --key ah-panetest-1 > "$WORK/o24" 2>&1
  check "kill safety: refuses to signal this process's own pid" 'grep -q "refusing to kill pid" "$WORK/o24"'
  check "kill safety: no signal reached this process" 'kill -0 $$ 2>/dev/null'
  check "kill safety: a refused close is not recorded as a successful close" '! grep -q "\"reason\":\"user\"" "$REG"'

  # ---- close reaps the tmux session and the recorded pid.
  reg "$T_PID"
  node "$H/pane.mjs" close --key ah-panetest-1 >/dev/null 2>&1
  check "close: the tmux session is gone" '! tmux has-session -t ah-panetest-1 2>/dev/null'
  check "close: the recorded process is gone" '! kill -0 "$T_PID" 2>/dev/null'
  check "close: appends a close event rather than rewriting" 'grep -q "\"ev\":\"close\"" "$REG"'
else
  echo "SKIP: tmux not installed — self-send, send, and kill-safety cases not run"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
