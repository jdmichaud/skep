#!/usr/bin/env bash
# release.sh - release the version in build.zig.zon and start the next one.
#
#   ./release.sh [patch|minor|major] [--no-test]
#
# 1. Refuses to run with uncommitted changes, and asks before releasing
#    from a branch other than master.
# 2. Checks that skep.h's SKEP_VERSION_* macros match build.zig.zon, that
#    the tag does not exist, and that CHANGELOG.md has notes under
#    [Unreleased].
# 3. Runs the release gate: the tests in debug and ReleaseSafe, the
#    format check, and the build of the archives install.sh installs
#    (--no-test skips it).
# 4. Moves the [Unreleased] notes under the version, commits that and
#    tags the commit with the version.
# 5. Raises the version in build.zig.zon and skep.h for the next release,
#    by a patch unless told otherwise, and commits it.
#
# Nothing is pushed: the commands to publish are printed at the end. CI
# publishes the release when the tag is pushed.

set -euo pipefail
cd "$(dirname "$0")"

fail() {
    echo "release.sh: $*" >&2
    exit 1
}

bump=patch
gate=1
for arg in "$@"; do
    case "$arg" in
        patch|minor|major) bump=$arg ;;
        --no-test) gate=0 ;;
        *) echo "usage: $0 [patch|minor|major] [--no-test]" >&2; exit 2 ;;
    esac
done

# 1. A clean tree, on master.
if [ -n "$(git status --porcelain)" ]; then
    fail "uncommitted changes: commit or stash them first"
fi
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != master ]; then
    read -r -p "release.sh: releasing from branch '$branch', continue? [y/N] " answer
    [ "$answer" = y ] || exit 1
fi

# 2. The version, its tag and its notes.
version=$(sed -n 's/^ *\.version = "\([0-9][^"]*\)",.*/\1/p' build.zig.zon)
[ -n "$version" ] || fail "no .version in build.zig.zon"
IFS=. read -r major minor patch <<< "$version"
macro() {
    sed -n "s/^#define SKEP_VERSION_$1 \([0-9][0-9]*\)$/\1/p" include/skep.h
}
if [ "$(macro MAJOR).$(macro MINOR).$(macro PATCH)" != "$version" ]; then
    fail "the SKEP_VERSION_* macros of skep.h do not match version $version of build.zig.zon"
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    fail "tag $version already exists"
fi
notes=$(awk '/^## \[Unreleased\]$/ { on = 1; next } on && /^## / { exit } on && NF { print }' \
    CHANGELOG.md)
[ -n "$notes" ] || fail "nothing under [Unreleased] in CHANGELOG.md: the release would have no notes"

# 3. The release gate.
if [ "$gate" = 1 ]; then
    echo "==> zig build test"
    zig build test
    echo "==> zig build test -Drelease"
    zig build test -Drelease
    echo "==> zig build fmt-check"
    zig build fmt-check
    echo "==> tools/dist.sh"
    dist=$(mktemp -d)
    tools/dist.sh "$dist"
    rm -rf "$dist"
fi

# 4. The release commit and its tag.
sed -i "s/^## \[Unreleased\]$/## [Unreleased]\n\n## [$version] - $(date +%Y-%m-%d)/" CHANGELOG.md
git add CHANGELOG.md
git commit -q -F - <<EOF
Release $version

Move the notes under [Unreleased] in CHANGELOG.md to version $version.
EOF
git tag -a "$version" -m "skep $version"
echo "==> tagged $version"

# 5. The next version.
case "$bump" in
    major) next="$((major + 1)).0.0" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
esac
IFS=. read -r next_major next_minor next_patch <<< "$next"
sed -i "s/^\( *\.version = \)\"$version\",/\1\"$next\",/" build.zig.zon
sed -i -e "s/^#define SKEP_VERSION_MAJOR [0-9]*$/#define SKEP_VERSION_MAJOR $next_major/" \
    -e "s/^#define SKEP_VERSION_MINOR [0-9]*$/#define SKEP_VERSION_MINOR $next_minor/" \
    -e "s/^#define SKEP_VERSION_PATCH [0-9]*$/#define SKEP_VERSION_PATCH $next_patch/" \
    include/skep.h
if [ "$(git diff --name-only | tr '\n' ' ')" != "build.zig.zon include/skep.h " ]; then
    fail "raising the version did not change both build.zig.zon and include/skep.h"
fi
git add build.zig.zon include/skep.h
git commit -q -F - <<EOF
Start $next development

Raise the version in build.zig.zon and skep.h to that of the next
release.
EOF
echo "==> the version is now $next"

echo
echo "To publish (CI releases the pushed tag):"
echo "  git push origin $branch"
echo "  git push origin $version"
