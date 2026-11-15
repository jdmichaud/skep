/* SPDX-License-Identifier: MIT */
/*
 * skep/zcl.h - names for the Zigbee Cluster Library
 *
 * DRAFT for review, like skep.h, which includes this header.
 *
 * Clusters, attributes and commands, named for use with the requests and
 * events of skep.h, with each attribute's type and unit and each
 * command's arguments next to its name. The ids are those of the ZCL
 * specification and never change. Only what libskep knows is named; later
 * versions add more.
 *
 * Names:
 * - clusters: SKEP_CLUSTER_<cluster>, in enum skep_cluster;
 * - attributes: SKEP_ATTR_<cluster>_<attribute>, in one enum per cluster;
 * - commands sent to a device: SKEP_CMD_<cluster>_<command>, in one enum
 *   per cluster, since the same command id means something different in
 *   each cluster.
 *
 * Arguments are listed in order, by type and meaning; they are passed to
 * skep_send_command() as an array of struct skep_value. Values are as
 * libskep presents them (see "Devices" in skep.h). "Tenths" means tenths
 * of a second, the ZCL's unit for transition times.
 */

#ifndef SKEP_ZCL_H
#define SKEP_ZCL_H

enum skep_cluster {
  SKEP_CLUSTER_BASIC = 0x0000,
  SKEP_CLUSTER_POWER_CONFIG = 0x0001, /* Power Configuration */
  SKEP_CLUSTER_IDENTIFY = 0x0003,
  SKEP_CLUSTER_ON_OFF = 0x0006,
  SKEP_CLUSTER_LEVEL = 0x0008, /* Level Control */
  SKEP_CLUSTER_COLOR = 0x0300, /* Color Control */
  SKEP_CLUSTER_TEMPERATURE = 0x0402, /* Temperature Measurement */
  SKEP_CLUSTER_HUMIDITY = 0x0405, /* Relative Humidity Measurement */
  SKEP_CLUSTER_METERING = 0x0702,
  SKEP_CLUSTER_ELECTRICAL = 0x0b04, /* Electrical Measurement */
};

/* Basic ------------------------------------------------------------------ */

enum skep_basic_attribute {
  SKEP_ATTR_BASIC_ZCL_VERSION = 0x0000, /* uint8 */
  SKEP_ATTR_BASIC_APPLICATION_VERSION = 0x0001, /* uint8 */
  SKEP_ATTR_BASIC_STACK_VERSION = 0x0002, /* uint8 */
  SKEP_ATTR_BASIC_HW_VERSION = 0x0003, /* uint8 */
  SKEP_ATTR_BASIC_MANUFACTURER_NAME = 0x0004, /* char string */
  SKEP_ATTR_BASIC_MODEL_IDENTIFIER = 0x0005, /* char string */
  SKEP_ATTR_BASIC_DATE_CODE = 0x0006, /* char string */
  /* enum8: 1 mains (single phase), 3 battery, ...; bit 7 set when a
   * battery backs up the main source */
  SKEP_ATTR_BASIC_POWER_SOURCE = 0x0007,
  SKEP_ATTR_BASIC_SW_BUILD_ID = 0x4000, /* char string */
};

/* Power Configuration ---------------------------------------------------- */

enum skep_power_config_attribute {
  SKEP_ATTR_POWER_CONFIG_BATTERY_VOLTAGE = 0x0020, /* uint8, 100 mV */
  /* uint8, 0.5 % (200 is full), 0xff unknown */
  SKEP_ATTR_POWER_CONFIG_BATTERY_PERCENTAGE_REMAINING = 0x0021,
};

/* Identify --------------------------------------------------------------- */

enum skep_identify_attribute {
  SKEP_ATTR_IDENTIFY_IDENTIFY_TIME = 0x0000, /* uint16, seconds left */
};

enum skep_identify_command {
  SKEP_CMD_IDENTIFY_IDENTIFY = 0x00, /* uint16 identify time (seconds) */
  SKEP_CMD_IDENTIFY_IDENTIFY_QUERY = 0x01, /* no arguments */
  SKEP_CMD_IDENTIFY_TRIGGER_EFFECT = 0x40, /* enum8 effect, enum8 variant */
};

/* On/Off ----------------------------------------------------------------- */

