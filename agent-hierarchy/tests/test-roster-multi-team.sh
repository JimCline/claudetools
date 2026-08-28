#!/bin/bash
# agent-hierarchy — multi-roster-per-orchestrator (spec 0011). Shared files
# (peers.jsonl, msgs/, gates.jsonl) stay in one hierarchyDir(cwd) per repo,
# tagged with a `team:` field and filtered read-side; only team.json splits
# per team (team.json = default, teams/<name>.json = named teams).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-roster-multi-team.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
NODE_BIN="$(command -v node)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
PEERS="$HD/peers.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
BASE="$(basename "$PROJ")"

run_roster() { # <roster.mjs args...>
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" "$NODE_BIN" "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
run_msg() { # <msg.mjs args...>
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" "$NODE_BIN" "$H/msg.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
}
eval_hier() { # <js expr over L (lib-hier), C (lib-config), R (lib-roster)>
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" "$NODE_BIN" --input-type=module -e "
    const L = await import('$H/lib-hier.mjs'); const C = await import('$H/lib-config.mjs'); const R = await import('$H/lib-roster.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}
append_peer() { # <json fragment, e.g. '"status":"seen","role":"reviewer","name":"x","team":"alpha"'>
  node -e 'const fs=require("fs");const [f,frag]=process.argv.slice(1);
    fs.appendFileSync(f, "{\"type\":\"peer\"," + frag + ",\"ts\":\"" + new Date().toISOString() + "\"}\n");' "$PEERS" "$1"
}

# ==== 1 — baseline invariance: with no --team anywhere, the existing suite
# passes unchanged. Run first, not last (spec 0011 §11 test 1). ====
OUT=$(bash "$PLUGIN/tests/test-roster.sh" 2>&1); RC=$?
check "1: baseline invariance — test-roster.sh (no --team anywhere) passes unchanged" '[ "$RC" -eq 0 ]'

# ==== 2 — two teams, isolated rosters from the shared peers.jsonl ====
run_roster create --team alpha --commit --verified '[{"name":"alpha-reviewer","role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "2a: create --team alpha --commit succeeds" '[ "$RC" -eq 0 ]'
run_roster create --team beta --commit --verified '[{"name":"beta-reviewer","role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$"
check "2b: create --team beta --commit succeeds" '[ "$RC" -eq 0 ]'
append_peer '"status":"seen","role":"reviewer","name":"alpha-reviewer","team":"alpha"'
append_peer '"status":"seen","role":"reviewer","name":"beta-reviewer","team":"beta"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').reviewer.map(i => i.name))"
check "2c: alpha's roster() lists exactly alpha-reviewer, zero of beta's (shared peers.jsonl)" '[ "$OUT" = "[\"alpha-reviewer\"]" ]'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'beta'}), '$BASE').reviewer.map(i => i.name))"
check "2d: beta's roster() lists exactly beta-reviewer, zero of alpha's" '[ "$OUT" = "[\"beta-reviewer\"]" ]'

# ---- 2 (cont'd), B2: real name derivation (not hand-fed --verified) also
# resolves correctly under --team — init/add build the roster definition,
# create --plan derives the actual prefixed member name via
# rosterMemberNames + teamPrefix(cwd, team).
run_roster init --level repo --route peer
check "2e: init --level repo --route peer succeeds" '[ "$RC" -eq 0 ]'
run_roster add --level repo --role reviewer --model sonnet
check "2f: add --level repo --role reviewer succeeds" '[ "$RC" -eq 0 ]'
run_roster create --team gamma --plan
check "2g: create --team gamma --plan succeeds" '[ "$RC" -eq 0 ]'
check "2h: create --team gamma --plan derives a real name from the roster (not a hand-fed --verified one)" \
  'echo "$OUT" | grep -q "\"name\": \"gamma-reviewer\""'

