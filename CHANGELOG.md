# Changelog

Notable changes to skep, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[semantic versioning](https://semver.org/) of the libskep API. CI
publishes the section of each released version as its release notes.

## [Unreleased]

### Added

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
- `zig build probe -- <device>`, a development tool that resets an
  EmberZNet dongle and reports its EZSP and firmware versions.
- Build checks that the headers compile as C99 and C++ and translate to
  Zig.
