#!/bin/bash
# agent-hierarchy — herdr transport dependency check (spec 0010 §2). Feature A:
# a pure PATH-walk presence probe (`herdrOnPath()`, no subprocess — this runs
# on every SessionStart including `compact`), an advisory SessionStart warning
# when HERDR_ENV=1 and herdr is missing, and a hard fail() at the point of use
# (roster.mjs, wherever a herdr command is about to run) since the command
# literally cannot succeed without the binary.
# Usage: bash tests/test-herdr-presence.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-herdr-presence-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$SANDBOX/with-herdr" "$SANDBOX/without-herdr" "$SANDBOX/not-executable"
(cd "$PROJ" && git init -q)

# ---- fake `herdr` executables for the presence probe ----
cat > "$SANDBOX/with-herdr/herdr" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/with-herdr/herdr"

cat > "$SANDBOX/not-executable/herdr" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod -x "$SANDBOX/not-executable/herdr"

evalr() { # <js expr over R = lib-roster.mjs> [PATH override]
  OUT=$(PATH="${1:-$PATH}" "$NODE_BIN" --input-type=module -e "
    const R = await import('$H/lib-roster.mjs');
    process.stdout.write(String($2));
  " 2>&1); RC=$?
}

# ==== 1 — executable herdr on PATH -> true ====
evalr "$SANDBOX/with-herdr" "R.herdrOnPath()"
check "1: herdr present + executable -> herdrOnPath() true" '[ "$OUT" = true ]'

# ==== 2 — PATH has directories but none contain herdr -> false ====
evalr "$SANDBOX/without-herdr" "R.herdrOnPath()"
check "2: no herdr anywhere on PATH -> herdrOnPath() false" '[ "$OUT" = false ]'

# ==== 3 — a file named herdr exists but is not executable -> false ====
evalr "$SANDBOX/not-executable" "R.herdrOnPath()"
check "3: herdr present but not executable -> herdrOnPath() false" '[ "$OUT" = false ]'

# ==== 4 — PATH unset -> false, never throws ====
OUT=$(env -u PATH "$NODE_BIN" --input-type=module -e "
  const R = await import('$H/lib-roster.mjs');
  process.stdout.write(String(R.herdrOnPath()));
" 2>&1); RC=$?
check "4: PATH unset -> herdrOnPath() false, no throw" '[ "$RC" -eq 0 ] && [ "$OUT" = false ]'

# ---- SessionStart warning (§2.5) ----
start() { # payload JSON, PATH override, extra env -> hook stdout
  local payload=$1 pathval=$2 extra_env=$3
  # HERDR_ENV="" first so a real-shell-ambient HERDR_ENV (this session may itself
  # be running inside a herdr pane) never leaks in — extra_env overrides it back
  # to 1 when a case actually wants that.
  OUT=$(eval "echo '$payload' | HOME=\"$FAKEHOME\" AGENT_HIERARCHY_DIR=\"$SANDBOX/hier\" PATH=\"$pathval\" HERDR_ENV=\"\" $extra_env \"$NODE_BIN\" \"$H/sessionstart.mjs\" 2>/dev/null")
}

cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "model" } } }
EOF
WITH_HERDR_PATH="$SANDBOX/with-herdr:$NODE_DIR"
WITHOUT_HERDR_PATH="$SANDBOX/without-herdr:$NODE_DIR"

PAYLOAD="{\"session_id\":\"s5\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"

# ==== 5 — HERDR_ENV=1, no herdr, plain configured+enabled session -> warning present ====
start "$PAYLOAD" "$WITHOUT_HERDR_PATH" "HERDR_ENV=1"
check "5: HERDR_ENV=1 + no herdr -> warning text present" \
  'echo "$OUT" | grep -q "HERDR_ENV=1 but no" && echo "$OUT" | grep -q "will fail when it tries to place"'

# ==== 6 — HERDR_ENV=1, herdr present -> no warning ====
start "$PAYLOAD" "$WITH_HERDR_PATH" "HERDR_ENV=1"
check "6: HERDR_ENV=1 + herdr present -> no warning" '! echo "$OUT" | grep -q "HERDR_ENV=1 but no"'

