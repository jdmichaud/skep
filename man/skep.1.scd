skep(1)

# NAME

skep - ask skepd about the Zigbee network, and tell it what to do

# SYNOPSIS

*skep* [*--socket* _path_] [*--json*] [*--timeout* _seconds_] _command_ [_arguments_]

# DESCRIPTION

*skep* is a client of *skepd*(8), which runs the network: it turns its
arguments into a request of *skep-protocol*(7), sends it on skepd's socket,
and prints the answer. It knows nothing of Zigbee itself.

A _device_ is its IEEE address, 16 hexadecimal digits such as
f44250000d350000, or the name *rename* gave it. Endpoints are numbers;
clusters, attributes and commands too, in decimal or in hexadecimal after
0x, such as 0x0402.

A _reading_ is what an attribute holds, named and in its unit: a
temperature in °C rather than the hundredths of a degree the device sends.
*get* lists those of a device; skep-protocol(7) lists them all.

Text that devices send is printed with control characters, and characters
that reorder text, escaped: \\n, \\x1b, \\u{202e}. A device cannot use it
to drive the terminal, nor to forge lines.

# COMMANDS

*version*
	The versions of skepd, of the libskep it runs on, and of its protocol.

*network*
	Whether the network is up, its channel, PAN ID and extended PAN ID, and
	how long devices may still join.

*permit* [_seconds_]
	Let new devices join for that long, 60 seconds by default, at most 254;
	0 stops letting them.

*rekey*
	Give the network a new, random key: sent to each device, encrypted with
	its own link key, then switched to after 15 seconds. A device that was
	removed and still listens cannot read it: rekey after removing a device
	you no longer trust. A sleepy device that missed the key rejoins by
	itself, or must be paired again; skepd's log names the devices the key
	could not be sent to.

*devices*
	The devices, one per line: their name, or address without one, their
	model, and the first three readings they reported, or how far their setup
	got (pending or failed).

*device* _device_
	One device, in detail: what its interview found, its endpoints and
	clusters, and its readings, as *get* gives them.

*get* _device_ [_reading_...]
	The readings of the device, or those named: the last value it reported
	or was read for, and how long ago. It answers at once, even for a device
	that sleeps. After skepd starts, a device that sleeps has no values until
	it wakes up, which can take minutes.

*rename* _device_ [_name_]
	Give the device a name, or forget its name without one.

*setup* _device_
	Interview the device and set it up again, from the start.

*remove* _device_
	Make the device leave the network, and forget it. It gives up waiting
	for an answer after 60 seconds, or *--timeout*: the device is forgotten
	either way.

*read* _device_ _reading_...
	Ask the device for the readings named. A device that sleeps answers
	when it wakes up, which can take minutes: see *--timeout*.

*read* _device_ _endpoint_ _cluster_ _attribute_...
	Read attributes: their values and types, and their readings, or the
	status the device gave.

*set* _device_ *on*|*off*
	Switch the device on or off: a light or a plug.

*set* _device_ _reading_ _value_ [*--transition* _seconds_]
	Set a reading: a light's *level*, such as 50%; its *color_temperature*,
	such as 2700K; its *hue* or *saturation*. Or set a light's colour:
	*color* and an sRGB colour, such as #ff8000, whose brightness is the
	level's. A light takes _seconds_ to get there, 0 by default. A value
	outside what the device takes is refused, with the range it takes.

*write* _device_ _endpoint_ _cluster_ _attribute_ _type_ _value_
	Write an attribute, with its ZCL type named as *skep-protocol*(7) names
	them, such as uint8 or char_string.

*report* _device_ _endpoint_ _cluster_ _attribute_ _type_ _min_ _max_ [_change_]
	Configure how the device reports an attribute: at least _min_ and at
	most _max_ seconds apart, and when it changes by _change_, for analog
	types.

*bind* _device_ _endpoint_ _cluster_, *unbind* _device_ _endpoint_ _cluster_
	Bind the cluster to the coordinator, so that the device sends it reports
	and commands, or remove the binding.

*command* _device_ _endpoint_ _cluster_ _command_ [_type_:_value_...]
	Send a cluster command, with its arguments in order, such as
	uint8:128 uint16:10.

*on*, *off* _device_ [_endpoint_]
	Switch the device on or off, as *set* does: the first endpoint that can
	be switched, unless given.

*toggle* _device_ [_endpoint_]
	Switch the device the other way, with the Toggle command of the On/Off
	cluster of the endpoint, 1 by default.

*watch*
	Print what happens on the network, one event per line, until
	interrupted: its time in UTC, the device, and what happened, such as
	the readings it reported.

# OPTIONS

Options go before or after the command, as in _skep --timeout 600 read
thermometre temperature_ or _skep read thermometre temperature --timeout
600_. An argument that starts with -- goes after a *--*.

*--socket* _path_
	skepd's socket. By default, _$SKEP_SOCKET_; without it,
	_$XDG_RUNTIME_DIR/skep/skepd.sock_, then _/run/skep/skepd.sock_. A socket
	given, by this option or by _$SKEP_SOCKET_, is the only one tried.

*--json*
	Print skepd's answers, and events, as it sends them: JSON, one per line.

*--timeout* _seconds_
	How long a request to a device may wait, for a sleepy device to wake up
	among others. Without it, requests wait as long as it takes, except
	*remove*.

*--help*, *--version*
	Print how to use skep, or its version. With a command, *--help* prints
	how to use that command, as in _skep set --help_.

# ERRORS

A mistake on the command line is told with the command, the argument, and
what is wrong with it, then how to use the command:

```
skep set: missing <value>; "color_temperature" was taken as <device>, "1000K" as <reading>
usage: skep [<options>] set <device> <reading> <value> [--transition <seconds>]
skep set --help tells more.
```

What skepd refuses, or a device, is told the same way: _skep set: no
reading levl; it can set on, level, color_temperature, hue, saturation and
color_. *--json* shows skepd's answers as they are, with their error
codes.

# EXIT STATUS

0 when the request was done; 1 when it failed, skepd could not be reached,
or the device refused it, with a status other than 0; 2 when the command
line is wrong.

# EXAMPLES

```
skep permit 60
skep devices
skep rename f44250000d350000 "living room"
skep get "living room" temperature
skep --timeout 600 read "living room" temperature
skep read plug power
skep set bulb off
skep set bulb level 30 --transition 2
skep set bulb color "#ff8000"
skep off plug
skep --json watch | jq -c 'select(.event == "attributes")'
```

# SEE ALSO

*skepd*(8), *skep-protocol*(7)
