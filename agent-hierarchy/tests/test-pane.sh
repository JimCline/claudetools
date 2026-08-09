#!/bin/bash
# agent-hierarchy durable agents (/durable) — the parts that must hold with no
# live Claude session.
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

# ---- gate E (0.10.0): the echo line ties a Stop to the request it answers.
#      Pendings WITHOUT the echo flag relay on turn order — cases 2/5/6 above
#      pin that legacy path, so gate E cannot regress it.
D="$(mailbox)"
echo '{"reqid":"r-echo","echo":true,"sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"[ah-reply r-echo]\nECHOED BODY"}'
check "gate E: an echoed reply is relayed" '[ -f "'$D'/reply.r-echo.json" ]'
check "gate E: the echo line is stripped from the relayed text" \
  '[ "$(node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"'$D'/reply.r-echo.json\",\"utf8\")).text)")" = "ECHOED BODY" ]'
check "gate E: an echoed reply consumes the token" '[ ! -f "'$D'/pending" ]'

# ---- gate E, 0.13.0: the gate is unchanged — a human's answer still never
#      reaches the Orchestrator — but it no longer fails SILENTLY, which used to
#      strand finished work whenever a compaction took the reqid with it. The
#      first unechoed turn gets ONE nag carrying the id back; only the turn
#      after that is filed as unmatched.
D="$(mailbox)"
echo '{"reqid":"r-cross","echo":true,"sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
NAG_OUT="$(AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"answer to the human, no echo line"}')"
check "gate E: a turn without the echo is NOT relayed" '! ls "'$D'"/reply.*.json >/dev/null 2>&1'
check "gate E: a turn without the echo does NOT consume the token" '[ -f "'$D'/pending" ]'
check "gate E: the first unechoed turn is nagged, not filed" \
  '[ -f "'$D'/nag.r-cross.json" ] && ! ls "'$D'"/unmatched.*.json >/dev/null 2>&1'
check "gate E: the nag keeps the turn's text" 'grep -q "answer to the human" "'$D'/nag.r-cross.json"'
check "gate E: the nag asks the harness to block" 'echo "$NAG_OUT" | grep -q "\"decision\":\"block\""'
check "gate E: the block reason carries the request id" 'echo "$NAG_OUT" | grep -q "r-cross"'
check "gate E: the block reason offers the not-a-reply escape" 'echo "$NAG_OUT" | grep -q "ah-not-a-reply"'
check "gate E: logs ev=nagged" 'grep -q "\"ev\":\"nagged\"" "'$D'/log.jsonl"'
WRONG_OUT="$(AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"[ah-reply r-WRONG]\nhijack"}')"
check "gate E: a WRONG echo id is not relayed and keeps the token" \
  '[ -f "'$D'/pending" ] && ! ls "'$D'"/reply.*.json >/dev/null 2>&1'
check "gate E: the second failure is filed as unmatched" 'ls "'$D'"/unmatched.*.json >/dev/null 2>&1'
check "gate E: logs ev=unmatched" 'grep -q "\"ev\":\"unmatched\"" "'$D'/log.jsonl"'
check "gate E: one nag per request, never a loop" '! echo "$WRONG_OUT" | grep -q "\"decision\":\"block\""'
check "gate E: the nag file is folded away once it is filed" '! [ -f "'$D'/nag.r-cross.json" ]'
check "gate E: the unmatched record keeps BOTH turns of text" \
  'cat "'$D'"/unmatched.*.json | grep -q "answer to the human" && cat "'$D'"/unmatched.*.json | grep -q "hijack"'
check "gate E: the unmatched record names why it gave up" \
  'cat "'$D'"/unmatched.*.json | grep -q "\"reason\":\"already_nagged\""'
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"[ah-reply r-cross]\nthe real answer"}'
check "gate E: the correctly echoed turn still gets through afterwards" \
  '[ "$(node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"'$D'/reply.r-cross.json\",\"utf8\")).text)")" = "the real answer" ]'

# ---- the happy path for the nag: the pane takes the id back and corrects
#      itself, so nothing is left stranded at all.
D="$(mailbox)"
echo '{"reqid":"r-retry","echo":true,"sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"finished, but forgot the line"}' >/dev/null
check "gate E retry: the nag is written" '[ -f "'$D'/nag.r-retry.json" ]'
AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"[ah-reply r-retry]\nthe corrected answer"}' >/dev/null
check "gate E retry: the corrected turn is relayed" \
  '[ "$(node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"'$D'/reply.r-retry.json\",\"utf8\")).text)")" = "the corrected answer" ]'
check "gate E retry: the nag is cleared, so nothing reads as stranded" '! [ -f "'$D'/nag.r-retry.json" ]'
check "gate E retry: no unmatched file is left behind" '! ls "'$D'"/unmatched.*.json >/dev/null 2>&1'

# ---- [ah-not-a-reply]: only the pane knows whether it was answering a human,
#      so it gets to say so. Filed at once, never relayed, never nagged twice.
D="$(mailbox)"
echo '{"reqid":"r-human","echo":true,"sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
DECL_OUT="$(AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","last_assistant_message":"[ah-not-a-reply]\nthis one was for the human"}')"
check "gate E declined: not relayed" '! ls "'$D'"/reply.*.json >/dev/null 2>&1'
check "gate E declined: the token survives for the real answer" '[ -f "'$D'/pending" ]'
check "gate E declined: filed immediately, with no nag" \
  'ls "'$D'"/unmatched.*.json >/dev/null 2>&1 && ! [ -f "'$D'/nag.r-human.json" ]'
check "gate E declined: no block is requested" '! echo "$DECL_OUT" | grep -q "\"decision\":\"block\""'
check "gate E declined: the reason is recorded" 'cat "'$D'"/unmatched.*.json | grep -q "\"reason\":\"declined\""'
check "gate E declined: the marker is stripped from the saved text" \
  'cat "'$D'"/unmatched.*.json | grep -q "this one was for the human" && ! cat "'$D'"/unmatched.*.json | grep -q "ah-not-a-reply"'

# ---- stop_hook_active is honoured when the harness sends it, but the nag file
#      above is the guard that actually holds: this field is not in Claude
#      Code's documented Stop input.
D="$(mailbox)"
echo '{"reqid":"r-active","echo":true,"sent_at":"2026-01-01T00:00:00Z","expect_session":null}' > "$D/pending"
ACT_OUT="$(AGENT_HIERARCHY_PANE_DIR="$D" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  relay '{"session_id":"s9","agent_type":"agent-hierarchy:architect","stop_hook_active":true,"last_assistant_message":"no echo, already resumed once"}')"
check "gate E: stop_hook_active suppresses the nag" '! echo "$ACT_OUT" | grep -q "\"decision\":\"block\""'
check "gate E: stop_hook_active files the turn instead" 'ls "'$D'"/unmatched.*.json >/dev/null 2>&1'
check "gate E: stop_hook_active records itself as the reason" \
  'cat "'$D'"/unmatched.*.json | grep -q "\"reason\":\"stop_hook_active\""'

# ---- envelope + reply-structure helpers (0.10.0)
check "envelope: wrapPrompt stamps the id, the echo rule, and the structure rule" \
  'node --input-type=module -e "