# ==== 7 — HERDR_ENV unset, no herdr -> silent (out of scope, §2.3) ====
start "$PAYLOAD" "$WITHOUT_HERDR_PATH" ""
check "7: HERDR_ENV unset + no herdr -> silent" '! echo "$OUT" | grep -q "HERDR_ENV=1 but no"'

# ==== 8 — role branch (`--agent ah:architect`) never gets the warning ====
ROLE_PAYLOAD="{\"session_id\":\"s8\",\"cwd\":\"$PROJ\",\"agent_type\":\"ah:architect\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
start "$ROLE_PAYLOAD" "$WITHOUT_HERDR_PATH" "HERDR_ENV=1"
check "8: role session, HERDR_ENV=1 + no herdr -> no warning" '! echo "$OUT" | grep -q "HERDR_ENV=1 but no"'

# ==== 9 — unconfigured cwd (nudge branch) never gets the warning ====
UNCONF="$SANDBOX/unconfigured"
mkdir -p "$UNCONF"
NUDGE_PAYLOAD="{\"session_id\":\"s9\",\"cwd\":\"$UNCONF\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
start "$NUDGE_PAYLOAD" "$WITHOUT_HERDR_PATH" "HERDR_ENV=1"
check "9: unconfigured cwd, HERDR_ENV=1 + no herdr -> no warning" '! echo "$OUT" | grep -q "HERDR_ENV=1 but no"'
check "9b: unconfigured cwd still gets the plain nudge" 'echo "$OUT" | grep -q "not configured"'

# ---- point-of-use hard fail() (§2.6) ----
setup_roster() { # <n roles> <level>
  local n=$1 level=${2:-repo}
  local roles=(ultra-advisor architect reviewer implementor)
  HOME="$FAKEHOME" "$NODE_BIN" "$H/roster.mjs" init --level "$level" --route peer --cwd "$PROJ" >/dev/null
  for ((i = 0; i < n; i++)); do
    HOME="$FAKEHOME" "$NODE_BIN" "$H/roster.mjs" add --level "$level" --role "${roles[$i]}" --model opus --cwd "$PROJ" >/dev/null
  done
}
rm -rf "$PROJ/.claude/hierarchy"
rm -f "$PROJ/.claude/agent-hierarchy.json"
setup_roster 1

TEAM_FILE="$PROJ/.claude/hierarchy/team.json"

# ==== 10 — spawn-one: HERDR_ENV=1, no herdr on PATH -> hard fail, no team.json written ====
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$WITHOUT_HERDR_PATH" HERDR_ENV=1 "$NODE_BIN" "$H/roster.mjs" spawn-one ultra-advisor --cwd "$PROJ" 2>&1); RC=$?
check "10: spawn-one, HERDR_ENV=1 + no herdr -> non-zero, §2.6 message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "no" && echo "$OUT" | grep -q "binary is on PATH"'
check "10b: spawn-one never wrote team.json" '[ ! -f "$TEAM_FILE" ]'

# ==== 11 — create --spawn and layout-splits: same herdr-missing hard fail ====
rm -rf "$PROJ/.claude/hierarchy"
OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$WITHOUT_HERDR_PATH" HERDR_ENV=1 "$NODE_BIN" "$H/roster.mjs" create --spawn --mode auto --cwd "$PROJ" 2>&1); RC=$?
check "11a: create --spawn, HERDR_ENV=1 + no herdr -> non-zero, §2.6 message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "binary is on PATH"'
check "11b: create --spawn never wrote team.json" '[ ! -f "$TEAM_FILE" ]'

OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" HERDR_PANE_ID=p0 PATH="$WITHOUT_HERDR_PATH" HERDR_ENV=1 "$NODE_BIN" "$H/roster.mjs" layout-splits --mode auto --pane-count 1 --self p0 --cwd "$PROJ" 2>&1); RC=$?
check "11c: layout-splits, HERDR_ENV=1 + no herdr -> non-zero, §2.6 message" \
  '[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "binary is on PATH"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
