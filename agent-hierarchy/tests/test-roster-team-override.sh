#!/bin/bash
# agent-hierarchy — per-team roster override (spec 0032 §3): a config file may carry an
# optional `rosters` map keyed by team alias, alongside the existing `roster` default
# template. `resolveRoster` resolves it in two passes — team-specific (any level) before
# default (any level) — and every roster.mjs write path routes through one container
# helper so a --team-scoped write never touches the shared `roster` key.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-team-override.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-override-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/repo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q && git config user.email t@t.com && git config user.name t && touch f && git add f && git commit -qm init)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

evalc() { # <js over lib-config as C>
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

rcli() { # <roster.mjs argv...>
  OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}

REPO_CFG="$PROJ/.claude/agent-hierarchy.json"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"

writeCfg() { cat > "$1"; }

# T1: roster at repo with members A,B; no rosters. Resolve with --team hotfix -> default, teamKey null
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" }, { "role": "architect", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({roles: C.resolveRoster('$PROJ','hotfix').members.map(m=>m.role), teamKey: C.resolveRoster('$PROJ','hotfix').teamKey})"
check "T1: no rosters key -> --team hotfix falls back to default, teamKey null (regression guard)" \
  'echo "$OUT" | grep -q "\"teamKey\":null" && echo "$OUT" | grep -q "reviewer"'

# T2: roster at repo (A,B) AND rosters.hotfix at repo (C). Resolve --team hotfix -> C only
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" }, { "role": "architect", "model": "opus" } ] },
  "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } } }
EOF
evalc "JSON.stringify({roles: C.resolveRoster('$PROJ','hotfix').members.map(m=>m.role), teamKey: C.resolveRoster('$PROJ','hotfix').teamKey})"
check "T2: rosters.hotfix selected when active, members C only" \
  'echo "$OUT" | grep -q "\[\"implementor\"\]" && echo "$OUT" | grep -q "\"teamKey\":\"hotfix\""'

# T3: same file, resolve with no team -> A,B
evalc "JSON.stringify(C.resolveRoster('$PROJ',null).members.map(m=>m.role))"
check "T3: no team -> default roster A,B" 'echo "$OUT" | grep -q "reviewer" && echo "$OUT" | grep -q "architect"'

# T4: resolve --team other (no such key) -> falls through to default
evalc "JSON.stringify(C.resolveRoster('$PROJ','other').members.map(m=>m.role))"
check "T4: unknown team key falls through to default, no warn/throw" 'echo "$OUT" | grep -q "reviewer"'

# T5: rosters.hotfix at global, roster at repo. Resolve --team hotfix -> global per-team wins
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
writeCfg "$GLOBAL_CFG" <<'EOF'
{ "version": 1, "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$PROJ','hotfix').level, roles: C.resolveRoster('$PROJ','hotfix').members.map(m=>m.role)})"
check "T5: per-team override at global outranks default at repo (the falsifiable §3.2 core)" \
  'echo "$OUT" | grep -q "\"level\":\"global\"" && echo "$OUT" | grep -q "implementor"'

# T6: rosters.hotfix at global AND repo -> repo one wins (location precedence within a pass)
cat > "$REPO_CFG" <<'EOF'
{ "version": 1, "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$PROJ','hotfix').level, roles: C.resolveRoster('$PROJ','hotfix').members.map(m=>m.role)})"
check "T6: two per-team blocks -> location precedence still decides within the team-pass" \
  'echo "$OUT" | grep -q "\"level\":\"repo\"" && echo "$OUT" | grep -q "reviewer"'
rm -f "$GLOBAL_CFG"

# T7: rosters.hotfix present with members:[] -> falls through to default
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "hotfix": { "route": "peer", "members": [] } } }
EOF
evalc "JSON.stringify(C.resolveRoster('$PROJ','hotfix').teamKey)"
check "T7: empty rosters.hotfix members -> no-match, falls through to default" '[ "$OUT" = null ]'

# T8: rosters is an array, or a string -> ignored, no throw; default resolves
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] }, "rosters": [1,2,3] }
EOF
evalc "JSON.stringify(C.resolveRoster('$PROJ','hotfix'))"
check "T8a: rosters as array -> ignored, no throw, default resolves" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q reviewer'
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] }, "rosters": "nope" }
EOF
evalc "JSON.stringify(C.resolveRoster('$PROJ','hotfix'))"
check "T8b: rosters as string -> ignored, no throw, default resolves" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q reviewer'

