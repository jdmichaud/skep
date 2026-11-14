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
 * - libskep starts no threads and never calls back into the caller. All
 *   work happens inside skep_process(), and its results are queued as
 *   events. libskep never blocks and never writes to stdout or stderr;
 *   diagnostics are delivered as SKEP_EVENT_LOG events.
 * - A context may be used from one thread at a time. Separate contexts
 *   are independent.
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

/* A connection to one dongle and the Zigbee network it coordinates. */
typedef struct skep_ctx skep_ctx;

/*
 * Create a context. Configure it with skep_set_option(), then call
 * skep_start().
 *
 * Errors: -ENOMEM.
 */
int skep_new(skep_ctx **ctx);

/* Stop everything immediately, close the dongle and free the context. */
void skep_free(skep_ctx *ctx);

/*
 * Set an option. Options can only be set before skep_start(). Values are
 * strings so that they can come straight from a configuration file.
 *
 * Common options:
 *   driver           Dongle driver: "ezsp" (Silicon Labs EmberZNet) or
 *                    "sim" (simulated network, for tests). Required.
 *   device           Path of the serial device, for instance
 *                    /dev/serial/by-id/usb-... . Required by "ezsp".
 *   baudrate         Serial speed. Default: the driver's usual speed.
 *   flow-control     "none", "software" or "hardware". Default: the
 *                    driver's usual setting.
 *   state-dir        Directory where libskep keeps the network backup and
 *                    the device registry. Files holding keys are created
 *                    with mode 0600. Default: nothing is persisted.
 *   log-level        "error", "warning", "info" or "debug".
 *                    Default: "warning".
 *
 * Used only when a new network is formed (no network on the dongle and
 * none in state-dir):
 *   channel          11 to 26, or "auto" to pick a quiet one. Default: "auto".
 *   pan-id           16-bit PAN ID in hexadecimal. Default: random.
 *   extended-pan-id  64-bit extended PAN ID in hexadecimal. Default: random.
 *   network-key      128-bit network key in hexadecimal. Default: random.
 *
 * Errors: -ENOENT (unknown option), -EINVAL (invalid value),
 * -EBUSY (already started).
 */
int skep_set_option(skep_ctx *ctx, const char *name, const char *value);

/*
 * Open the dongle and bring the network up: resume the network stored on
 * the dongle, restore the one in state-dir, or form a new one.
 *
 * This only starts the work. Success is reported by SKEP_EVENT_STARTED,
 * failure by SKEP_EVENT_STOPPED.
 *
 * Errors: -EINVAL (missing or inconsistent options), -EBUSY (already
 * started), and errors from opening the device, such as -ENOENT or
 * -EACCES.
 */
int skep_start(skep_ctx *ctx);

/*
 * Stop cleanly: finish pending writes to state-dir and close the dongle.
 * SKEP_EVENT_STOPPED is reported when done. The network itself stays on
 * the dongle and is resumed by the next skep_start().
 */
int skep_stop(skep_ctx *ctx);

/* Event loop ------------------------------------------------------------- */

/*
 * File descriptor to wait on with poll(), epoll or any event loop. When it
 * is readable, call skep_process(). It also becomes readable when one of
 * libskep's timers expires, so no timeout needs to be managed by the
 * caller. The descriptor is valid from skep_new() to skep_free() and never
 * changes, even when the dongle is reopened.
 *
 * Linux only: the descriptor is an epoll instance.
 */
int skep_get_fd(skep_ctx *ctx);

/*
 * Do the work that is due: read from and write to the dongle, run expired
 * timers, and queue the resulting events. Never blocks.
 *
 * Errors: -ENOMEM. Failures of the dongle are reported as events, not as
 * return values.
 */
int skep_process(skep_ctx *ctx);

/* Events ----------------------------------------------------------------- */

typedef struct skep_event skep_event;

enum skep_event_type {
  /* The network is up. */
  SKEP_EVENT_STARTED = 1,
  /*
   * The context stopped, after skep_stop() or because of an error that
   * libskep could not recover from. skep_event_get_error() tells which.
   * skep_start() may be called again.
   */
  SKEP_EVENT_STOPPED = 2,
  /* The join window opened or closed. See skep_event_get_duration(). */
  SKEP_EVENT_PERMIT_JOIN = 3,
  /* A device joined the network. libskep now interviews and sets it up. */
  SKEP_EVENT_DEVICE_JOINED = 4,
  /*
   * A device has been interviewed and set up (bindings and reporting
   * configured from the device tables). Its endpoints and clusters are
   * known.
   */
  SKEP_EVENT_DEVICE_READY = 5,
  /* A device left the network or was removed. */
  SKEP_EVENT_DEVICE_LEFT = 6,
  /*
   * Attribute values from a device: a report, or the answer to
   * skep_read_attributes() (then skep_event_get_request() is non-zero).
   */
  SKEP_EVENT_ATTRIBUTES = 7,
  /* A cluster command sent by a device, for instance by a remote. */
  SKEP_EVENT_COMMAND = 8,
  /*
   * A request finished. Every request ends with exactly one such event,
   * after any SKEP_EVENT_ATTRIBUTES it produced.
   */
  SKEP_EVENT_REQUEST_DONE = 9,
  /* A diagnostic message, see skep_event_get_log(). */
  SKEP_EVENT_LOG = 10,
};

