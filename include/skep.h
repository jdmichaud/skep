/* SPDX-License-Identifier: MIT */
/*
 * skep.h - the libskep C API
 *
 * DRAFT for review: nothing here is implemented yet, and everything may
 * still change. See doc/design.md for the principles behind it.
 *
 * Conventions
 *
 * - Functions returning int return 0 (or a documented non-negative value)
 *   on success, and a negative errno value on failure, for instance
 *   -EINVAL or -ETIMEDOUT. strerror(-r) describes the error.
 * - Objects are created and destroyed in pairs (skep_new/skep_free,
 *   skep_next_event/skep_event_free). Destroy functions accept NULL.
 * - libskep does no I/O. It never opens, reads or writes a device or a
 *   file, never reads the clock, never blocks, starts no threads and never
 *   calls back into the caller. The caller carries bytes between the dongle
 *   and libskep, tells it the time, and stores its state. Results are
 *   queued as events. Diagnostics are SKEP_EVENT_LOG events, never output.
 * - A failed internal check (an out-of-bounds index, an overflow) is a bug
 *   in libskep. Like a failed assert(), it aborts the program with a
 *   message on stderr, the only output libskep ever writes.
 * - Time is a monotonic clock in milliseconds, for instance
 *   CLOCK_MONOTONIC, always from the same clock.
 * - All of libskep's state is in its contexts: there is no global state.
 *   Separate contexts are independent, so a program can drive several
 *   dongles, one context each, and use different contexts from different
 *   threads at the same time. A context may be used from one thread at a
 *   time.
 * - Memory comes from the allocator given to skep_new(), malloc() unless
 *   the caller provides one.
 * - Devices are identified by their IEEE address (EUI-64), which never
 *   changes, rather than by their network address, which may.
 * - Values are passed in host byte order.
 */

#ifndef SKEP_H
#define SKEP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version ---------------------------------------------------------------- */

#define SKEP_VERSION_MAJOR 0
#define SKEP_VERSION_MINOR 0
#define SKEP_VERSION_PATCH 0

/*
 * Version of the library loaded at run time, encoded as
 * (major << 16) | (minor << 8) | patch, to be compared with the
 * SKEP_VERSION_* macros the program was compiled against.
 */
uint32_t skep_version(void);

/* Context ---------------------------------------------------------------- */

/* The Zigbee logic for one dongle and the network it coordinates. */
typedef struct skep_ctx skep_ctx;

/*
 * Where a context gets its memory. Everything libskep allocates for a
 * context, its events included, comes from the allocator given to
 * skep_new(); libskep has no allocator of its own.
 *
 * Every function gets ctx as its first argument. Sizes are in bytes and
 * never 0; alignment is a power of two. libskep always passes back the
 * size and alignment a block has, so the allocator need not record them.
 *
 * Zero the whole struct before setting the fields you use, for instance
 * with a designated initializer:
 *
 *   struct skep_allocator a = { .ctx = arena, .alloc = arena_alloc,
 *                               .free = arena_free };
 */
struct skep_allocator {
  void *ctx;
  /* Return a block of size bytes aligned to alignment, or NULL. Required. */
  void *(*alloc)(void *ctx, size_t size, size_t alignment);
  /*
   * Resize the block at ptr from size to new_size bytes, moving it if
   * needed, and return its address. Return NULL if it cannot be done; the
   * block must then be left as it was. Optional: without it, libskep
   * allocates a new block, copies and frees the old one.
   */
  void *(*realloc)(void *ctx, void *ptr, size_t size, size_t new_size, size_t alignment);
  /* Free the block at ptr. Required. */
  void (*free)(void *ctx, void *ptr, size_t size, size_t alignment);
  /* For later versions; must be NULL. */
  void *reserved[4];
};

/*
 * Create a context. Configure it with skep_set_option() and, if a state
 * was saved, skep_import_state(); then call skep_start().
 *
 * allocator is copied; NULL selects malloc() and free() from the C
 * library. What allocator->ctx refers to must stay usable until the
 * context and every event taken from it are freed. libskep calls the
 * allocator from the thread that calls into libskep, so an allocator used
 * from several threads, for instance by contexts in different threads or
 * by events freed in another thread, must be thread-safe.
 *
 * Errors: -ENOMEM, -EINVAL (alloc or free missing, or a reserved field
 * set).
 */
