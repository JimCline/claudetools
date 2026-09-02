#!/bin/bash
# review-guide — CLI test suite (spec 0002 §10.2).
# HOME-redirect + temp git repo; real state untouched.
# Usage: bash tests/test-review-guide.sh   (exits 0 iff all cases pass)

set -u
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$PLUGIN/bin/guide.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/review-guide-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=${RC:-?} OUT=${OUT:0:400})"; fi
}

g() { OUT=$(HOME="$FAKEHOME" node "$GUIDE" "$@" 2>&1); RC=$?; }

# A repo with a fake "gh" on PATH that fails loudly if invoked (test 9).
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
echo "gh SHOULD NEVER BE INVOKED BY review-guide" >&2
exit 99
EOF
chmod +x "$BIN/gh"

PATH_ORIG="$PATH"

new_repo() { # <dir>
  mkdir -p "$1"
  (cd "$1" && git init -q -b main && git config user.email t@t.test && git config user.name t)
}
commit_all() { (cd "$1" && git add -A && git commit -q -m "$2"); }

REPO="$SANDBOX/repo"
new_repo "$REPO"
echo "hello" > "$REPO/README.md"
commit_all "$REPO" "init"

# ---- 1: fresh repo, note writes base then note; ledger under --git-common-dir
COMMON=$(cd "$REPO" && git rev-parse --git-common-dir)
COMMON_ABS="$(cd "$REPO" && cd "$(dirname "$COMMON")" 2>/dev/null && pwd)/$(basename "$COMMON")"
echo "content1" > "$REPO/a.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "added a.txt" a.txt); RC=$?; OUT=""
LEDGER="$REPO/.git/review-guide/main.jsonl"
check "1: note exits zero" '[ $RC -eq 0 ]'
check "1: ledger file created under git-common-dir" '[ -f "$LEDGER" ]'
check "1: ledger has a base record then a note record" '
  [ "$(sed -n 1p "$LEDGER" | node -e "console.log(JSON.parse(require(\"fs\").readFileSync(0)).kind)")" = "base" ] &&
  [ "$(sed -n 2p "$LEDGER" | node -e "console.log(JSON.parse(require(\"fs\").readFileSync(0)).kind)")" = "note" ]
'

# ---- 2: worktree behaviour (Fix B)
WT="$SANDBOX/wt-feat"
(cd "$REPO" && git branch feat-y && git worktree add -q "$WT" feat-y)
echo "feat content" > "$WT/b.txt"
(cd "$WT" && HOME="$FAKEHOME" node "$GUIDE" note "worked on feat-y" b.txt) >/dev/null 2>&1
check "2: worktree ledger is a distinct file from main's" '[ -f "$REPO/.git/review-guide/feat-y.jsonl" ] && [ -f "$REPO/.git/review-guide/main.jsonl" ]'
(cd "$WT" && HOME="$FAKEHOME" node "$GUIDE" guide) > /tmp/rg-wt-guide.log 2>&1
WT_GUIDE_PATH=$(grep -o '/.*feat-y.guide.md' /tmp/rg-wt-guide.log | head -1)
check "2: guide run in worktree compiles feat-y" '[ -n "$WT_GUIDE_PATH" ] && grep -q "b.txt" "$WT_GUIDE_PATH"'
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" guide) > /tmp/rg-main-guide.log 2>&1
MAIN_GUIDE_PATH=$(grep -o '/.*main.guide.md' /tmp/rg-main-guide.log | head -1)
check "2: guide run in main checkout compiles main" '[ -n "$MAIN_GUIDE_PATH" ]'
(cd "$REPO" && git worktree remove -f "$WT")
check "2: worktree branch ledger survives worktree remove" '[ -f "$REPO/.git/review-guide/feat-y.jsonl" ]'

# ---- 3: base with push -u (Fix A)
BARE="$SANDBOX/bare.git"
git init -q --bare "$BARE"
(cd "$REPO" && git remote add origin "$BARE" && git push -q -u origin main)
BR3="$SANDBOX/repo-branch3"
git clone -q "$REPO" "$BR3" 2>/dev/null
(cd "$BR3" && git checkout -q -b feat-push)
echo "x" > "$BR3/c.txt"
commit_all "$BR3" "feat work"
(cd "$BR3" && git push -q -u origin feat-push)
(cd "$BR3" && HOME="$FAKEHOME" node "$GUIDE" note "did feat-push work" c.txt) >/dev/null 2>&1
LEDGER3="$BR3/.git/review-guide/feat-push.jsonl"
BASE_SHA3=$(sed -n 1p "$LEDGER3" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0)).base_sha)')
HEAD3=$(cd "$BR3" && git rev-parse HEAD)
check "3: recorded base_sha is not HEAD" '[ "$BASE_SHA3" != "$HEAD3" ] && [ -n "$BASE_SHA3" ]'
(cd "$BR3" && HOME="$FAKEHOME" node "$GUIDE" status) > /tmp/rg-status3.log 2>&1
check "3: status reports a non-empty changed set" '! grep -q "^0 of 0" /tmp/rg-status3.log'

# ---- 4: base is not re-derived
(cd "$BR3" && git update-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null)
(cd "$BR3" && HOME="$FAKEHOME" node "$GUIDE" status) > /tmp/rg-status4.log 2>&1
check "4: status still reports the originally recorded base" 'grep -q "$BASE_SHA3" /tmp/rg-status4.log'

# ---- 5: branch with a slash -> flat file
(cd "$REPO" && git checkout -q -b 'feat/x' main)
echo "y" > "$REPO/d.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "slash branch" d.txt) >/dev/null 2>&1
check "5: feat/x -> flat feat-x.jsonl, no nested dir" '[ -f "$REPO/.git/review-guide/feat-x.jsonl" ] && [ ! -d "$REPO/.git/review-guide/feat" ]'

# ---- 6: detached HEAD
(cd "$REPO" && git checkout -q --detach main)
echo "z" > "$REPO/e.txt"
g_detached() { (cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" "$@" 2>&1); }
OUT=$(g_detached note "detached work" e.txt); RC=$?
check "6: detached HEAD note succeeds" '[ $RC -eq 0 ]'
check "6: writes detached.jsonl" '[ -f "$REPO/.git/review-guide/detached.jsonl" ]'
(cd "$REPO" && git checkout -q main)

# ---- 7: drift
echo "drift" > "$REPO/f.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "note f" f.txt) >/dev/null 2>&1
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" status 2>&1)
check "7: status shows f.txt annotated (not in unannotated list)" '! echo "$OUT" | grep -qE "^\s*- f\.txt$"'
echo "drift changed" >> "$REPO/f.txt"
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" status 2>&1)
check "7: after edit, f.txt flips to unannotated" 'echo "$OUT" | grep -qE "^\s*- f\.txt$"'
echo "skip me" > "$REPO/g.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note --skip "trivial" g.txt) >/dev/null 2>&1
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" status 2>&1)
check "7: skip -> g.txt not in unannotated" '! echo "$OUT" | grep -qE "^\s*- g\.txt$"'

# ---- 8: guide output shape
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" guide) > /tmp/rg-guide8.log 2>&1
GUIDE_PATH8=$(grep -o '/.*main.guide.md' /tmp/rg-guide8.log | head -1)
check "8: guide output non-empty" '[ -s "$GUIDE_PATH8" ]'
check "8: contains marker line" 'grep -q "<!-- review-guide: generated" "$GUIDE_PATH8"'
check "8: contains N of M header" 'grep -qE "\*\*[0-9]+ of [0-9]+ changed files annotated\.\*\*" "$GUIDE_PATH8"'
check "8: auto-derived entry for unnoted changed file" 'grep -q "no note; auto-derived from diff stat" "$GUIDE_PATH8"'
check "8: separate skipped section" 'grep -q "### Skipped as trivial" "$GUIDE_PATH8"'

# ---- 9: guide --pr prints both forms, invokes neither
PATH="$BIN:$PATH_ORIG"
(cd "$REPO" && HOME="$FAKEHOME" PATH="$BIN:$PATH_ORIG" node "$GUIDE" guide --pr) > /tmp/rg-pr.log 2>&1
PATH="$PATH_ORIG"
check "9: prints gh pr create" 'grep -q "gh pr create --body-file" /tmp/rg-pr.log'
check "9: prints gh pr edit" 'grep -q "gh pr edit --body-file" /tmp/rg-pr.log'
check "9: never invoked the gh stub" '! grep -q "SHOULD NEVER BE INVOKED" /tmp/rg-pr.log'

# ---- 10: empty narration
echo "h" > "$REPO/h.txt"
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "" h.txt 2>&1); RC=$?
check "10: empty narration exits non-zero" '[ $RC -ne 0 ]'
LEDGER_MAIN="$REPO/.git/review-guide/main.jsonl"
check "10: writes no record" '! grep -q "\"h.txt\"" "$LEDGER_MAIN"'

# ---- 11: --files a,b comma form
echo "i1" > "$REPO/i1.txt"; echo "i2" > "$REPO/i2.txt"
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "two files via --files" --files "i1.txt,i2.txt" 2>&1); RC=$?
check "11: --files comma form accepted" '[ $RC -eq 0 ]'
check "11: both files recorded" 'grep -q "i1.txt" "$LEDGER_MAIN" && grep -q "i2.txt" "$LEDGER_MAIN"'

# ---- 12: two-field schema
echo "j" > "$REPO/j.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "j note" --watch "flag one" --watch "flag two" j.txt) >/dev/null 2>&1
LAST_NOTE=$(tail -1 "$LEDGER_MAIN")
check "12: two --watch flags -> 2-element watch array" '
  node -e "const r=JSON.parse(process.argv[1]); process.exit(Array.isArray(r.watch) && r.watch.length===2 ? 0 : 1)" "$LAST_NOTE"
'
echo "k" > "$REPO/k.txt"
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "k note, no flags" k.txt) >/dev/null 2>&1
LAST_NOTE_K=$(tail -1 "$LEDGER_MAIN")
check "12: no --watch -> no watch key" '
  node -e "const r=JSON.parse(process.argv[1]); process.exit(!(\"watch\" in r) || (Array.isArray(r.watch)&&r.watch.length===0) ? 0 : 1)" "$LAST_NOTE_K"
'

# ---- 13: watch rendering
(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" guide) > /tmp/rg-guide13.log 2>&1
GUIDE_PATH13=$(grep -o '/.*main.guide.md' /tmp/rg-guide13.log | head -1)
check "13: top-level Watch list present" 'grep -q "### Watch list" "$GUIDE_PATH13"'
check "13: watch list has both flags with file" 'grep -q "flag one" "$GUIDE_PATH13" && grep -q "flag two" "$GUIDE_PATH13"'
check "13: per-entry Watch: sub-list present" 'grep -q "\*\*Watch:\*\*" "$GUIDE_PATH13"'

REPO_NOWATCH="$SANDBOX/repo-nowatch"
new_repo "$REPO_NOWATCH"
echo "n" > "$REPO_NOWATCH/n.txt"
commit_all "$REPO_NOWATCH" "init"
echo "m" > "$REPO_NOWATCH/m.txt"
(cd "$REPO_NOWATCH" && HOME="$FAKEHOME" node "$GUIDE" note "no flags anywhere" m.txt) >/dev/null 2>&1
(cd "$REPO_NOWATCH" && HOME="$FAKEHOME" node "$GUIDE" guide) > /tmp/rg-guide13b.log 2>&1
GUIDE_PATH13B=$(grep -o '/.*main.guide.md' /tmp/rg-guide13b.log | head -1)
check "13: no flags anywhere -> Watch list section absent" '! grep -q "### Watch list" "$GUIDE_PATH13B"'

# ---- 14: narration required with --watch; --skip with --watch is an error
echo "p" > "$REPO/p.txt"
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note "" --watch "x" p.txt 2>&1); RC=$?
check "14: note --watch with empty narration exits non-zero" '[ $RC -ne 0 ]'
check "14: writes no record" '! grep -q "\"p.txt\"" "$LEDGER_MAIN"'
OUT=$(cd "$REPO" && HOME="$FAKEHOME" node "$GUIDE" note --skip "why" --watch "x" p.txt 2>&1); RC=$?
check "14: note --skip with --watch is an error" '[ $RC -ne 0 ]'

# ---- 15: zero-note guide
REPO_ZERO="$SANDBOX/repo-zero"
new_repo "$REPO_ZERO"
echo "z1" > "$REPO_ZERO/z1.txt"
commit_all "$REPO_ZERO" "init"
echo "z2" > "$REPO_ZERO/z2.txt"
OUT=$(cd "$REPO_ZERO" && HOME="$FAKEHOME" node "$GUIDE" guide 2>&1); RC=$?
check "15: guide with changes but no notes succeeds and exits zero" '[ $RC -eq 0 ]'
ZERO_GUIDE=$(grep -o '/.*main.guide.md' <<< "$OUT" | head -1)
check "15: 0 of N annotated header" 'grep -qE "\*\*0 of [0-9]+ changed files annotated\.\*\*" "$ZERO_GUIDE"'

# ---- 16: no hooks
check "16: no review-guide/hooks directory" '[ ! -d "$PLUGIN/hooks" ]'
check "16: no hooks.json" '[ ! -f "$PLUGIN/hooks.json" ]'
check "16: plugin.json has no hooks key" '
  node -e "const p=require(\"$PLUGIN/.claude-plugin/plugin.json\"); process.exit(\"hooks\" in p ? 1 : 0)"
'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
