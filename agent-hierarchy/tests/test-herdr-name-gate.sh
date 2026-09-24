#!/usr/bin/env bash
# pretooluse-herdr-name-gate.mjs: a raw `herdr agent start <name>` with a name Herdr would reject
# is denied before it runs; every other Bash call passes untouched. HOME-redirected.
set -u
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$PLUGIN/hooks/pretooluse-herdr-name-gate.mjs"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1 (OUT=$OUT)"; fi; }
gate() { # <bash command>
  OUT=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1" | HOME="$SANDBOX" node "$GATE" 2>&1); RC=$?
}
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }

gate 'herdr agent start abcdefghij-abcdefghij-abcdefghij-xyz --kind claude --pane w1:p7 -- --agent ah:implementor'
check "a 36-character name is denied, naming the rule and its length" 'denied && echo "$OUT" | grep -q "1-32 characters" && echo "$OUT" | grep -q "is 36 characters"'
check "...and the deny says to reuse the already-split pane" 'echo "$OUT" | grep -q "Pane w1:p7 is still empty"'

gate 'herdr agent start Claudetools-architect --kind claude --pane p2'
check "an uppercase name is denied" 'denied'

gate 'herdr agent start --kind claude --pane p2 abcdefghij-abcdefghij-abcdefghij-xyz'
check "the name is found after leading flags" 'denied'

gate 'herdr pane split --pane p1 --direction right && herdr agent start "abcdefghij-abcdefghij-abcdefghij-xyz" --kind claude --pane p3'
check "a quoted name in a chained command is denied" 'denied'

gate 'herdr agent start claudetools-ui-implementor --kind claude --pane p2 -- --agent ui-implementor'
check "a valid name passes silently" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

gate 'echo herdr agent start is documented; ls'
check "a command with no name after start passes" '[ "$RC" -eq 0 ] && ! denied'

gate 'git status'
check "an unrelated Bash call passes silently" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

OUT=$(printf 'not json' | HOME="$SANDBOX" node "$GATE" 2>&1); RC=$?
check "unparseable input fails open" '[ "$RC" -eq 0 ] && ! denied'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