int skep_new(const struct skep_allocator *allocator, skep_ctx **ctx);

/*
 * Free the context. The dongle is the caller's: libskep does not close it.
 * Events already taken from the context stay valid.
 */
void skep_free(skep_ctx *ctx);

/*
 * Set an option. Options can only be set before skep_start(), except
 * log-level, which can be changed at any time. Values are strings so that
 * they can come straight from a configuration file.
 *
 *   driver           Dongle driver: "ezsp" (Silicon Labs EmberZNet) or
 *                    "sim" (a simulated network that needs no dongle, for
 *                    tests). Required.
 *   log-level        "error", "warning", "info" or "debug".
 *                    Default: "warning".
 *   frame-counter-margin
 *                    Added to the saved frame counters when the network is
 *                    restored onto a dongle, to stay ahead of frames sent
 *                    after the last refresh. Default: 100000.
 *   replace-network  "yes" lets skep_start() overwrite a network found on
 *                    the dongle with the imported one. Default: "no".
 *
 * Used only when a new network is formed (no network on the dongle and no
 * imported state):
 *   channel          11 to 26. Default: 15, which lies between Wi-Fi
 *                    channels 1 and 6.
 *   pan-id           16-bit PAN ID in hexadecimal. Default: random.
 *   extended-pan-id  64-bit extended PAN ID in hexadecimal. Default: random.
 *   network-key      128-bit network key in hexadecimal. Default: random.
 *
 * Errors: -ENOENT (unknown option), -EINVAL (invalid value),
 * -EBUSY (already started, for options other than log-level).
 */
int skep_set_option(skep_ctx *ctx, const char *name, const char *value);

enum skep_flow_control {
  SKEP_FLOW_CONTROL_NONE = 0,
  SKEP_FLOW_CONTROL_SOFTWARE = 1, /* XON/XOFF, handled by libskep */
  SKEP_FLOW_CONTROL_HARDWARE = 2, /* RTS/CTS */
};

/*
 * Serial settings the driver's dongles usually need, for the caller to
 * open the device with (8 data bits, no parity, 1 stop bit, raw mode).
 * The caller may use other settings for a dongle that needs them.
 *
 * Software flow control needs nothing from the caller: libskep pauses its
 * output on XOFF until XON, so raw mode (IXON off) is fine. For hardware
 * flow control, the caller enables RTS/CTS on the port.
 *
 * Errors: -EINVAL (no driver set), -ENOTSUP (the driver does not talk to
 * a serial device, like "sim").
 */
int skep_get_serial_defaults(const skep_ctx *ctx, unsigned *baudrate,
                             enum skep_flow_control *flow_control);

/*
 * Bring the network up, once the caller has opened the dongle.
 * - With an imported state: resume its network if the dongle holds it,
 *   restore it onto the dongle if the dongle holds none. If the dongle
 *   holds another network, stop with -EEXIST rather than lose either,
 *   unless the replace-network option allows overwriting it.
 * - Without a state: resume the dongle's network if it holds one,
 *   otherwise form a new network.
 *
 * This only starts the work: the first bytes for the dongle are now in
 * skep_output(). Success is reported by SKEP_EVENT_STARTED, failure by
 * SKEP_EVENT_STOPPED.
 *
 * Errors: -EINVAL (missing or inconsistent options), -EBUSY (already
 * started).
 */
int skep_start(skep_ctx *ctx);

/*
 * Stop cleanly: end pending requests with -ECANCELED, refresh the state
 * from the dongle (see skep_refresh_state()), then report
 * SKEP_EVENT_STOPPED. Keep running the loop until then, and save the
 * state after SKEP_EVENT_STATE_CHANGED as usual. The network stays on the
 * dongle and is resumed by the next skep_start().
 *
 * Errors: -ENETDOWN (not started).
 */
int skep_stop(skep_ctx *ctx);

