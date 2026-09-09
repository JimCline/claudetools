# 0045 — Inter-agent message protocol: token-cost audit

Status: r3. r1 (§1–§8) was the audit. r2 added **§9 implementation** (cuts 1–5,
new cut 8; cut 6 dropped on E1, cut 7 dropped as non-trivial) and **§10 commit
order + version bumps**. **r3 (§9.8) is a spec-defect ruling**: r2's byte
ceilings for cuts 5 and 8 were set from estimated savings the after-text never
delivered; ceilings reset to measured, savings claims corrected, after-text
unchanged. Brief `20260909-111145-1vga`. Cross-plugin cuts 1/3/4 are user-authorised
(brief `20260909-103830-1or1`). The brief asked for "§7"; §7/§8 already exist,
so implementation is §9.
Briefs: `20260909-100322-1nz4` (audit), `20260909-103830-1or1` (+ addendum:
fidelity is the hard requirement; caveman register permitted for cuts 5 and 8). User directive: "make sure the message protocol
between agents is as compressed as possible so that we're saving on tokens."

All numbers are `wc -c` bytes from the tree at `6a03d5c`+ (v0.69.2) and the
pool at `.claude/hierarchy/msgs/` (501 files). Token estimate throughout:
**~4 bytes/token** for English/markdown prose. Every "saves" figure is bytes;
divide by 4.

Three things a reader should not have to hunt for:

- **The brief was aimed at ~2% of the cost.** Message-file boilerplate
  (null frontmatter keys, `- none`, `## [N]` headings, absolute pointer paths)
  totals ~730 B per dispatch, of which ~350 B is cuttable. The two largest
  per-dispatch items are **not agent-hierarchy's**: task-gopher's relay
  prepends **10,362 B** to every `Agent` prompt, and comment-discipline injects
  **2,161 B** on every `SubagentStart`. Together ~12.5 KB/dispatch, 40% of the
  whole.
- **The tldr is the compression mechanism, not the redundancy.** It is the
  index that lets a receiver `grep -n '^## \['` and Read only the sections it
  needs. Cutting it forces full reads. §6.
- **Two of the brief's premises were wrong.** `archive/` is populated (36
  files; the sweep runs at `sessionstart.mjs:165`). `comms-protocol.md` is
  never injected — zero references in hooks/agents/skills — so its 26,996 B
  costs nothing per dispatch.

## 1. What is paid, and when

### 1.1 Subagent route (Orchestrator → `Agent(subagent_type: "ah:<role>")`)

A subagent starts with an empty context. Everything below is paid **per
dispatch** — there is no "one-time" on this route.

| item | bytes | owner | source |
|---|---|---|---|
| task-gopher relay directive prepended to the prompt (`updatedInput`) | **10,362** | task-gopher plugin | PreToolUse `Agent\|Task` |
| role definition `agents/<role>.md` body (system prompt) | 5,226–9,752 (architect 9,752 / implementor 5,226 / orchestrator 7,239 / reviewer 6,538 / task-runner 5,699 / ultra-advisor 7,264) | agent-hierarchy | Claude Code loads it per spawn |
| comment-discipline directive | **2,161** | comment-discipline plugin | SubagentStart |
| user `CLAUDE.md` (global) | ~6,000 | user | Claude Code, out of scope |
| dispatch prompt: `[hierarchy-msg <abs path>]` + one line | ~150 | protocol | Orchestrator |
| request file, read by the role | mean **4,310** (median 3,989; min 462; max 16,090) | protocol | `.claude/hierarchy/msgs/*--request.md` |
| ⤷ of which frontmatter | ~240 | protocol | 12 keys, `lib-hier.mjs:186-190` |
| ⤷ of which `## [0] tldr` | ~890 avg (444,164 B / 500 files) | protocol | index section |
| ⤷ of which `## [N]` heading lines | ~150 (76,473 B / 500 files) | protocol | skeleton |
| ⤷ of which `- none` placeholders | ~8 avg (141 lines pool-wide) | protocol | skeleton |
| Read tool line-number prefix on the request | ~6 B/line, ~400 | Claude Code | not cuttable |
| response file, written by the role (output tokens) | mean **5,872** (median 5,812; min 459; max 19,800) | protocol | `*--response.md` |
| response file, read back by the Orchestrator (input tokens) | 0–5,872 depending on whether it greps the index or reads whole | protocol | Orchestrator behaviour |
| role's final message echoed into the Orchestrator's context | contract says ~150 (pointer + status); **actual unmeasured** — see §5 E2 | protocol | role behaviour |
| `sessionstart.mjs` directive | **0** — `sessionstart.mjs:10`: subagent (`agent_id` set) → inject NOTHING | — | — |
| `docs/comms-protocol.md`, `docs/mcp-tools.md` | **0** unless a role opens them on demand (mcp-tools only on MCP-absent fallback) | — | — |

**Per-dispatch total (architect, typical): ≈ 30 KB input + ~6 KB output ≈
9,000 tokens**, of which the protocol's own message files are ≈ 10 KB and the
message-file *boilerplate* is ≈ 0.7 KB.

Nudge/gate hooks (`pretooluse-msg-gate.mjs`, `subagentstop-msg-nudge.mjs`,
`pretooluse-sendmessage-response.mjs`, `stop-peer-nudge.mjs`) emit only on a
**violation** (inline dispatch, missing response file, wrong token). Steady-state
cost per dispatch: 0. Their deny texts are 200–600 B each and fire once per
violation; not a ranking target.

### 1.2 Peer route (Orchestrator → `SendMessage` to a `--agent ah:<role>` session)

| item | bytes | when |
|---|---|---|
| `sessionstart.mjs` injection (directive + roles + peer contract + protocol items 0–14) | **~5,600 measured** from `buildDirective` (`lib-config.mjs:959-991`) — brief claims 18,226; the gap is unexplained, see §5 E1 | once per session **and again on every compact** (`sessionstart.mjs:29-30`) |
| role `agents/<role>.md` | as §1.1 | once per session |
| `<cross-session-message>` envelope + permission-laundering paragraph | ~700 | per message, Claude Code's, not cuttable |
| task-gopher UserPromptSubmit directive | **~1,900** | **per message received** (every SendMessage, every task-notification) — task-gopher plugin |
| `[hierarchy-peer-brief reply-to=…]` or `[hierarchy-msg <path>]` line | ~150 | per message |
| request / response files | as §1.1 | per dispatch |

On the peer route the role-md and directive are amortised; the per-message
multiplier is the task-gopher UPS directive (~1,900) plus the envelope (~700),
both outside agent-hierarchy.

### 1.3 Frequency

Pool: 265 requests / 235 responses over ~3.5 weeks (2026-08-16 → 09-09) ≈ 10–15
dispatches per working day. A 20-dispatch session on the subagent route pays
≈ 600 KB ≈ 150 K tokens of context setup, of which ≈ 250 KB is the two
cross-plugin injections. Per-dispatch dominates; nothing here is one-time
except on the peer route, and even there the directive re-pays on every compact.

## 2. Redundancy inventory (what is paid twice)

| duplicated text | where | per-dispatch cost of the duplicate |
|---|---|---|
| Delegation rule ("push retrieval to task-gopher") | task-gopher relay (10,362) **and** role md bullet — architect.md:90, reviewer.md:57, ultra-advisor.md:60, orchestrator.md (Tier rule + directive); implementor.md has **no** delegate bullet; task-runner.md:47 says never delegate and the relay's tier gate tells Haiku to ignore it | 10,362 |
| "Compress every message" bullet | architect.md:118, implementor.md:59, orchestrator.md:45, reviewer.md:77, ultra-advisor.md:82 (task-runner has its own at :76-80) | 0 per spawn (one file per spawn) — maintenance only |
| "BRIEF INTAKE / REPORT via message files" bullet | 5 role files | 0 per spawn; ~700 B of it could be tightened |
| "Always try `mcp__ah__*` first … commonly `mcp__plugin_ah_ah__<verb>`" | all 6 role files, ~600 B each | 0 per spawn; ~350 B tightenable |
| "Never call the generic `advisor` tool" | 5 role files, ~300 B | already denied in frontmatter `tools:`; the prose is belt-and-braces |
| tldr bullets vs body sections | every file; sample of 10 shows 5–6 tldr lines per file with a body counterpart | ~890 avg — **but it is the index, keep** (§6) |
| `[hierarchy-msg <abs path>]` (~110 B) | dispatch prompt, reply first line, `msg new --req` arg | ~330 |
| null frontmatter keys | `reason: null` 496/501 files, `team: null` 467, `parent: null` 121, `to_name`/`from_name`/`eta` null 134–153 | ~40–70 |
| comment-discipline for roles that cannot write code | reviewer (Edit denied), task-runner, ultra-advisor (Edit denied), architect (spec-only) | 2,161 on those spawns |

