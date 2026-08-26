#!/usr/bin/env bash
# Tests for agent-hierarchy/mcp/server.mjs — spec 0013.
#
# Covers spec 0013 §12 tests 1-6, 8-13. Test 7 (gate_status cwd correctness)
# is retired by amendment (c): gate_status is excluded on independent merits
# (§8.3 — GATE_CLI is already a resolved path constant at lib-config.mjs:41),
# not by the cwd-divergence claim test 7 would have checked, which cannot
# occur (one global HOME-anchored file). The number is not reused. Test 11
# (full regression) is not re-run inside this file — it is satisfied by
# running the whole test suite separately, which this round's report records
# the result of.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SERVER="$REPO_ROOT/mcp/server.mjs"
MSG_CLI="$REPO_ROOT/hooks/msg.mjs"
ROSTER_CLI="$REPO_ROOT/hooks/roster.mjs"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
LIB_CONFIG="$REPO_ROOT/hooks/lib-config.mjs"
GIT_ROOT="$(git -C "$REPO_ROOT" rev-parse --show-toplevel)"
MARKETPLACE_JSON="$GIT_ROOT/.claude-plugin/marketplace.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
unset AGENT_HIERARCHY_DIR

REPO_A="$TMP/repo-a"
REPO_B="$TMP/repo-b"
mkdir -p "$REPO_A" "$REPO_B"
(cd "$REPO_A" && git init -q)
(cd "$REPO_B" && git init -q)

PASS=0
FAIL=0

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
  fi
}

# ---------------------------------------------------------------------------
# Tests 1, 2, 4: protocol interop, cwd-required, wrong-cwd isolation.
# Driven by a small Node client speaking newline-delimited JSON-RPC over the
# server's stdio, generated at test time (not committed — server.mjs and
# this file are the only new files spec 0013 §4.3 lists).
# ---------------------------------------------------------------------------
cat > "$TMP/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [, , serverPath, repoA, repoB] = process.argv;
const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "pipe"] });
const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });

const pending = new Map();
let nextId = 1;
let lineCount = 0;
rl.on("line", (line) => {
  lineCount += 1;
  try {
    const msg = JSON.parse(line);
    if (msg && typeof msg === "object" && "id" in msg && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  } catch {
    // non-JSON stdout would be a server bug; ignored here, protocol tests below catch it via id correlation timing out.
  }
});

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + "\n");
}
function call(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    send({ jsonrpc: "2.0", id, method, params });
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        resolve(null);
      }
    }, 5000);
  });
}
function notify(method, params) {
  send({ jsonrpc: "2.0", method, params });
}

const results = [];
function report(name, ok, detail) {
  results.push(`${ok ? "PASS" : "FAIL"}: ${name}${ok ? "" : ` — ${detail}`}`);
}