/*
 * Tell libskep that the dongle is gone: a read or write error, or the
 * device was unplugged. Drops pending output, ends pending requests with
 * -ECANCELED and reports SKEP_EVENT_STOPPED with -ENOTCONN, at once and
 * without I/O. Call skep_start() once the dongle is open again.
 */
void skep_link_lost(skep_ctx *ctx);

/* Bytes and time ------------------------------------------------------- */

/*
 * The caller runs the loop. A minimal one, error handling left out:
 *
 *   skep_start(ctx);
 *   for (;;) {
 *     const uint8_t *out;
 *     size_t n = skep_output(ctx, &out);
 *     if (n > 0) {
 *       ssize_t w = write(fd, out, n);
 *       if (w > 0) skep_output_done(ctx, w, now());
 *     }
 *     uint64_t deadline;
 *     int timeout = skep_next_deadline(ctx, &deadline) ? ms_until(deadline) : -1;
 *     struct pollfd p = { fd, POLLIN | (skep_output(ctx, &out) ? POLLOUT : 0), 0 };
 *     poll(&p, 1, timeout);
 *     if (p.revents & POLLIN) {
 *       uint8_t in[256];
 *       ssize_t r = read(fd, in, sizeof in);
 *       if (r > 0) skep_input(ctx, in, r, now());
 *     }
 *     skep_advance(ctx, now());
 *     for (skep_event *e; (e = skep_next_event(ctx)); skep_event_free(e))
 *       handle(e);
 *   }
 *
 * The current time only enters through skep_input(), skep_output_done()
 * and skep_advance(). Requests take a deadline instead (see Requests), so
 * libskep never needs to know when a request was made. The protocol's
 * own timers start when bytes are written.
 */

/*
 * Hand over bytes read from the dongle, at time now.
 *
 * Errors: -ENOMEM. Bad frames from the dongle are not errors: libskep
 * recovers and reports what it could not recover from as events.
 */
int skep_input(skep_ctx *ctx, const uint8_t *data, size_t len, uint64_t now);

/*
 * Bytes waiting to be written to the dongle. Stores a pointer to them in
 * *data and returns their number, 0 if there are none. The bytes stay
 * valid until the next call on ctx.
 */
size_t skep_output(skep_ctx *ctx, const uint8_t **data);

/*
 * Tell libskep that the first len bytes from skep_output() were written,
 * at time now. A partial write is fine: the rest stays in skep_output().
 */
void skep_output_done(skep_ctx *ctx, size_t len, uint64_t now);

/*
 * When libskep next needs skep_advance() to be called, even if no byte
 * arrives. Returns 1 and stores the time in *deadline, or returns 0 if no
 * timer is pending. The deadline may change after any call on ctx.
 */
int skep_next_deadline(const skep_ctx *ctx, uint64_t *deadline);

/*
 * Run the timers that are due at time now. Calling it early or often is
 * harmless.
 *
 * Errors: -ENOMEM.
 */
int skep_advance(skep_ctx *ctx, uint64_t now);

/* Events ----------------------------------------------------------------- */

typedef struct skep_event skep_event;

/*
 * Newer versions of libskep add event types. Applications must ignore
 * (and free) events of a type they do not know.
 */
