// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <stdio.h>
#include <sysexits.h>

__attribute__((visibility("default"))) int main() {
  // The diagnostic is a NUL-terminated string literal.
#pragma clang unsafe_buffer_usage begin
  fputs("Bark Engine is an SDK build artifact. Launch the signed Bark app.\n",
        stderr);
#pragma clang unsafe_buffer_usage end
  return EX_UNAVAILABLE;
}
