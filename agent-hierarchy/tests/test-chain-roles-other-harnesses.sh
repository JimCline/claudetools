#!/bin/bash
# agent-hierarchy — chain roles running in another harness (Codex) through Herdr: validation, the
# launch line, standing instructions, `deliver`, `answer`, declared tiers, the startup-screen and
# trust checks, and the gates that keep a raw brief or a stray key out of such a member's pane.
# HOME-redirected, with a scripted fake herdr: nothing reaches a real herdr, codex, gate state or
# config. Usage: bash tests/test-chain-roles-other-harnesses.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-other-harness-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach a real herdr, tmux or codex: stubs that fail every call sit first on PATH.
mkdir -p "$SANDBOX/nolaunch"
for b in herdr tmux codex; do printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/$b"; chmod +x "$SANDBOX/nolaunch/$b"; done
export PATH="$SANDBOX/nolaunch:$PATH"
unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE CODEX_HOME CLAUDE_CODE_SESSION_ID AGENT_HIERARCHY_DIR AH_HERDR_READY_WAIT_MS
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
HIER="$PROJ/.claude/hierarchy"
CODEXHOME="$SANDBOX/codexhome"
SCREENS="$SANDBOX/screens"
FAKE_STATE_DIR="$SANDBOX/state"
CFG="$PROJ/.claude/agent-hierarchy.json"
GLOBAL="$FAKEHOME/.claude/agent-hierarchy.json"
HOOK_LOG="$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"
THROWS="$PLUGIN/tests/fixtures/resolve-config-throws.mjs"
mkdir -p "$FAKEHOME/.claude/plugins" "$PROJ/.claude" "$SANDBOX/bin" "$CODEXHOME" "$SCREENS"
(cd "$PROJ" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
# A non-claude member's standing instructions carry its role's agent body, found through
# installed_plugins.json as role validation finds it; this plugin is the one installed.
echo "{\"version\":2,\"plugins\":{\"ah@local\":[{\"installPath\":\"$PLUGIN\"}]}}" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
NODE_DIR="$(dirname "$(command -v node)")"
PASS=0; FAIL=0; RC=0; OUT=""

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:700})"; fi
}

# ---- screens, as Codex draws them (E8's exec approval is verbatim) ----------------------------
cat > "$SCREENS/approval.txt" <<'EOF'


  Would you like to run the following command?

  Environment: local

  Reason: The sandbox blocked the command. Approve running this exact touch command outside the sandbox?

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `touch /tmp/x` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
EOF
# the same approval on a narrow pane: "(esc)" wraps onto its own line
cat > "$SCREENS/approval-narrow.txt" <<'EOF'


  Would you like to run the following command?

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that
     start with `touch /tmp/x` (p)
  3. No, and tell Codex what to do differently
     (esc)

  Press enter to confirm or esc to cancel
EOF
sed -e 's/1\. Yes, proceed (y)/1. Yes, just this once (y)/' "$SCREENS/approval.txt" > "$SCREENS/approval-other-first.txt"
# every option label is one approval draws, but option 1 is not "Yes, proceed"
cat > "$SCREENS/approval-reordered.txt" <<'EOF'

  Would you like to run the following command?

› 1. No, and tell Codex what to do differently (esc)
  2. Yes, proceed (y)

  Press enter to confirm or esc to cancel
EOF
sed -e 's/differently (esc)/differently (d)/' "$SCREENS/approval.txt" > "$SCREENS/approval-remapped.txt"
cat > "$SCREENS/trust.txt" <<'EOF'
> You are in /some/where

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
cat > "$SCREENS/login.txt" <<'EOF'
  Welcome to Codex, OpenAI's command-line coding agent

  Sign in with ChatGPT to use Codex as part of your paid plan
  or connect an API key for usage-based billing

> 1. Sign in with ChatGPT
     Usage included with Plus, Pro, Business, and Enterprise plans

  2. Sign in with Device Code
     Sign in from another device with a one-time code

  3. Provide your own API key
     Pay for what you use

  Press enter to continue
EOF
printf '\n› Ask Codex to do anything\n\n  gpt-6-astra high · ~/myrepo\n' > "$SCREENS/composer.txt"
# Verbatim `herdr agent read --source visible` captures of codex-cli 0.154.0-alpha.6.2 in a 52-column
# pane: an exec approval, the login screen, the idle composer twice 4 s apart and once after a turn,
# the composer with "hi" typed, and "Hooks need review".
cp "$PLUGIN/tests/fixtures/0062-screens/"*.txt "$SCREENS/"
derive() { # <from> <to> <JS expression over the screen text s>
  node -e 'const fs=require("fs");let s=fs.readFileSync(process.argv[1],"utf8");fs.writeFileSync(process.argv[2],eval(process.argv[3]))' "$SCREENS/$1.txt" "$SCREENS/$2.txt" "$3"
}
derive composer-e12a composer-plain 's.replace(/[⠀-⣿]/g," ")'
derive composer-e12a composer-guillemet 's.replace("› Ask Codex","» Ask Codex")'
derive composer-e12a composer-followup 's.replace("Ask Codex to do anything","Ask a follow-up question")'
derive composer-e12a composer-transcript 's.replace("  Tip: Try","  Sign in with ChatGPT\n  Do you trust the contents of this directory?\n› Ask Codex to do anything\n\n  Tip: Try")'
derive composer-e12a composer-2footer 's.replace(/\n*$/,"\n  40% context left\n")'
derive composer-e12a composer-padding 's.replace(/(› Ask Codex to do anything[^\n]*\n)[^\n]*\n/,"$1  queued: run the tests\n")'
: > "$SCREENS/blank.txt"
# From Codex's source at the same tag: the update prompt and model migration
cat > "$SCREENS/update-prompt.txt" <<'EOF'
  ✨ Update available! 0.154.0-alpha.6.2 -> 0.155.0

  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version

  Press enter to continue
EOF
cat > "$SCREENS/model-migration.txt" <<'EOF'
> Codex just got an upgrade. Introducing gpt-7.

  A faster model for everyday coding.

› 1. Try new model
  2. Use existing model

  Use ↑/↓ to move, press enter to confirm
EOF
# the trust dialog as its source draws it, at 52 columns
cat > "$SCREENS/trust-52.txt" <<'EOF'
> You are in /Users/someone/myrepo

  Do you trust the contents of this directory?
Working with untrusted contents comes with higher
risk of prompt injection.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
cat > "$SCREENS/trust-swapped.txt" <<'EOF'
> You are in /Users/someone/myrepo

  Do you trust the contents of this directory?

› 1. No, quit
  2. Yes, continue

  Press enter to continue
EOF
# inside option 2's free command-prefix slot, so only the column-0 rule can reject it
derive approval-e8 approval-col0 's.replace(/(ev-codex-\n)/,"$1stray at column 0\n")'
derive approval-e8 approval-echo 's.replace(/(  2\. Yes, and don.t ask again for commands that\n)[\s\S]*?\(p\)\n/,"$1     start with `echo\n     › 1. Yes, continue\n     2. No, quit\n     Press enter to continue` (p)\n")'
derive approval-e8 approval-4sp 's.replace("     e8/a.txt","    e8/a.txt")'
derive login-e8 login-col0-blank 's.replace("Enterprise plans\n\n","Enterprise plans\n\nstray\n")'
derive approval-e8 approval-noblank1 's.replace("view all\n\n›","view all\n›")'
derive approval-e8 approval-wrapfooter 's.replace("  Press enter to confirm or esc to cancel","  Press enter to confirm or esc to\ncancel")'
derive approval-e8 approval-extra 's.replace("     (esc)\n\n","     (esc)\n\n  note\n\n")'
derive approval-e8 approval-otherfooter 's.replace("or esc to cancel","or esc to go back")'
derive approval-e8 approval-trailing 's.replace(/\n*$/,"\n  trailing\n")'
derive approval-e8 approval-twomarks 's.replace("  2. Yes, and","› 2. Yes, and")'
derive approval-e8 approval-otherhead 's.replace("  Environment: local","  Environment: local\n  Sign in with ChatGPT")'
derive approval-e8 approval-editshead 's.replace("  Environment: local","  Environment: local\n  Would you like to make the following edits?")'
# the member's own command echoing the trust dialog, in the header of a real approval
derive approval-e8 approval-probe 's.replace("  [… 9 lines] ctrl + a view all","  $ echo Do you trust the contents of this directory\n  › 1. Yes, continue\n    2. No, quit\n  Press enter to continue")' 
for h in "Would you like to make the following edits?" "Would you like to grant these permissions?" 'Do you want to approve network access to "example.com"?' "Would you like to send input to the existing terminal?" "docs needs your approval."; do
  n=$((${n:-0}+1)); printf '\n  %s\n\n› 1. Yes\n  2. No\n' "$h" > "$SCREENS/other-$n.txt"
done

# ---- fake herdr: scripted per agent from $FAKE_STATE_DIR/herdr.json, every call logged in order --
cat > "$SANDBOX/bin/herdr" <<EOF
#!$(command -v node)
$(cat <<'FAKEEOF'
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const dir = process.env.FAKE_STATE_DIR;
fs.mkdirSync(dir, { recursive: true });
fs.appendFileSync(path.join(dir, "calls.jsonl"), JSON.stringify(args) + "\n");
const stateFile = path.join(dir, "herdr.json");
const st = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : {};
st.agents = st.agents || {};
const save = () => fs.writeFileSync(stateFile, JSON.stringify(st));
const done = (code, out) => {
  if (out !== undefined) process.stdout.write(typeof out === "string" ? out : JSON.stringify(out) + "\n");
  save();
  process.exit(code);
};
const text = (v) => (typeof v === "string" && v.startsWith("@") ? fs.readFileSync(path.join(process.env.FAKE_SCREENS, v.slice(1) + ".txt"), "utf8") : v || "");
const next = (a, key) => {
  const q = a[key];
  if (!Array.isArray(q)) return q;
  return q.length > 1 ? q.shift() : q[0];
};
const notFound = (verb) => done(1, { error: { code: "agent_not_found", message: "agent target not found" }, id: `cli:agent:${verb}` });
if (args[0] === "pane" && args[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(path.join(dir, "geometry.json"), "utf8"));
  const panes = Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect }));
  done(0, { result: { layout: { area: s.area, focused_pane_id: s.self, panes, splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } });
}
if (args[0] === "pane" && args[1] === "split") {
  const geomFile = path.join(dir, "geometry.json");
  const s = JSON.parse(fs.readFileSync(geomFile, "utf8"));
  const target = args[args.indexOf("--pane") + 1];
  const rect = s.panes[target];
  const id = `p${s.nextId++}`;
  const w1 = Math.floor(rect.width / 2);
  s.panes[target] = { ...rect, width: w1 };
  s.panes[id] = { ...rect, width: rect.width - w1, x: rect.x + w1 };
  fs.writeFileSync(geomFile, JSON.stringify(s));
  done(0, { result: { pane: { pane_id: id } } });
}
if (args[0] === "pane") done(0, { result: { type: "ok" } });
if (args[0] === "agent") {
  const verb = args[1];
  const name = args[2];
  if (verb === "start") {
    const dd = args.indexOf("--");
    fs.writeFileSync(path.join(dir, "last-start.json"), JSON.stringify({ argv: args, passthrough: dd === -1 ? [] : args.slice(dd + 1) }));
    const mode = Array.isArray(st.start) ? (st.start.length > 1 ? st.start.shift() : st.start[0]) : st.start;
    if (mode === "name-taken") done(1, { error: { code: "agent_name_taken", message: `agent name ${name} is already used by w9:p9 (idle)` } });
    st.agents[name] = st.afterStart || { gets: [{ agent_status: "idle", interactive_ready: true }], visible: "@composer" };
    if (mode === "timeout-registered") done(1, { error: { code: "timeout", message: "agent never became ready" } });
    done(0, { result: { pane: { pane_id: "target" }, agent: { name, agent_status: "idle", interactive_ready: true } } });
  }
  const a = st.agents[name];
  if (!a) notFound(verb);
  if (verb === "get") {
    const g = next(a, "gets");
    if (g === "notfound") notFound("get");
    if (g === "error") done(1, { error: { code: "server_unavailable", message: "no" } });
    done(0, { result: { agent: { name, ...g } } });
  }
  if (verb === "read") {
    if (a.gone) notFound("read");
    const src = args[args.indexOf("--source") + 1];
    done(0, src === "visible" ? text(next(a, "visible")) : text(a.recent));
  }
  if (verb === "prompt") {
    fs.appendFileSync(path.join(dir, "prompts.jsonl"), JSON.stringify({ name, text: args[3], argv: args }) + "\n");
    const w = a.onPrompt;
    if (w && w.append) fs.appendFileSync(w.append, w.text);
    if (w && w.replace) fs.writeFileSync(w.replace, fs.readFileSync(w.replace, "utf8").replace(w.from, w.to));
    const r = a.prompt || { exit: 0, json: { result: { agent: { name, agent_status: "done" } }, type: "agent_prompted" } };
    done(r.exit, r.json);
  }
  if (verb === "wait") {
    const r = a.wait || { exit: 0, json: { result: { agent: { name, agent_status: "done" } } } };
    done(r.exit, r.json);
  }
  if (verb === "send-keys") {
    if (a.afterKeys) {
      Object.assign(a, a.afterKeys);
      delete a.afterKeys;
    }
    done(0, { result: { type: "ok" } });
  }
}
done(1, { error: { code: "unhandled", message: JSON.stringify(args) } });
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

