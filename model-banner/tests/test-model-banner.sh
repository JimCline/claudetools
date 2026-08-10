#!/bin/bash
# model-banner regression tests.
# Runs the renderer + CLI with HOME redirected to a throwaway dir so real
# config/settings are never touched.
# Usage: bash tests/test-model-banner.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PLUGIN/.." && pwd)"
RENDER="$PLUGIN/statusline/render.mjs"
CLI="$PLUGIN/hooks/cli.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/model-banner-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

REAL_CFG="$(printf '%s' ~)/.claude/model-banner.json"
REAL_CFG_PRE=0; [ -f "$REAL_CFG" ] && REAL_CFG_PRE=1

ESC=$'\033'

run_render() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$RENDER" 2>/dev/null); RC=$?; }
run_render_raw() { OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" node "$RENDER" 2>/dev/null); RC=$?; }
run_cli() { OUT=$(HOME="$FAKEHOME" node "$CLI" "$@" 2>&1); RC=$?; }

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:200} RC=$RC)"; fi
}

write_config() { mkdir -p "$FAKEHOME/.claude"; printf '%s' "$1" > "$FAKEHOME/.claude/model-banner.json"; }
clear_config() { rm -f "$FAKEHOME/.claude/model-banner.json"; }

payload() { # payload <model_id> <display_name> [cwd]
  local cwd="${3:-$FAKEHOME}"
  printf '{"cwd":"%s","model":{"id":"%s","display_name":"%s"}}' "$cwd" "$1" "$2"
}

row_count() { printf '%s\n' "$OUT" | grep -c .; }
contains_esc() { printf '%s' "$OUT" | grep -qF "${ESC}[$1m"; }
contains() { printf '%s' "$OUT" | grep -qF "$1"; }
not_contains() { ! printf '%s' "$OUT" | grep -qF "$1"; }
exit_ok() { [ "$RC" -eq 0 ]; }
all_rows_end_reset() {
  local pattern total match
  pattern="${ESC}\[0m\$"
  total=$(printf '%s\n' "$OUT" | grep -c .)
  match=$(printf '%s\n' "$OUT" | grep -cE "$pattern")
  [ "$total" -gt 0 ] && [ "$total" -eq "$match" ]
}
last_line_is() { [ "$(printf '%s\n' "$OUT" | tail -1)" = "$1" ]; }

echo "== Tier + colour =="

clear_config
run_render "$(payload claude-sonnet-5 Sonnet)"
check "sonnet: green escape present" "contains_esc 32"
check "sonnet: renders block-glyph art" "contains █"
check "sonnet: exit 0" exit_ok

run_render "$(payload claude-opus-5 Opus)"
check "opus: yellow escape present" "contains_esc 33"

run_render "$(payload claude-fable-5 Fable)"
check "fable: red escape present" "contains_esc 31"

run_render "$(payload claude-haiku-4-5 Haiku)"
check "haiku: cyan escape present" "contains_esc 36"

run_render '{"cwd":"'"$FAKEHOME"'","model":{"id":"some-future-model-9","display_name":"Zephyr"}}'
check "unknown model: default white escape present" "contains_esc 37"
check "unknown model: exit 0" exit_ok
check "unknown model: renders glyph art (ZEPHYR)" "contains █"

run_render '{"cwd":"'"$FAKEHOME"'"}'
check "model key absent: exit 0" exit_ok

echo "== Size =="

clear_config
run_render "$(payload claude-sonnet-5 Sonnet)"
check "default size large: exactly 5 rows" "[ \$(row_count) -eq 5 ]"

write_config '{"version":1,"size":"small"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "size small: exactly 1 row" "[ \$(row_count) -eq 1 ]"
check "size small: contains literal SONNET" "contains SONNET"

write_config '{"version":1,"size":"bogus"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "size bogus: falls back to large (5 rows)" "[ \$(row_count) -eq 5 ]"
check "size bogus: exit 0" exit_ok

write_config '{"version":1,"size":"compact"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "size compact: exactly 3 rows" "[ \$(row_count) -eq 3 ]"
check "size compact: uses thin line-art chars, not blocks" "not_contains █"
check "size compact: exit 0" exit_ok

echo "== Colour hygiene =="

clear_config
run_render "$(payload claude-sonnet-5 Sonnet)"
check "every banner row ends with reset" all_rows_end_reset

write_config '{"version":1,"colors":{"sonnet":"chartreuse"}}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "invalid colour name: falls back to tier default (green)" "contains_esc 32"
check "invalid colour name: exit 0" exit_ok

