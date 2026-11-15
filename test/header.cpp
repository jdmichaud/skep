// skep.h must also compile as C++, with C linkage for its functions.
#include "skep.h"

extern "C" int skep_header_check_cxx();

int skep_header_check_cxx() {
  skep_target target = {};
  target.device = 0x0011223344556677u;
  target.endpoint = 1;
  target.cluster = 0x0006;
  skep_value value;
  value.type = SKEP_TYPE_UINT8;
  value.v.u = 1;
  uint32_t (*version)() = skep_version;
  return target.endpoint + value.type + (version != nullptr);
}
