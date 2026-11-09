// Copyright 2021 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef EARLY_ZONE_REGISTRATION_APPLE_H_
#define EARLY_ZONE_REGISTRATION_APPLE_H_

// This is an Apple-only file, used to register PartitionAlloc's zone *before*
// the process becomes multi-threaded.

namespace partition_alloc {

// Must be called *once*, *before* the process becomes multi-threaded.
void EarlyMallocZoneRegistration();

}  // namespace partition_alloc

#endif  // EARLY_ZONE_REGISTRATION_APPLE_H_