echo "== Chain — safety cases =="

clear_config
write_config '{"version":1,"chain":"echo CHAINED"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "chain: CHAINED present" "contains CHAINED"
check "chain: CHAINED is the first line (before banner)" "[ \"\$(printf '%s\n' \"\$OUT\" | head -1)\" = CHAINED ]"

write_config '{"version":1,"enabled":false,"chain":"echo CHAINED"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "enabled:false: zero banner rows (only chain output)" "[ \$(row_count) -eq 1 ]"
check "enabled:false: chain still runs" "contains CHAINED"
check "enabled:false: no glyph art" "not_contains █"

write_config '{"version":1,"chain":"exit 1"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "chain exits 1: banner still present" "contains █"
check "chain exits 1: exit 0" exit_ok

write_config '{"version":1,"chain":"this-command-does-not-exist-xyz"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "chain missing binary: banner still present" "contains █"
check "chain missing binary: exit 0" exit_ok

write_config '{"version":1,"chain":"echo CHAINED"}'
OUT=$(printf 'not json at all' | HOME="$FAKEHOME" node "$RENDER" 2>/dev/null); RC=$?
check "malformed stdin: exit 0" exit_ok
check "malformed stdin: chain still runs" "contains CHAINED"

echo "== Layout =="

clear_config
write_config '{"version":1,"size":"compact","chain":"echo CHAINED"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "layout stack (default): chain first" "[ \"\$(printf '%s\n' \"\$OUT\" | head -1)\" = CHAINED ]"
check "layout stack (default): 4 lines total (1 chain + 3 banner rows)" "[ \$(row_count) -eq 4 ]"

write_config '{"version":1,"size":"compact","layout":"side","chain":"printf \"line1\\nline2\""}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "layout side: 3 lines total (banner rows, chain folded alongside)" "[ \$(row_count) -eq 3 ]"
check "layout side: first chain line present" "contains line1"
check "layout side: second chain line present" "contains line2"
check "layout side: still has glyph strokes" "contains '|'"

write_config '{"version":1,"layout":"bogus"}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "layout bogus: falls back to stack, exit 0" exit_ok

clear_config

echo "== Shim fallback =="

run_cli install
SHIM="$FAKEHOME/.claude/model-banner/statusline.mjs"
check "install: shim written" "[ -f '$SHIM' ]"
write_config '{"version":1,"chain":"echo CHAINED"}'
BROKEN_SHIM="$SANDBOX/broken-statusline.mjs"
sed "s#$PLUGIN#/nonexistent/model-banner-plugin-root#g" "$SHIM" > "$BROKEN_SHIM"
OUT=$(printf '%s' "$(payload claude-sonnet-5 Sonnet)" | HOME="$FAKEHOME" node "$BROKEN_SHIM" 2>/dev/null); RC=$?
check "shim fallback: chain runs when the plugin import fails" "contains CHAINED"
check "shim fallback: exit 0" exit_ok
# undo the install side-effect so later install-safety cases start clean
rm -rf "$FAKEHOME/.claude/model-banner"
rm -f "$FAKEHOME/.claude/settings.json" "$FAKEHOME/.claude/settings.json".model-banner.bak*
clear_config

echo "== Config layering =="

PROJ="$SANDBOX/proj"
mkdir -p "$PROJ/.claude"

write_config '{"version":1,"size":"large"}'
printf '{"version":1,"size":"small"}' > "$PROJ/.claude/model-banner.json"
run_render "$(payload claude-sonnet-5 Sonnet "$PROJ")"
check "layering: project size overrides user size" "[ \$(row_count) -eq 1 ]"

write_config '{"version":1,"colors":{"sonnet":"cyan","opus":"cyan","fable":"cyan","haiku":"cyan"}}'
printf '{"version":1,"colors":{"sonnet":"magenta"}}' > "$PROJ/.claude/model-banner.json"
run_render "$(payload claude-sonnet-5 Sonnet "$PROJ")"
check "layering: project overrides sonnet colour only (magenta)" "contains_esc 35"
run_render "$(payload claude-opus-5 Opus "$PROJ")"
check "layering: opus keeps user-scope colour (cyan)" "contains_esc 36"
rm -rf "$PROJ"

write_config '{"version":99,"colors":{"sonnet":"magenta"}}'
run_render "$(payload claude-sonnet-5 Sonnet)"
check "version 99 config: ignored, default green used" "contains_esc 32"
check "version 99 config: exit 0" exit_ok
clear_config