enum skep_event_type {
  /* The network is up. skep_event_get_network_origin() tells how. */
  SKEP_EVENT_STARTED = 1,
  /*
   * The context stopped, after skep_stop(), after skep_link_lost(), or
   * because of an error that libskep could not recover from, such as a
   * dongle that stopped answering. skep_event_get_error() tells which.
   * skep_start() may be called again.
   */
  SKEP_EVENT_STOPPED = 2,
  /* The join window opened or closed. See skep_event_get_duration(). */
  SKEP_EVENT_PERMIT_JOIN = 3,
  /*
   * A device joined the network: a new one, or a known one joining afresh
   * after a factory reset, which lost its bindings and reporting. libskep
   * now interviews and sets it up. A known device rejoining, for instance
   * after losing its parent, keeps its setup and causes no event, even if
   * its network address changed.
   */
  SKEP_EVENT_DEVICE_JOINED = 4,
  /*
   * A device has been interviewed and set up (bindings and reporting
   * configured from the device tables). Its endpoints and clusters are
   * known. Setup proceeds while the device is awake: a sensor that falls
   * asleep half-way is set up further when it is next heard from, which
   * may take hours.
   */
  SKEP_EVENT_DEVICE_READY = 5,
  /*
   * A device left the network, by itself or after skep_remove_device().
   * libskep keeps a device that left by itself: it may come back, and a
   * report of a leave is not always final (a device that loses its parent
   * may be reported as gone, then rejoin). Only skep_remove_device()
   * forgets a device.
   */
  SKEP_EVENT_DEVICE_LEFT = 6,
  /*
   * Attribute values a device reported by itself. Answers to
   * skep_read_attributes() come in SKEP_EVENT_REQUEST_DONE instead.
   */
  SKEP_EVENT_ATTRIBUTES = 7,
  /* A cluster command sent by a device, for instance by a remote. */
  SKEP_EVENT_COMMAND = 8,
  /*
   * A request finished. Every request ends with exactly one such event,
   * which carries its result.
   */
  SKEP_EVENT_REQUEST_DONE = 9,
  /* A diagnostic message, see skep_event_get_log(). */
  SKEP_EVENT_LOG = 10,
  /*
   * The state worth saving changed: network formed, device joined, left
   * or set up, and so on. Export it with skep_export_state() and store it.
   */
  SKEP_EVENT_STATE_CHANGED = 11,
  /*
   * Setting up a device failed: the device rejected a step, which
   * skep_event_get_error() and skep_event_get_status() describe as for
   * SKEP_EVENT_REQUEST_DONE. A device that stays silent has not failed:
   * its setup waits. libskep does not retry by itself, since the device
   * would most likely reject the step again; skep_setup_device() does.
   */
  SKEP_EVENT_DEVICE_SETUP_FAILED = 12,
  /*
   * Set the serial control lines of the dongle as skep_event_get_lines()
   * says, before the next skep_output(). Some dongles need them toggled to
   * leave their bootloader. libskep holds its output back until the event
   * has been taken. Applications without control lines (a dongle reached
   * over TCP) ignore it.
   */
  SKEP_EVENT_SERIAL_LINES = 13,
};

/*
 * Take the next event from the queue. Returns NULL when the queue is
 * empty. The event holds its own copy of everything it reports, and stays
 * valid until the caller frees it with skep_event_free(), even after
 * skep_free().
 */
skep_event *skep_next_event(skep_ctx *ctx);

void skep_event_free(skep_event *event);

enum skep_event_type skep_event_get_type(const skep_event *event);

/*
 * IEEE address of the device the event is about, or 0 for events not
 * about a device.
 */
uint64_t skep_event_get_device(const skep_event *event);

/*
 * SKEP_EVENT_STOPPED: 0 after skep_stop(), -ENOTCONN after
 * skep_link_lost(), otherwise a negative errno value telling why libskep
 * stopped, for instance -ETIMEDOUT when the dongle stopped answering,
 * -EPROTO when it broke the protocol, or -EEXIST when skep_start() found
 * another network on the dongle.
 * SKEP_EVENT_REQUEST_DONE and SKEP_EVENT_DEVICE_SETUP_FAILED: whether the
 * request was delivered and answered: 0 if it was, otherwise for instance
 * -ETIMEDOUT (no answer) or -EHOSTUNREACH (device not reachable). What
 * the device thought of the request is its status.
 */
int skep_event_get_error(const skep_event *event);

/*
 * SKEP_EVENT_REQUEST_DONE and SKEP_EVENT_DEVICE_SETUP_FAILED: the status
 * the device answered with, 0 for success. Only meaningful when
 * skep_event_get_error() is 0. Which status it is depends on the request:
 *
 *   skep_read_attributes(), skep_write_attributes(),
 *   skep_configure_reporting()
 *       0, or the ZCL status of a Default Response rejecting the whole
 *       request, for instance 0xc3 (UNSUPPORTED_CLUSTER). The status of
 *       each attribute is in the event's attributes.
 *   skep_send_command()
 *       The ZCL status of the device's Default Response, for instance
 *       0x81 (UNSUP_COMMAND); 0 if it sent none.
 *   skep_bind(), skep_unbind()
 *       The ZDO status of the Bind or Unbind response, for instance 0x8c
 *       (TABLE_FULL).
 *   skep_remove_device()
 *       The ZDO status of the Leave response.
 *   skep_permit_join(), skep_refresh_state()
 *       Always 0: no device answers.
 */
