/* libskep through the C ABI: a C program linked with the library, using the sim driver. Checks
 * that the implementation matches skep.h: struct layouts, enums, pointers and errno values. */
#define _POSIX_C_SOURCE 200809L

#include "skep.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Blocks allocated and not freed: libskep must pass back every block it gets. */
static long live;

static void *counting_alloc(void *ctx, size_t size, size_t alignment) {
  void *ptr;
  (void)ctx;
  if (alignment < sizeof(void *)) alignment = sizeof(void *);
  if (posix_memalign(&ptr, alignment, size) != 0) return NULL;
  live++;
  return ptr;
}

static void counting_free(void *ctx, void *ptr, size_t size, size_t alignment) {
  (void)ctx;
  (void)size;
  (void)alignment;
  free(ptr);
  live--;
}

#define CHECK(condition)                                                          \
  do {                                                                            \
    if (!(condition)) {                                                           \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
      return 1;                                                                   \
    }                                                                             \
  } while (0)

int main(void) {
  struct skep_allocator allocator = { .alloc = counting_alloc, .free = counting_free };
  uint8_t seed[SKEP_SEED_SIZE] = { 0 };
  skep_ctx *ctx = NULL;
  skep_ctx *other = NULL;
  uint8_t *state = NULL;
  size_t state_len = 0;
  unsigned baudrate = 0;
  enum skep_flow_control flow_control = SKEP_FLOW_CONTROL_NONE;
  const char *message = NULL;
  skep_event *event;
  uint8_t channel = 0;
  uint16_t pan_id = 0;
  uint64_t extended_pan_id = 0;
  uint32_t request = 0;

  CHECK(skep_version() ==
        (uint32_t)(SKEP_VERSION_MAJOR << 16 | SKEP_VERSION_MINOR << 8 | SKEP_VERSION_PATCH));
  CHECK(skep_new(&allocator, NULL, &ctx) == -EINVAL);
  CHECK(skep_new(&allocator, seed, &ctx) == 0);
  CHECK(live > 0);

  CHECK(skep_set_option(ctx, "colour", "blue") == -ENOENT);
  CHECK(skep_set_option(ctx, "driver", "ezsp") == 0);
  CHECK(skep_get_serial_defaults(ctx, &baudrate, &flow_control) == 0);
  CHECK(baudrate == 115200 && flow_control == SKEP_FLOW_CONTROL_SOFTWARE);

  /* The simulated dongle holds no network: libskep forms one, with the options given. */
  CHECK(skep_set_option(ctx, "driver", "sim") == 0);
  CHECK(skep_set_option(ctx, "log-level", "debug") == 0);
  CHECK(skep_set_option(ctx, "channel", "20") == 0);
  CHECK(skep_start(ctx) == 0);
  CHECK(skep_advance(ctx, 0) == 0);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_LOG);
  CHECK(skep_event_get_log(event, &message) == 2 && strstr(message, "forming") != NULL);
  skep_event_free(event);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_LOG);
  skep_event_free(event);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_STARTED);
  CHECK(skep_event_get_network_origin(event) == SKEP_NETWORK_FORMED);
  CHECK(skep_event_get_device(event) == 0);
  skep_event_free(event);
  CHECK(skep_get_network(ctx, &channel, &pan_id, &extended_pan_id) == 0 && channel == 20);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_STATE_CHANGED);
  skep_event_free(event);
  CHECK(skep_next_event(ctx) == NULL);

  /* The state: first its length, then the state itself, a JSON document. */
  CHECK(skep_export_state(ctx, NULL, 0, &state_len) == -ENOBUFS && state_len > 0);
  state = malloc(state_len);
  CHECK(state != NULL);
  CHECK(skep_export_state(ctx, state, state_len, &state_len) == 0 && state[0] == '{');
  CHECK(skep_import_state(ctx, state, state_len) == -EBUSY);
  CHECK(skep_refresh_state(ctx, &request) == 0 && request != 0);
  CHECK(skep_advance(ctx, 0) == 0);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_REQUEST_DONE);
  CHECK(skep_event_get_request(event) == request && skep_event_get_error(event) == 0);
  skep_event_free(event);

  CHECK(skep_permit_join(ctx, 255, &request) == -EINVAL);
  CHECK(skep_permit_join(ctx, 60, &request) == 0 && request != 0);
  CHECK(skep_advance(ctx, 0) == 0);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_REQUEST_DONE);
  CHECK(skep_event_get_request(event) == request && skep_event_get_error(event) == 0);
  CHECK(skep_event_get_status(event) == 0);
  skep_event_free(event);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_PERMIT_JOIN);
  CHECK(skep_event_get_duration(event) == 60);
  skep_event_free(event);

  CHECK(skep_stop(ctx) == 0);
  CHECK(skep_advance(ctx, 0) == 0);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_STOPPED);
  CHECK(skep_event_get_error(event) == 0);

  /* The state outlives the network, and goes to another context. */
  CHECK(skep_export_state(ctx, state, state_len, &state_len) == 0);
  CHECK(skep_new(&allocator, seed, &other) == 0);
  CHECK(skep_import_state(other, state, state_len) == 0);
  CHECK(skep_import_state(other, state, state_len / 2) == -EINVAL);
  skep_free(other);
  free(state);

  /* Events outlive their context. */
  skep_free(ctx);
  CHECK(skep_event_get_type(event) == SKEP_EVENT_STOPPED);
  skep_event_free(event);
  CHECK(live == 0);
  return 0;
}