Cross-file duplication in `agents/*.md` costs nothing per dispatch because a
spawn loads exactly one file. Deduplicating it (an include mechanism) is a
maintenance win with zero token win — Claude Code has no include for agent md,
so it would be a build step. Not ranked.

## 3. Cost model summary

```
subagent dispatch (bytes in):
  10,362 task-gopher relay           ← cross-plugin, cut 1
   7,000 role md (avg)               ← cut 5 trims ~1,200
   2,161 comment-discipline          ← cross-plugin, cut 3
   4,310 request file (mean)         ← ~350 B cuttable, cut 7
   ~400  Read line prefixes          ← not cuttable
   ~150  dispatch line
  ------
  ~24,400 + CLAUDE.md
bytes out: 5,872 response (mean) + final message (unmeasured, cut 2)
orchestrator readback: 0–5,872 (behaviour, cut 2)
```

## 4. Ranked cut list

Ranked by bytes saved per dispatch × frequency. "Owner" names whose plugin
changes. Anything cross-plugin is the **user's call** (§7) — this spec ranks
it but does not authorise it.

### Cut 1 — task-gopher relay skips `ah:*` targets — saves ~10,300 B/dispatch, every dispatch
- **What**: the task-gopher PreToolUse relay that rewrites `Agent` prompts via
  `updatedInput` does not prepend its 10,362-byte directive when
  `subagent_type` starts with `ah:`. Optionally prepends a one-line stub
  ("task-gopher relay: ON — your role file carries the delegation rule").
- **Why it loses nothing**: every ah role that may delegate already carries the
  rule in its own md (architect.md:90, reviewer.md:57, ultra-advisor.md:60,
  orchestrator.md:96 + directive); task-runner is Haiku-tier and the relay
  tells it to ignore itself. The relay's *checkpoint* behaviour (the
  deny-to-prompt on direct Read) is a separate hook and keeps working — the
  checkpoint message explains itself when it fires.
- **Fidelity gap to close**: implementor.md has no delegation bullet. Either
  accept that (the Implementor runs the session's full toolset and is the
  execution tier anyway) or add one bullet (~250 B) — user's call; default
  accept.
- **Files**: task-gopher plugin's PreToolUse relay hook (the `updatedInput`
  rewrite; per memory note it is 0.6.0's mechanism). Not in this repo's
  agent-hierarchy tree.
- **Risk**: low. The ah roster's relay bounce keys (memory: "per-context bounce
  keys are load-bearing") are about *nested* dispatch loops, not target-name
  exemptions; a name-prefix skip does not touch them. Verify by the existing
  task-gopher relay tests — NEEDS-EVIDENCE E4.

### Cut 2 — roles stop echoing the report inline — saves 0–5,800 B/dispatch (evidence-gated)
- **What**: contract already says the final message is `[hierarchy-msg <path>]`
  + one status bullet (architect.md:124-133 and siblings). If roles in practice
  paste the report a second time inline, that is a full response paid twice
  (output tokens, then Orchestrator input). The Architect authoring this spec
  did exactly that on its previous brief.
- **Measure first**: §5 E2. If the mean echo is >1 KB, enforce mechanically:
  `subagentstop-msg-nudge.mjs` already reads the role's last message to find
  the token; add a length check (deny-with-reason when the message after the
  pointer line exceeds N bytes, N ≈ 600). Same shape for the peer route in
  `stop-peer-nudge.mjs`.
- **Fidelity**: none lost — the file holds the report; the Orchestrator reads
  the index and the sections it needs.
- **Files**: `hooks/subagentstop-msg-nudge.mjs`, `hooks/stop-peer-nudge.mjs`,
  test files for both.
- **Risk**: medium. A hard cap can trap a role whose status line is legitimately
  long; make the cap generous and the reason text say how to satisfy it.

### Cut 3 — comment-discipline skips non-code roles — saves 2,161 B on ~half of dispatches
- **What**: the comment-discipline SubagentStart hook checks `agent_type` and
  skips `ah:reviewer`, `ah:task-runner`, `ah:ultra-advisor`, `ah:architect`
  (Edit/Write denied or spec-only). Keeps injecting for `ah:implementor` and
  everything else.
- **Fidelity**: zero for reviewer/task-runner/ultra-advisor (cannot edit code);
  architect writes markdown only.
- **Files**: comment-discipline plugin's SubagentStart hook. Cross-plugin —
  user's call. NEEDS-EVIDENCE E3: confirm the SubagentStart payload carries
  `agent_type` (memory note says `--agent` sets it at SessionStart/Stop; not
  verified for SubagentStart).
- **Risk**: low.

### Cut 4 — task-gopher UserPromptSubmit directive skipped for `ah:*` `--agent` sessions — saves ~1,900 B per peer message
- **What**: same argument as cut 1, peer route. Every SendMessage and every
  task-notification delivered to a peer role session re-injects ~1,900 B that
  the role md already states.
- **Files**: task-gopher UserPromptSubmit hook. Cross-plugin.
- **Gate**: E3 (does the UPS payload carry `agent_type`?). If not, the hook can
  read the session-role file `lib-session-role.mjs` maintains — but that is
  agent-hierarchy state read by another plugin; flag as coupling.
- **Risk**: low–medium (coupling).

### Cut 5 — tighten the five shared bullets in `agents/*.md` — saves ~1,000–1,500 B/dispatch
- **What**: rewrite in the fragment style the bullets themselves demand:
  "Compress every message" (~450 B → ~200), "BRIEF INTAKE / REPORT" (~700 →
  ~350), "Always try `mcp__ah__*`" (~600 → ~250), "peer message" (~250 → ~120),
  "Never call the generic advisor" (~300 → ~120). Same edit in all six files.
- **Constraint (hard)**: every clause survives. These are behavioural rules;
  the compaction-guard lesson applies — a reworded rule can invert. Reviewer
  diffs clause-by-clause, not by gist. Specifically keep: `grep -n '^## \['`
  intake; `req_path` from the brief; frontmatter `id`/`from`; the
  `second-opinion` verdict rule; "MCP absent only if no such tool under any
  prefix"; "say so ONCE".
- **Files**: `agents/architect.md`, `implementor.md`, `orchestrator.md`,
  `reviewer.md`, `task-runner.md`, `ultra-advisor.md`; `tests/` that assert on
  agent-md phrases (E5 lists them).
- **Risk**: medium (wording). Zero mechanical risk — no hook parses these
  bullets except tests.

### Cut 6 — SessionStart open-exchange listing — saves up to ~12 KB per session start and per compact (evidence-gated)
- **What**: the brief measured 18,226 B injected; `buildDirective` is ~5,600.
  The remainder is most plausibly the per-session status block (open
  exchanges, peer roster, tier line — `sessionstart.mjs:29`). The pool holds
  265 requests vs 235 responses: ~30 requests were never answered, and the
  sweep archives only **closed** exchanges (`sessionstart.mjs:30`), so
  unanswered ones are listed forever.
- **Measure first**: §5 E1. If the open-exchange block is the bulk: cap it
  (newest N, plus a count), and extend `sweep` to archive unanswered requests
  older than `SWEEP_DAYS` (they are dead — no orchestrator is waiting on a
  three-week-old brief). If the bulk is elsewhere, re-rank.
- **Files**: `hooks/sessionstart.mjs`, `hooks/lib-hier.mjs:445-452` (`sweep`),
  `hooks/lib-config.mjs` (status block builder), tests.
- **Risk**: low for the cap; archiving unanswered requests changes `msg list`
  output — check the spec-0037 durability invariant: archive is still the
  durable record, so the pair invariant holds.

### Cut 7 — message-file skeleton trims — saves ~350 B/dispatch
- Drop null frontmatter keys on write (~40–70 B). Gate: every key is read
  somewhere (`lib-hier.mjs:288-302, 359-406, 485-511`;
  `pretooluse-route-gate.mjs:416`; `stop-peer-nudge.mjs:61`;
  `userpromptsubmit-peer-tracking.mjs:66`). The readers must treat *absent* as
  `null` — E6 checks the frontmatter parser. Keep `parent` when non-null
  (chain walk `:359-362`).
- Omit `- none` sections on write; `lib-hier.mjs:526 isPlaceholder` already
  tolerates them; `indexAnchors` (`:159`) indexes whatever headings exist.
  Saves ~8 B avg, ~180 B on the empty-skeleton case. Cheap to do alongside the
  above; worthless alone.
- Shorten the `## [N] key` heading lines: no — `grep -n '^## \['` intake and
  `indexAnchors` depend on them, and 150 B is the price of an index.
- **Files**: `hooks/lib-hier.mjs:176-191`, tests in `tests/test-msg*.sh`.
- **Risk**: low, but the saving is ~90 tokens; do it only as a rider on cut 6.

