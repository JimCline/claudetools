#!/usr/bin/env node
/**
 * review-guide — `guide.mjs note|status|guide` (spec 0002 §5). Node, no
 * dependencies, pure tooling: nothing here is enforced, nothing runs on its
 * own. Renamed from the working name `rg.mjs` — `rg` is ripgrep, and
 * `rg.mjs guide` invites a reader to run ripgrep instead.
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

import {
  appendLedger,
  branchKey,
  changedFiles,
  classify,
  ensureBase,
  hashObject,
  headSha,
  ledgerPath,
  readLedger,
  repoRoot,
  storeDir,
} from "../lib/store.mjs";

function fail(msg) {
  process.stderr.write(`guide.mjs: ${msg}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const flags = { watch: [] };
  const positionals = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--watch") flags.watch.push(argv[++i]);
    else if (a === "--files") flags.files = argv[++i];
    else if (a === "--out") flags.out = argv[++i];
    else if (a === "--pr") flags.pr = true;
    else if (a === "--skip") flags.skip = argv[++i];
    else if (a === "--base") flags.base = argv[++i];
    else positionals.push(a);
  }
  return { positionals, flags };
}

function requireLedgerPath(cwd) {
  const path = ledgerPath(cwd);
  if (!path) fail("not inside a git checkout (git rev-parse --git-common-dir failed)");
  return path;
}

// ---------------------------------------------------------------- note

function cmdNote(argv, cwd) {
  const { positionals, flags } = parseArgs(argv);
  const isSkip = typeof flags.skip === "string";
  if (isSkip && flags.watch.length) fail("--skip and --watch are mutually exclusive");

  const narration = isSkip ? flags.skip : positionals[0];
  if (typeof narration !== "string" || narration.trim() === "") fail("narration is required and must not be empty");
  for (const w of flags.watch) {
    if (typeof w !== "string" || w.trim() === "") fail("--watch value must not be empty");
  }

  let files = isSkip ? positionals : positionals.slice(1);
  if (flags.files) files = flags.files.split(",").map((s) => s.trim()).filter(Boolean);

  const path = requireLedgerPath(cwd);
  const ledger = readLedger(path);
  const base = ensureBase(cwd, ledger, path, flags.base);

  if (!files.length) files = changedFiles(cwd, base.base_sha);

  const root = repoRoot(cwd) || cwd;
  const fileEntries = files.map((p) => {
    const abs = resolve(root, p);
    return { path: p, blob: existsSync(abs) ? hashObject(cwd, abs) : null };
  });

  const rec = isSkip
    ? { kind: "skip", ts: new Date().toISOString(), note: narration, files: fileEntries }
    : {
        kind: "note",
        ts: new Date().toISOString(),
        note: narration,
        ...(flags.watch.length ? { watch: flags.watch } : {}),
        files: fileEntries,
      };

  appendLedger(path, rec);
  process.stdout.write(`review-guide: recorded ${rec.kind} for ${fileEntries.length} file(s)\n`);
}

// ---------------------------------------------------------------- status

function cmdStatus(argv, cwd) {
  const { flags } = parseArgs(argv);
  const path = requireLedgerPath(cwd);
  const ledger = readLedger(path);
  const base = ensureBase(cwd, ledger, path, flags.base);
  const changed = changedFiles(cwd, base.base_sha);
  const { annotated, skipped, unannotated, notes } = classify(cwd, changed, ledger);
  const watchCount = notes.reduce((n, r) => n + (r.watch ? r.watch.length : 0), 0);

  const lines = [
    `branch: ${branchKey(cwd)}`,
    `base: ${base.base || "(none)"}${base.base_sha ? ` (${base.base_sha})` : ""}`,
    `ledger: ${path}`,
    `notes: ${notes.length}`,
    `${annotated.length} of ${changed.length - skipped.length} annotated (${skipped.length} skipped)`,
    `watch flags: ${watchCount}`,
  ];
  if (unannotated.length) {
    lines.push("unannotated:");
    for (const u of unannotated) lines.push(`  - ${u.path}`);
  }
  process.stdout.write(lines.join("\n") + "\n");
}

// ---------------------------------------------------------------- guide

function numstat(cwd, baseSha, path) {
  let added = 0;
  let removed = 0;
  const runs = [];
  if (baseSha) runs.push(["diff", "--numstat", `${baseSha}...HEAD`, "--", path]);
  runs.push(["diff", "--numstat", "HEAD", "--", path]);
  runs.push(["diff", "--numstat", "--cached", "--", path]);
  for (const args of runs) {
    let out;
    try {
      out = execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
    } catch {
      continue;
    }
    if (!out) continue;
    const [a, r] = out.split("\n")[0].split("\t");
    if (a !== "-") added += Number(a) || 0;
    if (r !== "-") removed += Number(r) || 0;
    if (added || removed) return { added, removed };
  }
  return { added, removed };
}

function renderWatchList(notes) {
  const flags = [];
  for (const note of notes) {
    if (!note.watch || !note.watch.length) continue;
    const files = (note.files || []).map((f) => `\`${f.path}\``).join(", ");
    for (const flag of note.watch) flags.push(`- ${flag} — ${files}`);
  }
  if (!flags.length) return "";
  return ["### Watch list", "", "Everything flagged for scrutiny, across the whole change:", "", ...flags, ""].join("\n");
}

function renderReadingOrder(annotated, ledger) {
  const groups = new Map(); // note object -> paths[]
  const order = [];
  for (const { path, note } of annotated) {
    if (!groups.has(note)) {
      groups.set(note, []);
      order.push(note);
    }
    groups.get(note).push(path);
  }
  order.sort((a, b) => ledger.indexOf(a) - ledger.indexOf(b));

  const out = ["### Reading order", ""];
  order.forEach((note, i) => {
    const paths = groups.get(note);
    out.push(`${i + 1}. **${paths.map((p) => `\`${p}\``).join(", ")}**`, "");
    out.push(`   ${note.note}`, "");
    if (note.watch && note.watch.length) {
      out.push("   **Watch:**");
      for (const flag of note.watch) out.push(`   - ${flag}`);
      out.push("");
    }
  });
  return out.join("\n");
}

function renderUnannotated(unannotated, cwd, baseSha) {
  if (!unannotated.length) return "";
  const lines = ["### Changed but not annotated", ""];
  for (const u of unannotated) {
    const { added, removed } = numstat(cwd, baseSha, u.path);
    lines.push(`- ${u.path} (+${added} −${removed}) — _no note; auto-derived from diff stat_`);
  }
  lines.push("");
  return lines.join("\n");
}

function renderSkipped(skipped) {
  if (!skipped.length) return "";
  const lines = ["### Skipped as trivial", ""];
  for (const s of skipped) lines.push(`- ${s.path} — _${s.note.note}_`);
  lines.push("");
  return lines.join("\n");
}

function renderDiffStat(cwd, baseSha) {
  const parts = [];
  if (baseSha) {
    const out = (() => {
      try {
        return execFileSync("git", ["diff", "--stat", `${baseSha}...HEAD`], { cwd, encoding: "utf8" }).trim();
      } catch {
        return "";
      }
    })();
    if (out) parts.push(out);
  }
  const wt = (() => {
    try {
      return execFileSync("git", ["diff", "--stat", "HEAD"], { cwd, encoding: "utf8" }).trim();
    } catch {
      return "";
    }
  })();
  if (wt) parts.push(wt);
  const body = parts.length ? parts.join("\n") : "(no diff)";
  return ["### Diff stat", "", "```", body, "```", ""].join("\n");
}

function renderGuide({ cwd, branch, base, changed, annotated, skipped, unannotated, notes, ledger }) {
  const head = headSha(cwd) || "(unknown)";
  const denom = changed.length - skipped.length;
  const marker = `<!-- review-guide: generated branch=${branch} base=${base.base || "null"} head=${head} annotated=${annotated.length} changed=${changed.length} skipped=${skipped.length} -->`;

  const parts = [
    marker,
    "## Reviewer's guide",
    "",
    "_Generated by `review-guide`. Do not hand-edit — regenerate with `guide.mjs guide`._",
    "",
    `**${annotated.length} of ${denom} changed files annotated.** (${skipped.length} skipped as trivial.)`,
    "",
  ];

  const watchMd = renderWatchList(notes);
  if (watchMd) parts.push(watchMd, "");

  parts.push(renderReadingOrder(annotated, ledger), "");
  const unannotatedMd = renderUnannotated(unannotated, cwd, base.base_sha);
  if (unannotatedMd) parts.push(unannotatedMd, "");
  const skippedMd = renderSkipped(skipped);
  if (skippedMd) parts.push(skippedMd, "");
  parts.push(renderDiffStat(cwd, base.base_sha));

  return parts.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

function cmdGuide(argv, cwd) {
  const { flags } = parseArgs(argv);
  const path = requireLedgerPath(cwd);
  const ledger = readLedger(path);
  const base = ensureBase(cwd, ledger, path, flags.base);
  const changed = changedFiles(cwd, base.base_sha);
  const { annotated, skipped, unannotated, notes } = classify(cwd, changed, ledger);
  const branch = branchKey(cwd);

  const md = renderGuide({ cwd, branch, base, changed, annotated, skipped, unannotated, notes, ledger });

  const outPath = flags.out ? resolve(cwd, flags.out) : resolve(storeDir(cwd), `${branch}.guide.md`);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, md, "utf8");
  process.stdout.write(`review-guide: wrote ${outPath}\n`);

  if (flags.pr) {
    // §5.4: print both forms, execute neither — a helper script should not
    // perform an outward-facing action as a side effect of compiling a
    // document, and detecting which applies would mean a network call.
    process.stdout.write(
      [
        "",
        "# if no PR exists for this branch yet:",
        `gh pr create --body-file ${outPath}`,
        "",
        "# if a PR already exists:",
        `gh pr edit --body-file ${outPath}`,
        "",
      ].join("\n")
    );
  }
}

// ---------------------------------------------------------------- main

const [, , cmd, ...rest] = process.argv;
const cwd = process.cwd();

if (cmd === "note") cmdNote(rest, cwd);
else if (cmd === "status") cmdStatus(rest, cwd);
else if (cmd === "guide") cmdGuide(rest, cwd);
else fail(`unknown subcommand "${cmd || ""}" — expected note, status, or guide`);
