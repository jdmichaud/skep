//! skep's commands: what each takes, how its arguments are checked and written into a request of
//! skep-protocol(7), and how its help reads. One declaration per command drives all of these, so
//! that they cannot drift apart; skep's main runs what parse() makes of the command line.

const std = @import("std");

const Io = std.Io;
const Stringify = std.json.Stringify;

/// What an argument takes: how it is checked, and how it goes into the request.
pub const Kind = enum {
  /// An IEEE address, or a name.
  device,
  /// A name to give a device.
  name,
  /// An integer, in decimal, or in hexadecimal after 0x.
  integer,
  /// A number of seconds, fractions allowed.
  seconds,
  /// A reading's name, such as temperature.
  reading,
  /// A ZCL type's name, such as uint8.
  zcl_type,
  /// A number, true or false, or text.
  value,
  /// A ZCL type and a value: uint8:128.
  typed,
  /// What a reading is set to, as the reading before it takes it.
  setting,
  /// on or off.
  state,
};

pub const Argument = struct {
  name: []const u8,
  /// How usage and messages show it: <name>.
  label: []const u8,
  kind: Kind,
  help: []const u8,
  /// May be left out: the last arguments only.
  optional: bool = false,
  /// Takes all the arguments left: the last one only.
  repeated: bool = false,
  /// The range of integers and seconds.
  min: f64 = 0,
  max: f64 = std.math.inf(f64),
};

fn argument(comptime name: []const u8, kind: Kind, help: []const u8) Argument {
  return .{ .name = name, .label = "<" ++ name ++ ">", .kind = kind, .help = help };
}

fn optional(a: Argument) Argument {
  var b = a;
  b.optional = true;
  return b;
}

fn repeated(a: Argument) Argument {
  var b = a;
  b.repeated = true;
  return b;
}

fn upTo(a: Argument, max: f64) Argument {
  var b = a;
  b.max = max;
  return b;
}

fn above(a: Argument, min: f64) Argument {
  var b = a;
  b.min = min;
  return b;
}

/// An option of a command, after it: --transition <seconds>.
pub const Option = struct {
  name: []const u8,
  value: Argument,
};

/// How a command runs.
pub const Flow = enum {
  /// One request, and its answer.
  request,
  /// Events, until interrupted.
  watch,
  /// The device's description, for its readings.
  get,
  /// The device's description, then reads of the readings named.
  read_readings,
};

pub const Form = struct {
  arguments: []const Argument,
  flow: Flow = .request,
  /// Whether it takes the command's options.
  options: bool = true,
};

pub const Command = struct {
  /// on, off and toggle share one.
  names: []const []const u8,
  method: []const u8,
  forms: []const Form,
  options: []const Option = &.{},
  /// What it does, in a few words for skep --help.
  summary: []const u8,
  /// What it does, for its own --help, before its arguments.
  help: []const u8,
  /// What its --help tells after its arguments, such as the readings.
  more: []const u8 = "",
  /// Writes the members of its request's params.
  params: *const fn (j: *Stringify, call: *const Call) Stringify.Error!void,
};

/// The most options a command takes.
const max_options = 2;

/// A command, as the command line asks for it.
pub const Call = struct {
  command: *const Command,
  /// Its name as typed: on, off or toggle.
  name: []const u8,
  form: *const Form,
  /// Its arguments, options left out, in the form's order.
  arguments: []const []const u8,
  /// The values of its options, in the command's order; null for those not given.
  options: [max_options]?[]const u8 = @splat(null),
  global: Global,

  /// An argument, by its name; null if left out.
  pub fn get(c: *const Call, name: []const u8) ?[]const u8 {
    for (c.form.arguments, 0..) |a, i| {
      if (std.mem.eql(u8, a.name, name)) return if (i < c.arguments.len) c.arguments[i] else null;
    }
    return null;
  }

  /// A repeated argument's values.
  pub fn all(c: *const Call, name: []const u8) []const []const u8 {
    for (c.form.arguments, 0..) |a, i| {
      if (std.mem.eql(u8, a.name, name)) return if (i < c.arguments.len) c.arguments[i..] else &.{};
    }
    return &.{};
  }

  pub fn option(c: *const Call, name: []const u8) ?[]const u8 {
    for (c.command.options, 0..) |o, i| {
      if (std.mem.eql(u8, o.name, name)) return c.options[i];
    }
    return null;
  }
};

/// skep's own options, before or after the command.
pub const Global = struct {
  socket: ?[]const u8 = null,
  json: bool = false,
  timeout: ?[]const u8 = null,
};

/// A mistake on the command line.
pub const Problem = struct {
  /// The command it was made with, if one was recognized.
  command: ?*const Command = null,
  /// Its name as typed.
  name: []const u8 = "",
  message: []const u8,
};

pub const Parsed = union(enum) {
  /// skep --help, or a command's.
  help: ?*const Command,
  version,
  call: Call,
  problem: Problem,
};

// The arguments commands share.

const device = argument(
  "device",
  .device,
  "its IEEE address, such as f44250000d350000, or its name",
);
const endpoint = upTo(
  argument("endpoint", .integer, "the number of one of its endpoints, such as 1"),
  255,
);
const cluster = upTo(
  argument("cluster", .integer, "the id of a cluster of the endpoint, such as 0x0402"),
  0xffff,
);
const attribute = upTo(
  argument("attribute", .integer, "the id of an attribute of the cluster, such as 0x0000"),
  0xffff,
);
const zcl_type = argument("type", .zcl_type,
  \\the attribute's ZCL type, such as bool, uint8, int16, enum8 or
  \\char_string; skep-protocol(7) names them all
);
const target = [_]Argument{ device, endpoint, cluster };

