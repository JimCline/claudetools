#!/bin/bash
# agent-hierarchy — the class-contract validator for custom roles and built-in overrides
# (spec 0056 §1.16): tool contract, file-level checks, findings and their fixes, and every point
# that enforces it (role set, spawn, SessionStart, role list).
# HOME-redirected; real config never touched.
# Usage: bash tests/test-role-contract.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-role-contract-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/repo"
AG="$PROJ/.claude/agents"
UAG="$FAKEHOME/.claude/agents"
mkdir -p "$FAKEHOME/.claude/plugins" "$AG" "$UAG" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:600})"; fi
}

# agent <file> <name|-> <frontmatter lines...>: writes a repo-level agent file; "-" omits name:.
agent() {
  local f=$1 n=$2; shift 2
  { echo "---"; [ "$n" != "-" ] && echo "name: $n"; echo "description: Probe agent $n."; printf '%s\n' "$@"; echo "---"; echo "Body."; } > "$AG/$f.md"
}

# codes <class> <agent> [rowModel]: the validator's finding codes for that agent, sorted, one line.
codes() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$H/lib-config.mjs');
    const r = L.validateAgentContract({ role: 'probe', cls: '$1', agent: '$2', cwd: '$PROJ' });
    process.stdout.write(r.findings.map((f) => f.code).sort().join(' '));
  " 2>&1)
}

roles_json() { printf '%s' "$1" > "$PROJ/.claude/agent-hierarchy.json"; }
R() { OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>"$SANDBOX/err"); RC=$?; ERR=$(cat "$SANDBOX/err"); }

# ---- C1: a passing fixture per class — the scaffold's own shapes
agent adv adv "disallowedTools: Edit, NotebookEdit, advisor"
agent des des "disallowedTools: Bash, NotebookEdit, advisor"
agent rev rev "disallowedTools: Edit, Write, NotebookEdit, advisor"
agent coder coder "disallowedTools: advisor"
agent leg leg
for pair in advise:adv design:des review:rev implement:coder legwork:leg; do
  codes "${pair%%:*}" "${pair##*:}"
  check "C1: ${pair%%:*} fixture passes with zero findings" '[ -z "$OUT" ]'
done

# ---- C2: every missing required tool, per class; both halves of implement's pairs
agent noread noread "tools: SendMessage, Write, Edit, Bash"
agent nowrite nowrite "tools: Read, SendMessage"
agent impnoedit impnoedit "tools: Read, SendMessage, Bash"
agent impnowb impnowb "tools: Read, SendMessage, Edit"
codes advise noread;  check "C2: advise without Read → missing-tool:Read" '[[ "$OUT" == *"missing-tool:Read"* ]]'
codes design noread;  check "C2: design without Read → missing-tool:Read" '[[ "$OUT" == *"missing-tool:Read"* ]]'
codes review noread;  check "C2: review without Read → missing-tool:Read" '[[ "$OUT" == *"missing-tool:Read"* ]]'
codes implement noread; check "C2: implement without Read → missing-tool:Read" '[[ "$OUT" == *"missing-tool:Read"* ]]'
codes design nowrite; check "C2: design without Write → missing-tool:Write" '[[ "$OUT" == *"missing-tool:Write"* ]]'
codes implement impnoedit; check "C2: implement with neither Edit nor Write → missing-tool:Edit|Write" '[[ "$OUT" == *"missing-tool:Edit|Write"* ]]'
codes implement impnowb; check "C2: implement with neither Write nor Bash → missing-tool:Write|Bash" '[[ "$OUT" == *"missing-tool:Write|Bash"* ]]'

# ---- C3/C4: review may not edit; an allowlist without SendMessage loses it
agent revedit revedit "disallowedTools: Write, NotebookEdit, advisor"
agent revwrite revwrite "disallowedTools: Edit, NotebookEdit, advisor"
codes review revedit;  check "C3: review with Edit → forbidden-tool:Edit" '[[ "$OUT" == *"forbidden-tool:Edit"* ]]'
codes review revwrite; check "C3: review with Write → forbidden-tool:Write" '[[ "$OUT" == *"forbidden-tool:Write"* ]]'
agent nosm nosm "tools: Read, Write, Edit, Bash"
codes implement nosm; check "C4: allowlist without SendMessage → missing-tool:SendMessage" '[[ "$OUT" == *"missing-tool:SendMessage"* ]]'
codes implement coder;  check "C4: tools absent → no missing-tool error" '[[ "$OUT" != *"missing-tool"* ]]'

