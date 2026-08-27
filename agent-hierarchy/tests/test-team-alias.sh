#!/bin/bash
# agent-hierarchy — team/repo naming alias (spec 0010 §3-§7). A `teamAlias` is
# a top-level sibling of `roster` in the repo/repo-user config, read only at
# those two levels (never global — an alias is a property of one repo, not a
# machine-wide default) and resolved by ONE function, `teamPrefix`/
# `teamPrefixInfo`, that every member-naming call site now goes through.
# Usage: bash tests/test-team-alias.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
NODE_BIN="$(command -v node)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-alias-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$PROJ/sub/dir"
(cd "$PROJ" && git init -q)
BASE="$(basename "$PROJ")"

REPO_PATH="$PROJ/.claude/agent-hierarchy.json"
GLOBAL_PATH="$FAKEHOME/.claude/agent-hierarchy.json"
REPO_USER_PATH="$FAKEHOME/.claude/agent-hierarchy/projects/$(echo "$PROJ" | sed 's#/#-#g')/agent-hierarchy.json"
HIER_DIR="$PROJ/.claude/hierarchy"
TEAM_FILE="$HIER_DIR/team.json"

reset_levels() { rm -f "$REPO_PATH" "$GLOBAL_PATH" "$REPO_USER_PATH"; rm -rf "$HIER_DIR"; }

