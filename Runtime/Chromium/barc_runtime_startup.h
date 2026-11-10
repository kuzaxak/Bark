#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_BARC_RUNTIME_STARTUP_H_

#include <string>

#include "chrome/browser/ui/views/frame/barc_runtime_startup_api.h"
#include "base/functional/callback_forward.h"
#include "ui/gfx/native_ui_types.h"
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
// Find, zoom, reload, print, devtools and history commands of the shown page.
bool IsPageCommand(int command_id);
// In native application mode a key runs a Chromium command only for the shown
// page, for editing, or to ask the app for a window. The app owns every other
// key, even when it has no action for it.
bool ApplicationOwnsKeyCommand(int command_id);
// Also true for a page command while the app shows no page in `window`.
bool KeyCommandBelongsToApplication(gfx::NativeWindow window, int command_id);
// Hands a BarcApplicationWindowRequest to the app; Chromium opens no window.
void RequestApplicationWindow(int32_t request);
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
