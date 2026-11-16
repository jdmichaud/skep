skep-protocol(7)

# NAME

skep-protocol - how clients talk to skepd

# DESCRIPTION

*skepd*(8) runs a Zigbee network and serves clients, such as *skep*(1), on a
Unix stream socket. Clients ask it things with requests; it answers each
with a response, and sends events to the clients that asked for them.

Messages are JSON objects (RFC 8259) in UTF-8, one per line: each ends with
a newline, and contains none. A line is at most 65536 bytes.

# SOCKET

skepd listens on _$XDG_RUNTIME_DIR/skep/skepd.sock_ when run as a user
service, on _$RUNTIME_DIRECTORY/skepd.sock_ (_/run/skep/skepd.sock_) as a
system service. Only its owner can connect: the directory is readable by
its owner only. skepd serves any number of clients at once.

# REQUESTS AND RESPONSES

A request names a method, and carries an id of the client's choosing, which
its response repeats:

```
{"id": 1, "method": "permit-join", "params": {"seconds": 60}}
```

_params_ may be left out when there are none. Ids are integers; a client
keeps them unique among its pending requests.

Each request gets exactly one response, once it is done. Requests to a
sleepy device wait until the device wakes up, which can take hours, so
responses come in the order requests end, not the order they were made,
and a client may make more requests while it waits. A response holds a
_result_, an object:

```
{"id": 1, "result": {}}
```

or an _error_, whose _code_ is the name of a POSIX errno value, and whose
_message_ is for people to read, not for programs to parse:

```
{"id": 1, "error": {"code": "EINVAL", "message": "seconds: at most 254"}}
```

A request that cannot be read as one, not JSON or without an id, gets an
error response whose _id_ is null.

When a client disconnects, its pending requests are canceled.

# EVENTS

Events tell what happens on the network. skepd sends them to the clients
that sent a *watch* request, from then on, as long as they stay connected:

```
{"event": "device-joined", "time": "2026-11-16T20:29:51.935Z", "device": "f44250000d350000"}
```

_time_ is when skepd learnt of it, in UTC, as ISO 8601 with milliseconds.

# COMPATIBILITY

Newer versions of skepd add methods, events, and members to results and
events. Clients ignore events and members they do not know.

skepd refuses a request with members of _params_ it does not know
(*EINVAL*), and methods it does not know (*ENOSYS*): a client that relies on
something new learns that skepd is too old, instead of having it ignored.

The protocol's version, which *version* gives, changes only when a change
would break existing clients.

# VALUES

IEEE addresses are strings of 16 lowercase hexadecimal digits, most
significant first, as devices print them: "f44250000d350000". So is the
extended PAN ID.

Everything else with a number is a JSON number: network addresses, PAN IDs,
endpoints, profiles, clusters, attributes, commands, manufacturer codes and
statuses.

A device can be named, with *rename*. Wherever a request takes a _device_,
it takes its IEEE address or its name. Names are 1 to 64 characters, unique,
and never 16 hexadecimal digits, so they cannot be taken for an address.

ZCL values carry their type, named as in *skep.h* without the SKEP_TYPE_
prefix, in lowercase:

```
{"type": "int16", "value": 2154}
```

- Booleans are JSON booleans.
- Integers, bitmaps, enumerations, data, times and ids are numbers, except
  those wider than 48 bits, which are strings of decimal digits: not every
  JSON parser keeps more than 53 bits of a number.
- Floats are numbers, or null for those JSON cannot hold (NaN, infinities).
- Character strings are strings. Bytes that are not UTF-8 become U+FFFD.
- Octet strings, keys, and arrays, sets, bags and structures are strings of
  lowercase hexadecimal digits: the bytes of their ZCL encoding, without the
  length of strings.
- _nodata_ has no _value_.

# METHODS

*version*
	The protocol's version, and skepd's.
	Result: {"protocol": 1, "skepd": "0.1.0"}

*watch*
	Send events to this client, from now on.
	Result: {}

*network*
	The network, if it is up.
	Result: {"up": true, "channel": 15, "pan_id": 17784, "extended_pan_id":
	"8a4f7ca9954c4cd5"}, or {"up": false}.

*permit-join* {"seconds": _0 to 254_}
	Let new devices join for that long, or stop letting them with 0. Done
	once the coordinator and the routers have been told.
	Result: {}

*devices*
	The devices of the network.
	Result: {"devices": [_device_, ...]}

