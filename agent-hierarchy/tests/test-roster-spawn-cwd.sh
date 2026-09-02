#!/bin/bash
# agent-hierarchy — spec 0035 (W-1 Tier 1): terminal-transport spawn placement.
# The terminal transport's execFile call carried no `cwd` option, so a spawned peer
# inherited roster.mjs's own process cwd instead of the resolved --cwd value — most
# consequential when roster.mjs runs as a long-lived MCP server's subprocess, whose
# own cwd can never match a worktree created after the server started.
# Fixture technique (spec 0035 §4): a stub `claude` on PATH records its OWN pwd, so
# assertions are on where the process actually ran, never on the command string built.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-spawn-cwd.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-spawn-cwd-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude" "$SANDBOX/bin"
NODE_DIR="$(dirname "$(command -v node)")"
export CLAUDE_PID=$$
PASS=0; FAIL=0; SKIP=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

# stub `claude`: records its OWN pwd, not the command string it was invoked with —
# the terminal branch's command string ("claude ... --bg") was always correct; what
# was missing was the execution option beside it (spec 0035 §4).
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/sh
pwd > "$SPAWN_CWD_LOG"
EOF
chmod +x "$SANDBOX/bin/claude"

# One fresh roster+repo per scenario, so team state never leaks across cases.
setup_repo() {
  local dir=$1
  mkdir -p "$dir/.claude"
  (cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t)
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$dir" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --level repo --role implementor --cwd "$dir" >/dev/null
}

# Terminal-transport spawn: run FROM $1 (the process's own cwd), with --cwd $2 (empty
# to omit the flag), logging the claude stub's pwd to $3. To create the divergence
# the bug needs, $1 and $2 must differ (spec 0035 §4).
spawn_terminal() {
  local runcwd=$1 cwdarg=$2 log=$3
  rm -f "$log"
  if [ -n "$cwdarg" ]; then
    OUT=$(cd "$runcwd" && env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" SPAWN_CWD_LOG="$log" CLAUDE_PID=$$ node "$H/roster.mjs" create --spawn --mode auto --cwd "$cwdarg" 2>&1)
  else
    OUT=$(cd "$runcwd" && env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" SPAWN_CWD_LOG="$log" CLAUDE_PID=$$ node "$H/roster.mjs" create --spawn --mode auto 2>&1)
  fi
  RC=$?
}

# ---- T1: falsifiable core. Process cwd = /tmp-ish elsewhere dir, --cwd = the repo. ----
T1_REPO="$SANDBOX/t1-repo"
T1_ELSEWHERE="$SANDBOX/t1-elsewhere"
mkdir -p "$T1_ELSEWHERE"
setup_repo "$T1_REPO"
T1_LOG="$SANDBOX/t1.log"
spawn_terminal "$T1_ELSEWHERE" "$T1_REPO" "$T1_LOG"
check "T1: create --spawn succeeds" '[ "$RC" -eq 0 ]'
check "T1: stub claude ran in --cwd's directory, not the process cwd (the defect)" \
  '[ -f "$T1_LOG" ] && [ "$(cat "$T1_LOG")" = "$T1_REPO" ]'

# ---- T2: the reported incident in miniature — --cwd is a worktree, process cwd is the main checkout. ----
T2_MAIN="$SANDBOX/t2-main"
setup_repo "$T2_MAIN"
T2_WORKTREE="$SANDBOX/t2-worktree"
(cd "$T2_MAIN" && git worktree add -q -b t2-wt "$T2_WORKTREE" >/dev/null 2>&1)
mkdir -p "$T2_WORKTREE/.claude"
T2_LOG="$SANDBOX/t2.log"
spawn_terminal "$T2_MAIN" "$T2_WORKTREE" "$T2_LOG"
check "T2: create --spawn succeeds" '[ "$RC" -eq 0 ]'
check "T2: stub claude ran in the worktree, not the main checkout" \
  '[ -f "$T2_LOG" ] && [ "$(cat "$T2_LOG")" = "$T2_WORKTREE" ]'

# ---- T3: regression guard — direct-Bash path, --cwd omitted, roster.mjs run FROM the repo. ----
T3_REPO="$SANDBOX/t3-repo"
setup_repo "$T3_REPO"
T3_LOG="$SANDBOX/t3.log"
spawn_terminal "$T3_REPO" "" "$T3_LOG"
check "T3: create --spawn succeeds" '[ "$RC" -eq 0 ]'
check "T3: --cwd omitted still lands at the repo via :126's process.cwd() fallback" \
  '[ -f "$T3_LOG" ] && [ "$(cat "$T3_LOG")" = "$T3_REPO" ]'

# ---- T4: path with a space — guards the options-object fix against a naive `cd $dir &&` string fix. ----
T4_ELSEWHERE="$SANDBOX/t4-elsewhere"
mkdir -p "$T4_ELSEWHERE"
T4_REPO="$SANDBOX/t4-repo with space"
setup_repo "$T4_REPO"
T4_LOG="$SANDBOX/t4.log"
spawn_terminal "$T4_ELSEWHERE" "$T4_REPO" "$T4_LOG"
check "T4: create --spawn succeeds with a spaced path" '[ "$RC" -eq 0 ]'
check "T4: stub claude ran in the exact spaced path" \
  '[ -f "$T4_LOG" ] && [ "$(cat "$T4_LOG")" = "$T4_REPO" ]'

# ---- T5: tmux — honesty test. Drives roster.mjs create --spawn for real (transport
# auto-detected as tmux) and asserts the resulting pane's actual OS-level cwd via
# #{pane_current_path} — not a hand-rolled mirror of roster.mjs's own tmux construction.
# Deleting `-c splitCwd` from layoutAndLaunch's real tmux execFileSync call (:850) —
# not spawnShape's :254 display string — must make this fail.
T5_ELSEWHERE="$SANDBOX/t5-elsewhere"
mkdir -p "$T5_ELSEWHERE"
T5_REPO="$SANDBOX/t5-repo"
setup_repo "$T5_REPO"
if command -v tmux >/dev/null 2>&1; then
  TMUX_SOCK="/tmp/ah-w1t5-$$.sock"
  TMUX_DIR="$(dirname "$(command -v tmux)")"
  # Session's own default-path is $SANDBOX, deliberately not $T5_REPO, so a regressed
  # spawnShape (no -c) would land the pane somewhere other than $T5_REPO, not by luck.
  (cd "$SANDBOX" && tmux -S "$TMUX_SOCK" new-session -d -s w1t5)
  OUT=$(cd "$T5_ELSEWHERE" && env -u HERDR_ENV HOME="$FAKEHOME" PATH="$TMUX_DIR:$NODE_DIR" TMUX="$TMUX_SOCK,0,0" CLAUDE_PID=$$ node "$H/roster.mjs" create --spawn --mode auto --cwd "$T5_REPO" 2>&1)
  RC=$?
  PANE_ID=$(echo "$OUT" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const p=JSON.parse(s);const m=p.members.find(x=>x.route==='peer');process.stdout.write(m&&m.transport_id?m.transport_id:'')}catch{}})" 2>/dev/null)
  if [ -n "$PANE_ID" ]; then
    PANE_PATH=$(tmux -S "$TMUX_SOCK" display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>&1)
  else
    PANE_PATH=""
  fi
  tmux -S "$TMUX_SOCK" kill-server 2>/dev/null
  rm -f "$TMUX_SOCK"
  check "T5: create --spawn (tmux, auto-detected) succeeds" '[ "$RC" -eq 0 ]'
  check "T5: real pane's OS-level cwd (#{pane_current_path}) matches --cwd, driven end-to-end through roster.mjs" \
    '[ -n "$PANE_ID" ] && [ "$PANE_PATH" = "$T5_REPO" ]'