### Not ranked: relative/short ids in the pointer
- `[hierarchy-msg <abs path>]` × ~3 per dispatch ≈ 330 B. A short id would save
  ~250 B/dispatch (~60 tokens) and would touch `MSG_TOKEN_RE`
  (`lib-hier.mjs:40`), `MSG_TOKEN_LINE_RE` (`lib-peer.mjs:78`), the `--req`
  absolute-path contract (`lib-hier.mjs:260`), `validateResponseToken`
  (`:506-511`), both deny reasons, and every role md. A resolver from id to
  path would also have to handle the pool-resolution case the brief notes
  (`req_path` exists precisely because cwd can resolve a different pool).
  Cost/benefit fails. **Do not cut** (§6).

## 5. NEEDS-EVIDENCE

Each item names what to run and what each result decides. Route to the
Implementor; none is a design call.

- **E1 — sessionstart injection breakdown.** Run `hooks/sessionstart.mjs` with
  a `startup` payload (no `agent_id`; with and without `agent_type: ah:orchestrator`)
  in this repo, capture `additionalContext`, `wc -c` it, and split by the four
  headings `buildDirective` emits plus whatever follows them. Decides cut 6's
  rank: if the post-directive block is >8 KB, cut 6 moves to #2; if the total
  is ~5,600 the brief's 18,226 was a different measurement (say which) and
  cut 6 is dropped.
- **E2 — final-message echo size.** From the last 30 `ah:*` subagent
  transcripts under `~/.claude/projects/-Users-jimcline-git-repos-claudetools/`
  (or the task output dir), extract each role's final assistant message and
  measure bytes after the `[hierarchy-msg …]` line. Report mean/max. Decides
  cut 2: mean >1 KB → enforce; <300 B → drop cut 2.
- **E3 — hook payload fields.** Dump the JSON stdin of one SubagentStart and
  one UserPromptSubmit event for an `ah:architect` spawn / `--agent`
  session (a throwaway hook that `cat`s stdin to a file). Decides whether
  cuts 3 and 4 can key on `agent_type` directly or need the session-role file.
- **E4 — task-gopher relay tests.** Name the test file(s) covering the
  `updatedInput` rewrite and whether any asserts the directive is present for
  every target. Decides the size of cut 1's test change.
- **E5 — agent-md phrase assertions.** `grep -rn "agents/.*\.md" agent-hierarchy/tests/`
  and list every test that greps a phrase in an agent md. Decides cut 5's test
  blast radius.
- **E6 — frontmatter parser on absent keys.** Read the frontmatter parser in
  `lib-hier.mjs` (the function `readMessage`/equivalent uses) and report
  whether a missing key yields `undefined` or `null`, and whether any reader
  does `=== null`. Decides whether cut 7's null-drop is a one-line change or
  needs a normaliser.

## 6. Do not cut

- **The `## [0] tldr` section.** It is the index that makes partial reads
  possible (`grep -n '^## \['` then Read by range). Its ~890 B buys the
  option to skip the other ~3,400. Removing it makes every dispatch a full
  read: net loss. The brief's "tldr duplicates section headings" is by design.
- **`## [N] key` heading lines.** Same reason; `indexAnchors` (`lib-hier.mjs:159`)
  and the intake `grep` both key on them.
- **Absolute path in `[hierarchy-msg <path>]`.** Contract at `lib-hier.mjs:260`;
  it is what makes the reply land beside the request when cwd resolves a
  different pool. 60 tokens is not worth a resolver.
- **The request/response file pair.** Spec 0037 durability invariant; also
  what `msg list`, downstream tracing (`lib-hier.mjs:387-406`), and both gates
  read.
- **Frontmatter keys** `id type to from slug parent created to_name from_name team reason`
  — every one has a reader (§4 cut 7 lists them). Only their *null encoding* is
  in play.
- **`<cross-session-message>` envelope and the permission-laundering paragraph.**
  Claude Code's, and a security boundary.
- **Read tool line-number prefixes.** Tool behaviour.
- **Nudge/gate deny texts.** They fire only on violation; shortening them
  trades clarity at the moment someone is already off-protocol for ~100 tokens
  they rarely pay.
- **Any clause of a behavioural rule in `agents/*.md`** — cut 5 compresses
  wording, never drops a clause.

## 7. Decisions made / refused

- **Made**: the ranking, the "tldr is the index" ruling, the do-not-cut list,
  and that cross-file dedup of `agents/*.md` is not a token cut.
- **Refused — user's call**: cuts 1, 3, 4 change other plugins (task-gopher,
  comment-discipline) based on agent-hierarchy's role names. That is a
  cross-plugin coupling decision, and task-gopher's relay was ruled load-bearing
  once already (memory: "task-gopher: default not preference"). The
  counter-argument is specific: the ah roles carry the rule in their own md,
  so for them the relay is duplicate text, not the only copy. Present both.
- **Refused — user's call**: whether to add a delegation bullet to
  `implementor.md` when cut 1 lands (default: no).
- **Corrections to the brief**: `archive/` is populated (36 files);
  `comms-protocol.md` is never injected; the 18,226 B figure is unexplained
  (E1); task-runner does carry the compression rule (task-runner.md:48-52,
  76-80) in its own words — no cut needed there.

## 8. Confidence

- **High** on the per-dispatch table for items measured directly (relay 10,362;
  comment-discipline 2,161; role md sizes; pool statistics; zero injection of
  comms-protocol/directive into subagents — all from read code and `wc -c`).
- **Medium** on the ranking between cuts 2 and 6 — both are evidence-gated and
  either could be the #2 item.
- **Low** on the 18,226 vs 5,600 discrepancy; deliberately not resolved here.
- Not recommending Ultra-Advisor escalation. Nothing here is hard to reverse.

## 9. Implementation (r2)

### 9.0 Evidence that shaped r2, and two corrections

- **E1**: SessionStart injection 18,252 B; open-exchange listing 0 B. Cut 6
  dropped. E1's "PEER BRIEF CONTRACT 14,813" is **the whole directive tail from
  that heading to the end** — the contract bullets themselves are 1,792 B
  (`lib-config.mjs:966-971`); protocol items 0–14 (`:976-990`, item 12–14 at
  `:938-940`, gate sentences `:889-899`) are the other ~13 KB. Cut 8 therefore
  covers the **entire `buildDirective` text**, not one heading.
- **E2**: 124 echoes; mean 1,066 B, median 641, max 5,016, 52 >1,000. Cut 2
  re-ranked — see 9.2: a hook that fires on half of all dispatches costs a
  round trip each time it fires, ≈ what it saves. Cap set high; wording does
  the rest.
- **E3**: `agent_type` is in the SubagentStart payload
  (comment-discipline `subagentstart.mjs:45-46` already gates on it); task-gopher
  reads it on UserPromptSubmit and SessionStart via `isGopherAgent`
  (`userpromptsubmit.mjs:19`, `sessionstart.mjs:18` → `directive.mjs:187-189`).
- **New in r2, not in the brief**: task-gopher's **SessionStart** hook injects the
  full 10,362 B directive into every `--agent ah:<role>` peer session at start
  and on every compact (`task-gopher/hooks/sessionstart.mjs:18-23`). Folded
  into cut 4.

### 9.1 Cut 1 — task-gopher relay exempts `ah:*` targets

- **Mechanism**: reuse the existing builtin exempt set.
  `task-gopher/hooks/pretooluse-nudge.mjs:126` `RELAY_EXEMPT = new Set(["Explore","Plan","statusline-setup","output-style-setup"])`
  gains the six hierarchy roles: `ah:architect`, `ah:implementor`,
  `ah:orchestrator`, `ah:reviewer`, `ah:ultra-advisor`, `ah:task-runner`.
  `relaySkipReason` (`:134`) already returns `"builtin"` for a hit and the
  dispatch path (`:529-532`) already allows without rewriting.
- **Why the builtin set and not `~/.claude/task-gopher.relay-exempt`
  (`directive.mjs:40`)**: the user file is per-machine config, not shipped —
  every install would have to be hand-edited. Why not a prefix rule: the set is
  exact-match (`:134-135`); six literal names are one line and need no new
  matching code. A prefix helper is YAGNI until a seventh role exists.
- **Gate**: `subagent_type` ∈ that set. Non-`ah:` dispatches untouched.
- **What is NOT affected**: the strict-mode checkpoint that fires *inside* a
  subagent on direct Read/Grep (keyed on the subagent's own `agent_type` via
  `gopherKind`, `directive.mjs:186-189`) keeps firing for ah roles — its deny
  text explains itself. Bounce keys / nested-dispatch protection: untouched;
  they key on context, not target name.
- **Fidelity**: architect.md:90, reviewer.md:57, ultra-advisor.md:60,
  orchestrator.md:96 carry the delegation rule. implementor.md does not —
  user's default "no bullet" taken (it is the execution tier; its own md tells
  it to run the build/tests). task-runner is Haiku and told by the relay itself
  to ignore it.