# ---- C5: file-level checks
agent misnamed othername "disallowedTools: advisor"
agent haikurev haikurev "model: haiku" "disallowedTools: Edit, Write, NotebookEdit, advisor"
printf 'just a body, no frontmatter\n' > "$AG/nofm.md"
agent weird weird "tools: {weird}"
codes implement misnamed; check "C5: name-mismatch" '[[ "$OUT" == *"name-mismatch"* ]]'
codes review haikurev;    check "C5: model-not-allowed for haiku on review" '[[ "$OUT" == *"model-not-allowed"* ]]'
codes implement nofm;     check "C5: no-frontmatter" '[ "$OUT" = "no-frontmatter" ]'
codes implement weird;    check "C5: unparseable-field for tools: {weird}" '[[ "$OUT" == *"unparseable-field"* ]]'

# ---- C6: list syntaxes, scoped entries, MCP names
agent comma comma "tools: Read, SendMessage, Write, Edit, Bash"
agent flow flow "tools: [Read, SendMessage, Write, Edit, Bash]"
agent block block "tools:" "  - Read" "  - SendMessage" "  - Write" "  - Edit" "  - Bash"
for a in comma flow block; do codes implement $a; check "C6: $a tools list parses and passes" '[ -z "$OUT" ]'; done
agent scopedbash scopedbash "tools: Read, SendMessage, Write, Bash(git:*), mcp__x__y"
codes design scopedbash; check "C6: Bash(git:*) counts as Bash (discouraged on design) and mcp__x__y is ignored" '[[ "$OUT" == *"discouraged-tool:Bash"* && "$OUT" != *"mcp__"* ]]'

# ---- C7: unresolvable files
codes implement ghost; check "C7: agent-not-found for a bare ref" '[ "$OUT" = "agent-not-found" ]'
echo '{"version":2,"plugins":{"other@x":[{"installPath":"/nowhere"}]}}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
codes implement "nopl:agent"; check "C7: plugin-unresolvable for a plugin with no install record" '[ "$OUT" = "plugin-unresolvable" ]'
mkdir -p "$SANDBOX/plug/agents"
printf -- '---\nname: pagent\ndescription: Plugin agent.\ndisallowedTools: advisor\n---\nBody.\n' > "$SANDBOX/plug/agents/pagent.md"
echo "{\"version\":2,\"plugins\":{\"myplug@mk\":[{\"installPath\":\"$SANDBOX/plug\"}]}}" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
codes implement "myplug:pagent"; check "C7: a plugin ref resolves through installed_plugins.json" '[ -z "$OUT" ]'

# ---- C8: every finding carries a fix; --json is valid; plain prints fix: lines
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const all = ['noread','nowrite','revedit','misnamed','haikurev','nofm','weird','scopedbash','ghost','nopl:agent'].flatMap((a) =>
    ['design','review','implement'].flatMap((c) => L.validateAgentContract({ role: 'p', cls: c, agent: a, cwd: '$PROJ' }).findings));
  process.stdout.write(String(all.length > 0 && all.every((f) => Array.isArray(f.fix) && f.fix.length > 0 && f.fix.every((x) => x.kind && x.detail))));
" 2>&1)
check "C8: every finding has a non-empty fix list" '[ "$OUT" = "true" ]'
roles_json '{"version":1,"roles":{"coder":{"class":"implement","description":"Imp."}}}'
R role set coder --class implement --dry-run
check "C8: role set --dry-run output is valid JSON" 'echo "$OUT" | node -e "JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"))"'
R role set revedit --class review --description "R." --dry-run
check "C8: plain findings print their fix: lines" '[[ "$ERR" == *"ERROR forbidden-tool:Edit"* && "$ERR" == *"  fix: "* ]]'

