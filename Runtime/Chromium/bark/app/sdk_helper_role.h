// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef BARK_APP_SDK_HELPER_ROLE_H_
#define BARK_APP_SDK_HELPER_ROLE_H_

#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sysexits.h>

// The helpers run before the Chromium framework is loaded. Recognize its
// macOS switch syntax without linking base::CommandLine to these executables.
// argv entries are NUL-terminated by main's contract. Check argc before reading
// an entry and its measured length before comparing the key and value.
#pragma clang unsafe_buffer_usage begin
static inline bool BarkHasHelperProcessRole(int argc, char* argv[]) {
  const char* const whitespace = " \t\n\r\f\v";
  bool has_role = false;
  for (int i = 1; i < argc; ++i) {
    const char* arg = argv[i] + strspn(argv[i], whitespace);
    size_t length = strlen(arg);
    while (length > 0 && strchr(whitespace, arg[length - 1])) {
      --length;
    }
    if (length == 2 && strncmp(arg, "--", 2) == 0) {
      break;
    }
    if (arg[0] != '-') {
      continue;
    }
    size_t prefix = arg[1] == '-' ? 2 : 1;
    const char* key = arg + prefix;
    if (length < prefix + 4 || strncmp(key, "type", 4) != 0) {
      continue;
    }
    if (length == prefix + 4) {
      return false;
    }
    if (key[4] != '=') {
      continue;
    }
    if (has_role) {
      return false;
    }
    // Renderer, GPU and utility are Content children. Relaunch and cleanup are
    // browser support helpers. Apéritif's subprocess test uses the no-op role.
    const char* const roles[] = {"renderer", "gpu-process", "utility",
                                 "relauncher", "code-sign-clone-cleanup",
                                 "no-op-for-testing"};
    const size_t value_length = length - prefix - 5;
    for (size_t role = 0; role < sizeof(roles) / sizeof(roles[0]); ++role) {
      if (value_length == strlen(roles[role]) &&
          strncmp(key + 5, roles[role], value_length) == 0) {
        has_role = true;
        break;
      }
    }
    if (!has_role) {
      return false;
    }
  }
  return has_role;
}
#pragma clang unsafe_buffer_usage end

static inline int BarkRefuseUnownedHelperLaunch(void) {
  // The diagnostic is a NUL-terminated string literal.
#pragma clang unsafe_buffer_usage begin
  fputs("Bark Helper requires a Chromium subprocess role. Launch the signed Bark app.\n",
        stderr);
#pragma clang unsafe_buffer_usage end
  return EX_UNAVAILABLE;
}

#endif  // BARK_APP_SDK_HELPER_ROLE_H_
