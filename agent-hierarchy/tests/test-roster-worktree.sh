#!/bin/bash
# agent-hierarchy — worktree roster resolution (spec 0027): from a linked worktree,
# resolveRoster also considers the main checkout's repo/repo-user paths, at lower
# precedence than the worktree's own. HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-worktree.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-worktree-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
MAIN="$SANDBOX/main"
WT="$SANDBOX/wt"
mkdir -p "$FAKEHOME/.claude" "$MAIN"
(cd "$MAIN" && git init -q && git config user.email t@t.com && git config user.name t && touch f && git add f && git commit -qm init)
git -C "$MAIN" worktree add -q "$WT" -b wt-branch >/dev/null
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

evalc "C.pathSlug('$MAIN')"
MAIN_SLUG="$OUT"
REPO_USER_MAIN="$FAKEHOME/.claude/agent-hierarchy/projects/$MAIN_SLUG/agent-hierarchy.json"

# T1: roster ONLY at the main root's repo level -> worktree resolves it
mkdir -p "$MAIN/.claude"
cat > "$MAIN/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$WT') && C.resolveRoster('$WT').level, path: C.resolveRoster('$WT') && C.resolveRoster('$WT').path})"
check "T1: worktree resolves a repo roster that exists only at the main root" \
  "echo \"\$OUT\" | grep -q '\"level\":\"repo\"' && echo \"\$OUT\" | grep -q \"$(echo "$MAIN/.claude/agent-hierarchy.json" | sed 's/[\/&]/\\&/g')\""
rm "$MAIN/.claude/agent-hierarchy.json"

# T2: roster ONLY at the main root's repo-user level -> worktree resolves it
mkdir -p "$(dirname "$REPO_USER_MAIN")"
cat > "$REPO_USER_MAIN" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "architect", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$WT').level, path: C.resolveRoster('$WT').path})"
check "T2: worktree resolves a repo-user roster that exists only at the main root's slug" \
  "echo \"\$OUT\" | grep -q '\"level\":\"repo-user\"' && echo \"\$OUT\" | grep -q \"$(echo "$REPO_USER_MAIN" | sed 's/[\/&]/\\&/g')\""
rm "$REPO_USER_MAIN"

# T9: the ordering case flagged as easy to get subtly wrong — repo-user@mainRoot vs repo@worktreeRoot
# simultaneously. Location-major order still keeps repo-user ahead of repo WITHIN each location, so a
# main-root repo-user roster must outrank a worktree's own repo roster.
mkdir -p "$(dirname "$REPO_USER_MAIN")" "$WT/.claude"
cat > "$REPO_USER_MAIN" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "architect", "model": "opus" } ] } }
EOF
cat > "$WT/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$WT').level, path: C.resolveRoster('$WT').path})"
check "T9: repo-user@mainRoot outranks repo@worktreeRoot (repo-user precedence holds across locations)" \
  "echo \"\$OUT\" | grep -q '\"level\":\"repo-user\"' && echo \"\$OUT\" | grep -q \"$(echo "$REPO_USER_MAIN" | sed 's/[\/&]/\\&/g')\""
rm "$REPO_USER_MAIN" "$WT/.claude/agent-hierarchy.json"

