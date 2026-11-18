#!/bin/sh
# skepd's policy for the system bus, dbus/zigbee.Skep1.conf, as dbus-daemon applies
# it: its user owns the name, its group reads the objects and gets their signals, and other users
# do neither. On a bus of its own, configured as the system bus is, with the policy's user and
# group made the tester's, its name the harness's, and test/dbus_harness.zig as the service.
# `zig build test-dbus` runs it; it needs no root.
set -eu
harness=$1
policy=$2
system_conf=/usr/share/dbus-1/system.conf
service=io.example.Contract1
root=/io/example/Contract1

dir=$(mktemp -d)
daemon=
trap 'exec 3>&- 2>/dev/null; [ -z "$daemon" ] || kill $daemon 2>/dev/null || true; rm -rf "$dir"' EXIT

fail() {
    echo "dbus-policy: $*" >&2
    exit 1
}

[ -r $system_conf ] || fail "no $system_conf to configure the bus as the system bus is"

# Runs a bus configured as the system bus, with the policy given to group $1, and the harness
# publishing on it.
start() {
    mkdir -p "$dir/policy"
    sed -e "s/zigbee\.Skep1/$service/g" \
        -e "s/user=\"skep\"/user=\"$(id -un)\"/" \
        -e "s/group=\"skep\"/group=\"$1\"/" "$policy" > "$dir/policy/policy.conf"
    # The system bus's configuration, without what needs root or reaches the machine's services.
    sed -e 's|<user>.*</user>||' -e 's|<pidfile>.*</pidfile>||' \
        -e 's|<servicehelper>.*</servicehelper>||' -e 's|<standard_system_servicedirs/>||' \
        -e 's|<include .*</include>||' -e 's|<includedir>.*</includedir>||' \
        -e "s|<listen>.*</listen>|<listen>unix:path=$dir/bus</listen>|" \
        -e "s|</busconfig>|<includedir>$dir/policy</includedir></busconfig>|" \
        $system_conf > "$dir/bus.conf"
    grep -q "<includedir>$dir/policy</includedir>" "$dir/bus.conf" || fail "cannot configure the bus"
    dbus-daemon --config-file="$dir/bus.conf" --nofork --nosyslog &
    daemon=$!
    address=unix:path=$dir/bus
    n=0
    until [ -S "$dir/bus" ]; do
        n=$((n + 1))
        [ $n -lt 100 ] || fail "the bus did not start"
        sleep 0.05
    done
    rm -f "$dir/in" "$dir/out"
    mkfifo "$dir/in"
    DBUS_SESSION_BUS_ADDRESS=$address "$harness" < "$dir/in" > "$dir/out" &
    exec 3> "$dir/in"
    n=0
    until grep -qx published "$dir/out"; do
        n=$((n + 1))
        [ $n -lt 100 ] || fail "the policy's user cannot own the name"
        sleep 0.05
    done
}

stop() {
    exec 3>&-
    kill $daemon
    wait $daemon 2>/dev/null || true
    daemon=
    rm -f "$dir/bus"
}

# Whether this user reads the objects, and gets the signal of one added.
reads() {
    busctl --address=$address call $service $root org.freedesktop.DBus.ObjectManager \
        GetManagedObjects > /dev/null 2>&1
}
hears() {
    timeout 3 busctl --address=$address wait $root org.freedesktop.DBus.ObjectManager \
        InterfacesAdded > /dev/null 2>&1 &
    listener=$!
    sleep 0.5
    echo "put $root/devices/a$1 kitchen 21.5" >&3
    wait $listener
}

# The policy's group is the tester's: the objects are read, and their signals heard.
start "$(id -gn)"
reads || fail "the policy's group cannot read the objects"
hears 1 || fail "the policy's group does not get the signals"
stop

# Another group, without the tester: neither.
other=$(getent group | cut -d: -f1 | while read -r g; do
    id -Gn | tr ' ' '\n' | grep -qx "$g" || { echo "$g"; break; }
done)
[ -n "$other" ] || fail "no group without $(id -un) to give the policy"
start "$other"
! reads || fail "a user outside the policy's group reads the objects"
! hears 2 || fail "a user outside the policy's group gets the signals"
stop

echo "dbus-policy: all checks passed"
