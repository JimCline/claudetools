/**
 * model-banner — named colour palette.
 *
 * Fixed named palette only, mapped to basic SGR codes. No hex, no 256-colour,
 * no truecolour — the statusLine doc demonstrates only basic SGR codes and
 * says nothing about extended colour support.
 */

export const COLORS = {
  black: 30,
  red: 31,
  green: 32,
  yellow: 33,
  blue: 34,
  magenta: 35,
  cyan: 36,
  white: 37,
  gray: 90,
  brightred: 91,
  brightgreen: 92,
  brightyellow: 93,
  brightblue: 94,
  brightmagenta: 95,
  brightcyan: 96,
  brightwhite: 97,
};

export const RESET = "\x1b[0m";

/** Returns the full SGR escape sequence for a colour name, or "" if unknown. */
export function sgr(name) {
  const code = COLORS[name];
  if (code === undefined) return "";
  return `\x1b[${code}m`;
}
