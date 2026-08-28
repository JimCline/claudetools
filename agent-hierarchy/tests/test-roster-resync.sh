#!/bin/bash
# agent-hierarchy — roster.mjs `resync`/`move` (spec 0008): resync re-derives every peer
# member's herdr location from live topology and rewrites team.json; move executes a
# `herdr pane move` then resyncs that one member. Uses a stateful fake `herdr` on PATH
# (same technique as test-roster-layout-splits.sh) so no real herdr call ever happens.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-resync.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-resync-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- fake herdr: `agent list` reads its response from $FAKE_HERDR_STATE (a JSON `agents` array);
# FAKE_HERDR_FAIL=1 makes every call exit 1 loudly; FAKE_HERDR_LIST_FAIL=1 fails only `agent list`
# (so a preceding `pane move` still succeeds — the move-then-query-fails case needs exactly that).
# `pane move` always succeeds (unless FAKE_HERDR_FAIL=1) — its response body is ignored by roster.mjs.
cat > "$SANDBOX/bin/herdr" <<EOF
#!/usr/bin/env node
$(cat <<'FAKEEOF'
const fs = require("fs");
const args = process.argv.slice(2);
if (process.env.FAKE_HERDR_FAIL === "1") {
  process.stderr.write("fake herdr: forced failure\n");
  process.exit(1);
}
if (args[0] === "agent" && args[1] === "list") {
  if (process.env.FAKE_HERDR_LIST_FAIL === "1") {
    process.stderr.write("fake herdr: forced agent-list failure\n");
    process.exit(1);
  }
  const agents = JSON.parse(fs.readFileSync(process.env.FAKE_HERDR_STATE, "utf8"));
  console.log(JSON.stringify({ id: "cli:agent:list", result: { agents, type: "agent_list" } }));
  process.exit(0);
}
if (args[0] === "pane" && args[1] === "move") {
  console.log(JSON.stringify({ id: "cli:pane:move", result: { pane: { pane_id: args[2] } } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(args) + "\n");
process.exit(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

run() { OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FAKE_HERDR_LIST_FAIL="${FAKE_HERDR_LIST_FAIL:-0}" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

write_team() {
  local transport=$1
  mkdir -p "$(dirname "$TEAM_FILE")"
  cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "$transport",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "w2:pD", "tab_id": "w2:t1", "workspace_id": "w2", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "reviewer", "name": null, "ref": "r3", "route": "subagent", "model": "opus", "transport_id": null, "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
}

write_agents() { echo "$1" > "$SANDBOX/agents.json"; }

# ---- no active team
rm -f "$TEAM_FILE"
run resync
check "resync: no active team -> resynced false, reason given, exit 0" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"resynced\": false" && echo "$OUT" | grep -q "\"reason\": \"no active team\""'

# ---- tmux transport: the §4 no-op, file unchanged
write_team tmux
BEFORE=$(cat "$TEAM_FILE")
run resync
check "resync: tmux transport -> no-op, exit 0" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"resynced\": false" && echo "$OUT" | grep -q "transport tmux not supported"'
check "resync: tmux transport -> team.json unchanged" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'

# ---- the core case: tab_id heals w2:t1 -> w2:t3, transport_id unchanged, status updated
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t3","workspace_id":"w2"}]'
run resync
check "resync (core): exit 0" '[ "$RC" -eq 0 ]'
check "resync (core): architect status updated, tab_id healed w2:t1 -> w2:t3, pane_id unchanged" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));const m=t.members.find(x=>x.name===\"myrepo-architect\");process.exit(m.tab_id===\"w2:t3\"&&m.transport_id===\"w2:pD\"&&m.workspace_id===\"w2\"?0:1)"'
check "resync (core): emitted plan reports status updated with from/to" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-architect\");process.exit(m&&m.status===\"updated\"&&m.from.tab_id===\"w2:t1\"&&m.to.tab_id===\"w2:t3\"?0:1)})"'
check "resync (core): counts.updated is 1" \
  'echo "$OUT" | grep -q "\"updated\": 1"'

# ---- member absent from topology: not_found, transport_stale true, ids byte-identical
write_team herdr
export BEFORE_MEMBER=$(node -e "const t=JSON.parse(require('fs').readFileSync('$TEAM_FILE','utf8'));console.log(JSON.stringify(t.members.find(m=>m.name==='myrepo-architect')))")
write_agents '[]'
run resync
check "resync (not_found): exit 0, status not_found" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-architect\");process.exit(m&&m.status===\"not_found\"?0:1)})"'
check "resync (not_found): transport_stale true, transport_id/tab_id/workspace_id byte-identical to before" \
  'node -e "const t=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\"));const m=t.members.find(x=>x.name===\"myrepo-architect\");const b=JSON.parse(process.env.BEFORE_MEMBER);process.exit(m.transport_stale===true&&m.transport_id===b.transport_id&&m.tab_id===b.tab_id&&m.workspace_id===b.workspace_id?0:1)"'
unset BEFORE_MEMBER

# ---- --dry-run: same emitted plan, team.json mtime and contents unchanged
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t3","workspace_id":"w2"}]'
BEFORE=$(cat "$TEAM_FILE")
BEFORE_MTIME=$(node -e "console.log(require('fs').statSync('$TEAM_FILE').mtimeMs)")
sleep 1
run resync --dry-run
AFTER_MTIME=$(node -e "console.log(require('fs').statSync('$TEAM_FILE').mtimeMs)")
check "resync --dry-run: reports dry_run true, status updated" \
  'echo "$OUT" | grep -q "\"dry_run\": true" && echo "$OUT" | grep -q "\"status\": \"updated\""'
check "resync --dry-run: team.json contents and mtime unchanged" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ] && [ "$AFTER_MTIME" = "$BEFORE_MTIME" ]'

# ---- topology query fails: exit non-zero, team.json unchanged, no member marked not_found
write_team herdr
BEFORE=$(cat "$TEAM_FILE")
FAKE_HERDR_FAIL=1 run resync
check "resync: topology query fails -> exit non-zero" '[ "$RC" -ne 0 ]'
check "resync: topology query fails -> team.json unchanged" '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'
check "resync: topology query fails -> no member marked not_found (no JSON plan emitted)" \
  '! echo "$OUT" | grep -q "not_found"'

# ---- move: two of --tab/--new-tab/--new-workspace given -> non-zero exit, usage message
write_team herdr
run move myrepo-architect --new-tab --new-workspace
check "move: two placement flags -> exit non-zero, usage message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "exactly one of"'

# ---- move: --tab without --split -> non-zero exit, message names --split, herdr never invoked.
# FAKE_HERDR_FAIL=1 makes any herdr call exit 1 with "fake herdr: forced failure" — its absence
# from $OUT proves the guard fired before herdrCall() was ever reached.
write_team herdr
FAKE_HERDR_FAIL=1 run move myrepo-architect --tab w2:t9
check "move: --tab without --split -> exit non-zero, message names --split" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "--split"'
check "move: --tab without --split -> herdr never invoked" \
  '! echo "$OUT" | grep -q "fake herdr: forced failure"'
check "move: --tab without --split -> team.json architect tab_id unchanged" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-architect\");process.exit(m.tab_id===\"w2:t1\"?0:1)"'

# ---- move --dry-run: emits the herdr pane move ... string, executes nothing
write_team herdr
run move myrepo-architect --new-tab --dry-run
check "move --dry-run: exit 0, emits command string, does not execute" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"command\": \"herdr pane move w2:pD --new-tab\"" && echo "$OUT" | grep -q "\"dry_run\": true"'
check "move --dry-run: team.json unchanged" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-architect\");process.exit(m.tab_id===\"w2:t1\"?0:1)"'

# ---- spec 0008 §7.6: two members both resolving to the same live pane -> first updated, second
# not_found + transport_stale, top-level warning.
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "w2:pD", "tab_id": "w2:t1", "workspace_id": "w2", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": "w2:pD", "tab_id": "w2:t1", "workspace_id": "w2", "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
write_agents '[{"pane_id":"w2:pD","tab_id":"w2:t3","workspace_id":"w2"}]'
run resync
check "resync (§7.6 dup): exit 0" '[ "$RC" -eq 0 ]'
check "resync (§7.6 dup): first claimant (architect) updated" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-architect\");process.exit(m&&m.status===\"updated\"?0:1)})"'
check "resync (§7.6 dup): second claimant (implementor) not_found" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-implementor\");process.exit(m&&m.status===\"not_found\"?0:1)})"'
check "resync (§7.6 dup): implementor persisted with transport_stale true" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-implementor\");process.exit(m.transport_stale===true?0:1)"'
check "resync (§7.6 dup): output carries warning duplicate pane match" \
  'echo "$OUT" | grep -q "\"warning\": \"duplicate pane match\""'

# ---- move happy-path: fake herdr accepts `pane move`, topology query reports the new location,
# team.json persists the healed member.
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t9","workspace_id":"w2"}]'
run move myrepo-architect --new-tab
check "move (happy path): exit 0, moved true, resync.ok true" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"moved\": true" && echo "$OUT" | grep -q "\"ok\": true"'
check "move (happy path): team.json persists the healed tab_id" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-architect\");process.exit(m.tab_id===\"w2:t9\"?0:1)"'

# ---- (amendment b) --level on resync and move -> non-zero exit, unknown-flag message; locks in
# spec 0008 §8.1 item B so it cannot silently regress back to accepted-but-ignored.
write_team herdr
run resync --level repo
check "resync --level: rejected, non-zero exit, unrecognized-flag message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "unrecognized flag --level"'
run move myrepo-architect --new-tab --level repo
check "move --level: rejected, non-zero exit, unrecognized-flag message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "unrecognized flag --level"'

# ---- (amendment b) whole-team heal: move on member X also persists a healed record for an
# unrelated member Y in the same pass (spec 0008 §5.4 step 7 — ratified, not scoped to one member).
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "ref": "r1", "route": "peer", "model": "opus", "transport_id": "w2:pD", "tab_id": "w2:t1", "workspace_id": "w2", "checked_in": "2026-01-01T00:00:00Z"},
    {"role": "implementor", "name": "myrepo-implementor", "ref": "r2", "route": "peer", "model": "sonnet", "transport_id": "w2:pE", "tab_id": "w2:t2", "workspace_id": "w2", "checked_in": "2026-01-01T00:00:00Z"}
  ],
  "partial": false
}
EOF
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t9","workspace_id":"w2"},{"name":"myrepo-implementor","pane_id":"w2:pE","tab_id":"w2:t8","workspace_id":"w2"}]'
run move myrepo-architect --new-tab
check "move (whole-team heal): exit 0" '[ "$RC" -eq 0 ]'
check "move (whole-team heal): moved member (architect) healed to w2:t9" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-architect\");process.exit(m.tab_id===\"w2:t9\"?0:1)"'
check "move (whole-team heal): unrelated member (implementor) also healed to w2:t8 by the same pass" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-implementor\");process.exit(m.tab_id===\"w2:t8\"?0:1)"'

# ---- (amendment b, §8.1 item A, HARD CONSTRAINT) move succeeds, then the topology query fails ->
# exit 0, "moved": true, "resync": {"ok": false, ...}; team.json left unhealed (never fail()s once
# the pane has actually moved — spec 0008 §7.5's irreversibility rule).
write_team herdr
BEFORE=$(cat "$TEAM_FILE")
FAKE_HERDR_LIST_FAIL=1 run move myrepo-architect --new-tab
check "move: post-move query failure -> exit 0" '[ "$RC" -eq 0 ]'
check "move: post-move query failure -> moved true, resync.ok false" \
  'echo "$OUT" | grep -q "\"moved\": true" && echo "$OUT" | grep -q "\"ok\": false"'
check "move: post-move query failure -> team.json left unhealed (unwritten)" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'

# ---- move (spec 0023 §8.2 B1): same-tab no-op — resync reports status "unchanged" -> moved false,
# a reason key naming the no-op, exit 0. Must be shown to fail against pre-bug-B-fix code, which
# reported moved:true unconditionally regardless of resync.status (verified by hand, scratch copy).
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"}]'
run move myrepo-architect --tab w2:t1 --split down
check "move (B1): same-tab no-op -> moved false, exit 0" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"moved\": false"'
check "move (B1): resync.status is unchanged" \
  'echo "$OUT" | grep -q "\"status\": \"unchanged\""'
check "move (B1): a reason key is present naming the no-op" \
  'echo "$OUT" | grep -q "\"reason\":" && echo "$OUT" | grep -qi "no-op"'

# ---- move (spec 0023 §8.2 B3): post-move resync reports not_found -> moved stays true, UNREGRESSED
# by bug B's fix. Guards against an over-reaching fix that flips every non-"updated" status to false.
write_team herdr
write_agents '[]'
run move myrepo-architect --new-tab
check "move (B3): not_found after move -> moved true (unregressed), exit 0" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"moved\": true"'
check "move (B3): resync.status is not_found" \
  'echo "$OUT" | grep -q "\"status\": \"not_found\""'

# ---- (spec 0025 §6) regression: a malformed (string) member must round-trip byte-identical,
# never spread into char-indexed garbage; resync still exits 0 and reports counts.malformed.
# Written via JSON.stringify(data, null, 2) — the exact serialization writeTeam uses — so a
# correct (non-corrupting) resync leaves the file genuinely byte-identical, not merely reformatted.
mkdir -p "$(dirname "$TEAM_FILE")"
node -e '
const fs = require("fs");
const team = {
  version: 1, team_id: "t1", created: "2026-01-01T00:00:00Z",
  roster_level: "repo", transport: "herdr",
  orchestrator: { session_id: null, pid: null },
  members: ["waves-architect"],
  partial: false,
};
fs.writeFileSync(process.argv[1], JSON.stringify(team, null, 2) + "\n", "utf8");
' "$TEAM_FILE"
BEFORE=$(cat "$TEAM_FILE")
write_agents '[]'
run resync
check "resync (§6 malformed regression): exit 0" '[ "$RC" -eq 0 ]'
check "resync (§6 malformed regression): team.json left byte-identical (raw text, not parsed)" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'
check "resync (§6 malformed regression): counts.malformed is 1" \
  'echo "$OUT" | grep -q "\"malformed\": 1"'
check "resync (§6 malformed regression): recovery warning emitted" \
  'echo "$OUT" | grep -qi "create --commit"'

# ---- (spec 0025 §5) a peer member with transport_id: null whose name matches a live pane is
# healed by resync — the guard that used to skip null-transport_id members is gone.
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"}]'
run resync
check "resync (§5 repair): exit 0" '[ "$RC" -eq 0 ]'
check "resync (§5 repair): healed to status updated with from.transport_id null" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-architect\");process.exit(m&&m.status===\"updated\"&&m.from.transport_id===null?0:1)})"'
check "resync (§5 repair): team.json persists the discovered transport_id" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(\"$TEAM_FILE\",\"utf8\")).members.find(x=>x.name===\"myrepo-architect\");process.exit(m.transport_id===\"w2:pD\"?0:1)"'

# ===========================================================================
# Spec 0025 §12/§14 — multi-pass matching (peers.jsonl exact tier, cwd
# narrowing tier, self-pane exclusion, --bind). Verification items 7-18.
# ===========================================================================

PEERS_FILE="$PROJ/.claude/hierarchy/peers.jsonl"
reset_peers() { rm -f "$PEERS_FILE"; }
seed_peer() { # <session_id> <role> <status> <pid> <pane_id|null> <cwd|null>
  mkdir -p "$(dirname "$PEERS_FILE")"
  node -e "
    const fs = require('fs');
    const [f, sid, role, status, pid, pane, cwd] = process.argv.slice(1);
    fs.appendFileSync(f, JSON.stringify({
      type: 'peer', status, role, session_id: sid,
      pid: pid === 'null' ? null : Number(pid),
      ppid: pid === 'null' ? null : Number(pid),
      cwd: cwd === 'null' ? null : cwd,
      pane_id: pane === 'null' ? null : pane,
      tab_id: pane === 'null' ? null : pane + ':tab',
      workspace_id: pane === 'null' ? null : 'wS',
      ts: new Date().toISOString(),
    }) + '\n');
  " "$PEERS_FILE" "$1" "$2" "$3" "$4" "$5" "$6"
}

run_self() { # <self-pane-id|UNSET> <resync-args...>
  local self=$1; shift
  if [ "$self" = "UNSET" ]; then
    OUT=$(env -u HERDR_PANE_ID HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FAKE_HERDR_LIST_FAIL="${FAKE_HERDR_LIST_FAIL:-0}" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
  else
    OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FAKE_HERDR_LIST_FAIL="${FAKE_HERDR_LIST_FAIL:-0}" HERDR_PANE_ID="$self" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?
  fi
}

member_status() { # <name> -> status field from $OUT's emitted plan
  echo "$OUT" | node -e "
    let s = '';
    process.stdin.on('data', d => s += d).on('end', () => {
      const o = JSON.parse(s);
      const m = (o.members || []).find(x => x.name === '$1');
      console.log(m ? m.status : 'MISSING');
    });
  "
}
member_field() { # <name> <field> -> that field's value from team.json on disk
  node -e "
    const m = JSON.parse(require('fs').readFileSync('$TEAM_FILE', 'utf8')).members.find(x => x.name === '$1');
    console.log(m ? String(m['$2']) : 'MISSING');
  "
}
member_has_field() { # <name> <field> -> "true"/"false" whether $OUT's member owns that key
  echo "$OUT" | node -e "
    let s = '';
    process.stdin.on('data', d => s += d).on('end', () => {
      const o = JSON.parse(s);
      const m = (o.members || []).find(x => x.name === '$1');
      console.log(m ? Object.prototype.hasOwnProperty.call(m, '$2') : 'MISSING');
    });
  "
}

# ---- (spec 0025 §14 item 7) pass ordering: identity always wins over a weaker tier
# regardless of member order. B (transport_id null, unmatchable by name) listed BEFORE
# A (name-matchable) must not steal A's only pane.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "reviewer", "name": "myrepo-b", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null},
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": "OLD:pX", "tab_id": "OLD:t1", "workspace_id": "OLD"}
  ],
  "partial": false
}
EOF
write_agents "[{\"name\":\"myrepo-architect\",\"pane_id\":\"wT:pA\",\"tab_id\":\"wT:t1\",\"workspace_id\":\"wT\",\"cwd\":\"$PROJ\"}]"
run_self UNSET resync
check "7: pass ordering - exit 0" '[ "$RC" -eq 0 ]'
check "7: pass ordering - A (name match) healed to its own pane" \
  '[ "$(member_status myrepo-architect)" = "updated" ] && [ "$(member_field myrepo-architect transport_id)" = "wT:pA" ]'
check "7: pass ordering - B never claims A's pane" \
  '[ "$(member_field myrepo-b transport_id)" != "wT:pA" ] && [ "$(member_status myrepo-b)" != "updated" ]'

# ---- (spec 0025 §14 item 8) pass 2 exact bind: a peers.jsonl up record with a live pid,
# matching role and cwd, and a pane_id present in topology -> status updated, match_by
# peers_jsonl, from.transport_id null.
reset_peers
write_team herdr
seed_peer "sess-impl-8" "implementor" "up" "$$" "wP:p9" "$PROJ"
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"},{"pane_id":"wP:p9","tab_id":"wP:t1","workspace_id":"wP"}]'
run_self "wSELF:pOrch" resync
check "8: pass 2 exact bind - exit 0" '[ "$RC" -eq 0 ]'
check "8: pass 2 exact bind - implementor healed via peers.jsonl" \
  '[ "$(member_status myrepo-implementor)" = "updated" ] && [ "$(member_field myrepo-implementor transport_id)" = "wP:p9" ]'
check "8: pass 2 exact bind - match_by peers_jsonl, from.transport_id null in the emitted plan" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-implementor\");process.exit(m&&m.match_by===\"peers_jsonl\"&&m.from.transport_id===null?0:1)})"'

# ---- (spec 0025 §14 item 9) anti-zip regression: two members awaiting repair, two candidate
# panes, no usable peers.jsonl records -> both ambiguous, both transport_id still null on
# disk, exit 0. Self pane is set but excluded from neither candidate, so the failure is the
# 2-members-vs-1-slot gate, not the self-pane gate.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null},
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
write_agents "[{\"pane_id\":\"wZ:p1\",\"tab_id\":\"wZ:t1\",\"workspace_id\":\"wZ\",\"cwd\":\"$PROJ\"},{\"pane_id\":\"wZ:p2\",\"tab_id\":\"wZ:t2\",\"workspace_id\":\"wZ\",\"cwd\":\"$PROJ\"}]"
run_self "wSELF:pOrch" resync
check "9: anti-zip - exit 0" '[ "$RC" -eq 0 ]'
check "9: anti-zip - both members ambiguous, never zipped by order" \
  '[ "$(member_status myrepo-architect)" = "ambiguous" ] && [ "$(member_status myrepo-implementor)" = "ambiguous" ]'
check "9: anti-zip - both transport_id still null on disk" \
  '[ "$(member_field myrepo-architect transport_id)" = "null" ] && [ "$(member_field myrepo-implementor transport_id)" = "null" ]'
check "9: anti-zip - counts.ambiguous is 2, not counted as not_found (Reviewer finding 2)" \
  'echo "$OUT" | grep -q "\"ambiguous\": 2" && ! echo "$OUT" | grep -q "\"not_found\": 2"'

# ---- (spec 0025 §14 item 10, tightened per item 20) pass 2 rejects a stale record: up record
# whose pid is dead -> not used, even though role and cwd match. Topology panes are explicitly
# NOT at the team cwd, so the candidate count is zero, deliberately (not incidental) -> exact
# status not_found.
reset_peers
write_team herdr
seed_peer "sess-impl-10" "implementor" "up" "99999999" "wP:p9" "$PROJ"
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2","cwd":"/nonmatching"},{"pane_id":"wP:p9","tab_id":"wP:t1","workspace_id":"wP","cwd":"/nonmatching"}]'
run_self "wSELF:pOrch" resync
check "10: pass 2 rejects stale (dead pid) record - exit 0" '[ "$RC" -eq 0 ]'
check "10: pass 2 rejects stale record - implementor falls through to zero-candidate not_found" \
  '[ "$(member_status myrepo-implementor)" = "not_found" ]'

# ---- (spec 0025 §14 item 11, tightened per item 20) pass 2 rejects a recycled pane: up record
# whose pane_id is absent from live topology -> not used; member falls through to pass 3. The
# one live pane is explicitly NOT at the team cwd -> exact status not_found.
reset_peers
write_team herdr
seed_peer "sess-impl-11" "implementor" "up" "$$" "wP:pGHOST" "$PROJ"
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2","cwd":"/nonmatching"}]'
run_self "wSELF:pOrch" resync
check "11: pass 2 rejects recycled pane - exit 0" '[ "$RC" -eq 0 ]'
check "11: pass 2 rejects recycled pane - implementor falls through to zero-candidate not_found" \
  '[ "$(member_status myrepo-implementor)" = "not_found" ]'

# ---- (spec 0025 §14 item 12, tightened per item 20) two members sharing one role, both
# awaiting repair, two up records -> NOT bound by pass 2 (the role key cannot separate them).
# Two panes are explicitly at the team cwd, so the candidate count is deliberately 2 -> exact
# status ambiguous, candidates.length === 2, for both.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet", "transport_id": null, "tab_id": null, "workspace_id": null},
    {"role": "implementor", "name": "myrepo-implementor-2", "route": "peer", "model": "sonnet", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
seed_peer "sess-impl-12a" "implementor" "up" "$$" "wQ:p1" "$PROJ"
seed_peer "sess-impl-12b" "implementor" "up" "$$" "wQ:p2" "$PROJ"
write_agents "[{\"pane_id\":\"wQ:p1\",\"tab_id\":\"wQ:t1\",\"workspace_id\":\"wQ\",\"cwd\":\"$PROJ\"},{\"pane_id\":\"wQ:p2\",\"tab_id\":\"wQ:t2\",\"workspace_id\":\"wQ\",\"cwd\":\"$PROJ\"}]"
run_self "wSELF:pOrch" resync
check "12: role collision - exit 0" '[ "$RC" -eq 0 ]'
check "12: role collision - neither implementor bound by pass 2, both ambiguous with 2 candidates" \
  '[ "$(member_status myrepo-implementor)" = "ambiguous" ] && [ "$(member_status myrepo-implementor-2)" = "ambiguous" ]'

# ---- (spec 0025 §14 item 20 — Architect ruling) status classification, zero vs many: a
# repair-case member with NO candidate pane -> exact status not_found, no candidates key, no
# transport_stale. A repair-case member with TWO candidate panes -> exact status ambiguous,
# candidates.length === 2.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
write_agents '[{"pane_id":"wZ:p1","tab_id":"wZ:t1","workspace_id":"wZ","cwd":"/nonmatching"}]'
run_self "wSELF:pOrch" resync
check "20a: zero candidates - exact status not_found" '[ "$(member_status myrepo-architect)" = "not_found" ]'
check "20a: zero candidates - no candidates key" '[ "$(member_has_field myrepo-architect candidates)" = "false" ]'
check "20a: zero candidates - no transport_stale" '[ "$(member_has_field myrepo-architect transport_stale)" = "false" ]'

write_agents "[{\"pane_id\":\"wZ:p1\",\"tab_id\":\"wZ:t1\",\"workspace_id\":\"wZ\",\"cwd\":\"$PROJ\"},{\"pane_id\":\"wZ:p2\",\"tab_id\":\"wZ:t2\",\"workspace_id\":\"wZ\",\"cwd\":\"$PROJ\"}]"
run_self "wSELF:pOrch" resync
check "20b: two candidates - exact status ambiguous" '[ "$(member_status myrepo-architect)" = "ambiguous" ]'
check "20b: two candidates - candidates.length === 2" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-architect\");process.exit(m&&Array.isArray(m.candidates)&&m.candidates.length===2?0:1)})"'

# ---- (spec 0025 §14 item 13) --bind naming an unknown member -> non-zero exit listing
# known names.
reset_peers
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"}]'
run_self UNSET resync --bind '{"nonexistent-member":"w2:pD"}'
check "13: --bind unknown member - exit non-zero" '[ "$RC" -ne 0 ]'
check "13: --bind unknown member - lists known member names" 'echo "$OUT" | grep -q "myrepo-architect"'

# ---- (spec 0025 §14 item 14) --bind naming a pane already claimed by pass 1 -> non-zero
# exit, and team.json unchanged (no partial application).
reset_peers
write_team herdr
BEFORE=$(cat "$TEAM_FILE")
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"}]'
run_self UNSET resync --bind '{"myrepo-implementor":"w2:pD"}'
check "14: --bind pane already claimed by pass 1 - exit non-zero" '[ "$RC" -ne 0 ]'
check "14: --bind pane already claimed - team.json unchanged (no partial application)" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'

# ---- (spec 0025 §14 item 15) --bind where cwd does not match -> still binds. Explicit
# outranks heuristic.
reset_peers
write_team herdr
write_agents '[{"pane_id":"wR:p1","tab_id":"wR:t1","workspace_id":"wR","cwd":"/totally/different/path"}]'
run_self UNSET resync --bind '{"myrepo-implementor":"wR:p1"}'
check "15: --bind ignores cwd mismatch - exit 0" '[ "$RC" -eq 0 ]'
check "15: --bind ignores cwd mismatch - implementor bound to the named pane" \
  '[ "$(member_status myrepo-implementor)" = "updated" ] && [ "$(member_field myrepo-implementor transport_id)" = "wR:p1" ]'
check "15: --bind ignores cwd mismatch - match_by is bind" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const m=o.members.find(x=>x.name===\"myrepo-implementor\");process.exit(m&&m.match_by===\"bind\"?0:1)})"'

# ---- (spec 0025 §14 item 16) self-pane exclusion: the sole candidate pane IS
# HERDR_PANE_ID -> no auto-bind, status ambiguous.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
write_agents "[{\"pane_id\":\"wS:pSELF\",\"tab_id\":\"wS:t1\",\"workspace_id\":\"wS\",\"cwd\":\"$PROJ\"}]"
run_self "wS:pSELF" resync
check "16: self-pane exclusion - exit 0" '[ "$RC" -eq 0 ]'
check "16: self-pane exclusion - no auto-bind, status ambiguous" \
  '[ "$(member_status myrepo-architect)" = "ambiguous" ]'
check "16: self-pane exclusion - transport_id stays null" \
  '[ "$(member_field myrepo-architect transport_id)" = "null" ]'

# ---- (spec 0025 §14 item 17) HERDR_PANE_ID unset -> pass 3 auto-bind never fires (even
# with exactly one candidate and one member awaiting repair); pass 2 still binds.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "architect", "name": "myrepo-architect", "route": "peer", "model": "opus", "transport_id": null, "tab_id": null, "workspace_id": null}
  ],
  "partial": false
}
EOF
write_agents "[{\"pane_id\":\"wU:p1\",\"tab_id\":\"wU:t1\",\"workspace_id\":\"wU\",\"cwd\":\"$PROJ\"}]"
run_self UNSET resync
check "17a: HERDR_PANE_ID unset - pass 3 auto-bind never fires" \
  '[ "$(member_status myrepo-architect)" = "ambiguous" ]'

reset_peers
write_team herdr
seed_peer "sess-impl-17b" "implementor" "up" "$$" "wV:p1" "$PROJ"
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t1","workspace_id":"w2"},{"pane_id":"wV:p1","tab_id":"wV:t1","workspace_id":"wV"}]'
run_self UNSET resync
check "17b: HERDR_PANE_ID unset - pass 2 still binds via peers.jsonl" \
  '[ "$(member_status myrepo-implementor)" = "updated" ] && [ "$(member_field myrepo-implementor transport_id)" = "wV:p1" ]'

# ---- (spec 0025 §14 item 18) a member with a non-null transport_id that fails pass 1 stays
# not_found; no weaker tier re-homes it, even when a matching peers.jsonl record and a
# matching-cwd topology pane both exist.
reset_peers
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{
  "version": 1, "team_id": "t1", "created": "2026-01-01T00:00:00Z",
  "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet", "transport_id": "STALE:pX", "tab_id": "STALE:t1", "workspace_id": "STALE"}
  ],
  "partial": false
}
EOF
seed_peer "sess-impl-18" "implementor" "up" "$$" "w2:pE" "$PROJ"
write_agents "[{\"pane_id\":\"w2:pE\",\"tab_id\":\"w2:t1\",\"workspace_id\":\"w2\",\"cwd\":\"$PROJ\"}]"
run_self UNSET resync
check "18: non-null transport_id failing pass 1 - exit 0" '[ "$RC" -eq 0 ]'
check "18: non-null transport_id failing pass 1 - status stays not_found" \
  '[ "$(member_status myrepo-implementor)" = "not_found" ]'
