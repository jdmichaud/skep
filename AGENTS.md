# Agent guidelines for skep

## Formatting

- Format Zig code (`.zig` and `.zon` files) with `zigfmt`, the formatter
  found in `PATH`. Do not use `zig fmt`: the two produce different output.
- Run it before every commit: `zigfmt .`, then check that
  `zigfmt --check .` exits with 0. Never commit unformatted code.
- The style is pinned in `zigfmt.zon`. Do not change it as part of an
  unrelated commit.
- The pre-commit hook in `.githooks/` enforces this. Enable it once per
  clone with `git config core.hooksPath .githooks`.

## Commits

- Commit regularly, in small, self-contained steps: one logical change per
  commit, and every commit builds and passes the tests on its own.
- Do not mix unrelated changes, such as a refactoring and a new feature, in
  the same commit.
- Write commit messages for humans: a short summary line (imperative mood,
  at most 72 characters), a blank line, then a body explaining what changed
  and why. Do not explain how; the code shows that.

## README

- Keep `README.md` as small as possible: what skep is, how to build and
  install it, and where to find more. Detailed documentation belongs in the
  man pages.