# ---- C9: role set refuses on errors, writes on warnings; the scaffold passes for every class
roles_json '{"version":1}'
R role set revedit --class review --description "R." --level repo
check "C9: role set refuses an agent that fails its contract" '[ $RC -ne 0 ] && ! grep -q revedit "$PROJ/.claude/agent-hierarchy.json"'
R role set scopedbash --class design --description "D." --level repo
check "C9: role set writes despite warnings" '[ $RC -eq 0 ] && grep -q scopedbash "$PROJ/.claude/agent-hierarchy.json"'
for cls in advise design review implement legwork; do
  model=""; [ $cls = advise ] && model="--model opus"
  R role set "sc-$cls" --class $cls --description "Scaffolded $cls." $model --scaffold repo --level repo
  n=$(echo "$OUT" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(o.findings.length))}catch{process.stdout.write('x')}")
  check "C9: --scaffold repo for $cls writes a file that passes with zero findings" '[ $RC -eq 0 ] && [ "$n" = 0 ] && [ -f "$AG/sc-$cls.md" ]'
done

# ---- C10: revalidation at spawn and at SessionStart
roles_json '{"version":1,"roles":{"coder":{"class":"implement","description":"Imp."},"arch2":{"class":"design","routes":"UI design work"}},"roster":{"route":"peer","members":[{"role":"coder","model":"inherit"},{"role":"architect","model":"opus"}]}}'
agent arch2 arch2 "disallowedTools: Bash, NotebookEdit, advisor"
R spawn-one coder --dry-run
check "C10: spawn-one --dry-run of a valid custom role emits --agent coder" '[[ "$OUT" == *"--agent coder --name repo-coder"* ]]'
agent coder coder "tools: Read, SendMessage, Edit"
R spawn-one coder --dry-run
check "C10: spawn-one refuses once the file breaks, with findings" '[ $RC -ne 0 ] && [[ "$ERR" == *"missing-tool:Write|Bash"* ]]'
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" 2>&1)
check "C10: create plan refuses only the broken member; the Architect still has a launch" 'echo "$OUT" | node -e "const p=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"));const coder=p.members.find(m=>m.role===\"coder\"),a=p.members.find(m=>m.role===\"architect\");process.exit(coder.spawn.refuse&&coder.spawn.validation.refused&&a.spawn.launch.length===1&&!a.spawn.refuse?0:1)"'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }));
" 2>&1)
check "C10: SessionStart marks the broken role unavailable and omits its line" '[[ "$OUT" == *"Unavailable user-defined roles"*": coder."* ]] && ! grep -q "^- Coder " <<<"$OUT"'
agent coder coder "disallowedTools: Edit, NotebookEdit, advisor" "tools: Read, SendMessage, Bash"
roles_json '{"version":1,"roles":{"coder":{"class":"implement","routes":"UI work"}}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }));
" 2>&1)
check "C10: an unavailable alternative falls out of routing (no routing item, built-in stays)" '[[ "$OUT" != *"ROUTING"* && "$OUT" == *"Unavailable user-defined roles"* ]]'

# ---- C11 (I7): no per-tool-call hook reads an agent file
agent coder coder "disallowedTools: advisor"
roles_json '{"version":1,"roles":{"coder":{"class":"implement","routes":"UI work"},"arch2":{"class":"design"}}}'
cat > "$SANDBOX/count-reads.mjs" <<EOF
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const log = (p) => { if (String(p).includes("/.claude/agents/")) fs.appendFileSync("$SANDBOX/reads.log", String(p) + "\n"); };
for (const fn of ["readFileSync", "openSync", "statSync", "existsSync"]) {
  const orig = fs[fn];
  fs[fn] = function (p, ...rest) { log(p); return orig.call(this, p, ...rest); };
}
syncBuiltinESMExports();
EOF
: > "$SANDBOX/reads.log"
PAY_PRE='{"session_id":"s1","cwd":"'$PROJ'","tool_name":"Agent","tool_input":{"subagent_type":"coder","prompt":"x"},"hook_event_name":"PreToolUse"}'
PAY_SEND='{"session_id":"s1","cwd":"'$PROJ'","tool_name":"SendMessage","tool_input":{"to":"repo-coder","message":"[hierarchy-peer-brief reply-to=\"sender\" task=\"t\"]\nhi"},"hook_event_name":"PreToolUse"}'
PAY_POST='{"session_id":"s1","cwd":"'$PROJ'","tool_name":"SendMessage","tool_input":{"to":"repo-coder","message":"hi"},"tool_response":"ok","hook_event_name":"PostToolUse"}'
PAY_UPS='{"session_id":"s1","cwd":"'$PROJ'","prompt":"hello","hook_event_name":"UserPromptSubmit"}'
PAY_STOP='{"session_id":"s1","cwd":"'$PROJ'","agent_type":"coder","hook_event_name":"Stop","stop_hook_active":false}'
PAY_SSTOP='{"session_id":"s1","cwd":"'$PROJ'","agent_type":"coder","agent_id":"a1","hook_event_name":"SubagentStop"}'
for hook in "$H"/pretooluse-*.mjs; do
  for p in "$PAY_PRE" "$PAY_SEND"; do printf '%s' "$p" | HOME="$FAKEHOME" NODE_OPTIONS="--import $SANDBOX/count-reads.mjs" node "$hook" >/dev/null 2>&1; done
