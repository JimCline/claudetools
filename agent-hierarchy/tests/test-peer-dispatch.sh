#!/bin/bash
# agent-hierarchy peer-dispatch tests: per-role "dispatch"/"peer" config resolution
# + directive rendering. HOME-redirected; real config never touched.
# Usage: bash tests/test-peer-dispatch.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-peer-test.XXXXXX")"
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
#         guard for the config-resolution rule. The DIRECTIVE TEXT for an
#         unconfirmed "auto" now points at the one-time PEER NAME CONFIRMATION
#         flow instead of asserting the convention name silently (Change: the
#         Orchestrator now confirms a role's peer name with the user once,
#         even on an exact convention match, rather than trusting it blind).
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\"}}}"
eval_js "r.roles.architect.dispatch + '|' + r.roles.architect.peer"
check "no dispatch/peer keys -> peer/auto" '[ "$OUT" = "peer|auto" ]'
eval_js "L.buildDirective(r)"
EXPECTED='- Architect — peer name not yet confirmed for this repo (see PEER NAME CONFIRMATION below); resolve it before your first dispatch of this role, then use Agent(subagent_type:"ah:architect", model:"opus") as the fallback once resolved.'
check "no dispatch/peer keys -> directive line points at PEER NAME CONFIRMATION" 'printf "%s" "$OUT" | grep -qF -- "$EXPECTED"'
check "no dispatch/peer keys -> directive includes the PEER NAME CONFIRMATION section" 'printf "%s" "$OUT" | grep -q "^PEER NAME CONFIRMATION"'
check "no dispatch/peer keys -> repo-basename convention shown in the confirmation guidance" 'printf "%s" "$OUT" | grep -qF "proj-<role>"'

# ---- 1b. once EVERY peer-eligible role's peer name is explicitly
#          confirmed/recorded (peer is a literal string, not "auto"), the
#          directive goes straight back to asserting the peer route with no
#          confirmation pointer anywhere — the one-time-only guarantee from
#          the PEER NAME CONFIRMATION flow. Every peer-eligible role must be
#          given an explicit peer here: any role left unmentioned still
#          defaults to dispatch:"peer", peer:"auto" (case 1 above), which
#          would keep the confirmation section present and defeat this case.
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\
\"ultra-advisor\":{\"model\":\"fable\",\"dispatch\":\"peer\",\"peer\":\"proj-ultra-advisor\"},\
\"architect\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"proj-architect\"},\
\"reviewer\":{\"model\":\"opus\",\"dispatch\":\"peer\",\"peer\":\"proj-reviewer\"},\
\"implementor\":{\"model\":\"inherit\",\"dispatch\":\"peer\",\"peer\":\"proj-implementor\"}\
}}"
eval_js "L.buildDirective(r)"
EXPECTED='- Architect — peer "proj-architect" via SendMessage if it appears in ListAgents (default), else Agent(subagent_type:"ah:architect", model:"opus")'
check "confirmed auto-shaped peer name -> directive line matches convention peer route" 'printf "%s" "$OUT" | grep -qF -- "$EXPECTED"'
check "all roles confirmed -> no PEER NAME CONFIRMATION section" '! printf "%s" "$OUT" | grep -q "^PEER NAME CONFIRMATION"'

# ---- 2. dispatch:"model" -> no peer mention at all on that role's line,
#         same shape as a non-peer-eligible role (e.g. task-runner).
clear_cfgs
proj_cfg "{$BASE,\"roles\":{\"architect\":{\"model\":\"opus\",\"dispatch\":\"model\"}}}"
eval_js "L.buildDirective(r)"
check "dispatch:model -> Architect line has no peer mention" \
  '! printf "%s" "$OUT" | grep "^- Architect" | grep -q "peer"'
EXPECTED='- Architect — Agent(subagent_type:"ah:architect", model:"opus")'
check "dispatch:model -> Architect line is bare Agent() call" 'printf "%s" "$OUT" | grep -qF -- "$EXPECTED"'

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
check "status: subagent-only role shown" 'printf "%s" "$OUT" | grep "Architect" | grep -q "dispatch: subagent-only"'
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
