//! A service's objects on the bus, without I/O: the values of their properties, as the service
//! gives them, and the bus's standard interfaces, answered from those values: Properties (read
//! only), ObjectManager on the root object, Introspectable and Peer. Changes are signalled with
//! PropertiesChanged, InterfacesAdded and InterfacesRemoved, once the service's name is its own.
//!
//! The objects are kept while the bus is away, and answered from again once it is back: clients
//! learn that the service is back from the bus, and ask again.

const std = @import("std");
const Connection = @import("Connection.zig");
const names = @import("names.zig");
const signature = @import("signature.zig");
const wire = @import("wire.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;
const Message = wire.Message;

const Service = @This();

/// An interface of the objects published: its name, and its properties, which clients read.
pub const Interface = struct {
  name: []const u8,
  properties: []const PropertyInfo,
};

pub const PropertyInfo = struct {
  name: []const u8,
  signature: []const u8,
};

/// A property's value, as given to `put` and `set`.
pub const Property = struct {
  name: []const u8,
  value: Value,
};

pub const State = enum {
  /// Not connected.
  off,
  /// Authenticating, or waiting for Hello's answer.
  connecting,
  /// Asking the bus for the name.
  requesting,
  /// The name is ours: clients see the objects.
  published,
  /// The bus refused the name.
  refused,
};

pub const Refusal = enum {
  /// The bus's policy does not let this user own the name.
  not_allowed,
  /// Another connection owns it.
  taken,
};

pub const Options = struct {
  /// The well-known name to own.
  name: []const u8,
  /// The object implementing ObjectManager, above every object published.
  root: []const u8,
  interfaces: []const Interface,
  /// The machine's id, as GetMachineId gives it, if known.
  machine_id: ?[32]u8 = null,
};

pub const Error = error{
  /// A path, an interface or a property that the options do not declare, or a value of another
  /// type than declared, or one the bus would not take: the caller's mistake.
  Invalid,
  OutOfMemory,
};

const properties_interface = "org.freedesktop.DBus.Properties";
const object_manager_interface = "org.freedesktop.DBus.ObjectManager";
const introspectable_interface = "org.freedesktop.DBus.Introspectable";
const peer_interface = "org.freedesktop.DBus.Peer";
const bus_name = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";

gpa: Allocator,
options: Options,
/// By path: the values of each interface it has.
objects: std.StringArrayHashMapUnmanaged(Object) = .empty,
connection: ?Connection = null,
state: State = .off,
refusal: Refusal = .not_allowed,
request_serial: u32 = 0,
/// What made sending fail, which ends the connection.
failure: ?Connection.Error = null,

/// The values of an object's properties: by interface, as the options list them, then by
/// property, in its order; null for an interface it does not have.
const Object = struct {
  parts: []?[]Value,
};

pub fn init(gpa: Allocator, options: Options) Error!Service {
  if (!names.isBusName(options.name) or !names.isObjectPath(options.root)) return error.Invalid;
  for (options.interfaces) |interface| {
    if (!names.isInterface(interface.name)) return error.Invalid;
    for (interface.properties) |property| {
      if (!names.isMember(property.name)) return error.Invalid;
      if (!signature.isSingle(property.signature)) return error.Invalid;
    }
  }
  return .{ .gpa = gpa, .options = options };
}

pub fn deinit(s: *Service) void {
  s.disconnect();
  for (s.objects.keys(), s.objects.values()) |path, object| {
    s.freeObject(object);
    s.gpa.free(path);
  }
  s.objects.deinit(s.gpa);
}

fn freeObject(s: *Service, object: Object) void {
  for (object.parts) |part| {
    s.freePart(part);
  }
  s.gpa.free(object.parts);
}

fn freePart(s: *Service, part: ?[]Value) void {
  const values = part orelse return;
  for (values) |v| {
    v.deinit(s.gpa);
  }
  s.gpa.free(values);
}

fn interfaceIndex(s: *const Service, name: []const u8) ?usize {
  for (s.options.interfaces, 0..) |interface, i| {
    if (std.mem.eql(u8, interface.name, name)) return i;
  }
  return null;
}

fn propertyIndex(interface: Interface, name: []const u8) ?usize {
  for (interface.properties, 0..) |property, i| {
    if (std.mem.eql(u8, property.name, name)) return i;
  }
  return null;
}

/// Whether `path` is below the root, where objects go.
fn underRoot(s: *const Service, path: []const u8) bool {
  const root = s.options.root;
  if (std.mem.eql(u8, root, "/")) return path.len > 1;
  return path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// Publishes the object at `path` with `interface`, every property of which `properties` gives:
/// a new object, a new interface of it, or new values for all its properties.
pub fn put(
  s: *Service,
  path: []const u8,
  interface: []const u8,
  properties: []const Property,
) Error!void {
  const index = s.interfaceIndex(interface) orelse return error.Invalid;
  const info = s.options.interfaces[index];
  if (!names.isObjectPath(path) or !s.underRoot(path)) return error.Invalid;
  if (properties.len != info.properties.len) return error.Invalid;
  for (properties) |property| {
    _ = propertyIndex(info, property.name) orelse return error.Invalid;
  }
  if (s.objects.getPtr(path)) |object| {
    if (object.parts[index] != null) return s.set(path, interface, properties);
  }
  const values = try s.cloneProperties(info, properties);
  errdefer s.freePart(values);
  const entry = try s.objects.getOrPut(s.gpa, path);
  if (!entry.found_existing) {
    errdefer s.objects.swapRemoveAt(entry.index);
    entry.key_ptr.* = try s.gpa.dupe(u8, path);
    errdefer s.gpa.free(entry.key_ptr.*);
    const parts = try s.gpa.alloc(?[]Value, s.options.interfaces.len);
    @memset(parts, null);
    entry.value_ptr.* = .{ .parts = parts };
  }
  entry.value_ptr.parts[index] = values;
  s.interfacesAdded(entry.key_ptr.*, index);
}

/// The values of `properties`, all those of `info`, in its order.
fn cloneProperties(s: *Service, info: Interface, properties: []const Property) Error![]Value {
  const values = try s.gpa.alloc(Value, info.properties.len);
  var done: usize = 0;
  errdefer {
    for (values[0..done]) |v| {
      v.deinit(s.gpa);
    }
    s.gpa.free(values);
  }
  for (info.properties, values) |declared, *v| {
    const given = for (properties) |property| {
      if (std.mem.eql(u8, property.name, declared.name)) break property.value;
    } else return error.Invalid;
    if (!given.is(declared.signature) or !given.isValid()) return error.Invalid;
    v.* = try given.clone(s.gpa);
    done += 1;
  }
  return values;
}

/// Gives new values to some properties of a published object's interface: those that differ
/// from what they were are signalled.
pub fn set(
  s: *Service,
  path: []const u8,
  interface: []const u8,
  properties: []const Property,
) Error!void {
  const index = s.interfaceIndex(interface) orelse return error.Invalid;
  const info = s.options.interfaces[index];
  const object = s.objects.getPtr(path) orelse return error.Invalid;
  const values = object.parts[index] orelse return error.Invalid;
  // Checked and copied first: a property refused leaves them all as they were.
  var arena: std.heap.ArenaAllocator = .init(s.gpa);
  defer arena.deinit();
  const copies = try arena.allocator().alloc(?Value, info.properties.len);
  @memset(copies, null);
  errdefer for (copies) |copy| {
    if (copy) |v| {
      v.deinit(s.gpa);
    }
  };
  for (properties) |property| {
    const i = propertyIndex(info, property.name) orelse return error.Invalid;
    if (!property.value.is(info.properties[i].signature) or !property.value.isValid()) {
      return error.Invalid;
    }
    if (values[i].eql(property.value)) continue;
    if (copies[i]) |earlier| {
      earlier.deinit(s.gpa);
    }
    copies[i] = try property.value.clone(s.gpa);
  }
  var changed: std.ArrayList(Value.Entry) = .empty;
  try changed.ensureTotalCapacity(arena.allocator(), info.properties.len);
  for (copies, values, info.properties) |copy, *v, declared| {
    const new = copy orelse continue;
    v.deinit(s.gpa);
    v.* = new;
    changed.appendAssumeCapacity(.{
      .key = .{ .string = declared.name },
      .value = .{ .variant = v },
    });
  }
  if (changed.items.len == 0) return;
  s.signal(
    path,
    properties_interface,
    "PropertiesChanged",
    &.{
      .{ .string = interface },
      .{ .dict = .{ .key = "s", .value = "v", .entries = changed.items } },
      .{ .array = .{ .element = "s", .items = &.{} } },
    },
  );
}

/// Removes a published object, with all its interfaces.
pub fn remove(s: *Service, path: []const u8) void {
  const entry = s.objects.fetchSwapRemove(path) orelse return;
  defer s.gpa.free(entry.key);
  defer s.freeObject(entry.value);
  var interfaces: [8]Value = undefined;
  var count: usize = 0;
  for (entry.value.parts, s.options.interfaces) |part, interface| {
    if (part == null or count == interfaces.len) continue;
    interfaces[count] = .{ .string = interface.name };
    count += 1;
  }
  s.signal(
    s.options.root,
    object_manager_interface,
    "InterfacesRemoved",
    &.{
      .{ .object_path = entry.key },
      .{ .array = .{ .element = "s", .items = interfaces[0..count] } },
    },
  );
}

/// The value of a published property, as clients read it.
pub fn get(
  s: *const Service,
  path: []const u8,
  interface: []const u8,
  property: []const u8,
) ?Value {
  const index = s.interfaceIndex(interface) orelse return null;
  const object = s.objects.get(path) orelse return null;
  const values = object.parts[index] orelse return null;
  return values[propertyIndex(s.options.interfaces[index], property) orelse return null];
}

fn interfacesAdded(s: *Service, path: []const u8, index: usize) void {
  if (s.state != .published) return;
  var arena: std.heap.ArenaAllocator = .init(s.gpa);
  defer arena.deinit();
  const entry: Value.Entry = .{
    .key = .{ .string = s.options.interfaces[index].name },
    .value = s.propertiesOf(arena.allocator(), index, s.objects.get(path).?.parts[index].?) catch {
      s.failure = error.OutOfMemory;
      return;
    },
  };
  s.signal(
    s.options.root,
    object_manager_interface,
    "InterfacesAdded",
    &.{
      .{ .object_path = path },
      .{ .dict = .{ .key = "s", .value = "a{sv}", .entries = &.{ entry } } },
    },
  );
}

/// An interface's properties, as GetAll gives them.
fn propertiesOf(
  s: *const Service,
  arena: Allocator,
  index: usize,
  values: []const Value,
) Error!Value {
  const info = s.options.interfaces[index];
  const entries = try arena.alloc(Value.Entry, values.len);
  for (entries, info.properties, values) |*entry, declared, *v| {
    entry.* = .{ .key = .{ .string = declared.name }, .value = .{ .variant = v } };
  }
  return .{ .dict = .{ .key = "s", .value = "v", .entries = entries } };
}

/// Sends a signal, if the name is ours: a failure ends the connection, as `failure` tells.
fn signal(
  s: *Service,
  path: []const u8,
  interface: []const u8,
  member: []const u8,
  body: []const Value,
) void {
  if (s.state != .published) return;
  const c = &(s.connection orelse return);
  _ = c.send(
    .{ .type = .signal, .path = path, .interface = interface, .member = member },
    body,
  ) catch |e| {
    s.failure = e;
  };
}

/// Starts connecting, as `uid`: what to send is then `pending`.
pub fn connect(s: *Service, uid: u32) Error!void {
  s.disconnect();
  s.connection = Connection.init(s.gpa, uid) catch return error.OutOfMemory;
  s.state = .connecting;
}

pub fn disconnect(s: *Service) void {
  if (s.connection) |*c| {
    c.deinit();
  }
  s.connection = null;
  s.state = .off;
  s.failure = null;
  s.request_serial = 0;
}

/// What is to be written to the bus.
pub fn pending(s: *const Service) []const u8 {
  const c = &(s.connection orelse return "");
  return c.pending();
}

pub fn written(s: *Service, n: usize) void {
  if (s.connection) |*c| {
    c.written(n);
  }
}

/// Takes bytes from the bus, and answers the messages they complete.
pub fn received(s: *Service, bytes: []const u8) Connection.Error!void {
  const c = &(s.connection orelse return);
  try c.receive(bytes);
  var arena: std.heap.ArenaAllocator = .init(s.gpa);
  defer arena.deinit();
  while (try c.next(arena.allocator())) |m| {
    try s.handle(arena.allocator(), &m);
    _ = arena.reset(.retain_capacity);
  }
  if (s.state == .connecting and c.ready()) {
    // Not queued: another owner refuses it at once, rather than hand it over some day.
    const do_not_queue = 4;
    s.request_serial = try c.send(
      .{
        .type = .method_call,
        .destination = bus_name,
        .path = bus_path,
        .interface = bus_name,
        .member = "RequestName",
      },
      &.{.{ .string = s.options.name }, .{ .uint32 = do_not_queue }},
    );
    s.state = .requesting;
  }
  if (s.failure) |e| return e;
}

fn handle(s: *Service, arena: Allocator, m: *const Message) Connection.Error!void {
  switch (m.type) {
    .method_call => try s.call(arena, m),
    .method_return, .@"error" => if (s.request_serial != 0 and m.reply_serial == s.request_serial) {
      s.request_serial = 0;
      s.nameAnswered(arena, m);
    },
    // NameAcquired and NameLost, which the answer to RequestName already told.
    else => {},
  }
}

fn nameAnswered(s: *Service, arena: Allocator, m: *const Message) void {
  const primary_owner = 1;
  const already_owner = 4;
  if (m.type == .@"error") {
    s.state = .refused;
    s.refusal = .not_allowed;
    return;
  }
  const values = m.values(arena) catch &.{};
  const reply = if (values.len == 1 and values[0] == .uint32) values[0].uint32 else 0;
  if (reply == primary_owner or reply == already_owner) {
    s.state = .published;
  } else {
    s.state = .refused;
    s.refusal = .taken;
  }
}

/// A method call's answer, or the error it failed with.
const Answer = union(enum) {
  values: []const Value,
  failed: struct { name: []const u8, message: []const u8 },
};

fn call(s: *Service, arena: Allocator, m: *const Message) Connection.Error!void {
  const result = s.answer(arena, m) catch |e| switch (e) {
    error.OutOfMemory => return error.OutOfMemory,
    error.Invalid => failed("InvalidArgs", "the arguments are not those the method takes"),
  };
  if (m.flags.no_reply_expected) return;
  const c = &(s.connection orelse return);
  switch (result) {
    .values => |values| _ = try c.send(
      .{ .type = .method_return, .reply_serial = m.serial, .destination = m.sender },
      values,
    ),
    .failed => |f| _ = try c.send(
      .{
        .type = .@"error",
        .reply_serial = m.serial,
        .destination = m.sender,
        .error_name = f.name,
      },
      &.{.{ .string = f.message }},
    ),
  }
}

fn failed(comptime name: []const u8, message: []const u8) Answer {
  return .{ .failed = .{ .name = "org.freedesktop.DBus.Error." ++ name, .message = message } };
}

const Method = enum { Ping, GetMachineId, Introspect, Get, GetAll, Set, GetManagedObjects };

fn answer(s: *Service, arena: Allocator, m: *const Message) Error!Answer {
  const path = m.path.?;
  const member = std.meta.stringToEnum(Method, m.member.?);
  const interface = m.interface orelse if (member) |known| switch (known) {
    .Ping, .GetMachineId => peer_interface,
    .Introspect => introspectable_interface,
    .Get, .GetAll, .Set => properties_interface,
    .GetManagedObjects => object_manager_interface,
  } else return failed("UnknownMethod", "no such method");
  const standard = std.mem.eql(u8, interface, peer_interface) or
    std.mem.eql(u8, interface, introspectable_interface) or
    std.mem.eql(u8, interface, properties_interface) or
    std.mem.eql(u8, interface, object_manager_interface);
  if (!standard) {
    if (s.interfaceIndex(interface) != null) return failed("UnknownMethod", "no such method");
    return failed("UnknownInterface", "no such interface");
  }
  const method = member orelse return failed("UnknownMethod", "no such method");
  const expected: []const u8 = switch (method) {
    .Get => "ss",
    .GetAll => "s",
    .Set => "ssv",
    else => "",
  };
  if (!std.mem.eql(u8, m.signature, expected)) return error.Invalid;
  const args = m.values(arena) catch return error.Invalid;
  // Peer answers on any path, as the specification says.
  if (std.mem.eql(u8, interface, peer_interface)) {
    return switch (method) {
      .Ping => .{ .values = &.{} },
      .GetMachineId => if (s.options.machine_id) |*id|
        .{ .values = try arena.dupe(Value, &.{.{ .string = try arena.dupe(u8, id) }}) }
      else
        failed("Failed", "the machine's id is not known"),
      else => failed("UnknownMethod", "no such method"),
    };
  }
  if (!s.isNode(path)) return failed("UnknownObject", "no such object");
  if (std.mem.eql(u8, interface, introspectable_interface)) {
    if (method != .Introspect) return failed("UnknownMethod", "no such method");
    const xml = try s.introspect(arena, path);
    return .{ .values = try arena.dupe(Value, &.{.{ .string = xml }}) };
  }
  const is_root = std.mem.eql(u8, path, s.options.root);
  const object = s.objects.get(path);
  if (object == null and !is_root) return failed("UnknownObject", "no such object");
  if (std.mem.eql(u8, interface, object_manager_interface)) {
    if (!is_root) return failed("UnknownInterface", "no such interface");
    if (method != .GetManagedObjects) return failed("UnknownMethod", "no such method");
    return .{ .values = try arena.dupe(Value, &.{ try s.managedObjects(arena) }) };
  }
  if (method != .Get and method != .GetAll and method != .Set) {
    return failed("UnknownMethod", "no such method");
  }
  const name = args[0].string;
  const index = s.interfaceIndex(name);
  // The root's ObjectManager, and the standard interfaces, have no properties.
  const values = if (index != null and object != null) object.?.parts[index.?] else null;
  if (values == null) {
    if (method == .GetAll and (is_root or isStandard(name))) {
      return .{
        .values = try arena.dupe(
          Value,
          &.{.{ .dict = .{ .key = "s", .value = "v", .entries = &.{} } }},
        ),
      };
    }
    return failed("UnknownInterface", "no such interface");
  }
  const info = s.options.interfaces[index.?];
  switch (method) {
    .GetAll => return .{
      .values = try arena.dupe(Value, &.{ try s.propertiesOf(arena, index.?, values.?) }),
    },
    .Get, .Set => {
      const i = propertyIndex(info, args[1].string) orelse
        return failed("UnknownProperty", "no such property");
      if (method == .Set) return failed("PropertyReadOnly", "the property is read-only");
      return .{ .values = try arena.dupe(Value, &.{.{ .variant = &values.?[i] }}) };
    },
    else => unreachable,
  }
}

fn isStandard(interface: []const u8) bool {
  for ([_][]const u8{
    properties_interface,
    object_manager_interface,
    introspectable_interface,
    peer_interface,
  }) |name| {
    if (std.mem.eql(u8, name, interface)) return true;
  }
  return false;
}

/// The objects below the root, with their interfaces and properties, as GetManagedObjects gives
/// them.
fn managedObjects(s: *const Service, arena: Allocator) Error!Value {
  const entries = try arena.alloc(Value.Entry, s.objects.count());
  for (entries, s.objects.keys(), s.objects.values()) |*entry, path, object| {
    var interfaces: std.ArrayList(Value.Entry) = .empty;
    for (object.parts, 0..) |part, index| {
      const values = part orelse continue;
      try interfaces.append(arena, .{
        .key = .{ .string = s.options.interfaces[index].name },
        .value = try s.propertiesOf(arena, index, values),
      });
    }
    entry.* = .{
      .key = .{ .object_path = path },
      .value = .{ .dict = .{ .key = "s", .value = "a{sv}", .entries = interfaces.items } },
    };
  }
  return .{ .dict = .{ .key = "o", .value = "a{sa{sv}}", .entries = entries } };
}

/// Whether `path` is an object, the root, or above one of them: what Introspect answers on.
fn isNode(s: *const Service, path: []const u8) bool {
  if (isAbove(path, s.options.root)) return true;
  for (s.objects.keys()) |object| {
    if (isAbove(path, object)) return true;
  }
  return false;
}

/// Whether `path` is `other`, or above it.
fn isAbove(path: []const u8, other: []const u8) bool {
  if (std.mem.eql(u8, path, other)) return true;
  if (std.mem.eql(u8, path, "/")) return true;
  return other.len > path.len and std.mem.startsWith(u8, other, path) and other[path.len] == '/';
}

/// The name of the node below `path` on the way to `other`, if `other` is below it.
fn childToward(path: []const u8, other: []const u8) ?[]const u8 {
  if (std.mem.eql(u8, path, other) or !isAbove(path, other)) return null;
  const start = if (std.mem.eql(u8, path, "/")) 1 else path.len + 1;
  const rest = other[start..];
  return rest[0..std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

fn introspect(s: *const Service, arena: Allocator, path: []const u8) Error![]const u8 {
  var out: std.Io.Writer.Allocating = .init(arena);
  const w = &out.writer;
  const is_root = std.mem.eql(u8, path, s.options.root);
  const object = s.objects.get(path);
  writeIntrospection(w, s.options.interfaces, is_root, object) catch return error.OutOfMemory;
  var children: std.ArrayList([]const u8) = .empty;
  const others = try arena.alloc([]const u8, s.objects.count() + 1);
  others[0] = s.options.root;
  @memcpy(others[1..], s.objects.keys());
  for (others) |other| {
    const child = childToward(path, other) orelse continue;
    for (children.items) |known| {
      if (std.mem.eql(u8, known, child)) break;
    } else {
      try children.append(arena, child);
    }
  }
  for (children.items) |child| {
    w.print(" <node name=\"{s}\"/>\n", .{ child }) catch return error.OutOfMemory;
  }
  w.writeAll("</node>\n") catch return error.OutOfMemory;
  return out.written();
}

fn writeIntrospection(
  w: *std.Io.Writer,
  interfaces: []const Interface,
  is_root: bool,
  object: ?Object,
) std.Io.Writer.Error!void {
  try w.writeAll(
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.freedesktop.DBus.Peer">
    \\  <method name="Ping"/>
    \\  <method name="GetMachineId">
    \\   <arg name="machine_uuid" type="s" direction="out"/>
    \\  </method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect">
    \\   <arg name="xml_data" type="s" direction="out"/>
    \\  </method>
    \\ </interface>
    \\
  );
  if (!is_root and object == null) return;
  try w.writeAll(
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get">
    \\   <arg name="interface_name" type="s" direction="in"/>
    \\   <arg name="property_name" type="s" direction="in"/>
    \\   <arg name="value" type="v" direction="out"/>
    \\  </method>
    \\  <method name="GetAll">
    \\   <arg name="interface_name" type="s" direction="in"/>
    \\   <arg name="properties" type="a{sv}" direction="out"/>
    \\  </method>
    \\  <method name="Set">
    \\   <arg name="interface_name" type="s" direction="in"/>
    \\   <arg name="property_name" type="s" direction="in"/>
    \\   <arg name="value" type="v" direction="in"/>
    \\  </method>
    \\  <signal name="PropertiesChanged">
    \\   <arg name="interface_name" type="s"/>
    \\   <arg name="changed_properties" type="a{sv}"/>
    \\   <arg name="invalidated_properties" type="as"/>
    \\  </signal>
    \\ </interface>
    \\
  );
  if (is_root) {
    try w.writeAll(
      \\ <interface name="org.freedesktop.DBus.ObjectManager">
      \\  <method name="GetManagedObjects">
      \\   <arg name="objects" type="a{oa{sa{sv}}}" direction="out"/>
      \\  </method>
      \\  <signal name="InterfacesAdded">
      \\   <arg name="object_path" type="o"/>
      \\   <arg name="interfaces_and_properties" type="a{sa{sv}}"/>
      \\  </signal>
      \\  <signal name="InterfacesRemoved">
      \\   <arg name="object_path" type="o"/>
      \\   <arg name="interfaces" type="as"/>
      \\  </signal>
      \\ </interface>
      \\
    );
  }
  const o = object orelse return;
  for (o.parts, interfaces) |part, interface| {
    if (part == null) continue;
    // Names and signatures, as the options declare them, need no escaping.
    try w.print(" <interface name=\"{s}\">\n", .{ interface.name });
    for (interface.properties) |property| {
      try w.print("  <property name=\"{s}\" type=\"{s}\" access=\"read\"/>\n", .{
        property.name,
        property.signature,
      });
    }
    try w.writeAll(" </interface>\n");
  }
}

const testing = std.testing;

const test_interfaces = [_]Interface{
  .{
    .name = "io.example.Thing1.Device",
    .properties = &.{
      .{ .name = "Name", .signature = "s" },
      .{ .name = "Readings", .signature = "a{sv}" },
    },
  },
  .{ .name = "io.example.Thing1.Extra", .properties = &.{.{ .name = "Count", .signature = "u" }} },
};

const test_options: Options = .{
  .name = "io.example.Thing1",
  .root = "/io/example/Thing1",
  .interfaces = &test_interfaces,
  .machine_id = "0123456789abcdef0123456789abcdef".*,
};

/// Plays the bus to a service: takes what it sends, and sends it messages.
const TestBus = struct {
  service: Service,
  arena: std.heap.ArenaAllocator,
  serial: u32 = 100,

  fn init() !TestBus {
    return .{
      .service = try .init(testing.allocator, test_options),
      .arena = .init(testing.allocator),
    };
  }

  fn deinit(b: *TestBus) void {
    b.service.deinit();
    b.arena.deinit();
  }

  /// Connects the service, and answers until its name is its own, or refused with `answer`.
  fn connect(b: *TestBus, refusal: ?Message) !void {
    try b.service.connect(1000);
    try b.service.received("OK 0123456789abcdef0123456789abcdef\r\n");
    const hello = try b.take();
    try testing.expectEqual(1, hello.len);
    try testing.expectEqualStrings("Hello", hello[0].member.?);
    try b.send(
      .{ .type = .method_return, .reply_serial = hello[0].serial },
      &.{.{ .string = ":1.5" }},
    );
    const request = try b.take();
    try testing.expectEqualStrings("RequestName", request[0].member.?);
    const values = try request[0].values(b.arena.allocator());
    try testing.expectEqualStrings("io.example.Thing1", values[0].string);
    var reply = refusal orelse Message{ .type = .method_return };
    reply.reply_serial = request[0].serial;
    const owner: []const Value = &.{.{ .uint32 = 1 }};
    const exists: []const Value = &.{.{ .uint32 = 3 }};
    try b.send(
      reply,
      if (refusal == null) owner else if (reply.type == .method_return) exists else &.{},
    );
  }

  /// Sends the service a message, as the bus would.
  fn send(b: *TestBus, m: Message, body: []const Value) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    b.serial += 1;
    try wire.encode(testing.allocator, &bytes, m, b.serial, body);
    try b.service.received(bytes.items);
  }

  /// A client's method call, and the messages the service sent since.
  fn call(
    b: *TestBus,
    path: []const u8,
    interface: ?[]const u8,
    member: []const u8,
    args: []const Value,
  ) ![]Message {
    try b.send(
      .{
        .type = .method_call,
        .path = path,
        .interface = interface,
        .member = member,
        .destination = "io.example.Thing1",
        .sender = ":1.9",
      },
      args,
    );
    return b.take();
  }

  /// What the service sent, as messages: the text of the authentication left out.
  fn take(b: *TestBus) ![]Message {
    const a = b.arena.allocator();
    var bytes = try a.dupe(u8, b.service.pending());
    b.service.written(bytes.len);
    if (std.mem.indexOf(u8, bytes, "BEGIN\r\n")) |i| {
      bytes = bytes[i + "BEGIN\r\n".len..];
    }
    var messages: std.ArrayList(Message) = .empty;
    while (bytes.len > 0) {
      const len: usize = @intCast(try wire.frameLength(bytes[0..wire.fixed_header_len]));
      try messages.append(a, try wire.decode(a, bytes[0..len]));
      bytes = bytes[len..];
    }
    return messages.items;
  }

  /// The one answer to a call: its values, after checking that it went to the caller.
  fn answer(b: *TestBus, messages: []const Message) ![]Value {
    try testing.expectEqual(1, messages.len);
    if (messages[0].type == .@"error") {
      std.debug.print("error: {s}\n", .{ messages[0].error_name.? });
      return error.TestUnexpectedResult;
    }
    try testing.expectEqual(MessageTypeTest.method_return, messages[0].type);
    try testing.expectEqualStrings(":1.9", messages[0].destination.?);
    return messages[0].values(b.arena.allocator());
  }

  fn failure(messages: []const Message) []const u8 {
    if (messages.len != 1 or messages[0].type != .@"error") return "(no error)";
    return messages[0].error_name.?;
  }
};

const MessageTypeTest = wire.MessageType;

fn putThing(s: *Service, path: []const u8, name: []const u8, temperature: f64) !void {
  const t: Value = .{ .double = temperature };
  try s.put(
    path,
    "io.example.Thing1.Device",
    &.{
      .{ .name = "Name", .value = .{ .string = name } },
      .{
        .name = "Readings",
        .value = .{
          .dict = .{
            .key = "s",
            .value = "v",
            .entries = &.{.{ .key = .{ .string = "temperature" }, .value = .{ .variant = &t } }},
          },
        },
      },
    },
  );
}

test "a service owns its name, and answers from its objects" {
  var b: TestBus = try .init();
  defer b.deinit();
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "living room", 21.5);
  try b.connect(null);
  try testing.expectEqual(State.published, b.service.state);
  // Published before the name was owned: no signal.
  try testing.expectEqual(0, (try b.take()).len);

  const objects = try b.answer(
    try b.call("/io/example/Thing1", object_manager_interface, "GetManagedObjects", &.{}),
  );
  const entry = objects[0].dict.entries[0];
  try testing.expectEqualStrings("/io/example/Thing1/devices/a1", entry.key.object_path);
  try testing.expectEqualStrings(
    "io.example.Thing1.Device",
    entry.value.dict.entries[0].key.string,
  );

  const name = try b.answer(
    try b.call(
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "Get",
      &.{.{ .string = "io.example.Thing1.Device" }, .{ .string = "Name" }},
    ),
  );
  try testing.expectEqualStrings("living room", name[0].variant.string);
  const all = try b.answer(
    try b.call(
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "GetAll",
      &.{.{ .string = "io.example.Thing1.Device" }},
    ),
  );
  try testing.expectEqual(2, all[0].dict.entries.len);
  const readings = all[0].dict.entries[1].value.variant.dict.entries;
  try testing.expectEqual(21.5, readings[0].value.variant.double);
  // Without the interface, which the specification allows.
  _ = try b.answer(
    try b.call(
      "/io/example/Thing1/devices/a1",
      null,
      "GetAll",
      &.{.{ .string = "io.example.Thing1.Device" }},
    ),
  );
  _ = try b.answer(try b.call("/anywhere", peer_interface, "Ping", &.{}));
  const id = try b.answer(try b.call("/", peer_interface, "GetMachineId", &.{}));
  try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", id[0].string);
  // The ObjectManager's interface has no properties.
  const none = try b.answer(
    try b.call(
      "/io/example/Thing1",
      properties_interface,
      "GetAll",
      &.{.{ .string = object_manager_interface }},
    ),
  );
  try testing.expectEqual(0, none[0].dict.entries.len);

  const errors = [_]struct { []const u8, []const u8, []const u8, []const Value, []const u8 }{
    .{
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "Set",
      &.{
        .{ .string = "io.example.Thing1.Device" },
        .{ .string = "Name" },
        .{ .variant = &.{ .string = "x" } },
      },
      "org.freedesktop.DBus.Error.PropertyReadOnly",
    },
    .{
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "Get",
      &.{.{ .string = "io.example.Thing1.Device" }, .{ .string = "Colour" }},
      "org.freedesktop.DBus.Error.UnknownProperty",
    },
    .{
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "GetAll",
      &.{.{ .string = "io.example.Thing1.Extra" }},
      "org.freedesktop.DBus.Error.UnknownInterface",
    },
    .{
      "/io/example/Thing1/devices/b2",
      properties_interface,
      "GetAll",
      &.{.{ .string = "io.example.Thing1.Device" }},
      "org.freedesktop.DBus.Error.UnknownObject",
    },
    .{
      "/io/example/Thing1/devices/a1",
      properties_interface,
      "Get",
      &.{.{ .string = "io.example.Thing1.Device" }},
      "org.freedesktop.DBus.Error.InvalidArgs",
    },
    .{
      "/io/example/Thing1/devices/a1",
      "io.example.Thing1.Device",
      "Explode",
      &.{},
      "org.freedesktop.DBus.Error.UnknownMethod",
    },
    .{
      "/io/example/Thing1/devices/a1",
      "io.example.Other",
      "Explode",
      &.{},
      "org.freedesktop.DBus.Error.UnknownInterface",
    },
    .{
      "/io/example/Thing1/devices",
      object_manager_interface,
      "GetManagedObjects",
      &.{},
      "org.freedesktop.DBus.Error.UnknownObject",
    },
    .{
      "/io/example/Thing1/devices/a1",
      object_manager_interface,
      "GetManagedObjects",
      &.{},
      "org.freedesktop.DBus.Error.UnknownInterface",
    },
  };
  for (errors) |e| {
    try testing.expectEqualStrings(e[4], TestBus.failure(try b.call(e[0], e[1], e[2], e[3])));
  }

  // A call that wants no reply gets none.
  try b.send(
    .{
      .type = .method_call,
      .flags = .{ .no_reply_expected = true },
      .path = "/",
      .interface = peer_interface,
      .member = "Ping",
    },
    &.{},
  );
  try testing.expectEqual(0, (try b.take()).len);
}

test "changes are signalled once the name is the service's, and only what changed" {
  var b: TestBus = try .init();
  defer b.deinit();
  try b.connect(null);
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "living room", 21.5);
  const added = try b.take();
  try testing.expectEqual(1, added.len);
  try testing.expectEqualStrings("InterfacesAdded", added[0].member.?);
  try testing.expectEqualStrings("/io/example/Thing1", added[0].path.?);
  try testing.expectEqual(null, added[0].destination);
  const values = try added[0].values(b.arena.allocator());
  try testing.expectEqualStrings("/io/example/Thing1/devices/a1", values[0].object_path);

  // The same values again: nothing to signal.
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "living room", 21.5);
  try testing.expectEqual(0, (try b.take()).len);
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "living room", 22);
  const changed = try b.take();
  try testing.expectEqualStrings("PropertiesChanged", changed[0].member.?);
  try testing.expectEqualStrings("/io/example/Thing1/devices/a1", changed[0].path.?);
  const what = try changed[0].values(b.arena.allocator());
  try testing.expectEqualStrings("io.example.Thing1.Device", what[0].string);
  try testing.expectEqual(1, what[1].dict.entries.len);
  try testing.expectEqualStrings("Readings", what[1].dict.entries[0].key.string);
  try testing.expectEqual(0, what[2].array.items.len);

  try b.service.put(
    "/io/example/Thing1/devices/a1",
    "io.example.Thing1.Extra",
    &.{.{ .name = "Count", .value = .{ .uint32 = 3 } }},
  );
  try testing.expectEqualStrings("InterfacesAdded", (try b.take())[0].member.?);
  try b.service.set(
    "/io/example/Thing1/devices/a1",
    "io.example.Thing1.Extra",
    &.{.{ .name = "Count", .value = .{ .uint32 = 4 } }},
  );
  try testing.expectEqual(
    4,
    b.service.get("/io/example/Thing1/devices/a1", "io.example.Thing1.Extra", "Count").?.uint32,
  );
  _ = try b.take();
  b.service.remove("/io/example/Thing1/devices/a1");
  const removed = try b.take();
  try testing.expectEqualStrings("InterfacesRemoved", removed[0].member.?);
  const gone = try removed[0].values(b.arena.allocator());
  try testing.expectEqual(2, gone[1].array.items.len);
  try testing.expectEqual(
    null,
    b.service.get("/io/example/Thing1/devices/a1", "io.example.Thing1.Extra", "Count"),
  );
}

