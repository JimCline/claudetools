# Bug spec: output-discipline blocks commands whose *string data* matches command patterns

**Component:** `output-discipline/hooks/pretooluse-bash.mjs`
**Severity:** medium — blocks legitimate commands; the deny message misdiagnoses the problem, sending the agent on a wrong-workaround detour
**Found:** 2026-07-24, during a real session (git commits in the tower-defense repo)

## Summary

The PreToolUse gate tests its `STREAMING` / `LONG_RUNNING` / `NOISY` regexes
against the **raw command string**, which includes heredoc bodies, quoted
arguments, and command substitutions. Prose inside that data — a git commit
message, a Python string literal, an echoed sentence — can match a pattern
intended for executables, and the command is denied.

## Observed failures (real session)

Both of these were denied with the "streams output indefinitely" message:

1. A `git commit -m "$(cat <<'EOF' … EOF)"` whose commit message contained
   the phrase **"diagonal bottom-to-top wipe reveal"**.
2. A `python3 - <<'EOF' … EOF` script whose embedded doc text contained
   **"bottom-to-top"**.

Neither command streams anything; both are one-shot and exit immediately.

A third, self-demonstrating case: a `node -e '…'` one-liner written to *test*
this bug was itself denied, because its string literals contain the trigger
patterns. Any command that quotes or documents these patterns cannot run.

Verified against the hook's exact regex list: both real blocked commands
match only `/\btop\b|\bhtop\b/`, via the substring `bottom-to-top`; and the
lookbehind variant `(?<![-\w])top\b` rejects `bottom-to-top` while still
matching a bare `top` command.

## Root cause

In the `STREAMING` list:

```js
/\btop\b|\bhtop\b/,
```

`\b` treats the hyphen as a word boundary, so the substring `bottom-to-top`
matches `\btop\b`. The match is performed against the whole command string
(`matches(STREAMING, cmd)`), so data smuggles in the trigger word.

`top` is only the instance that fired. The same class of false positive
exists for any data containing e.g.:

- `less` (`/\bless\b/`) — "the lesson", quoted filenames, `--less-verbose`? (no — but literal word "less" in a commit message, yes)
- `watch <word>` (`/\bwatch\s+/`) — "watch the sequence" in any quoted text
- `--follow`, `--watch` (`/--follow\b/`, `/--watch\b/`) — in quoted docs about CLI flags
- `make`, `top`, etc. in the `NOISY` list (`/\b(make|cmake|ninja)\b/` — a
  commit message containing "make" already forces the capture-to-file dance)

Any hook that greps prose-bearing commands (git commits, doc-writing
scripts, `echo`) will keep hitting this.

## Why it's worse than a plain block

The deny text asserts the command "streams output indefinitely" and says
"Do not retry this command as-is." The agent believes it, invents a wrong
theory (e.g. "the hook dislikes heredocs"), and switches to workarounds
(`git commit -F msgfile`) — noise and confusion instead of a 2-second
commit. A false positive here costs several turns, not one.

## Suggested fix

Strip data regions from the command string before pattern matching:

1. **Heredoc bodies**: remove everything between `<<[-~]?['"]?WORD['"]?` and
   the terminating `WORD` line.
2. **Quoted strings**: remove the contents of single- and double-quoted
   spans (keep the quotes so structure survives).
3. Run the existing regexes against the stripped string only.

Sketch:

```js
function commandSkeleton(cmd) {
  let s = cmd;
  // heredoc bodies (handles <<EOF, <<-EOF, <<'EOF', <<"EOF")
  s = s.replace(
    /<<-?\s*(['"]?)(\w+)\1[\s\S]*?\n\2(?=\s*($|\n|;|&|\)))/g,
    "<<HEREDOC_STRIPPED"
  );
  s = s.replace(/'[^']*'/g, "''");           // single-quoted data
  s = s.replace(/"(?:[^"\\]|\\.)*"/g, '""'); // double-quoted data
  return s;
}
```

Then: `matches(STREAMING, commandSkeleton(cmd))` etc. The `ALREADY_TAMED`
check should keep using the raw string (a redirect inside quotes is rare,
and stripping there only risks re-blocking tamed commands).

Optional hardening, independent of the above:

- Tighten `/\btop\b/` so a preceding hyphen doesn't count: `/(?<![-\w])top\b/`
  (Node ≥ 8.3 supports lookbehind).
- Same treatment for `less`, `make` if they prove noisy.

Not recommended as the primary fix: a full shell parser (overkill, new
dependency) or whitelisting `git commit` (the bug is generic, not git's).

## Acceptance criteria

- `git commit -m "diagonal bottom-to-top wipe reveal"` (with or without a
  heredoc) is allowed.
- A heredoc whose body contains `watch the sequence`, `less`, `--follow`,
  or `top` is allowed, provided the command outside the heredoc is clean.
- `tail -f log`, `watch date`, `top`, `docker logs -f x` are still denied.
- `npm test` without capture is still redirected to the capture-and-filter
  recipe; `npm test > /tmp/x.log 2>&1` still passes.
- A command that *both* has innocent quoted data *and* a real streaming
  invocation outside quotes (`echo "top scores" && tail -f app.log`) is
  still denied.

## Workaround until fixed

Either avoid trigger words in commit-message heredocs (fragile), write the
message to a file and use `git commit -F <file>`, or set
`OUTPUT_DISCIPLINE_ALLOW="git commit"` in the environment (allows any
command containing that fragment — coarse but unblocks commits).
