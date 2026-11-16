skep-protocol(7)

# NAME

skep-protocol - how clients talk to skepd

# DESCRIPTION

*skepd*(8) runs a Zigbee network and serves clients, such as *skep*(1), on a
Unix stream socket. Clients ask it things with requests; it answers each
with a response, and sends events to the clients that asked for them.

Messages are JSON objects (RFC 8259) in UTF-8, one per line: each ends with
a newline, and contains none.

# SOCKET

skepd listens on _$RUNTIME_DIRECTORY/skepd.sock_ (_/run/skep/skepd.sock_) when
run as a system service, on _$XDG_RUNTIME_DIR/skep/skepd.sock_ otherwise.
Clients look for it in _$SKEP_SOCKET_, then at those two paths.

Whoever can connect has full control of the network: opening it to new
devices, removing devices, sending them commands. Who can is decided by the
socket's directory: skepd creates _$XDG_RUNTIME_DIR/skep_ for its owner only,
and the system service's unit creates _/run/skep_ for its owner and group. The
socket itself is readable and writable by its owner and group.

skepd serves any number of clients at once.

# REQUESTS AND RESPONSES

A request names a method, and carries an id of the client's choosing, which
its response repeats:

```
{"id": 1, "method": "permit_join", "params": {"seconds": 60}}
```

"params" may be left out when there are none. Ids are integers, unique
among the client's pending requests.

Each request gets exactly one response, once it is done. Requests to a
sleepy device wait until the device wakes up, which can take hours, so
responses come in the order requests end, not the order they were made,
and a client may make more requests while it waits. A response holds a
result, an object:

```
{"id": 1, "result": {}}
```

or an error, whose "code" is the name of a POSIX errno value, and whose
"message" is for people to read, not for programs to parse:

```
{"id": 1, "error": {"code": "EINVAL", "message": "seconds: at most 254"}}
```

A request that cannot be read as one, not JSON or without an id, gets an
error whose "id" is null. Empty lines are ignored.

A response reflects every event sent before it on the same connection: a
client that sends *watch*, then *devices*, has a list that the events after
it update.

# CONNECTIONS

A client that shuts down its sending side, as _echo request | socat_ does,
has made its last request: skepd still answers its pending requests, and
sends it events if it watches, then closes the connection once nothing is
pending and it does not watch. Closing the connection altogether cancels the
client's pending requests.

A client's lines are at most 65536 bytes, newline included. skepd answers a
longer one with an *EMSGSIZE* error whose "id" is null, and closes the
connection, since it cannot tell where the next line starts. skepd's lines
have no such limit: a list of many devices can be longer.

A client that leaves more than a mebibyte unread, such as one that watches
events and stops reading them, is disconnected. Once connected again, it
asks for *devices* to learn what it missed.

# EVENTS

Events tell what happens on the network. skepd sends them to the clients
that sent a *watch* request, from then on, as long as they stay connected:

```
{"event": "device_joined", "time": "2026-11-16T20:29:51.935Z", "device": "f44250000d350000"}
```

"time" is when skepd learnt of it, in UTC, as ISO 8601 with milliseconds.
jq's _fromdateiso8601_ does not take the milliseconds: drop them first, with
_sub("\\\\.[0-9]+Z$"; "Z")_.

# COMPATIBILITY

Newer versions of skepd add methods, events, members of results and events,
and values: strings such as a device's "type" or a ZCL type's name, and
error codes. Clients ignore the events and members they do not know, and
accept the values they do not know.

skepd refuses a request with a member it does not know, at the top level or
in "params", with *ENOTSUP*, and a method it does not know with *ENOSYS*: a
client that relies on something new learns that skepd is too old, instead
of having it ignored. A value it cannot take is *EINVAL*.

The protocol's version, which *version* gives, changes only when a change
would break existing clients.

# VALUES

IEEE addresses are strings of 16 lowercase hexadecimal digits, most
significant first, as devices print them: "f44250000d350000". So is the
extended PAN ID. skepd takes them in uppercase and with "0x" too.

Other numbers are JSON numbers: network addresses, PAN IDs, endpoints,
profiles, clusters, attributes, commands, manufacturer codes and statuses.
skepd takes them as strings of hexadecimal digits after "0x" too, such as
"0x0402", as the Zigbee specifications write them.

A device can be named, with *rename*. Wherever a request takes a "device",
it takes its IEEE address or its name. A name is 1 to 64 bytes of UTF-8,
without control characters, unique, and never 16 hexadecimal digits, with
or without "0x", so that it cannot be taken for an address.

