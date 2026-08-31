#!/bin/bash
# agent-hierarchy — spec 0028 §5 Orchestrator-side liveness check-in: T11-T15, T28-T30.
# HOME-redirected; real config and real state are never touched.
# Usage: bash tests/test-orchestrator-liveness.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-liveness-test.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd)"  # canonicalize — TMPDIR can carry a trailing slash on macOS, which would otherwise
                                    # make shell-concatenated paths (e.g. mark_peer_route's) diverge byte-for-byte from
                                    # the same paths as built internally via Node's path.join (which collapses "//").
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
HIER_DIR="$SANDBOX/hier"
PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
PASS=0; FAIL=0
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HIER_DIR/msgs" "$(dirname "$PENDING")"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
is_block() { case "$OUT" in *'"decision":"block"'*) true;; *) false;; esac; }
is_empty() { [ -z "$OUT" ]; }

# write_request <id> <to> <slug> <created-iso> <eta>
write_request() {
  local id=$1 to=$2 slug=$3 created=$4 eta=$5
  cat > "$HIER_DIR/msgs/${id}--${to}--${slug}--request.md" <<EOF
---
id: ${id}
type: request
to: ${to}
from: orchestrator
slug: ${slug}
parent: null
reason: null
eta: ${eta}
to_name: peer-name
from_name: null
team: null
created: ${created}
---

## [0] tldr
- none
EOF
}
write_response() {
  local id=$1 to=$2 slug=$3
  cat > "$HIER_DIR/msgs/${id}--orchestrator--${slug}--response.md" <<EOF
---
id: ${id}
type: response
to: orchestrator
from: ${to}
slug: ${slug}
parent: null
reason: null
eta: null
to_name: null
from_name: peer-name
team: null
created: $(now_iso)
---

## [1] status
- done
EOF
}
# mark_dispatch <request-id> <to-role> <dispatcher-session-id> — the r4
# replacement for the old peer-pending-record cross-reference (spec 0028
# §5.3, finding 3): a dispatch record is written by the SENDER's own hook the
# moment it sends the request, keyed on the sender's session_id, independent
# of whether the recipient ever received or acknowledged it.
mark_dispatch() {
  printf '{"type":"dispatch","session_id":"%s","request_id":"%s","to":"%s","created":"%s"}\n' "$3" "$1" "$2" "$(now_iso)" >> "$PENDING"
}

liveness_hook() {
  local sid=$1
  OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/stop-orchestrator-liveness.mjs" 2>&1); RC=$?
}

OLD="2020-01-01T00:00:00-00:00"  # well past every eta threshold

# ---- T11: falsifiable — outstanding request past its eta threshold blocks, naming id and role
write_request "20260101-000000-t11a" architect t11 "$OLD" small
mark_dispatch "20260101-000000-t11a" architect s11
liveness_hook s11
check "T11: outstanding dispatch past eta blocks the stop" 'is_block'
check "T11: block names the request id" 'case "$OUT" in *20260101-000000-t11a*) true;; *) false;; esac'
check "T11: block names the role" 'case "$OUT" in *architect*) true;; *) false;; esac'
check "T11: block prescribes ListAgents then SendMessage" 'case "$OUT" in *ListAgents*SendMessage*) true;; *) false;; esac'
rm -f "$HIER_DIR"/msgs/20260101-000000-t11a--*

# ---- T12: OUTCOME — a matching response file closes the exchange, allow
write_request "20260101-000000-t12a" architect t12 "$OLD" small
mark_dispatch "20260101-000000-t12a" architect s12
write_response "20260101-000000-t12a" architect t12
liveness_hook s12
check "T12: OUTCOME — a closed exchange never blocks" 'is_empty'
rm -f "$HIER_DIR"/msgs/20260101-000000-t12a--*

# ---- T13: falsifiable — outstanding but younger than its eta threshold, allow
write_request "20260101-000000-t13a" architect t13 "$(now_iso)" small
mark_dispatch "20260101-000000-t13a" architect s13
liveness_hook s13
check "T13: falsifiable — a fresh dispatch under threshold does not block" 'is_empty'
rm -f "$HIER_DIR"/msgs/20260101-000000-t13a--*

# ---- T14: falsifiable — outstanding, old, but SUBAGENT route (no dispatch record) -> allow
write_request "20260101-000000-t14a" architect t14 "$OLD" small
liveness_hook s14
check "T14: falsifiable — a subagent-route dispatch never blocks (no stall it could catch)" 'is_empty'
rm -f "$HIER_DIR"/msgs/20260101-000000-t14a--*

