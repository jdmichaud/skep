# skep design

Status: draft, agreed on 2026-11-14 before any code was written. When a
decision changes, update this document in the same commit as the change.

## Goal

A small, native Zigbee stack for Linux that is driven from the terminal
and follows Unix conventions. Version 1 pairs and uses a temperature and
humidity sensor, a colour light bulb and a smart plug with energy metering
(see [hardware.md](hardware.md)). skep replaces Zigbee2MQTT for our use;
it does not try to match its device coverage.

skep is not tied to a particular dongle. The ZBDongle-E is the one we
develop with, so its driver comes first; other dongles are added as
drivers without changes to the rest of the stack.

## Components

```
  skep (CLI)    scripts, socat
       |             |
       +------+------+
              |  Unix socket, line-delimited JSON (skep-protocol(7))
              v
        skepd (daemon)  <---- serial port ---->  dongle
              |              (skepd does all I/O)
              |  C API, <skep.h>: bytes, time, state, requests, events
              v
        libskep (Zigbee logic, no I/O)
              |  driver interface
       +------+---------------+----------------+
       v                      v                v
  ezsp driver          sim driver        later: zstack, deconz, ...
  (ASH, EZSP: for Silicon Labs           (for TI Z-Stack, ConBee, ...
  EmberZNet dongles)                     dongles)
```

Names: the project is skep (a woven straw beehive). The library is
`libskep`, its header `<skep.h>`, its C prefix `skep_` (macros `SKEP_`),
the daemon `skepd` and the command-line tool `skep`.

## Language and build

- Zig, pinned to 0.17.0 (`minimum_zig_version` in `build.zig.zon`).
  Upgrading Zig is a deliberate change of its own.
- Why Zig: exporting a C ABI is native to the language, and skepd consumes
  libskep through `skep.h`, exactly like an outside user would: the build
  translates the header with a translate-c step (`b.addTranslateC`; Zig
  0.17 no longer has `@cImport`) and skepd imports the result. The work
  is mostly byte-level protocol code and a single-threaded poll loop. One
  build system produces the libraries, header, pkg-config file, man
  pages, systemd units and static musl binaries.
- Why not Rust: using our own C API from Rust means bindgen declarations
  and `unsafe` calls into our own code, and Rust's safety stops at that
  boundary, which skepd crosses on every call. Linking is not the
  obstacle: skepd could link libskep as an rlib and call its exported C
  functions without duplicating the standard library. The choice rests
  on the points above, not on Rust being unable to do it.
- Zig gives fewer safety guarantees than Rust, and we parse input that
  anything in radio range can send. To compensate: release builds use
  `ReleaseSafe` (bounds and overflow checks stay on), tests use
  `std.heap.DebugAllocator` to catch leaks and misuse, and every parser
  of external input has a fuzz test.
- No dependencies outside the Zig standard library unless agreed first.

## Dongle drivers

- The driver boundary is at the network co-processor (NCP) level. The
  dongle firmware runs the Zigbee stack (network layer, APS, security,
  trust center); a driver exchanges APS frames and network management
  requests with it. Dongles of this kind (Silicon Labs EZSP, TI Z-Stack,
  deCONZ, ...) are interchangeable behind the interface.
- Initial driver operations:
  - reset the dongle's stack and the link to it;
  - read the network state, form a network (channel, PAN ID, extended
    PAN ID, network key), resume an existing network;
  - permit joining for a number of seconds;
  - send an APS frame by unicast, multicast (group) or broadcast;
  - report events: incoming APS frame, device joined, left or announced,
    send confirmation, stack status change;
  - back up and restore the network parameters and keys.
- Drivers are internal to libskep and selected at run time by name, with
  the `driver` option (`ezsp`, `sim`). They never open the dongle or
  configure the serial port: the caller does, with the settings the driver
  suggests (`skep_get_serial_defaults()`), and passes the bytes.
- Software flow control (XON/XOFF) is handled by libskep: the driver
  pauses its output on XOFF, so the caller opens the port in raw mode
  whatever the dongle uses. XON or XOFF arriving when the driver expects
  no software flow control means the firmware and the serial settings
  disagree; libskep logs a warning.
