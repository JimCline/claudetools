#!/bin/bash
# agent-hierarchy — spec 0036 (W-1 Tier 2): peer relocation. `expected_root` recorded at team
# creation (§3.1), detected-and-flagged (never refused) at SessionStart (§3.2), and the new
# `roster.mjs checkin` primitive (§3.3) that verifies relocation by read-back — never by a
# tool's success return (§3.4).
# HOME-redirected; real state untouched. `roster.mjs checkin` resolves its own session pid via
# CLAUDE_PID/--orchestrator-pid (same as create --commit/teams), never process.ppid alone —
# process.ppid at that call site is a transient Bash-tool shell, not the session (roster.mjs:1371
# documents the same trap at its other call sites). CLAUDE_PID=$$ is exported once, below, so it
# is inherited whatever process shape a given `node roster.mjs ...` call runs in — most scenarios
# below still invoke directly (no pipe/subshell) purely to keep setup simple; T11b exists
# specifically to prove checkin also resolves through a real subshell (Reviewer F1/F2).
# Most scenarios below patch team.json's expected_root directly rather than writing it via a
# second `create --commit` from a worktree cwd — per 0027 §2, hierarchyDir is worktree-local, so
# a commit run from a worktree writes to the WORKTREE's own team.json, never the main checkout's
# (T11 deliberately exploits exactly that split; every other scenario wants a single shared
# team.json with a divergent expected_root, which only a direct patch achieves).
# Usage: bash tests/test-roster-relocation.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-relocation-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
export CLAUDE_PID=$$
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

realpath_of() { node -e "console.log(require('fs').realpathSync(process.argv[1]))" "$1"; }

# Fresh repo + roster + a committed team whose expected_root is $1 (realpath-normalised inside
# roster.mjs itself). $1 is also where the process runs from, so create --commit's own `cwd`
# argument is exactly the value under test.
setup_team() {
  local dir=$1
  mkdir -p "$dir/.claude"
  (cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t)
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$dir" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$dir" >/dev/null
  local slug; slug=$(basename "$dir")
  HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo \
    --verified "[\"${slug}-implementor\"]" --orchestrator-pid "$$" --cwd "$dir" >/dev/null
}

# Rewrite an already-committed team's expected_root in place — the direct way to set up "peer
# disagrees with the recorded expectation" without a second cross-worktree commit (see header).
patch_expected_root() { # <hierarchy-dir-root> <new-root-dir, need not be a registered worktree>
  local dir=$1 newroot=$2
  mkdir -p "$newroot"
  local real; real=$(realpath_of "$newroot")
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const t = JSON.parse(fs.readFileSync(p, 'utf8'));
    t.expected_root = process.argv[2];
    fs.writeFileSync(p, JSON.stringify(t));
  " "$dir/.claude/hierarchy/team.json" "$real"
}

# SessionStart's role branch, invoked directly (no pipe/subshell) so its `process.ppid` is this
# script's own $$. $1=hierarchy-resolving cwd, $2=session id. Sets SS_OUT / SS_RC.
sessionstart_role() {
  local fromcwd=$1 sid=$2
  echo "{\"session_id\":\"$sid\",\"cwd\":\"$fromcwd\",\"agent_type\":\"ah:implementor\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
    > "$SANDBOX/ss_in.json"
  HOME="$FAKEHOME" node "$H/sessionstart.mjs" < "$SANDBOX/ss_in.json" > "$SANDBOX/ss_out.json" 2>&1
  SS_RC=$?
  SS_OUT="$(cat "$SANDBOX/ss_out.json")"
}

# `roster.mjs checkin`, invoked directly (no pipe/subshell) for the same reason. $1=team-resolving
# cwd. Sets CI_OUT / CI_RC.
checkin() {
  local fromcwd=$1
  HOME="$FAKEHOME" node "$H/roster.mjs" checkin --cwd "$fromcwd" > "$SANDBOX/ci_out.json" 2>&1
  CI_RC=$?
  CI_OUT="$(cat "$SANDBOX/ci_out.json")"
}

