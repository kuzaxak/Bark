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
// Main thread, once before ChromeMain. Borrow callback/user_data until runtime
// stop/ChromeMain return. accepted=1 follows current shutdown consent, before
// teardown; accepted=0 reports a later veto only after that notification.
// Initial attempts, non-quit window close and post-stop work never notify.
__attribute__((visibility("default"))) void barc_set_runtime_close_callback(
    void (*callback)(int32_t accepted, void*), void* user_data);
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
// Internal browser-test inspection; no C export or production caller.
bool RuntimeCallbacksClearedForTesting();
}  // namespace barc
#endif
#endif
