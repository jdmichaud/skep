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
  unsigned baudrate = 0;
  enum skep_flow_control flow_control = SKEP_FLOW_CONTROL_NONE;
  const char *message = NULL;
  skep_event *event;
  uint8_t channel = 0;
  uint16_t pan_id = 0;
  uint64_t extended_pan_id = 0;

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
  CHECK(skep_next_event(ctx) == NULL);

  CHECK(skep_stop(ctx) == 0);
  CHECK(skep_advance(ctx, 0) == 0);
  event = skep_next_event(ctx);
  CHECK(event != NULL && skep_event_get_type(event) == SKEP_EVENT_STOPPED);
  CHECK(skep_event_get_error(event) == 0);

  /* Events outlive their context. */
  skep_free(ctx);
  CHECK(skep_event_get_type(event) == SKEP_EVENT_STOPPED);
  skep_event_free(event);
  CHECK(live == 0);
  return 0;
}