test "the bus refusing the name: not allowed, or taken" {
  var b: TestBus = try .init();
  defer b.deinit();
  try b.connect(.{ .type = .@"error", .error_name = "org.freedesktop.DBus.Error.AccessDenied" });
  try testing.expectEqual(State.refused, b.service.state);
  try testing.expectEqual(Refusal.not_allowed, b.service.refusal);
  try b.connect(.{ .type = .method_return });
  try testing.expectEqual(State.refused, b.service.state);
  try testing.expectEqual(Refusal.taken, b.service.refusal);
}

test "introspection tells the interfaces of a node and the nodes below it" {
  var b: TestBus = try .init();
  defer b.deinit();
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "a", 1);
  try putThing(&b.service, "/io/example/Thing1/devices/b2", "b", 2);
  try b.connect(null);
  const top = try b.answer(try b.call("/", introspectable_interface, "Introspect", &.{}));
  try testing.expect(std.mem.indexOf(u8, top[0].string, "<node name=\"io\"/>") != null);
  try testing.expect(std.mem.indexOf(u8, top[0].string, "org.freedesktop.DBus.Properties") == null);
  const root = try b.answer(
    try b.call("/io/example/Thing1", introspectable_interface, "Introspect", &.{}),
  );
  try testing.expect(std.mem.indexOf(u8, root[0].string, object_manager_interface) != null);
  try testing.expect(std.mem.indexOf(u8, root[0].string, "<node name=\"devices\"/>") != null);
  const devices = try b.answer(
    try b.call("/io/example/Thing1/devices", introspectable_interface, "Introspect", &.{}),
  );
  try testing.expect(
    std.mem.indexOf(u8, devices[0].string, "<node name=\"a1\"/>\n <node name=\"b2\"/>") != null,
  );
  const device = try b.answer(
    try b.call("/io/example/Thing1/devices/a1", introspectable_interface, "Introspect", &.{}),
  );
  try testing.expect(
    std.mem.indexOf(
      u8,
      device[0].string,
      "<property name=\"Readings\" type=\"a{sv}\" access=\"read\"/>",
    ) != null,
  );
  try testing.expect(std.mem.indexOf(u8, device[0].string, "io.example.Thing1.Extra") == null);
  try testing.expectEqualStrings(
    "org.freedesktop.DBus.Error.UnknownObject",
    TestBus.failure(try b.call("/elsewhere", introspectable_interface, "Introspect", &.{})),
  );
}

