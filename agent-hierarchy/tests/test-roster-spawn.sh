#!/bin/bash
# agent-hierarchy — roster.mjs spawnShape() output: every emitted `--agent`
# names a real agent definition, and `inherit` never reaches the CLI as a
# literal --model value. Regression test for docs/specs/0002 Defect A.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-spawn.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-spawn-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

run() { OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

# a fake `tmux` on PATH so the tmux transport branch is reachable without a real session
cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"
NODE_DIR="$(dirname "$(command -v node)")"

# every role exercised: implementor defaults to model "inherit" (ROLE_DEFAULTS),
# plus a second implementor with an explicit model to prove real models still emit.
run init --level repo --route peer
run add --level repo --role ultra-advisor
run add --level repo --role architect
run add --level repo --role reviewer
run add --level repo --role implementor
run add --level repo --role task-runner
run add --level repo --role implementor --model opus
check "setup: 6 members added" 'echo "$OUT" | grep -q "\"name\": \"myrepo-implementor-2\""'

# a node helper that sweeps every emitted step across the whole plan: each --agent value
# must name a real agents/<role>.md, and no step may contain the literal "--model inherit".
cat > "$SANDBOX/verify-plan.mjs" <<'EOF'
import { existsSync, readFileSync } from "node:fs";
const [, , planPath, agentsDir] = process.argv;
const plan = JSON.parse(readFileSync(planPath, "utf8"));
let ok = true;
for (const m of plan.members) {
  if (!m.spawn) continue;
  if ("steps" in m.spawn) { console.error(`spawn.steps still present for ${m.name}`); ok = false; }
  for (const step of [...m.spawn.layout, ...m.spawn.launch]) {
    const match = step.match(/--agent ah:([a-z-]+)/);
    if (match) {
      const agentFile = `${agentsDir}/${match[1]}.md`;
      if (!existsSync(agentFile)) { console.error(`no agent definition at ${agentFile} for step: ${step}`); ok = false; }
    }
    if (step.includes("--model inherit")) { console.error(`literal --model inherit in step: ${step}`); ok = false; }
  }
  // §9.1.7 — target_placeholder null iff no launch string contains it.
  const hasHole = m.spawn.launch.some((s) => m.spawn.target_placeholder && s.includes(m.spawn.target_placeholder));
  if (m.spawn.target_placeholder === null && hasHole) { console.error(`null placeholder but launch contains a hole for ${m.name}`); ok = false; }
  if (m.spawn.target_placeholder !== null && !hasHole) { console.error(`declared placeholder ${m.spawn.target_placeholder} absent from launch for ${m.name}`); ok = false; }
  // §9.2 — substituting a dummy id must leave no <...> markers.
  if (m.spawn.target_placeholder) {
    for (const s of m.spawn.launch) {
      const substituted = s.split(m.spawn.target_placeholder).join("DUMMY-ID");
      if (/[<>]/.test(substituted)) { console.error(`leftover <...> after substitution for ${m.name}: ${substituted}`); ok = false; }
    }
  }
}
process.exit(ok ? 0 : 1);
EOF

plan_for() {
  local transport=$1
  case "$transport" in
    herdr) HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-herdr.json" 2>"$SANDBOX/plan-herdr.err" ;;
    tmux) env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-tmux.json" 2>"$SANDBOX/plan-tmux.err" ;;
    terminal) env -u HERDR_ENV HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-terminal.json" 2>"$SANDBOX/plan-terminal.err" ;;
  esac
}

for transport in herdr tmux terminal; do
  plan_for "$transport"
  PLAN_FILE="$SANDBOX/plan-$transport.json"
  OUT=$(cat "$PLAN_FILE" 2>/dev/null)
  check "create --plan ($transport): transport detected correctly" \
    "grep -q \"\\\"transport\\\": \\\"$transport\\\"\" \"$PLAN_FILE\""
  check "create --plan ($transport): every --agent names a real agents/*.md, no literal --model inherit" \
    "node \"$SANDBOX/verify-plan.mjs\" \"$PLAN_FILE\" \"$PLUGIN/agents\""
done

# precise checks on the two implementors, herdr transport (exact spawn-step strings)
HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-precise.json" 2>&1
check "create --plan (herdr): default implementor (model inherit) emits no --model flag at all" \
  'grep -q "herdr agent start myrepo-implementor --kind claude --pane <TARGET> -- --agent ah:implementor --name myrepo-implementor\"" "$SANDBOX/plan-precise.json"'
check "create --plan (herdr): explicit-model implementor still emits --model opus" \
  'grep -q "herdr agent start myrepo-implementor-2 --kind claude --pane <TARGET> -- --agent ah:implementor --name myrepo-implementor-2 --model opus" "$SANDBOX/plan-precise.json"'
