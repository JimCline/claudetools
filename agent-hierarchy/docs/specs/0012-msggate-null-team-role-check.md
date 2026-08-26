# 0012 — msg-gate role-check gap for unresolved team scope

Status: **OPEN — filed, not started.**

## Origin

Filed per spec 0011 §9.6 (predicate-(ii) closing sweep, amendment (i)).
Architect's ruling: real, 0011-created, deferred rather than fixed under
0011. Full reasoning in `docs/specs/0011-multi-roster-per-orchestrator.md`
§9.6 and the adjudication trail at
`.claude/hierarchy/msgs/20260825-131205-6iee--orchestrator--spec-0011-full-sweep--response.md`.

## Problem

In a named-team repo, a peer session's `resolved.team` is `null` (same
root cause as spec 0011's ultra-gate gap: only the orchestrator's
`session_id` is ever stored, so a peer can never resolve its own team).
`pretooluse-msg-gate.mjs`'s role lookup returns `null` in this case, so
`validateRequestToken`'s `if (expectedTo && ...)` at `lib-hier.mjs:358`
silently **skips** the `to:`-matches-role cross-check for every peer
brief sent from such a session. Everything else in `validateRequestToken`
(file-must-exist, `msgsDir` scoping, `--request.md` suffix, `type:
request` — `lib-hier.mjs:353-357`) stays unconditional and is unaffected.

Architect's classification: a **routing lint**, not a consent gate —
lower stakes than the ultra-gate gap spec 0011 actually fixed (predicate
(ii)), but real and created by the same team-scoping work.

## Why not fixed directly

The obvious swap (apply the same all-team-prefix-union approach as
ultra-gate's predicate (ii)) doesn't transfer cleanly: msg-gate's
in-repo `(A)`-form lookup (`roleForAnyPeerName`) tails into
`roleFromName`, which is spec 0010 §8's unanchored substring matcher
(itself a documented mis-resolution hazard, out of scope here). Applying
it here would turn "check skipped" into "check runs against a possibly
wrong role," which can make `validateRequestToken` return `{ok:false}`
on a legitimate brief — a **fail-open gate acquiring the ability to fail
closed**, which Architect judged not to be a same-session change on an
already-signed-off diff.

## Root fix (preferred, once available)

NEEDS-EVIDENCE (d) from spec 0011 — if a future `claude` CLI surfaces
peer identity to hook input, a peer could resolve its own team directly
and this entire gap (and the `roleFromName` fallback question) may not
need touching at all. Re-check that NEEDS-EVIDENCE item before starting
design work here.

## Not yet decided

- Whether the eventual fix is the same union-predicate shape as spec
  0011's ultra-gate fix (with the `roleFromName` mis-resolution risk
  designed around), a different mechanism, or an accepted/documented
  limitation.
- Severity/priority relative to other backlog work — not scoped by this
  filing.
