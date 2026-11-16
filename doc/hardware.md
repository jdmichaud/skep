# Hardware

Notes on the hardware skep is developed and tested with. This is not a
list of what skep supports: other dongles and devices are added through
drivers and device tables (see [design.md](design.md)). Cluster and
attribute details come from the Zigbee2MQTT device definitions
(zigbee-herdsman-converters 26.125.0) unless stated otherwise.

## Development coordinator: Sonoff Zigbee 3.0 USB Dongle Plus V2 (ZBDongle-E)

- Radio: Silicon Labs EFR32MG21 according to the label and the product
  name. Our unit answers ASH and EZSP, so it is an EmberZNet network
  co-processor on a Silicon Labs radio; EZSP's version answer does not
  name the chip.
- USB serial bridge: our unit enumerates as `10c4:ea60` and is bound by
  the kernel's `cp210x` driver, so the bridge is a Silicon Labs CP210x
  (most likely a CP2102N), although Sonoff documents a CH9102F
  (`1a86:55d4`) for this model, probably a change between production
  batches. `10c4:ea60` is the generic CP210x id, also used by the
  ZBDongle-P and many unrelated adapters, so it does not identify the
  dongle. The strings programmed into the bridge do:

  ```
  Manufacturer: Itead
  Product: Sonoff Zigbee 3.0 USB Dongle Plus V2
  SerialNumber: b8aeef8b3a1fef11b64250d0639e525b
  ```

  Neither the id nor the strings prove which radio sits behind the
  bridge; only talking to it does.
- Stable device path:
  `/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_<serial>-if00-port0`.
- Serial settings: 115200 baud, 8N1, no RTS/CTS. The firmware uses
  software flow control: it sends XON about 0.1 s after a reset, as
  builds for XON/XOFF do. RSTACK follows about 1 s after RST. (Measured
  on 2026-11-16 with `zig build probe`.)
- Firmware: our unit runs EmberZNet 6.10.3 build 297, a general
  availability release (stack version 0x6a30), EZSP protocol version 8,
  as early ZBDongle-E units shipped. skep supports it
  (see design.md); Zigbee2MQTT's `ember` driver needs EmberZNet 7.4 or
  newer. `universal-silabs-flasher --device <path> probe` also reports
  the running firmware, and the same tool flashes a new one.
- After forming a network, EmberZNet 6.10.3 refuses `set_value` of
  `STACK_TOKEN_WRITING` (status 0x70), which zigbee-herdsman sends to
  make sure the network is saved; the network is kept across restarts
  anyway. The network it held as delivered, of unknown origin, was
  replaced by skep's on 2026-11-16.
- Keys and frame counters (2026-11-16): `get_key` gives the network key
  and the trust center link key, with their outgoing frame counters.
  The firmware raises its saved network frame counter by 4096 at each
  start (49153, 53250, 57346 over three starts).
- Putting a saved network back (2026-11-16, five times, over a throwaway
  network): `set_value` of `NWK_FRAME_COUNTER` and `APS_FRAME_COUNTER`
  before the security state is accepted, and the network carries on
  from them. `APS_FRAME_COUNTER` after forming is refused (status 0x70),
  and the trust center's counter then reads 0. Set before, at 118784,
  it read 118784 after the restart and the start after it: unlike the
  network counter, it does not move at a start, at least while no frame
  uses it. The sensor came back by itself each time, with a secured
  rejoin within 25 seconds, and went on reporting.
- The network frame counter after a restore, by the value set (4096 ×
  block + offset) and the starts that followed:
  - 157347 (38 + 1699): the next start resumed at 157347 or below,
    under frames already sent; the one after, at 159753 (39 + 9).
  - 262143 (63 + 4095), counted up to 262167 (64 + 23): the next start
    resumed at 262145 (64 + 1), under frames already sent; the one
    after, at 266241 (65 + 1).
  - 362167 (88 + 1719), restarted right after forming: resumed at
    360448 (88 + 0), below the value set; the next start, at 364545.
  - 462848 (113 + 0), restarted right after forming: resumed at 466944
    (114 + 0); counted up to 466968, then the next start resumed at
    471041 (115 + 1).
  So a run that begins with `set_value` saves nothing ahead, and its
  next start can go back below what it sent; a start saves ahead again.
  skep sets a block's start and restarts the dongle once the network is
  formed, as in the last case.
- Linux pitfall: brltty claims some USB serial ids, including `10c4:ea60`,
  and takes the port away. Remove it if `/dev/ttyUSB0` appears and then
  vanishes.

## ThirdReality Temperature and Humidity Sensor Lite (3RTHS0224Z)

- Battery powered (2 × AAA) sleepy end device. Sensirion sensor, ±0.3 °C,
  ±2 % RH.
- Standard clusters:
  - Power Configuration (0x0001): battery;
  - Temperature Measurement (0x0402): MeasuredValue, int16, 0.01 °C;
  - Relative Humidity Measurement (0x0405): MeasuredValue, uint16, 0.01 %.
- Manufacturer-specific cluster 0xFF01, manufacturer code 0x1407, all
  attributes int16 and writable:
  - 0x0031: temperature calibration in °C;
  - 0x0032: humidity calibration;
  - 0x0033: temperature calibration in °F.
- Pairing: hold the reset button until the LED turns red, then release.
  The LED flashes blue while the sensor is in pairing mode.
- Binding and reporting must be configured right after the sensor joins,
  while it is still awake; afterwards it sleeps most of the time.
- Joining skep's network (2026-11-16): it joins with the well-known link
  key and fails, over and over, if the trust center does not know it.
  Once joined, it obtains its own trust center link key, and reports
  temperature and humidity to the coordinator by itself, before any
  binding or reporting configuration.

## Aqara LED Bulb T2, E27, RGB CCT (LB-L02D)

