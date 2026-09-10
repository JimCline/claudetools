#!/usr/bin/env bash
# agent-hierarchy — spec 0047 §7.2: the HTTP daemon transport.
#
# Every case fails on 0.71.0, where mcp/server.mjs has no --http, no /health and no
# --stop. HOME- and AGENT_HIERARCHY_DIR-redirected throughout; the installed daemon on
# the default port is never contacted (each case picks its own free port).
#
# Usage: bash tests/test-mcp-http.sh   (exits 0 iff all cases pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SERVER="$REPO_ROOT/mcp/server.mjs"
ENSURE_HOOK="$REPO_ROOT/hooks/sessionstart-mcp-ensure.mjs"

# pwd -P: server.mjs's isMain check compares import.meta.url (real path) against
# argv[1], and on macOS mktemp -d hands back a /var -> /private/var symlink. A server
# copy reached through the symlink would silently run nothing at all.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
export HOME="$TMP/home"
mkdir -p "$HOME"
REPO="$TMP/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q)

PASS=0
FAIL=0
DAEMON_PIDS=()
CLAIMED_PORTS=()

# Kill whatever is listening on a port this test claimed. Deliberately not a
# process-name sweep over every running --http server: such a pattern also matches the
# user's own installed daemon, so running this suite would take their live server down.
kill_port() {
  local pids
  pids="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null)"
  for p in $pids; do kill "$p" 2>/dev/null; done
}

cleanup() {
  for p in "${DAEMON_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  # A daemon that re-exec'd itself is not in DAEMON_PIDS; find it by its port.
  for port in "${CLAIMED_PORTS[@]:-}"; do kill_port "$port"; done
  rm -rf "$TMP"
}
trap cleanup EXIT

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1)); echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $desc"
  fi
}

# A port nothing is listening on. Bind 0, read what the kernel gave us, release it.
free_port() {
  local p
  p="$(node -e '
    const net = require("net");
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => console.log(p)); });
  ')"
  CLAIMED_PORTS+=("$p")
  echo "$p"
}