done
for hook in "$H"/posttooluse-*.mjs; do printf '%s' "$PAY_POST" | HOME="$FAKEHOME" NODE_OPTIONS="--import $SANDBOX/count-reads.mjs" node "$hook" >/dev/null 2>&1; done
for hook in "$H"/userpromptsubmit-*.mjs; do printf '%s' "$PAY_UPS" | HOME="$FAKEHOME" NODE_OPTIONS="--import $SANDBOX/count-reads.mjs" node "$hook" >/dev/null 2>&1; done
for hook in "$H"/stop-*.mjs "$H"/subagentstop-*.mjs; do
  for p in "$PAY_STOP" "$PAY_SSTOP"; do printf '%s' "$p" | HOME="$FAKEHOME" NODE_OPTIONS="--import $SANDBOX/count-reads.mjs" node "$hook" >/dev/null 2>&1; done
done
OUT=$(sort -u "$SANDBOX/reads.log")
check "C11: PreToolUse/PostToolUse/UserPromptSubmit/Stop hooks perform zero agent-file reads" '[ -z "$OUT" ]'
: > "$SANDBOX/reads.log"
printf '%s' '{"session_id":"s1","cwd":"'$PROJ'","hook_event_name":"SessionStart","source":"startup"}' | HOME="$FAKEHOME" NODE_OPTIONS="--import $SANDBOX/count-reads.mjs" node "$H/sessionstart.mjs" >/dev/null 2>&1
check "C11: the stub does see a SessionStart read (it can fail)" '[ -s "$SANDBOX/reads.log" ]'

# ---- C12: scoped tool entries grant the whole tool
agent sc12 sc12 "tools: Read, SendMessage, Write, Bash(git:*)"
codes design sc12; check "C12: design with Bash(git:*) → scoped-tool-entry and discouraged-tool:Bash" '[[ "$OUT" == *"scoped-tool-entry"* && "$OUT" == *"discouraged-tool:Bash"* ]]'
codes review sc12; check "C12: review with the same list → forbidden-tool:Write" '[[ "$OUT" == *"scoped-tool-entry"* && "$OUT" == *"forbidden-tool:Write"* ]]'

# ---- C13: frontmatter models
agent sonnetimp sonnetimp "model: sonnet" "disallowedTools: advisor"
for row in inherit opus; do
  roles_json '{"version":1,"roles":{"haikurev":{"class":"review","description":"R.","model":"'$row'"}}}'
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$H/lib-config.mjs');
    process.stdout.write(L.validateRole('haikurev', L.resolveConfig('$PROJ')).findings.map((f) => f.code).join(' '));
  " 2>&1)
  check "C13: haiku on review is model-not-allowed under a $row row" '[[ "$OUT" == *"model-not-allowed"* ]]'
done
roles_json '{"version":1,"roles":{"sonnetimp":{"class":"implement","description":"I.","model":"opus"}}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.validateRole('sonnetimp', L.resolveConfig('$PROJ')).findings.map((f) => f.code).join(' '));
" 2>&1)
check "C13: row opus + frontmatter sonnet → no finding" '[ -z "$OUT" ]'