uint8_t skep_event_get_status(const skep_event *event);

/* SKEP_EVENT_REQUEST_DONE: the request id. */
uint32_t skep_event_get_request(const skep_event *event);

enum skep_network_origin {
  /* The network on the dongle, as it was. */
  SKEP_NETWORK_RESUMED = 1,
  /* The imported network, written onto the dongle: a new dongle. */
  SKEP_NETWORK_RESTORED = 2,
  /* A new network: devices must be paired. */
  SKEP_NETWORK_FORMED = 3,
};

enum skep_serial_line {
  SKEP_SERIAL_DTR = 1 << 0,
  SKEP_SERIAL_RTS = 1 << 1,
};

/*
 * SKEP_EVENT_SERIAL_LINES: the lines to assert, a bitwise or of enum
 * skep_serial_line values. Lines not in it are deasserted.
 */
unsigned skep_event_get_lines(const skep_event *event);

/* SKEP_EVENT_STARTED: how the network was brought up. */
enum skep_network_origin skep_event_get_network_origin(const skep_event *event);

/*
 * SKEP_EVENT_PERMIT_JOIN: seconds the join window stays open, 0 when it
 * closed.
 */
unsigned skep_event_get_duration(const skep_event *event);

/*
 * SKEP_EVENT_ATTRIBUTES and SKEP_EVENT_COMMAND: where the frame came from.
 * The manufacturer code is 0 for standard (not manufacturer-specific)
 * frames.
 */
uint8_t skep_event_get_endpoint(const skep_event *event);
uint16_t skep_event_get_cluster(const skep_event *event);
uint16_t skep_event_get_manufacturer_code(const skep_event *event);

/*
 * SKEP_EVENT_LOG: severity (0 error, 1 warning, 2 info, 3 debug) and
 * message. The string is valid until the event is freed.
 */
int skep_event_get_log(const skep_event *event, const char **message);

/* Values ----------------------------------------------------------------- */

/* ZCL data types (Zigbee Cluster Library, section 2.6.2). */
enum skep_type {
  SKEP_TYPE_NODATA = 0x00,
  SKEP_TYPE_DATA8 = 0x08,
  SKEP_TYPE_DATA16 = 0x09,
  SKEP_TYPE_BOOL = 0x10,
  SKEP_TYPE_BITMAP8 = 0x18,
  SKEP_TYPE_BITMAP16 = 0x19,
  SKEP_TYPE_BITMAP32 = 0x1b,
  SKEP_TYPE_UINT8 = 0x20,
  SKEP_TYPE_UINT16 = 0x21,
  SKEP_TYPE_UINT24 = 0x22,
  SKEP_TYPE_UINT32 = 0x23,
  SKEP_TYPE_UINT48 = 0x25,
  SKEP_TYPE_UINT64 = 0x27,
  SKEP_TYPE_INT8 = 0x28,
  SKEP_TYPE_INT16 = 0x29,
  SKEP_TYPE_INT24 = 0x2a,
  SKEP_TYPE_INT32 = 0x2b,
  SKEP_TYPE_INT64 = 0x2f,
  SKEP_TYPE_ENUM8 = 0x30,
  SKEP_TYPE_ENUM16 = 0x31,
  SKEP_TYPE_SEMI = 0x38,
  SKEP_TYPE_SINGLE = 0x39,
  SKEP_TYPE_DOUBLE = 0x3a,
  SKEP_TYPE_OCTET_STRING = 0x41,
  SKEP_TYPE_CHAR_STRING = 0x42,
  SKEP_TYPE_ARRAY = 0x48,
  SKEP_TYPE_STRUCT = 0x4c,
  SKEP_TYPE_UTC = 0xe2,
  SKEP_TYPE_CLUSTER_ID = 0xe8,
  SKEP_TYPE_ATTRIBUTE_ID = 0xe9,
  SKEP_TYPE_IEEE_ADDRESS = 0xf0,
  SKEP_TYPE_KEY128 = 0xf1,
};