wait_health() {
  local port="$1" i=0
  while [ "$i" -lt 40 ]; do
    if curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_daemon() {
  local port="$1" hier="$2" srv="${3:-$SERVER}"
  mkdir -p "$hier"
  AH_MCP_PORT="$port" AGENT_HIERARCHY_DIR="$hier" node "$srv" --http >/dev/null 2>&1 &
  DAEMON_PIDS+=("$!")
  wait_health "$port"
}

health() { curl -fsS -m 2 "http://127.0.0.1:$1/health"; }
jfield() { node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s)[\"$1\"]))"; }

# ---------------------------------------------------------------------------
# §7.2.2 — transport contract.
# ---------------------------------------------------------------------------
PORT="$(free_port)"
HIER="$TMP/hier-contract"
start_daemon "$PORT" "$HIER"
check "daemon answers /health on its own port" 'health "$PORT" >/dev/null'
check "/health reports the checkout's version and transport http" \
  'health "$PORT" | node -e "
     let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{
       const h=JSON.parse(s);
       const v=JSON.parse(require(\"fs\").readFileSync(\"$REPO_ROOT/.claude-plugin/plugin.json\",\"utf8\")).version;
       process.exit(h.transport===\"http\" && h.version===v && Number.isInteger(h.pid) && h.root && h.node ? 0 : 1);
     });"'

cat > "$TMP/contract.mjs" <<'JSEOF'
const base = `http://127.0.0.1:${process.env.PORT}/`;
const post = async (body, sid) => {
  const res = await fetch(base, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(sid ? { "Mcp-Session-Id": sid } : {}) },
    body: JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch {}
  return { status: res.status, sid: res.headers.get("mcp-session-id"), json };
};
const out = {};
const init = await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
out.initStatus = init.status;
out.sidIssued = Boolean(init.sid);

const list = await post({ jsonrpc: "2.0", id: 2, method: "tools/list" }, init.sid);
out.toolsJson = JSON.stringify(list.json.result.tools);

const call = await post({ jsonrpc: "2.0", id: 3, method: "tools/call",
  params: { name: "msg_new", arguments: { cwd: process.env.REPO, to: "implementor", from: "orchestrator", slug: "http-transport-probe" } } }, init.sid);
out.callIsError = Boolean(call.json?.result?.isError);
out.callText = (call.json?.result?.content?.[0]?.text || "").slice(0, 300);

out.notificationStatus = (await post({ jsonrpc: "2.0", method: "notifications/initialized" }, init.sid)).status;
out.noSidStatus = (await post({ jsonrpc: "2.0", id: 4, method: "ping" })).status;
out.badSidStatus = (await post({ jsonrpc: "2.0", id: 5, method: "ping" }, "definitely-not-a-session")).status;
// F6: a batch is only as exempt as its least exempt member. The initialize would
// otherwise smuggle the tools/list past the session gate.
out.batchNoSidStatus = (await post([{ jsonrpc: "2.0", id: 7, method: "initialize", params: {} }, { jsonrpc: "2.0", id: 8, method: "tools/list" }])).status;
out.batchExemptStatus = (await post([{ jsonrpc: "2.0", id: 11, method: "server/discover" }, { jsonrpc: "2.0", id: 12, method: "initialize", params: {} }])).status;
out.getStatus = (await fetch(base, { method: "GET" })).status;
out.deleteStatus = (await fetch(base, { method: "DELETE", headers: { "Mcp-Session-Id": init.sid } })).status;
out.afterDeleteStatus = (await post({ jsonrpc: "2.0", id: 6, method: "ping" }, init.sid)).status;

const many = await Promise.all([0, 1, 2, 3, 4].map(() => post({ jsonrpc: "2.0", id: 9, method: "initialize", params: {} })));
out.distinctSids = new Set(many.map((m) => m.sid)).size;
const pinged = await Promise.all(many.map((m) => post({ jsonrpc: "2.0", id: 10, method: "ping" }, m.sid)));
out.allPinged = pinged.every((p) => p.status === 200 && p.json.result);
console.log(JSON.stringify(out));
JSEOF
C="$(PORT="$PORT" REPO="$REPO" node "$TMP/contract.mjs" 2>&1)"
field() { echo "$C" | jfield "$1"; }

check "initialize: 200 with a server-issued Mcp-Session-Id" \
  '[ "$(field initStatus)" = "200" ] && [ "$(field sidIssued)" = "true" ]'
check "notification (no id): 202" '[ "$(field notificationStatus)" = "202" ]'
check "request with no Mcp-Session-Id: 400" '[ "$(field noSidStatus)" = "400" ]'
check "request with an unknown Mcp-Session-Id: 404" '[ "$(field badSidStatus)" = "404" ]'
check "batch [initialize, tools/list] with no session id: whole request 400" \
  '[ "$(field batchNoSidStatus)" = "400" ]'
check "batch of only exempt methods with no session id: still 200" \
  '[ "$(field batchExemptStatus)" = "200" ]'
check "GET /: 405 (no server-initiated stream)" '[ "$(field getStatus)" = "405" ]'
check "DELETE drops the session: 200, then the id is 404" \
  '[ "$(field deleteStatus)" = "200" ] && [ "$(field afterDeleteStatus)" = "404" ]'
check "five concurrent sessions get five distinct ids and all succeed" \
  '[ "$(field distinctSids)" = "5" ] && [ "$(field allPinged)" = "true" ]'
# The file lands under AGENT_HIERARCHY_DIR, which the daemon inherits and which
# outranks the cwd's own .claude/hierarchy — that override is the test's isolation.
check "tools/call over HTTP really ran the CLI (msg_new wrote a file)" \
  '[ "$(field callIsError)" = "false" ] && ls "$HIER"/msgs/*http-transport-probe*request.md >/dev/null 2>&1'

cat > "$TMP/stdio-tools.mjs" <<'JSEOF'
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
const child = spawn(process.execPath, [process.env.SERVER_PATH], { stdio: ["pipe", "pipe", "ignore"] });
const rl = createInterface({ input: child.stdout });
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) + "\n");
for await (const line of rl) {
  const m = JSON.parse(line);
  if (m.id === 1) { console.log(JSON.stringify(m.result.tools)); break; }
}
child.kill();
JSEOF
STDIO_TOOLS="$(SERVER_PATH="$SERVER" AGENT_HIERARCHY_DIR="$TMP/hier-stdio" node "$TMP/stdio-tools.mjs" 2>/dev/null)"
HTTP_TOOLS="$(echo "$C" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.stdout.write(JSON.parse(s).toolsJson))")"
check "tools/list over HTTP is byte-identical to the stdio loop's" '[ -n "$STDIO_TOOLS" ] && [ "$STDIO_TOOLS" = "$HTTP_TOOLS" ]'
check "tools/list still serves the 0046 surface of 25 tools" \
  '[ "$(echo "$HTTP_TOOLS" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" = "25" ]'

