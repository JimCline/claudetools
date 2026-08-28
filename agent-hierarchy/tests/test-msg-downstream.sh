#!/bin/bash
# agent-hierarchy — spec 0026 §4: downstream-dispatch visibility.
# `listDownstreamDispatches` (lib-hier.mjs), `msg.mjs downstream`, the
# `downstream:` section in `msg.mjs list`, and the msg_downstream MCP tool.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-msg-downstream.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-msg-downstream-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" "$@" 2>&1); RC=$?; }
mk_req() { # <to> <from> <slug> <from-name> <to-name> [--parent <id>] -> sets ID/PATH
  local to=$1 from=$2 slug=$3 fname=$4 tname=$5; shift 5
  msg new --to "$to" --from "$from" --slug "$slug" --from-name "$fname" --to-name "$tname" "$@"
  ID=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.id)' "$OUT")
  REQPATH=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.path)' "$OUT")
}
mk_req_noname() { # <to> <from> <slug> <to-name> [--parent <id>] -> sets ID (no --from-name passed)
  local to=$1 from=$2 slug=$3 tname=$4; shift 4
  msg new --to "$to" --from "$from" --slug "$slug" --to-name "$tname" "$@"
  ID=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(o.id)' "$OUT")
}
row_field() { # <id> <field> -- prints the JSON value of <field> on the downstream row for <id>, or MISSING
  echo "$OUT" | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      const arr=JSON.parse(s); const [id,f]=process.argv.slice(1);
      const r=arr.find(x=>x.id===id);
      process.stdout.write(r?JSON.stringify(r[f]):"MISSING");
    });' "$1" "$2"
}

# ---- item 14: empty msgs/ dir -> listDownstreamDispatches empty, list prints no downstream: header
msg downstream --plain
check "14: empty msgs dir, downstream --plain: empty output" '[ -z "$OUT" ]'
msg downstream
check "14: empty msgs dir, downstream (json): empty array" '[ "$OUT" = "[]" ]'
msg list --plain
check "14: empty msgs dir, list --plain: no downstream: header" '! echo "$OUT" | grep -q "downstream:"'

# ---- item 9: worked example (spec §4.1) -> exactly one downstream row
mk_req ultra-advisor orchestrator root-brief bear-poppa-promo-3b bps-ultra-advisor
ROOT_ID=$ID
mk_req implementor ultra-advisor relay bps-ultra-advisor bps-implementor --parent "$ROOT_ID"
DISPATCH_ID=$ID
msg downstream
check "9: exactly one downstream row" '[ "$(echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" = 1 ]'
check "9: root_from_name is the orchestrator's name, from_name is the ultra-advisor's" \
  'echo "$OUT" | grep -q "\"root_from_name\":\"bear-poppa-promo-3b\"" && echo "$OUT" | grep -q "\"from_name\":\"bps-ultra-advisor\""'
msg downstream --plain
check "9: plain line matches the spec shape" \
  'echo "$OUT" | grep -qF "bear-poppa-promo-3b → bps-ultra-advisor → implementor: relay  (id $DISPATCH_ID, parent $ROOT_ID)"'

# ---- item 10: an Orchestrator's own follow-up parented to its own earlier request -> zero rows
mk_req reviewer orchestrator r2 orch-self peer-a
R2_ID=$ID
mk_req reviewer orchestrator r2-follow orch-self peer-b --parent "$R2_ID"
FOLLOW_ID=$ID
msg downstream
check "10: own follow-up (same from_name as root) contributes no row" '! echo "$OUT" | grep -q "\"id\":\"$FOLLOW_ID\""'

# ---- item 10a (§4.1 condition 2, explicit): parentless request, no from_name -> zero rows.
# OUTCOME assertion, not falsifiable against the current implementation: rootOf returns the
# message's own frontmatter object for a parentless message, so any sender comparison is
# reflexive and excludes it regardless. Guards a FUTURE change where rootOf stops
# self-referencing — item 10e pins that dependency directly.
mk_req_noname reviewer orchestrator root-10a peer-e
R10A_ID=$ID
msg downstream
check "10a: parentless, unnamed sender -> no row" '! echo "$OUT" | grep -q "\"id\":\"$R10A_ID\""'