# ---- C14: a name at both levels validates the repo file and warns
agent twin twin "disallowedTools: advisor"
printf -- '---\nname: twin\ndescription: User copy.\n---\nBody.\n' > "$UAG/twin.md"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const r = L.validateAgentContract({ role: 'twin', cls: 'implement', agent: 'twin', cwd: '$PROJ' });
  const f = r.findings.find((x) => x.code === 'shadowed-agent');
  process.stdout.write(JSON.stringify({ path: r.file.found, f }));
" 2>&1)
check "C14: shadowed-agent fires, validating the repo file and naming the user file" '[[ "$OUT" == *"\"path\":\"$AG/twin.md\""* && "$OUT" == *"shadowed-agent"* && "$OUT" == *"$UAG/twin.md"* && "$OUT" == *"remove-file"* ]]'

# ---- C15 (G1): agent collisions
roles_json '{"version":1,"roles":{"one":{"class":"implement","agent":"shared"},"two":{"class":"review","agent":"shared"},"three":{"class":"design","agent":"ah:architect"},"four":{"class":"implement","agent":"coder"}}}'
mkdir -p "$FAKEHOME/.claude" && echo '{"version":1,"roles":{"four":{"class":"implement","agent":"coder"}}}' > "$FAKEHOME/.claude/agent-hierarchy.json"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const r = L.resolveConfig('$PROJ');
  process.stdout.write(JSON.stringify({ roles: Object.keys(r.roles), ex: r.excludedRoles.map((e) => e.name + ':' + e.reason), w: r.warnings }));
" 2>&1)
check "C15: both custom rows sharing an agent are excluded, each warning naming the other" '[[ "$OUT" == *"one:agent \\\"shared\\\" is also used by two"* && "$OUT" == *"two:agent \\\"shared\\\" is also used by one"* ]]'
check "C15: ah:* on a custom row is invalid (built-ins win)" '[[ "$OUT" == *"three:ah:* agents belong to the built-ins"* ]]'
check "C15: the same name at two levels is not a collision" '[[ "$OUT" == *"\"four\""* && "$OUT" != *"four:"* ]]'
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"
roles_json '{"version":1,"roles":{"four":{"class":"implement","agent":"coder"}}}'
R role set five --class implement --agent coder --level repo
check "C15: role set refuses a row whose agent another role owns" '[ $RC -ne 0 ] && [[ "$ERR$OUT" == *"four"* ]]'

# ---- C16 (G2): a failing built-in override reverts to the shipped agent
printf -- '---\nname: my-architect\ndescription: Custom architect.\ntools: Read, SendMessage\n---\nBody.\n' > "$AG/my-architect.md"
roles_json '{"version":1,"roles":{"architect":{"model":"opus","agent":"my-architect"}},"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }));
" 2>&1)
check "C16: directive names architect (my-architect) as unavailable and keeps the Architect line" '[[ "$OUT" == *"Unavailable user-defined roles"*"architect (my-architect)"* && "$OUT" == *"- Architect — "* ]]'
R spawn-one architect --dry-run
check "C16: spawn-one launches ah:architect in place of the failing override, with a notice" '[ $RC -eq 0 ] && [[ "$OUT" == *"--agent ah:architect "* && "$OUT" == *"in place of my-architect"* ]]'
NOTICE() { printf '%s' '{"session_id":"n16","cwd":"'$PROJ'","agent_type":"'$1'","hook_event_name":"SessionStart","source":"startup"}' | HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>/dev/null; }
OUT=$(NOTICE ah:architect)
GOLD=$(sed "s#<PLUGIN>#$PLUGIN#g; s#(v<VER>)#(v$(node -e "console.log(require('$PLUGIN/.claude-plugin/plugin.json').version)"))#" "$PLUGIN/tests/fixtures/0056-i1/golden/notice-architect.json")
check "C16: an ah:architect session gets the byte-identical built-in notice even with an override configured" '[ "$OUT" = "$GOLD" ]'
OUT=$(printf '%s' '{"session_id":"s","cwd":"'$PROJ'","agent_type":"ah:architect","agent_id":"a1","hook_event_name":"SubagentStart"}' | HOME="$FAKEHOME" node "$H/subagentstart-cli-root.mjs" 2>&1)
check "C16: an ah:architect subagent gets no injected contract" '[[ "$OUT" != *"HIERARCHY CONTRACT"* ]]'
printf -- '---\nname: my-architect\ndescription: Custom architect.\ndisallowedTools: Bash, NotebookEdit, advisor\n---\nBody.\n' > "$AG/my-architect.md"
OUT=$(NOTICE my-architect)
check "C16: a my-architect session (the override itself) gets the contract and names its agent file" '[[ "$OUT" == *"HIERARCHY CONTRACT"* && "$OUT" == *"your agent file (\`my-architect\`)"* ]]'
printf -- '---\nname: my-architect\ndescription: Custom architect.\ntools: Read, SendMessage\n---\nBody.\n' > "$AG/my-architect.md"
R role list
check "C16: role list shows UNAVAILABLE → reverted to ah:architect" '[[ "$OUT" == *"UNAVAILABLE → reverted to ah:architect"* ]]'

