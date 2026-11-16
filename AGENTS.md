# Agent guidelines for skep

## Formatting

- Format Zig code (`.zig` and `.zon` files) with `zig build fmt`, which
  runs the zigfmt pinned in `build.zig.zon`. Do not use `zig fmt`, nor a
  zigfmt from `PATH`: their output may differ from the pinned version's.
- Run it before every commit, then check that `zig build fmt-check`
  succeeds. Never commit unformatted code.
- The style is pinned in `zigfmt.zon` and the formatter in
  `build.zig.zon`. Do not change either as part of an unrelated commit.
- The pre-commit hook in `.githooks/` enforces this. Enable it once per
  clone with `git config core.hooksPath .githooks`.

## Commits

- Commit regularly, in small, self-contained steps: one logical change per
  commit, and every commit builds and passes the tests on its own.
- Do not mix unrelated changes, such as a refactoring and a new feature, in
  the same commit.
- A commit that changes the API raises the version, as described under
  "Releasing" in `doc/development.md`.
- Write commit messages for humans: a short summary line (imperative mood,
  at most 72 characters), a blank line, then a body explaining what changed
  and why. Do not explain how; the code shows that.

## Documentation

- Read `doc/design.md` before changing the architecture or the C API. When
  a decision changes, update it in the same commit.
- `doc/hardware.md` holds what we know about the dongle and devices, and
  `doc/development.md` the development setup and the reference sources.
- Record changes that matter to users of skep (new or changed API,
  behaviour, devices, fixes) in `CHANGELOG.md`, under `[Unreleased]`, in
  the commit that makes them. They become the release notes.
- Do not copy or port code from Zigbee2MQTT or zigpy (GPL-3.0). Code from
  the MIT licensed zigbee-herdsman projects may be ported with its
  copyright notice.

## README

- Keep `README.md` as small as possible: what skep is, how to build and
  install it, and where to find more. User documentation belongs in the
  man pages, developer documentation in `doc/`.
