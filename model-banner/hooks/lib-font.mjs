/**
 * model-banner — hand-rolled glyph tables.
 *
 * Both fonts cover the same key set — full A–Z, 0–9, space, hyphen, period —
 * so the unknown-model fallback path (see lib-tiers.mjs) can always render
 * whatever label it computes under either size, and switching `size` never
 * changes which labels are renderable.
 *
 * Each glyph is exactly N rows (5 for FONT_LARGE, 3 for FONT_COMPACT); all
 * rows of a given glyph share one width. FONT_LARGE fills with U+2588 FULL
 * BLOCK; FONT_COMPACT draws with only `| _ - \ /` and space, a thinner
 * line-art style. Widths below are load-bearing — trailing spaces inside the
 * string literals are not incidental.
 */

export const FONT_LARGE = {
  "A": [" ██ ", "█  █", "████", "█  █", "█  █"],
  "B": ["███ ", "█  █", "███ ", "█  █", "███ "],
  "C": [" ███", "█   ", "█   ", "█   ", " ███"],
  "D": ["███ ", "█  █", "█  █", "█  █", "███ "],
  "E": ["████", "█   ", "███ ", "█   ", "████"],
  "F": ["████", "█   ", "███ ", "█   ", "█   "],
  "G": [" ███", "█   ", "█ ██", "█  █", " ███"],
  "H": ["█  █", "█  █", "████", "█  █", "█  █"],
  "I": ["███", " █ ", " █ ", " █ ", "███"],
  "J": ["  ██", "   █", "   █", "█  █", " ██ "],
  "K": ["█  █", "█ █ ", "██  ", "█ █ ", "█  █"],
  "L": ["█   ", "█   ", "█   ", "█   ", "████"],
  "M": ["█   █", "██ ██", "█ █ █", "█   █", "█   █"],
  "N": ["█   █", "██  █", "█ █ █", "█  ██", "█   █"],
  "O": [" ██ ", "█  █", "█  █", "█  █", " ██ "],
  "P": ["███ ", "█  █", "███ ", "█   ", "█   "],
  "Q": [" ██  ", "█  █ ", "█  █ ", "█ █  ", " ██ █"],
  "R": ["███ ", "█  █", "███ ", "█ █ ", "█  █"],
  "S": [" ███", "█   ", " ██ ", "   █", "███ "],
  "T": ["█████", "  █  ", "  █  ", "  █  ", "  █  "],
  "U": ["█  █", "█  █", "█  █", "█  █", " ██ "],
  "V": ["█   █", "█   █", "█   █", " █ █ ", "  █  "],
  "W": ["█   █", "█   █", "█ █ █", "██ ██", "█   █"],
  "X": ["█   █", " █ █ ", "  █  ", " █ █ ", "█   █"],
  "Y": ["█   █", " █ █ ", "  █  ", "  █  ", "  █  "],
  "Z": ["█████", "   █ ", "  █  ", " █   ", "█████"],
  "0": [" ██ ", "█  █", "█  █", "█  █", " ██ "],
  "1": [" █  ", "██  ", " █  ", " █  ", "███ "],
  "2": ["███ ", "   █", " ██ ", "█   ", "████"],
  "3": ["███ ", "   █", " ██ ", "   █", "███ "],
  "4": ["█  █", "█  █", "████", "   █", "   █"],
  "5": ["████", "█   ", "███ ", "   █", "███ "],
  "6": [" ██ ", "█   ", "███ ", "█  █", " ██ "],
  "7": ["████", "   █", "  █ ", " █  ", " █  "],
  "8": [" ██ ", "█  █", " ██ ", "█  █", " ██ "],
  "9": [" ██ ", "█  █", " ███", "   █", " ██ "],
  " ": ["  ", "  ", "  ", "  ", "  "],
  "-": ["    ", "    ", "████", "    ", "    "],
  ".": ["  ", "  ", "  ", "  ", "██"],
};

/** Thin line-art font, 3 rows, drawn with only `| _ - \ / ` and space. */
export const FONT_COMPACT = {
  "A": [" _ ", "|_|", "| |"],
  "B": ["|_ ", "|_|", "|_|"],
  "C": [" __", "/  ", "\\__"],
  "D": ["|_ ", "| \\", "|_/"],
  "E": ["|_ ", "|_ ", "|_ "],
  "F": ["|_ ", "|_ ", "|  "],
  "G": [" __", "/ _", "\\_|"],
  "H": ["| |", "|_|", "| |"],
  "I": ["|", "|", "|"],
  "J": ["  |", "  |", "\\_/"],
  "K": ["| /", "|  ", "| \\"],
  "L": ["|  ", "|  ", "|_ "],
  "M": ["|\\/|", "|  |", "|  |"],
  "N": ["|\\|", "| |", "| |"],
  "O": [" _ ", "| |", "|_|"],
  "P": [" _ ", "|_|", "|  "],
  "Q": [" _ ", "| |", "|_\\"],
  "R": [" _ ", "|_|", "| \\"],
  "S": [" __", "\\_ ", " _/"],
  "T": ["___", " | ", " | "],
  "U": ["| |", "| |", "|_|"],
  "V": ["\\ /", " \\/", "  |"],
  "W": ["|  |", "|  |", "|\\/|"],
  "X": ["\\ /", "   ", "/ \\"],
  "Y": ["\\ /", " | ", " | "],
  "Z": ["___", " / ", "___"],
  "0": [" _ ", "| |", "|_|"],
  "1": [" |", " |", " |"],
  "2": [" _ ", " _|", "|_ "],
  "3": [" _ ", " _|", " _|"],
  "4": ["   ", "|_|", "  |"],
  "5": [" _ ", "|_ ", " _|"],
  "6": [" _ ", "|_ ", "|_|"],
  "7": [" _ ", "  |", "  |"],
  "8": [" _ ", "|_|", "|_|"],
  "9": [" _ ", "|_|", " _|"],
  " ": ["  ", "  ", "  "],
  "-": ["   ", " - ", "   "],
  ".": [" ", " ", "_"],
};

const FONTS = { large: FONT_LARGE, compact: FONT_COMPACT };
const ROW_COUNTS = { large: 5, compact: 3 };

/**
 * Renders `word` as banner rows.
 *
 * "small" -> a single decorated row, no glyph lookup.
 * "large" / "compact" -> N rows built from the matching font table (5 for
 * large, 3 for compact). Any other value falls back to "large". A character
 * not in the table is skipped, not substituted — callers should already have
 * sanitized (see lib-tiers.mjs's unknown-model path), so this is
 * belt-and-braces. Each finished row is right-trimmed, since trailing blanks
 * are invisible and only risk terminal wrapping — callers that need the
 * rows rectangular (e.g. a side-by-side layout) re-pad to the group's max
 * width themselves.
 */
export function renderWord(word, size) {
  if (!word) return [];
  if (size === "small") {
    return [`── ${word} ──`];
  }
  const font = FONTS[size] || FONT_LARGE;
  const rowCount = ROW_COUNTS[size] || ROW_COUNTS.large;
  const chars = [...word].filter((ch) => font[ch]);
  if (chars.length === 0) return [];
  const rows = [];
  for (let i = 0; i < rowCount; i++) {
    const row = chars.map((ch) => font[ch][i]).join(" ");
    rows.push(row.replace(/\s+$/, ""));
  }
  return rows;
}
