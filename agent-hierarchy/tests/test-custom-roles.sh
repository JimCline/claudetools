#!/bin/bash
# agent-hierarchy — user-defined roles (spec 0056): the I1 baseline, the `role` verbs, spawn,
# identity lookup and every gate, resilience, routing, and injected-text budgets.
# HOME-redirected; real config never touched.
# Usage: bash tests/test-custom-roles.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-custom-roles-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: stubs that fail every call sit first on PATH, and the
# session's pane environment is dropped. The tmux transport case sets its own PATH to a fake.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/repo"
AG="$PROJ/.claude/agents"
CFG="$PROJ/.claude/agent-hierarchy.json"
mkdir -p "$FAKEHOME/.claude" "$AG" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:600} ERR=${ERR:0:300})"; fi
}
R() { OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>"$SANDBOX/err"); RC=$?; ERR=$(cat "$SANDBOX/err"); }
M() { OUT=$(HOME="$FAKEHOME" node "$H/msg.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
hook() { # <hook file> <json payload>
  OUT=$(printf '%s' "$2" | env -u HERDR_ENV -u HERDR_PANE_ID HOME="$FAKEHOME" node "$H/$1" 2>&1); RC=$?
}
js() { OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const L = await import('$H/lib-config.mjs'); $1" 2>&1); RC=$?; }
jfield() { node -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8'));const v=$1;process.stdout.write(typeof v==='string'?v:JSON.stringify(v))"; }
cfg() { printf '%s' "$1" > "$CFG"; }
agentfile() { # <name> <frontmatter lines...>
  local n=$1; shift
  { echo "---"; echo "name: $n"; echo "description: The $n agent. It does things."; printf '%s\n' "$@"; echo "---"; echo "Body."; } > "$AG/$n.md"
}
directive() { js "process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }))"; }

agentfile ui-implementor "disallowedTools: advisor"
agentfile auditor "disallowedTools: Edit, Write, NotebookEdit, advisor"
agentfile ui-architect "disallowedTools: Bash, NotebookEdit, advisor"
agentfile sage "disallowedTools: Edit, NotebookEdit, advisor"
agentfile fetcher
BASE='"ui-implementor":{"class":"implement","routes":"UI work: Control scenes, HUD, menus"},"auditor":{"class":"review","description":"Audits licences."},"ui-architect":{"class":"design"},"sage":{"class":"advise","model":"opus"},"fetcher":{"class":"legwork"}'

# ---- T1 (I1): with no custom rows and no overrides every surface is byte-identical
bash "$PLUGIN/tests/fixtures/0056-i1/render.sh" "$SANDBOX/i1" >/dev/null 2>&1
OUT=$(diff -r "$PLUGIN/tests/fixtures/0056-i1/golden" "$SANDBOX/i1" 2>&1 | head -20)
check "T1: derived views, directives, notices, SubagentStart and spawn plans are byte-identical to the pre-0056 golden files" '[ -z "$OUT" ]'

# ---- T2: role verbs round-trip at every level
cfg '{"version":1,"enabled":true,"handoffs":"auto"}'
for level in repo repo-user global; do
  R role set auditor --class review --description "Audits licences." --level $level
  check "T2: role set writes at $level" '[ $RC -eq 0 ]'
  R role list --json
  check "T2: role list shows auditor from $level" '[ "$(echo "$OUT" | jfield "o.roles.find(r=>r.name===\"auditor\").level")" = "$level" ]'
  R role remove auditor --level $level
  check "T2: role remove deletes it at $level" '[ $RC -eq 0 ]'
done
R role set auditor --class review --description "Audits licences." --level repo
R role set auditor --model sonnet --level repo
check "T2: seeding from the row keeps class, description and unrelated keys" 'node -e "const c=JSON.parse(require(\"fs\").readFileSync(\"$CFG\",\"utf8\"));const a=c.roles.auditor;process.exit(a.class===\"review\"&&a.description===\"Audits licences.\"&&a.model===\"sonnet\"&&c.handoffs===\"auto\"?0:1)"'
mkdir -p "$(dirname "$(HOME="$FAKEHOME" node -e "import('$H/lib-config.mjs').then(L=>process.stdout.write(L.rosterLevelPaths('$PROJ')['repo-user']))")")"
RU=$(HOME="$FAKEHOME" node -e "import('$H/lib-config.mjs').then(L=>process.stdout.write(L.rosterLevelPaths('$PROJ')['repo-user']))")
echo '{"version":1,"roles":{"auditor":{"model":"opus"}}}' > "$RU"
R role list --json
check "T2: a partial hand-edited row at a more specific level is excluded, not merged" '[[ "$OUT" == *"\"excluded\""*"auditor"*"class is required"* ]]'
rm -f "$RU"
R role set ui-implementor --class implement --routes "UI work" --level repo
R role set ui-implementor --routes "" --level repo
R role list --json
check "T2: --routes \"\" demotes an alternative to a side role" '[ "$(echo "$OUT" | jfield "o.roles.find(r=>r.name===\"ui-implementor\").placement")" = "side" ]'

# ---- T3: row refusals
cfg '{"version":1}'
R role set architect --class design;               check "T3: --class on a built-in is refused" '[ $RC -ne 0 ]'
R role set reviewer --routes "x";                  check "T3: --routes on a built-in is refused" '[ $RC -ne 0 ]'
R role set orchestrator --class design;            check "T3: reserved name orchestrator is refused" '[ $RC -ne 0 ]'
R role set advisor --class design;                 check "T3: reserved name advisor is refused" '[ $RC -ne 0 ]'
R role set foo-2 --class design;                   check "T3: a name ending in -<digits> is refused" '[ $RC -ne 0 ]'
R role set bad --class design --agent 'x;rm';      check "T3: agent with ; is refused" '[ $RC -ne 0 ]'
R role set bad --class design --agent 'a b';       check "T3: agent with a space is refused" '[ $RC -ne 0 ]'
R role set bad --class design --agent '$(id)';     check "T3: agent with \$( is refused" '[ $RC -ne 0 ]'
R role set bad --class design --agent 'ah:x';      check "T3: ah:* on a custom row is refused" '[ $RC -ne 0 ]'
R role set sage --class advise;                    check "T3: advise with no model is refused" '[ $RC -ne 0 ]'
R role set sage --class advise --model inherit;    check "T3: advise with inherit is refused" '[ $RC -ne 0 ]'
R role set auditor --class review --model haiku;   check "T3: haiku on a non-legwork role is refused" '[ $RC -ne 0 ]'
R role set fetcher --class legwork --routes "x" --level repo
check "T3: legwork routes warns and is not written" '[ $RC -eq 0 ] && [[ "$ERR" == *"routes"* ]] && ! grep -q "\"routes\"" "$CFG"'
R role set ui-implementor --class implement --scaffold repo --description "UI."
check "T3: --scaffold over an existing file is refused" '[ $RC -ne 0 ]'
R role set plugrole --class implement --agent "someplug:agent" --scaffold repo --description "P."
check "T3: --scaffold onto a plugin ref is refused" '[ $RC -ne 0 ]'
cfg '{"version":1,"roles":{'"$BASE"'},"roster":{"route":"peer","members":[{"role":"auditor"}]}}'
R role remove auditor --level repo
check "T3: remove is refused while a roster member uses the role, naming it" '[ $RC -ne 0 ] && [[ "$ERR$OUT" == *"auditor"* ]]'

# ---- T3b: --dry-run writes nothing
cfg '{"version":1}'
BEFORE=$(cat "$CFG")
R role set newrole --class implement --description "New." --scaffold repo --dry-run
check "T3b: --dry-run --scaffold writes neither the row nor the file" '[ $RC -eq 0 ] && [ "$(cat "$CFG")" = "$BEFORE" ] && [ ! -e "$AG/newrole.md" ]'

# ---- T5: spawn shape for a custom member, every transport
cfg '{"version":1,"roles":{'"$BASE"'},"roster":{"route":"peer","members":[{"role":"ui-implementor"},{"role":"ui-implementor","model":"opus"}]}}'
for tr in herdr tmux terminal; do
  case $tr in
    herdr) OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1) ;;
    tmux) OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1) ;;
    terminal) OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1) ;;
  esac
  check "T5 ($tr): custom member spawns --agent ui-implementor with no --model" '[[ "$OUT" == *"--agent ui-implementor --name repo-ui-implementor"* ]] && ! [[ "$OUT" =~ --name\ repo-ui-implementor\ --model ]]'
  check "T5 ($tr): --model opus reaches the second member" '[[ "$OUT" == *"--name repo-ui-implementor-2 --model opus"* ]]'
