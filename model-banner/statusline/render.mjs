#!/usr/bin/env node
/**
 * model-banner — the status-line renderer.
 *
 * Invoked (via the generated shim) once per status-line refresh — roughly
 * once a second on a `refreshInterval: 1` setup — so this stays cheap: one
 * readFileSync per config scope, module-level glyph tables, no network, no
 * transcript reading, no git calls.
 *
 * main() never throws and never exits non-zero: a status-line script that
 * crashes degrades the whole footer. Every failure mode (malformed stdin,
 * an unreadable config, a missing glyph, a composition bug) is swallowed,
 * and the chained command's output still makes it to stdout regardless —
 * turning the banner off, or breaking it, must never take the user's
 * existing status line down with it.
 *
 * Output order is chain first, banner after: the banner is the newer,
 * decorative addition and shouldn't push the user's pre-existing status
 * line down out of habitual eye-line. `layout: "side"` composes them
 * side by side instead, banner on the left, chain output to the right of
 * it — an alternative to the default vertical stack.
 */

import { spawnSync } from "node:child_process";
import { resolveConfig } from "../hooks/lib-config.mjs";
import { tierFor } from "../hooks/lib-tiers.mjs";
import { renderWord } from "../hooks/lib-font.mjs";
import { COLORS, RESET, sgr } from "../hooks/lib-color.mjs";

export function main(rawStdin) {
  const resolved = resolveConfigSafe(rawStdin);
  const banner = computeBannerSafe(resolved);
  const chainOutput = runChainSafe(resolved.chain, rawStdin);

  let output;
  try {
    output = compose(banner, chainOutput, resolved.layout);
  } catch {
    output = chainOutput;
  }

  if (output) process.stdout.write(output.replace(/\n+$/, "") + "\n");
}

function resolveConfigSafe(rawStdin) {
  let payload = {};
  try {
    payload = JSON.parse(rawStdin);
  } catch {
    payload = {};
  }
  const cwd = payload && typeof payload.cwd === "string" ? payload.cwd : process.cwd();
  let resolved;
  try {
    resolved = resolveConfig(cwd);
  } catch {
    resolved = { enabled: true, size: "large", layout: "stack", colors: {}, chain: null, warnings: [] };
  }
  resolved.model = payload && typeof payload === "object" ? payload.model : undefined;
  return resolved;
}

/** Returns { rows: string[], colorName: string } | null. Rows are plain text, uncoloured. */
function computeBannerSafe(resolved) {
  try {
    if (!resolved.enabled) return null;
    const tier = tierFor(resolved.model);
    const colorName = resolveColorName(tier, resolved.colors);
    const rows = renderWord(tier.label, resolved.size);
    if (rows.length === 0) return null;
    return { rows, colorName };
  } catch {
    return null;
  }
}

function resolveColorName(tier, configuredColors) {
  const configured = configuredColors && configuredColors[tier.key];
  if (typeof configured === "string" && COLORS[configured] !== undefined) return configured;
  return tier.color;
}

/** Runs the chained command, if any, and returns its stdout (trailing newlines stripped) or "". Never throws. */
function runChainSafe(chain, rawStdin) {
  if (!chain) return "";
  try {
    const r = spawnSync(chain, { shell: true, input: rawStdin, encoding: "utf8", timeout: 2000 });
    if (r.status === 0 && r.stdout) return r.stdout.replace(/\n+$/, "");
  } catch {
    // swallow — the banner, if any, still composes below
  }
  return "";
}

function compose(banner, chainOutput, layout) {
  if (!banner) return chainOutput;
  if (layout === "side") return composeSide(banner.rows, banner.colorName, chainOutput);
  return composeStack(banner.rows, banner.colorName, chainOutput);
}

/** Default layout: chain output first, coloured banner rows below it. */
function composeStack(rows, colorName, chainOutput) {
  const parts = [];
  if (chainOutput) parts.push(chainOutput);
  for (const row of rows) parts.push(sgr(colorName) + row + RESET);
  return parts.join("\n");
}

/**
 * `layout: "side"`: banner on the left, chain output to the right of it,
 * row for row. Banner rows are re-padded to the group's max width first —
 * renderWord right-trims each row individually, which can leave them
 * ragged — so the block stays rectangular and the chain text lines up in
 * one column regardless of which banner row is shortest.
 */
function composeSide(rows, colorName, chainOutput) {
  if (rows.length === 0) return chainOutput;
  const width = Math.max(...rows.map((r) => r.length));
  const chainLines = chainOutput ? chainOutput.split("\n") : [];
  const rowCount = Math.max(rows.length, chainLines.length);
  const out = [];
  for (let i = 0; i < rowCount; i++) {
    const hasBannerRow = i < rows.length;
    const plain = hasBannerRow ? rows[i].padEnd(width) : " ".repeat(width);
    const chainText = chainLines[i] || "";
    if (!hasBannerRow && !chainText) continue;
    const bannerPart = hasBannerRow ? sgr(colorName) + plain + RESET : plain;
    out.push(chainText ? `${bannerPart}  ${chainText}` : bannerPart);
  }
  return out.join("\n");
}

// Run directly (piped stdin): read it once, then call main() with the raw
// string — the same entry point the generated shim calls via import().
if (process.argv[1] && process.argv[1].endsWith("render.mjs")) {
  const chunks = [];
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => {
    main(Buffer.concat(chunks).toString("utf8"));
  });
}
