# task-gopher 0001 — verbatim-read gate

Status: **r10 — record only. E1 r9 measured: 55 hits, 50/55 = 90.9% (gate met), recall 6/13. #18 was not an impl defect (§2 r10 block). Two r9 side-effects ruled bugs and applied: ext lookahead `(?![\w-]|\.\w)`, path-blanking before guard (iii); plus H3 `lines A–B` path-either-side. Expected after fixes: 59 hits, recall 8/13.** (r9: r8 narrow + the four r9 amendments in §2 (mirror drops `verbatim`, path token terminates, minimal target guard i–iii, H2 drops `section`); §6 case 17 pins them. r8 measured 62.9%, projected r9 ≈ 96%.) (r8: NARROW predicate (user ruling). §2 is normative;
§2.0–§2.3 are the superseded wide record. E1 = precision ≥ 90% on the whole
hit set + recall over 13 TPs reported.** History: (r3: H1 shape + mention guard; r4: object guards a–e
after E1 measured 70%; r5: guard (b) widening, H2 guard confirmed; r6: H3
pipe guard, (d) plurals + backtick idents, single-line guard, H1a comma
binding — after E1 round 2 measured 39% under a stricter labeller). Follow-on to 0.16.0 (spec 0045 cuts 1+4); ships as **0.17.0**,
after 0.16.0, not folded. r2 = user ruled **hard deny** on §7's question; the
one-shot key/re-issue path is removed throughout (§3, §6, §7, §10). E1 ≥ 80%
precision remains the ship condition — with no escape hatch, false positives
cost more, so it matters more.
Brief: `20260909-105857-hvva`. Path was not dictated in the brief; this location
was proposed to the Orchestrator and not contested.

Goal: an agent must not order task-gopher (or smart-gopher) to read a file and
hand it back whole. That costs more than a direct Read — Haiku input + Haiku
output + the dispatcher's input of the same bytes, plus the dispatch — and the
prose rule against it (`directive.mjs:245`, `SHORT_REMINDER`,
`agents/task-gopher.md:96`, `agents/smart-gopher.md:91`) is ignored in
practice: the Architect writing this spec issued three such orders today.

Three things a reader should not have to hunt for:

- **"verbatim" is NOT the trigger.** 456 of 656 real gopher orders in this
  project's transcripts (70%) contain the word — "report every FAIL line
  verbatim", "the exact command line verbatim", "grep output verbatim". It
  means *don't paraphrase*, and most of those orders are narrow. The brief's
  phrase list ("read X verbatim", "copy the file", "hand back the contents")
  would have checkpointed the majority of legitimate dispatches. The
  discriminator is the **object**: a whole file, or a line range ≥ 80 lines.
- **Hard deny, no escape (user ruling, r2).** A hit is denied every time,
  with the cost argument and the `Read(<path>)` remedy. No session/prompt
  key, no "re-issue to proceed". The dispatcher's only way forward is to
  narrow the order or Read directly — which is the point. Consequence: a false
  positive is a dead end, so the predicate's precision (E1) is the ship gate.
- **Runner side stays prose, plus a STOP rule.** The only mechanical runner-side
  option (report-size vs bytes-read at SubagentStop) is designed in §4 and
  ruled YAGNI until phase-1 leakage is observed.

## 1. Where it lives

`task-gopher/hooks/pretooluse-nudge.mjs`, inside the dispatch branch
`if (target) { … allow(); }` (`:495-523`, 0.16.0 line numbers), **before** the
smart-gopher checkpoint. Applies to both runners (`target` is `task-gopher` or
`smart-gopher`). Sits after `if (!isEnabled()) allow()` (`:484`) — plugin OFF
means no gate, consistent with every other gate in the file.

Predicate and deny text live in `hooks/directive.mjs` beside `SENTINEL` /
`SHORT_REMINDER` so the same predicate is testable in isolation and the text is
in one place. Names are the Implementor's.

Touch points vs 0.16.0 (already in tree: `RELAY_EXEMPT` `:126`,
`AH_ROLE_AGENTS` `directive.mjs:203`, `isHierarchyRoleAgent` `:213`,
userpromptsubmit/sessionstart gates): no overlapping lines. Land after 0.16.0
is committed; do not branch from before it.

## 2. Detection rule — r8 NARROW (user ruling; supersedes §2.0–§2.3)

Input: `tool_input.prompt` (string; non-string → no gate, fail open like
`:535`). Case-insensitive. Principle: deny only when the order names **an
explicit file AND asks for it whole** in the same breath. No object guards,
no line-filter windows — those existed to rescue a wide adjective+noun match
and are moot when a path token is required.

Definitions used below:

- **path token**: a whitespace-free run that contains `/` **or** ends in a
  file extension `\.\w{1,5}\b`, optionally wrapped in backticks or quotes,
  and does **not** end in `/` (`tests/` is a directory, not a file). `docs/`,
  `hooks/`, `v0.16.0`-style version strings are not path tokens (a version has
  no `/` and its "extension" is digits — require the extension's first char
  to be a letter).
- **glue**: the only material permitted between the qualifier and the path
  token for them to count as adjacent — whitespace (including **one**
  newline followed by an optional list marker `-`, `*`, or `N.`), the
  punctuation `: , ( — –`, the connectives `of for from in at and`, the
  determiners `the this these those each both`, and the words `file files`.
  Total glue ≤ **40** chars. Any other word breaks adjacency — that is how
  "no `of <non-path target>` between" is enforced: "full text of the section
  beginning ## Scope in docs/a.md" has `section beginning ## Scope` between →
  not adjacent → no hit.
- **span** (H3): `head -N`/`tail -N` → N; `sed -n 'A,Bp'` and "lines A–B" →
  B−A+1; `Read(…, offset A, limit L)` → L. **= 80 denies.** Threshold is one
  named constant.

A hit is any of:

