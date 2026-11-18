# Changelog

Notable changes to skep, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[semantic versioning](https://semver.org/) of the libskep API. CI
publishes the section of each released version as its release notes.

## [Unreleased]

## [0.1.2] - 2026-11-18

### Added

- skepd publishes the devices on D-Bus, read-only, for desktop widgets,
  status bars and scripts: an object per device, with its address, its
  name and its last readings, and signals as they change
  (skep-dbus(7)). On the session bus if there is one, on the system bus
  otherwise, where only the `skep` group and root see them; `install.sh`
  installs the policy that allows it as root. Without a bus, skepd runs
  as before.

### Fixed

- skepd left its socket behind when it could not read `names.json`, and
  would have freed it twice had its loop failed.

## [0.1.1] - 2026-11-18

### Added

- skepd finds the dongle without `--device`: the one serial device in
  `/dev/serial/by-id/` whose name looks like a Zigbee dongle's. With
  none or several, it says so and looks again every 5 seconds.

### Changed

- The systemd units are `skepd.service`, for the system and for users,
  and find the dongle: `systemctl --user enable --now skepd`. They were
  templates whose instance was the dongle, `skepd@<device>`. To update
  from 0.1.0, disable the instance enabled first, such as
  `systemctl --user disable --now skepd@ttyUSB0` (as root, without
  `--user`), then remove `skepd@.service` from `/etc/systemd/system` and
  `/etc/systemd/user`, or from `~/.config/systemd/user`.
- `install.sh` ends with the command that starts skepd, and, for a user,
  how to keep it running after logout; as root, how to let users talk
  to it.

## [0.1.0] - 2026-11-18

### Added

- Releases offer static binaries of `skepd` and `skep`, with their
  manual pages and skepd's systemd units, for x86_64, aarch64, 32-bit
  ARM and riscv64, and `install.sh`, which installs them without a
  compiler, the units where systemd runs, and `skep-uninstall`, which
  removes them all. Run as a user, it first says what installing as
  root would give, and offers to stop for that:
  `curl -fsSL https://github.com/jdmichaud/skep/releases/latest/download/install.sh | sh`.
- skepd's `read_readings` method reads a device for readings by name,
  as `skep read <device> <reading>...` does, which now asks for it.
- skepd takes ZCL booleans and numbers as strings too, as a command line
  gives them: "true", "12", "0x0c", "1.5".
- Network key rotation: `skep_rotate_network_key()`, skepd's
  `rotate_network_key` method and `skep rekey` give the network a new,
  random key, then switch to it. It is broadcast encrypted with the
  current key, or, with `SKEP_KEY_PER_DEVICE` and `skep rekey --evict`,
  sent to each device under its own link key, which a removed device that
  still listens cannot read, nor a device without a link key of its own.
  Whether the network switched is judged by the key the dongle holds:
  EmberZNet 6.10.3 answered that it refused the switch, and had switched.
- The ThirdReality Smart Color Bulb ZL4 (3RCB02070Z): bound and configured
  to report its on/off state, level and colour once it joins.
- The libskep C API, `skep.h` and `skep/zcl.h`, which says what is
  planned and not done yet.
- The frame codec of ASH, the serial link protocol of Silicon Labs
  EmberZNet dongles, with fuzz tests.
- The ASH link layer: resetting the dongle, acknowledgements,
  retransmissions and software flow control (XON/XOFF).
- EZSP frames, in the legacy and the extended format, for EZSP 8 to 19.
- Starting an EmberZNet dongle: reset, agreeing on the EZSP version,
  reading the firmware version, configuring it and bringing up the
  network it holds.
- libskep as a static and a shared library (soname `libskep.so.0`),
  installed with its headers and `libskep.pc`.
- The core of the C API: contexts with the application's allocator and
  seed, options, the I/O loop and events. Starting resumes the dongle's
  network, or forms a new one, also in place of the dongle's with the
  `replace-network` option. `skep_permit_join()` opens the join window,
  and events report it, and the devices that join or leave.
- Devices: those that join are interviewed (node descriptor, endpoints,
  clusters, manufacturer and model) and set up from their entry in the
  device tables, binding clusters and configuring reporting, which the
  ThirdReality Temperature and Humidity Sensor Lite (3RTHS0224Z) and
  Smart Plug E2 (3RSPE01044BZ) have. A sleepy device's setup waits for it
  to wake up. `SKEP_EVENT_DEVICE_READY` and
  `SKEP_EVENT_DEVICE_SETUP_FAILED` tell how it went, `skep_setup_device()`
  starts it again, and the state keeps it. Reports become
  `SKEP_EVENT_ATTRIBUTES`, cluster commands from devices
  `SKEP_EVENT_COMMAND`.
- The device functions (`skep_get_devices()`, `skep_device_get_*()`,
  `skep_device_get_setup()` and `skep_device_get_endpoint()` among them,
  `skep_remove_device()`) and the requests (`skep_read_attributes()`,
  `skep_write_attributes()`, `skep_configure_reporting()`, `skep_bind()`,
  `skep_unbind()`, `skep_send_command()`, `skep_cancel()`), which wait
  for sleepy devices to wake up.
- Readings: libskep names attributes in words and units, a temperature
  in °C rather than hundredths of a degree, with the device's own scale
  where it has one, such as the plug's power, current and voltage, and
  the light's: level, colour temperature in kelvins, hue, saturation and
  CIE x and y.
  `skep_event_get_reading()` gives an attribute's, and
  `skep_device_get_readings()` lists what a device can be read for.
  skep-protocol(7) carries them, and skepd remembers the last ones, which
  the devices' descriptions give. It reads devices for those it has none
  of, once the network is up and when a device is set up.
- Setting readings: `skep_set_reading()` sets a light's or a plug's `on`,
  and a light's `level`, `color_temperature`, `hue` and `saturation`,
  with a transition, and `skep_set_color()` a light's colour, from sRGB. A
  setting outside what the device takes is refused with -ERANGE, and each
  settable reading says its range: a light's colour temperatures are read during
  its interview and kept in the state. The
  protocol's `set` method does both, and devices' readings say which can
  be set.
- skep shows readings: `skep devices` sums up what each device last
  reported, `skep get` gives a device's last readings at once, even for a
  sleepy one, `skep read <device> <reading>...` asks the device, as in
  `skep read plug power`, and `skep watch` prints events on short lines
  such as `plug: power 11.2 W`.
- `enum skep_log_level` names the severities `skep_event_get_log()` gives.
- `skep_event_get_removed()` tells whether a device that left was removed
  and forgotten, or left by itself.
- skep.h gives libskep's limits: SKEP_MAX_PERMIT_JOIN, SKEP_MAX_ATTRIBUTES,
  SKEP_MAX_REQUESTS and SKEP_MAX_TRANSITION.
- A device's firmware update query is reported as a command, though libskep
  still answers it, with no image.
- The `setup` option lets the application set devices up itself:
  `interview` stops after the interview.
- The `tx-power` option sets the radio's transmit power at every start.
- The `flow-control` option tells libskep how the caller opened the port,
  so that it warns of XON or XOFF on a port using RTS/CTS; skepd sets it
  from `--rtscts`.
- `--help` after any skep command tells how to use it (`skep set
  --help`), and skepd takes `--help` too.
- skep's mistakes are told with the command, the argument and what is
  wrong with it, then that command's usage, rather than the usage of
  all commands; skepd's refusals read as sentences. skep's options go
  before or after the command.
- `skep set <device> <reading> <value>` sets a reading, with
  `--transition`: `skep set bulb level 50%`, `skep set bulb
  color_temperature 2700K`, `skep set bulb color "#ff8000"`; and `skep
  set <device> on` or `off` switches it.
- Opening or closing the join window tells the routers too.
- libskep answers devices on the coordinator's behalf: a Default
  Response where a frame asks for one, and "no image available" to
  firmware update queries.
- The state: `skep_export_state()` and `skep_import_state()` save and
  load the network, its keys and frame counters, and its devices as an
  Open Coordinator Backup, the JSON format of zigpy and zigbee-herdsman;
  `skep_refresh_state()` reads the counters from the dongle again, as
  `skep_stop()` now does before stopping, and `SKEP_EVENT_STATE_CHANGED`
  says when to save. With a state, starting resumes its network, puts
  it back onto a dongle that holds none, and refuses to overwrite
  another network without `replace-network`.
- skepd, which runs the network of a dongle through libskep: it opens
  the serial port, reopens it when it disappears, logs to stderr with
  timestamps unless journald adds them, and stops cleanly on SIGTERM or
  SIGINT. It keeps the state in a file (`--state`, by default
  `state.json` in the XDG data directory or systemd's state directory),
  replaced atomically on each change with mode 0600, and refreshes it
  from the dongle every hour.
- skep-protocol(7): skepd serves clients on a Unix socket, with
  line-delimited JSON requests, responses and events, to list, name,
  set up and remove devices, read and write their attributes, configure
  their reporting, bind them, send them commands, open the join window
  and watch what happens.
- skep, the command-line client of skepd: `skep devices`, `skep permit`,
  `skep rename`, `skep read`, `skep on` and the others, and `skep watch`
  for events, in words or, with `--json`, as skepd sends them.
- systemd units for skepd, for the system and for users, one instance per
  dongle (`skepd@ttyUSB0`), installed with a sysusers.d file for the
  `skep` user and group of the system unit; skepd reports its readiness
  and status to systemd.
- Man pages, written in scdoc and rendered at build time by zzdoc:
  skep(1), skep-protocol(7) and skepd(8).
- `zig build probe -- <device>`, a development tool that resets an
  EmberZNet dongle and reports its EZSP and firmware versions.
- Build checks that the headers compile as C99 and C++ and translate to
  Zig.

### Security

- Devices libskep does not know are recorded only while the join window
  is open, and `SKEP_MAX_DEVICES` (1024) at most: a device on the network
  could make libskep record any number of made-up devices, by announcing
  them or by rejoining them through itself, until skepd could no longer
  load its state. An announcement must come from the address it
  announces.
- A join window that ends on its own is closed on the trust center too,
  and stopping closes one still open: until then, the trust center kept
  admitting devices and the well-known link key after the window ended.
- A device rejoining while a new network was being formed made libskep
  abort.
- Three kinds of input from the dongle made libskep abort: an answer
  and a failure in one read, which a dongle resetting right after it
  answers can send; a frame in the legacy EZSP format with more
  parameters than a command has; and answers to commands not sent yet.
  The driver now fails instead.
- Text from devices reached terminals and skepd's log as it was: their
  control characters could drive the terminal (clear it, set its title,
  write the clipboard) or forge lines. skep now escapes the strings skepd
  sends, and skepd those it logs, which also logged long strings as a
  pointer. Device names can no longer hold C1 controls or characters
  that reorder text.
- A client of skepd could stall it for minutes with megabytes of empty
  lines, during which skepd served neither the dongle nor other clients,
  nor stopped on SIGTERM. skepd now reads a client's lines as it handles
  them, 64 per turn of its loop at most. It serves 32 clients at once,
  and stops accepting for a second when out of file descriptors rather
  than spinning; a client may have 8 requests pending, not 16, so that
  two cannot take all of libskep's.
- skepd saves its state every 5 seconds at most, and before it exits,
  rather than on every change: each save rewrites and syncs the whole
  file, which a device causing many changes turned into a stream of
  writes. SIGHUP stops it cleanly, rather than killing it unsaved.
- libskep queued a reply to every frame from a device that asked for a
  Default Response, or for a firmware image, one sent at a time: a device
  sending them fast grew the queue without end. One reply waits per
  device at most; the device goes without the others.
- A refresh took whatever the dongle reported, even another network key,
  with which a lower frame counter: one that reports another network or
  other keys is now ignored, and logged.
- A dongle that sent XOFF and never XON held libskep's output for ever,
  with no deadline: the link now fails after 5 seconds of it while frames
  wait. The dongle's second answer about its EZSP version is now checked
  against the first.
- skepd removed whatever was at its socket's path, a regular file among
  them, and set the socket's mode by its path, following a symbolic link
  put there meanwhile: it now refuses a path that holds anything but a
  socket, and creates the socket with its mode. A temporary state file
  left from before passed its mode to the state; it is now made 0600.
- Two skepd could drive one dongle: skepd now has its serial port to
  itself, with a lock and the port's exclusive mode.
- `skep watch` kept every event it printed in memory.
- skepd could cut an error message inside a UTF-8 character, which then
  reached clients as an array of numbers.
- skepd's systemd units restart it after 5 seconds, so that a crash loop
  no longer stops it for good; bound its file descriptors, memory and
  tasks; and filter its system calls. The system unit also drops every
  capability, gives it no network, and no device but USB serial
  adapters: `systemd-analyze security` rates it 1.0, from 5.3.
- libskep aborted when an application passed `skep_output_done()` more
  bytes than `skep_output()` gave, or a time near the end of its clock:
  the first now counts what was given, and deadlines saturate.
- skep tried the default sockets when nothing answered on the one given
  by `--socket` or `$SKEP_SOCKET`, and so could act on another network
  than the one meant: a socket given is now the only one tried.
- skepd keeps systemd's watchdog, which its units set to 30 seconds:
  a skepd whose loop stops turning is restarted.
- The state has a bound, `SKEP_MAX_STATE_SIZE` (32 MiB), which skepd
  reads up to: libskep keeps 32 endpoints of a device, and writes each
  list of clusters on one line. A device listing more endpoints, or one
  answering in its name, could make the state grow past what skepd
  read, and keep it from starting.
- With EZSP 13 and later, the trust center's frame counter is read too,
  with `getApsKeyInfo`, rather than left unknown: the state keeps it, and
  a restored network starts above it.
- libskep took the network a dongle held whatever the dongle's role in
  it: one that is only a router or an end device in it is now refused,
  unless replace-network lets libskep form a network in its place. A
  dongle whose frame counters fell below the saved ones gets the saved
  network back with them, rather than send frames devices ignore; and
  when the dongle is the coordinator the devices know, its refusing to
  set them stops the start.