# ---- item 10b: root unnamed, descendant named, different roles -> exactly one row,
# root_from_name null, root_from the root's role, identity role-only.
mk_req_noname reviewer orchestrator root-10b peer-f
R10B_ROOT=$ID
mk_req implementor reviewer desc-10b named-desc peer-g --parent "$R10B_ROOT"
R10B_DESC=$ID
msg downstream
check "10b: row present" '[ "$(row_field "$R10B_DESC" id)" != "MISSING" ]'
check "10b: root_from_name null, root_from is the root's role, identity role-only" \
  '[ "$(row_field "$R10B_DESC" root_from_name)" = "null" ] && [ "$(row_field "$R10B_DESC" root_from)" = "\"orchestrator\"" ] && [ "$(row_field "$R10B_DESC" identity)" = "\"role-only\"" ]'

# ---- item 10c: root unnamed AND descendant unnamed, different roles -> exactly one row,
# identity role-only. THE FALSE NEGATIVE BEING CLOSED: pre-fix, this returns zero rows.
mk_req_noname reviewer orchestrator root-10c peer-h
R10C_ROOT=$ID
mk_req_noname implementor reviewer desc-10c peer-i --parent "$R10C_ROOT"
R10C_DESC=$ID
msg downstream
check "10c: unnamed root + unnamed descendant, different roles -> row present" '[ "$(row_field "$R10C_DESC" id)" != "MISSING" ]'
check "10c: identity role-only" '[ "$(row_field "$R10C_DESC" identity)" = "\"role-only\"" ]'
msg downstream --plain
check "10c: plain-text output tags the role-only row" 'echo "$OUT" | grep -q "id $R10C_DESC.*, role-only)"'

# ---- item 10d: root unnamed AND descendant unnamed, SAME role -> zero rows (§4.1 known residual).
mk_req_noname reviewer orchestrator root-10d peer-j
R10D_ROOT=$ID
mk_req_noname reviewer orchestrator desc-10d peer-k --parent "$R10D_ROOT"
R10D_DESC=$ID
msg downstream
check "10d: unnamed root + unnamed descendant, same role -> no row" '! echo "$OUT" | grep -q "\"id\":\"$R10D_DESC\""'

