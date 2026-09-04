#!/bin/bash
# Spec 0041 (r2) — uniform CLI fallback when the `ah` MCP server is not
# connected. Pure static-content checks against the shipped docs/agents/
# skills — no runtime MCP or roster/msg state needed.
# Usage: bash tests/test-mcp-cli-fallback.sh   (exits 0 iff all pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc"
  fi
}

# Shared row-lookup logic (T1): find the markdown table row for `name`
# (line-anchored, so it can never span into a neighboring row) and require
# a real 4th ("CLI equivalent") cell. A cell may itself contain an escaped
# pipe (`\|`, used for flag alternatives like `--commit\|--keep-sessions`),
# so an escaped pipe is protected before splitting on the real column
# separators.
T1_LOOKUP='
function findMissing(names, doc) {
  const lines = doc.split("\n");
  const missing = [];
  for (const n of names) {
    const re = new RegExp("^\\|\\s*`" + n + "`\\s*\\|");
    const row = lines.find((l) => re.test(l.trim()));
    if (!row) { missing.push(n); continue; }
    const protectedRow = row.trim().replace(/\\\|/g, "");
    const cells = protectedRow.replace(/^\|/, "").replace(/\|$/, "").split("|");
    if (cells.length < 4 || !cells[3].trim()) missing.push(n);
  }
  return missing;
}
'

