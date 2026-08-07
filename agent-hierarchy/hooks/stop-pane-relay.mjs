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
  const { appendFileSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } = await import("node:fs");
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
  if (typeof pending.expect_session === "string" && pending.expect_session && input.session_id !== pending.expect_session) {
    log({ ev: "foreign", reason: "session_id", expected: pending.expect_session, got: input.session_id ?? null });
    process.exit(0);
  }

  let text = typeof input.last_assistant_message === "string" ? input.last_assistant_message : "";

  // Gate E — content. Gates B and D prove WHO answered; nothing above proves
  // WHICH question was answered. A human typing into the pane mid-request can
  // make the next Stop an answer to *their* question, from the right agent in
  // the right session — so `send` stamps `[ah-request <reqid>]` into the
  // delivered prompt and the pane must open its final message with the line
  // `[ah-reply <reqid>]`. No echo, or the wrong one → the turn is SAVED as
  // unmatched (it may be the human's answer, or a real reply from an agent
  // that forgot the line — either way it is evidence, not a relay) and the
  // token survives for the turn that does echo. Pendings written before the
  // envelope existed carry no `echo` flag and relay on turn order as before.
  if (pending.echo) {
    const m = /^\s*\[ah-reply ([A-Za-z0-9-]+)\][ \t]*\r?\n?/.exec(text);
    if (!m || m[1] !== pending.reqid) {
      const saved = join(dir, `unmatched.${Date.now()}.json`);
      const tmpU = `${saved}.tmp`;
      mkdirSync(dir, { recursive: true });
      writeFileSync(tmpU, JSON.stringify({ reqid_expected: pending.reqid, session_id: input.session_id ?? null, at: new Date().toISOString(), text }));
      renameSync(tmpU, saved);
      log({ ev: "unmatched", reqid: pending.reqid, got: m ? m[1] : null, chars: text.length });
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

  log({ ev: "replied", reqid: pending.reqid, chars: text.length });
} catch {
  /* a broken relay must never block the session it is attached to */
}

process.exit(0);
