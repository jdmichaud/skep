skepd(8)

# NAME

skepd - run a Zigbee network

# SYNOPSIS

*skepd* *--device* _path_ [*--state* _path_] [*--socket* _path_] [*--driver* _name_] [*--log-level* _level_] [*--replace-network*] [*--baud* _rate_] [*--rtscts*]

*skepd* *--help*

# DESCRIPTION

*skepd* runs the Zigbee network of a dongle, through libskep. It is the only
program that opens the dongle: it brings the network up, interviews and sets
up the devices that join, and serves clients such as *skep*(1) on a Unix
socket, as *skep-protocol*(7) says.

It keeps the network's state in a file: the network, its keys and frame
counters, and the devices and what their interviews found. With that file,
skepd comes back to the same network after a restart, and puts it back onto
a new dongle when the old one dies. It refreshes the frame counters from the
dongle every hour, and when it stops.

It remembers the last readings of the devices, such as a temperature, which
it gives clients. Once the network is up, and when a device is set up, it
reads the devices for those it has none of.

When the dongle goes away, skepd opens it again every 5 seconds until it is
back. It runs in the foreground, and logs to standard error.

# OPTIONS

*--device* _path_
	The dongle's serial device, best under _/dev/serial/by-id/_, whose names do
	not change when other devices are plugged in.

*--state* _path_
	The state file, which skepd reads at start and replaces when it changes,
	every 5 seconds at most, and before it exits. By default _state.json_ in
	_$STATE_DIRECTORY_ under systemd, in _$XDG_DATA_HOME/skep_ otherwise.

*--socket* _path_
	The socket clients connect to. By default _skepd.sock_ in
	_$RUNTIME_DIRECTORY_ under systemd, in _$XDG_RUNTIME_DIR/skep_ otherwise.

*--driver* _name_
	The dongle's driver: *ezsp* (the default), for Silicon Labs EmberZNet
	dongles such as the Sonoff ZBDongle-E; or *sim*, a simulated network that
	needs no dongle, for tests, which takes no *--device*.

*--log-level* _level_
	*error*, *warning*, *info* (the default) or *debug*, which logs every frame
	the dongle reports.

*--replace-network*
	Replace the network the dongle holds, if it is not the saved one: with the
	saved one, or with a new one if no state is saved. The devices of the
	network replaced must then be paired again. Without it, skepd refuses to
	overwrite a network it does not know.

*--baud* _rate_, *--rtscts*
	The serial speed and hardware flow control, if the dongle's firmware does
	not use the driver's usual ones (115200 bauds, software flow control for
	ezsp).

*--help*
	Print how to use skepd, and exit.

# FILES

_state.json_
	The state. It holds the network key: skepd writes it with mode 0600, in a
	directory it creates with mode 0700, and replaces it as a whole, so that a
	crash leaves the old state or the new one. A state skepd cannot read stops
	it before it opens the dongle, and is left as it is.

_names.json_
	The names clients give devices, next to the state.

_skepd.sock_
	The socket. Whoever can connect has full control of the network: its
	directory decides who can.

# SYSTEMD

skepd comes with units for the system and for users. Both are templates
whose instance is the dongle under _/dev_:

```
systemctl enable --now skepd@ttyUSB0
systemctl enable --now "skepd@$(systemd-escape --path serial/by-id/usb-...)"
```

The system unit runs skepd as the *skep* user, which systemd-sysusers
creates. Its state is in _/var/lib/skep_, for *skep* alone; its socket in
_/run/skep_, which the *skep* group may use: add those who run *skep* to it.
The unit gives skepd the *dialout* group for the dongle; on distributions
where serial devices belong to *uucp*, change it with *systemctl edit*.

The user unit, for *systemctl --user*, runs skepd as the user, with the same
paths as when started by hand.

skepd tells systemd it is ready once its socket accepts clients, and then
how the network is doing, which *systemctl status* shows.

The units start *skepd* by name, which systemd finds in _/usr/local/bin_ and
_/usr/bin_. Installed elsewhere, the path is set with *systemctl edit
skepd@.service*:

```
[Service]
ExecStart=
ExecStart=/opt/skep/bin/skepd --device /dev/%I
```

# SIGNALS

*SIGTERM*, *SIGINT*, *SIGHUP*
	Stop cleanly: refresh the state from the dongle, save it, and exit.

# ENVIRONMENT

_STATE_DIRECTORY_, _RUNTIME_DIRECTORY_
	Set by systemd: where the state and the socket go.

_XDG_DATA_HOME_, _XDG_RUNTIME_DIR_, _HOME_
	Where they go otherwise.

_JOURNAL_STREAM_
	When standard error is journald's, skepd leaves out the time it otherwise
	starts its lines with: journald adds its own.

_NOTIFY_SOCKET_
	Where systemd listens for skepd's readiness and status.

# EXIT STATUS

0 after a clean stop. 1 when skepd cannot go on: a state it cannot read, a
socket another skepd answers on, a dongle that holds another network, or
one that does not answer, as when *--device* names the wrong device. 2 when
the command line is wrong.

# SEE ALSO

*skep*(1), *skep-protocol*(7), *systemd.service*(5), *systemd-sysusers*(8)
