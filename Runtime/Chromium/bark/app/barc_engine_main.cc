#include "bark/app/barc_public_headers_sha256.h"
#include "bark/bridge/barc_bridge_api.h"
#include "bark/bridge/barc_bridge_functions.h"
#include "base/compiler_specific.h"
#include "partition_alloc/buildflags.h"

#if PA_BUILDFLAG(USE_PARTITION_ALLOC_AS_MALLOC)
#include "partition_alloc/shim/early_zone_registration_utils_apple.h"

namespace {

// Keep the allocator's canonical C string in the image for staging checks.
[[gnu::used, gnu::retain]] constexpr const char* kBarkDelegatingZoneName =
    allocator_shim::kDelegatingZoneName.data();

}  // namespace
#endif

extern "C" int ChromeMain(int argc, const char** argv);

NO_STACK_PROTECTOR int barc_engine_main_v13(int argc, const char** argv) {
  barc_seal_password_provider();
  return ChromeMain(argc, argv);
}

const char* barc_public_headers_sha256() {
  return BARC_PUBLIC_HEADERS_SHA256;
}
