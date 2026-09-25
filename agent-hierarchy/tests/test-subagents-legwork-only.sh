#!/bin/bash
# agent-hierarchy — only legwork roles run as subagents. The route gate walls every chain role
# (and ah:orchestrator) whatever opt-in was written before; stale opt-ins are ignored at read,
# reported by the CLI only, and migrated by the next CLI write to their file; new writes that
# would opt a chain role into a subagent exit 2.
# HOME- and AGENT_HIERARCHY_DIR-redirected; no test reaches the real herdr, tmux, or ~/.claude.
# Usage: bash tests/test-subagents-legwork-only.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
GATE="$H/pretooluse-route-gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-legwork-only-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/claude"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux" "$SANDBOX/nolaunch/claude"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
FAKEHOME="$SANDBOX/home"
GLOBAL="$FAKEHOME/.claude/agent-hierarchy.json"
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

new_repo() { # <name>: PROJ, CFG, HD (the hierarchy dir the gate reads), fresh
  PROJ="$SANDBOX/$1"; rm -rf "$PROJ"; mkdir -p "$PROJ/.claude"; (cd "$PROJ" && git init -q)
  CFG="$PROJ/.claude/agent-hierarchy.json"; HD="$SANDBOX/hier-$1"; rm -rf "$HD"; mkdir -p "$HD"
}
fresh_home() { rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME/.claude"; }
write_cfg() { printf '%s\n' "$1" > "$CFG"; }
sum() { cksum < "$1"; }

run_roster() {
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
run_split() { # stdout in OUT, stderr in STDERR
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" "$@" --cwd "$PROJ" 2> "$SANDBOX/stderr"); RC=$?
  STDERR=$(cat "$SANDBOX/stderr")
}
jq_out() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{o=JSON.parse(s.slice(s.indexOf("{")))}process.stdout.write(String((new Function("o","return "+process.argv[1]))(o)))})' "$1" 2>/dev/null; }
jq_file() { node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((new Function("t","return "+process.argv[2]))(t)))' "$1" "$2" 2>/dev/null; }