write_level() { # <path> <json>
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

evalc() { # <js over lib-config as C>
  OUT=$(HOME="$FAKEHOME" "$NODE_BIN" --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}

run_roster() { # <roster.mjs args...> -> $OUT/$RC, HERDR_ENV unset
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" "$NODE_BIN" "$H/roster.mjs" "$@" 2>&1); RC=$?
}

# ==== 13 — subdirectory-cwd regression guard: teamPrefix from deep inside the
# repo still resolves via the git root, same as the old direct basename(cwd)
# call sites did before the unification. ====
reset_levels
evalc "C.teamPrefix('$PROJ/sub/dir')"
check "13a: teamPrefix from a subdirectory -> basename of the git root" '[ "$OUT" = "$BASE" ]'

# 13b — the same agreement proven from OUTSIDE lib-config.mjs: run the real
# pretooluse-route-gate.mjs hook as a subprocess from the subdirectory cwd,
# and confirm its own internally-computed prefix resolves a SendMessage `to`
# built from resolveRoster's derived peer name. This is the actual regression
# guard — it proves the two independently-invoked code paths agree, not just
# that a shared helper trivially equals itself when called twice.
write_level "$REPO_PATH" '{"version":1,"enabled":true,"roles":{"reviewer":{"model":"opus","dispatch":"peer"}}}'
ROUTE_GATE="$H/pretooluse-route-gate.mjs"
ROUTE_PAYLOAD=$(HOME="$FAKEHOME" "$NODE_BIN" -e '
  const [cwd, to, msg] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({
    session_id: "team-alias-test-13b",
    cwd, tool_name: "SendMessage",
    tool_input: { to, message: msg },
  }));
' "$PROJ/sub/dir" "$BASE-reviewer" '[hierarchy-peer-brief reply-to="me" task="x"]
plain')
OUT=$(echo "$ROUTE_PAYLOAD" | HOME="$FAKEHOME" "$NODE_BIN" "$ROUTE_GATE" 2>&1); RC=$?
check "13b: route-gate's derived prefix (subdir cwd) agrees with resolveRoster's" \
  'echo "$OUT" | grep -q "\"permissionDecision\":\"deny\""'

# ==== 27 — inventory completeness guard (amendment (c)): no hooks/ file
# spells the two known basename(cwd)-derivation forms any more; teamPrefix/
# teamPrefixInfo is the only place that should derive a prefix, from
# repoRoot. This is what would have caught site 10 (msg.mjs) originally, and
# what stops an eleventh site written in one of these exact two forms from
# being introduced silently later — it does not sweep every basename( call,
# so a differently-spelled reintroduction (e.g. basename(process.cwd()))
# would not be caught by this guard. ====
GREP_HITS=$(grep -rn 'basename(resolved\.cwd)\|basename(resolve(cwd))' "$H" 2>/dev/null)
check "27: no hooks/ file spells basename(resolved.cwd) or basename(resolve(cwd))" '[ -z "$GREP_HITS" ]'

# ==== 14 — alias set at repo level applies, even resolved from a subdirectory ====
reset_levels
write_level "$REPO_PATH" '{"teamAlias":"ct"}'
evalc "JSON.stringify(C.teamPrefixInfo('$PROJ/sub/dir'))"
check "14: repo-level teamAlias -> {prefix,alias:'ct',source:'repo'}" \
  '[ "$OUT" = "{\"prefix\":\"ct\",\"alias\":\"ct\",\"source\":\"repo\"}" ]'

# ==== 15 — repo-user precedence over repo when both set ====
reset_levels
write_level "$REPO_PATH" '{"teamAlias":"repolevel"}'
write_level "$REPO_USER_PATH" '{"teamAlias":"repouserlevel"}'
evalc "JSON.stringify(C.teamPrefixInfo('$PROJ'))"
check "15: repo-user teamAlias wins over repo" \
  '[ "$OUT" = "{\"prefix\":\"repouserlevel\",\"alias\":\"repouserlevel\",\"source\":\"repo-user\"}" ]'

# ==== 16 — a teamAlias at global/user scope is never consulted ====
reset_levels
write_level "$GLOBAL_PATH" '{"teamAlias":"globalalias"}'
evalc "C.teamPrefix('$PROJ')"
check "16: global-level teamAlias is ignored -> falls back to basename" '[ "$OUT" = "$BASE" ]'

# ==== 17 — invalid alias (bad character set) is ignored and warned about ====
reset_levels
write_level "$REPO_PATH" '{"teamAlias":"bad_alias!"}'
evalc "C.teamPrefixInfo('$PROJ').alias"
check "17a: invalid-charset alias -> falls through, alias null" '[ "$OUT" = null ]'
evalc "C.resolveConfig('$PROJ').warnings.some(w => w.includes('teamAlias'))"
check "17b: invalid-charset alias -> resolveConfig warns" '[ "$OUT" = true ]'

# ==== 18 — invalid alias (ends in -<role>, ambiguous double-role suffix) ====
reset_levels
write_level "$REPO_PATH" '{"teamAlias":"ct-reviewer"}'
evalc "C.teamPrefixInfo('$PROJ').alias"
check "18a: role-suffix alias -> falls through, alias null" '[ "$OUT" = null ]'
evalc "C.validateTeamAlias('ct-reviewer').why"
check "18b: validateTeamAlias names the role-suffix reason" 'echo "$OUT" | grep -qi "role"'

# ==== 19 — seam guard: rosterMemberNames stays a pure, prefix-agnostic
# function untouched by the alias/teamPrefix machinery — proven by the
# pre-existing test-roster-names.sh suite still passing unmodified. If this
# ever needs editing to pass, the seam was cut in the wrong place; the fix is
# never to relax that suite's expectations. ====
OUT=$(bash "$PLUGIN/tests/test-roster-names.sh" 2>&1); RC=$?
check "19: seam guard — test-roster-names.sh green with zero edits" '[ "$RC" -eq 0 ]'

# ---- roster.mjs alias subcommand ----

# ==== 20 — read-only, nothing configured anywhere ====
reset_levels
run_roster alias --cwd "$PROJ"
check "20: alias (read-only), nothing set -> alias null, source default" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"alias\": null" && echo "$OUT" | grep -q "\"source\": \"default\""'
check "20b: read-only prefix + sample reflect the default basename" \
  "echo \"\$OUT\" | grep -q '\"prefix\": \"$BASE\"' && echo \"\$OUT\" | grep -q '\"effective_names_sample\": \"$BASE-architect\"'"

# ==== 21 — --set writes teamAlias at the given level, prefix reflects it ====
reset_levels
run_roster alias --set myalias --level repo --cwd "$PROJ"
check "21: alias --set -> RC 0, echoes level/path/teamAlias/prefix" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"teamAlias\": \"myalias\"" && echo "$OUT" | grep -q "\"prefix\": \"myalias\""'
check "21b: --set actually wrote the repo-level config file" 'grep -q "\"teamAlias\": \"myalias\"" "$REPO_PATH"'
evalc "C.teamPrefix('$PROJ')"
check "21c: teamPrefix now resolves the newly-set alias" '[ "$OUT" = myalias ]'

# ==== 22 — --set with an invalid name fails, writes nothing ====
reset_levels
run_roster alias --set "bad name" --level repo --cwd "$PROJ"
check "22: alias --set <invalid> -> non-zero, roster.mjs-prefixed reason" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^roster.mjs: alias:"'
check "22b: invalid --set never created the config file" '[ ! -f "$REPO_PATH" ]'

# ==== 23 — --clear removes the key, prefix falls back to default ====
reset_levels
run_roster alias --set ct --level repo --cwd "$PROJ" >/dev/null
run_roster alias --clear --level repo --cwd "$PROJ"
check "23: alias --clear -> RC 0, teamAlias null, prefix back to basename" \
  "[ \"\$RC\" -eq 0 ] && echo \"\$OUT\" | grep -q '\"teamAlias\": null' && echo \"\$OUT\" | grep -q '\"prefix\": \"$BASE\"'"
check "23b: --clear actually removed the key from the file" '! grep -q "teamAlias" "$REPO_PATH"'

# ==== 24 — --set/--clear at --level global hard-fails: alias is repo-scoped ====
reset_levels
run_roster alias --set ct --level global --cwd "$PROJ"
check "24: alias --set --level global -> hard fail, repo-scoped reason" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "repo-scoped"'
check "24b: never touched the global config file" '[ ! -f "$GLOBAL_PATH" ]'

# ---- non-blocking warnings (§7.2/§7.4) ----

# ==== 25 — spawn-one warns on a prefix mismatch against a live team.json,
# without itself blocking (execution reaches the later herdr-presence check,
# proven by that failure message also being present in the same run). ====
reset_levels
run_roster init --level repo --route peer --cwd "$PROJ" >/dev/null
run_roster add --level repo --role reviewer --model opus --cwd "$PROJ" >/dev/null
mkdir -p "$HIER_DIR"
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t1", "roster_level": "repo", "transport": "herdr",
  "members": [ { "name": "otherprefix-architect", "role": "architect" } ] }
EOF
NODE_DIR="$(dirname "$NODE_BIN")"
NO_HERDR_DIR="$SANDBOX/no-herdr-bin"
mkdir -p "$NO_HERDR_DIR"
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$NO_HERDR_DIR:$NODE_DIR" HERDR_ENV=1 \
  "$NODE_BIN" "$H/roster.mjs" spawn-one reviewer --cwd "$PROJ" 2>&1); RC=$?
check "25a: spawn-one prints the mixed-prefix warning" \
  'echo "$OUT" | grep -q "existing members are named .otherprefix-\*."'
check "25b: mixed-prefix warning never mentions disband" '! echo "$OUT" | grep -qi disband'
check "25c: warning is non-blocking — execution reaches the later herdr-presence fail" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "binary is on PATH"'
check "25d: still never wrote a new member (herdr-presence fail stopped it first)" \
  '[ "$(grep -c "\"role\"" "$TEAM_FILE")" -eq 1 ]'

# ==== 26 — alias --set/--clear warns when a Team is live, but still writes ====
reset_levels
run_roster init --level repo --route peer --cwd "$PROJ" >/dev/null
mkdir -p "$HIER_DIR"
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t2", "roster_level": "repo", "transport": "herdr",
  "members": [ { "name": "$BASE-architect", "role": "architect" } ] }