# T3: rosters at BOTH worktree and main-root repo level, distinguishable -> worktree's wins
cat > "$WT/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "implementor", "model": "sonnet" } ] } }
EOF
mkdir -p "$MAIN/.claude"
cat > "$MAIN/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" }, { "role": "architect", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$WT').level, roles: C.resolveRoster('$WT').members.map(m => m.role)})"
check "T3: worktree's own repo roster wins over the main root's when both are present" \
  'echo "$OUT" | grep -q "\[\"implementor\"\]"'
rm "$WT/.claude/agent-hierarchy.json" "$MAIN/.claude/agent-hierarchy.json"

# T4: normal (non-worktree) checkout — regression guard, resolution unchanged
NORMAL="$SANDBOX/normal"
mkdir -p "$NORMAL/.claude"
(cd "$NORMAL" && git init -q)
cat > "$NORMAL/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "JSON.stringify({level: C.resolveRoster('$NORMAL').level, path: C.resolveRoster('$NORMAL').path})"
check "T4: normal checkout resolves its own repo roster, unaffected" \
  "echo \"\$OUT\" | grep -q '\"level\":\"repo\"' && echo \"\$OUT\" | grep -q \"$(echo "$NORMAL/.claude/agent-hierarchy.json" | sed 's/[\/&]/\\&/g')\""

# T5: worktree, nothing at worktree or main-root levels, roster only at global
cat > "$FAKEHOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "C.resolveRoster('$WT').level"
check "T5: worktree falls through to global when nothing at worktree or main root" '[ "$OUT" = global ]'
rm "$FAKEHOME/.claude/agent-hierarchy.json"

# T6: submodule guard — a REAL `git submodule add` fixture (submodules default to a RELATIVE
# `gitdir:` pointer, exercising `resolve(worktreeRoot, ptr)`'s relative branch), with a roster
# planted at the superproject root. Resolution from inside the submodule must NOT reach it.
SUPER="$SANDBOX/super"
SUBSRC="$SANDBOX/subsrc"
mkdir -p "$SUPER" "$SUBSRC"
(cd "$SUBSRC" && git init -q && git config user.email t@t.com && git config user.name t && touch g && git add g && git commit -qm init)
(cd "$SUPER" && git init -q && git config user.email t@t.com && git config user.name t && touch h && git add h && git commit -qm init)
git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$SUBSRC" submod >/dev/null 2>&1
mkdir -p "$SUPER/.claude"
cat > "$SUPER/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "JSON.stringify(C.resolveRoster('$SUPER/submod'))"
check "T6: a real (relative-pointer) submodule does not bind to the superproject's roster" '[ "$OUT" = null ]'
rm "$SUPER/.claude/agent-hierarchy.json"

# T7: .git file unreadable/malformed — no throw, degrades to a single (own-root) candidate
MALFORMED="$SANDBOX/malformed"
mkdir -p "$MALFORMED"
echo "not a gitdir line" > "$MALFORMED/.git"
evalc "JSON.stringify(C.rosterLevelCandidates('$MALFORMED').repo.length)"
check "T7: a malformed .git file does not throw and degrades to a single candidate" '[ "$RC" -eq 0 ] && [ "$OUT" = 1 ]'

# T8: bare-repo-linked worktree (spec §3.1) — a roster placed BESIDE the bare repo (the position
# the un-guarded code would bind to) must NOT be reachable from a worktree linked off that bare repo.
BARE_DIR="$SANDBOX/baretest"
mkdir -p "$BARE_DIR"
git clone -q --bare "$MAIN" "$BARE_DIR/repo.git"
git -C "$BARE_DIR/repo.git" worktree add -q "$BARE_DIR/wt" >/dev/null
mkdir -p "$BARE_DIR/.claude"
cat > "$BARE_DIR/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "roster": { "route": "peer", "members": [ { "role": "reviewer", "model": "opus" } ] } }
EOF
evalc "JSON.stringify(C.resolveRoster('$BARE_DIR/wt'))"
check "T8: bare-repo-linked worktree does not bind to the roster beside the bare repo (§3.1 guard)" '[ "$OUT" = null ]'

# T14 (spec 0032 §2.1/§4, "the closed gap"): worktree; per-role model config ONLY at
# <mainRoot>/.claude/agent-hierarchy.json; resolve from the worktree -> resolveConfig
# finds it, sources[role] !== "default". Pre-fix this failed (source: "default") — see
# spec 0032 §7 item 1's evidence, run separately against the unmodified tree.
mkdir -p "$MAIN/.claude"
cat > "$MAIN/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "roles": { "architect": { "model": "sonnet" } } }
EOF
evalc "JSON.stringify({model: C.resolveConfig('$WT').roles.architect.model, source: C.resolveConfig('$WT').sources.architect})"
check "T14: resolveConfig finds the main checkout's role config from inside a worktree" \
  'echo "$OUT" | grep -q "\"model\":\"sonnet\"" && echo "$OUT" | grep -q "\"source\":\"project\""'

# T15: spec 0032's own §6 prose for this case ("roles come from the main root rather than
# defaults") CONTRADICTS its own §4 fix code and §4.2 text. §4's `firstExisting` picks the
# first EXISTING candidate per scope and does NOT merge/fall through past it (§4:
# "Deliberately NOT merging across candidates within a level... one layer per scope, is the
# minimal change"); §4.2 separately states "configured's presence-only gate (§2.2) stays" —
# unfixed, on purpose. So a worktree-local file that exists (even with only teamAlias, no
# roles) wins the `project` scope outright and the main root's `roles` are never consulted —
# ROLE_DEFAULTS apply, exactly as §4.2 says stays true. Asserting the spec's own §4 code,
# not its §6 prose for this row — see the implementation report for the flagged contradiction.
mkdir -p "$WT/.claude"
cat > "$WT/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "teamAlias": "wtonly" }
EOF
evalc "JSON.stringify({model: C.resolveConfig('$WT').roles.architect.model, configured: C.resolveConfig('$WT').configured})"
check "T15: worktree-local presence-only file wins its scope outright, per §4/§4.2 (contradicts §6 prose — flagged)" \
  'echo "$OUT" | grep -q "\"model\":\"opus\"" && echo "$OUT" | grep -q "\"configured\":true"'
rm "$WT/.claude/agent-hierarchy.json" "$MAIN/.claude/agent-hierarchy.json"

# T16: normal checkout, config at <root>/.claude/..., cwd = root -> resolveConfig unchanged (Fix 2 regression guard)
NORMAL2="$SANDBOX/normal2"
mkdir -p "$NORMAL2/.claude"
(cd "$NORMAL2" && git init -q)
cat > "$NORMAL2/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "roles": { "reviewer": { "model": "sonnet" } } }
EOF
evalc "JSON.stringify({model: C.resolveConfig('$NORMAL2').roles.reviewer.model, source: C.resolveConfig('$NORMAL2').sources.reviewer, configured: C.resolveConfig('$NORMAL2').configured})"
check "T16: normal checkout resolveConfig output unaffected by Fix 2" \
  'echo "$OUT" | grep -q "\"model\":\"sonnet\"" && echo "$OUT" | grep -q "\"source\":\"project\"" && echo "$OUT" | grep -q "\"configured\":true"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
