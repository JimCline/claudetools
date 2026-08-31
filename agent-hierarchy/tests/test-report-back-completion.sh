#!/bin/bash
# agent-hierarchy — spec 0028 §4 report-back completion: T7, T8, T8b, T9b, T9c, T10, T27.
# HOME-redirected; real config and real state are never touched.
# Usage: bash tests/test-report-back-completion.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-report-back-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
HIER_DIR="$SANDBOX/hier"
PASS=0; FAIL=0
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HIER_DIR"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

msgcli() { HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/msg.mjs" "$@" --cwd "$PROJ" 2>&1; }

# ---------------------------------------------------------------- T7-T9: SubagentStop
TRANSCRIPT="$SANDBOX/agent-transcript.jsonl"

# subagentstop_hook <agent_id> <request-path> <last-assistant-message>
# agent_id is unique per call — the hook's one-shot "nudge" gate is keyed on it,
# so reusing an id across cases would let an earlier block silently satisfy a
# later one.
subagentstop_hook() {
  local aid=$1 req=$2 last=$3
  printf '{"type":"user","message":{"role":"user","content":"[hierarchy-msg %s] brief"}}\n' "$req" > "$TRANSCRIPT"
  printf '{"type":"assistant","message":{"role":"assistant","content":"working"}}\n' >> "$TRANSCRIPT"
  OUT=$(printf '{"agent_id":"%s","agent_type":"ah:architect","cwd":"%s","agent_transcript_path":"%s","last_assistant_message":"%s"}' \
        "$aid" "$PROJ" "$TRANSCRIPT" "$last" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/subagentstop-msg-nudge.mjs" 2>&1); RC=$?
}
is_block() { case "$OUT" in *'"decision":"block"'*) true;; *) false;; esac; }
is_empty() { [ -z "$OUT" ]; }

REQ_ID=$(msgcli new --to architect --from orchestrator --slug t7 --plain | cut -d' ' -f1)
REQ_PATH="$HIER_DIR/msgs/${REQ_ID}--architect--t7--request.md"
[ -f "$REQ_PATH" ] || REQ_PATH=$(find "$HIER_DIR/msgs" -name "${REQ_ID}--*--request.md")

# T7: token present, response file MISSING -> block (falsifiable: the missing
# file must actually be the failure mode, not any other gate condition)
subagentstop_hook a7 "$REQ_PATH" "[hierarchy-msg $HIER_DIR/msgs/${REQ_ID}--orchestrator--t7--response.md]"
check "T7: response file missing is blocked" 'is_block'
check "T7: block names the missing file's response command" 'case "$OUT" in *"msg.mjs\\\" new --type response"*) true;; *) false;; esac'

# T8: token present, response file EXISTS but is frontmatter-only (empty body)
RESP_STUB="$HIER_DIR/msgs/${REQ_ID}--orchestrator--t7--response.md"
cat > "$RESP_STUB" <<EOF
---
id: ${REQ_ID}
type: response
to: orchestrator
from: architect
slug: t7
parent: null
reason: null
eta: null
to_name: null
from_name: null
team: null
created: 2026-01-01T00:00:00-00:00
---
EOF
subagentstop_hook a8 "$REQ_PATH" "[hierarchy-msg $RESP_STUB]"
check "T8: falsifiable — a frontmatter-only response stub is blocked" 'is_block'

# T8b (was T9, INVERTED — r4 finding 1): token present, response file exists
# but is an UNEDITED CLI-produced skeleton (no author content anywhere in the
# body) -> must BLOCK. As shipped this asserted allow, encoding the very
# defect r4 fixes; the assertion is inverted rather than left standing beside
# a new test, so the suite is never self-contradictory about what "filled"
# means.
rm -f "$RESP_STUB"
msgcli new --type response --to orchestrator --from architect --id "$REQ_ID" >/dev/null
subagentstop_hook a8b "$REQ_PATH" "[hierarchy-msg $RESP_STUB]"
check "T8b: falsifiable — an unedited CLI-produced skeleton is blocked, not allowed" 'is_block'

