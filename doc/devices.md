# Devices

The dongles and devices skep is meant to work with, and those it was
tried with.

- **Supported in theory**: what skep's code is written to handle, from
  its drivers, its device entries (`src/devices.zig`) and the standard
  readings, without having been tried on that hardware.
- **Tested**: tried on the hardware itself, with skep. What we saw is in
  [hardware.md](hardware.md).

Whatever the device, skep can read and write its attributes and send it
commands by number (`skep read`, `skep write`, `skep command`), and bind
and configure it: support below means what works without that.

## Dongles

skepd talks to a dongle on a serial port, as `/dev/ttyUSB0`.

| Dongle | Supported in theory | Tested |
| --- | --- | --- |
| Sonoff Zigbee 3.0 USB Dongle Plus V2 (ZBDongle-E) | Yes: EmberZNet network co-processor, EZSP 8 to 19 | Yes, with EmberZNet 6.10.3 (EZSP 8): forming, putting a saved network back, joining, key rotation |
| Other dongles with EmberZNet network co-processor firmware (EZSP 8 to 19), such as the Home Assistant SkyConnect (Connect ZBT-1) with its Zigbee firmware | Yes: the same driver, whose scenarios run at EZSP 8 to 19 against a made-up dongle | No |
| Dongles with radio co-processor (RCP) firmware, multiprotocol firmware among them | No: they need a whole Zigbee stack on the host, out of skep's scope | No |
| Texas Instruments Z-Stack dongles (CC2652, such as the Sonoff ZBDongle-P) | No: there is no Z-Stack driver yet | No |
| deCONZ dongles (ConBee, RaspBee) | No: there is no deCONZ driver yet | No |
| Dongles reached over the network (TCP) | No: skepd opens serial ports only | No |

## Devices

| Device | Zigbee model | Supported in theory | Tested |
| --- | --- | --- | --- |
| ThirdReality Temperature and Humidity Sensor Lite | `3RTHS0224Z` | Yes, with a device entry: set up to report temperature, humidity and battery | Yes: joining, interview, setup, reports, key rotation |
| ThirdReality Smart Color Bulb ZL4, E27 | `3RCB02070Z` | Yes, with a device entry: on, level, colour temperature within its own range, hue, saturation and colour, set and reported | Yes, two bulbs: joining, interview, setup, commands, reports, key rotation |
| ThirdReality Smart Plug E2, Type F | `3RSPE01044BZ` | Yes, with a device entry: on, power, energy, voltage, current, power factor and frequency, at the plug's scales | Yes: joining, interview, setup, commands, reports, key rotation |
| Aqara LED Bulb T2, E27 | `lumi.light.agl001`, `lumi.light.agl003` | In part: on, level, colour temperature and colour through the standard clusters; no device entry, so nothing set up to report; none of Aqara's own features (cluster 0xFCC0: effects, dimming range, power-on behaviour) | No |
| Other Zigbee 3.0 devices | | In part: interviewed, and their standard readings read and set (temperature, humidity, pressure, battery, on, level, colour, power, energy, voltage, current, power factor, frequency); nothing set up to report, unless they report by themselves; no vendor protocols, such as Tuya's datapoints | No |

A device is added to this list when skep gets an entry for it, or when
it is tried.