else
  skip "T5: tmux not on PATH — cannot check directly"
fi

# ---- T6: herdr — same honesty test, but this environment has a REAL herdr session live
# and visible (this test suite itself is ambiently HERDR_ENV=1). Unlike tmux's isolated,
# detached server, a real `herdr pane split` here would create a visible pane in the
# actual live session — a disruptive side effect this test must not cause unattended.
# Spec 0035 §4 asks for a loud SKIP when herdr is absent; extending that same discipline
# to "herdr is present but only as the live session itself" rather than silently running
# it or silently omitting the row.
if command -v herdr >/dev/null 2>&1; then
  skip "T6: herdr binary present, but only as this session's own live pane — a real 'herdr pane split' would visibly disrupt it, so this is a deliberate SKIP, not a silent omission. Needs a driveable, isolated herdr instance (or explicit user sign-off to use the live one) to run for real."
else
  skip "T6: herdr not on PATH"
fi

# ---- T7: herdr retry path — both attempts must use the same launch_cwd. ----
T7_ELSEWHERE="$SANDBOX/t7-elsewhere"
mkdir -p "$T7_ELSEWHERE"
T7_REPO="$SANDBOX/t7-repo"
setup_repo "$T7_REPO"
T7_LOG="$SANDBOX/t7.log"
rm -f "$T7_LOG"
# Fake herdr: the layout phase (pane layout/split) always succeeds so create --spawn can
# reach the launch step; only "agent start" (the launch command, run via runShell — the
# code path this spec touches) fails once then succeeds, recording its own pwd each time.
cat > "$SANDBOX/bin/herdr" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "pane layout") echo '{"result":{"layout":{"panes":[{"pane_id":"self1","rect":{"x":0,"y":0,"width":100,"height":100}}]}}}'; exit 0 ;;
  "pane split") echo '{"result":{"pane":{"pane_id":"p1"}}}'; exit 0 ;;
