#!/bin/bash
# agent-hierarchy — suites never inherit the invoking session's CLAUDE_PID: every tests/*.sh that
# unsets AH_TEAM_FILE also unsets CLAUDE_PID, so a check that needs an orchestrator pid sets it
# itself and the suite passes the same inside and outside a Claude session.
# Usage: bash tests/test-suite-hermeticity.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-suite-hermeticity-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:500})"; fi
}

# Each *.sh in <dir> that unsets AH_TEAM_FILE but never CLAUDE_PID, one per line.
lint() {
  local f
  for f in "$1"/*.sh; do
    grep -qE '^[[:space:]]*(export PATH=[^;]*;[[:space:]]*)?unset[[:space:]]([^#]*[[:space:]])?AH_TEAM_FILE([[:space:];]|$)' "$f" || continue
    grep -qE '^[[:space:]]*(export PATH=[^;]*;[[:space:]]*)?unset[[:space:]]([^#]*[[:space:]])?CLAUDE_PID([[:space:];]|$)' "$f" || basename "$f"
  done
}

OUT=$(lint "$PLUGIN/tests")
check "T-H3: every suite that unsets AH_TEAM_FILE also unsets CLAUDE_PID" '[ -z "$OUT" ]'

mkdir -p "$SANDBOX/scratch"
printf '#!/bin/bash\nunset AH_TEAM_FILE  # x\necho hi\n' > "$SANDBOX/scratch/test-only-team-file.sh"
printf '#!/bin/bash\nunset AH_TEAM_FILE  # x\nunset CLAUDE_PID  # x\n' > "$SANDBOX/scratch/test-both-lines.sh"
printf '#!/bin/bash\nexport PATH="/x:$PATH"; unset HERDR_ENV AH_TEAM_FILE CLAUDE_PID\n' > "$SANDBOX/scratch/test-both-one-line.sh"
printf '#!/bin/bash\nunset AH_TEAM_FILE\n# unset CLAUDE_PID only in a comment\n' > "$SANDBOX/scratch/test-comment-only.sh"
printf '#!/bin/bash\necho no unsets here\n' > "$SANDBOX/scratch/test-neither.sh"
OUT=$(lint "$SANDBOX/scratch" | sort | tr '\n' ' ')
check "T-H3: the lint names a suite that unsets only AH_TEAM_FILE, or names CLAUDE_PID only in a comment, and nothing else" \
  '[ "$OUT" = "test-comment-only.sh test-only-team-file.sh " ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
