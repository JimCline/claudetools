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
  for (const step of m.spawn.steps) {
    const match = step.match(/--agent ah:([a-z-]+)/);
    if (!match) continue;
    const agentFile = `${agentsDir}/${match[1]}.md`;
    if (!existsSync(agentFile)) { console.error(`no agent definition at ${agentFile} for step: ${step}`); ok = false; }
    if (step.includes("--model inherit")) { console.error(`literal --model inherit in step: ${step}`); ok = false; }
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
check "create --plan: default implementor (model inherit) emits no --model flag at all" \
  'grep -q "herdr agent start myrepo-implementor --kind claude --pane <pane-id-from-split> -- --agent ah:implementor\"" "$SANDBOX/plan-precise.json"'
check "create --plan: explicit-model implementor still emits --model opus" \
  'grep -q "herdr agent start myrepo-implementor-2 --kind claude --pane <pane-id-from-split> -- --agent ah:implementor --model opus" "$SANDBOX/plan-precise.json"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