# Like setup_team, but scoped to a named team (0011 §5.1: --team X selects teams/X.json and,
# for init/add, the rosters.X roster block instead of the unscoped one).
setup_named_team() { # <dir> <team-name>
  local dir=$1 team=$2
  mkdir -p "$dir/.claude"
  (cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t) 2>/dev/null || true
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --team "$team" --cwd "$dir" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --team "$team" --cwd "$dir" >/dev/null
  HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --team "$team" \
    --verified "[\"${team}-implementor\"]" --orchestrator-pid "$$" --cwd "$dir" >/dev/null
}

# Same as patch_expected_root, but for a named team's file.
patch_expected_root_team() { # <hierarchy-dir-root> <team-name> <new-root-dir>
  local dir=$1 team=$2 newroot=$3
  mkdir -p "$newroot"
  local real; real=$(realpath_of "$newroot")
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const t = JSON.parse(fs.readFileSync(p, 'utf8'));
    t.expected_root = process.argv[2];
    fs.writeFileSync(p, JSON.stringify(t));
  " "$dir/.claude/hierarchy/teams/$team.json" "$real"
}

# Hand-craft a peers.jsonl row directly, bypassing SessionStart/checkin — used by T12/T14/T16 to
# drive `roster teams`'s correlation logic (§3.6) in isolation from how the row got its `team`
# field. team='' omits the field entirely (pre-0036 row); team='__null__' sets it explicitly to
# JSON null (a resolved-to-default-team row); any other value sets it to that string.
append_peer_row() { # <dir> <session_id> <role> <team> <pid> <misplaced true/false> <cwd>
  local dir=$1 sid=$2 role=$3 team=$4 pid=$5 misplaced=$6 cwd=$7
  node -e '
    const fs = require("fs");
    const [, dir, sid, role, team, pid, misplaced, cwd] = process.argv;
    const rec = { type: "peer", status: "up", role, session_id: sid, pid: Number(pid), ppid: Number(pid), cwd, pane_id: null, tab_id: null, workspace_id: null };
    if (team === "__null__") rec.team = null;
    else if (team) rec.team = team;
    rec.expected_root = cwd;
    rec.misplaced = misplaced === "true";
    rec.ts = new Date().toISOString();
    fs.appendFileSync(dir + "/.claude/hierarchy/peers.jsonl", JSON.stringify(rec) + "\n");
  ' "$dir" "$sid" "$role" "$team" "$pid" "$misplaced" "$cwd"
}

# One field off the `roster teams` row matching team-name (pass the literal string "null" for the
# default team), read back from its JSON stdout.
team_row_field() { # <teams-json> <team-name-or-'null'> <field>
  echo "$1" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const data = JSON.parse(s);
      const want = process.argv[1] === "null" ? null : process.argv[1];
      const row = data.teams.find((r) => r.name === want);
      process.stdout.write(row ? JSON.stringify(row[process.argv[2]]) : "undefined");
    });
  ' "$2" "$3"
}

peers_jsonl_misplaced() { # <dir> <session_id> -> "true"/"false"/"absent"/"" (no row) for the last row
  local dir=$1 sid=$2
  node -e "
    const fs=require('fs');
    const lines=fs.readFileSync('$dir/.claude/hierarchy/peers.jsonl','utf8').trim().split('\n').filter(Boolean).map(l=>JSON.parse(l));
    const rows=lines.filter(r=>r.session_id==='$sid');
    const last=rows[rows.length-1];
    if (!last) process.stdout.write('');
    else if (!('misplaced' in last)) process.stdout.write('absent');
    else process.stdout.write(String(!!last.misplaced));
  " 2>/dev/null
}

# ---- T1: team created with --cwd <worktree> -> team.json has expected_root = the worktree, realpath-normalised. ----
T1="$SANDBOX/t1-repo"
setup_team "$T1"
T1_ROOT=$(realpath_of "$T1")
check "T1: team.json's expected_root equals the resolved (realpath) --cwd" \
  '[ "$(cat "$T1/.claude/hierarchy/team.json" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.stdout.write(JSON.parse(s).expected_root))")" = "$T1_ROOT" ]'

# ---- T2: peer's cwd = expected_root -> row has misplaced falsy, no instruction text. ----
T2="$SANDBOX/t2-repo"
setup_team "$T2"
sessionstart_role "$T2" "t2-sess"
check "T2: SessionStart succeeds" '[ "$SS_RC" -eq 0 ]'
check "T2: correctly-placed peer's row is not misplaced" '[ "$(peers_jsonl_misplaced "$T2" "t2-sess")" = "false" ]'
check "T2: no 'Misplaced' instruction text emitted" '! echo "$SS_OUT" | grep -q "Misplaced:"'

