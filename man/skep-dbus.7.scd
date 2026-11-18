skep-dbus(7)

# NAME

skep-dbus - skepd's devices on D-Bus

# DESCRIPTION

*skepd*(8) publishes the devices of its network on D-Bus, for desktop
widgets, status bars and scripts that show or follow what they measure: an
object per device, whose properties are its address, its name and its last
readings, and signals when they change. It is read-only: what *skep*(1)
does, such as pairing, naming or switching devices, goes through
*skep-protocol*(7).

skepd publishes on the user's session bus when _DBUS_SESSION_BUS_ADDRESS_
names one, as for skepd started by hand in a session or by the user unit;
otherwise on the system bus, as for the system unit, where its policy lets
only the *skep* group and root see the devices (see FILES). Without a bus,
or when the bus does not let it own its name, skepd runs as usual: it says
so in its log, and tries again later, every 5 minutes at most.

# NAMES

The bus name *zigbee.Skep1* is skepd's. Its root object, _/zigbee/Skep1_,
implements *org.freedesktop.DBus.ObjectManager*, which lists the devices and
tells when they come and go. Each device is the object
_/zigbee/Skep1/devices/IEEE_, by its IEEE address in 16 lowercase
hexadecimal digits, with the interface *zigbee.Skep1.Device*.

The 1 is the version of the interface. A change that breaks clients comes as
Skep2, next to it. Newer versions of skepd add properties and readings,
which clients ignore if they do not know them.

# PROPERTIES

The properties of *zigbee.Skep1.Device*, which are read-only:

*Address* (s)
	The device's IEEE address, as in its object's path and in
	skep-protocol(7).

*Name* (s)
	The name *skep rename* gave it, or "" without one.

*Readings* (a{sv})
	The last value of each reading the device reported or was read for, by
	the reading's name, such as "temperature", as a double in the reading's
	unit: °C for a temperature, 1 or 0 for "on". skep-protocol(7) lists the
	readings and their units under READINGS. A reading is of the device's
	first endpoint with it, as *skep get* gives it, and is left out until it
	has a value: a sleepy device's, after skepd starts, until it reports or
	wakes up.

# SIGNALS

*org.freedesktop.DBus.Properties.PropertiesChanged*, on a device
	Properties that changed: its name, or its readings, once a report or a
	read changes one of them. A report of the same values signals nothing.

*org.freedesktop.DBus.ObjectManager.InterfacesAdded*, on the root
	A device joined.

*org.freedesktop.DBus.ObjectManager.InterfacesRemoved*, on the root
	A device was removed from the network. One that left by itself stays,
	since it may come back.

When skepd starts, or comes back to a bus that went away, it owns its name
again, which the bus tells clients with *NameOwnerChanged*: they read the
devices again then.

# EXAMPLES

The devices, and a sensor's last readings:

```
busctl --user tree zigbee.Skep1
busctl --user get-property zigbee.Skep1 \\
    /zigbee/Skep1/devices/f44250000d350000 \\
    zigbee.Skep1.Device Readings
```

which says _a{sv} 3 "temperature" d 21.54 "humidity" d 48.2 "battery" d
100_. Its readings as they change, one line each:

```
gdbus monitor --session --dest zigbee.Skep1 \\
    --object-path /zigbee/Skep1/devices/f44250000d350000
```

For skepd's system unit, *--system* rather than *--user* and *--session*.

# FILES

_/etc/dbus-1/system.d/zigbee.Skep1.conf_
	The system bus's policy for skepd, which the release's _install.sh_
	installs as root, or _share/dbus-1/system.d_ under the prefix *zig
	build* installs into: the *skep* user owns the name, the *skep* group
	and root see the devices and get their signals, and other users do
	neither, since readings tell who is home. Without it, the system bus
	does not let skepd own its name.

# SEE ALSO

*skepd*(8), *skep-protocol*(7), *busctl*(1), *gdbus*(1)