enum skep_on_off_attribute {
  SKEP_ATTR_ON_OFF_ON_OFF = 0x0000, /* bool */
  SKEP_ATTR_ON_OFF_GLOBAL_SCENE_CONTROL = 0x4000, /* bool */
  SKEP_ATTR_ON_OFF_ON_TIME = 0x4001, /* uint16, tenths */
  SKEP_ATTR_ON_OFF_OFF_WAIT_TIME = 0x4002, /* uint16, tenths */
  /* enum8: 0 off, 1 on, 2 toggle, 0xff as before power was lost */
  SKEP_ATTR_ON_OFF_START_UP_ON_OFF = 0x4003,
};

enum skep_on_off_command {
  SKEP_CMD_ON_OFF_OFF = 0x00, /* no arguments */
  SKEP_CMD_ON_OFF_ON = 0x01, /* no arguments */
  SKEP_CMD_ON_OFF_TOGGLE = 0x02, /* no arguments */
  SKEP_CMD_ON_OFF_OFF_WITH_EFFECT = 0x40, /* enum8 effect, uint8 variant */
  SKEP_CMD_ON_OFF_ON_WITH_RECALL_GLOBAL_SCENE = 0x41, /* no arguments */
  /* bitmap8 control, uint16 on time (tenths), uint16 off wait time
   * (tenths) */
  SKEP_CMD_ON_OFF_ON_WITH_TIMED_OFF = 0x42,
};

/* Level Control ---------------------------------------------------------- */

enum skep_level_attribute {
  SKEP_ATTR_LEVEL_CURRENT_LEVEL = 0x0000, /* uint8, 1 to 254 for lights */
  SKEP_ATTR_LEVEL_REMAINING_TIME = 0x0001, /* uint16, tenths */
  SKEP_ATTR_LEVEL_OPTIONS = 0x000f, /* bitmap8 */
  SKEP_ATTR_LEVEL_ON_OFF_TRANSITION_TIME = 0x0010, /* uint16, tenths */
  SKEP_ATTR_LEVEL_ON_LEVEL = 0x0011, /* uint8, 0xff for the last level */
  SKEP_ATTR_LEVEL_ON_TRANSITION_TIME = 0x0012, /* uint16, tenths */
  SKEP_ATTR_LEVEL_OFF_TRANSITION_TIME = 0x0013, /* uint16, tenths */
  /* uint8: 0 the minimum, 0xff as before power was lost */
  SKEP_ATTR_LEVEL_START_UP_CURRENT_LEVEL = 0x4000,
};

/*
 * Level Control and Color Control commands may end with two more
 * arguments, bitmap8 options mask and bitmap8 options override. They are
 * optional, and libskep leaves them out for devices known to reject them.
 * Move modes are 0 up, 1 down; rates are per second.
 */
enum skep_level_command {
  /* uint8 level, uint16 transition time (tenths) */
  SKEP_CMD_LEVEL_MOVE_TO_LEVEL = 0x00,
  /* enum8 move mode, uint8 rate */
  SKEP_CMD_LEVEL_MOVE = 0x01,
  /* enum8 step mode (0 up, 1 down), uint8 step size, uint16 transition
   * time (tenths) */
  SKEP_CMD_LEVEL_STEP = 0x02,
  SKEP_CMD_LEVEL_STOP = 0x03, /* no arguments */
  /* The same four commands, also switching the device on or off: on
   * when the level rises above the minimum, off when it reaches it. */
  SKEP_CMD_LEVEL_MOVE_TO_LEVEL_WITH_ON_OFF = 0x04,
  SKEP_CMD_LEVEL_MOVE_WITH_ON_OFF = 0x05,
  SKEP_CMD_LEVEL_STEP_WITH_ON_OFF = 0x06,
  SKEP_CMD_LEVEL_STOP_WITH_ON_OFF = 0x07,
};

/* Color Control ---------------------------------------------------------- */

/*
 * Hue and saturation are 0 to 254 (hue in steps of 360/254 degrees);
 * enhanced hue is 0 to 65535. x and y are CIE 1931 coordinates times
 * 65536. Colour temperatures are in mireds (1,000,000 / kelvin).
 */
