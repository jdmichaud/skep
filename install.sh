#!/bin/sh
# install.sh - install skep from a release on GitHub: skepd, skep and their manual pages; where
# systemd runs the machine, skepd's units; and skep-uninstall, which removes all of it.
#
#   curl -fsSL https://github.com/jdmichaud/skep/releases/latest/download/install.sh | sh
#
# Downloads the release's archive of static binaries for this machine and the release's
# SHA256SUMS, checks the archive against it, and installs into the prefix: /usr/local as root,
# ~/.local otherwise, or $PREFIX. $SKEP_VERSION installs a release other than the latest, such
# as 0.1.0. Run it again to update.
#
# The units are installed, not enabled: as root, skepd@ as a system service, with the skep user it
# runs as, and as a user service for every user; otherwise as the user's service. skepd(8) tells
# how to start them.
set -eu

releases=https://github.com/jdmichaud/skep/releases
version=${SKEP_VERSION:-latest}
if [ "$(id -u)" = 0 ]; then root=1; else root=; fi
if [ -n "$root" ]; then prefix=${PREFIX:-/usr/local}; else prefix=${PREFIX:-$HOME/.local}; fi

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
tar -xzf "$tmp/$archive" -C "$tmp"

# Installs a file of the archive, and notes it for skep-uninstall to remove.
put() {
    install -D -m "$1" "$tmp/$2" "$3"
    echo "rm -f -- '$3'" >> "$tmp/removals"
    echo "installed $3"
}
put 755 bin/skepd "$prefix/bin/skepd"
put 755 bin/skep "$prefix/bin/skep"
put 644 share/man/man1/skep.1 "$prefix/share/man/man1/skep.1"
put 644 share/man/man7/skep-protocol.7 "$prefix/share/man/man7/skep-protocol.7"
put 644 share/man/man8/skepd.8 "$prefix/share/man/man8/skepd.8"

if [ -d /run/systemd/system ]; then
    # The units start skepd where it was installed, rather than look for it.
    sed -i "s|^ExecStart=skepd |ExecStart=$prefix/bin/skepd |" "$tmp"/lib/systemd/*/skepd@.service
    if [ -n "$root" ]; then
        put 644 lib/systemd/system/skepd@.service /etc/systemd/system/skepd@.service
        put 644 lib/systemd/user/skepd@.service /etc/systemd/user/skepd@.service
        put 644 lib/sysusers.d/skep.conf /etc/sysusers.d/skep.conf
        systemd-sysusers /etc/sysusers.d/skep.conf
        systemctl daemon-reload
    else
        put 644 lib/systemd/user/skepd@.service "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/skepd@.service"
        systemctl --user daemon-reload || true
    fi
fi

# skep-uninstall: the services stopped, the files above removed, the skep user deleted, and the
# network state too if its owner says so.
{
    echo '#!/bin/sh'
    echo "# skep-uninstall - remove skep, as install.sh installed it into $prefix."
    echo "root=$root"
    cat <<'EOF'
if [ -n "$root" ]; then user=; else user=--user; fi
if [ -d /run/systemd/system ]; then
    # Stopped, and no longer started at boot or login.
    systemctl $user stop 'skepd@*.service'
    if [ -n "$root" ]; then
        rm -f /etc/systemd/system/*.wants/skepd@*.service /etc/systemd/user/*.wants/skepd@*.service
    else
        rm -f "${XDG_CONFIG_HOME:-$HOME/.config}"/systemd/user/*.wants/skepd@*.service
    fi
fi
EOF
    cat "$tmp/removals"
    echo "rm -f -- '$prefix/bin/skep-uninstall'"
    cat <<'EOF'
if [ -n "$root" ]; then
    userdel skep 2>/dev/null
    groupdel skep 2>/dev/null
fi
[ -d /run/systemd/system ] && systemctl $user daemon-reload
# The network state: its key, its devices and their names. Without it, every device has to be
# paired again with a new network: deleted only when its owner says so.
if [ -n "$root" ]; then state=/var/lib/skep; else state=${XDG_DATA_HOME:-$HOME/.local/share}/skep; fi
if [ -e "$state" ]; then
    printf '%s holds the network state: its key, its devices and their names.\n' "$state"
    printf 'Delete it? Every device would have to be paired again. [y/N] '
    { read -r answer < /dev/tty; } 2>/dev/null || answer=
    case $answer in
        y | Y | yes) rm -rf -- "$state" && echo "removed $state" ;;
        *) echo "kept $state" ;;
    esac
fi
echo "skep is uninstalled"
EOF
} > "$tmp/skep-uninstall"
install -m 755 "$tmp/skep-uninstall" "$prefix/bin/skep-uninstall"
echo "installed $prefix/bin/skep-uninstall, which removes all of it"