done

# ---- T6: SessionStart for a custom role session
hook sessionstart.mjs '{"session_id":"t6","cwd":"'$PROJ'","agent_type":"ui-implementor","hook_event_name":"SessionStart","source":"startup"}'
CTX=$(echo "$OUT" | jfield "o.hookSpecificOutput.additionalContext")
check "T6: the role-session notice carries the contract and the alternative clause" '[[ "$CTX" == *"HIERARCHY CONTRACT"* && "$CTX" == *"alternative to Implementor for: UI work"* && "$CTX" != *"Agent hierarchy ACTIVE"* ]]'
check "T6: peers.jsonl records the custom role" 'grep -q "\"role\":\"ui-implementor\"" "$PROJ/.claude/hierarchy/peers.jsonl"'
hook sessionstart.mjs '{"session_id":"t6b","cwd":"'$PROJ'","agent_type":"my-auditor-unregistered","hook_event_name":"SessionStart","source":"startup"}'
check "T6: an unregistered agent type gets the Orchestrator directive" '[[ "$OUT" == *"Agent hierarchy ACTIVE"* ]]'

# ---- T7: route gate
PRE() { printf '{"session_id":"%s","cwd":"%s","tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"x"},"hook_event_name":"PreToolUse"%s}' "$1" "$PROJ" "$2" "$3"; }
hook pretooluse-route-gate.mjs "$(PRE orch1 ui-implementor)"
check "T7: an Orchestrator dispatch to a custom chain role is walled, with spawn-ad-hoc or spawn-one in the deny" '[[ "$OUT" == *"deny"* && "$OUT" == *"spawn-"*"ui-implementor"* ]]'
hook pretooluse-route-gate.mjs "$(PRE orch1 fetcher)"
check "T7: custom legwork passes the route gate" '[[ "$OUT" != *"deny"* ]]'
hook pretooluse-route-gate.mjs "$(PRE sub1 auditor ',"agent_id":"a1","agent_type":"ui-implementor"')"
check "T7: a role subagent dispatching a custom chain role is walled with route-back" '[[ "$OUT" == *"deny"* && "$OUT" == *"NEEDS-AUDITOR"* ]]'
hook pretooluse-route-gate.mjs "$(PRE sub1 fetcher ',"agent_id":"a1","agent_type":"ui-implementor"')"
check "T7: a role subagent dispatching custom legwork is allowed" '[[ "$OUT" != *"deny"* ]]'