/// The readings, which get and read take, in their help.
const readings_help =
  \\Readings, as devices have them:
  \\
  \\  on                 yes or no
  \\  level              a light's brightness, in %
  \\  color_temperature  a light's white, in K
  \\  hue                a light's hue, in degrees
  \\  saturation         a light's saturation, in %
  \\  color_x, color_y   a light's colour, as CIE 1931 coordinates
  \\  temperature        in °C
  \\  humidity           in %
  \\  pressure           in hPa
  \\  battery            in %
  \\  battery_voltage    in V
  \\  power              in W
  \\  energy             in kWh
  \\  voltage            in V
  \\  current            in A
  \\  power_factor       from 0 to 1
  \\  frequency          in Hz
;

pub const commands = [_]Command{
  .{
    .names = &.{ "version" },
    .method = "version",
    .forms = &.{.{ .arguments = &.{} }},
    .summary = "the versions of skepd, libskep and their protocol",
    .help = "Prints the versions of skepd, of the libskep it runs on, and of skep-protocol(7).",
    .params = noParams,
  },
  .{
    .names = &.{ "network" },
    .method = "network",
    .forms = &.{.{ .arguments = &.{} }},
    .summary = "the network",
    .help =
    \\Prints whether the network is up, its channel, PAN ID and extended PAN ID, and how long
    \\devices may still join.
    ,
    .params = noParams,
  },
  .{
    .names = &.{ "permit" },
    .method = "permit_join",
    .forms = &.{.{
      .arguments = &.{
        optional(
          upTo(
            argument(
              "seconds",
              .seconds,
              "how long, 60 by default, 254 at most; 0 stops letting them",
            ),
            254,
          ),
        ),
      },
    }},
    .summary = "let new devices join, 60 s by default, 0 to stop",
    .help = "Lets new devices join the network for a while.",
    .params = permitParams,
  },
  .{
    .names = &.{ "devices" },
    .method = "devices",
    .forms = &.{.{ .arguments = &.{} }},
    .summary = "the devices, and what they last reported",
    .help =
    \\Lists the devices, one per line: their name, or their address without one, their model,
    \\and the first three readings they reported, or how far their setup got.
    ,
    .params = noParams,
  },
  .{
    .names = &.{ "device" },
    .method = "device",
    .forms = &.{.{ .arguments = &.{ device } }},
    .summary = "one device, in detail",
    .help =
    \\Prints what the device's interview found: its address, type, manufacturer and model, its
    \\endpoints and clusters, and its readings, as get gives them.
    ,
    .params = deviceParams,
  },
  .{
    .names = &.{ "get" },
    .method = "device",
    .forms = &.{.{
      .arguments = &.{
        device,
        optional(
          repeated(
            argument(
              "reading",
              .reading,
              "one of the device's readings, which get without one lists",
            ),
          ),
        ),
      },
      .flow = .get,
    }},
    .summary = "what a device last reported, or was read for",
    .help =
    \\Prints the device's readings, or those named: the last value it reported or was read for,
    \\and how long ago. It answers at once, even for a device that sleeps.
    ,
    .more = readings_help,
    .params = deviceParams,
  },
  .{
    .names = &.{ "read" },
    .method = "read",
    .forms = &.{
      .{
        .arguments = &.{
          device,
          repeated(argument("reading", .reading, "one of the device's readings, which get lists")),
        },
        .flow = .read_readings,
      },
      .{ .arguments = &(target ++ [_]Argument{ repeated(attribute) }) },
    },
    .summary = "ask a device for readings, such as temperature",
    .help =
    \\Asks the device for readings, or for attributes by number. A device that sleeps answers
    \\when it wakes up, which can take minutes: --timeout gives up earlier.
    ,
    .more = readings_help,
    .params = readParams,
  },
  .{
    .names = &.{ "set" },
    .method = "set",
    .forms = &.{
      .{
        .arguments = &.{
          device,
          .{ .name = "state", .label = "on|off", .kind = .state, .help = "switch it on or off" },
        },
        .options = false,
      },
      .{
        .arguments = &.{
          device,
          argument("reading", .reading, "what to set, from the list below"),
          argument("value", .setting, "what to set it to, as the list below says"),
        },
      },
    },
    .options = &.{.{
      .name = "--transition",
      .value = upTo(
        argument("seconds", .seconds, "how long a light takes to get there, 0 by default"),
        6553.4,
      ),
    }},
    .summary = "set a reading, such as level 50%, or a colour: color #ff8000",
    .help = "Switches the device on or off, or sets a reading of it, or a light's colour.",
    .more =
    \\Readings and their values:
    \\
    \\  level <percent>              a light's brightness, such as 50%; 0 switches it off
    \\  color_temperature <kelvins>  a light's white, such as 2700K
    \\  hue <degrees>                a light's hue, such as 120
    \\  saturation <percent>         a light's saturation, such as 80%
    \\  color <#rrggbb>              a light's colour, in sRGB, such as #ff8000; its brightness
    \\                               is the level's
    ,
    .params = setParams,
  },
  .{
    .names = &.{ "rename" },
    .method = "rename",
    .forms = &.{.{
      .arguments = &.{
        device,
        optional(
          argument("name", .name,
            \\up to 64 bytes of text, without control characters, other than an
            \\IEEE address; quoted if it has spaces, such as "living room"
          ),
        ),
      },
    }},
    .summary = "name a device, or forget its name",
    .help =
    \\Gives the device a name, which commands then take instead of its address, or forgets its
    \\name without one.
    ,
    .params = renameParams,
  },
  .{
    .names = &.{ "setup" },
    .method = "setup",
    .forms = &.{.{ .arguments = &.{ device } }},
    .summary = "interview and set a device up again",
    .help =
    \\Interviews the device and sets it up again from the start: after a failed setup, or when it
    \\lost its configuration.
    ,
    .params = deviceParams,
  },
  .{
    .names = &.{ "remove" },
    .method = "remove",
    .forms = &.{.{ .arguments = &.{ device } }},
    .summary = "make a device leave the network, and forget it",
    .help =
    \\Asks the device to leave the network, and forgets it. It gives up waiting for an answer
    \\after 60 seconds, or --timeout: the device is forgotten either way.
    ,
    .params = removeParams,
  },
  .{
    .names = &.{ "write" },
    .method = "write",
    .forms = &.{.{
      .arguments = &(target ++
        [_]Argument{
          attribute,
          zcl_type,
          argument("value", .value, "a number, true or false, or text"),
        }),
    }},
    .summary = "write an attribute",
    .help = "Writes an attribute of a cluster of the device.",
    .params = writeParams,
  },
  .{
    .names = &.{ "report" },
    .method = "configure_reporting",
    .forms = &.{.{
      .arguments = &(target ++ [_]Argument{
        attribute,
        zcl_type,
        upTo(argument("min", .integer, "the fewest seconds between two reports"), 0xffff),
        upTo(
          argument("max", .integer,
            \\the most seconds between two reports: 0 for reports on change only,
            \\65535 for no reports
          ),
          0xffff,
        ),
        optional(
          argument("change", .value,
            \\how much it must change to be reported, for numbers, in its own units:
            \\100 for 1 °C of a temperature in hundredths of a degree
          ),
        ),
      }),
    }},
    .summary = "configure how a device reports an attribute",
    .help =
    \\Configures how the device reports an attribute: when it changes enough, but at most every
    \\<min> seconds, and at least every <max> seconds.
    ,
    .params = reportParams,
  },
  .{
    .names = &.{ "bind" },
    .method = "bind",
    .forms = &.{.{ .arguments = &target }},
    .summary = "bind a cluster to the coordinator",
    .help = "Binds the cluster to the coordinator, so that the device sends it reports and commands.",
    .params = targetParams,
  },
  .{
    .names = &.{ "unbind" },
    .method = "unbind",
    .forms = &.{.{ .arguments = &target }},
    .summary = "remove a binding",
    .help = "Removes the binding of the cluster to the coordinator.",
    .params = targetParams,
  },
  .{
    .names = &.{ "command" },
    .method = "command",
    .forms = &.{.{
      .arguments = &(target ++
        [_]Argument{
          upTo(
            argument("command", .integer, "the command's id in the cluster, such as 0x04"),
            0xff,
          ),
          .{
            .name = "argument",
            .label = "<type>:<value>",
            .kind = .typed,
            .help = "an argument, with its ZCL type, such as uint8:128 then uint16:10",
            .optional = true,
            .repeated = true,
          },
        }),
    }},
    .summary = "send a cluster command",
    .help = "Sends a cluster command, with its arguments in order.",
    .params = commandParams,
  },
  .{
    .names = &.{ "on", "off" },
    .method = "set",
    .forms = &.{.{
      .arguments = &.{
        device,
        optional(
          upTo(
            argument("endpoint", .integer, "the number of the endpoint, the first one by default"),
            255,
          ),
        ),
      },
    }},
    .summary = "switch a device on or off",
    .help = "Switches the device on or off, as set <device> on or off does.",
    .params = switchParams,
  },
  .{
    .names = &.{ "toggle" },
    .method = "command",
    .forms = &.{.{
      .arguments = &.{
        device,
        optional(
          upTo(argument("endpoint", .integer, "the number of the endpoint, 1 by default"), 255),
        ),
      },
    }},
    .summary = "switch a device the other way",
    .help = "Switches the device on if it is off, off if it is on: its On/Off cluster's Toggle command.",
    .params = toggleParams,
  },
  .{
    .names = &.{ "watch" },
    .method = "watch",
    .forms = &.{.{ .arguments = &.{}, .flow = .watch }},
    .summary = "print events until interrupted",
    .help =
    \\Prints what happens on the network, one event per line, until interrupted: its time in UTC,
    \\the device, and what happened, such as the readings it reported.
    ,
    .params = noParams,
  },
};