check "18: non-null transport_id failing pass 1 - transport_id untouched on disk" \
  '[ "$(member_field myrepo-implementor transport_id)" = "STALE:pX" ]'

# ---- (Reviewer finding 1, sibling of §14 item 14): --bind naming the same pane for two
# different members -> non-zero exit, team.json unchanged (an intra-bind collision, not just
# a collision with pass 1's claims).
reset_peers
write_team herdr
BEFORE=$(cat "$TEAM_FILE")
write_agents '[{"pane_id":"wI:p1","tab_id":"wI:t1","workspace_id":"wI"}]'
run_self UNSET resync --bind '{"myrepo-implementor":"wI:p1","myrepo-architect":"wI:p1"}'
check "finding1: --bind intra-bind pane collision - exit non-zero" '[ "$RC" -ne 0 ]'
check "finding1: --bind intra-bind pane collision - team.json unchanged" \
  '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'

# ---- (Reviewer finding 3): teamCwd is git-root-anchored, not the raw --cwd. Running resync
# from a subdirectory of the repo must still resolve cwd comparisons against the git root.
reset_peers
write_team herdr
mkdir -p "$PROJ/sub"
write_agents "[{\"name\":\"myrepo-architect\",\"pane_id\":\"w2:pD\",\"tab_id\":\"w2:t1\",\"workspace_id\":\"w2\"},{\"pane_id\":\"wG:p1\",\"tab_id\":\"wG:t1\",\"workspace_id\":\"wG\"}]"
seed_peer "sess-impl-f3" "implementor" "up" "$$" "wG:p1" "$PROJ"
OUT=$(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_HERDR_STATE="$SANDBOX/agents.json" HERDR_PANE_ID="wSELF:pOrch" node "$H/roster.mjs" resync --cwd "$PROJ/sub" 2>&1); RC=$?
check "finding3: resync from a subdirectory - exit 0" '[ "$RC" -eq 0 ]'
check "finding3: resync from a subdirectory - pass 2 still matches via git-root-anchored teamCwd" \
  '[ "$(member_status myrepo-implementor)" = "updated" ] && [ "$(member_field myrepo-implementor transport_id)" = "wG:p1" ]'

# ---- (Reviewer finding 4): --bind on an already pass-1-matched member does not double-count.
reset_peers
write_team herdr
write_agents '[{"name":"myrepo-architect","pane_id":"w2:pD","tab_id":"w2:t3","workspace_id":"w2"},{"pane_id":"wJ:p1","tab_id":"wJ:t1","workspace_id":"wJ"}]'
run_self UNSET resync --bind '{"myrepo-architect":"wJ:p1"}'
check "finding4: --bind on an already-matched member - exit 0" '[ "$RC" -eq 0 ]'
check "finding4: --bind on an already-matched member - rebinds to the named pane" \
  '[ "$(member_status myrepo-architect)" = "updated" ] && [ "$(member_field myrepo-architect transport_id)" = "wJ:p1" ]'
check "finding4: --bind on an already-matched member - counts total does not exceed member count" \
  'echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);const total=Object.values(o.counts).reduce((a,b)=>a+b,0);process.exit(total===o.members.length?0:1)})"'

reset_peers

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
