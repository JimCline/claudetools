# Bug: `/clear` in a durable pane permanently breaks its relay

**Component:** `agent-hierarchy` — durable agent relay (`hooks/pane.mjs`)
**Severity:** high — silent, permanent, and destroys the agent's reply
**Status:** FIXED in 0.14.0 — fixes 1, 3 and 4 shipped; fix 2 deferred (see below)
**Found:** 2026-08-09, while using a durable implementor as a test harness

> **The component this bug belongs to is deprecated and scheduled for removal.**
> Durable agents were an experiment in keeping a role's session alive between
> sends; it only ever worked on macOS with iTerm2, and this bug is a fair sample
> of why the substrate was wrong — a relay pinned to a terminal session's id is
> fragile in a way a server-side channel would not be. herdr's headless server
> is the replacement direction. The deferred fix 2 below will not be pursued.

## Resolution (0.14.0)

Gate D now asks **"is this one of this pane's sessions?"** instead of "is this
the one id seen at creation". The pane keeps an append-only enrolment log
(`<mailbox>/sessions.jsonl`); gate D accepts any enrolled id, so a rotation
mid-request can still answer it.

What stops a grandchild enrolling is the SessionStart `source`. The origin still
enrols by first-writer-wins on `session` — that mechanism is unchanged, and is
still what stops a grandchild claiming origin. A later id enrols only on a
rotation source (`clear`/`resume`/`compact`/`fork`), with an origin already
present and `agent_type` matching. A nested `claude` reports `startup`, so it
can never enrol however often it runs.

This report's suggested fix 1 said to have SessionStart *rewrite* `session`.
That was not done, and would have been a mistake: `recordPaneSession` writes
that file with `{ flag: "wx" }` precisely so a grandchild cannot overwrite the
identity gate D checks. First-writer-wins IS the anti-hijack mechanism, so the
enrolment log is additive alongside it rather than a replacement for it.