test "what is published must be as the interfaces declare it" {
  var s: Service = try .init(testing.allocator, test_options);
  defer s.deinit();
  const extra = "io.example.Thing1.Extra";
  const count: []const Property = &.{.{ .name = "Count", .value = .{ .uint32 = 1 } }};
  try testing.expectError(error.Invalid, s.put("/io/example/Thing1", extra, count));
  try testing.expectError(error.Invalid, s.put("/elsewhere/x", extra, count));
  try testing.expectError(error.Invalid, s.put("/io/example/Thing1/x/", extra, count));
  try testing.expectError(error.Invalid, s.put("/io/example/Thing1/x", "io.example.Other", count));
  try testing.expectError(error.Invalid, s.put("/io/example/Thing1/x", extra, &.{}));
  try testing.expectError(
    error.Invalid,
    s.put("/io/example/Thing1/x", extra, &.{.{ .name = "Count", .value = .{ .int32 = 1 } }}),
  );
  try testing.expectError(
    error.Invalid,
    s.put(
      "/io/example/Thing1/x",
      "io.example.Thing1.Device",
      &.{
        .{ .name = "Name", .value = .{ .string = "\xff" } },
        .{
          .name = "Readings",
          .value = .{ .dict = .{ .key = "s", .value = "v", .entries = &.{} } },
        },
      },
    ),
  );
  try testing.expectError(error.Invalid, s.set("/io/example/Thing1/x", extra, count));
  try s.put("/io/example/Thing1/x", extra, count);
  try testing.expectError(
    error.Invalid,
    s.set("/io/example/Thing1/x", extra, &.{.{ .name = "Count", .value = .{ .string = "2" } }}),
  );
  try testing.expectEqual(1, s.get("/io/example/Thing1/x", extra, "Count").?.uint32);
  try testing.expectError(
    error.Invalid,
    Service.init(testing.allocator, .{ .name = "nodots", .root = "/", .interfaces = &.{} }),
  );

  // Running out of memory at any allocation leaves the service as it was.
  try testing.checkAllAllocationFailures(
    testing.allocator,
    struct {
      fn publish(gpa: Allocator) !void {
        var service: Service = try .init(gpa, test_options);
        defer service.deinit();
        try putThing(&service, "/io/example/Thing1/devices/a1", "a", 1);
        try putThing(&service, "/io/example/Thing1/devices/a1", "a", 2);
        service.remove("/io/example/Thing1/devices/a1");
      }
    }.publish,
    .{},
  );
}

