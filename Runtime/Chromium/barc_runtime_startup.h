#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Register exactly once on the main thread before ChromeMain. Browser-process
// only; never starts NSApplication. Callback/user_data must survive ChromeMain.
__attribute__((visibility("default"))) void barc_set_runtime_ready_callback(
    void (*callback)(void*), void* user_data);
// Browser UI thread. Complete after successful native attachment with a live
// window, or 0 on failure. Repeated completion is ignored. Failure requests
// normal Chromium shutdown. After ChromeMain returns, 0 only clears callbacks.
__attribute__((visibility("default"))) void barc_runtime_complete_startup(
    int32_t window);
#ifdef __cplusplus
}
namespace barc {
bool IsNativeApplicationRegistered();
void PostRuntimeReady();
void RuntimeStopped();
}  // namespace barc
#endif
#endif