/* A ZCL value. Which member of v is used depends on the type. */
struct skep_value {
  uint8_t type; /* enum skep_type */
  union {
    /* Booleans, unsigned integers, bitmaps, enumerations, data, UTC time,
     * cluster and attribute ids, IEEE addresses. */
    uint64_t u;
    /* Signed integers. */
    int64_t i;
    /* Semi, single and double precision floats. */
    double f;
    /* Strings, arrays, structures and keys, in their ZCL encoding without
     * the length prefix. Strings are not NUL-terminated. In events, the
     * data is valid until the event is freed. */
    struct {
      const uint8_t *data;
      size_t len;
    } bytes;
  } v;
};

/* An attribute and its value. */
struct skep_attribute {
  uint16_t id;
  /* In the result of a request, the ZCL status of this attribute: 0
   * (SUCCESS), or for instance 0x86 (UNSUPPORTED_ATTRIBUTE) or 0x88
   * (READ_ONLY). Always 0 in reports. Ignored when writing. */
  uint8_t status;
  struct skep_value value;
  uint64_t reserved[2]; /* for later versions; must be 0 */
};

/*
 * SKEP_EVENT_ATTRIBUTES and SKEP_EVENT_REQUEST_DONE: number of attributes
 * in the event, and the attribute at index (0 to count - 1).
 *
 * Errors of skep_event_get_attribute: -EINVAL (index out of range).
 */
size_t skep_event_get_attribute_count(const skep_event *event);
int skep_event_get_attribute(const skep_event *event, size_t index, struct skep_attribute *attribute);

/*
 * SKEP_EVENT_COMMAND: the command id and its payload, in ZCL encoding.
 * The payload is valid until the event is freed.
 */
uint8_t skep_event_get_command(const skep_event *event);
const uint8_t *skep_event_get_payload(const skep_event *event, size_t *len);

/* State ------------------------------------------------------------------ */

/*
 * What libskep needs to survive a restart or a move to a new dongle:
 * - the network: channel, PAN ID, extended PAN ID, network key and its
 *   sequence number, and the coordinator's IEEE address;
 * - the security counters: the outgoing network frame counter, the trust
 *   center link key and its frame counter, and the link keys of devices
 *   that have their own, with their counters;
 * - the devices: addresses, node descriptors, endpoints, clusters,
 *   manufacturer and model, and how far their setup has got.
 * libskep never stores it itself; the caller does, and must keep it
 * private (it holds keys, so mode 0600 for a file).
 *
 * The state is opaque bytes. A libskep version reads the state written by
 * any older version.
 */

/*
 * Copy the current state into buf (size bytes). Stores the length of the
 * state in *len; if buf is too small, nothing is copied and -ENOBUFS is
 * returned, so a first call with size 0 tells how much room is needed.
 *
 * Errors: -ENOBUFS, -ENODATA (no network yet: nothing worth saving).
 */
int skep_export_state(skep_ctx *ctx, uint8_t *buf, size_t size, size_t *len);

/*
 * Read the security counters from the dongle, which advances them with
 * every frame it sends, so that the next export is current. A request
 * like those under Requests: it ends with SKEP_EVENT_REQUEST_DONE, after
 * SKEP_EVENT_STATE_CHANGED if the counters moved. libskep does not
 * refresh them by itself: the application decides when, for instance
 * every hour and right before moving the network to another dongle.
 *
 * Errors: -ENETDOWN.
 */
int skep_refresh_state(skep_ctx *ctx, uint32_t *request);

/*
 * Load a state saved by skep_export_state(). Only before skep_start().
 *
 * Errors: -EBUSY (already started), -EINVAL (not a valid state),
 * -ENOTSUP (written by a newer libskep).
 */
int skep_import_state(skep_ctx *ctx, const uint8_t *data, size_t len);

/* Network ---------------------------------------------------------------- */

/*
 * Parameters of the running network.
 *
 * Errors: -ENETDOWN (network not up).
 */
int skep_get_network(skep_ctx *ctx, uint8_t *channel, uint16_t *pan_id, uint64_t *extended_pan_id);