# ---- C17 (G3): agent > delegate > ah:task-runner, and directive item 8
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write([
    L.subagentType('task-runner', { model: 'haiku', delegate: 'task-gopher', agent: 'my-runner' }),
    L.subagentType('task-runner', { model: 'haiku', delegate: 'task-gopher' }),
    L.subagentType('task-runner', { model: 'haiku' }),
    String(L.hierarchyRoleOf('task-gopher:task-gopher', { resolved: L.resolveConfig('$PROJ') })),
  ].join(' '));
" 2>&1)
check "C17: agent set → agent; else delegate → task-gopher; else ah:task-runner; task-gopher resolves to no role" '[ "$OUT" = "my-runner task-gopher:task-gopher ah:task-runner null" ]'
printf -- '---\nname: my-runner\ndescription: Runner.\n---\nBody.\n' > "$AG/my-runner.md"
roles_json '{"version":1,"roles":{"task-runner":{"model":"haiku","agent":"my-runner"}}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }).split('\n').find((l) => l.startsWith('8. ')));
" 2>&1)
check "C17: item 8 names the task-runner override" '[[ "$OUT" == *"8. Task-Runner: dispatch \`my-runner\`"* ]]'
roles_json '{"version":1,"roles":{}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  process.stdout.write(L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }).split('\n').find((l) => l.startsWith('8. ')));
" 2>&1)
check "C17: item 8 is unchanged with no override" '[ "$OUT" = "8. Task-Runner: prefer \`task-gopher:task-gopher\`; that agent type unavailable → \`ah:task-runner\`. task-gopher'"'"'s on/off toggle controls only its directive, not the agent — delegation works either way." ]'

# ---- C18: peer-name parsing — custom roles match only as an anchored suffix; the built-in scan is unchanged
roles_json '{"version":1,"roles":{"imp":{"class":"implement"},"runner":{"class":"legwork"},"security-reviewer":{"class":"review"}}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const r = L.resolveConfig('$PROJ');
  const parts = (n) => { const p = L.hierarchyNameParts(n, r); return p ? p.role : null; };
  const names = ['claudetools-implementor', 'claudetools-imp', 'claudetools-imp-2', 'proj-runner', 'proj-security-reviewer', 'proj-reviewer'];
  process.stdout.write(JSON.stringify({
    excluded: r.excludedRoles.map((e) => e.name),
    fromName: names.map((n) => L.roleFromName(n, r)),
    parts: [...names, 'proj-task-runner'].map(parts),
  }));
" 2>&1)
check "C18: the hand-edited rows imp, runner and security-reviewer are all accepted" '[[ "$OUT" == *"\"excluded\":[]"* ]]'
check "C18: roleFromName — implementor, imp, imp, runner, security-reviewer, reviewer" '[[ "$OUT" == *"\"fromName\":[\"implementor\",\"imp\",\"imp\",\"runner\",\"security-reviewer\",\"reviewer\"]"* ]]'
check "C18: hierarchyNameParts — same, and proj-task-runner stays task-runner" '[[ "$OUT" == *"\"parts\":[\"implementor\",\"imp\",\"imp\",\"runner\",\"security-reviewer\",\"reviewer\",\"task-runner\"]"* ]]'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const p = L.hierarchyNameParts('proj-architect-reviewer');
  process.stdout.write([L.roleFromName('custom-reviewer-peer'), L.roleFromName('x-architect-reviewer'), p.prefix + '/' + p.role].join(' '));
