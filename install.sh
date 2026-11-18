#!/bin/sh
# install.sh - install skepd, skep and their manual pages from a skep release on GitHub.
#
#   curl -fsSL https://github.com/jdmichaud/skep/releases/latest/download/install.sh | sh
#
# Downloads the release's archive of static binaries for this machine, and the release's
# SHA256SUMS; checks the archive against it; and unpacks it into the prefix: bin/skepd, bin/skep
# and share/man/man*/. The prefix is /usr/local as root, ~/.local otherwise, or $PREFIX.
# $SKEP_VERSION installs a release other than the latest, such as 0.1.0.
#
# Nothing else is done: no compiler, no service, no user. Run it again to update; remove the
# files it lists to uninstall.
set -eu

releases=https://github.com/jdmichaud/skep/releases
version=${SKEP_VERSION:-latest}
if [ "$(id -u)" = 0 ]; then prefix=${PREFIX:-/usr/local}; else prefix=${PREFIX:-$HOME/.local}; fi

[ "$(uname -s)" = Linux ] || { echo "install.sh: skep runs on Linux only" >&2; exit 1; }
case $(uname -m) in
    x86_64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    armv6l | armv7l | armv8l) arch=arm ;;
    riscv64) arch=riscv64 ;;
    *) echo "install.sh: no skep build for $(uname -m)" >&2; exit 1 ;;
esac
if [ "$version" = latest ]; then url=$releases/latest/download; else url=$releases/download/$version; fi
archive=skep-$arch-linux.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$archive" "$url/$archive"
curl -fsSL -o "$tmp/SHA256SUMS" "$url/SHA256SUMS"
(cd "$tmp" && grep " $archive\$" SHA256SUMS | sha256sum -c -)

mkdir -p "$prefix"
tar -xzf "$tmp/$archive" -C "$prefix"
tar -tzf "$tmp/$archive" | sed "s|^|installed $prefix/|"
