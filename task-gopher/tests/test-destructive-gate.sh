#!/bin/bash
# task-gopher destructive-guard regression tests.
# Runs the hook with HOME redirected to a throwaway dir so real config is never touched.
# Usage: bash tests/test-destructive-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-nudge.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-destructive-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PASS=0; FAIL=0

REAL_ALLOW="$(printf '%s' ~)/.claude/task-gopher.allow"
REAL_ALLOW_PRE=0; [ -f "$REAL_ALLOW" ] && REAL_ALLOW_PRE=1

mkdir -p "$FAKEHOME/.claude"

run_hook() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$HOOK" 2>/dev/null); RC=$?; }

check() { # check <name> <condition...>
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:160} RC=$RC)"; fi
}

is_allow() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
is_deny()  { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; }
is_ask()   { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; }

json() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))'; }

# A Bash call made BY the runner: agent_type is what identifies it.
gopher_bash() { # <command> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:task-gopher","prompt_id":"p1","session_id":"%s","tool_input":{"command":%s}}' \
    "${2:-sD}" "$(json "$1")"
}

# The same command run by anyone else — the guard must not touch it.
other_bash() { # <command>
  printf '{"tool_name":"Bash","prompt_id":"p1","session_id":"sD","tool_input":{"command":%s}}' "$(json "$1")"
}

# A Bash call made BY the reasoning runner. Same guard, different agent_type.
smart_bash() { # <command> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:smart-gopher","prompt_id":"p1","session_id":"%s","tool_input":{"command":%s}}' \
    "${2:-sS}" "$(json "$1")"
}
smart_bash_mode() { # <command> <permission_mode> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:smart-gopher","permission_mode":"%s","prompt_id":"p1","session_id":"%s","tool_input":{"command":%s}}' \
    "$2" "${3:-sS}" "$(json "$1")"
}
smart_dispatch() { # <prompt> [session_id]
  printf '{"tool_name":"Agent","prompt_id":"p1","session_id":"%s","tool_input":{"subagent_type":"task-gopher:smart-gopher","prompt":%s}}' \
    "${2:-sS}" "$(json "$1")"
}

# A dispatch TO the runner, whose prompt may carry authorization lines.
dispatch() { # <prompt> [session_id]
  printf '{"tool_name":"Agent","prompt_id":"p1","session_id":"%s","tool_input":{"subagent_type":"task-gopher:task-gopher","prompt":%s}}' \
    "${2:-sD}" "$(json "$1")"
}

# ---- 1. the guard is live with the plugin OFF (no .enabled marker yet).
# This is the whole reason it sits above the ON check: the agent is dispatchable
# whether or not the delegation directive is switched on.
run_hook "$(gopher_bash 'rm -rf /Users/x/proj/dist')"
check "off: rm -rf denied for the runner" is_deny
run_hook "$(gopher_bash 'git worktree remove --force ../wt')"
check "off: forced worktree removal denied (the incident)" is_deny

touch "$FAKEHOME/.claude/task-gopher.enabled"

# ---- 2. destruction, in its usual disguises
for cmd in \
  'rm -rf build' \
  'rm -f notes.txt' \
  'rm *.log' \
  'git reset --hard origin/main' \
  'git clean -fdx' \
  'git worktree remove ../wt' \
  'git worktree prune' \
  'git branch -D feature/x' \
  'git stash clear' \
  'git checkout -- src/' \
  'git restore src/app.ts' \
  'git rebase -i main' \
  'git commit --amend --no-edit' \
  'git filter-branch --tree-filter true HEAD' \
  'find . -name "*.tmp" -delete' \
  'sed -i "" s/a/b/ file.txt' \
  'chmod -R 777 .' \
  'docker system prune -af' \
  'kubectl delete pod web-1' \
  'terraform destroy -auto-approve' \
  'dropdb production'
do
  run_hook "$(gopher_bash "$cmd")"
  check "deny: $cmd" is_deny
done

# ---- 3. outward-facing work is the lead's call too
for cmd in \
  'git push origin main' \
  'git push --force-with-lease' \
  'gh pr create --title x --body y' \
  'gh pr merge 42 --squash' \
  'npm publish' \
  'cargo publish' \
  'curl -X POST https://api.example.com/hook -d @body.json'
do
  run_hook "$(gopher_bash "$cmd")"
  check "deny: $cmd" is_deny
done