# ---- T8: message gates
cfg '{"version":1,"roles":{'"$BASE"'}}'
hook pretooluse-msg-gate.mjs "$(PRE orch2 ui-implementor)"
check "T8: a custom chain dispatch without a message file is blocked" '[[ "$OUT" == *"deny"* && "$OUT" == *"--to ui-implementor"* ]]'
M new --to ui-implementor --from orchestrator --slug t8
check "T8: msg.mjs new --to ui-implementor works" '[ $RC -eq 0 ]'
M new --to nope --from orchestrator --slug t8
check "T8: --to nope fails and lists the custom roles" '[ $RC -ne 0 ] && [[ "$OUT" == *"ui-implementor"* && "$OUT" == *"auditor"* ]]'
REQ=$(ls "$PROJ/.claude/hierarchy/msgs/"*--ui-implementor--t8--request.md | head -1)
js "
  const P = await import('$H/lib-peer.mjs');
  P.appendPeerRecord({ session_id: 't8s', task: 't8', from: 'orchestrator', status: 'pending', msg: '$REQ', armed_by: 'msg-token', ts: new Date().toISOString() });
"
hook pretooluse-sendmessage-response.mjs '{"session_id":"t8s","cwd":"'$PROJ'","agent_type":"ui-implementor","tool_name":"SendMessage","tool_input":{"to":"x","message":"done"},"hook_event_name":"PreToolUse"}'
check "T8: the response-file gate applies to a ui-implementor session (end to end)" '[[ "$OUT" == *"deny"* ]]'
hook pretooluse-sendmessage-response.mjs '{"session_id":"t8s","cwd":"'$PROJ'","agent_type":"auditor","tool_name":"SendMessage","tool_input":{"to":"x","message":"done"},"hook_event_name":"PreToolUse"}'
check "T8: ... and not to a review-class session, which owes no response file" '[[ "$OUT" != *"deny"* ]]'

