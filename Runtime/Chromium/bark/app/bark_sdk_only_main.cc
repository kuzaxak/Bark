// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <stdio.h>
#include <sysexits.h>

int main() {
  fputs("Bark Engine is an SDK build artifact. Launch the signed Bark app.\n",
        stderr);
  return EX_UNAVAILABLE;
}
