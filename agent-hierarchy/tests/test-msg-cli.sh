#!/bin/bash
# agent-hierarchy — msg.mjs CLI + lib-hier.mjs runtime dir: request/response
# skeletons, list, index, sweep, dir resolution. HOME- and
# AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-msg-cli.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-msg-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)" # normalized: paths below are compared byte-for-byte against node's resolve()
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" "$@" 2>&1); RC=$?; }

eval_hier() { # <js expression over lib-hier.mjs bound as L>, no AGENT_HIERARCHY_DIR unless caller sets one
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$H/lib-hier.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

# ---- 1: new request — skeleton, frontmatter, tldr index, .gitignore
msg new --to implementor --from orchestrator --slug peer-roster --to-name repo-implementor --reason context
check "new request: exit 0" '[ $RC -eq 0 ]'
REQ=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.path)' "$OUT")
ID=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.id)' "$OUT")
check "new request: prints {id,path}" '[ -n "$ID" ] && [ -f "$REQ" ]'
check "new request: id shape YYYYMMDD-HHMMSS-xxxx" 'echo "$ID" | grep -Eq "^[0-9]{8}-[0-9]{6}-[0-9a-z]{4}$"'
check "new request: filename <id>--<to>--<slug>--request.md" '[ "$(basename "$REQ")" = "$ID--implementor--peer-roster--request.md" ]'
check "new request: under <dir>/msgs/" '[ "$(dirname "$REQ")" = "$HD/msgs" ]'
check "frontmatter: flat, opens with ---" '[ "$(head -1 "$REQ")" = "---" ]'
check "frontmatter: type: request" 'grep -q "^type: request$" "$REQ"'
check "frontmatter: to/from" 'grep -q "^to: implementor$" "$REQ" && grep -q "^from: orchestrator$" "$REQ"'
check "frontmatter: to_name recorded" 'grep -q "^to_name: repo-implementor$" "$REQ"'
check "frontmatter: reason recorded" 'grep -q "^reason: context$" "$REQ"'
check "frontmatter: parent null" 'grep -q "^parent: null$" "$REQ"'
check "frontmatter: no nesting/lists" '! grep -Eq "^\s+-|^\s+[a-z_]+:" "$REQ"'
check "body: all 7 request anchors at column 0" '[ "$(grep -c "^## \[" "$REQ")" -eq 7 ]'
check "body: anchors in order" '[ "$(grep "^## \[" "$REQ" | tr "\n" " ")" = "## [0] tldr ## [1] goal ## [2] context ## [3] constraints ## [4] files ## [5] acceptance ## [6] want_back " ]'
check "body: tldr has one - [N] key: line per section" '[ "$(grep -c "^- \[[1-6]\] [a-z_]*: " "$REQ")" -eq 6 ]'
check "body: - none placeholders" '[ "$(grep -c "^- none$" "$REQ")" -eq 6 ]'
check ".gitignore written with *" '[ "$(cat "$HD/.gitignore")" = "*" ]'
check "layout: msgs/archive and specs exist" '[ -d "$HD/msgs/archive" ] && [ -d "$HD/specs" ]'

# ---- 2: arg validation
msg new --to nobody --from orchestrator --slug x
check "new: bad --to exits non-zero with one stderr line" '[ $RC -ne 0 ] && [ "$(echo "$OUT" | wc -l | tr -d " ")" = 1 ]'
msg new --to implementor --from orchestrator --slug "Bad Slug"
check "new: bad slug rejected" '[ $RC -ne 0 ]'
msg new --to implementor --from orchestrator --slug ok --reason whim
check "new: bad reason rejected" '[ $RC -ne 0 ]'
msg new --type response
check "response: --id required" '[ $RC -ne 0 ] && echo "$OUT" | grep -q -- "--id"'
msg new --type response --id 20990101-000000-zzzz
check "response: missing request rejected" '[ $RC -ne 0 ] && echo "$OUT" | grep -q "no request"'

# ---- 3: list open, then response closes it
msg list --plain
check "list --plain: id to slug age open" 'echo "$OUT" | grep -Eq "^$ID  implementor  peer-roster  [0-9]+[smhd]  open$"'
msg list
check "list (json): open exchange present" 'echo "$OUT" | grep -q "\"state\":\"open\""'
msg list --closed --plain
check "list --closed: empty before response" '[ -z "$OUT" ]'
msg new --type response --id "$ID"
check "response: exit 0" '[ $RC -eq 0 ]'
RESP=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.path)' "$OUT")
check "response: filename <id>--<orig from>--<slug>--response.md" '[ "$(basename "$RESP")" = "$ID--orchestrator--peer-roster--response.md" ]'
check "response: to/from swapped" 'grep -q "^to: orchestrator$" "$RESP" && grep -q "^from: implementor$" "$RESP"'
check "response: to_name/from_name swapped from request" 'grep -q "^from_name: repo-implementor$" "$RESP"'
check "response: 6 anchors" '[ "$(grep "^## \[" "$RESP" | tr "\n" " ")" = "## [0] tldr ## [1] status ## [2] changes ## [3] evidence ## [4] gaps ## [5] open_questions " ]'
msg new --type response --id "$ID"
check "response: duplicate rejected" '[ $RC -ne 0 ]'
msg list --plain
check "list default (--open): closed exchange gone" '[ -z "$OUT" ]'
msg list --closed --plain
check "list --closed: shows it closed" 'echo "$OUT" | grep -q "closed$"'
msg list --all --plain --to implementor
check "list --all --to: filters by to" 'echo "$OUT" | grep -q "^$ID"'
msg list --all --plain --to reviewer
check "list --to other role: empty" '[ -z "$OUT" ]'

