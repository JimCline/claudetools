# 0017 — Roster tool collapse

Status: implemented and certified; amended 2026-08-26 with two doc-only defects
found in review (§11).
Follow-up to 0016 (roster MCP coverage). Pure `mcp/server.mjs` + SKILL.md + tests
change — no `roster.mjs` CLI change (§6).

## 1. Goal

0016 shipped 20 registered tools (4 `msg_*` + 16 `roster_*`). Every tool's name,
description, and inputSchema sits in the context of every session connected to the
`ah` server, every turn (0016 §2). Reduce that tax modestly, without giving up
harness-enforced schema validation.

Two collapses, using the `mode`-enum pattern 0016 already shipped for
`roster_create` (server.mjs:218–235) and `roster_disband` (255–266):

1. `roster_init` + `roster_add` + `roster_edit` + `roster_remove` →
   **`roster_member(action)`**
2. `roster_layout` + `roster_alias` → **`roster_config(target)`**

Net: 20 tools → 16.

**Rejected, do not revisit:** a single generic dispatcher plus a separate help/usage
tool. It surrenders harness-enforced schema validation on every call. Decided
against by the user.

**Untouched, deliberately:** `roster_show`, `roster_teams`, `roster_history`,
`roster_create`, `roster_layout_splits`, `roster_disband`, `roster_disband_close`,
`roster_resync`, `roster_move`, `roster_spawn_one`. The destructive/gated three
(`roster_disband_close`, `roster_move`, `roster_spawn_one`) stay distinct for
0016 §4.5's reasons — independent permission-gateability and independent audit
visibility. `mcp__ah__roster_disband_close` in particular is matched **by exact
name** by the §4.5.1 ask hook and by `tests/test-disband-close-gate.sh`; collapsing
it would break the one user-enforced gate in the system. Not re-litigated here.

## 2. What this costs, stated plainly

The generic dispatcher was rejected for losing schema validation. This change loses
a *little* of the same thing, and it should not be a surprise later.

**Kept:** every field's `type`, every `enum`, and the `cwd` requirement — all still
enforced by the harness before the call reaches `callTool`.

**Lost:** the per-tool static `required` arrays of the six collapsed tools. JSON
Schema `required` is static, so "`level` and `route` are required when
`action: "init"`" cannot be expressed without `oneOf`/`if-then-else`. Those
requirements move from the schema into `callTool`.

This is the same trade 0016 already made for `roster_create` (`verified` is required
only for `mode: "commit"`, checked at server.mjs:521–523, not in the schema). It is
a real reduction in harness-side validation, bounded to requiredness, and it buys
four fewer tool schemas. If that trade is unacceptable for a given field, the answer
is to keep that tool separate — not to add conditional JSON Schema.

**Do not use `oneOf` / `allOf` / `if-then-else`** to recover per-action
requiredness. Reasons: it diverges from the shipped `roster_create` pattern; the
harness's handling of conditional schemas is unverified here; and a `callTool` check
produces a better error message than a schema rejection. Consistency with 0016 wins.

### 2.1 Note on collapse 2

Recorded, not re-litigated — the user has decided. `roster_layout` + `roster_alias`
saves exactly one tool by merging two semantically unrelated verbs (pane layout;
repo team-name alias) under a deliberately vague name. Collapse 1 is a clear win —
those four are one CRUD family over roster members. Collapse 2 is marginal. If the
tool count is later found acceptable at 17, dropping collapse 2 and keeping
`roster_layout`/`roster_alias` as-is costs one schema and reads better. Proceeding
as specified.

## 3. `roster_member`

Replaces `roster_init` (128–140), `roster_add` (142–157), `roster_edit` (159–175),
`roster_remove` (177–188).

