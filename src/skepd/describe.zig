//! What skepd says of the network and of devices, in results and events: their descriptions, as
//! skep-protocol(7) gives them.

const std = @import("std");
const c = @import("skep_h");
const Protocol = @import("protocol.zig");
const Readings = @import("Readings.zig");
const Server = @import("Server.zig");
const libskep = @import("libskep.zig");
const time = @import("time.zig");
const values = @import("values.zig");

const Error = Protocol.Error;
const Message = Protocol.Message;
const Stringify = std.json.Stringify;
const events = @import("events.zig");

pub fn network(p: *Protocol, client: *Server.Client, id: i64) Error!void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  try p.result(&m, id);
  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  const up = c.skep_get_network(p.ctx, &channel, &pan_id, &extended_pan_id) == 0;
  try m.j.objectField("up");
  try m.j.write(up);
  if (up) {
    try m.j.objectField("channel");
    try m.j.write(channel);
    try m.j.objectField("pan_id");
    try m.j.write(pan_id);
    try m.j.objectField("extended_pan_id");
    try m.j.print("\"{x:0>16}\"", .{ extended_pan_id });
    try m.j.objectField("permit_join");
    const left = if (p.window_until) |until|
      (if (until > p.now) (until - p.now + 999) / 1000 else 0)
    else
      0;
    try m.j.write(left);
  } else if (p.down_error) |e| {
    var buffer: [24]u8 = undefined;
    try m.j.objectField("error");
    try m.j.write(Protocol.errnoCode(&buffer, e));
  }
  p.send(client, &m);
}

pub fn networkMembers(p: *Protocol, j: *Stringify, origin: c.enum_skep_network_origin) !void {
  try j.objectField("origin");
  try j.write(
    switch (origin) {
      c.SKEP_NETWORK_RESTORED => "restored",
      c.SKEP_NETWORK_FORMED => "formed",
      else => "resumed",
    },
  );
  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  if (c.skep_get_network(p.ctx, &channel, &pan_id, &extended_pan_id) != 0) return;
  try j.objectField("channel");
  try j.write(channel);
  try j.objectField("pan_id");
  try j.write(pan_id);
  try j.objectField("extended_pan_id");
  try j.print("\"{x:0>16}\"", .{ extended_pan_id });
}

