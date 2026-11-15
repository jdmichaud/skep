/* skep.h must compile on its own as strict C99, and its types must be usable. */
#define _POSIX_C_SOURCE 200809L

#include "skep.h"

#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int skep_header_check(void);
int skep_header_new(skep_ctx **ctx);
void skep_header_loop(skep_ctx *ctx, int fd);

int skep_header_check(void) {
  struct skep_target target = { .device = 0x0011223344556677u, .endpoint = 1, .cluster = 0x0006 };
  struct skep_value value;
  value.type = SKEP_TYPE_UINT8;
  value.v.u = 1;
  return target.endpoint + value.type + SKEP_EVENT_STARTED;
}

/* An allocator as a C program would write one. */
static void *check_alloc(void *ctx, size_t size, size_t alignment) {
  void *ptr;
  (void)ctx;
  if (alignment < sizeof(void *)) alignment = sizeof(void *);
  return posix_memalign(&ptr, alignment, size) == 0 ? ptr : NULL;
}

static void check_free(void *ctx, void *ptr, size_t size, size_t alignment) {
  (void)ctx;
  (void)size;
  (void)alignment;
  free(ptr);
}

int skep_header_new(skep_ctx **ctx) {
  struct skep_allocator allocator = { .alloc = check_alloc, .free = check_free };
  return skep_new(&allocator, ctx);
}

static uint64_t now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static int ms_until(uint64_t deadline) {
  uint64_t t = now();
  return deadline > t ? (int)(deadline - t) : 0;
}

static void handle(const skep_event *event) {
  (void)skep_event_get_type(event);
}

/* The loop shown in skep.h, so that the example keeps compiling. */
void skep_header_loop(skep_ctx *ctx, int fd) {
  skep_start(ctx);
  for (;;) {
    const uint8_t *out;
    size_t n = skep_output(ctx, &out);
    if (n > 0) {
      ssize_t w = write(fd, out, n);
      if (w > 0) skep_output_done(ctx, w, now());
    }
    uint64_t deadline;
    int timeout = skep_next_deadline(ctx, &deadline) ? ms_until(deadline) : -1;
    struct pollfd p = { fd, POLLIN | (skep_output(ctx, &out) ? POLLOUT : 0), 0 };
    poll(&p, 1, timeout);
    if (p.revents & POLLIN) {
      uint8_t in[256];
      ssize_t r = read(fd, in, sizeof in);
      if (r > 0) skep_input(ctx, in, r, now());
    }
    skep_advance(ctx, now());
    for (skep_event *e; (e = skep_next_event(ctx)); skep_event_free(e))
      handle(e);
  }
}
