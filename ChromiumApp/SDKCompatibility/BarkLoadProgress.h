// Licensed under GPL-3.0. See LICENSE.
#pragma once
#include <stddef.h>
#include <BarcChromium/barc_bridge_api.h>

// Keep Swift's callback type independent of the optional SDK member.
typedef void (*BarkLoadProgressCallback)(void *context, uint64_t observation,
                                        double progress, int loading);

static inline int BarkObserveTabLoadProgress(const struct BarcBridge *api,
                                             uint64_t observation,
                                             BarkLoadProgressCallback callback) {
#ifdef BARC_HAS_LOAD_PROGRESS
  if (api->size >= offsetof(struct BarcBridge, tab_observe_load_progress) +
                       sizeof(api->tab_observe_load_progress) &&
      api->tab_observe_load_progress) {
    return api->tab_observe_load_progress(observation, callback);
  }
#endif
  return 0;
}
