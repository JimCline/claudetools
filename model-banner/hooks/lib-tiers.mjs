/**
 * model-banner — the model-tier registry.
 *
 * Single table: adding a model tier costs exactly one row here and zero
 * edits anywhere else. Order matters and is the array order — the first
 * match wins, so keep tokens ordered so none is a substring of another.
 */

import { FONT_LARGE } from "./lib-font.mjs";

export const TIERS = [
  { key: "sonnet", match: ["sonnet"], label: "SONNET", color: "green" },
  { key: "opus", match: ["opus"], label: "OPUS", color: "yellow" },
  { key: "fable", match: ["fable"], label: "FABLE", color: "red" },
  { key: "haiku", match: ["haiku"], label: "HAIKU", color: "cyan" },
];

export const DEFAULT_TIER = { key: "default", label: null, color: "white" };

const GLYPH_CHARS = new Set(Object.keys(FONT_LARGE));

function sanitizeLabel(raw) {
  const kept = [...raw].filter((ch) => GLYPH_CHARS.has(ch)).join("");
  return kept.replace(/ +/g, " ").trim();
}

/**
 * Input: the `model` object from the stdin JSON ({ id, display_name }), which
 * may be undefined or malformed. Substring match, never equality — model ids
 * drift across releases, and the config is keyed by tier, not by id.
 */
export function tierFor(model) {
  const haystack = `${model?.id ?? ""} ${model?.display_name ?? ""}`.toLowerCase();
  for (const tier of TIERS) {
    if (tier.match.some((token) => haystack.includes(token))) return tier;
  }

  const rawLabel = String(model?.display_name || model?.id || "CLAUDE").toUpperCase();
  const sanitized = sanitizeLabel(rawLabel);
  const label = (sanitized || "CLAUDE").slice(0, 12);
  return { ...DEFAULT_TIER, label };
}
