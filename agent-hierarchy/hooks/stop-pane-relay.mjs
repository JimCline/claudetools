#!/usr/bin/env node
/**
 * agent-hierarchy — the pane reply relay (Stop hook).
 *
 * A paned agent has no tool and no address for contacting the Orchestrator.
 * Instead, when the Orchestrator sends work it drops a `pending` token in the
 * pane's mailbox; this hook turns the pane's final assistant message into
 * `reply.<reqid>.json` and consumes the token. No pending token, no reply —
 * which is what makes "only the Orchestrator may initiate" a mechanism rather
 * than an instruction. A turn the user typed into the pane themselves stays
 * private to the pane, for free.
 *
 * This runs on EVERY Stop in EVERY session on the machine, so the no-op path
 * is one environment lookup: no imports, no stdin, no filesystem. Everything
 * else is loaded dynamically, after the gate.
 *
 * The reply text comes from `last_assistant_message` and NEVER from
 * `transcript_path`. Reading the transcript at Stop time is racy: the hook has
 * been observed seeing 23 lines where the finished file had 27, with the
 * assistant's text entry not yet flushed, extracting zero characters.
 */

const dir = process.env.AGENT_HIERARCHY_PANE_DIR;
if (!dir) process.exit(0);

const declaredRole = process.env.AGENT_HIERARCHY_PANE_ROLE || null;
const paneKey = process.env.AGENT_HIERARCHY_PANE_KEY || null;

