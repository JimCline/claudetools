#!/usr/bin/env node
/**
 * comment-discipline — `sweep`: find comments that violate the directive's do-not classes.
 *
 * Deterministic pre-filter, no judgment. It reports CANDIDATES; deciding keep/remove/rewrite is the
 * caller's job (the `/comment-discipline sweep` command fans that out). Precision beats recall here:
 * a false positive costs a reviewer one glance, while flagging half the codebase costs the whole
 * exercise its credibility, so the patterns stay narrow and literal.
 *
 * Usage:
 *   node hooks/sweep.mjs [path…] [--json] [--count]
 *
 * Paths default to the repo root. Only git-tracked files are read — an untracked build artefact is
 * not someone's comment. `docs/specs/**` is excluded by design: spec prose cites specs for a living.
 *
 * Exit 0 with or without hits; a non-zero exit means the sweep itself failed.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { extname } from "node:path";
import { fileURLToPath } from "node:url";

/** The do-not classes, each a list of patterns tested against comment TEXT only. Exported for tests. */
export const CLASSES = {
  references: [
    /#\d+\b/, //                       issue/PR number
    /\b[A-Z]{2,}-\d+\b/, //            JIRA-style key
    /\bspec \d{3,4}\b/i, //            spec number
    /§/, //                            section mark
    /\bper r\d+\b/i, //                review round
    /\br\d\b(?=.*\b(review|round|fix)\b)/i,
    /NEEDS-EVIDENCE/,
    /\b[EUDNT]\d+\b/, //               finding IDs (E1, U2, D3, N4, T6)
    /\bper review\b/i,
    /\bas (decided|ruled)\b/i,
    /\b(decision|ruling) (above|below|in)\b/i,
  ],
  "change-narration": [
    /\bchanged from\b/i,
    /\bnow uses\b/i,
    /\bremoved the\b/i,
    /\bNEW:/,
    /\bupdated to\b/i,
    /\bpreviously\b/i,
    /\bused to\b/i,
    /\bas suggested\b/i,
  ],
  "time-markers": [/\bfor now\b/i, /\btemporary\b/i, /\bwill remove later\b/i],
  "todo-with-ref": [/TODO\s*\(/],
};

const LINE_MARKERS = {
  slash: "//",
  hash: "#",
  dash: "--",
};
const EXT_SYNTAX = {
  slash: [".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".java", ".go", ".rs", ".swift", ".kt", ".kts", ".scala", ".php", ".m", ".mm", ".dart", ".zig"],
  hash: [".py", ".sh", ".bash", ".zsh", ".rb", ".pl", ".yml", ".yaml", ".toml", ".gd", ".tf", ".r", ".cmake", ".mk", ".nix"],
  dash: [".sql", ".lua", ".hs", ".elm", ".adb"],
  block: [".css", ".scss", ".less"],
  html: [".html", ".htm", ".xml", ".svg", ".vue"],
};
const SYNTAX_OF = (() => {
  const m = new Map();
  for (const [kind, exts] of Object.entries(EXT_SYNTAX)) for (const e of exts) m.set(e, kind);
  return m;
})();

/** Comment text on one line, or null. Naive on purpose: a marker inside a string literal is a known, accepted false positive. */
export function commentText(line, kind) {
  const marker = LINE_MARKERS[kind];
  if (marker) {
    const i = line.indexOf(marker);
    if (i !== -1 && !inQuotes(line, i)) return line.slice(i + marker.length).trim();
  }
  if (kind === "slash" || kind === "block") {
    const i = line.indexOf("/*");
    if (i !== -1) return line.slice(i + 2).replace(/\*\/.*$/, "").trim();
    const s = line.trim();
    if (s.startsWith("*") && !s.startsWith("*/")) return s.slice(1).trim();
  }
  if (kind === "html") {
    const i = line.indexOf("<!--");
    if (i !== -1) return line.slice(i + 4).replace(/-->.*$/, "").trim();
  }
  return null;
}

function inQuotes(line, idx) {
  let single = 0;
  let dbl = 0;
  for (let i = 0; i < idx; i++) {
    const c = line[i];
    if (c === "\\") { i++; continue; }
    if (c === "'") single++;
    else if (c === '"') dbl++;
  }
  return single % 2 === 1 || dbl % 2 === 1;
}

function classify(text) {
  const hit = [];
  for (const [name, patterns] of Object.entries(CLASSES)) {
    if (patterns.some((re) => re.test(text))) hit.push(name);
  }
  return hit;
}

function trackedFiles(paths, cwd) {
  const out = execFileSync("git", ["ls-files", "-z", "--", ...(paths.length ? paths : ["."])], {
    cwd,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return out.split("\0").filter(Boolean);
}

/** Sweep `paths` and return one record per flagged comment line. */
export function sweep(paths, cwd = process.cwd()) {
  const hits = [];
  for (const rel of trackedFiles(paths, cwd)) {
    if (rel.includes("docs/specs/")) continue;
    const kind = SYNTAX_OF.get(extname(rel).toLowerCase());
    if (!kind) continue;
    let body;
    try {
      body = readFileSync(rel.startsWith("/") ? rel : `${cwd}/${rel}`);
    } catch {
      continue;
    }
    if (body.includes(0)) continue;
    const lines = body.toString("utf8").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const text = commentText(lines[i], kind);
      if (!text) continue;
      for (const cls of classify(text)) hits.push({ file: rel, line: i + 1, class: cls, text });
    }
  }
  return hits;
}

const argv = process.argv.slice(2);
// realpath both sides: on macOS an invocation through /tmp or /var reaches this file by a symlinked
// path, and a raw string compare would silently skip the whole CLI block.
const real = (p) => { try { return realpathSync(p); } catch { return p; } };
const isMain = process.argv[1] && real(fileURLToPath(import.meta.url)) === real(process.argv[1]);
if (isMain) {
  const json = argv.includes("--json");
  const countOnly = argv.includes("--count");
  const paths = argv.filter((a) => !a.startsWith("--"));
  let hits;
  try {
    hits = sweep(paths);
  } catch (e) {
    process.stderr.write(`sweep failed: ${e.message}\n`);
    process.exit(1);
  }
  if (json) {
    process.stdout.write(`${JSON.stringify({ count: hits.length, hits }, null, 2)}\n`);
  } else if (countOnly) {
    process.stdout.write(`${hits.length}\n`);
  } else {
    for (const cls of Object.keys(CLASSES)) {
      const group = hits.filter((h) => h.class === cls);
      if (!group.length) continue;
      process.stdout.write(`\n${cls} (${group.length})\n`);
      for (const h of group) process.stdout.write(`  ${h.file}:${h.line}: ${h.text}\n`);
    }
    process.stdout.write(`\n${hits.length} candidate${hits.length === 1 ? "" : "s"}. Each still needs a human or a judging agent: a reference may be the only thing wrong with an otherwise durable comment.\n`);
  }
  process.exit(0);
}