payload() { # <session> <tool> <subagent_type> [agent_id]
  node -e 'const[s,t,st,a,cwd]=process.argv.slice(1);const o={session_id:s,cwd,tool_name:t,tool_input:{subagent_type:st,prompt:"x"}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3" "$4" "$PROJ"; }
gate() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
RESOLVE_THROWS="$PLUGIN/tests/fixtures/resolve-config-throws.mjs"
gate_resolve_throws() { OUT=$(echo "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --import "$RESOLVE_THROWS" "$GATE" 2>&1); RC=$?; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
spawn_reason() { denied && echo "$OUT" | grep -q "ah chain roles run as peers, never subagents" && echo "$OUT" | grep -qE "spawn-(one|ad-hoc) $1 --cwd"; }
seed_live() { node -e 'const fs=require("fs");const[f,n,r]=process.argv.slice(1);fs.appendFileSync(f,JSON.stringify({type:"peer",status:"seen",name:n,role:r,ts:new Date().toISOString()})+"\n");' "$HD/peers.jsonl" "$1" "$2"; }
stale_route() { echo "{\"type\":\"route\",\"session_id\":\"$1\",\"value\":\"$2\"}" >> "$HD/gates.jsonl"; }
role_set() { # custom role with a scaffolded agent file
  env -u HERDR_ENV HOME="$FAKEHOME" node "$H/roster.mjs" role set "$1" --class "$2" --description "A $2 role." --scaffold user --cwd "$PROJ" >/dev/null 2>&1; }

# ============================================================ G: the route gate
fresh_home
new_repo g1
write_cfg '{"version":1,"enabled":true,"roles":{}}'
stale_route g1s subagents
gate "$(payload g1s Agent ah:architect)"
check "G1: a stale session route subagents record: Agent(ah:architect) denied with spawnReason" 'spawn_reason architect'
write_cfg '{"version":1,"enabled":true,"route":"prefer-peers","roles":{}}'
gate "$(payload g1p Agent ah:architect)"
check "G1: config route prefer-peers, no free peer: denied with spawnReason" 'spawn_reason architect'
seed_live arch-live architect
gate "$(payload g1p2 Agent ah:architect)"
check "G1: config route prefer-peers, a free peer: denied, naming the peer" 'denied && echo "$OUT" | grep -q "arch-live"'
: > "$HD/peers.jsonl"
write_cfg '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus","route":"subagent"}]}}'
gate "$(payload g1r Agent ah:architect)"
check "G1: a roster member's own route subagent: denied with spawnReason" 'spawn_reason architect'
write_cfg '{"version":1,"enabled":true,"roster":{"route":"subagent","members":[{"role":"architect","model":"opus"}]}}'
gate "$(payload g1b Agent ah:architect)"
check "G1: a block-inherited route subagent: denied with spawnReason" 'spawn_reason architect'
write_cfg '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus","onMissing":"never"}]}}'
gate "$(payload g1n Agent ah:architect)"
check "G1: onMissing never: denied with spawnReason" 'spawn_reason architect'
write_cfg '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus","onMissing":"prompt"}]}}'
gate "$(payload g1m Agent ah:architect)"
check "G1: onMissing prompt: denied with spawnReason, no ask" 'spawn_reason architect && ! echo "$OUT" | grep -q AskUserQuestion'
gate "$(payload g1m Agent ah:architect)"
check "G1: onMissing prompt: the identical re-issue is denied too" 'spawn_reason architect'
write_cfg '{"version":1,"enabled":true,"roles":{"architect":{"model":"opus","dispatch":"model"}}}'
gate "$(payload g1d Agent ah:architect)"
check "G1: roles.architect.dispatch model: denied with spawnReason" 'spawn_reason architect'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); const r = C.resolveConfig('$PROJ'); process.stdout.write(r.roles.architect.dispatch + '|' + r.warnings.filter((w) => w.includes('dispatch')).length);" 2>&1)
check "G1: a chain role's stale dispatch model reads as peer, with no warning in session context" '[ "$OUT" = "peer|0" ]'
role_set coder implement
write_cfg '{"version":1,"enabled":true,"roles":{"coder":{"class":"implement","description":"A implement role.","dispatch":"model"}},"roster":{"route":"subagent","members":[{"role":"coder","onMissing":"never"}]}}'
gate "$(payload g1c Agent coder)"
check "G1: a custom implement-class role with every opt-in: denied with spawnReason" 'spawn_reason coder'
stale_route g1c2 subagents
gate "$(payload g1c2 Agent coder)"
check "G1: ...and under a stale session subagents record" 'spawn_reason coder'

gate "$(payload g2 Agent ah:task-runner)"
check "G2: Agent(ah:task-runner) passes" 'allowed'
gate "$(payload g2 Agent task-gopher:task-gopher)"
check "G2: Agent(task-gopher:task-gopher) passes" 'allowed'
role_set helper legwork
gate "$(payload g2 Agent helper)"
check "G2: a custom legwork role passes" 'allowed'

gate "$(payload g3 Agent ah:orchestrator)"
check "G3: Agent(ah:orchestrator) from the Orchestrator: denied" 'denied && echo "$OUT" | grep -q "never runs as a subagent"'
gate "$(payload g3 Task ah:orchestrator)"
check "G3: Task(ah:orchestrator): denied" 'denied && echo "$OUT" | grep -q "never runs as a subagent"'
gate "$(payload g3 Agent ah:orchestrator sub-1)"
check "G3: Agent(ah:orchestrator) from a subagent caller: denied" 'denied && echo "$OUT" | grep -q "never runs as a subagent"'
gate "$(payload g3 Agent orchestrator)"
check "G3: a bare orchestrator ref is not ours: not denied" 'allowed'

gate "$(payload g7 Agent ah:architect)"; BARE=$OUT
gate "$(payload g7 Agent " ah:architect ")"
check "G7: a whitespace-padded ah:architect ref gets the bare ref's exact denial" 'spawn_reason architect && [ "$OUT" = "$BARE" ]'
gate "$(payload g7 Task ah:orchestrator)"; BARE=$OUT
gate "$(payload g7 Task "	ah:orchestrator ")"
check "G7: a whitespace-padded ah:orchestrator ref gets the bare ref's exact denial" 'denied && echo "$OUT" | grep -q "never runs as a subagent" && [ "$OUT" = "$BARE" ]'

write_cfg '{"version":1,"enabled":false,"roles":{}}'
gate "$(payload g4 Agent ah:architect)"
check "G4: enabled:false: Agent(ah:architect) passes" 'allowed'
gate "$(payload g4 Agent ah:orchestrator)"
check "G4: enabled:false: Agent(ah:orchestrator) passes" 'allowed'

write_cfg '{"version":1,"enabled":true,"roles":{}}'
gate "$(payload g5 Agent ah:architect)"
check "G5: spawnReason carries the launch-failure pointer" 'echo "$OUT" | grep -qF "If the command fails to launch, follow agent-team'"'"'s '"'"'When a role can'"'"'t take the work'"'"'."'
check "G5: ...and no route subagents command, opt-in, or 'does not lead to the subagent opt-in'" '! echo "$OUT" | grep -qE "route subagents|opt-in|opts in|opt into"'

# G6: an internal error in the gate fails closed for the five built-in chain refs, open for everything else.
# Two injections, neither a test-only path in the hook: a plain file where the hierarchy dir's msgs/
# belongs makes roster() throw ENOTDIR after role resolution; a load-time rewrite of lib-config.mjs
# (`node --import` of a test fixture) makes resolveConfig itself throw on entry, before enabled or
# the ah:orchestrator deny is reached.
ERRLOG="$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"
FC_HEAD="ah: the route gate hit an internal error and could not check this dispatch (logged to $ERRLOG)."
fail_closed() { # <role> <Label>
  [ "$(jq_out "o.hookSpecificOutput.permissionDecision")" = deny ] &&
  [ "$(jq_out "o.hookSpecificOutput.permissionDecisionReason")" = "$FC_HEAD $2 never runs as a subagent: SendMessage its live peer, or start one with \`node \"$H/roster.mjs\" spawn-one $1 --cwd $PROJ\`." ]
}
orch_fail_closed() { [ "$(jq_out "o.hookSpecificOutput.permissionDecision")" = deny ] && [ "$(jq_out "o.hookSpecificOutput.permissionDecisionReason")" = "$FC_HEAD The Orchestrator never runs as a subagent." ]; }
errlines() { [ -f "$ERRLOG" ] && grep -c '"hook":"pretooluse-route-gate.mjs"' "$ERRLOG" || echo 0; }
send_payload() { printf '{"session_id":"%s","cwd":"%s","tool_name":"SendMessage","tool_input":{"to":"nobody","message":"[hierarchy-peer-brief reply-to=\\"orch\\" task=\\"t\\"]\\nx"}}' "$1" "$PROJ"; }
new_repo g6
write_cfg '{"version":1,"enabled":true,"roles":{}}'
rm -f "$ERRLOG"
: > "$HD/msgs"
gate "$(payload g6 Agent ah:architect)"
check "G6: a throw after role resolution: Agent(ah:architect) denied with the fail-closed text" 'fail_closed architect Architect'
check "G6: ...and the error is logged" '[ "$(errlines)" = 1 ] && grep -q ENOTDIR "$ERRLOG"'
for r in ultra-advisor:Ultra-Advisor reviewer:Reviewer implementor:Implementor; do
  gate "$(payload g6 Agent "ah:${r%%:*}")"
  check "G6: ...Agent(ah:${r%%:*}) too" "fail_closed ${r%%:*} ${r#*:}"
done
gate "$(payload g6 Task ah:orchestrator)"
check "G6: Task(ah:orchestrator): denied (its own deny precedes the throw)" 'denied && echo "$OUT" | grep -q "never runs as a subagent"'
gate "$(payload g6 Agent ah:task-runner)"
check "G6: Agent(ah:task-runner) passes" 'allowed'
gate "$(payload g6 Agent task-gopher:task-gopher)"
check "G6: Agent(task-gopher:task-gopher) passes" 'allowed'
BEFORE=$(errlines)
gate "$(payload g6 Agent coder)"
check "G6: Agent(<custom implement role>) hits the throw and passes" 'allowed && [ "$(errlines)" = $((BEFORE+1)) ]'
BEFORE=$(errlines)
gate "$(send_payload g6)"
check "G6: a SendMessage brief hits the throw and passes" 'allowed && [ "$(errlines)" = $((BEFORE+1)) ]'
write_cfg '{"version":1,"enabled":false,"roles":{}}'
BEFORE=$(errlines)
gate "$(payload g6 Agent ah:architect)"
check "G6: enabled:false with the same injection: Agent(ah:architect) passes, never reaching the throw" 'allowed && [ "$(errlines)" = "$BEFORE" ]'
rm -f "$HD/msgs"
write_cfg '{"version":1,"enabled":true,"roles":{}}'
BEFORE=$(errlines)
gate_resolve_throws "$(payload g6 Task ah:orchestrator)"
check "G6: a throw inside config resolution: Task(ah:orchestrator) denied with the fail-closed Orchestrator text, and logged" 'orch_fail_closed && [ "$(errlines)" = $((BEFORE+1)) ]'
check "G6: ...the logged throw is the injected one" 'tail -1 "$ERRLOG" | grep -q "injected by tests/fixtures/resolve-config-throws.mjs"'
gate_resolve_throws "$(payload g6 Agent ah:architect)"
check "G6: ...Agent(ah:architect) denied with the fail-closed text" 'fail_closed architect Architect'
gate_resolve_throws "$(payload g6 Agent ah:task-runner)"
check "G6: ...Agent(ah:task-runner) passes" 'allowed'
gate_resolve_throws "$(send_payload g6)"
check "G6: ...a SendMessage brief passes" 'allowed'
gate_resolve_throws "$(payload g6 Read "")"
check "G6: ...a non-dispatch tool passes" 'allowed'
# R4: the input that used to be this injection, a null roster member, is now skipped at read and
# takes the gate's normal path.
write_cfg '{"version":1,"enabled":true,"roster":{"members":[null]}}'
BEFORE=$(errlines)
gate "$(payload g6 Task ah:orchestrator)"
check "R4: members:[null]: Task(ah:orchestrator) gets the normal deny, not the fail-closed text, and nothing is logged" 'denied && echo "$OUT" | grep -q "never runs as a subagent" && ! orch_fail_closed && [ "$(errlines)" = "$BEFORE" ]'
gate "$(payload g6 Agent ah:architect)"
check "R4: ...Agent(ah:architect) gets the normal spawn reason, and nothing is logged" 'spawn_reason architect && ! fail_closed architect Architect && [ "$(errlines)" = "$BEFORE" ]'

# ============================================================ D: the directive, in every golden scenario
GOLD="$PLUGIN/tests/fixtures/0056-i1/golden"
for f in "$GOLD"/directive-*.txt; do
  n=$(basename "$f")
  check "D1 ($n): no opts in, route subagents or prefer-peers" '! grep -qE "opts in|route subagents|prefer-peers" "$f"'
  check "D1 ($n): no chain role renders as an Agent( line" '! grep -qE "^- (Ultra-Advisor|Architect|Reviewer|Implementor)[^—]* — Agent\(" "$f"'
  check "D1 ($n): the legwork Task-Runner line is still an Agent call" 'grep -qE "^- Task-Runner.* — Agent\(" "$f"'
  check "D1 ($n): the Orchestrator line carries the takeover exception" 'head -1 "$f" | grep -qF "except where agent-team '"'"'When a role can'"'"'t take the work'"'"' has you take a role over."'
  check "D1 ($n): the peer-brief contract carries the three-ping rule" 'grep -F "Ping n/3" "$f" | grep -F "notify_when_idle" | grep -F "never ping a busy peer" | grep -qF "leaving its pane running"'
  check "D1 ($n): item 7 carries the escalation-ladder pointer" 'grep "^7\. Ultra-Advisor" "$f" | grep -qF "No Ultra-Advisor reachable → the escalation ladder in agent-team '"'"'When a role can'"'"'t take the work'"'"'."'
done

# ============================================================ K: skills, docs, agents
TEAM_SKILL="$PLUGIN/skills/agent-team/SKILL.md"
SECTION=$(awk '/^## When a role can.t take the work/{f=1} f' "$TEAM_SKILL")
check "K2: agent-team has the section 'When a role can't take the work'" '[ -n "$SECTION" ]'
check "K2: the design/review/implement ladder, a physical launch failure the only takeover trigger" 'echo "$SECTION" | grep -q "Design, review and implement roles" && echo "$SECTION" | grep -q "Only when that launch physically fails, do the work yourself" && echo "$SECTION" | grep -q "the only thing that makes a role unreachable"'
check "K2: the approval table: gate.mjs status, and the rows none, off, session, each" 'echo "$SECTION" | grep -q "gate.mjs status --session" && echo "$SECTION" | grep -q "^| none |" && echo "$SECTION" | grep -q "^| \`off\` |" && echo "$SECTION" | grep -q "^| \`session\` |" && echo "$SECTION" | grep -q "^| \`each\` |"'
check "K2: the gate's first-use options, verbatim" 'echo "$SECTION" | grep -qF "\"Yes, rest of session\" (Escalate now, and allow every later Ultra-Advisor dispatch this session without asking again.)" && echo "$SECTION" | grep -qF "\"Ask me each time\" (Escalate now, but prompt again at every later escalation.)" && echo "$SECTION" | grep -qF "\"No, not this session\" (Do not escalate; block Ultra-Advisor for the rest of this session.)"'
steps_in_order() { # the four escalation steps, numbered 1-4, in that order
  local prev=0 n i=0 t
  for t in "An Ultra-Advisor that can be reached" "Ask the user to spawn one" "The highest-reasoning chain role" "Adjudicate yourself"; do
    i=$((i+1)); n=$(echo "$SECTION" | grep -n "^$i\. \*\*$t" | head -1 | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1; prev=$n
  done
}
check "K2: escalation steps 1-4 in order, with Don't spawn an Ultra-Advisor and the step-3 ranking" 'steps_in_order && echo "$SECTION" | grep -qF "\"Don'"'"'t spawn an Ultra-Advisor\"" && echo "$SECTION" | grep -q "by model" && echo "$SECTION" | grep -q "ranks" && echo "$SECTION" | grep -q "Ties go to a live member first, then design before"'
check "K2: a stalled Ultra-Advisor continues from step 3" 'echo "$SECTION" | grep -q "escalation ladder \*\*from step 3\*\*"'
check "K2: stall = owes a reply and idle; three pings per brief, never reset; response defined; pane left running; late report surfaced" 'echo "$SECTION" | grep -q "owes you a reply" && echo "$SECTION" | grep -q "per brief and never resets" && echo "$SECTION" | grep -q "A response\*\* is any SendMessage" && echo "$SECTION" | grep -q "Leave the stalled pane running" && echo "$SECTION" | grep -q "Surface a late report"'
check "K2: the declined-spawn question" 'echo "$SECTION" | grep -qF "\"Do the <Role> work"'
check "K1: agent-roster init has no Subagent only option" '! grep -q "Subagent only" "$PLUGIN/skills/agent-roster/SKILL.md"'
check "K1: hooks.json no longer describes a route question or the prefer-peers default" '! grep -qE "prefer-peers|asks ONCE per session" "$H/hooks.json"'
check "K1: comms-protocol.md no longer describes a route question or the prefer-peers default" '! grep -qE "Default when the user has not answered|ask ONCE per session|One routing question per session" "$PLUGIN/docs/comms-protocol.md"'
# K1: every budget the size test holds, pinned at its value. Raising one means editing this list
# as well, so it is a deliberate, reviewed change; lowering one needs nothing here.
K1_PINS="AUTO_MAX=14600 CONFIRM_MAX=16500 architect=9700 ultra-advisor=7300 reviewer=6500 implementor=5300 task-runner=5650 orchestrator=7350"
k1_raised() { # <size test file>: each pinned budget it raises or no longer defines
  local f=$1 pin name max got
  for pin in $K1_PINS; do
    name=${pin%%=*}; max=${pin#*=}
    case $name in
      AUTO_MAX|CONFIRM_MAX) got=$(sed -nE "s/^$name=([0-9]+).*/\1/p" "$f") ;;
      *) got=$(sed -nE "s/^md_ceiling $name +([0-9]+).*/\1/p" "$f") ;;
    esac
    { [ -n "$got" ] && [ "$got" -le "$max" ]; } || echo "$name=${got:-missing}"
  done
}
OUT=$(k1_raised "$PLUGIN/tests/test-directive-size.sh")
check "K1: no directive or agents/*.md budget in the size test is raised above its pin" '[ -z "$OUT" ]'
SIZE_COPY="$SANDBOX/size-copy.sh"
for raise in 's/^AUTO_MAX=14600/AUTO_MAX=14601/' 's/^CONFIRM_MAX=16500/CONFIRM_MAX=17000/' 's/^md_ceiling orchestrator  7350/md_ceiling orchestrator  7351/' 's/^md_ceiling task-runner   5650/md_ceiling task-runner   9999/' 's/^md_ceiling architect .*//'; do
  perl -pe "$raise" "$PLUGIN/tests/test-directive-size.sh" > "$SIZE_COPY"
  OUT=$(k1_raised "$SIZE_COPY")
  check "T-H0: K1 fails on a copy of the size test edited with $raise" '! cmp -s "$SIZE_COPY" "$PLUGIN/tests/test-directive-size.sh" && [ -n "$OUT" ]'
done
perl -pe 's/^AUTO_MAX=14600/AUTO_MAX=14000/' "$PLUGIN/tests/test-directive-size.sh" > "$SIZE_COPY"
OUT=$(k1_raised "$SIZE_COPY")
check "T-H0: a lowered budget passes K1" '[ -z "$OUT" ]'
check "K1: commands/hierarchy.md has no plugins/cache/*/task-gopher glob" '! grep -qF "plugins/cache/*/task-gopher" "$PLUGIN/commands/hierarchy.md"'

# ============================================================ M: migrate on write, ignored until then
STALE='{"version":1,"zzUnrelated":{"keep":true},"route":"subagents","roles":{"architect":{"model":"opus","dispatch":"model"},"task-runner":{"model":"haiku","dispatch":"model"}},"roster":{"route":"subagent","members":[{"role":"architect","model":"opus","route":"subagent","onMissing":"never"},{"role":"task-runner","model":"haiku"},{"role":"task-runner","model":"haiku","route":"subagent"},{"role":"implementor","model":"opus","onMissing":"prompt"}]}}'
fresh_home
new_repo m1
write_cfg "$STALE"
GLOBAL_STALE='{"version":1,"route":"prefer-peers","teamLayout":"grid","roles":{"reviewer":{"model":"opus","dispatch":"model"}}}'
printf '%s\n' "$GLOBAL_STALE" > "$GLOBAL"
GSUM=$(sum "$GLOBAL")
run_split add --level repo --role reviewer --model opus
check "M1: add on a stale file succeeds" '[ "$RC" = 0 ]'
check "M1: top-level route, and the chain role's dispatch model, are deleted" '[ "$(jq_file "$CFG" "\"route\" in t")" = false ] && [ "$(jq_file "$CFG" "\"dispatch\" in t.roles.architect")" = false ]'
check "M1: legwork dispatch model is kept" '[ "$(jq_file "$CFG" "t.roles[\"task-runner\"].dispatch")" = model ]'
check "M1: the block route becomes peer" '[ "$(jq_file "$CFG" "t.roster.route")" = peer ]'
check "M1: the chain member's route subagent and onMissing never are deleted" '[ "$(jq_file "$CFG" "JSON.stringify(t.roster.members[0])")" = "{\"role\":\"architect\",\"model\":\"opus\"}" ]'
check "M1: a legwork member that inherited subagent now has its own route subagent" '[ "$(jq_file "$CFG" "t.roster.members[1].route")" = subagent ]'
check "M1: a legwork member's own route subagent is kept" '[ "$(jq_file "$CFG" "t.roster.members[2].route")" = subagent ]'
check "M1: onMissing prompt is deleted" '[ "$(jq_file "$CFG" "\"onMissing\" in t.roster.members[3]")" = false ]'
check "M1: the unrelated key and the key order are preserved" '[ "$(jq_file "$CFG" "Object.keys(t).join()")" = version,zzUnrelated,roles,roster ] && [ "$(jq_file "$CFG" "JSON.stringify(t.zzUnrelated)")" = "{\"keep\":true}" ]'
check "M1: migrated lists each change" '[ "$(jq_out "o.migrated.map(m=>m.key+\":\"+m.from+\">\"+m.to).join(\"|\")")" = "route:subagents>null|roles.architect.dispatch:model>null|roster.route:subagent>peer|roster.members[0].onMissing:never>null|roster.members[0].route:subagent>null|roster.members[1].route:null>subagent|roster.members[3].onMissing:prompt>null" ]'
check "M1: one stderr notice for the file" '[ "$(echo "$STDERR" | grep -c "migrated 7 stale key(s) in $CFG")" = 1 ]'
check "M2: the global file's stale keys are byte-identical" '[ "$(sum "$GLOBAL")" = "$GSUM" ]'
for verb in edit remove role-set init; do
  new_repo "m1-$verb"
  write_cfg "$STALE"
  case "$verb" in
    edit) run_split edit --level repo --member "m1-$verb-implementor" --model sonnet ;;
    remove) run_split remove --level repo --member "m1-$verb-implementor" ;;
    role-set) run_split role set architect --model opus --level repo ;;
    init) run_split init --level repo --route peer ;;
  esac
  check "M1 ($verb): the write succeeds and lists migrated keys" '[ "$RC" = 0 ] && [ "$(jq_out "o.migrated.length")" -ge 2 ]'
  check "M1 ($verb): no stale key survives in the file" '[ "$(jq_file "$CFG" "\"route\" in t")" = false ] && [ "$(jq_file "$CFG" "\"dispatch\" in (t.roles.architect||{})")" = false ] && [ "$(jq_file "$CFG" "t.roster.route")" = peer ] && [ "$(jq_file "$CFG" "t.roster.members.some(m=>m.onMissing===\"never\"||m.onMissing===\"prompt\"||(m.role!==\"task-runner\"&&m.route===\"subagent\"))")" = false ]'