- **Test (fails without)**: `task-gopher/tests/test-relay-gate.sh` — new case:
  PreToolUse `Agent` with `subagent_type: "ah:architect"`, relay ON, prompt
  unstamped → output has **no** `updatedInput` (or `updatedInput.prompt` equals
  the input prompt). Sibling positive case: `subagent_type: "general-purpose"`
  → stamped (guards against over-broad exemption).
- **Files**: `task-gopher/hooks/pretooluse-nudge.mjs`,
  `task-gopher/tests/test-relay-gate.sh`, `task-gopher/commands/task-gopher.md:14`
  (mention the builtin ah exemption beside the user-file one),
  `task-gopher/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json:98`.
- **Saves**: 10,362 B per ah-role Agent dispatch.

### 9.2 Cut 2 — final-message echo: wording first, hook as a backstop only

- **Ruling on the threshold**: **2,000 B after the pointer line**, not 600.
  Reason: E2 median is 641 and mean 1,066; a cap near the median fires on ~half
  of dispatches and each firing costs a Stop-block round trip (deny reason
  ~300 B + regenerated final ~200 B + the turn) ≈ the ~450 B it saves. Net ≈ 0.
  At 2,000 the hook catches only the tail (max 5,016) where the saving is
  3–5 KB per hit. The bulk of the gain comes from cut 5's rewording of bullet
  (d), which makes the contract unmissable: *final message = pointer line +
  ONE status bullet*.
- **Mechanism, subagent route**: `hooks/subagentstop-msg-nudge.mjs` — after the
  existing `hasResponseToken(last, meta.id)` check passes (`:99`), measure
  `last_assistant_message` bytes **after** the line carrying the token; > 2,000
  → `block` with a reason of the form "ah: final message must be
  `[hierarchy-msg <path>]` + one status bullet — the file carries the report;
  trim and stop again." Reuse the hook's existing once-per-agent nudge record
  (`:78-84`) so it blocks at most once per agent (no loop if the agent cannot
  comply).
- **Mechanism, peer route**: `hooks/pretooluse-sendmessage-response.mjs` — it
  already parses the SendMessage body for the response token (`:59-82`). Same
  2,000 B rule on the body after the token line, same once-per-obligation
  behaviour (the pending record it already consults, `:90-104`). Do **not** put
  this in `stop-peer-nudge.mjs` — it fires when the report is *missing*, and it
  never sees the SendMessage body.
- **Constraint**: the cap counts bytes after the pointer line so a long
  absolute path never trips it. Deny text must name the cap.
- **Test (fails without)**: `tests/test-msg-response.sh` (or a new
  `test-msg-echo-cap.sh`): SubagentStop with a valid token followed by 2,500 B
  of filler → `decision: block`; same with 300 B → allow; SendMessage variant in
  `tests/test-sendmessage-response-nudge.sh`.
- **Files**: `hooks/subagentstop-msg-nudge.mjs`,
  `hooks/pretooluse-sendmessage-response.mjs`, the two tests.
- **Saves**: ~1 KB mean per dispatch via wording; 3–5 KB per hook hit on the tail.

### 9.3 Cut 3 — comment-discipline skips non-authoring hierarchy roles

- **Mechanism**: `comment-discipline/hooks/lib-config.mjs:44-50`
  `NON_AUTHORING_AGENTS` gains `ah:architect`, `ah:reviewer`, `ah:ultra-advisor`,
  `ah:task-runner`. `subagentstart.mjs:46` already quits on membership. Nothing
  else changes; `ah:implementor` and `ah:orchestrator` keep the injection.
- **Why architect is in the set**: Bash denied, Edit scoped to the spec file by
  contract; it authors markdown specs, and the directive is about code comments.
  If a reviewer of this change disagrees, drop `ah:architect` from the list —
  the other three are unarguable (Edit/Write denied or Haiku runner).
- **Test (fails without)**: `comment-discipline/tests/test-subagentstart.sh` —
  SubagentStart with `agent_type: "ah:reviewer"` → no `additionalContext`;
  `agent_type: "ah:implementor"` → injected (guards the positive case).
- **Files**: `comment-discipline/hooks/lib-config.mjs`,
  `comment-discipline/tests/test-subagentstart.sh`,
  `comment-discipline/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json:45`.
- **Saves**: 2,161 B per spawn of those four roles.

### 9.4 Cut 4 — task-gopher skips `--agent ah:*` sessions on UserPromptSubmit AND SessionStart

- **Mechanism**: both hooks gate on `isEnabled() && !isGopherAgent(input)`
  (`userpromptsubmit.mjs:19`, `sessionstart.mjs:18`). Add a second exclusion:
  `agent_type` is a string starting with `ah:`. Put the predicate beside
  `isGopherAgent` in `directive.mjs` so both hooks share one definition and the
  role list lives in one place (it is the same six names as cut 1 — one
  exported constant, referenced from `pretooluse-nudge.mjs:126` and here).
- **Gate**: exact membership in that constant, not a prefix test — same
  reasoning as 9.1.
- **Fidelity**: the role md carries the rule; a `--agent ah:<role>` session
  loads its md once at start. The role notice from agent-hierarchy
  (`buildRoleSessionNotice`, 835 B) does not mention task-gopher and need not.
- **NEEDS-EVIDENCE E7 (statically unresolvable)**: whether the UserPromptSubmit
  payload carries `agent_type` for a top-level `--agent` session. Memory records
  it on SessionStart and Stop only. `isGopherAgent` already assumes it on UPS
  for gopher *subagents*, which is a different case. Measure: temporary hook
  that writes UPS stdin to a file, one prompt in an `--agent ah:architect`
  session. If absent → the UPS half of cut 4 needs a session marker written by
  task-gopher's SessionStart (which does see `agent_type`) keyed on
  `session_id`; spec that as a follow-up, do not block the SessionStart half.
- **Test (fails without)**: task-gopher currently has **no** UPS test
  (`grep -ln UserPromptSubmit tests/*` empty). New `test-userpromptsubmit.sh`:
  payload with `agent_type: "ah:architect"` → empty stdout; without
  `agent_type` → `SHORT_REMINDER` present. Same pair for `sessionstart.mjs`.
- **Files**: `task-gopher/hooks/directive.mjs`, `task-gopher/hooks/userpromptsubmit.mjs`,
  `task-gopher/hooks/sessionstart.mjs`, new test, plugin.json, marketplace.json.
- **Saves**: 2,053 B per message received by a peer role session; 10,362 B per
  peer-session start and per compact.

### 9.5 Cut 5 — tighten the shared bullets in `agents/*.md`

- **Register**: caveman (user-authorised): drop articles/filler/pleasantries,
  fragments, arrows for causality. **Every technical clause survives.** The
  Reviewer validates by the clause checklist under each bullet, not by gist.
- **Verbatim-survival rule**: any phrase a test greps against an agent md stays
  byte-identical. Known from `tests/test-agent-frontmatter.sh`: `generic \`advisor\` tool`
  (:26), `NEEDS-EVIDENCE` (:40), `READ-ONLY retrieval` / `execution legwork`
  (:41), `read-only inspection` (:47), `never execute yourself` /
  `MANDATORY for execution` (:48), `a test should pass, run it` (:49) — only
  the first is inside a bullet this cut touches; the after-text keeps it.
  `tests/test-mcp-cli-fallback.sh` (10 refs) and `test-mcp-server.sh` (4)
  assert on bullet (e)'s wording — the Implementor lists those literals before
  editing and the after-text below is adjusted only where a literal is
  otherwise lost; if a literal is pure filler the test changes instead, and the
  commit message names it.
- **Test (fails without)** — r3 ceilings, measured from the applied
  after-text + ~1% margin (`wc -c`, whole file incl. frontmatter):
  architect 9,752 → ≤ **9,600** (measured 9,504); ultra-advisor 7,264 →
  ≤ **7,100** (7,015); reviewer 6,538 → ≤ **6,350** (6,299); implementor
  5,226 → ≤ **5,100** (5,038); task-runner 5,699 → ≤ **5,650** (5,585);
  orchestrator 7,239 → ≤ **7,200** (7,122). Each is below HEAD, so the test
  still fails against the unedited files. r2's ceilings (9,300 / 6,800 /
  6,150 / 4,850 / 5,450 / 6,950) were derived from per-bullet byte estimates
  in this section that were ~100 B/bullet optimistic; the after-text is
  unchanged and stays as the applied text.
