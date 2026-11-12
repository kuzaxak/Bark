#include "bark/app/barc_public_headers_sha256.h"
#include "bark/bridge/barc_bridge_api.h"
#include "base/compiler_specific.h"

extern "C" int ChromeMain(int argc, const char** argv);

NO_STACK_PROTECTOR int barc_engine_main_v11(int argc, const char** argv) {
  return ChromeMain(argc, argv);
}

const char* barc_public_headers_sha256() {
  return BARC_PUBLIC_HEADERS_SHA256;
}
