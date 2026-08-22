#!/bin/bash
# agent-hierarchy usage-tracking tests: SubagentStop collector + reporter.
# Runs with HOME redirected and fabricated transcript trees so real state is
# never touched, and no model is ever involved — the point of the feature.
# Usage: bash tests/test-usage-tracking.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
COLLECT="$PLUGIN/hooks/subagentstop-usage.mjs"
REPORT="$PLUGIN/hooks/usage-report.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-usage-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/projects/myproj"
PASS=0; FAIL=0

REAL_USAGE="$(printf '%s' ~)/.claude/agent-hierarchy.usage.jsonl"
REAL_USAGE_PRE=0; [ -f "$REAL_USAGE" ] && REAL_USAGE_PRE=1

mkdir -p "$FAKEHOME/.claude" "$PROJ/sessA/subagents"
TODAY="$(date -u +%Y-%m-%d)"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:140})"; fi
}

# Fabricate a transcript: assistant lines with usage, plus noise that must be
# skipped (user line, garbage line, assistant line without usage).
mk_transcript() { # <path> <model> <out1> <out2>
  cat > "$1" <<EOF
{"type":"user","timestamp":"${TODAY}T10:00:00.000Z","message":{"role":"user","content":"x"}}
{"type":"assistant","timestamp":"${TODAY}T10:00:01.000Z","message":{"model":"$2","usage":{"input_tokens":10,"output_tokens":$3,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}
not json at all
{"type":"assistant","timestamp":"${TODAY}T10:00:02.000Z","message":{"model":"$2"}}
{"type":"assistant","timestamp":"${TODAY}T10:00:03.000Z","message":{"model":"$2","usage":{"input_tokens":20,"output_tokens":$4,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}
EOF
}

payload() { # <agent_id> <agent_type>
  printf '{"hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"%s","session_id":"sessA","transcript_path":"%s/sessA.jsonl","cwd":"%s"}' \
    "$1" "$2" "$PROJ" "$PROJ"
}

run_collect() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$COLLECT" 2>/dev/null); RC=$?; }
USAGE="$FAKEHOME/.claude/agent-hierarchy.usage.jsonl"

# ---- collector: sums a real transcript into one record
mk_transcript "$PROJ/sessA/subagents/agent-idA.jsonl" "claude-opus-5" 30 70
run_collect "$(payload idA ah:architect)"
check "collector: exits 0" '[ $RC -eq 0 ]'
check "collector: one record written" '[ "$(wc -l < "$USAGE")" -eq 1 ]'
check "collector: sums out=100 in=30 cache_read=300, found, type stored" \
  'node -e "const r=JSON.parse(require(\"fs\").readFileSync(\"$USAGE\",\"utf8\").trim());process.exit(r.out===100&&r.in===30&&r.cache_read===300&&r.cache_create===5&&r.calls===2&&r.found===true&&r.agent_type===\"ah:architect\"&&r.model===\"claude-opus-5\"?0:1)"'

# ---- second agent, delegate type (maps to task-runner at report time)
mk_transcript "$PROJ/sessA/subagents/agent-idB.jsonl" "claude-haiku-4-5-20251001" 11 22
run_collect "$(payload idB task-gopher:task-gopher)"
check "collector: second record appended" '[ "$(wc -l < "$USAGE")" -eq 2 ]'

# ---- unknown type lands in the data as-is (bucketed at report time)
mk_transcript "$PROJ/sessA/subagents/agent-idC.jsonl" "claude-sonnet-5" 5 5
run_collect "$(payload idC github-pr-toolkit:github-worker)"

# ---- missing transcript -> found:false telemetry record, zero tokens
run_collect "$(payload idGone ah:reviewer)"
check "collector: missing transcript logged found:false with zero tokens" \
  'node -e "const l=require(\"fs\").readFileSync(\"$USAGE\",\"utf8\").trim().split(\"\n\");const r=JSON.parse(l[l.length-1]);process.exit(r.found===false&&r.out===0&&r.agent_id===\"idGone\"?0:1)"'

# ---- payloads that must not produce records or errors
N_BEFORE="$(wc -l < "$USAGE")"
run_collect '{"hook_event_name":"SubagentStop","session_id":"sessA"}'
check "collector: no agent_id -> no record, exit 0" '[ $RC -eq 0 ] && [ "$(wc -l < "$USAGE")" -eq "$N_BEFORE" ]'
run_collect ''
check "collector: empty stdin -> exit 0" '[ $RC -eq 0 ] && [ "$(wc -l < "$USAGE")" -eq "$N_BEFORE" ]'
run_collect 'not json'
check "collector: malformed stdin -> exit 0" '[ $RC -eq 0 ] && [ "$(wc -l < "$USAGE")" -eq "$N_BEFORE" ]'

# ---- concurrent stops must all survive (append-only contract)
for i in $(seq 1 12); do
  mk_transcript "$PROJ/sessA/subagents/agent-cc$i.jsonl" "claude-haiku-4-5-20251001" 1 1
  printf '%s' "$(payload "cc$i" task-gopher:task-gopher)" | HOME="$FAKEHOME" node "$COLLECT" >/dev/null 2>&1 &
done
wait
CC=$(grep -c '"agent_id":"cc' "$USAGE")
[ "$CC" -eq 12 ] && { PASS=$((PASS+1)); echo "PASS: 12 concurrent stops, all 12 records survived"; } || { FAIL=$((FAIL+1)); echo "FAIL: concurrent records lost, $CC/12"; }

# ---- reporter: main transcript gives the orchestrator row
mk_transcript "$PROJ/sessA.jsonl" "claude-fable-5" 40 60
run_report() { OUT=$(HOME="$FAKEHOME" node "$REPORT" "$@" 2>&1); RC=$?; }

run_report all --json
check "reporter --json: exits 0 and parses" '[ $RC -eq 0 ] && printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{JSON.parse(s)})" 2>/dev/null'
check "reporter: architect out=100" 'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.architect.out===100?0:1)})"'
check "reporter: task-gopher records mapped to task-runner (out=57, 13 agents)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);const t=j.windowed.roles[\"task-runner\"];process.exit(t.out===33+24&&t.agents===13?0:1)})"'
check "reporter: orchestrator row from main transcript (out=100)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.orchestrator&&j.windowed.roles.orchestrator.out===100?0:1)})"'
check "reporter: unknown type bucketed under other with breakdown" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.other&&j.windowed.otherTypes[\"github-pr-toolkit:github-worker\"]===1?0:1)})"'
check "reporter: found:false surfaces as missing count on reviewer" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.reviewer.missing===1?0:1)})"'

# ---- a re-fired Stop (resumed agent) must not double-count: transcript sums
# are cumulative, so the LAST record per (session, agent) wins.
run_collect "$(payload idA ah:architect)"
run_report all --json
check "reporter: duplicate Stop for same agent counted once (out stays 100)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);const a=j.windowed.roles.architect;process.exit(a.out===100&&a.agents===1?0:1)})"'

run_report
check "reporter human: session table present" 'printf "%s" "$OUT" | grep -q "SESSION sessA"'
check "reporter human: roles and bars render" 'printf "%s" "$OUT" | grep -q "architect" && printf "%s" "$OUT" | grep -q "█"'
check "reporter human: honest cache-read footnote" 'printf "%s" "$OUT" | grep -q "cache reads shown separately"'

# ---- incremental scan: appended main-transcript lines are picked up
check "reporter: cache file created" '[ -f "$FAKEHOME/.claude/agent-hierarchy.usage-cache.json" ]'
printf '{"type":"assistant","timestamp":"%sT12:00:00.000Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":900,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$TODAY" >> "$PROJ/sessA.jsonl"
run_report all --json
check "reporter: incremental append picked up (orchestrator out=1000)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.orchestrator.out===1000?0:1)})"'

# ---- a partial (mid-write) trailing line must not be counted or corrupt state
printf '{"type":"assistant","timestamp":"%sT12:01:00.000Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":55' "$TODAY" >> "$PROJ/sessA.jsonl"
run_report all --json
check "reporter: partial trailing line ignored (still 1000)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.orchestrator.out===1000?0:1)})"'
printf ',"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$PROJ/sessA.jsonl"
run_report all --json
check "reporter: completed line then counted (1055)" \
  'printf "%s" "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.windowed.roles.orchestrator.out===1055?0:1)})"'

# ---- no data at all: report says so instead of crashing
EMPTYHOME="$SANDBOX/emptyhome"; mkdir -p "$EMPTYHOME/.claude"
OUT=$(HOME="$EMPTYHOME" node "$REPORT" 2>&1); RC=$?
check "reporter: no data -> friendly message, exit 0" '[ $RC -eq 0 ] && printf "%s" "$OUT" | grep -q "No usage recorded yet"'

# ---- syntax + wiring + versions
for f in "$PLUGIN"/hooks/*.mjs; do
  node --check "$f" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: node --check $(basename "$f")"; } || { FAIL=$((FAIL+1)); echo "FAIL: node --check $(basename "$f")"; }
done
check "hooks.json registers SubagentStop" 'grep -q "\"SubagentStop\"" "$PLUGIN/hooks/hooks.json"'
check "hooks.json points at subagentstop-usage.mjs" 'grep -q "subagentstop-usage.mjs" "$PLUGIN/hooks/hooks.json"'
for j in "$PLUGIN/hooks/hooks.json" "$PLUGIN/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json"; do
  node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: valid JSON $(basename "$j")"; } || { FAIL=$((FAIL+1)); echo "FAIL: invalid JSON $j"; }
done
V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='ah').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

# ---- real config untouched
if [ -f "$REAL_USAGE" ] && [ "$REAL_USAGE_PRE" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "FAIL: real ~/.claude/agent-hierarchy.usage.jsonl was created by the tests!"
else
  PASS=$((PASS+1)); echo "PASS: real ~/.claude untouched by tests"
fi

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