*device* {"device": _device_}
	One device.
	Result: _device_

*rename* {"device": _device_, "name": _name_ or null}
	Name a device, or forget its name.
	Result: {}

*setup* {"device": _device_}
	Interview and set the device up again, from the start. Done once started:
	the *device-ready* or *device-setup-failed* event tells how it went.
	Result: {}

*remove* {"device": _device_}
	Ask the device to leave the network, and forget it, whether it answered
	or not.
	Result: {"status": _ZDO status_}

*read* {_target_, "attributes": [_id_, ...]}
	Read attributes.
	Result: {"status": _ZCL status_, "attributes": [{"id": _id_, "status":
	_ZCL status_, "type": ..., "value": ...}, ...]}, with a type and value for
	each attribute whose status is 0.

*write* {_target_, "attributes": [{"id": _id_, "type": ..., "value": ...}, ...]}
	Write attributes.
	Result: {"status": _ZCL status_, "attributes": [{"id": _id_, "status":
	_ZCL status_}, ...]}

*configure-reporting* {_target_, "reporting": [_reporting_, ...]}
	Configure how attributes are reported. A _reporting_ is {"attribute":
	_id_, "type": ..., "min_interval": _seconds_, "max_interval": _seconds_,
	"change": _value_}, the change in the attribute's type, for analog types
	only.
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
	request already sent may still take effect.
	Result: {}

A _target_ is the members "device", "endpoint" and "cluster", and
"manufacturer_code" for manufacturer-specific clusters, attributes and
commands.

Requests to devices (*remove*, *read*, *write*, *configure-reporting*,
*bind*, *unbind*, *command*) take a "timeout" too, in seconds: how long the
request may wait, for a sleepy device to wake up among others. Without
one, it waits as long as it takes.

Their result's _status_ is what the device answered: a request it refused
has a result, not an error. Errors say the request did not get there or
back: *ETIMEDOUT*, *EHOSTUNREACH*, *ECANCELED*; or that it cannot be made:
*ENODEV* (no such device), *ENETDOWN* (the network is not up), *EINVAL*,
*ENOBUFS* (too many requests pending).

# DEVICES

A _device_ is an object with what is known of it so far; members appear as
the interview learns them:

```
{
  "device": "f44250000d350000",
  "name": "living room",
  "address": 7118,
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

(shown on several lines here; on the socket, it is on one.) _type_ is
"coordinator", "router" or "end_device". _setup_ is "pending" while the
device is interviewed and set up, "ready" once done, "failed" when it
refused a step.

# EVENTS

Each event has the members _event_ and _time_, and those listed here. Those
about a device have _device_, and _name_ if it has one.

*network-up* {"origin": "resumed", "restored" or "formed", "channel",
"pan_id", "extended_pan_id"}
	The network is up.

*network-down* {"error": _errno name_}
	The network went down, for instance ENOTCONN when the dongle went away.

*permit-join* {"seconds": _seconds_}
	The join window opened for that long, or closed (0).

*device-joined*, *device-left*, *device-ready*
	A device joined, left, or is set up.

*device-setup-failed* {"error": _errno name_, "status": _status_}
	Setting a device up failed: it refused a step with that status, or the
	error tells why.

*attributes* {"endpoint", "cluster", "manufacturer_code",
"attributes": [{"id": _id_, "type": ..., "value": ...}, ...]}
	A device reported attributes. _manufacturer_code_ only for
	manufacturer-specific frames.

*command* {"endpoint", "cluster", "manufacturer_code", "command",
"payload": _hexadecimal_}
	A device sent a cluster command, its arguments in their ZCL encoding.

# EXAMPLE

A client opens the join window, then watches a device join and report:

```
> {"id": 1, "method": "watch"}
< {"id": 1, "result": {}}
> {"id": 2, "method": "permit-join", "params": {"seconds": 60}}
< {"event": "permit-join", "time": "...", "seconds": 60}
< {"id": 2, "result": {}}
< {"event": "device-joined", "time": "...", "device": "f44250000d350000"}
< {"event": "device-ready", "time": "...", "device": "f44250000d350000"}
< {"event": "attributes", "time": "...", "device": "f44250000d350000",
   "endpoint": 1, "cluster": 1026, "attributes": [{"id": 0, "type":
   "int16", "value": 2154}]}
```

# SEE ALSO

*skep*(1), *skepd*(8)
