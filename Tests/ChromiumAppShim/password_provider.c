// Licensed under GPL-3.0. See LICENSE.
#include <assert.h>
#include "BarkPasswordProvider.h"

#ifdef BARC_HAS_PASSWORD_PROVIDER
static BarcPasswordProvider received;
static int accepted;

static int select_provider(BarcPasswordProvider provider) {
  received = provider;
  return accepted;
}
#endif

int main(void) {
  struct BarcBridge bridge = {.size = sizeof(bridge)};
  assert(!BarkTabShowsPawlManagement(0));
#ifdef BARC_HAS_PAWL_MANAGEMENT
  assert(BarkTabShowsPawlManagement(BARC_TAB_PAWL_MANAGEMENT | BARC_TAB_LOADING));
#else
  assert(!BarkTabShowsPawlManagement(8192));
#endif
#ifdef BARC_HAS_PASSWORD_PROVIDER
  bridge.set_password_provider = select_provider;
  assert(BarkSDKSupportsPasswordSelection());
  accepted = 1;
  assert(BarkSelectLaunchPasswordProvider(&bridge, true));
  assert(received == BARC_PASSWORD_PROVIDER_PAWL);
  assert(BarkSelectLaunchPasswordProvider(&bridge, false));
  assert(received == BARC_PASSWORD_PROVIDER_CHROMIUM);
  accepted = 0;
  assert(!BarkSelectLaunchPasswordProvider(&bridge, true));
#else
  assert(!BarkSDKSupportsPasswordSelection());
  assert(!BarkSelectLaunchPasswordProvider(&bridge, true));
  assert(!BarkSelectLaunchPasswordProvider(&bridge, false));
#endif
  return 0;
}