- First drivers: `ezsp` (Silicon Labs EmberZNet NCP over ASH, used by the
  ZBDongle-E) and `sim` (a simulated network for tests). Having two
  drivers from day one keeps the interface honest.
- The `ezsp` driver negotiates the protocol version with the dongle at
  start-up and requires EZSP 13 (EmberZNet 7.4) or newer, the same
  minimum as zigbee-herdsman's `ember` driver. Dongles with older
  firmware are flashed rather than supported: versions before 13 differ
  in frame layouts and behaviour, and current releases are freely
  available. Version-specific layouts are kept apart, so that newer
  versions can be added.
- Nothing outside a driver may depend on a particular dongle, chip or
  firmware.
- Out of scope: radio co-processors (RCP), which need a full Zigbee stack
  on the host.

## C API

The API is drafted in [include/skep.h](../include/skep.h), to be
reviewed before the library is implemented.

- libskep does no I/O. It never opens, reads or writes a device or a
  file, never reads the clock and never blocks (the "sans-I/O" design of
  protocol libraries such as ngtcp2 or quiche). The caller:
  - opens the dongle, with the serial settings the driver suggests
    (`skep_get_serial_defaults()`), and reconnects when it disappears;
  - passes the bytes it reads to `skep_input()` and writes the bytes from
    `skep_output()`;
  - tells libskep the time, from a monotonic clock in milliseconds, and
    calls `skep_advance()` by the deadline from `skep_next_deadline()`;
  - stores libskep's state (see below).
- Why: the timers are part of the protocol and stay in libskep, but
  waiting is not. Without I/O, libskep has no operating-system code and is
  portable; its tests drive it with bytes and time and run instantly and
  deterministically, timeouts and retransmissions included; and the
  transport is the caller's choice (serial port, a coordinator reached
  over TCP, a replayed capture). The cost is an I/O loop in every
  application, 60 to 100 lines, of which skepd is the reference and
  `skep.h` shows a minimal one (compiled by the header checks).
- Time only enters through `skep_input()`, `skep_output_done()` and
  `skep_advance()`. Other calls only queue work, whose timers start when
  its bytes are written, so a request made after a long idle time does not
  start its timeout from a stale clock.
- State: what must survive a restart or a new dongle (network parameters
  and keys, device registry) is exported and imported as opaque bytes
  (`skep_export_state()`, `skep_import_state()`). `SKEP_EVENT_STATE_CHANGED`
  says when to save it. libskep reads states written by any older version.
- No threads inside libskep and no callbacks into caller code. Results
  are events, drained with `skep_next_event()`. Diagnostics are events
  too (`SKEP_EVENT_LOG`); libskep never writes to stdout or stderr, with
  one exception: a failed safety check (see "Language and build") aborts
  the program with a message, like a failed `assert()`. Such a failure is
  a bug in libskep; carrying on with corrupted state would be worse.
- Opaque handles (`skep_ctx`, `skep_event`), created and destroyed in
  pairs. The ownership of every returned pointer is documented.
- Functions return an `int`: 0 on success, a negative errno value on
  failure (`-EINVAL`, `-ETIMEDOUT`, `-ENETDOWN`, ...), as libsystemd,
  libinput and liburing do. `strerror(-r)` describes an error; there are
  no skep-specific error codes to learn. A device's answer to a request
  is not an error code: its ZCL status is reported separately.
- The application chooses the driver and the parameters of a new network
  with `skep_set_option()` before `skep_start()`; only the log level can
  be changed later, so that a running skepd can be made more verbose.
  Options are strings so that they map directly to a configuration file. Nothing else in
  `skep.h` depends on the dongle.
- Devices are identified by their IEEE address, which never changes.
- Requests to devices (read, write, configure reporting, bind, commands)
  are asynchronous. Each returns a request id and ends with exactly one
  `SKEP_EVENT_REQUEST_DONE` event.