done

new_repo m1b
write_cfg '{"version":1,"teamAlias":"old","teamLayout":"grid","roster":{"route":"peer","layout":"columns","members":[{"role":"architect","model":"opus"}]},"rosters":{"alt":{"route":"peer","layout":"grid","members":[{"role":"reviewer","model":"opus"}]}}}'
run_split add --level repo --role reviewer --model opus
check "M1b: teamAlias, roster.layout, rosters.alt.layout and a non-global teamLayout are deleted and listed" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "[\"teamAlias\" in t,\"teamLayout\" in t,\"layout\" in t.roster,\"layout\" in t.rosters.alt].join()")" = false,false,false,false ] && [ "$(jq_out "o.migrated.map(m=>m.key).sort().join()")" = "roster.layout,rosters.alt.layout,teamAlias,teamLayout" ]'
printf '%s\n' '{"version":1,"teamLayout":"grid","roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}' > "$GLOBAL"
run_split add --level global --role reviewer --model opus --allow-global
check "M1b: the global file's teamLayout survives a write to the global file" '[ "$RC" = 0 ] && [ "$(jq_file "$GLOBAL" "t.teamLayout")" = grid ]'

# M3: reads and hooks leave every config file alone; only the CLI reports
fresh_home
new_repo m3
write_cfg '{"version":1,"enabled":true,"route":"subagents","roles":{"architect":{"model":"opus","dispatch":"model"}},"roster":{"route":"subagent","members":[{"role":"architect","model":"opus","route":"subagent","onMissing":"never"},{"role":"implementor","model":"opus","onMissing":"prompt"}]}}'
printf '%s\n' "$GLOBAL_STALE" > "$GLOBAL"
RSUM=$(sum "$CFG"); GSUM=$(sum "$GLOBAL")
run_roster show;                                   SHOW_RC=$RC
run_roster doctor;                                 DOCTOR_OUT=$OUT
run_roster create --plan;                          PLAN_OUT=$OUT
run_roster role set architect --model opus --dry-run
run_roster spawn-one architect --dry-run
STATUS_OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(C.statusReport('$PROJ'));" 2>&1)
SS_OUT=$(printf '{"session_id":"m3","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" 2>&1)
gate "$(payload m3 Agent ah:architect)"
for hook in pretooluse-msg-gate.mjs pretooluse-ultra-gate.mjs; do payload m3 Agent ah:architect | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/$hook" >/dev/null 2>&1; done
check "M3: show, doctor, create --plan, --dry-run verbs, status and every hook leave both config files byte-identical" '[ "$(sum "$CFG")" = "$RSUM" ] && [ "$(sum "$GLOBAL")" = "$GSUM" ]'
WARN="only legwork roles run as subagents. It is migrated at the next CLI write to that file"
check "M3: status prints the stale-key warnings" '[ "$(echo "$STATUS_OUT" | grep -c "$WARN")" -ge 6 ]'
check "M3: doctor prints them" 'echo "$DOCTOR_OUT" | grep -q "$WARN"'
check "M3: create --plan prints them" 'echo "$PLAN_OUT" | grep -q "$WARN"'
check "M3: the SessionStart context and directive carry none of them" '[ -n "$SS_OUT" ] && ! echo "$SS_OUT" | grep -q "only legwork roles run as subagents" && ! echo "$SS_OUT" | grep -qE "is not a mode|dispatch \\\\\"model\\\\\" is not valid"'

# M4: an architect member with route subagent, before any write
new_repo m4
write_cfg '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus","route":"subagent"}]}}'
run_split create --plan
check "M4: create --plan shows it peer-routed with a spawn shape" '[ "$(jq_out "o.members[0].route")" = peer ] && [ "$(jq_out "Array.isArray(o.members[0].spawn.launch)")" = true ]'
STATUS_OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(C.statusReport('$PROJ'));" 2>&1)
check "M4: status shows the effective peer" 'echo "$STATUS_OUT" | grep "m4-architect" | grep -q "route=peer"'
gate "$(payload m4 Agent ah:architect)"
check "M4: the gate denies its Agent dispatch" 'spawn_reason architect'

# M5: a stale route record in gates.jsonl is inert, never rewritten
new_repo m5
write_cfg '{"version":1,"enabled":true,"roles":{}}'
stale_route S subagents
GATESUM=$(sum "$HD/gates.jsonl")
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" route --session S --cwd "$PROJ" --plain 2>&1); RC=$?
check "M5: msg.mjs route --session S prints peers" 'echo "$OUT" | grep -q "^peers"'
gate "$(payload S Agent ah:architect)"
check "M5: the gate treats S as peers" 'spawn_reason architect'
check "M5: gates.jsonl is byte-identical after those verbs" '[ "$(sum "$HD/gates.jsonl")" = "$GATESUM" ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" route subagents --session S --cwd "$PROJ" 2>&1); RC=$?
check "M5: route subagents --session S exits 2, and appends nothing" '[ "$RC" = 2 ] && [ "$(sum "$HD/gates.jsonl")" = "$GATESUM" ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" route peers --session S --cwd "$PROJ" 2>&1); RC=$?
check "M5: route peers appends" '[ "$RC" = 0 ] && [ "$(tail -1 "$HD/gates.jsonl" | jq_file /dev/stdin "t.value" 2>/dev/null || tail -1 "$HD/gates.jsonl")" != "" ] && tail -1 "$HD/gates.jsonl" | grep -q "\"value\":\"peers\""'

# W: a write that reclassifies a custom role is judged by the class it writes, for the row and its members
new_repo w1
role_set coder implement
write_cfg '{"version":1,"roles":{"coder":{"class":"implement","description":"A implement role."}},"roster":{"route":"peer","members":[{"role":"coder","route":"subagent"},{"role":"architect","model":"opus"}]}}'
run_split role set coder --class legwork --dispatch model --level repo
check "W1: implement -> legwork with --dispatch model succeeds" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "t.roles.coder.class")" = legwork ]'
check "W1: the dispatch model it just wrote is kept" '[ "$(jq_file "$CFG" "t.roles.coder.dispatch")" = model ]'
check "W1: its member keeps route subagent" '[ "$(jq_file "$CFG" "t.roster.members[0].route")" = subagent ]'
check "W1: neither is listed as migrated" '[ "$(jq_out "(o.migrated||[]).filter(m=>m.key===\"roles.coder.dispatch\"||m.key===\"roster.members[0].route\").length")" = 0 ]'
new_repo w2
role_set helper3 legwork
write_cfg '{"version":1,"roles":{"helper3":{"class":"legwork","description":"A legwork role.","dispatch":"model"}},"roster":{"route":"peer","members":[{"role":"helper3","route":"subagent"},{"role":"architect","model":"opus"}]}}'
run_split role set helper3 --class implement --level repo
check "W2: legwork -> implement succeeds" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "t.roles.helper3.class")" = implement ]'
check "W2: the now-stale dispatch model is deleted" '[ "$(jq_file "$CFG" "\"dispatch\" in t.roles.helper3")" = false ]'
check "W2: its member loses route subagent" '[ "$(jq_file "$CFG" "\"route\" in t.roster.members[0]")" = false ]'
check "W2: both are listed as migrated" '[ "$(jq_out "o.migrated.map(m=>m.key+\":\"+m.from+\">\"+m.to).join(\"|\")")" = "roles.helper3.dispatch:model>null|roster.members[0].route:subagent>null" ]'

