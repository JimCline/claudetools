#!/bin/bash
# comment-discipline — hooks/sweep.mjs, the deterministic candidate finder behind
# `/comment-discipline sweep`.
#
# Two properties matter more than coverage here: every do-not class must actually fire, and the
# two CONTROLS must stay silent. A sweep that flags a durable WHY comment or a properly-qualified
# TODO trains its user to ignore it, which is worse than not having it.
# Runs against a throwaway git repo; the real tree is never read.
# Usage: bash tests/test-sweep.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$PLUGIN/hooks/sweep.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/comment-discipline-sweep-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
mkdir -p "$REPO/src" "$REPO/docs/specs"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# ---- fixture: one hit per class, plus the controls and the exclusions
cat > "$REPO/src/hits.js" <<'EOF'
// spec 0048 §2.4 says this must ask
const a = 1;
// changed from a Map to a Set
const b = 2;
// for now, single-threaded
const c = 3;
// TODO(#4127): remove once the v2 endpoint lands
const d = 4;
// implements spec 0042 behaviour
const k = 11;
// see PROJ-317 before touching this
const l = 12;
// as decided in the sync
const m = 13;
EOF

cat > "$REPO/src/controls.js" <<'EOF'
// The vendor API returns 200 with an error body, so the status code cannot be trusted here.
const e = 5;
// TODO: remove once the v2 endpoint lands
const f = 6;
/** Returns the caller's effective permissions, or null when the session is anonymous. */
const g = 7;
EOF

cat > "$REPO/src/more.py" <<'EOF'
# per review feedback, widened the guard
h = 8
EOF

# excluded by design: spec prose cites specs for a living
cat > "$REPO/docs/specs/0048-thing.js" <<'EOF'
// spec 0048 §2.4 — this one must NOT be reported
const i = 9;
EOF

# untracked: not someone's comment
cat > "$REPO/src/untracked.js" <<'EOF'
// changed from foo to bar
const j = 10;
EOF

(cd "$REPO" && git init -q && git add src/hits.js src/controls.js src/more.py docs/specs/0048-thing.js)

RUN() { OUT=$(cd "$REPO" && node "$SWEEP" "$@" 2>&1); RC=$?; }

RUN --json
check "sweep exits 0 and emits JSON" '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{JSON.parse(d);console.log(\"ok\")})" | grep -q ok'

has() { # <file> <line> <class>
  echo "$OUT" | node -e '
    let d=""; process.stdin.on("data",(c)=>d+=c).on("end",()=>{
      const {hits} = JSON.parse(d);
      const [f,l,c] = process.argv.slice(1);
      process.exit(hits.some((h) => h.file === f && String(h.line) === l && h.class === c) ? 0 : 1);
    });
  ' "$1" "$2" "$3"
}

check "class references: flags a spec number and section mark" 'has src/hits.js 1 references'
check "class change-narration: flags \"changed from\"" 'has src/hits.js 3 change-narration'
check "class time-markers: flags a bare \"for now\"" 'has src/hits.js 5 time-markers'
check "class todo-with-ref: flags TODO(#…)" 'has src/hits.js 7 todo-with-ref'
check "class references: fires in a # -comment language too" 'has src/more.py 1 references'
# one fixture line per reference pattern: a line that trips three rows at once cannot show
# that any single row is load-bearing.
check "references row: a bare spec number, no section mark" 'has src/hits.js 9 references'
check "references row: a JIRA-style key" 'has src/hits.js 11 references'
check "references row: a decision marker" 'has src/hits.js 13 references'

# ---- the controls: a durable WHY comment, a properly-qualified TODO, a doc comment
check "CONTROL: a durable WHY comment is not flagged" '! echo "$OUT" | grep -q "status code cannot be trusted"'
check "CONTROL: a TODO with a condition and no reference is not flagged" \
  '! echo "$OUT" | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c).on(\"end\",()=>{const{hits}=JSON.parse(d);process.exit(hits.some(h=>h.file===\"src/controls.js\")?0:1)})"'
check "CONTROL: an API-contract docblock is not flagged" '! echo "$OUT" | grep -q "effective permissions"'

# ---- exclusions
check "docs/specs/** is excluded" '! echo "$OUT" | grep -q "docs/specs"'
check "untracked files are not read" '! echo "$OUT" | grep -q "untracked.js"'

# ---- output modes
RUN --count
check "--count prints just the number" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -Eq "^[0-9]+$"'
COUNT="$OUT"
# 6, not 5: the `TODO(#4127)` line is both a reference and a parenthesised TODO, and one line
# legitimately belongs to two classes — the report groups per class, so it appears under both.
check "--count matches the number of hits (9 in the fixture, one line in two classes)" '[ "$COUNT" -eq 9 ]'

RUN
check "default output groups by class and spells file:line" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^references (" && echo "$OUT" | grep -q "src/hits.js:1:"'
check "default output says the candidates still need judgment" 'echo "$OUT" | grep -q "still needs a human or a judging agent"'

RUN src/more.py
check "a path argument narrows the sweep" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "src/more.py" && ! echo "$OUT" | grep -q "src/hits.js"'

# ---- the command surface must name the script through the plugin-root placeholder
CMD="$PLUGIN/commands/comment-discipline.md"
check "command md documents the sweep subcommand" 'grep -q "comment-discipline sweep" "$CMD"'
check "command md names sweep.mjs via \${CLAUDE_PLUGIN_ROOT}" 'grep -q "\${CLAUDE_PLUGIN_ROOT}/hooks/sweep.mjs" "$CMD"'
check "command md fans out to smart-gopher above the threshold" 'grep -q "task-gopher:smart-gopher" "$CMD"'
check "command md asks once, with the three choices" \
  'grep -q "AskUserQuestion" "$CMD" && grep -qi "report only" "$CMD" && grep -qi "show the diff first" "$CMD"'
check "README documents sweep" 'grep -q "sweep" "$PLUGIN/README.md"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