esac
pwd >> "$T7_LOG"
if [ ! -f "$SANDBOX/t7.fired" ]; then
  touch "$SANDBOX/t7.fired"
  echo "fake herdr: agent start failed (once)" >&2
  exit 1
fi
echo '{"result":{"pane":{}}}'
exit 0
EOF
chmod +x "$SANDBOX/bin/herdr"
OUT=$(cd "$T7_ELSEWHERE" && HOME="$FAKEHOME" HERDR_ENV=1 HERDR_PANE_ID=self1 PATH="$SANDBOX/bin:$NODE_DIR" CLAUDE_PID=$$ node "$H/roster.mjs" create --spawn --mode auto --cwd "$T7_REPO" 2>&1)
RC=$?
check "T7: create --spawn (herdr, forced retry) succeeds" '[ "$RC" -eq 0 ]'
check "T7: retry ran in the same directory as the first attempt" \
  '[ -f "$T7_LOG" ] && [ "$(sort -u "$T7_LOG" | wc -l | tr -d " ")" = "1" ] && [ "$(head -1 "$T7_LOG")" = "$T7_REPO" ]'

# ---- T8: create --spawn output reports the launch directory per member (§2.4). ----
T8_ELSEWHERE="$SANDBOX/t8-elsewhere"
mkdir -p "$T8_ELSEWHERE"
T8_REPO="$SANDBOX/t8-repo"
setup_repo "$T8_REPO"
T8_LOG="$SANDBOX/t8.log"
spawn_terminal "$T8_ELSEWHERE" "$T8_REPO" "$T8_LOG"
check "T8: create --spawn succeeds" '[ "$RC" -eq 0 ]'
check "T8: output reports launch_cwd per member, matching --cwd" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const p=JSON.parse(s);const bad=p.members.some(m=>m.route===\"peer\"&&m.launch_cwd!==\"$T8_REPO\");process.exit(bad?1:0)})"'

# ---- §4.3: every spawnShape branch returns a non-null launch_cwd — the guard against a
# future fourth transport (the cheap substitute for the rejected process.chdir()). Each
# iteration also asserts `transport` in the output actually matches what it forced — without
# that, a broken tmux/herdr detection silently degrades every iteration to terminal and the
# guard passes vacuously (Reviewer finding on r3). The tmux case needs a real, live server
# (same technique as T5) so detectTransport's `tmux list-sessions` actually succeeds. ----
GUARD_REPO="$SANDBOX/guard-repo"
setup_repo "$GUARD_REPO"
for transport in herdr tmux terminal; do
  case "$transport" in
    herdr) PLAN_OUT=$(HOME="$FAKEHOME" HERDR_ENV=1 node "$H/roster.mjs" create --plan --cwd "$GUARD_REPO" 2>&1) ;;
    tmux)
      GUARD_TMUX_SOCK="/tmp/ah-w1guard-$$.sock"
      GUARD_TMUX_DIR="$(dirname "$(command -v tmux)" 2>/dev/null)"
      if [ -n "$GUARD_TMUX_DIR" ]; then
        (cd "$SANDBOX" && tmux -S "$GUARD_TMUX_SOCK" new-session -d -s w1guard)
        PLAN_OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$GUARD_TMUX_DIR:$NODE_DIR" TMUX="$GUARD_TMUX_SOCK,0,0" node "$H/roster.mjs" create --plan --cwd "$GUARD_REPO" 2>&1)
        tmux -S "$GUARD_TMUX_SOCK" kill-server 2>/dev/null
        rm -f "$GUARD_TMUX_SOCK"
      else
        PLAN_OUT=""
      fi
      ;;
    terminal) PLAN_OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$NODE_DIR" node "$H/roster.mjs" create --plan --cwd "$GUARD_REPO" 2>&1) ;;
  esac
  if [ "$transport" = "tmux" ] && [ -z "$GUARD_TMUX_DIR" ]; then
    skip "§4.3: spawnShape(tmux) — tmux not on PATH, cannot check directly"
    continue
  fi
  check "§4.3: spawnShape($transport) actually ran as transport=$transport, not a silent fallback" \
    "echo \"\$PLAN_OUT\" | node -e \"let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const p=JSON.parse(s);process.exit(p.transport==='$transport'?0:1)})\""
  check "§4.3: spawnShape($transport) sets a non-null launch_cwd" \
    "echo \"\$PLAN_OUT\" | node -e \"let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const p=JSON.parse(s);const bad=p.members.some(m=>m.spawn&&m.spawn.launch_cwd==null);process.exit(bad?1:0)})\""
done

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" -eq 0 ]