/// The command named, or null.
pub fn named(name: []const u8) ?*const Command {
  for (&commands) |*command| {
    for (command.names) |n| {
      if (std.mem.eql(u8, n, name)) return command;
    }
  }
  return null;
}

// Parsing.

/// What the command line asks for, from the arguments after the program's name. Problems are
/// returned, not errors: only running out of memory is.
pub fn parse(a: std.mem.Allocator, args: []const []const u8) error{ OutOfMemory }!Parsed {
  var global: Global = .{};
  var positional: std.ArrayList([]const u8) = .empty;
  var given: [max_options]?[]const u8 = @splat(null);
  var command: ?*const Command = null;
  var help = false;
  var only_arguments = false;
  var i: usize = 0;
  while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (only_arguments or !std.mem.startsWith(u8, arg, "--")) {
      if (command == null and positional.items.len == 0) {
        command = named(arg);
      }
      try positional.append(a, arg);
      continue;
    }
    const name = if (positional.items.len > 0) positional.items[0] else "";
    if (eq(arg, "--")) {
      only_arguments = true;
    } else if (eq(arg, "--help")) {
      help = true;
    } else if (eq(arg, "--version")) {
      return .version;
    } else if (eq(arg, "--json")) {
      global.json = true;
    } else if (eq(arg, "--socket") or eq(arg, "--timeout") or optionIndex(command, arg) != null) {
      if (i + 1 == args.len) {
        return problem(a, command, name, "{s} needs a value", .{ arg });
      }
      i += 1;
      const value = args[i];
      if (eq(arg, "--socket")) {
        global.socket = value;
      } else if (eq(arg, "--timeout")) {
        const timeout = above(argument("seconds", .seconds, ""), 0.001);
        if (try check(a, timeout, value, &.{}, null)) |message| {
          return problem(a, command, name, "--timeout: {s}", .{ message });
        }
        global.timeout = value;
      } else {
        const index = optionIndex(command, arg).?;
        if (try check(a, command.?.options[index].value, value, &.{}, null)) |message| {
          return problem(a, command, name, "{s}: {s}", .{ arg, message });
        }
        given[index] = value;
      }
    } else {
      return problem(a, command, name, "unknown option {s}", .{ arg });
    }
  }
  if (positional.items.len == 0) {
    if (help) return .{ .help = null };
    return .{ .problem = .{ .message = "no command" } };
  }
  const name = positional.items[0];
  const c = command orelse return problem(a, null, "", "unknown command \"{s}\"", .{ name });
  if (help) return .{ .help = c };
  const arguments = positional.items[1..];
  // The form that takes the arguments; or, if none does, what is wrong with the one that took
  // most of them, the first one on a tie.
  var best: ?Mismatch = null;
  for (c.forms) |*form| {
    const mismatch = try match(a, form, arguments) orelse {
      if (!form.options) {
        for (given[0..c.options.len], c.options) |value, o| {
          if (value != null) {
            return problem(a, c, name, "{s} does not go with {s}", .{
              o.name,
              arguments[arguments.len - 1],
            });
          }
        }
      }
      return .{
        .call = .{
          .command = c,
          .name = name,
          .form = form,
          .arguments = arguments,
          .options = given,
          .global = global,
        },
      };
    };
    if (mismatch.better(best)) {
      best = mismatch;
    }
  }
  return .{ .problem = .{ .command = c, .name = name, .message = best.?.message } };
}