Fixes 3 and 4 shipped too: a rejected turn is written to `foreign.<ts>.json` and
reported through the existing stranded-turn surfaces (`list`, the nudge,
`wait`'s timeout, `stranded --key <k> --show`), and the send-time error no
longer asserts hijacking as the cause.

**Deferred — fix 2 (process lineage).** Note it is weaker than it reads: a
grandchild is a *descendant* of the pane's process, so it shares the pane's
process group, and a pgid check would admit exactly what it is meant to exclude.
A real lineage check needs the Stop hook's ppid chain to reach the recorded
`pane_pid`, plus confirmation that `/clear` keeps the same pid. Both are
unmeasured, so this was not guessed at.

**Residual risk, accepted:** a grandchild launched from inside the pane with
`--resume` AND the pane's own `agent_type` would report a rotation source and
could enrol. Strictly narrower than the failure it replaces — a routine `/clear`
versus a nested resumed claude with a matching role — and gate E still stops it
answering the wrong request. Closing it is what the deferred lineage work is for.

## Summary

A durable agent's relay binding is pinned to the Claude session id captured
**once, when the pane is created**. Any action that rotates the pane's session
id — `/clear` observed, likely others — leaves that binding stale. Every
subsequent `send` is then rejected by the anti-hijack gate, the agent's reply is
**discarded rather than saved**, and the condition **does not self-heal**. The
pane keeps working for a human typing into it; only the relay is dead.

## Observed behaviour

1. Durable implementor created at `00:30:37Z`. Relay worked — two requests sent
   and answered normally.
2. User ran `/clear` in the pane.
3. Next `send` failed:

   ```
   A Stop hook fired for ah-9066a51b-agent-hierarchy-implementor-1 from a session
   that is NOT the pane — a foreign reply was rejected and the request is still
   outstanding. This is the grandchild-hijack gate firing, not a timeout.
   ```

4. `cancel` cleared the outstanding request. The **next send failed identically.**
5. After a *second* `/clear`, the pane's recorded session id was two rotations
   stale.

## Root cause

The pane directory holds a `session` file written at creation and never updated:

```json
{
  "session_id": "91a1ff6f-2f69-480a-b090-fb75674d35c2",
  "agent_type": "agent-hierarchy:implementor",
  "at": "2026-08-09T00:30:37.016Z"
}
```

`/clear` starts a new Claude session with a new id. The relay's Stop-hook handler
compares the replying session against this pinned value and refuses on mismatch.
From `log.jsonl`:

```
ev=sent      reqid=72b2938c-…  ts=01:23:42.694Z
ev=foreign   reason=session_id
             expected=91a1ff6f-2f69-480a-b090-fb75674d35c2
             got=c1b66c57-04ac-4aa9-8db4-2589cf1b9dc0
             ts=01:24:09.275Z
ev=cancelled reqid=72b2938c-…  ts=01:24:19.490Z
ev=sent      reqid=279f6841-…  ts=01:24:28.510Z
ev=foreign   reason=session_id   (same expected/got pair)
             ts=01:24:31.619Z
```

The gate itself is correct and worth keeping — it exists to stop a stray
grandchild session from answering on the pane's behalf. The defect is that
**the pinned identity is never refreshed**, so a legitimate identity change is
indistinguishable from a hijack.

## Why it is worse than a stalled request

- **The reply is destroyed, not quarantined.** No `unmatched.*.json` was written
  for either rejection. The documented unmatched path (a final message lacking
  the `[ah-reply <id>]` echo) *does* preserve the text; this rejection path does
  not. The agent did the work and the output is gone.
- **`cancel` does not help.** It clears the outstanding request but not the stale
  binding, so the retry fails the same way. The tooling's own guidance points at
  `cancel` as the remedy for a stuck request, which is misleading here.
- **It is permanent and silent.** Nothing marks the agent as unreachable. `list`
  shows it `idle` and healthy. The failure only surfaces on the next `send`, and
  its message names hijacking — pointing the reader away from the real cause.

## Suggested fixes

Roughly in order of preference:

1. **Refresh the pinned id on legitimate rotation.** Have the pane's own
   `SessionStart` hook rewrite `session` with the current id. A rotation
   originating *inside* the pane is exactly what distinguishes a `/clear` from a
   hijack, so this preserves the gate's purpose. Requires the pane to run a hook
   the relay controls.
2. **Verify by process lineage instead of session id.** Accept a reply whose
   originating process belongs to the pane's process group. Identity then
   survives session rotation by construction.
3. **Quarantine rather than discard.** At minimum, write the rejected reply to
   `unmatched.*.json` like the other rejection path. Turns silent data loss into
   a recoverable state.
4. **Detect and report.** When a mismatch is seen, mark the agent `unreachable`
   in `list`, and have the error name session rotation as the likely cause with
   `close`/recreate as the remedy.

Fixes 3 and 4 are cheap and independent of 1 and 2 — worth taking regardless,
since they convert a silent permanent failure into a visible recoverable one.

## Workaround

Close and recreate the durable agent. There is no way to re-bind an existing one.

Where the goal is verifying what a pane's agent has in context, reading its
transcript on disk is strictly better anyway: it is objective, structural, and
immune both to this bug and to the model's own self-report.

## Confidence

- **Verified:** the `session` file contents and its creation-time timestamp; the
  `foreign` / `session_id` log entries with both ids; that `cancel` does not
  restore the relay; that no `unmatched.*.json` was produced; that the pinned id
  was still stale after a second rotation.
- **Inferred:** that `/clear` specifically is what rotates the id — strongly
  implied by the timeline, but not observed directly. Other session-rotating
  operations are untested and probably behave the same way.

## Reproduction

1. `/durable create implementor`
2. Send it any request through the ask flow — confirm a reply comes back.
3. Type `/clear` in the pane.
4. Send it another request. It fails with the grandchild-hijack message, and no
   `unmatched.*.json` appears in the pane directory.
