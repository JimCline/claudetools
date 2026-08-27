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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