# ---- 4: index matches grep -n
msg index --plain "$RESP"
check "index --plain: matches grep -n '^## \[' exactly" '[ "$OUT" = "$(grep -n "^## \[" "$RESP")" ]'
msg index "$RESP"
check "index (json): line numbers present" 'echo "$OUT" | grep -q "\"line\":"'

# ---- 5: sweep archives only closed pairs older than N days
msg new --to reviewer --from orchestrator --slug still-open
msg sweep --days 0
check "sweep --days 0: archives the closed pair only" 'echo "$OUT" | grep -q "\"archived\":1"'
check "sweep: closed pair moved to msgs/archive" '[ -f "$HD/msgs/archive/$(basename "$REQ")" ] && [ -f "$HD/msgs/archive/$(basename "$RESP")" ]'
check "sweep: open request untouched" 'ls "$HD/msgs" | grep -q "still-open--request.md"'
msg new --to reviewer --from orchestrator --slug fresh
FID=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.id)' "$OUT")
msg new --type response --id "$FID"
msg sweep --days 7
check "sweep --days 7: a fresh closed pair stays" 'echo "$OUT" | grep -q "\"archived\":0"'
msg sweep --plain --days 0
check "sweep --plain: prints the count" '[ "$OUT" = "1" ]'

# ---- 6: dir resolution — env override, project (.git walk-up), user fallback
eval_hier "L.hierarchyDir('$SANDBOX/anything')"
check "hierarchyDir: no git, no env -> ~/.claude/hierarchy/<basename>" '[ "$OUT" = "$FAKEHOME/.claude/hierarchy/anything" ]'
mkdir -p "$SANDBOX/repo/.git" "$SANDBOX/repo/sub/deep"
eval_hier "L.hierarchyDir('$SANDBOX/repo/sub/deep')"
check "hierarchyDir: walks up to .git dir -> <root>/.claude/hierarchy" '[ "$OUT" = "$SANDBOX/repo/.claude/hierarchy" ]'
mkdir -p "$SANDBOX/wt/inner" && echo "gitdir: elsewhere" > "$SANDBOX/wt/.git"
eval_hier "L.hierarchyDir('$SANDBOX/wt/inner')"
check "hierarchyDir: .git FILE (worktree) counts" '[ "$OUT" = "$SANDBOX/wt/.claude/hierarchy" ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$SANDBOX/override" node --input-type=module -e "
  const L = await import('$H/lib-hier.mjs'); process.stdout.write(L.hierarchyDir('$SANDBOX/repo/sub'));" 2>&1)
check "hierarchyDir: AGENT_HIERARCHY_DIR wins over git root" '[ "$OUT" = "$SANDBOX/override" ]'
eval_hier "(L.ensureHierarchyDir('$SANDBOX/repo/sub'), require('node:fs').readFileSync('$SANDBOX/repo/.claude/hierarchy/.gitignore','utf8'))" 2>/dev/null
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  import { readFileSync } from 'node:fs';
  const L = await import('$H/lib-hier.mjs'); L.ensureHierarchyDir('$SANDBOX/repo/sub'); L.ensureHierarchyDir('$SANDBOX/repo/sub');
  process.stdout.write(readFileSync('$SANDBOX/repo/.claude/hierarchy/.gitignore','utf8'));" 2>&1)
check "ensureHierarchyDir: idempotent, project .gitignore = *" '[ "$OUT" = "*" ]'

# ---- 7: msg.mjs writes stdout via one helper; frontmatter parser round-trips
eval_hier "JSON.stringify(L.parseFrontmatter('---\nid: x\nparent: null\nreason: context   # note\n---\nbody').fields)"
check "parseFrontmatter: null + trailing comment stripped" '[ "$OUT" = "{\"id\":\"x\",\"parent\":null,\"reason\":\"context\"}" ]'
eval_hier "L.parseFrontmatter('no fence')"
check "parseFrontmatter: no fence -> null" '[ "$OUT" = null ]'
eval_hier "L.tierOf('claude-opus-4-1')+','+L.tierOf('fable')+','+L.tierOf('claude-fable-5')+','+L.tierOf('gpt-x')"
check "tierOf: family token in id or bare; unknown null" '[ "$OUT" = "3,4,4,null" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
