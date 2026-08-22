#!/bin/bash
# agent-hierarchy — roster level resolution: rosterLevelPaths, resolveRoster
# whole-level-replace precedence (repo-user > repo > global), skip-empty/invalid.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-roster-levels.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-levels-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
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

REPO_USER_PATH="$FAKEHOME/.claude/agent-hierarchy/projects/$(echo "$PROJ" | sed 's,/,-,g')/agent-hierarchy.json"

evalc "JSON.stringify(C.rosterLevelPaths('$PROJ'))"
check "rosterLevelPaths: global/repo/repo-user paths" \
  "echo \"\$OUT\" | grep -q \"$FAKEHOME/.claude/agent-hierarchy.json\" && echo \"\$OUT\" | grep -q \"$PROJ/.claude/agent-hierarchy.json\" && echo \"\$OUT\" | grep -q \"$(echo "$REPO_USER_PATH" | sed 's/[\/&]/\\&/g')\""

# no roster anywhere -> null
evalc "C.resolveRoster('$PROJ')"
check "resolveRoster: none configured -> null" '[ "$OUT" = null ]'

# global only
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "C.resolveRoster('$PROJ').level"
check "resolveRoster: global roster resolves when nothing else exists" '[ "$OUT" = global ]'

# repo overrides global (whole-level replace, not merge: repo has NO reviewer)
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "subagent", "members": [ { "role": "architect", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$PROJ').level, roles: C.resolveRoster('$PROJ').members.map(m => m.role)})"
check "resolveRoster: repo replaces global wholesale (global's reviewer is gone, not merged)" \
  'echo "$OUT" | grep -q "\"level\":\"repo\"" && echo "$OUT" | grep -q "\[\"architect\"\]"'

# repo-user overrides repo
mkdir -p "$(dirname "$REPO_USER_PATH")"
cat > "$REPO_USER_PATH" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$PROJ').level, roles: C.resolveRoster('$PROJ').members.map(m => m.role)})"
check "resolveRoster: repo-user is highest precedence, replaces repo wholesale" \
  'echo "$OUT" | grep -q "\"level\":\"repo-user\"" && echo "$OUT" | grep -q "\[\"implementor\"\]"'

# repo-user with empty members array is skipped, falls through to repo
cat > "$REPO_USER_PATH" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [] } }
EOF
evalc "C.resolveRoster('$PROJ').level"
check "resolveRoster: empty-members repo-user roster is skipped, falls through to repo" '[ "$OUT" = repo ]'

# malformed JSON at a level is skipped, falls through
cat > "$REPO_USER_PATH" <<'EOF'
{ not valid json
EOF
evalc "C.resolveRoster('$PROJ').level"
check "resolveRoster: malformed JSON at a level is skipped, falls through" '[ "$OUT" = repo ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
