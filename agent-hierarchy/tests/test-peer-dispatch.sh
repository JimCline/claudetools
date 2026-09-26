#!/bin/bash
# agent-hierarchy peer-dispatch tests: per-role "dispatch"/"peer" config resolution
# + directive rendering. HOME-redirected; real config never touched.
# Usage: bash tests/test-peer-dispatch.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-peer-test.XXXXXX")"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:200})"; fi
}

# eval_js <js-expression over {resolveConfig,buildDirective,statusReport} bound as L, cwd $PROJ>
eval_js() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('${LIB}');
    const r = L.resolveConfig('${PROJ}');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

user_cfg()    { printf '%s\n' "$1" > "$FAKEHOME/.claude/agent-hierarchy.json"; }
proj_cfg()    { printf '%s\n' "$1" > "$PROJ/.claude/agent-hierarchy.json"; }
clear_cfgs()  { rm -f "$FAKEHOME/.claude/agent-hierarchy.json" "$PROJ/.claude/agent-hierarchy.json"; }

BASE='"version":1,"enabled":true'
# PROJ is always named "proj" (fixed basename of the sandbox project dir), so
# the "<repo>-<role>" convention name for architect is always "proj-architect".

# ---- 1. no dispatch/peer keys at all (every config written before this
#         feature existed) -> resolves to dispatch:"peer", peer:"auto",
#         reproducing today's RESOLVED VALUES exactly. Load-bearing regression
#         guard for the config-resolution rule. The directive line for it names
#         the live teammate, the spawn command for when none is live, and where to
#         turn when it cannot be launched — never an Agent call and never a
#         peer-name ceremony.
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\"}}}"
eval_js "r.roles.architect.dispatch + '|' + r.roles.architect.peer"
check "no dispatch/peer keys -> peer/auto" '[ "$OUT" = "peer|auto" ]'
eval_js "L.buildDirective(r)"
check "no dispatch/peer keys -> directive line: live teammate, spawn command, can't-launch pointer" \
  'printf "%s" "$OUT" | grep "^- Architect" | grep -qF "SendMessage its live teammate (names: \`ListAgents\` / \`roster.mjs teams\`); none live → " && printf "%s" "$OUT" | grep "^- Architect" | grep -qF "spawn-ad-hoc architect --cwd" && printf "%s" "$OUT" | grep "^- Architect" | grep -qF "launch → agent-team" && ! printf "%s" "$OUT" | grep -q "opts in"'
check "no dispatch/peer keys -> no Agent call and no else-subagent on the line" '! printf "%s" "$OUT" | grep "^- Architect" | grep -qE "Agent\(|else Agent|else the subagent"'
check "no dispatch/peer keys -> no PEER NAME CONFIRMATION section" '! printf "%s" "$OUT" | grep -qE "PEER NAME CONFIRMATION|not yet confirmed"'
check "item 13 no longer routes spawning one member through the skill" \
  '! printf "%s" "$OUT" | grep -qF "spawn or dismiss one member" && printf "%s" "$OUT" | grep -qF "dismiss one member, disband"'

# ---- 1b. an explicitly recorded peer name is the SendMessage target on the line.
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\
\"ultra-advisor\":{\"model\":\"fable\",\"dispatch\":\"peer\",\"peer\":\"proj-ultra-advisor\"},\
\"architect\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"proj-architect\"},\
\"reviewer\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"proj-reviewer\"},\
\"implementor\":{\"model\":\"inherit\",\"dispatch\":\"peer\",\"peer\":\"proj-implementor\"}\
}}"
eval_js "L.buildDirective(r)"
EXPECTED='- Architect — SendMessage peer "proj-architect"; none live → '
check "recorded peer name -> directive line names that peer" 'printf "%s" "$OUT" | grep -qF -- "$EXPECTED"'

# ---- 2. dispatch:"model" on a chain role is ignored — a chain role runs only as a peer, so its
#         line is the peer line, never an Agent() call.
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"model\"}}}"
eval_js "r.roles.architect.dispatch"
check "dispatch:model on a chain role reads as peer" '[ "$OUT" = peer ]'
eval_js "L.buildDirective(r)"
check "dispatch:model -> Architect line still names its live teammate" \
  'printf "%s" "$OUT" | grep "^- Architect" | grep -q "SendMessage its live teammate"'
check "dispatch:model -> no Agent() call on the Architect line" '! printf "%s" "$OUT" | grep "^- Architect" | grep -q "Agent("'

# ---- 3. dispatch:"peer", explicit peer name -> that name is used instead of
#         the "<repo>-<role>" convention.
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"custom-name\"}}}"
eval_js "L.buildDirective(r)"
check "explicit peer name -> used verbatim in directive" 'printf "%s" "$OUT" | grep -q "peer \"custom-name\""'
check "explicit peer name -> convention name NOT used" '! printf "%s" "$OUT" | grep -q "proj-architect"'

# ---- 4. invalid dispatch value -> warning + falls back to "peer"
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"carrier-pigeon\"}}}"
eval_js "r.roles.architect.dispatch + '|' + (r.warnings.some(w=>w.includes('dispatch')) ? 'warned' : 'silent')"
check "invalid dispatch -> peer with a warning" '[ "$OUT" = "peer|warned" ]'

# ---- 5. invalid/empty peer value (dispatch:"peer") -> warning + falls back
#         to "auto"
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"\"}}}"
eval_js "r.roles.architect.peer + '|' + (r.warnings.some(w=>w.includes('peer value')) ? 'warned' : 'silent')"
check "empty peer value -> auto with a warning" '[ "$OUT" = "auto|warned" ]'

# ---- 6. statusReport() reflects the dispatch route per role
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"model\"},\"reviewer\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"custom-name\"}}}"
OUT=$(cd "$PROJ" && HOME="$FAKEHOME" node "$LIB" 2>&1); RC=$?
check "status: a chain role's stale dispatch:model shows its peer route" 'printf "%s" "$OUT" | grep "Architect" | grep -q "dispatch: peer \"proj-architect\""'
check "status: explicit-peer role shown" 'printf "%s" "$OUT" | grep "Reviewer" | grep -q "dispatch: peer \"custom-name\""'

# ---- task-runner is unaffected: no dispatch/peer concept, line unchanged
clear_cfgs
proj_cfg "{$BASE,\"roles\":{}}"
eval_js "L.buildDirective(r)"
EXPECTED='- Task-Runner — Agent(subagent_type:"task-gopher:task-gopher", model:"haiku")'
check "task-runner line unaffected (no peer, no dispatch marker)" 'printf "%s" "$OUT" | grep -qF -- "$EXPECTED"'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
