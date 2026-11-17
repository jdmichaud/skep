# Changelog

Notable changes to skep, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[semantic versioning](https://semver.org/) of the libskep API. CI
publishes the section of each released version as its release notes.

## [Unreleased]

### Added

- The ThirdReality Smart Color Bulb ZL4 (3RCB02070Z): bound and configured
  to report its on/off state, level and colour once it joins.
- A draft of the libskep C API, `skep.h` and `skep/zcl.h`, for review.
  Nothing in it is implemented yet.
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
  where it has one, such as the plug's power, current and voltage.
  `skep_event_get_reading()` gives an attribute's, and
  `skep_device_get_readings()` lists what a device can be read for.
  skep-protocol(7) carries them, and skepd remembers the last ones, which
  the devices' descriptions give. It reads devices for those it has none
  of, once the network is up and when a device is set up.
- skep shows readings: `skep devices` sums up what each device last
  reported, `skep get` gives a device's last readings at once, even for a
  sleepy one, `skep read <device> <reading>...` asks the device, as in
  `skep read plug power`, and `skep watch` prints events on short lines
  such as `plug: power 11.2 W`.
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
