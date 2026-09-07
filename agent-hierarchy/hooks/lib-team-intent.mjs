#!/usr/bin/env node
// agent-hierarchy — team-intent phrase list for the §1.5 nudge (spec 0042). Read from
// `skills/agent-roster/SKILL.md`'s frontmatter `description` at call time so the phrase
// list has exactly one source of truth; the test imports this module directly to assert
// it matches. No side effects on import — safe to import from a test process.

import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const SKILL_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "skills", "agent-roster", "SKILL.md");

export function teamIntentPhrases() {
  try {
    const body = readFileSync(SKILL_PATH, "utf8");
    const fm = body.match(/^---\n([\s\S]*?)\n---/);
    const descLine = fm && fm[1].match(/^description:\s*(.*)$/m);
    if (!descLine) return [];
    return [...descLine[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  } catch {
    return [];
  }
}

export function matchedTeamIntentPhrase(prompt) {
  const lower = prompt.toLowerCase();
  return teamIntentPhrases().find((phrase) => lower.includes(phrase.toLowerCase())) || null;
}