# ---- helpers -----------------------------------------------------------------------------------
reset_state() {
  rm -rf "$FAKE_STATE_DIR"; mkdir -p "$FAKE_STATE_DIR"
  echo '{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}' > "$FAKE_STATE_DIR/geometry.json"
}
hs() { # <JS object literal>: the fake herdr's script
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify(eval("(" + process.argv[2] + ")")))' "$FAKE_STATE_DIR/herdr.json" "$1"
}
calls() { # <agent verb> -> how many times the fake herdr saw `herdr agent <verb>` (or `pane close` for "pane-close")
  node -e 'const rows=require("fs").existsSync(process.argv[1])?require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse):[];const v=process.argv[2];console.log(rows.filter(a=>v==="pane-close"?a[0]==="pane"&&a[1]==="close":a[0]==="agent"&&a[1]===v).length)' "$FAKE_STATE_DIR/calls.jsonl" "$1"
}
keys_sent() { # -> the keys every send-keys carried, in order, as JSON
  node -e 'const f=process.argv[1];const rows=require("fs").existsSync(f)?require("fs").readFileSync(f,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse):[];console.log(JSON.stringify(rows.filter(a=>a[0]==="agent"&&a[1]==="send-keys").map(a=>a.slice(3)).flat()))' "$FAKE_STATE_DIR/calls.jsonl"
}
STDOUT_F="$SANDBOX/out.json"; STDERR_F="$SANDBOX/err.txt"
r() { # <extra env> <roster.mjs args...>   (cwd $PROJ unless --cwd is given)
  local extra=$1; shift
  local cwdarg="--cwd $PROJ"; case " $* " in *" --cwd "*) cwdarg="";; esac
  eval "env -u HERDR_ENV HOME=\"$FAKEHOME\" HERDR_PANE_ID=p0 PATH=\"$SANDBOX/bin:$NODE_DIR\" FAKE_STATE_DIR=\"$FAKE_STATE_DIR\" FAKE_SCREENS=\"$SCREENS\" CODEX_HOME=\"$CODEXHOME\" CLAUDE_PID=$$ AH_COMPOSER_REREAD_MS=0 AH_DELIVER_POLL_MS=20 $extra node \"$H/roster.mjs\" $* $cwdarg >\"$STDOUT_F\" 2>\"$STDERR_F\""; RC=$?
  OUT="$(cat "$STDOUT_F" "$STDERR_F")"
}
jo() { node -e 'let o;try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{console.log("ERR");process.exit(0)}try{const v=eval(process.argv[2]);console.log(typeof v==="object"?JSON.stringify(v):v)}catch(e){console.log("ERR")}' "$STDOUT_F" "$1"; }
lib() { HOME="$FAKEHOME" node --input-type=module -e "const R=await import('$H/lib-roster.mjs');const C=await import('$H/lib-config.mjs');const out=await (async()=>{ $1 })();console.log(typeof out==='object'?JSON.stringify(out):out)"; }
screen_hash() { HOME="$FAKEHOME" node --input-type=module -e "const R=await import('$H/lib-roster.mjs');const fs=await import('node:fs');console.log(R.screenHash(fs.readFileSync('$SCREENS/$1.txt','utf8')))"; }
roster_cfg() { # <members JSON array>: the repo roster, route pane
  printf '{"version":1,"enabled":true,"roles":{},"roster":{"route":"pane","members":%s}}\n' "$1" > "$CFG"
}
team_file() { # <members JSON array> [team name]: a live team owned by this test shell
  mkdir -p "$HIER/teams"
  node -e 'const [t,m,pid,root]=process.argv.slice(1);require("fs").writeFileSync(t,JSON.stringify({version:1,team_id:"20260101-000000-abcd",created:"2026-01-01T00:00:00+00:00",roster_level:"repo",transport:"herdr",orchestrator:{session_id:null,pid:Number(pid)},members:JSON.parse(m),expected_root:root,roster:null,layout:"auto"},null,2))' "$HIER/teams/${2:-myrepo}.json" "$1" "$$" "$PROJ"
}
CODEX_ARCH='{"role":"architect","name":"myrepo-architect","kind":"codex","route":"pane","model":"gpt-6-astra","transport_id":"p1"}'
CODEX_UA='{"role":"ultra-advisor","name":"myrepo-ultra-advisor","kind":"codex","route":"pane","model":"gpt-6-astra","transport_id":"p2"}'
CLAUDE_REV='{"role":"reviewer","name":"myrepo-reviewer","route":"peer","model":"opus","transport_id":"p3"}'
CLAUDE_UA2='{"role":"ultra-advisor","name":"myrepo-ultra-advisor-2","route":"peer","model":"fable","transport_id":"p4"}'
mkreq() { # <slug> [to-role] [to-name] -> REQ, RESP
  REQ=$(HOME="$FAKEHOME" CLAUDE_PID=$$ node "$H/msg.mjs" new --to "${2:-architect}" --from orchestrator --slug "$1" --to-name "${3:-myrepo-architect}" --cwd "$PROJ" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).path))')
  RESP=$(node --input-type=module -e "const L=await import('$H/lib-hier.mjs');console.log(L.responsePlan('$REQ').path)")
}
IDLE='{agent_status:"idle",interactive_ready:true}'
setup_deliver() { # the codex architect, idle and ready at its composer
  rm -rf "$HIER"; reset_state
  roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"},{"role":"ultra-advisor","kind":"codex","route":"pane","model":"gpt-6-astra"}]'
  team_file "[$CODEX_ARCH,$CODEX_UA,$CLAUDE_REV]"
  mkreq "t$((++REQN))"
}
REQN=0

########################################################################
# K1 / K14 — validation
########################################################################
rm -f "$CFG"; reset_state
r "" init --level repo --route pane
r "" add --role architect --kind codex --model gpt-6-astra
check "K1: codex with model gpt-6-astra passes" '[ "$RC" -eq 0 ] && [ "$(jo o.member.model)" = gpt-6-astra ]'
r "" add --role implementor --kind codex --model gpt-6-astra --args "'[\"-m\",\"other\"]'"
check "K1: model plus the mapped flag in args (-m) is a hard error" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "one channel per setting"'
r "" add --role implementor --kind codex --model gpt-6-astra --args "'[\"-c\",\"model=\\\"other\\\"\"]'"
check "K1: ...and so is -c model=… in args" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "one channel per setting"'
r "" add --role implementor --kind codex --model gpt-6-astra --args "'[\"-c\",\"model_instructions_file=\\\"x\\\"\"]'"
check "K1: ...but a config key that only starts with model is not the model flag" '[ "$RC" -eq 0 ]'
r "" add --role reviewer --kind pi --model some-model
check "K1: a kind with no mapping plus model is a hard error naming args" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "in args"'
r "" add --role ultra-advisor --kind codex --model gpt-6-astra --args "'[\"--profile\",\"x\"]'"
check "K1: a codex advise-class member with args is a hard error" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "advise-class"'
r "" add --role ultra-advisor --kind codex --model gpt-6-astra
check "K1: a codex advise-class member on an undeclared model is added, with a tier warning" '[ "$RC" -eq 0 ] && grep -q "warning — codex model gpt-6-astra has no declared tier" "$STDERR_F"'
r "" add --role reviewer --kind codex --model gpt-6-astra --effort high
check "K1: effort on codex is still a hard error" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "effort is a Claude Code CLI flag"'
r "" add --role reviewer --kind codex --model gpt-6-astra --auto-mode plan
check "K1: codex auto-mode plan gives the read-only-sandbox warning" '[ "$RC" -eq 0 ] && grep -q "read-only sandbox" "$STDERR_F"'
r "" add --role reviewer --kind codex --model gpt-6-astra --auto-mode acceptEdits
check "K1: ...and a writable auto-mode does not" '[ "$RC" -eq 0 ] && ! grep -q "read-only sandbox" "$STDERR_F"'
r "" add --role reviewer --kind codex --model "'gpt 6'"
check "K1: a codex model with whitespace is refused (shape check)" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no whitespace"'
r "" add --role reviewer --kind codex --model gpt-6-astra --args "'[\"-c\",\"approvals_reviewer=\\\"auto_review\\\"\"]'"
check "K14: approvals_reviewer in a codex member's args is a hard error" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "must not set approvals_reviewer"'
check "K14: no harness-auto-review refusal or --allow-auto-review flag exists" '! grep -q "harness-auto-review\|allow-auto-review" "$H/roster.mjs" "$H/lib-roster.mjs"'
check "K13: harness-login-required does not exist" '! grep -rq "harness-login-required" "$H"'

########################################################################
# K2 / K14 — the launch line
########################################################################
rm -rf "$HIER"; reset_state
roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra","autoMode":"acceptEdits","args":["--x"]},{"role":"reviewer","model":"opus"},{"role":"ultra-advisor","kind":"codex","route":"pane","model":"m-top"}]'
r "HERDR_ENV=1" spawn-one architect --dry-run
EXPECT_ARCH="herdr agent start myrepo-architect --kind codex --pane <TARGET> -- '--model' 'gpt-6-astra' '-c' 'model_instructions_file=\"$HIER/instructions/myrepo-architect.md\"' '-c' 'approvals_reviewer=\"user\"' '--sandbox' 'workspace-write' '--ask-for-approval' 'on-request' '--x'"
check "K2: codex argv is -- model, instructions file, approvals, then auto-mode, then args" '[ "$RC" -eq 0 ] && [ "$(jo "o.launch[0]")" = "$EXPECT_ARCH" ]'
r "HERDR_ENV=1 AGENT_HIERARCHY_DIR=$SANDBOX/elsewhere" spawn-one architect --dry-run
check "K2: with the message pool outside the cwd, --add-dir <pool> sits between the instructions and the approvals" '[ "$RC" -eq 0 ] && jo "o.launch[0]" | grep -qF "'"'"'model_instructions_file=\"$SANDBOX/elsewhere/instructions/myrepo-architect.md\"'"'"' '"'"'--add-dir'"'"' '"'"'$SANDBOX/elsewhere/msgs'"'"' '"'"'-c'"'"' '"'"'approvals_reviewer=\"user\"'"'"'"'
r "HERDR_ENV=1" spawn-one architect --dry-run
check "K2: ...and with the pool under the cwd there is no --add-dir" '! jo "o.launch[0]" | grep -q -- "--add-dir"'
r "HERDR_ENV=1" spawn-one reviewer --dry-run
check "K2: a claude member's argv is byte-identical to 0.91.0" '[ "$(jo "o.launch[0]")" = "herdr agent start myrepo-reviewer --kind claude --pane <TARGET> -- --agent ah:reviewer --name myrepo-reviewer --model opus --settings '"'"'{\"env\":{\"AH_TEAM_FILE\":\"$HIER/teams/myrepo.json\"}}'"'"'" ]'
roster_cfg '[{"role":"architect","kind":"codex","route":"pane"}]'
r "HERDR_ENV=1" spawn-one architect --model m-now --dry-run
check "K2: spawn-one --model on a model-less codex member launches it on that model, this time" '[ "$RC" -eq 0 ] && jo "o.launch[0]" | grep -qF -- "-- '"'"'--model'"'"' '"'"'m-now'"'"'" && ! grep -q m-now "$CFG"'
r "HERDR_ENV=1" create --plan --member-model myrepo-architect=m-now
check "K2: create --member-model <codex member>=<model> is accepted and planned" '[ "$RC" -eq 0 ] && [ "$(jo "\"members_needing_model\" in o")" = false ] && jo "o.members[0].spawn.launch[0]" | grep -qF "'"'"'m-now'"'"'"'
r "HERDR_ENV=1" spawn-ad-hoc reviewer --kind codex --route pane --model m-adhoc --dry-run
check "K2: spawn-ad-hoc --kind codex --model launches on that model" '[ "$RC" -eq 0 ] && jo "o.launch[0]" | grep -qF -- "-- '"'"'--model'"'"' '"'"'m-adhoc'"'"'"'
roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra","autoMode":"acceptEdits","args":["--x"]},{"role":"reviewer","model":"opus"},{"role":"ultra-advisor","kind":"codex","route":"pane","model":"m-top"}]'
echo '{"modelTiers":{"codex":{"m-top":"fable"}}}' > "$GLOBAL"
r "HERDR_ENV=1" spawn-one ultra-advisor --dry-run
check "K14: an advise-class codex member's argv carries the approvals override too" '[ "$RC" -eq 0 ] && jo "o.launch[0]" | grep -qF "'"'"'-c'"'"' '"'"'approvals_reviewer=\"user\"'"'"'"'
rm -f "$GLOBAL"