# ==== 3 — exchange-count isolation, including the to_name: null case (§7.7) ====
run_msg new --to reviewer --from orchestrator --slug for-alpha-named --to-name alpha-reviewer --team alpha
check "3a: msg.mjs new --team alpha (named) succeeds" '[ "$RC" -eq 0 ]'
run_msg new --to reviewer --from orchestrator --slug for-alpha-any --team alpha
check "3b: msg.mjs new --team alpha (to_name: null) succeeds" '[ "$RC" -eq 0 ]'
run_msg list --team beta
check "3c: beta's msg.mjs list shows none of alpha's exchanges (including the unnamed one)" \
  '! echo "$OUT" | grep -q "for-alpha-named" && ! echo "$OUT" | grep -q "for-alpha-any"'
run_msg list --team alpha
check "3d: alpha's msg.mjs list shows both of alpha's exchanges" \
  'echo "$OUT" | grep -q "for-alpha-named" && echo "$OUT" | grep -q "for-alpha-any"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'beta'}), '$BASE').reviewer.map(i => [i.name, i.openBriefs]))"
check "3e: beta-reviewer's openBriefs is 0 — alpha's to_name:null exchange does not leak (closes §7.7's leak)" \
  '[ "$OUT" = "[[\"beta-reviewer\",0]]" ]'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').reviewer.map(i => [i.name, i.openBriefs, i.unassigned]))"
check "3f: alpha-reviewer's openBriefs is 2 (named + unassigned), unassigned is 1" \
  '[ "$OUT" = "[[\"alpha-reviewer\",2,1]]" ]'

# ==== 4 — unattributed bucket: a nameless status:"up" record appears in
# `unattributed` for every team and in no named team's role bucket (§4.2). ====
node -e 'const fs=require("fs");const [f]=process.argv.slice(1);
  fs.appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:"reviewer",session_id:"nameless-s",pid:process.ppid,ts:new Date().toISOString()})+"\n");' "$PEERS"
eval_hier "L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').unattributed.some(i => i.name === null && i.role === 'reviewer')"
check "4a: nameless up record appears in alpha's unattributed bucket" '[ "$OUT" = true ]'
eval_hier "L.roster('$HD', C.resolveConfig('$PROJ', {team:'beta'}), '$BASE').unattributed.some(i => i.name === null && i.role === 'reviewer')"
check "4b: nameless up record appears in beta's unattributed bucket too" '[ "$OUT" = true ]'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').reviewer.map(i => i.name))"
check "4c: nameless record is NOT in alpha's (a named team's) reviewer role bucket" '! echo "$OUT" | grep -q "reviewer@"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'beta'}), '$BASE').reviewer.map(i => i.name))"
check "4d: nameless record is NOT in beta's reviewer role bucket either" '! echo "$OUT" | grep -q "reviewer@"'

# ---- 4 (cont'd), S1/§4.2.1: the SAME nameless record also surfaces under
# the default team — in unattributed AND synthesized into its role bucket as
# `${role}@${session_id.slice(0,8)}` (baseline invariance; not exclusive
# with the named-team exclusion asserted in 4a-4d above).
eval_hier "L.roster('$HD', C.resolveConfig('$PROJ', {team:null}), '$BASE').unattributed.some(i => i.name === null && i.role === 'reviewer')"
check "4e: the same nameless record ALSO appears in the default team's unattributed bucket" '[ "$OUT" = true ]'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:null}), '$BASE').reviewer.map(i => i.name))"
check "4f: ...AND is synthesized into the default team's reviewer bucket as reviewer@nameless (§4.2.1 carve-out)" 'echo "$OUT" | grep -q "reviewer@nameless"'

# ==== 5 — static grep, redesigned (amendment (a)): no file outside
# lib-roster.mjs constructs a "team.json" path; only lib-roster.mjs's
# teamPath does. Widened (N3) to catch single- and double-quoted forms. ====
GREP_HITS=$(grep -rlE "['\"]team\.json['\"]" "$H" 2>/dev/null)
check "5: only lib-roster.mjs references the literal \"team.json\" path string" '[ "$GREP_HITS" = "$H/lib-roster.mjs" ]'

