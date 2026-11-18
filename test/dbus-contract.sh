#!/bin/sh
# What D-Bus clients see of a service published through the dbus module's interface, Bus:
# its objects, their properties, the signals of their changes, and the errors of what it does
# not do, as busctl (sd-bus), gdbus (GLib) and dbus-send (libdbus) show them. `zig build
# test-dbus` runs it on a session bus of its own, with test/dbus_harness.zig as the service.
# Written against the interface only: a replacement of what is behind it must pass it as it is.
set -eu
harness=$1
service=io.example.Contract1
root=/io/example/Contract1
device=io.example.Contract1.Device
a1=$root/devices/a1

dir=$(mktemp -d)
mkfifo "$dir/in"
"$harness" < "$dir/in" > "$dir/out" &
exec 3> "$dir/in"
trap 'exec 3>&-; rm -rf "$dir"' EXIT

fail() {
    echo "dbus-contract: $*" >&2
    exit 1
}

# Waits until the service has printed $1 $2 times, or once.
await() {
    n=0
    until [ "$(grep -cx "$1" "$dir/out")" -ge "${2:-1}" ]; do
        n=$((n + 1))
        [ $n -lt 200 ] || fail "the service did not say '$1'"
        sleep 0.05
    done
}

# Gives the service a command, and waits until it is done.
commands=0
tell() {
    echo "$*" >&3
    commands=$((commands + 1))
    await ok $commands
}

check() {
    [ "$2" = "$3" ] || fail "$1:
expected: $3
got:      $2"
}

objects() {
    busctl --user call $service $root org.freedesktop.DBus.ObjectManager GetManagedObjects
}

# Waits, in the background, for the signal $3 of the interface $2 on the object $1, into the
# file $dir/signal; returns once the bus routes it, which dbus-daemon tells by its match rules.
listen() {
    rm -f "$dir/signal"
    busctl --user wait "$1" "$2" "$3" > "$dir/signal" &
    listener=$!
    n=0
    until busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.Debug.Stats GetAllMatchRules 2>/dev/null | grep -q "member=.\{1,2\}$3"; do
        n=$((n + 1))
        if [ $n -ge 100 ]; then
            # A bus without statistics: time enough.
            sleep 0.5
            break
        fi
        sleep 0.05
    done
}

# Waits for the signal listened for, $1, into $signal: in this shell, the listener's parent.
heard() {
    wait $listener || fail "no $1 signal"
    signal=$(cat "$dir/signal")
}

# The error name of a method call, as dbus-send tells it.
error_of() {
    dbus-send --session --print-reply --dest=$service "$@" 2>&1 >/dev/null |
        sed -n 's/^Error \([^:]*\):.*/\1/p'
}

await published

# Nothing published yet; the root is the object manager.
check "no objects" "$(objects)" 'a{oa{sa{sv}}} 0'
busctl --user introspect $service $root | grep -q '^org.freedesktop.DBus.ObjectManager ' ||
    fail "the root is not an object manager"

# An object published: announced, listed, and its properties read.
listen $root org.freedesktop.DBus.ObjectManager InterfacesAdded
tell put $a1 kitchen 21.5
heard InterfacesAdded
check "InterfacesAdded" "$signal" \
    "oa{sa{sv}} \"$a1\" 1 \"$device\" 2 \"Name\" s \"kitchen\" \"Readings\" a{sv} 1 \"temperature\" d 21.5"
check "objects" "$(objects)" \
    "a{oa{sa{sv}}} 1 \"$a1\" 1 \"$device\" 2 \"Name\" s \"kitchen\" \"Readings\" a{sv} 1 \"temperature\" d 21.5"
check "Name" "$(busctl --user get-property $service $a1 $device Name)" 's "kitchen"'
check "Readings" "$(busctl --user get-property $service $a1 $device Readings)" \
    'a{sv} 1 "temperature" d 21.5'
check "GetAll" "$(busctl --user call $service $a1 org.freedesktop.DBus.Properties GetAll s $device)" \
    'a{sv} 2 "Name" s "kitchen" "Readings" a{sv} 1 "temperature" d 21.5'
busctl --user call $service $a1 org.freedesktop.DBus.Peer Ping > /dev/null || fail "no Ping"

# Its introspection, as GLib reads it: the nodes on the way, and the interface's properties.
gdbus introspect --session --dest $service --object-path / --recurse > "$dir/introspection" ||
    fail "gdbus cannot introspect the service"
grep -q "node $a1 " "$dir/introspection" || fail "no node $a1 in the introspection"
grep -q "readonly a{sv} Readings" "$dir/introspection" || fail "no Readings in the introspection"

# A change, signalled; the same value again is not, so the first signal is the next change's.
listen $a1 org.freedesktop.DBus.Properties PropertiesChanged
tell set $a1 21.5
tell set $a1 22
heard PropertiesChanged
check "PropertiesChanged" "$signal" \
    "sa{sv}as \"$device\" 1 \"Readings\" a{sv} 1 \"temperature\" d 22 0"

# What it does not do.
check "Set" "$(error_of $a1 org.freedesktop.DBus.Properties.Set string:$device string:Name variant:string:x)" \
    org.freedesktop.DBus.Error.PropertyReadOnly
check "unknown property" "$(error_of $a1 org.freedesktop.DBus.Properties.Get string:$device string:Colour)" \
    org.freedesktop.DBus.Error.UnknownProperty
check "unknown interface" "$(error_of $a1 org.freedesktop.DBus.Properties.GetAll string:io.example.Other)" \
    org.freedesktop.DBus.Error.UnknownInterface
check "unknown method" "$(error_of $a1 $device.Explode)" org.freedesktop.DBus.Error.UnknownMethod
check "unknown object" "$(error_of $root/devices/b2 org.freedesktop.DBus.Properties.GetAll string:$device)" \
    org.freedesktop.DBus.Error.UnknownObject

# The object removed: announced, and gone.
listen $root org.freedesktop.DBus.ObjectManager InterfacesRemoved
tell remove $a1
heard InterfacesRemoved
check "InterfacesRemoved" "$signal" "oas \"$a1\" 1 \"$device\""
check "no objects again" "$(objects)" 'a{oa{sa{sv}}} 0'
check "removed object" "$(error_of $a1 org.freedesktop.DBus.Properties.GetAll string:$device)" \
    org.freedesktop.DBus.Error.UnknownObject

echo "dbus-contract: all checks passed"