# ---- T9: other gates
cfg '{"version":1,"roles":{'"$BASE"'}}'
js "process.stdout.write([L.classProp('ui-architect', L.resolveConfig('$PROJ'), 'tier'), L.classProp('auditor', L.resolveConfig('$PROJ'), 'tier')].join(' '))"
check "T9: the tier rule applies to a custom design role and not a custom review role" '[ "$OUT" = "true false" ]'
rm -f "$FAKEHOME/.claude/agent-hierarchy.gate.json"
hook pretooluse-ultra-gate.mjs "$(PRE ug1 sage)"
check "T9: the Ultra gate fires for a custom advise role" '[[ "$OUT" == *"deny"* ]]'
hook pretooluse-ultra-gate.mjs "$(PRE ug2 x:ultra-advisor)"
check "T9: the Ultra gate fires for x:ultra-advisor" '[[ "$OUT" == *"deny"* ]]'
hook pretooluse-conduit-gate.mjs '{"session_id":"c1","cwd":"'$PROJ'","agent_type":"auditor","tool_name":"AskUserQuestion","tool_input":{},"hook_event_name":"PreToolUse"}'
check "T9: the conduit gate blocks a custom role session" '[[ "$OUT" == *"deny"* && "$OUT" == *"Auditor does not talk to the user"* ]]'

# ---- T10: name parsing and alias collisions
cfg '{"version":1,"roles":{"security-reviewer":{"class":"review","description":"Sec."}}}'
agentfile security-reviewer "disallowedTools: Edit, Write, NotebookEdit, advisor"
js "const r = L.resolveConfig('$PROJ'); process.stdout.write([L.roleFromName('repo-security-reviewer-2', r), L.roleFromName('repo-reviewer', r), L.roleFromName('repo-security-reviewer')].join(' '))"
check "T10: custom names parse first, longest first; without the registry the built-in token wins" '[ "$OUT" = "security-reviewer reviewer reviewer" ]'
cfg '{"version":1,"teamAlias":"team-ui"}'
agentfile ui-reviewer "disallowedTools: Edit, Write, NotebookEdit, advisor"
js "process.stdout.write(JSON.stringify([L.validateTeamAlias('team-ui', { roles: { 'ui-reviewer': { class: 'review' } } }), L.validateTeamAlias('ui', { roles: { 'ui-reviewer': { class: 'review' } } })]))"
check "T10: alias team-ui collides with custom role ui-reviewer (the Reviewer's peer name team-ui-reviewer would parse as it); alias ui does not" '[[ "$OUT" == *"[{\"ok\":false"*"{\"ok\":true}]"* ]]'
R role set ui-reviewer --class review --description "UI review." --level repo
check "T10: role set refuses the colliding role" '[ $RC -ne 0 ] && [[ "$ERR" == *"collides"* ]]'

