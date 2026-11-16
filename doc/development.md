# Development

## Tools

- Zig 0.17.0.
- zigfmt, the formatter, which the build fetches (`zig build fmt`),
  configured by `zigfmt.zon`. See `AGENTS.md`.
- Enable the pre-commit hook once per clone:
  `git config core.hooksPath .githooks`.
- On network file systems (sshfs, NFS), keep build outputs on a local
  disk: sshfs is slow and does not support symlinks. Pass
  `--cache-dir <local dir>` and `--prefix <local dir>` to `zig build`, or
  set `ZIG_LOCAL_CACHE_DIR`.

## Building and testing

- `zig build` installs libskep, static and shared, its headers and
  `libskep.pc` under `zig-out/`, or under `--prefix`.
- `zig build test` runs the unit tests and checks the headers in
  `include/`: they must compile as strict C99 and as C++, translate to
  Zig, and `skep.h` must carry the version from `build.zig.zon`. A C
  program linked with the library (`test/abi.c`) checks that the
  implementation matches the headers, through the C ABI.
- `zig build test -Drelease` does the same in ReleaseSafe, the mode of
  release builds. The build offers no other optimize mode.
- `zig build test --fuzz=1M -Drelease` runs the fuzz tests for a million
  iterations; without a limit it runs until stopped. Fuzz in ReleaseSafe:
  with Zig 0.17, fuzzing a debug build fails with "corrupted coverage
  file ... pcs_len was zero".
- `zig build fmt` formats the Zig code and `zig build fmt-check` checks
  it, with the version of zigfmt pinned in `build.zig.zon`. The first
  build of skep fetches zigfmt and its own dependency from GitHub, into
  `zig-pkg/`.
- CI (GitHub Actions, `.github/workflows/ci.yml`) runs the tests in both
  modes, a million fuzz iterations and the format check on every push
  and pull request, with the Zig version of `minimum_zig_version`. On a
  tag, it also publishes the release (see below).

## Talking to the dongle

- `zig build skepd -- --device <path>` runs skepd on the dongle, which
  brings its network up; SIGINT (Ctrl-C) or SIGTERM stop it cleanly.
  `zig-out/bin/skepd --help` lists its options.
- `zig build probe -- <device>` starts a Silicon Labs EmberZNet dongle as
  the `ezsp` driver does, and reports its EZSP and firmware versions,
  whether it sent XON/XOFF, its IEEE address and the network it holds.
  `--trace` shows the bytes exchanged, `--baud` and `--rtscts` change the
  serial settings. Use the stable path under `/dev/serial/by-id/`.
- It is the minimal I/O loop around the `ezsp` driver (milestone 2), and
  Linux only. Like every host when it starts, it resets the dongle's
  firmware and brings up the network the dongle holds, which the dongle
  then keeps running; it changes nothing stored on it.

## Releasing

- The version in `build.zig.zon`, repeated by the `SKEP_VERSION_*`
  macros of `skep.h`, is the version of the next release.
- A commit that changes the API raises it, unless it has been raised
  enough since the last release: the minor version for additions, the
  major version for changes that break the API or the ABI (the minor
  version while the major version is 0). So the version is right
  whenever a release is made.
- `./release.sh` releases it. It refuses a dirty tree, a version that
  `skep.h` does not repeat, an existing tag and a changelog with nothing
  under `[Unreleased]`; runs the tests in both modes and the format
  check; moves the notes under the version and tags that commit with the
  version (`0.1.0`, no `v`); then raises the version by a patch for the
  next release (`./release.sh minor` or `major` for more) and commits
  that. It pushes nothing, and prints the commands that do.
- Pushing the tag makes CI publish the release, with the version's
  section of `CHANGELOG.md` as its notes.

## Developing in a virtual machine

We develop inside a KVM guest while the dongle is plugged into the host.
The source tree is shared from the host over sshfs.

The dongle is handed to the guest with USB passthrough rather than over
the network (ser2net): passthrough gives the guest a real serial device
with the same timing and control lines as on the host. Add an xHCI
controller and the device to the QEMU command line. The ids below are
those of our ZBDongle-E; use `lsusb` to find another dongle's.

```
-device qemu-xhci,id=xhci
-device usb-host,bus=xhci.0,vendorid=0x10c4,productid=0xea60
```

- `10c4:ea60` is a generic CP210x id that other adapters (ESP32 boards,
  for instance) use too. When several are plugged in, select the physical
  port instead: `hostbus=<bus>,hostport=<port>`, from `lsusb -t`.
- If QEMU runs as a regular user, give it access to the USB device on the
  host with a udev rule, for instance in
  `/etc/udev/rules.d/50-zbdongle.rules`:

  ```
  SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="ea60", MODE="0660", GROUP="plugdev"
  ```

  Then run `udevadm control --reload` and plug the dongle in again.
- While the guest runs, the host loses its `/dev/ttyUSB0`.
- With `-nographic`, the QEMU monitor (Ctrl-a c) attaches and detaches the
  dongle without a reboot:
  `device_add usb-host,bus=xhci.0,vendorid=0x10c4,productid=0xea60,id=zb`
  and `device_del zb`. The xHCI controller must be on the command line
  from the start.
- In the guest, the user opening the dongle must be in the `dialout`
  group.

## Reference sources

These projects are useful for comparison. They are kept outside the skep
repository, as independent clones pinned to the versions Zigbee2MQTT
2.14.3 uses. In our setup they live in `~/projects/zigbee/reference/` on
the host.

| Project | Version | License | Of interest |
|---|---|---|---|
| zigbee-herdsman | v11.2.0 | MIT | `src/adapter/ember/`: ASH (`uart/ash.ts`), EZSP (`ezsp/ezsp.ts`), adapter logic (`adapter/emberAdapter.ts`); `src/zspec/` for Zigbee and ZCL definitions |
| zigbee-herdsman-converters | v26.125.0 | MIT | Device definitions: `src/devices/third_reality.ts`, `src/devices/lumi.ts`, `src/lib/lumi.ts` |
| zigbee2mqtt | 2.14.3 | GPL-3.0 | Application behaviour only |

- Code from the MIT projects may be ported, keeping their copyright
  notices in the ported files.
- Zigbee2MQTT is GPL-3.0: read it to understand behaviour, but do not copy
  or port its code into skep.
