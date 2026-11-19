// Licensed under GPL-3.0. See LICENSE.
#include "BarkLoadProgress.h"
#include <assert.h>

static void report(void *context, uint64_t observation, double progress,
                   int loading) {
  assert(context == NULL && observation == 23 && progress == 0.75);
  assert(loading == 1);
}

#ifdef BARC_HAS_LOAD_PROGRESS
static int observe(uint64_t observation, BarcLoadProgressCallback callback) {
  assert(observation == 23 && callback == report);
  callback(NULL, observation, 0.75, 1);
  return 1;
}
#endif

int main(void) {
  struct BarcBridge bridge = {0};
  bridge.size = sizeof(bridge);
  assert(BarkObserveTabLoadProgress(&bridge, 23, report) == 0);
#ifdef BARC_HAS_LOAD_PROGRESS
  bridge.tab_observe_load_progress = observe;
  bridge.size = offsetof(struct BarcBridge, tab_observe_load_progress);
  assert(BarkObserveTabLoadProgress(&bridge, 23, report) == 0);
  bridge.size = sizeof(bridge);
  assert(BarkObserveTabLoadProgress(&bridge, 23, report) == 1);
#endif
}