```js
{
  name: "roster_member",
  description: "Init a roster level, or add, edit, or remove a roster member, via roster.mjs.",
  inputSchema: {
    type: "object",
    properties: {
      cwd: cwdSchema,
      action: { type: "string", enum: ["init", "add", "edit", "remove"] },
      level: levelSchema,
      member: { type: "string", description: "The member's derived name. Required with action: edit, remove." },
      role: { type: "string", description: "Required with action: add." },
      model: { type: "string", description: "With action: add, edit." },
      effort: { type: "string", description: "With action: add, edit." },
      route: { type: "string", enum: ["peer", "subagent"], description: "Required with action: init." },
      auto_mode: { type: "string", description: "With action: add, edit." },
      layout: { type: "string", enum: ["auto", "columns", "grid"], description: "With action: init." },
    },
    required: ["cwd", "action"],
  },
}
```

Field applicability, and which the CLI treats as required (roster.mjs handlers:
init 771–786, add 788–812, edit 814–839, remove 841–854):

| Field | init | add | edit | remove |
|---|---|---|---|---|
| `level` | **required** (772) | optional | optional | optional |
| `route` | **required** (773) | optional | optional | — |
| `layout` | optional | — | — | — |
| `role` | — | **required** (793) | optional | — |
| `member` | — | — | **required** (815) | **required** (842) |
| `model`, `effort`, `auto_mode` | — | optional | optional | — |

No enum conflicts across the merge: `route` is `peer|subagent` in init/add/edit
alike, and `layout` is `auto|columns|grid` in init and in the standalone layout verb.
The union is consistent; no field means two different things depending on `action`.

### 3.1 Router

Mirror `roster_create`'s structure (server.mjs:515–537) exactly: validate the enum,
validate action-specific requirements, then build argv with the existing `pushArg`
(393–396) / `pushFlag` (399–401). The argv construction per action is a verbatim
lift of the four existing cases (461–498) — the CLI subcommand name equals the
action name in all four, so `args = [action]` is the whole dispatch.

```js
case "roster_member": {
  const action = args_in.action;
  if (!["init", "add", "edit", "remove"].includes(action)) {
    return err(`roster_member: "action" must be one of init, add, edit, remove, got ${JSON.stringify(action)}`);
  }
  if (action === "init") {
    if (!args_in.level) return err('roster_member: action "init" requires "level".');
    if (!args_in.route) return err('roster_member: action "init" requires "route".');
  }
  if (action === "add" && !args_in.role) return err('roster_member: action "add" requires "role".');
  if ((action === "edit" || action === "remove") && !args_in.member) {
    return err(`roster_member: action "${action}" requires "member".`);
  }

  const args = [action];
  pushArg(args, "level", args_in.level);
  if (action === "init") {
    pushArg(args, "route", args_in.route);
    pushArg(args, "layout", args_in.layout);
  }
  if (action === "add") pushArg(args, "role", args_in.role);
  if (action === "edit" || action === "remove") pushArg(args, "member", args_in.member);
  if (action === "edit") pushArg(args, "role", args_in.role);
  if (action === "add" || action === "edit") {
    pushArg(args, "model", args_in.model);
    pushArg(args, "effort", args_in.effort);
    pushArg(args, "route", args_in.route);
    pushArg(args, "auto-mode", args_in.auto_mode);
  }
  pushArg(args, "cwd", cwd);
  return execCli(ROSTER_CLI, args);
}
```

**On argv order — CORRECTED (§11.2).** An earlier revision required the argv to
match the pre-collapse cases flag-for-flag, and justified it by claiming §7's
equivalence tests would catch a divergence. They would not: those tests compare CLI
*results*, and `roster.mjs` parses with `parseArgs`, which is order-insensitive.

What is actually true: **for these six verbs every input is a `--flag value` pair
with no positional argument, so argv order is functionally irrelevant.** Matching
the original order is worth doing for reviewability — a reviewer diffing the lift
against 461–514 can see at a glance that nothing was dropped — but it is a style
preference, not a correctness requirement, and no test enforces it. What the tests
do enforce is that the right flags with the right values reach the CLI.

