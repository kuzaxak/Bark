// Licensed under GPL-3.0. See LICENSE.
#pragma once
#include <BarcChromium/barc_bridge_api.h>

static inline int BarkReadRendererState(const struct BarcBridge *api,
                                        int32_t window, int32_t tab,
                                        int32_t *pid, int32_t *visible) {
#ifdef BARC_HAS_RENDERER_STATE
  if (api->size >= offsetof(struct BarcBridge, tab_renderer_state) +
                       sizeof(api->tab_renderer_state) &&
      api->tab_renderer_state) {
    return api->tab_renderer_state(window, tab, pid, visible);
  }
#endif
  return 0;
}
