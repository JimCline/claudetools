#!/bin/bash
# agent-hierarchy — per-member `kind` (spec 0043): roster members spawnable as
# non-Claude agent CLIs through Herdr.
#
# Three cases here are the spec's own must-pass set (§7) — all three are the
# same underlying bug, "an unset or unexpected value read as a definite
# negative", which would end in either a duplicate agent or a stranded one:
#   §4.5  args must be SHELL-QUOTED into runShell's /bin/sh -c line, not joined
#   §4.4  Herdr-unreachable is INDETERMINATE, not "not live" (else duplicate spawn)
#   §4.4  absent `interactive_ready` falls back, is not read as false
#
# Reuses the fake-herdr/tmux stub convention from test-herdr-pane-label.sh
# (per-invocation call records under $FAKE_STATE_DIR/calls/), extended with an
# `agent get` handler driven by $FAKE_HERDR_GET_JSON / $FAKE_HERDR_GET_EXIT and
# an `agent start` handler that can return Herdr's real error shapes.
# Usage: bash tests/test-roster-agent-kind.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-agent-kind-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/bin"
(cd "$PROJ" && git init -q)
NODE_DIR="$(dirname "$(command -v node)")"
CFG="$PROJ/.claude/agent-hierarchy.json"
PWNED="$SANDBOX/ah-pwned"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

# ---- fake herdr -------------------------------------------------------------
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
  fs.writeFileSync(file, JSON.stringify({ argv: args, exit: exitCode, bin: "herdr" }));
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

if (args[0] === "agent" && args[1] === "start") {
  // Record the post-`--` passthrough exactly as this process received it, so the
  // test can assert argv boundaries rather than re-parsing a command string.
  const dashdash = args.indexOf("--");
  const passthrough = dashdash === -1 ? [] : args.slice(dashdash + 1);
  fs.writeFileSync(path.join(dir, "last-start.json"), JSON.stringify({ argv: args, passthrough }));
  const mode = process.env.FAKE_HERDR_START_MODE || "ok";
  if (mode === "unknown-kind") {
    process.stderr.write("fake herdr: unknown agent kind 'nosuchkind'\n");
    finish(1);
  }
  if (mode === "timeout") {
    console.log(JSON.stringify({ error: { code: "timeout", message: "agent never became ready" } }));
    finish(1);
  }
  if (mode === "not-ready") {
    // Herdr's real shape for a first-run onboarding gate: error JSON on STDOUT, exit 1.
    console.log(JSON.stringify({ error: { code: "agent_not_ready", message: "agent is blocked" } }));
    finish(1);
  }
  console.log(JSON.stringify({ result: { pane: { pane_id: "target" }, agent: { name: args[2], ready: true } } }));
  finish(0);
}

if (args[0] === "agent" && args[1] === "get") {
  const exit = Number(process.env.FAKE_HERDR_GET_EXIT || 0);
  // Default: the agent does not exist — exit 1 with the error JSON on STDOUT, which is Herdr's
  // real shape (r4). Tests that need another state set FAKE_HERDR_GET_JSON/_EXIT explicitly.
  const body = process.env.FAKE_HERDR_GET_JSON;
  if (body === undefined) {
    console.log(JSON.stringify({ error: { code: "agent_not_found", message: "no such agent" } }));
    finish(1);
  }
  console.log(body); // stdout on BOTH paths — this is the real behaviour being modelled
  finish(exit);
}

if (args[0] === "pane" && args[1] === "rename") {
  console.log(JSON.stringify({ result: { pane: { pane_id: args[2], label: args.slice(3).join(" ") } } }));
  finish(0);
}

if (args[0] === "pane" && args[1] === "close") {
  console.log(JSON.stringify({ result: { closed: args[2] } }));
  finish(0);
}

