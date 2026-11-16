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
- EZSP frames, in the legacy and the extended format, for EZSP 13 to 19.
- Build checks that the headers compile as C99 and C++ and translate to
  Zig.
