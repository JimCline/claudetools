#!/bin/bash
# agent-hierarchy — every hook file parses.
#
# On a machine whose marketplace is a local checkout, hooks run straight from the working tree, so
# an uncommitted edit with a syntax error takes out all 17 hook entrypoints at once — and Claude
# Code reports that only under --debug. This is the cheapest possible guard: node --check, seconds,
# catching the whole class before a session does.
# Usage: bash tests/test-hook-syntax.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

for f in "$PLUGIN"/hooks/*.mjs; do
  OUT=$(node --check "$f" 2>&1)
  check "node --check $(basename "$f")" '[ -z "$OUT" ]'
done

check "hooks.json is valid JSON" 'node -e "JSON.parse(require(\"node:fs\").readFileSync(process.argv[1],\"utf8\"))" "$PLUGIN/hooks/hooks.json"'

# Every command hooks.json names must exist: a rename that misses one file is silent at runtime.
MISSING=$(node -e '
  const fs = require("node:fs");
  const raw = fs.readFileSync(process.argv[1], "utf8");
  const paths = [...raw.matchAll(/\$\{CLAUDE_PLUGIN_ROOT\}\/(hooks\/[A-Za-z0-9._-]+)/g)].map((m) => m[1]);
  const missing = [...new Set(paths)].filter((p) => !fs.existsSync(`${process.argv[2]}/${p}`));
  console.log(missing.join(" "));
' "$PLUGIN/hooks/hooks.json" "$PLUGIN")
check "every hooks.json command points at a file that exists" '[ -z "$MISSING" ]'

# Control: the check must be able to fail, or a syntax error would sail past it.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-hook-syntax.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
printf 'const x = {;\n' > "$TMP/broken.mjs"
OUT=$(node --check "$TMP/broken.mjs" 2>&1)
check "control: node --check reports a broken file" '[ -n "$OUT" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
