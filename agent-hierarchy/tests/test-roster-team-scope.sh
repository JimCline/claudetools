#!/bin/bash
# agent-hierarchy — spec 0044 (roster/team scope split): the roster is a read-only
# TEMPLATE, every team gets its own file, and nothing new writes the shared
# `team.json`. Covers spec 0044 §4 items 1-5 (the mechanism half); the surface
# split's items 7-9 live in tests/test-roster-surface-split.sh.
#
# Reuses tests/test-roster-spawn-one.sh's PER-INVOCATION-APPEND fake herdr stub
# verbatim (spec 0005 §11.1's technique).
# Usage: bash tests/test-roster-team-scope.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-scope-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
HIER="$PROJ/.claude/hierarchy"
LEGACY_TEAM="$HIER/team.json"
SCOPED_TEAM="$HIER/teams/myrepo.json"
REPO_ROSTER="$PROJ/.claude/agent-hierarchy.json"
PEERS_FILE="$HIER/peers.jsonl"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

cat > "$SANDBOX/bin/herdr" <<EOF
#!$(command -v node)
$(cat <<'FAKEEOF'
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const dir = process.env.FAKE_STATE_DIR;
const callsDir = path.join(dir, "calls");
fs.mkdirSync(callsDir, { recursive: true });
function finish(exitCode) {
  const file = path.join(callsDir, `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify({ argv: args, exit: exitCode, pid: process.pid, bin: "herdr" }));
  process.exit(exitCode);
}
if (args[0] === "pane" && args[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(path.join(dir, "geometry.json"), "utf8"));
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  console.log(JSON.stringify({ result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } }));
  finish(0);
}
if (args[0] === "pane" && args[1] === "split") {
  const geomFile = path.join(dir, "geometry.json");
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const target = args[args.indexOf("--pane") + 1];
  const direction = args[args.indexOf("--direction") + 1];
  const rect = s.panes[target];
  const newId = `p${s.nextId++}`;
  if (direction === "right") {
    const w1 = Math.floor(rect.width / 2), w2 = rect.width - w1;
    s.panes[target] = { ...rect, width: w1 };
    s.panes[newId] = { ...rect, width: w2, x: rect.x + w1 };
  } else {
    const h1 = Math.floor(rect.height / 2), h2 = rect.height - h1;
    s.panes[target] = { ...rect, height: h1 };
    s.panes[newId] = { ...rect, height: h2, y: rect.y + h1 };
  }
  fs.writeFileSync(geomFile, JSON.stringify(s));
  console.log(JSON.stringify({ result: { pane: { pane_id: newId } } }));
  finish(0);
}
if (args[0] === "agent" && args[1] === "get") {
  // Nothing this stub started stays registered, so every liveness question answers the one
  // DEFINITE not-live signal herdr has (spec 0043 §1.6) rather than an indeterminate one.
  console.log(JSON.stringify({ error: { code: "agent_not_found" } }));
  finish(1);
}
if (args[0] === "agent" && args[1] === "start") {
  console.log(JSON.stringify({ result: { pane: { pane_id: "target" }, agent: { name: args[2], ready: true } } }));
  finish(0);
}
process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

FAKE_STATE_DIR="$SANDBOX/state"
reset_state() { rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"; }
init_geometry() {
  cat > "$FAKE_STATE_DIR/geometry.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}
EOF
}
clear_all() { rm -rf "$HIER" "$REPO_ROSTER" "$FAKEHOME/.claude/agent-hierarchy.json"; }

r() { # <extra_env> <args...> — roster.mjs with the fake herdr on PATH
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV -u CLAUDE_PID HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" $* --cwd \"$PROJ\" 2>&1"); RC=$?
}
setup_roster() { # <roles...> — repo-level peer roster, one member each
  r "" init --level repo --route peer >/dev/null
  local role
  for role in "$@"; do r "" add --level repo --role "$role" --model opus >/dev/null; done
}
jq_node() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(eval(process.argv[1]))})' "$1"; }
call_count() { ls "$FAKE_STATE_DIR/calls" 2>/dev/null | wc -l | tr -d ' '; }
# A live pid the team files can be owned by: this shell. Distinct from any real orchestrator.
LIVE_PID=$$

# ================================================================= 1 — §4 item 4 + §1.1
# Bare spawn-one on a fresh repo writes teams/<prefix>.json, never team.json, and the
# derived member name is byte-identical to what the pre-0044 shared default produced.
reset_state; clear_all; init_geometry; setup_roster architect
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect
check "1a: spawn-one exits 0 and reports spawned" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'
check "1b: §1.1 — the team file is teams/myrepo.json" '[ -f "$SCOPED_TEAM" ]'
check "1c: §1.1 invariant — team.json was never created" '[ ! -f "$LEGACY_TEAM" ]'
check "1d: §4 item 4 — derived name is byte-identical to the pre-change default (myrepo-architect)" \
  '[ "$(cat "$SCOPED_TEAM" | jq_node "j.members[0].name")" = "myrepo-architect" ]'

# ================================================================= 2 — §4 item 1
# THE ANTI-REQUIREMENT, DIRECTLY. An ad hoc member diverging on every field at once —
# different kind, different route, native args, and a role the roster does not define —
# must leave every roster level file byte-identical. This is the test the user's
# amendment exists to demand; it must fail if a divergence-driven roster write returns.
reset_state; clear_all; init_geometry; setup_roster architect
ROSTER_BEFORE="$(cat "$REPO_ROSTER")"
GLOBAL_BEFORE_EXISTS="$([ -f "$FAKEHOME/.claude/agent-hierarchy.json" ] && echo yes || echo no)"
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-ad-hoc reviewer --kind codex --route pane --args "'[\"--profile\",\"fast\"]'"
check "2a: spawn-ad-hoc exits 0 and spawned the divergent member" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'
check "2b: §4.1 — every roster level file is byte-identical after the divergent spawn" \
  '[ "$(cat "$REPO_ROSTER")" = "$ROSTER_BEFORE" ] && [ "$([ -f "$FAKEHOME/.claude/agent-hierarchy.json" ] && echo yes || echo no)" = "$GLOBAL_BEFORE_EXISTS" ]'
check "2c: the roster still defines exactly one member (the architect) — no reviewer row" \
  '[ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members.length")" = "1" ]'
check "2d: the divergence landed in the TEAM file, kind and args intact" \
  '[ "$(cat "$SCOPED_TEAM" | jq_node "j.members.filter(m=>m.role===\"reviewer\")[0].kind")" = "codex" ] && [ "$(cat "$SCOPED_TEAM" | jq_node "j.members.filter(m=>m.role===\"reviewer\")[0].args.join(\",\")")" = "--profile,fast" ]'
check "2e: §1.4 point 2 — a role absent from the roster is not an error" 'echo "$OUT" | grep -q "myrepo-reviewer"'

# ---- 2f: the same, for a member the roster DOES define but with divergent parameters —
#      alongside the roster-conforming one, so point 5's ordinal has something to avoid.
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect >/dev/null
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-ad-hoc architect --model sonnet
check "2f: divergent parameters for a roster-defined role still write no roster file" \
  '[ "$RC" -eq 0 ] && [ "$(cat "$REPO_ROSTER")" = "$ROSTER_BEFORE" ]'
check "2g: §1.4 point 5 — the second architect got the next ordinal, not the first name again" \
  '[ "$(cat "$SCOPED_TEAM" | jq_node "j.members.filter(m=>m.role===\"architect\").map(m=>m.name).join(\",\")")" = "myrepo-architect,myrepo-architect-2" ]'

# ---- 2h: §1.4 point 5 — a derived name that IS taken refuses rather than overwriting.
#      Two same-role members exist, so a third derives -3; force the collision by asking
#      for a role whose sole derived name is already present.
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-ad-hoc reviewer --kind codex --route pane
check "2h: a second reviewer derives -2 rather than colliding with the first" \
  '[ "$RC" -eq 0 ] && [ "$(cat "$SCOPED_TEAM" | jq_node "j.members.filter(m=>m.role===\"reviewer\").length")" = "2" ]'

# ================================================================= 3 — §4 item 3 (§1.3)
# A roster-mutating command invoked by the session that OWNS a live team refuses, exits
# non-zero, writes nothing, and names §1.4's command — before, not after, the override.
reset_state; clear_all; init_geometry; setup_roster architect
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect >/dev/null
ROSTER_BEFORE="$(cat "$REPO_ROSTER")"
r "CLAUDE_PID=$LIVE_PID" add --level repo --role reviewer --model opus
check "3a: §1.3 — add refuses while this session owns a live team" '[ "$RC" -ne 0 ]'
check "3b: §1.3 — the roster file is untouched by the refusal" '[ "$(cat "$REPO_ROSTER")" = "$ROSTER_BEFORE" ]'
check "3c: §1.3 — the message NAMES spawn-ad-hoc as the remedy" 'echo "$OUT" | grep -q "spawn-ad-hoc"'
check "3d: §1.3 — spawn-ad-hoc leads, the override is mentioned second" \
  '[ "$(echo "$OUT" | grep -bo "spawn-ad-hoc" | head -1 | cut -d: -f1)" -lt "$(echo "$OUT" | grep -bo -- "--allow-roster-edit" | head -1 | cut -d: -f1)" ]'
r "CLAUDE_PID=$LIVE_PID" edit --level repo --member myrepo-architect --model haiku
check "3e: §1.3 — edit is refused by the same uniform rule" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "spawn-ad-hoc"'
r "CLAUDE_PID=$LIVE_PID" layout --level repo --layout grid
check "3f: §1.3 — layout (a roster writer by §1.5) is refused too" '[ "$RC" -ne 0 ]'
r "CLAUDE_PID=$LIVE_PID" show --level repo
check "3g: §1.3 — a read-only command is NOT refused" '[ "$RC" -eq 0 ]'
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-ad-hoc reviewer --model opus
check "3h: §1.3 — the remedy it names actually works while the team is live" '[ "$RC" -eq 0 ]'
r "CLAUDE_PID=$LIVE_PID" add --level repo --role reviewer --model opus --allow-roster-edit
check "3i: §1.3 — the user's explicit override lets the edit through" \
  '[ "$RC" -eq 0 ] && [ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members.length")" = "2" ]'
# A pid that is alive but owns nothing — NOT an absent CLAUDE_PID, which makes the gate
# early-return on "no identity" and would pass this check without ever comparing ownership.
r "CLAUDE_PID=$PPID" add --level repo --role implementor --model opus
check "3j: §1.3 — a live session that owns no live team is unaffected" '[ "$RC" -eq 0 ]'
# r3 [9.2]: ownership is session-wide, not scope-local. `--team other` selects a different roster
# CONTAINER, but the roster is off limits for the duration of ownership — the earlier wording let
# an owner edit the template just by naming a scope it does not own.
r "CLAUDE_PID=$LIVE_PID" init --level repo --route peer --team other
check "3k: §1.3/[9.2] — owning a live team refuses init for another scope too" '[ "$RC" -ne 0 ]'
r "CLAUDE_PID=$LIVE_PID" add --level repo --role reviewer --model opus --team other
check "3k2: ...and add for that other scope" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "spawn-ad-hoc"'

# ================================================================= 3a — §4 item 3a (§1.10)
# `add` spawns NOTHING, in the case 0039's auto-spawn used to fire (route peer, a
# peer-eligible role, no live team). Surgical: the config row still lands exactly as before.
reset_state; clear_all; init_geometry
r "" init --level repo --route peer >/dev/null
r "HERDR_ENV=1" add --level repo --role architect --model opus
check "3a1: §1.10 — add exits 0" '[ "$RC" -eq 0 ]'
check "3a2: §1.10 — nothing was launched (no herdr invocation at all)" '[ "$(call_count)" = "0" ]'
check "3a3: §1.10 — no team file was written, at either location" '[ ! -f "$LEGACY_TEAM" ] && [ ! -f "$SCOPED_TEAM" ]'
check "3a4: §1.10 — the output carries no spawn field" '! echo "$OUT" | grep -q "\"spawn\":"'
check "3a5: §1.10 — the output names the spawn step instead of leaving it to be discovered" \
  'echo "$OUT" | grep -q "spawn-one architect"'
check "3a6: §1.10 — the removal is surgical: exactly the expected roster row landed" \
  '[ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members.length")" = "1" ] && [ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members[0].role")" = "architect" ] && [ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members[0].model")" = "opus" ]'

# ================================================================= 3c — §4 item 3c (R1)
# `--no-spawn` is still ACCEPTED and is now a no-op: identical to the flagless form.
FLAGLESS_ROSTER="$(cat "$REPO_ROSTER")"
clear_all; reset_state; init_geometry
r "" init --level repo --route peer >/dev/null
r "HERDR_ENV=1" add --no-spawn --level repo --role architect --model opus
check "3c1: R1 — --no-spawn exits 0" '[ "$RC" -eq 0 ]'
check "3c2: R1 — --no-spawn produces the byte-identical roster the flagless form did" \
  '[ "$(cat "$REPO_ROSTER")" = "$FLAGLESS_ROSTER" ]'
check "3c3: R1 — --no-spawn is not reported as a reason for anything (it is silent)" \
  '! echo "$OUT" | grep -q -- "--no-spawn"'

# ================================================================= 3b — §4 item 3b (§1.1 F3)
# A bare `create` whose derived name is held by a LIVE team refuses, writes no team file,
# and SUGGESTS a free candidate without applying it.
reset_state; clear_all; init_geometry; setup_roster architect
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect >/dev/null
r "" create --plan
check "3b1: §1.1 — bare create refuses when the derived name is held by a live team" '[ "$RC" -ne 0 ]'
check "3b2: §1.1 — it suggests the free candidate myrepo-2" 'echo "$OUT" | grep -q -- "--team myrepo-2"'
check "3b3: §1.1 F3 — the candidate is NOT applied: no teams/myrepo-2.json exists" '[ ! -f "$HIER/teams/myrepo-2.json" ]'
check "3b4: §1.1 — the live team's own file is untouched by the refusal" '[ -f "$SCOPED_TEAM" ]'

# ================================================================= 2 — §4 item 2
# Two concurrent orchestrators in one repo. Two distinct teams/*.json, no team.json,
# non-colliding member names, and each peer's peers.jsonl row carries its OWN team.
reset_state; clear_all; init_geometry; setup_roster architect
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect --team alpha >/dev/null
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect --team beta >/dev/null
check "4a: §4.2 — two distinct named team files exist" '[ -f "$HIER/teams/alpha.json" ] && [ -f "$HIER/teams/beta.json" ]'
check "4b: §4.2 — neither wrote team.json" '[ ! -f "$LEGACY_TEAM" ]'
check "4c: §4.2 — member names do not collide across the two teams" \
  '[ "$(cat "$HIER/teams/alpha.json" | jq_node "j.members[0].name")" = "alpha-architect" ] && [ "$(cat "$HIER/teams/beta.json" | jq_node "j.members[0].name")" = "beta-architect" ]'
# §1.6: each peer self-attributes from the pane id its orchestrator recorded, NOT from role —
# role alone matches both teams here, which is exactly the case that resolves to nothing.
ALPHA_PANE="$(cat "$HIER/teams/alpha.json" | jq_node 'j.members[0].transport_id')"
BETA_PANE="$(cat "$HIER/teams/beta.json" | jq_node 'j.members[0].transport_id')"
session_start() { # <pane_id> <session_id>
  printf '{"session_id":"%s","cwd":"%s","agent_type":"ah:architect","source":"startup"}' "$2" "$PROJ" |
    env HOME="$FAKEHOME" HERDR_PANE_ID="$1" CLAUDE_PID=$LIVE_PID node "$H/sessionstart.mjs" >/dev/null 2>&1
}
# §1.6 chose channel (b), attribute at READ time, and the ORDERING is the whole reason: a peer's
# SessionStart fires while the orchestrator is still launching, before its writeTeam lands. So the
# team files are held aside across the two SessionStart calls, reproducing that ordering exactly —
# invoking sessionstart.mjs after the write (as this block first did) masks the bug entirely.
mv "$HIER/teams" "$HIER/teams.hold"
rm -f "$PEERS_FILE"
session_start "$ALPHA_PANE" sess-alpha
session_start "$BETA_PANE" sess-beta
mv "$HIER/teams.hold" "$HIER/teams"
check "4d: §1.6 — a peer registering before its team file exists records NO team of its own" \
  '! grep -q "\"team\"" "$PEERS_FILE"'
# ...and the readers, which run after the write, attribute it anyway — by pane, to the exact
# member name, with role alone matching BOTH teams. Under registration-time attribution both rows
# stay unattributed forever and this is empty.
for t in alpha beta; do
  node -e '
    const fs=require("fs");const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));j.expected_root=process.argv[2];
    fs.writeFileSync(p,JSON.stringify(j));
  ' "$HIER/teams/$t.json" "$SANDBOX/elsewhere"
done
r "" teams
ATTRIB="$(echo "$OUT" | jq_node 'j.teams.map(t=>t.name+"="+t.misplaced_members.map(m=>m.name).join("|")).sort().join(",")')"
check "4d2: §1.6(b) — read-time attribution pins each peer to its own team and member" \
  '[ "$ATTRIB" = "alpha=alpha-architect,beta=beta-architect" ]'
check "4d3: ...and nothing was left unattributed, so it was not merely under-reporting" \
  '[ "$(echo "$OUT" | jq_node "j.teams.reduce((a,t)=>a+t.misplaced_unattributed,0)")" = "0" ]'
# The falsifiable half: with no pane to match on, neither the role scan at registration nor the
# read-time match can resolve, and both must refuse rather than guess (§1.6's safe-refuse).
rm -f "$PEERS_FILE"
printf '{"session_id":"sess-none","cwd":"%s","agent_type":"ah:architect","source":"startup"}' "$PROJ" |
  env HOME="$FAKEHOME" -u HERDR_PANE_ID -u TMUX_PANE CLAUDE_PID=$LIVE_PID node "$H/sessionstart.mjs" >/dev/null 2>&1
check "4e: §1.6/§3 — an unresolvable attribution records no team, never a guess" \
  '! grep -q "\"team\"" "$PEERS_FILE"'
r "" teams
check "4e2: §1.6/§3 — and the reader does not guess one for it either" \
  '[ "$(echo "$OUT" | jq_node "j.teams.reduce((a,t)=>a+t.misplaced_members.length,0)")" = "0" ]'

# ================================================================= 5 — §4 item 5 (§1.7)
# A repo holding a pre-existing LIVE legacy team.json upgrades: still readable,
# disbandable and resyncable in place, never migrated — and a second orchestrator
# arriving gets a non-colliding name.
reset_state; clear_all; init_geometry; setup_roster architect
mkdir -p "$HIER"
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"legacy-1","created":"$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/')","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$LIVE_PID},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
LEGACY_BEFORE="$(cat "$LEGACY_TEAM")"
r "" disband --plan
check "5a: §1.7 — a legacy team.json is still readable by disband" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "myrepo-architect" && echo "$OUT" | grep -q "p9"'
check "5b: §1.7 — reading it did not move, rewrite or migrate it" \
  '[ -f "$LEGACY_TEAM" ] && [ "$(cat "$LEGACY_TEAM")" = "$LEGACY_BEFORE" ] && [ ! -f "$SCOPED_TEAM" ]'
r "" dismiss myrepo-architect --plan
check "5c: §1.7 — dismiss resolves against the legacy file" '[ "$RC" -eq 0 ]'
r "" create --plan
check "5d: §1.7 — a second orchestrator arriving is refused and offered a non-colliding name" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "--team myrepo-2"'
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect --team myrepo-2 >/dev/null
check "5e: §1.7 — the second orchestrator's team lands beside the legacy one, not over it" \
  '[ -f "$HIER/teams/myrepo-2.json" ] && [ "$(cat "$LEGACY_TEAM")" = "$LEGACY_BEFORE" ]'
r "" disband --commit
check "5f: §1.7 — the legacy file ages out when its own team disbands" '[ "$RC" -eq 0 ] && [ ! -f "$LEGACY_TEAM" ]'
r "" create --plan
check "5g: §1.7 — with the legacy file gone, the bare scope resolves to the named path" \
  '[ "$RC" -eq 0 ]'

# ---- 5h-5k (B1): a stale legacy team.json still RESOLVES (§1.7), but nothing new is written into
# it. Without the retarget it would be cleared by the create/spawn path and a brand-new team put
# straight back into the shared default — breaking §1.1 and self-perpetuating in exactly the
# pre-0044 repos §1.7 exists for. The stale file is left for `reap`, never reused, never deleted
# by scope resolution.
reset_state; clear_all; init_geometry; setup_roster architect
( : ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
mkdir -p "$HIER"
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"stale-1","created":"2020-01-01T00:00:00+00:00","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$DEAD_PID},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
STALE_BEFORE="$(cat "$LEGACY_TEAM")"
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect
check "5h: §1.1/B1 — a stale legacy team.json is not reused as the scope" \
  '[ "$RC" -eq 0 ] && [ -f "$SCOPED_TEAM" ]'
check "5i: §1.1/B1 — and the new team did NOT land back in team.json" \
  '[ "$(cat "$SCOPED_TEAM" | jq_node "j.team_id")" != "stale-1" ] && [ "$(cat "$LEGACY_TEAM")" = "$STALE_BEFORE" ]'
r "" reap
check "5j: §1.7/B1 — the stale file is left intact for reap, which sees it" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "stale-1"'
r "" reap --commit
check "5k: §1.7/B1 — reap is what removes it, not the scope resolution" \
  '[ "$RC" -eq 0 ] && [ ! -f "$LEGACY_TEAM" ]'

# ---- 5l-5n (R1): the SAME property on `create --commit`, which writes a new team without ever
# going through refuseOrClearExistingTeam. It is worse than the spawn path if unguarded — it
# OVERWRITES the stale record instead of clearing it, so the file reap needs is destroyed.
reset_state; clear_all; init_geometry; setup_roster architect
mkdir -p "$HIER"
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"stale-2","created":"2020-01-01T00:00:00+00:00","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$DEAD_PID},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
STALE2_BEFORE="$(cat "$LEGACY_TEAM")"
r "CLAUDE_PID=$LIVE_PID" create --commit --transport terminal --roster-level repo --verified "'[\"myrepo-architect\"]'" --orchestrator-pid "$LIVE_PID"
check "5l: R1 — create --commit lands at the scoped path, not the stale default" \
  '[ "$RC" -eq 0 ] && [ -f "$SCOPED_TEAM" ] && [ "$(cat "$SCOPED_TEAM" | jq_node "j.team_id")" != "stale-2" ]'
check "5m: R1 — and it did not overwrite the stale record reap still needs" \
  '[ "$(cat "$LEGACY_TEAM")" = "$STALE2_BEFORE" ]'
r "" reap
check "5n: R1 — reap still sees the stale team afterwards" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "stale-2"'

# ---- 5o (R3): JOINING a legacy team that is past the staleness window but whose orchestrator is
# still running must not move the new member to a second file. `teamIsOrphaned` (dead owner) is
# the predicate; `!teamIsLive` would also catch this team and split it across two files.
reset_state; clear_all; init_geometry; setup_roster architect reviewer
mkdir -p "$HIER"
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"old-live-1","created":"2020-01-01T00:00:00+00:00","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$LIVE_PID},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one reviewer
check "5o: R3 — spawning into an old-but-owner-alive legacy team keeps it in one file" \
  '[ "$RC" -eq 0 ] && [ ! -f "$SCOPED_TEAM" ] && [ "$(cat "$LEGACY_TEAM" | jq_node "j.members.length")" = "2" ]'

# ---- 5p-5r: the LIVE half of the same rule. Declining to retarget a live legacy team (§1.7) is
# only half an answer — the create paths must then REFUSE, not fall through and overwrite the
# running team's members in place. --plan and --commit have to give the same answer.
reset_state; clear_all; init_geometry; setup_roster architect
mkdir -p "$HIER"
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"live-legacy-1","created":"$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/')","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$LIVE_PID},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
LIVE_LEGACY_BEFORE="$(cat "$LEGACY_TEAM")"
r "CLAUDE_PID=$LIVE_PID" create --plan
check "5p: --plan refuses against a live legacy team" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "live-legacy-1"'
# The committing session must be a DIFFERENT one: §1.11 allows an orchestrator to re-commit its
# OWN live legacy team (block 8e), so reusing $LIVE_PID here would assert the case that ruling
# deliberately reverses rather than the overwrite this case is about.
( sleep 60 ) & FOREIGN_PID=$!
r "CLAUDE_PID=$FOREIGN_PID" create --commit --transport terminal --roster-level repo --verified "'[\"myrepo-architect\"]'" --orchestrator-pid "$FOREIGN_PID"
check "5q: --commit gives the SAME answer, and does not overwrite the running team" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$LEGACY_TEAM")" = "$LIVE_LEGACY_BEFORE" ]'
check "5q2: ...and did not create a second file behind the refusal either" '[ ! -f "$SCOPED_TEAM" ]'
kill "$FOREIGN_PID" 2>/dev/null; wait "$FOREIGN_PID" 2>/dev/null


# ================================================================= 6 — r3 [9.1]: an unnamable prefix
# A repo whose basename cannot clear validateTeamAlias must NOT fall back to creating the shared
# team.json — that reinstates §1.1's ownership problem across a whole class of repos, silently.
# It refuses with a name the user can paste. The refusal is at the CREATE site, not at scope
# resolution, so `alias --set` (the remedy the message names) still runs in such a repo.
BADPROJ="$SANDBOX/_badrepo"
BADHIER="$BADPROJ/.claude/hierarchy"
BADROSTER="$BADPROJ/.claude/agent-hierarchy.json"
mkdir -p "$BADPROJ/.claude"
(cd "$BADPROJ" && git init -q)
rb() { # same as r(), against the unnamable repo
  local extra_env=$1; shift
  OUT=$(eval "env -u HERDR_ENV -u CLAUDE_PID HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" $extra_env node \"$H/roster.mjs\" $* --cwd \"$BADPROJ\" 2>&1"); RC=$?
}
bad_reset() { rm -rf "$BADHIER" "$BADROSTER"; rb "" init --level repo --route peer >/dev/null; rb "" add --level repo --role architect --model opus >/dev/null; }

reset_state; init_geometry; bad_reset
check "6a0: [9.1] — the roster commands themselves still work in such a repo" '[ "$RC" -eq 0 ]'
r_before_count=$(ls -A "$BADHIER" 2>/dev/null | wc -l | tr -d ' ')
rb "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect
check "6a: [9.1] — a bare launch refuses rather than creating the shared team.json" '[ "$RC" -ne 0 ]'
rb "CLAUDE_PID=$LIVE_PID" create --plan
check "6a1: [9.1] — bare create refuses on the same rule" '[ "$RC" -ne 0 ]'
# R1: --commit is the mode that actually WRITES, so it is the one that must not be the mode that
# skips the refusal. Same command, two modes, one answer.
rb "CLAUDE_PID=$LIVE_PID" create --commit --transport terminal --roster-level repo --verified "'[\"_badrepo-architect\"]'" --orchestrator-pid "$LIVE_PID"
check "6a1b: [9.1]/R1 — create --commit refuses identically, and writes no team.json" \
  '[ "$RC" -ne 0 ] && [ ! -f "$BADHIER/team.json" ]'
check "6a2: [9.1] — and wrote nothing under the hierarchy dir" \
  '[ ! -f "$BADHIER/team.json" ] && [ "$(ls -A "$BADHIER" 2>/dev/null | wc -l | tr -d " ")" = "$r_before_count" ]'
check "6a3: [9.1] — the message names a VALID suggested name" \
  'echo "$OUT" | grep -q "badrepo" && [ "$RC" -ne 0 ]'
check "6a4: [9.1] — and names alias --set as the remedy, not just the rejection" \
  'echo "$OUT" | grep -q -- "alias --level repo --set"'

# ---- 6b: the suggested remedy is real, not advice — setting the alias makes bare create work.
rb "" alias --level repo --set badrepo
check "6b: [9.1] — alias --set is reachable in the very repo the refusal fires in" '[ "$RC" -eq 0 ]'
rb "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect
check "6b2: [9.1] — with the alias set, the bare create path succeeds" '[ "$RC" -eq 0 ]'
check "6b3: [9.1] — and it landed at teams/<alias>.json, never team.json" \
  '[ -f "$BADHIER/teams/badrepo.json" ] && [ ! -f "$BADHIER/team.json" ]'

# ---- 6c: the same repo with a pre-existing legacy team.json behaves exactly as §1.7 promises —
# proving the refusal did not catch defaultTeamScope's legacy-file branch.
reset_state; init_geometry; bad_reset
mkdir -p "$BADHIER"
cat > "$BADHIER/team.json" <<EOF
{"version":1,"team_id":"legacy-bad","created":"$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/')","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$LIVE_PID},"members":[{"role":"architect","name":"legacy-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$BADPROJ"}
EOF
BAD_LEGACY_BEFORE="$(cat "$BADHIER/team.json")"
rb "" disband --plan
check "6c: §1.7 — an existing legacy team.json still resolves in an unnamable repo" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "legacy-architect"'
check "6c2: §1.7 — reading it neither refused nor rewrote it" \
  '[ "$(cat "$BADHIER/team.json")" = "$BAD_LEGACY_BEFORE" ]'

# ---- 6d (R2): a legacy file must not MASK the unnamable check. Once that team is orphaned there
# is no name left to fall back to, so the create paths refuse rather than deriving one from a
# prefix validateTeamAlias rejects.
cat > "$BADHIER/team.json" <<EOF
{"version":1,"team_id":"legacy-bad-dead","created":"2020-01-01T00:00:00+00:00","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$DEAD_PID},"members":[{"role":"architect","name":"legacy-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$BADPROJ"}
EOF
rb "CLAUDE_PID=$LIVE_PID" create --plan
check "6d: R2 — a legacy team.json does not mask the unnamable prefix" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "alias --level repo --set"'
rb "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-ad-hoc architect --model opus
check "6d2: R2 — and spawn-ad-hoc does not derive a member name from the rejected prefix" \
  '[ "$RC" -ne 0 ] && ! echo "$OUT" | grep -q "_badrepo-architect"'
BAD_DEAD_BEFORE="$(cat "$BADHIER/team.json")"
rb "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect
check "6d3: R2 — spawn-one is guarded on the same shape, and leaves the orphan for reap" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$BADHIER/team.json")" = "$BAD_DEAD_BEFORE" ]'

# ---- 6e: unnamable repo + a LIVE legacy team. The candidate-deriving path cannot produce a name
# here (every `<prefix>-N` fails the same validator), so it must report the thing the user can act
# on rather than an exhausted search.
cat > "$BADHIER/team.json" <<EOF
{"version":1,"team_id":"legacy-bad-live","created":"$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/')","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$LIVE_PID},"members":[{"role":"architect","name":"legacy-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$BADPROJ"}
EOF
rb "CLAUDE_PID=$LIVE_PID" create --plan
check "6e: an unnamable prefix reports [9.1], not an exhausted candidate search" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "alias --level repo --set" && ! echo "$OUT" | grep -q "1000 attempts"'

# ================================================================= 7 — r3 [9.2]: ownership is session-wide
# A session owning teams/foo.json running a roster-mutating command with NO --team is refused: the
# roster is off limits for the duration of ownership, not merely for one argument spelling. This
# is the S3 regression and it fails against r2's "team file at the resolving scope" wording.
reset_state; clear_all; init_geometry; setup_roster architect
r "HERDR_ENV=1 CLAUDE_PID=$LIVE_PID" spawn-one architect --team foo >/dev/null
ROSTER_BEFORE="$(cat "$REPO_ROSTER")"
r "CLAUDE_PID=$LIVE_PID" add --level repo --role reviewer --model opus
check "7a: [9.2] — owning teams/foo.json refuses a roster edit made with no --team" '[ "$RC" -ne 0 ]'
check "7a2: [9.2] — it names the owned team, and the roster is untouched" \
  'echo "$OUT" | grep -q "\"foo\"" && [ "$(cat "$REPO_ROSTER")" = "$ROSTER_BEFORE" ]'
# The deliberate hole: no resolvable pid means ownership cannot be established, and §1.3 says the
# write must then be ALLOWED — that case is the plain user shell §1.2 preserves.
r "" add --level repo --role reviewer --model opus
check "7b: [9.2]/§1.3 — with no resolvable pid the same command is allowed, not refused" \
  '[ "$RC" -eq 0 ] && [ "$(cat "$REPO_ROSTER" | jq_node "j.roster.members.length")" = "2" ]'

# ================================================================= 8 — §1.11: ownership-gating on the commit path
# A live team is never overwritten by ANOTHER session, but the session that owns it may re-commit
# (0015's supported commit-twice). Ownership, not liveness, is the line between those two.
CARGS='--commit --transport terminal --roster-level repo'
V_MYREPO="'[\"myrepo-architect\"]'"

reset_state; clear_all; init_geometry; setup_roster architect
( sleep 60 ) & OWNER_A=$!
r "CLAUDE_PID=$OWNER_A" create $CARGS --verified "$V_MYREPO"
check "8a: first commit into a clean repo succeeds" '[ "$RC" -eq 0 ] && [ -f "$SCOPED_TEAM" ]'
TEAM_ID_1="$(cat "$SCOPED_TEAM" | jq_node "j.team_id")"
r "CLAUDE_PID=$OWNER_A" create $CARGS --verified "$V_MYREPO"
check "8a2: the SAME session re-committing its own live team is allowed (0015 commit-twice)" '[ "$RC" -eq 0 ]'
check "8a3: ...and still mints a fresh team_id — 0015 §12 needs the superseded entry to read inactive" \
  '[ "$(cat "$SCOPED_TEAM" | jq_node "j.team_id")" != "$TEAM_ID_1" ]'

# Case L: the same second commit from a different live session.
TEAM_BEFORE="$(cat "$SCOPED_TEAM")"
( sleep 60 ) & OWNER_B=$!
r "CLAUDE_PID=$OWNER_B" create $CARGS --verified "$V_MYREPO"
check "8b: a DIFFERENT live session is refused (case L)" '[ "$RC" -ne 0 ]'
check "8b2: ...and the team file is byte-unchanged" '[ "$(cat "$SCOPED_TEAM")" = "$TEAM_BEFORE" ]'
check "8b3: ...and the refusal offers no --team candidate (constraint 2: --verified names are already derived)" \
  '! echo "$OUT" | grep -q "Re-run with --team"'

# Liveness AND ownership: once the owner is gone the same foreign commit goes through.
kill "$OWNER_A" 2>/dev/null; wait "$OWNER_A" 2>/dev/null
r "CLAUDE_PID=$OWNER_B" create $CARGS --verified "$V_MYREPO"
check "8c: once the owner's pid is dead the same foreign commit is allowed" \
  '[ "$RC" -eq 0 ] && [ "$(cat "$SCOPED_TEAM")" != "$TEAM_BEFORE" ]'
kill "$OWNER_B" 2>/dev/null; wait "$OWNER_B" 2>/dev/null

# The gate keys on the RESOLVED scope, so an explicit --team is covered too.
reset_state; clear_all; init_geometry; setup_roster architect
( sleep 60 ) & OWNER_C=$!
r "CLAUDE_PID=$OWNER_C" create $CARGS --team foo --verified "'[\"foo-architect\"]'"
check "8d: explicit --team first commit succeeds" '[ "$RC" -eq 0 ] && [ -f "$HIER/teams/foo.json" ]'
FOO_BEFORE="$(cat "$HIER/teams/foo.json")"
( sleep 60 ) & OWNER_D=$!
r "CLAUDE_PID=$OWNER_D" create $CARGS --team foo --verified "'[\"foo-architect\"]'"
check "8d2: the gate covers an EXPLICIT --team scope, not only the derived one" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$HIER/teams/foo.json")" = "$FOO_BEFORE" ]'
kill "$OWNER_C" "$OWNER_D" 2>/dev/null; wait "$OWNER_C" "$OWNER_D" 2>/dev/null

# §1.11 constraint 1 — the trap. `resolveWritableTeamScope` refuses a live legacy default before
# the ownership gate can run, so leaving that refusal unconditional makes the whole rule
# unreachable for pre-0044 repos. This case fails against shipped code in the OPPOSITE direction
# from 8b: not "overwrote a team it should not have", but "refused a commit it should allow".
reset_state; clear_all; init_geometry; setup_roster architect
mkdir -p "$HIER"
( sleep 60 ) & OWNER_E=$!
cat > "$LEGACY_TEAM" <<EOF
{"version":1,"team_id":"legacy-owned-1","created":"$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/')","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":$OWNER_E},"members":[{"role":"architect","name":"myrepo-architect","route":"peer","transport_id":"p9"}],"partial":false,"expected_root":"$PROJ"}
EOF
r "CLAUDE_PID=$OWNER_E" create $CARGS --verified "$V_MYREPO"
check "8e: constraint 1 — re-committing your OWN live legacy team.json is allowed" '[ "$RC" -eq 0 ]'
check "8e2: ...in place, without leaving a second scoped file behind" '[ ! -f "$SCOPED_TEAM" ]'

LEGACY_BEFORE="$(cat "$LEGACY_TEAM")"
( sleep 60 ) & OWNER_F=$!
r "CLAUDE_PID=$OWNER_F" create $CARGS --verified "$V_MYREPO"
check "8f: a foreign session still cannot take over a live legacy team" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$LEGACY_TEAM")" = "$LEGACY_BEFORE" ]'
check "8f2: ...and that refusal offers no --team candidate either" '! echo "$OUT" | grep -q "Re-run with --team"'
kill "$OWNER_E" "$OWNER_F" 2>/dev/null; wait "$OWNER_E" "$OWNER_F" 2>/dev/null

# A session with no pid of its own cannot prove ownership either way, so it is refused like a
# foreign one — but the team may well be its own, and a refusal that ASSERTS otherwise sends the
# user to disband a team nobody else holds. The remedy is supplying the identity, not destroying.
reset_state; clear_all; init_geometry; setup_roster architect
( sleep 60 ) & OWNER_G=$!
r "CLAUDE_PID=$OWNER_G" create $CARGS --verified "$V_MYREPO"
G_BEFORE="$(cat "$SCOPED_TEAM")"
r "" create $CARGS --verified "$V_MYREPO"
check "8g: an unresolvable own pid is refused against a live team" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$SCOPED_TEAM")" = "$G_BEFORE" ]'
check "8g2: ...without claiming the team belongs to another orchestrator" \
  '! echo "$OUT" | grep -q "owned by another live orchestrator"'
check "8g3: ...and it names supplying the pid as the remedy, not only disband" \
  'echo "$OUT" | grep -q -- "--orchestrator-pid"'
kill "$OWNER_G" 2>/dev/null; wait "$OWNER_G" 2>/dev/null

# §1.11 rows 4/5 delegate --plan and --spawn to refuseOrClearExistingTeam's own live-team refusal.
# On an EXPLICIT --team that refusal is the plain "disband it first" branch — the one §1.1 fork F3
# deliberately keeps candidate-free — and nothing else in the tree exercises it directly.
reset_state; clear_all; init_geometry; setup_roster architect
( sleep 60 ) & OWNER_H=$!
r "CLAUDE_PID=$OWNER_H" create $CARGS --team foo --verified "'[\"foo-architect\"]'"
FOO_H_BEFORE="$(cat "$HIER/teams/foo.json")"
r "CLAUDE_PID=$OWNER_H" create --plan --team foo
check "8h: --plan refuses a live team at an explicit --team scope, even to its own owner" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "disband it first"'
check "8h2: ...leaving that team file byte-unchanged" '[ "$(cat "$HIER/teams/foo.json")" = "$FOO_H_BEFORE" ]'
check "8h3: ...and offering no auto-derived candidate, since the user named this scope" \
  '! echo "$OUT" | grep -q "Re-run with --team"'
kill "$OWNER_H" 2>/dev/null; wait "$OWNER_H" 2>/dev/null

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