/// The members of a device object: what is known of it so far.
pub fn deviceMembers(p: *Protocol, j: *Stringify, a: std.mem.Allocator, device: u64) Error!void {
  try j.objectField("device");
  try j.print("\"{x:0>16}\"", .{ device });
  if (p.names.get(device)) |name| {
    try j.objectField("name");
    try j.write(name);
  }
  var address: u16 = 0;
  if (c.skep_device_get_short_address(p.ctx, device, &address) == 0) {
    try j.objectField("network_address");
    try j.write(address);
  }
  var node_type: c.enum_skep_node_type = undefined;
  var manufacturer_code: u16 = 0;
  var rx_on_when_idle: c_int = 0;
  if (c.skep_device_get_node(p.ctx, device, &node_type, &manufacturer_code, &rx_on_when_idle) ==
    0) {
    try j.objectField("type");
    try j.write(
      switch (node_type) {
        c.SKEP_NODE_COORDINATOR => "coordinator",
        c.SKEP_NODE_ROUTER => "router",
        else => "end_device",
      },
    );
    try j.objectField("manufacturer_code");
    try j.write(manufacturer_code);
    try j.objectField("rx_on_when_idle");
    try j.write(rx_on_when_idle != 0);
  }
  var text: [256]u8 = undefined;
  inline for (.{
    .{ "manufacturer", c.skep_device_get_manufacturer },
    .{ "model", c.skep_device_get_model },
  }) |field| {
    if (field[1](p.ctx, device, &text, text.len) >= 0) {
      const valid = try values.validUtf8(a, std.mem.sliceTo(&text, 0));
      try j.objectField(field[0]);
      try j.write(valid);
    }
  }
  var count: usize = 0;
  if (c.skep_device_get_endpoints(p.ctx, device, null, 0, &count) == 0) {
    const endpoints = try a.alloc(u8, count);
    _ = c.skep_device_get_endpoints(p.ctx, device, endpoints.ptr, endpoints.len, &count);
    try j.objectField("endpoints");
    try j.beginArray();
    for (endpoints) |endpoint| {
      try j.beginObject();
      try j.objectField("endpoint");
      try j.write(endpoint);
      var profile: u16 = 0;
      var device_type: u16 = 0;
      if (c.skep_device_get_endpoint(p.ctx, device, endpoint, &profile, &device_type) == 0) {
        try j.objectField("profile");
        try j.write(profile);
        try j.objectField("device_type");
        try j.write(device_type);
      }
      inline for (.{
        .{ "input_clusters", c.SKEP_CLUSTER_INPUT },
        .{ "output_clusters", c.SKEP_CLUSTER_OUTPUT },
      }) |side| {
        var n: usize = 0;
        if (c.skep_device_get_clusters(p.ctx, device, endpoint, side[1], null, 0, &n) == 0) {
          const clusters = try a.alloc(u16, n);
          _ = c.skep_device_get_clusters(
            p.ctx,
            device,
            endpoint,
            side[1],
            clusters.ptr,
            clusters.len,
            &n,
          );
          try j.objectField(side[0]);
          try j.write(clusters);
        }
      }
      try j.endObject();
    }
    try j.endArray();
  }
  var setup: c.enum_skep_setup = undefined;
  if (c.skep_device_get_setup(p.ctx, device, &setup) == 0) {
    try j.objectField("setup");
    try j.write(
      switch (setup) {
        c.SKEP_SETUP_READY => "ready",
        c.SKEP_SETUP_FAILED => "failed",
        else => "pending",
      },
    );
  }
  try readingsMember(p, j, a, device);
}

/// "readings": what the device can be read for, with what it last reported or was read, and
/// when.
pub fn readingsMember(p: *Protocol, j: *Stringify, a: std.mem.Allocator, device: u64) !void {
  const sources = libskep.readings(p.ctx, a, device) catch |e| switch (e) {
    error.OutOfMemory => return error.OutOfMemory,
    error.NoDevice, error.NotInterviewed => return,
  };
  try j.objectField("readings");
  try j.beginArray();
  for (sources) |source| {
    try j.beginObject();
    try j.objectField("endpoint");
    try j.write(source.endpoint);
    try j.objectField("cluster");
    try j.write(source.cluster);
    try j.objectField("id");
    try j.write(source.attribute);
    if (source.settable != 0) {
      try j.objectField("settable");
      try j.write(true);
      try j.objectField("min");
      try j.write(source.min);
      try j.objectField("max");
      try j.write(source.max);
    }
    const key: Readings.Source = .{
      .device = device,
      .endpoint = source.endpoint,
      .cluster = source.cluster,
      .attribute = source.attribute,
    };
    if (p.readings.get(key)) |last| {
      try values.write(j, p.gpa, last.value);
      try readingMembers(j, source.name, source.unit, last.scaled);
      var buffer: [32]u8 = undefined;
      try j.objectField("time");
      try j.write(time.format(&buffer, last.time));
    } else {
      try j.objectField("reading");
      try j.write(std.mem.span(source.name));
      try j.objectField("unit");
      try j.write(std.mem.span(source.unit));
    }
    try j.endObject();
  }
  try j.endArray();
}

/// The members of an attribute's reading: its name, its value in its unit, and its unit.
pub fn readingMembers(
  j: *Stringify,
  name: [*c]const u8,
  unit: [*c]const u8,
  scaled: f64,
) !void {
  try j.objectField("reading");
  try j.write(std.mem.span(name));
  try j.objectField("scaled");
  if (std.math.isFinite(scaled)) {
    try j.write(scaled);
  } else {
    try j.write(null);
  }
  try j.objectField("unit");
  try j.write(std.mem.span(unit));
}
