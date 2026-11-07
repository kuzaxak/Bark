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
// Version 3 guarantees that native startup registration selects the dedicated
// NookChromium Safe Storage/account namespace before ChromeMain/provider init.
// Version 2 is accepted only for explicit mock-keychain verification startup.
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
// UI commands target only this exact selected logical owner and active tab.
// No selection/focus or fallback retargeting is performed. Return dispatch
// acceptance, not completion of a dialog, find result, print job or DevTools.
// Refused during bridge callbacks; callers may post a browser UI task.
enum BarcPageCommand {
  BARC_PAGE_FIND = 0, BARC_PAGE_FIND_NEXT = 1, BARC_PAGE_FIND_PREVIOUS = 2,
  BARC_PAGE_ZOOM_IN = 3, BARC_PAGE_ZOOM_OUT = 4, BARC_PAGE_ZOOM_RESET = 5,
  BARC_PAGE_PRINT = 6, BARC_PAGE_DEVTOOLS = 7, BARC_PAGE_HARD_RELOAD = 8
};
BARC_API int barc_tab_execute_command(int32_t window, int32_t tab,
                                     int32_t command);
// Explicit tab mute, including background tabs; never changes selection or
// site sound settings. muted must be 0 or 1. Return actual helper acceptance
// for the still-live exact owner; actual state is reported by observation.
BARC_API int barc_tab_set_muted(int32_t window, int32_t tab, int muted);
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
// One browser-UI subscription to loaded Barc profiles' existing download
// managers. Strings/snapshot are borrowed only during callbacks, delivered in
// posted non-nestable UI tasks. Initial/history items may repeat; identity is
// actual profile/session UUID + private flag + GUID. manager is a process-local
// source lifetime token, not a Profile pointer. Unknown profiles are excluded.
enum BarcDownloadEvent { BARC_DOWNLOAD_ITEM = 0, BARC_DOWNLOAD_REMOVED = 1,
                         BARC_DOWNLOAD_MANAGER_ENDED = 2 };
enum BarcDownloadState { BARC_DOWNLOAD_PROGRESS = 0, BARC_DOWNLOAD_COMPLETE = 1,
                         BARC_DOWNLOAD_CANCELLED = 2, BARC_DOWNLOAD_INTERRUPTED = 3 };
enum BarcDownloadFlags { BARC_DOWNLOAD_PRIVATE = 1, BARC_DOWNLOAD_UNSAFE = 2,
                         BARC_DOWNLOAD_SAFE_FILE = 4 };
struct BarcDownloadSnapshot {
  uint64_t manager;
  const char* profile_uuid;
  const char* guid;
  const char* url;
  const char* target_path;
  const char* filename;
  int32_t state;
  int32_t error;
  uint32_t flags;
  int64_t received_bytes;
  int64_t total_bytes;
  double started_unix;
};
typedef void (*BarcDownloadCallback)(void* context, uint64_t observation,
                                    int32_t event,
                                    const struct BarcDownloadSnapshot* snapshot);
BARC_API uint64_t barc_downloads_observe(BarcDownloadCallback callback, void* context);
BARC_API void barc_downloads_unobserve(uint64_t observation);
enum BarcDownloadAction { BARC_DOWNLOAD_CANCEL = 0, BARC_DOWNLOAD_REMOVE = 1 };
// Resolve GUID only in the exact still-live subscribed manager. CANCEL accepts
// in-progress items; REMOVE accepts terminal history items and never trashes a
// file. Returns dispatch/queue acceptance; events confirm state/removal.
BARC_API int barc_download_action(uint64_t observation, uint64_t manager,
                                  const char* guid, int32_t action);