/*
 * Let new devices join for the given number of seconds (at most 254), or
 * close the window with 0. A request like those under Requests: it ends
 * with SKEP_EVENT_REQUEST_DONE once the dongle has opened or closed the
 * window and told the routers, and SKEP_EVENT_PERMIT_JOIN reports the
 * change.
 *
 * Errors: -ENETDOWN, -EINVAL (more than 254 seconds).
 */
int skep_permit_join(skep_ctx *ctx, unsigned seconds, uint32_t *request);

/* Devices ---------------------------------------------------------------- */

/*
 * IEEE addresses of the known devices. Stores up to capacity addresses in
 * devices and the total number of devices in *count, so that a first call
 * with capacity 0 tells how much room is needed.
 */
int skep_get_devices(skep_ctx *ctx, uint64_t *devices, size_t capacity, size_t *count);

enum skep_node_type {
  SKEP_NODE_COORDINATOR = 0,
  SKEP_NODE_ROUTER = 1,
  SKEP_NODE_END_DEVICE = 2,
};

/*
 * What the device said about itself in its node descriptor: role,
 * manufacturer code, and whether it sleeps (rx_on_when_idle is 0 for
 * sleepy end devices, which only receive when they poll).
 *
 * Errors: -ENODEV (unknown device), -EAGAIN (not interviewed yet).
 */
int skep_device_get_node(skep_ctx *ctx, uint64_t device, enum skep_node_type *type,
                         uint16_t *manufacturer_code, int *rx_on_when_idle);

/*
 * Current network (short) address of the device.
 *
 * Errors: -ENODEV.
 */
int skep_device_get_short_address(skep_ctx *ctx, uint64_t device, uint16_t *address);

/*
 * Manufacturer name and model identifier from the device's Basic cluster,
 * copied as NUL-terminated strings into buf (size bytes, truncated if
 * needed). Returns the length of the full string.
 *
 * Errors: -ENODEV, -EAGAIN (not interviewed yet).
 */
int skep_device_get_manufacturer(skep_ctx *ctx, uint64_t device, char *buf, size_t size);
int skep_device_get_model(skep_ctx *ctx, uint64_t device, char *buf, size_t size);

/*
 * Endpoints of the device, then the input (server) or output (client)
 * clusters of one endpoint. Same capacity and count convention as
 * skep_get_devices().
 *
 * Errors: -ENODEV, -EAGAIN (not interviewed yet), -ENOENT (no such
 * endpoint).
 */
int skep_device_get_endpoints(skep_ctx *ctx, uint64_t device, uint8_t *endpoints, size_t capacity,
                              size_t *count);
enum skep_cluster_side {
  SKEP_CLUSTER_INPUT = 0,
  SKEP_CLUSTER_OUTPUT = 1,
};
int skep_device_get_clusters(skep_ctx *ctx, uint64_t device, uint8_t endpoint,
                             enum skep_cluster_side side, uint16_t *clusters, size_t capacity,
                             size_t *count);

/*
 * Set the device up again from the start, after a failed setup or when
 * the device lost its configuration. SKEP_EVENT_DEVICE_READY or
 * SKEP_EVENT_DEVICE_SETUP_FAILED follows.
 *
 * Errors: -ENODEV, -ENETDOWN.
 */
int skep_setup_device(skep_ctx *ctx, uint64_t device);

/*
 * Ask the device to leave the network and forget it. A request like those
 * under Requests, waiting for a sleepy device to wake up. When it ends,
 * the device is forgotten even if it did not answer, since a device that
 * is broken or gone never will, and SKEP_EVENT_DEVICE_LEFT follows.
 *
 * Errors: -ENODEV, -ENETDOWN.
 */
int skep_remove_device(skep_ctx *ctx, uint64_t device, uint64_t deadline, uint32_t *request);

/* Requests --------------------------------------------------------------- */

