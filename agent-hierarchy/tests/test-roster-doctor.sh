#!/bin/bash
# agent-hierarchy — `roster.mjs doctor`: the read-only self-check.
#
# Its whole value is that it answers when everything else is broken, so the assertions are about
# degrading rather than throwing: a missing file, an unreadable install record, or a hook that no
# longer parses each produce a row, never a stack trace.
# HOME-redirected; real state untouched. Writes nothing to the project.
# Usage: bash tests/test-roster-doctor.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-doctor-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

# $1… = extra args; runs with a live CLAUDE_PID unless the caller unsets it
doc() { OUT=$(CLAUDE_PID="$$" HOME="$FAKEHOME" node "$H/roster.mjs" doctor --cwd "$PROJ" "$@" 2>&1); RC=$?; }

# row <name> -> prints that row's status
rowstat() {
  echo "$OUT" | node -e "
    let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
      try { const j=JSON.parse(d); const r=(j.rows||[]).find(x=>x.name===process.argv[1]); process.stdout.write(r?r.status:'MISSING'); }
      catch { process.stdout.write('NOT-JSON'); }
    })" "$1"
}

# ---- 1: clean run is one JSON object with every documented row
doc
check "clean run: exits 0" '[ "$RC" -eq 0 ]'
check "clean run: stdout is exactly one JSON object" \
  '[ "$(echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{try{JSON.parse(d);console.log(\"one\")}catch{console.log(\"not-one\")}})")" = "one" ]'
EXPECTED="version install identity runtime-dir config team peers hook-errors hooks-syntax marketplace"
NAMES=$(echo "$OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{process.stdout.write(JSON.parse(d).rows.map(r=>r.name).join(' '))})")
check "clean run: all 10 rows present, in order" '[ "$NAMES" = "$EXPECTED" ]'
check "clean run: every row has a status from ok|warn|red" \
  'echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{const ok=JSON.parse(d).rows.every(r=>[\"ok\",\"warn\",\"red\"].includes(r.status)&&typeof r.detail===\"string\");process.exit(ok?0:1)})"'
check "clean run: identity is ok with a live CLAUDE_PID" '[ "$(rowstat identity)" = "ok" ]'
check "clean run: hooks-syntax is ok in the real plugin root" '[ "$(rowstat hooks-syntax)" = "ok" ]'
check "clean run: no red rows" \
  'echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{process.exit(JSON.parse(d).red.length===0?0:1)})"'
check "clean run: --check exits 0 when nothing is red" 'CLAUDE_PID="$$" HOME="$FAKEHOME" node "$H/roster.mjs" doctor --cwd "$PROJ" --check > /dev/null 2>&1'

# ---- 2: doctor is read-only — it must not create the hierarchy dir it reports on
check "read-only: no .claude/hierarchy created under the project" '[ ! -d "$PROJ/.claude/hierarchy" ]'

# ---- 3: CLAUDE_PID unset -> identity red, --check exits 1
OUT=$(env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" doctor --cwd "$PROJ" 2>&1); RC=$?
check "CLAUDE_PID unset: identity is red" '[ "$(rowstat identity)" = "red" ]'
check "CLAUDE_PID unset: red[] names identity" 'echo "$OUT" | grep -q "\"identity\""'
check "CLAUDE_PID unset: plain run still exits 0" '[ "$RC" -eq 0 ]'
env -u CLAUDE_PID HOME="$FAKEHOME" node "$H/roster.mjs" doctor --cwd "$PROJ" --check > /dev/null 2>&1; RC=$?
check "CLAUDE_PID unset: --check exits 1" '[ "$RC" -eq 1 ]'

# ---- 4: a hook that does not parse in the running root -> hooks-syntax red.
# Copied root, because the point is that doctor reports on the tree it is running FROM.
BROKEN_ROOT="$SANDBOX/brokenroot"
mkdir -p "$BROKEN_ROOT"
cp -R "$PLUGIN/hooks" "$PLUGIN/.claude-plugin" "$BROKEN_ROOT/"
printf 'const x = {;\n' > "$BROKEN_ROOT/hooks/zz-broken.mjs"
OUT=$(CLAUDE_PID="$$" HOME="$FAKEHOME" node "$BROKEN_ROOT/hooks/roster.mjs" doctor --cwd "$PROJ" 2>&1); RC=$?
check "broken hook in own root: hooks-syntax is red" '[ "$(rowstat hooks-syntax)" = "red" ]'
check "broken hook in own root: the failing file is named" 'echo "$OUT" | grep -q "zz-broken.mjs"'
CLAUDE_PID="$$" HOME="$FAKEHOME" node "$BROKEN_ROOT/hooks/roster.mjs" doctor --cwd "$PROJ" --check > /dev/null 2>&1; RC=$?
check "broken hook in own root: --check exits 1" '[ "$RC" -eq 1 ]'
rm -f "$BROKEN_ROOT/hooks/zz-broken.mjs"

# ---- 5: garbage installed_plugins.json -> a row, not a throw (the schema is undocumented)
mkdir -p "$FAKEHOME/.claude/plugins"
printf 'this is not json' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
doc
check "garbage installed_plugins.json: still one JSON object, exit 0" \
  '[ "$RC" -eq 0 ] && [ "$(rowstat install)" != "NOT-JSON" ]'
check "garbage installed_plugins.json: install row is not red" '[ "$(rowstat install)" != "red" ]'

# ---- 6: an install record pointing elsewhere is the stale-root warning
cat > "$FAKEHOME/.claude/plugins/installed_plugins.json" <<EOF
{ "plugins": { "ah@claudetools": [ { "installPath": "$SANDBOX/some/other/root" } ] } }
EOF
doc
check "install record points elsewhere: install row warns about a stale root" \
  '[ "$(rowstat install)" = "warn" ] && echo "$OUT" | grep -q "stale root"'

# ---- 7: the record is an array of install records, and matching own root is ok
cat > "$FAKEHOME/.claude/plugins/installed_plugins.json" <<EOF
{ "plugins": { "agent-hierarchy@somewhere": [ { "installPath": "$PLUGIN" } ] } }
EOF
doc
check "install record matches own root: install row is ok" '[ "$(rowstat install)" = "ok" ]'
rm -f "$FAKEHOME/.claude/plugins/installed_plugins.json"

# ---- 8: hook errors in the last 24 h surface as a warn with the entries
mkdir -p "$FAKEHOME/.claude/hierarchy"
printf '{"ts":"%s","hook":"sessionstart.mjs","event":"SessionStart","message":"boom"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"
doc
check "recent hook errors: hook-errors row warns" '[ "$(rowstat hook-errors)" = "warn" ]'
check "recent hook errors: the entry is quoted in the detail" 'echo "$OUT" | grep -q "boom"'
rm -f "$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"

# ---- 9: an unwritable hierarchy dir is red
mkdir -p "$PROJ/.claude/hierarchy"
chmod 500 "$PROJ/.claude/hierarchy"
doc
check "unwritable hierarchy dir: runtime-dir is red" '[ "$(rowstat runtime-dir)" = "red" ]'
chmod 700 "$PROJ/.claude/hierarchy"
rm -rf "$PROJ/.claude/hierarchy"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
