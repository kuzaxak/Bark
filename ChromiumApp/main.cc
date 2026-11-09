// Copyright 2015 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The outer application's main, from chrome/app/chrome_exe_main_mac.cc at
// Chromium 156.0.8078.80. Helpers keep Chromium's own main.

#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "BarcChromium/barc_bridge_api.h"
#include "early_zone_registration_apple.h"

extern "C" {
// abort_report_np() records the message in a special section that both the
// system CrashReporter and Crashpad collect in crash reports.
void abort_report_np(const char* fmt, ...);
}

namespace {

[[noreturn]] void FatalError(const char* format, ...) {
  va_list valist;
  va_start(valist, format);
  char message[4096];
  if (vsnprintf(message, sizeof(message), format, valist) >= 0) {
    fputs(message, stderr);
    abort_report_np("%s", message);
  }
  va_end(valist);
  abort();
}

char* JoinPath(const char* parent_dir, const char* relative_path) {
  char* path = nullptr;
  if (asprintf(&path, "%s/%s", parent_dir, relative_path) < 0) {
    FatalError("asprintf: %s.", strerror(errno));
  }
  return path;
}

}  // namespace

__attribute__((visibility("default"))) int main(int argc, char* argv[]) {
  partition_alloc::EarlyMallocZoneRegistration();

  uint32_t exec_path_size = 0;
  int rv = _NSGetExecutablePath(NULL, &exec_path_size);
  if (rv != -1) {
    FatalError("_NSGetExecutablePath: get length failed.");
  }

  char* exec_path = static_cast<char*>(malloc(exec_path_size));
  rv = _NSGetExecutablePath(exec_path, &exec_path_size);
  if (rv != 0) {
    FatalError("_NSGetExecutablePath: get path failed.");
  }

  const char* parent_dir = dirname(exec_path);
  if (!parent_dir) {
    FatalError("dirname %s: %s.", exec_path, strerror(errno));
  }

  char* framework_path = JoinPath(
      parent_dir, "../Frameworks/Bark Framework.framework/Versions/" ENGINE_VERSION_STRING "/Bark Framework");
  void* library = dlopen(framework_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!library) {
    FatalError("dlopen %s: %s.", framework_path, dlerror());
  }
  if (!dlsym(library, BARC_ENGINE_MAIN_SYMBOL)) {
    FatalError("dlsym %s: %s. Bark Framework was built for another bridge version; this app needs version %d.",
               BARC_ENGINE_MAIN_SYMBOL, dlerror(), BARC_BRIDGE_VERSION);
  }

  char* native_path = JoinPath(
      parent_dir, "../Frameworks/NookNativeShell.framework/Versions/A/NookNativeShell");
  void* native_library = dlopen(native_path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
  if (!native_library) {
    FatalError("dlopen native shell %s: %s.", native_path, dlerror());
  }
  using NativeMainPtr = int (*)(void*, int, const char**);
  const auto native_main = reinterpret_cast<NativeMainPtr>(dlsym(native_library, "barc_native_main"));
  if (!native_main) {
    FatalError("Native shell entry is missing.");
  }

  rv = native_main(library, argc, const_cast<const char**>(argv));

  // exit, don't return from main, to avoid the apparent removal of main from
  // stack backtraces under tail call optimization.
  exit(rv);
}