check "create --plan (herdr): spawn.layout is empty, target_from is null (0004 §11.1.1 — layout is no longer per-member)" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-precise.json\",\"utf8\"));const bad=p.members.some(m=>m.spawn&&(m.spawn.layout.length!==0||m.spawn.target_from!==null||m.spawn.target_placeholder!==\"<TARGET>\"||m.spawn.target_source.path!==\".result.pane.pane_id\"));process.exit(bad?1:0)"'
check "create --plan (herdr): top-level layout_plan present, pane_count matches, split_command has holes not --current (0004 §11.1.2)" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-precise.json\",\"utf8\"));const lp=p.layout_plan;const peerCount=p.members.filter(m=>m.spawn).length;process.exit(lp&&lp.pane_count===peerCount&&[\"auto\",\"columns\",\"grid\"].includes(lp.mode)&&lp.split_command.includes(\"--pane <SPLIT_TARGET>\")&&lp.split_command.includes(\"<DIRECTION>\")&&!lp.split_command.includes(\"--current\")&&lp.inspect_source.path===\".result.layout.panes\"?0:1)"'
# 0002 Defect D: herdr launch must carry --name <derived-name> so the Claude session's display
# name matches the check-in scan — the pre-amendment version of this test asserted the opposite.
check "create --plan (herdr): launch contains --name <derived-name> after -- (0002 Defect D)" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-precise.json\",\"utf8\"));const bad=p.members.some(m=>m.spawn&&!m.spawn.launch.some(s=>s.includes(\`--name \${m.name}\`)));process.exit(bad?1:0)"'
check "create --plan (herdr): target_source is json .result.pane.pane_id, target_from is null (0004 §3.2)" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-precise.json\",\"utf8\"));const m=p.members.find(x=>x.spawn);process.exit(m.spawn.target_source.kind===\"json\"&&m.spawn.target_source.path===\".result.pane.pane_id\"&&m.spawn.target_placeholder===\"<TARGET>\"&&m.spawn.target_from===null?0:1)"'

# precise checks: tmux transport — the §4.3 -t target fix
env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-tmux-precise.json" 2>&1
check "create --plan (tmux): layout captures pane id via -P -F '#{pane_id}'" \
  "grep -q \"tmux new-window -P -F '#{pane_id}'\" \"$SANDBOX/plan-tmux-precise.json\""
check "create --plan (tmux): launch targets the captured pane with -t (the §4.3 fix)" \
  'grep -q "tmux send-keys -t <TARGET>" "$SANDBOX/plan-tmux-precise.json"'
check "create --plan (tmux): launch still contains --name" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-tmux-precise.json\",\"utf8\"));const m=p.members.find(x=>x.spawn);process.exit(m.spawn.launch.some(s=>s.includes(\"--name\"))?0:1)"'
check "create --plan (tmux): target_source is stdout/trim" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-tmux-precise.json\",\"utf8\"));const m=p.members.find(x=>x.spawn);process.exit(m.spawn.target_source.kind===\"stdout\"&&m.spawn.target_source.trim===true?0:1)"'
check "create --plan (tmux): layout_plan is null (0004 §3.1 — layout is herdr-only)" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-tmux-precise.json\",\"utf8\"));process.exit(p.layout_plan===null?0:1)"'

# precise checks: terminal transport — no layout, no placeholder
env -u HERDR_ENV HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$PROJ" > "$SANDBOX/plan-terminal-precise.json" 2>&1
check "create --plan (terminal): layout empty, launch is a single --bg command, target_* all null" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-terminal-precise.json\",\"utf8\"));const m=p.members.find(x=>x.spawn);const s=m.spawn;process.exit(s.layout.length===0&&s.launch.length===1&&s.launch[0].endsWith(\"--bg\")&&s.target_placeholder===null&&s.target_from===null&&s.target_source===null?0:1)"'
check "create --plan (terminal): layout_plan is null" \
  'node -e "const p=JSON.parse(require(\"fs\").readFileSync(\"$SANDBOX/plan-terminal-precise.json\",\"utf8\"));process.exit(p.layout_plan===null?0:1)"'

# ---- 0004 §11.1.5: a roster with no "layout" key (pre-0004 file) resolves to layout_plan.mode "auto" and validates clean
BACKCOMPAT="$SANDBOX/backcompat"
mkdir -p "$BACKCOMPAT/.claude"
(cd "$BACKCOMPAT" && git init -q)
cat > "$BACKCOMPAT/.claude/agent-hierarchy.json" <<'EOF'
{"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]}}
EOF
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$BACKCOMPAT" 2>&1); RC=$?
check "create --plan: pre-0004 roster (no layout key) resolves layout_plan.mode 'auto'" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).layout_plan.mode===\"auto\"?0:1))"'

# ---- 0004 §11.1.6: an all-subagent roster yields layout_plan === null
ALLSUBAGENT="$SANDBOX/allsubagent"
mkdir -p "$ALLSUBAGENT/.claude"
(cd "$ALLSUBAGENT" && git init -q)
cat > "$ALLSUBAGENT/.claude/agent-hierarchy.json" <<'EOF'
{"roster":{"route":"subagent","members":[{"role":"architect","model":"opus"}]}}
EOF
OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$ALLSUBAGENT" 2>&1); RC=$?
check "create --plan: all-subagent roster yields layout_plan null" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).layout_plan===null?0:1))"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