enum skep_color_attribute {
  SKEP_ATTR_COLOR_CURRENT_HUE = 0x0000, /* uint8 */
  SKEP_ATTR_COLOR_CURRENT_SATURATION = 0x0001, /* uint8 */
  SKEP_ATTR_COLOR_REMAINING_TIME = 0x0002, /* uint16, tenths */
  SKEP_ATTR_COLOR_CURRENT_X = 0x0003, /* uint16 */
  SKEP_ATTR_COLOR_CURRENT_Y = 0x0004, /* uint16 */
  SKEP_ATTR_COLOR_COLOR_TEMPERATURE = 0x0007, /* uint16, mireds */
  /* enum8: 0 hue and saturation, 1 x and y, 2 colour temperature */
  SKEP_ATTR_COLOR_COLOR_MODE = 0x0008,
  SKEP_ATTR_COLOR_OPTIONS = 0x000f, /* bitmap8 */
  SKEP_ATTR_COLOR_ENHANCED_CURRENT_HUE = 0x4000, /* uint16 */
  /* enum8: as colour mode, plus 3 enhanced hue and saturation */
  SKEP_ATTR_COLOR_ENHANCED_COLOR_MODE = 0x4001,
  SKEP_ATTR_COLOR_COLOR_LOOP_ACTIVE = 0x4002, /* uint8, 0 or 1 */
  /* bitmap16: bit 0 hue and saturation, 1 enhanced hue, 2 colour loop,
   * 3 x and y, 4 colour temperature */
  SKEP_ATTR_COLOR_COLOR_CAPABILITIES = 0x400a,
  SKEP_ATTR_COLOR_COLOR_TEMP_PHYSICAL_MIN = 0x400b, /* uint16, mireds */
  SKEP_ATTR_COLOR_COLOR_TEMP_PHYSICAL_MAX = 0x400c, /* uint16, mireds */
  /* uint16, mireds; 0xffff as before power was lost */
  SKEP_ATTR_COLOR_START_UP_COLOR_TEMPERATURE = 0x4010,
};

/*
 * The options arguments described for Level Control apply. Hue
 * directions are 0 shortest, 1 longest, 2 up, 3 down; move modes 0 stop,
 * 1 up, 3 down; step modes 1 up, 3 down.
 */
enum skep_color_command {
  /* uint8 hue, enum8 direction, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_MOVE_TO_HUE = 0x00,
  SKEP_CMD_COLOR_MOVE_HUE = 0x01, /* enum8 move mode, uint8 rate */
  /* enum8 step mode, uint8 step size, uint8 transition time (tenths) */
  SKEP_CMD_COLOR_STEP_HUE = 0x02,
  /* uint8 saturation, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_MOVE_TO_SATURATION = 0x03,
  SKEP_CMD_COLOR_MOVE_SATURATION = 0x04, /* enum8 move mode, uint8 rate */
  /* enum8 step mode, uint8 step size, uint8 transition time (tenths) */
  SKEP_CMD_COLOR_STEP_SATURATION = 0x05,
  /* uint8 hue, uint8 saturation, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_MOVE_TO_HUE_AND_SATURATION = 0x06,
  /* uint16 x, uint16 y, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_MOVE_TO_COLOR = 0x07,
  SKEP_CMD_COLOR_MOVE_COLOR = 0x08, /* int16 rate of x, int16 rate of y */
  /* int16 step of x, int16 step of y, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_STEP_COLOR = 0x09,
  /* uint16 colour temperature (mireds), uint16 transition time (tenths) */
  SKEP_CMD_COLOR_MOVE_TO_COLOR_TEMPERATURE = 0x0a,
  /* uint16 enhanced hue, enum8 direction, uint16 transition time
   * (tenths) */
  SKEP_CMD_COLOR_ENHANCED_MOVE_TO_HUE = 0x40,
  SKEP_CMD_COLOR_ENHANCED_MOVE_HUE = 0x41, /* enum8 move mode, uint16 rate */
  /* enum8 step mode, uint16 step size, uint16 transition time (tenths) */
  SKEP_CMD_COLOR_ENHANCED_STEP_HUE = 0x42,
  /* uint16 enhanced hue, uint8 saturation, uint16 transition time
   * (tenths) */
  SKEP_CMD_COLOR_ENHANCED_MOVE_TO_HUE_AND_SATURATION = 0x43,
  /* bitmap8 update flags, enum8 action, enum8 direction, uint16 time
   * (seconds per loop), uint16 start hue (enhanced) */
  SKEP_CMD_COLOR_COLOR_LOOP_SET = 0x44,
  SKEP_CMD_COLOR_STOP_MOVE_STEP = 0x47, /* no arguments */
  /* enum8 move mode, uint16 rate (mireds per second), uint16 minimum,
   * uint16 maximum (mireds) */
  SKEP_CMD_COLOR_MOVE_COLOR_TEMPERATURE = 0x4b,
  /* enum8 step mode, uint16 step size (mireds), uint16 transition time
   * (tenths), uint16 minimum, uint16 maximum (mireds) */
  SKEP_CMD_COLOR_STEP_COLOR_TEMPERATURE = 0x4c,
};

