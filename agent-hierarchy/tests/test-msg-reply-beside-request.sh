#!/bin/bash
# agent-hierarchy — spec 0037: a response lands beside its request. `msg.mjs new --type response
# --req <abs request path>` writes into the request's own msgs dir regardless of the responder's
# resolved pool; without --req, a response whose request is absent from the resolved pool is a loud
# hard failure (nothing written) rather than a file the requester never sees.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-msg-reply-beside-request.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SERVER="$PLUGIN/mcp/server.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-reply-beside-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

# Fixture: main checkout with a registered worktree, plus a non-repo scratch dir. Requests are always
# minted in MAIN's pool; responders run from elsewhere.
MAIN="$SANDBOX/main"; WT="$SANDBOX/wt"; NONREPO="$SANDBOX/nonrepo"
mkdir -p "$MAIN/.claude" "$NONREPO"
(cd "$MAIN" && git init -q && git config user.email t@t.com && git config user.name t && git commit -q --allow-empty -m init)
git -C "$MAIN" worktree add -q "$WT" -b wt-branch >/dev/null
mkdir -p "$WT/.claude"
MAIN_MSGS="$MAIN/.claude/hierarchy/msgs"

mcli() { # <cwd> <msg.mjs argv...>
  local at=$1; shift
  OUT=$(HOME="$FAKEHOME" node "$H/msg.mjs" "$@" --cwd "$at" 2>&1); RC=$?
}
json_path() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const l=s.split("\n").find(x=>x.startsWith("{"));process.stdout.write(JSON.parse(l).path)})'; }
mint_request() { # <slug> -> sets REQ (abs path) and ID
  mcli "$MAIN" new --to implementor --from orchestrator --to-name main-implementor --from-name main-orchestrator --slug "$1"
  REQ=$(printf '%s' "$OUT" | json_path); ID=$(basename "$REQ" | cut -d- -f1-3)
}
pool_of() { HOME="$FAKEHOME" node -e 'import("'"$H"'/lib-hier.mjs").then(m=>process.stdout.write(m.hierarchyDir(process.argv[1])))' "$1"; }
responses_under() { find "$1" -name '*--response.md' 2>/dev/null | wc -l | tr -d ' '; }

# ---- T1: responder in the WORKTREE with --req -> file beside the request in MAIN; worktree pool has
# no copy. Mutation: fails against an implementation that resolves the destination from cwd. ----
mint_request t1
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ"
WT_POOL=$(pool_of "$WT")
check "T1: worktree responder with --req exits 0" '[ "$RC" -eq 0 ]'
check "T1: response exists in MAIN's msgs dir" '[ -f "$MAIN_MSGS/$ID--orchestrator--t1--response.md" ]'
check "T1: worktree pool holds no copy" '[ "$WT_POOL" != "$MAIN/.claude/hierarchy" ] && [ "$(responses_under "$WT_POOL")" = "0" ]'
check "T1: exactly one response file anywhere in the sandbox" '[ "$(responses_under "$SANDBOX")" = "1" ]'

# ---- T2: responder cwd is a non-repo dir (vector c). ----
mint_request t2
mcli "$NONREPO" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ"
NR_POOL=$(pool_of "$NONREPO")
check "T2: non-repo responder with --req exits 0" '[ "$RC" -eq 0 ]'
check "T2: response exists in MAIN's msgs dir" '[ -f "$MAIN_MSGS/$ID--orchestrator--t2--response.md" ]'
check "T2: non-repo pool holds no copy" '[ "$(responses_under "$NR_POOL")" = "0" ]'

# ---- T3: no --req, request absent from the resolved pool -> exit non-zero, stderr names the resolved
# dir and the --req remedy, nothing written. ----
mint_request t3
BEFORE=$(responses_under "$SANDBOX")
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor
check "T3: no --req + request absent exits non-zero" '[ "$RC" -ne 0 ]'
check "T3: stderr names the resolved msgs dir" 'echo "$OUT" | grep -qF "$WT_POOL/msgs"'
check "T3: stderr names the --req remedy" 'echo "$OUT" | grep -q -- "--req <that path>"'
check "T3: nothing written anywhere" '[ "$(responses_under "$SANDBOX")" = "$BEFORE" ]'

# ---- T4: no --req, request IS in the resolved pool — the common local flow, untaxed. ----
mint_request t4
mcli "$MAIN" new --type response --id "$ID" --to orchestrator --from implementor
check "T4: local flow without --req exits 0" '[ "$RC" -eq 0 ]'
check "T4: response beside request in MAIN" '[ -f "$MAIN_MSGS/$ID--orchestrator--t4--response.md" ]'
check "T4: no divergence note for a same-pool write" '! echo "$OUT" | grep -q "written beside its request"'

# ---- T5: --req relative path -> exit non-zero, nothing written. ----
mint_request t5
BEFORE=$(responses_under "$SANDBOX")
mcli "$MAIN" new --type response --id "$ID" --to orchestrator --from implementor --req ".claude/hierarchy/msgs/$(basename "$REQ")"
check "T5: relative --req exits non-zero" '[ "$RC" -ne 0 ]'
check "T5: error says absolute" 'echo "$OUT" | grep -qi "absolute"'
check "T5: nothing written anywhere" '[ "$(responses_under "$SANDBOX")" = "$BEFORE" ]'