########################################################################
# K3 — the standing-instructions file
########################################################################
rm -rf "$HIER"; reset_state
mkdir -p "$PROJ/.claude/agents"
printf -- '---\nname: auditor\ndescription: audits\ntools: Read, Grep, Glob, SendMessage\n---\nAUDITOR-CONTRACT-MARKER: audit the change.\n' > "$PROJ/.claude/agents/auditor.md"
printf '{"version":1,"enabled":true,"roles":{"auditor":{"class":"review","agent":"auditor","label":"Auditor"}},"roster":{"route":"pane","members":[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"},{"role":"auditor","kind":"codex","route":"pane","model":"gpt-6-astra"}]}}\n' > "$CFG"
r "HERDR_ENV=1" spawn-one architect
INS="$HIER/instructions/myrepo-architect.md"
BODY_LINE=$(awk 'f==2 && NF {print; exit} /^---$/ {f++}' "$PLUGIN/agents/architect.md")
check "K3: spawn writes the instructions file" '[ "$RC" -eq 0 ] && [ -f "$INS" ]'
check "K3: ...with the identity lines" 'grep -qF -- "- Member name: myrepo-architect" "$INS" && grep -qF -- "- Team: myrepo" "$INS" && grep -qF -- "- Team file: $HIER/teams/myrepo.json" "$INS" && grep -qF -- "- Working directory: $PROJ" "$INS" && grep -qF "Your Orchestrator briefs you; you brief no one." "$INS"'
check "K3: ...the role's agent body without its frontmatter" 'grep -qF -- "$BODY_LINE" "$INS" && ! grep -q "^name: architect" "$INS" && [ "$(head -1 "$INS")" != "---" ]'
check "K3: ...and the adapter" 'grep -qF "**How a brief arrives.**" "$INS" && grep -qF "**Pings.**" "$INS" && grep -qF "There is no SendMessage, Agent tool, ListAgents" "$INS"'
r "HERDR_ENV=1" spawn-one auditor
check "K3: a custom role gets its own agent's body" '[ "$RC" -eq 0 ] && grep -q "AUDITOR-CONTRACT-MARKER" "$HIER/instructions/myrepo-auditor.md" && ! grep -qF -- "$BODY_LINE" "$HIER/instructions/myrepo-auditor.md"'
echo "STALE" > "$INS"
hs '{agents:{}}'
r "HERDR_ENV=1" spawn-one architect
check "K3: a respawn overwrites it" '[ "$RC" -eq 0 ] && ! grep -q STALE "$INS" && grep -qF -- "$BODY_LINE" "$INS"'
rm -rf "$PROJ/.claude/agents"

########################################################################
# K4 — deliver
########################################################################
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\",onPrompt:{append:\"$RESP\",text:\"- [done] the report\\n\"}}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K4: reported — the response file now holds a report" '[ "$RC" -eq 0 ] && [ "$(jo o.status)" = reported ] && [ "$(jo o.response)" = "$RESP" ] && [ "$(jo o.agent_status)" = done ]'
check "K4: the brief is exactly its three lines" '[ "$(node -e "const r=require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim().split(\"\\n\").map(JSON.parse);console.log(r[0].text)" "$FAKE_STATE_DIR/prompts.jsonl")" = "$(printf "[hierarchy-msg %s]\nReport to: %s\nStanding instructions: %s — read it first if you have not read it this session." "$REQ" "$RESP" "$HIER/instructions/myrepo-architect.md")" ]'
prompt_timeout() { node -e 'const r=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);const a=r[r.length-1].argv;const i=a.indexOf("--timeout");console.log(a[i-1]==="--wait"?a[i+1]:"none")' "$FAKE_STATE_DIR/prompts.jsonl"; }
check "K4: ...sent with --wait and what is left of the --timeout deadline, in ms" 'T=$(prompt_timeout); [ "$T" -le 1800000 ] && [ "$T" -gt 1790000 ]'
check "K4: ...and sent: true" '[ "$(jo o.sent)" = true ]'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\",recent:\"line1\\nthe 400 model is not supported\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K4: no-report — the turn ended and the file is unchanged, with a pane_tail" '[ "$(jo o.status)" = no-report ] && jo o.pane_tail | grep -q "model is not supported"'
RESP_BEFORE=$(cat "$RESP")
r "" deliver myrepo-architect --req "$REQ" --ping 1
check "K4: a ping reuses the response file (one file, unchanged)" '[ "$(ls "$(dirname "$RESP")" | grep -c "$(basename "$RESP")")" -eq 1 ] && [ "$(cat "$RESP")" = "$RESP_BEFORE" ]'
check "K4: the ping text is as specified" '[ "$(node -e "const r=require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim().split(\"\\n\").map(JSON.parse);console.log(r[r.length-1].text)" "$FAKE_STATE_DIR/prompts.jsonl")" = "Ping 1/3: you owe a report on task t$REQN — write it to $RESP, then end your turn." ]'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\",onPrompt:{replace:\"$RESP\",from:\"id: \",to:\"id: 1999\"}}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K4: malformed-report — the frontmatter no longer carries the request id" '[ "$(jo o.status)" = malformed-report ]'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[{agent_status:\"working\",interactive_ready:false}],visible:\"@composer\"}}}"
r "" deliver myrepo-architect --req "$REQ" --timeout 1
check "K4: busy — a member working until --timeout is sent nothing, and no response file is created" '[ "$(jo o.status)" = busy ] && [ "$(jo o.sent)" = false ] && [ "$(calls prompt)" -eq 0 ] && [ ! -f "$RESP" ]'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\"}}}"
r "" deliver myrepo-architect --req "$REQ"
hs "{agents:{\"myrepo-architect\":{gets:[{agent_status:\"working\",interactive_ready:false}],visible:\"@composer\"}}}"
r "" deliver myrepo-architect --req "$REQ" --wait-only
check "K4: --wait-only after a sent brief waits out a working turn, and sends nothing" '[ "$(calls wait)" -eq 1 ] && [ "$(calls prompt)" -eq 1 ] && [ "$(jo o.sent)" = false ]'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@trust\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K4/K13: blocked — the trust dialog on screen, though Herdr says idle and ready; nothing sent, no pane closed" '[ "$(jo o.status)" = blocked ] && [ "$(jo o.blocked_by)" = trust-dialog ] && [ "$(calls prompt)" -eq 0 ] && [ "$(calls pane-close)" -eq 0 ] && [ ! -f "$RESP" ]'
check "K17: a blocked from the check before sending has sent: false, and its next step is the same command" '[ "$(jo o.sent)" = false ] && jo o.message | grep -q "re-run this same command in the background: node .*deliver myrepo-architect --req"'
check "K13: ...with the screen verbatim and its options" 'jo o.screen | grep -q "Do you trust the contents" && [ "$(jo "o.options.map(x=>x.id).join()")" = trust,distrust ]'

setup_deliver
hs '{agents:{}}'
r "" deliver myrepo-architect --req "$REQ"
check "K4: not-live, with the spawn-one command" '[ "$RC" -eq 0 ] && [ "$(jo o.status)" = not-live ] && jo o.spawn | grep -q "spawn-one architect --member myrepo-architect" && [ "$(jo o.spawn_note)" = undefined ] && [ "$(jo o.sent)" = false ]'
hs '{agents:{"myrepo-architect":{gets:["error"],visible:"@composer"}}}'
r "" deliver myrepo-architect --req "$REQ"
check "K4: indeterminate when Herdr cannot answer" '[ "$(jo o.status)" = indeterminate ] && [ "$(calls prompt)" -eq 0 ]'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\",recent:\"still working\",prompt:{exit:1,json:{error:{code:\"timeout\",message:\"t\"}}}}}}"
r "" deliver myrepo-architect --req "$REQ" --timeout 5
check "K4: timeout, with a pane_tail, bounded by --timeout" '[ "$(jo o.status)" = timeout ] && [ "$(jo o.sent)" = true ] && jo o.pane_tail | grep -q "still working" && T=$(prompt_timeout) && [ "$T" -le 5000 ] && [ "$T" -gt 3000 ]'

setup_deliver
r "" deliver myrepo-reviewer --req "$REQ"
check "K4: a claude target exits 2" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "SendMessage it"'
r "" deliver nobody --req "$REQ"
check "K4: an unknown name exits 2, listing the team's pane members" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "myrepo-architect, myrepo-ultra-advisor"'

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:[\"@composer\",\"@other-1\"],onPrompt:{append:\"$RESP\",text:\"- a report\\n\"},prompt:{exit:0,json:{result:{agent:{agent_status:\"blocked\"}},type:\"agent_prompted\"}}}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K4: prompt --wait returning blocked is blocked / harness-prompt, with the screen" '[ "$(jo o.status)" = blocked ] && [ "$(jo o.blocked_by)" = harness-prompt ] && jo o.screen | grep -q "following edits"'
check "K4: ...and the response file is not evaluated, even though it changed" 'grep -q "a report" "$RESP" && [ "$(jo o.status)" != reported ]'
check "K17: a blocked at the end of the wait after sending has sent: true, and its next step is --wait-only" '[ "$(jo o.sent)" = true ] && jo o.message | grep -q "deliver myrepo-architect --req .* --wait-only"'

setup_deliver
hs '{agents:{"myrepo-architect":{gets:[{agent_status:"blocked",interactive_ready:false}],visible:"@other-2"}}}'
r "" deliver myrepo-architect --req "$REQ" --ping 2
check "K4: a --ping to a member Herdr reports blocked sends nothing" '[ "$(jo o.status)" = blocked ] && [ "$(calls prompt)" -eq 0 ]'
r "" deliver myrepo-architect --req "$REQ" --wait-only
check "K4: ...and --wait-only waits on nothing" '[ "$(jo o.status)" = blocked ] && [ "$(calls wait)" -eq 0 ]'
check "K15: Herdr blocked with no recognised heading is harness-prompt with options []" '[ "$(jo o.blocked_by)" = harness-prompt ] && [ "$(jo "o.options.length")" = 0 ]'
for n in 1 2 3 4 5; do
  hs "{agents:{\"myrepo-architect\":{gets:[{agent_status:\"blocked\",interactive_ready:false}],visible:\"@other-$n\"}}}"
  r "" deliver myrepo-architect --req "$REQ"
  check "K15: Codex's other approval heading #$n (edits, permissions, network, terminal, MCP) is harness-prompt with options []" '[ "$(jo o.blocked_by)" = harness-prompt ] && [ "$(jo "o.options.length")" = 0 ]'
done

setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\",recent:\"$(printf '%s' 'Do you trust the contents of this directory')\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K13: every screen check reads --source visible: trust text only in recent-unwrapped matches nothing" '[ "$(jo o.status)" = no-report ] && [ "$(calls prompt)" -eq 1 ]'
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@login\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K13: deliver with the login screen up gives blocked_by login, nothing sent" '[ "$(jo o.blocked_by)" = login ] && [ "$(calls prompt)" -eq 1 ]'

########################################################################
# K5 — route gate
########################################################################
setup_deliver
route() { # <tool> <tool_input JSON>
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s-route",cwd:process.argv[1],tool_name:process.argv[2],tool_input:JSON.parse(process.argv[3])}))' "$PROJ" "$1" "$2" | HOME="$FAKEHOME" node "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
}
route SendMessage '{"to":"myrepo-architect","message":"hello"}'
check "K5: SendMessage to a codex member is denied, naming the deliver command" 'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\"" && echo "$OUT" | grep -qF "deliver myrepo-architect --req <request path> --cwd $PROJ" && echo "$OUT" | grep -q "cannot receive SendMessage"'
route SendMessage "{\"to\":\"myrepo-architect [abc123]\",\"message\":\"[hierarchy-peer-brief reply-to=\\\"o\\\"] [hierarchy-msg $REQ]\"}"
check "K5: ...with its [ref] stripped, and a brief's request path filled in" 'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\"" && echo "$OUT" | grep -qF "deliver myrepo-architect --req $REQ"'
route SendMessage '{"to":"myrepo-reviewer","message":"hello"}'
check "K5: SendMessage to a claude member is not denied by that rule" '! echo "$OUT" | grep -q "cannot receive SendMessage"'
rm -rf "$HIER"
route Agent '{"subagent_type":"ah:architect","prompt":"x"}'
check "K5: an Agent dispatch of a chain role whose member is pane gets the deliver paneLine" 'echo "$OUT" | grep -q "This member.s route is pane: brief it with" && echo "$OUT" | grep -qF "deliver <name> --req <request path>" && echo "$OUT" | grep -q "including when spawn-one reports it already live"'

########################################################################
# K6 / K8 — tiers never read from a name; the 0058 ask for mapped kinds
########################################################################
check "K6: a codex model named opus-lookalike has no tier: declaredTier is null, where the name alone would give tierOf 3" '[ "$(lib "return C.declaredTier(\"codex\",\"opus-lookalike\")")" = null ] && [ "$(lib "return C.tierOf(\"opus-lookalike\")")" = 3 ]'
rm -rf "$HIER"; reset_state
roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"opus-lookalike"},{"role":"reviewer"}]'
STATUS=$(cd "$PROJ" && HOME="$FAKEHOME" node "$H/lib-config.mjs" 2>&1)
check "K6: status shows a codex member as codex:<model>(?)" 'echo "$STATUS" | grep -q "model=codex:opus-lookalike(?)"'
r "HERDR_ENV=1" create --plan
check "K6: the 0058 fallback never picks a codex donor" '[ "$(jo "o.members_needing_model.find(m=>m.name===\"myrepo-reviewer\").fallback")" = null ]'
roster_cfg '[{"role":"architect","model":"opus"},{"role":"reviewer"}]'
r "HERDR_ENV=1" create --plan
check "K6: ...where a claude architect on opus is one (control)" '[ "$(jo "o.members_needing_model.find(m=>m.name===\"myrepo-reviewer\").fallback.model")" = opus ]'
roster_cfg '[{"role":"architect","kind":"codex","route":"pane"},{"role":"ultra-advisor","kind":"codex","route":"pane"}]'
echo '{"modelTiers":{"codex":{"m-fable":"fable","m-sonnet":"sonnet","m-opus":"opus"}}}' > "$GLOBAL"
r "HERDR_ENV=1" create --plan
check "K8: a model-less codex member is listed with allowed null and fallback null" '[ "$(jo "JSON.stringify(o.members_needing_model.find(m=>m.name===\"myrepo-architect\"))")" = "{\"name\":\"myrepo-architect\",\"role\":\"architect\",\"class\":\"design\",\"kind\":\"codex\",\"allowed\":null,\"fallback\":null,\"models_command\":\"codex debug models\"}" ]'
check "K8: a model-less codex advise member's allowed is its kind's models declared opus or fable" '[ "$(jo "o.members_needing_model.find(m=>m.name===\"myrepo-ultra-advisor\").allowed.join()")" = m-fable,m-opus ]'
r "HERDR_ENV=1" create --spawn
check "K8: create --spawn refuses member-model-undefined, naming codex debug models" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = member-model-undefined ] && jo o.message | grep -q "codex debug models" && [ "$(jo o.rerun_fallback)" = null ]'
check "K6: SKILL.md's ladder step 3 ranks a non-Claude member by its declared tier, and an undeclared one below every tiered model" 'grep -q "A non-Claude member ranks by its" "$PLUGIN/skills/agent-team/SKILL.md" && grep -q "model.s declared tier, which status shows as \`<kind>:<model>(<tier>)\`" "$PLUGIN/skills/agent-team/SKILL.md" && grep -q "(\`?\` when none is declared), never by its name" "$PLUGIN/skills/agent-team/SKILL.md" && grep -q "a non-Claude model with no declared tier, or no model," "$PLUGIN/skills/agent-team/SKILL.md"'
rm -f "$GLOBAL"

