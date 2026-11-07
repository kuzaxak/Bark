#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_

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
// Resolve only app-owned model identity, on browser UI after initial admission.
// kind=0 external URLs (regular), kind=1 New Window, kind=2 Dock reopen.
// Initialize output empty. Return an exact live logical window, or 0 plus a
// canonical existing regular model UUID when no live owner exists. Empty means
// refusal, never a default-profile fallback. -1 with empty output means an
// ordinary model window is temporarily opening; only URL kind accepts it.
// Native copies output immediately.
// Borrow callback/user_data until runtime stop/ChromeMain return, like ready.
__attribute__((visibility("default"))) void
barc_set_runtime_browser_target_callback(int32_t (*callback)(int32_t kind,
                                                             char* regular_uuid,
                                                             size_t capacity,
                                                             void*),
                                         void* user_data);
// Browser UI thread. Complete after successful native attachment with a live
// window, or 0 on failure. Repeated completion is ignored. Failure requests
// normal Chromium shutdown. After ChromeMain returns, 0 only clears callbacks.
__attribute__((visibility("default"))) void barc_runtime_complete_startup(
    int32_t window);
#ifdef __cplusplus
}
#include "base/functional/callback_forward.h"
class BrowserWindowInterface;
class Profile;
namespace base {
class FilePath;
}
namespace barc {
bool IsNativeApplicationRegistered();
bool CanResolveApplicationBrowser();
// Sticky mode identity survives early stop, preventing native queues from
// falling through to stock/default-profile routing after cancellation.
bool IsNativeApplicationMode();
// Captured before ChromeMain, so startup parsing does not query filesystem cwd
// from the browser UI thread. Empty if unavailable/stopped.
base::FilePath ApplicationLaunchDirectory();
// Installed once by the real AppController, weakly bound to that owner. Its
// existing queues drain after model admission; all runtime teardown clears it.
void SetApplicationLaunchReadyCallback(base::RepeatingClosure callback);
// Coalesced non-nestable delivery, after catalog/admission callbacks unwind.
void NotifyApplicationBrowserAvailable();
enum class ApplicationBrowserResult { kReady, kOpening, kUnavailable };
// The Profile is borrowed only during callback. nullptr/nullptr is refusal.
// No request registry: the existing async ProfileManager callback owns work.
void RunInApplicationBrowser(int32_t kind,
                             base::OnceCallback<void(ApplicationBrowserResult,
                                                     BrowserWindowInterface*,
                                                     Profile*)> callback);
void PostRuntimeReady();
void RuntimeStopped();
// Internal browser-test inspection; no C export or production caller.
bool RuntimeCallbacksClearedForTesting();
}  // namespace barc
#endif
#endif