fn problem(
  a: std.mem.Allocator,
  command: ?*const Command,
  name: []const u8,
  comptime format: []const u8,
  args: anytype,
) error{ OutOfMemory }!Parsed {
  return .{
    .problem = .{
      .command = command,
      .name = if (command != null) name else "",
      .message = try std.fmt.allocPrint(a, format, args),
    },
  };
}

fn optionIndex(command: ?*const Command, name: []const u8) ?usize {
  for ((command orelse return null).options, 0..) |o, i| {
    if (eq(o.name, name)) return i;
  }
  return null;
}

const Mismatch = struct {
  /// How many of the form's arguments went well.
  position: usize,
  message: []const u8,
  /// Arguments were left over: less telling than a wrong one, on a tie.
  excess: bool = false,

  fn better(m: Mismatch, other: ?Mismatch) bool {
    const o = other orelse return true;
    return m.position > o.position or (m.position == o.position and o.excess and !m.excess);
  }
};

/// What keeps a form from taking the arguments, or null if it takes them.
fn match(a: std.mem.Allocator, form: *const Form, arguments: []const []const u8) error{
  OutOfMemory,
}!?Mismatch {
  // Too few first: which one is missing may be another than the last, as when the device is,
  // so it says how it took those given.
  var required: usize = 0;
  for (form.arguments) |arg| {
    if (!arg.optional) {
      required += 1;
    }
  }
  if (arguments.len < required) {
    var message: Io.Writer.Allocating = .init(a);
    message.writer.print("missing {s}", .{ form.arguments[arguments.len].label }) catch
      return error.OutOfMemory;
    for (arguments, 0..) |given, k| {
      message.writer.print("{s} \"{s}\" {s}{s}", .{
        if (k == 0) ";" else ",",
        given,
        if (k == 0) "was taken as " else "as ",
        form.arguments[k].label,
      }) catch return error.OutOfMemory;
    }
    return .{ .position = arguments.len, .message = message.written() };
  }
  var i: usize = 0;
  for (form.arguments, 0..) |arg, k| {
    if (i == arguments.len) {
      if (arg.optional) break;
      return .{
        .position = k,
        .message = try std.fmt.allocPrint(a, "missing {s}", .{ arg.label }),
      };
    }
    const values = if (arg.repeated) arguments[i..] else arguments[i..i + 1];
    for (values) |value| {
      if (try check(a, arg, value, arguments[0..i], form)) |message| {
        return .{
          .position = k,
          .message = try std.fmt.allocPrint(a, "{s}: {s}", .{ arg.label, message }),
        };
      }
    }
    i += values.len;
  }
  if (i < arguments.len) {
    return .{
      .position = form.arguments.len,
      .message = try std.fmt.allocPrint(a, "too many arguments, from \"{s}\"", .{ arguments[i] }),
      .excess = true,
    };
  }
  return null;
}

