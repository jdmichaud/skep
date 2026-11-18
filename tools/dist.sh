#!/usr/bin/env bash
# tools/dist.sh <dir> - build what a release offers for install.sh: for each Linux architecture,
# an archive of skepd, skep and their manual pages, as static binaries that run on any
# distribution, with skepd's systemd units; their SHA256SUMS; and install.sh itself. CI runs it
# for each release.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(realpath -m "${1:?usage: tools/dist.sh <dir>}")
mkdir -p "$out"

files="bin/skepd bin/skep share/man/man1/skep.1 share/man/man7/skep-protocol.7 share/man/man8/skepd.8
    lib/systemd/system/skepd.service lib/systemd/user/skepd.service lib/sysusers.d/skep.conf"

# The architecture as install.sh names it, the Zig target, and the CPU if not the target's
# default: 32-bit ARM for the Raspberry Pi 1 and Zero's ARMv6, which ARMv7 runs too.
while read -r arch target cpu; do
    prefix=$(mktemp -d)
    zig build -Drelease -Dtarget="$target" ${cpu:+-Dcpu="$cpu"} --prefix "$prefix"
    # Files only, owned by root and writable by it only: unpacked into a prefix, the archive
    # leaves its directories as they are.
    tar -C "$prefix" --owner=0 --group=0 --numeric-owner --mode=go-w \
        -czf "$out/skep-$arch-linux.tar.gz" $files
    rm -rf "$prefix"
done <<EOF
x86_64 x86_64-linux-musl
aarch64 aarch64-linux-musl
arm arm-linux-musleabihf arm1176jzf_s
riscv64 riscv64-linux-musl
EOF

cp install.sh "$out/"
(cd "$out" && sha256sum skep-*-linux.tar.gz > SHA256SUMS)
