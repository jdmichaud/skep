//! D-Bus, for publishing a service's objects from a program with a poll loop. `Bus` is the
//! module's interface, and all a program uses: what is behind it can be replaced by an adapter
//! over another D-Bus library, such as sd-bus, without changing the program. The tests in
//! test/dbus-contract.sh check what clients see of a service through it, with busctl, and pass
//! as they are with any implementation.
//!
//! Behind it, in layers, none doing I/O but the last:
//! - signature.zig, names.zig, value.zig: the bus's types, names and values.
//! - wire.zig: the wire format, values and messages.
//! - auth.zig, Connection.zig: a connection: authentication, Hello, messages in and out.
//! - Service.zig: the objects, the bus's standard interfaces on them, and their signals.
//! - Bus.zig: the socket, connecting again, and the poll loop.
//!
//! As a service only, with read-only properties: no methods of its own, no calls to other
//! services, no signals listened to, no file descriptors passed.

pub const Bus = @import("Bus.zig");
pub const Value = Bus.Value;
pub const Interface = Bus.Interface;
pub const PropertyInfo = Bus.PropertyInfo;
pub const Property = Bus.Property;
pub const News = Bus.News;

test {
  _ = @import("signature.zig");
  _ = @import("names.zig");
  _ = @import("value.zig");
  _ = @import("wire.zig");
  _ = @import("auth.zig");
  _ = @import("Connection.zig");
  _ = @import("Service.zig");
  _ = @import("address.zig");
  _ = @import("Bus.zig");
}
