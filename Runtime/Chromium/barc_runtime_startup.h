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
// Browser UI, once before ChromeMain. kind=0 validated incoming URL, kind=1
// New Window, kind=2 Dock reopen, kind=3 exact pending-page admission.
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
#include <string>
#include "base/functional/callback_forward.h"
class BrowserWindowInterface;
class Profile;
class GURL;
namespace content {
class WebContents;
}
namespace base {
class FilePath;
}
namespace password_manager { struct PasswordForm; }
namespace barc {
// Called only by Chromium's validated password-save admission. Returns true
// only when an opt-in model consumer owns the single save prompt.
bool OfferVaultPasswordSave(content::WebContents* contents,
                            const password_manager::PasswordForm& credentials);
// Internal network provenance only, after request/redirect identity validation.
// Records a matching in-progress navigation; does not call Swift or navigate.
void RecordNativeNavigationBlock(content::WebContents* contents,
                                 int64_t navigation, const GURL& url);
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
// URL-aware policy and exact pending-page admission share the existing resolver.
void RunInApplicationBrowser(int32_t kind, std::string url,
                             int32_t pending_window, int32_t pending_tab,
                             base::OnceCallback<void(ApplicationBrowserResult,
                                                     BrowserWindowInterface*,
                                                     Profile*, BarcApplicationTarget)> callback);
// One pending resource identity; its validated URL stays in StartupTabs.
struct ApplicationPage { int32_t window = 0; int32_t tab = 0; uint64_t request = 0; };
ApplicationPage CreateApplicationPage(Profile* profile, BrowserWindowInterface* owner,
                                       const BarcApplicationTarget& target,
                                       uint64_t request);
bool IsPendingApplicationPage(ApplicationPage page);
void CloseUnusedApplicationPage(ApplicationPage page);
bool MarkApplicationPage(int32_t window, int32_t tab, uint64_t request,
                          std::string space);
bool ApplicationPageMatches(int32_t window, int32_t tab, uint64_t request);
// A captured native intent stays owned by its intrinsic blank-page record.
// The existing availability task retries only the deterministic pending front.
bool SetApplicationPageResume(ApplicationPage page, base::RepeatingClosure resume);
void DrainApplicationPageIntents();
void ClearApplicationPageIntents();
void ConsumeApplicationPage(int32_t window, int32_t tab, uint64_t request);
void AbandonApplicationPageRequest(int32_t tab, uint64_t request);

bool IsApplicationMini(const BrowserWindowInterface* browser);
void PostRuntimeReady();
void RuntimeStopped();
// Internal browser-test inspection; no C export or production caller.
bool RuntimeCallbacksClearedForTesting();
}  // namespace barc
#endif
#endif