try {
  const { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync, writeSync } = await import("node:fs");
  const { join } = await import("node:path");

  const log = (event) => {
    try {
      mkdirSync(dir, { recursive: true });
      appendFileSync(join(dir, "log.jsonl"), JSON.stringify({ ...event, key: paneKey, at: new Date().toISOString() }) + "\n");
    } catch {
      /* the audit trail must never block the session this hook is attached to */
    }
  };

  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  let input = {};
  try {
    input = JSON.parse(Buffer.concat(chunks).toString("utf8").trim() || "{}");
  } catch {
    input = {};
  }

  // Gate B — identity. Env vars are inherited by child processes, so a paned
  // Implementor that shells out to `claude` would produce a grandchild whose
  // Stop hook lands in this mailbox and answers in the parent's name.
  if (declaredRole && input.agent_type !== declaredRole) {
    log({ ev: "foreign", reason: "agent_type", expected: declaredRole, got: input.agent_type ?? null });
    process.exit(0);
  }

  let pending = null;
  try {
    pending = JSON.parse(readFileSync(join(dir, "pending"), "utf8"));
  } catch {
    pending = null;
  }
  if (!pending || typeof pending.reqid !== "string" || !pending.reqid) {
    log({ ev: "silent" });
    process.exit(0);
  }

  // Gate D — belt-and-braces on B, for a grandchild that somehow reports the
  // same agent_type. Neither gate consumes the token: a rejected Stop must
  // leave `pending` in place so the real pane can still answer.
  //
  // The test is "is this one of THIS PANE's sessions", not "is this the one id
  // seen at creation". Pinning the creation id meant a `/clear` — which rotates
  // the id — made every later reply look like a hijack, and the work was
  // destroyed. Enrolment (lib-pane's enrolSession) is what admits a rotated id
  // while still shutting out a grandchild, which can only ever report `startup`.
  let text = typeof input.last_assistant_message === "string" ? input.last_assistant_message : "";

  let enrolled = [];
  try {
    const { enrolledSessions } = await import("./lib-pane.mjs");
    enrolled = enrolledSessions(dir);
  } catch {
    enrolled = [];
  }
  // With no enrolment data at all — a mailbox this build never wrote — fall
  // back to the old comparison rather than accepting anything.
  const known = enrolled.length ? enrolled : pending.expect_session ? [pending.expect_session] : [];
  if (known.length && !known.includes(input.session_id)) {
    const saved = join(dir, `foreign.${Date.now()}.json`);
    const tmpF = `${saved}.tmp`;
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      tmpF,
      JSON.stringify({
        reqid_expected: pending.reqid,
        session_id: input.session_id ?? null,
        expected_sessions: known,
        agent_type: input.agent_type ?? null,
        at: new Date().toISOString(),
        text,
      })
    );
    renameSync(tmpF, saved);
    log({ ev: "foreign", reason: "session_id", expected: known.join(","), got: input.session_id ?? null, chars: text.length });
    process.exit(0);
  }

  // Gate E — content. Gates B and D prove WHO answered; nothing above proves
  // WHICH question was answered. A human typing into the pane mid-request can
  // make the next Stop an answer to *their* question, from the right agent in
  // the right session — so `send` stamps `[ah-request <reqid>]` into the
  // delivered prompt and the pane must open its final message with the line
  // `[ah-reply <reqid>]`. No echo, or the wrong one → the turn is never
  // relayed, and the token survives for the turn that does echo. Pendings
  // written before the envelope existed carry no `echo` flag and relay on turn
  // order as before.
  //
  // The gate is not softened — a human's answer must never reach the
  // Orchestrator — but it no longer fails silently, which stranded finished
  // work whenever a compaction took the reqid with it. The pane gets ONE
  // chance to correct itself, with the id supplied, and only the pane can tell
  // the two cases apart: it either re-sends with the echo, or declares
  // `[ah-not-a-reply]`. Either way the text is kept.
  if (pending.echo) {
    const m = /^\s*\[ah-reply ([A-Za-z0-9-]+)\][ \t]*\r?\n?/.exec(text);
    if (!m || m[1] !== pending.reqid) {
      const nagPath = join(dir, `nag.${pending.reqid}.json`);
      const declined = /^\s*\[ah-not-a-reply\][ \t]*\r?\n?/.exec(text);

      // One retry, then give up. The guard is the nag FILE, not
      // `stop_hook_active`: that field is absent from Claude Code's documented
      // Stop input, so a loop guard resting on it would rest on nothing. It is
      // honoured when present, as a second belt.
      const giveUp = declined
        ? "declined"
        : existsSync(nagPath)
          ? "already_nagged"
          : input.stop_hook_active === true
            ? "stop_hook_active"
            : null;

      if (!giveUp) {
        mkdirSync(dir, { recursive: true });
        const tmpN = `${nagPath}.tmp`;
        writeFileSync(tmpN, JSON.stringify({ reqid: pending.reqid, at: new Date().toISOString(), session_id: input.session_id ?? null, text }));
        renameSync(tmpN, nagPath);
        log({ ev: "nagged", reqid: pending.reqid, got: m ? m[1] : null, chars: text.length });
        // writeSync, not process.stdout.write: stdout to a pipe is async and
        // process.exit can truncate it, which would silently turn the block
        // into a no-op.
        writeSync(
          1,
          JSON.stringify({
            decision: "block",
            reason:
              `Your final message was not relayed to the Orchestrator: it must begin with the request-id echo line and it did not. The outstanding request is ${pending.reqid}.\n\n` +
              `If that message WAS your answer to the Orchestrator: send it again, unchanged, with this as its exact first line — [ah-reply ${pending.reqid}]\n\n` +
              `If that message was a reply to a human typing directly into this pane, and not an answer to the Orchestrator, say so with [ah-not-a-reply] as the first line and it will be filed without being relayed.`,
          })
        );
        process.exit(0);
      }

      // Giving up: the nag's text is folded in, so neither turn is ever lost.
      let priorText = null;
      try {
        priorText = JSON.parse(readFileSync(nagPath, "utf8")).text ?? null;
      } catch {
        priorText = null;
      }
      const saved = join(dir, `unmatched.${Date.now()}.json`);
      const tmpU = `${saved}.tmp`;
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        tmpU,
        JSON.stringify({
          reqid_expected: pending.reqid,
          session_id: input.session_id ?? null,
          at: new Date().toISOString(),
          reason: giveUp,
          prior_text: priorText,
          text: declined ? text.slice(declined[0].length) : text,
        })
      );
      renameSync(tmpU, saved);
      try {
        unlinkSync(nagPath);
      } catch {
        /* nothing to fold in — the unmatched record stands alone */
      }
      log({ ev: "unmatched", reqid: pending.reqid, got: m ? m[1] : null, reason: giveUp, chars: text.length });
      process.exit(0);
    }
    text = text.slice(m[0].length);
  }

  const reply = {
    reqid: pending.reqid,
    answered_at: new Date().toISOString(),
    session_id: input.session_id ?? null,
    agent_type: input.agent_type ?? null,
    transcript_path: input.transcript_path ?? null,
    permission_mode: input.permission_mode ?? null,
    echoed: Boolean(pending.echo),
    text,
  };

  // Write the reply BEFORE consuming the token. Dying between the two leaves
  // the reply on disk with `pending` intact, which the Orchestrator can see;
  // unlinking first and then dying would lose the answer and the evidence.
  const target = join(dir, `reply.${pending.reqid}.json`);
  const tmp = `${target}.tmp`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(tmp, JSON.stringify(reply));
  renameSync(tmp, target);

  try {
    unlinkSync(join(dir, "pending"));
  } catch {
    /* already gone — the reply is what matters */
  }

  // The retry landed, so the nag is no longer stranded work and must stop being
  // reported as such.
  try {
    unlinkSync(join(dir, `nag.${pending.reqid}.json`));
  } catch {
    /* the common case: this turn echoed first time and no nag was ever written */
  }

  log({ ev: "replied", reqid: pending.reqid, chars: text.length });
} catch {
  /* a broken relay must never block the session it is attached to */
}

process.exit(0);
