# Changelog

Notable changes to skep, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[semantic versioning](https://semver.org/) of the libskep API. CI
publishes the section of each released version as its release notes.

## [Unreleased]

### Added

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