The requirement that *is* load-bearing: **no flag may be dropped or misnamed** in
the lift (note `auto-mode` on the wire vs `auto_mode` in the schema). Verify against
461–514 by reading, and rely on §7's equivalence cases to catch a dropped flag —
which they do, because a missing flag changes the result.

`err(...)` denotes the existing inline error-result shape used at 519–523 — if a
one-line helper for it does not already exist, adding one is fine (it is used four
times by `roster_create`/`roster_disband` today and gains four more uses here).
That is extraction of existing duplication, not a new dispatch mechanism. Skip it if
it complicates the diff.

## 4. `roster_config`

Replaces `roster_layout` (190–201) and `roster_alias` (203–216).

```js
{
  name: "roster_config",
  description: "Show or set a roster level's pane layout, or the repo's team-name alias, via roster.mjs.",
  inputSchema: {
    type: "object",
    properties: {
      cwd: cwdSchema,
      target: { type: "string", enum: ["layout", "alias"] },
      level: levelSchema,
      layout: { type: "string", enum: ["auto", "columns", "grid"], description: "With target: layout. Omit to read." },
      set: { type: "string", description: "New alias. With target: alias." },
      clear: { type: "boolean", description: "With target: alias." },
      team: teamSchema,
    },
    required: ["cwd", "target"],
  },
}
```

Both verbs are read-when-no-argument, so nothing beyond `target` is required. The
per-target fields are disjoint (`layout` vs `set`/`clear`/`team`), so no field is
ambiguous.

`target` has **no default.** `roster_disband` defaults `mode` to `"plan"` because
bare `disband` is the documented plan call; there is no comparable "obvious" default
between two unrelated verbs, and silently picking one would make a typo'd call do
the wrong thing.

### 4.1 Router

```js
case "roster_config": {
  const target = args_in.target;
  if (target !== "layout" && target !== "alias") {
    return err(`roster_config: "target" must be one of layout, alias, got ${JSON.stringify(target)}`);
  }
  const args = [target];
  pushArg(args, "level", args_in.level);
  if (target === "layout") {
    pushArg(args, "layout", args_in.layout);
  } else {
    pushArg(args, "set", args_in.set);
    pushFlag(args, "clear", args_in.clear);
    pushArg(args, "team", args_in.team);
  }
  pushArg(args, "cwd", cwd);
  return execCli(ROSTER_CLI, args);
}
```

Lifted from 499–505 and 506–514. `team` is passed only for `alias`, matching the
pre-collapse `roster_layout`, which never sent it.

0011 §7.4's refusal (`alias --set` fails when a team scope is active) lives in
`roster.mjs` and is inherited unchanged.

## 5. SKILL.md changes

From the evidence, `skills/agent-roster/SKILL.md` names MCP tools in its command
surface and separately shows some CLI invocations. Only the **tool names** change.

**Must change** — command-surface lines naming a collapsed tool:

| Line | Currently names | Becomes |
|---|---|---|
| 67 | `mcp__ah__roster_init` | `mcp__ah__roster_member`, `action: "init"` |
| 68 | `mcp__ah__roster_add` | `mcp__ah__roster_member`, `action: "add"` |
| 69 | `mcp__ah__roster_edit` | `mcp__ah__roster_member`, `action: "edit"` |
| 70 | `mcp__ah__roster_remove` | `mcp__ah__roster_member`, `action: "remove"` |
| 71 | `mcp__ah__roster_layout` | `mcp__ah__roster_config`, `target: "layout"` |
| 99 | `mcp__ah__roster_alias` | `mcp__ah__roster_config`, `target: "alias"` |

Lines 66 and 72 (`roster_show`, `roster_create`) and line 79 (`roster_disband`) are
unchanged — they follow the same annotation style, so match it rather than inventing
a new one. Consider collapsing 67–70 into one entry describing `roster_member` with
its four actions, since four adjacent lines now name one tool; keep the per-verb
flag documentation either way.