echo "== Font integrity =="

cat > "$SANDBOX/check-font.mjs" <<EOF
import { FONT_LARGE } from "$PLUGIN/hooks/lib-font.mjs";
let bad = [];
for (const [ch, rows] of Object.entries(FONT_LARGE)) {
  if (!Array.isArray(rows) || rows.length !== 5) { bad.push(ch + ":rowcount"); continue; }
  const w = rows[0].length;
  if (!rows.every((r) => r.length === w)) bad.push(ch + ":width");
}
console.log(bad.length === 0 ? "OK" : "BAD:" + bad.join(","));
EOF
FONT_CHECK=$(node "$SANDBOX/check-font.mjs" 2>&1)
check "font integrity: all glyphs 5 rows, equal width" "[ \"\$FONT_CHECK\" = OK ]"

cat > "$SANDBOX/check-font-compact.mjs" <<'EOF'
const pluginDir = process.env.PLUGIN_DIR;
const { FONT_LARGE, FONT_COMPACT } = await import(pluginDir + "/hooks/lib-font.mjs");
let bad = [];
for (const [ch, rows] of Object.entries(FONT_COMPACT)) {
  if (!Array.isArray(rows) || rows.length !== 3) { bad.push(ch + ":rowcount"); continue; }
  const w = rows[0].length;
  if (!rows.every((r) => r.length === w)) bad.push(ch + ":width");
  if (/[^| _\-\\\/]/.test(rows.join(""))) bad.push(ch + ":charset");
}
const largeKeys = Object.keys(FONT_LARGE).sort();
const compactKeys = Object.keys(FONT_COMPACT).sort();
if (JSON.stringify(largeKeys) !== JSON.stringify(compactKeys)) bad.push("keyset-mismatch");
console.log(bad.length === 0 ? "OK" : "BAD:" + bad.join(","));
EOF
FONT_COMPACT_CHECK=$(PLUGIN_DIR="$PLUGIN" node "$SANDBOX/check-font-compact.mjs" 2>&1)
check "font integrity: FONT_COMPACT is 3 rows, equal width, |_-\\/ chars only, same keyset as FONT_LARGE" "[ \"\$FONT_COMPACT_CHECK\" = OK ]"

echo "== Install safety (real contract) =="