# ---- T6: --req naming a nonexistent file in a plausible dir -> exit non-zero, nothing written there. ----
mint_request t6
BEFORE=$(responses_under "$SANDBOX")
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --req "$MAIN_MSGS/$ID--implementor--typo--request.md"
check "T6: nonexistent --req exits non-zero" '[ "$RC" -ne 0 ]'
check "T6: error says no such file" 'echo "$OUT" | grep -q "no such file"'
check "T6: nothing written into that dir or anywhere" '[ "$(responses_under "$SANDBOX")" = "$BEFORE" ]'

# ---- T7: frontmatter mismatch — id differs; separately to ≠ request.from. Both values quoted. ----
mint_request t7
BEFORE=$(responses_under "$SANDBOX")
mcli "$WT" new --type response --id "20000101-000000-zzzz" --to orchestrator --from implementor --req "$REQ"
check "T7a: --id differing from the request's id exits non-zero" '[ "$RC" -ne 0 ]'
check "T7a: both ids quoted" 'echo "$OUT" | grep -qF "\"$ID\"" && echo "$OUT" | grep -qF "\"20000101-000000-zzzz\""'
mcli "$WT" new --type response --id "$ID" --to architect --from implementor --req "$REQ"
check "T7b: --to ≠ request.from exits non-zero" '[ "$RC" -ne 0 ]'
check "T7b: both values quoted" 'echo "$OUT" | grep -qF "\"architect\"" && echo "$OUT" | grep -qF "\"orchestrator\""'
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --to-name wrong-name --req "$REQ"
check "T7c: --to-name ≠ request.from_name exits non-zero, both quoted" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "\"wrong-name\"" && echo "$OUT" | grep -qF "\"main-orchestrator\""'
check "T7: nothing written by any mismatch" '[ "$(responses_under "$SANDBOX")" = "$BEFORE" ]'

# ---- T8: MCP msg_new with req_path, called from the worktree's cwd -> same as T1. ----
mint_request t8
OUT=$(HOME="$FAKEHOME" node --input-type=module -e '
  import { spawn } from "node:child_process";
  const [server, cwd, id, req] = process.argv.slice(1);
  const child = spawn(process.execPath, [server], { stdio: ["pipe", "pipe", "ignore"] });
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d;
    for (const line of buf.split("\n")) {
      if (!line.trim()) continue;
      let m; try { m = JSON.parse(line); } catch { continue; }
      if (m.id === 2) { process.stdout.write(JSON.stringify(m)); child.kill(); process.exit(0); }
    }
  });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }) + "\n");
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "msg_new", arguments: { cwd, type: "response", id, to: "orchestrator", from: "implementor", req_path: req } } }) + "\n");
  setTimeout(() => { process.stdout.write("TIMEOUT"); process.exit(1); }, 15000);
' "$SERVER" "$WT" "$ID" "$REQ" 2>&1); RC=$?
check "T8: MCP msg_new with req_path returns a result, not an error" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"result\"" && ! echo "$OUT" | grep -q "\"isError\":true"'
check "T8: response landed in MAIN's msgs dir" '[ -f "$MAIN_MSGS/$ID--orchestrator--t8--response.md" ]'
check "T8: worktree pool still holds no copy" '[ "$(responses_under "$WT_POOL")" = "0" ]'

# ---- T9: divergence info line — --req write from a divergent pool prints the one-line note; exit 0. ----
mint_request t9
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ"
check "T9: exit 0" '[ "$RC" -eq 0 ]'
check "T9: divergence note names both pools" 'echo "$OUT" | grep -q "written beside its request" && echo "$OUT" | grep -qF "$WT_POOL" && echo "$OUT" | grep -qF "$MAIN/.claude/hierarchy"'

# ---- T10: AGENT_HIERARCHY_DIR set for the responder only (vector d). With --req: lands beside the
# request. Without: T3's guard fires. ----
ENVDIR="$SANDBOX/envpool"; mkdir -p "$ENVDIR/msgs"
mint_request t10a
OUT=$(AGENT_HIERARCHY_DIR="$ENVDIR" HOME="$FAKEHOME" node "$H/msg.mjs" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ" --cwd "$MAIN" 2>&1); RC=$?
check "T10a: env-redirected responder with --req exits 0" '[ "$RC" -eq 0 ]'
check "T10a: response beside the request in MAIN, none in the env pool" '[ -f "$MAIN_MSGS/$ID--orchestrator--t10a--response.md" ] && [ "$(responses_under "$ENVDIR")" = "0" ]'
mint_request t10b
BEFORE=$(responses_under "$SANDBOX")
OUT=$(AGENT_HIERARCHY_DIR="$ENVDIR" HOME="$FAKEHOME" node "$H/msg.mjs" new --type response --id "$ID" --to orchestrator --from implementor --cwd "$MAIN" 2>&1); RC=$?
check "T10b: env-redirected responder without --req hits the guard" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "$ENVDIR/msgs" && echo "$OUT" | grep -q -- "--req"'
check "T10b: nothing written" '[ "$(responses_under "$SANDBOX")" = "$BEFORE" ]'

# ---- Duplicate: a second --req write for the same id is refused (§2.1.5). ----
mint_request dup
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ"
mcli "$WT" new --type response --id "$ID" --to orchestrator --from implementor --req "$REQ"
check "DUP: second --req response for the same id exits non-zero and says already exists" '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "already exists"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
