# skep design

Status: draft, agreed on 2026-11-14 before any code was written. When a
decision changes, update this document in the same commit as the change.

## Goal

A small, native Zigbee stack for Linux that is driven from the terminal
and follows Unix conventions. The first goal is to pair and use a
temperature and humidity sensor and a colour light bulb (see
[hardware.md](hardware.md)). skep replaces Zigbee2MQTT for our use; it
does not try to match its device coverage.

## Components

```
  skep (CLI)    scripts, socat
       |             |
       +------+------+
              |  Unix socket, line-delimited JSON (skep-protocol(7))
              v
        skepd (daemon)
              |  C API, <skep.h>
              v
        libskep (Zigbee logic)
              |  driver interface
       +------+---------------+----------------+
       v                      v                v
  ezsp driver          sim driver        later: Z-Stack, ...
       |  serial (ASH)
       v
  Silicon Labs NCP dongle
```

Names: the project is skep (a woven straw beehive). The library is
`libskep`, its header `<skep.h>`, its C prefix `skep_` (macros `SKEP_`),
the daemon `skepd` and the command-line tool `skep`.

## Language and build

- Zig, pinned to 0.17.0 (`minimum_zig_version` in `build.zig.zon`).
  Upgrading Zig is a deliberate change of its own.
- Why Zig: exporting a C ABI is native to the language, and skepd consumes
  libskep through `@cImport` of `skep.h`, exactly like an outside user
  would. The work is mostly byte-level protocol code and a single-threaded
  poll loop. One build system produces the libraries, header, pkg-config
  file, man pages, systemd units and static musl binaries.
- Why not Rust: using our own C API from Rust needs a `-sys` crate and
  `unsafe` wrappers around our own code, and a Rust static library cannot
  be linked into a Rust binary without duplicate standard library symbols,
  which forces dynamic linking.
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
  - open, close, reset;
  - read the network state, form a network (channel, PAN ID, extended
    PAN ID, network key), resume an existing network;
  - permit joining for a number of seconds;
  - send an APS frame by unicast, multicast (group) or broadcast;
  - report events: incoming APS frame, device joined, left or announced,
    send confirmation, stack status change;
  - back up and restore the network parameters and keys.
- Drivers are internal to libskep and selected at run time by name
  (`ezsp`, `sim`) together with the device path and serial options.
- First drivers: `ezsp` (Silicon Labs EmberZNet NCP over ASH, used by the
  ZBDongle-E) and `sim` (a simulated network for tests). Having two
  drivers from day one keeps the interface honest.
- The `ezsp` driver supports the EZSP protocol version of the firmware we
  run, not a range of versions.
- Out of scope: radio co-processors (RCP), which need a full Zigbee stack
  on the host.

## C API

- Opaque handles (`skep_ctx` and others), created and destroyed in pairs.
  The ownership of every returned pointer is documented.
- Functions return an `int`: 0 on success, a negative `skep_err` value on
  failure. `skep_strerror()` describes an error.
- No threads inside libskep and no callbacks into caller code. The caller
  waits on a file descriptor from `skep_get_fd()` with `poll()` or any
  event loop, calls `skep_process()`, then drains events with
  `skep_next_event()`.
- A context is used by one thread at a time; separate contexts are
  independent.
- Semantic versioning. The soname major number is the ABI version.
  `skep_version()` and `SKEP_VERSION_*` macros report the version. The
  header and `libskep.pc` are installed. Both a static and a shared
  library are built.
- A draft `skep.h` is reviewed before the library is implemented.

## skepd

- The only process that opens the dongle.
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
| Network backup, device registry | `$XDG_DATA_HOME/skep/` | `$STATE_DIRECTORY/` (`/var/lib/skep`) |
| Socket | `$XDG_RUNTIME_DIR/skep/skepd.sock` | `$RUNTIME_DIRECTORY/skepd.sock` (`/run/skep`) |

Files holding keys are created with mode 0600. The socket is not
accessible to other users.

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

Device-specific knowledge (which clusters to bind and report,
manufacturer-specific attributes) is kept in small data tables, not in
per-device code.

Not in version 1: MQTT (possible later as a separate bridge speaking
skep-protocol), OTA firmware updates, groups and scenes, Touchlink, Green
Power, RCP drivers, and a device database like Zigbee2MQTT's.

## Testing

- Unit tests for every codec, using byte sequences captured from the real
  dongle where possible.
- The `sim` driver lets libskep and skepd be tested without hardware.
- Fuzz tests for every parser of external input: serial link, Zigbee
  frames, IPC requests, configuration.
- Tests against the real dongle are run by hand, as described in
  [development.md](development.md).

## Security

- Everything received from the serial line or the radio is untrusted.
  Malformed input is rejected without crashing.
- The network key and backups are readable by their owner only.
- Devices can join only during an explicit, time-limited permit window.

## Milestones

1. This document, then a draft `skep.h` for review.
2. `ezsp` driver: reset the ASH link and read the EZSP version from the
   dongle.
3. Network: form or resume, permit joining, join events. From here on
   every feature is exercised by skepd through `<skep.h>`.
4. Device interview, binding and reporting: sensor readings arrive.
5. Light control: the bulb obeys.
6. skep-protocol and the skep command-line tool.
7. Packaging: man pages, systemd units, installation.

## Open questions

- Event loop integration: a single pollable descriptor (an internal epoll
  and timerfd, Linux only), or a descriptor plus a timeout from
  `skep_get_timeout()` (portable)?
- Configuration file format.
- Source format of the man pages (mdoc, scdoc, pandoc Markdown).
- EZSP protocol version: probe the dongle firmware first, and flash a
  newer one if it is older than EmberZNet 7.4.
- The JSON schema of skep-protocol.

## References

- Silicon Labs UG101, the ASH serial link protocol used by EZSP.
- Silicon Labs UG100, the EZSP reference guide.
- Silicon Labs AN706, the EZSP UART host interfacing guide.
- Connectivity Standards Alliance, Zigbee Cluster Library specification.
- zigbee-herdsman (MIT), `src/adapter/ember/`: a working implementation of
  ASH and EZSP. See [development.md](development.md) for the local copy
  and licensing notes.