# ==== 6 — degradation: a record with no `team` field, and a missing
# teams/<T>.json, both resolve to the default team without throwing (0009 §8.12). ====
append_peer '"status":"seen","role":"reviewer","name":"legacy-reviewer"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:null}), '$BASE').reviewer.map(i => i.name))"
check "6a: untagged (no team field) record resolves under the default team, no throw" 'echo "$OUT" | grep -q "legacy-reviewer"'
eval_hier "(() => { try { const r = L.roster('$HD', C.resolveConfig('$PROJ', {team:'ghost'}), '$BASE'); return 'ok:' + JSON.stringify(r.reviewer); } catch (e) { return 'threw:' + e.message; } })()"
check "6b: a missing teams/ghost.json resolves without throwing" 'echo "$OUT" | grep -q "^ok:"'

# ==== 7 — collision refusal: with a live default team, bare create fails
# naming a candidate and --team (§5.3/§7.2). ====
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$HD', { version: 1, team_id: 'live-default', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 'orch', pid: $$ }, members: [{ name: '$BASE-architect', role: 'architect' }], partial: false }, null);
"
run_roster create --plan
check "7a: bare create fails when a live default team already exists" '[ "$RC" -ne 0 ]'
check "7b: refusal names the live team id" 'echo "$OUT" | grep -q "live-default"'
check "7c: refusal names an auto-derived --team candidate (never the bare prefix)" 'echo "$OUT" | grep -qF -- "--team $BASE-2"'

# ==== 8 — alias refusal: --set with an active team scope fails; the
# read-only report names both the config-level alias and the team scope (§7.4). ====
run_roster alias --set x --team alpha
check "8a: alias --set with --team active fails" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "team scope is active"'
run_roster alias --team alpha
check "8b: alias (read-only) --team alpha reports both the team scope and its prefix" \
  'echo "$OUT" | grep -q "\"teamScope\": \"alpha\"" && echo "$OUT" | grep -q "\"prefix\": \"alpha\""'

# ==== 9 — name validation: create --team architect is rejected by spec
# 0010's exact role-token collision `why` text. ====
run_roster create --team architect --plan
check "9: create --team architect rejected by spec 0010's role-token collision text" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "alias collides with role-token matching"'

# ==== 10 — rename case: a member renamed out of team.json while its
# peers.jsonl records still carry the old name shows as unattributed, not a
# member (§7.5). Runs last — mutates alpha's membership used by tests 2-4. ====
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  const t = R.readTeam('$HD', 'alpha');
  t.members = [{ name: 'alpha-reviewer2', role: 'reviewer' }];
  R.writeTeam('$HD', t, 'alpha');
"
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').reviewer.map(i => i.name))"
check "10a: renamed-out member no longer appears in alpha's reviewer bucket" '! echo "$OUT" | grep -q "\"alpha-reviewer\""'
eval_hier "L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').unattributed.some(i => i.name === 'alpha-reviewer')"
check "10b: renamed-out member's old-name record shows unattributed instead (stale tag, membership wins)" '[ "$OUT" = true ]'