/// What is wrong with a value for an argument, or null. A setting is checked against the reading
/// before it, among `before`.
fn check(
  a: std.mem.Allocator,
  arg: Argument,
  value: []const u8,
  before: []const []const u8,
  form: ?*const Form,
) error{ OutOfMemory }!?[]const u8 {
  switch (arg.kind) {
    .device, .value => if (value.len == 0) return "empty",
    .name => {
      if (value.len == 0 or value.len > 64) return "from 1 to 64 bytes";
      for (value) |b| {
        if (b < 0x20 or b == 0x7f) return "no control characters";
      }
    },
    .integer => {
      const n = integerOf(value) orelse
        return try std.fmt.allocPrint(a, "\"{s}\" is not a number", .{ value });
      if (@as(f64, @floatFromInt(n)) > arg.max) {
        return try std.fmt.allocPrint(a, "{s} is more than {d}", .{ value, arg.max });
      }
    },
    .seconds => {
      const s = std.fmt.parseFloat(f64, value) catch
        return try std.fmt.allocPrint(a, "\"{s}\" is not a number of seconds", .{ value });
      if (!std.math.isFinite(s)) {
        return try std.fmt.allocPrint(a, "\"{s}\" is not a number of seconds", .{ value });
      }
      if (s < arg.min) {
        return try std.fmt.allocPrint(a, "{s} is less than {d}", .{ value, arg.min });
      }
      if (s > arg.max) {
        return try std.fmt.allocPrint(a, "{s} is more than {d}", .{ value, arg.max });
      }
    },
    .reading, .zcl_type => if (!isName(value)) {
      return try std.fmt.allocPrint(a, "\"{s}\" is not a {s}", .{
        value,
        if (arg.kind == .reading) "reading, such as temperature" else "ZCL type, such as uint8",
      });
    },
    .typed => {
      const colon = std.mem.indexOfScalar(u8, value, ':') orelse 0;
      if (colon == 0 or !isName(value[0..colon])) {
        return try std.fmt.allocPrint(a, "\"{s}\" has no type, as in uint8:128", .{ value });
      }
    },
    .state => if (!std.ascii.eqlIgnoreCase(value, "on") and
      !std.ascii.eqlIgnoreCase(value, "off")) {
      return try std.fmt.allocPrint(a, "\"{s}\" is not on or off", .{ value });
    },
    .setting => {
      const reading = for ((form orelse return null).arguments, 0..) |other, k| {
        if (other.kind == .reading and k < before.len) break before[k];
      } else return null;
      switch (settingOf(reading, value)) {
        .boolean, .number, .color => {},
        .bad_boolean => return try std.fmt.allocPrint(a, "{s} takes yes or no, not \"{s}\"", .{
          reading,
          value,
        }),
        .bad_color => return try std.fmt.allocPrint(
          a,
          "\"{s}\" is not a colour, such as #ff8000",
          .{ value },
        ),
        .bad_number => return try std.fmt.allocPrint(a, "\"{s}\" is not a number", .{ value }),
      }
    },
  }
  return null;
}

/// A reading's name, or a ZCL type's: a letter, then letters, digits and underscores.
fn isName(s: []const u8) bool {
  if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
  for (s) |c| {
    if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
  }
  return true;
}

/// An integer as typed: in decimal, or in hexadecimal after 0x.
fn integerOf(s: []const u8) ?u64 {
  if (std.mem.startsWith(u8, s, "0x")) return std.fmt.parseInt(u64, s[2..], 16) catch null;
  return std.fmt.parseInt(u64, s, 10) catch null;
}

/// What a setting's value is, as typed for its reading.
const Setting = union(enum) {
  boolean: bool,
  number: f64,
  /// 0xrrggbb.
  color: u32,
  bad_boolean,
  bad_color,
  bad_number,
};

/// A colour as #rrggbb, with or without its #, for color; yes or no, on or off, for on; and a
/// number for the others, with its unit if typed, as in 50%, 2700K or 120°.
fn settingOf(reading: []const u8, value: []const u8) Setting {
  if (eq(reading, "color")) {
    const digits = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
    if (digits.len != 6) return .bad_color;
    return .{ .color = std.fmt.parseInt(u32, digits, 16) catch return .bad_color };
  }
  if (eq(reading, "on")) {
    for ([_][]const u8{ "yes", "on", "true", "1" }) |word| {
      if (std.ascii.eqlIgnoreCase(value, word)) return .{ .boolean = true };
    }
    for ([_][]const u8{ "no", "off", "false", "0" }) |word| {
      if (std.ascii.eqlIgnoreCase(value, word)) return .{ .boolean = false };
    }
    return .bad_boolean;
  }
  var digits = value;
  for ([_][]const u8{ "%", "K", "k", "°" }) |unit| {
    if (std.mem.endsWith(u8, digits, unit)) {
      digits = digits[0..digits.len - unit.len];
    }
  }
  const n = std.fmt.parseFloat(f64, digits) catch return .bad_number;
  if (!std.math.isFinite(n)) return .bad_number;
  return .{ .number = n };
}

// Requests.

/// Writes the request a call makes, on one line: for get and reads of readings, the request for
/// the device's description, which comes first.
pub fn writeRequest(w: *Io.Writer, call: *const Call) Stringify.Error!void {
  var j: Stringify = .{ .writer = w };
  try j.beginObject();
  try j.objectField("id");
  try j.write(1);
  try j.objectField("method");
  try j.write(
    switch (call.form.flow) {
      .get, .read_readings => "device",
      .request, .watch => call.command.method,
    },
  );
  try j.objectField("params");
  try j.beginObject();
  try call.command.params(&j, call);
  try j.endObject();
  try j.endObject();
  try w.writeByte('\n');
}

fn noParams(_: *Stringify, _: *const Call) Stringify.Error!void {}

fn deviceParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try j.objectField("device");
  try j.write(call.get("device").?);
}

fn permitParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try j.objectField("seconds");
  try writeSeconds(j, call.get("seconds") orelse "60");
}

fn removeParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try deviceParams(j, call);
  // A device that is gone never answers: give up after a minute, unless told otherwise.
  try j.objectField("timeout");
  try writeSeconds(j, call.global.timeout orelse "60");
}

fn renameParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try deviceParams(j, call);
  try j.objectField("name");
  try j.write(call.get("name"));
}

/// device, endpoint and cluster, and the timeout if given.
fn targetParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try writeTarget(
    j,
    call.get("device").?,
    integerOf(call.get("endpoint").?).?,
    integerOf(call.get("cluster").?).?,
    call.global.timeout,
  );
}

/// The members of a request to a cluster of a device's endpoint.
pub fn writeTarget(
  j: *Stringify,
  name: []const u8,
  endpoint_id: u64,
  cluster_id: u64,
  timeout: ?[]const u8,
) Stringify.Error!void {
  try j.objectField("device");
  try j.write(name);
  try j.objectField("endpoint");
  try j.write(endpoint_id);
  try j.objectField("cluster");
  try j.write(cluster_id);
  if (timeout) |t| {
    try j.objectField("timeout");
    try writeSeconds(j, t);
  }
}

