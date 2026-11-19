// Licensed under GPL-3.0. See LICENSE.
#include <assert.h>
#include "BarkRendererState.h"

#ifdef BARC_HAS_RENDERER_STATE
static int read_state(int32_t window, int32_t tab, int32_t *pid, int32_t *visible) {
  if (window != 2 || tab != 4) return 0;
  *pid = 42;
  *visible = 0;
  return 1;
}
#endif

int main(void) {
  struct BarcBridge bridge = {.size = sizeof(bridge)};
  int32_t pid = -1, visible = -1;
  assert(!BarkReadRendererState(&bridge, 2, 4, &pid, &visible));
#ifdef BARC_HAS_RENDERER_STATE
  bridge.tab_renderer_state = read_state;
  bridge.size = offsetof(struct BarcBridge, tab_renderer_state);
  assert(!BarkReadRendererState(&bridge, 2, 4, &pid, &visible));
  bridge.size = sizeof(bridge);
  assert(!BarkReadRendererState(&bridge, 2, 7, &pid, &visible));
  assert(pid == -1 && visible == -1);
  assert(BarkReadRendererState(&bridge, 2, 4, &pid, &visible));
  assert(pid == 42 && visible == 0);
#else
  assert(pid == -1 && visible == -1);
#endif
}