**Must NOT change** — lines 153, 159, 175, 205 invoke `roster.mjs init|add|layout`
by CLI verb. The CLI is untouched (§6), so these stay correct as written.

**Check while in the file** (not a required change, report if wrong): 0016 §7
converted SKILL.md's invocation lines to tool calls with a single 1:1 Bash-fallback
line. Lines 153/159/205 still show Bash form. Either 0016's edit deliberately left
them (they may sit inside prose where the CLI form is the point) or it missed them.
Determine which and report — do not convert them as a side effect of this spec.

## 6. `roster.mjs` — zero changes

Confirmed from the router evidence, not assumed: all six pre-collapse cases
(461–514) are pure `pushArg`/`pushFlag` argv construction over the same script, and
the CLI subcommand name equals the tool's verb in every case (`init`, `add`, `edit`,
`remove`, `layout`, `alias`). Collapsing changes only which `case` label builds the
argv; the argv itself is equivalent.

No CLI behaviour, flag, exit code, or output shape changes. Every existing CLI-level
test (e.g. `tests/test-team-alias.sh`, which drives `run_roster alias …` directly)
is unaffected.

If implementation reveals any verb needing a `roster.mjs` change, **stop and report**
— that would mean §3 or §4 mis-modelled the flag surface, and it is a spec defect,
not something to patch in the CLI.

## 7. Test impact

Small and localized. From the grep, the only test referencing the six by *tool* name
is the registered-name list.

**Must change:**

- `tests/test-mcp-server.sh:116–118` — the expected tool-name array. Remove
  `roster_init`, `roster_add`, `roster_edit`, `roster_remove`, `roster_layout`,
  `roster_alias`; add `roster_member`, `roster_config`. Keep the list sorted as it
  is now. This is a restructure of one array, not a rename sweep.

**Must add** (`tests/test-mcp-server.sh`, alongside the existing `callTool` refusal
block at 284–294, which is the model to copy):

- `roster_member` with a bad/missing `action` → refused.
- `roster_member` `action: "init"` without `level`, and without `route` → refused,
  each naming the missing field.
- `roster_member` `action: "add"` without `role` → refused.
- `roster_member` `action: "edit"` and `action: "remove"` without `member` → refused.
- `roster_config` with a bad/missing `target` → refused.
- **Result equivalence, per action/target (6 cases).** For each, assert the collapsed
  tool produces the same result as a direct `node roster.mjs <verb> …` run with the
  same inputs, matching how 0016 §10 framed its equivalence assertions. These are
  the tests that catch a dropped or misnamed flag in the §3.1/§4.1 lift. They do
  **not** check argv ordering — see §3.1 and §11.2.

"Refused" above means what the 284–294 block asserts: `isError` plus the expected
message. See §9 for what that does and does not prove.

**Untouched:**

- `tests/test-disband-close-gate.sh` — names `mcp__ah__roster_disband_close` and
  `mcp__ah__roster_disband` explicitly; neither is collapsed. Its "does NOT fire on
  other `mcp__ah__*` tools" assertion (line 50–52) remains valid.
- `tests/test-team-alias.sh` — CLI-level (`run_roster alias|init|add`), unaffected
  by §6.
- `tests/test-roster-disband-close.sh`, `test-roster-move-guard.sh`,
  `test-roster-global-gate.sh`, and every other CLI-level roster test.
- The rest of `test-mcp-server.sh`, including the `roster_create` `verified`
  round-trip (407–424) and the refusal block's existing cases.

## 8. Files to change

- `mcp/server.mjs` — remove six registrations (128–216) and six router cases
  (461–514); add two registrations and two router cases; optionally extract the
  `err(...)` helper (§3.1).
- `skills/agent-roster/SKILL.md` — the six lines in §5's table.
- `tests/test-mcp-server.sh` — the name array plus the new cases in §7.
- `plugin.json` **and** root `marketplace.json` — version bump. Both (0011 §14).

## 9. Verification