# T9b: genuine authored content in the body -> allow
{
  cat "$RESP_STUB"
  echo "- fixed the bug in foo.py:42"
} > "${RESP_STUB}.tmp"
mv "${RESP_STUB}.tmp" "$RESP_STUB"
subagentstop_hook a9b "$REQ_PATH" "[hierarchy-msg $RESP_STUB]"
check "T9b: OUTCOME — genuinely authored content allows the stop" 'is_empty'

# T9c: falsifiable — only ONE section filled in, the rest still skeleton -> allow
# (pins the boundary: this heuristic accepts partial-but-real completion,
# not just a fully-filled skeleton)
rm -f "$RESP_STUB"
msgcli new --type response --to orchestrator --from architect --id "$REQ_ID" >/dev/null
python3 - "$RESP_STUB" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("## [1] status\n- none", "## [1] status\n- done", 1)
open(path, "w").write(text)
PY
subagentstop_hook a9c "$REQ_PATH" "[hierarchy-msg $RESP_STUB]"
check "T9c: falsifiable — one authored section, rest still skeleton, allows the stop" 'is_empty'

# ---------------------------------------------------------------- T27: subagent silent give-up is recorded (r4 finding 2)
GATES="$HIER_DIR/gates.jsonl"
rm -f "$RESP_STUB"
# First SubagentStop: no response token satisfied -> blocks, records the one-shot "nudge" gate.
subagentstop_hook a27 "$REQ_PATH" "no pointer here"
check "T27: first stop (unsatisfied) blocks" 'is_block'
# Second SubagentStop, same agent_id, still unsatisfied: the one-shot bound
# means this must allow — but it must ALSO record the silent give-up now,
# where it previously recorded nothing.
subagentstop_hook a27 "$REQ_PATH" "no pointer here"
check "T27: second stop (still unsatisfied, already nudged) allows" 'is_empty'
check "T27: falsifiable — the silent give-up is recorded as nudge-unmet" \
  "grep -q '\"type\":\"nudge-unmet\"' \"\$GATES\" && grep -q '\"agent_id\":\"a27\"' \"\$GATES\""

# ---------------------------------------------------------------- T10: peer Stop, unmet obligation on the record
PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
mkdir -p "$(dirname "$PENDING")"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
  printf '{"session_id":"s10","from":"peer-addr","from_name":"orchestrator-peer","reply_to":"sender","task":"t10","ts":"%s","status":"pending","nudges":2}\n' "$(now)"
  printf '{"type":"turn","session_id":"s10","status":"armed","ts":"%s"}\n' "$(now)"
} >> "$PENDING"

OUT=$(printf '{"session_id":"s10"}' | HOME="$FAKEHOME" node "$H/stop-peer-nudge.mjs" 2>&1); RC=$?
check "T10: falsifiable — at MAX_NUDGES the stop is allowed (no output)" 'is_empty'
check "T10: an unmet-obligation record was written to the peer store" \
  "grep -q '\"session_id\":\"s10\"' \"$PENDING\" && grep -q '\"status\":\"waived\"' \"$PENDING\""
check "T10: obligation no longer counts as pending" \
  "OUT=\$(HOME=\"$FAKEHOME\" node --input-type=module -e \"
    const P = await import('$H/lib-peer.mjs');
    process.stdout.write(String(P.pendingFor('s10').length));
  \" 2>&1); [ \"\$OUT\" = 0 ]"

# ---------------------------------------------------------------- T10b: peer Stop, last-attempt escalation text (§4.3)
PENDING_B="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
{
  printf '{"session_id":"s10b","from":"peer-addr","from_name":"orchestrator-peer","reply_to":"sender","task":"t10b","ts":"%s","status":"pending","nudges":1}\n' "$(now)"
  printf '{"type":"turn","session_id":"s10b","status":"armed","ts":"%s"}\n' "$(now)"
} >> "$PENDING_B"

OUT=$(printf '{"session_id":"s10b"}' | HOME="$FAKEHOME" node "$H/stop-peer-nudge.mjs" 2>&1); RC=$?
check "T10b: falsifiable — nudges=1 (about to hit MAX_NUDGES) blocks with the last-attempt text" \
  'case "$OUT" in *"THIS IS THE LAST ATTEMPT"*) true;; *) false;; esac'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