test "fuzz: a service survives whatever its clients ask" {
  try testing.fuzz({}, fuzzService, .{});
}

fn fuzzService(_: void, smith: *testing.Smith) !void {
  var b: TestBus = try .init();
  defer b.deinit();
  try putThing(&b.service, "/io/example/Thing1/devices/a1", "a", 1);
  try b.connect(null);
  const paths = [_][]const u8{
    "/",
    "/io",
    "/io/example/Thing1",
    "/io/example/Thing1/devices",
    "/io/example/Thing1/devices/a1",
    "/x",
  };
  const interfaces = [_]?[]const u8{
    null,
    properties_interface,
    object_manager_interface,
    introspectable_interface,
    peer_interface,
    "io.example.Thing1.Device",
    "io.example.Thing1.Extra",
    "a.b",
  };
  const members = [_][]const u8{
    "Get",
    "GetAll",
    "Set",
    "GetManagedObjects",
    "Introspect",
    "Ping",
    "GetMachineId",
    "Other",
  };
  const strings = [_][]const u8{
    "io.example.Thing1.Device",
    "io.example.Thing1.Extra",
    properties_interface,
    "Name",
    "Readings",
    "Count",
    "",
  };
  while (!smith.eos()) {
    var args: [3]Value = undefined;
    const count = smith.index(args.len + 1);
    for (args[0..count]) |*arg| {
      arg.* = switch (smith.index(3)) {
        0 => .{ .string = strings[smith.index(strings.len)] },
        1 => .{ .uint32 = smith.value(u32) },
        else => .{ .variant = &.{ .string = "x" } },
      };
    }
    const messages = try b.call(
      paths[smith.index(paths.len)],
      interfaces[smith.index(interfaces.len)],
      members[smith.index(members.len)],
      args[0..count],
    );
    // Every call is answered, once.
    try testing.expectEqual(1, messages.len);
    _ = b.arena.reset(.retain_capacity);
  }
}
