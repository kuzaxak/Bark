// Licensed under GPL-3.0. See LICENSE.
#pragma once
#include <stdbool.h>
#include <BarcChromium/barc_bridge_api.h>

// The signed SDK receipt selects the header used for this slice. Swift cannot
// refer to a table member absent from an older pinned SDK.
static inline bool BarkSDKSupportsPasswordSelection(void) {
#ifdef BARC_HAS_PASSWORD_PROVIDER
  return true;
#else
  return false;
#endif
}

static inline bool BarkSelectLaunchPasswordProvider(const struct BarcBridge *api,
                                                    bool use_pawl) {
#ifdef BARC_HAS_PASSWORD_PROVIDER
  return api->set_password_provider(use_pawl ? BARC_PASSWORD_PROVIDER_PAWL
                                             : BARC_PASSWORD_PROVIDER_CHROMIUM) == 1;
#else
  return false;
#endif
}

static inline bool BarkTabShowsPawlManagement(uint32_t flags) {
#ifdef BARC_HAS_PAWL_MANAGEMENT
  return (flags & BARC_TAB_PAWL_MANAGEMENT) != 0;
#else
  return false;
#endif
}