process.stderr.write(`fake herdr: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

# ---- fake tmux / claude -----------------------------------------------------
cat > "$SANDBOX/bin/tmux" <<EOF
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
  fs.writeFileSync(file, JSON.stringify({ argv: args, exit: exitCode, bin: "tmux" }));
  process.exit(exitCode);
}
if (args[0] === "list-sessions") finish(0);
if (args[0] === "new-window") {
  const idFile = path.join(dir, "tmux-next-id.json");
  let n = 1;
  if (fs.existsSync(idFile)) n = JSON.parse(fs.readFileSync(idFile, "utf8")).next;
  fs.writeFileSync(idFile, JSON.stringify({ next: n + 1 }));
  console.log(`%${n}`);
  finish(0);
}
if (args[0] === "send-keys") finish(0);
process.stderr.write(`fake tmux: unhandled args ${JSON.stringify(args)}\n`);
finish(1);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/tmux"
mkdir -p "$SANDBOX/bin-claude-only"
cat > "$SANDBOX/bin-claude-only/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin-claude-only/claude"
cp "$SANDBOX/bin-claude-only/claude" "$SANDBOX/bin/claude"

FAKE_STATE_DIR="$SANDBOX/state"
reset_state() { rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"; }
init_geometry() {
  cat > "$FAKE_STATE_DIR/geometry.json" <<EOF
{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}
EOF
}
clear_hierarchy() { rm -rf "$PROJ/.claude/hierarchy"; rm -f "$CFG"; }

# `env -u HERDR_ENV` everywhere so an ambient Herdr session running this suite
# cannot silently change which transport is under test.
# roster.mjs writes its JSON result to stdout and its warnings/errors to stderr. They are captured
# SEPARATELY here: OUT (both, for message greps) and $STDOUT_F (stdout only, for JSON parsing) —
# a warning line prepended to the JSON would otherwise break every JSON.parse assertion.
STDOUT_F="$SANDBOX/out.json"
STDERR_F="$SANDBOX/err.txt"
r() { # <extra_env> <roster.mjs args...>
  local extra_env=$1; shift
  eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" CLAUDE_PID=$$ $extra_env node \"$H/roster.mjs\" $* --cwd \"$PROJ\" >\"$STDOUT_F\" 2>\"$STDERR_F\""; RC=$?
  OUT="$(cat "$STDOUT_F" "$STDERR_F")"
}
# terminal transport: neither herdr nor tmux resolvable
rterm() {
  local extra_env=$1; shift
  eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" PATH=\"$SANDBOX/bin-claude-only:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" CLAUDE_PID=$$ $extra_env node \"$H/roster.mjs\" $* --cwd \"$PROJ\" >\"$STDOUT_F\" 2>\"$STDERR_F\""; RC=$?
  OUT="$(cat "$STDOUT_F" "$STDERR_F")"
}
# Evaluate a JS expression over the parsed stdout JSON (bound as `o`).
jo() { node -e 'let o;try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{console.log("ERR");process.exit(0)}try{console.log(eval(process.argv[2]))}catch(e){console.log("ERR")}' "$STDOUT_F" "$1"; }
# The launch string a --dry-run produced, decoded from JSON (not grepped through JSON escaping).
launch_str() { jo 'o.launch[0]'; }
init_roster() { r "" init --level repo --route peer >/dev/null 2>&1; }
jqnode() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(eval(process.argv[1]))}catch(e){console.log("ERR")}})' "$1"; }

########################################################################
# §4.1 — BACKCOMPAT (the load-bearing test)
########################################################################
# Baseline strings are asserted literally rather than diffed against a
# pre-change capture: they ARE the pre-change output, and pinning them here is
# what makes a future edit to spawnShape's claude branch fail loudly.
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role architect --model opus
r "" add --no-spawn --role implementor --model sonnet

r "HERDR_ENV=1" spawn-one architect --dry-run
check "4.1a: no kind key anywhere -> herdr launch string is byte-identical to pre-0043" \
  '[ "$RC" -eq 0 ] && [ "$(launch_str)" = "herdr agent start myrepo-architect --kind claude --pane <TARGET> -- --agent ah:architect --name myrepo-architect --model opus" ]'
check "4.1a2: no --timeout leaked into the claude launch string" \
  '! launch_str | grep -q -- "--timeout"'

r "" spawn-one architect --dry-run
check "4.1b: tmux transport launch string byte-identical" \
  '[ "$RC" -eq 0 ] && [ "$(launch_str)" = "tmux send-keys -t <TARGET> \"claude --agent ah:architect --name myrepo-architect --model opus\" Enter" ]'

rterm "" spawn-one architect --dry-run
check "4.1c: terminal transport launch string byte-identical" \
  '[ "$RC" -eq 0 ] && [ "$(launch_str)" = "claude --agent ah:architect --name myrepo-architect --model opus --bg" ]'

check "4.1d: reading the roster did NOT rewrite the config file with kind keys" \
  '! grep -q "\"kind\"" "$CFG"'

r "" show
check "4.1e: resolved members report kind claude explicitly (default applied at the read seam)" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.members.filter(m=>m.kind===\"claude\").length")" = "2" ]'

# explicit kind: "claude" in the file behaves identically and is accepted unchanged
node -e '
  const fs=require("fs"); const p=process.argv[1];
  const d=JSON.parse(fs.readFileSync(p,"utf8"));
  d.roster.members[0].kind="claude";
  fs.writeFileSync(p, JSON.stringify(d,null,2));
' "$CFG"
r "HERDR_ENV=1" spawn-one architect --dry-run
check "4.1f: an explicit kind:\"claude\" in the file produces the identical launch string" \
  '[ "$RC" -eq 0 ] && [ "$(launch_str)" = "herdr agent start myrepo-architect --kind claude --pane <TARGET> -- --agent ah:architect --name myrepo-architect --model opus" ]'

########################################################################
# §4.2 — VALIDATION
########################################################################
reset_state; clear_hierarchy; init_geometry; init_roster

r "" add --no-spawn --role implementor --kind codex --route pane --model sonnet
check "4.2a: --kind codex with --model -> rejected, message names model" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "model is a Claude Code CLI flag"'
r "" add --no-spawn --role implementor --kind codex --route pane --effort high
check "4.2b: --kind codex with --effort -> rejected, message names effort" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "effort is a Claude Code CLI flag"'
r "" add --no-spawn --role implementor --kind codex --route pane --auto-mode acceptEdits
check "4.2c: --kind codex with --auto-mode -> rejected, message names auto-mode" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "auto-mode is a Claude Code CLI flag"'

# THE role-default trap: without the kind-aware ROLE_DEFAULTS guard this add is
# rejected for a model the user never supplied, i.e. non-claude members would be
# uncreatable at all.
r "" add --no-spawn --role implementor --kind codex --route pane
check "4.2d: --kind codex with NO --model -> accepted (ROLE_DEFAULTS trap)" '[ "$RC" -eq 0 ]'
check "4.2d2: ...and the stored member has no model key at all" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).roster.members.find(x=>x.kind===\"codex\");process.exit(m && !(\"model\" in m)?0:1)" "$CFG"'
check "4.2d3: ...and the stored member records kind codex" \
  'node -e "const m=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).roster.members.find(x=>x.kind===\"codex\");process.exit(m?0:1)" "$CFG"'

clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind claude
check "4.2e: --kind claude with no --model still gets ROLE_DEFAULTS.implementor (inherit)" \
  '[ "$RC" -eq 0 ] && node -e "const m=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).roster.members[0];process.exit(m.model===\"inherit\"?0:1)" "$CFG"'
check "4.2e2: an explicit --kind claude is NOT written to the file (§1.1 persistence)" \
  '! grep -q "\"kind\"" "$CFG"'

clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --on-missing auto
check "4.2f: --kind codex --route pane --on-missing auto -> accepted (§1.3)" '[ "$RC" -eq 0 ]'

clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"--profile\",\"fast\"]"'
check "4.2g: args as an array of non-empty strings on a non-claude member -> accepted" \
  '[ "$RC" -eq 0 ] && node -e "const m=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).roster.members[0];process.exit(JSON.stringify(m.args)===JSON.stringify([\"--profile\",\"fast\"])?0:1)" "$CFG"'

clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"\"justastring\""'
check "4.2h: args as a bare string -> rejected" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args must be an array of strings"'
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[[\"nested\"]]"'
check "4.2i: args with a nested array element -> rejected, names the element index" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args\[0\] must be a non-empty string"'
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"ok\",\"\"]"'
check "4.2j: args with an empty-string element -> rejected, names the element index" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args\[1\] must be a non-empty string"'
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"ok\",7]"'
check "4.2k: args with a non-string element -> rejected, names the element index" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args\[1\] must be a non-empty string"'

# args on kind claude: the rejection every model/effort/permission rule depends on
clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --args '"[\"--model\",\"haiku\"]"'
check "4.2l: args on a kind:claude member -> rejected at add" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args is not allowed for kind"'
r "" add --no-spawn --role ultra-advisor --model fable --args '"[\"--model\",\"haiku\"]"'
check "4.2m: args cannot be used to defeat the ultra-advisor top-tier model rule" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args is not allowed for kind"'

# ...and again at SPAWN, for the config a hand edit produced without passing add
clear_hierarchy; init_roster
r "" add --no-spawn --role ultra-advisor --model fable
node -e '
  const fs=require("fs"); const p=process.argv[1];
  const d=JSON.parse(fs.readFileSync(p,"utf8"));
  d.roster.members[0].args=["--model","haiku"];
  fs.writeFileSync(p, JSON.stringify(d,null,2));
' "$CFG"
r "HERDR_ENV=1" spawn-one ultra-advisor
check "4.2n: hand-edited args on a kind:claude member is re-rejected at spawn" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "args is not allowed for kind"'
check "4.2n2: ...and no agent-start was ever shelled for it" \
  '[ ! -f "$FAKE_STATE_DIR/last-start.json" ]'

# route rules
clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind codex --route peer
check "4.2o: --kind codex --route peer -> rejected" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "route must be .pane. for kind"'
r "" add --no-spawn --role implementor --kind codex --route subagent
check "4.2p: --kind codex --route subagent -> rejected" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "route must be .pane. for kind"'
r "" add --no-spawn --role implementor --kind codex --route pane
check "4.2q: --kind codex --route pane -> accepted" '[ "$RC" -eq 0 ]'

# kind shape
clear_hierarchy; init_roster
r "" add --no-spawn --role implementor --kind Codex --route pane
check "4.2r: --kind Codex (uppercase) -> rejected on shape" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "kind must be a non-empty lowercase string"'
r "" add --no-spawn --role implementor --kind "'co dex'" --route pane
check "4.2s: --kind \"co dex\" (space) -> rejected on shape" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "kind must be a non-empty lowercase string"'
r "" add --no-spawn --role implementor --kind some-kind-nobody-has --route pane
check "4.2t: an unknown kind -> ACCEPTED (no allowlist, §1.2)" '[ "$RC" -eq 0 ]'

# per-role claude model rules are untouched
clear_hierarchy; init_roster
r "" add --no-spawn --role ultra-advisor --model sonnet
check "4.2u: kind claude ultra-advisor with a non-top-tier model still rejected" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "is not valid for role"'
r "" add --no-spawn --role architect --model haiku
check "4.2v: kind claude architect on haiku still rejected" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "is not valid for role"'
r "" add --no-spawn --role architect --model opus
check "4.2w: kind claude architect on opus still accepted" '[ "$RC" -eq 0 ]'

# §1.7 derived-name shape. A non-claude member has no non-Herdr transport to fall back to, so an
# unusable name is a hard error. A claude member still launches on tmux/terminal with such a name
# (tests/test-roster-spawn-cwd.sh asserts a spaced repo path works), so it warns instead — see the
# §1.7-vs-§3 conflict recorded in the implementation report.
LONGREPO="$SANDBOX/averyveryverylongrepositoryname"
mkdir -p "$LONGREPO/.claude" && (cd "$LONGREPO" && git init -q)
lr() { OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" node "$H/roster.mjs" "$@" --cwd "$LONGREPO" 2>&1); RC=$?; }
lr init --level repo --route peer
lr add --no-spawn --role implementor --kind codex --route pane
check "4.2x: a derived name over 32 chars on a NON-claude member -> rejected, naming limit and value" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "Herdr.s agent-name rule" && echo "$OUT" | grep -q "averyveryverylongrepositoryname-implementor"'
lr add --no-spawn --role ultra-advisor --model fable
check "4.2x2: the same over-long name on a claude member warns but still succeeds (§3 must-not-change)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "Herdr.s agent-name rule"'

########################################################################
# §4.3 — SPAWN
########################################################################
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane

r "HERDR_ENV=1" spawn-one implementor --dry-run
check "4.3a: codex dry-run launch names --kind codex" \
  '[ "$RC" -eq 0 ] && launch_str | grep -qF "herdr agent start myrepo-implementor --kind codex"'
check "4.3b: ...and emits NO claude flags (--agent/--name/--model/--effort/--permission-mode)" \
  '! launch_str | grep -qE -- "--agent |--name |--model |--effort |--permission-mode "'
# spec r6: the flag was inert (herdr's own default is the same value) and broke §3's
# byte-identical claude string, so no launch string on EITHER path may carry it.
check "4.3b2: ...and carries NO --timeout flag (spec r6 removed it)" \
  '! launch_str | grep -qF -- "--timeout"'

reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role architect --model opus
r "HERDR_ENV=1" spawn-one architect --dry-run
check "4.3b3: the claude launch string carries NO --timeout either" \
  '[ "$RC" -eq 0 ] && ! launch_str | grep -qF -- "--timeout"'

reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane

# non-herdr transport: refused, nothing shelled, the rest of a team still launches
reset_state; init_geometry
r "" spawn-one implementor
check "4.3c: codex member under tmux -> spawn refused" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "requires the herdr transport"'
check "4.3c2: ...and nothing was shelled for it (no tmux send-keys, no agent start)" \
  '[ ! -f "$FAKE_STATE_DIR/last-start.json" ]'
# §1.4/§4.3 "no command is shelled for it" includes the LAYOUT step — a refused member that still
# got a pane leaves an orphan window behind.
check "4.3c3: ...and NO pane/window was created for the refused member" \
  '! grep -rqE "new-window|\"split\"" "$FAKE_STATE_DIR/calls" 2>/dev/null'

reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role architect --model opus
r "" add --no-spawn --role implementor --kind codex --route pane
r "" create --spawn --mode auto
check "4.3d: mixed roster under tmux -> claude member launches, codex refused, partial reported" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.partial")" = "true" ]'
check "4.3d2: ...the claude member is not failed" \
  '[ "$(jo "o.members.find(m=>m.name===\"myrepo-architect\").launch_status")" != "failed" ]'
check "4.3d3: ...the codex member is failed and names the transport" \
  '[ "$(jo "o.members.find(m=>m.name===\"myrepo-implementor\").launch_status")" = "failed" ] && echo "$OUT" | grep -q "requires the herdr transport"'

# Spec 0044 §1.10 reverses spec 0039: `add` is a roster-template edit and launches nothing.
# The kind/route launch coverage this block used to get from `add` now comes from `spawn-one`,
# which is the one launch path.
reset_state; clear_hierarchy; init_geometry; init_roster
r "HERDR_ENV=1" add --role implementor --kind codex --route pane
check "4.3e: add --kind codex --route pane writes config and launches nothing" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.spawned")" = "false" ] && [ ! -f "$FAKE_STATE_DIR/last-start.json" ]'
check "4.3e2: ...and points at spawn-one instead of claiming a launch" \
  'echo "$OUT" | grep -q "nothing was launched" && echo "$OUT" | grep -q "spawn-one"'
r "HERDR_ENV=1" spawn-one implementor
check "4.3e3: ...and spawn-one then records route pane and kind codex in the team file" \
  '[ "$RC" -eq 0 ] && node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));const m=t.members[0];process.exit(m.route===\"pane\"&&m.kind===\"codex\"?0:1)" "$PROJ/.claude/hierarchy/teams/$(basename "$PROJ").json"'

# §1.10 R1: `--no-spawn` survives as a silent no-op, so an old call site is byte-identical.
reset_state; clear_hierarchy; init_geometry; init_roster
r "HERDR_ENV=1" add --no-spawn --role implementor --kind codex --route pane
check "4.3f: add --no-spawn writes config and spawns nothing" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.spawned")" = "false" ] && [ ! -f "$FAKE_STATE_DIR/last-start.json" ]'

# herdr's own error text passes through verbatim
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind nosuchkind --route pane
r "HERDR_ENV=1 FAKE_HERDR_START_MODE=unknown-kind" spawn-one implementor
check "4.3g: an unknown kind -> herdr's own stderr appears verbatim, unreworded" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "fake herdr: unknown agent kind"'

# pane label carries the kind
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane
r "HERDR_ENV=1" spawn-one implementor
check "4.3h: pane label for a codex member says codex, not claude" \
  '[ "$RC" -eq 0 ] && [ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      const rn=rows.find(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"rename\");
      console.log(rn && rn.argv[3]===\"codex\" ? 1 : 0)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'

########################################################################
# §4.4 — LIVENESS  (two of the three must-pass cases live here)
########################################################################
setup_live_codex() { # <get-json> <get-exit>
  reset_state; clear_hierarchy; init_geometry; init_roster
  r "" add --no-spawn --role implementor --kind codex --route pane >/dev/null 2>&1
}

for st in idle working blocked done unknown; do
  setup_live_codex
  r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\",\"agent_status\":\"$st\"}}}'" spawn-one implementor
  check "4.4a[$st]: agent_status $st -> member reads LIVE, spawn-one refuses as already live" \
    '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already live"'
done

# not-live: exit 1 with agent_not_found, written to STDOUT (never stderr)
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_EXIT=1 FAKE_HERDR_GET_JSON='{\"error\":{\"code\":\"agent_not_found\",\"message\":\"no such agent\"}}'" spawn-one implementor
check "4.4b: agent_not_found on STDOUT with exit 1 -> not live, so the spawn proceeds" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.spawned")" = "true" ]'

# ---- MUST-PASS (§7): indeterminate is not "not live" -----------------------
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_EXIT=1 FAKE_HERDR_GET_JSON='{\"error\":{\"code\":\"daemon_unreachable\",\"message\":\"connection refused\"}}'" spawn-one implementor
check "4.4c: MUST-PASS — an unrecognised error code is INDETERMINATE: spawn-one refuses" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "cannot determine whether"'
check "4.4c2: MUST-PASS — ...and does NOT launch a replacement (no duplicate agent)" \
  '[ ! -f "$FAKE_STATE_DIR/last-start.json" ]'
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_EXIT=1 FAKE_HERDR_GET_JSON='not json at all {{{'" spawn-one implementor
check "4.4d: MUST-PASS — unparseable herdr output is INDETERMINATE, not not-live" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "cannot determine whether" && [ ! -f "$FAKE_STATE_DIR/last-start.json" ]'
# fix-round: an agent_status this build does not recognise, and a payload with none at all, are
# both the §1.6 "anything else" row — indeterminate, never a definite not-live. Reading either as
# dead is the duplicate-spawn bug the three-valued answer exists to prevent.
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"quiescing\"}}}'" spawn-one implementor
check "4.4c3: an UNRECOGNISED agent_status is INDETERMINATE: spawn-one refuses" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "cannot determine whether"'
check "4.4c4: ...and does NOT launch a replacement" \
  '[ ! -f "$FAKE_STATE_DIR/last-start.json" ]'
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\"}}}'" spawn-one implementor
check "4.4c5: a payload with NO agent_status is INDETERMINATE, not not-live" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "cannot determine whether" && [ ! -f "$FAKE_STATE_DIR/last-start.json" ]'

# herdr binary absent entirely
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane >/dev/null 2>&1
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$SANDBOX/bin-claude-only:$NODE_DIR" FAKE_STATE_DIR="$FAKE_STATE_DIR" CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one implementor --cwd "$PROJ" 2>&1); RC=$?
check "4.4e: MUST-PASS — herdr absent from PATH is INDETERMINATE, not not-live" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qE "cannot determine whether|no .herdr. binary"'

# a non-claude payload has no agent_session key — must parse fine
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\",\"agent_status\":\"idle\",\"pane_id\":\"p1\"}}}'" spawn-one implementor
check "4.4f: a payload with NO agent_session key parses (that key is never required)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already live"'

# readiness vs liveness
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"done\",\"interactive_ready\":true}}}'" spawn-one implementor
check "4.4g: agent_status done + interactive_ready true -> live AND ready" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already live" && [ "$(jo "o.ready")" = "true" ]'
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"blocked\",\"launch_pending\":true}}}'" spawn-one implementor
check "4.4h: agent_status blocked -> LIVE (refuses to start a second agent)" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already live"'
check "4.4h2: ...but NOT ready (not promptable)" \
  '[ "$(jo "o.ready")" = "false" ]'
check "4.4h3: ...and no second agent was started" '[ ! -f "$FAKE_STATE_DIR/last-start.json" ]'

# ---- MUST-PASS (§7): absent interactive_ready falls back, is not read as false
setup_live_codex
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"idle\"}}}'" spawn-one implementor
check "4.4i: MUST-PASS — absent interactive_ready falls back to agent_status: idle reads READY" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.ready")" = "true" ]'

# a kind:codex member with NO peers.jsonl record but a live herdr agent —
# the exact duplicate-spawn failure §1.6 exists to prevent
setup_live_codex
check "4.4j: precondition — no peers.jsonl record exists for the codex member" \
  '! grep -q "myrepo-implementor" "$PROJ/.claude/hierarchy/peers.jsonl" 2>/dev/null'
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"idle\"}}}'" spawn-one implementor
check "4.4k: codex member live in herdr but absent from peers.jsonl -> refused as already live" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already live" && [ ! -f "$FAKE_STATE_DIR/last-start.json" ]'

# the claude path is unaffected by herdr agent get
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role architect --model opus
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"agent_status\":\"idle\"}}}'" spawn-one architect
check "4.4l: a kind:claude member's liveness still comes from peers.jsonl, NOT herdr agent get" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.spawned")" = "true" ]'
check "4.4l2: ...and no `herdr agent get` was issued for it at all" \
  '[ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      let rows=[];try{rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")))}catch{}
      console.log(rows.filter(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"get\").length)
    " "$FAKE_STATE_DIR/calls")" -eq 0 ]'

########################################################################
# §4.6 — BLOCKED AT STARTUP
########################################################################
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane
r "HERDR_ENV=1 FAKE_HERDR_START_MODE=not-ready" spawn-one implementor
check "4.6a: agent_not_ready -> the distinct blocked outcome, NOT failed" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.launch_status")" = "blocked-at-startup" ]'
check "4.6b: ...the spawn is reported as succeeded (live, action outstanding)" \
  '[ "$(jo "o.spawned")" = "true" ]'
check "4.6c: ...the message names agent read and send-keys as the remedy" \
  'echo "$OUT" | grep -q "herdr agent read" && echo "$OUT" | grep -q "herdr agent send-keys"'
check "4.6d: ...launchMember's herdr retry did NOT fire (exactly one agent start)" \
  '[ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      console.log(rows.filter(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"start\").length)
    " "$FAKE_STATE_DIR/calls")" -eq 1 ]'
check "4.6e: ...the pane was NOT closed" \
  '[ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      console.log(rows.filter(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"close\").length)
    " "$FAKE_STATE_DIR/calls")" -eq 0 ]'
# §6's refusal: spawn must never answer an onboarding prompt on the user's behalf
check "4.6f: ...and NOTHING sent keystrokes to the blocked agent (§6 refusal)" \
  '[ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      console.log(rows.filter(c=>c.argv[0]===\"agent\"&&c.argv[1]===\"send-keys\").length)
    " "$FAKE_STATE_DIR/calls")" -eq 0 ]'
check "4.6f2: ...and roster.mjs contains no herdr send-keys EXECUTION at all (only remedy text)" \
  '[ "$(grep -c "herdrCall(\\[\"agent\", \"send-keys\"" "$H/roster.mjs")" -eq 0 ]' 

# Spec 0044 §1.10: `add` cannot hit a startup at all any more, so the blocked-startup case moves
# to `spawn-one` — the launch path that can actually reach it.
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane
r "HERDR_ENV=1 FAKE_HERDR_START_MODE=not-ready" spawn-one implementor
check "4.6g: spawn-one hitting a blocked startup reports success-with-action-outstanding, not a failure" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.spawned")" = "true" ] && [ "$(jo "o.launch_status")" = "blocked-at-startup" ]'

########################################################################
# §4.5 — PASSTHROUGH QUOTING  (the third must-pass case)
########################################################################
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"--flag\",\"value\"]"'
r "HERDR_ENV=1" spawn-one implementor
check "4.5a: the stub receives exactly two arguments after --, with those values" \
  '[ "$RC" -eq 0 ] && [ "$(node -e "
      const p=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).passthrough;
      console.log(JSON.stringify(p)===JSON.stringify([\"--flag\",\"value\"])?1:0)
    " "$FAKE_STATE_DIR/last-start.json")" -eq 1 ]'

# ---- MUST-PASS (§7): shell injection ---------------------------------------
rm -f "$PWNED"
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args "'[\"; touch $PWNED\"]'"
r "HERDR_ENV=1" spawn-one implementor
check "4.5b: MUST-PASS — a \`;\` args element does NOT execute (no file created)" \
  '[ ! -f "$PWNED" ]'
check "4.5b2: MUST-PASS — ...and arrives as ONE literal argument" \
  '[ "$(node -e "
      const p=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).passthrough;
      console.log(p.length===1 && p[0]===process.argv[2] ? 1 : 0)
    " "$FAKE_STATE_DIR/last-start.json" "; touch $PWNED")" -eq 1 ]'

rm -f "$PWNED"
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args "'[\"\$(touch $PWNED)\"]'"
r "HERDR_ENV=1" spawn-one implementor
check "4.5c: MUST-PASS — a \$(...) args element does NOT execute" '[ ! -f "$PWNED" ]'
check "4.5c2: MUST-PASS — ...and arrives as one literal argument" \
  '[ "$(node -e "
      const p=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).passthrough;
      console.log(p.length===1 && p[0]===process.argv[2] ? 1 : 0)
    " "$FAKE_STATE_DIR/last-start.json" "\$(touch $PWNED)")" -eq 1 ]'

rm -f "$PWNED"
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args "'[\"\`touch $PWNED\`\"]'"
r "HERDR_ENV=1" spawn-one implementor
check "4.5d: MUST-PASS — a backtick args element does NOT execute" '[ ! -f "$PWNED" ]'
check "4.5d2: MUST-PASS — ...and arrives as one literal argument" \
  '[ "$(node -e "
      const p=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).passthrough;
      console.log(p.length===1 && p[0]===process.argv[2] ? 1 : 0)
    " "$FAKE_STATE_DIR/last-start.json" "\`touch $PWNED\`")" -eq 1 ]'

# a single quote in an element must survive the quoting scheme itself
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"it'"'"'s\"]"'
r "HERDR_ENV=1" spawn-one implementor
check "4.5e: an element containing a single quote arrives intact" \
  '[ "$(node -e "
      const p=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).passthrough;
      console.log(p.length===1 && p[0]===\"it'"'"'s\" ? 1 : 0)
    " "$FAKE_STATE_DIR/last-start.json")" -eq 1 ]'

# --dry-run prints the quoted form actually executed
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"--a b\",\"c\"]"'
r "HERDR_ENV=1" spawn-one implementor --dry-run
check "4.5f: --dry-run prints the QUOTED form, not a bare space-join" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -qF "'"'"'--a b'"'"' '"'"'c'"'"'"'

# timeout: blame args when present, report the orphaned pane, never close it
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args '"[\"--help\"]"'
r "HERDR_ENV=1 FAKE_HERDR_START_MODE=timeout" spawn-one implementor
check "4.5g: a timeout WITH args names the args as the likely cause and prints them" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "likely_cause\|most likely made" && echo "$OUT" | grep -q -- "--help"'
check "4.5h: ...reports the orphaned transport_id with herdr pane close as the remedy" \
  'echo "$OUT" | grep -q "herdr pane close"'
check "4.5i: ...and does NOT close the pane itself" \
  '[ "$(node -e "
      const fs=require(\"fs\");const dir=process.argv[1];
      const rows=fs.readdirSync(dir).map(f=>JSON.parse(fs.readFileSync(dir+\"/\"+f,\"utf8\")));
      console.log(rows.filter(c=>c.argv[0]===\"pane\"&&c.argv[1]===\"close\").length)
    " "$FAKE_STATE_DIR/calls")" -eq 0 ]'

reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane
r "HERDR_ENV=1 FAKE_HERDR_START_MODE=timeout" spawn-one implementor
check "4.5j: a timeout with NO args does not blame args" \
  '[ "$RC" -ne 0 ] && ! echo "$OUT" | grep -q "likely_cause"'
check "4.5j2: ...but still reports the orphaned pane" 'echo "$OUT" | grep -q "herdr pane close"'

########################################################################
# fix-round: block-level route inheritance, and converting a member's kind
########################################################################
# §1.3: a member with no route of its own inherits the roster block's. spawn-one used to read
# only member.route and default to "peer", so a codex member under `init --route pane` was
# misrouted at the one place that decides what gets recorded.
reset_state; clear_hierarchy; init_geometry
r "" init --level repo --route pane
r "" add --no-spawn --role implementor --kind codex
r "HERDR_ENV=1" spawn-one implementor
check "F2a: a member inheriting route pane from the roster block spawns" '[ "$RC" -eq 0 ]'
check "F2b: ...and is recorded as route pane, not peer"   '[ "$(jo "o.member.route")" = "pane" ]'

# §1.3: `add` fills model from ROLE_DEFAULTS for a claude member, and model is rejected for any
# other kind — so without clearing it, converting an existing member's kind was impossible.
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --model sonnet
r "" edit --member myrepo-implementor --kind codex --route pane
check "F6a: edit --kind off claude succeeds on a member carrying a model" '[ "$RC" -eq 0 ]'
check "F6b: ...and drops the claude-only model key"   '[ "$(jo "o.member.model")" = "undefined" ] && [ "$(jo "o.member.kind")" = "codex" ]'
check "F6c: ...and says so on stderr rather than silently"   'grep -q "cleared model" "$STDERR_F"'
r "" edit --member myrepo-implementor --kind pi --model opus
check "F6d: --model together with a non-claude --kind is a contradiction, not a silent drop"   '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "cannot be combined with --kind"'

# N1: `[]` and absent are the same thing (§1.9), so an empty --args writes no key at all.
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args "'[]'"
check "FN1: add --args '[]' omits the key rather than storing null"   '[ "$RC" -eq 0 ] && ! grep -q "\"args\"" "$PROJ/.claude/agent-hierarchy.json"'

########################################################################
# fix-round 2: create --spawn must carry kind/args into its member rows
########################################################################
# `create --spawn` does not write team.json — the Orchestrator builds it from these rows
# (SKILL.md). A row missing `kind` becomes a team.json entry that resolves to claude, checks
# liveness against peers.jsonl forever, and lets the next spawn-one start a duplicate under a
# name Herdr requires to be unique. So: assert the field, THEN assert the failure mode is shut.
reset_state; clear_hierarchy; init_geometry; init_roster
r "" add --no-spawn --role implementor --kind codex --route pane --args "'[\"--profile\",\"fast\"]'"
r "HERDR_ENV=1" create --spawn --mode auto
check "F7a: create --spawn's codex row carries kind" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.members[0].kind")" = "codex" ]'
check "F7b: ...and carries args" \
  '[ "$(jo "JSON.stringify(o.members[0].args)")" = "[\"--profile\",\"fast\"]" ]'

# Stand in for the Orchestrator: build team.json from the row create --spawn just emitted, then
# ask the commands that read THAT record about it.
#
# NB: spawn-one is NOT the consumer that breaks. It resolves its member from the roster config
# (roster.mjs:1464/1468 pass the config member; only the NAME comes from team.json), so its
# liveness question already carries the right kind and it refuses a duplicate either way. The
# consumers that read team.json members directly are all three inside `dismiss` (roster.mjs:2289
# --commit, :2336 reordinal, :2374 bare/--plan) — so that is where a kind-less record does its
# damage, and where this is asserted.
node -e '
  const fs=require("fs");
  const row=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).members[0];
  const dir=process.argv[2];
  fs.mkdirSync(dir,{recursive:true});
  fs.writeFileSync(dir+"/team.json", JSON.stringify({
    version:1, team_id:"t-fix7", created:new Date().toISOString(), roster_level:"repo",
    transport:"herdr", orchestrator:{session_id:null,pid:process.ppid}, partial:false,
    expected_root:process.argv[3],
    members:[{role:row.role,name:row.name,route:row.route,kind:row.kind,args:row.args,transport_id:row.transport_id}],
  },null,2));
' "$STDOUT_F" "$PROJ/.claude/hierarchy" "$(cd "$PROJ" && pwd -P)"

r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\",\"agent_status\":\"idle\"}}}'" dismiss myrepo-implementor
check "F7c: dismiss reads the record's kind and sees the running codex agent as LIVE" \
  '[ "$RC" -eq 0 ] && [ "$(jo "o.live")" = "true" ]'

# and the same record, committed while that agent is still running, must not go out silently
# Spec 0046 §2.1/§2.3: the tracking-only removal is `untrack`, and forgetting a LIVE record is
# the explicit --keep-sessions opt-in. The kind-aware liveness read is what makes that opt-in
# required here, so this still exercises F7c's codex path.
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\",\"agent_status\":\"idle\"}}}'" untrack myrepo-implementor --commit
check "F7d: untrack --commit on a live codex member refuses without --keep-sessions" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q -- "--keep-sessions"'
r "HERDR_ENV=1 FAKE_HERDR_GET_JSON='{\"result\":{\"agent\":{\"name\":\"myrepo-implementor\",\"agent_status\":\"idle\"}}}'" untrack myrepo-implementor --commit --keep-sessions
check "F7d2: with --keep-sessions it untracks and warns rather than silently dropping it" \
  '[ "$RC" -eq 0 ] && grep -q "is still live" "$STDERR_F"'

# F7 hand-builds a team.json in $PROJ; the regression suites below run in the same environment,
# so clear it rather than leaving them to inherit it.
reset_state; clear_hierarchy

########################################################################
# regression: the suites sharing spawnShape/launchMember/validateMember
########################################################################
for t in test-roster-create-spawn.sh test-roster-spawn-one.sh test-roster.sh test-roster-cli.sh test-herdr-pane-label.sh test-route-gate.sh; do
  bash "$PLUGIN/tests/$t" >/dev/null 2>&1; RC=$?
  check "regression: $t passes unmodified" '[ "$RC" -eq 0 ]'
done

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
