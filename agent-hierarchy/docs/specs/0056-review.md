# 0056 review — r3.5 diff, feat/0056-user-defined-roles (uncommitted)

Reviewer: claudetools-reviewer. Verdict: **CHANGES REQUIRED** — 0 blocking, 6 should-fix, 10 nits.
r3.6 (roleFromName/hierarchyNameParts, C18) held pending a signal.

## Verified

- **Suite** (re-run by the Reviewer's runner): 79 test-*.sh files, 2550 PASS / 0 FAIL; all 17
  SUMMARY lines report 0 failed; check-gate-name-agreement.mjs exit 0. custom-roles 99/0,
  role-contract 64/0, roster-doctor 23/0. No stray tmux. The count differs from the Implementor's
  2563 because different markers were counted and the tree was being edited for r3.6 during the
  run. Re-run after r3.6 lands.
- **I1 goldens:** HEAD was extracted with `git archive HEAD agent-hierarchy` and rendered with the
  current render.sh. HEAD render = golden = working-tree render on all 33 files, 0-line diffs. The
  golden derived.json key set equals the HEAD render's key set. So the goldens do come from HEAD
  code, and I1 holds for every rendered surface. Caveat: the gate goldens cover the route and msg
  gates only. The ultra, conduit and response gates rest on unchanged existing suites.
- **Doctor:** not weakened. The config row adds a warn on excluded or unavailable roles
  (roster.mjs:525-535), and the team row is ok only when `live && !orphans`
  (roster.mjs:545-555). Both only add warn paths; no existing path is relaxed.
- **Security:** the agent charset is enforced at read (checkCustomRow, builtinAgentError), at write
  (roleSet) and at the seam (spawnShape AGENT_REF_RE, roster.mjs:1047). description and routes:
  one line, ≤160, no `\n\r` or backtick, at read and write. label uses LABEL_RE and names use
  ROLE_NAME_RE. The scaffold writes the description JSON-quoted, so the YAML stays valid.
  locateAgentFile builds paths only from a validated ref, with no `/`. One gap: S6.
- **Registry consumers:** every §1.6 site is converted except S2 and N6.
- **Prose:** all contracts/*.md clauses from §1.17 are present, with `~` de-duplication against the
  notice correct. agent-role SKILL matches §1.15c: remove-file is advisory only, and a file is
  deleted only via the remove opt-in, default keep. The pipeline skill matches §1.14g, apart from
  N3 and N7.
- **Coverage:** see S4 and N8.

## Findings

| ID | Severity | Class | Where | What's wrong | What should happen |
|---|---|---|---|---|---|
| S1 | should-fix | impl-defect | lib-config.mjs buildRoleSessionNotice (`viaAgentFile`); subagentstart-cli-root.mjs:26-31 | Override detection keys on the config entry, not on the session's actual agent_type. A peer or subagent running as `ah:architect` while roles.architect.agent is set gets the injected custom contract and a notice saying "your agent file (`my-architect`) governs". That happens under the G2 spawn revert, under the SessionStart revert when the override fails, and on any direct ah:architect dispatch. It violates I5 (shipped ah:* are never injected) and misstates identity. | Inject the contract and name the agent file only when agent_type === roleAgent(role, entry), i.e. not `ah:<role>`. Otherwise keep the byte-identical built-in notice; the design routing block may still apply. Add notice and SubagentStart assertions to C16. |
| S2 | should-fix | impl-defect | lib-config.mjs:~1999 statusReport onMissingTag | Still uses PEER_ELIGIBLE_ROLES, so a custom chain-class roster member is shown as "(inert: role is not peer-eligible)". A leftover built-in-only list. | Use `classProp(m.role, resolved, "chain")`. |
| S3 | should-fix | impl-defect | lib-config.mjs parseAgentFrontmatter (description branch); validateAgentContract parseErrors loop | A description written as a valid YAML multi-line plain scalar (`description:` then an indented line), or one starting with `[` or `{`, is pushed into parseErrors. That raises an unparseable-field ERROR, so a valid agent is refused or marked unavailable. §1.16a limits unparseable-field to tools, disallowedTools, model and name. | Never record description in parseErrors. Fold indented continuation lines as a plain scalar, or treat the field as absent, which gives the no-description warning. |
| S4 | should-fix | impl-defect | tests/test-custom-roles.sh:155-166 (T8) | The end-to-end branch for the response gate is dead code: lib-peer.mjs exports no `armPending`, so the test always falls back to asserting the class property. Spec T8 requires the gate itself to apply to a ui-implementor session. | Arm the pending obligation the real way (appendPeerRecord, or whatever pendingFor reads), assert the deny, and delete the fallback branch. |
| S5 | should-fix | impl-defect | contracts/common.md (903 B); tests | §1.17 caps common.md at ≤900 B and each class file at ≤450 B, marked "(tested)". common.md is 903 B, and no test checks the per-file caps; T16 checks only the rendered ≤1350. | Trim common.md by ≥3 B and add a check for each file's cap. |
| S6 | should-fix | impl-defect | roster.mjs:1047 spawnShape | The agent comes from `member.agent` whenever it is present. For a shipped built-in, spawnValidation returns null, so a stray `agent` key on a roster, team or history member launches that agent unvalidated. There is no member-key allowlist. That bypasses the §1.7 revalidation and the one-agent-per-role rule. The charset check still holds, so this is not an injection. | Pass the validated agent to spawnShape as its own argument, and ignore member.agent. |
| N1 | nit | impl-defect | contracts/common.md:1; roster.mjs scaffoldText | "a implement-class" / "a advise-class". | Pick the article (a/an), or reword to "a role of class <class>". |
| N2 | nit | impl-defect | skills/agent-role/SKILL.md | The skill never names the `role set` flags (--scaffold repo\|user, --routes, --description, --level, --model), so steps 5 and 10 leave the model to guess them. | Add one line listing the flags, or point to docs/cli-tools.md. |
| N3 | nit | impl-defect | autonomous-pipeline SKILL.md, "Rework never preempts" | Still says "when the Implementor next comes free". | Say "the item's implementer". |
| N4 | nit | impl-defect | roster.mjs roleRemove, built-in branch | Deleting `agent` can leave a `{}` row. Under whole-row precedence that row still shadows a wider-level row for the built-in. | Delete the role key when the row becomes empty. |
| N5 | nit | spec-defect | spec §1.15c remove step 3; SKILL remove | The opt-in delete has no guard for a plugin agent's file, or for a user-level file that may be live in other repos. That second case is exactly why remove-file is advisory. | Offer the delete only for bare repo-level files. Warn before deleting a user-level file. Never delete a plugin file. |
| N6 | nit | spec-defect | spec §1.6 table | The table omits the tier-rule prose sites: lib-config.mjs:1824 roleTierText (directive items 12-14) and lib-hier.mjs:1028. Both name only Architect and Ultra-Advisor, so custom design and advise roles are tier-gated with no mention in the directive. The gate's deny text explains it. | Add these sites to §1.6, or accept the gap. |
| N7 | nit | spec-defect | spec §1.14g | The pipeline routes only Implement and Review to alternatives. Design and Escalate alternatives (§1.14a) are never chosen in /ah:pipeline, because the skill overrides the directive per item 9. | Rule whether design alternatives route inside the pipeline. |
| N8 | nit | impl-defect (coverage) | test-role-contract.sh:139-140 (C10) | Per-member refusal is proven at `create --plan`, and createSpawn copies `validation` into the entry (roster.mjs:~2486). The partial result of `create --spawn` itself is never exercised, even in the sandbox. Adequate but thin. | Add one sandboxed `create --spawn` with a fake transport, asserting partial. |
| N9 | nit | spec-defect | spec §1.17 / §1.14a vs I7 | The SubagentStart routing block (subagentstart-cli-root.mjs:30) lists alternatives without filtering for availability, because that hook cannot read agent files. The peer notice does filter. It self-heals via §1.14c rule 2. | State in the spec that the subagent route's block is unfiltered. |
| N10 | nit | impl-defect | docs/specs/0056-evidence.md | The T1 "show it failing once" paste required by §4 is missing. T1 is a `diff -r`, so the risk is low. | Paste the failing run. |

**Known open risk (substring names):** no further fallout seen outside the held functions.

---

# Pass 2 — r3.7 diff (r3.6 name parsing + all fixes)

Verdict: **PASS**. No new findings; every pass-1 row is closed.

- **Suite** (Reviewer's runner): 2567 PASS / 0 FAIL, every file exit 0; check-gate-name-agreement exit 0.
  custom-roles 109/0 and role-contract 71/0: the pass-1 total plus the 17 new checks. The
  Implementor's 2584 is a marker-count difference; the fail count is 0 either way.
- **I1:** HEAD (git archive) rendered with the current render.sh = golden = working tree, on all 33 files.
- **Flake:** test-roster-agent-kind ran 5/5 green at 121/0. It did not reproduce, and no tmux or
  herdr process was left alive.
- **r3.6:** customRoleFromSuffix is pass 1 and returns only a custom winner; roleFromName and
  hierarchyNameParts then fall back to the unchanged built-in scans. With zero custom roles the
  moved hierarchyNameParts is line-for-line the HEAD roster.mjs logic (same ordinal regex, same
  HIERARCHY_NAME_ROLES order, same empty-prefix null), and roster.mjs only wraps it with
  registry(). No behaviour change.
- **T10 alias edit is legitimate.** Under suffix anchoring, alias `ui` gives the peer name
  `ui-implementor`, whose longest suffix match is the built-in, so it truly no longer collides;
  the test now asserts that too. `team-ui` against `ui-reviewer` (`team-ui-reviewer`) is still a
  real collision, and `role set` still refuses it. Coverage kept, not bent.
- **Pass-1 rows, all fixed:**
  - S1: notice and SubagentStart are keyed on agent_type === roleAgent and not `ah:`; C16 asserts both sides.
  - S2: statusReport uses classProp chain.
  - S3: description is never a parse error; multi-line plain scalars are folded.
  - S4: T8 now runs end to end via appendPeerRecord.
  - S5: common.md is 899 B, and per-file caps are tested at test-custom-roles.sh:306.
  - S6: spawnShape takes only the validated agent; member.agent is ignored.
  - N1: wording is now "an agent-hierarchy role of class".
  - N2: the flags are listed in the skill.
  - N3: fixed.
  - N4: an emptied row is deleted.
  - N8: a sandboxed create --spawn asserts partial.
  - N10: the failing T1 run is pasted in evidence.
- **r3.7 rulings, all built as ruled:**
  - N5: the skill's remove step 3 is keyed repo/user/plugin/override, default keep.
  - N6: customTierText; the built-in text is unchanged when there are no tier-class custom roles.
    The lib-hier tier line's availabilityView runs only via buildStateBlock, which only
    sessionstart calls, so I7 holds.
  - N7: the pipeline routes Design and Escalate with the §1.14c precedence.
  - The S1 clarification in §1.17 matches the code.