" 2>&1)
check "C18: with no custom roles the built-in scan is unchanged (custom-reviewer-peer, and the multi-token legacy case)" '[ "$OUT" = "reviewer architect proj-architect/reviewer" ]'

# ---- C19: tier prose names available custom design/advise roles, and nothing more
printf -- '---\nname: ui-architect\ndescription: UI architect.\ndisallowedTools: Bash, NotebookEdit, advisor\n---\nB\n' > "$AG/ui-architect.md"
printf -- '---\nname: sage\ndescription: Sage.\ndisallowedTools: Edit, NotebookEdit, advisor\n---\nB\n' > "$AG/sage.md"
printf -- '---\nname: rev2\ndescription: Reviewer two.\ndisallowedTools: Edit, Write, NotebookEdit, advisor\n---\nB\n' > "$AG/rev2.md"
roles_json '{"version":1,"roles":{"ui-architect":{"class":"design"},"sage":{"class":"advise","model":"opus"},"rev2":{"class":"review"}}}'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const Hr = await import('$H/lib-hier.mjs');
  const r = L.resolveConfig('$PROJ');
  const d = L.buildDirective(r, 's1', { hierDir: '/tmp/h', model: 'opus', route: null });
  process.stdout.write(JSON.stringify({ item14: d.split(String.fromCharCode(10)).find((l) => l.startsWith('14. ')), tier: Hr.tierLine(r, 'opus') }));
" 2>&1)
check "C19: directive item 14 appends the custom design and advise labels (not the review role)" '[[ "$OUT" == *"Ultra-Advisor fable(4), and custom: Sage, Ui-Architect."* && "$OUT" != *"Rev2"* ]]'
check "C19: the HIERARCHY STATE tier line appends them too" '[[ "$OUT" == *"ultra-advisor fable(4), and custom: Sage, Ui-Architect\""* ]]'
printf -- '---\nname: sage\ndescription: Sage.\ntools: Read\n---\nB\n' > "$AG/sage.md"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const L = await import('$H/lib-config.mjs');
  const d = L.buildDirective(L.resolveConfig('$PROJ'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null });
  process.stdout.write(d.split(String.fromCharCode(10)).find((l) => l.startsWith('14. ')));
" 2>&1)
check "C19: an unavailable custom role is not named" '[[ "$OUT" == *"and custom: Ui-Architect."* && "$OUT" != *"Sage"* ]]'

# ---- N8: create --spawn under a fake transport reports the refused member and a partial team
mkdir -p "$SANDBOX/faketmux"
cat > "$SANDBOX/faketmux/tmux" <<'FAKE'
#!/bin/sh
case "$1" in
  list-sessions) exit 0 ;;
  new-window) n=$(cat "$SANDBOX_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$SANDBOX_COUNTER"; echo "%$n" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$SANDBOX/faketmux/tmux"
printf -- '---\nname: coder\ndescription: Coder.\ntools: Read, SendMessage, Edit\n---\nB\n' > "$AG/coder.md"
roles_json '{"version":1,"roles":{"coder":{"class":"implement","description":"C."}},"roster":{"route":"peer","members":[{"role":"coder","model":"inherit"},{"role":"architect","model":"opus"}]}}'
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" SANDBOX_COUNTER="$SANDBOX/faketmux/n" PATH="$SANDBOX/faketmux:$(dirname "$(command -v node)"):/usr/bin:/bin" node "$H/roster.mjs" create --spawn --mode auto --cwd "$PROJ" 2>/dev/null)
check "N8: create --spawn launches the valid member, refuses the broken one, and reports partial" 'echo "$OUT" | node -e "const o=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"));const c=o.members.find(m=>m.role===\"coder\"),a=o.members.find(m=>m.role===\"architect\");process.exit(o.partial===true&&c.launch_status===\"failed\"&&c.validation&&c.validation.refused&&a.launch_status!==\"failed\"?0:1)"'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