- **H1 — whole-file qualifier adjacent to a path token.** Qualifier forms
  (unchanged from r7): H1a `\b(full|entire|whole|complete)\b,?(?:\s+\w+){0,2}\s+(file|files|contents?|text|source)\b`;
  H1c `\b(full|entire|whole|complete)\b[^.\n]{0,20}\bcontents?\s+of\b`;
  and the mirrored H1b `<path token> <glue> (in full|verbatim|entirely|whole)\b`.
  Adjacency is **symmetric** (Architect's decision, flagged in §7):
  qualifier → glue → path, or path → glue → qualifier. "Return the full
  contents of hooks/x.mjs" and "hooks/x.mjs — full contents" are the same
  order. Rationale: H1b was already path-first; a one-direction rule would
  make word order a loophole.
  "Read hooks/x.mjs and return the full file contents" does **not** hit —
  `and return the` contains `return` — and is the documented known-FN shape
  (§6 case 14).
- **H2 — read-whole, as is.** `\bread\s+(the\s+)?(whole|entire|full)\s+(file|thing|section)\b`
  and `\bin (its )?entirety\b`. No path required (kept per ruling; measured 0
  hits in E1, so it costs nothing and catches the one phrasing that names no
  file).
- **H3 — range tool directly on a path token.** `sed -n 'A,Bp'`, `head -N`,
  `tail -N` (both `-n N` and `-N` spellings) where the path token is the next
  argument (only flags/quotes/whitespace between), **no `|` in the 40 chars
  before the tool token on the same line, no `|` or `>` in the 20 chars
  after the path token on the same line**, and span ≥ 80. Also
  `Read(<path token> … offset A … limit L)` with L ≥ 80, and "lines A–B" with
  a path token adjacent by glue on either side (`quote lines 95-190 of
  tests/t.sh`), span ≥ 80. Bare "head -150" or "lines 95-190" with no path →
  no hit (narrow by construction). Redirect counts as a pipe: output sent to a
  file never enters the runner's context.

**Guard (kept — cheap, and both live FPs named paths):** no hit when the
**60** chars before the qualifier/tool token contain a negation
`\b(not|never|no|don'?t|do not|without|unless|instead of|rather than|avoid)\b`
or a meta word
`\b(deny|denies|denied|denial|refuse[sd]?|reject[sd]?|block[sed]?|gate[sd]?|flag[sged]*|detect[sed]?|forbid[s]?|pattern|regex|test case|assert|counts? as|true positive|false positive|TP|FP|label[sled]*|classif\w*|definition|defined?|means|i\.e\.|e\.g\.)\b`,
or the **qualifier span itself** sits inside backticks or double quotes. The
quote rule tests the qualifier, never the path token — paths are routinely
backticked in legitimate orders ("full contents of `hooks/x.mjs`" hits).

Accepted misses (known-FN-direction, documented in §6 case 14, counted in
E1's recall number): whole-file order where the path is named earlier in
the prose ("Read hooks/x.mjs. … Then return the full file"); qualifier and
path separated by any non-glue word ("full contents, cleaned up, of
hooks/x.mjs"); "these files" followed by a list more than one newline away.
Backstops unchanged: runner STOP clause (§4) and the `verbatim-deny` log.

**r9 amendments (E1 r8: 89 hits, 56/89 = 62.9%; 33 FPs analysed from
`/tmp/e1-r8-labelled.md`). These override the H1/H2/path-token text above
where they conflict.**

1. **Mirror (path-first) form — `verbatim` is NOT a qualifier** (defect 1:
   21 of 33 FPs, all bare "… verbatim" after a path — grep output, script
   stdout, bounded excerpts; contradicted the not-triggers list and §6 case
   5). Path-first accepts only a *terminal* whole-file qualifier:
   `\bin full\b`, `\bin (its )?entirety\b`, `\bentirely\b`, or
   `\b(full|entire|whole|complete)\s+(file|files|contents?)\b` **not followed
   by `\s+of\b`**. `full source`, `full text`, `complete text` are
   qualifier-first only. This also fixes #9 #10 #11 #12 #39 ("From
   hooks/lib-hier.mjs: the full source of the `roster(…)` function" hit
   path-first through glue `: the`; with the `of`-exclusion it cannot).
   Measured by the Orchestrator: dropping `verbatim` alone → 68 hits,
   56/68, zero TPs lost (the ranged ones re-land on H3).
2. **Path token must terminate the run.** Extension form is
   `[\w-]+\.[A-Za-z]\w{0,4}(?![\w./-])` — `process.env.CLAUDE_PID` no
   longer yields `process.env` (#15). Slash form unchanged.
3. **Minimal target guard inside the narrow frame** — sized to the measured
   residue, four checks, each one line:
   - (i) **search verb before**: 40 chars before the qualifier contain
     `\b(search|grep|scan|find)\b` → allow (#15 "Search the whole file for
     X", #80 "Fetch and grep the full text of <path>"). A search is a filter
     by definition.
   - (ii) **listing after noun**: file-noun followed within 3 chars by
     `\b(list|listing|names?|paths?|count|size|tree)\b` → allow (#69
     "full file listing"). r4's (a), reinstated as-is.
   - (iii) **read-but-distil after**: 60 chars after the qualifier span
     contain `\b(compact\w*|summar\w*|answer\w*)\b` → allow (#30 "in full
     and report back a COMPACT numbered list", #71 "in full. Report back
     compactly"). **`report` alone is NOT a signal** — #49 "in full … and
     report back VERBATIM … the entire file" must stay a deny.
   - (iv) qualifier-first `of <non-path>` already breaks adjacency (glue
     rule); no change — restated because the r8 premise was right for
     qualifier-first and wrong only for the mirror.
4. **H2 drops `section`**: `\bread\s+(the\s+)?(whole|entire|full)\s+(file|thing)\b`
   (#8 "read the whole section" — a section is the sanctioned narrow ask).

Expected on the r8 hit set: 32 of 33 FPs removed (21 verbatim; #8; #9–12,
#39; #15; #30; #71; #69; #80). #18 ("…0011….md. Find and quote VERBATIM, in
full: section §5.3.2") should not have hit under §2 as written — `Find and
quote VERBATIM,` is not glue — **Implementor: report which form and which
path token matched #18; if the glue crossed non-glue words that is an impl
defect, not a spec gap.** One TP lost: #37 "complete text of section §7.5"
(now allow — correct per §2's own rule that a section is narrow; the label
was generous). Projected **55/56–57 ≈ 96%**; ship gate remains ≥ 90% on the
whole re-run hit set, and recall over the 13 TPs is re-reported (E1 #2).

**r10 amendments (E1 r9 measured: 55 hits, 50/55 = 90.9%, recall 6/13).
Override the r9 text above where they conflict.**

1. **#18 resolved — not an impl defect.** The prompt contains three `in
   full`; the third, in "TASK B: Read skills/agent-roster/SKILL.md in full",
   is a path-first mirror hit with one-space glue — a correct deny. The r8
   label sheet showed first-textual-occurrence context, so the labeller saw
   the wrong span (Implementor's sheet bug; corrected r8 = 64.0%). Rule for
   every future E1 sheet: context is taken around the **matched span**, not
   the first occurrence of the qualifier text.
2. **Path-token extension lookahead** was `(?![\w./-])` and rejected a
   filename ending a sentence (`plugin.json.`). Now `(?![\w-]|\.\w)` — a
   trailing bare `.` (or `,` `)` etc.) terminates the run; only `.word`
   continues it (still blocks `process.env.CLAUDE_PID`). Slash form
   unchanged.
3. **Guard (iii) scans prose, not paths.** `summar\w*` matched inside
   `/tmp/rh-summary.log` and allowed a real whole-file ask. Before the
   (iii) scan, blank every path-shaped run (same path-token regex) in the
   60-char after-window; same blanking applies to guard (i)'s before-window
   (a `grep/` dir name is the same failure shape). Words inside path tokens
   are never signals.
4. **H3 `lines A–B` path either side** (Implementor's `pathEitherSide`,
   adopted): the path token may sit before or after the range with glue
   between, mirroring H1's symmetric adjacency (§7). Forward-only adjacency
   flipped #98 ("tests/t.sh lines 1–200") to allow; either-side denies it.
   Span rule and =80 boundary unchanged.

Expected after 1–4: 59 hits, recall 8/13 (two TPs regained on #2 and #3).
Precision must be re-reported on the 59; gate stays ≥ 90%.

Illustrative only, not prescriptive — one way the H1 adjacency reads as a
single expression (Implementor's shape is their own):

```
QUAL  = (?:\b(full|entire|whole|complete)\b,?(?:\s+\w+){0,2}\s+(file|files|contents?|text|source)\b)
GLUE  = (?:[\s:,(—–]|\n\s*(?:[-*]|\d+\.)?\s*|\b(?:of|for|from|in|at|and|the|this|these|those|each|both|file|files)\b){0,40}   # bounded by chars, not repeats
PATH  = [`"']?(?:[\w.~-]*\/[\w./~-]*[\w~-]|[\w-]+\.[A-Za-z]\w{0,4})\b[`"']?
H1    = QUAL GLUE PATH  |  PATH GLUE (?:in full|verbatim|entirely|whole)\b
```

### 2.0 Superseded — wide predicate, r3–r7 (record only; do not implement)

Kept so the wide-vs-narrow tradeoff is not re-litigated. §2.1–§2.3 below
are the final state of the wide design and the estimate that led to the
narrow ruling. Nothing in §2.0–§2.3 is normative for 0.17.0.

Input: `tool_input.prompt` (string; non-string → no gate, fail open like
`:535`). Case-insensitive. A hit is any of:

- **H1 — whole-file object.** (r3: pattern shape widened — r2's `\s+` between
  adjective and noun missed §2's own example "FULL, VERBATIM content of these
  files".) Three forms:
  - H1a: `\b(full|entire|whole|complete)\b,?(?:\s+\w+){0,2}\s+(file|files|contents?|text|source)\b`
    — up to two intervening words; a comma is allowed only directly after the
    adjective ("FULL, VERBATIM content" yes; "Run the full suite, one file at
    a time" no — r6: r4's `[\s,]+` let the slack cross a comma into an
    unrelated noun, #114).
  - H1b: `\bcontents?\s+of\b[^.\n]{0,40}\b(in full|verbatim|entirely|whole)\b`
    (unchanged).
  - H1c: `\b(full|entire|whole|complete)\b[^.\n]{0,20}\bcontents?\s+of\b`
    — adjective before "content(s) of" with anything short between
    ("FULL, VERBATIM content of", "complete exact contents of").
  **Unless negated or mentioned** (r3, widened after a live false positive:
  an order *describing* the gate — "the gate should DENY a dispatch that
  orders the runner to read a WHOLE FILE" — was denied): the **60** characters
  before the match contain a negation
  `\b(not|never|no|don'?t|do not|without|unless|instead of|rather than|avoid)\b`
  **or a meta-context word**
  `\b(deny|denies|denied|denial|refuse[sd]?|reject[sd]?|block[sed]?|gate[sd]?|flag[sged]*|detect[sed]?|forbid[s]?|pattern|regex|test case|assert|counts? as|true positive|false positive|TP|FP|label[sled]*|classif\w*|definition|defined?|means|i\.e\.|e\.g\.)\b`
  (the definitional words added after a second live FP — a labelling order
  that only *defined* what counts as a hit was denied on `complete file`),
  **or the match sits inside backticks or double quotes** (`` `…` `` or
  `"…"`) — a quoted phrase is a mention, not an order.
  **r4 object guards** (E1 labelled 21/30 = 70% on r2 hits; the FP shapes
  below account for 8 of the 9). Applied to H1a/H1c after the match:
  - (a) **Listing, not contents**: no hit when the file-noun is followed
    within 3 chars by `\b(list|listing|names?|paths?|count|size|tree)\b`
    ("full file listing" = `ls`).
  - (b) **Matching-line retrieval**: no hit when the 60-char window before
    the match contains `\b(every|each|all|any)\s+(\w+\s+)?(line|match|occurrence)s?\b|\bgrep\b|\blines?\s+(that|which|containing|matching|with)\b|\bmatching\b`
    (r5: one optional intervening word — "every FAIL line", "each matching
    occurrence" are the natural forms),
    or the **20** chars after the noun contain `\blines?\b` (r5: was 15;
    "text of every FAIL line" is 19), or (r6, single named line — "full text
    of the RESYNC_FLAGS line", "full line text" per match) `\bline\b` appears
    within 12 chars on either side of the adjective–noun match ("full text of every
    FAIL line", "every line in the whole file that contains X", "grep -n
    across the whole file"). A line-filtered read is the sanctioned narrow ask.
  - (d) **Section target** (Architect's addition — the "debatable TPs" #16/#56
    are FP by design: `SHORT_REMINDER` names "the one function or section you
    care about" as the right ask): no hit when the 25 chars after the noun
    contain `\bof\s+(the\s+)?(sections?|§|headings?|functions?|blocks?|paragraphs?|items?|bullets?|entr(y|ies)|cases?|clauses?)\b`
    (r6: plurals), or — **ruling r6: yes, (d) covers backtick-named
    identifiers** — `\bof\s+(the\s+)?`([^`]+)`` where the backtick content is
    NOT a path: contains no `/` and does not end in `\.\w{1,5}`. "full source
    of `roleForPeerName`" → target, no hit; "full contents of `hooks/x.mjs`"
    → path, hit stands. A bare symbol in backticks is a function/const, and a
    function is the sanctioned narrow ask. "(the bullet runs from…)" (#58) is
    covered by `bullets?` plus the 25-char window.
    Or the match itself is `(full|entire|whole|complete)\s+(section|function|block)` (never in the noun list anyway).
  - (c) **Conditional-full — design ruling, not a regex knob: ALLOW only when
    the condition names a numeric line bound ≤ the H3 threshold (80).**
    Pattern: the 80 chars after the noun contain
    `\b(if|when|unless|only if)\b[^.\n]{0,30}\b(under|below|<|≤|fewer than|less than|at most|up to|no more than)\s*(\d+)\s*lines?\b`
    with N ≤ 80 → no hit. "full file if under 40 lines, else the section"
    passes; "full file if it is small/short/reasonable" — no number — still
    denies: an unbounded conditional is the rationalisation the gate exists
    to stop, and the fix is to write the number. A bound over 80 ("if under
    500 lines") denies — that is a whole file by the gate's own definition.
    Rationale: the dispatcher has bounded the cost explicitly at ≤ ~4 KB, the
    same trade H3 already accepts for small ranges.
  - (e) Write-parameter shape (#121, "full content = frontmatter + body" as
    an argument to a write): covered by the mention guard's double-quote rule
    when quoted; when not, it stays a known FP — one in the sample, and the
    order is asking the runner to *write*, which the guard cannot see. Not
    worth a pattern.
  Expected on the labelled sample: (a)+(b) remove 8 FPs, (d) reclassifies
  #16/#56, (c) reclassifies #26/#96/#146 only if they carry a number —
  ≥ 29/30 either way. Ship gate ≥ 80% stands; re-run E1 on the r4 predicate
  over the same 146 (or the new hit set) and report count + a fresh 30-label.
  Tradeoff, stated once: this is a mention-vs-use heuristic, not a parser. It
  lets through a whole-file order that happens to say "gate"/"test" within 60
  chars before the noun ("for the test, return the full file"); that is rare
  in the corpus and the runner-side STOP rule is the backstop. The
  alternative — accepting the mention case as a known false positive — is
  wrong under hard deny: with no escape, the only workaround is to reword a
  description whose whole point is to name the phrase (spec-writing and
  test-writing orders must), and every rewording trips another form (H2's
  "in its entirety"). An imperative-mood parser would be over-engineering for
  the same gain.
  Real examples that must hit: "Full content of hooks/sessionend-roster.mjs",
  "Return the FULL, VERBATIM content of these files", "report the full file
  verbatim (it is small)". Must not hit: "don't dump the whole file unless it's
  under 40 lines", "Do NOT print full log contents".
- **H2 — read-whole.** `\bread\s+(the\s+)?(whole|entire|full)\s+(file|thing|section)\b`
  and `\bin (its )?entirety\b`, same guard as H1 — under r3 that is the full
  negation + mention guard (confirmed r5; the Implementor's application to H2
  is correct). The r4 object guards (a)–(d) are H1-only: H2 has no separable
  file-noun to test. Example hit: "Read the
  whole file, report it verbatim in full".
- **H3 — large range.** Any single range mention whose span is **≥ 80 lines**:
  `lines?\s+(\d+)\s*(?:-|–|—|to|through)\s*(\d+)`, `sed\s+-n\s+'?(\d+),(\d+)p`,
  `head\s+(?:-n\s*|-)(\d+)`, `tail\s+(?:-n\s*|-)(\d+)`,
  `Read\([^)]*offset\D*(\d+)[^)]*limit\D*(\d+)` (span = limit). Span for A–B is
  B−A+1. **r6 — H3 is guarded** (6/33 round-2 FPs were pipelines): a
  `head`/`tail`/`sed -n` match counts only when it applies directly to a
  file, i.e. **no `|` in the 40 chars before it on the same line** (not
  `grep … | head -100`, `ls | tail -200`) **and no `|` in the 20 chars after
  it** (not `head -200 x | wc -l`, `… | grep`). `lines A–B` and `Read(offset,
  limit)` forms are unaffected — they name a file range by construction. Examples: `sed -n '1,400p'` hit; `head -150` hit; "lines 95-190" hit;
  `sed -n '1,60p'` allow; "lines 130-150" allow. Threshold 80 ≈ 4 KB ≈ one
  Read chunk; below it, batching several small ranges into one dispatch is a
  defensible trade against N tool round trips. One knob, named as a constant.

### 2.1 Windows and anchors — r7 (SUPERSEDED by r8 §2; record only)

Supersedes every window number stated inline in H1–H3 and the guards above.
Guards are OR-ed and order-independent; the one conflict (guard (b)'s
`lines?` vs guard (c)'s `N lines` bound) is resolved by a lookbehind, not by
ordering. "match" = the H1a/H1c adjective…noun span. Each window is derived
from the longest §6 example it must reach, named in the last column.

| guard | pattern | where it looks | window | derived from (§6) |
|---|---|---|---|---|
| negation | `\b(not\|never\|no\|don'?t\|do not\|without\|unless\|instead of\|rather than\|avoid)\b` | before match | **60** | case 3 (18 needed); shares the mention window |
| mention words | the meta/definitional list in H1 | before match | **60** | case 12 "counts as a true positive when the order asks for the complete file" — `counts as` ends 54 before |
| mention quotes | match lies inside `` `…` `` or `"…"` | enclosing | unbounded | case 12 backtick/quote examples |
| (a) listing | `\s{0,3}\b(list\|listing\|names?\|paths?\|count\|size\|tree)\b` | **anchored** at noun end | — | case 13 "full file listing" |
| (b) LF_QUANT | `\b(every\|each\|all\|any)\s+(\w+\s+)?(line\|match\|occurrence)s?\b\|\blines?\s+(that\|which\|containing\|matching\|with)\b\|\bmatching\b\|\bgrep\b` | before match **and** after noun | before **60**, after **40** | before: case 13 "every line in the whole file" (20), case 15 "for every FAIL line, give the full text" (31); after: case 13 "full text of every FAIL line" (19), case 15 "full text of each of the lines that contain X" (37) |
| (b) LF_LINE | `(?<!\d\s)\blines?\b` — digit-preceded is a bound, not a filter (Implementor's remedy, adopted) | **inside the match span** + before + after | before **12**, after **25** | span: case 13 "full line text"; after: case 14 "full text of the RESYNC_FLAGS line" (24); before: case 15 "the RESYNC_FLAGS line's full text" (7) |
| (c) conditional | `\b(if\|when\|unless\|only if)\b[^.\n]{0,30}\b(under\|below\|<\|≤\|fewer than\|less than\|at most\|up to\|no more than)\s*(\d+)\s*lines?\b`, N ≤ 80 → allow | after noun | **80** | case 13 "full file if under 40 lines, else only the matching function" (bound at 17) |
| (d) section words | `\s+of\s+(the\s+)?(sections?\|§\|headings?\|functions?\|blocks?\|paragraphs?\|items?\|bullets?\|entr(y\|ies)\|cases?\|clauses?)\b` | **anchored** at noun end | — | case 13/14 "full text of the section(s)…", #58 "the bullet" |
| (d) backtick ident | `\s+of\s+(the\s+)?`([^`]{1,60})`` and content has no `/` and no `\.\w{1,5}$` | **anchored** at noun end | — | case 14 "full source of `roleForPeerName`"; a 31-char ident like `refuseRosterEditWhileOwningTeam` would have overflowed r6's 25-char window — hence anchored, not windowed |
| H1a slack | `\b(adj)\b,?(?:\s+\w+){0,2}\s+(noun)` | the match itself | ≤2 words | case 11 "FULL, VERBATIM content"; case 14 "full suite, one file" must not bind |
| H3 pipe | `\|` present | before / after the head/tail/sed token, same line | before **40**, after **20** | case 14 "grep -n TODO src/ \| head -100", "tail -n 200 /tmp/x.log \| wc -l" |
| H3 range | span ≥ **80** lines | the range token | — | cases 5–6 |

Why anchored beats windowed for (a)/(d): the thing being tested sits
immediately after the noun, so a window only adds a way to be wrong (r6's
25 could not hold a long identifier). Why LF_LINE scans the match span: the
H1a slack admits "full **line** text", where the discriminating word is
*inside* the match — no before/after window can see it.

The two r6 failures, resolved: "full file if under 500 lines" — LF_LINE's
lookbehind excludes `500 lines`, (c) sees N=500 > 80 → **deny** ✓;
"full text of the RESYNC_FLAGS line" — after-window 25 reaches offset 24 →
**allow** ✓.

### 2.2 r7 addendum — round-2 residual FP shapes (SUPERSEDED; record only)

Amends the §2.1 table; where the two disagree, this section wins.

| # | shape | fix | table row changed |
|---|---|---|---|
| #22 | "Search the **whole file** for X — report every match" | already covered by LF_QUANT **after** (40); additionally add `\b(search|scan|look through)\b` to LF_QUANT's before-list beside `grep` — a search verb is a filter by definition | (b) LF_QUANT |
| #26 #54 | "text of **these** sections", "full source of **these** functions" | determiner group in (d) becomes optional `(the|this|these|those|each|every|all|both|any|its|their|my|our)\s+`; same group reused by (d) backtick-ident | (d) |
| #50 | "full contents of the tests/ **directory** (just filenames)" | (d) target list += `director(y|ies)|folders?|dirs?`, allowing one path token between determiner and target: `of\s+(det\s+)?(\S+\s+)?(…|director(y|ies)|…)\b` | (d) |
| #58 | "(the bullet runs from…)" | (d) anchored at noun catches `of the bullet`; if the hit is elsewhere in that order I cannot see it — **Implementor: paste #58 verbatim into the E1 sheet**; not fixed blind | — |
| #70 | "line number and full **line** text" | r6 missed it because its ±12 window measured from match *start* ("line number and " = 16 before) and never looked *inside* the match; r7 LF_LINE scans the match span → "full line text" allows | (b) LF_LINE (already in §2.1) |
| #126 | `tail -n 300 … > file; wc -l` | H3 after-guard: `\||>` (pipe **or** redirect) within 20 after the token, same line. Output redirected to a file never lands in the runner's context, so it is not a verbatim read; `wc` afterwards is irrelevant | H3 pipe → "H3 pipe/redirect" |
| #106 | write-param | known, accepted (e) | — |

**H3 boundary ruling.** Span **= 80 denies**. Definitions: `head -N` / `tail -N` → N; `sed -n 'A,Bp'` and "lines A–B" → B−A+1; `Read(offset=A, limit=L)` → L. The pipe/redirect guard is orthogonal to the threshold: `head -80 path` → deny, `head -79 path` → allow, `head -80 path | grep x` → allow, `sed -n '1,80p' path` → deny, `sed -n '1,80p' path > /tmp/o` → allow. §6 case 16 pins all five so the =80 result never again rides on an incidental `|`.

Expected r7 effect on the round-2 sample: 6 of the 9 residual FPs addressed (#22 #26 #54 #50 #70 #126), #58 unknown, #106 accepted → **13/16 ≈ 81%** if nothing regresses. n=22 gives ±17 pp at 95% — this number cannot carry a ship decision. **E1 amendment:** label the *entire* post-r7 hit set (expect 60–90 hits of 661), not a 22-row sample, before applying the ≥80% gate.

### 2.3 Honest precision estimate — wide regex vs narrow gate (user chose NARROW, r8)

- **Wide (this spec, r7):** plateau **~75–85%** on this corpus. Every round so far halved the residual FPs and found new shapes; the tail is natural-language and long. Recall ≈100% of labelled TPs by construction (TPs defined by the predicate's hits). Under **hard deny** every remaining FP is a dead-end dispatch — at 80% that is ~1 in 5 gated dispatches, ~3% of all dispatches.
- **Narrow:** deny only when (1) H1 adjective+noun is immediately followed (≤40, same sentence) by an explicit path token (`/` or `\.\w{1,5}\b`) and there is no `of <non-path target>` between; or (2) H2 "read the whole file"; or (3) H3 applied directly to a path token with no pipe/redirect. Estimate **≥90% precision**; recall vs the current 13 TPs **~40–70%** — orders like "return the full file" with the path named two lines earlier slip. **NEEDS-EVIDENCE:** Implementor runs the narrow predicate over the 13 labelled TPs and reports recall; that number, not my estimate, decides.
- **Recommendation:** under the hard-deny ruling, narrow. A dead-end FP costs a whole dispatch and the user's trust in the gate; a missed TP costs what we pay today, and the runner STOP clause + `verbatim-deny` log remain the backstop. If the user would rather keep wide, the honest pairing is wide + one-shot — which the user already declined; so the real choice is narrow-hard-deny vs wide-hard-deny-at-~80%.

Not triggers, deliberately: `verbatim` alone; `cat <path>` alone (60 hits,
many are `cat /tmp/<summary the runner just wrote>` — legitimate); "quote
the function X"; "copy". Precision over recall (brief §3); the runner-side
rule and the log catch leakage.

Measured (E1, r2 patterns, 657 prompts): 146 hits = 22.2% (H1 120, H2 0,
H3 26); hits at `/tmp/e1-verbatim-hits.txt`. r3's H1 widening should add
only the "adjective, adjective noun" and "adjective … content of" forms —
expect +5–10 hits (≈ +1 pt), all of the §2-example shape; the mention guard
should remove a handful (orders about this gate, spec-0045-era orders
quoting "whole file" in backticks) — net ≈ unchanged, ~22%. Precision labelling
of a 30-hit sample (E1) is still the ship gate; H2 = 0 means the "read the
whole file" form is not how orders are phrased here — leave it, it is free.

## 3. Behaviour on hit

- No state is read or written. On a hit: `logEvent` with
  `event: "verbatim-deny"`, `agent: target`, `detail`: the matched text
  (≤120 chars) and which of H1/H2/H3; then `deny(<text below>)`. Every time,
  every session, same prompt or not.
- Sequencing: the verbatim check runs before the smart-gate block, so a
  smart-gopher prompt that hits never reaches the smart-gate checkpoint — it
  cannot proceed at all until rewritten, at which point the rewritten prompt
  gets its own smart-gate checkpoint as today.

Deny text (one paragraph; the cost argument stated once so the dispatcher
learns rather than rewording):

> task-gopher: this order asks the runner to hand a file back whole
> (matched: `<matched text>`). That costs MORE than reading it yourself: Haiku
> reads it (input), re-emits it (output), and you read it again (input) —
> three times the bytes plus a dispatch. Read(<path>[, offset, limit]) directly.
> Dispatch gopher only when the answer is SMALLER than the source: grep →
> file:line + a few lines of context, the one function, a summary, a count,
> the first N matches. Rewrite the order that way, or read the file yourself;
> this dispatch will not be allowed as written.

`<path>` is the first path-like token in the prompt if one exists, else
omitted. Reason text must contain the literals `Read(` and
`will not be allowed as written` (tests grep them). It must NOT contain
`re-issue` — that phrase means "retry passes" elsewhere in this plugin and
would teach the wrong lesson here.

## 4. Runner side

- **Prose amendment** (`agents/task-gopher.md:96`, `agents/smart-gopher.md:91`):
  the existing "Do NOT return whole files verbatim" bullet gains a STOP clause
  in the same register as `:70`'s gap rule: an order whose only satisfying
  output is a file (or ≥ 80 lines of one) reproduced whole → do not read it;
  report one line, `verbatim hand-back refused — dispatcher should Read
  <path> directly`, and stop. Keep every existing clause of the bullet.
- **Mechanical runner-side check — designed, ruled YAGNI for 0.17.0.** Shape:
  a `SubagentStop` hook for `agent_type` ∈ gopher kinds; from
  `transcript_path` sum the bytes of `Read`/`Bash` tool results consumed; from
  `last_assistant_message` take the report bytes; if consumed ≥ 4 KB and report
  ≥ 0.8 × consumed → block once with "report is not smaller than what you read
  — distill". Why not now: (i) it costs a Haiku turn per firing, (ii) the
  transcript-at-Stop race (memory: last message may not be flushed — though
  tool results earlier in the file are safe), (iii) no evidence yet that
  phase 1 leaks enough to justify a second hook. Trigger to build it: the
  `task-gopher.log` shows dispatches with no `verbatim-checkpoint` whose
  reports the user still catches as copies — i.e. observed false negatives.
  Requires evidence E2 before building.
- Size-based check on the **dispatcher** side is impossible: at PreToolUse the
  file size is knowable but the report is not; a "prompt names a path whose
  file is > N KB" rule would also fire on every "grep this big file" order.
  Rejected.

## 5. Directive text

`FULL_DIRECTIVE` line `:245` and `SHORT_REMINDER` `:247` already carry the
compress rule (added in 0.16.0). Append one sentence to each, verbatim:
"A PreToolUse gate denies any gopher order that asks for a whole file or a
≥ 80-line range back — no retry passes; narrow the order or Read it yourself."
Nothing else in either string changes.

## 6. Tests — `tests/test-relay-gate.sh` (extend; no new file)

Helpers `run_hook`/`check`/`payload` (`:20-32`) and `is_allow`/`is_inject`
exist; add `is_deny` if absent (`grep -q '"permissionDecision":"deny"'`). Each
case is a block/allow pair where meaningful; plugin ON unless stated.

1. target `task-gopher:task-gopher`, prompt "Return the full contents of hooks/x.mjs" (r8: was "Read hooks/x.mjs and return the full file contents", which is now the case-14 known miss) → deny; reason contains `Read(` and `will not be allowed as written` and not `re-issue`; log has one `verbatim-deny`.
2. **identical prompt again, same `session_id` → still deny**; log has two `verbatim-deny` events. (r2: replaces the one-shot "re-issue passes" case.)
3. "Do NOT return the whole file; grep -n TODO hooks/x.mjs and report file:line" → allow (negation).
4. "report every FAIL line verbatim from /tmp/suite.log" → allow (`verbatim` alone never trips).
5. "sed -n '10,40p' hooks/x.mjs, verbatim" → allow; "sed -n '1,400p' hooks/x.mjs" → deny.
6. "quote lines 95-190 of tests/t.sh" → deny; "quote lines 130-150 of tests/t.sh" → allow (span); "head -150 hooks/x.mjs" → deny; (r8) "head -150" alone → allow (no path token).
7. target `task-gopher:smart-gopher`, whole-file prompt → deny with `verbatim-deny`, and **no** `smart-gate-checkpoint` event and no smart-gate state line written (verbatim runs first and short-circuits).
8. target `general-purpose`, whole-file prompt → **not** denied (relay path unchanged; `is_inject` as today).
9. plugin OFF, whole-file prompt to gopher → allow.
10. `directive.mjs` unit: `node -e` over the exported predicate with the H1/H2/H3 example strings above, each asserting hit / no-hit — the fastest way to keep the regexes honest when someone tunes them.
**r8: cases 11–16 below replace the r3–r7 cases of the same numbers in full.
The old cases exercised guards that no longer exist.**

11. (r8 H1 adjacency) "Return the full contents of hooks/x.mjs" → deny; "Full content of hooks/sessionend-roster.mjs" → deny; "full contents of `hooks/x.mjs`" → deny (backticked path, qualifier unquoted); "the complete, exact contents of hooks/x.mjs" → deny (H1c); "Return the FULL, VERBATIM content of these files:\n- hooks/a.mjs\n- hooks/b.mjs" → deny (glue: colon + one newline + list marker); "hooks/x.mjs in full" → deny (H1b mirror); "tests/t.sh — full contents" → deny (mirror, dash glue); "full contents of the tests/ directory (just filenames)" → allow (trailing slash ≠ path token); "full text of the section beginning ## Scope in docs/a.md" → allow (non-glue words between); "full source of `roleForPeerName` in hooks/x.mjs" → allow (ident is not glue); "full text of every FAIL line in /tmp/suite.log" → allow; "return the full file if under 500 lines" → allow (no path — narrow); "give the full file listing of docs/" → allow; "Run the full suite, one file at a time on tests/t.sh" → allow (comma binding, and `suite` is not glue); "full contents of v0.16.0" → allow (version string is not a path token).
12. (r8 mention guard — the two live FPs, both naming paths) "the gate should DENY a dispatch that orders the runner to read a WHOLE FILE such as hooks/x.mjs" → allow; "a hit counts as a true positive when the order asks for the complete file hooks/x.mjs" → allow; "the phrase `whole file` must trip it for hooks/x.mjs" → allow (qualifier in backticks); 'label as TP any prompt saying "full contents of hooks/x.mjs"' → allow (qualifier inside double quotes); "Now return the whole file hooks/x.mjs" → deny (imperative, no meta word).
13. (r8 H3, =80 boundary independent of pipes) `head -80 hooks/x.mjs` → deny; `head -79 hooks/x.mjs` → allow; `head -80 hooks/x.mjs | grep x` → allow; `head -n 80 hooks/x.mjs` → deny; `sed -n '1,80p' hooks/x.mjs` → deny; `sed -n '1,79p' hooks/x.mjs` → allow; `sed -n '1,80p' hooks/x.mjs > /tmp/o` → allow (redirect); `grep -n TODO src/ | head -100` → allow (pipe before; also `src/` is not a path token); `tail -n 300 /tmp/x.log > /tmp/t; wc -l /tmp/t` → allow; `tail -n 300 /tmp/x.log` → deny; "Read(hooks/x.mjs, offset 1, limit 200)" → deny; "Read(hooks/x.mjs, offset 1, limit 60)" → allow.
14. (r8 `known-FN-direction` — accepted misses; assert **allow**, suffix the test name so nobody "fixes" them) "Read hooks/x.mjs.\n\nThen return the full file." → allow (path two lines up, non-glue between); "full contents, cleaned up, of hooks/x.mjs" → allow (`cleaned up` breaks adjacency); "Read hooks/x.mjs and return the full file contents" → allow. Contrast in the same case: "Read the whole file hooks/x.mjs and report it verbatim" → deny (H2 needs no path).
15. (r8 recall fixtures) The **13 labelled TPs** from the E1 round-2 sheet, verbatim as prompts, one assertion each. Expected result per prompt is computed by hand against §2 r8 by the Implementor and written into the test; the ones that come out **allow** carry the `known-FN-direction` suffix and are listed in the E1 report as the recall misses. The count of expected-deny is E1's recall numerator — the test file and the E1 number must agree.
17. (r9, from the r8 FP sheet — each string is the measured shape) "report the first 30 lines of /tmp/ah-wt-roster.log verbatim" → allow; "paste the grep output verbatim" → allow; "run this exact script and report its full stdout/stderr verbatim" → allow; "sed -n '10,40p' hooks/x.mjs, verbatim" → allow (case 5 and the mirror now agree); "hooks/x.mjs in full" → deny (terminal qualifier, mirror); "hooks/x.mjs (full file)" → deny; "From hooks/lib-hier.mjs: the full source of the `roster(dir)` function" → allow (mirror rejects `of`); "Search the whole file for `process.env.CLAUDE_PID` and report every match" → allow (search verb; and `process.env` is not a path token); "Fetch and grep the full text of pkg/constants.py for BUFFER" → allow; "`ls -R ~/.claude/skills/herdr` — full file listing" → allow; "Read tests/t.sh in full and report back a COMPACT numbered list of every test case" → allow; "Read hooks/report.mjs in full. Report back compactly:" → allow; "Read tests/t.sh in full (158 lines) and report back VERBATIM with line numbers: the entire file" → **deny** (`report` alone is not a distil signal); "grep for §13 as a heading first and read the whole section" → allow (H2 no longer lists `section`); "Read the whole file hooks/x.mjs and quote it" → deny (H2 control); "the complete text of section §7.5 of docs/specs/0008.md" → allow (qualifier-first `of section` breaks adjacency; was a generous TP label).
18. (r10) "Return the full contents of plugin.json." → deny (sentence-ending `.` terminates the path token); "Return the full contents of plugin.json, then stop" → deny; "Search process.env.CLAUDE_PID usage and return the whole file hooks/x.mjs" → H2 control deny; "Read /tmp/rh-summary.log in full" → **deny** (`summary` inside the path is not a distil signal); "Read hooks/x.mjs in full and summarise" → allow (guard iii on prose); "grep/ dir: return the full contents of grep/x.mjs" → deny (guard i must not see `grep` inside a path token); "tests/t.sh lines 1–200" → deny (path before range); "lines 1–200 of tests/t.sh" → deny; "lines 1–200" → allow (no path); "TASK A: … TASK B: Read skills/agent-roster/SKILL.md in full" → deny, and the logged `detail` shows the *third* `in full` span with its path (pins the #18 sheet rule).
16. (r8 negative control) Three non-gopher-shaped prompts that name paths with no qualifier: "grep -n TODO hooks/x.mjs and report file:line" → allow; "summarise hooks/x.mjs in ≤10 lines" → allow; "list the exported names in hooks/directive.mjs" → allow.

<!-- r8: the r3–r7 cases that followed are retained only as history of the wide predicate; they are NOT to be implemented. -->
11-old. (r3) "Return the FULL, VERBATIM content of these files, each clearly labeled" → deny (H1a and H1c); "report the full bullet list under that heading verbatim" → allow (no file-noun); "the complete, exact contents of hooks/x.mjs" → deny.
12. (r3, mention guard) "the gate should DENY a dispatch that orders the runner to read a WHOLE FILE" → allow; "add a test case: prompt asks for the entire file → deny" → allow; "the phrase `whole file` must trip it" → allow (backticks); "a hit counts as a true positive when the order asks for the complete file" → allow (definitional); 'label as TP any prompt saying "full contents"' → allow (double quotes); "Now return the whole file hooks/x.mjs" → deny (imperative, no meta word in window).
13. (r4 object guards) "give the full file listing of docs/" → allow (a); "full text of every FAIL line in /tmp/suite.log" → allow (b); "every line in the whole file that contains TODO" → allow (b); "grep -n across the whole file for X" → allow (b); "full text of the section beginning ## Scope" → allow (d); "return the full file if under 40 lines, else only the matching function" → allow (c); "return the full file if it is small" → deny (c, no number); "return the full file if under 500 lines" → deny (c, bound > 80); "Return the full contents of hooks/x.mjs" → deny (control).
14. (r6) "grep -n TODO src/ | head -100" → allow (H3 pipe-before); "tail -n 200 /tmp/x.log | wc -l" → allow (pipe-after); "head -150 hooks/x.mjs" → deny (control); "full text of the sections under ## Scope" → allow (plural); "full source of `roleForPeerName`" → allow (backtick ident); "full contents of `hooks/x.mjs`" → deny (backtick path); "full text of the RESYNC_FLAGS line" → allow (single line); "Run the full suite, one file at a time" → allow (comma binding); "FULL, VERBATIM content of these files" → still deny (comma directly after adjective).
15. (r7 — makes the r5 before-regex widening load-bearing, and pins each window at its derived length) "for every FAIL line, give the full text" → allow (LF_QUANT before, intervening word, 31 chars); "print each ERROR line's full text from /tmp/x.log" → allow (LF_QUANT before with intervening word; also LF_LINE before 7); "full text of each of the lines that contain X" → allow (LF_QUANT after, 37); "the RESYNC_FLAGS line's full text" → allow (LF_LINE before); "full text of the RESYNC_FLAGS line" → allow (LF_LINE after, 24); "full file if under 500 lines" → deny (lookbehind + (c) N>80); "full source of `refuseRosterEditWhileOwningTeam`" → allow (anchored backtick ident, 31 chars); "full contents of hooks/x.mjs — every line" → **deny**: LF_QUANT after is 40 and "every line" starts at offset 21, so this WOULD allow — this case documents the known cost: a whole-file order that appends a line-quantifier slips. Accept; runner STOP rule is the backstop. (Implementor: assert allow, and label it `known-FP-direction` in the test name so nobody "fixes" it into a deny by shrinking the window.)
    Control set: every deny in cases 1, 5–7, 11, 13, 14 still denies after r7 — run the whole file, not the new cases alone.
16. (r7 §2.2) "Search the whole file for X — report every match" → allow; "full source of these functions" → allow; "full text of those sections" → allow; "full contents of the tests/ directory (just filenames)" → allow; "full contents of tests/x.sh" → deny (path token, not a directory word); "line number and full line text" → allow; `tail -n 300 /tmp/x.log > /tmp/t; wc -l /tmp/t` → allow; `tail -n 300 /tmp/x.log` → deny; `head -80 path` → deny; `head -79 path` → allow; `head -80 path | grep x` → allow; `sed -n '1,80p' path` → deny; `sed -n '1,80p' path > /tmp/o` → allow.

Regression bar: every existing case in all three suites still passes; the
new cases fail against 0.16.0 (case 1 is the fails-without proof).

## 7. Decisions made / refused

- **Made**: object-based detection, not "verbatim"; 80-line threshold; both
  runners gated; runner side = prose STOP rule; mechanical runner-side check
  deferred with its trigger stated.
- **Ruled by the user (r2): hard deny.** r1 recommended a one-shot
  (session, prompt) checkpoint with re-issue-passes, on the grounds that the
  regex is a heuristic and re-issues would be countable in the log. The user
  chose no escape hatch: every hit is denied, always. Recorded so the
  tradeoff is not re-litigated: the cost is that a false positive forces a
  rewrite of an order that may have been fine; the mitigation is E1's ≥ 80%
  precision gate before ship and the two named tuning knobs.
- **Ruled by the user (r8): NARROW under hard deny.** Wide r7 estimated
  75–85% precision; every FP is a dead end with no escape. Narrow requires an
  explicit path token adjacent to the qualifier. Recall loss is accepted and
  measured (E1 #2), not floored. §2.0–§2.3 kept as the record.
- **Made (r8, flag for veto)**: (i) adjacency is **symmetric** — path may
  precede the qualifier ("hooks/x.mjs in full"); the ruling said "followed",
  I widened because H1b was already path-first and word order should not be
  a loophole. (ii) glue admits **one** newline + list marker so "these
  files:\n- path" — the r3 canonical TP — still hits. (iii) H3 keeps the
  `Read(path, offset, limit)` and "lines A–B of path" forms beside
  sed/head/tail: same object, same explicit path. (iv) a trailing-slash
  token is a directory, never a path token. Any of the four can be reverted
  by deleting its §6 fixtures; none affects the others.
- **Refused**: adding `verbatim` or `cat` as triggers (70% / legitimate-tmp
  cases); a size-based dispatcher check (impossible at PreToolUse).

## 8. Files, version, sequencing

- `task-gopher/hooks/directive.mjs` — predicate + threshold constant + deny
  text; one sentence appended to `FULL_DIRECTIVE:245` and `SHORT_REMINDER`.
- `task-gopher/hooks/pretooluse-nudge.mjs:495-523` — the new check before the
  smart-gate block; new log event.
- `task-gopher/agents/task-gopher.md:96`, `agents/smart-gopher.md:91` — STOP clause.
- `task-gopher/tests/test-relay-gate.sh` — cases 1–12.
- `task-gopher/commands/task-gopher.md` — document the gate and the
  `verbatim-deny` log event beside the existing strict-checkpoint text, stating
  plainly that it is a hard deny with no retry; `README.md` one paragraph.
- `task-gopher/.claude-plugin/plugin.json` 0.16.0 → **0.17.0** and root
  `.claude-plugin/marketplace.json:98` together. Lands after 0.16.0 ships; not
  folded (ruled r2).

## 9. NEEDS-EVIDENCE

- **E1 (r8) — two numbers, both reported; only the first is a floor.** Run
  the r8 narrow predicate over the same 656-prompt extraction (top-level
  transcripts under
  `~/.claude/projects/-Users-jimcline-git-repos-claudetools/*.jsonl`, `Agent`/`Task`
  tool_use with `subagent_type` containing `task-gopher`); print every hit
  with matched text + 200 chars of context.
  1. **Precision ≥ 90% on the ENTIRE narrow hit set** — label every hit, no
     sampling (the set should be small enough; if it exceeds ~80 the narrow
     rule is not narrow and that is itself a finding). Below 90% → report the
     FP shapes; do not tune blind.
  2. **Recall over the 13 labelled TPs** from the round-2 sheet: how many
     the narrow predicate still denies. **No floor** — the user sees the
     number and owns the trade. Must equal the expected-deny count in §6
     case 15.
  Also report the hit count and the H1/H2/H3 split.
  **Results:** r8 89 hits 62.9% (corrected 64.0% after the sheet-context
  bug); r9 55 hits **50/55 = 90.9%, recall 6/13 — gate met**. r10 fixes
  (§2 r10 block) expected 59 hits, recall 8/13; precision on the 59 to be
  re-reported, still ≥ 90%. E1 sheet rule from #18: context around the
  matched span, never the first textual occurrence.
- **E2 — SubagentStop payload for a gopher** (only if §4's mechanical check is
  ever built): confirm `transcript_path` and `last_assistant_message` are
  present for `agent_type: task-gopher:task-gopher`.

## 10. Confidence

- High that "verbatim" must not be the trigger — measured.
- High on the mechanism — a stateless predicate → `deny()` in the branch the
  smart-gate already occupies; nothing to fail open on.
- r8: high on precision (a required path token removes every FP shape seen
  in two labelling rounds except #106 write-param, which the quote rule
  covers when quoted). Medium-low on recall — my 40–70% estimate is
  unmeasured; E1 #2 replaces it. Knobs: threshold 80, glue length 40, glue
  word list — three named constants.
- Not recommending Ultra-Advisor.