- **Measured saving** (r3): 114–249 B per file (architect −248, ultra-advisor
  −249, reviewer −239, implementor −188, orchestrator −117, task-runner −114);
  per bullet −20 to −81. r2's "~450–550" and r1's "1,000–1,500" were
  estimates, both wrong. Still worth keeping: zero mechanical risk, already
  applied, and (d)'s sharpened "ONE status bullet" is cut 2's real mechanism.
  Not worth a further pass: another caveman round on already-dense rule
  text buys maybe 100 B/file and risks a clause each time.

Canonical after-text (architect.md is the base; per-file variants in 9.5.1).

**(a) advisor** — before architect.md:109-113, 349 B; identical in implementor.
After:
> - **Never call the generic `advisor` tool** — denied in your frontmatter; harness offers it anyway → rule stands. Escalation path = previous bullet: recommend Ultra-Advisor in your report. Sideways advisor call escapes the chain, often lands on your own tier → buys nothing.

Check: denied-in-frontmatter; harness-offers-anyway still denied; escalation = Ultra-Advisor via report; sideways call escapes chain; lands on own tier; buys nothing. ~260 B.

**(b) peer message** — before :114-117, 270 B; identical in implementor, reviewer, ultra-advisor. After:
> - **Tasked as a peer** (message opens `[hierarchy-peer-brief reply-to=...]`, not an Agent-tool spawn) → report must be DELIVERED, not just written: SendMessage it to the reply-to address before the task counts as done.

Check: sentinel form; contrast with Agent spawn; DELIVERED not written; SendMessage; reply-to address; before done. ~200 B.

**(c) compress** — before :118-123, 444 B; identical in implementor, reviewer, ultra-advisor; task-runner variant :76-80 (357 B, "order" for "ask"). After:
> - **Compress every message to another agent.** Dispatch orders, peer SendMessages, reports back = agent-to-agent traffic, not conversation: no greetings, no restating the ask, no narrating next steps, no hedging. Full factual fidelity — never drop a fact to save tokens — in fewest tokens: fragments over sentences, `file:line` over prose, lists over paragraphs.

Check: three message kinds; not-a-person framing; the four "no"s; fidelity clause; the three "over"s. ~330 B. task-runner: same text with "the order" for "the ask" and only "reports" as the kind.

**(d) brief intake / report** — before :124-133, 706 B; identical in ultra-advisor. After:
> - **BRIEF INTAKE / REPORT via message files.** Brief is a file (dispatch carries `[hierarchy-msg <path>]`) → `grep -n '^## \[' <path>` for the index, Read only the sections you need. Report: `mcp__ah__msg_new` — `id`/`from` from the request frontmatter, `req_path` = the brief's own `[hierarchy-msg]` path (reply lands beside the request even when cwd resolves a different pool); fill it: bullets, no prose, status first. Final message = `[hierarchy-msg <response path>]` + ONE status bullet, nothing else — the file carries the report. Request `reason:` = `second-opinion` → caller is your tier or higher: verdict, not tutorial.

Check: grep index; Read selectively; msg_new; id/from source; req_path source and why; bullets/no prose/status first; final message = pointer + one status bullet, nothing else (sharpened for cut 2); second-opinion rule. ~560 B.

**(e) mcp first** — before :134, 920 B (one line); byte-identical in
implementor :73, reviewer :91, ultra-advisor :98, task-runner :74;
orchestrator :57 differs only in the clause after `say so ONCE:`.
**Frozen by test**: `tests/test-mcp-cli-fallback.sh:117` `$INVARIANT` (the
sentence from `Always try` through `say so ONCE:`) must appear exactly once in
each of the 5 agent files + orchestrator + 2 SKILL.md files; `:139-141`
`$CLAUSE_A/B/C` fix the clause after it per file (A orchestrator, B the five,
C skills). That is a deliberate cross-file uniformity invariant from an earlier
spec; this cut does **not** reopen it. Only the tail after clause B/A is
compressed. After (five agent files):
> - Always try `mcp__ah__*` first — it is the preferred path. Only if it is absent from your toolset or a call to it fails as not-connected, fall back to the CLI equivalents listed in `agent-hierarchy/docs/mcp-tools.md` rather than guessing the arguments, and say so ONCE: add one line to your report. `mcp__ah__*` = the ah MCP tools under whatever prefix your install surfaces — commonly `mcp__plugin_ah_ah__<verb>`; match on the verb, not the prefix; MCP is absent only if no such tool appears under any prefix.