EOF
run_roster alias --set newalias --level repo --cwd "$PROJ"
check "26a: alias --set with a live team -> RC 0 (write still happens)" '[ "$RC" -eq 0 ]'
check "26b: warns that names are frozen, using the first member as the example" \
  "echo \"\$OUT\" | grep -q 'named \"$BASE-architect\"' && echo \"\$OUT\" | grep -qi frozen"
check "26c: live-team warning never mentions disband/teardown" '! echo "$OUT" | grep -qiE "disband|teardown"'
check "26d: the write actually happened despite the warning" 'grep -q "\"teamAlias\": \"newalias\"" "$REPO_PATH"'

# ==== 12 — spec 0019 §6 case 12 / amendment (b): record-live under a stale name (population 2),
#            single-candidate role. team.json holds "old-implementor", live in the registry; the
#            alias then changes so the roster derives "new-implementor". spawn-one must treat this
#            as a no-op — never launch a second pane for the same role, never overwrite the still-
#            live "old-implementor" row. Assert all four: spawned:false/already-live; claude/herdr
#            never invoked; team.json byte-identical; member.name is old-implementor not
#            new-implementor. Existing case 25 does NOT cover this — it seeds a cross-role stale
#            record with no registry entry, so existingRecord is null under both old and new code
#            and passes either way; this needs a same-role, registry-live stale record. ====
reset_levels
PEERS_FILE="$HIER_DIR/peers.jsonl"
seed_peer() { # <name> <role> <status> <pid>
  mkdir -p "$(dirname "$PEERS_FILE")"
  "$NODE_BIN" -e 'const fs=require("fs");const[f,n,r,st,p]=process.argv.slice(1);
    fs.appendFileSync(f,JSON.stringify({type:"peer",status:st,name:n,role:r,pid:Number(p)||undefined,ts:new Date().toISOString()})+"\n");' \
    "$PEERS_FILE" "$1" "$2" "$3" "$4"
}
run_roster init --level repo --route peer --cwd "$PROJ" >/dev/null
run_roster alias --set old --level repo --cwd "$PROJ" >/dev/null
run_roster add --level repo --role implementor --model opus --cwd "$PROJ" >/dev/null
mkdir -p "$HIER_DIR"
cat > "$TEAM_FILE" <<EOF
{ "version": 1, "team_id": "t12", "roster_level": "repo", "transport": "herdr",
  "orchestrator": { "session_id": null, "pid": $$ },
  "members": [ { "name": "old-implementor", "role": "implementor", "route": "peer", "model": "opus", "effort": null, "autoMode": null, "transport_id": "p1" } ] }