# T9: a rosters key that isn't the requested team -> irrelevant, no throw, default resolves
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "not-hotfix!!": { "route": "peer", "members": [ { "role": "architect", "model": "opus" } ] } } }
EOF
evalc "JSON.stringify(C.resolveRoster('$PROJ','hotfix'))"
check "T9: unrelated/malformed rosters key -> no throw, default resolves" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q reviewer'

# ---- write-path tests (§3.4) ----

# T10: roster add --team hotfix against a file with both keys -> rosters.hotfix grew, roster untouched
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "hotfix": { "route": "peer", "members": [] } } }
EOF
DEFAULT_BEFORE=$(cat "$REPO_CFG" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(JSON.parse(d).roster)))")
rcli add --no-spawn --team hotfix --level repo --role implementor
check "T10a: add --team hotfix succeeds" '[ "$RC" -eq 0 ]'
DEFAULT_AFTER=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')).roster))")
check "T10b: data.roster byte-identical after add --team hotfix" "[ '$DEFAULT_BEFORE' = '$DEFAULT_AFTER' ]"
check "T10c: data.rosters.hotfix.members grew" \
  "node -e \"process.exit(JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')).rosters.hotfix.members.length===1?0:1)\""

# T11: roster add with no --team -> data.roster grew, rosters untouched
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [] },
  "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } } }
EOF
rcli add --no-spawn --level repo --role architect
check "T11a: add (no --team) succeeds" '[ "$RC" -eq 0 ]'
check "T11b: data.roster.members grew, rosters.hotfix untouched" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit(d.roster.members.length===1 && d.rosters.hotfix.members.length===1 ? 0 : 1)\""

# T12: roster init --team hotfix on a file holding only roster -> creates rosters.hotfix; roster untouched
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
rcli init --team hotfix --level repo --route peer
check "T12a: init --team hotfix succeeds" '[ "$RC" -eq 0 ]'
check "T12b: creates rosters.hotfix, roster untouched" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit(d.rosters && d.rosters.hotfix && d.roster.members.length===1 ? 0 : 1)\""

# T13: roster remove --team hotfix removing the last member -> members:[], block still present
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } } }
EOF
evalc "C.rosterMemberNames([{role:'implementor',model:'sonnet'}], C.teamPrefix('$PROJ','hotfix'))[0].name"
MNAME="$OUT"
rcli remove --team hotfix --level repo --member "$MNAME"
check "T13a: remove --team hotfix succeeds" '[ "$RC" -eq 0 ]'
check "T13b: rosters.hotfix.members is [], block still present" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit(d.rosters && d.rosters.hotfix && Array.isArray(d.rosters.hotfix.members) && d.rosters.hotfix.members.length===0 ? 0 : 1)\""

# T17 [r2, NEW] (spec 0032 §3.4a): rosters.hotfix at repo (members C). create --plan --team
# hotfix, take the member names it reports, then create --commit --team hotfix --verified
# '<those names>' --roster-level repo -> commit succeeds, committed members are C's. Fails
# against a build where --plan reads rosters.hotfix and --commit hydrates from data.roster.
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "hotfix": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } } }
EOF
rcli create --plan --team hotfix
check "T17a: create --plan --team hotfix succeeds" '[ "$RC" -eq 0 ]'
PLAN_NAMES=$(echo "$OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(JSON.parse(d).members.map(m=>m.name))))")
check "T17b: --plan resolved the team-scoped implementor" 'echo "$PLAN_NAMES" | grep -q implementor'
rcli create --commit --team hotfix --verified "$PLAN_NAMES" --roster-level repo --transport terminal --orchestrator-pid "$$"
check "T17c: --commit succeeds with --plan's own member names (§3.4a round trip)" '[ "$RC" -eq 0 ]'
check "T17d: committed team's members are the team-scoped ones (implementor)" 'echo "$OUT" | grep -q implementor'

