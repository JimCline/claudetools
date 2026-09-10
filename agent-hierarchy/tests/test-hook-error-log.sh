#!/bin/bash
# agent-hierarchy — the hook error log.
#
# Claude Code ignores a hook's invalid JSON on exit 0 and treats exit 1 as non-blocking, both
# visible only under --debug: a hook that crashed and a hook that decided to stay quiet look
# identical from the outside. This log is the only difference, so the assertions are that every
# entrypoint writes to it, that writing never changes what the hook decided, and that the logger
# itself cannot throw.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-hook-error-log.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-hook-error-log-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
LOG="$FAKEHOME/.claude/hierarchy/hook-errors.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

lib() { # <js body, `L` is lib-config>
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$LIB');
    $1
  " 2>&1); RC=$?
}

# ---- 1: the path is under the user's own .claude, not the project
lib 'process.stdout.write(L.HOOK_ERROR_LOG);'
check "log path is ~/.claude/hierarchy/hook-errors.jsonl" '[ "$OUT" = "$LOG" ]'

# ---- 2: one append per call, with the documented fields
rm -f "$LOG"
lib 'L.logHookError("probe.mjs", new Error("boom"), { hook_event_name: "SessionStart", session_id: "s1" });'
check "logHookError writes one line" '[ "$(wc -l < "$LOG" | tr -d " ")" -eq 1 ]'
check "the line is JSON with ts, hook, event, session_id, message and stack" \
  'node -e "
     const e = JSON.parse(require(\"node:fs\").readFileSync(process.argv[1], \"utf8\").trim());
     const ok = typeof e.ts === \"string\" && e.hook === \"probe.mjs\" && e.event === \"SessionStart\"
       && e.session_id === \"s1\" && e.message === \"boom\" && Array.isArray(e.stack) && e.stack.length <= 3;
     process.exit(ok ? 0 : 1);
   " "$LOG"'

# ---- 3: a non-Error thrown value still logs
lib 'L.logHookError("probe.mjs", "just a string", {});'
check "a non-Error thrown value logs its string form" 'grep -q "just a string" "$LOG"'

# ---- 4: recentHookErrors windows on ts
rm -f "$LOG"
mkdir -p "$(dirname "$LOG")"
OLD_TS=$(node -e 'process.stdout.write(new Date(Date.now() - 48*3600*1000).toISOString())')
printf '{"ts":"%s","hook":"old.mjs","message":"ancient"}\n' "$OLD_TS" > "$LOG"
printf 'this line is not json at all\n' >> "$LOG"
printf '{"ts":"%s","hook":"new.mjs","message":"fresh"}\n' "$(node -e 'process.stdout.write(new Date().toISOString())')" >> "$LOG"
lib 'process.stdout.write(String(L.recentHookErrors(24).length));'
check "recentHookErrors(24) drops entries older than the window" '[ "$OUT" = "1" ]'
lib 'process.stdout.write(L.recentHookErrors(24)[0].hook);'
check "recentHookErrors survives an unparseable line in the middle" '[ "$OUT" = "new.mjs" ]'
lib 'process.stdout.write(String(L.recentHookErrors(72).length));'
check "a wider window includes the older entry" '[ "$OUT" = "2" ]'
rm -f "$LOG"
lib 'process.stdout.write(String(L.recentHookErrors(24).length));'
check "an absent log reads as no errors" '[ "$OUT" = "0" ]'

# ---- 5: the logger never throws — the one place with an empty catch
rm -rf "$FAKEHOME/.claude/hierarchy"
: > "$FAKEHOME/.claude/hierarchy"   # a FILE where the directory must go
lib 'L.logHookError("probe.mjs", new Error("boom"), {}); process.stdout.write("survived");'
check "logHookError swallows its own failure" '[ "$OUT" = "survived" ]'
rm -f "$FAKEHOME/.claude/hierarchy"

# ---- 6: the size cap rotates to .1 rather than growing without bound
mkdir -p "$(dirname "$LOG")"
node -e 'require("node:fs").writeFileSync(process.argv[1], "x".repeat(1024*1024 + 10))' "$LOG"
lib 'L.logHookError("probe.mjs", new Error("after the cap"), {});'
check "past the cap: the old log is rotated to .1" '[ -f "$LOG.1" ]'
check "past the cap: the live log holds only the new entry" '[ "$(wc -l < "$LOG" | tr -d " ")" -eq 1 ]'
rm -f "$LOG" "$LOG.1"

# ---- 7: an unparseable stdin payload is itself logged — the {} it degrades to is
# indistinguishable from a plain main session, which is exactly the silent case.
rm -f "$LOG"
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$PLUGIN/hooks/sessionstart.mjs" 2>&1); RC=$?
check "unparseable payload: the hook still exits 0" '[ "$RC" -eq 0 ]'
check "unparseable payload: readHookInput logs it" 'grep -q "readHookInput" "$LOG"'
check "unparseable payload: the log says the payload would not parse" 'grep -q "unparseable payload" "$LOG"'

# ---- 8: every hook entrypoint routes its catch through the logger. A hook whose
# catch stays bare is invisible again, which is the whole class this closes.
MISSING=""
for f in "$PLUGIN"/hooks/*.mjs; do
  b=$(basename "$f")
  case "$b" in lib-*|roster.mjs|msg.mjs|gate.mjs|usage-report.mjs) continue;; esac
  grep -q "logHookError" "$f" || MISSING="$MISSING $b"
done
check "every hook entrypoint calls logHookError" '[ -z "$MISSING" ]'

# ---- 9: logging does not change a hook's decision — a healthy hook writes nothing
rm -f "$LOG"
OUT=$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1","agent_id":"a1"}' "$PROJ" \
  | HOME="$FAKEHOME" node "$PLUGIN/hooks/subagentstart-cli-root.mjs" 2>&1); RC=$?
check "a hook that does not throw logs nothing" '[ "$RC" -eq 0 ] && [ ! -s "$LOG" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