# ---- T11 (I3): a live member whose role row is deleted is still torn down
cfg '{"version":1,"roles":{'"$BASE"'}}'
DIR="$PROJ/.claude/hierarchy"
mkdir -p "$DIR"
cat > "$DIR/team.json" <<EOF
{"version":1,"team_id":"t11","transport":"herdr","created":"2026-01-01T00:00:00Z","roster_level":"repo","orchestrator":{"pid":null,"session_id":null},"members":[{"role":"auditor","name":"repo-auditor","route":"peer","model":"opus","transport_id":"P9","checked_in":"2026-01-01T00:00:00Z"}],"partial":false}
EOF
cfg '{"version":1}'
hook sessionstart.mjs '{"session_id":"t11","cwd":"'$PROJ'","hook_event_name":"SessionStart","source":"startup"}'
check "T11: SessionStart does not throw with an orphaned member" '[ $RC -eq 0 ]'
# SessionStart's stale-team sweep removes a team whose orchestrator is gone; seed it again.
cat > "$DIR/team.json" <<EOF
{"version":1,"team_id":"t11","transport":"herdr","created":"2026-01-01T00:00:00Z","roster_level":"repo","orchestrator":{"pid":null,"session_id":null},"members":[{"role":"auditor","name":"repo-auditor","route":"peer","model":"opus","transport_id":"P9","checked_in":"2026-01-01T00:00:00Z"}],"partial":false}
EOF
R doctor
check "T11: doctor warns about the member whose role is no longer defined" '[[ "$OUT" == *"repo-auditor"* && "$OUT" == *"not defined"* ]]'
R dismiss repo-auditor --plan
check "T11: dismiss still plans to close the orphaned member" '[ $RC -eq 0 ] && [[ "$OUT" == *"repo-auditor"* ]]'
R disband --plan
check "T11: disband still plans to close the orphaned member" '[ $RC -eq 0 ] && [[ "$OUT" == *"repo-auditor"* ]]'
rm -f "$DIR/team.json"

# ---- T12 (I6): garbage never throws
cfg '{"version":1,"roles":{"x":"string","y":[1],"Bad Name":{"class":"design"},"z":{"class":"nope"},"w":{"class":"design","label":"bad`label"}}}'
directive
check "T12: garbage rows produce warnings and the directive still builds" '[ $RC -eq 0 ] && [[ "$OUT" == *"custom role \"x\""* && "$OUT" == *"Agent hierarchy ACTIVE"* ]]'
cfg '{"version":1,"roles":{'"$BASE"'}}'
chmod 000 "$AG/auditor.md"
directive
check "T12: an unreadable agent file makes that role unavailable, without throwing" '[ $RC -eq 0 ] && [[ "$OUT" == *"Unavailable user-defined roles"*"auditor"* ]]'
chmod 644 "$AG/auditor.md"
cp -R "$PLUGIN" "$SANDBOX/plugcopy" && rm -f "$SANDBOX/plugcopy/contracts/implement.md"
OUT=$(printf '%s' '{"session_id":"s","cwd":"'$PROJ'","agent_type":"ui-implementor","agent_id":"a1","hook_event_name":"SubagentStart"}' | HOME="$FAKEHOME" node "$SANDBOX/plugcopy/hooks/subagentstart-cli-root.mjs" 2>&1); RC=$?
check "T12: a missing contract file injects nothing extra and does not throw" '[ $RC -eq 0 ] && [[ "$OUT" != *"HIERARCHY CONTRACT"* && "$OUT" == *"ah CLI root"* ]]'
check "T12: the missing contract file is logged" 'grep -q "contracts" "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"'