// Pure current safe-complete target, required bytes including NUL; 0 means
// unavailable/stale/unsafe. Same short-buffer contract as tab_copy_title.
BARC_API size_t barc_download_copy_safe_target(uint64_t observation,
    uint64_t manager, const char* guid, char* buffer, size_t capacity);

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
  BARC_TAB_OWNER_ENDED = 128,
  // Actual WebContents output mute/audibility, not capture or work eligibility.
  BARC_TAB_MUTED = 256, BARC_TAB_AUDIBLE = 512
};
typedef void (*BarcTabCallback)(void* context, uint64_t observation,
                               int32_t event, int32_t window, int32_t tab,
                               const char* url, const char* title,
                               int32_t error, uint32_t flags);
BARC_API uint64_t barc_tab_observe(int32_t window, int32_t tab,
                                  BarcTabCallback callback, void* context);
BARC_API void barc_tab_unobserve(uint64_t observation);
// Bounded PNG capture of an already-presented tab. One in flight per existing
// observation. Bytes are borrowed during callback; nullptr/0 means failure.
// Context is the observation's existing context. Unobserve/terminal teardown
// cancels publication. Acceptance never loads, selects, shows or wakes a page.
typedef void (*BarcTabThumbnailCallback)(void* context, uint64_t observation,
                                        uint64_t request, const uint8_t* png, size_t length);
BARC_API int barc_tab_capture_thumbnail(uint64_t observation, uint64_t request,
                                       BarcTabThumbnailCallback callback);
// Exact current-document site data commands. Return dispatch acceptance; the
// callback reports deletion completion/cancellation/failure on the UI thread.
// COOKIES_AND_RELOAD waits for deletion, then reports reload dispatch acceptance.
// Cookie scope is host/.host and current top-level partition keys; CACHE never
// deletes cookies/DOM storage or globally flushes renderer memory resources. Unobserve/terminal teardown cancels publication.
enum BarcSiteDataAction {
  BARC_SITE_COOKIES = 0, BARC_SITE_CACHE = 1, BARC_SITE_COOKIES_AND_RELOAD = 2
};
enum BarcSiteDataResult {
  BARC_SITE_COMPLETED = 0, BARC_SITE_CANCELLED = 1, BARC_SITE_FAILED = 2
};
typedef void (*BarcSiteDataCallback)(void* context, uint64_t observation,
                                    uint64_t request, int32_t result);
BARC_API int barc_tab_clear_site_data(uint64_t observation, uint64_t request,
                                      int32_t action, BarcSiteDataCallback callback);

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
enum BarcDiscoveryWindowKind {
  BARC_DISCOVERY_NORMAL = 0, BARC_DISCOVERY_POPUP = 1,
  BARC_DISCOVERY_APP = 2, BARC_DISCOVERY_DEVTOOLS = 3,
  BARC_DISCOVERY_OTHER_WINDOW = 4
};
enum BarcDiscoveryProfileKind {
  BARC_DISCOVERY_REGULAR = 0, BARC_DISCOVERY_INCOGNITO = 1,
  BARC_DISCOVERY_GUEST = 2, BARC_DISCOVERY_OTHER_PROFILE = 3
};
enum BarcDiscoveryWindowFlags {
  BARC_DISCOVERY_PHYSICAL_ACTIVE = 1,
  BARC_DISCOVERY_PHYSICAL_VISIBLE = 2,
  BARC_DISCOVERY_SELECTED_CLIENT = 4,
  BARC_DISCOVERY_WINDOW_APP_FACTORY = 8,
  BARC_DISCOVERY_AWAITING_ADMISSION = 16,
  BARC_DISCOVERY_OWNER_ENDING = 32
};
enum BarcDiscoveryTabFlags {
  BARC_DISCOVERY_ACTIVE_TAB = 1,
  BARC_DISCOVERY_TAB_APP_FACTORY = 2
};

typedef struct BarcDiscoveryWindow {
  uint64_t physical_group;  // Opaque; not a live window handle. Zero is invalid.
  int32_t window;
  int32_t active_tab;       // Actual selection in this logical tab strip, or 0.
  int32_t selected_client;  // Authoritative logical client for physical_group.
  uint32_t kind;
  uint32_t profile_kind;
  uint32_t flags;
  // Existing barc_window_profile_uuid result, NUL-terminated. Empty for every
  // nonregular/unknown profile; no default-profile inference.
  char regular_profile_uuid[37];
} BarcDiscoveryWindow;

