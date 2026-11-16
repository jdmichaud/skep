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
	The devices, one per line: address, name, model, type, and how far their
	setup got (pending, ready or failed).

*device* _device_
	One device, in detail: what its interview found, its endpoints and
	clusters.

*rename* _device_ [_name_]
	Give the device a name, or forget its name without one.

*setup* _device_
	Interview the device and set it up again, from the start.

*remove* _device_
	Make the device leave the network, and forget it. It gives up waiting
	for an answer after 60 seconds, or *--timeout*: the device is forgotten
	either way.

*read* _device_ _endpoint_ _cluster_ _attribute_...
	Read attributes: their values and types, or the status the device gave.

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
	interrupted.

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
skep read "living room" 1 0x0402 0
skep off plug
skep --json watch | jq -c 'select(.event == "attributes")'
```

# SEE ALSO

*skepd*(8), *skep-protocol*(7)