- Mains powered, acts as a Zigbee router.
- Speaks Thread (Matter), Zigbee and Bluetooth, and ships in Thread mode.
  It must be switched to Zigbee mode before pairing; see the bulb's manual
  for the procedure.
- Zigbee model ids: `lumi.light.agl001`, `lumi.light.agl003` (E26/E27);
  `agl005`, `agl007` are the GU10 versions. Zigbee2MQTT model `T2_E27`.
- Specifications: about 1100 lm at 6500 K and 950 lm at 2700 K, 10.5 W,
  CRI 90, white from 2000 K to 9000 K.
- Standard clusters:
  - Identify (0x0003), On/Off (0x0006);
  - Level Control (0x0008), including OnTransitionTime (0x0012) and
    OffTransitionTime (0x0013);
  - Color Control (0x0300): colour temperature 111–500 mireds, xy and
    hue/saturation colour.
- Aqara cluster 0xFCC0, manufacturer code 0x115F (Lumi):
  - 0x0515: minimum dimming level, uint8;
  - 0x0516: maximum dimming level, uint8;
  - 0x0517: power-on behaviour, uint8 (0 off, 1 on, 2 reverse,
    3 restore; names as in Zigbee2MQTT);
  - 0x051F: RGB effect, uint32;
  - 0x0520: effect speed, uint8, 0–100 %;
  - 0x0528: transition curve curvature, float;
  - 0x052C: initial brightness of a transition, uint8;
  - 0x0523: colours of the RGB effect, octet string: 0x00, the number
    of colours (1 to 8), then each colour as CIE x and y, each scaled to
    0–65535 and sent high byte first, unlike ZCL integers
    (`lumiRGBEffectColors` in `src/lib/lumi.ts`).
  - More attributes (on/off fade durations) are defined in
    `src/lib/lumi.ts` of zigbee-herdsman-converters.
- Coordinator manufacturer code: zigbee-herdsman presents Lumi's code
  (0x115F) to devices whose IEEE address starts with 0x54ef44 or
  0x04cf8c while they join, because some Aqara devices otherwise miss
  features. Whether the T2 needs this is to be checked on the hardware.
- Reporting: Zigbee2MQTT configures none for this bulb (its `lumiLight`
  extend leaves the generic light's `configureReporting` off), so the bulb
  may not report changes of on/off, level or colour by itself. To check on
  the hardware; if it does not, its state has to be read back after each
  command, and changes made by another controller go unnoticed.

## ThirdReality Smart Color Bulb ZL4, E27 (3RCB02070Z), candidate

- Mains powered Zigbee router. Zigbee only.
- Same firmware family as the ZL1 (3RCB01057Z) and ZL2 (3RCB1095Z);
  Zigbee2MQTT handles the three as one model.
- Specifications: 810 lm, 2700–6500 K, 200–230 V only.
- Standard clusters: On/Off, Level Control, and Color Control with colour
  temperature 142–454 mireds, xy and hue/saturation colour (no enhanced
  hue).
- Manufacturer-specific cluster 0xFF04, manufacturer code 0x1407:
  - 0x0020 `allowBind`, uint8, writable. Writing 1 starts binding the
    light to a controller.
- Known issue, single report: ZL1 bulbs used with Zigbee2MQTT and an EZSP
  dongle collected hidden Touchlink group bindings over a few weeks.

## ThirdReality Smart Plug E2, Type F (3RSPE01044BZ)

- Mains powered Zigbee router with energy metering, for Type F (Schuko)
  sockets. Also has Bluetooth. Sold by Vesternet as SKU 3RDZP1SPA1-EU.
  Not to be confused with the Smart Plug E3 (3RSPE02065Z), a different
  model.
- Standard clusters, all on endpoint 1:
  - On/Off (0x0006): OnOff (0x0000); StartUpOnOff (0x4003) for the
    power-on behaviour;
  - Electrical Measurement (0x0B04): RMSVoltage (0x0505), RMSCurrent
    (0x0508), ActivePower (0x050B), PowerFactor (0x0510), ACFrequency
    (0x0300);
  - Metering (0x0702): CurrentSummationDelivered (0x0000), Multiplier
    (0x0301), Divisor (0x0302).
- Scale factors: Zigbee2MQTT reads the plug's multiplier and divisor
  attributes but then replaces them with fixed values, so the reported
  ones are presumably wrong:
  - voltage in V = RMSVoltage / 10;
  - current in A = RMSCurrent / 1000;
  - power in W = ActivePower / 10;
  - energy in kWh = CurrentSummationDelivered / 3 600 000.
- Setup done by Zigbee2MQTT: bind On/Off, Electrical Measurement and
  Metering to the coordinator, then configure reporting:
  - OnOff: every 0–3600 s;
  - ActivePower: every 5–3600 s, or on a change of 10 (1 W);
  - RMSCurrent: every 5–3600 s, or on a change of 50 (0.05 A);
  - RMSVoltage: every 5–3600 s, or on a change of 5 (0.5 V).
- No reporting is configured for the energy total
  (CurrentSummationDelivered), and Zigbee2MQTT does not poll it either.
  To check on the hardware whether the plug reports it by itself; if not,
  skep has to read it periodically.
- Manufacturer-specific cluster 0xFF03, manufacturer code 0x1233
  (ThirdReality's assigned code, unlike the 0x1407 used by the sensor and
  the ZL4 bulb), all attributes writable:
  - 0x0000: reset the energy total, uint8, write 1;
  - 0x0001: countdown before turning off, uint16, seconds;
  - 0x0002: countdown before turning on, uint16, seconds;
  - 0x0010: LED brightness, uint8, 0–100 %;
  - 0x0020: `allowBind`, uint8.
- Supports OTA firmware updates (not in version 1).