typedef struct BarcDiscoveryTab {
  int32_t window;
  int32_t tab;
  int32_t opener_tab;  // Live JS opener TabHandle, or 0 (including noopener).
  int32_t index;
  uint32_t flags;      // ACTIVE_TAB does not imply physical activation/focus.
} BarcDiscoveryTab;

typedef struct BarcDiscoverySnapshot {
  uint64_t revision;
  size_t window_count;
  size_t tab_count;
} BarcDiscoverySnapshot;

enum BarcDiscoveryReadStatus {
  BARC_DISCOVERY_READ_OK = 0,
  BARC_DISCOVERY_READ_CAPACITY = 1,
  BARC_DISCOVERY_READ_UNAVAILABLE = 2,
  BARC_DISCOVERY_READ_INVALID_ARGUMENT = 3
};
// Pure live enumeration; no callbacks, selection, focus, navigation or showing.
// out_snapshot is required. Null arrays with zero capacity query needed counts.
// Insufficient capacity writes counts/revision only, never partial array rows.
// Run both calls on UI without yielding; retry capacity only if caller yielded.
BARC_API int32_t barc_discovery_snapshot(BarcDiscoveryWindow* windows,
                                size_t window_capacity,
                                BarcDiscoveryTab* tabs,
                                size_t tab_capacity,
                                BarcDiscoverySnapshot* out_snapshot);

typedef void (*BarcDiscoveryCallback)(void* context, uint64_t observation,
                                     uint64_t revision);
// One observer; duplicate registration returns0. Initial and later invalidations
// are coalesced posted NON-nestable tasks, never inline mutation callbacks.
// Revision changes cover ownership/membership, logical/active-tab selection,
// physical active/visible and admission state; not title/loading/progress.
// Callback is invalidation only: read a fresh snapshot. It may unobserve/close.
// Unobserve clears borrowed context and cancels every pending delivery; caller
// keeps context alive until unobserve (which is safe from inside its callback).
BARC_API uint64_t barc_discovery_observe(BarcDiscoveryCallback callback, void* context);
BARC_API void barc_discovery_unobserve(uint64_t observation);

// Pure single-window row lookup using the same authoritative row builder as
// snapshot, without enumerating/copying the catalog or invoking callbacks.
// out_window is required; returns 0 if unavailable. No selection/focus/show.
BARC_API int barc_window_discovery_state(int32_t window,
                                        BarcDiscoveryWindow* out_window);

// Chrome-created NORMAL windows only: attach/admit model first. Checks exact
// nonnull currently attached NSView before releasing deferred first Show mode.
// Refusal/stale/reentrant replacement returns0; never adopts/reloads/focuses a
// different logical client. Preserve Show/ShowInactive/Activate intent; do not
// replay over a newer intent or later native selection. Repeated admission of
// the same admitted view succeeds without replaying presentation.
// POPUP display/opener behavior is untouched.
// Factory-origin windows/tabs must be deduplicated against their own completion;
// consumers must not auto-adopt them from an earlier catalog notification.
BARC_API int barc_window_admit_discovered(int32_t window, void* expected_native_view);

#ifdef __cplusplus
}

namespace views {
class NativeViewHost;
class View;
}  // namespace views
class BrowserView;
namespace barc {
// Internal Chrome-view hooks; no foreign callbacks are invoked inline.
void BrowserDiscoveryChanged();
void StopBrowserDiscovery();
inline constexpr int kNativeShellWidth = 240;
int NativeShellWidth(const BrowserView* browser_view);
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view);
void LayoutNativeShell(views::NativeViewHost* shell, views::View* browser_view);
}  // namespace barc
#endif
#endif
