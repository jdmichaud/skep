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
  The two agreed so far are build tools, not libraries, pinned in
  `build.zig.zon`: zigfmt, the formatter, and zzdoc, which renders the
  man pages. They are lazy dependencies, asked for only when skep is the
  project being built, so projects that use libskep never fetch them.

## Dongle drivers

- The driver boundary is at the network co-processor (NCP) level. The
  dongle firmware runs the Zigbee stack (network layer, APS, security,
  trust center); a driver exchanges APS frames and network management
  requests with it. Dongles of this kind (Silicon Labs EZSP, TI Z-Stack,
  deCONZ, ...) are interchangeable behind the interface.
- Driver operations, which `driver/driver.zig` defines and each driver
  implements alike:
  - reset the dongle's stack and the link to it, and report the
    coordinator's IEEE address, the firmware, and the network the dongle
    holds;
  - form a network (channel, PAN ID, extended PAN ID, keys, frame
    counters), new or put back from a saved state;
  - read the network, its keys and frame counters again;
  - permit joining for a number of seconds;
  - send an APS frame by unicast or broadcast;
  - report events: incoming APS frame, device joined, rejoined or left,
    send confirmation and delivery, join window, failure, log message.
  - ZDO requests are APS frames to endpoint 0, which libskep builds: the
    EZSP firmware carries them so. A driver for a dongle with a command
    per ZDO request, as TI's Z-Stack has, translates them.
  - Planned, not built yet: multicast (group) frames, and setting the
    manufacturer code of the coordinator's node descriptor (see below).
- A driver's translation between its dongle's protocol and these
  operations is its own: the `ezsp` driver's is `driver/ezsp/adapter.zig`,
  apart from the EZSP protocol code, which the tools under `tools/` use
  without libskep.
- These operations were checked against zigbee-herdsman's `Adapter`
  class (v11.2.0), the interface behind its drivers for Silicon Labs, TI,
  deCONZ, ZBOSS and ZiGate dongles. Its other operations are left out of
  version 1: install codes, opening the join window through one router
  only, and inter-PAN frames (Touchlink).
- Drivers are internal to libskep and selected at run time by name, with
  the `driver` option (`ezsp`, `sim`). They never open the dongle or
  configure the serial port: the caller does, with the settings the driver
  suggests (`skep_get_serial_defaults()`), and passes the bytes.
- Some devices check the coordinator's manufacturer code, which they
  read from its node descriptor while joining: Aqara (Lumi) devices miss
  features unless it is Lumi's (0x115F). zigbee-herdsman therefore
  switches the code while a device whose IEEE address starts with a Lumi
  prefix joins (Zigbee2MQTT issue 9274). libskep is to do the same, with
  the prefixes and codes in the device tables, through a driver
  operation, once an Aqara device needs it.
- Drivers may need the serial control lines: some CC2652 dongles only
  leave their bootloader after a pulse on RTS (zigbee-herdsman's Z-Stack
  driver sends one). As libskep does no I/O, it will ask the caller with
  an event and hold its output back until the event has been taken;
  timing between steps uses its deadlines. Not in skep.h until a driver
  needs it: the `ezsp` driver does not.
- The radio's transmit power is the application's to choose, within
  what the dongle and the local regulations allow (`tx-power`): the
  driver sets it at every start.
  Without it, a dongle keeps its own, and forms a network at
  zigbee-herdsman's 5 dBm.
- Software flow control (XON/XOFF) is handled by libskep: the driver
  pauses its output on XOFF, so the caller opens the port in raw mode
  whatever the dongle uses. The caller says how it opened the port (the
  `flow-control` option, which skepd sets from `--rtscts`). XON or XOFF
  arriving when the port uses no software flow control means the
  firmware and the serial settings disagree; libskep logs a warning.
- First drivers: `ezsp` (Silicon Labs EmberZNet NCP over ASH, used by the
  ZBDongle-E) and `sim` (a simulated network for tests). Having two
  drivers from day one keeps the interface honest.