const init = await call("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "0" } });
report("initialize responds", Boolean(init && init.result), JSON.stringify(init));
report("initialize declares only tools capability", Boolean(init && init.result && init.result.capabilities && "tools" in init.result.capabilities && !("resources" in init.result.capabilities) && !("prompts" in init.result.capabilities) && !("sampling" in init.result.capabilities)), JSON.stringify(init && init.result && init.result.capabilities));
report("initialize returns a protocolVersion string", Boolean(init && init.result && typeof init.result.protocolVersion === "string" && init.result.protocolVersion), JSON.stringify(init));
notify("notifications/initialized", {});

const toolsList = await call("tools/list", {});
const names = (toolsList && toolsList.result && toolsList.result.tools || []).map((t) => t.name).sort();
const expected = ["msg_index", "msg_list", "msg_new", "msg_roster", "roster_show", "roster_teams"];
report("tools/list returns exactly the 6-tool inventory", JSON.stringify(names) === JSON.stringify(expected), JSON.stringify(names));

const ping = await call("ping", {});
report("ping answered", Boolean(ping && ping.result && typeof ping.result === "object" && !ping.error), JSON.stringify(ping));

const unknownMethod = await call("totally/unknown/method", {});
report("unknown method -> -32601", Boolean(unknownMethod && unknownMethod.error && unknownMethod.error.code === -32601), JSON.stringify(unknownMethod));

const beforeGarbage = lineCount;
child.stdin.write("not json at all\n");
await new Promise((r) => setTimeout(r, 300));
report("garbage line produced a response", lineCount > beforeGarbage, `lineCount ${beforeGarbage} -> ${lineCount}`);

const beforeUnknownNotif = lineCount;
notify("totally/unknown/notification", {});
await new Promise((r) => setTimeout(r, 300));
report("unknown notification produces NO response", lineCount === beforeUnknownNotif, `lineCount ${beforeUnknownNotif} -> ${lineCount}`);

const [c1, c2] = await Promise.all([
  call("tools/call", { name: "roster_teams", arguments: { cwd: repoA } }),
  call("tools/call", { name: "roster_teams", arguments: { cwd: repoB } }),
]);
report("concurrent tools/call requests both resolve", Boolean(c1 && c1.result && c2 && c2.result), JSON.stringify([c1, c2]));

// Test 2: cwd required, never defaulted.
const noCwd = await call("tools/call", { name: "msg_new", arguments: { to: "architect", from: "orchestrator", slug: "no-cwd-test" } });
const noCwdResult = noCwd && noCwd.result;
report(
  "msg_new with no cwd fails naming the parameter, not silently defaulting",
  Boolean(noCwdResult && noCwdResult.isError && /cwd/i.test(noCwdResult.content[0].text)),
  JSON.stringify(noCwd)
);

// Test 4: wrong-cwd isolation.
const newA = await call("tools/call", { name: "msg_new", arguments: { cwd: repoA, to: "architect", from: "orchestrator", slug: "isolation-test" } });
report("msg_new against repo A succeeds", Boolean(newA && newA.result && !newA.result.isError), JSON.stringify(newA));

const EXPECTED_RESULT_COUNT = 11;
report("driver reported exactly the expected number of results", results.length === EXPECTED_RESULT_COUNT, `got ${results.length}, expected ${EXPECTED_RESULT_COUNT}`);

console.log(JSON.stringify({ results, done: true }));
child.stdin.end();
child.kill();
EOF

node "$TMP/driver.mjs" "$SERVER" "$REPO_A" "$REPO_B" > "$TMP/driver-out.json" 2>"$TMP/driver-err.log"
if [ -s "$TMP/driver-err.log" ]; then
  echo "--- driver stderr ---"
  cat "$TMP/driver-err.log"
fi

while IFS= read -r line; do
  case "$line" in
    PASS:*) PASS=$((PASS + 1)); echo "$line" ;;
    FAIL:*) FAIL=$((FAIL + 1)); echo "$line" ;;
  esac
done < <(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); d.results.forEach(l=>console.log(l))' "$TMP/driver-out.json" 2>/dev/null || echo "FAIL: driver produced no parseable output")

check "wrong-cwd isolation: repo B's msgs dir has no message from the repo-A call" \
  '[ ! -d "'"$REPO_B"'/.claude/hierarchy/msgs" ] || [ -z "$(ls -A "'"$REPO_B"'/.claude/hierarchy/msgs" 2>/dev/null)" ]'
check "wrong-cwd isolation: repo A's msgs dir DOES have the message" \
  '[ -d "'"$REPO_A"'/.claude/hierarchy/msgs" ] && [ -n "$(ls -A "'"$REPO_A"'/.claude/hierarchy/msgs" 2>/dev/null)" ]'

# ---------------------------------------------------------------------------
# Test 3: tool-vs-CLI equivalence.
# ---------------------------------------------------------------------------
cat > "$TMP/equiv.mjs" <<'EOF'
import { execFileSync } from "node:child_process";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [, , serverPath, msgCli, rosterCli, repoA] = process.argv;

function callViaServer(name, args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "ignore"] });
    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
    rl.on("line", (line) => {
      try {
        const msg = JSON.parse(line);
        if (msg.id === 2) {
          resolve(msg.result);
          child.stdin.end();
          child.kill();
        }
      } catch {}
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }) + "\n");
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } }) + "\n");
  });
}

// roster_show: pure read, deterministic, no roster configured at "repo" level -> byte-identical.
const toolShow = await callViaServer("roster_show", { cwd: repoA, level: "repo" });
const cliShow = execFileSync(process.execPath, [rosterCli, "show", "--level", "repo", "--cwd", repoA]).toString();
const showMatch = toolShow.content[0].text === cliShow;

// msg_new: id/timestamp differ by construction; normalize both before comparing.
const toolNew = await callViaServer("msg_new", { cwd: repoA, to: "architect", from: "orchestrator", slug: "equiv-tool" });
const cliNewRaw = execFileSync(process.execPath, [msgCli, "new", "--to", "architect", "--from", "orchestrator", "--slug", "equiv-cli", "--cwd", repoA]).toString().replace(/\n$/, "");
function normalize(text) {
  const obj = JSON.parse(text);
  return { keys: Object.keys(obj).sort(), idLooksLikeId: /^\d{8}-\d{6}-[a-z0-9]+$/.test(obj.id), pathEndsInMd: obj.path.endsWith(".md"), pathContainsMsgsDir: obj.path.includes("/msgs/") };
}
const toolNewNorm = normalize(toolNew.content[0].text);
const cliNewNorm = normalize(cliNewRaw);
const newMatch = JSON.stringify(toolNewNorm) === JSON.stringify(cliNewNorm);

