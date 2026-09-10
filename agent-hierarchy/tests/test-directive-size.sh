#!/bin/bash
# agent-hierarchy directive size ceilings (spec 0045 §9.6).
# The SessionStart injection is paid on every session start AND every compact of
# the Orchestrator session, so its size is a budget, not a detail. These are
# CEILINGS, not targets: a rewrite that grows the directive past them has to be
# a deliberate decision, not an accident.
# HOME-redirected; real config never touched.
# Usage: bash tests/test-directive-size.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN/hooks/lib-config.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-dirsize-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name ($OUT)"; fi
}

# Fixed fixture so the number is comparable run to run: a known model, a null
# route, and a hierarchy dir short enough not to skew the count.
directive_bytes() { # <handoffs>
  printf '{"version":1,"enabled":true,"roles":{},"handoffs":"%s"}\n' "$1" > "$FAKEHOME/.claude/agent-hierarchy.json"
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const L = await import('$LIB');
    const r = L.resolveConfig('$PROJ');
    const d = L.buildDirective(r, 's1', { hierDir: '/tmp/h', model: 'opus', route: null });
    process.stdout.write(String(Buffer.byteLength(d)));
  " 2>&1)
}

AUTO_MAX=14300
CONFIRM_MAX=16200

directive_bytes auto
check "buildDirective(auto) <= $AUTO_MAX B (got $OUT)" '[ "$OUT" -le "$AUTO_MAX" ] 2>/dev/null'

directive_bytes confirm
check "buildDirective(confirm) <= $CONFIRM_MAX B (got $OUT)" '[ "$OUT" -le "$CONFIRM_MAX" ] 2>/dev/null'

# ---- agent definition ceilings (spec 0045 §9.5). Every one of these is paid on
# every spawn of that role.
A="$PLUGIN/agents"
md_ceiling() { # <file> <max>
  OUT=$(wc -c < "$A/$1.md" | tr -d ' ')
  check "agents/$1.md <= $2 B (got $OUT)" "[ \"$OUT\" -le \"$2\" ]"
}

md_ceiling architect     9600
md_ceiling ultra-advisor 7100
md_ceiling reviewer      6400
md_ceiling implementor   5100
md_ceiling task-runner   5650
md_ceiling orchestrator  7200

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
