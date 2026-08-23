#!/bin/bash
# agent-hierarchy — derived roster member names (spec 0001 §3.4): ordinal-1 of
# a role = peerName(repoBasename, role); ordinal 2+ get a -2, -3, ... suffix,
# in array order. Names are derived, never stored.
# Usage: bash tests/test-roster-names.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

evalc() { # <js over lib-config as C>
  OUT=$(node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

evalc "JSON.stringify(C.rosterMemberNames([{role:'reviewer'},{role:'reviewer'},{role:'implementor'}], 'myrepo').map(m => m.name))"
check "single reviewer -> peerName; second reviewer -> -2 suffix; implementor unaffected" \
  '[ "$OUT" = "[\"myrepo-reviewer\",\"myrepo-reviewer-2\",\"myrepo-implementor\"]" ]'

evalc "JSON.stringify(C.rosterMemberNames([{role:'reviewer'},{role:'reviewer'},{role:'reviewer'}], 'myrepo').map(m => m.name))"
check "three reviewers -> base, -2, -3 in array order" \
  '[ "$OUT" = "[\"myrepo-reviewer\",\"myrepo-reviewer-2\",\"myrepo-reviewer-3\"]" ]'

evalc "C.rosterMemberNames([{role:'architect', model:'opus'}], 'myrepo')[0].model"
check "rosterMemberNames preserves the member's other fields" '[ "$OUT" = opus ]'

evalc "JSON.stringify(C.rosterMemberNames([], 'myrepo'))"
check "empty members -> empty array" '[ "$OUT" = "[]" ]'

# ==== 12 — teamPrefix(cwd) with no teamAlias set anywhere: falls back to the
# git-root basename (spec 0010 §3), the same value the old repoBasename
# derivations used to compute directly.
NAMEDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-teamprefix-test.XXXXXX")"
trap 'rm -rf "$NAMEDIR"' EXIT
NAMEDIR="$(cd "$NAMEDIR" && pwd -P)"
TEAMPREFIX_REPO="$NAMEDIR/some-repo-name"
mkdir -p "$TEAMPREFIX_REPO"
(cd "$TEAMPREFIX_REPO" && git init -q)
evalc "C.teamPrefix('$TEAMPREFIX_REPO')"
check "12: teamPrefix with no teamAlias -> basename of the git root" '[ "$OUT" = some-repo-name ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