/* Temperature Measurement ------------------------------------------------ */

enum skep_temperature_attribute {
  SKEP_ATTR_TEMPERATURE_MEASURED_VALUE = 0x0000, /* int16, 0.01 °C; 0x8000 unknown */
  SKEP_ATTR_TEMPERATURE_MIN_MEASURED_VALUE = 0x0001, /* int16, 0.01 °C */
  SKEP_ATTR_TEMPERATURE_MAX_MEASURED_VALUE = 0x0002, /* int16, 0.01 °C */
  SKEP_ATTR_TEMPERATURE_TOLERANCE = 0x0003, /* uint16, 0.01 °C */
};

/* Relative Humidity Measurement ------------------------------------------ */

enum skep_humidity_attribute {
  SKEP_ATTR_HUMIDITY_MEASURED_VALUE = 0x0000, /* uint16, 0.01 %; 0xffff unknown */
  SKEP_ATTR_HUMIDITY_MIN_MEASURED_VALUE = 0x0001, /* uint16, 0.01 % */
  SKEP_ATTR_HUMIDITY_MAX_MEASURED_VALUE = 0x0002, /* uint16, 0.01 % */
  SKEP_ATTR_HUMIDITY_TOLERANCE = 0x0003, /* uint16, 0.01 % */
};

/* Metering --------------------------------------------------------------- */

/*
 * Summations and demand are in the unit of measure, scaled by multiplier
 * / divisor: kWh and kW for unit 0.
 */
enum skep_metering_attribute {
  SKEP_ATTR_METERING_CURRENT_SUMMATION_DELIVERED = 0x0000, /* uint48 */
  SKEP_ATTR_METERING_UNIT_OF_MEASURE = 0x0300, /* enum8: 0 kWh, ... */
  SKEP_ATTR_METERING_MULTIPLIER = 0x0301, /* uint24 */
  SKEP_ATTR_METERING_DIVISOR = 0x0302, /* uint24 */
  SKEP_ATTR_METERING_SUMMATION_FORMATTING = 0x0303, /* bitmap8 */
  SKEP_ATTR_METERING_DEVICE_TYPE = 0x0306, /* bitmap8 */
  SKEP_ATTR_METERING_INSTANTANEOUS_DEMAND = 0x0400, /* int24 */
};

/* Electrical Measurement ------------------------------------------------- */

/*
 * Frequency, voltage, current and power are scaled by their multiplier /
 * divisor: RMS voltage in volts is rms_voltage * ac_voltage_multiplier /
 * ac_voltage_divisor.
 */
enum skep_electrical_attribute {
  SKEP_ATTR_ELECTRICAL_AC_FREQUENCY = 0x0300, /* uint16, Hz */
  SKEP_ATTR_ELECTRICAL_AC_FREQUENCY_MULTIPLIER = 0x0400, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_FREQUENCY_DIVISOR = 0x0401, /* uint16 */
  SKEP_ATTR_ELECTRICAL_RMS_VOLTAGE = 0x0505, /* uint16, V */
  SKEP_ATTR_ELECTRICAL_RMS_CURRENT = 0x0508, /* uint16, A */
  SKEP_ATTR_ELECTRICAL_ACTIVE_POWER = 0x050b, /* int16, W */
  SKEP_ATTR_ELECTRICAL_POWER_FACTOR = 0x0510, /* int8, -100 to 100 */
  SKEP_ATTR_ELECTRICAL_AC_VOLTAGE_MULTIPLIER = 0x0600, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_VOLTAGE_DIVISOR = 0x0601, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_CURRENT_MULTIPLIER = 0x0602, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_CURRENT_DIVISOR = 0x0603, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_POWER_MULTIPLIER = 0x0604, /* uint16 */
  SKEP_ATTR_ELECTRICAL_AC_POWER_DIVISOR = 0x0605, /* uint16 */
};

#endif /* SKEP_ZCL_H */