########################################################################
# K10 — declared tiers
########################################################################
rm -rf "$HIER"; reset_state
roster_cfg '[{"role":"ultra-advisor","kind":"codex","route":"pane","model":"gpt-6-astra"}]'
CFG_SUM=$(shasum "$CFG")
r "" tier set codex gpt-6-astra fable
check "K10: tier set writes only the global file" '[ "$RC" -eq 0 ] && [ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).modelTiers.codex[\"gpt-6-astra\"])" "$GLOBAL")" = fable ] && [ "$(shasum "$CFG")" = "$CFG_SUM" ]'
r "" tier list
check "K10: list shows it" '[ "$(jo "o.modelTiers.codex[\"gpt-6-astra\"]")" = fable ]'
check "K10: a global file holding only modelTiers configures no hierarchy" '[ "$(cd "$SANDBOX" && HOME="$FAKEHOME" node --input-type=module -e "const C=await import(\"$H/lib-config.mjs\");console.log(C.resolveConfig(\"$SANDBOX\").configured)")" = false ]'
r "" tier remove codex gpt-6-astra
check "K10: remove deletes it" '[ "$(jo o.removed)" = true ] && ! grep -q modelTiers "$GLOBAL"'
r "" tier set claude opus fable
check "K10: tier set for kind claude is refused" '[ "$RC" -eq 2 ]'
r "" tier set codex m1 mega
check "K10: tier set with an unknown tier name is refused" '[ "$RC" -eq 2 ]'
echo '{"modelTiers":{"claude":{"opus":"fable"},"codex":{"m1":"mega","m2":"opus"}}}' > "$GLOBAL"
r "" tier list
check "K10: a claude entry and an unknown tier name are ignored with a warning" '[ "$(jo "JSON.stringify(o.modelTiers)")" = "{\"codex\":{\"m2\":\"opus\"}}" ] && [ "$(jo "o.warnings.length")" = 2 ] && jo "o.warnings.join()" | grep -q "modelTiers.claude" && jo "o.warnings.join()" | grep -q "mega"'
rm -f "$GLOBAL"
r "HERDR_ENV=1" spawn-one ultra-advisor
check "K10: a codex Ultra-Advisor on an undeclared model is refused advise-model-tier (declared_tier null)" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = advise-model-tier ] && [ "$(jo o.declared_tier)" = null ] && [ "$(jo "o.needs.join()")" = opus,fable ] && jo o.rerun_declare | grep -q "tier set codex gpt-6-astra <TIER>"'
check "K10: ...creating no team file and launching nothing" '[ ! -d "$HIER/teams" ] || [ -z "$(ls "$HIER/teams")" ]; [ "$(calls start)" -eq 0 ]'
echo '{"modelTiers":{"codex":{"gpt-6-astra":"sonnet"}}}' > "$GLOBAL"
r "HERDR_ENV=1" spawn-one ultra-advisor
check "K10: declared sonnet: the same refusal, with declared_tier sonnet" '[ "$RC" -eq 2 ] && [ "$(jo o.declared_tier)" = sonnet ] && [ "$(calls start)" -eq 0 ]'
echo '{"modelTiers":{"codex":{"gpt-6-astra":"fable"}}}' > "$GLOBAL"
r "HERDR_ENV=1" spawn-one ultra-advisor
check "K10: declared fable: it launches" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ] && [ "$(calls start)" -eq 1 ]'
STATUS=$(cd "$PROJ" && HOME="$FAKEHOME" node "$H/lib-config.mjs" 2>&1)
check "K10: what ladder step 3 ranks by: status shows the declared-fable codex member as codex:gpt-6-astra(fable) (the ranking itself is SKILL.md prose, checked under K6)" 'echo "$STATUS" | grep -q "model=codex:gpt-6-astra(fable)"'
rm -f "$GLOBAL"

########################################################################
# K7 — names
########################################################################
rm -rf "$HIER"; reset_state
roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"}]'
hs '{start:"name-taken"}'
r "HERDR_ENV=1" spawn-one architect
check "K7: agent_name_taken gives refused name-in-use, not a launch failure" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = name-in-use ] && [ "$(jo o.name)" = myrepo-architect ] && jo o.rerun | grep -q -- "--names-in-use myrepo-architect$"'
check "K7: ...the pane opened for it is closed, and no team file is written" '[ "$(calls pane-close)" -ge 1 ] && { [ ! -d "$HIER/teams" ] || [ -z "$(ls "$HIER/teams")" ]; }'
rm -rf "$HIER"; reset_state
hs "{start:[\"timeout-registered\",\"name-taken\"],afterStart:{gets:[$IDLE],visible:\"@composer\"}}"
r "HERDR_ENV=1" spawn-one architect
check "K7: name taken only on the retry, after a first attempt that timed out with the agent registered here: a launch failure, not name-in-use" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" != name-in-use ] && ! echo "$OUT" | grep -q "another Herdr agent already holds" && [ "$(calls start)" -eq 2 ]'
check "K7: ...and this launch's own live agent keeps its pane, with the close command reported" '[ "$(calls pane-close)" -eq 0 ] && echo "$OUT" | grep -q "close it with"'

