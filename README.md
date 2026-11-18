# skep

A small Zigbee stack: the `libskep` library with a C API, the `skepd`
daemon and the `skep` command-line tool.

## Install

On Linux (x86_64, aarch64, 32-bit ARM from ARMv6, riscv64), `skepd`,
`skep`, their manual pages and, where systemd runs, skepd's units, from
the latest release:

```
curl -fsSL https://github.com/jdmichaud/skep/releases/latest/download/install.sh | sh
```

as root into `/usr/local`, otherwise into `~/.local`. The script is
short: to read it first, download it, then run it with `sh install.sh`.
`skep-uninstall` removes it all again; skepd(8) tells how to start the
service.

The dongles and devices skep supports, and those it was tested with, are
listed in [doc/devices.md](doc/devices.md).

MIT licensed, see [LICENSE](LICENSE).