ZCL values carry their type:

```
{"type": "int16", "value": 2154}
```

The types are named after the ZCL: "nodata", "data8" to "data64", "bool",
"bitmap8" to "bitmap64", "uint8" to "uint64", "int8" to "int64", "enum8",
"enum16", "semi", "single", "double", "octet_string", "char_string",
"long_octet_string", "long_char_string", "array", "struct", "set", "bag",
"time_of_day", "date", "utc", "cluster_id", "attribute_id", "bacnet_oid",
"ieee_address" and "key128". A type without a name is its number, and its
value the hexadecimal digits of its encoding.

- "bool" is a JSON boolean.
- Integers, data, bitmaps, enumerations, times and ids are numbers, except
  the types of 56 and 64 bits, which are always strings of decimal digits,
  even for small values: not every JSON parser keeps more than 53 bits of a
  number. skepd takes either for them.
- "ieee_address" is 16 hexadecimal digits, as above.
- Floats are numbers, "single" at single precision, or null for those JSON
  cannot hold (NaN, infinities).
- Character strings are strings. Bytes that are not UTF-8 become U+FFFD.
- Octet strings and keys are hexadecimal digits: their bytes, without the
  length of strings.
- Arrays, sets, bags and structures are hexadecimal digits: their ZCL
  encoding as it is, element type and count first for arrays, sets and
  bags, count first for structures.
- "nodata" has no "value".

# METHODS

*version*
	The protocol's version, and skepd's.
	Result: {"protocol": 1, "skepd": "0.1.0"}

*watch*
	Send events to this client, from now on.
	Result: {}

*network*
	The network. When it is up: {"up": true, "channel": 15, "pan_id": 17784,
	"extended_pan_id": "8a4f7ca9954c4cd5", "permit_join": _seconds left_, 0
	when no device may join}. When it is not: {"up": false}, with the
	"error" that took it down, if one did, such as "EEXIST" when the dongle
	holds another network.

*permit_join* {"seconds": _0 to 254_}
	Let new devices join for that long, or stop letting them with 0. Done
	once the coordinator and the routers have been told.
	Result: {}

*devices*
	The devices of the network, the coordinator aside.
	Result: {"devices": [_device_, ...]}

*device* {"device": _device_}
	One device.
	Result: _device_

*rename* {"device": _device_, "name": _name_ or null}
	Name a device, or forget its name. A name already taken is *EEXIST*.
	Result: {}

*setup* {"device": _device_}
	Interview and set the device up again, from the start. Done once
	started: the *device_ready* or *device_setup_failed* event tells how it
	went.
	Result: {}

*remove* {"device": _device_}
	Ask the device to leave the network, and forget it and its name, whether
	it answered or not. Done once forgotten.
	Result: {"status": _ZDO status_} if it answered, {} if not.

*read* {_target_, "attributes": [_id_, ...]}
	Read attributes.
	Result: {"status": _ZCL status_, "attributes": [{"id": _id_, "status":
	_ZCL status_, "type": ..., "value": ...}, ...]}, a type and value for each
	attribute whose status is 0. "attributes" is left out when the device
	refused the whole request, with a status other than 0.

*write* {_target_, "attributes": [{"id": _id_, "type": ..., "value": ...}, ...]}
	Write attributes.
	Result: {"status": _ZCL status_, "attributes": [{"id": _id_, "status":
	_ZCL status_}, ...]}

*configure_reporting* {_target_, "reporting": [_reporting_, ...]}
	Configure how attributes are reported. A _reporting_ is {"id": _id_,
	"type": ..., "min_interval": _seconds_, "max_interval": _seconds_,
	"change": _value_}: "change" is a value of the attribute's type, without
	its own "type", which analog types (integers, floats, times) need and the
	others do without.
	Result: {"status": _ZCL status_, "attributes": [{"id": _id_, "status":
	_ZCL status_}, ...]}

*bind*, *unbind* {_target_}
	Bind the target's cluster to the coordinator, so that the device sends it
	reports and commands, or remove the binding.
	Result: {"status": _ZDO status_}

*command* {_target_, "command": _id_, "arguments": [{"type": ..., "value":
...}, ...]}
	Send a cluster command, with its arguments in order; "arguments" may be
	left out when there are none.
	Result: {"status": _ZCL status_}, the status of the device's Default
	Response, 0 if it sent none.

*cancel* {"id": _id_}
	Give up a pending request of this client, which ends with *ECANCELED*. A
	request already sent may still take effect. An id that is not pending is
	*ENOENT*.
	Result: {}

