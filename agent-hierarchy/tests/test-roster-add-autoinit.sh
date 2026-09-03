#!/bin/bash
# agent-hierarchy — spec 0038: bare `roster.mjs add <role>` with no roster anywhere bootstraps a
# minimal one (init's own writer, one serializer) instead of failing "run init first". `--team X`
# with no container still errors (0032 §3.4b) — auto-init does not extend to named teams.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-add-autoinit.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-add-autoinit-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

new_repo() { # <dir>
  mkdir -p "$1/.claude"
  (cd "$1" && git init -q && git config user.email t@t.com && git config user.name t)
}

rcli() { # <repo> <roster.mjs argv...>
  local repo=$1; shift
  OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$repo" 2>&1); RC=$?
}

roles_in() { # <cfg path> <container: roster | rosters.X> -> comma-joined role list
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const c = process.argv[2] === "roster" ? d.roster : (d.rosters || {})[process.argv[2].slice(8)];
    process.stdout.write(c && Array.isArray(c.members) ? c.members.map((m) => m.role).join(",") : "<none>");
  ' "$1" "$2"
}

# ---- T1: scratch repo, no config anywhere; `add reviewer` -> exit 0, repo-level file created with
# exactly the reviewer role, creation notice printed. Falsifying core — fails on the unmodified tree
# with exit 2 "run init first". ----
T1="$SANDBOX/t1"; new_repo "$T1"
T1_CFG="$T1/.claude/agent-hierarchy.json"
rcli "$T1" add --no-spawn --role reviewer
check "T1: bare add with no roster anywhere exits 0" '[ "$RC" -eq 0 ]'
check "T1: roster file created at repo level" '[ -f "$T1_CFG" ]'
check "T1: contains exactly the reviewer role" '[ "$(roles_in "$T1_CFG" roster)" = "reviewer" ]'
check "T1: creation notice names the absolute path" 'echo "$OUT" | grep -q "created a minimal one" && echo "$OUT" | grep -qF "$T1_CFG"'
check "T1: nothing written at global level" '[ ! -f "$FAKEHOME/.claude/agent-hierarchy.json" ]'

# ---- T2: explicit --level honoured — spec 0038 names `--level user`; ROSTER_LEVELS has no such
# level (repo-user | repo | global), so this exercises the user-wide file, `global`
# (~/.claude/agent-hierarchy.json). Flagged in the implementation report as a spec gap. ----
T2="$SANDBOX/t2"; new_repo "$T2"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"
rcli "$T2" add --no-spawn --role reviewer --level global
check "T2: add --level global with no roster exits 0" '[ "$RC" -eq 0 ]'
check "T2: file created at the explicit (global) level" '[ -f "$GLOBAL_CFG" ] && [ "$(roles_in "$GLOBAL_CFG" roster)" = "reviewer" ]'
check "T2: not created at repo level" '[ ! -f "$T2/.claude/agent-hierarchy.json" ]'
rm -f "$GLOBAL_CFG"

# ---- T3: no config; `add reviewer --team X` -> exit non-zero, points at init — auto-init must NOT
# extend to named teams (0032 §3.4b). Mutation: fails against an implementation that auto-vivifies
# `rosters.X`. ----
T3="$SANDBOX/t3"; new_repo "$T3"
rcli "$T3" add --no-spawn --role reviewer --team X
check "T3: add --team X with nothing anywhere exits non-zero" '[ "$RC" -ne 0 ]'
check "T3: error names init as the remedy" 'echo "$OUT" | grep -q "init"'
check "T3: no roster file was created" '[ ! -f "$T3/.claude/agent-hierarchy.json" ]'
# ...and with a default roster present but no rosters.X — still refused, nothing auto-vivified.
rcli "$T3" add --no-spawn --role reviewer
rcli "$T3" add --no-spawn --role architect --team X
check "T3b: add --team X with a default roster but no rosters.X exits non-zero" '[ "$RC" -ne 0 ]'
check "T3b: rosters.X was not auto-vivified" '[ "$(roles_in "$T3/.claude/agent-hierarchy.json" rosters.X)" = "<none>" ]'

# ---- T4: roster already exists; `add implementor` -> byte-identical to today: no creation notice,
# normal append. ----
T4="$SANDBOX/t4"; new_repo "$T4"
T4_CFG="$T4/.claude/agent-hierarchy.json"
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route subagent --cwd "$T4" >/dev/null
rcli "$T4" add --no-spawn --role implementor
check "T4: add against an existing roster exits 0" '[ "$RC" -eq 0 ]'
check "T4: no creation notice" '! echo "$OUT" | grep -q "created a minimal one"'
check "T4: appended to the existing (subagent-route) block, route untouched" \
  '[ "$(roles_in "$T4_CFG" roster)" = "implementor" ] && grep -q "\"route\": \"subagent\"" "$T4_CFG"'

# ---- T5 (structural): add's creation path routes through the same writer init uses — no second
# serialization of the roster shape. ----
INIT_CASE=$(sed -n '/case "init": {/,/case "add": {/p' "$H/roster.mjs")
ADD_CASE=$(sed -n '/case "add": {/,/case "edit": {/p' "$H/roster.mjs")
check "T5: init builds its block via freshRosterBlock + installRosterBlock" \
  'echo "$INIT_CASE" | grep -q "freshRosterBlock(" && echo "$INIT_CASE" | grep -q "installRosterBlock("'
check "T5: add's auto-init path calls the same two functions" \
  'echo "$ADD_CASE" | grep -q "freshRosterBlock(" && echo "$ADD_CASE" | grep -q "installRosterBlock("'
check "T5: the roster-block literal ({ route, members: [] }) is serialized in exactly one place" \
  '[ "$(grep -c "{ route, members: \[\] }" "$H/roster.mjs")" -eq 1 ]'

# ---- T6: second add after T1's auto-init appends; does not re-create or clobber. ----
rcli "$T1" add --no-spawn --role architect
check "T6: second add exits 0" '[ "$RC" -eq 0 ]'
check "T6: no second creation notice" '! echo "$OUT" | grep -q "created a minimal one"'
check "T6: both roles present, in order" '[ "$(roles_in "$T1_CFG" roster)" = "reviewer,architect" ]'

# ---- T7 (0038 §1.1 ruling): bare add with no git root and no roster anywhere -> refused, nothing
# written at global, error names `--level global` as the escape. ----
T7="$SANDBOX/t7-nogit"; mkdir -p "$T7"
rcli "$T7" add --no-spawn --role reviewer
check "T7: bare add outside any repo exits non-zero" '[ "$RC" -ne 0 ]'
check "T7: error names --level global as the remedy" 'echo "$OUT" | grep -q -- "--level global"'
check "T7: nothing auto-created at global level" '[ ! -f "$FAKEHOME/.claude/agent-hierarchy.json" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