- The `ezsp` driver negotiates the protocol version with the dongle at
  start-up and supports EZSP 8 to 19: from EmberZNet 6.10, the firmware
  our ZBDongle-E came with, to the newest version zigbee-herdsman knows.
  Dongles then work as delivered, without being flashed.
  - Where versions differ, the driver has a path for each, kept apart.
    Most differences come with EZSP 13, which reads and restores keys
    and frame counters through Silicon Labs' new security API, and
    imports the keys of joining devices with another command.
  - zigbee-herdsman's older `ezsp` driver (MIT licensed), kept for
    firmware before EmberZNet 7.4, shows each difference; its `ember`
    driver supports EZSP 13 and later only.
  - The cost: two paths in the key and state code, of which only the
    versions our dongles run can be tested on hardware.
- Nothing outside a driver may depend on a particular dongle, chip or
  firmware.
- Out of scope: radio co-processors (RCP), which need a full Zigbee stack
  on the host.

## C API

The API is in [include/skep.h](../include/skep.h).

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
- The current time only enters through `skep_input()`,
  `skep_output_done()` and `skep_advance()`. Requests take a deadline
  instead, an absolute time on the same clock, after which they end with
  `-ETIMEDOUT`. So libskep never needs to know when a request was made
  (the time it last saw may be stale after a long idle period), and how
  long a request may wait is the application's choice: seconds for a
  light switched from a user interface, hours for a setting meant for a
  sensor that wakes up rarely. The protocol's own timers start when bytes
  are written.
- Requests to sleepy end devices are queued by libskep and sent when the
  device is next heard from, while it is awake. Its parent buffers frames
  for it for a few seconds only (7.68 s by default), far less than a
  sensor sleeps. A newer write or reporting configuration for the same
  attributes replaces a waiting one, so that a device that has been
  asleep is not sent outdated settings first.
- State: what must survive a restart or a new dongle (network parameters,
  keys and security counters, device registry) is exported and imported
  with `skep_export_state()` and `skep_import_state()`.
  `SKEP_EVENT_STATE_CHANGED` says when to save it. libskep reads states
  written by any older version.
  - The state is a JSON document in the Open Coordinator Backup format
    (`zigpy/open-coordinator-backup`, version 1), which zigpy and
    zigbee-herdsman read and write: the network, its key and frame
    counter, the trust center link key (under `stack_specific`), and
    the devices with their link keys. What libskep knows beyond it,
    devices' descriptors, endpoints, clusters and setup progress among
    others, is in a top-level `skep` object with a version of its own.
  - Why: the state can be read with `cat` and `jq`, and a network can
    move between skep, Zigbee2MQTT and ZHA, which is an escape hatch and
    a way in. JSON comes with Zig's standard library.
  - IEEE addresses and extended PAN IDs are written most significant
    byte first, as zigpy and zigbee-herdsman's Z-Stack driver write them.
    herdsman's `ember` driver writes them least significant byte first,
    as EZSP carries them, and wants `metadata.internal.ezspVersion`, of
    12 or more, which libskep does not write: a network moved to it needs
    its file converted.
  - Not chosen: a compact binary state of our own, with a separate export
    to this format for moving networks: smaller, but unreadable without a
    tool, and two formats to maintain.
  - The keys alone are not enough to move a network to a new dongle.
    Devices drop frames whose counter is not above the last one they saw
    from the sender (replay protection), so the state holds the frame
    counters of the network key and of every link key. Devices also know
    the coordinator by its IEEE address, so the state holds it too, and
    the driver is to give it to the new dongle where the firmware allows
    (EmberZNet keeps a "restored EUI64" token for this purpose, which
    zigbee-herdsman uses). That is not done yet: libskep warns that
    devices may have to be paired again.
  - The counters advance inside the dongle with every frame it sends, so
    an exported state is only as current as its last refresh from the
    dongle (`skep_refresh_state()`). When to refresh is policy, not
    protocol, so it is the application's choice: libskep has no clock
    to schedule it with, and zigpy and zigbee-herdsman likewise back up
    from the application layer, once a day. A clean stop
    (`skep_stop()`) refreshes the state too, so that a planned move to
    another dongle carries exact counters. A lost link
    (`skep_link_lost()`) cannot.
  - A state saved before the old dongle died lags behind the counters
    the devices last saw. On restore, libskep adds a margin to the saved
    counters (`frame-counter-margin`, 100,000 by default). Other stacks
    do the same with smaller margins and longer intervals: zigpy adds
    10,000 to a daily backup, and EmberZNet firmware adds 4,096 to its
    own saved counter at every boot. The margin costs nothing, the
    counters having four billion values, and it can be raised to
    restore an old backup.
  - Putting a network back follows zigbee-herdsman: the frame counters
    are set before the security state, which is told to keep them. A
    dongle that
    refuses a counter is logged as a warning, not a failure, and the
    state keeps the counter it had: a key's counter in the state never
    goes down, since devices remember the highest they saw. Unlike
    zigbee-herdsman, the `ezsp` driver then restarts the dongle: without
    that, EmberZNet's next start goes back below frames already sent
    (hardware.md). A state
    without a trust center link key, as one written for Z-Stack, gets a
    new one, which devices paired before do not share.
  - The dongle holds the imported network when it has the same extended
    PAN ID and network key; its channel, PAN ID and counters, newer than
    the state's, then update it. When it holds another network, the
    imported one wins, but not silently: `skep_start()` stops with
    `-EEXIST` unless `replace-network` allows overwriting the dongle's.
    Resuming the dongle's network instead would leave every known device
    behind, and a dongle used elsewhere before is the usual cause.
    Without an imported state, `replace-network` replaces the dongle's
    network with a new one, which is how a dongle used elsewhere is taken
    over.
  - A new network gets the channel, PAN ID, extended PAN ID and network
    key of the options, or random ones from the seed (channel 15 by
    default). Its security follows zigbee-herdsman's: devices join with
    the global link key, and the keys the trust center then gives them
    are derived from a random link key of its own.
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
  is not an error code: its status is reported separately.
