#!/bin/bash
# agent-hierarchy doc-lint: every relative markdown link in README.md and
# docs/*.md (excluding docs/specs/ and docs/retired/, which are historical
# records, not living docs) must resolve to a real file. Broken relative
# links are the cheapest, most common defect in a docs commit.
# Usage: bash tests/test-doc-links.sh   (exits 0 iff all links resolve)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

check_file() {
  local doc="$1"
  local dir
  dir="$(dirname "$doc")"
  # [text](path) links, excluding http(s)/mailto and pure #anchors.
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    local target="${link%%#*}"   # drop a trailing #anchor
    [ -z "$target" ] && continue
    local resolved
    resolved="$(cd "$dir" 2>/dev/null && node -e "console.log(require('path').resolve(process.argv[1]))" "$target" 2>/dev/null)"
    if [ -n "$resolved" ] && [ -e "$resolved" ]; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      echo "FAIL: $doc -> $link (resolved: $resolved)"
    fi
  done < <(grep -oE '\]\([^)]+\)' "$doc" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:)')
}

FILES=("$PLUGIN/README.md")
for f in "$PLUGIN"/docs/*.md; do
  [ -f "$f" ] || continue
  FILES+=("$f")
done

for f in "${FILES[@]}"; do
  check_file "$f"
done

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