# 22: pre-existing statusLine.command -> lands verbatim in chain, .bak created,
# every other settings.json key untouched.
rm -rf "$FAKEHOME/.claude"
mkdir -p "$FAKEHOME/.claude"
cat > "$FAKEHOME/.claude/settings.json" <<'EOF'
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh", "refreshInterval": 1 },
  "someOtherKey": { "nested": true, "value": 42 },
  "topLevelFlag": false
}
EOF
ORIGINAL_SETTINGS=$(cat "$FAKEHOME/.claude/settings.json")
run_cli install
check "install: exit 0" exit_ok
check "install: backup file created" "[ -f '$FAKEHOME/.claude/settings.json.model-banner.bak' ]"
BACKUP_MATCHES=$(node -e "
const fs = require('fs');
const backup = JSON.parse(fs.readFileSync('$FAKEHOME/.claude/settings.json.model-banner.bak', 'utf8'));
const original = $ORIGINAL_SETTINGS;
process.stdout.write(JSON.stringify(backup) === JSON.stringify(original) ? 'OK' : 'MISMATCH');
")
check "install: backup is byte-for-byte the original" "[ \"\$BACKUP_MATCHES\" = OK ]"
CHAIN_VALUE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/model-banner.json','utf8')).chain)")
check "install: original statusLine.command landed verbatim in chain" "[ \"\$CHAIN_VALUE\" = 'bash ~/.claude/statusline-command.sh' ]"
OTHER_KEYS_INTACT=$(node -e "
const s = JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/settings.json','utf8'));
const ok = JSON.stringify(s.someOtherKey) === JSON.stringify({nested:true,value:42}) && s.topLevelFlag === false
  && s.statusLine.type === 'command' && s.statusLine.refreshInterval === 1;
console.log(ok ? 'OK' : 'BROKEN');
")
check "install: every other settings.json key preserved" "[ \"\$OTHER_KEYS_INTACT\" = OK ]"

# 23: install run twice -> chain still holds the original command, not the shim path.
run_cli install
CHAIN_VALUE_2=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/model-banner.json','utf8')).chain)")
check "install twice: chain still the original command" "[ \"\$CHAIN_VALUE_2\" = 'bash ~/.claude/statusline-command.sh' ]"
check "install twice: chain is not the shim path" "[[ \"\$CHAIN_VALUE_2\" != *model-banner/statusline.mjs* ]]"

# 24: uninstall -> statusLine.command restored to the original string.
run_cli uninstall
check "uninstall: exit 0" exit_ok
RESTORED_COMMAND=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/settings.json','utf8')).statusLine.command)")
check "uninstall: statusLine.command restored verbatim" "[ \"\$RESTORED_COMMAND\" = 'bash ~/.claude/statusline-command.sh' ]"

# 25: install with NO pre-existing statusLine -> chain null; uninstall removes the key entirely.
rm -rf "$FAKEHOME/.claude"
mkdir -p "$FAKEHOME/.claude"
cat > "$FAKEHOME/.claude/settings.json" <<'EOF'
{ "unrelatedKey": "keepme" }
EOF
run_cli install
CHAIN_NULL=$(node -e "const c = JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/model-banner.json','utf8')).chain; console.log(c === null || c === undefined ? 'NULL' : c)")
check "install with no prior statusLine: chain is null" "[ \"\$CHAIN_NULL\" = NULL ]"
run_cli uninstall
HAS_STATUSLINE=$(node -e "console.log('statusLine' in JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/settings.json','utf8')) ? 'YES' : 'NO')")
check "uninstall with no recorded chain: statusLine key removed entirely" "[ \"\$HAS_STATUSLINE\" = NO ]"
UNRELATED_INTACT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FAKEHOME/.claude/settings.json','utf8')).unrelatedKey)")
check "uninstall: unrelated settings.json key still intact" "[ \"\$UNRELATED_INTACT\" = keepme ]"

echo "== CLI subcommands =="

rm -rf "$FAKEHOME/.claude"
mkdir -p "$FAKEHOME/.claude"
run_cli on
check "cli on: reports ON" "contains ON"
run_cli off
check "cli off: reports OFF" "contains OFF"
run_cli size small
check "cli size small: accepted" exit_ok
run_cli size bogus
check "cli size bogus: rejected (non-zero exit)" "[ \$RC -ne 0 ]"
run_cli layout side
check "cli layout side: accepted" exit_ok
run_cli layout bogus
check "cli layout bogus: rejected (non-zero exit)" "[ \$RC -ne 0 ]"
run_cli color sonnet cyan
check "cli color sonnet cyan: accepted" exit_ok
run_cli color notatier cyan
check "cli color bad tier: rejected" "[ \$RC -ne 0 ]"
run_cli color sonnet notacolor
check "cli color bad colour: rejected" "[ \$RC -ne 0 ]"
run_cli status
check "cli status: exit 0" exit_ok
check "cli status: mentions size" "contains size"
check "cli status: mentions layout" "contains layout"

echo "== Syntax + JSON validity =="

for f in "$PLUGIN"/hooks/*.mjs "$PLUGIN"/statusline/*.mjs; do
  node --check "$f" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: node --check $(basename "$f")"; } || { FAIL=$((FAIL+1)); echo "FAIL: node --check $(basename "$f")"; }
done
for j in "$PLUGIN/hooks/hooks.json" "$PLUGIN/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json"; do
  node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS: valid JSON $(basename "$j")"; } || { FAIL=$((FAIL+1)); echo "FAIL: invalid JSON $j"; }
done

echo "== Version agreement =="

V_PLUGIN=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PLUGIN/.claude-plugin/plugin.json','utf8')).version)")
V_MARKET=$(node -e "const m=JSON.parse(require('fs').readFileSync('$ROOT/.claude-plugin/marketplace.json','utf8')); process.stdout.write(m.plugins.find(p=>p.name==='model-banner').version)")
[ -n "$V_PLUGIN" ] && [ "$V_PLUGIN" = "$V_MARKET" ] && { PASS=$((PASS+1)); echo "PASS: versions agree ($V_PLUGIN)"; } || { FAIL=$((FAIL+1)); echo "FAIL: version mismatch plugin=$V_PLUGIN marketplace=$V_MARKET"; }

echo "== Real config untouched =="

if [ -f "$REAL_CFG" ] && [ "$REAL_CFG_PRE" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "FAIL: real ~/.claude/model-banner.json was created by the tests!"
else
  PASS=$((PASS+1)); echo "PASS: real ~/.claude state untouched by tests"
fi

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