fn readParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  if (call.form.flow == .read_readings) return deviceParams(j, call);
  try targetParams(j, call);
  try j.objectField("attributes");
  try j.beginArray();
  for (call.all("attribute")) |id| {
    try j.write(integerOf(id).?);
  }
  try j.endArray();
}

fn setParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try deviceParams(j, call);
  if (call.get("state")) |state| {
    try j.objectField("reading");
    try j.write("on");
    try j.objectField("value");
    try j.write(std.ascii.eqlIgnoreCase(state, "on"));
    return;
  }
  const reading = call.get("reading").?;
  try j.objectField("reading");
  try j.write(reading);
  try j.objectField("value");
  switch (settingOf(reading, call.get("value").?)) {
    .boolean => |b| try j.write(b),
    .number => |n| try writeNumber(j, n),
    .color => |rgb| try j.print("\"#{x:0>6}\"", .{ rgb }),
    else => unreachable,
  }
  if (call.option("--transition")) |t| {
    try j.objectField("transition");
    try writeSeconds(j, t);
  }
  if (call.global.timeout) |t| {
    try j.objectField("timeout");
    try writeSeconds(j, t);
  }
}

fn writeParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try targetParams(j, call);
  try j.objectField("attributes");
  try j.beginArray();
  try j.beginObject();
  try j.objectField("id");
  try j.write(integerOf(call.get("attribute").?).?);
  try writeTyped(j, call.get("type").?, call.get("value").?);
  try j.endObject();
  try j.endArray();
}

fn reportParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try targetParams(j, call);
  try j.objectField("reporting");
  try j.beginArray();
  try j.beginObject();
  try j.objectField("id");
  try j.write(integerOf(call.get("attribute").?).?);
  try j.objectField("type");
  try j.write(call.get("type").?);
  try j.objectField("min_interval");
  try j.write(integerOf(call.get("min").?).?);
  try j.objectField("max_interval");
  try j.write(integerOf(call.get("max").?).?);
  if (call.get("change")) |change| {
    try j.objectField("change");
    try writeValue(j, change);
  }
  try j.endObject();
  try j.endArray();
}

fn commandParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try targetParams(j, call);
  try j.objectField("command");
  try j.write(integerOf(call.get("command").?).?);
  const arguments = call.all("argument");
  if (arguments.len == 0) return;
  try j.objectField("arguments");
  try j.beginArray();
  for (arguments) |typed| {
    const colon = std.mem.indexOfScalar(u8, typed, ':').?;
    try j.beginObject();
    try writeTyped(j, typed[0..colon], typed[colon + 1..]);
    try j.endObject();
  }
  try j.endArray();
}

/// on, off and toggle: On/Off's commands 1, 0 and 2.
/// on and off: the setting of the reading "on", which skepd knows how to make.
fn switchParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  try deviceParams(j, call);
  if (call.get("endpoint")) |e| {
    try j.objectField("endpoint");
    try j.write(integerOf(e).?);
  }
  try j.objectField("reading");
  try j.write("on");
  try j.objectField("value");
  try j.write(eq(call.name, "on"));
  if (call.global.timeout) |t| {
    try j.objectField("timeout");
    try writeSeconds(j, t);
  }
}

/// toggle: the On/Off cluster's Toggle command, which no setting is.
fn toggleParams(j: *Stringify, call: *const Call) Stringify.Error!void {
  const endpoint_id = if (call.get("endpoint")) |e| integerOf(e).? else 1;
  try writeTarget(j, call.get("device").?, endpoint_id, 0x0006, call.global.timeout);
  try j.objectField("command");
  try j.write(2);
}

/// Seconds as typed, which check() found to be a number.
fn writeSeconds(j: *Stringify, s: []const u8) Stringify.Error!void {
  try writeNumber(j, std.fmt.parseFloat(f64, s) catch unreachable);
}

/// A number, as an integer when it is one.
fn writeNumber(j: *Stringify, n: f64) Stringify.Error!void {
  if (@floor(n) == n and @abs(n) < 1e15) return j.write(@as(i64, @intFromFloat(n)));
  try j.write(n);
}

/// A value as typed: a number, true or false, or text.
fn writeValue(j: *Stringify, s: []const u8) Stringify.Error!void {
  if (eq(s, "true")) return j.write(true);
  if (eq(s, "false")) return j.write(false);
  if (std.fmt.parseInt(i64, s, 10)) |n| return j.write(n) else |_| {}
  if (std.fmt.parseFloat(f64, s)) |f| return j.write(f) else |_| {}
  try j.write(s);
}

/// "type" and "value", with text and hexadecimal digits kept as strings, whatever they look like.
fn writeTyped(j: *Stringify, type_name: []const u8, s: []const u8) Stringify.Error!void {
  try j.objectField("type");
  try j.write(type_name);
  try j.objectField("value");
  for ([_][]const u8{ "array", "struct", "set", "bag", "key128", "ieee_address" }) |name| {
    if (eq(type_name, name)) return j.write(s);
  }
  if (std.mem.endsWith(u8, type_name, "_string")) return j.write(s);
  try writeValue(j, s);
}

fn eq(a: []const u8, b: []const u8) bool {
  return std.mem.eql(u8, a, b);
}

// Help.

