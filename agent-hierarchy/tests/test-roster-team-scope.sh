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
r "" add --level repo --role implementor --model opus
check "3j: §1.3 — a session that owns no live team is unaffected" '[ "$RC" -eq 0 ]'
# §1.3 says "the team file at the RESOLVING SCOPE" — owning a live team at one scope must not
# refuse roster work aimed at another. Scanning every team file instead would make standing up a
# second, named team impossible for as long as the first one runs.
r "CLAUDE_PID=$LIVE_PID" init --level repo --route peer --team other
check "3k: §1.3 — a live team at the default scope does not refuse init for --team other" '[ "$RC" -eq 0 ]'
r "CLAUDE_PID=$LIVE_PID" add --level repo --role reviewer --model opus --team other
check "3k2: ...nor add for that other scope" '[ "$RC" -eq 0 ]'

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
session_start "$ALPHA_PANE" sess-alpha
session_start "$BETA_PANE" sess-beta
TEAMS_SEEN="$(node -e '
  const fs=require("fs");
  const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(l=>JSON.parse(l)).filter(r=>r.status==="up"&&r.role==="architect");
  console.log(rows.map(r=>String(r.team)).join(","));
' "$PEERS_FILE" 2>/dev/null)"
check "4d: §1.6 — each peer recorded its OWN team, resolved from its pane not its role" \
  '[ "$TEAMS_SEEN" = "alpha,beta" ]'
# The falsifiable half: with no pane to match on, the role scan is ambiguous across the two
# teams and must record NO team rather than guess one (§1.6's safe-refuse property).
rm -f "$PEERS_FILE"
printf '{"session_id":"sess-none","cwd":"%s","agent_type":"ah:architect","source":"startup"}' "$PROJ" |
  env HOME="$FAKEHOME" -u HERDR_PANE_ID -u TMUX_PANE CLAUDE_PID=$LIVE_PID node "$H/sessionstart.mjs" >/dev/null 2>&1
check "4e: §1.6/§3 — an unresolvable attribution records no team, never a guess" \
  '! grep -q "\"team\"" "$PEERS_FILE"'

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

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
