# Development

## Tools

- Zig 0.17.0.
- `zigfmt`, the formatter in `PATH`, configured by `zigfmt.zon`. See
  `AGENTS.md`.
- Enable the pre-commit hook once per clone:
  `git config core.hooksPath .githooks`.
- On network file systems (sshfs, NFS), keep build outputs on a local
  disk: sshfs is slow and does not support symlinks. Pass
  `--cache-dir <local dir>` and `--prefix <local dir>` to `zig build`.

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