# ==== 11 (spec 0011 §11 test 6) — static: no file under hooks/ calls
# teamPrefix(/teamPrefixInfo( with exactly one argument. This is what makes
# §9.1's rule enforceable instead of a file list someone must remember to
# re-derive (a file list is exactly what missed 3 of 4 B3-affected sites). ====
SINGLE_ARG_HITS=$(grep -rnE '\bteamPrefix(Info)?\(\s*[A-Za-z_$][A-Za-z0-9_.]*\s*\)' "$H"/*.mjs 2>/dev/null)
check "11: no file in hooks/ calls teamPrefix(/teamPrefixInfo( with a single argument" '[ -z "$SINGLE_ARG_HITS" ]'

# ==== 12 (spec 0011 §11 test 7, BLOCKING) — security-adjacent: with a named
# team active (rung 2 — sessionId matches the team's orchestrator.session_id),
# a SendMessage to one of its own members must resolve a role and reach
# 0009's global-scope confirm gate — POSITIVELY producing a deny, not merely
# avoiding a crash. The failing state here is silence, so "no exception
# thrown" would pass on the broken (pre-B3) code too. Isolated sandbox: no
# repo-level roster/config, so scope A/B trigger naturally. ====
S12="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-gate-test.XXXXXX")"
S12="$(cd "$S12" && pwd -P)"
S12HOME="$S12/home"; S12HD="$S12/hier"; S12PROJ="$S12/myrepo"
mkdir -p "$S12HOME/.claude" "$S12PROJ/.claude" "$S12HD"
cat > "$S12HOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a"] } } }
EOF
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S12HD', { version: 1, team_id: 'epsilon', created: new Date().toISOString(), roster_level: 'global', transport: 'terminal',
    orchestrator: { session_id: 's12-epsilon', pid: $$ }, members: [{ name: 'epsilon-reviewer', role: 'reviewer' }], partial: false }, 'epsilon');
"
S12_PAYLOAD=$(S12PROJ="$S12PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S12PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s12-epsilon" "epsilon-reviewer" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S12_PAYLOAD" | HOME="$S12HOME" AGENT_HIERARCHY_DIR="$S12HD" "$NODE_BIN" "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
check "12: named-team SendMessage to its own member resolves a role and reaches 0009's scope gate — POSITIVE deny, not silence" \
  'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\""'
rm -rf "$S12"

# ==== 13 (spec 0011 §11 test 9) — S4: CLI rung 3 — CLAUDE_PID matched
# against a live team's orchestrator.pid resolves that team without --team;
# a dead pid falls through to the default team (§4.4 rung 3, pidAlive-
# guarded). Isolated sandbox: avoids colliding with other tests' shared use
# of $$ as orchestrator.pid. ====
S13="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-pid-test.XXXXXX")"
S13="$(cd "$S13" && pwd -P)"
S13HOME="$S13/home"; S13HD="$S13/hier"; S13PROJ="$S13/myrepo"
mkdir -p "$S13HOME/.claude" "$S13PROJ/.claude" "$S13HD"
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S13HD', { version: 1, team_id: 'zeta', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 'orch-zeta', pid: $$ }, members: [{ name: 'zeta-reviewer', role: 'reviewer' }], partial: false }, 'zeta');
"
OUT=$(HOME="$S13HOME" AGENT_HIERARCHY_DIR="$S13HD" "$NODE_BIN" "$H/msg.mjs" new --to reviewer --from orchestrator --slug for-zeta --team zeta --cwd "$S13PROJ" 2>&1); RC=$?
check "13a: msg.mjs new --team zeta succeeds (seeds an exchange to compare against)" '[ "$RC" -eq 0 ]'
OUT=$(HOME="$S13HOME" AGENT_HIERARCHY_DIR="$S13HD" CLAUDE_PID="$$" "$NODE_BIN" "$H/msg.mjs" list --cwd "$S13PROJ" 2>&1); RC=$?
check "13b: msg.mjs list with CLAUDE_PID=\$\$ (matches zeta's live orchestrator.pid), no --team, resolves zeta" 'echo "$OUT" | grep -q "for-zeta"'
( sleep 0.01 ) & DEADPID13=$!
wait "$DEADPID13" 2>/dev/null
OUT=$(HOME="$S13HOME" AGENT_HIERARCHY_DIR="$S13HD" CLAUDE_PID="$DEADPID13" "$NODE_BIN" "$H/msg.mjs" list --cwd "$S13PROJ" 2>&1); RC=$?
check "13c: msg.mjs list with a dead CLAUDE_PID, no --team, falls through to the default team (not zeta)" '! echo "$OUT" | grep -q "for-zeta"'
rm -rf "$S13"

# ==== 14 (amendment (c), spec 0011 §5.3.2/§7.9) — bare `create` in a fresh
# repo succeeds silently, unprompted: no TTY, no stdin answer available.
# Confirming/overriding the team name lives entirely in SKILL.md (an
# agent-facing prompt before this CLI call); roster.mjs create itself must
# stay byte-identical to pre-amendment behavior. ====
S14="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-freshcreate-test.XXXXXX")"
S14="$(cd "$S14" && pwd -P)"
S14HOME="$S14/home"; S14HD="$S14/hier"; S14PROJ="$S14/myrepo"
mkdir -p "$S14HOME/.claude" "$S14PROJ/.claude" "$S14HD"
OUT=$(HOME="$S14HOME" AGENT_HIERARCHY_DIR="$S14HD" "$NODE_BIN" "$H/roster.mjs" create --commit --verified '[{"name":"myrepo-reviewer","role":"reviewer","route":"peer"}]' --transport terminal --roster-level repo --orchestrator-pid "$$" --cwd "$S14PROJ" </dev/null 2>&1); RC=$?
check "14a: bare create --commit in a fresh repo succeeds unprompted, no TTY/stdin answer" '[ "$RC" -eq 0 ]'
check "14b: base team.json was written" '[ -f "$S14HD/team.json" ]'
rm -rf "$S14"

# ==== 15 (amendment (d), spec 0011 §4.5 — was called "test 12" in the
# amendment's prose, renumbered to avoid colliding with the existing test 12
# above) — pins the named-team attribution table's rows 3 and 4: row 3 (a
# name belonging to ANOTHER team) is excluded entirely, not unattributed; row
# 4 (a name owned by no team at all) IS unattributed, not silently dropped.
# Reuses alpha/beta from tests 2-4 (post test-10 rename of alpha-reviewer). ====
append_peer '"status":"seen","role":"reviewer","name":"ghost-nobody"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').unattributed.map(i => i.name))"
check "15a: alpha's unattributed does NOT include beta-reviewer (row 3: another team's member is excluded, not unattributed)" '! echo "$OUT" | grep -q "beta-reviewer"'
check "15b: alpha's unattributed DOES include ghost-nobody (row 4: a name owned by no team)" 'echo "$OUT" | grep -q "ghost-nobody"'
eval_hier "JSON.stringify(L.roster('$HD', C.resolveConfig('$PROJ', {team:'alpha'}), '$BASE').reviewer.map(i => i.name))"
check "15c: neither beta-reviewer nor ghost-nobody appear in alpha's reviewer bucket" '! echo "$OUT" | grep -qE "beta-reviewer|ghost-nobody"'

# ==== 16 (amendment (d), spec 0011 §9.1 — was called "test 13" in the
# amendment's prose, renumbered to avoid colliding with the existing test 13
# above) — distinguishes resolveMemberTeam(dir,to) from
# teamMemberByName(dir,to,resolved.team): a named team's member whose name
# carries no role-token substring and no roster/config record, reached with
# NO session_id (so rung 2 cannot resolve resolved.team — it stays null).
# Under the OLD team-scoped mechanism this role lookup misses (default
# team's members don't include it) and the gate goes silently dark: no
# deny. Under resolveMemberTeam it is found via an all-teams name search
# regardless of resolved.team, and the gate POSITIVELY denies. ====
S16="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-mechanism-test.XXXXXX")"
S16="$(cd "$S16" && pwd -P)"
S16HOME="$S16/home"; S16HD="$S16/hier"; S16PROJ="$S16/myrepo"
mkdir -p "$S16HOME/.claude" "$S16PROJ/.claude" "$S16HD"
cat > "$S16HOME/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {
  "reviewer": { "model": "opus", "dispatch": "peer", "peer": ["rev-a"] } } }
EOF
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S16HD', { version: 1, team_id: 'theta', created: new Date().toISOString(), roster_level: 'global', transport: 'terminal',
    orchestrator: { session_id: 's16-theta', pid: $$ }, members: [{ name: 'quill', role: 'reviewer' }], partial: false }, 'theta');
"
S16_PAYLOAD=$(S16PROJ="$S16PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S16PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "" "quill" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S16_PAYLOAD" | HOME="$S16HOME" AGENT_HIERARCHY_DIR="$S16HD" "$NODE_BIN" "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
check "16: resolveMemberTeam finds a named team's member with no session_id available — POSITIVE deny, not silence" \
  'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\""'
rm -rf "$S16"

# ==== 17 (amendment (f), spec 0011 §9.3/§9.4/§7.10 — was called "test 14" in
# the amendment's prose, renumbered to avoid colliding with the existing test
# 14 above) — pins the withdrawal: ultra-gate's peer-hood check is question
# (C), prefix-only, with NO team-membership lookup. Gates its own team's
# conventional `<prefix>-ultra-advisor`; does NOT gate a sibling team's
# `<other-prefix>-ultra-advisor` — that is the intended behaviour (§7.10),
# not a hole, and this test exists so nobody "fixes" it back to (A). Team U
# is a REAL team with a real U-ultra-advisor member (not merely absent from
# the fixture), so 17b exercises actual cross-team non-gating rather than
# passing vacuously because resolveMemberTeam can't find team U at all. ====
S17="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-ultragate-test.XXXXXX")"
S17="$(cd "$S17" && pwd -P)"
S17HOME="$S17/home"; S17HD="$S17/hier"; S17PROJ="$S17/myrepo"
mkdir -p "$S17HOME/.claude" "$S17PROJ/.claude" "$S17HD"
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S17HD', { version: 1, team_id: 'T', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 's17-t', pid: $$ }, members: [], partial: false }, 'T');
  R.writeTeam('$S17HD', { version: 1, team_id: 'U', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 's17-u', pid: $$ }, members: [{ name: 'U-ultra-advisor', role: 'ultra-advisor' }], partial: false }, 'U');
"
S17_PAYLOAD_OWN=$(S17PROJ="$S17PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S17PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s17-t" "T-ultra-advisor" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S17_PAYLOAD_OWN" | HOME="$S17HOME" AGENT_HIERARCHY_DIR="$S17HD" "$NODE_BIN" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "17a: ultra-gate gates a SendMessage to its OWN team's conventional T-ultra-advisor" 'echo "$OUT" | grep -q "\"permissionDecision\""'
S17_PAYLOAD_SIB=$(S17PROJ="$S17PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S17PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s17-t" "U-ultra-advisor" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S17_PAYLOAD_SIB" | HOME="$S17HOME" AGENT_HIERARCHY_DIR="$S17HD" "$NODE_BIN" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "17b: ultra-gate does NOT gate a sibling team's U-ultra-advisor (question (C), no membership lookup — withdrawal pinned)" '[ -z "$OUT" ]'
rm -rf "$S17"

# ==== 18 (amendment (g), spec 0011 §9.5 predicate (ii) — was called
# "test 15" in the amendment's prose, renumbered to avoid colliding with
# the existing test 15 above) — INVERTED from its original characterization
# form now that §9.5's gap is closed: a peer session (session_id != team
# T's orchestrator.session_id, so resolved.team === null) escalating to its
# own named team's real T-ultra-advisor IS now gated on first attempt —
# predicate (ii)'s union-of-team-prefixes closes exactly this blackout. ====
S18="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-ultragate-blackout-test.XXXXXX")"
S18="$(cd "$S18" && pwd -P)"
S18HOME="$S18/home"; S18HD="$S18/hier"; S18PROJ="$S18/myrepo"
mkdir -p "$S18HOME/.claude" "$S18PROJ/.claude" "$S18HD"
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S18HD', { version: 1, team_id: 'T', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 's18-orch', pid: $$ }, members: [{ name: 'T-ultra-advisor', role: 'ultra-advisor' }], partial: false }, 'T');
"
S18_PAYLOAD=$(S18PROJ="$S18PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S18PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s18-peer" "T-ultra-advisor" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S18_PAYLOAD" | HOME="$S18HOME" AGENT_HIERARCHY_DIR="$S18HD" "$NODE_BIN" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "18: predicate (ii) — a peer session (session_id != team T's orchestrator.session_id) escalating to its OWN named team's T-ultra-advisor IS gated on first attempt (§9.5 blackout closed)" 'echo "$OUT" | grep -q "\"permissionDecision\""'
rm -rf "$S18"

# ==== 19 (spec 0011 §9.5 predicate (ii), acceptance item "single-team-repo
# byte-identical") — when no named teams exist at all, predicate (ii)'s
# guard condition (`teamNames.length > 0`) never activates, so a peer
# session (unresolved team, exactly the case that would trigger widening if
# any named team existed) sees byte-identical behavior to pre-(ii): gated
# only against the single default prefix, nothing widened. (The other half
# of that claim — an unrelated name is NOT gated — is general
# `isGatedPeerTarget` exact-match behavior untouched by predicate (ii) and
# already covered by tests/test-ultra-gate.sh:60-61/82-83; test 20 covers
# the resolved-team non-widening case, so no separate assertion belongs
# here.) ====
S19="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-ultragate-singleteam-test.XXXXXX")"
S19="$(cd "$S19" && pwd -P)"
S19HOME="$S19/home"; S19HD="$S19/hier"; S19PROJ="$S19/myrepo"
mkdir -p "$S19HOME/.claude" "$S19PROJ/.claude" "$S19HD"
S19_PAYLOAD_DEFAULT=$(S19PROJ="$S19PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S19PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s19-peer" "myrepo-ultra-advisor" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S19_PAYLOAD_DEFAULT" | HOME="$S19HOME" AGENT_HIERARCHY_DIR="$S19HD" "$NODE_BIN" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "19: no named teams exist — the default-prefix ultra-advisor is still gated (byte-identical to pre-(ii))" 'echo "$OUT" | grep -q "\"permissionDecision\""'
rm -rf "$S19"

# ==== 20 (spec 0011 §9.5 predicate (ii), acceptance item "orchestrator-
# resolved session — sibling still NOT gated") — regression pin for §7.10
# post-(ii): when `resolved.team` DOES resolve (session_id matches the
# team's own orchestrator), the guard condition's `resolved.team === null`
# half is false, so gatedPrefixes stays a single-element array — a sibling
# team's ultra-advisor must still NOT be gated, exactly as test 17b already
# established pre-(ii). ====
S20="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-team-ultragate-orch-sibling-test.XXXXXX")"
S20="$(cd "$S20" && pwd -P)"
S20HOME="$S20/home"; S20HD="$S20/hier"; S20PROJ="$S20/myrepo"
mkdir -p "$S20HOME/.claude" "$S20PROJ/.claude" "$S20HD"
node --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  R.writeTeam('$S20HD', { version: 1, team_id: 'T', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 's20-orch-t', pid: $$ }, members: [], partial: false }, 'T');
  R.writeTeam('$S20HD', { version: 1, team_id: 'U', created: new Date().toISOString(), roster_level: 'repo', transport: 'terminal',
    orchestrator: { session_id: 's20-orch-u', pid: $$ }, members: [{ name: 'U-ultra-advisor', role: 'ultra-advisor' }], partial: false }, 'U');
"
S20_PAYLOAD=$(S20PROJ="$S20PROJ" node -e 'const[s,t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.S20PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "s20-orch-t" "U-ultra-advisor" '[hierarchy-peer-brief reply-to="x" task="t"]')
OUT=$(echo "$S20_PAYLOAD" | HOME="$S20HOME" AGENT_HIERARCHY_DIR="$S20HD" "$NODE_BIN" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "20: an orchestrator whose session_id DOES resolve its own team still does NOT gate a sibling team's U-ultra-advisor (§7.10 preserved post-(ii))" '[ -z "$OUT" ]'
rm -rf "$S20"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