# ---- T3: peer's cwd = repo root, expected_root = worktree -> row IS written, misplaced true,
# instruction names EnterWorktree and contains the "cd will not work" sentence. ----
T3_MAIN="$SANDBOX/t3-main"
setup_team "$T3_MAIN"
# A subdir of the SAME repo, not a directory outside it: T4 below checks in FROM this path, and
# checkin's own hierarchyDir(cwd) must resolve to the same git root T3_MAIN's team.json lives
# under, or it can never find the existing peer/team records to compare against.
T3_WT="$T3_MAIN/wt-subdir"
patch_expected_root "$T3_MAIN" "$T3_WT"
sessionstart_role "$T3_MAIN" "t3-sess"
check "T3: SessionStart succeeds (never refuses)" '[ "$SS_RC" -eq 0 ]'
check "T3: misplaced peer's row IS written" '[ -n "$(peers_jsonl_misplaced "$T3_MAIN" "t3-sess")" ]'
check "T3: row is misplaced" '[ "$(peers_jsonl_misplaced "$T3_MAIN" "t3-sess")" = "true" ]'
check "T3: instruction text names EnterWorktree" 'echo "$SS_OUT" | grep -q "EnterWorktree"'
check "T3: instruction text contains the cd-will-not-work sentence" 'echo "$SS_OUT" | grep -q "cd\` will not work"'

# ---- T4: T3's peer, then checkin from the correct cwd -> new row misplaced falsy, exit 0.
# Also the real evidence for NEEDS-EVIDENCE item 2 (peers.jsonl latest-per-key supersession) —
# T3 wrote misplaced:true for this session id; this asserts the checkin-appended row supersedes
# it, read back via peers.jsonl itself, not just checkin's own stdout. ----
checkin "$T3_WT"
check "T4: checkin from the correct cwd exits 0" '[ "$CI_RC" -eq 0 ]'
check "T4: checkin output positively reports misplaced:false" 'echo "$CI_OUT" | grep -q "\"misplaced\": false"'
check "T4: the appended row supersedes T3's misplaced:true row (latest-per-key)" '[ "$(peers_jsonl_misplaced "$T3_MAIN" "t3-sess")" = "false" ]'

# ---- T5: T3's peer, then checkin still from the wrong cwd -> still misplaced true, exit non-zero. ----
T5_MAIN="$SANDBOX/t5-main"
setup_team "$T5_MAIN"
T5_WT="$SANDBOX/t5-wt"
patch_expected_root "$T5_MAIN" "$T5_WT"
sessionstart_role "$T5_MAIN" "t5-sess"
checkin "$T5_MAIN"
check "T5: checkin from the still-wrong cwd exits non-zero" '[ "$CI_RC" -ne 0 ]'
check "T5: checkin still reports misplaced" 'echo "$CI_OUT" | grep -q "\"misplaced\": true"'

# ---- T6 (structural — rewritten per Reviewer F3): the original version set a shell variable
# `checkin` never reads and asserted a tautology over it — one mutation felled T5 and T6 together,
# zero marginal coverage. §3.4's rule ("a tool's success return is not evidence") is pinned by
# CONSTRUCTION instead: checkin's flag surface offers no channel through which a caller could hand
# it a "this actually moved" signal, and its misplaced computation reduces to exactly one
# comparison against the observed cwd. Matches T11's precedent — assert the property directly
# rather than trying to exercise a scenario that has no way to arise. ----
CHECKIN_CASE=$(sed -n '/case "checkin": {/,/case "reap": {/p' "$H/roster.mjs")
CHECKIN_FLAGS_LINE='const CHECKIN_FLAGS = new Set(["cwd", "team", "orchestrator-pid"]);'
check "T6: checkin's own case body admits no success/relocated/verified-move trust signal" \
  '! echo "$CHECKIN_CASE" | grep -qiE "success|relocated|verifiedmove|trustsignal"'
check "T6: misplaced is computed from exactly the observed-cwd-vs-expected_root comparison, nothing else" \
  'echo "$CHECKIN_CASE" | grep -qF "observed !== expectedRoot"'