- libskep interviews and sets up new devices itself, using the device
  tables, and reports `SKEP_EVENT_DEVICE_READY` when done.
- No global state: everything libskep knows is in a context, which the
  application holds as an opaque handle. The application decides when a
  context is created and freed; only libskep reads or changes what is
  inside. Separate contexts are independent, so one program can drive
  several dongles, and use different contexts from different threads at
  the same time. A context is used by one thread at a time. In the
  implementation, this rules out:
  - Zig's `std.log`, whose configuration is global to the program and
    which writes to stderr. Log messages are events of the context they
    come from, filtered by that context's `log-level`;
  - an allocator of libskep's own: all memory comes from the context's
    allocator (below).
- Events hold copies of what they report and outlive the context they
  came from: an application can free a context and still handle the
  events it took from it.
- Memory: the application passes an allocator (`struct skep_allocator`)
  to `skep_new()`, or NULL for `malloc()`. Everything the context
  allocates, events included, comes from it. Inside libskep, functions
  that allocate take an `std.mem.Allocator`, as in any Zig code; the
  context's allocator, wrapped once at creation, is the only one.
  - Why: tests make each allocation fail in turn through the C API
    (`std.testing.checkAllAllocationFailures`) to check every `-ENOMEM`
    path; the C library's allocator is only a default, not a dependency;
    applications can use an arena or cap a context's memory.
  - Shape: set per context, like Lua's `lua_newstate()` (SQLite and libuv
    configure theirs globally). Every function takes a context pointer
    and gets back the size of the block (Chris Wellons' checklist for C
    allocator interfaces), and an alignment, which Zig's allocators need
    and `lua_Alloc` lacks. `alloc` and `free` are required; `realloc` is
    optional; reserved slots leave room for more. It maps onto
    `std.mem.Allocator` without loss: `alloc` and `free` directly,
    `realloc` as `remap`, and resizing in place is refused.
  - Not chosen: allocating everything up front, sized by options, as
    TigerBeetle does. It would take allocation failures out of protocol
    handling, but it caps the number of devices and puts events in fixed
    slots of the context, so they could not outlive it.
- Semantic versioning. The soname major number is the ABI version.
  `skep_version()` and the `SKEP_VERSION_*` macros report the version; a
  test checks that the macros match `build.zig.zon`. The header and
  `libskep.pc` are installed. Both a static and a shared library are
  built.
- The build checks that `skep.h` compiles as strict C99 and as C++, and
  that it translates to Zig.

## skepd

- The only process that opens the dongle, and the one doing all of
  libskep's I/O: it opens the serial port (with the driver's serial
  defaults unless `skepd.conf` overrides them), runs the poll loop, keeps
  time, reopens the dongle when it disappears, and saves libskep's state
  whenever it changes.
- Runs in the foreground and never daemonizes itself. Under systemd it
  uses `Type=notify` and reports readiness with sd_notify.
- Logs to stderr; journald adds timestamps. The log level is configurable.
- SIGTERM and SIGINT shut it down cleanly; SIGHUP reloads the
  configuration.
- Serves clients on a Unix stream socket with line-delimited JSON
  requests, responses and events, documented in skep-protocol(7).
- Uses libskep only through `<skep.h>`.
- Ships a systemd user unit and a system unit.

## skep

- A thin client of the skepd socket; it contains no Zigbee logic.
- Subcommands such as `skep permit 60`, `skep devices`, `skep rename`,
  `skep watch`. The exact set is settled in skep(1).
- `--help` and `--version`; data on stdout, diagnostics on stderr. Human
  readable output by default, `--json` for scripts. Exit status 0 on
  success, 1 on failure, 2 on usage errors.

## Files

| What | User service | System service |
|---|---|---|
| Configuration | `$XDG_CONFIG_HOME/skep/skepd.conf` | `$CONFIGURATION_DIRECTORY/skepd.conf` (`/etc/skep`) |
| State exported by libskep (network, keys, devices), friendly names | `$XDG_DATA_HOME/skep/` | `$STATE_DIRECTORY/` (`/var/lib/skep`) |
| Socket | `$XDG_RUNTIME_DIR/skep/skepd.sock` | `$RUNTIME_DIRECTORY/skepd.sock` (`/run/skep`) |

