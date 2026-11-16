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

# COMMANDS

*version*
	The versions of skepd and of its protocol.

*network*
	Whether the network is up, its channel, PAN ID and extended PAN ID, and
	how long devices may still join.

*permit* [_seconds_]
	Let new devices join for that long, 60 seconds by default, at most 254;
	0 stops letting them.

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
	that sleeps; skepd forgets the values when it restarts, until the
	devices report again.

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

*on*, *off*, *toggle* _device_ [_endpoint_]
	Switch the device on, off, or the other way, with the On/Off cluster of
	the endpoint, 1 by default.

*watch*
	Print what happens on the network, one event per line, until
	interrupted: its time in UTC, the device, and what happened, such as
	the readings it reported.

# OPTIONS

*--socket* _path_
	skepd's socket. By default, _$SKEP_SOCKET_, then
	_$XDG_RUNTIME_DIR/skep/skepd.sock_, then _/run/skep/skepd.sock_.

*--json*
	Print skepd's answers, and events, as it sends them: JSON, one per line.

*--timeout* _seconds_
	How long a request to a device may wait, for a sleepy device to wake up
	among others. Without it, requests wait as long as it takes, except
	*remove*.

*--help*, *--version*
	Print how to use skep, or its version.

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
skep off plug
skep --json watch | jq -c 'select(.event == "attributes")'
```

# SEE ALSO

*skepd*(8), *skep-protocol*(7)
