#ifndef BARC_CHROMIUM_BRIDGE_H_
#define BARC_CHROMIUM_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

// Versioned C boundary built into the pinned Chromium framework. Call every
// entry point on Chromium's browser UI thread, after browser startup. Handles
// are process-local IDs, never C++ or Objective-C pointers; closed IDs fail.
#ifdef __cplusplus
extern "C" {
#endif
#define BARC_API __attribute__((visibility("default")))
BARC_API uint32_t barc_bridge_version(void);
// Static NUL-terminated engine version, valid for the process lifetime.
BARC_API const char* barc_chromium_version(void);
// Creates an empty same-profile peer for immediate page insertion/transfer.
// Close it if the insertion fails. It becomes visible once populated.
BARC_API int32_t barc_window_new_peer(int32_t source_window);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
BARC_API int barc_window_close(int32_t window);
BARC_API size_t barc_window_tab_count(int32_t window);
BARC_API int32_t barc_window_tab_at(int32_t window, size_t index);
BARC_API int32_t barc_tab_create(int32_t window,
                                 const char* url,
                                 int foreground);
BARC_API int barc_tab_select(int32_t window, int32_t tab);
BARC_API int barc_tab_navigate(int32_t window, int32_t tab, const char* url);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
// A tab ID stops resolving only after actual destruction.
BARC_API int barc_tab_close(int32_t window, int32_t tab);
// Cross-profile transfer is rejected; reassignment requires a new document.
// Transfer during a navigation callback is refused; callers may post a UI task.
BARC_API int barc_tab_transfer(int32_t source_window,
                               int32_t tab,
                               int32_t destination_window);
// Select this logical browser within its physical native window. Returns 0
// for stale/refused admission; does not claim completed native
// focus/activation.
BARC_API int barc_window_select(int32_t window);
// Returns bytes required including NUL; 0 means stale/invalid handle. A short
// buffer is NUL-terminated. Titles are UTF-8 and may be empty. A non-null
// buffer must point to at least capacity writable chars; nullptr queries size.
BARC_API size_t barc_tab_copy_title(int32_t window,
                                    int32_t tab,
                                    char* buffer,
                                    size_t capacity);
// Navigation observation is UI-thread-only. One observer per live tab; duplicate
// binding fails. Strings are UTF-8, borrowed only during the callback. INITIAL
// is synchronous; return is 0 if that callback unobserves. A queued close request
// leaves the token active until deletion is admitted or the caller unobserves.
// Unobserve is idempotent and prevents every subsequent callback. CLOSED is
// terminal (once), emitted when deletion is admitted, before final destruction.
// Tab/window close during callbacks queues a non-nestable UI request and returns
// queue acceptance; exact IDs are revalidated when it runs. This permits modal
// nested loops and unsubscribe-then-close without destroying notifying contents.
// CLOSE_CANCELLED reports explicit refusal and keeps the live observation.
// Pending unload/download dialogs do not complete a close request.
// Other mutation APIs do not promise unrestricted callback reentrancy.
// Same-profile transfers retain observation; event window follows current owner
// (0 while detached). Contents replacement emits STATE for the replacement.
// Lifecycle STARTED/FINISHED/FAILED cover only navigations started after binding.
// Mid-load binding reports INITIAL/STATE and actual subsequent primary commits;
// it never invents a historical start, finish or failure. Bind before navigating
// a newly created blank tab for complete lifecycle coverage.
// FAILED URL is the displayed last committed URL (not the rejected target).
// Same-document changes emit COMMITTED with SAME_DOCUMENT, without STARTED.
// Error is net::Error; ABORTED is cancellation, not a user-visible failure.
enum BarcTabEvent {
  BARC_TAB_INITIAL = 0, BARC_TAB_STARTED = 1, BARC_TAB_COMMITTED = 2,
  BARC_TAB_FINISHED = 3, BARC_TAB_FAILED = 4, BARC_TAB_TITLE = 5,
  BARC_TAB_STATE = 6, BARC_TAB_CLOSED = 7, BARC_TAB_CLOSE_CANCELLED = 8
};
enum BarcTabFlags {
  BARC_TAB_LOADING = 1, BARC_TAB_BACK = 2, BARC_TAB_FORWARD = 4,
  BARC_TAB_RELOAD = 8, BARC_TAB_SAME_DOCUMENT = 16,
  BARC_TAB_PROVISIONAL = 32, BARC_TAB_ABORTED = 64,
  // CLOSED reflects owner shutdown; retain saved app tab metadata.
  BARC_TAB_OWNER_ENDED = 128
};
typedef void (*BarcTabCallback)(void* context, uint64_t observation,
                               int32_t event, int32_t window, int32_t tab,
                               const char* url, const char* title,
                               int32_t error, uint32_t flags);
BARC_API uint64_t barc_tab_observe(int32_t window, int32_t tab,
                                  BarcTabCallback callback, void* context);
BARC_API void barc_tab_unobserve(uint64_t observation);
BARC_API int barc_tab_go_back(int32_t window, int32_t tab);
BARC_API int barc_tab_go_forward(int32_t window, int32_t tab);
BARC_API int barc_tab_reload(int32_t window, int32_t tab);
BARC_API int barc_tab_stop(int32_t window, int32_t tab);
// Selects the admitted logical owner, then shows its normal Chromium window.
BARC_API int barc_window_show(int32_t window);
// native_view is an NSView* (including NSHostingView), retained by the native
// host until replacement, nullptr detach, or window close. Chromium retains
// window ownership. Detach restores the space reserved for the native shell.
// Nested attachment is refused (0); close requests may be deferred until this
// attachment returns. Native destruction or changed attachment returns 0.
BARC_API int barc_window_attach_native_shell(int32_t window, void* native_view);
// Pure native-host identity query; null matches an existing empty host.
// Missing host, mismatched view or stale window returns 0.
BARC_API int barc_window_native_shell_is_owned(int32_t window,
                                             void* expected_view);
// Detach only the exact currently attached NSView; null/mismatch/stale returns 0.
BARC_API int barc_window_detach_native_shell_if_owned(int32_t window,
                                                    void* expected_view);
#ifdef __cplusplus
}

namespace views {
class NativeViewHost;
class View;
}  // namespace views
class BrowserView;
namespace barc {
inline constexpr int kNativeShellWidth = 240;
int NativeShellWidth(const BrowserView* browser_view);
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view);
void LayoutNativeShell(views::NativeViewHost* shell, views::View* browser_view);
}  // namespace barc
#endif
#endif