- Registered tool list is exactly 16: the 4 `msg_*`, the 10 untouched `roster_*`,
  plus `roster_member` and `roster_config`. None of the six old names resolves.
- Each of the 6 action/target paths produces the same result as the equivalent
  direct CLI invocation (§7).
- Every per-action requiredness check refuses with `isError` and a message naming
  the missing field.
- Schema-level validation still bites: a bad `route`, `layout`, or `level` enum
  value is rejected, and a call with no `cwd` is rejected, without reaching the
  router.
- `mcp__ah__roster_disband_close` still resolves and is still matched by the §4.5.1
  ask hook — `tests/test-disband-close-gate.sh` green, unmodified.
- Baseline: full existing test suite green, with only the §7 changes applied.

### 9.1 What the refusal tests do not prove — CORRECTED (§11.1)

An earlier revision required these tests to "assert the CLI was not invoked". They
do not, and neither does the 284–294 block they are modelled on: both assert
`isError` plus a message substring. The implementation faithfully copied the model;
the spec's description of the model was wrong.

So the property "refused **before** invoking the CLI" is asserted nowhere. For
`roster_member` / `roster_config` that is purely an efficiency question and does not
matter. It matters more for `roster_disband_close`, where 0016 §4.5's `confirm`
pre-check is layer 2 of a four-layer defence and a leak past it would be a real (if
non-exploitable) gap — layer 3, the CLI's own `--confirm` / `--plan-token` checks,
still refuses, so no close can execute. **Low severity, recorded rather than
urgent**, and it is 0016's coverage gap, not 0017's.

Two optional improvements, neither required to certify this spec — the reviewer's
suggestion first:

1. **Tighten both blocks to match the router's full literal message** rather than a
   substring. Cheap, and it pins the exact refusal rather than a prefix of it.
2. **Actually assert non-invocation** for `roster_disband_close` specifically, if a
   cheap hook exists (a spy on `execCli`, or a sentinel `cwd` whose CLI invocation
   would be observable). Do not build machinery for it; if it is not cheap, leave
   the gap recorded here.

## 10. Open questions

None blocking. §2.1 records that collapse 2 is marginal value and would be the first
thing to drop if the shape is revisited; the user has decided to proceed.

No NEEDS-EVIDENCE items: §6's zero-CLI-change claim is confirmed from the router
source rather than inferred, and the test surface was enumerated by grep rather than
estimated.

## 11. Amendment log

Both entries are the same failure mode: the spec credited a test with proving more
than it does. That is the more dangerous direction of documentation error, because
it makes an unverified property read as verified — worth noting as a pattern, not
just fixing the two instances.

### 11.1 §9 mis-described the refusal tests (doc-only)

§9 required PRECHECK-style tests to "assert the CLI was not invoked". The 284–294
block it pointed at as the model asserts only `isError` plus a message substring.
The implementor copied the model correctly; the spec described it wrongly.

Corrected in §9, with the real coverage gap recorded in new §9.1 — including that
the gap is 0016's rather than 0017's, that it is non-exploitable because the CLI's
own checks still refuse, and two optional tightenings (the reviewer's full-literal-
message suggestion, and asserting non-invocation for `roster_disband_close` only if
cheap).

### 11.2 §3.1 mis-credited the equivalence tests (doc-only)

§3.1 required flag-for-flag argv ordering and justified it by saying §7's
equivalence tests would catch divergence. They compare CLI *results* via
`parseArgs`, which is order-insensitive, so they cannot. Order correctness was
verified by manual review.

Corrected in §3.1, and the requirement softened to match reality: for these six
verbs every input is a `--flag value` pair with no positional argument, so argv
order is functionally irrelevant. Matching the original order stays worthwhile for
reviewability but is a style preference, not correctness. The load-bearing
requirement — no flag dropped or misnamed, watching `auto-mode` vs `auto_mode` — is
now stated as such, and the equivalence tests do genuinely catch that, because a
missing flag changes the result.