check "lifecycle log: the http start line records the port, a null session_pid and the identity method" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$HIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     const s=l.find(e=>e.event===\"start\");
     process.exit(s && s.transport===\"http\" && s.port==='"$PORT"' && s.session_pid===null && s.identity===\"socket-peer\" ? 0 : 1);
   "'

# ---------------------------------------------------------------------------
# §7.2.3 — identity (§4.4). E1 selected method 2 (socket peer lookup): ${CLAUDE_PID}
# does NOT expand in a plugin manifest's headers, so the header variant was not built
# and is not asserted here. What must hold is that the pid the daemon attributes to a
# session is the pid of the process that opened the connection — asserted through
# team_adopt, which stamps exactly that pid into team.json.
# ---------------------------------------------------------------------------
IPORT="$(free_port)"
IHIER="$TMP/hier-identity"
mkdir -p "$IHIER"
node --input-type=module -e "
  const R = await import('$REPO_ROOT/hooks/lib-roster.mjs');
  R.writeTeam('$IHIER', { version: 1, team_id: 'orphan-http', created: new Date().toISOString(),
    roster_level: 'repo', transport: 'terminal', orchestrator: { session_id: null, pid: null },
    members: [{ role: 'architect', name: 'repo-architect' }], partial: false }, null);
"
start_daemon "$IPORT" "$IHIER"
cat > "$TMP/identity.mjs" <<'JSEOF'
const base = `http://127.0.0.1:${process.env.PORT}/`;
const post = async (body, sid) => {
  const res = await fetch(base, { method: "POST",
    headers: { "Content-Type": "application/json", ...(sid ? { "Mcp-Session-Id": sid } : {}) },
    body: JSON.stringify(body) });
  return { sid: res.headers.get("mcp-session-id"), json: await res.json() };
};
const init = await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
const call = await post({ jsonrpc: "2.0", id: 2, method: "tools/call",
  params: { name: "team_adopt", arguments: { cwd: process.env.REPO } } }, init.sid);
console.log(JSON.stringify({ pid: process.pid, isError: Boolean(call.json.result?.isError), text: (call.json.result?.content?.[0]?.text || "").slice(0, 200) }));
JSEOF
ID_OUT="$(PORT="$IPORT" REPO="$REPO" AGENT_HIERARCHY_DIR="$IHIER" node "$TMP/identity.mjs" 2>&1)"
ID_PID="$(echo "$ID_OUT" | jfield pid 2>/dev/null)"
DAEMON_PID="$(health "$IPORT" | jfield pid)"
check "identity: team_adopt over HTTP succeeded" '[ "$(echo "$ID_OUT" | jfield isError 2>/dev/null)" = "false" ]'
check "identity: the daemon resolved the CONNECTING process's pid" \
  '[ -n "$ID_PID" ] && grep -q "\"pid\": $ID_PID" "$IHIER/team.json"'
check "identity: that pid is not the daemon's own" '[ -n "$ID_PID" ] && [ "$ID_PID" != "$DAEMON_PID" ]'
check "/health names the identity method in force" 'health "$IPORT" | grep -q "\"identity\":\"socket-peer\""'

# F4 — two non-self candidates on the peer socket: log the ambiguity, take the
# smallest pid (the oldest process, i.e. the session rather than anything it spawned).
# Unit-shaped: the real lsof cannot be made to report two clients for one socket, so
# the resolver's input is stubbed on PATH.
APORT="$(free_port)"
AHIER="$TMP/hier-ambiguous"
mkdir -p "$AHIER" "$TMP/stub"
cat > "$TMP/stub/lsof" <<'SHEOF'
#!/bin/sh
# Highest pid first, so "chose the smallest" is distinguishable from "took the first".
echo p30002
echo p30001
SHEOF
chmod +x "$TMP/stub/lsof"
AH_MCP_PORT="$APORT" AGENT_HIERARCHY_DIR="$AHIER" PATH="$TMP/stub:$PATH" node "$SERVER" --http >/dev/null 2>&1 &
DAEMON_PIDS+=("$!")
wait_health "$APORT"
curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$APORT/" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
sleep 0.3
check "identity: two candidate pids are logged as ambiguous, smallest chosen" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$AHIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     const a=l.find(e=>e.event===\"identity-ambiguous\");
     process.exit(a && a.chosen===30001 && a.pids.join(\",\")===\"30001,30002\" ? 0 : 1);
   "'
kill_port "$APORT"; sleep 0.5

# ---------------------------------------------------------------------------
# §7.2.4 — self-replacement on update.
# ---------------------------------------------------------------------------
INST="$TMP/cache/ah"
mkdir -p "$INST"
for V in A B; do
  mkdir -p "$INST/$V/mcp" "$INST/$V/.claude-plugin" "$INST/$V/hooks"
  cp "$SERVER" "$INST/$V/mcp/server.mjs"
  cp -R "$REPO_ROOT/hooks/." "$INST/$V/hooks/"
done
node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  p.version = "9.9.1"; fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2));
  p.version = "9.9.2"; fs.writeFileSync(process.argv[3], JSON.stringify(p, null, 2));
' "$REPO_ROOT/.claude-plugin/plugin.json" "$INST/A/.claude-plugin/plugin.json" "$INST/B/.claude-plugin/plugin.json"

mkdir -p "$HOME/.claude/plugins"
write_installed() {
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ "ah@claudetools": [{ scope: "user", installPath: process.argv[2], version: process.argv[3] }] }, null, 2))' \
    "$HOME/.claude/plugins/installed_plugins.json" "$1" "$2"
}

