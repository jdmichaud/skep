# Hardware

Notes on the hardware skep is developed with. Cluster and attribute
details come from the Zigbee2MQTT device definitions
(zigbee-herdsman-converters 26.125.0) unless stated otherwise.

## Coordinator: Sonoff Zigbee 3.0 USB Dongle Plus V2 (ZBDongle-E)

- Radio: Silicon Labs EFR32MG21. Firmware: EmberZNet network
  co-processor; the host talks EZSP over the ASH serial link protocol.
- USB serial bridge: our unit enumerates as `10c4:ea60` (Silicon Labs
  CP210x, kernel driver `cp210x`), although Sonoff documents a CH9102F
  (`1a86:55d4`) for this model. The USB id does not identify the dongle;
  the product string does: "Sonoff Zigbee 3.0 USB Dongle Plus V2".
- Stable device path:
  `/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_<serial>-if00-port0`.
  Our unit's serial is `b8aeef8b3a1fef11b64250d0639e525b`.
- Serial settings: 115200 baud is the usual setting for this dongle. Flow
  control is to be confirmed when probing.
- Firmware version: not yet known for our unit. Early ZBDongle-E units
  shipped EmberZNet 6.x; Zigbee2MQTT's `ember` driver needs 7.4 or newer.
  `universal-silabs-flasher --device <path> probe` reports the running
  firmware, and the same tool flashes a new one.
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
  - 0x0523: read by Zigbee2MQTT during setup, meaning unknown.
  - More attributes (on/off fade durations) are defined in
    `src/lib/lumi.ts` of zigbee-herdsman-converters.

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