# ---- T13 (D1): overriding a built-in's agent
agentfile my-architect "disallowedTools: Bash, NotebookEdit, advisor"
cfg '{"version":1,"roles":{"architect":{"model":"opus","agent":"my-architect"}},"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}'
R spawn-one architect --dry-run
check "T13: spawn uses the override agent" '[[ "$OUT" == *"--agent my-architect --name repo-architect"* ]]'
js "const r = L.resolveConfig('$PROJ'); process.stdout.write([L.hierarchyRoleOf('my-architect', { resolved: r }), L.hierarchyRoleOf('ah:architect', { resolved: r })].join(' '))"
check "T13: my-architect and ah:architect both resolve to Architect" '[ "$OUT" = "architect architect" ]'
directive
check "T13: the Architect line keeps its label and prose" '[[ "$OUT" == *"- Architect — SendMessage"* ]]'
hook subagentstart-cli-root.mjs '{"session_id":"s","cwd":"'$PROJ'","agent_type":"my-architect","agent_id":"a1","hook_event_name":"SubagentStart"}'
check "T13: the override's subagent gets the injected contract" '[[ "$OUT" == *"HIERARCHY CONTRACT"* && "$OUT" == *"You are Architect, an agent-hierarchy role of class design"* ]]'
agentfile my-architect "disallowedTools: Edit, NotebookEdit, advisor"
R role set architect --agent my-architect --dry-run
check "T13: an override with Bash but no Edit is fine for design (warnings only)" '[ $RC -eq 0 ]'
agentfile my-architect "tools: Read, SendMessage, Edit"
R role set architect --agent my-architect
check "T13: an override lacking Write is refused" '[ $RC -ne 0 ] && [[ "$ERR" == *"missing-tool:Write"* ]]'

# ---- T14 (C2): description forms
DESC() { printf -- '---\nname: %s\n%s\n---\nBody.\n' "$1" "$2" > "$AG/$1.md"; js "process.stdout.write(String(L.validateAgentContract({ role: '$1', cls: 'legwork', agent: '$1', cwd: '$PROJ' }).description.text))"; }
DESC d1 'description: Plain words here.';                   check "T14: plain description" '[ "$OUT" = "Plain words here." ]'
DESC d2 'description: "Quoted.\nSecond line."';           check "T14: quoted with \\n" '[ "$OUT" = "Quoted." ]'
DESC d3 "$(printf 'description: |\n  Block one.\n  Block two.')"; check "T14: | block" '[ "$OUT" = "Block one." ]'
DESC d4 'description: Use it when X. <example>ignored</example> tail'; check "T14: <example>-laden" '[ "$OUT" = "Use it when X." ]'
DESC d7 "$(printf 'description:\n  Folded plain. Across lines.')"; check "T14: a multi-line plain description is folded" '[ "$OUT" = "Folded plain." ]'
DESC d8 'description: [bracketed] words.'; check "T14: a description starting with [ is text" '[ "$OUT" = "[bracketed] words." ]'
js "process.stdout.write(L.validateAgentContract({ role: 'd7', cls: 'legwork', agent: 'd7', cwd: '$PROJ' }).findings.map((f) => f.code).join(' '))"
check "T14: a description never produces unparseable-field" '[[ "$OUT" != *"unparseable-field"* ]]'
js "process.stdout.write(String(L.validateAgentContract({ role: 'none', cls: 'legwork', agent: 'none-here', cwd: '$PROJ' }).description.text))"
check "T14: a missing file has no description" '[ "$OUT" = "null" ]'
printf 'no frontmatter\n' > "$AG/d5.md"
js "process.stdout.write(String(L.validateAgentContract({ role: 'd5', cls: 'legwork', agent: 'd5', cwd: '$PROJ' }).description.text))"
check "T14: a file with no frontmatter has no description" '[ "$OUT" = "null" ]'
{ printf -- '---\nname: d6\ndescription: Big file.\n---\n'; head -c 40000 /dev/zero | tr '\0' 'x'; } > "$AG/d6.md"
js "process.stdout.write(String(L.validateAgentContract({ role: 'd6', cls: 'legwork', agent: 'd6', cwd: '$PROJ' }).description.text))"
check "T14: a 40 KB file is read (bounded) without trouble" '[ "$OUT" = "Big file." ]'
mkdir -p "$SANDBOX/plug/agents" "$FAKEHOME/.claude/plugins"
printf -- '---\nname: pa\ndescription: From a plugin.\n---\nB.\n' > "$SANDBOX/plug/agents/pa.md"
echo "{\"version\":2,\"plugins\":{\"pl@mk\":[{\"installPath\":\"$SANDBOX/plug\"}]}}" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
js "process.stdout.write(String(L.validateAgentContract({ role: 'p', cls: 'legwork', agent: 'pl:pa', cwd: '$PROJ' }).description.text))"
check "T14: a plugin ref resolves through a sandboxed installed_plugins.json" '[ "$OUT" = "From a plugin." ]'

