// Licensed under GPL-3.0. See LICENSE.
#include "BarkTabFavicon.h"
#include <assert.h>

static int calls;
static void cleared(void *context, uint64_t token, const uint8_t *png, size_t count) {
  assert(context == NULL && token == 17 && !png && count == 0);
  ++calls;
}

#ifdef BARC_HAS_TAB_FAVICON
static int bind_icon(uint64_t token, BarcTabFaviconCallback callback) {
  callback(NULL, token, NULL, 0);
  return 1;
}
#endif

int main(void) {
  struct BarcBridge api = {.size = sizeof(api)};
  assert(!BarkObserveTabFavicon(&api, 17, cleared));
#ifdef BARC_HAS_TAB_FAVICON
  api.tab_bind_favicon = bind_icon;
  api.size = offsetof(struct BarcBridge, tab_bind_favicon);
  assert(!BarkObserveTabFavicon(&api, 17, cleared) && calls == 0);
  api.size = sizeof(api);
  assert(BarkObserveTabFavicon(&api, 17, cleared) && calls == 1);
#else
  assert(calls == 0);
#endif
}
