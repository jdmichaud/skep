/* skep.h must compile on its own as strict C99, and its types must be usable. */
#include "skep.h"

int skep_header_check(void);

int skep_header_check(void) {
  struct skep_target target = { 0x0011223344556677u, 1, 0x0006, 0 };
  struct skep_value value;
  value.type = SKEP_TYPE_UINT8;
  value.v.u = 1;
  return target.endpoint + value.type + SKEP_EVENT_STARTED;
}