# ---- T15: routing
cfg '{"version":1,"roles":{'"$BASE"'}}'
directive
ITEM=$(echo "$OUT" | sed -n '/^15\. ROUTING/,$p' | sed '/^ah: /,$d')
check "T15: the routing item has its header, step line, header precedence, ownership and gate parity" '[[ "$ITEM" == *"15. ROUTING"* && "$ITEM" == *"· Implement: Ui-Implementor for \"UI work: Control scenes, HUD, menus\"; otherwise Implementor."* && "$ITEM" == *"Implementer:"*"Reviewer:"* && "$ITEM" == *"impl-defect → the implementing role, spec-defect → the designing role"* && "$ITEM" == *"as for the built-in"* ]]'
GOLD="$PLUGIN/tests/fixtures/0056-i1/golden/directive-auto.txt"
for n in 0 6; do
  L6=$(echo "$OUT" | grep "^$n\. ")
  check "T15: item $n is byte-identical to the baseline" '[ "$L6" = "$(grep "^$n\. " "$GOLD" | sed "s#<PLUGIN>#$PLUGIN#g")" ]'
done
hook sessionstart.mjs '{"session_id":"t15","cwd":"'$PROJ'","agent_type":"ah:architect","hook_event_name":"SessionStart","source":"startup"}'
check "T15: the design routing block reaches the built-in Architect's notice" '[[ "$OUT" == *"ROUTING — when you write a spec"* && "$OUT" == *"ui-implementor"* ]]'
hook subagentstart-cli-root.mjs '{"session_id":"s","cwd":"'$PROJ'","agent_type":"ah:architect","agent_id":"a1","hook_event_name":"SubagentStart"}'
check "T15: ... and the Architect's SubagentStart" '[[ "$OUT" == *"ROUTING — when you write a spec"* && "$OUT" != *"HIERARCHY CONTRACT"* ]]'
hook subagentstart-cli-root.mjs '{"session_id":"s","cwd":"'$PROJ'","agent_type":"task-gopher:task-gopher","agent_id":"a1","hook_event_name":"SubagentStart"}'
check "T15: a task-gopher SubagentStart is still exactly one line" '[ "$(echo "$OUT" | jfield "o.hookSpecificOutput.additionalContext" | wc -l | tr -d " ")" = 0 ]'
cfg '{"version":1,"roles":{"ui-implementor":{"class":"implement"},"auditor":{"class":"review","description":"A."}}}'
directive
check "T15: removing routes removes the routing item" '[[ "$OUT" != *"ROUTING"* ]]'
hook sessionstart.mjs '{"session_id":"t15b","cwd":"'$PROJ'","agent_type":"ah:architect","hook_event_name":"SessionStart","source":"startup"}'
check "T15: ... and the Architect's routing block" '[[ "$OUT" != *"ROUTING"* ]]'