# ---- T15: falsifiable — a session that both OWES and is OWED a report:
# peer-nudge blocks, liveness must not also block.
write_request "20260101-000000-t15a" architect t15 "$OLD" small
mark_dispatch "20260101-000000-t15a" architect s15
{
  printf '{"session_id":"s15","from":"upstream-addr","from_name":"someone","reply_to":"sender","task":"y","ts":"%s","status":"pending","nudges":0}\n' "$(now_iso)"
  printf '{"type":"turn","session_id":"s15","status":"armed","ts":"%s"}\n' "$(now_iso)"
} >> "$PENDING"

PEER_OUT=$(printf '{"session_id":"s15"}' | HOME="$FAKEHOME" node "$H/stop-peer-nudge.mjs" 2>&1)
case "$PEER_OUT" in *'"decision":"block"'*) PEER_BLOCKED=1;; *) PEER_BLOCKED=0;; esac
check "T15: precondition — stop-peer-nudge blocks this session (it owes a report)" '[ "$PEER_BLOCKED" = 1 ]'

liveness_hook s15
check "T15: falsifiable — liveness does not also block when peer-nudge already would" 'is_empty'
rm -f "$HIER_DIR"/msgs/20260101-000000-t15a--*

# ---- T28: falsifiable — two orchestrator sessions in one repo: session B's
# Stop is not blocked by session A's open dispatch (r4 finding 3 — §5.3's
# original premise cross-blocked exactly this).
write_request "20260101-000000-t28a" architect t28 "$OLD" small
mark_dispatch "20260101-000000-t28a" architect sA28
liveness_hook sB28
check "T28: falsifiable — another session's dispatch record does not block THIS session" 'is_empty'
rm -f "$HIER_DIR"/msgs/20260101-000000-t28a--*

# ---- T29: falsifiable — the peer never received the brief at all (no
# peer-pending obligation record exists for it — its own hook never ran) —
# the dispatcher session is STILL blocked. This is the case r4 finding 3
# specifically fixes: the old mechanism required the RECIPIENT's own record
# to exist, so a peer that died before receiving the brief was invisible.
write_request "20260101-000000-t29a" architect t29 "$OLD" small
mark_dispatch "20260101-000000-t29a" architect s29
# deliberately no peer-pending obligation record for this exchange at all
liveness_hook s29
check "T29: falsifiable — a peer that never received the brief still blocks the dispatcher" 'is_block'
check "T29: block names the request id" 'case "$OUT" in *20260101-000000-t29a*) true;; *) false;; esac'
rm -f "$HIER_DIR"/msgs/20260101-000000-t29a--*

# ---- T30: falsifiable — the dispatch record carries the SENDER's session_id,
# not the recipient's. Exercised end-to-end through the real producing hook
# (posttooluse-peer-resolve.mjs), not hand-written, since this is specifically
# a claim about what that hook writes.
REQ30_ID="20260101-000000-t30a"
write_request "$REQ30_ID" architect t30 "$OLD" small
REQ30_PATH="$HIER_DIR/msgs/${REQ30_ID}--architect--t30--request.md"
# Built via node's own JSON.stringify rather than a hand-escaped printf format
# string — `\"` inside a printf format is not a portable escape (bash's
# builtin printf drops the backslash where an interactive shell's did not),
# so hand-quoting the embedded sentinel's `reply-to="..."` corrupted the JSON
# under `bash tests/*.sh` specifically. Passing the raw text as an argv value
# sidesteps format-string escaping entirely.
MSG_TEXT="[hierarchy-peer-brief reply-to=\"sender-sess-30\" task=\"t30\"]
[hierarchy-msg $REQ30_PATH]"
PAYLOAD=$(node -e 'console.log(JSON.stringify({session_id:"sender-sess-30", tool_name:"SendMessage", tool_input:{to:"recipient-peer", message:process.argv[1]}}))' "$MSG_TEXT")
OUT=$(printf '%s' "$PAYLOAD" \
      | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/posttooluse-peer-resolve.mjs" 2>&1); RC=$?
DISPATCH_LINE=$(grep '"type":"dispatch"' "$PENDING" | grep "\"request_id\":\"$REQ30_ID\"")
check "T30: falsifiable — a dispatch record was written for this request" '[ -n "$DISPATCH_LINE" ]'
check "T30: falsifiable — the record's session_id is the SENDER's, not the recipient's" \
  'case "$DISPATCH_LINE" in *"\"session_id\":\"sender-sess-30\""*) true;; *) false;; esac'
check "T30: the record's session_id is not the recipient target's name" \
  'case "$DISPATCH_LINE" in *"\"session_id\":\"recipient-peer\""*) false;; *) true;; esac'
rm -f "$REQ30_PATH"

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