# ============================================================ V: new writes
fresh_home
new_repo v1
run_roster init --level repo --route subagent
check "V1: init --route subagent exits 2, pointing at legwork members" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents" && echo "$OUT" | grep -q "legwork"'
run_roster init --level repo --route peer
run_roster add --level repo --role architect --route subagent --model opus
check "V1: add --role architect --route subagent exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
run_roster add --level repo --role architect --model opus
run_roster edit --level repo --member v1-architect --route subagent
check "V1: edit of an architect to --route subagent exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
run_roster add --level repo --role task-runner --route subagent --model haiku
check "V1: add --role task-runner --route subagent succeeds" '[ "$RC" = 0 ] && [ "$(jq_file "$CFG" "t.roster.members.at(-1).route")" = subagent ]'
run_roster edit --level repo --member v1-task-runner --role architect
check "V1: edit --role architect on a subagent-routed task-runner row exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
for v in never prompt; do
  run_roster add --level repo --role reviewer --model opus --on-missing "$v"
  check "V1: --on-missing $v exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
done
run_roster role set architect --dispatch model
check "V1: role set architect --dispatch model exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
role_set coder2 implement
run_roster role set coder2 --dispatch model
check "V1: role set <custom implement> --dispatch model exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
role_set helper2 legwork
run_roster role set helper2 --dispatch model
check "V1: role set <custom legwork> --dispatch model succeeds" '[ "$RC" = 0 ]'
run_roster spawn-ad-hoc architect --route subagent --model opus --dry-run
check "V1: spawn-ad-hoc architect --route subagent exits 2" '[ "$RC" = 2 ] && echo "$OUT" | grep -q "only legwork roles run as subagents"'
check "V1: no refusal message cites a spec number" '! grep -rqE "\(spec 0059\)" "$H"'

# ============================================================ T: team files are read, never rewritten
fresh_home
new_repo t1
write_cfg '{"version":1,"enabled":true,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}'
mkdir -p "$PROJ/.claude/hierarchy"
printf '{"version":1,"team_id":"t1","roster_level":"repo","transport":"terminal","orchestrator":{"session_id":null,"pid":%s},"members":[{"role":"architect","name":"t1-architect","route":"subagent","model":"opus","transport_id":null}],"partial":false}\n' "$$" > "$PROJ/.claude/hierarchy/team.json"
TSUM=$(sum "$PROJ/.claude/hierarchy/team.json")
OUT=$(payload t1 Agent ah:architect | HOME="$FAKEHOME" node "$GATE" 2>&1); RC=$?
check "T1: the gate treats the subagent-routed team record as a missing peer" 'spawn_reason architect'
run_split spawn-one architect --dry-run
check "T1: spawn-one architect launches it as a peer" '[ "$RC" = 0 ] && [ "$(jq_out o.dry_run)" = true ] && [[ "$(jq_out "o.launch.join()")" == *"--agent ah:architect"* ]]'
check "T1: the team file is never rewritten" '[ "$(sum "$PROJ/.claude/hierarchy/team.json")" = "$TSUM" ]'

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