########################################################################
# K13 — the trust dialog and the login screen at spawn
########################################################################
k13() { # <codex config body|"none"|"dir"> <herdr afterStart JS>
  rm -rf "$HIER" "$CODEXHOME"; mkdir -p "$CODEXHOME"; reset_state
  roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"}]'
  case "$1" in none) ;; dir) mkdir -p "$CODEXHOME/config.toml";; *) printf '%s\n' "$1" > "$CODEXHOME/config.toml";; esac
  hs "{afterStart:$2}"
  r "HERDR_ENV=1" spawn-one architect
}
UNTRUSTED='[projects."/nowhere/else"]
trust_level = "trusted"'
k13 "$UNTRUSTED" "{gets:[{agent_status:\"idle\",interactive_ready:false},$IDLE],visible:\"@trust\"}"
check "K13: an untrusted cwd does not refuse before launch" '[ "$(calls start)" -eq 1 ]'
check "K13: (a) untrusted, trust dialog on screen after readiness: launched with a blocked trust-dialog object" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ] && [ "$(jo o.blocked.blocked_by)" = trust-dialog ] && [ "$(jo "o.blocked.options.map(x=>x.id).join()")" = trust,distrust ] && [ "$(jo "o.blocked.screen_hash.length")" = 64 ]'
check "K13: ...the pane stays open and no keys are sent" '[ "$(calls pane-close)" -eq 0 ] && [ "$(calls send-keys)" -eq 0 ]'
check "K13: the screen read came after Herdr reported interactive_ready (a not-ready get, then a ready one, after the start)" 'node -e "const rows=require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim().split(\"\\n\").map(JSON.parse);const s=rows.findIndex(a=>a[1]===\"start\");const read=rows.findIndex((a,i)=>i>s&&a[1]===\"read\"&&a.includes(\"visible\"));const gets=rows.filter((a,i)=>i>s&&i<read&&a[1]===\"get\").length;process.exit(s>=0&&read>s&&gets>=2?0:1)" "$FAKE_STATE_DIR/calls.jsonl"'
SPAWN_HASH=$(jo o.blocked.screen_hash)
check "K13: the message relays it through AskUserQuestion and answer" 'jo o.message | grep -q "AskUserQuestion, header \"Codex prompt\"" && jo o.message | grep -q "roster.mjs answer myrepo-architect --prompt trust-dialog"'
k13 "$UNTRUSTED" "{gets:[$IDLE],visible:\"@composer\"}"
check "K17: (a) untrusted, but the screen is the composer: launched and ready, nothing closed" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ] && [ "$(jo o.blocked)" = undefined ] && [ "$(calls pane-close)" -eq 0 ]'
k13 "$UNTRUSTED" "{gets:[$IDLE],visible:\"@blank\"}"
check "K13: (a) untrusted and neither the composer nor a recognised prompt: refused harness-cwd-untrusted" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = harness-cwd-untrusted ] && [ "$(jo o.cwd)" = "$PROJ" ] && jo o.message | grep -q "Codex has not been told to trust"'
check "K13: ...closing only the pane it opened, and writing no team file" '[ "$(calls pane-close)" -eq 1 ] && grep -q "\"pane\",\"close\",\"p1\"" "$FAKE_STATE_DIR/calls.jsonl" && { [ ! -d "$HIER/teams" ] || [ -z "$(ls "$HIER/teams")" ]; }'
k13 "$UNTRUSTED" "{gets:[{agent_status:\"blocked\",interactive_ready:true}],visible:\"@other-1\"}"
check "K13: (a) untrusted, and Herdr blocked on a screen no pattern recognises: refused harness-cwd-untrusted too" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = harness-cwd-untrusted ] && [ "$(calls pane-close)" -eq 1 ]'
k13 none "{gets:[{agent_status:\"blocked\",interactive_ready:true}],visible:\"@other-1\"}"
check "K13: (a) unknown, and Herdr blocked on an unrecognised screen: launched with a harness-prompt blocked object, options []" '[ "$RC" -eq 0 ] && [ "$(jo o.blocked.blocked_by)" = harness-prompt ] && [ "$(jo "o.blocked.options.length")" = 0 ] && [ "$(calls pane-close)" -eq 0 ]'
k13 none "{gets:[$IDLE],visible:\"@composer\"}"
check "K13: (a) unknown (no config) and no prompt: launches normally" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ] && [ "$(jo o.blocked)" = undefined ] && [ "$(calls pane-close)" -eq 0 ]'
k13 dir "{gets:[$IDLE],visible:\"@composer\"}"
check "K13: an unreadable config: spawn proceeds to layer (b) and launches" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ]'
k13 none "{gets:[$IDLE],visible:\"@login\"}"
check "K13: the login screen at spawn: launched with a blocked login object" '[ "$RC" -eq 0 ] && [ "$(jo o.blocked.blocked_by)" = login ] && [ "$(jo "o.blocked.options.map(x=>x.id).join()")" = sign-in ]'

trustv() { # <cwd> -> the (a) verdict, reading $CODEXHOME
  HOME="$FAKEHOME" node --input-type=module -e "const R=await import('$H/lib-roster.mjs');console.log(R.codexTrust(process.argv[1],{CODEX_HOME:'$CODEXHOME'}).verdict)" "$1"
}
mkdir -p "$PROJ/sub/deeper"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$SANDBOX" > "$CODEXHOME/config.toml"
check "K13: a config trusting only an ancestor of the cwd: trusted, not refused" '[ "$(trustv "$PROJ/sub/deeper")" = trusted ]'
(cd "$PROJ" && git worktree add -q "$SANDBOX/wt" 2>/dev/null)
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PROJ" > "$CODEXHOME/config.toml"
check "K13: only the main checkout root trusted, for a worktree cwd: trusted" '[ "$(trustv "$SANDBOX/wt")" = trusted ]'
printf '[projects."%s"]\ntrust_level = "trusted"\n' "/elsewhere" > "$CODEXHOME/config.toml"
check "K13: a config trusting neither: untrusted" '[ "$(trustv "$SANDBOX/wt")" = untrusted ]'
mkdir -p "$FAKEHOME/.codex"; printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PROJ" > "$FAKEHOME/.codex/config.toml"
check "K13: CODEX_HOME set: that config is read, and ~/.codex is not" '[ "$(trustv "$PROJ")" = untrusted ] && [ "$(HOME="$FAKEHOME" node --input-type=module -e "const R=await import(\"$H/lib-roster.mjs\");console.log(R.codexTrust(\"$PROJ\",{}).verdict)")" = trusted ]'
rm -rf "$FAKEHOME/.codex"
printf 'projects = { "/x" = { trust_level = "trusted" } }\n' > "$CODEXHOME/config.toml"
check "K13: a projects inline table: unknown, not refused" '[ "$(trustv "$PROJ")" = unknown ]'
printf '[projects."/x\\q"]\ntrust_level = "trusted"\n' > "$CODEXHOME/config.toml"
check "K13: an undecodable header: unknown" '[ "$(trustv "$PROJ")" = unknown ]'
printf "[projects.'%s']\ntrust_level = \"trusted\"\n" "$PROJ" > "$CODEXHOME/config.toml"
check "K13: a literal-string header: unknown" '[ "$(trustv "$PROJ")" = unknown ]'
printf '[projects."%s"]\ntrusted_hash = "abc"\ntrust_level = "untrusted"\n[other]\ntrusted_hash = "x"\n' "$PROJ" > "$CODEXHOME/config.toml"
check "K13: trusted_hash lines are ignored, and trust_level other than trusted is untrusted" '[ "$(trustv "$PROJ")" = untrusted ]'

########################################################################
# K15 — answer
########################################################################
k15() { # <screen> [afterKeys JS] [Herdr get JS, default blocked] -> a codex architect at that screen
  setup_deliver
  hs "{agents:{\"myrepo-architect\":{gets:[${3:-$HERDR_BLOCKED}],visible:\"@$1\"${2:+,afterKeys:$2}}}}"
}
HERDR_BLOCKED='{agent_status:"blocked",interactive_ready:false}'
AH=$(screen_hash approval)
k15 approval "{visible:\"@composer\",gets:[$IDLE]}"
r "" answer myrepo-architect --prompt approval --choice approve --screen-hash "$AH"
check "K15: a matching prompt and hash: exactly the row's keys, once — approve sends 1" '[ "$RC" -eq 0 ] && [ "$(jo o.status)" = answered ] && [ "$(keys_sent)" = "[\"1\"]" ] && [ "$(jo o.prompt_after)" = null ] && [ "$(jo o.live)" = true ]'
k15 approval
r "" answer myrepo-architect --prompt approval --choice deny --screen-hash "$AH"
check "K15: deny sends esc; the prompt still shown after is answered, reported, keys sent once" '[ "$(keys_sent)" = "[\"esc\"]" ] && [ "$(jo o.status)" = answered ] && [ "$(jo o.prompt_after)" = approval ]'
TH=$(screen_hash trust)
k15 trust "" "$IDLE"
r "" answer myrepo-architect --prompt trust-dialog --choice trust --screen-hash "$TH"
check "K15: trust sends 1 then Enter" '[ "$(keys_sent)" = "[\"1\",\"Enter\"]" ]'
k15 trust '{gets:["notfound"],gone:true}' "$IDLE"
r "" answer myrepo-architect --prompt trust-dialog --choice distrust --screen-hash "$TH"
check "K15: distrust sends exactly 2; the agent gone after it is answered, not live, prompt_after null, exit 0" '[ "$RC" -eq 0 ] && [ "$(keys_sent)" = "[\"2\"]" ] && [ "$(jo o.status)" = answered ] && [ "$(jo o.live)" = false ] && [ "$(jo o.prompt_after)" = null ] && [ "$(jo o.closed)" = undefined ]'
check "K15: answer never closes a pane" '[ "$(calls pane-close)" -eq 0 ] && ! sed -n "/case \"answer\": {/,/case \"tier\": {/p" "$H/roster.mjs" | grep -q "closeMemberPane\|closeOrphanPane\|\"pane\", \"close\""'
LH=$(screen_hash login)
k15 login "" "$IDLE"
r "" answer myrepo-architect --prompt login --choice sign-in --screen-hash "$LH"
check "K15: sign-in sends 1" '[ "$(keys_sent)" = "[\"1\"]" ]'
k15 approval
r "" answer myrepo-architect --prompt approval --choice approve --screen-hash "$TH"
check "K15: a hash mismatch: screen-changed with fresh fields, nothing sent" '[ "$(jo o.status)" = screen-changed ] && [ "$(jo o.blocked_by)" = approval ] && [ "$(jo o.screen_hash)" = "$AH" ] && [ "$(jo "o.options.map(x=>x.id).join()")" = approve,deny ] && [ "$(calls send-keys)" -eq 0 ]'
k15 trust "" "$IDLE"
r "" answer myrepo-architect --prompt approval --choice approve --screen-hash "$TH"
check "K15: a different prompt on screen (same hash): screen-changed, nothing sent" '[ "$(jo o.status)" = screen-changed ] && [ "$(jo o.blocked_by)" = trust-dialog ] && [ "$(calls send-keys)" -eq 0 ]'
k15 approval
r "" answer myrepo-architect --prompt approval --choice always --screen-hash "$AH"
check "K15: an unknown --choice exits 2 listing the ids, nothing sent" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "the ids are: approve, deny" && [ "$(calls send-keys)" -eq 0 ]'
r "" answer myrepo-architect --prompt nosuch --choice approve --screen-hash "$AH"
check "K15: an unknown --prompt exits 2, nothing sent" '[ "$RC" -eq 2 ] && [ "$(calls send-keys)" -eq 0 ]'
r "" answer myrepo-architect --prompt approval --choice "'Yes, and don'\\''t ask again'" --screen-hash "$AH"
check "K15: approval's \"don't ask again\" is not a row: exit 2, nothing sent" '[ "$RC" -eq 2 ] && [ "$(calls send-keys)" -eq 0 ]'
r "" answer myrepo-reviewer --prompt approval --choice approve --screen-hash "$AH"
check "K15: a claude member exits 2" '[ "$RC" -eq 2 ] && [ "$(calls send-keys)" -eq 0 ]'
r "" answer myrepo-architect --prompt approval --choice approve --screen-hash "$AH" --keys 1
check "K15: the verb takes no flag for keys or text" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "unrecognized flag --keys" && grep -q "^const ANSWER_FLAGS = new Set(\[\"prompt\", \"choice\", \"screen-hash\", \"team\", \"cwd\"\]);" "$H/roster.mjs"'
NH=$(screen_hash approval-reordered)
k15 approval-reordered
r "" deliver myrepo-architect --req "$REQ"
check "K15: on-screen filter — option 1 reading other than \"1. Yes, proceed\" gets no approve" '[ "$(jo o.blocked_by)" = approval ] && [ "$(jo "o.options.map(x=>x.id).join()")" = deny ]'
r "" answer myrepo-architect --prompt approval --choice approve --screen-hash "$NH"
check "K15: ...and answer --choice approve against it, hash matching, exits 2 listing the offered ids, nothing sent" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "was not offered on this screen" && echo "$OUT" | grep -q "offered on it: deny" && [ "$(calls send-keys)" -eq 0 ]'
k15 approval-remapped
r "" deliver myrepo-architect --req "$REQ"
check "K15: on-screen filter — a (d) decline hint instead of (esc) gets no deny" '[ "$(jo "o.options.map(x=>x.id).join()")" = approve ]'
k15 approval-narrow
r "" deliver myrepo-architect --req "$REQ"
check "K15/K17: a narrow pane's wrapped option is matched on its joined label: deny over the wrapped (esc) line" '[ "$(jo o.blocked_by)" = approval ] && [ "$(jo "o.options.map(x=>x.id).join()")" = approve,deny ]'
k15 approval
r "" deliver myrepo-architect --req "$REQ"
check "K15: deliver's blocked for an approval screen carries the table's options, grants marked" '[ "$(jo "JSON.stringify(o.options.map(x=>[x.id,x.label,x.grants]))")" = "[[\"approve\",\"Yes, once\",true],[\"deny\",\"No\",false]]" ]'
DELIVER_HASH=$(jo o.screen_hash)
k15 trust "" "$IDLE"
r "" deliver myrepo-architect --req "$REQ"
check "K15: ...with placeholders filled (config path, cwd)" 'jo "o.options[1].description" | grep -qF "Nothing is written to \`$CODEXHOME/config.toml\`, so the next Codex launch in \`$PROJ\` asks again."'
check "K15: the same function computes screen_hash in spawn, deliver and answer: one fixture, one hash" '[ "$(jo o.screen_hash)" = "$TH" ] && [ "$SPAWN_HASH" = "$TH" ] && [ "$DELIVER_HASH" = "$AH" ]'
k15 trust "" "$IDLE"
r "" deliver myrepo-architect --req "$REQ" --cwd "$PROJ/sub"
check "K15: trust's description names the main checkout root for a cwd in a subdirectory" 'jo "o.options[0].description" | grep -qF "for \`$PROJ\` in \`$CODEXHOME/config.toml\`. That is the whole repository, not only \`$PROJ/sub\`."'
trustdesc() { HOME="$FAKEHOME" node --input-type=module -e "const R=await import('$H/lib-roster.mjs');const fs=await import('node:fs');const p=await import('node:path');const cwd=process.argv[1];const t=R.codexTrust(cwd,{CODEX_HOME:'$CODEXHOME'});console.log(R.promptOptions('codex','trust-dialog',R.recognizeScreen('codex',fs.readFileSync('$SCREENS/trust.txt','utf8'),'idle').block,{cwd:p.resolve(cwd),configPath:t.configPath,codexHome:t.codexHome,trustRoot:t.trustRoot})[0].description)" "$1"; }
check "K15: ...for a linked worktree, the main checkout" 'trustdesc "$SANDBOX/wt" | grep -qF "for \`$PROJ\` in" && trustdesc "$SANDBOX/wt" | grep -qF "not only \`$SANDBOX/wt\`"'
mkdir -p "$SANDBOX/nogit"
check "K15: ...and with no checkout, the cwd, with no repository sentence" 'trustdesc "$SANDBOX/nogit" | grep -qF "for \`$SANDBOX/nogit\` in" && ! trustdesc "$SANDBOX/nogit" | grep -q "whole repository"'