- The application chooses the driver and the parameters of a new network
  with `skep_set_option()` before `skep_start()`; only the log level can
  be changed later, so that a running skepd can be made more verbose.
  Options are strings so that they map directly to a configuration file. Nothing else in
  `skep.h` depends on the dongle.
- Devices are identified by their IEEE address, which never changes.
- Requests (read, write, configure reporting, bind, commands, but also
  opening the join window and removing a device) are asynchronous. Each returns a request id and ends with exactly one
  `SKEP_EVENT_REQUEST_DONE` event, which carries the whole result: an
  errno value for delivery, the device's status, and for requests about
  attributes, the status (and value, for reads) of each attribute in the
  order asked. The meaning of the status is documented per request,
  since ZCL and ZDO statuses differ. ZCL responses list only the
  attributes that failed; libskep fills in the others, so that
  applications need not match ids.
- libskep presents every device as the ZCL describes it. Values in events
  and read results are corrected where a device is known to report them
  wrongly (the Smart Plug E2's scale factors). Vendor protocols that
  bypass the ZCL, such as Tuya's datapoints carried in commands of
  cluster 0xEF00, are translated into standard clusters and attributes,
  or into virtual attributes of the vendor's cluster where the ZCL has no
  equivalent. The endpoints and clusters of a device are libskep's view
  of it, which may differ from what the device advertises. zigpy's quirks
  do the same for ZHA.
  - Why: support for new devices is then a change inside libskep, with
    no change to the API or to applications. Passing vendor protocols
    through would leave their decoding to every application.
  - Cost: applications need to know the ZCL (cluster ids, units such as
    0.01 °C). Virtual attribute ids are named in `<skep/zcl.h>` and
    cannot change once released. What applications see is not always
    what went over the air, so libskep's debug log shows frames as
    received.
  - Not chosen for now: an API of named features in physical units
    ("brightness", "temperature" in °C), like Zigbee2MQTT's. It would
    spare applications the ZCL, but its vocabulary would become the
    stable API, and it is a large design. It can be added later, in a
    minor version, on top of the same model.
- Command arguments are typed values (`struct skep_value`) in both
  directions, not payloads in ZCL encoding, because encoding them is
  device knowledge too. Level Control and Color Control commands end
  with optional fields that Zigbee2MQTT sends by default and leaves out
  for devices that reject them, and devices leave out such fields in the
  commands they send. libskep needs the fields of commands anyway, to
  translate vendor protocols; for the standard commands they come from
  zigbee-herdsman's cluster definitions. An incoming command that libskep
  does not know is only available as its payload, since command payloads
  do not say the types of their fields.
- Arrays and structures stay in their ZCL encoding in `struct
  skep_value`. They are rare (32 of the 2,546 typed fields in
  zigbee-herdsman's cluster definitions, none on our devices), nested
  values would bring ownership rules and depth limits to the C API, and
  libskep can avoid them in virtual attributes. A function that decodes
  them element by element can be added in a minor version if a device
  needs it.
- `<skep/zcl.h>`, included by `skep.h`, names the clusters, attributes
  and commands libskep knows, with each attribute's type and unit and
  each command's arguments next to its name, as
  `<linux/input-event-codes.h>` does for the generic evdev API. It names
  virtual attributes too, which makes visible that their ids are part of
  the API.
  - Enums, one for each cluster's attributes and one for its commands,
    since a command id means something different in each cluster.
    Unlike macros, enum names survive in debuggers and in the
    translation to Zig.
  - A header of its own, so that `skep.h` stays about the API.
  - Why names rather than a function for each command: the ids are fixed
    by the ZCL specification, so names cost nothing in the ABI and can be
    added in any minor version, while every function would stay in the
    ABI for good, and no small set of functions covers the commands
    (On/Off, Level Control and Color Control alone have over 30). With
    typed arguments, functions would only save typing: the encoding a
    device needs is done by `skep_send_command()` either way.
- libskep interviews and sets up new devices itself, using the device
  tables, and reports `SKEP_EVENT_DEVICE_READY` when done.
  - The interview asks the node descriptor, the active endpoints and
    their simple descriptors over ZDO, then the manufacturer and model
    from the Basic cluster. The model finds the device's entry, whose
    steps bind clusters to the coordinator's endpoint 1 and configure
    their reporting. A model without an entry needs no setup.
  - Interviews, setups and requests are made of exchanges: a frame, and
    the answer it waits for, matched by its ZDO or ZCL sequence number.
    A device has one under way at a time, so that what is asked of it
    goes out in order. A sleepy device is counted awake for 10 s after
    it is heard from; what is for it waits until then. A device that
    does not pick a frame up, or does not answer within 10 s of its
    delivery, is silent until heard from again: its setup waits, its
    requests too if it sleeps, and requests to a device that does not
    sleep fail with -EHOSTUNREACH or -ETIMEDOUT.
  - A sleepy sensor stays awake for a few seconds after joining, often
    not long enough for the whole setup. libskep records how far each
    device's setup has got, in the state so that a restart does not lose
    it, and carries on when it next hears from the device.
  - A device that rejects a step fails its setup
    (`SKEP_EVENT_DEVICE_SETUP_FAILED`, with the step's error and status).
    libskep does not retry, since the device would most likely reject
    the step again; `skep_setup_device()` starts the setup over.
  - Steps that the device tables mark as allowed to fail are the
    exception: a rejection is ignored and the setup goes on. Zigbee2MQTT
    needs this for Tuya devices, which it asks for six Basic attributes,
    including 0xFFFE, ignoring an UNSUPPORTED_ATTRIBUTE answer
    (`configureMagicPacket` in `src/lib/tuya.ts`). Not done yet: no
    entry needs it.
  - Each device records the version of the device table entry it was set
    up with. When the entry changes, for instance with a new libskep that
    corrects a reporting interval, the setup is redone. Not done yet.
  - The entries' steps are a choice as much as knowledge: how often a
    sensor reports spends its battery and the network's airtime. So the
    `setup` option leaves them to the application: `full`, the default,
    takes them; `interview` stops after the interview, and the
    application binds and configures reporting itself with requests. The
    entries' scale corrections apply either way. Should a device need a
    step merely to work (Tuya's magic packet, a Lumi manufacturer code),
    such steps become quirks, taken whatever the option says.
- Devices come and go. A device that rejoins (it lost its parent, or its
  network address changed) keeps its setup; one that joins afresh after a
  factory reset is set up again, as it lost its bindings and reporting.
  The dongle tells them apart: a fresh join is an association, a rejoin
  a rejoin request, and EZSP reports the two differently. A device that leaves stays known until the
  application removes it, because leave reports are not always final and
  a device that comes back should keep its identity and setup.
- libskep also answers devices on the coordinator's behalf, without the
  application, since the answers are due at once and the ZCL says what
  they are: a ZCL Default Response where a unicast frame asks for one, of
  status success for a command whether the application handles it or not
  (as zigbee-herdsman answers); reads of the coordinator's own clusters
  (Basic, not done yet); and "no image available" to OTA queries, since
  firmware updates are not in version 1, while the query is reported as
  a command, so that the application knows a device asks. An application
  could not answer them itself: the answer carries the query's sequence
  number. ZDO requests to the coordinator are answered by the dongle's
  firmware.
- Readings: libskep names the attributes that hold a measurement or a
  state, in words and units (`temperature` in °C rather than hundredths
  of a degree), in events (`skep_event_get_reading()`), and lists those a
  device has (`skep_device_get_readings()`), what matters most first.
  - Why in libskep: what an attribute means and how it is scaled is
    Zigbee knowledge, and devices get their scale factors wrong, which
    their entries in `devices.zig` correct. Every application would
    otherwise need the same tables, skep among them.
  - The standard ones come from the ZCL, with a device's own definitions
    first. Values the ZCL reserves for "invalid" have no reading.
  - Not chosen: scaling in skep, which would put Zigbee logic in a client
    and leave other clients to do it again.
  - Some readings can be set (`skep_set_reading()`): `on`, `level`,
    `color_temperature`, `hue` and `saturation`. libskep sends the
    command of the reading's cluster that sets it, with the value scaled
    back: level 50 % is Move to Level with On/Off, to 127. Setting
    readings, rather than one function per command, gives applications
    one way to control any device that has the reading, the plug's `on`
    as much as a bulb's.
  - A setting outside what the device takes is refused (-EINVAL), and
    `skep_device_get_readings()` gives each settable reading's range in
    its unit. A light's colour temperatures are its own: its interview
    reads them (ColorTempPhysicalMinMireds and MaxMireds), and the state
    keeps them. Lights answer an out-of-range temperature with success
    and ignore it, so without that, a user would never learn why.
  - Colours are set from sRGB (`skep_set_color()`), as their CIE 1931
    chromaticity (Move to Color); their brightness is the level's. The
    conversion is colour science rather than Zigbee, but lights need it,
    and every application would otherwise do it again. Bulbs keep a
    colour outside their gamut within it themselves; clamping it in
    libskep, from a gamut in the device's entry, waits for a device that
    needs it.
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
- Randomness: the application passes 32 random bytes to `skep_new()`,
  from a cryptographically secure source such as getrandom(2), and the
  context derives every random value it needs from them with a
  cryptographic generator (ChaCha20): network keys, PAN IDs, sequence
  numbers. libskep does no I/O, so it cannot read a random source itself.
  Tests pass a fixed seed and stay repeatable.
  - Not chosen: the dongle's random generator, which every driver would
    have to offer, and the `sim` driver to fake, for something
    security-critical; and leaving applications to set the PAN IDs and
    the network key themselves, which every application would have to
    get right.
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
- Semantic versioning. The soname major number is the ABI version. Minor
  versions may add functions, options and event types; applications must
  ignore event types they do not know, so that a new event is not an ABI
  break. Structs that applications fill in end with reserved fields that
  must be 0, so that fields can be added without changing their size.
  `skep_version()` and the `SKEP_VERSION_*` macros report the version; a
  test checks that the macros match `build.zig.zon`. The headers
  (`skep.h`, `skep/zcl.h`) and `libskep.pc` are installed. Both a static
  and a shared library are built.
- The build checks that the headers compile on their own as strict C99
  and as C++, and that they translate to Zig.

## skepd

- The only process that opens the dongle, and the one doing all of
  libskep's I/O: it opens the serial port (with the driver's serial
  defaults unless `skepd.conf` overrides them), runs the poll loop, keeps
  time, reopens the dongle when it disappears, and saves libskep's state
  whenever it changes. It refreshes the state from the dongle every hour
  (`skep_refresh_state()`), which is cheap, so that a dongle that dies
  takes at most an hour of frame counters with it.
- Until the configuration file format is settled, its options come from
  the command line: `--device`, `--state` for the state file and
  `--socket` for the socket (see Files), `--driver`, `--log-level`,
  `--replace-network`, and `--baud` and `--rtscts` to override the
  driver's serial settings. What clients ask, such as opening the join
  window, goes through the socket, not the command line.
- Device names, which clients give with skep-protocol's rename, are
  skepd's, not libskep's: they are kept in `names.json` next to the
  state.
- It remembers the last reading of each attribute, as reported or read,
  with its time, and gives them with the devices: a sleepy device cannot
  be read on the spot, and the last report is often what a client wants.
  In memory only: saving them would write a file on every report, for
  values the devices send again within the hour.
  - So that there are values from the start, skepd reads devices for
    the readings it has none of: all of them once the network is up,
    those that do not sleep first, and a device once it is set up. At
    most 4 reads at once, one per device, so that clients' requests find
    room among libskep's 32 and a sleepy device does not hold up the
    others; a read waits an hour at most for a device to wake up.
  - In skepd, not libskep: whether to spend traffic, and a sleepy
    device's battery, on values is the application's choice. libskep
    gives the means: which readings a device has, and reads that wait
    for a sleepy device.
- A state file it cannot read stops it before it opens the dongle, and
  is left as it is: replacing it would lose the network it holds.
- Runs in the foreground and never daemonizes itself. Under systemd it
  uses `Type=notify` and reports readiness with sd_notify, without
  libsystemd: ready once its socket accepts clients, since the dongle may
  take long to answer or be plugged in, then a status line as the
  network comes up or the dongle goes.
- Logs to stderr, each line starting with the time in UTC (ISO 8601,
  with milliseconds), except under journald, which adds its own: skepd
  checks that stderr is the stream `JOURNAL_STREAM` names. The log level
  is configurable.
- SIGTERM and SIGINT shut it down cleanly: skepd calls `skep_stop()`,
  which refreshes the state, and saves the state before exiting. SIGHUP
  reloads the configuration.
- Serves clients on a Unix stream socket with line-delimited JSON
  requests, responses and events, documented in skep-protocol(7).
- Uses libskep only through `<skep.h>`.
- Ships a systemd user unit and a system unit, both templates whose
  instance is the dongle under /dev: `skepd@ttyUSB0`, or the escaped
  by-id path for a stable name. The device needs no configuration file
  that way, until skepd.conf exists.
  - The system unit runs skepd as the `skep` user, which a sysusers.d
    file creates, with the `dialout` group for the dongle. Its socket is
    in `/run/skep`, mode 0750, open to the `skep` group: admins in it
    use skep. Its state is in `/var/lib/skep`, for `skep` only. It is
    sandboxed with systemd's usual options.
  - The user unit uses the same paths as skepd started by hand.
  - `ExecStart` names `skepd` without a path, which systemd finds in
    `/usr/local/bin` and `/usr/bin`: Zig's build only knows the install
    prefix after build.zig has run, too late to write it into a unit.
    For another prefix, `systemctl edit` sets the path.

## skep

- A thin client of the skepd socket; it contains no Zigbee logic.
- Subcommands follow the protocol's methods, `skep permit 60`, `skep
  devices`, `skep rename`, `skep read`, `skep watch` and the others,
  with `on`, `off` and `toggle` for the On/Off cluster; skep(1) lists
  them.
- Readings, which skepd gives named and scaled, are how skep shows what
  devices measure: `skep devices` sums them up, `skep get` gives the last
  ones at once, `skep read plug power` asks the device. Numbers stay
  available for what has no reading. `skep set bulb level 50` sets one,
  in the same terms, with units as typed (`2700K`, `50%`), and `skep set
  bulb color "#ff8000"` a colour.
- One declaration per command (`src/skep/commands.zig`) says its forms,
  its arguments, what kind of value each takes and in what range, its
  options, and its help; parsing, checking, error messages, the help and
  the request all come from it, so they cannot drift apart, and tests
  cover each command from its command line to its request.
  - Not chosen: a library such as zig-clap or one that derives the
    command line from a struct, none of which was known to build on Zig
    0.17, and whose error messages could not be shaped.
- Mistakes say which command, which argument and what is wrong, then
  show that command's usage only. Too few arguments are told before bad
  ones, with how those given were taken, since the missing one is often
  not the last. skepd's refusals are shown as its messages, after the
  command's name, or worded from the data their errors carry, such as a
  setting's range; `--json` keeps their codes.
- skepd gives data, not sentences: an error's "message" is short, and
  what a client tells its user, such as "from 2203 to 7042 K" or "it can
  set on and level", it words from the error's members. The wording is
  the client's.
- Options go before or after the command. `--help` and `--version`;
  data on stdout, diagnostics on stderr. Human readable output by
  default, `--json` for scripts. Exit status 0 on success, 1 on failure,
  2 on usage errors.

## Files

| What | User service | System service |
|---|---|---|
| Configuration | `$XDG_CONFIG_HOME/skep/skepd.conf` | `$CONFIGURATION_DIRECTORY/skepd.conf` (`/etc/skep`) |
| State exported by libskep (network, keys, devices), friendly names | `$XDG_DATA_HOME/skep/` (`state.json`) | `$STATE_DIRECTORY/` (`/var/lib/skep`, `state.json`) |
| Socket | `$XDG_RUNTIME_DIR/skep/skepd.sock` | `$RUNTIME_DIRECTORY/skepd.sock` (`/run/skep`) |

skepd creates files holding keys, such as the state, with mode 0600 and
replaces them atomically. The socket is not accessible to other users,
except the members of the `skep` group for the system service.

## Documentation

- Man pages: skep(1), skepd(8), libskep(3) (plus per-function pages as the
  API settles), skepd.conf(5) and skep-protocol(7).
- They are written in scdoc, a small markup for man pages, in `man/`, and
  rendered to roff at build time by zzdoc, a Zig port of scdoc
  (github.com/rockorager/zzdoc), so building them needs nothing but Zig.
  `zig build` installs them.
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

Device-specific knowledge lives in libskep, written once for each device:
which clusters to bind and report, reporting intervals,
manufacturer-specific attributes, corrections for values a device reports
wrongly (such as scale factors), and translations of vendor protocols.
Most of it is data, but not all of it can be. Of Zigbee2MQTT's 4,618
device definitions (zigbee-herdsman-converters 26.125.0, by a rough scan
of its TypeScript), about 40 % use only generic building blocks and
standard converters; the rest rely on vendor code, such as Tuya's
datapoints or encodings like the T2's effect colours. Most of that code
is shared by a vendor's devices. So device entries are data, and refer by
name to the encodings and quirks implemented in libskep. The format of
the entries is internal, settled with the first devices, and can change
without affecting the API.

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
  Its devices answer interviews, setups and reads as the test gives
  them. skepd runs on it with `--driver sim`, and skepd's tests build
  libskep from its sources rather than link the library, so that they
  can give the sim its devices; skepd itself knows libskep by skep.h
  only.
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
  window must not cut them off. Only while the window is open does the
  trust center accept new devices and know the well-known link key they
  join with (`ZigBeeAlliance09`); outside it, it accepts rejoins only.
  A window that ends on its own is closed on the trust center too, and
  stopping closes one still open: the dongle only closes its own window,
  and would leave the trust center admitting devices.
- Devices libskep does not know are recorded only while the window is
  open, `SKEP_MAX_DEVICES` at most. Any device with the network key can
  claim that others joined, by announcing them or by telling the trust
  center that they rejoined through it: recording them at any time would
  let one device grow the state until it no longer loads. A device
  announces only itself, from the address it announces.

## Milestones

1. This document, then a draft `skep.h` for review.
2. `ezsp` driver: reset the ASH link and read the EZSP version from the
   dongle, through a minimal I/O loop.
3. The driver interface, implemented by both `ezsp` and `sim`. Network:
   form or resume, permit joining, join events. From here on every
   feature is exercised by skepd through `<skep.h>`.
4. Device interview, binding and reporting: sensor readings arrive.
5. skep-protocol and the skep command-line tool.
6. Light control: the bulb obeys.
7. Packaging: man pages, systemd units, installation.

## Open questions

- Configuration file format.
- Dongle detection: should libskep offer to find dongles and pick the
  driver? USB ids are not reliable for this (see
  [hardware.md](hardware.md)); product strings or probing the protocol
  may be.
- Wall-clock time: some devices read the current time from the
  coordinator (Time cluster). libskep only knows a monotonic clock, so the
  application would have to pass the wall-clock time as well. None of the
  version 1 devices is known to need it.

## References

- Silicon Labs UG101, the ASH serial link protocol used by EZSP.
- Silicon Labs UG100, the EZSP reference guide.
- Silicon Labs AN706, the EZSP UART host interfacing guide.
- Connectivity Standards Alliance, Zigbee Cluster Library specification.
- zigbee-herdsman (MIT), `src/adapter/ember/`: a working implementation of
  ASH and EZSP. See [development.md](development.md) for the local copy
  and licensing notes.