RPORT="$(free_port)"
RHIER="$TMP/hier-replace"
write_installed "$INST/A" "9.9.1"
start_daemon "$RPORT" "$RHIER" "$INST/A/mcp/server.mjs"
OLD_PID="$(health "$RPORT" | jfield pid)"
check "self-replace: the daemon starts on A's version" 'health "$RPORT" | grep -q "9.9.1"'
write_installed "$INST/B" "9.9.2"
# One request is all it takes: the check is a stat per request.
curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$RPORT/" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
sleep 2
wait_health "$RPORT"
NEW_PID="$(health "$RPORT" | jfield pid 2>/dev/null)"
check "self-replace: the same port now serves B's version" 'health "$RPORT" | grep -q "9.9.2"'
check "self-replace: it is a new process" '[ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]'
check "self-replace: a replace event names from and to" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$RHIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     const r=l.find(e=>e.event===\"replace\");
     process.exit(r && /\/A$/.test(r.from) && /\/B$/.test(r.to) ? 0 : 1);
   "'
kill_port "$RPORT"; sleep 0.5

# A root outside the installed lineage (a --plugin-dir checkout) must never replace
# itself, however far the installed version has moved on.
DPORT="$(free_port)"
DHIER="$TMP/hier-devcheckout"
DEV="$TMP/elsewhere/checkout"
mkdir -p "$DEV/mcp" "$DEV/.claude-plugin" "$DEV/hooks"
cp "$SERVER" "$DEV/mcp/server.mjs"
cp -R "$REPO_ROOT/hooks/." "$DEV/hooks/"
node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  p.version = "0.0.1-dev"; fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2));
' "$REPO_ROOT/.claude-plugin/plugin.json" "$DEV/.claude-plugin/plugin.json"
write_installed "$INST/B" "9.9.2"
start_daemon "$DPORT" "$DHIER" "$DEV/mcp/server.mjs"
curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$DPORT/" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
sleep 1.5
check "self-replace: a dev checkout outside the install dir never replaces itself" \
  'health "$DPORT" | grep -q "0.0.1-dev"'
check "self-replace: and logs no replace event" \
  '! grep -q "\"event\":\"replace\"" "$DHIER/mcp-server.log"'