/// skep --help: how to use skep, and its commands in a few words, each after its form, or under it
/// when the form is long.
pub fn writeUsage(w: *Io.Writer) Io.Writer.Error!void {
  const column = 34;
  try w.writeAll(
    \\usage: skep [--socket <path>] [--json] [--timeout <seconds>] <command> [<arguments>]
    \\
    \\Asks skepd about the Zigbee network, and tells it what to do.
    \\
    \\
  );
  for (&commands) |*command| {
    for (command.forms, 0..) |*form, k| {
      var buffer: [256]u8 = undefined;
      var line: Io.Writer = .fixed(&buffer);
      try writeSynopsis(&line, command, form);
      const synopsis = line.buffered();
      try w.print("  {s}", .{ synopsis });
      if (k == 0 and synopsis.len + 2 < column) {
        try w.splatByteAll(' ', column - 2 - synopsis.len);
        try w.writeAll(command.summary);
      } else if (k == 0) {
        try w.writeByte('\n');
        try w.splatByteAll(' ', column);
        try w.writeAll(command.summary);
      }
      try w.writeByte('\n');
    }
  }
  try w.writeAll(
    \\
    \\Options, before or after the command:
    \\
    \\  --socket <path>      skepd's socket, if not the usual one
    \\  --json               print skepd's answers as they are, one per line
    \\  --timeout <seconds>  give up on a device after that long
    \\
    \\A device is its IEEE address or its name. Clusters, attributes and commands are numbers,
    \\in hexadecimal after 0x. skep <command> --help tells how to use a command, skep(1) more.
    \\
  );
}

/// A form of a command: set <device> <reading> <value> [--transition <seconds>].
pub fn writeSynopsis(
  w: *Io.Writer,
  command: *const Command,
  form: *const Form,
) Io.Writer.Error!void {
  for (command.names, 0..) |name, i| {
    if (i > 0) {
      try w.writeByte('|');
    }
    try w.writeAll(name);
  }
  for (form.arguments) |a| {
    try w.print(" {s}{s}{s}{s}", .{
      if (a.optional) "[" else "",
      a.label,
      if (a.repeated) "..." else "",
      if (a.optional) "]" else "",
    });
  }
  if (form.options) {
    for (command.options) |o| {
      try w.print(" [{s} {s}]", .{ o.name, o.value.label });
    }
  }
}

/// The usage lines of a command, one per form.
pub fn writeUsageLines(w: *Io.Writer, command: *const Command) Io.Writer.Error!void {
  for (command.forms, 0..) |*form, k| {
    try w.writeAll(if (k == 0) "usage: skep [<options>] " else "       skep [<options>] ");
    try writeSynopsis(w, command, form);
    try w.writeByte('\n');
  }
}

/// skep <command> --help: its forms, what it does, its arguments and options, and more.
pub fn writeHelp(w: *Io.Writer, command: *const Command) Io.Writer.Error!void {
  try writeUsageLines(w, command);
  try w.print("\n{s}\n", .{ command.help });
  // Its arguments, each once, then its options.
  var labels: [16][]const u8 = undefined;
  var helps: [16][]const u8 = undefined;
  var count: usize = 0;
  var option_labels: [max_options][64]u8 = undefined;
  for (command.forms) |form| {
    next: for (form.arguments) |a| {
      for (labels[0..count]) |l| {
        if (eq(l, a.label)) continue :next;
      }
      labels[count] = a.label;
      helps[count] = a.help;
      count += 1;
    }
  }
  for (command.options, 0..) |o, i| {
    labels[count] = std.fmt.bufPrint(&option_labels[i], "{s} {s}", .{ o.name, o.value.label }) catch
      o.name;
    helps[count] = o.value.help;
    count += 1;
  }
  if (count > 0) {
    var width: usize = 0;
    for (labels[0..count]) |l| {
      width = @max(width, l.len);
    }
    try w.writeByte('\n');
    for (labels[0..count], helps[0..count]) |l, h| {
      var lines = std.mem.splitScalar(u8, h, '\n');
      try w.print("  {s}", .{ l });
      try w.splatByteAll(' ', width - l.len + 2);
      try w.print("{s}\n", .{ lines.first() });
      while (lines.next()) |more| {
        try w.splatByteAll(' ', width + 4);
        try w.print("{s}\n", .{ more });
      }
    }
  }
  if (command.more.len > 0) {
    try w.print("\n{s}\n", .{ command.more });
  }
  try w.writeAll("\nskep --help lists the options and the commands; skep(1) tells more.\n");
}

/// A mistake on the command line: what it is, and how to use the command.
pub fn writeProblem(w: *Io.Writer, p: Problem) Io.Writer.Error!void {
  const command = p.command orelse {
    try w.print("skep: {s}\nskep --help lists the commands.\n", .{ p.message });
    return;
  };
  try w.print("skep {s}: {s}\n", .{ p.name, p.message });
  try writeUsageLines(w, command);
  try w.print("skep {s} --help tells more.\n", .{ p.name });
}

const testing = std.testing;

/// The request a command line makes, or the problem with it.
fn expectParsed(args: []const []const u8, expected: []const u8) !void {
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  var out: Io.Writer.Allocating = .init(arena.allocator());
  switch (try parse(arena.allocator(), args)) {
    .call => |call| try writeRequest(&out.writer, &call),
    .problem => |p| try writeProblem(&out.writer, p),
    .help => |c| if (c) |command|
      try writeHelp(&out.writer, command)
    else
      try writeUsage(&out.writer),
    .version => try out.writer.writeAll("version"),
  }
  const got = out.written();
  if (std.mem.indexOf(u8, got, expected) == null) {
    std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ expected, got });
    return error.TestExpectedContains;
  }
}