# T18 [r3, REWRITTEN — was r2's auto-vivify assertion, now the opposite] (spec 0032 §3.4b):
# file with roster (A,B) and NO rosters key. roster add --team hotfix --role implementor, no
# pre-existing rosters.hotfix -> FAILS (no auto-vivification: init is the only creation path).
# data.roster byte-identical AND data.rosters stays absent entirely — "writes nothing anywhere"
# is the stronger assertion than "writes to the right place" (Architect's ruling). Still guards
# §3.4 point 1's teamKey fix: fails the same way whether teamKey comes from teamArg or a
# resolveRoster-derived null, so it no longer distinguishes the two — T17's round trip does.
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" }, { "role": "architect", "model": "opus" } ] } }
EOF
DEFAULT_BEFORE18=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')).roster))")
rcli add --no-spawn --team hotfix --role implementor
check "T18a: add --team hotfix with no pre-existing rosters.hotfix FAILS" '[ "$RC" -ne 0 ]'
DEFAULT_AFTER18=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')).roster))")
check "T18b: data.roster byte-identical (A,B untouched)" "[ '$DEFAULT_BEFORE18' = '$DEFAULT_AFTER18' ]"
check "T18c: data.rosters still absent entirely (nothing written anywhere)" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit(d.rosters === undefined ? 0 : 1)\""

# T19 [r3, NEW] — pairs with T18: proves the guard is a guard, not a dead code path. init --team
# hotfix first, then the SAME add --team hotfix succeeds.
rcli init --team hotfix --level repo --route peer
check "T19a: init --team hotfix succeeds" '[ "$RC" -eq 0 ]'
rcli add --no-spawn --team hotfix --role implementor
check "T19b: add --team hotfix (after init --team hotfix) succeeds" '[ "$RC" -eq 0 ]'
check "T19c: rosters.hotfix has the new member" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit(d.rosters && d.rosters.hotfix && d.rosters.hotfix.members.length===1 ? 0 : 1)\""

# T20 [r3, NEW] (Reviewer-found: init lost its block-reset): init --layout columns, then
# re-init without --layout -> layout clears back to auto (default), not stale "columns".
rcli init --level repo --route peer --layout columns
check "T20a: init --layout columns succeeds" '[ "$RC" -eq 0 ]'
rcli init --level repo --route peer
check "T20b: re-init without --layout succeeds" '[ "$RC" -eq 0 ]'
check "T20c: layout cleared back to auto (no stale columns)" \
  "node -e \"const d=JSON.parse(require('fs').readFileSync('$REPO_CFG','utf8')); process.exit((d.roster.layout||'auto')==='auto'?0:1)\""

# T21 [r3, NEW] (Reviewer-found: F1 fix over-corrected): --team names a team with NO override
# in `rosters` -> create --plan --team hotfix2 hydrates from the default roster (unchanged
# spec §3.3 behavior); create --commit --team hotfix2 --verified <those names> must still find
# them via the string-hydration branch, not fail "it defines: (none)" now that
# rosterContainer(data, teamArg) legitimately returns null for a team with no override.
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
rcli create --plan --team hotfix2
check "T21a: create --plan --team hotfix2 (no override) succeeds" '[ "$RC" -eq 0 ]'
PLAN_NAMES21=$(echo "$OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(JSON.parse(d).members.map(m=>m.name))))")
check "T21b: --plan resolved the default-roster reviewer" 'echo "$PLAN_NAMES21" | grep -q reviewer'
rcli create --commit --team hotfix2 --verified "$PLAN_NAMES21" --roster-level repo --transport terminal --orchestrator-pid "$$"
check "T21c: --commit succeeds for a named team with no override (falls through to default)" '[ "$RC" -eq 0 ]'
check "T21d: committed member is the default-roster reviewer" 'echo "$OUT" | grep -q reviewer'

# T22 [r3, NEW] (Reviewer-found: fallback predicate narrower than resolveRoster's own no-match
# rule): rosters.hotfix3 EXISTS but members: [] (T13's own end state — the last member removed).
# create --plan --team hotfix3 falls through to the default (resolveRoster's own predicate:
# !members.length counts as no-match, not just a missing container); --commit must agree.
writeCfg "$REPO_CFG" <<'EOF'
{ "version": 1,
  "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] },
  "rosters": { "hotfix3": { "route": "peer", "members": [] } } }
EOF
rcli create --plan --team hotfix3
check "T22a: create --plan --team hotfix3 (empty-members override) succeeds" '[ "$RC" -eq 0 ]'
PLAN_NAMES22=$(echo "$OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(JSON.parse(d).members.map(m=>m.name))))")
check "T22b: --plan fell through to the default-roster reviewer" 'echo "$PLAN_NAMES22" | grep -q reviewer'
rcli create --commit --team hotfix3 --verified "$PLAN_NAMES22" --roster-level repo --transport terminal --orchestrator-pid "$$"
check "T22c: --commit succeeds and agrees with --plan (empty-members override falls through)" '[ "$RC" -eq 0 ]'
check "T22d: committed member is the default-roster reviewer" 'echo "$OUT" | grep -q reviewer'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