console.log(JSON.stringify({ showMatch, newMatch, toolShow: toolShow.content[0].text, cliShow: cliShow.trim() }));
EOF

node "$TMP/equiv.mjs" "$SERVER" "$MSG_CLI" "$ROSTER_CLI" "$REPO_A" > "$TMP/equiv-out.json" 2>"$TMP/equiv-err.log"
if [ -s "$TMP/equiv-err.log" ]; then
  echo "--- equivalence driver stderr ---"
  cat "$TMP/equiv-err.log"
fi
check "roster_show tool output is byte-identical to the CLI invocation" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/equiv-out.json\",\"utf8\")); process.exit(d.showMatch?0:1)"'
check "msg_new tool output matches the CLI invocation apart from id/timestamp" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/equiv-out.json\",\"utf8\")); process.exit(d.newMatch?0:1)"'

# ---------------------------------------------------------------------------
# Test 6: stderr preservation mechanism.
#
# None of the 6 shipped tools has a real CLI path that produces non-empty
# stderr at exit 0 (confirmed: roster.mjs's only stderr-at-exit-0 warning —
# the level-defaulting notice — fires only from add/edit/remove/layout, all
# excluded from the tool inventory; msg.mjs's only stderr write is fail()'s
# exit-2 path). This exercises the mapping function directly with synthetic
# inputs instead of fabricating a false real-world trigger.
# ---------------------------------------------------------------------------
MAP_CHECK="$(node --input-type=module -e "
import { mapExecResult } from '$SERVER';
const a = mapExecResult({code:0, stdout:'{\"ok\":true}', stderr:'ah: no --level given — added at repo\n', scriptPath:'x'});
const okA = !a.isError && a.content[0].text.startsWith('{\"ok\":true}') && a.content[0].text.includes('stderr:') && a.content[0].text.includes('no --level given');
const b = mapExecResult({code:2, stdout:'', stderr:'roster.mjs: bad args', scriptPath:'x'});
const okB = b.isError === true && b.content[0].text.startsWith('exit=2') && b.content[0].text.includes('bad args');
const c = mapExecResult({code:-1, stdout:'', stderr:'ENOENT', scriptPath:'/abs/path/roster.mjs'});
const okC = c.isError === true && c.content[0].text.includes('/abs/path/roster.mjs');
const d = mapExecResult({code:0, stdout:'clean output', stderr:'', scriptPath:'x'});
const okD = !d.isError && d.content[0].text === 'clean output';
console.log(okA && okB && okC && okD ? 'PASS' : 'FAIL ' + JSON.stringify({okA,okB,okC,okD}));
" 2>&1)"
check "mapExecResult: exit 0 + stderr appended, exit 2 -> isError w/ exit=2 prefix, spawn failure names script path, clean exit 0 untouched" \
  '[ "$MAP_CHECK" = "PASS" ]'

# ---------------------------------------------------------------------------
# Test 5: directive/doc static greps.
# ---------------------------------------------------------------------------
check "lib-config.mjs defines ROSTER_CLI" \
  'grep -q "ROSTER_CLI" "'"$LIB_CONFIG"'"'

for f in architect implementor reviewer task-runner ultra-advisor; do
  check "agents/$f.md names mcp__ah__msg_new" \
    'grep -q "mcp__ah__msg_new" "'"$REPO_ROOT"'/agents/'"$f"'.md"'
done

BARE_HITS="$(node -e '
const fs = require("fs");
const re = /(?<![\/\w])hooks\/(msg|roster)\.mjs/;
let hits = [];
for (const f of process.argv.slice(1)) {
  const lines = fs.readFileSync(f, "utf8").split("\n");
  lines.forEach((l, i) => { if (re.test(l)) hits.push(f + ":" + (i + 1)); });
}
console.log(hits.join("\n"));
' "$REPO_ROOT"/agents/architect.md "$REPO_ROOT"/agents/implementor.md "$REPO_ROOT"/agents/reviewer.md "$REPO_ROOT"/agents/task-runner.md "$REPO_ROOT"/agents/ultra-advisor.md "$REPO_ROOT"/skills/agent-roster/SKILL.md)"
if [ -n "$BARE_HITS" ]; then echo "bare hits: $BARE_HITS"; fi
check "no bare relative hooks/msg.mjs or hooks/roster.mjs in agents/*.md or SKILL.md" \
  '[ -z "$BARE_HITS" ]'