skepd creates files holding keys, such as the state, with mode 0600 and
replaces them atomically. The socket is not accessible to other users.

## Documentation

- Man pages: skep(1), skepd(8), libskep(3) (plus per-function pages as the
  API settles), skepd.conf(5) and skep-protocol(7).
- `README.md` stays minimal. Developer documentation lives in `doc/`.

## Scope of version 1

In scope:

- form or resume the network, permit joining;
- interview new devices (node descriptor, endpoints, clusters, basic
  attributes);
- bind clusters and configure attribute reporting;
- read and write attributes, including manufacturer-specific ones;
- send cluster commands (on/off, level, colour);
- events for attribute reports, joins and leaves;
- a device registry with friendly names, and a network backup.

Device-specific knowledge (which clusters to bind and report, reporting
intervals, manufacturer-specific attributes, and corrections for values a
device reports wrongly, such as scale factors) is kept in small data
tables, not in per-device code.

Not in version 1: MQTT (possible later as a separate bridge speaking
skep-protocol), OTA firmware updates, groups and scenes, Touchlink, Green
Power, RCP drivers, and a device database like Zigbee2MQTT's.

## Testing

- Unit tests for every codec, using byte sequences captured from real
  dongles where possible.
- libskep is tested by feeding it bytes and time: timeouts,
  retransmissions and sleepy devices are tested without waiting, and
  every run is the same.
- The `sim` driver lets libskep and skepd be tested without hardware.
- Fuzz tests for every parser of external input: serial link, Zigbee
  frames, IPC requests, configuration.
- Tests against the real dongle are run by hand, as described in
  [development.md](development.md).

## Security

- Everything received from the serial line or the radio is untrusted.
  Malformed input is rejected without crashing.
- The network key and the exported state are readable by their owner
  only. libskep hands the state to the caller; storing it safely is
  skepd's job.
- New devices can join only during an explicit, time-limited permit
  window. Devices already in the network may rejoin at any time, for
  instance a sensor whose parent router was switched off: closing the
  window must not cut them off.

## Milestones

1. This document, then a draft `skep.h` for review.
2. `ezsp` driver: reset the ASH link and read the EZSP version from the
   dongle, through a minimal I/O loop.
3. The driver interface, implemented by both `ezsp` and `sim`. Network:
   form or resume, permit joining, join events. From here on every
   feature is exercised by skepd through `<skep.h>`.
4. Device interview, binding and reporting: sensor readings arrive.
5. Light control: the bulb obeys.
6. skep-protocol and the skep command-line tool.
7. Packaging: man pages, systemd units, installation.

## Open questions

- Configuration file format.
- Source format of the man pages (mdoc, scdoc, pandoc Markdown).
- Dongle detection: should libskep offer to find dongles and pick the
  driver? USB ids are not reliable for this (see
  [hardware.md](hardware.md)); product strings or probing the protocol
  may be.
- The JSON schema of skep-protocol.
- Format of the exported state: compact binary, or text that a human can
  inspect (it holds the network key either way).
- Values from devices: `SKEP_EVENT_ATTRIBUTES` carries raw ZCL values.
  Should libskep also apply the device tables' corrections and units (the
  Smart Plug E2's voltage in volts, for instance), or leave that to
  applications?
- Convenience functions for common commands (On/Off, Level Control,
  Color Control), or only the generic `skep_send_command()`?

## References

- Silicon Labs UG101, the ASH serial link protocol used by EZSP.
- Silicon Labs UG100, the EZSP reference guide.
- Silicon Labs AN706, the EZSP UART host interfacing guide.
- Connectivity Standards Alliance, Zigbee Cluster Library specification.
- zigbee-herdsman (MIT), `src/adapter/ember/`: a working implementation of
  ASH and EZSP. See [development.md](development.md) for the local copy
  and licensing notes.