########################################################################
# K11 / K12 / K16 — gates and deliver's floor
########################################################################
SID="s-gate"
GATE_FILE="$FAKEHOME/.claude/agent-hierarchy.gate.json"
decide_gate() { rm -f "$GATE_FILE"; [ "$1" = none ] || HOME="$FAKEHOME" node "$H/gate.mjs" set --session "$SID" --choice "$1" >/dev/null; }
bashhook() { # <hook file> <command> [env...]
  local hook=$1 cmd=$2; shift 2
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],cwd:process.argv[2],tool_name:"Bash",tool_input:{command:process.argv[3]}}))' "$SID" "$PROJ" "$cmd" | env HOME="$FAKEHOME" "$@" node "$H/$hook" 2>&1); RC=$?
}
ug() { bashhook pretooluse-ultra-gate.mjs "$@"; }
hg() { bashhook pretooluse-herdr-name-gate.mjs "$@"; }
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
asked() { echo "$OUT" | grep -q '"permissionDecision":"ask"'; }
silent() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }
setup_deliver
team_file "[$CODEX_ARCH,$CODEX_UA,$CLAUDE_REV,$CLAUDE_UA2]"
team_file '[{"role":"ultra-advisor","name":"other-ultra-advisor","kind":"codex","route":"pane","model":"gpt-6-astra","transport_id":"p9"}]' other
mkreq ua1 ultra-advisor myrepo-ultra-advisor
DELIVER_UA="node $H/roster.mjs deliver myrepo-ultra-advisor --req $REQ --cwd $PROJ"
decide_gate none; ug "$DELIVER_UA"
check "K11: deliver to a codex Ultra-Advisor with no decision is denied with the first-use text" 'denied && echo "$OUT" | grep -q "has no decision on record" && echo "$OUT" | grep -q "re-issue the identical command"'
check "K11: ...naming the member's own kind, model and declared tier" 'echo "$OUT" | grep -q "codex gpt-6-astra (declared none)"'
decide_gate each; ug "$DELIVER_UA"
check "K11: under each it asks" 'asked'
decide_gate session; ug "$DELIVER_UA"
check "K11: under session it passes" 'silent'
decide_gate off; ug "$DELIVER_UA"
check "K11: under off it is denied" 'denied && echo "$OUT" | grep -q "No, not this session"'
for d in none each session off; do
  decide_gate $d; ug "$DELIVER_UA --wait-only"
  check "K11: --wait-only passes under $d" 'silent'
done
touch "$RESP"
decide_gate each; ug "$DELIVER_UA --ping 2"
check "K11: --ping 2 with an existing response file passes under each without an ask" 'silent'
decide_gate off; ug "$DELIVER_UA --ping 2"
check "K11: ...and is denied under off" 'denied'
decide_gate none; ug "$DELIVER_UA --ping 2"
check "K11: ...and with no decision" 'denied'
rm -f "$RESP"
decide_gate session; ug "$DELIVER_UA --ping 2"
check "K11: a ping whose request has no response file yet is a delivery: under session it passes" 'silent'
decide_gate each; ug "$DELIVER_UA --ping 2"
check "K11: ...and under each it asks" 'asked'
decide_gate session; ug 'herdr agent prompt myrepo-ultra-advisor "x"'
check "K11: a raw herdr agent prompt to a codex Ultra-Advisor is denied, under session too" 'denied && echo "$OUT" | grep -q "deliver myrepo-ultra-advisor --req <request path>"'
ug 'herdr --session default agent prompt myrepo-ultra-advisor "x"'
check "K11: ...with --session <name> before agent" 'denied'
ug "$(printf 'herdr agent prompt \\\n  myrepo-ultra-advisor "x"')"
check "K11: ...with a backslash-newline before the name" 'denied'
ug '"herdr" agent prompt myrepo-ultra-advisor "x"'
check "K11: ...with the command word quoted" 'denied'
ug 'herdr agent --session=default prompt myrepo-ultra-advisor "x"'
check "K11: ...with --session=<name> between agent and its verb" 'denied'
ug 'herdr --remote host --handoff agent send-keys myrepo-ultra-advisor-2 "hello world"'
check "K11: a multi-token send-keys to a Claude Ultra-Advisor behind global options is denied" 'denied'
hg 'herdr agent send-keys myrepo-ultra-advisor Enter'
check "K11/K16: send-keys to a codex Ultra-Advisor is denied by the herdr-command rule" 'denied && echo "$OUT" | grep -q "answer its prompt with \`roster.mjs answer\` after asking the user"'
ug 'herdr agent send-keys myrepo-ultra-advisor-2 Enter'
check "K11: a Claude Ultra-Advisor in a Herdr pane: one key token (Enter) passes the ultra-gate" 'silent'
hg 'herdr agent send-keys myrepo-ultra-advisor-2 Enter'
check "K11: ...and the herdr-command rule leaves a Claude member alone" 'silent'
ug 'herdr agent send-keys myrepo-ultra-advisor-2 "hello world"'
check "K11: ...while \"hello world\" is denied" 'denied'
ug "node $H/roster.mjs deliver other-ultra-advisor --req $REQ --cwd $PROJ" AH_TEAM_FILE="$HIER/teams/myrepo.json"
check "K11: a sibling team's codex Ultra-Advisor, from a session that resolves its own team, is not gated (G1)" 'silent'
decide_gate none; ug "node $H/roster.mjs deliver other-ultra-advisor --req $REQ --cwd $PROJ"
check "K11: ...while from a session that resolves none, it is (control)" 'denied'
rm -f "$HOOK_LOG"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"ls -la && git status"}}))' "$PROJ" | HOME="$FAKEHOME" node --import "$THROWS" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "K11: a Bash call without those shapes reads no config: it passes silently where resolveConfig would throw" 'silent && [ ! -s "$HOOK_LOG" ]'
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$DELIVER_UA" | HOME="$FAKEHOME" node --import "$THROWS" "$H/pretooluse-ultra-gate.mjs" 2>&1); RC=$?
check "K11: ...where a deliver command does reach the config read (control: the injected throw is logged)" '[ "$RC" -eq 1 ] && grep -q "injected by tests/fixtures/resolve-config-throws.mjs" "$HOOK_LOG"'
for d in none each session off; do
  decide_gate $d; ug "node $H/roster.mjs answer myrepo-ultra-advisor --prompt approval --choice approve --screen-hash $AH --cwd $PROJ"
  check "K16: answer to a codex Ultra-Advisor gets no ultra-gate decision under $d" 'silent'
done

# K12 — the floor in deliver itself, with the hook bypassed
hs "{agents:{\"myrepo-ultra-advisor\":{gets:[$IDLE],visible:\"@composer\"},\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\"}}}"
decide_gate none; r "CLAUDE_CODE_SESSION_ID=$SID" deliver myrepo-ultra-advisor --req "$REQ" --team myrepo
check "K12: no decision: exit 2, nothing sent" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no Ultra-Advisor decision on record" && [ "$(calls prompt)" -eq 0 ] && [ "$(calls get)" -eq 0 ]'
decide_gate off; r "CLAUDE_CODE_SESSION_ID=$SID" deliver myrepo-ultra-advisor --req "$REQ" --team myrepo
check "K12: off: exit 2" '[ "$RC" -eq 2 ] && [ "$(calls prompt)" -eq 0 ]'
decide_gate session; r "" deliver myrepo-ultra-advisor --req "$REQ" --team myrepo
check "K12: no resolvable session: exit 2" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "cannot be resolved" && [ "$(calls prompt)" -eq 0 ]'
decide_gate session; r "CLAUDE_CODE_SESSION_ID=$SID" deliver myrepo-ultra-advisor --req "$REQ" --team myrepo
check "K12: session: it sends" '[ "$RC" -eq 0 ] && [ "$(calls prompt)" -eq 1 ]'
decide_gate each; r "CLAUDE_CODE_SESSION_ID=$SID" deliver myrepo-ultra-advisor --req "$REQ" --team myrepo
check "K12: each: it sends" '[ "$RC" -eq 0 ] && [ "$(calls prompt)" -eq 2 ]'
decide_gate none; r "" deliver myrepo-architect --req "$REQ" --team myrepo
check "K12: a non-advise codex member never consults the gate" '[ "$RC" -eq 0 ] && [ "$(calls prompt)" -eq 3 ]'

# K16 — the close gate, the allow hook, and the herdr-command rule
ANSWER="node $H/roster.mjs answer myrepo-architect --prompt approval --choice approve --screen-hash $AH --cwd $PROJ"
bashhook pretooluse-disband-close-gate.mjs "$ANSWER"
check "K16: the close gate emits no decision for answer --choice approve" 'silent'
bashhook pretooluse-disband-close-gate.mjs "${ANSWER/approve/deny}"
check "K16: ...nor for --choice deny" 'silent'
bashhook pretooluse-disband-close-gate.mjs "node $H/roster.mjs answer myrepo-architect --prompt approval; echo \$(id)"
check "K16: ...nor for an answer that will not parse" 'silent'
bashhook pretooluse-disband-close-gate.mjs "node $H/roster.mjs disband --close --confirm --plan-token abc --cwd $PROJ"
check "K16: its close cases still ask" 'asked'
bashhook pretooluse-ah-cli.mjs "$ANSWER"; A1=$(echo "$OUT" | grep -o '"permissionDecision":"[a-z]*"')
bashhook pretooluse-ah-cli.mjs "node $H/roster.mjs teams --cwd $PROJ"; A2=$(echo "$OUT" | grep -o '"permissionDecision":"[a-z]*"')
check "K16: the allow hook gives answer --choice approve the same decision as any other roster verb" '[ -n "$A1" ] && [ "$A1" = "$A2" ]'
hg 'herdr agent send-keys myrepo-architect 1'
check "K16: send-keys to a codex member is denied" 'denied'
hg 'herdr --session default agent send-keys myrepo-architect 1'
check "K16: ...with --session <name> before agent" 'denied'
hg 'herdr --session=default agent prompt myrepo-architect x'
check "K16: ...with --session=<name> before agent" 'denied'
hg 'herdr --remote host --remote-keybindings server agent send-keys myrepo-architect 1'
check "K16: ...with --remote <target> --remote-keybindings <v> before agent" 'denied'
hg 'herdr --handoff agent prompt myrepo-architect x'
check "K16: ...with a bare flag before agent" 'denied'
hg 'herdr agent --session default send-keys myrepo-architect 1'
check "K16: ...with --session <name> between agent and its verb" 'denied'
hg '/usr/local/bin/herdr --session default agent prompt myrepo-architect x'
check "K16: ...with herdr run by its path" 'denied'
hg 'herdr --session default agent get myrepo-architect'
check "K16: herdr --session <name> agent get still passes" 'silent'
hg 'herdr --session default agent start Bad_Name --kind codex --pane p1'
check "K16: the name rule also sees agent start behind a global option" 'denied && echo "$OUT" | grep -q "must start with a lowercase letter"'
hg 'node /x/hooks/pretooluse-herdr-name-gate.mjs agent send-keys myrepo-architect 1'
check "K16: a word that only contains herdr is not herdr" 'silent'
hg 'herdr agent prompt myrepo-architect x'
check "K16: prompt to a codex member is denied" 'denied'
hg 'herdr agent send-keys myrepo-architect-2 1'
check "K16: send-keys to an unrecorded <prefix>-architect-2 whose roster row is codex is denied" 'denied'
hg 'herdr agent prompt myrepo-architect-2 x'
check "K16: ...and prompt" 'denied'
for v in read get wait; do
  hg "herdr agent $v myrepo-architect"
  check "K16: herdr agent $v to a codex member passes" 'silent'