# ---------------------------------------------------------------------------
# Test 8: no npm lifecycle files anywhere under agent-hierarchy/.
# ---------------------------------------------------------------------------
NPM_HITS="$(find "$REPO_ROOT" \( -name package.json -o -name package-lock.json -o -name node_modules \) 2>/dev/null)"
check "no package.json / package-lock.json / node_modules under agent-hierarchy/" \
  '[ -z "$NPM_HITS" ]'

# ---------------------------------------------------------------------------
# Test 9: no .mcp.json at the plugin root.
# ---------------------------------------------------------------------------
check "no .mcp.json at agent-hierarchy/ root" \
  '[ ! -f "'"$REPO_ROOT"'/.mcp.json" ]'

# ---------------------------------------------------------------------------
# Test 10 (widened, amendment (d)): both plugin.json AND marketplace.json's
# `ah` entry must each have a present, well-formed mcpServers.ah block.
# Absence is a FAILURE, not a skip — a marketplace install missing the block
# registers nothing, silently, and a naive "parse + check entries" reads
# clean against zero entries. Static config-shape only — never a live
# registration check (a ~33%-flaky bug would pass most runs and prove
# nothing).
#
# Test 13 (NEW, amendment (d)): the two copies' mcpServers.ah blocks must be
# deep-equal. Test 10 only proves each copy is individually well-formed;
# mandatory duplication (§4.3) without an equality check is a drift hazard —
# the copies can diverge on a later edit and only a marketplace install sees
# the stale one.
# ---------------------------------------------------------------------------
node -e '
const fs = require("fs");
function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null) return false;
  if (typeof a !== "object") return false;
  const ak = Object.keys(a).sort(), bk = Object.keys(b).sort();
  if (JSON.stringify(ak) !== JSON.stringify(bk)) return false;
  return ak.every((k) => deepEqual(a[k], b[k]));
}
function assertEntry(srv) {
  if (!srv) return { present: false, cmdOk: false, argsOk: false };
  const cmdOk = !String(srv.command).includes("${CLAUDE_PLUGIN_ROOT}");
  const argsOk = Array.isArray(srv.args) && srv.args.some((a) => String(a).includes("${CLAUDE_PLUGIN_ROOT}"));
  return { present: true, cmdOk, argsOk };
}
const pluginJson = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const pluginSrv = pluginJson.mcpServers && pluginJson.mcpServers.ah;
const marketJson = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const marketEntry = (marketJson.plugins || []).find((p) => p.name === "ah");
const marketSrv = marketEntry && marketEntry.mcpServers && marketEntry.mcpServers.ah;
const out = {
  plugin: assertEntry(pluginSrv),
  marketplace: assertEntry(marketSrv),
  equal: deepEqual(pluginSrv, marketSrv),
};
fs.writeFileSync(process.argv[3], JSON.stringify(out));
' "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$TMP/test10-13.json"

check "plugin.json mcpServers.ah is present" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.plugin.present?0:1)"'
check "plugin.json mcpServers.ah: \${CLAUDE_PLUGIN_ROOT} not in command" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.plugin.cmdOk?0:1)"'
check "plugin.json mcpServers.ah: \${CLAUDE_PLUGIN_ROOT} in args" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.plugin.argsOk?0:1)"'
check "marketplace.json ah entry's mcpServers.ah is present" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.marketplace.present?0:1)"'
check "marketplace.json mcpServers.ah: \${CLAUDE_PLUGIN_ROOT} not in command" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.marketplace.cmdOk?0:1)"'
check "marketplace.json mcpServers.ah: \${CLAUDE_PLUGIN_ROOT} in args" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.marketplace.argsOk?0:1)"'
check "plugin.json and marketplace.json mcpServers.ah blocks are deep-equal" \
  'node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"$TMP/test10-13.json\",\"utf8\")); process.exit(d.equal?0:1)"'

# ---------------------------------------------------------------------------
# Test 12: gate.mjs and lib-gate.mjs are untouched by this spec's changes.
# §8's retracted ruling once authorised a two-line edit to gate.mjs; that
# authorisation is revoked (§4.3, §8.3), and this guard is what closes it —
# a stale spec revision must not be actable on later. Static: the diff of
# this spec's (not-yet-committed) changes against HEAD must not touch either
# file, staged or unstaged.
# ---------------------------------------------------------------------------
GATE_DIFF_HITS="$(git -C "$GIT_ROOT" diff --name-only HEAD -- agent-hierarchy/hooks/gate.mjs agent-hierarchy/hooks/lib-gate.mjs)"
check "gate.mjs and lib-gate.mjs are untouched by this spec's changes" \
  '[ -z "$GATE_DIFF_HITS" ]'

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
