// Licensed under GPL-3.0. See LICENSE.
#pragma once
#include <stddef.h>
#include <BarcChromium/barc_bridge_api.h>

typedef void (*BarkTabFaviconCallback)(void *context, uint64_t observation,
                                      const uint8_t *png, size_t length);

static inline int BarkObserveTabFavicon(const struct BarcBridge *api,
                                        uint64_t observation,
                                        BarkTabFaviconCallback callback) {
#ifdef BARC_HAS_TAB_FAVICON
  if (api->size >= offsetof(struct BarcBridge, tab_bind_favicon) +
                       sizeof(api->tab_bind_favicon) && api->tab_bind_favicon) {
    return api->tab_bind_favicon(observation, callback);
  }
#endif
  return 0;
}