check "T6: CHECKIN_FLAGS is exactly {cwd, team, orchestrator-pid} — no fourth, signal-shaped flag exists to trust" \
  'grep -qF "$CHECKIN_FLAGS_LINE" "$H/roster.mjs"'

# ---- T7: team record with no expected_root (pre-0036) -> no detection, no misplaced, no instruction text. ----
T7="$SANDBOX/t7-repo"
mkdir -p "$T7/.claude"
(cd "$T7" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$T7" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$T7" >/dev/null
mkdir -p "$T7/.claude/hierarchy"
cat > "$T7/.claude/hierarchy/team.json" <<EOF
{"version":1,"team_id":"pre0036","created":"2026-01-01T00:00:00-00:00","roster_level":"repo","transport":"terminal","orchestrator":{"session_id":null,"pid":$$},"members":[{"role":"implementor","name":"$(basename "$T7")-implementor","route":"peer","transport_id":"x"}],"partial":false}
EOF
sessionstart_role "$T7" "t7-sess"
check "T7: SessionStart succeeds against a pre-0036 team (no expected_root)" '[ "$SS_RC" -eq 0 ]'
check "T7: absent expected_root -> misplaced field itself absent (absent != mismatch, distinct from an explicit false)" '[ "$(peers_jsonl_misplaced "$T7" "t7-sess")" = "absent" ]'
check "T7: no instruction text emitted" '! echo "$SS_OUT" | grep -q "Misplaced:"'

# ---- T8: expected_root and observed cwd differ only by a symlink -> NOT flagged misplaced.
# Constructed explicitly (not relying on ambient /tmp), so this does not pass spuriously on Linux. ----
T8_REAL="$SANDBOX/t8-real"
setup_team "$T8_REAL"
T8_LINK="$SANDBOX/t8-link"
ln -s "$T8_REAL" "$T8_LINK"
sessionstart_role "$T8_LINK" "t8-sess"
check "T8: SessionStart succeeds" '[ "$SS_RC" -eq 0 ]'
check "T8: symlink-vs-real-path divergence is NOT flagged misplaced" '[ "$(peers_jsonl_misplaced "$T8_REAL" "t8-sess")" = "false" ]'

# ---- T9: roster teams with one misplaced member -> reports it, with the observed cwd. ----
T9_MAIN="$SANDBOX/t9-main"
setup_team "$T9_MAIN"
T9_WT="$SANDBOX/t9-wt"
patch_expected_root "$T9_MAIN" "$T9_WT"
sessionstart_role "$T9_MAIN" "t9-sess"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" teams --cwd "$T9_MAIN" 2>&1); RC=$?
check "T9: roster teams succeeds" '[ "$RC" -eq 0 ]'
check "T9: reports the misplaced member" '! echo "$OUT" | grep -q "\"misplaced_members\": \[\]" && echo "$OUT" | grep -q "\"role\": \"implementor\""'
check "T9: reports its observed cwd" "echo \"\$OUT\" | grep -q \"$(echo "$T9_MAIN" | sed 's/[\/&]/\\&/g')\""

# ---- T10: misplaced peer is still visible to roster teams and dismissable by roster dismiss —
# §3.2's whole argument for recording rather than refusing. ----
T10_MAIN="$SANDBOX/t10-main"
setup_team "$T10_MAIN"
T10_WT="$SANDBOX/t10-wt"
patch_expected_root "$T10_MAIN" "$T10_WT"
sessionstart_role "$T10_MAIN" "t10-sess"
NAME="$(basename "$T10_MAIN")-implementor"
DISMISS_OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" dismiss "$NAME" --cwd "$T10_MAIN" 2>&1); DISMISS_RC=$?
check "T10: a misplaced peer is dismissable, not invisible" '[ "$DISMISS_RC" -eq 0 ] && echo "$DISMISS_OUT" | grep -q "$NAME"'

# ---- T11 (Ultra-Advisor scrutiny pass): mirror case — orchestrator inside a worktree, peer at
# the main checkout root. 0027 keeps hierarchyDir worktree-local, so the peer's own SessionStart
# resolves a DIFFERENT hierarchy dir than the one the team (and its expected_root) was written
# to — it cannot see that team.json at all. This is a confirmed, structural limitation of §3.1's
# design (not a bug to silently pass around): assert explicitly that detection CANNOT fire here,
# and name why, rather than let the test pass by finding nothing. Deliberately does NOT call
# setup_team on T11_MAIN (that would write a team.json there itself) — only the roster is seeded
# at the main root; the committed team, with its expected_root, is written ONLY from the worktree. ----
T11_MAIN="$SANDBOX/t11-main"
mkdir -p "$T11_MAIN/.claude"
(cd "$T11_MAIN" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$T11_MAIN" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$T11_MAIN" >/dev/null
T11_WT="$SANDBOX/t11-wt"
(cd "$T11_MAIN" && git worktree add -q -b t11-wt "$T11_WT" >/dev/null 2>&1)
mkdir -p "$T11_WT/.claude"
HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo \
  --verified "[\"$(basename "$T11_WT")-implementor\"]" --orchestrator-pid "$$" --cwd "$T11_WT" >/dev/null
check "T11 precondition: team.json exists under the worktree's own hierarchy dir" '[ -f "$T11_WT/.claude/hierarchy/team.json" ]'
check "T11 precondition: no team.json under the main checkout's hierarchy dir (0027's worktree-local split)" '[ ! -f "$T11_MAIN/.claude/hierarchy/team.json" ]'
sessionstart_role "$T11_MAIN" "t11-sess"
check "T11: SessionStart still succeeds (never refuses/crashes)" '[ "$SS_RC" -eq 0 ]'
if echo "$SS_OUT" | grep -q "Misplaced:"; then
  check "T11: detection DID fire — mirror case is NOT the blind spot in this build" 'true'
else
  MIRR="$(peers_jsonl_misplaced "$T11_MAIN" "t11-sess")"
  check "T11: detection explicitly could NOT fire — recorded reason: peer's SessionStart resolves the main checkout's own hierarchy dir (0027 §2, worktree-local), which never received the worktree-written team.json/expected_root, so §3.2's comparison has no expected_root to compare against (absent, not a false negative it silently swallowed)" \
    '[ "$MIRR" = "absent" ] && [ ! -f "$T11_MAIN/.claude/hierarchy/team.json" ]'
fi

# ---- T11b (Reviewer F1/F2 regression guard): checkin invoked through a REAL subshell — the
# production process shape (a Bash tool call's node process is a transient shell's child, not the
# session; every checkin() call above deliberately avoids that shape to keep setup simple). F1's
# fix reads CLAUDE_PID/--orchestrator-pid before ever falling back to process.ppid, so this must
# still resolve even though process.ppid here is NOT this script's own $$. ----
F2_OUT=$( (HOME="$FAKEHOME" node "$H/roster.mjs" checkin --cwd "$T3_WT") 2>&1 ); F2_RC=$?
check "T11b: checkin through a real subshell (production process shape) still resolves its own session, exit 0" '[ "$F2_RC" -eq 0 ]'
check "T11b: still reports misplaced:false" 'echo "$F2_OUT" | grep -q "\"misplaced\": false"'

# ---- T12 (Architect F4, BLOCKING — falsifying test): two teams sharing the same role name; team
# A's implementor is misplaced, team B's is not. Rows are hand-crafted (append_peer_row) rather
# than run through SessionStart, so this isolates `roster teams`'s correlation rule (§3.6) from
# how a row's `team` field was populated. Must be seen FAILING against the pre-F4 (role-only)
# correlation before being scored as coverage — see the mutation-testing note at the bottom. ----
T12="$SANDBOX/t12-repo"
mkdir -p "$T12/.claude"
(cd "$T12" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --team teama --cwd "$T12" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --team teama --cwd "$T12" >/dev/null
HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --team teama \
  --verified '["teama-implementor"]' --orchestrator-pid "$$" --cwd "$T12" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --team teamb --cwd "$T12" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --team teamb --cwd "$T12" >/dev/null
HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --team teamb \
  --verified '["teamb-implementor"]' --orchestrator-pid "$$" --cwd "$T12" >/dev/null
append_peer_row "$T12" "t12a-sess" "implementor" "teama" "$$" "true" "$SANDBOX/t12-wrong-a"
append_peer_row "$T12" "t12b-sess" "implementor" "teamb" "$$" "false" "$T12"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" teams --cwd "$T12" 2>&1); RC=$?
check "T12: roster teams succeeds" '[ "$RC" -eq 0 ]'
check "T12: team A's misplaced implementor IS flagged" \
  '[ "$(team_row_field "$OUT" "teama" "misplaced_members")" != "[]" ]'
check "T12: team B's implementor is NOT flagged despite the same role name (cross-team false positive)" \
  '[ "$(team_row_field "$OUT" "teamb" "misplaced_members")" = "[]" ]'

# ---- T13 (Architect F6, BLOCKING — falsifying test): a NAMED team (--team teamx), peer misplaced
# -> detection fires and instruction text is emitted at SessionStart itself, no manual checkin
# needed. Only one team exists, so role resolution is unambiguous. ----
T13="$SANDBOX/t13-repo"
setup_named_team "$T13" "teamx"
T13_WT="$T13/wt-subdir"
patch_expected_root_team "$T13" "teamx" "$T13_WT"
sessionstart_role "$T13" "t13-sess"
check "T13: SessionStart succeeds" '[ "$SS_RC" -eq 0 ]'
check "T13: named-team peer's row is written and flagged misplaced" '[ "$(peers_jsonl_misplaced "$T13" "t13-sess")" = "true" ]'
check "T13: instruction text fires at SessionStart, no manual checkin needed" 'echo "$SS_OUT" | grep -q "Misplaced:"'

# ---- T14: a team with two members of the same role, one misplaced -> role match is ambiguous,
# so no member is flagged; counted as misplaced_unattributed instead. Row carries an EXPLICIT
# team (JSON null, the default team) — this tests the role-ambiguity branch, not the
# absent-team branch (that's T16). ----
T14="$SANDBOX/t14-repo"
mkdir -p "$T14/.claude/hierarchy"
(cd "$T14" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$T14" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$T14" >/dev/null
cat > "$T14/.claude/hierarchy/team.json" <<EOF
{"version":1,"team_id":"t14team","created":"2026-01-01T00:00:00-00:00","roster_level":"repo","transport":"terminal","orchestrator":{"session_id":null,"pid":$$},"members":[{"role":"implementor","name":"impl-1","route":"peer","transport_id":"x"},{"role":"implementor","name":"impl-2","route":"peer","transport_id":"y"}],"partial":false,"expected_root":"$T14"}
EOF
append_peer_row "$T14" "t14-sess" "implementor" "__null__" "$$" "true" "$SANDBOX/t14-wrong"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" teams --cwd "$T14" 2>&1); RC=$?
check "T14: roster teams succeeds" '[ "$RC" -eq 0 ]'
check "T14: no member flagged (role matches more than one member)" '[ "$(team_row_field "$OUT" "null" "misplaced_members")" = "[]" ]'
check "T14: misplaced_unattributed = 1" '[ "$(team_row_field "$OUT" "null" "misplaced_unattributed")" = "1" ]'

# ---- T15: a session that resolves to no team at all (roster exists, no team ever created) ->
# detection skips entirely: no instruction text, no misplaced field, not even an explicit false. ----
T15="$SANDBOX/t15-repo"
mkdir -p "$T15/.claude"
(cd "$T15" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$T15" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$T15" >/dev/null
sessionstart_role "$T15" "t15-sess"
check "T15: SessionStart succeeds with no team to resolve" '[ "$SS_RC" -eq 0 ]'
check "T15: no instruction text emitted" '! echo "$SS_OUT" | grep -q "Misplaced:"'
check "T15: misplaced field itself absent (skipped, not a silent false)" '[ "$(peers_jsonl_misplaced "$T15" "t15-sess")" = "absent" ]'

# ---- T16: a peer record with `team` absent entirely (pre-0036 row) -> never attributed by role
# alone, even when role is otherwise unambiguous within the team; counted as unattributed. ----
T16="$SANDBOX/t16-repo"
setup_team "$T16"
append_peer_row "$T16" "t16-sess" "implementor" "" "$$" "true" "$SANDBOX/t16-wrong"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" teams --cwd "$T16" 2>&1); RC=$?
check "T16: roster teams succeeds" '[ "$RC" -eq 0 ]'
check "T16: team-absent row is never flagged, even though role alone is unambiguous" '[ "$(team_row_field "$OUT" "null" "misplaced_members")" = "[]" ]'
check "T16: counted as unattributed instead" '[ "$(team_row_field "$OUT" "null" "misplaced_unattributed")" = "1" ]'

# ---- T17 (Reviewer G1, BLOCKING — falsifying test): T14's exact team shape (default team with
# two implementors) plus a second, single-implementor named team — but this time run resolution
# itself (sessionstart_role), which T14 never did (it only drove `roster teams`' output path via
# a hand-crafted row). Old (buggy) resolveSessionTeam treated the two-member default team as "not
# a candidate" (length !== 1) and silently resolved to the unrelated single-member named team
# instead — misattributing a CORRECTLY-placed peer as misplaced against the wrong team's root. ----
T17="$SANDBOX/t17-repo"
mkdir -p "$T17/.claude/hierarchy"
(cd "$T17" && git init -q && git config user.email t@t.com && git config user.name t)
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$T17" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$T17" >/dev/null
cat > "$T17/.claude/hierarchy/team.json" <<EOF
{"version":1,"team_id":"t17teamA","created":"2026-01-01T00:00:00-00:00","roster_level":"repo","transport":"terminal","orchestrator":{"session_id":null,"pid":$$},"members":[{"role":"implementor","name":"impl-1","route":"peer","transport_id":"x"},{"role":"implementor","name":"impl-2","route":"peer","transport_id":"y"}],"partial":false,"expected_root":"$(realpath_of "$T17")"}
EOF
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --team teamb --cwd "$T17" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --team teamb --cwd "$T17" >/dev/null
HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/roster.mjs" create --commit --transport terminal --roster-level repo --team teamb \
  --verified '["teamb-implementor"]' --orchestrator-pid "$$" --cwd "$T17" >/dev/null
patch_expected_root_team "$T17" "teamb" "$SANDBOX/t17-teamb-elsewhere"
sessionstart_role "$T17" "t17-sess"
check "T17 (G1): SessionStart succeeds" '[ "$SS_RC" -eq 0 ]'
check "T17 (G1): a correctly-placed peer in the ambiguous (2-member) team is NOT misattributed to the unrelated single-member team" \
  '[ "$(peers_jsonl_misplaced "$T17" "t17-sess")" = "absent" ]'
check "T17 (G1): no instruction text emitted (resolution correctly skipped, not guessed)" '! echo "$SS_OUT" | grep -q "Misplaced:"'

# ---- T18 (Reviewer G7): a misplaced row with a dead pid is excluded from both misplaced_members
# and misplaced_unattributed (F5's liveness filter) — every prior append_peer_row call used a live
# pid ($$), so this path was never exercised. ----
T18="$SANDBOX/t18-repo"
setup_team "$T18"
( : ) & T18_DEAD_PID=$!
wait "$T18_DEAD_PID" 2>/dev/null
append_peer_row "$T18" "t18-sess" "implementor" "__null__" "$T18_DEAD_PID" "true" "$SANDBOX/t18-wrong"
OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" teams --cwd "$T18" 2>&1); RC=$?
check "T18 (G7): roster teams succeeds" '[ "$RC" -eq 0 ]'
check "T18 (G7): a dead-pid misplaced row is not flagged" '[ "$(team_row_field "$OUT" "null" "misplaced_members")" = "[]" ]'
check "T18 (G7): a dead-pid misplaced row is not counted unattributed either" '[ "$(team_row_field "$OUT" "null" "misplaced_unattributed")" = "0" ]'

# ---- T19 (Reviewer G8): checkin --team <typo> fails explicitly, matching 0032 §3.4b's precedent
# for an explicit-but-nonexistent --team, rather than silently reporting misplaced:false forever. ----
T19="$SANDBOX/t19-repo"
setup_team "$T19"
sessionstart_role "$T19" "t19-sess"
CI_TYPO_OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" checkin --cwd "$T19" --team no-such-team --orchestrator-pid "$$" 2>&1); CI_TYPO_RC=$?
check "T19 (G8): checkin with a typo'd --team fails, not a silent misplaced:false" \
  '[ "$CI_TYPO_RC" -ne 0 ] && echo "$CI_TYPO_OUT" | grep -qi "no such team"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
