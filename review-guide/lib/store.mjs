#!/usr/bin/env node
/**
 * review-guide — shared store: git-common-dir resolution, branchkey, the
 * append-only JSONL ledger, base-record resolution, and the change/annotated/
 * skipped/unannotated sets `note`, `status`, and `guide` all compute the same
 * way (spec 0002 §3–§4).
 *
 * All git access goes through `execFileSync("git", [...])` — never a shell
 * string.
 */

import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

function git(args, cwd) {
  try {
    return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

function gitLines(args, cwd) {
  const out = git(args, cwd);
  if (!out) return [];
  return out.split("\n").filter(Boolean);
}

export function repoRoot(cwd) {
  return git(["rev-parse", "--show-toplevel"], cwd);
}

export function headSha(cwd) {
  return git(["rev-parse", "HEAD"], cwd);
}

/**
 * The repository's git-common-dir, resolved against the repo root (never
 * `process.cwd()` — `--git-common-dir` may return a relative path, typically
 * `.git`). Correction to 1a0g §[1].1 (spec §3.1): `--git-dir` in a linked
 * worktree returns that worktree's private dir, destroyed by
 * `git worktree remove`; `--git-common-dir` belongs to the repository and
 * outlives any worktree.
 */
export function gitCommonDir(cwd) {
  const root = repoRoot(cwd);
  if (!root) return null;
  const raw = git(["rev-parse", "--git-common-dir"], cwd);
  if (!raw) return null;
  return isAbsolute(raw) ? raw : resolve(root, raw);
}

export function storeDir(cwd) {
  const common = gitCommonDir(cwd);
  return common ? join(common, "review-guide") : null;
}

/** Current branch name, or null on detached HEAD (`symbolic-ref` exits non-zero). */
export function currentBranch(cwd) {
  return git(["symbolic-ref", "--short", "HEAD"], cwd);
}

/** `feat/x` -> `feat-x`; detached HEAD -> `detached` (never the SHA — it changes every commit). */
export function branchKey(cwd) {
  const branch = currentBranch(cwd);
  if (!branch) return "detached";
  return branch.replace(/[^A-Za-z0-9._-]/g, "-");
}

export function ledgerPath(cwd) {
  const dir = storeDir(cwd);
  return dir ? join(dir, `${branchKey(cwd)}.jsonl`) : null;
}

/** Append-only JSONL read. Malformed lines are skipped; a missing file reads as empty. */
export function readLedger(path) {
  if (!path || !existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      // corrupt line: skip it, do not fail the whole read
    }
  }
  return out;
}

export function appendLedger(path, record) {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(record) + "\n");
}

/** `git hash-object` of the working-tree bytes, so untracked/unstaged files hash identically to how git would. */
export function hashObject(cwd, absPath) {
  try {
    return execFileSync("git", ["hash-object", "--stdin"], { cwd, input: readFileSync(absPath), encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

function mergeBaseSha(cwd, ref) {
  return git(["merge-base", ref, "HEAD"], cwd);
}

/**
 * Base resolution order (§3.3), used ONLY when writing the `base` record —
 * every later `note`/`guide`/`status` reads it back and never re-derives.
 *
 * Fix A: step 2's guard is load-bearing. `git push -u` sets the upstream to
 * `origin/<same-branch>`; unguarded, the merge-base of that with HEAD is HEAD
 * itself, so the change scope computes as empty and — because the result is
 * pinned permanently — that wrong answer is frozen for the life of the
 * branch. Skip `@{upstream}` when its branch component equals the current
 * branch name.
 */
export function resolveBase(cwd, baseFlag) {
  const branch = currentBranch(cwd);
  const ordered = [];
  if (baseFlag) ordered.push(baseFlag);

  const upstream = git(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd);
  if (upstream) {
    const upstreamBranch = upstream.includes("/") ? upstream.slice(upstream.indexOf("/") + 1) : upstream;
    if (!(branch && upstreamBranch === branch)) ordered.push(upstream);
  }

  ordered.push("origin/HEAD", "origin/main", "origin/master", "main", "master");

  for (const ref of ordered) {
    const sha = mergeBaseSha(cwd, ref);
    if (sha) return { base: ref, base_sha: sha };
  }
  return { base: null, base_sha: null };
}

/**
 * The ledger's `kind:"base"` record, writing one (and reporting on stderr) if
 * this is the ledger's first use. Every subsequent call for the same ledger
 * reads the existing record back rather than re-deriving — re-deriving later
 * would silently change the answer once `origin/HEAD` moves, an upstream is
 * set mid-branch, or the default branch is renamed.
 */
export function ensureBase(cwd, ledger, path, baseFlag) {
  const existing = ledger.find((r) => r && r.kind === "base");
  if (existing) return existing;
  const resolved = resolveBase(cwd, baseFlag);
  const rec = { kind: "base", ts: new Date().toISOString(), base: resolved.base, base_sha: resolved.base_sha };
  appendLedger(path, rec);
  ledger.push(rec);
  if (!resolved.base) {
    process.stderr.write("review-guide: no base ref resolved; change scope is working tree vs HEAD only.\n");
  } else {
    process.stderr.write(`review-guide: wrote base record (base=${resolved.base}).\n`);
  }
  return rec;
}

/** Union of the four §4.1 sources. Deleted paths are included (git diff --name-only lists them). */
export function changedFiles(cwd, baseSha) {
  const set = new Set();
  if (baseSha) for (const p of gitLines(["diff", "--name-only", `${baseSha}...HEAD`], cwd)) set.add(p);
  for (const p of gitLines(["diff", "--name-only", "HEAD"], cwd)) set.add(p);
  for (const p of gitLines(["diff", "--name-only", "--cached"], cwd)) set.add(p);
  for (const p of gitLines(["ls-files", "--others", "--exclude-standard"], cwd)) set.add(p);
  return [...set];
}

/**
 * A changed file is `annotated` iff some `note` record's `files` entry for
 * that path has `blob` equal to the file's *current* `git hash-object`
 * (§4.2). A deleted path has no current hash, so it counts as annotated iff
 * ANY note names it at all. Same test against `skip` records makes a file
 * `skipped`. The latest matching record wins (ledger order); everything else
 * changed is `unannotated`.
 */
export function classify(cwd, changed, ledger) {
  const notes = ledger.filter((r) => r && r.kind === "note");
  const skips = ledger.filter((r) => r && r.kind === "skip");
  const root = repoRoot(cwd) || cwd;

  function latestMatch(records, path, exists, currentHash) {
    for (let i = records.length - 1; i >= 0; i--) {
      const rec = records[i];
      const f = (rec.files || []).find((e) => e.path === path);
      if (!f) continue;
      if (!exists) return rec; // deleted file: any mention counts
      if (f.blob !== null && f.blob === currentHash) return rec;
    }
    return null;
  }

  const annotated = [];
  const skipped = [];
  const unannotated = [];
  for (const path of changed) {
    const abs = resolve(root, path);
    const exists = existsSync(abs);
    const currentHash = exists ? hashObject(cwd, abs) : null;
    const noteHit = latestMatch(notes, path, exists, currentHash);
    if (noteHit) {
      annotated.push({ path, note: noteHit });
      continue;
    }
    const skipHit = latestMatch(skips, path, exists, currentHash);
    if (skipHit) {
      skipped.push({ path, note: skipHit });
      continue;
    }
    unannotated.push({ path });
  }
  return { annotated, skipped, unannotated, notes, skips };
}