done
hg 'herdr agent send-keys myrepo-reviewer Enter'
check "K16: send-keys to a claude member passes the new rule" 'silent'
rm -f "$HOOK_LOG"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"herdr agent get myrepo-architect && ls"}}))' "$PROJ" | HOME="$FAKEHOME" node --import "$THROWS" "$H/pretooluse-herdr-name-gate.mjs" 2>&1); RC=$?
check "K16: a Bash call without herdr agent prompt/send-keys reads no config: passes where resolveConfig would throw" 'silent && [ ! -s "$HOOK_LOG" ]'
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"herdr agent send-keys myrepo-architect 1"}}))' "$PROJ" | HOME="$FAKEHOME" node --import "$THROWS" "$H/pretooluse-herdr-name-gate.mjs" 2>&1); RC=$?
check "K16: ...where a send-keys command does reach it (control: the injected throw is logged)" 'grep -q "injected by tests/fixtures/resolve-config-throws.mjs" "$HOOK_LOG"'

########################################################################
# K17 — the composer allowlist, the strict prompt grammar, and the rest of the review's fixes
########################################################################
seen() { # <screen> <Herdr status> -> composer, prompt and offered ids, as JSON
  HOME="$FAKEHOME" node --input-type=module -e "const R=await import('$H/lib-roster.mjs');const fs=await import('node:fs');const r=R.recognizeScreen('codex',fs.readFileSync('$SCREENS/$1.txt','utf8'),'$2');console.log(JSON.stringify({composer:r.composer,prompt:r.prompt,ids:R.promptOptions('codex',r.prompt,r.block,{cwd:'/c',configPath:'/p',codexHome:'/h',trustRoot:'/c'}).map(o=>o.id).join()}))"
}
is_seen() { [ "$(seen "$1" "$2")" = "$3" ]; }
NOPE='{"composer":false,"prompt":null,"ids":""}'
check "K17: E11's verbatim approval capture under blocked: approval, [approve, deny] (deny over the wrapped (esc) line)" 'is_seen approval-e8 blocked "{\"composer\":false,\"prompt\":\"approval\",\"ids\":\"approve,deny\"}"'
check "K17: E11's verbatim login capture under idle: login, [sign-in]" 'is_seen login-e8 idle "{\"composer\":false,\"prompt\":\"login\",\"ids\":\"sign-in\"}"'
check "K17: the trust dialog from source at 52 columns under idle: trust-dialog, [trust, distrust]" 'is_seen trust-52 idle "{\"composer\":false,\"prompt\":\"trust-dialog\",\"ids\":\"trust,distrust\"}"'
check "K17: the verbatim trust dialog captured live (codex-cli 0.154.0-alpha.6.2, an untrusted non-git cwd) under idle: trust-dialog, [trust, distrust]" 'is_seen trust-live idle "{\"composer\":false,\"prompt\":\"trust-dialog\",\"ids\":\"trust,distrust\"}"'
check "K17: ...and under Herdr blocked, which the trust dialog never is: no match" 'is_seen trust-live blocked "$NOPE"'
COMPOSER='{"composer":true,"prompt":null,"ids":""}'
for f in composer-e12a composer-e12b composer-after-turn composer-plain composer-guillemet composer-followup composer-transcript composer; do
  check "K17: $f is the composer" 'is_seen $f idle "$COMPOSER"'
done
check "K17: the composer under Herdr working or blocked is not the composer" 'is_seen composer-e12a working "$NOPE" && is_seen composer-e12a blocked "$NOPE"'
for f in composer-typed composer-2footer composer-padding hooks-review update-prompt model-migration blank; do
  check "K17: $f matches nothing" 'is_seen $f idle "$NOPE"'
  setup_deliver
  hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@$f\"}}}"
  r "" deliver myrepo-architect --req "$REQ"
  check "K17: ...so deliver sends nothing: blocked, harness-prompt, options [], sent false, after a second read" '[ "$(jo o.status)" = blocked ] && [ "$(jo o.blocked_by)" = harness-prompt ] && [ "$(jo "o.options.length")" = 0 ] && [ "$(jo o.sent)" = false ] && [ "$(calls prompt)" -eq 0 ] && [ "$(calls read)" -eq 2 ] && [ ! -f "$RESP" ]'
done
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer-transcript\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K17: transcript text naming prompts above a recognised composer does not block: deliver sends" '[ "$(calls prompt)" -eq 1 ] && [ "$(jo o.sent)" = true ]'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:[\"@blank\",\"@composer-e12b\"]}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K17: a screen that is not yet the composer is read once more, and a composer then sends" '[ "$(calls prompt)" -eq 1 ] && [ "$(jo o.sent)" = true ]'
for gs in 'working busy' 'idle busy' 'blocked blocked'; do
  read -r GST WANT <<<"$gs"
  setup_deliver
  hs "{agents:{\"myrepo-architect\":{gets:[$IDLE,{agent_status:\"$GST\",interactive_ready:false}],visible:[\"@blank\",\"@composer-e12b\"]}}}"
  r "" deliver myrepo-architect --req "$REQ" --timeout 1
  check "K17: Herdr is read again with the screen: the composer on the re-read with Herdr now $GST and not ready sends nothing, and is $WANT with Herdr's fresh status" '[ "$(jo o.status)" = "$WANT" ] && [ "$(jo o.agent_status)" = "$GST" ] && [ "$(calls prompt)" -eq 0 ] && [ "$(jo o.sent)" = false ] && [ ! -f "$RESP" ]'
done
k13 none "{gets:[$IDLE,{agent_status:\"working\",interactive_ready:false}],visible:[\"@blank\",\"@composer-e12b\"]}"
check "K17: at spawn, the composer on the re-read with Herdr now working is not the composer: a harness-prompt blocked object, nothing sent" '[ "$RC" -eq 0 ] && [ "$(jo o.blocked.blocked_by)" = harness-prompt ] && [ "$(jo "o.blocked.options.length")" = 0 ] && [ "$(calls send-keys)" -eq 0 ] && [ "$(calls prompt)" -eq 0 ]'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@hooks-review\"}}}"
r "" deliver myrepo-architect --req "$REQ" --wait-only
check "K17: --wait-only has no composer check: on Hooks need review, with no response file, it is not-sent" '[ "$(jo o.status)" = not-sent ] && [ "$(calls prompt)" -eq 0 ]'
k13 "$UNTRUSTED" "{gets:[$IDLE],visible:\"@hooks-review\"}"
check "K17: at spawn, (a) untrusted and Hooks need review: the harness-cwd-untrusted refusal" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = harness-cwd-untrusted ] && [ "$(calls pane-close)" -eq 1 ]'
k13 "[projects.\"$PROJ\"]
trust_level = \"trusted\"" "{gets:[$IDLE],visible:\"@hooks-review\"}"
check "K17: ...(a) trusted: launched, with a harness-prompt blocked object, options [], no keys sent" '[ "$RC" -eq 0 ] && [ "$(jo o.spawned)" = true ] && [ "$(jo o.blocked.blocked_by)" = harness-prompt ] && [ "$(jo "o.blocked.options.length")" = 0 ] && [ "$(calls send-keys)" -eq 0 ] && [ "$(calls pane-close)" -eq 0 ]'

check "K17: wrap grammar — a column-0 line inside an approval block: no match" 'is_seen approval-col0 blocked "$NOPE"'
check "K17: wrap grammar — option 2's 5-space continuation echoing the trust options and footer: still approval, [approve, deny]" 'is_seen approval-echo blocked "{\"composer\":false,\"prompt\":\"approval\",\"ids\":\"approve,deny\"}"'
check "K17: wrap grammar — a continuation with 4 leading spaces: no match" 'is_seen approval-4sp blocked "$NOPE"'
check "K17: wrap grammar — a column-0 line straight after a blank line in the login block: no match" 'is_seen login-col0-blank idle "$NOPE"'
check "K17: wrap grammar — option 1 without a blank line above it: no match" 'is_seen approval-noblank1 blocked "$NOPE"'
check "K17: wrap grammar — a wrapped footer: no match" 'is_seen approval-wrapfooter blocked "$NOPE"'
check "K17: strict — a line added between the options and the footer: no match" 'is_seen approval-extra blocked "$NOPE"'
check "K17: strict — a footer that is not the last non-blank line: no match" 'is_seen approval-trailing blocked "$NOPE"'
check "K17: strict — a footer that is not the prompt's own (Hooks need review's): no match" 'is_seen approval-otherfooter blocked "$NOPE"'
check "K17: strict — two marked options: no match" 'is_seen approval-twomarks blocked "$NOPE"'
check "K17: strict — a label outside the prompt's set: no match" 'is_seen approval-other-first blocked "$NOPE"'
check "K17: strict — the trust layout under Herdr blocked: no match" 'is_seen trust-52 blocked "$NOPE"'
check "K17: strict — the approval layout under Herdr idle: no match" 'is_seen approval-e8 idle "$NOPE"'
check "K17: strict — another prompt's heading anywhere on screen: no match" 'is_seen approval-otherhead blocked "$NOPE" && is_seen approval-editshead blocked "$NOPE"'
check "K17: distrust is offered only where its line reads 2. No, quit (and trust only as 1.)" 'is_seen trust-swapped idle "{\"composer\":false,\"prompt\":\"trust-dialog\",\"ids\":\"\"}"'
PH=$(screen_hash approval-probe)
k15 approval-probe
r "" deliver myrepo-architect --req "$REQ"
check "K17: the probe — an approval whose command echoes the trust dialog is harness-prompt, options []" '[ "$(jo o.blocked_by)" = harness-prompt ] && [ "$(jo "o.options.length")" = 0 ] && [ "$(jo o.screen_hash)" = "$PH" ]'
r "" answer myrepo-architect --prompt trust-dialog --choice distrust --screen-hash "$PH"
check "K17: ...and answer --prompt trust-dialog against it is screen-changed, with nothing sent" '[ "$(jo o.status)" = screen-changed ] && [ "$(jo o.blocked_by)" = harness-prompt ] && [ "$(calls send-keys)" -eq 0 ]'