Orchestrator: same, with clause A verbatim (`say so ONCE: tell the user in your next message that the `ah` server is not connected, that you are using the CLI, and that `/reload-plugins` or a restart fixes it.`) in place of clause B. SKILL.md files: untouched (clause C, not in this cut's scope).

Check: INVARIANT byte-identical; clause A/B byte-identical; tail keeps prefix-agnostic definition, common prefix example, verb-match, absence definition. ~790 B (saves ~130, not ~520 — the frozen part is the bulk).

#### 9.5.1 Per-file variants
- Reviewer (a) :65-72 (570 B), ultra-advisor (a) :72-77 (396 B, "you ARE the apex"), orchestrator (a) :41-44 (258 B, names the Ultra-Advisor gate); implementor/reviewer (d) :65-72 / :83-90 (587 B, escalation via Orchestrator); orchestrator (c) :45-51 (509 B, dispatch + SendMessage), (d) "Message files." :52-56 (327 B), (e) :57 (659 B); implementor/reviewer (e) (758 / 755 B); ultra-advisor (e) :98-105 (952 B).
- Rule: apply the canonical after-text, then re-add every clause the variant carries beyond the base, in the same register. The Implementor's commit message lists, per file, the extra clauses re-added. The Reviewer diffs each variant's before against its after clause-by-clause.
- Correction to the byte survey above: bullet **(e) is byte-identical** in
  architect, implementor, reviewer, ultra-advisor, task-runner (the earlier
  per-file byte counts were line-range artifacts). Only orchestrator's (e)
  differs — locate it by `grep -n 'mcp__ah__\*' agents/orchestrator.md`; if
  identical, canonical after-text applies; if it carries extra clauses
  (`/reload-plugins` is asserted there by `test-mcp-cli-fallback.sh:152`),
  keep them.
- implementor (d) :65-72 and reviewer (d) :83-90 = architect's (d) **minus**
  the `second-opinion` sentence. task-runner (d) :66-73 = same, with "order"
  for "brief" in the first clause. Apply the canonical (d) after-text without
  the final sentence; task-runner keeps "order".

#### 9.5.2 Variant after-texts

**orchestrator (a)** :41-44 (258 B). After:
> - **Never call the generic `advisor` tool** — denied in your frontmatter; harness offers it anyway → rule stands. Ultra-Advisor is your escalation apex, gated by its own approval flow; a sideways advisor call skips that gate for no benefit.

Check: denied; harness-anyway; UA = apex; own approval flow; sideways skips gate; no benefit.

**reviewer (a)** :65-72 (570 B). After:
> - **Never call the generic `advisor` tool** — denied in your frontmatter; harness offers it anyway → rule stands. Review is assigned to YOU; escalation runs through the Orchestrator to the Ultra-Advisor. A sideways advisor call = escalation outside the chain, frequently on the same model you already run — tokens spent on a second opinion from yourself. Finding beyond your confidence → mark it so in your report, recommend Ultra-Advisor escalation with the exact question.

Check: denied; harness-anyway; review assigned to YOU; path Orchestrator → UA; outside chain; same model; second opinion from yourself; beyond-confidence handling incl. exact question.

**ultra-advisor (a)** :72-77 (396 B). After:
> - **Never call the generic `advisor` tool** — denied in your frontmatter; harness offers it anyway → rule stands. You ARE the apex — no stronger tier to consult; an advisor call from you runs a model at or below your own. Genuinely undecidable at your tier → a finding to report, not a reason to ask a lesser oracle.

Check: denied; harness-anyway; ARE the apex; no stronger tier; at-or-below; undecidable → report, not lesser oracle.

**orchestrator (c)** :45-51 (509 B). After:
> - **Compress every message to another agent.** Dispatch orders and peer SendMessages = agent-to-agent traffic, not conversation: no greetings, no restating the ask, no narrating next steps, no hedging. Full factual fidelity — never drop a fact to save tokens — in fewest tokens: fragments over sentences, `file:line` over prose, lists over paragraphs. Applies to what you send them; replies to the user stay in normal prose.

Check: canonical (c) clauses (two message kinds here) + the user-prose exception.

**orchestrator (d) "Message files."** :52-56 (327 B). After:
> - **Message files.** Every role dispatch rides a request file: create it with `mcp__ah__msg_new`, put `[hierarchy-msg <path>]` in the dispatch or brief, expect the reply as `[hierarchy-msg <response path>]`. The file pair under the hierarchy dir is the durable record; in-band text only points at it.

Check: every dispatch; msg_new; pointer in dispatch/brief; reply form; pair = durable record; in-band = pointer. (~290 B; near-terse already, and `test-mcp-cli-fallback.sh:177` greps `msg.mjs new ... --to` in orchestrator.md — that literal lives elsewhere in the file; confirm it survives untouched.)

**task-runner (c)** :76-80 (357 B). After:
> - Your report = agent-to-agent traffic, not conversation: no greetings, no restating the order, no narrating next steps, no hedging. Full factual fidelity — never drop a fact to save tokens — in fewest tokens: fragments over sentences, `file:line` over prose, lists over paragraphs.

Check: report framing; "order"; four no's; fidelity; three over's.

### 9.6 Cut 8 — compress the Orchestrator SessionStart directive (`buildDirective`)

- **Scope**: every string in `lib-config.mjs` `buildDirective` (`:949-994`),
  `protocolItems1214` (`:927-942`), `gateSentences` (`:889-899`),
  `peerConfirmationParagraph` (`:909-919`), and the Roles preamble (`:962`).
  `roleLines` (`:861-879`) and `buildRoleSessionNotice` (`:1012-1020`, 835 B)
  are already terse — untouched.
- **Register**: caveman. **Verbatim-survival rule**: item numbers `0.`–`14.`
  and their ALL-CAPS labels (`PEER BRIEF CONTRACT`, `PEER NAME CONFIRMATION`,
  `MESSAGE FILES`, `PEER ROSTER + ROUTE`, `TIER RULE`, `USER GATE`); every
  quoted AskUserQuestion option label; every command string and flag; every
  config key and value (`handoffs:"confirm"`, `dispatch:"model"`, `peer:"auto"`);
  every sentinel/token form; the `haiku<sonnet<opus<fable` ranking; `Max 2`;
  `ONCE`. Cross-references between items (item 7, 12, 13) stay valid.
- **Test (fails without)** — r3: `tests/test-sessionstart-agent.sh` (or new
  `test-directive-size.sh`): `buildDirective` output for the **Implementor's
  fixture** (the one that measured 14,107 / 16,011 — name it in the test) with
  `handoffs:"auto"` → ≤ **14,300 B**; `handoffs:"confirm"` → ≤ **16,200 B**.
  Both are below HEAD on the same fixture (14,955 / 17,351), so the test fails
  against the unedited file. r2's 9,500 / 11,500 were unreachable without
  dropping clauses — see §9.8. Plus:
  every literal the existing directive tests grep (E5 list — Implementor
  produces it first, `grep -nE "grep -q|grep -c|grep -F|=~" tests/test-{sessionstart-agent,flow-mode,ultra-gate,route-gate,route-gate-subordinate,peer-dispatch,orchestrator-liveness}.sh`)
  still matches; a literal that no longer matches is either restored verbatim
  in the after-text (preferred) or, if pure filler, the test is updated and the
  commit message says which. **Verified against the after-text below** (all
  survive): `Agent hierarchy ACTIVE`, `MESSAGE FILES`, `PEER ROSTER`, `TIER RULE`
  (`test-sessionstart-agent.sh:114-116`); `0. Handoff gate`, `AskUserQuestion`,
  `errands are not handoffs`, `handoffs are currently "confirm"` / `"auto"`,
  `AT ANY TIME`, `honor the new mode immediately`, `11. Evidence loop`,
  `NEEDS-EVIDENCE`, `route the work to the role that owns it`,
  `The Reviewer likewise reasons only` (`test-flow-mode.sh:65-90`);
  `^PEER NAME CONFIRMATION` at line start and `${repoBasename}-<role>`
  (`test-peer-dispatch.sh:52-54,74`). `test-ultra-gate.sh` and
  `test-orchestrator-liveness.sh` grep no directive text.
- **Saves** (r3, measured): **848 B (auto) / 1,340 B (confirm)** per session
  start and per compact of the Orchestrator session — 5.7% / 7.7%. r2's
  "≈ 6,500 / 7,500" was wrong; §9.8 explains.
- **Files**: `hooks/lib-config.mjs`, the directive tests, `docs/comms-protocol.md:164-176`
  (§10 SessionStart injection — update the size it quotes if any), plugin.json,
  marketplace.json:19.

After-text per string. "Before" = the line in `lib-config.mjs` at v0.69.4 (byte
count is the string's). Template placeholders (`${…}`) stay exactly as in the
source.

**Preamble** `:960` (144 B) — unchanged.

**Roles line** `:962` (~470 B). After:
> Roles — dispatch route per role below: peer session via SendMessage, or always a spawned subagent. Legwork (Task-Runner) always spawns or delegates to task-gopher; pass `model` on the Agent call — agent frontmatter is fallback only. Role with a peer target: SendMessage it first when ListAgents shows it running (Ultra-Advisor's peer route gated exactly like its subagent route — item 7), else the subagent. No peer target → always the subagent:

Check: two routes; legwork always spawns/delegates; pass model; frontmatter fallback; ListAgents-running condition; UA gate parity + item 7 ref; fallback; no-peer case.

**PEER NAME CONFIRMATION** `:911-917` (1,930 B, conditional). After:
> PEER NAME CONFIRMATION — a role above marked "peer name not yet confirmed" has `peer:"auto"` never settled for this repo. Resolve ONCE, the first time you need to dispatch that role, before dispatching:
> 1. ListAgents. Exact match on "${repoBasename}-<role>" first (repo-basename convention).
> 2. No match + you know this session's display name (UI, or user told you) → also try "<that name's prefix>-<role>" — some setups name peers off a shared custom prefix, not the repo dir.
> 3. Rank ListAgents output: (a) exact match on expected name, (b) contains expected prefix AND a role-match token ("architect", "reviewer", "implementor", "ultra-advisor"/"advisor"), (c) role token only, (d) prefix only, (e) everything else — same tiers as `/hierarchy init`.
> 4. AskUserQuestion — even an exact match gets this one-time confirmation, never assume silently. Offer: confirm the top candidate (if any); "pick from a list" of up to the top 4 ranked candidates when 2 or more exist; "type in the exact name"; "no peer — always use a subagent for this role".
> 5. Record immediately with the Write tool in the most specific `.claude/agent-hierarchy.json` that already exists (project if present, else user), replacing only that role's object: `peer:"<confirmed-name>"` (keep `dispatch:"peer"`) for a confirmed name; `dispatch:"model"` with `peer` omitted for "no peer". Preserve every other key and role. One line: what you recorded, where.
> 6. Proceed with THIS dispatch on the resolved route. Every later dispatch of this role in this repo uses the recorded value — never ask again unless the user changes it via `/hierarchy` or the config file.

Check: trigger condition; ONCE/first-need/before; six steps with all option strings, ranking tiers (a)–(e), file-selection rule, key edits, preserve-others, one-line confirm, never-again clause.

**PEER BRIEF CONTRACT** `:966-971` (1,792 B). After:
> PEER BRIEF CONTRACT — a peer session is an independent Claude session: unlike a subagent, NOTHING returns its result to you automatically; a peer that finishes goes idle without telling you unless the brief itself obliges it to report. Every SendMessage that tasks a role peer must:
> - Open with the sentinel line `[hierarchy-peer-brief reply-to="sender" task="<short-slug>"]`. reply-to="sender" = the peer replies to the delivery-envelope address: your message arrives wrapped as `<cross-session-message from="...">`; copying that `from` into the reply's `to` is the reliable route (the sender is often NOT in the peer's ListAgents — never rely on that). Explicit `reply-to="<name> [ref]"` only to redirect the report to a third session.
> - Next line: `[hierarchy-msg <request path>]` — the brief lives in the message file (item 12); set its `to_name:` to the peer's session name.
> - Same self-contained brief a subagent would get (spec path, task, constraints) — the peer shares none of your context.
> - End with an explicit report-back order: the exact report expected (same as the role's subagent form); the reply rule restated in prose (copy this message's wrapper `from` into the SendMessage `to`); and plainly: task NOT COMPLETE until that report is sent back via SendMessage — finishing silently strands the caller.
> - No reply and ListAgents shows the peer idle → ping ONCE ("you owe a report on task <slug> — SendMessage it back to the sender"); still silent → dispatch the role's subagent and tell the user the peer stalled.

Check: independence + nothing-returns + idle-silently; sentinel exact; "sender" semantics + wrapper form + copy-from-to-to + not-in-ListAgents warning + third-session redirect; second line + item 12 + to_name; self-contained + no shared context; report-back order's three parts + strands-caller; ping-once wording + fallback + tell user.

**Item 0** `:976` (~2,500 B, `confirm` only). After:
> 0. Handoff gate — user chose per-handoff approval (config handoffs:"confirm"). Before dispatching Ultra-Advisor, Architect, Implementor, or Reviewer — review-loop re-dispatches included — read that role's dispatch line in Roles above. No peer target (subagent-only) → skip ListAgents for it; offer "Dispatch <role> (Recommended)", "Do it inline yourself", "Skip this step". Peer target named → ListAgents first: is that session present? Then AskUserQuestion naming the role, its model, one line on what you hand it. Peer listed → offer "Task peer \"<name>\" via SendMessage (Recommended)", "Dispatch <role> subagent instead", "Do it inline yourself", "Skip this step", in that order. Peer target but not listed → drop the peer option for this dispatch; offer the subagent-only three. Filter peer-vs-subagent options by this session's route (item 13): "peers" → peer option only, no subagent option; "subagents" → subagent option only, no peer option even if listed; "prefer-peers" → both, peer first. This item decides only WHETHER to hand off — the route decides HOW, asked once, not per dispatch. Ultra-Advisor: both routes equally gated by item 7's PreToolUse approval gate (it watches SendMessage to the Ultra-Advisor peer as it watches Agent/Task) — the peer option never skips user approval. Ask per dispatch, not per plan; never re-ask a dispatch already approved. Legwork (Task-Runner / task-gopher) exempt — errands are not handoffs. "Task peer" = SendMessage that peer the same self-contained brief a subagent gets, then await its reply as you would a subagent's completion; the brief follows the PEER BRIEF CONTRACT above — a peer not ordered to report back does the work and goes idle silently. "Do it inline" = you take that role's contract for that step. "Skip" = the step does not happen; say plainly what that leaves undesigned or unverified.

Check: config key; four roles + re-dispatches; read dispatch line; subagent-only branch (skip ListAgents, three labels); peer branch (ListAgents, AskUserQuestion contents, four labels in order); peer-not-listed branch; route filter three cases; WHETHER vs HOW + asked once; UA gate parity + item 7; per dispatch not per plan; never re-ask; legwork exempt; definitions of Task peer / Do it inline / Skip incl. contract ref and undesigned/unverified.

**Item 1** `:979` (~170 B) — unchanged.

**Item 2** `:980` (~560 B). After:
> 2. Scope: the chain governs changes. Analysis, debugging, research → Architect (design reasoning) or Task-Runner (retrieval) alone — no Reviewer without a diff. Never dispatch Architect or Ultra-Advisor when the deliverable is only writing, recording, or persisting something you already know — a memory entry, a status note, a file update with no open design question: no reasoning content → do it yourself, or hand the mechanical write to Task-Runner or Implementor. Architect/Ultra-Advisor = reasoning that produces new judgment, never the write step alone.

Check: chain governs changes; analysis/debug/research routing; no Reviewer without diff; three write-only examples; do-yourself or Task-Runner/Implementor; never write-step-alone.

**Item 3** `:981` (~330 B). After:
> 3. Tiers: trivial (one blind Edit, no verification — typo, config value) → yourself. Determined (request fixes the spec; no design choices left) → Implementor, then Reviewer. Everything else → Architect → spec → Implementor → Reviewer; Ultra-Advisor ahead of the Architect when an item 7 trigger fires.

Check: three tiers with definitions and examples; ordering; UA insertion condition.

**Item 4** `:982` (~260 B). After:
> 4. Spec handoff: one unique absolute spec path — default `${…}/<slug>.md` — dictated in the Architect's prompt; same path to Implementor and Reviewer. Dispatches are self-contained — subagents share no context.

(Keep the existing `${hierDir ? … : …}` expression verbatim.) Check: unique absolute; default path; dictated; same path to both; self-contained.

**Item 5** `:983` (~260 B). After:
> 5. Living spec: Implementor reports a spec gap, or a deviation is agreed → amend the spec file (yourself, or re-dispatch the Architect for design questions) BEFORE the Reviewer runs. The Reviewer always validates against the current spec.

Check: two triggers; who amends; BEFORE Reviewer; current spec.

**Item 6** `:984` (~300 B). After:
> 6. Review loop: Reviewer classifies each finding impl-defect or spec-defect. Impl-defect → Implementor; spec-defect → Architect. Max 2 round-trips; findings still open after that → escalate to Ultra-Advisor, not another loop, then surface its verdict to the user.

Check: classification; routing; Max 2; escalate not loop; surface verdict.

**Item 7** `:985` (~800 B + gate sentences 976 B). After:
> 7. Ultra-Advisor — escalation apex, never a routine step. Reasons and adjudicates; never implements. Dispatch ONLY when: the user says the problem is hard, important, or high-stakes, or asks for a second opinion; the Architect reports low confidence or a fork it could not resolve; the review loop hits item 6's cap; or the change carries outsized blast radius (security, auth, data migration, concurrency, a public interface, anything hard to reverse). Give it the same absolute spec path plus the specific question. Its answer is authoritative: fold it into the spec before the Implementor runs again. Never escalate because a task feels large — size is the Architect's job. ${gateSentences(sessionId)}

`gateSentences` after:
> USER GATE: a PreToolUse hook DENIES the first Ultra-Advisor dispatch of every session — Agent-tool spawn or SendMessage to its named peer — until the user approves. The denial states the exact question to put to them and the exact command that records their answer — follow it verbatim; no improvised wording, no skipped record step. Their answer (allow for this session / ask each time / blocked this session) is session-scoped, covers both routes, resets next session. In "confirm" flow that prompt REPLACES item 0's confirmation for that dispatch: ask once, not twice.
> This session's gate id is "${sessionId}". Plain-words request ("don't use the ultra advisor", "stop asking me about it", "go ahead without asking") → run `node "${GATE_CLI}" set --session "${sessionId}" --choice session|each|off` without waiting for a dispatch; `node "${GATE_CLI}" status --session "${sessionId}"` reports the current answer.

Check (7): apex/never routine; reasons-never-implements; four triggers with all sub-cases; spec path + question; authoritative + fold before Implementor; not-because-large. Check (gate): DENIES first dispatch; both routes; until approval; denial contents; follow verbatim; three answers; session-scoped/both routes/resets; REPLACES item 0; gate id; three plain-words examples; set and status commands verbatim.

**Item 8** `:986` (~200 B). After:
> 8. Task-Runner: prefer `task-gopher:task-gopher`; that agent type unavailable → `ah:task-runner`. task-gopher's on/off toggle controls only its directive, not the agent — delegation works either way.

**Item 9** `:987` (~150 B) — unchanged.

**Item 10** `:988` (~560 B). After:
> 10. Flow control — handoffs are currently "${resolved.handoffs}"${…}. The user owns this switch and may flip it AT ANY TIME, either direction, just by telling you — "ask me before handoffs", "stop asking", or /hierarchy flow auto|confirm. Then: update the "handoffs" key in the most specific agent-hierarchy.json that exists (project if present, else user) with the Write tool, preserving every other key; confirm in one line; honor the new mode immediately for the rest of this session — no restart.

(Keep the `${confirm ? … : …}` parenthetical verbatim.) Check: current value; user owns; any time/either direction; three trigger phrasings; file-selection rule; Write tool; preserve keys; one-line confirm; immediate, no restart.

**Item 11** `:989` (~1,150 B). After:
> 11. Evidence loop — YOU keep the roles in their lanes. The Architect reasons and designs; it never executes — no tests, builds, or experiments, direct or via a runner (Bash is denied to it). (a) Dispatch it with design questions only: never fold "and verify it works" into an Architect prompt. (b) Its report or spec carries NEEDS-EVIDENCE items → route that gruntwork to the Implementor (write/run/measure, at implementation rates; Task-Runner for a pure run-and-report), then re-dispatch the Architect with the results and the same spec path. (c) The Reviewer likewise reasons only: it reads diffs itself (read-only git is its instrument) but MUST delegate every execution — suites, builds, repro scripts — to task-gopher and judge the compact report; its Bash is for inspection, never for running. (d) A role's report shows it did another role's work — an Architect that ran tests, a Reviewer that ran a suite itself, an Implementor that redesigned → do not accept that part: note the overstep, route the work to the role that owns it. Reasoning-tier tokens buy judgment, not gruntwork; enforcing that split is YOUR job, not the roles' goodwill.

Check: (a)–(d) all present with their examples; Bash denied; direct-or-via-runner; implementation rates; Task-Runner run-and-report; same spec path; read-only git; MUST delegate; inspection-never-running; three overstep examples; closing rule.

**Item 12** `:938` (~1,700 B). After:
> 12. MESSAGE FILES — every role dispatch (Agent spawn of architect/implementor/reviewer/ultra-advisor, or a peer brief via SendMessage) carries its brief as a file, not inline prose; a PreToolUse gate denies the dispatch otherwise. Writer: `node "${MSG_CLI}" new --to <role> --from orchestrator --slug <slug> [--to-name <peer-or-agent name>] [--parent <id>] [--reason context|second-opinion|parallel]` (never hand-roll ids or skeletons), then fill EVERY section of the skeleton it prints — request keys [0] tldr [1] goal [2] context [3] constraints [4] files [5] acceptance [6] want_back; `[0] tldr` = one bullet per section, `- [N] key: <≤10-word gist>`. Style: bullets, imperative, no prose, no restating what the reader can see; every constraint / negative / acceptance criterion survives verbatim — brevity is the tie-breaker, never the goal. In-band pointer: the Agent prompt / SendMessage body opens with `[hierarchy-msg <abs request path>]` then ≤3 TL;DR lines (peer briefs keep the [hierarchy-peer-brief ...] sentinel line first). Reader: `grep -n '^## \[' <path>` = the index; Read(offset,limit) only the sections the tldr says matter (whole-file Read fine when small). The role replies `[hierarchy-msg <abs response path>]` + its [1] status bullet; a response file closes the exchange — new work is a new id (`--parent <id>` links it), never an append. Files under ${dirText}/msgs/; `node "${MSG_CLI}" list|index|sweep|roster` (or /hierarchy msgs|peers|sweep). Multiple instances per role are normal — roles are categories; `to_name:`/`from_name:` name the instance.

Check: all four spawn kinds + peer; gate denies; full `new` command with every flag; never hand-roll; fill EVERY section; seven keys; tldr form; style rules incl. verbatim-survival and tie-breaker; pointer form + ≤3 lines + sentinel-first; reader grep + Read(offset,limit) + whole-file allowance; reply form; closes exchange; new id + --parent; never append; files path; CLI verbs + slash forms; instances/categories/to_name/from_name. (This item is already near-terse; ~1,500 B after.)

**Item 13** `:939` (~900 B). After:
> 13. PEER ROSTER + ROUTE — ${dirText}/peers.jsonl is ground truth for which role peers are up, seen, or briefed; after compaction trust the HIERARCHY STATE block over memory. This session's dispatch route is ${routeText} — honor it without re-asking (a PreToolUse gate enforces it, one-shot per role per session, on the roster roles). User changes it in chat ("peers only", "subagents only", "prefer peers"/"peers when free") → record immediately with `${routeCmd}` and confirm in one line. Standing up, reshaping, or tearing down a live Team — create/spawn a Team, spawn or dismiss one member, disband, resync/move — goes through the `ah:agent-team` skill (`Skill(skill:"ah:agent-team")`, or `/agent-team`); editing the roster TEMPLATE — add/edit/remove a role — through `ah:agent-roster`; neither is a raw roster MCP call. A one-off subagent dispatch of a role is ordinary protocol, no skill.

Check: ground-truth file; up/seen/briefed; post-compaction rule; route value; honor without re-asking; gate one-shot per role per session; four chat phrasings; record command + one-line confirm; Team operations list → agent-team skill both invocations; template ops → agent-roster; neither raw MCP; one-off dispatch exemption.

**Item 14** `:940` (~800 B). After:
> 14. ${tierOpen} Do not dispatch Architect or Ultra-Advisor for REASONING when its tier ≤ yours — take that role's contract inline (write the spec at the spec path yourself; adjudicate yourself). Same-or-lower-tier dispatch only for: context — the design is large and belongs out of your window; second-opinion — the user asked, or you want a fresh-context check; parallel — other work runs meanwhile. Put the reason in the request file's reason: field and one tldr line. Ultra-Advisor: escalate only when strictly higher than you; same tier → decide it yourself and say so. Reviewer is exempt — review buys independence, not tier. A PreToolUse gate denies ONCE per role per session when your model is known, the role's tier ≤ yours, and the request file carries no reason:.

`tierOpen` (`:933-936`) unchanged. Check: tier ≤ rule; inline alternatives; three reasons with definitions; reason: field + tldr line; UA strictly-higher; same-tier say so; Reviewer exempt + why; gate's three conditions + ONCE.

### 9.8 r3 ruling — ceilings reset, claims corrected, after-text unchanged

- **What happened.** The Implementor applied §9.5/§9.6 after-text verbatim
  and measured 14,107 / 16,011 (directive, auto / confirm) and 5,038–9,504
  (agent md) against ceilings of 9,500 / 11,500 and 4,850–9,300. All suites
  green; ceiling tests correctly not added. **The defect is the spec's.**
- **Why.** Per-string before→after in `lib-config.mjs`: every item moved
  −5 to −87 B except item 0 (−483, −20%). The r2 after-text was written
  fidelity-first and kept nearly every word; the "≈ 6,500 / 7,500" figure came
  from per-item byte *estimates* written beside it (e.g. item 12 "~1,350",
  measured 1,598; item 11 "~850", measured 1,150; PEER BRIEF CONTRACT
  "~1,050", measured 1,537) that were never checked against the text. Same
  error in §9.5 at ~100 B per bullet. Separately, r2's "current 14.8 KB" for
  the directive was E1's confirm-mode `additionalContext` (which includes the
  ~2.5 KB role lines, the ~0.9 KB HIERARCHY STATE block, and the conditional
  PEER NAME CONFIRMATION), not `buildDirective` text — so the ceiling was
  set against the wrong quantity as well as the wrong estimate.
- **Why not retighten.** The directive is command/flag/label-dense: item 12 is
  a CLI invocation, seven keys, three token forms and a path; item 14 is a
  rule with three enumerated reasons and a three-condition gate. Caveman
  removes articles and filler, and those strings have almost none — item 0,
  the one prose item, is where the register worked. A second pass would buy
  ~1–1.5 KB on a directive the reader pays once per session and per compact,
  against the fidelity risk the user named as the hard requirement. Not
  worth it; ruled (b).
- **Ruling.** Ceilings reset (§9.5, §9.6) to measured + ~1%, each still below
  HEAD so the fails-without property holds. After-text unchanged — the tree
  state is the spec. Savings claims corrected in §9.5, §9.6, §4 (r1's cut 5
  and cut 8 rows now stand corrected by these sections). Implementor adds the
  two ceiling tests at the r3 numbers; nothing else changes.
- **Corrected ranking.** Cut 8's real yield (0.8–1.3 KB per start/compact)
  drops it below cut 3 (2,161 B per non-authoring spawn) and near cut 5. The
  cuts that carry this spec are 1 and 4 (10.4 KB per dispatch / per peer
  start+compact; 2 KB per peer message) and 3. That was true in r1's table and
  is unchanged by r3; only the two text cuts were overstated.

### 9.7 Dropped in r2
- **Cut 6** — E1: open-exchange listing is 0 B. Nothing to cap.
- **Cut 7** — not trivial: 12 readers across 6 files plus the frontmatter
  parser's absent-vs-null behaviour (E6). ~90 tokens per dispatch does not buy
  that. Unchanged from r1's "rider only" — and there is no longer a cut 6 to
  ride on.

## 10. Commit order and version bumps

Three plugins, no cross-dependency between the changes — each commit stands
alone and each is one plugin. Order by bytes saved per dispatch. Every commit
bumps its `plugin.json` **and** the root `.claude-plugin/marketplace.json`
(memory: both or neither).

| # | plugin | cuts | version | marketplace.json line |
|---|---|---|---|---|
| 1 | task-gopher | 1, 4 | 0.15.1 → **0.16.0** (behaviour change: ah targets/sessions exempt) | :98 |
| 2 | comment-discipline | 3 | 0.3.2 → **0.4.0** (new non-authoring set members) | :45 |
| 3 | agent-hierarchy | 8, 5, 2 | 0.69.4 → **0.70.0** (directive + agent md text; new echo cap) | :19 |

Within commit 3: cut 8 first (largest, one file), then cut 5 (six files), then
cut 2 (two hooks + tests). One commit is fine if the suite is green; three are
fine if the Implementor prefers bisectable steps — no requirement either way.

Verification per commit: the plugin's own tests (`bash <plugin>/tests/test-*.sh`,
no run-all — each exits 0 iff green) before and after; the new fails-without
case in each; for commit 3 the full `agent-hierarchy/tests/` set (63 files),
since directive and agent-md literals are asserted across many of them.

### 10.1 Open user decisions (r2)
- None blocking. Two defaults taken, reversible in one line each: no delegation
  bullet in `implementor.md` (9.1); `ah:architect` in comment-discipline's
  non-authoring set (9.3).
- Cut 2 threshold set to 2,000 B by ruling (9.2), not 600 — the user may prefer
  stricter; the tradeoff is stated there.

### 10.2 Confidence (r2)
- **High** on cuts 1, 3, 4-SessionStart: one-line set changes on mechanisms
  already in place, read in code.
- **High** on the cut 8 after-text preserving every clause — each item carries
  its checklist; the Reviewer can verify mechanically.
- **Medium** on cut 5 variants (9.5.1) — the base bullets are covered verbatim;
  the five variant texts were not in hand when this section was written.
- **Medium** on cut 4-UPS pending E7.
- No Ultra-Advisor needed; nothing here is hard to reverse (text and set
  membership, all under test).