A _target_ is the members "device", "endpoint" and "cluster", and
"manufacturer_code" for manufacturer-specific clusters, attributes and
commands.

Requests to devices (*remove*, *read*, *write*, *configure_reporting*,
*bind*, *unbind*, *command*) take a "timeout" too: how long, in seconds,
fractions allowed, the request may wait, for a sleepy device to wake up
among others. Without one, it waits as long as it takes.

Their result's "status" is what the device answered: a request it refused
has a result, not an error. Errors say that the request did not get there
or back, or that it cannot be made:

- *ETIMEDOUT*: no answer in time.
- *EHOSTUNREACH*: the device could not be reached.
- *ECANCELED*: canceled with *cancel*; replaced, if it was a *write* or a
  *configure_reporting* still waiting, by a newer one for the same
  attributes of the same target, from any client; or given up because the
  network went down.
- *ENODEV*: no such device.
- *ENETDOWN*: the network is not up.
- *ENOBUFS*: too many requests pending: 32 for all clients together, 16
  for one client.
- *EINVAL*, *ENOTSUP*: a request that is not right, as above. A request
  takes at most 16 attributes.
- *EEXIST*: an id already pending, for any method.

# DEVICES

A _device_ is an object with what is known of it so far; members appear as
the interview learns them:

```
{
  "device": "f44250000d350000",
  "name": "living room",
  "network_address": 7118,
  "type": "end_device",
  "manufacturer_code": 5127,
  "rx_on_when_idle": false,
  "manufacturer": "Third Reality",
  "model": "3RTHS0224Z",
  "endpoints": [
    {"endpoint": 1, "profile": 260, "device_type": 770,
     "input_clusters": [0, 1, 3, 32, 1026, 1029], "output_clusters": [25]}
  ],
  "setup": "ready"
}
```

(shown on several lines here; on the socket, it is on one.) "type" is
"coordinator", "router" or "end_device". "setup" is "pending" while the
device is interviewed and set up, or waits to wake up to go on, "ready" once
done, and "failed" when it refused a step.

# EVENT TYPES

Each event has the members "event" and "time", and those listed here. Those
about a device have "device", and "name" if it has one.

*network_up* {"origin": "resumed", "restored" or "formed", "channel",
"pan_id", "extended_pan_id"}
	The network is up.

*network_down* {"error": _errno name_}
	The network went down, for instance with "ENOTCONN" when the dongle went
	away.

*permit_join* {"seconds": _seconds_}
	The join window opened for that long, or closed (0).

*device_joined*, *device_ready*
	A device joined, or is set up.

*device_left* {"removed": _boolean_}
	A device left the network: by itself, and it may come back; or removed
	with *remove*, and forgotten.

*device_setup_failed* {"status": _status_} or {"error": _errno name_}
	Setting a device up failed: it refused a step with that status, or the
	error tells why. One of the two members is there, never both.

*device_renamed* {"old_name": _name_}
	A device got a new name, or lost its name. "old_name" is left out when it
	had none, "name" when it has none now.

*attributes* {"endpoint", "cluster", "manufacturer_code",
"attributes": [{"id": _id_, "type": ..., "value": ...}, ...]}
	A device reported attributes. "manufacturer_code" only for
	manufacturer-specific frames.

*command* {"endpoint", "cluster", "manufacturer_code", "command",
"payload": _hexadecimal_, "arguments": [{"type": ..., "value": ...}, ...]}
	A device sent a cluster command. "payload" is its arguments in their
	ZCL encoding; "arguments" has them decoded, for the commands libskep
	knows.

# EXAMPLE

A client opens the join window, then watches a device join and report:

```
> {"id": 1, "method": "watch"}
< {"id": 1, "result": {}}
> {"id": 2, "method": "permit_join", "params": {"seconds": 60}}
< {"event": "permit_join", "time": "...", "seconds": 60}
< {"id": 2, "result": {}}
< {"event": "device_joined", "time": "...", "device": "f44250000d350000"}
< {"event": "device_ready", "time": "...", "device": "f44250000d350000"}
< {"event": "attributes", "time": "...", "device": "f44250000d350000",
   "endpoint": 1, "cluster": 1026, "attributes": [{"id": 0, "type":
   "int16", "value": 2154}]}
```

From a shell, with *socat*(1):

```
echo '{"id": 1, "method": "devices"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/skep/skepd.sock
```

For a request that may wait, give socat time: _socat -t 3600_.

# SEE ALSO

*skep*(1), *skepd*(8)