# deliver's wait, sent, not-sent and the skeleton
W='{agent_status:"working",interactive_ready:false}'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$W,$W,{agent_status:\"done\",interactive_ready:true}],visible:\"@composer\",onPrompt:{append:\"$RESP\",text:\"- [done] r\\n\"}}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K17: working for 2 polls, then done: the brief waits, then is sent" '[ "$(jo o.status)" = reported ] && [ "$(jo o.sent)" = true ] && [ "$(calls get)" -ge 3 ] && [ "$(calls prompt)" -eq 1 ]'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[{agent_status:\"idle\",interactive_ready:false},$IDLE],visible:\"@composer\"}}}"
r "" deliver myrepo-architect --req "$REQ"
check "K17: idle but not ready, then ready: it waits, then sends" '[ "$(jo o.sent)" = true ] && [ "$(calls get)" -ge 2 ] && [ "$(calls prompt)" -eq 1 ]'
setup_deliver
hs "{agents:{\"myrepo-architect\":{gets:[$IDLE],visible:\"@composer\"}}}"
r "" deliver myrepo-architect --req "$REQ" --wait-only
check "K17: --wait-only with no response file: not-sent, sent false, nothing waited on or sent" '[ "$(jo o.status)" = not-sent ] && [ "$(jo o.sent)" = false ] && [ "$(calls wait)" -eq 0 ] && [ "$(calls prompt)" -eq 0 ]'
r "" deliver myrepo-architect --req "$REQ"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],fs.readFileSync(process.argv[1],"utf8").replace(/\n*$/,"   \n\n  \t\n\n"))' "$RESP"
r "" deliver myrepo-architect --req "$REQ" --wait-only
check "K17: --wait-only on an idle member is evaluated at once, with no herdr agent wait" '[ "$(calls wait)" -eq 0 ] && [ "$(calls prompt)" -eq 1 ] && [ "$(jo o.sent)" = false ]'
check "K17: a response body equal to the skeleton plus trailing whitespace is no-report" '[ "$(jo o.status)" = no-report ]'

# the re-spawn command for a member no roster row derives
setup_deliver
team_file "[$CODEX_ARCH,$CODEX_UA,{\"role\":\"reviewer\",\"name\":\"myrepo-reviewer-9\",\"kind\":\"codex\",\"route\":\"pane\",\"model\":\"gpt-6-astra\",\"autoMode\":\"acceptEdits\",\"transport_id\":\"p7\"}]"
mkreq "t$((++REQN))" reviewer myrepo-reviewer-9
hs '{agents:{}}'
r "" deliver myrepo-reviewer-9 --req "$REQ"
check "K17: not-live for an ad hoc codex member: spawn-ad-hoc with its recorded kind, model, route and auto-mode, and a spawn_note" '[ "$(jo o.status)" = not-live ] && jo o.spawn | grep -q "roster.mjs spawn-ad-hoc reviewer --kind codex --model gpt-6-astra --route pane --auto-mode acceptEdits --cwd $PROJ$" && jo o.spawn_note | grep -q "may come back different"'

# an advise member of a kind with no model mapping
rm -rf "$HIER"; rm -f "$CFG"; reset_state
r "" init --level repo --route pane
r "" add --role ultra-advisor --kind pi --route pane
check "K17: add --role ultra-advisor --kind pi exits 2 with the no-model-mapping message" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -qF "\`pi\` has no model mapping, so its model cannot be set or declared. Use claude, or a kind with a model mapping (codex)."'
roster_cfg '[{"role":"ultra-advisor","kind":"pi","route":"pane"}]'
r "HERDR_ENV=1" spawn-one ultra-advisor
panes_split() { local c; c=$(grep -c '"pane","split"' "$FAKE_STATE_DIR/calls.jsonl" 2>/dev/null); echo "${c:-0}"; }
check "K17: a hand-written pi Ultra-Advisor row is refused at spawn: advise-model-tier, model/declared_tier/rerun_declare null, no pane" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = advise-model-tier ] && [ "$(jo o.model)" = null ] && [ "$(jo o.declared_tier)" = null ] && [ "$(jo o.rerun_declare)" = null ] && [ "$(calls start)" -eq 0 ] && [ "$(panes_split)" = 0 ]'
r "HERDR_ENV=1" create --spawn
check "K17: ...and at create" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = advise-model-tier ] && [ "$(jo o.model)" = null ] && [ "$(calls start)" -eq 0 ]'

# the contract file
rm -rf "$HIER"; reset_state
cp "$FAKEHOME/.claude/plugins/installed_plugins.json" "$SANDBOX/installed.bak"
echo '{"version":2,"plugins":{"ah@local":[{"installPath":"/nonexistent/ah"}]}}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
roster_cfg '[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"}]'
r "HERDR_ENV=1" spawn-one architect
check "K17: a built-in role's contract is read from the running plugin, with the install record pointing elsewhere" '[ "$RC" -eq 0 ] && grep -qF -- "$BODY_LINE" "$HIER/instructions/myrepo-architect.md"'
cp "$SANDBOX/installed.bak" "$FAKEHOME/.claude/plugins/installed_plugins.json"
rm -rf "$HIER"; reset_state
printf '{"version":1,"enabled":true,"roles":{"auditor":{"class":"review","agent":"auditor","label":"Auditor"}},"roster":{"route":"pane","members":[{"role":"auditor","kind":"codex","route":"pane","model":"gpt-6-astra"}]}}\n' > "$CFG"
r "HERDR_ENV=1" spawn-one auditor
check "K17: a custom role whose agent file is missing: agent-file-not-found, before any pane opens" '[ "$RC" -eq 2 ] && [ "$(jo o.refused)" = agent-file-not-found ] && [ "$(jo o.member)" = myrepo-auditor ] && [ "$(jo o.role)" = auditor ] && [ "$(jo o.ref)" = auditor ] && [ "$(calls start)" -eq 0 ] && [ "$(panes_split)" = 0 ]'
rm -rf "$HIER"; reset_state
printf '{"version":1,"enabled":true,"roles":{"auditor":{"class":"review","agent":"auditor","label":"Auditor"}},"roster":{"route":"pane","members":[{"role":"architect","kind":"codex","route":"pane","model":"gpt-6-astra"},{"role":"auditor","kind":"codex","route":"pane","model":"gpt-6-astra"}]}}\n' > "$CFG"
r "HERDR_ENV=1" create --spawn
check "K17: ...under create --spawn, a failed launch whose launch_result.refused is agent-file-not-found" '[ "$(jo "o.members.find(m=>m.name===\"myrepo-auditor\").launch_status")" = failed ] && [ "$(jo "o.members.find(m=>m.name===\"myrepo-auditor\").launch_result.refused")" = agent-file-not-found ] && [ "$(jo "o.members.find(m=>m.name===\"myrepo-auditor\").launch_result.reason")" = refused ]'

# pane-level input and the unparsed deliver
setup_deliver
team_file "[$CODEX_ARCH,$CODEX_UA,$CLAUDE_REV,$CLAUDE_UA2]"
mkreq ua2 ultra-advisor myrepo-ultra-advisor
for c in "herdr pane send-keys p1 1" "herdr pane send-text p1 x" "herdr pane run p1 x" "herdr agent send-keys p1 1" "herdr agent attach myrepo-architect" "herdr terminal session control myrepo-architect"; do
  hg "$c"
  check "K17: $c is denied (a codex member, by name or pane id)" 'denied'
done
hg "herdr pane read p1"
check "K17: herdr pane read <codex member's pane> passes" 'silent'
for c in "$(printf 'herdr \\\n  pane send-keys p1 1')" "$(printf 'herdr pane send-keys \\\n  p1 1')" "\"herdr\" pane send-keys p1 1" "'herdr' pane send-text p1 x"; do
  hg "$c"
  check "K17: $c is denied (a continued line, or a quoted command word)" 'denied'
done
hg "$(printf 'herdr pane read \\\n  p1')"
check "K17: ...while a continued pane read still passes" 'silent'
decide_gate session
ug "herdr pane send-text p2 x"
check "K17: pane send-text to a codex Ultra-Advisor's pane is denied under session" 'denied'
ug "herdr pane send-keys p4 1"
check "K17: pane send-keys with one key to a Claude Ultra-Advisor's pane passes the ultra-gate" 'silent'
ug "herdr pane send-keys p4 1 2"
check "K17: ...two keys are denied" 'denied'
ug "herdr pane read p2"
check "K17: pane read passes the ultra-gate" 'silent'
rm -f "$HOOK_LOG"
for hook in pretooluse-herdr-name-gate.mjs pretooluse-ultra-gate.mjs; do
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"herdr pane read p1 && herdr pane list && ls"}}))' "$PROJ" | HOME="$FAKEHOME" node --import "$THROWS" "$H/$hook" 2>&1); RC=$?
  check "K17: $hook reads no config for a Bash call with none of the input verbs" 'silent && [ ! -s "$HOOK_LOG" ]'
done
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"herdr pane send-keys p1 1"}}))' "$PROJ" | HOME="$FAKEHOME" node --import "$THROWS" "$H/pretooluse-herdr-name-gate.mjs" 2>&1); RC=$?
check "K17: ...where pane send-keys does reach it (control: the injected throw is logged)" 'grep -q "injected by tests/fixtures/resolve-config-throws.mjs" "$HOOK_LOG"'
for shape in "cd /x && node roster.mjs deliver myrepo-ultra-advisor --req r --cwd /x" "FOO=1 node $H/roster.mjs deliver myrepo-ultra-advisor --req $REQ --cwd $PROJ" "node ./hooks/roster.mjs deliver myrepo-ultra-advisor --req $REQ --cwd $PROJ; true"; do
  decide_gate each; ug "$shape"
  check "K17: unparsed deliver to the Ultra-Advisor asks under each: $shape" 'asked'
  decide_gate off; ug "$shape"
  check "K17: ...and is denied under off" 'denied'
  ug "${shape//myrepo-ultra-advisor/myrepo-architect}"
  check "K17: ...while the same shape to a non-advise member passes" 'silent'
done

########################################################################
# K9 — text
########################################################################
SK="$PLUGIN/skills/agent-team/SKILL.md"
check "K9: directive item 13 names deliver" 'grep -q "brief it with \\\\\`roster.mjs deliver\\\\\` in the background, never SendMessage" "$H/lib-config.mjs" && grep -q "roster.mjs deliver" "$PLUGIN/tests/fixtures/0056-i1/golden/directive-auto.txt"'
check "K9: orchestrator.md names deliver, within its 7350-byte budget" 'grep -q "roster.mjs deliver <name>" "$PLUGIN/agents/orchestrator.md" && [ "$(wc -c < "$PLUGIN/agents/orchestrator.md")" -le 7350 ]'
check "K9: SKILL.md has the stall mapping" 'grep -q "is pinged with \`deliver --ping <n>\`" "$SK" && grep -q "\`busy\`, \`timeout\`, \`not-sent\` and \`blocked\` never count" "$SK"'
check "K9: SKILL.md's status table: busy re-runs the same command, and not-sent sends the brief" 'grep -q "^| \`busy\` | still working or not ready at \`--timeout\`; nothing was sent | re-run the \*\*same\*\* command |" "$SK" && grep -q "^| \`not-sent\` |.*| send the brief, without \`--wait-only\` |" "$SK"'
check "K9: SKILL.md: after answered, the re-run depends on sent" 'grep -q "the \*\*same\*\* command if it had \`sent: false\`, with \`--wait-only\`" "$SK"'
check "K9: SKILL.md: no brief after sign-in until the user says it finished" 'grep -q "Send that member nothing until the user says the sign-in" "$SK"'
check "K9: SKILL.md: a refused launch is handled by its refusal, never as a launch failure" 'grep -q "\`launch_result.reason\` of \`refused\`" "$SK" && grep -q "refused: .agent-file-not-found..: the role" "$SK"'
check "K9: SKILL.md: a harness-prompt over a plainly idle composer means the recognizer is out of date" 'grep -q "the composer recognizer is out of date" "$SK"'
check "K9: SKILL.md has the relay steps" 'grep -q "^### Relaying a prompt" "$SK" && grep -q "header \`Codex prompt\`" "$SK" && grep -q "\`screen\` \*\*verbatim\*\*" "$SK" && grep -q "Free text is never" "$SK"'
check "K9: SKILL.md: a granting option is sent only after the user picked it in AskUserQuestion" 'grep -q "sent only after the user picked it in that AskUserQuestion" "$SK"'
check "K9: SKILL.md has the two-strikes rule, the distrust step (no wait, no brief), and never copying a URL out of screen" 'grep -q "\*\*Two strikes:\*\*" "$SK" && grep -q "\`distrust\`: no wait and no brief" "$SK" && grep -q "never copy a URL" "$SK"'

echo
echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