/*
 * Requests talk to one cluster of one device endpoint. They are
 * asynchronous: each returns at once, stores a non-zero request id in
 * *request, and ends with one SKEP_EVENT_REQUEST_DONE carrying that id.
 * Requests to a sleepy end device wait in libskep until the device is
 * next heard from, which can take hours, and are then sent in the order
 * they were made. A waiting write or reporting configuration is replaced
 * by a newer one for the same attributes of the same target: the older
 * request ends with -ECANCELED.
 *
 * Each request takes a deadline: the time, on the clock given to
 * skep_advance(), by which it must be done. A request still pending at
 * its deadline ends with -ETIMEDOUT; SKEP_NO_DEADLINE lets it wait as
 * long as it takes. The protocol's own timeouts still apply once the
 * request is sent, so a request can fail earlier, for instance with
 * -EHOSTUNREACH.
 *
 * struct skep_target, struct skep_attribute and struct skep_reporting end
 * with reserved fields, so that later versions can add fields without
 * changing their size, which arrays of them depend on. Zero the whole
 * struct before setting the fields you use.
 *
 * Errors of all requests: -ENODEV (unknown device), -ENETDOWN,
 * -EINVAL (including a reserved field that is not 0), -ENOBUFS (too many
 * requests pending).
 */

#define SKEP_NO_DEADLINE UINT64_MAX

struct skep_target {
  uint64_t device; /* IEEE address */
  uint8_t endpoint;
  uint16_t cluster;
  /* 0 for standard attributes and commands, otherwise the manufacturer
   * code of a manufacturer-specific cluster, attribute or command. */
  uint16_t manufacturer_code;
  uint32_t reserved[4]; /* for later versions; must be 0 */
};

/*
 * Read attributes. SKEP_EVENT_REQUEST_DONE holds one attribute per id, in
 * the same order, each with its status and, if the status is 0, its
 * value.
 */
int skep_read_attributes(skep_ctx *ctx, const struct skep_target *target, const uint16_t *ids,
                         size_t count, uint64_t deadline, uint32_t *request);

/*
 * Write attributes. The status field of each attribute is ignored.
 * SKEP_EVENT_REQUEST_DONE holds one attribute per attribute written, in
 * the same order, each with its status and no value.
 */
int skep_write_attributes(skep_ctx *ctx, const struct skep_target *target,
                          const struct skep_attribute *attributes, size_t count, uint64_t deadline,
                          uint32_t *request);

/* How and when a device reports an attribute. */
struct skep_reporting {
  uint16_t attribute;
  uint8_t type; /* enum skep_type of the attribute */
  uint16_t min_interval; /* seconds between reports, at least */
  uint16_t max_interval; /* seconds between reports, at most; 0xffff stops reporting */
  /* Change that triggers a report, for analog types (integers, floats);
   * its type is the attribute's. Ignored for discrete types. */
  struct skep_value change;
  uint64_t reserved[2]; /* for later versions; must be 0 */
};

/*
 * Configure attribute reporting. SKEP_EVENT_REQUEST_DONE holds one
 * attribute per configuration, in the same order, each with its status
 * and no value.
 */
int skep_configure_reporting(skep_ctx *ctx, const struct skep_target *target,
                             const struct skep_reporting *reporting, size_t count,
                             uint64_t deadline, uint32_t *request);

/*
 * Bind the cluster of the target endpoint to the coordinator, so that the
 * device sends its reports and commands to us, or remove that binding.
 */
int skep_bind(skep_ctx *ctx, const struct skep_target *target, uint64_t deadline,
              uint32_t *request);
int skep_unbind(skep_ctx *ctx, const struct skep_target *target, uint64_t deadline,
                uint32_t *request);

/*
 * Send a cluster-specific command with a payload in ZCL encoding, for
 * instance On/Off "on" (cluster 0x0006, command 0x01, no payload).
 */
int skep_send_command(skep_ctx *ctx, const struct skep_target *target, uint8_t command,
                      const uint8_t *payload, size_t len, uint64_t deadline, uint32_t *request);

/*
 * Give up a pending request. It ends at once with SKEP_EVENT_REQUEST_DONE
 * and -ECANCELED. A request already sent may still take effect on the
 * device: cancelling only stops libskep from sending or waiting for it.
 *
 * Errors: -ENOENT (no such request pending).
 */
int skep_cancel(skep_ctx *ctx, uint32_t request);

#ifdef __cplusplus
}
#endif

#endif /* SKEP_H */