# F5′(b) — the replacement dies on startup. Closing the listener BEFORE spawning is
# what makes this survivable at all (the spec's original spawn-first order hands the
# child an EADDRINUSE from its own parent); the old daemon must re-listen and keep
# serving rather than leave a dead port.
mkdir -p "$INST/C/mcp" "$INST/C/.claude-plugin"
SPAWN_LOG="$TMP/c-spawn-count"
# The broken replacement records that it ran, then dies — that is how the test counts
# spawn ATTEMPTS rather than inferring them from the parent's log.
cat > "$INST/C/mcp/server.mjs" <<SHEOF
import { appendFileSync } from "node:fs";
appendFileSync("$SPAWN_LOG", "spawned\n");
process.exit(0);
SHEOF
node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  p.version = "9.9.3"; fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2));
' "$REPO_ROOT/.claude-plugin/plugin.json" "$INST/C/.claude-plugin/plugin.json"

FPORT="$(free_port)"
FHIER="$TMP/hier-replace-failed"
write_installed "$INST/A" "9.9.1"
start_daemon "$FPORT" "$FHIER" "$INST/A/mcp/server.mjs"
FAIL_OLD_PID="$(health "$FPORT" | jfield pid)"
write_installed "$INST/C" "9.9.3"
curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$FPORT/" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
sleep 4
check "replace-failed: the old daemon still answers /health, same pid and version" \
  'H="$(health "$FPORT" 2>/dev/null)" && echo "$H" | grep -q "9.9.1" && [ "$(echo "$H" | jfield pid)" = "$FAIL_OLD_PID" ]'
check "replace-failed: the replacement really was spawned once" \
  '[ "$(wc -l < "$SPAWN_LOG" | tr -d " ")" = "1" ]'
# F5′ backoff (r2.1): a permanently broken next root must not cost one doomed child per
# request. Four more requests inside REPLACE_RETRY_MS must add no spawn and no log line.
for i in 1 2 3 4; do
  curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$FPORT/" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' 2>/dev/null
done
sleep 1
check "replace-failed: no further spawn attempt inside the 5-minute backoff" \
  '[ "$(wc -l < "$SPAWN_LOG" | tr -d " ")" = "1" ]'
check "replace-failed: and exactly one replace-failed line for all five requests" \
  '[ "$(grep -c "\"event\":\"replace-failed\"" "$FHIER/mcp-server.log")" = "1" ]'