/*
 * Take the next event from the queue. Returns NULL when the queue is
 * empty. The caller frees the event with skep_event_free().
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
 * SKEP_EVENT_STOPPED: 0 after skep_stop(), otherwise a negative errno
 * value telling why libskep stopped.
 * SKEP_EVENT_REQUEST_DONE: 0 if the request succeeded, otherwise a
 * negative errno value: -ETIMEDOUT (no answer), -EHOSTUNREACH (device not
 * reachable), -EREMOTEIO (the device answered with a ZCL error status,
 * see skep_event_get_zcl_status()), and others.
 */
int skep_event_get_error(const skep_event *event);

/*
 * SKEP_EVENT_REQUEST_DONE: ZCL status returned by the device, 0 (SUCCESS)
 * if it reported no error.
 */
uint8_t skep_event_get_zcl_status(const skep_event *event);

/* SKEP_EVENT_REQUEST_DONE and SKEP_EVENT_ATTRIBUTES: the request id. */
uint32_t skep_event_get_request(const skep_event *event);

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
  /* ZCL status of this attribute in a read response: 0 (SUCCESS), or for
   * instance 0x86 (UNSUPPORTED_ATTRIBUTE), in which case value is not set.
   * Always 0 in reports. Ignored when writing. */
  uint8_t status;
  struct skep_value value;
};

/*
 * SKEP_EVENT_ATTRIBUTES: number of attributes in the event, and the
 * attribute at index (0 to count - 1).
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

/* Network ---------------------------------------------------------------- */

/*
 * Parameters of the running network.
 *
 * Errors: -ENETDOWN (network not up).
 */
int skep_get_network(skep_ctx *ctx, uint8_t *channel, uint16_t *pan_id, uint64_t *extended_pan_id);

/*
 * Let new devices join for the given number of seconds (at most 254), or
 * close the window with 0. SKEP_EVENT_PERMIT_JOIN reports the change.
 *
 * Errors: -ENETDOWN, -EINVAL (more than 254 seconds).
 */
int skep_permit_join(skep_ctx *ctx, unsigned seconds);

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
 * Ask the device to leave the network and forget it.
 * SKEP_EVENT_DEVICE_LEFT follows.
 *
 * Errors: -ENODEV, -ENETDOWN.
 */
int skep_remove_device(skep_ctx *ctx, uint64_t device);

/* Requests --------------------------------------------------------------- */

/*
 * Requests talk to one cluster of one device endpoint. They are
 * asynchronous: each returns at once, stores a non-zero request id in
 * *request, and ends with one SKEP_EVENT_REQUEST_DONE carrying that id.
 * Requests to sleepy end devices are delivered when the device next
 * wakes up, which can take minutes.
 *
 * Errors of all requests: -ENODEV (unknown device), -ENETDOWN,
 * -EINVAL, -ENOBUFS (too many requests pending).
 */

struct skep_target {
  uint64_t device; /* IEEE address */
  uint8_t endpoint;
  uint16_t cluster;
  /* 0 for standard attributes and commands, otherwise the manufacturer
   * code of a manufacturer-specific cluster, attribute or command. */
  uint16_t manufacturer_code;
};

/* Read attributes. The values arrive in one SKEP_EVENT_ATTRIBUTES. */
int skep_read_attributes(skep_ctx *ctx, const struct skep_target *target, const uint16_t *ids,
                         size_t count, uint32_t *request);

/* Write attributes. The status field of each attribute is ignored. */
int skep_write_attributes(skep_ctx *ctx, const struct skep_target *target,
                          const struct skep_attribute *attributes, size_t count,
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
};

/* Configure attribute reporting. */
int skep_configure_reporting(skep_ctx *ctx, const struct skep_target *target,
                             const struct skep_reporting *reporting, size_t count,
                             uint32_t *request);

/*
 * Bind the cluster of the target endpoint to the coordinator, so that the
 * device sends its reports and commands to us, or remove that binding.
 */
int skep_bind(skep_ctx *ctx, const struct skep_target *target, uint32_t *request);
int skep_unbind(skep_ctx *ctx, const struct skep_target *target, uint32_t *request);

/*
 * Send a cluster-specific command with a payload in ZCL encoding, for
 * instance On/Off "on" (cluster 0x0006, command 0x01, no payload).
 */
int skep_send_command(skep_ctx *ctx, const struct skep_target *target, uint8_t command,
                      const uint8_t *payload, size_t len, uint32_t *request);

#ifdef __cplusplus
}
#endif

#endif /* SKEP_H */