# ---- 4. the runner's ACTUAL job must stay completely unimpeded.
# A guard that blocks ordinary legwork gets switched off, and then it protects
# nothing at all.
for cmd in \
  'npm test 2>&1 | tail -40' \
  'npm run build > /tmp/build.log 2>&1; echo "exit=$?"' \
  'grep -rn "class Foo" src/' \
  'rg --json TODO . | head -20' \
  'git status --short' \
  'git diff main...HEAD -- src/' \
  'git log --oneline -20' \
  'git add -A && git commit -m "wip"' \
  'mkdir -p /tmp/scratch && cd /tmp/scratch' \
  'sed -n "1,60p" README.md' \
  'cat pkg.json | head -30' \
  'find . -name "*.mjs" -not -path "*/node_modules/*"' \
  'pytest -q > /tmp/t.log 2>&1' \
  'docker ps -a' \
  'kubectl get pods'
do
  run_hook "$(gopher_bash "$cmd")"
  check "allow (legwork): $cmd" is_allow
done

# ---- 5. a destructive word inside a quoted string is prose, not a command
run_hook "$(gopher_bash 'git commit -m "stop calling rm -rf in the deploy script"')"
check "quoted 'rm -rf' in a commit message is text" is_allow
run_hook "$(gopher_bash 'echo "git push is blocked here" >> notes.md')"
check "quoted 'git push' in an echo is text" is_allow

# ...but a command CARRIED by a wrapper is still a command.
run_hook "$(gopher_bash 'bash -c "rm -rf /tmp/x"')"
check "nested: bash -c carrying rm -rf is caught" is_deny
run_hook "$(gopher_bash 'psql -c "DROP TABLE users"')"
check "nested: psql -c carrying DROP TABLE is caught" is_deny

# ---- 6. per-stage matching: a destructive stage anywhere in a pipeline counts
run_hook "$(gopher_bash 'npm run build && rm -rf dist/cache')"
check "destructive stage in a later position is caught" is_deny

# ---- 7. the guard applies to the RUNNER only.
# Everyone else keeps their own permission system; this plugin has no business
# gating the lead's hands.
run_hook "$(other_bash 'rm -rf /Users/x/proj/dist')"
check "same command from a non-gopher caller is untouched" is_allow

# ---- 8. authorization: verbatim, and nothing but
run_hook "$(dispatch 'Clean the tree.
ALLOW-DESTRUCTIVE: rm -rf /Users/x/proj/node_modules
Then run npm install.')"
check "dispatch carrying an allowance is not itself denied" "[ $RC -eq 0 ] && ! printf '%s' \"\$OUT\" | grep -q 'permissionDecision'"
check "allowance is recorded" "grep -q 'rm -rf /Users/x/proj/node_modules' \"$FAKEHOME/.claude/task-gopher.allow\""

run_hook "$(gopher_bash 'rm -rf /Users/x/proj/node_modules')"
check "authorized command runs" is_allow
run_hook "$(gopher_bash 'rm    -rf   /Users/x/proj/node_modules')"
check "authorization is whitespace-normalized, not byte-exact" is_allow
run_hook "$(gopher_bash 'rm -rf /Users/x/proj/node_modules && npm install')"
check "authorized stage still runs when combined with an innocent one" is_allow
run_hook "$(gopher_bash 'rm -rf /Users/x/proj/src')"
check "a DIFFERENT path is not covered by the allowance" is_deny
run_hook "$(gopher_bash 'rm -rf /Users/x/proj/node_modules' sOTHER)"
check "allowance does not leak across sessions" is_deny

# An allowance must not be inferable from prose — only the marker grants it.
run_hook "$(dispatch 'You may need to run rm -rf /Users/x/proj/tmp to clear it.')"
run_hook "$(gopher_bash 'rm -rf /Users/x/proj/tmp')"
check "a command merely MENTIONED in the order is not authorized" is_deny

# ---- 9. the deny has to leave the runner with somewhere to go
run_hook "$(gopher_bash 'git worktree remove --force ../wt')"
check "deny names the blocked command" "printf '%s' \"\$OUT\" | grep -q 'git worktree remove --force'"
check "deny forbids retrying with a bigger hammer" "printf '%s' \"\$OUT\" | grep -q 'bigger hammer'"
check "deny tells the runner to report back" "printf '%s' \"\$OUT\" | grep -q 'Report back to your lead'"
check "deny names the authorization route" "printf '%s' \"\$OUT\" | grep -q 'ALLOW-DESTRUCTIVE'"

# ---- 10. audit trail
check "block is logged" "grep -q '\"event\":\"destructive-blocked\"' \"$FAKEHOME/.claude/task-gopher.log\""
check "allowance grant is logged" "grep -q '\"event\":\"destructive-allowance\"' \"$FAKEHOME/.claude/task-gopher.log\""
check "authorized execution is logged" "grep -q '\"event\":\"destructive-allowed\"' \"$FAKEHOME/.claude/task-gopher.log\""