EOF
BEFORE_TEAM12=$(cat "$TEAM_FILE")
seed_peer "old-implementor" "implementor" "up" "$$"
# alias changes AFTER the team was created — roster now derives "new-implementor" for this role.
run_roster alias --set new --level repo --cwd "$PROJ" >/dev/null
HERDR_MARKER="$SANDBOX/herdr-invoked-12"
HERDR_STUB_DIR="$SANDBOX/herdr-stub-bin-12"
mkdir -p "$HERDR_STUB_DIR"
cat > "$HERDR_STUB_DIR/herdr" <<STUBEOF
#!/bin/sh
echo "HERDR INVOKED: \$@" >> "$HERDR_MARKER"
exit 1
STUBEOF
chmod +x "$HERDR_STUB_DIR/herdr"
NODE_DIR="$(dirname "$NODE_BIN")"
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$HERDR_STUB_DIR:$NODE_DIR" HERDR_ENV=1 \
  "$NODE_BIN" "$H/roster.mjs" spawn-one implementor --cwd "$PROJ" 2>&1); RC=$?
check "12a: spawned false, reason already live" \
  '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": false" && echo "$OUT" | grep -q "\"reason\": \"already live\""'
check "12b: herdr never invoked (no launch attempt for the drifted name)" '[ ! -f "$HERDR_MARKER" ]'
check "12c: team.json byte-identical afterward" '[ "$(cat "$TEAM_FILE")" = "$BEFORE_TEAM12" ]'
check "12d: emitted member.name is the live old-implementor, not the drifted new-implementor" \
  'echo "$OUT" | grep -q "\"name\": \"old-implementor\"" && ! echo "$OUT" | grep -q "\"name\": \"new-implementor\""'

# ==== 29 — role-token collision (amendment (d), §4.4): validateTeamAlias rejects ====
evalc "C.validateTeamAlias('architect').ok"
check "29a: alias equal to a role token -> rejected" '[ "$OUT" = false ]'
evalc "C.validateTeamAlias('architect').why"
check "29b: rejection message names the role collision, not the charset rule" \
  'echo "$OUT" | grep -qi "role" && ! echo "$OUT" | grep -qi "letter or digit"'
evalc "C.validateTeamAlias('xarchitectx').ok"
check "29c: alias containing a role token mid-string -> rejected" '[ "$OUT" = false ]'
evalc "C.validateTeamAlias('ct-reviewer').ok"
check "29d: alias ending in -<role> (superseded suffix rule's case) -> rejected" '[ "$OUT" = false ]'
evalc "C.validateTeamAlias('ultra-advisor').ok"
check "29e: alias 'ultra-advisor' -> rejected (shadows architect/reviewer/implementor)" '[ "$OUT" = false ]'
evalc "C.validateTeamAlias('ct').ok"
check "29f: clean alias -> still accepted" '[ "$OUT" = true ]'
evalc "C.validateTeamAlias('advisor').ok"
check "29g: alias 'advisor' -> accepted (over-broadness guard: a blacklist would wrongly reject this)" '[ "$OUT" = true ]'
evalc "C.validateTeamAlias('bad_alias!').why"
check "29h: charset-violation message is distinct from the role-collision message" '! echo "$OUT" | grep -qi "role-token"'

# ==== 30 — no new module edge (amendment (e)): lib-config.mjs never imports lib-hier.mjs ====
check "30: lib-config.mjs has no import from ./lib-hier.mjs" \
  '! grep -qE "(from|import\()[[:space:]]*['"'"'\"]\./lib-hier\.mjs" "$H/lib-config.mjs"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