check "replace-failed: and logged why, with no replace event" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$FHIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     const f=l.find(e=>e.event===\"replace-failed\");
     process.exit(f && /\/C$/.test(f.to) && f.err===\"no health in 3s\" && !l.some(e=>e.event===\"replace\") ? 0 : 1);
   "'
kill_port "$FPORT"; sleep 0.5

# ---------------------------------------------------------------------------
# §7.2.7 — the bind is the lock: no pidfile, no second listener.
# ---------------------------------------------------------------------------
BPORT="$(free_port)"
BHIER="$TMP/hier-bind"
start_daemon "$BPORT" "$BHIER"
SECOND_HIER="$TMP/hier-bind2"
mkdir -p "$SECOND_HIER"
SECOND_OUT="$(AH_MCP_PORT="$BPORT" AGENT_HIERARCHY_DIR="$SECOND_HIER" node "$SERVER" --http 2>&1)"
SECOND_RC=$?
check "bind: a second daemon on a taken port exits 0" '[ "$SECOND_RC" -eq 0 ]'
check "bind: and prints nothing (a hook's stdout is model context)" '[ -z "$SECOND_OUT" ]'
check "bind: and records EADDRINUSE instead" 'grep -q "EADDRINUSE" "$SECOND_HIER/mcp-server.log"'

# ---------------------------------------------------------------------------
# §7.2.6 — --stop.
# ---------------------------------------------------------------------------
BEFORE_STOP_PID="$(health "$BPORT" | jfield pid)"
STOP_OUT="$(AH_MCP_PORT="$BPORT" AGENT_HIERARCHY_DIR="$BHIER" node "$SERVER" --stop 2>&1)"
sleep 1
check "--stop: names the pid it signalled" 'echo "$STOP_OUT" | grep -q "SIGTERM sent to pid"'
check "--stop: /health stops answering" '! health "$BPORT" >/dev/null 2>&1'
check "--stop: it recorded the stop request, naming the pid, before signalling" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$BHIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     const i=l.findIndex(e=>e.event===\"stop\");
     process.exit(i>=0 && l[i].target_pid===Number(\"$BEFORE_STOP_PID\") && l.slice(i).some(e=>e.event===\"signal\") ? 0 : 1);
   "'
check "--stop: the daemon logged signal SIGTERM and then exit" \
  'node -e "
     const l=require(\"fs\").readFileSync(\"$BHIER/mcp-server.log\",\"utf8\").trim().split(\"\n\").map(JSON.parse);
     process.exit(l.some(e=>e.event===\"signal\" && e.signal===\"SIGTERM\") && l.some(e=>e.event===\"exit\") ? 0 : 1);
   "'
check "--stop: says so, exit 0, when nothing is listening" \
  'OUT="$(AH_MCP_PORT="$(free_port)" AGENT_HIERARCHY_DIR="$BHIER" node "$SERVER" --stop 2>&1)" && echo "$OUT" | grep -q "nothing answering"'

# ---------------------------------------------------------------------------
# §7.2.5 — the SessionStart ensure hook.
# ---------------------------------------------------------------------------
HPORT="$(free_port)"
HHIER="$TMP/hier-hook"
mkdir -p "$HHIER"
HOOK_OUT="$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | \
  AH_MCP_PORT="$HPORT" AGENT_HIERARCHY_DIR="$HHIER" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" node "$ENSURE_HOOK" 2>&1)"
HOOK_RC=$?
check "ensure hook: exits 0" '[ "$HOOK_RC" -eq 0 ]'
check "ensure hook: prints nothing on success (stdout is injected context)" '[ -z "$HOOK_OUT" ]'
check "ensure hook: the daemon is answering afterwards" 'wait_health "$HPORT"'

BEFORE_COUNT="$(lsof -nP -iTCP:"$HPORT" -sTCP:LISTEN -t 2>/dev/null | wc -l | tr -d ' ')"
HOOK_OUT2="$(echo '{"hook_event_name":"SessionStart","source":"resume"}' | \
  AH_MCP_PORT="$HPORT" AGENT_HIERARCHY_DIR="$HHIER" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" node "$ENSURE_HOOK" 2>&1)"
sleep 0.5
AFTER_COUNT="$(lsof -nP -iTCP:"$HPORT" -sTCP:LISTEN -t 2>/dev/null | wc -l | tr -d ' ')"
check "ensure hook: a second run starts no second daemon" '[ "$BEFORE_COUNT" = "$AFTER_COUNT" ]'
check "ensure hook: and is still silent" '[ -z "$HOOK_OUT2" ]'

BAD_OUT="$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | \
  AH_MCP_PORT="$(free_port)" AGENT_HIERARCHY_DIR="$HHIER" CLAUDE_PLUGIN_ROOT="$TMP/not-a-plugin" node "$ENSURE_HOOK" 2>&1)"
BAD_RC=$?
check "ensure hook: an unstartable root still exits 0" '[ "$BAD_RC" -eq 0 ]'
check "ensure hook: and says so in one line naming the CLI fallback" \
  '[ "$(echo "$BAD_OUT" | wc -l | tr -d " ")" = "1" ] && echo "$BAD_OUT" | grep -q "CLI fallback"'

# ---------------------------------------------------------------------------
# Registration: the hook is wired into SessionStart with the same matcher as
# sessionstart.mjs, without displacing it.
# ---------------------------------------------------------------------------
check "hooks.json: sessionstart-mcp-ensure.mjs runs on SessionStart alongside sessionstart.mjs" \
  'node -e "
     const h=JSON.parse(require(\"fs\").readFileSync(\"$REPO_ROOT/hooks/hooks.json\",\"utf8\")).hooks.SessionStart;
     const e=h.find(x=>x.matcher===\"startup|resume|clear|compact|fork\");
     const cmds=e.hooks.map(x=>x.command).join(\" \");
     process.exit(cmds.includes(\"sessionstart.mjs\") && cmds.includes(\"sessionstart-mcp-ensure.mjs\") ? 0 : 1);
   "'

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