# ---- item 10e: rootOf's self-reference contract, isolated (unit-level, falsifiable). For a
# parentless message, rootOf(byId, id).fm must be the SAME REFERENCE as byId.get(id) -- items 10a
# and the root.id === id guard both silently depend on this.
ROOTOF_OUT=$(node -e '
  import("'"$H"'/lib-hier.mjs").then((L) => {
    const byId = new Map([["x", { parent: null, from: "a", from_name: null }]]);
    const root = L.rootOf(byId, "x");
    process.stdout.write(String(root.fm === byId.get("x")));
  });')
check "10e: rootOf returns the SAME fm reference for a parentless message" '[ "$ROOTOF_OUT" = "true" ]'

# ---- item 11: a response file sharing an id with a request -> zero rows from it
msg new --type response --id "$ROOT_ID"
check "11: response created" '[ $RC -eq 0 ]'
msg downstream
check "11: response id never appears as its own downstream row (only request-typed files are walked)" \
  '[ "$(echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).filter(r=>r.id===\"$ROOT_ID\").length))")" = 0 ]'

# ---- item 12: a message whose parent names a nonexistent id -> zero rows, no throw
mk_req reviewer orchestrator badparent ghost-session peer-c --parent 20990101-000000-zzzz
BADPARENT_ID=$ID
msg downstream
check "12: nonexistent-parent message contributes no row" '[ $RC -eq 0 ] && ! echo "$OUT" | grep -q "\"id\":\"$BADPARENT_ID\""'

# ---- item 13: a hand-made cycle (A.parent=B, B.parent=A) -> zero rows, no throw, call returns
CYC_A=20990102-010101-cyca
CYC_B=20990102-020202-cycb
node -e '
  const fs = require("fs");
  const [dir, aId, bId] = process.argv.slice(1);
  const fm = (f) => ["---", ...Object.entries(f).map(([k,v]) => `${k}: ${v === null ? "null" : v}`), "---", ""].join("\n");
  fs.writeFileSync(`${dir}/${aId}--reviewer--cyc-a--request.md`, fm({
    id: aId, type: "request", to: "reviewer", from: "orchestrator", slug: "cyc-a",
    parent: bId, reason: "null", to_name: "peer-a", from_name: "cycler-a", team: "null", created: "2026-01-01T00:00:00-00:00",
  }) + "\n## [0] tldr\n- none\n");
  fs.writeFileSync(`${dir}/${bId}--reviewer--cyc-b--request.md`, fm({
    id: bId, type: "request", to: "reviewer", from: "orchestrator", slug: "cyc-b",
    parent: aId, reason: "null", to_name: "peer-b", from_name: "cycler-b", team: "null", created: "2026-01-01T00:00:01-00:00",
  }) + "\n## [0] tldr\n- none\n");
' "$HD/msgs" "$CYC_A" "$CYC_B"
msg downstream
check "13: cycle terminates (no timeout/hang) — call returned" '[ $RC -eq 0 ]'
check "13a: different from_names on both cycle members, still zero rows (genuinely exercises cycle handling, not name-equality)" \
  '! echo "$OUT" | grep -qE "\"id\":\"($CYC_A|$CYC_B)\""'

# ---- item 13b: a parent chain longer than the 32-hop cap, deepest from_name differing from the
# head's -> zero rows (the cap's termination path, distinct from an actual cycle)
DEEP_ID=$(node -e '
  const fs = require("fs");
  const dir = process.argv[1];
  const fm = (f) => ["---", ...Object.entries(f).map(([k,v]) => `${k}: ${v === null ? "null" : v}`), "---", ""].join("\n");
  const N = 40; // > 32-hop cap
  let parent = null;
  let deepId = null;
  for (let i = 0; i < N; i++) {
    const id = `20990103-000${String(i).padStart(3,"0")}-d${String(i).padStart(3,"0")}`.slice(0,20);
    fs.writeFileSync(`${dir}/${id}--reviewer--deep-${i}--request.md`, fm({
      id, type: "request", to: "reviewer", from: "orchestrator", slug: `deep-${i}`,
      parent, reason: "null", to_name: "peer-d", from_name: `deep-${i}`,
      team: "null", created: `2026-01-02T00:00:${String(i).padStart(2,"0")}-00:00`,
    }) + "\n## [0] tldr\n- none\n");
    parent = id;
    deepId = id;
  }
  process.stdout.write(deepId);
' "$HD/msgs")
msg downstream
check "13b: depth-cap-exhausted chain (40 hops > 32 cap): zero rows" '! echo "$OUT" | grep -q "\"id\":\"$DEEP_ID\""'

# ---- --root-name filter
msg downstream --root-name bear-poppa-promo-3b
check "root-name filter: only rows rooted at the named session" \
  'echo "$OUT" | grep -q "bps-ultra-advisor" && [ "$(echo "$OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))")" = 1 ]'
msg downstream --root-name nobody-ever
check "root-name filter: no match -> empty array" '[ "$OUT" = "[]" ]'

# ---- msg.mjs list integration: downstream: section appended only when non-empty
msg list --all --plain
check "list --all --plain: downstream: section present with the worked-example row" \
  'echo "$OUT" | grep -q "downstream:" && echo "$OUT" | grep -qF "bear-poppa-promo-3b → bps-ultra-advisor → implementor: relay"'
msg list --all
check "list --all (json): includes both exchanges and downstream keys" \
  'echo "$OUT" | grep -q "\"exchanges\":" && echo "$OUT" | grep -q "\"downstream\":"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
