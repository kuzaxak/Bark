// Licensed under GPL-3.0. See LICENSE.
#pragma once
#include <BarcChromium/barc_bridge_api.h>

static inline const char *BarkCloudShareNotification(void) {
#ifdef BARC_HAS_CLOUD_SHARE_ACTIVATION
  return BARC_CLOUD_SHARE_NOTIFICATION;
#else
  return NULL;
#endif
}