# ---- T16: budgets
cfg '{"version":1,"roles":{'"$BASE"'}}'
directive
MAXLINE=$(echo "$OUT" | grep '\[custom · ' | awk '{ print length($0) }' | sort -n | tail -1)
check "T16: every custom role line ≤ 600 B" '[ "$MAXLINE" -le 600 ]'
IB=$(echo "$OUT" | sed -n '/^15\. ROUTING/,$p' | sed '/^ah: /,$d' | wc -c | tr -d ' ')
check "T16: routing item ≤ 260 + 220·1 B (got $IB)" '[ "$IB" -le 480 ]'
js "
  const r = L.resolveConfig('$PROJ');
  const sizes = ['ui-implementor','auditor','ui-architect','sage'].map((n) => Buffer.byteLength(L.contractBlock(n, r) || ''));
  const block = Buffer.byteLength(L.designRoutingBlock(r) || '');
  process.stdout.write(JSON.stringify({ max: Math.max(...sizes), block }));
"
check "T16: injected contract ≤ 1350 B and routing block ≤ 200 + 200·1 B" 'node -e "const o=$OUT;process.exit(o.max<=1350&&o.max>0&&o.block<=400?0:1)"'
agentfile auditor "tools: Read, SendMessage, Edit"
directive
UL=$(echo "$OUT" | grep '^Unavailable user-defined roles' | sed 's/: auditor\.$//' | wc -c | tr -d ' ')
check "T16: the unavailable line ≤ 120 B + names" '[ "$UL" -le 121 ]'
agentfile auditor "disallowedTools: Edit, Write, NotebookEdit, advisor"
for f in common:900 design:450 implement:450 review:450 advise:450; do
  n=$(wc -c < "$PLUGIN/contracts/${f%%:*}.md" | tr -d ' ')
  check "T16: contracts/${f%%:*}.md ≤ ${f##*:} B (got $n)" '[ "$n" -le "${f##*:}" ]'
done
directive
TT=$(echo "$OUT" | grep -o ', and custom: [^.]*' | head -1)
TL=${TT#*custom: }
check "T16: the tier-prose custom suffix is ≤ 40 B + labels" '[ -n "$TT" ] && [ $(( ${#TT} - ${#TL} )) -le 40 ]'
check "T16: the default config stays within AUTO_MAX/CONFIRM_MAX" 'bash "$PLUGIN/tests/test-directive-size.sh" >/dev/null 2>&1'

# ---- T17 (I4): foreign agents are unchanged at every gate
cfg '{"version":1,"roles":{'"$BASE"'}}'
for t in foo:bar task-gopher:task-gopher; do
  for g in pretooluse-route-gate.mjs pretooluse-msg-gate.mjs pretooluse-ultra-gate.mjs; do
    hook $g "$(PRE t17 $t)"
    check "T17: $t passes $g" '[[ "$OUT" != *"deny"* && "$OUT" != *"\"ask\""* ]]'
  done
  hook pretooluse-conduit-gate.mjs '{"session_id":"c17","cwd":"'$PROJ'","agent_type":"'$t'","agent_id":"a1","tool_name":"AskUserQuestion","tool_input":{},"hook_event_name":"PreToolUse"}'
  check "T17: $t is not blocked by the conduit gate" '[[ "$OUT" != *"deny"* ]]'
  hook subagentstart-cli-root.mjs '{"session_id":"s","cwd":"'$PROJ'","agent_type":"'$t'","agent_id":"a1","hook_event_name":"SubagentStart"}'
  check "T17: $t SubagentStart is the one CLI-root line" '[[ "$OUT" != *"HIERARCHY CONTRACT"* && "$OUT" != *"ROUTING"* ]]'
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