# ---- 11. malformed input must never brick the runner's tools
run_hook 'not json at all'
check "garbage payload fails open" is_allow
run_hook '{"tool_name":"Bash","agent_type":"task-gopher:task-gopher","tool_input":{}}'
check "missing command fails open" is_allow

# ---- 12. the agent prompt must carry the rule too.
# The hook is the enforcement, but a runner that never tries is better than one
# that tries and is refused — and the hook cannot follow it into a script.
grep -q 'NEVER destroy, and NEVER publish' "$PLUGIN/agents/task-gopher.md" \
  && { PASS=$((PASS+1)); echo "PASS: agent prompt forbids destruction"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: agent prompt lost the destruction rule"; }
grep -q 'never escalate it to make it succeed' "$PLUGIN/agents/task-gopher.md" \
  && { PASS=$((PASS+1)); echo "PASS: agent prompt forbids escalating a failed command"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: agent prompt lost the no-escalation rule"; }
grep -q 'ALLOW-DESTRUCTIVE' "$PLUGIN/hooks/directive.mjs" \
  && { PASS=$((PASS+1)); echo "PASS: directive tells leads how to authorize"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: directive never explains the authorization route"; }

# ---- 13. asking the user.
# Everything above ran with no permission_mode in the payload, which is the
# "we cannot tell whether a human is reachable" case and must deny. These set
# one, and the guard's whole purpose is that a PERSON accepts the risk.
gopher_bash_mode() { # <command> <permission_mode> [session_id]
  printf '{"tool_name":"Bash","agent_type":"task-gopher:task-gopher","prompt_id":"p1","session_id":"%s","permission_mode":"%s","tool_input":{"command":%s}}' \
    "${3:-sD}" "$2" "$(json "$1")"
}

for m in default acceptEdits plan; do
  run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' "$m")"
  check "$m: destructive command asks the user" is_ask
done

run_hook "$(gopher_bash_mode 'git push origin main' default)"
check "default: outward-facing command asks the user" is_ask

# The load-bearing one. A lead's ALLOW-DESTRUCTIVE line is a MODEL vouching for a
# model; it must not spend the user's consent for them.
run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/node_modules' default)"
check "a lead-authorized command STILL asks the user" is_ask
check "the prompt discloses that the lead pre-authorized it" "printf '%s' \"\$OUT\" | grep -q 'pre-authorized this exact command'"

run_hook "$(gopher_bash_mode 'git worktree remove --force ../wt' default)"
check "prompt names the command" "printf '%s' \"\$OUT\" | grep -q 'git worktree remove --force'"
check "prompt says the runner cannot judge it" "printf '%s' \"\$OUT\" | grep -q 'makes no judgments'"
check "prompt is marked destructive" "printf '%s' \"\$OUT\" | grep -q 'DESTRUCTIVE'"

# Modes that exist to STOP asking: nobody is there to consent, so deny.
for m in bypassPermissions dontAsk auto; do
  run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' "$m")"
  check "$m: no human to ask -> denied, not asked" is_deny
  check "$m: deny explains why it could not ask" "printf '%s' \"\$OUT\" | grep -q 'permission mode'"
done

run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/node_modules' bypassPermissions)"
check "bypassPermissions: the lead's written authorization still releases it" is_allow

run_hook "$(gopher_bash_mode 'npm test | tail -20' default)"
check "ordinary legwork is never asked about" is_allow

check "ask is logged" "grep -q '\"event\":\"destructive-ask\"' \"$FAKEHOME/.claude/task-gopher.log\""
check "an unaskable block records why" "grep -q '\"why\":\"no-human:bypassPermissions\"' \"$FAKEHOME/.claude/task-gopher.log\""

# ---- 14. guard modes
printf 'block\n' > "$FAKEHOME/.claude/task-gopher.guard"
run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' default)"
check "guard=block: denies instead of asking, even with a human present" is_deny
check "guard=block: does not blame the permission mode" "! printf '%s' \"\$OUT\" | grep -q 'permission mode'"
run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/node_modules' default)"
check "guard=block: the lead's authorization is the release valve" is_allow
check "block is logged with its reason" "grep -q '\"why\":\"guard-mode:block\"' \"$FAKEHOME/.claude/task-gopher.log\""

printf 'off\n' > "$FAKEHOME/.claude/task-gopher.guard"
run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' default)"
check "guard=off: nothing is gated" is_allow

printf 'nonsense\n' > "$FAKEHOME/.claude/task-gopher.guard"
run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' default)"
check "unrecognized guard value falls back to asking, not to off" is_ask
rm -f "$FAKEHOME/.claude/task-gopher.guard"

# ---- 15. the user has to be able to see and change what the guard is doing.
# A mode nobody can read or set is a mode nobody trusts, and an audit report
# that counts only denials hides what the guard actually cost in interruptions.
doc() { # <label> <pattern> <file>
  grep -q "$2" "$PLUGIN/$3" \
    && { PASS=$((PASS+1)); echo "PASS: $1"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
}
doc "command doc offers guard ask"          'guard ask'            commands/task-gopher.md
doc "command doc offers guard block"        'guard block'          commands/task-gopher.md
doc "command doc offers guard off"          'guard off'            commands/task-gopher.md
doc "guard is advertised in the usage line" 'guard \[ask|block'    commands/task-gopher.md
doc "report counts the asks"                'destructive-ask'      hooks/report.mjs
doc "agent prompt says a person is asked"   'interrupts the USER'  agents/task-gopher.md

# The two manifests must agree, or the marketplace installs a version that does
# not exist. Same rule as every other plugin in this repo.
PV=$(grep -o '"version": *"[^"]*"' "$PLUGIN/.claude-plugin/plugin.json" | head -1 | grep -o '[0-9][^"]*')
MV=$(grep -A6 '"name": *"task-gopher"' "$PLUGIN/../.claude-plugin/marketplace.json" \
       | grep -o '"version": *"[^"]*"' | head -1 | grep -o '[0-9][^"]*')
check "plugin.json and marketplace.json agree on the version ($PV vs $MV)" \
  "[ -n \"$PV\" ] && [ \"$PV\" = \"$MV\" ]"

# ---- 16. real config must be untouched
REAL_ALLOW_POST=0; [ -f "$REAL_ALLOW" ] && REAL_ALLOW_POST=1
check "test wrote no allowance into the real HOME" "[ $REAL_ALLOW_PRE -eq $REAL_ALLOW_POST ]"

# ---- 17. smart-gopher: same guard, and the D8-D11 group is the regression test
# for the "task-gopher:smart-gopher" substring collision (§2 of the spec) — a
# task-gopher-first test would misclassify every smart-gopher dispatch as the
# Haiku runner, which is invisible for a boolean gate but wrong in the one place
# it matters most: the permission dialog.
run_hook "$(smart_bash 'rm -rf /Users/x/proj/dist')"
check "D1: guard live for smart-gopher regardless of plugin toggle" is_deny

touch "$FAKEHOME/.claude/task-gopher.enabled"

run_hook "$(smart_bash 'git push origin main')"
check "D2: smart-gopher outward-facing command denied" is_deny
run_hook "$(smart_bash 'git worktree remove --force ../wt')"
check "D3: smart-gopher destructive command denied" is_deny
run_hook "$(smart_bash 'npm test | tail -20')"
check "D4: smart-gopher benign work never gated" is_allow
run_hook "$(smart_bash_mode 'rm -rf /Users/x/proj/node_modules' default)"
check "D5: smart-gopher destructive command asks when a human is reachable" is_ask
run_hook "$(smart_bash_mode 'rm -rf /Users/x/proj/node_modules' bypassPermissions)"
check "D6: smart-gopher denied outright with nobody to ask" is_deny

run_hook "$(smart_dispatch 'ALLOW-DESTRUCTIVE: rm -rf /Users/x/proj/node_modules')"
run_hook "$(smart_bash_mode 'rm -rf /Users/x/proj/node_modules' bypassPermissions)"
check "D7: the release valve works for smart-gopher" is_allow

run_hook "$(smart_bash_mode 'rm -rf /Users/x/proj/dist' default)"
check "D8: naming — dialog names smart-gopher" "printf '%s' \"\$OUT\" | grep -q 'smart-gopher'"
check "D9: naming, negative — the ordering trap does not misname it" "! printf '%s' \"\$OUT\" | grep -q 'the Haiku runner'"
check "D10: honesty — the caveat must not lie about a Sonnet agent" "! printf '%s' \"\$OUT\" | grep -q 'makes no judgments'"

run_hook "$(gopher_bash_mode 'rm -rf /Users/x/proj/dist' default)"
check "D11: task-gopher's own dialog is unchanged (asks)" is_ask
check "D11: task-gopher's own dialog is unchanged (names the Haiku runner)" "printf '%s' \"\$OUT\" | grep -q 'the Haiku runner'"

run_hook "$(other_bash 'rm -rf /Users/x/proj/dist')"
check "D12: an ordinary agent is still untouched" is_allow

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