test "command lines become requests" {
  try expectParsed(&.{ "devices" }, "{\"id\":1,\"method\":\"devices\",\"params\":{}}\n");
  try expectParsed(&.{ "permit" }, "\"method\":\"permit_join\",\"params\":{\"seconds\":60}}");
  try expectParsed(
    &.{ "set", "lamp", "level", "50%", "--transition", "1.5" },
    "\"params\":{\"device\":\"lamp\",\"reading\":\"level\",\"value\":50,\"transition\":1.5}}",
  );
  try expectParsed(&.{ "set", "lamp", "color", "ff8000" }, "\"value\":\"#ff8000\"");
  try expectParsed(&.{ "set", "plug", "on", "no" }, "\"reading\":\"on\",\"value\":false}");
  try expectParsed(
    &.{ "set", "lamp", "off" },
    "\"params\":{\"device\":\"lamp\",\"reading\":\"on\",\"value\":false}}",
  );
  try expectParsed(
    &.{ "set", "lamp", "on" },
    "\"params\":{\"device\":\"lamp\",\"reading\":\"on\",\"value\":true}}",
  );
  try expectParsed(&.{ "set", "lamp", "OFF" }, "\"reading\":\"on\",\"value\":false}}");
  try expectParsed(
    &.{ "--timeout", "5", "set", "lamp", "color_temperature", "2700K" },
    "\"value\":2700,\"timeout\":5}",
  );
  // Options after the command too.
  try expectParsed(
    &.{ "toggle", "plug", "--timeout", "5" },
    "\"params\":{\"device\":\"plug\",\"endpoint\":1,\"cluster\":6,\"timeout\":5,\"command\":2}",
  );
  try expectParsed(
    &.{ "off", "plug" },
    "\"method\":\"set\",\"params\":{\"device\":\"plug\",\"reading\":\"on\",\"value\":false}}",
  );
  try expectParsed(
    &.{ "read", "plug", "1", "0x0b04", "0x050b", "1285" },
    "\"method\":\"read\",\"params\":{\"device\":\"plug\",\"endpoint\":1,\"cluster\":2820,\"attributes\":[1291,1285]}",
  );
  try expectParsed(
    &.{ "read", "plug", "power" },
    "\"method\":\"device\",\"params\":{\"device\":\"plug\"}",
  );
  try expectParsed(
    &.{ "command", "lamp", "1", "8", "4", "uint8:127", "uint16:10" },
    "\"command\":4,\"arguments\":[{\"type\":\"uint8\",\"value\":127},{\"type\":\"uint16\",\"value\":10}]",
  );
  try expectParsed(
    &.{ "write", "lamp", "1", "0", "0x4000", "char_string", "1.0" },
    "\"attributes\":[{\"id\":16384,\"type\":\"char_string\",\"value\":\"1.0\"}]",
  );
  try expectParsed(
    &.{ "report", "sensor", "1", "0x0402", "0", "int16", "10", "3600", "100" },
    "\"reporting\":[{\"id\":0,\"type\":\"int16\",\"min_interval\":10,\"max_interval\":3600,\"change\":100}]",
  );
  try expectParsed(&.{ "rename", "lamp" }, "\"params\":{\"device\":\"lamp\",\"name\":null}");
  try expectParsed(&.{ "remove", "lamp" }, "\"timeout\":60");
  try expectParsed(&.{ "--version" }, "version");
}

test "mistakes say what is wrong, and how to use the command" {
  try expectParsed(&.{ "set", "color_temperature", "1000K" },
    \\skep set: missing <value>; "color_temperature" was taken as <device>, "1000K" as <reading>
    \\usage: skep [<options>] set <device> on|off
    \\       skep [<options>] set <device> <reading> <value> [--transition <seconds>]
    \\skep set --help tells more.
    \\
  );
  try expectParsed(
    &.{ "set", "lamp", "level", "warm" },
    "skep set: <value>: \"warm\" is not a number\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "on", "maybe" },
    "skep set: <value>: on takes yes or no, not \"maybe\"\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "color", "red" },
    "skep set: <value>: \"red\" is not a colour, such as #ff8000\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "level", "50", "--transition", "x" },
    "skep set: --transition: \"x\" is not a number of seconds\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "level", "50", "--transition" },
    "skep set: --transition needs a value\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "level", "50", "more" },
    "skep set: too many arguments, from \"more\"\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "off", "--transition", "2" },
    "skep set: --transition does not go with off\n",
  );
  try expectParsed(
    &.{ "set", "lamp", "dim" },
    "skep set: missing <value>; \"lamp\" was taken as <device>, \"dim\" as <reading>\n",
  );
  try expectParsed(&.{ "permit", "300" }, "skep permit: <seconds>: 300 is more than 254\n");
  try expectParsed(
    &.{ "bind", "lamp", "1", "foo" },
    "skep bind: <cluster>: \"foo\" is not a number\n",
  );
  try expectParsed(
    &.{ "command", "lamp", "1", "8", "4", "127" },
    "skep command: <type>:<value>: \"127\" has no type, as in uint8:128\n",
  );
  try expectParsed(&.{ "--timeout", "0", "devices" }, "skep: --timeout: 0 is less than 0.001\n");
  try expectParsed(&.{ "devices", "--speed", "1" }, "skep devices: unknown option --speed\n");
  try expectParsed(
    &.{ "sett" },
    "skep: unknown command \"sett\"\nskep --help lists the commands.\n",
  );
  try expectParsed(&.{}, "skep: no command\n");
  // Of read's two forms, the one that went furthest says what is wrong, and both are shown.
  try expectParsed(&.{ "read", "plug", "1", "0x0b04" },
    \\skep read: missing <attribute>; "plug" was taken as <device>, "1" as <endpoint>, "0x0b04" as <cluster>
    \\usage: skep [<options>] read <device> <reading>...
    \\       skep [<options>] read <device> <endpoint> <cluster> <attribute>...
    \\
  );
}

test "every command has its help" {
  try expectParsed(&.{ "--help" }, "  set <device> <reading> <value> [--transition <seconds>]\n");
  try expectParsed(
    &.{ "set", "--help" },
    "  --transition <seconds>  how long a light takes to get there, 0 by default\n",
  );
  try expectParsed(
    &.{ "toggle", "lamp", "--help" },
    "usage: skep [<options>] toggle <device> [<endpoint>]\n",
  );
  for (commands) |command| {
    for (command.names) |name| {
      try expectParsed(&.{ name, "--help" }, command.help);
    }
  }
}