# T1 — mapping completeness (drift guard): every tool registered in
# mcp/server.mjs's TOOLS array must appear in docs/mcp-tools.md's tables with
# a non-empty CLI-equivalent (4th) column.
T1_OUT="$(PLUGIN="$PLUGIN" node -e "
const fs = require('fs');
$T1_LOOKUP
const plugin = process.env.PLUGIN;
const server = fs.readFileSync(plugin + '/mcp/server.mjs', 'utf8');
const start = server.indexOf('export const TOOLS');
const end = server.indexOf('const TOOL_NAMES');
const toolsSection = server.slice(start, end);
const names = [...toolsSection.matchAll(/name: \"([a-z_]+)\"/g)].map((m) => m[1]);
const doc = fs.readFileSync(plugin + '/docs/mcp-tools.md', 'utf8');
console.log(JSON.stringify({ count: names.length, missing: findMissing(names, doc) }));
")"
T1_COUNT="$(node -e "console.log(JSON.parse(process.argv[1]).count)" "$T1_OUT")"
T1_MISSING="$(node -e "console.log(JSON.parse(process.argv[1]).missing.join(','))" "$T1_OUT")"
T1_MISSING_COUNT="$(node -e "console.log(JSON.parse(process.argv[1]).missing.length)" "$T1_OUT")"
check "T1: server.mjs registers a non-trivial tool count (sanity)" "$([ "$T1_COUNT" -ge 20 ] && echo 0 || echo 1)"
check "T1: every registered tool ($T1_COUNT total) has a non-empty CLI-equivalent row in docs/mcp-tools.md (missing $T1_MISSING_COUNT: $T1_MISSING)" "$([ -z "$T1_MISSING" ] && echo 0 || echo 1)"

# T1 falsifier: a fake registration not in the doc must fail T1's own logic.
T1_FALSIFIER="$(PLUGIN="$PLUGIN" node -e "
const fs = require('fs');
$T1_LOOKUP
const plugin = process.env.PLUGIN;
const server = fs.readFileSync(plugin + '/mcp/server.mjs', 'utf8').replace(
  'const TOOL_NAMES',
  '  { name: \"roster_bogus\", description: \"x\" },\nconst TOOL_NAMES'
);
const start = server.indexOf('export const TOOLS');
const end = server.indexOf('const TOOL_NAMES');
const toolsSection = server.slice(start, end);
const names = [...toolsSection.matchAll(/name: \"([a-z_]+)\"/g)].map((m) => m[1]);
const doc = fs.readFileSync(plugin + '/docs/mcp-tools.md', 'utf8');
const missing = findMissing(names, doc);
console.log(missing.includes('roster_bogus') ? 'fails-as-expected' : 'BUG-did-not-fail');
")"
check "T1 falsifier: fake roster_bogus registration is caught as undocumented" "$([ "$T1_FALSIFIER" = "fails-as-expected" ] && echo 0 || echo 1)"

# T1 control mutation: delete msg_new's row from the doc table -> must fail.
T1_CONTROL="$(PLUGIN="$PLUGIN" node -e "
const fs = require('fs');
$T1_LOOKUP
const plugin = process.env.PLUGIN;
const server = fs.readFileSync(plugin + '/mcp/server.mjs', 'utf8');
const start = server.indexOf('export const TOOLS');
const end = server.indexOf('const TOOL_NAMES');
const toolsSection = server.slice(start, end);
const names = [...toolsSection.matchAll(/name: \"([a-z_]+)\"/g)].map((m) => m[1]);
let doc = fs.readFileSync(plugin + '/docs/mcp-tools.md', 'utf8');
doc = doc.split('\n').filter((line) => !line.includes('\`msg_new\`')).join('\n');
const missing = findMissing(names, doc);
console.log(missing.includes('msg_new') ? 'fails-as-expected' : 'BUG-did-not-fail');
")"
check "T1 control: deleting msg_new's doc row is caught" "$([ "$T1_CONTROL" = "fails-as-expected" ] && echo 0 || echo 1)"

# T2/T3 target files.
AGENT_FILES=(
  "$PLUGIN/agents/architect.md"
  "$PLUGIN/agents/implementor.md"
  "$PLUGIN/agents/reviewer.md"
  "$PLUGIN/agents/ultra-advisor.md"
  "$PLUGIN/agents/task-runner.md"
)
ORCH_FILE="$PLUGIN/agents/orchestrator.md"
SKILL_FILES=(
  "$PLUGIN/skills/agent-roster/SKILL.md"
  "$PLUGIN/skills/autonomous-pipeline/SKILL.md"
)
FILES=("${AGENT_FILES[@]}" "$ORCH_FILE" "${SKILL_FILES[@]}")

# T2 — uniform prose: the §2.1 standard sentence's invariant portion (the
# part identical in all eight files, up to the role-specific clause) appears
# exactly once in each file.
INVARIANT='Always try `mcp__ah__*` first — it is the preferred path. Only if it is absent from your toolset or a call to it fails as not-connected, fall back to the CLI equivalents listed in `agent-hierarchy/docs/mcp-tools.md` rather than guessing the arguments, and say so ONCE:'
for f in "${FILES[@]}"; do
  label="$(basename "$(dirname "$f")")/$(basename "$f")"
  n="$(grep -F -c "$INVARIANT" "$f")"
  check "T2: standard sentence appears exactly once in $label" "$([ "$n" -eq 1 ] && echo 0 || echo 1)"
done

# T2 falsifier: delete it from one file (a scratch copy) -> must fail.
TMP_T2="$(mktemp)"
grep -v -F "$INVARIANT" "$PLUGIN/agents/architect.md" > "$TMP_T2"
T2_N="$(grep -F -c "$INVARIANT" "$TMP_T2")"
check "T2 falsifier: sentence-stripped scratch copy is caught (found $T2_N)" "$([ "$T2_N" -eq 0 ] && echo 0 || echo 1)"
rm -f "$TMP_T2"

# T3 — notice clause present, correct variant per file (r2 §2.1, three
# variants): A (user-facing, orchestrator.md only), B (report line, the
# other five agents/*.md), C (defers to the invoking role, both SKILL.md
# files, byte-identical). Each file must carry exactly its own variant and
# neither of the other two.
# Each anchored on "say so ONCE: " so B's text (which also appears, as a
# clause, inside C's "...add one line to your report.") cannot false-match
# as a substring of C or vice versa.
CLAUSE_A='say so ONCE: tell the user in your next message that the `ah` server is not connected'
CLAUSE_B='say so ONCE: add one line to your report.'
CLAUSE_C='say so ONCE: apply the notice per your role — if you are the top-level session, tell the user; if you were dispatched, add one line to your report.'

for f in "${AGENT_FILES[@]}"; do
  label="agents/$(basename "$f")"
  hasB="$(grep -F -c "$CLAUSE_B" "$f")"
  hasA="$(grep -F -c "$CLAUSE_A" "$f")"
  hasC="$(grep -F -c "$CLAUSE_C" "$f")"
  check "T3: $label carries clause B (report line) and not A or C" "$([ "$hasB" -eq 1 ] && [ "$hasA" -eq 0 ] && [ "$hasC" -eq 0 ] && echo 0 || echo 1)"
done

hasA_orch="$(grep -F -c "$CLAUSE_A" "$ORCH_FILE")"
hasReload="$(grep -F -c '/reload-plugins' "$ORCH_FILE")"
hasB_orch="$(grep -F -c "$CLAUSE_B" "$ORCH_FILE")"
hasC_orch="$(grep -F -c "$CLAUSE_C" "$ORCH_FILE")"
check "T3: orchestrator.md carries clause A (user-facing, names /reload-plugins) and not B or C" "$([ "$hasA_orch" -ge 1 ] && [ "$hasReload" -ge 1 ] && [ "$hasB_orch" -eq 0 ] && [ "$hasC_orch" -eq 0 ] && echo 0 || echo 1)"

for f in "${SKILL_FILES[@]}"; do
  label="$(basename "$(dirname "$f")")/$(basename "$f")"
  hasC="$(grep -F -c "$CLAUSE_C" "$f")"
  hasA="$(grep -F -c "$CLAUSE_A" "$f")"
  hasB="$(grep -F -c "$CLAUSE_B" "$f")"
  check "T3: $label carries clause C byte-identically and not A or B" "$([ "$hasC" -ge 1 ] && [ "$hasA" -eq 0 ] && [ "$hasB" -eq 0 ] && echo 0 || echo 1)"
done

# T4 (r2, redefined per F4) — the removed ad-hoc clauses stay removed. This
# is deliberately NOT a blanket ban on any `roster.mjs <verb>`/`msg.mjs
# <verb>` literal in agents/*.md or SKILL.md: that would also forbid
# agent-roster/SKILL.md's pre-existing "Command surface" per-verb reference
# and autonomous-pipeline/SKILL.md's msg.mjs route/sweep/list mentions,
# which document CLI-only functionality with no mcp__ah__* wrapper at all
# (§2's file table explicitly leaves both out of scope). T4 checks exactly
# the three literal clauses §2's file table asked removed.
for f in "${FILES[@]}"; do
  n="$(grep -F -c -- '--type response --id' "$f")"
  check "T4: old ad-hoc msg.mjs response-argv clause is gone from $(basename "$f")" "$([ "$n" -eq 0 ] && echo 0 || echo 1)"
done
n="$(grep -F -c -- 'msg.mjs new ... --to' "$ORCH_FILE")"
check "T4: orchestrator.md's old msg.mjs new argv mention is gone" "$([ "$n" -eq 0 ] && echo 0 || echo 1)"
n="$(grep -F -c -- 'msg.mjs new --eta' "$PLUGIN/skills/autonomous-pipeline/SKILL.md")"
check "T4: autonomous-pipeline SKILL.md's old msg.mjs new --eta mention is gone" "$([ "$n" -eq 0 ] && echo 0 || echo 1)"

# T4 falsifier: a scratch copy that reintroduces the old clause must be caught.
TMP_T4="$(mktemp)"
cp "$PLUGIN/agents/implementor.md" "$TMP_T4"
printf '\n(`msg.mjs new --type response --id <id>`)\n' >> "$TMP_T4"
n="$(grep -F -c -- '--type response --id' "$TMP_T4")"
check "T4 falsifier: reintroduced argv form is caught (found $n)" "$([ "$n" -gt 0 ] && echo 0 || echo 1)"
rm -f "$TMP_T4"

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