import { wrapPrompt } from \"$H/lib-pane.mjs\";
const t = wrapPrompt(\"RID\", \"the body\");
if (!t.includes(\"[ah-request RID]\") || !t.includes(\"[ah-reply RID]\") || !t.includes(\"TL;DR\") || !t.endsWith(\"the body\")) process.exit(1);
"'
check "tldr: extractTldr returns exactly the TL;DR section" \
  '[ "$(node --input-type=module -e "
import { extractTldr } from \"$H/lib-pane.mjs\";
process.stdout.write(extractTldr(\"## TL;DR\n- a\n- b\n\n## Rest\nzz\") || \"NULL\");
")" = "## TL;DR
- a
- b" ]'
check "tldr: extractTldr is null when the section is absent" \
  '[ "$(node --input-type=module -e "
import { extractTldr } from \"$H/lib-pane.mjs\";
process.stdout.write(String(extractTldr(\"no sections here\")));
")" = "null" ]'
check "tldr: sectionHeadings lists the grep targets in order" \
  '[ "$(node --input-type=module -e "
import { sectionHeadings } from \"$H/lib-pane.mjs\";
process.stdout.write(sectionHeadings(\"## TL;DR\nx\n## A\ny\n## B\n\").join(\",\"));
")" = "## TL;DR,## A,## B" ]'

# ================================================= sessionstart pane branch (§8)

start() { echo "$2" | env AGENT_HIERARCHY_PANE_DIR="$1" AGENT_HIERARCHY_PANE_ROLE="agent-hierarchy:architect" \
  AGENT_HIERARCHY_PANE_KEY="ah-test-architect-1" node "$H/sessionstart.mjs" 2>/dev/null ; }

# ---- 7: pane protocol is injected with and without agent_type, and the pane
#         records its session identity for §9.4's gate D.
D="$(mailbox)"
P1="$(start "$D" '{"session_id":"p1","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"startup"}')"
check "sessionstart pane: emits the pane protocol" 'echo "$P1" | grep -q "agent-hierarchy DURABLE AGENT"'
check "sessionstart pane: says NOT the Orchestrator" 'echo "$P1" | grep -q "You are NOT the Orchestrator"'
check "sessionstart pane: never says You are the Orchestrator" '! echo "$P1" | grep -q "You are the Orchestrator\\."'
check "sessionstart pane: states the one-channel rule" 'echo "$P1" | grep -q "inbound only"'
check "sessionstart pane: states artifacts go to disk by path" 'echo "$P1" | grep -q "ABSOLUTE PATH"'
check "sessionstart pane: forbids nesting durable agents" 'echo "$P1" | grep -q "Do not create durable agents"'
check "sessionstart pane: states the echo rule" 'echo "$P1" | grep -q "ah-reply"'
check "sessionstart pane: states the TL;DR structure rule" 'echo "$P1" | grep -q "TL;DR"'
check "sessionstart pane: records <dir>/session with the session_id" 'grep -q "\"session_id\":\"p1\"" "'$D'/session"'

D2="$(mailbox)"
P2="$(start "$D2" '{"session_id":"p2","cwd":"'$WORK'","source":"startup"}')"
check "sessionstart pane: protocol emitted even with no agent_type" 'echo "$P2" | grep -q "agent-hierarchy DURABLE AGENT"'

D3="$(mailbox)"
echo '{"session_id":"first","agent_type":"agent-hierarchy:architect","at":"x"}' > "$D3/session"
start "$D3" '{"session_id":"second","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect"}' >/dev/null
check "sessionstart pane: session file is first-writer-wins" 'grep -q "\"session_id\":\"first\"" "'$D3'/session"'

# ---- 8: the pane branch wins over the subagent branch.
D="$(mailbox)"
P3="$(start "$D" '{"session_id":"p3","cwd":"'$WORK'","agent_id":"sub-1","agent_type":"agent-hierarchy:architect"}')"
check "sessionstart pane: pane branch beats the subagent branch" 'echo "$P3" | grep -q "agent-hierarchy DURABLE AGENT"'

# ---- 9: a broken mailbox must not cost the session its protocol.
P4="$(start "$WORK/no/such/dir/anywhere" '{"session_id":"p4","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect"}')"
check "sessionstart pane: survives a non-existent mailbox dir" 'echo "$P4" | grep -q "agent-hierarchy DURABLE AGENT"'

# ---- 9b (0.13.0): the OUTSTANDING request id is re-supplied from disk at every
#      session start. `compact` is in this hook's matcher, so a compaction that
#      drops the opaque reqid gets it straight back — which is the whole reason
#      gate E stopped stranding finished work.
D5="$(mailbox)"
echo '{"reqid":"r-live","echo":true,"sent_at":"2026-02-02T03:04:05Z","expect_session":null}' > "$D5/pending"
P5="$(start "$D5" '{"session_id":"p5","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"compact"}')"
check "sessionstart pane: injects the outstanding request id" 'echo "$P5" | grep -q "CURRENT REQUEST"'
check "sessionstart pane: injects the exact echo line to use" 'echo "$P5" | grep -q "\[ah-reply r-live\]"'
check "sessionstart pane: names when the request was delivered" 'echo "$P5" | grep -q "2026-02-02T03:04:05Z"'
check "sessionstart pane: points at the on-disk id so recall is never required" \
  'echo "$P5" | grep -q "AGENT_HIERARCHY_PANE_DIR/pending"'

D6="$(mailbox)"
P6="$(start "$D6" '{"session_id":"p6","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"startup"}')"
check "sessionstart pane: no request outstanding means no CURRENT REQUEST block" \
  '! echo "$P6" | grep -q "CURRENT REQUEST"'

D7="$(mailbox)"
printf 'not json at all' > "$D7/pending"
P7="$(start "$D7" '{"session_id":"p7","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"compact"}')"
check "sessionstart pane: a corrupt pending costs the id, never the protocol" \
  'echo "$P7" | grep -q "agent-hierarchy DURABLE AGENT" && ! echo "$P7" | grep -q "CURRENT REQUEST"'

D8="$(mailbox)"
echo '{"reqid":"r-nodate","echo":true,"expect_session":null}' > "$D8/pending"
P8="$(start "$D8" '{"session_id":"p8","cwd":"'$WORK'","agent_type":"agent-hierarchy:architect","source":"compact"}')"
check "sessionstart pane: a pending with no sent_at prints no undefined" \
  'echo "$P8" | grep -q "\[ah-reply r-nodate\]" && ! echo "$P8" | grep -q "undefined"'

check "buildPaneProtocol: omitting pending matches passing null exactly" \
  '[ "$(node --input-type=module -e "import {buildPaneProtocol as b} from \"$H/lib-pane.mjs\";
     const a=b({role:\"r\",declaredRole:\"r\",key:\"ah-k\"});
     const c=b({role:\"r\",declaredRole:\"r\",key:\"ah-k\",pending:null});
     const d=b({role:\"r\",declaredRole:\"r\",key:\"ah-k\",pending:undefined});
     process.stdout.write(String(a===c && c===d))")" = "true" ]'

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
check "registry: list reports nothing live once tmux disagrees" '[ "$(pane list)" = "no durable agents running." ]'
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

# ================================================= §14.1a — canExecute fails SAFE (test 25)

# The invariant: false ONLY when a definition positively proves both Bash and
# Edit are unavailable. The empty-frontmatter branch is the one a well-meaning
# "simplification" would invert.
ce() { node --input-type=module -e "
import { canExecute } from '$H/lib-pane.mjs';
process.stdout.write(String(canExecute(JSON.parse(process.argv[1]))));
" "$1" ; }

check "canExecute: empty frontmatter fails SAFE (true — always asks)" '[ "$(ce "{}")" = "true" ]'
check "canExecute: denying Bash+Edit+NotebookEdit rules execution out" \
  '[ "$(ce "{\"disallowedTools\":[\"Bash\",\"Edit\",\"NotebookEdit\"]}")" = "false" ]'
check "canExecute: denying Bash alone still asks (Edit remains)" \
  '[ "$(ce "{\"disallowedTools\":[\"Bash\"]}")" = "true" ]'
check "canExecute: a read-only allowlist rules execution out" \
  '[ "$(ce "{\"tools\":[\"Read\",\"Grep\"]}")" = "false" ]'
check "canExecute: a wildcard allowlist asks" '[ "$(ce "{\"tools\":[\"*\"]}")" = "true" ]'

# ================================================= §6.3a — two sources of truth (tests 26-30)

# A synthetic divergence: a fake directory-sourced marketplace whose checkout
# and installed cache disagree about agents/x.md. The real trees on this
# machine are byte-identical today, so the fixture is built, not found.
DIVROOT="$WORK/div"
CACHE="$DIVROOT/cache/divplug/1.0.0"
CHECKOUT="$DIVROOT/checkout"
mkdir -p "$CACHE/agents" "$CHECKOUT/.claude-plugin" "$CHECKOUT/divplug/agents" "$DIVROOT/ghcache/ghplug/1.0.0/agents"
cat > "$HOME/.claude/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": {
  "agent-hierarchy@claudetools": [
    { "scope": "user", "installPath": "$PLUGIN", "version": "9.9.9", "lastUpdated": "2026-01-01T00:00:00Z" } ],
  "divplug@divmarket": [
    { "scope": "user", "installPath": "$CACHE", "version": "1.0.0", "lastUpdated": "2026-01-01T00:00:00Z" } ],
  "ghplug@ghmarket": [
    { "scope": "user", "installPath": "$DIVROOT/ghcache/ghplug/1.0.0", "version": "1.0.0", "lastUpdated": "2026-01-01T00:00:00Z" } ]
} }
JSON
cat > "$HOME/.claude/plugins/known_marketplaces.json" <<JSON
{ "divmarket": { "source": { "source": "directory", "path": "$CHECKOUT" }, "installLocation": "$CHECKOUT" },
  "ghmarket":  { "source": { "source": "github", "repo": "x/y" }, "installLocation": "$DIVROOT/ghmarket" } }
JSON
goodmanifest() { cat > "$CHECKOUT/.claude-plugin/marketplace.json" <<JSON
{ "name": "divmarket", "plugins": [ { "name": "divplug", "source": "./divplug", "version": "1.0.0" } ] }
JSON
}
goodmanifest
restricted_md() { cat > "$1" <<'MD'
---
name: x
disallowedTools:
  - Bash
  - Edit
  - NotebookEdit
---
restricted body
MD
}
capable_md() { cat > "$1" <<'MD'
---
name: x
tools:
  - Bash
---
capable body
MD
}
restricted_md "$CACHE/agents/x.md"
capable_md   "$CHECKOUT/divplug/agents/x.md"
restricted_md "$DIVROOT/ghcache/ghplug/1.0.0/agents/y.md"

# ---- 26: divergence is detected, both paths surface, and warn continues.
OUT26="$(pane open --agent divplug:x --orient right --dry-run --cwd "$WORK")"; RC=$?
check "divergence: dry-run open exits 0 under the default warn" '[ "$RC" -eq 0 ]'
check "divergence: definition_source is divergent" 'echo "$OUT26" | grep -q "\"definition_source\": \"divergent\""'
check "divergence: definition_path_live is populated" \
  'echo "$OUT26" | grep -q "\"definition_path_live\": \"'$CHECKOUT'/divplug/agents/x.md\""'
check "divergence: both paths appear in the output" \
  'echo "$OUT26" | grep -q "'$CACHE'/agents/x.md" && echo "$OUT26" | grep -q "'$CHECKOUT'/divplug/agents/x.md"'
check "divergence: the warning names the resync command" 'echo "$OUT26" | grep -q "plugin marketplace update divmarket"'

# ---- 27: the union resolves by OR, and the answer must not depend on which
#          side is stale. This is the security test.
check "divergence union: asks when the CHECKOUT copy can execute" 'echo "$OUT26" | grep -q "permission prompt required: yes"'
cp "$CACHE/agents/x.md" "$WORK/swap.tmp"
cp "$CHECKOUT/divplug/agents/x.md" "$CACHE/agents/x.md"
cp "$WORK/swap.tmp" "$CHECKOUT/divplug/agents/x.md"
OUT27="$(pane open --agent divplug:x --orient right --dry-run --cwd "$WORK")"
check "divergence union: asks when the CACHE copy can execute (trees swapped)" \
  'echo "$OUT27" | grep -q "permission prompt required: yes"'
check "divergence union: still divergent after the swap" 'echo "$OUT27" | grep -q "\"definition_source\": \"divergent\""'

# ---- 28: identical copies stay QUIET — the normal case must not warn.
cp "$CACHE/agents/x.md" "$CHECKOUT/divplug/agents/x.md"
OUT28="$(pane open --agent divplug:x --orient right --dry-run --cwd "$WORK")"
check "divergence: byte-identical copies report identical" 'echo "$OUT28" | grep -q "\"definition_source\": \"identical\""'
check "divergence: byte-identical copies emit no divergence warning" '! echo "$OUT28" | grep -qi "they differ"'

# ---- 29: onDefinitionDivergence=refuse exits 2 and names both paths.
restricted_md "$CACHE/agents/x.md"
capable_md   "$CHECKOUT/divplug/agents/x.md"
cp "$CFG" "$WORK/cfg29.bak"
node -e "
  const fs=require('fs'); const c=JSON.parse(fs.readFileSync('$CFG','utf8'));
  c.panes={ onDefinitionDivergence:'refuse' }; fs.writeFileSync('$CFG', JSON.stringify(c));
"
pane open --agent divplug:x --orient right --dry-run --cwd "$WORK" >/dev/null; RC=$?
check "divergence: onDefinitionDivergence=refuse exits 2" '[ "$RC" -eq 2 ]'
check "divergence: the refusal names both paths" \
  'grep -q "'$CACHE'/agents/x.md" "$WORK/err" && grep -q "'$CHECKOUT'/divplug/agents/x.md" "$WORK/err"'
node -e "
  const fs=require('fs'); const c=JSON.parse(fs.readFileSync('$CFG','utf8'));
  c.panes={ onDefinitionDivergence:'ignore' }; fs.writeFileSync('$CFG', JSON.stringify(c));
"
check "divergence: there is no \"ignore\" value — it warns and stays on warn" \
  'pane open --agent divplug:x --orient right --dry-run --cwd "$WORK" | grep -q "ignoring panes.onDefinitionDivergence"'
cp "$WORK/cfg29.bak" "$CFG"

# ---- 30: a non-local marketplace is inert — no live candidate, no warning.
OUT30="$(pane open --agent ghplug:y --orient right --dry-run --cwd "$WORK")"
check "divergence: a github marketplace computes no live candidate" 'echo "$OUT30" | grep -q "\"definition_path_live\": null"'
check "divergence: a github marketplace stays recorded" 'echo "$OUT30" | grep -q "\"definition_source\": \"recorded\""'
check "divergence: a github marketplace emits no divergence warning" '! echo "$OUT30" | grep -qi "they differ"'

# ---- an unrecognised plugin `source` shape abandons the live candidate
#      LOUDLY, never silently (§6.3a step 4 was verified on two entries in one
#      manifest, so unknown shapes are expected someday).
cat > "$CHECKOUT/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "divmarket", "plugins": [ { "name": "divplug", "source": { "weird": true } } ] }
JSON
OUT30b="$(pane open --agent divplug:x --orient right --dry-run --cwd "$WORK")"
check "divergence: an unrecognised source shape warns rather than abandoning silently" \
  'echo "$OUT30b" | grep -q "does not recognise"'
check "divergence: an unrecognised source shape degrades to recorded" \
  'echo "$OUT30b" | grep -q "\"definition_source\": \"recorded\""'
goodmanifest

# ---- doctor notices the stale cache, at doctor time (§6.3a).
DOC="$(pane doctor)"
check "doctor: compares installed agents/ against the live checkout" 'echo "$DOC" | grep -q "divplug@divmarket"'
check "doctor: reports the divergent tree as stale with the resync command" \
  'echo "$DOC" | grep "divplug@divmarket" | grep -q "STALE.*marketplace update divmarket"'

# ================================================= §13.3 — the group kill is guarded (test 32)

# killPane with every process-touching dependency stubbed: the assertions are
# about WHICH target the guard chooses, and a negative target may appear only
# when ps confirmed the recorded pid leads its own group and that group is not
# our own.
killcase() { node --input-type=module -e "
import { killPane } from '$H/lib-pane.mjs';
const [panePid, panePgid, ownPgid] = process.argv.slice(1, 4).map(Number);
const calls = [];
let alive = true;
const res = killPane(
  { key: 'ah-killtest-1', tmux_session: 'ah-killtest-1', pane_pid: panePid },
  {
    readPgid: (pid) => (pid === panePid ? panePgid : ownPgid),
    ownPgid,
    kill: (target, sig) => { calls.push(target + ':' + sig); alive = false; },
    pidAlive: () => alive,
    sleep: () => {},
    selfPid: 999999,
    selfPpid: 999998,
  }
);
process.stdout.write(JSON.stringify({ ok: res.ok, calls, notes: res.notes }));
" "$1" "$2" "$3" ; }

R32A="$(killcase 4242 777 111)"
check "group kill: unconfirmed leadership falls back to the single pid" 'echo "$R32A" | grep -q "\"4242:SIGTERM\""'
check "group kill: unconfirmed leadership never signals a group" '! echo "$R32A" | grep -q -- "-4242"'
check "group kill: the single-pid fallback says children may survive" 'echo "$R32A" | grep -q "children may survive"'
R32B="$(killcase 4242 4242 111)"
check "group kill: a ps-confirmed leader is killed as a GROUP" 'echo "$R32B" | grep -q -- "\"-4242:SIGTERM\""'
R32C="$(killcase 4242 4242 4242)"
check "group kill: our own process group is never group-killed" \
  '! echo "$R32C" | grep -q -- "-4242" && echo "$R32C" | grep -q "\"4242:SIGTERM\""'

# ================================================= 0.9.0 — durable rename + launching fold

check "create: is a synonym for open" \
  'pane create --agent agent-hierarchy:architect --orient right --dry-run --cwd "$WORK" | grep -q "DRY RUN"'
pane bogus >/dev/null 2>&1
check "usage: names create" 'grep -q "create|open" "$WORK/err"'

# F2: the launching event must be on disk BEFORE tmux can run, so a crash
# between the two never leaves an untracked session.
LAUNCH_LINE=$(grep -n '"launching"' "$H/pane.mjs" | head -1 | cut -d: -f1)
OPENTMUX_LINE=$(grep -n 'openTmuxSession(tmuxArgv' "$H/pane.mjs" | head -1 | cut -d: -f1)
check "launching: the launching event precedes the tmux launch in source" '[ "$LAUNCH_LINE" -lt "$OPENTMUX_LINE" ]'

cat > "$REG" <<'JSON'
{"ev":"launching","key":"ah-crash-arch-1","agent":"a"}
{"ev":"launching","key":"ah-mid-arch-1","agent":"a"}
{"ev":"open","key":"ah-mid-arch-1","agent":"a","pane_id":"%7"}
JSON
check "launching: a key stuck at launching is never live" \
  '[ "$(node --input-type=module -e "import { foldRegistry } from \"$H/lib-pane.mjs\"; process.stdout.write([...foldRegistry(\"$REG\").keys()].join(\",\"))")" = "ah-mid-arch-1" ]'
DOC2="$(pane doctor)"
check "launching: doctor reaps a launching key with no tmux session" 'echo "$DOC2" | grep -q "ah-crash-arch-1: no tmux session"'
check "launching: the reap is an appended close event" 'grep "\"ev\":\"close\"" "$REG" | grep -q "launch-crashed"'
rm -f "$REG"

# ================================================= 0.9.0 — SessionStart roster

cat > "$REG" <<'JSON'
{"ev":"open","key":"ah-ghost-arch-1","agent":"agent-hierarchy:architect","pane_id":"%42","tmux_session":"ah-ghost-arch-1"}
JSON
R1="$(echo '{"session_id":"orchA","cwd":"'$WORK'","source":"startup"}' | \
  env -u AGENT_HIERARCHY_PANE_DIR -u AGENT_HIERARCHY_PANE_ROLE -u AGENT_HIERARCHY_PANE_KEY node "$H/sessionstart.mjs" 2>/dev/null)"
check "roster: a dead-only registry injects no roster" '! echo "$R1" | grep -q "Durable agents live right now"'
check "roster: the dead key was reaped at session start" 'grep "\"ev\":\"close\"" "$REG" | grep -q "ah-ghost-arch-1"'
check "roster: the ordinary directive still arrives" 'echo "$R1" | grep -q "Orchestrator"'
rm -f "$REG"
R2="$(echo '{"session_id":"orchB","cwd":"'$WORK'","source":"startup"}' | \
  env -u AGENT_HIERARCHY_PANE_DIR node "$H/sessionstart.mjs" 2>/dev/null)"
check "roster: no registry file injects no roster" '! echo "$R2" | grep -q "Durable agents live right now"'

# ================================================= 0.9.0 — PreToolUse durable offer (fast paths)

OFFER="$H/pretooluse-durable-offer.mjs"
rm -f "$REG" "$HOME/.claude/agent-hierarchy.durable-offers.jsonl"
O0="$(echo '{"session_id":"od0","cwd":"'$WORK'","tool_name":"Agent","tool_input":{"subagent_type":"agent-hierarchy:architect"}}' | \
  env -u AGENT_HIERARCHY_PANE_DIR node "$OFFER")"
check "offer: silent with no registry" '[ -z "$O0" ]'

# ================================================= 0.10.0 — cancel

CD="$HOME/.claude/agent-hierarchy.panes/ah-cnl-arch-1"
mkdir -p "$CD"
echo '{"reqid":"r-c","sent_at":"2026-01-01T00:00:00Z"}' > "$CD/pending"
OUTC="$(pane cancel --key ah-cnl-arch-1)"
check "cancel: clears the pending token" '[ ! -f "$CD/pending" ]'
check "cancel: names the cancelled request" 'echo "$OUTC" | grep -q "r-c"'
check "cancel: logs ev=cancelled" 'grep -q "\"ev\":\"cancelled\"" "$CD/log.jsonl"'
OUTC2="$(pane cancel --key ah-cnl-arch-1)"
check "cancel: says so when nothing is outstanding" 'echo "$OUTC2" | grep -q "no request is outstanding"'
pane cancel --key "not-a-key;id" >/dev/null 2>&1; RC=$?
check "cancel: refuses a key outside the whitelist with exit 2" '[ "$RC" -eq 2 ]'

# ================================================= 0.11.0 — wait

# The Bash tool kills commands at 120s by default; a send that outlives it dies
# with its guidance unprinted. BOOT_WAIT_SECONDS (30) plus the default poll
# window must stay under that kill.
check "wait: default send window survives the Bash tool's 120s kill" \
  'node --input-type=module -e "
import { PANE_DEFAULTS } from \"$H/lib-pane.mjs\";
if (!(30 + PANE_DEFAULTS.timeoutSeconds < 120)) process.exit(1);
"'

WD="$HOME/.claude/agent-hierarchy.panes/ah-wt-arch-1"
mkdir -p "$WD"
echo '{"reqid":"r-w1","echo":true,"sent_at":"2026-01-01T00:00:00Z"}' > "$WD/pending"
node -e 'require("fs").writeFileSync(process.argv[1] + "/reply.r-w1.json", JSON.stringify({ reqid: "r-w1", text: "WAITED BODY" }))' "$WD"
OUTW="$(pane wait --key ah-wt-arch-1 --timeout 5)"
check "wait: presents the reply for the outstanding request" 'echo "$OUTW" | grep -q "WAITED BODY"'
check "wait: names the request id" 'echo "$OUTW" | grep -q "r-w1"'
rm -f "$WD/pending"
OUTW2="$(pane wait --key ah-wt-arch-1)"
check "wait: with no pending, re-presents the newest reply on disk" 'echo "$OUTW2" | grep -q "WAITED BODY"'
check "wait: says the request is no longer outstanding" 'echo "$OUTW2" | grep -q "no request is outstanding"'
sleep 1
node -e '
  const fs = require("fs"), d = process.argv[1];
  const body = "## TL;DR\n- Verdict: ship it\n\n## Verdict\n" + "y".repeat(5000) + "\n";
  fs.writeFileSync(d + "/reply.r-w2.json", JSON.stringify({ reqid: "r-w2", text: body }));
' "$WD"
OUTW3="$(pane wait --key ah-wt-arch-1)"
check "wait: a late oversized reply still hits the size gate" 'echo "$OUTW3" | grep -q "stays on disk"'
check "wait: the late body never prints" '! echo "$OUTW3" | grep -q "yyyyyyyyyy"'
check "wait: the late TL;DR is printed" 'echo "$OUTW3" | grep -q "Verdict: ship it"'
check "wait: the late body file is on disk" 'grep -q "yyyyyyyyyy" "$WD/reply.r-w2.md"'
pane wait --key ah-wt2-arch-1 >/dev/null 2>&1; RC=$?
check "wait: nothing outstanding and nothing on disk is a plain failure" '[ "$RC" -eq 1 ]'
pane wait --key "bad;key" >/dev/null 2>&1; RC=$?
check "wait: refuses a key outside the whitelist with exit 2" '[ "$RC" -eq 2 ]'
echo '{"reqid":"r-w3","echo":true,"sent_at":"2026-01-01T00:00:00Z"}' > "$WD/pending"
pane wait --key ah-wt-arch-1 --timeout 1 > "$WORK/o-wt" 2>&1; RC=$?
check "wait: times out gracefully when no reply arrives" '[ "$RC" -eq 1 ] && grep -q "No reply from" "$WORK/o-wt"'
check "wait timeout: arms the background ear" 'grep -q "run_in_background: true" "$WORK/o-wt"'
check "wait timeout: prints the ear command verbatim" 'grep -q -- "wait --key ah-wt-arch-1 --timeout 3600" "$WORK/o-wt"'
rm -f "$WD/pending"
echo '{"reqid":"r-w5","echo":true,"sent_at":"2026-01-01T00:00:00Z"}' > "$WD/pending"
node "$H/pane.mjs" wait --key ah-wt-arch-1 --timeout 0 > "$WORK/o-w0" 2>&1 &
W0PID=$!
sleep 3
if kill -0 "$W0PID" 2>/dev/null; then W0ALIVE=1; kill "$W0PID" 2>/dev/null; else W0ALIVE=0; fi
check "wait: --timeout 0 never gives up on its own" '[ "$W0ALIVE" -eq 1 ] && ! grep -q "No reply" "$WORK/o-w0"'
rm -f "$WD/pending"

# ================================================= 0.12.0 — finish nudge

check "nudge: presenting writes the presented marker" '[ -f "$WD/reply.r-w2.presented" ]'
check "nudge: hooks.json registers the UserPromptSubmit hook" \
  'node -e "const j=JSON.parse(require(\"fs\").readFileSync(\"'$PLUGIN'/hooks/hooks.json\",\"utf8\")); process.exit(Array.isArray(j.hooks.UserPromptSubmit) && JSON.stringify(j).includes(\"userpromptsubmit-durable-nudge\") ? 0 : 1)"'
UPS="$H/userpromptsubmit-durable-nudge.mjs"
rm -f "$REG"
U0="$(echo '{"session_id":"u0","cwd":"'$WORK'"}' | env -u AGENT_HIERARCHY_PANE_DIR node "$UPS")"
check "nudge hook: silent with no registry" '[ -z "$U0" ]'
UD="$HOME/.claude/agent-hierarchy.panes/ah-nud-arch-1"
mkdir -p "$UD"
cat > "$REG" <<JSON
{"ev":"open","key":"ah-nud-arch-1","agent":"agent-hierarchy:architect","dir":"$UD"}
JSON
U1="$(echo '{"session_id":"u1","cwd":"'$WORK'"}' | env -u AGENT_HIERARCHY_PANE_DIR node "$UPS")"
check "nudge hook: silent when the agent has no replies" '[ -z "$U1" ]'
node -e 'require("fs").writeFileSync(process.argv[1] + "/reply.r-n1.json", JSON.stringify({ reqid: "r-n1", text: "NUDGE BODY" }))' "$UD"
U2="$(echo '{"session_id":"u2","cwd":"'$WORK'"}' | env -u AGENT_HIERARCHY_PANE_DIR node "$UPS")"
check "nudge hook: an unread reply produces the nudge" 'echo "$U2" | grep -q "ah-nud-arch-1"'
check "nudge hook: the nudge names the pickup command" 'echo "$U2" | grep -q "wait --key ah-nud-arch-1"'
check "nudge hook: emitted as additionalContext" 'echo "$U2" | grep -q "hookSpecificOutput"'
check "nudge hook: never contains reply text" '! echo "$U2" | grep -q "NUDGE BODY"'
U3="$(echo '{"session_id":"u3","cwd":"'$WORK'"}' | env AGENT_HIERARCHY_PANE_DIR="$UD" node "$UPS")"
check "nudge hook: a pane session is never nudged" '[ -z "$U3" ]'
OUTN="$(pane wait --key ah-nud-arch-1)"
check "nudge: wait picks the unread reply up" 'echo "$OUTN" | grep -q "NUDGE BODY"'
U4="$(echo '{"session_id":"u4","cwd":"'$WORK'"}' | env -u AGENT_HIERARCHY_PANE_DIR node "$UPS")"
check "nudge hook: a presented reply stops nudging" '[ -z "$U4" ]'
mkdir -p "$WORK/off/.claude"
echo '{ "version": 1, "enabled": false }' > "$WORK/off/.claude/agent-hierarchy.json"
node -e 'require("fs").writeFileSync(process.argv[1] + "/reply.r-n2.json", JSON.stringify({ reqid: "r-n2", text: "off body" }))' "$UD"
U5="$(echo '{"session_id":"u5","cwd":"'$WORK'/off"}' | env -u AGENT_HIERARCHY_PANE_DIR node "$UPS")"
check "nudge hook: silent when the hierarchy is disabled" '[ -z "$U5" ]'
rm -f "$REG"
rm -rf "$UD" "$WORK/off"

# ================================================= test 31 — the cache is never globbed

check "cache: hooks never construct a plugins/cache path" '! grep -nE "plugins/cache" "$H"/*.mjs'
check "cache: no readdir is rooted at a cache path" '! grep -n "readdirSync" "$H"/*.mjs | grep -i "cache"'
check "cache: no glob machinery anywhere in hooks" '! grep -nE "globSync|fast-glob|[^a-z]glob\(" "$H"/*.mjs'

# ================================================= §13.4 — no pane discovery

check "no discovery: nothing runs \`tmux ls\` or list-sessions" \
  '! grep -nE "\"(ls|list-sessions)\"|tmux (ls|list-sessions)" "$H"/*.mjs'
check "no discovery: every list-panes passes an explicit -t" \
  '[ "$(grep -c "list-panes" "$H"/*.mjs | cut -d: -f2 | paste -sd+ - | bc)" = "$(grep "list-panes" "$H"/*.mjs | grep -c -- "\"-t\"")" ]'
SENDKEYS=$(grep -c '"send-keys"' "$H"/*.mjs | cut -d: -f2 | paste -sd+ - | bc)
SENDKEYS_ENTER=$(grep '"send-keys"' "$H"/*.mjs | grep -c '"Enter"')
check "no discovery: at least one send-keys call site exists to check" '[ "$SENDKEYS" -ge 1 ]'
check "no discovery: every send-keys call sends only the Enter key" '[ "$SENDKEYS" = "$SENDKEYS_ENTER" ]'
check "no discovery: pgrep and pkill are never used" \
  '! grep -nE "\"(pgrep|pkill)\"" "$H"/*.mjs'
# §13.3 sanctions exactly two ps uses: the pgid LOOKUP on a recorded pid before
# a group kill, and doctor's report-only survivor listing. Both carry "pgid=";
# a ps call without it would be target discovery, which stays banned.
check "no discovery: every ps invocation is a pgid lookup or the doctor report" \
  '[ "$(grep -h "\"ps\"" "$H"/*.mjs | grep -cv "pgid=")" = "0" ]'

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
  # F1 boot gate: sends refuse to paste until the pane's session identity file
  # exists, so every delivering send in this file plants one first.
  echo '{"session_id":"live-sess"}' > "$WORK/mbox-live/session"
  # Every send in this file passes an explicit short --timeout: the pane is a
  # `sleep`, so nothing ever replies and the 300s default would stall the suite.
  printf 'hello pane\n' | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 > "$WORK/o-sendto" 2>&1
  check "send: writes the pending token before pasting" '[ -f "$WORK/mbox-live/pending" ]'
  check "send timeout: points at wait for the pickup" 'grep -q "wait --key ah-panetest-1" "$WORK/o-sendto"'
  check "send timeout: warns against reading reply files raw" 'grep -q "Do NOT read reply files directly" "$WORK/o-sendto"'
  check "send: leaves pending in place on timeout, so a late reply still lands" '[ -f "$WORK/mbox-live/pending" ]'
  check "send: logs ev=sent" 'grep -q "\"ev\":\"sent\"" "$WORK/mbox-live/log.jsonl"'
  check "send: refuses a second send while one is outstanding" \
    'printf x | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 >/dev/null 2>&1; [ $? -eq 1 ]'
  check "send: the text actually landed in the pane" 'tmux capture-pane -p -t "$T_PANE" | grep -q "hello pane"'
  rm -f "$WORK/mbox-live/pending"

  # ---- F1 (0.9.0): send refuses to paste before the pane records its identity.
  reg "$T_PID"
  rm -rf "$WORK/mbox-live"; mkdir -p "$WORK/mbox-live"
  printf 'early bird\n' | node "$H/pane.mjs" send --key ah-panetest-1 --boot-wait 0 --timeout 4 >/dev/null 2>"$WORK/ef1"; RC=$?
  check "boot-wait: send fails when the identity file never appears" '[ "$RC" -eq 1 ]'
  check "boot-wait: the failure says the agent has not finished booting" 'grep -q "has not finished booting" "$WORK/ef1"'
  check "boot-wait: no pending token is left behind" '[ ! -f "$WORK/mbox-live/pending" ]'
  check "boot-wait: nothing was pasted into the pane" '! tmux capture-pane -p -t "$T_PANE" | grep -q "early bird"'
  ( sleep 1; echo '{"session_id":"late-sess"}' > "$WORK/mbox-live/session" ) &
  printf 'late bird\n' | node "$H/pane.mjs" send --key ah-panetest-1 --boot-wait 10 --timeout 3 >/dev/null 2>&1
  check "boot-wait: a late identity file unblocks the send" '[ -f "$WORK/mbox-live/pending" ]'
  check "boot-wait: expect_session comes from the late identity file" 'grep -q "\"expect_session\":\"late-sess\"" "$WORK/mbox-live/pending"'
  rm -f "$WORK/mbox-live/pending"

  # ---- 0.10.0: the reply contract is stamped by the helper, not written by the
  #      Orchestrator — the envelope must be in the delivery and the pending token.
  reg "$T_PID"
  rm -rf "$WORK/mbox-live"; mkdir -p "$WORK/mbox-live"
  echo '{"session_id":"live-sess"}' > "$WORK/mbox-live/session"
  printf 'envelope probe\n' | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 4 >/dev/null 2>&1
  check "envelope: pending carries the echo flag" 'grep -q "\"echo\":true" "$WORK/mbox-live/pending"'
  check "envelope: the delivery opens with ah-request" 'tmux capture-pane -p -t "$T_PANE" | grep -q "ah-request"'
  check "envelope: the delivery states the echo rule inline" 'tmux capture-pane -p -t "$T_PANE" | grep -q "ah-reply"'
  rm -f "$WORK/mbox-live/pending"

  # ---- 0.10.0: the size gate. A reply over replyInlineMaxChars must never
  #      print its body — TL;DR, path, and section list only.
  reg "$T_PID"
  rm -rf "$WORK/mbox-live"; mkdir -p "$WORK/mbox-live"
  echo '{"session_id":"live-sess"}' > "$WORK/mbox-live/session"
  (
    for i in $(seq 1 40); do [ -f "$WORK/mbox-live/pending" ] && break; sleep 0.25; done
    node -e '
      const fs = require("fs"), d = process.argv[1];
      const reqid = JSON.parse(fs.readFileSync(d + "/pending", "utf8")).reqid;
      const body = "## TL;DR\n- Findings: two issues\n- Appendix: raw data\n\n## Findings\n" +
        "x".repeat(5000) + "\n\n## Appendix\nzzz\n";
      fs.writeFileSync(d + "/reply." + reqid + ".json", JSON.stringify({ reqid, text: body }));
    ' "$WORK/mbox-live"
  ) &
  printf 'big reply probe\n' | node "$H/pane.mjs" send --key ah-panetest-1 --timeout 30 > "$WORK/o-size" 2>&1
  wait
  check "size gate: the body is withheld" 'grep -q "stays on disk" "$WORK/o-size"'
  check "size gate: the TL;DR is printed" 'grep -q "Findings: two issues" "$WORK/o-size"'
  check "size gate: the body itself never prints" '! grep -q "xxxxxxxxxx" "$WORK/o-size"'
  check "size gate: the section list names the grep targets" 'grep -q "## Appendix" "$WORK/o-size"'
  check "size gate: points at task-gopher for fetching sections" 'grep -q "task-gopher" "$WORK/o-size"'
  check "size gate: the full body is on disk" 'grep -q "xxxxxxxxxx" "$WORK/mbox-live/reply."*.md'
  rm -f "$WORK/mbox-live/pending"

  # ---- 0.12.0: unread means unpresented, in list and in the roster.
  reg "$T_PID"
  check "list: a presented reply is not unread" '! node "$H/pane.mjs" list 2>/dev/null | grep -q "UNREAD"'
  node -e 'require("fs").writeFileSync(process.argv[1] + "/reply.r-lu.json", JSON.stringify({ reqid: "r-lu", text: "small" }))' "$WORK/mbox-live"
  check "list: an unpresented reply is unread, with the pickup command" \
    'node "$H/pane.mjs" list 2>/dev/null | grep -q "1 UNREAD reply — pick up: pane.mjs wait --key ah-panetest-1"'
  ROSTERU="$(echo '{"session_id":"orchU","cwd":"'$WORK'","source":"startup"}' | \
    env -u AGENT_HIERARCHY_PANE_DIR -u AGENT_HIERARCHY_PANE_ROLE -u AGENT_HIERARCHY_PANE_KEY node "$H/sessionstart.mjs" 2>/dev/null)"
  check "roster: an unread reply is named with its pickup command" 'echo "$ROSTERU" | grep -q "UNREAD reply waiting"'
  rm -f "$WORK/mbox-live"/reply.r-lu.*

  # ---- 0.12.1: an agent rooted in another repo is flagged, not silently used.
  check "cwd guard: list flags an agent rooted elsewhere" \
    'node "$H/pane.mjs" list 2>/dev/null | grep -q "not this session'\''s cwd"'
  check "cwd guard: no flag when cwds match" \
    '! (cd "$WORK" && node "'$H'/pane.mjs" list 2>/dev/null | grep -q "not this session")'
  check "cwd guard: send states the mismatch up front" 'grep -q "rooted in" "$WORK/o-sendto"'

  # ---- roster (0.9.0): SessionStart names the live durable agent, reaps dead ones.
  reg "$T_PID"
  cat >> "$REG" <<'JSON'
{"ev":"open","key":"ah-dead-arch-1","agent":"agent-hierarchy:architect","pane_id":"%99","tmux_session":"ah-dead-arch-1"}
JSON
  ROSTER="$(echo '{"session_id":"orchC","cwd":"'$WORK'","source":"startup"}' | \
    env -u AGENT_HIERARCHY_PANE_DIR -u AGENT_HIERARCHY_PANE_ROLE -u AGENT_HIERARCHY_PANE_KEY node "$H/sessionstart.mjs" 2>/dev/null)"
  check "roster: names the live durable agent" 'echo "$ROSTER" | grep -q "Durable agents live right now"'
  check "roster: lists the live key" 'echo "$ROSTER" | grep -q "ah-panetest-1"'
  check "roster: does not list the dead key" '! echo "$ROSTER" | grep -q "ah-dead-arch-1"'
  check "roster: the dead key was reaped" 'grep "\"ev\":\"close\"" "$REG" | grep -q "ah-dead-arch-1"'

  # ---- offer hook (0.9.0): deny once per (session, type); the re-run passes.
  offer() { echo "$1" | env -u AGENT_HIERARCHY_PANE_DIR node "$OFFER" ; }
  reg "$T_PID"
  rm -f "$HOME/.claude/agent-hierarchy.durable-offers.jsonl"
  DISPATCH='{"session_id":"od1","cwd":"'$WORK'","tool_name":"Agent","tool_input":{"subagent_type":"agent-hierarchy:architect"}}'
  O1="$(offer "$DISPATCH")"
  check "offer: first dispatch matching a live idle durable agent is denied" 'echo "$O1" | grep -q "\"permissionDecision\":\"deny\""'
  check "offer: the denial names the durable agent" 'echo "$O1" | grep -q "ah-panetest-1"'
  check "offer: the denial says the re-run will pass" 'echo "$O1" | grep -q "re-run"'
  O2="$(offer "$DISPATCH")"
  check "offer: the identical re-run passes untouched" '[ -z "$O2" ]'
  check "offer: offers are recorded per session and type" 'grep -q "\"session_id\":\"od1\"" "$HOME/.claude/agent-hierarchy.durable-offers.jsonl"'
  O3="$(offer '{"session_id":"od2","cwd":"'$WORK'","tool_name":"Agent","tool_input":{"subagent_type":"task-gopher:task-gopher"}}')"
  check "offer: task-gopher is exempt" '[ -z "$O3" ]'
  O4="$(offer '{"session_id":"od2","cwd":"'$WORK'","tool_name":"Agent","tool_input":{"subagent_type":"agent-hierarchy:reviewer"}}')"
  check "offer: no matching durable agent means no deny" '[ -z "$O4" ]'
  O5="$(echo "$DISPATCH" | env AGENT_HIERARCHY_PANE_DIR="$WORK/mbox-live" node "$OFFER")"
  check "offer: a pane session is exempt" '[ -z "$O5" ]'
  echo '{"reqid":"busy","sent_at":"2026-01-01T00:00:00Z"}' > "$WORK/mbox-live/pending"
  O6="$(offer '{"session_id":"od3","cwd":"'$WORK'","tool_name":"Agent","tool_input":{"subagent_type":"agent-hierarchy:architect"}}')"
  check "offer: a WORKING durable agent with no idle sibling is not offered" '[ -z "$O6" ]'
  rm -f "$WORK/mbox-live/pending" "$HOME/.claude/agent-hierarchy.durable-offers.jsonl"

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

# ================================================= stranded turns (0.13.0)
#
# Finished work that never reached the Orchestrator. The two kinds are reported
# identically because the Orchestrator's move is the same for both: read it and
# decide whether it answers the question it asked.

SD="$HOME/.claude/agent-hierarchy.panes/ah-stranded-1"
mkdir -p "$SD"
node -e 'const fs=require("fs"), d=process.argv[1];
  fs.writeFileSync(d+"/nag.r-n1.json", JSON.stringify({reqid:"r-n1",at:"2026-01-01T00:00:00Z",text:"work that was nagged"}));
  fs.writeFileSync(d+"/unmatched.1700000000000.json", JSON.stringify({reqid_expected:"r-u1",at:"2026-01-02T00:00:00Z",reason:"already_nagged",prior_text:"an earlier attempt",text:"work that was filed"}));' "$SD"

check "stranded: both kinds are reported" \
  '[ "$(node --input-type=module -e "import {strandedTurns as s} from \"$H/lib-pane.mjs\"; process.stdout.write(String(s(\"'$SD'\").length))")" = "2" ]'
check "stranded: each kind is labelled" \
  '[ "$(node --input-type=module -e "import {strandedTurns as s} from \"$H/lib-pane.mjs\"; process.stdout.write(s(\"'$SD'\").map(t=>t.kind).sort().join(\",\"))")" = "nag,unmatched" ]'
check "stranded: the request id is recovered from both filename and record" \
  '[ "$(node --input-type=module -e "import {strandedTurns as s} from \"$H/lib-pane.mjs\"; process.stdout.write(s(\"'$SD'\").map(t=>t.reqid).sort().join(\",\"))")" = "r-n1,r-u1" ]'
check "stranded: a missing directory is empty, not an error" \
  '[ "$(node --input-type=module -e "import {strandedTurns as s} from \"$H/lib-pane.mjs\"; process.stdout.write(String(s(\"'$WORK'/no/such/mbox\").length))")" = "0" ]'

printf 'not json' > "$SD/unmatched.1700000000001.json"
check "stranded: a corrupt record still lists, with a null id, rather than throwing" \
  '[ "$(node --input-type=module -e "import {strandedTurns as s} from \"$H/lib-pane.mjs\"; const t=s(\"'$SD'\"); process.stdout.write(t.length+\":\"+t.filter(x=>x.reqid===null).length)")" = "3:1" ]'

node "$H/pane.mjs" stranded --key ah-stranded-1 > "$WORK/o-str" 2>&1
check "stranded CLI: lists what is on disk" 'grep -q "3 stranded turns" "$WORK/o-str"'
check "stranded CLI: says the work finished but was never relayed" 'grep -q "never relayed" "$WORK/o-str"'
check "stranded CLI: withholds the text until asked" '! grep -q "work that was nagged" "$WORK/o-str"'
node "$H/pane.mjs" stranded --key ah-stranded-1 --show > "$WORK/o-str2" 2>&1
check "stranded CLI: --show prints both kinds of turn" \
  'grep -q "work that was nagged" "$WORK/o-str2" && grep -q "work that was filed" "$WORK/o-str2"'
check "stranded CLI: --show prints the folded-in earlier attempt too" 'grep -q "an earlier attempt" "$WORK/o-str2"'
node "$H/pane.mjs" stranded --key ah-stranded-1 --clear > "$WORK/o-str3" 2>&1
check "stranded CLI: --clear removes them and reports the count" \
  'grep -q "cleared 3 stranded turns" "$WORK/o-str3" && ! ls "'$SD'"/nag.*.json >/dev/null 2>&1'
check "stranded CLI: an empty mailbox says so plainly" \
  'node "$H/pane.mjs" stranded --key ah-stranded-1 2>&1 | grep -q "no stranded turns"'
check "stranded CLI: refuses a key that is not a pane key" \
  'node "$H/pane.mjs" stranded --key "../../etc" 2>&1 | grep -q "Refusing"'
check "stranded CLI: is listed in the usage line" \
  'node "$H/pane.mjs" bogus-subcommand 2>&1 | grep -q "stranded"'

# ---- the nudge reports stranded turns as their own kind of trouble. An unread
#      reply means "come and collect it"; a stranded turn means "no reply file
#      is ever coming", so waiting longer is exactly the wrong move.
ND="$HOME/.claude/agent-hierarchy.panes/ah-nudge-1"
mkdir -p "$ND"
cat >> "$HOME/.claude/agent-hierarchy.panes.jsonl" <<JSON
{"ev":"open","key":"ah-nudge-1","agent":"agent-hierarchy:architect","pane_id":"%99","pane_pid":1,"tmux_session":"ah-nudge-1","cwd":"$WORK","dir":"$ND","orientation":"right","orchestrator_session_id":"testorch","model":null,"permission_mode":null}
JSON
node -e 'const fs=require("fs"), d=process.argv[1];
  fs.writeFileSync(d+"/nag.r-nudge.json", JSON.stringify({reqid:"r-nudge",at:"2026-01-01T00:00:00Z",text:"the stranded body"}));
  fs.writeFileSync(d+"/unmatched.1700000000002.json", JSON.stringify({reqid_expected:"r-nudge2",at:"2026-01-01T00:00:00Z",text:"another stranded body"}));' "$ND"
NUDGE="$(echo '{"session_id":"n1","cwd":"'$WORK'","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | node "$H/userpromptsubmit-durable-nudge.mjs" 2>/dev/null)"
check "nudge: reports stranded turns" 'echo "$NUDGE" | grep -q "never reached you"'
check "nudge: counts both kinds together" 'echo "$NUDGE" | grep -q "2 finished turns"'
check "nudge: the stranded line names the pane it belongs to" \
  'echo "$NUDGE" | grep "never reached you" | grep -q "ah-nudge-1"'
check "nudge: points at stranded, not at wait" 'echo "$NUDGE" | grep -q "stranded --key ah-nudge-1"'
check "nudge: never leaks the stranded text into context" \
  '! echo "$NUDGE" | grep -q "the stranded body" && ! echo "$NUDGE" | grep -q "another stranded body"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
