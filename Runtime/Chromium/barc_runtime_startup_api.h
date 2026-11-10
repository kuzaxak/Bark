#ifndef BARC_RUNTIME_STARTUP_API_H_
#define BARC_RUNTIME_STARTUP_API_H_

#include <stdint.h>
#include <stddef.h>

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
// Where a person's New Window or New Private Window request comes from: a key,
// a menu, the Dock or a page's command.
enum BarcApplicationWindowRequest {
  BARC_APPLICATION_NEW_WINDOW = 1,
  BARC_APPLICATION_NEW_PRIVATE_WINDOW = 2
};
// Main thread, once before ChromeMain; borrowed like the close callback. In
// native application mode these requests come here and Chromium opens nothing:
// the app opens the window it wants. Dock reopen comes here as New Window when
// the browser target names no window to show.
__attribute__((visibility("default"))) void
barc_set_runtime_window_request_callback(
    void (*callback)(int32_t request, void*), void* user_data);
// A validated incoming URL chooses current-space or detached-mini presentation.
// UUID fields are canonical, NUL-terminated model identities, never paths.
// Native copies this value before the resolver returns.
enum BarcApplicationPresentation {
  BARC_APPLICATION_CURRENT_SPACE = 0,
  BARC_APPLICATION_MINI = 1
};
typedef struct BarcApplicationTarget {
  int32_t window;  // Exact logical owner, or zero for a regular-profile load.
  uint32_t presentation;
  char regular_profile_uuid[37];
  char space_uuid[37];
} BarcApplicationTarget;
// Browser UI, once before ChromeMain. kind=0 validated incoming URL, kind=2
// Dock reopen, kind=3 exact pending-page admission.
// validated_url is null for profile-only lookup. Pending handles are zero except
// kind=3; that query never selects, creates or navigates.
// Return 1 with an initialized exact target; 0 refuses. -1 means temporary
// ordinary-window opening, only for URL requests. Never infer a default owner.
// Borrow callback/user_data until runtime stop/ChromeMain return, like ready.
__attribute__((visibility("default"))) void
barc_set_runtime_browser_target_callback(
    int32_t (*callback)(int32_t kind, const char* validated_url,
                        int32_t pending_window, int32_t pending_tab,
                        BarcApplicationTarget* out_target, void*),
    void* user_data);
// Browser UI thread. Complete after successful native attachment with a live
// window, or 0 on failure. Repeated completion is ignored. Failure requests
// normal Chromium shutdown. After ChromeMain returns, 0 only clears callbacks.
__attribute__((visibility("default"))) void barc_runtime_complete_startup(
    int32_t window);
#ifdef __cplusplus
}
#endif
#endif
